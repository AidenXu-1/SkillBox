import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("AI authorization lifecycle")
struct AIAppModelSecurityTests {
    @Test("A connection result cannot verify configuration edited while the request was running")
    func connectionTestIsBoundToExactConfiguration() async throws {
        let fixture = try AIAppModelFixture()
        defer { fixture.remove() }
        let provider = BlockingConnectionProvider()
        let keyStore = InMemoryAIKeyStore()
        let model = fixture.model(provider: provider, keyStore: keyStore)
        model.updateAIConfiguration(
            providerID: "custom",
            baseURL: "https://old.example/v1",
            model: "old-model"
        )

        let testTask = Task { await model.saveAndTestAIKey(providerID: "custom", apiKey: "secret") }
        await provider.waitUntilStarted()
        #expect(await keyStore.userInitiatedLoadCount == 1)
        model.updateAIConfiguration(
            providerID: "custom",
            baseURL: "https://new.example/v1",
            model: "new-model"
        )
        await provider.release()
        await testTask.value

        #expect(!model.configuredAIProviderIDs.contains("custom"))
        #expect(!model.aiSettings.isConnectionVerified(providerID: "custom"))
        #expect(model.aiConnectionStatus == "配置已变化，请重新测试连接")
    }

    @Test("Deleting a key while connection testing prevents the late result from restoring authorization")
    func deletingKeyRevokesInFlightConnectionTest() async throws {
        let fixture = try AIAppModelFixture()
        defer { fixture.remove() }
        let provider = BlockingConnectionProvider()
        let keyStore = InMemoryAIKeyStore()
        let model = fixture.model(provider: provider, keyStore: keyStore)
        model.updateAIConfiguration(
            providerID: "custom",
            baseURL: "https://custom.example/v1",
            model: "custom-model"
        )

        let testTask = Task { await model.saveAndTestAIKey(providerID: "custom", apiKey: "secret") }
        await provider.waitUntilStarted()
        await model.deleteAIKey(providerID: "custom")
        await provider.release()
        await testTask.value

        #expect(await keyStore.load(providerID: "custom") == nil)
        #expect(!model.configuredAIProviderIDs.contains("custom"))
        #expect(!model.aiSettings.isConnectionVerified(providerID: "custom"))
    }

    @Test("A complete search can continue when verified candidates still await AI comparison")
    func completedSearchCanContinueItsNextEvaluationWindow() throws {
        let fixture = try AIAppModelFixture()
        defer { fixture.remove() }
        let model = fixture.model(provider: BlockingConnectionProvider(), keyStore: InMemoryAIKeyStore())
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "agnes"
        settings.markConnectionVerified(providerID: "agnes")
        model.aiSettings = settings

        let candidate = DiscoveryCandidate(
            id: "author/repo/pptx",
            name: "pptx",
            summary: "Create presentation files from scratch.",
            repositoryFullName: "author/repo",
            installCount: 500,
            evidence: .init(
                skillSummary: "Create presentation files from scratch.",
                skillContentVerified: true,
                repositoryIsPrivate: false,
                sources: [.skillDocument]
            )
        )
        var session = DiscoverySession(title: "PPT", storageFolderName: "ppt")
        session.candidates = [candidate]
        session.runs = [.init(
            queries: ["create pptx"],
            state: .completed,
            requestedLimitPerQuery: 64
        )]
        model.discoverySessions = [session]
        model.selectedDiscoverySessionID = session.id

        #expect(model.canContinueSelectedDiscoverySearch)

        session.runs[0].semanticEvaluatedCandidateIDs = [candidate.id]
        model.discoverySessions = [session]
        #expect(!model.canContinueSelectedDiscoverySearch)
    }

    @Test("Ineligible private candidates do not leave Continue stuck on forever")
    func completedSearchStopsWhenOnlyIneligibleCandidatesRemain() throws {
        let fixture = try AIAppModelFixture()
        defer { fixture.remove() }
        let model = fixture.model(provider: BlockingConnectionProvider(), keyStore: InMemoryAIKeyStore())
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "agnes"
        settings.markConnectionVerified(providerID: "agnes")
        model.aiSettings = settings

        let candidate = DiscoveryCandidate(
            id: "private/repo/pptx", name: "pptx", summary: "Create presentation files.",
            repositoryFullName: "private/repo",
            evidence: .init(skillSummary: "Create presentation files.", skillContentVerified: true, repositoryIsPrivate: true)
        )
        var session = DiscoverySession(title: "PPT", storageFolderName: "ppt-private")
        session.intent = .init(goal: "create pptx")
        session.candidates = [candidate]
        session.runs = [.init(queries: ["create pptx"], state: .completed, requestedLimitPerQuery: 1_000)]
        model.discoverySessions = [session]
        model.selectedDiscoverySessionID = session.id

        #expect(!model.canContinueSelectedDiscoverySearch)
    }
}

private struct AIAppModelFixture {
    let root: URL
    let store: LibraryStore
    let defaults: UserDefaults
    let defaultsSuite: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxAIAppModelTests-\(UUID().uuidString)", isDirectory: true)
        store = try LibraryStore(root: root.appendingPathComponent("store", isDirectory: true))
        defaultsSuite = "SkillBoxAIAppModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    @MainActor
    func model(provider: any AIProvider, keyStore: any AIKeyStore) -> AppModel {
        AppModel(
            libraryRoot: root.appendingPathComponent("store", isDirectory: true),
            store: store,
            homeDirectory: root,
            aiKeyStore: keyStore,
            aiProvider: provider,
            userDefaults: defaults,
            startBootstrap: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}

private actor InMemoryAIKeyStore: AIKeyStore {
    private var values: [String: String] = [:]
    private(set) var userInitiatedLoadCount = 0

    func load(providerID: String) -> String? { values[providerID] }
    func loadForUserInitiatedAccess(providerID: String) -> String? {
        userInitiatedLoadCount += 1
        return values[providerID]
    }
    func save(_ apiKey: String, providerID: String) { values[providerID] = apiKey }
    func delete(providerID: String) { values.removeValue(forKey: providerID) }
}

private actor BlockingConnectionProvider: AIProvider {
    private var started = false
    private var released = false

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { released = true }

    func testConnection(
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIConnectionTestResult {
        started = true
        while !released {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        return .init(
            models: [configuration.model],
            diagnostic: .init(providerID: configuration.id, model: configuration.model)
        )
    }

    func planDiscovery(
        message: String,
        previousIntent: DiscoveryIntent?,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryPlan> {
        throw CancellationError()
    }

    func evaluateCandidates(
        intent: DiscoveryIntent,
        candidates: [DiscoveryCandidate],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryEvaluation> {
        throw CancellationError()
    }

    func analyzeSkillUsage(
        material: SkillUsageGuideMaterial,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<SkillUsageGuide> {
        throw CancellationError()
    }
}
