import { useCallback, useEffect, useRef, useState } from "react";
import { IndexeddbPersistence } from "y-indexeddb";
import * as Y from "yjs";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Route } from "./+types/home";

interface User { login: string; avatarUrl?: string }
interface Repository { fullName: string; defaultBranch: string; private: boolean; canWrite: boolean }
interface Workspace { id: string; repository: string; branch: string; revision: number; githubStatus: string; message?: string }
interface FileRecord { id: string; path: string; kind: "markdown" | "asset" | "folder"; content?: string; size?: number; revision?: number }
interface SyncStatus { githubStatus: string; pendingFiles: number; message?: string; lastGitHubCommitAt?: string; nextGitHubFlushAt?: number }
interface RealtimeMessage { type: string; fileId?: string; update?: string; operationId?: string; acceptedRevision?: number; revision?: number; message?: string; code?: string }
interface Peer { clientId: string; login: string; avatarUrl?: string; fileId?: string }

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function id(): string { return crypto.randomUUID(); }

function applyTextDiff(text: Y.Text, previous: string, next: string): void {
  if (previous === next) return;
  let prefix = 0;
  const maxPrefix = Math.min(previous.length, next.length);
  while (prefix < maxPrefix && previous.charCodeAt(prefix) === next.charCodeAt(prefix)) prefix++;
  let suffix = 0;
  while (suffix < previous.length - prefix && suffix < next.length - prefix &&
    previous.charCodeAt(previous.length - suffix - 1) === next.charCodeAt(next.length - suffix - 1)) suffix++;
  const removed = previous.length - prefix - suffix;
  const inserted = next.slice(prefix, next.length - suffix);
  text.doc!.transact(() => {
    if (removed) text.delete(prefix, removed);
    if (inserted) text.insert(prefix, inserted);
  }, "local-editor");
}

export function meta(_: Route.MetaArgs) {
  return [{ title: "PKMS — Markdown workspace" }];
}

export default function Home() {
  const [user, setUser] = useState<User | null>(null);
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [repositories, setRepositories] = useState<Repository[]>([]);
  const [activeWorkspace, setActiveWorkspace] = useState<Workspace | null>(null);
  const [files, setFiles] = useState<FileRecord[]>([]);
  const [activeFile, setActiveFile] = useState<FileRecord | null>(null);
  const [text, setText] = useState("");
  const [sync, setSync] = useState<SyncStatus>({ githubStatus: "pending", pendingFiles: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [showRepositories, setShowRepositories] = useState(false);
  const [saving, setSaving] = useState(false);
  const [peers, setPeers] = useState<Peer[]>([]);
  const socket = useRef<WebSocket | null>(null);
  const docs = useRef(new Map<string, { doc: Y.Doc; persistence: IndexeddbPersistence; observer?: () => void; updateHandler?: (update: Uint8Array, origin: unknown) => void }>());
  const activeRef = useRef<{ file: FileRecord | null; doc: Y.Doc | null; text: Y.Text | null; value: string }>({ file: null, doc: null, text: null, value: "" });
  const pending = useRef(new Map<string, RealtimeMessage>());
  const hydrating = useRef(false);

  const api = useCallback(async <T,>(path: string, init?: RequestInit): Promise<T> => {
    const response = await fetch(path, { credentials: "same-origin", ...init });
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as { message?: string; error?: string };
      throw new Error(body.message ?? body.error ?? `Request failed (${response.status})`);
    }
    if (response.status === 204) return undefined as T;
    return response.json() as Promise<T>;
  }, []);

  const refreshWorkspaces = useCallback(async () => {
    const result = await api<{ workspaces: Workspace[] }>("/api/workspaces");
    setWorkspaces(result.workspaces);
    setActiveWorkspace((previous) => previous ? result.workspaces.find((item) => item.id === previous.id) ?? previous : result.workspaces[0] ?? null);
  }, [api]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const result = await api<{ user: User | null }>("/api/session");
        if (!alive) return;
        setUser(result.user);
        if (result.user) await refreshWorkspaces();
      } catch (cause) {
        if (alive) setError(cause instanceof Error ? cause.message : "Could not load your session");
      } finally { if (alive) setLoading(false); }
    })();
    return () => { alive = false; };
  }, [api, refreshWorkspaces]);

  useEffect(() => {
    if (!activeWorkspace) {
      setFiles([]); setActiveFile(null); setText("");
      return;
    }
    let alive = true;
    const clientId = `web-${id()}`;
    let retryTimer = 0;
    let retries = 0;
    const connect = () => {
      if (!alive) return;
      const url = new URL(`/api/workspaces/${activeWorkspace.id}/stream`, window.location.origin);
      url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      url.searchParams.set("clientId", clientId);
      const ws = new WebSocket(url);
      socket.current = ws;
      ws.onopen = () => {
        retries = 0;
        ws.send(JSON.stringify({ type: "hello", protocolVersion: 1, clientId, afterRevision: activeWorkspace.revision, user, fileId: activeRef.current.file?.id }));
        const current = activeRef.current;
        if (current.file && current.doc) {
          const operationId = id();
          ws.send(JSON.stringify({ type: "document-update", operationId, fileId: current.file.id, update: toBase64(Y.encodeStateAsUpdate(current.doc)) }));
          pending.current.set(operationId, { type: "document-update", operationId, fileId: current.file.id });
        }
      };
      ws.onmessage = (event) => {
      let message: RealtimeMessage;
      try { message = JSON.parse(String(event.data)) as RealtimeMessage; } catch { return; }
      if (message.type === "presence-state") {
        setPeers((message as RealtimeMessage & { peers?: Peer[] }).peers ?? []);
      } else if (message.type === "presence") {
        const presence = message as RealtimeMessage & { action?: string; peer?: Peer; clientId?: string };
        if (presence.action === "leave") setPeers((current) => current.filter((peer) => peer.clientId !== presence.clientId));
        else if (presence.peer) setPeers((current) => [...current.filter((peer) => peer.clientId !== presence.peer!.clientId), presence.peer!]);
      } else if (message.type === "document-state" && message.fileId && message.update) {
        const document = docs.current.get(message.fileId)?.doc;
        if (document) Y.applyUpdate(document, fromBase64(message.update), "server");
        else pending.current.set(`state:${message.fileId}`, message);
      } else if (message.type === "document-update" && message.fileId && message.update) {
        const document = docs.current.get(message.fileId)?.doc;
        if (document) Y.applyUpdate(document, fromBase64(message.update), "server");
      } else if (message.type === "ack" && message.operationId) {
        pending.current.delete(message.operationId);
        setSaving(pending.current.size > 0);
        setNotice("Saved to cloud");
      } else if (message.type === "error") {
        setError(message.message ?? "Collaboration sync failed");
      } else if (typeof message.acceptedRevision === "number") {
        void api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`).then((snapshot) => setFiles(snapshot.files)).catch(() => {});
      }
      };
      ws.onclose = () => {
        if (socket.current === ws) socket.current = null;
        setPeers([]);
        pending.current.clear();
        setSaving(false);
        if (alive) {
          const delay = Math.min(30_000, 1_000 * 2 ** Math.min(retries++, 5));
          setError("Live sync disconnected. Reconnecting…");
          retryTimer = window.setTimeout(connect, delay);
        }
      };
      ws.onerror = () => ws.close();
    };
    connect();
    const loadSnapshot = async () => {
      try {
        const result = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
        if (!alive) return;
        setFiles(result.files);
        const state = await api<SyncStatus>(`/api/workspaces/${activeWorkspace.id}/sync-status`);
        if (alive) setSync(state);
      } catch (cause) { if (alive) setError(cause instanceof Error ? cause.message : "Could not load workspace"); }
    };
    void loadSnapshot();
    const timer = window.setInterval(() => {
      void api<SyncStatus>(`/api/workspaces/${activeWorkspace.id}/sync-status`).then(setSync).catch(() => {});
    }, 15_000);
    return () => { alive = false; window.clearInterval(timer); window.clearTimeout(retryTimer); socket.current?.close(); socket.current = null; setPeers([]); };
  }, [activeWorkspace, api, user]);

  const openFile = useCallback(async (file: FileRecord) => {
    setNotice("");
    const previous = activeRef.current;
    if (previous.file && previous.text) {
      const oldEntry = docs.current.get(previous.file.id);
      if (oldEntry?.observer) previous.text.unobserve(oldEntry.observer);
      if (oldEntry) oldEntry.observer = undefined;
    }
    if (file.kind !== "markdown") {
      setActiveFile(file); setText(""); activeRef.current = { file, doc: null, text: null, value: "" };
      return;
    }
    setError(""); setActiveFile(file); setSaving(false); hydrating.current = true;
    let entry = docs.current.get(file.id);
    if (!entry) {
      const doc = new Y.Doc({ guid: file.id });
      const persistence = new IndexeddbPersistence(`pkms:${activeWorkspace?.id}:${file.id}`, doc);
      entry = { doc, persistence };
      docs.current.set(file.id, entry);
      await persistence.whenSynced;
    }
    let currentText = entry.doc.getText("markdown");
    if (!currentText.length) {
      const server = await api<{ update: string }>(`/api/workspaces/${activeWorkspace?.id}/files/${file.id}/updates`);
      Y.applyUpdate(entry.doc, fromBase64(server.update), "server");
    }
    const queuedState = pending.current.get(`state:${file.id}`);
    if (queuedState?.update) {
      Y.applyUpdate(entry.doc, fromBase64(queuedState.update), "server");
      pending.current.delete(`state:${file.id}`);
    }
    currentText = entry.doc.getText("markdown");
    activeRef.current = { file, doc: entry.doc, text: currentText, value: currentText.toString() };
    setText(currentText.toString());
    const update = () => {
      const value = currentText.toString();
      activeRef.current.value = value;
      setText(value);
    };
    currentText.observe(update);
    entry.observer = update;
    const currentSocket = socket.current;
    const cacheKey = `pkms:${activeWorkspace?.id}:${file.id}`;
    const stored = JSON.parse(localStorage.getItem("pkms:recent-files") ?? "[]") as Array<{ key: string; lastOpened: number }>;
    const recent = [{ key: cacheKey, lastOpened: Date.now() }, ...stored.filter((item) => item.key !== cacheKey)].slice(0, 20);
    localStorage.setItem("pkms:recent-files", JSON.stringify(recent));
    const evicted = stored.filter((item) => !recent.some((kept) => kept.key === item.key));
    for (const item of evicted) {
      const fileId = item.key.split(":").at(-1) ?? "";
      const old = docs.current.get(fileId);
      if (old && activeRef.current.file?.id !== fileId) {
        old.doc.destroy();
        old.persistence.destroy();
        docs.current.delete(fileId);
      }
      const deletion = indexedDB.deleteDatabase(item.key);
      deletion.onerror = () => {};
    }
    if (entry.updateHandler) entry.doc.off("update", entry.updateHandler);
    const updateHandler = (updateBytes: Uint8Array, origin: unknown) => {
      if (origin === "server") return;
      const current = socket.current;
      if (!current || current.readyState !== WebSocket.OPEN) return;
      const operationId = id();
      pending.current.set(operationId, { type: "document-update", operationId, fileId: file.id });
      setSaving(true);
      current.send(JSON.stringify({ type: "document-update", operationId, fileId: file.id, update: toBase64(updateBytes) }));
    };
    entry.doc.on("update", updateHandler);
    entry.updateHandler = updateHandler;
    if (currentSocket?.readyState === WebSocket.OPEN) {
      currentSocket.send(JSON.stringify({ type: "presence", fileId: file.id }));
      const operationId = id();
      pending.current.set(operationId, { type: "document-update", operationId, fileId: file.id });
      setSaving(true);
      currentSocket.send(JSON.stringify({ type: "document-update", operationId, fileId: file.id, update: toBase64(Y.encodeStateAsUpdate(entry.doc)) }));
    }
    hydrating.current = false;
  }, [activeWorkspace?.id, api]);

  const chooseWorkspace = (workspace: Workspace) => {
    setActiveWorkspace(workspace); setActiveFile(null); activeRef.current = { file: null, doc: null, text: null, value: "" };
  };

  const openRepositoryPicker = async () => {
    setError("");
    try {
      const result = await api<{ repositories: Repository[] }>("/api/repositories");
      setRepositories(result.repositories.filter((repository) => repository.canWrite));
      setShowRepositories(true);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not list repositories"); }
  };

  const connectRepository = async (repository: Repository) => {
    setError("");
    try {
      const result = await api<{ workspace: Workspace }>("/api/workspaces", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ repository: repository.fullName, branch: repository.defaultBranch }) });
      setShowRepositories(false);
      await refreshWorkspaces();
      setActiveWorkspace(result.workspace);
      setNotice("Repository connected");
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not connect repository"); }
  };

  const newNote = async () => {
    if (!activeWorkspace) return;
    const path = `Untitled ${new Date().toLocaleString("sv-SE").replaceAll(":", "-")}.md`;
    try {
      const result = await api<{ operationId: string; acceptedRevision: number; conflictCopyPath?: string }>(`/api/workspaces/${activeWorkspace.id}/operations`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: "web", operation: { type: "create-file", path, fileId: id(), content: "# Untitled\n\n" } }),
      });
      const snapshot = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
      setFiles(snapshot.files);
      const created = snapshot.files.find((item) => item.path === (result.conflictCopyPath ?? path));
      if (created) await openFile(created);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not create note"); }
  };

  const newFolder = async () => {
    if (!activeWorkspace) return;
    const name = window.prompt("Folder name");
    if (!name?.trim()) return;
    try {
      await api(`/api/workspaces/${activeWorkspace.id}/operations`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: "web", operation: { type: "create-folder", path: name.trim() } }) });
      const snapshot = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
      setFiles(snapshot.files);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not create folder"); }
  };

  const uploadFile = async (file?: File) => {
    if (!file || !activeWorkspace) return;
    const form = new FormData(); form.set("file", file); form.set("path", file.name); form.set("clientId", "web");
    try {
      await api(`/api/workspaces/${activeWorkspace.id}/upload`, { method: "POST", body: form });
      const snapshot = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
      setFiles(snapshot.files);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Upload failed"); }
  };

  const handleText = (next: string) => {
    const current = activeRef.current;
    if (!current.text || hydrating.current) { setText(next); return; }
    const previous = current.text.toString();
    applyTextDiff(current.text, previous, next);
    activeRef.current.value = next;
    setText(next);
  };

  if (loading) return <main className="loading-screen"><div className="brand-mark">P</div><span>Opening your workspace…</span></main>;
  if (!user) return (
    <main className="welcome-screen">
      <div className="welcome-card">
        <div className="brand-lockup"><div className="brand-mark">P</div><span>PKMS</span></div>
        <h1>Your notes, in sync.</h1>
        <p>A fast, collaborative Markdown workspace stored in your GitHub repository.</p>
        {error && <div className="notice error">{error}</div>}
        <a className="primary-button github-button" href="/api/auth/github"><GitHubIcon /> Continue with GitHub</a>
        <small>Your repository remains yours. PKMS writes changes back to GitHub automatically.</small>
      </div>
    </main>
  );

  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="sidebar-top">
          <div className="brand-lockup"><div className="brand-mark small">P</div><span>PKMS</span></div>
          <button className="icon-button" title="Add repository" onClick={openRepositoryPicker}>＋</button>
        </div>
        <div className="workspace-select">
          <span className="eyebrow">WORKSPACE</span>
          {workspaces.length ? <select value={activeWorkspace?.id ?? ""} onChange={(event) => { const workspace = workspaces.find((item) => item.id === event.target.value); if (workspace) chooseWorkspace(workspace); }}>
            {workspaces.map((workspace) => <option key={workspace.id} value={workspace.id}>{workspace.repository}</option>)}
          </select> : <button className="connect-link" onClick={openRepositoryPicker}>Connect a repository <span>↗</span></button>}
        </div>
        {activeWorkspace && <>
          <div className="file-toolbar"><span className="eyebrow">FILES</span><div className="toolbar-actions">
            <button className="mini-button" title="New note" onClick={newNote}>＋</button>
            <button className="mini-button" title="New folder" onClick={newFolder}>▱</button>
            <label className="mini-button upload-button" title="Upload file">↑<input type="file" onChange={(event) => { void uploadFile(event.target.files?.[0]); event.currentTarget.value = ""; }} /></label>
          </div></div>
          <nav className="file-list" aria-label="Files">
            {files.map((file) => file.kind === "folder" ? <div className="folder-row" key={file.id}><span className="folder-icon">⌄</span>{file.path}</div> : <button key={file.id} className={`file-row ${activeFile?.id === file.id ? "selected" : ""}`} onClick={() => void openFile(file)}><span className="file-icon">{file.kind === "markdown" ? "▤" : "◇"}</span><span>{file.path}</span></button>)}
            {!files.length && <p className="empty-hint">This repository is empty. Create a note to get started.</p>}
          </nav>
        </>}
        <div className="sidebar-bottom">
          <div className={`sync-indicator ${sync.githubStatus}`}><span className="status-dot" /><span>{sync.githubStatus === "synced" ? "GitHub up to date" : sync.githubStatus === "pending" ? "Saved to cloud · GitHub pending" : sync.githubStatus === "external-change" ? "GitHub changed outside PKMS" : "Sync needs attention"}</span></div>
          <div className="account-row"><img src={user.avatarUrl} alt="" /><span>@{user.login}</span><button className="icon-button logout-button" title="Sign out" onClick={() => void api("/api/logout", { method: "POST" }).then(() => window.location.reload())}>↪</button></div>
        </div>
      </aside>

      <section className="main-panel">
        <header className="topbar">
          <div className="breadcrumbs"><span>{activeWorkspace?.repository ?? "No workspace"}</span>{activeFile && <><span className="crumb-slash">/</span><span>{activeFile.path}</span></>}</div>
          <div className="topbar-right">
            <span className={`save-label ${saving ? "active" : ""}`}><span className="status-dot" />{saving ? "Saving…" : notice || (sync.githubStatus === "synced" ? "All changes saved" : "Saved to cloud")}</span>
            <div className="collaborators" aria-label="Collaborators"><img src={user.avatarUrl} alt={user.login} /><span>{peers.length > 1 ? `${peers.length} here` : "Just you"}</span></div>
          </div>
        </header>
        {error && <button className="notice error dismissible" onClick={() => setError("")}>{error}<span>×</span></button>}
        {showRepositories && <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) setShowRepositories(false); }}><section className="repository-modal">
          <button className="modal-close" onClick={() => setShowRepositories(false)}>×</button><span className="eyebrow">GITHUB</span><h2>Choose a repository</h2><p>PKMS will create a workspace from the repository’s default branch.</p>
          <div className="repository-list">{repositories.map((repository) => <button key={repository.fullName} className="repository-option" onClick={() => void connectRepository(repository)}><span className="repo-icon">{repository.private ? "◈" : "◇"}</span><span><strong>{repository.fullName}</strong><small>{repository.defaultBranch} · {repository.private ? "Private" : "Public"}</small></span><span className="option-arrow">→</span></button>)}{!repositories.length && <p className="empty-hint">No writable repositories found.</p>}</div>
        </section></div>}
        {!activeWorkspace ? <div className="empty-workspace"><div className="empty-illustration">⌘</div><h2>Connect your notes</h2><p>Choose a GitHub repository to open it as your PKMS workspace.</p><button className="primary-button" onClick={openRepositoryPicker}>Choose repository</button></div> : !activeFile ? <div className="empty-workspace"><div className="empty-illustration">✎</div><h2>Your workspace is ready</h2><p>Open a Markdown file, or create a note to start writing.</p><button className="primary-button" onClick={newNote}>Create a note</button></div> : activeFile.kind === "markdown" ? <div className="editor-layout">
          <div className="editor-heading"><span className="eyebrow">MARKDOWN</span><h1>{activeFile.path.split("/").at(-1)?.replace(/\.md$/i, "")}</h1><div className="live-presence"><span className="status-dot green" /> Live collaboration enabled</div></div>
          <div className="editor-columns"><div className="source-column"><div className="column-label">EDITOR</div><textarea className="markdown-editor" aria-label="Markdown editor" spellCheck autoCapitalize="sentences" value={text} onChange={(event) => handleText(event.target.value)} placeholder="Start writing in Markdown…" /></div><div className="preview-column"><div className="column-label">PREVIEW</div><article className="markdown-preview"><ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown></article></div></div>
        </div> : <div className="asset-view"><div className="file-icon large">◇</div><h2>{activeFile.path.split("/").at(-1)}</h2><p>{activeFile.size ? `${(activeFile.size / 1024).toFixed(1)} KB` : "Attachment"}</p><a className="primary-button" href={`/api/workspaces/${activeWorkspace.id}/assets/${activeFile.id}`} target="_blank" rel="noreferrer">Open file</a></div>}
        {sync.githubStatus === "external-change" && <div className="external-warning"><strong>GitHub branch changed outside PKMS.</strong><span>PKMS paused its commit so it won’t overwrite that change. {sync.message}</span></div>}
      </section>
    </main>
  );
}

function GitHubIcon() {
  return <svg aria-hidden="true" viewBox="0 0 24 24"><path fill="currentColor" d="M12 .9a11.1 11.1 0 0 0-3.51 21.63c.56.1.76-.24.76-.54v-2.1c-3.1.67-3.76-1.31-3.76-1.31-.51-1.3-1.25-1.65-1.25-1.65-1.02-.7.08-.69.08-.69 1.13.08 1.73 1.16 1.73 1.16 1 .1.12.1.2.09.1-.78.39-1.3.71-1.6-2.48-.28-5.09-1.24-5.09-5.52 0-1.22.44-2.22 1.16-3-.12-.28-.5-1.42.1-2.96 0 0 .95-.3 3.05 1.15a10.6 10.6 0 0 1 5.55 0c2.1-1.43 3.04-1.15 3.04-1.15.61 1.54.23 2.68.12 2.96.72.78 1.15 1.78 1.15 3 0 4.3-2.61 5.24-5.1 5.51.4.35.76 1.03.76 2.08v3.08c0 .3.2.65.77.54A11.1 11.1 0 0 0 12 .9Z" /></svg>;
}
