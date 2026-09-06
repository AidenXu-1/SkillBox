import Foundation
import SkillBoxCore

@main
enum SkillBoxDiagnostics {
    static func main() async {
        guard CommandLine.arguments.contains("--read-only-scan") else {
            FileHandle.standardError.write(Data("Usage: SkillBoxDiagnostics --read-only-scan\n".utf8))
            Foundation.exit(64)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let builtin = BuiltinAgentAdapters.all.map { $0.makeTarget(homeDirectory: home, fileManager: .default) }
        let sourceNames = Dictionary(uniqueKeysWithValues: builtin.map { ($0.path, $0.displayName) })
        var seen = Set<String>()
        let roots = builtin.map { URL(fileURLWithPath: $0.path) }.filter {
            FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted
        }
        let result = await FileSystemSkillScanner().scan(roots: roots, sourceName: { sourceNames[$0.path] ?? "Agent Skill 目录" })
        let report: [String: Any] = [
            "mode": "read-only",
            "roots": roots.map(\.path),
            "candidates": result.candidates.count,
            "duplicateGroups": result.duplicateGroups.count,
            "conflicts": result.conflicts.count,
            "diagnostics": result.diagnostics,
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
