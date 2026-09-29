import Foundation
import Observation

/// App-wide view model for the vault: owns the current index and all user-initiated file changes.
@MainActor
@Observable
final class VaultStore {
    /// A rename or move, published so open views can follow the file to its new path.
    struct Move: Equatable {
        let from: VaultPath
        let to: VaultPath
    }

    let repository: any VaultRepository
    private(set) var index: FileIndex = .empty
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Incremented on every reload so open documents know to re-read their file.
    private(set) var revision = 0
    private(set) var lastMove: Move?
    /// A newly created note that should open straight into the editor.
    var pendingEdit: VaultPath?

    /// Called whenever the user changes a file, so sync can upload it.
    @ObservationIgnored var onLocalChange: () -> Void = {}
    /// Editors with unsaved text register here so sync can save them first.
    @ObservationIgnored private var flushers: [UUID: () -> Void] = [:]

    init(repository: any VaultRepository) {
        self.repository = repository
    }

    /// Rebuilds the index from disk. Call on launch, on pull-to-refresh, and after a sync.
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

    // MARK: - Editing

    func save(_ text: String, to path: VaultPath) throws {
        try repository.writeText(text, to: path)
        onLocalChange()
    }

    /// Creates an empty note named "Untitled" in `folder` and marks it for editing.
    func createNote(in folder: VaultPath) async throws -> VaultPath {
        let path = uniquePath(named: "Untitled", extension: "md", in: folder)
        try repository.writeText("# ", to: path)
        pendingEdit = path
        await changedStructure()
        return path
    }

    func createFolder(named name: String, in folder: VaultPath) async throws -> VaultPath {
        let path = uniquePath(named: Self.fileName(from: name, fallback: "New Folder"), extension: nil, in: folder)
        try repository.createFolder(at: path)
        await changedStructure()
        return path
    }

    /// Renames a note or folder. Notes keep their `.md` extension; the name is cleaned of characters
    /// that can't appear in file names.
    @discardableResult
    func rename(_ path: VaultPath, to name: String) async throws -> VaultPath {
        let node = index.node(at: path)
        let isNote = node?.kind == .markdown || path.isMarkdown
        let base = Self.fileName(from: name, fallback: isNote ? "Untitled" : "New Folder")
        let newName = isNote ? base + "." + (path.pathExtension.isEmpty ? "md" : path.pathExtension) : base
        let destination = path.parent.appending(newName)
        guard destination != path else { return path }
        flushPendingEdits()
        try repository.move(path, to: destination)
        lastMove = Move(from: path, to: destination)
        await changedStructure()
        return destination
    }

    func delete(_ path: VaultPath) async throws {
        try repository.delete(path)
        await changedStructure()
    }

    /// Returns `path` unless a file already exists there, in which case " 2", " 3", … is appended.
    func uniquePath(named name: String, extension ext: String?, in folder: VaultPath) -> VaultPath {
        func candidate(_ n: Int) -> VaultPath {
            let base = n == 1 ? name : "\(name) \(n)"
            return folder.appending(ext.map { "\(base).\($0)" } ?? base)
        }
        var n = 1
        while repository.exists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Turns a title into a safe file name (without extension).
    static func fileName(from title: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    private func changedStructure() async {
        await reload()
        onLocalChange()
    }

    // MARK: - Pending edits

    func registerFlush(_ id: UUID, _ flush: @escaping () -> Void) { flushers[id] = flush }
    func unregisterFlush(_ id: UUID) { flushers[id] = nil }

    /// Saves any text still waiting in an open editor's debounce.
    func flushPendingEdits() {
        flushers.values.forEach { $0() }
    }
}
