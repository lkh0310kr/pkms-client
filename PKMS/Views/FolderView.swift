import SwiftUI

/// Lists the subfolders and Markdown documents of one vault folder.
struct FolderView: View {
    let folder: VaultPath
    @Binding var selection: VaultPath?

    @Environment(VaultStore.self) private var store
    @Environment(SyncController.self) private var sync
    @State private var query = ""
    @State private var showsSettings = false

    var body: some View {
        if folder.isRoot {
            list
                .searchable(text: $query, prompt: "Search notes")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        syncIndicator
                        Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    }
                }
                .sheet(isPresented: $showsSettings) { SettingsView() }
        } else {
            list
        }
    }

    @ViewBuilder
    private var syncIndicator: some View {
        switch sync.status {
        case .syncing:
            ProgressView()
        case .failed:
            Button("Sync Failed", systemImage: "exclamationmark.icloud") { showsSettings = true }
                .tint(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var node: VaultNode? { store.index.node(at: folder) }

    /// Folders without any Markdown inside (e.g. `Assets/`) are hidden from browsing;
    /// their files are still used to resolve images.
    private var visibleChildren: [VaultNode] {
        (node?.children ?? []).filter(\.containsMarkdown)
    }

    private var list: some View {
        List(selection: $selection) {
            if !query.isEmpty {
                ForEach(store.index.search(query), id: \.path.string) { file in
                    NavigationLink(value: file.path) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(file.displayName)
                                if !file.path.parent.isRoot {
                                    Text(file.path.parent.string).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                    .tag(Optional(file.path))
                }
            } else {
                // Rows are keyed by string so only documents carry a `VaultPath` selection tag;
                // otherwise tapping a folder would select it as if it were a document.
                ForEach(visibleChildren, id: \.path.string) { child in
                    if child.isFolder {
                        NavigationLink(value: FolderRoute(path: child.path)) {
                            Label(child.displayName, systemImage: "folder")
                        }
                    } else {
                        NavigationLink(value: child.path) {
                            Label(child.displayName, systemImage: "doc.text")
                        }
                        .tag(Optional(child.path))
                    }
                }
            }
        }
        .navigationTitle(node?.displayName ?? folder.name)
        .refreshable {
            if sync.repository != nil { await sync.sync() }
            await store.reload()
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty, store.index.search(query).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if query.isEmpty, visibleChildren.isEmpty {
            if store.isLoading {
                ProgressView()
            } else if let error = store.loadError {
                ContentUnavailableView("Couldn’t Open Vault", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ContentUnavailableView("No Notes", systemImage: "folder",
                                       description: Text("Add Markdown files to this folder."))
            }
        }
    }
}
