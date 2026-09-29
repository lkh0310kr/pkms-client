import Foundation
import Security

enum GitHubAppConfig {
    /// Client ID of the GitHub OAuth App used for "Sign in with GitHub" (Device Flow).
    /// Register one at https://github.com/settings/developers, tick "Enable Device Flow",
    /// and paste its Client ID here. Client IDs are public; no client secret is needed.
    /// While empty, the app offers personal access token sign-in only.
    static let clientID = "Ov23liV7UUqSYZxljsgf"

    /// `repo` grants access to private repositories (and will be needed for pushing later).
    static let scope = "repo"
}

/// GitHub OAuth Device Flow: the app shows a short code, the user approves it on github.com,
/// and the app polls until GitHub issues an access token.
/// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
struct GitHubDeviceFlow: Sendable {
    struct DeviceCode: Decodable, Sendable, Equatable {
        let deviceCode: String
        let userCode: String
        let verificationUri: URL
        let expiresIn: Int
        let interval: Int
    }

    enum FlowError: LocalizedError {
        case expired
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .expired: "The sign-in code expired. Try again."
            case .denied: "Sign-in was canceled on GitHub."
            case .failed(let message): message
            }
        }
    }

    let clientID: String
    var session: URLSession = .shared

    func start() async throws -> DeviceCode {
        try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": GitHubAppConfig.scope])
    }

    /// Polls until the user approves the code. Cancel the calling task to stop waiting.
    func waitForToken(_ code: DeviceCode) async throws -> String {
        struct Response: Decodable {
            let accessToken: String?
            let error: String?
            let errorDescription: String?
            let interval: Int?
        }
        var interval = max(code.interval, 5)
        let deadline = Date.now.addingTimeInterval(TimeInterval(code.expiresIn))
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let response: Response = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = response.accessToken { return token }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval = response.interval ?? interval + 5
            case "expired_token": throw FlowError.expired
            case "access_denied": throw FlowError.denied
            default: throw FlowError.failed(response.errorDescription ?? response.error ?? "Sign-in failed.")
            }
        }
        throw FlowError.expired
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// Stores the GitHub token in the Keychain (never in UserDefaults or the vault).
enum TokenStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "pkms") + ".github"
    private static let account = "access-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var item: CFTypeRef?
        var query = query
        query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        var query = query
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
