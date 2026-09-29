import SwiftUI
import UIKit

/// Displays an image referenced from Markdown: a vault asset (relative path or `![[wiki embed]]`)
/// or, when online, a remote URL.
struct VaultImageView: View {
    let source: String
    let alt: String

    @Environment(VaultStore.self) private var store
    @Environment(\.markdownDocumentPath) private var documentPath
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width)  // never upscale small images
            } else if failed {
                placeholder
            } else {
                Color.clear.frame(height: 120)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel(alt)
        .task(id: source) { await loadLocal() }
    }

    private var remoteURL: URL? {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color(.secondarySystemBackground))
    }

    private func loadLocal() async {
        guard remoteURL == nil else { return }
        let wikiTarget = WikiLink.target(in: source)
        guard let path = store.index.resolve(wikiTarget ?? source, from: documentPath, isWikiLink: wikiTarget != nil),
              let data = try? await store.repository.readData(at: path) else {
            failed = true
            return
        }
        // Decode off the main thread so large images don't stall scrolling.
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
        if let decoded { image = decoded } else { failed = true }
    }
}
