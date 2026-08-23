import Foundation

public enum SkillDeletionMode: Sendable {
    case requireNoManagedInstallations
    case preserveInstalledCopies
}

public protocol SkillTrashHandling: Sendable {
    func trashItem(at url: URL) throws -> URL
}

public enum SkillTrashError: LocalizedError {
    case resultingLocationUnavailable

    public var errorDescription: String? {
        switch self {
        case .resultingLocationUnavailable:
            "macOS 已移动这份 Skill，但没有返回它在废纸篓中的位置，暂时无法提供撤销"
        }
    }
}

public struct SystemSkillTrash: SkillTrashHandling {
    public init() {}

    public func trashItem(at url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else { throw SkillTrashError.resultingLocationUnavailable }
        return resultingURL as URL
    }
}

private struct DirectorySkillTrash: SkillTrashHandling, @unchecked Sendable {
    let root: URL
    let fileManager: FileManager

    func trashItem(at url: URL) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent(
                "\(url.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}

public enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case blockedImport
    case highRiskConfirmationRequired
    case candidateChanged
    case centralContentChanged
    case centralArchiveChanged
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
        case .highRiskConfirmationRequired: "这份 Skill 包含需要确认的内容，请查看证据后再次明确确认"
        case .candidateChanged: "Skill 在你确认前发生了变化，请重新查看"
        case .centralContentChanged: "「我的 Skills」中的原件已被其他程序修改。SkillBox 没有覆盖它，请先重新检查"
        case .centralArchiveChanged: "这份 Skill 的历史恢复点已损坏或被修改。SkillBox 已停止更新，请先保留现场并检查"
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
    private let trashHandler: any SkillTrashHandling
    private let migratesLegacyDeletedItems: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var snapshot: LibrarySnapshot
    public let recoveryWarnings: [String]

    public init(
        root: URL,
        fileManager: FileManager = .default,
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter(),
        trashHandler: (any SkillTrashHandling)? = nil,
        migratesLegacyDeletedItems: Bool = false
    ) throws {
        let normalizedRoot = root.standardizedFileURL
        let libraryURL = normalizedRoot.appendingPathComponent("Library", isDirectory: true)
        let transactionsURL = normalizedRoot.appendingPathComponent("Transactions", isDirectory: true)
        let deletedURL = normalizedRoot.appendingPathComponent("Deleted", isDirectory: true)
        self.root = normalizedRoot
        libraryDirectory = libraryURL
        transactionsDirectory = transactionsURL
        deletedDirectory = deletedURL
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        self.trashHandler = trashHandler ?? DirectorySkillTrash(root: deletedURL, fileManager: fileManager)
        self.migratesLegacyDeletedItems = migratesLegacyDeletedItems
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: transactionsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: deletedURL, withIntermediateDirectories: true)
        var warnings: [String] = []
        let loaded = try Self.loadSnapshot(root: normalizedRoot, fileManager: fileManager, decoder: decoder, warnings: &warnings)
        var loadedSnapshot = loaded.snapshot
        let storageMoves = try Self.migrateReadableStorageFolders(
            snapshot: &loadedSnapshot,
            root: normalizedRoot,
            libraryDirectory: libraryURL,
            fileManager: fileManager
        )
        let deletionRecovery = try Self.recoverInterruptedLibraryDeletions(
            snapshot: &loadedSnapshot,
            root: normalizedRoot,
            transactionsDirectory: transactionsURL,
            fileManager: fileManager,
            fingerprinter: fingerprinter
        )
        warnings.append(contentsOf: deletionRecovery.warnings)
        let restorationRecovery = Self.recoverInterruptedLibraryRestorations(
            snapshot: &loadedSnapshot,
            root: normalizedRoot,
            fileManager: fileManager,
            fingerprinter: fingerprinter
        )
        warnings.append(contentsOf: restorationRecovery.warnings)
        snapshot = loadedSnapshot
        recoveryWarnings = warnings
        if loaded.didMigrate || !storageMoves.isEmpty || deletionRecovery.didChange || restorationRecovery.didChange {
            do {
                try Self.persist(snapshot: loadedSnapshot, root: normalizedRoot, encoder: encoder, fileManager: fileManager)
                for url in deletionRecovery.cleanupURLs where fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            } catch {
                for move in storageMoves.reversed() where fileManager.fileExists(atPath: move.to.path) {
                    try? fileManager.moveItem(at: move.to, to: move.from)
                }
                throw error
            }
        }
    }

    public func currentSnapshot() -> LibrarySnapshot { snapshot }

    public func mostRecentRestorableDeletion() -> DeletedSkillBackup? {
        snapshot.transactions
            .sorted { $0.createdAt > $1.createdAt }
            .lazy
            .compactMap { transaction -> DeletedSkillBackup? in
                guard transaction.status == .succeeded,
                      let deletion = transaction.libraryDeletion?.deletion,
                      let archivedURL = deletion.archivedURL,
                      self.fileManager.fileExists(atPath: archivedURL.path),
                      !self.snapshot.skills.contains(where: { $0.id == deletion.record.id })
                else { return nil }
                return deletion
            }
            .first
    }

    public func moveLegacyDeletedItemsToTrash() throws -> Int {
        guard migratesLegacyDeletedItems else { return 0 }
        let legacyItems = try fileManager.contentsOfDirectory(
            at: deletedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in legacyItems {
            _ = try trashHandler.trashItem(at: item)
        }
        return legacyItems.count
    }

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
            let skillMarkdown = content.appendingPathComponent("SKILL.md")
            if let text = try? String(contentsOf: skillMarkdown, encoding: .utf8) {
                let metadata = SkillMetadataParser.parse(
                    text: text,
                    fallbackName: snapshot.skills[index].canonicalName
                )
                if metadata.description != "未提供描述" {
                    snapshot.skills[index].description = metadata.description
                }
            }
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

    public func replaceLocalSourceStates(_ states: [LocalSourceState]) throws {
        snapshot.localSourceStates = states
        try persist()
    }

    public func updateLocalSourceState(_ state: LocalSourceState) throws {
        if let index = snapshot.localSourceStates.firstIndex(where: { $0.skillID == state.skillID }) {
            snapshot.localSourceStates[index] = state
        } else {
            snapshot.localSourceStates.append(state)
        }
        try persist()
    }

    public func recordLocalSourceUpdate(_ state: LocalSourceState, transactionID: UUID) throws {
        guard let transactionIndex = snapshot.transactions.firstIndex(where: { $0.id == transactionID }),
              snapshot.transactions[transactionIndex].libraryUpdate != nil
        else { throw LibraryStoreError.skillNotFound }
        let previousSnapshot = snapshot
        let previousState = snapshot.localSourceStates.first { $0.skillID == state.skillID }
        snapshot.transactions[transactionIndex].libraryUpdate?.previousLocalSourceState = previousState
        snapshot.transactions[transactionIndex].libraryUpdate?.updatedLocalSourceFingerprint = state.currentPackageFingerprint
        if let sourceIndex = snapshot.localSourceStates.firstIndex(where: { $0.skillID == state.skillID }) {
            snapshot.localSourceStates[sourceIndex] = state
        } else {
            snapshot.localSourceStates.append(state)
        }
        do { try persist() } catch {
            snapshot = previousSnapshot
            throw error
        }
    }

    public func restoreLocalSourceState(_ backup: LibraryUpdateBackup) throws {
        guard backup.previousLocalSourceState != nil || backup.updatedLocalSourceFingerprint != nil else { return }
        let skillID = backup.previousRecord.id
        if let previous = backup.previousLocalSourceState {
            if let index = snapshot.localSourceStates.firstIndex(where: { $0.skillID == skillID }) {
                snapshot.localSourceStates[index] = previous
            } else {
                snapshot.localSourceStates.append(previous)
            }
        } else {
            snapshot.localSourceStates.removeAll { $0.skillID == skillID }
        }
        try persist()
    }

    public func stopTrackingLocalSource(skillID: UUID) throws {
        guard let skillIndex = snapshot.skills.firstIndex(where: { $0.id == skillID }) else {
            throw LibraryStoreError.skillNotFound
        }
        let previousSnapshot = snapshot
        snapshot.skills[skillIndex].source = localCopySource(for: snapshot.skills[skillIndex])
        snapshot.localSourceStates.removeAll { $0.skillID == skillID }
        for index in snapshot.transactions.indices {
            guard var update = snapshot.transactions[index].libraryUpdate,
                  update.previousRecord.id == skillID
            else { continue }
            update.previousRecord.source = localCopySource(for: update.previousRecord)
            update.previousLocalSourceState = nil
            update.updatedLocalSourceFingerprint = nil
            snapshot.transactions[index].libraryUpdate = update
        }
        do { try persist() } catch {
            snapshot = previousSnapshot
            throw error
        }
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

    public func importCandidate(
        _ candidate: SkillCandidate,
        authorizingHighRisk: Bool = false
    ) throws -> SkillRecord {
        guard !candidate.riskReport.isBlocked else { throw LibraryStoreError.blockedImport }
        guard !candidate.riskReport.requiresUserAttention || authorizingHighRisk else {
            throw LibraryStoreError.highRiskConfirmationRequired
        }
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

    public func updateSkill(
        id: UUID,
        with candidate: SkillCandidate,
        authorizingHighRisk: Bool = false
    ) throws -> SkillRecord {
        guard !candidate.riskReport.isBlocked else { throw LibraryStoreError.blockedImport }
        guard !candidate.riskReport.requiresUserAttention || authorizingHighRisk else {
            throw LibraryStoreError.highRiskConfirmationRequired
        }
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
        guard fileManager.fileExists(atPath: content.path),
              try fingerprinter.fingerprint(directory: content) == old.fingerprint
        else { throw LibraryStoreError.centralContentChanged }
        if fileManager.fileExists(atPath: archived.path) {
            guard try fingerprinter.fingerprint(directory: archived) == old.fingerprint else {
                throw LibraryStoreError.centralArchiveChanged
            }
        }
        let temporary = libraryDirectory.appendingPathComponent(".update-\(id.uuidString)-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try SafeFileOperations.copyDirectory(from: candidate.sourceURL, to: temporary, fileManager: fileManager)
        guard try fingerprinter.fingerprint(directory: temporary) == candidate.fingerprint else {
            try? fileManager.removeItem(at: temporary)
            throw FileOperationError.fingerprintMismatch
        }
        try fileManager.createDirectory(at: versions, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: archived.path) {
            let temporaryArchive = versions.appendingPathComponent(".archive-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: temporaryArchive) }
            try SafeFileOperations.copyDirectory(from: content, to: temporaryArchive, fileManager: fileManager)
            guard try fingerprinter.fingerprint(directory: temporaryArchive) == old.fingerprint else {
                throw LibraryStoreError.centralContentChanged
            }
            try fileManager.moveItem(at: temporaryArchive, to: archived)
        }
        guard try fingerprinter.fingerprint(directory: content) == old.fingerprint else {
            throw LibraryStoreError.centralContentChanged
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
        guard let index = snapshot.skills.firstIndex(where: { $0.id == previous.id }) else {
            throw LibraryStoreError.candidateChanged
        }
        let current = snapshot.skills[index]
        let allowedFingerprints = Set([previous.fingerprint, backup.updatedFingerprint])
        guard allowedFingerprints.contains(current.fingerprint) else {
            throw LibraryStoreError.candidateChanged
        }
        let recordRoot = recordRoot(for: previous)
        let content = recordRoot.appendingPathComponent("content")
        guard fileManager.fileExists(atPath: content.path) else { throw LibraryStoreError.candidateChanged }
        let actualFingerprint = try fingerprinter.fingerprint(directory: content)
        guard allowedFingerprints.contains(actualFingerprint) else { throw LibraryStoreError.candidateChanged }
        if actualFingerprint == previous.fingerprint {
            snapshot.skills[index] = previous
            do { try persist() } catch {
                snapshot.skills[index] = current
                throw error
            }
            return previous
        }

        let versions = recordRoot.appendingPathComponent("versions")
        let previousContent = versions.appendingPathComponent(previous.fingerprint)
        guard fileManager.fileExists(atPath: previousContent.path),
              try fingerprinter.fingerprint(directory: previousContent) == previous.fingerprint
        else { throw LibraryStoreError.candidateChanged }
        let currentArchive = versions.appendingPathComponent(actualFingerprint)
        if !fileManager.fileExists(atPath: currentArchive.path) {
            try SafeFileOperations.copyDirectory(from: content, to: currentArchive, fileManager: fileManager)
        }
        let temporary = libraryDirectory.appendingPathComponent(".restore-\(previous.id.uuidString)-\(UUID().uuidString)")
        try SafeFileOperations.copyDirectory(from: previousContent, to: temporary, fileManager: fileManager)
        _ = try fileManager.replaceItemAt(content, withItemAt: temporary)
        snapshot.skills[index] = previous
        do { try persist() } catch {
            snapshot.skills[index] = current
            let rollback = libraryDirectory.appendingPathComponent(".restore-rollback-\(previous.id.uuidString)-\(UUID().uuidString)")
            if (try? SafeFileOperations.copyDirectory(from: currentArchive, to: rollback, fileManager: fileManager)) != nil {
                _ = try? fileManager.replaceItemAt(content, withItemAt: rollback)
            }
            throw error
        }
        return previous
    }

    public func contentURL(for skill: SkillRecord) -> URL {
        root.appendingPathComponent(skill.contentRelativePath)
    }

    public func deleteSkill(
        id: UUID,
        mode: SkillDeletionMode = .requireNoManagedInstallations
    ) throws -> DeletedSkillBackup {
        guard let record = snapshot.skills.first(where: { $0.id == id }) else {
            throw LibraryStoreError.skillNotFound
        }
        let managedInstallations = snapshot.installations.filter { $0.skillID == id }
        guard mode == .preserveInstalledCopies || managedInstallations.isEmpty else {
            throw LibraryStoreError.skillStillInstalled
        }

        let previousSnapshot = snapshot
        let recordRoot = recordRoot(for: record)
        let standardizedRecordRoot = recordRoot.standardizedFileURL.path.lowercased()
        let rootIsShared = snapshot.skills.contains {
            $0.id != id && self.recordRoot(for: $0).standardizedFileURL.path.lowercased() == standardizedRecordRoot
        }
        let movedRecordRoot = fileManager.fileExists(atPath: recordRoot.path) && !rootIsShared
        var deletion = DeletedSkillBackup(
            record: record,
            archivedURL: nil,
            assignments: snapshot.assignments.filter { $0.skillID == id },
            installations: managedInstallations,
            placement: snapshot.organization.placements.first { $0.skillID == id },
            sourceState: snapshot.sourceStates.first { $0.skillID == id },
            localSourceState: snapshot.localSourceStates.first { $0.skillID == id }
        )
        var transaction = SyncTransaction(
            status: .running,
            actions: [],
            libraryDeletion: .init(
                deletion: deletion,
                recoveryBackupRelativePath: movedRecordRoot ? "deletion-recovery" : nil
            )
        )
        snapshot.transactions.insert(transaction, at: 0)
        do {
            try persist()
            let transactionRoot = transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
            let recovery = transactionRoot.appendingPathComponent("deletion-recovery")
            if movedRecordRoot {
                try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
                try SafeFileOperations.copyDirectory(from: recordRoot, to: recovery, fileManager: fileManager)
                deletion.archivedURL = try trashHandler.trashItem(at: recordRoot)
            }

            snapshot.skills.removeAll { $0.id == id }
            snapshot.assignments.removeAll { $0.skillID == id }
            snapshot.installations.removeAll { $0.skillID == id }
            snapshot.organization.placements.removeAll { $0.skillID == id }
            snapshot.sourceStates.removeAll { $0.skillID == id }
            snapshot.localSourceStates.removeAll { $0.skillID == id }
            transaction.libraryDeletion?.deletion = deletion
            transaction.status = .succeeded
            transaction.completedAt = Date()
            if let index = snapshot.transactions.firstIndex(where: { $0.id == transaction.id }) {
                snapshot.transactions[index] = transaction
            }
            try persist()
            if fileManager.fileExists(atPath: recovery.path) { try? fileManager.removeItem(at: recovery) }
        } catch {
            let transactionRoot = transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
            do {
                try restoreDeletionContent(
                    journal: transaction.libraryDeletion ?? .init(deletion: deletion),
                    transactionRoot: transactionRoot
                )
                snapshot = previousSnapshot
                transaction.status = .rolledBack
                transaction.errors.append(error.localizedDescription)
                transaction.completedAt = Date()
                snapshot.transactions.insert(transaction, at: 0)
                try? persist()
                if let relative = transaction.libraryDeletion?.recoveryBackupRelativePath {
                    let recovery = transactionRoot.appendingPathComponent(relative)
                    if fileManager.fileExists(atPath: recovery.path) { try? fileManager.removeItem(at: recovery) }
                }
            } catch let recoveryError {
                snapshot = previousSnapshot
                transaction.status = .failed
                transaction.errors.append(error.localizedDescription)
                transaction.errors.append("恢复失败：\(recoveryError.localizedDescription)")
                transaction.completedAt = Date()
                snapshot.transactions.insert(transaction, at: 0)
                try? persist()
            }
            throw error
        }
        return deletion
    }

    public func restoreDeletedSkill(_ deletion: DeletedSkillBackup) throws -> SkillRecord {
        guard !snapshot.skills.contains(where: { $0.id == deletion.record.id }) else {
            throw LibraryStoreError.duplicateRecord
        }
        guard let archivedURL = deletion.archivedURL,
              fileManager.fileExists(atPath: archivedURL.path)
        else {
            throw LibraryStoreError.skillNotFound
        }
        var restoredRecord = deletion.record
        var recordRoot = recordRoot(for: restoredRecord)
        if fileManager.fileExists(atPath: recordRoot.path) {
            let folderName = availableStorageFolderName(for: restoredRecord.canonicalName, id: restoredRecord.id)
            restoredRecord.contentRelativePath = "Library/\(folderName)/content"
            recordRoot = self.recordRoot(for: restoredRecord)
        }

        let detachedInstallationKeys = Set(deletion.installations.map(installationKey))
        var occupiedDestinationPaths = Set(snapshot.installations.map {
            standardizedPath($0.destinationPath)
        })
        var reattachedInstallationKeys = Set<String>()
        var restorableInstallations: [ManagedInstallation] = []
        for installation in deletion.installations {
            let destinationPath = standardizedPath(installation.destinationPath)
            let destinationURL = URL(fileURLWithPath: installation.destinationPath, isDirectory: true)
            guard !occupiedDestinationPaths.contains(destinationPath),
                  fileManager.fileExists(atPath: destinationURL.path),
                  let currentFingerprint = try? fingerprinter.fingerprint(directory: destinationURL),
                  currentFingerprint == installation.deployedFingerprint
            else { continue }
            occupiedDestinationPaths.insert(destinationPath)
            reattachedInstallationKeys.insert(installationKey(installation))
            restorableInstallations.append(installation)
        }

        var occupiedAssignmentIDs = Set(snapshot.assignments.map(\.id))
        var occupiedDesiredDestinations = Set(snapshot.assignments.filter(\.isDesired).map(assignmentDestinationKey))
        var restorableAssignments: [Assignment] = []
        for assignment in deletion.assignments {
            let destinationKey = assignmentDestinationKey(assignment)
            if detachedInstallationKeys.contains(destinationKey),
               !reattachedInstallationKeys.contains(destinationKey)
            {
                continue
            }
            guard !occupiedAssignmentIDs.contains(assignment.id),
                  !assignment.isDesired || !occupiedDesiredDestinations.contains(destinationKey)
            else { continue }
            occupiedAssignmentIDs.insert(assignment.id)
            if assignment.isDesired { occupiedDesiredDestinations.insert(destinationKey) }
            restorableAssignments.append(assignment)
        }

        let previousSnapshot = snapshot
        var transaction = SyncTransaction(
            status: .running,
            actions: [],
            libraryRestoration: .init(deletion: deletion, restoredRecord: restoredRecord)
        )
        snapshot.transactions.insert(transaction, at: 0)
        do {
            try persist()
            try fileManager.moveItem(at: archivedURL, to: recordRoot)
            snapshot.skills.append(restoredRecord)
            snapshot.assignments.append(contentsOf: restorableAssignments)
            snapshot.installations.append(contentsOf: restorableInstallations)
            if let placement = deletion.placement { snapshot.organization.placements.append(placement) }
            if let sourceState = deletion.sourceState { snapshot.sourceStates.append(sourceState) }
            if let localSourceState = deletion.localSourceState { snapshot.localSourceStates.append(localSourceState) }
            snapshot.organization.normalize(skillIDs: snapshot.skills.map(\.id))
            transaction.status = .succeeded
            transaction.completedAt = Date()
            if let index = snapshot.transactions.firstIndex(where: { $0.id == transaction.id }) {
                snapshot.transactions[index] = transaction
            }
            try persist()
        } catch {
            snapshot = previousSnapshot
            do {
                try Self.rollbackInterruptedLibraryRestoration(
                    journal: transaction.libraryRestoration!,
                    root: root,
                    fileManager: fileManager,
                    fingerprinter: fingerprinter
                )
                transaction.status = .rolledBack
            } catch let recoveryError {
                transaction.status = .failed
                transaction.errors.append("恢复失败：\(recoveryError.localizedDescription)")
            }
            transaction.errors.append(error.localizedDescription)
            transaction.completedAt = Date()
            snapshot.transactions.insert(transaction, at: 0)
            try? persist()
            throw error
        }
        return restoredRecord
    }

    private func installationKey(_ installation: ManagedInstallation) -> String {
        "\(installation.targetID.uuidString):\(URL(fileURLWithPath: installation.destinationPath).lastPathComponent.lowercased())"
    }

    private func assignmentDestinationKey(_ assignment: Assignment) -> String {
        "\(assignment.targetID.uuidString):\(assignment.installationDirectoryName.lowercased())"
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    private func restoreDeletionContent(journal: LibraryDeletionJournal, transactionRoot: URL) throws {
        guard let relative = journal.recoveryBackupRelativePath else { return }
        let recordRoot = recordRoot(for: journal.deletion.record)
        let content = recordRoot.appendingPathComponent("content")
        if !fileManager.fileExists(atPath: recordRoot.path) {
            if let archivedURL = journal.deletion.archivedURL,
               fileManager.fileExists(atPath: archivedURL.path)
            {
                try fileManager.moveItem(at: archivedURL, to: recordRoot)
            } else {
                let recovery = transactionRoot.appendingPathComponent(relative)
                guard fileManager.fileExists(atPath: recovery.path) else {
                    throw LibraryStoreError.skillNotFound
                }
                try SafeFileOperations.copyDirectory(from: recovery, to: recordRoot, fileManager: fileManager)
            }
        }
        guard fileManager.fileExists(atPath: content.path),
              try fingerprinter.fingerprint(directory: content) == journal.deletion.record.fingerprint
        else { throw LibraryStoreError.candidateChanged }
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
        guard storageFolderIsUnavailable(base) else { return base }

        let suffix = id.uuidString.prefix(8).lowercased()
        var candidate = "\(base)--\(suffix)"
        var attempt = 2
        while storageFolderIsUnavailable(candidate) {
            candidate = "\(base)--\(suffix)-\(attempt)"
            attempt += 1
        }
        return candidate
    }

    private func storageFolderIsUnavailable(_ folderName: String) -> Bool {
        let candidateURL = libraryDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .standardizedFileURL
        if fileManager.fileExists(atPath: candidateURL.path) { return true }
        let candidateRoot = candidateURL.path.lowercased()
        return snapshot.skills.contains {
            recordRoot(for: $0).standardizedFileURL.path.lowercased() == candidateRoot
        }
    }

    private static func readableStorageFolderName(for canonicalName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let pieces = canonicalName.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        let readable = pieces.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return readable.isEmpty ? "skill" : readable
    }

    private struct DeletionRecoveryResult {
        var didChange = false
        var cleanupURLs: [URL] = []
        var warnings: [String] = []
    }

    private struct RestorationRecoveryResult {
        var didChange = false
        var warnings: [String] = []
    }

    private static func recoverInterruptedLibraryRestorations(
        snapshot: inout LibrarySnapshot,
        root: URL,
        fileManager: FileManager,
        fingerprinter: any SkillFingerprinting
    ) -> RestorationRecoveryResult {
        var result = RestorationRecoveryResult()
        for index in snapshot.transactions.indices {
            guard snapshot.transactions[index].status == .running,
                  let journal = snapshot.transactions[index].libraryRestoration
            else { continue }
            result.didChange = true
            do {
                try rollbackInterruptedLibraryRestoration(
                    journal: journal,
                    root: root,
                    fileManager: fileManager,
                    fingerprinter: fingerprinter
                )
                let skillID = journal.restoredRecord.id
                snapshot.skills.removeAll { $0.id == skillID }
                snapshot.assignments.removeAll { $0.skillID == skillID }
                snapshot.installations.removeAll { $0.skillID == skillID }
                snapshot.organization.placements.removeAll { $0.skillID == skillID }
                snapshot.sourceStates.removeAll { $0.skillID == skillID }
                snapshot.localSourceStates.removeAll { $0.skillID == skillID }
                snapshot.organization.normalize(skillIDs: snapshot.skills.map(\.id))
                snapshot.transactions[index].status = .rolledBack
                snapshot.transactions[index].completedAt = Date()
                snapshot.transactions[index].errors.append("应用上次异常退出，SkillBox 已撤回未完成的删除恢复")
                result.warnings.append("上次未完成的 Skill 恢复已安全撤回")
            } catch {
                snapshot.transactions[index].status = .failed
                snapshot.transactions[index].completedAt = Date()
                snapshot.transactions[index].errors.append("删除恢复的启动回滚失败：\(error.localizedDescription)")
                result.warnings.append("上次未完成的 Skill 恢复需要人工检查，原内容位置均已保留")
            }
        }
        return result
    }

    private static func rollbackInterruptedLibraryRestoration(
        journal: LibraryRestorationJournal,
        root: URL,
        fileManager: FileManager,
        fingerprinter: any SkillFingerprinting
    ) throws {
        guard let archivedURL = journal.deletion.archivedURL else {
            throw LibraryStoreError.skillNotFound
        }
        let recordRoot = root
            .appendingPathComponent(journal.restoredRecord.contentRelativePath)
            .deletingLastPathComponent()
        let restoredContent = recordRoot.appendingPathComponent("content")
        let archiveExists = fileManager.fileExists(atPath: archivedURL.path)
        let restoredExists = fileManager.fileExists(atPath: recordRoot.path)

        if archiveExists {
            guard !restoredExists else { throw LibraryStoreError.candidateChanged }
            return
        }
        guard restoredExists,
              fileManager.fileExists(atPath: restoredContent.path),
              try fingerprinter.fingerprint(directory: restoredContent) == journal.restoredRecord.fingerprint
        else { throw LibraryStoreError.candidateChanged }
        try fileManager.createDirectory(at: archivedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: recordRoot, to: archivedURL)
    }

    private static func recoverInterruptedLibraryDeletions(
        snapshot: inout LibrarySnapshot,
        root: URL,
        transactionsDirectory: URL,
        fileManager: FileManager,
        fingerprinter: any SkillFingerprinting
    ) throws -> DeletionRecoveryResult {
        var result = DeletionRecoveryResult()
        for index in snapshot.transactions.indices {
            guard snapshot.transactions[index].status == .running,
                  let journal = snapshot.transactions[index].libraryDeletion
            else { continue }
            result.didChange = true
            let deletion = journal.deletion
            let recordRoot = root.appendingPathComponent(deletion.record.contentRelativePath).deletingLastPathComponent()
            let content = recordRoot.appendingPathComponent("content")
            let transactionRoot = transactionsDirectory.appendingPathComponent(snapshot.transactions[index].id.uuidString)
            let recovery = journal.recoveryBackupRelativePath.map { transactionRoot.appendingPathComponent($0) }
            do {
                if journal.recoveryBackupRelativePath != nil,
                   !fileManager.fileExists(atPath: recordRoot.path)
                {
                    if let archivedURL = deletion.archivedURL,
                       fileManager.fileExists(atPath: archivedURL.path)
                    {
                        try fileManager.moveItem(at: archivedURL, to: recordRoot)
                    } else if let recovery, fileManager.fileExists(atPath: recovery.path) {
                        try SafeFileOperations.copyDirectory(from: recovery, to: recordRoot, fileManager: fileManager)
                    } else {
                        throw LibraryStoreError.skillNotFound
                    }
                }
                if journal.recoveryBackupRelativePath != nil {
                    guard fileManager.fileExists(atPath: content.path),
                          try fingerprinter.fingerprint(directory: content) == deletion.record.fingerprint
                    else { throw LibraryStoreError.candidateChanged }
                }

                if !snapshot.skills.contains(where: { $0.id == deletion.record.id }) {
                    snapshot.skills.append(deletion.record)
                }
                for assignment in deletion.assignments where !snapshot.assignments.contains(where: { $0.id == assignment.id }) {
                    snapshot.assignments.append(assignment)
                }
                for installation in deletion.installations where !snapshot.installations.contains(where: {
                    URL(fileURLWithPath: $0.destinationPath).standardizedFileURL
                        == URL(fileURLWithPath: installation.destinationPath).standardizedFileURL
                }) {
                    snapshot.installations.append(installation)
                }
                if let placement = deletion.placement,
                   !snapshot.organization.placements.contains(where: { $0.skillID == deletion.record.id })
                {
                    snapshot.organization.placements.append(placement)
                }
                if let sourceState = deletion.sourceState,
                   !snapshot.sourceStates.contains(where: { $0.skillID == deletion.record.id })
                {
                    snapshot.sourceStates.append(sourceState)
                }
                if let localSourceState = deletion.localSourceState,
                   !snapshot.localSourceStates.contains(where: { $0.skillID == deletion.record.id })
                {
                    snapshot.localSourceStates.append(localSourceState)
                }
                snapshot.organization.normalize(skillIDs: snapshot.skills.map(\.id))
                snapshot.transactions[index].status = .rolledBack
                snapshot.transactions[index].completedAt = Date()
                snapshot.transactions[index].errors.append("应用上次异常退出，SkillBox 已恢复未完成的中央删除")
                if let recovery { result.cleanupURLs.append(recovery) }
                result.warnings.append("上次未完成的 Skill 删除已安全恢复")
            } catch {
                snapshot.transactions[index].status = .failed
                snapshot.transactions[index].completedAt = Date()
                snapshot.transactions[index].errors.append("中央删除恢复失败：\(error.localizedDescription)")
                result.warnings.append("上次未完成的 Skill 删除需要人工检查，事务恢复副本已保留")
            }
        }

        for transaction in snapshot.transactions where transaction.status != .running && transaction.status != .failed {
            guard let relative = transaction.libraryDeletion?.recoveryBackupRelativePath else { continue }
            let recovery = transactionsDirectory
                .appendingPathComponent(transaction.id.uuidString)
                .appendingPathComponent(relative)
            if fileManager.fileExists(atPath: recovery.path) { result.cleanupURLs.append(recovery) }
        }
        return result
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
        // Keep the historical split files as readable compatibility mirrors.
        // The complete snapshot is written last and is the only commit marker;
        // an interruption while updating a mirror therefore leaves the prior
        // complete generation authoritative on the next launch.
        try write(snapshot.skills, name: "catalog.json")
        try write(snapshot.targets, name: "targets.json")
        try write(snapshot.assignments, name: "assignments.json")
        try write(snapshot.installations, name: "installations.json")
        try write(snapshot.organization, name: "organization.json")
        try write(snapshot.sourceStates, name: "source-state.json")
        try write(snapshot.localSourceStates, name: "local-source-state.json")
        try write(snapshot.transactions, name: "transactions.json")
        try write(snapshot, name: "library-state.json")
    }

    private static func loadSnapshot(root: URL, fileManager: FileManager, decoder: JSONDecoder, warnings: inout [String]) throws -> (snapshot: LibrarySnapshot, didMigrate: Bool) {
        let supportedSchemas = [1, 2, 3, SkillBoxSchema.currentVersion]
        let completeSnapshotURL = root.appendingPathComponent("library-state.json")
        if fileManager.fileExists(atPath: completeSnapshotURL.path) {
            do {
                let envelope = try decoder.decode(
                    PersistedEnvelope<LibrarySnapshot>.self,
                    from: Data(contentsOf: completeSnapshotURL)
                )
                guard supportedSchemas.contains(envelope.schemaVersion) else {
                    throw LibraryStoreError.unsupportedSchema(envelope.schemaVersion)
                }
                var completeSnapshot = envelope.value
                var didMigrate = envelope.schemaVersion != SkillBoxSchema.currentVersion
                completeSnapshot.organization.normalize(skillIDs: completeSnapshot.skills.map(\.id))
                if normalizeLegacyGitHubUpdateStatuses(&completeSnapshot.sourceStates) {
                    didMigrate = true
                }
                if migrateDeterministicGitHubPackageRecipes(&completeSnapshot.sourceStates) {
                    didMigrate = true
                }
                return (completeSnapshot, didMigrate)
            } catch let error as LibraryStoreError {
                throw error
            } catch {
                let recovery = root.appendingPathComponent("CorruptData", isDirectory: true)
                try fileManager.createDirectory(at: recovery, withIntermediateDirectories: true)
                let archived = recovery.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-library-state.json")
                try fileManager.moveItem(at: completeSnapshotURL, to: archived)
                warnings.append("SkillBox 的完整状态记录无法读取，已保留原文件并尝试兼容记录：\(archived.path)")
            }
        }

        let legacyNames = [
            "catalog.json",
            "targets.json",
            "assignments.json",
            "installations.json",
            "transactions.json",
            "organization.json",
            "source-state.json",
            "local-source-state.json",
        ]
        var didMigrate = legacyNames.contains {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        func load<T: Codable & Sendable>(_ type: T.Type, name: String, fallback: T) throws -> T {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return fallback }
            do {
                let envelope = try decoder.decode(PersistedEnvelope<T>.self, from: Data(contentsOf: url))
                guard supportedSchemas.contains(envelope.schemaVersion) else {
                    throw LibraryStoreError.unsupportedSchema(envelope.schemaVersion)
                }
                if envelope.schemaVersion != SkillBoxSchema.currentVersion { didMigrate = true }
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
        let localSourceStates = try load([LocalSourceState].self, name: "local-source-state.json", fallback: [])
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
        if migrateDeterministicGitHubPackageRecipes(&sourceStates) {
            didMigrate = true
        }
        let snapshot = try LibrarySnapshot(
            skills: skills,
            targets: load([AgentTarget].self, name: "targets.json", fallback: []),
            assignments: load([Assignment].self, name: "assignments.json", fallback: []),
            installations: load([ManagedInstallation].self, name: "installations.json", fallback: []),
            transactions: load([SyncTransaction].self, name: "transactions.json", fallback: []),
            organization: organization,
            sourceStates: sourceStates,
            localSourceStates: localSourceStates
        )
        return (snapshot, didMigrate)
    }

    private static func normalizeLegacyGitHubUpdateStatuses(_ states: inout [GitHubSourceState]) -> Bool {
        var changed = false
        for index in states.indices {
            if states[index].lastCheckIssue == nil,
               states[index].status == .authenticationRequired || states[index].status == .unavailable
            {
                if states[index].status == .authenticationRequired,
                   states[index].repositoryIsPrivate == true
                {
                    states[index].lastCheckIssue = .authenticationRequired
                } else {
                    states[index].lastCheckIssue = .temporarilyUnavailable
                }
                states[index].status = restoredLegacyVersionStatus(states[index])
                changed = true
            }

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

    private static func migrateDeterministicGitHubPackageRecipes(_ states: inout [GitHubSourceState]) -> Bool {
        var changed = false
        for index in states.indices where states[index].packageRecipe == nil {
            guard let repositoryID = states[index].repositoryID,
                  let currentVersion = states[index].currentVersionIdentifier
            else { continue }
            let skillPath = states[index].skillPath?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let origin: GitHubPackageRecipeOrigin
            if states[index].currentAssetID != nil {
                origin = .releaseAsset
            } else if skillPath?.isEmpty == false {
                origin = .skillDirectory
            } else {
                continue
            }
            states[index].packageRecipe = .init(
                origin: origin,
                repositoryID: repositoryID,
                repositoryFullName: states[index].repositoryFullName,
                trackingMode: states[index].trackingMode,
                skillPath: skillPath,
                confirmedVersionIdentifier: currentVersion
            )
            changed = true
        }
        return changed
    }

    private static func restoredLegacyVersionStatus(_ state: GitHubSourceState) -> GitHubSourceStatus {
        guard state.checkingEnabled else { return .checkingStopped }
        guard state.currentTreeSHA != nil else { return .needsInitialCheck }
        if state.ignoredVersionIdentifier == state.availableVersionIdentifier,
           state.availableVersionIdentifier != nil
        {
            return .ignored
        }
        if state.availableVersionIdentifier != nil,
           state.availableVersionIdentifier != state.currentVersionIdentifier
        {
            return .updateAvailable
        }
        return .current
    }
}
