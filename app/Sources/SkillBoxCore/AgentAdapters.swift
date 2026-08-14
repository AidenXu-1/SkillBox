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

    public init(
        targetID: UUID,
        kind: AgentKind,
        displayName: String,
        defaultGlobalPath: String,
        indirectVisibility: VisibilityRule? = nil
    ) {
        self.targetID = targetID
        self.kind = kind
        self.displayName = displayName
        self.defaultGlobalPath = defaultGlobalPath
        self.indirectVisibility = indirectVisibility
    }

    public func makeTarget(homeDirectory: URL, fileManager: FileManager = .default) -> AgentTarget {
        let url = PathSafety.resolveTildePath(defaultGlobalPath, homeDirectory: homeDirectory)
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
    public static let all: [StandardAgentAdapter] = [
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, kind: .codex, displayName: "Codex", defaultGlobalPath: "~/.codex/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, kind: .claudeCode, displayName: "Claude Code", defaultGlobalPath: "~/.claude/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, kind: .cursor, displayName: "Cursor", defaultGlobalPath: "~/.cursor/skills"),
        .init(
            targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            kind: .kimiCode,
            displayName: "Kimi Code",
            defaultGlobalPath: "~/.kimi/skills",
            indirectVisibility: .init(
                targetKind: .kimiCode,
                sourcePaths: [
                    "~/.claude/skills",
                    "~/.codex/skills",
                    "~/.config/agents/skills",
                    "~/.agents/skills",
                ]
            )
        ),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, kind: .zcode, displayName: "ZCode", defaultGlobalPath: "~/.zcode/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!, kind: .workBuddy, displayName: "WorkBuddy", defaultGlobalPath: "~/.workbuddy/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!, kind: .hanaAgent, displayName: "HanaAgent", defaultGlobalPath: "~/.hanako/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!, kind: .geminiCLI, displayName: "Gemini CLI", defaultGlobalPath: "~/.gemini/skills"),
        .init(targetID: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!, kind: .openCode, displayName: "OpenCode", defaultGlobalPath: "~/.config/opencode/skills"),
    ]
}

public enum PathSafetyError: LocalizedError, Equatable {
    case unsafeTarget(String)
    case targetInsideLibrary(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeTarget(path):
            "这个文件夹范围太大，请选择应用专门用来保存 Skills 的文件夹：\(path)"
        case let .targetInsideLibrary(path):
            "这个文件夹在 SkillBox 自己的保存位置里，请选择应用的 Skills 文件夹：\(path)"
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
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let library = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let unsafe = [URL(fileURLWithPath: "/"), home]
        if unsafe.contains(where: { $0.path == target.path }) || target.pathComponents.count < 3 {
            throw PathSafetyError.unsafeTarget(target.path)
        }
        if target.path == library.path || target.path.hasPrefix(library.path + "/") {
            throw PathSafetyError.targetInsideLibrary(target.path)
        }
    }
}
