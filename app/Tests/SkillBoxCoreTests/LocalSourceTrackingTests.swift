import Foundation
import Testing
@testable import SkillBoxApp
@testable import SkillBoxCore

@Suite("Tracked local development sources")
struct LocalSourceTrackingTests {
    @Test("A confirmed local recipe creates a clean package without changing the development source")
    func cleanPackageLeavesDevelopmentSourceUntouched() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Use scripts/run.sh and references/guide.md."))
        try fixture.write("skills/demo/scripts/run.sh", "#!/bin/sh\necho ready\n")
        try fixture.write("skills/demo/references/guide.md", "Guide")
        try fixture.write("skills/demo/tests/fixture.md", "development only")
        try fixture.write("skills/demo/design/flow.png", "design draft")
        let candidate = try await fixture.candidate()
        let sourceFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: candidate.sourceURL)

        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: candidate, projectRoot: fixture.projectRoot)
        #expect(review.recommendedIncludePaths == ["SKILL.md", "references", "scripts"])
        #expect(review.developmentOnlyPaths == ["design", "tests"])

        let resolved = try await resolver.confirm(
            review: review,
            includePaths: review.recommendedIncludePaths
        )
        defer { try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: resolved.candidate.sourceURL.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: resolved.candidate.sourceURL.appendingPathComponent("scripts/run.sh").path))
        #expect(FileManager.default.fileExists(atPath: resolved.candidate.sourceURL.appendingPathComponent("references/guide.md").path))
        #expect(!FileManager.default.fileExists(atPath: resolved.candidate.sourceURL.appendingPathComponent("tests").path))
        #expect(!FileManager.default.fileExists(atPath: resolved.candidate.sourceURL.appendingPathComponent("design").path))
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: candidate.sourceURL) == sourceFingerprint)
    }

    @Test("Development-only changes stay quiet while selected runtime changes become an update")
    func updateCheckUsesOnlySelectedContent() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Use scripts/run.sh."))
        try fixture.write("skills/demo/scripts/run.sh", "echo v1")
        try fixture.write("skills/demo/tests/fixture.md", "test v1")
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent()) }
        var state = LocalSourceState(
            skillID: UUID(),
            projectRootPath: fixture.projectRoot.path,
            recipe: resolved.recipe,
            currentPackageFingerprint: resolved.candidate.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        )

        try fixture.write("skills/demo/tests/fixture.md", "test v2")
        let ignored = try await resolver.check(state: state)
        #expect(ignored.state.status == .current)
        #expect(ignored.candidate == nil)
        #expect(ignored.ignoredChangedPaths == ["tests"])

        state = ignored.state
        try fixture.write("skills/demo/scripts/run.sh", "echo v2")
        let update = try await resolver.check(state: state)
        #expect(update.state.status == .updateAvailable)
        #expect(update.candidate?.fingerprint != state.currentPackageFingerprint)
        #expect(update.ignoredChangedPaths.isEmpty)
        if let candidate = update.candidate {
            try? FileManager.default.removeItem(at: candidate.sourceURL.deletingLastPathComponent())
        }
    }

    @Test("New possible runtime content and missing selected content require review")
    func sourceShapeChangesRequireReview() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Use scripts/run.sh."))
        try fixture.write("skills/demo/scripts/run.sh", "echo v1")
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent()) }
        let state = LocalSourceState(
            skillID: UUID(),
            projectRootPath: fixture.projectRoot.path,
            recipe: resolved.recipe,
            currentPackageFingerprint: resolved.candidate.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        )

        try fixture.write("skills/demo/templates/new.txt", "new runtime")
        let newRuntime = try await resolver.check(state: state)
        #expect(newRuntime.state.status == .packageReviewRequired)
        #expect(newRuntime.review?.newUnreviewedPaths == ["templates"])
        #expect(newRuntime.candidate == nil)

        try FileManager.default.removeItem(at: fixture.skillRoot.appendingPathComponent("templates"))
        try FileManager.default.removeItem(at: fixture.skillRoot.appendingPathComponent("scripts"))
        let missingSelection = try await resolver.check(state: state)
        #expect(missingSelection.state.status == .packageReviewRequired)
        #expect(missingSelection.review?.missingSelectedPaths == ["scripts"])
        #expect(missingSelection.candidate == nil)
    }

    @Test("Tracked source state survives restart and stopping tracking preserves every content copy")
    func persistenceAndStopTrackingPreserveContent() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Demo"))
        try fixture.write("skills/demo/scripts/run.sh", "echo ready")
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(resolved.candidate)
        try await store.updateLocalSourceState(.init(
            skillID: record.id,
            projectRootPath: fixture.projectRoot.path,
            recipe: resolved.recipe,
            currentPackageFingerprint: record.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        ))
        try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent())

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        let persisted = try #require(await reloaded.currentSnapshot().localSourceStates.first)
        #expect(persisted.projectRootPath == fixture.projectRoot.path)
        #expect(persisted.recipe.skillRelativePath == "skills/demo")
        #expect(persisted.recipe.includePaths == ["SKILL.md", "scripts"])
        let contentURL = await reloaded.contentURL(for: record)
        let centralFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: contentURL)

        try await reloaded.stopTrackingLocalSource(skillID: record.id)
        let stopped = await reloaded.currentSnapshot()
        #expect(stopped.localSourceStates.isEmpty)
        #expect(stopped.skills.first?.source.displayName == "SkillBox 中的本地副本")
        #expect(FileManager.default.fileExists(atPath: contentURL.appendingPathComponent("SKILL.md").path))
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: contentURL) == centralFingerprint)
        #expect(FileManager.default.fileExists(atPath: fixture.skillRoot.appendingPathComponent("SKILL.md").path))
    }

    @Test("An unavailable development source preserves the central Skill and installed copy")
    func unavailableSourcePreservesExistingCopies() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Demo"))
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(resolved.candidate)
        let state = LocalSourceState(
            skillID: record.id,
            projectRootPath: fixture.projectRoot.path,
            recipe: resolved.recipe,
            currentPackageFingerprint: record.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        )
        try await store.updateLocalSourceState(state)
        try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent())

        let targetRoot = fixture.root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(
            kind: .custom,
            displayName: "Test",
            path: targetRoot.path,
            detectionStatus: .available,
            writeStatus: .writable,
            isCustom: true
        )
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(
            skillID: record.id,
            targetID: target.id,
            installationDirectoryName: "demo"
        )])
        let planner = DefaultSyncPlanner()
        _ = try await TransactionalSyncExecutor().execute(
            plan: planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot),
            store: store
        )
        let centralURL = await store.contentURL(for: record)
        let installedURL = targetRoot.appendingPathComponent("demo", isDirectory: true)
        let centralFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: centralURL)
        let installedFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: installedURL)

        try FileManager.default.removeItem(at: fixture.projectRoot)
        let result = try await resolver.check(state: state)
        try await store.updateLocalSourceState(result.state)

        #expect(result.state.status == .sourceUnavailable)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: centralURL) == centralFingerprint)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: installedURL) == installedFingerprint)
        #expect(await store.currentSnapshot().skills.first?.fingerprint == record.fingerprint)
    }

    @Test("A moved project is recovered through its bookmark and refreshes the displayed path")
    func movedProjectBookmarkRefreshesPath() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Demo"))
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        defer { try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent()) }
        let bookmark = try #require(LocalSkillPackageResolver.bookmarkData(for: fixture.projectRoot))
        let state = LocalSourceState(
            skillID: UUID(),
            projectRootPath: fixture.projectRoot.path,
            projectRootBookmarkData: bookmark,
            recipe: resolved.recipe,
            currentPackageFingerprint: resolved.candidate.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        )
        let movedProject = fixture.root.appendingPathComponent("Project Moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.projectRoot, to: movedProject)

        let result = try await resolver.check(state: state)

        #expect(result.state.status == .current)
        #expect(result.state.projectRootPath == movedProject.path)
    }

    @Test("Undoing a local-source update restores the pure snapshot while keeping the newer source visible")
    func localSourceUpdateUndoRestoresStateAndContent() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Use scripts/run.sh."))
        try fixture.write("skills/demo/scripts/run.sh", "echo v1")
        let resolver = LocalSkillPackageResolver()
        let review = try resolver.review(candidate: try await fixture.candidate(), projectRoot: fixture.projectRoot)
        let resolved = try await resolver.confirm(review: review, includePaths: review.recommendedIncludePaths)
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(resolved.candidate)
        let originalState = LocalSourceState(
            skillID: original.id,
            projectRootPath: fixture.projectRoot.path,
            recipe: resolved.recipe,
            currentPackageFingerprint: original.fingerprint,
            topLevelFingerprints: resolved.topLevelFingerprints,
            status: .current
        )
        try await store.updateLocalSourceState(originalState)
        try? FileManager.default.removeItem(at: resolved.candidate.sourceURL.deletingLastPathComponent())

        try fixture.write("skills/demo/scripts/run.sh", "echo v2")
        let check = try await resolver.check(state: originalState)
        let updateCandidate = try #require(check.candidate)
        defer { try? FileManager.default.removeItem(at: updateCandidate.sourceURL.deletingLastPathComponent()) }
        try await store.updateLocalSourceState(check.state)
        let result = try await SkillUpdateCoordinator().updateCentralOnly(
            skillID: original.id,
            candidate: updateCandidate,
            store: store
        )
        let transaction = try #require(result.transaction)
        var installedState = check.state
        installedState.currentPackageFingerprint = result.record.fingerprint
        installedState.topLevelFingerprints = try #require(check.state.availableTopLevelFingerprints)
        installedState.availablePackageFingerprint = nil
        installedState.availableTopLevelFingerprints = nil
        installedState.status = .current
        try await store.recordLocalSourceUpdate(installedState, transactionID: transaction.id)

        _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store)

        let snapshot = await store.currentSnapshot()
        let restoredState = try #require(snapshot.localSourceStates.first)
        let restoredRecord = try #require(snapshot.skills.first)
        let restoredText = try String(
            contentsOf: await store.contentURL(for: restoredRecord).appendingPathComponent("scripts/run.sh"),
            encoding: .utf8
        )
        #expect(restoredRecord.fingerprint == original.fingerprint)
        #expect(restoredState.currentPackageFingerprint == originalState.currentPackageFingerprint)
        #expect(restoredState.status == .updateAvailable)
        #expect(restoredState.availablePackageFingerprint == result.record.fingerprint)
        #expect(restoredText == "echo v1")
    }

    @MainActor
    @Test("The app asks for local source confirmation before exposing import candidates")
    func appPreviewRequiresSourceConfirmation() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", fixture.skillMarkdown("Use scripts/run.sh."))
        try fixture.write("skills/demo/scripts/run.sh", "echo ready")
        try fixture.write("skills/demo/tests/fixture.md", "development")
        let store = try LibraryStore(root: fixture.storeRoot)
        let model = AppModel(
            libraryRoot: fixture.storeRoot,
            store: store,
            homeDirectory: fixture.root,
            startBootstrap: false
        )

        await model.previewLocalFolder(fixture.projectRoot)

        let setup = try #require(model.pendingLocalSourceSetup)
        #expect(setup.reviews.count == 1)
        #expect(model.pendingCandidates.isEmpty)
        let review = try #require(setup.reviews.first)

        await model.confirmLocalSourceSetup(
            setup,
            trackChanges: true,
            includePathsByCandidate: [review.candidate.id: review.recommendedIncludePaths]
        )
        #expect(model.pendingCandidates.count == 1)
        #expect(model.pendingCandidates.first?.source.displayName == "本地开发源")
        let temporaryPackageRoot = try #require(model.pendingCandidates.first?.temporaryPackageRoot)
        #expect(FileManager.default.fileExists(atPath: temporaryPackageRoot.path))
        await model.importSelectedCandidates()

        #expect(model.snapshot.skills.count == 1)
        #expect(model.snapshot.localSourceStates.count == 1)
        #expect(!FileManager.default.fileExists(atPath: temporaryPackageRoot.path))
        let content = await store.contentURL(for: try #require(model.snapshot.skills.first))
        #expect(!FileManager.default.fileExists(atPath: content.appendingPathComponent("tests").path))
    }

    @MainActor
    @Test("Cancelling a preview never deletes a user-owned folder based only on its name")
    func cancellingPreviewPreservesUserOwnedPrefixedFolder() async throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        let userRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxLocalPackage-user-owned-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: userRoot) }
        let content = userRoot.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try fixture.skillMarkdown("User data")
            .write(to: content.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let candidate = SkillCandidate(
            sourceURL: content,
            directoryName: "demo",
            canonicalName: "demo",
            displayName: "Demo",
            description: "User-owned folder",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: content),
            source: .init(kind: .localFolder, displayName: "电脑文件夹", locator: content.path),
            riskReport: try StaticRiskAnalyzer().analyze(skillDirectory: content)
        )
        let store = try LibraryStore(root: fixture.storeRoot)
        let model = AppModel(
            libraryRoot: fixture.storeRoot,
            store: store,
            homeDirectory: fixture.root,
            startBootstrap: false
        )
        model.pendingCandidates = [candidate]

        model.cancelCandidatePreview()

        #expect(FileManager.default.fileExists(atPath: content.appendingPathComponent("SKILL.md").path))
    }

    @MainActor
    @Test("A non-cancellable commit cannot report that it was cancelled")
    func nonCancellableCommitDoesNotReportCancellation() throws {
        let fixture = try LocalSourceFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let model = AppModel(
            libraryRoot: fixture.storeRoot,
            store: store,
            homeDirectory: fixture.root,
            startBootstrap: false
        )
        model.operationProgress = .init(
            title: "正在完成更新",
            detail: "正在安全保存文件",
            canCancel: false
        )

        model.cancelRemoteOperation()

        #expect(model.operationProgress?.canCancel == false)
        #expect(model.statusMessage == "正在完成更新，请稍候")
    }
}

private struct LocalSourceFixture {
    let root: URL
    let projectRoot: URL
    let skillRoot: URL
    let storeRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxLocalSourceTests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        skillRoot = projectRoot.appendingPathComponent("skills/demo", isDirectory: true)
        storeRoot = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    }

    func skillMarkdown(_ body: String) -> String {
        "---\nname: demo\ndescription: Local development demo\n---\n\(body)\n"
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = projectRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func candidate() async throws -> SkillCandidate {
        let result = try await LocalFolderSourceProvider().preview(locator: projectRoot.path)
        return try #require(result.first { $0.canonicalName == "demo" })
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
