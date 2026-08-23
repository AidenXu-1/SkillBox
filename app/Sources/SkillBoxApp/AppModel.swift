import AppKit
import Combine
import Foundation
import SkillBoxCore

struct SkillBoxOperationProgress: Equatable {
    var title: String
    var detail: String
    var canCancel: Bool
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

@MainActor
final class AppModel: ObservableObject {
    static let githubConnectionHintKey = "SkillBoxGitHubConnectionHint"

    @Published var snapshot = LibrarySnapshot()
    @Published var scanResult: ScanResult?
    @Published var pendingCandidates: [SkillCandidate] = []
    @Published var selectedCandidateIDs: Set<String> = []
    @Published var activeConflict: ConflictGroup?
    @Published var syncPlan: SyncPlan?
    @Published var isBusy = false
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
    @Published private(set) var lastDeletedSkill: DeletedSkillBackup?
    @Published private(set) var pendingDeletionAfterSyncSkillID: UUID?
    @Published var canRetryGitHubWithDefaultBranch = false
    @Published var pendingReleasePackageChoice: GitHubReleasePackageChoice?
    @Published var pendingInstallContentChoice: GitHubInstallContentChoice?
    @Published var pendingLocalSourceSetup: LocalSourceSetup?
    @Published var pendingLocalIgnoredChangedPaths: [String] = []
    @Published var discoverySessions: [DiscoverySession] = []
    @Published var selectedDiscoverySessionID: UUID?
    @Published var selectedDiscoveryCandidateID: String?
    @Published var discoveryDraft = ""
    @Published var isDiscoverySearching = false
    @Published var discoveryRunState: DiscoveryRunState?
    @Published private(set) var activeDiscoverySessionID: UUID?
    @Published private(set) var generatingDiscoveryUsageGuideCandidateID: String?
    @Published var discoveryStorageBytes: Int64 = 0
    @Published var aiSettings = AISettings.defaults
    @Published var configuredAIProviderIDs: Set<String> = []
    @Published var isTestingAIConnection = false
    @Published var aiConnectionStatus = ""

    let libraryRoot: URL
    let discoverySessionsDirectory: URL
    private let store: LibraryStore
    private let discoveryStore: DiscoverySessionStore
    private let usageGuideStore: SkillUsageGuideStore
    private let aiSettingsStore: AISettingsStore
    private let aiKeyStore: any AIKeyStore
    private let aiProvider: any AIProvider
    private let userDefaults: UserDefaults
    private lazy var discoveryProvider = DiscoverySearchCoordinator(providers: [
        SkillsShDiscoveryProvider(repositoryTokenProvider: githubSession),
        GitHubSkillDiscoveryProvider(tokenProvider: githubSession),
    ])
    private let scanner = FileSystemSkillScanner()
    private let planner = DefaultSyncPlanner()
    private let executor = TransactionalSyncExecutor()
    private let updateCoordinator = SkillUpdateCoordinator()
    private let localPackageResolver = LocalSkillPackageResolver()
    private let homeDirectory: URL
    private lazy var githubDeviceClient = GitHubDeviceFlowClient(clientID: githubClientID)
    private lazy var githubSession = GitHubAuthenticatedSession(
        client: githubDeviceClient,
        credentialStore: KeychainGitHubCredentialStore()
    )
    private lazy var githubProvider = GitHubSourceProvider(tokenProvider: githubSession)
    private lazy var githubUpdateChecker = GitHubUpdateChecker(checker: githubProvider, store: store)
    private lazy var automaticGitHubUpdateChecker = GitHubUpdateChecker(
        checker: GitHubSourceProvider(),
        store: store
    )
    private var githubLoginTask: Task<Void, Never>?
    private var remoteOperationTask: Task<Void, Never>?
    private var pendingGitHubPackageRecipes: [String: GitHubPackageRecipe] = [:]
    private var pendingLocalPackages: [String: PreparedLocalPackage] = [:]
    private var pendingLocalTrackingEnabled = false
    private var pendingLocalUpdateState: LocalSourceState?
    private var pendingDiscoveryCandidateName: String?
    private var pendingDiscoveryUsageGuide: SkillUsageGuide?
    private var pendingDiscoveryUsageGuideSourceDigest: String?
    private var discoveryUsageGuideTask: Task<Void, Never>?
    private var discoveryUsageGuideGenerationID: UUID?
    private var discoveryCandidateSelectionTask: Task<Void, Never>?
    private var discoveryCandidateSelectionGenerationID: UUID?
    private var discoverySearchTask: Task<Void, Never>?
    private var activeGitHubPreviewOperationID: UUID?
    private var retryGitHubImportContext: GitHubImportContext?
    private var invalidatedDiscoverySessionIDs = Set<UUID>()
    private var aiAuthorizationGeneration = 0

    var githubClientID: String { Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubClientID") as? String ?? "" }
    var isGitHubConfigured: Bool { !githubClientID.isEmpty && githubInstallURL != nil }
    var githubInstallURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubInstallURL") as? String else { return nil }
        return URL(string: value)
    }

    init(
        libraryRoot customLibraryRoot: URL? = nil,
        store providedStore: LibraryStore? = nil,
        homeDirectory customHomeDirectory: URL? = nil,
        aiKeyStore providedAIKeyStore: (any AIKeyStore)? = nil,
        aiProvider providedAIProvider: (any AIProvider)? = nil,
        userDefaults: UserDefaults = .standard,
        startBootstrap: Bool = true
    ) {
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
        aiKeyStore = providedAIKeyStore ?? KeychainAIKeyStore()
        aiProvider = providedAIProvider ?? OpenAICompatibleProvider()
        self.userDefaults = userDefaults
        showOnboarding = !UserDefaults.standard.bool(forKey: "SkillBoxOnboardingCompleted")
        if startBootstrap {
            Task { await bootstrap() }
        }
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
                errorMessage = "上次未完成的安装没有全部恢复，请在「最近操作」中查看详情。"
            } else if !recovered.isEmpty {
                statusMessage = "已恢复上次异常中断的安装操作"
            }
        } catch { present(error) }
        let persisted = await store.currentSnapshot()
        let builtin = BuiltinAgentAdapters.all.map { $0.makeTarget(homeDirectory: homeDirectory, fileManager: .default) }
        let custom = persisted.targets.filter(\.isCustom)
        do { try await store.replaceTargets(builtin + custom) } catch { present(error) }
        do { try await store.refreshRiskReports(using: StaticRiskAnalyzer()) } catch { present(error) }
        await reload()
        lastDeletedSkill = await store.mostRecentRestorableDeletion()
        do { _ = try await discoveryStore.recoverInterruptedRuns() } catch { present(error) }
        await reloadDiscoverySessions()
        await reloadCredentialHints()
        await scanInstalledSkills()
        await checkAllGitHubUpdatesIfStale()
    }

    func reload() async {
        snapshot = await store.currentSnapshot()
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

    var isGeneratingSelectedDiscoveryUsageGuide: Bool {
        generatingDiscoveryUsageGuideCandidateID == selectedDiscoveryCandidateID
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
            guard let key = try await aiKeyStore.load(providerID: providerID),
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
        cancelDiscoveryUsageGuide()
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
        if let session = selectedDiscoverySession,
           selectedDiscoveryCandidateID == nil || !session.candidates.contains(where: { $0.id == selectedDiscoveryCandidateID })
        {
            selectedDiscoveryCandidateID = session.selectedCandidateID ?? session.candidates.first?.id
        }
    }

    func beginNewDiscovery() {
        cancelDiscoveryCandidateSelection()
        cancelDiscoveryUsageGuide()
        selectedDiscoverySessionID = nil
        selectedDiscoveryCandidateID = nil
        discoveryDraft = ""
        statusMessage = "可以开始一次新的 Skill 寻找"
    }

    func selectDiscoverySession(_ id: UUID?) {
        cancelDiscoveryCandidateSelection()
        cancelDiscoveryUsageGuide()
        selectedDiscoverySessionID = id
        let session = discoverySessions.first { $0.id == id }
        selectedDiscoveryCandidateID = session?.selectedCandidateID ?? session?.candidates.first?.id
        discoveryDraft = ""
    }

    func selectDiscoveryCandidate(_ id: String) {
        cancelDiscoveryCandidateSelection()
        cancelDiscoveryUsageGuide()
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
                guard !Task.isCancelled,
                      self.discoveryCandidateSelectionGenerationID == generationID,
                      self.selectedDiscoverySessionID == session.id,
                      self.selectedDiscoveryCandidateID == id
                else { return }
                self.startDiscoveryUsageGuideGeneration(sessionID: session.id, candidateID: id)
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

    private func startDiscoveryUsageGuideGeneration(sessionID: UUID, candidateID: String) {
        let generationID = UUID()
        discoveryUsageGuideGenerationID = generationID
        generatingDiscoveryUsageGuideCandidateID = candidateID
        discoveryUsageGuideTask = Task { [weak self] in
            guard let self else { return }
            await self.generateDiscoveryUsageGuideIfNeeded(sessionID: sessionID, candidateID: candidateID)
            guard self.discoveryUsageGuideGenerationID == generationID else { return }
            self.discoveryUsageGuideTask = nil
            self.discoveryUsageGuideGenerationID = nil
            self.generatingDiscoveryUsageGuideCandidateID = nil
        }
    }

    func cancelDiscoveryUsageGuide() {
        discoveryUsageGuideTask?.cancel()
        discoveryUsageGuideTask = nil
        discoveryUsageGuideGenerationID = nil
        generatingDiscoveryUsageGuideCandidateID = nil
    }

    private func generateDiscoveryUsageGuideIfNeeded(sessionID: UUID, candidateID: String) async {
        guard !Task.isCancelled,
              let session = discoverySessions.first(where: { $0.id == sessionID }),
              let candidate = session.candidates.first(where: { $0.id == candidateID }),
              candidate.usageGuide == nil,
              AIContentSharingPolicy.canSend(
                  sourceKind: .github,
                  repositoryIsPrivate: candidate.evidence.repositoryIsPrivate,
                  allowPrivateSkillContent: aiSettings.isPrivateContentSharingAllowedForSelectedProvider
              ),
              let configuration = aiSettings.selectedVerifiedConfiguration,
              configuredAIProviderIDs.contains(configuration.id),
              let key = try? await aiKeyStore.load(providerID: configuration.id),
              !key.isEmpty
        else { return }
        guard !Task.isCancelled else { return }

        let source = candidate.evidence.skillDocumentExcerpt ?? candidate.userFacingSummary ?? ""
        let excerpt = String(source.prefix(DiscoveryEvaluationLimits.maximumLazyGuideCharacters))
        let sourceDigest = candidate.evidence.skillDocumentExcerpt.map(SkillUsageGuideSourceIdentity.digest(markdown:))
        guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let material = SkillUsageGuideMaterial(
            name: candidate.name,
            description: candidate.userFacingSummary ?? "",
            documents: [.init(relativePath: "SKILL.md", content: excerpt)]
        )

        let analyzed: AIInvocationResult<SkillUsageGuide>
        do {
            analyzed = try await aiProvider.analyzeSkillUsage(
                material: material,
                configuration: configuration,
                apiKey: key
            )
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        do {
            guard try await discoveryStore.saveUsageGuide(
                sessionID: sessionID,
                storageFolderName: session.storageFolderName,
                candidateID: candidateID,
                guide: analyzed.value,
                sourceDigest: sourceDigest,
                diagnostics: analyzed.diagnostics
            ) != nil else { return }
            await reloadDiscoverySessions(allowAutomaticSelection: false)
        } catch { present(error) }
    }

    func startDiscoverySearch() {
        guard discoverySearchTask == nil, !isDiscoverySearching else { return }
        cancelDiscoveryCandidateSelection()
        cancelDiscoveryUsageGuide()
        discoverySearchTask = Task { [weak self] in
            guard let self else { return }
            await self.submitDiscoverySearch()
            self.discoverySearchTask = nil
        }
    }

    func cancelDiscoverySearch() {
        discoverySearchTask?.cancel()
    }

    private func submitDiscoverySearch() async {
        let text = discoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled, !isDiscoverySearching, !text.isEmpty else {
            if text.isEmpty { noticeMessage = "先说说你想让 AI 帮你完成什么。" }
            return
        }
        isDiscoverySearching = true
        discoveryRunState = .understanding
        defer {
            isDiscoverySearching = false
            discoveryRunState = nil
            activeDiscoverySessionID = nil
        }
        var session: DiscoverySession
        let isNewSession: Bool
        if let current = selectedDiscoverySession {
            session = current
            isNewSession = false
        } else {
            session = await discoveryStore.makeSession(title: String(text.prefix(28)))
            isNewSession = true
        }
        activeDiscoverySessionID = session.id
        selectedDiscoverySessionID = session.id
        invalidatedDiscoverySessionIDs.remove(session.id)
        session.messages.append(.init(role: .user, text: text))
        let fallbackPlan = DiscoveryIntentPlanner.fallback(message: text, previous: session.intent)
        let runID = UUID()
        session.runs.append(.init(id: runID, queries: fallbackPlan.queries, state: .understanding))
        discoveryDraft = ""
        session.updatedAt = Date()
        guard await saveDiscoveryResult(session, allowCreate: isNewSession) else { return }

        var plan = fallbackPlan
        var configurationUsed: AIProviderConfiguration?
        var keyUsed: String?
        var authorizationGenerationUsed: Int?
        var fallbackReason: String?
        var diagnostics: [AIInvocationDiagnostic] = []
        if let configuration = aiSettings.selectedVerifiedConfiguration,
           configuredAIProviderIDs.contains(configuration.id)
        {
            do {
                if let key = try await aiKeyStore.load(providerID: configuration.id), !key.isEmpty {
                    let authorizationGeneration = aiAuthorizationGeneration
                    guard aiSettings.selectedVerifiedConfiguration == configuration,
                          configuredAIProviderIDs.contains(configuration.id)
                    else { throw CancellationError() }
                    let result = try await aiProvider.planDiscovery(
                        message: text,
                        previousIntent: session.intent,
                        configuration: configuration,
                        apiKey: key
                    )
                    guard authorizationGeneration == aiAuthorizationGeneration else {
                        throw CancellationError()
                    }
                    plan = result.value
                    diagnostics.append(contentsOf: result.diagnostics)
                    configurationUsed = configuration
                    keyUsed = key
                    authorizationGenerationUsed = authorizationGeneration
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
        } else {
            fallbackReason = "本轮未使用 AI 语义筛选，当前结果来自已核对的公开资料。"
        }
        session.intent = plan.intent
        Self.updateDiscoveryRun(in: &session, id: runID, state: .understanding, queries: plan.queries, diagnostics: diagnostics, fallbackReason: fallbackReason)

        if plan.needsClarification, let question = plan.clarifyingQuestion, !question.isEmpty {
            session.messages.append(.init(
                role: .assistant,
                text: question,
                providerID: configurationUsed?.id,
                model: configurationUsed?.model
            ))
            Self.updateDiscoveryRun(in: &session, id: runID, state: .completed, queries: plan.queries, diagnostics: diagnostics, fallbackReason: fallbackReason)
            session.updatedAt = Date()
            _ = await saveDiscoveryResult(session)
            return
        }

        do {
            discoveryRunState = .recalling
            Self.updateDiscoveryRun(in: &session, id: runID, state: .recalling, queries: plan.queries, diagnostics: diagnostics, fallbackReason: fallbackReason)
            session.updatedAt = Date()
            guard await saveDiscoveryResult(session) else { return }

            try Task.checkCancellation()
            let searchScope: DiscoverySearchScope = plan.intent.preferences.contains(where: { $0.contains("继续深挖") }) ? .deep : .initial
            let result = try await discoveryProvider.search(queries: plan.queries, limitPerQuery: searchScope.limitPerQuery)
            try Task.checkCancellation()
            if result.failedSourceCount > 0 {
                fallbackReason = Self.combinedNotice(
                    fallbackReason,
                    "本轮有 \(result.failedSourceCount) 个公开来源暂时未完成，已保留其他来源中核对通过的结果。"
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
                retrievedCandidateCount: result.candidates.count
            )
            session.updatedAt = Date()
            guard await saveDiscoveryResult(session) else { return }

            var evaluation: DiscoveryEvaluation?
            let evaluationFrontier = DiscoveryCandidateRanker.candidatesForEvaluation(
                result.candidates,
                intent: plan.intent,
                allowPrivateSkillContent: aiSettings.isPrivateContentSharingAllowedForSelectedProvider
            )
            let evaluationCandidates = Array(evaluationFrontier.prefix(DiscoveryEvaluationLimits.maximumCandidates))
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
                        retrievedCandidateCount: result.candidates.count,
                        evaluationCandidateCount: evaluationCandidates.count
                    )
                    session.updatedAt = Date()
                    guard await saveDiscoveryResult(session) else { return }
                    if !evaluationCandidates.isEmpty {
                        try Task.checkCancellation()
                        guard authorizationGenerationUsed == aiAuthorizationGeneration,
                              aiSettings.selectedVerifiedConfiguration == configurationUsed,
                              configuredAIProviderIDs.contains(configurationUsed.id)
                        else { throw CancellationError() }
                        let evaluated = try await aiProvider.evaluateCandidates(
                            intent: plan.intent,
                            candidates: evaluationCandidates,
                            configuration: configurationUsed,
                            apiKey: keyUsed
                        )
                        try Task.checkCancellation()
                        evaluation = evaluated.value
                        diagnostics.append(contentsOf: evaluated.diagnostics)
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
            let semanticRouting = DiscoveryCandidateRanker.semanticRouting(
                evaluation: evaluation,
                fallbackCandidateIDs: Set(evaluationFrontier.map(\.id))
            )
            let ranked = DiscoveryCandidateRanker.rank(
                result.candidates,
                intent: plan.intent,
                originalQueryCandidateIDs: result.originalQueryCandidateIDs,
                relevantCandidateIDs: semanticRouting.relevantCandidateIDs,
                evaluatedCandidateIDs: semanticRouting.evaluatedCandidateIDs
            )
            let evaluationByID = Dictionary(
                (evaluation?.recommendations ?? []).map { ($0.candidateID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let previousStates = session.candidates.reduce(into: [String: DiscoveryCandidateState]()) { $0[$1.id] = $1.state }
            let prepared = (ranked.recommended + ranked.other).map { candidate -> DiscoveryCandidate in
                var updated = candidate
                updated.state = previousStates[candidate.id] ?? .notTried
                if let explanation = evaluationByID[candidate.id] {
                    updated.recommendationReason = explanation.reason
                    updated.suitableWhen = explanation.suitableWhen
                    updated.examplePrompt = explanation.examplePrompt
                    updated.experienceSteps = explanation.experienceSteps
                    updated.limitations = explanation.limitations
                    updated.usageGuide = explanation.usageGuide
                }
                return updated
            }
            session.candidates = prepared
            if session.selectedCandidateID == nil || !prepared.contains(where: { $0.id == session.selectedCandidateID }) {
                session.selectedCandidateID = ranked.recommended.first?.id
            }
            Self.updateDiscoveryRun(
                in: &session,
                id: runID,
                state: fallbackReason == nil ? .completed : .partiallyCompleted,
                queries: plan.queries,
                diagnostics: diagnostics,
                fallbackReason: fallbackReason,
                recommendedCandidateIDs: ranked.recommended.map(\.id),
                otherCandidateIDs: ranked.other.map(\.id),
                usedAI: evaluation != nil
            )
            let acceptedCandidateIDs = Set(prepared.map(\.id))
            let recommendedResponseIDs = Set(
                evaluation?.recommendations.filter { $0.tier == .recommended }.map(\.candidateID) ?? []
            )
            let canUseAIReply = evaluation != nil
                && recommendedResponseIDs.isSubset(of: acceptedCandidateIDs)
            if canUseAIReply {
                session.messages.append(.init(
                    role: .assistant,
                    text: evaluation!.reply,
                    providerID: configurationUsed?.id,
                    model: configurationUsed?.model
                ))
            } else if let fallbackReason {
                session.notices.append(.init(runID: runID, text: fallbackReason, kind: .partialResult))
            }
            session.updatedAt = Date()
            guard await saveDiscoveryResult(session) else { return }
            statusMessage = ranked.recommended.isEmpty ? "暂时没有足够可靠的推荐" : "已找到 \(ranked.recommended.count) 个值得先看的 Skill"
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
        retrievedCandidateCount: Int? = nil,
        evaluationCandidateCount: Int? = nil
    ) {
        guard let index = session.runs.firstIndex(where: { $0.id == id }) else { return }
        session.runs[index].state = state
        session.runs[index].queries = queries
        session.runs[index].diagnostics = diagnostics
        session.runs[index].fallbackReason = fallbackReason
        if let recommendedCandidateIDs { session.runs[index].recommendedCandidateIDs = recommendedCandidateIDs }
        if let otherCandidateIDs { session.runs[index].otherCandidateIDs = otherCandidateIDs }
        if let usedAI { session.runs[index].usedAI = usedAI }
        if let retrievedCandidateCount { session.runs[index].retrievedCandidateCount = retrievedCandidateCount }
        if let evaluationCandidateCount { session.runs[index].evaluationCandidateCount = evaluationCandidateCount }
    }

    private static func aiDiagnostic(from error: Error) -> AIInvocationDiagnostic? {
        guard case let AIServiceError.invocation(failure) = error else { return nil }
        return failure.diagnostic
    }

    private static func combinedNotice(_ first: String?, _ second: String) -> String {
        guard let first, !first.isEmpty else { return second }
        return "\(first) \(second)"
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
            cancelDiscoveryUsageGuide()
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
        cancelDiscoveryUsageGuide()
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
            usageGuide: candidate.usageGuide,
            usageGuideSourceDigest: candidate.usageGuideSourceDigest
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

    func scanInstalledSkills() async {
        isBusy = true
        statusMessage = "正在查看本机 Skills…"
        defer { isBusy = false }
        await refreshTargetStatuses()
        let targetRoots = snapshot.targets.map { URL(fileURLWithPath: $0.path) }
        let universal = ["~/.agents/skills", "~/.config/agents/skills"].map { PathSafety.resolveTildePath($0, homeDirectory: homeDirectory) }
        var seen = Set<String>()
        let roots = (targetRoots + universal).filter {
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted
        }
        let sourceNames = Dictionary(uniqueKeysWithValues: snapshot.targets.map { ($0.path, $0.displayName) })
        scanResult = await scanner.scan(roots: roots, sourceName: { root in
            sourceNames[root.path] ?? "其他通用位置"
        })
        statusMessage = "查看完成，没有改动任何文件"
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
        trackChanges: Bool,
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
                pendingLocalTrackingEnabled = trackChanges
                pendingLocalPackages = [:]
                let candidates = prepared.map { preparedPackage -> SkillCandidate in
                    var candidate = preparedPackage.package.candidate
                    if !trackChanges {
                        candidate.source.displayName = "电脑文件夹"
                    }
                    var stored = preparedPackage
                    stored.package.candidate = candidate
                    pendingLocalPackages[candidate.id] = stored
                    return candidate
                }
                activeConflict = nil
                updatingSkillID = nil
                pendingCandidates = candidates
                selectedCandidateIDs = Set(candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
                statusMessage = trackChanges ? "已准备持续跟踪的纯净 Skill" : "已准备一次性导入的纯净 Skill"
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
        guard !isBusy,
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
            let result = try await localPackageResolver.check(state: state)
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
        } catch { present(error) }
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
            errorMessage = GitHubSourceError.noStableRelease.localizedDescription
            statusMessage = "这个仓库还没有正式 Release"
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
        let result = try await updateCoordinator.updateCentralOnly(
            skillID: skill.id,
            candidate: package.candidate,
            store: store
        )
        let state = sourceState(
            skillID: skill.id,
            skillPath: package.recipe.skillPath,
            remote: version,
            recipe: package.recipe
        )
        if let transaction = result.transaction {
            try await store.recordGitHubSourceUpdate(state, transactionID: transaction.id)
        } else {
            try await store.updateSourceState(state)
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
                if pendingLocalTrackingEnabled,
                   let prepared = pendingLocalPackages[candidate.id]
                {
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
            pendingLocalTrackingEnabled = false
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
            let result = deployToExisting
                ? try await updateCoordinator.updateAndDeploy(
                    skillID: skillID,
                    candidate: candidate,
                    store: store,
                    authorizingHighRisk: authorizingHighRisk
                )
                : try await updateCoordinator.updateCentralOnly(
                    skillID: skillID,
                    candidate: candidate,
                    store: store,
                    authorizingHighRisk: authorizingHighRisk
                )
            if var localState = pendingLocalUpdateState,
               candidate.source.kind == .localFolder
            {
                localState.currentPackageFingerprint = result.record.fingerprint
                localState.topLevelFingerprints = localState.availableTopLevelFingerprints ??
                    pendingLocalPackages[candidate.id]?.package.topLevelFingerprints ??
                    localState.topLevelFingerprints
                localState.availablePackageFingerprint = nil
                localState.availableTopLevelFingerprints = nil
                localState.lastCheckedAt = Date()
                localState.status = .current
                if let transaction = result.transaction {
                    try await store.recordLocalSourceUpdate(localState, transactionID: transaction.id)
                } else {
                    try await store.updateLocalSourceState(localState)
                }
            } else if let remote = pendingGitHubVersion {
                let updatedSourceState = sourceState(
                    skillID: skillID,
                    skillPath: candidate.source.skillPath,
                    remote: remote,
                    recipe: pendingGitHubPackageRecipes[candidate.id]
                )
                if let transaction = result.transaction {
                    try await store.recordGitHubSourceUpdate(updatedSourceState, transactionID: transaction.id)
                } else {
                    try await store.updateSourceState(updatedSourceState)
                }
            }
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
            statusMessage = result.transaction.map { "已更新并安装到 \($0.backups.count) 个应用" } ?? "已更新「我的 Skills」中的原件"
            await reload()
            await scanInstalledSkills()
        } catch { present(error) }
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
        pendingLocalTrackingEnabled = false
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
            let planningRoot = libraryRoot
            let plan = try await Task.detached(priority: .userInitiated) {
                try DefaultSyncPlanner().makePlan(snapshot: proposedSnapshot, libraryRoot: planningRoot)
            }.value
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
            await reload()
            guard let action = syncPlan?.actions.first(where: {
                $0.skillID == proposal.skill.id && $0.targetID == proposal.target.id && $0.kind != .noChange
            }) else {
                statusMessage = proposal.desired ? "已保留当前安装" : "已取消这项安装"
                return true
            }
            guard action.kind != .blocked else {
                noticeMessage = action.summary
                return false
            }

            let result = try await executor.execute(plan: SyncPlan(actions: [action]), store: store)
            statusMessage = action.kind == .remove
                ? "已从 \(proposal.target.displayName) 卸载 \(proposal.skill.displayName)"
                : "已安装 \(proposal.skill.displayName) 到 \(proposal.target.displayName)"
            await reload()
            await scanInstalledSkills()
            return result.status == .succeeded
        } catch {
            present(error)
            return false
        }
    }

    func prepareInstallEverywhere(_ skill: SkillRecord) async -> Bool {
        let available = snapshot.targets.filter(isAvailableForInstallation)
        guard !available.isEmpty else {
            noticeMessage = "本机还没有找到可以安装 Skill 的应用。SkillBox 不会代为创建应用文件夹。"
            return false
        }
        var assignments = snapshot.assignments
        for target in available {
            setAssignment(skill: skill, target: target, desired: true, assignments: &assignments)
        }
        do {
            try await store.replaceAssignments(assignments)
            await reload()
            let shouldPreview = syncPlan?.actions.contains { $0.skillID == skill.id && $0.kind != .noChange } == true
            if !shouldPreview { noticeMessage = "这份 Skill 已经安装到所有可用应用。" }
            return shouldPreview
        } catch {
            present(error)
            return false
        }
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
        do {
            try await store.replaceAssignments(assignments)
            await reload()
            let shouldPreview = syncPlan?.actions.contains { $0.skillID == skill.id && $0.kind != .noChange } == true
            if !shouldPreview {
                pendingDeletionAfterSyncSkillID = nil
                noticeMessage = "这份 Skill 当前没有可卸载的受管理副本。"
            }
            return shouldPreview
        } catch {
            pendingDeletionAfterSyncSkillID = nil
            present(error)
            return false
        }
    }

    func cancelPendingDeletionAfterSync() {
        pendingDeletionAfterSyncSkillID = nil
    }

    var isDeletingSkillAfterSync: Bool {
        pendingDeletionAfterSyncSkillID != nil
    }

    func deleteSkill(_ skill: SkillRecord, preservingInstalledCopies: Bool = false) async -> Bool {
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
        guard let deletion = lastDeletedSkill else { return }
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

    func hasManagedInstallation(for skill: SkillRecord) -> Bool {
        snapshot.installations.contains { $0.skillID == skill.id }
    }

    func availableTargets() -> [AgentTarget] {
        snapshot.targets.filter(isAvailableForInstallation)
    }

    func unavailableTargets() -> [AgentTarget] {
        snapshot.targets.filter { !isAvailableForInstallation($0) }
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
        var assignments = snapshot.assignments
        guard let index = assignments.firstIndex(where: { $0.skillID == action.skillID && $0.targetID == action.targetID }) else { return }
        if replacement { assignments[index].allowReplacement = true }
        else { assignments[index].allowTakeover = true }
        assignments[index].authorizedDestinationFingerprint = action.expectedDestinationFingerprint
        do { try await store.replaceAssignments(assignments); await reload() } catch { present(error) }
    }

    func executePlan() async {
        guard let syncPlan else { return }
        let deletionSkillID = pendingDeletionAfterSyncSkillID
        isBusy = true
        defer {
            pendingDeletionAfterSyncSkillID = nil
            isBusy = false
        }
        do {
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

    func undo(_ transaction: SyncTransaction) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await executor.undo(transactionID: transaction.id, store: store)
            statusMessage = "已恢复到操作前"
            await reload()
            await scanInstalledSkills()
        } catch { present(error) }
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
            targets.append(.init(kind: .custom, displayName: trimmed, path: validatedURL.path, detectionStatus: .available, writeStatus: FileManager.default.isWritableFile(atPath: validatedURL.path) ? .writable : .readOnly, isCustom: true))
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

    func removeCustomTarget(_ target: AgentTarget) async {
        do {
            try await store.removeCustomTarget(id: target.id)
            statusMessage = "已移除 \(target.displayName) 的安装位置"
            await reload()
        } catch { present(error) }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func contentURL(for skill: SkillRecord) async -> URL { await store.contentURL(for: skill) }

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
        let url = await store.contentURL(for: skill)
        let material = await Task.detached(priority: .userInitiated) {
            SkillUsageGuideMaterialReader().read(
                from: url,
                name: skill.displayName,
                description: skill.description
            )
        }.value
        let fallback = await Task.detached(priority: .userInitiated) {
            SkillUsageGuideExtractor().extract(from: url)
        }.value

        let sourceState = snapshot.sourceStates.first { $0.skillID == skill.id }
        let canSendMaterial = AIContentSharingPolicy.canSend(
            sourceKind: skill.source.kind,
            repositoryIsPrivate: sourceState?.repositoryIsPrivate,
            allowPrivateSkillContent: aiSettings.isPrivateContentSharingAllowedForSelectedProvider
        )
        guard canSendMaterial,
              let configuration = aiSettings.selectedVerifiedConfiguration,
              configuredAIProviderIDs.contains(configuration.id),
              let key = try? await aiKeyStore.load(providerID: configuration.id),
              !key.isEmpty
        else { return fallback }

        do {
            let analyzed = try await aiProvider.analyzeSkillUsage(
                material: material,
                configuration: configuration,
                apiKey: key
            )
            try await usageGuideStore.save(
                analyzed.value,
                skillID: skill.id,
                fingerprint: skill.fingerprint,
                providerID: configuration.id,
                model: configuration.model
            )
            return analyzed.value
        } catch {
            return fallback
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
        do { syncPlan = try planner.makePlan(snapshot: snapshot, libraryRoot: libraryRoot) }
        catch { present(error) }
    }

    private func refreshTargetStatuses() async {
        let builtins = BuiltinAgentAdapters.all.map { $0.makeTarget(homeDirectory: homeDirectory, fileManager: .default) }
        let custom = snapshot.targets.filter(\.isCustom).map { target in
            var refreshed = target
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
            refreshed.detectionStatus = exists && FileManager.default.isReadableFile(atPath: target.path) ? .available : exists ? .unreadable : .directoryMissing
            refreshed.writeStatus = exists && FileManager.default.isWritableFile(atPath: target.path) ? .writable : exists ? .readOnly : .directoryMissing
            return refreshed
        }
        do {
            try await store.replaceTargets(builtins + custom)
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
            await reload()
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
        statusMessage = "操作未完成"
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
