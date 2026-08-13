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
                actions.append(blocked(assignment, path: "", reason: .missingSkill, summary: "中央原件不存在")); continue
            }
            guard let target = targets[assignment.targetID] else {
                actions.append(blocked(assignment, path: "", reason: .missingTarget, summary: "Agent 目标不存在")); continue
            }
            let destination = URL(fileURLWithPath: target.path).appendingPathComponent(assignment.installationDirectoryName).standardizedFileURL
            desiredDestinations.insert(destination.path)
            guard destination.deletingLastPathComponent().path == URL(fileURLWithPath: target.path).standardizedFileURL.path else {
                actions.append(blocked(assignment, path: destination.path, reason: .invalidDestination, summary: "安装目录名越界")); continue
            }
            guard !skill.riskReport.isBlocked else {
                actions.append(blocked(assignment, path: destination.path, reason: .sourceBlocked, summary: "中央原件含有阻断风险")); continue
            }
            if target.writeStatus == .readOnly {
                actions.append(blocked(assignment, path: destination.path, reason: .targetReadOnly, summary: "目标目录只读")); continue
            }

            let current = currentFingerprint(destination)
            if let managed = managedByDestination[destination.path] {
                guard current == managed.deployedFingerprint else {
                    actions.append(blocked(assignment, path: destination.path, reason: .externalModification, summary: "目标副本已被外部修改")); continue
                }
                let kind: SyncActionKind = current == skill.fingerprint ? .noChange : .update
                actions.append(.init(kind: kind, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: kind == .update ? "更新 \(skill.displayName)" : "状态一致"))
            } else if let current {
                let authorizationMatches = assignment.authorizedDestinationFingerprint == current
                if current == skill.fingerprint, assignment.allowTakeover, authorizationMatches {
                    actions.append(.init(kind: .takeover, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: "接管相同副本"))
                } else if current != skill.fingerprint, assignment.allowReplacement, authorizationMatches {
                    actions.append(.init(kind: .update, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, expectedDestinationFingerprint: current, summary: "明确替换未管理副本"))
                } else {
                    actions.append(blocked(assignment, path: destination.path, reason: .unmanagedConflict, summary: current == skill.fingerprint ? "相同副本尚未授权接管" : "存在未管理的同名目录"))
                }
            } else {
                actions.append(.init(kind: .create, skillID: skill.id, targetID: target.id, destinationPath: destination.path, expectedSourceFingerprint: skill.fingerprint, summary: "安装 \(skill.displayName)"))
            }
        }

        for installation in snapshot.installations where !desiredDestinations.contains(installation.destinationPath) {
            let current = currentFingerprint(URL(fileURLWithPath: installation.destinationPath))
            if current == installation.deployedFingerprint {
                actions.append(.init(kind: .remove, skillID: installation.skillID, targetID: installation.targetID, destinationPath: installation.destinationPath, expectedDestinationFingerprint: current, summary: "移除已管理副本"))
            } else {
                actions.append(.init(kind: .blocked, skillID: installation.skillID, targetID: installation.targetID, destinationPath: installation.destinationPath, expectedDestinationFingerprint: installation.deployedFingerprint, blockReason: .externalModification, summary: "外部改动阻止移除"))
            }
        }
        return SyncPlan(actions: actions.sorted { $0.destinationPath < $1.destinationPath })
    }

    private func currentFingerprint(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? fingerprinter.fingerprint(directory: url)
    }

    private func blocked(_ assignment: Assignment, path: String, reason: SyncBlockReason, summary: String) -> SyncAction {
        .init(kind: .blocked, skillID: assignment.skillID, targetID: assignment.targetID, destinationPath: path, blockReason: reason, summary: summary)
    }
}

public protocol SyncExecutor: Sendable {
    func execute(plan: SyncPlan, store: LibraryStore) async throws -> SyncTransaction
    func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction
}

public enum SyncExecutorError: LocalizedError {
    case planContainsBlockedActions
    case stateChanged(String)
    case transactionNotFound
    case undoWouldOverwrite(String)
    case injectedFailure

    public var errorDescription: String? {
        switch self {
        case .planContainsBlockedActions: "同步计划包含阻塞项"
        case let .stateChanged(path): "预览后目标状态发生变化：\(path)"
        case .transactionNotFound: "找不到对应事务"
        case let .undoWouldOverwrite(path): "撤销会覆盖外部改动，已暂停：\(path)"
        case .injectedFailure: "测试注入的写入中断"
        }
    }
}

public actor TransactionalSyncExecutor: SyncExecutor {
    private let fileManager: FileManager
    private let fingerprinter: any SkillFingerprinting
    private let shouldInjectFailure: @Sendable (Int) -> Bool

    public init(fileManager: FileManager = .default, fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter()) {
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        shouldInjectFailure = { _ in false }
    }

    init(
        fileManager: FileManager = .default,
        fingerprinter: any SkillFingerprinting = SHA256SkillFingerprinter(),
        shouldInjectFailure: @escaping @Sendable (Int) -> Bool
    ) {
        self.fileManager = fileManager
        self.fingerprinter = fingerprinter
        self.shouldInjectFailure = shouldInjectFailure
    }

    public func execute(plan: SyncPlan, store: LibraryStore) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        let skills = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0) })
        var installations = snapshot.installations
        var transaction = SyncTransaction(status: .running, actions: plan.actions)
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
                let backupName = "\(index)-\(destination.lastPathComponent)"
                let backup = backupRoot.appendingPathComponent(backupName)
                if current != nil { try SafeFileOperations.copyDirectory(from: destination, to: backup, fileManager: fileManager) }

                switch action.kind {
                case .create, .update:
                    guard let skill = skills[action.skillID] else { throw SyncExecutorError.stateChanged(destination.path) }
                    let source = await store.contentURL(for: skill)
                    guard try fingerprinter.fingerprint(directory: source) == action.expectedSourceFingerprint else { throw SyncExecutorError.stateChanged(source.path) }
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let staged = destination.deletingLastPathComponent().appendingPathComponent(".skillbox-\(UUID().uuidString)")
                    try SafeFileOperations.copyDirectory(from: source, to: staged, fileManager: fileManager)
                    guard try fingerprinter.fingerprint(directory: staged) == action.expectedSourceFingerprint else { throw FileOperationError.fingerprintMismatch }
                    if fileManager.fileExists(atPath: destination.path) { _ = try fileManager.replaceItemAt(destination, withItemAt: staged) }
                    else { try fileManager.moveItem(at: staged, to: destination) }
                case .remove:
                    try fileManager.removeItem(at: destination)
                case .takeover:
                    break
                default:
                    break
                }

                let after = fingerprintIfExists(destination)
                transaction.backups.append(.init(destinationPath: destination.path, backupRelativePath: current == nil ? nil : "backups/\(backupName)", beforeFingerprint: current, afterFingerprint: after, actionKind: action.kind, previousInstallation: previousInstallation))
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
                try rollback(transaction: transaction, transactionRoot: transactionRoot)
                transaction.status = .rolledBack
            } catch {
                transaction.errors.append("恢复失败：\(error.localizedDescription)")
                transaction.status = .failed
            }
            transaction.completedAt = Date()
            try await store.recordTransaction(transaction)
            throw transaction.status == .failed ? SyncExecutorError.stateChanged("自动恢复失败，请查看事务记录") : error
        }
    }

    public func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        guard var transaction = snapshot.transactions.first(where: { $0.id == transactionID }) else { throw SyncExecutorError.transactionNotFound }
        let transactionRoot = store.transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
        for backup in transaction.backups.reversed() {
            let destination = URL(fileURLWithPath: backup.destinationPath)
            guard fingerprintIfExists(destination) == backup.afterFingerprint else {
                transaction.status = .undoBlocked
                transaction.errors.append(SyncExecutorError.undoWouldOverwrite(destination.path).localizedDescription)
                try await store.recordTransaction(transaction)
                throw SyncExecutorError.undoWouldOverwrite(destination.path)
            }
            try restore(backup: backup, transactionRoot: transactionRoot)
        }
        var installations = snapshot.installations
        for backup in transaction.backups {
            installations.removeAll { $0.destinationPath == backup.destinationPath }
            if let previous = backup.previousInstallation { installations.append(previous) }
        }
        transaction.status = .undone
        transaction.completedAt = Date()
        try await store.replaceInstallations(installations)
        try await store.recordTransaction(transaction)
        return transaction
    }

    private func rollback(transaction: SyncTransaction, transactionRoot: URL) throws {
        for backup in transaction.backups.reversed() { try restore(backup: backup, transactionRoot: transactionRoot) }
    }

    private func restore(backup: TransactionBackup, transactionRoot: URL) throws {
        let destination = URL(fileURLWithPath: backup.destinationPath)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        if let relative = backup.backupRelativePath {
            try SafeFileOperations.copyDirectory(from: transactionRoot.appendingPathComponent(relative), to: destination, fileManager: fileManager)
        }
    }

    private func fingerprintIfExists(_ url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? fingerprinter.fingerprint(directory: url)
    }
}
