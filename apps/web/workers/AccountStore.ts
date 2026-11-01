import { DurableObject } from "cloudflare:workers";
import type { Env, WorkspaceRecord } from "./env";
import { decryptSecret, encryptSecret, json } from "./crypto";

interface AccountRow { [key: string]: SqlStorageValue; key: string; value: string }

export class AccountStore extends DurableObject<Env> {
  private refreshInFlight?: Promise<{ accessToken: string; user: { login: string; avatarUrl?: string } }>;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS account (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  }

  private get(key: string): string | undefined {
    return this.ctx.storage.sql.exec<AccountRow>("SELECT key, value FROM account WHERE key = ?", key).toArray()[0]?.value;
  }

  private set(key: string, value: string): void {
    this.ctx.storage.sql.exec("INSERT INTO account (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value);
  }

  private async accessToken(): Promise<{ accessToken: string; user: { login: string; avatarUrl?: string } }> {
    if (this.refreshInFlight) return this.refreshInFlight;
    this.refreshInFlight = this.loadAccessToken();
    try { return await this.refreshInFlight; }
    finally { this.refreshInFlight = undefined; }
  }

  private async loadAccessToken(): Promise<{ accessToken: string; user: { login: string; avatarUrl?: string } }> {
    const sealed = this.get("credentials");
    if (!sealed) throw new Error("GitHub account is not connected");
    const credentials = JSON.parse(sealed) as { accessToken: string; refreshToken?: string; expiresAt?: number; user: { login: string; avatarUrl?: string } };
    const accessToken = await decryptSecret(this.env, credentials.accessToken);
    if (!credentials.expiresAt || credentials.expiresAt - Date.now() > 5 * 60 * 1000) return { accessToken, user: credentials.user };
    if (!credentials.refreshToken) throw new Error("GitHub authorization expired; sign in again.");
    const response = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST",
      headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: this.env.GITHUB_CLIENT_ID, client_secret: this.env.GITHUB_CLIENT_SECRET, grant_type: "refresh_token", refresh_token: await decryptSecret(this.env, credentials.refreshToken) }),
    });
    const grant = await response.json() as { access_token?: string; refresh_token?: string; expires_in?: number; error?: string };
    if (!response.ok || !grant.access_token) throw new Error(grant.error ?? "Could not refresh GitHub authorization");
    this.set("credentials", JSON.stringify({
      accessToken: await encryptSecret(this.env, grant.access_token),
      refreshToken: grant.refresh_token ? await encryptSecret(this.env, grant.refresh_token) : credentials.refreshToken,
      expiresAt: grant.expires_in ? Date.now() + grant.expires_in * 1000 : undefined,
      user: credentials.user,
    }));
    return { accessToken: grant.access_token, user: credentials.user };
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/__migration/export") {
      const rows = this.ctx.storage.sql.exec<AccountRow>("SELECT key,value FROM account ORDER BY key").toArray();
      return json(rows.map(({ key, value }) => ({ key, value })));
    }
    if (request.method === "GET" && url.pathname === "/credentials") {
      const value = this.get("credentials");
      return value ? json(JSON.parse(value)) : json({ error: "not_connected" }, { status: 404 });
    }
    if (request.method === "GET" && url.pathname === "/credentials/access-token") {
      try { return json(await this.accessToken()); }
      catch (error) { return json({ error: "github_authorization_failed", message: error instanceof Error ? error.message : "Could not authorize GitHub request" }, { status: 401 }); }
    }
    if (request.method === "PUT" && url.pathname === "/credentials") {
      const credentials = await request.json();
      this.set("credentials", JSON.stringify(credentials));
      return json({ ok: true });
    }
    if (request.method === "GET" && url.pathname === "/workspaces") {
      return json({ workspaces: JSON.parse(this.get("workspaces") ?? "[]") as WorkspaceRecord[] });
    }
    if (request.method === "PUT" && url.pathname === "/workspaces") {
      const workspace = await request.json() as WorkspaceRecord;
      const list = JSON.parse(this.get("workspaces") ?? "[]") as WorkspaceRecord[];
      const next = [...list.filter((item) => item.id !== workspace.id), workspace];
      this.set("workspaces", JSON.stringify(next));
      return json({ workspace });
    }
    if (request.method === "PATCH" && url.pathname.startsWith("/workspaces/")) {
      const id = decodeURIComponent(url.pathname.slice("/workspaces/".length));
      const patch = await request.json() as Partial<WorkspaceRecord>;
      const list = JSON.parse(this.get("workspaces") ?? "[]") as WorkspaceRecord[];
      const workspace = list.find((item) => item.id === id);
      if (!workspace) return json({ error: "not_found" }, { status: 404 });
      Object.assign(workspace, patch);
      this.set("workspaces", JSON.stringify(list));
      return json({ workspace });
    }
    if (request.method === "POST" && url.pathname.startsWith("/mcp-oauth/put/")) {
      const key = url.pathname.slice("/mcp-oauth/put/".length);
      if (!key || key.includes("/")) return json({ error: "invalid_key" }, { status: 400 });
      if (key.startsWith("client:") && (this.ctx.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM account WHERE key LIKE 'mcp:client:%'").toArray()[0]?.count ?? 0) >= 20) return json({ error: "client_limit_reached" }, { status: 429 });
      const body = await request.json() as { value?: unknown; expiresAt?: number };
      if (typeof body.expiresAt !== "number" || body.expiresAt <= Date.now()) return json({ error: "invalid_expiry" }, { status: 400 });
      this.set(`mcp:${key}`, JSON.stringify({ value: body.value, expiresAt: body.expiresAt }));
      return json({ ok: true });
    }
    if ((request.method === "GET" || request.method === "POST" || request.method === "DELETE") && (url.pathname.startsWith("/mcp-oauth/get/") || url.pathname.startsWith("/mcp-oauth/consume/") || url.pathname.startsWith("/mcp-oauth/delete/"))) {
      const consume = url.pathname.startsWith("/mcp-oauth/consume/");
      const key = url.pathname.replace(/^\/mcp-oauth\/(?:get|consume|delete)\//, "");
      if (!key || key.includes("/")) return json({ error: "invalid_key" }, { status: 400 });
      const stored = this.get(`mcp:${key}`);
      if (consume || request.method === "DELETE") this.ctx.storage.sql.exec("DELETE FROM account WHERE key = ?", `mcp:${key}`);
      if (!stored) return json({ error: "not_found" }, { status: 404 });
      try {
        const record = JSON.parse(stored) as { value: unknown; expiresAt: number };
        if (record.expiresAt <= Date.now()) return json({ error: "expired" }, { status: 404 });
        return json({ value: record.value, expiresAt: record.expiresAt });
      } catch {
        return json({ error: "invalid_record" }, { status: 500 });
      }
    }
    return json({ error: "not_found" }, { status: 404 });
  }
}
