import Foundation

public struct TrustedSkillCatalogEntry: Codable, Hashable, Sendable {
    public typealias Trust = DiscoveryCatalogTrust

    public var repository: String
    public var revision: String
    public var path: String
    public var name: String
    public var description: String
    public var trust: Trust
    public var searchAliases: [String]?
    /// Editorial identity aliases backed by an author's public document. Capability
    /// search terms remain in searchAliases and never establish identity.
    public var nameAliases: [String]?
    public var nameAliasSource: URL?

    public init(
        repository: String,
        revision: String = "main",
        path: String,
        name: String,
        description: String,
        trust: Trust
    ) {
        self.repository = repository
        self.revision = revision
        self.path = path
        self.name = name
        self.description = description
        self.trust = trust
    }
}

private struct TrustedSkillCatalogSnapshot: Codable {
    var version: Int
    var generatedAt: String
    var entries: [TrustedSkillCatalogEntry]
}

public struct TrustedSkillCatalogSummary: Equatable, Sendable {
    public var entryCount: Int
    public var officialCount: Int
    public var curatedCount: Int
    public var internalPathCount: Int
}

private struct TrustedCatalogRepositoryMetadata: Decodable, Sendable {
    var fullName: String
    var description: String?
    var stars: Int
    var updatedAt: Date?
    var archived: Bool
    var disabled: Bool

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case description
        case stars = "stargazers_count"
        case updatedAt = "updated_at"
        case archived, disabled
    }
}

private struct TrustedCatalogRepositoryEvidence: Sendable {
    var metadata: TrustedCatalogRepositoryMetadata
    var fetchedAt: Date
}

private struct TrustedCatalogDocumentEvidence: Sendable {
    var markdown: String
    var fetchedAt: Date
}

private actor TrustedSkillCatalogCache {
    private struct RepositoryEntry {
        var evidence: TrustedCatalogRepositoryEvidence
        var expiresAt: Date
    }

    private struct DocumentEntry {
        var evidence: TrustedCatalogDocumentEvidence
        var expiresAt: Date
        var byteCount: Int
    }

    private let ttl: TimeInterval
    private let maximumRepositoryCount = 64
    private let maximumDocumentCount = 128
    private let maximumDocumentBytes = 8 * 1_024 * 1_024
    private var repositories: [String: RepositoryEntry] = [:]
    private var documents: [String: DocumentEntry] = [:]
    private var recentVerificationAttempts: [String: Date] = [:]

    init(ttl: TimeInterval) {
        self.ttl = max(0, ttl)
    }

    func repository(_ name: String, now: Date) -> TrustedCatalogRepositoryEvidence? {
        let key = name.lowercased()
        guard let entry = repositories[key] else { return nil }
        guard entry.expiresAt > now else {
            repositories.removeValue(forKey: key)
            return nil
        }
        return entry.evidence
    }

    func insert(_ metadata: TrustedCatalogRepositoryMetadata, now: Date) {
        repositories[metadata.fullName.lowercased()] = .init(
            evidence: .init(metadata: metadata, fetchedAt: now),
            expiresAt: now.addingTimeInterval(ttl)
        )
        while repositories.count > maximumRepositoryCount,
              let oldest = repositories.min(by: { $0.value.evidence.fetchedAt < $1.value.evidence.fetchedAt })?.key
        {
            repositories.removeValue(forKey: oldest)
        }
    }

    func document(repository: String, revision: String, path: String, now: Date) -> TrustedCatalogDocumentEvidence? {
        let key = Self.documentKey(repository: repository, revision: revision, path: path)
        guard let entry = documents[key] else { return nil }
        guard entry.expiresAt > now else {
            documents.removeValue(forKey: key)
            return nil
        }
        return entry.evidence
    }

    func insert(document: String, repository: String, revision: String, path: String, now: Date) {
        let key = Self.documentKey(repository: repository, revision: revision, path: path)
        recentVerificationAttempts.removeValue(forKey: "\(repository.lowercased())|\(path.lowercased())")
        documents[key] = .init(
            evidence: .init(markdown: document, fetchedAt: now),
            expiresAt: now.addingTimeInterval(ttl),
            byteCount: document.utf8.count
        )
        while documents.count > maximumDocumentCount || documents.values.reduce(0, { $0 + $1.byteCount }) > maximumDocumentBytes {
            guard let oldest = documents.min(by: { $0.value.evidence.fetchedAt < $1.value.evidence.fetchedAt })?.key else { break }
            documents.removeValue(forKey: oldest)
        }
    }

    func claimVerificationKeys(_ keys: [String], maximum: Int, now: Date) -> Set<String> {
        recentVerificationAttempts = recentVerificationAttempts.filter { now.timeIntervalSince($0.value) < 10 * 60 }
        var claimed = Set<String>()
        for key in keys where recentVerificationAttempts[key] == nil && claimed.count < maximum {
            recentVerificationAttempts[key] = now
            claimed.insert(key)
        }
        return claimed
    }

    private static func documentKey(repository: String, revision: String, path: String) -> String {
        "\(repository.lowercased())|\(revision)|\(path)"
    }
}

public struct TrustedSkillCatalogDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private let session: URLSession
    private let tokenProvider: any GitHubAccessTokenProvider
    private let entries: [TrustedSkillCatalogEntry]
    private let cache: TrustedSkillCatalogCache
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        tokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider(),
        entries: [TrustedSkillCatalogEntry]? = nil,
        cacheTTL: TimeInterval = 6 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.entries = entries ?? Self.bundledEntries()
        cache = TrustedSkillCatalogCache(ttl: cacheTTL)
        self.now = now
    }

    public static var bundledEntryCount: Int { bundledEntries().count }

    /// Editorial aliases are recall hints only; live author documents and the
    /// normal evidence gates still decide whether a result can be recommended.
    public static func taskNames(for goal: String, limit: Int = 4) -> [String] {
        let compact = goal.lowercased().replacingOccurrences(of: " ", with: "")
        return Array(bundledEntries().filter { entry in
            entry.searchAliases?.contains { compact.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) } == true
        }.map(\.name).prefix(limit))
    }

    static func taskEntries() -> [TrustedSkillCatalogEntry] {
        bundledEntries().filter { $0.searchAliases?.isEmpty == false }
    }

    public static var bundledSummary: TrustedSkillCatalogSummary {
        let entries = bundledEntries()
        return .init(
            entryCount: entries.count,
            officialCount: entries.filter { $0.trust == .official }.count,
            curatedCount: entries.filter { $0.trust == .curated }.count,
            internalPathCount: entries.filter { $0.path.hasPrefix(".github/") || $0.path.hasPrefix(".agents/") }.count
        )
    }

    public static func bundledMatches(queries: [String], limit: Int = 40) -> [TrustedSkillCatalogEntry] {
        let catalog = bundledEntries()
        let boundedLimit = min(max(limit, 1), max(catalog.count, 1))
        let provider = TrustedSkillCatalogDiscoveryProvider(entries: catalog)
        return provider.rankedEntries(
            for: queries,
            limitPerQuery: boundedLimit,
            overallLimit: boundedLimit
        ).entries
    }

    public func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let result = try await search(queries: [query], limitPerQuery: limit)
        return .init(
            candidates: result.candidates,
            fetchedAt: result.fetchedAt,
            hasMoreResults: result.saturatedQueryCount > 0,
            failedCandidateVerificationCount: result.failedCandidateVerificationCount
        )
    }

    public func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        let cleaned = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        let perQueryLimit = min(max(limitPerQuery, 1), max(entries.count, 1))
        let rankedResult = rankedEntries(
            for: cleaned,
            limitPerQuery: perQueryLimit,
            overallLimit: min(DiscoverySearchLimits.maximumCandidatesPerProvider, perQueryLimit * cleaned.count)
        )
        let ranked = rankedResult.entries
        let originalKeys = Set(
            rankedEntries(for: [cleaned[0]], limitPerQuery: perQueryLimit, overallLimit: perQueryLimit).entries
                .map(Self.key)
        )
        var indexed: [(Int, DiscoveryCandidate)] = []
        var uncached: [(Int, TrustedSkillCatalogEntry)] = []
        for (index, entry) in ranked.enumerated() {
            if let candidate = await cachedCandidate(for: entry) { indexed.append((index, candidate)) }
            else { uncached.append((index, entry)) }
        }
        let cachedCandidateCount = indexed.count
        let claimedKeys = await cache.claimVerificationKeys(
            uncached.map { Self.key($0.1) },
            maximum: DiscoverySearchLimits.trustedCatalogVerificationLimit(for: limitPerQuery),
            now: now()
        )
        let entriesToVerify = uncached.filter { claimedKeys.contains(Self.key($0.1)) }
        for start in stride(from: 0, to: entriesToVerify.count, by: 8) {
            let end = min(start + 8, entriesToVerify.count)
            let batch = Array(entriesToVerify[start..<end])
            let values = await withTaskGroup(of: (Int, DiscoveryCandidate?).self, returning: [(Int, DiscoveryCandidate)].self) { group in
                for (index, entry) in batch {
                    group.addTask { (index, await verifiedCandidate(for: entry)) }
                }
                var collected: [(Int, DiscoveryCandidate)] = []
                for await (index, candidate) in group {
                    if let candidate { collected.append((index, candidate)) }
                }
                return collected
            }
            indexed.append(contentsOf: values)
        }
        let candidates = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        let newlyVerifiedCount = max(0, candidates.count - cachedCandidateCount)
        let deferredCount = max(0, ranked.count - cachedCandidateCount - entriesToVerify.count)
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: Set(candidates.compactMap {
                originalKeys.contains("\($0.repositoryFullName.lowercased())|\($0.skillPath?.lowercased() ?? "")") ? $0.id : nil
            }),
            saturatedQueryCount: rankedResult.saturatedQueryCount + (deferredCount > 0 ? 1 : 0),
            failedCandidateVerificationCount: max(0, entriesToVerify.count - newlyVerifiedCount),
            deferredCandidateVerificationCount: deferredCount
        )
    }

    private func rankedEntries(
        for queries: [String],
        limitPerQuery: Int,
        overallLimit: Int
    ) -> (entries: [TrustedSkillCatalogEntry], saturatedQueryCount: Int) {
        var fusedScores: [String: Double] = [:]
        var byKey: [String: TrustedSkillCatalogEntry] = [:]
        var saturatedQueryCount = 0
        let searchContext = queries.joined(separator: " ").lowercased()
        for query in queries {
            let matches = entries.compactMap { entry -> (TrustedSkillCatalogEntry, Int)? in
                if let owner = DiscoveryAuthorIdentity.ownerQuery(query) {
                    return DiscoveryAuthorIdentity.matches(repository: entry.repository, owner: owner) ? (entry, 1) : nil
                }
                let score = Self.matchScore(entry, query: query, context: searchContext)
                return score > 0 ? (entry, score) : nil
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.trust != $1.0.trust { return $0.0.trust == .official }
                return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
            }
            if matches.count > limitPerQuery { saturatedQueryCount += 1 }
            for (rank, match) in matches.prefix(limitPerQuery).enumerated() {
                let key = Self.key(match.0)
                byKey[key] = match.0
                fusedScores[key, default: 0] += 1.0 / Double(60 + rank)
            }
        }
        let sortedKeys = byKey.keys.sorted {
            let left = fusedScores[$0] ?? 0
            let right = fusedScores[$1] ?? 0
            if left != right { return left > right }
            guard let leftEntry = byKey[$0], let rightEntry = byKey[$1] else { return $0 < $1 }
            if leftEntry.trust != rightEntry.trust { return leftEntry.trust == .official }
            return leftEntry.name.localizedStandardCompare(rightEntry.name) == .orderedAscending
        }
        if sortedKeys.count > overallLimit, saturatedQueryCount == 0 { saturatedQueryCount = 1 }
        return (
            sortedKeys.prefix(overallLimit).compactMap { byKey[$0] },
            saturatedQueryCount
        )
    }

    private static func matchScore(
        _ entry: TrustedSkillCatalogEntry,
        query: String,
        context: String
    ) -> Int {
        let normalizedQuery = query.lowercased()
        let name = entry.name.lowercased()
        let description = entry.description.lowercased()
        let path = entry.path.lowercased()
        let material = "\(name) \(description) \(path)"
        let wantsGeneralSecurityReview = ["安全", "漏洞", "security", "vulnerability"].contains(where: context.contains)
            && !context.contains("mcp")
        if wantsGeneralSecurityReview, material.contains("mcp ") || name.hasPrefix("mcp-") { return 0 }

        let wantsWebsiteAccessibility = ["网站", "website", "web accessibility"].contains(where: context.contains)
            && ["无障碍", "accessibility"].contains(where: context.contains)
        if wantsWebsiteAccessibility,
           description.contains("data visual"),
           !description.contains("website"),
           !description.contains("web application")
        { return 0 }

        let presentationTerms = ["ppt", "pptx", "演示", "幻灯片", "presentation", "slide deck"]
        let creationTerms = ["从零", "新的", "新建", "创建", "制作", "net-new", "new presentation", "create", "make"]
        let wantsNewPresentation = presentationTerms.contains(where: context.contains)
            && creationTerms.contains(where: context.contains)
        if wantsNewPresentation {
            let directlyCreatesPresentation = name == "pptx"
                || (description.contains("create on-brand") && description.contains("presentation"))
                || (description.contains("create any visual design") && description.contains("presentations"))
                || (description.contains("lay out and export") && description.contains("powerpoint"))
            if !directlyCreatesPresentation { return 0 }
        }

        let wantsExcelAnalysis = context.contains("excel")
            && ["分析", "analysis", "analyze", "chart"].contains(where: context.contains)
        if wantsExcelAnalysis,
           !["excel", "xlsx", "spreadsheet", "workbook"].contains(where: material.contains)
        { return 0 }

        // Cross-language expansion may add "web research" to a website task. That
        // recall helper must not rewrite a concrete QA/accessibility goal into a
        // generic research request and then filter its real matches away.
        let hasConcreteNonResearchGoal = wantsGeneralSecurityReview
            || wantsWebsiteAccessibility
            || wantsNewPresentation
            || wantsExcelAnalysis
            || ["登录", "login flow", "software testing", "test automation", "quality assurance"]
                .contains(where: context.contains)
        let wantsGeneralResearch = !hasConcreteNonResearchGoal
            && ["调研", "研究", "deep research", "research"].contains(where: context.contains)
            && !["代码库", "安全", "漏洞", "广告", "竞品", "财报", "公司", "医学", "生命科学", "产品体验"]
                .contains(where: context.contains)
        if wantsGeneralResearch {
            let directlyGeneral = ["deep research", "general research", "web research", "academic research"]
                .contains(where: material.contains)
            let specialized = [
                "ux research", "digital product", "life-sciences", "notion", "nvidia ai-q", "programming task",
                "codebase", "security scan", "competitor", "paid ads", "earnings", "financial",
            ].contains(where: material.contains)
            if !directlyGeneral || specialized { return 0 }
        }

        let wantsPDFReading = context.contains("pdf")
            && ["读取", "整理", "阅读", "提取", "read", "extract", "summarize"].contains(where: context.contains)
        if wantsPDFReading {
            let canReadPDF = name == "pdf"
                || ["read", "extract", "ocr", "document processing", "pdf-to-md"].contains(where: material.contains)
            if !canReadPDF { return 0 }
        }

        let ignored = Set(["agent", "skill", "skills", "workflow", "with", "from", "that", "this", "一个", "帮我", "制作"])
        let latin = normalizedQuery.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !ignored.contains($0) }
        var terms = latin
        let chinese = Array(normalizedQuery.filter { character in
            character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        })
        if chinese.count >= 2 {
            terms.append(contentsOf: (0..<(chinese.count - 1)).map { String(chinese[$0...$0 + 1]) }.filter { !ignored.contains($0) })
        }
        var score = 0
        if name == normalizedQuery { score += 200 }
        if description.contains(normalizedQuery), normalizedQuery.count >= 3 { score += 100 }
        for term in Set(terms) {
            if name.contains(term) { score += 40 }
            if description.contains(term) { score += 14 }
            if path.contains(term) { score += 8 }
        }
        if wantsGeneralSecurityReview, description.contains("codebase security scanner") { score += 180 }
        if wantsWebsiteAccessibility,
           description.contains("test this website"),
           description.contains("accessibility")
        { score += 180 }
        if wantsNewPresentation,
           description.contains("creating slide decks"),
           description.contains(".pptx")
        { score += 180 }
        if wantsExcelAnalysis,
           entry.trust == .official,
           description.contains("charting")
        { score += 120 }
        if entry.trust == .official, score > 0 { score += 4 }
        return score
    }

    private func verifiedCandidate(for entry: TrustedSkillCatalogEntry) async -> DiscoveryCandidate? {
        guard let document = await skillDocument(entry),
              let candidate = Self.makeCandidate(entry: entry, document: document)
        else { return nil }
        return candidate
    }

    private func cachedCandidate(for entry: TrustedSkillCatalogEntry) async -> DiscoveryCandidate? {
        guard let document = await cache.document(
            repository: entry.repository, revision: entry.revision, path: entry.path, now: now()
        ) else { return nil }
        return Self.makeCandidate(entry: entry, document: document)
    }

    private static func makeCandidate(
        entry: TrustedSkillCatalogEntry,
        document: TrustedCatalogDocumentEvidence
    ) -> DiscoveryCandidate? {
        guard
              let frontmatter = DiscoverySkillDocumentParser.frontmatter(in: document.markdown),
              DiscoverySkillDocumentParser.nameMatchesPath(frontmatter.name, path: entry.path)
        else { return nil }
        let parent = entry.path.split(separator: "/").dropLast().joined(separator: "/")
        return .init(
            id: "github/\(entry.repository)/\(entry.path)",
            name: frontmatter.name,
            summary: frontmatter.description,
            repositoryFullName: entry.repository,
            skillPath: parent.isEmpty ? nil : parent,
            evidence: .init(
                skillSummary: frontmatter.description,
                skillDocumentExcerpt: String(document.markdown.prefix(DiscoveryEvaluationLimits.maximumPersistedSkillCharacters)),
                skillContentVerified: true,
                repositoryIsPrivate: false,
                skillDocumentURL: Self.rawURL(entry),
                fetchedAt: document.fetchedAt,
                sources: [.curatedCatalog, .github, .skillDocument],
                repositoryArchived: false,
                downloadable: true,
                catalogTrust: entry.trust
            )
        )
    }

    private func skillDocument(_ entry: TrustedSkillCatalogEntry) async -> TrustedCatalogDocumentEvidence? {
        let requestTime = now()
        if let cached = await cache.document(repository: entry.repository, revision: entry.revision, path: entry.path, now: requestTime) {
            return cached
        }
        guard let url = Self.rawURL(entry) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 256 * 1_024
        ),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let markdown = String(data: data, encoding: .utf8)
        else { return nil }
        let fetchedAt = now()
        await cache.insert(document: markdown, repository: entry.repository, revision: entry.revision, path: entry.path, now: fetchedAt)
        return .init(markdown: markdown, fetchedAt: fetchedAt)
    }

    private func repositoryMetadata(_ repository: String, token: String?) async -> TrustedCatalogRepositoryEvidence? {
        let requestTime = now()
        if let cached = await cache.repository(repository, now: requestTime) { return cached }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)") else { return nil }
        var metadata: TrustedCatalogRepositoryMetadata?
        if let token { metadata = await requestRepositoryMetadata(url: url, token: token) }
        if metadata == nil { metadata = await requestRepositoryMetadata(url: url, token: nil) }
        guard let metadata else { return nil }
        let fetchedAt = now()
        await cache.insert(metadata, now: fetchedAt)
        return .init(metadata: metadata, fetchedAt: fetchedAt)
    }

    private func requestRepositoryMetadata(url: URL, token: String?) async -> TrustedCatalogRepositoryMetadata? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await DiscoveryNetworkResponseLoader.data(
            for: request,
            session: session,
            maximumBytes: 512 * 1_024
        ),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrustedCatalogRepositoryMetadata.self, from: data)
    }

    private static func rawURL(_ entry: TrustedSkillCatalogEntry) -> URL? {
        var url = URL(string: "https://raw.githubusercontent.com")!
        for component in entry.repository.split(separator: "/") + [Substring(entry.revision)] + entry.path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private static func key(_ entry: TrustedSkillCatalogEntry) -> String {
        "\(entry.repository.lowercased())|\(entry.path.lowercased())"
    }

    static func bundledEntries() -> [TrustedSkillCatalogEntry] {
        let fileName = "trusted-skills-catalog-v1.json"
        var locations: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            locations.append(resourceURL.appendingPathComponent(fileName))
        }
        locations.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Sources/SkillBoxCore/Resources", isDirectory: true)
                .appendingPathComponent(fileName)
        )
        for url in locations {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(TrustedSkillCatalogSnapshot.self, from: data),
                  snapshot.version == 1
            else { continue }
            return snapshot.entries
        }
        return []
    }
}

enum DiscoverySkillDocumentParser {
    static func frontmatter(in markdown: String) -> (name: String, description: String)? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return nil }
        let frontmatter = Array(lines[1..<closing])
        guard let name = scalar("name", in: frontmatter),
              let description = scalar("description", in: frontmatter)
        else { return nil }
        return (name, description)
    }

    static func nameMatchesPath(_ name: String, path: String) -> Bool {
        if path == "SKILL.md" { return true }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        func normalize(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(parent) == normalize(name)
    }

    private static func scalar(_ key: String, in lines: [String]) -> String? {
        guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) else { return nil }
        let raw = lines[index].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["|", ">", "|-", ">-", "|+", ">+"].contains(trimmed) {
            let continuation = lines.dropFirst(index + 1).prefix { line in
                line.first?.isWhitespace == true || line.trimmingCharacters(in: .whitespaces).isEmpty
            }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let value = continuation.joined(separator: trimmed.hasPrefix(">") ? " " : "\n")
            return value.isEmpty ? nil : value
        }
        let value = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.isEmpty ? nil : value
    }
}
