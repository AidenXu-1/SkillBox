import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Agent discovery conversation", .serialized)
struct DiscoveryAgentConversationTests {
    @Test("Replies saved in the same second remain after the user's question")
    func equalTimestampOrder() {
        var session = Self.session()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        session.messages = [
            .init(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, role: .user, text: "这两个有什么区别？", createdAt: timestamp),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, role: .assistant, text: "作者说明…", createdAt: timestamp),
        ]
        let items = DiscoveryTimelineItem.items(for: session)
        #expect(items.first?.id == "message-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        #expect(items.last?.id == "message-00000000-0000-0000-0000-000000000000")
    }
    static func session() -> DiscoverySession {
        var result = DiscoverySession(title: "写作", storageFolderName: "conversation-test", intent: DiscoveryIntentPlanner.fallback(message: "帮我找卡兹克的写作 Skill", previous: nil).intent)
        result.messages = [.init(role: .user, text: result.intent!.goal)]
        result.candidates = ["khazix-writer", "human-writing"].map { name in
            var candidate = DiscoveryCandidate(id: name, name: name, summary: "中文写作", repositoryFullName: "KKKKhazix/" + name, installCount: 1_000)
            candidate.tier = .recommended
            candidate.evidence.skillContentVerified = true
            candidate.evidence.skillSummary = name == "human-writing" ? "通用中文创作与改稿" : "公众号长文写作"
            candidate.evidence.skillDocumentExcerpt = "# 写作\n先核对素材，再创作。"
            return candidate
        }
        result.selectedCandidateID = "human-writing"
        return result
    }

    @Test("Conversation actions resolve current references and do not turn questions into search")
    func actions() {
        let session = Self.session()
        #expect(DiscoveryConversation.action(for: "这两个有什么区别？", session: session) == .compare)
        #expect(DiscoveryConversation.action(for: "它支持中文吗？", session: session) == .explain)
        #expect(DiscoveryConversation.action(for: "帮我找视频 Skill？", session: session) == .search)
        #expect(DiscoveryConversation.action(for: "最好中文，不要收费", session: session) == .search)
        #expect(DiscoveryConversation.references(for: "它怎么用", action: .explain, session: session).map(\.name) == ["human-writing"])
        #expect(DiscoveryConversation.references(for: "比较这两个", action: .compare, session: session).count == 2)
        var noRecommendations = session
        noRecommendations.candidates = session.candidates.map { candidate in
            var value = candidate; value.tier = .other; return value
        }
        #expect(DiscoveryConversation.taskSummary(noRecommendations)?.contains("正在查看") == false)
    }

    @Test("A new search is not intercepted by comparison or constraint vocabulary")
    func newSearchWithConversationWords() {
        let session = Self.session()
        for message in [
            "帮我找去掉中文文案 AI 味的 Skill",
            "推荐去掉中文文案 AI 味的 Skill",
            "帮我找一个能对比两个 PDF 差异的 Skill",
            "compare-skills",
        ] {
            #expect(DiscoveryConversation.action(for: message, session: session) == .search, "Wrong action: \(message)")
        }
        #expect(DiscoveryConversation.action(for: "不要求免费了", session: session) == .removeConstraint("免费"))
        #expect(DiscoveryConversation.action(for: "这两个有什么区别？", session: session) == .compare)
    }

    @Test("References honor ordinal positions and never replace a missing named object")
    func preciseConversationReferences() {
        var session = Self.session()
        var third = session.candidates[0]
        third.id = "humanizer-zh"
        third.name = "humanizer-zh"
        third.repositoryFullName = "fixture/humanizer-zh"
        session.candidates.append(third)
        session.selectedCandidateID = third.id
        #expect(DiscoveryConversation.references(for: "第二个和第三个有什么区别？", action: .compare, session: session).map(\.name) == ["human-writing", "humanizer-zh"])
        #expect(DiscoveryConversation.references(for: "第2个和第3个有什么区别？", action: .compare, session: session).map(\.name) == ["human-writing", "humanizer-zh"])
        #expect(DiscoveryConversation.references(for: "第二个怎么用？", action: .explain, session: session).map(\.name) == ["human-writing"])
        #expect(DiscoveryConversation.references(for: "比较一下", action: .compare, session: session).isEmpty)
        #expect(DiscoveryConversation.references(for: "这两个有什么区别？", action: .compare, session: session).isEmpty)
        #expect(DiscoveryConversation.references(for: "第九个怎么用？", action: .explain, session: session).isEmpty)
        #expect(DiscoveryConversation.references(for: "unseen-skill 这个 Skill 怎么用？", action: .explain, session: session).isEmpty)
        #expect(DiscoveryConversation.references(for: "比较 human-writing 和 unseen-skill 这个 Skill", action: .compare, session: session).count < 2)
        #expect(DiscoveryConversation.references(for: "它怎么用？", action: .explain, session: session).map(\.name) == ["humanizer-zh"])
        var shorter = third
        shorter.name = "humanizer"
        shorter.id = "humanizer"
        session.candidates.append(shorter)
        #expect(DiscoveryConversation.references(for: "humanizer-zh 这个 Skill 怎么用？", action: .explain, session: session).map(\.name) == ["humanizer-zh"])
    }

    @Test("Same-name works require identity, while a repository selects its own author")
    func sameNameConversationReferences() {
        var session = Self.session()
        session.candidates[0].name = "humanizer"
        session.candidates[0].repositoryFullName = "aboudjem/humanizer-skill"
        session.candidates[1].name = "humanizer"
        session.candidates[1].repositoryFullName = "blader/humanizer"
        #expect(DiscoveryConversation.references(for: "humanizer怎么用", action: .explain, session: session).isEmpty)
        #expect(DiscoveryConversation.references(for: "blader/humanizer怎么用", action: .explain, session: session).map(\.repository) == ["blader/humanizer"])
        #expect(DiscoveryConversation.references(for: "第二个humanizer怎么用", action: .explain, session: session).map(\.repository) == ["blader/humanizer"])
        #expect(DiscoveryConversation.references(for: "它怎么用", action: .explain, session: session).map(\.id) == [session.selectedCandidateID!])
    }

    @Test("The application searches an explicit humanizing request instead of removing Chinese")
    @MainActor
    func applicationSearchWithRemovalWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        try await store.save(Self.session())
        let spy = ConversationSearchSpy()
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.discoveryDraft = "帮我找去掉中文文案 AI 味的 Skill"
        model.startDiscoverySearch()
        try await waitForReply(model)
        #expect(await spy.calls == 1)
        #expect(model.selectedDiscoverySession?.intent?.goal == "帮我找去掉中文文案 AI 味的 Skill")
    }

    @Test("No AI does not turn completed public coverage into an incomplete search", arguments: [0, 1])
    @MainActor
    func completedCoverageWithoutAI(failedSources: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = ConversationSearchSpy(failedSourceCount: failedSources)
        let model = makeModel(root: root, spy: spy)
        model.discoveryDraft = "推荐去文案AI味的skill。"
        model.startDiscoverySearch()
        try await waitForReply(model)
        let session = try #require(model.selectedDiscoverySession)
        let run = try #require(session.runs.last)
        let presentation = try #require(DiscoveryResultPresentation(session: session))
        #expect(!run.usedAI)
        #expect(run.state == (failedSources == 0 ? .completed : .partiallyCompleted))
        #expect(presentation.explanation.contains("公开来源尚未查完") == (failedSources > 0))
    }

    @Test("A clarification reply keeps the task and removed conditions do not return through context")
    func clarificationAndRemoval() {
        var session = Self.session()
        session.pendingClarification = "最后交付什么？"
        let plan = DiscoveryConversation.searchPlan(message: "公众号文章", session: session)
        #expect(plan.intent.goal == session.intent?.goal)
        #expect(plan.intent.preferences.contains("公众号文章"))
        #expect(plan.intent.targets == session.intent?.targets)
        session.intent?.mustHaves = ["必须中文", "必须免费"]
        session.intent = DiscoveryConversation.removeConstraint("免费", from: session.intent!)
        let removal = DiscoveryMessage(role: .user, text: "不要求免费了")
        session.messages.append(removal)
        session.contextStartMessageID = removal.id
        #expect(session.intent?.mustHaves == ["必须中文"])
        #expect(!DiscoveryPlanningContext(session: session, nextMessage: "继续寻找").text.contains("必须免费"))
        var noAuthor = Self.session()
        noAuthor.intent = DiscoveryConversation.removeConstraint("作者", from: noAuthor.intent!)
        let next = DiscoveryConversation.searchPlan(message: "继续寻找", session: noAuthor)
        #expect(!next.intent.targets.contains { $0.kind == .author })
        #expect(!next.queries.contains { $0.localizedCaseInsensitiveContains("khazix") })
        var combined = DiscoveryIntent(goal: "找写作 Skill", mustHaves: ["必须中文，不要收费"])
        combined = DiscoveryConversation.removeConstraint("免费", from: combined)
        #expect(combined.mustHaves == ["必须中文"])
    }

    @Test("New assistant evidence survives reload while unclassified legacy text is removed")
    func historyMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = Self.session()
        var answer = DiscoveryMessage(role: .assistant, text: "已核验的作者说明")
        answer.origin = "conversation-local-v1"
        answer.references = session.candidates.map(DiscoveryConversationReference.init)
        session.messages += [answer, .init(role: .assistant, text: "无法识别的旧回复")]
        try await store.save(session)
        let loaded = try #require(await store.loadAll().first)
        #expect(loaded.messages.contains { $0.id == answer.id })
        #expect(loaded.messages.first { $0.id == answer.id }?.references?.count == 2)
        #expect(!loaded.messages.contains { $0.text == "无法识别的旧回复" })
    }

    @Test("Pending inputs survive search saves, reload and atomic coalescing")
    func queuePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        let session = Self.session()
        try await store.save(session)
        try await store.enqueue("必须中文", sessionID: session.id, storageFolderName: session.storageFolderName)
        try await store.enqueue("不要收费", sessionID: session.id, storageFolderName: session.storageFolderName)
        _ = try await store.updateSearchSnapshot(session)
        #expect(await store.loadAll().first?.queuedMessages.count == 2)
        let message = try #require(try await store.claimQueued(sessionID: session.id, storageFolderName: session.storageFolderName))
        #expect(message.text == "必须中文\n不要收费")
        let loaded = try #require(await store.loadAll().first)
        #expect(loaded.queuedMessages.isEmpty)
        #expect(loaded.messages.contains { $0.id == message.id })
    }

    @Test("Application answers comparisons without invoking search and persists its response")
    @MainActor
    func applicationComparison() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        try await store.save(Self.session())
        let spy = ConversationSearchSpy()
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.discoveryDraft = "这两个有什么区别？"
        model.startDiscoverySearch()
        try await waitForReply(model)
        #expect(await spy.calls == 0)
        let session = try #require(model.selectedDiscoverySession)
        #expect(session.messages.last?.role == .assistant)
        #expect(session.messages.last?.references?.count == 2)
        #expect(session.recommendedCandidates.count == 2)
        await model.reloadDiscoverySessions()
        #expect(model.selectedDiscoverySession?.messages.last?.role == .assistant)
    }

    @Test("Stopping a running search retains queued input and never starts it automatically")
    @MainActor
    func cancellationKeepsQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        try await store.save(Self.session())
        let spy = ConversationSearchSpy(delay: .seconds(2))
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.discoveryDraft = "继续寻找"
        model.startDiscoverySearch()
        for _ in 0..<200 where await spy.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        model.discoveryDraft = "必须中文"
        model.startDiscoverySearch()
        for _ in 0..<200 where model.selectedDiscoverySession?.queuedMessages.isEmpty == true { try await Task.sleep(for: .milliseconds(10)) }
        model.cancelDiscoverySearch()
        for _ in 0..<200 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await spy.calls == 1)
        #expect(model.selectedDiscoverySession?.queuedMessages.map(\.text) == ["必须中文"])
        #expect(model.discoveryQueuePaused)
        let recovered = try #require(await store.loadAll().first)
        #expect(recovered.queuedMessages.count == 1)
    }

    @Test("Two pending refinements become one follow-up search")
    @MainActor
    func coalescesFollowUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        try await store.save(Self.session())
        let spy = ConversationSearchSpy(delay: .milliseconds(200))
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.discoveryDraft = "继续寻找"
        model.startDiscoverySearch()
        for _ in 0..<200 where await spy.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.discoveryDraft = "必须中文"
        model.startDiscoverySearch()
        model.discoveryDraft = "不要收费"
        model.startDiscoverySearch()
        for _ in 0..<400 {
            if await spy.calls >= 2, !model.isDiscoverySearching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await spy.calls == 2)
        #expect(model.selectedDiscoverySession?.queuedMessages.isEmpty == true)
        #expect(model.selectedDiscoverySession?.messages.filter { $0.text == "必须中文\n不要收费" }.count == 1)
    }

    @Test("Removing an author also invalidates the old deep-search query list")
    @MainActor
    func removedAuthorDoesNotReturnInDeepSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = Self.session()
        session.runs = [.init(queries: ["user:KKKKhazix", "khazix-writer"], route: .hybrid, state: .completed)]
        try await store.save(session)
        let spy = ConversationSearchSpy()
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.discoveryDraft = "不限制作者了"
        model.startDiscoverySearch()
        try await waitForReply(model)
        #expect(await spy.calls == 0)
        #expect(model.selectedDiscoverySession?.continuationInvalidated == true)
        model.discoveryDraft = "继续深挖更多来源"
        model.startDiscoverySearch()
        for _ in 0..<200 {
            if await spy.calls > 0, !model.isDiscoverySearching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await spy.calls == 1)
        #expect(await spy.allQueries.flatMap { $0 }.allSatisfy { !$0.localizedCaseInsensitiveContains("khazix") })
    }

    @Test("Switching conversations leaves pending input attached to its original task")
    @MainActor
    func switchDoesNotDrainOtherQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        let original = Self.session()
        let other = DiscoverySession(title: "视频", storageFolderName: "other-task", intent: .init(goal: "视频剪辑"))
        try await store.save(original)
        try await store.save(other)
        let spy = ConversationSearchSpy(delay: .milliseconds(200))
        let model = makeModel(root: root, spy: spy)
        await model.reloadDiscoverySessions()
        model.selectDiscoverySession(original.id)
        model.discoveryDraft = "继续寻找"
        model.startDiscoverySearch()
        for _ in 0..<200 where await spy.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.discoveryDraft = "必须中文"
        model.startDiscoverySearch()
        for _ in 0..<200 where model.selectedDiscoverySession?.queuedMessages.isEmpty == true { try await Task.sleep(for: .milliseconds(5)) }
        model.selectDiscoverySession(other.id)
        for _ in 0..<200 where model.isDiscoverySearching { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await spy.calls == 1)
        #expect(model.selectedDiscoverySessionID == other.id)
        #expect(model.selectedDiscoverySession?.messages.isEmpty == true)
        #expect(await store.loadAll().first { $0.id == original.id }?.queuedMessages.count == 1)
    }

    @MainActor
    private func makeModel(root: URL, spy: ConversationSearchSpy) -> AppModel {
        AppModel(libraryRoot: root, homeDirectory: root,
            routedDiscoveryProvider: RoutedSkillDiscoveryProvider(exactProvider: spy, scenarioProvider: spy, hybridProvider: spy),
            userDefaults: UserDefaults(suiteName: "SkillBoxConversationTests." + UUID().uuidString)!, startBootstrap: false)
    }

    @MainActor
    private func waitForReply(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.isDiscoverySearching, model.selectedDiscoverySession?.messages.last?.role == .assistant { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The application did not deliver a reply")
    }
}

private actor ConversationSearchSpy: SkillDiscoveryProvider {
    var calls = 0
    var allQueries: [[String]] = []
    let delay: Duration
    let failedSourceCount: Int
    init(delay: Duration = .zero, failedSourceCount: Int = 0) { self.delay = delay; self.failedSourceCount = failedSourceCount }
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        .init(candidates: try await search(queries: [query], limitPerQuery: limit).candidates)
    }
    func search(queries: [String], limitPerQuery: Int) async throws -> DiscoveryBatchSearchResult {
        calls += 1
        allQueries.append(queries)
        try await Task.sleep(for: delay)
        return .init(candidates: [], originalQueryCandidateIDs: [], failedSourceCount: failedSourceCount)
    }
}
