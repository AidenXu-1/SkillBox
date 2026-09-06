import Foundation

private final class DiscoveryProviderSearchRace: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<DiscoveryBatchSearchResult, Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var pendingResult: Result<DiscoveryBatchSearchResult, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func installContinuation(_ continuation: Continuation) {
        let pending = lock.withLock { () -> Result<DiscoveryBatchSearchResult, Error>? in
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !isResolved else { return true }
            operationTask = operation
            timeoutTask = timeout
            return false
        }
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func succeed(_ value: DiscoveryBatchSearchResult) {
        resolve(.success(value), cancelOperation: false)
    }

    func fail(_ error: Error, cancelOperation: Bool) {
        resolve(.failure(error), cancelOperation: cancelOperation)
    }

    private func resolve(
        _ result: Result<DiscoveryBatchSearchResult, Error>,
        cancelOperation: Bool
    ) {
        let captured = lock.withLock { () -> (Continuation?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !isResolved else { return nil }
            isResolved = true
            let continuation = self.continuation
            if continuation == nil { pendingResult = result }
            self.continuation = nil
            let operation = operationTask
            let timeout = timeoutTask
            operationTask = nil
            timeoutTask = nil
            return (continuation, operation, timeout)
        }
        guard let captured else { return }
        if cancelOperation { captured.1?.cancel() }
        captured.2?.cancel()
        captured.0?.resume(with: result)
    }
}

public struct DiscoverySearchCoordinator: SkillDiscoveryProvider, Sendable {
    private struct ProviderSearchTimeout: Error, Sendable {}

    private struct ProviderSearchOutcome: Sendable {
        var index: Int
        var result: DiscoveryBatchSearchResult?
    }

    private let providers: [any SkillDiscoveryProvider]
    private let providerTimeout: Duration

    public init(
        providers: [any SkillDiscoveryProvider],
        providerTimeout: Duration = .seconds(55)
    ) {
        self.providers = providers
        self.providerTimeout = providerTimeout
    }

    public func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let result = try await search(queries: [query], limitPerQuery: limit)
        return .init(
            candidates: result.candidates,
            fetchedAt: result.fetchedAt,
            hasMoreResults: result.saturatedQueryCount > 0,
            failedCandidateVerificationCount: result.failedCandidateVerificationCount,
            deferredCandidateVerificationCount: result.deferredCandidateVerificationCount,
            rateLimitedUntil: result.rateLimitedUntil
        )
    }

    public static func mergeCandidates(
        existing: [DiscoveryCandidate],
        incoming: [DiscoveryCandidate]
    ) -> [DiscoveryCandidate] {
        var accumulated = existing
        for candidate in incoming {
            if let index = accumulated.firstIndex(where: { representsSameSkill($0, candidate) }) {
                accumulated[index] = merge(accumulated[index], candidate)
            } else if accumulated.count < DiscoverySearchLimits.maximumMergedCandidates {
                accumulated.append(candidate)
            }
        }
        return accumulated
    }

    public func search(queries: [String], limitPerQuery: Int = 1_000) async throws -> DiscoveryBatchSearchResult {
        let cleaned = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        var merged: [DiscoveryCandidate] = []
        var originalCandidateIDs = Set<String>()
        var completedSourceCount = 0
        var failedSourceCount = 0
        var failedQueryCount = 0
        var saturatedQueryCount = 0
        var failedCandidateVerificationCount = 0
        var deferredCandidateVerificationCount = 0
        var rateLimitedUntil: Date?
        var unavailableCommunityPlatforms = Set<DiscoveryCommunityPlatform>()
        var unresolvedCommunityMentions: [DiscoveryCommunityMention] = []

        let outcomes = try await withThrowingTaskGroup(of: ProviderSearchOutcome.self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let result = try await Self.search(
                            provider: provider,
                            queries: cleaned,
                            limitPerQuery: limitPerQuery,
                            timeout: providerTimeout
                        )
                        try Task.checkCancellation()
                        return ProviderSearchOutcome(index: index, result: result)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        return ProviderSearchOutcome(index: index, result: nil)
                    }
                }
            }
            var values: [ProviderSearchOutcome] = []
            for try await outcome in group { values.append(outcome) }
            return values.sorted { $0.index < $1.index }
        }

        for outcome in outcomes {
            if let result = outcome.result {
                completedSourceCount += 1
                failedSourceCount += result.failedSourceCount
                failedQueryCount += result.failedQueryCount
                saturatedQueryCount += result.saturatedQueryCount
                failedCandidateVerificationCount += result.failedCandidateVerificationCount
                deferredCandidateVerificationCount += result.deferredCandidateVerificationCount
                if let candidate = result.rateLimitedUntil, candidate > (rateLimitedUntil ?? .distantPast) {
                    rateLimitedUntil = candidate
                }
                unavailableCommunityPlatforms.formUnion(result.unavailableCommunityPlatforms)
                unresolvedCommunityMentions = DiscoveryCommunityMentionSelection.select(
                    unresolvedCommunityMentions + result.unresolvedCommunityMentions,
                    limit: 8
                )
                let sourceOriginalIDs = result.originalQueryCandidateIDs
                for candidate in result.candidates {
                    if let index = merged.firstIndex(where: { Self.representsSameSkill($0, candidate) }) {
                        let wasOriginal = originalCandidateIDs.contains(merged[index].id) || sourceOriginalIDs.contains(candidate.id)
                        merged[index] = Self.merge(merged[index], candidate)
                        if wasOriginal { originalCandidateIDs.insert(merged[index].id) }
                    } else {
                        merged.append(candidate)
                        if sourceOriginalIDs.contains(candidate.id) { originalCandidateIDs.insert(candidate.id) }
                    }
                }
            } else {
                failedSourceCount += 1
            }
        }

        guard completedSourceCount > 0 else { throw SkillDiscoveryError.invalidResponse }
        return .init(
            candidates: merged,
            originalQueryCandidateIDs: originalCandidateIDs,
            failedSourceCount: failedSourceCount,
            failedQueryCount: failedQueryCount,
            saturatedQueryCount: saturatedQueryCount,
            failedCandidateVerificationCount: failedCandidateVerificationCount,
            deferredCandidateVerificationCount: deferredCandidateVerificationCount,
            rateLimitedUntil: rateLimitedUntil,
            unavailableCommunityPlatforms: unavailableCommunityPlatforms,
            unresolvedCommunityMentions: unresolvedCommunityMentions
        )
    }

    private static func search(
        provider: any SkillDiscoveryProvider,
        queries: [String],
        limitPerQuery: Int,
        timeout: Duration
    ) async throws -> DiscoveryBatchSearchResult {
        let race = DiscoveryProviderSearchRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)
                let operation = Task {
                    do {
                        race.succeed(try await provider.search(queries: queries, limitPerQuery: limitPerQuery))
                    } catch {
                        race.fail(error, cancelOperation: false)
                    }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    race.fail(ProviderSearchTimeout(), cancelOperation: true)
                }
                race.installTasks(operation: operation, timeout: timer)
            }
        } onCancel: {
            race.fail(CancellationError(), cancelOperation: true)
        }
    }

    private static func representsSameSkill(_ first: DiscoveryCandidate, _ second: DiscoveryCandidate) -> Bool {
        guard first.repositoryFullName.caseInsensitiveCompare(second.repositoryFullName) == .orderedSame else { return false }
        if let firstPath = normalized(first.skillPath), let secondPath = normalized(second.skillPath) {
            return firstPath == secondPath
        }
        return normalizedName(first.name) == normalizedName(second.name)
    }

    private static func normalized(_ path: String?) -> String? {
        guard let value = path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func merge(_ first: DiscoveryCandidate, _ second: DiscoveryCandidate) -> DiscoveryCandidate {
        var merged = first
        if merged.installCountText == nil { merged.installCountText = second.installCountText }
        if merged.repositoryStarsText == nil { merged.repositoryStarsText = second.repositoryStarsText }
        if merged.skillPath == nil { merged.skillPath = second.skillPath }
        if merged.installCount == nil || (second.installCount ?? -1) > (merged.installCount ?? -1) {
            merged.installCount = second.installCount
        }
        if merged.repositoryStars == nil || (second.repositoryStars ?? -1) > (merged.repositoryStars ?? -1) {
            merged.repositoryStars = second.repositoryStars
            merged.repositoryStarsFetchedAt = second.repositoryStarsFetchedAt
        }
        if (second.repositoryUpdatedAt ?? .distantPast) > (merged.repositoryUpdatedAt ?? .distantPast) {
            merged.repositoryUpdatedAt = second.repositoryUpdatedAt
        }
        merged.evidence.sources.formUnion(second.evidence.sources)
        merged.evidence.communityMentions = DiscoveryCommunityMentionSelection.select(
            merged.evidence.communityMentions + second.evidence.communityMentions
        )
        if first.evidence.repositoryIsPrivate == true || second.evidence.repositoryIsPrivate == true {
            merged.evidence.repositoryIsPrivate = true
        } else if first.evidence.repositoryIsPrivate == false || second.evidence.repositoryIsPrivate == false {
            merged.evidence.repositoryIsPrivate = false
        }
        merged.evidence.repositoryArchived = first.evidence.repositoryArchived || second.evidence.repositoryArchived
        merged.evidence.downloadable = first.evidence.downloadable && second.evidence.downloadable
        merged.evidence.hasBlockingSafetyIssue = first.evidence.hasBlockingSafetyIssue || second.evidence.hasBlockingSafetyIssue
        if first.evidence.catalogTrust == .official || second.evidence.catalogTrust == .official {
            merged.evidence.catalogTrust = .official
        } else {
            merged.evidence.catalogTrust = first.evidence.catalogTrust ?? second.evidence.catalogTrust
        }
        if second.evidence.skillContentVerified {
            merged.evidence.skillContentVerified = true
            merged.evidence.skillSummary = second.evidence.skillSummary ?? merged.evidence.skillSummary
            merged.evidence.skillDocumentExcerpt = second.evidence.skillDocumentExcerpt ?? merged.evidence.skillDocumentExcerpt
            merged.evidence.skillDocumentURL = second.evidence.skillDocumentURL ?? merged.evidence.skillDocumentURL
            merged.evidence.fetchedAt = second.evidence.fetchedAt ?? merged.evidence.fetchedAt
            merged.summary = merged.evidence.skillSummary
            merged.summaryIsRepositoryLevel = false
        } else if merged.evidence.skillSummary == nil {
            merged.evidence.skillSummary = second.evidence.skillSummary
        }
        if merged.evidence.repositorySummary == nil { merged.evidence.repositorySummary = second.evidence.repositorySummary }
        return merged
    }
}

public struct GitHubSkillDiscoveryProvider: SkillDiscoveryProvider, ExactTargetSkillDiscoveryProvider, Sendable {
    private actor RuntimeCache {
        private struct CandidateEntry: Sendable { var value: DiscoveryCandidate; var expiresAt: Date }
        private struct RepositoryEntry: Sendable { var value: RepositoryResponse; var expiresAt: Date }
        private var candidates: [String: CandidateEntry] = [:]
        private var repositories: [String: RepositoryEntry] = [:]
        private var recentVerificationAttempts: [String: Date] = [:]

        func candidate(id: String, now: Date = Date()) -> DiscoveryCandidate? {
            guard let entry = candidates[id], entry.expiresAt > now else {
                candidates.removeValue(forKey: id)
                return nil
            }
            return entry.value
        }

        func insert(candidate: DiscoveryCandidate, now: Date = Date()) {
            candidates[candidate.id] = .init(value: candidate, expiresAt: now.addingTimeInterval(24 * 60 * 60))
            trimCandidates()
        }

        func repository(name: String, now: Date = Date()) -> RepositoryResponse? {
            let key = name.lowercased()
            guard let entry = repositories[key], entry.expiresAt > now else {
                repositories.removeValue(forKey: key)
                return nil
            }
            return entry.value
        }

        func insert(repository: RepositoryResponse, now: Date = Date()) {
            repositories[repository.fullName.lowercased()] = .init(
                value: repository,
                expiresAt: now.addingTimeInterval(6 * 60 * 60)
            )
            while repositories.count > 128,
                  let oldest = repositories.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
            { repositories.removeValue(forKey: oldest) }
        }

        func claimCandidateIDs(_ ids: [String], maximum: Int, now: Date = Date()) -> Set<String> {
            recentVerificationAttempts = recentVerificationAttempts.filter { now.timeIntervalSince($0.value) < 10 * 60 }
            var claimed = Set<String>()
            for id in ids where recentVerificationAttempts[id] == nil && claimed.count < maximum {
                recentVerificationAttempts[id] = now
                claimed.insert(id)
            }
            return claimed
        }

        private func trimCandidates() {
            while candidates.count > 256,
                  let oldest = candidates.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
            { candidates.removeValue(forKey: oldest) }
        }
    }

    private struct SearchItemsResult {
        var items: [SearchItem]
        var hasMore: Bool
    }

    private struct SearchResponse: Decodable {
        var totalCount: Int
        var incompleteResults: Bool?
        var items: [SearchItem]

        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case incompleteResults = "incomplete_results"
            case items
        }
    }

    private struct SearchItem: Decodable {
        var path: String
        var url: URL
        var repository: RepositoryReference
    }

    private struct RepositoryReference: Decodable { var fullName: String; enum CodingKeys: String, CodingKey { case fullName = "full_name" } }
    private struct ContentResponse: Decodable { var content: String?; var downloadURL: URL?; enum CodingKeys: String, CodingKey { case content; case downloadURL = "download_url" } }
    private struct RepositoryResponse: Decodable, Sendable {
        var fullName: String
        var description: String?
        var stars: Int
        var updatedAt: Date?
        var archived: Bool
        var disabled: Bool
        var isPrivate: Bool?

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case description
            case stars = "stargazers_count"
            case updatedAt = "updated_at"
            case archived, disabled
            case isPrivate = "private"
        }
    }

    private struct VerificationOutcome: Sendable {
        var candidates: [DiscoveryCandidate]
        var failedCount: Int
        var deferredCount: Int
    }

    private let session: URLSession
    private let tokenProvider: any GitHubAccessTokenProvider
    private let runtime = RuntimeCache()
    private let rateLimitGate: GitHubDiscoveryRateLimitGate

    public init(
        session: URLSession = .shared,
        tokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider(),
        rateLimitGate: GitHubDiscoveryRateLimitGate = GitHubDiscoveryRateLimitGate()
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.rateLimitGate = rateLimitGate
    }

    public func search(query: String, limit: Int = 1_000) async throws -> DiscoverySearchResult {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        let token = try? await tokenProvider.accessToken()
        let result = try await searchItems(query: clean, limit: limit, token: token)
        let verification = await verifiedCandidates(
            for: result.items,
            token: token,
            maximumNew: DiscoverySearchLimits.githubVerificationLimit(for: limit)
        )
        return .init(
            candidates: verification.candidates,
            hasMoreResults: result.hasMore || verification.deferredCount > 0,
            failedCandidateVerificationCount: verification.failedCount,
            deferredCandidateVerificationCount: verification.deferredCount,
            rateLimitedUntil: await rateLimitGate.activeRetryDate()
        )
    }

    public func searchExact(
        targets: [DiscoveryTarget],
        limit: Int
    ) async throws -> DiscoveryBatchSearchResult {
        let repositoryTargets = targets.filter {
            $0.kind == .repository && $0.repositoryFullName != nil
        }
        guard !repositoryTargets.isEmpty else {
            return try await search(
                queries: targets.map { $0.kind == .repository ? "repo:\($0.repositoryFullName ?? $0.value)" : $0.value },
                limitPerQuery: limit
            )
        }

        var candidates: [DiscoveryCandidate] = []
        var failedCount = 0
        var rateLimitedUntil: Date?
        var fallbackResults: [DiscoveryBatchSearchResult] = []
        for target in repositoryTargets.prefix(max(1, min(limit, 8))) {
            try Task.checkCancellation()
            let repository = target.repositoryFullName ?? target.value
            let folder = target.skillPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            let skillFile = folder.lowercased().hasSuffix("skill.md")
                ? folder
                : [folder, "SKILL.md"].filter { !$0.isEmpty }.joined(separator: "/")
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.github.com"
            components.path = "/repos/\(repository)/contents/\(skillFile)"
            guard let url = components.url else {
                failedCount += 1
                continue
            }
            let item = SearchItem(
                path: skillFile,
                url: url,
                repository: .init(fullName: repository)
            )
            if let candidate = try await publicRawCandidate(item, revision: target.revision ?? "HEAD") {
                candidates.append(candidate)
                continue
            }
            let token = try? await tokenProvider.accessToken()
            do {
                if let revision = target.revision {
                    components.queryItems = [.init(name: "ref", value: revision)]
                }
                let contentData = try await githubData(components.url ?? url, token: token)
                let metadata = await repositoryEvidence(for: [item], token: token)[repository.lowercased()]
                guard let metadata,
                      let candidate = Self.makeCandidate(item, contentData: contentData, repository: metadata)
                else {
                    failedCount += 1
                    continue
                }
                await runtime.insert(candidate: candidate)
                candidates.append(candidate)
            } catch is CancellationError {
                throw CancellationError()
            } catch let SkillDiscoveryError.rateLimited(retryAt) {
                rateLimitedUntil = retryAt
                break
            } catch {
                if target.skillPath == nil {
                    let fallback = try await search(queries: ["repo:\(repository)"], limitPerQuery: limit)
                    candidates.append(contentsOf: fallback.candidates)
                    fallbackResults.append(fallback)
                } else {
                    failedCount += 1
                }
            }
        }
        let ids = Set(candidates.map(\.id))
        let activeRateLimit = await rateLimitGate.activeRetryDate()
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: ids,
            failedQueryCount: fallbackResults.reduce(0) { $0 + $1.failedQueryCount },
            saturatedQueryCount: fallbackResults.reduce(0) { $0 + $1.saturatedQueryCount },
            failedCandidateVerificationCount: failedCount + fallbackResults.reduce(0) { $0 + $1.failedCandidateVerificationCount },
            deferredCandidateVerificationCount: fallbackResults.reduce(0) { $0 + $1.deferredCandidateVerificationCount },
            rateLimitedUntil: rateLimitedUntil ?? (candidates.isEmpty ? activeRateLimit : fallbackResults.compactMap(\.rateLimitedUntil).max())
        )
    }

    /// Named repositories can be found without GitHub code-search login. One
    /// page per name, at most five exact repository names, three raw paths each.
    /// Search results locate evidence; they never establish an installable Skill.
    public func searchNamedRepositories(names: [String], limit: Int) async throws -> DiscoveryBatchSearchResult {
        struct Repositories: Decodable {
            var total_count: Int
            var incomplete_results: Bool?
            var items: [RepositoryResponse]
        }
        func normalize(_ value: String) -> String {
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        var candidates: [DiscoveryCandidate] = []
        var failed = 0
        var deferred = 0
        var saturated = 0
        for name in names.prefix(1) {
            guard name.count <= 64,
                  name.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} _.\-]*$"#, options: .regularExpression) != nil
            else { throw SkillDiscoveryError.invalidResponse }
            var components = URLComponents(string: "https://api.github.com/search/repositories")!
            components.queryItems = [.init(name: "q", value: "\"\(name)\" in:name fork:false"), .init(name: "per_page", value: "100")]
            let data = try await githubData(components.url!, token: nil)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(Repositories.self, from: data)
            if response.total_count > response.items.count || response.incomplete_results == true { saturated += 1 }
            let exact = response.items.filter {
                !$0.archived && !$0.disabled && $0.isPrivate != true
                    && $0.fullName.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                    && normalize($0.fullName.split(separator: "/").last.map(String.init) ?? "") == normalize(name)
            }
            let maximum = min(max(limit, 1), 5)
            deferred += max(0, exact.count - maximum)
            for repository in exact.prefix(maximum) {
                try Task.checkCancellation()
                await runtime.insert(repository: repository)
                let leaf = repository.fullName.split(separator: "/").last.map(String.init)!
                var found = false
                for path in ["SKILL.md", "\(leaf)/SKILL.md", "skills/\(leaf)/SKILL.md"] {
                    let item = SearchItem(path: path,
                        url: URL(string: "https://api.github.com/repos/\(repository.fullName)/contents/\(path)")!,
                        repository: .init(fullName: repository.fullName))
                    if let candidate = try await publicRawCandidate(item, revision: "HEAD") {
                        candidates.append(candidate)
                        found = true
                        break
                    }
                }
                if !found { failed += 1 }
            }
        }
        return .init(candidates: candidates, originalQueryCandidateIDs: Set(candidates.map(\.id)),
            saturatedQueryCount: saturated, failedCandidateVerificationCount: failed,
            deferredCandidateVerificationCount: deferred)
    }

    /// An exact public document does not require repository/code-search quota.
    /// Only this fixed GitHub host is used, with no token or cookies attached.
    private func publicRawCandidate(_ item: SearchItem, revision: String) async throws -> DiscoveryCandidate? {
        let components = item.repository.fullName.split(separator: "/").map(String.init)
            + [revision] + item.path.split(separator: "/").map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { return nil }
        var url = URL(string: "https://raw.githubusercontent.com")!
        for component in components { url.appendPathComponent(component) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await DiscoveryNetworkResponseLoader.data(
                for: request, session: session, maximumBytes: 512 * 1_024
            )
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let payload = try JSONSerialization.data(withJSONObject: [
                "content": data.base64EncodedString(), "download_url": url.absoluteString,
            ])
            let repository = await runtime.repository(name: item.repository.fullName)
            guard var candidate = Self.makeCandidate(item, contentData: payload, repository: repository) else { return nil }
            candidate.evidence.repositoryIsPrivate = false
            await runtime.insert(candidate: candidate)
            return candidate
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func searchItems(query: String, limit: Int, token: String?) async throws -> SearchItemsResult {
        guard let token, !token.isEmpty else { throw SkillDiscoveryError.requestFailed(401) }
        let sourceLimit = min(max(limit, 1), DiscoverySearchLimits.maximumCandidatesPerProvider)
        var items: [SearchItem] = []
        var page = 1
        var totalCount = 0
        var incompleteResults = false

        while items.count < sourceLimit {
            var components = URLComponents(string: "https://api.github.com/search/code")!
            components.queryItems = [
                .init(name: "q", value: "filename:SKILL.md \(query)"),
                .init(name: "per_page", value: String(min(100, sourceLimit - items.count))),
                .init(name: "page", value: String(page)),
            ]
            guard let url = components.url else { throw SkillDiscoveryError.invalidResponse }
            let data = try await githubData(url, token: token)
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            totalCount = max(totalCount, decoded.totalCount)
            incompleteResults = incompleteResults || decoded.incompleteResults == true
            let remaining = sourceLimit - items.count
            items.append(contentsOf: decoded.items.prefix(remaining))
            if decoded.items.isEmpty || items.count >= decoded.totalCount || decoded.items.count < 100 { break }
            page += 1
        }
        return .init(items: items, hasMore: totalCount > items.count || incompleteResults)
    }

    private func verifiedCandidates(
        for items: [SearchItem],
        token: String?,
        maximumNew: Int
    ) async -> VerificationOutcome {
        var indexedCandidates: [(Int, DiscoveryCandidate)] = []
        var uncachedItems: [(Int, SearchItem)] = []
        for (index, item) in items.enumerated() {
            if let candidate = await runtime.candidate(id: Self.candidateID(for: item)) {
                indexedCandidates.append((index, candidate))
            } else {
                uncachedItems.append((index, item))
            }
        }
        let cachedCount = indexedCandidates.count
        let claimedIDs = await runtime.claimCandidateIDs(
            uncachedItems.map { Self.candidateID(for: $0.1) },
            maximum: maximumNew
        )
        let claimedItems = uncachedItems.filter { claimedIDs.contains(Self.candidateID(for: $0.1)) }
        let repositories = await repositoryEvidence(for: claimedItems.map(\.1), token: token)
        let qualifiedItems = claimedItems.filter { repositories[$0.1.repository.fullName.lowercased()] != nil }

        for batchStart in stride(from: 0, to: qualifiedItems.count, by: 4) {
            if await rateLimitGate.activeRetryDate(for: .core) != nil { break }
            let batchEnd = min(qualifiedItems.count, batchStart + 4)
            let batch = Array(qualifiedItems[batchStart..<batchEnd])
            let values = await withTaskGroup(of: (Int, DiscoveryCandidate?).self, returning: [(Int, DiscoveryCandidate)].self) { group in
                for (index, item) in batch {
                    let repository = repositories[item.repository.fullName.lowercased()]
                    group.addTask { (index, await self.makeCandidate(item, repository: repository, token: token)) }
                }
                var collected: [(Int, DiscoveryCandidate)] = []
                for await (index, candidate) in group { if let candidate { collected.append((index, candidate)) } }
                return collected
            }
            for (index, candidate) in values {
                await runtime.insert(candidate: candidate)
                indexedCandidates.append((index, candidate))
            }
        }
        let candidates = indexedCandidates.sorted { $0.0 < $1.0 }.map(\.1)
        let newlyVerifiedCount = max(0, candidates.count - cachedCount)
        return .init(
            candidates: candidates,
            failedCount: max(0, claimedItems.count - newlyVerifiedCount),
            deferredCount: max(0, uncachedItems.count - claimedItems.count)
        )
    }

    public func search(queries: [String], limitPerQuery: Int = 1_000) async throws -> DiscoveryBatchSearchResult {
        let token = try? await tokenProvider.accessToken()
        var mergedItems: [String: SearchItem] = [:]
        var itemOrder: [String] = []
        var originalItemIDs = Set<String>()
        var failedQueryCount = 0
        var saturatedQueryCount = 0
        var completedQueryCount = 0
        var firstError: Error?
        var rateLimitedUntil: Date?

        for (queryIndex, query) in queries.enumerated() {
            try Task.checkCancellation()
            do {
                let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let searchResult = try await searchItems(query: clean, limit: limitPerQuery, token: token)
                let items = searchResult.items
                completedQueryCount += 1
                if searchResult.hasMore { saturatedQueryCount += 1 }
                for item in items {
                    let key = Self.deduplicationKey(for: item)
                    if mergedItems[key] == nil {
                        itemOrder.append(key)
                        mergedItems[key] = item
                    }
                    if queryIndex == 0 { originalItemIDs.insert(Self.candidateID(for: item)) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let SkillDiscoveryError.rateLimited(retryAt) {
                rateLimitedUntil = retryAt ?? Date().addingTimeInterval(60)
                break
            } catch {
                failedQueryCount += 1
                if firstError == nil { firstError = error }
            }
        }

        guard completedQueryCount > 0 || rateLimitedUntil != nil else { throw firstError ?? SkillDiscoveryError.invalidResponse }
        let allOrderedItems = itemOrder.compactMap { mergedItems[$0] }
        if allOrderedItems.count > DiscoverySearchLimits.maximumCandidatesPerProvider {
            saturatedQueryCount += 1
        }
        let orderedItems = Array(allOrderedItems.prefix(DiscoverySearchLimits.maximumCandidatesPerProvider))
        let verification = await verifiedCandidates(
            for: orderedItems,
            token: token,
            maximumNew: DiscoverySearchLimits.githubVerificationLimit(for: limitPerQuery)
        )
        rateLimitedUntil = await rateLimitGate.activeRetryDate() ?? rateLimitedUntil
        try Task.checkCancellation()
        let originalIDs = Set(verification.candidates.compactMap { originalItemIDs.contains($0.id) ? $0.id : nil })
        return .init(
            candidates: verification.candidates,
            originalQueryCandidateIDs: originalIDs,
            failedQueryCount: failedQueryCount,
            saturatedQueryCount: saturatedQueryCount + (verification.deferredCount > 0 || rateLimitedUntil != nil ? 1 : 0),
            failedCandidateVerificationCount: verification.failedCount,
            deferredCandidateVerificationCount: verification.deferredCount,
            rateLimitedUntil: rateLimitedUntil
        )
    }

    private static func deduplicationKey(for item: SearchItem) -> String {
        let parentPath = item.path.split(separator: "/").dropLast().joined(separator: "/")
        return deduplicationKey(repository: item.repository.fullName, path: parentPath.isEmpty ? nil : parentPath, name: item.path)
    }

    private static func deduplicationKey(repository: String, path: String?, name: String) -> String {
        let normalizedPath = path?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identity = normalizedPath?.isEmpty == false ? normalizedPath! : name
        return "\(repository.lowercased())|\(identity.lowercased())"
    }

    private static func candidateID(for item: SearchItem) -> String {
        "github/\(item.repository.fullName)/\(item.path)"
    }

    private func makeCandidate(_ item: SearchItem, repository: RepositoryResponse?, token: String?) async -> DiscoveryCandidate? {
        guard item.path == "SKILL.md" || item.path.hasSuffix("/SKILL.md"),
              let contentData = try? await githubData(item.url, token: token)
        else { return nil }
        return Self.makeCandidate(item, contentData: contentData, repository: repository)
    }

    private static func makeCandidate(
        _ item: SearchItem,
        contentData: Data,
        repository: RepositoryResponse?
    ) -> DiscoveryCandidate? {
        guard item.path == "SKILL.md" || item.path.hasSuffix("/SKILL.md"),
              let content = try? JSONDecoder().decode(ContentResponse.self, from: contentData),
              let encoded = content.content,
              let markdownData = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")),
              let markdown = String(data: markdownData, encoding: .utf8),
              let metadata = Self.frontmatter(in: markdown),
              Self.nameMatchesPath(metadata.name, path: item.path)
        else { return nil }

        guard repository?.archived != true, repository?.disabled != true else { return nil }
        let parentPath = item.path.split(separator: "/").dropLast().joined(separator: "/")
        return DiscoveryCandidate(
            id: Self.candidateID(for: item),
            name: metadata.name,
            summary: metadata.description,
            repositoryFullName: item.repository.fullName,
            skillPath: parentPath.isEmpty ? nil : parentPath,
            repositoryStars: repository?.stars,
            repositoryStarsFetchedAt: repository == nil ? nil : Date(),
            repositoryUpdatedAt: repository?.updatedAt,
            evidence: .init(
                skillSummary: metadata.description,
                skillDocumentExcerpt: String(markdown.prefix(DiscoveryEvaluationLimits.maximumPersistedSkillCharacters)),
                repositorySummary: repository?.description,
                skillContentVerified: true,
                repositoryIsPrivate: repository?.isPrivate,
                skillDocumentURL: content.downloadURL ?? item.url,
                fetchedAt: Date(),
                sources: [.github, .skillDocument],
                repositoryArchived: false,
                downloadable: true
            )
        )
    }

    private func repositoryEvidence(for items: [SearchItem], token: String?) async -> [String: RepositoryResponse] {
        var seen = Set<String>()
        let repositories = items.compactMap { item -> String? in
            let key = item.repository.fullName.lowercased()
            return seen.insert(key).inserted ? item.repository.fullName : nil
        }
        var values: [String: RepositoryResponse] = [:]
        var missing: [String] = []
        for repository in repositories {
            if let cached = await runtime.repository(name: repository) {
                values[cached.fullName.lowercased()] = cached
            } else {
                missing.append(repository)
            }
        }
        for batchStart in stride(from: 0, to: missing.count, by: 4) {
            if await rateLimitGate.activeRetryDate(for: .core) != nil { break }
            let batchEnd = min(missing.count, batchStart + 4)
            let batch = Array(missing[batchStart..<batchEnd])
            let metadata = await withTaskGroup(of: RepositoryResponse?.self, returning: [RepositoryResponse].self) { group in
                for repository in batch {
                    group.addTask { await self.repositoryMetadata(repository, token: token) }
                }
                var collected: [RepositoryResponse] = []
                for await repository in group { if let repository { collected.append(repository) } }
                return collected
            }
            for repository in metadata {
                values[repository.fullName.lowercased()] = repository
                await runtime.insert(repository: repository)
            }
        }
        return values
    }

    private func repositoryMetadata(_ repository: String, token: String?) async -> RepositoryResponse? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)"),
              let data = try? await githubData(url, token: token)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RepositoryResponse.self, from: data)
    }

    private func githubData(_ url: URL, token: String?) async throws -> Data {
        if let retryAt = await rateLimitGate.activeRetryDate(for: GitHubDiscoveryRateLimitGate.resource(for: url)) {
            throw SkillDiscoveryError.rateLimited(retryAt)
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await DiscoveryNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 2 * 1_024 * 1_024
            )
        } catch is BoundedNetworkResponseError {
            throw SkillDiscoveryError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw SkillDiscoveryError.invalidResponse }
        let retryAt = await rateLimitGate.observeDiscoveryResponse(http, anonymous: token == nil)
        if http.statusCode == 403 || http.statusCode == 429 {
            throw SkillDiscoveryError.rateLimited(retryAt)
        }
        guard (200...299).contains(http.statusCode) else { throw SkillDiscoveryError.requestFailed(http.statusCode) }
        return data
    }

    private static func frontmatter(in markdown: String) -> (name: String, description: String)? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return nil }
        let frontmatter = lines[1..<closing]
        func value(_ key: String) -> String? {
            guard let line = frontmatter.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) else { return nil }
            let raw = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let clean = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            return clean.isEmpty ? nil : clean
        }
        guard let name = value("name"), value("description") != nil else { return nil }
        let metadata = SkillMetadataParser.parse(text: markdown, fallbackName: name)
        guard metadata.description != "未提供描述" else { return nil }
        return (name, metadata.description)
    }

    private static func nameMatchesPath(_ name: String, path: String) -> Bool {
        if path == "SKILL.md" { return true }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        func normalize(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "_", with: "-") }
        return normalize(parent) == normalize(name)
    }
}
