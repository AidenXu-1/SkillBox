import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Installable Skill package resolver")
struct SkillPackageResolverTests {
    @Test("A mixed root repository asks once instead of importing repository files")
    func mixedRootNeedsConfirmation() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("scripts/run.sh", "#!/bin/sh\necho ok\n")
        try fixture.write("templates/project.txt", "template")
        try fixture.write("README.md", "Repository homepage")
        try fixture.write(".github/workflows/ci.yml", "name: CI")
        let candidate = try await fixture.candidate()

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .needsConfirmation(review) = resolution else {
            Issue.record("Expected a one-time package review")
            return
        }
        #expect(review.recommendedIncludePaths == ["SKILL.md", "scripts", "templates"])
        #expect(review.repositoryOnlyPaths == [".github", "README.md"])
        #expect(review.entries.map(\.relativePath) == [".github", "README.md", "SKILL.md", "scripts", "templates"])
    }

    @Test("Root-level runtime files are kept by default and references in SKILL.md are required")
    func rootRuntimeFileIsProtected() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write(
            "SKILL.md",
            "---\nname: demo\ndescription: Demo\n---\nRun `bash <skill-dir>/scaffold.sh` to create the project.\n"
        )
        try fixture.write("scaffold.sh", "#!/bin/sh\necho ready\n")
        try fixture.write("README.md", "Repository homepage")
        let candidate = try await fixture.candidate()

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .needsConfirmation(review) = resolution else {
            Issue.record("Expected a package review")
            return
        }
        #expect(review.recommendedIncludePaths == ["SKILL.md", "scaffold.sh"])
        #expect(review.entries.first(where: { $0.relativePath == "scaffold.sh" })?.kind == .required)
    }

    @Test("Repository-looking files remain required when SKILL.md explicitly depends on them")
    func referencedRepositoryFileIsProtected() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write(
            "SKILL.md",
            "---\nname: demo\ndescription: Demo\n---\nRead README.md before continuing.\n"
        )
        try fixture.write("README.md", "Required runtime instructions")
        try fixture.write(".github/workflows/ci.yml", "name: CI")
        let candidate = try await fixture.candidate()

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .needsConfirmation(review) = resolution else {
            Issue.record("Expected a package review")
            return
        }
        #expect(review.recommendedIncludePaths == ["SKILL.md", "README.md"])
        #expect(review.repositoryOnlyPaths == [".github"])
        #expect(review.entries.first(where: { $0.relativePath == "README.md" })?.kind == .required)
    }

    @Test("A saved recipe that omitted a referenced runtime file must be reviewed again")
    func legacyRecipeMissingRequiredFileNeedsReview() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write(
            "SKILL.md",
            "---\nname: demo\ndescription: Demo\n---\nRun scaffold.sh to create the project.\n"
        )
        try fixture.write("scaffold.sh", "#!/bin/sh\necho ready\n")
        try fixture.write("scripts/verify.sh", "#!/bin/sh\nexit 0\n")
        let candidate = try await fixture.candidate()
        let incompleteRecipe = fixture.recipe(
            includePaths: ["SKILL.md", "scripts"],
            reviewed: ["SKILL.md", "scaffold.sh", "scripts"]
        )

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(identifier: "commit:2"),
            archiveIsReleaseAsset: false,
            existingRecipe: incompleteRecipe
        )

        guard case let .needsConfirmation(review) = resolution else {
            Issue.record("An incomplete saved recipe must not silently remain incomplete")
            return
        }
        #expect(review.recommendedIncludePaths == ["SKILL.md", "scaffold.sh", "scripts"])
        #expect(review.entries.first(where: { $0.relativePath == "scaffold.sh" })?.kind == .required)
    }

    @Test("Unknown top-level content is preserved by default")
    func possibleRuntimeIsSelectedByDefault() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("runtime-config.json", "{}")
        try fixture.write("README.md", "Repository homepage")
        let candidate = try await fixture.candidate()

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .needsConfirmation(review) = resolution else {
            Issue.record("Expected a package review")
            return
        }
        #expect(review.recommendedIncludePaths == ["SKILL.md", "runtime-config.json"])
    }

    @Test("A confirmed recipe materializes only installable content")
    func confirmationCreatesPurePackage() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("scripts/run.sh", "#!/bin/sh\necho ok\n")
        try fixture.write("templates/project.txt", "template")
        try fixture.write("README.md", "Repository homepage")
        try fixture.write("CHANGELOG.md", "History")
        let candidate = try await fixture.candidate()
        let initial = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )
        guard case let .needsConfirmation(review) = initial else {
            Issue.record("Expected a package review")
            return
        }

        let confirmed = try await GitHubSkillPackageResolver().confirm(
            review: review,
            includePaths: ["SKILL.md", "scripts", "templates"]
        )
        guard case let .ready(package) = confirmed else {
            Issue.record("Expected a resolved package")
            return
        }
        #expect(package.recipe.origin == .userSelection)
        #expect(package.recipe.includePaths == ["SKILL.md", "scripts", "templates"])
        #expect(FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("scripts/run.sh").path))
        #expect(FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("templates/project.txt").path))
        #expect(!FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("README.md").path))
        #expect(!FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("CHANGELOG.md").path))
    }

    @Test("An explicit manifest keeps custom runtime directories without guessing")
    func manifestResolvesCustomRuntime() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("custom-runtime/prompt.txt", "prompt")
        try fixture.write("README.md", "Repository homepage")
        try fixture.write("skillbox.json", #"{"schemaVersion":1,"include":["SKILL.md","custom-runtime"]}"#)
        let candidate = try await fixture.candidate()

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .ready(package) = resolution else {
            Issue.record("Expected manifest resolution")
            return
        }
        #expect(package.recipe.origin == .manifest)
        #expect(package.recipe.includePaths == ["SKILL.md", "custom-runtime"])
        #expect(FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("custom-runtime/prompt.txt").path))
        #expect(!FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("README.md").path))
        #expect(!FileManager.default.fileExists(atPath: package.candidate.sourceURL.appendingPathComponent("skillbox.json").path))
    }

    @Test("Unsafe or incomplete manifests are rejected")
    func rejectsUnsafeManifest() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("skillbox.json", #"{"schemaVersion":1,"include":["../outside"]}"#)
        let candidate = try await fixture.candidate()

        await #expect(throws: GitHubPackageError.self) {
            _ = try await GitHubSkillPackageResolver().resolve(
                candidate: candidate,
                version: fixture.version(),
                archiveIsReleaseAsset: false
            )
        }
    }

    @Test("An explicit Skill subdirectory remains a complete package")
    func nestedSkillIsAutomatic() async throws {
        let fixture = try PackageFixture(skillPath: "skills/demo")
        defer { fixture.remove() }
        try fixture.write("skills/demo/SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("skills/demo/templates/project.txt", "template")
        let candidate = try await fixture.candidate(at: "skills/demo")

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(),
            archiveIsReleaseAsset: false
        )

        guard case let .ready(package) = resolution else {
            Issue.record("Expected an automatic nested package")
            return
        }
        #expect(package.recipe.origin == .skillDirectory)
        #expect(package.recipe.skillPath == "skills/demo")
        #expect(package.recipe.includePaths.isEmpty)
    }

    @Test("A Release asset is authoritative but still represented by a bound recipe")
    func releaseAssetIsBoundPackage() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("scripts/run.sh", "echo ok")
        let candidate = try await fixture.candidate()
        var version = fixture.version()
        version.releaseID = 42
        version.releaseAssets = [.init(
            id: 100,
            name: "demo-pure.zip",
            size: 100,
            browserDownloadURL: URL(string: "https://example.test/demo-pure.zip")!
        )]
        version.selectedReleaseAssetID = 100

        let resolution = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: version,
            archiveIsReleaseAsset: true
        )

        guard case let .ready(package) = resolution else {
            Issue.record("Expected a Release package")
            return
        }
        #expect(package.recipe.origin == .releaseAsset)
        #expect(package.recipe.repositoryID == 7)
        #expect(package.recipe.repositoryFullName == "example/demo")
    }

    @Test("A saved recipe ignores new repository metadata but pauses for possible runtime content")
    func recipeOnlyPausesForPossibleRuntimeContent() async throws {
        let fixture = try PackageFixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", "---\nname: demo\ndescription: Demo\n---\n")
        try fixture.write("scripts/run.sh", "echo ok")
        let candidate = try await fixture.candidate()
        let recipe = fixture.recipe(includePaths: ["SKILL.md", "scripts"], reviewed: ["SKILL.md", "scripts"])

        try fixture.write(".github/workflows/ci.yml", "name: CI")
        let metadataOnly = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(identifier: "commit:2"),
            archiveIsReleaseAsset: false,
            existingRecipe: recipe
        )
        guard case .ready = metadataOnly else {
            Issue.record("Repository metadata must not interrupt updates")
            return
        }

        try fixture.write("templates/project.txt", "template")
        let possibleRuntime = try await GitHubSkillPackageResolver().resolve(
            candidate: candidate,
            version: fixture.version(identifier: "commit:3"),
            archiveIsReleaseAsset: false,
            existingRecipe: recipe
        )
        guard case let .needsConfirmation(review) = possibleRuntime else {
            Issue.record("New possible runtime content must be reviewed")
            return
        }
        #expect(review.newUnreviewedPaths == ["templates"])
    }
}

private struct PackageFixture {
    let root: URL
    let skillPath: String?

    init(skillPath: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxPackageTests-\(UUID().uuidString)")
        self.skillPath = skillPath
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ text: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func candidate(at relativePath: String? = nil) async throws -> SkillCandidate {
        let directory = relativePath.map { root.appendingPathComponent($0) } ?? root
        let result = await FileSystemSkillScanner().scan(roots: [directory], sourceName: { _ in "GitHub" })
        var candidate = try #require(result.candidates.first)
        candidate.source = .init(
            kind: .github,
            displayName: "example/demo",
            locator: "https://github.com/example/demo",
            repository: "example/demo",
            revision: "main",
            skillPath: relativePath ?? skillPath
        )
        return candidate
    }

    func version(identifier: String = "commit:1") -> GitHubRemoteVersion {
        .init(
            repositoryID: 7,
            repositoryFullName: "example/demo",
            isPrivate: false,
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            versionIdentifier: identifier,
            versionName: "main",
            revision: "main",
            commitSHA: String(identifier.dropFirst("commit:".count)),
            treeSHA: "root-tree",
            archiveURL: URL(string: "https://example.test/source.zip")!
        )
    }

    func recipe(includePaths: [String], reviewed: [String]) -> GitHubPackageRecipe {
        .init(
            origin: .userSelection,
            repositoryID: 7,
            repositoryFullName: "example/demo",
            trackingMode: .defaultBranch,
            skillPath: nil,
            includePaths: includePaths,
            reviewedTopLevelPaths: reviewed,
            confirmedVersionIdentifier: "commit:1"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
