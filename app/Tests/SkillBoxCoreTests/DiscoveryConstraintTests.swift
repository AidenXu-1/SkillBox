import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Discovery mandatory conditions")
struct DiscoveryConstraintTests {
    static func candidate(_ description: String) -> DiscoveryCandidate {
        var value = DiscoveryCandidate(id: "writer", name: "writer", repositoryFullName: "example/writer", installCount: 2_000)
        value.evidence.skillContentVerified = true
        value.evidence.downloadable = true
        value.evidence.skillSummary = "Rewrite prose to remove AI writing patterns. " + description
        value.evidence.skillDocumentExcerpt = value.evidence.skillSummary
        return value
    }
    static func ranked(_ candidate: DiscoveryCandidate, conditions: [String]) -> DiscoveryRankedCandidates {
        DiscoveryCandidateRanker.rank([candidate], intent: .init(goal: "推荐去文案AI味的skill。", mustHaves: conditions), originalQueryCandidateIDs: [candidate.id])
    }

    @Test("Withdrawing a condition clears equivalent wording in the original goal", arguments: ["必须不联网", "必须离线运行", "must work offline"])
    func withdrawConditionFromGoal(condition: String) {
        let intent = DiscoveryIntentPlanner.fallback(message: "帮我找写作 Skill，" + condition + "，必须免费", previous: nil).intent
        let removed = DiscoveryConversation.removeConstraint("离线", from: intent)
        let candidate = Self.candidate("Requires an internet connection. Free to use.")
        #expect(DiscoveryConstraintAssessment(candidate: candidate, intent: removed).permitsRecommendation)
        #expect(removed.goal.contains("写作"))
        #expect(removed.goal.contains("必须免费"))
        #expect(!DiscoveryConstraintAssessment(candidate: Self.candidate("Requires a paid subscription."), intent: removed).permitsRecommendation)
        var session = DiscoverySession(title: "写作", storageFolderName: "withdrawn", intent: removed)
        session.messages = [.init(role: .user, text: intent.goal), .init(role: .user, text: "不要求离线了")]
        session.contextStartMessageID = session.messages.last?.id
        let continued = DiscoveryConversation.searchPlan(message: "继续寻找", session: session)
        #expect(DiscoveryConstraintAssessment(candidate: candidate, intent: continued.intent).permitsRecommendation)
        #expect(!DiscoveryPlanningContext(session: session, nextMessage: "继续寻找").text.contains(condition))
    }

    @Test("Required paid service does not satisfy a no-charge request")
    func paidConflict() {
        let value = Self.candidate("Requires a paid subscription; no free tier.")
        #expect(Self.ranked(value, conditions: ["不要收费"]).recommended.isEmpty)
    }

    @Test("Cloud-only rewriting does not satisfy offline and no-upload conditions")
    func cloudConflict() {
        let value = Self.candidate("Requires uploading the full text to an external cloud service. Does not work offline.")
        #expect(Self.ranked(value, conditions: ["必须离线运行", "禁止上传原文"]).recommended.isEmpty)
    }

    @Test("No price statement does not establish free use")
    func unknownCost() {
        #expect(Self.ranked(Self.candidate("Edits your draft."), conditions: ["必须免费"]).recommended.isEmpty)
    }

    @Test("Affirmative conditions retain eligible recommendations")
    func satisfiedConditions() {
        let value = Self.candidate("Works offline. No text leaves your device. Free to use; no subscription required.")
        #expect(Self.ranked(value, conditions: ["必须离线运行", "禁止上传原文", "必须免费"]).recommended.count == 1)
    }

    @Test("Hard requirements in the initial query are checked without a model")
    func initialQuery() {
        let value = Self.candidate("Requires a paid subscription; no free tier.")
        let plan = DiscoveryIntentPlanner.fallback(message: "推荐去文案AI味的skill，必须免费", previous: nil)
        #expect(DiscoveryCandidateRanker.rank([value], intent: plan.intent, originalQueryCandidateIDs: [value.id]).recommended.isEmpty)
    }

    @Test("Soft preferences and a normal rewriting request remain recommendations")
    func preferencesStaySoft() {
        let value = Self.candidate("Requires a paid subscription.")
        let intent = DiscoveryIntent(goal: "推荐去文案AI味的skill。", preferences: ["最好免费"])
        #expect(DiscoveryCandidateRanker.rank([value], intent: intent, originalQueryCandidateIDs: [value.id]).recommended.count == 1)
        #expect(Self.ranked(value, conditions: []).recommended.count == 1)
    }

    @Test("Exact identity lookup is independent of recommendation conditions")
    func exactLookupRemainsAvailable() {
        #expect(DiscoveryCandidateRanker.rankExact([Self.candidate("Requires a paid subscription.")]).recommended.count == 1)
    }

    @Test("Conflicting and unknown evidence remain distinguishable, including compound requirements")
    func reportsEvidenceBoundary() {
        let intent = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["必须免费且支持法语"])
        let unknown = DiscoveryConstraintAssessment(candidate: Self.candidate("Free to use."), intent: intent)
        #expect(unknown.conflicts.isEmpty)
        #expect(unknown.unverified == ["法语"])
        let conflict = DiscoveryConstraintAssessment(candidate: Self.candidate("Requires a paid subscription."), intent: intent)
        #expect(conflict.conflicts == ["免费使用"])
        #expect(!conflict.permitsRecommendation)
    }

    @Test("Contradictions override attractive words and missing evidence is excluded from model evaluation")
    func negativeEvidence() {
        let value = Self.candidate("Does not work fully offline. 完全依赖在线服务。")
        let intent = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["必须离线运行", "必须免费"])
        let assessment = DiscoveryConstraintAssessment(candidate: value, intent: intent)
        #expect(assessment.conflicts == ["离线运行"])
        #expect(assessment.unverified == ["免费使用"])
        #expect(DiscoveryCandidateRanker.candidatesForEvaluation([value], intent: intent, allowPrivateSkillContent: false).isEmpty)
    }

    @Test("Negated dependencies are affirmative protections, not conflicts")
    func protectedWording() {
        let value = Self.candidate("完全本地运行，不需要联网。免费使用，无需付费订阅。Do not upload the text to an external cloud service. No text leaves your device.")
        let intent = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["必须离线", "必须免费", "禁止上传"])
        #expect(DiscoveryConstraintAssessment(candidate: value, intent: intent).permitsRecommendation)
        let english = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["must not upload text"])
        #expect(DiscoveryConstraintAssessment(candidate: value, intent: english).permitsRecommendation)
    }

    @Test("All conjunctions retain additional conditions and negative language is not inverted")
    func conjunctionAndDirection() {
        for conjunction in ["和", "且", "以及", " and "] {
            let intent = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["必须免费" + conjunction + "支持法语"])
            #expect(!DiscoveryConstraintAssessment(candidate: Self.candidate("Free to use. English only."), intent: intent).permitsRecommendation)
        }
        let intent = DiscoveryIntent(goal: "去 AI 味", mustHaves: ["不要中文"])
        #expect(!DiscoveryConstraintAssessment(candidate: Self.candidate("Supports Chinese prose."), intent: intent).permitsRecommendation)
        #expect(DiscoveryConstraintAssessment(candidate: Self.candidate("不支持中文。"), intent: intent).permitsRecommendation)
    }

    @Test("No subscription alone does not prove free use")
    func subscriptionIsNotPrice() {
        #expect(Self.ranked(Self.candidate("No subscription required."), conditions: ["必须免费"]).recommended.isEmpty)
    }

    @Test("Model suggestions never create mandatory conditions, while explicit combined user requirements survive")
    func userSourceBoundary() {
        let value = Self.candidate("Requires a paid subscription.")
        let intent = DiscoveryIntent(goal: "去 AI 味", preferences: ["必须免费"])
        #expect(DiscoveryConstraintAssessment(candidate: value, intent: intent).permitsRecommendation)
        #expect(DiscoveryConstraintAssessment.hasMandatoryLanguage(in: "最好中文，但必须免费"))
        #expect(!DiscoveryConstraintAssessment(candidate: value, intent: .init(goal: "最好中文，但必须免费")).permitsRecommendation)
    }

    @Test("User-backed exclusion survives old-record grounding without reversing its direction")
    func persistedExclusion() {
        var session = DiscoverySession(title: "写作", storageFolderName: "test", intent: .init(goal: "找写作 Skill", exclusions: ["中文"]))
        session.messages = [.init(role: .user, text: "找写作 Skill"), .init(role: .user, text: "不要中文")]
        #expect(DiscoveryConversation.userGroundedIntent(in: session)?.exclusions == ["中文"])
        session.messages[1].text = "必须中文"
        #expect(DiscoveryConversation.userGroundedIntent(in: session)?.exclusions.isEmpty == true)
    }
}
