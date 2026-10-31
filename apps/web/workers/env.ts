export interface Env {
  ACCOUNTS: DurableObjectNamespace;
  VAULT_ROOMS: DurableObjectNamespace;
  ASSET_BUCKET: R2Bucket;
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  SESSION_SECRET: string;
  DATA_ENCRYPTION_KEY: string;
  PUBLIC_ORIGIN: string;
}

export interface Session {
  login: string;
  avatarUrl?: string;
  expiresAt: number;
}

export interface WorkspaceRecord {
  id: string;
  repository: string;
  branch: string;
  githubStatus: "synced" | "pending" | "failed" | "external-change";
  revision: number;
  lastGitHubCommitAt?: string;
  message?: string;
}
