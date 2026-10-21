import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Snapshot save failure is atomic")
struct SnapshotSaveAtomicityTests {
    @Test("A failed mutation cannot leak into memory, reopening, or a later save", arguments: [
        "targets", "visibility", "removeTarget", "assignments", "organization",
        "githubReplace", "githubUpdate", "localReplace", "localUpdate", "riskRefresh",
    ], ["catalog.json", "library-state.json"])
    func failedSavePreservesCommittedState(operation: String, failingFile: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxAtomicSave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = AtomicSaveFailureState()
        let storeRoot = root.appendingPathComponent("Store")
        let store = try LibraryStore(root: storeRoot, fileManager: AtomicSaveFailureManager(fault: fault))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\nHello".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let record = try await store.importCandidate(.init(sourceURL: source, directoryName: "demo", canonicalName: "demo", displayName: "demo", description: "Demo", fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: source), source: .init(kind: .localFolder, displayName: "Fixture", locator: source.path), riskReport: .init(scannedFileCount: 1, findings: [])))
        let targetRoot = root.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        let destination = targetRoot.appendingPathComponent("demo")
        try FileManager.default.copyItem(at: source, to: destination)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])
        try await store.replaceInstallations([.init(skillID: record.id, targetID: target.id, destinationPath: destination.path, deployedFingerprint: record.fingerprint, transactionID: UUID())])
        let github = GitHubSourceState(skillID: record.id, repositoryFullName: "example/demo", status: .current)
        let local = LocalSourceState(skillID: record.id, projectRootPath: source.path, recipe: .init(skillRelativePath: "", includePaths: ["SKILL.md"], reviewedTopLevelPaths: ["SKILL.md"]), currentPackageFingerprint: record.fingerprint)
        try await store.replaceSourceStates([github])
        try await store.replaceLocalSourceStates([local])
        let committed = try normalized(await store.currentSnapshot())
        fault.fail(on: failingFile)
        await #expect(throws: (any Error).self) {
            switch operation {
            case "targets": try await store.replaceTargets([])
            case "visibility": try await store.setTargetVisibility(id: target.id, isVisible: false, preservingManagedCopies: true)
            case "removeTarget": try await store.removeCustomTarget(id: target.id, preservingManagedCopies: true)
            case "assignments": try await store.replaceAssignments([])
            case "organization": try await store.replaceOrganization(.init(folders: [.init(name: "new", sortIndex: 0)]))
            case "githubReplace": try await store.replaceSourceStates([])
            case "githubUpdate":
                var updated = github; updated.status = .updateAvailable
                try await store.updateSourceState(updated)
            case "localReplace": try await store.replaceLocalSourceStates([])
            case "localUpdate":
                var updated = local; updated.status = .sourceUnavailable
                try await store.updateLocalSourceState(updated)
            default: try await store.refreshRiskReports(using: ChangedRiskAnalyzer())
            }
        }
        #expect(try normalized(await store.currentSnapshot()) == committed)
        #expect(try normalized(await (try LibraryStore(root: storeRoot)).currentSnapshot()) == committed)
        fault.fail(on: nil)
        try await store.recordTransaction(.init(status: .running, actions: []))
        #expect(try normalized(await (try LibraryStore(root: storeRoot)).currentSnapshot()) == committed)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: destination) == record.fingerprint)
        // A failed save must also leave the original user action retryable.
        try await store.setTargetVisibility(id: target.id, isVisible: false, preservingManagedCopies: true)
        let retried = await (try LibraryStore(root: storeRoot)).currentSnapshot()
        #expect(retried.targets.first?.isVisible == false)
        #expect(retried.assignments.isEmpty && retried.installations.isEmpty)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: destination) == record.fingerprint)
    }

    private func normalized(_ value: LibrarySnapshot) throws -> Data {
        var value = value
        value.transactions = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

private struct ChangedRiskAnalyzer: RiskAnalyzer {
    func analyze(skillDirectory: URL) throws -> RiskReport { .init(scannedFileCount: 99, findings: []) }
}

private final class AtomicSaveFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var failingFile: String?
    func fail(on name: String?) { lock.withLock { failingFile = name } }
    func fails(_ url: URL) -> Bool { lock.withLock { failingFile == url.lastPathComponent } }
}

private final class AtomicSaveFailureManager: FileManager, @unchecked Sendable {
    private let fault: AtomicSaveFailureState
    init(fault: AtomicSaveFailureState) { self.fault = fault; super.init() }
    override func fileExists(atPath path: String) -> Bool {
        if fault.fails(URL(fileURLWithPath: path)) { return false }
        return super.fileExists(atPath: path)
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if fault.fails(dstURL) { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
