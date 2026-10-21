import MapKit

/// Places that are close together on screen, drawn as one pin (a single place) or one count bubble.
struct PlaceCluster: Identifiable {
    let id: String
    let places: [MapPlace]

    var single: MapPlace? { places.count == 1 ? places[0] : nil }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: places.map(\.lat).reduce(0, +) / Double(places.count),
            longitude: places.map(\.lon).reduce(0, +) / Double(places.count)
        )
    }

    /// The map rect that fits every place in the cluster, padded so the pins aren't on the edge.
    var rect: MKMapRect {
        let rect = places.reduce(MKMapRect.null) { rect, place in
            let point = MKMapPoint(place.coordinate)
            return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let minimum = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * 400
        let padded = rect.insetBy(dx: -max(rect.width * 0.4, minimum), dy: -max(rect.height * 0.4, minimum))
        return padded
    }
}

/// Groups places on a fixed grid whose cells are a fraction of the visible area, like Kakao Map:
/// zoomed out, nearby places collapse into count bubbles; zoom in and they spread into pins.
enum MapClustering {
    /// Roughly this many cells fit across the screen's height.
    private static let cellsAcross = 8.0
    /// Below this latitude span (about 1 km) every place gets its own pin.
    private static let pinSpan = 0.009

    static func clusters(_ places: [MapPlace], region: MKCoordinateRegion?, keeping selected: Int?) -> [PlaceCluster] {
        guard let region, region.span.latitudeDelta > pinSpan else {
            return places.map { PlaceCluster(id: "p\($0.id)", places: [$0]) }
        }
        let size = region.span.latitudeDelta / cellsAcross
        var cells: [String: [MapPlace]] = [:]
        var order: [String] = []
        var result: [PlaceCluster] = []
        for place in places {
            if place.id == selected {  // the selected place stays a pin so its card and pin don't vanish
                result.append(PlaceCluster(id: "p\(place.id)", places: [place]))
                continue
            }
            let key = "\(Int((place.lat / size).rounded(.down))),\(Int((place.lon / size).rounded(.down)))"
            if cells[key] == nil { order.append(key) }
            cells[key, default: []].append(place)
        }
        for key in order {
            let group = cells[key]!
            result.append(PlaceCluster(id: group.count == 1 ? "p\(group[0].id)" : "c\(key)", places: group))
        }
        return result
    }
}
