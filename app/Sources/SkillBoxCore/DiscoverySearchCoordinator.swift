import Foundation

public struct DiscoverySearchCoordinator: Sendable {
    private let providers: [any SkillDiscoveryProvider]

    public init(providers: [any SkillDiscoveryProvider]) {
        self.providers = providers
    }

    public func search(queries: [String], limitPerQuery: Int = 1_000) async throws -> DiscoveryBatchSearchResult {
        let cleaned = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        var merged: [DiscoveryCandidate] = []
        var originalCandidateIDs = Set<String>()
        var firstError: Error?
        var completedSourceCount = 0
        var failedSourceCount = 0
        var failedQueryCount = 0

        for provider in providers {
            try Task.checkCancellation()
            do {
                let result = try await provider.search(queries: cleaned, limitPerQuery: limitPerQuery)
                try Task.checkCancellation()
                completedSourceCount += 1
                failedSourceCount += result.failedSourceCount
                failedQueryCount += result.failedQueryCount
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
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedSourceCount += 1
                if firstError == nil { firstError = error }
            }
        }

        guard completedSourceCount > 0 else { throw firstError ?? SkillDiscoveryError.invalidResponse }
        return .init(
            candidates: merged,
            originalQueryCandidateIDs: originalCandidateIDs,
            failedSourceCount: failedSourceCount,
            failedQueryCount: failedQueryCount
        )
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
        if first.evidence.repositoryIsPrivate == true || second.evidence.repositoryIsPrivate == true {
            merged.evidence.repositoryIsPrivate = true
        } else if first.evidence.repositoryIsPrivate == false || second.evidence.repositoryIsPrivate == false {
            merged.evidence.repositoryIsPrivate = false
        }
        merged.evidence.repositoryArchived = first.evidence.repositoryArchived || second.evidence.repositoryArchived
        merged.evidence.downloadable = first.evidence.downloadable && second.evidence.downloadable
        merged.evidence.hasBlockingSafetyIssue = first.evidence.hasBlockingSafetyIssue || second.evidence.hasBlockingSafetyIssue
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

public struct GitHubSkillDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private static let trustedPublishers: Set<String> = [
        "openai", "anthropics", "vercel-labs", "microsoft", "github", "google-gemini", "agnesai-labs",
    ]
    private struct SearchResponse: Decodable {
        var totalCount: Int
        var items: [SearchItem]

        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
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
    private struct RepositoryResponse: Decodable {
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

    private let session: URLSession
    private let tokenProvider: any GitHubAccessTokenProvider

    public init(session: URLSession = .shared, tokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider()) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func search(query: String, limit: Int = 1_000) async throws -> DiscoverySearchResult {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        let token = try? await tokenProvider.accessToken()
        let items = try await searchItems(query: clean, limit: limit, token: token)
        return .init(candidates: await verifiedCandidates(for: items, token: token))
    }

    private func searchItems(query: String, limit: Int, token: String?) async throws -> [SearchItem] {
        let sourceLimit = min(max(limit, 1), 1_000)
        var items: [SearchItem] = []
        var page = 1

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
            items.append(contentsOf: decoded.items)
            if decoded.items.isEmpty || items.count >= decoded.totalCount || decoded.items.count < 100 { break }
            page += 1
        }
        return items
    }

    private func verifiedCandidates(for items: [SearchItem], token: String?) async -> [DiscoveryCandidate] {
        let repositories = await repositoryEvidence(for: items, token: token)
        let qualifiedItems = items.filter { item in
            guard let repository = repositories[item.repository.fullName.lowercased()] else { return false }
            return Self.hasEnoughPublicEvidenceToVerify(repository)
        }

        var indexedCandidates: [(Int, DiscoveryCandidate)] = []
        for batchStart in stride(from: 0, to: qualifiedItems.count, by: 8) {
            let batchEnd = min(qualifiedItems.count, batchStart + 8)
            let batch = qualifiedItems[batchStart..<batchEnd].enumerated().map { (batchStart + $0.offset, $0.element) }
            let values = await withTaskGroup(of: DiscoveryCandidate?.self, returning: [DiscoveryCandidate].self) { group in
                for (_, item) in batch {
                    let repository = repositories[item.repository.fullName.lowercased()]
                    group.addTask { await self.makeCandidate(item, repository: repository, token: token) }
                }
                var collected: [DiscoveryCandidate] = []
                for await candidate in group { if let candidate { collected.append(candidate) } }
                return collected
            }
            for candidate in values {
                let index = qualifiedItems.firstIndex(where: { Self.candidateID(for: $0) == candidate.id }) ?? batchStart
                indexedCandidates.append((index, candidate))
            }
        }
        return indexedCandidates.sorted { $0.0 < $1.0 }.map(\.1)
    }

    public func search(queries: [String], limitPerQuery: Int = 1_000) async throws -> DiscoveryBatchSearchResult {
        let token = try? await tokenProvider.accessToken()
        var mergedItems: [String: SearchItem] = [:]
        var itemOrder: [String] = []
        var originalItemIDs = Set<String>()
        var failedQueryCount = 0
        var completedQueryCount = 0
        var firstError: Error?

        for (queryIndex, query) in queries.enumerated() {
            try Task.checkCancellation()
            do {
                let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let items = try await searchItems(query: clean, limit: limitPerQuery, token: token)
                completedQueryCount += 1
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
            } catch {
                failedQueryCount += 1
                if firstError == nil { firstError = error }
            }
        }

        guard completedQueryCount > 0 else { throw firstError ?? SkillDiscoveryError.invalidResponse }
        let orderedItems = itemOrder.compactMap { mergedItems[$0] }
        let candidates = await verifiedCandidates(for: orderedItems, token: token)
        try Task.checkCancellation()
        let originalIDs = Set(candidates.compactMap { originalItemIDs.contains($0.id) ? $0.id : nil })
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: originalIDs,
            failedQueryCount: failedQueryCount
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
              let contentData = try? await githubData(item.url, token: token),
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
                skillDocumentExcerpt: String(markdown.prefix(60_000)),
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
        for batchStart in stride(from: 0, to: repositories.count, by: 8) {
            let batchEnd = min(repositories.count, batchStart + 8)
            let batch = Array(repositories[batchStart..<batchEnd])
            let metadata = await withTaskGroup(of: RepositoryResponse?.self, returning: [RepositoryResponse].self) { group in
                for repository in batch {
                    group.addTask { await self.repositoryMetadata(repository, token: token) }
                }
                var collected: [RepositoryResponse] = []
                for await repository in group { if let repository { collected.append(repository) } }
                return collected
            }
            for repository in metadata { values[repository.fullName.lowercased()] = repository }
        }
        return values
    }

    private static func hasEnoughPublicEvidenceToVerify(_ repository: RepositoryResponse) -> Bool {
        let publisher = repository.fullName.split(separator: "/").first.map { String($0).lowercased() } ?? ""
        return trustedPublishers.contains(publisher) || repository.stars >= 500
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
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
        guard let name = value("name"), let description = value("description") else { return nil }
        return (name, description)
    }

    private static func nameMatchesPath(_ name: String, path: String) -> Bool {
        if path == "SKILL.md" { return true }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        func normalize(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "_", with: "-") }
        return normalize(parent) == normalize(name)
    }
}
