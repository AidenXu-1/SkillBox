import Foundation
import LocalAuthentication
import Security

enum KeychainCredentialAccessibility {
    static var interactive: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
}

enum KeychainCredentialSaveRecovery: Equatable {
    case add
    case replaceAfterAuthorization
    case fail
}

enum KeychainCredentialAccessPolicy {
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func automaticReadQuery(service: String, account: String) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        // The legacy macOS file-based keychain can still present its ACL dialog
        // even when the LocalAuthentication context disallows interaction.
        // Fail instead of prompting as a second, Security-framework-level guard.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    static func saveRecovery(for status: OSStatus) -> KeychainCredentialSaveRecovery {
        switch status {
        case errSecItemNotFound:
            .add
        case errSecInteractionNotAllowed, errSecAuthFailed:
            .replaceAfterAuthorization
        default:
            .fail
        }
    }

    static func save(_ data: Data, service: String, account: String) -> OSStatus {
        let baseQuery = baseQuery(service: service, account: account)
        var silentQuery = baseQuery
        silentQuery[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: KeychainCredentialAccessibility.interactive,
        ]
        let updateStatus = SecItemUpdate(silentQuery as CFDictionary, attributes as CFDictionary)
        switch saveRecovery(for: updateStatus) {
        case .add:
            return add(data, to: baseQuery)
        case .replaceAfterAuthorization:
            let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { return deleteStatus }
            return add(data, to: baseQuery)
        case .fail:
            return updateStatus
        }
    }

    private static func add(_ data: Data, to baseQuery: [String: Any]) -> OSStatus {
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = KeychainCredentialAccessibility.interactive
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

public struct GitHubDeviceAuthorization: Hashable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var expiresAt: Date
    public var pollingInterval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresAt: Date, pollingInterval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.pollingInterval = pollingInterval
    }
}

public struct GitHubOAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var accessTokenExpiresAt: Date?
    public var refreshTokenExpiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, accessTokenExpiresAt: Date? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public enum GitHubDevicePollResult: Sendable {
    case pending
    case slowDown
    case authorized(GitHubOAuthTokens)
    case expired
    case denied
}

public enum GitHubAuthenticationError: LocalizedError {
    case missingClientID
    case invalidResponse
    case requestFailed(Int)
    case refreshExpired
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "SkillBox 还没有配置 GitHub 登录"
        case .invalidResponse: "GitHub 返回了无法识别的登录结果"
        case .requestFailed: "暂时无法连接 GitHub，请稍后重试"
        case .refreshExpired: "GitHub 登录已过期，请重新连接"
        case .keychain: "无法访问 macOS 钥匙串"
        }
    }
}

public protocol GitHubCredentialStore: Sendable {
    func load() async throws -> GitHubOAuthTokens?
    func save(_ tokens: GitHubOAuthTokens) async throws
    func delete() async throws
}

public actor KeychainGitHubCredentialStore: GitHubCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.zhaoji.skillbox.github", account: String = "github-app-user-token") {
        self.service = service
        self.account = account
    }

    public func load() throws -> GitHubOAuthTokens? {
        let query = KeychainCredentialAccessPolicy.automaticReadQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GitHubAuthenticationError.keychain(status) }
        return try JSONDecoder().decode(GitHubOAuthTokens.self, from: data)
    }

    public func save(_ tokens: GitHubOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = KeychainCredentialAccessPolicy.save(data, service: service, account: account)
        guard status == errSecSuccess else { throw GitHubAuthenticationError.keychain(status) }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubAuthenticationError.keychain(status) }
    }
}

public struct GitHubDeviceFlowClient: Sendable {
    public let clientID: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(clientID: String, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.clientID = clientID
        self.session = session
        self.now = now
    }

    public func beginAuthorization() async throws -> GitHubDeviceAuthorization {
        guard !clientID.isEmpty else { throw GitHubAuthenticationError.missingClientID }
        let response: DeviceCodeResponse = try await post(
            url: URL(string: "https://github.com/login/device/code")!,
            form: ["client_id": clientID]
        )
        return .init(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: response.verificationURI,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            pollingInterval: TimeInterval(response.interval)
        )
    }

    public func pollAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubDevicePollResult {
        if authorization.expiresAt <= now() { return .expired }
        let response: TokenResponse = try await post(
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            form: [
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
        )
        if let error = response.error {
            switch error {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: throw GitHubAuthenticationError.invalidResponse
            }
        }
        return .authorized(try response.tokens(now: now()))
    }

    public func refresh(_ tokens: GitHubOAuthTokens) async throws -> GitHubOAuthTokens {
        guard let refreshToken = tokens.refreshToken,
              tokens.refreshTokenExpiresAt.map({ $0 > now() }) ?? true
        else { throw GitHubAuthenticationError.refreshExpired }
        let response: TokenResponse = try await post(
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        return try response.tokens(now: now())
    }

    private func post<Response: Decodable>(url: URL, form: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.sorted { $0.key < $1.key }.map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await BoundedNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 256 * 1_024
            )
        } catch is BoundedNetworkResponseError {
            throw GitHubAuthenticationError.invalidResponse
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GitHubAuthenticationError.requestFailed(http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

public actor GitHubAuthenticatedSession: GitHubAccessTokenProvider {
    private let client: GitHubDeviceFlowClient
    private let credentialStore: any GitHubCredentialStore
    private let now: @Sendable () -> Date

    public init(
        client: GitHubDeviceFlowClient,
        credentialStore: any GitHubCredentialStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.now = now
    }

    public func accessToken() async throws -> String? {
        guard let tokens = try await credentialStore.load() else { return nil }
        if tokens.accessTokenExpiresAt.map({ $0 > now().addingTimeInterval(60) }) ?? true {
            return tokens.accessToken
        }
        let refreshed = try await client.refresh(tokens)
        try await credentialStore.save(refreshed)
        return refreshed.accessToken
    }

    public func save(_ tokens: GitHubOAuthTokens) async throws { try await credentialStore.save(tokens) }
    public func disconnect() async throws { try await credentialStore.delete() }
    public func isConnected() async -> Bool { (try? await credentialStore.load()) != nil }
}

private struct DeviceCodeResponse: Decodable {
    var deviceCode: String
    var userCode: String
    var verificationURI: URL
    var expiresIn: Int
    var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String?
    var expiresIn: Int?
    var refreshToken: String?
    var refreshTokenExpiresIn: Int?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
    }

    func tokens(now: Date) throws -> GitHubOAuthTokens {
        guard let accessToken else { throw GitHubAuthenticationError.invalidResponse }
        return .init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}
