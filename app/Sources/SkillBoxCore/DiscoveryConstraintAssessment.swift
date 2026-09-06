import Foundation

/// Author statements establish evidence, never a guarantee about the user's runtime.
/// Unknown requirements stay unknown; popularity and model ranking cannot fill them in.
public struct DiscoveryConstraintAssessment: Hashable, Sendable {
    public var conflicts: [String] = []
    public var unverified: [String] = []
    public var permitsRecommendation: Bool { conflicts.isEmpty && unverified.isEmpty }

    public static func hasMandatoryLanguage(in value: String) -> Bool {
        let clauses = value.replacingOccurrences(of: #"[，,。；;\n]|并且|而且|但是|但"#, with: "\n", options: .regularExpression).components(separatedBy: "\n")
        return clauses.contains { clause in
            !matches(#"最好|优先|尽量|不要求|不限制|取消.*限制|prefer|ideally"#, in: clause)
                && matches(#"必须|只能|只要|不得|禁止|不能|不要|排除|不允许|不上传|不联网|不收费|无需付费|\bmust\b|\brequired\b|\bonly\b"#, in: clause)
        }
    }

    /// Stable labels help match older model paraphrases to actual user messages.
    /// Callers must establish that the source message is a requirement first.
    public static func requirementLabels(in value: String) -> Set<String> {
        Set(requirements(.init(goal: "", mustHaves: [value])).map { $0.label.lowercased().filter { !$0.isWhitespace } })
    }

    public static func summary(candidates: [DiscoveryCandidate], intent: DiscoveryIntent?) -> String? {
        guard let intent, intent.route != .exact else { return nil }
        let assessments = candidates.map { Self(candidate: $0, intent: intent) }
        let conflicts = assessments.filter { !$0.conflicts.isEmpty }.count
        let unknown = assessments.filter { $0.conflicts.isEmpty && !$0.unverified.isEmpty }.count
        guard conflicts + unknown > 0 else { return nil }
        let reasons = [conflicts > 0 ? "\(conflicts) 份线索与必须条件冲突" : nil,
                       unknown > 0 ? "\(unknown) 份线索尚无法确认满足必须条件" : nil].compactMap { $0 }
        return reasons.joined(separator: "；") + "，均未列为推荐。"
    }

    public static func details(candidates: [DiscoveryCandidate], intent: DiscoveryIntent?) -> [String] {
        guard let intent, intent.route != .exact else { return [] }
        return candidates.compactMap { candidate in
            let assessment = Self(candidate: candidate, intent: intent)
            let reasons = [assessment.conflicts.isEmpty ? nil : "资料与条件冲突：" + assessment.conflicts.joined(separator: "、"),
                           assessment.unverified.isEmpty ? nil : "资料尚未证实：" + assessment.unverified.joined(separator: "、")].compactMap { $0 }
            return reasons.isEmpty ? nil : "\(candidate.name)：" + reasons.joined(separator: "；")
        }
    }

    private enum Requirement: Hashable {
        case free, offline, noUpload, chinese, noChinese, openSource, other(String)
        var label: String {
            switch self {
            case .free: "免费使用"
            case .offline: "离线运行"
            case .noUpload: "不上传原文"
            case .chinese: "支持中文"
            case .noChinese: "排除中文"
            case .openSource: "开源"
            case .other(let value): value
            }
        }
    }

    public init(candidate: DiscoveryCandidate, intent: DiscoveryIntent) {
        guard intent.route != .exact else { return }
        let evidence = ((candidate.userFacingSummary ?? "") + "\n" + String((candidate.evidence.skillDocumentExcerpt ?? "").prefix(8_000))).lowercased()
        for requirement in Self.requirements(intent) {
            let patterns = Self.patterns(requirement)
            if patterns.negative.contains(where: { Self.matches($0, in: evidence) }) {
                conflicts.append(requirement.label)
            } else if !patterns.positive.contains(where: { Self.matches($0, in: evidence) }) {
                unverified.append(requirement.label)
            }
        }
    }

    private static func requirements(_ intent: DiscoveryIntent) -> [Requirement] {
        let separators = #"[，,。；;\n]|并且|而且|但是|但"#
        func clauses(_ value: String) -> [String] {
            value.replacingOccurrences(of: separators, with: "\n", options: .regularExpression)
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        var values = intent.mustHaves.flatMap(clauses)
        // Preferences can contain model paraphrases such as "must support X".
        // Only actual user requirements belong in the hard-condition field.
        values += clauses(intent.goal).filter { hasMandatoryLanguage(in: $0) }
        values = values.flatMap { $0.replacingOccurrences(of: #"并且|且|和(?=支持|必须|禁止|不要|不得|离线|免费|不上传|开源|中文)|同时|以及|\band\b"#, with: "\n", options: .regularExpression).components(separatedBy: "\n") }
        var result: [Requirement] = []
        for raw in values {
            // A soft preference or an explicit removal must not become a hard gate.
            if matches(#"最好|优先|尽量|不要求|不限制|取消.*限制|prefer|ideally"#, in: raw) { continue }
            let text = raw.replacingOccurrences(of: " ", with: "")
            var current: [Requirement] = []
            if matches(#"免费|不.{0,2}收费|不.{0,2}付费|无需付费|排除(?:付费|收费)|free|nocost"#, in: text) { current.append(.free) }
            if matches(#"离线|不联网|无需联网|offline"#, in: text) { current.append(.offline) }
            if matches(#"(?:不|禁止|不得|不能|排除).{0,8}(?:上传|外传)|(?:no|not|never|donot|mustnot)upload|no.{0,8}leaves"#, in: text) { current.append(.noUpload) }
            if text.contains("中文") || text.contains("chinese") {
                current.append(matches(#"(?:不要|排除|禁止|不能|不得|不支持|no|not).{0,4}(?:中文|chinese)"#, in: text) ? .noChinese : .chinese)
            }
            if text.contains("开源") || text.contains("opensource") { current.append(.openSource) }
            if current.isEmpty {
                let label = raw.replacingOccurrences(of: #"^.*?(?:必须|只能|只要|\bmust\b)\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^(?:支持|能够|可以|需要|具备)\s*|(?:的\s*)?skills?[。.!！]?$"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty { current.append(.other(String(label.prefix(120)))) }
            }
            for item in current where !result.contains(item) { result.append(item) }
        }
        return result
    }

    private static func patterns(_ requirement: Requirement) -> (positive: [String], negative: [String]) {
        switch requirement {
        case .free:
            return ([#"\bfree (?:to use|of charge|for (?:personal|commercial|all) use)\b"#, #"(?:完全免费|永久免费|免费使用|免费且|无需付费|不收费|零费用)"#],
                    [#"\b(?:requires?|needs?) (?:a )?(?:paid |premium )?(?:subscription|payment|purchase)\b"#, #"\b(?:not free|no free tier|paid.only|one.time fee)\b"#, #"必须付费|(?<!不)需要付费|仅限付费|(?<!无)需购买|(?<!无需)(?<!不需要)付费订阅|不免费|不是免费|并非免费"#])
        case .offline:
            return ([#"\b(?:works?|runs?|operates?) (?:fully |entirely )?offline\b"#, #"\bno (?:internet|network) (?:connection|access) (?:is )?(?:required|needed)\b"#, #"支持离线|离线运行|无需联网|不需要联网|完全本地运行"#],
                    [#"\b(?:does not|doesn't|cannot|can't) (?:work|run|operate) (?:fully |entirely )?offline\b"#, #"\b(?:requires?|needs?) (?:an? |active )?(?:internet|network) (?:connection|access)\b"#, #"不支持离线|不能离线|无法离线|必须联网|(?<!不)需要联网|仅支持在线"#])
        case .noUpload:
            return ([#"\bno (?:text|content|data) leaves (?:your |the )?(?:device|computer|machine)\b"#, #"\b(?:never|do not|does not|don't) (?:upload|send|transmit) (?:your |the |any )?(?:text|content|data|draft)"#, #"(?:不|禁止|无需)(?:会|要|需要)?上传(?:原文|文本|内容|数据)|原文不离开本机|文本仅在本地"#],
                    [#"\b(?:requires?|needs?) (?:uploading|sending|transmitting) (?:the |your |full |entire |original )*(?:text|content|draft|document)\b"#, #"(?<!not )(?<!never )(?<!don't )\b(?:upload|send|transmit) (?:the |your |full |entire |original )*(?:text|draft|document) to (?:an? )?(?:external |cloud |remote )"#, #"必须上传(?:原文|文本|全文)|(?<!不)需要上传(?:原文|文本|全文)|将(?:原文|全文)发送到"#])
        case .chinese:
            return ([#"中文(?:写作|文本|文案|文章|改写|润色)|(?<!不)支持中文|\bchinese (?:prose|text|writing)\b|\bsupports chinese\b"#],
                    [#"不支持中文|仅支持英文|\benglish.only\b|\bdoes not support chinese\b"#])
        case .noChinese:
            let chinese = patterns(.chinese)
            return (chinese.negative, chinese.positive)
        case .openSource:
            return ([#"\bopen.source\b|开源|\bmit license\b|\bapache.2\.0\b|\bgpl.[23]\.0\b"#],
                    [#"\bclosed.source\b|闭源|\bnot open.source\b|不开源"#])
        case .other(let value):
            let term = NSRegularExpression.escapedPattern(for: value.lowercased())
            return ([term], [#"(?:不支持|不能|无法|不提供|没有|缺少|does not support|cannot|lacks)\s*"# + term])
        }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
