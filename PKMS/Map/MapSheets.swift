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
                Section("Folder") {
                    Picker("Folder", selection: $draft.folderID) {
                        ForEach(model.document?.outline() ?? [], id: \.folder.id) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.folder.title).tag(entry.folder.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("New Folder", systemImage: "folder.badge.plus") { addingFolder = true }
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
            .alert("New Folder", isPresented: $addingFolder) {
                TextField("Name", text: $newFolderTitle)
                Button("Cancel", role: .cancel) { newFolderTitle = "" }
                Button("Create") {
                    let title = newFolderTitle.trimmingCharacters(in: .whitespaces)
                    newFolderTitle = ""
                    // Created next to the folder currently chosen, inside the same parent.
                    let parent = model.document?.folder(draft.folderID)?.parentID
                    if !title.isEmpty, let folder = model.addFolder(title: title, in: parent) { draft.folderID = folder.id }
                }
            } message: {
                if let parent = model.document?.folder(draft.folderID)?.parentID, let document = model.document {
                    Text("In \(document.pathTitle(of: parent))")
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

/// Favorites: folders nested to any depth with the places in them. Browse, search, edit, move,
/// hide on the map and delete, all in one place.
struct FavoritesView: View {
    let model: MapDocumentModel
    let userLocation: CLLocation?
    @Binding var hiddenFolders: Set<Int>
    let select: (MapPlace) -> Void
    let edit: (MapPlace) -> Void

    var body: some View {
        NavigationStack {
            FavoritesFolderView(folderID: nil, context: context)
                .navigationDestination(for: FavoritesRoute.self) { route in
                    FavoritesFolderView(folderID: route.folderID, context: context)
                }
        }
    }

    private var context: FavoritesContext {
        FavoritesContext(model: model, userLocation: userLocation, hiddenFolders: $hiddenFolders, select: select, edit: edit)
    }
}

private struct FavoritesRoute: Hashable {
    let folderID: Int
}

private struct FavoritesContext {
    let model: MapDocumentModel
    let userLocation: CLLocation?
    let hiddenFolders: Binding<Set<Int>>
    let select: (MapPlace) -> Void
    let edit: (MapPlace) -> Void
}

/// One level of Favorites: its subfolders, then its places. The top level also searches everything.
private struct FavoritesFolderView: View {
    let folderID: Int?
    let context: FavoritesContext

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var byDistance = false
    @State private var naming: Naming?
    @State private var title = ""
    @State private var moving: Moving?
    @State private var pendingDelete: MapFolder?

    private enum Naming: Identifiable {
        case new
        case rename(MapFolder)
        var id: String {
            switch self {
            case .new: "new"
            case .rename(let folder): "rename-\(folder.id)"
            }
        }
    }

    private enum Moving: Identifiable {
        case folder(MapFolder)
        case place(MapPlace)
        var id: String {
            switch self {
            case .folder(let folder): "folder-\(folder.id)"
            case .place(let place): "place-\(place.id)"
            }
        }
    }

    private var model: MapDocumentModel { context.model }

    var body: some View {
        Group {
            if let document = model.document {
                if folderID == nil {
                    list(document).searchable(text: $query, prompt: "Search favorites")
                } else {
                    list(document)
                }
            }
        }
        .navigationTitle(folderID.flatMap { model.document?.folder($0)?.title } ?? "Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if folderID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        title = ""
                        naming = .new
                    }
                    if context.userLocation != nil {
                        Toggle(isOn: $byDistance) { Label("Nearest First", systemImage: "location") }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert(naming.map { if case .rename = $0 { "Rename Folder" } else { "New Folder" } } ?? "",
               isPresented: Binding { naming != nil } set: { if !$0 { naming = nil } }) {
            TextField("Name", text: $title)
            Button("Cancel", role: .cancel) {}
            Button(naming.map { if case .rename = $0 { "Rename" } else { "Create" } } ?? "") { commitNaming() }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } },
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let folder = pendingDelete { model.deleteFolder(folder.id) }
            }
        } message: {
            Text("It will also be removed from GitHub. You can recover it from the repository’s history.")
        }
        .sheet(item: $moving) { moving in
            switch moving {
            case .folder(let folder):
                FolderPicker(model: model, title: "Move “\(folder.title)”", excluding: model.document?.subtree(of: folder.id) ?? [],
                             allowsTopLevel: true, current: folder.parentID) { parent in
                    model.moveFolder(folder.id, to: parent)
                }
            case .place(let place):
                FolderPicker(model: model, title: "Move “\(place.name)”", excluding: [], allowsTopLevel: false,
                             current: place.folderID) { parent in
                    guard let parent else { return }
                    var moved = place
                    moved.folderID = parent
                    model.updatePlace(moved)
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ document: MapDocument) -> some View {
        if !query.isEmpty {
            let matches = sorted(document.places.filter(matches))
            List(matches) { place in
                placeRow(place, document: document, showsFolder: true)
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
            }
        } else {
            let folders = document.children(of: folderID)
            let places = folderID.map { sorted(document.places(in: $0)) } ?? []
            List {
                if !folders.isEmpty {
                    Section(folderID == nil ? "" : "Folders") {
                        ForEach(folders) { folder in folderRow(folder, document: document) }
                            .onMove { model.moveFolders(in: folderID, from: $0, to: $1) }
                    }
                }
                if !places.isEmpty {
                    Section("Places") {
                        ForEach(places) { place in placeRow(place, document: document, showsFolder: false) }
                    }
                }
            }
            .overlay {
                if folders.isEmpty, places.isEmpty {
                    ContentUnavailableView {
                        Label(folderID == nil ? "No Favorites" : "Empty Folder", systemImage: "star")
                    } description: {
                        Text("Save places from the map, or add a folder to organize them.")
                    } actions: {
                        Button("New Folder") {
                            title = ""
                            naming = .new
                        }
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: MapFolder, document: MapDocument) -> some View {
        let hidden = context.hiddenFolders.wrappedValue.contains(folder.id)
        return NavigationLink(value: FavoritesRoute(folderID: folder.id)) {
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(MapPalette.color(for: folder.id, in: document))
                Text(folder.title)
                Spacer()
                if hidden {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary).font(.caption)
                }
                Text("\(document.placeCount(under: folder.id))").foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
            Button("Rename", systemImage: "pencil") {
                title = folder.title
                naming = .rename(folder)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash") { toggleHidden(folder.id) }
                .tint(.gray)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                title = folder.title
                naming = .rename(folder)
            }
            Button("Move to…", systemImage: "folder") { moving = .folder(folder) }
            Button(hidden ? "Show on Map" : "Hide on Map", systemImage: hidden ? "eye" : "eye.slash") { toggleHidden(folder.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = folder }
        }
    }

    private func placeRow(_ place: MapPlace, document: MapDocument, showsFolder: Bool) -> some View {
        Button { context.select(place) } label: {
            HStack {
                Image(systemName: "star.fill").foregroundStyle(MapPalette.color(for: place.folderID, in: document))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.primary)
                    if let address = place.address {
                        Text(address).font(.caption).foregroundStyle(.secondary)
                    }
                    if showsFolder {
                        Text(document.pathTitle(of: place.folderID)).font(.caption).foregroundStyle(.secondary)
                    } else if let memo = place.memo {
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
            Button("Edit", systemImage: "pencil") { editPlace(place) }
                .tint(.orange)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editPlace(place) }
            Button("Move to…", systemImage: "folder") { moving = .place(place) }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deletePlace(place.id) }
        }
    }

    // MARK: - Actions

    private func editPlace(_ place: MapPlace) {
        // The editor opens from the map once this sheet is gone.
        context.select(place)
        context.edit(place)
    }

    private func toggleHidden(_ id: Int) {
        if context.hiddenFolders.wrappedValue.contains(id) {
            context.hiddenFolders.wrappedValue.remove(id)
        } else {
            context.hiddenFolders.wrappedValue.insert(id)
        }
    }

    private func commitNaming() {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let naming else { return }
        switch naming {
        case .new: model.addFolder(title: title, in: folderID)
        case .rename(let folder): model.renameFolder(folder.id, to: title)
        }
    }

    private var deleteTitle: String {
        guard let folder = pendingDelete, let document = model.document else { return "" }
        let places = document.placeCount(under: folder.id)
        let subfolders = document.subtree(of: folder.id).count - 1
        var parts: [String] = []
        if subfolders > 0 { parts.append("\(subfolders) subfolder\(subfolders == 1 ? "" : "s")") }
        if places > 0 { parts.append("\(places) place\(places == 1 ? "" : "s")") }
        return parts.isEmpty ? "Delete “\(folder.title)”?" : "Delete “\(folder.title)” and its \(parts.joined(separator: " and "))?"
    }

    private func matches(_ place: MapPlace) -> Bool {
        place.name.localizedStandardContains(query)
            || (place.address?.localizedStandardContains(query) ?? false)
            || (place.memo?.localizedStandardContains(query) ?? false)
    }

    private func sorted(_ places: [MapPlace]) -> [MapPlace] {
        guard byDistance, context.userLocation != nil else { return places }
        return places.sorted { (distance(to: $0) ?? 0) < (distance(to: $1) ?? 0) }
    }

    private func distance(to place: MapPlace) -> CLLocationDistance? {
        context.userLocation?.distance(from: CLLocation(latitude: place.lat, longitude: place.lon))
    }
}

/// Chooses a destination folder, shown as an indented outline.
private struct FolderPicker: View {
    let model: MapDocumentModel
    let title: String
    let excluding: Set<Int>
    let allowsTopLevel: Bool
    let current: Int?
    let pick: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if allowsTopLevel {
                    row("Favorites", systemImage: "star", depth: 0, id: nil)
                }
                ForEach(model.document?.outline(excluding: excluding) ?? [], id: \.folder.id) { entry in
                    row(entry.folder.title, systemImage: "folder", depth: entry.depth + (allowsTopLevel ? 1 : 0), id: entry.folder.id)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ name: String, systemImage: String, depth: Int, id: Int?) -> some View {
        Button {
            pick(id)
            dismiss()
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                    .padding(.leading, CGFloat(depth) * 18)
                Spacer()
                if id == current {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .disabled(id == current)
    }
}
