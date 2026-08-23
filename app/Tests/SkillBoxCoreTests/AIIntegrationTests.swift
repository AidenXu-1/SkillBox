import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Optional AI integration", .serialized)
struct AIIntegrationTests {
    @Test("Default providers use current public endpoints and stay disabled")
    func defaultsAreSafe() {
        let settings = AISettings.defaults

        #expect(settings.isEnabled == false)
        #expect(settings.selectedProviderID == "agnes")
        #expect(settings.configuration(id: "agnes")?.baseURL == "https://apihub.agnes-ai.com/v1")
        #expect(settings.configuration(id: "agnes")?.model == "agnes-2.5-flash")
        #expect(settings.configuration(id: "deepseek")?.baseURL == "https://api.deepseek.com")
        #expect(settings.configuration(id: "deepseek")?.model == "deepseek-v4-flash")
        #expect(settings.configuration(id: "kimi")?.baseURL == "https://api.moonshot.cn/v1")
        #expect(settings.configuration(id: "kimi")?.model == "kimi-k2.6")
        #expect(settings.configuration(id: "minimax")?.baseURL == "https://api.minimaxi.com/v1")
        #expect(settings.configuration(id: "minimax")?.model == "MiniMax-M2.7")
        #expect(settings.configuration(id: "glm")?.baseURL == "https://open.bigmodel.cn/api/paas/v4")
        #expect(settings.configuration(id: "glm")?.model == "glm-5.3")
        #expect(settings.configurations.map(\.id) == ["agnes", "deepseek", "kimi", "minimax", "glm", "custom"])
    }

    @Test("Older settings gain new providers without losing the selected model")
    func olderSettingsAreMergedWithCurrentProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAIMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AISettingsStore(root: root)
        var oldSettings = AISettings.defaults
        oldSettings.configurations = Array(oldSettings.configurations.prefix(2)) + [
            .init(id: "custom", kind: .custom, displayName: "我的接口", baseURL: "https://example.com/v1", model: "my-model"),
        ]
        oldSettings.selectedProviderID = "deepseek"
        oldSettings.configurations[1].model = "deepseek-v4-pro"
        try await store.save(oldSettings)

        let migrated = await store.load()

        #expect(migrated.selectedProviderID == "deepseek")
        #expect(migrated.configuration(id: "deepseek")?.model == "deepseek-v4-pro")
        #expect(migrated.configuration(id: "kimi") != nil)
        #expect(migrated.configuration(id: "minimax") != nil)
        #expect(migrated.configuration(id: "glm") != nil)
        #expect(migrated.configuration(id: "custom")?.displayName == "我的接口")
        #expect(migrated.configuration(id: "custom")?.model == "my-model")
        #expect(migrated.configurations.map(\.id) == ["agnes", "deepseek", "kimi", "minimax", "glm", "custom"])
    }

    @Test("Built-in provider endpoints cannot be replaced by persisted settings")
    func builtInEndpointsStayPinnedDuringMigration() {
        var settings = AISettings.defaults
        let index = settings.configurations.firstIndex { $0.id == "deepseek" }!
        settings.configurations[index].baseURL = "https://attacker.example/v1"
        settings.configurations[index].displayName = "Fake DeepSeek"
        settings.configurations[index].kind = .custom
        settings.configurations[index].model = "deepseek-v4-pro"

        let merged = settings.mergedWithCurrentProviders()
        let deepSeek = merged.configuration(id: "deepseek")

        #expect(deepSeek?.baseURL == "https://api.deepseek.com")
        #expect(deepSeek?.displayName == "DeepSeek")
        #expect(deepSeek?.kind == .deepSeek)
        #expect(deepSeek?.model == "deepseek-v4-pro")
    }

    @Test("Settings persist without ever containing an API key")
    func settingsNeverPersistKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAITests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AISettingsStore(root: root)
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "deepseek"

        try await store.save(settings)

        let data = try Data(contentsOf: root.appendingPathComponent("ai-settings.json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("api_key"))
        #expect(!text.contains("sk-secret"))
        #expect(await store.load() == settings)
    }

    @Test("A saved key is not a connected provider until its exact endpoint and model pass the probe")
    func connectionStateRequiresVerifiedConfiguration() {
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "deepseek"

        #expect(!settings.isConnectionVerified(providerID: "deepseek"))
        #expect(settings.selectedVerifiedConfiguration == nil)

        settings.markConnectionVerified(providerID: "deepseek", at: Date(timeIntervalSince1970: 100))
        #expect(settings.isConnectionVerified(providerID: "deepseek"))
        #expect(settings.selectedVerifiedConfiguration?.id == "deepseek")

        let index = settings.configurations.firstIndex { $0.id == "deepseek" }!
        settings.configurations[index].model = "deepseek-v4-pro"
        #expect(!settings.isConnectionVerified(providerID: "deepseek"))
        #expect(settings.selectedVerifiedConfiguration == nil)
    }

    @Test("Private-content consent is valid only for the exact selected recipient")
    func privateContentConsentIsRecipientScoped() {
        var settings = AISettings.defaults
        settings.isEnabled = true
        settings.selectedProviderID = "deepseek"
        settings.markConnectionVerified(providerID: "deepseek")
        settings.setPrivateContentSharingAllowed(true)

        #expect(settings.isPrivateContentSharingAllowedForSelectedProvider)

        settings.selectedProviderID = "kimi"
        #expect(!settings.isPrivateContentSharingAllowedForSelectedProvider)

        settings.selectedProviderID = "deepseek"
        let index = settings.configurations.firstIndex { $0.id == "deepseek" }!
        settings.configurations[index].model = "deepseek-v4-pro"
        #expect(!settings.isPrivateContentSharingAllowedForSelectedProvider)
    }

    @Test("Connection testing uses the selected provider and bearer key")
    func testsSelectedConnection() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .models))
        let configuration = AISettings.defaults.configuration(id: "agnes")!

        let result = try await provider.testConnection(configuration: configuration, apiKey: "agnes-key")

        #expect(result.models == ["agnes-2.5-flash", "agnes-2.0-flash"])
        #expect(AIMockURLProtocol.requestedPaths == ["/v1/models", "/v1/chat/completions"])
        #expect(result.diagnostic.errorCategory == nil)
        #expect(AIMockURLProtocol.lastAuthorization == "Bearer agnes-key")
    }

    @Test("Discovery planning preserves the original goal and uses the selected model")
    func plansWithSelectedModel() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .plan))
        var configuration = AISettings.defaults.configuration(id: "deepseek")!
        configuration.model = "deepseek-v4-pro"

        let result = try await provider.planDiscovery(
            message: "我想找一个能给公众号文章排版的 Skill",
            previousIntent: nil,
            configuration: configuration,
            apiKey: "deepseek-key"
        )

        #expect(result.value.intent.goal == "我想找一个能给公众号文章排版的 Skill")
        #expect(result.value.queries == ["我想找一个能给公众号文章排版的 Skill", "wechat article layout publishing"])
        let requestBody = try #require(AIMockURLProtocol.lastRequestBody?.data(using: .utf8))
        let payload = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        #expect(payload["model"] as? String == "deepseek-v4-pro")
        #expect((payload["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect((payload["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((payload["max_tokens"] as? Int ?? 0) <= 600)
        #expect(AIMockURLProtocol.lastAuthorization == "Bearer deepseek-key")
    }

    @Test("Discovery planning removes secrets and private paths before sending")
    func discoveryPlanningRedactsUserAndPriorIntent() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .plan))
        let configuration = AISettings.defaults.configuration(id: "deepseek")!
        let previous = DiscoveryIntent(
            goal: "读取 /Users/alice/private-project",
            mustHaves: ["api_key: sk-previous-secret-value"],
            preferences: ["保留普通需求"],
            exclusions: ["github_pat_previousSecretValue123"]
        )

        _ = try await provider.planDiscovery(
            message: "Bearer newest-secret-value 位于 /Users/alice/private/source.md",
            previousIntent: previous,
            configuration: configuration,
            apiKey: "deepseek-key"
        )

        let requestBody = try #require(AIMockURLProtocol.lastRequestBody)
        for privateValue in [
            "newest-secret-value",
            "/Users/alice",
            "sk-previous-secret-value",
            "github_pat_previousSecretValue123",
        ] {
            #expect(!requestBody.contains(privateValue))
        }
        #expect(requestBody.contains("[已隐藏敏感内容]") || requestBody.contains("[本机路径]"))
    }

    @Test("DeepSeek structured tasks explicitly request JSON output")
    func deepSeekStructuredTasksRequestJSON() async throws {
        let configuration = AISettings.defaults.configuration(id: "deepseek")!

        let planningProvider = OpenAICompatibleProvider(session: AIFixture.session(mode: .plan))
        _ = try await planningProvider.planDiscovery(
            message: "找一个自然写作 Skill",
            previousIntent: nil,
            configuration: configuration,
            apiKey: "deepseek-key"
        )
        #expect(try lastSystemPrompt().localizedCaseInsensitiveContains("json"))

        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(skillSummary: "Create slides", skillContentVerified: true)
        )
        let evaluationProvider = OpenAICompatibleProvider(session: AIFixture.session(mode: .evaluation))
        _ = try await evaluationProvider.evaluateCandidates(
            intent: .init(goal: "做演示文稿"),
            candidates: [candidate],
            configuration: configuration,
            apiKey: "deepseek-key"
        )
        #expect(try lastSystemPrompt().localizedCaseInsensitiveContains("json"))

        let guideProvider = OpenAICompatibleProvider(session: AIFixture.session(mode: .usageGuide))
        _ = try await guideProvider.analyzeSkillUsage(
            material: .init(
                name: "humanizer-zh",
                description: "让中文表达更自然",
                documents: [.init(relativePath: "SKILL.md", content: "保留事实与语气，减少模板化表达。")]
            ),
            configuration: configuration,
            apiKey: "deepseek-key"
        )
        #expect(try lastSystemPrompt().localizedCaseInsensitiveContains("json"))
    }

    @Test("A mixed evaluation containing an unknown ID is rejected")
    func mixedUnknownCandidateIDsAreRejected() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .mixedUnknownEvaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let known = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(skillSummary: "Create and edit slide decks", skillContentVerified: true)
        )

        do {
            _ = try await provider.evaluateCandidates(
                intent: .init(goal: "做演示文稿"),
                candidates: [known],
                configuration: configuration,
                apiKey: "agnes-key"
            )
            Issue.record("含有未知 ID 的混合结果不应保留可能提及虚构候选的 reply")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .schemaValidationFailed)
        }
    }

    @Test("Duplicate candidate IDs are rejected before application ranking")
    func duplicateCandidateIDsAreRejected() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .duplicateEvaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(skillSummary: "Create and edit slide decks", skillContentVerified: true)
        )

        do {
            _ = try await provider.evaluateCandidates(
                intent: .init(goal: "做演示文稿"),
                candidates: [candidate],
                configuration: configuration,
                apiKey: "agnes-key"
            )
            Issue.record("重复候选 ID 不应进入应用层")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .schemaValidationFailed)
        }
    }

    @Test("An evaluation containing only unknown IDs is rejected")
    func unknownOnlyEvaluationIsRejected() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .unknownOnlyEvaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(skillSummary: "Create and edit slide decks", skillContentVerified: true)
        )

        do {
            _ = try await provider.evaluateCandidates(
                intent: .init(goal: "做演示文稿"),
                candidates: [candidate],
                configuration: configuration,
                apiKey: "agnes-key"
            )
            Issue.record("只有未知 ID 的结果不应被当作有效评估")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .schemaValidationFailed)
        }
    }

    @Test("Candidate evaluation sends a compact Skill excerpt instead of the complete document")
    func candidateEvaluationUsesCompactEvidence() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .evaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let longDocument = String(repeating: "A", count: 20_000) + "PRIVATE_TAIL_MARKER"
        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(
                skillSummary: "Create and edit slide decks",
                skillDocumentExcerpt: longDocument,
                skillContentVerified: true
            )
        )

        _ = try await provider.evaluateCandidates(
            intent: .init(goal: "做演示文稿"),
            candidates: [candidate],
            configuration: configuration,
            apiKey: "agnes-key"
        )

        let body = try #require(AIMockURLProtocol.lastRequestBody)
        #expect(!body.contains("PRIVATE_TAIL_MARKER"))
        #expect(body.utf8.count < 16_000)
    }

    @Test("Candidate evaluation applies one whole-request budget")
    func candidateEvaluationUsesWholeRequestBudget() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .budgetEvaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let candidates = (0..<12).map { index in
            DiscoveryCandidate(
                id: "example/skills/item-\(index)",
                name: "item-\(index)",
                summary: String(repeating: "S", count: 1_000),
                repositoryFullName: "example/skills",
                repositoryStars: 10_000 - index,
                evidence: .init(
                    skillSummary: String(repeating: "M", count: 1_000),
                    skillDocumentExcerpt: String(repeating: "D", count: 10_000),
                    repositorySummary: String(repeating: "R", count: 1_000),
                    skillContentVerified: true
                )
            )
        }

        let result = try await provider.evaluateCandidates(
            intent: .init(goal: "找一个适合的 Skill"),
            candidates: candidates,
            configuration: configuration,
            apiKey: "agnes-key"
        )

        let body = try #require(AIMockURLProtocol.lastRequestBody?.data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? String)
        let input = try #require(JSONSerialization.jsonObject(with: Data(userContent.utf8)) as? [String: Any])
        let sent = try #require(input["candidates"] as? [[String: Any]])
        let evidenceCharacters = sent.reduce(0) { partial, candidate in
            partial
                + (candidate["skillSummary"] as? String ?? "").count
                + (candidate["skillDocumentExcerpt"] as? String ?? "").count
                + (candidate["repositorySummary"] as? String ?? "").count
        }

        #expect(sent.count == 8)
        #expect(evidenceCharacters <= 8_000)
        #expect((payload["max_tokens"] as? Int ?? 0) <= 1_500)
        #expect(result.diagnostic.inputItemCount == 8)
        #expect(result.diagnostic.requestBodyBytesSent == body.count)
        #expect(result.diagnostic.inputTokenCount == 321)
        #expect(result.diagnostic.outputTokenCount == 45)
        #expect(result.diagnostic.attemptCount == 1)
        #expect(result.diagnostic.durationMilliseconds != nil)
    }

    @Test("Skill analysis returns exactly the four reusable user-facing sections")
    func analyzesReusableSkillGuide() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .usageGuide))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let material = SkillUsageGuideMaterial(
            name: "humanizer-zh",
            description: "让中文表达更自然",
            documents: [
                .init(relativePath: "SKILL.md", content: "保留事实与语气，减少模板化表达。先确认用途，再完成改写。"),
            ]
        )

        let result = try await provider.analyzeSkillUsage(
            material: material,
            configuration: configuration,
            apiKey: "agnes-key"
        )

        #expect(result.value.purpose == "保留事实和原意，把生硬中文改得更自然。")
        #expect(result.value.useWhen == "已有初稿但读起来生硬；需要保留原有语气和事实")
        #expect(result.value.experienceSteps.count == 3)
        #expect(result.value.starterPrompt?.contains("保留事实") == true)
        #expect(result.value.origin == .aiAssisted)
        #expect(result.value.sourceDocuments == ["SKILL.md"])
        #expect(result.diagnostic.inputTokenCount == nil)
        #expect(result.diagnostic.outputTokenCount == nil)
    }

    @Test("Skill analysis bounds large local material before sending")
    func usageGuideUsesBoundedMaterial() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .usageGuide))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let material = SkillUsageGuideMaterial(
            name: "large-skill",
            description: String(repeating: "S", count: 2_000),
            documents: (0..<12).map {
                .init(relativePath: "references/\($0).md", content: String(repeating: "D", count: 30_000))
            }
        )

        _ = try await provider.analyzeSkillUsage(
            material: material,
            configuration: configuration,
            apiKey: "agnes-key"
        )

        let body = try #require(AIMockURLProtocol.lastRequestBody?.data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? String)
        let sent = try JSONDecoder().decode(SkillUsageGuideMaterial.self, from: Data(userContent.utf8))
        let sentCharacters = sent.name.count + sent.description.count + sent.documents.reduce(0) {
            $0 + $1.relativePath.count + $1.content.count
        }

        #expect(sentCharacters <= DiscoveryEvaluationLimits.maximumUsageGuideInputCharacters)
        #expect((payload["max_tokens"] as? Int ?? 0) <= DiscoveryEvaluationLimits.maximumUsageGuideOutputTokens)
    }

    @Test("Usage-guide material removes credentials and local absolute paths before AI can receive it")
    func usageGuideMaterialIsRedacted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAIRedactionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: example
        description: 普通功能说明
        ---
        普通内容应该保留。
        Authorization: Bearer bearer-secret-value
        api_key: sk-live-super-secret
        github_token=github_pat_verysecretvalue
        本机文件位于 /Users/alice/private/project/source.md
        -----BEGIN PRIVATE KEY-----
        private-key-secret
        -----END PRIVATE KEY-----
        """
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"))

        let material = SkillUsageGuideMaterialReader().read(
            from: root,
            name: "example",
            description: "读取 /Users/alice/private/project/source.md"
        )
        let sentText = material.description + material.documents.map(\.content).joined(separator: "\n")

        #expect(sentText.contains("普通内容应该保留"))
        #expect(!sentText.contains("bearer-secret-value"))
        #expect(!sentText.contains("sk-live-super-secret"))
        #expect(!sentText.contains("github_pat_verysecretvalue"))
        #expect(!sentText.contains("/Users/alice"))
        #expect(!sentText.contains("private-key-secret"))
        #expect(sentText.contains("[已隐藏敏感内容]") || sentText.contains("[本机路径]"))
    }

    @Test("Redaction covers inline headers, structured values, exports, JWTs and query credentials")
    func redactionCoversCommonCredentialRepresentations() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue123"
        let source = """
        curl -H "Authorization: Bearer inline-secret-value" https://example.com
        {"api_key":"json-secret-value"}
        service_token: "yaml-secret-value"
        export OPENAI_API_KEY=export-secret-value
        opaque_credential = custom-secret-value
        token: (jwt)
        https://example.com/callback?access_token=query-secret-value&mode=read
        普通功能说明应该保留。
        """

        let redacted = AIContentSanitizer.redact(source)

        for secret in [
            "inline-secret-value", "json-secret-value", "yaml-secret-value",
            "export-secret-value", "custom-secret-value", jwt, "query-secret-value",
        ] {
            #expect(!redacted.contains(secret))
        }
        #expect(redacted.contains("普通功能说明应该保留"))
    }

    @Test("Redaction covers mounted paths, file URLs and complete structured secret values")
    func redactionCoversExtendedLocalPathsAndStructuredSecrets() {
        let source = """
        项目位于 /Volumes/Client-X/private-project/source.md
        缓存位于 /private/var/customer/cache.json
        文件链接是 file:///Users/alice/private/source.md
        password: "correct horse battery staple"
        client_secret: |
          first private line
          second private line
        普通功能说明应该保留。
        """

        let redacted = AIContentSanitizer.redact(source)

        for privateValue in [
            "/Volumes/Client-X",
            "/private/var/customer",
            "file:///Users/alice",
            "correct horse battery staple",
            "first private line",
            "second private line",
        ] {
            #expect(!redacted.contains(privateValue))
        }
        #expect(redacted.contains("普通功能说明应该保留"))
    }

    @Test("Candidate evaluation redacts credentials before building the AI request")
    func candidateEvaluationRedactsCredentials() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .evaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides",
            name: "private-skill",
            summary: "普通候选说明",
            repositoryFullName: "openai/skills",
            evidence: .init(
                skillSummary: "普通候选说明",
                skillDocumentExcerpt: #"Use Authorization: Bearer candidate-secret-value"#,
                skillContentVerified: true
            )
        )

        _ = try await provider.evaluateCandidates(
            intent: .init(goal: "找一个普通 Skill"),
            candidates: [candidate],
            configuration: configuration,
            apiKey: "agnes-key"
        )

        let requestBody = try #require(AIMockURLProtocol.lastRequestBody)
        #expect(!requestBody.contains("candidate-secret-value"))
        #expect(requestBody.contains("普通候选说明"))
    }

    @Test("Unknown GitHub privacy is not treated as public content")
    func unknownRepositoryPrivacyFailsClosed() {
        #expect(AIContentSharingPolicy.canSend(
            sourceKind: .github,
            repositoryIsPrivate: false,
            allowPrivateSkillContent: false
        ))
        #expect(!AIContentSharingPolicy.canSend(
            sourceKind: .github,
            repositoryIsPrivate: nil,
            allowPrivateSkillContent: false
        ))
        #expect(!AIContentSharingPolicy.canSend(
            sourceKind: .github,
            repositoryIsPrivate: true,
            allowPrivateSkillContent: false
        ))
        #expect(AIContentSharingPolicy.canSend(
            sourceKind: .localFolder,
            repositoryIsPrivate: nil,
            allowPrivateSkillContent: true
        ))
    }

    @Test("Malformed model JSON is rejected for the local fallback")
    func malformedJSONIsRejected() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .malformed))
        let configuration = AISettings.defaults.configuration(id: "agnes")!

        do {
            _ = try await provider.planDiscovery(
                message: "找一个写作 Skill",
                previousIntent: nil,
                configuration: configuration,
                apiKey: "agnes-key"
            )
            Issue.record("损坏 JSON 不应被当作有效寻找计划")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .malformedJSON)
        }
    }

    @Test("HTTP 200 with empty final content is retried once and classified")
    func emptyContentIsClassified() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .emptyContent))
        let configuration = AISettings.defaults.configuration(id: "deepseek")!

        do {
            _ = try await provider.planDiscovery(
                message: "找一个写作 Skill",
                previousIntent: nil,
                configuration: configuration,
                apiKey: "deepseek-key"
            )
            Issue.record("空内容不应被当作成功")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .emptyContent)
            #expect(failure.diagnostic.finishReason == "stop")
            #expect(failure.diagnostic.responseLength > 0)
            #expect(failure.diagnostic.reasoningContentPresent)
            #expect(AIMockURLProtocol.requestCount == 2)
            #expect(AIMockURLProtocol.requestedMaxTokens.reduce(0, +) <= 600)
        }
    }

    @Test("finish_reason length is retried once and classified as truncated")
    func truncatedOutputIsClassified() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .truncated))
        let configuration = AISettings.defaults.configuration(id: "deepseek")!

        do {
            _ = try await provider.planDiscovery(
                message: "找一个写作 Skill",
                previousIntent: nil,
                configuration: configuration,
                apiKey: "deepseek-key"
            )
            Issue.record("截断输出不应被当作成功")
        } catch let AIServiceError.invocation(failure) {
            #expect(failure.category == .truncatedOutput)
            #expect(failure.diagnostic.finishReason == "length")
            #expect(AIMockURLProtocol.requestCount == 2)
            #expect(AIMockURLProtocol.requestedMaxTokens.reduce(0, +) <= 600)
        }
    }

    @Test("A successful planning retry shares budget and keeps partial usage honest")
    func planningRetryUsesCumulativeBudgetAndUsage() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .retryPlan))
        let configuration = AISettings.defaults.configuration(id: "deepseek")!

        let result = try await provider.planDiscovery(
            message: "找一个写作 Skill",
            previousIntent: nil,
            configuration: configuration,
            apiKey: "deepseek-key"
        )

        #expect(result.value.intent.goal == "找一个写作 Skill")
        #expect(AIMockURLProtocol.requestCount == 2)
        #expect(AIMockURLProtocol.requestedMaxTokens.reduce(0, +) <= 600)
        #expect(result.diagnostic.attemptCount == 2)
        #expect(result.diagnostic.inputTokenCount == 150)
        #expect(result.diagnostic.outputTokenCount == nil)
    }

    @Test("A successful evaluation retry stays inside the 1500-token phase budget")
    func evaluationRetryUsesCumulativeBudget() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .retryEvaluation))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let candidate = DiscoveryCandidate(
            id: "openai/skills/slides", name: "slides", summary: "Create slides",
            repositoryFullName: "openai/skills",
            evidence: .init(skillSummary: "Create slides", skillContentVerified: true)
        )

        let result = try await provider.evaluateCandidates(
            intent: .init(goal: "做演示文稿"),
            candidates: [candidate],
            configuration: configuration,
            apiKey: "agnes-key"
        )

        #expect(result.value.recommendations.map(\.candidateID) == [candidate.id])
        #expect(AIMockURLProtocol.requestCount == 2)
        #expect(AIMockURLProtocol.requestedMaxTokens.reduce(0, +) <= 1_500)
        #expect(result.diagnostic.attemptCount == 2)
        #expect(result.diagnostic.inputTokenCount == nil)
        #expect(result.diagnostic.outputTokenCount == nil)
    }

    @Test("A successful guide retry stays inside the 1200-token phase budget")
    func usageGuideRetryUsesCumulativeBudget() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .retryUsageGuide))
        let configuration = AISettings.defaults.configuration(id: "agnes")!
        let material = SkillUsageGuideMaterial(
            name: "writer",
            description: "Rewrite text",
            documents: [.init(relativePath: "SKILL.md", content: "Rewrite text naturally")]
        )

        let result = try await provider.analyzeSkillUsage(
            material: material,
            configuration: configuration,
            apiKey: "agnes-key"
        )

        #expect(result.value.purpose.contains("生硬中文"))
        #expect(AIMockURLProtocol.requestCount == 2)
        #expect(AIMockURLProtocol.requestedMaxTokens.reduce(0, +) <= 1_200)
        #expect(result.diagnostic.attemptCount == 2)
    }

    @Test("Diagnostics never retain model reasoning or raw content")
    func diagnosticsAreRedacted() async throws {
        let provider = OpenAICompatibleProvider(session: AIFixture.session(mode: .plan))
        let configuration = AISettings.defaults.configuration(id: "deepseek")!

        let result = try await provider.planDiscovery(
            message: "找一个写作 Skill",
            previousIntent: nil,
            configuration: configuration,
            apiKey: "deepseek-key"
        )

        let encoded = String(decoding: try JSONEncoder().encode(result.diagnostic), as: UTF8.self)
        #expect(!encoded.contains("hidden reasoning"))
        #expect(!encoded.contains("我想找一个能给公众号文章排版"))
        #expect(result.diagnostic.requestID == "req-plan")
    }

    @Test("AI response accumulation stops at the configured byte limit")
    func responseBodyIsBoundedWhileStreaming() throws {
        var accumulator = BoundedResponseAccumulator(limit: 4)

        try accumulator.append(contentsOf: [1, 2, 3, 4])
        #expect(accumulator.data == Data([1, 2, 3, 4]))

        do {
            try accumulator.append(5)
            Issue.record("Expected the response-size guard to reject the fifth byte")
        } catch AIServiceError.responseTooLarge {
            #expect(accumulator.data.count == 4)
        }
    }
}

private func lastSystemPrompt() throws -> String {
    let body = try #require(AIMockURLProtocol.lastRequestBody?.data(using: .utf8))
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(payload["messages"] as? [[String: Any]])
    let system = try #require(messages.first { $0["role"] as? String == "system" })
    return try #require(system["content"] as? String)
}

private final class AIMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case models, plan, evaluation, mixedUnknownEvaluation, budgetEvaluation, duplicateEvaluation, unknownOnlyEvaluation
        case usageGuide, retryPlan, retryEvaluation, retryUsageGuide, malformed, emptyContent, truncated
    }
    nonisolated(unsafe) static var mode: Mode = .models
    nonisolated(unsafe) static var lastURL: URL?
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var lastRequestBody: String?
    nonisolated(unsafe) static var requestedPaths: [String] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestedMaxTokens: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.requestedPaths.append(request.url?.path ?? "")
        Self.lastURL = request.url
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        if let body = request.httpBody {
            Self.lastRequestBody = String(decoding: body, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            Self.lastRequestBody = String(decoding: data, as: UTF8.self)
        }
        if let body = Self.lastRequestBody?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let maxTokens = object["max_tokens"] as? Int
        {
            Self.requestedMaxTokens.append(maxTokens)
        }
        let payload: String
        switch Self.mode {
        case .models:
            if request.url?.path.hasSuffix("/models") == true {
                payload = #"{"object":"list","data":[{"id":"agnes-2.5-flash"},{"id":"agnes-2.0-flash"}]}"#
            } else {
                payload = #"{"id":"req-probe","choices":[{"finish_reason":"stop","message":{"content":"{\"ok\":true}"}}]}"#
            }
        case .plan:
            payload = #"{"id":"req-plan","choices":[{"finish_reason":"stop","message":{"content":"{\"goal\":\"我想找一个能给公众号文章排版的 Skill\",\"mustHaves\":[],\"preferences\":[],\"exclusions\":[],\"queries\":[\"wechat article layout publishing\"],\"needsClarification\":false}","reasoning_content":"hidden reasoning"}}]}"#
        case .evaluation:
            payload = #"{"id":"req-eval","usage":{"prompt_tokens":321,"completion_tokens":45,"total_tokens":366},"choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"最值得先看 slides，它的用途和你的需求直接对应。\",\"recommendations\":[{\"candidateID\":\"openai/skills/slides\",\"tier\":\"recommended\",\"reason\":\"用途直接对应\"}] }"}}]}"#
        case .mixedUnknownEvaluation:
            payload = #"{"id":"req-eval","usage":{"prompt_tokens":321,"completion_tokens":45,"total_tokens":366},"choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"最值得先看 slides，它的用途和你的需求直接对应。\",\"recommendations\":[{\"candidateID\":\"openai/skills/slides\",\"tier\":\"recommended\",\"reason\":\"用途直接对应\"},{\"candidateID\":\"made-up/skill\",\"tier\":\"recommended\",\"reason\":\"虚构\"}] }"}}]}"#
        case .budgetEvaluation:
            payload = #"{"id":"req-budget-eval","usage":{"prompt_tokens":321,"completion_tokens":45,"total_tokens":366},"choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"先看 item-0。\",\"recommendations\":[{\"candidateID\":\"example/skills/item-0\",\"tier\":\"recommended\",\"reason\":\"证据完整\"}] }"}}]}"#
        case .duplicateEvaluation:
            payload = #"{"id":"req-duplicate","choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"先看 slides。\",\"recommendations\":[{\"candidateID\":\"openai/skills/slides\",\"tier\":\"recommended\",\"reason\":\"直接对应\"},{\"candidateID\":\"openai/skills/slides\",\"tier\":\"other\",\"reason\":\"重复项\"}]}"}}]}"#
        case .unknownOnlyEvaluation:
            payload = #"{"id":"req-unknown","choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"先看这个候选。\",\"recommendations\":[{\"candidateID\":\"made-up/skill\",\"tier\":\"recommended\",\"reason\":\"虚构\"}]}"}}]}"#
        case .usageGuide:
            payload = #"{"id":"req-guide","choices":[{"finish_reason":"stop","message":{"content":"{\"summary\":\"保留事实和原意，把生硬中文改得更自然。\",\"scenarios\":[\"已有初稿但读起来生硬\",\"需要保留原有语气和事实\"],\"experienceSteps\":[\"提交原文和用途\",\"确认保留项\",\"获得并检查改写稿\"],\"starterPrompt\":\"请保留事实和原意，把这篇文章改得自然、具体。\"}"}}]}"#
        case .retryPlan:
            payload = Self.requestCount == 1
                ? #"{"id":"req-plan-short","usage":{"prompt_tokens":50},"choices":[{"finish_reason":"length","message":{"content":"{\"goal\":"}}]}"#
                : #"{"id":"req-plan-retry","usage":{"prompt_tokens":100,"completion_tokens":20},"choices":[{"finish_reason":"stop","message":{"content":"{\"goal\":\"找一个写作 Skill\",\"mustHaves\":[],\"preferences\":[],\"exclusions\":[],\"queries\":[\"找一个写作 Skill\"],\"needsClarification\":false}"}}]}"#
        case .retryEvaluation:
            payload = Self.requestCount == 1
                ? #"{"id":"req-eval-short","choices":[{"finish_reason":"length","message":{"content":"{\"reply\":"}}]}"#
                : #"{"id":"req-eval-retry","usage":{"prompt_tokens":100,"completion_tokens":20},"choices":[{"finish_reason":"stop","message":{"content":"{\"reply\":\"先看 slides。\",\"recommendations\":[{\"candidateID\":\"openai/skills/slides\",\"tier\":\"recommended\",\"reason\":\"直接对应\"}]}"}}]}"#
        case .retryUsageGuide:
            payload = Self.requestCount == 1
                ? #"{"id":"req-guide-short","choices":[{"finish_reason":"length","message":{"content":"{\"summary\":"}}]}"#
                : #"{"id":"req-guide-retry","usage":{"prompt_tokens":100,"completion_tokens":20},"choices":[{"finish_reason":"stop","message":{"content":"{\"summary\":\"保留事实和原意，把生硬中文改得更自然。\",\"scenarios\":[\"已有初稿\"],\"experienceSteps\":[\"提交原文\",\"检查改写稿\"],\"starterPrompt\":\"请把这篇文章改得自然。\"}"}}]}"#
        case .malformed:
            payload = #"{"id":"req-bad","choices":[{"finish_reason":"stop","message":{"content":"这不是 JSON"}}]}"#
        case .emptyContent:
            payload = #"{"id":"req-empty","choices":[{"finish_reason":"stop","message":{"content":"","reasoning_content":"internal thinking"}}]}"#
        case .truncated:
            payload = #"{"id":"req-short","choices":[{"finish_reason":"length","message":{"content":"{\"goal\":"}}]}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum AIFixture {
    static func session(mode: AIMockURLProtocol.Mode) -> URLSession {
        AIMockURLProtocol.mode = mode
        AIMockURLProtocol.lastURL = nil
        AIMockURLProtocol.lastAuthorization = nil
        AIMockURLProtocol.lastRequestBody = nil
        AIMockURLProtocol.requestedPaths = []
        AIMockURLProtocol.requestCount = 0
        AIMockURLProtocol.requestedMaxTokens = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
