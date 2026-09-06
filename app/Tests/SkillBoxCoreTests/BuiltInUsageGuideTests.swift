import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Manual Agnes Skill introductions", .serialized)
struct BuiltInUsageGuideTests {
    @Test("Opening a Skill never sends its files; the explicit button sends once")
    func openingIsLocalAndExplicitGenerationUsesAgnes() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [.success(Self.completeGuide)])
        let keyStore = ManualUsageGuideKeyStore(values: ["agnes": "user-agnes-key"])
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)

        _ = await model.skillUsageGuide(fixture.skill)
        _ = await model.skillUsageGuide(fixture.skill)
        #expect(await provider.requestCount() == 0)

        let generated = await model.generateSkillUsageGuide(fixture.skill)

        #expect(generated == Self.completeGuide)
        #expect(await provider.requestCount() == 1)
        #expect(await provider.lastProviderID() == "agnes")
        #expect(await provider.lastAPIKey() == "user-agnes-key")
        #expect(await keyStore.userInitiatedLoadCount() == 1)
        #expect(await keyStore.automaticLoadCount() == 0)
        #expect(await model.skillUsageGuide(fixture.skill) == Self.completeGuide)
    }

    @Test("Skill introductions always use Agnes even when Discovery uses another provider")
    func generationDoesNotFollowDiscoveryProviderSelection() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [.success(Self.completeGuide)])
        let keyStore = ManualUsageGuideKeyStore(values: [
            "agnes": "user-agnes-key",
            "deepseek": "user-deepseek-key",
        ])
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)
        model.aiSettings.selectedProviderID = "deepseek"

        _ = await model.generateSkillUsageGuide(fixture.skill)

        #expect(await provider.lastProviderID() == "agnes")
        #expect(await provider.lastAPIKey() == "user-agnes-key")
    }

    @Test("Without a verified Agnes key the button sends nothing and points to Settings")
    func missingAgnesConnectionNeverSends() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [.success(Self.completeGuide)])
        let model = fixture.model(provider: provider, keyStore: ManualUsageGuideKeyStore())

        let generated = await model.generateSkillUsageGuide(fixture.skill)

        #expect(generated == nil)
        #expect(await provider.requestCount() == 0)
        #expect(model.noticeMessage?.contains("设置") == true)
        #expect(model.noticeMessage?.contains("Agnes") == true)
    }

    @Test("A failed manual request keeps the old guide and a later click may retry")
    func failureKeepsCacheAndDoesNotBlockManualRetry() async throws {
        let oldGuide = SkillUsageGuide(
            purpose: "旧介绍仍然可用",
            useWhen: "需要保留已有说明时",
            starterPrompt: "继续使用这份 Skill",
            experienceSteps: ["打开旧介绍"],
            origin: .aiAssisted
        )
        let fixture = try await Fixture.make(cachedGuide: oldGuide, cachedPromptVersion: "usage-guide-v2")
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [
            .failure(TestFailure.unavailable),
            .success(Self.completeGuide),
        ])
        let keyStore = ManualUsageGuideKeyStore(values: ["agnes": "user-agnes-key"])
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)

        #expect(await model.generateSkillUsageGuide(fixture.skill) == nil)
        #expect(model.noticeMessage?.contains(TestFailure.unavailable.localizedDescription) == true)
        #expect(model.noticeMessage?.contains("failure.message") == false)
        #expect(model.noticeMessage?.contains("已有介绍已保留") == true)
        #expect(await model.skillUsageGuide(fixture.skill) == oldGuide)
        #expect(await model.generateSkillUsageGuide(fixture.skill) == Self.completeGuide)
        #expect(await provider.requestCount() == 2)
    }

    @Test("A truncated Agnes response is explained instead of hidden behind a generic failure")
    func truncatedResponseHasSpecificNotice() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let diagnostic = AIInvocationDiagnostic(
            providerID: "agnes",
            model: "agnes-2.5-flash",
            httpStatus: 200,
            finishReason: "length",
            responseLength: 1_819,
            errorCategory: .truncatedOutput,
            attemptCount: 1
        )
        let provider = ManualUsageGuideProviderSpy(results: [
            .failure(AIServiceError.invocation(.init(category: .truncatedOutput, diagnostic: diagnostic))),
        ])
        let keyStore = ManualUsageGuideKeyStore(values: ["agnes": "user-agnes-key"])
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)

        #expect(await model.generateSkillUsageGuide(fixture.skill) == nil)
        #expect(model.noticeMessage?.contains("返回的介绍不完整") == true)
        #expect(model.noticeMessage?.contains("已有介绍已保留") == true)
        #expect(model.noticeMessage?.contains("没有完成这次整理") == false)
    }

    @Test("Concurrent clicks for the same Skill share one in-flight Agnes request")
    func concurrentClicksAreDeduplicated() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [.success(Self.completeGuide)], delay: .milliseconds(20))
        let keyStore = ManualUsageGuideKeyStore(values: ["agnes": "user-agnes-key"])
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)

        async let first = model.generateSkillUsageGuide(fixture.skill)
        async let second = model.generateSkillUsageGuide(fixture.skill)
        let results = await [first, second]

        #expect(results.allSatisfy { $0 == Self.completeGuide })
        #expect(await provider.requestCount() == 1)
    }

    @Test("A cancelled macOS Keychain confirmation sends nothing and explains how to continue")
    func cancelledKeychainAuthorizationSendsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let provider = ManualUsageGuideProviderSpy(results: [.success(Self.completeGuide)])
        let keyStore = ManualUsageGuideKeyStore(
            values: ["agnes": "user-agnes-key"],
            userInitiatedError: .keychainAuthorizationNotCompleted
        )
        let model = fixture.model(provider: provider, keyStore: keyStore)
        connectAgnes(model)

        #expect(await model.generateSkillUsageGuide(fixture.skill) == nil)
        #expect(await provider.requestCount() == 0)
        #expect(model.noticeMessage?.contains("始终允许") == true)
    }

    private func connectAgnes(_ model: AppModel) {
        model.aiSettings.markConnectionVerified(providerID: "agnes")
        model.configuredAIProviderIDs.insert("agnes")
    }

    fileprivate static let completeGuide = SkillUsageGuide(
        purpose: "把一个新项目需要的说明、协作规则和基础目录一次搭好。",
        useWhen: "准备开始长期维护的 App、网站或软件项目时使用。",
        starterPrompt: "帮我为这个新项目搭好开发前的基础。",
        experienceSteps: ["先回答项目用途和技术偏好", "确认要创建的内容", "得到可直接开始开发的项目基础"],
        origin: .aiAssisted,
        sourceDocuments: ["SKILL.md"]
    )
}

private enum TestFailure: Error {
    case unavailable
}

private actor ManualUsageGuideKeyStore: AIKeyStore {
    private var values: [String: String]
    private let userInitiatedError: AIServiceError?
    private var automaticLoads = 0
    private var userInitiatedLoads = 0

    init(
        values: [String: String] = [:],
        userInitiatedError: AIServiceError? = nil
    ) {
        self.values = values
        self.userInitiatedError = userInitiatedError
    }

    func load(providerID: String) -> String? {
        automaticLoads += 1
        return values[providerID]
    }

    func loadForUserInitiatedAccess(providerID: String) throws -> String? {
        userInitiatedLoads += 1
        if let userInitiatedError { throw userInitiatedError }
        return values[providerID]
    }

    func automaticLoadCount() -> Int { automaticLoads }
    func userInitiatedLoadCount() -> Int { userInitiatedLoads }
    func save(_ apiKey: String, providerID: String) { values[providerID] = apiKey }
    func delete(providerID: String) { values.removeValue(forKey: providerID) }
}

private actor ManualUsageGuideProviderSpy: AIProvider {
    private var results: [Result<SkillUsageGuide, Error>]
    private let delay: Duration?
    private var requests: [(providerID: String, apiKey: String, material: SkillUsageGuideMaterial)] = []

    init(results: [Result<SkillUsageGuide, Error>], delay: Duration? = nil) {
        self.results = results
        self.delay = delay
    }

    func requestCount() -> Int { requests.count }
    func lastProviderID() -> String? { requests.last?.providerID }
    func lastAPIKey() -> String? { requests.last?.apiKey }

    func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws -> AIConnectionTestResult {
        .init(models: [configuration.model], diagnostic: .init(providerID: configuration.id, model: configuration.model))
    }

    func planDiscovery(
        message: String,
        previousIntent: DiscoveryIntent?,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryPlan> {
        throw TestFailure.unavailable
    }

    func evaluateCandidates(
        intent: DiscoveryIntent,
        candidates: [DiscoveryCandidate],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryEvaluation> {
        throw TestFailure.unavailable
    }

    func analyzeSkillUsage(
        material: SkillUsageGuideMaterial,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<SkillUsageGuide> {
        requests.append((configuration.id, apiKey, material))
        if let delay { try await Task.sleep(for: delay) }
        guard !results.isEmpty else { throw TestFailure.unavailable }
        return .init(value: try results.removeFirst().get(), diagnostics: [])
    }
}

private struct Fixture {
    let root: URL
    let storeRoot: URL
    let store: LibraryStore
    let skill: SkillRecord

    @MainActor
    func model(provider: any AIProvider, keyStore: any AIKeyStore) -> AppModel {
        AppModel(
            libraryRoot: storeRoot,
            store: store,
            homeDirectory: root.appendingPathComponent("home"),
            aiKeyStore: keyStore,
            aiProvider: provider,
            startBootstrap: false
        )
    }

    static func make(
        cachedGuide: SkillUsageGuide? = nil,
        cachedPromptVersion: String = SkillUsageGuideRecord.currentPromptVersion
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxManualAgnesGuideTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/demo", isDirectory: true)
        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: Use when starting a new project.
        ---

        Ask what the user is building, then create the project foundation.
        """.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let store = try LibraryStore(root: storeRoot)
        let skill = try await store.importCandidate(SkillCandidate(
            sourceURL: source,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "Use when starting a new project.",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source),
            source: .init(kind: .localFolder, displayName: "Fixture", locator: source.path),
            riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: source)
        ))
        if let cachedGuide {
            let guideURL = storeRoot
                .appendingPathComponent("AIReviews", isDirectory: true)
                .appendingPathComponent(skill.id.uuidString, isDirectory: true)
                .appendingPathComponent(skill.fingerprint, isDirectory: true)
                .appendingPathComponent("usage-guide.json")
            try FileManager.default.createDirectory(at: guideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(SkillUsageGuideRecord(
                skillID: skill.id,
                fingerprint: skill.fingerprint,
                promptVersion: cachedPromptVersion,
                providerID: "agnes",
                model: "agnes-2.5-flash",
                guide: cachedGuide
            )).write(to: guideURL, options: .atomic)
        }
        return Fixture(root: root, storeRoot: storeRoot, store: store, skill: skill)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
