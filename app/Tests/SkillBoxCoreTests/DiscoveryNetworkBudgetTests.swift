import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Discovery network budgets", .serialized)
struct DiscoveryNetworkBudgetTests {
    private func session() -> URLSession {
        NetworkBudgetProtocol.log.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkBudgetProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(resource: String, remaining: Int, now: Date, status: Int = 200,
                          retryAfter: String? = nil, path: String = "/search/repositories") -> HTTPURLResponse {
        var headers = ["X-RateLimit-Resource": resource, "X-RateLimit-Remaining": String(remaining),
                       "X-RateLimit-Reset": String(Int(now.addingTimeInterval(resource == "core" ? 3_600 : 60).timeIntervalSince1970))]
        headers["Retry-After"] = retryAfter
        return HTTPURLResponse(url: URL(string: "https://api.github.com\(path)")!, statusCode: status,
                               httpVersion: nil, headerFields: headers)!
    }

    @Test("A successful search with nine remaining does not consume core headroom")
    func successfulSearchBucketsAreIndependent() async {
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        await gate.observeDiscoveryResponse(response(resource: "core", remaining: 13, now: now), anonymous: true, now: now)
        await gate.observeDiscoveryResponse(response(resource: "search", remaining: 9, now: now), anonymous: true, now: now)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now))
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now) == false)
        for _ in 0..<7 { #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .search, now: now)) }
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .search, now: now) == false)
        #expect(await gate.activeRetryDate(now: now) == nil)
    }

    @Test("Search local windows reset independently of the core hourly policy")
    func localSearchAndCoreWindowsAreIndependent() async {
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for _ in 0..<8 { #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .search, now: now)) }
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .search, now: now) == false)
        for _ in 0..<36 { #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now)) }
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now) == false)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .search, now: now.addingTimeInterval(61)))
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now.addingTimeInterval(61)) == false)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now.addingTimeInterval(3_601)))
    }

    @Test("The shared loader routes search URLs into search without spending core reserve")
    func sharedLoaderRoutesRequestsToTheirResource() async throws {
        let session = session()
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date()
        await gate.observeDiscoveryResponse(response(resource: "core", remaining: 13, now: now), anonymous: true)
        await gate.observeDiscoveryResponse(response(resource: "search", remaining: 9, now: now), anonymous: true)
        let context = DiscoveryRequestContext(gate: gate)
        for path in ["/search/repositories?q=one", "/search/repositories?q=two", "/repos/fixture/skill"] {
            _ = try await context.data(for: URLRequest(url: URL(string: "https://api.github.com\(path)")!),
                                       session: session, maximumBytes: 1_024)
        }
        #expect(await context.usage().githubAPIRequests == 3)
        #expect(NetworkBudgetProtocol.log.snapshot().count == 3)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core) == false)
        await context.finish()
    }

    @Test("Search exhaustion preserves core and raw access; secondary cooldown blocks all API buckets")
    func primaryAndSecondaryLimitsHaveDifferentScope() async throws {
        let session = session()
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date()
        await gate.observeDiscoveryResponse(response(resource: "search", remaining: 0, now: now, status: 403), anonymous: true)
        #expect(await gate.activeRetryDate(for: .search) != nil)
        #expect(await gate.activeRetryDate(for: .core) == nil)
        let context = DiscoveryRequestContext(gate: gate)
        _ = try await context.data(for: URLRequest(url: URL(string: "https://api.github.com/repos/fixture/skill")!),
                                   session: session, maximumBytes: 1_024)
        _ = try await context.data(for: URLRequest(url: URL(string: "https://raw.githubusercontent.com/fixture/skill/main/SKILL.md")!),
                                   session: session, maximumBytes: 1_024)
        #expect(await context.usage().networkRequests == 2)
        await gate.observeDiscoveryResponse(response(resource: "search", remaining: 9, now: now, status: 429, retryAfter: "120"), anonymous: true)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core) == false)
        #expect(await gate.reserveDiscoveryRequest(authenticated: true, resource: .codeSearch) == false)
        #expect(await gate.activeRetryDate(for: .core, now: now.addingTimeInterval(121)) == nil)
        await context.finish()
    }

    @Test("GitHub resource headers take precedence over the URL and code search has its own bucket")
    func resourceHeadersAndCodeSearch() async {
        let gate = GitHubDiscoveryRateLimitGate()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        await gate.observeDiscoveryResponse(response(resource: "search", remaining: 0, now: now, path: "/repos/fixture/skill"), anonymous: true, now: now)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core, now: now))
        #expect(await gate.reserveDiscoveryRequest(authenticated: true, resource: .codeSearch, now: now))
        #expect(await gate.reserveDiscoveryRequest(authenticated: true, resource: .search, now: now) == false)
        #expect(GitHubDiscoveryRateLimitGate.resource(for: URL(string: "https://api.github.com/search/code")) == .codeSearch)
        #expect(GitHubDiscoveryRateLimitGate.resource(for: URL(string: "https://api.github.com/search/repositories")) == .search)
        #expect(GitHubDiscoveryRateLimitGate.resource(for: URL(string: "https://api.github.com/repos/a/b")) == .core)
    }

    @Test("The default direct HTTP ceiling survives cache eviction and sequential requests")
    func cumulativeDirectHTTPBudget() async throws {
        let session = session()
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate())
        for index in 0..<300 {
            do {
                _ = try await context.data(for: URLRequest(url: URL(string: "https://public.invalid/item/\(index)")!),
                                           session: session, maximumBytes: 1_024)
            } catch is DiscoveryRequestContext.BudgetExceeded {} catch { throw error }
        }
        let usage = await context.usage()
        #expect(NetworkBudgetProtocol.log.snapshot().count == 256)
        #expect(usage.networkRequests == 256)
        #expect(usage.githubAPIRequests == 0)
        #expect(usage.budgetBlockedRequests == 44)
        await context.finish()
    }

    @Test("Mixed concurrent HTTP and API admissions cannot reuse the last budget slot")
    func concurrentMixedBudgetsAreAtomic() async {
        let session = session()
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate(), maximumGitHubRequests: 3, maximumNetworkRequests: 8)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let host = index.isMultiple(of: 2) ? "api.github.com" : "public.invalid"
                    do {
                        _ = try await context.data(for: URLRequest(url: URL(string: "https://\(host)/item/\(index)")!),
                                                   session: session, maximumBytes: 1_024)
                    } catch is DiscoveryRequestContext.BudgetExceeded {} catch { Issue.record("Unexpected error: \(error)") }
                }
            }
        }
        let requests = NetworkBudgetProtocol.log.snapshot()
        #expect(requests.count == 8)
        #expect(requests.filter { $0.host == "api.github.com" }.count <= 3)
        #expect(await context.usage().networkRequests == 8)
        #expect(await context.usage().budgetBlockedRequests == 32)
        await context.finish()
    }

    @Test("Non-GitHub redirects use the same cumulative direct HTTP ceiling")
    func redirectsUseDirectBudget() async throws {
        let session = session()
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate(), maximumNetworkRequests: 2)
        let url = URL(string: "https://public.invalid/old")!
        _ = try await context.data(for: URLRequest(url: url), session: session, maximumBytes: 1_024)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let destination = URLRequest(url: URL(string: "https://public.invalid/new")!)
        #expect(await context.redirect(from: response, to: destination) != nil)
        #expect(await context.redirect(from: response, to: destination) == nil)
        #expect(await context.usage().networkRequests == 2)
        #expect(await context.usage().budgetBlockedRequests == 1)
        await context.finish()
    }

    @Test("A redirect dropping Authorization cannot replace anonymous headroom with signed-in quota")
    func redirectedResponseKeepsItsOriginalIdentity() async throws {
        let session = session()
        let gate = GitHubDiscoveryRateLimitGate()
        let anonymousResponse = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/fixture/anonymous")!,
            statusCode: 200, httpVersion: nil, headerFields: ["X-RateLimit-Resource": "core", "X-RateLimit-Remaining": "12",
                "X-RateLimit-Reset": String(Int(Date().timeIntervalSince1970 + 100))])!
        await gate.observeDiscoveryResponse(anonymousResponse, anonymous: true)
        let context = DiscoveryRequestContext(gate: gate)
        var request = URLRequest(url: URL(string: "https://api.github.com/authenticated-redirect")!)
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        _ = try await context.data(for: request, session: session, maximumBytes: 1_024)
        #expect(await gate.reserveDiscoveryRequest(authenticated: false, resource: .core) == false)
        #expect(await context.usage().networkRequests == 2)
        #expect(await context.usage().githubAPIRequests == 1)
        #expect(NetworkBudgetProtocol.log.snapshot().count == 2)
        await context.finish()
    }

    @Test("Bilibili, WeChat and Hacker News share the operation loader and total budget")
    func allDirectMediaSourcesUseSharedBudget() async throws {
        let session = session()
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate(), maximumNetworkRequests: 4)
        let bilibili = BilibiliCommunityMediaSearchSource(session: session,
            navigationEndpoint: URL(string: "https://api.bilibili.com/x/web-interface/nav")!,
            searchEndpoint: URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type")!)
        let wechat = SogouWeChatCommunityMediaSearchSource(session: session, endpoint: URL(string: "https://weixin.sogou.com/weixin")!)
        let hackerNews = CommunityMediaSkillDiscoveryProvider(session: session, repositoryResolver: EmptyNetworkBudgetResolver())
        try await DiscoveryNetworkResponseLoader.$context.withValue(context) {
            _ = try await bilibili.search(query: "writing", limit: 10)
            _ = try await wechat.search(query: "writing", limit: 10)
            _ = try await hackerNews.search(query: "writing", limit: 10)
            do { _ = try await wechat.search(query: "another query", limit: 10); Issue.record("Media request escaped the total budget") }
            catch is SkillDiscoveryError {} catch { Issue.record("Unexpected error: \(error)") }
        }
        #expect(NetworkBudgetProtocol.log.snapshot().count == 4)
        #expect(await context.usage().networkRequests == 4)
        #expect(await context.usage().budgetBlockedRequests == 1)
        await context.finish()
    }

    @Test("External tool invocations have a separate two-call ceiling and never pretend to count internal HTTP")
    func externalToolsHaveSeparateBoundedCount() async {
        let runner = NetworkBudgetCommandRunner()
        let source = YTDLPCommunityMediaSearchSource(executablePath: "/fixture/yt-dlp", runner: runner)
        let context = DiscoveryRequestContext(gate: GitHubDiscoveryRateLimitGate())
        await DiscoveryNetworkResponseLoader.$context.withValue(context) {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<20 {
                    group.addTask {
                        do { _ = try await source.search(query: "query \(index)", limit: 10) }
                        catch is DiscoveryRequestContext.BudgetExceeded {} catch { Issue.record("Unexpected error: \(error)") }
                    }
                }
            }
        }
        let usage = await context.usage()
        #expect(await runner.invocations == 2)
        #expect(usage.externalToolInvocations == 2)
        #expect(usage.networkRequests == 0)
        #expect(usage.budgetBlockedRequests == 18)
        await context.finish()
        await DiscoveryNetworkResponseLoader.$context.withValue(context) {
            do { _ = try await source.search(query: "late query", limit: 10); Issue.record("Closed operation launched a tool") }
            catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        }
        #expect(await runner.invocations == 2)
    }

    @Test("Existing usage records decode without the new external-tool count")
    func oldUsageRecordsRemainReadable() throws {
        let usage = try JSONDecoder().decode(DiscoveryRequestUsage.self, from: Data(
            #"{"networkRequests":240,"githubAPIRequests":12,"reusedRequests":3,"budgetBlockedRequests":2}"#.utf8))
        #expect(usage.networkRequests == 240)
        #expect(usage.externalToolInvocations == 0)
        #expect(usage.budgetBlockedRequests == 2)
        #expect(try JSONDecoder().decode(DiscoveryRequestUsage.self, from: JSONEncoder().encode(usage)) == usage)
    }
}

private actor NetworkBudgetCommandRunner: CommunityCommandRunning {
    var invocations = 0
    func run(_ executable: String, arguments: [String]) async throws -> String {
        try Task.checkCancellation()
        invocations += 1
        return #"{"title":"A public Skill discussion","webpage_url":"https://www.youtube.com/watch?v=fixture"}"#
    }
}

private struct EmptyNetworkBudgetResolver: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult { .init(candidates: []) }
}

private final class NetworkBudgetProtocol: URLProtocol, @unchecked Sendable {
    static let log = BudgetRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.log.append(url)
        if url.path == "/authenticated-redirect" {
            let target = URLRequest(url: URL(string: "https://raw.githubusercontent.com/fixture/skill/main/SKILL.md")!)
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: [
                "Location": target.url!.absoluteString, "X-RateLimit-Resource": "core", "X-RateLimit-Remaining": "4999",
                "X-RateLimit-Reset": String(Int(Date().timeIntervalSince1970 + 3_600)),
            ])!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            return
        }
        let body: String
        if url.path == "/x/web-interface/nav" {
            body = #"{"code":0,"data":{"wbi_img":{"img_url":"https://i.invalid/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://i.invalid/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
        } else if url.host == "api.bilibili.com" {
            body = #"{"code":0,"data":{"result":[]}}"#
        } else if url.host == "weixin.sogou.com" {
            body = "<html><div class='no-result'></div></html>"
        } else if url.host == "hn.algolia.com" {
            body = #"{"hits":[],"nbPages":1,"page":0}"#
        } else {
            body = "ok"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.log.recordStop() }
}
