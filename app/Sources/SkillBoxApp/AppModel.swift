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
}

struct GitHubReleasePackageChoice: Identifiable {
    let id = UUID()
    let version: GitHubRemoteVersion
    let locator: String
    let skillPath: String?
    let purpose: GitHubReleasePackagePurpose
}

@MainActor
final class AppModel: ObservableObject {
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
    @Published var canRetryGitHubWithDefaultBranch = false
    @Published var pendingReleasePackageChoice: GitHubReleasePackageChoice?

    let libraryRoot: URL
    private let store: LibraryStore
    private let scanner = FileSystemSkillScanner()
    private let planner = DefaultSyncPlanner()
    private let executor = TransactionalSyncExecutor()
    private let updateCoordinator = SkillUpdateCoordinator()
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private lazy var githubDeviceClient = GitHubDeviceFlowClient(clientID: githubClientID)
    private lazy var githubSession = GitHubAuthenticatedSession(
        client: githubDeviceClient,
        credentialStore: KeychainGitHubCredentialStore()
    )
    private lazy var githubProvider = GitHubSourceProvider(tokenProvider: githubSession)
    private lazy var githubUpdateChecker = GitHubUpdateChecker(checker: githubProvider, store: store)
    private var githubLoginTask: Task<Void, Never>?
    private var remoteOperationTask: Task<Void, Never>?

    var githubClientID: String { Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubClientID") as? String ?? "" }
    var isGitHubConfigured: Bool { !githubClientID.isEmpty && githubInstallURL != nil }
    var githubInstallURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubInstallURL") as? String else { return nil }
        return URL(string: value)
    }

    init() {
        libraryRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SkillBox")
        do {
            store = try LibraryStore(root: libraryRoot)
        } catch {
            fatalError("无法准备 SkillBox 的本地保存位置：\(error.localizedDescription)")
        }
        showOnboarding = !UserDefaults.standard.bool(forKey: "SkillBoxOnboardingCompleted")
        Task { await bootstrap() }
    }

    func bootstrap() async {
        let recoveryWarnings = await store.recoveryWarnings
        if !recoveryWarnings.isEmpty {
            errorMessage = recoveryWarnings.joined(separator: "\n")
            statusMessage = "旧数据无法读取，原文件已保留"
        }
        let persisted = await store.currentSnapshot()
        let builtin = BuiltinAgentAdapters.all.map { $0.makeTarget(homeDirectory: homeDirectory, fileManager: .default) }
        let custom = persisted.targets.filter(\.isCustom)
        do { try await store.replaceTargets(builtin + custom) } catch { present(error) }
        do { try await store.refreshRiskReports(using: StaticRiskAnalyzer()) } catch { present(error) }
        await reload()
        await scanInstalledSkills()
        isGitHubConnected = await githubSession.isConnected()
        if isGitHubConnected { await refreshGitHubRepositories() }
        await checkAllGitHubUpdatesIfStale()
    }

    func reload() async {
        snapshot = await store.currentSnapshot()
        refreshPlan()
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
        await preview(provider: LocalFolderSourceProvider(), locator: url.path)
    }

    func previewGitHub() async {
        activeConflict = nil
        updatingSkillID = nil
        isBusy = true
        operationProgress = .init(title: "正在获取完整版本", detail: "连接 GitHub、下载文件并进行使用前检查…", canCancel: true)
        defer {
            isBusy = false
            operationProgress = nil
        }
        do {
            let remote = try await githubProvider.checkRemoteVersion(locator: githubURL, trackingMode: githubTrackingMode)
            let skillPath = try githubProvider.skillPath(in: githubURL)
            canRetryGitHubWithDefaultBranch = false
            if pauseForReleasePackageChoice(
                remote,
                locator: githubURL,
                skillPath: skillPath,
                purpose: .importSkill
            ) { return }
            try await prepareGitHubImport(remote: remote, locator: githubURL, skillPath: skillPath)
        } catch GitHubSourceError.noStableRelease {
            canRetryGitHubWithDefaultBranch = true
            errorMessage = GitHubSourceError.noStableRelease.localizedDescription
            statusMessage = "这个仓库还没有正式 Release"
        } catch {
            if isCancellation(error) { statusMessage = "已取消 GitHub 下载" }
            else { present(error) }
        }
    }

    func startGitHubPreview() {
        remoteOperationTask?.cancel()
        remoteOperationTask = Task { await previewGitHub() }
    }

    func retryGitHubUsingDefaultBranch() {
        canRetryGitHubWithDefaultBranch = false
        errorMessage = nil
        githubTrackingMode = .defaultBranch
        startGitHubPreview()
    }

    func checkForUpdate(_ skill: SkillRecord) async {
        guard skill.source.kind == .github else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let state = try await githubUpdateChecker.check(skillID: skill.id) else { return }
            await reload()
            switch state.status {
            case .updateAvailable: statusMessage = "发现新版本 \(state.availableVersionName ?? "")"
            case .releasePackageAvailable: statusMessage = "发现同一版本的纯净安装包"
            case .needsInitialCheck: statusMessage = "需要下载一次，才能确认当前内容是否最新"
            case .current: statusMessage = "这份 Skill 已经是最新内容"
            case .authenticationRequired: noticeMessage = "这个仓库需要重新连接 GitHub"
            default: break
            }
        } catch { present(error) }
    }

    func previewAvailableUpdate(_ skill: SkillRecord) async {
        guard let state = snapshot.sourceStates.first(where: { $0.skillID == skill.id }) else { return }
        isBusy = true
        operationProgress = .init(title: "正在准备更新", detail: "下载新版本并比较文件、说明和风险变化…", canCancel: true)
        defer {
            isBusy = false
            operationProgress = nil
        }
        do {
            let remote = try await githubProvider.checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
            if pauseForReleasePackageChoice(
                remote,
                locator: skill.source.locator,
                skillPath: state.skillPath,
                purpose: .updateSkill(skill.id)
            ) { return }
            try await prepareGitHubUpdate(remote: remote, skill: skill, skillPath: state.skillPath)
        } catch {
            if isCancellation(error) { statusMessage = "已取消更新检查" }
            else { present(error) }
        }
    }

    func startAvailableUpdatePreview(_ skill: SkillRecord) {
        remoteOperationTask?.cancel()
        remoteOperationTask = Task { await previewAvailableUpdate(skill) }
    }

    func cancelRemoteOperation() {
        remoteOperationTask?.cancel()
        remoteOperationTask = nil
        operationProgress = nil
        isBusy = false
        statusMessage = "已取消当前操作"
    }

    func continueReleasePackageChoice(assetID: Int64?) {
        guard let choice = pendingReleasePackageChoice else { return }
        pendingReleasePackageChoice = nil
        remoteOperationTask?.cancel()
        remoteOperationTask = Task { await downloadReleasePackageChoice(choice, assetID: assetID) }
    }

    func cancelReleasePackageChoice() {
        pendingReleasePackageChoice = nil
        statusMessage = "已取消 GitHub 下载"
    }

    private func pauseForReleasePackageChoice(
        _ remote: GitHubRemoteVersion,
        locator: String,
        skillPath: String?,
        purpose: GitHubReleasePackagePurpose
    ) -> Bool {
        guard remote.requiresReleaseAssetSelection || remote.usesSourceArchiveFallback else { return false }
        pendingReleasePackageChoice = .init(
            version: remote,
            locator: locator,
            skillPath: skillPath,
            purpose: purpose
        )
        statusMessage = remote.requiresReleaseAssetSelection ? "请选择要下载的 Release 安装包" : "这个 Release 没有独立安装包"
        return true
    }

    private func downloadReleasePackageChoice(_ choice: GitHubReleasePackageChoice, assetID: Int64?) async {
        isBusy = true
        operationProgress = .init(title: "正在获取完整版本", detail: "下载文件、校验完整性并进行使用前检查…", canCancel: true)
        defer {
            isBusy = false
            operationProgress = nil
        }
        do {
            let remote = try assetID.map { try choice.version.selectingReleaseAsset(id: $0) } ?? choice.version
            switch choice.purpose {
            case .importSkill:
                try await prepareGitHubImport(remote: remote, locator: choice.locator, skillPath: choice.skillPath)
            case let .updateSkill(skillID):
                guard let skill = snapshot.skills.first(where: { $0.id == skillID }) else { return }
                try await prepareGitHubUpdate(remote: remote, skill: skill, skillPath: choice.skillPath)
            }
        } catch {
            if isCancellation(error) { statusMessage = "已取消 GitHub 下载" }
            else { present(error) }
        }
    }

    private func prepareGitHubImport(
        remote: GitHubRemoteVersion,
        locator: String,
        skillPath: String?
    ) async throws {
        let result = try await githubProvider.downloadSnapshot(version: remote, skillPath: skillPath, locator: locator)
        pendingGitHubVersion = result.version
        pendingCandidates = result.candidates
        selectedCandidateIDs = Set(result.candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
    }

    private func prepareGitHubUpdate(
        remote: GitHubRemoteVersion,
        skill: SkillRecord,
        skillPath: String?
    ) async throws {
        let result = try await githubProvider.downloadSnapshot(
            version: remote,
            skillPath: skillPath,
            locator: skill.source.locator
        )
        let matching = result.candidates.filter { candidate in
            if remote.selectedReleaseAsset != nil { return candidate.canonicalName == skill.canonicalName }
            if let skillPath { return candidate.source.skillPath == skillPath }
            return candidate.canonicalName == skill.canonicalName
        }
        guard let candidate = matching.first else { throw GitHubSourceError.noSkillsFound }
        let current = await store.contentURL(for: skill)
        pendingUpdateChanges = try SkillDiffAnalyzer().compare(before: current, after: candidate.sourceURL)
        async let beforeMarkdown = readMarkdown(at: current.appendingPathComponent("SKILL.md"))
        async let afterMarkdown = readMarkdown(at: candidate.sourceURL.appendingPathComponent("SKILL.md"))
        pendingUpdateBeforeMarkdown = await beforeMarkdown
        pendingUpdateAfterMarkdown = await afterMarkdown
        pendingGitHubVersion = result.version
        activeConflict = nil
        updatingSkillID = skill.id
        pendingCandidates = [candidate]
        selectedCandidateIDs = candidate.riskReport.isBlocked ? [] : [candidate.id]
    }

    func importSelectedCandidates() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let selected = pendingCandidates.filter { selectedCandidateIDs.contains($0.id) }
            guard updatingSkillID == nil else { return }
            for candidate in selected {
                let record = try await store.importCandidate(candidate)
                if candidate.source.kind == .github, let remote = pendingGitHubVersion {
                    try await store.updateSourceState(sourceState(skillID: record.id, skillPath: candidate.source.skillPath, remote: remote))
                }
            }
            cleanupGitHubCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            activeConflict = nil
            updatingSkillID = nil
            pendingGitHubVersion = nil
            statusMessage = "已加入「我的 Skills」"
            await reload()
        } catch { present(error) }
    }

    func applyPendingUpdate(deployToExisting: Bool) async {
        guard let skillID = updatingSkillID,
              let candidate = pendingCandidates.first,
              selectedCandidateIDs.contains(candidate.id),
              let remote = pendingGitHubVersion
        else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = deployToExisting
                ? try await updateCoordinator.updateAndDeploy(skillID: skillID, candidate: candidate, store: store)
                : try await updateCoordinator.updateCentralOnly(skillID: skillID, candidate: candidate, store: store)
            let updatedSourceState = sourceState(skillID: skillID, skillPath: candidate.source.skillPath, remote: remote)
            if let transaction = result.transaction {
                try await store.recordGitHubSourceUpdate(updatedSourceState, transactionID: transaction.id)
            } else {
                try await store.updateSourceState(updatedSourceState)
            }
            cleanupGitHubCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            pendingUpdateChanges = []
            pendingUpdateBeforeMarkdown = ""
            pendingUpdateAfterMarkdown = ""
            pendingGitHubVersion = nil
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

    func checkAllGitHubUpdates() async {
        let states = snapshot.sourceStates.filter(\.checkingEnabled)
        guard !states.isEmpty else {
            noticeMessage = "目前没有正在检查更新的 GitHub Skill。"
            return
        }
        isBusy = true
        statusMessage = "正在检查 GitHub 更新…"
        defer { isBusy = false }
        var checkedStatuses: [GitHubSourceStatus] = []
        for state in states {
            do {
                if let status = try await githubUpdateChecker.check(skillID: state.skillID)?.status {
                    checkedStatuses.append(status)
                }
            } catch {
                checkedStatuses.append(.unavailable)
            }
        }
        await reload()
        statusMessage = GitHubUpdateSummary(statuses: checkedStatuses).statusMessage
    }

    func cancelCandidatePreview() {
        cleanupGitHubCandidates(pendingCandidates)
        pendingCandidates = []
        selectedCandidateIDs = []
        activeConflict = nil
        updatingSkillID = nil
        pendingGitHubVersion = nil
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
            isGitHubConnected = false
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
            isGitHubConnected = false
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
            if !githubAuthorizedRepositories.isEmpty {
                isWaitingForGitHubRepositorySelection = false
                githubLoginStatus = "连接完成，已找到 (githubAuthorizedRepositories.count) 个可读取的仓库。"
            }
        } catch GitHubSourceError.authenticationRequired {
            isGitHubConnected = false
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

    func prepareUninstallEverywhere(_ skill: SkillRecord) async -> Bool {
        var assignments = snapshot.assignments
        var changed = false
        for index in assignments.indices where assignments[index].skillID == skill.id && assignments[index].isDesired {
            assignments[index].isDesired = false
            clearAuthorization(&assignments[index])
            changed = true
        }
        let hasManagedCopies = snapshot.installations.contains { $0.skillID == skill.id }
        guard changed || hasManagedCopies else {
            noticeMessage = "这份 Skill 还没有通过 SkillBox 安装到任何应用。"
            return false
        }
        do {
            try await store.replaceAssignments(assignments)
            await reload()
            let shouldPreview = syncPlan?.actions.contains { $0.skillID == skill.id && $0.kind != .noChange } == true
            if !shouldPreview { noticeMessage = "这份 Skill 当前没有可卸载的受管理副本。" }
            return shouldPreview
        } catch {
            present(error)
            return false
        }
    }

    func deleteSkill(_ skill: SkillRecord) async -> Bool {
        do {
            lastDeletedSkill = try await store.deleteSkill(id: skill.id)
            statusMessage = "已删除 \(skill.displayName)，可以立即撤销"
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
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await executor.execute(plan: syncPlan, store: store)
            statusMessage = "安装完成：更新了 \(result.backups.count) 个位置"
            await reload()
            await scanInstalledSkills()
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
            try PathSafety.validateCustomTarget(url, homeDirectory: homeDirectory, libraryRoot: libraryRoot)
            guard !snapshot.targets.contains(where: { $0.path == url.standardizedFileURL.path }) else {
                noticeMessage = "这个文件夹已经添加过了。"
                return
            }
            var targets = snapshot.targets
            targets.append(.init(kind: .custom, displayName: trimmed, path: url.standardizedFileURL.path, detectionStatus: .available, writeStatus: FileManager.default.isWritableFile(atPath: url.path) ? .writable : .readOnly, isCustom: true))
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
            try PathSafety.validateCustomTarget(url, homeDirectory: homeDirectory, libraryRoot: libraryRoot)
            if target.path != url.standardizedFileURL.path,
               snapshot.installations.contains(where: { $0.targetID == target.id })
            {
                noticeMessage = "这个位置仍有 Skill 由 SkillBox 管理。请先卸载，再更换文件夹。"
                return
            }
            var targets = snapshot.targets
            guard let index = targets.firstIndex(where: { $0.id == target.id }) else { return }
            targets[index].displayName = trimmed
            targets[index].path = url.standardizedFileURL.path
            targets[index].detectionStatus = .available
            targets[index].writeStatus = FileManager.default.isWritableFile(atPath: url.path) ? .writable : .readOnly
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
        let url = await store.contentURL(for: skill)
        return await Task.detached(priority: .userInitiated) {
            SkillUsageGuideExtractor().extract(from: url)
        }.value
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
                if url.lastPathComponent.hasPrefix("SkillBoxGitHub-") { return url }
                url.deleteLastPathComponent()
            }
            return nil
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
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let eligible = snapshot.sourceStates.filter { $0.checkingEnabled && ($0.lastCheckedAt ?? .distantPast) < cutoff }
        for state in eligible { _ = try? await githubUpdateChecker.check(skillID: state.skillID) }
        if !eligible.isEmpty { await reload() }
    }

    private func readMarkdown(at url: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? "这个版本没有可预览的 SKILL.md"
        }.value
    }

    private func sourceState(skillID: UUID, skillPath: String?, remote: GitHubRemoteVersion) -> GitHubSourceState {
        .init(
            skillID: skillID,
            repositoryID: remote.repositoryID,
            repositoryFullName: remote.repositoryFullName,
            skillPath: skillPath,
            trackingMode: remote.trackingMode,
            defaultBranch: remote.defaultBranch,
            currentVersionIdentifier: remote.versionIdentifier,
            currentVersionName: remote.versionName,
            currentCommitSHA: remote.commitSHA,
            currentTreeSHA: remote.treeSHA,
            currentReleaseID: remote.releaseID,
            currentAssetID: remote.selectedReleaseAsset?.id,
            currentAssetName: remote.selectedReleaseAsset?.name,
            currentAssetDigest: remote.selectedReleaseAsset?.digest,
            lastCheckedAt: Date(),
            checkingEnabled: true,
            status: .current
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
                    isGitHubConnected = true
                    githubAuthorization = nil
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
                githubLoginStatus = "连接完成，已找到 (repositories.count) 个可读取的仓库。"
                return
            } catch is CancellationError {
                return
            } catch GitHubSourceError.authenticationRequired {
                isGitHubConnected = false
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

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
