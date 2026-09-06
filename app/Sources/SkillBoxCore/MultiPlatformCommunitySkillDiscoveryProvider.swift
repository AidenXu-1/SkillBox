import Foundation

public struct CommunityMediaSearchItem: Hashable, Sendable {
    public var id: String
    public var platform: DiscoveryCommunityPlatform
    public var author: String?
    public var title: String
    public var summary: String?
    public var url: URL
    public var engagement: Int?
    public var publishedAt: Date?

    public init(
        id: String,
        platform: DiscoveryCommunityPlatform,
        author: String? = nil,
        title: String,
        summary: String? = nil,
        url: URL,
        engagement: Int? = nil,
        publishedAt: Date? = nil
    ) {
        self.id = String(id.prefix(300))
        self.platform = platform
        self.author = author.map { String($0.prefix(120)) }
        self.title = String(title.prefix(400))
        self.summary = summary.map { String($0.prefix(1_200)) }
        self.url = url
        self.engagement = engagement
        self.publishedAt = publishedAt
    }

    var searchableText: String {
        [title, summary].compactMap { $0 }.joined(separator: "\n")
    }

    var mention: DiscoveryCommunityMention {
        .init(
            id: id,
            platform: platform,
            author: author,
            title: title,
            url: url,
            engagement: engagement,
            publishedAt: publishedAt
        )
    }
}

public protocol CommunityMediaSearchSource: Sendable {
    var platform: DiscoveryCommunityPlatform { get }
    func search(query: String, limit: Int) async throws -> [CommunityMediaSearchItem]
}

public protocol CommunityCommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
}

extension BoundedProcessRunner: CommunityCommandRunning {}

public enum CommunityMediaSourceError: Error, LocalizedError, Sendable {
    case toolUnavailable(String)
    case unsupportedPlatform(DiscoveryCommunityPlatform)
    case unreadableOutput(DiscoveryCommunityPlatform)
    case blocked(DiscoveryCommunityPlatform)

    public var errorDescription: String? {
        switch self {
        case let .toolUnavailable(tool): "这台 Mac 还没有可用的 \(tool)。"
        case let .unsupportedPlatform(platform): "\(platform.displayName) 暂时没有可用的只读搜索适配器。"
        case let .unreadableOutput(platform): "\(platform.displayName) 的搜索结果暂时无法核对。"
        case let .blocked(platform): "\(platform.displayName) 拒绝了这次公开搜索，本轮已跳过。"
        }
    }
}

public enum CommunityExternalToolLocator {
    public static func executable(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedEntries = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        for directory in pathEntries + fixedEntries where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public struct YTDLPCommunityMediaSearchSource: CommunityMediaSearchSource, Sendable {
    public let platform: DiscoveryCommunityPlatform = .youtube
    private let executablePath: String?
    private let runner: any CommunityCommandRunning

    public init(
        executablePath: String? = CommunityExternalToolLocator.executable(named: "yt-dlp"),
        runner: any CommunityCommandRunning = BoundedProcessRunner(timeout: 55, maximumOutputBytes: 4 * 1_024 * 1_024)
    ) {
        self.executablePath = executablePath
        self.runner = runner
    }

    public func search(query: String, limit: Int) async throws -> [CommunityMediaSearchItem] {
        guard let executablePath else { throw CommunityMediaSourceError.toolUnavailable("yt-dlp") }
        try Task.checkCancellation()
        if let context = DiscoveryNetworkResponseLoader.context {
            try await context.reserveExternalToolInvocation()
        }
        try Task.checkCancellation()
        let boundedLimit = min(max(limit, 1), 10)
        let search = "ytsearch\(boundedLimit):\(query)"
        let evidenceFields = "%(.{id,title,uploader,channel,webpage_url,original_url,view_count,description,upload_date})j"
        let output = try await runner.run(
            executablePath,
            arguments: [
                "--ignore-config",
                "--no-cookies",
                "--no-cookies-from-browser",
                "--no-cache-dir",
                "--skip-download",
                "--no-warnings",
                "--playlist-end", String(boundedLimit),
                "--print", evidenceFields,
                search,
            ]
        )
        return try Self.decodeItems(output)
    }

    static func decodeItems(_ output: String) throws -> [CommunityMediaSearchItem] {
        let rows: [[String: Any]] = output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
            return root as? [String: Any]
        }
        guard !rows.isEmpty else { throw CommunityMediaSourceError.unreadableOutput(.youtube) }
        return rows.compactMap { row in
            guard let title = cleanString(row["title"]), !title.isEmpty,
                  let rawURL = cleanString(row["webpage_url"] ?? row["original_url"] ?? row["url"]),
                  let parsedURL = URL(string: rawURL)
            else { return nil }
            let url = canonicalPublicURL(parsedURL, platform: .youtube)
            return .init(
                id: stableID(platform: .youtube, url: url),
                platform: .youtube,
                author: cleanString(row["uploader"] ?? row["channel"]),
                title: title,
                summary: cleanString(row["description"]),
                url: url,
                engagement: parseCount(row["view_count"]),
                publishedAt: cleanString(row["upload_date"]).flatMap(parseCompactDate)
            )
        }
    }
}

public enum CommunitySkillNameExtractor {
    private static let blockedNames: Set<String> = [
        "agent", "agents", "ai", "best", "claude", "codex", "complete", "creating", "custom", "favorite",
        "free", "github", "guide", "musthave", "openai", "recommended", "skill", "skills", "that", "the",
        "these", "this", "those", "tool", "tools", "top", "useful", "using", "workflow", "writing", "your",
        "http", "https", "www", "com",
    ]

    public static func exactNames(in item: CommunityMediaSearchItem) -> [String] {
        let text = item.searchableText
        var results: [String] = []
        var seen = Set<String>()
        let patterns: [(value: String, allowsLowercase: Bool)] = [
            (#"[\u0060\"“”「」『』]([A-Za-z][A-Za-z0-9_.-]{1,63})[\u0060\"“”「」『』]\s*(?:Agent\s+)?Skills?\b"#, true),
            (#"[\u0060\"“”「」『』]([\u4E00-\u9FFF][\u4E00-\u9FFFA-Za-z0-9_.-]{1,31})[\u0060\"“”「」『』]\s*(?:Agent\s+)?Skills?\b"#, true),
            (#"\b([A-Za-z][A-Za-z0-9_.-]{1,63})\s+(?:Agent\s+)?Skills?\b"#, false),
            (#"\bSkills?\s*(?:called|named|叫|名为|[:：])\s*[\u0060\"“”「」『』]?([A-Za-z][A-Za-z0-9_.-]{1,63})"#, true),
            (#"\b([A-Za-z][A-Za-z0-9_.-]{1,63})\s*,?\s+(?:is\s+)?(?:a\s+)?(?:free\s+)?(?:Claude\s+)?Skills?\b"#, false),
        ]
        if item.title.localizedCaseInsensitiveContains("skill") {
            let leadingPattern = #"^\s*([A-Za-z][A-Za-z0-9_.-]{1,63})\s*[:：]"#
            if let regex = try? NSRegularExpression(pattern: leadingPattern),
               let match = regex.firstMatch(in: item.title, range: NSRange(item.title.startIndex..<item.title.endIndex, in: item.title)),
               let matchRange = Range(match.range(at: 1), in: item.title)
            {
                let candidate = String(item.title[matchRange])
                let normalized = normalize(candidate)
                if isSpecific(candidate, normalized: normalized, allowsLowercase: false), seen.insert(normalized).inserted {
                    results.append(candidate)
                }
            }

            if let colon = item.title.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let listed = String(item.title[item.title.index(after: colon)...])
                let separators = CharacterSet(charactersIn: "、，,|/")
                let parts = listed.components(separatedBy: separators)
                if parts.count >= 2 {
                    let itemPattern = #"^\s*[\u0060\"\u201c\u201d「」『』]?([A-Za-z][A-Za-z0-9_.-]{1,63})"#
                    if let regex = try? NSRegularExpression(pattern: itemPattern) {
                        for part in parts {
                            let range = NSRange(part.startIndex..<part.endIndex, in: part)
                            guard let match = regex.firstMatch(in: part, range: range),
                                  let matchRange = Range(match.range(at: 1), in: part)
                            else { continue }
                            let candidate = String(part[matchRange])
                            let normalized = normalize(candidate)
                            guard isSpecific(candidate, normalized: normalized, allowsLowercase: false),
                                  seen.insert(normalized).inserted
                            else { continue }
                            results.append(candidate)
                        }
                    }
                }
            }
        }
        let colonDelimitedTitlePattern = #"[:：]\s*([A-Za-z][A-Za-z0-9_.-]{1,63})\s*(?=[:：])"#
        if let regex = try? NSRegularExpression(pattern: colonDelimitedTitlePattern) {
            let range = NSRange(item.title.startIndex..<item.title.endIndex, in: item.title)
            for match in regex.matches(in: item.title, range: range) where match.numberOfRanges > 1 {
                guard let matchRange = Range(match.range(at: 1), in: item.title) else { continue }
                let candidate = String(item.title[matchRange])
                let normalized = normalize(candidate)
                guard isSpecific(candidate, normalized: normalized, allowsLowercase: true),
                      seen.insert(normalized).inserted
                else { continue }
                results.append(candidate)
            }
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.value, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
                let candidate = String(text[matchRange])
                let normalized = normalize(candidate)
                guard isSpecific(candidate, normalized: normalized, allowsLowercase: pattern.allowsLowercase),
                      seen.insert(normalized).inserted
                else { continue }
                results.append(candidate)
            }
        }
        if item.title.localizedCaseInsensitiveContains("skill"), let summary = item.summary {
            let listPattern = #"(?m)^\s*(?:[-*•]|\d+[.)、]|(?:\d{1,2}:){1,2}\d{2})\s*[\u0060\"“”「」『』]?([A-Za-z][A-Za-z0-9_.-]{1,63})"#
            if let regex = try? NSRegularExpression(pattern: listPattern) {
                let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
                for match in regex.matches(in: summary, range: range) where match.numberOfRanges > 1 {
                    guard let matchRange = Range(match.range(at: 1), in: summary) else { continue }
                    let candidate = String(summary[matchRange])
                    let normalized = normalize(candidate)
                    guard isSpecific(candidate, normalized: normalized, allowsLowercase: true),
                          seen.insert(normalized).inserted
                    else { continue }
                    results.append(candidate)
                }
            }

            let inlineListPattern = #"(?:^|[\s；;])\d+[.)、]\s*[\u0060\"“”「」『』]?([A-Za-z][A-Za-z0-9_.-]{1,63})(?:\s+[-—–]\s*|\s*[:：]\s*)"#
            if let regex = try? NSRegularExpression(pattern: inlineListPattern) {
                let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
                for match in regex.matches(in: summary, range: range) where match.numberOfRanges > 1 {
                    guard let matchRange = Range(match.range(at: 1), in: summary) else { continue }
                    let candidate = String(summary[matchRange])
                    let normalized = normalize(candidate)
                    guard isSpecific(candidate, normalized: normalized, allowsLowercase: true),
                          seen.insert(normalized).inserted
                    else { continue }
                    results.append(candidate)
                }
            }
        }
        return results.prefix(8).map { $0 }
    }

    static func normalize(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func isSpecific(_ value: String, normalized: String, allowsLowercase: Bool) -> Bool {
        guard normalized.count >= 3, !blockedNames.contains(normalized) else { return false }
        if value.contains("-") || value.contains("_") { return true }
        if allowsLowercase { return normalized.count >= 5 }
        return value.first?.isUppercase == true && normalized.count >= 4
    }
}

public struct MultiPlatformCommunitySkillDiscoveryProvider: SkillDiscoveryProvider, Sendable {
    private struct MediaSearchTimeout: Error, Sendable {}

    private struct Reference: Sendable {
        var repository: String?
        var linkedPath: String?
        var skillName: String?
        var mention: DiscoveryCommunityMention
    }

    private struct MediaSearchOutcome: Sendable {
        var sourceIndex: Int
        var queryIndex: Int
        var platform: DiscoveryCommunityPlatform
        var items: [CommunityMediaSearchItem]?
    }

    private let sources: [any CommunityMediaSearchSource]
    private let repositoryResolver: any SkillDiscoveryProvider
    private let sourceTimeout: Duration

    public init(
        sources: [any CommunityMediaSearchSource],
        repositoryResolver: any SkillDiscoveryProvider,
        sourceTimeout: Duration = .seconds(45)
    ) {
        self.sources = sources
        self.repositoryResolver = repositoryResolver
        self.sourceTimeout = sourceTimeout
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

        let sourceLimit = min(max(limitPerQuery, 1), 12)
        let mediaQueries = Self.mediaQueries(from: cleanQueries)
        var items: [CommunityMediaSearchItem] = []
        var failedSourceCount = 0
        var failedQueryCount = 0
        var saturatedQueryCount = 0
        var unavailablePlatforms = Self.disabledPlatformsNamed(in: cleanQueries)
        let outcomes = try await withThrowingTaskGroup(of: MediaSearchOutcome.self) { group in
            for (sourceIndex, source) in sources.enumerated() {
                let sourceQueries = mediaQueries
                for (queryIndex, query) in sourceQueries.enumerated() {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let found = try await Self.search(
                                source: source,
                                query: Self.communityQuery(query),
                                limit: sourceLimit,
                                timeout: sourceTimeout
                            )
                            try Task.checkCancellation()
                            return .init(
                                sourceIndex: sourceIndex,
                                queryIndex: queryIndex,
                                platform: source.platform,
                                items: found
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as URLError where error.code == .cancelled {
                            throw CancellationError()
                        } catch {
                            return .init(
                                sourceIndex: sourceIndex,
                                queryIndex: queryIndex,
                                platform: source.platform,
                                items: nil
                            )
                        }
                    }
                }
            }
            var values: [MediaSearchOutcome] = []
            for try await outcome in group { values.append(outcome) }
            return values.sorted {
                ($0.sourceIndex, $0.queryIndex) < ($1.sourceIndex, $1.queryIndex)
            }
        }
        for (sourceIndex, source) in sources.enumerated() {
            let sourceOutcomes = outcomes.filter { $0.sourceIndex == sourceIndex }
            let completedQueries = sourceOutcomes.compactMap(\.items)
            let sourceFailedQueryCount = sourceOutcomes.count - completedQueries.count
            if completedQueries.isEmpty {
                failedSourceCount += 1
                unavailablePlatforms.insert(source.platform)
            } else {
                failedQueryCount += sourceFailedQueryCount
                for found in completedQueries {
                    if found.count >= sourceLimit { saturatedQueryCount += 1 }
                    items.append(contentsOf: found)
                }
            }
        }

        let deduplicatedItems = Self.deduplicate(items)
        let references = deduplicatedItems.flatMap(Self.references)
        let resolverQueries = Self.resolverQueries(for: references)
        guard !resolverQueries.isEmpty else {
            return .init(
                candidates: [],
                originalQueryCandidateIDs: [],
                failedSourceCount: failedSourceCount,
                failedQueryCount: failedQueryCount,
                saturatedQueryCount: saturatedQueryCount,
                unavailableCommunityPlatforms: unavailablePlatforms,
                unresolvedCommunityMentions: deduplicatedItems.map(\.mention)
            )
        }

        let resolved = try await repositoryResolver.search(
            queries: resolverQueries,
            limitPerQuery: min(max(limitPerQuery, 20), 160)
        )
        let repositoryCounts = Dictionary(grouping: resolved.candidates, by: { $0.repositoryFullName.lowercased() })
            .mapValues(\.count)
        let verifiedCandidates = resolved.candidates.filter(\.evidence.skillContentVerified)
        let uniquelyBoundNameReferences = Set(references.compactMap { reference -> String? in
            guard reference.repository == nil, reference.skillName != nil else { return nil }
            let matches = verifiedCandidates.filter {
                Self.matches(reference, candidate: $0, repositoryCandidateCount: 0)
            }
            return matches.count == 1 ? Self.referenceKey(reference) : nil
        })
        var matchedMentionIDs = Set<String>()
        var candidates: [DiscoveryCandidate] = []
        for candidate in verifiedCandidates {
            let matching = references.filter {
                if $0.repository == nil, !uniquelyBoundNameReferences.contains(Self.referenceKey($0)) {
                    return false
                }
                return Self.matches($0, candidate: candidate, repositoryCandidateCount: repositoryCounts[candidate.repositoryFullName.lowercased()] ?? 0)
            }
            guard !matching.isEmpty else { continue }
            matchedMentionIDs.formUnion(matching.map { $0.mention.id.lowercased() })
            var updated = candidate
            updated.evidence.sources.insert(.communityMedia)
            updated.evidence.communityMentions = Self.diverseMentions(matching.map(\.mention))
            candidates.append(updated)
        }
        let unresolvedMentions = deduplicatedItems
            .map(\.mention)
            .filter { !matchedMentionIDs.contains($0.id.lowercased()) }
        return .init(
            candidates: candidates,
            originalQueryCandidateIDs: Set(candidates.map(\.id)),
            failedSourceCount: failedSourceCount + resolved.failedSourceCount,
            failedQueryCount: failedQueryCount + resolved.failedQueryCount,
            saturatedQueryCount: saturatedQueryCount + resolved.saturatedQueryCount,
            failedCandidateVerificationCount: resolved.failedCandidateVerificationCount,
            deferredCandidateVerificationCount: resolved.deferredCandidateVerificationCount,
            rateLimitedUntil: resolved.rateLimitedUntil,
            unavailableCommunityPlatforms: unavailablePlatforms.union(resolved.unavailableCommunityPlatforms),
            unresolvedCommunityMentions: unresolvedMentions
        )
    }

    private static func search(
        source: any CommunityMediaSearchSource,
        query: String,
        limit: Int,
        timeout: Duration
    ) async throws -> [CommunityMediaSearchItem] {
        try await withThrowingTaskGroup(of: [CommunityMediaSearchItem].self) { group in
            group.addTask {
                try await source.search(query: query, limit: limit)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MediaSearchTimeout()
            }
            guard let first = try await group.next() else {
                throw CommunityMediaSourceError.unreadableOutput(source.platform)
            }
            group.cancelAll()
            return first
        }
    }

    private static func communityQuery(_ query: String) -> String {
        let containsChinese = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        return containsChinese ? "\(query) Agent Skill 推荐" : "\(query) Agent Skill recommendation"
    }

    private static func disabledPlatformsNamed(in queries: [String]) -> Set<DiscoveryCommunityPlatform> {
        let text = queries.joined(separator: "\n").lowercased()
        var platforms = Set<DiscoveryCommunityPlatform>()
        if ["小红书", "xiaohongshu", "rednote"].contains(where: text.contains) { platforms.insert(.xiaohongshu) }
        if ["抖音", "douyin"].contains(where: text.contains) { platforms.insert(.douyin) }
        return platforms
    }

    private static func mediaQueries(from queries: [String]) -> [String] {
        guard let first = queries.first else { return [] }
        var selected = [first]
        if let crossLanguage = queries.dropFirst().first(where: {
            $0.unicodeScalars.allSatisfy { $0.value < 128 }
        }), crossLanguage.caseInsensitiveCompare(first) != .orderedSame {
            selected.append(crossLanguage)
        }
        return selected
    }

    private static func references(from item: CommunityMediaSearchItem) -> [Reference] {
        var values: [Reference] = []
        let urls = [item.url] + gitHubURLs(in: item.searchableText)
        for url in urls {
            guard let identity = repositoryIdentity(from: url) else { continue }
            values.append(.init(
                repository: identity.repository,
                linkedPath: identity.path,
                skillName: nil,
                mention: item.mention
            ))
        }
        for name in CommunitySkillNameExtractor.exactNames(in: item) {
            values.append(.init(repository: nil, linkedPath: nil, skillName: name, mention: item.mention))
        }
        return values
    }

    private static func resolverQueries(for references: [Reference]) -> [String] {
        var seen = Set<String>()
        return references.compactMap { reference in
            let value: String?
            if let repository = reference.repository {
                value = "repo:\(repository)"
            } else {
                value = reference.skillName
            }
            guard let value, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(12).map { $0 }
    }

    private static func referenceKey(_ reference: Reference) -> String {
        "\(reference.mention.id.lowercased())|\(CommunitySkillNameExtractor.normalize(reference.skillName ?? ""))"
    }

    private static func matches(_ reference: Reference, candidate: DiscoveryCandidate, repositoryCandidateCount: Int) -> Bool {
        if let repository = reference.repository {
            guard repository.caseInsensitiveCompare(candidate.repositoryFullName) == .orderedSame else { return false }
            if let linkedPath = reference.linkedPath, let skillPath = candidate.skillPath {
                let link = linkedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                let skill = skillPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                return link == skill || link.hasSuffix(skill)
            }
            if repositoryCandidateCount == 1 { return true }
            return CommunitySkillNameExtractor.exactNames(in: .init(
                id: reference.mention.id,
                platform: reference.mention.platform,
                title: reference.mention.title,
                url: reference.mention.url
            )).contains { CommunitySkillNameExtractor.normalize($0) == CommunitySkillNameExtractor.normalize(candidate.name) }
        }
        guard let skillName = reference.skillName else { return false }
        let clue = CommunitySkillNameExtractor.normalize(skillName)
        let candidateName = CommunitySkillNameExtractor.normalize(candidate.name)
        if clue == candidateName { return true }
        let pathName = candidate.skillPath?.split(separator: "/").last.map(String.init) ?? ""
        return !pathName.isEmpty && clue == CommunitySkillNameExtractor.normalize(pathName)
    }

    private static func gitHubURLs(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[^\s\"'<>),\]]*"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[matchRange]))
        }
    }

    private static func repositoryIdentity(from url: URL) -> (repository: String, path: String?)? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        let blocked = Set(["topics", "search", "login", "marketplace", "features", "sponsors", "settings"])
        let owner = components[0]
        let repository = components[1].replacingOccurrences(of: ".git", with: "")
        guard !blocked.contains(owner.lowercased()), !repository.isEmpty else { return nil }
        var path: String?
        if components.count >= 5, ["tree", "blob"].contains(components[2]) {
            let tail = components.dropFirst(4)
            let value = tail.last == "SKILL.md" ? tail.dropLast().joined(separator: "/") : tail.joined(separator: "/")
            path = value.isEmpty ? nil : value
        }
        return ("\(owner)/\(repository)", path)
    }

    private static func deduplicate(_ items: [CommunityMediaSearchItem]) -> [CommunityMediaSearchItem] {
        var seen = Set<String>()
        return items.filter { seen.insert("\($0.platform.rawValue)|\($0.id.lowercased())").inserted }
    }

    private static func diverseMentions(_ mentions: [DiscoveryCommunityMention]) -> [DiscoveryCommunityMention] {
        DiscoveryCommunityMentionSelection.select(mentions)
    }
}

private func cleanString(_ value: Any?) -> String? {
    guard let value else { return nil }
    let text = (value as? String) ?? String(describing: value)
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "<null>" ? nil : cleaned
}

private func parseCount(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return max(0, number.intValue) }
    guard var text = cleanString(value)?.replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
    else { return nil }
    let multiplier: Double
    if text.hasSuffix("亿") {
        text.removeLast(); multiplier = 100_000_000
    } else if text.hasSuffix("万") {
        text.removeLast(); multiplier = 10_000
    } else if text.hasSuffix("m") {
        text.removeLast(); multiplier = 1_000_000
    } else if text.hasSuffix("k") {
        text.removeLast(); multiplier = 1_000
    } else {
        multiplier = 1
    }
    guard let number = Double(text), number.isFinite else { return nil }
    return max(0, Int((number * multiplier).rounded()))
}

private func parseCompactDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd"
    return formatter.date(from: value)
}

private func canonicalPublicURL(_ url: URL, platform: DiscoveryCommunityPlatform) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.fragment = nil
    if platform == .xiaohongshu {
        components.query = nil
    } else if platform == .youtube {
        components.queryItems = components.queryItems?.filter { $0.name == "v" }
    }
    return components.url ?? url
}

private func stableID(platform: DiscoveryCommunityPlatform, url: URL) -> String {
    "\(platform.rawValue)/\(String(url.absoluteString.prefix(240)))"
}
