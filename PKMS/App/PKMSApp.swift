import SwiftUI

@main
struct PKMSApp: App {
    @State private var store: VaultStore
    @State private var sync: SyncController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let repository = (try? LocalVaultRepository.prepareDefault())
            ?? LocalVaultRepository(rootURL: LocalVaultRepository.defaultRootURL)
        let store = VaultStore(repository: repository)
        _store = State(initialValue: store)
        _sync = State(initialValue: SyncController(vault: store, vaultRoot: repository.rootURL))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sync)
                .task {
                    // Local-first: show what's on disk immediately, then pull from GitHub in the background.
                    await store.reload()
                    await sync.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await sync.syncIfStale() } }
                }
        }
    }
}
