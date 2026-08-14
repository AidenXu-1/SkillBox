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
        guard fileManager.fileExists(atPath: source.path) else { throw FileOperationError.sourceMissing(source.path) }
        try validateTree(root: source, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)
    }

    static func validateTree(root: URL, fileManager: FileManager = .default) throws {
        let normalizedRoot = root.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(normalizedRoot.path.count + 1))
            if relative.split(separator: "/").contains("..") { throw FileOperationError.invalidRelativePath(relative) }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let link = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                let resolved = url.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
                guard resolved.path == normalizedRoot.path || resolved.path.hasPrefix(normalizedRoot.path + "/") else {
                    throw FileOperationError.unsafeSymlink(relative)
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
