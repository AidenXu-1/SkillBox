import Foundation
import Darwin
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("App backup checks without recurring automation")
struct AppRollbackBackupsTests {
    @Test("Native cleanup reads Python registration and removes only the expired set, preserving nested link targets")
    func pythonRegistryCompatibility() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.registerWithPython()
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 0)
        #expect(FileManager.default.fileExists(atPath: f.backup.path))
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data, now: Date().addingTimeInterval(8 * 86400)) == 1)
        #expect(!FileManager.default.fileExists(atPath: f.backup.path))
        #expect(try String(contentsOf: f.original, encoding: .utf8) == "protected original")
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data, now: Date().addingTimeInterval(9 * 86400)) == 0)
    }

    @Test("Changed registered payload is retained and reported as failure")
    func protectsChangedPayload() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.registerWithPython()
        try "changed".write(to: f.backup.appendingPathComponent("内容.txt"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try AppRollbackBackups.clean(libraryRoot: f.data, now: Date().addingTimeInterval(8 * 86400))
        }
        #expect(FileManager.default.fileExists(atPath: f.backup.path))
    }

    @Test("Unregistered and redirected backup roots are never cleaned")
    func protectsUnknownAndLinkedRoots() throws {
        let f = try Fixture()
        defer { f.remove() }
        #expect(try AppRollbackBackups.clean(libraryRoot: f.data) == 0)
        try f.registerWithPython()
        let moved = f.root.appendingPathComponent("protected-backup")
        try FileManager.default.moveItem(at: f.backup, to: moved)
        try FileManager.default.createSymbolicLink(at: f.backup, withDestinationURL: moved)
        #expect(throws: (any Error).self) {
            try AppRollbackBackups.clean(libraryRoot: f.data, now: Date().addingTimeInterval(8 * 86400))
        }
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("内容.txt").path))
    }

    @Test("Manual app check gives an explicit result and defers while another user operation is active")
    @MainActor func manualCheckFeedback() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let model = f.model()
        model.isBusy = true
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult == "请先完成当前操作，再检查备份。")
        model.isBusy = false
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult == "检查完成，没有需要清理的备份。")
        #expect(!model.isCheckingRollbackBackups)
        #expect(try String(contentsOf: f.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    private struct Fixture {
        let root: URL
        let data: URL
        let backup: URL
        let original: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            data = root.appendingPathComponent("Data")
            backup = root.appendingPathComponent("scratch/rollback-backups/previous")
            original = root.appendingPathComponent("original.txt")
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try "protected original".write(to: original, atomically: true, encoding: .utf8)
            try "previous app".write(to: backup.appendingPathComponent("内容.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: backup.appendingPathComponent("link"), withDestinationURL: original)
        }
        func registerWithPython() throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Scripts/rollback-backups.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let rootPointer = try #require(realpath(root.path, nil))
            let backupPointer = try #require(realpath(backup.path, nil))
            defer { free(rootPointer); free(backupPointer) }
            process.arguments = [script.path, "--workspace", String(cString: rootPointer), "register", "--path", String(cString: backupPointer)]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            try JSONSerialization.data(withJSONObject: ["workspace": root.path])
                .write(to: data.appendingPathComponent("rollback-maintenance.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
