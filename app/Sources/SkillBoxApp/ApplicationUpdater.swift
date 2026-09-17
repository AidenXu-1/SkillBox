import AppKit
import Combine
import Sparkle

extension Notification.Name {
    static let skillBoxShowAbout = Notification.Name("SkillBoxShowAbout")
}

enum ApplicationUpdatePhase: Equatable {
    case idle, checking, latest, available, downloading, extracting, ready, installing, failed
}

/// One updater for the running application. Sparkle owns downloads, validation,
/// replacement, preferences and temporary files; user Skill storage is never passed to it.
@MainActor
final class ApplicationUpdater: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    @Published private(set) var phase: ApplicationUpdatePhase = .idle
    @Published private(set) var detail = "获取最新功能、改进与修复。"
    @Published private(set) var availableVersion = ""
    @Published private(set) var releaseNotes = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var canCheck = false
    @Published private(set) var canCancel = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isConfigured = false
    @Published private(set) var aboutRequest: UUID?
    var canRestart: () -> Bool = { true }

    private var updater: SPUUpdater?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var started = false
    private var informationURL: URL?
    private var informationOnly = false

    static let repository = URL(string: "https://github.com/AidenXu-1/SkillBox")!
    static let author = URL(string: "https://github.com/AidenXu-1")!
    static let releases = URL(string: "https://github.com/AidenXu-1/SkillBox/releases")!
    static let issues = URL(string: "https://github.com/AidenXu-1/SkillBox/issues")!
    static let license = URL(string: "https://github.com/AidenXu-1/SkillBox/blob/master/LICENSE")!

    var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "开发版")（\(info["CFBundleVersion"] as? String ?? "未打包")）"
    }

    var title: String {
        switch phase {
        case .idle: "检查 SkillBox 新版本"
        case .checking: "正在检查更新…"
        case .latest: "当前没有可安装的新版本"
        case .available: "发现新版本 \(availableVersion)"
        case .downloading: "正在下载更新…"
        case .extracting: "正在准备更新…"
        case .ready: "更新已准备好"
        case .installing: "正在重启安装…"
        case .failed: "更新暂未完成"
        }
    }

    var actionTitle: String {
        switch phase {
        case .available: informationURL == nil ? "下载更新" : "查看版本说明"
        case .ready: "重启并安装"
        case .installing: "重试重启"
        case .checking: "检查中…"
        case .downloading: "下载中…"
        case .extracting: "准备中…"
        case .failed: "重试"
        case .latest: "再次检查"
        case .idle: "检查更新"
        }
    }

    var actionEnabled: Bool {
        switch phase {
        case .available: choice != nil && (!informationOnly || informationURL != nil)
        case .ready: choice != nil && canRestart()
        case .installing: retryTermination != nil && canRestart()
        case .checking, .downloading, .extracting: false
        default: canCheck
        }
    }

    func start(bundle: Bundle = .main) {
        guard !started else { return }
        started = true
        guard bundle.bundleURL.pathExtension == "app",
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            phase = .failed
            detail = "此版本尚未配置应用更新，请从 GitHub 获取完整安装版。"
            return
        }
        let engine = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        updater = engine
        do {
            try engine.start()
            isConfigured = true
            engine.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
            engine.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
            engine.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
            engine.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        } catch {
            phase = .failed
            detail = "无法启动应用更新，请重新打开 SkillBox，或从 GitHub 下载新版。"
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard let updater else { return }
        if !enabled { updater.automaticallyDownloadsUpdates = false }
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        guard let updater, !enabled || updater.automaticallyChecksForUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        showUpdateInFocus()
        guard let updater, updater.canCheckForUpdates else { return }
        // Calling while an existing session is displayed asks Sparkle to focus it.
        updater.checkForUpdates()
    }

    func performPrimaryAction() {
        guard actionEnabled else { return }
        switch phase {
        case .available:
            if let informationURL {
                NSWorkspace.shared.open(informationURL)
                let reply = choice; choice = nil
                reply?(.dismiss)
            } else {
                let reply = choice; choice = nil
                phase = .downloading
                reply?(.install)
            }
        case .ready:
            let reply = choice; choice = nil
            phase = .installing
            detail = "正在结束当前应用，安装后会重新打开。"
            reply?(.install)
        case .installing:
            retryTermination?()
        default:
            checkForUpdates()
        }
    }

    func cancel() {
        let handler = cancellation
        cancellation = nil; canCancel = false
        phase = .idle; detail = "已取消更新，可以稍后重新检查。"
        handler?()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Normal bundles set SUEnableAutomaticChecks explicitly; no profile collection.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking; detail = "正在连接官方更新源。"
        releaseNotes = ""; availableVersion = ""
        self.cancellation = cancellation; canCancel = true
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        availableVersion = appcastItem.displayVersionString
        releaseNotes = appcastItem.itemDescriptionFormat == "plain-text" ? (appcastItem.itemDescription ?? "") : ""
        informationOnly = appcastItem.isInformationOnlyUpdate
        informationURL = informationOnly ? appcastItem.infoURL : nil
        cancellation = nil; canCancel = false
        choice = reply
        phase = state.stage == .installing ? .ready : .available
        detail = state.stage == .notDownloaded ? "查看此次更新的内容，准备好后开始下载。" : "更新已下载，准备好后即可继续安装。"
        if state.userInitiated { showUpdateInFocus() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showNoUpdate(error)
        acknowledgement()
    }

    private func showNoUpdate(_ error: Error) {
        phase = .latest
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        switch reason?.intValue {
        case 1: detail = "SkillBox 已是最新版本。"
        case 2: detail = "当前版本比公开版本更新，无需降级。"
        case 3, 4: detail = "新版本暂不支持当前 macOS，请查看更新日志。"
        case 5: detail = "新版本不支持这台 Mac，请查看更新日志。"
        default: detail = "更新源中暂无适用于此版本的更新。"
        }
        cancellation = nil; canCancel = false
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        recordError(error)
        acknowledgement()
    }

    private func recordError(_ error: Error) {
        phase = .failed
        let value = error as NSError
        if value.domain == SUSparkleErrorDomain && [3001, 3002].contains(value.code) {
            detail = "更新包校验未通过，已停止安装。请稍后重试或前往 GitHub。"
        } else if value.domain == SUSparkleErrorDomain && [1003, 1005].contains(value.code) {
            detail = "请先把 SkillBox 移到应用程序文件夹，再检查更新。"
        } else if value.domain == SUSparkleErrorDomain && (4000...4012).contains(value.code) {
            detail = "安装未完成，请重新打开 SkillBox 后重试，或从 GitHub 下载。"
        } else {
            detail = "暂时无法获取更新，请检查网络后重试，或前往 GitHub 查看。"
        }
        choice = nil; cancellation = nil; retryTermination = nil; canCancel = false
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .downloading; progress = 0; expectedBytes = 0; receivedBytes = 0
        detail = "你可以继续使用 SkillBox。"
        self.cancellation = cancellation; canCancel = true
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes = receivedBytes.addingReportingOverflow(length).partialValue
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        progress = expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : 0
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting; detail = "正在校验并展开更新包。"; progress = 0
        cancellation = nil; canCancel = false
    }

    func showExtractionReceivedProgress(_ progress: Double) { self.progress = min(1, max(0, progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .ready; detail = "准备好后重启 SkillBox，完成安装。"
        choice = reply
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        detail = applicationTerminated ? "正在安装新版本。" : "如当前操作尚未结束，请完成后重试重启。"
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .latest; detail = "更新安装完成。"
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choice = nil; cancellation = nil; retryTermination = nil; canCancel = false
        if [.checking, .downloading, .extracting, .available, .ready, .installing].contains(phase) {
            phase = .idle; detail = "本次更新已结束，可以重新检查。"
        }
    }

    func showUpdateInFocus() {
        aboutRequest = UUID()
        NotificationCenter.default.post(name: .skillBoxShowAbout, object: nil)
        NSApp?.activate(ignoringOtherApps: true)
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { showNoUpdate(error) }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == 1001 { return }
        recordError(error)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        phase = .ready
        detail = "更新已在后台准备好，重启 SkillBox 后完成安装。"
        choice = { response in if response == .install { immediateInstallationBlock() } }
        return true
    }
}
