import Foundation
import Testing
@testable import SkillBoxApp
@testable import SkillBoxCore

@MainActor
@Suite("Local source refresh and monitoring")
struct LocalSourceRefreshTests {
    @Test("Toolbar refresh finds source edits without changing the saved or installed version")
    func refreshFindsChangesWithoutInstalling() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        await model.reload()
        try fixture.edit("updated runtime")

        await model.refreshSkills()

        #expect(model.snapshot.localSourceStates.first?.status == .updateAvailable)
        #expect(model.snapshot.localSourceStates.first?.lastCheckedAt != nil)
        #expect(model.pendingCandidates.isEmpty)
        #expect(model.pendingLocalSourceSetup == nil)
        #expect(model.snapshot.skills.first?.fingerprint == fixture.record.fingerprint)
        #expect(try String(contentsOf: fixture.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: fixture.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: fixture.source.appendingPathComponent("guide.md"), encoding: .utf8) == "updated runtime")

        try fixture.edit("original runtime")
        await model.refreshSkills()
        #expect(model.snapshot.localSourceStates.first?.status == .current)
    }

    @Test("Monitoring detects edits after startup and resumes after a busy operation")
    func monitorChecksRepeatedlyAndDefersWhileBusy() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        await model.reload()
        model.startLocalSourceMonitoring(interval: .milliseconds(20))
        defer { model.stopLocalSourceMonitoring() }
        try await waitUntil { model.snapshot.localSourceStates.first?.lastCheckedAt != nil }
        try await waitUntil { !model.isCheckingLocalSources }
        model.isBusy = true
        try fixture.edit("updated while busy")
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.snapshot.localSourceStates.first?.status == .current)
        model.isBusy = false
        try await waitUntil { model.snapshot.localSourceStates.first?.status == .updateAvailable }
        #expect(model.pendingCandidates.isEmpty)
        #expect(model.pendingLocalSourceSetup == nil)
        #expect(model.snapshot.skills.first?.fingerprint == fixture.record.fingerprint)
    }

    @Test("An automatically discovered update opens the existing diff preview and cancellation preserves content")
    func discoveredUpdateCanBePreviewedAndCancelled() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        await model.reload()
        try fixture.edit("new guide content")
        await model.checkAllLocalSources()
        await model.checkLocalSource(fixture.record)
        #expect(model.pendingCandidates.count == 1)
        #expect(model.updatingSkillID == fixture.record.id)
        #expect(model.pendingUpdateChanges.contains { $0.path == "guide.md" && $0.kind == .modified })
        let pending = try #require(model.pendingCandidates.first)
        #expect(FileManager.default.fileExists(atPath: pending.sourceURL.path))
        model.cancelCandidatePreview()
        #expect(model.pendingCandidates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pending.sourceURL.path))
        #expect(try String(contentsOf: fixture.saved.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
        #expect(try String(contentsOf: fixture.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    @Test("Missing sources and new runtime paths become visible without opening confirmation dialogs")
    func sourceChangesOnlyUpdateStatus() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        await model.reload()
        try "new".write(to: fixture.source.appendingPathComponent("extra.md"), atomically: true, encoding: .utf8)
        await model.checkAllLocalSources()
        #expect(model.snapshot.localSourceStates.first?.status == .packageReviewRequired)
        #expect(model.pendingLocalSourceSetup == nil)

        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("moved-source"))
        await model.checkAllLocalSources()
        #expect(model.snapshot.localSourceStates.first?.status == .sourceUnavailable)
        #expect(FileManager.default.fileExists(atPath: fixture.saved.path))
        #expect(FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    @Test("Late check results cannot restore stopped tracking or overwrite a new source association")
    func staleResultsAreDiscarded() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let old = try #require(await fixture.store.currentSnapshot().localSourceStates.first)
        var result = old
        result.status = .updateAvailable
        var relinked = old
        relinked.projectRootPath = fixture.root.appendingPathComponent("another-source").path
        try await fixture.store.updateLocalSourceState(relinked)
        #expect(try await !fixture.store.recordLocalSourceCheck(result, expected: old))
        #expect(await fixture.store.currentSnapshot().localSourceStates.first == relinked)
        try await fixture.store.stopTrackingLocalSource(skillID: old.skillID)
        #expect(try await !fixture.store.recordLocalSourceCheck(result, expected: old))
        #expect(await fixture.store.currentSnapshot().localSourceStates.isEmpty)
    }

    @Test("Read failures are persisted, reported and cleared only by a successful recheck")
    func failedChecksDoNotClaimCurrentContent() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let model = AppModel(
            libraryRoot: fixture.root.appendingPathComponent("Store"), store: fixture.store,
            homeDirectory: fixture.root,
            localPackageResolver: .init(scanner: FailingRefreshScanner()), startBootstrap: false
        )
        await model.reload()
        await model.refreshSkills()
        #expect(model.snapshot.localSourceStates.first?.lastCheckError != nil)
        #expect(model.statusMessage.contains("无法检查"))
        let reloaded = try LibraryStore(root: fixture.root.appendingPathComponent("Store"))
        #expect(await reloaded.currentSnapshot().localSourceStates.first?.lastCheckError != nil)
        let recovered = fixture.model()
        await recovered.reload()
        await recovered.checkAllLocalSources()
        #expect(recovered.snapshot.localSourceStates.first?.lastCheckError == nil)
        #expect(recovered.snapshot.localSourceStates.first?.lastCheckedAt != nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private struct FailingRefreshScanner: SkillScanner {
    func scan(roots: [URL], sourceName: @Sendable (URL) -> String) async -> ScanResult {
        .init(candidates: [], duplicateGroups: [], conflicts: [], diagnostics: ["开发源：读取测试失败"])
    }
}

struct RefreshFixture {
    let root: URL
    let source: URL
    let saved: URL
    let installed: URL
    let store: LibraryStore
    let record: SkillRecord

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxRefresh-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Refresh fixture\n---\nRead guide.md.\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "original runtime".write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: candidate, projectRoot: source)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent()) }
        let storeRoot = root.appendingPathComponent("Store")
        let store = try LibraryStore(root: storeRoot)
        let record = try await store.importCandidate(resolved.candidate)
        try await store.updateLocalSourceState(.init(
            skillID: record.id, projectRootPath: source.path, recipe: resolved.recipe,
            currentPackageFingerprint: record.fingerprint, topLevelFingerprints: resolved.topLevelFingerprints
        ))
        let targetRoot = root.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Fixture Agent", path: targetRoot.path,
                                 detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: storeRoot)
        _ = try await TransactionalSyncExecutor().execute(plan: plan, store: store)
        return .init(root: root, source: source, saved: await store.contentURL(for: record),
                     installed: targetRoot.appendingPathComponent("demo"), store: store, record: record)
    }

    @MainActor func model() -> AppModel {
        AppModel(libraryRoot: root.appendingPathComponent("Store"), store: store, homeDirectory: root, startBootstrap: false)
    }

    func edit(_ text: String) throws {
        try text.write(to: source.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
