import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill discovery", .serialized)
struct DiscoveryTests {
    @Test("Public search maps results without needing Node or an account")
    func publicSearchMapsCandidates() async throws {
        let provider = SkillsShDiscoveryProvider(
            session: DiscoveryFixture.session(),
            endpoint: URL(string: "https://skills.sh/api/search")!,
            fallbackEndpoint: nil
        )

        let result = try await provider.search(query: "build slides", limit: 6)

        #expect(DiscoveryMockURLProtocol.lastSearchURL?.query?.contains("q=build%20slides") == true)
        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].repositoryFullName == "openai/skills")
        #expect(result.candidates[0].skillPath == nil)
        #expect(result.candidates[0].installCount == 1250)
        #expect(result.candidates[0].repositoryStars == 9800)
        #expect(result.candidates[0].importURL?.absoluteString == "https://github.com/openai/skills")
        #expect(result.candidates[1].summary == "Repository-level description")
        #expect(result.candidates[1].summaryIsRepositoryLevel)
        #expect(result.candidates[1].repositoryStars == 321)

        _ = try await provider.search(query: "build slides", limit: 6)
        #expect(DiscoveryMockURLProtocol.repositoryRequestCount == 2)
    }

    @Test("Search records persist until the user deletes them")
    func searchRecordsPersistAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = await store.makeSession(title: "帮我做演示文稿", now: Date(timeIntervalSince1970: 100))
        session.messages = [
            .init(role: .user, text: "帮我做演示文稿", createdAt: Date(timeIntervalSince1970: 101)),
            .init(role: .assistant, text: "我会优先找用途明确、较多人使用的演示文稿 Skill。", createdAt: Date(timeIntervalSince1970: 102)),
        ]
        session.intent = .init(goal: "帮我做演示文稿")
        session.candidates = [
            .init(id: "openai/skills/skills/slides", name: "slides", repositoryFullName: "openai/skills", skillPath: "skills/slides"),
        ]

        try await store.save(session)
        let reloaded = await store.loadAll()

        #expect(reloaded.count == 1)
        #expect(reloaded[0].title == "帮我做演示文稿")
        #expect(reloaded[0].candidates.first?.name == "slides")
        #expect(reloaded[0].messages.count == 2)
        #expect(reloaded[0].messages.last?.role == .assistant)
        #expect(await store.storageSize() > 0)

        try await store.delete(session)
        #expect(await store.loadAll().isEmpty)
    }

    @Test("Old v1 records migrate without inventing assistant replies")
    func migratesV1RecordsWithoutFakeReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        let folder = root.appendingPathComponent("SearchSessions/old-search", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"session":{"id":"00000000-0000-0000-0000-000000000001","title":"去 AI 味","storageFolderName":"old-search","createdAt":"1970-01-01T00:01:40Z","updatedAt":"1970-01-01T00:01:40Z","turns":[{"id":"00000000-0000-0000-0000-000000000002","userText":"找一个去 AI 味的 Skill","effectiveQuery":"humanize text","createdAt":"1970-01-01T00:01:40Z"}],"candidates":[]}}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("session.json"))

        let sessions = await store.loadAll()

        #expect(sessions.count == 1)
        #expect(sessions[0].messages.map(\.role) == [.user])
        #expect(sessions[0].messages.first?.text == "找一个去 AI 味的 Skill")
        #expect(sessions[0].intent?.goal == "找一个去 AI 味的 Skill")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session-v1.json").path))
    }

    @Test("Early v3 records remove local failure copy from the AI conversation")
    func cleansLegacyFakeAssistantRepliesFromV3() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = await store.makeSession(title: "去 AI 味", now: Date(timeIntervalSince1970: 100))
        session.messages = [
            .init(role: .user, text: "帮我找一个去文案 AI 味的 Skill", createdAt: Date(timeIntervalSince1970: 101)),
            .init(
                role: .assistant,
                text: "AI 暂时不可用，已按公开资料筛选。我理解你要找的是去 AI 味。",
                createdAt: Date(timeIntervalSince1970: 102)
            ),
            .init(role: .assistant, text: "这是模型真正生成的回复。", createdAt: Date(timeIntervalSince1970: 103)),
        ]
        try await store.save(session)

        let loaded = try #require(await store.loadAll().first)

        #expect(loaded.messages.map(\.text) == ["帮我找一个去文案 AI 味的 Skill", "这是模型真正生成的回复。"])
        #expect(loaded.notices.contains { $0.text.contains("旧版本") })
    }

    @Test("Quality feedback changes preference and never becomes a query")
    func qualityFeedbackUpdatesIntent() {
        let previous = DiscoveryIntent(goal: "找一个去 AI 味的 Skill")

        let plan = DiscoveryIntentPlanner.fallback(message: "感觉质量不高", previous: previous)

        #expect(plan.intent.goal == previous.goal)
        #expect(plan.queries.first == previous.goal)
        #expect(!plan.queries.contains { $0.contains("质量不高") })
        #expect(plan.intent.preferences.contains { $0.contains("知名") || $0.contains("可靠") })
    }

    @Test("Natural complaints keep the original goal and expand search depth")
    func naturalQualityComplaintKeepsGoal() {
        let previous = DiscoveryIntent(goal: "帮我找一个去文案 AI 味的 Skill")

        let plan = DiscoveryIntentPlanner.fallback(
            message: "你找的太少了，而且一些优质的你都没找到",
            previous: previous
        )

        #expect(plan.intent.goal == previous.goal)
        #expect(plan.queries.first == previous.goal)
        #expect(!plan.queries.contains { $0.contains("太少") || $0.contains("没找到") })
        #expect(plan.intent.preferences.contains { $0.contains("深挖") || $0.contains("知名") })
    }

    @Test("A new task replaces the old search instead of concatenating it")
    func newGoalReplacesPreviousGoal() {
        let previous = DiscoveryIntent(goal: "找一个去 AI 味的 Skill")

        let plan = DiscoveryIntentPlanner.fallback(message: "帮我找专业的 Swift 开发 Skill", previous: previous)

        #expect(plan.intent.goal == "帮我找专业的 Swift 开发 Skill")
        #expect(plan.queries == ["帮我找专业的 Swift 开发 Skill"])
        #expect(!plan.queries[0].contains("去 AI 味"))
    }

    @Test("Verified popular relevant skills are recommended and weak results stay folded")
    func deterministicQualityTiers() {
        let strong = DiscoveryCandidate(
            id: "good/humanizer/humanizer-zh", name: "humanizer-zh", summary: "让中文文章更自然",
            repositoryFullName: "good/humanizer", installCount: 3_200, repositoryStars: 1_260,
            evidence: .init(skillSummary: "让中文文章更自然，减少模板化表达", skillContentVerified: true)
        )
        let weak = DiscoveryCandidate(
            id: "small/tool/humanizer", name: "humanizer", summary: "让文字更自然",
            repositoryFullName: "small/tool", installCount: 20, repositoryStars: 2,
            evidence: .init(skillSummary: "让文字更自然", skillContentVerified: true)
        )
        let unrelated = DiscoveryCandidate(
            id: "chat/dingtalk/dingtalk", name: "dingtalk", summary: "钉钉机器人",
            repositoryFullName: "chat/dingtalk", installCount: 9000, repositoryStars: 5000,
            evidence: .init(skillSummary: "管理钉钉文档和机器人", skillContentVerified: true)
        )

        let result = DiscoveryCandidateRanker.rank(
            [strong, weak, unrelated],
            intent: .init(goal: "找一个去 AI 味的中文写作 Skill"),
            originalQueryCandidateIDs: [strong.id, weak.id]
        )

        #expect(result.recommended.map(\.id) == [strong.id])
        #expect(result.other.map(\.id) == [weak.id])
        #expect(!result.recommended.contains { $0.id == unrelated.id })
        #expect(!result.other.contains { $0.id == unrelated.id })
    }

    @Test("AI relevance alone cannot promote a weakly proven candidate")
    func semanticMatchStillNeedsQualityEvidence() {
        let weak = DiscoveryCandidate(
            id: "unknown/writing/humanize-it", name: "humanize-it",
            summary: "把中文文案改写得更自然",
            repositoryFullName: "unknown/writing", installCount: 385, repositoryStars: 225,
            evidence: .init(
                skillSummary: "把中文文案改写得更自然，减少模板化表达",
                skillContentVerified: true
            )
        )

        let result = DiscoveryCandidateRanker.rank(
            [weak],
            intent: .init(goal: "找一个去文案 AI 味的中文写作 Skill"),
            originalQueryCandidateIDs: [weak.id],
            relevantCandidateIDs: [weak.id]
        )

        #expect(result.recommended.isEmpty)
        #expect(result.other.map(\.id) == [weak.id])
    }

    @Test("An AI-rejected candidate cannot return through deterministic fallback matching")
    func aiOtherTierCannotReturnThroughFallback() {
        let popular = DiscoveryCandidate(
            id: "popular/writing/detector", name: "detector",
            summary: "只检测文章中的 AI 特征",
            repositoryFullName: "popular/writing", installCount: 20_000, repositoryStars: 8_000,
            evidence: .init(skillSummary: "只检测文章中的 AI 特征", skillContentVerified: true)
        )

        let result = DiscoveryCandidateRanker.rank(
            [popular],
            intent: .init(goal: "帮我把文章改写得更自然"),
            originalQueryCandidateIDs: [popular.id],
            relevantCandidateIDs: [],
            evaluatedCandidateIDs: [popular.id]
        )

        #expect(result.recommended.isEmpty)
        #expect(result.other.isEmpty)
    }

    @Test("The AI budget does not hide verified candidates it did not review")
    func unevaluatedCandidatesKeepDeterministicFallback() {
        let reviewed = DiscoveryCandidate(
            id: "known/writing/reviewed", name: "reviewed",
            summary: "改写中文文章",
            repositoryFullName: "known/writing", repositoryStars: 900,
            evidence: .init(skillSummary: "改写中文文章", skillContentVerified: true)
        )
        let notReviewed = DiscoveryCandidate(
            id: "known/writing/not-reviewed", name: "not-reviewed",
            summary: "改写中文文章",
            repositoryFullName: "known/writing", repositoryStars: 800,
            evidence: .init(skillSummary: "改写中文文章", skillContentVerified: true)
        )

        let result = DiscoveryCandidateRanker.rank(
            [reviewed, notReviewed],
            intent: .init(goal: "改写中文文章"),
            originalQueryCandidateIDs: [reviewed.id, notReviewed.id],
            relevantCandidateIDs: [reviewed.id],
            evaluatedCandidateIDs: [reviewed.id]
        )

        #expect(result.recommended.map(\.id) == [reviewed.id, notReviewed.id])
    }

    @Test("AI omissions and supplemental-query candidates fall back without undoing explicit rejections")
    func semanticRoutingPreservesOnlyUnevaluatedFrontierCandidates() {
        let accepted = DiscoveryCandidate(
            id: "known/writing/accepted", name: "accepted", summary: "改写中文文章",
            repositoryFullName: "known/writing", repositoryStars: 900,
            evidence: .init(skillSummary: "改写中文文章", skillContentVerified: true)
        )
        let rejected = DiscoveryCandidate(
            id: "known/writing/rejected", name: "rejected", summary: "改写中文文章",
            repositoryFullName: "known/writing", repositoryStars: 850,
            evidence: .init(skillSummary: "改写中文文章", skillContentVerified: true)
        )
        let omitted = DiscoveryCandidate(
            id: "known/writing/omitted", name: "omitted", summary: "Natural writing rewrite",
            repositoryFullName: "known/writing", repositoryStars: 800,
            evidence: .init(skillSummary: "Natural writing rewrite", skillContentVerified: true)
        )
        let outsideBudget = DiscoveryCandidate(
            id: "known/writing/ninth", name: "ninth", summary: "Natural writing rewrite",
            repositoryFullName: "known/writing", repositoryStars: 750,
            evidence: .init(skillSummary: "Natural writing rewrite", skillContentVerified: true)
        )
        let evaluation = DiscoveryEvaluation(
            reply: "先看 accepted。",
            recommendations: [
                .init(candidateID: accepted.id, tier: .recommended, reason: "直接对应"),
                .init(candidateID: rejected.id, tier: .other, reason: "不够对应"),
            ]
        )
        let frontierIDs = Set([accepted.id, rejected.id, omitted.id, outsideBudget.id])

        let routing = DiscoveryCandidateRanker.semanticRouting(
            evaluation: evaluation,
            fallbackCandidateIDs: frontierIDs
        )
        let ranked = DiscoveryCandidateRanker.rank(
            [accepted, rejected, omitted, outsideBudget],
            intent: .init(goal: "改写中文文章"),
            originalQueryCandidateIDs: [],
            relevantCandidateIDs: routing.relevantCandidateIDs,
            evaluatedCandidateIDs: routing.evaluatedCandidateIDs
        )

        #expect(routing.evaluatedCandidateIDs == [accepted.id, rejected.id])
        #expect(ranked.recommended.map(\.id) == [accepted.id, omitted.id, outsideBudget.id])
        #expect(!ranked.recommended.contains { $0.id == rejected.id })
    }

    @Test("The ninth quality-frontier candidate survives the eight-item AI window")
    func ninthCandidateSurvivesAIEvaluationWindow() {
        let candidates = (0..<9).map { index in
            DiscoveryCandidate(
                id: "known/writing/item-\(index)",
                name: "item-\(index)",
                summary: "Natural writing rewrite",
                repositoryFullName: "known/writing",
                repositoryStars: 900 - index,
                evidence: .init(skillSummary: "Natural writing rewrite", skillContentVerified: true)
            )
        }
        let evaluation = DiscoveryEvaluation(
            reply: "先看 item-0。",
            recommendations: Array(candidates.prefix(8).enumerated()).map { index, candidate in
                .init(
                    candidateID: candidate.id,
                    tier: index == 0 ? .recommended : .other,
                    reason: index == 0 ? "直接对应" : "AI 明确降级"
                )
            }
        )
        let routing = DiscoveryCandidateRanker.semanticRouting(
            evaluation: evaluation,
            fallbackCandidateIDs: Set(candidates.map(\.id))
        )
        let ranked = DiscoveryCandidateRanker.rank(
            candidates,
            intent: .init(goal: "Natural writing rewrite"),
            originalQueryCandidateIDs: [],
            relevantCandidateIDs: routing.relevantCandidateIDs,
            evaluatedCandidateIDs: routing.evaluatedCandidateIDs
        )

        #expect(ranked.recommended.map(\.id) == [candidates[0].id, candidates[8].id])
    }

    @Test("An unevaluated quality candidate cannot become recommended without relevance evidence")
    func unevaluatedUnrelatedCandidateDoesNotBecomeRecommended() {
        let relevant = DiscoveryCandidate(
            id: "known/writing/humanizer", name: "humanizer", summary: "让中文写作更自然",
            repositoryFullName: "known/writing", repositoryStars: 900,
            evidence: .init(skillSummary: "让中文写作更自然，减少模板化表达", skillContentVerified: true)
        )
        let unrelated = DiscoveryCandidate(
            id: "known/writing/query-writing", name: "query-writing", summary: "Write database queries",
            repositoryFullName: "known/writing", repositoryStars: 850,
            evidence: .init(skillSummary: "Write and optimize database queries", skillContentVerified: true)
        )
        let evaluation = DiscoveryEvaluation(
            reply: "humanizer 更符合需求。",
            recommendations: [
                .init(candidateID: relevant.id, tier: .recommended, reason: "直接帮助中文写作更自然"),
            ]
        )
        let routing = DiscoveryCandidateRanker.semanticRouting(
            evaluation: evaluation,
            fallbackCandidateIDs: [relevant.id, unrelated.id]
        )

        let ranked = DiscoveryCandidateRanker.rank(
            [relevant, unrelated],
            intent: .init(goal: "帮我找一个去 AI 味、有活人感的中文写作 Skill"),
            originalQueryCandidateIDs: [relevant.id, unrelated.id],
            relevantCandidateIDs: routing.relevantCandidateIDs,
            evaluatedCandidateIDs: routing.evaluatedCandidateIDs
        )

        #expect(ranked.recommended.map(\.id) == [relevant.id])
        #expect(!ranked.other.contains { $0.id == unrelated.id })
    }

    @Test("Session mutations keep both guides and cannot recreate a deleted search")
    func sessionMutationsMergeAndRespectDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryMutationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = await store.makeSession(title: "写作")
        let firstMarkdown = "---\nname: one\ndescription: One\n---\n"
        let secondMarkdown = "---\nname: two\ndescription: Two\n---\n"
        session.candidates = [
            .init(
                id: "one", name: "one", summary: "One", repositoryFullName: "known/one",
                evidence: .init(skillDocumentExcerpt: firstMarkdown, skillContentVerified: true)
            ),
            .init(
                id: "two", name: "two", summary: "Two", repositoryFullName: "known/two",
                evidence: .init(skillDocumentExcerpt: secondMarkdown, skillContentVerified: true)
            ),
        ]
        try await store.save(session)
        let sessionID = session.id
        let storageFolderName = session.storageFolderName

        async let first = store.saveUsageGuide(
            sessionID: sessionID,
            storageFolderName: storageFolderName,
            candidateID: "one",
            guide: .init(purpose: "Guide one"),
            sourceDigest: SkillUsageGuideSourceIdentity.digest(markdown: firstMarkdown)
        )
        async let second = store.saveUsageGuide(
            sessionID: sessionID,
            storageFolderName: storageFolderName,
            candidateID: "two",
            guide: .init(purpose: "Guide two"),
            sourceDigest: SkillUsageGuideSourceIdentity.digest(markdown: secondMarkdown)
        )
        _ = try await (first, second)

        let merged = try #require(await store.loadAll().first)
        #expect(merged.candidates.first { $0.id == "one" }?.usageGuide?.purpose == "Guide one")
        #expect(merged.candidates.first { $0.id == "two" }?.usageGuide?.purpose == "Guide two")

        try await store.delete(merged)
        let updated = try await store.updateSearchSnapshot(merged)
        #expect(updated == nil)
        #expect(await store.loadAll().isEmpty)
    }

    @Test("A refreshed Skill document cannot inherit a stale discovery guide")
    func refreshedCandidateDropsStaleUsageGuide() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryGuideRefreshTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        let oldMarkdown = "---\nname: writer\ndescription: Old behavior\n---\n"
        let newMarkdown = "---\nname: writer\ndescription: New behavior\n---\n"
        var session = await store.makeSession(title: "写作")
        session.candidates = [
            .init(
                id: "known/writer",
                name: "writer",
                summary: "Old behavior",
                repositoryFullName: "known/writer",
                usageGuide: .init(purpose: "Old guide"),
                usageGuideSourceDigest: SkillUsageGuideSourceIdentity.digest(markdown: oldMarkdown),
                evidence: .init(skillDocumentExcerpt: oldMarkdown, skillContentVerified: true)
            ),
        ]
        try await store.save(session)

        var refreshed = session
        refreshed.candidates = [
            .init(
                id: "known/writer",
                name: "writer",
                summary: "New behavior",
                repositoryFullName: "known/writer",
                evidence: .init(skillDocumentExcerpt: newMarkdown, skillContentVerified: true)
            ),
        ]
        let merged = try #require(await store.updateSearchSnapshot(refreshed))

        #expect(merged.candidates.first?.usageGuide == nil)
        #expect(merged.candidates.first?.usageGuideSourceDigest == nil)
        let staleSave = try await store.saveUsageGuide(
            sessionID: session.id,
            storageFolderName: session.storageFolderName,
            candidateID: "known/writer",
            guide: .init(purpose: "Old guide returned late"),
            sourceDigest: SkillUsageGuideSourceIdentity.digest(markdown: oldMarkdown)
        )
        #expect(staleSave == nil)
        #expect(await store.loadAll().first?.candidates.first?.usageGuide == nil)
    }

    @Test("Only verified candidates with strong public evidence are sent to AI comparison")
    func evaluationFrontierExcludesWeakAndUnverifiedCandidates() {
        let strong = DiscoveryCandidate(
            id: "known/writing/humanizer", name: "humanizer", summary: "把文章改得更自然",
            repositoryFullName: "known/writing", installCount: 2_000, repositoryStars: 800,
            evidence: .init(skillSummary: "把文章改得更自然", skillContentVerified: true, repositoryIsPrivate: false)
        )
        let weak = DiscoveryCandidate(
            id: "unknown/writing/helper", name: "helper", summary: "写作辅助",
            repositoryFullName: "unknown/writing", installCount: 12, repositoryStars: 3,
            evidence: .init(skillSummary: "写作辅助", skillContentVerified: true)
        )
        let unverified = DiscoveryCandidate(
            id: "popular/writing/unverified", name: "unverified", summary: "写作辅助",
            repositoryFullName: "popular/writing", installCount: 20_000, repositoryStars: 9_000
        )

        let result = DiscoveryCandidateRanker.candidatesForEvaluation(
            [strong, weak, unverified],
            intent: .init(goal: "找一个让文章更自然的 Skill"),
            allowPrivateSkillContent: false
        )

        #expect(result.map(\.id) == [strong.id])
    }

    @Test("AI evaluation excludes private and unknown repository content until the user opts in")
    func evaluationFrontierRequiresContentSharingConsent() {
        func candidate(id: String, privacy: Bool?) -> DiscoveryCandidate {
            .init(
                id: id,
                name: "humanizer",
                summary: "把文章改得更自然",
                repositoryFullName: "known/writing",
                repositoryStars: 800,
                evidence: .init(
                    skillSummary: "把文章改得更自然",
                    skillContentVerified: true,
                    repositoryIsPrivate: privacy
                )
            )
        }
        let publicCandidate = candidate(id: "known/public", privacy: false)
        let privateCandidate = candidate(id: "known/private", privacy: true)
        let unknownCandidate = candidate(id: "known/unknown", privacy: nil)
        let intent = DiscoveryIntent(goal: "找一个让文章更自然的 Skill")

        let withoutConsent = DiscoveryCandidateRanker.candidatesForEvaluation(
            [publicCandidate, privateCandidate, unknownCandidate],
            intent: intent,
            allowPrivateSkillContent: false
        )
        let withConsent = DiscoveryCandidateRanker.candidatesForEvaluation(
            [publicCandidate, privateCandidate, unknownCandidate],
            intent: intent,
            allowPrivateSkillContent: true
        )

        #expect(withoutConsent.map(\.id) == [publicCandidate.id])
        #expect(Set(withConsent.map(\.id)) == Set([publicCandidate.id, privateCandidate.id, unknownCandidate.id]))
    }

    @Test("Strong candidates are ordered by GitHub reputation before install count")
    func githubStarsLeadQualityOrdering() {
        let moreInstalls = DiscoveryCandidate(
            id: "known/more-installs", name: "humanizer-a", summary: "把中文文章改写得自然",
            repositoryFullName: "known/more-installs", installCount: 50_000, repositoryStars: 520,
            evidence: .init(skillSummary: "把中文文章改写得自然", skillContentVerified: true)
        )
        let moreStars = DiscoveryCandidate(
            id: "known/more-stars", name: "humanizer-b", summary: "把中文文章改写得自然",
            repositoryFullName: "known/more-stars", installCount: 2_000, repositoryStars: 4_800,
            evidence: .init(skillSummary: "把中文文章改写得自然", skillContentVerified: true)
        )
        let ids = Set([moreInstalls.id, moreStars.id])

        let result = DiscoveryCandidateRanker.rank(
            [moreInstalls, moreStars],
            intent: .init(goal: "找一个把中文文章改写得自然的 Skill"),
            originalQueryCandidateIDs: ids,
            relevantCandidateIDs: ids
        )

        #expect(result.recommended.map(\.id) == [moreStars.id, moreInstalls.id])
    }

    @Test("Popularity cannot promote a detection-only Skill for a rewriting goal")
    func popularityCannotOverrideCapabilityMismatch() {
        let detector = DiscoveryCandidate(
            id: "popular/check/dbs-ai-check", name: "dbs-ai-check",
            summary: "扫描文案中的 AI 写作特征并输出检测报告，默认只诊断不改写",
            repositoryFullName: "popular/check", installCount: 17_600, repositoryStars: 9_600,
            evidence: .init(
                skillSummary: "扫描文案中的 AI 写作特征并输出检测报告，默认只诊断不改写",
                skillContentVerified: true
            )
        )

        let result = DiscoveryCandidateRanker.rank(
            [detector],
            intent: .init(goal: "帮我找一个去文案 AI 味并改写得更自然的 Skill"),
            originalQueryCandidateIDs: [detector.id],
            relevantCandidateIDs: [detector.id]
        )

        #expect(result.recommended.isEmpty)
        #expect(result.other.map(\.id) == [detector.id])
    }

    @Test("Every high-quality candidate survives ranking without display caps")
    func rankingHasNoProductCountCap() {
        let candidates = (0..<24).map { index in
            DiscoveryCandidate(
                id: "trusted/writing/humanizer-\(index)", name: "humanizer-\(index)",
                summary: "把中文文章改写得自然，减少 AI 模板化表达",
                repositoryFullName: "openai/writing-\(index)", installCount: 1_000 + index,
                repositoryStars: 300 + index,
                evidence: .init(skillSummary: "把中文文章改写得自然，减少 AI 模板化表达", skillContentVerified: true)
            )
        }
        let ids = Set(candidates.map(\.id))

        let result = DiscoveryCandidateRanker.rank(
            candidates,
            intent: .init(goal: "找一个把中文文案改写得更自然、减少 AI 味的 Skill"),
            originalQueryCandidateIDs: ids,
            relevantCandidateIDs: ids
        )

        #expect(result.recommended.count == candidates.count)
    }

    @Test("Chinese goals without spaces still match real Skill descriptions")
    func compactChineseGoalStillMatches() {
        let candidate = DiscoveryCandidate(
            id: "writer/layout/wechat-layout", name: "wechat-layout", summary: "公众号文章排版与发布",
            repositoryFullName: "writer/layout", installCount: 1_200, repositoryStars: 260,
            evidence: .init(skillSummary: "完成公众号文章排版、预览与发布", skillContentVerified: true)
        )

        let result = DiscoveryCandidateRanker.rank(
            [candidate],
            intent: .init(goal: "我想找一个公众号文章排版的 Skill"),
            originalQueryCandidateIDs: [candidate.id]
        )

        #expect(result.recommended.map(\.id) == [candidate.id])
    }

    @Test("Batch search keeps the original query and verifies Skill-level descriptions")
    func batchSearchVerifiesSkillEvidence() async throws {
        let provider = SkillsShDiscoveryProvider(
            session: DiscoveryFixture.session(),
            endpoint: URL(string: "https://skills.sh/api/search")!,
            fallbackEndpoint: nil
        )

        let result = try await provider.search(queries: ["去 AI 味", "humanize writing"], limitPerQuery: 20)
        let candidate = try #require(result.candidates.first { $0.name == "humanizer-zh" })

        #expect(result.originalQueryCandidateIDs.contains(candidate.id))
        #expect(candidate.evidence.skillContentVerified)
        #expect(candidate.evidence.repositoryIsPrivate == false)
        #expect(candidate.userFacingSummary == "让中文文章更自然，减少模板化和机械表达。")
        #expect(candidate.repositorySummary == "Repository-level description")
    }

    @Test("Batch search skips obviously weak catalog entries before expensive verification")
    func batchSearchUsesAQualityFrontierBeforeVerification() async throws {
        let provider = SkillsShDiscoveryProvider(
            session: DiscoveryFixture.session(),
            endpoint: URL(string: "https://skills.sh/api/search")!,
            fallbackEndpoint: nil
        )

        let result = try await provider.search(queries: ["presentation"], limitPerQuery: 20)

        #expect(result.candidates.contains { $0.name == "slides" })
        #expect(!result.candidates.contains { $0.name == "deck-helper" })
    }

    @Test("One failed skills.sh query keeps verified results from the remaining queries")
    func skillsShBatchKeepsPartialQueryResults() async throws {
        DiscoveryMockURLProtocol.failedSearchQuery = "broken query"
        defer { DiscoveryMockURLProtocol.failedSearchQuery = nil }
        let provider = SkillsShDiscoveryProvider(
            session: DiscoveryFixture.session(preservingFailure: true),
            endpoint: URL(string: "https://skills.sh/api/search")!,
            fallbackEndpoint: nil
        )

        let result = try await provider.search(
            queries: ["presentation", "broken query"],
            limitPerQuery: 20
        )

        #expect(result.candidates.contains { $0.name == "slides" })
        #expect(result.originalQueryCandidateIDs.contains("openai/skills/skills/slides"))
        #expect(result.failedQueryCount == 1)
    }

    @Test("Starting another search does not overwrite the earlier record")
    func multipleRecordsStayIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        let first = await store.makeSession(title: "剪辑视频", now: Date(timeIntervalSince1970: 100))
        let second = await store.makeSession(title: "分析数据", now: Date(timeIntervalSince1970: 200))

        try await store.save(first)
        try await store.save(second)

        let reloaded = await store.loadAll()
        #expect(reloaded.map(\.title) == ["分析数据", "剪辑视频"])
    }

    @Test("Reloading an active search never invents an interruption")
    func activeSearchReloadIsPure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = await store.makeSession(title: "中断测试", now: Date(timeIntervalSince1970: 100))
        session.messages = [.init(role: .user, text: "找一个写作 Skill")]
        session.runs = [.init(queries: ["找一个写作 Skill"], state: .recalling)]
        try await store.save(session)

        let reloaded = try #require(await store.loadAll().first)

        #expect(reloaded.messages.map(\.role) == [.user])
        #expect(reloaded.runs.last?.state == .recalling)
        #expect(reloaded.notices.isEmpty)
    }

    @Test("Explicit startup recovery marks only unfinished runs outside chat")
    func interruptedSearchRecoversOutsideChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxDiscoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscoverySessionStore(root: root)
        var session = await store.makeSession(title: "中断测试", now: Date(timeIntervalSince1970: 100))
        session.messages = [.init(role: .user, text: "找一个写作 Skill")]
        session.runs = [.init(queries: ["找一个写作 Skill"], state: .verifying)]
        try await store.save(session)

        let count = try await store.recoverInterruptedRuns()
        let recovered = try #require(await store.loadAll().first)

        #expect(count == 1)
        #expect(recovered.messages.map(\.role) == [.user])
        #expect(recovered.runs.last?.state == .interrupted)
        #expect(recovered.notices.last?.text.contains("继续寻找") == true)
    }

    @Test("Multiple discovery sources deduplicate by repository and Skill path without truncation")
    func coordinatorCombinesSourcesWithoutTruncation() async throws {
        let first = (0..<18).map { (index: Int) in
            DiscoveryCandidate(
                id: "skills-sh/owner/repo/skills/item-\(index)", name: "item-\(index)",
                summary: "用途 \(index)", repositoryFullName: "owner/repo", skillPath: "skills/item-\(index)",
                installCount: index
            )
        }
        var duplicate = first[0]
        duplicate.id = "github/owner/repo/skills/item-0"
        duplicate.repositoryStars = 900
        duplicate.evidence = .init(skillSummary: "来自真实 SKILL.md 的用途", skillContentVerified: true)
        let extra = DiscoveryCandidate(
            id: "github/other/repo/tool", name: "tool", summary: "额外候选",
            repositoryFullName: "other/repo", skillPath: "tool", repositoryStars: 500
        )
        let coordinator = DiscoverySearchCoordinator(providers: [
            StubDiscoveryProvider(candidates: first),
            StubDiscoveryProvider(candidates: [duplicate, extra]),
        ])

        let result = try await coordinator.search(queries: ["writing"], limitPerQuery: 100)

        #expect(result.candidates.count == 19)
        let merged = try #require(result.candidates.first { $0.skillPath == "skills/item-0" })
        #expect(merged.repositoryStars == 900)
        #expect(merged.evidence.skillContentVerified)
    }

    @Test("A catalog result without a path merges with GitHub evidence for the same named Skill")
    func coordinatorMergesNameOnlyCatalogEvidence() async throws {
        let catalog = DiscoveryCandidate(
            id: "catalog/known/writing/humanizer", name: "humanizer",
            repositoryFullName: "known/writing", installCount: 12_000,
            evidence: .init(sources: [.skillsSh])
        )
        let github = DiscoveryCandidate(
            id: "github/known/writing/skills/humanizer", name: "humanizer",
            summary: "把文章改写得更自然", repositoryFullName: "known/writing",
            skillPath: "skills/humanizer", repositoryStars: 4_200,
            evidence: .init(
                skillSummary: "把文章改写得更自然", skillContentVerified: true,
                sources: [.github, .skillDocument]
            )
        )
        let coordinator = DiscoverySearchCoordinator(providers: [
            StubDiscoveryProvider(candidates: [catalog]),
            StubDiscoveryProvider(candidates: [github]),
        ])

        let result = try await coordinator.search(queries: ["humanize"], limitPerQuery: 100)
        let merged = try #require(result.candidates.first)

        #expect(result.candidates.count == 1)
        #expect(merged.skillPath == "skills/humanizer")
        #expect(merged.installCount == 12_000)
        #expect(merged.repositoryStars == 4_200)
        #expect(merged.evidence.skillContentVerified)
    }

    @Test("A failed source keeps verified results and marks the search partial")
    func coordinatorKeepsResultsWhenOneSourceFails() async throws {
        let candidate = DiscoveryCandidate(
            id: "good/writing/humanizer", name: "humanizer", repositoryFullName: "good/writing"
        )
        let coordinator = DiscoverySearchCoordinator(providers: [
            StubDiscoveryProvider(candidates: [candidate]),
            FailingDiscoveryProvider(),
        ])

        let result = try await coordinator.search(queries: ["humanize writing"], limitPerQuery: 100)

        #expect(result.candidates.map(\.id) == [candidate.id])
        #expect(result.failedSourceCount == 1)
    }

    @Test("Cancellation stops the source pipeline instead of becoming a partial result")
    func coordinatorPropagatesCancellation() async throws {
        let counter = DiscoveryProviderCallCounter()
        let coordinator = DiscoverySearchCoordinator(providers: [
            CancellingDiscoveryProvider(),
            CountingDiscoveryProvider(counter: counter),
        ])

        do {
            _ = try await coordinator.search(queries: ["humanize writing"], limitPerQuery: 20)
            Issue.record("取消不应被记为普通来源失败")
        } catch is CancellationError {
            #expect(await counter.calls == 0)
        }
    }

    @Test("GitHub search only returns candidates backed by a real matching SKILL.md")
    func githubSearchVerifiesRealSkillDocuments() async throws {
        GitHubSkillSearchMockURLProtocol.failedQuery = nil
        GitHubSkillSearchMockURLProtocol.weakContentRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubSkillSearchMockURLProtocol.self]
        let provider = GitHubSkillDiscoveryProvider(
            session: URLSession(configuration: configuration),
            tokenProvider: DiscoveryFixedTokenProvider()
        )

        let result = try await provider.search(query: "humanize writing", limit: 200)
        let candidate = try #require(result.candidates.first)

        #expect(result.candidates.count == 1)
        #expect(candidate.name == "humanizer")
        #expect(candidate.skillPath == "skills/humanizer")
        #expect(candidate.repositoryFullName == "known/writing-skills")
        #expect(candidate.repositoryStars == 4_200)
        #expect(candidate.evidence.skillContentVerified)
        #expect(candidate.evidence.sources.contains(.github))
        #expect(candidate.evidence.sources.contains(.skillDocument))
        #expect(GitHubSkillSearchMockURLProtocol.lastAuthorization == "Bearer discovery-token")
    }

    @Test("GitHub search reads repository quality before downloading weak Skill documents")
    func githubSearchSkipsWeakRepositoryDocuments() async throws {
        GitHubSkillSearchMockURLProtocol.failedQuery = nil
        GitHubSkillSearchMockURLProtocol.weakContentRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubSkillSearchMockURLProtocol.self]
        let provider = GitHubSkillDiscoveryProvider(
            session: URLSession(configuration: configuration),
            tokenProvider: DiscoveryFixedTokenProvider()
        )

        let result = try await provider.search(query: "quality frontier", limit: 20)

        #expect(result.candidates.map(\.name) == ["humanizer"])
        #expect(GitHubSkillSearchMockURLProtocol.weakContentRequestCount == 0)
    }

    @Test("One failed GitHub query keeps verified results from the remaining queries")
    func githubBatchSearchKeepsResultsWhenOneQueryFails() async throws {
        GitHubSkillSearchMockURLProtocol.failedQuery = "broken query"
        GitHubSkillSearchMockURLProtocol.contentRequestCount = 0
        GitHubSkillSearchMockURLProtocol.repositoryRequestCount = 0
        defer { GitHubSkillSearchMockURLProtocol.failedQuery = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubSkillSearchMockURLProtocol.self]
        let provider = GitHubSkillDiscoveryProvider(
            session: URLSession(configuration: configuration),
            tokenProvider: DiscoveryFixedTokenProvider()
        )

        let result = try await provider.search(
            queries: ["humanize writing", "broken query"],
            limitPerQuery: 200
        )

        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.name == "humanizer")
        #expect(result.failedSourceCount == 0)
        #expect(result.failedQueryCount == 1)
    }

    @Test("Repeated GitHub query hits are verified only once")
    func githubBatchSearchDeduplicatesBeforeVerification() async throws {
        GitHubSkillSearchMockURLProtocol.failedQuery = nil
        GitHubSkillSearchMockURLProtocol.contentRequestCount = 0
        GitHubSkillSearchMockURLProtocol.repositoryRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubSkillSearchMockURLProtocol.self]
        let provider = GitHubSkillDiscoveryProvider(
            session: URLSession(configuration: configuration),
            tokenProvider: DiscoveryFixedTokenProvider()
        )

        let result = try await provider.search(
            queries: ["humanize writing", "natural rewrite"],
            limitPerQuery: 20
        )

        #expect(result.candidates.count == 1)
        #expect(GitHubSkillSearchMockURLProtocol.repositoryRequestCount == 1)
        #expect(GitHubSkillSearchMockURLProtocol.contentRequestCount == 1)
    }

    @Test("Initial search uses a smaller retrieval budget than explicit deep search")
    func discoverySearchBudgetsFavorFastFirstResults() {
        #expect(DiscoverySearchScope.initial.limitPerQuery <= 30)
        #expect(DiscoverySearchScope.deep.limitPerQuery > DiscoverySearchScope.initial.limitPerQuery)
    }
}

private struct StubDiscoveryProvider: SkillDiscoveryProvider {
    var candidates: [DiscoveryCandidate]

    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        DiscoverySearchResult(candidates: candidates)
    }
}

private struct FailingDiscoveryProvider: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        throw SkillDiscoveryError.requestFailed(429)
    }
}

private struct CancellingDiscoveryProvider: SkillDiscoveryProvider {
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        throw CancellationError()
    }
}

private actor DiscoveryProviderCallCounter {
    var calls = 0
    func record() { calls += 1 }
}

private struct CountingDiscoveryProvider: SkillDiscoveryProvider {
    let counter: DiscoveryProviderCallCounter
    func search(query: String, limit: Int) async throws -> DiscoverySearchResult {
        await counter.record()
        return .init(candidates: [])
    }
}

private struct DiscoveryFixedTokenProvider: GitHubAccessTokenProvider {
    func accessToken() async throws -> String? { "discovery-token" }
}

private final class GitHubSkillSearchMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var failedQuery: String?
    nonisolated(unsafe) static var weakContentRequestCount = 0
    nonisolated(unsafe) static var contentRequestCount = 0
    nonisolated(unsafe) static var repositoryRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let path = request.url?.path ?? ""
        if path == "/search/code",
           let failedQuery = Self.failedQuery,
           URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value?.contains(failedQuery) == true {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"message":"rate limited"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: String
        if path == "/search/code" {
            let isFrontier = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value?.contains("quality frontier") == true
            body = isFrontier
                ? #"{"total_count":2,"items":[{"path":"skills/humanizer/SKILL.md","url":"https://api.github.com/repos/known/writing-skills/contents/skills/humanizer/SKILL.md","repository":{"full_name":"known/writing-skills"}},{"path":"skills/noise/SKILL.md","url":"https://api.github.com/repos/weak/noise/contents/skills/noise/SKILL.md","repository":{"full_name":"weak/noise"}}]}"#
                : #"{"total_count":1,"items":[{"path":"skills/humanizer/SKILL.md","url":"https://api.github.com/repos/known/writing-skills/contents/skills/humanizer/SKILL.md","repository":{"full_name":"known/writing-skills"}}]}"#
        } else if path.contains("/contents/skills/humanizer/SKILL.md") {
            Self.contentRequestCount += 1
            let markdown = "---\nname: humanizer\ndescription: 把文案改写得更自然，减少 AI 模板感。\n---\n"
            body = #"{"content":"\#(Data(markdown.utf8).base64EncodedString())","download_url":"https://raw.githubusercontent.com/known/writing-skills/main/skills/humanizer/SKILL.md"}"#
        } else if path.contains("/contents/skills/noise/SKILL.md") {
            Self.weakContentRequestCount += 1
            let markdown = "---\nname: noise\ndescription: 未经验证的弱候选。\n---\n"
            body = #"{"content":"\#(Data(markdown.utf8).base64EncodedString())"}"#
        } else if path == "/repos/weak/noise" {
            Self.repositoryRequestCount += 1
            body = #"{"full_name":"weak/noise","description":"Weak repository","stargazers_count":2,"updated_at":"2024-01-01T08:00:00Z","archived":false,"disabled":false,"private":false}"#
        } else {
            Self.repositoryRequestCount += 1
            body = #"{"full_name":"known/writing-skills","description":"Writing skills","stargazers_count":4200,"updated_at":"2026-08-17T08:00:00Z","archived":false,"disabled":false,"private":false}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DiscoveryMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastSearchURL: URL?
    nonisolated(unsafe) static var repositoryRequestCount = 0
    nonisolated(unsafe) static var failedSearchQuery: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.host == "skills.sh" { Self.lastSearchURL = request.url }
        let query = request.url.flatMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
        }
        if request.url?.path == "/api/search", query == Self.failedSearchQuery {
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"temporary"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body: String
        if request.url?.host == "api.github.com" {
            Self.repositoryRequestCount += 1
            let repository: String
            if request.url?.path.contains("example/deck-helper") == true { repository = "example/deck-helper" }
            else if request.url?.path.contains("example/humanizer") == true { repository = "example/humanizer" }
            else if request.url?.path.contains("chat/dingtalk") == true { repository = "chat/dingtalk" }
            else { repository = "openai/skills" }
            let description = repository == "openai/skills" ? "OpenAI skills repository" : "Repository-level description"
            let stars = repository == "openai/skills" ? 9800 : 321
            if request.url?.path.contains("/git/trees/") == true {
                let skillName = repository == "chat/dingtalk" ? "dingtalk" : "humanizer-zh"
                body = #"{"tree":[{"path":"\#(skillName)/SKILL.md","type":"blob"}]}"#
            } else if request.url?.path.contains("/contents/") == true {
                let skillName = repository == "chat/dingtalk" ? "dingtalk" : "humanizer-zh"
                let markdown = repository == "chat/dingtalk"
                    ? "---\nname: \(skillName)\ndescription: 管理钉钉文档和机器人。\n---\n"
                    : "---\nname: \(skillName)\ndescription: 让中文文章更自然，减少模板化和机械表达。\n---\n"
                body = #"{"content":"\#(Data(markdown.utf8).base64EncodedString())"}"#
            } else {
                body = #"{"full_name":"\#(repository)","description":"\#(description)","stargazers_count":\#(stars),"updated_at":"2026-08-17T08:00:00Z","default_branch":"main","private":false}"#
            }
        } else if request.url?.path == "/api/search",
                  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value?.contains("去 AI 味") == true {
            body = #"{"skills":[{"id":"example/humanizer/humanizer-zh","name":"humanizer-zh","description":"search snippet","source":"example/humanizer","installs":719,"github_stars":321},{"id":"chat/dingtalk/dingtalk","name":"dingtalk","description":"钉钉机器人","source":"chat/dingtalk","installs":9999,"github_stars":5000}]}"#
        } else if request.url?.path == "/api/search",
                  URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == "humanize writing" {
            body = #"{"skills":[{"id":"example/humanizer/humanizer-zh","name":"humanizer-zh","description":"search snippet","source":"example/humanizer","installs":719,"github_stars":321}]}"#
        } else if request.url?.host == "skills.sh", request.url?.path != "/api/search" {
            let description = request.url?.path.contains("humanizer-zh") == true ? "让中文文章更自然，减少模板化和机械表达。" : "管理钉钉文档和机器人。"
            body = #"<html><script type="application/ld+json">{"@type":"SoftwareApplication","description":"\#(description)"}</script></html>"#
        } else {
            body = #"{"skills":[{"id":"openai/skills/skills/slides","name":"slides","description":"Create and edit presentations","source":"openai/skills","installs":1250,"github_stars":9800},{"name":"deck-helper","source":"https://github.com/example/deck-helper","installs":22}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum DiscoveryFixture {
    static func session(preservingFailure: Bool = false) -> URLSession {
        DiscoveryMockURLProtocol.lastSearchURL = nil
        DiscoveryMockURLProtocol.repositoryRequestCount = 0
        if !preservingFailure { DiscoveryMockURLProtocol.failedSearchQuery = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
