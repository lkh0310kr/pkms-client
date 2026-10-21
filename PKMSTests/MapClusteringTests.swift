import MapKit
import Testing
@testable import PKMS

struct MapClusteringTests {
    private func place(_ id: Int, _ lat: Double, _ lon: Double) -> MapPlace {
        MapPlace(id: id, name: "P\(id)", lat: lat, lon: lon, createdAt: "")
    }

    private func region(span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: 37.5, longitude: 127.0),
                           span: .init(latitudeDelta: span, longitudeDelta: span))
    }

    @Test func zoomedOutNearbyPlacesCollapseIntoOneBubble() {
        let places = [place(1, 37.5000, 127.0000), place(2, 37.5005, 127.0004), place(3, 37.9, 127.4)]
        let clusters = MapClustering.clusters(places, region: region(span: 0.5), keeping: nil)
        #expect(clusters.count == 2)
        #expect(clusters.contains { $0.places.count == 2 })
        #expect(clusters.contains { $0.single?.id == 3 })
    }

    @Test func zoomedInEveryPlaceIsAPin() {
        let places = [place(1, 37.5000, 127.0000), place(2, 37.5005, 127.0004)]
        let clusters = MapClustering.clusters(places, region: region(span: 0.005), keeping: nil)
        #expect(clusters.count == 2 && clusters.allSatisfy { $0.single != nil })
    }

    @Test func selectedPlaceStaysAPin() {
        let places = [place(1, 37.5000, 127.0000), place(2, 37.5005, 127.0004), place(3, 37.5002, 127.0001)]
        let clusters = MapClustering.clusters(places, region: region(span: 0.5), keeping: 2)
        #expect(clusters.contains { $0.single?.id == 2 })
        #expect(clusters.first { $0.single == nil }?.places.count == 2)
    }

    @Test func withoutARegionNothingIsGrouped() {
        let places = [place(1, 37.5, 127.0), place(2, 37.5, 127.0)]
        #expect(MapClustering.clusters(places, region: nil, keeping: nil).count == 2)
    }
}
