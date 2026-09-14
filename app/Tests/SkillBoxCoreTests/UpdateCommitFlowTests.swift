import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Update content and source commit flow")
struct UpdateCommitFlowTests {
    @Test("Local and GitHub updates save matching source recovery and restore it", arguments: [false, true])
    func successfulUpdateRestoresContentAndSource(github: Bool) async throws {
        let fixture = try await UpdateCommitFixture.make(github: github)
        defer { fixture.remove() }
        let model = fixture.model()
        await fixture.prepareUpdate(model)
        await model.applyPendingUpdate(deployToExisting: false)
        #expect(model.errorMessage == nil)
        #expect(model.pendingCandidates.isEmpty)
        #expect(model.statusMessage == "已更新「我的 Skills」中的原件")
        let current = await fixture.store.currentSnapshot()
        let transaction = try #require(current.transactions.first)
        #expect(transaction.status == .succeeded)
        if github {
            #expect(current.sourceStates.first?.currentVersionIdentifier == "commit:B")
            #expect(transaction.libraryUpdate?.previousSourceState?.currentVersionIdentifier == "commit:A")
            #expect(transaction.libraryUpdate?.updatedSourceVersionIdentifier == "commit:B")
        } else {
            #expect(current.localSourceStates.first?.currentPackageFingerprint == fixture.next.fingerprint)
            #expect(transaction.libraryUpdate?.previousLocalSourceState?.currentPackageFingerprint == fixture.original.fingerprint)
            #expect(transaction.libraryUpdate?.updatedLocalSourceFingerprint == fixture.next.fingerprint)
        }
        await model.undo(transaction)
        #expect(model.errorMessage == nil)
        #expect(try fixture.savedText() == "A")
        #expect(model.snapshot.skills.first?.fingerprint == fixture.original.fingerprint)
        if github {
            #expect(model.snapshot.sourceStates.first?.currentVersionIdentifier == "commit:A")
        } else {
            #expect(model.snapshot.localSourceStates.first?.currentPackageFingerprint == fixture.original.fingerprint)
        }
    }

    @Test("One source commit failure remains retryable and preserves the real previous version", arguments: [false, true])
    func failedSourceCommitRetryAndRestart(github: Bool) async throws {
        let fixture = try await UpdateCommitFixture.make(github: github)
        defer { fixture.remove() }
        let model = fixture.model()
        await fixture.prepareUpdate(model)
        fixture.fault.arm(expectedFingerprint: fixture.next.fingerprint, github: github)
        await model.applyPendingUpdate(deployToExisting: false)
        #expect(fixture.fault.failureCount == 1)
        #expect(model.errorMessage != nil)
        #expect(!model.pendingCandidates.isEmpty)
        #expect(!model.isBusy)
        #expect(try fixture.savedText() == "A")
        #expect(model.snapshot.skills.first?.fingerprint == fixture.original.fingerprint)
        #expect(!model.snapshot.transactions.contains { $0.status == .succeeded })
        let reopened = try LibraryStore(root: fixture.storeRoot)
        _ = try await TransactionalSyncExecutor().recoverInterruptedTransactions(store: reopened)
        let restarted = await reopened.currentSnapshot()
        #expect(restarted.skills.first?.fingerprint == fixture.original.fingerprint)
        if github {
            #expect(restarted.sourceStates.first?.currentVersionIdentifier == "commit:A")
        } else {
            #expect(restarted.localSourceStates.first?.currentPackageFingerprint == fixture.original.fingerprint)
        }

        model.errorMessage = nil
        await model.applyPendingUpdate(deployToExisting: false)
        #expect(model.errorMessage == nil)
        #expect(model.pendingCandidates.isEmpty)
        #expect(try fixture.savedText() == "B")
        let retried = await fixture.store.currentSnapshot()
        let transaction = try #require(retried.transactions.first { $0.status == .succeeded })
        #expect(transaction.libraryUpdate?.previousRecord.fingerprint == fixture.original.fingerprint)
        #expect(FileManager.default.fileExists(atPath: fixture.archiveA.path))
        let afterRetryRestart = try LibraryStore(root: fixture.storeRoot)
        _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: afterRetryRestart)
        #expect(try fixture.savedText() == "A")
    }

    @Test("Cancelling the update preview leaves content and recovery records unchanged")
    func cancellingPreviewDoesNotCommit() async throws {
        let fixture = try await UpdateCommitFixture.make(github: false)
        defer { fixture.remove() }
        let model = fixture.model()
        await fixture.prepareUpdate(model)
        model.cancelCandidatePreview()
        await model.applyPendingUpdate(deployToExisting: false)
        #expect(model.pendingCandidates.isEmpty)
        #expect(try fixture.savedText() == "A")
        #expect(await fixture.store.currentSnapshot().transactions.isEmpty)
    }
}

private final class UpdateSourceCommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (fingerprint: String, github: Bool)?
    private var failures = 0
    var expected: (fingerprint: String, github: Bool)? { lock.withLock { state } }
    var failureCount: Int { lock.withLock { failures } }
    func arm(expectedFingerprint: String, github: Bool) {
        lock.withLock { state = (expectedFingerprint, github) }
    }
    func failOnce() { lock.withLock { state = nil; failures += 1 } }
}

private final class UpdateSourceCommitFailure: FileManager, @unchecked Sendable {
    private let fault: UpdateSourceCommitFault
    init(fault: UpdateSourceCommitFault) { self.fault = fault; super.init() }

    override func fileExists(atPath path: String) -> Bool {
        if fault.expected != nil, URL(fileURLWithPath: path).lastPathComponent == "library-state.json" { return false }
        return super.fileExists(atPath: path)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if let expected = fault.expected, dstURL.lastPathComponent == "library-state.json" {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: srcURL)) as? [String: Any]
            let value = root?["value"] as? [String: Any]
            let transactions = value?["transactions"] as? [[String: Any]] ?? []
            let states = value?[expected.github ? "sourceStates" : "localSourceStates"] as? [[String: Any]] ?? []
            let nextSourceCommitted = states.contains {
                expected.github ? $0["currentVersionIdentifier"] as? String == "commit:B" :
                    $0["currentPackageFingerprint"] as? String == expected.fingerprint
            }
            if nextSourceCommitted, transactions.contains(where: { $0["status"] as? String == "succeeded" }) {
                fault.failOnce()
                throw CocoaError(.fileWriteNoPermission)
            }
            if super.fileExists(atPath: dstURL.path) {
                _ = try super.replaceItemAt(dstURL, withItemAt: srcURL)
                return
            }
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private struct UpdateCommitFixture {
    let root: URL
    let source: URL
    let storeRoot: URL
    let store: LibraryStore
    let fault: UpdateSourceCommitFault
    let original: SkillRecord
    let next: SkillCandidate
    let github: Bool
    let saved: URL
    var archiveA: URL { saved.deletingLastPathComponent().appendingPathComponent("versions/\(original.fingerprint)") }

    static func make(github: Bool) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateCommitFlow-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Commit fixture\n---\nRead guide.md.\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "A".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let raw = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: raw, projectRoot: source)
        let package = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { if let temporary = package.candidate.temporaryPackageRoot { try? FileManager.default.removeItem(at: temporary) } }
        var initial = package.candidate
        if github { initial.source = .init(kind: .github, displayName: "GitHub", locator: "https://github.com/example/skills", repository: "example/skills", revision: "A") }
        let storeRoot = root.appendingPathComponent("Store")
        let fault = UpdateSourceCommitFault()
        let store = try LibraryStore(root: storeRoot, fileManager: UpdateSourceCommitFailure(fault: fault))
        let original = try await store.importCandidate(initial)
        if github {
            try await store.updateSourceState(.init(skillID: original.id, repositoryID: 1, repositoryFullName: "example/skills", trackingMode: .defaultBranch, currentVersionIdentifier: "commit:A", currentCommitSHA: "A", currentTreeSHA: "tree-A", status: .updateAvailable))
        } else {
            try await store.updateLocalSourceState(.init(skillID: original.id, projectRootPath: source.path, recipe: package.recipe, currentPackageFingerprint: original.fingerprint, topLevelFingerprints: package.topLevelFingerprints))
        }
        try "B".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        var next = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        if github { next.source = .init(kind: .github, displayName: "GitHub", locator: "https://github.com/example/skills", repository: "example/skills", revision: "B") }
        return .init(root: root, source: source, storeRoot: storeRoot, store: store, fault: fault, original: original, next: next, github: github, saved: await store.contentURL(for: original))
    }

    @MainActor func model() -> AppModel {
        AppModel(libraryRoot: storeRoot, store: store, homeDirectory: root, startBootstrap: false)
    }

    @MainActor func prepareUpdate(_ model: AppModel) async {
        await model.reload()
        if github {
            model.updatingSkillID = original.id
            model.pendingCandidates = [next]
            model.selectedCandidateIDs = [next.id]
            model.pendingGitHubVersion = .init(repositoryID: 1, repositoryFullName: "example/skills", isPrivate: false, trackingMode: .defaultBranch, defaultBranch: "main", versionIdentifier: "commit:B", versionName: "B", revision: "B", commitSHA: "B", treeSHA: "tree-B", archiveURL: URL(string: "https://github.com/example/skills/archive/B.zip")!)
        } else {
            await model.checkLocalSource(original)
        }
    }

    func savedText() throws -> String { try String(contentsOf: saved.appendingPathComponent("guide.md"), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
