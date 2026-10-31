import { DurableObject } from "cloudflare:workers";
import * as Y from "yjs";
import type { Env, WorkspaceRecord } from "./env";
import { json } from "./crypto";

const FLUSH_AFTER_MS = 15 * 60 * 1000;
const MAX_GIT_FILE_BYTES = 50 * 1024 * 1024;
const MAX_MARKDOWN_BYTES = 512 * 1024;
const encoder = new TextEncoder();

interface MetaRow { [key: string]: SqlStorageValue; key: string; value: string }
interface FileRow {
  [key: string]: SqlStorageValue;
  file_id: string; path: string; kind: string; content: string | null; object_key: string | null;
  size: number; sha: string | null; previous_path: string | null; revision: number; deleted: number; dirty: number;
}
interface RefResponse { object: { sha: string } }
interface TreeResponse { sha: string; tree: Array<{ path: string; mode: string; type: string; sha: string; size?: number }>; truncated: boolean }

function asBytes(value: ArrayBuffer | Uint8Array): Uint8Array {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}

function b64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromB64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
}

function validPath(value: string): boolean {
  return value.length > 0 && value.length <= 1024 && !value.startsWith("/") && !value.includes("\\") &&
    value.split("/").every((part) => part && part !== "." && part !== ".." && ![...part].some((c) => c.charCodeAt(0) < 32));
}

function isMarkdown(path: string): boolean { return /\.md$/i.test(path); }

function conflictName(path: string, client: string): string {
  const suffix = ` (conflict ${client.slice(0, 8)})`;
  const slash = path.lastIndexOf("/");
  const dot = path.lastIndexOf(".");
  if (dot > slash) return `${path.slice(0, dot)}${suffix}${path.slice(dot)}`;
  return `${path}${suffix}`;
}

export class VaultRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS files (
        file_id TEXT PRIMARY KEY, path TEXT NOT NULL, kind TEXT NOT NULL,
        content TEXT, object_key TEXT, size INTEGER NOT NULL DEFAULT 0, sha TEXT, previous_path TEXT,
        revision INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS documents (file_id TEXT PRIMARY KEY, state_update BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, result TEXT NOT NULL);
      CREATE UNIQUE INDEX IF NOT EXISTS active_file_paths ON files (path) WHERE deleted = 0;
    `);
  }

  private getMeta(key: string): string | undefined {
    return this.ctx.storage.sql.exec<MetaRow>("SELECT key, value FROM meta WHERE key = ?", key).toArray()[0]?.value;
  }

  private setMeta(key: string, value: string): void {
    this.ctx.storage.sql.exec("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  private files(includeDeleted = false): FileRow[] {
    return this.ctx.storage.sql.exec<FileRow>(
      `SELECT * FROM files ${includeDeleted ? "" : "WHERE deleted = 0"} ORDER BY path COLLATE NOCASE`
    ).toArray();
  }

  private file(fileId: string): FileRow | undefined {
    return this.ctx.storage.sql.exec<FileRow>("SELECT * FROM files WHERE file_id = ? AND deleted = 0", fileId).toArray()[0];
  }

  private fileIncludingDeleted(fileId: string): FileRow | undefined {
    return this.ctx.storage.sql.exec<FileRow>("SELECT * FROM files WHERE file_id = ?", fileId).toArray()[0];
  }

  private async github(token: string, path: string, init: RequestInit = {}): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set("Authorization", `Bearer ${token}`);
    headers.set("Accept", headers.get("Accept") ?? "application/vnd.github+json");
    headers.set("X-GitHub-Api-Version", "2022-11-28");
    headers.set("User-Agent", "PKMS-Cloud/1.0");
    const response = await fetch(`https://api.github.com${path}`, { ...init, headers });
    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`GitHub API ${response.status}: ${detail.slice(0, 500)}`);
    }
    return response;
  }

  private async token(): Promise<string> {
    const login = this.getMeta("accountLogin");
    if (!login) throw new Error("GitHub credentials are missing; reconnect this workspace.");
    const account = this.env.ACCOUNTS.get(this.env.ACCOUNTS.idFromName(login.toLowerCase()));
    const response = await account.fetch("https://account/credentials/access-token");
    if (!response.ok) throw new Error((await response.json() as { message?: string }).message ?? "GitHub authorization expired; sign in again.");
    return (await response.json() as { accessToken: string }).accessToken;
  }

  private async initialize(body: { repository: string; branch: string; accountLogin: string }): Promise<Response> {
    if (!body.accountLogin) return json({ error: "github_account_required" }, { status: 400 });
    if (this.getMeta("repository")) {
      this.setMeta("accountLogin", body.accountLogin);
      return json({ ok: true, alreadyInitialized: true });
    }
    const [owner, repo] = body.repository.split("/");
    if (!owner || !repo || body.repository.split("/").length !== 2) return json({ error: "invalid_repository" }, { status: 400 });
    this.setMeta("accountLogin", body.accountLogin);
    try {
      const token = await this.token();
      const refPath = `/repos/${owner}/${repo}/git/ref/heads/${body.branch.split("/").map(encodeURIComponent).join("/")}`;
      const ref = await (await this.github(token, refPath)).json() as RefResponse;
      const commit = await (await this.github(token, `/repos/${owner}/${repo}/git/commits/${ref.object.sha}`)).json() as { tree: { sha: string } };
      const tree = await (await this.github(token, `/repos/${owner}/${repo}/git/trees/${commit.tree.sha}?recursive=1`)).json() as TreeResponse;
      if (tree.truncated) return json({ error: "repository_tree_too_large" }, { status: 413 });
      for (const entry of tree.tree) {
        if (entry.type !== "blob" || !["100644", "100755"].includes(entry.mode)) continue;
        if (!validPath(entry.path)) continue;
        if ((entry.size ?? 0) > MAX_GIT_FILE_BYTES) throw new Error(`${entry.path} exceeds the PKMS 50 MiB file limit.`);
        if (isMarkdown(entry.path) && (entry.size ?? 0) > MAX_MARKDOWN_BYTES) throw new Error(`${entry.path} exceeds the PKMS 512 KiB Markdown limit.`);
        const fileId = await this.stableFileId(body.repository, entry.path);
        this.ensureParents(entry.path, false);
        const markdown = isMarkdown(entry.path);
        let content: string | null = null;
        let objectKey: string | null = null;
        if (markdown) {
          const response = await this.github(token, `/repos/${owner}/${repo}/git/blobs/${entry.sha}`, { headers: { Accept: "application/vnd.github.raw+json" } });
          const raw = await response.arrayBuffer();
          content = new TextDecoder("utf-8", { fatal: true }).decode(raw);
          const doc = new Y.Doc({ guid: fileId });
          doc.getText("markdown").insert(0, content);
          this.saveDocument(fileId, Y.encodeStateAsUpdate(doc));
        } else {
          objectKey = `${this.ctx.id.toString()}/${fileId}`;
          const response = await this.github(token, `/repos/${owner}/${repo}/git/blobs/${entry.sha}`, { headers: { Accept: "application/vnd.github.raw+json" } });
          const raw = response.body ?? await response.arrayBuffer();
          await this.env.ASSET_BUCKET.put(objectKey, raw);
        }
        this.ctx.storage.sql.exec(
          "INSERT OR IGNORE INTO files (file_id,path,kind,content,object_key,size,sha,revision,deleted,dirty) VALUES (?,?,?,?,?,?,?,?,0,0)",
          fileId, entry.path, markdown ? "markdown" : "asset", content, objectKey, entry.size ?? 0, entry.sha, 0
        );
      }
      this.setMeta("repository", body.repository);
      this.setMeta("branch", body.branch);
      this.setMeta("head", ref.object.sha);
      this.setMeta("tree", commit.tree.sha);
      this.setMeta("revision", "0");
      this.setMeta("githubStatus", "synced");
      return json({ ok: true, head: ref.object.sha });
    } catch (error) {
      this.setMeta("githubStatus", "failed");
      this.setMeta("githubMessage", error instanceof Error ? error.message : "initial import failed");
      return json({ error: "github_import_failed", message: this.getMeta("githubMessage") }, { status: 502 });
    }
  }

  private async stableFileId(repository: string, path: string): Promise<string> {
    const bytes = await crypto.subtle.digest("SHA-256", encoder.encode(`${repository}\0${path}`));
    return [...new Uint8Array(bytes)].map((value) => value.toString(16).padStart(2, "0")).join("").slice(0, 32);
  }

  private saveDocument(fileId: string, update: Uint8Array): void {
    this.ctx.storage.sql.exec(
      "INSERT INTO documents (file_id, state_update) VALUES (?, ?) ON CONFLICT(file_id) DO UPDATE SET state_update = excluded.state_update",
      fileId, update.slice().buffer as ArrayBuffer
    );
  }

  private document(fileId: string): Y.Doc {
    const doc = new Y.Doc({ guid: fileId });
    const row = this.ctx.storage.sql.exec<{ [key: string]: SqlStorageValue; state_update: ArrayBuffer }>("SELECT state_update FROM documents WHERE file_id = ?", fileId).toArray()[0];
    if (row) Y.applyUpdate(doc, asBytes(row.state_update));
    return doc;
  }

  private nextRevision(): number {
    const revision = Number(this.getMeta("revision") ?? "0") + 1;
    this.setMeta("revision", String(revision));
    this.setMeta("githubStatus", "pending");
    return revision;
  }

  private async scheduleFlush(): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    const dirty = this.ctx.storage.sql.exec<{ count: number; bytes: number }>("SELECT COUNT(*) AS count, COALESCE(SUM(size),0) AS bytes FROM files WHERE deleted = 1 OR dirty = 1").toArray()[0];
    const due = dirty && (dirty.count >= 100 || dirty.bytes >= 5 * 1024 * 1024) ? Date.now() + 1_000 : Date.now() + FLUSH_AFTER_MS;
    if (current === null || due < current) await this.ctx.storage.setAlarm(due);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/initialize" && request.method === "POST") return this.initialize(await request.json() as { repository: string; branch: string; accountLogin: string });
      if (!this.getMeta("repository")) return json({ error: "workspace_not_initialized" }, { status: 409 });
      if (url.pathname === "/snapshot" && request.method === "GET") return this.snapshot(url);
      if (url.pathname === "/sync-status" && request.method === "GET") return json(await this.syncStatus());
      if (url.pathname === "/flush" && request.method === "POST") {
        await this.ctx.storage.deleteAlarm();
        await this.flushGitHub();
        return json(await this.syncStatus());
      }
      if (url.pathname === "/operations" && request.method === "POST") return this.applyOperation(await request.json() as Record<string, unknown>);
      if (url.pathname.startsWith("/files/") && url.pathname.endsWith("/updates") && request.method === "GET") {
        const fileId = decodeURIComponent(url.pathname.slice("/files/".length, -"/updates".length));
        return this.fileUpdates(fileId, url.searchParams.get("stateVector"));
      }
      if (url.pathname.startsWith("/files/") && url.pathname.endsWith("/updates") && request.method === "POST") {
        const fileId = decodeURIComponent(url.pathname.slice("/files/".length, -"/updates".length));
        return this.applyDocumentUpdate(await request.json() as Record<string, unknown>, fileId);
      }
      if (url.pathname.startsWith("/files/") && request.method === "GET") return this.getFile(decodeURIComponent(url.pathname.slice("/files/".length)));
      if (url.pathname.startsWith("/assets/") && request.method === "GET") return this.getAsset(decodeURIComponent(url.pathname.slice("/assets/".length)));
      if (url.pathname === "/stream" && request.headers.get("Upgrade") === "websocket") return this.openSocket(request);
      if (url.pathname === "/upload" && request.method === "POST") return this.upload(request);
      return json({ error: "not_found" }, { status: 404 });
    } catch (error) {
      return json({ error: "internal_error", message: error instanceof Error ? error.message : "Unexpected error" }, { status: 500 });
    }
  }

  private snapshot(url: URL): Response {
    const revision = Number(this.getMeta("revision") ?? "0");
    const files = this.files().map((file) => ({
      id: file.file_id, path: file.path, kind: file.kind, revision: file.revision,
      ...(file.kind === "markdown" ? { content: file.content ?? "" } : { contentType: "application/octet-stream", size: file.size }),
    }));
    return json({ workspaceId: this.ctx.id.toString(), revision, files, hasMore: false, nextRevision: revision, afterRevision: Number(url.searchParams.get("afterRevision") ?? 0) });
  }

  private async syncStatus(): Promise<Record<string, unknown>> {
    const dirty = this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM files WHERE dirty = 1").toArray()[0]?.count ?? 0;
    const alarm = await this.ctx.storage.getAlarm();
    return {
      serverRevision: Number(this.getMeta("revision") ?? "0"), githubStatus: this.getMeta("githubStatus") ?? "pending",
      githubHead: this.getMeta("head"), lastGitHubCommitAt: this.getMeta("lastGitHubCommitAt"), nextGitHubFlushAt: alarm,
      pendingFiles: dirty, message: this.getMeta("githubMessage"),
    };
  }

  private getFile(fileId: string): Response {
    const file = this.file(fileId);
    if (!file) return json({ error: "not_found" }, { status: 404 });
    return json({ id: file.file_id, path: file.path, kind: file.kind, revision: file.revision, content: file.content, contentType: file.kind === "markdown" ? "text/markdown; charset=utf-8" : "application/octet-stream", size: file.size, sha256: file.sha });
  }

  private async getAsset(fileId: string): Promise<Response> {
    const file = this.file(fileId);
    if (!file || file.kind !== "asset" || !file.object_key) return json({ error: "not_found" }, { status: 404 });
    const object = await this.env.ASSET_BUCKET.get(file.object_key);
    if (!object) return json({ error: "asset_missing" }, { status: 404 });
    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("Content-Length", String(object.size));
    headers.set("Content-Disposition", `inline; filename*=UTF-8''${encodeURIComponent(file.path.split("/").at(-1) ?? "download")}`);
    headers.set("Cache-Control", "private, max-age=60");
    return new Response(object.body, { headers });
  }

  private fileUpdates(fileId: string, vector: string | null): Response {
    const file = this.file(fileId);
    if (!file || file.kind !== "markdown") return json({ error: "not_found" }, { status: 404 });
    const doc = this.document(fileId);
    const update = vector ? Y.encodeStateAsUpdate(doc, fromB64(vector)) : Y.encodeStateAsUpdate(doc);
    return json({ fileId, update: b64(update), protocolVersion: 1, revision: file.revision });
  }

  private async applyOperation(body: Record<string, unknown>): Promise<Response> {
    const operationId = String(body.operationId ?? "");
    const operation = body.operation as Record<string, unknown> | undefined;
    if (!operationId || !operation || typeof operation.type !== "string") return json({ error: "invalid_operation" }, { status: 400 });
    const prior = this.ctx.storage.sql.exec<{ result: string }>("SELECT result FROM operations WHERE operation_id = ?", operationId).toArray()[0];
    if (prior) return json({ ...(JSON.parse(prior.result) as object), duplicate: true });
    const baseRevision = Number(body.baseRevision ?? 0);
    const currentRevision = Number(this.getMeta("revision") ?? "0");
    const clientId = String(body.clientId ?? "offline");
    let conflictCopyPath: string | undefined;
    let revision: number;

    if (operation.type === "create-folder" || operation.type === "create-file") {
      const requestedPath = String(operation.path ?? "");
      if (!validPath(requestedPath)) return json({ error: "invalid_path" }, { status: 400 });
      const path = this.pathExists(requestedPath) ? this.uniqueConflictPath(requestedPath, clientId) : requestedPath;
      if (path !== requestedPath) conflictCopyPath = path;
      const fileId = String(operation.fileId ?? crypto.randomUUID());
      const kind = operation.type === "create-folder" ? "folder" : "markdown";
      const content = kind === "markdown" ? String(operation.content ?? "") : null;
      this.ensureParents(path);
      this.ctx.storage.sql.exec("INSERT INTO files (file_id,path,kind,content,revision,deleted,dirty) VALUES (?,?,?,?,0,0,1)", fileId, path, kind, content);
      if (kind === "markdown") {
        const doc = new Y.Doc({ guid: fileId });
        if (content) doc.getText("markdown").insert(0, content);
        this.saveDocument(fileId, Y.encodeStateAsUpdate(doc));
      }
      revision = this.nextRevision();
      this.ctx.storage.sql.exec("UPDATE files SET revision = ? WHERE file_id = ?", revision, fileId);
    } else if (operation.type === "move") {
      const fileId = String(operation.fileId ?? "");
      const file = this.file(fileId);
      const target = String(operation.toPath ?? "");
      if (!file) return json({ error: "not_found" }, { status: 404 });
      if (!validPath(target)) return json({ error: "invalid_path" }, { status: 400 });
      if (file.kind === "folder" && target.startsWith(`${file.path}/`)) return json({ error: "move_into_itself" }, { status: 409 });
      let destination = target;
      if (this.pathExists(target) && target !== file.path) {
        destination = this.uniqueConflictPath(target, clientId);
        conflictCopyPath = destination;
      }
      // A directory move is atomic: every descendant receives the same prefix replacement.
      const prefix = file.kind === "folder" ? `${file.path}/` : "";
      const rows = file.kind === "folder" ? this.files().filter((item) => item.path.startsWith(prefix) && item.kind !== "folder") : [file];
      revision = this.nextRevision();
      this.ensureParents(destination);
      for (const row of rows) {
        const newPath = row.path === file.path ? destination : `${destination}${row.path.slice(file.path.length)}`;
        if (!validPath(newPath)) return json({ error: "invalid_path" }, { status: 400 });
        this.ctx.storage.sql.exec("UPDATE files SET previous_path = COALESCE(previous_path, path), path = ?, revision = ?, dirty = 1 WHERE file_id = ?", newPath, revision, row.file_id);
      }
      if (file.kind === "folder") {
        this.ctx.storage.sql.exec(
          "UPDATE files SET path = ? || substr(path, length(?) + 1), revision = ?, dirty = 0 WHERE kind = 'folder' AND (path = ? OR substr(path, 1, length(?) + 1) = ? || '/')",
          destination, file.path, revision, file.path, file.path, file.path
        );
      }
    } else if (operation.type === "delete") {
      const file = this.file(String(operation.fileId ?? ""));
      if (!file) return json({ error: "not_found" }, { status: 404 });
      revision = this.nextRevision();
      const prefix = file.kind === "folder" ? `${file.path}/` : "";
      if (file.kind === "folder") {
        this.ctx.storage.sql.exec("UPDATE files SET deleted = 1, dirty = CASE WHEN kind = 'folder' THEN 0 ELSE 1 END, revision = ? WHERE path = ? OR substr(path, 1, length(?) + 1) = ? || '/'", revision, file.path, file.path, file.path);
      }
      else this.ctx.storage.sql.exec("UPDATE files SET deleted = 1, dirty = 1, revision = ? WHERE file_id = ?", revision, file.file_id);
    } else {
      return json({ error: "unsupported_operation" }, { status: 400 });
    }

    const result = { operationId, acceptedRevision: revision, duplicate: false, ...(conflictCopyPath ? { conflictCopyPath } : {}), ...(baseRevision < currentRevision ? { rebasedFrom: baseRevision } : {}) };
    this.ctx.storage.sql.exec("INSERT INTO operations (operation_id,revision,result) VALUES (?,?,?)", operationId, revision, JSON.stringify(result));
    await this.scheduleFlush();
    this.broadcast(result);
    return json(result);
  }

  private pathExists(path: string): boolean {
    return Boolean(this.ctx.storage.sql.exec<{ path: string }>(
      "SELECT path FROM files WHERE deleted = 0 AND (path = ? OR substr(path, 1, length(?) + 1) = ? || '/')",
      path, path, path
    ).toArray().length);
  }

  private ensureParents(path: string, dirty = true): void {
    const components = path.split("/");
    for (let index = 1; index < components.length; index++) {
      const parent = components.slice(0, index).join("/");
      if (this.pathExists(parent)) continue;
      const fileId = `folder-${parent}`;
      this.ctx.storage.sql.exec("INSERT INTO files (file_id,path,kind,revision,deleted,dirty) VALUES (?,?, 'folder',0,0,?) ON CONFLICT(file_id) DO UPDATE SET path = excluded.path, deleted = 0, dirty = excluded.dirty", fileId, parent, dirty ? 1 : 0);
    }
  }

  private uniqueConflictPath(path: string, client: string): string {
    let candidate = conflictName(path, client);
    let suffix = 2;
    while (this.pathExists(candidate)) candidate = conflictName(path, `${client}-${suffix++}`);
    return candidate;
  }

  private async upload(request: Request): Promise<Response> {
    const form = await request.formData();
    const file = form.get("file");
    const path = String(form.get("path") ?? "");
    if (!(file instanceof File) || !validPath(path)) return json({ error: "invalid_upload" }, { status: 400 });
    if (file.size > MAX_GIT_FILE_BYTES) return json({ error: "file_too_large", maxBytes: MAX_GIT_FILE_BYTES }, { status: 413 });
    const fileId = String(form.get("fileId") ?? crypto.randomUUID());
    const objectKey = `${this.ctx.id.toString()}/${fileId}`;
    await this.env.ASSET_BUCKET.put(objectKey, file.stream(), { httpMetadata: { contentType: file.type || "application/octet-stream" } });
    const destination = this.pathExists(path) ? this.uniqueConflictPath(path, String(form.get("clientId") ?? "upload")) : path;
    this.ensureParents(destination);
    const revision = this.nextRevision();
    this.ctx.storage.sql.exec("INSERT INTO files (file_id,path,kind,object_key,size,revision,deleted,dirty) VALUES (?,?, 'asset',?,?,?,0,1)", fileId, destination, objectKey, file.size, revision);
    const result = { operationId: crypto.randomUUID(), acceptedRevision: revision, duplicate: false, ...(destination !== path ? { conflictCopyPath: destination } : {}) };
    await this.scheduleFlush();
    this.broadcast(result);
    return json({ ...result, fileId, path: destination }, { status: 201 });
  }

  private async openSocket(request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    const clientId = new URL(request.url).searchParams.get("clientId") ?? crypto.randomUUID();
    server.serializeAttachment({ clientId });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let data: Record<string, unknown>;
    try { data = JSON.parse(message) as Record<string, unknown>; }
    catch { socket.send(JSON.stringify({ type: "error", code: "invalid_json", message: "Expected JSON envelope" })); return; }
    if (data.type === "hello") {
      const attachment = socket.deserializeAttachment() as { clientId?: string } | null;
      const peer = {
        clientId: String(data.clientId ?? attachment?.clientId ?? crypto.randomUUID()),
        login: String((data.user as Record<string, unknown> | undefined)?.login ?? "Guest").slice(0, 64),
        avatarUrl: typeof (data.user as Record<string, unknown> | undefined)?.avatarUrl === "string" ? String((data.user as Record<string, unknown>).avatarUrl).slice(0, 2048) : undefined,
        fileId: typeof data.fileId === "string" ? data.fileId : undefined,
      };
      socket.serializeAttachment(peer);
      const peers = this.ctx.getWebSockets().map((client) => client.deserializeAttachment() as typeof peer | null).filter((item): item is typeof peer => Boolean(item?.clientId));
      socket.send(JSON.stringify({ type: "presence-state", peers }));
      const files = this.files().filter((file) => file.kind === "markdown");
      for (const file of files) {
        const doc = this.document(file.file_id);
        socket.send(JSON.stringify({ type: "document-state", fileId: file.file_id, revision: file.revision, update: b64(Y.encodeStateAsUpdate(doc)) }));
      }
      socket.send(JSON.stringify({ type: "ready", revision: Number(this.getMeta("revision") ?? "0") }));
      this.broadcast({ type: "presence", action: "join", peer }, socket);
      return;
    }
    if (data.type === "presence") {
      const attachment = socket.deserializeAttachment() as Record<string, unknown> | null;
      const peer = { ...attachment, fileId: typeof data.fileId === "string" ? data.fileId : undefined };
      socket.serializeAttachment(peer);
      this.broadcast({ type: "presence", action: "update", peer }, socket);
      return;
    }
    if (data.type !== "document-update") return;
    await this.applyDocumentUpdate(data, String(data.fileId ?? ""), socket);
  }

  private async applyDocumentUpdate(data: Record<string, unknown>, fileId: string, socket?: WebSocket): Promise<Response> {
    const operationId = String(data.operationId ?? "");
    const source = this.fileIncludingDeleted(fileId);
    const conflictId = source?.deleted ? this.getMeta(`deletedConflict:${fileId}`) : undefined;
    let file = conflictId ? this.file(conflictId) : source?.deleted ? undefined : source;
    if (!operationId || !source || source.kind !== "markdown" || typeof data.update !== "string" || (source.deleted && conflictId && !file)) {
      const message = { type: "error", code: "invalid_document_update", message: "Document or update is invalid", operationId };
      socket?.send(JSON.stringify(message));
      return json(message, { status: 400 });
    }
    const duplicate = this.ctx.storage.sql.exec<{ revision: number }>("SELECT revision FROM operations WHERE operation_id = ?", operationId).toArray()[0];
    if (duplicate) {
      const message = { type: "ack", operationId, acceptedRevision: duplicate.revision, duplicate: true };
      socket?.send(JSON.stringify(message));
      return json(message);
    }
    try {
      const update = fromB64(data.update);
      const documentId = file?.file_id ?? fileId;
      const doc = this.document(documentId);
      const before = Y.encodeStateAsUpdate(doc);
      Y.applyUpdate(doc, update);
      const state = Y.encodeStateAsUpdate(doc);
      if (before.length === state.length && before.every((byte, index) => byte === state[index])) {
        const acceptedRevision = Number(this.getMeta("revision") ?? "0");
        const message = { type: "ack", operationId, acceptedRevision, duplicate: true };
        socket?.send(JSON.stringify(message));
        return json(message);
      }
      const content = doc.getText("markdown").toString();
      if (encoder.encode(content).byteLength > MAX_MARKDOWN_BYTES) {
        const message = { type: "error", code: "markdown_too_large", message: "Markdown files are limited to 512 KiB.", operationId };
        socket?.send(JSON.stringify(message));
        return json(message, { status: 413 });
      }
      let conflictCopyPath: string | undefined;
      if (source.deleted && !file) {
        const attachment = socket?.deserializeAttachment() as { clientId?: string } | null;
        const clientId = String(attachment?.clientId ?? data.clientId ?? "offline");
        conflictCopyPath = this.uniqueConflictPath(source.path, clientId);
        const conflictFileId = crypto.randomUUID();
        this.ensureParents(conflictCopyPath);
        this.saveDocument(fileId, state);
        this.saveDocument(conflictFileId, state);
        const size = encoder.encode(content).byteLength;
        this.ctx.storage.sql.exec(
          "INSERT INTO files (file_id,path,kind,content,size,revision,deleted,dirty) VALUES (?,?,'markdown',?,?,0,0,1)",
          conflictFileId, conflictCopyPath, content, size
        );
        this.setMeta(`deletedConflict:${fileId}`, conflictFileId);
        file = this.file(conflictFileId);
      }
      const targetFileId = file?.file_id ?? fileId;
      const revision = this.nextRevision();
      this.saveDocument(targetFileId, state);
      this.ctx.storage.sql.exec("UPDATE files SET content = ?, size = ?, revision = ?, dirty = 1 WHERE file_id = ?", content, encoder.encode(content).byteLength, revision, targetFileId);
      const result = { operationId, acceptedRevision: revision, duplicate: false, ...(conflictCopyPath ? { conflictCopyPath } : {}) };
      this.ctx.storage.sql.exec("INSERT INTO operations (operation_id,revision,result) VALUES (?,?,?)", operationId, revision, JSON.stringify(result));
      await this.scheduleFlush();
      const message = { type: "ack", ...result };
      socket?.send(JSON.stringify(message));
      this.broadcast({ type: "document-update", fileId: targetFileId, revision, update: data.update, operationId }, socket);
      return json(message);
    } catch {
      const message = { type: "error", code: "invalid_document_update", message: "CRDT update could not be applied", operationId };
      socket?.send(JSON.stringify(message));
      return json(message, { status: 400 });
    }
  }

  private broadcast(value: unknown, except?: WebSocket): void {
    const encoded = JSON.stringify(value);
    for (const socket of this.ctx.getWebSockets()) {
      if (socket !== except && socket.readyState === WebSocket.OPEN) socket.send(encoded);
    }
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    const peer = socket.deserializeAttachment() as { clientId?: string } | null;
    if (peer?.clientId) this.broadcast({ type: "presence", action: "leave", clientId: peer.clientId });
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    await this.webSocketClose(socket);
  }

  async alarm(): Promise<void> {
    try {
      await this.flushGitHub();
    } catch (error) {
      this.setMeta("githubStatus", "failed");
      this.setMeta("githubMessage", error instanceof Error ? error.message : "GitHub sync failed");
      await this.ctx.storage.setAlarm(Date.now() + Math.min(60 * 60 * 1000, 30_000 * 2 ** Number(this.getMeta("retryCount") ?? 0)));
      this.setMeta("retryCount", String(Math.min(7, Number(this.getMeta("retryCount") ?? 0) + 1)));
    }
  }

  private async flushGitHub(): Promise<void> {
    const changes = this.files(true).filter((file) => file.dirty);
    if (!changes.length) return;
    this.setMeta("githubStatus", "pending");
    const repository = this.getMeta("repository")!;
    const branch = this.getMeta("branch")!;
    const [owner, repo] = repository.split("/");
    const token = await this.token();
    const refPath = `/repos/${owner}/${repo}/git/ref/heads/${branch.split("/").map(encodeURIComponent).join("/")}`;
    const ref = await (await this.github(token, refPath)).json() as RefResponse;
    if (ref.object.sha !== this.getMeta("head")) {
      this.setMeta("githubStatus", "external-change");
      this.setMeta("githubMessage", "GitHub branch changed outside PKMS. Automatic push is paused to protect those changes.");
      return;
    }
    const baseCommit = await (await this.github(token, `/repos/${owner}/${repo}/git/commits/${ref.object.sha}`)).json() as { tree: { sha: string } };
    const capturedRevision = Number(this.getMeta("revision") ?? "0");
    const treeEntries: Array<{ path: string; mode: string; type: "blob"; sha: string | null }> = [];
    const newBlobSHAs = new Map<string, string>();
    for (const file of changes) {
      if (file.kind === "folder") continue;
      if (file.previous_path) treeEntries.push({ path: file.previous_path, mode: "100644", type: "blob", sha: null });
      if (file.deleted) {
        treeEntries.push({ path: file.path, mode: "100644", type: "blob", sha: null });
        continue;
      }
      let bytes: Uint8Array;
      if (file.kind === "markdown") bytes = encoder.encode(file.content ?? "");
      else {
        if (!file.object_key) continue;
        const object = await this.env.ASSET_BUCKET.get(file.object_key);
        if (!object) throw new Error(`Attachment disappeared from object storage: ${file.path}`);
        bytes = new Uint8Array(await object.arrayBuffer());
      }
      if (bytes.byteLength > MAX_GIT_FILE_BYTES) throw new Error(`${file.path} exceeds the PKMS GitHub file size limit.`);
      const blob = await (await this.github(token, `/repos/${owner}/${repo}/git/blobs`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: b64(bytes), encoding: "base64" }),
      })).json() as { sha: string };
      newBlobSHAs.set(file.file_id, blob.sha);
      treeEntries.push({ path: file.path, mode: "100644", type: "blob", sha: blob.sha });
    }
    if (!treeEntries.length) {
      this.ctx.storage.sql.exec("UPDATE files SET dirty = 0, deleted = 1, previous_path = NULL WHERE dirty = 1 AND kind = 'folder'");
      await this.ctx.storage.deleteAlarm();
      this.setMeta("githubStatus", "synced");
      this.setMeta("githubMessage", "");
      return;
    }
    const tree = await (await this.github(token, `/repos/${owner}/${repo}/git/trees`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ base_tree: baseCommit.tree.sha, tree: treeEntries }),
    })).json() as { sha: string };
    const commit = await (await this.github(token, `/repos/${owner}/${repo}/git/commits`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: "Sync PKMS workspace", tree: tree.sha, parents: [ref.object.sha] }),
    })).json() as { sha: string };
    await this.github(token, refPath, {
      method: "PATCH", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sha: commit.sha, force: false }),
    });
    for (const file of changes) {
      const current = this.ctx.storage.sql.exec<{ [key: string]: SqlStorageValue; revision: number }>("SELECT revision FROM files WHERE file_id = ?", file.file_id).toArray()[0];
      if (current?.revision === file.revision && file.revision <= capturedRevision) {
        this.ctx.storage.sql.exec("UPDATE files SET dirty = 0, deleted = ?, sha = COALESCE(?, sha), previous_path = NULL WHERE file_id = ?", file.deleted ? 1 : 0, newBlobSHAs.get(file.file_id) ?? null, file.file_id);
        if (file.object_key) await this.env.ASSET_BUCKET.delete(file.object_key);
      }
    }
    this.setMeta("head", commit.sha);
    this.setMeta("githubStatus", "synced");
    this.setMeta("githubMessage", "");
    this.setMeta("lastGitHubCommitAt", new Date().toISOString());
    this.setMeta("retryCount", "0");
    const remaining = this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM files WHERE dirty = 1").toArray()[0]?.count ?? 0;
    if (remaining) await this.ctx.storage.setAlarm(Date.now() + FLUSH_AFTER_MS);
    else await this.ctx.storage.deleteAlarm();
  }
}

