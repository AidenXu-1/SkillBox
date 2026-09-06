import Foundation

public protocol ExactTargetSkillDiscoveryProvider: Sendable {
    func searchExact(targets: [DiscoveryTarget], limit: Int) async throws -> DiscoveryBatchSearchResult
}

public enum DiscoveryRouteOutcome: String, Codable, Hashable, Sendable {
    case exactFound
    case exactAmbiguous
    case exactNotFound
    case communityRecommendations
    case hybridResults
}

public struct DiscoveryRoutedSearchResult: Sendable {
    public var batch: DiscoveryBatchSearchResult
    public var route: DiscoverySearchRoute
    public var outcome: DiscoveryRouteOutcome

    public init(
        batch: DiscoveryBatchSearchResult,
        route: DiscoverySearchRoute,
        outcome: DiscoveryRouteOutcome
    ) {
        self.batch = batch
        self.route = route
        self.outcome = outcome
    }
}

/// Keeps the user's intent attached to the whole retrieval path. Exact lookups
/// never call community discovery, while scenario discovery only returns Skills
/// whose SKILL.md was read. Community evidence strengthens those results but a
/// media outage or an unnamed recommendation must not erase a verified answer.
public struct RoutedSkillDiscoveryProvider: Sendable {
    private let exactProvider: any SkillDiscoveryProvider
    private let exactNameProvider: (any SkillDiscoveryProvider)?
    private let scenarioProvider: any SkillDiscoveryProvider
    private let hybridProvider: any SkillDiscoveryProvider
    private let exactTargetProvider: (any ExactTargetSkillDiscoveryProvider)?
    private let requestGate: GitHubDiscoveryRateLimitGate

    public init(
        exactProvider: any SkillDiscoveryProvider,
        scenarioProvider: any SkillDiscoveryProvider,
        hybridProvider: any SkillDiscoveryProvider,
        exactTargetProvider: (any ExactTargetSkillDiscoveryProvider)? = nil,
        exactNameProvider: (any SkillDiscoveryProvider)? = nil,
        requestGate: GitHubDiscoveryRateLimitGate = GitHubDiscoveryRateLimitGate()
    ) {
        self.exactProvider = exactProvider
        self.scenarioProvider = scenarioProvider
        self.hybridProvider = hybridProvider
        self.exactTargetProvider = exactTargetProvider
        self.exactNameProvider = exactNameProvider
        self.requestGate = requestGate
    }

    public func search(
        plan: DiscoveryPlan,
        limitPerQuery: Int
    ) async throws -> DiscoveryRoutedSearchResult {
        let context = DiscoveryRequestContext(gate: requestGate)
        do {
            var result = try await DiscoveryNetworkResponseLoader.$context.withValue(context) {
                try await searchWithinBudget(plan: plan, limitPerQuery: limitPerQuery)
            }
            result.batch.requestUsage = await context.usage()
            await context.finish()
            return result
        } catch {
            await context.finish()
            throw error
        }
    }

    private func searchWithinBudget(plan: DiscoveryPlan, limitPerQuery: Int) async throws -> DiscoveryRoutedSearchResult {
        switch plan.intent.route {
        case .exact:
            let queries = exactQueries(for: plan.intent.targets, fallback: plan.queries)
            let hasDirectRepositoryPath = plan.intent.targets.contains {
                $0.kind == .repository
            }
            let raw: DiscoveryBatchSearchResult
            if hasDirectRepositoryPath, let exactTargetProvider {
                let bounded = DiscoverySearchCoordinator(providers: [
                    DirectRepositoryDiscovery(provider: exactTargetProvider, targets: plan.intent.targets),
                ], providerTimeout: .seconds(20))
                raw = try await bounded.search(queries: queries, limitPerQuery: limitPerQuery)
            } else {
                raw = try await (exactNameProvider ?? exactProvider).search(queries: queries, limitPerQuery: limitPerQuery)
            }
            let filtered = Self.filterExact(raw, targets: plan.intent.targets)
            let outcome: DiscoveryRouteOutcome
            switch filtered.candidates.count {
            case 0: outcome = .exactNotFound
            case 1: outcome = .exactFound
            default: outcome = .exactAmbiguous
            }
            return .init(batch: filtered, route: .exact, outcome: outcome)

        case .scenario:
            let raw = try await scenarioProvider.search(queries: plan.queries, limitPerQuery: limitPerQuery)
            let verified = raw.candidates.filter(\.evidence.skillContentVerified)
            return .init(
                batch: Self.replacingCandidates(in: raw, with: verified),
                route: .scenario,
                outcome: .communityRecommendations
            )

        case .hybrid:
            let authors = plan.intent.targets.filter { $0.kind == .author }
            let owners = authors.compactMap { DiscoveryAuthorIdentity.owner(for: $0.value) }
            if !authors.isEmpty, owners.count == authors.count {
                let raw = try await exactProvider.search(queries: owners.map { "user:\($0)" }, limitPerQuery: limitPerQuery)
                let matching = raw.candidates.filter { candidate in
                    candidate.evidence.skillContentVerified && owners.contains {
                        DiscoveryAuthorIdentity.matches(repository: candidate.repositoryFullName, owner: $0)
                    }
                }
                let scoped = Self.replacingCandidates(in: raw, with: matching)
                let filtered = plan.intent.targets.contains { $0.kind != .author }
                    ? Self.filterExact(scoped, targets: plan.intent.targets) : scoped
                return .init(batch: filtered, route: .hybrid, outcome: .hybridResults)
            }
            let queries = hybridQueries(for: plan.intent.targets, fallback: plan.queries)
            let raw = try await hybridProvider.search(queries: queries, limitPerQuery: limitPerQuery)
            let hasIdentityTarget = plan.intent.targets.contains { $0.kind != .author }
            let filtered = hasIdentityTarget ? Self.filterExact(raw, targets: plan.intent.targets) : raw
            return .init(batch: filtered, route: .hybrid, outcome: .hybridResults)
        }
    }

    private func exactQueries(for targets: [DiscoveryTarget], fallback: [String]) -> [String] {
        let targetQueries = targets.compactMap { target in
            switch target.kind {
            case .skillName: target.value
            case .repository: "repo:\(target.repositoryFullName ?? target.value)"
            case .author: nil
            }
        }
        return unique(targetQueries.isEmpty ? fallback : targetQueries)
    }

    private func hybridQueries(for targets: [DiscoveryTarget], fallback: [String]) -> [String] {
        unique(targets.map { target in
            switch target.kind {
            case .repository: "repo:\(target.repositoryFullName ?? target.value)"
            case .skillName, .author: target.value
            }
        } + fallback)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let cleaned = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !cleaned.isEmpty && seen.insert(cleaned.lowercased()).inserted
        }
    }

    private static func filterExact(
        _ result: DiscoveryBatchSearchResult,
        targets: [DiscoveryTarget]
    ) -> DiscoveryBatchSearchResult {
        let authors = targets.filter { $0.kind == .author }
        let owners = authors.compactMap { DiscoveryAuthorIdentity.owner(for: $0.value) }
        let filtered = result.candidates.filter { candidate in
            guard candidate.evidence.skillContentVerified else { return false }
            if !authors.isEmpty {
                guard owners.count == authors.count,
                      owners.contains(where: { DiscoveryAuthorIdentity.matches(repository: candidate.repositoryFullName, owner: $0) })
                else { return false }
            }
            return targets.contains { matches($0, candidate: candidate) }
        }
        return replacingCandidates(in: result, with: filtered)
    }

    static func matches(_ target: DiscoveryTarget, candidate: DiscoveryCandidate) -> Bool {
        switch target.kind {
        case .skillName:
            let targetName = normalize(target.value)
            let candidateNames = [candidate.name, candidate.skillPath?.split(separator: "/").last.map(String.init)]
                .compactMap { $0 }
                .map(normalize)
            // A verified root Skill can be addressed by its repository's name.
            // A collection repository must not grant that alias to its children.
            let rootRepositoryName = normalizedPath(candidate.skillPath) == nil
                ? candidate.repositoryFullName.split(separator: "/").last.map(String.init).map(normalize)
                : nil
            return candidateNames.contains(targetName) || rootRepositoryName == targetName

        case .repository:
            let repository = target.repositoryFullName ?? target.value
            guard repository.caseInsensitiveCompare(candidate.repositoryFullName) == .orderedSame else { return false }
            if target.value != repository, normalize(target.value) != normalize(candidate.name) { return false }
            if target.skillPath == "" { return normalizedPath(candidate.skillPath) == nil }
            guard let targetPath = normalizedPath(target.skillPath) else { return true }
            guard let candidatePath = normalizedPath(candidate.skillPath) else { return false }
            return candidatePath == targetPath
                || candidatePath.hasSuffix("/\(targetPath)")
                || targetPath.hasSuffix("/\(candidatePath)")

        case .author:
            return false
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard var path = value?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
              !path.isEmpty
        else { return nil }
        if path.hasSuffix("/skill.md") { path = String(path.dropLast("/skill.md".count)) }
        return path
    }

    private static func replacingCandidates(
        in result: DiscoveryBatchSearchResult,
        with candidates: [DiscoveryCandidate]
    ) -> DiscoveryBatchSearchResult {
        let ids = Set(candidates.map(\.id))
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: result.originalQueryCandidateIDs.intersection(ids),
            fetchedAt: result.fetchedAt,
            failedSourceCount: result.failedSourceCount,
            failedQueryCount: result.failedQueryCount,
            saturatedQueryCount: result.saturatedQueryCount,
            failedCandidateVerificationCount: result.failedCandidateVerificationCount,
            deferredCandidateVerificationCount: result.deferredCandidateVerificationCount,
            rateLimitedUntil: result.rateLimitedUntil,
            unavailableCommunityPlatforms: result.unavailableCommunityPlatforms,
            unresolvedCommunityMentions: result.unresolvedCommunityMentions
        )
    }
}

private struct DirectRepositoryDiscovery: SkillDiscoveryProvider {
    let provider: any ExactTargetSkillDiscoveryProvider
    let targets: [DiscoveryTarget]
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let batch = try await search(queries: [query], limitPerQuery: limit)
        return .init(candidates: batch.candidates, hasMoreResults: !batch.isExhaustive)
    }
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        try await provider.searchExact(targets: targets, limit: limitPerQuery)
    }
}
