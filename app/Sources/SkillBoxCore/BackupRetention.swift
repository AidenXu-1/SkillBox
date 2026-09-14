import Foundation

/// One previous copy per saved Skill / installation destination, for seven days.
/// Current content and the user's Trash are never part of this plan.
public struct BackupRetentionPlan: Sendable {
    public var removablePaths: Set<String>
    public var retainedPaths: Set<String>
    public var expiredTransactionIDs: Set<UUID>
}

public enum BackupRetentionPolicy {
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public static func plan(snapshot: LibrarySnapshot, root: URL, now: Date = Date()) -> BackupRetentionPlan {
        var keep = Set<String>()
        var known = Set<String>()
        var expired = Set<UUID>()
        var claimed = Set<String>()
        let contentPaths = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0.contentRelativePath) })
        let ordered = snapshot.transactions.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        // Rescue payloads are protected in addition to the latest successful
        // operation. They must not consume its ordinary rollback slot.
        for transaction in ordered where transaction.status == .running || transaction.status == .failed {
            for item in items(transaction, root: root, contentPaths: contentPaths) {
                if let path = item.path { keep.insert(path) }
            }
        }
        for transaction in ordered {
            let entries = items(transaction, root: root, contentPaths: contentPaths)
            known.formUnion(entries.compactMap(\.path))
            guard transaction.status != .running, transaction.status != .failed else { continue }
            let isUndoable = transaction.status == .succeeded || transaction.status == .undoBlocked
            let inTime = now.timeIntervalSince(transaction.createdAt) < lifetime
            var complete = isUndoable && inTime
            for item in entries {
                let latest = isUndoable && claimed.insert(item.key).inserted
                if latest && inTime {
                    if let path = item.path { keep.insert(path) }
                } else {
                    complete = false
                }
            }
            if !entries.isEmpty && !complete { expired.insert(transaction.id) }
        }
        return .init(removablePaths: known.subtracting(keep), retainedPaths: keep, expiredTransactionIDs: expired)
    }

    private static func items(_ transaction: SyncTransaction, root: URL, contentPaths: [UUID: String]) -> [(key: String, path: String?)] {
        // Deletion/restoration journals belong to the separate Trash recovery flow.
        guard transaction.libraryDeletion == nil, transaction.libraryRestoration == nil else { return [] }
        var result: [(key: String, path: String?)] = []
        if let update = transaction.libraryUpdate {
            let fingerprint = update.previousRecord.fingerprint
            let content = root.appendingPathComponent(contentPaths[update.previousRecord.id] ?? update.previousRecord.contentRelativePath).standardizedFileURL
            let library = root.appendingPathComponent("Library").standardizedFileURL
            if content.path.hasPrefix(library.path + "/"), content.lastPathComponent == "content",
               fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) {
                let path = content.deletingLastPathComponent().appendingPathComponent("versions/\(fingerprint)").path
                result.append(("library:\(update.previousRecord.id)", path))
            }
        }
        for backup in transaction.backups {
            var path: String?
            if let relative = backup.backupRelativePath {
                let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "backups", !parts[1].isEmpty,
                      parts[1] != ".", parts[1] != ".." else { continue }
                path = root.appendingPathComponent("Transactions/\(transaction.id.uuidString)/\(relative)").path
            }
            result.append(("destination:\(URL(fileURLWithPath: backup.destinationPath).standardizedFileURL.path)", path))
        }
        return result
    }
}
