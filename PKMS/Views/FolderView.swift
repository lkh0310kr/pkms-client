import SwiftUI

/// Lists the subfolders and Markdown documents of one vault folder.
struct FolderView: View {
    let folder: VaultPath
    @Binding var selection: VaultPath?

    @Environment(VaultStore.self) private var store
    @Environment(SyncController.self) private var sync
    @State private var query = ""
    @State private var showsSettings = false
    @State private var naming: NamingTask?
    @State private var nameText = ""
    @State private var pendingDelete: VaultNode?
    @State private var error: String?

    /// What the name prompt is for.
    private enum NamingTask: Identifiable {
        case newFolder
        case rename(VaultNode)

        var id: String {
            switch self {
            case .newFolder: "new-folder"
            case .rename(let node): "rename-\(node.path)"
            }
        }
    }

    var body: some View {
        Group {
            if folder.isRoot {
                list
                    .searchable(text: $query, prompt: "Search notes")
                    .sheet(isPresented: $showsSettings) { SettingsView() }
            } else {
                list
            }
        }
        .toolbar {
            if folder.isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { SyncStatusIcon() }
                        .accessibilityLabel("Sync status")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Note", systemImage: "square.and.pencil") { createNote() }
                    Button("New Folder", systemImage: "folder.badge.plus") { startNaming(.newFolder) }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                } primaryAction: {
                    createNote()
                }
            }
        }
        .alert(namingTitle, isPresented: isNaming) {
            TextField("Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button(namingConfirm) { commitNaming() }
        }
        .confirmationDialog(deleteTitle, isPresented: isDeleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDelete() }
        } message: {
            Text(sync.repository != nil ? "It will also be removed from GitHub. You can recover it from the repository’s history." : "This can’t be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var node: VaultNode? { store.index.node(at: folder) }

    /// Asset-only folders (e.g. `Assets/`) are hidden from browsing; their files are still used for images.
    private var visibleChildren: [VaultNode] {
        (node?.children ?? []).filter(\.isBrowsable)
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
                    row(for: child)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startNaming(.rename(child)) }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = child }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = child }
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
    private func row(for child: VaultNode) -> some View {
        if child.isFolder {
            NavigationLink(value: FolderRoute(path: child.path)) {
                Label(child.displayName, systemImage: "folder")
            }
        } else {
            NavigationLink(value: child.path) {
                Label {
                    Text(child.displayName)
                } icon: {
                    Image(systemName: sync.conflicts[child.path] != nil ? "exclamationmark.triangle" : "doc.text")
                        .foregroundStyle(sync.conflicts[child.path] != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                }
            }
            .tag(Optional(child.path))
        }
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
                ContentUnavailableView {
                    Label("No Notes", systemImage: "square.and.pencil")
                } description: {
                    Text("Notes you create here are saved as Markdown files.")
                } actions: {
                    Button("New Note") { createNote() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Actions

    private func createNote() {
        Task {
            do {
                selection = try await store.createNote(in: folder)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startNaming(_ task: NamingTask) {
        switch task {
        case .newFolder: nameText = ""
        case .rename(let node): nameText = node.displayName
        }
        naming = task
    }

    private var isNaming: Binding<Bool> {
        Binding { naming != nil } set: { if !$0 { naming = nil } }
    }

    private var namingTitle: String {
        switch naming {
        case .rename: "Rename"
        default: "New Folder"
        }
    }

    private var namingConfirm: String {
        switch naming {
        case .rename: "Rename"
        default: "Create"
        }
    }

    private func commitNaming() {
        guard let task = naming else { return }
        let name = nameText
        Task {
            do {
                switch task {
                case .newFolder:
                    _ = try await store.createFolder(named: name, in: folder)
                case .rename(let node):
                    try await store.rename(node.path, to: name)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } }
    }

    private var deleteTitle: String {
        guard let pendingDelete else { return "" }
        return pendingDelete.isFolder
            ? "Delete “\(pendingDelete.displayName)” and everything in it?"
            : "Delete “\(pendingDelete.displayName)”?"
    }

    private func commitDelete() {
        guard let node = pendingDelete else { return }
        if let selection, selection.hasPrefix(node.path) { self.selection = nil }
        Task {
            do {
                try await store.delete(node.path)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
