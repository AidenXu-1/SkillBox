import Foundation
import Testing
@testable import SkillBoxApp

@Suite("Organizer cross-folder drag layout")
struct OrganizerDragLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), f = UUID(), g = UUID()
    var rows: [OrganizerRowGeometry] {
        [
            .init(key: .uncategorized, frame: CGRect(x: 8, y: 8, width: 300, height: 32)),
            .init(key: .skill(a), frame: CGRect(x: 8, y: 45, width: 300, height: 44)),
            .init(key: .folder(f), folderID: f, frame: CGRect(x: 8, y: 94, width: 300, height: 32)),
            .init(key: .skill(b), folderID: f, frame: CGRect(x: 8, y: 131, width: 300, height: 44)),
            .init(key: .skill(c), folderID: f, frame: CGRect(x: 8, y: 180, width: 300, height: 44)),
            .init(key: .folder(g), folderID: g, frame: CGRect(x: 8, y: 229, width: 300, height: 32)),
        ]
    }
    func land(_ item: OrganizerRowKey, _ y: CGFloat, rows: [OrganizerRowGeometry]? = nil) -> OrganizerLanding? {
        OrganizerDragLayout.landing(moving: item, pointer: CGPoint(x: 100, y: y), viewport: CGSize(width: 316, height: 400), rows: rows ?? self.rows)
    }
    @Test("Folder titles accept Skills, including empty folders and uncategorized")
    func folderTitlesAcceptSkills() {
        #expect(land(.skill(a), 108) == .init(anchor: .folder(f), edge: .inside, folderID: f, beforeID: nil))
        #expect(land(.skill(a), 245) == .init(anchor: .folder(g), edge: .inside, folderID: g, beforeID: nil))
        #expect(land(.skill(b), 20) == .init(anchor: .uncategorized, edge: .inside, folderID: nil, beforeID: nil))
    }
    @Test("Cross-folder sorting resolves the exact destination and next sibling")
    func crossFolderSortKeepsDestination() {
        #expect(land(.skill(a), 140) == .init(anchor: .skill(b), edge: .before, folderID: f, beforeID: b))
        #expect(land(.skill(a), 169) == .init(anchor: .skill(b), edge: .after, folderID: f, beforeID: c))
        #expect(land(.skill(a), 213) == .init(anchor: .skill(c), edge: .after, folderID: f, beforeID: nil))
    }
    @Test("The insertion preview shifts every intervening row by the moved height")
    func crossGroupRowsYieldTogether() {
        let order = OrganizerDragLayout.previewOrder(moving: .skill(a), landing: land(.skill(a), 169), rows: rows)
        #expect(order == [.uncategorized, .folder(f), .skill(b), .skill(a), .skill(c), .folder(g)])
        let offsets = OrganizerDragLayout.offsets(order: order, rows: rows, spacing: 5)
        #expect(offsets[.folder(f)] == -49)
        #expect(offsets[.skill(b)] == -49)
        #expect(offsets[.skill(c)] == 0)
        #expect(offsets[.skill(a)] == 86)
    }
    @Test("Appending a Skill stays before the next folder")
    func appendDoesNotLeakIntoNextFolder() {
        let order = OrganizerDragLayout.previewOrder(moving: .skill(a), landing: land(.skill(a), 213), rows: rows)
        #expect(order == [.uncategorized, .folder(f), .skill(b), .skill(c), .skill(a), .folder(g)])
    }
    @Test("Folders have both before and after destinations including the last position")
    func folderSortingIncludesLastPosition() {
        #expect(land(.folder(g), 99) == .init(anchor: .folder(f), edge: .before, folderID: nil, beforeID: f))
        let destination = land(.folder(f), 255)
        #expect(destination == .init(anchor: .folder(g), edge: .after, folderID: nil, beforeID: nil))
        let collapsed = rows.filter { $0.key != .skill(b) && $0.key != .skill(c) }
        #expect(OrganizerDragLayout.previewOrder(moving: .folder(f), landing: destination, rows: collapsed).last == .folder(f))
        #expect(land(.folder(f), 20) == nil)
    }
    @Test("Viewport-relative geometry keeps the same drop after scrolling")
    func scrollDoesNotChangeDestinationIdentity() {
        let scrolled = rows.map { row in
            var changed = row; changed.frame.origin.y -= 100; return changed
        }
        #expect(land(.skill(a), 69, rows: scrolled) == land(.skill(a), 169))
    }
    @Test("Outside and self drops do not mutate the preview")
    func invalidDropsRestoreOriginalOrder() {
        #expect(land(.skill(a), 60) == nil)
        #expect(OrganizerDragLayout.landing(moving: .skill(a), pointer: CGPoint(x: -10, y: 160), viewport: CGSize(width: 316, height: 400), rows: rows) == nil)
        #expect(OrganizerDragLayout.previewOrder(moving: .skill(a), landing: nil, rows: rows) == rows.map(\.key))
    }
    @Test("Edge scrolling is gradual and stops outside the list")
    func edgeScrollingStopsOutside() {
        let viewport = CGSize(width: 316, height: 400)
        #expect(OrganizerDragLayout.scrollStep(pointer: CGPoint(x: 100, y: 200), viewport: viewport) == 0)
        #expect(OrganizerDragLayout.scrollStep(pointer: CGPoint(x: 100, y: 24), viewport: viewport) == -6)
        #expect(OrganizerDragLayout.scrollStep(pointer: CGPoint(x: 100, y: 376), viewport: viewport) == 6)
        #expect(OrganizerDragLayout.scrollStep(pointer: CGPoint(x: -1, y: 396), viewport: viewport) == 0)
        #expect(OrganizerDragLayout.scrollStep(pointer: CGPoint(x: 100, y: 410), viewport: viewport) == 0)
    }
}
