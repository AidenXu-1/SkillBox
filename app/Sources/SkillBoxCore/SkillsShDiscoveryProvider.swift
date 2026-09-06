import Foundation

private struct DiscoveryDirectoryMetadata: Sendable {
    var summary: String?
    var starsText: String?
    var installsText: String?
    var fetchedAt: Date
}

private actor DiscoveryDirectoryMetadataCache {
    private var entries: [String: DiscoveryDirectoryMetadata] = [:]
    func value(_ id: String) -> DiscoveryDirectoryMetadata? {
        guard let value = entries[id], Date().timeIntervalSince(value.fetchedAt) < 6 * 3600 else { return nil }
        return value
    }
    func insert(_ value: DiscoveryDirectoryMetadata, id: String) {
        if entries.count >= 128 { entries.removeAll() }
        entries[id] = value
    }
}

private struct DiscoveryRepositoryMetadata: Decodable, Sendable {
    var fullName: String
    var description: String?
    var stars: Int
    var updatedAt: Date?
    var defaultBranch: String?
    var archived: Bool?
    var isPrivate: Bool?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case description
        case stars = "stargazers_count"
        case updatedAt = "updated_at"
        case defaultBranch = "default_branch"
        case archived
        case isPrivate = "private"
    }
}

private struct DiscoveryRepositoryMetadataEvidence: Sendable {
    var metadata: DiscoveryRepositoryMetadata
    var fetchedAt: Date
}

private actor DiscoveryRepositoryMetadataCache {
    private struct Entry {
        var evidence: DiscoveryRepositoryMetadataEvidence
        var expiresAt: Date
    }

    private var values: [String: Entry] = [:]
    private let maximumEntryCount = 128

    func value(for repository: String, now: Date = Date()) -> DiscoveryRepositoryMetadataEvidence? {
        let key = repository.lowercased()
        guard let entry = values[key] else { return nil }
        guard entry.expiresAt > now else {
            values.removeValue(forKey: key)
            return nil
        }
        return entry.evidence
    }

    func insert(_ metadata: DiscoveryRepositoryMetadata, now: Date = Date()) {
        values[metadata.fullName.lowercased()] = Entry(
            evidence: .init(metadata: metadata, fetchedAt: now),
            expiresAt: now.addingTimeInterval(6 * 60 * 60)
        )
        while values.count > maximumEntryCount,
              let oldest = values.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
        {
            values.removeValue(forKey: oldest)
        }
    }
}

private actor DiscoverySkillEvidenceCache {
    private struct Entry {
        var evidence: DiscoveryCandidateEvidence
        var expiresAt: Date
    }

    private var values: [String: Entry] = [:]
    private let maximumEntryCount = 256

    func value(for candidate: DiscoveryCandidate, now: Date = Date()) -> DiscoveryCandidateEvidence? {
        let key = Self.key(for: candidate)
        guard let entry = values[key] else { return nil }
        guard entry.expiresAt > now else {
            values.removeValue(forKey: key)
            return nil
        }
        return entry.evidence
    }

    func insert(_ evidence: DiscoveryCandidateEvidence, for candidate: DiscoveryCandidate, now: Date = Date()) {
        values[Self.key(for: candidate)] = Entry(evidence: evidence, expiresAt: now.addingTimeInterval(24 * 60 * 60))
        while values.count > maximumEntryCount,
              let oldest = values.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
        {
            values.removeValue(forKey: oldest)
        }
    }

    private static func key(for candidate: DiscoveryCandidate) -> String {
        "\(candidate.repositoryFullName.lowercased())|\(candidate.name.lowercased())"
    }
}

private actor DiscoveryVerificationAttemptLedger {
    private var attempts: [String: Date] = [:]

    func claim(_ keys: [String], maximum: Int, now: Date = Date()) -> Set<String> {
        attempts = attempts.filter { now.timeIntervalSince($0.value) < 10 * 60 }
        var claimed = Set<String>()
        for key in keys where attempts[key] == nil && claimed.count < maximum {
            attempts[key] = now
            claimed.insert(key)
        }
        return claimed
    }
}

public enum SkillDiscoveryError: LocalizedError {
    case emptyQuery
    case invalidResponse
    case requestFailed(Int)
    case rateLimited(Date?)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "先说说你想让 AI 帮你完成什么"
        case .invalidResponse: "Skill 搜索服务返回了无法识别的结果，请稍后重试"
        case .requestFailed: "暂时无法搜索公开 Skills，请稍后重试"
        case let .rateLimited(retryAt):
            if let retryAt { "GitHub 暂时限制了查询，请在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后继续" }
            else { "GitHub 暂时限制了查询，请稍后继续" }
        }
    }
}

public struct SkillsShDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private struct Response: Decodable {
        var skills: [Entry]

        private enum CodingKeys: String, CodingKey { case skills, data }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            skills = try values.decodeIfPresent([Entry].self, forKey: .data)
                ?? values.decodeIfPresent([Entry].self, forKey: .skills)
                ?? []
        }
    }

    private struct Entry: Decodable {
        var id: String?
        var name: String
        var description: String?
        var source: String
        var installs: Int?
        var stars: Int?
        var githubStars: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, description, source, installs, stars
            case githubStars = "github_stars"
        }
    }

    private struct QuerySearchOutcome: Sendable {
        var index: Int
        var candidates: [DiscoveryCandidate]?
    }

    private let session: URLSession
    private let endpoint: URL
    private let fallbackEndpoint: URL?
    private let tokenProvider: any GitHubAccessTokenProvider
    private let metadataCache = DiscoveryRepositoryMetadataCache()
    private let evidenceCache = DiscoverySkillEvidenceCache()
    private let directoryCache = DiscoveryDirectoryMetadataCache()
    private let verificationAttempts = DiscoveryVerificationAttemptLedger()
    private let rateLimitGate: GitHubDiscoveryRateLimitGate
    private let exactNamesOnly: Bool

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://skills.sh/api/search")!,
        fallbackEndpoint: URL? = nil,
        repositoryTokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider(),
        rateLimitGate: GitHubDiscoveryRateLimitGate = GitHubDiscoveryRateLimitGate(),
        exactNamesOnly: Bool = false
    ) {
        self.session = session
        self.endpoint = endpoint
        self.fallbackEndpoint = fallbackEndpoint
        tokenProvider = repositoryTokenProvider
        self.rateLimitGate = rateLimitGate
        self.exactNamesOnly = exactNamesOnly
    }

    public func search(query: String, limit: Int = 10) async throws -> DiscoverySearchResult {
        let candidates = try await searchCandidates(query: query, limit: limit)
        return DiscoverySearchResult(
            candidates: candidates,
            hasMoreResults: candidates.count >= min(max(limit, 1), DiscoverySearchLimits.skillsShMaximumResultsPerQuery)
        )
    }

    private func searchCandidates(query: String, limit: Int) async throws -> [DiscoveryCandidate] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        do {
            return try await requestCandidates(query: cleanQuery, limit: limit, endpoint: endpoint)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            guard let fallbackEndpoint, fallbackEndpoint != endpoint else { throw error }
            return try await requestCandidates(query: cleanQuery, limit: limit, endpoint: fallbackEndpoint)
        }
    }

    private func requestCandidates(query: String, limit: Int, endpoint: URL) async throws -> [DiscoveryCandidate] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: DiscoveryAuthorIdentity.ownerQuery(query) ?? query),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, DiscoverySearchLimits.skillsShMaximumResultsPerQuery)))),
        ]
        guard let url = components?.url else { throw SkillDiscoveryError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
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
        guard (200...299).contains(http.statusCode) else { throw SkillDiscoveryError.requestFailed(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SkillDiscoveryError.invalidResponse
        }
        let candidates = decoded.skills.compactMap(Self.makeCandidate)
        guard let owner = DiscoveryAuthorIdentity.ownerQuery(query) else { return candidates }
        return candidates.filter { DiscoveryAuthorIdentity.matches(repository: $0.repositoryFullName, owner: owner) }
    }

    public func search(queries: [String], limitPerQuery: Int = 20) async throws -> DiscoveryBatchSearchResult {
        let cleanQueries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanQueries.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        var merged: [String: DiscoveryCandidate] = [:]
        var scores: [String: Int] = [:]
        var exactNameKeys = Set<String>()
        var originalIDs = Set<String>()
        var failedQueryCount = 0
        var saturatedQueryCount = 0
        let outcomes = try await withThrowingTaskGroup(of: QuerySearchOutcome.self) { group in
            for (queryIndex, query) in cleanQueries.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let candidates = try await searchCandidates(query: query, limit: limitPerQuery)
                        return .init(index: queryIndex, candidates: candidates)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled {
                        throw CancellationError()
                    } catch {
                        return .init(index: queryIndex, candidates: nil)
                    }
                }
            }
            var values: [QuerySearchOutcome] = []
            for try await outcome in group { values.append(outcome) }
            return values.sorted { $0.index < $1.index }
        }
        for outcome in outcomes {
            guard let candidates = outcome.candidates else {
                failedQueryCount += 1
                continue
            }
            let query = cleanQueries[outcome.index]
            if candidates.count >= min(max(limitPerQuery, 1), DiscoverySearchLimits.skillsShMaximumResultsPerQuery) {
                saturatedQueryCount += 1
            }
            for (position, candidate) in candidates.enumerated() {
                if exactNamesOnly,
                   Self.normalizedSkillName(candidate.name) != Self.normalizedSkillName(query) { continue }
                let key = "\(candidate.repositoryFullName.lowercased())|\(candidate.name.lowercased())"
                if merged[key] == nil { merged[key] = candidate }
                scores[key, default: 0] += max(1, 30 - position)
                if Self.isLikelyExactSkillNameQuery(query),
                   Self.normalizedSkillName(candidate.name) == Self.normalizedSkillName(query)
                {
                    exactNameKeys.insert(key)
                }
                if outcome.index == 0 { originalIDs.insert(candidate.id) }
            }
        }
        var exactRankByKey: [String: Int] = [:]
        let exactGroups = Dictionary(grouping: exactNameKeys) { key in
            Self.normalizedSkillName(merged[key]?.name ?? "")
        }
        for group in exactGroups.values {
            let ordered = group.sorted {
                let left = (merged[$0]?.installCount ?? 0, scores[$0] ?? 0)
                let right = (merged[$1]?.installCount ?? 0, scores[$1] ?? 0)
                return left > right
            }
            for (rank, key) in ordered.enumerated() { exactRankByKey[key] = rank }
        }
        let allShortlisted = merged.keys.sorted {
            let leftExactRank = exactRankByKey[$0]
            let rightExactRank = exactRankByKey[$1]
            if leftExactRank != rightExactRank {
                if let leftExactRank, let rightExactRank { return leftExactRank < rightExactRank }
                return leftExactRank != nil
            }
            let left = (scores[$0] ?? 0, merged[$0]?.installCount ?? 0)
            let right = (scores[$1] ?? 0, merged[$1]?.installCount ?? 0)
            return left > right
        }.compactMap { merged[$0] }
        if allShortlisted.count > DiscoverySearchLimits.maximumCandidatesPerProvider {
            saturatedQueryCount += 1
        }
        let shortlisted = Array(allShortlisted.prefix(DiscoverySearchLimits.maximumCandidatesPerProvider))
        var completedByID: [String: DiscoveryCandidate] = [:]
        var uncached: [DiscoveryCandidate] = []
        for var candidate in shortlisted {
            if var evidence = await evidenceCache.value(for: candidate), evidence.skillContentVerified {
                evidence.repositoryIsPrivate = evidence.repositoryIsPrivate ?? candidate.evidence.repositoryIsPrivate
                candidate.evidence = evidence
                candidate.summary = evidence.skillSummary
                candidate.summaryIsRepositoryLevel = false
                completedByID[candidate.id] = candidate
            } else {
                uncached.append(candidate)
            }
        }
        let candidateKey: (DiscoveryCandidate) -> String = { "\($0.repositoryFullName.lowercased())|\($0.name.lowercased())" }
        let claimedKeys = await verificationAttempts.claim(
            uncached.map(candidateKey),
            maximum: max(
                DiscoverySearchLimits.skillsShDetailLimit(for: limitPerQuery),
                min(exactGroups.count, DiscoveryEvaluationLimits.maximumSearchQueries)
            )
        )
        let claimed = uncached.filter { claimedKeys.contains(candidateKey($0)) }
        let detailed = await enrichSkillEvidence(in: claimed)
        for candidate in detailed { completedByID[candidate.id] = candidate }
        var completed = shortlisted.map { completedByID[$0.id] ?? $0 }
        for index in completed.indices {
            if let metadata = await directoryCache.value(completed[index].id) {
                completed[index].repositoryStarsText = metadata.starsText
                if completed[index].repositoryStarsFetchedAt == nil, metadata.starsText != nil {
                    completed[index].repositoryStarsFetchedAt = metadata.fetchedAt
                }
            }
        }
        let newlyVerifiedCount = detailed.filter { $0.evidence.skillContentVerified }.count
        let rateLimitedUntil = await rateLimitGate.activeRetryDate()
        try Task.checkCancellation()
        return .init(
            candidates: completed,
            originalQueryCandidateIDs: originalIDs,
            failedQueryCount: failedQueryCount,
            saturatedQueryCount: saturatedQueryCount + (uncached.count > claimed.count || rateLimitedUntil != nil ? 1 : 0),
            failedCandidateVerificationCount: max(0, claimed.count - newlyVerifiedCount),
            deferredCandidateVerificationCount: max(0, uncached.count - claimed.count),
            rateLimitedUntil: rateLimitedUntil
        )
    }

    private static func makeCandidate(_ entry: Entry) -> DiscoveryCandidate? {
        let repository = normalizeRepository(entry.source)
        guard repository.split(separator: "/").count == 2 else { return nil }
        let rawID = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoveryCandidate(
            id: rawID ?? "\(repository)/\(entry.name)",
            name: entry.name,
            summary: entry.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            repositoryFullName: repository,
            // skills.sh identifies a Skill, not its physical directory. Treating
            // the identifier suffix as a GitHub path can silently point at the
            // wrong folder. The existing GitHub importer will scan the complete
            // repository and preselect the matching Skill by name.
            skillPath: nil,
            installCount: entry.installs,
            repositoryStars: entry.githubStars ?? entry.stars,
            repositoryStarsFetchedAt: (entry.githubStars ?? entry.stars) == nil ? nil : Date()
        )
    }

    private static func normalizeRepository(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host?.lowercased() == "github.com" {
            return url.pathComponents.filter { $0 != "/" }.prefix(2).joined(separator: "/")
                .replacingOccurrences(of: ".git", with: "")
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
    }

    private static func normalizedSkillName(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func isLikelyExactSkillNameQuery(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= 64
            && trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private func enrichSkillEvidence(in candidates: [DiscoveryCandidate]) async -> [DiscoveryCandidate] {
        var allValues: [(Int, DiscoveryCandidate)] = []
        for batchStart in stride(from: 0, to: candidates.count, by: 8) {
            let batchEnd = min(candidates.count, batchStart + 8)
            let indexedBatch = candidates[batchStart..<batchEnd].enumerated().map { offset, candidate in
                (batchStart + offset, candidate)
            }
            let values = await withTaskGroup(of: (Int, DiscoveryCandidate).self, returning: [(Int, DiscoveryCandidate)].self) { group in
                for (index, candidate) in indexedBatch {
                    group.addTask {
                        var updated = candidate
                        if var evidence = await evidenceCache.value(for: candidate) {
                            evidence.repositoryIsPrivate = evidence.repositoryIsPrivate ?? updated.evidence.repositoryIsPrivate
                            updated.evidence = evidence
                            updated.summary = evidence.skillSummary
                            updated.summaryIsRepositoryLevel = false
                        } else {
                            async let directoryEvidence = fetchSkillsShEvidence(candidate)
                            async let sourceEvidence = fetchGitHubSkillEvidence(candidate)
                            let (directory, source) = await (directoryEvidence, sourceEvidence)
                            if var evidence = source {
                                evidence.repositoryIsPrivate = evidence.repositoryIsPrivate ?? updated.evidence.repositoryIsPrivate
                                updated.evidence = evidence
                                updated.summary = evidence.skillSummary
                                updated.summaryIsRepositoryLevel = false
                                await evidenceCache.insert(evidence, for: candidate)
                            } else if let directory {
                                updated.evidence = .init(skillSummary: directory.summary, fetchedAt: directory.fetchedAt, sources: [.skillsSh])
                                updated.summary = directory.summary
                                updated.summaryIsRepositoryLevel = false
                            }
                        }
                        return (index, updated)
                    }
                }
                var collected: [(Int, DiscoveryCandidate)] = []
                for await value in group { collected.append(value) }
                return collected
            }
            allValues.append(contentsOf: values)
        }
        return allValues.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Only called for the bounded, already verified task catalog. A directory
    /// page is evidence for counts, never proof of the Skill's identity or ability.
    func enrichKnownTaskCandidates(_ candidates: [DiscoveryCandidate]) async -> [DiscoveryCandidate] {
        await withTaskGroup(of: (Int, DiscoveryCandidate).self) { group in
            for (index, candidate) in candidates.prefix(4).enumerated() {
                group.addTask {
                    var updated = candidate
                    if candidate.evidence.skillContentVerified,
                       let page = await fetchSkillsShEvidence(candidate, canonicalHost: true) {
                        updated.installCountText = page.installsText
                        updated.repositoryStarsText = page.starsText
                        if page.starsText != nil { updated.repositoryStarsFetchedAt = page.fetchedAt }
                        updated.evidence.sources.insert(.skillsSh)
                    }
                    return (index, updated)
                }
            }
            var values: [(Int, DiscoveryCandidate)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetchSkillsShEvidence(_ candidate: DiscoveryCandidate, canonicalHost: Bool = false) async -> DiscoveryDirectoryMetadata? {
        if let cached = await directoryCache.value(candidate.id) { return cached }
        let parts = candidate.repositoryFullName.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        var url = URL(string: canonicalHost ? "https://www.skills.sh" : "https://skills.sh")!
        for component in parts + [candidate.name] { url.appendPathComponent(component) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        let metadata = DiscoveryDirectoryMetadata(summary: Self.jsonLDSkillSummary(in: html), starsText: Self.directoryStars(in: html), installsText: Self.directoryCount(in: html, label: "Installs"), fetchedAt: Date())
        await directoryCache.insert(metadata, id: candidate.id)
        return metadata
    }

    static func directoryStars(in html: String) -> String? {
        // Read the rendered, labelled field. Keep rounded values as text rather
        // than inventing an exact integer or treating installs as repository stars.
        return directoryCount(in: html, label: "GitHub Stars")
    }

    private static func directoryCount(in html: String, label: String) -> String? {
        guard let label = html.range(of: "\(label)</span>") else { return nil }
        let section = String(html[label.upperBound...].prefix(2_000))
        let text = section.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.range(of: #"^[0-9][0-9,]*(?:\.[0-9]+)?[KM]?(?=\s|$)"#, options: .regularExpression) else { return nil }
        return String(text[match])
    }

    private static func jsonLDSkillSummary(in html: String) -> String? {
        let pattern = #"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html),
                  let data = String(html[capture]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            let dictionaries: [[String: Any]]
            if let dictionary = object as? [String: Any] { dictionaries = [dictionary] }
            else { dictionaries = object as? [[String: Any]] ?? [] }
            for dictionary in dictionaries {
                let type = (dictionary["@type"] as? String)?.lowercased() ?? ""
                guard type.contains("software") || type.contains("creative") else { continue }
                if let description = dictionary["description"] as? String {
                    let clean = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { return clean }
                }
            }
        }
        return nil
    }

    private func fetchGitHubSkillEvidence(_ candidate: DiscoveryCandidate) async -> DiscoveryCandidateEvidence? {
        if let direct = await fetchPublicRawSkillEvidence(candidate) { return direct }

        guard !Task.isCancelled else { return nil }
        let token = try? await tokenProvider.accessToken()
        let repository = candidate.repositoryFullName
        guard let metadata = await fetchRepositoryMetadata(repository, token: token),
              let branch = metadata.defaultBranch,
              let treeURL = Self.githubURL(path: "/repos/\(repository)/git/trees/\(branch)", queryItems: [.init(name: "recursive", value: "1")])
        else { return nil }
        guard let treeData = await githubData(treeURL, token: token),
              let object = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let tree = object["tree"] as? [[String: Any]]
        else { return nil }
        let paths = tree.compactMap { $0["path"] as? String }.filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }
        let normalizedName = candidate.name.lowercased().replacingOccurrences(of: "_", with: "-")
        let matching = paths.filter {
            let parent = URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent.lowercased().replacingOccurrences(of: "_", with: "-")
            return parent == normalizedName
        }
        guard let path = matching.first ?? (paths.count == 1 ? paths[0] : nil),
              let contentURL = Self.githubURL(path: "/repos/\(repository)/contents/\(path)", queryItems: [.init(name: "ref", value: branch)]),
              let contentData = await githubData(contentURL, token: token),
              let contentObject = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let encoded = contentObject["content"] as? String,
              let markdownData = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")),
              let markdown = String(data: markdownData, encoding: .utf8),
              let frontmatter = Self.skillFrontmatter(in: markdown),
              Self.namesMatch(frontmatter.name, candidateName: candidate.name)
        else { return nil }
        return .init(
            skillSummary: frontmatter.description,
            skillDocumentExcerpt: String(markdown.prefix(DiscoveryEvaluationLimits.maximumPersistedSkillCharacters)),
            repositorySummary: metadata.description,
            skillContentVerified: true,
            repositoryIsPrivate: metadata.isPrivate,
            skillDocumentURL: contentURL,
            fetchedAt: Date(),
            sources: [.github, .skillDocument],
            repositoryArchived: metadata.archived ?? false,
            downloadable: metadata.archived != true
        )
    }

    private func fetchPublicRawSkillEvidence(_ candidate: DiscoveryCandidate) async -> DiscoveryCandidateEvidence? {
        let repositoryParts = candidate.repositoryFullName.split(separator: "/").map(String.init)
        let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard repositoryParts.count == 2,
              !name.isEmpty,
              name != ".",
              name != "..",
              name.rangeOfCharacter(from: allowed.inverted) == nil
        else { return nil }

        let candidatePaths = [
            ["SKILL.md"],
            [name, "SKILL.md"],
            ["skills", name, "SKILL.md"],
            [".agents", "skills", name, "SKILL.md"],
            [".claude", "skills", name, "SKILL.md"],
        ]
        for path in candidatePaths {
            guard !Task.isCancelled else { return nil }
            var url = URL(string: "https://raw.githubusercontent.com")!
            for component in repositoryParts + ["HEAD"] + path { url.appendPathComponent(component) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 512 * 1_024
            ),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let markdown = String(data: data, encoding: .utf8),
                  let frontmatter = Self.skillFrontmatter(in: markdown),
                  Self.namesMatch(frontmatter.name, candidateName: candidate.name)
            else { continue }
            return .init(
                skillSummary: frontmatter.description,
                skillDocumentExcerpt: String(markdown.prefix(DiscoveryEvaluationLimits.maximumPersistedSkillCharacters)),
                repositorySummary: candidate.repositorySummary,
                skillContentVerified: true,
                repositoryIsPrivate: false,
                skillDocumentURL: url,
                fetchedAt: Date(),
                sources: [.github, .skillDocument],
                repositoryArchived: false,
                downloadable: true
            )
        }
        return nil
    }

    private static func githubURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func skillFrontmatter(in markdown: String) -> (name: String, description: String)? {
        DiscoverySkillDocumentParser.frontmatter(in: markdown)
    }

    private static func namesMatch(_ declaredName: String, candidateName: String) -> Bool {
        func normalize(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(declaredName) == normalize(candidateName)
    }

    private func githubData(_ url: URL, token: String?) async -> Data? {
        guard await rateLimitGate.activeRetryDate(for: GitHubDiscoveryRateLimitGate.resource(for: url)) == nil else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse
        else { return nil }
        await rateLimitGate.observeDiscoveryResponse(http, anonymous: token == nil)
        guard (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private func fetchRepositoryMetadata(_ repository: String, token: String?) async -> DiscoveryRepositoryMetadata? {
        if let cached = await metadataCache.value(for: repository) { return cached.metadata }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)") else { return nil }
        let metadata: DiscoveryRepositoryMetadata?
        if let token, let authenticated = await requestRepositoryMetadata(url: url, token: token) {
            metadata = authenticated
        } else {
            metadata = await requestRepositoryMetadata(url: url, token: nil)
        }
        if let metadata { await metadataCache.insert(metadata) }
        return metadata
    }

    private func requestRepositoryMetadata(url: URL, token: String?) async -> DiscoveryRepositoryMetadata? {
        guard await rateLimitGate.activeRetryDate(for: .core) == nil else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse
        else { return nil }
        await rateLimitGate.observeDiscoveryResponse(http, anonymous: token == nil)
        guard (200...299).contains(http.statusCode) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiscoveryRepositoryMetadata.self, from: data)
    }
}
