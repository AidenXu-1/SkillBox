import CryptoKit
import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub source provider", .serialized)
struct SourceProviderTests {
    @Test("GitHub rate limits are not mistaken for private repository authorization")
    func rateLimitIsNotAuthenticationFailure() async throws {
        let provider = GitHubSourceProvider(session: RateLimitFixture.session())

        do {
            _ = try await provider.checkRemoteVersion(
                repositoryFullName: "example/skills",
                skillPath: nil,
                trackingMode: .latestStableRelease
            )
            Issue.record("Expected GitHub rate limiting")
        } catch GitHubSourceError.rateLimited(let retryAt, let scope) {
            #expect(retryAt == Date(timeIntervalSince1970: 1_786_809_641))
            #expect(scope == .anonymous)
        } catch {
            Issue.record("Expected rate limiting, got \(error)")
        }
    }

    @Test("A connected public-repository check records the authenticated quota")
    func authenticatedRateLimitIsDistinguishedFromAnonymousQuota() async throws {
        let provider = GitHubSourceProvider(
            session: RateLimitFixture.session(),
            tokenProvider: FixedTokenProvider()
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "release:41",
            status: .current
        )

        do {
            _ = try await provider.checkRemoteVersions(states: [state])
            Issue.record("Expected GitHub rate limiting")
        } catch GitHubSourceError.rateLimited(_, let scope) {
            #expect(scope == .authenticated)
        } catch {
            Issue.record("Expected authenticated rate limiting, got \(error)")
        }
    }

    @Test("An expired private-repository login never blocks public repository updates")
    func invalidTokenFallsBackToAnonymousForPublicRepository() async throws {
        let provider = GitHubSourceProvider(
            session: InvalidTokenPublicRepositoryFixture.session(),
            tokenProvider: FixedTokenProvider()
        )

        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: nil,
            trackingMode: .latestStableRelease
        )

        #expect(version.repositoryFullName == "example/skills")
        #expect(version.isPrivate == false)
        #expect(InvalidTokenPublicRepositoryMockURLProtocol.authenticatedRequestCount == 1)
    }

    @Test("A public repository outside the GitHub App selection still works anonymously")
    func unselectedPublicRepositoryFallsBackToAnonymous() async throws {
        let provider = GitHubSourceProvider(
            session: UnselectedPublicRepositoryFixture.session(),
            tokenProvider: FixedTokenProvider()
        )

        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: nil,
            trackingMode: .latestStableRelease
        )

        #expect(version.repositoryFullName == "example/skills")
        #expect(version.isPrivate == false)
        #expect(UnselectedPublicRepositoryMockURLProtocol.authenticatedRequestCount == 1)
    }

    @Test("A known public Release fallback stays anonymous after repository access is rejected")
    func knownPublicReleaseFallbackDoesNotRetryRejectedAuthorization() async throws {
        let provider = GitHubSourceProvider(
            session: UnselectedPublicRepositoryFixture.session(),
            tokenProvider: FixedTokenProvider()
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "release:41",
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])

        #expect(batch.versions[state.skillID]?.commitSHA == "commit-release")
        #expect(UnselectedPublicRepositoryMockURLProtocol.authenticatedRequestCount == 1)
    }

    @Test("A known public default-branch check keeps tree lookups anonymous after access is rejected")
    func knownPublicBranchTreeDoesNotRetryRejectedAuthorization() async throws {
        let provider = GitHubSourceProvider(
            session: UnselectedPublicRepositoryFixture.session(),
            tokenProvider: FixedTokenProvider()
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "demo",
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentCommitSHA: "commit-old",
            currentTreeSHA: "demo-old",
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])

        #expect(batch.versions[state.skillID]?.treeSHA == "demo-tree")
        #expect(UnselectedPublicRepositoryMockURLProtocol.authenticatedRequestCount == 1)
    }

    @Test("A newly issued login token becomes usable without restarting the app")
    func refreshedTokenRestoresPrivateRepositoryAccessImmediately() async throws {
        let tokenProvider = RotatingTokenProvider(token: "expired-token")
        let provider = GitHubSourceProvider(
            session: ReconnectedTokenFixture.session(),
            tokenProvider: tokenProvider
        )

        _ = try await provider.checkRemoteVersion(
            repositoryFullName: "example/public-skill",
            skillPath: nil,
            trackingMode: .latestStableRelease
        )
        await tokenProvider.setToken("new-token")

        let privateVersion = try await provider.checkRemoteVersion(
            repositoryFullName: "example/private-skill",
            skillPath: nil,
            trackingMode: .latestStableRelease
        )

        #expect(privateVersion.isPrivate)
        #expect(ReconnectedTokenMockURLProtocol.receivedNewToken)
    }

    @Test("An expired login on a known private repository asks to reconnect")
    func expiredPrivateRepositoryTokenIsNotMistakenForMissingRelease() async throws {
        let provider = GitHubSourceProvider(
            session: ReconnectedTokenFixture.session(),
            tokenProvider: RotatingTokenProvider(token: "expired-token")
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 8,
            repositoryFullName: "example/private-skill",
            repositoryIsPrivate: true,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "release:41",
            status: .current
        )

        do {
            _ = try await provider.checkRemoteVersions(states: [state])
            Issue.record("Expected an authentication-required result")
        } catch GitHubSourceError.authenticationRequired {
            // Expected: the local Skill remains intact and the UI can offer reconnection.
        } catch {
            Issue.record("Expected authenticationRequired, got \(error)")
        }
    }

    @Test("A Release with one ZIP selects the uploaded install package without downloading it")
    func releaseMetadataCheck() async throws {
        let session = RemoteVersionFixture.session()
        let provider = GitHubSourceProvider(session: session)
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .latestStableRelease
        )

        #expect(version.versionIdentifier == "release:42:asset:101:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(version.versionName == "v1.4.0")
        #expect(version.revision == "v1.4.0")
        #expect(version.commitSHA == "v1.4.0")
        #expect(version.treeSHA == "release:42")
        #expect(version.archiveURL.absoluteString == "https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip")
        #expect(RemoteVersionMockURLProtocol.archiveRequestCount == 0)
        #expect(RemoteVersionMockURLProtocol.requestPaths == [
            "/repos/example/skills",
            "/repos/example/skills/releases/latest"
        ])
    }

    @Test("Oversized GitHub metadata is rejected before decoding")
    func oversizedGitHubMetadataIsRejected() async throws {
        let session = RemoteVersionFixture.session()
        RemoteVersionMockURLProtocol.repositoryPaddingBytes = 2_200_000
        defer { RemoteVersionMockURLProtocol.repositoryPaddingBytes = 0 }
        let provider = GitHubSourceProvider(session: session)

        do {
            _ = try await provider.checkRemoteVersion(
                repositoryFullName: "example/skills",
                skillPath: nil,
                trackingMode: .latestStableRelease
            )
            Issue.record("Expected oversized GitHub metadata to be rejected")
        } catch GitHubSourceError.downloadTooLarge {
            // Expected: the response is stopped at the shared byte boundary.
        } catch {
            Issue.record("Expected downloadTooLarge, got \(error)")
        }
    }

    @Test("A truncated GitHub tree cannot be treated as complete")
    func truncatedTreeIsRejected() async throws {
        let session = RemoteVersionFixture.session()
        RemoteVersionMockURLProtocol.treeTruncated = true
        defer { RemoteVersionMockURLProtocol.treeTruncated = false }
        let provider = GitHubSourceProvider(session: session)
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/demo",
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentCommitSHA: "commit-old",
            currentTreeSHA: "demo-old",
            status: .current
        )

        await #expect(throws: GitHubSourceError.self) {
            try await provider.checkRemoteVersions(states: [state])
        }
    }

    @Test("Skills from one Release repository share one metadata request")
    func releaseChecksAreGroupedByRepository() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let first = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/demo",
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "demo-old",
            status: .current
        )
        let second = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/other",
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "other-old",
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [first, second])

        #expect(batch.versions.count == 2)
        #expect(batch.eTag == #""release-v1""#)
        #expect(RemoteVersionMockURLProtocol.requestPaths == ["/repos/example/skills/releases/latest"])
    }

    @Test("A connected GitHub account raises the limit for known public repositories")
    func knownPublicRepositoryUsesConnectedAccount() async throws {
        let provider = GitHubSourceProvider(
            session: RemoteVersionFixture.session(),
            tokenProvider: FixedTokenProvider()
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "release:41",
            status: .current
        )

        _ = try await provider.checkRemoteVersions(states: [state])

        #expect(RemoteVersionMockURLProtocol.authorizationHeaders == ["Bearer test-token"])
    }

    @Test("An unchanged conditional Release response stops all follow-up requests")
    func unchangedReleaseUsesETag() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            currentTreeSHA: "tree",
            versionETag: #""release-v1""#,
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])

        #expect(batch.isNotModified)
        #expect(batch.versions.isEmpty)
        #expect(RemoteVersionMockURLProtocol.lastIfNoneMatch == #""release-v1""#)
        #expect(RemoteVersionMockURLProtocol.requestPaths == ["/repos/example/skills/releases/latest"])
    }

    @Test("Default-branch Skills share the branch and tree lookup")
    func defaultBranchChecksShareRepositoryTree() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let first = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/demo",
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentTreeSHA: "demo-old",
            status: .current
        )
        let second = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/other",
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentTreeSHA: "other-old",
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [first, second])

        #expect(batch.versions[first.skillID]?.treeSHA == "demo-tree")
        #expect(batch.versions[second.skillID]?.treeSHA == "other-tree")
        #expect(RemoteVersionMockURLProtocol.requestPaths == [
            "/repos/example/skills/commits/main",
            "/repos/example/skills/git/trees/root-tree-new",
            "/repos/example/skills/git/trees/skills-tree",
        ])
    }

    @Test("An unchanged default-branch commit skips all tree requests")
    func unchangedDefaultBranchCommitSkipsTrees() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            skillPath: "skills/demo",
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentVersionIdentifier: "commit:commit-main",
            currentCommitSHA: "commit-main",
            currentTreeSHA: "demo-tree",
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])
        let version = try #require(batch.versions[state.skillID])

        #expect(version.treeSHA == "demo-tree")
        #expect(RemoteVersionMockURLProtocol.requestPaths == ["/repos/example/skills/commits/main"])
    }

    @Test("Default-branch checks use the Skill subtree instead of unrelated repository changes")
    func defaultBranchMetadataCheck() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .defaultBranch
        )
        #expect(version.versionIdentifier == "commit:commit-main")
        #expect(version.treeSHA == "demo-tree")
        #expect(version.archiveURL.absoluteString.hasSuffix("/zipball/commit-main"))
    }

    @Test("Root repository checks compare only the confirmed installable paths")
    func rootRecipeUsesSelectedTreeIdentity() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let recipe = GitHubPackageRecipe(
            origin: .userSelection,
            repositoryID: 7,
            repositoryFullName: "example/skills",
            trackingMode: .defaultBranch,
            includePaths: ["SKILL.md", "scripts"],
            reviewedTopLevelPaths: ["README.md", "SKILL.md", "scripts", "skills"],
            confirmedVersionIdentifier: "commit:old"
        )
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentVersionIdentifier: "commit:old",
            currentCommitSHA: "commit-old",
            currentTreeSHA: "package:old",
            packageRecipe: recipe,
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])
        let version = try #require(batch.versions[state.skillID])
        let identityInput = [
            "SKILL.md\u{0}blob\u{0}skill-blob",
            "scripts\u{0}tree\u{0}scripts-tree",
        ].sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identityInput.utf8)).map { String(format: "%02x", $0) }.joined()

        #expect(version.treeSHA == "package:\(digest)")
        #expect(version.packageReviewPaths.isEmpty)
    }

    @Test("A new possible runtime path requests review while repository metadata stays quiet")
    func rootRecipeDetectsOnlyPossibleRuntimePaths() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session())
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryID: 7,
            repositoryFullName: "example/skills",
            repositoryIsPrivate: false,
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            currentCommitSHA: "commit-old",
            currentTreeSHA: "package:old",
            packageRecipe: .init(
                origin: .userSelection,
                repositoryID: 7,
                repositoryFullName: "example/skills",
                trackingMode: .defaultBranch,
                includePaths: ["SKILL.md", "scripts"],
                reviewedTopLevelPaths: ["README.md", "SKILL.md", "scripts"],
                confirmedVersionIdentifier: "commit:old"
            ),
            status: .current
        )

        let batch = try await provider.checkRemoteVersions(states: [state])
        let version = try #require(batch.versions[state.skillID])

        #expect(version.packageReviewPaths == ["skills"])
        #expect(!version.packageReviewPaths.contains("README.md"))
    }

    @Test("Confirmed updates download a complete immutable snapshot")
    func completeSnapshotDownload() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session())
        let version = GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/skills",
            isPrivate: false,
            trackingMode: .defaultBranch,
            defaultBranch: "main",
            versionIdentifier: "commit:abc123",
            versionName: "main",
            revision: "main",
            commitSHA: "abc123",
            treeSHA: "demo-tree",
            archiveURL: URL(string: "https://codeload.github.com/example/skills/zip/abc123")!
        )

        let snapshot = try await provider.downloadSnapshot(
            version: version,
            skillPath: "skills/demo",
            locator: "https://github.com/example/skills/tree/main/skills/demo"
        )
        let candidate = try #require(snapshot.candidates.first)
        #expect(snapshot.version.commitSHA == "abc123")
        #expect(FileManager.default.fileExists(atPath: candidate.sourceURL.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: candidate.sourceURL.appendingPathComponent("README.md").path))
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("A pure Release package imports only its five runtime files")
    func pureReleasePackageDownload() async throws {
        let fixture = try PureReleaseArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session())
        let version = fixture.releaseVersionWithChecksum()

        let snapshot = try await provider.downloadSnapshot(
            version: version,
            skillPath: "skills/agent-team",
            locator: "https://github.com/example/agent-team/tree/main/skills/agent-team"
        )
        let candidate = try #require(snapshot.candidates.first)
        let files = try FileManager.default.subpathsOfDirectory(atPath: candidate.sourceURL.path)
            .filter { relativePath in
                try candidate.sourceURL.appendingPathComponent(relativePath)
                    .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            }
            .sorted()
        #expect(files == [
            "SKILL.md",
            "agents/openai.yaml",
            "references/temporary-executor.md",
            "scripts/scaffold_team.py",
            "scripts/temporary_executor_runtime.py",
        ])
        #expect(!files.contains(".github/workflows/ci.yml"))
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("A Release with multiple ZIP packages requires the user to choose")
    func multipleReleasePackagesRequireSelection() async throws {
        let session = RemoteVersionFixture.session(releaseAssets: [
            #"{"id":101,"name":"demo-macos.zip","state":"uploaded","content_type":"application/zip","size":2048,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-macos.zip"}"#,
            #"{"id":102,"name":"demo-pure.zip","state":"uploaded","content_type":"application/zip","size":1024,"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip"}"#,
            #"{"id":103,"name":"demo-pure.zip.sha256","state":"uploaded","content_type":"text/plain","size":80,"digest":null,"browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip.sha256"}"#,
        ])
        let provider = GitHubSourceProvider(session: session)
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .latestStableRelease
        )

        #expect(version.releaseAssets.map(\.name) == ["demo-macos.zip", "demo-pure.zip"])
        #expect(version.releaseAssets.last?.checksumAssetID == 103)
        #expect(version.requiresReleaseAssetSelection)
        do {
            _ = try await provider.downloadSnapshot(
                version: version,
                skillPath: "skills/demo",
                locator: "https://github.com/example/skills/tree/main/skills/demo"
            )
            Issue.record("Expected Release asset selection to be required")
        } catch GitHubSourceError.releaseAssetSelectionRequired(let assets) {
            #expect(assets.map(\.name) == ["demo-macos.zip", "demo-pure.zip"])
        }

        let chosen = try version.selectingReleaseAsset(id: 102)
        #expect(chosen.selectedReleaseAssetID == 102)
        #expect(chosen.archiveURL.absoluteString.hasSuffix("/demo-pure.zip"))
        #expect(chosen.versionIdentifier == "release:42:asset:102:sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }

    @Test("A Release without a ZIP safely falls back to source with a clear warning")
    func releaseWithoutPackageFallsBackToSource() async throws {
        let provider = GitHubSourceProvider(session: RemoteVersionFixture.session(releaseAssets: [
            #"{"id":103,"name":"demo-pure.zip.sha256","state":"uploaded","content_type":"text/plain","size":80,"digest":null,"browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip.sha256"}"#,
        ]))
        let version = try await provider.checkRemoteVersion(
            repositoryFullName: "example/skills",
            skillPath: "skills/demo",
            trackingMode: .latestStableRelease
        )

        #expect(version.releaseAssets.isEmpty)
        #expect(version.usesSourceArchiveFallback)
        #expect(version.archiveURL.absoluteString.hasSuffix("/zipball/v1.4.0"))
        #expect(version.sourceArchiveFallbackNotice == "该 Release 没有独立安装包，本次将导入完整源码，可能包含测试、CI 和开发文件。")
    }

    @Test("A matching SHA-256 sidecar allows the Release package to import")
    func matchingReleaseChecksumImports() async throws {
        let fixture = try PureReleaseArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session(checksum: fixture.correctChecksum))
        let snapshot = try await provider.downloadSnapshot(
            version: fixture.releaseVersionWithChecksum(),
            skillPath: nil,
            locator: "https://github.com/example/agent-team"
        )

        let candidate = try #require(snapshot.candidates.first)
        #expect(candidate.canonicalName == "agent-team")
        #expect(snapshot.version.selectedReleaseAsset?.digest == "sha256:\(fixture.correctChecksum)")
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("A mismatched SHA-256 sidecar blocks the Release package")
    func mismatchedReleaseChecksumBlocksImport() async throws {
        let fixture = try PureReleaseArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session(checksum: String(repeating: "0", count: 64)))

        do {
            _ = try await provider.downloadSnapshot(
                version: fixture.releaseVersionWithChecksum(),
                skillPath: nil,
                locator: "https://github.com/example/agent-team"
            )
            Issue.record("Expected a checksum mismatch")
        } catch GitHubSourceError.checksumMismatch(let name) {
            #expect(name == "agent-team-2.0-pure.zip")
        }
    }

    @Test("GitHub settings show repositories actually authorized to the app")
    func authorizedRepositories() async throws {
        let provider = GitHubSourceProvider(
            session: AuthorizedRepositoryFixture.session(),
            tokenProvider: FixedTokenProvider()
        )

        let repositories = try await provider.authorizedRepositories()

        #expect(repositories.map(\.fullName) == ["example/private-skill", "example/public-skill"])
        #expect(repositories.first?.isPrivate == true)
        #expect(AuthorizedRepositoryMockURLProtocol.receivedAuthorization == "Bearer test-token")
    }

    @Test("Public repository archives are previewed without executing content")
    func githubPreview() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let session = fixture.session()
        let provider = GitHubSourceProvider(session: session)
        let candidates = try await provider.preview(locator: "https://github.com/example/skills/tree/main/skills/demo")
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        #expect(candidate.canonicalName == "demo")
        #expect(candidate.source.kind == .github)
        #expect(candidate.source.repository == "example/skills")
        #expect(candidate.source.revision == "main")
        #expect(candidate.riskReport.findings.contains { $0.category == .network && $0.severity == .info })
        removeRetainedGitHubTemporaryDirectory(for: candidate.sourceURL)
    }

    @Test("Archive file-count limits stop imports")
    func fileLimit() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(
            session: fixture.session(),
            limits: .init(maximumDownloadBytes: 10 * 1024 * 1024, maximumExpandedBytes: 25 * 1024 * 1024, maximumFileCount: 1)
        )
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }

    @Test("Expanded-size limits stop imports before extraction")
    func expandedSizeLimit() async throws {
        let fixture = try GitHubArchiveFixture()
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(
            session: fixture.session(),
            limits: .init(maximumDownloadBytes: 10 * 1024 * 1024, maximumExpandedBytes: 1, maximumFileCount: 1_000)
        )
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }

    @Test("Archive symlinks are rejected before extraction")
    func symlinkArchive() async throws {
        let fixture = try GitHubArchiveFixture(includeSymlink: true)
        defer { fixture.remove() }
        let provider = GitHubSourceProvider(session: fixture.session())
        await #expect(throws: GitHubSourceError.self) {
            try await provider.preview(locator: "example/skills")
        }
    }

    @Test("Archive subprocess output is bounded instead of filling a pipe indefinitely")
    func archiveSubprocessOutputIsBounded() async throws {
        let runner = BoundedProcessRunner(timeout: 2, maximumOutputBytes: 4_096)

        do {
            _ = try await runner.run("/usr/bin/yes", arguments: ["archive-entry"])
            Issue.record("无限输出的子进程不应成功")
        } catch BoundedProcessError.outputLimitExceeded {
            // Expected: the process is terminated as soon as the cap is crossed.
        } catch {
            Issue.record("预期输出上限错误，实际为 \(error)")
        }
    }

    @Test("Archive subprocesses are terminated when they exceed the time budget")
    func archiveSubprocessHasTimeout() async throws {
        let runner = BoundedProcessRunner(timeout: 0.1, maximumOutputBytes: 4_096)

        do {
            _ = try await runner.run("/bin/sleep", arguments: ["5"])
            Issue.record("超时的子进程不应成功")
        } catch BoundedProcessError.timedOut {
            // Expected.
        } catch {
            Issue.record("预期超时错误，实际为 \(error)")
        }
    }
}

private final class RateLimitMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/json",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1786809641",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum RateLimitFixture {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class InvalidTokenPublicRepositoryMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var authenticatedRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isAuthenticated = request.value(forHTTPHeaderField: "Authorization") != nil
        if isAuthenticated {
            Self.authenticatedRequestCount += 1
            respond(status: 401, payload: #"{"message":"Bad credentials"}"#)
            return
        }

        let payload: String
        switch request.url?.path {
        case "/repos/example/skills":
            payload = #"{"id":7,"full_name":"example/skills","default_branch":"main","private":false}"#
        case "/repos/example/skills/releases/latest":
            payload = #"{"id":42,"tag_name":"v1.4.0","name":"Version 1.4","published_at":"2026-08-15T00:00:00Z","zipball_url":"https://api.github.com/repos/example/skills/zipball/v1.4.0","assets":[]}"#
        case "/repos/example/skills/commits/v1.4.0":
            payload = #"{"sha":"commit-release","commit":{"tree":{"sha":"root-tree"}}}"#
        default:
            payload = #"{}"#
        }
        respond(status: 200, payload: payload)
    }

    private func respond(status: Int, payload: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum InvalidTokenPublicRepositoryFixture {
    static func session() -> URLSession {
        InvalidTokenPublicRepositoryMockURLProtocol.authenticatedRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvalidTokenPublicRepositoryMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class UnselectedPublicRepositoryMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var authenticatedRequestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.value(forHTTPHeaderField: "Authorization") != nil {
            Self.authenticatedRequestCount += 1
            respond(status: 404, payload: #"{"message":"Not Found"}"#)
            return
        }

        let payload: String
        switch request.url?.path {
        case "/repos/example/skills":
            payload = #"{"id":7,"full_name":"example/skills","default_branch":"main","private":false}"#
        case "/repos/example/skills/releases/latest":
            payload = #"{"id":42,"tag_name":"v1.4.0","name":"Version 1.4","published_at":"2026-08-15T00:00:00Z","zipball_url":"https://api.github.com/repos/example/skills/zipball/v1.4.0","assets":[]}"#
        case "/repos/example/skills/commits/v1.4.0":
            payload = #"{"sha":"commit-release","commit":{"tree":{"sha":"root-tree"}}}"#
        case "/repos/example/skills/commits/main":
            payload = #"{"sha":"commit-main","commit":{"tree":{"sha":"root-tree"}}}"#
        case "/repos/example/skills/git/trees/root-tree":
            payload = #"{"sha":"root-tree","tree":[{"path":"demo","type":"tree","sha":"demo-tree"}]}"#
        default:
            payload = "{}"
        }
        respond(status: 200, payload: payload)
    }

    private func respond(status: Int, payload: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum UnselectedPublicRepositoryFixture {
    static func session() -> URLSession {
        UnselectedPublicRepositoryMockURLProtocol.authenticatedRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnselectedPublicRepositoryMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct FixedTokenProvider: GitHubAccessTokenProvider {
    func accessToken() async throws -> String? { "test-token" }
}

private actor RotatingTokenProvider: GitHubAccessTokenProvider {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func accessToken() async throws -> String? { token }

    func setToken(_ token: String?) {
        self.token = token
    }
}

private final class ReconnectedTokenMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receivedNewToken = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        if authorization == "Bearer expired-token" {
            respond(status: 401, payload: #"{"message":"Bad credentials"}"#)
            return
        }
        if authorization == "Bearer new-token" {
            Self.receivedNewToken = true
        }

        let path = request.url?.path ?? ""
        let requiresNewToken = path.contains("/private-skill")
        if requiresNewToken, authorization != "Bearer new-token" {
            respond(status: 404, payload: #"{"message":"Not Found"}"#)
            return
        }

        let payload: String
        switch path {
        case "/repos/example/public-skill":
            payload = #"{"id":7,"full_name":"example/public-skill","default_branch":"main","private":false}"#
        case "/repos/example/private-skill":
            payload = #"{"id":8,"full_name":"example/private-skill","default_branch":"main","private":true}"#
        case "/repos/example/public-skill/releases/latest", "/repos/example/private-skill/releases/latest":
            payload = #"{"id":42,"tag_name":"v1.0.0","name":"Version 1","published_at":"2026-08-15T00:00:00Z","zipball_url":"https://api.github.com/repos/example/skill/zipball/v1.0.0","assets":[]}"#
        case "/repos/example/public-skill/commits/v1.0.0", "/repos/example/private-skill/commits/v1.0.0":
            payload = #"{"sha":"commit-release","commit":{"tree":{"sha":"root-tree"}}}"#
        default:
            payload = #"{}"#
        }
        respond(status: 200, payload: payload)
    }

    private func respond(status: Int, payload: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum ReconnectedTokenFixture {
    static func session() -> URLSession {
        ReconnectedTokenMockURLProtocol.receivedNewToken = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReconnectedTokenMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class AuthorizedRepositoryMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receivedAuthorization: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.receivedAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let payload: String
        switch request.url?.path {
        case "/user/installations":
            payload = #"{"installations":[{"id":91}]}"#
        case "/user/installations/91/repositories":
            payload = #"{"repositories":[{"id":2,"full_name":"example/public-skill","private":false},{"id":1,"full_name":"example/private-skill","private":true}]}"#
        default:
            payload = #"{}"#
        }
        let data = Data(payload.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum AuthorizedRepositoryFixture {
    static func session() -> URLSession {
        AuthorizedRepositoryMockURLProtocol.receivedAuthorization = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorizedRepositoryMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func removeRetainedGitHubTemporaryDirectory(for sourceURL: URL) {
    let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
    var temporary = sourceURL.resolvingSymlinksInPath().standardizedFileURL
    while temporary.path.hasPrefix(temporaryRoot), temporary.path != temporaryRoot {
        if temporary.lastPathComponent.hasPrefix("SkillBoxGitHub-") {
            try? FileManager.default.removeItem(at: temporary)
            break
        }
        temporary.deleteLastPathComponent()
    }
}

private final class RemoteVersionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var archiveRequestCount = 0
    nonisolated(unsafe) static var requestPaths: [String] = []
    nonisolated(unsafe) static var lastIfNoneMatch: String?
    nonisolated(unsafe) static var authorizationHeaders: [String?] = []
    nonisolated(unsafe) static var repositoryPaddingBytes = 0
    nonisolated(unsafe) static var treeTruncated = false
    nonisolated(unsafe) static var releaseAssets = [
        #"{"id":101,"name":"demo-pure.zip","state":"uploaded","content_type":"application/zip","size":2048,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip"}"#,
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestPaths.append(path)
        Self.lastIfNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
        Self.authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        if path == "/repos/example/skills/releases/latest",
           Self.lastIfNoneMatch == #""release-v1""#
        {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": #""release-v1""#]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let payload: String
        switch path {
        case "/repos/example/skills":
            payload = #"{"id":7,"full_name":"example/skills","default_branch":"main","private":false}"#
                + String(repeating: " ", count: Self.repositoryPaddingBytes)
        case "/repos/example/skills/releases/latest":
            payload = #"{"id":42,"tag_name":"v1.4.0","name":"Version 1.4","published_at":"2026-08-15T00:00:00Z","zipball_url":"https://api.github.com/repos/example/skills/zipball/v1.4.0","assets":["# + Self.releaseAssets.joined(separator: ",") + "]}"
        case "/repos/example/skills/commits/v1.4.0":
            payload = #"{"sha":"commit-release","commit":{"tree":{"sha":"root-tree"}}}"#
        case "/repos/example/skills/commits/main":
            payload = #"{"sha":"commit-main","commit":{"tree":{"sha":"root-tree-new"}}}"#
        case "/repos/example/skills/git/trees/root-tree", "/repos/example/skills/git/trees/root-tree-new":
            payload = #"{"tree":[{"path":"README.md","type":"blob","sha":"readme-new"},{"path":"SKILL.md","type":"blob","sha":"skill-blob"},{"path":"scripts","type":"tree","sha":"scripts-tree"},{"path":"skills","type":"tree","sha":"skills-tree"}],"truncated":"#
                + (Self.treeTruncated ? "true" : "false") + "}"
        case "/repos/example/skills/git/trees/skills-tree":
            payload = #"{"tree":[{"path":"demo","type":"tree","sha":"demo-tree"},{"path":"other","type":"tree","sha":"other-tree"}]}"#
        default:
            Self.archiveRequestCount += 1
            payload = "{}"
        }
        let data = Data(payload.utf8)
        let eTag = path == "/repos/example/skills/releases/latest" ? #""release-v1""# : #""branch-v1""#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "ETag": eTag])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum RemoteVersionFixture {
    static func session(releaseAssets: [String]? = nil) -> URLSession {
        RemoteVersionMockURLProtocol.archiveRequestCount = 0
        RemoteVersionMockURLProtocol.requestPaths = []
        RemoteVersionMockURLProtocol.lastIfNoneMatch = nil
        RemoteVersionMockURLProtocol.authorizationHeaders = []
        RemoteVersionMockURLProtocol.repositoryPaddingBytes = 0
        RemoteVersionMockURLProtocol.treeTruncated = false
        if let releaseAssets { RemoteVersionMockURLProtocol.releaseAssets = releaseAssets }
        else {
            RemoteVersionMockURLProtocol.releaseAssets = [
                #"{"id":101,"name":"demo-pure.zip","state":"uploaded","content_type":"application/zip","size":2048,"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/example/skills/releases/download/v1.4.0/demo-pure.zip"}"#,
            ]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteVersionMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockGitHubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var archiveData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isAPI = request.url?.host == "api.github.com"
        let data = isAPI ? Data(#"{"default_branch":"main"}"#.utf8) : Self.archiveData
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isAPI ? "application/json" : "application/zip"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct GitHubArchiveFixture {
    let root: URL
    let archive: URL

    init(includeSymlink: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHubTests-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("skills-main/skills/demo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: Demo\n---\n\nRun curl https://example.com manually.\n".write(to: repo.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "reference".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if includeSymlink {
            try FileManager.default.createSymbolicLink(
                at: repo.appendingPathComponent("outside-link"),
                withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
            )
        }
        archive = root.appendingPathComponent("source.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("skills-main").path, archive.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        MockGitHubURLProtocol.archiveData = try Data(contentsOf: archive)
    }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class PureReleaseArchiveMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var archiveData = Data()
    nonisolated(unsafe) static var checksumData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isChecksum = request.url?.path.hasSuffix(".sha256") == true
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": isChecksum ? "text/plain" : "application/zip"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isChecksum ? Self.checksumData : Self.archiveData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PureReleaseArchiveFixture {
    let root: URL
    let archive: URL
    var correctChecksum: String {
        SHA256.hash(data: PureReleaseArchiveMockURLProtocol.archiveData).map { String(format: "%02x", $0) }.joined()
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxPureReleaseTests-\(UUID().uuidString)")
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("references"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "---\nname: agent-team\ndescription: Coordinate agents\n---\n".write(to: package.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "interface: {}\n".write(to: package.appendingPathComponent("agents/openai.yaml"), atomically: true, encoding: .utf8)
        try "temporary executor\n".write(to: package.appendingPathComponent("references/temporary-executor.md"), atomically: true, encoding: .utf8)
        try "print('scaffold')\n".write(to: package.appendingPathComponent("scripts/scaffold_team.py"), atomically: true, encoding: .utf8)
        try "print('runtime')\n".write(to: package.appendingPathComponent("scripts/temporary_executor_runtime.py"), atomically: true, encoding: .utf8)
        archive = root.appendingPathComponent("agent-team-2.0-pure.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", archive.path, "."]
        process.currentDirectoryURL = package
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        PureReleaseArchiveMockURLProtocol.archiveData = try Data(contentsOf: archive)
    }

    func session(checksum: String? = nil) -> URLSession {
        PureReleaseArchiveMockURLProtocol.checksumData = Data("\(checksum ?? correctChecksum)  agent-team-2.0-pure.zip\n".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PureReleaseArchiveMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func releaseVersionWithChecksum() -> GitHubRemoteVersion {
        let asset = GitHubReleaseAsset(
            id: 101,
            name: "agent-team-2.0-pure.zip",
            size: PureReleaseArchiveMockURLProtocol.archiveData.count,
            digest: nil,
            browserDownloadURL: URL(string: "https://github.com/example/agent-team/releases/download/v2.0.0/agent-team-2.0-pure.zip")!,
            checksumAssetID: 102,
            checksumDownloadURL: URL(string: "https://github.com/example/agent-team/releases/download/v2.0.0/agent-team-2.0-pure.zip.sha256")!
        )
        return GitHubRemoteVersion(
            repositoryID: 7,
            repositoryFullName: "example/agent-team",
            isPrivate: false,
            trackingMode: .latestStableRelease,
            defaultBranch: "main",
            versionIdentifier: "release:42",
            versionName: "v2.0.0",
            revision: "v2.0.0",
            commitSHA: "release-commit",
            treeSHA: "release-tree",
            archiveURL: asset.browserDownloadURL,
            releaseID: 42,
            releaseAssets: [asset],
            selectedReleaseAssetID: asset.id
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
