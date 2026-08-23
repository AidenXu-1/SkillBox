import Foundation

public protocol SkillScanner: Sendable {
    func scan(roots: [URL], sourceName: @Sendable (URL) -> String) async -> ScanResult
}

public struct SkillScanLimits: Sendable {
    public var maximumSkillDocumentBytes: Int
    public var maximumVisitedDirectoriesPerRoot: Int
    public var maximumSkillsPerRoot: Int
    public var maximumFilesPerSkill: Int
    public var maximumAggregateBytesPerSkill: Int
    public var maximumDepth: Int
    public var maximumDuration: TimeInterval

    public init(
        maximumSkillDocumentBytes: Int = 1 * 1_024 * 1_024,
        maximumVisitedDirectoriesPerRoot: Int = 10_000,
        maximumSkillsPerRoot: Int = 1_000,
        maximumFilesPerSkill: Int = 5_000,
        maximumAggregateBytesPerSkill: Int = 50 * 1_024 * 1_024,
        maximumDepth: Int = 32,
        maximumDuration: TimeInterval = 15
    ) {
        self.maximumSkillDocumentBytes = max(1, maximumSkillDocumentBytes)
        self.maximumVisitedDirectoriesPerRoot = max(1, maximumVisitedDirectoriesPerRoot)
        self.maximumSkillsPerRoot = max(1, maximumSkillsPerRoot)
        self.maximumFilesPerSkill = max(1, maximumFilesPerSkill)
        self.maximumAggregateBytesPerSkill = max(1, maximumAggregateBytesPerSkill)
        self.maximumDepth = max(1, maximumDepth)
        self.maximumDuration = max(0.1, maximumDuration)
    }
}

public enum SkillScanError: LocalizedError {
    case budgetExceeded(String)

    public var errorDescription: String? {
        switch self {
        case let .budgetExceeded(reason): "扫描范围过大（\(reason)），已跳过以避免影响应用启动"
        }
    }
}

public struct FileSystemSkillScanner: SkillScanner, Sendable {
    private let fingerprinter: any SkillFingerprinting
    private let riskAnalyzer: any RiskAnalyzer
    private let limits: SkillScanLimits

    public init(
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter(),
        riskAnalyzer: any RiskAnalyzer = StaticRiskAnalyzer(),
        limits: SkillScanLimits = SkillScanLimits()
    ) {
        self.fingerprinter = fingerprinter
        self.riskAnalyzer = riskAnalyzer
        self.limits = limits
    }

    public func scan(roots: [URL], sourceName: @Sendable (URL) -> String) async -> ScanResult {
        var candidates: [SkillCandidate] = []
        var diagnostics: [String] = []
        let deadline = Date().addingTimeInterval(limits.maximumDuration)

        for root in roots {
            if Task.isCancelled { break }
            do {
                let discovered = try discoverSkillRoots(in: root, deadline: deadline)
                for skillURL in discovered {
                    if Task.isCancelled { break }
                    do {
                        let skillFile = skillURL.appendingPathComponent("SKILL.md")
                        try validateSkillTree(skillURL, deadline: deadline)
                        let skillFileSize = try skillFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard skillFileSize <= limits.maximumSkillDocumentBytes else {
                            throw SkillScanError.budgetExceeded("SKILL.md 体积超过上限")
                        }
                        let data = try Data(contentsOf: skillFile, options: .mappedIfSafe)
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw CocoaError(.fileReadInapplicableStringEncoding)
                        }
                        let metadata = SkillMetadataParser.parse(text: text, fallbackName: skillURL.lastPathComponent)
                        try checkBudget(deadline: deadline)
                        let fingerprint = try fingerprinter.fingerprint(directory: skillURL)
                        try checkBudget(deadline: deadline)
                        let risk = try riskAnalyzer.analyze(skillDirectory: skillURL)
                        candidates.append(.init(
                            sourceURL: skillURL,
                            directoryName: skillURL.lastPathComponent,
                            canonicalName: metadata.name,
                            displayName: metadata.name,
                            description: metadata.description,
                            fingerprint: fingerprint,
                            source: .init(
                                kind: .agentDirectory,
                                displayName: sourceName(root),
                                locator: skillURL.path
                            ),
                            riskReport: risk
                        ))
                    } catch is CancellationError {
                        break
                    } catch {
                        diagnostics.append("\(skillURL.path)：\(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                diagnostics.append("\(root.path)：\(error.localizedDescription)")
            }
        }

        let sorted = candidates.sorted {
            if $0.canonicalName != $1.canonicalName {
                return $0.canonicalName.localizedStandardCompare($1.canonicalName) == .orderedAscending
            }
            return $0.sourceURL.path < $1.sourceURL.path
        }
        let groupedByName = Dictionary(grouping: sorted, by: \.canonicalName)
        var duplicateGroups: [DuplicateGroup] = []
        var conflicts: [ConflictGroup] = []

        for (name, nameCandidates) in groupedByName {
            let versions = Dictionary(grouping: nameCandidates, by: \.fingerprint)
                .map { fingerprint, members in
                    DuplicateGroup(canonicalName: name, fingerprint: fingerprint, candidates: members)
                }
                .sorted { $0.fingerprint < $1.fingerprint }
            duplicateGroups.append(contentsOf: versions.filter { $0.candidates.count > 1 })
            if versions.count > 1 {
                conflicts.append(ConflictGroup(canonicalName: name, versions: versions))
            }
        }

        return ScanResult(
            candidates: sorted,
            duplicateGroups: duplicateGroups.sorted { $0.canonicalName < $1.canonicalName },
            conflicts: conflicts.sorted { $0.canonicalName < $1.canonicalName },
            diagnostics: diagnostics
        )
    }

    private func discoverSkillRoots(in root: URL, deadline: Date) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        if fileManager.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return [root]
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var results: [URL] = []
        var visitedDirectories = 0
        for case let url as URL in enumerator {
            try checkBudget(deadline: deadline)
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            visitedDirectories += 1
            guard visitedDirectories <= limits.maximumVisitedDirectoriesPerRoot else {
                throw SkillScanError.budgetExceeded("目录数量超过上限")
            }
            guard relativeDepth(of: url, root: root) <= limits.maximumDepth else {
                enumerator.skipDescendants()
                continue
            }
            if fileManager.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
                results.append(url)
                guard results.count <= limits.maximumSkillsPerRoot else {
                    throw SkillScanError.budgetExceeded("Skill 数量超过上限")
                }
                enumerator.skipDescendants()
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private func validateSkillTree(_ root: URL, deadline: Date) throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        var fileCount = 0
        var aggregateBytes = 0
        for case let url as URL in enumerator {
            try checkBudget(deadline: deadline)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            let depth = relativeDepth(of: url, root: root)
            if values.isDirectory == true, depth > limits.maximumDepth {
                enumerator.skipDescendants()
                throw SkillScanError.budgetExceeded("目录层级超过上限")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            guard fileCount <= limits.maximumFilesPerSkill else {
                throw SkillScanError.budgetExceeded("文件数量超过上限")
            }
            let size = max(values.fileSize ?? 0, 0)
            guard size <= limits.maximumAggregateBytesPerSkill - aggregateBytes else {
                throw SkillScanError.budgetExceeded("文件总体积超过上限")
            }
            aggregateBytes += size
        }
    }

    private func checkBudget(deadline: Date) throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw SkillScanError.budgetExceeded("扫描时间超过上限") }
    }

    private func relativeDepth(of url: URL, root: URL) -> Int {
        let rootComponents = root.standardizedFileURL.pathComponents.count
        return max(0, url.standardizedFileURL.pathComponents.count - rootComponents)
    }
}
