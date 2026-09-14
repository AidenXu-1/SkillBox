import Darwin
import Foundation
import Testing
@testable import SkillBoxCore

@Suite("App rollback cleanup recovery and metadata safety")
struct AppBackupRecoverySafetyTests {
    @Test("Losing executable permissions in the replacement preserves both sets")
    func executablePermissions() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 1)
        let new = try f.payload("new", days: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: new.appendingPathComponent("executable").path)
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test("Replacing an empty directory with a special file never passes integrity checks")
    func specialFile() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 1)
        let new = try f.payload("new", days: 0, emptyDirectory: true)
        let empty = new.appendingPathComponent("empty")
        try FileManager.default.removeItem(at: empty)
        try #require(mkfifo(empty.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test("An unwritable removal plan cannot delete any payload")
    func planWriteFailure() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 9)
        let new = try f.payload("new", days: 8)
        try #require(chflags(f.registry.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(f.registry.path, 0) }
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test("A failure saving completion can resume after the payload was removed")
    func completionWriteFailure() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 9)
        let new = try f.payload("new", days: 8)
        #expect(throws: (any Error).self) {
            try AppRollbackBackups.clean(libraryRoot: f.data, now: Date()) { data, url in
                let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                if entries.contains(where: { $0["removedAt"] != nil }) { throw Interruption.afterRemoval }
                try data.write(to: url, options: .atomic)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 1)
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(try f.entries().allSatisfy { $0["removedAt"] != nil })
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 0)
    }

    @Test("A pending latest set already removed can finish without a replacement")
    func missingPendingLatest() throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("latest", days: 8)
        #expect(throws: (any Error).self) {
            try AppRollbackBackups.clean(libraryRoot: f.data, now: Date()) { data, url in
                let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                if entries.contains(where: { $0["removedAt"] != nil }) { throw Interruption.afterRemoval }
                try data.write(to: url, options: .atomic)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 0)
        #expect(try f.entries().allSatisfy { $0["removedAt"] != nil })
    }

    @Test("Pending sets still reject changed contents, markers, permissions and redirected paths", arguments: ["content", "marker", "permission", "link"])
    func pendingTampering(damage: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 1)
        let new = try f.payload("new", days: 0)
        try f.recordNativePlan()
        switch damage {
        case "content": try "user changed backup".write(to: old.appendingPathComponent("executable"), atomically: true, encoding: .utf8)
        case "marker": try FileManager.default.removeItem(at: old.appendingPathComponent(".skillbox-rollback.json"))
        case "permission": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: old.appendingPathComponent("executable").path)
        default:
            let moved = f.root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: old, to: moved)
            try FileManager.default.createSymbolicLink(at: old, withDestinationURL: moved)
        }
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(try f.entries().allSatisfy { $0["removedAt"] == nil })
    }

    @Test("A pending previous set cannot bypass a now missing replacement")
    func pendingRequiresReplacement() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 1)
        let new = try f.payload("new", days: 0)
        try f.recordNativePlan()
        try FileManager.default.removeItem(at: new)
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test("Python can resume a native plan that upgraded a legacy registration")
    func nativePlanToPython() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 9)
        let new = try f.payload("new", days: 8)
        var entries = try f.entries()
        let dates = entries.map { [$0["createdAt"] as? String, $0["expiresAt"] as? String] }
        for index in entries.indices {
            let versioned = try #require(entries[index]["digest"] as? String)
            entries[index]["digest"] = versioned.split(separator: ":")[1].description
        }
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        try f.recordNativePlan()
        #expect(try f.entries().allSatisfy { ($0["digest"] as? String)?.hasPrefix("v3:") == true })
        #expect(try f.entries().map { [$0["createdAt"] as? String, $0["expiresAt"] as? String] } == dates)
        // Old cleaners calculate only the legacy digest and therefore fail closed.
        #expect(try AppRollbackBackups.digest(new) != f.entries()[1]["digest"] as? String)
        try f.python(["clean", "--apply"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test("Native cleanup resumes a Python removal plan and its metadata format")
    func pythonPlanToNative() throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 9)
        let new = try f.payload("new", days: 8)
        #expect(try AppRollbackBackups.integrityDigest(new) == f.entries()[1]["digest"] as? String)
        try f.recordPythonPlan()
        #expect(try f.entries().allSatisfy { $0["removalStartedAt"] != nil })
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 2)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test("Legacy App registrations check the current user's launch permissions before migration", arguments: [0o755, 0o644, 0o655])
    func legacyAppLaunchPermissions(mode: Int) throws {
        let f = try Fixture()
        defer { f.remove() }
        let old = try f.payload("old", days: 1)
        let new = try f.payload("new", days: 0)
        let contents = new.appendingPathComponent("SkillBox.previous/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "SkillBox"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let program = contents.appendingPathComponent("MacOS/SkillBox")
        try "#!/bin/sh\necho app\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        var entries = try f.entries()
        entries[1]["digest"] = try AppRollbackBackups.digest(new)
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        if mode == 0o755 {
            #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 1)
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(try (f.entries()[1]["digest"] as? String)?.hasPrefix("v2:") == true)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: program.path)
            #expect(!FileManager.default.isExecutableFile(atPath: program.path))
            #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
            #expect(FileManager.default.fileExists(atPath: old.path))
            #expect(try (f.entries()[1]["digest"] as? String)?.hasPrefix("v2:") == false)
        }
    }

    @Test("A real partial deletion resumes after unlocking across both cleanup engines", arguments: ["native", "python", "native-to-python", "python-to-native"])
    func partialRemovalResumes(engine: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("partial", days: 8)
        let locked = backup.appendingPathComponent("zz-locked")
        try "remaining backup".write(to: locked, atomically: true, encoding: .utf8)
        let protected = f.root.appendingPathComponent("protected-original")
        try "original outside backup".write(to: protected, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("zzz-link"), withDestinationURL: protected)
        try "unicode survivor".write(to: backup.appendingPathComponent("中文.txt"), atomically: true, encoding: .utf8)
        var entries = try f.entries()
        entries[0]["digest"] = try AppRollbackBackups.integrityDigest(backup)
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        try #require(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(locked.path, 0) }
        if engine.hasPrefix("python") { #expect(try f.pythonExitStatus(["clean", "--apply"]) != 0) }
        else { #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) } }
        #expect(FileManager.default.fileExists(atPath: locked.path))
        try #require(chflags(locked.path, 0) == 0)
        if engine == "python" || engine == "native-to-python" { try f.python(["clean", "--apply"]) }
        else { #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 1) }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 0)
        #expect(try String(contentsOf: protected, encoding: .utf8) == "original outside backup")
        #expect(try f.entries()[0]["removedAt"] != nil)
    }

    @Test("Partial cleanup protects changed survivors, root permissions and new contents", arguments: ["content", "permission", "type", "link", "added", "root"])
    func partialSurvivorProtection(damage: String) throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("partial", days: 8)
        let survivor = backup.appendingPathComponent("survivor")
        try "remaining backup".write(to: survivor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: survivor.path)
        var entries = try f.entries()
        entries[0]["digest"] = try AppRollbackBackups.integrityDigest(backup)
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        try f.recordNativePlan()
        try FileManager.default.removeItem(at: backup.appendingPathComponent("executable"))
        switch damage {
        case "content": try "changed".write(to: survivor, atomically: true, encoding: .utf8)
        case "permission": try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: survivor.path)
        case "type":
            try FileManager.default.removeItem(at: survivor)
            try FileManager.default.createDirectory(at: survivor, withIntermediateDirectories: false)
        case "link":
            try FileManager.default.removeItem(at: survivor)
            try FileManager.default.createSymbolicLink(at: survivor, withDestinationURL: f.registry)
        case "added": try "user file".write(to: backup.appendingPathComponent("new-file"), atomically: true, encoding: .utf8)
        default: try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        }
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: survivor.path))
        #expect(try f.entries()[0]["removedAt"] == nil)
    }

    @Test("Legacy partial pending backups without an inventory stay protected")
    func legacyPartialWithoutInventory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("partial", days: 8)
        var entries = try f.entries()
        entries[0]["removalStartedAt"] = ISO8601DateFormatter().string(from: Date())
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        try FileManager.default.removeItem(at: backup.appendingPathComponent("executable"))
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try f.entries()[0]["removedAt"] == nil)
    }

    @Test("A v3 pending record whose inventory was lost cannot delete a backup")
    func missingInventory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let backup = try f.payload("partial", days: 8)
        try f.recordNativePlan()
        var entries = try f.entries()
        entries[0].removeValue(forKey: "removalInventory")
        try JSONSerialization.data(withJSONObject: entries).write(to: f.registry)
        #expect(throws: (any Error).self) { try AppRollbackBackups.clean(libraryRoot: f.data) }
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    private enum Interruption: Error { case beforeRemoval, afterRemoval }

    struct Fixture {
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
        func payload(_ name: String, days: Int, emptyDirectory: Bool = false) throws -> URL {
            let path = root.appendingPathComponent("scratch/" + name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "#!/bin/sh\necho app\n".write(to: path.appendingPathComponent("executable"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.appendingPathComponent("executable").path)
            if emptyDirectory { try FileManager.default.createDirectory(at: path.appendingPathComponent("empty"), withIntermediateDirectories: true) }
            try python(["register", "--path", path.path, "--created-at", ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(days * 86400) - 1))])
            return path
        }
        func recordNativePlan() throws {
            #expect(throws: (any Error).self) {
                try AppRollbackBackups.clean(libraryRoot: data, now: Date()) { data, url in
                    try data.write(to: url, options: .atomic)
                    throw Interruption.beforeRemoval
                }
            }
            #expect(try entries().contains { $0["removalStartedAt"] != nil })
        }
        func recordPythonPlan() throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/rollback-backups.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
                import importlib.util, sys
                from unittest.mock import patch
                spec = importlib.util.spec_from_file_location('backups', sys.argv[1])
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                with patch.object(module.Backups, 'remove_registered', side_effect=OSError('interrupted')):
                    try: module.Backups(sys.argv[2]).clean(apply=True)
                    except OSError: pass
                    else: raise AssertionError('cleanup did not attempt deletion')
                """, script.path, root.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
        }
        func python(_ arguments: [String]) throws {
            try #require(pythonExitStatus(arguments) == 0)
        }
        func pythonExitStatus(_ arguments: [String]) throws -> Int32 {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/rollback-backups.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let rootPointer = try #require(realpath(root.path, nil))
            defer { free(rootPointer) }
            var resolvedArguments = arguments
            if let pathIndex = arguments.firstIndex(of: "--path") {
                let pointer = try #require(realpath(arguments[pathIndex + 1], nil))
                resolvedArguments[pathIndex + 1] = String(cString: pointer)
                free(pointer)
            }
            process.arguments = [script.path, "--workspace", String(cString: rootPointer)] + resolvedArguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        func entries() throws -> [[String: Any]] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [[String: Any]])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
