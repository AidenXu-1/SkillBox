import Foundation

public enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case blockedImport
    case candidateChanged
    case duplicateRecord
    case duplicateDesiredDestination
    case skillNotFound
    case skillStillInstalled

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "这份 SkillBox 数据来自更新的应用版本，当前应用暂时无法读取"
        case .blockedImport: "这份 Skill 有严重风险，为了安全已阻止添加"
        case .candidateChanged: "Skill 在你确认前发生了变化，请重新查看"
        case .duplicateRecord: "「我的 Skills」中已经有相同内容"
        case .duplicateDesiredDestination: "同一个应用里，同名 Skill 一次只能选择一份"
        case .skillNotFound: "在「我的 Skills」中找不到这份内容"
        case .skillStillInstalled: "这份 Skill 仍安装在应用中，请先从所有应用卸载"
        }
    }
}

public actor LibraryStore {
    public let root: URL
    public let libraryDirectory: URL
    public let transactionsDirectory: URL
    public let deletedDirectory: URL
    private let fileManager: FileManager
    private let fingerprinter: any SkillFingerprinting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var snapshot: LibrarySnapshot
    public let recoveryWarnings: [String]

    public init(
        root: URL,
        fileManager: FileManager = .default,
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter()
    ) throws {
        self.root = root.standardizedFileURL
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        transactionsDirectory = root.appendingPathComponent("Transactions", isDirectory: true)
        deletedDirectory = root.appendingPathComponent("Deleted", isDirectory: true)
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transactionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        var warnings: [String] = []
        snapshot = try Self.loadSnapshot(root: root, fileManager: fileManager, decoder: decoder, warnings: &warnings)
        recoveryWarnings = warnings
    }

    public func currentSnapshot() -> LibrarySnapshot { snapshot }

    public func replaceTargets(_ targets: [AgentTarget]) throws {
        snapshot.targets = targets
        try persist()
    }

    public func replaceAssignments(_ assignments: [Assignment]) throws {
        var desiredDestinations = Set<String>()
        for assignment in assignments where assignment.isDesired {
            let key = "\(assignment.targetID.uuidString):\(assignment.installationDirectoryName.lowercased())"
            guard desiredDestinations.insert(key).inserted else {
                throw LibraryStoreError.duplicateDesiredDestination
            }
        }
        snapshot.assignments = assignments
        try persist()
    }

    public func importCandidate(_ candidate: SkillCandidate) throws -> SkillRecord {
        guard !candidate.riskReport.isBlocked else { throw LibraryStoreError.blockedImport }
        guard try fingerprinter.fingerprint(directory: candidate.sourceURL) == candidate.fingerprint else {
            throw LibraryStoreError.candidateChanged
        }
        if let existing = snapshot.skills.first(where: {
            $0.canonicalName == candidate.canonicalName && $0.fingerprint == candidate.fingerprint
        }) { return existing }

        let id = UUID()
        let recordRoot = libraryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let content = recordRoot.appendingPathComponent("content", isDirectory: true)
        let temporary = libraryDirectory.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        try SafeFileOperations.copyDirectory(from: candidate.sourceURL, to: temporary, fileManager: fileManager)
        guard try fingerprinter.fingerprint(directory: temporary) == candidate.fingerprint else {
            try? fileManager.removeItem(at: temporary)
            throw FileOperationError.fingerprintMismatch
        }
        try fileManager.createDirectory(at: recordRoot, withIntermediateDirectories: true)
        try fileManager.moveItem(at: temporary, to: content)

        let record = SkillRecord(
            id: id,
            canonicalName: candidate.canonicalName,
            displayName: candidate.displayName,
            description: candidate.description,
            fingerprint: candidate.fingerprint,
            source: candidate.source,
            riskReport: candidate.riskReport,
            contentRelativePath: "Library/\(id.uuidString)/content"
        )
        snapshot.skills.append(record)
        do { try persist() } catch {
            snapshot.skills.removeAll { $0.id == id }
            try? fileManager.removeItem(at: recordRoot)
            throw error
        }
        return record
    }

    public func updateSkill(id: UUID, with candidate: SkillCandidate) throws -> SkillRecord {
        guard !candidate.riskReport.isBlocked else { throw LibraryStoreError.blockedImport }
        guard try fingerprinter.fingerprint(directory: candidate.sourceURL) == candidate.fingerprint else {
            throw LibraryStoreError.candidateChanged
        }
        guard let index = snapshot.skills.firstIndex(where: { $0.id == id }) else {
            throw LibraryStoreError.candidateChanged
        }
        let old = snapshot.skills[index]
        let recordRoot = libraryDirectory.appendingPathComponent(id.uuidString)
        let content = recordRoot.appendingPathComponent("content")
        let versions = recordRoot.appendingPathComponent("versions")
        let archived = versions.appendingPathComponent(old.fingerprint)
        let temporary = libraryDirectory.appendingPathComponent(".update-\(id.uuidString)-\(UUID().uuidString)")
        try SafeFileOperations.copyDirectory(from: candidate.sourceURL, to: temporary, fileManager: fileManager)
        guard try fingerprinter.fingerprint(directory: temporary) == candidate.fingerprint else {
            try? fileManager.removeItem(at: temporary)
            throw FileOperationError.fingerprintMismatch
        }
        try fileManager.createDirectory(at: versions, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: archived.path) {
            try SafeFileOperations.copyDirectory(from: content, to: archived, fileManager: fileManager)
        }
        _ = try fileManager.replaceItemAt(content, withItemAt: temporary)
        snapshot.skills[index].canonicalName = candidate.canonicalName
        snapshot.skills[index].displayName = candidate.displayName
        snapshot.skills[index].description = candidate.description
        snapshot.skills[index].fingerprint = candidate.fingerprint
        snapshot.skills[index].source = candidate.source
        snapshot.skills[index].riskReport = candidate.riskReport
        snapshot.skills[index].importedAt = Date()
        do {
            try persist()
        } catch {
            snapshot.skills[index] = old
            try? fileManager.removeItem(at: content)
            try? SafeFileOperations.copyDirectory(from: archived, to: content, fileManager: fileManager)
            throw error
        }
        return snapshot.skills[index]
    }

    public func contentURL(for skill: SkillRecord) -> URL {
        root.appendingPathComponent(skill.contentRelativePath)
    }

    public func deleteSkill(id: UUID) throws -> URL {
        guard snapshot.skills.contains(where: { $0.id == id }) else {
            throw LibraryStoreError.skillNotFound
        }
        guard !snapshot.installations.contains(where: { $0.skillID == id }) else {
            throw LibraryStoreError.skillStillInstalled
        }

        let recordRoot = libraryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let archived = deletedDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(id.uuidString)", isDirectory: true)
        let previousSnapshot = snapshot
        try fileManager.moveItem(at: recordRoot, to: archived)
        snapshot.skills.removeAll { $0.id == id }
        snapshot.assignments.removeAll { $0.skillID == id }
        do {
            try persist()
        } catch {
            snapshot = previousSnapshot
            try? fileManager.moveItem(at: archived, to: recordRoot)
            throw error
        }
        return archived
    }

    public func recordTransaction(_ transaction: SyncTransaction) throws {
        if let index = snapshot.transactions.firstIndex(where: { $0.id == transaction.id }) {
            snapshot.transactions[index] = transaction
        } else {
            snapshot.transactions.insert(transaction, at: 0)
        }
        try persist()
    }

    public func replaceInstallations(_ installations: [ManagedInstallation]) throws {
        snapshot.installations = installations
        try persist()
    }

    private func persist() throws {
        try write(snapshot.skills, name: "catalog.json")
        try write(snapshot.targets, name: "targets.json")
        try write(snapshot.assignments, name: "assignments.json")
        try write(snapshot.installations, name: "installations.json")
        try write(snapshot.transactions, name: "transactions.json")
    }

    private func write<T: Codable & Sendable>(_ value: T, name: String) throws {
        try SafeFileOperations.atomicWrite(PersistedEnvelope(value: value), to: root.appendingPathComponent(name), encoder: encoder, fileManager: fileManager)
    }

    private static func loadSnapshot(root: URL, fileManager: FileManager, decoder: JSONDecoder, warnings: inout [String]) throws -> LibrarySnapshot {
        func load<T: Codable & Sendable>(_ type: T.Type, name: String, fallback: T) throws -> T {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return fallback }
            do {
                let envelope = try decoder.decode(PersistedEnvelope<T>.self, from: Data(contentsOf: url))
                guard envelope.schemaVersion == SkillBoxSchema.currentVersion else {
                    throw LibraryStoreError.unsupportedSchema(envelope.schemaVersion)
                }
                return envelope.value
            } catch {
                let recovery = root.appendingPathComponent("CorruptData", isDirectory: true)
                try fileManager.createDirectory(at: recovery, withIntermediateDirectories: true)
                let archived = recovery.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(name)")
                try fileManager.moveItem(at: url, to: archived)
                warnings.append("SkillBox 的一份旧记录无法读取。原文件已安全保留在：\(archived.path)")
                return fallback
            }
        }
        return try LibrarySnapshot(
            skills: load([SkillRecord].self, name: "catalog.json", fallback: []),
            targets: load([AgentTarget].self, name: "targets.json", fallback: []),
            assignments: load([Assignment].self, name: "assignments.json", fallback: []),
            installations: load([ManagedInstallation].self, name: "installations.json", fallback: []),
            transactions: load([SyncTransaction].self, name: "transactions.json", fallback: [])
        )
    }
}
