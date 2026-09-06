import Foundation

public struct DiscoveryRequestUsage: Codable, Hashable, Sendable {
    /// Direct HTTP attempts only; external tools do not expose their HTTP count.
    public var networkRequests = 0
    public var githubAPIRequests = 0
    public var externalToolInvocations = 0
    public var reusedRequests = 0
    public var budgetBlockedRequests = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case networkRequests, githubAPIRequests, externalToolInvocations, reusedRequests, budgetBlockedRequests
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        networkRequests = try values.decodeIfPresent(Int.self, forKey: .networkRequests) ?? 0
        githubAPIRequests = try values.decodeIfPresent(Int.self, forKey: .githubAPIRequests) ?? 0
        externalToolInvocations = try values.decodeIfPresent(Int.self, forKey: .externalToolInvocations) ?? 0
        reusedRequests = try values.decodeIfPresent(Int.self, forKey: .reusedRequests) ?? 0
        budgetBlockedRequests = try values.decodeIfPresent(Int.self, forKey: .budgetBlockedRequests) ?? 0
    }
}

/// One user operation owns its requests, including nested media resolvers.
/// No URL, credential or response body is persisted in the usage summary.
public actor DiscoveryRequestContext {
    private struct Key: Hashable {
        let url: URL?
        let authorization: String?
        let accept: String?
        let maximumBytes: Int
    }
    private struct Entry {
        let task: Task<(Data, URLResponse), Error>
        var waiters: Set<UUID>
        var bytes: Int?
    }
    public struct BudgetExceeded: Error, Sendable {}
    private let gate: GitHubDiscoveryRateLimitGate
    private let maximumGitHubRequests: Int
    private let maximumNetworkRequests: Int
    private let maximumExternalToolInvocations: Int
    private var entries: [Key: Entry] = [:]
    private var counters = DiscoveryRequestUsage()
    private var githubReservations = 0
    private var networkReservations = 0
    private var retainedBytes = 0
    private var closed = false

    public init(
        gate: GitHubDiscoveryRateLimitGate,
        maximumGitHubRequests: Int = 12,
        maximumNetworkRequests: Int = 256,
        maximumExternalToolInvocations: Int = 2
    ) {
        self.gate = gate
        self.maximumGitHubRequests = max(0, maximumGitHubRequests)
        self.maximumNetworkRequests = max(0, maximumNetworkRequests)
        self.maximumExternalToolInvocations = max(0, maximumExternalToolInvocations)
    }

    public func usage() -> DiscoveryRequestUsage { counters }

    public func finish() {
        closed = true
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
        retainedBytes = 0
    }

    func data(for request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let key = Key(url: request.url, authorization: request.value(forHTTPHeaderField: "Authorization"),
                      accept: request.value(forHTTPHeaderField: "Accept"), maximumBytes: maximumBytes)
        let waiter = UUID()
        let task: Task<(Data, URLResponse), Error>
        if var entry = entries[key] {
            counters.reusedRequests += 1
            entry.waiters.insert(waiter)
            entries[key] = entry
            task = entry.task
        } else {
            trimCache()
            guard entries.count < 128 else { counters.budgetBlockedRequests += 1; throw BudgetExceeded() }
            task = Task {
                try await self.admit(request)
                let delegate = DiscoveryRedirectDelegate(context: self, request: request)
                let result = try await BoundedNetworkResponseLoader.data(for: request, session: session, maximumBytes: maximumBytes,
                    delegate: delegate)
                if let http = result.1 as? HTTPURLResponse, http.url?.host == "api.github.com" {
                    await self.gate.observeDiscoveryResponse(http, anonymous: await delegate.isAnonymous())
                }
                return result
            }
            entries[key] = Entry(task: task, waiters: [waiter])
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                release(key, waiter: waiter, bytes: result.0.count)
                try Task.checkCancellation()
                return result
            } catch {
                release(key, waiter: waiter, bytes: nil)
                throw error
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
    }

    private func admit(_ request: URLRequest) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let isGitHub = request.url?.host == "api.github.com"
        guard networkReservations < maximumNetworkRequests,
              !isGitHub || githubReservations < maximumGitHubRequests else {
            counters.budgetBlockedRequests += 1
            throw BudgetExceeded()
        }
        // Reserve both budgets before crossing actors, so concurrent sources and
        // redirects cannot all pass the same last available slot.
        networkReservations += 1
        if isGitHub { githubReservations += 1 }
        do {
            if isGitHub {
                guard await gate.reserveDiscoveryRequest(
                    authenticated: request.value(forHTTPHeaderField: "Authorization") != nil,
                    resource: GitHubDiscoveryRateLimitGate.resource(for: request.url)
                ) else {
                    counters.budgetBlockedRequests += 1
                    throw BudgetExceeded()
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch {
            networkReservations -= 1
            if isGitHub { githubReservations -= 1 }
            throw error
        }
        if isGitHub { counters.githubAPIRequests += 1 }
        counters.networkRequests += 1
    }

    func reserveExternalToolInvocation() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard counters.externalToolInvocations < maximumExternalToolInvocations else {
            counters.budgetBlockedRequests += 1
            throw BudgetExceeded()
        }
        counters.externalToolInvocations += 1
    }

    func redirect(from response: HTTPURLResponse, to request: URLRequest, anonymous: Bool = true) async -> URLRequest? {
        if response.url?.host == "api.github.com" {
            await gate.observeDiscoveryResponse(response, anonymous: anonymous)
        }
        do { try await admit(request); return request } catch { return nil }
    }

    private func release(_ key: Key, waiter: UUID, bytes: Int?) {
        guard var entry = entries[key] else { return }
        entry.waiters.remove(waiter)
        if let bytes, entry.bytes == nil {
            entry.bytes = bytes
            retainedBytes += bytes
        }
        entries[key] = entry
        trimCache()
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard var entry = entries[key], entry.waiters.remove(waiter) != nil else { return }
        if entry.waiters.isEmpty, entry.bytes == nil {
            entry.task.cancel()
            entries.removeValue(forKey: key)
        } else { entries[key] = entry }
    }

    private func trimCache() {
        while retainedBytes > 8 * 1_024 * 1_024 || entries.count >= 128 {
            guard let key = entries.first(where: { $0.value.bytes != nil && $0.value.waiters.isEmpty })?.key,
                  let removed = entries.removeValue(forKey: key)
            else { break }
            retainedBytes -= removed.bytes ?? 0
        }
    }
}

private final class DiscoveryRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let context: DiscoveryRequestContext
    private let identity: DiscoveryRedirectIdentity
    init(context: DiscoveryRequestContext, request: URLRequest) {
        self.context = context
        identity = DiscoveryRedirectIdentity(request: request)
    }

    func isAnonymous() async -> Bool { await identity.anonymous }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let next = await context.redirect(from: response, to: request, anonymous: await identity.anonymous)
        if let next { await identity.update(request: next) }
        return next
    }
}

/// A redirect response belongs to the request before the redirect. Its target
/// may have stripped Authorization, so it cannot identify the source quota.
private actor DiscoveryRedirectIdentity {
    private(set) var anonymous: Bool
    init(request: URLRequest) {
        anonymous = request.value(forHTTPHeaderField: "Authorization") == nil
    }
    func update(request: URLRequest) {
        anonymous = request.value(forHTTPHeaderField: "Authorization") == nil
    }
}

enum DiscoveryNetworkResponseLoader {
    @TaskLocal static var context: DiscoveryRequestContext?

    static func data(for request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        if let context { return try await context.data(for: request, session: session, maximumBytes: maximumBytes) }
        return try await BoundedNetworkResponseLoader.data(for: request, session: session, maximumBytes: maximumBytes)
    }
}
