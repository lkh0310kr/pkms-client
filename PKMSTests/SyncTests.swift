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
        #expect(SyncPlanner.action(base: "a", local: "c", remote: "a") == .upload)
        #expect(SyncPlanner.action(base: "a", local: nil, remote: "a") == .upload)
        #expect(SyncPlanner.action(base: "a", local: "c", remote: "b") == .merge(remoteSHA: "b"))
        #expect(SyncPlanner.action(base: nil, local: "c", remote: "b") == .merge(remoteSHA: "b"))
        #expect(SyncPlanner.action(base: "a", local: "b", remote: "b") == .none)
        // Edit beats delete, in both directions.
        #expect(SyncPlanner.action(base: "a", local: "c", remote: nil) == .restoreLocal)
        #expect(SyncPlanner.action(base: "a", local: nil, remote: "b") == .download(sha: "b"))
    }
}

struct TextMergeTests {
    @Test func combinesEditsInDifferentPlaces() {
        let base = "# Title\none\ntwo\nthree\nfour"
        let local = "# Title\nONE\ntwo\nthree\nfour"
        let remote = "# Title\none\ntwo\nthree\nFOUR\nfive"
        #expect(TextMerge.merge(base: base, local: local, remote: remote) == "# Title\nONE\ntwo\nthree\nFOUR\nfive")
    }

    @Test func mergesAdjacentLines() {
        #expect(TextMerge.merge(base: "a\nb\nc", local: "A\nb\nc", remote: "a\nB\nc") == "A\nB\nc")
    }

    @Test func conflictsOnSameLine() {
        #expect(TextMerge.merge(base: "a\nb", local: "a\nlocal", remote: "a\nremote") == nil)
    }

    @Test func identicalChangesAreFine() {
        #expect(TextMerge.merge(base: "a\nb", local: "a\nc", remote: "a\nc") == "a\nc")
    }

    @Test func insertionsAtDifferentPoints() {
        #expect(TextMerge.merge(base: "a\nb", local: "x\na\nb", remote: "a\nb\ny") == "x\na\nb\ny")
    }
}

/// In-memory remote: `files` maps paths to contents at the current head.
final class FakeRemote: RemoteVault, @unchecked Sendable {
    private let lock = NSLock()
    private var _head = "c1"
    private var _files: [String: String] = [:]
    private var blobs: [String: Data] = [:]
    private var downloadCount = 0
    private(set) var uploads: [[String: String?]] = []

    var head: String { lock.withLock { _head } }
    var files: [String: String] {
        get { lock.withLock { _files } }
        set { lock.withLock { _files = newValue; for text in newValue.values { blobs[GitBlobHash.of(Data(text.utf8))] = Data(text.utf8) } } }
    }
    var downloads: Int { lock.withLock { downloadCount } }

    /// Simulates another device pushing a commit.
    func commit(_ newFiles: [String: String]) {
        files = newFiles
        lock.withLock { _head = "c\(Int(_head.dropFirst())! + 1)" }
    }

    func headCommit() async throws -> String { head }

    func files(at commit: String) async throws -> [VaultPath: String] {
        Dictionary(uniqueKeysWithValues: files.map { (VaultPath($0.key), GitBlobHash.of(Data($0.value.utf8))) })
    }

    func download(sha: String) async throws -> Data {
        lock.withLock {
            downloadCount += 1
            return blobs[sha]!
        }
    }

    func upload(_ changes: [VaultPath: Data?], parent: String, message: String) async throws -> String {
        guard parent == head else { throw RemoteVaultError.outdated }
        var next = files
        for (path, data) in changes {
            next[path.string] = data.map { String(decoding: $0, as: UTF8.self) }
        }
        lock.withLock { uploads.append(changes.reduce(into: [:]) { $0[$1.key.string] = $1.value.map { String(decoding: $0, as: UTF8.self) } }) }
        commit(next)
        return head
    }
}

struct SyncEngineTests {
    let root = URL.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)")
    let stateURL = URL.temporaryDirectory.appending(path: "state-\(UUID().uuidString).json")
    let remote = FakeRemote()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func engine(canUpload: Bool = true) -> SyncEngine {
        SyncEngine(vaultRoot: root, stateURL: stateURL, repositoryID: "me/notes@main", remote: remote, canUpload: canUpload)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateURL)
    }

    @Test func pullsAddsUpdatesAndDeletes() async throws {
        defer { cleanUp() }
        remote.files = ["README.md": "# Hi", "Notes/a.md": "A", "Notes/b.md": "B"]
        var report = try await engine().sync()
        #expect(report.downloaded == 3)
        #expect(read("Notes/a.md") == "A")

        // Unchanged head: nothing is fetched or uploaded.
        report = try await engine().sync()
        #expect(report.downloaded == 0 && report.uploaded == 0 && remote.downloads == 3)

        remote.commit(["README.md": "# Hi", "Notes/a.md": "A2"])
        report = try await engine().sync()
        #expect(report.downloaded == 1 && report.deleted == 1)
        #expect(read("Notes/a.md") == "A2")
        #expect(read("Notes/b.md") == nil)

        remote.commit(["README.md": "# Hi"])
        _ = try await engine().sync()
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Notes").path(percentEncoded: false)))
    }

    @Test func uploadsLocalEditsAdditionsAndDeletions() async throws {
        defer { cleanUp() }
        remote.files = ["a.md": "A", "b.md": "B"]
        _ = try await engine().sync()

        try write("a.md", "A edited")
        try write("New/c.md", "C")
        try FileManager.default.removeItem(at: root.appending(path: "b.md"))
        let report = try await engine().sync()

        #expect(report.uploaded == 3)
        #expect(remote.files == ["a.md": "A edited", "New/c.md": "C"])
        // Nothing left to upload afterwards.
        #expect(try await engine().sync().uploaded == 0)
    }

    @Test func holdsUploadsWhenSignedOut() async throws {
        defer { cleanUp() }
        remote.files = ["a.md": "A"]
        _ = try await engine().sync()
        try write("a.md", "A edited")
        let report = try await engine(canUpload: false).sync()
        #expect(report.notUploaded == 1)
        #expect(remote.files["a.md"] == "A")
    }

    @Test func mergesEditsFromBothSides() async throws {
        defer { cleanUp() }
        remote.files = ["n.md": "# Note\none\ntwo\nthree"]
        _ = try await engine().sync()

        try write("n.md", "# Note\nONE\ntwo\nthree")
        remote.commit(["n.md": "# Note\none\ntwo\nTHREE"])
        let report = try await engine().sync()

        #expect(report.merged == [VaultPath("n.md")])
        #expect(read("n.md") == "# Note\nONE\ntwo\nTHREE")
        #expect(remote.files["n.md"] == "# Note\nONE\ntwo\nTHREE")
    }

    @Test func keepsBothVersionsOnRealConflict() async throws {
        defer { cleanUp() }
        remote.files = ["n.md": "hello"]
        _ = try await engine().sync()

        try write("n.md", "hello from phone")
        remote.commit(["n.md": "hello from laptop"])
        let report = try await engine().sync()

        #expect(report.conflicts == [VaultPath("n.md")])
        #expect(read("n.md") == "hello from phone")
        #expect(read("n (GitHub version).md") == "hello from laptop")
        // Held back from GitHub until the user decides.
        #expect(remote.files == ["n.md": "hello from laptop"])

        try engine().resolveConflict(VaultPath("n.md"), .keepLocal)
        _ = try await engine().sync()
        #expect(remote.files == ["n.md": "hello from phone"])
        #expect(read("n (GitHub version).md") == nil)
    }

    @Test func conflictResolutionKeepRemote() async throws {
        defer { cleanUp() }
        remote.files = ["n.md": "hello"]
        _ = try await engine().sync()
        try write("n.md", "mine")
        remote.commit(["n.md": "theirs"])
        _ = try await engine().sync()

        try engine().resolveConflict(VaultPath("n.md"), .keepRemote)
        let report = try await engine().sync()
        #expect(read("n.md") == "theirs")
        #expect(report.uploaded == 0)
        #expect(remote.files == ["n.md": "theirs"])
    }

    @Test func editWinsOverRemoteDelete() async throws {
        defer { cleanUp() }
        remote.files = ["a.md": "A", "b.md": "B"]
        _ = try await engine().sync()
        try write("a.md", "A edited")
        remote.commit(["b.md": "B"])
        _ = try await engine().sync()
        #expect(remote.files["a.md"] == "A edited")
    }

    @Test func uploadsUnderTheRepositorysUnicodeSpelling() {
        let decomposed = "중국 소싱.md".decomposedStringWithCanonicalMapping   // as written by macOS
        let composed = "중국 소싱.md".precomposedStringWithCanonicalMapping    // as iOS reports it
        var state = SyncState(repository: "me/notes@main")
        state.files[decomposed] = "sha"
        // The file system hands back the composed name; the upload must reuse the repository's spelling.
        let path = engine().remoteSpelling(of: VaultPath(composed), state: state)
        #expect(path.string.utf8.elementsEqual(decomposed.utf8), "must edit the existing file, not add a second one")
    }

    @Test func newFilesUploadComposed() async throws {
        defer { cleanUp() }
        remote.files = [:]
        _ = try await engine().sync()
        try write("노트.md".decomposedStringWithCanonicalMapping, "x")
        _ = try await engine().sync()
        let uploaded = try #require(remote.uploads.last?.keys.first)
        #expect(uploaded.utf8.elementsEqual("노트.md".precomposedStringWithCanonicalMapping.utf8))
    }

    @Test func retriesWhenRemoteMovesDuringUpload() async throws {
        defer { cleanUp() }
        remote.files = ["a.md": "A", "b.md": "B"]
        _ = try await engine().sync()
        try write("a.md", "A edited")

        // Another device pushes after our pull but before our upload.
        let racing = RacingRemote(inner: remote) { $0.commit(["a.md": "A", "b.md": "B edited"]) }
        let engine = SyncEngine(vaultRoot: root, stateURL: stateURL, repositoryID: "me/notes@main", remote: racing)
        _ = try await engine.sync()

        #expect(remote.files == ["a.md": "A edited", "b.md": "B edited"])
        #expect(read("b.md") == "B edited")
    }
}

/// Wraps a remote and runs `beforeFirstUpload` once, just before the first upload.
final class RacingRemote: RemoteVault, @unchecked Sendable {
    let inner: FakeRemote
    private var hook: ((FakeRemote) -> Void)?

    init(inner: FakeRemote, beforeFirstUpload: @escaping (FakeRemote) -> Void) {
        self.inner = inner
        self.hook = beforeFirstUpload
    }

    func headCommit() async throws -> String { try await inner.headCommit() }
    func files(at commit: String) async throws -> [VaultPath: String] { try await inner.files(at: commit) }
    func download(sha: String) async throws -> Data { try await inner.download(sha: sha) }

    func upload(_ changes: [VaultPath: Data?], parent: String, message: String) async throws -> String {
        if let hook {
            self.hook = nil
            hook(inner)
        }
        return try await inner.upload(changes, parent: parent, message: message)
    }
}
