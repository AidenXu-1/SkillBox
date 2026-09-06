import Foundation

/// The app and integration tests use this same composition.
public enum DefaultSkillDiscovery {
    public static func make(
        tokenProvider: any GitHubAccessTokenProvider,
        session: URLSession = .shared,
        mediaSources: [any CommunityMediaSearchSource] = DefaultCommunityMediaSearchSources.make(),
        catalogEntries: [TrustedSkillCatalogEntry]? = nil
    ) -> RoutedSkillDiscoveryProvider {
        let gate = GitHubDiscoveryRateLimitGate()
        let github = GitHubSkillDiscoveryProvider(session: session, tokenProvider: tokenProvider, rateLimitGate: gate)
        let skills = SkillsShDiscoveryProvider(session: session, repositoryTokenProvider: tokenProvider, rateLimitGate: gate)
        let namedSkills = SkillsShDiscoveryProvider(session: session, repositoryTokenProvider: tokenProvider, rateLimitGate: gate, exactNamesOnly: true)
        let catalog = TrustedSkillCatalogDiscoveryProvider(session: session, tokenProvider: tokenProvider, entries: catalogEntries)
        let mediaGitHub = GitHubSkillDiscoveryProvider(session: session, tokenProvider: tokenProvider, rateLimitGate: gate)
        let mediaSkills = SkillsShDiscoveryProvider(session: session, repositoryTokenProvider: tokenProvider, rateLimitGate: gate)
        let mediaCatalog = TrustedSkillCatalogDiscoveryProvider(session: session, tokenProvider: tokenProvider, entries: catalogEntries)
        let mediaResolver = DiscoveryFallbackResolver(providers: [mediaCatalog, mediaSkills, mediaGitHub])
        let scenario = DiscoverySearchCoordinator(providers: [
            MultiPlatformCommunitySkillDiscoveryProvider(sources: mediaSources, repositoryResolver: mediaResolver, sourceTimeout: .seconds(18)),
            CommunityMediaSkillDiscoveryProvider(session: session, repositoryResolver: mediaResolver),
        ], providerTimeout: .seconds(48))
        let taskCatalog = CuratedTaskDirectoryDiscovery(session: session, entries: catalogEntries)
        let general = DiscoverySearchCoordinator(providers: [scenario, catalog, skills, github, taskCatalog])
        return RoutedSkillDiscoveryProvider(
            exactProvider: DiscoverySearchCoordinator(providers: [catalog, skills, github]),
            scenarioProvider: general, hybridProvider: general,
            exactTargetProvider: github,
            exactNameProvider: DiscoverySearchCoordinator(providers: [catalog, namedSkills, NamedRepositoryDiscovery(provider: github)], providerTimeout: .seconds(20)),
            requestGate: gate
        )
    }
}

private struct NamedRepositoryDiscovery: SkillDiscoveryProvider {
    let provider: GitHubSkillDiscoveryProvider
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let result = try await search(queries: [query], limitPerQuery: limit)
        return .init(candidates: result.candidates, hasMoreResults: !result.isExhaustive)
    }
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        try await provider.searchNamedRepositories(names: queries, limit: limitPerQuery)
    }
}

/// A small independently completed source keeps known task documents usable
/// when the directory's search API is down but its public detail pages work.
private struct CuratedTaskDirectoryDiscovery: SkillDiscoveryProvider {
    let session: URLSession
    let entries: [TrustedSkillCatalogEntry]
    let directory: SkillsShDiscoveryProvider

    init(session: URLSession, entries: [TrustedSkillCatalogEntry]?) {
        self.session = session
        self.entries = (entries ?? TrustedSkillCatalogDiscoveryProvider.taskEntries()).filter { $0.searchAliases?.isEmpty == false }
        directory = SkillsShDiscoveryProvider(session: session)
    }

    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let result = try await search(queries: [query], limitPerQuery: limit)
        return .init(candidates: result.candidates)
    }

    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        let context = queries.joined(separator: " ").lowercased().replacingOccurrences(of: " ", with: "")
        let selected = Array(entries.filter { entry in
            entry.searchAliases?.contains { context.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) } == true
        }.prefix(4))
        guard !selected.isEmpty else { return .init(candidates: [], originalQueryCandidateIDs: []) }
        let catalog = TrustedSkillCatalogDiscoveryProvider(session: session, entries: selected)
        var result = try await catalog.search(queries: selected.map(\.name), limitPerQuery: 4)
        result.candidates = await directory.enrichKnownTaskCandidates(result.candidates)
        return result
    }
}
