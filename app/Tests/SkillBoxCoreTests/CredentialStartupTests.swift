import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Credential startup policy", .serialized)
struct CredentialStartupTests {
    @Test("Startup restores non-secret connection hints without reading Keychain values")
    func startupUsesHintsOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillbox-credential-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var settings = AISettings.defaults
        settings.markConnectionVerified(providerID: "deepseek")
        try await AISettingsStore(root: root).save(settings)

        let suiteName = "com.zhaoji.skillbox.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AppModel.githubConnectionHintKey)

        let keyStore = StartupKeyStoreSpy()
        let model = AppModel(
            libraryRoot: root,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            aiKeyStore: keyStore,
            userDefaults: defaults,
            startBootstrap: false
        )

        await model.reloadCredentialHints()

        #expect(model.configuredAIProviderIDs.contains("deepseek"))
        #expect(model.isGitHubConnected)
        #expect(await keyStore.loadCount == 0)
    }
}

private actor StartupKeyStoreSpy: AIKeyStore {
    private(set) var loadCount = 0

    func load(providerID: String) async throws -> String? {
        loadCount += 1
        return "must-not-be-read-during-startup"
    }

    func save(_ apiKey: String, providerID: String) async throws {}
    func delete(providerID: String) async throws {}
}
