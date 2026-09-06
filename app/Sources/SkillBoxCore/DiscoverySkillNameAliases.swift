import Foundation

/// This local index supplies a location to check, never proof that a remote Skill
/// still exists. The normal exact provider must verify the document on every lookup.
enum DiscoverySkillNameAliases {
    static let bundled = targets(entries: TrustedSkillCatalogDiscoveryProvider.bundledEntries())

    static func targets(entries: [TrustedSkillCatalogEntry]) -> [String: DiscoveryTarget] {
        var matches: [String: Set<DiscoveryTarget>] = [:]
        for entry in entries {
            guard let source = entry.nameAliasSource,
                  source.scheme == "https", source.host?.lowercased() == "github.com",
                  source.user == nil, source.password == nil,
                  entry.repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  source.path.lowercased().hasPrefix("/\(entry.repository.lowercased())/blob/"),
                  source.path.hasSuffix("/\(entry.path)"),
                  !entry.path.split(separator: "/").contains(".."),
                  DiscoverySkillDocumentParser.nameMatchesPath(entry.name, path: entry.path)
            else { continue }
            let target = DiscoveryTarget(kind: .repository, value: entry.name,
                repositoryFullName: entry.repository, skillPath: entry.path, revision: entry.revision)
            for alias in (entry.nameAliases ?? []).prefix(12) {
                let name = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard (3...64).contains(name.count) else { continue }
                matches[name, default: []].insert(target)
            }
        }
        // Conflicting aliases cannot silently select a different author's work.
        return matches.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
