import Foundation
import Testing
@testable import PKMS

struct GitBlobHashTests {
    @Test func matchesGit() {
        // `git hash-object` of an empty file and of "hello\n".
        #expect(GitBlobHash.of(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        #expect(GitBlobHash.of(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    }
}

struct SyncPlannerTests {
    @Test func threeWayRules() {
        #expect(SyncPlanner.action(base: "a", local: "a", remote: "a") == .none)
        #expect(SyncPlanner.action(base: nil, local: nil, remote: "b") == .download(sha: "b"))
        #expect(SyncPlanner.action(base: "a", local: "a", remote: "b") == .download(sha: "b"))
        #expect(SyncPlanner.action(base: "a", local: "a", remote: nil) == .deleteLocal)
        #expect(SyncPlanner.action(base: "a", local: "c", remote: "a") == .keepLocalChange)
        #expect(SyncPlanner.action(base: "a", local: nil, remote: "a") == .keepLocalChange)
        #expect(SyncPlanner.action(base: "a", local: "c", remote: "b") == .conflict)
        #expect(SyncPlanner.action(base: nil, local: "c", remote: "b") == .conflict)
        #expect(SyncPlanner.action(base: "a", local: "b", remote: "b") == .none)
    }
}

/// In-memory remote: `files` maps paths to contents at the current head.
final class FakeRemote: RemoteVault, @unchecked Sendable {
    var head = "c1"
    var files: [String: String] = [:]
    private let lock = NSLock()
    private var downloadCount = 0
    var downloads: Int { lock.withLock { downloadCount } }

    func headCommit() async throws -> String { head }

    func files(at commit: String) async throws -> [VaultPath: String] {
        Dictionary(uniqueKeysWithValues: files.map { (VaultPath($0.key), GitBlobHash.of(Data($0.value.utf8))) })
    }

    func download(sha: String) async throws -> Data {
        lock.withLock { downloadCount += 1 }
        let content = files.values.first { GitBlobHash.of(Data($0.utf8)) == sha }!
        return Data(content.utf8)
    }
}

struct SyncEngineTests {
    let root = URL.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)")
    let stateURL = URL.temporaryDirectory.appending(path: "state-\(UUID().uuidString).json")
    let remote = FakeRemote()

    private var engine: SyncEngine {
        SyncEngine(vaultRoot: root, stateURL: stateURL, repositoryID: "me/notes@main", remote: remote)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appending(path: path))
    }

    @Test func pullsAddsUpdatesAndDeletes() async throws {
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: stateURL) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        remote.files = ["README.md": "# Hi", "Notes/a.md": "A", "Notes/b.md": "B"]
        var report = try await engine.pull()
        #expect(report.downloaded == 3)
        #expect(read("Notes/a.md") == "A")

        // Unchanged head: nothing is fetched.
        report = try await engine.pull()
        #expect(report.downloaded == 0 && remote.downloads == 3)

        // Remote edits one file and deletes a folder's only other file.
        remote.head = "c2"
        remote.files = ["README.md": "# Hi", "Notes/a.md": "A2"]
        report = try await engine.pull()
        #expect(report.downloaded == 1 && report.deleted == 1)
        #expect(read("Notes/a.md") == "A2")
        #expect(read("Notes/b.md") == nil)

        remote.head = "c3"
        remote.files = ["README.md": "# Hi"]
        _ = try await engine.pull()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Notes").path(percentEncoded: false)))
    }

    @Test func neverOverwritesLocalChanges() async throws {
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: stateURL) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        remote.files = ["a.md": "A", "b.md": "B"]
        _ = try await engine.pull()

        try write("a.md", "A local")
        try write("b.md", "B local")
        try write("new.md", "only here")
        remote.head = "c2"
        remote.files = ["a.md": "A remote"]  // a.md edited remotely, b.md deleted remotely
        let report = try await engine.pull()

        #expect(report.conflicts == [VaultPath("a.md"), VaultPath("b.md")])
        #expect(read("a.md") == "A local")
        #expect(read("b.md") == "B local")
        #expect(read("new.md") == "only here")
    }
}
