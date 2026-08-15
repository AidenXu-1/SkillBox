import Foundation

public enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case blockedImport
    case candidateChanged
    case duplicateRecord
    case duplicateDesiredDestination
    case skillNotFound
    case skillStillInstalled
    case targetNotFound
    case builtinTarget
    case targetStillInstalled

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "这份 SkillBox 数据来自更新的应用版本，当前应用暂时无法读取"
        case .blockedImport: "这份 Skill 有严重风险，为了安全已阻止添加"
        case .candidateChanged: "Skill 在你确认前发生了变化，请重新查看"
        case .duplicateRecord: "「我的 Skills」中已经有相同内容"
        case .duplicateDesiredDestination: "同一个应用里，同名 Skill 一次只能选择一份"
        case .skillNotFound: "在「我的 Skills」中找不到这份内容"
        case .skillStillInstalled: "这份 Skill 仍安装在应用中，请先从所有应用卸载"
        case .targetNotFound: "找不到这个安装位置"
        case .builtinTarget: "内置应用位置不能删除"
        case .targetStillInstalled: "这个位置仍有 Skill 由 SkillBox 管理，请先卸载后再移除"
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
        let loaded = try Self.loadSnapshot(root: root, fileManager: fileManager, decoder: decoder, warnings: &warnings)
        var loadedSnapshot = loaded.snapshot
        let storageMoves = try Self.migrateReadableStorageFolders(
            snapshot: &loadedSnapshot,
            root: self.root,
            libraryDirectory: libraryDirectory,
            fileManager: fileManager
        )
        snapshot = loadedSnapshot
        recoveryWarnings = warnings
        if loaded.didMigrate || !storageMoves.isEmpty {
            do {
                try Self.persist(snapshot: snapshot, root: self.root, encoder: encoder, fileManager: fileManager)
            } catch {
                for move in storageMoves.reversed() where fileManager.fileExists(atPath: move.to.path) {
                    try? fileManager.moveItem(at: move.to, to: move.from)
                }
                throw error
            }
        }
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

    public func replaceOrganization(_ organization: SkillOrganization) throws {
        var normalized = organization
        normalized.normalize(skillIDs: snapshot.skills.map(\.id))
        snapshot.organization = normalized
        try persist()
    }

    public func refreshRiskReports(using analyzer: any RiskAnalyzer) throws {
        let previousSnapshot = snapshot
        for index in snapshot.skills.indices {
            let content = root.appendingPathComponent(snapshot.skills[index].contentRelativePath)
            snapshot.skills[index].riskReport = try analyzer.analyze(skillDirectory: content)
        }
        do { try persist() } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    public func replaceSourceStates(_ states: [GitHubSourceState]) throws {
        snapshot.sourceStates = states
        try persist()
    }

    public func updateSourceState(_ state: GitHubSourceState) throws {
        if let index = snapshot.sourceStates.firstIndex(where: { $0.skillID == state.skillID }) {
            snapshot.sourceStates[index] = state
        } else {
            snapshot.sourceStates.append(state)
        }
        try persist()
    }

    public func clearGitHubInformation() throws {
        let previousSnapshot = snapshot
        snapshot.sourceStates.removeAll()

        for index in snapshot.skills.indices where snapshot.skills[index].source.kind == .github {
            snapshot.skills[index].source = localCopySource(for: snapshot.skills[index])
        }

        for index in snapshot.transactions.indices {
            guard var update = snapshot.transactions[index].libraryUpdate else { continue }
            if update.previousRecord.source.kind == .github {
                update.previousRecord.source = localCopySource(for: update.previousRecord)
            }
            update.previousSourceState = nil
            update.updatedSourceVersionIdentifier = nil
            snapshot.transactions[index].libraryUpdate = update
        }

        do { try persist() } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    public func recordGitHubSourceUpdate(_ state: GitHubSourceState, transactionID: UUID) throws {
        guard let transactionIndex = snapshot.transactions.firstIndex(where: { $0.id == transactionID }),
              snapshot.transactions[transactionIndex].libraryUpdate != nil
        else { throw LibraryStoreError.skillNotFound }
        let previousSnapshot = snapshot
        let previousState = snapshot.sourceStates.first { $0.skillID == state.skillID }
        snapshot.transactions[transactionIndex].libraryUpdate?.previousSourceState = previousState
        snapshot.transactions[transactionIndex].libraryUpdate?.updatedSourceVersionIdentifier = state.currentVersionIdentifier
        if let sourceIndex = snapshot.sourceStates.firstIndex(where: { $0.skillID == state.skillID }) {
            snapshot.sourceStates[sourceIndex] = state
        } else {
            snapshot.sourceStates.append(state)
        }
        do { try persist() } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    public func restoreGitHubSourceState(_ backup: LibraryUpdateBackup) throws {
        guard backup.previousSourceState != nil || backup.updatedSourceVersionIdentifier != nil else { return }
        let skillID = backup.previousRecord.id
        if let previous = backup.previousSourceState {
            if let index = snapshot.sourceStates.firstIndex(where: { $0.skillID == skillID }) {
                snapshot.sourceStates[index] = previous
            } else {
                snapshot.sourceStates.append(previous)
            }
        } else {
            snapshot.sourceStates.removeAll { $0.skillID == skillID }
        }
        try persist()
    }

    private func localCopySource(for record: SkillRecord) -> SkillSource {
        SkillSource(
            kind: .localFolder,
            displayName: "SkillBox 中的本地副本",
            locator: record.contentRelativePath
        )
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
        let storageFolderName = availableStorageFolderName(for: candidate.canonicalName, id: id)
        let recordRoot = libraryDirectory.appendingPathComponent(storageFolderName, isDirectory: true)
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
            contentRelativePath: "Library/\(storageFolderName)/content"
        )
        snapshot.skills.append(record)
        snapshot.organization.normalize(skillIDs: snapshot.skills.map(\.id))
        do { try persist() } catch {
            snapshot.skills.removeAll { $0.id == id }
            snapshot.organization.placements.removeAll { $0.skillID == id }
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
        let recordRoot = recordRoot(for: old)
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

    public func restoreSkillVersion(_ backup: LibraryUpdateBackup) throws -> SkillRecord {
        let previous = backup.previousRecord
        guard let index = snapshot.skills.firstIndex(where: { $0.id == previous.id }),
              snapshot.skills[index].fingerprint == backup.updatedFingerprint
        else { throw LibraryStoreError.candidateChanged }
        let current = snapshot.skills[index]
        let recordRoot = recordRoot(for: current)
        let content = recordRoot.appendingPathComponent("content")
        let versions = recordRoot.appendingPathComponent("versions")
        let previousContent = versions.appendingPathComponent(previous.fingerprint)
        guard fileManager.fileExists(atPath: previousContent.path),
              try fingerprinter.fingerprint(directory: previousContent) == previous.fingerprint
        else { throw LibraryStoreError.candidateChanged }
        let currentArchive = versions.appendingPathComponent(current.fingerprint)
        if !fileManager.fileExists(atPath: currentArchive.path) {
            try SafeFileOperations.copyDirectory(from: content, to: currentArchive, fileManager: fileManager)
        }
        let temporary = libraryDirectory.appendingPathComponent(".restore-\(previous.id.uuidString)-\(UUID().uuidString)")
        try SafeFileOperations.copyDirectory(from: previousContent, to: temporary, fileManager: fileManager)
        _ = try fileManager.replaceItemAt(content, withItemAt: temporary)
        snapshot.skills[index] = previous
        do { try persist() } catch {
            snapshot.skills[index] = current
            throw error
        }
        return previous
    }

    public func contentURL(for skill: SkillRecord) -> URL {
        root.appendingPathComponent(skill.contentRelativePath)
    }

    public func deleteSkill(id: UUID) throws -> DeletedSkillBackup {
        guard let record = snapshot.skills.first(where: { $0.id == id }) else {
            throw LibraryStoreError.skillNotFound
        }
        guard !snapshot.installations.contains(where: { $0.skillID == id }) else {
            throw LibraryStoreError.skillStillInstalled
        }

        let recordRoot = recordRoot(for: record)
        let archived = deletedDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(id.uuidString)", isDirectory: true)
        let deletion = DeletedSkillBackup(
            record: record,
            archivedURL: archived,
            assignments: snapshot.assignments.filter { $0.skillID == id },
            placement: snapshot.organization.placements.first { $0.skillID == id },
            sourceState: snapshot.sourceStates.first { $0.skillID == id }
        )
        let previousSnapshot = snapshot
        try fileManager.moveItem(at: recordRoot, to: archived)
        snapshot.skills.removeAll { $0.id == id }
        snapshot.assignments.removeAll { $0.skillID == id }
        snapshot.organization.placements.removeAll { $0.skillID == id }
        snapshot.sourceStates.removeAll { $0.skillID == id }
        do {
            try persist()
        } catch {
            snapshot = previousSnapshot
            try? fileManager.moveItem(at: archived, to: recordRoot)
            throw error
        }
        return deletion
    }

    public func restoreDeletedSkill(_ deletion: DeletedSkillBackup) throws -> SkillRecord {
        guard !snapshot.skills.contains(where: { $0.id == deletion.record.id }) else {
            throw LibraryStoreError.duplicateRecord
        }
        guard fileManager.fileExists(atPath: deletion.archivedURL.path) else {
            throw LibraryStoreError.skillNotFound
        }
        var restoredRecord = deletion.record
        var recordRoot = recordRoot(for: restoredRecord)
        if fileManager.fileExists(atPath: recordRoot.path) {
            let folderName = availableStorageFolderName(for: restoredRecord.canonicalName, id: restoredRecord.id)
            restoredRecord.contentRelativePath = "Library/\(folderName)/content"
            recordRoot = self.recordRoot(for: restoredRecord)
        }
        let previousSnapshot = snapshot
        try fileManager.moveItem(at: deletion.archivedURL, to: recordRoot)
        snapshot.skills.append(restoredRecord)
        snapshot.assignments.append(contentsOf: deletion.assignments)
        if let placement = deletion.placement { snapshot.organization.placements.append(placement) }
        if let sourceState = deletion.sourceState { snapshot.sourceStates.append(sourceState) }
        snapshot.organization.normalize(skillIDs: snapshot.skills.map(\.id))
        do {
            try persist()
        } catch {
            snapshot = previousSnapshot
            try? fileManager.moveItem(at: recordRoot, to: deletion.archivedURL)
            throw error
        }
        return restoredRecord
    }

    public func removeCustomTarget(id: UUID) throws {
        guard let target = snapshot.targets.first(where: { $0.id == id }) else {
            throw LibraryStoreError.targetNotFound
        }
        guard target.isCustom else { throw LibraryStoreError.builtinTarget }
        guard !snapshot.installations.contains(where: { $0.targetID == id }) else {
            throw LibraryStoreError.targetStillInstalled
        }
        snapshot.targets.removeAll { $0.id == id }
        snapshot.assignments.removeAll { $0.targetID == id }
        try persist()
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

    private func recordRoot(for record: SkillRecord) -> URL {
        root.appendingPathComponent(record.contentRelativePath).deletingLastPathComponent()
    }

    private func availableStorageFolderName(for canonicalName: String, id: UUID) -> String {
        let base = Self.readableStorageFolderName(for: canonicalName)
        guard !fileManager.fileExists(atPath: libraryDirectory.appendingPathComponent(base).path) else {
            return "\(base)--\(id.uuidString.prefix(8).lowercased())"
        }
        return base
    }

    private static func readableStorageFolderName(for canonicalName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let pieces = canonicalName.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        let readable = pieces.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return readable.isEmpty ? "skill" : readable
    }

    private static func migrateReadableStorageFolders(
        snapshot: inout LibrarySnapshot,
        root: URL,
        libraryDirectory: URL,
        fileManager: FileManager
    ) throws -> [(from: URL, to: URL)] {
        var moves: [(from: URL, to: URL)] = []
        let originalSnapshot = snapshot
        do {
            for index in snapshot.skills.indices {
                let currentContent = root.appendingPathComponent(snapshot.skills[index].contentRelativePath)
                let currentRoot = currentContent.deletingLastPathComponent()
                guard currentRoot.deletingLastPathComponent().standardizedFileURL == libraryDirectory.standardizedFileURL,
                      UUID(uuidString: currentRoot.lastPathComponent) != nil,
                      fileManager.fileExists(atPath: currentRoot.path)
                else { continue }

                let base = readableStorageFolderName(for: snapshot.skills[index].canonicalName)
                var folderName = base
                var destination = libraryDirectory.appendingPathComponent(folderName, isDirectory: true)
                if fileManager.fileExists(atPath: destination.path) {
                    folderName = "\(base)--\(snapshot.skills[index].id.uuidString.prefix(8).lowercased())"
                    destination = libraryDirectory.appendingPathComponent(folderName, isDirectory: true)
                }
                guard !fileManager.fileExists(atPath: destination.path) else { continue }

                try fileManager.moveItem(at: currentRoot, to: destination)
                moves.append((from: currentRoot, to: destination))
                let relativePath = "Library/\(folderName)/content"
                snapshot.skills[index].contentRelativePath = relativePath
                for transactionIndex in snapshot.transactions.indices {
                    guard snapshot.transactions[transactionIndex].libraryUpdate?.previousRecord.id == snapshot.skills[index].id else { continue }
                    snapshot.transactions[transactionIndex].libraryUpdate?.previousRecord.contentRelativePath = relativePath
                }
            }
            return moves
        } catch {
            snapshot = originalSnapshot
            for move in moves.reversed() where fileManager.fileExists(atPath: move.to.path) {
                try? fileManager.moveItem(at: move.to, to: move.from)
            }
            throw error
        }
    }

    private func persist() throws {
        try Self.persist(snapshot: snapshot, root: root, encoder: encoder, fileManager: fileManager)
    }

    private static func persist(snapshot: LibrarySnapshot, root: URL, encoder: JSONEncoder, fileManager: FileManager) throws {
        func write<T: Codable & Sendable>(_ value: T, name: String) throws {
            try SafeFileOperations.atomicWrite(PersistedEnvelope(value: value), to: root.appendingPathComponent(name), encoder: encoder, fileManager: fileManager)
        }
        try write(snapshot.skills, name: "catalog.json")
        try write(snapshot.targets, name: "targets.json")
        try write(snapshot.assignments, name: "assignments.json")
        try write(snapshot.installations, name: "installations.json")
        try write(snapshot.transactions, name: "transactions.json")
        try write(snapshot.organization, name: "organization.json")
        try write(snapshot.sourceStates, name: "source-state.json")
    }

    private static func loadSnapshot(root: URL, fileManager: FileManager, decoder: JSONDecoder, warnings: inout [String]) throws -> (snapshot: LibrarySnapshot, didMigrate: Bool) {
        var didMigrate = false
        func load<T: Codable & Sendable>(_ type: T.Type, name: String, fallback: T) throws -> T {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return fallback }
            do {
                let envelope = try decoder.decode(PersistedEnvelope<T>.self, from: Data(contentsOf: url))
                guard envelope.schemaVersion == 1 || envelope.schemaVersion == SkillBoxSchema.currentVersion else {
                    throw LibraryStoreError.unsupportedSchema(envelope.schemaVersion)
                }
                if envelope.schemaVersion == 1 { didMigrate = true }
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
        let skills = try load([SkillRecord].self, name: "catalog.json", fallback: [])
        var organization = try load(SkillOrganization.self, name: "organization.json", fallback: .init())
        organization.normalize(skillIDs: skills.map(\.id))
        var sourceStates = try load([GitHubSourceState].self, name: "source-state.json", fallback: [])
        let stateSkillIDs = Set(sourceStates.map(\.skillID))
        for skill in skills where skill.source.kind == .github && !stateSkillIDs.contains(skill.id) {
            sourceStates.append(.init(
                skillID: skill.id,
                repositoryFullName: skill.source.repository ?? skill.source.displayName,
                skillPath: skill.source.skillPath,
                trackingMode: .defaultBranch,
                defaultBranch: skill.source.revision,
                checkingEnabled: true,
                status: .needsInitialCheck
            ))
            didMigrate = true
        }
        if normalizeLegacyGitHubUpdateStatuses(&sourceStates) {
            didMigrate = true
        }
        let snapshot = try LibrarySnapshot(
            skills: skills,
            targets: load([AgentTarget].self, name: "targets.json", fallback: []),
            assignments: load([Assignment].self, name: "assignments.json", fallback: []),
            installations: load([ManagedInstallation].self, name: "installations.json", fallback: []),
            transactions: load([SyncTransaction].self, name: "transactions.json", fallback: []),
            organization: organization,
            sourceStates: sourceStates
        )
        return (snapshot, didMigrate)
    }

    private static func normalizeLegacyGitHubUpdateStatuses(_ states: inout [GitHubSourceState]) -> Bool {
        var changed = false
        for index in states.indices {
            guard states[index].trackingMode == .latestStableRelease,
                  states[index].status == .updateAvailable,
                  states[index].currentReleaseID == nil,
                  states[index].currentAssetID == nil,
                  let availableReleaseID = states[index].availableReleaseID,
                  states[index].currentVersionIdentifier == "release:\(availableReleaseID)",
                  states[index].currentCommitSHA == states[index].availableCommitSHA,
                  states[index].currentTreeSHA == states[index].availableTreeSHA
            else { continue }

            if states[index].availableAssetID != nil {
                states[index].status = .releasePackageAvailable
            } else if states[index].availableVersionIdentifier?.contains(":source:") == true {
                states[index].status = .current
                states[index].currentReleaseID = availableReleaseID
                states[index].currentVersionIdentifier = states[index].availableVersionIdentifier
            } else {
                continue
            }
            changed = true
        }
        return changed
    }
}
