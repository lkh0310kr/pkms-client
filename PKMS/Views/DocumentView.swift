import SwiftUI

/// Loads one Markdown file from the vault and renders it.
struct DocumentView: View {
    let path: VaultPath

    @Environment(VaultStore.self) private var store
    @Environment(\.openDocument) private var openDocument
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(MarkdownDocument)
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle(path.baseName)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(path)#\(store.revision)") { await load() }
            .environment(\.openURL, OpenURLAction(handler: open))
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
                MarkdownView(blocks: document.blocks, lazy: true)
                    .environment(\.markdownDocumentPath, path)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            let text = try await store.repository.readText(at: path)
            let document = await Task.detached(priority: .userInitiated) { MarkdownParser.parse(text) }.value
            state = .loaded(document)
        } catch {
            state = .failed(error.localizedDescription)
        }
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
