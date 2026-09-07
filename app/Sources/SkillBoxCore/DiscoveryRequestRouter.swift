import Foundation

public enum DiscoverySearchRoute: String, Codable, Hashable, Sendable {
    case exact
    case scenario
    case hybrid
}

public enum DiscoveryTargetKind: String, Codable, Hashable, Sendable {
    case skillName
    case repository
    case author
}

public struct DiscoveryTarget: Codable, Hashable, Sendable {
    public var kind: DiscoveryTargetKind
    public var value: String
    public var repositoryFullName: String?
    public var skillPath: String?
    public var revision: String?

    public init(
        kind: DiscoveryTargetKind,
        value: String,
        repositoryFullName: String? = nil,
        skillPath: String? = nil,
        revision: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.repositoryFullName = repositoryFullName
        self.skillPath = skillPath
        self.revision = revision
    }
}

public struct DiscoveryRoutingDecision: Codable, Hashable, Sendable {
    public var route: DiscoverySearchRoute
    public var targets: [DiscoveryTarget]
    public var executionQueries: [String]

    public init(route: DiscoverySearchRoute, targets: [DiscoveryTarget], executionQueries: [String]) {
        self.route = route
        self.targets = targets
        self.executionQueries = executionQueries
    }
}

/// Chooses the search path from explicit user evidence before any model is called.
/// A model may enrich search terms later, but cannot turn an exact target into a
/// broad recommendation request or invent an exact target from a generic need.
public enum DiscoveryRequestRouter {
    public static func classify(
        message: String,
        previousIntent: DiscoveryIntent?
    ) -> DiscoveryRoutingDecision {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let repository = githubRepositoryTarget(in: text) {
            return .init(
                route: .exact,
                targets: [repository],
                executionQueries: ["repo:\(repository.repositoryFullName ?? repository.value)"]
            )
        }
        if let repository = bareRepositoryTarget(in: text) {
            return .init(
                route: .exact,
                targets: [repository],
                executionQueries: ["repo:\(repository.value)"]
            )
        }
        let named = DiscoveryNamedSkillRequest.inspect(text)
        if named.hasNameEvidence {
            let targets = named.clarification == nil ? namedTargets(named.names, in: text) : []
            return .init(route: named.clarification == nil && asksForPopularity(in: text) ? .hybrid : .exact,
                targets: targets,
                executionQueries: targets.isEmpty ? [] : queries(for: targets.filter { $0.kind != .author }, fallback: text))
        }
        if let skillName = explicitSkillName(in: text) {
            let route: DiscoverySearchRoute = asksForPopularity(in: text) ? .hybrid : .exact
            return .init(
                route: route,
                targets: namedTargets([skillName], in: text),
                executionQueries: [skillName]
            )
        }
        if isAvailabilityQuestion(text), DiscoveryAuthorIdentity.mentionedAuthor(in: text) == nil {
            return .init(route: .scenario, targets: [], executionQueries: [])
        }
        if let author = explicitAuthor(in: text) {
            return .init(
                route: .hybrid,
                targets: [.init(kind: .author, value: author)],
                executionQueries: unique([author] + DiscoveryIntentPlanner.protectedCreatorQueries(for: text))
            )
        }

        if isRefinement(text), let previousIntent {
            let previousDecision: DiscoveryRoutingDecision
            if previousIntent.route != .scenario || !previousIntent.targets.isEmpty {
                previousDecision = .init(
                    route: previousIntent.route,
                    targets: previousIntent.targets,
                    executionQueries: queries(for: previousIntent.targets, fallback: previousIntent.goal)
                )
            } else {
                previousDecision = classify(message: previousIntent.goal, previousIntent: nil)
            }
            if previousDecision.route != .scenario {
                return previousDecision
            }
        }

        return .init(route: .scenario, targets: [], executionQueries: [])
    }

    private static func namedTargets(_ names: [String], in text: String) -> [DiscoveryTarget] {
        var targets = names.map { DiscoverySkillNameAliases.bundled[$0.lowercased()] ?? DiscoveryTarget(kind: .skillName, value: $0) }
        if let author = explicitAuthor(in: text) { targets.append(.init(kind: .author, value: author)) }
        return targets
    }

    private static func githubRepositoryTarget(in text: String) -> DiscoveryTarget? {
        let pattern = #"https?://(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/(?:tree|blob)/([^\s/]+)/([^\s?#]+))?"#
        guard let values = captures(pattern, in: text), values.count >= 2 else { return nil }
        let owner = values[0]
        let repository = values[1].replacingOccurrences(of: ".git", with: "", options: [.anchored, .backwards])
        let fullName = "\(owner)/\(repository)"
        let revision = values.count > 2 ? values[2] : nil
        var path = values.count > 3 ? cleanPath(values[3]) : nil
        if path?.lowercased().hasSuffix("/skill.md") == true {
            path = String(path!.dropLast("/SKILL.md".count))
        } else if path?.lowercased() == "skill.md" {
            path = ""
        }
        return .init(kind: .repository, value: fullName, repositoryFullName: fullName, skillPath: path, revision: revision)
    }

    private static func bareRepositoryTarget(in text: String) -> DiscoveryTarget? {
        let pattern = #"(?<![\w.-])([A-Za-z0-9_.-]{2,39})/([A-Za-z0-9_.-]{2,100})(?![\w.-])"#
        guard let values = captures(pattern, in: text), values.count == 2 else { return nil }
        let blocked = Set(["http", "https", "github", "skills", "skill"])
        guard !blocked.contains(values[0].lowercased()) else { return nil }
        let fullName = "\(values[0])/\(values[1])"
        let standalone = text.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "`\"'。.,!?！？"))) == fullName
        let repositoryContext = ["github", "仓库", "repository", "repo:"].contains {
            text.localizedCaseInsensitiveContains($0)
        }
        guard standalone || repositoryContext else { return nil }
        return .init(kind: .repository, value: fullName, repositoryFullName: fullName)
    }

    private static func explicitSkillName(in text: String) -> String? {
        // Extract explicit naming clauses before single-word patterns. Chinese
        // characters are word characters in ICU, so \b cannot delimit a slug
        // touching Chinese text; use ASCII identifier boundaries instead.
        let namedPatterns = [
            #"(?:叫做|名为|名字叫|名称是|叫)\s*[`\"“「]?([A-Za-z][A-Za-z0-9_.-]{1,63})(?![A-Za-z0-9_.-])"#,
            #"(?:帮我找|找到|查找|搜索|找一下)\s*([A-Za-z][A-Za-z0-9_.-]+(?:\s+[A-Za-z][A-Za-z0-9_.-]+){1,3}?)\s+Skills?(?![A-Za-z])"#,
            #"(?:^|帮我找(?:一下)?\s*|查找\s*|搜索\s*)([A-Za-z][A-Za-z0-9_]*[-_][A-Za-z0-9_.-]+)(?=\s*(?:$|[。！？]|找一下|这个\s*Skills?|\s+Skills?))"#,
        ]
        for pattern in namedPatterns {
            if let name = captures(pattern, in: text)?.first,
               name.count <= 64,
               !["writing", "design", "agent", "skill", "skills"].contains(name.lowercased())
            { return name }
        }
        let patterns = [
            #"[`\"\u201c\u201d\u300c\u300d\u300e\u300f]([A-Za-z][A-Za-z0-9_.-]{1,63})[`\"\u201c\u201d\u300c\u300d\u300e\u300f]\s*(?:Agent\s+)?Skills?\b"#,
            #"[`\"\u201c\u201d\u300c\u300d\u300e\u300f]([\u4E00-\u9FFF][\u4E00-\u9FFFA-Za-z0-9_.-]{1,31})[`\"\u201c\u201d\u300c\u300d\u300e\u300f]\s*(?:Agent\s+)?Skill"#,
            #"\b([A-Za-z][A-Za-z0-9_]*[-_][A-Za-z0-9_.-]+)\s+(?:Agent\s+)?Skills?\b"#,
            #"(?:Skill|Skills?)\s*(?:\u53eb|\u540d\u4e3a|called|named|[:\uff1a])\s*[`\"\u201c\u201d\u300c\u300d]?([A-Za-z][A-Za-z0-9_.-]{2,63})"#,
            #"\b([A-Za-z][A-Za-z0-9_.-]{2,63})\s+\u8fd9\u4e2a\s*(?:Agent\s+)?Skills?\b"#,
            #"(?:\u5e2e\u6211\u627e|\u627e\u5230|\u67e5\u627e|\u641c\u7d22)\s*[`\"\u201c\u201d\u300c\u300d]?([A-Za-z][A-Za-z0-9_.-]{2,63})[`\"\u201c\u201d\u300c\u300d]?\s*(?:Agent\s+)?Skills?\b"#,
            #"(?:\u5e2e\u6211\u627e|\u627e\u5230|\u67e5\u627e|\u641c\u7d22)\s*([\u4E00-\u9FFF][\u4E00-\u9FFFA-Za-z0-9_.-]{1,31})\s*\u8fd9\u4e2a\s*(?:Agent\s+)?Skill"#,
        ]
        let blocked = Set([
            "agent", "best", "browser", "calendar", "data", "debugging", "design", "email",
            "excel", "free", "github", "image", "pdf", "ppt", "research", "security", "seo",
            "skill", "skills", "testing", "tool", "tools", "video", "workflow", "writing",
        ])
        for pattern in patterns {
            guard let match = captures(pattern, in: text)?.first else { continue }
            let normalized = match.lowercased()
            guard !blocked.contains(normalized) else { continue }
            return match
        }
        if let plain = captures(#"\b([A-Z][A-Za-z0-9_.-]{2,63})\s+(?:Agent\s+)?Skills?\b"#, in: text)?.first,
           plain.first?.isUppercase == true,
           !blocked.contains(plain.lowercased())
        {
            return plain
        }
        return nil
    }

    private static func explicitAuthor(in text: String) -> String? {
        if let author = DiscoveryAuthorIdentity.mentionedAuthor(in: text) { return author }
        let cleaned = text.replacingOccurrences(
            of: #"^(?:改成找|换成找|重新找|另外找|现在找|我需要找|我想找|帮我(?:找到|找)?|想找|查找|搜索)\s*"#,
            with: "", options: .regularExpression
        )
        let pattern = #"^([\u4E00-\u9FFFA-Za-z0-9_.-]{2,40}?)\s*(?:的|那(?:个|份|款))[^\n]{1,40}?(?:Agent\s+)?Skill"#
        guard let candidate = captures(pattern, in: cleaned)?.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return nil }
        let blocked = Set(["专门", "最好", "优质", "好用", "写作", "文案", "设计", "转换", "排版", "表格", "视频", "剪辑", "视频剪辑", "ppt", "excel", "pdf", "word", "powerpoint"])
        let requestFragments = ["我想", "想找", "帮我", "找一个", "能给", "可以", "用于", "专门", "有个", "有一个", "有份", "有款", "名字叫", "名为", "叫做"]
        let genericPrefixes = ["一个", "能", "可以", "用于", "专门", "最好", "好用", "优质", "热门"]
        guard !blocked.contains(candidate.lowercased()),
              !requestFragments.contains(where: candidate.contains),
              !genericPrefixes.contains(where: candidate.hasPrefix)
        else { return nil }
        return candidate
    }

    private static func asksForPopularity(in text: String) -> Bool {
        ["推荐", "热门", "知名", "多人用", "popular", "recommended", "best"]
            .contains { text.localizedCaseInsensitiveContains($0) }
    }

    public static func isRefinement(_ text: String) -> Bool {
        guard !explicitlyChangesTask(text), !isAvailabilityQuestion(text) else { return false }
        let newRequests = ["帮我找", "我想找", "我需要找", "想找", "查找", "搜索"]
        guard !newRequests.contains(where: text.hasPrefix) else { return false }
        let markers = ["最好", "而且", "还要", "再", "继续", "深挖", "更多来源", "优先", "最近", "维护", "开源", "中文", "免费", "可以", "不要", "只要", "必须", "离线"]
        let deliverableReplies = ["写出", "输出", "做成", "用来", "主要用于"]
        return text.count <= 80 && (markers.contains(where: text.contains)
            || deliverableReplies.contains(where: text.hasPrefix))
    }

    /// Asking whether a suitable Skill exists introduces a discovery task.
    /// Anchor the inquiry before the category: "这个 Skill 有什么限制" and
    /// "这些 Skill 中有没有…" still refer to the current candidates.
    static func isAvailabilityQuestion(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:(?:请问|想问一下|我想知道)[，,：:\s]*)?(?:有什么|有没有|有哪些|哪些|哪种|哪款|是否有|是否存在)[^\n]*skills?(?![A-Za-z])|^\s*(?:are there|is there|which)\b[^\n]*\bskills?\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func explicitlyChangesTask(_ text: String) -> Bool {
        ["改成找", "换成找", "换个任务", "换一个任务", "重新找", "另外找", "现在找"]
            .contains(where: text.contains)
    }

    private static func queries(for targets: [DiscoveryTarget], fallback: String) -> [String] {
        let values = targets.map { target in
            switch target.kind {
            case .repository: "repo:\(target.repositoryFullName ?? target.value)"
            case .skillName, .author: target.value
            }
        }
        return unique(values.isEmpty ? [fallback] : values)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              )
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func cleanPath(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "/`\"'.,;:!?)]}。，！？"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Known aliases resolve identity only, never a preferred Skill or quality rating.
enum DiscoveryAuthorIdentity {
    private static let identities: [(owner: String, aliases: [String])] = [
        ("KKKKhazix", ["数字生命卡兹克", "卡兹克", "KKKKhazix"]),
    ]

    static func owner(for author: String) -> String? {
        let value = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = identities.first(where: { $0.aliases.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }) {
            return known.owner
        }
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Author identity is separate from the request prefix and the placement of
    /// “的”. Recognition still requires a creator clause, not a casual mention.
    static func mentionedAuthor(in text: String) -> String? {
        guard text.range(of: #"skills?|技能"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        for identity in identities {
            for alias in identity.aliases {
                let pattern = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: alias) + "(?![A-Za-z0-9_-])"
                guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                let prefix = String(text[..<range.lowerBound])
                let suffix = String(text[range.upperBound...])
                if prefix.range(of: #"(?:不要|不找|排除|不是|关于|介绍|模仿)\s*$"#, options: .regularExpression) != nil { continue }
                guard suffix.range(of: #"^\s*(?:的|那(?:个|份|款)|有[一二两三四五六七八九十几\d]*(?:个|份|款)|写作|文案|出品|开源|发布|制作)"#, options: .regularExpression) != nil else { continue }
                return String(text[range])
            }
        }
        return nil
    }

    static func ownerQuery(_ query: String) -> String? {
        guard query.lowercased().hasPrefix("user:") else { return nil }
        return owner(for: String(query.dropFirst(5)))
    }

    static func matches(repository: String, owner: String) -> Bool {
        repository.split(separator: "/").first?.lowercased() == owner.lowercased()
    }
}
