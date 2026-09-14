import Foundation
import Darwin
import Testing
@testable import SkillBoxCore

@Suite("App rollback registry regressions")
struct AppBackupRegistryRegressionTests {
    @Test("Native digests preserve existing Python path-component ordering")
    func existingPythonDigest() throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("previous")
        try FileManager.default.createDirectory(at: backup.appendingPathComponent("spec"), withIntermediateDirectories: true)
        try "nested".write(to: backup.appendingPathComponent("spec/README.md"), atomically: true, encoding: .utf8)
        try "sibling".write(to: backup.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        try f.register(backup, created: f.now.addingTimeInterval(-8 * 86400))
        var entries = try f.entries()
        let versioned = try #require(entries[0]["digest"] as? String)
        // Recreate an on-disk pre-v2 registration using Python's legacy component.
        entries[0]["digest"] = versioned.split(separator: ":")[1].description
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        let entry = try #require(f.entries().first)
        #expect(try AppRollbackBackups.digest(backup) == entry["digest"] as? String)
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data, now: f.now) == 1)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("An unavailable replacement never discards the complete previous backup", arguments: ["changed", "missing", "marker"])
    func damagedReplacement(damage: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old"), new = try f.payload("new")
        try f.register(old, created: f.now.addingTimeInterval(-86400))
        try f.register(new, created: f.now.addingTimeInterval(-60))
        switch damage {
        case "missing": try FileManager.default.removeItem(at: new)
        case "marker": try FileManager.default.removeItem(at: new.appendingPathComponent(".skillbox-rollback.json"))
        default: try "corrupt".write(to: new.appendingPathComponent("content"), atomically: true, encoding: .utf8)
        }
        let registryBefore = try Data(contentsOf: f.registry)
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data, now: f.now) }
        #expect(try String(contentsOf: old.appendingPathComponent("content"), encoding: .utf8) == "good backup")
        #expect(try Data(contentsOf: f.registry) == registryBefore)
    }

    @Test("A healthy replacement allows immediate removal of the earlier backup")
    func healthyReplacement() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old"), new = try f.payload("new")
        try f.register(old, created: f.now.addingTimeInterval(-86400))
        try f.register(new, created: f.now.addingTimeInterval(-60))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data, now: f.now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try String(contentsOf: new.appendingPathComponent("content"), encoding: .utf8) == "good backup")
    }

    @Test("Checks do not inspect payloads when no deletion is due")
    func noDeletionSkipsPayloadRead() throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("latest")
        try f.register(backup, created: f.now.addingTimeInterval(-60))
        try FileManager.default.removeItem(at: backup.appendingPathComponent(".skillbox-rollback.json"))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data, now: f.now) == 0)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    private struct Fixture {
        let root: URL
        let data: URL
        let registry: URL
        let now = Date()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            data = root.appendingPathComponent("Data")
            registry = root.appendingPathComponent("scratch/rollback-backups/registry.json")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["workspace": root.path]).write(to: data.appendingPathComponent("rollback-maintenance.json"))
        }
        func payload(_ name: String) throws -> URL {
            let result = root.appendingPathComponent("scratch/" + name)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            try "good backup".write(to: result.appendingPathComponent("content"), atomically: true, encoding: .utf8)
            return result
        }
        func register(_ backup: URL, created: Date) throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/rollback-backups.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let rootPointer = try #require(realpath(root.path, nil))
            let backupPointer = try #require(realpath(backup.path, nil))
            defer { free(rootPointer); free(backupPointer) }
            process.arguments = [script.path, "--workspace", String(cString: rootPointer), "register", "--path", String(cString: backupPointer),
                                 "--created-at", ISO8601DateFormatter().string(from: created)]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        func entries() throws -> [[String: Any]] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
