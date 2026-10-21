import CoreLocation
import SwiftUI

/// A place being added or edited.
struct PlaceDraft: Identifiable {
    let id = UUID()
    var existing: MapPlace?
    var name: String
    var address: String
    var memo: String
    var coordinate: CLLocationCoordinate2D
    var folderID: Int

    init(_ place: MapPlace) {
        existing = place
        name = place.name
        address = place.address ?? ""
        memo = place.memo ?? ""
        coordinate = place.coordinate
        folderID = place.folderID
    }

    init(target: MapTarget, folderID: Int) {
        name = target.name == "Dropped Pin" ? "" : target.name
        address = target.address ?? ""
        memo = ""
        coordinate = target.coordinate
        self.folderID = folderID
    }
}

/// Saves a new favorite or edits one: name, address, memo and group.
struct PlaceEditor: View {
    @State var draft: PlaceDraft
    let model: MapDocumentModel
    let onFinish: (MapPlace?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newFolderTitle = ""
    @State private var addingFolder = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Address", text: $draft.address, axis: .vertical)
                }
                Section("Memo") {
                    TextField("Notes about this place", text: $draft.memo, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Group") {
                    Picker("Group", selection: $draft.folderID) {
                        ForEach(model.document?.folders ?? []) { folder in
                            Text(folder.title).tag(folder.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("New Group", systemImage: "folder.badge.plus") { addingFolder = true }
                }
                Section {
                    LabeledContent("Coordinates",
                                   value: String(format: "%.5f, %.5f", draft.coordinate.latitude, draft.coordinate.longitude))
                        .font(.footnote)
                }
                if draft.existing != nil {
                    Section {
                        Button("Delete Place", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(draft.existing == nil ? "Save Place" : "Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.document?.folder(draft.folderID) == nil)
                }
            }
            .alert("New Group", isPresented: $addingFolder) {
                TextField("Name", text: $newFolderTitle)
                Button("Cancel", role: .cancel) { newFolderTitle = "" }
                Button("Create") {
                    let title = newFolderTitle.trimmingCharacters(in: .whitespaces)
                    newFolderTitle = ""
                    if !title.isEmpty, let folder = model.addFolder(title: title) { draft.folderID = folder.id }
                }
            }
            .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existing = draft.existing { model.deletePlace(existing.id) }
                    onFinish(nil)
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if var place = draft.existing {
            place.name = name
            place.address = draft.address
            place.memo = draft.memo
            place.folderID = draft.folderID
            model.updatePlace(place)
            onFinish(model.document?.places.first { $0.id == place.id })
        } else {
            let place = model.addPlace(name: name, address: draft.address, memo: draft.memo,
                                       coordinate: draft.coordinate, folderID: draft.folderID)
            onFinish(place)
        }
        dismiss()
    }
}

/// Every saved place, grouped, searchable and sortable by distance.
struct PlaceList: View {
    let model: MapDocumentModel
    let userLocation: CLLocation?
    let select: (MapPlace) -> Void
    let edit: (MapPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var byDistance = false

    var body: some View {
        NavigationStack {
            List {
                if let document = model.document {
                    ForEach(document.folders) { folder in
                        let places = sorted(document.places(in: folder.id).filter(matches))
                        if !places.isEmpty {
                            Section {
                                ForEach(places) { place in row(place, document: document) }
                            } header: {
                                HStack(spacing: 6) {
                                    Circle().fill(MapPalette.color(for: folder.id, in: document)).frame(width: 8, height: 8)
                                    Text(folder.title)
                                    Text("\(places.count)")
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if !query.isEmpty, model.document?.places.contains(where: matches) != true {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search saved places")
            .navigationTitle("Saved Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if userLocation != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Toggle(isOn: $byDistance) { Label("Nearest First", systemImage: "location") }
                    }
                }
            }
        }
    }

    private func row(_ place: MapPlace, document: MapDocument) -> some View {
        Button { select(place) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let address = place.address {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                    if let memo = place.memo {
                        Text(memo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let distance = distance(to: place) {
                    Text(distance.distanceText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { model.deletePlace(place.id) }
            Button("Edit", systemImage: "pencil") {
                dismiss()
                edit(place)
            }
            .tint(.orange)
        }
        .contextMenu {
            Menu("Move to", systemImage: "folder") {
                ForEach(document.folders.filter { $0.id != place.folderID }) { folder in
                    Button(folder.title) {
                        var moved = place
                        moved.folderID = folder.id
                        model.updatePlace(moved)
                    }
                }
            }
            Button("Edit", systemImage: "pencil") {
                dismiss()
                edit(place)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deletePlace(place.id) }
        }
    }

    private func matches(_ place: MapPlace) -> Bool {
        query.isEmpty || place.name.localizedStandardContains(query)
            || (place.address?.localizedStandardContains(query) ?? false)
            || (place.memo?.localizedStandardContains(query) ?? false)
    }

    private func sorted(_ places: [MapPlace]) -> [MapPlace] {
        guard byDistance, userLocation != nil else { return places }
        return places.sorted { (distance(to: $0) ?? 0) < (distance(to: $1) ?? 0) }
    }

    private func distance(to place: MapPlace) -> CLLocationDistance? {
        userLocation?.distance(from: CLLocation(latitude: place.lat, longitude: place.lon))
    }
}

/// Add, rename, reorder, hide and delete groups.
struct FolderManager: View {
    let model: MapDocumentModel
    @Binding var hiddenFolders: Set<Int>

    @Environment(\.dismiss) private var dismiss
    @State private var renaming: MapFolder?
    @State private var adding = false
    @State private var title = ""
    @State private var pendingDelete: MapFolder?

    var body: some View {
        NavigationStack {
            List {
                if let document = model.document {
                    ForEach(document.folders) { folder in
                        HStack {
                            Circle().fill(MapPalette.color(for: folder.id, in: document)).frame(width: 10, height: 10)
                            Text(folder.title)
                            Spacer()
                            Text("\(document.places(in: folder.id).count)").foregroundStyle(.secondary)
                            Button {
                                if hiddenFolders.contains(folder.id) { hiddenFolders.remove(folder.id) } else { hiddenFolders.insert(folder.id) }
                            } label: {
                                Image(systemName: hiddenFolders.contains(folder.id) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(hiddenFolders.contains(folder.id) ? "Show on map" : "Hide on map")
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
                            Button("Rename", systemImage: "pencil") {
                                title = folder.title
                                renaming = folder
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                title = folder.title
                                renaming = folder
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
                        }
                    }
                    .onMove { model.moveFolders(from: $0, to: $1) }
                }
            }
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Group", systemImage: "plus") {
                        title = ""
                        adding = true
                    }
                }
            }
            .alert("New Group", isPresented: $adding) {
                TextField("Name", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let title = title.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { model.addFolder(title: title) }
                }
            }
            .alert("Rename Group", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
                TextField("Name", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let title = title.trimmingCharacters(in: .whitespaces)
                    if let folder = renaming, !title.isEmpty { model.renameFolder(folder.id, to: title) }
                }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.title)” and its \(model.document?.places(in: $0.id).count ?? 0) places?" } ?? "",
                isPresented: Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } },
                titleVisibility: .visible
            ) {
                Button("Delete Group", role: .destructive) {
                    if let folder = pendingDelete { model.deleteFolder(folder.id) }
                }
            } message: {
                Text("It will also be removed from GitHub. You can recover it from the repository’s history.")
            }
        }
    }
}
