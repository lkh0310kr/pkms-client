# PKMS: Markdown Vault Viewer

A native SwiftUI iOS/iPadOS viewer for a folder of Markdown files. The files are the source of truth. The folder can be pulled from a GitHub repository, public or private.

## Run

Open `PKMS.xcodeproj` in Xcode 26 and run the `PKMS` scheme. The Markdown parser (`swift-markdown`) is resolved by Swift Package Manager.

## Vault location

`Application Support/vault/`. On first launch it's seeded with `SampleVault/`, and an existing vault is never overwritten. Folder structure and filenames are kept as-is. `.git` and hidden files are ignored. Pull to refresh re-scans the vault.

To add notes on the simulator:

```sh
open "$(xcrun simctl get_app_container booted com.lkh0310kr.pkms data)/Library/Application Support/vault"
```

## Architecture

```
LocalVaultRepository (files on disk)  →  FileIndex (derived tree + lookups)
        ↓ VaultRepository protocol
VaultStore (@Observable)  →  MarkdownParser → MarkdownDocument  →  SwiftUI views
```

| Layer | Files |
|---|---|
| Vault | `VaultPath`, `FileIndex`, `VaultRepository` (protocol + local impl), `VaultStore` |
| Markdown | `MarkdownParser` (swift-markdown AST → block model, wiki-link preprocessing), `MarkdownDocument` |
| Views | `RootView` (split view), `FolderView`, `DocumentView`, `MarkdownView`, `TableView`, `VaultImageView` |

| Sync | `GitHubClient` (REST), `GitHubAuth` (Device Flow + Keychain), `SyncPlanner` (3-way rules), `SyncEngine` (pull), `SyncController` (app state) |

## GitHub sync (Phase 2: pull only)

- **Sign-in:** OAuth Device Flow, with a personal access token as a fallback. The token is stored in the Keychain.
- **One-time setup for "Sign in with GitHub":** create an OAuth App at <https://github.com/settings/developers>, enable **Device Flow**, and put its Client ID in `GitHubAppConfig.clientID` (`PKMS/Sync/GitHubAuth.swift`). No client secret is needed.
- **How a pull works:** it fetches the branch head, then the recursive tree, and downloads only the blobs whose git SHA-1 differs from the local file. Downloads are checked against the SHA and written atomically.
- **Change detection:** three-way, comparing the last-synced base, the local file and the remote file. Files changed on the device are never overwritten or deleted; they're reported as local changes or conflicts.
- **Sync state** lives in `Application Support/Sync/state.json`, outside the vault.
- **Switching repositories** moves the current vault to `Application Support/Backups/`.
- **When it syncs:** on launch (after the local vault is shown), on returning to the foreground (at most once a minute), on pull-to-refresh, and from Settings → Sync Now.
- **Not handled yet:** hidden paths (`.github/`, `.obsidian/`), symlinks and submodules are skipped. Repositories too large for GitHub's tree API aren't supported yet.

## Supported syntax

Headings, emphasis, strikethrough, inline and fenced code, links, nested, ordered, and task lists, blockquotes, rules, GFM tables, and images (relative paths, remote URLs). Obsidian-style syntax: `[[Page]]`, `[[Page|Alias]]`, `![[image.png]]`. YAML front matter is hidden.
