import AppKit
import Combine
import Foundation
import SkillBoxCore

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
    @Published var githubAuthorization: GitHubDeviceAuthorization?
    @Published var isGitHubConnected = false
    @Published var githubLoginStatus = ""

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

    var githubClientID: String { Bundle.main.object(forInfoDictionaryKey: "SkillBoxGitHubClientID") as? String ?? "" }
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
        await reload()
        await scanInstalledSkills()
        isGitHubConnected = await githubSession.isConnected()
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
        defer { isBusy = false }
        do {
            let result = try await githubProvider.preview(locator: githubURL, trackingMode: githubTrackingMode)
            pendingGitHubVersion = result.version
            pendingCandidates = result.candidates
            selectedCandidateIDs = Set(result.candidates.filter { !$0.riskReport.isBlocked }.map(\.id))
        } catch { present(error) }
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
        defer { isBusy = false }
        do {
            let remote = try await githubProvider.checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
            let result = try await githubProvider.downloadSnapshot(version: remote, skillPath: state.skillPath, locator: skill.source.locator)
            let matching = result.candidates.filter { candidate in
                if let path = state.skillPath { return candidate.source.skillPath == path }
                return candidate.canonicalName == skill.canonicalName
            }
            guard let candidate = matching.first else { throw GitHubSourceError.noSkillsFound }
            let current = await store.contentURL(for: skill)
            pendingUpdateChanges = try SkillDiffAnalyzer().compare(before: current, after: candidate.sourceURL)
            pendingGitHubVersion = remote
            activeConflict = nil
            updatingSkillID = skill.id
            pendingCandidates = [candidate]
            selectedCandidateIDs = candidate.riskReport.isBlocked ? [] : [candidate.id]
        } catch { present(error) }
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
                    let exact = try await githubProvider.checkRemoteVersion(
                        repositoryFullName: remote.repositoryFullName,
                        skillPath: candidate.source.skillPath,
                        trackingMode: remote.trackingMode
                    )
                    try await store.updateSourceState(sourceState(skillID: record.id, skillPath: candidate.source.skillPath, remote: exact))
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
            try await store.updateSourceState(sourceState(skillID: skillID, skillPath: candidate.source.skillPath, remote: remote))
            cleanupGitHubCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            pendingUpdateChanges = []
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

    func cancelCandidatePreview() {
        cleanupGitHubCandidates(pendingCandidates)
        pendingCandidates = []
        selectedCandidateIDs = []
        activeConflict = nil
        updatingSkillID = nil
        pendingGitHubVersion = nil
        pendingUpdateChanges = []
    }

    func beginGitHubLogin() async {
        do {
            let authorization = try await githubDeviceClient.beginAuthorization()
            githubAuthorization = authorization
            githubLoginStatus = "等待你在浏览器中确认…"
        } catch { present(error) }
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
        if let githubInstallURL { NSWorkspace.shared.open(githubInstallURL) }
        else { noticeMessage = "当前测试包还没有配置 GitHub App 安装地址" }
    }

    func disconnectGitHub() async {
        do {
            try await githubSession.disconnect()
            isGitHubConnected = false
            githubAuthorization = nil
            githubLoginStatus = ""
        } catch { present(error) }
    }

    func toggleAssignment(skill: SkillRecord, target: AgentTarget) async {
        var assignments = snapshot.assignments
        let existingDesired = assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true
        if !existingDesired, !isAvailableForInstallation(target) {
            noticeMessage = unavailableMessage(for: target)
            return
        }
        setAssignment(skill: skill, target: target, desired: !existingDesired, assignments: &assignments)
        do { try await store.replaceAssignments(assignments); await reload() } catch { present(error) }
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
            _ = try await store.deleteSkill(id: skill.id)
            statusMessage = "已从「我的 Skills」删除，原内容保存在「已删除」文件夹"
            await reload()
            return true
        } catch {
            present(error)
            return false
        }
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
        do {
            try PathSafety.validateCustomTarget(url, homeDirectory: homeDirectory, libraryRoot: libraryRoot)
            var targets = snapshot.targets
            targets.append(.init(kind: .custom, displayName: name, path: url.standardizedFileURL.path, detectionStatus: .available, writeStatus: FileManager.default.isWritableFile(atPath: url.path) ? .writable : .readOnly, isCustom: true))
            try await store.replaceTargets(targets)
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
                    githubLoginStatus = "已连接 GitHub"
                    githubAuthorization = nil
                    return
                case .expired:
                    githubLoginStatus = "验证码已过期，请重新连接"
                    return
                case .denied:
                    githubLoginStatus = "你取消了这次连接"
                    return
                }
            } catch {
                if !Task.isCancelled { present(error) }
                return
            }
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "操作未完成"
    }
}
