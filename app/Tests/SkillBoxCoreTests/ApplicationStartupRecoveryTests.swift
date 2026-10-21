import Foundation
import Testing
@testable import SkillBoxApp
@testable import SkillBoxCore

@MainActor
@Suite("Startup storage failure preserves the real library")
struct ApplicationStartupRecoveryTests {
    @Test("Blocked storage has no empty fallback, preserves data, and can retry", arguments: ["SearchSessions", "AIReviews", "Library"])
    func storageFailureCanRetry(blockedDirectory: String) async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("Store")
        let before = try savedState(in: root)
        let savedHash = try SHA256SkillFingerprinter().fingerprint(directory: fixture.saved)
        let installedHash = try SHA256SkillFingerprinter().fingerprint(directory: fixture.installed)
        let blocked = root.appendingPathComponent(blockedDirectory)
        // Library already contains the saved Skill; move it within this test
        // fixture so the error never deletes the only copy of fixture content.
        let retained = root.appendingPathComponent("retained-\(blockedDirectory)")
        let existed = FileManager.default.fileExists(atPath: blocked.path)
        if existed { try FileManager.default.moveItem(at: blocked, to: retained) }
        let marker = Data("Do not replace this file".utf8)
        try marker.write(to: blocked)
        var attempts = 0
        let startup = ApplicationStartup(libraryRoot: root) {
            attempts += 1
            return try AppModel(libraryRoot: root, homeDirectory: fixture.root, startBootstrap: false)
        }
        #expect(startup.model == nil)
        #expect(startup.errorMessage?.contains("无法打开") == true)
        #expect(startup.errorMessage?.contains(fixture.root.path) == false)
        #expect(try Data(contentsOf: blocked) == marker)
        #expect(try savedState(in: root) == before)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: fixture.installed) == installedHash)
        // A repeated failed attempt must remain unavailable, not silently open
        // a second empty library or overwrite the obstructing user file.
        startup.start()
        #expect(attempts == 2)
        #expect(startup.model == nil)
        #expect(try Data(contentsOf: blocked) == marker)
        #expect(try savedState(in: root) == before)
        try FileManager.default.removeItem(at: blocked)
        if existed { try FileManager.default.moveItem(at: retained, to: blocked) }
        startup.start()
        let model = try #require(startup.model)
        #expect(startup.errorMessage == nil)
        #expect(attempts == 3)
        await model.reload()
        #expect(model.snapshot.skills.map(\.id) == [fixture.record.id])
        #expect(model.snapshot.installations.count == 1)
        #expect(try savedState(in: root) == before)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: fixture.saved) == savedHash)
        #expect(try SHA256SkillFingerprinter().fingerprint(directory: fixture.installed) == installedHash)
        startup.start()
        #expect(startup.model === model)
        #expect(attempts == 3)
    }

    @Test("An invalid root stays intact and reports failure without terminating")
    func invalidRootIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxStartupBlocked-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = Data("Existing root file".utf8)
        try marker.write(to: root)
        let startup = ApplicationStartup(libraryRoot: root) {
            try AppModel(libraryRoot: root, homeDirectory: root.deletingLastPathComponent(), startBootstrap: false)
        }
        #expect(startup.model == nil)
        #expect(startup.errorMessage != nil)
        #expect(try Data(contentsOf: root) == marker)
    }

    private func savedState(in root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["library-state.json", "catalog.json", "assignments.json", "installations.json", "organization.json", "transactions.json"].map {
            ($0, try Data(contentsOf: root.appendingPathComponent($0)))
        })
    }
}
