# PKMS: Markdown Vault

A native SwiftUI iOS/iPadOS app for a folder of Markdown files, with a live-preview editor. The files are the source of truth. The folder syncs both ways with a GitHub repository, public or private.

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
| Views | `RootView` (split view), `FolderView`, `DocumentView` (hosts the editor), `MarkdownView` (conflict review), `TableView`, `VaultImageView` |
| Editor | `MarkdownEditorView` (text view + taps), `MarkdownHighlighter` (live-preview styling), `LivePreview` (layout manager, decorations, widget cache), `MarkdownEditing` (pure editing commands), `NoteEditorView` (autosave, menus, formatting bar) |
| Sync | `GitHubClient` (REST), `GitHubAuth` (Device Flow + Keychain), `SyncPlanner` (3-way rules), `TextMerge`, `SyncEngine` (pull + upload), `SyncController` (app state) |

## Editing: live preview

There's no separate viewer. A note is always the editor, and it works like Obsidian's Live Preview:

- **Rendered in place:** everywhere except the line you're editing, Markdown syntax is hidden. Headings, bold and links render; checkboxes, bullets and rules are drawn; images and tables show as pictures. With the keyboard down, the whole note reads as a rendered page.
- **Tap to edit:** tap text to edit it, and that line shows its syntax (dimmed). Tap a checkbox to toggle it without opening the keyboard. Tap a link to follow it. Tap an image or table to edit its source.
- **How it works:** the text view holds the exact Markdown. `MarkdownHighlighter` marks syntax as hidden and adds decorations. `LivePreviewLayoutManager` (TextKit 1) turns hidden characters into zero-width glyphs and draws the decorations. Nothing is ever inserted into the text, so the file stays plain Markdown.
- **`/` menu:** type `/` at a line start (or after a space) to get headings, to-do, bulleted and numbered lists, quote, code and divider. `[[` suggests pages to link.
- **Lists:** Return continues a list. Return on an empty item outdents it or ends the list, leaving a blank line so Markdown keeps the next paragraph separate. There's a formatting bar above the keyboard. On iPad: ⌘B, ⌘I, ⌘K, ⌘L, and Tab / ⇧Tab to indent.
- **Saving:** notes save automatically (600 ms after typing stops).
- **New notes:** a new note opens with the keyboard up. When the keyboard goes away, an "Untitled" note takes its first line as its file name. You can rename from the title menu or the folder list.

## GitHub sync (two-way)

- **Sign-in:** GitHub App Device Flow, with a personal access token as a fallback. Credentials are stored in the Keychain. User access tokens expire after 8 hours; the app refreshes them (and rotates the refresh token, which lasts 6 months) automatically.
- **One-time setup for "Sign in with GitHub":** create a GitHub App at <https://github.com/settings/apps/new>, enable **Device Flow**, set Contents to Read and write, turn off the webhook, and put its Client ID in `GitHubAppConfig.clientID` (`PKMS/Sync/GitHubAuth.swift`). No client secret is needed.
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
