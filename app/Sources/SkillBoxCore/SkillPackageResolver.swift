import Foundation

public enum GitHubPackageError: LocalizedError {
    case invalidManifest
    case manifestMustIncludeSkill
    case unsafePath(String)
    case selectedPathMissing(String)
    case overlappingPaths(String, String)
    case sourceIdentityChanged
    case packageCouldNotBeBuilt

    public var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "这个仓库的 skillbox.json 无法读取，请让作者检查安装清单"
        case .manifestMustIncludeSkill:
            "安装清单必须包含 SKILL.md"
        case let .unsafePath(path):
            "安装清单包含不安全的位置：\(path)"
        case let .selectedPathMissing(path):
            "原来选择的内容已经不存在：\(path)。请重新确认这份 Skill 要安装什么"
        case let .overlappingPaths(parent, child):
            "安装清单重复包含了同一份内容：\(parent) 和 \(child)"
        case .sourceIdentityChanged:
            "GitHub 来源已经变化。为了避免装错内容，请重新确认这份 Skill"
        case .packageCouldNotBeBuilt:
            "无法从选择的内容组成一份完整 Skill，请确认其中包含有效的 SKILL.md"
        }
    }
}

public enum GitHubPackageEntryKind: String, Codable, Sendable {
    case required
    case likelyRuntime
    case possibleRuntime
    case repositoryOnly
}

public struct GitHubPackageEntry: Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var isDirectory: Bool
    public var kind: GitHubPackageEntryKind

    public init(relativePath: String, isDirectory: Bool, kind: GitHubPackageEntryKind) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.kind = kind
    }
}

public struct GitHubPackageReview: Hashable, Identifiable, Sendable {
    public var id: String { "\(candidate.id):\(version.versionIdentifier)" }
    public var candidate: SkillCandidate
    public var version: GitHubRemoteVersion
    public var entries: [GitHubPackageEntry]
    public var recommendedIncludePaths: [String]
    public var repositoryOnlyPaths: [String]
    public var newUnreviewedPaths: [String]
    public var existingRecipe: GitHubPackageRecipe?

    public init(
        candidate: SkillCandidate,
        version: GitHubRemoteVersion,
        entries: [GitHubPackageEntry],
        recommendedIncludePaths: [String],
        repositoryOnlyPaths: [String],
        newUnreviewedPaths: [String] = [],
        existingRecipe: GitHubPackageRecipe? = nil
    ) {
        self.candidate = candidate
        self.version = version
        self.entries = entries
        self.recommendedIncludePaths = recommendedIncludePaths
        self.repositoryOnlyPaths = repositoryOnlyPaths
        self.newUnreviewedPaths = newUnreviewedPaths
        self.existingRecipe = existingRecipe
    }
}

public struct GitHubResolvedPackage: Hashable, Sendable {
    public var candidate: SkillCandidate
    public var recipe: GitHubPackageRecipe

    public init(candidate: SkillCandidate, recipe: GitHubPackageRecipe) {
        self.candidate = candidate
        self.recipe = recipe
    }
}

public enum GitHubPackageResolution: Hashable, Sendable {
    case ready(GitHubResolvedPackage)
    case needsConfirmation(GitHubPackageReview)
}

public struct GitHubSkillPackageResolver: Sendable {
    private let scanner: any SkillScanner

    public init(scanner: any SkillScanner = FileSystemSkillScanner()) {
        self.scanner = scanner
    }

    public func resolve(
        candidate: SkillCandidate,
        version: GitHubRemoteVersion,
        archiveIsReleaseAsset: Bool,
        existingRecipe: GitHubPackageRecipe? = nil
    ) async throws -> GitHubPackageResolution {
        let fileManager = FileManager.default
        try SafeFileOperations.validateTree(root: candidate.sourceURL, fileManager: fileManager)
        if archiveIsReleaseAsset {
            return .ready(.init(
                candidate: candidate,
                recipe: recipe(
                    origin: .releaseAsset,
                    version: version,
                    skillPath: normalizedSkillPath(candidate.source.skillPath)
                )
            ))
        }

        if let skillPath = normalizedSkillPath(candidate.source.skillPath) {
            return .ready(.init(
                candidate: candidate,
                recipe: recipe(origin: .skillDirectory, version: version, skillPath: skillPath)
            ))
        }

        if let existingRecipe {
            try validate(existingRecipe, against: version, skillPath: nil)
            let entries = try topLevelEntries(in: candidate.sourceURL)
            let installablePaths = entries.filter { $0.kind != .repositoryOnly }.map(\.relativePath)
            let requiredPaths = entries.filter { $0.kind == .required }.map(\.relativePath)
            let newPaths = entries.filter {
                !existingRecipe.reviewedTopLevelPaths.contains($0.relativePath) &&
                    $0.kind != .repositoryOnly
            }.map(\.relativePath)
            let missingRequiredPaths = requiredPaths.filter {
                !existingRecipe.includePaths.contains($0)
            }
            if existingRecipe.requiresIntegrityReview || !newPaths.isEmpty || !missingRequiredPaths.isEmpty {
                let selectedPaths = existingRecipe.requiresIntegrityReview
                    ? installablePaths
                    : Array(Set(existingRecipe.includePaths + newPaths + missingRequiredPaths))
                return .needsConfirmation(review(
                    candidate: candidate,
                    version: version,
                    entries: entries,
                    selectedPaths: selectedPaths,
                    newUnreviewedPaths: Array(Set(newPaths + missingRequiredPaths)),
                    existingRecipe: existingRecipe
                ))
            }
            var updated = existingRecipe
            updated.repositoryFullName = version.repositoryFullName
            updated.confirmedVersionIdentifier = version.versionIdentifier
            updated.reviewedTopLevelPaths = entries.map(\.relativePath)
            updated.selectionPolicyVersion = GitHubPackageRecipe.currentSelectionPolicyVersion
            let packaged = try await materialize(candidate: candidate, includePaths: updated.includePaths)
            return .ready(.init(candidate: packaged, recipe: updated))
        }

        let manifestURL = candidate.sourceURL.appendingPathComponent("skillbox.json")
        if fileManager.fileExists(atPath: manifestURL.path) {
            let includePaths = try manifestPaths(at: manifestURL, root: candidate.sourceURL)
            let entries = try topLevelEntries(in: candidate.sourceURL)
            let packaged = try await materialize(candidate: candidate, includePaths: includePaths)
            return .ready(.init(
                candidate: packaged,
                recipe: recipe(
                    origin: .manifest,
                    version: version,
                    includePaths: includePaths,
                    reviewedPaths: entries.map(\.relativePath)
                )
            ))
        }

        let entries = try topLevelEntries(in: candidate.sourceURL)
        let hasAmbiguousContent = entries.contains { entry in
            entry.kind == .repositoryOnly || entry.kind == .possibleRuntime
        }
        let selected = entries.filter { $0.kind != .repositoryOnly }.map(\.relativePath)
        if hasAmbiguousContent {
            return .needsConfirmation(review(
                candidate: candidate,
                version: version,
                entries: entries,
                selectedPaths: selected
            ))
        }

        let packaged = try await materialize(candidate: candidate, includePaths: selected)
        return .ready(.init(
            candidate: packaged,
            recipe: recipe(
                origin: .automaticSelection,
                version: version,
                includePaths: selected,
                reviewedPaths: entries.map(\.relativePath)
            )
        ))
    }

    public func confirm(
        review: GitHubPackageReview,
        includePaths: [String]
    ) async throws -> GitHubPackageResolution {
        let normalized = try normalizeAndValidate(
            includePaths,
            root: review.candidate.sourceURL,
            requireSkillMarkdown: true
        )
        let packaged = try await materialize(candidate: review.candidate, includePaths: normalized)
        let entryPaths = review.entries.map(\.relativePath)
        var recipe = review.existingRecipe ?? self.recipe(
            origin: .userSelection,
            version: review.version
        )
        recipe.origin = .userSelection
        recipe.repositoryID = review.version.repositoryID
        recipe.repositoryFullName = review.version.repositoryFullName
        recipe.trackingMode = review.version.trackingMode
        recipe.skillPath = nil
        recipe.includePaths = normalized
        recipe.reviewedTopLevelPaths = entryPaths
        recipe.confirmedVersionIdentifier = review.version.versionIdentifier
        recipe.selectionPolicyVersion = GitHubPackageRecipe.currentSelectionPolicyVersion
        return .ready(.init(candidate: packaged, recipe: recipe))
    }

    private func review(
        candidate: SkillCandidate,
        version: GitHubRemoteVersion,
        entries: [GitHubPackageEntry],
        selectedPaths: [String],
        newUnreviewedPaths: [String] = [],
        existingRecipe: GitHubPackageRecipe? = nil
    ) -> GitHubPackageReview {
        .init(
            candidate: candidate,
            version: version,
            entries: entries,
            recommendedIncludePaths: Self.sortedPaths(selectedPaths),
            repositoryOnlyPaths: entries.filter { $0.kind == .repositoryOnly }.map(\.relativePath),
            newUnreviewedPaths: Self.sortedPaths(newUnreviewedPaths),
            existingRecipe: existingRecipe
        )
    }

    private func recipe(
        origin: GitHubPackageRecipeOrigin,
        version: GitHubRemoteVersion,
        skillPath: String? = nil,
        includePaths: [String] = [],
        reviewedPaths: [String] = []
    ) -> GitHubPackageRecipe {
        .init(
            origin: origin,
            repositoryID: version.repositoryID,
            repositoryFullName: version.repositoryFullName,
            trackingMode: version.trackingMode,
            skillPath: skillPath,
            includePaths: Self.sortedPaths(includePaths),
            reviewedTopLevelPaths: Self.sortedPaths(reviewedPaths),
            confirmedVersionIdentifier: version.versionIdentifier
        )
    }

    private func validate(
        _ recipe: GitHubPackageRecipe,
        against version: GitHubRemoteVersion,
        skillPath: String?
    ) throws {
        guard recipe.repositoryID == version.repositoryID,
              recipe.trackingMode == version.trackingMode,
              normalizedSkillPath(recipe.skillPath) == normalizedSkillPath(skillPath)
        else { throw GitHubPackageError.sourceIdentityChanged }
    }

    private func manifestPaths(at url: URL, root: URL) throws -> [String] {
        struct Manifest: Decodable {
            var schemaVersion: Int
            var include: [String]
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw GitHubPackageError.invalidManifest
        }
        guard manifest.schemaVersion == 1 else { throw GitHubPackageError.invalidManifest }
        return try normalizeAndValidate(manifest.include, root: root, requireSkillMarkdown: true)
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
            else { throw GitHubPackageError.unsafePath(raw) }
            let source = root.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(normalizedRoot.path + "/") else {
                throw GitHubPackageError.unsafePath(raw)
            }
            guard fileManager.fileExists(atPath: source.path) else {
                throw GitHubPackageError.selectedPathMissing(path)
            }
            normalized.append(path)
        }
        normalized = Array(Set(normalized))
        for parent in normalized {
            for child in normalized where parent != child && child.hasPrefix(parent + "/") {
                throw GitHubPackageError.overlappingPaths(parent, child)
            }
        }
        if requireSkillMarkdown, !normalized.contains("SKILL.md") {
            throw GitHubPackageError.manifestMustIncludeSkill
        }
        return Self.sortedPaths(normalized)
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
        let packageRoot = temporaryPackageRoot(for: candidate.sourceURL)
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
            let result = await scanner.scan(roots: [content], sourceName: { _ in "GitHub" })
            guard var packaged = result.candidates.first,
                  packaged.sourceURL.standardizedFileURL == content.standardizedFileURL
            else { throw GitHubPackageError.packageCouldNotBeBuilt }
            packaged.directoryName = candidate.directoryName
            packaged.source = candidate.source
            return packaged
        } catch {
            try? fileManager.removeItem(at: packageRoot)
            throw error
        }
    }

    private func topLevelEntries(in root: URL) throws -> [GitHubPackageEntry] {
        let fileManager = FileManager.default
        let skillInstructions = (try? String(
            contentsOf: root.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )) ?? ""
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).map { url -> GitHubPackageEntry in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let path = url.lastPathComponent
            let kind: GitHubPackageEntryKind
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
            } else if Self.isRepositoryOnlyPath(path) || path == "skillbox.json" {
                kind = .repositoryOnly
            } else {
                kind = .possibleRuntime
            }
            return GitHubPackageEntry(relativePath: path, isDirectory: values.isDirectory == true, kind: kind)
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private func temporaryPackageRoot(for source: URL) -> URL {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
        var ancestor = source.standardizedFileURL
        while ancestor.path.hasPrefix(temporaryRoot.path), ancestor.path != temporaryRoot.path {
            if ancestor.lastPathComponent.hasPrefix("SkillBoxGitHub-") {
                return ancestor.appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
            }
            ancestor.deleteLastPathComponent()
        }
        return temporaryRoot.appendingPathComponent("SkillBoxPackage-\(UUID().uuidString)", isDirectory: true)
    }

    private func normalizedSkillPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? nil : normalized
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

    public static func isRepositoryOnlyPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if [".git", ".github", ".gitlab", ".circleci", ".vscode", ".idea"].contains(lower) {
            return true
        }
        return [
            ".editorconfig", ".gitattributes", ".gitignore", ".swiftlint.yml",
            "changelog", "changelog.md", "code_of_conduct.md", "contributing.md",
            "license", "license.md", "readme", "readme.md", "security.md",
        ].contains(lower)
    }
}
