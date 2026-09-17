import AppKit
import Combine
import CryptoKit
import Foundation
import SkillBoxCore

struct SkillBoxOperationProgress: Equatable {
    var title: String
    var detail: String
    var canCancel: Bool
}

private struct ManualUsageGuideFailure: Sendable {
    var message: String
    var category: AIInvocationErrorCategory?
}

private enum ManualUsageGuideTaskResult: Sendable {
    case success(SkillUsageGuide)
    case failure(ManualUsageGuideFailure)
}

struct AssignmentProposal: Identifiable {
    let id = UUID()
    let skill: SkillRecord
    let target: AgentTarget
    let desired: Bool
    let action: SyncAction?
    let changes: [SkillFileChange]

    var hasDifferentExistingContent: Bool {
        action?.blockReason == .unmanagedConflict &&
            action?.expectedSourceFingerprint != action?.expectedDestinationFingerprint
    }

    var hasSameExistingContent: Bool {
        action?.blockReason == .unmanagedConflict &&
            action?.expectedSourceFingerprint == action?.expectedDestinationFingerprint &&
            action?.expectedSourceFingerprint != nil
    }
}

enum GitHubReleasePackagePurpose {
    case importSkill
    case updateSkill(UUID)
    case migrateSkill(UUID)
}

struct GitHubReleasePackageChoice: Identifiable {
    let id = UUID()
    let version: GitHubRemoteVersion
    let locator: String
    let skillPath: String?
    let purpose: GitHubReleasePackagePurpose
    let importContext: GitHubImportContext?
}

struct GitHubImportContext {
    var locator: String
    var trackingMode: GitHubTrackingMode
    var desiredCandidateName: String?
    var usageGuide: SkillUsageGuide?
    var usageGuideSourceDigest: String?
}

struct GitHubInstallContentChoice: Identifiable {
    let id = UUID()
    let review: GitHubPackageReview
    let locator: String
    let purpose: GitHubReleasePackagePurpose
    let importContext: GitHubImportContext?
}

enum LocalSourceSetupPurpose: Hashable {
    case importSkills
    case editSkill(UUID)
    case relinkSkill(UUID)
}

struct LocalSourceSetup: Identifiable {
    let id = UUID()
    var reviews: [LocalPackageReview]
    var purpose: LocalSourceSetupPurpose
}

private struct PreparedLocalPackage {
    var package: LocalResolvedPackage
    var projectRootPath: String
    var bookmarkData: Data?
}

struct AIModelChoice: Identifiable, Hashable {
    var providerID: String
    var providerName: String
    var model: String
    var id: String { "\(providerID)::\(model)" }
}

private struct DiscoveryAIRequestTimeout: Error, Sendable {}

private final class DiscoveryAIRequestRace<Value: Sendable>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var pendingResult: Result<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    func installContinuation(_ continuation: Continuation) {
        let pending = lock.withLock { () -> Result<Value, Error>? in
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard !isResolved else { return true }
            operationTask = operation
            timeoutTask = timeout
            return false
        }
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func succeed(_ value: Value) {
        resolve(.success(value), cancelOperation: false)
    }

    func fail(_ error: Error, cancelOperation: Bool) {
        resolve(.failure(error), cancelOperation: cancelOperation)
    }

    private func resolve(_ result: Result<Value, Error>, cancelOperation: Bool) {
        let captured = lock.withLock { () -> (Continuation?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !isResolved else { return nil }
            isResolved = true
            let continuation = self.continuation
            if continuation == nil { pendingResult = result }
            self.continuation = nil
            let operation = operationTask
            let timeout = timeoutTask
            operationTask = nil
            timeoutTask = nil
            return (continuation, operation, timeout)
        }
        guard let captured else { return }
        if cancelOperation { captured.1?.cancel() }
        captured.2?.cancel()
        captured.0?.resume(with: result)
    }
}

private func withDiscoveryAIRequestDeadline<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = DiscoveryAIRequestRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.installContinuation(continuation)
            let operationTask = Task {
                do { race.succeed(try await operation()) }
                catch { race.fail(error, cancelOperation: false) }
            }
            let timeoutTask = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                race.fail(DiscoveryAIRequestTimeout(), cancelOperation: true)
            }
            race.installTasks(operation: operationTask, timeout: timeoutTask)
        }
    } onCancel: {
        race.fail(CancellationError(), cancelOperation: true)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let githubConnectionHintKey = "SkillBoxGitHubConnectionHint"
    private static let riskAcknowledgementsKey = "SkillBoxRiskAcknowledgementsV1"

    @Published var snapshot = LibrarySnapshot()
    @Published var scanResult: ScanResult?
    @Published var pendingCandidates: [SkillCandidate] = [] {
        didSet { scheduleDeferredStartupBackupCheckIfReady() }
    }
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var activeConflict: ConflictGroup?
    @Published var syncPlan: SyncPlan?
    @Published var isBusy = false {
        didSet { scheduleDeferredStartupBackupCheckIfReady() }
    }
    @Published private(set) var isCheckingLocalSources = false
    @Published var statusMessage = "准备查看本机 Skills"
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var showOnboarding = false
    @Published var githubURL = ""
    @Published var updatingSkillID: UUID?
    @Published var githubTrackingMode: GitHubTrackingMode = .latestStableRelease
    @Published var pendingGitHubVersion: GitHubRemoteVersion?
    @Published var pendingUpdateChanges: [SkillFileChange] = []
    @Published var pendingUpdateBeforeMarkdown = ""
    @Published var pendingUpdateAfterMarkdown = ""
    @Published var githubAuthorization: GitHubDeviceAuthorization?
    @Published var isGitHubConnected = false
    @Published var isWaitingForGitHubRepositorySelection = false
    @Published var githubLoginStatus = ""
    @Published var githubAuthorizedRepositories: [GitHubRepositorySummary] = []
    @Published var operationProgress: SkillBoxOperationProgress?
    @Published private(set) var lastDeletedSkill: DeletedSkillBackup? {
        didSet { scheduleDeleteUndoDismissal() }
    }
    private var deleteUndoDismissTask: Task<Void, Never>?
    private var deleteUndoPaused = false
    private let deleteUndoDuration: Duration
    @Published private(set) var pendingDeletionAfterSyncSkillID: UUID?
    @Published private(set) var pendingUndoTransaction: SyncTransaction? {
        didSet { scheduleDeferredStartupBackupCheckIfReady() }
    }
    @Published var canRetryGitHubWithDefaultBranch = false
    @Published var canRetryGitHubConnection = false
    @Published var pendingReleasePackageChoice: GitHubReleasePackageChoice?
    @Published var pendingInstallContentChoice: GitHubInstallContentChoice?
    @Published var pendingLocalSourceSetup: LocalSourceSetup? {
        didSet { scheduleDeferredStartupBackupCheckIfReady() }
    }
    @Published var pendingLocalIgnoredChangedPaths: [String] = []
    @Published var discoverySessions: [DiscoverySession] = []
    @Published var selectedDiscoverySessionID: UUID?
    @Published var selectedDiscoveryCandidateID: String?
    @Published var discoveryDraft = ""
    @Published var isDiscoverySearching = false
    @Published var discoveryRunState: DiscoveryRunState?
    @Published private(set) var activeDiscoverySessionID: UUID?
    @Published var discoveryStorageBytes: Int64 = 0
    @Published var aiSettings = AISettings.defaults
    @Published var configuredAIProviderIDs: Set<String> = []
    @Published var isTestingAIConnection = false
    @Published var aiConnectionStatus = ""
    @Published private(set) var generatingUsageGuideSkillIDs = Set<UUID>()
    @Published private(set) var usageGuideRevision = 0

    let libraryRoot: URL
    let discoverySessionsDirectory: URL
    private let store: LibraryStore
    private let discoveryStore: DiscoverySessionStore
    private let usageGuideStore: SkillUsageGuideStore
    private let aiSettingsStore: AISettingsStore
    private let aiKeyStore: any AIKeyStore
    private let aiProvider: any AIProvider
    private let discoveryAIRequestTimeout: Duration
    private let userDefaults: UserDefaults
    private let injectedGitHubProvider: GitHubSourceProvider?
    private let injectedRoutedDiscoveryProvider: RoutedSkillDiscoveryProvider?
    private lazy var routedDiscoveryProvider = injectedRoutedDiscoveryProvider ?? DefaultSkillDiscovery.make(tokenProvider: githubSession)
    private let planner: any SyncPlanner
    private let executor = TransactionalSyncExecutor()
    private let updateCoordinator = SkillUpdateCoordinator()
    private let localPackageResolver: LocalSkillPackageResolver
    private var localSourceMonitoringTask: Task<Void, Never>?
    @Published private(set) var isCheckingRollbackBackups = false
    @Published private(set) var backupCheckResult: String?
    private var startupBackupCheckPending = false
    private var deferredStartupBackupCheckTask: Task<Void, Never>?
    private var lastReportedBackupMaintenanceIssue: String?
    private let homeDirectory: URL
    private lazy var githubDeviceClient = GitHubDeviceFlowClient(clientID: githubClientID)
    private lazy var githubSession = GitHubAuthenticatedSession(
        client: githubDeviceClient,
        credentialStore: KeychainGitHubCredentialStore()
    )
    private lazy var githubProvider = injectedGitHubProvider ?? GitHubSourceProvider(tokenProvider: githubSession)
    private lazy var githubUpdateChecker = GitHubUpdateChecker(checker: githubProvider, store: store)
    private lazy var automaticGitHubUpdateChecker = GitHubUpdateChecker(
        checker: GitHubSourceProvider(),
        store: store
    )
    private var githubLoginTask: Task<Void, Never>?
    private var remoteOperationTask: Task<Void, Never>?
    private var pendingGitHubPackageRecipes: [String: GitHubPackageRecipe] = [:]
    private var pendingLocalPackages: [String: PreparedLocalPackage] = [:]
    private var pendingLocalUpdateState: LocalSourceState?
    private var pendingDiscoveryCandidateName: String?
    private var pendingDiscoveryUsageGuide: SkillUsageGuide?
    private var pendingDiscoveryUsageGuideSourceDigest: String?
    private var discoveryCandidateSelectionTask: Task<Void, Never>?
    private var discoveryCandidateSelectionGenerationID: UUID?
    private var discoverySearchTask: Task<Void, Never>?
    private var discoveryQueueTask: Task<Void, Never>?
    @Published var discoveryQueuePaused = false
    private var activeGitHubPreviewOperationID: UUID?
    private var retryGitHubImportContext: GitHubImportContext?
    private var invalidatedDiscoverySessionIDs = Set<UUID>()
    private var aiAuthorizationGeneration = 0
    private var riskAcknowledgementDigests: [String: String] = [:]
    private var pendingSyncAssignments: [Assignment]?
    private var manualUsageGuideTasks: [String: Task<ManualUsageGuideTaskResult, Never>] = [:]

    var githubClientID: String { Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubClientID") as? String ?? "" }
    var isGitHubConfigured: Bool { !githubClientID.isEmpty && githubInstallURL != nil }
    var githubInstallURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubInstallURL") as? String else { return nil }
        return URL(string: value)
    }

    init(
        libraryRoot customLibraryRoot: URL? = nil,
        store providedStore: LibraryStore? = nil,
        planner: any SyncPlanner = DefaultSyncPlanner(),
        homeDirectory customHomeDirectory: URL? = nil,
        aiKeyStore providedAIKeyStore: (any AIKeyStore)? = nil,
        aiProvider providedAIProvider: (any AIProvider)? = nil,
        githubProvider providedGitHubProvider: GitHubSourceProvider? = nil,
        routedDiscoveryProvider providedRoutedDiscoveryProvider: RoutedSkillDiscoveryProvider? = nil,
        localPackageResolver: LocalSkillPackageResolver = LocalSkillPackageResolver(),
        discoveryAIRequestTimeout: Duration = .seconds(20),
        userDefaults: UserDefaults = .standard,
        startBootstrap: Bool = true,
        deleteUndoDuration: Duration = .seconds(6)
    ) {
        self.deleteUndoDuration = deleteUndoDuration
        homeDirectory = customHomeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        libraryRoot = customLibraryRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SkillBox")
        discoverySessionsDirectory = libraryRoot.appendingPathComponent("SearchSessions", isDirectory: true)
        do {
            if let providedStore {
                store = providedStore
            } else {
                store = try LibraryStore(
                    root: libraryRoot,
                    trashHandler: SystemSkillTrash(),
                    migratesLegacyDeletedItems: true
                )
            }
            discoveryStore = try DiscoverySessionStore(root: libraryRoot)
            usageGuideStore = try SkillUsageGuideStore(root: libraryRoot)
            aiSettingsStore = try AISettingsStore(root: libraryRoot)
        } catch {
            fatalError("无法准备 SkillBox 的本地保存位置：\(error.localizedDescription)")
        }
        self.planner = planner
        self.localPackageResolver = localPackageResolver
        aiKeyStore = providedAIKeyStore ?? KeychainAIKeyStore()
        aiProvider = providedAIProvider ?? OpenAICompatibleProvider()
        self.discoveryAIRequestTimeout = discoveryAIRequestTimeout
        injectedGitHubProvider = providedGitHubProvider
        injectedRoutedDiscoveryProvider = providedRoutedDiscoveryProvider
        self.userDefaults = userDefaults
        riskAcknowledgementDigests = userDefaults.dictionary(forKey: Self.riskAcknowledgementsKey) as? [String: String] ?? [:]
        showOnboarding = !UserDefaults.standard.bool(forKey: "SkillBoxOnboardingCompleted")
        if startBootstrap {
            Task { await bootstrap() }
        }
    }

    deinit {
        localSourceMonitoringTask?.cancel()
        deferredStartupBackupCheckTask?.cancel()
    }

    func needsRiskAcknowledgement(for skill: SkillRecord) -> Bool {
        guard skill.riskReport.requiresUserAttention, !skill.riskReport.isBlocked else { return false }
        return riskAcknowledgementDigests[skill.id.uuidString] != riskAcknowledgementDigest(for: skill)
    }

    func isRiskAcknowledged(for skill: SkillRecord) -> Bool {
        skill.riskReport.requiresUserAttention &&
            !skill.riskReport.isBlocked &&
            !needsRiskAcknowledgement(for: skill)
    }

    func shouldShowRiskAttention(for skill: SkillRecord) -> Bool {
        skill.riskReport.isBlocked || needsRiskAcknowledgement(for: skill)
    }

    func acknowledgeRisk(for skill: SkillRecord) {
        guard skill.riskReport.requiresUserAttention, !skill.riskReport.isBlocked else { return }
        objectWillChange.send()
        riskAcknowledgementDigests[skill.id.uuidString] = riskAcknowledgementDigest(for: skill)
        userDefaults.set(riskAcknowledgementDigests, forKey: Self.riskAcknowledgementsKey)
    }

    private func riskAcknowledgementDigest(for skill: SkillRecord) -> String {
        let findings = skill.riskReport.actionableFindings
            .sorted { lhs, rhs in
                let left = [
                    String(lhs.severity.rawValue), lhs.category.rawValue, lhs.relativePath, lhs.title, lhs.evidence,
                ]
                let right = [
                    String(rhs.severity.rawValue), rhs.category.rawValue, rhs.relativePath, rhs.title, rhs.evidence,
                ]
                return left.lexicographicallyPrecedes(right)
            }
            .flatMap { finding in
                [
                    String(finding.severity.rawValue),
                    finding.category.rawValue,
                    finding.relativePath,
                    finding.title,
                    finding.evidence,
                ]
            }
        let components = [
            skill.id.uuidString,
            skill.fingerprint,
            String(skill.riskReport.scannedFileCount),
        ] + findings
        let payload = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func bootstrap() async {
        let recoveryWarnings = await store.recoveryWarnings
        if !recoveryWarnings.isEmpty {
            errorMessage = recoveryWarnings.joined(separator: "\n")
            statusMessage = "旧数据无法读取，原文件已保留"
        }
        do {
            let migratedDeletedItems = try await store.moveLegacyDeletedItemsToTrash()
            if migratedDeletedItems > 0 {
                statusMessage = "已将 \(migratedDeletedItems) 份旧删除内容移到废纸篓"
            }
        } catch {
            errorMessage = "旧版删除内容暂时无法移到废纸篓：\(error.localizedDescription)"
        }
        do {
            let recovered = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: store)
            if recovered.contains(where: { $0.status == .failed }) {
                errorMessage = "上次未完成的安装没有全部恢复，请到「设置 → 操作记录与恢复」查看详情。"
            } else if !recovered.isEmpty {
                statusMessage = "已恢复上次异常中断的安装操作"
            }
        } catch { present(error) }
        let persisted = await store.currentSnapshot()
        let targets = BuiltinAgentAdapters.reconciledTargets(
            persisted: persisted.targets,
            homeDirectory: homeDirectory
        )
        do { try await store.replaceTargets(targets) } catch { present(error) }
        do { try await store.refreshRiskReports(using: StaticRiskAnalyzer()) } catch { present(error) }
        await reload()
        // Persisted deletions remain available in History, not as new notices on launch.
        do { _ = try await discoveryStore.recoverInterruptedRuns() } catch { present(error) }
        await reloadDiscoverySessions()
        await reloadCredentialHints()
        await scanInstalledSkills()
        startLocalSourceMonitoring()
        await checkRollbackBackupsOnStartup()
        await checkAllGitHubUpdatesIfStale()
    }

    func reload() async {
        snapshot = await store.currentSnapshot()
        await refreshBackupMaintenanceIssue()
        refreshPlan()
    }

    var selectedDiscoverySession: DiscoverySession? {
        guard let selectedDiscoverySessionID else { return nil }
        return discoverySessions.first { $0.id == selectedDiscoverySessionID }
    }

    var selectedDiscoveryCandidate: DiscoveryCandidate? {
        guard let selectedDiscoveryCandidateID else { return nil }
        return selectedDiscoverySession?.candidates.first { $0.id == selectedDiscoveryCandidateID }
    }

    var isSelectedDiscoverySearching: Bool {
        isDiscoverySearching && activeDiscoverySessionID == selectedDiscoverySessionID
    }

    var canContinueSelectedDiscoverySearch: Bool {
        guard let session = selectedDiscoverySession,
              let run = session.runs.last,
              run.state == .completed || run.state == .partiallyCompleted || run.state == .failed
        else { return false }
        let intent = session.intent ?? DiscoveryIntent(goal: session.title)
        let evaluated = Set(run.semanticEvaluatedCandidateIDs)
        let evaluationFrontier = intent.route == .exact
            ? []
            : DiscoveryCandidateRanker.candidatesForEvaluation(
                session.candidates,
                intent: intent,
                allowPrivateSkillContent: aiSettings.isPrivateContentSharingAllowedForSelectedProvider
            )
        let hasUnevaluatedAICandidate = aiSettings.selectedVerifiedConfiguration != nil
            && evaluationFrontier.contains { !evaluated.contains($0.id) }
        if hasUnevaluatedAICandidate { return true }
        if run.state == .failed || run.failedSourceCount > 0 || run.failedQueryCount > 0
            || run.failedCandidateVerificationCount > 0 || run.deferredCandidateVerificationCount > 0
        {
            return true
        }
        return run.state == .partiallyCompleted && run.requestedLimitPerQuery < 1_000
    }

    var selectedAIConfiguration: AIProviderConfiguration? {
        aiSettings.selectedConfiguration
    }

    var availableAIModelChoices: [AIModelChoice] {
        aiSettings.configurations.flatMap { configuration -> [AIModelChoice] in
            guard configuredAIProviderIDs.contains(configuration.id) else { return [] }
            return configuration.recommendedModels.map {
                AIModelChoice(providerID: configuration.id, providerName: configuration.displayName, model: $0)
            }
        }
    }

    var selectedAIModelChoiceID: String? {
        guard let configuration = aiSettings.selectedVerifiedConfiguration,
              configuredAIProviderIDs.contains(configuration.id), !configuration.model.isEmpty
        else { return nil }
        return "\(configuration.id)::\(configuration.model)"
    }

    var aiInputModelLabel: String {
        guard aiSettings.isEnabled else { return "AI 未启用" }
        guard let configuration = aiSettings.selectedVerifiedConfiguration,
              configuredAIProviderIDs.contains(configuration.id)
        else { return "配置 AI" }
        return configuration.model
    }

    func reloadAISettings() async {
        aiSettings = await aiSettingsStore.load()
        configuredAIProviderIDs = Set(aiSettings.configurations.compactMap { configuration in
            aiSettings.isConnectionVerified(providerID: configuration.id) ? configuration.id : nil
        })
    }

    func reloadCredentialHints() async {
        await reloadAISettings()
        isGitHubConnected = userDefaults.bool(forKey: Self.githubConnectionHintKey)
    }

    func setAIEnabled(_ enabled: Bool) {
        if aiSettings.isEnabled != enabled {
            invalidateAIAuthorizationTasks()
        }
        aiSettings.isEnabled = enabled
        persistAISettings()
    }

    func selectAIProvider(_ id: String) {
        guard aiSettings.configuration(id: id) != nil else { return }
        if aiSettings.selectedProviderID != id {
            aiSettings.invalidatePrivateContentConsent()
            invalidateAIAuthorizationTasks()
        }
        aiSettings.selectedProviderID = id
        aiConnectionStatus = ""
        persistAISettings()
    }

    func selectAIModel(providerID: String, model: String) {
        guard let index = aiSettings.configurations.firstIndex(where: { $0.id == providerID }) else { return }
        if aiSettings.configurations[index].model != model {
            aiSettings.invalidatePrivateContentConsent()
            invalidateAIAuthorizationTasks()
        }
        aiSettings.configurations[index].model = model
        if !aiSettings.isConnectionVerified(providerID: providerID) {
            configuredAIProviderIDs.remove(providerID)
        }
        aiSettings.selectedProviderID = providerID
        aiSettings.isEnabled = true
        persistAISettings()
    }

    func updateAIConfiguration(providerID: String, baseURL: String? = nil, model: String? = nil) {
        guard let index = aiSettings.configurations.firstIndex(where: { $0.id == providerID }) else { return }
        let recipientWillChange = baseURL.map { $0 != aiSettings.configurations[index].baseURL } == true
            || model.map { $0 != aiSettings.configurations[index].model } == true
        if recipientWillChange {
            aiSettings.invalidatePrivateContentConsent()
            invalidateAIAuthorizationTasks()
        }
        if let baseURL { aiSettings.configurations[index].baseURL = baseURL }
        if let model { aiSettings.configurations[index].model = model }
        if !aiSettings.isConnectionVerified(providerID: providerID) {
            configuredAIProviderIDs.remove(providerID)
        }
        aiConnectionStatus = ""
        persistAISettings()
    }

    func setAllowPrivateSkillContent(_ allowed: Bool) {
        aiSettings.setPrivateContentSharingAllowed(allowed)
        persistAISettings()
    }

    func saveAndTestAIKey(providerID: String, apiKey: String) async {
        isTestingAIConnection = true
        aiConnectionStatus = "正在测试连接…"
        defer { isTestingAIConnection = false }
        do {
            invalidateAIAuthorizationTasks()
            aiSettings.invalidateConnectionVerification(providerID: providerID)
            configuredAIProviderIDs.remove(providerID)
            try await aiSettingsStore.save(aiSettings)
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try await aiKeyStore.save(trimmed, providerID: providerID)
            }
            guard let key = try await aiKeyStore.loadForUserInitiatedAccess(providerID: providerID),
                  let configuration = aiSettings.configuration(id: providerID)
            else { throw AIServiceError.missingAPIKey }
            let authorizationGeneration = aiAuthorizationGeneration
            let result = try await aiProvider.testConnection(configuration: configuration, apiKey: key)
            guard authorizationGeneration == aiAuthorizationGeneration,
                  aiSettings.configuration(id: providerID) == configuration
            else {
                aiConnectionStatus = "配置已变化，请重新测试连接"
                return
            }
            aiSettings.markConnectionVerified(providerID: providerID)
            try await aiSettingsStore.save(aiSettings)
            configuredAIProviderIDs.insert(providerID)
            if result.models.contains(configuration.model) {
                aiConnectionStatus = "连接成功，当前模型可用"
            } else if result.models.isEmpty {
                aiConnectionStatus = "连接成功，但服务商没有返回模型列表"
            } else {
                aiConnectionStatus = "连接成功，但当前模型不在可用列表中"
            }
        } catch {
            aiConnectionStatus = error.localizedDescription
        }
    }

    func deleteAIKey(providerID: String) async {
        invalidateAIAuthorizationTasks()
        aiSettings.invalidateConnectionVerification(providerID: providerID)
        configuredAIProviderIDs.remove(providerID)
        do {
            try await aiKeyStore.delete(providerID: providerID)
            try await aiSettingsStore.save(aiSettings)
            aiConnectionStatus = "已删除这个服务商的本机密钥"
        } catch { aiConnectionStatus = error.localizedDescription }
    }

    private func invalidateAIAuthorizationTasks() {
        aiAuthorizationGeneration &+= 1
        discoverySearchTask?.cancel()
        cancelDiscoveryCandidateSelection()
    }

    func openAIKeyPage(providerID: String) {
        guard let url = aiSettings.configuration(id: providerID)?.apiKeyPage else { return }
        NSWorkspace.shared.open(url)
    }

    private func persistAISettings() {
        let settings = aiSettings
        Task {
            do { try await aiSettingsStore.save(settings) }
            catch { present(error) }
        }
    }

    func reloadDiscoverySessions(allowAutomaticSelection: Bool = true) async {
        discoverySessions = await discoveryStore.loadAll()
        discoveryStorageBytes = await discoveryStore.storageSize()
        if let selectedDiscoverySessionID,
           !discoverySessions.contains(where: { $0.id == selectedDiscoverySessionID })
        {
            self.selectedDiscoverySessionID = nil
            selectedDiscoveryCandidateID = nil
        }
        if allowAutomaticSelection, selectedDiscoverySessionID == nil {
            selectedDiscoverySessionID = discoverySessions.first?.id
        }
        if let session = selectedDiscoverySession {
            selectedDiscoveryCandidateID = Self.preferredDiscoveryCandidateID(in: session)
        }
    }

    func beginNewDiscovery() {
        if isDiscoverySearching { discoveryQueuePaused = true }
        cancelDiscoveryCandidateSelection()
        selectedDiscoverySessionID = nil
        selectedDiscoveryCandidateID = nil
        discoveryDraft = ""
        statusMessage = "可以开始一次新的 Skill 寻找"
    }

    func selectDiscoverySession(_ id: UUID?) {
        if id != selectedDiscoverySessionID, isDiscoverySearching { discoveryQueuePaused = true }
        cancelDiscoveryCandidateSelection()
        selectedDiscoverySessionID = id
        let session = discoverySessions.first { $0.id == id }
        selectedDiscoveryCandidateID = session.flatMap(Self.preferredDiscoveryCandidateID)
        discoveryDraft = ""
    }

    func selectDiscoveryCandidate(_ id: String) {
        cancelDiscoveryCandidateSelection()
        selectedDiscoveryCandidateID = id
        guard let session = selectedDiscoverySession else { return }
        let generationID = UUID()
        discoveryCandidateSelectionGenerationID = generationID
        discoveryCandidateSelectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.discoveryCandidateSelectionGenerationID == generationID {
                    self.discoveryCandidateSelectionTask = nil
                    self.discoveryCandidateSelectionGenerationID = nil
                }
            }
            do {
                guard try await self.discoveryStore.selectCandidate(
                    sessionID: session.id,
                    storageFolderName: session.storageFolderName,
                    candidateID: id
                ) != nil,
                !Task.isCancelled
                else { return }
                await self.reloadDiscoverySessions(allowAutomaticSelection: false)
            } catch is CancellationError {
                return
            } catch {
                self.present(error)
            }
        }
    }

    private func cancelDiscoveryCandidateSelection() {
        discoveryCandidateSelectionTask?.cancel()
        discoveryCandidateSelectionTask = nil
        discoveryCandidateSelectionGenerationID = nil
    }

    func startDiscoverySearch() {
        let text = discoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= DiscoveryEvaluationLimits.maximumPlanningInputCharacters else {
            noticeMessage = "这条消息超过 2,000 字，请拆成几条发送。原文已保留。"
            return
        }
        if discoverySearchTask != nil || isDiscoverySearching {
            guard let session = selectedDiscoverySession, session.id == activeDiscoverySessionID else {
                noticeMessage = "另一个对话还在处理，请先停止或等它完成。"
                return
            }
            let previous = discoveryQueueTask
            discoveryQueueTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                do {
                    try await self.discoveryStore.enqueue(text, sessionID: session.id, storageFolderName: session.storageFolderName)
                    if self.discoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.discoveryDraft = "" }
                    await self.reloadDiscoverySessions(allowAutomaticSelection: false)
                } catch { self.present(error) }
            }
            return
        }
        discoveryDraft = ""
        launchDiscoveryMessage(text)
    }

    private func launchDiscoveryMessage(_ text: String, existingMessageID: UUID? = nil, resumingQueue: Bool = false) {
        // Previously retained input requires the explicit resume action. A new
        // message must not revive a queue paused by stop, navigation or restart.
        discoveryQueuePaused = !resumingQueue && selectedDiscoverySession?.queuedMessages.isEmpty == false
        isDiscoverySearching = true
        discoveryRunState = .understanding
        cancelDiscoveryCandidateSelection()
        let requestedSessionID = selectedDiscoverySessionID
        discoverySearchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isDiscoverySearching = false
                self.discoveryRunState = nil
                self.activeDiscoverySessionID = nil
                self.discoverySearchTask = nil
            }
            var nextText = text
            var messageID = existingMessageID
            var boundSessionID = requestedSessionID
            repeat {
                await self.submitDiscoverySearch(message: nextText, existingMessageID: messageID, requestedSessionID: boundSessionID)
                let sessionID = self.lastProcessedDiscoverySessionID
                boundSessionID = sessionID
                await self.discoveryQueueTask?.value
                guard !Task.isCancelled, !self.discoveryQueuePaused,
                      let session = self.selectedDiscoverySession, session.id == sessionID,
                      !self.invalidatedDiscoverySessionIDs.contains(session.id)
                else { break }
                do {
                    guard let next = try await self.discoveryStore.claimQueued(sessionID: session.id, storageFolderName: session.storageFolderName) else { break }
                    await self.reloadDiscoverySessions(allowAutomaticSelection: false)
                    nextText = next.text
                    messageID = next.id
                } catch { self.present(error); break }
            } while !Task.isCancelled
            self.discoverySearchTask = nil
        }
    }

    private var lastProcessedDiscoverySessionID: UUID?

    func resumeDiscoveryQueue() {
        guard discoverySearchTask == nil, !isDiscoverySearching, let session = selectedDiscoverySession else { return }
        discoverySearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.discoveryStore.claimQueued(sessionID: session.id, storageFolderName: session.storageFolderName)
                await self.reloadDiscoverySessions(allowAutomaticSelection: false)
                self.discoverySearchTask = nil
                guard self.selectedDiscoverySessionID == session.id, let message else { return }
                self.launchDiscoveryMessage(message.text, existingMessageID: message.id, resumingQueue: true)
            } catch { self.discoverySearchTask = nil; self.present(error) }
        }
    }

    func cancelDiscoverySearch() {
        discoveryQueuePaused = true
        discoverySearchTask?.cancel()
    }

    private func submitDiscoverySearch(message text: String, existingMessageID: UUID? = nil, requestedSessionID: UUID?) async {
        guard !Task.isCancelled, !text.isEmpty else {
            if text.isEmpty { noticeMessage = "先说说你想让 AI 帮你完成什么。" }
            return
        }
        isDiscoverySearching = true
        discoveryRunState = .understanding
        // launchDiscoveryMessage owns completion, including queue persistence.
        // Clearing these here briefly exposes an idle UI with a live task and
        // can reject the user's immediate reply to a clarification.
        var session: DiscoverySession
        let isNewSession: Bool
        if let requestedSessionID, let current = discoverySessions.first(where: { $0.id == requestedSessionID }) {
            session = current
            isNewSession = false
        } else {
            guard requestedSessionID == nil else { return }
            session = await discoveryStore.makeSession(title: String(text.prefix(28)))
            isNewSession = true
        }
        let missingUserHistory = DiscoveryConversation.hasUnverifiableLegacyConditions(in: session)
        session.intent = DiscoveryConversation.userGroundedIntent(in: session)
        if missingUserHistory {
            let notice = "这条旧记录缺少原始用户条件的完整依据，已保守保留已有必须条件；你可以明确撤回或重新说明条件。"
            if !session.notices.contains(where: { $0.text == notice }) {
                session.notices.append(.init(text: notice, kind: .information))
            }
        }
        let carriesForwardPreviousSearch = text == "继续深挖更多来源" && session.continuationInvalidated != true
        let previousContinuationRun = carriesForwardPreviousSearch ? session.runs.last : nil
        activeDiscoverySessionID = session.id
        lastProcessedDiscoverySessionID = session.id
        if selectedDiscoverySessionID == requestedSessionID { selectedDiscoverySessionID = session.id }
        invalidatedDiscoverySessionIDs.remove(session.id)
        if selectedDiscoverySessionID == session.id, let selectedDiscoveryCandidateID { session.selectedCandidateID = selectedDiscoveryCandidateID }
        var contextSession = session
        contextSession.messages.removeAll { $0.id == existingMessageID }
        let planningContext = DiscoveryPlanningContext(session: contextSession, nextMessage: text)
        let priorIntent = session.intent
        let userMessage = DiscoveryMessage(id: existingMessageID ?? UUID(), role: .user, text: text)
        if !session.messages.contains(where: { $0.id == userMessage.id }) { session.messages.append(userMessage) }
        let action = DiscoveryConversation.action(for: text, session: session)
        if action != .search {
            await handleDiscoveryConversation(text: text, action: action, session: &session, isNewSession: isNewSession, userMessageID: userMessage.id)
            return
        }
        let fallbackPlan = DiscoveryConversation.searchPlan(message: text, session: session)
        let continuesTask = priorIntent?.goal == fallbackPlan.intent.goal
        session.pendingClarification = nil
        if !continuesTask {
            if !session.recommendedCandidates.isEmpty {
                appendDiscoveryReply("上一任务的结果：" + session.recommendedCandidates.map(\.name).joined(separator: "、"), to: &session,
                    references: Array(session.recommendedCandidates.prefix(6)).map(DiscoveryConversationReference.init))
                session.messages[session.messages.count - 1].createdAt = userMessage.createdAt.addingTimeInterval(-0.001)
                session.messages.removeAll { $0.id == userMessage.id }
                session.messages.append(userMessage)
            }
            session.contextStartMessageID = userMessage.id
            session.candidates = []
            session.selectedCandidateID = nil
        }
        let runID = UUID()
        session.runs.append(.init(
            id: runID,
            queries: fallbackPlan.queries,
            route: fallbackPlan.intent.route,
            state: .understanding
        ))
        session.updatedAt = Date()
        guard await saveDiscoveryResult(session, allowCreate: isNewSession) else { return }

        var plan = fallbackPlan
        if carriesForwardPreviousSearch,
           let previousContinuationRun,
           !previousContinuationRun.queries.isEmpty
        {
            plan = DiscoveryPlan(
                intent: session.intent ?? fallbackPlan.intent,
                queries: previousContinuationRun.queries
            )
        }
        var configurationUsed: AIProviderConfiguration?
        var keyUsed: String?
        var authorizationGenerationUsed: Int?
        var fallbackReason: String?
        var diagnostics: [AIInvocationDiagnostic] = []
        if fallbackPlan.intent.route != .exact,
           let configuration = aiSettings.selectedVerifiedConfiguration,
           configuredAIProviderIDs.contains(configuration.id)
        {
            do {
                if let key = try await aiKeyStore.load(providerID: configuration.id), !key.isEmpty {
                    let authorizationGeneration = aiAuthorizationGeneration
                    guard aiSettings.selectedVerifiedConfiguration == configuration,
                          configuredAIProviderIDs.contains(configuration.id)
                    else { throw CancellationError() }
                    configurationUsed = configuration
                    keyUsed = key
                    authorizationGenerationUsed = authorizationGeneration
                    if !carriesForwardPreviousSearch {
                        let aiProvider = self.aiProvider
                        let previousIntent = continuesTask ? priorIntent : nil
                        let result = try await withDiscoveryAIRequestDeadline(discoveryAIRequestTimeout) {
                            try await aiProvider.planDiscovery(
                                message: text,
                                previousIntent: previousIntent,
                                context: planningContext,
                                configuration: configuration,
                                apiKey: key
                            )
                        }
                        guard authorizationGeneration == aiAuthorizationGeneration else {
                            throw CancellationError()
                        }
                        plan = DiscoveryIntentPlanner.reconcile(
                            modelPlan: result.value,
                            deterministicPlan: fallbackPlan
                        )
                        diagnostics.append(contentsOf: result.diagnostics)
                    }
                } else {
                    fallbackReason = "本轮未使用 AI 语义筛选，当前结果来自已核对的公开资料。"
                }
            } catch {
                if error is CancellationError {
                    await markDiscoveryRunInterrupted(in: &session, runID: runID)
                    return
                }
                if let diagnostic = Self.aiDiagnostic(from: error) { diagnostics.append(diagnostic) }
                fallbackReason = Self.aiNotice(for: error, phase: "需求整理")
            }
        } else if fallbackPlan.intent.route != .exact {
            fallbackReason = "本轮未使用 AI 语义筛选，当前结果来自已核对的公开资料。"
        }
        session.intent = plan.intent
        session.continuationInvalidated = false
        var evidenceIntent = plan.intent
        for query in plan.queries.dropFirst()
        where !plan.intent.targets.contains(where: { $0.kind == .author })
            && !evidenceIntent.preferences.contains(query) {
            // Author aliases identify ownership, not writing capability.
            // Supplemental queries are created before any candidate document is
            // read. Carry them into local matching so a precise English query
            // does not find a niche Skill only to lose it at the final gate.
            evidenceIntent.preferences.append(query)
        }
        Self.updateDiscoveryRun(in: &session, id: runID, state: .understanding, queries: plan.queries, diagnostics: diagnostics, fallbackReason: fallbackReason)

        if plan.needsClarification {
            let question = plan.clarifyingQuestion.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
                ?? "你希望这个 Skill 直接完成什么任务，最后交付什么结果？"
            session.pendingClarification = question
            appendDiscoveryReply(question, to: &session)
            Self.updateDiscoveryRun(in: &session, id: runID, state: .completed, queries: plan.queries, diagnostics: diagnostics, fallbackReason: fallbackReason)
            session.updatedAt = Date()
            _ = await saveDiscoveryResult(session)
            return
        }

        do {
            discoveryRunState = .recalling
            let searchScope: DiscoverySearchScope = carriesForwardPreviousSearch ? .deep : .initial
            let previousLimit = previousContinuationRun?.requestedLimitPerQuery ?? 0
            let previouslyEvaluatedCandidateIDs = Set(previousContinuationRun?.semanticEvaluatedCandidateIDs ?? [])
            let previouslyRecommendedCandidateIDs = Set(previousContinuationRun?.semanticRecommendedCandidateIDs ?? [])
            let requestedLimitPerQuery = searchScope.limitPerQuery(after: previousLimit)
            Self.updateDiscoveryRun(
                in: &session,
                id: runID,
                state: .recalling,
                queries: plan.queries,
                diagnostics: diagnostics,
                fallbackReason: fallbackReason,
                requestedLimitPerQuery: requestedLimitPerQuery,
                semanticEvaluatedCandidateIDs: Array(previouslyEvaluatedCandidateIDs),
                semanticRecommendedCandidateIDs: previousContinuationRun?.semanticRecommendedCandidateIDs ?? []
            )
            session.updatedAt = Date()
            guard await saveDiscoveryResult(session) else { return }

            try Task.checkCancellation()
            let routedResult = try await routedDiscoveryProvider.search(
                plan: plan,
                limitPerQuery: requestedLimitPerQuery
            )
            let result = routedResult.batch
            try Task.checkCancellation()
            let replacesPreviousCandidates = !continuesTask || plan.intent.route == .exact
                || plan.intent.targets.contains { $0.kind == .skillName || $0.kind == .repository }
            let mergedCandidates = replacesPreviousCandidates
                ? result.candidates
                : DiscoverySearchCoordinator.mergeCandidates(
                    existing: session.candidates,
                    incoming: result.candidates
                )
            let accumulatedCandidates = mergedCandidates
            if let incompleteNotice = DiscoverySearchFeedback.incompleteNotice(
                for: result,
                canSearchDeeper: requestedLimitPerQuery < 1_000
            ) {
                fallbackReason = Self.combinedNotice(
                    fallbackReason,
                    incompleteNotice
                )
            }
            discoveryRunState = .verifying
            Self.updateDiscoveryRun(
                in: &session,
                id: runID,
                state: .verifying,
                queries: plan.queries,
                diagnostics: diagnostics,
                fallbackReason: fallbackReason,
                retrievedCandidateCount: accumulatedCandidates.count,
                searchResult: result
            )
            session.updatedAt = Date()
            guard await saveDiscoveryResult(session) else { return }

            var evaluation: DiscoveryEvaluation?
            let evaluationFrontier = plan.intent.route == .exact
                ? []
                : DiscoveryCandidateRanker.candidatesForEvaluation(
                    accumulatedCandidates,
                    intent: evidenceIntent,
                    allowPrivateSkillContent: aiSettings.isPrivateContentSharingAllowedForSelectedProvider
                )
            let evaluationCandidates = DiscoveryEvaluationBatcher.nextEvaluationWindow(
                from: evaluationFrontier,
                excluding: previouslyEvaluatedCandidateIDs
            )
            let evaluationIntent = evidenceIntent
            if let configurationUsed, let keyUsed, let authorizationGenerationUsed {
                do {
                    discoveryRunState = .evaluating
                    Self.updateDiscoveryRun(
                        in: &session,
                        id: runID,
                        state: .evaluating,
                        queries: plan.queries,
                        diagnostics: diagnostics,
                        fallbackReason: fallbackReason,
                        retrievedCandidateCount: accumulatedCandidates.count,
                        evaluationCandidateCount: evaluationCandidates.count
                    )
                    session.updatedAt = Date()
                    guard await saveDiscoveryResult(session) else { return }
                    if !evaluationCandidates.isEmpty {
                        var preliminaryEvaluations: [DiscoveryEvaluation] = []
                        var comparisonFailureReported = false
                        for batch in DiscoveryEvaluationBatcher.preliminaryBatches(from: evaluationCandidates) {
                            do {
                                try Task.checkCancellation()
                                guard authorizationGenerationUsed == aiAuthorizationGeneration,
                                      aiSettings.selectedVerifiedConfiguration == configurationUsed,
                                      configuredAIProviderIDs.contains(configurationUsed.id)
                                else { throw CancellationError() }
                                let aiProvider = self.aiProvider
                                let evaluated = try await withDiscoveryAIRequestDeadline(discoveryAIRequestTimeout) {
                                    try await aiProvider.evaluateCandidates(
                                        intent: evaluationIntent,
                                        candidates: batch,
                                        configuration: configurationUsed,
                                        apiKey: keyUsed
                                    )
                                }
                                preliminaryEvaluations.append(evaluated.value)
                                diagnostics.append(contentsOf: evaluated.diagnostics)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                if let diagnostic = Self.aiDiagnostic(from: error) { diagnostics.append(diagnostic) }
                                if !comparisonFailureReported {
                                    fallbackReason = Self.combinedNotice(fallbackReason, Self.aiNotice(for: error, phase: "分组比较"))
                                    comparisonFailureReported = true
                                }
                            }
                        }

                        var finalEvaluation: DiscoveryEvaluation?
                        let finalists = DiscoveryEvaluationBatcher.finalists(
                            from: preliminaryEvaluations,
                            candidates: evaluationCandidates
                        )
                        if preliminaryEvaluations.count > 1, finalists.count > 1 {
                            do {
                                try Task.checkCancellation()
                                guard authorizationGenerationUsed == aiAuthorizationGeneration,
                                      aiSettings.selectedVerifiedConfiguration == configurationUsed,
                                      configuredAIProviderIDs.contains(configurationUsed.id)
                                else { throw CancellationError() }
                                let aiProvider = self.aiProvider
                                let final = try await withDiscoveryAIRequestDeadline(discoveryAIRequestTimeout) {
                                    try await aiProvider.evaluateCandidates(
                                        intent: evaluationIntent,
                                        candidates: finalists,
                                        configuration: configurationUsed,
                                        apiKey: keyUsed
                                    )
                                }
                                finalEvaluation = final.value
                                diagnostics.append(contentsOf: final.diagnostics)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                if let diagnostic = Self.aiDiagnostic(from: error) { diagnostics.append(diagnostic) }
                                fallbackReason = Self.combinedNotice(fallbackReason, Self.aiNotice(for: error, phase: "最终比较"))
                            }
                        }
                        evaluation = DiscoveryEvaluationBatcher.merge(
                            preliminary: preliminaryEvaluations,
                            final: finalEvaluation
                        )
                    }
                } catch {
                    if error is CancellationError {
                        await markDiscoveryRunInterrupted(in: &session, runID: runID)
                        return
                    }
                    if let diagnostic = Self.aiDiagnostic(from: error) { diagnostics.append(diagnostic) }
                    fallbackReason = Self.combinedNotice(fallbackReason, Self.aiNotice(for: error, phase: "候选比较"))
                }
            }
            let currentEvaluatedCandidateIDs = Set(evaluation?.recommendations.map(\.candidateID) ?? [])
            let currentRecommendedCandidateIDs = Set(
                evaluation?.recommendations.filter { $0.tier == .recommended }.map(\.candidateID) ?? []
            )
            let combinedEvaluatedCandidateIDs = previouslyEvaluatedCandidateIDs.union(currentEvaluatedCandidateIDs)
            let combinedRecommendedCandidateIDs = previouslyRecommendedCandidateIDs.union(currentRecommendedCandidateIDs)
            let currentRecommendedOrder = evaluation?.recommendations
                .filter { $0.tier == .recommended }
                .map(\.candidateID) ?? []
            let previousRecommendedOrder = (previousContinuationRun?.semanticRecommendedCandidateIDs ?? [])
                .filter { !currentRecommendedCandidateIDs.contains($0) }
            let semanticRecommendationOrder = (currentRecommendedOrder + previousRecommendedOrder).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            let semanticRouting = combinedEvaluatedCandidateIDs.isEmpty
                ? DiscoverySemanticRouting(relevantCandidateIDs: nil, evaluatedCandidateIDs: nil, recommendedRanks: nil)
                : DiscoverySemanticRouting(
                    relevantCandidateIDs: combinedRecommendedCandidateIDs,
                    evaluatedCandidateIDs: combinedEvaluatedCandidateIDs,
                    recommendedRanks: Dictionary(
                        uniqueKeysWithValues: semanticRecommendationOrder.enumerated().map { ($0.element, $0.offset) }
                    )
                )
            let ranked = plan.intent.route == .exact
                ? DiscoveryCandidateRanker.rankExact(accumulatedCandidates)
                : DiscoveryCandidateRanker.rank(
                    accumulatedCandidates,
                    intent: evidenceIntent,
                    originalQueryCandidateIDs: result.originalQueryCandidateIDs,
                    relevantCandidateIDs: semanticRouting.relevantCandidateIDs,
                    evaluatedCandidateIDs: semanticRouting.evaluatedCandidateIDs,
                    semanticRecommendationRanks: semanticRouting.recommendedRanks
                )
            let previousStates = session.candidates.reduce(into: [String: DiscoveryCandidateState]()) { $0[$1.id] = $1.state }
            let prepared = (ranked.recommended + ranked.other).map { candidate -> DiscoveryCandidate in
                var updated = candidate
                updated.state = previousStates[candidate.id] ?? .notTried
                // Model output may only break an otherwise exact local tie. Do
                // not retain any candidate-conditioned copy in the record or UI.
                updated.recommendationReason = nil
                updated.suitableWhen = nil
                updated.examplePrompt = nil
                updated.experienceSteps = []
                updated.limitations = []
                updated.usageGuide = nil
                updated.usageGuideSourceDigest = nil
                return updated
            }
            session.candidates = prepared
            if session.selectedCandidateID == nil || !ranked.recommended.contains(where: { $0.id == session.selectedCandidateID }) {
                session.selectedCandidateID = ranked.recommended.first?.id
            }
            Self.updateDiscoveryRun(
                in: &session,
                id: runID,
                state: result.isExhaustive ? .completed : .partiallyCompleted,
                queries: plan.queries,
                diagnostics: diagnostics,
                fallbackReason: fallbackReason,
                recommendedCandidateIDs: ranked.recommended.map(\.id),
                otherCandidateIDs: ranked.other.map(\.id),
                usedAI: evaluation != nil,
                route: routedResult.route,
                outcome: routedResult.outcome,
                semanticEvaluatedCandidateIDs: Array(combinedEvaluatedCandidateIDs),
                semanticRecommendedCandidateIDs: semanticRecommendationOrder
            )
            switch routedResult.outcome {
            case .exactNotFound:
                guard result.isExhaustive else {
                    session.updatedAt = Date()
                    _ = await saveDiscoveryResult(session)
                    statusMessage = "暂时无法完成核验，请稍后重试"
                    return
                }
                let target = plan.intent.targets.first?.value ?? plan.intent.goal
                session.notices.append(.init(
                    runID: runID,
                    text: "没有找到与“\(target)”完全一致且能读取真实 SKILL.md 的结果，没有用相似 Skill 代替。",
                    kind: .information
                ))
            case .exactAmbiguous:
                session.notices.append(.init(
                    runID: runID,
                    text: "找到了 \(ranked.recommended.count) 个同名且已核对 SKILL.md 的结果，已全部列出，由你根据作者和仓库选择。",
                    kind: .information
                ))
            case .exactFound, .communityRecommendations, .hybridResults:
                break
            }
            session.updatedAt = Date()
            let resultNames = session.recommendedCandidates.prefix(3).map(\.name).joined(separator: "、")
            var finalReply = session.recommendedCandidates.isEmpty
                ? "这轮暂时没有得到足够可靠的推荐。可以补充具体用途，或给我名称和仓库地址。"
                : "核验到 \(session.recommendedCandidates.count) 份可优先查看的 Skill：\(resultNames)。你可以接着问它们的区别或用法。"
            if let conditionSummary = DiscoveryConstraintAssessment.summary(candidates: session.candidates, intent: session.intent) {
                finalReply += "\n\n" + conditionSummary
            }
            appendDiscoveryReply(finalReply, to: &session,
                references: Array(session.recommendedCandidates.prefix(3)).map(DiscoveryConversationReference.init))
            guard await saveDiscoveryResult(session) else { return }
            if routedResult.outcome == .exactNotFound {
                statusMessage = "没有找到已核对的精确结果"
            } else {
                statusMessage = ranked.recommended.isEmpty ? "暂时没有足够可靠的推荐" : "已找到 \(ranked.recommended.count) 个值得先看的 Skill"
            }
        } catch is CancellationError {
            await markDiscoveryRunInterrupted(in: &session, runID: runID)
        } catch {
            Self.updateDiscoveryRun(in: &session, id: runID, state: .failed, queries: plan.queries, diagnostics: diagnostics, fallbackReason: error.localizedDescription)
            session.notices.append(.init(
                runID: runID,
                text: "本轮公开来源查询未完成，上一轮的有效候选已保留，可以直接继续深挖。",
                kind: .failure
            ))
            session.updatedAt = Date()
            _ = await saveDiscoveryResult(session)
            statusMessage = "本次寻找未完成，可以重试"
        }
    }

    private func appendDiscoveryReply(_ text: String, to session: inout DiscoverySession, references: [DiscoveryConversationReference] = [], configuration: AIProviderConfiguration? = nil) {
        var message = DiscoveryMessage(role: .assistant, text: text, providerID: configuration?.id, model: configuration?.model)
        message.origin = configuration == nil ? "conversation-local-v1" : "conversation-evidence-v1"
        message.references = references.isEmpty ? nil : references
        session.messages.append(message)
        session.updatedAt = Date()
    }

    private func handleDiscoveryConversation(text: String, action: DiscoveryConversationAction, session: inout DiscoverySession, isNewSession: Bool, userMessageID: UUID) async {
        if case let .removeConstraint(term) = action {
            guard let intent = session.intent else {
                appendDiscoveryReply("当前还没有寻找任务。先告诉我你想找什么 Skill。", to: &session)
                _ = await saveDiscoveryResult(session, allowCreate: isNewSession)
                return
            }
            session.intent = DiscoveryConversation.removeConstraint(term, from: intent)
            session.continuationInvalidated = true
            session.contextStartMessageID = userMessageID
            session.pendingClarification = nil
            appendDiscoveryReply("已撤回“\(term)”条件，当前任务摘要已更新。继续寻找时会使用新条件。", to: &session)
            _ = await saveDiscoveryResult(session, allowCreate: isNewSession)
            return
        }
        let refs = DiscoveryConversation.references(for: text, action: action, session: session)
        guard await saveDiscoveryResult(session, allowCreate: isNewSession) else { return }
        var answer = DiscoveryConversation.fallbackReply(action: action, references: refs)
        var usedConfiguration: AIProviderConfiguration?
        if (action == .explain || action == .compare), !refs.isEmpty,
           action != .compare || refs.count >= 2,
           let configuration = aiSettings.selectedVerifiedConfiguration,
           configuredAIProviderIDs.contains(configuration.id) {
            do {
                if let key = try await aiKeyStore.load(providerID: configuration.id), !key.isEmpty {
                    let generation = aiAuthorizationGeneration
                    let provider = aiProvider
                    let task = DiscoveryConversation.taskSummary(session) ?? "了解当前 Skill"
                    let response = try await withDiscoveryAIRequestDeadline(discoveryAIRequestTimeout) {
                        try await provider.answerDiscovery(message: text, task: task, references: refs, configuration: configuration, apiKey: key)
                    }
                    guard generation == aiAuthorizationGeneration else { throw CancellationError() }
                    answer = response.value.text
                    usedConfiguration = configuration
                }
            } catch is CancellationError {
                appendDiscoveryReply("已停止回答，已有对话和待处理补充仍保留。", to: &session)
                _ = await saveDiscoveryResult(session)
                return
            } catch {
                answer = "这次 AI 回答未完成，先保留可核对的作者资料。\n\n" + answer
            }
        }
        guard !Task.isCancelled else { return }
        appendDiscoveryReply(answer, to: &session, references: refs, configuration: usedConfiguration)
        _ = await saveDiscoveryResult(session)
        statusMessage = "已回答，本轮没有新增搜索"
    }

    private static func updateDiscoveryRun(
        in session: inout DiscoverySession,
        id: UUID,
        state: DiscoveryRunState,
        queries: [String],
        diagnostics: [AIInvocationDiagnostic],
        fallbackReason: String?,
        recommendedCandidateIDs: [String]? = nil,
        otherCandidateIDs: [String]? = nil,
        usedAI: Bool? = nil,
        route: DiscoverySearchRoute? = nil,
        outcome: DiscoveryRouteOutcome? = nil,
        retrievedCandidateCount: Int? = nil,
        evaluationCandidateCount: Int? = nil,
        searchResult: DiscoveryBatchSearchResult? = nil,
        requestedLimitPerQuery: Int? = nil,
        semanticEvaluatedCandidateIDs: [String]? = nil,
        semanticRecommendedCandidateIDs: [String]? = nil
    ) {
        guard let index = session.runs.firstIndex(where: { $0.id == id }) else { return }
        session.runs[index].state = state
        session.runs[index].queries = queries
        session.runs[index].diagnostics = diagnostics
        session.runs[index].fallbackReason = fallbackReason
        if let recommendedCandidateIDs { session.runs[index].recommendedCandidateIDs = recommendedCandidateIDs }
        if let otherCandidateIDs { session.runs[index].otherCandidateIDs = otherCandidateIDs }
        if let usedAI { session.runs[index].usedAI = usedAI }
        if let route { session.runs[index].route = route }
        if let outcome { session.runs[index].outcome = outcome }
        if let retrievedCandidateCount { session.runs[index].retrievedCandidateCount = retrievedCandidateCount }
        if let evaluationCandidateCount { session.runs[index].evaluationCandidateCount = evaluationCandidateCount }
        if let requestedLimitPerQuery { session.runs[index].requestedLimitPerQuery = requestedLimitPerQuery }
        if let semanticEvaluatedCandidateIDs { session.runs[index].semanticEvaluatedCandidateIDs = semanticEvaluatedCandidateIDs }
        if let semanticRecommendedCandidateIDs { session.runs[index].semanticRecommendedCandidateIDs = semanticRecommendedCandidateIDs }
        if let searchResult {
            session.runs[index].requestUsage = searchResult.requestUsage
            session.runs[index].retryAfter = searchResult.rateLimitedUntil
            session.runs[index].failedSourceCount = searchResult.failedSourceCount
            session.runs[index].failedQueryCount = searchResult.failedQueryCount
            session.runs[index].saturatedQueryCount = searchResult.saturatedQueryCount
            session.runs[index].failedCandidateVerificationCount = searchResult.failedCandidateVerificationCount
            session.runs[index].deferredCandidateVerificationCount = searchResult.deferredCandidateVerificationCount
            session.runs[index].unresolvedCommunityMentions = searchResult.unresolvedCommunityMentions
        }
    }

    private static func aiDiagnostic(from error: Error) -> AIInvocationDiagnostic? {
        guard case let AIServiceError.invocation(failure) = error else { return nil }
        return failure.diagnostic
    }

    private static func combinedNotice(_ first: String?, _ second: String) -> String {
        guard let first, !first.isEmpty else { return second }
        return "\(first) \(second)"
    }

    private static func preferredDiscoveryCandidateID(in session: DiscoverySession) -> String? {
        let visible = session.recommendedCandidates
        if let selected = session.selectedCandidateID, visible.contains(where: { $0.id == selected }) {
            return selected
        }
        return visible.first?.id
    }

    private static func aiNotice(for error: Error, phase: String) -> String {
        guard case let AIServiceError.invocation(failure) = error else {
            return "AI 没有完成本轮\(phase)，当前结果来自已核对的公开资料。"
        }
        let reason: String
        switch failure.category {
        case .authenticationFailure: reason = "鉴权未通过"
        case .rateLimited: reason = "服务商暂时限流"
        case .emptyContent: reason = "模型没有返回最终结果"
        case .truncatedOutput: reason = "模型输出被截断"
        case .malformedJSON, .schemaValidationFailed: reason = "模型返回的结构无法校验"
        case .networkFailure: reason = "网络请求未完成"
        case .serviceFailure: reason = "服务商请求未完成"
        }
        return "AI \(phase)未完成（\(reason)），当前结果来自已核对的公开资料。"
    }

    @discardableResult
    private func saveDiscoveryResult(_ session: DiscoverySession, allowCreate: Bool = false) async -> Bool {
        guard !invalidatedDiscoverySessionIDs.contains(session.id) else { return false }
        do {
            if allowCreate {
                try await discoveryStore.save(session)
            } else if try await discoveryStore.updateSearchSnapshot(session) == nil {
                return false
            }
            await reloadDiscoverySessions(allowAutomaticSelection: false)
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func markDiscoveryRunInterrupted(in session: inout DiscoverySession, runID: UUID) async {
        guard !invalidatedDiscoverySessionIDs.contains(session.id) else { return }
        guard let index = session.runs.firstIndex(where: { $0.id == runID }) else { return }
        session.runs[index].state = .interrupted
        session.runs[index].fallbackReason = nil
        session.updatedAt = Date()
        _ = await saveDiscoveryResult(session)
        statusMessage = "已停止寻找，已有结果仍保留"
    }

    func deleteDiscoverySession(_ session: DiscoverySession) async {
        invalidatedDiscoverySessionIDs.insert(session.id)
        if activeDiscoverySessionID == session.id { cancelDiscoverySearch() }
        if selectedDiscoverySessionID == session.id {
            cancelDiscoveryCandidateSelection()
        }
        do {
            try await discoveryStore.delete(session)
            if selectedDiscoverySessionID == session.id {
                selectedDiscoverySessionID = nil
                selectedDiscoveryCandidateID = nil
            }
            await reloadDiscoverySessions()
            statusMessage = "已删除这条寻找记录"
        } catch { present(error) }
    }

    func deleteAllDiscoverySessions() async {
        invalidatedDiscoverySessionIDs.formUnion(discoverySessions.map(\.id))
        if let activeDiscoverySessionID { invalidatedDiscoverySessionIDs.insert(activeDiscoverySessionID) }
        cancelDiscoverySearch()
        cancelDiscoveryCandidateSelection()
        do {
            try await discoveryStore.deleteAll()
            selectedDiscoverySessionID = nil
            selectedDiscoveryCandidateID = nil
            await reloadDiscoverySessions()
            statusMessage = "已清空寻找记录"
        } catch { present(error) }
    }

    func importDiscoveryCandidate(_ candidate: DiscoveryCandidate) {
        guard let url = candidate.importURL else {
            noticeMessage = "这个候选缺少可用的 GitHub 地址，暂时无法加入。"
            return
        }
        githubURL = url.absoluteString
        githubTrackingMode = .latestStableRelease
        startGitHubPreview(context: .init(
            locator: url.absoluteString,
            trackingMode: .latestStableRelease,
            desiredCandidateName: candidate.name,
            usageGuide: nil,
            usageGuideSourceDigest: nil
        ))
    }

    func continueDiscoverySearch() {
        guard selectedDiscoverySession?.intent != nil, !isDiscoverySearching else { return }
        discoveryDraft = "继续深挖更多来源"
        startDiscoverySearch()
    }

    func isDiscoveryCandidateAdded(_ candidate: DiscoveryCandidate) -> Bool {
        snapshot.skills.contains { skill in
            skill.source.repository?.lowercased() == candidate.repositoryFullName.lowercased() &&
                (skill.canonicalName.caseInsensitiveCompare(candidate.name) == .orderedSame ||
                    skill.source.skillPath == candidate.skillPath)
        }
    }

    // Refresh only configured destinations and managed installation state. Skill
    // sources are explicitly imported; installed copies are never discovery roots.
    func scanInstalledSkills() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await refreshTargetStatuses()
        do {
            try await store.reconcileMissingInstallations()
            await reload()
            scanResult = ScanResult(candidates: [], duplicateGroups: [], conflicts: [], diagnostics: [])
            statusMessage = "安装状态已刷新"
        } catch {
            present(error)
        }
    }

    func refreshSkills() async {
        guard !isBusy, !isCheckingLocalSources else { return }
        await scanInstalledSkills()
        await checkAllLocalSources(reportResult: true)
    }

    func startLocalSourceMonitoring(interval: Duration = .seconds(30)) {
        guard localSourceMonitoringTask == nil else { return }
        localSourceMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAllLocalSources()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stopLocalSourceMonitoring() {
        localSourceMonitoringTask?.cancel()
        localSourceMonitoringTask = nil
    }

    func checkRollbackBackupsOnStartup() async {
        // An already-running manual check also satisfies this launch request.
        guard !isCheckingRollbackBackups else { return }
        startupBackupCheckPending = true
        guard canCheckRollbackBackups else { return }
        await cleanRollbackBackups()
    }

    private var canCheckRollbackBackups: Bool {
        !isBusy && pendingUndoTransaction == nil && pendingCandidates.isEmpty && pendingLocalSourceSetup == nil
    }

    private func scheduleDeferredStartupBackupCheckIfReady() {
        guard startupBackupCheckPending, canCheckRollbackBackups, !isCheckingRollbackBackups,
              deferredStartupBackupCheckTask == nil else { return }
        deferredStartupBackupCheckTask = Task { [weak self] in
            guard let self else { return }
            self.deferredStartupBackupCheckTask = nil
            // Confirming a preview can clear it and set isBusy in the same turn.
            // Read the final state here instead of trusting the state at enqueue.
            guard !Task.isCancelled, self.startupBackupCheckPending,
                  self.canCheckRollbackBackups, !self.isCheckingRollbackBackups else { return }
            await self.cleanRollbackBackups()
        }
    }

    private func refreshBackupMaintenanceIssue() async {
        let issue = await store.currentBackupMaintenanceIssue()
        if let issue {
            let message = "备份清理未完成：\(issue)"
            backupCheckResult = message
            if lastReportedBackupMaintenanceIssue != issue { noticeMessage = message }
        } else if let previous = lastReportedBackupMaintenanceIssue {
            let message = "备份清理未完成：\(previous)"
            if backupCheckResult == message { backupCheckResult = "上次备份清理问题已解决。" }
            if noticeMessage == message { noticeMessage = nil }
        }
        lastReportedBackupMaintenanceIssue = issue
    }

    func cleanRollbackBackups() async {
        guard !isCheckingRollbackBackups else { return }
        guard canCheckRollbackBackups else {
            backupCheckResult = "请先完成当前操作，再检查备份。"
            return
        }
        startupBackupCheckPending = false
        isCheckingRollbackBackups = true
        isBusy = true
        statusMessage = ""
        defer {
            isCheckingRollbackBackups = false
            isBusy = false
        }
        do {
            let removed = try await store.pruneRollbackBackups()
            snapshot = await store.currentSnapshot()
            await refreshBackupMaintenanceIssue()
            let root = libraryRoot
            let appRemoved = try await Task.detached(priority: .utility) {
                try AppRollbackBackups.clean(libraryRoot: root)
            }.value
            await refreshBackupMaintenanceIssue()
            guard lastReportedBackupMaintenanceIssue == nil else { return }
            let total = removed + appRemoved
            backupCheckResult = total == 0 ? "检查完成，没有需要清理的备份。" : "检查完成，已清理 \(total) 份过期或被替代的备份。"
            statusMessage = total == 0 ? "备份检查完成" : "已清理 \(total) 份备份"
        } catch {
            snapshot = await store.currentSnapshot()
            await refreshBackupMaintenanceIssue()
            backupCheckResult = "检查未全部完成，请重试：\(error.localizedDescription)"
            noticeMessage = backupCheckResult
        }
    }

    /// Check sources without preparing an update transaction or opening a sheet.
    /// The existing per-Skill action still owns the explicit update preview.
    func checkAllLocalSources(reportResult: Bool = false) async {
        guard !isBusy, !isCheckingLocalSources,
              pendingCandidates.isEmpty, pendingLocalSourceSetup == nil
        else { return }
        isCheckingLocalSources = true
        defer { isCheckingLocalSources = false }
        let current = await store.currentSnapshot()
        let trackedIDs = Set(current.skills.filter { $0.source.kind == .localFolder }.map(\.id))
        let states = current.localSourceStates.filter { trackedIDs.contains($0.skillID) }
        var checkedStates: [LocalSourceState] = []
        var saveFailed = false
        for state in states {
            guard !Task.isCancelled, !isBusy, pendingCandidates.isEmpty, pendingLocalSourceSetup == nil else { break }
            let resolver = localPackageResolver
            var checked: LocalSourceState
            do {
                // File reads, hashing and temporary packaging stay off the UI thread.
                let result = try await Task.detached(priority: .utility) {
                    try await resolver.check(state: state)
                }.value
                if let candidate = result.candidate { cleanupLocalCandidates([candidate]) }
                checked = result.state
            } catch {
                checked = state
                checked.lastCheckError = error.localizedDescription
            }
            guard !Task.isCancelled, !isBusy, pendingCandidates.isEmpty, pendingLocalSourceSetup == nil else { break }
            do {
                if try await store.recordLocalSourceCheck(checked, expected: state) {
                    checkedStates.append(checked)
                }
            } catch {
                saveFailed = true
            }
        }
        snapshot = await store.currentSnapshot()
        if reportResult {
            let updates = checkedStates.filter { $0.lastCheckError == nil && $0.status == .updateAvailable }.count
            let reviews = checkedStates.filter { $0.lastCheckError == nil && $0.status == .packageReviewRequired }.count
            let unavailable = checkedStates.filter { $0.lastCheckError != nil || $0.status == .sourceUnavailable }.count
            if saveFailed || checkedStates.count != states.count {
                statusMessage = "安装状态已刷新；部分本地来源尚未完成检查，请重试"
            } else if unavailable > 0 {
                statusMessage = "已检查本地来源：\(updates) 份有更新，\(reviews) 份需确认内容，\(unavailable) 份无法检查"
            } else if updates > 0 || reviews > 0 {
                statusMessage = "已检查本地来源：\(updates) 份有更新，\(reviews) 份需确认内容"
            } else {
                statusMessage = states.isEmpty ? "安装状态已刷新" : "安装状态已刷新；\(states.count) 份本地 Skill 本次检查一致"
            }
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "SkillBoxOnboardingCompleted")
        showOnboarding = false
    }

    func prepareScanImport() {
        guard let scanResult else { return }
        activeConflict = nil
        let byName = Dictionary(grouping: scanResult.candidates, by: \.canonicalName)
        pendingCandidates = byName.values.flatMap { candidates in
            Dictionary(grouping: candidates, by: \.fingerprint).values.compactMap(\.first)
        }.sorted { $0.canonicalName < $1.canonicalName }
        selectedCandidateIDs = Set(byName.values.compactMap { candidates in
            let versions = Dictionary(grouping: candidates, by: \.fingerprint)
            guard versions.count == 1 else { return nil }
            return versions.values.first?.first?.id
        })
        updatingSkillID = nil
    }

    func prepareConflictImport(_ conflict: ConflictGroup) {
        activeConflict = conflict
        pendingCandidates = conflict.versions
            .compactMap { $0.candidates.first }
            .sorted { $0.source.displayName < $1.source.displayName }
        selectedCandidateIDs = []
        updatingSkillID = nil
    }

    func sourceSummary(for candidate: SkillCandidate) -> String {
        guard let version = activeConflict?.versions.first(where: { $0.fingerprint == candidate.fingerprint }) else {
            return candidate.source.displayName
        }
        let sources = Set(version.candidates.map(\.source.displayName))
        return sources.sorted().joined(separator: "、")
    }

    func setCandidate(_ candidate: SkillCandidate, selected: Bool) {
        if selected {
            for other in pendingCandidates where other.canonicalName == candidate.canonicalName {
                selectedCandidateIDs.remove(other.id)
            }
            selectedCandidateIDs.insert(candidate.id)
        } else {
            selectedCandidateIDs.remove(candidate.id)
        }
    }

    func previewLocalFolder(_ url: URL) async {
        guard let candidates = await loadPreview(provider: LocalFolderSourceProvider(), locator: url.path) else { return }
        do {
            let reviews = try candidates.map {
                try localPackageResolver.review(candidate: $0, projectRoot: url)
            }
            guard !reviews.isEmpty else {
                noticeMessage = "这个文件夹里没有找到可以添加的 Skill。"
                return
            }
            pendingCandidates = []
            selectedCandidateIDs = []
            activeConflict = nil
            updatingSkillID = nil
            pendingLocalSourceSetup = .init(reviews: reviews, purpose: .importSkills)
            statusMessage = "请确认本地开发源和可使用内容"
        } catch { present(error) }
    }

    func confirmLocalSourceSetup(
        _ setup: LocalSourceSetup,
        includePathsByCandidate: [String: [String]]
    ) async {
        guard pendingLocalSourceSetup?.id == setup.id, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var prepared: [PreparedLocalPackage] = []
        do {
            for review in setup.reviews {
                guard let includePaths = includePathsByCandidate[review.candidate.id] else { continue }
                let package = try await localPackageResolver.confirm(
                    review: review,
                    includePaths: includePaths
                )
                prepared.append(.init(
                    package: package,
                    projectRootPath: review.projectRootPath,
                    bookmarkData: LocalSkillPackageResolver.bookmarkData(
                        for: URL(fileURLWithPath: review.projectRootPath, isDirectory: true)
                    )
                ))
            }
            guard !prepared.isEmpty else {
                noticeMessage = "请至少选择一份要添加的 Skill。"
                return
            }
            pendingLocalSourceSetup = nil
            switch setup.purpose {
            case .importSkills:
                pendingLocalPackages = [:]
                let candidates = prepared.map { preparedPackage -> SkillCandidate in
                    let candidate = preparedPackage.package.candidate
                    var stored = preparedPackage
                    stored.package.candidate = candidate
                    pendingLocalPackages[candidate.id] = stored
                    return candidate
                }
                activeConflict = nil
                updatingSkillID = nil
                pendingCandidates = candidates
                selectedCandidateIDs = Set(candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
                statusMessage = "已准备持续跟踪的纯净 Skill"
            case let .editSkill(skillID), let .relinkSkill(skillID):
                guard let preparedPackage = prepared.first,
                      let skill = snapshot.skills.first(where: { $0.id == skillID })
                else { return }
                try await prepareLocalPendingUpdate(preparedPackage, skill: skill)
            }
        } catch {
            for item in prepared { cleanupLocalCandidates([item.package.candidate]) }
            present(error)
        }
    }

    func cancelLocalSourceSetup() {
        pendingLocalSourceSetup = nil
        statusMessage = "已取消，本地项目没有变化"
    }

    func checkLocalSource(_ skill: SkillRecord) async {
        guard !isBusy, !isCheckingLocalSources,
              let state = snapshot.localSourceStates.first(where: { $0.skillID == skill.id })
        else { return }
        isBusy = true
        operationProgress = .init(
            title: "正在检查本地开发源",
            detail: "只读取确认过的可使用内容，并与 SkillBox 保存版本比较…",
            canCancel: false
        )
        defer {
            operationProgress = nil
            isBusy = false
        }
        do {
            let resolver = localPackageResolver
            let result = try await Task.detached(priority: .userInitiated) {
                try await resolver.check(state: state)
            }.value
            pendingLocalIgnoredChangedPaths = result.ignoredChangedPaths
            switch result.state.status {
            case .current:
                try await store.updateLocalSourceState(result.state)
                statusMessage = result.ignoredChangedPaths.isEmpty
                    ? "本地开发源已是最新"
                    : "可使用内容没有变化；已忽略 \(result.ignoredChangedPaths.count) 项开发文件变化"
                await reload()
            case .sourceUnavailable:
                try await store.updateLocalSourceState(result.state)
                statusMessage = "找不到本地开发源，现有 Skill 保持不变"
                await reload()
            case .packageReviewRequired:
                try await store.updateLocalSourceState(result.state)
                await reload()
                if let review = result.review {
                    pendingLocalSourceSetup = .init(
                        reviews: [review],
                        purpose: .editSkill(skill.id)
                    )
                    statusMessage = "来源内容范围发生变化，请重新确认"
                }
            case .updateAvailable:
                guard let candidate = result.candidate,
                      let topLevelFingerprints = result.state.availableTopLevelFingerprints
                else { return }
                let prepared = PreparedLocalPackage(
                    package: .init(
                        candidate: candidate,
                        recipe: result.state.recipe,
                        topLevelFingerprints: topLevelFingerprints
                    ),
                    projectRootPath: result.state.projectRootPath,
                    bookmarkData: result.state.projectRootBookmarkData
                )
                try await prepareLocalPendingUpdate(prepared, skill: skill, state: result.state)
            }
        } catch {
            var failed = state
            failed.lastCheckError = error.localizedDescription
            _ = try? await store.recordLocalSourceCheck(failed, expected: state)
            await reload()
            present(error)
        }
    }

    func prepareLocalContentReview(_ skill: SkillRecord) async {
        guard !isBusy,
              let state = snapshot.localSourceStates.first(where: { $0.skillID == skill.id })
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let review = try await localPackageResolver.review(state: state) else {
                var unavailable = state
                unavailable.status = .sourceUnavailable
                unavailable.lastCheckedAt = Date()
                try await store.updateLocalSourceState(unavailable)
                await reload()
                statusMessage = "找不到本地开发源，现有 Skill 保持不变"
                return
            }
            pendingLocalSourceSetup = .init(reviews: [review], purpose: .editSkill(skill.id))
        } catch { present(error) }
    }

    func relinkLocalSource(_ skill: SkillRecord, projectRoot: URL) async {
        guard !isBusy,
              var state = snapshot.localSourceStates.first(where: { $0.skillID == skill.id })
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let candidates = try await LocalFolderSourceProvider().preview(locator: projectRoot.path)
            guard let candidate = candidates.first(where: {
                $0.canonicalName.caseInsensitiveCompare(skill.canonicalName) == .orderedSame
            }) else {
                noticeMessage = "新位置里没有找到“\(skill.displayName)”。请选择它本身或包含它的项目文件夹。"
                return
            }
            state.projectRootPath = projectRoot.standardizedFileURL.path
            state.projectRootBookmarkData = LocalSkillPackageResolver.bookmarkData(for: projectRoot)
            let review = try localPackageResolver.review(
                candidate: candidate,
                projectRoot: projectRoot,
                existingState: state
            )
            pendingLocalSourceSetup = .init(reviews: [review], purpose: .relinkSkill(skill.id))
            statusMessage = "请核对新位置中的可使用内容"
        } catch { present(error) }
    }

    func stopTrackingLocalSource(_ skill: SkillRecord) async {
        do {
            try await store.stopTrackingLocalSource(skillID: skill.id)
            statusMessage = "已停止跟踪开发源；当前 Skill 和应用副本均已保留"
            await reload()
        } catch { present(error) }
    }

    func openLocalSource(_ state: LocalSourceState) {
        let root = URL(fileURLWithPath: state.projectRootPath, isDirectory: true)
        let source = state.recipe.skillRelativePath.isEmpty
            ? root
            : root.appendingPathComponent(state.recipe.skillRelativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            noticeMessage = "原来的开发源位置已经找不到，可以使用“重新关联”。"
            return
        }
        reveal(source)
    }

    private func prepareLocalPendingUpdate(
        _ prepared: PreparedLocalPackage,
        skill: SkillRecord,
        state providedState: LocalSourceState? = nil
    ) async throws {
        var state = providedState ?? snapshot.localSourceStates.first(where: { $0.skillID == skill.id }) ?? .init(
            skillID: skill.id,
            projectRootPath: prepared.projectRootPath,
            recipe: prepared.package.recipe,
            currentPackageFingerprint: skill.fingerprint
        )
        state.projectRootPath = prepared.projectRootPath
        state.projectRootBookmarkData = prepared.bookmarkData
        state.recipe = prepared.package.recipe
        state.lastCheckedAt = Date()

        if prepared.package.candidate.fingerprint == skill.fingerprint {
            state.currentPackageFingerprint = skill.fingerprint
            state.topLevelFingerprints = prepared.package.topLevelFingerprints
            state.availablePackageFingerprint = nil
            state.availableTopLevelFingerprints = nil
            state.status = .current
            try await store.updateLocalSourceState(state)
            cleanupLocalCandidates([prepared.package.candidate])
            statusMessage = "已更新本地开发源关联，可使用内容没有变化"
            await reload()
            return
        }

        state.availablePackageFingerprint = prepared.package.candidate.fingerprint
        state.availableTopLevelFingerprints = prepared.package.topLevelFingerprints
        state.status = .updateAvailable
        try await store.updateLocalSourceState(state)
        let current = await store.contentURL(for: skill)
        let changes = try SkillDiffAnalyzer().compare(
            before: current,
            after: prepared.package.candidate.sourceURL
        )
        async let beforeMarkdown = readMarkdown(at: current.appendingPathComponent("SKILL.md"))
        async let afterMarkdown = readMarkdown(at: prepared.package.candidate.sourceURL.appendingPathComponent("SKILL.md"))
        let markdown = await (beforeMarkdown, afterMarkdown)
        pendingLocalPackages = [prepared.package.candidate.id: prepared]
        pendingLocalUpdateState = state
        pendingGitHubVersion = nil
        pendingGitHubPackageRecipes = [:]
        activeConflict = nil
        updatingSkillID = skill.id
        pendingCandidates = [prepared.package.candidate]
        selectedCandidateIDs = prepared.package.candidate.riskReport.isBlocked
            ? []
            : [prepared.package.candidate.id]
        pendingUpdateChanges = changes
        pendingUpdateBeforeMarkdown = markdown.0
        pendingUpdateAfterMarkdown = markdown.1
        statusMessage = "发现本地可使用内容更新"
        await reload()
    }

    private func previewGitHub(context: GitHubImportContext, operationID: UUID) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        activeConflict = nil
        updatingSkillID = nil
        isBusy = true
        operationProgress = .init(title: "正在获取完整版本", detail: "连接 GitHub、下载文件并进行使用前检查…", canCancel: true)
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let remote = try await githubProvider.checkRemoteVersion(locator: context.locator, trackingMode: context.trackingMode)
            try Task.checkCancellation()
            guard activeGitHubPreviewOperationID == operationID else { return }
            let skillPath = try githubProvider.skillPath(in: context.locator)
            canRetryGitHubWithDefaultBranch = false
            retryGitHubImportContext = nil
            if pauseForReleasePackageChoice(
                remote,
                locator: context.locator,
                skillPath: skillPath,
                purpose: .importSkill,
                importContext: context
            ) { return }
            try await prepareGitHubImport(
                remote: remote,
                locator: context.locator,
                skillPath: skillPath,
                context: context,
                operationID: operationID
            )
        } catch GitHubSourceError.noStableRelease {
            guard activeGitHubPreviewOperationID == operationID else { return }
            retryGitHubImportContext = context
            canRetryGitHubWithDefaultBranch = true
            canRetryGitHubConnection = false
            errorMessage = GitHubSourceError.noStableRelease.localizedDescription
            statusMessage = "这个仓库还没有正式 Release"
        } catch let error as GitHubSourceError where error.canRetryConnection {
            guard activeGitHubPreviewOperationID == operationID else { return }
            retryGitHubImportContext = context
            canRetryGitHubWithDefaultBranch = false
            canRetryGitHubConnection = true
            present(error)
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            if isCancellation(error) { statusMessage = "已取消 GitHub 下载" }
            else { present(error) }
        }
    }

    func startGitHubPreview() {
        startGitHubPreview(context: .init(
            locator: githubURL,
            trackingMode: githubTrackingMode,
            desiredCandidateName: nil,
            usageGuide: nil,
            usageGuideSourceDigest: nil
        ))
    }

    private func startGitHubPreview(context: GitHubImportContext) {
        remoteOperationTask?.cancel()
        let operationID = UUID()
        activeGitHubPreviewOperationID = operationID
        remoteOperationTask = Task { [weak self] in
            await self?.previewGitHub(context: context, operationID: operationID)
        }
    }

    func retryGitHubUsingDefaultBranch() {
        canRetryGitHubWithDefaultBranch = false
        canRetryGitHubConnection = false
        errorMessage = nil
        githubTrackingMode = .defaultBranch
        var context = retryGitHubImportContext ?? .init(
            locator: githubURL,
            trackingMode: .defaultBranch,
            desiredCandidateName: nil,
            usageGuide: nil,
            usageGuideSourceDigest: nil
        )
        context.trackingMode = .defaultBranch
        startGitHubPreview(context: context)
    }

    func retryGitHubConnection() {
        guard let context = retryGitHubImportContext else { return }
        canRetryGitHubConnection = false
        errorMessage = nil
        startGitHubPreview(context: context)
    }

    func dismissCurrentError() {
        canRetryGitHubWithDefaultBranch = false
        canRetryGitHubConnection = false
        retryGitHubImportContext = nil
        errorMessage = nil
    }

    func checkForUpdate(_ skill: SkillRecord) async {
        guard skill.source.kind == .github else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let state = try await githubUpdateChecker.check(skillID: skill.id) else { return }
            await reload()
            if let issue = state.lastCheckIssue {
                switch issue {
                case .rateLimited:
                    statusMessage = state.retryAfter.map {
                        "GitHub 暂时限制了查询，请在 \($0.formatted(date: .omitted, time: .shortened)) 后重试"
                    } ?? "GitHub 暂时限制了查询，请稍后重试"
                case .authenticationRequired:
                    noticeMessage = "这份 Skill 来自私人仓库，请重新连接 GitHub 后再检查。"
                case .repositoryPermissionRequired:
                    noticeMessage = "SkillBox 还没有获准读取这个私人仓库，请在设置中允许访问。"
                case .repositoryMissing:
                    statusMessage = "找不到原来的 GitHub 仓库，请确认它是否改名、删除或改为私人仓库"
                case .temporarilyUnavailable:
                    statusMessage = "暂时无法连接 GitHub，本地内容没有变化"
                }
                return
            }
            switch state.status {
            case .updateAvailable: statusMessage = "发现新版本 \(state.availableVersionName ?? "")"
            case .releasePackageAvailable: statusMessage = "发现同一版本的纯净安装包"
            case .packageReviewRequired: statusMessage = "来源中有新内容，需要确认是否属于这份 Skill"
            case .needsInitialCheck: statusMessage = "需要下载一次，才能确认当前内容是否最新"
            case .current: statusMessage = "这份 Skill 已经是最新内容"
            case .authenticationRequired: noticeMessage = "这份旧记录需要重新核对 GitHub 连接"
            default: break
            }
        } catch { present(error) }
    }

    private func previewAvailableUpdate(_ skill: SkillRecord, operationID: UUID) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        guard let state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }) else { return }
        isBusy = true
        operationProgress = .init(title: "正在准备更新", detail: "下载新版本并比较文件、说明和风险变化…", canCancel: true)
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let remote = try await githubProvider.checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
            try Task.checkCancellation()
            guard activeGitHubPreviewOperationID == operationID else { return }
            if pauseForReleasePackageChoice(
                remote,
                locator: skill.source.locator,
                skillPath: state.skillPath,
                purpose: .updateSkill(skill.id)
            ) { return }
            try await prepareGitHubUpdate(
                remote: remote,
                skill: skill,
                skillPath: state.skillPath,
                operationID: operationID
            )
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            if isCancellation(error) { statusMessage = "已取消更新检查" }
            else { present(error) }
        }
    }

    func startAvailableUpdatePreview(_ skill: SkillRecord) {
        remoteOperationTask?.cancel()
        let operationID = UUID()
        activeGitHubPreviewOperationID = operationID
        remoteOperationTask = Task { [weak self] in
            await self?.previewAvailableUpdate(skill, operationID: operationID)
        }
    }

    func startInstallContentReview(_ skill: SkillRecord) {
        guard let state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }) else { return }
        let shouldCleanLegacyCopy = state.packageRecipe == nil && state.requiresPackageReview &&
            ![.updateAvailable, .releasePackageAvailable, .packageReviewRequired].contains(state.status)
        if shouldCleanLegacyCopy {
            remoteOperationTask?.cancel()
            let operationID = UUID()
            activeGitHubPreviewOperationID = operationID
            remoteOperationTask = Task { [weak self] in
                await self?.reviewLegacyPackage(skill: skill, state: state, operationID: operationID)
            }
        } else {
            startAvailableUpdatePreview(skill)
        }
    }

    func cancelRemoteOperation() {
        guard operationProgress?.canCancel != false else {
            statusMessage = "正在完成更新，请稍候"
            return
        }
        remoteOperationTask?.cancel()
        remoteOperationTask = nil
        activeGitHubPreviewOperationID = nil
        retryGitHubImportContext = nil
        operationProgress = nil
        isBusy = false
        statusMessage = "已取消当前操作"
    }

    func continueReleasePackageChoice(assetID: Int64?) {
        guard let choice = pendingReleasePackageChoice else { return }
        pendingReleasePackageChoice = nil
        remoteOperationTask?.cancel()
        let operationID = UUID()
        activeGitHubPreviewOperationID = operationID
        remoteOperationTask = Task { [weak self] in
            await self?.downloadReleasePackageChoice(choice, assetID: assetID, operationID: operationID)
        }
    }

    func cancelReleasePackageChoice() {
        pendingReleasePackageChoice = nil
        pendingDiscoveryCandidateName = nil
        pendingDiscoveryUsageGuide = nil
        pendingDiscoveryUsageGuideSourceDigest = nil
        statusMessage = "已取消 GitHub 下载"
    }

    func continueInstallContentChoice(includePaths: [String]) {
        guard let choice = pendingInstallContentChoice else { return }
        pendingInstallContentChoice = nil
        remoteOperationTask?.cancel()
        let operationID = UUID()
        activeGitHubPreviewOperationID = operationID
        remoteOperationTask = Task { [weak self] in
            await self?.applyInstallContentChoice(choice, includePaths: includePaths, operationID: operationID)
        }
    }

    func cancelInstallContentChoice() {
        if let review = pendingInstallContentChoice?.review {
            cleanupGitHubCandidates([review.candidate])
        }
        pendingInstallContentChoice = nil
        pendingDiscoveryCandidateName = nil
        pendingDiscoveryUsageGuide = nil
        pendingDiscoveryUsageGuideSourceDigest = nil
        statusMessage = "已取消整理，现有 Skill 保持不变"
    }

    private func pauseForReleasePackageChoice(
        _ remote: GitHubRemoteVersion,
        locator: String,
        skillPath: String?,
        purpose: GitHubReleasePackagePurpose,
        importContext: GitHubImportContext? = nil
    ) -> Bool {
        guard remote.requiresReleaseAssetSelection else { return false }
        pendingReleasePackageChoice = .init(
            version: remote,
            locator: locator,
            skillPath: skillPath,
            purpose: purpose,
            importContext: importContext
        )
        statusMessage = remote.requiresReleaseAssetSelection ? "请选择要下载的 Release 安装包" : "这个 Release 没有独立安装包"
        return true
    }

    private func downloadReleasePackageChoice(
        _ choice: GitHubReleasePackageChoice,
        assetID: Int64?,
        operationID: UUID
    ) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        isBusy = true
        operationProgress = .init(title: "正在获取完整版本", detail: "下载文件、校验完整性并进行使用前检查…", canCancel: true)
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let remote = try assetID.map { try choice.version.selectingReleaseAsset(id: $0) } ?? choice.version
            switch choice.purpose {
            case .importSkill:
                let context = choice.importContext ?? .init(
                    locator: choice.locator,
                    trackingMode: remote.trackingMode,
                    desiredCandidateName: nil,
                    usageGuide: nil,
                    usageGuideSourceDigest: nil
                )
                try await prepareGitHubImport(
                    remote: remote,
                    locator: choice.locator,
                    skillPath: choice.skillPath,
                    context: context,
                    operationID: operationID
                )
            case let .updateSkill(skillID):
                guard let skill = snapshot.skills.first(where: { $0.id == skillID }) else { return }
                try await prepareGitHubUpdate(
                    remote: remote,
                    skill: skill,
                    skillPath: choice.skillPath,
                    operationID: operationID
                )
            case .migrateSkill:
                return
            }
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            if isCancellation(error) { statusMessage = "已取消 GitHub 下载" }
            else { present(error) }
        }
    }

    private func prepareGitHubImport(
        remote: GitHubRemoteVersion,
        locator: String,
        skillPath: String?,
        context: GitHubImportContext,
        operationID: UUID
    ) async throws {
        let result = try await githubProvider.downloadSnapshot(version: remote, skillPath: skillPath, locator: locator)
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else {
            cleanupGitHubCandidates(result.candidates + result.packageReviews.map(\.candidate))
            throw CancellationError()
        }
        if let review = result.packageReviews.first {
            pendingInstallContentChoice = .init(
                review: review,
                locator: locator,
                purpose: .importSkill,
                importContext: context
            )
            statusMessage = "确认一次要安装的内容"
            return
        }
        pendingDiscoveryCandidateName = context.desiredCandidateName
        pendingDiscoveryUsageGuide = context.usageGuide
        pendingDiscoveryUsageGuideSourceDigest = context.usageGuideSourceDigest
        pendingGitHubVersion = result.version
        pendingGitHubPackageRecipes = result.packageRecipes
        pendingCandidates = result.candidates
        if let desiredName = context.desiredCandidateName {
            selectedCandidateIDs = Set(result.candidates.filter {
                !$0.riskReport.isBlocked && $0.canonicalName.caseInsensitiveCompare(desiredName) == .orderedSame
            }.map(\.id))
            if selectedCandidateIDs.isEmpty {
                statusMessage = "在仓库中找到了多个 Skills，请选择要加入的一个"
            }
        } else {
            selectedCandidateIDs = Set(result.candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
        }
    }

    private func prepareGitHubUpdate(
        remote: GitHubRemoteVersion,
        skill: SkillRecord,
        skillPath: String?,
        operationID: UUID
    ) async throws {
        let sourceState = snapshot.sourceStates.first { $0.skillID == skill.id }
        let result = try await githubProvider.downloadSnapshot(
            version: remote,
            skillPath: skillPath,
            locator: skill.source.locator,
            packageRecipe: sourceState?.packageRecipe
        )
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else {
            cleanupGitHubCandidates(result.candidates + result.packageReviews.map(\.candidate))
            throw CancellationError()
        }
        if let review = result.packageReviews.first {
            pendingInstallContentChoice = .init(
                review: review,
                locator: skill.source.locator,
                purpose: .updateSkill(skill.id),
                importContext: nil
            )
            statusMessage = "来源中的可安装内容发生了变化"
            return
        }
        let matching = result.candidates.filter { candidate in
            if remote.selectedReleaseAsset != nil { return candidate.canonicalName == skill.canonicalName }
            if let skillPath { return candidate.source.skillPath == skillPath }
            return candidate.canonicalName == skill.canonicalName
        }
        guard let candidate = matching.first else { throw GitHubSourceError.noSkillsFound }
        let current = await store.contentURL(for: skill)
        let changes = try SkillDiffAnalyzer().compare(before: current, after: candidate.sourceURL)
        async let beforeMarkdown = readMarkdown(at: current.appendingPathComponent("SKILL.md"))
        async let afterMarkdown = readMarkdown(at: candidate.sourceURL.appendingPathComponent("SKILL.md"))
        let markdown = await (beforeMarkdown, afterMarkdown)
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else {
            cleanupGitHubCandidates(result.candidates)
            throw CancellationError()
        }
        pendingUpdateChanges = changes
        pendingUpdateBeforeMarkdown = markdown.0
        pendingUpdateAfterMarkdown = markdown.1
        pendingGitHubVersion = result.version
        pendingGitHubPackageRecipes = result.packageRecipes
        activeConflict = nil
        updatingSkillID = skill.id
        pendingCandidates = [candidate]
        selectedCandidateIDs = candidate.riskReport.isBlocked ? [] : [candidate.id]
    }

    private func applyInstallContentChoice(
        _ choice: GitHubInstallContentChoice,
        includePaths: [String],
        operationID: UUID
    ) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        isBusy = true
        operationProgress = .init(
            title: "正在整理 Skill",
            detail: "只保留你确认的运行内容，并重新进行文件检查…",
            canCancel: true
        )
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let package = try await githubProvider.confirmPackageReview(
                choice.review,
                includePaths: includePaths
            )
            guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else {
                cleanupGitHubCandidates([package.candidate])
                return
            }
            pendingGitHubVersion = choice.review.version
            pendingGitHubPackageRecipes = [package.candidate.id: package.recipe]
            switch choice.purpose {
            case .importSkill:
                pendingDiscoveryCandidateName = choice.importContext?.desiredCandidateName
                pendingDiscoveryUsageGuide = choice.importContext?.usageGuide
                pendingDiscoveryUsageGuideSourceDigest = choice.importContext?.usageGuideSourceDigest
                activeConflict = nil
                updatingSkillID = nil
                pendingCandidates = [package.candidate]
                selectedCandidateIDs = package.candidate.riskReport.isBlocked ? [] : [package.candidate.id]
                statusMessage = "已整理出可安装的 Skill"
            case let .updateSkill(skillID):
                guard let skill = snapshot.skills.first(where: { $0.id == skillID }) else { return }
                try await preparePendingUpdate(
                    candidate: package.candidate,
                    skill: skill,
                    version: choice.review.version,
                    recipe: package.recipe,
                    operationID: operationID
                )
            case let .migrateSkill(skillID):
                guard let skill = snapshot.skills.first(where: { $0.id == skillID }) else { return }
                try await migrateLegacyPackage(
                    package,
                    skill: skill,
                    version: choice.review.version,
                    operationID: operationID
                )
            }
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            if isCancellation(error) { statusMessage = "已取消整理，现有 Skill 保持不变" }
            else { present(error) }
        }
    }

    private func reviewLegacyPackage(skill: SkillRecord, state: GitHubSourceState, operationID: UUID) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        isBusy = true
        operationProgress = .init(
            title: "正在识别可安装内容",
            detail: "分开 Skill 运行文件与 GitHub 仓库资料…",
            canCancel: true
        )
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let content = await store.contentURL(for: skill)
            let candidate = SkillCandidate(
                sourceURL: content,
                directoryName: skill.canonicalName,
                canonicalName: skill.canonicalName,
                displayName: skill.displayName,
                description: skill.description,
                fingerprint: skill.fingerprint,
                source: skill.source,
                riskReport: skill.riskReport
            )
            let version = legacyRemoteVersion(skill: skill, state: state)
            let resolution = try await GitHubSkillPackageResolver().resolve(
                candidate: candidate,
                version: version,
                archiveIsReleaseAsset: false
            )
            try Task.checkCancellation()
            guard activeGitHubPreviewOperationID == operationID else { return }
            switch resolution {
            case let .needsConfirmation(review):
                pendingInstallContentChoice = .init(
                    review: review,
                    locator: skill.source.locator,
                    purpose: .migrateSkill(skill.id),
                    importContext: nil
                )
                statusMessage = "请确认哪些内容属于这份 Skill"
            case let .ready(package):
                try await migrateLegacyPackage(
                    package,
                    skill: skill,
                    version: version,
                    operationID: operationID
                )
            }
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            if isCancellation(error) { statusMessage = "已取消整理，现有 Skill 保持不变" }
            else { present(error) }
        }
    }

    private func preparePendingUpdate(
        candidate: SkillCandidate,
        skill: SkillRecord,
        version: GitHubRemoteVersion,
        recipe: GitHubPackageRecipe,
        operationID: UUID
    ) async throws {
        let current = await store.contentURL(for: skill)
        let changes = try SkillDiffAnalyzer().compare(before: current, after: candidate.sourceURL)
        async let beforeMarkdown = readMarkdown(at: current.appendingPathComponent("SKILL.md"))
        async let afterMarkdown = readMarkdown(at: candidate.sourceURL.appendingPathComponent("SKILL.md"))
        let markdown = await (beforeMarkdown, afterMarkdown)
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else {
            cleanupGitHubCandidates([candidate])
            throw CancellationError()
        }
        pendingUpdateChanges = changes
        pendingUpdateBeforeMarkdown = markdown.0
        pendingUpdateAfterMarkdown = markdown.1
        pendingGitHubVersion = version
        pendingGitHubPackageRecipes = [candidate.id: recipe]
        activeConflict = nil
        updatingSkillID = skill.id
        pendingCandidates = [candidate]
        selectedCandidateIDs = candidate.riskReport.isBlocked ? [] : [candidate.id]
    }

    private func migrateLegacyPackage(
        _ package: GitHubResolvedPackage,
        skill: SkillRecord,
        version: GitHubRemoteVersion,
        operationID: UUID
    ) async throws {
        try Task.checkCancellation()
        guard activeGitHubPreviewOperationID == operationID else { throw CancellationError() }
        operationProgress = .init(
            title: "正在完成更新",
            detail: "正在安全保存 Skill 和恢复记录…",
            canCancel: false
        )
        let state = sourceState(
            skillID: skill.id,
            skillPath: package.recipe.skillPath,
            remote: version,
            recipe: package.recipe
        )
        do {
            _ = try await updateCoordinator.updateCentralOnly(
                skillID: skill.id,
                candidate: package.candidate,
                store: store,
                nextGitHubSourceState: state
            )
        } catch {
            await reload()
            throw error
        }
        cleanupGitHubCandidates([package.candidate])
        if activeGitHubPreviewOperationID == operationID {
            pendingGitHubPackageRecipes = [:]
            pendingGitHubVersion = nil
            statusMessage = "已整理成纯净 Skill，GitHub 仓库资料不会再安装到应用"
        }
        await reload()
        await scanInstalledSkills()
    }

    private func legacyRemoteVersion(skill: SkillRecord, state: GitHubSourceState) -> GitHubRemoteVersion {
        let repositoryURL = URL(string: skill.source.locator)
            ?? URL(string: "https://github.com/\(state.repositoryFullName)")!
        return .init(
            repositoryID: state.repositoryID ?? 0,
            repositoryFullName: state.repositoryFullName,
            isPrivate: state.repositoryIsPrivate ?? false,
            trackingMode: state.trackingMode,
            defaultBranch: state.defaultBranch ?? "main",
            versionIdentifier: state.currentVersionIdentifier ?? "local:\(skill.fingerprint)",
            versionName: state.currentVersionName ?? "当前版本",
            revision: state.currentCommitSHA ?? state.defaultBranch ?? "main",
            commitSHA: state.currentCommitSHA ?? "local:\(skill.fingerprint)",
            treeSHA: state.currentTreeSHA ?? "local:\(skill.fingerprint)",
            archiveURL: repositoryURL,
            releaseID: state.currentReleaseID
        )
    }

    func importSelectedCandidates(authorizingHighRisk: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let selected = pendingCandidates.filter { selectedCandidateIDs.contains($0.id) }
            guard updatingSkillID == nil else { return }
            for candidate in selected {
                let record = try await store.importCandidate(
                    candidate,
                    authorizingHighRisk: authorizingHighRisk
                )
                if candidate.canonicalName.caseInsensitiveCompare(pendingDiscoveryCandidateName ?? "") == .orderedSame,
                   let guide = pendingDiscoveryUsageGuide,
                   let expectedDigest = pendingDiscoveryUsageGuideSourceDigest,
                   SkillUsageGuideSourceIdentity.digest(skillDirectory: candidate.sourceURL) == expectedDigest
                {
                    try await usageGuideStore.save(
                        guide,
                        skillID: record.id,
                        fingerprint: record.fingerprint,
                        providerID: aiSettings.selectedProviderID,
                        model: aiSettings.selectedConfiguration?.model
                    )
                }
                if candidate.source.kind == .github, let remote = pendingGitHubVersion {
                    try await store.updateSourceState(sourceState(
                        skillID: record.id,
                        skillPath: candidate.source.skillPath,
                        remote: remote,
                        recipe: pendingGitHubPackageRecipes[candidate.id]
                    ))
                }
                if let prepared = pendingLocalPackages[candidate.id] {
                    try await store.updateLocalSourceState(.init(
                        skillID: record.id,
                        projectRootPath: prepared.projectRootPath,
                        projectRootBookmarkData: prepared.bookmarkData,
                        recipe: prepared.package.recipe,
                        currentPackageFingerprint: record.fingerprint,
                        topLevelFingerprints: prepared.package.topLevelFingerprints,
                        lastCheckedAt: Date(),
                        status: .current
                    ))
                }
            }
            cleanupGitHubCandidates(pendingCandidates)
            cleanupLocalCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            activeConflict = nil
            updatingSkillID = nil
            pendingGitHubVersion = nil
            pendingGitHubPackageRecipes = [:]
            pendingLocalPackages = [:]
            pendingLocalUpdateState = nil
            pendingLocalIgnoredChangedPaths = []
            pendingDiscoveryCandidateName = nil
            pendingDiscoveryUsageGuide = nil
            pendingDiscoveryUsageGuideSourceDigest = nil
            statusMessage = "已加入「我的 Skills」"
            await reload()
        } catch { present(error) }
    }

    func applyPendingUpdate(
        deployToExisting: Bool,
        authorizingHighRisk: Bool = false
    ) async {
        guard let skillID = updatingSkillID,
              let candidate = pendingCandidates.first,
              selectedCandidateIDs.contains(candidate.id)
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var nextLocalSourceState: LocalSourceState?
            var nextGitHubSourceState: GitHubSourceState?
            if var localState = pendingLocalUpdateState,
               candidate.source.kind == .localFolder
            {
                localState.currentPackageFingerprint = candidate.fingerprint
                localState.topLevelFingerprints = localState.availableTopLevelFingerprints ??
                    pendingLocalPackages[candidate.id]?.package.topLevelFingerprints ??
                    localState.topLevelFingerprints
                localState.availablePackageFingerprint = nil
                localState.availableTopLevelFingerprints = nil
                localState.lastCheckedAt = Date()
                localState.status = .current
                nextLocalSourceState = localState
            } else if let remote = pendingGitHubVersion {
                nextGitHubSourceState = sourceState(
                    skillID: skillID,
                    skillPath: candidate.source.skillPath,
                    remote: remote,
                    recipe: pendingGitHubPackageRecipes[candidate.id]
                )
            }
            let result = deployToExisting
                ? try await updateCoordinator.updateAndDeploy(
                    skillID: skillID,
                    candidate: candidate,
                    store: store,
                    authorizingHighRisk: authorizingHighRisk,
                    nextLocalSourceState: nextLocalSourceState,
                    nextGitHubSourceState: nextGitHubSourceState
                )
                : try await updateCoordinator.updateCentralOnly(
                    skillID: skillID,
                    candidate: candidate,
                    store: store,
                    authorizingHighRisk: authorizingHighRisk,
                    nextLocalSourceState: nextLocalSourceState,
                    nextGitHubSourceState: nextGitHubSourceState
                )
            cleanupGitHubCandidates(pendingCandidates)
            cleanupLocalCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            pendingUpdateChanges = []
            pendingUpdateBeforeMarkdown = ""
            pendingUpdateAfterMarkdown = ""
            pendingGitHubVersion = nil
            pendingGitHubPackageRecipes = [:]
            pendingLocalPackages = [:]
            pendingLocalUpdateState = nil
            pendingLocalIgnoredChangedPaths = []
            updatingSkillID = nil
            let installationCount = result.transaction?.backups.count ?? 0
            statusMessage = deployToExisting && installationCount > 0
                ? "已更新并安装到 \(installationCount) 个应用"
                : "已更新「我的 Skills」中的原件"
            await reload()
            await scanInstalledSkills()
        } catch {
            await reload()
            present(error)
        }
    }

    func ignoreAvailableUpdate(_ skill: SkillRecord) async {
        do { try await githubUpdateChecker.ignoreAvailableVersion(skillID: skill.id); await reload() }
        catch { present(error) }
    }

    func setUpdateChecking(_ enabled: Bool, for skill: SkillRecord) async {
        do { try await githubUpdateChecker.setCheckingEnabled(enabled, skillID: skill.id); await reload() }
        catch { present(error) }
    }

    func setGitHubTrackingMode(_ mode: GitHubTrackingMode, for skill: SkillRecord) async {
        guard var state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }), state.trackingMode != mode else { return }
        state.trackingMode = mode
        state.availableVersionIdentifier = nil
        state.availableVersionName = nil
        state.availableCommitSHA = nil
        state.availableTreeSHA = nil
        state.availableReleaseID = nil
        state.availableAssetID = nil
        state.availableAssetName = nil
        state.availableAssetDigest = nil
        state.ignoredVersionIdentifier = nil
        state.lastCheckIssue = nil
        state.retryAfter = nil
        state.rateLimitScope = nil
        if state.packageRecipe != nil {
            state.packageRecipe?.trackingMode = mode
        }
        state.currentTreeSHA = nil
        state.status = .needsInitialCheck
        do {
            try await store.updateSourceState(state)
            statusMessage = mode == .latestStableRelease ? "以后跟随最新正式 Release" : "以后跟随仓库默认分支"
            await reload()
        } catch { present(error) }
    }

    func openGitHubSource(_ skill: SkillRecord) {
        guard let url = URL(string: skill.source.locator), url.host?.lowercased() == "github.com" else {
            noticeMessage = "这份 Skill 没有可打开的 GitHub 地址。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func checkAllGitHubUpdates(operationID: UUID) async {
        guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
        let states = snapshot.sourceStates.filter(\.checkingEnabled)
        guard !states.isEmpty else {
            noticeMessage = "目前没有正在检查更新的 GitHub Skill。"
            return
        }
        isBusy = true
        operationProgress = .init(
            title: "正在检查 GitHub 更新",
            detail: "正在整理仓库，同一仓库只检查一次…",
            canCancel: true
        )
        defer {
            if activeGitHubPreviewOperationID == operationID {
                isBusy = false
                operationProgress = nil
                remoteOperationTask = nil
                activeGitHubPreviewOperationID = nil
            }
        }
        do {
            let checkedStates = try await githubUpdateChecker.checkAll { [weak self] progress in
                await MainActor.run {
                    guard self?.activeGitHubPreviewOperationID == operationID else { return }
                    self?.operationProgress = .init(
                        title: "正在检查 GitHub 更新",
                        detail: "已检查 \(progress.completedRepositories) / \(progress.totalRepositories) 个仓库",
                        canCancel: true
                    )
                }
            }
            guard activeGitHubPreviewOperationID == operationID, !Task.isCancelled else { return }
            await reload()
            statusMessage = GitHubUpdateSummary(states: checkedStates).statusMessage
        } catch is CancellationError {
            guard activeGitHubPreviewOperationID == operationID else { return }
            statusMessage = "已取消检查，本地 Skills 没有变化"
        } catch {
            guard activeGitHubPreviewOperationID == operationID else { return }
            present(error)
        }
    }

    func startGitHubUpdateCheck() {
        remoteOperationTask?.cancel()
        let operationID = UUID()
        activeGitHubPreviewOperationID = operationID
        remoteOperationTask = Task { [weak self] in
            await self?.checkAllGitHubUpdates(operationID: operationID)
        }
    }

    func cancelCandidatePreview() {
        cleanupGitHubCandidates(pendingCandidates)
        cleanupLocalCandidates(pendingCandidates)
        pendingCandidates = []
        selectedCandidateIDs = []
        activeConflict = nil
        updatingSkillID = nil
        pendingGitHubVersion = nil
        pendingGitHubPackageRecipes = [:]
        pendingLocalPackages = [:]
        pendingLocalUpdateState = nil
        pendingLocalIgnoredChangedPaths = []
        pendingDiscoveryCandidateName = nil
        pendingDiscoveryUsageGuide = nil
        pendingDiscoveryUsageGuideSourceDigest = nil
        pendingUpdateChanges = []
        pendingUpdateBeforeMarkdown = ""
        pendingUpdateAfterMarkdown = ""
    }

    func beginGitHubLogin() async {
        do {
            githubLoginTask?.cancel()
            isWaitingForGitHubRepositorySelection = false
            let authorization = try await githubDeviceClient.beginAuthorization()
            githubAuthorization = authorization
            githubLoginStatus = "等待你在浏览器中确认…"
        } catch { present(error) }
    }

    func connectPrivateGitHub() async {
        guard isGitHubConfigured else {
            noticeMessage = "当前版本尚未启用私人仓库连接。公开仓库仍然可以直接添加。"
            return
        }
        await beginGitHubLogin()
    }

    func openGitHubAuthorization() {
        guard let authorization = githubAuthorization else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.userCode, forType: .string)
        NSWorkspace.shared.open(authorization.verificationURL)
        githubLoginTask?.cancel()
        githubLoginTask = Task { await pollGitHubAuthorization(authorization) }
    }

    func manageGitHubRepositories() {
        if let githubInstallURL {
            isWaitingForGitHubRepositorySelection = isGitHubConnected && githubAuthorizedRepositories.isEmpty
            NSWorkspace.shared.open(githubInstallURL)
        }
        else { noticeMessage = "暂时无法打开仓库选择页，本地 Skills 不受影响。" }
    }

    func disconnectGitHub() async {
        do {
            githubLoginTask?.cancel()
            try await githubSession.disconnect()
            setGitHubConnectionHint(false)
            isWaitingForGitHubRepositorySelection = false
            githubAuthorization = nil
            githubLoginStatus = "已断开私人仓库连接。公开仓库仍会正常检查更新。"
            githubAuthorizedRepositories = []
        } catch { present(error) }
    }

    func clearGitHubInformation() async {
        do {
            githubLoginTask?.cancel()
            try await githubSession.disconnect()
            try await store.clearGitHubInformation()
            setGitHubConnectionHint(false)
            isWaitingForGitHubRepositorySelection = false
            githubAuthorization = nil
            githubAuthorizedRepositories = []
            lastDeletedSkill = nil
            githubLoginStatus = "GitHub 登录和仓库跟踪信息已清除，本地 Skills 已保留。"
            await reload()
        } catch { present(error) }
    }

    func openGitHubAuthorizationSettings() {
        guard let url = URL(string: "https://github.com/settings/apps/authorizations") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshGitHubRepositories() async {
        guard isGitHubConnected else {
            githubAuthorizedRepositories = []
            return
        }
        do {
            githubAuthorizedRepositories = try await githubProvider.authorizedRepositories()
            let accessByRepository = Dictionary(uniqueKeysWithValues: githubAuthorizedRepositories.map {
                ($0.fullName.lowercased(), $0.isPrivate)
            })
            var sourceStates = await store.currentSnapshot().sourceStates
            var sourceStatesChanged = false
            for index in sourceStates.indices {
                guard let isPrivate = accessByRepository[sourceStates[index].repositoryFullName.lowercased()] else { continue }
                if sourceStates[index].repositoryIsPrivate != isPrivate {
                    sourceStates[index].repositoryIsPrivate = isPrivate
                    sourceStatesChanged = true
                }
            }
            if sourceStatesChanged {
                try await store.replaceSourceStates(sourceStates)
                await reload()
            }
            if !githubAuthorizedRepositories.isEmpty {
                isWaitingForGitHubRepositorySelection = false
                githubLoginStatus = "连接完成，已找到 \(githubAuthorizedRepositories.count) 个可读取的仓库。"
            }
        } catch GitHubSourceError.authenticationRequired {
            setGitHubConnectionHint(false)
            isWaitingForGitHubRepositorySelection = false
            githubAuthorizedRepositories = []
            githubLoginStatus = "连接已失效，请重新连接 GitHub"
        } catch {
            githubLoginStatus = "暂时无法读取已授权仓库：\(error.localizedDescription)"
        }
    }

    func prepareAssignmentProposal(skill: SkillRecord, target: AgentTarget) async -> AssignmentProposal? {
        let existingDesired = snapshot.assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true
        let pendingAction = syncPlan?.actions.first {
            $0.skillID == skill.id && $0.targetID == target.id && $0.kind != .noChange
        }
        if pendingAction?.kind != .remove,
           skill.source.kind == .github,
           let state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }),
           state.requiresPackageReview
        {
            startInstallContentReview(skill)
            return nil
        }
        if let pendingAction {
            return AssignmentProposal(
                skill: skill,
                target: target,
                desired: existingDesired,
                action: pendingAction,
                changes: await comparisonChanges(for: pendingAction, skill: skill)
            )
        }

        let proposedDesired = !existingDesired
        if proposedDesired, !isAvailableForInstallation(target) {
            noticeMessage = unavailableMessage(for: target)
            return nil
        }
        if proposedDesired,
           skill.source.kind == .github,
           let state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }),
           state.requiresPackageReview
        {
            startInstallContentReview(skill)
            return nil
        }
        var proposedSnapshot = snapshot
        var assignments = proposedSnapshot.assignments
        setAssignment(skill: skill, target: target, desired: proposedDesired, assignments: &assignments)
        proposedSnapshot.assignments = assignments
        do {
            let plan = try await assignmentPlan(snapshot: proposedSnapshot, skillID: skill.id, targetID: target.id)
            let action = plan.actions.first { $0.skillID == skill.id && $0.targetID == target.id && $0.kind != .noChange }
            let changes: [SkillFileChange]
            if let action {
                changes = await comparisonChanges(for: action, skill: skill)
            } else {
                changes = []
            }
            return AssignmentProposal(
                skill: skill,
                target: target,
                desired: proposedDesired,
                action: action,
                changes: changes
            )
        } catch {
            present(error)
            return nil
        }
    }

    func confirmAssignmentProposal(_ proposal: AssignmentProposal) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        var assignments = snapshot.assignments
        setAssignment(skill: proposal.skill, target: proposal.target, desired: proposal.desired, assignments: &assignments)
        if proposal.desired,
           proposal.action?.blockReason == .unmanagedConflict,
           let destinationFingerprint = proposal.action?.expectedDestinationFingerprint,
           let index = assignments.firstIndex(where: { $0.skillID == proposal.skill.id && $0.targetID == proposal.target.id })
        {
            let isSame = proposal.action?.expectedSourceFingerprint == destinationFingerprint
            assignments[index].allowTakeover = isSame
            assignments[index].allowReplacement = !isSame
            assignments[index].authorizedDestinationFingerprint = destinationFingerprint
        }

        do {
            try await store.replaceAssignments(assignments)
            snapshot = await store.currentSnapshot()
            let plan = try await refreshAssignmentPlan(proposal)
            guard let action = plan.actions.first(where: { $0.kind != .noChange }) else {
                statusMessage = proposal.desired ? "已保留当前安装" : "已取消这项安装"
                return true
            }
            guard action.kind != .blocked else {
                noticeMessage = action.summary
                return false
            }

            let result = try await executor.execute(plan: SyncPlan(actions: [action]), store: store)
            snapshot = await store.currentSnapshot()
            await refreshBackupMaintenanceIssue()
            _ = try await refreshAssignmentPlan(proposal)
            guard result.status == .succeeded else {
                noticeMessage = "操作未完成，请查看操作记录中的原因。"
                return false
            }
            statusMessage = action.kind == .remove
                ? "已从 \(proposal.target.displayName) 卸载 \(proposal.skill.displayName)"
                : "已安装 \(proposal.skill.displayName) 到 \(proposal.target.displayName)"
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func assignmentPlan(snapshot: LibrarySnapshot, skillID: UUID, targetID: UUID) async throws -> SyncPlan {
        var scoped = snapshot
        scoped.assignments = snapshot.assignments.filter { $0.skillID == skillID && $0.targetID == targetID }
        let destinationPaths = Set(scoped.assignments.compactMap { assignment -> String? in
            guard let target = snapshot.targets.first(where: { $0.id == assignment.targetID }) else { return nil }
            return URL(fileURLWithPath: target.path).appendingPathComponent(assignment.installationDirectoryName).standardizedFileURL.path
        })
        // Keep ownership at the selected destination, including a conflicting
        // record, while avoiding reads of unrelated installed copies.
        scoped.installations = snapshot.installations.filter {
            ($0.skillID == skillID && $0.targetID == targetID) || destinationPaths.contains($0.destinationPath)
        }
        let planningRoot = libraryRoot
        let planner = planner
        let plan = try await Task.detached(priority: .userInitiated) {
            try planner.makePlan(snapshot: scoped, libraryRoot: planningRoot)
        }.value
        return SyncPlan(actions: plan.actions.filter { $0.skillID == skillID && $0.targetID == targetID })
    }

    private func refreshAssignmentPlan(_ proposal: AssignmentProposal) async throws -> SyncPlan {
        let plan = try await assignmentPlan(snapshot: snapshot, skillID: proposal.skill.id, targetID: proposal.target.id)
        var actions = syncPlan?.actions.filter {
            $0.skillID != proposal.skill.id || $0.targetID != proposal.target.id
        } ?? []
        actions.append(contentsOf: plan.actions)
        syncPlan = SyncPlan(actions: actions.sorted { $0.destinationPath < $1.destinationPath })
        return plan
    }

    func prepareInstallEverywhere(_ skill: SkillRecord) async -> Bool {
        guard !skill.riskReport.isBlocked else {
            noticeMessage = "这份 Skill 已被安全检查阻止，无法安装。"
            return false
        }
        guard !needsRiskAcknowledgement(for: skill) else {
            noticeMessage = "请先了解并确认这份 Skill 的内容提示。"
            return false
        }
        let available = visibleTargets().filter(isAvailableForInstallation)
        guard !available.isEmpty else {
            noticeMessage = "本机还没有找到可以安装 Skill 的应用。SkillBox 不会代为创建应用文件夹。"
            return false
        }
        var assignments = snapshot.assignments
        for target in available {
            setAssignment(skill: skill, target: target, desired: true, assignments: &assignments)
        }
        pendingDeletionAfterSyncSkillID = nil
        pendingSyncAssignments = assignments
        refreshPlan()
        let shouldPreview = syncPlan?.actions.contains { $0.skillID == skill.id && $0.kind != .noChange } == true
        if !shouldPreview {
            pendingSyncAssignments = nil
            refreshPlan()
            noticeMessage = "这份 Skill 已经安装到所有可用应用。"
        }
        return shouldPreview
    }

    func prepareUninstallEverywhere(
        _ skill: SkillRecord,
        deletingAfterwards: Bool = false
    ) async -> Bool {
        pendingDeletionAfterSyncSkillID = deletingAfterwards ? skill.id : nil
        var assignments = snapshot.assignments
        var changed = false
        for index in assignments.indices where assignments[index].skillID == skill.id && assignments[index].isDesired {
            assignments[index].isDesired = false
            clearAuthorization(&assignments[index])
            changed = true
        }
        let hasManagedCopies = snapshot.installations.contains { $0.skillID == skill.id }
        guard changed || hasManagedCopies else {
            pendingDeletionAfterSyncSkillID = nil
            noticeMessage = "这份 Skill 还没有通过 SkillBox 安装到任何应用。"
            return false
        }
        pendingSyncAssignments = assignments
        refreshPlan()
        let shouldPreview = syncPlan?.actions.contains { $0.skillID == skill.id && $0.kind != .noChange } == true
        if !shouldPreview {
            pendingSyncAssignments = nil
            pendingDeletionAfterSyncSkillID = nil
            refreshPlan()
            noticeMessage = "这份 Skill 当前没有可卸载的受管理副本。"
        }
        return shouldPreview
    }

    func cancelPendingDeletionAfterSync() {
        cancelSyncPreview()
    }

    func cancelSyncPreview() {
        pendingSyncAssignments = nil
        pendingDeletionAfterSyncSkillID = nil
        refreshPlan()
        noticeMessage = "已取消，没有保存任何安装选择。"
    }

    var isDeletingSkillAfterSync: Bool {
        pendingDeletionAfterSyncSkillID != nil
    }

    func deleteSkill(_ skill: SkillRecord, preservingInstalledCopies: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let mode: SkillDeletionMode = preservingInstalledCopies
                ? .preserveInstalledCopies
                : .requireNoManagedInstallations
            let deletion = try await store.deleteSkill(id: skill.id, mode: mode)
            lastDeletedSkill = deletion.archivedURL == nil ? nil : deletion
            if deletion.archivedURL == nil {
                statusMessage = "已清理 \(skill.displayName) 的失效记录，没有移动其他同名 Skill"
            } else if preservingInstalledCopies {
                statusMessage = "已将 \(skill.displayName) 移到废纸篓，应用中的副本保持不变"
            } else {
                statusMessage = "已将 \(skill.displayName) 移到废纸篓，可以立即撤销"
            }
            await reload()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func restoreLastDeletedSkill() async {
        guard !isBusy, let deletion = lastDeletedSkill else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let restored = try await store.restoreDeletedSkill(deletion)
            lastDeletedSkill = nil
            statusMessage = "已恢复 \(restored.displayName)"
            await reload()
        } catch { present(error) }
    }

    func dismissDeleteUndo() {
        lastDeletedSkill = nil
    }

    func setDeleteUndoPaused(_ paused: Bool) {
        guard deleteUndoPaused != paused else { return }
        deleteUndoPaused = paused
        scheduleDeleteUndoDismissal()
    }

    private func scheduleDeleteUndoDismissal() {
        deleteUndoDismissTask?.cancel()
        guard let deletion = lastDeletedSkill, !deleteUndoPaused else { return }
        let duration = deleteUndoDuration
        deleteUndoDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, !Task.isCancelled, !self.deleteUndoPaused,
                  self.lastDeletedSkill == deletion else { return }
            self.lastDeletedSkill = nil
        }
    }

    func hasManagedInstallation(for skill: SkillRecord) -> Bool {
        snapshot.installations.contains { $0.skillID == skill.id }
    }

    func availableTargets() -> [AgentTarget] {
        visibleTargets().filter(isAvailableForInstallation)
    }

    func unavailableTargets() -> [AgentTarget] {
        visibleTargets().filter { !isAvailableForInstallation($0) }
    }

    func visibleTargets() -> [AgentTarget] {
        snapshot.targets
            .filter(\.isVisible)
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    func hiddenBuiltinTargets() -> [AgentTarget] {
        snapshot.targets
            .filter { !$0.isCustom && !$0.isVisible }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    func setTargetVisibility(_ target: AgentTarget, isVisible: Bool, preservingManagedCopies: Bool = false) async -> Bool {
        let hasManagedCopies = snapshot.installations.contains { $0.targetID == target.id }
        if !isVisible, hasManagedCopies, !preservingManagedCopies {
            noticeMessage = "\(target.displayName) 仍有 SkillBox 管理的安装副本。你可以先卸载，或明确选择保留文件并停止管理。"
            return false
        }
        do {
            try await store.setTargetVisibility(
                id: target.id,
                isVisible: isVisible,
                preservingManagedCopies: preservingManagedCopies
            )
            statusMessage = isVisible ? "已将 \(target.displayName) 加回安装表" : "已从安装表移出 \(target.displayName)"
            await reload()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func restoreAllDefaultTargets() async {
        let defaultIDs = Set(BuiltinAgentAdapters.defaultAdapters.map(\.targetID))
        var targets = snapshot.targets
        var restored = 0
        for index in targets.indices where defaultIDs.contains(targets[index].id) && !targets[index].isVisible {
            targets[index].isVisible = true
            restored += 1
        }
        do {
            try await store.replaceTargets(targets)
            statusMessage = restored == 0 ? "十个预设应用都在安装表中" : "已恢复 \(restored) 个预设应用"
            await reload()
        } catch { present(error) }
    }

    func restoreDefaultTargetOrder() async {
        do {
            try await store.replaceTargets(BuiltinAgentAdapters.restoringDefaultOrder(in: snapshot.targets))
            statusMessage = "已恢复预设应用顺序"
            await reload()
        } catch { present(error) }
    }

    func saveVisibleTargetOrder(_ orderedIDs: [UUID]) async {
        let visible = visibleTargets()
        guard Set(orderedIDs) == Set(visible.map(\.id)), orderedIDs.count == visible.count else {
            noticeMessage = "应用列表在拖动时发生了变化，请重新调整顺序。"
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        var reordered = orderedIDs.compactMap { byID[$0] }
        var hidden = snapshot.targets.filter { !$0.isVisible }.sorted { $0.sortIndex < $1.sortIndex }
        for index in reordered.indices { reordered[index].sortIndex = index }
        for index in hidden.indices { hidden[index].sortIndex = reordered.count + index }
        do {
            try await store.replaceTargets(reordered + hidden)
            statusMessage = "应用顺序已保存"
            await reload()
        } catch { present(error) }
    }

    func moveVisibleTarget(_ target: AgentTarget, before destination: AgentTarget?) async {
        var visible = visibleTargets().filter { $0.id != target.id }
        if let destination, let index = visible.firstIndex(where: { $0.id == destination.id }) {
            visible.insert(target, at: index)
        } else {
            visible.append(target)
        }
        var hidden = snapshot.targets.filter { !$0.isVisible }
        for index in visible.indices { visible[index].sortIndex = index }
        for index in hidden.indices { hidden[index].sortIndex = visible.count + index }
        do {
            try await store.replaceTargets(visible + hidden)
            await reload()
        } catch { present(error) }
    }

    func orderedFolders() -> [SkillFolder] {
        snapshot.organization.folders.sorted { $0.sortIndex < $1.sortIndex }
    }

    func orderedSkills(in folderID: UUID?) -> [SkillRecord] {
        let skills = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0) })
        return snapshot.organization.placements
            .filter { $0.folderID == folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { skills[$0.skillID] }
    }

    func createSkillFolder(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            noticeMessage = "请先输入文件夹名称。"
            return false
        }
        guard !snapshot.organization.folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            noticeMessage = "已经有一个同名文件夹。"
            return false
        }
        var organization = snapshot.organization
        organization.folders.append(.init(name: trimmed, sortIndex: organization.folders.count))
        return await saveOrganization(organization)
    }

    func renameSkillFolder(_ folder: SkillFolder, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            noticeMessage = "文件夹名称不能为空。"
            return false
        }
        guard !snapshot.organization.folders.contains(where: { $0.id != folder.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            noticeMessage = "已经有一个同名文件夹。"
            return false
        }
        var organization = snapshot.organization
        guard let index = organization.folders.firstIndex(where: { $0.id == folder.id }) else { return false }
        organization.folders[index].name = trimmed
        return await saveOrganization(organization)
    }

    func deleteSkillFolder(_ folder: SkillFolder) async {
        var organization = snapshot.organization
        organization.deleteFolder(folder.id)
        _ = await saveOrganization(organization)
    }

    func moveSkill(_ skillID: UUID, to folderID: UUID?, before beforeSkillID: UUID? = nil) async {
        var organization = snapshot.organization
        organization.moveSkill(skillID, to: folderID, before: beforeSkillID)
        _ = await saveOrganization(organization)
    }

    func moveFolder(_ folderID: UUID, before beforeFolderID: UUID?) async {
        guard folderID != beforeFolderID else { return }
        var organization = snapshot.organization
        organization.moveFolder(folderID, before: beforeFolderID)
        _ = await saveOrganization(organization)
    }

    func authorize(action: SyncAction, replacement: Bool) async {
        var assignments = pendingSyncAssignments ?? snapshot.assignments
        guard let index = assignments.firstIndex(where: { $0.skillID == action.skillID && $0.targetID == action.targetID }) else { return }
        if replacement { assignments[index].allowReplacement = true }
        else { assignments[index].allowTakeover = true }
        assignments[index].authorizedDestinationFingerprint = action.expectedDestinationFingerprint
        if pendingSyncAssignments != nil {
            pendingSyncAssignments = assignments
            refreshPlan()
        } else {
            do { try await store.replaceAssignments(assignments); await reload() } catch { present(error) }
        }
    }

    func executePlan() async {
        guard syncPlan != nil else { return }
        let deletionSkillID = pendingDeletionAfterSyncSkillID
        isBusy = true
        defer {
            pendingSyncAssignments = nil
            pendingDeletionAfterSyncSkillID = nil
            isBusy = false
        }
        do {
            if let pendingSyncAssignments {
                try await store.replaceAssignments(pendingSyncAssignments)
                self.pendingSyncAssignments = nil
                await reload()
            }
            guard let syncPlan, !syncPlan.executableActions.isEmpty else {
                noticeMessage = "开始前重新检查时发现了变化，暂时没有修改应用文件。"
                return
            }
            let result = try await executor.execute(plan: syncPlan, store: store)
            await reload()
            var completionMessage = "安装完成：更新了 \(result.backups.count) 个位置"
            if let deletionSkillID {
                guard result.status == .succeeded,
                      !snapshot.installations.contains(where: { $0.skillID == deletionSkillID })
                else {
                    noticeMessage = "仍有副本没有安全卸载，SkillBox 主 Skill 已保留。"
                    await scanInstalledSkills()
                    return
                }
                guard let skill = snapshot.skills.first(where: { $0.id == deletionSkillID }) else {
                    noticeMessage = "卸载已经完成，但在「我的 Skills」中找不到准备清理的主 Skill。"
                    await scanInstalledSkills()
                    return
                }
                let deletion = try await store.deleteSkill(id: deletionSkillID)
                lastDeletedSkill = deletion.archivedURL == nil ? nil : deletion
                completionMessage = deletion.archivedURL == nil
                    ? "已从所有应用卸载并清理 \(skill.displayName) 的失效记录"
                    : "已从所有应用卸载，并将 \(skill.displayName) 移到废纸篓"
                await reload()
            }
            await scanInstalledSkills()
            statusMessage = completionMessage
        } catch { present(error) }
    }

    func canRestoreTransaction(_ transaction: SyncTransaction) -> Bool {
        guard transaction.canRestore(), transaction.libraryRestoration == nil else { return false }
        if let deletion = transaction.libraryDeletion?.deletion {
            return !snapshot.skills.contains(where: { $0.id == deletion.record.id })
                && deletion.archivedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        return true
    }

    func prepareUndoPreview(_ transaction: SyncTransaction) -> Bool {
        guard let current = snapshot.transactions.first(where: { $0.id == transaction.id }),
              canRestoreTransaction(current)
        else {
            noticeMessage = "这条操作记录已经无法恢复，请刷新后再查看。"
            return false
        }
        pendingUndoTransaction = current
        return true
    }

    func cancelUndoPreview() {
        pendingUndoTransaction = nil
        noticeMessage = "已取消恢复，没有修改任何文件。"
    }

    func confirmPendingUndo() async {
        guard let transaction = pendingUndoTransaction else { return }
        pendingUndoTransaction = nil
        await undo(transaction)
    }

    func undo(_ transaction: SyncTransaction) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let persisted = await store.currentSnapshot()
            guard let current = persisted.transactions.first(where: { $0.id == transaction.id }), current.canRestore() else {
                throw SyncExecutorError.rollbackExpired
            }
            if let deletion = current.libraryDeletion?.deletion {
                _ = try await store.restoreDeletedSkill(deletion)
                if lastDeletedSkill?.record.id == deletion.record.id { lastDeletedSkill = nil }
            } else {
                _ = try await executor.undo(transactionID: transaction.id, store: store)
            }
            statusMessage = "已恢复到操作前"
            await reload()
            await scanInstalledSkills()
        } catch {
            await reload()
            present(error)
        }
    }

    func addCustomTarget(name: String, url: URL) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            noticeMessage = "请先输入应用名称。"
            return
        }
        do {
            let validatedURL = try PathSafety.validatedCustomTarget(
                url,
                homeDirectory: homeDirectory,
                libraryRoot: libraryRoot
            )
            guard !snapshot.targets.contains(where: { $0.path == validatedURL.path }) else {
                noticeMessage = "这个文件夹已经添加过了。"
                return
            }
            var targets = snapshot.targets
            targets.append(.init(kind: .custom, displayName: trimmed, path: validatedURL.path, detectionStatus: .available, writeStatus: FileManager.default.isWritableFile(atPath: validatedURL.path) ? .writable : .readOnly, isCustom: true, sortIndex: targets.count))
            try await store.replaceTargets(targets)
            await reload()
        } catch { present(error) }
    }

    func updateCustomTarget(_ target: AgentTarget, name: String, url: URL) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.isCustom else { return }
        guard !trimmed.isEmpty else {
            noticeMessage = "请先输入应用名称。"
            return
        }
        do {
            let validatedURL = try PathSafety.validatedCustomTarget(
                url,
                homeDirectory: homeDirectory,
                libraryRoot: libraryRoot
            )
            if target.path != validatedURL.path,
               snapshot.installations.contains(where: { $0.targetID == target.id })
            {
                noticeMessage = "这个位置仍有 Skill 由 SkillBox 管理。请先卸载，再更换文件夹。"
                return
            }
            var targets = snapshot.targets
            guard let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
            targets[index].displayName = trimmed
            targets[index].path = validatedURL.path
            targets[index].detectionStatus = .available
            targets[index].writeStatus = FileManager.default.isWritableFile(atPath: validatedURL.path) ? .writable : .readOnly
            try await store.replaceTargets(targets)
            statusMessage = "已更新安装位置"
            await reload()
        } catch { present(error) }
    }

    func removeCustomTarget(_ target: AgentTarget, preservingManagedCopies: Bool = false) async {
        do {
            try await store.removeCustomTarget(
                id: target.id,
                preservingManagedCopies: preservingManagedCopies
            )
            statusMessage = "已移除 \(target.displayName) 的安装位置"
            await reload()
        } catch { present(error) }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func contentURL(for skill: SkillRecord) async -> URL { await store.contentURL(for: skill) }

    func skillStorageSize(_ skill: SkillRecord) async -> Int64? {
        let url = await store.contentURL(for: skill)
        return await Task.detached(priority: .utility) {
            try? SkillStorageMetrics.byteCount(at: url)
        }.value
    }

    func skillMarkdown(_ skill: SkillRecord) async -> String {
        let url = await store.contentURL(for: skill).appendingPathComponent("SKILL.md")
        return await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取 SKILL.md"
        }.value
    }

    func skillDirectory(_ skill: SkillRecord) async -> [SkillDirectoryEntry] {
        let url = await store.contentURL(for: skill)
        return await Task.detached(priority: .userInitiated) {
            (try? SkillDirectoryReader().entries(at: url)) ?? []
        }.value
    }

    func skillUsageGuide(_ skill: SkillRecord) async -> SkillUsageGuide? {
        if let saved = await usageGuideStore.load(skillID: skill.id, fingerprint: skill.fingerprint) {
            return saved.guide
        }
        let compatibleSaved = await usageGuideStore.loadCompatible(
            skillID: skill.id,
            fingerprint: skill.fingerprint
        )
        let url = await store.contentURL(for: skill)
        let extracted = await Task.detached(priority: .userInitiated) {
            SkillUsageGuideExtractor().extract(from: url)
        }.value
        let fallback = SkillUsageGuideFallbackSelection.preferred(
            cached: compatibleSaved?.guide,
            extracted: extracted
        )
        return fallback
    }

    var isAgnesUsageGuideConfigured: Bool {
        configuredAIProviderIDs.contains("agnes") &&
            aiSettings.isConnectionVerified(providerID: "agnes")
    }

    /// The only network entry point for a managed Skill introduction. Merely
    /// opening or switching Skills stays local; the detail button calls this
    /// method as the user's authorization for one request.
    func generateSkillUsageGuide(_ skill: SkillRecord) async -> SkillUsageGuide? {
        let key = "\(skill.id.uuidString)::\(skill.fingerprint)::\(SkillUsageGuideRecord.currentPromptVersion)"
        if let task = manualUsageGuideTasks[key] {
            switch await task.value {
            case let .success(guide): return guide
            case .failure: return nil
            }
        }
        guard isAgnesUsageGuideConfigured,
              let configuration = aiSettings.configuration(id: "agnes")
        else {
            noticeMessage = "请先到“设置 → AI”连接你的 Agnes API。"
            return nil
        }
        generatingUsageGuideSkillIDs.insert(skill.id)

        let libraryStore = store
        let guideStore = usageGuideStore
        let keyStore = aiKeyStore
        let provider = aiProvider
        let task = Task<ManualUsageGuideTaskResult, Never> {
            do {
                guard let apiKey = try await keyStore.loadForUserInitiatedAccess(providerID: "agnes") else {
                    throw AIServiceError.missingAPIKey
                }
                let url = await libraryStore.contentURL(for: skill)
                let material = await Task.detached(priority: .userInitiated) {
                    SkillUsageGuideMaterialReader().read(
                        from: url,
                        name: skill.displayName,
                        description: skill.description
                    )
                }.value
                var guide = try await provider.analyzeSkillUsage(
                    material: material,
                    configuration: configuration,
                    apiKey: apiKey
                ).value
                try Task.checkCancellation()
                guide.origin = .aiAssisted
                guide.sourceDocuments = material.documents.map(\.relativePath)
                try await guideStore.save(
                    guide,
                    skillID: skill.id,
                    fingerprint: skill.fingerprint,
                    providerID: "agnes",
                    model: configuration.model
                )
                return .success(guide)
            } catch {
                let category: AIInvocationErrorCategory? = if case let AIServiceError.invocation(failure) = error {
                    failure.category
                } else {
                    nil
                }
                return .failure(.init(message: error.localizedDescription, category: category))
            }
        }
        manualUsageGuideTasks[key] = task
        let result = await task.value
        manualUsageGuideTasks[key] = nil
        generatingUsageGuideSkillIDs.remove(skill.id)
        switch result {
        case let .success(guide):
            usageGuideRevision &+= 1
            statusMessage = "已获取 \(skill.displayName) 的 Skill 介绍"
            return guide
        case let .failure(failure):
            if failure.message == AIServiceError.missingAPIKey.localizedDescription {
                noticeMessage = "请先到“设置 → AI”重新保存 Agnes API Key。"
            } else if failure.message == AIServiceError.keychainAuthorizationNotCompleted.localizedDescription {
                noticeMessage = failure.message
            } else if failure.category == .truncatedOutput {
                noticeMessage = "Agnes 返回的介绍不完整。已有介绍已保留，请稍后重试。"
            } else {
                noticeMessage = "\(failure.message)。已有介绍已保留，可以稍后重试。"
            }
            return nil
        }
    }

    func hasUnmanagedSameName(skill: SkillRecord, target: AgentTarget) -> Bool {
        let destination = URL(fileURLWithPath: target.path)
            .appendingPathComponent(skill.canonicalName)
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: destination) else { return false }
        return !snapshot.installations.contains { $0.destinationPath == destination }
    }

    private func preview(provider: any SourceProvider, locator: String) async {
        guard let candidates = await loadPreview(provider: provider, locator: locator) else { return }
        activeConflict = nil
        pendingCandidates = candidates
        selectedCandidateIDs = Set(candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
    }

    private func loadPreview(provider: any SourceProvider, locator: String) async -> [SkillCandidate]? {
        isBusy = true
        defer { isBusy = false }
        do {
            return try await provider.preview(locator: locator)
        } catch { present(error); return nil }
    }

    private func comparisonChanges(for action: SyncAction, skill: SkillRecord) async -> [SkillFileChange] {
        guard action.expectedDestinationFingerprint != nil,
              action.expectedDestinationFingerprint != action.expectedSourceFingerprint,
              FileManager.default.fileExists(atPath: action.destinationPath)
        else { return [] }
        let source = await store.contentURL(for: skill)
        let destination = URL(fileURLWithPath: action.destinationPath)
        return await Task.detached(priority: .userInitiated) {
            (try? SkillDiffAnalyzer().compare(before: destination, after: source)) ?? []
        }.value
    }

    private func cleanupGitHubCandidates(_ candidates: [SkillCandidate]) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let roots = Set(candidates.filter { $0.source.kind == .github }.compactMap { candidate -> URL? in
            var url = candidate.sourceURL.standardizedFileURL
            while url.path.hasPrefix(temporaryRoot), url.path != temporaryRoot {
                if url.lastPathComponent.hasPrefix("SkillBoxGitHub-") ||
                    url.lastPathComponent.hasPrefix("SkillBoxPackage-")
                { return url }
                url.deleteLastPathComponent()
            }
            return nil
        })
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func cleanupLocalCandidates(_ candidates: [SkillCandidate]) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let roots = Set(candidates.compactMap { candidate -> URL? in
            guard let root = candidate.temporaryPackageRoot?.standardizedFileURL,
                  root.deletingLastPathComponent() == temporaryRoot,
                  candidate.sourceURL.standardizedFileURL == root
                    .appendingPathComponent("content", isDirectory: true)
                    .standardizedFileURL
            else { return nil }
            return root
        })
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func refreshPlan() {
        var planningSnapshot = snapshot
        if let pendingSyncAssignments {
            planningSnapshot.assignments = pendingSyncAssignments
        }
        do { syncPlan = try planner.makePlan(snapshot: planningSnapshot, libraryRoot: libraryRoot) }
        catch { present(error) }
    }

    private func refreshTargetStatuses() async {
        let targets = BuiltinAgentAdapters.reconciledTargets(
            persisted: snapshot.targets,
            homeDirectory: homeDirectory
        )
        do {
            try await store.replaceTargets(targets)
            await reload()
        } catch {
            present(error)
        }
    }

    private func isAvailableForInstallation(_ target: AgentTarget) -> Bool {
        target.detectionStatus == .available && target.writeStatus == .writable
    }

    private func unavailableMessage(for target: AgentTarget) -> String {
        if target.detectionStatus != .available {
            return "本机没有找到 \(target.displayName) 的 Skills 文件夹。请先安装并打开一次该应用，SkillBox 不会代为创建目录。"
        }
        return "\(target.displayName) 的 Skills 文件夹目前不能写入，请检查目录权限后再试。"
    }

    private func setAssignment(
        skill: SkillRecord,
        target: AgentTarget,
        desired: Bool,
        assignments: inout [Assignment]
    ) {
        if desired {
            for index in assignments.indices where
                assignments[index].targetID == target.id &&
                assignments[index].installationDirectoryName.caseInsensitiveCompare(skill.canonicalName) == .orderedSame
            {
                assignments[index].isDesired = false
                clearAuthorization(&assignments[index])
            }
        }
        if let index = assignments.firstIndex(where: { $0.skillID == skill.id && $0.targetID == target.id }) {
            assignments[index].isDesired = desired
            if !desired { clearAuthorization(&assignments[index]) }
        } else if desired {
            assignments.append(.init(skillID: skill.id, targetID: target.id, installationDirectoryName: skill.canonicalName))
        }
    }

    private func clearAuthorization(_ assignment: inout Assignment) {
        assignment.allowTakeover = false
        assignment.allowReplacement = false
        assignment.authorizedDestinationFingerprint = nil
    }

    private func saveOrganization(_ organization: SkillOrganization) async -> Bool {
        do {
            try await store.replaceOrganization(organization)
            snapshot.organization = organization
            return true
        } catch {
            present(error)
            return false
        }
    }

    private func checkAllGitHubUpdatesIfStale() async {
        let eligibleIDs = Set(snapshot.sourceStates.compactMap { state in
            state.checkingEnabled && GitHubAutomaticCheckPolicy.isDue(lastCheckedAt: state.lastCheckedAt)
                ? state.skillID
                : nil
        })
        guard !eligibleIDs.isEmpty else { return }
        // Startup checks stay anonymous so opening SkillBox never touches a
        // saved credential. Private sources are retried only after a user action.
        _ = try? await automaticGitHubUpdateChecker.checkAll(skillIDs: eligibleIDs)
        await reload()
    }

    private func readMarkdown(at url: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? "这个版本没有可预览的 SKILL.md"
        }.value
    }

    private func sourceState(
        skillID: UUID,
        skillPath: String?,
        remote: GitHubRemoteVersion,
        recipe: GitHubPackageRecipe?
    ) -> GitHubSourceState {
        let needsRemotePackageBaseline = recipe?.skillPath == nil &&
            recipe?.includePaths.isEmpty == false &&
            !remote.treeSHA.hasPrefix("package:")
        return .init(
            skillID: skillID,
            repositoryID: remote.repositoryID,
            repositoryFullName: remote.repositoryFullName,
            repositoryIsPrivate: remote.isPrivate,
            skillPath: skillPath,
            trackingMode: remote.trackingMode,
            defaultBranch: remote.defaultBranch,
            currentVersionIdentifier: remote.versionIdentifier,
            currentVersionName: remote.versionName,
            currentCommitSHA: remote.commitSHA,
            currentTreeSHA: needsRemotePackageBaseline ? nil : remote.treeSHA,
            currentReleaseID: remote.releaseID,
            currentAssetID: remote.selectedReleaseAsset?.id,
            currentAssetName: remote.selectedReleaseAsset?.name,
            currentAssetDigest: remote.selectedReleaseAsset?.digest,
            lastCheckedAt: Date(),
            packageRecipe: recipe,
            checkingEnabled: true,
            status: needsRemotePackageBaseline ? .needsInitialCheck : .current
        )
    }

    private func pollGitHubAuthorization(_ authorization: GitHubDeviceAuthorization) async {
        var interval = authorization.pollingInterval
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
                switch try await githubDeviceClient.pollAuthorization(authorization) {
                case .pending: continue
                case .slowDown: interval += 5
                case let .authorized(tokens):
                    try await githubSession.save(tokens)
                    setGitHubConnectionHint(true)
                    githubAuthorization = nil
                    try await githubUpdateChecker.resumeChecksAfterConnectingGitHub()
                    await reload()
                    await refreshGitHubRepositories()
                    if githubAuthorizedRepositories.isEmpty {
                        isWaitingForGitHubRepositorySelection = true
                        githubLoginStatus = "身份确认完成。正在打开仓库选择页…"
                        manageGitHubRepositories()
                        await waitForGitHubRepositorySelection()
                    }
                    return
                case .expired:
                    isWaitingForGitHubRepositorySelection = false
                    githubLoginStatus = "验证码已过期，请重新连接"
                    return
                case .denied:
                    isWaitingForGitHubRepositorySelection = false
                    githubLoginStatus = "你取消了这次连接"
                    return
                }
            } catch {
                if !Task.isCancelled { present(error) }
                return
            }
        }
    }

    private func waitForGitHubRepositorySelection() async {
        for _ in 0..<100 {
            do {
                try await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                let repositories = try await githubProvider.authorizedRepositories()
                guard !repositories.isEmpty else { continue }
                githubAuthorizedRepositories = repositories
                isWaitingForGitHubRepositorySelection = false
                githubLoginStatus = "连接完成，已找到 \(repositories.count) 个可读取的仓库。"
                return
            } catch is CancellationError {
                return
            } catch GitHubSourceError.authenticationRequired {
                setGitHubConnectionHint(false)
                isWaitingForGitHubRepositorySelection = false
                githubLoginStatus = "连接已失效，请重新连接 GitHub"
                return
            } catch {
                continue
            }
        }
        githubLoginStatus = "还没有找到已选仓库。你可以重新打开 GitHub 选择页。"
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = ""
    }

    private func setGitHubConnectionHint(_ connected: Bool) {
        isGitHubConnected = connected
        userDefaults.set(connected, forKey: Self.githubConnectionHintKey)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
