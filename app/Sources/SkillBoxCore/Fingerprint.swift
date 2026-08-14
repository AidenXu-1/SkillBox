import CryptoKit
import Foundation

public enum FingerprintError: LocalizedError {
    case missingDirectory(String)
    case unsupportedItem(String)

    public var errorDescription: String? {
        switch self {
        case let .missingDirectory(path): "找不到这份 Skill 的文件夹：\(path)"
        case let .unsupportedItem(path): "SkillBox 无法读取这个文件：\(path)"
        }
    }
}

public protocol SkillFingerprinting: Sendable {
    func fingerprint(directory: URL) throws -> String
}

public struct SHA256SkillFingerprinter: SkillFingerprinting, Sendable {
    public init() {}

    public func fingerprint(directory: URL) throws -> String {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FingerprintError.missingDirectory(directory.path)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw FingerprintError.missingDirectory(directory.path)
        }

        var urls: [URL] = []
        for case let url as URL in enumerator { urls.append(url) }
        urls.sort { relativePath(of: $0, root: directory) < relativePath(of: $1, root: directory) }

        var hasher = SHA256()
        for url in urls {
            let relative = relativePath(of: url, root: directory)
            let values = try url.resourceValues(forKeys: Set(keys))
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let permission = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0

            if values.isSymbolicLink == true {
                let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                update(&hasher, text: "L\0\(relative)\0\(permission)\0\(target)\0")
            } else if values.isDirectory == true {
                update(&hasher, text: "D\0\(relative)\0\(permission)\0")
            } else if values.isRegularFile == true {
                update(&hasher, text: "F\0\(relative)\0\(permission)\0\(values.fileSize ?? 0)\0")
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    hasher.update(data: data)
                }
                update(&hasher, text: "\0")
            } else {
                throw FingerprintError.unsupportedItem(relative)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return String(itemPath.dropFirst(min(itemPath.count, rootPath.count + 1)))
    }

    private func update(_ hasher: inout SHA256, text: String) {
        hasher.update(data: Data(text.utf8))
    }
}
