import { createRequestHandler } from "react-router";
import type { Env, Session, WorkspaceRecord } from "./env";
import { AccountStore } from "./AccountStore";
import { VaultRoom } from "./VaultRoom";
import { cookie, decryptSecret, encryptSecret, json, randomToken, sessionCookie, signSession, verifySession } from "./crypto";

export { AccountStore, VaultRoom };


interface Credentials {
  accessToken: string;
  user: { login: string; avatarUrl?: string };
}

interface GitHubGrant {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  error?: string;
}

async function saveGitHubGrant(env: Env, grant: GitHubGrant): Promise<Session> {
  if (!grant.access_token) throw new Error(grant.error ?? "GitHub token missing");
  const userResponse = await fetch("https://api.github.com/user", {
    headers: { Authorization: `Bearer ${grant.access_token}`, Accept: "application/vnd.github+json", "User-Agent": "PKMS-Cloud/1.0" },
  });
  if (!userResponse.ok) throw new Error("GitHub user lookup failed");
  const user = await userResponse.json() as { login: string; avatar_url?: string };
  const stored: Record<string, unknown> = {
    accessToken: await encryptSecret(env, grant.access_token),
    user: { login: user.login, avatarUrl: user.avatar_url },
  };
  if (grant.refresh_token) stored.refreshToken = await encryptSecret(env, grant.refresh_token);
  if (grant.expires_in) stored.expiresAt = Date.now() + grant.expires_in * 1000;
  await account(env, user.login).fetch("https://account/credentials", { method: "PUT", body: JSON.stringify(stored) });
  return { login: user.login, avatarUrl: user.avatar_url, expiresAt: Date.now() + 30 * 24 * 60 * 60 * 1000 };
}

function account(env: Env, login: string): DurableObjectStub {
  return env.ACCOUNTS.get(env.ACCOUNTS.idFromName(login.toLowerCase()));
}

async function credentials(env: Env, login: string): Promise<Credentials> {
  const response = await account(env, login).fetch("https://account/credentials/access-token");
  if (!response.ok) throw new Error((await response.json() as { message?: string }).message ?? "GitHub account is not connected");
  return response.json() as Promise<Credentials>;
}

async function requireSession(request: Request, env: Env): Promise<Session | Response> {
  const bearer = request.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  const session = await verifySession(env, bearer ?? cookie(request, "__Host-pkms_session"));
  if (!session) return json({ error: "unauthorized", message: "Sign in with GitHub to continue." }, { status: 401 });
  return session;
}

function sameOrigin(request: Request, env: Env): boolean {
  const origin = request.headers.get("Origin");
  return !origin || origin === env.PUBLIC_ORIGIN;
}

async function githubRequest(token: string, path: string): Promise<Response> {
  return fetch(`https://api.github.com${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "PKMS-Cloud/1.0" },
  });
}

async function api(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/api/health") return json({ ok: true, protocolVersion: 1 });
  if (request.method === "GET" && url.pathname === "/api/auth/github") {
    const state = randomToken(24);
    const target = new URL("https://github.com/login/oauth/authorize");
    target.searchParams.set("client_id", env.GITHUB_CLIENT_ID);
    target.searchParams.set("redirect_uri", `${env.PUBLIC_ORIGIN}/api/auth/github/callback`);
    target.searchParams.set("state", state);
    return new Response(null, { status: 302, headers: {
      Location: target.toString(),
      "Set-Cookie": `__Host-pkms_oauth=${state}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=600`,
      "Cache-Control": "no-store",
    } });
  }
  if (request.method === "GET" && url.pathname === "/api/auth/github/callback") {
    const state = url.searchParams.get("state");
    const expectedState = cookie(request, "__Host-pkms_oauth");
    const code = url.searchParams.get("code");
    if (!state || !expectedState || state !== expectedState || !code) return json({ error: "invalid_oauth_state" }, { status: 400 });
    const exchange = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST", headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ client_id: env.GITHUB_CLIENT_ID, client_secret: env.GITHUB_CLIENT_SECRET, code }),
    });
    if (!exchange.ok) return json({ error: "github_token_exchange_failed" }, { status: 502 });
    const grant = await exchange.json() as { access_token?: string; refresh_token?: string; expires_in?: number; refresh_token_expires_in?: number; error?: string };
    if (!grant.access_token) return json({ error: grant.error ?? "github_token_missing" }, { status: 502 });
    const session = await saveGitHubGrant(env, grant);
    const signed = await signSession(env, session);
    return new Response(null, { status: 302, headers: {
      Location: "/",
      "Cache-Control": "no-store",
      "Set-Cookie": sessionCookie(signed, 30 * 24 * 60 * 60),
    } });
  }
  if (request.method === "POST" && url.pathname === "/api/auth/device/start") {
    if (!sameOrigin(request, env)) return json({ error: "origin_mismatch" }, { status: 403 });
    const response = await fetch("https://github.com/login/device/code", {
      method: "POST", headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: env.GITHUB_CLIENT_ID }),
    });
    const device = await response.json() as { device_code?: string; user_code?: string; verification_uri?: string; expires_in?: number; interval?: number; error?: string };
    if (!response.ok || !device.device_code) return json({ error: device.error ?? "device_flow_unavailable" }, { status: 502 });
    return json(device, { status: 200 });
  }
  if (request.method === "POST" && url.pathname === "/api/auth/device/poll") {
    if (!sameOrigin(request, env)) return json({ error: "origin_mismatch" }, { status: 403 });
    const body = await request.json() as { deviceCode?: string };
    if (!body.deviceCode || body.deviceCode.length > 2048) return json({ error: "invalid_device_code" }, { status: 400 });
    const response = await fetch("https://github.com/login/oauth/access_token", {
      method: "POST", headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: env.GITHUB_CLIENT_ID, device_code: body.deviceCode, grant_type: "urn:ietf:params:oauth:grant-type:device_code" }),
    });
    const grant = await response.json() as GitHubGrant;
    if (grant.error === "authorization_pending" || grant.error === "slow_down") return json({ pending: true, interval: grant.error === "slow_down" ? 10 : undefined }, { status: 202 });
    if (!response.ok || !grant.access_token) return json({ error: grant.error ?? "device_authorization_failed" }, { status: 400 });
    const session = await saveGitHubGrant(env, grant);
    const token = await signSession(env, session);
    return json({ pending: false, token, user: { login: session.login, avatarUrl: session.avatarUrl }, expiresAt: session.expiresAt });
  }
  if (request.method === "GET" && url.pathname === "/api/session") {
    const bearer = request.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
    const session = await verifySession(env, bearer ?? cookie(request, "__Host-pkms_session"));
    return json({ user: session ? { login: session.login, avatarUrl: session.avatarUrl } : null });
  }
  if (request.method === "POST" && url.pathname === "/api/logout") {
    if (!sameOrigin(request, env)) return json({ error: "origin_mismatch" }, { status: 403 });
    return new Response(null, { status: 204, headers: { "Set-Cookie": sessionCookie("", 0), "Cache-Control": "no-store" } });
  }

  const auth = await requireSession(request, env);
  if (auth instanceof Response) return auth;
  if (!sameOrigin(request, env)) return json({ error: "origin_mismatch" }, { status: 403 });
  const authCredentials = await credentials(env, auth.login);

  if (request.method === "GET" && url.pathname === "/api/repositories") {
    const response = await githubRequest(authCredentials.accessToken, "/user/repos?per_page=100&sort=updated&visibility=all&affiliation=owner,collaborator,organization_member");
    if (!response.ok) return json({ error: "github_repository_list_failed" }, { status: response.status });
    const repositories = await response.json() as Array<{ full_name: string; default_branch: string; private: boolean; description?: string | null; permissions?: { push?: boolean } }>;
    return json({ repositories: repositories.map((repository) => ({ fullName: repository.full_name, defaultBranch: repository.default_branch, private: repository.private, description: repository.description, canWrite: repository.permissions?.push ?? false })) });
  }
  if (url.pathname === "/api/workspaces" && request.method === "GET") {
    const response = await account(env, auth.login).fetch("https://account/workspaces");
    return response;
  }
  if (url.pathname === "/api/workspaces" && request.method === "POST") {
    const body = await request.json() as { repository?: string; branch?: string };
    const repository = body.repository ?? "";
    const repositoryResponse = await githubRequest(authCredentials.accessToken, `/repos/${repository}`);
    if (!repositoryResponse.ok) return json({ error: "repository_unavailable" }, { status: repositoryResponse.status });
    const repo = await repositoryResponse.json() as { full_name: string; default_branch: string; permissions?: { push?: boolean } };
    if (!repo.permissions?.push) return json({ error: "repository_read_only" }, { status: 403 });
    const branch = body.branch || repo.default_branch;
    const id = await makeWorkspaceId(auth.login, repo.full_name, branch);
    const record: WorkspaceRecord = { id, repository: repo.full_name, branch, githubStatus: "pending", revision: 0 };
    const room = env.VAULT_ROOMS.get(env.VAULT_ROOMS.idFromName(id));
    const initialized = await room.fetch("https://room/initialize", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        repository: repo.full_name,
        branch,
        accountLogin: auth.login,
      }),
    });
    if (!initialized.ok) return initialized;
    const saved = await account(env, auth.login).fetch("https://account/workspaces", { method: "PUT", body: JSON.stringify(record) });
    return json({ ...(await saved.json() as object), workspace: record }, { status: 201 });
  }

  const match = url.pathname.match(/^\/api\/workspaces\/([^/]+)(\/.*)?$/);
  if (!match) return json({ error: "not_found" }, { status: 404 });
  const workspaceId = decodeURIComponent(match[1]);
  const listResponse = await account(env, auth.login).fetch("https://account/workspaces");
  const workspaceList = await listResponse.json() as { workspaces: WorkspaceRecord[] };
  const workspace = workspaceList.workspaces.find((item) => item.id === workspaceId);
  if (!workspace) return json({ error: "not_found" }, { status: 404 });
  const internalPath = match[2] || "/snapshot";
  const internalUrl = new URL(request.url);
  internalUrl.pathname = internalPath;
  const room = env.VAULT_ROOMS.get(env.VAULT_ROOMS.idFromName(workspaceId));
  const forwarded = new Request(internalUrl, request);
  const response = await room.fetch(forwarded);
  if (!internalPath.startsWith("/stream") && response.ok) {
    const clone = response.clone();
    if (internalPath === "/snapshot") {
      const snapshot = await clone.json() as { revision?: number };
      if (typeof snapshot.revision === "number") {
        await account(env, auth.login).fetch(`https://account/workspaces/${encodeURIComponent(workspaceId)}`, { method: "PATCH", body: JSON.stringify({ revision: snapshot.revision }) });
      }
    }
  }
  return response;
}

async function makeWorkspaceId(login: string, repository: string, branch: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${login.toLowerCase()}\0${repository.toLowerCase()}\0${branch}`));
  return [...new Uint8Array(bytes)].map((value) => value.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

const requestHandler = createRequestHandler(() => import("virtual:react-router/server-build"), import.meta.env.MODE);

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/")) {
      try { return await api(request, env); }
      catch (error) { return json({ error: "server_error", message: error instanceof Error ? error.message : "Unexpected error" }, { status: 500 }); }
    }
    return requestHandler(request);
  },
} satisfies ExportedHandler<Env>;
