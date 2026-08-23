import CryptoKit
import Foundation

public enum LocalSourceStatus: String, Codable, Sendable {
    case current
    case updateAvailable
    case packageReviewRequired
    case sourceUnavailable
}

public struct LocalPackageRecipe: Codable, Hashable, Sendable {
    public static let currentSelectionPolicyVersion = 1

    public var skillRelativePath: String
    public var includePaths: [String]
    public var reviewedTopLevelPaths: [String]
    public var selectionPolicyVersion: Int

    public init(
        skillRelativePath: String,
        includePaths: [String],
        reviewedTopLevelPaths: [String],
        selectionPolicyVersion: Int = LocalPackageRecipe.currentSelectionPolicyVersion
    ) {
        self.skillRelativePath = skillRelativePath
        self.includePaths = includePaths
        self.reviewedTopLevelPaths = reviewedTopLevelPaths
        self.selectionPolicyVersion = selectionPolicyVersion
    }
}

public struct LocalSourceState: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { skillID }
    public var skillID: UUID
    public var projectRootPath: String
    public var projectRootBookmarkData: Data?
    public var recipe: LocalPackageRecipe
    public var currentPackageFingerprint: String
    public var availablePackageFingerprint: String?
    public var topLevelFingerprints: [String: String]
    public var availableTopLevelFingerprints: [String: String]?
    public var lastCheckedAt: Date?
    public var status: LocalSourceStatus

    public init(
        skillID: UUID,
        projectRootPath: String,
        projectRootBookmarkData: Data? = nil,
        recipe: LocalPackageRecipe,
        currentPackageFingerprint: String,
        availablePackageFingerprint: String? = nil,
        topLevelFingerprints: [String: String] = [:],
        availableTopLevelFingerprints: [String: String]? = nil,
        lastCheckedAt: Date? = nil,
        status: LocalSourceStatus = .current
    ) {
        self.skillID = skillID
        self.projectRootPath = projectRootPath
        self.projectRootBookmarkData = projectRootBookmarkData
        self.recipe = recipe
        self.currentPackageFingerprint = currentPackageFingerprint
        self.availablePackageFingerprint = availablePackageFingerprint
        self.topLevelFingerprints = topLevelFingerprints
        self.availableTopLevelFingerprints = availableTopLevelFingerprints
        self.lastCheckedAt = lastCheckedAt
        self.status = status
    }
}

public enum LocalPackageEntryKind: String, Codable, Sendable {
    case required
    case likelyRuntime
    case possibleRuntime
    case developmentOnly
}

public struct LocalPackageEntry: Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var isDirectory: Bool
    public var kind: LocalPackageEntryKind

    public init(relativePath: String, isDirectory: Bool, kind: LocalPackageEntryKind) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.kind = kind
    }
}

public struct LocalPackageReview: Hashable, Identifiable, Sendable {
    public var id: String { candidate.id }
    public var candidate: SkillCandidate
    public var projectRootPath: String
    public var skillRelativePath: String
    public var entries: [LocalPackageEntry]
    public var recommendedIncludePaths: [String]
    public var developmentOnlyPaths: [String]
    public var newUnreviewedPaths: [String]
    public var missingSelectedPaths: [String]
    public var existingState: LocalSourceState?

    public init(
        candidate: SkillCandidate,
        projectRootPath: String,
        skillRelativePath: String,
        entries: [LocalPackageEntry],
        recommendedIncludePaths: [String],
        developmentOnlyPaths: [String],
        newUnreviewedPaths: [String] = [],
        missingSelectedPaths: [String] = [],
        existingState: LocalSourceState? = nil
    ) {
        self.candidate = candidate
        self.projectRootPath = projectRootPath
        self.skillRelativePath = skillRelativePath
        self.entries = entries
        self.recommendedIncludePaths = recommendedIncludePaths
        self.developmentOnlyPaths = developmentOnlyPaths
        self.newUnreviewedPaths = newUnreviewedPaths
        self.missingSelectedPaths = missingSelectedPaths
        self.existingState = existingState
    }
}

public struct LocalResolvedPackage: Hashable, Sendable {
    public var candidate: SkillCandidate
    public var recipe: LocalPackageRecipe
    public var topLevelFingerprints: [String: String]

    public init(
        candidate: SkillCandidate,
        recipe: LocalPackageRecipe,
        topLevelFingerprints: [String: String]
    ) {
        self.candidate = candidate
        self.recipe = recipe
        self.topLevelFingerprints = topLevelFingerprints
    }
}

public struct LocalSourceCheckResult: Sendable {
    public var state: LocalSourceState
    public var candidate: SkillCandidate?
    public var review: LocalPackageReview?
    public var ignoredChangedPaths: [String]

    public init(
        state: LocalSourceState,
        candidate: SkillCandidate? = nil,
        review: LocalPackageReview? = nil,
        ignoredChangedPaths: [String] = []
    ) {
        self.state = state
        self.candidate = candidate
        self.review = review
        self.ignoredChangedPaths = ignoredChangedPaths
    }
}

public enum LocalPackageError: LocalizedError {
    case sourceOutsideProject
    case unsafePath(String)
    case selectedPathMissing(String)
    case overlappingPaths(String, String)
    case skillMarkdownRequired
    case packageCouldNotBeBuilt

    public var errorDescription: String? {
        switch self {
        case .sourceOutsideProject:
            "选择的 Skill 不在这个开发项目中"
        case let .unsafePath(path):
            "可使用内容包含不安全的位置：\(path)"
        case let .selectedPathMissing(path):
            "原来选择的内容已经不存在：\(path)。请重新确认可使用内容"
        case let .overlappingPaths(parent, child):
            "可使用内容重复包含了同一份文件：\(parent) 和 \(child)"
        case .skillMarkdownRequired:
            "可使用内容必须包含 SKILL.md"
        case .packageCouldNotBeBuilt:
            "无法从选择的内容组成一份完整 Skill"
        }
    }
}

public struct LocalSkillPackageResolver: Sendable {
    private let scanner: any SkillScanner
    private let fingerprinter: any SkillFingerprinting

    public init(
        scanner: any SkillScanner = FileSystemSkillScanner(),
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter()
    ) {
        self.scanner = scanner
        self.fingerprinter = fingerprinter
    }

    public func review(
        candidate: SkillCandidate,
        projectRoot: URL,
        existingState: LocalSourceState? = nil
    ) throws -> LocalPackageReview {
        let root = projectRoot.standardizedFileURL
        let skillRoot = candidate.sourceURL.standardizedFileURL
        guard skillRoot.path == root.path || skillRoot.path.hasPrefix(root.path + "/") else {
            throw LocalPackageError.sourceOutsideProject
        }
        try SafeFileOperations.validateTree(root: skillRoot)
        let relative = skillRoot.path == root.path
            ? ""
            : String(skillRoot.path.dropFirst(root.path.count + 1))
        let entries = try topLevelEntries(in: skillRoot)
        let entryPaths = Set(entries.map(\.relativePath))
        let requiredPaths = Set(entries.filter { $0.kind == .required }.map(\.relativePath))
        let developmentPaths = entries.filter { $0.kind == .developmentOnly }.map(\.relativePath)
        let newPaths: [String]
        let missingPaths: [String]
        let selected: Set<String>

        if let existingState {
            let reviewed = Set(existingState.recipe.reviewedTopLevelPaths)
            newPaths = entries.filter {
                !reviewed.contains($0.relativePath) && $0.kind != .developmentOnly
            }.map(\.relativePath)
            missingPaths = existingState.recipe.includePaths.filter { !entryPaths.contains($0) }
            selected = Set(existingState.recipe.includePaths.filter(entryPaths.contains))
                .union(requiredPaths)
                .union(newPaths)
        } else {
            newPaths = []
            missingPaths = []
            selected = Set(entries.filter { $0.kind != .developmentOnly }.map(\.relativePath))
        }

        var updatedCandidate = candidate
        updatedCandidate.source = .init(
            kind: .localFolder,
            displayName: "本地开发源",
            locator: skillRoot.path,
            skillPath: relative.isEmpty ? nil : relative
        )
        return .init(
            candidate: updatedCandidate,
            projectRootPath: root.path,
            skillRelativePath: relative,
            entries: entries,
            recommendedIncludePaths: Self.sortedPaths(Array(selected)),
            developmentOnlyPaths: Self.sortedPaths(developmentPaths),
            newUnreviewedPaths: Self.sortedPaths(newPaths),
            missingSelectedPaths: Self.sortedPaths(missingPaths),
            existingState: existingState
        )
    }

    public func confirm(
        review: LocalPackageReview,
        includePaths: [String]
    ) async throws -> LocalResolvedPackage {
        let normalized = try normalizeAndValidate(
            includePaths,
            root: review.candidate.sourceURL,
            requireSkillMarkdown: true
        )
        let packaged = try await materialize(candidate: review.candidate, includePaths: normalized)
        let recipe = LocalPackageRecipe(
            skillRelativePath: review.skillRelativePath,
            includePaths: normalized,
            reviewedTopLevelPaths: Self.sortedPaths(review.entries.map(\.relativePath))
        )
        return .init(
            candidate: packaged,
            recipe: recipe,
            topLevelFingerprints: try topLevelFingerprints(in: review.candidate.sourceURL)
        )
    }

    public func check(state: LocalSourceState) async throws -> LocalSourceCheckResult {
        var state = state
        state.lastCheckedAt = Date()
        guard let access = projectRootAccess(for: state) else {
            state.status = .sourceUnavailable
            state.availablePackageFingerprint = nil
            state.availableTopLevelFingerprints = nil
            return .init(state: state)
        }
        defer { if access.didStartSecurityScope { access.url.stopAccessingSecurityScopedResource() } }

        let projectRoot = access.url.standardizedFileURL
        state.projectRootPath = projectRoot.path
        if state.projectRootBookmarkData != nil,
           let refreshedBookmark = Self.bookmarkData(for: projectRoot)
        {
            state.projectRootBookmarkData = refreshedBookmark
        }
        let skillRoot = state.recipe.skillRelativePath.isEmpty
            ? projectRoot
            : projectRoot.appendingPathComponent(state.recipe.skillRelativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: skillRoot.appendingPathComponent("SKILL.md").path),
              let candidate = await localCandidate(at: skillRoot)
        else {
            state.status = .sourceUnavailable
            state.availablePackageFingerprint = nil
            state.availableTopLevelFingerprints = nil
            return .init(state: state)
        }

        let review = try review(candidate: candidate, projectRoot: projectRoot, existingState: state)
        let mustReview = state.recipe.selectionPolicyVersion < LocalPackageRecipe.currentSelectionPolicyVersion ||
            !review.newUnreviewedPaths.isEmpty ||
            !review.missingSelectedPaths.isEmpty ||
            review.entries.contains { entry in
                entry.kind == .required && !state.recipe.includePaths.contains(entry.relativePath)
            }
        if mustReview {
            state.status = .packageReviewRequired
            state.availablePackageFingerprint = nil
            state.availableTopLevelFingerprints = try topLevelFingerprints(in: skillRoot)
            return .init(state: state, review: review)
        }

        let resolved = try await confirm(review: review, includePaths: state.recipe.includePaths)
        let ignoredChanges = changedIgnoredPaths(
            previous: state.topLevelFingerprints,
            current: resolved.topLevelFingerprints,
            includePaths: state.recipe.includePaths
        )
        if resolved.candidate.fingerprint == state.currentPackageFingerprint {
            removeMaterializedCandidate(resolved.candidate)
            state.status = .current
            state.recipe = resolved.recipe
            state.topLevelFingerprints = resolved.topLevelFingerprints
            state.availablePackageFingerprint = nil
            state.availableTopLevelFingerprints = nil
            return .init(state: state, ignoredChangedPaths: ignoredChanges)
        }

        state.status = .updateAvailable
        state.availablePackageFingerprint = resolved.candidate.fingerprint
        state.availableTopLevelFingerprints = resolved.topLevelFingerprints
        return .init(
            state: state,
            candidate: resolved.candidate,
            ignoredChangedPaths: ignoredChanges
        )
    }

    public func review(state: LocalSourceState) async throws -> LocalPackageReview? {
        guard let access = projectRootAccess(for: state) else { return nil }
        defer { if access.didStartSecurityScope { access.url.stopAccessingSecurityScopedResource() } }
        let projectRoot = access.url.standardizedFileURL
        let skillRoot = state.recipe.skillRelativePath.isEmpty
            ? projectRoot
            : projectRoot.appendingPathComponent(state.recipe.skillRelativePath, isDirectory: true)
        guard let candidate = await localCandidate(at: skillRoot) else { return nil }
        return try review(candidate: candidate, projectRoot: projectRoot, existingState: state)
    }

    public static func bookmarkData(for projectRoot: URL) -> Data? {
        try? projectRoot.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func projectRootAccess(for state: LocalSourceState) -> (url: URL, didStartSecurityScope: Bool)? {
        if let data = state.projectRootBookmarkData {
            var isStale = false
            if let bookmarked = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: bookmarked.path) {
                return (bookmarked, bookmarked.startAccessingSecurityScopedResource())
            }
        }
        let fallback = URL(fileURLWithPath: state.projectRootPath, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fallback.path) else { return nil }
        return (fallback, false)
    }

    private func localCandidate(at skillRoot: URL) async -> SkillCandidate? {
        let result = await scanner.scan(roots: [skillRoot], sourceName: { _ in "本地开发源" })
        guard var candidate = result.candidates.first(where: {
            $0.sourceURL.standardizedFileURL == skillRoot.standardizedFileURL
        }) else { return nil }
        candidate.source = .init(
            kind: .localFolder,
            displayName: "本地开发源",
            locator: skillRoot.path
        )
        return candidate
    }

    private func materialize(
        candidate: SkillCandidate,
        includePaths: [String]
    ) async throws -> SkillCandidate {
        let fileManager = FileManager.default
        let normalized = try normalizeAndValidate(
            includePaths,
            root: candidate.sourceURL,
            requireSkillMarkdown: true
        )
        let packageRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SkillBoxLocalPackage-\(UUID().uuidString)", isDirectory: true)
        let content = packageRoot.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
        do {
            for path in normalized {
                let source = candidate.sourceURL.appendingPathComponent(path)
                let destination = content.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
            }
            try SafeFileOperations.validateTree(root: content, fileManager: fileManager)
            let result = await scanner.scan(roots: [content], sourceName: { _ in "本地开发源" })
            guard var packaged = result.candidates.first,
                  packaged.sourceURL.standardizedFileURL == content.standardizedFileURL
            else { throw LocalPackageError.packageCouldNotBeBuilt }
            packaged.directoryName = candidate.directoryName
            packaged.source = candidate.source
            packaged.temporaryPackageRoot = packageRoot
            return packaged
        } catch {
            try? fileManager.removeItem(at: packageRoot)
            throw error
        }
    }

    private func removeMaterializedCandidate(_ candidate: SkillCandidate) {
        guard let packageRoot = candidate.temporaryPackageRoot,
              candidate.sourceURL.standardizedFileURL == packageRoot
                .appendingPathComponent("content", isDirectory: true)
                .standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: packageRoot)
    }

    private func normalizeAndValidate(
        _ paths: [String],
        root: URL,
        requireSkillMarkdown: Bool
    ) throws -> [String] {
        let fileManager = FileManager.default
        let normalizedRoot = root.standardizedFileURL
        var normalized: [String] = []
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty,
                  !raw.hasPrefix("/"),
                  path != ".",
                  !path.split(separator: "/").contains("..")
            else { throw LocalPackageError.unsafePath(raw) }
            let source = root.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(normalizedRoot.path + "/") else {
                throw LocalPackageError.unsafePath(raw)
            }
            guard fileManager.fileExists(atPath: source.path) else {
                throw LocalPackageError.selectedPathMissing(path)
            }
            normalized.append(path)
        }
        normalized = Array(Set(normalized))
        for parent in normalized {
            for child in normalized where parent != child && child.hasPrefix(parent + "/") {
                throw LocalPackageError.overlappingPaths(parent, child)
            }
        }
        if requireSkillMarkdown, !normalized.contains("SKILL.md") {
            throw LocalPackageError.skillMarkdownRequired
        }
        return Self.sortedPaths(normalized)
    }

    private func topLevelEntries(in root: URL) throws -> [LocalPackageEntry] {
        let fileManager = FileManager.default
        let skillInstructions = (try? String(
            contentsOf: root.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )) ?? ""
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).map { url -> LocalPackageEntry in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let path = url.lastPathComponent
            let kind: LocalPackageEntryKind
            if path == "SKILL.md" {
                kind = .required
            } else if Self.isReferencedBySkillInstructions(
                path,
                isDirectory: values.isDirectory == true,
                instructions: skillInstructions
            ) {
                kind = .required
            } else if Self.isLikelyRuntimePath(path) {
                kind = .likelyRuntime
            } else if Self.isDevelopmentOnlyPath(path) {
                kind = .developmentOnly
            } else {
                kind = .possibleRuntime
            }
            return .init(relativePath: path, isDirectory: values.isDirectory == true, kind: kind)
        }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func topLevelFingerprints(in root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                result[url.lastPathComponent] = try fingerprinter.fingerprint(directory: url)
            } else if values.isRegularFile == true {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let permission = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                var hasher = SHA256()
                hasher.update(data: Data("F\0\(permission)\0".utf8))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    hasher.update(data: data)
                }
                result[url.lastPathComponent] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    private func changedIgnoredPaths(
        previous: [String: String],
        current: [String: String],
        includePaths: [String]
    ) -> [String] {
        let includedTopLevel = Set(includePaths.compactMap { $0.split(separator: "/").first.map(String.init) })
        return Set(previous.keys).union(current.keys).filter { path in
            !includedTopLevel.contains(path) && previous[path] != current[path]
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func sortedPaths(_ paths: [String]) -> [String] {
        paths.sorted { left, right in
            if left == "SKILL.md" { return true }
            if right == "SKILL.md" { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private static func isLikelyRuntimePath(_ path: String) -> Bool {
        ["agents", "assets", "references", "scripts", "templates"].contains(path.lowercased())
    }

    private static func isDevelopmentOnlyPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if [
            ".git", ".github", ".gitlab", ".circleci", ".vscode", ".idea", ".build",
            "build", "design", "docs", "node_modules", "notes", "scratch", "test", "tests", "tmp",
        ].contains(lower) {
            return true
        }
        return [
            ".editorconfig", ".gitattributes", ".gitignore", ".swiftlint.yml",
            "changelog", "changelog.md", "code_of_conduct.md", "contributing.md",
            "license", "license.md", "readme", "readme.md", "security.md",
        ].contains(lower)
    }

    private static func isReferencedBySkillInstructions(
        _ path: String,
        isDirectory: Bool,
        instructions: String
    ) -> Bool {
        let normalizedInstructions = instructions.lowercased()
        let normalizedPath = path.lowercased()
        if isDirectory {
            return normalizedInstructions.contains(normalizedPath + "/") ||
                normalizedInstructions.contains(normalizedPath + "\\")
        }
        return normalizedInstructions.contains(normalizedPath)
    }
}
