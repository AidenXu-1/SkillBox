import CryptoKit
import Foundation

public enum SkillUsageGuideOrigin: String, Codable, Hashable, Sendable {
    case authorMaterial
    case aiAssisted
}

public struct SkillUsageGuide: Codable, Hashable, Sendable {
    public var purpose: String
    public var useWhen: String?
    public var avoidWhen: String?
    public var starterPrompt: String?
    public var experienceSteps: [String]
    public var origin: SkillUsageGuideOrigin?
    public var sourceDocuments: [String]?

    public init(
        purpose: String,
        useWhen: String? = nil,
        avoidWhen: String? = nil,
        starterPrompt: String? = nil,
        experienceSteps: [String] = [],
        origin: SkillUsageGuideOrigin? = .authorMaterial,
        sourceDocuments: [String]? = nil
    ) {
        self.purpose = purpose
        self.useWhen = useWhen
        self.avoidWhen = avoidWhen
        self.starterPrompt = starterPrompt
        self.experienceSteps = experienceSteps
        self.origin = origin
        self.sourceDocuments = sourceDocuments
    }
}

public struct SkillUsageGuideDocument: Codable, Hashable, Sendable {
    public var relativePath: String
    public var content: String

    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public struct SkillUsageGuideMaterial: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var documents: [SkillUsageGuideDocument]

    public init(name: String, description: String, documents: [SkillUsageGuideDocument]) {
        self.name = name
        self.description = description
        self.documents = documents
    }
}

public enum AIContentSanitizer {
    public static func sanitize(_ material: SkillUsageGuideMaterial) -> SkillUsageGuideMaterial {
        .init(
            name: redact(material.name),
            description: redact(material.description),
            documents: material.documents.map {
                .init(relativePath: redact($0.relativePath), content: redact($0.content))
            }
        )
    }

    public static func redact(_ text: String) -> String {
        var value = text
        let rules: [(String, String)] = [
            (#"-----BEGIN [^-\r\n]+-----[\s\S]*?-----END [^-\r\n]+-----"#, "[已隐藏敏感内容]"),
            (#"(?i)((?:proxy-)?authorization)(\s*[:=]\s*)(?:(?:bearer|basic)\s+)?[^\s\"',}\]]+"#, "$1$2[已隐藏敏感内容]"),
            (#"(?im)^([ \t]*[\"']?(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|auth[_-]?token|github[_-]?token|client[_-]?secret|password|secret|token|credential)[\"']?[ \t]*:)[ \t]*[>|][-+]?[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)+"#, "$1 [已隐藏敏感内容]"),
            (#"(?im)(^|[\{,\s])([\"']?(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|auth[_-]?token|github[_-]?token|client[_-]?secret|password|secret|token|credential)[\"']?\s*[:=]\s*)(?:\"[^\r\n\"]*\"|'[^\r\n']*'|[^\r\n,}&]+)"#, "$1$2[已隐藏敏感内容]"),
            (#"(?i)([?&](?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|secret|token|credential)=)[^&#\s\"']+"#, "$1[已隐藏敏感内容]"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [已隐藏敏感内容]"),
            (#"\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[已隐藏敏感内容]"),
            (#"(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|github_pat_[A-Za-z0-9_]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|AIza[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{12,})\b"#, "[已隐藏敏感内容]"),
            (#"(?i)https?://[^\s/@:]+:[^\s/@]+@"#, "https://[已隐藏敏感内容]@"),
            (#"(?i)\bfile://(?:localhost)?/[^\s\"'<>]+"#, "[本机路径]"),
            (#"(?<![A-Za-z0-9_:])/(?:Users|home|Volumes|private|var|tmp|Library|Applications|System|opt|usr|etc)/[^\s\"'<>]+"#, "[本机路径]"),
            (#"(?i)\b[A-Z]:\\[^\s\"'<>]+"#, "[本机路径]"),
        ]
        for (pattern, replacement) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
        }
        return value
    }
}

public enum AIContentSharingPolicy {
    public static func canSend(
        sourceKind: SkillSourceKind,
        repositoryIsPrivate: Bool?,
        allowPrivateSkillContent: Bool
    ) -> Bool {
        if allowPrivateSkillContent { return true }
        return sourceKind == .github && repositoryIsPrivate == false
    }
}

public enum SkillUsageGuideSourceIdentity {
    public static let maximumSkillDocumentCharacters = 60_000

    public static func digest(markdown: String) -> String {
        let bounded = String(markdown.prefix(maximumSkillDocumentCharacters))
        return SHA256.hash(data: Data(bounded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(skillDirectory: URL) -> String? {
        let file = skillDirectory.appendingPathComponent("SKILL.md")
        guard let markdown = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return digest(markdown: markdown)
    }
}

public struct SkillUsageGuideMaterialReader: Sendable {
    private let maximumDocumentCharacters = 60_000
    private let maximumTotalCharacters = 180_000
    private let maximumDocumentCount = 12

    public init() {}

    public func read(from skillDirectory: URL, name: String, description: String) -> SkillUsageGuideMaterial {
        let fileManager = FileManager.default
        let preferred = ["SKILL.md", "README.md", "agents/openai.yaml"]
        var paths = preferred.filter { fileManager.fileExists(atPath: skillDirectory.appendingPathComponent($0).path) }
        if let enumerator = fileManager.enumerator(
            at: skillDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            let allowedExtensions = Set(["md", "markdown", "txt", "yaml", "yml"])
            for case let url as URL in enumerator {
                let relativePath = url.path.replacingOccurrences(of: skillDirectory.path + "/", with: "")
                guard !paths.contains(relativePath), allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if relativePath.hasPrefix("references/") || relativePath.hasPrefix("agents/") {
                    paths.append(relativePath)
                }
            }
        }

        var remaining = maximumTotalCharacters
        var documents: [SkillUsageGuideDocument] = []
        for relativePath in paths.prefix(maximumDocumentCount) where remaining > 0 {
            let url = skillDirectory.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 512 * 1_024,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let limit = min(maximumDocumentCharacters, remaining)
            let content = String(text.prefix(limit))
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            documents.append(.init(relativePath: relativePath, content: content))
            remaining -= content.count
        }
        return AIContentSanitizer.sanitize(
            .init(name: name, description: description, documents: documents)
        )
    }
}

public struct SkillUsageGuideRecord: Codable, Hashable, Sendable {
    public static let currentPromptVersion = "usage-guide-v3"

    public var schemaVersion: Int
    public var skillID: UUID
    public var fingerprint: String
    public var promptVersion: String
    public var providerID: String?
    public var model: String?
    public var createdAt: Date
    public var guide: SkillUsageGuide

    public init(
        schemaVersion: Int = 1,
        skillID: UUID,
        fingerprint: String,
        promptVersion: String = Self.currentPromptVersion,
        providerID: String? = nil,
        model: String? = nil,
        createdAt: Date = Date(),
        guide: SkillUsageGuide
    ) {
        self.schemaVersion = schemaVersion
        self.skillID = skillID
        self.fingerprint = fingerprint
        self.promptVersion = promptVersion
        self.providerID = providerID
        self.model = model
        self.createdAt = createdAt
        self.guide = guide
    }
}

public actor SkillUsageGuideStore {
    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.appendingPathComponent("AIReviews", isDirectory: true)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load(skillID: UUID, fingerprint: String) -> SkillUsageGuideRecord? {
        guard let data = try? Data(contentsOf: fileURL(skillID: skillID, fingerprint: fingerprint)),
              let record = try? decoder.decode(SkillUsageGuideRecord.self, from: data),
              record.schemaVersion == 1,
              record.skillID == skillID,
              record.fingerprint == fingerprint,
              record.promptVersion == SkillUsageGuideRecord.currentPromptVersion
        else { return nil }
        return record
    }

    public func save(
        _ guide: SkillUsageGuide,
        skillID: UUID,
        fingerprint: String,
        providerID: String? = nil,
        model: String? = nil
    ) throws {
        let url = fileURL(skillID: skillID, fingerprint: fingerprint)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = SkillUsageGuideRecord(
            skillID: skillID,
            fingerprint: fingerprint,
            providerID: providerID,
            model: model,
            guide: guide
        )
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func fileURL(skillID: UUID, fingerprint: String) -> URL {
        root
            .appendingPathComponent(skillID.uuidString, isDirectory: true)
            .appendingPathComponent(fingerprint, isDirectory: true)
            .appendingPathComponent("usage-guide.json")
    }
}

public struct SkillUsageGuideExtractor: Sendable {
    private let maximumFileSize = 512 * 1024

    public init() {}

    public func extract(from skillDirectory: URL) -> SkillUsageGuide? {
        guard let skillMarkdown = readableText(at: skillDirectory.appendingPathComponent("SKILL.md")) else { return nil }
        let readmeMarkdown = readableText(at: skillDirectory.appendingPathComponent("README.md"))
        let openAIYAML = readableText(at: skillDirectory.appendingPathComponent("agents/openai.yaml"))
        let documents = [readmeMarkdown, markdownBody(skillMarkdown)].compactMap { $0 }
        let parsedMetadata = SkillMetadataParser.parse(
            text: skillMarkdown,
            fallbackName: skillDirectory.lastPathComponent
        )
        let description = parsedMetadata.description == "未提供描述" ? nil : parsedMetadata.description
        let descriptionParts = splitDescription(description)

        let purpose = firstNonEmpty([
            yamlValue(named: "short_description", in: openAIYAML),
            sectionSummary(in: documents, headings: purposeHeadings),
            descriptionParts.purpose,
        ]).map { limited(cleanInline($0), to: 100) }
        guard let purpose, !purpose.isEmpty else { return nil }

        let suitability = suitability(in: documents)
        let useWhen = firstNonEmpty([
            suitability.useWhen,
            sectionListSummary(in: documents, headings: useWhenHeadings, maximumItems: 2),
        ]).map { limited(cleanInline($0), to: 180) }
        let avoidWhen = firstNonEmpty([
            suitability.avoidWhen,
            sectionListSummary(in: documents, headings: avoidWhenHeadings, maximumItems: 1),
        ]).map { limited(cleanInline($0), to: 120) }
        let starterPrompt = firstNonEmpty([
            promptFromSection(in: documents),
            yamlValue(named: "default_prompt", in: openAIYAML).flatMap { isUserFriendlyPrompt($0) ? $0 : nil },
        ]).map { limited(cleanInline($0), to: 180) }
        let experienceSteps = experience(in: documents)

        return SkillUsageGuide(
            purpose: purpose,
            useWhen: useWhen,
            avoidWhen: avoidWhen,
            starterPrompt: starterPrompt,
            experienceSteps: experienceSteps,
            origin: .authorMaterial,
            sourceDocuments: [
                FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("SKILL.md").path) ? "SKILL.md" : nil,
                FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("README.md").path) ? "README.md" : nil,
                FileManager.default.fileExists(atPath: skillDirectory.appendingPathComponent("agents/openai.yaml").path) ? "agents/openai.yaml" : nil,
            ].compactMap { $0 }
        )
    }

    private var purposeHeadings: [String] {
        ["这个skill做什么", "能帮你什么", "作用", "whatthisskilldoes", "whatitdoes"]
    }

    private var useWhenHeadings: [String] {
        ["适用场景", "什么时候适合", "什么时候使用", "whentouse", "bestfor", "usecases"]
    }

    private var avoidWhenHeadings: [String] {
        ["不适用", "不适合", "不要在什么时候使用", "notfor", "whennottouse"]
    }

    private var promptHeadings: [String] {
        ["使用示例", "触发方式", "可以这样说", "可以这样告诉ai", "怎么开始", "usageexample", "starterprompt", "exampleprompt", "howtostart"]
    }

    private var experienceHeadings: [String] {
        ["使用时会发生什么", "你会经历什么", "用户体验流程", "用户流程", "whathappens", "userexperience", "userjourney"]
    }

    private func readableText(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumFileSize
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func yamlValue(named name: String, in yaml: String?) -> String? {
        guard let yaml else { return nil }
        for line in yaml.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(name):") else { continue }
            let value = trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
            return decodedScalar(String(value))
        }
        return nil
    }

    private func decodedScalar(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        var result = value
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            result.removeFirst()
            result.removeLast()
        }
        result = result
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\n"#, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markdownBody(_ markdown: String) -> String {
        let lines = normalizedLines(markdown)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return markdown }
        return lines.dropFirst(closing + 1).joined(separator: "\n")
    }

    private func splitDescription(_ description: String?) -> (purpose: String?, useWhen: String?) {
        guard let description, !description.isEmpty else { return (nil, nil) }
        let markers = ["Use when", "use when", "适用于", "用于"]
        for marker in markers {
            guard let range = description.range(of: marker) else { continue }
            let purpose = String(description[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let useWhen = String(description[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (purpose.isEmpty ? nil : purpose, useWhen.isEmpty ? nil : useWhen)
        }
        return (description, nil)
    }

    private func suitability(in documents: [String]) -> (useWhen: String?, avoidWhen: String?) {
        for document in documents {
            guard let lines = sectionLines(in: document, headings: useWhenHeadings) else { continue }
            var positive: [String] = []
            var negative: [String] = []
            var isNegative = false
            for line in lines {
                let label = normalizedHeading(cleanInline(line))
                if ["适合", "适用", "bestfor"].contains(label) { isNegative = false; continue }
                if ["不适合", "不适用", "notfor"].contains(label) { isNegative = true; continue }
                guard let item = listItem(from: line) else { continue }
                if isNegative { negative.append(cleanSentence(item)) }
                else { positive.append(cleanSentence(item)) }
            }
            if !positive.isEmpty || !negative.isEmpty {
                return (
                    positive.isEmpty ? nil : positive.prefix(2).joined(separator: "；"),
                    negative.isEmpty ? nil : negative.prefix(1).joined(separator: "；")
                )
            }
        }
        return (nil, nil)
    }

    private func sectionSummary(in documents: [String], headings: [String]) -> String? {
        for document in documents {
            guard let lines = sectionLines(in: document, headings: headings) else { continue }
            if let value = firstReadableLine(in: lines) { return value }
        }
        return nil
    }

    private func sectionListSummary(in documents: [String], headings: [String], maximumItems: Int) -> String? {
        for document in documents {
            guard let lines = sectionLines(in: document, headings: headings) else { continue }
            let items = lines.compactMap(listItem).map(cleanSentence)
            if !items.isEmpty { return items.prefix(maximumItems).joined(separator: "；") }
            if let line = firstReadableLine(in: lines) { return cleanSentence(line) }
        }
        return nil
    }

    private func promptFromSection(in documents: [String]) -> String? {
        for document in documents {
            guard let lines = sectionLines(in: document, headings: promptHeadings) else { continue }
            var inFence = false
            var paragraph: [String] = []
            var paragraphEnded = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") { inFence.toggle(); continue }
                if inFence, !trimmed.isEmpty { return cleanInline(trimmed) }
                if trimmed.isEmpty {
                    if !paragraph.isEmpty { paragraphEnded = true }
                    continue
                }
                guard heading(from: trimmed) == nil, listItem(from: trimmed) == nil, !trimmed.hasPrefix(">") else {
                    if !paragraph.isEmpty { paragraphEnded = true }
                    continue
                }
                if !paragraphEnded { paragraph.append(cleanInline(trimmed)) }
            }
            let value = paragraph.filter { !$0.isEmpty }.joined(separator: " ")
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func isUserFriendlyPrompt(_ value: String) -> Bool {
        let cleaned = cleanInline(value)
        guard !cleaned.isEmpty, cleaned.count <= 120 else { return false }
        let internalMarkers = [
            "$", "`", "sha", "json", "yaml", "原子任务", "事实日志", "四文档", "审查门", "技术约束",
        ]
        let lowered = cleaned.lowercased()
        return !internalMarkers.contains { lowered.contains($0) }
    }

    private func experience(in documents: [String]) -> [String] {
        for document in documents {
            guard let lines = sectionLines(in: document, headings: experienceHeadings) else { continue }
            let items = lines.compactMap(listItem).map { limited(cleanSentence($0), to: 90) }
            if !items.isEmpty { return Array(items.prefix(3)) }
        }
        return []
    }

    private func sectionLines(in markdown: String, headings: [String]) -> [String]? {
        let lines = normalizedLines(markdown)
        guard let start = lines.enumerated().first(where: { _, line in
            guard let heading = heading(from: line) else { return false }
            return headings.contains(normalizedHeading(heading.title))
        }) else { return nil }
        let end = lines.indices.dropFirst(start.offset + 1).first { index in
            guard let next = heading(from: lines[index]), let current = heading(from: start.element) else { return false }
            return next.level <= current.level
        } ?? lines.endIndex
        return Array(lines[(start.offset + 1)..<end])
    }

    private func heading(from line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, cleanInline(String(trimmed.dropFirst(hashes.count + 1))))
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

    private func firstReadableLine(in lines: [String]) -> String? {
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
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func cleanInline(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanSentence(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.!！；;")))
    }

    private func normalizedHeading(_ value: String) -> String {
        cleanInline(value)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:")))
            .filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedLines(_ markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }.first
    }

    private func limited(_ value: String, to maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
