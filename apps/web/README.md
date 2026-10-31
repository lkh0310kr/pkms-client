# PKMS web and Cloudflare backend

The React Router app and API run in one Cloudflare Worker. Durable Objects hold each account's encrypted GitHub credentials and each workspace's collaboration state, SQLite change log, WebSocket room, and GitHub flush alarm. R2 holds attachments. No paid database or separate worker is required for the personal deployment.

## Local setup

1. Install dependencies from the repository root with `npm install`.
2. Create a GitHub App configured for user authorization, enable expiring user access tokens, and grant repository Contents read/write permission. Set its callback URL to `http://localhost:5173/api/auth/github/callback`.
3. Copy `.dev.vars.example` to `.dev.vars`; fill in the app client ID/secret, a random session HMAC secret, and a base64-encoded 32-byte AES key. Generate the AES key with `openssl rand -base64 32`.
4. Create the attachment bucket once with `npx wrangler r2 bucket create pkms-attachments`.
5. Start with `npm run dev` from the repository root.

The current deployment uses `https://pkms-cloud.lkh0310kr.workers.dev` as `PUBLIC_ORIGIN`. Its `SESSION_SECRET` and `DATA_ENCRYPTION_KEY` are already configured. Configure the GitHub App callback URL as `https://pkms-cloud.lkh0310kr.workers.dev/api/auth/github/callback`, then add `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` with `npx wrangler secret put NAME` to enable sign-in.

## Login diagnostics

Each request returns an `X-Request-ID`. Sign-in failures show this ID on the page and emit structured stage events without OAuth codes, tokens, cookies, or request query strings. Stored invocation logs are disabled. To follow only safe application events, run this from the web app directory:

```sh
npx wrangler tail pkms-cloud --format json | jq --unbuffered 'select((.logs // [] | length) > 0 or (.exceptions // [] | length) > 0) | del(.event)'
```

Match the log `requestId` to the ID shown in the browser. Filtering removes the request URL and headers from the tail output.

## Personal free-tier deployment

The app uses SQLite-backed Durable Objects and hibernatable WebSockets. One workspace room serializes updates and sets an alarm on the first pending change; the alarm batches GitHub commits no later than 15 minutes after that change. External branch movement pauses automatic commits. Free-plan limit exhaustion can make writes fail, so the UI must retain the local IndexedDB cache and show retry state.

Deploy with `npm run deploy` after authenticating Wrangler using `npx wrangler login`. The first deployment requires the Durable Object migration and R2 bucket binding in `wrangler.jsonc`.

## Current scope

- GitHub App OAuth login and token refresh; no long-lived GitHub token is sent to browser storage.
- Workspace selection lists writable repositories.
- Markdown CRDT updates use Yjs/Yrs v1 encoding and are persisted before acknowledgements.
- Markdown documents are cached in IndexedDB and shared over a workspace WebSocket.
- File create/move/delete operations and attachment uploads are persisted in the room.
- GitHub REST Git Data API commits are batched, retried, and guarded against unexpected branch head changes.
- Binary uploads have a 50 MiB PKMS limit to keep GitHub blob requests within practical Worker payload limits.

## Configuration

| Name | Required | Purpose |
|---|---|---|
| `GITHUB_CLIENT_ID` | Yes | GitHub App OAuth client ID |
| `GITHUB_CLIENT_SECRET` | Yes | Server-only OAuth exchange and token refresh |
| `SESSION_SECRET` | Yes | HMAC signing key for the HttpOnly session cookie |
| `DATA_ENCRYPTION_KEY` | Yes | Base64 32-byte key for encrypting OAuth tokens at rest |
| `PUBLIC_ORIGIN` | Yes | Public origin used in OAuth callback and origin checks |
| `ACCOUNTS` | Binding | Account Durable Object namespace |
| `VAULT_ROOMS` | Binding | Workspace Durable Object namespace |
| `ASSET_BUCKET` | Binding | R2 attachment bucket |
