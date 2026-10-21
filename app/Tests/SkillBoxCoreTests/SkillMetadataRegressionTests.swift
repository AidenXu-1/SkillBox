import Foundation
import Testing
@testable import SkillBoxCore

@Suite("Skill identity keeps top-level metadata")
struct SkillMetadataRegressionTests {
    @Test("Nested package fields never replace Skill identity", arguments: [false, true])
    func nestedMetadataIsSeparate(metadataFirst: Bool) {
        let fields = "name: valid-skill\ndescription: The real Skill description"
        let metadata = "metadata:\n  name: internal-label\n  description: An internal package label"
        let text = "---\n" + (metadataFirst ? metadata + "\n" + fields : fields + "\n" + metadata) + "\n---\n# Instructions"
        let parsed = SkillMetadataParser.parse(text: text, fallbackName: "valid-skill")
        #expect(parsed.name == "valid-skill")
        #expect(parsed.description == "The real Skill description")
    }

    @Test("Indented root fields and folded descriptions keep their meaning")
    func indentedRootAndFoldedDescription() {
        let parsed = SkillMetadataParser.parse(text: "---\n  name: valid-skill\n  metadata:\n    name: internal-label\n    description: wrong\n  description: >-\n    First line\n    second line\n---\n", fallbackName: "valid-skill")
        #expect(parsed.name == "valid-skill")
        #expect(parsed.description == "First line second line")
    }

    @Test("Import uses the real Skill identity and leaves source bytes unchanged")
    func importedIdentityAndSourceArePreserved() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SkillBoxMetadataRegression-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("valid-skill")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let text = "---\nname: valid-skill\ndescription: The real Skill description\nmetadata:\n  name: internal-label\n  description: Internal label\n---\n# Safe instructions\n"
        let file = source.appendingPathComponent("SKILL.md")
        try Data(text.utf8).write(to: file)
        let candidate = try #require(try await LocalFolderSourceProvider().preview(locator: source.path).first)
        #expect(candidate.canonicalName == "valid-skill")
        #expect(candidate.description == "The real Skill description")
        let store = try LibraryStore(root: root.appendingPathComponent("store"))
        let record = try await store.importCandidate(candidate)
        #expect(record.canonicalName == "valid-skill")
        #expect(try Data(contentsOf: file) == Data(text.utf8))
        #expect(try Data(contentsOf: await store.contentURL(for: record).appendingPathComponent("SKILL.md")) == Data(text.utf8))
    }
}
