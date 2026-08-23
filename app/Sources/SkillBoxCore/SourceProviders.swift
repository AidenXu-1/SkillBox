import CryptoKit
import Darwin
import Foundation

public enum BoundedProcessError: Error, Sendable {
    case timedOut
    case outputLimitExceeded
    case failed(Int32, String)
}

public struct BoundedProcessRunner: Sendable {
    public var timeout: TimeInterval
    public var maximumOutputBytes: Int

    public init(timeout: TimeInterval = 30, maximumOutputBytes: Int = 2 * 1_024 * 1_024) {
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    public func run(_ executable: String, arguments: [String]) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxProcess-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL)
        else { throw BoundedProcessError.failed(-1, "无法创建临时输出文件") }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline { throw BoundedProcessError.timedOut }
                if outputSize(at: outputURL) > maximumOutputBytes {
                    throw BoundedProcessError.outputLimitExceeded
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            terminate(process)
            throw error
        }

        try output.synchronize()
        let data = (try? Data(contentsOf: outputURL, options: .mappedIfSafe)) ?? Data()
        guard data.count <= maximumOutputBytes else { throw BoundedProcessError.outputLimitExceeded }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw BoundedProcessError.failed(process.terminationStatus, String(text.prefix(500)))
        }
        return text
    }

    private func outputSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

public protocol SourceProvider: Sendable {
    func preview(locator: String) async throws -> [SkillCandidate]
}

public protocol GitHubAccessTokenProvider: Sendable {
    func accessToken() async throws -> String?
}

public protocol GitHubRemoteVersionChecking: Sendable {
    func checkRemoteVersion(
        repositoryFullName: String,
        skillPath: String?,
        trackingMode: GitHubTrackingMode
    ) async throws -> GitHubRemoteVersion

    func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch
}

public struct GitHubRemoteCheckBatch: Sendable {
    public var versions: [UUID: GitHubRemoteVersion]
    public var eTag: String?
    public var isNotModified: Bool

    public init(
        versions: [UUID: GitHubRemoteVersion],
        eTag: String? = nil,
        isNotModified: Bool = false
    ) {
        self.versions = versions
        self.eTag = eTag
        self.isNotModified = isNotModified
    }
}

public extension GitHubRemoteVersionChecking {
    func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch {
        var versions: [UUID: GitHubRemoteVersion] = [:]
        for state in states {
            versions[state.skillID] = try await checkRemoteVersion(
                repositoryFullName: state.repositoryFullName,
                skillPath: state.skillPath,
                trackingMode: state.trackingMode
            )
        }
        return GitHubRemoteCheckBatch(versions: versions)
    }
}

public struct AnonymousGitHubAccessTokenProvider: GitHubAccessTokenProvider, Sendable {
    public init() {}
    public func accessToken() async throws -> String? { nil }
}

public struct LocalFolderSourceProvider: SourceProvider, Sendable {
    private let scanner: any SkillScanner

    public init(scanner: any SkillScanner = FileSystemSkillScanner()) {
        self.scanner = scanner
    }

    public func preview(locator: String) async throws -> [SkillCandidate] {
        let url = URL(fileURLWithPath: locator).standardizedFileURL
        let result = await scanner.scan(roots: [url], sourceName: { _ in "本地文件夹" })
        return result.candidates.map { candidate in
            var updated = candidate
            updated.source = .init(kind: .localFolder, displayName: "本地文件夹", locator: candidate.sourceURL.path)
            return updated
        }
    }
}

public struct GitHubDownloadLimits: Sendable {
    public var maximumDownloadBytes: Int
    public var maximumExpandedBytes: Int
    public var maximumFileCount: Int

    public init(
        maximumDownloadBytes: Int = 10 * 1024 * 1024,
        maximumExpandedBytes: Int = 25 * 1024 * 1024,
        maximumFileCount: Int = 1_000
    ) {
        self.maximumDownloadBytes = maximumDownloadBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumFileCount = maximumFileCount
    }
}

public enum GitHubSourceError: LocalizedError {
    case invalidURL
    case unsupportedHost
    case requestFailed(Int)
    case downloadTooLarge
    case incompleteTree
    case archiveTooLarge
    case tooManyFiles
    case unsafeArchivePath(String)
    case extractionFailed(String)
    case noSkillsFound
    case noStableRelease
    case authenticationRequired
    case repositoryUnavailableOrUnauthorized
    case repositoryPermissionRequired
    case rateLimited(retryAt: Date, scope: GitHubRateLimitScope)
    case skillPathMissing(String)
    case releaseAssetSelectionRequired([GitHubReleaseAsset])
    case checksumMismatch(String)
    case releaseAssetUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "这个 GitHub 地址无法识别，请检查后重试"
        case .unsupportedHost: "目前只支持 github.com 仓库"
        case .requestFailed: "暂时无法从 GitHub 获取内容，请稍后重试"
        case .downloadTooLarge: "GitHub 下载的文件太大，目前最多约 10 MB"
        case .incompleteTree: "GitHub 返回的目录不完整，SkillBox 已停止本次检查，请稍后重试"
        case .archiveTooLarge: "这个仓库展开后太大，目前最多约 25 MB"
        case .tooManyFiles: "这个仓库文件太多，目前最多 1000 个"
        case .unsafeArchivePath: "这个仓库包含不安全的文件位置，已停止添加"
        case .extractionFailed: "下载的内容无法安全打开"
        case .noSkillsFound: "这个仓库里没有找到可以添加的 Skill"
        case .noStableRelease: "这个仓库还没有正式 Release，可以改为跟随默认分支"
        case .authenticationRequired: "这个仓库需要 GitHub 授权才能查看"
        case .repositoryUnavailableOrUnauthorized: "找不到这个仓库，或者 SkillBox 还没有访问权限"
        case .repositoryPermissionRequired: "SkillBox 还没有获准读取这个私人仓库"
        case let .rateLimited(retryAt, _): "GitHub 暂时限制了查询，请在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后重试"
        case .skillPathMissing: "GitHub 上找不到原来的 Skill 目录"
        case .releaseAssetSelectionRequired: "这个 Release 有多个可用安装包，请选择要导入的 ZIP"
        case let .checksumMismatch(name): "\(name) 的 SHA-256 校验未通过，已停止导入"
        case .releaseAssetUnavailable: "选择的 Release 安装包已不可用，请重新检查"
        }
    }
}

public struct GitHubSourceProvider: SourceProvider, GitHubRemoteVersionChecking, Sendable {
    private static let maximumAPIResponseBytes = 2 * 1_024 * 1_024
    private let session: URLSession
    private let limits: GitHubDownloadLimits
    private let scanner: any SkillScanner
    private let tokenProvider: any GitHubAccessTokenProvider
    private let authorizationPreference: GitHubAuthorizationPreference

    public init(
        session: URLSession = .shared,
        limits: GitHubDownloadLimits = GitHubDownloadLimits(),
        scanner: any SkillScanner = FileSystemSkillScanner(),
        tokenProvider: any GitHubAccessTokenProvider = AnonymousGitHubAccessTokenProvider()
    ) {
        self.session = session
        self.limits = limits
        self.scanner = scanner
        self.tokenProvider = tokenProvider
        authorizationPreference = GitHubAuthorizationPreference()
    }

    public func checkRemoteVersion(
        repositoryFullName: String,
        skillPath: String?,
        trackingMode: GitHubTrackingMode
    ) async throws -> GitHubRemoteVersion {
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryFullName: repositoryFullName,
            skillPath: skillPath,
            trackingMode: trackingMode
        )
        let batch = try await checkRemoteVersions(states: [state])
        guard !batch.isNotModified, let version = batch.versions[state.skillID] else {
            throw GitHubSourceError.requestFailed(304)
        }
        return version
    }

    public func checkRemoteVersions(states: [GitHubSourceState]) async throws -> GitHubRemoteCheckBatch {
        guard let first = states.first else { return GitHubRemoteCheckBatch(versions: [:]) }
        let repositoryName = first.repositoryFullName.lowercased()
        guard states.allSatisfy({
            $0.repositoryFullName.lowercased() == repositoryName && $0.trackingMode == first.trackingMode
        }) else {
            throw GitHubSourceError.invalidURL
        }

        let repository = try RepositoryName(first.repositoryFullName)
        let repositoryContext = try await repositoryInfo(repository: repository, states: states)
        let info = repositoryContext.info
        let conditionalETag = sharedETag(in: states)
        // A connected account raises GitHub's limit for public metadata too.
        // The request layer still retries anonymously when a public repository
        // is outside the GitHub App selection or the saved login is no longer valid.
        let useAuthorization = repositoryContext.useAuthorization

        switch first.trackingMode {
        case .latestStableRelease:
            let response: GitHubAPIResponse<ReleaseResponse>
            do {
                response = try await requestAPIResponse(
                    path: "/repos/\(repository.owner)/\(repository.name)/releases/latest",
                    ifNoneMatch: conditionalETag,
                    useAuthorization: useAuthorization
                )
            } catch GitHubSourceError.requestFailed(404) {
                if info.isPrivate {
                    guard await preferredAccessToken() != nil else {
                        throw GitHubSourceError.authenticationRequired
                    }
                    _ = try await fetchRepositoryInfo(repository: repository, knownPrivate: true)
                }
                throw GitHubSourceError.noStableRelease
            }
            switch response {
            case let .notModified(eTag, _):
                return GitHubRemoteCheckBatch(versions: [:], eTag: eTag ?? conditionalETag, isNotModified: true)
            case let .modified(release, eTag, usedAuthorization):
                return try await releaseBatch(
                    release: release,
                    eTag: eTag,
                    repository: repository,
                    info: info,
                    states: states,
                    useAuthorization: usedAuthorization
                )
            }
        case .defaultBranch:
            let response: GitHubAPIResponse<CommitResponse> = try await requestAPIResponse(
                path: "/repos/\(repository.owner)/\(repository.name)/commits/\(info.defaultBranch.urlPathSegment)",
                ifNoneMatch: conditionalETag,
                useAuthorization: useAuthorization
            )
            switch response {
            case let .notModified(eTag, _):
                return GitHubRemoteCheckBatch(versions: [:], eTag: eTag ?? conditionalETag, isNotModified: true)
            case let .modified(commit, eTag, usedAuthorization):
                var trees: [UUID: PackageTreeResolution] = [:]
                var statesNeedingTree: [GitHubSourceState] = []
                for state in states {
                    if state.currentCommitSHA == commit.sha, let currentTreeSHA = state.currentTreeSHA {
                        trees[state.skillID] = .init(treeSHA: currentTreeSHA)
                    } else {
                        statesNeedingTree.append(state)
                    }
                }
                if !statesNeedingTree.isEmpty {
                    let changedTrees = try await treeSHAs(
                        repository: repository,
                        rootTreeSHA: commit.commit.tree.sha,
                        states: statesNeedingTree,
                        useAuthorization: usedAuthorization
                    )
                    trees.merge(changedTrees) { _, refreshed in refreshed }
                }
                let versions = Dictionary(uniqueKeysWithValues: states.map { state in
                    let version = GitHubRemoteVersion(
                        repositoryID: info.id,
                        repositoryFullName: info.fullName,
                        isPrivate: info.isPrivate,
                        trackingMode: .defaultBranch,
                        defaultBranch: info.defaultBranch,
                        versionIdentifier: "commit:\(commit.sha)",
                        versionName: info.defaultBranch,
                        revision: info.defaultBranch,
                        commitSHA: commit.sha,
                        treeSHA: trees[state.skillID]?.treeSHA ?? commit.commit.tree.sha,
                        archiveURL: URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/zipball/\(commit.sha.urlPathSegment)")!,
                        packageReviewPaths: trees[state.skillID]?.reviewPaths ?? []
                    )
                    return (state.skillID, version)
                })
                return GitHubRemoteCheckBatch(versions: versions, eTag: eTag)
            }
        }
    }

    public func preview(locator: String) async throws -> [SkillCandidate] {
        let reference = try GitHubReference.parse(locator)
        let revision = try await reference.revision(
            using: session,
            maximumResponseBytes: Self.maximumAPIResponseBytes
        )
        let archiveURL = URL(string: "https://codeload.github.com/\(reference.owner)/\(reference.repository)/zip/\(revision)")!
        let data = try await downloadData(request: URLRequest(url: archiveURL))

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHub-\(UUID().uuidString)")
        let archive = temporary.appendingPathComponent("source.zip")
        let extracted = temporary.appendingPathComponent("extracted")
        var retainTemporaryDirectory = false
        defer {
            if !retainTemporaryDirectory { try? FileManager.default.removeItem(at: temporary) }
        }
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)

        let entries = try await listArchive(archive)
        guard entries.count <= limits.maximumFileCount else { throw GitHubSourceError.tooManyFiles }
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || components.contains("..") { throw GitHubSourceError.unsafeArchivePath(entry) }
        }
        let metadata = try await run("/usr/bin/unzip", arguments: ["-Z", "-l", archive.path])
        if metadata.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("l") }) {
            throw GitHubSourceError.unsafeArchivePath("压缩包包含软链接")
        }
        let expandedBytes = try await archiveExpandedSize(archive)
        guard expandedBytes <= limits.maximumExpandedBytes else { throw GitHubSourceError.archiveTooLarge }
        try await run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
        try validateExpandedTree(extracted)

        let repositoryRoot = try archiveContentRoot(in: extracted)
        let selectedRoot = reference.skillPath.map { repositoryRoot.appendingPathComponent($0) } ?? repositoryRoot
        let result = await scanner.scan(roots: [selectedRoot], sourceName: { _ in "GitHub" })
        guard !result.candidates.isEmpty else { throw GitHubSourceError.noSkillsFound }
        let candidates = result.candidates.map { candidate in
            var updated = candidate
            let relative = String(candidate.sourceURL.standardizedFileURL.path.dropFirst(repositoryRoot.standardizedFileURL.path.count + 1))
            updated.source = .init(
                kind: .github,
                displayName: "\(reference.owner)/\(reference.repository)",
                locator: locator,
                repository: "\(reference.owner)/\(reference.repository)",
                revision: revision,
                skillPath: relative
            )
            return updated
        }
        retainTemporaryDirectory = true
        return candidates
    }

    public func preview(locator: String, trackingMode: GitHubTrackingMode) async throws -> GitHubSnapshot {
        let reference = try GitHubReference.parse(locator)
        let version = try await checkRemoteVersion(locator: locator, trackingMode: trackingMode)
        return try await downloadSnapshot(version: version, skillPath: reference.skillPath, locator: locator)
    }

    public func checkRemoteVersion(
        locator: String,
        trackingMode: GitHubTrackingMode
    ) async throws -> GitHubRemoteVersion {
        let reference = try GitHubReference.parse(locator)
        let repositoryFullName = "\(reference.owner)/\(reference.repository)"
        return try await checkRemoteVersion(
            repositoryFullName: repositoryFullName,
            skillPath: reference.skillPath,
            trackingMode: trackingMode
        )
    }

    public func skillPath(in locator: String) throws -> String? {
        try GitHubReference.parse(locator).skillPath
    }

    public func authorizedRepositories() async throws -> [GitHubRepositorySummary] {
        let accessToken: String?
        do {
            accessToken = try await tokenProvider.accessToken()
        } catch {
            throw GitHubSourceError.authenticationRequired
        }
        guard accessToken != nil else {
            throw GitHubSourceError.authenticationRequired
        }
        let installations: InstallationsResponse = try await requestAPI(path: "/user/installations")
        var repositories: [Int64: GitHubRepositorySummary] = [:]
        for installation in installations.installations {
            var page = 1
            while true {
                let response: InstallationRepositoriesResponse = try await requestAPI(
                    path: "/user/installations/\(installation.id)/repositories?per_page=100&page=\(page)"
                )
                for repository in response.repositories {
                    repositories[repository.id] = .init(
                        id: repository.id,
                        fullName: repository.fullName,
                        isPrivate: repository.isPrivate
                    )
                }
                guard response.repositories.count == 100 else { break }
                page += 1
            }
        }
        return repositories.values.sorted {
            $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
    }

    public func downloadSnapshot(
        version: GitHubRemoteVersion,
        skillPath: String?,
        locator: String,
        packageRecipe: GitHubPackageRecipe? = nil
    ) async throws -> GitHubSnapshot {
        if version.requiresReleaseAssetSelection {
            throw GitHubSourceError.releaseAssetSelectionRequired(version.releaseAssets)
        }
        let request = try await downloadRequest(url: version.archiveURL, useAuthorization: version.isPrivate)
        let data = try await downloadData(request: request)
        let verifiedDigest = try await verifyReleaseAsset(
            data,
            asset: version.selectedReleaseAsset,
            useAuthorization: version.isPrivate
        )
        var resolvedVersion = version
        if let verifiedDigest,
           let selectedAssetID = version.selectedReleaseAssetID,
           let index = resolvedVersion.releaseAssets.firstIndex(where: { $0.id == selectedAssetID })
        {
            resolvedVersion.releaseAssets[index].digest = "sha256:\(verifiedDigest)"
            resolvedVersion = try resolvedVersion.selectingReleaseAsset(id: selectedAssetID)
        }
        let rawCandidates = try await extractCandidates(
            data: data,
            repositoryFullName: resolvedVersion.repositoryFullName,
            locator: locator,
            revision: resolvedVersion.commitSHA,
            selectedSkillPath: skillPath,
            archiveIsReleaseAsset: resolvedVersion.selectedReleaseAsset != nil
        )
        let packageResolver = GitHubSkillPackageResolver()
        var candidates: [SkillCandidate] = []
        var recipes: [String: GitHubPackageRecipe] = [:]
        var reviews: [GitHubPackageReview] = []
        for candidate in rawCandidates {
            let resolution = try await packageResolver.resolve(
                candidate: candidate,
                version: resolvedVersion,
                archiveIsReleaseAsset: resolvedVersion.selectedReleaseAsset != nil,
                existingRecipe: packageRecipe
            )
            switch resolution {
            case let .ready(package):
                candidates.append(package.candidate)
                recipes[package.candidate.id] = package.recipe
            case let .needsConfirmation(review):
                reviews.append(review)
            }
        }
        return GitHubSnapshot(
            version: resolvedVersion,
            candidates: candidates,
            packageRecipes: recipes,
            packageReviews: reviews
        )
    }

    public func confirmPackageReview(
        _ review: GitHubPackageReview,
        includePaths: [String]
    ) async throws -> GitHubResolvedPackage {
        let resolution = try await GitHubSkillPackageResolver().confirm(
            review: review,
            includePaths: includePaths
        )
        guard case let .ready(package) = resolution else {
            throw GitHubPackageError.packageCouldNotBeBuilt
        }
        return package
    }

    private func downloadRequest(url: URL, useAuthorization: Bool) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if useAuthorization, let token = await preferredAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func verifyReleaseAsset(
        _ data: Data,
        asset: GitHubReleaseAsset?,
        useAuthorization: Bool
    ) async throws -> String? {
        guard let asset else { return nil }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let digest = asset.digest,
           digest.lowercased().hasPrefix("sha256:"),
           String(digest.dropFirst("sha256:".count)).lowercased() != actual
        {
            throw GitHubSourceError.checksumMismatch(asset.name)
        }
        guard let checksumURL = asset.checksumDownloadURL else { return actual }
        let checksumData = try await downloadData(
            request: downloadRequest(url: checksumURL, useAuthorization: useAuthorization)
        )
        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expected = firstSHA256(in: checksumText),
              expected == actual
        else {
            throw GitHubSourceError.checksumMismatch(asset.name)
        }
        return actual
    }

    private func firstSHA256(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{64}\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return text[range].lowercased()
    }

    private func repositoryInfo(
        repository: RepositoryName,
        states: [GitHubSourceState]
    ) async throws -> RepositoryCheckContext {
        if let known = states.first(where: {
            $0.repositoryID != nil && $0.repositoryIsPrivate != nil && $0.defaultBranch?.isEmpty == false
        }), let repositoryID = known.repositoryID,
           let isPrivate = known.repositoryIsPrivate,
           let defaultBranch = known.defaultBranch
        {
            return RepositoryCheckContext(
                info: RepositoryResponse(
                    id: repositoryID,
                    fullName: known.repositoryFullName,
                    defaultBranch: defaultBranch,
                    isPrivate: isPrivate
                ),
                useAuthorization: true
            )
        }

        return try await fetchRepositoryInfo(repository: repository, knownPrivate: nil)
    }

    private func fetchRepositoryInfo(
        repository: RepositoryName,
        knownPrivate: Bool?
    ) async throws -> RepositoryCheckContext {
        do {
            let response: GitHubAPIResponse<RepositoryResponse> = try await requestAPIResponse(
                path: "/repos/\(repository.owner)/\(repository.name)",
                ifNoneMatch: nil
            )
            switch response {
            case let .modified(info, _, usedAuthorization):
                return RepositoryCheckContext(
                    info: info,
                    useAuthorization: info.isPrivate || usedAuthorization
                )
            case .notModified:
                throw GitHubSourceError.requestFailed(304)
            }
        } catch GitHubSourceError.requestFailed(404) {
            if knownPrivate == true {
                if await preferredAccessToken() != nil {
                    throw GitHubSourceError.repositoryPermissionRequired
                }
                throw GitHubSourceError.authenticationRequired
            }
            if await preferredAccessToken() != nil {
                throw GitHubSourceError.repositoryPermissionRequired
            }
            throw GitHubSourceError.repositoryUnavailableOrUnauthorized
        }
    }

    private func releaseBatch(
        release: ReleaseResponse,
        eTag: String?,
        repository: RepositoryName,
        info: RepositoryResponse,
        states: [GitHubSourceState],
        useAuthorization: Bool
    ) async throws -> GitHubRemoteCheckBatch {
        let zipAssets = installableZIPs(in: release)
        if !zipAssets.isEmpty {
            let versions = try Dictionary(uniqueKeysWithValues: states.map { state in
                var version = GitHubRemoteVersion(
                    repositoryID: info.id,
                    repositoryFullName: info.fullName,
                    isPrivate: info.isPrivate,
                    trackingMode: .latestStableRelease,
                    defaultBranch: info.defaultBranch,
                    versionIdentifier: "release:\(release.id)",
                    versionName: release.tagName,
                    revision: release.tagName,
                    commitSHA: release.tagName,
                    treeSHA: "release:\(release.id)",
                    publishedAt: release.publishedAt,
                    archiveURL: zipAssets.count == 1 ? zipAssets[0].browserDownloadURL : release.zipballURL,
                    releaseID: release.id,
                    releaseAssets: zipAssets
                )
                if let assetID = preferredReleaseAssetID(for: state, assets: zipAssets) {
                    version = try version.selectingReleaseAsset(id: assetID)
                }
                return (state.skillID, version)
            })
            return GitHubRemoteCheckBatch(versions: versions, eTag: eTag)
        }

        let commit: CommitResponse = try await requestAPI(
            path: "/repos/\(repository.owner)/\(repository.name)/commits/\(release.tagName.urlPathSegment)",
            useAuthorization: useAuthorization
        )
        let trees = try await treeSHAs(
            repository: repository,
            rootTreeSHA: commit.commit.tree.sha,
            states: states,
            useAuthorization: useAuthorization
        )
        let versions = Dictionary(uniqueKeysWithValues: states.map { state in
            let version = GitHubRemoteVersion(
                repositoryID: info.id,
                repositoryFullName: info.fullName,
                isPrivate: info.isPrivate,
                trackingMode: .latestStableRelease,
                defaultBranch: info.defaultBranch,
                versionIdentifier: "release:\(release.id):source:\(commit.sha)",
                versionName: release.tagName,
                revision: release.tagName,
                commitSHA: commit.sha,
                treeSHA: trees[state.skillID]?.treeSHA ?? commit.commit.tree.sha,
                publishedAt: release.publishedAt,
                archiveURL: release.zipballURL,
                releaseID: release.id,
                usesSourceArchiveFallback: true,
                packageReviewPaths: trees[state.skillID]?.reviewPaths ?? []
            )
            return (state.skillID, version)
        })
        return GitHubRemoteCheckBatch(versions: versions, eTag: eTag)
    }

    private func installableZIPs(in release: ReleaseResponse) -> [GitHubReleaseAsset] {
        release.assets.filter(\.isInstallableZIP).map { asset in
            var enriched = asset
            if let checksum = release.assets.first(where: {
                $0.state == "uploaded" && $0.name.caseInsensitiveCompare(asset.name + ".sha256") == .orderedSame
            }) {
                enriched.checksumAssetID = checksum.id
                enriched.checksumDownloadURL = checksum.browserDownloadURL
            }
            return enriched
        }
    }

    private func preferredReleaseAssetID(
        for state: GitHubSourceState,
        assets: [GitHubReleaseAsset]
    ) -> Int64? {
        if assets.count == 1 { return assets[0].id }
        if let currentID = state.currentAssetID, assets.contains(where: { $0.id == currentID }) {
            return currentID
        }
        let preferredName = state.currentAssetName ?? state.availableAssetName
        if let preferredName,
           let matching = assets.first(where: { $0.name.caseInsensitiveCompare(preferredName) == .orderedSame })
        {
            return matching.id
        }
        return nil
    }

    private func sharedETag(in states: [GitHubSourceState]) -> String? {
        guard states.allSatisfy({ $0.versionETag != nil }) else { return nil }
        let values = Set(states.compactMap(\.versionETag))
        return values.count == 1 ? values.first : nil
    }

    private func downloadData(request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let retryAt = rateLimitRetryDate(from: http) {
                let scope: GitHubRateLimitScope = request.value(forHTTPHeaderField: "Authorization") == nil
                    ? .anonymous
                    : .authenticated
                throw GitHubSourceError.rateLimited(retryAt: retryAt, scope: scope)
            }
            if request.value(forHTTPHeaderField: "Authorization") != nil,
               http.statusCode == 401 || http.statusCode == 403
            {
                await rejectAuthorization(in: request)
                var anonymousRequest = request
                anonymousRequest.setValue(nil, forHTTPHeaderField: "Authorization")
                return try await downloadData(request: anonymousRequest)
            }
            if http.statusCode == 401 || http.statusCode == 403 { throw GitHubSourceError.authenticationRequired }
            throw GitHubSourceError.requestFailed(http.statusCode)
        }
        if response.expectedContentLength > Int64(limits.maximumDownloadBytes) {
            throw GitHubSourceError.downloadTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limits.maximumDownloadBytes))
        for try await byte in bytes {
            guard data.count < limits.maximumDownloadBytes else { throw GitHubSourceError.downloadTooLarge }
            data.append(byte)
        }
        return data
    }

    private func extractCandidates(
        data: Data,
        repositoryFullName: String,
        locator: String,
        revision: String,
        selectedSkillPath: String?,
        archiveIsReleaseAsset: Bool = false
    ) async throws -> [SkillCandidate] {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHub-\(UUID().uuidString)")
        let archive = temporary.appendingPathComponent("source.zip")
        let extracted = temporary.appendingPathComponent("extracted")
        var retainTemporaryDirectory = false
        defer { if !retainTemporaryDirectory { try? FileManager.default.removeItem(at: temporary) } }
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)
        try Task.checkCancellation()
        let entries = try await listArchive(archive)
        guard entries.count <= limits.maximumFileCount else { throw GitHubSourceError.tooManyFiles }
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || components.contains("..") { throw GitHubSourceError.unsafeArchivePath(entry) }
        }
        let metadata = try await run("/usr/bin/unzip", arguments: ["-Z", "-l", archive.path])
        if metadata.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("l") }) {
            throw GitHubSourceError.unsafeArchivePath("压缩包包含软链接")
        }
        guard try await archiveExpandedSize(archive) <= limits.maximumExpandedBytes else { throw GitHubSourceError.archiveTooLarge }
        try await run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
        try Task.checkCancellation()
        try validateExpandedTree(extracted)
        let repositoryRoot = try archiveContentRoot(in: extracted)
        let selectedRoot = archiveIsReleaseAsset
            ? repositoryRoot
            : selectedSkillPath.map { repositoryRoot.appendingPathComponent($0) } ?? repositoryRoot
        let result = await scanner.scan(roots: [selectedRoot], sourceName: { _ in "GitHub" })
        try Task.checkCancellation()
        guard !result.candidates.isEmpty else { throw GitHubSourceError.noSkillsFound }
        let candidates = result.candidates.map { candidate in
            var updated = candidate
            let relative = String(candidate.sourceURL.standardizedFileURL.path.dropFirst(repositoryRoot.standardizedFileURL.path.count + 1))
            let sourceSkillPath = archiveIsReleaseAsset && selectedSkillPath?.isEmpty == false
                ? selectedSkillPath
                : relative
            updated.source = .init(
                kind: .github,
                displayName: repositoryFullName,
                locator: locator,
                repository: repositoryFullName,
                revision: revision,
                skillPath: sourceSkillPath
            )
            return updated
        }
        retainTemporaryDirectory = true
        return candidates
    }

    private func listArchive(_ archive: URL) async throws -> [String] {
        let output = try await run("/usr/bin/unzip", arguments: ["-Z1", archive.path])
        return output.split(separator: "\n").map(String.init)
    }

    private func treeSHAs(
        repository: RepositoryName,
        rootTreeSHA: String,
        states: [GitHubSourceState],
        useAuthorization: Bool
    ) async throws -> [UUID: PackageTreeResolution] {
        var responses: [String: TreeResponse] = [:]
        var result: [UUID: PackageTreeResolution] = [:]
        for state in states {
            if let recipe = state.packageRecipe,
               recipe.skillPath?.isEmpty ?? true,
               !recipe.includePaths.isEmpty
            {
                let rootTree = try await treeResponse(
                    sha: rootTreeSHA,
                    repository: repository,
                    useAuthorization: useAuthorization,
                    cache: &responses
                )
                let topLevelPaths = Set(rootTree.tree.map(\.path))
                let newPaths = topLevelPaths.filter {
                    !recipe.reviewedTopLevelPaths.contains($0) &&
                        !GitHubSkillPackageResolver.isRepositoryOnlyPath($0)
                }.sorted()
                var identities: [String] = []
                var missing: [String] = []
                for path in recipe.includePaths {
                    if let entry = try await treeEntry(
                        at: path,
                        rootTreeSHA: rootTreeSHA,
                        repository: repository,
                        useAuthorization: useAuthorization,
                        cache: &responses
                    ) {
                        identities.append("\(path)\u{0}\(entry.type)\u{0}\(entry.sha)")
                    } else {
                        missing.append(path)
                    }
                }
                let reviewPaths = Array(Set(newPaths + missing)).sorted()
                if missing.isEmpty {
                    let bytes = identities.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    result[state.skillID] = .init(treeSHA: "package:\(digest)", reviewPaths: reviewPaths)
                } else {
                    result[state.skillID] = .init(
                        treeSHA: state.currentTreeSHA ?? "package-review:\(rootTreeSHA)",
                        reviewPaths: reviewPaths
                    )
                }
                continue
            }
            guard let skillPath = state.skillPath, !skillPath.isEmpty else {
                result[state.skillID] = .init(treeSHA: rootTreeSHA)
                continue
            }
            var currentSHA = rootTreeSHA
            for component in skillPath.split(separator: "/").map(String.init) {
                let tree: TreeResponse
                if let cached = responses[currentSHA] {
                    tree = cached
                } else {
                    tree = try await treeResponse(
                        sha: currentSHA,
                        repository: repository,
                        useAuthorization: useAuthorization,
                        cache: &responses
                    )
                }
                guard let entry = tree.tree.first(where: { $0.path == component && $0.type == "tree" }) else {
                    throw GitHubSourceError.skillPathMissing(skillPath)
                }
                currentSHA = entry.sha
            }
            result[state.skillID] = .init(treeSHA: currentSHA)
        }
        return result
    }

    private func treeResponse(
        sha: String,
        repository: RepositoryName,
        useAuthorization: Bool,
        cache: inout [String: TreeResponse]
    ) async throws -> TreeResponse {
        if let cached = cache[sha] { return cached }
        let tree: TreeResponse = try await requestAPI(
            path: "/repos/\(repository.owner)/\(repository.name)/git/trees/\(sha.urlPathSegment)",
            useAuthorization: useAuthorization
        )
        guard tree.truncated != true else { throw GitHubSourceError.incompleteTree }
        cache[sha] = tree
        return tree
    }

    private func treeEntry(
        at relativePath: String,
        rootTreeSHA: String,
        repository: RepositoryName,
        useAuthorization: Bool,
        cache: inout [String: TreeResponse]
    ) async throws -> TreeResponse.Entry? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var treeSHA = rootTreeSHA
        for (index, component) in components.enumerated() {
            let tree = try await treeResponse(
                sha: treeSHA,
                repository: repository,
                useAuthorization: useAuthorization,
                cache: &cache
            )
            guard let entry = tree.tree.first(where: { $0.path == component }) else { return nil }
            if index == components.count - 1 { return entry }
            guard entry.type == "tree" else { return nil }
            treeSHA = entry.sha
        }
        return nil
    }

    private func requestAPI<Response: Decodable>(
        path: String,
        useAuthorization: Bool = true
    ) async throws -> Response {
        let result: GitHubAPIResponse<Response> = try await requestAPIResponse(
            path: path,
            ifNoneMatch: nil,
            useAuthorization: useAuthorization
        )
        switch result {
        case let .modified(value, _, _): return value
        case .notModified: throw GitHubSourceError.requestFailed(304)
        }
    }

    private func requestAPIResponse<Response: Decodable>(
        path: String,
        ifNoneMatch: String?,
        useAuthorization: Bool = true
    ) async throws -> GitHubAPIResponse<Response> {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw GitHubSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        if useAuthorization, let token = await preferredAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var usedAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        var (data, response) = try await boundedAPIData(for: request)
        if let http = response as? HTTPURLResponse,
           request.value(forHTTPHeaderField: "Authorization") != nil,
           rateLimitRetryDate(from: http) == nil,
           http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404
        {
            if http.statusCode != 404 {
                await rejectAuthorization(in: request)
            }
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            usedAuthorization = false
            (data, response) = try await boundedAPIData(for: request)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 304 {
            return .notModified(
                eTag: http.value(forHTTPHeaderField: "ETag") ?? ifNoneMatch,
                usedAuthorization: usedAuthorization
            )
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let retryAt = rateLimitRetryDate(from: http) {
                let scope: GitHubRateLimitScope = usedAuthorization ? .authenticated : .anonymous
                throw GitHubSourceError.rateLimited(retryAt: retryAt, scope: scope)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GitHubSourceError.authenticationRequired
            }
            throw GitHubSourceError.requestFailed(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Response.self, from: data)
        let eTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        return .modified(value, eTag: eTag, usedAuthorization: usedAuthorization)
    }

    private func boundedAPIData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await BoundedNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: Self.maximumAPIResponseBytes
            )
        } catch is BoundedNetworkResponseError {
            throw GitHubSourceError.downloadTooLarge
        }
    }

    private func preferredAccessToken() async -> String? {
        do {
            guard let token = try await tokenProvider.accessToken(),
                  await authorizationPreference.shouldUse(token)
            else { return nil }
            return token
        } catch {
            return nil
        }
    }

    private func rejectAuthorization(in request: URLRequest) async {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ")
        else { return }
        await authorizationPreference.reject(String(authorization.dropFirst("Bearer ".count)))
    }

    private func rateLimitRetryDate(from response: HTTPURLResponse) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return Date().addingTimeInterval(max(retryAfter, 60))
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        {
            return Date(timeIntervalSince1970: reset)
        }
        if response.statusCode == 429 {
            return Date().addingTimeInterval(60)
        }
        return nil
    }

    private func archiveExpandedSize(_ archive: URL) async throws -> Int {
        let output = try await run("/usr/bin/unzip", arguments: ["-l", archive.path])
        var total = 0
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 4, let size = Int(columns[0]), size >= 0 else { continue }
            guard size <= limits.maximumExpandedBytes - total else {
                throw GitHubSourceError.archiveTooLarge
            }
            total += size
        }
        return total
    }

    private func validateExpandedTree(_ root: URL) throws {
        var count = 0
        var bytes = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        for case let url as URL in enumerator {
            count += 1
            if count > limits.maximumFileCount { throw GitHubSourceError.tooManyFiles }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            if bytes > limits.maximumExpandedBytes { throw GitHubSourceError.archiveTooLarge }
        }
        try SafeFileOperations.validateTree(root: root)
    }

    private func firstDirectory(in root: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        guard let directory = try children.first(where: { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }) else {
            throw GitHubSourceError.noSkillsFound
        }
        return directory
    }

    private func archiveContentRoot(in extracted: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: extracted.appendingPathComponent("SKILL.md").path) {
            return extracted
        }
        return try firstDirectory(in: extracted)
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String]) async throws -> String {
        do {
            return try await BoundedProcessRunner().run(executable, arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch BoundedProcessError.timedOut {
            throw GitHubSourceError.extractionFailed("处理压缩包超时")
        } catch BoundedProcessError.outputLimitExceeded {
            throw GitHubSourceError.extractionFailed("压缩包目录信息过多")
        } catch let BoundedProcessError.failed(_, message) {
            throw GitHubSourceError.extractionFailed(message)
        }
    }
}

private actor GitHubAuthorizationPreference {
    private var rejectedToken: String?

    func shouldUse(_ token: String) -> Bool {
        token != rejectedToken
    }

    func reject(_ token: String) {
        rejectedToken = token
    }
}

private struct RepositoryName: Sendable {
    let owner: String
    let name: String

    init(_ fullName: String) throws {
        let components = fullName.split(separator: "/").map(String.init)
        guard components.count == 2, components.allSatisfy({ !$0.isEmpty }) else { throw GitHubSourceError.invalidURL }
        owner = components[0]
        name = components[1]
    }
}

private enum GitHubAPIResponse<Value> {
    case modified(Value, eTag: String?, usedAuthorization: Bool)
    case notModified(eTag: String?, usedAuthorization: Bool)
}

private struct RepositoryCheckContext {
    let info: RepositoryResponse
    let useAuthorization: Bool
}

private struct PackageTreeResolution {
    var treeSHA: String
    var reviewPaths: [String]

    init(treeSHA: String, reviewPaths: [String] = []) {
        self.treeSHA = treeSHA
        self.reviewPaths = reviewPaths
    }
}

private struct RepositoryResponse: Decodable {
    var id: Int64
    var fullName: String
    var defaultBranch: String
    var isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case isPrivate = "private"
    }
}

private struct InstallationsResponse: Decodable {
    struct Installation: Decodable { var id: Int64 }
    var installations: [Installation]
}

private struct InstallationRepositoriesResponse: Decodable {
    struct Repository: Decodable {
        var id: Int64
        var fullName: String
        var isPrivate: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case fullName = "full_name"
            case isPrivate = "private"
        }
    }
    var repositories: [Repository]
}

private struct ReleaseResponse: Decodable {
    var id: Int64
    var tagName: String
    var name: String?
    var publishedAt: Date?
    var zipballURL: URL
    var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case zipballURL = "zipball_url"
        case assets
    }
}

private struct CommitResponse: Decodable {
    struct Commit: Decodable {
        struct Tree: Decodable { var sha: String }
        var tree: Tree
    }
    var sha: String
    var commit: Commit
}

private struct TreeResponse: Decodable {
    struct Entry: Decodable {
        var path: String
        var type: String
        var sha: String
    }
    var tree: [Entry]
    var truncated: Bool?
}

private extension String {
    var urlPathSegment: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

private struct GitHubReference: Sendable {
    var owner: String
    var repository: String
    var explicitRevision: String?
    var skillPath: String?

    static func parse(_ locator: String) throws -> GitHubReference {
        let normalized = locator.hasPrefix("http") ? locator : "https://github.com/\(locator)"
        guard let url = URL(string: normalized), url.host?.lowercased() == "github.com" else { throw GitHubSourceError.unsupportedHost }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw GitHubSourceError.invalidURL }
        let repository = parts[1].replacingOccurrences(of: ".git", with: "")
        if parts.count >= 5, parts[2] == "tree" {
            return .init(owner: parts[0], repository: repository, explicitRevision: parts[3], skillPath: parts.dropFirst(4).joined(separator: "/"))
        }
        return .init(owner: parts[0], repository: repository)
    }

    func revision(using session: URLSession, maximumResponseBytes: Int) async throws -> String {
        if let explicitRevision { return explicitRevision }
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: maximumResponseBytes
            )
        } catch is BoundedNetworkResponseError {
            throw GitHubSourceError.downloadTooLarge
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw GitHubSourceError.requestFailed(http.statusCode) }
        struct Repository: Decodable { var default_branch: String }
        return try JSONDecoder().decode(Repository.self, from: data).default_branch
    }
}
