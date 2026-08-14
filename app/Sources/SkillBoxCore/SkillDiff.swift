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
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: URL] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            result[relative] = url
        }
        return result
    }

    private func signature(for url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            return Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
        }
        var data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber {
            data.append(Data("\0mode:\(permissions.intValue)".utf8))
        }
        return data
    }
}
