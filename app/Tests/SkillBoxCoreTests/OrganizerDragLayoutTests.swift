import Foundation
import Testing
@testable import SkillBoxApp

@Suite("Organizer cross-folder drag layout")
struct OrganizerDragLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), f = UUID(), g = UUID()
    var rows: [OrganizerRowGeometry] {
        [
            .init(key: .folder(f), folderID: f, frame: CGRect(x: 8, y: 8, width: 300, height: 32)),
            .init(key: .skill(b), folderID: f, frame: CGRect(x: 8, y: 45, width: 300, height: 44)),
            .init(key: .skill(c), folderID: f, frame: CGRect(x: 8, y: 94, width: 300, height: 44)),
            .init(key: .folder(g), folderID: g, frame: CGRect(x: 8, y: 143, width: 300, height: 32)),
            .init(key: .uncategorized, frame: CGRect(x: 8, y: 180, width: 300, height: 32)),
            .init(key: .skill(a), frame: CGRect(x: 8, y: 217, width: 300, height: 44)),
        ]
    }

    func land(_ item: OrganizerRowKey, _ y: CGFloat, rows: [OrganizerRowGeometry]? = nil) -> OrganizerLanding? {
        OrganizerDragLayout.landing(moving: item, pointer: CGPoint(x: 100, y: y), viewport: CGSize(width: 316, height: 400), rows: rows ?? self.rows)
    }
    @Test("Folder titles accept Skills, including empty folders and uncategorized")
    func folderTitlesAcceptSkills() {
        #expect(land(.skill(a), 20) == .init(anchor: .folder(f), edge: .inside, folderID: f, beforeID: nil))
        #expect(land(.skill(a), 160) == .init(anchor: .folder(g), edge: .inside, folderID: g, beforeID: nil))
        #expect(land(.skill(b), 196) == .init(anchor: .uncategorized, edge: .inside, folderID: nil, beforeID: nil))
    }
    @Test("Cross-folder sorting resolves the exact destination and next sibling")
    func crossFolderSortKeepsDestination() {
        #expect(land(.skill(a), 55) == .init(anchor: .skill(b), edge: .before, folderID: f, beforeID: b))
        #expect(land(.skill(a), 80) == .init(anchor: .skill(b), edge: .after, folderID: f, beforeID: c))
        #expect(land(.skill(a), 130) == .init(anchor: .skill(c), edge: .after, folderID: f, beforeID: nil))
    }
    @Test("The insertion preview shifts every intervening row by the moved height")
    func crossGroupRowsYieldTogether() {
        let order = OrganizerDragLayout.previewOrder(moving: .skill(a), landing: land(.skill(a), 80), rows: rows)
        #expect(order == [.folder(f), .skill(b), .skill(a), .skill(c), .folder(g), .uncategorized])
        let offsets = OrganizerDragLayout.offsets(order: order, rows: rows, spacing: 5)
        #expect(offsets[.folder(f)] == 0)
        #expect(offsets[.skill(b)] == 0)
        #expect(offsets[.skill(c)] == 49)
        #expect(offsets[.skill(a)] == -123)
    }
    @Test("Appending a Skill stays before the next folder")
    func appendDoesNotLeakIntoNextFolder() {
        let order = OrganizerDragLayout.previewOrder(moving: .skill(a), landing: land(.skill(a), 130), rows: rows)
        #expect(order == [.folder(f), .skill(b), .skill(c), .skill(a), .folder(g), .uncategorized])
    }
    @Test("Folders have both before and after destinations including the last position")
    func folderSortingIncludesLastPosition() {
        #expect(land(.folder(g), 15) == .init(anchor: .folder(f), edge: .before, folderID: nil, beforeID: f))
        let destination = land(.folder(f), 170)
        #expect(destination == .init(anchor: .folder(g), edge: .after, folderID: nil, beforeID: nil))
        let collapsed = rows.filter { $0.key != .skill(b) && $0.key != .skill(c) }
        #expect(OrganizerDragLayout.previewOrder(moving: .folder(f), landing: destination, rows: collapsed) == [.folder(g), .folder(f), .uncategorized, .skill(a)])
        #expect(land(.folder(f), 20) == nil)
    }
    @Test("The last folder append preview stays above uncategorized Skills")
    func lastFolderAppendKeepsUncategorizedBelow() {
        let lastFolderRows = rows.filter { $0.key != .folder(g) }
        let destination = land(.skill(a), 130, rows: lastFolderRows)
        #expect(OrganizerDragLayout.previewOrder(moving: .skill(a), landing: destination, rows: lastFolderRows)
            == [.folder(f), .skill(b), .skill(c), .skill(a), .uncategorized])
    }
    @Test("A drop in the bottom section keeps folders above ungrouped Skills")
    func folderDropBelowGroupsClampsToLastFolder() {
        let destination = land(.folder(f), 245)
        #expect(destination == .init(anchor: .folder(g), edge: .after, folderID: nil, beforeID: nil))
        let collapsed = rows.filter { $0.key != .skill(b) && $0.key != .skill(c) }
        #expect(OrganizerDragLayout.previewOrder(moving: .folder(f), landing: destination, rows: collapsed)
            == [.folder(g), .folder(f), .uncategorized, .skill(a)])
        #expect(land(.skill(b), 230)?.folderID == nil)
        #expect(land(.skill(b), 230)?.beforeID == a)
    }
    @Test("Viewport-relative geometry keeps the same drop after scrolling")
    func scrollDoesNotChangeDestinationIdentity() {
        let scrolled = rows.map { row in
            var changed = row; changed.frame.origin.y -= 40; return changed
        }
        #expect(land(.skill(a), 40, rows: scrolled) == land(.skill(a), 80))
    }
    @Test("Outside and self drops do not mutate the preview")
    func invalidDropsRestoreOriginalOrder() {
        #expect(land(.skill(a), 230) == nil)
        #expect(OrganizerDragLayout.landing(moving: .skill(a), pointer: CGPoint(x: -10, y: 160), viewport: CGSize(width: 316, height: 400), rows: rows) == nil)
        #expect(OrganizerDragLayout.previewOrder(moving: .skill(a), landing: nil, rows: rows) == rows.map(\.key))
    }
    @Test("Displayed header geometry keeps the whole title a drop target and resets the bottom group")
    func displayedGeometryPreservesGroupBoundaries() {
        let keys: [OrganizerRowKey] = [.folder(f), .skill(b), .folder(g), .uncategorized, .skill(a)]
        let geometry = OrganizerDragLayout.geometry(keys: keys, offset: 0, width: 316, spacing: 5)
        let folder = geometry[0].frame
        #expect(land(.skill(a), folder.maxY - 1, rows: geometry)?.folderID == f)
        let last = geometry.last!
        #expect(land(.skill(b), last.frame.midY - 1, rows: geometry)?.folderID == nil)
        #expect(land(.skill(b), last.frame.midY - 1, rows: geometry)?.beforeID == a)
        let scrolled = OrganizerDragLayout.geometry(keys: keys, offset: 50, width: 316, spacing: 5)
        #expect(land(.skill(b), last.frame.midY - 51, rows: scrolled)
            == land(.skill(b), last.frame.midY - 1, rows: geometry))
        let end = land(.folder(f), last.frame.midY, rows: geometry)
        let collapsed = OrganizerDragLayout.geometry(keys: keys.filter { $0 != .skill(b) }, offset: 0, width: 316, spacing: 5)
        #expect(OrganizerDragLayout.previewOrder(moving: .folder(f), landing: end, rows: collapsed)
            == [.folder(g), .folder(f), .uncategorized, .skill(a)])
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
