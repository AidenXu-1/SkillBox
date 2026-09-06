import Foundation

/// Recognizes the object independently of the sentence's request prefix.
/// This is name evidence, not a guess about a capability or an author.
enum DiscoveryNamedSkillRequest {
    struct Evidence {
        var names: [String] = []
        var excludedNames: [String] = []
        var clarification: String? {
            if names.count > 1 { return "你提到了多个名称：\(names.joined(separator: "、"))。请只发送这次要找的一份 Skill 的完整名称。" }
            if names.isEmpty, !excludedNames.isEmpty { return "已理解你不想找 \(excludedNames.joined(separator: "、"))。请告诉我这次要找的 Skill 完整名称；也可以说“换个任务”后描述用途。" }
            return nil
        }
        var hasNameEvidence: Bool { !names.isEmpty || !excludedNames.isEmpty }
    }

    static func inspect(_ text: String) -> Evidence {
        let pattern = #"(?<![A-Za-z0-9_.-])([A-Za-z][A-Za-z0-9]*(?:[-_][A-Za-z0-9]+)+)(?![A-Za-z0-9_.-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .init() }
        var ranges = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map { $0.range(at: 1) }
        // A naming clause supplies identity evidence even without slug punctuation.
        // Ordinary English capability phrases do not enter this additional path.
        let namedPhrase = #"(?:有(?:一)?(?:个|份|款)|叫做|名为|名字叫|名称是|叫|named\s+|called\s+)\s*[`\"“「『]?([A-Za-z][A-Za-z0-9_.-]*(?:[ \t]+(?!Skills?(?![A-Za-z0-9_-]))[A-Za-z][A-Za-z0-9_.-]*){0,5})"#
        if let namedRegex = try? NSRegularExpression(pattern: namedPhrase, options: .caseInsensitive) {
            ranges += namedRegex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map { $0.range(at: 1) }
        }
        for alias in DiscoverySkillNameAliases.bundled.keys.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            if let aliasRegex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])", options: .caseInsensitive) {
                ranges += aliasRegex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).map(\.range)
            }
        }
        // Prefer the complete identity when one alias is a substring of another.
        ranges = ranges.filter { candidate in !ranges.contains { other in
            other.length > candidate.length && NSIntersectionRange(candidate, other) == candidate
        } }
        var result = Evidence()
        for rawRange in ranges.sorted(by: { $0.location < $1.location }) {
            guard let range = Range(rawRange, in: text) else { continue }
            let name = String(text[range])
            guard name.count <= 64 else { continue }
            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"“”「」『』。!！?？"))
            let categoryAfter = suffix.range(of: #"^[`\"”」』]?\s*(?:这个|这份|这款|的)?\s*(?:Agent\s+)?Skills?(?![A-Za-z0-9_-])"#, options: [.regularExpression, .caseInsensitive]) != nil
            let namingBefore = prefix.range(of: #"(?:有(?:一)?(?:个|份|款)|叫做|名为|名字叫|名称是|叫|named|called)\s*[`\"“「『]?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            let nameFirst = prefix.trimmingCharacters(in: trim).isEmpty && suffix.hasPrefix("找一下")
            let standalone = prefix.trimmingCharacters(in: trim).isEmpty && suffix.trimmingCharacters(in: trim).isEmpty
            guard categoryAfter || namingBefore || nameFirst || standalone else { continue }
            let clause = prefix.components(separatedBy: CharacterSet(charactersIn: "，,。;；!！?？\n")).last ?? ""
            let excluded = clause.range(of: #"(?:不要|不找|别找|排除|不是|not|exclude)\s*(?:叫做|名为|名字叫|叫|named|called)?\s*[`\"“「『]?$"#, options: [.regularExpression, .caseInsensitive]) != nil
            if excluded {
                if !result.excludedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { result.excludedNames.append(name) }
            } else if !result.names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { result.names.append(name) }
        }
        return result
    }
}
