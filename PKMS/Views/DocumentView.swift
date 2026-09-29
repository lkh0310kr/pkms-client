import SwiftUI

/// Shows one note, rendered for reading, with an Edit mode for changing it.
struct DocumentView: View {
    let path: VaultPath

    @Environment(VaultStore.self) private var store
    @Environment(SyncController.self) private var sync
    @Environment(\.openDocument) private var openDocument
    @State private var state: LoadState = .loading
    @State private var rawText: String?
    @State private var isEditing = false
    @State private var focusEditor = false
    @State private var editorText = ""
    @State private var reviewingConflict = false

    private enum LoadState {
        case loading
        case loaded(MarkdownDocument)
        case failed(String)
    }

    var body: some View {
        Group {
            if isEditing, let rawText {
                NoteEditorView(path: path, initialText: rawText, focusOnAppear: focusEditor, text: $editorText)
            } else {
                content
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { conflictBanner }
        .navigationTitle(titleBinding)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SyncStatusIcon() }
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") { Task { await finishEditing() } }
                        .fontWeight(.semibold)
                } else {
                    Button("Edit", systemImage: "square.and.pencil") { startEditing(focus: true) }
                        .disabled(rawText == nil)
                }
            }
        }
        .task(id: "\(path)#\(store.revision)") {
            if !isEditing { await load() }
        }
        .onAppear {
            if store.pendingEdit == path {
                store.pendingEdit = nil
                Task {
                    await load()
                    startEditing(focus: true)
                }
            }
        }
        .onDisappear {
            if isEditing { Task { await finishEditing() } }
        }
        .environment(\.openURL, OpenURLAction(handler: open))
        .sheet(isPresented: $reviewingConflict) {
            if let copy = sync.conflicts[path] {
                ConflictReviewView(path: path, remoteCopy: copy)
            }
        }
    }

    /// Renaming from the title menu renames the file.
    private var titleBinding: Binding<String> {
        Binding {
            path.baseName
        } set: { newTitle in
            Task { try? await store.rename(path, to: newTitle) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("Couldn’t Open Note", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .loaded(let document):
            ScrollView {
                if document.blocks.isEmpty {
                    Button { startEditing(focus: true) } label: {
                        Text("Empty note. Tap to start writing.")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    .buttonStyle(.plain)
                } else {
                    MarkdownView(blocks: document.blocks, lazy: true)
                        .environment(\.markdownDocumentPath, path)
                        .environment(\.toggleTask, TaskToggleAction { line in
                            Task { try? await store.toggleTask(atLine: line + document.lineOffset, in: path) }
                        })
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                }
            }
            .refreshable {
                await sync.sync()
                await load()
            }
        }
    }

    @ViewBuilder
    private var conflictBanner: some View {
        if sync.conflicts[path] != nil {
            Button { reviewingConflict = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Also edited on another device").font(.subheadline.weight(.semibold))
                        Text("Both versions were kept. Tap to review.").font(.caption)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(12)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Loading and editing

    private func load() async {
        do {
            let text = try await store.repository.readText(at: path)
            let document = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(text) }.value
            rawText = text
            state = .loaded(document)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startEditing(focus: Bool) {
        guard let rawText else { return }
        editorText = rawText
        focusEditor = focus
        withAnimation(.easeInOut(duration: 0.15)) { isEditing = true }
    }

    private func finishEditing() async {
        store.flushPendingEdits()
        let text = editorText
        rawText = text
        state = .loaded(MarkdownParser.parse(text))
        withAnimation(.easeInOut(duration: 0.15)) { isEditing = false }
        await renameUntitledNote(from: text)
        sync.scheduleSync(after: .seconds(1))
    }

    /// New notes start as "Untitled"; once they have a first line, the file takes that as its name.
    private func renameUntitledNote(from text: String) async {
        guard path.baseName.range(of: #"^Untitled( \d+)?$"#, options: .regularExpression) != nil,
              let firstLine = text.components(separatedBy: "\n").first(where: {
                  !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.trimmingCharacters(in: .whitespaces) != "#"
              }) else { return }
        let title = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*[] ").union(.whitespaces))
        guard !title.isEmpty, title != path.baseName else { return }
        let unique = store.uniquePath(named: VaultStore.fileName(from: title, fallback: "Untitled"), extension: "md", in: path.parent).baseName
        _ = try? await store.rename(path, to: unique)
    }

    /// Routes taps on links: vault documents open in-app, web links go to the system.
    private func open(_ url: URL) -> OpenURLAction.Result {
        let string = url.absoluteString
        let resolved: VaultPath?
        if let target = WikiLink.target(in: string) {
            resolved = store.index.resolve(target, from: path, isWikiLink: true)
        } else if url.scheme == nil {
            if string.hasPrefix("#") { return .handled }  // in-page anchors: not supported yet
            resolved = store.index.resolve(string, from: path, isWikiLink: false)
        } else {
            return .systemAction
        }
        guard let resolved, resolved.isMarkdown else { return .discarded }
        openDocument(resolved)
        return .handled
    }
}

/// A small cloud icon summarizing sync: uploading, waiting to upload, failed, or all synced.
struct SyncStatusIcon: View {
    @Environment(SyncController.self) private var sync

    var body: some View {
        if sync.repository != nil {
            Group {
                switch sync.status {
                case .syncing:
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                        .accessibilityLabel("Sync failed: \(message)")
                case .idle:
                    if !sync.conflicts.isEmpty {
                        Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                            .accessibilityLabel("Needs review")
                    } else if sync.hasLocalChanges {
                        Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                            .accessibilityLabel(sync.isSignedIn ? "Waiting to sync" : "Sign in to sync changes")
                    } else {
                        Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
                            .accessibilityLabel("Synced")
                    }
                }
            }
            .font(.footnote)
            .animation(.default, value: sync.isSyncing)
        }
    }
}

/// Side-by-side choice between this device's version of a note and GitHub's.
struct ConflictReviewView: View {
    let path: VaultPath
    let remoteCopy: VaultPath

    @Environment(VaultStore.self) private var store
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var showing = 0
    @State private var local: MarkdownDocument?
    @State private var remote: MarkdownDocument?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Version", selection: $showing) {
                    Text("This Device").tag(0)
                    Text("GitHub").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                ScrollView {
                    if let document = showing == 0 ? local : remote {
                        MarkdownView(blocks: document.blocks)
                            .environment(\.markdownDocumentPath, path)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 10) {
                    Button { resolve(.keepLocal) } label: {
                        Text("Keep This Device’s Version").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { resolve(.keepRemote) } label: {
                        Text("Keep GitHub’s Version").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button("Keep Both as Separate Notes") { resolve(.keepBoth) }
                        .font(.subheadline)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .navigationTitle(path.baseName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
            .task {
                local = try? await MarkdownParser.parse(store.repository.readText(at: path))
                remote = try? await MarkdownParser.parse(store.repository.readText(at: remoteCopy))
            }
        }
    }

    private func resolve(_ resolution: SyncEngine.Resolution) {
        dismiss()
        Task { await sync.resolveConflict(path, resolution) }
    }
}
