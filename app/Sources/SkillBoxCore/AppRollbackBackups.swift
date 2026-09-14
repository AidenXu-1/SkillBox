import CryptoKit
import Darwin
import Foundation

/// Reads the same explicit registry as Scripts/rollback-backups.py, without
/// launching Python, a scheduler, or an AI session from the installed app.
public enum AppRollbackBackups {
    private struct Location: Codable { var workspace: String }
    private struct Entry: Codable {
        var id: String
        var group: String
        var path: String
        var createdAt: String
        var expiresAt: String
        var digest: String
        var removedAt: String?
        var removalStartedAt: String?
        var removalInventory: [RemovalItem]?
    }
    private struct RemovalItem: Codable, Equatable {
        var path: String
        var kind: String
        var mode: Int
        var content: String?
    }
    private struct Marker: Codable, Equatable { var id: String; var group: String }

    public static func clean(libraryRoot: URL, now: Date = Date()) throws -> Int {
        try clean(libraryRoot: libraryRoot, now: now) { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// The injectable persistence boundary exercises interrupted saves without
    /// replacing filesystem validation or deletion in recovery tests.
    static func clean(libraryRoot: URL, now: Date, saveRegistry: (Data, URL) throws -> Void) throws -> Int {
        let fm = FileManager.default
        let location = libraryRoot.appendingPathComponent("rollback-maintenance.json")
        guard fm.fileExists(atPath: location.path) else { return 0 }
        let config = try JSONDecoder().decode(Location.self, from: Data(contentsOf: location))
        let workspace = try canonicalExisting(URL(fileURLWithPath: config.workspace))
        let currentLibrary = try canonicalExisting(libraryRoot)
        let scratch = workspace.appendingPathComponent("scratch")
        let home = scratch.appendingPathComponent("rollback-backups")
        let registry = home.appendingPathComponent("registry.json")
        try checkPath(home, below: workspace)
        try checkPath(registry, below: workspace)
        let lockURL = home.appendingPathComponent("registry.lock")
        if fm.fileExists(atPath: lockURL.path) { try checkPath(lockURL, below: workspace) }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MaintenanceError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MaintenanceError.busy }
        defer { flock(descriptor, LOCK_UN) }

        var entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: registry))
        func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try saveRegistry(encoder.encode(entries), registry)
        }
        var live = entries.indices.filter { entries[$0].removedAt == nil }
        guard Set(live.map { entries[$0].id }).count == live.count else { throw MaintenanceError.invalidRegistry }
        var dates: [Int: (Date, Date)] = [:]
        for index in live {
            dates[index] = (try date(entries[index].createdAt), try date(entries[index].expiresAt))
            if let started = entries[index].removalStartedAt {
                _ = try date(started)
                guard entries[index].digest.hasPrefix("v2:") || entries[index].digest.hasPrefix("v3:") else { throw MaintenanceError.invalidRegistry }
                if entries[index].digest.hasPrefix("v3:") { _ = try checkedInventory(entries[index]) }
            } else if entries[index].digest.hasPrefix("v3:") { throw MaintenanceError.invalidRegistry }
        }

        func entryPath(_ index: Int) throws -> URL {
            let path = URL(fileURLWithPath: entries[index].path)
            guard entries[index].path.hasPrefix("/"),
                  !path.pathComponents.contains(".."), !path.pathComponents.contains("."),
                  path.path != home.path, !home.path.hasPrefix(path.path + "/"),
                  !currentLibrary.path.hasPrefix(path.path + "/"),
                  path.path != currentLibrary.path else { throw MaintenanceError.invalidPath }
            guard !live.contains(where: {
                $0 != index && (entries[$0].path == path.path || entries[$0].path.hasPrefix(path.path + "/") || path.path.hasPrefix(entries[$0].path + "/"))
            }) else { throw MaintenanceError.invalidPath }
            // Check existing ancestors as well, including a dangling final link.
            var cursor = path
            while !fm.fileExists(atPath: cursor.path) {
                let attributes = try? fm.attributesOfItem(atPath: cursor.path)
                guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else { throw MaintenanceError.invalidPath }
                guard cursor.path.hasPrefix(scratch.path + "/") else { throw MaintenanceError.invalidPath }
                cursor.deleteLastPathComponent()
            }
            if cursor.path != scratch.path { try checkPath(cursor, below: scratch) }
            else { try checkPath(scratch, below: workspace) }
            return path
        }

        // Only a durably recorded removal intent may explain a missing set.
        // Reconcile completed deletions before picking a surviving replacement.
        var recovered = false
        for index in live where entries[index].removalStartedAt != nil {
            if !fm.fileExists(atPath: try entryPath(index).path) {
                entries[index].removedAt = entries[index].removalStartedAt
                recovered = true
            }
        }
        if recovered { try save() }
        live = live.filter { entries[$0].removedAt == nil }
        let ordered = live.sorted {
            dates[$0]!.0 == dates[$1]!.0 ? entries[$0].id > entries[$1].id : dates[$0]!.0 > dates[$1]!.0
        }
        var latest: [String: Int] = [:]
        var planned: [(index: Int, superseded: Bool)] = []
        for index in ordered {
            let entry = entries[index]
            let superseded = latest[entry.group] != nil
            if !superseded { latest[entry.group] = index }
            guard superseded || now >= dates[index]!.1 || entry.removalStartedAt != nil else { continue }
            planned.append((index, superseded))
        }

        func verifiedPath(_ index: Int, requirePresent: Bool = false) throws -> (path: URL, digest: String) {
            let entry = entries[index]
            let path = try entryPath(index)
            var upgraded = entry.digest
            if fm.fileExists(atPath: path.path) {
                if entry.digest.hasPrefix("v3:") {
                    try verifyRemaining(path, entry: entry, requireComplete: requirePresent)
                    return (path, upgraded)
                }
                let markerURL = path.appendingPathComponent(".skillbox-rollback.json")
                let markerValues = try markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard markerValues.isRegularFile == true, markerValues.isSymbolicLink != true else { throw MaintenanceError.changed }
                let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
                guard marker == Marker(id: entry.id, group: entry.group) else { throw MaintenanceError.changed }
                let actual = try integrityDigest(path)
                if entry.digest.hasPrefix("v2:") {
                    guard actual == entry.digest else { throw MaintenanceError.changed }
                } else {
                    guard actual.split(separator: ":")[1] == entry.digest else { throw MaintenanceError.changed }
                    try checkLegacyApp(path)
                    upgraded = actual
                }
            } else if requirePresent { throw MaintenanceError.missingReplacement }
            return (path, upgraded)
        }

        var checked: [Int: (path: URL, digest: String)] = [:]
        for item in planned where item.superseded {
            let replacement = latest[entries[item.index].group]!
            if checked[replacement] == nil { checked[replacement] = try verifiedPath(replacement, requirePresent: true) }
        }
        for item in planned where checked[item.index] == nil {
            checked[item.index] = try verifiedPath(item.index)
        }
        if !planned.isEmpty {
            for (index, value) in checked { entries[index].digest = value.digest }
            for item in planned {
                if fm.fileExists(atPath: checked[item.index]!.path.path) {
                    entries[item.index].removalStartedAt = entries[item.index].removalStartedAt ?? ISO8601DateFormatter().string(from: now)
                    if !entries[item.index].digest.hasPrefix("v3:") {
                        entries[item.index].removalInventory = try removalInventory(checked[item.index]!.path)
                        // Old cleaners cannot silently discard the inventory and
                        // continue deleting under the older integrity contract.
                        entries[item.index].digest = "v3:" + entries[item.index].digest.dropFirst(3)
                    }
                } else { entries[item.index].removedAt = ISO8601DateFormatter().string(from: now) }
            }
            // Save the verified plan before the first destructive operation.
            try save()
        }
        var removed = 0
        // Keep replacements until their older sets have finished deleting.
        for item in planned.reversed() {
            let index = item.index
            let path = checked[index]!.path
            if fm.fileExists(atPath: path.path) {
                try removeRegistered(path, entry: entries[index])
                removed += 1
            }
            entries[index].removedAt = ISO8601DateFormatter().string(from: now)
            try save()
        }
        return removed
    }

    private static let markerName = ".skillbox-rollback.json"

    private static func removalInventory(_ root: URL) throws -> [RemovalItem] {
        var items = [("", root)] + (try orderedItems(root))
        let marker = root.appendingPathComponent(markerName)
        var info = stat()
        if lstat(marker.path, &info) == 0 { items.append((markerName, marker)) }
        else if errno != ENOENT { throw MaintenanceError.unavailable }
        return try items.map { relative, url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw MaintenanceError.unavailable }
            let kind: String
            let content: String?
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                kind = "L"
                content = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            case S_IFREG:
                kind = "F"
                var hash = SHA256()
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
                content = hash.finalize().map { String(format: "%02x", $0) }.joined()
            case S_IFDIR:
                kind = "D"
                content = nil
            default: throw MaintenanceError.unsupportedFile
            }
            return RemovalItem(path: relative, kind: kind, mode: Int(info.st_mode & 0o7777), content: content)
        }
    }

    private static func checkedInventory(_ entry: Entry) throws -> [String: RemovalItem] {
        guard let inventory = entry.removalInventory, !inventory.isEmpty else { throw MaintenanceError.invalidRegistry }
        var expected: [String: RemovalItem] = [:]
        for item in inventory {
            let components = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard expected[item.path] == nil,
                  item.path.isEmpty || (!item.path.hasPrefix("/") && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })),
                  ["D", "F", "L"].contains(item.kind), (0...0o7777).contains(item.mode),
                  item.kind == "D" || item.content != nil else { throw MaintenanceError.invalidRegistry }
            expected[item.path] = item
        }
        guard expected[""]?.kind == "D", expected[markerName]?.kind == "F" else { throw MaintenanceError.invalidRegistry }
        for name in expected.keys where !name.isEmpty {
            let parent = name.split(separator: "/").dropLast().joined(separator: "/")
            guard expected[parent]?.kind == "D" else { throw MaintenanceError.invalidRegistry }
        }
        return expected
    }

    private static func verifyRemaining(_ root: URL, entry: Entry, requireComplete: Bool = false) throws {
        let expected = try checkedInventory(entry)
        let actual = Dictionary(uniqueKeysWithValues: try removalInventory(root).map { ($0.path, $0) })
        guard actual.allSatisfy({ expected[$0.key] == $0.value }),
              !requireComplete || actual == expected,
              actual[markerName] != nil || actual.count == 1 else { throw MaintenanceError.changed }
    }

    private static func removeRegistered(_ root: URL, entry: Entry) throws {
        // A persisted inventory permits missing known entries, never changed or
        // additional survivors. rmdir refuses newly added directory contents.
        try verifyRemaining(root, entry: entry)
        let expected = try checkedInventory(entry)
        let names = expected.keys.filter { !$0.isEmpty && $0 != markerName }.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth ? $0.utf8.lexicographicallyPrecedes($1.utf8) : leftDepth > rightDepth
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        let parentFD = open(root.deletingLastPathComponent().path, flags)
        guard parentFD >= 0 else { throw MaintenanceError.unavailable }
        defer { close(parentFD) }
        let rootFD = openat(parentFD, root.lastPathComponent, flags)
        guard rootFD >= 0 else { throw MaintenanceError.invalidPath }
        defer { close(rootFD) }
        var rootIdentity = stat()
        guard fstat(rootFD, &rootIdentity) == 0 else { throw MaintenanceError.unavailable }
        for name in names + [markerName] {
            var directoryFD = dup(rootFD)
            guard directoryFD >= 0 else { throw MaintenanceError.unavailable }
            defer { close(directoryFD) }
            let components = name.split(separator: "/").map(String.init)
            var missingParent = false
            for component in components.dropLast() {
                let childFD = openat(directoryFD, component, flags)
                guard childFD >= 0 else {
                    if errno == ENOENT { missingParent = true; break }
                    throw MaintenanceError.invalidPath
                }
                close(directoryFD)
                directoryFD = childFD
            }
            if missingParent { continue }
            let result = unlinkat(directoryFD, components.last!, expected[name]!.kind == "D" ? AT_REMOVEDIR : 0)
            if result != 0 && errno != ENOENT { throw MaintenanceError.removalFailed }
        }
        var currentRoot = stat()
        guard fstatat(parentFD, root.lastPathComponent, &currentRoot, AT_SYMLINK_NOFOLLOW) == 0,
              currentRoot.st_dev == rootIdentity.st_dev, currentRoot.st_ino == rootIdentity.st_ino else { throw MaintenanceError.invalidPath }
        guard unlinkat(parentFD, root.lastPathComponent, AT_REMOVEDIR) == 0 else { throw MaintenanceError.removalFailed }
    }

    private static func date(_ value: String) throws -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: value) else { throw MaintenanceError.invalidRegistry }
        return date
    }

    private static func canonicalExisting(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw MaintenanceError.invalidPath }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }

    private static func checkPath(_ url: URL, below root: URL) throws {
        // Foundation's standardization changes /private/var spelling depending
        // on whether the final item exists. Keep the same canonical root for
        // both present and already removed payloads during recovery.
        var cursor = url
        guard cursor.path.hasPrefix(root.path + "/") else { throw MaintenanceError.invalidPath }
        while cursor.path != root.path {
            guard (try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw MaintenanceError.invalidPath
            }
            cursor.deleteLastPathComponent()
        }
    }

    private static func orderedItems(_ root: URL) throws -> [(String, URL)] {
        let fm = FileManager.default
        var items: [(String, URL)] = []
        func collect(_ directory: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                let relative = prefix + child.lastPathComponent
                if relative == ".skillbox-rollback.json" { continue }
                items.append((relative, child))
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    try collect(child, prefix: relative + "/")
                }
            }
        }
        try collect(root, prefix: "")
        // pathlib.Path sorts component by component, not by the full path string.
        // Preserve that ordering so existing Python registry digests remain valid.
        return items.sorted {
            $0.0.split(separator: "/").lexicographicallyPrecedes($1.0.split(separator: "/")) {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
        }
    }

    /// Byte-compatible with legacy Python registrations; do not change this format.
    static func digest(_ root: URL) throws -> String {
        let fm = FileManager.default
        var hash = SHA256()
        let ordered = try orderedItems(root)
        for (relative, url) in ordered {
            let name = Data(relative.utf8)
            var length = UInt64(name.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: name)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                hash.update(data: Data(("L" + (try fm.destinationOfSymbolicLink(atPath: url.path))).utf8))
            } else if values.isRegularFile == true {
                hash.update(data: Data("F".utf8))
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            } else { hash.update(data: Data("D".utf8)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Versioned metadata protects permissions and rejects special files. Older
    /// cleaners compare the entire string to their legacy digest and stop safely.
    static func integrityDigest(_ root: URL) throws -> String {
        var metadata = SHA256()
        for (relative, url) in [("", root)] + (try orderedItems(root)) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw MaintenanceError.unavailable }
            let kind: String
            switch info.st_mode & S_IFMT {
            case S_IFLNK: kind = "L"
            case S_IFREG: kind = "F"
            case S_IFDIR: kind = "D"
            default: throw MaintenanceError.unsupportedFile
            }
            let name = Data(relative.utf8)
            var length = UInt64(name.count).bigEndian
            withUnsafeBytes(of: &length) { metadata.update(data: Data($0)) }
            metadata.update(data: name)
            metadata.update(data: Data(kind.utf8))
            var mode = UInt32(info.st_mode & 0o7777).bigEndian
            withUnsafeBytes(of: &mode) { metadata.update(data: Data($0)) }
        }
        let suffix = metadata.finalize().map { String(format: "%02x", $0) }.joined()
        return "v2:" + (try digest(root)) + ":" + suffix
    }

    private static func checkLegacyApp(_ root: URL) throws {
        let fm = FileManager.default
        // Legacy digests cannot recover historical modes. Validate known App
        // launch requirements before establishing the metadata baseline.
        for app in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where app.lastPathComponent == "SkillBox.previous" || app.pathExtension == "app" {
            let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw MaintenanceError.changed }
            let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let executable = plist["CFBundleExecutable"] as? String,
                  !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else {
                throw MaintenanceError.changed
            }
            var info = stat()
            let program = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
            guard lstat(program.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  fm.isExecutableFile(atPath: program.path) else { throw MaintenanceError.changed }
        }
    }

    private enum MaintenanceError: LocalizedError {
        case unavailable, busy, invalidRegistry, invalidPath, changed, missingReplacement, unsupportedFile, removalFailed
        var errorDescription: String? {
            switch self {
            case .removalFailed: "应用回退备份暂时无法清理，剩余资料已保留。请解除文件锁定或权限问题后再检查。"
            case .unavailable: "暂时无法读取应用回退备份。"
            case .busy: "应用备份正在保存，请稍后再检查。"
            case .invalidRegistry, .invalidPath: "应用备份的登记或位置异常，已停止清理。"
            case .changed: "应用回退备份的内容或权限已被改动，已保留，请先检查。"
            case .unsupportedFile: "应用回退备份包含不支持的文件类型，已保留，请先检查。"
            case .missingReplacement: "最新应用回退备份已缺失，已保留上一份备份，请先检查。"
            }
        }
    }
}
