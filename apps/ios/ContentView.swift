import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PKMSModel.self) private var model
    @State private var showingRepositories = false
    @State private var showingSettings = false
    @State private var showingFileImporter = false

    var body: some View {
        NavigationSplitView { sidebar } detail: { detailPane }
            .alert("PKMS", isPresented: errorPresented) {
                Button("OK") { model.dismissError() }
            } message: { Text(model.errorMessage ?? "") }
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
        List(selection: fileSelection) {
            if model.user != nil {
                Section("Workspace") {
                    ForEach(model.workspaces) { workspace in
                        Button {
                            Task { await model.selectWorkspace(workspace) }
                        } label: { Label(workspace.repository, systemImage: "externaldrive") }
                    }
                }
                Section("Files") {
                    ForEach(model.files) { file in
                        Label(file.path, systemImage: file.kind == "folder" ? "folder" : (file.isMarkdown ? "doc.text" : "paperclip"))
                            .tag(file.id)
                    }
                }
            }
        }
        .navigationTitle("PKMS")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.user != nil {
                    Menu {
                        Button("New note", systemImage: "square.and.pencil") { Task { await model.createNote() } }
                        Button("New folder", systemImage: "folder.badge.plus") { Task { await model.createFolder() } }
                        Button("Upload file", systemImage: "arrow.up.doc") { showingFileImporter = true }
                        Button("Connect repository", systemImage: "plus") { Task { await model.loadRepositories(); showingRepositories = true } }
                    } label: { Image(systemName: "plus") }
                }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
    }

    private var fileSelection: Binding<String?> {
        Binding(get: { model.activeFile?.id }, set: { selected in
            guard let file = model.files.first(where: { $0.id == selected }) else { return }
            Task { await model.open(file) }
        })
    }

    @ViewBuilder private var detailPane: some View {
        if model.user == nil {
            signIn
        } else if model.activeFile?.isMarkdown == true {
            markdownEditor
        } else {
            ContentUnavailableView(model.activeFile?.path ?? "Choose a file", systemImage: "doc.text", description: Text("Markdown files sync live across your PKMS clients."))
        }
    }

    private var markdownEditor: some View {
        TextEditor(text: Binding(get: { model.markdown }, set: { model.editMarkdown($0) }))
            .font(.system(.body, design: .default))
            .padding()
            .navigationTitle(model.activeFile?.path ?? "Markdown")
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Circle().fill(model.githubStatus == "synced" ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.githubStatus == "synced" ? "Synced with GitHub" : "\(model.pendingFiles) changes · \(model.githubStatus)")
                    Spacer()
                    Text(model.collaborators.count > 1 ? "\(model.collaborators.count) connected" : "Just you")
                        .foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal).padding(.vertical, 10).background(.bar)
            }
    }

    private var repositoryPicker: some View {
        NavigationStack {
            List(model.repositories) { repository in
                Button {
                    Task { await model.connect(repository); showingRepositories = false }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repository.fullName).foregroundStyle(.primary)
                        Text(repository.private ? "Private · \(repository.defaultBranch)" : "Public · \(repository.defaultBranch)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    TextField("https://pkms.example.com", text: Binding(get: { model.serverAddress }, set: { model.serverAddress = $0 }))
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
        VStack(spacing: 18) {
            Image(systemName: "text.book.closed.fill").font(.system(size: 42)).foregroundStyle(.tint)
            Text("PKMS Cloud").font(.largeTitle.bold())
            Text("Your Markdown files, synced through GitHub.").foregroundStyle(.secondary)
            if let code = model.deviceCode {
                Text(code).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled)
                if let url = model.verificationURL { Link("Authorize with GitHub", destination: url) }
                ProgressView("Waiting for authorization…")
            } else {
                Button("Continue with GitHub") { Task { await model.beginSignIn() } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
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
