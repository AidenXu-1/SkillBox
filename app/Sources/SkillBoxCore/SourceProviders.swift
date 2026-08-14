import Foundation

public protocol SourceProvider: Sendable {
    func preview(locator: String) async throws -> [SkillCandidate]
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

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "这个 GitHub 地址无法识别，请检查后重试"
        case .unsupportedHost: "目前只能从 github.com 的公开仓库添加"
        case .requestFailed: "暂时无法从 GitHub 获取内容，请稍后重试"
        case .downloadTooLarge: "GitHub 下载的文件太大，目前最多约 10 MB"
        case .archiveTooLarge: "这个仓库展开后太大，目前最多约 25 MB"
        case .tooManyFiles: "这个仓库文件太多，目前最多 1000 个"
        case .unsafeArchivePath: "这个仓库包含不安全的文件位置，已停止添加"
        case .extractionFailed: "下载的内容无法安全打开"
        case .noSkillsFound: "这个仓库里没有找到可以添加的 Skill"
        }
    }
}

public struct GitHubSourceProvider: SourceProvider, Sendable {
    private let session: URLSession
    private let limits: GitHubDownloadLimits
    private let scanner: any SkillScanner

    public init(
        session: URLSession = .shared,
        limits: GitHubDownloadLimits = GitHubDownloadLimits(),
        scanner: any SkillScanner = FileSystemSkillScanner()
    ) {
        self.session = session
        self.limits = limits
        self.scanner = scanner
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

        let repositoryRoot = try firstDirectory(in: extracted)
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

    private func listArchive(_ archive: URL) throws -> [String] {
        let output = try run("/usr/bin/unzip", arguments: ["-Z1", archive.path])
        return output.split(separator: "\n").map(String.init)
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
