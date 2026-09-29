import Foundation

/// A remote copy of the vault. `GitHubRemote` is the real one; tests use an in-memory fake.
protocol RemoteVault: Sendable {
    func headCommit() async throws -> String
    /// Blob SHA of every file at `commit`, keyed by vault path.
    func files(at commit: String) async throws -> [VaultPath: String]
    func download(sha: String) async throws -> Data
}

struct GitHubRemote: RemoteVault {
    let client: GitHubClient
    let repository: String
    let branch: String

    func headCommit() async throws -> String {
        try await client.headCommit(of: repository, branch: branch)
    }

    func files(at commit: String) async throws -> [VaultPath: String] {
        let tree = try await client.tree(of: repository, commit: commit)
        var files: [VaultPath: String] = [:]
        // Regular files only (no symlinks or submodules), skipping hidden paths like `.github/` or `.obsidian/`.
        for entry in tree.tree where entry.type == "blob" && ["100644", "100755"].contains(entry.mode) {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else { continue }
            files[VaultPath(components: parts.map(String.init))] = entry.sha
        }
        return files
    }

    func download(sha: String) async throws -> Data {
        try await client.blob(of: repository, sha: sha)
    }
}

/// What sync remembers between runs, stored outside the vault in `Application Support/Sync/state.json`.
struct SyncState: Codable, Sendable {
    /// `owner/name@branch` the state belongs to.
    var repository: String
    /// Last commit fully applied to the vault.
    var commit: String?
    /// Blob SHA of each file as of the last sync: the "base" for detecting changes on either side.
    var files: [String: String] = [:]

    static let fileURL = URL.applicationSupportDirectory.appending(path: "Sync/state.json")

    static func load(from url: URL = fileURL) -> SyncState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct SyncReport: Sendable {
    var commit: String
    var downloaded = 0
    var deleted = 0
    var localChanges: [VaultPath] = []
    var conflicts: [VaultPath] = []

    var changedVault: Bool { downloaded > 0 || deleted > 0 }
}

enum SyncEngineError: LocalizedError {
    case corruptDownload(VaultPath)

    var errorDescription: String? {
        switch self {
        case .corruptDownload(let path): "“\(path.name)” didn’t download correctly."
        }
    }
}

/// Pulls a remote vault into the local vault directory.
///
/// Files are only overwritten or deleted when they haven't changed locally since the last sync,
/// so nothing edited on this device is ever lost. State is saved after every run, including
/// failed ones, so an interrupted sync resumes where it stopped.
struct SyncEngine: Sendable {
    let vaultRoot: URL
    let stateURL: URL
    let repositoryID: String
    let remote: any RemoteVault

    private static let maxConcurrentDownloads = 6

    func pull(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async throws -> SyncReport {
        var state = SyncState.load(from: stateURL).flatMap { $0.repository == repositoryID ? $0 : nil }
            ?? SyncState(repository: repositoryID)
        let head = try await remote.headCommit()
        var report = SyncReport(commit: head)
        if state.commit == head { return report }

        let remoteFiles = try await remote.files(at: head)
        var base = Dictionary(uniqueKeysWithValues: state.files.map { (VaultPath($0.key), $0.value) })
        let local = localHashes(for: Set(base.keys).union(remoteFiles.keys))
        let plan = SyncPlanner.plan(base: base, local: local, remote: remoteFiles)

        defer {
            state.files = Dictionary(uniqueKeysWithValues: base.map { ($0.key.string, $0.value) })
            try? state.save(to: stateURL)
        }

        var downloads: [(VaultPath, String)] = []
        for (path, action) in plan.sorted(by: { $0.key < $1.key }) {
            switch action {
            case .none:
                base[path] = remoteFiles[path]
            case .download(let sha):
                downloads.append((path, sha))
            case .deleteLocal:
                try deleteFile(at: path)
                base[path] = nil
                report.deleted += 1
            case .keepLocalChange:
                report.localChanges.append(path)
            case .conflict:
                report.conflicts.append(path)
            }
        }

        progress(0, downloads.count)
        try await withThrowingTaskGroup(of: (VaultPath, String).self) { group in
            var pending = downloads.makeIterator()
            func enqueue() {
                guard let (path, sha) = pending.next() else { return }
                group.addTask {
                    let data = try await remote.download(sha: sha)
                    guard GitBlobHash.of(data) == sha else { throw SyncEngineError.corruptDownload(path) }
                    try writeFile(data, at: path)
                    return (path, sha)
                }
            }
            for _ in 0..<Self.maxConcurrentDownloads { enqueue() }
            for try await (path, sha) in group {
                base[path] = sha
                report.downloaded += 1
                progress(report.downloaded, downloads.count)
                enqueue()
            }
        }

        state.commit = head
        return report
    }

    // MARK: - Local files

    private func url(for path: VaultPath) -> URL {
        path.components.reduce(vaultRoot) { $0.appending(path: $1, directoryHint: .notDirectory) }
    }

    private func localHashes(for paths: Set<VaultPath>) -> [VaultPath: String] {
        var hashes: [VaultPath: String] = [:]
        for path in paths {
            if let data = try? Data(contentsOf: url(for: path), options: .mappedIfSafe) {
                hashes[path] = GitBlobHash.of(data)
            }
        }
        return hashes
    }

    private func writeFile(_ data: Data, at path: VaultPath) throws {
        let url = url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes a file, then removes any folders it leaves empty.
    private func deleteFile(at path: VaultPath) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url(for: path))
        var folder = path.parent
        while !folder.isRoot {
            let folderURL = url(for: folder)
            guard let contents = try? fm.contentsOfDirectory(atPath: folderURL.path(percentEncoded: false)),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
            try fm.removeItem(at: folderURL)
            folder = folder.parent
        }
    }
}
