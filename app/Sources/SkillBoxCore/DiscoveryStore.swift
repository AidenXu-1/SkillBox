import Foundation

public enum DiscoveryStoreError: LocalizedError {
    case invalidSessionFolder
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSessionFolder: "这条寻找记录的保存位置无效"
        case .unsupportedSchema: "这条寻找记录来自更新版本的 SkillBox，当前版本暂时无法读取"
        }
    }
}

public actor DiscoverySessionStore {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var session: DiscoverySession
    }

    public let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL, fileManager: FileManager = .default) throws {
        directory = root.appendingPathComponent("SearchSessions", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func makeSession(title: String, now: Date = Date()) -> DiscoverySession {
        let id = UUID()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let readable = Self.safeName(title)
        let folderName = "\(formatter.string(from: now))-\(readable)-\(id.uuidString.prefix(8).lowercased())"
        return DiscoverySession(id: id, title: title, storageFolderName: folderName, createdAt: now, updatedAt: now)
    }

    public func loadAll() -> [DiscoverySession] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.compactMap { folder in
            let file = folder.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file),
                  let envelope = try? decoder.decode(Envelope.self, from: data),
                  (1...3).contains(envelope.schemaVersion)
            else { return nil }
            var migrated = envelope.session
            var needsWrite = envelope.schemaVersion < 3
            if envelope.schemaVersion == 1, migrated.messages.isEmpty {
                migrated.messages = migrated.turns.map {
                    DiscoveryMessage(id: $0.id, role: .user, text: $0.userText, createdAt: $0.createdAt)
                }
            }
            if migrated.intent == nil, let goal = migrated.turns.last?.userText {
                migrated.intent = DiscoveryIntent(goal: goal)
            }
            let legacyAssistantPrefixes = [
                "AI 暂时不可用", "上次寻找在完成前中断", "公开 Skill 目录暂时"
            ]
            let removedLegacyMessages = migrated.messages.filter { message in
                message.role == .assistant && (
                    legacyAssistantPrefixes.contains { message.text.hasPrefix($0) }
                        || (envelope.schemaVersion < 3 && message.state != .complete)
                )
            }
            migrated.messages.removeAll { message in
                removedLegacyMessages.contains(where: { $0.id == message.id })
            }
            if !removedLegacyMessages.isEmpty {
                needsWrite = true
                if !migrated.notices.contains(where: { $0.text.contains("旧版本的本地错误提示") }) {
                    migrated.notices.append(.init(
                        text: "旧版本的本地错误提示已从 AI 对话中移出，原有候选结果仍保留。",
                        createdAt: migrated.updatedAt,
                        kind: .information
                    ))
                }
            }
            if needsWrite {
                let backup = folder.appendingPathComponent("session-v\(envelope.schemaVersion).json")
                if !fileManager.fileExists(atPath: backup.path) { try? data.write(to: backup, options: .atomic) }
                if let upgraded = try? encoder.encode(Envelope(schemaVersion: 3, session: migrated)) {
                    try? upgraded.write(to: file, options: .atomic)
                }
            }
            return migrated
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ session: DiscoverySession) throws {
        guard Self.isSafeFolderName(session.storageFolderName) else { throw DiscoveryStoreError.invalidSessionFolder }
        let folder = directory.appendingPathComponent(session.storageFolderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(session, to: folder.appendingPathComponent("session.json"))
    }

    /// Updates a running search without recreating a record the user deleted.
    /// Interactive fields are merged from the latest file so a network response
    /// cannot erase a newer selection or lazily generated guide.
    public func updateSearchSnapshot(_ incoming: DiscoverySession) throws -> DiscoverySession? {
        guard var current = storedSession(
            id: incoming.id,
            storageFolderName: incoming.storageFolderName
        ) else { return nil }
        var merged = incoming
        if let selected = current.selectedCandidateID,
           merged.candidates.contains(where: { $0.id == selected })
        {
            merged.selectedCandidateID = selected
        }
        let currentByID = Dictionary(current.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in merged.candidates.indices {
            guard let latest = currentByID[merged.candidates[index].id] else { continue }
            merged.candidates[index].state = latest.state
            let incomingSourceDigest = merged.candidates[index].evidence.skillDocumentExcerpt
                .map(SkillUsageGuideSourceIdentity.digest(markdown:))
            if merged.candidates[index].usageGuide == nil,
               latest.usageGuideSourceDigest != nil,
               latest.usageGuideSourceDigest == incomingSourceDigest
            {
                merged.candidates[index].usageGuide = latest.usageGuide
                merged.candidates[index].usageGuideSourceDigest = latest.usageGuideSourceDigest
            }
        }
        let currentRunsByID = Dictionary(current.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in merged.runs.indices {
            guard let latest = currentRunsByID[merged.runs[index].id] else { continue }
            for diagnostic in latest.diagnostics where !merged.runs[index].diagnostics.contains(diagnostic) {
                merged.runs[index].diagnostics.append(diagnostic)
            }
        }
        current = merged
        try writeExisting(current)
        return current
    }

    public func selectCandidate(
        sessionID: UUID,
        storageFolderName: String,
        candidateID: String
    ) throws -> DiscoverySession? {
        guard var session = storedSession(id: sessionID, storageFolderName: storageFolderName),
              session.candidates.contains(where: { $0.id == candidateID })
        else { return nil }
        session.selectedCandidateID = candidateID
        session.updatedAt = Date()
        try writeExisting(session)
        return session
    }

    public func saveUsageGuide(
        sessionID: UUID,
        storageFolderName: String,
        candidateID: String,
        guide: SkillUsageGuide,
        sourceDigest: String? = nil,
        diagnostics: [AIInvocationDiagnostic] = []
    ) throws -> DiscoverySession? {
        guard var session = storedSession(id: sessionID, storageFolderName: storageFolderName),
              let index = session.candidates.firstIndex(where: { $0.id == candidateID }),
              let sourceDigest,
              session.candidates[index].evidence.skillDocumentExcerpt
                .map(SkillUsageGuideSourceIdentity.digest(markdown:)) == sourceDigest
        else { return nil }
        if session.candidates[index].usageGuide == nil {
            session.candidates[index].usageGuide = guide
            session.candidates[index].usageGuideSourceDigest = sourceDigest
        }
        if !diagnostics.isEmpty, let runIndex = session.runs.indices.last {
            session.runs[runIndex].diagnostics.append(contentsOf: diagnostics)
        }
        session.updatedAt = Date()
        try writeExisting(session)
        return session
    }

    @discardableResult
    public func recoverInterruptedRuns(now: Date = Date()) throws -> Int {
        var recoveredCount = 0
        for var session in loadAll() {
            var interruptedRunIDs: [UUID] = []
            for index in session.runs.indices where session.runs[index].state.isActive {
                session.runs[index].state = .interrupted
                interruptedRunIDs.append(session.runs[index].id)
            }
            guard !interruptedRunIDs.isEmpty else { continue }
            recoveredCount += interruptedRunIDs.count
            for runID in interruptedRunIDs {
                session.notices.append(.init(
                    runID: runID,
                    text: "上次寻找意外中止，已有结果仍保留。可以继续寻找。",
                    createdAt: now,
                    kind: .recovery
                ))
            }
            session.updatedAt = now
            try save(session)
        }
        return recoveredCount
    }

    public func delete(_ session: DiscoverySession) throws {
        guard Self.isSafeFolderName(session.storageFolderName) else { throw DiscoveryStoreError.invalidSessionFolder }
        let folder = directory.appendingPathComponent(session.storageFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
    }

    public func deleteAll() throws {
        let sessions = loadAll()
        for session in sessions { try delete(session) }
    }

    public func storageSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func storedSession(id: UUID, storageFolderName: String) -> DiscoverySession? {
        guard Self.isSafeFolderName(storageFolderName) else { return nil }
        let file = directory
            .appendingPathComponent(storageFolderName, isDirectory: true)
            .appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              (1...3).contains(envelope.schemaVersion),
              envelope.session.id == id
        else { return nil }
        return envelope.session
    }

    private func writeExisting(_ session: DiscoverySession) throws {
        guard Self.isSafeFolderName(session.storageFolderName) else { throw DiscoveryStoreError.invalidSessionFolder }
        let file = directory
            .appendingPathComponent(session.storageFolderName, isDirectory: true)
            .appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: file.path) else { return }
        try write(session, to: file)
    }

    private func write(_ session: DiscoverySession, to file: URL) throws {
        let data = try encoder.encode(Envelope(schemaVersion: 3, session: session))
        try data.write(to: file, options: .atomic)
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let compact = String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String((compact.isEmpty ? "search" : compact).prefix(32))
    }

    private static func isSafeFolderName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains(":")
    }
}
