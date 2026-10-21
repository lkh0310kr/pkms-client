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

    @MainActor @Test func editsAreWrittenBackToTheFolder() async throws {
        let repo = try makeVault()
        let store = VaultStore(repository: repo, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let path = VaultPath("places.map")
        let model = MapDocumentModel(path: path, store: store)
        await model.load()

        let folder = try #require(model.addFolder(title: "Busan"))
        let added = try #require(model.addPlace(name: "Beach", address: " ", memo: "swim",
                                                coordinate: .init(latitude: 35.15, longitude: 129.16), folderID: folder.id))
        var moved = try #require(model.document?.places.first { $0.name == "Cafe" })
        moved.folderID = folder.id
        model.updatePlace(moved)
        model.renameFolder(7, to: "서울")

        let reloaded = try await MapDocument.load(path, from: repo)
        #expect(reloaded.folders.map(\.title) == ["서울", "Empty", "Busan"])
        #expect(Set(reloaded.places(in: folder.id).map(\.name)) == ["Beach", "Cafe"])
        #expect(reloaded.places(in: 7).isEmpty)
        #expect(reloaded.places.first { $0.id == added.id }?.address == nil)
        #expect(reloaded.places.first { $0.id == added.id }?.memo == "swim")
        let index = try await repo.readText(at: path.appending("folders.json"))
        #expect(index.contains("\"count\" : 2"))

        model.deleteFolder(folder.id)
        #expect(!repo.exists(path.appending("\(folder.id).json")))
        #expect(try await MapDocument.load(path, from: repo).places.isEmpty)
    }
}
