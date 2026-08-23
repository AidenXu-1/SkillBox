import Foundation
import LocalAuthentication
import Security
import Testing
@testable import SkillBoxCore

@Suite("GitHub device authorization", .serialized)
struct GitHubAuthenticationTests {
    @Test("Interactive credentials are available only while the Mac is unlocked")
    func keychainAccessibilityRequiresUnlockedMac() {
        #expect(
            KeychainCredentialAccessibility.interactive as String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    @Test("Automatic credential reads never ask for the Mac login password")
    func automaticCredentialReadsAreNonInteractive() {
        let query = KeychainCredentialAccessPolicy.automaticReadQuery(
            service: "com.zhaoji.skillbox.test",
            account: "test-account"
        )

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context?.interactionNotAllowed == true)
        #expect(
            query[kSecUseAuthenticationUI as String].map(String.init(describing:))
                == "u_AuthUIF"
        )
        #expect(query[kSecReturnData as String] as? Bool == true)
    }

    @Test("An explicit save can rebind a credential after the app identity changes")
    func explicitSaveCanRebindAfterAuthorizationIsNeeded() {
        #expect(KeychainCredentialAccessPolicy.saveRecovery(for: errSecInteractionNotAllowed) == .replaceAfterAuthorization)
        #expect(KeychainCredentialAccessPolicy.saveRecovery(for: errSecAuthFailed) == .replaceAfterAuthorization)
        #expect(KeychainCredentialAccessPolicy.saveRecovery(for: errSecItemNotFound) == .add)
        #expect(KeychainCredentialAccessPolicy.saveRecovery(for: errSecUserCanceled) == .fail)
    }

    @Test("Desktop login uses device flow without sending a client secret")
    func deviceFlow() async throws {
        let session = DeviceFlowFixture.session()
        let client = GitHubDeviceFlowClient(clientID: "public-client-id", session: session)
        let authorization = try await client.beginAuthorization()
        #expect(authorization.userCode == "A8D2-K7PL")
        #expect(authorization.verificationURL.absoluteString == "https://github.com/login/device")

        let result = try await client.pollAuthorization(authorization)
        guard case let .authorized(tokens) = result else {
            Issue.record("Expected an authorized token response")
            return
        }
        #expect(tokens.accessToken == "ghu_access")
        #expect(tokens.refreshToken == "ghr_refresh")
        #expect(DeviceFlowMockURLProtocol.requestBodies.allSatisfy { !$0.contains("client_secret") })
    }

    @Test("Expired device-flow tokens refresh and rotate through the credential store")
    func refreshesExpiredToken() async throws {
        let store = MemoryGitHubCredentialStore(tokens: .init(
            accessToken: "expired",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 0),
            refreshTokenExpiresAt: Date.distantFuture
        ))
        let client = GitHubDeviceFlowClient(clientID: "public-client-id", session: DeviceFlowFixture.session())
        let session = GitHubAuthenticatedSession(client: client, credentialStore: store)
        #expect(try await session.accessToken() == "ghu_refreshed")
        #expect(try await store.load()?.refreshToken == "ghr_rotated")
    }

    @Test("Expired device codes stop locally without another network request")
    func expiredDeviceCodeStopsLocally() async throws {
        let client = GitHubDeviceFlowClient(clientID: "public-client-id", session: DeviceFlowFixture.session())
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "expired",
            userCode: "OLD-CODE",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: .distantPast,
            pollingInterval: 5
        )
        let result = try await client.pollAuthorization(authorization)
        guard case .expired = result else {
            Issue.record("Expected the expired authorization to stop locally")
            return
        }
        #expect(DeviceFlowMockURLProtocol.requestBodies.isEmpty)
    }

    @Test("Disconnecting removes the locally stored GitHub tokens")
    func disconnectRemovesTokens() async throws {
        let store = MemoryGitHubCredentialStore(tokens: .init(accessToken: "private-token"))
        let session = GitHubAuthenticatedSession(
            client: GitHubDeviceFlowClient(clientID: "public-client-id", session: DeviceFlowFixture.session()),
            credentialStore: store
        )

        try await session.disconnect()

        #expect(try await store.load() == nil)
    }

    @Test("Bounded network reads stop oversized responses before callers decode them")
    func boundedNetworkReadRejectsOversizedResponse() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://example.com/oversized")!)

        await #expect(throws: BoundedNetworkResponseError.self) {
            try await BoundedNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 64
            )
        }
    }
}

private final class OversizedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "256"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 256))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor MemoryGitHubCredentialStore: GitHubCredentialStore {
    var tokens: GitHubOAuthTokens?
    init(tokens: GitHubOAuthTokens? = nil) { self.tokens = tokens }
    func load() throws -> GitHubOAuthTokens? { tokens }
    func save(_ tokens: GitHubOAuthTokens) throws { self.tokens = tokens }
    func delete() throws { tokens = nil }
}

private final class DeviceFlowMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestBodies: [String] = []
    nonisolated(unsafe) static var tokenRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if let data = request.httpBody {
            body = String(data: data, encoding: .utf8) ?? ""
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = String(data: data, encoding: .utf8) ?? ""
        } else {
            body = ""
        }
        Self.requestBodies.append(body)
        let payload: String
        if request.url?.path == "/login/device/code" {
            payload = #"{"device_code":"device-code","user_code":"A8D2-K7PL","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        } else if body.contains("grant_type=refresh_token") {
            payload = #"{"access_token":"ghu_refreshed","expires_in":28800,"refresh_token":"ghr_rotated","refresh_token_expires_in":15897600,"token_type":"bearer"}"#
        } else {
            Self.tokenRequestCount += 1
            payload = #"{"access_token":"ghu_access","expires_in":28800,"refresh_token":"ghr_refresh","refresh_token_expires_in":15897600,"token_type":"bearer"}"#
        }
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum DeviceFlowFixture {
    static func session() -> URLSession {
        DeviceFlowMockURLProtocol.requestBodies = []
        DeviceFlowMockURLProtocol.tokenRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceFlowMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
