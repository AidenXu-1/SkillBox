import CryptoKit
import Foundation

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
    case archiveTooLarge
    case tooManyFiles
    case unsafeArchivePath(String)
    case extractionFailed(String)
    case noSkillsFound
    case noStableRelease
    case authenticationRequired
    case repositoryUnavailableOrUnauthorized
    case repositoryPermissionRequired
    case rateLimited(retryAt: Date)
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
        case .archiveTooLarge: "这个仓库展开后太大，目前最多约 25 MB"
        case .tooManyFiles: "这个仓库文件太多，目前最多 1000 个"
        case .unsafeArchivePath: "这个仓库包含不安全的文件位置，已停止添加"
        case .extractionFailed: "下载的内容无法安全打开"
        case .noSkillsFound: "这个仓库里没有找到可以添加的 Skill"
        case .noStableRelease: "这个仓库还没有正式 Release，可以改为跟随默认分支"
        case .authenticationRequired: "这个仓库需要 GitHub 授权才能查看"
        case .repositoryUnavailableOrUnauthorized: "找不到这个仓库，或者 SkillBox 还没有访问权限"
        case .repositoryPermissionRequired: "SkillBox 还没有获准读取这个私人仓库"
        case let .rateLimited(retryAt): "GitHub 暂时限制了查询，请在 \(retryAt.formatted(date: .omitted, time: .shortened)) 后重试"
        case .skillPathMissing: "GitHub 上找不到原来的 Skill 目录"
        case .releaseAssetSelectionRequired: "这个 Release 有多个可用安装包，请选择要导入的 ZIP"
        case let .checksumMismatch(name): "\(name) 的 SHA-256 校验未通过，已停止导入"
        case .releaseAssetUnavailable: "选择的 Release 安装包已不可用，请重新检查"
        }
    }
}

public struct GitHubSourceProvider: SourceProvider, GitHubRemoteVersionChecking, Sendable {
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
        let repository = try RepositoryName(repositoryFullName)
        let info: RepositoryResponse
        do {
            info = try await requestAPI(path: "/repos/\(repository.owner)/\(repository.name)")
        } catch GitHubSourceError.requestFailed(404) {
            if await preferredAccessToken() != nil {
                throw GitHubSourceError.repositoryPermissionRequired
            }
            throw GitHubSourceError.repositoryUnavailableOrUnauthorized
        }
        let revision: String
        let versionIdentifier: String
        let versionName: String
        let publishedAt: Date?
        var archiveURL: URL
        var releaseID: Int64?
        var releaseAssets: [GitHubReleaseAsset] = []
        var selectedReleaseAssetID: Int64?
        var usesSourceArchiveFallback = false

        switch trackingMode {
        case .latestStableRelease:
            let release: ReleaseResponse
            do {
                release = try await requestAPI(path: "/repos/\(repository.owner)/\(repository.name)/releases/latest")
            } catch GitHubSourceError.requestFailed(404) {
                throw GitHubSourceError.noStableRelease
            }
            revision = release.tagName
            versionIdentifier = "release:\(release.id)"
            versionName = release.tagName
            publishedAt = release.publishedAt
            let zipAssets = release.assets.filter(\.isInstallableZIP).map { asset in
                var enriched = asset
                if let checksum = release.assets.first(where: {
                    $0.state == "uploaded" && $0.name.caseInsensitiveCompare(asset.name + ".sha256") == .orderedSame
                }) {
                    enriched.checksumAssetID = checksum.id
                    enriched.checksumDownloadURL = checksum.browserDownloadURL
                }
                return enriched
            }
            archiveURL = zipAssets.count == 1 ? zipAssets[0].browserDownloadURL : release.zipballURL
            releaseID = release.id
            releaseAssets = zipAssets
            selectedReleaseAssetID = zipAssets.count == 1 ? zipAssets[0].id : nil
            usesSourceArchiveFallback = zipAssets.isEmpty
        case .defaultBranch:
            revision = info.defaultBranch
            versionName = info.defaultBranch
            publishedAt = nil
            archiveURL = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/zipball/\(revision.urlPathSegment)")!
            versionIdentifier = ""
            releaseID = nil
        }

        let commit: CommitResponse = try await requestAPI(path: "/repos/\(repository.owner)/\(repository.name)/commits/\(revision.urlPathSegment)")
        if trackingMode == .defaultBranch {
            archiveURL = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/zipball/\(commit.sha.urlPathSegment)")!
        }
        let resolvedIdentifier: String
        if trackingMode == .defaultBranch {
            resolvedIdentifier = "commit:\(commit.sha)"
        } else if usesSourceArchiveFallback, let releaseID {
            resolvedIdentifier = "release:\(releaseID):source:\(commit.sha)"
        } else {
            resolvedIdentifier = versionIdentifier
        }
        let selectedTree = try await treeSHA(
            repository: repository,
            rootTreeSHA: commit.commit.tree.sha,
            skillPath: skillPath
        )
        var remote = GitHubRemoteVersion(
            repositoryID: info.id,
            repositoryFullName: info.fullName,
            isPrivate: info.isPrivate,
            trackingMode: trackingMode,
            defaultBranch: info.defaultBranch,
            versionIdentifier: resolvedIdentifier,
            versionName: versionName,
            revision: revision,
            commitSHA: commit.sha,
            treeSHA: selectedTree,
            publishedAt: publishedAt,
            archiveURL: archiveURL,
            releaseID: releaseID,
            releaseAssets: releaseAssets,
            selectedReleaseAssetID: selectedReleaseAssetID,
            usesSourceArchiveFallback: usesSourceArchiveFallback
        )
        if let selectedReleaseAssetID {
            remote = try remote.selectingReleaseAsset(id: selectedReleaseAssetID)
        }
        return remote
    }

    public func preview(locator: String) async throws -> [SkillCandidate] {
        let reference = try GitHubReference.parse(locator)
        let revision = try await reference.revision(using: session)
        let archiveURL = URL(string: "https://codeload.github.com/\(reference.owner)/\(reference.repository)/zip/\(revision)")!
        let (data, response) = try await session.data(from: archiveURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GitHubSourceError.requestFailed(http.statusCode)
        }
        guard data.count <= limits.maximumDownloadBytes else { throw GitHubSourceError.downloadTooLarge }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHub-\(UUID().uuidString)")
        let archive = temporary.appendingPathComponent("source.zip")
        let extracted = temporary.appendingPathComponent("extracted")
        var retainTemporaryDirectory = false
        defer {
            if !retainTemporaryDirectory { try? FileManager.default.removeItem(at: temporary) }
        }
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)

        let entries = try listArchive(archive)
        guard entries.count <= limits.maximumFileCount else { throw GitHubSourceError.tooManyFiles }
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || components.contains("..") { throw GitHubSourceError.unsafeArchivePath(entry) }
        }
        let metadata = try run("/usr/bin/unzip", arguments: ["-Z", "-l", archive.path])
        if metadata.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("l") }) {
            throw GitHubSourceError.unsafeArchivePath("压缩包包含软链接")
        }
        let expandedBytes = try archiveExpandedSize(archive)
        guard expandedBytes <= limits.maximumExpandedBytes else { throw GitHubSourceError.archiveTooLarge }
        try run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
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
        locator: String
    ) async throws -> GitHubSnapshot {
        if version.requiresReleaseAssetSelection {
            throw GitHubSourceError.releaseAssetSelectionRequired(version.releaseAssets)
        }
        let request = try await downloadRequest(url: version.archiveURL)
        let data = try await downloadData(request: request)
        let verifiedDigest = try await verifyReleaseAsset(data, asset: version.selectedReleaseAsset)
        var resolvedVersion = version
        if let verifiedDigest,
           let selectedAssetID = version.selectedReleaseAssetID,
           let index = resolvedVersion.releaseAssets.firstIndex(where: { $0.id == selectedAssetID })
        {
            resolvedVersion.releaseAssets[index].digest = "sha256:\(verifiedDigest)"
            resolvedVersion = try resolvedVersion.selectingReleaseAsset(id: selectedAssetID)
        }
        let candidates = try await extractCandidates(
            data: data,
            repositoryFullName: resolvedVersion.repositoryFullName,
            locator: locator,
            revision: resolvedVersion.commitSHA,
            selectedSkillPath: skillPath,
            archiveIsReleaseAsset: resolvedVersion.selectedReleaseAsset != nil
        )
        return GitHubSnapshot(version: resolvedVersion, candidates: candidates)
    }

    private func downloadRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await preferredAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func verifyReleaseAsset(_ data: Data, asset: GitHubReleaseAsset?) async throws -> String? {
        guard let asset else { return nil }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let digest = asset.digest,
           digest.lowercased().hasPrefix("sha256:"),
           String(digest.dropFirst("sha256:".count)).lowercased() != actual
        {
            throw GitHubSourceError.checksumMismatch(asset.name)
        }
        guard let checksumURL = asset.checksumDownloadURL else { return actual }
        let checksumData = try await downloadData(request: downloadRequest(url: checksumURL))
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

    private func downloadData(request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let retryAt = rateLimitRetryDate(from: http) {
                throw GitHubSourceError.rateLimited(retryAt: retryAt)
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
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SkillBoxGitHub-\(UUID().uuidString)")
        let archive = temporary.appendingPathComponent("source.zip")
        let extracted = temporary.appendingPathComponent("extracted")
        var retainTemporaryDirectory = false
        defer { if !retainTemporaryDirectory { try? FileManager.default.removeItem(at: temporary) } }
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try data.write(to: archive, options: .atomic)
        let entries = try listArchive(archive)
        guard entries.count <= limits.maximumFileCount else { throw GitHubSourceError.tooManyFiles }
        for entry in entries {
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || components.contains("..") { throw GitHubSourceError.unsafeArchivePath(entry) }
        }
        let metadata = try run("/usr/bin/unzip", arguments: ["-Z", "-l", archive.path])
        if metadata.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("l") }) {
            throw GitHubSourceError.unsafeArchivePath("压缩包包含软链接")
        }
        guard try archiveExpandedSize(archive) <= limits.maximumExpandedBytes else { throw GitHubSourceError.archiveTooLarge }
        try run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
        try validateExpandedTree(extracted)
        let repositoryRoot = try archiveContentRoot(in: extracted)
        let selectedRoot = archiveIsReleaseAsset
            ? repositoryRoot
            : selectedSkillPath.map { repositoryRoot.appendingPathComponent($0) } ?? repositoryRoot
        let result = await scanner.scan(roots: [selectedRoot], sourceName: { _ in "GitHub" })
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

    private func listArchive(_ archive: URL) throws -> [String] {
        let output = try run("/usr/bin/unzip", arguments: ["-Z1", archive.path])
        return output.split(separator: "\n").map(String.init)
    }

    private func treeSHA(repository: RepositoryName, rootTreeSHA: String, skillPath: String?) async throws -> String {
        guard let skillPath, !skillPath.isEmpty else { return rootTreeSHA }
        var currentSHA = rootTreeSHA
        for component in skillPath.split(separator: "/").map(String.init) {
            let tree: TreeResponse = try await requestAPI(path: "/repos/\(repository.owner)/\(repository.name)/git/trees/\(currentSHA.urlPathSegment)")
            guard let entry = tree.tree.first(where: { $0.path == component && $0.type == "tree" }) else {
                throw GitHubSourceError.skillPathMissing(skillPath)
            }
            currentSHA = entry.sha
        }
        return currentSHA
    }

    private func requestAPI<Response: Decodable>(path: String) async throws -> Response {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw GitHubSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await preferredAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           request.value(forHTTPHeaderField: "Authorization") != nil,
           rateLimitRetryDate(from: http) == nil,
           http.statusCode == 401 || http.statusCode == 403
        {
            await rejectAuthorization(in: request)
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let retryAt = rateLimitRetryDate(from: http) {
                throw GitHubSourceError.rateLimited(retryAt: retryAt)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GitHubSourceError.authenticationRequired
            }
            throw GitHubSourceError.requestFailed(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
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

    private func archiveExpandedSize(_ archive: URL) throws -> Int {
        let output = try run("/usr/bin/unzip", arguments: ["-l", archive.path])
        return output.split(separator: "\n").reduce(into: 0) { total, line in
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 4, let size = Int(columns[0]) else { return }
            total += size
        }
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
    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw GitHubSourceError.extractionFailed(String(text.prefix(500))) }
        return text
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

    func revision(using session: URLSession) async throws -> String {
        if let explicitRevision { return explicitRevision }
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)")!
        var request = URLRequest(url: url)
        request.setValue("SkillBox/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw GitHubSourceError.requestFailed(http.statusCode) }
        struct Repository: Decodable { var default_branch: String }
        return try JSONDecoder().decode(Repository.self, from: data).default_branch
    }
}
