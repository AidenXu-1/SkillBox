import Foundation

public struct DiscoveryQueuedMessage: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var text: String
    public init(text: String) { self.text = text }
}

public struct DiscoveryConversationReference: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var repository: String
    public var summary: String
    public var excerpt: String
    public init(candidate: DiscoveryCandidate) {
        id = String(candidate.id.prefix(250))
        name = String(candidate.name.prefix(100))
        repository = String(candidate.repositoryFullName.prefix(160))
        summary = String(AIContentSanitizer.redact(candidate.evidence.skillSummary ?? "暂无核验摘要").prefix(500))
        excerpt = String(AIContentSanitizer.redact(candidate.evidence.skillDocumentExcerpt ?? "").prefix(1_500))
    }
}

public enum DiscoveryConversationAction: Sendable, Equatable {
    case search
    case compare
    case explain
    case acknowledge
    case removeConstraint(String)
}

public struct DiscoveryConversationReply: Codable, Sendable {
    public var text: String
    public var citedIDs: [String]
    public init(text: String, citedIDs: [String]) { self.text = text; self.citedIDs = citedIDs }
}

public enum DiscoveryConversation {
    public static func action(for message: String, session: DiscoverySession) -> DiscoveryConversationAction {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？ "))
        if ["谢谢", "好的", "好", "ok", "thanks", "你好", "hello", "hi"].contains(normalized) { return .acknowledge }
        if DiscoveryRequestRouter.explicitlyChangesTask(text) { return .search }
        let explicit = DiscoveryRequestRouter.classify(message: text, previousIntent: nil)
        let isQuestion = ["怎么", "如何", "为什么", "能不能", "是否", "支持吗", "能做什么", "介绍一下", "解释", "吗", "how ", "what ", "why "].contains(where: normalized.contains)
            || text.hasSuffix("？") || text.hasSuffix("?")
        // A requested capability may itself involve comparison or removing text.
        // Protect the requested search before interpreting conversational actions.
        if requestsSearch(text) { return .search }
        let entityNames = DiscoveryNamedSkillRequest.inspect(message).names + explicit.targets.filter { $0.kind == .skillName }.map(\.value)
        let actionText = entityNames.reduce(normalized) { $0.replacingOccurrences(of: $1, with: "", options: .caseInsensitive) }
        if ["不限制", "不要求", "取消", "撤回", "去掉", "不要再限定"].contains(where: actionText.contains),
           let term = ["作者", "免费", "收费", "中文", "离线", "开源"].first(where: actionText.contains) {
            return .removeConstraint(term)
        }
        if ["区别", "比较", "对比", "哪个更", "选哪个", "compare", "difference"].contains(where: actionText.contains) { return .compare }
        if isQuestion && explicit.route != .exact { return .explain }
        if isQuestion && !session.candidates.isEmpty { return .explain }
        return .search
    }

    static func requestsSearch(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["帮我找", "我想找", "我需要找", "继续找", "搜索", "search", "find "].contains(where: normalized.contains)
            || (normalized.hasPrefix("推荐") && normalized.contains("skill")
                && !["哪个", "哪份", "哪款"].contains(where: normalized.contains))
    }

    static func userConditionClauses(_ text: String) -> [String] {
        text.replacingOccurrences(of: #"[，,。；;\n]|并且|而且"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Old intent arrays mixed user requirements with model paraphrases. Only
    /// existing conditions are checked; removed conditions are never replayed.
    public static func userGroundedIntent(in session: DiscoverySession) -> DiscoveryIntent? {
        guard var intent = session.intent else { return nil }
        guard let sources = userRequirementSources(in: session) else { return intent }
        let labels = sources.reduce(into: Set<String>()) { $0.formUnion(DiscoveryConstraintAssessment.requirementLabels(in: $1)) }
        func grounded(_ condition: String) -> Bool {
            let requested = DiscoveryConstraintAssessment.requirementLabels(in: condition)
            return !requested.isEmpty && requested.isSubset(of: labels)
        }
        intent.mustHaves = intent.mustHaves.filter(grounded)
        intent.exclusions = intent.exclusions.filter { condition in
            if grounded("排除" + condition) { return true }
            let escaped = NSRegularExpression.escapedPattern(for: condition)
            return sources.contains { source in
                source.range(of: "(?:不要|排除|禁止|不得|不允许|不能)(?:包含|涉及|使用|推荐|出现)?\\s*" + escaped,
                             options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        // Older clarification replies could save actual user requirements as
        // preferences. Promote only entries still present and backed by the user.
        var preferences: [String] = []
        for clause in intent.preferences.flatMap(userConditionClauses) {
            if DiscoveryConstraintAssessment.hasMandatoryLanguage(in: clause) {
                if grounded(clause), !intent.mustHaves.contains(clause) { intent.mustHaves.append(clause) }
            } else { preferences.append(clause) }
        }
        intent.preferences = preferences
        return intent
    }

    public static func hasUnverifiableLegacyConditions(in session: DiscoverySession) -> Bool {
        guard let intent = session.intent, !intent.mustHaves.isEmpty || !intent.exclusions.isEmpty else { return false }
        return userRequirementSources(in: session) == nil
    }

    private static func userRequirementSources(in session: DiscoverySession) -> [String]? {
        guard let intent = session.intent else { return [] }
        let messages = session.turns.map(\.userText) + session.messages.filter { $0.role == .user }.map(\.text)
        // A context boundary may mark a withdrawal, not the task's start. Keep
        // earlier user evidence in that task, while excluding previous tasks.
        guard let start = messages.lastIndex(where: { text in
            text == intent.goal || DiscoveryRequestRouter.explicitlyChangesTask(text)
                || (requestsSearch(text) && !text.contains("继续"))
        }) else { return nil }
        return messages[start...].flatMap(userConditionClauses).filter { DiscoveryConstraintAssessment.hasMandatoryLanguage(in: $0) }
    }

    public static func references(for message: String, action: DiscoveryConversationAction, session: DiscoverySession) -> [DiscoveryConversationReference] {
        let verified = session.recommendedCandidates.filter { $0.evidence.skillContentVerified }
        let repositoryMatches = verified.filter { mentionsName($0.repositoryFullName, in: message) }
        let nameMatches = verified.filter { mentionsName($0.name, in: message) }
        let routing = DiscoveryRequestRouter.classify(message: message, previousIntent: nil)
        let explicitNames = DiscoveryNamedSkillRequest.inspect(message).names
            + routing.targets.filter { $0.kind == .skillName }.map(\.value)
        guard explicitNames.allSatisfy({ name in verified.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) else { return [] }
        guard routing.targets.filter({ $0.kind == .repository }).allSatisfy({ target in
            verified.contains { RoutedSkillDiscoveryProvider.matches(target, candidate: $0) }
        }) else { return [] }
        let ordinals = ordinalReferences(in: message)
        guard ordinals.allSatisfy({ $0 >= 0 && $0 < verified.count }) else { return [] }
        let identifiedNames = Set(repositoryMatches.map { $0.name.lowercased() })
        let ambiguousNames = Set(Dictionary(grouping: nameMatches, by: { $0.name.lowercased() })
            .filter { $0.value.count > 1 && !identifiedNames.contains($0.key) }.keys)
        guard ambiguousNames.isEmpty || !ordinals.isEmpty else { return [] }
        var chosen = repositoryMatches + nameMatches.filter {
            !identifiedNames.contains($0.name.lowercased()) && !ambiguousNames.contains($0.name.lowercased())
        }
        for index in ordinals where !chosen.contains(where: { $0.id == verified[index].id }) {
            chosen.append(verified[index])
        }
        if chosen.isEmpty {
            if action == .compare { chosen = verified.count == 2 ? verified : [] }
            else if let selected = verified.first(where: { $0.id == session.selectedCandidateID }) { chosen = [selected] }
            else if verified.count == 1 { chosen = verified }
        }
        guard chosen.count <= 3 else { return [] }
        return chosen.map(DiscoveryConversationReference.init)
    }

    private static func mentionsName(_ name: String, in message: String) -> Bool {
        guard !name.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return message.range(of: "(?<![A-Za-z0-9_.-])\(escaped)(?![A-Za-z0-9_.-])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func ordinalReferences(in message: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"第\s*([0-9一二两三四五六七八九十百零〇]+)\s*(?:个|份|款|项)"#) else { return [] }
        let digits = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        return regex.matches(in: message, range: NSRange(message.startIndex..<message.endIndex, in: message)).map { match in
            guard let range = Range(match.range(at: 1), in: message) else { return -1 }
            let number = String(message[range])
            if let numeric = Int(number) { return numeric - 1 }
            if let digit = digits[number] { return digit - 1 }
            let tens = number.components(separatedBy: "十")
            if tens.count == 2, let high = tens[0].isEmpty ? 1 : digits[tens[0]],
               let low = tens[1].isEmpty ? 0 : digits[tens[1]] { return high * 10 + low - 1 }
            return -1
        }
    }

    public static func fallbackReply(action: DiscoveryConversationAction, references: [DiscoveryConversationReference]) -> String {
        if action == .acknowledge { return "好的。你可以接着问某份 Skill 怎么用、比较当前结果，或补充新的条件。" }
        if references.isEmpty { return "当前资料还无法对应到你提到的具体对象。请选中结果，或补充作者、仓库、序号；要查找新的 Skill，可以直接说“帮我找＋名称”。" }
        if action == .compare && references.count < 2 { return "目前只明确了一份 Skill。请告诉我另一份的名称，我再根据两份说明比较。" }
        let details = references.map {
            let excerpt = String($0.summary.prefix(160)) + ($0.summary.count > 160 ? "…" : "")
            return "\($0.name)\n作者说明：\(excerpt)"
        }.joined(separator: "\n\n")
        return "先对照作者自己的说明：\n\n\(details)\n\n这是资料摘录，具体差异或用法尚未由 AI 整理。可以展开下方依据核对；本轮没有新增搜索。"
    }

    public static func removeConstraint(_ term: String, from intent: DiscoveryIntent) -> DiscoveryIntent {
        var value = intent
        var terms = term == "收费" || term == "免费" ? ["免费", "收费", "付费"] : [term]
        if term == "作者" {
            for author in intent.targets where author.kind == .author {
                terms.append(author.value)
                if let owner = DiscoveryAuthorIdentity.owner(for: author.value) { terms.append(owner) }
            }
        }
        func remaining(_ entries: [String]) -> [String] {
            entries.flatMap { $0.replacingOccurrences(of: #"[，,；;\n]|而且|并且|以及|且|和|\band\b"#, with: "\n", options: .regularExpression).components(separatedBy: "\n") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { entry in
                    guard !entry.isEmpty, !terms.contains(where: entry.localizedCaseInsensitiveContains) else { return false }
                    guard term != "作者" else { return true }
                    return DiscoveryConstraintAssessment.requirementLabels(in: entry).isDisjoint(with: DiscoveryConstraintAssessment.requirementLabels(in: term))
                }
        }
        value.mustHaves = remaining(value.mustHaves)
        value.preferences = remaining(value.preferences)
        value.exclusions = remaining(value.exclusions)
        if term == "作者" {
            for author in value.targets where author.kind == .author {
                value.goal = value.goal.replacingOccurrences(of: author.value, with: "")
            }
            value.targets.removeAll { $0.kind == .author }
            value.route = value.targets.isEmpty ? .scenario : value.route
            value.goal = value.goal.replacingOccurrences(of: #"那(?:个|份|款)|的"#, with: "", options: .regularExpression)
        }
        for marker in terms { value.goal = value.goal.replacingOccurrences(of: marker, with: "") }
        return value
    }

    public static func searchPlan(message: String, session: DiscoverySession) -> DiscoveryPlan {
        var session = session
        session.intent = userGroundedIntent(in: session)
        if let question = session.pendingClarification, session.intent?.route == .exact,
           session.intent?.targets.isEmpty == true,
           !DiscoveryRequestRouter.explicitlyChangesTask(message),
           DiscoveryRequestRouter.classify(message: message, previousIntent: nil).targets.isEmpty {
            return .init(intent: session.intent!, queries: [], needsClarification: true, clarifyingQuestion: question)
        }
        if session.pendingClarification != nil, var intent = session.intent,
           !DiscoveryRequestRouter.explicitlyChangesTask(message),
           DiscoveryRequestRouter.classify(message: message, previousIntent: nil).targets.isEmpty {
            for clause in userConditionClauses(message) {
                if DiscoveryConstraintAssessment.hasMandatoryLanguage(in: clause) { intent.mustHaves.append(clause) }
                else { intent.preferences.append(clause) }
            }
            var plan = DiscoveryIntentPlanner.fallback(message: "继续寻找", previous: intent)
            plan.intent = intent
            return plan
        }
        return DiscoveryIntentPlanner.fallback(message: message, previous: session.intent)
    }

    public static func taskSummary(_ session: DiscoverySession) -> String? {
        guard let intent = session.intent else { return nil }
        let conditions = (intent.mustHaves + intent.preferences + intent.exclusions.map { "排除：" + $0 }).suffix(4)
        var parts = [intent.goal] + conditions
        if let candidate = session.recommendedCandidates.first(where: { $0.id == session.selectedCandidateID }) { parts.append("正在查看 " + candidate.name) }
        return parts.joined(separator: " · ")
    }
}
