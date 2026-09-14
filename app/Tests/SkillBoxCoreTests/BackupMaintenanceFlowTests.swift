import Foundation
import Testing
@testable import SkillBoxCore
@testable import SkillBoxApp

@Suite("Deferred startup backup maintenance")
struct BackupMaintenanceFlowTests {
    @Test("Startup check resumes after each kind of blocking user operation", arguments: ["busy", "candidate", "source", "undo"])
    @MainActor func resumesAfterBlocker(_ blocker: String) async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let model = f.model()
        await model.reload()
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: f.source.path).first)
        switch blocker {
        case "busy": model.isBusy = true
        case "candidate": model.pendingCandidates = [candidate]
        case "source":
            let review = try LocalSkillPackageResolver().review(candidate: candidate, projectRoot: f.source)
            model.pendingLocalSourceSetup = .init(reviews: [review], purpose: .importSkills)
        default:
            #expect(model.prepareUndoPreview(try #require(model.snapshot.transactions.first)))
        }
        await model.checkRollbackBackupsOnStartup()
        #expect(model.backupCheckResult != "检查完成，没有需要清理的备份。")
        // A second blocker must keep the queued check waiting.
        model.isBusy = true
        switch blocker {
        case "candidate": model.pendingCandidates = []
        case "source": model.pendingLocalSourceSetup = nil
        case "undo": model.cancelUndoPreview()
        default: break
        }
        await Task.yield()
        #expect(model.backupCheckResult != "检查完成，没有需要清理的备份。")
        model.isBusy = false
        model.isBusy = true
        await Task.yield()
        #expect(model.backupCheckResult != "检查完成，没有需要清理的备份。")
        model.isBusy = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.backupCheckResult != "检查完成，没有需要清理的备份。", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.backupCheckResult == "检查完成，没有需要清理的备份。")
        #expect(!model.isCheckingRollbackBackups)
        // Later idle transitions must not invent another check.
        let configuration = model.libraryRoot.appendingPathComponent("rollback-maintenance.json")
        try Data("invalid fixture configuration".utf8).write(to: configuration)
        model.isBusy = true
        model.isBusy = false
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.backupCheckResult == "检查完成，没有需要清理的备份。")
        #expect(try String(contentsOf: f.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    @Test("A manual check consumes a queued launch check, including when it fails")
    @MainActor func manualCheckConsumesStartupRequest() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let model = f.model()
        model.isBusy = true
        await model.checkRollbackBackupsOnStartup()
        let configuration = model.libraryRoot.appendingPathComponent("rollback-maintenance.json")
        try Data("invalid fixture configuration".utf8).write(to: configuration)
        model.isBusy = false
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult?.hasPrefix("检查未全部完成") == true)
        #expect(model.statusMessage.isEmpty)
        let failedResult = model.backupCheckResult
        try FileManager.default.removeItem(at: configuration)
        model.isBusy = true
        model.isBusy = false
        try await Task.sleep(for: .milliseconds(40))
        #expect(model.backupCheckResult == failedResult)
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult == "检查完成，没有需要清理的备份。")
        #expect(model.statusMessage == "备份检查完成")
    }

    @Test("Successful single-target uninstall reports its cleanup failure and retry clears the warning")
    @MainActor func assignmentReportsMaintenanceIssue() async throws {
        let f = try await RefreshFixture.make()
        defer { f.remove() }
        let versions = f.saved.deletingLastPathComponent().appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let unsafeBackup = versions.appendingPathComponent(String(repeating: "e", count: 64))
        try FileManager.default.createSymbolicLink(at: unsafeBackup, withDestinationURL: f.source)
        let model = f.model()
        await model.reload()
        let target = try #require(model.snapshot.targets.first)
        let proposal = try #require(await model.prepareAssignmentProposal(skill: f.record, target: target))
        #expect(!proposal.desired)
        #expect(await model.confirmAssignmentProposal(proposal))
        #expect(!FileManager.default.fileExists(atPath: f.installed.path))
        #expect(model.statusMessage.contains("卸载"))
        #expect(model.backupCheckResult?.hasPrefix("备份清理未完成") == true)
        #expect(model.noticeMessage?.hasPrefix("备份清理未完成") == true)
        #expect(try String(contentsOf: f.source.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        try FileManager.default.removeItem(at: unsafeBackup)
        await model.cleanRollbackBackups()
        #expect(model.backupCheckResult?.hasPrefix("检查完成") == true)
        #expect(model.noticeMessage == nil)
        #expect(await f.store.currentBackupMaintenanceIssue() == nil)
    }
}
