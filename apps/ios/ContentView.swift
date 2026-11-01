import SwiftUI
import QuickLook
import UniformTypeIdentifiers

private struct FileTreeRow: Identifiable {
    let file: PKMSFile
    let depth: Int
    var id: String { file.id }
}

struct ContentView: View {
    @Environment(PKMSModel.self) private var model
    @State private var showingRepositories = false
    @State private var showingSettings = false
    @State private var showingFileImporter = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Color.accentColor)
        .alert("PKMS", isPresented: errorPresented) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await model.upload(url) } }
        }
        .sheet(isPresented: $showingRepositories) { repositoryPicker }
        .sheet(isPresented: $showingSettings) { settingsForm }
        .sheet(isPresented: previewPresented, onDismiss: { model.dismissPreview() }) {
            if let url = model.previewURL { QuickLookSheet(url: url) }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }

    private var previewPresented: Binding<Bool> {
        Binding(get: { model.previewURL != nil }, set: { if !$0 { model.dismissPreview() } })
    }

    private var sidebar: some View {
        List {
            if model.user != nil {
                if !model.workspaces.isEmpty {
                    Section("Workspaces") {
                        ForEach(model.workspaces) { workspace in
                            Button {
                                Task { await model.selectWorkspace(workspace) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "externaldrive")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    Text(workspace.repository).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if model.activeWorkspace?.id == workspace.id {
                                        Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(model.activeWorkspace?.id == workspace.id ? Color.accentColor.opacity(0.1) : nil)
                        }
                    }
                }

                Section(model.activeWorkspace?.repository ?? "Files") {
                    if model.activeWorkspace == nil {
                        Text("Connect a repository to get started")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if treeRows.isEmpty {
                        if model.errorMessage == nil { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    } else {
                        ForEach(treeRows) { row in fileRow(row) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspace")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.user != nil {
                    Menu {
                        Button("New note", systemImage: "square.and.pencil") { Task { await model.createNote() } }
                            .disabled(model.activeWorkspace == nil)
                        Button("New folder", systemImage: "folder.badge.plus") { Task { await model.createFolder() } }
                            .disabled(model.activeWorkspace == nil)
                        Button("Upload file", systemImage: "arrow.up.doc") { showingFileImporter = true }
                            .disabled(model.activeWorkspace == nil)
                        Button("Connect repository", systemImage: "plus") { openRepositories() }
                    } label: {
                        Image(systemName: "plus").accessibilityLabel("Create or connect")
                    }
                }
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
        }
    }

    private var treeRows: [FileTreeRow] {
        let children = Dictionary(grouping: model.files) { parentPath($0.path) }
        var rows: [FileTreeRow] = []
        func append(_ parent: String, depth: Int) {
            let items = (children[parent] ?? []).sorted {
                if ($0.kind == "folder") != ($1.kind == "folder") { return $0.kind == "folder" }
                return entryName($0.path).localizedStandardCompare(entryName($1.path)) == .orderedAscending
            }
            for file in items {
                rows.append(FileTreeRow(file: file, depth: depth))
                if file.kind == "folder", model.expandedFolders.contains(file.path) { append(file.path, depth: depth + 1) }
            }
        }
        append("", depth: 0)
        return rows
    }

    private func fileRow(_ row: FileTreeRow) -> some View {
        let file = row.file
        return Button {
            if file.kind == "folder" { Task { await model.toggleFolder(file) } }
            else { Task { await model.open(file) } }
        } label: {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                if file.kind == "folder" {
                    Image(systemName: model.expandedFolders.contains(file.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Image(systemName: model.expandedFolders.contains(file.path) ? "folder.fill" : "folder")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: file.isMarkdown ? "doc.text" : "paperclip")
                        .frame(width: 24).foregroundStyle(file.isMarkdown ? Color.accentColor : Color.secondary)
                }
                Text(entryName(file.path)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(model.activeFile?.id == file.id ? Color.accentColor.opacity(0.12) : nil)
    }

    @ViewBuilder private var detailPane: some View {
        if model.isRestoringSession {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.user == nil {
            signIn
        } else if model.activeFile?.isMarkdown == true {
            markdownEditor
        } else if model.activeWorkspace == nil {
            emptyWorkspace
        } else if let file = model.activeFile {
            ContentUnavailableView(entryName(file.path), systemImage: "paperclip", description: Text("This file is ready to preview."))
        } else {
            workspaceHome
        }
    }

    private var workspaceHome: some View {
        ContentUnavailableView {
            Label(model.activeWorkspace?.repository ?? "Workspace", systemImage: "doc.text")
        } description: {
            Text("Open a note or create one to get started.")
        } actions: {
            Button("New note", systemImage: "square.and.pencil") { Task { await model.createNote() } }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(model.activeWorkspace?.repository ?? "Workspace")
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 36, weight: .regular)).foregroundStyle(.secondary)
            Text("Connect a GitHub repository")
                .font(.title2.weight(.semibold))
            Text("Your Markdown files appear here and stay in sync with GitHub.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
            Button("Choose repository") { openRepositories() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Workspace")
    }

    private var markdownEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(model.activeWorkspace?.repository ?? "Workspace").lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text(model.activeFile.map { entryName($0.path) } ?? "Note").lineLimit(1)
                Spacer()
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)

            TextEditor(text: Binding(get: { model.markdown }, set: { model.editMarkdown($0) }))
                .font(.system(size: 18, weight: .regular, design: .default))
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Markdown editor")
                .background(Color(uiColor: .systemBackground))

            HStack(spacing: 8) {
                Circle().fill(model.githubStatus == "synced" ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(syncLabel).lineLimit(1)
                Spacer()
                if model.collaborators.count > 1 {
                    Label("\(model.collaborators.count)", systemImage: "person.2")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.bar)
        }
        .navigationTitle(model.activeFile.map { entryName($0.path) } ?? "Note")
    }

    private var syncLabel: String {
        if model.githubStatus == "synced" { return "Synced with GitHub" }
        if model.pendingFiles > 0 { return "\(model.pendingFiles) changes · syncing" }
        return model.githubStatus.capitalized
    }

    private var repositoryPicker: some View {
        NavigationStack {
            Group {
                if model.repositories.isEmpty {
                    ContentUnavailableView("No writable repositories", systemImage: "externaldrive", description: Text("GitHub did not return any repositories you can edit."))
                } else {
                    List(model.repositories) { repository in
                        Button {
                            Task { await model.connect(repository); showingRepositories = false }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: repository.private ? "lock" : "globe.americas")
                                    .foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repository.fullName).foregroundStyle(.primary)
                                    Text("\(repository.private ? "Private" : "Public") · \(repository.defaultBranch)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Connect repository")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingRepositories = false } } }
        }
    }

    private var settingsForm: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://pkms-cloud.lkh0310kr.workers.dev", text: Binding(get: { model.serverAddress }, set: { model.serverAddress = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                if let user = model.user {
                    Section("GitHub") {
                        LabeledContent("Signed in as", value: user.login)
                        Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showingSettings = false } } }
        }
    }

    private var signIn: some View {
        VStack(spacing: 22) {
            Image(systemName: "doc.text")
                .font(.system(size: 34, weight: .regular)).foregroundStyle(.tint)
                .frame(width: 72, height: 72).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 8) {
                Text("Your workspace, everywhere")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).multilineTextAlignment(.center)
                Text("Sign in with GitHub to open and edit your Markdown files.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 330)
            }

            if let code = model.deviceCode {
                VStack(spacing: 14) {
                    Text("Enter this code on GitHub")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .tracking(3).textSelection(.enabled).padding(.vertical, 12)
                        .frame(maxWidth: 300).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    if let url = model.verificationURL { Link("Open GitHub", destination: url).buttonStyle(.borderedProminent) }
                    ProgressView("Waiting for authorization")
                        .font(.footnote).tint(.secondary)
                }
                .padding(.top, 6)
            } else {
                Button {
                    Task { await model.beginSignIn() }
                } label: {
                    Label("Continue with GitHub", systemImage: "arrow.up.right")
                        .font(.headline).frame(maxWidth: 300).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("PKMS")
    }

    private func openRepositories() {
        Task {
            await model.loadRepositories()
            showingRepositories = true
        }
    }

    private func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private func entryName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }
}

private struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { controller.reloadData() }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
