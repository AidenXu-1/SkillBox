import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Central library")
struct LibraryStoreTests {
    @Test("Import copies a verified candidate and persists schema envelopes")
    func importAndReload() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let candidate = try fixture.candidate(name: "demo", body: "original")
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(candidate)

        #expect(record.contentRelativePath == "Library/demo/content")
        #expect(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent(record.contentRelativePath).appendingPathComponent("SKILL.md").path))
        let catalogData = try Data(contentsOf: fixture.storeRoot.appendingPathComponent("catalog.json"))
        let json = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 2)

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        #expect(await reloaded.currentSnapshot().skills.count == 1)
    }

    @Test("Same-name versions keep readable folders without colliding")
    func readableFoldersHandleSameNameVersions() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let first = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let second = try await store.importCandidate(fixture.candidate(name: "demo", body: "v2"))

        #expect(first.contentRelativePath == "Library/demo/content")
        #expect(second.contentRelativePath.hasPrefix("Library/demo--"))
        #expect(second.contentRelativePath.hasSuffix("/content"))
        #expect(FileManager.default.fileExists(atPath: await store.contentURL(for: second).appendingPathComponent("SKILL.md").path))
    }

    @Test("Schema v1 GitHub records migrate without downloading or losing content")
    func migratesGitHubSourceState() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        let candidate = try fixture.candidate(name: "demo", body: "central")
        let record = SkillRecord(
            canonicalName: candidate.canonicalName,
            displayName: candidate.displayName,
            description: candidate.description,
            fingerprint: candidate.fingerprint,
            source: .init(
                kind: .github,
                displayName: "example/skills",
                locator: "https://github.com/example/skills",
                repository: "example/skills",
                revision: "main",
                skillPath: "skills/demo"
            ),
            riskReport: candidate.riskReport,
            contentRelativePath: "Library/existing/content"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedEnvelope(schemaVersion: 1, value: [record]))
            .write(to: fixture.storeRoot.appendingPathComponent("catalog.json"))

        let store = try LibraryStore(root: fixture.storeRoot)
        let state = try #require(await store.currentSnapshot().sourceStates.first)
        #expect(state.skillID == record.id)
        #expect(state.trackingMode == .defaultBranch)
        #expect(state.status == .needsInitialCheck)
        #expect(state.checkingEnabled)

        let migratedData = try Data(contentsOf: fixture.storeRoot.appendingPathComponent("catalog.json"))
        let migratedJSON = try #require(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
        #expect(migratedJSON["schemaVersion"] as? Int == 2)
    }

    @Test("Legacy GitHub update false positives are normalized when the store opens")
    func normalizesLegacyGitHubUpdateFalsePositiveOnLoad() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        try await store.updateSourceState(.init(
            skillID: record.id,
            repositoryFullName: "example/skills",
            skillPath: "",
            trackingMode: .latestStableRelease,
            currentVersionIdentifier: "release:42",
            currentVersionName: "v1.4.0",
            currentCommitSHA: "commit-1",
            currentTreeSHA: "tree-1",
            availableVersionIdentifier: "release:42:source:commit-1",
            availableVersionName: "v1.4.0",
            availableCommitSHA: "commit-1",
            availableTreeSHA: "tree-1",
            availableReleaseID: 42,
            checkingEnabled: true,
            status: .updateAvailable
        ))

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        let state = try #require(await reloaded.currentSnapshot().sourceStates.first)
        #expect(state.status == .current)
        #expect(state.currentReleaseID == 42)
        #expect(state.currentVersionIdentifier == "release:42:source:commit-1")
    }

    @Test("Legacy source imports with a clean Release package get a dedicated package status on load")
    func normalizesLegacySourceImportWithCleanPackageOnLoad() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        try await store.updateSourceState(.init(
            skillID: record.id,
            repositoryFullName: "example/skills",
            skillPath: "",
            trackingMode: .latestStableRelease,
            currentVersionIdentifier: "release:42",
            currentVersionName: "v1.4.0",
            currentCommitSHA: "commit-1",
            currentTreeSHA: "tree-1",
            availableVersionIdentifier: "release:42:asset:101:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            availableVersionName: "v1.4.0",
            availableCommitSHA: "commit-1",
            availableTreeSHA: "tree-1",
            availableReleaseID: 42,
            availableAssetID: 101,
            availableAssetName: "demo-pure.zip",
            availableAssetDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            checkingEnabled: true,
            status: .updateAvailable
        ))

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        let state = try #require(await reloaded.currentSnapshot().sourceStates.first)
        #expect(state.status == .releasePackageAvailable)
    }

    @Test("Legacy public-source authorization errors are migrated away from private-login prompts")
    func normalizesLegacyPublicAuthorizationPromptOnLoad() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        try await store.updateSourceState(.init(
            skillID: record.id,
            repositoryFullName: "example/public-skill",
            currentVersionIdentifier: "release:42",
            currentCommitSHA: "commit-1",
            currentTreeSHA: "tree-1",
            availableVersionIdentifier: "release:42",
            availableCommitSHA: "commit-1",
            availableTreeSHA: "tree-1",
            checkingEnabled: true,
            status: .authenticationRequired
        ))

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        let state = try #require(await reloaded.currentSnapshot().sourceStates.first)

        #expect(state.status == .current)
        #expect(state.lastCheckIssue == .temporarilyUnavailable)
    }

    @Test("Legacy UUID folders migrate to readable Skill names")
    func migratesLegacyStorageFolder() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        let candidate = try fixture.candidate(name: "demo", body: "central")
        let record = SkillRecord(
            canonicalName: candidate.canonicalName,
            displayName: candidate.displayName,
            description: candidate.description,
            fingerprint: candidate.fingerprint,
            source: candidate.source,
            riskReport: candidate.riskReport,
            contentRelativePath: "Library/\(UUID().uuidString)/content"
        )
        let legacyContent = fixture.storeRoot.appendingPathComponent(record.contentRelativePath)
        try FileManager.default.createDirectory(at: legacyContent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SafeFileOperations.copyDirectory(from: candidate.sourceURL, to: legacyContent)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(PersistedEnvelope(value: [record]))
            .write(to: fixture.storeRoot.appendingPathComponent("catalog.json"))

        let store = try LibraryStore(root: fixture.storeRoot)

        let migrated = try #require(await store.currentSnapshot().skills.first)
        #expect(migrated.contentRelativePath == "Library/demo/content")
        #expect(FileManager.default.fileExists(atPath: await store.contentURL(for: migrated).appendingPathComponent("SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: legacyContent.deletingLastPathComponent().path))
    }

    @Test("Clearing GitHub information keeps Skills as local copies and removes repository metadata")
    func clearsGitHubInformation() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        var candidate = try fixture.candidate(name: "demo", body: "central")
        candidate.source = .init(
            kind: .github,
            displayName: "owner/private-skill",
            locator: "https://github.com/owner/private-skill",
            repository: "owner/private-skill",
            revision: "v1.0.0",
            skillPath: "skills/demo"
        )
        let record = try await store.importCandidate(candidate)
        try await store.updateSourceState(.init(
            skillID: record.id,
            repositoryID: 42,
            repositoryFullName: "owner/private-skill",
            status: .current
        ))
        try await store.recordTransaction(.init(
            completedAt: Date(),
            status: .succeeded,
            actions: [],
            libraryUpdate: .init(
                previousRecord: record,
                updatedFingerprint: record.fingerprint,
                previousSourceState: .init(skillID: record.id, repositoryFullName: "owner/private-skill"),
                updatedSourceVersionIdentifier: "release-42"
            )
        ))

        try await store.clearGitHubInformation()

        let snapshot = await store.currentSnapshot()
        let keptSkill = try #require(snapshot.skills.first)
        #expect(snapshot.skills.count == 1)
        #expect(snapshot.sourceStates.isEmpty)
        #expect(keptSkill.fingerprint == record.fingerprint)
        #expect(keptSkill.source.kind == .localFolder)
        #expect(keptSkill.source.repository == nil)
        #expect(keptSkill.source.revision == nil)
        #expect(keptSkill.source.skillPath == nil)
        #expect(keptSkill.source.locator == record.contentRelativePath)
        #expect(snapshot.transactions.first?.libraryUpdate?.previousRecord.source.kind == .localFolder)
        #expect(snapshot.transactions.first?.libraryUpdate?.previousSourceState == nil)
        #expect(snapshot.transactions.first?.libraryUpdate?.updatedSourceVersionIdentifier == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent(record.contentRelativePath).appendingPathComponent("SKILL.md").path))
        let persistedFiles = ["catalog.json", "source-state.json", "transactions.json"]
        for file in persistedFiles {
            let text = try String(contentsOf: fixture.storeRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("owner/private-skill"))
        }
    }

    @Test("Blocked candidates never enter the library")
    func blockedImport() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        var candidate = try fixture.candidate(name: "blocked", body: "body")
        candidate.riskReport = RiskReport(scannedFileCount: 1, findings: [.init(severity: .blocked, category: .pathEscape, relativePath: "x", title: "blocked", evidence: "x")])
        let store = try LibraryStore(root: fixture.storeRoot)
        await #expect(throws: LibraryStoreError.self) { try await store.importCandidate(candidate) }
        #expect(await store.currentSnapshot().skills.isEmpty)
    }

    @Test("Stored Skills can be rescanned when risk rules improve")
    func refreshesStoredRiskReports() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        var candidate = try fixture.candidate(name: "cleanup", body: "central")
        try #"rm -rf "$TMP_ROOT""#.write(
            to: candidate.sourceURL.appendingPathComponent("cleanup.sh"),
            atomically: true,
            encoding: .utf8
        )
        candidate.fingerprint = try SHA256SkillFingerprinter().fingerprint(directory: candidate.sourceURL)
        candidate.riskReport = RiskReport(scannedFileCount: 2, findings: [
            .init(severity: .high, category: .deletion, relativePath: "cleanup.sh", title: "旧规则", evidence: "旧规则"),
        ])
        let record = try await store.importCandidate(candidate)

        try await store.refreshRiskReports(using: StaticRiskAnalyzer())

        let refreshed = try #require(await store.currentSnapshot().skills.first { $0.id == record.id })
        let deletion = try #require(refreshed.riskReport.findings.first { $0.category == .deletion })
        #expect(deletion.severity == .caution)
        #expect(deletion.evidence == #"rm -rf "$TMP_ROOT""#)
    }

    @Test("Refreshing stored Skills repairs descriptions with the current metadata parser")
    func refreshesStoredMetadata() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        var candidate = try fixture.candidate(name: "writing", body: "# Writing")
        try """
        ---
        name: writing
        description: >-
          完成内容写作与质量把关。
          适合完整创作和轻量编辑。
        ---

        # Writing
        """.write(to: candidate.sourceURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        candidate.description = ">-"
        candidate.fingerprint = try SHA256SkillFingerprinter().fingerprint(directory: candidate.sourceURL)
        let record = try await store.importCandidate(candidate)

        try await store.refreshRiskReports(using: StaticRiskAnalyzer())

        let refreshed = try #require(await store.currentSnapshot().skills.first { $0.id == record.id })
        #expect(refreshed.description == "完成内容写作与质量把关。 适合完整创作和轻量编辑。")
    }

    @Test("GitHub-style updates archive the prior central version")
    func updateArchivesOldContent() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let updatedCandidate = try fixture.candidate(name: "demo", body: "v2")
        let updated = try await store.updateSkill(id: original.id, with: updatedCandidate)
        #expect(updated.id == original.id)
        #expect(updated.fingerprint != original.fingerprint)
        let archived = await store.contentURL(for: original).deletingLastPathComponent()
            .appendingPathComponent("versions/\(original.fingerprint)/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: archived.path))
    }

    @Test("Corrupt metadata is preserved instead of overwritten")
    func corruptMetadataRecovery() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.storeRoot.appendingPathComponent("catalog.json"))
        let store = try LibraryStore(root: fixture.storeRoot)
        #expect(await store.currentSnapshot().skills.isEmpty)
        let recoveryWarnings = await store.recoveryWarnings
        #expect(recoveryWarnings.count == 1)
        let recovered = try FileManager.default.contentsOfDirectory(at: fixture.storeRoot.appendingPathComponent("CorruptData"), includingPropertiesForKeys: nil)
        #expect(recovered.contains { $0.lastPathComponent.hasSuffix("catalog.json") })
    }

    @Test("Two desired versions cannot share one Agent destination")
    func duplicateDestination() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let targetID = UUID()
        await #expect(throws: LibraryStoreError.self) {
            try await store.replaceAssignments([
                .init(skillID: UUID(), targetID: targetID, installationDirectoryName: "Demo"),
                .init(skillID: UUID(), targetID: targetID, installationDirectoryName: "demo"),
            ])
        }
    }

    @Test("Deleting a central Skill archives its content and clears unused choices")
    func deleteArchivesCentralSkill() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let target = AgentTarget(kind: .custom, displayName: "Test", path: fixture.root.appendingPathComponent("target").path)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo", isDesired: false)])

        let deletion = try await store.deleteSkill(id: record.id)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.skills.isEmpty)
        #expect(snapshot.assignments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: deletion.archivedURL.appendingPathComponent("content/SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: await store.contentURL(for: record).deletingLastPathComponent().path))
    }

    @Test("A recently deleted Skill can be restored with its organization and source state")
    func restoreDeletedSkill() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let folder = SkillFolder(name: "写作", sortIndex: 0)
        var organization = SkillOrganization(folders: [folder])
        organization.normalize(skillIDs: [record.id])
        organization.moveSkill(record.id, to: folder.id)
        try await store.replaceOrganization(organization)
        let sourceState = GitHubSourceState(skillID: record.id, repositoryFullName: "owner/demo")
        try await store.updateSourceState(sourceState)

        let deletion = try await store.deleteSkill(id: record.id)
        let restored = try await store.restoreDeletedSkill(deletion)

        let snapshot = await store.currentSnapshot()
        #expect(restored.id == record.id)
        #expect(snapshot.skills.map(\.id) == [record.id])
        #expect(snapshot.organization.placements.first { $0.skillID == record.id }?.folderID == folder.id)
        #expect(snapshot.sourceStates.first { $0.skillID == record.id }?.repositoryFullName == "owner/demo")
        #expect(FileManager.default.fileExists(atPath: await store.contentURL(for: record).appendingPathComponent("SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: deletion.archivedURL.path))
    }

    @Test("Restoring a deleted Skill avoids a new same-name folder")
    func restoreDeletedSkillWithSameNameCollision() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        let deletion = try await store.deleteSkill(id: original.id)
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        _ = try await store.importCandidate(fixture.candidate(name: "demo", body: "v2"))

        let restored = try await store.restoreDeletedSkill(deletion)

        #expect(restored.contentRelativePath.hasPrefix("Library/demo--"))
        #expect(FileManager.default.fileExists(atPath: await store.contentURL(for: restored).appendingPathComponent("SKILL.md").path))
    }

    @Test("Removing a custom installation location clears only its pending choices")
    func removeCustomTarget() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let custom = AgentTarget(kind: .custom, displayName: "My Agent", path: fixture.root.appendingPathComponent("custom").path, isCustom: true)
        let builtin = AgentTarget(kind: .codex, displayName: "Codex", path: fixture.root.appendingPathComponent("codex").path)
        try await store.replaceTargets([builtin, custom])
        try await store.replaceAssignments([
            .init(skillID: record.id, targetID: builtin.id, installationDirectoryName: "demo"),
            .init(skillID: record.id, targetID: custom.id, installationDirectoryName: "demo"),
        ])

        try await store.removeCustomTarget(id: custom.id)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.targets.map(\.id) == [builtin.id])
        #expect(snapshot.assignments.map(\.targetID) == [builtin.id])
    }

    @Test("Deleting a Skill is blocked while SkillBox still manages an installed copy")
    func deleteBlocksManagedInstallation() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        try await store.replaceInstallations([
            .init(skillID: record.id, targetID: UUID(), destinationPath: "/tmp/demo", deployedFingerprint: record.fingerprint, transactionID: UUID()),
        ])

        await #expect(throws: LibraryStoreError.self) {
            try await store.deleteSkill(id: record.id)
        }
        #expect(await store.currentSnapshot().skills.count == 1)
    }

    @Test("Skill folders and drag order persist without moving Skill content")
    func organizationPersists() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let first = try await store.importCandidate(fixture.candidate(name: "first", body: "one"))
        let second = try await store.importCandidate(fixture.candidate(name: "second", body: "two"))
        let work = SkillFolder(name: "工作", sortIndex: 0)
        let personal = SkillFolder(name: "个人", sortIndex: 1)
        var organization = SkillOrganization(folders: [work, personal])
        organization.normalize(skillIDs: [first.id, second.id])
        organization.moveSkill(second.id, to: work.id)
        organization.moveSkill(first.id, to: work.id, before: second.id)
        organization.moveFolder(personal.id, before: work.id)
        try await store.replaceOrganization(organization)

        let reloaded = try LibraryStore(root: fixture.storeRoot)
        var persisted = await reloaded.currentSnapshot().organization
        #expect(persisted.folders.map(\.name) == ["个人", "工作"])
        #expect(persisted.placements.filter { $0.folderID == work.id }.sorted { $0.sortIndex < $1.sortIndex }.map(\.skillID) == [first.id, second.id])
        #expect(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent(first.contentRelativePath).path))

        persisted.deleteFolder(work.id)
        try await reloaded.replaceOrganization(persisted)
        let afterDelete = await reloaded.currentSnapshot()
        #expect(afterDelete.skills.count == 2)
        #expect(afterDelete.organization.placements.allSatisfy { $0.folderID == nil })
    }
}

@Suite("Transactional sync")
struct SyncTests {
    @Test("A failed update restores both the central original and deployed copies")
    func combinedUpdateFailureRestoresEverything() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: original.id, targetID: target.id, installationDirectoryName: "demo")])
        let initialPlan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        _ = try await TransactionalSyncExecutor().execute(plan: initialPlan, store: store)

        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let update = try fixture.candidate(name: "demo", body: "v2")
        let failingExecutor = TransactionalSyncExecutor(shouldInjectFailure: { $0 == 1 })
        let coordinator = SkillUpdateCoordinator(executor: failingExecutor)
        await #expect(throws: SyncExecutorError.self) {
            try await coordinator.updateAndDeploy(skillID: original.id, candidate: update, store: store)
        }

        let restored = try #require(await store.currentSnapshot().skills.first)
        #expect(restored.fingerprint == original.fingerprint)
        let centralText = try String(contentsOf: await store.contentURL(for: restored).appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(centralText.contains("v1"))
        let installedText = try String(contentsOf: targetRoot.appendingPathComponent("demo/SKILL.md"), encoding: .utf8)
        #expect(installedText.contains("v1"))
    }

    @Test("Undoing a combined update restores the central version and deployed copy")
    func combinedUpdateUndo() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: original.id, targetID: target.id, installationDirectoryName: "demo")])
        let planner = DefaultSyncPlanner()
        let executor = TransactionalSyncExecutor()
        _ = try await executor.execute(plan: planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot), store: store)

        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let update = try fixture.candidate(name: "demo", body: "v2")
        let result = try await SkillUpdateCoordinator(executor: executor).updateAndDeploy(skillID: original.id, candidate: update, store: store)
        let transaction = try #require(result.transaction)
        #expect(transaction.libraryUpdate != nil)
        _ = try await executor.undo(transactionID: transaction.id, store: store)

        let restored = try #require(await store.currentSnapshot().skills.first)
        #expect(restored.fingerprint == original.fingerprint)
        let centralText = try String(contentsOf: await store.contentURL(for: restored).appendingPathComponent("SKILL.md"), encoding: .utf8)
        let installedText = try String(contentsOf: targetRoot.appendingPathComponent("demo/SKILL.md"), encoding: .utf8)
        #expect(centralText.contains("v1"))
        #expect(installedText.contains("v1"))
    }

    @Test("Updating only My Skills creates a visible transaction that can be undone")
    func centralOnlyUpdateUndo() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let update = try fixture.candidate(name: "demo", body: "v2")

        let result = try await SkillUpdateCoordinator().updateCentralOnly(skillID: original.id, candidate: update, store: store)
        let transaction = try #require(result.transaction)
        #expect(transaction.backups.isEmpty)
        #expect(transaction.libraryUpdate?.previousRecord.fingerprint == original.fingerprint)
        #expect(await store.currentSnapshot().transactions.first?.id == transaction.id)

        _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store)
        let restored = try #require(await store.currentSnapshot().skills.first)
        #expect(restored.fingerprint == original.fingerprint)
        let centralText = try String(contentsOf: await store.contentURL(for: restored).appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(centralText.contains("v1"))
    }

    @Test("Undoing a GitHub update also restores the tracked source version")
    func githubSourceStateUndo() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        let previousState = GitHubSourceState(
            skillID: original.id,
            repositoryFullName: "owner/demo",
            currentVersionIdentifier: "release-1",
            currentVersionName: "v1",
            currentTreeSHA: "tree-1",
            currentReleaseID: 41,
            currentAssetID: 101,
            currentAssetName: "demo-pure.zip",
            currentAssetDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            status: .current
        )
        try await store.updateSourceState(previousState)
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let update = try fixture.candidate(name: "demo", body: "v2")
        let result = try await SkillUpdateCoordinator().updateCentralOnly(skillID: original.id, candidate: update, store: store)
        let transaction = try #require(result.transaction)
        let updatedState = GitHubSourceState(
            skillID: original.id,
            repositoryFullName: "owner/demo",
            currentVersionIdentifier: "release-2",
            currentVersionName: "v2",
            currentTreeSHA: "tree-2",
            currentReleaseID: 42,
            currentAssetID: 102,
            currentAssetName: "demo-pure.zip",
            currentAssetDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            status: .current
        )

        try await store.recordGitHubSourceUpdate(updatedState, transactionID: transaction.id)
        _ = try await TransactionalSyncExecutor().undo(transactionID: transaction.id, store: store)

        let restoredState = try #require(await store.currentSnapshot().sourceStates.first)
        #expect(restoredState.currentVersionIdentifier == "release-1")
        #expect(restoredState.currentTreeSHA == "tree-1")
        #expect(restoredState.currentReleaseID == 41)
        #expect(restoredState.currentAssetID == 101)
        #expect(restoredState.currentAssetName == "demo-pure.zip")
        #expect(restoredState.currentAssetDigest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test("Updating a Skill never turns a pending deselection into an uninstall")
    func combinedUpdateDoesNotExecutePendingRemoval() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let original = try await store.importCandidate(fixture.candidate(name: "demo", body: "v1"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: original.id, targetID: target.id, installationDirectoryName: "demo")])
        let planner = DefaultSyncPlanner()
        let executor = TransactionalSyncExecutor()
        _ = try await executor.execute(plan: planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot), store: store)

        try await store.replaceAssignments([.init(skillID: original.id, targetID: target.id, installationDirectoryName: "demo", isDesired: false)])
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent("demo"))
        let update = try fixture.candidate(name: "demo", body: "v2")
        let result = try await SkillUpdateCoordinator(executor: executor).updateAndDeploy(skillID: original.id, candidate: update, store: store)

        let transaction = try #require(result.transaction)
        #expect(transaction.backups.isEmpty)
        #expect(transaction.actions.allSatisfy { $0.kind != .remove })
        #expect(transaction.libraryUpdate != nil)
        let installedText = try String(contentsOf: targetRoot.appendingPathComponent("demo/SKILL.md"), encoding: .utf8)
        #expect(installedText.contains("v1"))
        #expect(await store.currentSnapshot().installations.count == 1)
    }

    @Test("Plan, execute and undo preserve ownership boundaries")
    func executeAndUndo() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])

        let planner = DefaultSyncPlanner()
        let plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.map(\.kind) == [.create])
        let executor = TransactionalSyncExecutor()
        let transaction = try await executor.execute(plan: plan, store: store)
        let installed = targetRoot.appendingPathComponent("demo")
        #expect(transaction.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
        #expect(await store.currentSnapshot().installations.count == 1)

        let undone = try await executor.undo(transactionID: transaction.id, store: store)
        #expect(undone.status == .undone)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(await store.currentSnapshot().installations.isEmpty)
    }

    @Test("Unmanaged conflicts and external modifications block writes and undo")
    func conflictsAndDrift() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        let destination = try fixture.writeSkill(at: targetRoot.appendingPathComponent("demo"), name: "demo", body: "foreign")
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])
        let planner = DefaultSyncPlanner()
        var plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        let conflict = try #require(plan.actions.first)
        let destinationFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: destination)
        #expect(conflict.blockReason == .unmanagedConflict)
        #expect(conflict.expectedSourceFingerprint == record.fingerprint)
        #expect(conflict.expectedDestinationFingerprint == destinationFingerprint)
        #expect(conflict.expectedSourceFingerprint != conflict.expectedDestinationFingerprint)

        try FileManager.default.removeItem(at: destination)
        plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        let executor = TransactionalSyncExecutor()
        let transaction = try await executor.execute(plan: plan, store: store)
        try "external".write(to: destination.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: SyncExecutorError.self) { try await executor.undo(transactionID: transaction.id, store: store) }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra.txt").path))

        let driftPlan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(driftPlan.actions.contains { $0.blockReason == .externalModification })
    }

    @Test("Replacement permission is bound to the previewed fingerprint")
    func replacementAuthorizationExpiresWhenTargetChanges() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("target")
        let destination = try fixture.writeSkill(at: targetRoot.appendingPathComponent("demo"), name: "demo", body: "foreign-v1")
        let target = AgentTarget(kind: .custom, displayName: "Test", path: targetRoot.path, detectionStatus: .available, writeStatus: .writable, isCustom: true)
        let authorizedFingerprint = try SHA256SkillFingerprinter().fingerprint(directory: destination)
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(
            skillID: record.id,
            targetID: target.id,
            installationDirectoryName: "demo",
            allowReplacement: true,
            authorizedDestinationFingerprint: authorizedFingerprint
        )])
        let planner = DefaultSyncPlanner()
        var plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.first?.kind == .update)

        try "changed after confirmation".write(to: destination.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        plan = try planner.makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        #expect(plan.actions.first?.kind == .blocked)
        #expect(plan.actions.first?.blockReason == .unmanagedConflict)
    }

    @Test("A mid-transaction failure restores every completed target")
    func injectedFailureRollsBackCompletedTargets() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        var targets: [AgentTarget] = []
        for index in 1...3 {
            let root = fixture.root.appendingPathComponent("target-\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            targets.append(.init(
                kind: .custom,
                displayName: "Target \(index)",
                path: root.path,
                detectionStatus: .available,
                writeStatus: .writable,
                isCustom: true
            ))
        }
        try await store.replaceTargets(targets)
        try await store.replaceAssignments(targets.map {
            .init(skillID: record.id, targetID: $0.id, installationDirectoryName: "demo")
        })
        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)
        let executor = TransactionalSyncExecutor(shouldInjectFailure: { $0 == 2 })
        await #expect(throws: SyncExecutorError.self) {
            try await executor.execute(plan: plan, store: store)
        }

        for target in targets {
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: target.path).appendingPathComponent("demo").path))
        }
        let snapshot = await store.currentSnapshot()
        #expect(snapshot.installations.isEmpty)
        #expect(snapshot.transactions.first?.status == .rolledBack)
    }

    @Test("Missing application directories are blocked and never created")
    func missingTargetDirectoryNeverCreated() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let targetRoot = fixture.root.appendingPathComponent("missing-target")
        let target = AgentTarget(
            kind: .custom,
            displayName: "Missing App",
            path: targetRoot.path,
            detectionStatus: .directoryMissing,
            writeStatus: .directoryMissing,
            isCustom: true
        )
        try await store.replaceTargets([target])
        try await store.replaceAssignments([.init(skillID: record.id, targetID: target.id, installationDirectoryName: "demo")])

        let plan = try DefaultSyncPlanner().makePlan(snapshot: await store.currentSnapshot(), libraryRoot: fixture.storeRoot)

        #expect(plan.executableActions.isEmpty)
        #expect(plan.blockedActions.first?.blockReason == .targetUnavailable)
        #expect(!FileManager.default.fileExists(atPath: targetRoot.path))
    }

    @Test("Executor rejects a stale create plan when its application directory disappeared")
    func executorRejectsMissingParentDirectory() async throws {
        let fixture = try SyncFixture()
        defer { fixture.remove() }
        let store = try LibraryStore(root: fixture.storeRoot)
        let record = try await store.importCandidate(fixture.candidate(name: "demo", body: "central"))
        let target = AgentTarget(kind: .custom, displayName: "Gone", path: fixture.root.appendingPathComponent("gone").path)
        try await store.replaceTargets([target])
        let destination = URL(fileURLWithPath: target.path).appendingPathComponent("demo")
        let stalePlan = SyncPlan(actions: [
            .init(
                kind: .create,
                skillID: record.id,
                targetID: target.id,
                destinationPath: destination.path,
                expectedSourceFingerprint: record.fingerprint,
                summary: "stale"
            ),
        ])

        await #expect(throws: SyncExecutorError.self) {
            try await TransactionalSyncExecutor().execute(plan: stalePlan, store: store)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

private struct SyncFixture {
    let root: URL
    var sourceRoot: URL { root.appendingPathComponent("source") }
    var storeRoot: URL { root.appendingPathComponent("store") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func candidate(name: String, body: String) throws -> SkillCandidate {
        let url = try writeSkill(at: sourceRoot.appendingPathComponent(name), name: name, body: body)
        let risk = try StaticRiskAnalyzer().analyze(skillDirectory: url)
        return SkillCandidate(
            sourceURL: url,
            directoryName: name,
            canonicalName: name,
            displayName: name,
            description: "Test \(name)",
            fingerprint: try SHA256SkillFingerprinter().fingerprint(directory: url),
            source: .init(kind: .localFolder, displayName: "Fixture", locator: url.path),
            riskReport: risk
        )
    }

    func writeSkill(at url: URL, name: String, body: String) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: Test\n---\n\n\(body)\n".write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
