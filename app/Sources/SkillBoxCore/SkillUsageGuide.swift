import Foundation

public struct SkillUsageStep: Hashable, Sendable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct SkillUsageGuide: Hashable, Sendable {
    public var summary: String?
    public var steps: [SkillUsageStep]
    public var sourceFile: String

    public init(summary: String? = nil, steps: [SkillUsageStep], sourceFile: String) {
        self.summary = summary
        self.steps = steps
        self.sourceFile = sourceFile
    }
}

public struct SkillUsageGuideExtractor: Sendable {
    private let maximumFileSize = 512 * 1024

    public init() {}

    public func extract(from skillDirectory: URL) -> SkillUsageGuide? {
        for fileName in ["SKILL.md", "README.md"] {
            let url = skillDirectory.appendingPathComponent(fileName)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maximumFileSize,
                  let markdown = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if let guide = extract(markdown: markdown, sourceFile: fileName) { return guide }
        }
        return nil
    }

    private func extract(markdown: String, sourceFile: String) -> SkillUsageGuide? {
        let lines = bodyLines(markdown)
        guard let section = lines.enumerated().compactMap({ index, line -> (Int, Int, String)? in
            guard let heading = heading(from: line), isUsageHeading(heading.title) else { return nil }
            return (index, heading.level, heading.title)
        }).first else { return nil }

        let end = lines.indices.dropFirst(section.0 + 1).first { index in
            guard let next = heading(from: lines[index]) else { return false }
            return next.level <= section.1
        } ?? lines.endIndex
        let sectionLines = Array(lines[(section.0 + 1)..<end])
        let summary = firstReadableLine(in: sectionLines.prefix { heading(from: $0) == nil })

        var steps: [SkillUsageStep] = []
        let childHeadings = sectionLines.enumerated().compactMap { index, line -> (Int, Int, String)? in
            guard let child = heading(from: line), child.level == section.1 + 1 else { return nil }
            return (index, child.level, child.title)
        }
        for (offset, child) in childHeadings.enumerated() {
            let nextIndex = offset + 1 < childHeadings.count ? childHeadings[offset + 1].0 : sectionLines.endIndex
            let detailLines = sectionLines[(child.0 + 1)..<nextIndex]
            let title = cleanedStepTitle(child.2)
            guard !title.isEmpty else { continue }
            steps.append(.init(title: title, detail: firstReadableLine(in: detailLines)))
            if steps.count == 6 { break }
        }

        if steps.isEmpty {
            for line in sectionLines {
                guard let item = listItem(from: line) else { continue }
                steps.append(.init(title: item))
                if steps.count == 6 { break }
            }
        }
        guard !steps.isEmpty else { return nil }
        return SkillUsageGuide(summary: summary, steps: steps, sourceFile: sourceFile)
    }

    private func bodyLines(_ markdown: String) -> [String] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        {
            lines = Array(lines.dropFirst(closing + 1))
        }
        return lines
    }

    private func heading(from line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " else { return nil }
        let title = cleanInline(String(trimmed.dropFirst(hashes.count + 1)))
        return (hashes.count, title)
    }

    private func isUsageHeading(_ title: String) -> Bool {
        let normalized = title.lowercased().filter { $0.isLetter || $0.isNumber }
        let exactChinese = ["执行步骤", "使用流程", "使用方法", "如何使用", "快速开始", "操作步骤"]
        if exactChinese.contains(where: { normalized.contains($0) }) { return true }
        let english = ["workflow", "usage", "instructions", "howtouse", "gettingstarted", "quickstart"]
        return english.contains { normalized.contains($0) }
    }

    private func cleanedStepTitle(_ title: String) -> String {
        title.replacingOccurrences(
            of: #"^\s*(?:(?:step|步骤)\s*)?(?:\d+|[一二三四五六七八九十]+)\s*[\.\)\uFF09\u3001:\-]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func listItem(from line: String) -> String? {
        let pattern = #"^\s*(?:\d+[\.\)\uFF09]|[-*+])\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        let value = cleanInline(String(line[range]))
        return value.isEmpty ? nil : value
    }

    private func firstReadableLine<S: Sequence>(in lines: S) -> String? where S.Element == String {
        var inCodeFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") { inCodeFence.toggle(); continue }
            guard !inCodeFence,
                  !trimmed.isEmpty,
                  heading(from: trimmed) == nil,
                  listItem(from: trimmed) == nil,
                  !trimmed.hasPrefix(">")
            else { continue }
            let value = cleanInline(trimmed)
            if !value.isEmpty { return String(value.prefix(180)) }
        }
        return nil
    }

    private func cleanInline(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
