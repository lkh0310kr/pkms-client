import Foundation
import Observation

/// App-wide view model for the vault: owns the current index and exposes it to the UI.
@MainActor
@Observable
final class VaultStore {
    let repository: any VaultRepository
    private(set) var index: FileIndex = .empty
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Incremented on every reload so open documents know to re-read their file.
    private(set) var revision = 0

    init(repository: any VaultRepository) {
        self.repository = repository
    }

    /// Rebuilds the index from disk. Call on launch, on pull-to-refresh, and (later) after a sync.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            index = try await repository.loadIndex()
            loadError = nil
            revision += 1
        } catch {
            loadError = error.localizedDescription
        }
    }
}
