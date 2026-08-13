import Foundation

public protocol SkillScanner: Sendable {
    func scan(roots: [URL], sourceName: @Sendable (URL) -> String) async -> ScanResult
}

public struct FileSystemSkillScanner: SkillScanner, Sendable {
    private let fingerprinter: any SkillFingerprinting
    private let riskAnalyzer: any RiskAnalyzer

    public init(
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter(),
        riskAnalyzer: any RiskAnalyzer = StaticRiskAnalyzer()
    ) {
        self.fingerprinter = fingerprinter
        self.riskAnalyzer = riskAnalyzer
    }

    public func scan(roots: [URL], sourceName: @Sendable (URL) -> String) async -> ScanResult {
        var candidates: [SkillCandidate] = []
        var diagnostics: [String] = []

        for root in roots {
            do {
                let discovered = try discoverSkillRoots(in: root)
                for skillURL in discovered {
                    do {
                        let skillFile = skillURL.appendingPathComponent("SKILL.md")
                        let text = try String(contentsOf: skillFile, encoding: .utf8)
                        let metadata = SkillMetadataParser.parse(text: text, fallbackName: skillURL.lastPathComponent)
                        let fingerprint = try fingerprinter.fingerprint(directory: skillURL)
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
                    } catch {
                        diagnostics.append("\(skillURL.path)：\(error.localizedDescription)")
                    }
                }
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

    private func discoverSkillRoots(in root: URL) throws -> [URL] {
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
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if fileManager.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
                results.append(url)
                enumerator.skipDescendants()
            }
        }
        return results.sorted { $0.path < $1.path }
    }
}
