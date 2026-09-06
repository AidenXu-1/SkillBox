import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Named object contract", .serialized)
struct DiscoveryNameContractTests {
    @Test("Named objects accept natural naming clauses and word separators", arguments: [
        ("有个human writing的skill。", "human writing"),
        ("有一个 custom widget 的 Skill", "custom widget"),
        ("名字叫 Agent Team 的 skill", "Agent Team"),
        ("有个Humanizer的skill。", "Humanizer"),
        ("有个Humanizer的 Skill。", "Humanizer"),
        ("有个human-writing的skill。", "human-writing"),
    ])
    func naturalNames(_ input: (String, String)) {
        let plan = DiscoveryIntentPlanner.fallback(message: input.0, previous: nil)
        #expect(plan.intent.route == .exact)
        #expect(plan.intent.targets == [.init(kind: .skillName, value: input.1)])
        #expect(plan.queries == [input.1])
    }

    @Test("432 name, prefix, suffix and spacing combinations preserve identity")
    func nameMatrix() {
        let prefixes = ["我找一下", "请帮忙查一查", "劳驾搜一下", "想了解", "麻烦定位", "请看看", "我要找", "能找到吗，", ""]
        let names = ["vibe-project-foundation-skill", "wechat-layout-publisher", "Agent-Team-Skill", "human-writing", "random-widget-name", "sample_utility_tool"]
        for prefix in prefixes { for name in names { for suffix in ["这个skill", "这份 Skill", "这款skill", " skill"] { for gap in ["", " "] {
            let input = prefix + gap + name + suffix
            let plan = DiscoveryIntentPlanner.fallback(message: input, previous: nil)
            #expect(plan.intent.route == .exact, "\(input)")
            #expect(plan.intent.targets.map(\.value) == [name], "\(input)")
            #expect(plan.queries == [name], "\(input)")
        }}}}
    }

    @Test("Ambiguous and excluded-only names request clarification without broad queries")
    func unclearNames() {
        for input in ["alpha-tools这个skill和beta-tools这个skill", "不要human-writing这个skill", "不要 human-writing Skill", "不要叫 human writing 的skill"] {
            let plan = DiscoveryIntentPlanner.fallback(message: input, previous: nil)
            #expect(plan.needsClarification, "\(input)")
            #expect(plan.queries.isEmpty)
        }
        let positive = DiscoveryIntentPlanner.fallback(message: "不要human-writing这个skill，找vibe-project-foundation-skill这个skill", previous: nil)
        #expect(positive.intent.targets.map(\.value) == ["vibe-project-foundation-skill"])
        #expect(!positive.needsClarification)
    }

    @Test("A sourced Chinese name identifies one repository and file without broadening capabilities")
    func chineseName() {
        let plan = DiscoveryIntentPlanner.fallback(message: "我要找一个小黑配图的skill。", previous: nil)
        #expect(plan.intent.route == .exact)
        #expect(plan.intent.targets == [.init(kind: .repository, value: "ian-xiaohei-illustrations", repositoryFullName: "helloianneo/ian-xiaohei-illustrations", skillPath: "ian-xiaohei-illustrations/SKILL.md", revision: "main")])
        #expect(plan.queries == ["repo:helloianneo/ian-xiaohei-illustrations"])
        for text in ["帮我找一个去文案AI味的skill", "帮我找一个做图文的小黑元素的Skill"] {
            #expect(DiscoveryIntentPlanner.fallback(message: text, previous: nil).intent.route == .scenario)
        }
        #expect(DiscoveryIntentPlanner.fallback(message: "不要小黑配图这个skill", previous: nil).needsClarification)
        #expect(DiscoveryIntentPlanner.fallback(message: "小黑配图这个skill和human-writing这个skill", previous: nil).needsClarification)
    }

    @Test("Explicit task changes leave name clarification and popularity keeps its route")
    func clarificationTaskChange() {
        let plan = DiscoveryIntentPlanner.fallback(message: "不要human-writing这个skill", previous: nil)
        var session = DiscoverySession(title: "clarification", storageFolderName: "clarification")
        session.intent = plan.intent
        session.pendingClarification = plan.clarifyingQuestion
        let changed = DiscoveryConversation.searchPlan(message: "换个任务，帮我找做幻灯片的 Skill", session: session)
        #expect(!changed.needsClarification)
        #expect(changed.intent.route == .scenario)
        #expect(!changed.queries.isEmpty)
        #expect(DiscoveryRequestRouter.classify(message: "human-writing这个skill热门吗", previousIntent: nil).route == .hybrid)
    }

    @Test("A missed routing decision cannot turn an explicit name into broad recommendations")
    func finalIdentityGate() {
        var unrelated = DiscoveryCandidate(id: "wrong", name: "claude-api", summary: "Build a project foundation.", repositoryFullName: "anthropics/skills", installCount: 10000)
        unrelated.evidence.skillContentVerified = true
        unrelated.evidence.skillSummary = unrelated.summary
        let ranked = DiscoveryCandidateRanker.rank([unrelated], intent: .init(goal: "我找一下vibe-project-foundation-skill这个skill"), originalQueryCandidateIDs: [unrelated.id])
        #expect(ranked.recommended.isEmpty)
        #expect(ranked.other.isEmpty)
    }

    @Test("Model reconciliation cannot expand a protected name")
    func reconciliationKeepsIdentity() {
        let original = DiscoveryIntentPlanner.fallback(message: "我找一下vibe-project-foundation-skill这个skill", previous: nil)
        let result = DiscoveryIntentPlanner.reconcile(modelPlan: .init(intent: .init(goal: "project tools"), queries: ["project", "foundation"]), deterministicPlan: original)
        #expect(result.intent.targets == original.intent.targets)
        #expect(result.queries == ["vibe-project-foundation-skill"])
    }
}
