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
    @Published var syncPlan: SyncPlan?
    @Published var isBusy = false
    @Published var statusMessage = "准备查看本机 Skills"
    @Published var errorMessage: String?
    @Published var showOnboarding = false
    @Published var githubURL = ""
    @Published var updatingSkillID: UUID?

    let libraryRoot: URL
    private let store: LibraryStore
    private let scanner = FileSystemSkillScanner()
    private let planner = DefaultSyncPlanner()
    private let executor = TransactionalSyncExecutor()
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

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
    }

    func reload() async {
        snapshot = await store.currentSnapshot()
        refreshPlan()
    }

    func scanInstalledSkills() async {
        isBusy = true
        statusMessage = "正在查看本机 Skills…"
        defer { isBusy = false }
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
        updatingSkillID = nil
        await preview(provider: GitHubSourceProvider(), locator: githubURL)
    }

    func checkForUpdate(_ skill: SkillRecord) async {
        guard skill.source.kind == .github else { return }
        updatingSkillID = skill.id
        let all = await loadPreview(provider: GitHubSourceProvider(), locator: skill.source.locator)
        guard let all else { return }
        let matching = all.filter { candidate in
            if let path = skill.source.skillPath { return candidate.source.skillPath == path }
            return candidate.canonicalName == skill.canonicalName
        }
        if matching.first?.fingerprint == skill.fingerprint {
            cleanupGitHubCandidates(all)
            updatingSkillID = nil
            statusMessage = "这份 Skill 已经是 GitHub 上的最新内容"
        } else {
            pendingCandidates = matching
            selectedCandidateIDs = Set(matching.filter { !$0.riskReport.isBlocked }.map(\.id))
        }
    }

    func importSelectedCandidates() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let selected = pendingCandidates.filter { selectedCandidateIDs.contains($0.id) }
            if let updatingSkillID, let candidate = selected.first {
                _ = try await store.updateSkill(id: updatingSkillID, with: candidate)
            } else {
                for candidate in selected { _ = try await store.importCandidate(candidate) }
            }
            cleanupGitHubCandidates(pendingCandidates)
            pendingCandidates = []
            selectedCandidateIDs = []
            updatingSkillID = nil
            statusMessage = "已加入「我的 Skills」"
            await reload()
        } catch { present(error) }
    }

    func cancelCandidatePreview() {
        cleanupGitHubCandidates(pendingCandidates)
        pendingCandidates = []
        selectedCandidateIDs = []
        updatingSkillID = nil
    }

    func toggleAssignment(skill: SkillRecord, target: AgentTarget) async {
        var assignments = snapshot.assignments
        if let index = assignments.firstIndex(where: { $0.skillID == skill.id && $0.targetID == target.id }) {
            let willEnable = !assignments[index].isDesired
            if willEnable {
                for otherIndex in assignments.indices where
                    assignments[otherIndex].targetID == target.id &&
                    assignments[otherIndex].installationDirectoryName.caseInsensitiveCompare(skill.canonicalName) == .orderedSame
                {
                    assignments[otherIndex].isDesired = false
                    assignments[otherIndex].allowTakeover = false
                    assignments[otherIndex].allowReplacement = false
                    assignments[otherIndex].authorizedDestinationFingerprint = nil
                }
            }
            assignments[index].isDesired = willEnable
            if !willEnable {
                assignments[index].allowTakeover = false
                assignments[index].allowReplacement = false
                assignments[index].authorizedDestinationFingerprint = nil
            }
        } else {
            for otherIndex in assignments.indices where
                assignments[otherIndex].targetID == target.id &&
                assignments[otherIndex].installationDirectoryName.caseInsensitiveCompare(skill.canonicalName) == .orderedSame
            {
                assignments[otherIndex].isDesired = false
                assignments[otherIndex].allowTakeover = false
                assignments[otherIndex].allowReplacement = false
                assignments[otherIndex].authorizedDestinationFingerprint = nil
            }
            assignments.append(.init(skillID: skill.id, targetID: target.id, installationDirectoryName: skill.canonicalName))
        }
        do { try await store.replaceAssignments(assignments); await reload() } catch { present(error) }
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
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "无法读取 SKILL.md"
    }

    private func preview(provider: any SourceProvider, locator: String) async {
        guard let candidates = await loadPreview(provider: provider, locator: locator) else { return }
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

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "操作未完成"
    }
}
