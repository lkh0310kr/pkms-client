import { lazy, Suspense, useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import { IndexeddbPersistence } from "y-indexeddb";
import * as Y from "yjs";
import { useSearchParams } from "react-router";
import type { Route } from "./+types/home";

const MarkdownCodeEditor = lazy(() => import("../components/MarkdownCodeEditor").then((module) => ({ default: module.MarkdownCodeEditor })));

interface User { login: string; avatarUrl?: string }
interface Repository { fullName: string; defaultBranch: string; private: boolean; canWrite: boolean }
interface Workspace { id: string; repository: string; branch: string; revision: number; githubStatus: string; message?: string }
interface FileRecord { id: string; path: string; kind: "markdown" | "asset" | "folder"; content?: string; size?: number; revision?: number }
interface SyncStatus { githubStatus: string; pendingFiles: number; message?: string; lastGitHubCommitAt?: string; nextGitHubFlushAt?: number }
interface RealtimeMessage { type: string; fileId?: string; update?: string; operationId?: string; acceptedRevision?: number; conflictCopyPath?: string; revision?: number; message?: string; code?: string }
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

function parentPath(path: string): string {
  const separator = path.lastIndexOf("/");
  return separator < 0 ? "" : path.slice(0, separator);
}

function entryName(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

function matchesExcludePattern(path: string, pattern: string): boolean {
  const normalized = pattern.trim().replace(/^\/+|\/+$/g, "");
  if (!normalized) return false;
  const escape = (value: string) => value.replace(/[|\\{}()[\]^$+?.]/g, "\\$&").replace(/\*/g, "\\*?");
  const source = normalized.split("**").map(escape).join(".*").replace(/\\\*\?/g, "[^/]*");
  const expression = new RegExp(normalized.includes("/") ? `^${source}$` : `(^|/)${source}$`);
  const segments = path.split("/");
  return segments.some((_, index) => expression.test(segments.slice(0, index + 1).join("/")) || expression.test(segments[index]));
}

interface TreeRow { file: FileRecord; depth: number }
function flattenTree(files: FileRecord[], expanded: Set<string>): TreeRow[] {
  const children = new Map<string, FileRecord[]>();
  for (const file of files) {
    const parent = parentPath(file.path);
    const siblings = children.get(parent) ?? [];
    siblings.push(file);
    children.set(parent, siblings);
  }
  const rows: TreeRow[] = [];
  const visit = (parent: string, depth: number) => {
    const siblings = children.get(parent) ?? [];
    siblings.sort((a, b) => Number(b.kind === "folder") - Number(a.kind === "folder") || entryName(a.path).localeCompare(entryName(b.path), undefined, { sensitivity: "base" }));
    for (const file of siblings) {
      rows.push({ file, depth });
      if (file.kind === "folder" && expanded.has(file.path)) visit(file.path, depth + 1);
    }
  };
  visit("", 0);
  return rows;
}

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
  const [currentFolder, setCurrentFolder] = useState("");
  const [files, setFiles] = useState<FileRecord[]>([]);
  const [loadingFolder, setLoadingFolder] = useState(false);
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(() => new Set([""]));
  const [loadedFolders, setLoadedFolders] = useState<Set<string>>(() => new Set());
  const [focusedTreePath, setFocusedTreePath] = useState<string | null>(null);
  const [showHiddenFiles, setShowHiddenFiles] = useState(false);
  const [excludedPatterns, setExcludedPatterns] = useState("");
  const [showFileFilters, setShowFileFilters] = useState(false);
  const [outlineOpen, setOutlineOpen] = useState(false);
  const [mobileExplorerOpen, setMobileExplorerOpen] = useState(true);
  const [activeFile, setActiveFile] = useState<FileRecord | null>(null);
  const [openTabs, setOpenTabs] = useState<FileRecord[]>([]);
  const [quickOpen, setQuickOpen] = useState(false);
  const [quickQuery, setQuickQuery] = useState("");
  const [text, setText] = useState("");
  const [sync, setSync] = useState<SyncStatus>({ githubStatus: "pending", pendingFiles: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [searchParams, setSearchParams] = useSearchParams();
  const [showRepositories, setShowRepositories] = useState(false);
  const [saving, setSaving] = useState(false);
  const [peers, setPeers] = useState<Peer[]>([]);
  const socket = useRef<WebSocket | null>(null);
  const treeRef = useRef<HTMLElement>(null);
  const quickOpenInput = useRef<HTMLInputElement>(null);
  const editorNavigate = useRef<((line: number) => void) | null>(null);
  const openFileRef = useRef<((file: FileRecord) => Promise<void>) | null>(null);
  const docs = useRef(new Map<string, { doc: Y.Doc; persistence: IndexeddbPersistence; observer?: () => void; updateHandler?: (update: Uint8Array, origin: unknown) => void }>());
  const activeRef = useRef<{ file: FileRecord | null; doc: Y.Doc | null; text: Y.Text | null; value: string }>({ file: null, doc: null, text: null, value: "" });
  const pending = useRef(new Map<string, RealtimeMessage>());
  const hydrating = useRef(false);
  const autoSaveTimers = useRef(new Map<string, number>());
  const registerEditorNavigator = useCallback((navigate: ((line: number) => void) | null) => { editorNavigate.current = navigate; }, []);

  useEffect(() => {
    if (!activeWorkspace) return;
    setShowHiddenFiles(localStorage.getItem(`pkms:show-hidden:${activeWorkspace.id}`) === "true");
    setExcludedPatterns(localStorage.getItem(`pkms:excluded-files:${activeWorkspace.id}`) ?? "");
    setShowFileFilters(false);
  }, [activeWorkspace?.id]);

  const clearActiveFile = () => {
    const current = activeRef.current;
    if (current.file && current.text) {
      const entry = docs.current.get(current.file.id);
      if (entry?.observer) current.text.unobserve(entry.observer);
      if (entry) entry.observer = undefined;
    }
    activeRef.current = { file: null, doc: null, text: null, value: "" };
    setActiveFile(null);
    setText("");
  };

  const api = useCallback(async <T,>(path: string, init?: RequestInit): Promise<T> => {
    const response = await fetch(path, { credentials: "same-origin", ...init });
    if (!response.ok) {
      const body = await response.json().catch(() => ({})) as { message?: string; error?: string };
      const requestId = response.headers.get("X-Request-ID") ?? (body as { requestId?: string }).requestId;
      const message = body.message ?? body.error ?? `Request failed (${response.status})`;
      throw new Error(`${message}${requestId ? ` · ${requestId}` : ""}`);
    }
    if (response.status === 204) return undefined as T;
    return response.json() as Promise<T>;
  }, []);

  const saveMarkdownToGitHub = useCallback(async (fileId: string, doc: Y.Doc) => {
    const workspaceId = activeWorkspace?.id;
    if (!workspaceId) return;
    setSaving(true);
    setError("");
    try {
      await api(`/api/workspaces/${workspaceId}/files/${fileId}/updates`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: id(), fileId, update: toBase64(Y.encodeStateAsUpdate(doc)) }),
      });
      const status = await api<SyncStatus>(`/api/workspaces/${workspaceId}/flush`, { method: "POST" });
      if (activeRef.current.file?.id === fileId && activeWorkspace?.id === workspaceId) {
        setSync(status);
        if (status.githubStatus === "synced") setNotice("Saved to GitHub");
        else if (status.githubStatus === "external-change") setError(status.message ?? "GitHub changed outside PKMS.");
        else setNotice("Saved locally");
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save to GitHub");
    } finally { setSaving(false); }
  }, [activeWorkspace?.id, api]);

  const scheduleAutoSave = useCallback((fileId: string, doc: Y.Doc) => {
    const workspaceId = activeWorkspace?.id;
    if (!workspaceId) return;
    const key = `${workspaceId}:${fileId}`;
    setNotice("Unsaved");
    const previous = autoSaveTimers.current.get(key);
    if (previous !== undefined) window.clearTimeout(previous);
    const timer = window.setTimeout(() => {
      autoSaveTimers.current.delete(key);
      void saveMarkdownToGitHub(fileId, doc);
    }, 5_000);
    autoSaveTimers.current.set(key, timer);
  }, [saveMarkdownToGitHub]);

  const saveActiveFileNow = useCallback(() => {
    const current = activeRef.current;
    if (!current.file || current.file.kind !== "markdown" || !current.doc) return;
    const key = `${activeWorkspace?.id}:${current.file.id}`;
    const timer = autoSaveTimers.current.get(key);
    if (timer !== undefined) window.clearTimeout(timer);
    autoSaveTimers.current.delete(key);
    void saveMarkdownToGitHub(current.file.id, current.doc);
  }, [saveMarkdownToGitHub]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "p" && activeWorkspace) {
        event.preventDefault();
        setQuickQuery("");
        setQuickOpen(true);
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s" && activeRef.current.file?.kind === "markdown") {
        event.preventDefault();
        saveActiveFileNow();
      }
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [activeWorkspace, saveActiveFileNow]);

  useEffect(() => { if (quickOpen) quickOpenInput.current?.focus(); }, [quickOpen]);

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
    const reason = searchParams.get("auth_error");
    if (!reason) return;
    const requestId = searchParams.get("request_id");
    const messages: Record<string, string> = {
      github_access_denied: "GitHub access was declined.",
      github_account_not_allowed: "This GitHub account is not allowed.",
      github_authorization_failed: "GitHub authorization failed.",
      invalid_oauth_state: "Sign-in expired. Try again.",
      github_code_rejected: "GitHub rejected the sign-in code.",
      github_token_missing: "GitHub did not return an access token.",
      github_user_lookup_failed: "Could not read the GitHub account.",
      github_credentials_store_failed: "Could not save GitHub credentials.",
      session_create_failed: "Could not create a session.",
      github_token_exchange_failed: "Could not exchange the GitHub sign-in code.",
      oauth_callback_internal_error: "GitHub sign-in failed. Check the request log.",
    };
    setError(`${messages[reason] ?? "GitHub sign-in failed."}${requestId ? ` · ${requestId}` : ""}`);
    const next = new URLSearchParams(searchParams);
    next.delete("auth_error");
    next.delete("request_id");
    setSearchParams(next, { replace: true });
  }, [searchParams, setSearchParams]);

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
        if (message.conflictCopyPath) {
          void api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`).then(async (snapshot) => {
            setFiles(snapshot.files);
            const conflict = snapshot.files.find((file) => file.path === message.conflictCopyPath);
            if (conflict) await openFileRef.current?.(conflict);
          }).catch(() => {});
        }
      } else if (message.type === "error") {
        setError(message.message ?? "Collaboration sync failed");
      } else if (typeof message.acceptedRevision === "number") {
        void api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`).then(async (snapshot) => {
          setFiles(snapshot.files);
          if (message.conflictCopyPath) {
            const conflict = snapshot.files.find((file) => file.path === message.conflictCopyPath);
            if (conflict) await openFileRef.current?.(conflict);
          }
        }).catch(() => {});
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
        setLoadingFolder(true);
        const result = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/directory`);
        if (!alive) return;
        const storageKey = `pkms:tree:${activeWorkspace.id}`;
        let saved: { expanded?: string[]; currentFolder?: string; scrollTop?: number } = {};
        try { saved = JSON.parse(localStorage.getItem(storageKey) ?? "{}"); } catch { saved = {}; }
        const expanded = [...new Set(["", ...(saved.expanded ?? [])])];
        const restored = await Promise.allSettled(expanded.filter(Boolean).map((path) => api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/directory?path=${encodeURIComponent(path)}`)));
        if (!alive) return;
        const restoredFiles = restored.flatMap((entry) => entry.status === "fulfilled" ? entry.value.files : []);
        const loaded = new Set(["", ...expanded.filter((path, index) => index > 0 && restored[index - 1]?.status === "fulfilled")]);
        setFiles([...result.files, ...restoredFiles]);
        setCurrentFolder(saved.currentFolder ?? "");
        setExpandedFolders(new Set(expanded));
        setLoadedFolders(loaded);
        setFocusedTreePath(null);
        setLoadingFolder(false);
        requestAnimationFrame(() => { if (treeRef.current) treeRef.current.scrollTop = saved.scrollTop ?? 0; });
        const state = await api<SyncStatus>(`/api/workspaces/${activeWorkspace.id}/sync-status`);
        if (alive) setSync(state);
      } catch (cause) { if (alive) { setLoadingFolder(false); setError(cause instanceof Error ? cause.message : "Could not load workspace"); } }
    };
    void loadSnapshot();
    const timer = window.setInterval(() => {
      void api<SyncStatus>(`/api/workspaces/${activeWorkspace.id}/sync-status`).then(setSync).catch(() => {});
    }, 15_000);
    return () => { alive = false; window.clearInterval(timer); window.clearTimeout(retryTimer); socket.current?.close(); socket.current = null; setPeers([]); };
  }, [activeWorkspace, api, user]);

  useEffect(() => {
    if (!activeWorkspace || !loadedFolders.has("")) return;
    localStorage.setItem(`pkms:tree:${activeWorkspace.id}`, JSON.stringify({ expanded: [...expandedFolders].filter(Boolean), currentFolder }));
  }, [activeWorkspace?.id, currentFolder, expandedFolders, loadedFolders]);

  const openFile = useCallback(async (file: FileRecord) => {
    setNotice("");
    if (window.matchMedia("(max-width: 580px)").matches) setMobileExplorerOpen(false);
    const parent = parentPath(file.path);
    setCurrentFolder(parent);
    setExpandedFolders((current) => {
      const next = new Set(current).add("");
      let ancestor = parent;
      while (ancestor) { next.add(ancestor); ancestor = parentPath(ancestor); }
      return next;
    });
    setOpenTabs((current) => current.some((entry) => entry.id === file.id) ? current.map((entry) => entry.id === file.id ? file : entry) : [...current, file]);
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
      scheduleAutoSave(file.id, entry.doc);
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
  }, [activeWorkspace?.id, api, scheduleAutoSave]);
  openFileRef.current = openFile;

  const toggleFolder = async (file: FileRecord) => {
    if (!activeWorkspace) return;
    setCurrentFolder(file.path);
    setFocusedTreePath(file.path);
    if (expandedFolders.has(file.path)) {
      setExpandedFolders((current) => { const next = new Set(current); next.delete(file.path); return next; });
      return;
    }
    setExpandedFolders((current) => new Set(current).add(file.path));
    if (loadedFolders.has(file.path)) return;
    setLoadingFolder(true);
    try {
      const result = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/directory?path=${encodeURIComponent(file.path)}`);
      setFiles((current) => [...current.filter((entry) => parentPath(entry.path) !== file.path), ...result.files]);
      setLoadedFolders((current) => new Set(current).add(file.path));
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not open folder"); }
    finally { setLoadingFolder(false); }
  };

  const chooseWorkspace = (workspace: Workspace) => {
    setActiveWorkspace(workspace); clearActiveFile(); setOpenTabs([]); setCurrentFolder(""); setExpandedFolders(new Set([""])); setLoadedFolders(new Set());
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
      clearActiveFile(); setOpenTabs([]); setCurrentFolder(""); setExpandedFolders(new Set([""])); setLoadedFolders(new Set());
      await refreshWorkspaces();
      setActiveWorkspace(result.workspace);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not connect repository"); }
  };

  const newNote = async () => {
    if (!activeWorkspace) return;
    const path = `${currentFolder ? `${currentFolder}/` : ""}Untitled ${new Date().toLocaleString("sv-SE").replaceAll(":", "-")}.md`;
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
    const name = window.prompt("New folder");
    if (!name?.trim()) return;
    try {
      await api(`/api/workspaces/${activeWorkspace.id}/operations`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: `web-${id()}`, operation: { type: "create-folder", path: `${currentFolder ? `${currentFolder}/` : ""}${name.trim()}` } }) });
      const snapshot = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
      setFiles(snapshot.files);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not create folder"); }
  };

  const uploadFile = async (file?: File) => {
    if (!file || !activeWorkspace) return;
    const form = new FormData(); form.set("file", file); form.set("path", `${currentFolder ? `${currentFolder}/` : ""}${file.name}`); form.set("clientId", `web-${id()}`);
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

  const visibleFiles = files.filter((file) =>
    (showHiddenFiles || !file.path.split("/").some((part) => part.startsWith("."))) &&
    !excludedPatterns.split("\n").some((pattern) => matchesExcludePattern(file.path, pattern))
  );
  const treeRows = flattenTree(visibleFiles, expandedFolders);
  const outlineItems = text.split("\n").flatMap((line, index) => {
    const heading = /^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    return heading ? [{ line: index + 1, level: heading[1].length, title: heading[2] }] : [];
  });
  const parentFolder = parentPath(currentFolder);
  const persistTreeScroll = (scrollTop: number) => {
    if (!activeWorkspace) return;
    const key = `pkms:tree:${activeWorkspace.id}`;
    let saved: Record<string, unknown> = {};
    try { saved = JSON.parse(localStorage.getItem(key) ?? "{}"); } catch { saved = {}; }
    localStorage.setItem(key, JSON.stringify({ ...saved, scrollTop }));
  };

  const handleTreeKeyDown = (event: ReactKeyboardEvent<HTMLElement>) => {
    const index = treeRows.findIndex((row) => row.file.path === focusedTreePath);
    const row = treeRows[index];
    if (!row) return;
    const focusRow = (next: TreeRow | undefined) => {
      if (!next) return;
      setFocusedTreePath(next.file.path);
      requestAnimationFrame(() => treeRef.current?.querySelector<HTMLElement>(`[data-tree-path="${CSS.escape(next.file.path)}"]`)?.focus());
    };
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      focusRow(treeRows[index + (event.key === "ArrowDown" ? 1 : -1)]);
    } else if (event.key === "ArrowRight" && row.file.kind === "folder") {
      event.preventDefault();
      if (!expandedFolders.has(row.file.path)) void toggleFolder(row.file);
      else if (treeRows[index + 1]?.depth === row.depth + 1) focusRow(treeRows[index + 1]);
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      if (row.file.kind === "folder" && expandedFolders.has(row.file.path)) void toggleFolder(row.file);
      else focusRow(treeRows.find((candidate) => candidate.file.path === parentPath(row.file.path)));
    } else if (event.key === "Enter") {
      event.preventDefault();
      if (row.file.kind === "folder") void toggleFolder(row.file);
      else void openFile(row.file);
    }
  };

  const closeTab = (file: FileRecord) => {
    const index = openTabs.findIndex((entry) => entry.id === file.id);
    const nextTabs = openTabs.filter((entry) => entry.id !== file.id);
    setOpenTabs(nextTabs);
    if (activeFile?.id === file.id) {
      const nextFile = nextTabs[Math.min(index, nextTabs.length - 1)];
      if (nextFile) void openFile(nextFile);
      else clearActiveFile();
    }
  };

  const quickOpenResults = [...new Map([...visibleFiles, ...openTabs].filter((file) => file.kind !== "folder").map((file) => [file.id, file])).values()]
    .filter((file) => !quickQuery.trim() || file.path.toLocaleLowerCase().includes(quickQuery.trim().toLocaleLowerCase()))
    .slice(0, 30);

  const updateFilePath = async (file: FileRecord, toPath: string) => {
    if (!activeWorkspace) return;
    try {
      const result = await api<{ conflictCopyPath?: string }>(`/api/workspaces/${activeWorkspace.id}/operations`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: `web-${id()}`, operation: { type: "move", fileId: file.id, toPath } }),
      });
      const snapshot = await api<{ files: FileRecord[] }>(`/api/workspaces/${activeWorkspace.id}/snapshot`);
      setFiles(snapshot.files);
      setOpenTabs((current) => current.map((tab) => snapshot.files.find((entry) => entry.id === tab.id) ?? tab));
      if (activeFile?.id === file.id) setActiveFile(snapshot.files.find((entry) => entry.id === file.id) ?? null);
      const destination = result.conflictCopyPath ?? toPath;
      if (file.kind === "folder" && (currentFolder === file.path || currentFolder.startsWith(`${file.path}/`))) {
        setCurrentFolder(`${destination}${currentFolder.slice(file.path.length)}`);
      }
      if (file.kind === "folder") {
        const movePath = (path: string) => path === file.path || path.startsWith(`${file.path}/`) ? `${destination}${path.slice(file.path.length)}` : path;
        setExpandedFolders((current) => new Set([...current].map(movePath)));
        setLoadedFolders((current) => new Set([...current].map(movePath)));
      }
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not rename item"); }
  };

  const renameActiveFile = () => {
    if (!activeFile) return;
    const name = window.prompt("Rename", entryName(activeFile.path));
    if (!name?.trim() || name.trim() === entryName(activeFile.path)) return;
    const parent = parentPath(activeFile.path);
    void updateFilePath(activeFile, `${parent ? `${parent}/` : ""}${name.trim()}`);
  };

  const renameCurrentFolder = () => {
    const folder = files.find((file) => file.kind === "folder" && file.path === currentFolder);
    if (!folder) return;
    const name = window.prompt("Rename", entryName(currentFolder));
    if (!name?.trim() || name.trim() === entryName(currentFolder)) return;
    void updateFilePath(folder, `${parentPath(currentFolder) ? `${parentPath(currentFolder)}/` : ""}${name.trim()}`);
  };

  const deleteActiveFile = async () => {
    if (!activeWorkspace || !activeFile || !window.confirm(`Delete ${entryName(activeFile.path)}?`)) return;
    try {
      await api(`/api/workspaces/${activeWorkspace.id}/operations`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: `web-${id()}`, operation: { type: "delete", fileId: activeFile.id } }),
      });
      clearActiveFile();
      setOpenTabs((current) => current.filter((file) => file.id !== activeFile.id));
      setFiles((current) => current.filter((file) => file.id !== activeFile.id));
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not delete item"); }
  };

  const deleteCurrentFolder = async () => {
    const folder = files.find((file) => file.kind === "folder" && file.path === currentFolder);
    if (!activeWorkspace || !folder || !window.confirm(`Delete ${entryName(currentFolder)}?`)) return;
    try {
      await api(`/api/workspaces/${activeWorkspace.id}/operations`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: id(), baseRevision: activeWorkspace.revision, clientId: `web-${id()}`, operation: { type: "delete", fileId: folder.id } }),
      });
      setFiles((current) => current.filter((file) => file.path !== currentFolder && !file.path.startsWith(`${currentFolder}/`)));
      setOpenTabs((current) => current.filter((file) => file.path !== currentFolder && !file.path.startsWith(`${currentFolder}/`)));
      setExpandedFolders((current) => new Set([...current].filter((path) => path !== currentFolder && !path.startsWith(`${currentFolder}/`))));
      setCurrentFolder(parentFolder);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not delete folder"); }
  };

  if (loading) return <main className="loading-screen"><div className="brand-mark">P</div><span>Opening your workspace…</span></main>;
  if (!user) return (
    <main className="welcome-screen">
      <div className="welcome-card">
        <h1>Sign in to PKMS</h1>
        {error && <div className="notice error">{error}</div>}
        <a className="primary-button github-button" href="/api/auth/github"><GitHubIcon /> Continue with GitHub</a>
      </div>
    </main>
  );

  return (
    <main className={`app-shell${mobileExplorerOpen ? " mobile-explorer-open" : " mobile-explorer-closed"}`}>
      <aside className="sidebar">
        <div className="sidebar-top">
          <div className="brand-lockup"><div className="brand-mark small">P</div><span>PKMS</span></div>
          <button className="icon-button" title="Add repository" onClick={openRepositoryPicker}><AppIcon name="plus" /></button>
        </div>
        <div className="workspace-select">
          <span className="eyebrow">WORKSPACE</span>
          {workspaces.length ? <select value={activeWorkspace?.id ?? ""} onChange={(event) => { const workspace = workspaces.find((item) => item.id === event.target.value); if (workspace) chooseWorkspace(workspace); }}>
            {workspaces.map((workspace) => <option key={workspace.id} value={workspace.id}>{workspace.repository}</option>)}
          </select> : <button className="connect-link" onClick={openRepositoryPicker}>Connect a repository <span>↗</span></button>}
        </div>
        {activeWorkspace && <>
          <div className="file-toolbar"><span className="eyebrow">FILES</span><div className="toolbar-actions">
            <button className={`mini-button visibility-button${showFileFilters ? " active" : ""}`} title="File visibility settings" aria-label="File visibility settings" aria-expanded={showFileFilters} onClick={() => setShowFileFilters((open) => !open)}><AppIcon name="filter" /></button>
            <button className="mini-button" title="New note" onClick={newNote}><AppIcon name="filePlus" /></button>
            <button className="mini-button" title="New folder" onClick={newFolder}><AppIcon name="folderPlus" /></button>
            <label className="mini-button upload-button" title="Upload file"><AppIcon name="upload" /><input type="file" onChange={(event) => { void uploadFile(event.target.files?.[0]); event.currentTarget.value = ""; }} /></label>
            {activeFile && <button className="mini-button" title="Rename" onClick={renameActiveFile}><AppIcon name="pencil" /></button>}
            {activeFile && <button className="mini-button" title="Delete" onClick={() => void deleteActiveFile()}><AppIcon name="trash" /></button>}
            {!activeFile && currentFolder && <button className="mini-button" title="Rename folder" onClick={renameCurrentFolder}><AppIcon name="pencil" /></button>}
            {!activeFile && currentFolder && <button className="mini-button" title="Delete folder" onClick={() => void deleteCurrentFolder()}><AppIcon name="trash" /></button>}
          </div></div>
          {showFileFilters && <div className="file-filter-panel"><div className="file-filter-heading"><span>Show hidden files</span><button className={`mini-button visibility-button${showHiddenFiles ? " active" : ""}`} aria-pressed={showHiddenFiles} onClick={() => { const next = !showHiddenFiles; setShowHiddenFiles(next); localStorage.setItem(`pkms:show-hidden:${activeWorkspace.id}`, String(next)); }}>{showHiddenFiles ? "On" : "Off"}</button></div><label htmlFor="excluded-files">Exclude paths</label><textarea id="excluded-files" value={excludedPatterns} placeholder={"*.tmp\n**/drafts/**"} spellCheck={false} onChange={(event) => { const next = event.target.value; setExcludedPatterns(next); localStorage.setItem(`pkms:excluded-files:${activeWorkspace.id}`, next); }} /><p>One glob per line</p></div>}
          <nav ref={treeRef} className="file-list file-tree" role="tree" aria-label="Repository files" aria-busy={loadingFolder} onKeyDown={handleTreeKeyDown} onScroll={(event) => persistTreeScroll(event.currentTarget.scrollTop)}>
            {treeRows.map(({ file, depth }, index) => <button
              key={file.id}
              type="button"
              role="treeitem"
              data-tree-path={file.path}
              aria-level={depth + 1}
              aria-expanded={file.kind === "folder" ? expandedFolders.has(file.path) : undefined}
              tabIndex={focusedTreePath === file.path || (!focusedTreePath && index === 0) ? 0 : -1}
              className={`tree-row ${file.kind === "folder" ? "folder-row" : "file-row"}${file.path === currentFolder && file.kind === "folder" ? " selected" : ""}${activeFile?.id === file.id ? " selected" : ""}`}
              style={{ paddingLeft: 8 + depth * 14 }}
              onFocus={() => setFocusedTreePath(file.path)}
              onClick={() => file.kind === "folder" ? void toggleFolder(file) : void openFile(file)}
            >
              <span className={`tree-chevron${expandedFolders.has(file.path) ? " expanded" : ""}`} aria-hidden="true">{file.kind === "folder" && <AppIcon name="chevron" />}</span>
              <span className="file-icon" aria-hidden="true"><AppIcon name={file.kind === "folder" ? "folder" : file.kind === "markdown" ? "fileText" : "file"} /></span>
              <span className="tree-label">{entryName(file.path)}</span>
            </button>)}
            {!treeRows.length && <p className="empty-hint">{loadingFolder ? "Loading…" : "Empty folder"}</p>}
          </nav>
        </>}
        <div className="sidebar-bottom">
          <div className={`sync-indicator ${sync.githubStatus}`}><span className="status-dot" /><span>{sync.githubStatus === "synced" ? "Synced" : sync.githubStatus === "pending" ? "Saving" : sync.githubStatus === "external-change" ? "GitHub changed" : "Sync error"}</span></div>
          <div className="account-row"><img src={user.avatarUrl} alt="" /><span>@{user.login}</span><button className="icon-button logout-button" title="Sign out" onClick={() => void api("/api/logout", { method: "POST" }).then(() => window.location.reload())}><AppIcon name="logout" /></button></div>
        </div>
      </aside>

      <section className="main-panel">
        <header className="topbar">
          <div className="breadcrumbs"><span>{activeWorkspace?.repository ?? "No workspace"}</span>{(activeFile || currentFolder) && <><span className="crumb-slash">/</span><span>{activeFile?.path ?? currentFolder}</span></>}</div>
          <div className="topbar-right">
            <button className="mobile-explorer-toggle" onClick={() => setMobileExplorerOpen((open) => !open)} aria-expanded={mobileExplorerOpen} title="Toggle file tree"><AppIcon name="menu" /> Files</button>
            <span className={`save-label ${saving ? "active" : ""}`}><span className="status-dot" />{saving ? "Saving" : notice || (sync.githubStatus === "synced" ? "Synced" : "Saved")}</span>
            {peers.length > 1 && <div className="collaborators" aria-label="Collaborators"><span>{peers.length} here</span></div>}
          </div>
        </header>
        {!!openTabs.length && <nav className="document-tabs" aria-label="Open documents">{openTabs.map((file) => <div key={file.id} className={`document-tab${activeFile?.id === file.id ? " active" : ""}`}><button className="document-tab-label" onClick={() => void openFile(file)} title={file.path}>{entryName(file.path)}</button><button className="document-tab-close" onClick={() => closeTab(file)} aria-label={`Close ${entryName(file.path)}`}><AppIcon name="close" /></button></div>)}</nav>}
        {error && <button className="notice error dismissible" onClick={() => setError("")}>{error}<AppIcon name="close" /></button>}
        {showRepositories && <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) setShowRepositories(false); }}><section className="repository-modal">
          <button className="modal-close" onClick={() => setShowRepositories(false)} aria-label="Close"><AppIcon name="close" /></button><span className="eyebrow">GITHUB</span><h2>Choose a repository</h2>
          <div className="repository-list">{repositories.map((repository) => <button key={repository.fullName} className="repository-option" onClick={() => void connectRepository(repository)}><span className="repo-icon"><AppIcon name={repository.private ? "lock" : "folder"} /></span><span><strong>{repository.fullName}</strong><small>{repository.defaultBranch} · {repository.private ? "Private" : "Public"}</small></span><span className="option-arrow"><AppIcon name="arrowRight" /></span></button>)}{!repositories.length && <p className="empty-hint">No writable repositories found.</p>}</div>
        </section></div>}
        {quickOpen && <div className="modal-backdrop quick-open-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) setQuickOpen(false); }}><section className="quick-open-modal" role="dialog" aria-modal="true" aria-label="Quick open"><input ref={quickOpenInput} value={quickQuery} onChange={(event) => setQuickQuery(event.target.value)} placeholder="Search open and loaded files…" onKeyDown={(event) => { if (event.key === "Escape") setQuickOpen(false); else if (event.key === "Enter" && quickOpenResults[0]) { void openFile(quickOpenResults[0]); setQuickOpen(false); } }} /><div className="quick-open-results">{quickOpenResults.map((file) => <button key={file.id} onClick={() => { void openFile(file); setQuickOpen(false); }}><span>{entryName(file.path)}</span><small>{file.path}</small></button>)}{!quickOpenResults.length && <p className="empty-hint">No loaded files found</p>}</div></section></div>}
        {!activeWorkspace ? <div className="empty-workspace"><h2>No workspace</h2><button className="primary-button" onClick={openRepositoryPicker}>Connect repository</button></div> : !activeFile ? <div className="empty-workspace"><h2>No file open</h2><button className="primary-button" onClick={newNote}>New note</button></div> : activeFile.kind === "markdown" ? <div className="editor-layout">
          <div className="editor-heading"><div className="editor-title-block"><h1>{activeFile.path.split("/").at(-1)?.replace(/\.md$/i, "")}</h1>{peers.length > 1 && <div className="live-presence">{peers.length} editing</div>}</div><div className="editor-controls"><div className="outline-control"><button className={`mini-button outline-button${outlineOpen ? " active" : ""}`} title="Note outline" aria-label="Note outline" aria-expanded={outlineOpen} onClick={() => setOutlineOpen((open) => !open)}><AppIcon name="list" /></button>{outlineOpen && <div className="outline-popover" role="navigation" aria-label="Note outline">{outlineItems.length ? outlineItems.map((item) => <button key={`${item.line}-${item.title}`} style={{ paddingLeft: 8 + (item.level - 1) * 11 }} title={item.title} onClick={() => { setOutlineOpen(false); requestAnimationFrame(() => editorNavigate.current?.(item.line)); }}>{item.title}</button>) : <span>No headings</span>}</div>}</div><button className="save-button" onClick={saveActiveFileNow} title="Save now (⌘S / Ctrl+S)">Save</button></div></div>
          <div className="editor-columns"><div className="source-column"><Suspense fallback={<div className="editor-loading">Opening editor…</div>}><MarkdownCodeEditor key={activeFile.id} value={text} onChange={handleText} onNavigateReady={registerEditorNavigator} /></Suspense></div></div>
        </div> : <div className="asset-view"><div className="file-icon large"><AppIcon name="file" /></div><h2>{activeFile.path.split("/").at(-1)}</h2><p>{activeFile.size ? `${(activeFile.size / 1024).toFixed(1)} KB` : "Attachment"}</p><a className="primary-button" href={`/api/workspaces/${activeWorkspace.id}/assets/${activeFile.id}`} target="_blank" rel="noreferrer">Open file</a></div>}
        {sync.githubStatus === "external-change" && <div className="external-warning"><strong>GitHub branch changed outside PKMS.</strong><span>PKMS paused its commit so it won’t overwrite that change. {sync.message}</span></div>}
      </section>
    </main>
  );
}

type AppIconName = "plus" | "filter" | "filePlus" | "folderPlus" | "upload" | "pencil" | "trash" | "folder" | "fileText" | "file" | "chevron" | "logout" | "menu" | "lock" | "arrowRight" | "list" | "close";
function AppIcon({ name, className = "" }: { name: AppIconName; className?: string }) {
  const path = {
    plus: <path d="M12 5v14M5 12h14" />,
    filter: <path d="M4 5h16l-6.5 7.3V19l-3 1.5v-8.2L4 5Z" />,
    filePlus: <><path d="M13 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h7M13 3v6h6M13 3l6 6" /><path d="M17 14v7m-3.5-3.5h7" /></>,
    folderPlus: <><path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v3M3 7v11a2 2 0 0 0 2 2h8" /><path d="M18 14v7m-3.5-3.5h7" /></>,
    upload: <><path d="M12 16V4m-4 4 4-4 4 4" /><path d="M5 14v5h14v-5" /></>,
    pencil: <><path d="m4 16.5-.8 4.3 4.3-.8L19 8.5 15.5 5 4 16.5Z" /><path d="m13.8 6.7 3.5 3.5" /></>,
    trash: <><path d="M4 7h16M10 11v6m4-6v6M6 7l1 14h10l1-14M9 7V4h6v3" /></>,
    folder: <path d="M3 6.5a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-11Z" />,
    fileText: <><path d="M13 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9l-7-6Z" /><path d="M13 3v6h7M8 13h8m-8 4h8" /></>,
    file: <><path d="M13 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9l-7-6Z" /><path d="M13 3v6h7" /></>,
    chevron: <path d="m9 18 6-6-6-6" />,
    logout: <><path d="M10 17l5-5-5-5m5 5H3" /><path d="M13 4h5a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-5" /></>,
    menu: <><path d="M4 6h16M4 12h16M4 18h16" /></>,
    lock: <><rect x="4" y="10" width="16" height="11" rx="2" /><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 5v2" /></>,
    arrowRight: <><path d="M4 12h15m-6-6 6 6-6 6" /></>,
    list: <><path d="M9 6h11M9 12h11M9 18h11" /><path d="M4 6h.01M4 12h.01M4 18h.01" /></>,
    close: <path d="m6 6 12 12M18 6 6 18" />,
  } satisfies Record<AppIconName, ReactNode>;
  return <svg className={`app-icon ${className}`} viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{path[name]}</svg>;
}

function GitHubIcon() {
  return <svg aria-hidden="true" viewBox="0 0 24 24"><path fill="currentColor" d="M12 .9a11.1 11.1 0 0 0-3.51 21.63c.56.1.76-.24.76-.54v-2.1c-3.1.67-3.76-1.31-3.76-1.31-.51-1.3-1.25-1.65-1.25-1.65-1.02-.7.08-.69.08-.69 1.13.08 1.73 1.16 1.73 1.16 1 .1.12.1.2.09.1-.78.39-1.3.71-1.6-2.48-.28-5.09-1.24-5.09-5.52 0-1.22.44-2.22 1.16-3-.12-.28-.5-1.42.1-2.96 0 0 .95-.3 3.05 1.15a10.6 10.6 0 0 1 5.55 0c2.1-1.43 3.04-1.15 3.04-1.15.61 1.54.23 2.68.12 2.96.72.78 1.15 1.78 1.15 3 0 4.3-2.61 5.24-5.1 5.51.4.35.76 1.03.76 2.08v3.08c0 .3.2.65.77.54A11.1 11.1 0 0 0 12 .9Z" /></svg>;
}
