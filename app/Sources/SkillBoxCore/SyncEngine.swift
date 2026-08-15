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
                    actions.append(blocked(assignment, path: destination.path, reason: .externalModification, summary: "安装后的内容被其他软件改过")); continue
                }
                let kind: SyncActionKind = current == skill.fingerprint ? .noChange : .update
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
    func execute(plan: SyncPlan, store: LibraryStore) async throws -> SyncTransaction
    func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction
}

public enum SyncExecutorError: LocalizedError {
    case planContainsBlockedActions
    case stateChanged(String)
    case transactionNotFound
    case undoWouldOverwrite(String)
    case targetUnavailable(String)
    case injectedFailure

    public var errorDescription: String? {
        switch self {
        case .planContainsBlockedActions: "安装列表中还有需要先处理的问题"
        case let .stateChanged(path): "你确认后，文件又发生了变化。SkillBox 已停下：\(path)"
        case .transactionNotFound: "找不到这次操作记录"
        case let .undoWouldOverwrite(path): "文件在安装后又被改过。为了保护新内容，暂时不能恢复：\(path)"
        case let .targetUnavailable(path): "应用的 Skills 文件夹不存在或无法写入，SkillBox 不会代为创建：\(path)"
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
                if [.create, .update, .takeover].contains(action.kind) {
                    try requireExistingWritableParent(of: destination)
                }
                let backupName = "\(index)-\(destination.lastPathComponent)"
                let backup = backupRoot.appendingPathComponent(backupName)
                if current != nil { try SafeFileOperations.copyDirectory(from: destination, to: backup, fileManager: fileManager) }

                switch action.kind {
                case .create, .update:
                    guard let skill = skills[action.skillID] else { throw SyncExecutorError.stateChanged(destination.path) }
                    let source = await store.contentURL(for: skill)
                    guard try fingerprinter.fingerprint(directory: source) == action.expectedSourceFingerprint else { throw SyncExecutorError.stateChanged(source.path) }
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
            throw transaction.status == .failed ? SyncExecutorError.stateChanged("自动恢复没有完成，请查看「最近操作」") : error
        }
    }

    public func undo(transactionID: UUID, store: LibraryStore) async throws -> SyncTransaction {
        let snapshot = await store.currentSnapshot()
        guard var transaction = snapshot.transactions.first(where: { $0.id == transactionID }) else { throw SyncExecutorError.transactionNotFound }
        let transactionRoot = store.transactionsDirectory.appendingPathComponent(transaction.id.uuidString)
        if let libraryUpdate = transaction.libraryUpdate {
            guard snapshot.skills.first(where: { $0.id == libraryUpdate.previousRecord.id })?.fingerprint == libraryUpdate.updatedFingerprint else {
                throw SyncExecutorError.undoWouldOverwrite("SkillBox 中的原件")
            }
            if let expectedVersion = libraryUpdate.updatedSourceVersionIdentifier,
               snapshot.sourceStates.first(where: { $0.skillID == libraryUpdate.previousRecord.id })?.currentVersionIdentifier != expectedVersion
            {
                throw SyncExecutorError.undoWouldOverwrite("GitHub 更新记录")
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
        for backup in transaction.backups.reversed() { try restore(backup: backup, transactionRoot: transactionRoot) }
        if let libraryUpdate = transaction.libraryUpdate {
            _ = try await store.restoreSkillVersion(libraryUpdate)
            try await store.restoreGitHubSourceState(libraryUpdate)
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
}
