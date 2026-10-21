import CryptoKit
import Foundation

public enum SkillFileChangeKind: String, Codable, Sendable {
    case added
    case modified
    case removed
}

public struct SkillFileChange: Codable, Hashable, Sendable {
    public var path: String
    public var kind: SkillFileChangeKind

    public init(path: String, kind: SkillFileChangeKind) {
        self.path = path
        self.kind = kind
    }
}

public struct SkillDiffAnalyzer: Sendable {
    public init() {}

    public func compare(before: URL, after: URL) throws -> [SkillFileChange] {
        let beforeFiles = try files(in: before)
        let afterFiles = try files(in: after)
        let paths = Set(beforeFiles.keys).union(afterFiles.keys)
        return try paths.compactMap { path in
            switch (beforeFiles[path], afterFiles[path]) {
            case (.none, .some): return .init(path: path, kind: .added)
            case (.some, .none): return .init(path: path, kind: .removed)
            case let (.some(lhs), .some(rhs)):
                return try signature(for: lhs) == signature(for: rhs) ? nil : .init(path: path, kind: .modified)
            case (.none, .none): return nil
            }
        }.sorted { $0.path < $1.path }
    }

    private func files(in root: URL) throws -> [String: URL] {
        let manager = FileManager.default
        var result: [String: URL] = [:]
        var directories = [(root, "")]
        while let (directory, prefix) = directories.popLast() {
            try Task.checkCancellation()
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if try FinderMetadata.isMetadataFile(url) { continue }
                // Carry names explicitly: Foundation may mix /var and
                // /private/var spellings even within the same enumeration.
                let relative = prefix + url.lastPathComponent
                result[relative] = url
                let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                if type == .typeDirectory { directories.append((url, relative + "/")) }
            }
        }
        return result
    }

    private func signature(for url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            return "L\0\(permissions)\0\(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))"
        case .typeDirectory:
            return "D\0\(permissions)"
        case .typeRegular:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return "F\0\(permissions)\0\(hash.finalize().map { String(format: "%02x", $0) }.joined())"
        default:
            throw FingerprintError.unsupportedItem(url.lastPathComponent)
        }
    }
}
