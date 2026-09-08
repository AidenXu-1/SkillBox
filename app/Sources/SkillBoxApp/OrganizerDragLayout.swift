import Foundation

// Geometry stays in the scroll viewport's coordinate space. Visual offsets never
// change these hit-test frames, preventing rows from oscillating under the pointer.
enum OrganizerRowKey: Hashable, Sendable {
    case uncategorized
    case folder(UUID)
    case skill(UUID)
}

struct OrganizerRowGeometry: Equatable, Sendable {
    var key: OrganizerRowKey
    var folderID: UUID?
    var frame: CGRect
}

struct OrganizerLanding: Equatable, Sendable {
    enum Edge: Equatable, Sendable { case before, after, inside }
    var anchor: OrganizerRowKey
    var edge: Edge
    var folderID: UUID?
    var beforeID: UUID?
}

enum OrganizerDragLayout {
    static func landing(
        moving: OrganizerRowKey, pointer: CGPoint, viewport: CGSize,
        rows: [OrganizerRowGeometry]
    ) -> OrganizerLanding? {
        guard pointer.x >= 0, pointer.x <= viewport.width,
              pointer.y >= 0, pointer.y <= viewport.height,
              !rows.isEmpty else { return nil }
        let ordered = rows.sorted { $0.frame.minY < $1.frame.minY }
        if case .folder = moving {
            let folders = ordered.filter { if case .folder = $0.key { true } else { false } }
            guard let first = folders.first, pointer.y >= first.frame.minY - 3 else { return nil }
            let hit = folders.last(where: { $0.frame.minY <= pointer.y + 3 }) ?? first
            guard hit.key != moving, case let .folder(id) = hit.key else { return nil }
            let before = pointer.y < hit.frame.midY
            let remaining = folders.filter { $0.key != moving }
            let next = remaining.drop(while: { $0.key != hit.key }).dropFirst().first
            let nextID: UUID? = if case let .folder(id)? = next?.key { id } else { nil }
            return .init(anchor: hit.key, edge: before ? .before : .after, folderID: nil, beforeID: before ? id : nextID)
        }
        guard case let .skill(movingID) = moving else { return nil }
        let hit = ordered.first(where: { pointer.y <= $0.frame.maxY + 3 }) ?? ordered.last!
        guard hit.key != moving else { return nil }
        switch hit.key {
        case .uncategorized:
            return .init(anchor: hit.key, edge: .inside, folderID: nil, beforeID: nil)
        case let .folder(id):
            return .init(anchor: hit.key, edge: .inside, folderID: id, beforeID: nil)
        case let .skill(id):
            let before = pointer.y < hit.frame.midY
            let siblings = ordered.filter { $0.folderID == hit.folderID && $0.key != .skill(movingID) }
                .compactMap { row -> UUID? in if case let .skill(id) = row.key { id } else { nil } }
            let index = siblings.firstIndex(of: id)!
            let nextID = index + 1 < siblings.count ? siblings[index + 1] : nil
            return .init(anchor: hit.key, edge: before ? .before : .after, folderID: hit.folderID, beforeID: before ? id : nextID)
        }
    }

    static func previewOrder(moving: OrganizerRowKey, landing: OrganizerLanding?, rows: [OrganizerRowGeometry]) -> [OrganizerRowKey] {
        let original = rows.map(\.key)
        guard let landing, landing.edge != .inside, original.contains(moving) else { return original }
        var order = original.filter { $0 != moving }
        let beforeKey: OrganizerRowKey?
        switch moving {
        case .folder:
            beforeKey = landing.beforeID.map(OrganizerRowKey.folder)
        case .skill:
            if let beforeID = landing.beforeID { beforeKey = .skill(beforeID) }
            else {
                // End of this group, immediately before the following folder.
                let anchorIndex = order.firstIndex(of: landing.anchor) ?? order.endIndex
                beforeKey = order.dropFirst(min(anchorIndex + 1, order.count)).first {
                    if case .folder = $0 { true } else { false }
                }
            }
        case .uncategorized: return original
        }
        let insertion = beforeKey.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(moving, at: insertion)
        return order
    }

    static func offsets(order: [OrganizerRowKey], rows: [OrganizerRowGeometry], spacing: CGFloat) -> [OrganizerRowKey: CGFloat] {
        let frames = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.frame) })
        var y = rows.first?.frame.minY ?? 0
        var result: [OrganizerRowKey: CGFloat] = [:]
        for key in order {
            guard let frame = frames[key] else { continue }
            result[key] = y - frame.minY
            y += frame.height + spacing
        }
        return result
    }

    static func scrollStep(pointer: CGPoint, viewport: CGSize) -> CGFloat {
        guard pointer.x >= 0, pointer.x <= viewport.width, pointer.y >= 0, pointer.y <= viewport.height else { return 0 }
        let edge: CGFloat = 48
        if pointer.y < edge { return -12 * (1 - pointer.y / edge) }
        if pointer.y > viewport.height - edge { return 12 * (1 - (viewport.height - pointer.y) / edge) }
        return 0
    }
}

struct OrganizerScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGSize = .zero
    var contentHeight: CGFloat = 0
}
