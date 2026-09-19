import Foundation

/// UTF-16 ranges match NSTextStorage, including Chinese and composed emoji.
public struct MarkdownLineDiff: Sendable {
    public let removed: [NSRange]
    public let added: [NSRange]
    public let usesChangedRegion: Bool

    public init(before: String, after: String) {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        let oldMiddle = Array(old[prefix..<oldEnd]), newMiddle = Array(new[prefix..<newEnd])
        var deleted = Set<Int>(), inserted = Set<Int>()
        // Bound worst-case quadratic work. Preserve full original text in either mode.
        usesChangedRegion = Double(oldMiddle.count) * Double(newMiddle.count) > 4_000_000
        if usesChangedRegion {
            deleted.formUnion(prefix..<oldEnd)
            inserted.formUnion(prefix..<newEnd)
        } else {
            for change in newMiddle.difference(from: oldMiddle) {
                switch change {
                case let .remove(offset, _, _): deleted.insert(prefix + offset)
                case let .insert(offset, _, _): inserted.insert(prefix + offset)
                }
            }
        }
        func ranges(_ lines: [String], _ indices: Set<Int>) -> [NSRange] {
            var offset = 0
            return lines.enumerated().compactMap { index, line in
                let length = line.utf16.count
                defer { offset += length + 1 }
                return indices.contains(index) && length > 0 ? NSRange(location: offset, length: length) : nil
            }
        }
        removed = ranges(old, deleted)
        added = ranges(new, inserted)
    }
}
