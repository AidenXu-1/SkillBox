import Foundation

public enum SkillBoxSchema {
    public static let currentVersion = 1
}

public struct PersistedEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: Int
    public var value: Value

    public init(schemaVersion: Int = SkillBoxSchema.currentVersion, value: Value) {
        self.schemaVersion = schemaVersion
        self.value = value
    }
}

public enum SkillSourceKind: String, Codable, CaseIterable, Sendable {
    case agentDirectory
    case localFolder
    case github
}

public struct SkillSource: Codable, Hashable, Sendable {
    public var kind: SkillSourceKind
    public var displayName: String
    public var locator: String
    public var repository: String?
    public var revision: String?
    public var skillPath: String?

    public init(
        kind: SkillSourceKind,
        displayName: String,
        locator: String,
        repository: String? = nil,
        revision: String? = nil,
        skillPath: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.locator = locator
        self.repository = repository
        self.revision = revision
        self.skillPath = skillPath
    }
}

public enum RiskSeverity: Int, Codable, CaseIterable, Comparable, Sendable {
    case info = 0
    case caution = 1
    case high = 2
    case blocked = 3

    public static func < (lhs: RiskSeverity, rhs: RiskSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum RiskCategory: String, Codable, Sendable {
    case invalidFormat
    case executableFile
    case binaryFile
    case oversizedFile
    case symlink
    case pathEscape
    case network
    case privilege
    case deletion
    case credentialAccess
    case dynamicExecution
}

public struct RiskFinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var severity: RiskSeverity
    public var category: RiskCategory
    public var relativePath: String
    public var title: String
    public var evidence: String

    public init(
        id: UUID = UUID(),
        severity: RiskSeverity,
        category: RiskCategory,
        relativePath: String,
        title: String,
        evidence: String
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.relativePath = relativePath
        self.title = title
        self.evidence = evidence
    }
}

public struct RiskReport: Codable, Hashable, Sendable {
    public var scannedFileCount: Int
    public var findings: [RiskFinding]

    public init(scannedFileCount: Int, findings: [RiskFinding]) {
        self.scannedFileCount = scannedFileCount
        self.findings = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    public var highestSeverity: RiskSeverity {
        findings.map(\.severity).max() ?? .info
    }

    public var isBlocked: Bool {
        findings.contains { $0.severity == .blocked }
    }
}

public struct SkillRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var canonicalName: String
    public var displayName: String
    public var description: String
    public var fingerprint: String
    public var source: SkillSource
    public var riskReport: RiskReport
    public var contentRelativePath: String
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        canonicalName: String,
        displayName: String,
        description: String,
        fingerprint: String,
        source: SkillSource,
        riskReport: RiskReport,
        contentRelativePath: String,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.description = description
        self.fingerprint = fingerprint
        self.source = source
        self.riskReport = riskReport
        self.contentRelativePath = contentRelativePath
        self.importedAt = importedAt
    }
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode
    case cursor
    case kimiCode
    case zcode
    case workBuddy
    case hanaAgent
    case geminiCLI
    case openCode
    case custom
}

public enum TargetDetectionStatus: String, Codable, Sendable {
    case available
    case directoryMissing
    case unreadable
}

public enum TargetWriteStatus: String, Codable, Sendable {
    case writable
    case directoryMissing
    case readOnly
}

public struct AgentTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AgentKind
    public var displayName: String
    public var path: String
    public var detectionStatus: TargetDetectionStatus
    public var writeStatus: TargetWriteStatus
    public var isCustom: Bool

    public init(
        id: UUID = UUID(),
        kind: AgentKind,
        displayName: String,
        path: String,
        detectionStatus: TargetDetectionStatus = .directoryMissing,
        writeStatus: TargetWriteStatus = .directoryMissing,
        isCustom: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.detectionStatus = detectionStatus
        self.writeStatus = writeStatus
        self.isCustom = isCustom
    }
}

public struct Assignment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var skillID: UUID
    public var targetID: UUID
    public var installationDirectoryName: String
    public var isDesired: Bool
    public var allowTakeover: Bool
    public var allowReplacement: Bool
    public var authorizedDestinationFingerprint: String?

    public init(
        id: UUID = UUID(),
        skillID: UUID,
        targetID: UUID,
        installationDirectoryName: String,
        isDesired: Bool = true,
        allowTakeover: Bool = false,
        allowReplacement: Bool = false,
        authorizedDestinationFingerprint: String? = nil
    ) {
        self.id = id
        self.skillID = skillID
        self.targetID = targetID
        self.installationDirectoryName = installationDirectoryName
        self.isDesired = isDesired
        self.allowTakeover = allowTakeover
        self.allowReplacement = allowReplacement
        self.authorizedDestinationFingerprint = authorizedDestinationFingerprint
    }
}

public enum SyncActionKind: String, Codable, Sendable {
    case create
    case update
    case remove
    case takeover
    case noChange
    case blocked
}

public enum SyncBlockReason: String, Codable, Sendable {
    case missingSkill
    case missingTarget
    case targetUnavailable
    case targetReadOnly
    case unmanagedConflict
    case externalModification
    case invalidDestination
    case sourceBlocked
}

public struct SyncAction: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SyncActionKind
    public var skillID: UUID
    public var targetID: UUID
    public var destinationPath: String
    public var expectedSourceFingerprint: String?
    public var expectedDestinationFingerprint: String?
    public var blockReason: SyncBlockReason?
    public var summary: String

    public init(
        id: UUID = UUID(),
        kind: SyncActionKind,
        skillID: UUID,
        targetID: UUID,
        destinationPath: String,
        expectedSourceFingerprint: String? = nil,
        expectedDestinationFingerprint: String? = nil,
        blockReason: SyncBlockReason? = nil,
        summary: String
    ) {
        self.id = id
        self.kind = kind
        self.skillID = skillID
        self.targetID = targetID
        self.destinationPath = destinationPath
        self.expectedSourceFingerprint = expectedSourceFingerprint
        self.expectedDestinationFingerprint = expectedDestinationFingerprint
        self.blockReason = blockReason
        self.summary = summary
    }
}

public struct SyncPlan: Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var actions: [SyncAction]

    public init(id: UUID = UUID(), createdAt: Date = Date(), actions: [SyncAction]) {
        self.id = id
        self.createdAt = createdAt
        self.actions = actions
    }

    public var executableActions: [SyncAction] {
        actions.filter { [.create, .update, .remove, .takeover].contains($0.kind) }
    }

    public var blockedActions: [SyncAction] {
        actions.filter { $0.kind == .blocked }
    }
}

public enum TransactionStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case rolledBack
    case undone
    case undoBlocked
}

public struct TransactionBackup: Codable, Hashable, Sendable {
    public var destinationPath: String
    public var backupRelativePath: String?
    public var beforeFingerprint: String?
    public var afterFingerprint: String?
    public var actionKind: SyncActionKind
    public var previousInstallation: ManagedInstallation?

    public init(
        destinationPath: String,
        backupRelativePath: String?,
        beforeFingerprint: String?,
        afterFingerprint: String?,
        actionKind: SyncActionKind,
        previousInstallation: ManagedInstallation? = nil
    ) {
        self.destinationPath = destinationPath
        self.backupRelativePath = backupRelativePath
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.actionKind = actionKind
        self.previousInstallation = previousInstallation
    }
}

public struct SyncTransaction: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var completedAt: Date?
    public var status: TransactionStatus
    public var actions: [SyncAction]
    public var backups: [TransactionBackup]
    public var errors: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        status: TransactionStatus,
        actions: [SyncAction],
        backups: [TransactionBackup] = [],
        errors: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.status = status
        self.actions = actions
        self.backups = backups
        self.errors = errors
    }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var skills: [SkillRecord]
    public var targets: [AgentTarget]
    public var assignments: [Assignment]
    public var installations: [ManagedInstallation]
    public var transactions: [SyncTransaction]
    public var organization: SkillOrganization

    public init(
        skills: [SkillRecord] = [],
        targets: [AgentTarget] = [],
        assignments: [Assignment] = [],
        installations: [ManagedInstallation] = [],
        transactions: [SyncTransaction] = [],
        organization: SkillOrganization = .init()
    ) {
        self.skills = skills
        self.targets = targets
        self.assignments = assignments
        self.installations = installations
        self.transactions = transactions
        self.organization = organization
    }
}

public struct SkillFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, sortIndex: Int) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}

public struct SkillPlacement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { skillID }
    public var skillID: UUID
    public var folderID: UUID?
    public var sortIndex: Int

    public init(skillID: UUID, folderID: UUID? = nil, sortIndex: Int) {
        self.skillID = skillID
        self.folderID = folderID
        self.sortIndex = sortIndex
    }
}

public struct SkillOrganization: Codable, Hashable, Sendable {
    public var folders: [SkillFolder]
    public var placements: [SkillPlacement]

    public init(folders: [SkillFolder] = [], placements: [SkillPlacement] = []) {
        self.folders = folders
        self.placements = placements
    }

    public mutating func normalize(skillIDs: [UUID]) {
        let validSkillIDs = Set(skillIDs)
        let validFolderIDs = Set(folders.map(\.id))
        var seen = Set<UUID>()
        placements = placements.filter { placement in
            validSkillIDs.contains(placement.skillID) &&
                (placement.folderID == nil || validFolderIDs.contains(placement.folderID!)) &&
                seen.insert(placement.skillID).inserted
        }
        for skillID in skillIDs where !seen.contains(skillID) {
            placements.append(.init(skillID: skillID, sortIndex: placements.filter { $0.folderID == nil }.count))
        }
        reindexFolders()
        reindexAllGroups()
    }

    public mutating func moveSkill(_ skillID: UUID, to folderID: UUID?, before beforeSkillID: UUID? = nil) {
        guard folderID == nil || folders.contains(where: { $0.id == folderID }) else { return }
        var moved = placements.first(where: { $0.skillID == skillID }) ?? .init(skillID: skillID, sortIndex: 0)
        placements.removeAll { $0.skillID == skillID }
        moved.folderID = folderID
        var destination = placements.filter { $0.folderID == folderID }.sorted { $0.sortIndex < $1.sortIndex }
        let insertionIndex = beforeSkillID.flatMap { before in destination.firstIndex { $0.skillID == before } } ?? destination.endIndex
        destination.insert(moved, at: insertionIndex)
        placements.append(moved)
        for (index, placement) in destination.enumerated() {
            if let storedIndex = placements.firstIndex(where: { $0.skillID == placement.skillID }) {
                placements[storedIndex].folderID = folderID
                placements[storedIndex].sortIndex = index
            }
        }
        reindexAllGroups()
    }

    public mutating func moveFolder(_ folderID: UUID, before beforeFolderID: UUID?) {
        folders.sort { $0.sortIndex < $1.sortIndex }
        guard let moving = folders.first(where: { $0.id == folderID }) else { return }
        folders.removeAll { $0.id == folderID }
        let insertionIndex = beforeFolderID.flatMap { before in folders.firstIndex { $0.id == before } } ?? folders.endIndex
        folders.insert(moving, at: insertionIndex)
        for index in folders.indices { folders[index].sortIndex = index }
    }

    public mutating func deleteFolder(_ folderID: UUID) {
        folders.removeAll { $0.id == folderID }
        for index in placements.indices where placements[index].folderID == folderID {
            placements[index].folderID = nil
        }
        reindexFolders()
        reindexAllGroups()
    }

    private mutating func reindexFolders() {
        folders.sort { $0.sortIndex < $1.sortIndex }
        for index in folders.indices { folders[index].sortIndex = index }
    }

    private mutating func reindexAllGroups() {
        let groupIDs = [UUID?.none] + folders.map { Optional($0.id) }
        for groupID in groupIDs {
            let ordered = placements.filter { $0.folderID == groupID }.sorted { $0.sortIndex < $1.sortIndex }
            for (index, placement) in ordered.enumerated() {
                if let storedIndex = placements.firstIndex(where: { $0.skillID == placement.skillID }) {
                    placements[storedIndex].sortIndex = index
                }
            }
        }
    }
}

public struct ManagedInstallation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var skillID: UUID
    public var targetID: UUID
    public var destinationPath: String
    public var deployedFingerprint: String
    public var transactionID: UUID
    public var deployedAt: Date

    public init(
        id: UUID = UUID(),
        skillID: UUID,
        targetID: UUID,
        destinationPath: String,
        deployedFingerprint: String,
        transactionID: UUID,
        deployedAt: Date = Date()
    ) {
        self.id = id
        self.skillID = skillID
        self.targetID = targetID
        self.destinationPath = destinationPath
        self.deployedFingerprint = deployedFingerprint
        self.transactionID = transactionID
        self.deployedAt = deployedAt
    }
}

public enum InstallationState: String, Codable, Sendable {
    case notInstalled
    case synced
    case updateAvailable
    case externallyModified
    case conflict
    case indirectlyVisible
}

public struct SkillCandidate: Hashable, Identifiable, Sendable {
    public var id: String { sourceURL.path }
    public var sourceURL: URL
    public var directoryName: String
    public var canonicalName: String
    public var displayName: String
    public var description: String
    public var fingerprint: String
    public var source: SkillSource
    public var riskReport: RiskReport

    public init(
        sourceURL: URL,
        directoryName: String,
        canonicalName: String,
        displayName: String,
        description: String,
        fingerprint: String,
        source: SkillSource,
        riskReport: RiskReport
    ) {
        self.sourceURL = sourceURL
        self.directoryName = directoryName
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.description = description
        self.fingerprint = fingerprint
        self.source = source
        self.riskReport = riskReport
    }
}

public struct DuplicateGroup: Hashable, Identifiable, Sendable {
    public var id: String { "\(canonicalName):\(fingerprint)" }
    public var canonicalName: String
    public var fingerprint: String
    public var candidates: [SkillCandidate]
}

public struct ConflictGroup: Hashable, Identifiable, Sendable {
    public var id: String { canonicalName }
    public var canonicalName: String
    public var versions: [DuplicateGroup]
}

public struct ScanResult: Sendable {
    public var candidates: [SkillCandidate]
    public var duplicateGroups: [DuplicateGroup]
    public var conflicts: [ConflictGroup]
    public var diagnostics: [String]

    public init(
        candidates: [SkillCandidate],
        duplicateGroups: [DuplicateGroup],
        conflicts: [ConflictGroup],
        diagnostics: [String]
    ) {
        self.candidates = candidates
        self.duplicateGroups = duplicateGroups
        self.conflicts = conflicts
        self.diagnostics = diagnostics
    }
}
