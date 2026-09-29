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

## Editing (Phase 3)

- **Live-styled editor:** you edit plain Markdown, but headings, emphasis, code and links are styled as you type. Syntax characters are dimmed.
- **`/` menu:** type `/` at a line start (or after a space) to get headings, to-do, bulleted and numbered lists, quote, code and divider. `[[` suggests pages to link.
- **Lists:** Return continues a list. Return on an empty item outdents it or ends the list, leaving a blank line so Markdown keeps the next paragraph separate. There's a formatting bar above the keyboard. On iPad: ⌘B, ⌘I, ⌘K, ⌘L, and Tab / ⇧Tab to indent.
- **Saving:** notes save automatically (600 ms after typing stops).
- **New notes:** a new note opens in the editor. An "Untitled" note takes its first line as its file name. You can rename from the title menu or the folder list.
- **Read mode:** checkboxes can be tapped directly.

## GitHub sync (two-way)

- **Sign-in:** OAuth Device Flow, with a personal access token as a fallback. The token is stored in the Keychain.
- **One-time setup for "Sign in with GitHub":** create an OAuth App at <https://github.com/settings/developers>, enable **Device Flow**, and put its Client ID in `GitHubAppConfig.clientID` (`PKMS/Sync/GitHubAuth.swift`). No client secret is needed.
- **Upload:** local edits are uploaded about 4 seconds after they're saved, when leaving the editor, and when the app goes to the background. They're sent as one commit through the Git Data API (blobs → tree → commit → fast-forward ref update). If the branch moved in the meantime, the app pulls again and retries.
- **How a pull works:** it fetches the branch head, then the recursive tree, and downloads only the blobs whose git SHA-1 differs from the local file. Downloads are checked against the SHA and written atomically.
- **Change detection:** three-way, comparing the last-synced base, the local file and the remote file. An edit always wins over a delete.
- **Edits on both sides:** they're merged line by line when they touch different lines. Otherwise GitHub's version is saved as `Note (GitHub version).md` and held back from upload until the user picks *this device*, *GitHub* or *both* in the review sheet.
- **Sync state** lives in `Application Support/Sync/state.json`, outside the vault.
- **Switching repositories** moves the current vault to `Application Support/Backups/`.
- **When it syncs:** on launch (after the local vault is shown), on returning to the foreground (at most once a minute), on pull-to-refresh, and from Settings → Sync Now.
- **Not handled yet:** hidden paths (`.github/`, `.obsidian/`), symlinks and submodules are skipped. Repositories too large for GitHub's tree API aren't supported yet.

## Supported syntax

Headings, emphasis, strikethrough, inline and fenced code, links, nested, ordered, and task lists, blockquotes, rules, GFM tables, and images (relative paths, remote URLs). Obsidian-style syntax: `[[Page]]`, `[[Page|Alias]]`, `![[image.png]]`. YAML front matter is hidden.
