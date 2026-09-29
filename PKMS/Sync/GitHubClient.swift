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

    // MARK: - Transport

    private func get(_ path: String, query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") async throws -> Data {
        var url = Self.baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
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
        default:
            struct Message: Decodable { let message: String? }
            throw GitHubError.http(status: http.statusCode, message: (try? JSONDecoder().decode(Message.self, from: data))?.message)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
