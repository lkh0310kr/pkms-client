import Foundation
import Testing
@testable import PKMS

struct MapDocumentTests {
    private func makeVault() throws -> LocalVaultRepository {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = LocalVaultRepository(rootURL: root)
        try repo.writeText(#"{"version":1,"folders":[{"id":7,"title":"Seoul","icon":"01","count":1},{"id":0,"title":"Empty","icon":"01","count":0}]}"#,
                           to: VaultPath("places.map/folders.json"))
        try repo.writeText(#"[{"id":1,"name":"Cafe","address":"Somewhere","lat":37.5,"lon":127.0,"color":"02","createdAt":"2026-01-01 00:00:00"}]"#,
                           to: VaultPath("places.map/7.json"))
        return repo
    }

    @Test func loadsFoldersAndPlaces() async throws {
        let repo = try makeVault()
        let document = try await MapDocument.load(VaultPath("places.map"), from: repo)
        #expect(document.folders.map(\.title) == ["Seoul", "Empty"])
        #expect(document.places.count == 1)
        #expect(document.places[0].folderID == 7)
        #expect(document.places[0].address == "Somewhere")
    }

    @Test func mapFolderIsOneBrowsableNode() async throws {
        let repo = try makeVault()
        let index = try await repo.loadIndex()
        let node = try #require(index.node(at: VaultPath("places.map")))
        #expect(node.kind == .map)
        #expect(node.isBrowsable)
        #expect(node.displayName == "places")
        #expect(node.children.isEmpty)
    }
}
