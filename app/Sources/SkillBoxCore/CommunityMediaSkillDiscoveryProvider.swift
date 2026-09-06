import Foundation

public struct CommunityMediaSkillDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private struct SearchResponse: Decodable {
        var hits: [Hit]
        var nbPages: Int
        var page: Int

        enum CodingKeys: String, CodingKey {
            case hits, nbPages, page
        }
    }

    private struct Hit: Decodable, Sendable {
        var objectID: String
        var author: String?
        var title: String?
        var url: URL?
        var storyText: String?
        var points: Int?
        var commentCount: Int?
        var createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case objectID, author, title, url, points
            case storyText = "story_text"
            case commentCount = "num_comments"
            case createdAt = "created_at"
        }
    }

    private struct RepositoryReference: Sendable {
        var repository: String
        var linkedPath: String?
        var mention: DiscoveryCommunityMention
    }

    private let session: URLSession
    private let endpoint: URL
    private let repositoryResolver: any SkillDiscoveryProvider

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://hn.algolia.com/api/v1/search")!,
        repositoryResolver: any SkillDiscoveryProvider
    ) {
        self.session = session
        self.endpoint = endpoint
        self.repositoryResolver = repositoryResolver
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

    public func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        let cleanQueries = Array(queries.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(DiscoveryEvaluationLimits.maximumSearchQueries))
        guard !cleanQueries.isEmpty else { throw SkillDiscoveryError.emptyQuery }

        var references: [RepositoryReference] = []
        var failedQueryCount = 0
        var saturatedQueryCount = 0
        var completedQueryCount = 0
        var firstError: Error?
        for query in cleanQueries {
            try Task.checkCancellation()
            do {
                let response = try await searchCommunity(query: Self.communityQuery(for: query), limit: limitPerQuery)
                completedQueryCount += 1
                if response.page + 1 < response.nbPages { saturatedQueryCount += 1 }
                references.append(contentsOf: response.hits.compactMap(Self.reference))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedQueryCount += 1
                if firstError == nil { firstError = error }
            }
        }
        guard completedQueryCount > 0 else { throw firstError ?? SkillDiscoveryError.invalidResponse }

        references = Self.deduplicate(references)
        guard !references.isEmpty else {
            return .init(
                candidates: [],
                originalQueryCandidateIDs: [],
                failedQueryCount: failedQueryCount,
                saturatedQueryCount: saturatedQueryCount
            )
        }

        let repositoryQueries = Self.repositoryQueries(for: references)
        let resolved = try await repositoryResolver.search(
            queries: repositoryQueries,
            limitPerQuery: min(max(limitPerQuery, 20), 160)
        )
        var resolvedCountByRepository: [String: Int] = [:]
        for candidate in resolved.candidates {
            resolvedCountByRepository[candidate.repositoryFullName.lowercased(), default: 0] += 1
        }

        let candidates = resolved.candidates.compactMap { candidate -> DiscoveryCandidate? in
            let sameRepository = references.filter {
                $0.repository.caseInsensitiveCompare(candidate.repositoryFullName) == .orderedSame
            }
            guard !sameRepository.isEmpty else { return nil }
            let mentions = sameRepository.filter { reference in
                Self.reference(reference, specificallyMentions: candidate)
                    || resolvedCountByRepository[candidate.repositoryFullName.lowercased()] == 1
            }.map(\.mention)
            guard !mentions.isEmpty else { return nil }
            var candidate = candidate
            candidate.evidence.sources.insert(.communityMedia)
            candidate.evidence.communityMentions = Array(mentions.prefix(5))
            return candidate
        }
        let ids = Set(candidates.map(\.id))
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: ids,
            failedSourceCount: resolved.failedSourceCount,
            failedQueryCount: failedQueryCount + resolved.failedQueryCount,
            saturatedQueryCount: saturatedQueryCount + resolved.saturatedQueryCount,
            failedCandidateVerificationCount: resolved.failedCandidateVerificationCount,
            deferredCandidateVerificationCount: resolved.deferredCandidateVerificationCount,
            rateLimitedUntil: resolved.rateLimitedUntil
        )
    }

    private func searchCommunity(query: String, limit: Int) async throws -> SearchResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "query", value: query),
            .init(name: "tags", value: "story"),
            .init(name: "hitsPerPage", value: String(min(max(limit, 1), 20))),
            .init(name: "page", value: "0"),
        ]
        guard let url = components?.url else { throw SkillDiscoveryError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await DiscoveryNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 1 * 1_024 * 1_024
            )
        } catch is BoundedNetworkResponseError {
            throw SkillDiscoveryError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw SkillDiscoveryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SkillDiscoveryError.requestFailed(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(SearchResponse.self, from: data) else {
            throw SkillDiscoveryError.invalidResponse
        }
        return decoded
    }

    private static func communityQuery(for query: String) -> String {
        let lowered = query.lowercased()
        if lowered.contains("skill") { return query }
        return "\(query) Claude skill"
    }

    private static func reference(from hit: Hit) -> RepositoryReference? {
        let linkedURL = hit.url.flatMap(gitHubURL) ?? hit.storyText.flatMap(firstGitHubURL)
        guard let linkedURL, let identity = repositoryIdentity(from: linkedURL),
              let discussionURL = URL(string: "https://news.ycombinator.com/item?id=\(hit.objectID)")
        else { return nil }
        let title = hit.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mention = DiscoveryCommunityMention(
            id: "hackerNews/\(hit.objectID)",
            platform: .hackerNews,
            author: hit.author,
            title: title?.isEmpty == false ? title! : identity.repository,
            url: discussionURL,
            engagement: max(0, hit.points ?? 0) + max(0, hit.commentCount ?? 0),
            publishedAt: hit.createdAt
        )
        return .init(repository: identity.repository, linkedPath: identity.path, mention: mention)
    }

    private static func gitHubURL(_ url: URL) -> URL? {
        url.host?.lowercased() == "github.com" ? url : nil
    }

    private static func firstGitHubURL(in text: String) -> URL? {
        guard let start = text.range(of: "https://github.com/", options: .caseInsensitive)?.lowerBound else { return nil }
        let suffix = text[start...]
        let end = suffix.firstIndex { character in
            character.isWhitespace || "\"'<>),]".contains(character)
        } ?? text.endIndex
        return URL(string: String(text[start..<end])).flatMap(gitHubURL)
    }

    private static func repositoryIdentity(from url: URL) -> (repository: String, path: String?)? {
        guard gitHubURL(url) != nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        let repository = components[1].replacingOccurrences(of: ".git", with: "")
        let blocked = Set(["topics", "search", "login", "marketplace", "features", "sponsors", "settings"])
        guard !owner.isEmpty, !repository.isEmpty, !blocked.contains(owner.lowercased()) else { return nil }
        var linkedPath: String?
        if components.count >= 5, ["tree", "blob"].contains(components[2]) {
            let tail = components.dropFirst(4)
            let path = tail.last == "SKILL.md" ? tail.dropLast().joined(separator: "/") : tail.joined(separator: "/")
            linkedPath = path.isEmpty ? nil : path
        }
        return ("\(owner)/\(repository)", linkedPath)
    }

    private static func repositoryQueries(for references: [RepositoryReference]) -> [String] {
        var seen = Set<String>()
        return references.compactMap { reference in
            let key = reference.repository.lowercased()
            guard seen.insert(key).inserted else { return nil }
            let hint = skillNameHint(from: reference.mention.title)
            return hint.map { "repo:\(reference.repository) \($0)" } ?? "repo:\(reference.repository)"
        }.prefix(12).map { $0 }
    }

    private static func skillNameHint(from title: String) -> String? {
        let head = title.split(whereSeparator: { ":：–—|".contains($0) }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head, (2...48).contains(head.count) else { return nil }
        let words = head.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count <= 4 else { return nil }
        return head
    }

    private static func deduplicate(_ references: [RepositoryReference]) -> [RepositoryReference] {
        var seen = Set<String>()
        return references.filter { seen.insert("\($0.repository.lowercased())|\($0.mention.id.lowercased())").inserted }
    }

    private static func reference(_ reference: RepositoryReference, specificallyMentions candidate: DiscoveryCandidate) -> Bool {
        if let linkedPath = reference.linkedPath, let skillPath = candidate.skillPath {
            let normalizedLink = linkedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let normalizedSkill = skillPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if normalizedLink == normalizedSkill || normalizedLink.hasSuffix(normalizedSkill) { return true }
        }
        let normalizedTitle = normalize(reference.mention.title)
        let normalizedName = normalize(candidate.name)
        if normalizedTitle.contains(normalizedName) { return true }
        let repositoryName = candidate.repositoryFullName.split(separator: "/").last.map(String.init) ?? ""
        return candidate.skillPath == nil && normalize(repositoryName).contains(normalizedName)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
