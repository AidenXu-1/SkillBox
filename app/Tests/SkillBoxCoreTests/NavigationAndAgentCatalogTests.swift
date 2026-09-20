import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@Suite("Confirmed v28 navigation and Agent catalog")
struct NavigationAndAgentCatalogTests {
    @Test("The sidebar contains only the four confirmed user goals in order")
    func sidebarOrderMatchesTheConfirmedDesign() {
        #expect(SidebarItem.allCases == [.library, .agents, .discover, .settings])
        #expect(SidebarItem.allCases.map(\.rawValue) == [
            "我的 Skills",
            "安装到应用",
            "发现 Skills",
            "设置",
        ])
    }

    @Test("没有推荐结果时不会在空列表旁展示隐藏候选详情")
    @MainActor
    func discoverySelectionOnlyTargetsVisibleRecommendations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxDiscoverySelectionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let discoveryStore = try DiscoverySessionStore(root: root)
        var session = await discoveryStore.makeSession(title: "去文案 AI 味")
        let hiddenCandidate = DiscoveryCandidate(
            id: "github/awesome/finnish-humanizer",
            name: "finnish-humanizer",
            summary: "Only rewrites Finnish text.",
            repositoryFullName: "github/awesome-copilot",
            tier: .other,
            evidence: .init(skillSummary: "Only rewrites Finnish text.", skillContentVerified: true)
        )
        session.candidates = [hiddenCandidate]
        session.selectedCandidateID = hiddenCandidate.id
        try await discoveryStore.save(session)
        let suiteName = "SkillBoxDiscoverySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            libraryRoot: root,
            store: store,
            homeDirectory: root,
            userDefaults: defaults,
            startBootstrap: false
        )

        await model.reloadDiscoverySessions()

        #expect(model.selectedDiscoverySession?.recommendedCandidates.isEmpty == true)
        #expect(model.selectedDiscoveryCandidateID == nil)
        #expect(model.selectedDiscoveryCandidate == nil)
    }

    @Test("没有推荐或搜索未完成不会显示为绿色成功")
    func incompleteDiscoveryUsesAttentionStatus() {
        #expect(StatusToastTone.forMessage("暂时没有足够可靠的推荐") == .attention)
        #expect(StatusToastTone.forMessage("本次寻找未完成，可以重试") == .attention)
        #expect(StatusToastTone.forMessage("已找到 2 个值得先看的 Skill") == .success)
    }

    @Test("完整应用流程会把已核验的去 AI 味 Skill 交付到最终候选区")
    @MainActor
    func discoveryPublicFlowDeliversFinalHumanizerCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxDiscoveryPublicFlowTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FinalHumanizerDiscoveryProvider()
        let routedProvider = RoutedSkillDiscoveryProvider(
            exactProvider: provider,
            scenarioProvider: provider,
            hybridProvider: provider
        )
        let suiteName = "SkillBoxDiscoveryPublicFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            libraryRoot: root,
            homeDirectory: root,
            routedDiscoveryProvider: routedProvider,
            userDefaults: defaults,
            startBootstrap: false
        )

        model.discoveryDraft = "我需要找去文案AI 味的skill"
        model.startDiscoverySearch()
        for _ in 0..<200 where !model.discoveryDraft.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<200 where model.isDiscoverySearching {
            try await Task.sleep(for: .milliseconds(10))
        }

        let session = try #require(model.selectedDiscoverySession)
        #expect(session.recommendedCandidates.map(\.name) == ["story-deslop"])
        #expect(model.selectedDiscoveryCandidate?.name == "story-deslop")
        #expect(model.statusMessage == "已找到 1 个值得先看的 Skill")
    }

    @Test("模型需求理解卡住时应按时回退并交付公开来源结果")
    @MainActor
    func discoveryPlanningDeadlineStillDeliversFinalCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxDiscoveryPlanningDeadlineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FinalHumanizerDiscoveryProvider()
        let routedProvider = RoutedSkillDiscoveryProvider(
            exactProvider: provider,
            scenarioProvider: provider,
            hybridProvider: provider
        )
        let keyStore = DiscoveryDeadlineAIKeyStore()
        await keyStore.save("secret", providerID: "agnes")
        let suiteName = "SkillBoxDiscoveryPlanningDeadlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            libraryRoot: root,
            homeDirectory: root,
            aiKeyStore: keyStore,
            aiProvider: CancellationIgnoringPlanningAIProvider(),
            routedDiscoveryProvider: routedProvider,
            discoveryAIRequestTimeout: .milliseconds(40),
            userDefaults: defaults,
            startBootstrap: false
        )
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "agnes"
        settings.markConnectionVerified(providerID: "agnes")
        model.aiSettings = settings
        model.configuredAIProviderIDs.insert("agnes")

        let clock = ContinuousClock()
        let startedAt = clock.now
        model.discoveryDraft = "我需要找去文案AI 味的skill"
        model.startDiscoverySearch()
        for _ in 0..<200 where !model.discoveryDraft.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<200 where model.isDiscoverySearching {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = startedAt.duration(to: clock.now)

        let session = try #require(model.selectedDiscoverySession)
        #expect(elapsed < .milliseconds(500))
        #expect(session.recommendedCandidates.map(\.name) == ["story-deslop"])
        #expect(model.selectedDiscoveryCandidate?.name == "story-deslop")
        #expect(session.runs.last?.fallbackReason?.contains("需求整理") == true)
        #expect(model.statusMessage == "已找到 1 个值得先看的 Skill")
    }

    @Test("New users receive the ten approved built-in Agent products")
    func defaultAgentCatalogMatchesTheConfirmedDesign() {
        #expect(BuiltinAgentAdapters.defaultAdapters.map(\.displayName) == [
            "GPT",
            "Claude",
            "WorkBuddy",
            "ZCode",
            "Kimi Code",
            "Cursor",
            "HanaAgent",
            "Pi",
            "DeepSeek Harness",
            "Trae",
        ])
        #expect(BuiltinAgentAdapters.defaultAdapters.map(\.defaultGlobalPath) == [
            "~/.codex/skills",
            "~/.claude/skills",
            "~/.workbuddy/skills",
            "~/.zcode/skills",
            "~/.kimi-code/skills",
            "~/.cursor/skills",
            "~/.hanako/skills",
            "~/.pi/agent/skills",
            "~/.dsh/skills",
            "~/.trae-cn/skills",
        ])
        #expect(BuiltinAgentAdapters.defaultAdapters.allSatisfy { $0.indirectVisibility == nil })
        #expect(BuiltinAgentAdapters.defaultAdapters.allSatisfy {
            AgentIconCatalog.resourceFilename(for: $0.kind) != nil
        })
    }

    @Test("Legacy Gemini and OpenCode targets remain compatible without joining new defaults")
    func legacyTargetsRemainAvailableForMigration() {
        #expect(BuiltinAgentAdapters.legacyAdapters.map(\.displayName) == ["Gemini CLI", "OpenCode"])
        #expect(BuiltinAgentAdapters.all.count == 12)
    }

    @MainActor
    @Test("Scanning only reads each configured Agent's own Skill directory")
    func scanDoesNotTreatSharedAgentFoldersAsInstallLocations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxTargetScanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedSkill = root.appendingPathComponent(".agents/skills/shared-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedSkill, withIntermediateDirectories: true)
        try "---\nname: shared-demo\ndescription: Should stay invisible\n---\n".write(
            to: sharedSkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let storeRoot = root.appendingPathComponent("Store", isDirectory: true)
        let model = AppModel(
            libraryRoot: storeRoot,
            homeDirectory: root,
            startBootstrap: false
        )

        await model.scanInstalledSkills()

        #expect(model.scanResult?.candidates.isEmpty == true)
        #expect(model.scanResult?.candidates.contains { $0.canonicalName == "shared-demo" } == false)
    }

    @Test("DeepSeek Harness resolves its real DSH home when configured")
    func deepSeekHarnessResolvesDSHHome() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBox-DSH-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("skills"),
            withIntermediateDirectories: true
        )
        let adapter = BuiltinAgentAdapters.defaultAdapters.first { $0.kind == .deepSeekHarness }!

        let target = adapter.makeTarget(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default,
            environment: ["DSH_HOME": root.path]
        )

        #expect(target.path == root.appendingPathComponent("skills").standardizedFileURL.path)
    }

    @Test("DeepSeek prepares only a missing skills child of an existing home", arguments: ["default", "configured", "missing", "occupied"])
    func deepSeekPreparesSkillsDirectory(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(scenario == "configured" ? "custom" : ".dsh")
        if scenario != "missing" { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        let skills = home.appendingPathComponent("skills")
        if scenario == "occupied" { try "keep".write(to: skills, atomically: true, encoding: .utf8) }
        let targets = BuiltinAgentAdapters.reconciledTargets(persisted: [], homeDirectory: root,
            environment: scenario == "configured" ? ["DSH_HOME": home.path] : [:])
        let target = try #require(targets.first { $0.kind == .deepSeekHarness })
        #expect(target.path == skills.path)
        if scenario == "default" || scenario == "configured" {
            #expect(target.detectionStatus == .available)
            #expect(target.writeStatus == .writable)
            #expect(try FileManager.default.contentsOfDirectory(atPath: skills.path).isEmpty)
        } else {
            #expect(target.detectionStatus == .directoryMissing)
            if scenario == "missing" { #expect(!FileManager.default.fileExists(atPath: home.path)) }
            else { #expect(try String(contentsOf: skills, encoding: .utf8) == "keep") }
        }
    }

    @Test("Old target records decode as visible without losing compatibility")
    func legacyTargetJSONDefaultsToVisible() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "kind": "codex",
          "displayName": "Codex",
          "path": "/tmp/.codex/skills",
          "detectionStatus": "available",
          "writeStatus": "writable",
          "isCustom": false
        }
        """

        let target = try JSONDecoder().decode(AgentTarget.self, from: Data(json.utf8))

        #expect(target.isVisible)
        #expect(target.sortIndex == Int.max)
    }

    @Test("恢复默认顺序不会恢复被移除的应用，也不会丢掉自定义应用")
    func restoringDefaultOrderPreservesVisibilityAndCustomTargets() {
        var gpt = BuiltinAgentAdapters.defaultAdapters[0].makeTarget(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        var claude = BuiltinAgentAdapters.defaultAdapters[1].makeTarget(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        var cursor = BuiltinAgentAdapters.defaultAdapters[5].makeTarget(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        var custom = AgentTarget(
            kind: .custom,
            displayName: "My Agent",
            path: "/tmp/my-agent/skills",
            detectionStatus: .available,
            writeStatus: .writable,
            isCustom: true
        )
        gpt.sortIndex = 3
        claude.sortIndex = 2
        claude.isVisible = false
        cursor.sortIndex = 0
        custom.sortIndex = 1

        let restored = BuiltinAgentAdapters.restoringDefaultOrder(in: [cursor, custom, claude, gpt])

        #expect(restored.map(\.id) == [gpt.id, claude.id, cursor.id, custom.id])
        #expect(restored.first { $0.id == claude.id }?.isVisible == false)
        #expect(restored.last?.displayName == "My Agent")
        #expect(restored.map(\.sortIndex) == [0, 1, 2, 3])
    }

    @Test("Agent 列拖动时实时预览最终顺序，放手只提交一次")
    func agentColumnDragPreviewsAndCommitsOneOrder() throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: CGFloat(index) * 112, y: 0, width: 100, height: 70))
        })
        var session = AgentColumnDragSession()

        session.begin(
            targetID: ids[1],
            orderedTargetIDs: ids,
            frame: try #require(frames[ids[1]]),
            pointerX: 162
        )
        let changed = session.update(pointerX: 390, frames: frames)

        #expect(changed)
        #expect(session.previewOrder == [ids[0], ids[2], ids[3], ids[1]])
        #expect(session.isActive)
        #expect(session.ghostCenterX == 390)
        #expect(session.finish(commit: true) == [ids[0], ids[2], ids[3], ids[1]])
        #expect(!session.isActive)
    }

    @Test("拖出表格或按 Esc 取消时恢复原顺序")
    func agentColumnDragCancellationNeverCommitsPreview() throws {
        let ids = [UUID(), UUID(), UUID()]
        let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: CGFloat(index) * 112, y: 0, width: 100, height: 70))
        })
        var session = AgentColumnDragSession()
        session.begin(
            targetID: ids[0],
            orderedTargetIDs: ids,
            frame: try #require(frames[ids[0]]),
            pointerX: 40
        )
        _ = session.update(pointerX: 280, frames: frames)

        #expect(session.finish(commit: false) == nil)
        #expect(session.previewOrder.isEmpty)
        #expect(!session.isActive)
    }

    @Test("我的 Skills 右侧使用最新的信息层级")
    func skillDetailLayoutMatchesTheApprovedV28Hierarchy() {
        #expect(SkillDetailLayout.metaTitles == ["来源", "当前安装版本", "版本情况"])
        #expect(SkillDetailLayout.tabTitles == ["Skill 介绍", "文件详情"])
        #expect(SkillDetailLayout.guideTitles == ["作用", "适用场景", "使用流程", "启动提示词"])
        #expect(SkillDetailLayout.aiGuideLabel == "AI 介绍")
        #expect(SkillDetailLayout.connectAIButtonTitle == "连接 AI")
        #expect(SkillDetailLayout.tabMinimumHitHeight >= 44)
        #expect(SidebarLayout.rowMinimumHitHeight >= 44)
    }

    @Test("设置页包含关于与原有任务目录和完整点击热区")
    func settingsLayoutMatchesTheApprovedV31Hierarchy() {
        #expect(SettingsLayout.pageTitles == [
            "AI 服务",
            "GitHub",
            "存储与记录",
            "操作记录与恢复",
            "隐私与安全",
            "关于",
        ])
        #expect(SettingsLayout.aiServiceSymbol == "brain.head.profile")
        #expect(SettingsLayout.githubUsesOfficialMark)
        #expect(SettingsLayout.rowMinimumHitHeight >= 44)
        #expect(SettingsLayout.navigationWidth >= 240)
        #expect(SettingsLayout.contentMaxWidth >= 760)
    }
}

private struct FinalHumanizerDiscoveryProvider: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        let batch = try await search(queries: [query], limitPerQuery: limit)
        return .init(candidates: batch.candidates, fetchedAt: batch.fetchedAt)
    }

    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        let candidate = DiscoveryCandidate(
            id: "skills-sh/zenstory-ai/oh-story-claudecode/story-deslop",
            name: "story-deslop",
            summary: "网文去AI味。检测并清除文本中的AI写作痕迹。",
            repositoryFullName: "zenstory-ai/oh-story-claudecode",
            skillPath: "skills/story-deslop",
            installCount: 13_421,
            evidence: .init(
                skillSummary: "网文去AI味。检测并清除文本中的AI写作痕迹。",
                skillDocumentExcerpt: "---\nname: story-deslop\ndescription: 网文去AI味\n---",
                skillContentVerified: true
            )
        )
        return .init(
            candidates: [candidate],
            originalQueryCandidateIDs: [candidate.id]
        )
    }
}

private actor DiscoveryDeadlineAIKeyStore: AIKeyStore {
    private var values: [String: String] = [:]

    func load(providerID: String) -> String? { values[providerID] }
    func save(_ apiKey: String, providerID: String) { values[providerID] = apiKey }
    func delete(providerID: String) { values.removeValue(forKey: providerID) }
}

private struct CancellationIgnoringPlanningAIProvider: AIProvider {
    func testConnection(
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIConnectionTestResult {
        .init(
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
        await withCheckedContinuation { continuation in
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                continuation.resume()
            }
        }
        return .init(
            value: DiscoveryIntentPlanner.fallback(message: message, previous: previousIntent),
            diagnostics: []
        )
    }

    func evaluateCandidates(
        intent: DiscoveryIntent,
        candidates: [DiscoveryCandidate],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryEvaluation> {
        .init(value: .init(reply: "", recommendations: []), diagnostics: [])
    }

    func analyzeSkillUsage(
        material: SkillUsageGuideMaterial,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<SkillUsageGuide> {
        throw CancellationError()
    }
}
