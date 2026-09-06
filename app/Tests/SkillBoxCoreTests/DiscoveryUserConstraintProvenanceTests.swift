import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Discovery user constraint provenance", .serialized)
struct DiscoveryUserConstraintProvenanceTests {
    static let request = "推荐去文案AI味的skill。"
    static var observedModelPlan: DiscoveryPlan {
        .init(intent: .init(goal: request, mustHaves: ["AI风格", "文案写作"], preferences: ["不太机械", "自然流畅"]), queries: ["humanize writing"])
    }
    static var candidate: DiscoveryCandidate {
        .init(id: "english", name: "plain-humanizer", summary: "Rewrite prose to remove AI writing patterns. Free to use.", repositoryFullName: "fixture/plain-humanizer", installCount: 1000, evidence: .init(skillContentVerified: true, repositoryIsPrivate: false))
    }
    static func legacy(_ conditions: [String]) -> DiscoverySession {
        var session = DiscoverySession(title: "写作", storageFolderName: "legacy", intent: .init(goal: request, mustHaves: conditions))
        session.messages = [.init(role: .user, text: request)]
        session.runs = [.init(queries: [request, "humanize writing"], route: .scenario, state: .completed)]
        return session
    }

    @Test("The observed model's capability words never become mandatory evidence requirements")
    func modelCapabilitiesStaySoft() {
        let local = DiscoveryIntentPlanner.fallback(message: Self.request, previous: nil)
        let plan = DiscoveryIntentPlanner.reconcile(modelPlan: Self.observedModelPlan, deterministicPlan: local)
        #expect(plan.intent.mustHaves.isEmpty)
        #expect(DiscoveryCandidateRanker.rank([Self.candidate], intent: plan.intent, originalQueryCandidateIDs: []).recommended.count == 1)
        var invented = Self.observedModelPlan
        invented.intent.mustHaves = ["必须支持中文"]
        invented.intent.preferences = ["must work offline"]
        invented.intent.exclusions = ["rewrite"]
        let reconciled = DiscoveryIntentPlanner.reconcile(modelPlan: invented, deterministicPlan: local)
        #expect(reconciled.intent.mustHaves.isEmpty)
        #expect(reconciled.intent.exclusions.isEmpty)
        #expect(DiscoveryCandidateRanker.rank([Self.candidate], intent: reconciled.intent, originalQueryCandidateIDs: []).recommended.count == 1)
    }

    @Test("Actual user requirements survive model reconciliation and clarification replies")
    func actualRequirementsSurvive() {
        let initial = DiscoveryIntentPlanner.fallback(message: Self.request, previous: nil)
        for message in ["不要收费", "必须离线运行", "禁止上传原文", "最好中文，不要收费"] {
            let local = DiscoveryIntentPlanner.fallback(message: message, previous: initial.intent)
            #expect(local.intent.goal == Self.request)
            #expect(!local.intent.mustHaves.isEmpty, "Lost user requirement: \(message)")
            let plan = DiscoveryIntentPlanner.reconcile(modelPlan: Self.observedModelPlan, deterministicPlan: local)
            #expect(plan.intent.mustHaves == local.intent.mustHaves)
        }
        var session = Self.legacy([])
        session.pendingClarification = "最后交付什么，是否有必须条件？"
        let answer = DiscoveryConversation.searchPlan(message: "必须离线运行", session: session)
        #expect(answer.intent.goal == Self.request)
        #expect(answer.intent.mustHaves.contains("必须离线运行"))
    }

    @Test("Legacy model words are removed while grounded aliases and withdrawn conditions stay correct")
    func legacyConditionsKeepUserEvidence() {
        var session = Self.legacy(["AI风格", "文案写作", "free", "offline", "不上传原文"])
        session.messages += [.init(role: .user, text: "必须免费且离线运行，禁止上传原文")]
        let plan = DiscoveryConversation.searchPlan(message: "继续寻找", session: session)
        #expect(Set(plan.intent.mustHaves) == ["free", "offline", "不上传原文"])
        session.intent = plan.intent
        session.intent?.mustHaves.append("必须中文")
        session.messages.append(.init(role: .user, text: "必须中文"))
        session.intent = DiscoveryConversation.removeConstraint("免费", from: session.intent!)
        let removal = DiscoveryMessage(role: .user, text: "不要求免费了")
        session.messages.append(removal)
        session.contextStartMessageID = removal.id
        let continued = DiscoveryConversation.searchPlan(message: "继续寻找", session: session)
        #expect(!continued.intent.mustHaves.contains("free"))
        #expect(continued.intent.mustHaves.contains("必须中文"))
        var noHistory = Self.legacy(["必须免费"])
        noHistory.messages = []
        #expect(DiscoveryConversation.searchPlan(message: "继续寻找", session: noHistory).intent.mustHaves == ["必须免费"])
    }

    @Test("Enabled AI and legacy deep search both retain the English author result", arguments: [false, true])
    @MainActor
    func applicationWithEnabledAI(isLegacy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if isLegacy {
            let store = try DiscoverySessionStore(root: root)
            try await store.save(Self.legacy(Self.observedModelPlan.intent.mustHaves))
        }
        let ai = ProvenanceModel()
        let source = ProvenanceSource()
        let suite = "SkillBoxProvenance." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryRoot: root, homeDirectory: root, aiKeyStore: ProvenanceKeyStore(), aiProvider: ai,
            routedDiscoveryProvider: .init(exactProvider: source, scenarioProvider: source, hybridProvider: source), userDefaults: defaults, startBootstrap: false)
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "agnes"
        settings.markConnectionVerified(providerID: "agnes")
        model.aiSettings = settings
        model.configuredAIProviderIDs.insert("agnes")
        await model.reloadDiscoverySessions()
        model.discoveryDraft = isLegacy ? "继续深挖更多来源" : Self.request
        model.startDiscoverySearch()
        for _ in 0..<400 {
            if model.discoveryDraft.isEmpty, !model.isDiscoverySearching, model.selectedDiscoverySession?.messages.last?.role == .assistant { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await ai.planningCalls == (isLegacy ? 0 : 1))
        #expect(await ai.evaluationCalls == 1)
        #expect(model.selectedDiscoverySession?.recommendedCandidates.map(\.id) == [Self.candidate.id])
        #expect(model.selectedDiscoverySession?.intent?.mustHaves.isEmpty == true)
    }
}

private struct ProvenanceSource: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult { .init(candidates: [DiscoveryUserConstraintProvenanceTests.candidate]) }
}
private actor ProvenanceKeyStore: AIKeyStore {
    func load(providerID: String) -> String? { "fixture-key" }
    func save(_ apiKey: String, providerID: String) {}
    func delete(providerID: String) {}
}
private actor ProvenanceModel: AIProvider {
    var planningCalls = 0
    var evaluationCalls = 0
    func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws -> AIConnectionTestResult { throw CancellationError() }
    func planDiscovery(message: String, previousIntent: DiscoveryIntent?, configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<DiscoveryPlan> {
        planningCalls += 1
        return .init(value: DiscoveryUserConstraintProvenanceTests.observedModelPlan, diagnostics: [])
    }
    func evaluateCandidates(intent: DiscoveryIntent, candidates: [DiscoveryCandidate], configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<DiscoveryEvaluation> {
        evaluationCalls += 1
        return .init(value: .init(reply: "", recommendations: []), diagnostics: [])
    }
    func analyzeSkillUsage(material: SkillUsageGuideMaterial, configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<SkillUsageGuide> { throw CancellationError() }
}
