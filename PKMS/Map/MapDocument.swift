import CoreLocation
import Foundation
import Observation
import SwiftUI

/// A `*.map` folder in the vault: `folders.json` lists the groups, and `<folder id>.json` holds each group's places.
/// Plain JSON files, so the folder syncs through Git like any note.
struct MapDocument: Sendable {
    var folders: [MapFolder]
    var places: [MapPlace]

    func places(in folderID: Int) -> [MapPlace] {
        places.filter { $0.folderID == folderID }
    }

    func folder(_ id: Int) -> MapFolder? {
        folders.first { $0.id == id }
    }

    static func load(_ path: VaultPath, from repository: any VaultRepository) async throws -> MapDocument {
        struct Index: Decodable { var folders: [MapFolder] }
        let decoder = JSONDecoder()
        let index = try decoder.decode(Index.self, from: try await repository.readData(at: path.appending("folders.json")))
        var places: [MapPlace] = []
        for folder in index.folders where repository.exists(path.appending(fileName(for: folder.id))) {
            let data = try await repository.readData(at: path.appending(fileName(for: folder.id)))
            var items = try decoder.decode([MapPlace].self, from: data)
            for i in items.indices { items[i].folderID = folder.id }
            places += items
        }
        return MapDocument(folders: index.folders, places: places)
    }

    static func fileName(for folderID: Int) -> String { "\(folderID).json" }

    /// `folders.json`, with each folder's `count` kept in step with its places.
    func indexJSON() throws -> String {
        struct Index: Encodable { var version = 1; var folders: [MapFolder] }
        let folders = folders.map { folder in
            var folder = folder
            folder.count = places(in: folder.id).count
            return folder
        }
        return try Self.encode(Index(folders: folders))
    }

    func placesJSON(for folderID: Int) throws -> String {
        try Self.encode(places(in: folderID))
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}

struct MapFolder: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var memo: String?
    var icon: String
    var count: Int
}

struct MapPlace: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var address: String?
    var memo: String?
    var lat: Double
    var lon: Double
    var color: String
    var createdAt: String
    /// Set when the position was derived from Kakao's own x/y coordinates (accurate to a few meters).
    var estimated: Bool?
    var kakaoPlaceId: String?
    /// Group this place belongs to; filled in by `MapDocument.load`, not stored in the file.
    var folderID = 0

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, memo, lat, lon, color, createdAt, estimated, kakaoPlaceId
    }
}

/// The open map and its edits. Every change is written straight back into the `*.map` folder,
/// which schedules a sync like any other edit.
@MainActor
@Observable
final class MapDocumentModel {
    let path: VaultPath
    private(set) var document: MapDocument?
    private(set) var loadError: String?
    var saveError: String?

    @ObservationIgnored private let store: VaultStore

    init(path: VaultPath, store: VaultStore) {
        self.path = path
        self.store = store
    }

    func load() async {
        do {
            document = try await MapDocument.load(path, from: store.repository)
            loadError = nil
        } catch {
            // Keep showing what was loaded before if a sync briefly leaves the files mid-update.
            if document == nil { loadError = error.localizedDescription }
        }
    }

    // MARK: - Places

    @discardableResult
    func addPlace(name: String, address: String?, memo: String?, coordinate: CLLocationCoordinate2D,
                  folderID: Int) -> MapPlace? {
        guard var document else { return nil }
        let place = MapPlace(
            id: Self.newID(), name: name, address: address.nilIfBlank, memo: memo.nilIfBlank,
            lat: coordinate.latitude, lon: coordinate.longitude, color: "02",
            createdAt: Self.timestamp(), folderID: folderID
        )
        document.places.append(place)
        commit(document, folders: [folderID])
        return place
    }

    func updatePlace(_ place: MapPlace) {
        guard var document, let i = document.places.firstIndex(where: { $0.id == place.id }) else { return }
        let oldFolder = document.places[i].folderID
        var place = place
        place.address = place.address.nilIfBlank
        place.memo = place.memo.nilIfBlank
        document.places[i] = place
        commit(document, folders: [oldFolder, place.folderID])
    }

    func deletePlace(_ id: Int) {
        guard var document, let i = document.places.firstIndex(where: { $0.id == id }) else { return }
        let folder = document.places.remove(at: i).folderID
        commit(document, folders: [folder])
    }

    /// Whether a place at this spot is already saved, so search results can show it as saved.
    func savedPlace(near coordinate: CLLocationCoordinate2D, named name: String?) -> MapPlace? {
        document?.places.first { place in
            abs(place.lat - coordinate.latitude) < 0.0002 && abs(place.lon - coordinate.longitude) < 0.0002
                && (name == nil || place.name == name)
        }
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(title: String) -> MapFolder? {
        guard var document else { return nil }
        let folder = MapFolder(id: Self.newID(), title: title, icon: "01", count: 0)
        document.folders.append(folder)
        commit(document, folders: [folder.id])
        return folder
    }

    func renameFolder(_ id: Int, to title: String) {
        guard var document, let i = document.folders.firstIndex(where: { $0.id == id }) else { return }
        document.folders[i].title = title
        commit(document, folders: [])
    }

    /// Removes a folder and every place in it.
    func deleteFolder(_ id: Int) {
        guard var document else { return }
        document.folders.removeAll { $0.id == id }
        document.places.removeAll { $0.folderID == id }
        self.document = document
        do {
            try store.save(try document.indexJSON(), to: path.appending("folders.json"))
            let file = path.appending(MapDocument.fileName(for: id))
            if store.repository.exists(file) { try store.repository.delete(file) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        guard var document else { return }
        document.folders.move(fromOffsets: source, toOffset: destination)
        commit(document, folders: [])
    }

    // MARK: - Saving

    private func commit(_ document: MapDocument, folders changed: Set<Int>) {
        self.document = document
        do {
            for id in changed where document.folder(id) != nil {
                try store.save(try document.placesJSON(for: id), to: path.appending(MapDocument.fileName(for: id)))
            }
            try store.save(try document.indexJSON(), to: path.appending("folders.json"))
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func newID() -> Int {
        Int(Date.now.timeIntervalSince1970 * 1000)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: .now)
    }
}

extension Optional<String> {
    /// `nil` for missing or whitespace-only text, so empty fields aren't written to the file.
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
