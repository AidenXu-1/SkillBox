import Foundation

public enum SkillDirectoryEntryKind: String, Codable, Sendable {
    case directory
    case markdown
    case file
    case symbolicLink
}

public struct SkillDirectoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    public let depth: Int
    public let kind: SkillDirectoryEntryKind
    public let fileSize: Int64?

    public init(
        relativePath: String,
        name: String,
        depth: Int,
        kind: SkillDirectoryEntryKind,
        fileSize: Int64?
    ) {
        self.relativePath = relativePath
        self.name = name
        self.depth = depth
        self.kind = kind
        self.fileSize = fileSize
    }
}

public struct SkillDirectoryReader: Sendable {
    public init() {}

    public func entries(at root: URL, fileManager: FileManager = .default) throws -> [SkillDirectoryEntry] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FingerprintError.missingDirectory(root.path)
        }

        var entries: [SkillDirectoryEntry] = []
        try appendEntries(in: root, relativeDirectory: "", depth: 0, to: &entries, fileManager: fileManager)
        return entries
    }

    private func appendEntries(
        in directory: URL,
        relativeDirectory: String,
        depth: Int,
        to entries: inout [SkillDirectoryEntry],
        fileManager: FileManager
    ) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for child in children {
            let values = try child.resourceValues(forKeys: keys)
            let relativePath = relativeDirectory.isEmpty ? child.lastPathComponent : "\(relativeDirectory)/\(child.lastPathComponent)"
            let isSymbolicLink = values.isSymbolicLink == true
            let childIsDirectory = values.isDirectory == true
            let kind: SkillDirectoryEntryKind
            if isSymbolicLink {
                kind = .symbolicLink
            } else if childIsDirectory {
                kind = .directory
            } else if child.pathExtension.lowercased() == "md" {
                kind = .markdown
            } else {
                kind = .file
            }
            entries.append(.init(
                relativePath: relativePath,
                name: child.lastPathComponent,
                depth: depth,
                kind: kind,
                fileSize: childIsDirectory ? nil : values.fileSize.map(Int64.init)
            ))
            if childIsDirectory, !isSymbolicLink {
                try appendEntries(
                    in: child,
                    relativeDirectory: relativePath,
                    depth: depth + 1,
                    to: &entries,
                    fileManager: fileManager
                )
            }
        }
    }
}
