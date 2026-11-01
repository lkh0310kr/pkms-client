import { createClient, type RealtimeChannel, type SupabaseClient } from "@supabase/supabase-js";

export interface RealtimeUser { login: string; avatarUrl?: string }
export interface RealtimeEnvelope { type: string; fileId?: string; update?: string; operationId?: string; acceptedRevision?: number; conflictCopyPath?: string; revision?: number; message?: string; code?: string; [key: string]: unknown }
type Api = <T>(path: string, init?: RequestInit) => Promise<T>;

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
      this.client = createClient(config.url, config.anonKey, {
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      });
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
      channel.subscribe((status) => {
        if (status === "SUBSCRIBED") {
          this.readyState = 1;
          this.onopen?.();
          this.tokenTimer = window.setInterval(() => { void this.refreshToken(); }, 10 * 60 * 1000);
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
          this.readyState = 3;
          if (!this.closed) this.onclose?.();
        }
      });
    } catch {
      this.readyState = 3;
      if (!this.closed) this.onclose?.();
    }
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
    this.closed = true;
    this.readyState = 3;
    window.clearInterval(this.tokenTimer);
    if (this.channel) void this.client?.removeChannel(this.channel);
    this.onclose?.();
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
