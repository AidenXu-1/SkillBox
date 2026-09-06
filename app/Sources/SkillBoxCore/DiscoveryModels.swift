import Foundation

public enum DiscoveryCandidateState: String, Codable, Hashable, Sendable { case notTried, trying, notSuitable }
public enum DiscoveryCandidateTier: String, Codable, Hashable, Sendable { case recommended, other }
public enum DiscoveryEvidenceSource: String, Codable, Hashable, Sendable { case skillsSh, github, skillDocument, curatedCatalog, communityMedia, localSafety }
public enum DiscoveryCatalogTrust: String, Codable, Hashable, Sendable { case official, curated }

public enum DiscoveryCommunityPlatform: String, Codable, Hashable, Sendable {
    case hackerNews
    case youtube
    case bilibili
    case wechat
    case xiaohongshu
    case douyin

    public var displayName: String {
        switch self {
        case .hackerNews: "Hacker News"
        case .youtube: "YouTube"
        case .bilibili: "B 站"
        case .wechat: "公众号"
        case .xiaohongshu: "小红书"
        case .douyin: "抖音"
        }
    }
}

public struct DiscoveryCommunityMention: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var platform: DiscoveryCommunityPlatform
    public var author: String?
    public var title: String
    public var url: URL
    public var engagement: Int?
    public var publishedAt: Date?

    public init(
        id: String,
        platform: DiscoveryCommunityPlatform,
        author: String? = nil,
        title: String,
        url: URL,
        engagement: Int? = nil,
        publishedAt: Date? = nil
    ) {
        self.id = id
        self.platform = platform
        self.author = author
        self.title = String(title.prefix(240))
        self.url = url
        self.engagement = engagement
        self.publishedAt = publishedAt
    }

    var normalizedAuthorIdentity: String? {
        let normalized = author?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

enum DiscoveryCommunityMentionSelection {
    static func select(_ mentions: [DiscoveryCommunityMention], limit: Int = 5) -> [DiscoveryCommunityMention] {
        var seenIDs = Set<String>()
        let unique = mentions
            .filter { seenIDs.insert($0.id.lowercased()).inserted }
            .sorted {
                let left = $0.engagement ?? 0
                let right = $1.engagement ?? 0
                if left != right { return left > right }
                return $0.id < $1.id
            }
        var selected: [DiscoveryCommunityMention] = []
        var selectedIDs = Set<String>()
        var platforms = Set<DiscoveryCommunityPlatform>()
        for mention in unique where selected.count < limit && platforms.insert(mention.platform).inserted {
            selected.append(mention)
            selectedIDs.insert(mention.id.lowercased())
        }
        var authors = Set(selected.compactMap(\.normalizedAuthorIdentity))
        for mention in unique where selected.count < limit && !selectedIDs.contains(mention.id.lowercased()) {
            guard let author = mention.normalizedAuthorIdentity,
                  authors.insert(author).inserted
            else { continue }
            selected.append(mention)
            selectedIDs.insert(mention.id.lowercased())
        }
        for mention in unique where selected.count < limit && selectedIDs.insert(mention.id.lowercased()).inserted {
            selected.append(mention)
        }
        return selected
    }
}

public struct DiscoveryCandidateEvidence: Codable, Hashable, Sendable {
    public var skillSummary: String?
    public var skillDocumentExcerpt: String?
    public var repositorySummary: String?
    public var skillContentVerified: Bool
    public var repositoryIsPrivate: Bool?
    public var skillDocumentURL: URL?
    public var fetchedAt: Date?
    public var sources: Set<DiscoveryEvidenceSource>
    public var repositoryArchived: Bool
    public var downloadable: Bool
    public var hasBlockingSafetyIssue: Bool
    public var catalogTrust: DiscoveryCatalogTrust?
    public var communityMentions: [DiscoveryCommunityMention]

    public init(
        skillSummary: String? = nil,
        skillDocumentExcerpt: String? = nil,
        repositorySummary: String? = nil,
        skillContentVerified: Bool = false,
        repositoryIsPrivate: Bool? = nil,
        skillDocumentURL: URL? = nil,
        fetchedAt: Date? = nil,
        sources: Set<DiscoveryEvidenceSource> = [],
        repositoryArchived: Bool = false,
        downloadable: Bool = true,
        hasBlockingSafetyIssue: Bool = false,
        catalogTrust: DiscoveryCatalogTrust? = nil,
        communityMentions: [DiscoveryCommunityMention] = []
    ) {
        self.skillSummary = skillSummary; self.skillDocumentExcerpt = skillDocumentExcerpt; self.repositorySummary = repositorySummary
        self.skillContentVerified = skillContentVerified; self.repositoryIsPrivate = repositoryIsPrivate
        self.skillDocumentURL = skillDocumentURL; self.fetchedAt = fetchedAt
        self.sources = sources; self.repositoryArchived = repositoryArchived; self.downloadable = downloadable
        self.hasBlockingSafetyIssue = hasBlockingSafetyIssue
        self.catalogTrust = catalogTrust
        self.communityMentions = DiscoveryCommunityMentionSelection.select(communityMentions)
    }

    private enum CodingKeys: String, CodingKey {
        case skillSummary, skillDocumentExcerpt, repositorySummary, skillContentVerified, repositoryIsPrivate, skillDocumentURL, fetchedAt
        case sources, repositoryArchived, downloadable, hasBlockingSafetyIssue, catalogTrust, communityMentions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        skillSummary = try values.decodeIfPresent(String.self, forKey: .skillSummary)
        skillDocumentExcerpt = try values.decodeIfPresent(String.self, forKey: .skillDocumentExcerpt)
        repositorySummary = try values.decodeIfPresent(String.self, forKey: .repositorySummary)
        skillContentVerified = try values.decodeIfPresent(Bool.self, forKey: .skillContentVerified) ?? false
        repositoryIsPrivate = try values.decodeIfPresent(Bool.self, forKey: .repositoryIsPrivate)
        skillDocumentURL = try values.decodeIfPresent(URL.self, forKey: .skillDocumentURL)
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        sources = try values.decodeIfPresent(Set<DiscoveryEvidenceSource>.self, forKey: .sources) ?? []
        repositoryArchived = try values.decodeIfPresent(Bool.self, forKey: .repositoryArchived) ?? false
        downloadable = try values.decodeIfPresent(Bool.self, forKey: .downloadable) ?? true
        hasBlockingSafetyIssue = try values.decodeIfPresent(Bool.self, forKey: .hasBlockingSafetyIssue) ?? false
        catalogTrust = try values.decodeIfPresent(DiscoveryCatalogTrust.self, forKey: .catalogTrust)
        communityMentions = DiscoveryCommunityMentionSelection.select(
            try values.decodeIfPresent([DiscoveryCommunityMention].self, forKey: .communityMentions) ?? []
        )
    }

    public var independentCommunityAuthorCount: Int {
        Set(communityMentions.compactMap(\.normalizedAuthorIdentity)).count
    }

    public var communityPlatformCount: Int {
        Set(communityMentions.map(\.platform)).count
    }

    public var communityEngagement: Int {
        communityMentions.reduce(0) { $0 + max(0, $1.engagement ?? 0) }
    }

    public var communityPopularitySignal: Int {
        let strongestByPlatform = Dictionary(grouping: communityMentions, by: \.platform).mapValues { mentions in
            mentions.map { max(0, $0.engagement ?? 0) }.max() ?? 0
        }
        return strongestByPlatform.values.reduce(0) { total, engagement in
            total + Int((log10(Double(engagement) + 1) * 100).rounded())
        }
    }

}

public struct DiscoveryCandidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String?
    public var summaryIsRepositoryLevel: Bool
    public var repositoryFullName: String
    public var skillPath: String?
    public var installCount: Int?
    public var installCountText: String?
    public var repositoryStars: Int?
    public var repositoryStarsText: String?
    public var repositoryStarsFetchedAt: Date?
    public var repositoryUpdatedAt: Date?
    public var state: DiscoveryCandidateState
    public var tier: DiscoveryCandidateTier
    public var recommendationReason: String?
    public var suitableWhen: String?
    public var examplePrompt: String?
    public var experienceSteps: [String]
    public var limitations: [String]
    public var usageGuide: SkillUsageGuide?
    public var usageGuideSourceDigest: String?
    public var evidence: DiscoveryCandidateEvidence

    public init(
        id: String, name: String, summary: String? = nil, summaryIsRepositoryLevel: Bool = false,
        repositoryFullName: String, skillPath: String? = nil, installCount: Int? = nil,
        repositoryStars: Int? = nil, repositoryStarsFetchedAt: Date? = nil, repositoryUpdatedAt: Date? = nil,
        state: DiscoveryCandidateState = .notTried, tier: DiscoveryCandidateTier = .other,
        recommendationReason: String? = nil, suitableWhen: String? = nil, examplePrompt: String? = nil,
        experienceSteps: [String] = [], limitations: [String] = [], usageGuide: SkillUsageGuide? = nil,
        usageGuideSourceDigest: String? = nil,
        evidence: DiscoveryCandidateEvidence = .init()
    ) {
        self.id = id; self.name = name; self.summary = summary; self.summaryIsRepositoryLevel = summaryIsRepositoryLevel
        self.repositoryFullName = repositoryFullName; self.skillPath = skillPath; self.installCount = installCount
        self.repositoryStars = repositoryStars; self.repositoryStarsFetchedAt = repositoryStarsFetchedAt
        self.repositoryUpdatedAt = repositoryUpdatedAt; self.state = state; self.tier = tier
        self.recommendationReason = recommendationReason; self.suitableWhen = suitableWhen; self.examplePrompt = examplePrompt
        self.experienceSteps = experienceSteps; self.limitations = limitations; self.usageGuide = usageGuide
        self.usageGuideSourceDigest = usageGuideSourceDigest; self.evidence = evidence
    }

    public var userFacingSummary: String? {
        let value = evidence.skillSummary ?? (summaryIsRepositoryLevel ? nil : summary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    /// Rounded public counts must not silently cross the 500-install threshold.
    /// For example 0.5K may represent 450, while 5.8K is safely at least 5750.
    public var verifiedInstallCountLowerBound: Int {
        if let installCount { return max(0, installCount) }
        guard let text = installCountText?.replacingOccurrences(of: ",", with: ""),
              text.range(of: #"^[0-9]+(?:\.[0-9]+)?[KM]?$"#, options: .regularExpression) != nil
        else { return 0 }
        let multiplier: Double = text.hasSuffix("M") ? 1_000_000 : (text.hasSuffix("K") ? 1_000 : 1)
        let number = multiplier == 1 ? text : String(text.dropLast())
        guard let value = Double(number), value.isFinite else { return 0 }
        let decimals = number.split(separator: ".").dropFirst().first?.count ?? 0
        let uncertainty = multiplier == 1 ? 0 : 0.5 * multiplier / pow(10, Double(decimals))
        let minimum = floor(max(0, value * multiplier - uncertainty))
        guard minimum < Double(Int.max) else { return 0 }
        return Int(minimum)
    }

    public var repositorySummary: String? { evidence.repositorySummary ?? (summaryIsRepositoryLevel ? summary : nil) }
    public var repositoryURL: URL? { URL(string: "https://github.com/\(repositoryFullName)") }
    public var importURL: URL? {
        guard let repositoryURL else { return nil }
        guard let skillPath, !skillPath.isEmpty else { return repositoryURL }
        return repositoryURL.appendingPathComponent("tree").appendingPathComponent("HEAD").appending(path: skillPath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, summaryIsRepositoryLevel, repositoryFullName, skillPath, installCount
        case installCountText, repositoryStars, repositoryStarsText, repositoryStarsFetchedAt, repositoryUpdatedAt, state, tier, recommendationReason
        case suitableWhen, examplePrompt, experienceSteps, limitations, usageGuide, usageGuideSourceDigest, evidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        summaryIsRepositoryLevel = try values.decodeIfPresent(Bool.self, forKey: .summaryIsRepositoryLevel) ?? false
        repositoryFullName = try values.decode(String.self, forKey: .repositoryFullName)
        skillPath = try values.decodeIfPresent(String.self, forKey: .skillPath)
        installCount = try values.decodeIfPresent(Int.self, forKey: .installCount)
        installCountText = try values.decodeIfPresent(String.self, forKey: .installCountText)
        repositoryStars = try values.decodeIfPresent(Int.self, forKey: .repositoryStars)
        repositoryStarsText = try values.decodeIfPresent(String.self, forKey: .repositoryStarsText)
        repositoryStarsFetchedAt = try values.decodeIfPresent(Date.self, forKey: .repositoryStarsFetchedAt)
        repositoryUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .repositoryUpdatedAt)
        state = try values.decodeIfPresent(DiscoveryCandidateState.self, forKey: .state) ?? .notTried
        tier = try values.decodeIfPresent(DiscoveryCandidateTier.self, forKey: .tier) ?? .other
        recommendationReason = try values.decodeIfPresent(String.self, forKey: .recommendationReason)
        suitableWhen = try values.decodeIfPresent(String.self, forKey: .suitableWhen)
        examplePrompt = try values.decodeIfPresent(String.self, forKey: .examplePrompt)
        experienceSteps = try values.decodeIfPresent([String].self, forKey: .experienceSteps) ?? []
        limitations = try values.decodeIfPresent([String].self, forKey: .limitations) ?? []
        usageGuide = try values.decodeIfPresent(SkillUsageGuide.self, forKey: .usageGuide)
        usageGuideSourceDigest = try values.decodeIfPresent(String.self, forKey: .usageGuideSourceDigest)
        evidence = try values.decodeIfPresent(DiscoveryCandidateEvidence.self, forKey: .evidence) ?? .init(
            skillSummary: summaryIsRepositoryLevel ? nil : summary,
            repositorySummary: summaryIsRepositoryLevel ? summary : nil,
            skillContentVerified: false
        )
    }
}

public enum DiscoveryMessageRole: String, Codable, Hashable, Sendable { case user, assistant }
public enum DiscoveryMessageState: String, Codable, Hashable, Sendable { case pending, complete, failed }
public enum DiscoveryRunState: String, Codable, Hashable, Sendable {
    case understanding, recalling, verifying, evaluating
    case completed, partiallyCompleted, failed, interrupted

    public var isActive: Bool {
        switch self {
        case .understanding, .recalling, .verifying, .evaluating: true
        case .completed, .partiallyCompleted, .failed, .interrupted: false
        }
    }
}

public enum DiscoveryNoticeKind: String, Codable, Hashable, Sendable { case information, partialResult, recovery, failure }

public struct DiscoverySystemNotice: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var runID: UUID?
    public var text: String
    public var createdAt: Date
    public var kind: DiscoveryNoticeKind

    public init(id: UUID = UUID(), runID: UUID? = nil, text: String, createdAt: Date = Date(), kind: DiscoveryNoticeKind = .information) {
        self.id = id; self.runID = runID; self.text = text; self.createdAt = createdAt; self.kind = kind
    }
}

public struct DiscoveryMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var role: DiscoveryMessageRole
    public var text: String
    public var createdAt: Date
    public var providerID: String?
    public var model: String?
    public var state: DiscoveryMessageState
    public var origin: String?
    public var references: [DiscoveryConversationReference]?
    public init(id: UUID = UUID(), role: DiscoveryMessageRole, text: String, createdAt: Date = Date(), providerID: String? = nil, model: String? = nil, state: DiscoveryMessageState = .complete) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
        self.providerID = providerID; self.model = model; self.state = state
    }
}

public struct DiscoveryIntent: Codable, Hashable, Sendable {
    public var goal: String
    public var mustHaves: [String]
    public var preferences: [String]
    public var exclusions: [String]
    public var route: DiscoverySearchRoute
    public var targets: [DiscoveryTarget]
    public init(
        goal: String,
        mustHaves: [String] = [],
        preferences: [String] = [],
        exclusions: [String] = [],
        route: DiscoverySearchRoute = .scenario,
        targets: [DiscoveryTarget] = []
    ) {
        self.goal = goal; self.mustHaves = mustHaves; self.preferences = preferences; self.exclusions = exclusions
        self.route = route; self.targets = targets
    }

    private enum CodingKeys: String, CodingKey {
        case goal, mustHaves, preferences, exclusions, route, targets
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decodeIfPresent(String.self, forKey: .goal) ?? ""
        mustHaves = try values.decodeIfPresent([String].self, forKey: .mustHaves) ?? []
        preferences = try values.decodeIfPresent([String].self, forKey: .preferences) ?? []
        exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        route = try values.decodeIfPresent(DiscoverySearchRoute.self, forKey: .route) ?? .scenario
        targets = try values.decodeIfPresent([DiscoveryTarget].self, forKey: .targets) ?? []
    }
}

public struct DiscoveryPlan: Codable, Hashable, Sendable {
    public var intent: DiscoveryIntent
    public var queries: [String]
    public var needsClarification: Bool
    public var clarifyingQuestion: String?
    public init(intent: DiscoveryIntent, queries: [String], needsClarification: Bool = false, clarifyingQuestion: String? = nil) {
        self.intent = intent; self.queries = queries; self.needsClarification = needsClarification; self.clarifyingQuestion = clarifyingQuestion
    }
}

public struct DiscoveryRecommendation: Codable, Hashable, Sendable {
    public var candidateID: String
    public var tier: DiscoveryCandidateTier
    public var reason: String
    public var evidenceQuote: String?
    public var suitableWhen: String?
    public var examplePrompt: String?
    public var experienceSteps: [String]
    public var limitations: [String]
    public var usageGuide: SkillUsageGuide?
    public init(candidateID: String, tier: DiscoveryCandidateTier, reason: String, evidenceQuote: String? = nil, suitableWhen: String? = nil, examplePrompt: String? = nil, experienceSteps: [String] = [], limitations: [String] = [], usageGuide: SkillUsageGuide? = nil) {
        self.candidateID = candidateID; self.tier = tier; self.reason = reason; self.suitableWhen = suitableWhen
        self.evidenceQuote = evidenceQuote
        self.examplePrompt = examplePrompt; self.experienceSteps = Array(experienceSteps.prefix(5)); self.limitations = limitations
        self.usageGuide = usageGuide
    }
}

public struct DiscoveryEvaluation: Codable, Hashable, Sendable {
    public var reply: String
    public var recommendations: [DiscoveryRecommendation]
    public init(reply: String, recommendations: [DiscoveryRecommendation]) { self.reply = reply; self.recommendations = recommendations }
}

public struct DiscoverySearchRun: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var queries: [String]
    public var recommendedCandidateIDs: [String]
    public var otherCandidateIDs: [String]
    public var usedAI: Bool
    public var route: DiscoverySearchRoute
    public var outcome: DiscoveryRouteOutcome?
    public var retryAfter: Date?
    public var requestUsage: DiscoveryRequestUsage?
    public var fallbackReason: String?
    public var state: DiscoveryRunState
    public var diagnostics: [AIInvocationDiagnostic]
    public var retrievedCandidateCount: Int?
    public var evaluationCandidateCount: Int?
    public var failedSourceCount: Int
    public var failedQueryCount: Int
    public var saturatedQueryCount: Int
    public var failedCandidateVerificationCount: Int
    public var deferredCandidateVerificationCount: Int
    public var requestedLimitPerQuery: Int
    public var semanticEvaluatedCandidateIDs: [String]
    public var semanticRecommendedCandidateIDs: [String]
    public var unresolvedCommunityMentions: [DiscoveryCommunityMention]
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        queries: [String],
        recommendedCandidateIDs: [String] = [],
        otherCandidateIDs: [String] = [],
        usedAI: Bool = false,
        route: DiscoverySearchRoute = .scenario,
        outcome: DiscoveryRouteOutcome? = nil,
        retryAfter: Date? = nil,
        fallbackReason: String? = nil,
        state: DiscoveryRunState = .completed,
        diagnostics: [AIInvocationDiagnostic] = [],
        retrievedCandidateCount: Int? = nil,
        evaluationCandidateCount: Int? = nil,
        failedSourceCount: Int = 0,
        failedQueryCount: Int = 0,
        saturatedQueryCount: Int = 0,
        failedCandidateVerificationCount: Int = 0,
        deferredCandidateVerificationCount: Int = 0,
        requestedLimitPerQuery: Int = 0,
        semanticEvaluatedCandidateIDs: [String] = [],
        semanticRecommendedCandidateIDs: [String] = [],
        unresolvedCommunityMentions: [DiscoveryCommunityMention] = []
    ) {
        self.id = id; self.createdAt = createdAt; self.queries = queries; self.recommendedCandidateIDs = recommendedCandidateIDs
        self.otherCandidateIDs = otherCandidateIDs; self.usedAI = usedAI; self.fallbackReason = fallbackReason
        self.route = route; self.outcome = outcome
        self.retryAfter = retryAfter
        self.state = state; self.diagnostics = diagnostics
        self.retrievedCandidateCount = retrievedCandidateCount; self.evaluationCandidateCount = evaluationCandidateCount
        self.failedSourceCount = failedSourceCount; self.failedQueryCount = failedQueryCount
        self.saturatedQueryCount = saturatedQueryCount
        self.failedCandidateVerificationCount = failedCandidateVerificationCount
        self.deferredCandidateVerificationCount = deferredCandidateVerificationCount
        self.requestedLimitPerQuery = requestedLimitPerQuery
        self.semanticEvaluatedCandidateIDs = semanticEvaluatedCandidateIDs
        self.semanticRecommendedCandidateIDs = semanticRecommendedCandidateIDs
        self.unresolvedCommunityMentions = DiscoveryCommunityMentionSelection.select(
            unresolvedCommunityMentions,
            limit: 8
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, queries, recommendedCandidateIDs, otherCandidateIDs, usedAI, route, outcome, retryAfter, requestUsage, fallbackReason, state, diagnostics
        case retrievedCandidateCount, evaluationCandidateCount, failedSourceCount, failedQueryCount
        case saturatedQueryCount, failedCandidateVerificationCount, deferredCandidateVerificationCount, requestedLimitPerQuery
        case semanticEvaluatedCandidateIDs, semanticRecommendedCandidateIDs, unresolvedCommunityMentions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        queries = try values.decodeIfPresent([String].self, forKey: .queries) ?? []
        recommendedCandidateIDs = try values.decodeIfPresent([String].self, forKey: .recommendedCandidateIDs) ?? []
        otherCandidateIDs = try values.decodeIfPresent([String].self, forKey: .otherCandidateIDs) ?? []
        usedAI = try values.decodeIfPresent(Bool.self, forKey: .usedAI) ?? false
        route = try values.decodeIfPresent(DiscoverySearchRoute.self, forKey: .route) ?? .scenario
        outcome = try values.decodeIfPresent(DiscoveryRouteOutcome.self, forKey: .outcome)
        retryAfter = try values.decodeIfPresent(Date.self, forKey: .retryAfter)
        requestUsage = try values.decodeIfPresent(DiscoveryRequestUsage.self, forKey: .requestUsage)
        fallbackReason = try values.decodeIfPresent(String.self, forKey: .fallbackReason)
        state = try values.decodeIfPresent(DiscoveryRunState.self, forKey: .state) ?? .completed
        diagnostics = try values.decodeIfPresent([AIInvocationDiagnostic].self, forKey: .diagnostics) ?? []
        retrievedCandidateCount = try values.decodeIfPresent(Int.self, forKey: .retrievedCandidateCount)
        evaluationCandidateCount = try values.decodeIfPresent(Int.self, forKey: .evaluationCandidateCount)
        failedSourceCount = try values.decodeIfPresent(Int.self, forKey: .failedSourceCount) ?? 0
        failedQueryCount = try values.decodeIfPresent(Int.self, forKey: .failedQueryCount) ?? 0
        saturatedQueryCount = try values.decodeIfPresent(Int.self, forKey: .saturatedQueryCount) ?? 0
        failedCandidateVerificationCount = try values.decodeIfPresent(Int.self, forKey: .failedCandidateVerificationCount) ?? 0
        deferredCandidateVerificationCount = try values.decodeIfPresent(Int.self, forKey: .deferredCandidateVerificationCount) ?? 0
        requestedLimitPerQuery = try values.decodeIfPresent(Int.self, forKey: .requestedLimitPerQuery) ?? 0
        semanticEvaluatedCandidateIDs = try values.decodeIfPresent([String].self, forKey: .semanticEvaluatedCandidateIDs) ?? []
        semanticRecommendedCandidateIDs = try values.decodeIfPresent([String].self, forKey: .semanticRecommendedCandidateIDs) ?? []
        unresolvedCommunityMentions = DiscoveryCommunityMentionSelection.select(
            try values.decodeIfPresent([DiscoveryCommunityMention].self, forKey: .unresolvedCommunityMentions) ?? [],
            limit: 8
        )
    }
}

// Retained only to migrate v1 records.
public struct DiscoveryTurn: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var userText: String
    public var effectiveQuery: String
    public var createdAt: Date
    public init(id: UUID = UUID(), userText: String, effectiveQuery: String, createdAt: Date = Date()) {
        self.id = id; self.userText = userText; self.effectiveQuery = effectiveQuery; self.createdAt = createdAt
    }
}

public struct DiscoverySession: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var storageFolderName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [DiscoveryTurn]
    public var messages: [DiscoveryMessage]
    public var intent: DiscoveryIntent?
    public var runs: [DiscoverySearchRun]
    public var notices: [DiscoverySystemNotice]
    public var candidates: [DiscoveryCandidate]
    public var selectedCandidateID: String?
    public var contextStartMessageID: UUID?
    public var pendingClarification: String?
    public var continuationInvalidated: Bool?
    public var queuedMessages: [DiscoveryQueuedMessage] = []
    public init(id: UUID = UUID(), title: String, storageFolderName: String, createdAt: Date = Date(), updatedAt: Date = Date(), turns: [DiscoveryTurn] = [], messages: [DiscoveryMessage] = [], intent: DiscoveryIntent? = nil, runs: [DiscoverySearchRun] = [], notices: [DiscoverySystemNotice] = [], candidates: [DiscoveryCandidate] = [], selectedCandidateID: String? = nil) {
        self.id = id; self.title = title; self.storageFolderName = storageFolderName; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.turns = turns; self.messages = messages; self.intent = intent; self.runs = runs; self.notices = notices; self.candidates = candidates; self.selectedCandidateID = selectedCandidateID
    }
    public var effectiveQuery: String? { runs.last?.queries.first ?? turns.last?.effectiveQuery }
    public var recommendedCandidates: [DiscoveryCandidate] { candidates.filter { $0.tier == .recommended } }
    public var otherCandidates: [DiscoveryCandidate] { candidates.filter { $0.tier == .other } }
    private enum CodingKeys: String, CodingKey { case id, title, storageFolderName, createdAt, updatedAt, turns, messages, intent, runs, notices, candidates, selectedCandidateID, contextStartMessageID, pendingClarification, continuationInvalidated, queuedMessages }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); title = try values.decode(String.self, forKey: .title)
        storageFolderName = try values.decode(String.self, forKey: .storageFolderName)
        createdAt = try values.decode(Date.self, forKey: .createdAt); updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        turns = try values.decodeIfPresent([DiscoveryTurn].self, forKey: .turns) ?? []
        messages = try values.decodeIfPresent([DiscoveryMessage].self, forKey: .messages) ?? []
        intent = try values.decodeIfPresent(DiscoveryIntent.self, forKey: .intent)
        runs = try values.decodeIfPresent([DiscoverySearchRun].self, forKey: .runs) ?? []
        notices = try values.decodeIfPresent([DiscoverySystemNotice].self, forKey: .notices) ?? []
        candidates = try values.decodeIfPresent([DiscoveryCandidate].self, forKey: .candidates) ?? []
        selectedCandidateID = try values.decodeIfPresent(String.self, forKey: .selectedCandidateID)
        contextStartMessageID = try values.decodeIfPresent(UUID.self, forKey: .contextStartMessageID)
        pendingClarification = try values.decodeIfPresent(String.self, forKey: .pendingClarification)
        continuationInvalidated = try values.decodeIfPresent(Bool.self, forKey: .continuationInvalidated)
        queuedMessages = try values.decodeIfPresent([DiscoveryQueuedMessage].self, forKey: .queuedMessages) ?? []
    }

}

public struct DiscoveryResultPresentation: Hashable, Sendable {
    public var title: String
    public var explanation: String
    public var candidateListTitle: String
    public var coverageTitle: String
    public var coverageDetails: [String]
    public var hasRecommendations: Bool

    public init?(session: DiscoverySession) {
        guard let run = session.runs.last, !run.state.isActive else { return nil }
        let count = session.recommendedCandidates.count
        hasRecommendations = count > 0 && (run.state == .completed || run.state == .partiallyCompleted)
        candidateListTitle = "推荐 \(count) 个"
        coverageTitle = "查看本轮覆盖情况"

        if run.state == .failed {
            title = count > 0 ? "这轮没有完成，已保留 \(count) 个已有推荐" : "这轮没有完成"
            explanation = "可以重试；已有候选和寻找记录没有被删除。"
        } else if run.state == .interrupted {
            title = count > 0 ? "这轮已停止，已保留 \(count) 个已有推荐" : "这轮已停止"
            explanation = "已有候选和寻找记录没有被删除。"
        } else if count > 0 {
            title = "找到 \(count) 个值得优先看的 Skill"
            if run.route == .exact {
                explanation = "这些结果都已核对真实 SKILL.md，并与点名的 Skill 精确匹配。"
            } else {
                explanation = "这些结果都已核对真实 SKILL.md，并且有公开使用量、官方来源或多人推荐作为质量依据。"
            }
        } else if run.state == .partiallyCompleted {
            title = "暂时无法完成核验"
            if let retryAfter = run.retryAfter {
                explanation = "GitHub 暂时限制了查询，可在 \(retryAfter.formatted(date: .omitted, time: .shortened)) 后重试。这不代表 Skill 不存在。"
            } else {
                explanation = "公开来源尚未查完，暂时不能判断有没有合适的 Skill。请稍后重试，或补充具体的 Skill 名称。"
            }
        } else if run.outcome == .exactNotFound {
            title = "没有找到完全匹配的 Skill"
            explanation = "没有用名称相似但并非同一个的 Skill 代替。"
        } else {
            title = "这轮没有找到足够可靠的推荐"
            explanation = "找到的线索还没有同时通过用途、真实 SKILL.md 和公开质量依据核对。"
        }
        if let conditionSummary = DiscoveryConstraintAssessment.summary(candidates: session.candidates, intent: session.intent) {
            explanation += " " + conditionSummary
        }

        let noticeDetails = session.notices
            .filter { $0.runID == run.id && $0.kind == .partialResult }
            .map(\.text)
        coverageDetails = ([run.fallbackReason] + noticeDetails.map(Optional.some))
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, detail in
                if !result.contains(detail) { result.append(detail) }
            }
        if let usage = run.requestUsage {
            coverageDetails.append("本轮直接资料请求 \(usage.networkRequests) 次，其中 GitHub API 查询 \(usage.githubAPIRequests) 次；重复资料复用了 \(usage.reusedRequests) 次。")
            if usage.externalToolInvocations > 0 {
                coverageDetails.append("另发起 \(usage.externalToolInvocations) 次外部媒体工具调用；工具内部网络请求数量未知，未计入上面的直接请求数。")
            }
        }
        coverageDetails += DiscoveryConstraintAssessment.details(candidates: session.candidates, intent: session.intent)
    }
}

public struct DiscoveryPopularityPresentation: Hashable, Sendable {
    public let skillUsageLabel = "Skill 使用量"
    public let repositoryStarsLabel = "GitHub 仓库热度"
    public var skillUsageValue: String
    public var repositoryStarsValue: String

    public init(installCount: Int?, repositoryStars: Int?) {
        skillUsageValue = installCount.map { "\(Self.compact($0)) 次安装" } ?? "暂无公开数据"
        repositoryStarsValue = repositoryStars.map { "\(Self.compact($0)) Stars" } ?? "暂无公开数据"
    }

    public init(candidate: DiscoveryCandidate) {
        self.init(installCount: candidate.installCount, repositoryStars: candidate.repositoryStars)
        if candidate.installCount == nil, let text = candidate.installCountText {
            skillUsageValue = "\(text) 次安装"
        }
        if candidate.repositoryStars == nil, let text = candidate.repositoryStarsText {
            repositoryStarsValue = "\(text) Stars"
        }
    }

    private static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

public enum DiscoverySearchFeedback {
    public static func incompleteNotice(
        for result: DiscoveryBatchSearchResult,
        canSearchDeeper: Bool = true
    ) -> String? {
        var parts: [String] = []
        if (result.requestUsage?.budgetBlockedRequests ?? 0) > 0 {
            parts.append("本轮已达到查询预算，已停止追加请求并保留核验结果。可以稍后重试，或提供具体仓库地址。")
        }
        if result.failedSourceCount > 0 {
            let names = result.unavailableCommunityPlatforms
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.displayName)
                .joined(separator: "、")
            if names.isEmpty {
                parts.append("本轮有 \(result.failedSourceCount) 个公开来源暂时未完成，已保留其他来源中核对通过的结果。")
            } else {
                let unnamedCount = max(0, result.failedSourceCount - result.unavailableCommunityPlatforms.count)
                let unnamed = unnamedCount > 0 ? "，另有 \(unnamedCount) 个公开来源未完成" : ""
                parts.append("本轮的 \(names) 暂时未参与\(unnamed)，已保留其他来源中核对通过的结果。")
            }
        }
        if result.failedQueryCount > 0 {
            parts.append("本轮有 \(result.failedQueryCount) 个搜索词暂时查询失败，已保留其他搜索词的有效结果。")
        }
        if result.saturatedQueryCount > 0 {
            if canSearchDeeper {
                parts.append("本轮有 \(result.saturatedQueryCount) 个搜索词已读到当前上限，后面还可能有未核对的结果，可以继续深挖。")
            } else {
                parts.append("本轮有 \(result.saturatedQueryCount) 个搜索词已到免费公开来源允许的最深范围；若仍不理想，请换成更具体的能力或交付物再找。")
            }
        }
        if result.failedCandidateVerificationCount > 0 {
            parts.append("有 \(result.failedCandidateVerificationCount) 个候选的实时 SKILL.md 未能完成核验，没有把它们混入可信结果。")
        }
        if result.deferredCandidateVerificationCount > 0 {
            parts.append("还有 \(result.deferredCandidateVerificationCount) 个候选在免费请求预算外，继续深挖会从下一批开始核验。")
        }
        if !result.unresolvedCommunityMentions.isEmpty {
            let examples = result.unresolvedCommunityMentions.prefix(2).map {
                "\($0.platform.displayName)《\(String($0.title.prefix(60)))》"
            }.joined(separator: "、")
            parts.append("已找到 \(result.unresolvedCommunityMentions.count) 条社区讨论，但还不能确认对应哪一个真实 Skill，暂未混入推荐：\(examples)。")
        }
        if let retryAt = result.rateLimitedUntil {
            parts.append("GitHub 已触发免费查询限制，本轮已立即停止继续请求；可在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后继续深挖。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public struct DiscoverySearchResult: Sendable {
    public var candidates: [DiscoveryCandidate]
    public var fetchedAt: Date
    public var hasMoreResults: Bool
    public var failedCandidateVerificationCount: Int
    public var deferredCandidateVerificationCount: Int
    public var rateLimitedUntil: Date?
    public init(
        candidates: [DiscoveryCandidate],
        fetchedAt: Date = Date(),
        hasMoreResults: Bool = false,
        failedCandidateVerificationCount: Int = 0,
        deferredCandidateVerificationCount: Int = 0,
        rateLimitedUntil: Date? = nil
    ) {
        self.candidates = candidates
        self.fetchedAt = fetchedAt
        self.hasMoreResults = hasMoreResults
        self.failedCandidateVerificationCount = failedCandidateVerificationCount
        self.deferredCandidateVerificationCount = deferredCandidateVerificationCount
        self.rateLimitedUntil = rateLimitedUntil
    }
}

public struct DiscoveryBatchSearchResult: Sendable {
    public var requestUsage: DiscoveryRequestUsage?
    public var candidates: [DiscoveryCandidate]
    public var originalQueryCandidateIDs: Set<String>
    public var fetchedAt: Date
    public var failedSourceCount: Int
    public var failedQueryCount: Int
    public var saturatedQueryCount: Int
    public var failedCandidateVerificationCount: Int
    public var deferredCandidateVerificationCount: Int
    public var rateLimitedUntil: Date?
    public var unavailableCommunityPlatforms: Set<DiscoveryCommunityPlatform>
    public var unresolvedCommunityMentions: [DiscoveryCommunityMention]
    public init(
        candidates: [DiscoveryCandidate],
        originalQueryCandidateIDs: Set<String>,
        fetchedAt: Date = Date(),
        failedSourceCount: Int = 0,
        failedQueryCount: Int = 0,
        saturatedQueryCount: Int = 0,
        failedCandidateVerificationCount: Int = 0,
        deferredCandidateVerificationCount: Int = 0,
        rateLimitedUntil: Date? = nil,
        unavailableCommunityPlatforms: Set<DiscoveryCommunityPlatform> = [],
        unresolvedCommunityMentions: [DiscoveryCommunityMention] = []
    ) {
        self.candidates = candidates; self.originalQueryCandidateIDs = originalQueryCandidateIDs; self.fetchedAt = fetchedAt
        self.failedSourceCount = failedSourceCount
        self.failedQueryCount = failedQueryCount
        self.saturatedQueryCount = saturatedQueryCount
        self.failedCandidateVerificationCount = failedCandidateVerificationCount
        self.deferredCandidateVerificationCount = deferredCandidateVerificationCount
        self.rateLimitedUntil = rateLimitedUntil
        self.unavailableCommunityPlatforms = unavailableCommunityPlatforms
        self.unresolvedCommunityMentions = DiscoveryCommunityMentionSelection.select(
            unresolvedCommunityMentions,
            limit: 8
        )
    }

    public var isExhaustive: Bool {
        failedSourceCount == 0
            && failedQueryCount == 0
            && saturatedQueryCount == 0
            && failedCandidateVerificationCount == 0
            && deferredCandidateVerificationCount == 0
            && rateLimitedUntil == nil
            && unavailableCommunityPlatforms.isEmpty
            && unresolvedCommunityMentions.isEmpty
            && (requestUsage?.budgetBlockedRequests ?? 0) == 0
    }
}

public enum DiscoverySearchScope: Sendable, Equatable {
    case initial
    case deep

    public var limitPerQuery: Int {
        switch self {
        case .initial: 64
        case .deep: 160
        }
    }

    public func limitPerQuery(after previousLimit: Int) -> Int {
        guard self == .deep else { return limitPerQuery }
        return [160, 320, 640, 1_000].first(where: { $0 > previousLimit }) ?? 1_000
    }
}

public enum DiscoverySearchLimits {
    public static let maximumCandidatesPerProvider = 1_000
    public static let maximumMergedCandidates = 3_000
    public static let skillsShMaximumResultsPerQuery = 200

    public static func trustedCatalogVerificationLimit(for recallLimit: Int) -> Int {
        recallLimit > 0 ? 12 : 0
    }

    public static func githubVerificationLimit(for recallLimit: Int) -> Int {
        recallLimit > 0 ? 8 : 0
    }

    public static func skillsShDetailLimit(for recallLimit: Int) -> Int {
        recallLimit > 0 ? 12 : 0
    }
}

public actor GitHubDiscoveryRateLimitGate {
    public enum Resource: String, Hashable, Sendable {
        case core
        case search
        case codeSearch = "code_search"

        var localLimit: Int { self == .core ? 36 : 8 }
        var localWindow: TimeInterval { self == .core ? 3_600 : 60 }
        var anonymousReserve: Int { self == .core ? 12 : 2 }
    }

    private struct Bucket {
        var requests: [Date] = []
        var remaining: Int?
        var reset: Date?
        var retryAt: Date?
    }

    private var buckets: [Resource: Bucket] = [:]
    private var secondaryRetryAt: Date?

    public init() {}

    public nonisolated static func resource(for url: URL?) -> Resource {
        if url?.path == "/search/code" { return .codeSearch }
        if url?.path.hasPrefix("/search/") == true { return .search }
        return .core
    }

    func reserveDiscoveryRequest(authenticated: Bool, resource: Resource = .core, now: Date = Date()) -> Bool {
        guard activeRetryDate(for: resource, now: now) == nil else { return false }
        guard !authenticated else { return true }
        var bucket = buckets[resource, default: Bucket()]
        bucket.requests.removeAll { now.timeIntervalSince($0) >= resource.localWindow }
        if let reset = bucket.reset, reset <= now { bucket.remaining = nil; bucket.reset = nil }
        guard bucket.requests.count < resource.localLimit,
              (bucket.remaining ?? Int.max) > resource.anonymousReserve else {
            buckets[resource] = bucket
            return false
        }
        bucket.requests.append(now)
        if let remaining = bucket.remaining { bucket.remaining = remaining - 1 }
        buckets[resource] = bucket
        return true
    }

    @discardableResult
    func observeDiscoveryResponse(_ response: HTTPURLResponse, anonymous: Bool, now: Date = Date()) -> Date? {
        let resource = response.value(forHTTPHeaderField: "X-RateLimit-Resource")
            .flatMap { Resource(rawValue: $0.lowercased()) } ?? Self.resource(for: response.url)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
        let retryAt = observe(statusCode: response.statusCode, remaining: remaining, reset: reset,
                              retryAfter: response.value(forHTTPHeaderField: "Retry-After"), resource: resource, now: now)
        guard anonymous, let remaining, let value = Int(remaining),
              let reset, let seconds = TimeInterval(reset) else { return retryAt }
        let resetDate = Date(timeIntervalSince1970: seconds)
        var bucket = buckets[resource, default: Bucket()]
        // A slower response must not replenish a reservation already made by a
        // concurrent source, or replace a newer server window with an old one.
        if bucket.reset == nil || resetDate >= bucket.reset! {
            bucket.remaining = bucket.reset == resetDate ? min(bucket.remaining ?? value, value) : value
            bucket.reset = resetDate
        }
        buckets[resource] = bucket
        return retryAt
    }

    public func activeRetryDate(for resource: Resource? = nil, now: Date = Date()) -> Date? {
        if let secondaryRetryAt, secondaryRetryAt <= now { self.secondaryRetryAt = nil }
        for key in Array(buckets.keys) {
            if let retryAt = buckets[key]?.retryAt, retryAt <= now { buckets[key]?.retryAt = nil }
        }
        let primaryDates = resource.map { [buckets[$0]?.retryAt].compactMap { $0 } }
            ?? buckets.values.compactMap(\.retryAt)
        return (primaryDates + [secondaryRetryAt].compactMap { $0 }).max()
    }

    @discardableResult
    public func observe(
        statusCode: Int,
        remaining: String?,
        reset: String?,
        retryAfter: String?,
        resource: Resource = .core,
        now: Date = Date()
    ) -> Date? {
        var candidate: Date?
        let isRejection = statusCode == 403 || statusCode == 429
        let isSecondary = isRejection && (retryAfter != nil || remaining != "0")
        if isSecondary {
            let delay = retryAfter.flatMap(TimeInterval.init) ?? 60
            candidate = now.addingTimeInterval(max(1, delay))
            secondaryRetryAt = max(secondaryRetryAt ?? .distantPast, candidate!)
        } else if remaining == "0", let reset, let seconds = TimeInterval(reset) {
            candidate = Date(timeIntervalSince1970: seconds)
        } else if isRejection {
            candidate = now.addingTimeInterval(60)
        }
        if let candidate, !isSecondary {
            var bucket = buckets[resource, default: Bucket()]
            bucket.retryAt = max(bucket.retryAt ?? .distantPast, candidate)
            buckets[resource] = bucket
        }
        return candidate
    }
}

public enum DiscoveryEvaluationLimits {
    public static let maximumSearchQueries = 8
    public static let maximumCandidatesPerBatch = 6
    public static let maximumTotalCandidates = maximumCandidatesPerBatch
    public static let maximumCandidates = maximumCandidatesPerBatch
    public static let maximumEvidenceCharacters = 12_000
    public static let maximumOutputTokens = 1_500
    public static let maximumPlanningOutputTokens = 800
    public static let maximumPlanningInputCharacters = 2_000
    public static let maximumLazyGuideCharacters = 8_000
    public static let maximumPersistedSkillCharacters = 8_000
    public static let maximumUsageGuideInputCharacters = 12_000
    public static let maximumUsageGuideOutputTokens = 2_400
}

public protocol SkillDiscoveryProvider: Sendable {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult
}

public extension SkillDiscoveryProvider {
    func search(queries: [String], limitPerQuery: Int = 20) async throws -> DiscoveryBatchSearchResult {
        var merged: [String: DiscoveryCandidate] = [:]
        var order: [String] = []
        var originalIDs = Set<String>()
        var saturatedQueryCount = 0
        var failedCandidateVerificationCount = 0
        var deferredCandidateVerificationCount = 0
        var rateLimitedUntil: Date?
        for (queryIndex, query) in queries.enumerated() {
            let result = try await search(query: query, limit: limitPerQuery)
            if result.hasMoreResults { saturatedQueryCount += 1 }
            failedCandidateVerificationCount += result.failedCandidateVerificationCount
            deferredCandidateVerificationCount += result.deferredCandidateVerificationCount
            if let candidate = result.rateLimitedUntil, candidate > (rateLimitedUntil ?? .distantPast) {
                rateLimitedUntil = candidate
            }
            for candidate in result.candidates {
                let key = "\(candidate.repositoryFullName.lowercased())|\((candidate.skillPath ?? candidate.name).lowercased())"
                if merged[key] == nil { order.append(key); merged[key] = candidate }
                if queryIndex == 0 { originalIDs.insert(candidate.id) }
            }
        }
        return .init(
            candidates: order.compactMap { merged[$0] },
            originalQueryCandidateIDs: originalIDs,
            saturatedQueryCount: saturatedQueryCount,
            failedCandidateVerificationCount: failedCandidateVerificationCount,
            deferredCandidateVerificationCount: deferredCandidateVerificationCount,
            rateLimitedUntil: rateLimitedUntil
        )
    }
}

public enum DiscoveryIntentPlanner {
    public static func fallback(message: String, previous: DiscoveryIntent?) -> DiscoveryPlan {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let routing = DiscoveryRequestRouter.classify(message: text, previousIntent: previous)
        if routing.targets.isEmpty, let question = DiscoveryNamedSkillRequest.inspect(text).clarification {
            return .init(intent: .init(goal: text, route: .exact), queries: [], needsClarification: true, clarifyingQuestion: question)
        }
        let explicitRouting = DiscoveryRequestRouter.classify(message: text, previousIntent: nil)
        let previousRouting = previous.map {
            DiscoveryRequestRouter.classify(message: $0.goal, previousIntent: nil)
        }
        // A correction about the same author, or a name supplied within that
        // task, narrows its identity. It does not start a new task or remove the
        // author simply because the wording of this message is different.
        if var previous, !DiscoveryConversation.requestsSearch(text),
           !DiscoveryRequestRouter.explicitlyChangesTask(text) {
            let priorTargets = previous.targets.isEmpty ? (previousRouting?.targets ?? []) : previous.targets
            let priorAuthors = priorTargets.filter { $0.kind == .author }
            let nextAuthors = explicitRouting.targets.filter { $0.kind == .author }
            func owners(_ values: [DiscoveryTarget]) -> Set<String> {
                Set(values.map { (DiscoveryAuthorIdentity.owner(for: $0.value) ?? $0.value).lowercased() })
            }
            let sameAuthor = !priorAuthors.isEmpty && owners(priorAuthors) == owners(nextAuthors)
            let names = explicitRouting.targets.filter { $0.kind == .skillName }
            let isNamingReply = text.range(of: #"^(?:有(?:一)?(?:个|份|款)|还有|另一个|其中|名字叫|名称是|叫做|我说的是)"#, options: .regularExpression) != nil
            let isAuthorCorrection = text.range(of: #"(?:我记得|应该|不止|不只)|有[一二两三四五六七八九十几\d]+(?:个|份|款)"#, options: .regularExpression) != nil
            func retainingUserConditions(_ intent: DiscoveryIntent) -> DiscoveryIntent {
                var result = intent
                for clause in DiscoveryConversation.userConditionClauses(text) {
                    if DiscoveryConstraintAssessment.hasMandatoryLanguage(in: clause) {
                        if !result.mustHaves.contains(clause) { result.mustHaves.append(clause) }
                    } else if ["最好", "优先", "尽量"].contains(where: clause.hasPrefix), !result.preferences.contains(clause) {
                        result.preferences.append(clause)
                    }
                }
                return result
            }
            if !priorAuthors.isEmpty, !names.isEmpty, isNamingReply,
               nextAuthors.isEmpty || sameAuthor {
                previous.targets = names + priorAuthors
                previous.route = explicitRouting.route
                return .init(intent: retainingUserConditions(previous), queries: explicitRouting.executionQueries)
            }
            if sameAuthor, isAuthorCorrection, explicitRouting.targets.allSatisfy({ $0.kind == .author }) {
                previous.targets = priorTargets
                if previous.route == .scenario { previous.route = .hybrid }
                let retained = DiscoveryRoutingDecision(route: previous.route, targets: priorTargets, executionQueries: explicitRouting.executionQueries)
                return .init(intent: retainingUserConditions(previous), queries: routedQueries(retained, base: deterministicQueries(for: previous.goal, previous: previous)))
            }
        }
        let replacesTarget = !explicitRouting.targets.isEmpty
            && explicitRouting.targets != (previous?.targets.isEmpty == false ? previous?.targets : previousRouting?.targets)
        let qualityFeedback = ["质量不高", "质量不好", "不够好", "不知名", "更知名", "更优质", "质量高一点", "太少", "优质的", "知名的", "没找到", "继续深挖", "找得少"].contains { text.contains($0) }
        if qualityFeedback, !replacesTarget, !DiscoveryRequestRouter.explicitlyChangesTask(text), var previous {
            for preference in ["继续深挖更多来源", "优先用途匹配、来源可靠且有维护证据"] where !previous.preferences.contains(preference) {
                previous.preferences.append(preference)
            }
            previous.route = routing.route
            previous.targets = routing.targets
            let queries = routedQueries(
                routing,
                base: deterministicQueries(for: previous.goal, previous: previous)
            )
            return DiscoveryPlan(intent: previous, queries: queries)
        }
        let clauses = DiscoveryConversation.userConditionClauses(text)
        let hasUserRequirement = clauses.contains { DiscoveryConstraintAssessment.hasMandatoryLanguage(in: $0) }
        let isRequirementRefinement = hasUserRequirement && !DiscoveryConversation.requestsSearch(text)
            && !DiscoveryRequestRouter.explicitlyChangesTask(text)
        if var previous, (DiscoveryRequestRouter.isRefinement(text) || isRequirementRefinement), !replacesTarget
        {
            previous.route = routing.route
            previous.targets = routing.targets
            for clause in clauses {
                if DiscoveryConstraintAssessment.hasMandatoryLanguage(in: clause) {
                    if !previous.mustHaves.contains(clause) { previous.mustHaves.append(clause) }
                } else if !previous.preferences.contains(clause) { previous.preferences.append(clause) }
            }
            return DiscoveryPlan(
                intent: previous,
                queries: routedQueries(routing, base: deterministicQueries(for: previous.goal, previous: previous))
            )
        }
        let intent = DiscoveryIntent(goal: text, route: routing.route, targets: routing.targets)
        let queries = routedQueries(
            routing,
            base: deterministicQueries(for: text)
        )
        return DiscoveryPlan(intent: intent, queries: queries)
    }

    public static func reconcile(
        modelPlan: DiscoveryPlan,
        deterministicPlan: DiscoveryPlan
    ) -> DiscoveryPlan {
        if deterministicPlan.intent.route == .exact { return deterministicPlan }
        var result = modelPlan
        result.intent.goal = deterministicPlan.intent.goal
        result.intent.mustHaves = deterministicPlan.intent.mustHaves
        result.intent.preferences = Array(Set(deterministicPlan.intent.preferences
            + result.intent.preferences.flatMap(DiscoveryConversation.userConditionClauses).filter { !DiscoveryConstraintAssessment.hasMandatoryLanguage(in: $0) })).sorted()
        result.intent.exclusions = deterministicPlan.intent.exclusions
        result.intent.route = deterministicPlan.intent.route
        result.intent.targets = deterministicPlan.intent.targets
        let protectsHumanizingIntent = deterministicPlan.queries.contains("humanize writing")
        let broadHumanizingQueries = Set(["writingediting", "contentwritingworkflow", "bestwritingskills"])
        let combined = deterministicPlan.queries + modelPlan.queries
        result.queries = Array(combined.reduce(into: [String]()) { queries, value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = cleaned.lowercased().filter(\.isLetter)
            guard !cleaned.isEmpty,
                  !(protectsHumanizingIntent && broadHumanizingQueries.contains(normalized)),
                  !queries.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame })
            else { return }
            queries.append(cleaned)
        }.prefix(DiscoveryEvaluationLimits.maximumSearchQueries))
        return result
    }

    private static func routedQueries(
        _ routing: DiscoveryRoutingDecision,
        base: [String]
    ) -> [String] {
        let values = routing.route == .exact
            ? routing.executionQueries
            : base + routing.executionQueries
        return Array(values.reduce(into: [String]()) { result, query in
            if !result.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
                result.append(query)
            }
        }.prefix(DiscoveryEvaluationLimits.maximumSearchQueries))
    }

    private static func deterministicQueries(for goal: String, previous: DiscoveryIntent? = nil) -> [String] {
        guard !goal.isEmpty else { return [] }
        var queries = [goal]
        let compact = goal.lowercased().replacingOccurrences(of: " ", with: "")
        queries.append(contentsOf: protectedCreatorQueries(for: goal, previousIntent: previous))
        if previous?.targets.isEmpty != false {
            queries.append(contentsOf: TrustedSkillCatalogDiscoveryProvider.taskNames(for: goal))
        }
        let isHumanizingRequest = compact.contains("ai味")
            || compact.contains("去除ai")
            || compact.contains("去掉ai")
            || compact.contains("不像ai")
            || compact.contains("活人感")
            || compact.contains("humanize")
        if isHumanizingRequest {
            queries.append(contentsOf: ["humanize writing", "remove AI writing style", "natural writing rewrite"])
        }
        let expansions: [([String], [String])] = [
            (["ppt", "演示", "幻灯片"], ["presentation slides", "slide deck design"]),
            (["excel", "表格", "电子表格"], ["spreadsheet data analysis", "Excel automation"]),
            (["pdf"], ["PDF document processing"]),
            (["写作", "文案", "文章", "改写", "润色"], ["writing editing", "content writing workflow"]),
            (["视频", "剪辑", "口播"], ["video editing workflow", "video script production"]),
            (["图片", "绘图", "海报", "设计"], ["image design", "visual design workflow"]),
            (["数据", "分析", "报表"], ["data analysis", "analytics reporting"]),
            (["邮件", "邮箱"], ["email writing management"]),
            (["日历", "日程"], ["calendar scheduling"]),
            (["浏览器", "网页", "网站"], ["browser automation", "web research"]),
            (["安全", "漏洞", "审计", "攻击", "权限", "泄露密码", "泄露密钥", "泄密", "外泄", "登录凭证", "访问凭证", "越权", "被黑", "注入", "恶意代码", "发出去"], ["code security review", "vulnerability scanning", "application security audit"]),
            (["无障碍", "可访问性", "辅助功能", "键盘操作", "只用键盘", "键盘完成", "读屏", "屏幕阅读", "旁白", "色盲", "对比度", "焦点顺序", "tab键"], ["website accessibility audit", "inclusive design review", "web accessibility testing"]),
            (["代码审查", "代码评审", "code review"], ["code review", "source code quality review"]),
            (["测试", "回归", "质量保证"], ["software testing", "test automation", "quality assurance"]),
            (["调试", "排错", "报错", "故障"], ["systematic debugging", "root cause analysis"]),
            (["部署", "上线", "发布"], ["deployment automation", "release engineering"]),
            (["研究", "调研", "论文", "调查", "全面了解", "市场", "行业", "赛道", "趋势"], ["deep research", "academic research"]),
            (["小红书"], ["Xiaohongshu RedNote content"]),
            (["抖音"], ["Douyin short video content"]),
            (["公众号", "微信"], ["WeChat article publishing"]),
            (["swift", "macos", "ios"], ["Swift development", "SwiftUI development"]),
        ]
        for (triggers, values) in expansions where triggers.contains(where: compact.contains) {
            if isHumanizingRequest, values == ["writing editing", "content writing workflow"] {
                continue
            }
            queries.append(contentsOf: values)
        }
        return Array(queries.reduce(into: []) { result, query in
            if !result.contains(query) { result.append(query) }
        }.prefix(DiscoveryEvaluationLimits.maximumSearchQueries))
    }

    public static func protectedCreatorQueries(for message: String) -> [String] {
        protectedCreatorQueries(for: message, previousIntent: nil)
    }

    public static func protectedCreatorQueries(
        for message: String,
        previousIntent: DiscoveryIntent?
    ) -> [String] {
        let context = ([message] + [previousIntent?.goal] + (previousIntent?.mustHaves ?? []) + (previousIntent?.preferences ?? []))
            .compactMap { $0 }
            .joined(separator: " ")
        let compact = context.lowercased().replacingOccurrences(of: " ", with: "")
        guard compact.contains("卡兹克"), ["写作", "文案", "writer", "writing"].contains(where: compact.contains) else {
            return []
        }
        return ["KKKKhazix writer", "khazix-writer"]
    }
}

public struct DiscoveryRankedCandidates: Sendable { public var recommended: [DiscoveryCandidate]; public var other: [DiscoveryCandidate] }

public struct DiscoverySemanticRouting: Sendable {
    public var relevantCandidateIDs: Set<String>?
    public var evaluatedCandidateIDs: Set<String>?
    public var recommendedRanks: [String: Int]?

    public init(relevantCandidateIDs: Set<String>?, evaluatedCandidateIDs: Set<String>?, recommendedRanks: [String: Int]? = nil) {
        self.relevantCandidateIDs = relevantCandidateIDs
        self.evaluatedCandidateIDs = evaluatedCandidateIDs
        self.recommendedRanks = recommendedRanks
    }
}

public enum DiscoveryEvaluationBatcher {
    public static func nextEvaluationWindow(
        from candidates: [DiscoveryCandidate],
        excluding evaluatedCandidateIDs: Set<String>
    ) -> [DiscoveryCandidate] {
        Array(
            candidates.lazy
                .filter { !evaluatedCandidateIDs.contains($0.id) }
                .prefix(DiscoveryEvaluationLimits.maximumTotalCandidates)
        )
    }

    public static func preliminaryBatches(from candidates: [DiscoveryCandidate]) -> [[DiscoveryCandidate]] {
        let frontier = Array(candidates.prefix(DiscoveryEvaluationLimits.maximumTotalCandidates))
        guard !frontier.isEmpty else { return [] }
        let groupCount = Int(ceil(
            Double(frontier.count) / Double(DiscoveryEvaluationLimits.maximumCandidatesPerBatch)
        ))
        var groups = Array(repeating: [DiscoveryCandidate](), count: groupCount)
        for (index, candidate) in frontier.enumerated() {
            groups[index % groupCount].append(candidate)
        }
        return groups
    }

    public static func finalists(
        from evaluations: [DiscoveryEvaluation],
        candidates: [DiscoveryCandidate]
    ) -> [DiscoveryCandidate] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return evaluations.compactMap { evaluation in
            evaluation.recommendations.first(where: { $0.tier == .recommended })?.candidateID
        }.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }.prefix(DiscoveryEvaluationLimits.maximumCandidatesPerBatch).map { $0 }
    }

    public static func merge(
        preliminary: [DiscoveryEvaluation],
        final: DiscoveryEvaluation?
    ) -> DiscoveryEvaluation? {
        guard !preliminary.isEmpty || final != nil else { return nil }
        let finalistIDs = Set(final?.recommendations.map(\.candidateID) ?? [])
        var order: [String] = []
        var byID: [String: DiscoveryRecommendation] = [:]
        for evaluation in preliminary {
            for recommendation in evaluation.recommendations {
                if byID[recommendation.candidateID] == nil { order.append(recommendation.candidateID) }
                byID[recommendation.candidateID] = recommendation
            }
        }
        if let final {
            for recommendation in final.recommendations {
                if byID[recommendation.candidateID] == nil { order.append(recommendation.candidateID) }
                if byID[recommendation.candidateID]?.tier == .recommended,
                   recommendation.tier == .other
                {
                    // The final round orders group winners. It cannot erase a
                    // grounded positive result already established in a group.
                    continue
                }
                byID[recommendation.candidateID] = recommendation
            }
        }
        let finalOrder = (final?.recommendations.map(\.candidateID) ?? []) + order.filter { !finalistIDs.contains($0) }
        let recommendations = finalOrder.compactMap { byID[$0] }
        guard !recommendations.isEmpty else { return nil }
        return .init(
            reply: final?.reply ?? preliminary.last?.reply ?? "已完成候选比较。",
            recommendations: recommendations
        )
    }
}

public enum DiscoveryCandidateRanker {
    public static func rankExact(_ candidates: [DiscoveryCandidate]) -> DiscoveryRankedCandidates {
        let accepted = candidates.compactMap { candidate -> DiscoveryCandidate? in
            guard candidate.evidence.skillContentVerified,
                  candidate.userFacingSummary != nil,
                  !candidate.evidence.repositoryArchived,
                  candidate.evidence.downloadable,
                  !candidate.evidence.hasBlockingSafetyIssue
            else { return nil }
            var result = candidate
            result.tier = .recommended
            return result
        }.sorted {
            let leftUpdated = $0.repositoryUpdatedAt ?? .distantPast
            let rightUpdated = $1.repositoryUpdatedAt ?? .distantPast
            if leftUpdated != rightUpdated { return leftUpdated > rightUpdated }
            return $0.repositoryFullName.localizedStandardCompare($1.repositoryFullName) == .orderedAscending
        }
        return .init(recommended: accepted, other: [])
    }

    public static func rank(
        _ candidates: [DiscoveryCandidate],
        intent: DiscoveryIntent,
        originalQueryCandidateIDs: Set<String>,
        relevantCandidateIDs _: Set<String>? = nil,
        evaluatedCandidateIDs _: Set<String>? = nil,
        semanticRecommendationRanks: [String: Int]? = nil
    ) -> DiscoveryRankedCandidates {
        var recommended: [DiscoveryCandidate] = []; var other: [DiscoveryCandidate] = []
        let explicit = intent.targets.isEmpty
            ? DiscoveryRequestRouter.classify(message: intent.goal, previousIntent: nil).targets
            : intent.targets
        let identityTargets = explicit.filter { $0.kind != .author }
        for var candidate in candidates {
            if !identityTargets.isEmpty,
               !identityTargets.contains(where: { RoutedSkillDiscoveryProvider.matches($0, candidate: candidate) }) { continue }
            // Candidate-conditioned model output never creates relevance or
            // quality eligibility. It may only order candidates that already
            // pass these local, inspectable gates.
            let locallyRelevant = isRelevant(
                candidate,
                to: intent,
                originallyMatched: originalQueryCandidateIDs.contains(candidate.id)
            )
            guard candidate.evidence.skillContentVerified, candidate.userFacingSummary != nil,
                  !candidate.evidence.repositoryArchived, candidate.evidence.downloadable,
                  !candidate.evidence.hasBlockingSafetyIssue,
                  locallyRelevant
            else { continue }
            let installs = candidate.verifiedInstallCountLowerBound
            let hasPublicQualityEvidence = hasDeterministicQualityEvidence(candidate, installs: installs)
            let capabilityMismatch = isCapabilityMismatch(candidate, intent: intent)
            let isStrong = !capabilityMismatch
                && !containsCandidateInstructionInjection(candidate)
                && hasPublicQualityEvidence
                && DiscoveryConstraintAssessment(candidate: candidate, intent: intent).permitsRecommendation
            candidate.tier = isStrong ? .recommended : .other
            if isStrong { recommended.append(candidate) }
            else { other.append(candidate) }
        }
        recommended.sort {
            qualityOrder($0, $1, intent: intent, semanticRecommendationRanks: semanticRecommendationRanks)
        }
        other.sort { qualityOrder($0, $1, intent: intent) }
        return .init(recommended: recommended, other: other)
    }

    public static func candidatesForEvaluation(
        _ candidates: [DiscoveryCandidate],
        intent: DiscoveryIntent,
        allowPrivateSkillContent: Bool
    ) -> [DiscoveryCandidate] {
        candidates.filter { candidate in
            guard candidate.evidence.skillContentVerified,
                  candidate.userFacingSummary != nil,
                  allowPrivateSkillContent || candidate.evidence.repositoryIsPrivate == false,
                  !candidate.evidence.repositoryArchived,
                  candidate.evidence.downloadable,
                  !candidate.evidence.hasBlockingSafetyIssue,
                  !containsCandidateInstructionInjection(candidate),
                  !isCapabilityMismatch(candidate, intent: intent),
                  DiscoveryConstraintAssessment(candidate: candidate, intent: intent).permitsRecommendation,
                  isRelevant(candidate, to: intent, originallyMatched: true),
                  hasDeterministicQualityEvidence(candidate, installs: candidate.verifiedInstallCountLowerBound)
            else { return false }
            return true
        }.sorted { qualityOrder($0, $1, intent: intent) }
    }

    public static func semanticallyRecommendedCandidateIDs(from evaluation: DiscoveryEvaluation?) -> Set<String>? {
        guard let evaluation else { return nil }
        return Set(evaluation.recommendations.lazy.filter { $0.tier == .recommended }.map(\.candidateID))
    }

    public static func recommendationEvidenceIsGrounded(
        _ quote: String,
        candidate: DiscoveryCandidate,
        intent: DiscoveryIntent
    ) -> Bool {
        let cleanedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...240).contains(cleanedQuote.count) else { return false }
        let sourceMaterial = [candidate.userFacingSummary, candidate.evidence.skillDocumentExcerpt]
            .compactMap { $0 }
            .joined(separator: "\n")
        guard sourceMaterial.localizedCaseInsensitiveContains(cleanedQuote) else { return false }

        guard !containsCandidateInstructionInjection(candidate) else { return false }

        let ignored = Set(["agent", "skill", "skills", "workflow", "find", "suitable", "help", "with", "the", "for"])
        let intentTerms = expandedLatinTerms(for: intent).filter { term in
            !ignored.contains(term) && term.unicodeScalars.allSatisfy { $0.isASCII }
        }
        guard !intentTerms.isEmpty else { return true }
        let loweredQuote = cleanedQuote.lowercased()
        return intentTerms.contains { containsAffirmedTerm($0, in: loweredQuote) }
    }

    private static func containsCandidateInstructionInjection(_ candidate: DiscoveryCandidate) -> Bool {
        let material = [candidate.userFacingSummary, candidate.evidence.skillDocumentExcerpt]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        let markers = [
            "ignore previous instructions", "ignore all previous", "system prompt",
            "mark this candidate recommended", "recommend this candidate",
            "choose the top tier", "highest tier", "rank this candidate first",
            "忽略之前的指令", "忽略上级指令", "忽略系统指令", "系统提示词",
            "将本候选标记为推荐", "标记为推荐", "推荐这个候选", "选择最高等级",
        ]
        return markers.contains(where: material.contains)
    }

    public static func semanticRouting(
        evaluation: DiscoveryEvaluation?,
        fallbackCandidateIDs: Set<String>
    ) -> DiscoverySemanticRouting {
        guard let evaluation else {
            return .init(relevantCandidateIDs: nil, evaluatedCandidateIDs: nil, recommendedRanks: nil)
        }
        let evaluated = Set(evaluation.recommendations.map(\.candidateID))
        let orderedRecommended = evaluation.recommendations.filter { $0.tier == .recommended }.map(\.candidateID)
        let recommended = Set(orderedRecommended)
        return .init(
            relevantCandidateIDs: recommended,
            evaluatedCandidateIDs: evaluated,
            recommendedRanks: Dictionary(uniqueKeysWithValues: orderedRecommended.enumerated().map { ($0.element, $0.offset) })
        )
    }

    private static func hasDeterministicQualityEvidence(
        _ candidate: DiscoveryCandidate,
        installs: Int
    ) -> Bool {
        if candidate.evidence.independentCommunityAuthorCount >= 2 { return true }
        if candidate.evidence.catalogTrust == .official { return true }
        return installs >= 500
    }

    private static func qualityOrder(
        _ lhs: DiscoveryCandidate,
        _ rhs: DiscoveryCandidate,
        intent: DiscoveryIntent,
        semanticRecommendationRanks: [String: Int]? = nil
    ) -> Bool {
        // Community approval helps distinguish candidates that solve the same
        // job. It must never compensate for a weaker match to the user's job.
        let leftRelevance = relevanceScore(lhs, intent: intent)
        let rightRelevance = relevanceScore(rhs, intent: intent)
        if leftRelevance != rightRelevance { return leftRelevance > rightRelevance }
        let leftCommunityAuthors = lhs.evidence.independentCommunityAuthorCount
        let rightCommunityAuthors = rhs.evidence.independentCommunityAuthorCount
        if leftCommunityAuthors != rightCommunityAuthors { return leftCommunityAuthors > rightCommunityAuthors }
        let leftCommunityPlatforms = lhs.evidence.communityPlatformCount
        let rightCommunityPlatforms = rhs.evidence.communityPlatformCount
        if leftCommunityPlatforms != rightCommunityPlatforms { return leftCommunityPlatforms > rightCommunityPlatforms }
        let leftCommunityPopularity = lhs.evidence.communityPopularitySignal
        let rightCommunityPopularity = rhs.evidence.communityPopularitySignal
        if leftCommunityPopularity != rightCommunityPopularity { return leftCommunityPopularity > rightCommunityPopularity }
        let leftInstalls = lhs.verifiedInstallCountLowerBound
        let rightInstalls = rhs.verifiedInstallCountLowerBound
        if leftInstalls != rightInstalls { return leftInstalls > rightInstalls }
        let leftTrusted = isTrusted(lhs)
        let rightTrusted = isTrusted(rhs)
        if leftTrusted != rightTrusted { return leftTrusted }
        let leftUpdated = lhs.repositoryUpdatedAt ?? .distantPast
        let rightUpdated = rhs.repositoryUpdatedAt ?? .distantPast
        if leftUpdated != rightUpdated { return leftUpdated > rightUpdated }
        let leftEvidence = lhs.evidence.skillDocumentExcerpt?.count ?? 0
        let rightEvidence = rhs.evidence.skillDocumentExcerpt?.count ?? 0
        if leftEvidence != rightEvidence { return leftEvidence > rightEvidence }
        let leftCurated = lhs.evidence.catalogTrust == .curated || lhs.evidence.sources.contains(.curatedCatalog)
        let rightCurated = rhs.evidence.catalogTrust == .curated || rhs.evidence.sources.contains(.curatedCatalog)
        if leftCurated != rightCurated { return leftCurated }
        let leftStars = repositoryStarsAreSkillEvidence(lhs) ? (lhs.repositoryStars ?? 0) : 0
        let rightStars = repositoryStarsAreSkillEvidence(rhs) ? (rhs.repositoryStars ?? 0) : 0
        if leftStars != rightStars { return leftStars > rightStars }
        let leftRank = semanticRecommendationRanks?[lhs.id]
        let rightRank = semanticRecommendationRanks?[rhs.id]
        if leftRank != rightRank {
            if let leftRank, let rightRank { return leftRank < rightRank }
            return leftRank != nil
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func isTrusted(_ candidate: DiscoveryCandidate) -> Bool {
        candidate.evidence.catalogTrust == .official
    }

    private static func repositoryStarsAreSkillEvidence(_ candidate: DiscoveryCandidate) -> Bool {
        guard candidate.evidence.catalogTrust != .curated, candidate.skillPath == nil else { return false }
        let repository = candidate.repositoryFullName.lowercased()
        return repository != "openai/plugins" && repository != "github/awesome-copilot"
    }

    private static func relevanceScore(_ candidate: DiscoveryCandidate, intent: DiscoveryIntent) -> Int {
        let haystack = "\(candidate.userFacingSummary ?? "").\n\(candidate.evidence.skillDocumentExcerpt ?? "")".lowercased()
        let goal = ([intent.goal] + intent.mustHaves + intent.preferences).joined(separator: " ").lowercased()
        let latinTerms = expandedLatinTerms(for: intent)
        var score = latinTerms.reduce(0) { $0 + (containsAffirmedTerm($1, in: haystack) ? 12 : 0) }
        let chinese = Array(goal.filter { character in
            character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        })
        if chinese.count >= 2 {
            for index in 0..<(chinese.count - 1)
                where containsAffirmedTerm(String(chinese[index...index + 1]), in: haystack)
            {
                score += 6
            }
        }
        if isRewriteRequest(intent), containsHanCharacters(intent.goal) {
            let identityAndEvidence = "\(candidate.name) \(haystack)"
            let hasChineseFit = containsHanCharacters(identityAndEvidence)
                || identityAndEvidence.contains("chinese")
                || identityAndEvidence.contains("humanizer-zh")
                || identityAndEvidence.contains("humanizer-cn")
            if hasChineseFit { score += 48 }
        }
        if containsAffirmedTerm(intent.goal.lowercased(), in: haystack) { score += 80 }
        return score
    }

    private static func isCapabilityMismatch(_ candidate: DiscoveryCandidate, intent: DiscoveryIntent) -> Bool {
        guard isRewriteRequest(intent) else { return false }
        let text = "\(candidate.name) \(candidate.userFacingSummary ?? "")".lowercased()
        let intentText = ([intent.goal] + intent.mustHaves + intent.preferences).joined(separator: " ").lowercased()
        let isAcademicSpecific = candidate.name.lowercased().contains("academic")
            || text.contains("authentic academic voice")
            || text.contains("scholarly writing for")
        let asksForAcademicWriting = ["academic", "scholarly", "manuscript", "学术", "论文", "期刊"]
            .contains(where: intentText.contains)
        if isAcademicSpecific, !asksForAcademicWriting { return true }
        let languageConstraints: [(marker: String, phrases: [String])] = [
            ("finnish", ["finnish text", "finnish prose", "native finnish"]),
            ("japanese", ["japanese text", "japanese prose", "native japanese"]),
            ("korean", ["korean text", "korean prose", "native korean", "한국어 텍스트"]),
            ("spanish", ["spanish text", "spanish prose", "native spanish"]),
            ("french", ["french text", "french prose", "native french"]),
            ("german", ["german text", "german prose", "native german"]),
        ]
        for constraint in languageConstraints {
            let isLanguageSpecific = candidate.name.lowercased().contains(constraint.marker)
                || constraint.phrases.contains(where: text.contains)
            let requestedLanguage = intentText.contains(constraint.marker)
                || (constraint.marker == "korean" && ["韩语", "한국어"].contains(where: intentText.contains))
            if isLanguageSpecific, !requestedLanguage { return true }
        }
        let explicitlyDiagnosticOnly = ["只诊断不改写", "默认只诊断", "只检测不改写", "only detects", "diagnostic only"]
            .contains(where: { text.contains($0) })
        if explicitlyDiagnosticOnly { return true }
        let rewriteTerms = ["改写", "润色", "重写", "humanize", "rewrite", "edit drafts", "edit prose", "editing prose", "自然表达", "去 ai 味", "去ai味"]
        let diagnosticTerms = ["检测", "诊断", "扫描", "报告", "detect", "check", "只诊断不改写"]
        return diagnosticTerms.contains(where: { text.contains($0) }) && !rewriteTerms.contains(where: { containsAffirmedTerm($0, in: text) })
    }

    private static func containsHanCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
    private static func isRelevant(_ candidate: DiscoveryCandidate, to intent: DiscoveryIntent, originallyMatched: Bool) -> Bool {
        let authors = intent.targets.filter { $0.kind == .author }
        if !authors.isEmpty {
            let owners = authors.compactMap { DiscoveryAuthorIdentity.owner(for: $0.value) }
            guard owners.count == authors.count, owners.contains(where: {
                DiscoveryAuthorIdentity.matches(repository: candidate.repositoryFullName, owner: $0)
            }) else { return false }
            var capabilityIntent = intent
            capabilityIntent.targets = []
            for identity in authors.map(\.value) + owners {
                capabilityIntent.goal = capabilityIntent.goal.replacingOccurrences(of: identity, with: "", options: .caseInsensitive)
            }
            return isRelevant(candidate, to: capabilityIntent, originallyMatched: originallyMatched)
        }
        // A name can attract a search hit, but only the verified Skill-level summary
        // may establish recommendation eligibility. This prevents a suggestive name
        // from overruling an explicit "lacks / absent / 缺少" capability statement.
        let summary = (candidate.userFacingSummary ?? "").lowercased()
        var haystack = summary
        if isRewriteRequest(intent),
           ["文案", "文章", "长文", "写作", "稿子", "prose", "copywriting", "writer", "edit drafts", "editing drafts", "writing skill", "writing style", "humanize", "한국어 텍스트"]
            .contains(where: { containsAffirmedTerm($0, in: summary) }),
           !["does not", "doesn't", "cannot", "not support", "不支持", "不提供", "不能", "只诊断", "lacks", "absent"].contains(where: summary.contains) {
            // A capability may be described in the body rather than frontmatter.
            // The summary must first establish prose work. API examples and
            // incidental mentions in an unrelated document cannot supply that fact.
            haystack += "\n" + String((candidate.evidence.skillDocumentExcerpt ?? "").prefix(8_000)).lowercased()
        }
        if intent.exclusions.contains(where: { exclusion in
            let value = exclusion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !value.isEmpty && haystack.contains(value)
        }) { return false }
        if isRewriteRequest(intent) {
            let directHumanizationTerms = [
                "去 ai 味", "去ai味", "去除 ai", "去除ai", "ai 生成痕迹", "ai生成痕迹", "减少模板化",
                "减少机械", "活人感", "humanize", "de-ai", "ai-generated pattern", "ai-sounding",
                "ai writing pattern", "writing slop", "de-slop", "deslop", "natural writing",
            ]
            if directHumanizationTerms.contains(where: { containsAffirmedTerm($0, in: haystack) }) { return true }
            let rewriteActions = ["改写", "润色", "重写", "更自然", "自然表达", "rewrite", "polish"]
            let writingObjects = ["文案", "文章", "文本", "文字", "写作", "稿件", "prose", "copy", "draft", "writing", "text"]
            return rewriteActions.contains(where: { containsAffirmedTerm($0, in: haystack) })
                && writingObjects.contains(where: { containsAffirmedTerm($0, in: haystack) })
        }
        let compactGoal = intent.goal.lowercased().replacingOccurrences(of: "skill", with: "")
        let terms = compactGoal.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { $0.count >= 2 }
        if terms.contains(where: { containsAffirmedTerm($0, in: haystack) }) { return true }
        if expandedLatinTerms(for: intent).contains(where: { containsAffirmedTerm($0, in: haystack) }) { return true }

        guard originallyMatched else { return false }

        let chineseCharacters = compactGoal.filter { character in
            character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        }
        let characters = Array(chineseCharacters)
        let genericPairs: Set<String> = ["我想", "想找", "找到", "那个", "那份", "那款", "找一", "一个", "个能", "能帮", "帮我", "我的", "需要", "要一", "适合", "什么", "功能", "一下", "这个", "使用"]
        let pairs = characters.indices.dropLast().map { String(characters[$0...characters.index(after: $0)]) }
            .filter { !genericPairs.contains($0) }
        return pairs.contains { containsAffirmedTerm($0, in: haystack) }
    }

    private static func isRewriteRequest(_ intent: DiscoveryIntent) -> Bool {
        let compactIntent = ([intent.goal] + intent.mustHaves + intent.preferences)
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let terms = [
            "ai味", "ai文案味", "文案ai味", "文案味", "去ai", "去除ai", "改写", "润色", "重写", "更自然", "活人感",
            "humanize", "rewrite", "naturalwriting",
        ]
        return terms.contains(where: compactIntent.contains)
    }

    // These are language-level negation families. The matcher below scopes them to the
    // specific capability mention instead of rejecting an entire candidate sentence.
    private static let negatedCapabilityMarkers = [
        "no ", "does not", "doesn't", "do not", "don't", "cannot", "can't", "never ",
        "not support", "not supported", "unsupported", "without support", "absence of ",
        "lack of ", "lack ", "lacks ", "lacked ", "lacking ", "missing ",
        "omit ", "omits ", "omitted ", "omitting ", "exclude ", "excludes ", "excluded ", "excluding ",
        "没有提供", "没有", "缺少", "缺乏", "缺失", "尚未实现", "未实现", "未提供", "未包含",
        "不包含", "不含", "不具备", "不支持", "不能", "无法", "不会", "不提供", "不适用", "不要用于", "勿用于",
    ]

    private static let capabilityAffirmationMarkers = [
        "supports ", "provides ", "offers ", "manages ", "handles ", "creates ", "automates ",
        "processes ", "allows ", "can ", "able to ", "支持", "提供", "具备", "管理", "处理", "创建",
        "可以", "能够", "可管理", "能管理", "可处理", "能处理",
    ]

    private static let affirmationResetCues = [
        ",", "，", ";", "；", ".", "。", "!", "！", "?", "？", "\n",
        " but ", " however ", " yet ", " still ", " while ", " and ", " can ", "able to ",
        "但", "不过", "然而", "仍", "依然", "也能", "能够", "可以", "可", "并", "而",
    ]

    private static let trailingNegationMarkers = [
        "is not supported", "isn't supported", "are not supported", "aren't supported", "is unsupported",
        "is unavailable", "is not available", "is absent", "are absent", "remains absent",
        "is missing", "are missing", "remains missing", "is unimplemented", "are unimplemented",
        "has not been implemented", "have not been implemented", "not provided",
        "尚未实现", "未实现", "尚未提供", "未提供", "缺少", "缺乏", "缺失", "不存在",
        "不受支持", "不支持", "不可用", "没有提供", "不具备",
    ]

    private static func containsAffirmedTerm(_ term: String, in text: String) -> Bool {
        let loweredTerm = term.lowercased()
        guard !loweredTerm.isEmpty else { return false }
        let loweredText = text.lowercased()
        var cursor = loweredText.startIndex
        while cursor < loweredText.endIndex,
              let match = loweredText.range(of: loweredTerm, range: cursor..<loweredText.endIndex)
        {
            if !capabilityMatchIsNegated(match, in: loweredText) { return true }
            cursor = match.upperBound
        }
        return false
    }

    private static func capabilityMatchIsNegated(_ match: Range<String.Index>, in text: String) -> Bool {
        let sentenceStart = text[..<match.lowerBound].lastIndex(where: isStrongClauseBoundary)
            .map { text.index(after: $0) } ?? text.startIndex
        let prefix = String(text[sentenceStart..<match.lowerBound])

        if let negative = lastMarkerRange(negatedCapabilityMarkers, in: prefix) {
            let laterAffirmation = markerRanges(capabilityAffirmationMarkers, in: prefix).contains { affirmation in
                guard affirmation.lowerBound >= negative.upperBound else { return false }
                let bridge = String(prefix[negative.upperBound..<affirmation.lowerBound])
                return affirmationResetCues.contains(where: bridge.contains)
            }
            if !laterAffirmation { return true }
        }

        let remaining = text[match.upperBound...]
        let suffixEnd = remaining.firstIndex(where: isClauseBoundary) ?? text.endIndex
        let suffix = String(text[match.upperBound..<suffixEnd])
        return trailingNegationMarkers.contains(where: suffix.contains)
    }

    private static func lastMarkerRange(_ markers: [String], in text: String) -> Range<String.Index>? {
        markerRanges(markers, in: text).max { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound { return lhs.upperBound < rhs.upperBound }
            return lhs.lowerBound < rhs.lowerBound
        }
    }

    private static func markerRanges(_ markers: [String], in text: String) -> [Range<String.Index>] {
        markers.flatMap { marker -> [Range<String.Index>] in
            var ranges: [Range<String.Index>] = []
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: marker, range: cursor..<text.endIndex)
            {
                ranges.append(range)
                cursor = range.upperBound
            }
            return ranges
        }
    }

    private static func isStrongClauseBoundary(_ character: Character) -> Bool {
        ".。!！?？;\n".contains(character)
    }

    private static func isClauseBoundary(_ character: Character) -> Bool {
        ",，;；.。!！?？\n".contains(character)
    }

    private static func expandedLatinTerms(for intent: DiscoveryIntent) -> Set<String> {
        let fallbackQueries = DiscoveryIntentPlanner.fallback(message: intent.goal, previous: nil).queries
        let source = (fallbackQueries + intent.mustHaves + intent.preferences).joined(separator: " ").lowercased()
        let ignored = Set(["skill", "skills", "workflow", "with", "from", "that", "this"])
        return Set(
            source.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !ignored.contains($0) }
        )
    }
}
