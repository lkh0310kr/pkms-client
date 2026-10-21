import MapKit
import SwiftUI

/// Shows a `*.map` folder as places on a map, with one toggle per group.
struct MapDocumentView: View {
    let path: VaultPath

    @Environment(VaultStore.self) private var store
    @State private var document: MapDocument?
    @State private var loadError: String?
    @State private var hiddenFolders: Set<Int> = []
    @State private var selection: Int?
    @State private var camera: MapCameraPosition = .automatic

    private static let palette: [Color] = [.red, .blue, .green, .orange, .purple, .teal, .pink, .indigo]

    var body: some View {
        Group {
            if let document {
                map(document)
            } else if let loadError {
                ContentUnavailableView("Couldn’t Open Map", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(path.baseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SyncStatusIcon() }
        }
        .task(id: store.revision) { await load() }
    }

    private func map(_ document: MapDocument) -> some View {
        let visible = document.places.filter { !hiddenFolders.contains($0.folderID) }
        return Map(position: $camera, selection: $selection) {
            UserAnnotation()
            ForEach(visible) { place in
                Marker(place.name, coordinate: place.coordinate)
                    .tint(color(for: place.folderID, in: document))
                    .tag(place.id)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .top, spacing: 0) { folderChips(document) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let place = document.places.first(where: { $0.id == selection }) {
                detail(place, in: document)
            }
        }
    }

    private func folderChips(_ document: MapDocument) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(document.folders.filter { $0.count > 0 }) { folder in
                    let isOn = !hiddenFolders.contains(folder.id)
                    Button {
                        if isOn { hiddenFolders.insert(folder.id) } else { hiddenFolders.remove(folder.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: folder.id, in: document)).frame(width: 9, height: 9)
                            Text(folder.title)
                            Text("\(folder.count)").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isOn ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: .capsule)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(isOn ? 0 : 0.5)))
                        .opacity(isOn ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func detail(_ place: MapPlace, in document: MapDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(place.name).font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") { selection = nil }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            if let address = place.address {
                Text(address).font(.subheadline).foregroundStyle(.secondary)
            }
            if let memo = place.memo {
                Text(memo).font(.subheadline)
            }
            HStack {
                if let folder = document.folders.first(where: { $0.id == place.folderID }) {
                    Label(folder.title, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open in Maps", systemImage: "map") {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
                    item.name = place.name
                    item.openInMaps()
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func color(for folderID: Int, in document: MapDocument) -> Color {
        let index = document.folders.firstIndex { $0.id == folderID } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    private func load() async {
        do {
            document = try await MapDocument.load(path, from: store.repository)
            loadError = nil
        } catch {
            if document == nil { loadError = error.localizedDescription }
        }
    }
}
