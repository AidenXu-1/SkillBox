import Foundation

public struct VisibilityRule: Hashable, Sendable {
    public var targetKind: AgentKind
    public var sourcePaths: [String]

    public init(targetKind: AgentKind, sourcePaths: [String]) {
        self.targetKind = targetKind
        self.sourcePaths = sourcePaths
    }
}

public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    var displayName: String { get }
    var defaultGlobalPath: String { get }
    var indirectVisibility: VisibilityRule? { get }
    func makeTarget(homeDirectory: URL, fileManager: FileManager) -> AgentTarget
}

public struct StandardAgentAdapter: AgentAdapter, Sendable {
    public let targetID: UUID
    public let kind: AgentKind
    public let displayName: String
    public let defaultGlobalPath: String
    public let indirectVisibility: VisibilityRule?
    public let environmentRootVariable: String?

    public init(
        targetID: UUID,
        kind: AgentKind,
        displayName: String,
        defaultGlobalPath: String,
        indirectVisibility: VisibilityRule? = nil,
        environmentRootVariable: String? = nil
    ) {
        self.targetID = targetID
        self.kind = kind
        self.displayName = displayName
        self.defaultGlobalPath = defaultGlobalPath
        self.indirectVisibility = indirectVisibility
        self.environmentRootVariable = environmentRootVariable
    }

    public func makeTarget(homeDirectory: URL, fileManager: FileManager = .default) -> AgentTarget {
        makeTarget(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment
        )
    }

    public func makeTarget(
        homeDirectory: URL,
        fileManager: FileManager = .default,
        environment: [String: String]
    ) -> AgentTarget {
        let url: URL
        if let environmentRootVariable,
           let configuredRoot = environment[environmentRootVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredRoot.isEmpty
        {
            url = PathSafety.resolveTildePath(configuredRoot, homeDirectory: homeDirectory)
                .appendingPathComponent("skills", isDirectory: true)
                .standardizedFileURL
        } else {
            url = PathSafety.resolveTildePath(defaultGlobalPath, homeDirectory: homeDirectory)
        }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let detection: TargetDetectionStatus
        let write: TargetWriteStatus
        if !exists || !isDirectory.boolValue {
            detection = .directoryMissing
            write = .directoryMissing
        } else {
            detection = fileManager.isReadableFile(atPath: url.path) ? .available : .unreadable
            write = fileManager.isWritableFile(atPath: url.path) ? .writable : .readOnly
        }

        return AgentTarget(
            id: targetID,
            kind: kind,
            displayName: displayName,
            path: url.path,
            detectionStatus: detection,
            writeStatus: write
        )
    }
}

public enum BuiltinAgentAdapters {
    public static let defaultAdapters: [StandardAgentAdapter] = [
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, kind: .codex, displayName: "GPT", defaultGlobalPath: "~/.codex/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, kind: .claudeCode, displayName: "Claude", defaultGlobalPath: "~/.claude/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!, kind: .workBuddy, displayName: "WorkBuddy", defaultGlobalPath: "~/.workbuddy/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, kind: .zcode, displayName: "ZCode", defaultGlobalPath: "~/.zcode/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, kind: .kimiCode, displayName: "Kimi Code", defaultGlobalPath: "~/.kimi-code/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, kind: .cursor, displayName: "Cursor", defaultGlobalPath: "~/.cursor/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!, kind: .hanaAgent, displayName: "HanaAgent", defaultGlobalPath: "~/.hanako/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, kind: .pi, displayName: "Pi", defaultGlobalPath: "~/.pi/agent/skills"),
        .init(
            targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            kind: .deepSeekHarness,
            displayName: "DeepSeek Harness",
            defaultGlobalPath: "~/.dsh/skills",
            environmentRootVariable: "DSH_HOME"
        ),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!, kind: .trae, displayName: "Trae", defaultGlobalPath: "~/.trae-cn/skills"),
    ]

    public static let legacyAdapters: [StandardAgentAdapter] = [
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!, kind: .geminiCLI, displayName: "Gemini CLI", defaultGlobalPath: "~/.gemini/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!, kind: .openCode, displayName: "OpenCode", defaultGlobalPath: "~/.config/opencode/skills"),
    ]

    public static let all = defaultAdapters + legacyAdapters

    public static func restoringDefaultOrder(in targets: [AgentTarget]) -> [AgentTarget] {
        let current = targets.sorted { $0.sortIndex < $1.sortIndex }
        let defaultRank = Dictionary(
            uniqueKeysWithValues: defaultAdapters.enumerated().map { ($0.element.targetID, $0.offset) }
        )
        let defaults = current
            .filter { defaultRank[$0.id] != nil }
            .sorted { defaultRank[$0.id, default: .max] < defaultRank[$1.id, default: .max] }
        let remaining = current.filter { defaultRank[$0.id] == nil }
        var ordered = defaults + remaining
        for index in ordered.indices { ordered[index].sortIndex = index }
        return ordered
    }

    public static func reconciledTargets(
        persisted: [AgentTarget],
        homeDirectory: URL,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AgentTarget] {
        let persistedByID = Dictionary(uniqueKeysWithValues: persisted.filter { !$0.isCustom }.map { ($0.id, $0) })
        var targets: [AgentTarget] = []

        for (index, adapter) in defaultAdapters.enumerated() {
            var target = adapter.makeTarget(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                environment: environment
            )
            if let previous = persistedByID[target.id] {
                target.isVisible = previous.isVisible
                target.sortIndex = previous.sortIndex == .max ? index : previous.sortIndex
            } else {
                target.sortIndex = index
            }
            targets.append(target)
        }

        for (offset, adapter) in legacyAdapters.enumerated() {
            guard let previous = persistedByID[adapter.targetID] else { continue }
            var target = adapter.makeTarget(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                environment: environment
            )
            target.isVisible = previous.isVisible
            target.sortIndex = previous.sortIndex == .max ? defaultAdapters.count + offset : previous.sortIndex
            targets.append(target)
        }

        for (offset, previous) in persisted.filter(\.isCustom).enumerated() {
            var target = previous
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
            target.detectionStatus = exists && fileManager.isReadableFile(atPath: target.path)
                ? .available
                : exists ? .unreadable : .directoryMissing
            target.writeStatus = exists && fileManager.isWritableFile(atPath: target.path)
                ? .writable
                : exists ? .readOnly : .directoryMissing
            if target.sortIndex == .max {
                target.sortIndex = defaultAdapters.count + legacyAdapters.count + offset
            }
            targets.append(target)
        }

        let defaultPosition = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.targetID, $0.offset) })
        targets.sort { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return (defaultPosition[lhs.id] ?? .max) < (defaultPosition[rhs.id] ?? .max)
        }
        for index in targets.indices { targets[index].sortIndex = index }
        return targets
    }
}

public enum PathSafetyError: LocalizedError, Equatable {
    case unsafeTarget(String)
    case targetInsideLibrary(String)
    case targetMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeTarget(path):
            "这个文件夹范围太大，请选择应用专门用来保存 Skills 的文件夹：\(path)"
        case let .targetInsideLibrary(path):
            "这个文件夹在 SkillBox 自己的保存位置里，请选择应用的 Skills 文件夹：\(path)"
        case let .targetMissing(path):
            "这个文件夹不存在。请先在对应应用中准备好 Skills 文件夹，再重新选择：\(path)"
        }
    }
}

public enum PathSafety {
    public static func resolveTildePath(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory.standardizedFileURL }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    public static func validateCustomTarget(_ url: URL, homeDirectory: URL, libraryRoot: URL) throws {
        _ = try validatedCustomTarget(url, homeDirectory: homeDirectory, libraryRoot: libraryRoot)
    }

    public static func validatedCustomTarget(_ url: URL, homeDirectory: URL, libraryRoot: URL) throws -> URL {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let library = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let unsafe = [URL(fileURLWithPath: "/"), home]
        if unsafe.contains(where: { $0.path == target.path }) || target.pathComponents.count < 3 {
            throw PathSafetyError.unsafeTarget(target.path)
        }
        if target.path == library.path ||
            target.path.hasPrefix(library.path + "/") ||
            library.path.hasPrefix(target.path + "/")
        {
            throw PathSafetyError.targetInsideLibrary(target.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathSafetyError.targetMissing(target.path)
        }
        return target
    }
}
