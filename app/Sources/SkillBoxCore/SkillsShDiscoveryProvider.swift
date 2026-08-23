import Foundation

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

private actor DiscoveryRepositoryMetadataCache {
    private struct Entry {
        var metadata: DiscoveryRepositoryMetadata
        var expiresAt: Date
    }

    private var values: [String: Entry] = [:]

    func value(for repository: String, now: Date = Date()) -> DiscoveryRepositoryMetadata? {
        guard let entry = values[repository.lowercased()], entry.expiresAt > now else { return nil }
        return entry.metadata
    }

    func insert(_ metadata: DiscoveryRepositoryMetadata, now: Date = Date()) {
        values[metadata.fullName.lowercased()] = Entry(metadata: metadata, expiresAt: now.addingTimeInterval(6 * 60 * 60))
    }
}

private actor DiscoverySkillEvidenceCache {
    private struct Entry {
        var evidence: DiscoveryCandidateEvidence
        var expiresAt: Date
    }

    private var values: [String: Entry] = [:]

    func value(for candidate: DiscoveryCandidate, now: Date = Date()) -> DiscoveryCandidateEvidence? {
        guard let entry = values[Self.key(for: candidate)], entry.expiresAt > now else { return nil }
        return entry.evidence
    }

    func insert(_ evidence: DiscoveryCandidateEvidence, for candidate: DiscoveryCandidate, now: Date = Date()) {
        values[Self.key(for: candidate)] = Entry(evidence: evidence, expiresAt: now.addingTimeInterval(24 * 60 * 60))
    }

    private static func key(for candidate: DiscoveryCandidate) -> String {
        "\(candidate.repositoryFullName.lowercased())|\(candidate.name.lowercased())"
    }
}

public enum SkillDiscoveryError: LocalizedError {
    case emptyQuery
    case invalidResponse
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "先说说你想让 AI 帮你完成什么"
        case .invalidResponse: "Skill 搜索服务返回了无法识别的结果，请稍后重试"
        case .requestFailed: "暂时无法搜索公开 Skills，请稍后重试"
        }
    }
}

public struct SkillsShDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private static let trustedPublishers: Set<String> = [
        "openai", "anthropics", "vercel-labs", "microsoft", "github", "google-gemini", "agnesai-labs",
    ]
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

    private let session: URLSession
    private let endpoint: URL
    private let fallbackEndpoint: URL?
    private let tokenProvider: any GitHubAccessTokenProvider
    private let metadataCache = DiscoveryRepositoryMetadataCache()
    private let evidenceCache = DiscoverySkillEvidenceCache()

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://skills.sh/api/v1/skills/search")!,
        fallbackEndpoint: URL? = URL(string: "https://skills.sh/api/search"),
        repositoryTokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider()
    ) {
        self.session = session
        self.endpoint = endpoint
        self.fallbackEndpoint = fallbackEndpoint
        tokenProvider = repositoryTokenProvider
    }

    public func search(query: String, limit: Int = 10) async throws -> DiscoverySearchResult {
        DiscoverySearchResult(candidates: await enrichRepositoryMetadata(in: try await searchCandidates(query: query, limit: limit)))
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
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
        ]
        guard let url = components?.url else { throw SkillDiscoveryError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await BoundedNetworkResponseLoader.data(
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
        return decoded.skills.compactMap(Self.makeCandidate)
    }

    public func search(queries: [String], limitPerQuery: Int = 20) async throws -> DiscoveryBatchSearchResult {
        let cleanQueries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanQueries.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        var merged: [String: DiscoveryCandidate] = [:]
        var scores: [String: Int] = [:]
        var originalIDs = Set<String>()
        var failedQueryCount = 0
        for (queryIndex, query) in cleanQueries.enumerated() {
            try Task.checkCancellation()
            let candidates: [DiscoveryCandidate]
            do {
                candidates = try await searchCandidates(query: query, limit: limitPerQuery)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                failedQueryCount += 1
                continue
            }
            for (position, candidate) in candidates.enumerated() {
                let key = "\(candidate.repositoryFullName.lowercased())|\(candidate.name.lowercased())"
                if merged[key] == nil { merged[key] = candidate }
                scores[key, default: 0] += max(1, 30 - position) + (queryIndex == 0 ? 80 : 0)
                if queryIndex == 0 { originalIDs.insert(candidate.id) }
            }
        }
        let shortlisted = merged.keys.sorted {
            let left = (scores[$0] ?? 0, merged[$0]?.installCount ?? 0)
            let right = (scores[$1] ?? 0, merged[$1]?.installCount ?? 0)
            return left > right
        }.compactMap { merged[$0] }.filter(Self.hasEnoughPublicEvidenceToVerify)
        let withRepositoryEvidence = await enrichRepositoryMetadata(in: shortlisted)
        let completed = await enrichSkillEvidence(in: withRepositoryEvidence)
        try Task.checkCancellation()
        return .init(
            candidates: completed,
            originalQueryCandidateIDs: originalIDs,
            failedQueryCount: failedQueryCount
        )
    }

    private static func hasEnoughPublicEvidenceToVerify(_ candidate: DiscoveryCandidate) -> Bool {
        let publisher = candidate.repositoryFullName.split(separator: "/").first.map { String($0).lowercased() } ?? ""
        return trustedPublishers.contains(publisher)
            || (candidate.repositoryStars ?? 0) >= 200
            || (candidate.installCount ?? 0) >= 500
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

    private func enrichRepositoryMetadata(in candidates: [DiscoveryCandidate]) async -> [DiscoveryCandidate] {
        var seenRepositories = Set<String>()
        let repositories = candidates.compactMap { candidate -> String? in
            let key = candidate.repositoryFullName.lowercased()
            return seenRepositories.insert(key).inserted ? candidate.repositoryFullName : nil
        }
        let token = try? await tokenProvider.accessToken()
        var metadataByRepository: [String: DiscoveryRepositoryMetadata] = [:]
        var missing: [String] = []
        for repository in repositories {
            if let cached = await metadataCache.value(for: repository) {
                metadataByRepository[repository.lowercased()] = cached
            } else {
                missing.append(repository)
            }
        }
        for batchStart in stride(from: 0, to: missing.count, by: 8) {
            let batchEnd = min(missing.count, batchStart + 8)
            let batch = Array(missing[batchStart..<batchEnd])
            await withTaskGroup(of: DiscoveryRepositoryMetadata?.self) { group in
                for repository in batch {
                    group.addTask { await fetchRepositoryMetadata(repository, token: token) }
                }
                for await metadata in group {
                    if let metadata {
                        metadataByRepository[metadata.fullName.lowercased()] = metadata
                        await metadataCache.insert(metadata)
                    }
                }
            }
        }
        let fetchedAt = Date()
        return candidates.map { candidate in
            guard let metadata = metadataByRepository[candidate.repositoryFullName.lowercased()] else { return candidate }
            var updated = candidate
            if updated.summary?.isEmpty != false, let description = metadata.description, !description.isEmpty {
                updated.summary = description
                updated.summaryIsRepositoryLevel = true
            }
            updated.evidence.repositorySummary = metadata.description
            updated.evidence.repositoryArchived = metadata.archived ?? false
            updated.evidence.repositoryIsPrivate = metadata.isPrivate
            updated.evidence.downloadable = metadata.archived != true
            updated.evidence.sources.insert(.github)
            updated.repositoryStars = metadata.stars
            updated.repositoryStarsFetchedAt = fetchedAt
            updated.repositoryUpdatedAt = metadata.updatedAt
            return updated
        }
    }

    private func enrichSkillEvidence(in candidates: [DiscoveryCandidate]) async -> [DiscoveryCandidate] {
        let token = try? await tokenProvider.accessToken()
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
                            async let sourceEvidence = fetchGitHubSkillEvidence(candidate, token: token)
                            let (directory, source) = await (directoryEvidence, sourceEvidence)
                            if var evidence = source {
                                evidence.repositoryIsPrivate = evidence.repositoryIsPrivate ?? updated.evidence.repositoryIsPrivate
                                if let skillSummary = directory?.skillSummary, !skillSummary.isEmpty {
                                    evidence.skillSummary = skillSummary
                                }
                                evidence.repositorySummary = source?.repositorySummary ?? directory?.repositorySummary
                                updated.evidence = evidence
                                updated.summary = evidence.skillSummary
                                updated.summaryIsRepositoryLevel = false
                                await evidenceCache.insert(evidence, for: candidate)
                            } else if var directory {
                                directory.repositoryIsPrivate = directory.repositoryIsPrivate ?? updated.evidence.repositoryIsPrivate
                                updated.evidence = directory
                                updated.summary = directory.skillSummary
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

    private func fetchSkillsShEvidence(_ candidate: DiscoveryCandidate) async -> DiscoveryCandidateEvidence? {
        let parts = candidate.repositoryFullName.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        var url = URL(string: "https://skills.sh")!
        for component in parts + [candidate.name] { url.appendPathComponent(component) }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await BoundedNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8),
              let summary = Self.jsonLDSkillSummary(in: html)
        else { return nil }
        return .init(
            skillSummary: summary,
            repositorySummary: candidate.repositorySummary,
            skillContentVerified: false,
            skillDocumentURL: url,
            fetchedAt: Date(),
            sources: [.skillsSh]
        )
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

    private func fetchGitHubSkillEvidence(_ candidate: DiscoveryCandidate, token: String?) async -> DiscoveryCandidateEvidence? {
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
            skillDocumentExcerpt: String(markdown.prefix(60_000)),
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

    private static func githubURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func skillFrontmatter(in markdown: String) -> (name: String, description: String)? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return nil }
        let frontmatter = lines[1..<closing]
        func value(for key: String) -> String? {
            guard let line = frontmatter.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) else { return nil }
            let raw = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            let value = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        guard let name = value(for: "name"), let description = value(for: "description") else { return nil }
        return (name, description)
    }

    private static func namesMatch(_ declaredName: String, candidateName: String) -> Bool {
        func normalize(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(declaredName) == normalize(candidateName)
    }

    private func githubData(_ url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await BoundedNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }

    private func fetchRepositoryMetadata(_ repository: String, token: String?) async -> DiscoveryRepositoryMetadata? {
        if let cached = await metadataCache.value(for: repository) { return cached }
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
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await BoundedNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 2 * 1_024 * 1_024
        ),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiscoveryRepositoryMetadata.self, from: data)
    }
}
