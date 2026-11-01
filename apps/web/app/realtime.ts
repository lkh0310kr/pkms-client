import { createClient, type RealtimeChannel, type SupabaseClient } from "@supabase/supabase-js";

export interface RealtimeUser { login: string; avatarUrl?: string }
export interface RealtimeEnvelope { type: string; fileId?: string; update?: string; operationId?: string; acceptedRevision?: number; conflictCopyPath?: string; revision?: number; message?: string; code?: string; [key: string]: unknown }
type Api = <T>(path: string, init?: RequestInit) => Promise<T>;
type RealtimeStatus = "SUBSCRIBED" | "CHANNEL_ERROR" | "TIMED_OUT" | "CLOSED" | "CONNECT_ERROR" | "SOCKET_CREATED" | "SOCKET_OPEN" | "SOCKET_CLOSE" | "SOCKET_ERROR";
const clients = new Map<string, SupabaseClient>();
let reportSocketEvent: ((status: "SOCKET_CREATED" | "SOCKET_OPEN" | "SOCKET_CLOSE" | "SOCKET_ERROR", closeCode?: number, wasClean?: boolean) => void) | undefined;
class DiagnosticWebSocket extends WebSocket {
  constructor(url: string | URL, protocols?: string | string[]) {
    super(url, protocols);
    reportSocketEvent?.("SOCKET_CREATED");
    this.addEventListener("open", () => reportSocketEvent?.("SOCKET_OPEN"));
    this.addEventListener("close", (event) => reportSocketEvent?.("SOCKET_CLOSE", event.code, event.wasClean));
    this.addEventListener("error", () => reportSocketEvent?.("SOCKET_ERROR"));
  }
}
function sharedClient(url: string, anonKey: string): SupabaseClient {
  const key = `${url}\0${anonKey}`;
  let client = clients.get(key);
  if (!client) {
    client = createClient(url, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      realtime: { transport: DiagnosticWebSocket },
    });
    clients.set(key, client);
  }
  return client;
}
function errorMetadata(error: unknown): { errorType?: string; errorCode?: string } {
  if (!error || typeof error !== "object") return {};
  const value = error as { name?: unknown; code?: unknown };
  const safe = (input: unknown) => typeof input === "string" && /^[A-Za-z0-9_.:-]{1,64}$/.test(input) ? input : undefined;
  return { errorType: safe(value.name), errorCode: safe(value.code) };
}

export class PKMSRealtimeSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent<string>) => void) | null = null;
  onclose: (() => void) | null = null;
  private client?: SupabaseClient;
  private channel?: RealtimeChannel;
  private tokenTimer = 0;
  private closed = false;

  constructor(private readonly workspaceId: string, private readonly clientId: string, private readonly user: RealtimeUser, private readonly api: Api) {}

  async connect(): Promise<void> {
    try {
      const config = await this.api<{ url: string; anonKey: string }>("/api/realtime/config");
      const initial = await this.api<{ token: string }>("/api/realtime/token");
      if (this.closed) return;
      reportSocketEvent = (status, closeCode, wasClean) => { void this.reportStatus(status, undefined, closeCode, wasClean); };
      this.client = sharedClient(config.url, config.anonKey);
      this.client.realtime.setAuth(initial.token);
      const channel = this.client.channel(`pkms:${this.workspaceId}`, {
        config: { private: true, presence: { key: this.clientId }, broadcast: { self: false } },
      });
      this.channel = channel;
      channel.on("broadcast", { event: "protocol" }, ({ payload }) => this.dispatch(payload as RealtimeEnvelope));
      const dispatchPeers = () => {
        const peers = Object.values(channel.presenceState()).flat().map((presence) => presence as unknown as Record<string, unknown>);
        this.dispatch({ type: "presence-state", peers } as RealtimeEnvelope);
      };
      channel.on("presence", { event: "sync" }, dispatchPeers);
      channel.on("presence", { event: "join" }, dispatchPeers);
      channel.on("presence", { event: "leave" }, dispatchPeers);
      channel.subscribe((status, error) => {
        if (this.closed && status === "CLOSED") return;
        if (status === "SUBSCRIBED") {
          void this.reportStatus("SUBSCRIBED");
          this.readyState = 1;
          this.onopen?.();
          this.tokenTimer = window.setInterval(() => { void this.refreshToken(); }, 10 * 60 * 1000);
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
          void this.reportStatus(status, error);
          this.readyState = 3;
          const notify = !this.closed;
          this.cleanup();
          if (notify) this.onclose?.();
        }
      });
    } catch (error) {
      void this.reportStatus("CONNECT_ERROR", error);
      this.readyState = 3;
      const notify = !this.closed;
      this.cleanup();
      if (notify) this.onclose?.();
    }
  }

  private reportStatus(status: RealtimeStatus, error?: unknown, closeCode?: number, wasClean?: boolean): Promise<void> {
    return this.api<void>(`/api/workspaces/${encodeURIComponent(this.workspaceId)}/diagnostics/realtime`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ status, ...errorMetadata(error), closeCode, wasClean, connectionState: this.client?.realtime.connectionState() }),
    }).then(() => {}).catch(() => {});
  }

  send(raw: string): void {
    const channel = this.channel;
    if (this.readyState !== 1 || !channel) return;
    let envelope: RealtimeEnvelope;
    try { envelope = JSON.parse(raw) as RealtimeEnvelope; } catch { return; }
    if (envelope.type === "hello" || envelope.type === "presence") {
      void channel.track({ clientId: this.clientId, login: this.user.login, avatarUrl: this.user.avatarUrl, fileId: envelope.fileId });
      return;
    }
    if (envelope.type !== "document-update" || !envelope.fileId || !envelope.operationId || !envelope.update) return;
    void this.api<RealtimeEnvelope>(`/api/workspaces/${encodeURIComponent(this.workspaceId)}/files/${encodeURIComponent(envelope.fileId)}/updates`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(envelope),
    }).then((ack) => this.dispatch({ ...ack, type: "ack", fileId: envelope.fileId, operationId: envelope.operationId }))
      .catch((error: unknown) => this.dispatch({ type: "error", operationId: envelope.operationId, message: error instanceof Error ? error.message : "Could not save this change." }));
  }

  close(): void {
    this.cleanup();
    this.onclose?.();
  }

  private cleanup(): void {
    this.closed = true;
    this.readyState = 3;
    window.clearInterval(this.tokenTimer);
    if (this.channel) void this.client?.removeChannel(this.channel);
    this.channel = undefined;
  }

  private async refreshToken(): Promise<void> {
    try {
      const result = await this.api<{ token: string }>("/api/realtime/token");
      this.client?.realtime.setAuth(result.token);
    } catch {
      this.dispatch({ type: "error", message: "Live sync authorization expired. Reconnecting…" });
      this.close();
    }
  }

  private dispatch(envelope: RealtimeEnvelope): void {
    if (!this.closed) this.onmessage?.({ data: JSON.stringify(envelope) } as MessageEvent<string>);
  }
}
