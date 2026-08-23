import Foundation
import Security

public enum AIProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case agnes
    case deepSeek
    case kimi
    case miniMax
    case glm
    case custom
}

public struct AIProviderConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: AIProviderKind
    public var displayName: String
    public var baseURL: String
    public var model: String

    public init(id: String, kind: AIProviderKind, displayName: String, baseURL: String, model: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
    }

    public var recommendedModels: [String] {
        switch kind {
        case .agnes:
            ["agnes-2.5-flash", "agnes-2.0-flash", "agnes-1.5-flash"]
        case .deepSeek:
            ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .kimi:
            ["kimi-k2.6", "kimi-k2.5"]
        case .miniMax:
            ["MiniMax-M2.7", "MiniMax-M2.7-highspeed"]
        case .glm:
            ["glm-5.3", "glm-5"]
        case .custom:
            model.isEmpty ? [] : [model]
        }
    }

    public var apiKeyPage: URL? {
        switch kind {
        case .agnes: URL(string: "https://platform.agnes-ai.com/settings/apiKeys")
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")
        case .kimi: URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .miniMax: URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        case .glm: URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")
        case .custom: nil
        }
    }

    public var capabilities: AIProviderCapabilities {
        switch kind {
        case .agnes:
            .init(supportsJSONMode: true, supportsThinkingControl: false)
        case .deepSeek:
            .init(supportsJSONMode: true, supportsThinkingControl: true)
        case .kimi, .miniMax, .glm:
            .init(supportsJSONMode: true, supportsThinkingControl: false)
        case .custom:
            .init(supportsJSONMode: false, supportsThinkingControl: false)
        }
    }
}

public struct AIProviderCapabilities: Codable, Hashable, Sendable {
    public var supportsJSONMode: Bool
    public var supportsThinkingControl: Bool

    public init(supportsJSONMode: Bool, supportsThinkingControl: Bool) {
        self.supportsJSONMode = supportsJSONMode
        self.supportsThinkingControl = supportsThinkingControl
    }
}

public struct AIProviderConnectionVerification: Codable, Hashable, Sendable {
    public var providerID: String
    public var baseURL: String
    public var model: String
    public var verifiedAt: Date

    public init(providerID: String, baseURL: String, model: String, verifiedAt: Date) {
        self.providerID = providerID
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.verifiedAt = verifiedAt
    }

    public func matches(_ configuration: AIProviderConfiguration) -> Bool {
        providerID == configuration.id
            && baseURL == configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            && model == configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AIPrivateContentConsent: Codable, Hashable, Sendable {
    public var providerID: String
    public var baseURL: String
    public var model: String

    public init(configuration: AIProviderConfiguration) {
        providerID = configuration.id
        baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(_ configuration: AIProviderConfiguration) -> Bool {
        providerID == configuration.id
            && baseURL == configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            && model == configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AISettings: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var isEnabled: Bool
    public var selectedProviderID: String
    public var configurations: [AIProviderConfiguration]
    public var allowPrivateSkillContent: Bool
    public var privateContentConsent: AIPrivateContentConsent?
    public var connectionVerifications: [AIProviderConnectionVerification]?

    public init(
        schemaVersion: Int = 1,
        isEnabled: Bool = false,
        selectedProviderID: String = "agnes",
        configurations: [AIProviderConfiguration],
        allowPrivateSkillContent: Bool = false,
        privateContentConsent: AIPrivateContentConsent? = nil,
        connectionVerifications: [AIProviderConnectionVerification]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.selectedProviderID = selectedProviderID
        self.configurations = configurations
        self.allowPrivateSkillContent = allowPrivateSkillContent
        self.privateContentConsent = privateContentConsent
        self.connectionVerifications = connectionVerifications
    }

    public static let defaults = AISettings(configurations: [
        .init(
            id: "agnes",
            kind: .agnes,
            displayName: "Agnes",
            baseURL: "https://apihub.agnes-ai.com/v1",
            model: "agnes-2.5-flash"
        ),
        .init(
            id: "deepseek",
            kind: .deepSeek,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash"
        ),
        .init(
            id: "kimi",
            kind: .kimi,
            displayName: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            model: "kimi-k2.6"
        ),
        .init(
            id: "minimax",
            kind: .miniMax,
            displayName: "MiniMax",
            baseURL: "https://api.minimaxi.com/v1",
            model: "MiniMax-M2.7"
        ),
        .init(
            id: "glm",
            kind: .glm,
            displayName: "GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            model: "glm-5.3"
        ),
        .init(
            id: "custom",
            kind: .custom,
            displayName: "自定义 API",
            baseURL: "",
            model: ""
        ),
    ])

    public func configuration(id: String) -> AIProviderConfiguration? {
        configurations.first { $0.id == id }
    }

    public var selectedConfiguration: AIProviderConfiguration? {
        configuration(id: selectedProviderID)
    }

    /// The only configuration that may receive a stored API key. Callers must
    /// use this value at the request boundary instead of trusting UI state.
    public var selectedVerifiedConfiguration: AIProviderConfiguration? {
        guard isEnabled,
              let configuration = selectedConfiguration,
              isConnectionVerified(providerID: configuration.id)
        else { return nil }
        return configuration
    }

    public var isPrivateContentSharingAllowedForSelectedProvider: Bool {
        guard allowPrivateSkillContent,
              let configuration = selectedConfiguration,
              privateContentConsent?.matches(configuration) == true
        else { return false }
        return true
    }

    public mutating func setPrivateContentSharingAllowed(_ allowed: Bool) {
        guard allowed, let configuration = selectedConfiguration else {
            invalidatePrivateContentConsent()
            return
        }
        allowPrivateSkillContent = true
        privateContentConsent = .init(configuration: configuration)
    }

    public mutating func invalidatePrivateContentConsent() {
        allowPrivateSkillContent = false
        privateContentConsent = nil
    }

    public func isConnectionVerified(providerID: String) -> Bool {
        guard let configuration = configuration(id: providerID) else { return false }
        return connectionVerifications?.contains { $0.matches(configuration) } == true
    }

    public mutating func markConnectionVerified(providerID: String, at date: Date = Date()) {
        guard let configuration = configuration(id: providerID) else { return }
        var values = connectionVerifications ?? []
        values.removeAll { $0.providerID == providerID }
        values.append(.init(
            providerID: providerID,
            baseURL: configuration.baseURL,
            model: configuration.model,
            verifiedAt: date
        ))
        connectionVerifications = values
    }

    public mutating func invalidateConnectionVerification(providerID: String) {
        connectionVerifications?.removeAll { $0.providerID == providerID }
    }

    /// Adds providers introduced by newer SkillBox versions. Built-in provider
    /// identities and endpoints stay pinned; only their selected model is user-editable.
    public func mergedWithCurrentProviders() -> AISettings {
        var merged = self
        let existing = configurations.reduce(into: [String: AIProviderConfiguration]()) { result, configuration in
            if result[configuration.id] == nil { result[configuration.id] = configuration }
        }
        let currentIDs = Set(Self.defaults.configurations.map(\.id))
        merged.configurations = Self.defaults.configurations.map { current in
            guard let saved = existing[current.id] else { return current }
            guard current.kind != .custom else { return saved }
            var pinned = current
            let selectedModel = saved.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedModel.isEmpty { pinned.model = selectedModel }
            return pinned
        }
        merged.configurations.append(contentsOf: configurations.filter { !currentIDs.contains($0.id) })
        if merged.configuration(id: merged.selectedProviderID) == nil {
            merged.selectedProviderID = Self.defaults.selectedProviderID
        }
        if merged.allowPrivateSkillContent,
           !merged.isPrivateContentSharingAllowedForSelectedProvider
        {
            merged.invalidatePrivateContentConsent()
        }
        return merged
    }
}

public actor AISettingsStore {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("ai-settings.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() -> AISettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? decoder.decode(AISettings.self, from: data),
              settings.schemaVersion == 1
        else { return .defaults }
        return settings.mergedWithCurrentProviders()
    }

    public func save(_ settings: AISettings) throws {
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
    }
}

public protocol AIKeyStore: Sendable {
    func load(providerID: String) async throws -> String?
    func save(_ apiKey: String, providerID: String) async throws
    func delete(providerID: String) async throws
}

public actor KeychainAIKeyStore: AIKeyStore {
    private let service: String

    public init(service: String = "com.zhaoji.skillbox.ai-provider") {
        self.service = service
    }

    public func load(providerID: String) throws -> String? {
        let query = KeychainCredentialAccessPolicy.automaticReadQuery(service: service, account: providerID)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { throw AIServiceError.keychain(status) }
        return value
    }

    public func save(_ apiKey: String, providerID: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIServiceError.missingAPIKey }
        let data = Data(value.utf8)
        let status = KeychainCredentialAccessPolicy.save(data, service: service, account: providerID)
        guard status == errSecSuccess else { throw AIServiceError.keychain(status) }
    }

    public func delete(providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIServiceError.keychain(status)
        }
    }
}

public enum AIInvocationErrorCategory: String, Codable, Hashable, Sendable {
    case networkFailure
    case authenticationFailure
    case rateLimited
    case serviceFailure
    case emptyContent
    case truncatedOutput
    case malformedJSON
    case schemaValidationFailed
}

public struct AIInvocationDiagnostic: Codable, Hashable, Sendable {
    public var providerID: String
    public var model: String
    public var httpStatus: Int?
    public var finishReason: String?
    public var responseLength: Int
    public var requestID: String?
    public var errorCategory: AIInvocationErrorCategory?
    public var reasoningContentPresent: Bool
    public var requestBodyBytesSent: Int?
    public var inputTokenCount: Int?
    public var outputTokenCount: Int?
    public var durationMilliseconds: Int?
    public var attemptCount: Int?
    public var inputItemCount: Int?

    public init(
        providerID: String,
        model: String,
        httpStatus: Int? = nil,
        finishReason: String? = nil,
        responseLength: Int = 0,
        requestID: String? = nil,
        errorCategory: AIInvocationErrorCategory? = nil,
        reasoningContentPresent: Bool = false,
        requestBodyBytesSent: Int? = nil,
        inputTokenCount: Int? = nil,
        outputTokenCount: Int? = nil,
        durationMilliseconds: Int? = nil,
        attemptCount: Int? = nil,
        inputItemCount: Int? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.httpStatus = httpStatus
        self.finishReason = finishReason
        self.responseLength = responseLength
        self.requestID = requestID
        self.errorCategory = errorCategory
        self.reasoningContentPresent = reasoningContentPresent
        self.requestBodyBytesSent = requestBodyBytesSent
        self.inputTokenCount = inputTokenCount
        self.outputTokenCount = outputTokenCount
        self.durationMilliseconds = durationMilliseconds
        self.attemptCount = attemptCount
        self.inputItemCount = inputItemCount
    }
}

public struct AIInvocationFailure: LocalizedError, Sendable {
    public var category: AIInvocationErrorCategory
    public var diagnostic: AIInvocationDiagnostic

    public init(category: AIInvocationErrorCategory, diagnostic: AIInvocationDiagnostic) {
        self.category = category
        self.diagnostic = diagnostic
    }

    public var errorDescription: String? {
        switch category {
        case .networkFailure: "无法连接模型服务，请检查网络后重试"
        case .authenticationFailure: "API Key 无效，或当前账号没有访问这个模型的权限"
        case .rateLimited: "这个模型暂时达到使用限制，请稍后再试"
        case .serviceFailure: "模型服务暂时无法完成请求"
        case .emptyContent: "模型没有返回最终结果"
        case .truncatedOutput: "模型结果没有完整返回"
        case .malformedJSON: "模型返回的结构无法读取"
        case .schemaValidationFailed: "模型结果缺少 SkillBox 需要的信息"
        }
    }
}

public enum AIServiceError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidConfiguration
    case insecureEndpoint
    case requestFailed(Int)
    case responseTooLarge
    case invalidResponse
    case invocation(AIInvocationFailure)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先保存这个服务商的 API Key"
        case .invalidConfiguration: "模型名称或接口地址还没有填写完整"
        case .insecureEndpoint: "自定义接口需要使用 HTTPS；本机 localhost 可以使用 HTTP"
        case let .requestFailed(status):
            switch status {
            case 401, 403: "API Key 无效，或当前账号没有访问这个模型的权限"
            case 404: "没有找到这个模型或接口，请检查模型名称和接口地址"
            case 429: "这个模型暂时达到使用限制，请稍后再试"
            default: "模型服务暂时无法完成请求（错误码 \(status)）"
            }
        case .responseTooLarge: "模型返回的内容超过 SkillBox 的读取上限"
        case .invalidResponse: "模型返回了无法识别的内容"
        case let .invocation(failure): failure.errorDescription
        case .keychain: "无法访问 macOS 钥匙串"
        }
    }
}

public struct AIInvocationResult<Value: Sendable>: Sendable {
    public var value: Value
    public var diagnostics: [AIInvocationDiagnostic]

    public init(value: Value, diagnostics: [AIInvocationDiagnostic]) {
        self.value = value
        self.diagnostics = diagnostics
    }

    public var diagnostic: AIInvocationDiagnostic {
        diagnostics.last ?? .init(providerID: "unknown", model: "unknown")
    }
}

public struct AIConnectionTestResult: Sendable {
    public var models: [String]
    public var diagnostic: AIInvocationDiagnostic

    public init(models: [String], diagnostic: AIInvocationDiagnostic) {
        self.models = models
        self.diagnostic = diagnostic
    }
}

public protocol AIProvider: Sendable {
    func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws -> AIConnectionTestResult
    func planDiscovery(message: String, previousIntent: DiscoveryIntent?, configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<DiscoveryPlan>
    func evaluateCandidates(intent: DiscoveryIntent, candidates: [DiscoveryCandidate], configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<DiscoveryEvaluation>
    func analyzeSkillUsage(material: SkillUsageGuideMaterial, configuration: AIProviderConfiguration, apiKey: String) async throws -> AIInvocationResult<SkillUsageGuide>
}

struct BoundedResponseAccumulator {
    private(set) var data = Data()
    let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
        data.reserveCapacity(min(self.limit, 64 * 1_024))
    }

    mutating func append(_ byte: UInt8) throws {
        guard data.count < limit else { throw AIServiceError.responseTooLarge }
        data.append(byte)
    }

    mutating func append(contentsOf bytes: some Sequence<UInt8>) throws {
        for byte in bytes {
            try append(byte)
        }
    }
}

public struct OpenAICompatibleProvider: AIProvider, Sendable {
    private let session: URLSession
    private let maximumResponseBytes = 2 * 1_024 * 1_024

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func testConnection(configuration: AIProviderConfiguration, apiKey: String) async throws -> AIConnectionTestResult {
        let url = try endpoint(configuration: configuration, path: "models")
        let modelResult = try await request(url: url, method: "GET", configuration: configuration, apiKey: apiKey, body: nil)
        guard let response = try? JSONDecoder().decode(ModelListResponse.self, from: modelResult.data) else {
            throw invocationFailure(.malformedJSON, configuration: configuration, httpStatus: modelResult.http.statusCode, responseLength: modelResult.data.count)
        }
        let probe: AIInvocationResult<StructuredProbeResponse> = try await performStructuredRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: [
                .init(role: "system", content: "只输出 JSON 对象。格式示例：{\"ok\":true}"),
                .init(role: "user", content: "返回 ok=true"),
            ],
            initialMaxTokens: 100,
            totalOutputTokenBudget: 160,
            inputItemCount: 1
        )
        guard probe.value.ok else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: probe.diagnostic)
        }
        return .init(models: response.data.map(\.id), diagnostic: probe.diagnostic)
    }

    public func planDiscovery(
        message: String,
        previousIntent: DiscoveryIntent?,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryPlan> {
        let input = String(
            AIContentSanitizer.redact(message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(DiscoveryEvaluationLimits.maximumPlanningInputCharacters)
        )
        guard !input.isEmpty else { throw AIServiceError.invalidConfiguration }
        let previous = previousIntent.map {
            String("当前目标：\(AIContentSanitizer.redact($0.goal))\n必要条件：\($0.mustHaves.map(AIContentSanitizer.redact).joined(separator: "、"))\n偏好：\($0.preferences.map(AIContentSanitizer.redact).joined(separator: "、"))\n排除：\($0.exclusions.map(AIContentSanitizer.redact).joined(separator: "、"))".prefix(2_000))
        } ?? "当前没有既有寻找目标"
        let response: AIInvocationResult<DiscoveryPlanResponse> = try await performStructuredRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: [
                .init(
                    role: "system",
                    content: """
                    你只负责帮助用户寻找 AI Agent Skill。把最新消息整理为 JSON。用户明显切换任务时替换 goal；“太少、质量不好、知名的没找到”等反馈只更新 preferences，不得成为 goal 或 query。无法确认的专有名词只追问一个问题。queries 最多 3 条，只包含中文同义词、英文行业词或常见能力名，不重复原始 goal。
                    必须严格采用这个结构：
                    {"goal":"用户当前目标","mustHaves":[],"preferences":[],"exclusions":[],"queries":["english term"],"needsClarification":false,"clarifyingQuestion":null}
                    不要解释，不要 Markdown。
                    """
                ),
                .init(role: "user", content: "\(previous)\n最新消息：\(input)"),
            ],
            initialMaxTokens: 400,
            totalOutputTokenBudget: DiscoveryEvaluationLimits.maximumPlanningOutputTokens,
            inputItemCount: 1
        )
        let planResponse = response.value
        let goal = planResponse.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: response.diagnostic)
        }
        var queries = [goal]
        for query in planResponse.queries.prefix(3) {
            let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !queries.contains(cleaned) { queries.append(cleaned) }
        }
        return .init(
            value: DiscoveryPlan(
                intent: .init(goal: goal, mustHaves: planResponse.mustHaves, preferences: planResponse.preferences, exclusions: planResponse.exclusions),
                queries: queries,
                needsClarification: planResponse.needsClarification,
                clarifyingQuestion: planResponse.clarifyingQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            diagnostics: response.diagnostics
        )
    }

    public func evaluateCandidates(
        intent: DiscoveryIntent,
        candidates: [DiscoveryCandidate],
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<DiscoveryEvaluation> {
        let limitedCandidates = Array(candidates.prefix(DiscoveryEvaluationLimits.maximumCandidates))
        guard !limitedCandidates.isEmpty else { throw AIServiceError.invalidConfiguration }
        var remainingEvidenceCharacters = DiscoveryEvaluationLimits.maximumEvidenceCharacters
        func consume(_ value: String?, preferredLimit: Int) -> String? {
            guard remainingEvidenceCharacters > 0,
                  let value = value.map(AIContentSanitizer.redact)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            let limit = min(preferredLimit, remainingEvidenceCharacters)
            let result = String(value.prefix(limit))
            remainingEvidenceCharacters -= result.count
            return result
        }
        let boundedIntent = DiscoveryIntent(
            goal: AIContentSanitizer.redact(String(intent.goal.prefix(1_000))),
            mustHaves: intent.mustHaves.prefix(8).map { AIContentSanitizer.redact(String($0.prefix(240))) },
            preferences: intent.preferences.prefix(8).map { AIContentSanitizer.redact(String($0.prefix(240))) },
            exclusions: intent.exclusions.prefix(8).map { AIContentSanitizer.redact(String($0.prefix(240))) }
        )
        let evidence = limitedCandidates.map { candidate in
            DiscoveryEvaluationCandidate(
                id: String(candidate.id.prefix(300)),
                name: String(candidate.name.prefix(160)),
                skillSummary: consume(candidate.userFacingSummary, preferredLimit: 240) ?? "",
                installs: candidate.installCount,
                repositoryStars: candidate.repositoryStars,
                repositoryUpdatedAt: candidate.repositoryUpdatedAt,
                contentVerified: candidate.evidence.skillContentVerified,
                skillDocumentExcerpt: consume(candidate.evidence.skillDocumentExcerpt, preferredLimit: 640),
                repositorySummary: consume(candidate.repositorySummary, preferredLimit: 120)
            )
        }
        let input = DiscoveryEvaluationInput(intent: boundedIntent, candidates: evidence)
        let response: AIInvocationResult<DiscoveryEvaluationResponse> = try await performStructuredRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: [
                .init(role: "system", content: """
                    你只比较输入中已经核验的 candidate id。热度不能替代用途匹配，检测型 Skill 不能因为热门就被当成改写型 Skill。不要虚构文件、能力或候选。
                    这一步只做相关性判断。根据 skillSummary 和 skillDocumentExcerpt 判断候选是否直接满足目标；repositorySummary 只是来源补充，不能替代 Skill 本体证据。理由只写一句。
                    必须严格采用这个结构：
                    {"reply":"自然中文短回复","recommendations":[{"candidateID":"真实 id","tier":"recommended","reason":"一句相关性理由"}]}
                    tier 只能是 recommended 或 other。reply 使用 2 至 4 个短段落、最多 220 个中文字，不重复右侧详情；没有可靠候选就如实说明。不要 Markdown。
                    """),
                .init(role: "user", content: String(decoding: try JSONEncoder().encode(input), as: UTF8.self)),
            ],
            initialMaxTokens: 1_000,
            totalOutputTokenBudget: DiscoveryEvaluationLimits.maximumOutputTokens,
            inputItemCount: limitedCandidates.count
        )
        let decoded = response.value
        let validIDs = Set(limitedCandidates.map(\.id))
        var seenCandidateIDs = Set<String>()
        var containsDuplicateCandidateID = false
        var containsInvalidRecommendation = false
        let recommendations = decoded.recommendations.compactMap { item -> DiscoveryRecommendation? in
            guard validIDs.contains(item.candidateID), let tier = DiscoveryCandidateTier(rawValue: item.tier) else {
                containsInvalidRecommendation = true
                return nil
            }
            guard seenCandidateIDs.insert(item.candidateID).inserted else {
                containsDuplicateCandidateID = true
                return nil
            }
            return .init(candidateID: item.candidateID, tier: tier, reason: String(item.reason.prefix(240)))
        }
        guard !containsInvalidRecommendation, !containsDuplicateCandidateID, !recommendations.isEmpty else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: response.diagnostic)
        }
        let reply = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply.count <= 500 else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: response.diagnostic)
        }
        return .init(value: .init(reply: reply, recommendations: recommendations), diagnostics: response.diagnostics)
    }

    public func analyzeSkillUsage(
        material: SkillUsageGuideMaterial,
        configuration: AIProviderConfiguration,
        apiKey: String
    ) async throws -> AIInvocationResult<SkillUsageGuide> {
        let boundedMaterial = Self.boundedUsageGuideMaterial(material)
        guard !boundedMaterial.documents.isEmpty else { throw AIServiceError.invalidConfiguration }
        let response: AIInvocationResult<SkillUsageGuideResponse> = try await performStructuredRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: [
                .init(role: "system", content: """
                    你只负责把一个 AI Agent Skill 解释给普通用户。依据输入的真实文件，用简短自然的中文一次写清四件事：Skill 简要说明、适用场景、体验流程、提示词参考。
                    简要说明要同时写清特色和真正有用的技巧；适用场景写用户会遇到的具体情境；体验流程只写用户能感受到的 2 至 5 步；提示词必须可以直接复制给 AI。
                    不复述内部规则、文件结构、技术术语或安全检查，不写“作者未说明”，不夸大没有证据的能力，不填充废话。若资料不完整，只写能从 Skill 内容合理确认的部分。
                    必须严格采用这个结构：
                    {"summary":"不超过180个中文字","scenarios":["场景"],"experienceSteps":["步骤"],"starterPrompt":"可直接复制的话"}
                    不要 Markdown，不要输出其他字段。
                    """),
                .init(role: "user", content: String(decoding: try JSONEncoder().encode(boundedMaterial), as: UTF8.self)),
            ],
            initialMaxTokens: 900,
            totalOutputTokenBudget: DiscoveryEvaluationLimits.maximumUsageGuideOutputTokens,
            inputItemCount: boundedMaterial.documents.count
        )
        let value = response.value
        let summary = value.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let scenarios = value.scenarios.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let steps = value.experienceSteps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let prompt = value.starterPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 360,
              !scenarios.isEmpty, !steps.isEmpty, !prompt.isEmpty
        else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: response.diagnostic)
        }
        return .init(
            value: .init(
                purpose: summary,
                useWhen: scenarios.prefix(5).joined(separator: "；"),
                starterPrompt: prompt,
                experienceSteps: Array(steps.prefix(5)),
                origin: .aiAssisted,
                sourceDocuments: boundedMaterial.documents.map(\.relativePath)
            ),
            diagnostics: response.diagnostics
        )
    }

    private func performStructuredRequest<T: Decodable & Sendable>(
        configuration: AIProviderConfiguration,
        apiKey: String,
        messages: [ChatRequest.Message],
        initialMaxTokens: Int,
        totalOutputTokenBudget: Int? = nil,
        inputItemCount: Int? = nil
    ) async throws -> AIInvocationResult<T> {
        let url = try endpoint(configuration: configuration, path: "chat/completions")
        let outputBudget = max(1, totalOutputTokenBudget ?? initialMaxTokens)
        var maxTokens = min(initialMaxTokens, outputBudget)
        var remainingOutputBudget = outputBudget
        var requestBodyBytesSent = 0
        var inputTokenCount = 0
        var outputTokenCount = 0
        var completeInputTokenUsage = true
        var completeOutputTokenUsage = true
        var durationMilliseconds = 0
        let requestMessages = configuration.capabilities.supportsJSONMode
            ? Self.messagesExplicitlyRequestingJSON(messages)
            : messages
        for attempt in 0...1 {
            guard remainingOutputBudget > 0 else { throw AIServiceError.invalidResponse }
            maxTokens = min(maxTokens, remainingOutputBudget)
            remainingOutputBudget -= maxTokens
            let payload = ChatRequest(
                model: configuration.model,
                messages: requestMessages,
                maxTokens: maxTokens,
                responseFormat: configuration.capabilities.supportsJSONMode ? .init(type: "json_object") : nil,
                thinking: configuration.capabilities.supportsThinkingControl ? .init(type: "disabled") : nil
            )
            let body = try JSONEncoder().encode(payload)
            requestBodyBytesSent += body.count
            let startedAt = Date()
            let networkResult: HTTPResult
            do {
                networkResult = try await request(url: url, method: "POST", configuration: configuration, apiKey: apiKey, body: body)
            } catch let AIServiceError.invocation(failure) {
                completeInputTokenUsage = false
                completeOutputTokenUsage = false
                durationMilliseconds += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                var diagnostic = failure.diagnostic
                diagnostic.requestBodyBytesSent = requestBodyBytesSent
                diagnostic.inputTokenCount = nil
                diagnostic.outputTokenCount = nil
                diagnostic.durationMilliseconds = durationMilliseconds
                diagnostic.attemptCount = attempt + 1
                diagnostic.inputItemCount = inputItemCount
                throw AIServiceError.invocation(.init(category: failure.category, diagnostic: diagnostic))
            }
            durationMilliseconds += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            guard let response = try? JSONDecoder().decode(ChatResponse.self, from: networkResult.data),
                  let choice = response.choices.first
            else {
                throw invocationFailure(.malformedJSON, configuration: configuration, diagnostic: .init(
                    providerID: configuration.id,
                    model: configuration.model,
                    httpStatus: networkResult.http.statusCode,
                    responseLength: networkResult.data.count,
                    requestID: networkResult.requestID,
                    requestBodyBytesSent: requestBodyBytesSent,
                    durationMilliseconds: durationMilliseconds,
                    attemptCount: attempt + 1,
                    inputItemCount: inputItemCount
                ))
            }
            if let promptTokens = response.usage?.promptTokens { inputTokenCount += promptTokens }
            else { completeInputTokenUsage = false }
            if let completionTokens = response.usage?.completionTokens { outputTokenCount += completionTokens }
            else { completeOutputTokenUsage = false }
            var diagnostic = AIInvocationDiagnostic(
                providerID: configuration.id,
                model: configuration.model,
                httpStatus: networkResult.http.statusCode,
                finishReason: choice.finishReason,
                responseLength: networkResult.data.count,
                requestID: response.id ?? networkResult.requestID,
                reasoningContentPresent: !(choice.message.reasoningContent?.isEmpty ?? true),
                requestBodyBytesSent: requestBodyBytesSent,
                inputTokenCount: completeInputTokenUsage ? inputTokenCount : nil,
                outputTokenCount: completeOutputTokenUsage ? outputTokenCount : nil,
                durationMilliseconds: durationMilliseconds,
                attemptCount: attempt + 1,
                inputItemCount: inputItemCount
            )
            if choice.finishReason == "length" {
                diagnostic.errorCategory = .truncatedOutput
                if attempt == 0, remainingOutputBudget > 0 {
                    maxTokens = remainingOutputBudget
                    continue
                }
                throw AIServiceError.invocation(.init(category: .truncatedOutput, diagnostic: diagnostic))
            }
            guard let content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                diagnostic.errorCategory = .emptyContent
                if attempt == 0, remainingOutputBudget > 0 {
                    maxTokens = remainingOutputBudget
                    continue
                }
                throw AIServiceError.invocation(.init(category: .emptyContent, diagnostic: diagnostic))
            }
            let value: T = try decodeJSONObject(content, configuration: configuration, diagnostic: diagnostic)
            return .init(value: value, diagnostics: [diagnostic])
        }
        throw AIServiceError.invalidResponse
    }

    private static func messagesExplicitlyRequestingJSON(_ messages: [ChatRequest.Message]) -> [ChatRequest.Message] {
        guard let systemIndex = messages.firstIndex(where: { $0.role == "system" }) else {
            return [.init(role: "system", content: "请严格输出 json 格式的对象，不要输出其他内容。")]
                + messages
        }
        guard !messages[systemIndex].content.localizedCaseInsensitiveContains("json") else { return messages }
        var updated = messages
        updated[systemIndex].content += "\n请严格输出 json 格式的对象，不要输出其他内容。"
        return updated
    }

    private static func boundedUsageGuideMaterial(_ material: SkillUsageGuideMaterial) -> SkillUsageGuideMaterial {
        let material = AIContentSanitizer.sanitize(material)
        var remaining = DiscoveryEvaluationLimits.maximumUsageGuideInputCharacters
        func consume(_ value: String, limit: Int) -> String {
            guard remaining > 0 else { return "" }
            let result = String(value.prefix(min(limit, remaining)))
            remaining -= result.count
            return result
        }
        let name = consume(material.name, limit: 160)
        let description = consume(material.description, limit: 600)
        var documents: [SkillUsageGuideDocument] = []
        for document in material.documents.prefix(8) where remaining > 0 {
            let relativePath = consume(document.relativePath, limit: 240)
            let content = consume(document.content, limit: remaining)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            documents.append(.init(relativePath: relativePath, content: content))
        }
        return .init(name: name, description: description, documents: documents)
    }

    private func decodeJSONObject<T: Decodable>(
        _ content: String,
        configuration: AIProviderConfiguration,
        diagnostic: AIInvocationDiagnostic
    ) throws -> T {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw invocationFailure(.malformedJSON, configuration: configuration, diagnostic: diagnostic)
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw invocationFailure(.schemaValidationFailed, configuration: configuration, diagnostic: diagnostic)
        }
        return decoded
    }

    private func endpoint(configuration: AIProviderConfiguration, path: String) throws -> URL {
        let base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: base),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { throw AIServiceError.invalidConfiguration }
        let localHosts = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && localHosts.contains(host)) else {
            throw AIServiceError.insecureEndpoint
        }
        return url.appendingPathComponent(path)
    }

    private struct HTTPResult {
        var data: Data
        var http: HTTPURLResponse
        var requestID: String?
    }

    private func request(
        url: URL,
        method: String,
        configuration: AIProviderConfiguration,
        apiKey: String,
        body: Data?
    ) async throws -> HTTPResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIServiceError.missingAPIKey }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            if receivedResponse.expectedContentLength > Int64(maximumResponseBytes) {
                throw AIServiceError.responseTooLarge
            }
            var accumulator = BoundedResponseAccumulator(limit: maximumResponseBytes)
            for try await byte in bytes {
                try Task.checkCancellation()
                try accumulator.append(byte)
            }
            data = accumulator.data
            response = receivedResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw invocationFailure(.networkFailure, configuration: configuration)
        }
        guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let category: AIInvocationErrorCategory
            switch http.statusCode {
            case 401, 403: category = .authenticationFailure
            case 429: category = .rateLimited
            default: category = .serviceFailure
            }
            throw invocationFailure(category, configuration: configuration, httpStatus: http.statusCode, responseLength: data.count, requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
        return .init(data: data, http: http, requestID: http.value(forHTTPHeaderField: "x-request-id"))
    }

    private func invocationFailure(
        _ category: AIInvocationErrorCategory,
        configuration: AIProviderConfiguration,
        httpStatus: Int? = nil,
        responseLength: Int = 0,
        requestID: String? = nil
    ) -> AIServiceError {
        .invocation(.init(
            category: category,
            diagnostic: .init(
                providerID: configuration.id,
                model: configuration.model,
                httpStatus: httpStatus,
                responseLength: responseLength,
                requestID: requestID,
                errorCategory: category
            )
        ))
    }

    private func invocationFailure(
        _ category: AIInvocationErrorCategory,
        configuration: AIProviderConfiguration,
        diagnostic: AIInvocationDiagnostic
    ) -> AIServiceError {
        var updated = diagnostic
        updated.errorCategory = category
        return .invocation(.init(category: category, diagnostic: updated))
    }
}

private struct DiscoveryPlanResponse: Decodable {
    var goal: String
    var mustHaves: [String] = []
    var preferences: [String] = []
    var exclusions: [String] = []
    var queries: [String] = []
    var needsClarification: Bool = false
    var clarifyingQuestion: String?

    private enum CodingKeys: String, CodingKey { case goal, mustHaves, preferences, exclusions, queries, needsClarification, clarifyingQuestion }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        goal = try values.decode(String.self, forKey: .goal)
        mustHaves = try values.decodeIfPresent([String].self, forKey: .mustHaves) ?? []
        preferences = try values.decodeIfPresent([String].self, forKey: .preferences) ?? []
        exclusions = try values.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        queries = try values.decodeIfPresent([String].self, forKey: .queries) ?? []
        needsClarification = try values.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        clarifyingQuestion = try values.decodeIfPresent(String.self, forKey: .clarifyingQuestion)
    }
}

private struct DiscoveryEvaluationInput: Encodable { var intent: DiscoveryIntent; var candidates: [DiscoveryEvaluationCandidate] }
private struct DiscoveryEvaluationCandidate: Encodable {
    var id: String; var name: String; var skillSummary: String; var installs: Int?; var repositoryStars: Int?; var repositoryUpdatedAt: Date?; var contentVerified: Bool; var skillDocumentExcerpt: String?; var repositorySummary: String?
}
private struct DiscoveryEvaluationResponse: Decodable {
    struct Item: Decodable {
        var candidateID: String; var tier: String; var reason: String
    }
    var reply: String
    var recommendations: [Item]
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable { var id: String }
    var data: [Model]
}

private struct StructuredProbeResponse: Decodable, Sendable { var ok: Bool }

private struct SkillUsageGuideResponse: Decodable, Sendable {
    var summary: String
    var scenarios: [String]
    var experienceSteps: [String]
    var starterPrompt: String
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }
    var model: String
    var messages: [Message]
    var maxTokens: Int
    var responseFormat: ResponseFormat?
    var thinking: Thinking?

    struct ResponseFormat: Encodable { var type: String }
    struct Thinking: Encodable { var type: String }

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case thinking
    }
}

private struct ChatResponse: Decodable {
    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
            var reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }
        var message: Message
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    var id: String?
    var choices: [Choice]
    var usage: Usage?
}
