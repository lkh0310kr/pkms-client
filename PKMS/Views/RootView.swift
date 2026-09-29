import SwiftUI

/// Navigation value for drilling into a folder. Distinct from `VaultPath` so that folder
/// links push onto the sidebar stack instead of changing the selected document.
struct FolderRoute: Hashable {
    let path: VaultPath
}

/// Opens another vault document on top of the current one, e.g. when a link is tapped.
struct OpenDocumentAction {
    let handler: @MainActor (VaultPath) -> Void
    @MainActor func callAsFunction(_ path: VaultPath) { handler(path) }
}

extension EnvironmentValues {
    @Entry var openDocument = OpenDocumentAction { _ in }
}

/// Split view on iPad (files | document); collapses into a single stack on iPhone.
struct RootView: View {
    @Environment(VaultStore.self) private var store
    @State private var folderStack: [FolderRoute] = []
    @State private var selection: VaultPath?
    /// Documents opened by following links from the selected document.
    @State private var linkedDocuments: [VaultPath] = []

    var body: some View {
        NavigationSplitView {
            NavigationStack(path: $folderStack) {
                FolderView(folder: .root, selection: $selection)
                    .navigationDestination(for: FolderRoute.self) { route in
                        FolderView(folder: route.path, selection: $selection)
                    }
            }
        } detail: {
            NavigationStack(path: $linkedDocuments) {
                Group {
                    if let selection {
                        DocumentView(path: selection).id(selection)
                    } else {
                        ContentUnavailableView("No Document Selected", systemImage: "doc.text",
                                               description: Text("Choose a note from the sidebar."))
                    }
                }
                .navigationDestination(for: VaultPath.self) { DocumentView(path: $0) }
            }
            .environment(\.openDocument, OpenDocumentAction { linkedDocuments.append($0) })
        }
        .onChange(of: selection) { old, new in
            // Following a rename keeps the navigation history; choosing another note resets it.
            if let move = store.lastMove, old?.movingPrefix(move.from, to: move.to) == new { return }
            linkedDocuments.removeAll()
        }
        .onChange(of: store.lastMove) { _, move in
            guard let move else { return }
            linkedDocuments = linkedDocuments.map { $0.movingPrefix(move.from, to: move.to) ?? $0 }
            folderStack = folderStack.map { FolderRoute(path: $0.path.movingPrefix(move.from, to: move.to) ?? $0.path) }
            if let moved = selection?.movingPrefix(move.from, to: move.to) { selection = moved }
        }
    }
}
