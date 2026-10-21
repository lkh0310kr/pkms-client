import CoreLocation
import Foundation

/// A `*.map` folder in the vault: `folders.json` lists the groups, and `<folder id>.json` holds each group's places.
/// Plain JSON files, so the folder syncs through Git like any note.
struct MapDocument: Sendable {
    var folders: [MapFolder]
    var places: [MapPlace]

    func places(in folder: MapFolder) -> [MapPlace] {
        places.filter { $0.folderID == folder.id }
    }

    static func load(_ path: VaultPath, from repository: any VaultRepository) async throws -> MapDocument {
        struct Index: Decodable { var folders: [MapFolder] }
        let decoder = JSONDecoder()
        let index = try decoder.decode(Index.self, from: try await repository.readData(at: path.appending("folders.json")))
        var places: [MapPlace] = []
        for folder in index.folders where folder.count > 0 {
            let data = try await repository.readData(at: path.appending("\(folder.id).json"))
            var items = try decoder.decode([MapPlace].self, from: data)
            for i in items.indices { items[i].folderID = folder.id }
            places += items
        }
        return MapDocument(folders: index.folders, places: places)
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
    /// Group this place belongs to; filled in by `MapDocument.load`, not stored in the file.
    var folderID = 0

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, memo, lat, lon, color, createdAt, estimated
    }
}
