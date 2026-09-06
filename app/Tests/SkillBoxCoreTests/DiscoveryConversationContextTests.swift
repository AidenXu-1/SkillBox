import Testing
@testable import SkillBoxCore

@Suite("Discovery conversation context")
struct DiscoveryConversationContextTests {
    @Test("Names narrow the active author, while an explicit new search changes tasks")
    func namedFollowupScope() {
        let narrowed = DiscoveryIntentPlanner.fallback(message: "有个human writing的skill。", previous: authorIntent)
        #expect(narrowed.intent.goal == authorIntent.goal)
        #expect(narrowed.intent.route == .exact)
        #expect(narrowed.intent.targets.contains(.init(kind: .author, value: "卡兹克")))
        #expect(narrowed.intent.targets.contains(.init(kind: .skillName, value: "human writing")))
        #expect(narrowed.queries == ["human writing"])
        let changed = DiscoveryIntentPlanner.fallback(message: "帮我找 human-writing Skill", previous: authorIntent)
        #expect(changed.intent.goal != authorIntent.goal)
        #expect(!changed.intent.targets.contains { $0.kind == .author })
        let combined = DiscoveryIntentPlanner.fallback(message: "帮我找卡兹克的 human-writing Skill", previous: nil)
        #expect(combined.intent.targets.contains(.init(kind: .author, value: "卡兹克")))
        #expect(combined.intent.targets.contains(.init(kind: .skillName, value: "human-writing")))
    }

    @Test("Identity refinements retain new requirements and a different capability changes the goal")
    func identityRefinementRequirements() {
        for text in ["有个human writing的skill，而且必须离线", "我记得卡兹克有两个写作skill啊，而且必须离线"] {
            let plan = DiscoveryIntentPlanner.fallback(message: text, previous: authorIntent)
            #expect(plan.intent.goal == authorIntent.goal)
            #expect(plan.intent.mustHaves.contains("必须离线"))
        }
        let changed = DiscoveryIntentPlanner.fallback(message: "卡兹克的视频skill", previous: authorIntent)
        #expect(changed.intent.goal == "卡兹克的视频skill")
        #expect(changed.intent.targets.contains(.init(kind: .author, value: "卡兹克")))
    }

    private var authorIntent: DiscoveryIntent {
        DiscoveryIntentPlanner.fallback(message: "帮我找到卡兹克那个写作的Skill。", previous: nil).intent
    }

    @Test("A new task drops queries from the previous author task")
    func newTaskDoesNotInheritCreator() {
        let plan = DiscoveryIntentPlanner.fallback(message: "换成找视频剪辑的 Skill", previous: authorIntent)
        #expect(plan.intent.goal == "换成找视频剪辑的 Skill")
        #expect(plan.intent.targets.isEmpty)
        #expect(!plan.queries.contains { $0.localizedCaseInsensitiveContains("khazix") })
        #expect(plan.queries.contains("video editing workflow"))
    }

    @Test("A new explicit repository takes precedence over negative feedback")
    func newTargetInFeedback() {
        let text = "没找到 https://github.com/example/video-tools"
        let plan = DiscoveryIntentPlanner.fallback(message: text, previous: authorIntent)
        #expect(plan.intent.goal == text)
        #expect(plan.intent.route == .exact)
        #expect(plan.intent.targets.first?.repositoryFullName == "example/video-tools")
        #expect(plan.intent.preferences.isEmpty)
    }

    @Test("Refinement recovers author routing from a legacy scenario intent")
    func refinementRecoversLegacyAuthor() {
        let previous = DiscoveryIntent(goal: "帮我找到卡兹克那个写作的Skill。")
        let plan = DiscoveryIntentPlanner.fallback(message: "最好支持中文", previous: previous)
        #expect(plan.intent.goal == previous.goal)
        #expect(plan.intent.route == .hybrid)
        #expect(plan.intent.targets.contains { $0.kind == .author })
        #expect(plan.intent.preferences.contains("最好支持中文"))
    }

    @Test("Negative feedback and constraints keep an existing author task")
    func continuationPreservesAuthor() {
        let feedback = DiscoveryIntentPlanner.fallback(message: "找得太少，继续深挖", previous: authorIntent)
        #expect(feedback.intent.goal == authorIntent.goal)
        #expect(feedback.intent.targets == authorIntent.targets)
        let refinement = DiscoveryIntentPlanner.fallback(message: "必须支持中文", previous: feedback.intent)
        #expect(refinement.intent.goal == authorIntent.goal)
        #expect(refinement.intent.targets == authorIntent.targets)
        #expect(refinement.intent.mustHaves.contains("必须支持中文"))
        let deliverable = DiscoveryIntentPlanner.fallback(message: "写出活人感文案", previous: authorIntent)
        #expect(deliverable.intent.goal == authorIntent.goal)
        #expect(deliverable.intent.targets == authorIntent.targets)
    }

    @Test("Request context keeps only the active task and selected candidate")
    func boundedTaskContext() {
        var session = DiscoverySession(title: "test", storageFolderName: "test", intent: authorIntent)
        session.messages = [
            .init(role: .user, text: "旧任务是保密的邮件归档"),
            .init(role: .user, text: authorIntent.goal),
            .init(role: .user, text: "最好支持中文"),
        ]
        var candidate = DiscoveryCandidate(id: "human", name: "human-writing", summary: "中文改稿", repositoryFullName: "KKKKhazix/human-writing")
        candidate.evidence.skillContentVerified = true
        session.candidates = [candidate]
        session.selectedCandidateID = candidate.id
        let context = DiscoveryPlanningContext(session: session, nextMessage: "还要能改稿")
        #expect(context.text.contains("最好支持中文"))
        #expect(context.text.contains("当前选中: human-writing"))
        #expect(!context.text.contains("邮件归档"))
        #expect(DiscoveryPlanningContext(session: session, nextMessage: "换成找视频剪辑的 Skill").text.isEmpty)
        session.messages += (0..<20).map { _ in .init(role: .user, text: String(repeating: "很长的需求", count: 2_000)) }
        let bounded = DiscoveryPlanningContext(session: session, nextMessage: "继续深挖")
        #expect(bounded.text.count <= DiscoveryPlanningContext.maximumCharacters)
        #expect(bounded.text.contains("human-writing"))
    }
}
