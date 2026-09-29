import Foundation

struct GitHubUser: Decodable, Sendable {
    let login: String
}

struct GitHubRepository: Decodable, Identifiable, Hashable, Sendable {
    let fullName: String
    let defaultBranch: String
    let `private`: Bool
    let description: String?

    var id: String { fullName }
}

struct GitTree: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let path: String
        let mode: String
        let type: String
        let sha: String
    }

    let sha: String
    let tree: [Entry]
    let truncated: Bool
}

enum GitHubError: LocalizedError {
    case unauthorized
    case notFound
    case rateLimited(resetsAt: Date?)
    case treeTooLarge
    case notFastForward
    case readOnly
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "GitHub rejected the sign-in. Sign in again."
        case .notFound:
            "Repository or branch not found, or this account doesn’t have access to it."
        case .rateLimited(let date):
            "GitHub rate limit reached." + (date.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
        case .treeTooLarge:
            "This repository has too many files to sync."
        case .notFastForward:
            "GitHub changed while uploading. Try syncing again."
        case .readOnly:
            "This account can’t save changes to the repository."
        case .http(let status, let message):
            "GitHub error \(status)" + (message.map { ": \($0)" } ?? "")
        }
    }
}

/// Minimal GitHub REST API client. It covers only what sync needs; Git itself stays an implementation detail.
struct GitHubClient: Sendable {
    var token: String?
    var session: URLSession = .shared

    private static let baseURL = URL(string: "https://api.github.com")!

    func currentUser() async throws -> GitHubUser {
        try await decode(get("user"))
    }

    /// Repositories the user can access, most recently updated first.
    func repositories() async throws -> [GitHubRepository] {
        var result: [GitHubRepository] = []
        for page in 1...5 {
            let batch: [GitHubRepository] = try await decode(get("user/repos", query: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "sort", value: "updated"),
            ]))
            result += batch
            if batch.count < 100 { break }
        }
        return result
    }

    func repository(_ fullName: String) async throws -> GitHubRepository {
        try await decode(get("repos/\(fullName)"))
    }

    /// SHA of the commit at the tip of `branch`.
    func headCommit(of fullName: String, branch: String) async throws -> String {
        let data = try await get("repos/\(fullName)/commits/\(branch)", accept: "application/vnd.github.sha")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tree(of fullName: String, commit: String) async throws -> GitTree {
        let tree: GitTree = try await decode(get("repos/\(fullName)/git/trees/\(commit)",
                                                 query: [URLQueryItem(name: "recursive", value: "1")]))
        if tree.truncated { throw GitHubError.treeTooLarge }
        return tree
    }

    func blob(of fullName: String, sha: String) async throws -> Data {
        try await get("repos/\(fullName)/git/blobs/\(sha)", accept: "application/vnd.github.raw+json")
    }

    // MARK: - Writing (Git Data API)

    private struct SHAResponse: Decodable { let sha: String }

    func createBlob(in fullName: String, content: Data) async throws -> String {
        let body = ["content": content.base64EncodedString(), "encoding": "base64"]
        let response: SHAResponse = try await decode(send("POST", "repos/\(fullName)/git/blobs", body: body))
        return response.sha
    }

    /// Tree SHA of a commit.
    func treeSHA(of fullName: String, commit: String) async throws -> String {
        struct Commit: Decodable { let tree: SHAResponse }
        let response: Commit = try await decode(get("repos/\(fullName)/git/commits/\(commit)"))
        return response.tree.sha
    }

    /// A file in a new tree; a `nil` sha deletes the path.
    struct TreeChange: Encodable {
        let path: String
        let sha: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode("100644", forKey: .mode)
            try container.encode("blob", forKey: .type)
            try container.encode(sha, forKey: .sha)  // explicit null deletes the file
        }

        private enum CodingKeys: String, CodingKey { case path, mode, type, sha }
    }

    func createTree(in fullName: String, base: String, changes: [TreeChange]) async throws -> String {
        struct Body: Encodable { let base_tree: String; let tree: [TreeChange] }
        let response: SHAResponse = try await decode(send("POST", "repos/\(fullName)/git/trees",
                                                          body: Body(base_tree: base, tree: changes)))
        return response.sha
    }

    func createCommit(in fullName: String, message: String, tree: String, parent: String) async throws -> String {
        struct Body: Encodable { let message: String; let tree: String; let parents: [String] }
        let response: SHAResponse = try await decode(send("POST", "repos/\(fullName)/git/commits",
                                                          body: Body(message: message, tree: tree, parents: [parent])))
        return response.sha
    }

    /// Moves `branch` to `commit`. Throws `.notFastForward` if the branch moved on in the meantime.
    func updateBranch(in fullName: String, branch: String, to commit: String) async throws {
        struct Body: Encodable { let sha: String; let force: Bool }
        do {
            _ = try await send("PATCH", "repos/\(fullName)/git/refs/heads/\(branch)", body: Body(sha: commit, force: false))
        } catch GitHubError.http(status: 422, _) {
            throw GitHubError.notFastForward
        }
    }

    // MARK: - Transport

    private func get(_ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") async throws -> Data {
        try await send("GET", path, query: query, accept: accept, body: Optional<String>.none)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      accept: String = "application/vnd.github+json", body: (some Encodable)?) async throws -> Data {
        var url = Self.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw GitHubError.unauthorized
        case 404:
            throw GitHubError.notFound
        case 429:
            throw GitHubError.rateLimited(resetsAt: nil)
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
            throw GitHubError.rateLimited(resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
        case 403 where method != "GET":
            throw GitHubError.readOnly
        default:
            throw GitHubError.http(status: http.statusCode, message: (try? JSONDecoder().decode(ErrorMessage.self, from: data))?.message)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

private struct ErrorMessage: Decodable {
    let message: String?
}
