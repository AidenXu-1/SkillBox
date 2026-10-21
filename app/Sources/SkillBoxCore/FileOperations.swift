import Foundation

public enum FileOperationError: LocalizedError {
    case unsafeSymlink(String)
    case sourceMissing(String)
    case fingerprintMismatch
    case invalidRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case let .unsafeSymlink(path): "发现一个指向 Skill 文件夹外的文件连接，已停止：\(path)"
        case let .sourceMissing(path): "找不到要复制的 Skill 文件夹：\(path)"
        case .fingerprintMismatch: "复制后的内容校验没有通过。为了保护原文件，操作已停止"
        case let .invalidRelativePath(path): "发现不安全的文件位置，已停止：\(path)"
        }
    }
}

enum SafeFileOperations {
    static func copyDirectory(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        try validateTree(root: source, fileManager: fileManager, relocationRoot: destination)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)
    }

    static func validateTree(root: URL, fileManager: FileManager = .default, relocationRoot: URL? = nil) throws {
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var directories = [(normalizedRoot, "")]
        while let (directory, prefix) = directories.popLast() {
            for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let relative = prefix + url.lastPathComponent
                let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    let link = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                    guard SkillLinkBoundary.isContained(link: url, target: link, root: normalizedRoot) else {
                        throw FileOperationError.unsafeSymlink(relative)
                    }
                    // Refuse an absolute source pointer before relocation can
                    // turn it into an external link in the copied directory.
                    if let relocationRoot, (link as NSString).isAbsolutePath,
                       !SkillLinkBoundary.isContained(link: relocationRoot.appendingPathComponent(relative), target: link, root: relocationRoot) {
                        throw FileOperationError.unsafeSymlink(relative)
                    }
                } else if type == .typeDirectory {
                    directories.append((url, relative + "/"))
                }
            }
        }
    }

    static func atomicWrite<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let data = try encoder.encode(value)
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}

enum SkillLinkBoundary {
    static func isContained(link: URL, target: String, root: URL) -> Bool {
        let targetURL = (target as NSString).isAbsolutePath
            ? URL(fileURLWithPath: target)
            : link.deletingLastPathComponent().appendingPathComponent(target)
        let resolved = targetURL.resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        // A terminal link left unresolved is cyclic or could not be resolved.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path)) == nil else { return false }
        return resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
    }
}
