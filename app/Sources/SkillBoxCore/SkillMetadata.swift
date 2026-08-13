import Foundation

public struct SkillMetadata: Hashable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum SkillMetadataParser {
    public static func parse(text: String, fallbackName: String) -> SkillMetadata {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var name = fallbackName
        var description = ""

        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            for line in lines[1..<closing] {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "name", !value.isEmpty { name = value }
                if key == "description", !value.isEmpty { description = value }
            }
        }

        if description.isEmpty {
            let bodyStart: Int
            if lines.first == "---", let closing = lines.dropFirst().firstIndex(of: "---") {
                bodyStart = closing + 1
            } else {
                bodyStart = 0
            }
            description = lines.dropFirst(bodyStart)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) ?? "未提供描述"
        }

        return SkillMetadata(name: canonicalize(name), description: String(description.prefix(1024)))
    }

    public static func canonicalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" { return Character(String(scalar)) }
            return "-"
        }
        return String(allowed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
