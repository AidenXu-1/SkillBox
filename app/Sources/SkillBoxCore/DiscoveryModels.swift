import Foundation

public enum DiscoveryCandidateState: String, Codable, Hashable, Sendable { case notTried, trying, notSuitable }
public enum DiscoveryCandidateTier: String, Codable, Hashable, Sendable { case recommended, other }
public enum DiscoveryEvidenceSource: String, Codable, Hashable, Sendable { case skillsSh, github, skillDocument, curatedCatalog, localSafety }

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
        hasBlockingSafetyIssue: Bool = false
    ) {
        self.skillSummary = skillSummary; self.skillDocumentExcerpt = skillDocumentExcerpt; self.repositorySummary = repositorySummary
        self.skillContentVerified = skillContentVerified; self.repositoryIsPrivate = repositoryIsPrivate
        self.skillDocumentURL = skillDocumentURL; self.fetchedAt = fetchedAt
        self.sources = sources; self.repositoryArchived = repositoryArchived; self.downloadable = downloadable
        self.hasBlockingSafetyIssue = hasBlockingSafetyIssue
    }

    private enum CodingKeys: String, CodingKey {
        case skillSummary, skillDocumentExcerpt, repositorySummary, skillContentVerified, repositoryIsPrivate, skillDocumentURL, fetchedAt
        case sources, repositoryArchived, downloadable, hasBlockingSafetyIssue
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
    public var repositoryStars: Int?
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
    public var repositorySummary: String? { evidence.repositorySummary ?? (summaryIsRepositoryLevel ? summary : nil) }
    public var repositoryURL: URL? { URL(string: "https://github.com/\(repositoryFullName)") }
    public var importURL: URL? {
        guard let repositoryURL else { return nil }
        guard let skillPath, !skillPath.isEmpty else { return repositoryURL }
        return repositoryURL.appendingPathComponent("tree").appendingPathComponent("HEAD").appending(path: skillPath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, summaryIsRepositoryLevel, repositoryFullName, skillPath, installCount
        case repositoryStars, repositoryStarsFetchedAt, repositoryUpdatedAt, state, tier, recommendationReason
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
        repositoryStars = try values.decodeIfPresent(Int.self, forKey: .repositoryStars)
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
    public init(goal: String, mustHaves: [String] = [], preferences: [String] = [], exclusions: [String] = []) {
        self.goal = goal; self.mustHaves = mustHaves; self.preferences = preferences; self.exclusions = exclusions
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
    public var suitableWhen: String?
    public var examplePrompt: String?
    public var experienceSteps: [String]
    public var limitations: [String]
    public var usageGuide: SkillUsageGuide?
    public init(candidateID: String, tier: DiscoveryCandidateTier, reason: String, suitableWhen: String? = nil, examplePrompt: String? = nil, experienceSteps: [String] = [], limitations: [String] = [], usageGuide: SkillUsageGuide? = nil) {
        self.candidateID = candidateID; self.tier = tier; self.reason = reason; self.suitableWhen = suitableWhen
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
    public var fallbackReason: String?
    public var state: DiscoveryRunState
    public var diagnostics: [AIInvocationDiagnostic]
    public var retrievedCandidateCount: Int?
    public var evaluationCandidateCount: Int?
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        queries: [String],
        recommendedCandidateIDs: [String] = [],
        otherCandidateIDs: [String] = [],
        usedAI: Bool = false,
        fallbackReason: String? = nil,
        state: DiscoveryRunState = .completed,
        diagnostics: [AIInvocationDiagnostic] = [],
        retrievedCandidateCount: Int? = nil,
        evaluationCandidateCount: Int? = nil
    ) {
        self.id = id; self.createdAt = createdAt; self.queries = queries; self.recommendedCandidateIDs = recommendedCandidateIDs
        self.otherCandidateIDs = otherCandidateIDs; self.usedAI = usedAI; self.fallbackReason = fallbackReason
        self.state = state; self.diagnostics = diagnostics
        self.retrievedCandidateCount = retrievedCandidateCount; self.evaluationCandidateCount = evaluationCandidateCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, queries, recommendedCandidateIDs, otherCandidateIDs, usedAI, fallbackReason, state, diagnostics
        case retrievedCandidateCount, evaluationCandidateCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        queries = try values.decodeIfPresent([String].self, forKey: .queries) ?? []
        recommendedCandidateIDs = try values.decodeIfPresent([String].self, forKey: .recommendedCandidateIDs) ?? []
        otherCandidateIDs = try values.decodeIfPresent([String].self, forKey: .otherCandidateIDs) ?? []
        usedAI = try values.decodeIfPresent(Bool.self, forKey: .usedAI) ?? false
        fallbackReason = try values.decodeIfPresent(String.self, forKey: .fallbackReason)
        state = try values.decodeIfPresent(DiscoveryRunState.self, forKey: .state) ?? .completed
        diagnostics = try values.decodeIfPresent([AIInvocationDiagnostic].self, forKey: .diagnostics) ?? []
        retrievedCandidateCount = try values.decodeIfPresent(Int.self, forKey: .retrievedCandidateCount)
        evaluationCandidateCount = try values.decodeIfPresent(Int.self, forKey: .evaluationCandidateCount)
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
    public init(id: UUID = UUID(), title: String, storageFolderName: String, createdAt: Date = Date(), updatedAt: Date = Date(), turns: [DiscoveryTurn] = [], messages: [DiscoveryMessage] = [], intent: DiscoveryIntent? = nil, runs: [DiscoverySearchRun] = [], notices: [DiscoverySystemNotice] = [], candidates: [DiscoveryCandidate] = [], selectedCandidateID: String? = nil) {
        self.id = id; self.title = title; self.storageFolderName = storageFolderName; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.turns = turns; self.messages = messages; self.intent = intent; self.runs = runs; self.notices = notices; self.candidates = candidates; self.selectedCandidateID = selectedCandidateID
    }
    public var effectiveQuery: String? { runs.last?.queries.first ?? turns.last?.effectiveQuery }
    public var recommendedCandidates: [DiscoveryCandidate] { candidates.filter { $0.tier == .recommended } }
    public var otherCandidates: [DiscoveryCandidate] { candidates.filter { $0.tier == .other } }
    private enum CodingKeys: String, CodingKey { case id, title, storageFolderName, createdAt, updatedAt, turns, messages, intent, runs, notices, candidates, selectedCandidateID }
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
    }
}

public struct DiscoverySearchResult: Sendable {
    public var candidates: [DiscoveryCandidate]
    public var fetchedAt: Date
    public init(candidates: [DiscoveryCandidate], fetchedAt: Date = Date()) { self.candidates = candidates; self.fetchedAt = fetchedAt }
}

public struct DiscoveryBatchSearchResult: Sendable {
    public var candidates: [DiscoveryCandidate]
    public var originalQueryCandidateIDs: Set<String>
    public var fetchedAt: Date
    public var failedSourceCount: Int
    public var failedQueryCount: Int
    public init(
        candidates: [DiscoveryCandidate],
        originalQueryCandidateIDs: Set<String>,
        fetchedAt: Date = Date(),
        failedSourceCount: Int = 0,
        failedQueryCount: Int = 0
    ) {
        self.candidates = candidates; self.originalQueryCandidateIDs = originalQueryCandidateIDs; self.fetchedAt = fetchedAt
        self.failedSourceCount = failedSourceCount
        self.failedQueryCount = failedQueryCount
    }
}

public enum DiscoverySearchScope: Sendable {
    case initial
    case deep

    public var limitPerQuery: Int {
        switch self {
        case .initial: 24
        case .deep: 96
        }
    }
}

public enum DiscoveryEvaluationLimits {
    public static let maximumCandidates = 8
    public static let maximumEvidenceCharacters = 8_000
    public static let maximumOutputTokens = 1_500
    public static let maximumPlanningOutputTokens = 600
    public static let maximumPlanningInputCharacters = 2_000
    public static let maximumLazyGuideCharacters = 8_000
    public static let maximumUsageGuideInputCharacters = 12_000
    public static let maximumUsageGuideOutputTokens = 1_200
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
        for (queryIndex, query) in queries.enumerated() {
            let result = try await search(query: query, limit: limitPerQuery)
            for candidate in result.candidates {
                let key = "\(candidate.repositoryFullName.lowercased())|\((candidate.skillPath ?? candidate.name).lowercased())"
                if merged[key] == nil { order.append(key); merged[key] = candidate }
                if queryIndex == 0 { originalIDs.insert(candidate.id) }
            }
        }
        return .init(candidates: order.compactMap { merged[$0] }, originalQueryCandidateIDs: originalIDs)
    }
}

public enum DiscoveryIntentPlanner {
    public static func fallback(message: String, previous: DiscoveryIntent?) -> DiscoveryPlan {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualityFeedback = ["质量不高", "质量不好", "不够好", "不知名", "更知名", "更优质", "质量高一点", "太少", "优质的", "知名的", "没找到", "继续深挖", "找得少"].contains { text.contains($0) }
        if qualityFeedback, var previous {
            for preference in ["继续深挖更多来源", "优先用途匹配、来源可靠且有维护证据"] where !previous.preferences.contains(preference) {
                previous.preferences.append(preference)
            }
            return DiscoveryPlan(intent: previous, queries: deterministicQueries(for: previous.goal))
        }
        let intent = DiscoveryIntent(goal: text)
        return DiscoveryPlan(intent: intent, queries: deterministicQueries(for: text))
    }

    private static func deterministicQueries(for goal: String) -> [String] {
        guard !goal.isEmpty else { return [] }
        var queries = [goal]
        let compact = goal.lowercased().replacingOccurrences(of: " ", with: "")
        if compact.contains("去ai味") || compact.contains("文案ai") || compact.contains("不像ai") {
            queries.append(contentsOf: ["humanize writing", "remove AI writing style", "natural writing rewrite"])
        }
        return queries.reduce(into: []) { result, query in
            if !result.contains(query) { result.append(query) }
        }
    }
}

public struct DiscoveryRankedCandidates: Sendable { public var recommended: [DiscoveryCandidate]; public var other: [DiscoveryCandidate] }

public struct DiscoverySemanticRouting: Sendable {
    public var relevantCandidateIDs: Set<String>?
    public var evaluatedCandidateIDs: Set<String>?

    public init(relevantCandidateIDs: Set<String>?, evaluatedCandidateIDs: Set<String>?) {
        self.relevantCandidateIDs = relevantCandidateIDs
        self.evaluatedCandidateIDs = evaluatedCandidateIDs
    }
}

public enum DiscoveryCandidateRanker {
    private static let trustedPublishers: Set<String> = ["openai", "anthropics", "vercel-labs", "microsoft", "github", "google-gemini", "agnesai-labs"]
    public static func rank(
        _ candidates: [DiscoveryCandidate],
        intent: DiscoveryIntent,
        originalQueryCandidateIDs: Set<String>,
        relevantCandidateIDs: Set<String>? = nil,
        evaluatedCandidateIDs: Set<String>? = nil
    ) -> DiscoveryRankedCandidates {
        var recommended: [DiscoveryCandidate] = []; var other: [DiscoveryCandidate] = []
        for var candidate in candidates {
            let isRelevantMatch: Bool
            if let evaluatedCandidateIDs, evaluatedCandidateIDs.contains(candidate.id) {
                isRelevantMatch = relevantCandidateIDs?.contains(candidate.id) == true
            } else if evaluatedCandidateIDs != nil {
                isRelevantMatch = relevantCandidateIDs?.contains(candidate.id) == true
                    || isRelevant(candidate, to: intent, originallyMatched: originalQueryCandidateIDs.contains(candidate.id))
            } else if relevantCandidateIDs != nil, evaluatedCandidateIDs == nil {
                isRelevantMatch = relevantCandidateIDs?.contains(candidate.id) == true
            } else {
                isRelevantMatch = isRelevant(candidate, to: intent, originallyMatched: originalQueryCandidateIDs.contains(candidate.id))
            }
            guard candidate.evidence.skillContentVerified, candidate.userFacingSummary != nil,
                  !candidate.evidence.repositoryArchived, candidate.evidence.downloadable,
                  !candidate.evidence.hasBlockingSafetyIssue,
                  isRelevantMatch else { continue }
            let publisher = candidate.repositoryFullName.split(separator: "/").first.map { String($0).lowercased() } ?? ""
            let stars = candidate.repositoryStars ?? 0
            let installs = candidate.installCount ?? 0
            let hasTrustedSource = trustedPublishers.contains(publisher) || candidate.evidence.sources.contains(.curatedCatalog)
            let hasPublicQualityEvidence = hasTrustedSource || stars >= 500 || (stars >= 200 && installs >= 1_000)
            let capabilityMismatch = isCapabilityMismatch(candidate, intent: intent)
            let isStrong = !capabilityMismatch && hasPublicQualityEvidence
            candidate.tier = isStrong ? .recommended : .other
            if isStrong { recommended.append(candidate) }
            else { other.append(candidate) }
        }
        recommended.sort(by: qualityOrder)
        other.sort(by: qualityOrder)
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
                  !isCapabilityMismatch(candidate, intent: intent)
            else { return false }
            let publisher = candidate.repositoryFullName.split(separator: "/").first.map { String($0).lowercased() } ?? ""
            let stars = candidate.repositoryStars ?? 0
            let installs = candidate.installCount ?? 0
            let trusted = trustedPublishers.contains(publisher) || candidate.evidence.sources.contains(.curatedCatalog)
            return trusted || stars >= 500 || (stars >= 200 && installs >= 1_000)
        }.sorted(by: qualityOrder)
    }

    public static func semanticallyRecommendedCandidateIDs(from evaluation: DiscoveryEvaluation?) -> Set<String>? {
        guard let evaluation else { return nil }
        return Set(evaluation.recommendations.lazy.filter { $0.tier == .recommended }.map(\.candidateID))
    }

    public static func semanticRouting(
        evaluation: DiscoveryEvaluation?,
        fallbackCandidateIDs: Set<String>
    ) -> DiscoverySemanticRouting {
        guard let evaluation else {
            return .init(relevantCandidateIDs: nil, evaluatedCandidateIDs: nil)
        }
        let evaluated = Set(evaluation.recommendations.map(\.candidateID))
        let recommended = Set(
            evaluation.recommendations.lazy
                .filter { $0.tier == .recommended }
                .map(\.candidateID)
        )
        return .init(
            relevantCandidateIDs: recommended,
            evaluatedCandidateIDs: evaluated
        )
    }

    private static func qualityOrder(_ lhs: DiscoveryCandidate, _ rhs: DiscoveryCandidate) -> Bool {
        let leftStars = lhs.repositoryStars ?? 0
        let rightStars = rhs.repositoryStars ?? 0
        if leftStars != rightStars { return leftStars > rightStars }
        let leftInstalls = lhs.installCount ?? 0
        let rightInstalls = rhs.installCount ?? 0
        if leftInstalls != rightInstalls { return leftInstalls > rightInstalls }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func isCapabilityMismatch(_ candidate: DiscoveryCandidate, intent: DiscoveryIntent) -> Bool {
        let compactGoal = intent.goal.lowercased().replacingOccurrences(of: " ", with: "")
        guard compactGoal.contains("去ai味") || compactGoal.contains("改写") || compactGoal.contains("更自然") else { return false }
        let text = "\(candidate.name) \(candidate.userFacingSummary ?? "")".lowercased()
        let explicitlyDiagnosticOnly = ["只诊断不改写", "默认只诊断", "只检测不改写", "only detects", "diagnostic only"]
            .contains(where: { text.contains($0) })
        if explicitlyDiagnosticOnly { return true }
        let rewriteTerms = ["改写", "润色", "重写", "humanize", "rewrite", "自然表达", "去 ai 味", "去ai味"]
        let diagnosticTerms = ["检测", "诊断", "扫描", "报告", "detect", "check", "只诊断不改写"]
        return diagnosticTerms.contains(where: { text.contains($0) }) && !rewriteTerms.contains(where: { text.contains($0) })
    }
    private static func isRelevant(_ candidate: DiscoveryCandidate, to intent: DiscoveryIntent, originallyMatched: Bool) -> Bool {
        let haystack = "\(candidate.name) \(candidate.userFacingSummary ?? "")".lowercased()
        if intent.exclusions.contains(where: { exclusion in
            let value = exclusion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !value.isEmpty && haystack.contains(value)
        }) { return false }
        if intent.goal.contains("去 AI 味") || intent.goal.contains("去AI味") {
            return haystack.contains("自然") || haystack.contains("human") || haystack.contains("ai 味")
        }
        if intent.goal.contains("改写") || intent.goal.contains("更自然") {
            let rewriteTerms = ["改写", "润色", "重写", "自然", "humanize", "rewrite", "natural writing"]
            if rewriteTerms.contains(where: { haystack.contains($0) }) { return true }
        }
        let compactGoal = intent.goal.lowercased().replacingOccurrences(of: "skill", with: "")
        let terms = compactGoal.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { $0.count >= 2 }
        if terms.contains(where: { haystack.contains($0) }) { return true }

        guard originallyMatched else { return false }

        let chineseCharacters = compactGoal.filter { character in
            character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        }
        let characters = Array(chineseCharacters)
        let genericPairs: Set<String> = ["我想", "想找", "找一", "一个", "个能", "能帮", "帮我", "我的", "需要", "要一", "适合", "什么", "功能", "一下", "这个", "使用"]
        let pairs = characters.indices.dropLast().map { String(characters[$0...characters.index(after: $0)]) }
            .filter { !genericPairs.contains($0) }
        return pairs.contains { haystack.contains($0) }
    }
}
