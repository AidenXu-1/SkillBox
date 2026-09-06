import Foundation

public enum DiscoveryStoreError: LocalizedError {
    case invalidSessionFolder
    case unsupportedSchema(Int)
    case storageLimitReached(Int64)
    case queueFull

    public var errorDescription: String? {
        switch self {
        case .invalidSessionFolder: "这条寻找记录的保存位置无效"
        case .unsupportedSchema: "这条寻找记录来自更新版本的 SkillBox，当前版本暂时无法读取"
        case .queueFull: "待处理补充最多 4 条、合计 1,800 字。请等这轮完成后再发送；输入内容已保留。"
        case let .storageLimitReached(maximumBytes):
            "寻找记录已达到 \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) 的保存上限。请先在设置中删除不再需要的记录。"
        }
    }
}

public enum DiscoveryStorageLimits {
    public static let maximumTotalBytes: Int64 = 64 * 1_024 * 1_024
    public static let maximumDetailedCandidates = 96
    public static let maximumDetailedExcerptCharacters = 8_000
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
    private let storageLimitBytes: Int64

    public init(
        root: URL,
        fileManager: FileManager = .default,
        storageLimitBytes: Int64 = DiscoveryStorageLimits.maximumTotalBytes
    ) throws {
        directory = root.appendingPathComponent("SearchSessions", isDirectory: true)
        self.fileManager = fileManager
        self.storageLimitBytes = max(1, storageLimitBytes)
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
                  (1...4).contains(envelope.schemaVersion)
            else { return nil }
            var migrated = envelope.session
            var needsWrite = envelope.schemaVersion < 4
            if envelope.schemaVersion == 1, migrated.messages.isEmpty {
                migrated.messages = migrated.turns.map {
                    DiscoveryMessage(id: $0.id, role: .user, text: $0.userText, createdAt: $0.createdAt)
                }
            }
            if migrated.intent == nil, let goal = migrated.turns.last?.userText {
                migrated.intent = DiscoveryIntent(goal: goal)
            }
            // Earlier releases did not record whether assistant text was created
            // before or after untrusted candidate documents were read. Preserve
            // only the user's own words; the old assistant text cannot be safely
            // distinguished after the fact.
            let removedLegacyMessages = migrated.messages.filter {
                $0.role == .assistant && !["conversation-local-v1", "conversation-evidence-v1"].contains($0.origin ?? "")
            }
            migrated.messages.removeAll { message in
                removedLegacyMessages.contains(where: { $0.id == message.id })
            }
            if !removedLegacyMessages.isEmpty {
                needsWrite = true
                if !migrated.notices.contains(where: { $0.text.contains("旧版本的 AI 回复") }) {
                    migrated.notices.append(.init(
                        text: "旧版本的 AI 回复无法确认是否受候选正文影响，已从寻找记录中移除；用户原话和候选证据仍保留。",
                        createdAt: migrated.updatedAt,
                        kind: .information
                    ))
                }
            }
            var removedCandidateAIText = false
            for index in migrated.candidates.indices {
                let candidate = migrated.candidates[index]
                let hadCandidateConditionedText = candidate.recommendationReason != nil
                    || candidate.suitableWhen != nil
                    || candidate.examplePrompt != nil
                    || !candidate.experienceSteps.isEmpty
                    || !candidate.limitations.isEmpty
                    || candidate.usageGuide?.origin == .aiAssisted
                guard hadCandidateConditionedText else { continue }
                migrated.candidates[index].recommendationReason = nil
                migrated.candidates[index].suitableWhen = nil
                migrated.candidates[index].examplePrompt = nil
                migrated.candidates[index].experienceSteps = []
                migrated.candidates[index].limitations = []
                if migrated.candidates[index].usageGuide?.origin == .aiAssisted {
                    migrated.candidates[index].usageGuide = nil
                    migrated.candidates[index].usageGuideSourceDigest = nil
                }
                removedCandidateAIText = true
            }
            if removedCandidateAIText {
                needsWrite = true
                if !migrated.notices.contains(where: { $0.text.contains("旧版本候选详情中的 AI 说明") }) {
                    migrated.notices.append(.init(
                        text: "旧版本候选详情中的 AI 说明已移除，当前只显示可核对的作者资料。",
                        createdAt: migrated.updatedAt,
                        kind: .information
                    ))
                }
            }
            let compacted = Self.compactedForPersistence(migrated)
            if compacted != migrated {
                migrated = compacted
                needsWrite = true
            }
            if needsWrite {
                let backup = folder.appendingPathComponent("session-v\(envelope.schemaVersion).json")
                // v4 only adds optional conversation fields. Keep the existing
                // v3 compaction policy: do not duplicate a potentially huge log.
                let shouldBackUpLegacySchema = envelope.schemaVersion < 3
                    && !fileManager.fileExists(atPath: backup.path)
                let backupAddition = shouldBackUpLegacySchema ? Int64(data.count) : 0
                let existingSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if let upgraded = try? encoder.encode(Envelope(schemaVersion: 4, session: migrated)),
                   storageSize() + backupAddition - existingSize + Int64(upgraded.count) <= storageLimitBytes
                {
                    if shouldBackUpLegacySchema { try? data.write(to: backup, options: .atomic) }
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
        merged.queuedMessages = current.queuedMessages
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

    public func enqueue(_ text: String, sessionID: UUID, storageFolderName: String) throws {
        guard var session = storedSession(id: sessionID, storageFolderName: storageFolderName) else { return }
        guard session.queuedMessages.last?.text != text else { return }
        guard session.queuedMessages.count < 4,
              session.queuedMessages.reduce(text.count, { $0 + $1.text.count }) <= 1_800
        else { throw DiscoveryStoreError.queueFull }
        session.queuedMessages.append(.init(text: text))
        try writeExisting(session)
    }

    /// Atomically moves pending inputs into history before execution, so a quit
    /// cannot lose a message between removing the queue and saving the turn.
    public func claimQueued(sessionID: UUID, storageFolderName: String) throws -> DiscoveryMessage? {
        guard var session = storedSession(id: sessionID, storageFolderName: storageFolderName),
              !session.queuedMessages.isEmpty else { return nil }
        var count = 1
        if DiscoveryRequestRouter.isRefinement(session.queuedMessages[0].text),
           DiscoveryConversation.action(for: session.queuedMessages[0].text, session: session) == .search {
            while count < session.queuedMessages.count,
                  DiscoveryRequestRouter.isRefinement(session.queuedMessages[count].text),
                  DiscoveryConversation.action(for: session.queuedMessages[count].text, session: session) == .search {
                count += 1
            }
        }
        let message = DiscoveryMessage(role: .user, text: session.queuedMessages.prefix(count).map(\.text).joined(separator: "\n"))
        session.queuedMessages.removeFirst(count)
        session.messages.append(message)
        try writeExisting(session)
        return message
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
              (1...4).contains(envelope.schemaVersion),
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
        let compacted = Self.compactedForPersistence(session)
        let data = try encoder.encode(Envelope(schemaVersion: 4, session: compacted))
        let existingSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let projectedSize = storageSize() - existingSize + Int64(data.count)
        guard projectedSize <= storageLimitBytes else {
            throw DiscoveryStoreError.storageLimitReached(storageLimitBytes)
        }
        try data.write(to: file, options: .atomic)
    }

    private static func compactedForPersistence(_ session: DiscoverySession) -> DiscoverySession {
        var compacted = session
        var detailedIDs: [String] = []
        if let selectedCandidateID = session.selectedCandidateID { detailedIDs.append(selectedCandidateID) }
        detailedIDs.append(contentsOf: session.recommendedCandidates.map(\.id))
        detailedIDs.append(contentsOf: session.candidates.map(\.id))
        let allowedDetailedIDs = Set(
            detailedIDs.reduce(into: [String]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }.prefix(DiscoveryStorageLimits.maximumDetailedCandidates)
        )
        for index in compacted.candidates.indices {
            if allowedDetailedIDs.contains(compacted.candidates[index].id) {
                if let excerpt = compacted.candidates[index].evidence.skillDocumentExcerpt {
                    compacted.candidates[index].evidence.skillDocumentExcerpt = String(
                        excerpt.prefix(DiscoveryStorageLimits.maximumDetailedExcerptCharacters)
                    )
                }
            } else {
                compacted.candidates[index].evidence.skillDocumentExcerpt = nil
            }
        }
        return compacted
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
