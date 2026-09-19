import Darwin
import Foundation

public protocol SyncPlanner: Sendable {
    func makePlan(snapshot: LibrarySnapshot, libraryRoot: URL) throws -> SyncPlan
}

public struct DefaultSyncPlanner: SyncPlanner, Sendable {
    private let fingerprinter: any SkillFingerprinting

    public init(fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter()) {
        self.fingerprinter = fingerprinter
    }

    public func makePlan(snapshot: LibrarySnapshot, libraryRoot: URL) throws -> SyncPlan {
        let skills = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0) })
        let targets = Dictionary(uniqueKeysWithValues: snapshot.targets.map { ($0.id, $0) })
        let managedByDestination = Dictionary(uniqueKeysWithValues: snapshot.installations.map { ($0.destinationPath, $0) })
        var desiredDestinations: Set<String> = []
        var actions: [SyncAction] = []

        for assignment in snapshot.assignments where assignment.isDesired {
            guard let skill = skills[assignment.skillID] else {
                actions.append(blocked(assignment, path: "", reason: .missingSkill, summary: "SkillBox 中找不到这份 Skill")); continue
            }
            guard let target = targets[assignment.targetID] else {
                actions.append(blocked(assignment, path: "", reason: .missingTarget, summary: "找不到这个应用的安装位置")); continue
            }
            let destination = URL(fileURLWithPath: target.path).appendingPathComponent(assignment.installationDirectoryName).standardizedFileURL
            desiredDestinations.insert(destination.path)
            guard target.detectionStatus == .available, targetDirectoryExists(target) else {
                actions.append(blocked(assignment, path: destination.path, reason: .targetUnavailable, summary: "本机没有找到 \(target.displayName)，不会创建它的文件夹")); continue
            }
            guard destination.deletingLastPathComponent().path == URL(fileURLWithPath: target.path).standardizedFileURL.path else {
                actions.append(blocked(assignment, path: destination.path, reason: .invalidDestination, summary: "安装位置不安全，请重新选择")); continue
            }
            guard !skill.riskReport.isBlocked else {
                actions.append(blocked(assignment, path: destination.path, reason: .sourceBlocked, summary: "这份 Skill 有严重风险，已停止安装")); continue
            }
            if target.writeStatus != .writable || !FileManager.default.isWritableFile(atPath: target.path) {
                actions.append(blocked(assignment, path: destination.path, reason: .targetReadOnly, summary: "这个文件夹目前不能写入")); continue
            }

            let current = currentFingerprint(destination)
            if let managed = managedByDestination[destination.path] {
                guard current == managed.deployedFingerprint else {
                    actions.append(.init(
                        kind: .blocked,
                        skillID: skill.id, targetID: target.id, destinationPath: destination.path,
                        expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current,
                        blockReason: .externalModification,
                        summary: "当前内容与上次安装记录不一致"
                    ))
                    continue
                }
                let source = libraryRoot.appendingPathComponent(skill.contentRelativePath)
                let sameContent = current == skill.fingerprint || matchesIgnoringFinderMetadata(source: source, destination: destination, expectedSource: skill.fingerprint)
                let kind: SyncActionKind = sameContent ? .noChange : .update
                actions.append(.init(kind: kind, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: kind == .update ? "更新 \(skill.displayName)" : "已安装，内容一致"))
            } else if let current {
                let authorizationMatches = assignment.authorizedDestinationFingerprint == current
                if current == skill.fingerprint, assignment.allowTakeover, authorizationMatches {
                    actions.append(.init(kind: .takeover, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: "让 SkillBox 管理已有的相同内容"))
                } else if current != skill.fingerprint, assignment.allowReplacement, authorizationMatches {
                    actions.append(.init(kind: .update, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: "用 SkillBox 中的版本替换现有内容"))
                } else {
                    actions.append(.init(
                        kind: .blocked,
                        skillID: skill.id,
                        targetID: target.id,
                        destinationPath: destination.path,
                        expectedSourceFingerprint: skill.fingerprint,
                        expectedDestinationFingerprint: current,
                        blockReason: .unmanagedConflict,
                        summary: current == skill.fingerprint ? "这里已有相同内容，需要你允许 SkillBox 管理" : "这里已经有一个同名 Skill，需要你选择如何处理"
                    ))
                }
            } else {
                actions.append(.init(kind: .create, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, summary: "安装 \(skill.displayName)"))
            }
        }

        for installation in snapshot.installations where !desiredDestinations.contains(installation.destinationPath) {
            let current = currentFingerprint(URL(fileURLWithPath: installation.destinationPath))
            if current == installation.deployedFingerprint {
                actions.append(.init(kind: .remove, skillID: installation.skillID, targetID: installation.targetID, destinationPath: installation.destinationPath, expectedDestinationFingerprint: current, summary: "从这个应用中移除 Skill"))
            } else {
                actions.append(.init(kind: .blocked, skillID: installation.skillID, targetID: installation.targetID, destinationPath: installation.destinationPath, expectedDestinationFingerprint: installation.deployedFingerprint, blockReason: .externalModification, summary: "内容后来被改过，暂时不能移除"))
            }
        }
        return SyncPlan(actions: actions.sorted { $0.destinationPath < $1.destinationPath })
    }

    private func matchesIgnoringFinderMetadata(source: URL, destination: URL, expectedSource: String) -> Bool {
        guard (try? fingerprinter.fingerprint(directory: source)) == expectedSource else { return false }
        let content = SHA256SkillFingerprinter(ignoringFinderMetadata: true)
        guard let expected = try? content.fingerprint(directory: source),
              let actual = try? content.fingerprint(directory: destination) else { return false }
        return expected == actual
    }

    private func currentFingerprint(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? fingerprinter.fingerprint(directory: url)
    }

    private func targetDirectoryExists(_ target: AgentTarget) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func blocked(_ assignment: Assignment, path: String, reason: SyncBlockReason, summary: String) -> SyncAction {
        .init(kind: .blocked, skillID: assignment.skillID, targetID: assignment.targetID, destinationPath: path, blockReason: reason, summary: summary)
    }
}

public protocol SyncExecutor: Sendable {
    func execute(
        plan: SyncPlan,
        store: LibraryStore,
        transaction: SyncTransaction?
    ) async throws -> SyncTransaction
    func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction
    func rollback(transactionID: UUID, store: LibraryStore, reason: String) async throws -> SyncTransaction
}

public extension SyncExecutor {
    func execute(plan: SyncPlan, store: LibraryStore) async throws -> SyncTransaction {
        try await execute(plan: plan, store: store, transaction: nil)
    }
}

public enum SyncExecutorError: LocalizedError {
    case planContainsBlockedActions
    case stateChanged(String)
    case transactionNotFound
    case undoWouldOverwrite(String)
    case targetUnavailable(String)
    case injectedFailure
    case rollbackExpired

    public var errorDescription: String? {
        switch self {
        case .planContainsBlockedActions: "安装列表中还有需要先处理的问题"
        case let .stateChanged(path): "你确认后，文件又发生了变化。SkillBox 已停下：\(path)"
        case .transactionNotFound: "找不到这次操作记录"
        case let .undoWouldOverwrite(path): "文件在安装后又被改过。为了保护新内容，暂时不能恢复：\(path)"
        case let .targetUnavailable(path): "应用的 Skills 文件夹不存在或无法写入，SkillBox 不会代为创建：\(path)"
        case .injectedFailure: "测试注入的写入中断"
        case .rollbackExpired: "这份回退备份已被更新的备份替代，或已满 7 天，无法再恢复"
        }
    }
}

public actor TransactionalSyncExecutor: SyncExecutor {
    private let fileManager: FileManager
    private let fingerprinter: any SkillFingerprinting
    private let shouldInjectFailure: @Sendable (Int) -> Bool
    private let beforeDestinationMutation: @Sendable (URL) -> Void

    public init(fileManager: FileManager = .default, fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter()) {
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        shouldInjectFailure = { _ in false }
        beforeDestinationMutation = { _ in }
    }

    init(
        fileManager: FileManager = .default,
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter(),
        shouldInjectFailure: @escaping @Sendable (Int) -> Bool,
        beforeDestinationMutation: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        self.shouldInjectFailure = shouldInjectFailure
        self.beforeDestinationMutation = beforeDestinationMutation
    }

    public func execute(
        plan: SyncPlan,
        store: LibraryStore,
        transaction initialTransaction: SyncTransaction?
    ) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        let skills = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0) })
        var installations = snapshot.installations
        var transaction = initialTransaction ?? SyncTransaction(status: .running, actions: plan.actions)
        transaction.status = .running
        transaction.completedAt = nil
        transaction.actions = plan.actions
        let transactionRoot = store.transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
        let backupRoot = transactionRoot.appendingPathComponent("backups")
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try await store.recordTransaction(transaction)

        do {
            for (index, action) in plan.executableActions.enumerated() {
                let destination = URL(fileURLWithPath: action.destinationPath)
                let previousInstallation = installations.first { $0.destinationPath == destination.path }
                let current = fingerprintIfExists(destination)
                guard current == action.expectedDestinationFingerprint else { throw SyncExecutorError.stateChanged(destination.path) }
                if [.create, .update, .takeover].contains(action.kind) {
                    try requireExistingWritableParent(of: destination)
                }
                let backupName = "\(index)-\(destination.lastPathComponent)"
                let backup = backupRoot.appendingPathComponent(backupName)
                if current != nil { try SafeFileOperations.copyDirectory(from: destination, to: backup, fileManager: fileManager) }

                let expectedAfterFingerprint: String?
                switch action.kind {
                case .create, .update:
                    expectedAfterFingerprint = action.expectedSourceFingerprint
                case .takeover:
                    expectedAfterFingerprint = current
                case .remove:
                    expectedAfterFingerprint = nil
                default:
                    expectedAfterFingerprint = current
                }
                transaction.backups.append(.init(
                    destinationPath: destination.path,
                    backupRelativePath: current == nil ? nil : "backups/\(backupName)",
                    beforeFingerprint: current,
                    afterFingerprint: expectedAfterFingerprint,
                    actionKind: action.kind,
                    previousInstallation: previousInstallation
                ))
                try await store.recordTransaction(transaction)

                switch action.kind {
                case .create, .update:
                    guard let skill = skills[action.skillID] else { throw SyncExecutorError.stateChanged(destination.path) }
                    let source = await store.contentURL(for: skill)
                    guard try fingerprinter.fingerprint(directory: source) == action.expectedSourceFingerprint else { throw SyncExecutorError.stateChanged(source.path) }
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".skillbox-\(UUID().uuidString)")
                    try SafeFileOperations.copyDirectory(from: source, to: staged, fileManager: fileManager)
                    guard try fingerprinter.fingerprint(directory: staged) == action.expectedSourceFingerprint else { throw FileOperationError.fingerprintMismatch }
                    beforeDestinationMutation(destination)
                    if let expectedBefore = action.expectedDestinationFingerprint {
                        try replaceExistingDirectoryAtomically(
                            destination: destination,
                            staged: staged,
                            expectedBeforeFingerprint: expectedBefore
                        )
                    } else {
                        guard !fileManager.fileExists(atPath: destination.path) else {
                            throw SyncExecutorError.stateChanged(destination.path)
                        }
                        try fileManager.moveItem(at: staged, to: destination)
                    }
                case .remove:
                    beforeDestinationMutation(destination)
                    guard let expectedBefore = action.expectedDestinationFingerprint else {
                        throw SyncExecutorError.stateChanged(destination.path)
                    }
                    try removeExistingDirectoryAtomically(
                        destination: destination,
                        expectedBeforeFingerprint: expectedBefore
                    )
                case .takeover:
                    break
                default:
                    break
                }

                let after = fingerprintIfExists(destination)
                guard after == expectedAfterFingerprint else {
                    throw SyncExecutorError.stateChanged(destination.path)
                }
                installations.removeAll { $0.destinationPath == destination.path }
                if [.create, .update, .takeover].contains(action.kind), let after {
                    installations.append(.init(skillID: action.skillID, targetID: action.targetID, destinationPath: destination.path, deployedFingerprint: after, transactionID: transaction.id))
                }
                if shouldInjectFailure(transaction.backups.count) { throw SyncExecutorError.injectedFailure }
            }
            transaction.status = .succeeded
            transaction.completedAt = Date()
            try await store.replaceInstallations(installations)
            try await store.recordTransaction(transaction)
            return transaction
        } catch {
            transaction.errors.append(error.localizedDescription)
            do {
                var completion = transaction
                completion.status = .rolledBack
                completion.completedAt = Date()
                transaction = try await performRestoration(completion: completion, store: store,
                    installations: snapshot.installations, assignments: snapshot.assignments)
            } catch {
                transaction.errors.append("恢复失败：\(error.localizedDescription)")
                transaction.status = .failed
            }
            transaction.completedAt = Date()
            try await store.recordTransaction(transaction)
            throw transaction.status == .failed ? SyncExecutorError.stateChanged("自动恢复没有完成，请查看「设置 → 操作记录与恢复」") : error
        }
    }

    /// Update coordination uses the same prepared, compensatable restoration
    /// as deployment failures and startup recovery. Only its final saved
    /// restoration may call the original transaction rolled back.
    public func rollback(transactionID: UUID, store: LibraryStore, reason: String) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        guard var transaction = snapshot.transactions.first(where: { $0.id == transactionID }) else {
            throw SyncExecutorError.transactionNotFound
        }
        guard transaction.status == .running,
              !snapshot.transactions.contains(where: {
                  $0.restorationContext?.originalTransactionID == transactionID && ($0.status == .running || $0.status == .failed)
              }) else {
            throw SyncExecutorError.stateChanged("自动恢复尚未完成，救援资料已保留")
        }
        var installations = snapshot.installations
        for backup in transaction.backups {
            installations.removeAll { $0.destinationPath == backup.destinationPath }
            if let previous = backup.previousInstallation { installations.append(previous) }
        }
        transaction.status = .rolledBack
        transaction.completedAt = Date()
        transaction.errors.append(reason)
        do {
            return try await performRestoration(completion: transaction, store: store,
                installations: installations, assignments: snapshot.assignments)
        } catch {
            var failed = await store.currentSnapshot().transactions.first { $0.id == transactionID } ?? transaction
            failed.status = .failed
            failed.completedAt = Date()
            failed.errors.append("自动恢复未完成：\(error.localizedDescription)")
            try await store.recordTransaction(failed)
            throw SyncExecutorError.stateChanged("自动恢复未完成，救援资料已保留，请查看「设置 → 操作记录与恢复」")
        }
    }

    public func recoverInterruptedTransactions(store: LibraryStore) async throws -> [SyncTransaction] {
        let snapshot = await store.currentSnapshot()
        let rescueJournals = snapshot.transactions.filter { $0.restorationContext != nil && ($0.status == .running || $0.status == .failed) }
        var recovered: [SyncTransaction] = []
        for journal in rescueJournals where journal.status == .running {
            do {
                let original = try await compensateRestoration(journal, store: store)
                if original.status != .running { recovered.append(original) }
            }
            catch {
                if let original = await store.currentSnapshot().transactions.first(where: { $0.id == journal.restorationContext?.originalTransactionID }) {
                    recovered.append(original)
                }
            }
        }
        let refreshed = await store.currentSnapshot()
        let recoveringOriginals = Set(refreshed.transactions.filter {
            $0.restorationContext != nil && ($0.status == .running || $0.status == .failed)
        }.compactMap { $0.restorationContext?.originalTransactionID })
        let interrupted = refreshed.transactions
            .filter { $0.status == .running && $0.restorationContext == nil && !recoveringOriginals.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }

        for var transaction in interrupted {
            do {
                for backup in transaction.backups.reversed() {
                    let actual = fingerprintIfExists(URL(fileURLWithPath: backup.destinationPath))
                    guard actual == backup.beforeFingerprint || actual == backup.afterFingerprint else {
                        throw SyncExecutorError.undoWouldOverwrite(backup.destinationPath)
                    }
                }
                if let libraryUpdate = transaction.libraryUpdate {
                    let currentRecord = await store.currentSnapshot().skills
                        .first { $0.id == libraryUpdate.previousRecord.id }
                    let currentFingerprint = currentRecord?.fingerprint
                    let contentURL = await store.contentURL(for: libraryUpdate.previousRecord)
                    let actualFingerprint = fingerprintIfExists(contentURL)
                    let allowed = Set([
                        libraryUpdate.previousRecord.fingerprint,
                        libraryUpdate.updatedFingerprint,
                    ])
                    guard currentFingerprint.map(allowed.contains) == true,
                          actualFingerprint.map(allowed.contains) == true
                    else {
                        throw SyncExecutorError.undoWouldOverwrite("SkillBox 中的原件")
                    }
                    if actualFingerprint != libraryUpdate.previousRecord.fingerprint {
                        let archive = contentURL.deletingLastPathComponent()
                            .appendingPathComponent("versions/\(libraryUpdate.previousRecord.fingerprint)")
                        guard fingerprintIfExists(archive) == libraryUpdate.previousRecord.fingerprint else {
                            throw SyncExecutorError.rollbackExpired
                        }
                    }
                }
                let currentSnapshot = await store.currentSnapshot()
                var installations = currentSnapshot.installations
                for backup in transaction.backups {
                    installations.removeAll { $0.destinationPath == backup.destinationPath }
                    if let previous = backup.previousInstallation { installations.append(previous) }
                }
                transaction.status = .rolledBack
                transaction.completedAt = Date()
                transaction.errors.append("应用上次异常退出，SkillBox 已恢复这次未完成的操作")
                transaction = try await performRestoration(completion: transaction, store: store,
                    installations: installations, assignments: currentSnapshot.assignments)
            } catch {
                transaction.status = .failed
                transaction.errors.append("启动恢复失败：\(error.localizedDescription)")
            }
            transaction.completedAt = Date()
            try await store.recordTransaction(transaction)
            recovered.append(transaction)
        }
        return recovered
    }

    public func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        guard var transaction = snapshot.transactions.first(where: { $0.id == transactionID }) else { throw SyncExecutorError.transactionNotFound }
        guard transaction.canRestore() else { throw SyncExecutorError.rollbackExpired }
        let transactionRoot = store.transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
        // Verify every restore source before touching even the first destination.
        for backup in transaction.backups {
            if let relative = backup.backupRelativePath {
                guard let expected = backup.beforeFingerprint,
                      fingerprintIfExists(transactionRoot.appendingPathComponent(relative)) == expected else {
                    throw SyncExecutorError.rollbackExpired
                }
            }
        }
        if let libraryUpdate = transaction.libraryUpdate {
            let previous = libraryUpdate.previousRecord
            let contentPath = snapshot.skills.first { $0.id == previous.id }?.contentRelativePath ?? previous.contentRelativePath
            let archive = store.root.appendingPathComponent(contentPath)
                .deletingLastPathComponent().appendingPathComponent("versions/\(previous.fingerprint)")
            guard fingerprintIfExists(archive) == previous.fingerprint else { throw SyncExecutorError.rollbackExpired }
            guard snapshot.skills.first(where: { $0.id == libraryUpdate.previousRecord.id })?.fingerprint == libraryUpdate.updatedFingerprint,
                  fingerprintIfExists(store.root.appendingPathComponent(contentPath)) == libraryUpdate.updatedFingerprint else {
                throw SyncExecutorError.undoWouldOverwrite("SkillBox 中的原件")
            }
            if let expectedVersion = libraryUpdate.updatedSourceVersionIdentifier,
               snapshot.sourceStates.first(where: { $0.skillID == libraryUpdate.previousRecord.id })?.currentVersionIdentifier != expectedVersion
            {
                throw SyncExecutorError.undoWouldOverwrite("GitHub 更新记录")
            }
            if let expectedFingerprint = libraryUpdate.updatedLocalSourceFingerprint,
               snapshot.localSourceStates.first(where: { $0.skillID == libraryUpdate.previousRecord.id })?.currentPackageFingerprint != expectedFingerprint
            {
                throw SyncExecutorError.undoWouldOverwrite("本地开发源更新记录")
            }
        }
        for backup in transaction.backups.reversed() {
            let destination = URL(fileURLWithPath: backup.destinationPath)
            guard fingerprintIfExists(destination) == backup.afterFingerprint else {
                transaction.status = .undoBlocked
                transaction.errors.append(SyncExecutorError.undoWouldOverwrite(destination.path).localizedDescription)
                try await store.recordTransaction(transaction)
                throw SyncExecutorError.undoWouldOverwrite(destination.path)
            }
        }
        var installations = snapshot.installations
        for backup in transaction.backups {
            installations.removeAll { $0.destinationPath == backup.destinationPath }
            if let previous = backup.previousInstallation { installations.append(previous) }
        }
        var assignments = snapshot.assignments
        for backup in transaction.backups {
            guard let action = transaction.actions.first(where: { $0.destinationPath == backup.destinationPath }) else { continue }
            let restoredDesiredState: Bool?
            switch backup.actionKind {
            case .remove:
                restoredDesiredState = true
            case .create, .takeover:
                restoredDesiredState = false
            case .update where backup.previousInstallation == nil:
                restoredDesiredState = false
            default:
                restoredDesiredState = nil
            }
            guard let restoredDesiredState else { continue }
            if let index = assignments.firstIndex(where: {
                $0.skillID == action.skillID && $0.targetID == action.targetID
            }) {
                assignments[index].isDesired = restoredDesiredState
                if !restoredDesiredState {
                    assignments[index].allowTakeover = false
                    assignments[index].allowReplacement = false
                    assignments[index].authorizedDestinationFingerprint = nil
                }
            } else if restoredDesiredState {
                assignments.append(.init(
                    skillID: action.skillID,
                    targetID: action.targetID,
                    installationDirectoryName: URL(fileURLWithPath: action.destinationPath).lastPathComponent
                ))
            }
        }
        transaction.status = .undone
        transaction.completedAt = Date()
        return try await performRestoration(completion: transaction, store: store, installations: installations, assignments: assignments)
    }

    private func performRestoration(completion: SyncTransaction, store: LibraryStore,
                                    installations: [ManagedInstallation], assignments: [Assignment]) async throws -> SyncTransaction {
        let before = await store.currentSnapshot()
        guard let original = before.transactions.first(where: { $0.id == completion.id }) else { throw SyncExecutorError.transactionNotFound }
        var rescue = SyncTransaction(status: .running, actions: [])
        let stagedPaths = original.backups.map {
            URL(fileURLWithPath: $0.destinationPath).deletingLastPathComponent()
                .appendingPathComponent(".skillbox-restore-\(UUID())").path
        }
        rescue.restorationContext = .init(originalTransactionID: original.id, originalStatus: original.status,
            originalCompletedAt: original.completedAt, originalErrors: original.errors,
            originalBackupsExpiredAt: original.backupsExpiredAt, installations: before.installations,
            assignments: before.assignments, stagedPaths: stagedPaths)
        for (index, backup) in original.backups.enumerated() {
            let current = fingerprintIfExists(URL(fileURLWithPath: backup.destinationPath))
            rescue.backups.append(.init(destinationPath: backup.destinationPath,
                backupRelativePath: current == nil ? nil : "backups/\(index)-current", beforeFingerprint: current,
                afterFingerprint: backup.beforeFingerprint, actionKind: .update,
                previousInstallation: before.installations.first { $0.destinationPath == backup.destinationPath }))
        }
        if let update = original.libraryUpdate,
           var current = before.skills.first(where: { $0.id == update.previousRecord.id }) {
            // A crash may have replaced content just before saving its catalog.
            // The rescue copy describes the bytes actually present at entry.
            if let actual = fingerprintIfExists(await store.contentURL(for: current)) { current.fingerprint = actual }
            rescue.libraryUpdate = .init(previousRecord: current, updatedFingerprint: update.previousRecord.fingerprint,
                previousSourceState: before.sourceStates.first { $0.skillID == current.id },
                updatedSourceVersionIdentifier: update.updatedSourceVersionIdentifier,
                previousLocalSourceState: before.localSourceStates.first { $0.skillID == current.id },
                updatedLocalSourceFingerprint: update.updatedLocalSourceFingerprint)
        }
        if rescue.libraryUpdate != nil {
            rescue.restorationContext?.centralStagedPath = store.libraryDirectory.appendingPathComponent(".restore-\(rescue.id)").path
        }
        try await store.recordTransaction(rescue)
        let rescueRoot = store.transactionsDirectory.appendingPathComponent(rescue.id.uuidString)
        do {
            try fileManager.createDirectory(at: rescueRoot.appendingPathComponent("backups"), withIntermediateDirectories: true)
            for backup in rescue.backups {
                if let relative = backup.backupRelativePath, let expected = backup.beforeFingerprint {
                    let copy = rescueRoot.appendingPathComponent(relative)
                    try SafeFileOperations.copyDirectory(from: URL(fileURLWithPath: backup.destinationPath), to: copy, fileManager: fileManager)
                    guard fingerprintIfExists(copy) == expected else { throw FileOperationError.fingerprintMismatch }
                }
            }
            if let libraryUpdate = rescue.libraryUpdate { try await store.prepareRestorationRescue(libraryUpdate) }
            let originalRoot = store.transactionsDirectory.appendingPathComponent(original.id.uuidString)
            try prepareRestorationTargets(original, transactionRoot: originalRoot, stagedPaths: stagedPaths)
            for index in original.backups.indices.reversed() {
                try applyPreparedRestore(original.backups[index], staged: URL(fileURLWithPath: stagedPaths[index]), notify: true)
            }
            if let update = original.libraryUpdate {
                _ = try await store.restoreSkillVersion(update,
                    stagingURL: rescue.restorationContext?.centralStagedPath.map { URL(fileURLWithPath: $0) }, retainExchangedContent: true)
                try await store.restoreGitHubSourceState(update)
                try await store.restoreLocalSourceState(update)
            }
            rescue.status = .rolledBack
            rescue.completedAt = Date()
            try await store.finishRestoration(original: completion, rescue: rescue, installations: installations, assignments: assignments)
            return completion
        } catch {
            let failure = error
            do { _ = try await compensateRestoration(rescue, store: store) }
            catch { throw SyncExecutorError.stateChanged("恢复未完成，救援资料已保留，请查看「设置 → 操作记录与恢复」") }
            throw failure
        }
    }

    private func compensateRestoration(_ initial: SyncTransaction, store: LibraryStore) async throws -> SyncTransaction {
        var rescue = initial
        guard let context = rescue.restorationContext,
              var original = await store.currentSnapshot().transactions.first(where: { $0.id == context.originalTransactionID }) else {
            throw SyncExecutorError.transactionNotFound
        }
        var failures: [String] = []
        // Each registered stage contains either the desired copy or the actual
        // exchanged current copy. Only restore a destination still matching us.
        for index in rescue.backups.indices.reversed() {
            let backup = rescue.backups[index]
            do {
                let destination = URL(fileURLWithPath: backup.destinationPath)
                let actual = fingerprintIfExists(destination)
                if actual == backup.beforeFingerprint { continue }
                guard actual == backup.afterFingerprint else { throw SyncExecutorError.undoWouldOverwrite(backup.destinationPath) }
                let staged = URL(fileURLWithPath: context.stagedPaths[index])
                if let expected = backup.beforeFingerprint, fingerprintIfExists(staged) != expected {
                    // An absent stage can be rebuilt from the separately saved
                    // rescue copy; an unexpected existing stage is preserved.
                    guard !fileManager.fileExists(atPath: staged.path), let relative = backup.backupRelativePath else {
                        throw SyncExecutorError.undoWouldOverwrite(staged.path)
                    }
                    let source = store.transactionsDirectory.appendingPathComponent("\(rescue.id)/\(relative)")
                    guard fingerprintIfExists(source) == expected else { throw SyncExecutorError.rollbackExpired }
                    try SafeFileOperations.copyDirectory(from: source, to: staged, fileManager: fileManager)
                    guard fingerprintIfExists(staged) == expected else { throw FileOperationError.fingerprintMismatch }
                }
                try applyPreparedRestore(backup, staged: staged, notify: false)
            } catch { failures.append(error.localizedDescription) }
        }
        if let update = rescue.libraryUpdate {
            do {
                _ = try await store.restoreSkillVersion(update,
                    stagingURL: context.centralStagedPath.map { URL(fileURLWithPath: $0) }, retainExchangedContent: true)
                try await store.restoreGitHubSourceState(update)
                try await store.restoreLocalSourceState(update)
            } catch { failures.append(error.localizedDescription) }
        }
        if failures.isEmpty {
            original.status = context.originalStatus
            original.completedAt = context.originalCompletedAt
            original.errors = context.originalErrors
            original.backupsExpiredAt = context.originalBackupsExpiredAt
            rescue.status = .rolledBack
            rescue.completedAt = Date()
            do {
                try await store.finishRestoration(original: original, rescue: rescue,
                    installations: context.installations, assignments: context.assignments)
                return original
            } catch { failures.append(error.localizedDescription) }
        }
        rescue.status = .failed
        rescue.errors.append(contentsOf: failures)
        original.status = .failed
        original.errors.append("恢复补偿未完成，救援资料已保留：" + failures.joined(separator: "；"))
        try await store.recordTransaction(rescue)
        try await store.recordTransaction(original)
        throw SyncExecutorError.stateChanged("恢复补偿未完成，救援资料已保留")
    }

    private func prepareRestorationTargets(_ transaction: SyncTransaction, transactionRoot: URL, stagedPaths: [String]) throws {
        for backup in transaction.backups {
            let destination = URL(fileURLWithPath: backup.destinationPath)
            let actual = fingerprintIfExists(destination)
            guard (!fileManager.fileExists(atPath: destination.path) || actual != nil),
                  actual == backup.beforeFingerprint || actual == backup.afterFingerprint else {
                throw SyncExecutorError.undoWouldOverwrite(backup.destinationPath)
            }
            if actual != backup.beforeFingerprint { try validateRestoreSource(backup: backup, transactionRoot: transactionRoot) }
        }
        for (index, backup) in transaction.backups.enumerated() {
            if fingerprintIfExists(URL(fileURLWithPath: backup.destinationPath)) == backup.beforeFingerprint { continue }
            if let relative = backup.backupRelativePath, let expected = backup.beforeFingerprint {
                let staged = URL(fileURLWithPath: stagedPaths[index])
                try SafeFileOperations.copyDirectory(from: transactionRoot.appendingPathComponent(relative), to: staged, fileManager: fileManager)
                guard fingerprintIfExists(staged) == expected else { throw FileOperationError.fingerprintMismatch }
            }
        }
    }

    private func applyPreparedRestore(_ backup: TransactionBackup, staged: URL, notify: Bool) throws {
        let destination = URL(fileURLWithPath: backup.destinationPath)
        let actual = fingerprintIfExists(destination)
        guard !fileManager.fileExists(atPath: destination.path) || actual != nil else { throw SyncExecutorError.undoWouldOverwrite(destination.path) }
        if actual == backup.beforeFingerprint { return }
        guard actual == backup.afterFingerprint else { throw SyncExecutorError.undoWouldOverwrite(destination.path) }
        if let expected = backup.beforeFingerprint {
            guard fingerprintIfExists(staged) == expected else { throw SyncExecutorError.rollbackExpired }
        } else if fileManager.fileExists(atPath: staged.path) {
            throw SyncExecutorError.undoWouldOverwrite(staged.path)
        }
        if notify { beforeDestinationMutation(destination) }
        if actual != nil, backup.beforeFingerprint != nil {
            try atomicRename(from: destination, to: staged, flags: UInt32(RENAME_SWAP))
            guard fingerprintIfExists(staged) == actual else {
                _ = try? atomicRename(from: destination, to: staged, flags: UInt32(RENAME_SWAP))
                throw SyncExecutorError.undoWouldOverwrite(destination.path)
            }
        } else if backup.beforeFingerprint == nil {
            try atomicRename(from: destination, to: staged, flags: UInt32(RENAME_EXCL))
            guard fingerprintIfExists(staged) == actual else {
                if !fileManager.fileExists(atPath: destination.path) { _ = try? atomicRename(from: staged, to: destination, flags: UInt32(RENAME_EXCL)) }
                throw SyncExecutorError.undoWouldOverwrite(destination.path)
            }
        } else {
            try atomicRename(from: staged, to: destination, flags: UInt32(RENAME_EXCL))
        }
    }

    private func validateRestoreSource(backup: TransactionBackup, transactionRoot: URL) throws {
        if let expected = backup.beforeFingerprint {
            guard let relative = backup.backupRelativePath,
                  fingerprintIfExists(transactionRoot.appendingPathComponent(relative)) == expected else {
                throw SyncExecutorError.rollbackExpired
            }
        } else if backup.backupRelativePath != nil {
            throw SyncExecutorError.rollbackExpired
        }
    }

    private func fingerprintIfExists(_ url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? fingerprinter.fingerprint(directory: url)
    }

    private func requireExistingWritableParent(of destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: parent.path)
        else {
            throw SyncExecutorError.targetUnavailable(parent.path)
        }
    }

    private func replaceExistingDirectoryAtomically(
        destination: URL,
        staged: URL,
        expectedBeforeFingerprint: String
    ) throws {
        do {
            try atomicRename(from: destination, to: staged, flags: UInt32(RENAME_SWAP))
        } catch {
            throw SyncExecutorError.stateChanged(destination.path)
        }

        guard fingerprintIfExists(staged) == expectedBeforeFingerprint else {
            if (try? atomicRename(from: destination, to: staged, flags: UInt32(RENAME_SWAP))) != nil {
                try? fileManager.removeItem(at: staged)
            }
            throw SyncExecutorError.stateChanged(destination.path)
        }
        try fileManager.removeItem(at: staged)
    }

    private func removeExistingDirectoryAtomically(
        destination: URL,
        expectedBeforeFingerprint: String
    ) throws {
        let preserved = destination.deletingLastPathComponent()
            .appendingPathComponent(".skillbox-remove-\(UUID().uuidString)")
        do {
            try atomicRename(from: destination, to: preserved, flags: UInt32(RENAME_EXCL))
        } catch {
            throw SyncExecutorError.stateChanged(destination.path)
        }

        guard fingerprintIfExists(preserved) == expectedBeforeFingerprint else {
            if !fileManager.fileExists(atPath: destination.path) {
                try? atomicRename(from: preserved, to: destination, flags: UInt32(RENAME_EXCL))
            }
            throw SyncExecutorError.stateChanged(destination.path)
        }
        try fileManager.removeItem(at: preserved)
    }

    private func atomicRename(from source: URL, to destination: URL, flags: UInt32) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
