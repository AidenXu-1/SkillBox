import Foundation
import SkillBoxCore
import Testing
@testable import SkillBoxApp

@Suite("Skill organizer interactions")
struct SkillOrganizerInteractionTests {
    @Test("The upper and lower halves of a row expose precise named drop destinations")
    func rowHalvesResolveNamedDropDestinations() {
        let targetID = UUID()

        let above = SkillOrganizerDropPolicy.resolve(
            locationY: 12,
            rowHeight: 60,
            targetSkillID: targetID,
            targetName: "agent-team"
        )
        let below = SkillOrganizerDropPolicy.resolve(
            locationY: 48,
            rowHeight: 60,
            targetSkillID: targetID,
            targetName: "agent-team"
        )

        #expect(above == SkillOrganizerDropDestination(
            edge: .before,
            targetSkillID: targetID,
            accessibilityLabel: "放到 agent-team 上方"
        ))
        #expect(below == SkillOrganizerDropDestination(
            edge: .after,
            targetSkillID: targetID,
            accessibilityLabel: "放到 agent-team 下方"
        ))
    }

    @Test("Measured Skill rows define the live reorder area without relying on the outer scroll view size")
    func measuredRowsDefineTheReorderArea() {
        let frames = [
            CGRect(x: 8, y: 40, width: 320, height: 42),
            CGRect(x: 8, y: 87, width: 320, height: 42),
            CGRect(x: 8, y: 134, width: 320, height: 42),
        ]

        #expect(SkillOrganizerDropPolicy.reorderBounds(for: frames) == CGRect(
            x: 8,
            y: 40,
            width: 320,
            height: 136
        ))
        #expect(SkillOrganizerDropPolicy.contains(
            CGPoint(x: 239, y: 155),
            in: frames
        ))
        #expect(!SkillOrganizerDropPolicy.contains(
            CGPoint(x: 340, y: 155),
            in: frames
        ))
    }

    @Test("Dropping below a row resolves against the list after removing the dragged Skill")
    func belowDestinationSurvivesAdjacentReordering() {
        let first = UUID()
        let moving = UUID()
        let target = UUID()
        let last = UUID()
        let destination = SkillOrganizerDropDestination(
            edge: .after,
            targetSkillID: target,
            accessibilityLabel: "放到 target 下方"
        )

        let beforeSkillID = SkillOrganizerDropPolicy.beforeSkillID(
            for: destination,
            movingSkillID: moving,
            orderedSkillIDs: [first, moving, target, last]
        )

        #expect(beforeSkillID == last)
    }

    @Test("A Skill does not advertise itself as a valid drop destination")
    func selfDropDoesNotExposeAnInsertionMarker() {
        let skillID = UUID()

        let destination = SkillOrganizerDropPolicy.resolveValidDestination(
            locationY: 12,
            rowHeight: 60,
            movingSkillID: skillID,
            targetSkillID: skillID,
            targetName: "agent-team"
        )

        #expect(destination == nil)
    }

    @Test("Storage size counts only regular files inside the central Skill copy")
    func centralSkillStorageSizeCountsNestedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillBoxStorageMetrics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("references"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 7).write(to: root.appendingPathComponent("SKILL.md"))
        try Data(repeating: 2, count: 5).write(to: root.appendingPathComponent("references/guide.md"))

        #expect(try SkillStorageMetrics.byteCount(at: root) == 12)
    }

    @Test("Each supported source has a short consumer-facing label")
    func skillSourceLabelsStayShortAndExplicit() {
        #expect(SkillOrganizerRowPresentation.sourceLabel(for: .github) == "GitHub 来源")
        #expect(SkillOrganizerRowPresentation.sourceLabel(for: .localFolder) == "本地来源")
        #expect(SkillOrganizerRowPresentation.sourceLabel(for: .agentDirectory) == "应用导入")
    }

    @Test("Trailing source icons use recognizable GitHub and local folder metaphors")
    func skillSourcesExposeRecognizableTrailingIcons() {
        #expect(SkillOrganizerRowPresentation.sourceIcon(for: .github) == .githubMark)
        #expect(SkillOrganizerRowPresentation.sourceIcon(for: .localFolder) == .system(
            name: "folder.fill",
            tint: .blue
        ))
        #expect(SkillOrganizerRowPresentation.sourceIcon(for: .agentDirectory) == .system(
            name: "square.and.arrow.down.fill",
            tint: .secondary
        ))
    }

    @Test("Saved folders remain visible even when they contain no matching Skills")
    func savedEmptyFoldersRemainVisible() {
        let emptyFolder = SkillFolder(name: "操盘", sortIndex: 0)

        let visibleFolders = SkillOrganizerRowPresentation.visibleFolders(
            orderedFolders: [emptyFolder]
        )

        #expect(visibleFolders == [emptyFolder])
    }

    @Test("Completing a drag returns one move and clears every transient marker")
    func completingDragClearsTheSession() {
        let first = UUID()
        let movingID = UUID()
        let targetID = UUID()
        let last = UUID()
        let destination = SkillOrganizerDropDestination(
            edge: .before,
            targetSkillID: targetID,
            accessibilityLabel: "放到 target 上方"
        )
        var session = SkillOrganizerDragSession()

        session.begin(
            skillID: movingID,
            group: .uncategorized,
            orderedSkillIDs: [first, movingID, targetID, last],
            grabOffsetY: 14,
            pointerY: 80
        )
        session.update(destination: destination, pointerY: 120)

        #expect(session.previewOrder == [first, movingID, targetID, last])
        #expect(SkillOrganizerRowPresentation.showsInsertionLine(
            session: session,
            rowID: movingID
        ))
        #expect(SkillOrganizerRowPresentation.insertionLineY(
            session: session,
            movingRowFrame: CGRect(x: 12, y: 80, width: 320, height: 44)
        ) == 127)

        let intent = session.finish()

        #expect(intent == SkillOrganizerMoveIntent(
            movingSkillID: movingID,
            group: .uncategorized,
            beforeSkillID: targetID
        ))
        #expect(!session.isActive)
        #expect(session.movingSkillID == nil)
        #expect(session.destination == nil)
        #expect(session.previewOrder.isEmpty)
        #expect(SkillOrganizerRowPresentation.insertionLineY(
            session: session,
            movingRowFrame: CGRect(x: 12, y: 80, width: 320, height: 44)
        ) == nil)
    }

    @Test("A drag keeps row identity stable while neighbours open the target slot")
    func dragKeepsRowsStableWhileNeighboursOpenTheTargetSlot() {
        let movingID = UUID()
        let first = UUID()
        let target = UUID()
        let last = UUID()
        var session = SkillOrganizerDragSession()

        session.begin(
            skillID: movingID,
            group: .uncategorized,
            orderedSkillIDs: [movingID, first, target, last],
            grabOffsetY: 12,
            pointerY: 32
        )
        session.update(
            destination: SkillOrganizerDropDestination(
                edge: .before,
                targetSkillID: last,
                accessibilityLabel: "放到 last 上方"
            ),
            pointerY: 148
        )

        #expect(session.previewOrder == [first, target, movingID, last])
        #expect(SkillOrganizerRowPresentation.stableListOrder(
            session: session,
            fallback: session.previewOrder
        ) == [movingID, first, target, last])
        #expect(SkillOrganizerRowPresentation.previewSlotOffset(
            session: session,
            rowID: first
        ) == -1)
        #expect(SkillOrganizerRowPresentation.previewSlotOffset(
            session: session,
            rowID: target
        ) == -1)
        #expect(SkillOrganizerRowPresentation.previewSlotOffset(
            session: session,
            rowID: movingID
        ) == 0)
        #expect(SkillOrganizerRowPresentation.previewSlotOffset(
            session: session,
            rowID: last
        ) == 0)
        #expect(SkillOrganizerRowPresentation.insertionSlotID(session: session) == target)
        #expect(SkillOrganizerRowPresentation.disposition(
            session: session,
            rowID: movingID
        ) == .placeholder)
        #expect(SkillOrganizerRowPresentation.disposition(
            session: session,
            rowID: target
        ) == .card)
        #expect(SkillOrganizerRowPresentation.floatingSkillID(session: session) == movingID)
    }

    @Test("Cancelling a drag restores idle state without producing a move")
    func cancellingDragClearsTheSession() {
        let movingID = UUID()
        let targetID = UUID()
        var session = SkillOrganizerDragSession()
        session.begin(
            skillID: movingID,
            group: .folder(UUID()),
            orderedSkillIDs: [movingID, targetID],
            grabOffsetY: 10,
            pointerY: 40
        )
        session.update(
            destination: SkillOrganizerDropDestination(
                edge: .after,
                targetSkillID: targetID,
                accessibilityLabel: "放到 target 下方"
            ),
            pointerY: 90
        )

        session.cancel()

        #expect(!session.isActive)
        #expect(session.finish() == nil)
        #expect(session.destination == nil)
        #expect(session.previewOrder.isEmpty)
    }
}
