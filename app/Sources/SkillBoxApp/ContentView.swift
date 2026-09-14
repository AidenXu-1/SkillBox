import AppKit
import SkillBoxCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case library = "我的 Skills"
    case agents = "安装到应用"
    case discover = "发现 Skills"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: "books.vertical"
        case .agents: "square.grid.2x2"
        case .discover: "sparkle.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

enum SkillDetailLayout {
    static let metaTitles = ["来源", "当前安装版本", "版本情况"]
    static let tabTitles = ["Skill 介绍", "文件详情"]
    static let guideTitles = ["作用", "适用场景", "使用流程", "启动提示词"]
    static let aiGuideLabel = "AI 介绍"
    static let connectAIButtonTitle = "连接 AI"
    static let tabMinimumHitHeight: CGFloat = 46
}

enum SidebarLayout {
    static let rowMinimumHitHeight: CGFloat = 46
}

enum SettingsLayout {
    static let pageTitles = ["AI 服务", "GitHub", "存储与记录", "操作记录与恢复", "隐私与安全"]
    static let aiServiceSymbol = "brain.head.profile"
    static let githubUsesOfficialMark = true
    static let rowMinimumHitHeight: CGFloat = 62
    static let navigationWidth: CGFloat = 268
    static let contentMaxWidth: CGFloat = 860
}

struct AgentColumnDragSession: Equatable {
    private(set) var movingTargetID: UUID?
    private(set) var originOrder: [UUID] = []
    private(set) var previewOrder: [UUID] = []
    private(set) var ghostCenterX: CGFloat = 0
    private(set) var grabOffsetX: CGFloat = 0

    var isActive: Bool { movingTargetID != nil }

    mutating func begin(
        targetID: UUID,
        orderedTargetIDs: [UUID],
        frame: CGRect,
        pointerX: CGFloat
    ) {
        movingTargetID = targetID
        originOrder = orderedTargetIDs
        previewOrder = orderedTargetIDs
        ghostCenterX = frame.midX
        grabOffsetX = pointerX - frame.midX
    }

    @discardableResult
    mutating func update(pointerX: CGFloat, frames: [UUID: CGRect]) -> Bool {
        guard let movingTargetID else { return false }
        ghostCenterX = pointerX - grabOffsetX
        let stationary = previewOrder.filter { $0 != movingTargetID }
        let orderedFrames = stationary.compactMap { id -> (UUID, CGRect)? in
            guard let frame = frames[id] else { return nil }
            return (id, frame)
        }.sorted { $0.1.midX < $1.1.midX }
        guard orderedFrames.count == stationary.count else { return false }

        var reordered = orderedFrames.map(\.0)
        let insertionIndex = orderedFrames.firstIndex { ghostCenterX < $0.1.midX } ?? reordered.endIndex
        reordered.insert(movingTargetID, at: insertionIndex)
        guard reordered != previewOrder else { return false }
        previewOrder = reordered
        return true
    }

    mutating func finish(commit: Bool) -> [UUID]? {
        let result = commit && previewOrder != originOrder ? previewOrder : nil
        cancel()
        return result
    }

    mutating func cancel() {
        movingTargetID = nil
        originOrder = []
        previewOrder = []
        ghostCenterX = 0
        grabOffsetX = 0
    }
}

enum AgentIconCatalog {
    static func resourceFilename(for kind: AgentKind) -> String? {
        switch kind {
        case .codex: "gpt.png"
        case .claudeCode: "claude-code.png"
        case .workBuddy: "workbuddy.png"
        case .zcode: "zcode.png"
        case .kimiCode: "kimi-code.png"
        case .cursor: "cursor.png"
        case .hanaAgent: "hanaagent.png"
        case .pi: "pi.svg"
        case .deepSeekHarness: "deepseek-harness.svg"
        case .trae: "trae.png"
        case .geminiCLI: "gemini-cli.png"
        case .openCode, .custom: nil
        }
    }
}

private struct AgentProductIcon: View {
    let target: AgentTarget
    var size: CGFloat = 28

    var body: some View {
        Group {
            if target.isCustom {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.blue)
                    .background(.blue.opacity(0.09))
            } else if let image = bundledImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
    }

    private var bundledImage: NSImage? {
        guard let filename = AgentIconCatalog.resourceFilename(for: target.kind),
              let resourceURL = Bundle.main.resourceURL
        else { return nil }
        return NSImage(contentsOf: resourceURL
            .appendingPathComponent("AgentIcons", isDirectory: true)
            .appendingPathComponent(filename))
    }
}

private struct SkillBoxSidebar: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("SkillBox")
                        .font(.headline)
                    Text("统一管理全局 Skill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 16)

            VStack(spacing: 5) {
                ForEach([SidebarItem.library, .agents]) { item in
                    SidebarNavigationButton(item: item, selection: $selection)
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                ForEach([SidebarItem.discover, .settings]) { item in
                    SidebarNavigationButton(item: item, selection: $selection)
                }
            }
            .padding(7)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.35)))
            .padding(.horizontal, 10)

            Spacer(minLength: 18)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "scope")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("管理范围")
                        .font(.caption.weight(.semibold))
                    Text("只管理跨项目使用的全局 Skill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.3)))
            .padding(10)
        }
    }
}

private struct SidebarNavigationButton: View {
    let item: SidebarItem
    @Binding var selection: SidebarItem?
    @State private var isHovering = false

    private var isSelected: Bool { selection == item }

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 23)
                Text(item.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: SidebarLayout.rowMinimumHitHeight, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color.primary.opacity(isHovering ? 0.065 : 0.018),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator.opacity(isHovering ? 0.5 : 0.22))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? "当前页面" : "")
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarItem? = .library
    @State private var selectedSkillID: UUID?
    @State private var showGitHub = false
    @State private var showImportPreview = false
    @State private var showUpdatePreview = false
    @State private var showSyncPreview = false
    @State private var showCustomTarget = false
    @State private var customTargetName = "其他应用"
    @State private var editingCustomTarget: AgentTarget?
    @State private var selectedSettingsPage: SettingsPage = .ai
    @State private var visibleStatusMessage: String?
    @State private var statusDismissTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            SkillBoxSidebar(selection: $selection)
            .navigationTitle("SkillBox")
            .navigationSplitViewColumnWidth(min: 210, ideal: 236)
        } detail: {
            Group {
                switch selection ?? .library {
                case .library:
                    LibraryView(
                        model: model,
                        selectedSkillID: $selectedSkillID,
                        showSyncPreview: $showSyncPreview,
                        importLocal: chooseLocalFolder,
                        importGitHub: { showGitHub = true },
                        openSettings: { selection = .settings },
                        openAISettings: {
                            selectedSettingsPage = .ai
                            selection = .settings
                        },
                        connectGitHub: {
                            selection = .settings
                            if model.isGitHubConfigured { Task { await model.connectPrivateGitHub() } }
                        }
                    )
                case .discover:
                    DiscoverSkillsView(model: model, openAISettings: {
                        selectedSettingsPage = .ai
                        selection = .settings
                    })
                case .agents:
                    AgentsView(
                        model: model,
                        addCustom: { showCustomTarget = true },
                        addSkill: { selection = .library },
                        editCustom: { editingCustomTarget = $0 }
                    )
                case .settings: SettingsView(model: model, selectedSettingsPage: $selectedSettingsPage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(selection?.rawValue ?? "SkillBox")
            .toolbar {
                if (model.isBusy || model.isCheckingLocalSources) && model.operationProgress == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Button { Task { await model.refreshSkills() } } label: {
                    Label("刷新安装状态与本地来源", systemImage: "arrow.clockwise")
                }
                .help("检查本地开发文件夹的变化，并刷新应用安装状态；GitHub 更新可在来源菜单中检查")
                .disabled(model.isBusy || model.isCheckingLocalSources)
            }
            .overlay(alignment: .topTrailing) {
                if let visibleStatusMessage, !model.isBusy {
                    StatusToast(message: visibleStatusMessage)
                        .padding(.top, 12)
                        .padding(.trailing, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $showGitHub) { GitHubImportView(model: model, isPresented: $showGitHub) }
        .sheet(item: $model.pendingReleasePackageChoice) { choice in
            GitHubReleasePackageChoiceView(model: model, choice: choice)
        }
        .sheet(item: $model.pendingInstallContentChoice) { choice in
            GitHubInstallContentChoiceView(model: model, choice: choice)
        }
        .sheet(item: $model.pendingLocalSourceSetup) { setup in
            LocalSourceSetupView(model: model, setup: setup)
        }
        .sheet(isPresented: $showImportPreview) { ImportPreviewView(model: model, isPresented: $showImportPreview) }
        .sheet(isPresented: $showUpdatePreview) { UpdatePreviewView(model: model, isPresented: $showUpdatePreview) }
        .sheet(isPresented: $showSyncPreview) { SyncPreviewView(model: model, isPresented: $showSyncPreview) }
        .sheet(isPresented: $showCustomTarget) { CustomTargetView(model: model, isPresented: $showCustomTarget, name: $customTargetName) }
        .sheet(item: $editingCustomTarget) { target in
            EditCustomTargetView(model: model, target: target, isPresented: Binding(
                get: { editingCustomTarget != nil },
                set: { if !$0 { editingCustomTarget = nil } }
            ))
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissCurrentError() } }
        )) {
            if model.canRetryGitHubWithDefaultBranch {
                Button("改用默认分支继续") { model.retryGitHubUsingDefaultBranch() }
            }
            if model.canRetryGitHubConnection {
                Button("重试") { model.retryGitHubConnection() }
            }
            Button("取消", role: .cancel) {
                model.dismissCurrentError()
            }
        } message: { Text(model.errorMessage ?? "") }
        .alert("提示", isPresented: Binding(get: { model.noticeMessage != nil }, set: { if !$0 { model.noticeMessage = nil } })) { Button("知道了") { model.noticeMessage = nil } } message: { Text(model.noticeMessage ?? "") }
        .onChange(of: model.pendingCandidates) { _, candidates in
            guard !candidates.isEmpty else { return }
            if model.updatingSkillID == nil {
                showUpdatePreview = false
                showImportPreview = true
            } else {
                showImportPreview = false
                showUpdatePreview = true
            }
        }
        .onChange(of: model.statusMessage) { _, message in
            guard !model.isBusy else { return }
            presentStatusToast(message)
        }
        .onChange(of: model.isBusy) { wasBusy, isBusy in
            guard wasBusy, !isBusy else { return }
            presentStatusToast(model.statusMessage)
        }
        .onDisappear {
            statusDismissTask?.cancel()
        }
        .overlay {
            if let progress = model.operationProgress {
                OperationProgressView(model: model, progress: progress)
            }
        }
        .overlay(alignment: .bottom) {
            if let deletion = model.lastDeletedSkill {
                DeleteUndoToast(model: model, deletion: deletion)
                    .padding(.bottom, 22)
            }
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "查看可添加的 Skills"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.previewLocalFolder(url) } }
    }

    private func presentStatusToast(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusDismissTask?.cancel()
            withAnimation(.easeIn(duration: 0.12)) {
                visibleStatusMessage = nil
            }
            return
        }

        statusDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            visibleStatusMessage = trimmed
        }
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                visibleStatusMessage = nil
            }
        }
    }
}

enum StatusToastTone: Equatable {
    case success
    case attention
    case neutral

    static func forMessage(_ message: String) -> StatusToastTone {
        let needsAttention = [
            "无法", "找不到", "需要", "请确认", "请选择", "限制", "未完成",
            "暂时没有", "没有正式 Release", "没有独立安装包",
        ].contains { message.contains($0) }
        if needsAttention { return .attention }
        if message.contains("取消") || message.contains("停止") { return .neutral }
        return .success
    }
}

private struct StatusToast: View {
    let message: String

    private var appearance: (icon: String, color: Color) {
        switch StatusToastTone.forMessage(message) {
        case .attention:
            return ("exclamationmark.circle.fill", .orange)
        case .neutral:
            return ("xmark.circle.fill", .secondary)
        case .success:
            return ("checkmark.circle.fill", .green)
        }
    }

    var body: some View {
        Label(message, systemImage: appearance.icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(appearance.color)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }
}

private struct OperationProgressView: View {
    @ObservedObject var model: AppModel
    let progress: SkillBoxOperationProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(progress.title).font(.headline)
                Text(progress.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if progress.canCancel {
                    Button("取消") { model.cancelRemoteOperation() }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                }
            }
            .padding(24)
            .frame(width: 350)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct DeleteUndoToast: View {
    @ObservedObject var model: AppModel
    let deletion: DeletedSkillBackup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash").foregroundStyle(.secondary)
            Text("已移到废纸篓：\(deletion.record.displayName)").font(.callout.weight(.medium))
            Button("撤销") { Task { await model.restoreLastDeletedSkill() } }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            Button { model.dismissDeleteUndo() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.4)))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 5)
    }
}

private struct PageHeader: View {
    let eyebrow: String; let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(eyebrow).font(.caption.weight(.semibold)).foregroundStyle(.blue); Text(title).font(.largeTitle.bold()); Text(subtitle).font(.callout).foregroundStyle(.secondary) } }
}

private struct DiscoverSkillsView: View {
    @ObservedObject var model: AppModel
    let openAISettings: () -> Void
    @State private var pendingDelete: DiscoverySession?
    @State private var compactShowsDetail = false

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 1_150 {
                HStack(alignment: .top, spacing: 0) {
                    DiscoveryConversationPane(model: model, pendingDelete: $pendingDelete, openAISettings: openAISettings)
                        .frame(width: 380)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    DiscoveryCandidateList(model: model) { compactShowsDetail = false }
                        .frame(width: min(420, max(350, proxy.size.width * 0.31)))
                        .frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    DiscoveryCandidateDetail(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    DiscoveryConversationPane(model: model, pendingDelete: $pendingDelete, openAISettings: openAISettings)
                        .frame(width: min(380, max(330, proxy.size.width * 0.40)))
                        .frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    if compactShowsDetail, model.selectedDiscoveryCandidate != nil {
                        DiscoveryCandidateDetail(model: model, showBack: true) { compactShowsDetail = false }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        DiscoveryCandidateList(model: model) { compactShowsDetail = true }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("删除这条寻找记录？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { session in
            Button("删除记录", role: .destructive) { Task { await model.deleteDiscoverySession(session) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只会删除这次寻找的条件和候选结果，已加入「我的 Skills」的内容不受影响。")
        }
    }
}

private let discoveryHeaderHeight: CGFloat = 74

private struct DiscoveryConversationPane: View {
    @ObservedObject var model: AppModel
    @Binding var pendingDelete: DiscoverySession?
    let openAISettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("寻找 Skills").font(.title2.bold())
                    Text("说清目标，再逐步补充条件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.beginNewDiscovery()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                .help("开始新的寻找")

                Menu {
                    if model.discoverySessions.isEmpty {
                        Text("还没有寻找记录")
                    } else {
                        ForEach(model.discoverySessions) { session in
                            Button {
                                model.selectDiscoverySession(session.id)
                            } label: {
                                if session.id == model.selectedDiscoverySessionID {
                                    Label(session.title, systemImage: "checkmark")
                                } else {
                                    Text(session.title)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .help("切换寻找记录")
            }
            .padding(.horizontal, 18)
            .frame(height: discoveryHeaderHeight)

            Divider()

            Group {
                if let session = model.selectedDiscoverySession {
                  VStack(spacing: 0) {
                    if let summary = DiscoveryConversation.taskSummary(session) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前任务").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(summary).font(.caption).lineLimit(3).help(summary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                    }
                    ScrollViewReader { reader in
                      ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title).font(.headline)
                                    Text("更新于 \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button(role: .destructive) { pendingDelete = session } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("删除这条寻找记录")
                            }
                            ForEach(DiscoveryTimelineItem.items(for: session)) { item in
                                switch item.content {
                                case let .message(message):
                                    DiscoveryMessageView(message: message)
                                case let .notice(notice):
                                    DiscoverySystemNoticeView(notice: notice)
                                }
                            }
                            if !model.isSelectedDiscoverySearching,
                               let presentation = DiscoveryResultPresentation(session: session)
                            {
                                DiscoveryResultSummaryView(presentation: presentation)
                            }
                            if model.isSelectedDiscoverySearching,
                               let state = model.discoveryRunState
                            {
                                DiscoveryProgressView(state: state)
                            }
                        }
                        .padding(18)
                        .id("discovery-timeline")
                      }
                      .onChange(of: session.messages.count) { _, _ in
                          reader.scrollTo("discovery-timeline", anchor: .bottom)
                      }
                    }
                  }
                } else {
                    ContentUnavailableView(
                        "你想解决什么？",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("例如：我想找一个能做公众号排版的 Skill")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            DiscoveryInput(model: model, openAISettings: openAISettings)
                .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

struct DiscoveryTimelineItem: Identifiable {
    enum Content {
        case message(DiscoveryMessage)
        case notice(DiscoverySystemNotice)
    }

    var id: String
    var createdAt: Date
    var content: Content

    static func items(for session: DiscoverySession) -> [Self] {
        let latestRunID = session.runs.last?.id
        let messages = session.messages.map {
            Self(id: "message-\($0.id.uuidString)", createdAt: $0.createdAt, content: .message($0))
        }
        let notices = session.notices.filter {
            !($0.kind == .partialResult && $0.runID == latestRunID)
        }.map {
            Self(id: "notice-\($0.id.uuidString)", createdAt: $0.createdAt, content: .notice($0))
        }
        return (messages + notices).enumerated().sorted { first, second in
            if first.element.createdAt == second.element.createdAt { return first.offset < second.offset }
            return first.element.createdAt < second.element.createdAt
        }.map(\.element)
    }
}

private struct DiscoveryMessageView: View {
    let message: DiscoveryMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 38)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.blue)
                    .frame(width: 22, height: 22)
                    .background(Color.blue.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text)
                        .font(.callout)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let references = message.references, !references.isEmpty {
                        DisclosureGroup("依据：\(references.map(\.name).joined(separator: "、"))") {
                            ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                                Text("\(reference.name) · \(reference.repository)\n\(reference.summary)")
                                    .font(.caption2).textSelection(.enabled)
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    if message.origin == "conversation-evidence-v1" {
                        Text("AI 根据引用资料整理，请核对作者说明").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct DiscoveryProgressView: View {
    let state: DiscoveryRunState

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(state.progressTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct DiscoverySystemNoticeView: View {
    let notice: DiscoverySystemNotice

    @ViewBuilder
    var body: some View {
        if notice.kind == .partialResult {
            DisclosureGroup("查看这轮的覆盖情况") {
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.kind == .failure ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(notice.kind == .failure ? Color.orange : Color.secondary)
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct DiscoveryResultSummaryView: View {
    let presentation: DiscoveryResultPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: presentation.hasRecommendations ? "checkmark.circle.fill" : "magnifyingglass.circle")
                    .foregroundStyle(presentation.hasRecommendations ? Color.green : Color.secondary)
                Text(presentation.title)
                    .font(.callout.bold())
            }
            Text(presentation.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .padding(.leading, 25)
            if !presentation.coverageDetails.isEmpty {
                DisclosureGroup(presentation.coverageTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(presentation.coverageDetails.enumerated()), id: \.offset) { _, detail in
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 25)
            }
        }
        .padding(12)
        .background(
            presentation.hasRecommendations ? Color.green.opacity(0.06) : Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(presentation.hasRecommendations ? Color.green.opacity(0.18) : Color.clear)
        }
    }
}

private extension DiscoveryRunState {
    var progressTitle: String {
        switch self {
        case .understanding: "正在理解你的需求…"
        case .recalling: "正在搜索多个公开来源…"
        case .verifying: "正在读取并核对真实 Skill…"
        case .evaluating: "正在比较适合度和质量…"
        case .completed: "寻找完成"
        case .partiallyCompleted: "已保留完成核对的结果"
        case .failed: "本轮寻找未完成"
        case .interrupted: "上次寻找已中止"
        }
    }
}

private struct DiscoveryInput: View {
    @ObservedObject var model: AppModel
    let openAISettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = model.selectedDiscoverySession, !session.queuedMessages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isSelectedDiscoverySearching && !model.discoveryQueuePaused
                        ? "待处理补充 · 本轮结束后合并处理"
                        : "补充已保留 · 等你继续")
                        .font(.caption.weight(.semibold))
                    ForEach(session.queuedMessages) { message in
                        Text(message.text).font(.caption).lineLimit(2).help(message.text)
                    }
                    if !model.isDiscoverySearching {
                        Button("继续处理补充") { model.resumeDiscoveryQueue() }.font(.caption)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            TextField(
                "继续问、补充条件，或告诉我换个方向…",
                text: $model.discoveryDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .frame(minHeight: 38, alignment: .leading)
            .onSubmit { model.startDiscoverySearch() }

            HStack(spacing: 8) {
                Menu {
                    if model.availableAIModelChoices.isEmpty {
                        Text("还没有可用模型")
                    } else {
                        ForEach(model.availableAIModelChoices) { choice in
                            Button {
                                model.selectAIModel(providerID: choice.providerID, model: choice.model)
                            } label: {
                                if choice.id == model.selectedAIModelChoiceID {
                                    Label("\(choice.providerName) · \(choice.model)", systemImage: "checkmark")
                                } else {
                                    Text("\(choice.providerName) · \(choice.model)")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("打开 AI 设置…") { openAISettings() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(model.aiInputModelLabel).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.selectedAIModelChoiceID == nil ? Color.secondary : Color.blue)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .help("选择用来理解需求和筛选候选的模型")

                Spacer()

                if model.isDiscoverySearching {
                    Button { model.cancelDiscoverySearch() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    .help("停止当前处理，保留待处理补充")
                }
                Button { model.startDiscoverySearch() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .disabled(model.discoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(model.isDiscoverySearching ? "发送补充，完成本轮后处理" : "发送消息")
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.55)))
    }
}

private struct DiscoveryCandidateList: View {
    @ObservedObject var model: AppModel
    let didSelect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let session = model.selectedDiscoverySession,
                   let presentation = DiscoveryResultPresentation(session: session)
                {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.candidateListTitle).font(.title2.bold())
                        Text("达到质量门槛的全部保留，不凑数")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("候选 Skills").font(.title2.bold())
                }
                Spacer()
                if model.isSelectedDiscoverySearching {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        if let state = model.discoveryRunState {
                            Text(state.progressTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if model.canContinueSelectedDiscoverySearch {
                    Button("继续深挖") { model.continueDiscoverySearch() }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: discoveryHeaderHeight)
            Divider()

            if let session = model.selectedDiscoverySession, !session.recommendedCandidates.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.recommendedCandidates) { candidate in
                            DiscoveryCandidateRow(
                                candidate: candidate,
                                isSelected: candidate.id == model.selectedDiscoveryCandidateID,
                                isAdded: model.isDiscoveryCandidateAdded(candidate)
                            ) {
                                model.selectDiscoveryCandidate(candidate.id)
                                didSelect()
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                if model.isSelectedDiscoverySearching {
                    ContentUnavailableView(
                        "正在寻找",
                        systemImage: "magnifyingglass",
                        description: Text(model.discoveryRunState?.progressTitle ?? "正在寻找…")
                    )
                } else if let session = model.selectedDiscoverySession,
                          let presentation = DiscoveryResultPresentation(session: session)
                {
                    ContentUnavailableView(
                        presentation.title,
                        systemImage: "magnifyingglass",
                        description: Text("不会为了凑数量放入证据不足的候选")
                    )
                } else {
                    ContentUnavailableView(
                        "选择一个候选",
                        systemImage: "magnifyingglass",
                        description: Text("搜索结果会显示在这里")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

}

private struct DiscoveryCandidateRow: View {
    let candidate: DiscoveryCandidate
    let isSelected: Bool
    let isAdded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(candidate.name).font(.headline).lineLimit(1)
                    Spacer()
                    if candidate.tier == .recommended {
                        Text("推荐")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.blue)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.blue.opacity(0.10), in: Capsule())
                    }
                    if isAdded {
                        Text("已加入").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                Text(candidate.userFacingSummary ?? "作者暂未提供可核对的用途说明")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Label(candidate.repositoryFullName, systemImage: "shippingbox")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.13) : isHovered ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(isSelected ? Color.accentColor.opacity(0.32) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

}

private struct DiscoveryCandidateDetail: View {
    @ObservedObject var model: AppModel
    var showBack = false
    var back: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if showBack {
                    Button(action: back) { Label("候选", systemImage: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                }
                Text("Skill 详情").font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: discoveryHeaderHeight)
            Divider()

            if let candidate = model.selectedDiscoveryCandidate {
                ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 14) {
                        Text(candidate.name.first.map { String($0).uppercased() } ?? "S")
                            .font(.title2.bold()).foregroundStyle(.blue)
                            .frame(width: 54, height: 54)
                            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.name).font(.title.bold())
                            Text(candidate.repositoryFullName).font(.callout).foregroundStyle(.secondary)
                            if let updatedAt = candidate.repositoryUpdatedAt {
                                Text("仓库更新于 \(updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let url = candidate.repositoryURL {
                            Button("打开 GitHub") { NSWorkspace.shared.open(url) }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        }
                    }

                    let popularity = DiscoveryPopularityPresentation(candidate: candidate)
                    HStack(spacing: 10) {
                        DiscoveryPopularityMetric(
                            label: popularity.skillUsageLabel,
                            value: popularity.skillUsageValue
                        )
                        DiscoveryPopularityMetric(
                            label: popularity.repositoryStarsLabel,
                            value: popularity.repositoryStarsValue
                        )
                    }
                    Text("使用量属于这个 Skill；Star 属于整个 GitHub 仓库，仅作辅助参考。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    let guide = displayGuide(for: candidate)
                    if guide.origin == .aiAssisted {
                        Label("AI 辅助说明", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                        if let sources = guide.sourceDocuments, !sources.isEmpty {
                            Text("依据：\(sources.joined(separator: "、"))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    DiscoveryDetailSection(title: SkillDetailLayout.guideTitles[0], text: guide.purpose)
                    if let documentURL = candidate.evidence.skillDocumentURL,
                       documentURL.scheme == "https",
                       ["github.com", "raw.githubusercontent.com", "api.github.com"].contains(documentURL.host ?? "")
                    {
                        Link("查看作者的完整说明", destination: documentURL)
                            .font(.callout)
                    }
                    if let useWhen = guide.useWhen, !useWhen.isEmpty {
                        DiscoveryDetailSection(title: "适用场景", text: useWhen)
                    }

                    if !guide.experienceSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(SkillDetailLayout.guideTitles[2]).font(.headline)
                            ForEach(Array(guide.experienceSteps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                        .frame(width: 22, height: 22)
                                        .background(.blue.opacity(0.09), in: Circle())
                                    Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if let prompt = guide.starterPrompt, !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(SkillDetailLayout.guideTitles[3]).font(.headline)
                            HStack(alignment: .top) {
                                Text(prompt)
                                    .font(.callout).textSelection(.enabled)
                                Spacer()
                                Button("复制") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(prompt, forType: .string)
                                }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            }
                            .padding(12)
                            .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    if let source = candidate.repositorySummary, !source.isEmpty {
                        DisclosureGroup("来源信息") {
                            Text(source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                            Text("安装量和 Star 只用于了解知名度，不代表质量或安全。")
                                .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                    }

                    Button {
                        model.importDiscoveryCandidate(candidate)
                    } label: {
                        Label(model.isDiscoveryCandidateAdded(candidate) ? "已在我的 Skills" : "加入我的 Skills", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                    .disabled(model.isBusy || model.isDiscoveryCandidateAdded(candidate))
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            } else {
                if let session = model.selectedDiscoverySession,
                   let presentation = DiscoveryResultPresentation(session: session),
                   session.recommendedCandidates.isEmpty
                {
                    ContentUnavailableView(
                        "没有可查看的推荐",
                        systemImage: "rectangle.and.text.magnifyingglass",
                        description: Text(presentation.explanation)
                    )
                } else {
                    ContentUnavailableView("选择一个候选", systemImage: "rectangle.and.text.magnifyingglass", description: Text("这里会显示用途、适用场景和使用方式"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func displayGuide(for candidate: DiscoveryCandidate) -> SkillUsageGuide {
        DiscoveryCandidateUsage.guide(for: candidate)
    }
}

private struct DiscoveryPopularityMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DiscoveryDetailSection: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiscoveryFact: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold())
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    @Binding var showSyncPreview: Bool
    let importLocal: () -> Void
    let importGitHub: () -> Void
    let openSettings: () -> Void
    let openAISettings: () -> Void
    let connectGitHub: () -> Void
    @State private var searchText = ""
    @State private var filter: SkillListFilter = .all
    @State private var isAddMenuHovered = false
    var selected: SkillRecord? { model.snapshot.skills.first { $0.id == selectedSkillID } ?? model.snapshot.skills.first }
    var body: some View {
        Group {
            if model.snapshot.skills.isEmpty {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        PageHeader(
                            eyebrow: "全局 Skill",
                            title: "我的 Skills",
                            subtitle: "在这里集中管理来自电脑文件夹和 GitHub 的 Skills。"
                        )
                        Spacer()
                    }
                    .padding(28)
                ContentUnavailableView {
                    Label("还没有添加 Skill", systemImage: "shippingbox")
                } description: {
                    Text("从电脑文件夹或公开、私人 GitHub 仓库添加，确认前只会查看内容。")
                } actions: {
                    HStack {
                        Button("从电脑添加", action: importLocal)
                        Button("从 GitHub 添加", action: importGitHub)
                            .buttonStyle(.borderedProminent)
                        if !model.isGitHubConnected {
                            Button(model.isGitHubConfigured ? "连接 GitHub" : "了解 GitHub 登录状态", action: model.isGitHubConfigured ? connectGitHub : openSettings)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
                }
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        libraryPaneHeader
                        Divider()
                        SkillOrganizerSidebar(
                            model: model,
                            selectedSkillID: $selectedSkillID,
                            showSyncPreview: $showSyncPreview,
                            searchText: $searchText,
                            filter: $filter
                        )
                    }
                    .frame(minWidth: 290, idealWidth: 350, maxWidth: 410)
                    if let selected {
                        SkillDetailView(
                            model: model,
                            skill: selected,
                            showSyncPreview: $showSyncPreview,
                            openSettings: openSettings,
                            openAISettings: openAISettings
                        ) {
                            selectedSkillID = model.snapshot.skills.first?.id
                        }
                            .frame(minWidth: 480)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedSkillID == nil { selectedSkillID = model.snapshot.skills.first?.id }
        }
    }

    private var libraryPaneHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("我的 Skills")
                    .font(.title3.bold())
                Text("\(model.snapshot.skills.count) 份全局 Skill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !model.snapshot.sourceStates.isEmpty || !model.isGitHubConnected {
                Menu {
                    if !model.snapshot.sourceStates.isEmpty {
                        Button {
                            model.startGitHubUpdateCheck()
                        } label: {
                            Label("检查 GitHub 更新", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(model.isBusy)
                    }
                    if !model.isGitHubConnected {
                        Button(action: model.isGitHubConfigured ? connectGitHub : openSettings) {
                            Label(model.isGitHubConfigured ? "连接 GitHub" : "GitHub 登录状态", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("来源检查与 GitHub 设置")
            }

            Menu {
                Button("从电脑文件夹添加", action: importLocal)
                Button("从 GitHub 仓库添加", action: importGitHub)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    Color.accentColor.opacity(isAddMenuHovered ? 0.86 : 1),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isAddMenuHovered = $0 }
            .help("从电脑文件夹或 GitHub 仓库添加 Skill")
            .accessibilityLabel("添加 Skill")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

private enum SkillListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case updates = "有更新"
    case installed = "已安装"
    case attention = "需要处理"

    var id: String { rawValue }
}

enum SkillOrganizerSourceTint: Equatable, Sendable {
    case blue
    case secondary
}

enum SkillOrganizerSourceIcon: Equatable, Sendable {
    case githubMark
    case system(name: String, tint: SkillOrganizerSourceTint)
}

enum SkillOrganizerRowPresentation {
    static let rowSpacing: CGFloat = 5

    static func visibleFolders(orderedFolders: [SkillFolder]) -> [SkillFolder] {
        orderedFolders
    }

    static func sourceLabel(for sourceKind: SkillSourceKind) -> String {
        switch sourceKind {
        case .github: "GitHub 来源"
        case .localFolder: "本地来源"
        case .agentDirectory: "应用导入"
        }
    }

    static func sourceIcon(for sourceKind: SkillSourceKind) -> SkillOrganizerSourceIcon {
        switch sourceKind {
        case .github: .githubMark
        case .localFolder: .system(name: "folder.fill", tint: .blue)
        case .agentDirectory: .system(name: "square.and.arrow.down.fill", tint: .secondary)
        }
    }

    static func showsInsertionLine(
        session: SkillOrganizerDragSession,
        rowID: UUID
    ) -> Bool {
        session.movingSkillID == rowID && session.destination != nil
    }

    static func insertionLineY(
        session: SkillOrganizerDragSession,
        movingRowFrame: CGRect?
    ) -> CGFloat? {
        guard session.isActive,
              session.destination != nil,
              let movingRowFrame
        else { return nil }
        return movingRowFrame.maxY + 3
    }

    static func disposition(
        session: SkillOrganizerDragSession,
        rowID: UUID
    ) -> SkillOrganizerRowDisposition {
        guard session.isActive, session.movingSkillID == rowID else { return .card }
        return .placeholder
    }

    static func floatingSkillID(session: SkillOrganizerDragSession) -> UUID? {
        guard session.isActive else { return nil }
        return session.movingSkillID
    }

    static func stableListOrder(
        session: SkillOrganizerDragSession,
        fallback: [UUID]
    ) -> [UUID] {
        guard session.isActive, !session.originOrder.isEmpty else { return fallback }
        return session.originOrder
    }

    static func previewSlotOffset(
        session: SkillOrganizerDragSession,
        rowID: UUID
    ) -> Int {
        guard session.isActive,
              session.movingSkillID != rowID,
              let originIndex = session.originOrder.firstIndex(of: rowID),
              let previewIndex = session.previewOrder.firstIndex(of: rowID)
        else { return 0 }
        return previewIndex - originIndex
    }

    static func insertionSlotID(session: SkillOrganizerDragSession) -> UUID? {
        guard session.isActive,
              session.destination != nil,
              let movingSkillID = session.movingSkillID,
              let previewIndex = session.previewOrder.firstIndex(of: movingSkillID),
              session.originOrder.indices.contains(previewIndex)
        else { return nil }
        return session.originOrder[previewIndex]
    }
}

enum SkillOrganizerRowDisposition: Equatable, Sendable {
    case card
    case placeholder
}

enum SkillOrganizerDropEdge: Equatable, Sendable {
    case before
    case after
}

struct SkillOrganizerDropDestination: Equatable, Sendable {
    let edge: SkillOrganizerDropEdge
    let targetSkillID: UUID
    let accessibilityLabel: String
}

enum SkillOrganizerGroup: Equatable, Sendable {
    case uncategorized
    case folder(UUID)

    init(folderID: UUID?) {
        if let folderID { self = .folder(folderID) }
        else { self = .uncategorized }
    }

    var folderID: UUID? {
        if case let .folder(id) = self { return id }
        return nil
    }
}

struct SkillOrganizerMoveIntent: Equatable, Sendable {
    let movingSkillID: UUID
    let group: SkillOrganizerGroup
    let beforeSkillID: UUID?
}

struct SkillOrganizerDragSession: Equatable, Sendable {
    private(set) var movingSkillID: UUID?
    private(set) var group: SkillOrganizerGroup?
    private(set) var originOrder: [UUID] = []
    private(set) var previewOrder: [UUID] = []
    private(set) var destination: SkillOrganizerDropDestination?
    private(set) var grabOffsetY: CGFloat = 0
    private(set) var pointerY: CGFloat = 0

    var isActive: Bool { movingSkillID != nil }

    mutating func begin(
        skillID: UUID,
        group: SkillOrganizerGroup,
        orderedSkillIDs: [UUID],
        grabOffsetY: CGFloat,
        pointerY: CGFloat
    ) {
        movingSkillID = skillID
        self.group = group
        originOrder = orderedSkillIDs
        previewOrder = orderedSkillIDs
        destination = nil
        self.grabOffsetY = max(grabOffsetY, 0)
        self.pointerY = pointerY
    }

    mutating func update(destination: SkillOrganizerDropDestination?, pointerY: CGFloat) {
        guard let movingSkillID else { return }
        self.destination = destination
        self.pointerY = pointerY
        guard let destination else {
            previewOrder = originOrder
            return
        }

        let beforeSkillID = SkillOrganizerDropPolicy.beforeSkillID(
            for: destination,
            movingSkillID: movingSkillID,
            orderedSkillIDs: originOrder
        )
        var remaining = originOrder.filter { $0 != movingSkillID }
        if let beforeSkillID, let index = remaining.firstIndex(of: beforeSkillID) {
            remaining.insert(movingSkillID, at: index)
        } else {
            remaining.append(movingSkillID)
        }
        previewOrder = remaining
    }

    mutating func finish() -> SkillOrganizerMoveIntent? {
        guard let movingSkillID, let group, let destination else {
            cancel()
            return nil
        }
        let intent = SkillOrganizerMoveIntent(
            movingSkillID: movingSkillID,
            group: group,
            beforeSkillID: SkillOrganizerDropPolicy.beforeSkillID(
                for: destination,
                movingSkillID: movingSkillID,
                orderedSkillIDs: originOrder
            )
        )
        cancel()
        return intent
    }

    mutating func cancel() {
        movingSkillID = nil
        group = nil
        originOrder = []
        previewOrder = []
        destination = nil
        grabOffsetY = 0
        pointerY = 0
    }
}

enum SkillOrganizerDropPolicy {
    static func reorderBounds(for rowFrames: [CGRect]) -> CGRect? {
        rowFrames.reduce(nil) { bounds, frame in
            guard let bounds else { return frame }
            return bounds.union(frame)
        }
    }

    static func contains(_ location: CGPoint, in rowFrames: [CGRect]) -> Bool {
        reorderBounds(for: rowFrames)?.contains(location) == true
    }

    static func resolveValidDestination(
        locationY: CGFloat,
        rowHeight: CGFloat,
        movingSkillID: UUID?,
        targetSkillID: UUID,
        targetName: String
    ) -> SkillOrganizerDropDestination? {
        guard movingSkillID != targetSkillID else { return nil }
        return resolve(
            locationY: locationY,
            rowHeight: rowHeight,
            targetSkillID: targetSkillID,
            targetName: targetName
        )
    }

    static func resolve(
        locationY: CGFloat,
        rowHeight: CGFloat,
        targetSkillID: UUID,
        targetName: String
    ) -> SkillOrganizerDropDestination {
        let isBefore = locationY < max(rowHeight, 0) / 2
        return SkillOrganizerDropDestination(
            edge: isBefore ? .before : .after,
            targetSkillID: targetSkillID,
            accessibilityLabel: "放到 \(targetName) \(isBefore ? "上方" : "下方")"
        )
    }

    static func beforeSkillID(
        for destination: SkillOrganizerDropDestination,
        movingSkillID: UUID,
        orderedSkillIDs: [UUID]
    ) -> UUID? {
        let remaining = orderedSkillIDs.filter { $0 != movingSkillID }
        guard let targetIndex = remaining.firstIndex(of: destination.targetSkillID) else {
            return nil
        }
        switch destination.edge {
        case .before:
            return destination.targetSkillID
        case .after:
            let nextIndex = remaining.index(after: targetIndex)
            return nextIndex < remaining.endIndex ? remaining[nextIndex] : nil
        }
    }
}

private enum SkillOrganizerCoordinateSpace {
    static let name = "skill-organizer-list"
}

private struct SkillOrganizerRowFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SkillOrganizerSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    @Binding var showSyncPreview: Bool
    @Binding var searchText: String
    @Binding var filter: SkillListFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedFolderIDs: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var sortByName = false
    @State private var dragSession = SkillOrganizerDragSession()
    @State private var movingItem: OrganizerRowKey?
    @State private var landing: OrganizerLanding?
    @State private var pointer: CGPoint = .zero
    @State private var grabOffset: CGFloat = 0
    @State private var gestureStart: CGPoint?
    @State private var ignoredStart: CGPoint?
    @State private var hoveredFolderID: UUID?
    @State private var hoverStartedAt: Date?
    @State private var isCommitting = false
    @State private var escapeMonitor: Any?
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var scrollMetrics = OrganizerScrollMetrics()

    private var canDrag: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter == .all && !sortByName && !isCommitting
    }
    private var folders: [SkillFolder] { model.orderedFolders() }
    private var rowKeys: [OrganizerRowKey] {
        var keys: [OrganizerRowKey] = []
        for folder in folders {
            keys.append(.folder(folder.id))
            if !collapsedFolderIDs.contains(folder.id), movingItem != .folder(folder.id) {
                keys += displayedSkills(in: folder.id).map { .skill($0.id) }
            }
        }
        keys.append(.uncategorized)
        keys += displayedSkills(in: nil).map { .skill($0.id) }
        return keys
    }
    private var rowGeometry: [OrganizerRowGeometry] {
        OrganizerDragLayout.geometry(keys: rowKeys, offset: scrollMetrics.offset,
            width: scrollMetrics.viewport.width, spacing: SkillOrganizerRowPresentation.rowSpacing)
    }
    private var previewOrder: [OrganizerRowKey] {
        guard let movingItem else { return rowKeys }
        return OrganizerDragLayout.previewOrder(moving: movingItem, landing: landing, rows: rowGeometry)
    }
    private var offsets: [OrganizerRowKey: CGFloat] {
        OrganizerDragLayout.offsets(order: previewOrder, rows: rowGeometry, spacing: SkillOrganizerRowPresentation.rowSpacing)
    }
    private var dragHint: String {
        if isCommitting { return "正在保存顺序…" }
        guard let landing else {
            return canDrag ? "拖动排序或移入文件夹 · Esc 取消" : "切回手动排序并清除筛选后，可拖动整理"
        }
        let name: String
        switch landing.anchor {
        case .uncategorized: name = "未分类"
        case let .folder(id): name = folders.first { $0.id == id }?.name ?? "文件夹"
        case let .skill(id): name = model.snapshot.skills.first { $0.id == id }?.displayName ?? "Skill"
        }
        switch landing.edge {
        case .inside: return "移到“\(name)”"
        case .before: return "放到“\(name)”上方"
        case .after: return "放到“\(name)”下方"
        }
    }

    var body: some View {
        let visualOffsets = offsets
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索 Skills", text: $searchText).textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) {
                    ForEach(SkillListFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 96)
                Menu {
                    Button { sortByName = false } label: { Label("手动排序", systemImage: sortByName ? "circle" : "checkmark") }
                    Button { sortByName = true } label: { Label("按名称排序", systemImage: sortByName ? "checkmark" : "circle") }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(sortByName ? "按名称排序" : "手动排序")
                Button { newFolderName = ""; showNewFolder = true } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }.labelStyle(.iconOnly).buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary)).help("新建文件夹")
            }.padding(.horizontal, 10).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SkillOrganizerRowPresentation.rowSpacing) {
                    ForEach(rowKeys, id: \.self) { key in
                        organizerRow(key)
                            .frame(height: OrganizerDragLayout.rowHeight(for: key))
                            .offset(y: key == movingItem ? 0 : (visualOffsets[key] ?? 0))
                            .zIndex(key == movingItem ? 20 : 0)
                            .transaction { if key == movingItem { $0.animation = nil } }
                    }
                }
                .padding(8)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: OrganizerScrollMetrics.self) { geometry in
                OrganizerScrollMetrics(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                       viewport: geometry.containerSize, contentHeight: geometry.contentSize.height)
            } action: { _, metrics in
                scrollMetrics = metrics
                if movingItem != nil { updateLanding() }
            }
            .coordinateSpace(name: SkillOrganizerCoordinateSpace.name)
            .overlay(alignment: .topLeading) {
                if let movingItem, let landing, landing.edge != .inside,
                   let frame = rowGeometry.first(where: { $0.key == movingItem })?.frame {
                    let inset: CGFloat = if case .skill = movingItem, landing.folderID != nil { 24 } else { 0 }
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                        .frame(width: max(0, frame.width - inset), height: 3)
                        .offset(x: 8 + inset, y: frame.minY + (offsets[movingItem] ?? 0) - 2)
                        .allowsHitTesting(false)
                        .accessibilityLabel(dragHint)
                }
            }
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.23, dampingFraction: 1), value: previewOrder)
            Divider()
            Text(dragHint).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.quaternary.opacity(0.12))
        .task(id: movingItem) {
            while movingItem != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !isCommitting else { continue }
                let step = OrganizerDragLayout.scrollStep(pointer: pointer, viewport: scrollMetrics.viewport)
                if step != 0 {
                    let next = min(max(scrollMetrics.offset + step, 0), max(0, scrollMetrics.contentHeight - scrollMetrics.viewport.height))
                    if abs(next - scrollMetrics.offset) > 0.1 { scrollPosition.scrollTo(y: next) }
                }
                if let id = hoveredFolderID, let started = hoverStartedAt,
                   Date().timeIntervalSince(started) >= 0.65, collapsedFolderIDs.contains(id) {
                    collapsedFolderIDs.remove(id)
                    hoverStartedAt = nil
                }
            }
        }
        .onAppear {
            guard escapeMonitor == nil else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, movingItem != nil, !isCommitting else { return event }
                cancelDrag(suppressGesture: true)
                return nil
            }
        }
        .onExitCommand { cancelDrag(suppressGesture: true) }
        .onDisappear {
            cancelDrag(suppressGesture: true)
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in cancelDrag(suppressGesture: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelDrag(suppressGesture: true) }
        .onChange(of: searchText) { _, _ in cancelDrag(suppressGesture: true) }
        .onChange(of: filter) { _, _ in cancelDrag(suppressGesture: true) }
        .onChange(of: sortByName) { _, _ in cancelDrag(suppressGesture: true) }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("例如：写作、开发、运营", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { _ = await model.createSkillFolder(named: newFolderName) } }
        } message: { Text("文件夹只用于整理列表，不会移动或修改 Skill 原件。") }
    }

    @ViewBuilder
    private func organizerRow(_ key: OrganizerRowKey) -> some View {
        switch key {
        case .uncategorized:
            OrganizerGroupHeader(title: "未分类", count: displayedSkills(in: nil).count, systemImage: "tray")
                .background(highlight(key), in: RoundedRectangle(cornerRadius: 8))
        case let .skill(id):
            if let skill = model.snapshot.skills.first(where: { $0.id == id }) {
                let folderID = model.snapshot.organization.placements.first { $0.skillID == id }?.folderID
                SkillOrganizerRow(model: model, skill: skill, folderID: folderID,
                    selectedSkillID: $selectedSkillID, showSyncPreview: $showSyncPreview,
                    dragSession: dragSession, dragOffsetY: floatingOffset(key), previewOffsetY: 0,
                    onDragChanged: { updateDrag(key, value: $0) }, onDragEnded: { finishDrag(key, value: $0) })
                    .padding(.leading, folderID == nil ? 0 : 24)
            }
        case let .folder(id):
            if let folder = folders.first(where: { $0.id == id }) {
                ZStack {
                    OrganizerFolderHeader(model: model, folder: folder,
                        count: model.orderedSkills(in: id).count, isCollapsed: collapsedFolderIDs.contains(id),
                        isDropTarget: landing?.anchor == key && landing?.edge == .inside,
                        onToggle: {
                            guard movingItem == nil else { return }
                            if collapsedFolderIDs.contains(id) { collapsedFolderIDs.remove(id) }
                            else { collapsedFolderIDs.insert(id) }
                        })
                        .opacity(movingItem == key ? 0.18 : 1)
                        .background(highlight(key), in: RoundedRectangle(cornerRadius: 8))
                    if movingItem == key {
                        HStack(spacing: 5) {
                            OrganizerFolderTitle(name: folder.name, count: model.orderedSkills(in: id).count,
                                                 isCollapsed: collapsedFolderIDs.contains(id))
                            Image(systemName: "ellipsis").frame(width: 22, height: 22).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 10).padding(.trailing, 8)
                        .frame(height: OrganizerDragLayout.rowHeight(for: key))
                        .background(.background, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                        .offset(y: floatingOffset(key)).allowsHitTesting(false)
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(SkillOrganizerCoordinateSpace.name))
                    .onChanged { updateDrag(key, value: $0) }.onEnded { finishDrag(key, value: $0) })
            }
        }
    }

    private func highlight(_ key: OrganizerRowKey) -> Color {
        landing?.anchor == key && landing?.edge == .inside ? .accentColor.opacity(0.19) : .clear
    }
    private func floatingOffset(_ key: OrganizerRowKey) -> CGFloat {
        guard key == movingItem, let frame = rowGeometry.first(where: { $0.key == key })?.frame else { return 0 }
        return pointer.y - frame.minY - grabOffset
    }
    private func updateDrag(_ key: OrganizerRowKey, value: DragGesture.Value) {
        guard canDrag else { return }
        if let ignoredStart {
            if ignoredStart == value.startLocation { return }
            self.ignoredStart = nil
        }
        if movingItem == nil {
            gestureStart = value.startLocation
            grabOffset = value.startLocation.y - (rowGeometry.first { $0.key == key }?.frame.minY ?? value.startLocation.y)
            movingItem = key
            if case let .skill(id) = key {
                selectedSkillID = id
                let group = model.snapshot.organization.placements.first { $0.skillID == id }?.folderID
                dragSession.begin(skillID: id, group: .init(folderID: group), orderedSkillIDs: model.orderedSkills(in: group).map(\.id), grabOffsetY: grabOffset, pointerY: value.location.y)
            }
        }
        guard movingItem == key else { return }
        pointer = value.location
        if case .skill = key { dragSession.update(destination: nil, pointerY: pointer.y) }
        updateLanding()
    }
    private func updateLanding() {
        guard let movingItem, !isCommitting else { return }
        landing = OrganizerDragLayout.landing(moving: movingItem, pointer: pointer, viewport: scrollMetrics.viewport, rows: rowGeometry)
        let folderID: UUID? = if landing?.edge == .inside { landing?.folderID } else { nil }
        if folderID != hoveredFolderID { hoveredFolderID = folderID; hoverStartedAt = folderID == nil ? nil : Date() }
    }
    private func finishDrag(_ key: OrganizerRowKey, value: DragGesture.Value) {
        if ignoredStart == value.startLocation { ignoredStart = nil; return }
        guard movingItem == key, !isCommitting else { return }
        updateDrag(key, value: value)
        guard let landing else { cancelDrag(); return }
        isCommitting = true
        Task {
            switch key {
            case let .skill(id): await model.moveSkill(id, to: landing.folderID, before: landing.beforeID)
            case let .folder(id): await model.moveFolder(id, before: landing.beforeID)
            case .uncategorized: break
            }
            isCommitting = false
            cancelDrag()
        }
    }
    private func cancelDrag(suppressGesture: Bool = false) {
        guard !isCommitting else { return }
        if suppressGesture { ignoredStart = gestureStart }
        movingItem = nil; landing = nil; gestureStart = nil
        hoveredFolderID = nil; hoverStartedAt = nil
        dragSession.cancel()
    }
    private func displayedSkills(in folderID: UUID?) -> [SkillRecord] {
        let skills = filteredSkills(in: folderID)
        return sortByName ? skills.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } : skills
    }
    private func filteredSkills(in folderID: UUID?) -> [SkillRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.orderedSkills(in: folderID).filter { skill in
            let matchesSearch = query.isEmpty ||
                skill.displayName.lowercased().contains(query) ||
                skill.canonicalName.lowercased().contains(query) ||
                skill.description.lowercased().contains(query)
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .updates:
                let status = model.snapshot.sourceStates.first { $0.skillID == skill.id }?.status
                let localStatus = model.snapshot.localSourceStates.first { $0.skillID == skill.id }?.status
                return status == .updateAvailable || status == .releasePackageAvailable || localStatus == .updateAvailable
            case .installed:
                return model.snapshot.installations.contains { $0.skillID == skill.id }
            case .attention:
                let sourceState = model.snapshot.sourceStates.first { $0.skillID == skill.id }
                let localState = model.snapshot.localSourceStates.first { $0.skillID == skill.id }
                return model.shouldShowRiskAttention(for: skill) ||
                    sourceState?.lastCheckIssue != nil ||
                    sourceState?.status == .authenticationRequired ||
                    sourceState?.status == .unavailable ||
                    localState?.status == .packageReviewRequired ||
                    localState?.status == .sourceUnavailable
            }
        }
    }

}

private struct OrganizerGroupHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

private struct OrganizerFolderTitle: View {
    let name: String
    let count: Int
    let isCollapsed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Image(systemName: "archivebox.fill")
                .font(.system(size: 23))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 23)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct OrganizerFolderHeader: View {
    @ObservedObject var model: AppModel
    let folder: SkillFolder
    let count: Int
    let isCollapsed: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameValue = ""

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onToggle) {
                OrganizerFolderTitle(name: folder.name, count: count, isCollapsed: isCollapsed)
            }
            .buttonStyle(.plain)
            Menu {
                Button("重命名") {
                    renameValue = folder.name
                    showRename = true
                }
                Button("删除文件夹", role: .destructive) { showDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(isDropTarget ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered ? 0.075 : 0.04),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isDropTarget ? Color.accentColor : Color.primary.opacity(0.055)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .alert("重命名文件夹", isPresented: $showRename) {
            TextField("文件夹名称", text: $renameValue)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { _ = await model.renameSkillFolder(folder, to: renameValue) } }
        }
        .alert("删除“\(folder.name)”文件夹？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除文件夹", role: .destructive) { Task { await model.deleteSkillFolder(folder) } }
        } message: {
            Text("里面的 Skill 会回到“未分类”，原件和安装状态都不会改变。")
        }
    }
}

private struct SkillOrganizerRow: View {
    private enum StorageState {
        case loading
        case available(Int64)
        case unavailable
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let skill: SkillRecord
    let folderID: UUID?
    @Binding var selectedSkillID: UUID?
    @Binding var showSyncPreview: Bool
    let dragSession: SkillOrganizerDragSession
    let dragOffsetY: CGFloat
    let previewOffsetY: CGFloat
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    @State private var isHovered = false
    @State private var storageState: StorageState = .loading
    @State private var showDeleteConfirmation = false
    @State private var showRemovalOptions = false
    @State private var showSyncPreviewAfterRemovalOptions = false

    private var isSelected: Bool { selectedSkillID == skill.id }
    private var disposition: SkillOrganizerRowDisposition {
        SkillOrganizerRowPresentation.disposition(session: dragSession, rowID: skill.id)
    }
    private var isDragging: Bool {
        SkillOrganizerRowPresentation.floatingSkillID(session: dragSession) == skill.id
    }

    var body: some View {
        ZStack {
            rowCard
                .opacity(disposition == .placeholder ? 0 : 1)
                .offset(y: previewOffsetY)
                .accessibilityHidden(disposition == .placeholder)
            if isDragging {
                rowCard
                    .shadow(color: Color.black.opacity(0.13), radius: 9, y: 4)
                    .offset(y: dragOffsetY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .zIndex(isDragging ? 10 : 0)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SkillOrganizerRowFramesPreferenceKey.self,
                    value: [skill.id: proxy.frame(in: .named(SkillOrganizerCoordinateSpace.name))]
                )
            }
        }
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(
                minimumDistance: 8,
                coordinateSpace: .named(SkillOrganizerCoordinateSpace.name)
            )
            .onChanged(onDragChanged)
            .onEnded(onDragEnded)
        )
        .contextMenu {
            Menu("移动到") {
                Button("未分类") { moveSkill(to: nil) }
                    .disabled(folderID == nil)
                ForEach(model.orderedFolders()) { folder in
                    Button(folder.name) { moveSkill(to: folder.id) }
                        .disabled(folder.id == folderID)
                }
            }
            Divider()
            Button("删除 Skill…", role: .destructive) {
                if model.hasManagedInstallation(for: skill) {
                    showRemovalOptions = true
                } else {
                    showDeleteConfirmation = true
                }
            }
        }
        .task(id: skill.fingerprint) {
            storageState = .loading
            if let byteCount = await model.skillStorageSize(skill) {
                storageState = .available(byteCount)
            } else {
                storageState = .unavailable
            }
        }
        .confirmationDialog(
            "删除“\(skill.displayName)”？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                Task {
                    if await model.deleteSkill(skill) { finishDeletion() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("中央内容会移到 macOS 废纸篓，可以立即撤销；清空废纸篓后将无法恢复。其他应用中未由 SkillBox 管理的文件不会被改动。")
        }
        .sheet(isPresented: $showRemovalOptions, onDismiss: {
            guard showSyncPreviewAfterRemovalOptions else { return }
            showSyncPreviewAfterRemovalOptions = false
            showSyncPreview = true
        }) {
            SkillRemovalOptionsView(
                model: model,
                skill: skill,
                isPresented: $showRemovalOptions,
                onDeleted: finishDeletion,
                onPreparedUninstall: {
                    showSyncPreviewAfterRemovalOptions = true
                    showRemovalOptions = false
                }
            )
        }
        .help("拖动调整顺序，或右键移动和删除")
    }

    private var rowCard: some View {
        Button { selectedSkillID = skill.id } label: {
            HStack(spacing: 9) {
                SkillOrganizerSourceIconView(sourceKind: skill.source.kind)
                    .frame(width: 22, height: 22)
                    .frame(width: 26, height: 26)
                Text(skill.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(storageText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 68, alignment: .trailing)
                    .help("大小只计算 SkillBox 中央库里的这份内容")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowBackground: Color {
        if isDragging || isSelected { return .accentColor.opacity(0.16) }
        if isHovered { return .primary.opacity(0.055) }
        return .clear
    }

    private var storageText: String {
        switch storageState {
        case .loading:
            "正在计算…"
        case let .available(byteCount):
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        case .unavailable:
            "大小不可用"
        }
    }

    private func finishDeletion() {
        if selectedSkillID == skill.id {
            selectedSkillID = model.snapshot.skills.first?.id
        }
    }

    private func moveSkill(to destinationFolderID: UUID?) {
        Task { await model.moveSkill(skill.id, to: destinationFolderID) }
    }
}

private struct SkillOrganizerSourceIconView: View {
    let sourceKind: SkillSourceKind

    var body: some View {
        Group {
            switch SkillOrganizerRowPresentation.sourceIcon(for: sourceKind) {
            case .githubMark:
                GitHubSourceMark()
                    .foregroundStyle(.primary)
            case let .system(name, tint):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint == .blue ? Color.blue : Color.secondary)
            }
        }
        .padding(1)
        .help(SkillOrganizerRowPresentation.sourceLabel(for: sourceKind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SkillOrganizerRowPresentation.sourceLabel(for: sourceKind))
    }
}

private struct GitHubSourceMark: View {
    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private static let image: NSImage = {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">
          <path d="M8 0C3.58 0 0 3.64 0 8.13c0 3.59 2.29 6.63 5.47 7.71.4.08.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.59 1.23.83.72 1.22 1.87.88 2.33.67.07-.53.28-.88.51-1.08-1.78-.2-3.64-.9-3.64-4 0-.88.31-1.61.82-2.18-.08-.2-.36-1.03.08-2.15 0 0 .67-.22 2.2.83A7.4 7.4 0 0 1 8 4.11c.68 0 1.36.09 2 .27 1.53-1.05 2.2-.83 2.2-.83.44 1.12.16 1.95.08 2.15.51.57.82 1.29.82 2.18 0 3.11-1.87 3.8-3.65 4 .29.25.54.73.54 1.49 0 1.08-.01 1.94-.01 2.21 0 .21.15.46.55.38A8.02 8.02 0 0 0 16 8.13C16 3.64 12.42 0 8 0Z" fill="black"/>
        </svg>
        """#
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: nil
        )!
        image.isTemplate = true
        return image
    }()
}

private struct SkillOrganizerDropIndicator: View {
    let destination: SkillOrganizerDropDestination

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(destination.accessibilityLabel)
            .allowsHitTesting(false)
    }
}

private enum OrganizerDragItem: Sendable {
    case skill(UUID)
    case folder(UUID)

    init?(_ value: String) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "skill": self = .skill(id)
        case "folder": self = .folder(id)
        default: return nil
        }
    }

    var skillID: UUID? {
        if case let .skill(id) = self { return id }
        return nil
    }
}

private struct SkillBoxHoverButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructiveText
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        SkillBoxHoverButtonBody(configuration: configuration, kind: kind)
    }
}

private struct SkillBoxHoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SkillBoxHoverButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.callout.weight(kind == .primary ? .semibold : .medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, kind == .destructiveText ? 8 : 11)
            .padding(.vertical, kind == .destructiveText ? 5 : 7)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .primary
        case .destructiveText: return .red
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return Color.accentColor.opacity(configuration.isPressed ? 0.76 : isHovered ? 0.86 : 1)
        case .secondary:
            return Color.primary.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.075 : 0.035)
        case .destructiveText:
            return Color.red.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.10 : 0)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return Color(nsColor: .separatorColor).opacity(isHovered ? 0.9 : 0.55)
        case .destructiveText: return isHovered ? Color.red.opacity(0.22) : .clear
        }
    }
}

private struct GitHubSourceCard: View {
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    let openSettings: () -> Void

    private var state: GitHubSourceState? {
        model.snapshot.sourceStates.first { $0.skillID == skill.id }
    }

    private var needsLegacyPackageCleanup: Bool {
        guard let state, state.requiresPackageReview else { return false }
        return ![.updateAvailable, .releasePackageAvailable, .packageReviewRequired].contains(state.status)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title).font(.headline)
                    if let version = state?.availableVersionName,
                       state?.status == .updateAvailable || state?.status == .releasePackageAvailable || state?.status == .ignored {
                        Text(version)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.11), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(SkillBoxHoverButtonStyle(kind: isActionableUpdate ? .primary : .secondary))
                .disabled(model.isBusy || state == nil)
            if let state {
                Menu {
                    Button("在 GitHub 打开") { model.openGitHubSource(skill) }
                    Menu("更新来源") {
                        Button {
                            Task { await model.setGitHubTrackingMode(.latestStableRelease, for: skill) }
                        } label: {
                            Label("最新正式 Release", systemImage: state.trackingMode == .latestStableRelease ? "checkmark" : "tag")
                        }
                        Button {
                            Task { await model.setGitHubTrackingMode(.defaultBranch, for: skill) }
                        } label: {
                            Label("默认分支", systemImage: state.trackingMode == .defaultBranch ? "checkmark" : "arrow.triangle.branch")
                        }
                    }
                    if state.status == .updateAvailable || state.status == .releasePackageAvailable {
                        Button("忽略这个版本") {
                            Task { await model.ignoreAvailableUpdate(skill) }
                        }
                    }
                    if state.checkingEnabled {
                        Button("停止检查更新") {
                            Task { await model.setUpdateChecking(false, for: skill) }
                        }
                    } else {
                        Button("重新开启更新检查") {
                            Task { await model.setUpdateChecking(true, for: skill) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("更多更新选项")
                .accessibilityLabel("更多更新选项")
            }
        }
        .padding(14)
        .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.17)))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired: return "私人仓库连接已失效"
            case .repositoryPermissionRequired: return "需要允许访问这个私人仓库"
            case .rateLimited: return "GitHub 暂时无法继续检查"
            case .repositoryMissing: return "找不到原来的 GitHub 仓库"
            case .temporarilyUnavailable: return "暂时无法连接 GitHub"
            }
        }
        if needsLegacyPackageCleanup {
            return "整理成纯净 Skill"
        }
        return switch state?.status {
        case .updateAvailable: "发现新版本"
        case .releasePackageAvailable: "有更干净的安装包"
        case .packageReviewRequired: "需要确认新的安装内容"
        case .ignored: "这个版本已忽略"
        case .checkingStopped: "已停止检查更新"
        case .authenticationRequired: "需要重新连接 GitHub"
        case .unavailable: "暂时无法检查更新"
        case .needsInitialCheck: "需要核对一次来源"
        case .current: "GitHub 来源已是最新"
        case nil: "GitHub 更新来源尚未准备好"
        }
    }

    private var subtitle: String {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired:
                return "本地 Skill 不受影响。重新连接后，私人仓库才会继续检查。"
            case .repositoryPermissionRequired:
                return "本地 Skill 不受影响。请在 GitHub 中把这个仓库加入允许访问的列表。"
            case .rateLimited:
                if let retryAfter = state?.retryAfter {
                    return "预计 \(retryAfter.formatted(date: .omitted, time: .shortened)) 后可继续，SkillBox 会保留当前结果。"
                }
                return "请稍后再试，本地 Skill 和已安装副本都不受影响。"
            case .repositoryMissing:
                return "仓库可能已改名、删除或改为私人仓库。本地 Skill 仍然保留。"
            case .temporarilyUnavailable:
                return "可能是网络或 GitHub 临时异常。本地内容没有变化，请稍后重试。"
            }
        }
        if needsLegacyPackageCleanup {
            return "这份旧 Skill 包含了 GitHub 仓库资料。整理一次后，以后只会安装运行所需内容。"
        }
        return switch state?.status {
        case .updateAvailable: "先查看文件变化，再决定是否更新和重新安装。"
        case .releasePackageAvailable: "这是同一个 GitHub Release，不是作者新发了版本。建议查看后替换为作者提供的纯净安装包。"
        case .packageReviewRequired: "作者新增了可能属于 Skill 的内容。确认后，SkillBox 会继续沿用你的选择。"
        case .ignored: "这次不再提醒；GitHub 出现下一个版本时仍会告诉你。"
        case .checkingStopped: "SkillBox 不会再访问这个仓库，可随时重新开启。"
        case .authenticationRequired: "本地内容仍然保留，重新授权后才能继续检查。"
        case .unavailable: "仓库或网络暂时不可用，本地内容没有变化。"
        case .needsInitialCheck: "这份旧记录来自升级前，需要你手动检查一次。"
        case .current:
            if let checked = state?.lastCheckedAt {
                "上次检查：\(checked.formatted(date: .abbreviated, time: .shortened))"
            } else {
                "点击即可只检查版本信息，不会下载仓库。"
            }
        case nil: "重新添加来源后即可开始检查更新。"
        }
    }

    private var primaryTitle: String {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired: return "前往设置"
            case .repositoryPermissionRequired: return "允许访问"
            case .rateLimited: return isWaitingForRateLimit ? "稍后可重试" : "重新检查"
            case .repositoryMissing: return "查看原仓库"
            case .temporarilyUnavailable: return "重新检查"
            }
        }
        if needsLegacyPackageCleanup { return "开始整理" }
        return switch state?.status {
        case .updateAvailable, .ignored: "查看这次更新"
        case .releasePackageAvailable: "查看安装包变化"
        case .packageReviewRequired: "确认安装内容"
        case .checkingStopped: "重新开启"
        case .authenticationRequired: "前往设置"
        default: "检查更新"
        }
    }

    private var icon: String {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired: return "person.crop.circle.badge.exclamationmark"
            case .repositoryPermissionRequired: return "lock.trianglebadge.exclamationmark"
            case .rateLimited: return "clock.badge.exclamationmark"
            case .repositoryMissing: return "link.badge.plus"
            case .temporarilyUnavailable: return "wifi.exclamationmark"
            }
        }
        if needsLegacyPackageCleanup { return "shippingbox.and.arrow.backward.fill" }
        return switch state?.status {
        case .updateAvailable: "arrow.down.circle.fill"
        case .releasePackageAvailable: "archivebox.fill"
        case .packageReviewRequired: "checklist"
        case .ignored: "eye.slash.fill"
        case .checkingStopped: "pause.circle.fill"
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "wifi.exclamationmark"
        case .needsInitialCheck: "questionmark.circle.fill"
        case .current: "checkmark.circle.fill"
        case nil: "link.badge.plus"
        }
    }

    private var color: Color {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired, .repositoryPermissionRequired: return .orange
            case .rateLimited, .repositoryMissing, .temporarilyUnavailable: return .secondary
            }
        }
        if needsLegacyPackageCleanup { return .orange }
        return switch state?.status {
        case .updateAvailable, .releasePackageAvailable: .blue
        case .ignored, .checkingStopped, .needsInitialCheck, .packageReviewRequired: .orange
        case .authenticationRequired, .unavailable: .red
        case .current: .green
        case nil: .secondary
        }
    }

    private func primaryAction() {
        if let issue = state?.lastCheckIssue {
            switch issue {
            case .authenticationRequired:
                openSettings()
            case .repositoryPermissionRequired:
                if model.isGitHubConnected { model.manageGitHubRepositories() }
                else { openSettings() }
            case .repositoryMissing:
                model.openGitHubSource(skill)
            case .rateLimited, .temporarilyUnavailable:
                Task { await model.checkForUpdate(skill) }
            }
            return
        }
        if needsLegacyPackageCleanup {
            model.startInstallContentReview(skill)
            return
        }
        switch state?.status {
        case .updateAvailable, .releasePackageAvailable, .ignored:
            model.startAvailableUpdatePreview(skill)
        case .packageReviewRequired:
            model.startInstallContentReview(skill)
        case .checkingStopped:
            Task {
                await model.setUpdateChecking(true, for: skill)
                await model.checkForUpdate(skill)
            }
        case .authenticationRequired:
            openSettings()
        default:
            Task { await model.checkForUpdate(skill) }
        }
    }

    private var isActionableUpdate: Bool {
        state?.lastCheckIssue == nil && (
            needsLegacyPackageCleanup ||
            state?.status == .updateAvailable ||
            state?.status == .releasePackageAvailable ||
            state?.status == .packageReviewRequired
        )
    }

    private var isWaitingForRateLimit: Bool {
        guard state?.lastCheckIssue == .rateLimited,
              let retryAfter = state?.retryAfter
        else { return false }
        return retryAfter > Date()
    }
}

private struct LocalSourceCard: View {
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    @State private var showStopConfirmation = false

    private var state: LocalSourceState? {
        model.snapshot.localSourceStates.first { $0.skillID == skill.id }
    }

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 38, height: 38)
                        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(title).font(.headline)
                            if state.status == .updateAvailable {
                                Text("有更新")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.blue.opacity(0.10), in: Capsule())
                            }
                        }
                        Text(sourcePath(state))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(sourcePath(state))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    Button(primaryTitle) { primaryAction(state) }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: isActionable ? .primary : .secondary))
                        .disabled(model.isBusy || model.isCheckingLocalSources)
                    Menu {
                        Button("在 Finder 中显示") { model.openLocalSource(state) }
                        Button("编辑可使用内容") {
                            Task { await model.prepareLocalContentReview(skill) }
                        }
                        Divider()
                        Button("停止跟踪开发源") { showStopConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("更多本地开发源选项")
                    .disabled(model.isBusy)
                }

                if state.status == .updateAvailable {
                    Text("可使用内容已经变化。开发项目里的其他文件仍会留在原处，不会进入 SkillBox。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }

                Divider().opacity(0.55)
                HStack(alignment: .top, spacing: 10) {
                    Text("进入 SkillBox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.recipe.includePaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Button("编辑范围") {
                        Task { await model.prepareLocalContentReview(skill) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .disabled(model.isBusy)
                }
            }
            .padding(14)
            .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.17)))
            .confirmationDialog(
                "停止跟踪这个开发源？",
                isPresented: $showStopConfirmation,
                titleVisibility: .visible
            ) {
                Button("停止跟踪") { Task { await model.stopTrackingLocalSource(skill) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前 Skill、历史版本和所有应用副本都会保留。以后不再检查这个项目的变化。")
            }
        }
    }

    private var title: String {
        if state?.lastCheckError != nil { return "本地来源检查失败" }
        return switch state?.status {
        case .current: "本地开发源已核对"
        case .updateAvailable: "有可使用内容更新"
        case .packageReviewRequired: "需要确认可使用内容"
        case .sourceUnavailable: "找不到本地开发源"
        case nil: "本地开发源"
        }
    }

    private var subtitle: String {
        guard let state else { return "" }
        if let error = state.lastCheckError { return error }
        switch state.status {
        case .current:
            if let checked = state.lastCheckedAt {
                return "上次核对：\(checked.formatted(date: .abbreviated, time: .shortened))"
            }
            return "点击即可只读检查项目，不会修改任何文件。"
        case .updateAvailable:
            return "先查看文件变化，再决定是否更新和重新安装。"
        case .packageReviewRequired:
            return "来源中出现了新内容或原来选择的内容已变化，需要重新核对一次。"
        case .sourceUnavailable:
            return "SkillBox 主 Skill 和应用副本均已保留。选择新位置即可重新关联。"
        }
    }

    private var primaryTitle: String {
        if model.isCheckingLocalSources { return "正在检查…" }
        if state?.lastCheckError != nil { return "重新检查" }
        return switch state?.status {
        case .updateAvailable: "查看更新"
        case .packageReviewRequired: "确认内容"
        case .sourceUnavailable: "重新关联"
        default: "检查更新"
        }
    }

    private var icon: String {
        if state?.lastCheckError != nil { return "exclamationmark.circle" }
        return switch state?.status {
        case .current: "checkmark.circle.fill"
        case .updateAvailable: "arrow.down.circle.fill"
        case .packageReviewRequired: "checklist"
        case .sourceUnavailable: "folder.badge.questionmark"
        case nil: "folder"
        }
    }

    private var color: Color {
        if state?.lastCheckError != nil { return .orange }
        return switch state?.status {
        case .current: .green
        case .updateAvailable: .blue
        case .packageReviewRequired: .orange
        case .sourceUnavailable: .red
        case nil: .secondary
        }
    }

    private var isActionable: Bool {
        state?.lastCheckError != nil || state?.status != .current
    }

    private func primaryAction(_ state: LocalSourceState) {
        if state.lastCheckError != nil {
            Task { await model.checkLocalSource(skill) }
            return
        }
        switch state.status {
        case .current, .updateAvailable:
            Task { await model.checkLocalSource(skill) }
        case .packageReviewRequired:
            Task { await model.prepareLocalContentReview(skill) }
        case .sourceUnavailable:
            chooseRelinkLocation()
        }
    }

    private func chooseRelinkLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新关联"
        panel.message = "选择 Skill 本身，或包含它的本地项目文件夹。"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.relinkLocalSource(skill, projectRoot: url) }
        }
    }

    private func sourcePath(_ state: LocalSourceState) -> String {
        guard !state.recipe.skillRelativePath.isEmpty else { return state.projectRootPath }
        return URL(fileURLWithPath: state.projectRootPath)
            .appendingPathComponent(state.recipe.skillRelativePath)
            .path
    }
}

private struct SkillDetailView: View {
    private enum Confirmation: String, Identifiable {
        case installEverywhere
        case uninstallEverywhere
        case delete
        var id: String { rawValue }
    }

    private enum DetailSection: String, CaseIterable, Identifiable {
        case introduction = "Skill 介绍"
        case files = "文件详情"
        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let skill: SkillRecord
    @Binding var showSyncPreview: Bool
    let openSettings: () -> Void
    let openAISettings: () -> Void
    let onDeleted: () -> Void
    @State private var showRawSource = false
    @State private var showInstallManager = false
    @State private var showSafetyDetails = false
    @State private var directoryEntries: [SkillDirectoryEntry] = []
    @State private var usageGuide: SkillUsageGuide?
    @State private var isLoadingDirectory = true
    @State private var detailSection: DetailSection = .introduction
    @State private var confirmation: Confirmation?
    @State private var showRemovalOptions = false
    @State private var showSyncPreviewAfterRemovalOptions = false
    @State private var showRiskConfirmation = false
    @State private var continueInstallAfterRiskConfirmation = false
    @State private var showInstallConfirmationAfterRiskSheet = false

    private var availableTargets: [AgentTarget] { model.availableTargets() }
    private var unavailableTargets: [AgentTarget] { model.unavailableTargets() }
    private var hasInstallations: Bool { model.hasManagedInstallation(for: skill) }
    private var hasDesiredAssignments: Bool {
        model.snapshot.assignments.contains { $0.skillID == skill.id && $0.isDesired }
    }
    private var installedTargets: [AgentTarget] {
        let targetIDs = Set(model.snapshot.installations.filter { $0.skillID == skill.id }.map(\.targetID))
        return model.snapshot.targets.filter { targetIDs.contains($0.id) }
    }
    private var mainMarkdown: SkillDirectoryEntry? {
        directoryEntries.first { $0.relativePath.caseInsensitiveCompare("SKILL.md") == .orderedSame }
    }
    private var githubState: GitHubSourceState? {
        model.snapshot.sourceStates.first { $0.skillID == skill.id }
    }
    private var localState: LocalSourceState? {
        model.snapshot.localSourceStates.first { $0.skillID == skill.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHeader
                detailMetaGrid

                if sourceNeedsAttention || localState != nil {
                    sourceAttentionCard
                }

                installSummaryCard
                detailTabs

                Group {
                    if detailSection == .introduction {
                        VStack(alignment: .leading, spacing: 16) {
                            usageGuideActionBar

                            if let usageGuide {
                                SkillUsageGuideCard(guide: usageGuide)
                            } else if model.generatingUsageGuideSkillIDs.contains(skill.id) {
                                SkillUsageGuideLoadingCard()
                            } else {
                                ContentUnavailableView(
                                    "还没有生成使用说明",
                                    systemImage: "text.bubble",
                                    description: Text("点击上方按钮，让 AI 把这份 Skill 讲清楚。")
                                )
                                .frame(minHeight: 150)
                            }

                            if model.shouldShowRiskAttention(for: skill) {
                                riskSummary
                            } else if model.isRiskAcknowledged(for: skill) {
                                riskAcknowledgedSummary
                            }
                        }
                    } else {
                        fileDetails
                    }
                }
                .id(detailSection)
                .transition(.opacity)
            }
            .frame(maxWidth: 940, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .sheet(isPresented: $showRawSource) {
            SkillRawSourceView(model: model, skill: skill, isPresented: $showRawSource)
        }
        .sheet(isPresented: $showInstallManager) {
            SkillInstallManagerView(
                model: model,
                skill: skill,
                isPresented: $showInstallManager
            )
        }
        .sheet(isPresented: $showRiskConfirmation, onDismiss: {
            continueInstallAfterRiskConfirmation = false
            guard showInstallConfirmationAfterRiskSheet else { return }
            showInstallConfirmationAfterRiskSheet = false
            confirmation = .installEverywhere
        }) {
            riskConfirmationSheet
        }
        .sheet(isPresented: $showRemovalOptions, onDismiss: {
            guard showSyncPreviewAfterRemovalOptions else { return }
            showSyncPreviewAfterRemovalOptions = false
            showSyncPreview = true
        }) {
            SkillRemovalOptionsView(
                model: model,
                skill: skill,
                isPresented: $showRemovalOptions,
                onDeleted: onDeleted,
                onPreparedUninstall: {
                    showSyncPreviewAfterRemovalOptions = true
                    showRemovalOptions = false
                }
            )
        }
        .task(id: skill.id) {
            isLoadingDirectory = true
            showSafetyDetails = false
            async let entries = model.skillDirectory(skill)
            async let guide = model.skillUsageGuide(skill)
            directoryEntries = await entries
            usageGuide = await guide
            isLoadingDirectory = false
        }
        .onChange(of: model.usageGuideRevision) { _, _ in
            Task { usageGuide = await model.skillUsageGuide(skill) }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            presenting: confirmation
        ) { choice in
            switch choice {
            case .installEverywhere:
                if availableTargets.isEmpty {
                    Button("知道了", role: .cancel) {}
                } else {
                    Button("继续，查看安装清单") {
                        Task {
                            if await model.prepareInstallEverywhere(skill) { showSyncPreview = true }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            case .uninstallEverywhere:
                Button("继续，查看卸载清单") {
                    Task {
                        if await model.prepareUninstallEverywhere(skill) { showSyncPreview = true }
                    }
                }
                Button("取消", role: .cancel) {}
            case .delete:
                Button("删除", role: .destructive) {
                    Task {
                        if await model.deleteSkill(skill) { onDeleted() }
                    }
                }
                Button("取消", role: .cancel) {}
            }
        } message: { choice in
            Text(confirmationMessage(for: choice))
        }
    }

    private var usageGuideActionBar: some View {
        HStack(spacing: 12) {
            Label(SkillDetailLayout.aiGuideLabel, systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if model.generatingUsageGuideSkillIDs.contains(skill.id) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在获取…")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 32)
            } else {
                Button(model.isAgnesUsageGuideConfigured
                       ? (usageGuide?.origin == .aiAssisted ? "重新获取" : "获取 Skill 介绍")
                       : SkillDetailLayout.connectAIButtonTitle) {
                    guard model.isAgnesUsageGuideConfigured else {
                        model.noticeMessage = "请在“设置 → AI”中连接用于生成 Skill 介绍的 AI 服务。"
                        openAISettings()
                        return
                    }
                    Task {
                        if let generated = await model.generateSkillUsageGuide(skill) {
                            usageGuide = generated
                        }
                    }
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .help(model.isAgnesUsageGuideConfigured
                      ? "点击后才会把当前 Skill 的说明文件发给你已连接的 AI 服务"
                      : "先连接你的 AI 服务")
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 36)
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 15) {
            Text(String(skill.displayName.prefix(1)).uppercased())
                .font(.title2.bold())
                .foregroundStyle(.blue)
                .frame(width: 54, height: 54)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(skill.displayName)
                    .font(.title2.bold())
                Text(skill.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button("管理安装") { showInstallManager = true }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .fixedSize()
            Menu {
                Button("在 Finder 中显示") {
                    Task { model.reveal(await model.contentURL(for: skill)) }
                }
                if skill.source.kind == .github {
                    Button("在 GitHub 打开") { model.openGitHubSource(skill) }
                }
                Divider()
                Button("删除这份 Skill", role: .destructive) {
                    requestRemoval()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
    }

    private var detailMetaGrid: some View {
        HStack(alignment: .top, spacing: 11) {
            detailMetaCard(
                title: SkillDetailLayout.metaTitles[0],
                value: sourceKindTitle,
                detail: sourceDetail,
                tint: .blue
            ) {
                SkillOrganizerSourceIconView(sourceKind: skill.source.kind)
                    .frame(width: 19, height: 19)
            }
            .frame(maxWidth: .infinity)

            detailMetaCard(
                title: SkillDetailLayout.metaTitles[1],
                value: currentVersionText,
                detail: "内容校验码 \(String(skill.fingerprint.prefix(8)))",
                tint: .secondary
            ) {
                Image(systemName: "shippingbox.fill")
            }
            .frame(maxWidth: .infinity)

            detailMetaCard(
                title: SkillDetailLayout.metaTitles[2],
                value: versionStatusText,
                detail: versionStatusDetail,
                tint: versionStatusTint
            ) {
                Image(systemName: versionStatusIcon)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailMetaCard<Icon: View>(
        title: String,
        value: String,
        detail: String,
        tint: Color,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                icon()
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(detail)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.42)))
    }

    @ViewBuilder
    private var sourceAttentionCard: some View {
        if skill.source.kind == .github {
            GitHubSourceCard(model: model, skill: skill, openSettings: openSettings)
        } else if localState != nil {
            LocalSourceCard(model: model, skill: skill)
        }
    }

    private var installSummaryCard: some View {
        HStack(spacing: 16) {
            HStack(spacing: -7) {
                ForEach(Array(installedTargets.prefix(4))) { target in
                    AgentProductIcon(target: target, size: 28)
                        .padding(3)
                        .background(.background, in: Circle())
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
                if installedTargets.isEmpty {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 36, height: 36)
                        .background(.background, in: Circle())
                }
            }
            .frame(minWidth: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("安装情况")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(installationSummaryTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(installationAvailabilityMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("全部安装") {
                requestInstallEverywhere()
            }
            .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            .fixedSize()
            .disabled(availableTargets.isEmpty || skill.riskReport.isBlocked)
            .help(installButtonHelp)
            Button("全部卸载") {
                confirmation = .uninstallEverywhere
            }
            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            .fixedSize()
            .disabled(!hasInstallations && !hasDesiredAssignments)
        }
        .padding(16)
        .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.14)))
    }

    private var detailTabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(DetailSection.allCases) { section in
                    Button {
                        if reduceMotion {
                            detailSection = section
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                detailSection = section
                            }
                        }
                    } label: {
                        VStack(spacing: 0) {
                            Text(section.rawValue)
                                .font(.callout.weight(detailSection == section ? .semibold : .regular))
                                .foregroundStyle(detailSection == section ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Rectangle()
                                .fill(detailSection == section ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity, minHeight: SkillDetailLayout.tabMinimumHitHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SkillDetailTabButtonStyle())
                    .accessibilityValue(detailSection == section ? "已选中" : "")
                }
            }

            if detailSection == .introduction, model.generatingUsageGuideSkillIDs.contains(skill.id) {
                Label("AI 正在补充这份介绍", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 7)
            } else if detailSection == .introduction, let usageGuide {
                Label(guideSourceNote(usageGuide), systemImage: usageGuide.origin == .aiAssisted ? "sparkles" : "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 7)
            } else {
                Text("\(skill.riskReport.scannedFileCount) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 7)
            }
        }
        .overlay(alignment: .top) {
            Divider()
                .offset(y: SkillDetailLayout.tabMinimumHitHeight - 0.5)
                .zIndex(-1)
        }
    }

    private var sourceNeedsAttention: Bool {
        if let githubState {
            return githubState.lastCheckIssue != nil || githubState.status != .current
        }
        if let localState {
            return localState.lastCheckError != nil || localState.status != .current
        }
        return false
    }

    private var sourceKindTitle: String {
        switch skill.source.kind {
        case .github: "GitHub 仓库"
        case .localFolder: "本地开发文件夹"
        case .agentDirectory: "应用目录导入"
        }
    }

    private var sourceDetail: String {
        if let githubState { return githubState.repositoryFullName }
        if let localState {
            return URL(fileURLWithPath: localState.projectRootPath).lastPathComponent
        }
        return skill.source.displayName
    }

    private var currentVersionText: String {
        if let githubState {
            if let name = githubState.currentVersionName, !name.isEmpty { return name }
            if let commit = githubState.currentCommitSHA, !commit.isEmpty {
                return "提交 \(String(commit.prefix(7)))"
            }
        }
        if let localState {
            return "本地快照 \(String(localState.currentPackageFingerprint.prefix(7)))"
        }
        return "当前内容"
    }

    private var versionStatusText: String {
        if let githubState {
            if githubState.lastCheckIssue != nil { return "暂时无法检查" }
            return switch githubState.status {
            case .current: "已是最新"
            case .updateAvailable: "有新版本"
            case .releasePackageAvailable: "安装包可更新"
            case .packageReviewRequired: "更新前需确认"
            case .ignored: "已忽略本次更新"
            case .checkingStopped: "已停止检查"
            case .authenticationRequired: "需要连接 GitHub"
            case .unavailable: "来源暂不可用"
            case .needsInitialCheck: "等待首次检查"
            }
        }
        if let localState {
            if localState.lastCheckError != nil { return "暂时无法检查" }
            return switch localState.status {
            case .current: localState.lastCheckedAt == nil ? "尚未检查" : "上次检查一致"
            case .updateAvailable: "开发内容有更新"
            case .packageReviewRequired: "更新前需确认"
            case .sourceUnavailable: "找不到开发文件夹"
            }
        }
        return "当前内容"
    }

    private var versionStatusDetail: String {
        if let checkedAt = githubState?.lastCheckedAt ?? localState?.lastCheckedAt {
            return "检查于 \(checkedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return sourceNeedsAttention ? "点击下方提示继续处理" : "尚未检查来源变化"
    }

    private var versionStatusTint: Color {
        guard sourceNeedsAttention else { return .green }
        if githubState?.status == .updateAvailable ||
            githubState?.status == .releasePackageAvailable ||
            localState?.status == .updateAvailable {
            return .blue
        }
        return .orange
    }

    private var versionStatusIcon: String {
        guard sourceNeedsAttention else { return "checkmark.circle.fill" }
        if githubState?.status == .updateAvailable ||
            githubState?.status == .releasePackageAvailable ||
            localState?.status == .updateAvailable {
            return "arrow.down.circle.fill"
        }
        return "exclamationmark.circle.fill"
    }

    private var installationSummaryTitle: String {
        guard !installedTargets.isEmpty else { return "还没有安装到任何 Agent" }
        let shownNames = installedTargets.prefix(3).map(\.displayName).joined(separator: "、")
        if installedTargets.count > 3 {
            return "已安装到 \(shownNames) 等 \(installedTargets.count) 个 Agent"
        }
        return "已安装到 \(shownNames)"
    }

    private func guideSourceNote(_ guide: SkillUsageGuide) -> String {
        if guide.origin == .aiAssisted { return "AI 已整理 · 依据当前版本" }
        return "依据当前版本的作者资料"
    }

    private func requestInstallEverywhere() {
        if model.needsRiskAcknowledgement(for: skill) {
            continueInstallAfterRiskConfirmation = true
            showRiskConfirmation = true
        } else {
            confirmation = .installEverywhere
        }
    }

    private func requestRemoval() {
        if hasInstallations {
            showRemovalOptions = true
        } else {
            confirmation = .delete
        }
    }

    private var fileDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(fileSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if mainMarkdown != nil {
                    Button("查看 SKILL.md") { showRawSource = true }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                }
                Button("在 Finder 中显示") {
                    Task { model.reveal(await model.contentURL(for: skill)) }
                }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            }
            if isLoadingDirectory {
                ProgressView("正在读取目录…")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if directoryEntries.isEmpty {
                ContentUnavailableView("无法读取目录", systemImage: "folder.badge.questionmark")
                    .frame(minHeight: 170)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label(skill.canonicalName, systemImage: "folder.fill")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(fileTreeSizeText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
                        ForEach(directoryEntries) { entry in
                            SkillDirectoryRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 430)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.55)))
            }
            Text("内容校验码 \(String(skill.fingerprint.prefix(12)))… · 用来确认文件有没有被改过")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var fileSummary: String {
        "当前安装版本共 \(fileCount) 个文件 · \(fileTreeSizeText)"
    }

    private var fileCount: Int {
        directoryEntries.filter { $0.kind != .directory }.count
    }

    private var fileTreeSizeText: String {
        let bytes = directoryEntries.compactMap(\.fileSize).reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var riskSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: riskSummaryIcon)
                    .font(.title3)
                    .foregroundStyle(riskTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.riskReport.isBlocked ? "这份 Skill 已被安全检查阻止" : "安装前，有 \(skill.riskReport.actionableFindings.count) 项内容需要你了解")
                        .font(.headline)
                    Text(skill.riskReport.isBlocked ? "你仍可以查看发现了什么，但无法安装。" : "看完并作出选择后，这条提示就会收起。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(skill.riskReport.isBlocked ? "已阻止" : "待了解")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(riskTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(riskTint.opacity(0.10), in: Capsule())
            }
            Divider().opacity(0.5)

            if let finding = skill.riskReport.actionableFindings.first {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(riskFindingTitle(finding)).font(.callout.weight(.medium))
                        Spacer()
                        Text(riskLevel(finding.severity))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(riskFindingColor(finding.severity))
                    }
                    Text(riskFindingExplanation(finding))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showSafetyDetails {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(skill.riskReport.actionableFindings.prefix(6)) { finding in
                        if let evidence = riskEvidence(finding) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.relativePath)
                                    .font(.caption.weight(.medium))
                                Text(evidence)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
                .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
                .transition(.opacity)
            }

            HStack {
                Button(showSafetyDetails ? "收起技术证据" : "查看技术证据") {
                    if reduceMotion { showSafetyDetails.toggle() }
                    else { withAnimation(.easeOut(duration: 0.14)) { showSafetyDetails.toggle() } }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                Spacer()
                if !skill.riskReport.isBlocked {
                    Button("查看并确认") {
                        continueInstallAfterRiskConfirmation = false
                        showRiskConfirmation = true
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                }
            }
            Text("这是文件内容提示，不代表 Skill 已经运行，也不代表它一定有问题。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(riskTint.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(riskTint.opacity(0.15)))
    }

    private var riskAcknowledgedSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("你已了解这项内容")
                    .font(.callout.weight(.medium))
                Text("确认对应 \(skill.displayName) 的当前内容版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新查看") {
                continueInstallAfterRiskConfirmation = false
                showRiskConfirmation = true
            }
            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
        }
        .padding(13)
        .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.green.opacity(0.16)))
    }

    private var riskConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: riskSummaryIcon)
                    .font(.title2)
                    .foregroundStyle(riskTint)
                    .frame(width: 38, height: 38)
                    .background(riskTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.riskReport.isBlocked ? "查看安全检查结果" : "确认这项风险提示")
                        .font(.title2.bold())
                    Text("先看清它可能在什么时候发生，再决定是否继续安装。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(skill.riskReport.actionableFindings) { finding in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(riskFindingTitle(finding)).font(.headline)
                            Text(riskFindingExplanation(finding))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let evidence = riskEvidence(finding) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("发现位置").font(.caption.weight(.semibold))
                                    Text("\(finding.relativePath) · \(evidence)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .padding(10)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                            }
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(riskTint.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
            .frame(maxHeight: 300)

            if !skill.riskReport.isBlocked {
                Label("这次确认只适用于 \(skill.displayName) 的当前内容版本；内容或风险证据变化后会重新询问。", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack {
                Button(continueInstallAfterRiskConfirmation ? "暂不安装" : "关闭") {
                    showRiskConfirmation = false
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                Spacer()
                if !skill.riskReport.isBlocked && model.needsRiskAcknowledgement(for: skill) {
                    Button(continueInstallAfterRiskConfirmation ? "我已了解，继续安装" : "我已了解") {
                        model.acknowledgeRisk(for: skill)
                        showInstallConfirmationAfterRiskSheet = continueInstallAfterRiskConfirmation
                        showRiskConfirmation = false
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                }
            }
        }
        .padding(24)
        .frame(width: 590)
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .installEverywhere: "安装到全部可用应用？"
        case .uninstallEverywhere: "从所有应用卸载？"
        case .delete: "从「我的 Skills」删除？"
        case nil: "请确认"
        }
    }

    private func confirmationMessage(for choice: Confirmation) -> String {
        switch choice {
        case .installEverywhere: installEverywhereMessage
        case .uninstallEverywhere: "下一步会列出准备移除的位置。只有 SkillBox 管理且内容没有被其他软件改过的副本才能卸载。"
        case .delete: "中央内容会移到 macOS 废纸篓，可以立即撤销；清空废纸篓后将无法恢复。其他应用中未由 SkillBox 管理的文件不会被改动。"
        }
    }

    private var installEverywhereMessage: String {
        guard !availableTargets.isEmpty else {
            return "本机还没有找到可以安装 Skill 的应用。SkillBox 不会代为创建应用文件夹。"
        }
        let availableNames = availableTargets.map(\.displayName).joined(separator: "、")
        guard !unavailableTargets.isEmpty else {
            return "将为 \(availableNames) 准备安装。下一步仍会显示完整改动清单。"
        }
        let skippedNames = unavailableTargets.map(\.displayName).joined(separator: "、")
        return "将为 \(availableNames) 准备安装。未找到或不可写的 \(skippedNames) 会被跳过，也不会创建文件夹。"
    }

    private var installationAvailabilityMessage: String {
        guard !availableTargets.isEmpty else {
            return "本机还没有找到可安装的应用，SkillBox 不会代为创建目录。"
        }
        if skill.riskReport.isBlocked {
            return "安全检查已阻止这份 Skill，可以在下方查看原因。"
        }
        if model.needsRiskAcknowledgement(for: skill) {
            return "已找到 \(availableTargets.count) 个可安装应用。确认下方的内容提示后即可继续。"
        }
        return "已找到 \(availableTargets.count) 个可安装应用。继续后会先让你查看完整清单。"
    }

    private var installButtonHelp: String {
        if availableTargets.isEmpty { return "本机还没有找到可安装 Skill 的应用" }
        if skill.riskReport.isBlocked { return "这份 Skill 已被安全检查阻止" }
        if model.needsRiskAcknowledgement(for: skill) { return "先了解风险提示，再查看安装清单" }
        return "先查看完整安装清单"
    }

    private func riskLevel(_ severity: RiskSeverity) -> String {
        switch severity { case .info: "仅说明"; case .caution: "需要了解"; case .high: "需要确认"; case .blocked: "无法添加" }
    }

    private var riskSummaryIcon: String {
        switch skill.riskReport.highestSeverity {
        case .blocked: "xmark.shield.fill"
        case .high: "exclamationmark.shield.fill"
        case .caution, .info: "info.circle.fill"
        }
    }

    private var riskSummaryTitle: String {
        switch skill.riskReport.highestSeverity {
        case .blocked: "有内容为了安全已被阻止"
        case .high: "有内容需要你确认后再使用"
        case .caution, .info: "这份 Skill 有几项文件内容需要了解"
        }
    }

    private var riskTint: Color {
        switch skill.riskReport.highestSeverity {
        case .blocked: .red
        case .high: .orange
        case .caution, .info: .blue
        }
    }

    private func riskFindingColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .blocked: .red
        case .high: .orange
        case .caution: .blue
        case .info: .secondary
        }
    }

    private func riskFindingTitle(_ finding: RiskFinding) -> String {
        switch finding.category {
        case .executableFile: "这个 Skill 带有可运行的脚本"
        case .deletion where finding.severity == .info: "说明文档里提到了清理命令"
        case .deletion where finding.evidence.contains("$"): "脚本会按变量指定的位置清理文件"
        case .deletion: "脚本里有清理文件的命令"
        case .network where finding.severity == .info: "说明文档里提到了网址或下载命令"
        case .network: "脚本可能访问网络或下载文件"
        case .privilege: "脚本可能请求更高的系统权限"
        case .credentialAccess where finding.severity == .info: finding.title
        case .credentialAccess: "脚本可能读取账号信息或密钥"
        case .dynamicExecution: "脚本可能启动其他程序或命令"
        default: finding.title
        }
    }

    private func riskFindingExplanation(_ finding: RiskFinding) -> String {
        let location = "文件：\(finding.relativePath)"
        if finding.category == .credentialAccess,
           finding.severity == .info,
           finding.title == "GitHub 自动化使用临时仓库令牌"
        {
            return "\(finding.evidence)。\(location)"
        }
        if finding.severity == .info {
            return "这只是说明文字，SkillBox 不会执行。\(location)"
        }
        if finding.severity == .blocked {
            return "为了避免访问 Skill 文件夹之外的内容，SkillBox 已经停止添加。\(location)"
        }
        switch finding.category {
        case .executableFile:
            return "只有你或 AI 应用主动调用它时才会运行。\(location)"
        case .deletion:
            return "只有这个脚本被主动运行时才会清理，建议先确认变量最终指向哪个位置。\(location)"
        default:
            let advice: String = finding.severity == .high ? "建议确认用途后再安装。" : "建议使用前查看这个文件。"
            return "\(advice)\(location)"
        }
    }

    private func riskEvidence(_ finding: RiskFinding) -> String? {
        switch finding.category {
        case .deletion, .privilege, .credentialAccess, .dynamicExecution:
            return finding.evidence.hasPrefix("建议") ? nil : "发现：\(finding.evidence)"
        case .symlink, .pathEscape:
            return "指向：\(finding.evidence)"
        default:
            return nil
        }
    }
}

private struct SkillDetailTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.primary.opacity(0.055) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

private struct SkillUsageGuideCard: View {
    let guide: SkillUsageGuide
    @State private var copiedPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            guideSectionCard(title: SkillDetailLayout.guideTitles[0], icon: "wand.and.stars") {
                Text(guide.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let useWhen = guide.useWhen, !useWhen.isEmpty {
                guideSectionCard(title: SkillDetailLayout.guideTitles[1], icon: "checkmark.circle") {
                    Text(useWhen)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !guide.experienceSteps.isEmpty {
                guideSectionCard(title: SkillDetailLayout.guideTitles[2], icon: "point.3.connected.trianglepath.dotted") {
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(Array(guide.experienceSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 22, height: 22)
                                    .background(.blue.opacity(0.09), in: Circle())
                                Text(step)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let starterPrompt = guide.starterPrompt, !starterPrompt.isEmpty {
                guideSectionCard(title: SkillDetailLayout.guideTitles[3], icon: "quote.bubble") {
                    HStack(alignment: .center, spacing: 12) {
                        Text(starterPrompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(copiedPrompt ? "已复制" : "复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(starterPrompt, forType: .string)
                            copiedPrompt = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                copiedPrompt = false
                            }
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        .accessibilityHint("复制这句话，可以粘贴给 AI 应用")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func guideSectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.blue)
                .frame(width: 18, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.42)))
    }
}

private struct SkillUsageGuideLoadingCard: View {
    var body: some View {
        HStack(spacing: 13) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text("正在补齐这份 Skill 介绍")
                    .font(.callout.weight(.semibold))
                Text("你可以继续查看文件或管理安装，完成后会在这里自动显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.42)))
    }
}

private struct SkillDirectoryRow: View {
    let entry: SkillDirectoryEntry

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 15)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if let fileSize = entry.fileSize, entry.kind != .directory {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.leading, CGFloat(entry.depth) * 18)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isMainMarkdown ? Color.blue : Color.primary)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider().opacity(0.38)
        }
    }

    private var isMainMarkdown: Bool {
        entry.relativePath.caseInsensitiveCompare("SKILL.md") == .orderedSame
    }

    private var icon: String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .markdown: "doc.richtext"
        case .symbolicLink: "link"
        case .file: "doc"
        }
    }

    private var iconColor: Color {
        if isMainMarkdown { return .blue }
        switch entry.kind {
        case .directory: return Color(nsColor: .secondaryLabelColor)
        case .markdown: return Color.indigo
        case .symbolicLink: return Color.orange
        case .file: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

private struct SkillRawSourceView: View {
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    @Binding var isPresented: Bool
    @State private var markdown = ""
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SKILL.md 预览").font(.title2.bold())
                    Text("\(skill.displayName) · 只读").foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            }
            if isLoading {
                ProgressView("正在读取…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReadOnlyTextView(text: markdown)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
            }
        }
        .padding(22)
        .frame(width: 760, height: 600)
        .task(id: skill.id) {
            markdown = await model.skillMarkdown(skill)
            isLoading = false
        }
    }
}

private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

private struct SkillInstallManagerView: View {
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    @Binding var isPresented: Bool
    @State private var proposal: AssignmentProposal?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("管理安装").font(.title2.bold())
                    Text("选择把“\(skill.displayName)”安装到哪些应用。每次点击都会先让你确认。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { isPresented = false }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            }
            .padding(24)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.visibleTargets()) { target in
                        Button {
                            Task { proposal = await model.prepareAssignmentProposal(skill: skill, target: target) }
                        } label: {
                            HStack(spacing: 12) {
                                AgentProductIcon(target: target, size: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(target.displayName).font(.callout.weight(.semibold))
                                    Text(target.path)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Label(statusText(target), systemImage: statusSymbol(target))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(statusColor(target))
                            }
                            .padding(11)
                            .contentShape(Rectangle())
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 620, height: 620)
        .sheet(item: $proposal) { proposal in
            AgentAssignmentSheet(model: model, proposal: proposal)
        }
    }

    private func action(for target: AgentTarget) -> SyncAction? {
        model.syncPlan?.actions.first { $0.skillID == skill.id && $0.targetID == target.id }
    }

    private func isDesired(_ target: AgentTarget) -> Bool {
        model.snapshot.assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true
    }

    private func statusText(_ target: AgentTarget) -> String {
        if action(for: target)?.kind == .blocked || model.hasUnmanagedSameName(skill: skill, target: target) {
            return "已有同名"
        }
        if target.detectionStatus != .available || target.writeStatus != .writable { return "应用不可用" }
        if action(for: target)?.kind == .update { return "可更新" }
        return isDesired(target) ? "已安装" : "安装"
    }

    private func statusSymbol(_ target: AgentTarget) -> String {
        switch statusText(target) {
        case "已有同名": "square.stack.3d.up.fill"
        case "应用不可用": "nosign"
        case "可更新": "arrow.triangle.2.circlepath"
        case "已安装": "checkmark.circle.fill"
        default: "plus.circle.fill"
        }
    }

    private func statusColor(_ target: AgentTarget) -> Color {
        switch statusText(target) {
        case "已有同名": .orange
        case "应用不可用": .secondary
        case "已安装": .green
        default: .blue
        }
    }
}

private enum MatrixSkillFilter: Hashable {
    case all
    case folder(UUID)
    case uncategorized
}

private enum AgentMatrixCoordinateSpace {
    static let name = "agent-installation-matrix"
}

private struct AgentColumnFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct AgentMatrixBoundsPreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct AgentsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let addCustom: () -> Void
    let addSkill: () -> Void
    let editCustom: (AgentTarget) -> Void
    @State private var assignmentProposal: AssignmentProposal?
    @State private var searchText = ""
    @State private var filter: MatrixSkillFilter = .all
    @State private var showApplicationManager = false
    @State private var columnDrag = AgentColumnDragSession()
    @State private var columnFrames: [UUID: CGRect] = [:]
    @State private var matrixBounds = CGRect.zero

    private var liveTargets: [AgentTarget] { model.visibleTargets() }
    private var targets: [AgentTarget] {
        guard columnDrag.isActive else { return liveTargets }
        let byID = Dictionary(uniqueKeysWithValues: liveTargets.map { ($0.id, $0) })
        let ordered = columnDrag.previewOrder.compactMap { byID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + liveTargets.filter { !orderedIDs.contains($0.id) }
    }

    private var filteredSkills: [SkillRecord] {
        let source: [SkillRecord]
        switch filter {
        case .all:
            source = model.snapshot.skills
        case let .folder(id):
            source = model.orderedSkills(in: id)
        case .uncategorized:
            source = model.orderedSkills(in: nil)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.canonicalName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(
                    eyebrow: "统一安装",
                    title: "安装到应用",
                    subtitle: "查看每个 Skill 安装在哪些应用里，点击一个状态即可安装、更新或卸载。"
                )
                Spacer()
                Button("管理应用") { showApplicationManager = true }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            }
            .padding(28)

            if model.snapshot.skills.isEmpty {
                ContentUnavailableView {
                    Label("先添加一个 Skill", systemImage: "square.grid.2x2")
                } description: {
                    Text("添加后，就能在这里选择要安装到哪些应用。")
                } actions: {
                    Button("去添加 Skill", action: addSkill)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
            } else {
                HStack(spacing: 14) {
                    TextField("搜索当前列表", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    AssignmentLegend(symbol: "plus", color: .blue, text: "安装")
                    AssignmentLegend(symbol: "checkmark", color: .green, text: "已安装")
                    AssignmentLegend(symbol: "arrow.triangle.2.circlepath", color: .blue, text: "可更新")
                    AssignmentLegend(symbol: "square.stack.3d.up.fill", color: .orange, text: "已有同名")
                    AssignmentLegend(symbol: "nosign", color: .secondary, text: "应用不可用")
                    Spacer()
                    Text(columnDrag.isActive ? "松手保存 · 拖出表格或按 Esc 取消" : "拖动表头调整常用顺序")
                        .font(.caption2)
                        .foregroundStyle(columnDrag.isActive ? Color.blue : Color.secondary)
                    Button("恢复默认顺序") {
                        Task { await model.restoreDefaultTargetOrder() }
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    .controlSize(.small)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 10)

                ScrollViewReader { scrollProxy in
                    ScrollView([.horizontal, .vertical]) {
                        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                matrixSkillFilter
                                    .frame(width: 220, alignment: .leading)
                                ForEach(targets) { target in
                                    agentColumnHeader(target)
                                        .id(target.id)
                                }
                            }
                            Divider().gridCellColumns(targets.count + 1)
                            ForEach(filteredSkills) { skill in
                                GridRow {
                                    HStack(spacing: 9) {
                                        SkillOrganizerSourceIconView(sourceKind: skill.source.kind)
                                            .frame(width: 20, height: 20)
                                        Text(skill.displayName)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if sourceHasUpdate(skill) {
                                            Text("有新版本")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .frame(width: 220, alignment: .leading)
                                    ForEach(targets) { target in
                                        AssignmentButton(model: model, skill: skill, target: target) {
                                            Task {
                                                assignmentProposal = await model.prepareAssignmentProposal(skill: skill, target: target)
                                            }
                                        }
                                        .frame(width: 102)
                                        .padding(.vertical, 3)
                                        .background(
                                            columnDrag.movingTargetID == target.id
                                                ? Color.blue.opacity(0.055)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                    }
                                }
                            }
                        }
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.92),
                            value: targets.map(\.id)
                        )
                        .padding()
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AgentMatrixBoundsPreferenceKey.self,
                                value: proxy.frame(in: .named(AgentMatrixCoordinateSpace.name))
                            )
                        }
                    }
                    .coordinateSpace(name: AgentMatrixCoordinateSpace.name)
                    .onPreferenceChange(AgentColumnFramesPreferenceKey.self) { columnFrames = $0 }
                    .onPreferenceChange(AgentMatrixBoundsPreferenceKey.self) { matrixBounds = $0 }
                    .onChange(of: columnDrag.ghostCenterX) { _, _ in
                        autoScrollIfNeeded(scrollProxy)
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $assignmentProposal) { proposal in
            AgentAssignmentSheet(model: model, proposal: proposal)
        }
        .sheet(isPresented: $showApplicationManager) {
            ManageApplicationsView(
                model: model,
                addCustom: addCustom,
                editCustom: editCustom
            )
        }
        .onExitCommand { cancelColumnDrag() }
        .onDisappear { cancelColumnDrag() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            cancelColumnDrag()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelColumnDrag()
        }
        .onChange(of: liveTargets.map(\.id)) { _, ids in
            guard let movingTargetID = columnDrag.movingTargetID, !ids.contains(movingTargetID) else { return }
            cancelColumnDrag()
        }
    }

    private func agentColumnHeader(_ target: AgentTarget) -> some View {
        let isDragging = columnDrag.movingTargetID == target.id
        let currentFrame = columnFrames[target.id]
        let ghostOffset = isDragging
            ? columnDrag.ghostCenterX - (currentFrame?.midX ?? columnDrag.ghostCenterX)
            : 0
        let currentIndex = targets.firstIndex(where: { $0.id == target.id }) ?? 0

        return ZStack {
            TargetColumnHeader(target: target, showsDragHandle: true)
                .opacity(isDragging ? 0.18 : 1)
                .background(
                    isDragging ? Color.blue.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(isDragging ? Color.blue.opacity(0.9) : Color.clear, lineWidth: 2)
                )

            if isDragging {
                TargetColumnHeader(target: target, showsDragHandle: true)
                    .padding(.horizontal, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.55)))
                    .shadow(color: .black.opacity(0.18), radius: 13, y: 7)
                    .offset(x: ghostOffset)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(width: 102)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AgentColumnFramesPreferenceKey.self,
                    value: [target.id: proxy.frame(in: .named(AgentMatrixCoordinateSpace.name))]
                )
            }
        }
        .gesture(
            DragGesture(minimumDistance: 7, coordinateSpace: .named(AgentMatrixCoordinateSpace.name))
                .onChanged { updateColumnDrag(target, value: $0) }
                .onEnded { finishColumnDrag(target, value: $0) }
        )
        .contextMenu {
            Button("向左移动") { moveColumn(target, offset: -1) }
                .disabled(currentIndex == 0)
            Button("向右移动") { moveColumn(target, offset: 1) }
                .disabled(currentIndex >= targets.count - 1)
        }
        .accessibilityAction(named: Text("向左移动")) { moveColumn(target, offset: -1) }
        .accessibilityAction(named: Text("向右移动")) { moveColumn(target, offset: 1) }
        .zIndex(isDragging ? 50 : 0)
    }

    private func updateColumnDrag(_ target: AgentTarget, value: DragGesture.Value) {
        if !columnDrag.isActive {
            guard let frame = columnFrames[target.id] else { return }
            columnDrag.begin(
                targetID: target.id,
                orderedTargetIDs: liveTargets.map(\.id),
                frame: frame,
                pointerX: value.startLocation.x
            )
        }
        guard columnDrag.movingTargetID == target.id else { return }
        var next = columnDrag
        let changed = next.update(pointerX: value.location.x, frames: columnFrames)
        if changed, !reduceMotion {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) { columnDrag = next }
        } else {
            columnDrag = next
        }
    }

    private func finishColumnDrag(_ target: AgentTarget, value: DragGesture.Value) {
        updateColumnDrag(target, value: value)
        let commit = matrixBounds.insetBy(dx: -18, dy: -28).contains(value.location)
        let order = columnDrag.finish(commit: commit)
        guard let order else { return }
        Task { await model.saveVisibleTargetOrder(order) }
    }

    private func cancelColumnDrag() {
        guard columnDrag.isActive else { return }
        if reduceMotion { columnDrag.cancel() }
        else { withAnimation(.easeOut(duration: 0.14)) { columnDrag.cancel() } }
    }

    private func moveColumn(_ target: AgentTarget, offset: Int) {
        var ids = liveTargets.map(\.id)
        guard let index = ids.firstIndex(of: target.id) else { return }
        let destination = index + offset
        guard ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        Task { await model.saveVisibleTargetOrder(ids) }
    }

    private func autoScrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard columnDrag.isActive,
              let movingTargetID = columnDrag.movingTargetID,
              let index = targets.firstIndex(where: { $0.id == movingTargetID }),
              !matrixBounds.isEmpty
        else { return }

        let edgeZone: CGFloat = 72
        if columnDrag.ghostCenterX > matrixBounds.maxX - edgeZone,
           targets.indices.contains(index + 1) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                proxy.scrollTo(targets[index + 1].id, anchor: .trailing)
            }
        } else if columnDrag.ghostCenterX < matrixBounds.minX + edgeZone,
                  targets.indices.contains(index - 1) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                proxy.scrollTo(targets[index - 1].id, anchor: .leading)
            }
        }
    }

    private var matrixSkillFilter: some View {
        Menu {
            Button("全部 Skills") { filter = .all }
            Divider()
            ForEach(model.orderedFolders()) { folder in
                Button(folder.name) { filter = .folder(folder.id) }
            }
            Button("未分类") { filter = .uncategorized }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                Text(filterName)
                    .lineLimit(1)
                Spacer()
                Text("\(filteredSkills.count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var filterName: String {
        switch filter {
        case .all: "全部 Skills"
        case let .folder(id): model.orderedFolders().first { $0.id == id }?.name ?? "全部 Skills"
        case .uncategorized: "未分类"
        }
    }

    private func sourceHasUpdate(_ skill: SkillRecord) -> Bool {
        model.snapshot.sourceStates.contains {
            $0.skillID == skill.id && ($0.status == .updateAvailable || $0.status == .releasePackageAvailable)
        } || model.snapshot.localSourceStates.contains {
            $0.skillID == skill.id && $0.status == .updateAvailable
        }
    }
}

private struct AssignmentLegend: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct TargetColumnHeader: View {
    let target: AgentTarget
    var showsDragHandle = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 5) {
                AgentProductIcon(target: target, size: 28)
                Text(target.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(target.detectionStatus == .available ? "已找到" : "未找到")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(target.detectionStatus == .available ? Color.green : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(90))
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 65)
        .contentShape(Rectangle())
        .help("\(target.displayName) · \(target.path) · 按住拖动可调整顺序")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.displayName)，\(target.detectionStatus == .available ? "已找到" : "未找到")，可调整顺序")
    }
}

private struct ManageApplicationsView: View {
    @ObservedObject var model: AppModel
    let addCustom: () -> Void
    let editCustom: (AgentTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: AgentTarget?

    private var hidden: [AgentTarget] { model.hiddenBuiltinTargets() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("管理应用").font(.title2.bold())
                    Text("决定哪些应用出现在安装表中。移出列表不会删除电脑上的应用、文件夹或 Skill 文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    applicationSection(title: "安装表中的应用", count: model.visibleTargets().count) {
                        ForEach(model.visibleTargets()) { target in
                            applicationRow(target) {
                                if target.isCustom { editCustom(target) }
                            } trailing: {
                                Button(target.isCustom ? "删除" : "移出") { pendingRemoval = target }
                                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .destructiveText))
                            }
                        }
                    }

                    applicationSection(title: "已从列表移除", count: hidden.count) {
                        if hidden.isEmpty {
                            Text("没有被移出的预设应用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(hidden) { target in
                                applicationRow(target) {} trailing: {
                                    Button("加回来") {
                                        Task { _ = await model.setTargetVisibility(target, isVisible: true) }
                                    }
                                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                                }
                            }
                        }
                        HStack {
                            Text("预设应用随时可以恢复，自定义应用不会受影响。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复全部预设应用") { Task { await model.restoreAllDefaultTargets() } }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                                .disabled(hidden.isEmpty)
                        }
                        .padding(.top, 4)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("列表里没有我的应用").font(.headline)
                            Text("填写产品名称，再选择它已经存在的全局 Skills 文件夹。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("添加自定义应用") { addCustom() }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                    }
                    .padding(16)
                    .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 760, height: 680)
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            if let target = pendingRemoval {
                if hasManagedCopies(target) {
                    Button("保留文件并停止管理", role: .destructive) {
                        Task {
                            if target.isCustom {
                                await model.removeCustomTarget(target, preservingManagedCopies: true)
                            } else {
                                _ = await model.setTargetVisibility(
                                    target,
                                    isVisible: false,
                                    preservingManagedCopies: true
                                )
                            }
                        }
                        pendingRemoval = nil
                    }
                } else {
                    Button(target.isCustom ? "删除自定义应用" : "从列表移出", role: .destructive) {
                        Task {
                            if target.isCustom { await model.removeCustomTarget(target) }
                            else { _ = await model.setTargetVisibility(target, isVisible: false) }
                        }
                        pendingRemoval = nil
                    }
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(removalMessage)
        }
    }

    @ViewBuilder
    private func applicationSection<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(count) 个").font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func applicationRow<Trailing: View>(
        _ target: AgentTarget,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            AgentProductIcon(target: target, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Button(action: action) {
                    Text(target.displayName).font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(!target.isCustom)
                Text(target.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(target.detectionStatus == .available ? "已找到" : "未找到")
                .font(.caption)
                .foregroundStyle(target.detectionStatus == .available ? Color.green : Color.secondary)
            trailing()
        }
        .padding(11)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }

    private func hasManagedCopies(_ target: AgentTarget) -> Bool {
        model.snapshot.installations.contains { $0.targetID == target.id }
    }

    private var removalTitle: String {
        guard let target = pendingRemoval else { return "移出这个应用？" }
        return target.isCustom ? "删除“\(target.displayName)”？" : "从安装表移出“\(target.displayName)”？"
    }

    private var removalMessage: String {
        guard let target = pendingRemoval else { return "" }
        if hasManagedCopies(target) {
            return "这里仍有 SkillBox 安装的副本。保留文件并停止管理后，现有文件不会删除，SkillBox 也不会再更新或卸载它们。"
        }
        return "只会改变 SkillBox 的应用列表，不会删除电脑上的应用、文件夹或 Skill 文件。"
    }
}

private struct AssignmentButton: View {
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    let target: AgentTarget
    let activate: () -> Void
    @State private var isHovered = false

    private var desired: Bool {
        model.snapshot.assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true
    }

    private var action: SyncAction? {
        model.syncPlan?.actions.first { $0.skillID == skill.id && $0.targetID == target.id }
    }

    private var available: Bool {
        target.detectionStatus == .available && target.writeStatus == .writable
    }

    private var hasUnmanagedSameName: Bool {
        available && model.hasUnmanagedSameName(skill: skill, target: target)
    }

    var body: some View {
        Button(action: activate) {
            Image(systemName: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(isHovered ? 0.18 : 0.10), in: Circle())
                .overlay(Circle().stroke(color.opacity(isHovered ? 0.34 : 0), lineWidth: 1))
                .scaleEffect(isHovered ? 1.05 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .accessibilityLabel("\(skill.displayName)，\(target.displayName)，\(help)")
    }

    private var symbol: String {
        if action?.kind == .blocked || hasUnmanagedSameName {
            return "square.stack.3d.up.fill"
        }
        if !available && !desired { return "nosign" }
        if action?.kind == .update { return "arrow.triangle.2.circlepath" }
        if action?.kind == .create { return "plus" }
        return desired ? "checkmark" : "plus"
    }

    private var color: Color {
        if action?.kind == .blocked { return .orange }
        if hasUnmanagedSameName { return .orange }
        if !available { return .secondary }
        if action?.kind == .update { return .blue }
        return desired ? .green : .blue
    }

    private var help: String {
        if action?.kind == .blocked || hasUnmanagedSameName {
            return action?.summary ?? "这里已有一份不由 SkillBox 管理的同名 Skill，点击查看差异"
        }
        if !available && !desired {
            return "本机没有找到可用的安装位置"
        }
        if action?.kind == .update { return "SkillBox 中已有新版本，点击更新" }
        return desired ? "已安装，点击卸载" : "点击安装到 \(target.displayName)"
    }
}

private struct AgentAssignmentSheet: View {
    @ObservedObject var model: AppModel
    let proposal: AssignmentProposal
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false
    @State private var confirmationMessage: String?

    private var action: SyncAction? { proposal.action }
    private var isConflict: Bool { action?.blockReason == .unmanagedConflict }
    private var isActionable: Bool { action?.kind != .blocked || isConflict }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: headerIcon)
                    .font(.title2)
                    .foregroundStyle(headerColor)
                    .frame(width: 44, height: 44)
                    .background(headerColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title2.bold())
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if isConflict {
                conflictComparison
            } else if action?.kind == .blocked {
                blockedExplanation
            } else {
                destinationSummary
            }

            Divider()
            HStack(spacing: 10) {
                Text(isConfirming ? "正在处理这一项，请稍候…" : (confirmationMessage ?? footerText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isActionable ? "取消" : "知道了") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isConfirming)
                if isActionable {
                    Button(isConfirming ? (proposal.desired ? "正在安装…" : "正在卸载…") : confirmTitle) {
                        isConfirming = true
                        confirmationMessage = nil
                        Task {
                            let succeeded = await model.confirmAssignmentProposal(proposal)
                            isConfirming = false
                            if succeeded { dismiss() }
                            else {
                                confirmationMessage = model.noticeMessage ?? model.errorMessage ?? "操作未完成，请稍后重试。"
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(confirmTint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConfirming || model.isBusy)
                }
            }
        }
        .padding(24)
        .frame(width: 570)
        .interactiveDismissDisabled(isConfirming)
    }

    private var destinationSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(proposal.target.displayName, systemImage: "app.dashed")
                .font(.headline)
            Text(action?.destinationPath ?? proposal.target.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(destinationMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }

    private var conflictComparison: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: proposal.hasSameExistingContent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(proposal.hasSameExistingContent ? Color.green : Color.orange)
                Text(proposal.hasSameExistingContent ? "两份内容完全相同" : "两份内容不同")
                    .font(.headline)
            }
            Text(proposal.hasSameExistingContent
                 ? "应用里已经是同一份 Skill。确认后，SkillBox 只记住由它继续管理，不会重复复制。"
                 : "应用里已有同名 Skill。SkillBox 不会悄悄覆盖，只有你在这里确认后才会替换。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if proposal.hasDifferentExistingContent {
                HStack(spacing: 10) {
                    versionCard(title: "我的 Skills 版本", fingerprint: action?.expectedSourceFingerprint, tint: .blue)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    versionCard(title: "\(proposal.target.displayName) 现有版本", fingerprint: action?.expectedDestinationFingerprint, tint: .orange)
                }
                changeSummary
            }
        }
        .padding(15)
        .background((proposal.hasSameExistingContent ? Color.green : Color.orange).opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((proposal.hasSameExistingContent ? Color.green : Color.orange).opacity(0.18)))
    }

    private var blockedExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action?.summary ?? "这项目前无法处理。")
                .font(.callout)
            Text("现有文件不会被更改。你可以先在 Finder 中查看安装位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path = action?.destinationPath {
                Button("在 Finder 中查看") {
                    model.reveal(URL(fileURLWithPath: path))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func versionCard(title: String, fingerprint: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            Text("内容编号 \(String((fingerprint ?? "未知").prefix(10)))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var changeSummary: some View {
        if !proposal.changes.isEmpty {
            let added = proposal.changes.filter { $0.kind == .added }.count
            let modified = proposal.changes.filter { $0.kind == .modified }.count
            let removed = proposal.changes.filter { $0.kind == .removed }.count
            VStack(alignment: .leading, spacing: 7) {
                Text("替换后的文件变化：新增 \(added) · 修改 \(modified) · 移除 \(removed)")
                    .font(.caption.weight(.semibold))
                ForEach(Array(proposal.changes.prefix(5).enumerated()), id: \.offset) { _, change in
                    HStack(spacing: 7) {
                        Text(changeLabel(change.kind))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(changeColor(change.kind))
                            .frame(width: 30, alignment: .leading)
                        Text(change.path)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                if proposal.changes.count > 5 {
                    Text("还有 \(proposal.changes.count - 5) 项变化")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        if proposal.hasSameExistingContent { return "已找到相同的 Skill" }
        if proposal.hasDifferentExistingContent { return "\(proposal.target.displayName) 已有同名 Skill" }
        return switch action?.kind {
        case .remove: "从 \(proposal.target.displayName) 卸载？"
        case .update: "更新 \(proposal.target.displayName) 中的 Skill？"
        case .create: "安装到 \(proposal.target.displayName)？"
        case .takeover: "由 SkillBox 继续管理？"
        case .blocked: "暂时无法完成"
        case .noChange, nil: proposal.desired ? "已经安装好了" : "确认这项调整？"
        }
    }

    private var subtitle: String {
        "\(proposal.skill.displayName) · \(proposal.target.displayName)"
    }

    private var destinationMessage: String {
        return switch action?.kind {
        case .remove: "只会移除由 SkillBox 管理且没有被外部修改的副本。"
        case .update: "会用「我的 Skills」中的最新内容替换这份可管理副本。"
        case .create: "将复制一份完整 Skill 到这个应用的安装位置。"
        default: "确认后只会处理这一个应用位置。"
        }
    }

    private var confirmTitle: String {
        if proposal.hasSameExistingContent { return "由 SkillBox 管理" }
        if proposal.hasDifferentExistingContent { return "用我的版本替换" }
        return switch action?.kind {
        case .remove: "确认卸载"
        case .update: "确认更新"
        case .create: "确认安装"
        case .takeover: "开始管理"
        default: "确认"
        }
    }

    private var confirmTint: Color {
        if action?.kind == .remove { return .red }
        if proposal.hasDifferentExistingContent { return .orange }
        return .accentColor
    }

    private var headerIcon: String {
        if isConflict { return proposal.hasSameExistingContent ? "checkmark.circle.fill" : "square.stack.3d.up.fill" }
        return switch action?.kind {
        case .remove: "trash"
        case .blocked: "exclamationmark.triangle.fill"
        default: "square.and.arrow.down.fill"
        }
    }

    private var headerColor: Color {
        if proposal.hasSameExistingContent { return .green }
        if isConflict || action?.kind == .blocked { return .orange }
        if action?.kind == .remove { return .red }
        return .blue
    }

    private var footerText: String {
        isActionable
            ? "确认后只处理这一项，写入前会再次检查并保留恢复记录。"
            : "SkillBox 不会在你未确认时更改现有文件。"
    }

    private func changeLabel(_ kind: SkillFileChangeKind) -> String {
        switch kind { case .added: "新增"; case .modified: "修改"; case .removed: "移除" }
    }

    private func changeColor(_ kind: SkillFileChangeKind) -> Color {
        switch kind { case .added: .green; case .modified: .blue; case .removed: .red }
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    var embeddedInSettings = false
    private var visibleTransactions: [SyncTransaction] {
        model.snapshot.transactions.filter { $0.restorationContext == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if embeddedInSettings {
                    SettingsDetailHeader(page: .history)
                } else {
                    PageHeader(
                        eyebrow: "可以反悔",
                        title: "操作记录与恢复",
                        subtitle: "安装、更新和卸载都会留下记录，需要时可以恢复到操作前。"
                    )
                }
                if visibleTransactions.isEmpty {
                    ContentUnavailableView("还没有操作记录", systemImage: "clock.arrow.circlepath", description: Text("第一次安装、更新或卸载完成后会出现在这里"))
                } else {
                    ForEach(visibleTransactions) { transaction in
                        HistoryTransactionCard(model: model, transaction: transaction)
                    }
                }
            }
            .frame(
                maxWidth: embeddedInSettings ? SettingsLayout.contentMaxWidth : .infinity,
                alignment: .leading
            )
            .padding(.horizontal, embeddedInSettings ? 34 : 28)
            .padding(.top, embeddedInSettings ? 34 : 28)
            .padding(.bottom, embeddedInSettings ? 42 : 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(isPresented: Binding(
            get: { model.pendingUndoTransaction != nil },
            set: { isPresented in
                if !isPresented, model.pendingUndoTransaction != nil {
                    model.cancelUndoPreview()
                }
            }
        )) {
            if let transaction = model.pendingUndoTransaction {
                UndoPreviewView(model: model, transaction: transaction)
            }
        }
    }
}

private struct HistoryTransactionCard: View {
    @ObservedObject var model: AppModel
    let transaction: SyncTransaction
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text("\(statusText) · \(transaction.createdAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(showDetails ? "收起详情" : "查看详情") { showDetails.toggle() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                if transaction.canRestore() {
                    Button("恢复到操作前") { _ = model.prepareUndoPreview(transaction) }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                } else if transaction.status == .succeeded && transaction.libraryDeletion == nil {
                    Text("回退备份已到期或被替代")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showDetails {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    if let libraryUpdate = transaction.libraryUpdate {
                        Label("更新了“\(libraryUpdate.previousRecord.displayName)”在我的 Skills 中保存的原件", systemImage: "shippingbox")
                    }
                    ForEach(Array(transaction.actions.enumerated()), id: \.offset) { _, action in
                        Label("\(actionLabel(action.kind))：\(targetName(for: action))", systemImage: action.kind == .blocked ? "exclamationmark.triangle" : "arrow.right.circle")
                    }
                    if !transaction.errors.isEmpty {
                        ForEach(transaction.errors, id: \.self) { Text($0).foregroundStyle(.orange) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
    }

    private var title: String {
        if let update = transaction.libraryUpdate {
            return transaction.backups.isEmpty ? "更新了 \(update.previousRecord.displayName)" : "更新并重新安装了 \(update.previousRecord.displayName)"
        }
        let skillNames = Set(transaction.actions.compactMap { action in
            model.snapshot.skills.first { $0.id == action.skillID }?.displayName
        })
        if skillNames.count == 1, let name = skillNames.first { return "处理了 \(name) 的安装" }
        return "处理了 \(transaction.backups.count) 个安装位置"
    }

    private var statusText: String {
        switch transaction.status { case .running: "正在处理"; case .succeeded: "已完成"; case .failed: "没有完成"; case .rolledBack: "已恢复到操作前"; case .undone: "已恢复"; case .undoBlocked: "发现新改动，暂未恢复" }
    }

    private var statusIcon: String {
        switch transaction.status { case .succeeded: "checkmark.circle.fill"; case .undone, .rolledBack: "arrow.uturn.backward.circle.fill"; default: "exclamationmark.circle.fill" }
    }

    private var statusColor: Color { transaction.status == .succeeded ? .green : .orange }

    private func targetName(for action: SyncAction) -> String {
        model.snapshot.targets.first { $0.id == action.targetID }?.displayName ?? "已移除的应用"
    }

    private func actionLabel(_ kind: SyncActionKind) -> String {
        switch kind { case .create: "安装"; case .update: "更新"; case .remove: "卸载"; case .takeover: "纳入管理"; case .noChange: "无需改动"; case .blocked: "未处理" }
    }
}

struct UndoPreviewContent {
    let transaction: SyncTransaction

    var installationActions: [SyncAction] {
        transaction.actions.filter { [.create, .update, .remove, .takeover].contains($0.kind) }
    }

    var savedVersion: SkillRecord? { transaction.libraryUpdate?.previousRecord }
    var canConfirm: Bool { transaction.canRestore() && (savedVersion != nil || !installationActions.isEmpty) }
    var summary: String {
        if savedVersion != nil {
            return installationActions.isEmpty ? "将恢复保存版本" : "将恢复保存版本和 \(installationActions.count) 个安装位置"
        }
        return "将恢复 \(installationActions.count) 个安装位置"
    }
    var confirmation: String {
        if savedVersion != nil { return installationActions.isEmpty ? "确认恢复保存版本" : "确认恢复" }
        return "确认恢复 \(installationActions.count) 个安装位置"
    }
}

private struct UndoPreviewView: View {
    @ObservedObject var model: AppModel
    let transaction: SyncTransaction

    private var content: UndoPreviewContent { .init(transaction: transaction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("恢复到这次操作之前？")
                        .font(.title2.bold())
                    Text("先查看即将恢复的位置。现在还没有修改任何文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(content.summary)
                    .font(.headline)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let record = content.savedVersion {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(.blue)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("我的 Skills · \(record.displayName)")
                                        .font(.callout.weight(.medium))
                                    Text("恢复这次更新前保存的版本")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(content.installationActions) { action in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: undoIcon(for: action.kind))
                                    .foregroundStyle(.blue)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(targetName(for: action)) · \(undoLabel(for: action.kind))")
                                        .font(.callout.weight(.medium))
                                    Text(action.destinationPath)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 270)
            }

            Label(centralContentMessage, systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("如果某个位置在这次操作后被其他软件改过，SkillBox 会保留新改动，并停下来提醒你。", systemImage: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("取消") { model.cancelUndoPreview() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(content.confirmation) {
                    Task { await model.confirmPendingUndo() }
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || !content.canConfirm)
            }
        }
        .padding(24)
        .frame(width: 660)
    }

    private var centralContentMessage: String {
        if transaction.libraryUpdate != nil {
            return "「我的 Skills」中的原件也会恢复到更新前版本。"
        }
        if transaction.libraryDeletion != nil {
            return "「我的 Skills」中的原件会一起恢复。"
        }
        if transaction.libraryRestoration != nil {
            return "「我的 Skills」中这次恢复的原件会回到操作前状态。"
        }
        return "「我的 Skills」中的主 Skill 不会改变。"
    }

    private func targetName(for action: SyncAction) -> String {
        model.snapshot.targets.first { $0.id == action.targetID }?.displayName ?? "已移除的应用"
    }

    private func undoLabel(for kind: SyncActionKind) -> String {
        switch kind {
        case .create: "移除这次新安装的副本"
        case .update: "恢复为更新前的内容"
        case .remove: "恢复这次卸载的副本"
        case .takeover: "恢复为操作前的管理状态"
        case .noChange: "无需恢复"
        case .blocked: "未曾修改"
        }
    }

    private func undoIcon(for kind: SyncActionKind) -> String {
        switch kind {
        case .create: "minus.circle"
        case .update: "clock.arrow.circlepath"
        case .remove: "arrow.uturn.backward.circle"
        case .takeover: "person.crop.circle.badge.minus"
        case .noChange: "equal.circle"
        case .blocked: "exclamationmark.triangle"
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case ai = "AI 服务"
    case github = "GitHub"
    case storage = "存储与记录"
    case history = "操作记录与恢复"
    case privacy = "隐私与安全"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ai: SettingsLayout.aiServiceSymbol
        case .github: "chevron.left.forwardslash.chevron.right"
        case .storage: "externaldrive.fill"
        case .history: "clock.arrow.circlepath"
        case .privacy: "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ai: .purple
        case .github: .primary
        case .storage: .blue
        case .history: .orange
        case .privacy: .green
        }
    }

    var detail: String {
        switch self {
        case .ai: "决定哪些功能使用 AI，并分别管理每家服务的连接信息。"
        case .github: "连接私人仓库，并管理 SkillBox 可以读取的仓库范围。"
        case .storage: "查看 SkillBox 在这台 Mac 上保存了什么，并清理不再需要的寻找记录。"
        case .history: "安装、更新和卸载都会留下记录，需要时可以恢复到操作前。"
        case .privacy: "了解 SkillBox 什么时候读取文件、访问网络，以及如何保护你的内容。"
        }
    }
}

private struct SettingsPageIcon: View {
    let page: SettingsPage
    let size: CGFloat
    var isSelected = false

    var body: some View {
        Group {
            if page == .github, SettingsLayout.githubUsesOfficialMark {
                GitHubSourceMark()
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: page.icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(isSelected ? Color.white : page.tint)
        .frame(width: size, height: size)
        .background(
            isSelected ? Color.accentColor : page.tint.opacity(0.1),
            in: RoundedRectangle(cornerRadius: size * 0.28)
        )
        .accessibilityHidden(true)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSettingsPage: SettingsPage
    @State private var selectedAIProviderID = "agnes"
    @State private var aiKeyDraft = ""
    @State private var aiStatusProviderID: String?
    @State private var confirmDeleteAIKey = false
    @State private var confirmDisconnect = false
    @State private var confirmClearGitHub = false
    @State private var confirmOpenGitHubRevoke = false
    @State private var showAllRepositories = false
    @State private var confirmClearDiscoverySessions = false

    private var selectedAIConfiguration: AIProviderConfiguration {
        model.aiSettings.configuration(id: selectedAIProviderID)
            ?? model.aiSettings.configurations.first
            ?? AISettings.defaults.configurations[0]
    }

    private var agnesConfiguration: AIProviderConfiguration {
        model.aiSettings.configuration(id: "agnes")
            ?? AISettings.defaults.configurations[0]
    }

    private var discoveryConfiguration: AIProviderConfiguration? {
        model.aiSettings.selectedConfiguration
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsNavigationPane(
                model: model,
                selection: $selectedSettingsPage
            )
            .frame(width: SettingsLayout.navigationWidth)

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            selectedAIProviderID = model.aiSettings.selectedProviderID
            await refreshGitHubIfNeeded()
        }
        .onChange(of: selectedSettingsPage) { _, page in
            guard page == .github else { return }
            Task { await refreshGitHubIfNeeded() }
        }
        .confirmationDialog("删除这个 API Key？", isPresented: $confirmDeleteAIKey) {
            Button("删除密钥", role: .destructive) {
                aiStatusProviderID = selectedAIProviderID
                Task { await model.deleteAIKey(providerID: selectedAIProviderID) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除这台 Mac 钥匙串里的密钥，不会修改你在服务商账号中的内容。")
        }
        .confirmationDialog("断开 GitHub？", isPresented: $confirmDisconnect) {
            Button("断开连接", role: .destructive) { Task { await model.disconnectGitHub() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这台 Mac 上的登录信息会被删除。私人仓库会在下次检查时提示重新连接；公开仓库、本地 Skills 和已安装副本都不受影响。")
        }
        .confirmationDialog("清除所有 GitHub 信息？", isPresented: $confirmClearGitHub) {
            Button("清除 GitHub 信息", role: .destructive) { Task { await model.clearGitHubInformation() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("SkillBox 会删除登录信息和仓库跟踪记录。已经保存在“我的 Skills”中的内容不会删除。")
        }
        .confirmationDialog("前往 GitHub 撤销授权？", isPresented: $confirmOpenGitHubRevoke) {
            Button("打开 GitHub") { model.openGitHubAuthorizationSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("GitHub 端的访问许可需要在 GitHub 设置中撤销。完成后也可以回到这里断开本机连接。")
        }
        .confirmationDialog("清空所有寻找记录？", isPresented: $confirmClearDiscoverySessions) {
            Button("清空记录", role: .destructive) { Task { await model.deleteAllDiscoverySessions() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机保存的需求、补充条件和候选列表。已加入“我的 Skills”的内容不会删除。")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSettingsPage {
        case .ai:
            SettingsDetailPage(page: .ai) { aiContent }
        case .github:
            SettingsDetailPage(page: .github) { githubContent }
        case .storage:
            SettingsDetailPage(page: .storage) { storageContent }
        case .history:
            HistoryView(model: model, embeddedInSettings: true)
        case .privacy:
            SettingsDetailPage(page: .privacy) { privacyContent }
        }
    }

    @ViewBuilder
    private var aiContent: some View {
        SettingsSectionHeading(
            title: "使用位置",
            trailing: "先决定用在哪里，再管理服务"
        )

        HStack(alignment: .top, spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        AIServiceSymbol(kind: .agnes, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Skill 介绍")
                                .font(.callout.weight(.semibold))
                            Text("固定使用 Agnes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        SettingsBadge(
                            title: model.configuredAIProviderIDs.contains("agnes") ? "已连接" : "未连接",
                            color: model.configuredAIProviderIDs.contains("agnes") ? .green : .secondary
                        )
                    }

                    Text("只有你在某份 Skill 中点击“获取 Skill 介绍”时，才会把经过隐藏处理的说明文字发送给 Agnes。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Text(agnesConfiguration.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("管理 Agnes") {
                            selectedAIProviderID = "agnes"
                            aiKeyDraft = ""
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 34, height: 34)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("发现 Skills")
                                .font(.callout.weight(.semibold))
                            Text(discoveryConfiguration?.displayName ?? "还未选择服务")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { model.aiSettings.isEnabled },
                            set: { model.setAIEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("决定“发现 Skills”是否使用 AI 帮你整理需求和比较候选")
                    }

                    Text("开启后，AI 会帮你整理搜索需求和比较候选；关闭后仍然可以搜索。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack {
                        Text("使用服务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("发现 Skills 使用的 AI 服务", selection: Binding(
                            get: { model.aiSettings.selectedProviderID },
                            set: { model.selectAIProvider($0) }
                        )) {
                            ForEach(model.aiSettings.configurations) { configuration in
                                Text(configuration.displayName)
                                    .tag(configuration.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }

        SettingsSectionHeading(
            title: "AI 服务",
            trailing: "\(model.configuredAIProviderIDs.count) 个已连接"
        )

        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(model.aiSettings.configurations.enumerated()), id: \.element.id) { index, configuration in
                    AIServiceSelectionRow(
                        configuration: configuration,
                        isSelected: selectedAIProviderID == configuration.id,
                        isConnected: model.configuredAIProviderIDs.contains(configuration.id)
                    ) {
                        selectedAIProviderID = configuration.id
                        aiKeyDraft = ""
                    }

                    if index < model.aiSettings.configurations.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
        }

        aiManagementCard
    }

    private var aiManagementCard: some View {
        let configuration = selectedAIConfiguration
        let isConnected = model.configuredAIProviderIDs.contains(configuration.id)

        return SettingsCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 11) {
                    AIServiceSymbol(kind: configuration.kind, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("管理 \(configuration.displayName)")
                            .font(.headline)
                        Text(isConnected ? "连接已经过测试" : "填写自己的 API Key 后测试连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    SettingsBadge(
                        title: isConnected ? "已连接" : "未连接",
                        color: isConnected ? .green : .secondary
                    )
                }

                Divider()

                if configuration.kind == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("接口地址")
                            .font(.caption.weight(.semibold))
                        TextField("https://example.com/v1", text: Binding(
                            get: { configuration.baseURL },
                            set: { model.updateAIConfiguration(providerID: configuration.id, baseURL: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text("支持 OpenAI 兼容接口；公网地址必须使用 HTTPS。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型名称")
                            .font(.caption.weight(.semibold))
                        TextField("例如 model-name", text: Binding(
                            get: { configuration.model },
                            set: { model.updateAIConfiguration(providerID: configuration.id, model: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("模型")
                                .font(.callout.weight(.semibold))
                            Text(configuration.kind == .agnes
                                 ? "Agnes 用于生成 Skill 介绍"
                                 : "SkillBox 已预设官方接口地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("模型", selection: Binding(
                            get: { configuration.model },
                            set: {
                                model.updateAIConfiguration(
                                    providerID: configuration.id,
                                    model: $0
                                )
                            }
                        )) {
                            ForEach(configuration.recommendedModels, id: \.self) { modelName in
                                Text(modelName).tag(modelName)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("API Key")
                        .font(.caption.weight(.semibold))

                    HStack(spacing: 10) {
                        SecureField(
                            isConnected ? "已经保存，留空可重新测试" : "粘贴 API Key",
                            text: $aiKeyDraft
                        )
                        .textFieldStyle(.roundedBorder)

                        Button {
                            let providerID = configuration.id
                            let key = aiKeyDraft
                            aiStatusProviderID = providerID
                            Task {
                                await model.saveAndTestAIKey(providerID: providerID, apiKey: key)
                                if model.configuredAIProviderIDs.contains(providerID) {
                                    aiKeyDraft = ""
                                }
                            }
                        } label: {
                            if model.isTestingAIConnection && aiStatusProviderID == configuration.id {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("正在测试")
                                }
                            } else {
                                Text(isConnected ? "测试连接" : "保存并测试")
                            }
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        .disabled(
                            model.isTestingAIConnection ||
                                (!isConnected && aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        )
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if aiStatusProviderID == configuration.id,
                       !model.aiConnectionStatus.isEmpty
                    {
                        Label(
                            model.aiConnectionStatus,
                            systemImage: model.aiConnectionStatus.contains("成功")
                                ? "checkmark.circle.fill"
                                : "info.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            model.aiConnectionStatus.contains("成功")
                                ? Color.green
                                : Color.orange
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(
                            "API Key 只保存在这台 Mac 的钥匙串中",
                            systemImage: "key.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if configuration.apiKeyPage != nil {
                        Button("获取 API Key") {
                            model.openAIKeyPage(providerID: configuration.id)
                        }
                        .buttonStyle(.link)
                    }

                    if isConnected {
                        Button("删除密钥", role: .destructive) {
                            confirmDeleteAIKey = true
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .destructiveText))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var githubContent: some View {
        if model.isGitHubConnected {
            SettingsStatusBanner(
                icon: "checkmark",
                title: "GitHub 已连接",
                detail: model.githubAuthorizedRepositories.isEmpty
                    ? "身份连接已经保存。选择仓库后，SkillBox 才能读取对应的私人仓库。"
                    : "SkillBox 可以读取你选中的仓库，但不能修改仓库内容。",
                color: .green
            ) {
                Button("管理可访问仓库") {
                    model.manageGitHubRepositories()
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            }

            SettingsSectionHeading(
                title: "可访问仓库",
                trailing: "\(model.githubAuthorizedRepositories.count) 个"
            )

            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    if model.githubAuthorizedRepositories.isEmpty {
                        HStack(spacing: 12) {
                            if model.isWaitingForGitHubRepositorySelection {
                                ProgressView().controlSize(.small)
                                    .frame(width: 34, height: 34)
                            } else {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundStyle(.blue)
                                    .frame(width: 34, height: 34)
                                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.isWaitingForGitHubRepositorySelection ? "正在等待你选择仓库" : "还没有选择仓库")
                                    .font(.callout.weight(.semibold))
                                Text("前往 GitHub 选择 SkillBox 可以读取的仓库。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.isWaitingForGitHubRepositorySelection ? "重新打开 GitHub" : "选择仓库") {
                                model.manageGitHubRepositories()
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        }
                        .padding(16)
                    } else {
                        ForEach(
                            Array(model.githubAuthorizedRepositories.prefix(
                                showAllRepositories ? model.githubAuthorizedRepositories.count : 6
                            ).enumerated()),
                            id: \.element.id
                        ) { index, repository in
                            HStack(spacing: 11) {
                                Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(repository.isPrivate ? .orange : .blue)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        (repository.isPrivate ? Color.orange : Color.blue).opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(repository.fullName)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(repository.isPrivate ? "私人仓库" : "公开仓库")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("在 GitHub 查看") {
                                    openGitHubRepository(repository.fullName)
                                }
                                .buttonStyle(.link)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 58)

                            if index < min(
                                model.githubAuthorizedRepositories.count,
                                showAllRepositories ? model.githubAuthorizedRepositories.count : 6
                            ) - 1 {
                                Divider().padding(.leading, 62)
                            }
                        }

                        if model.githubAuthorizedRepositories.count > 6 {
                            Divider()
                            Button(showAllRepositories ? "收起仓库列表" : "查看全部仓库") {
                                showAllRepositories.toggle()
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }

            SettingsSectionHeading(title: "连接管理")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsActionRow(
                        icon: "person.crop.circle.badge.minus",
                        title: "断开这台 Mac 的 GitHub 连接",
                        detail: "只删除本机登录信息，公开仓库和已经保存的 Skills 不受影响。",
                        buttonTitle: "断开连接"
                    ) {
                        confirmDisconnect = true
                    }

                    Divider().padding(.leading, 46)

                    SettingsActionRow(
                        icon: "rectangle.portrait.and.arrow.forward",
                        title: "在 GitHub 撤销访问许可",
                        detail: "打开 GitHub 官方设置，由你亲自撤销 SkillBox 的权限。",
                        buttonTitle: "打开 GitHub"
                    ) {
                        confirmOpenGitHubRevoke = true
                    }

                    Divider().padding(.leading, 46)

                    SettingsActionRow(
                        icon: "trash",
                        title: "清除 GitHub 信息",
                        detail: "删除本机登录和仓库跟踪记录，已经保存的 Skill 内容会保留。",
                        buttonTitle: "清除信息",
                        isDestructive: true
                    ) {
                        confirmClearGitHub = true
                    }
                }
            }
        } else {
            SettingsStatusBanner(
                icon: "person.crop.circle.badge.plus",
                title: "连接 GitHub",
                detail: "只有读取私人仓库时才需要连接；公开仓库无需登录。",
                color: .blue
            ) {
                EmptyView()
            }

            SettingsSectionHeading(title: "连接步骤")

            SettingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        GitHubConnectionStep(number: 1, title: "确认身份", detail: "打开 GitHub")
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        GitHubConnectionStep(number: 2, title: "选择仓库", detail: "只选需要的")
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        GitHubConnectionStep(number: 3, title: "回到 SkillBox", detail: "自动完成连接")
                    }

                    if model.isGitHubConfigured {
                        Button("开始连接") {
                            Task { await model.connectPrivateGitHub() }
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        .disabled(model.isBusy)
                    } else {
                        Label(
                            "当前版本尚未配置私人仓库登录，公开仓库仍然可以直接使用。",
                            systemImage: "info.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }

        if let authorization = model.githubAuthorization {
            GitHubDeviceAuthorizationCard(model: model, authorization: authorization)
        }

        if !model.githubLoginStatus.isEmpty {
            Label(model.githubLoginStatus, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var storageContent: some View {
        SettingsSectionHeading(title: "回退备份")

        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("只留上一版，保留 7 天")
                            .font(.callout.weight(.semibold))
                        Text("启动时自动检查，也可以在这里手动清理到期备份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.isCheckingRollbackBackups ? "正在检查…" : "检查并清理备份") {
                        Task { await model.cleanRollbackBackups() }
                    }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    .disabled(model.isBusy || model.isCheckingRollbackBackups)
                }
                Text(model.backupCheckResult ?? "仅在本机检查，不调用 AI。到期后在下次启动或手动检查时清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        SettingsSectionHeading(title: "SkillBox 保存位置")

        SettingsCard {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill 库与恢复数据")
                        .font(.callout.weight(.semibold))
                    Text(model.libraryRoot.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("在 Finder 中显示") {
                    model.reveal(model.libraryRoot)
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            }
        }

        SettingsSectionHeading(
            title: "寻找记录",
            trailing: "\(model.discoverySessions.count) 条 · \(formattedDiscoveryStorage)"
        )

        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                if model.discoverySessions.isEmpty {
                    ContentUnavailableView(
                        "还没有寻找记录",
                        systemImage: "sparkle.magnifyingglass",
                        description: Text("开始寻找 Skill 后，需求和候选会保存在这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(Array(model.discoverySessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 34, height: 34)
                                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("\(session.candidates.count) 个候选 · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) {
                                Task { await model.deleteDiscoverySession(session) }
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .destructiveText))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 58)

                        if index < min(model.discoverySessions.count, 5) - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Text("开始新的寻找不会删除旧记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("在 Finder 中显示") {
                            model.reveal(model.discoverySessionsDirectory)
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        Button("清空记录", role: .destructive) {
                            confirmClearDiscoverySessions = true
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .destructiveText))
                    }
                    .padding(14)
                }
            }
        }
    }

    @ViewBuilder
    private var privacyContent: some View {
        SettingsSectionHeading(title: "SkillBox 的安全边界")

        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                SettingsSafetyRow(
                    icon: "eye.fill",
                    title: "查看 Skill 时不会运行里面的文件",
                    detail: "扫描、预览和风险检查只读取内容，不执行脚本、构建或安装命令。",
                    color: .blue
                )
                Divider().padding(.leading, 62)
                SettingsSafetyRow(
                    icon: "hand.raised.fill",
                    title: "不会悄悄替换已有文件",
                    detail: "安装、更新和卸载前都会展示变化，需要你确认后才会写入。",
                    color: .orange
                )
                Divider().padding(.leading, 62)
                SettingsSafetyRow(
                    icon: "arrow.uturn.backward.circle.fill",
                    title: "每次写入都会留下恢复记录",
                    detail: "如果目标文件后来又被其他软件修改，恢复会先停下来保护新内容。",
                    color: .purple
                )
                Divider().padding(.leading, 62)
                SettingsSafetyRow(
                    icon: "network",
                    title: "联网用途清楚可见",
                    detail: "只用于 GitHub 来源和版本检查、发现 Skills，以及你主动获取 AI 介绍。",
                    color: .green
                )
                Divider().padding(.leading, 62)
                SettingsSafetyRow(
                    icon: "key.fill",
                    title: "API Key 保存在 macOS 钥匙串",
                    detail: "SkillBox 的设置文件、操作记录和日志都不会保存你的完整 Key。",
                    color: .blue
                )
            }
        }

        SettingsSectionHeading(title: "需要重新了解吗")

        SettingsCard {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("欢迎说明")
                        .font(.callout.weight(.semibold))
                    Text("重新查看 SkillBox 的管理范围、写入确认和恢复规则。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新查看") {
                    model.showOnboarding = true
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            }
        }
    }

    private var formattedDiscoveryStorage: String {
        ByteCountFormatter.string(
            fromByteCount: model.discoveryStorageBytes,
            countStyle: .file
        )
    }

    private func refreshGitHubIfNeeded() async {
        guard selectedSettingsPage == .github,
              model.isGitHubConnected,
              model.githubAuthorizedRepositories.isEmpty
        else { return }
        await model.refreshGitHubRepositories()
    }

    private func openGitHubRepository(_ fullName: String) {
        guard let url = URL(string: "https://github.com/\(fullName)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsNavigationPane: View {
    @ObservedObject var model: AppModel
    @Binding var selection: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("设置")
                    .font(.system(size: 28, weight: .bold))
                Text("管理连接、本机数据与恢复记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 18)

            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    SettingsNavigationRow(
                        page: page,
                        summary: summary(for: page),
                        isSelected: selection == page
                    ) {
                        selection = page
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func summary(for page: SettingsPage) -> String {
        switch page {
        case .ai:
            let count = model.configuredAIProviderIDs.count
            return count == 0 ? "尚未连接服务" : "已连接 \(count) 个"
        case .github:
            guard model.isGitHubConnected else { return "尚未连接" }
            let count = model.githubAuthorizedRepositories.count
            return count == 0 ? "已连接，待选择仓库" : "已连接 · \(count) 个仓库"
        case .storage:
            return "\(model.discoverySessions.count) 条寻找记录 · \(ByteCountFormatter.string(fromByteCount: model.discoveryStorageBytes, countStyle: .file))"
        case .history:
            guard let latest = model.snapshot.transactions.first(where: { $0.restorationContext == nil }) else { return "还没有操作记录" }
            return "最近操作 · \(latest.createdAt.formatted(date: .omitted, time: .shortened))"
        case .privacy:
            return "读取、联网与密钥保护"
        }
    }
}

private struct SettingsNavigationRow: View {
    let page: SettingsPage
    let summary: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                SettingsPageIcon(page: page, size: 36, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 3) {
                    Text(page.rawValue)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(
                maxWidth: .infinity,
                minHeight: SettingsLayout.rowMinimumHitHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.10)
                    : Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.72),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.34)
                            : Color.primary.opacity(isHovering ? 0.10 : 0.055),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isSelected ? 0.025 : 0.015),
                radius: 1,
                y: 1
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? "当前设置" : "")
    }
}

private struct SettingsDetailPage<Content: View>: View {
    let page: SettingsPage
    let content: Content

    init(page: SettingsPage, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsDetailHeader(page: page)
                content
            }
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 42)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
    }
}

private struct SettingsDetailHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsPageIcon(page: page, size: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(page.rawValue)
                    .font(.system(size: 27, weight: .bold))
                Text(page.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }
}

private struct SettingsSectionHeading: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct SettingsCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.45))
            )
    }
}

private struct SettingsBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.09), in: Capsule())
    }
}

private struct SettingsStatusBanner<Accessory: View>: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color
    let accessory: Accessory

    init(
        icon: String,
        title: String,
        detail: String,
        color: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.color = color
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(16)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.22))
        )
    }
}

private struct AIServiceSymbol: View {
    let kind: AIProviderKind
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }

    private var icon: String {
        switch kind {
        case .agnes: "sparkles"
        case .deepSeek: "brain.head.profile"
        case .kimi: "moon.stars.fill"
        case .miniMax: "waveform.path.ecg"
        case .glm: "cube.transparent"
        case .custom: "plus"
        }
    }

    private var color: Color {
        switch kind {
        case .agnes: .purple
        case .deepSeek: .blue
        case .kimi: .indigo
        case .miniMax: .orange
        case .glm: .teal
        case .custom: .blue
        }
    }
}

private struct AIServiceSelectionRow: View {
    let configuration: AIProviderConfiguration
    let isSelected: Bool
    let isConnected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AIServiceSymbol(kind: configuration.kind, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(configuration.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(configuration.kind == .custom
                         ? "OpenAI 兼容接口"
                         : configuration.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                SettingsBadge(
                    title: isConnected ? "已连接" : "未连接",
                    color: isConnected ? .green : .secondary
                )

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : Color.primary.opacity(isHovering ? 0.035 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(isSelected ? "正在管理" : "")
    }
}

private struct SettingsActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let buttonTitle: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.red : Color.secondary)
                .frame(width: 34, height: 34)
                .background(
                    (isDestructive ? Color.red : Color.secondary).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(buttonTitle, role: isDestructive ? .destructive : nil, action: action)
                .buttonStyle(
                    SkillBoxHoverButtonStyle(
                        kind: isDestructive ? .destructiveText : .secondary
                    )
                )
        }
        .padding(.vertical, 12)
    }
}

private struct SettingsSafetyRow: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 64)
    }
}
private struct GitHubConnectionStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(.blue.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var body: some View { VStack(alignment: .leading, spacing: 22) { Label("SkillBox", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.blue); Text("先看清，再决定怎么整理").font(.largeTitle.bold()); Text("SkillBox 会查看各个 AI 应用已经安装的 Skills，找出重复、不同内容和需要留意的地方。这个过程不会改动任何文件。").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 14) { PromiseRow(title: "先看一遍，不动文件", detail: "不会创建、移动、改名或删除已有内容"); PromiseRow(title: "相同内容只整理一次", detail: "名字相同但内容不同时，会留给你选择"); PromiseRow(title: "安装前一定让你确认", detail: "每次安装都有备份，需要时可以恢复") }; Spacer(); HStack { Text("全部处理都在本机完成").font(.caption).foregroundStyle(.secondary); Spacer(); Button("开始") { model.finishOnboarding() }.buttonStyle(.borderedProminent).controlSize(.large) } }.padding(38).frame(width: 650, height: 470).interactiveDismissDisabled() }
}

private struct PromiseRow: View { let title: String; let detail: String; var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: "checkmark").foregroundStyle(.green).frame(width: 24, height: 24).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) } } } }

private struct GitHubImportView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("从 GitHub 添加 Skill").font(.title2.bold())
                    Text("选择要长期跟随的版本来源，再下载完整内容供你确认。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isGitHubConnected {
                    Label("连接记录已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("仓库地址").font(.callout.weight(.semibold))
                TextField("https://github.com/owner/repo", text: $model.githubURL)
                    .textFieldStyle(.roundedBorder)
                Text("可以直接粘贴仓库首页或某个 Skill 子目录地址。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !model.githubURL.isEmpty && !isValidGitHubURL {
                    Label("请粘贴 github.com 的仓库地址", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("以后从哪里判断新版本").font(.callout.weight(.semibold))
                Picker("版本来源", selection: $model.githubTrackingMode) {
                    Text("最新正式 Release").tag(GitHubTrackingMode.latestStableRelease)
                    Text("默认分支").tag(GitHubTrackingMode.defaultBranch)
                }
                .pickerStyle(.segmented)
                Text(trackingExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))

            if !model.isGitHubConnected {
                VStack(alignment: .leading, spacing: 9) {
                    Text("要添加私人仓库？").font(.callout.weight(.semibold))
                    Text("连接后可读取你亲自选择的私人仓库。公开仓库无需连接，可以直接继续。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isGitHubConfigured {
                        Button("连接 GitHub") { Task { await model.connectPrivateGitHub() } }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    } else {
                        Label("当前版本尚未配置 GitHub 登录，公开仓库仍可直接添加。", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let authorization = model.githubAuthorization {
                        GitHubDeviceAuthorizationCard(model: model, authorization: authorization)
                    }
                }
            }

            HStack {
                Button("取消") {
                    model.cancelCandidatePreview()
                    isPresented = false
                }
                Spacer()
                Button {
                    isPresented = false
                    model.startGitHubPreview()
                } label: {
                    Label("下载完整版本并预览", systemImage: "arrow.down.circle")
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .disabled(!isValidGitHubURL || model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 620)
    }

    private var isValidGitHubURL: Bool {
        let value = model.githubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.host?.lowercased() == "github.com" else { return false }
        return url.pathComponents.filter { $0 != "/" }.count >= 2
    }

    private var trackingExplanation: String {
        switch model.githubTrackingMode {
        case .latestStableRelease:
            "适合对外发布的 Skill。只提醒正式 Release，草稿版和预发布版不会出现；仓库没有 Release 时会请你改选默认分支。"
        case .defaultBranch:
            "适合持续开发的 Skill。每次检查都会锁定当时的完整 Commit，README 或其他 Skill 的变化不会误报。"
        }
    }
}

private struct GitHubReleasePackageChoiceView: View {
    @ObservedObject var model: AppModel
    let choice: GitHubReleasePackageChoice
    @State private var selectedAssetID: Int64?
    @State private var hoveredAssetID: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(choice.version.usesSourceArchiveFallback ? "这个 Release 没有独立安装包" : (isUpdate ? "选择用于更新的安装包" : "选择要添加的安装包"))
                        .font(.title3.bold())
                    Text(choice.version.usesSourceArchiveFallback
                         ? "SkillBox 找不到可直接安装的 ZIP。"
                         : "这个 Release 提供了多个 ZIP。请选择一个，SkillBox 不会自行猜测。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if choice.version.usesSourceArchiveFallback {
                fallbackNotice
            } else {
                VStack(spacing: 9) {
                    ForEach(choice.version.releaseAssets) { asset in
                        releaseAssetRow(asset)
                    }
                }
            }

            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Spacer()
                Button("取消") { model.cancelReleasePackageChoice() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                Button(primaryButtonTitle) {
                    model.continueReleasePackageChoice(assetID: selectedAssetID)
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .disabled(!choice.version.usesSourceArchiveFallback && selectedAssetID == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 610)
    }

    private var fallbackNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark")
                .font(.callout.bold())
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text("将导入完整源码").font(.headline)
                Text(choice.version.sourceArchiveFallbackNotice ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("SkillBox 会继续做大小、文件数量和安全检查，并在添加前让你预览内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.35)))
    }

    private func releaseAssetRow(_ asset: GitHubReleaseAsset) -> some View {
        Button {
            selectedAssetID = asset.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedAssetID == asset.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedAssetID == asset.id ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if asset.checksumDownloadURL != nil || asset.digest?.lowercased().hasPrefix("sha256:") == true {
                    Text("带完整性校验")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.09), in: Capsule())
                }
            }
            .padding(14)
            .contentShape(Rectangle())
            .background(
                selectedAssetID == asset.id ? .blue.opacity(0.07) : (hoveredAssetID == asset.id ? Color.primary.opacity(0.035) : .clear),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedAssetID == asset.id ? .blue : Color.secondary.opacity(0.2), lineWidth: selectedAssetID == asset.id ? 2 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredAssetID = hovering ? asset.id : nil }
        .accessibilityLabel("选择 \(asset.name)")
        .accessibilityValue(selectedAssetID == asset.id ? "已选择" : "未选择")
    }

    private var footerText: String {
        if choice.version.usesSourceArchiveFallback {
            return "添加和安装时不会运行任何文件。如果你期待的是精简版，可以取消并联系仓库作者上传安装包。"
        }
        return "下一步会检查 ZIP 的内容，并在添加前让你预览 Skill。不会运行里面的文件。"
    }

    private var isUpdate: Bool {
        if case .updateSkill = choice.purpose { return true }
        return false
    }

    private var primaryButtonTitle: String {
        if choice.version.usesSourceArchiveFallback {
            return isUpdate ? "用完整源码更新" : "导入完整源码"
        }
        return isUpdate ? "下载并查看更新" : "下载并预览"
    }
}

private struct GitHubInstallContentChoiceView: View {
    @ObservedObject var model: AppModel
    let choice: GitHubInstallContentChoice

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 46, height: 46)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.title2.bold())
                        Text("SkillBox 会优先保证功能齐全；只有明确的仓库资料才会默认排除。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if choice.review.version.usesSourceArchiveFallback {
                    Label(
                        "作者没有提供独立安装包。无法确认用途的文件会默认保留，避免 Skill 缺少功能。",
                        systemImage: "info.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("将保留").font(.headline)
                    Text("主说明提到的文件和用途不明的内容都会保留，避免缺少功能。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(installableEntries) { entry in
                                contentRow(entry)
                                if entry.id != installableEntries.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.42)))
                }

                if !choice.review.repositoryOnlyPaths.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("默认不安装 \(choice.review.repositoryOnlyPaths.count) 项仓库资料")
                                .font(.callout.weight(.semibold))
                            Text(choice.review.repositoryOnlyPaths.joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            .padding(26)

            Divider()
            HStack(spacing: 10) {
                Text("这个选择会跟随这份 Skill，后续更新无需重复设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.cancelInstallContentChoice() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                Button(primaryTitle) {
                    model.continueInstallContentChoice(includePaths: choice.review.recommendedIncludePaths)
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 680)
        .interactiveDismissDisabled()
    }

    private var installableEntries: [GitHubPackageEntry] {
        choice.review.entries.filter { $0.kind != .repositoryOnly }
    }

    private func contentRow(_ entry: GitHubPackageEntry) -> some View {
        let required = entry.kind == .required
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(required ? .blue : .green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.relativePath).font(.callout.weight(.medium))
                Text(entryDescription(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(required ? "必须保留" : "保留")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(required ? .blue : .green)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((required ? Color.blue : Color.green).opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func entryDescription(_ entry: GitHubPackageEntry) -> String {
        switch entry.kind {
        case .required: entry.relativePath == "SKILL.md"
            ? "Skill 主说明，安装时必须保留"
            : "主说明明确用到了它，必须保留"
        case .likelyRuntime: "通常是 Skill 运行时会用到的内容"
        case .possibleRuntime: "用途暂时无法确定，为保证功能会默认保留"
        case .repositoryOnly: "GitHub 仓库资料，不会安装"
        }
    }

    private var title: String {
        if !choice.review.newUnreviewedPaths.isEmpty { return "确认新的 Skill 内容" }
        if case .migrateSkill = choice.purpose { return "整理成纯净 Skill" }
        return "确认要安装的内容"
    }

    private var primaryTitle: String {
        switch choice.purpose {
        case .importSkill: "继续预览"
        case .updateSkill: "继续查看更新"
        case .migrateSkill: "保存为纯净 Skill"
        }
    }
}

private struct LocalSourceSetupView: View {
    @ObservedObject var model: AppModel
    let setup: LocalSourceSetup
    @State private var selectedCandidateIDs: Set<String>
    @State private var includePathsByCandidate: [String: Set<String>]

    init(model: AppModel, setup: LocalSourceSetup) {
        self.model = model
        self.setup = setup
        _selectedCandidateIDs = State(initialValue: Set(setup.reviews.map { $0.candidate.id }))
        _includePathsByCandidate = State(initialValue: Dictionary(uniqueKeysWithValues: setup.reviews.map {
            ($0.candidate.id, Set($0.recommendedIncludePaths))
        }))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 46, height: 46)
                            .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.title2.bold())
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(setup.reviews) { review in
                        localSkillReview(review)
                    }

                    Label(
                        "SkillBox 不会移动、改名或修改开发项目，也不会运行其中的脚本。",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(26)
            }

            Divider()
            HStack(spacing: 10) {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.cancelLocalSourceSetup() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    .disabled(model.isBusy)
                Button(primaryTitle) {
                    let paths = Dictionary(uniqueKeysWithValues: selectedCandidateIDs.compactMap { candidateID in
                        includePathsByCandidate[candidateID].map { (candidateID, Array($0)) }
                    })
                    Task {
                        await model.confirmLocalSourceSetup(
                            setup,
                            includePathsByCandidate: paths
                        )
                    }
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .disabled(model.isBusy || selectedCandidateIDs.isEmpty || !allSelectionsAreValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 860, minHeight: 600, idealHeight: 720, maxHeight: 860)
        .interactiveDismissDisabled()
    }

    private func localSkillReview(_ review: LocalPackageReview) -> some View {
        let isSelected = selectedCandidateIDs.contains(review.candidate.id)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                if setup.purpose == .importSkills {
                    Toggle(isOn: Binding(
                        get: { isSelected },
                        set: { selected in
                            if selected { selectedCandidateIDs.insert(review.candidate.id) }
                            else { selectedCandidateIDs.remove(review.candidate.id) }
                        }
                    )) { EmptyView() }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(review.candidate.displayName).font(.headline)
                    Text(sourcePath(review))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(selectedCount(review)) / \(review.entries.count) 项进入 SkillBox")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 0) {
                ForEach(review.entries) { entry in
                    let required = entry.kind == .required
                    Toggle(isOn: Binding(
                        get: { includePathsByCandidate[review.candidate.id, default: []].contains(entry.relativePath) },
                        set: { selected in
                            if selected { includePathsByCandidate[review.candidate.id, default: []].insert(entry.relativePath) }
                            else if !required { includePathsByCandidate[review.candidate.id, default: []].remove(entry.relativePath) }
                        }
                    )) {
                        HStack(spacing: 9) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(required ? .blue : entry.kind == .developmentOnly ? .secondary : .green)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.relativePath).font(.callout.weight(.medium))
                                Text(entryDescription(entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!isSelected || required)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if entry.id != review.entries.last?.id { Divider() }
                }
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.42)))
        }
        .padding(14)
        .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.42)))
        .opacity(isSelected ? 1 : 0.56)
    }

    private var title: String {
        switch setup.purpose {
        case .importSkills: "把这个文件夹作为开发源？"
        case .editSkill: "确认进入 SkillBox 的内容"
        case .relinkSkill: "重新关联本地开发源"
        }
    }

    private var subtitle: String {
        switch setup.purpose {
        case .importSkills:
            "文件夹继续留在原位。SkillBox 只读取你确认的内容，保存一份纯净版本用于安装，以后可手动检查更新。"
        case .editSkill:
            "调整后先生成更新预览；确认更新前，SkillBox 主 Skill 和应用副本都不会变化。"
        case .relinkSkill:
            "先核对新位置和可使用内容，再决定是否替换 SkillBox 保存的版本。"
        }
    }

    private var primaryTitle: String {
        switch setup.purpose {
        case .importSkills: "添加并跟踪更新"
        case .editSkill: "继续查看变化"
        case .relinkSkill: "核对并重新关联"
        }
    }

    private var footerText: String {
        switch setup.purpose {
        case .importSkills: "以后手动检查更新，不会监听每次保存。"
        case .editSkill, .relinkSkill: "现有内容会一直保留到你确认更新。"
        }
    }

    private var allSelectionsAreValid: Bool {
        setup.reviews.filter { selectedCandidateIDs.contains($0.candidate.id) }.allSatisfy { review in
            let selected = includePathsByCandidate[review.candidate.id, default: []]
            return selected.contains("SKILL.md") && review.entries
                .filter { $0.kind == .required }
                .allSatisfy { selected.contains($0.relativePath) }
        }
    }

    private func selectedCount(_ review: LocalPackageReview) -> Int {
        includePathsByCandidate[review.candidate.id, default: []].count
    }

    private func sourcePath(_ review: LocalPackageReview) -> String {
        review.skillRelativePath.isEmpty ? review.projectRootPath : review.skillRelativePath
    }

    private func entryDescription(_ entry: LocalPackageEntry) -> String {
        switch entry.kind {
        case .required: entry.relativePath == "SKILL.md" ? "Skill 主说明，必须保留" : "主说明明确用到了它，必须保留"
        case .likelyRuntime: "通常属于 Skill 可使用内容"
        case .possibleRuntime: "用途暂时无法确定，默认保留"
        case .developmentOnly: "开发资料，默认只留在项目中"
        }
    }
}

private struct GitHubDeviceAuthorizationCard: View {
    @ObservedObject var model: AppModel
    let authorization: GitHubDeviceAuthorization

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("1")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.blue, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("在 GitHub 确认身份").font(.callout.weight(.semibold))
                    Text("SkillBox 会复制验证码并打开浏览器。确认后回到这里继续。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("验证码").font(.caption).foregroundStyle(.secondary)
                    Text(authorization.userCode)
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                }
                Spacer()
                Button("复制验证码并继续") { model.openGitHubAuthorization() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
            }
            Label("无需下载其他软件", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Label("这一步只确认你的身份，不会创建仓库或修改文件。重新开始只会换一个会过期的临时验证码。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.blue.opacity(0.16)))
        .accessibilityElement(children: .contain)
        .accessibilityHint("复制验证码并在浏览器中确认 GitHub 身份")
    }
}

private struct ImportPreviewView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var isShowingHighRiskConfirmation = false

    private var isResolvingConflict: Bool { model.activeConflict != nil }

    private var title: String {
        if let conflict = model.activeConflict { return "选择 \(conflict.canonicalName) 的保留版本" }
        return model.updatingSkillID == nil ? "选择要添加的 Skills" : "确认更新"
    }

    private var explanation: String {
        if model.activeConflict != nil {
            return "这些 Skill 名字相同，但内容不同。选中一份加入「我的 Skills」，其他位置的原文件仍会保留。"
        }
        return model.updatingSkillID == nil
            ? "勾选要加入「我的 Skills」的内容。名字相同但内容不同时，需要你选其中一份。"
            : "确认后，SkillBox 会保留旧内容的备份，并更新库里的这份 Skill。已经安装到应用里的内容不会自动变化。"
    }

    private var confirmTitle: String {
        if isResolvingConflict { return "保留所选版本" }
        return model.updatingSkillID == nil ? "添加所选" : "确认更新"
    }

    private var selectedHighRiskCandidates: [SkillCandidate] {
        model.pendingCandidates.filter {
            model.selectedCandidateIDs.contains($0.id) && $0.riskReport.requiresUserAttention
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(explanation).foregroundStyle(.secondary)
            if isResolvingConflict {
                conflictChoices
            } else {
                candidateChoices
            }
            HStack {
                Button("取消") {
                    model.cancelCandidatePreview()
                    isPresented = false
                }
                Spacer()
                Button(confirmTitle) {
                    if selectedHighRiskCandidates.isEmpty {
                        beginImport(authorizingHighRisk: false)
                    } else {
                        isShowingHighRiskConfirmation = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCandidateIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .interactiveDismissDisabled()
        .confirmationDialog(
            "这些 Skill 包含需要确认的内容",
            isPresented: $isShowingHighRiskConfirmation,
            titleVisibility: .visible
        ) {
            Button("我已查看证据，仍然添加", role: .destructive) {
                beginImport(authorizingHighRisk: true)
            }
            Button("返回检查", role: .cancel) {}
        } message: {
            Text("将添加：\(selectedHighRiskCandidates.map(\.displayName).joined(separator: "、"))。添加时不会运行文件；只有你或 AI 应用以后主动运行相关脚本时，提示中的行为才可能发生。")
        }
    }

    private func beginImport(authorizingHighRisk: Bool) {
        isPresented = false
        Task { await model.importSelectedCandidates(authorizingHighRisk: authorizingHighRisk) }
    }

    private var conflictChoices: some View {
        List(model.pendingCandidates) { candidate in
            Button {
                model.setCandidate(candidate, selected: true)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.selectedCandidateIDs.contains(candidate.id) ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(model.selectedCandidateIDs.contains(candidate.id) ? Color.accentColor : .secondary)
                        .font(.title3)
                        .padding(.top, 2)
                    CandidateSummary(
                        candidate: candidate,
                        sourceText: "在 \(model.sourceSummary(for: candidate)) 中找到"
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(candidate.riskReport.isBlocked)
            .accessibilityHint("选择这一份加入 SkillBox")
        }
        .frame(minHeight: 320)
    }

    private var candidateChoices: some View {
        List(model.pendingCandidates) { candidate in
            Toggle(isOn: Binding(
                get: { model.selectedCandidateIDs.contains(candidate.id) },
                set: { model.setCandidate(candidate, selected: $0) }
            )) {
                CandidateSummary(candidate: candidate, sourceText: "来自 \(candidate.source.displayName)")
            }
            .disabled(candidate.riskReport.isBlocked)
        }
        .frame(minHeight: 320)
    }
}

private struct UpdatePreviewView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var pendingHighRiskDeployChoice: Bool?

    private var skill: SkillRecord? {
        guard let id = model.updatingSkillID else { return nil }
        return model.snapshot.skills.first { $0.id == id }
    }

    private var candidate: SkillCandidate? { model.pendingCandidates.first }

    private var canUpdate: Bool {
        guard let candidate else { return false }
        return !candidate.riskReport.isBlocked && model.selectedCandidateIDs.contains(candidate.id)
    }

    private var installedDestinations: [ManagedInstallation] {
        guard let skill else { return [] }
        return model.snapshot.installations.filter { $0.skillID == skill.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("查看这次更新").font(.title2.bold())
                    Text(headerSubtitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    model.cancelCandidatePreview()
                    isPresented = false
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        UpdateMetric(title: "新增", value: changeCount(.added), color: .green)
                        UpdateMetric(title: "修改", value: changeCount(.modified), color: .blue)
                        UpdateMetric(title: "移除", value: changeCount(.removed), color: .orange)
                        UpdateMetric(title: "原有安装", value: installedDestinations.count, color: .purple)
                    }

                    riskChangeCard

                    GroupBox("文件变化") {
                        if model.pendingUpdateChanges.isEmpty {
                            ContentUnavailableView(
                                "文件内容没有变化",
                                systemImage: "checkmark.circle",
                                description: Text("版本名称发生变化，但这个 Skill 目录的内容相同。")
                            )
                            .frame(minHeight: 120)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(model.pendingUpdateChanges, id: \.path) { change in
                                    HStack(spacing: 10) {
                                        Image(systemName: changeIcon(change.kind))
                                            .foregroundStyle(changeColor(change.kind))
                                            .frame(width: 20)
                                        Text(change.path)
                                            .font(.system(.caption, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(changeLabel(change.kind))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(changeColor(change.kind))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    if change.path != model.pendingUpdateChanges.last?.path { Divider() }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if isLocalUpdate, !model.pendingLocalIgnoredChangedPaths.isEmpty {
                        GroupBox("只留在开发项目中的变化") {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("这些内容不在已确认的可使用范围内，不会进入 SkillBox 或任何 AI 应用。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(model.pendingLocalIgnoredChangedPaths, id: \.self) { path in
                                    HStack(spacing: 9) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.secondary)
                                        Text(path)
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                        Text("已忽略")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }

                    GroupBox("SKILL.md 更新前后") {
                        HStack(alignment: .top, spacing: 12) {
                            markdownPreview(title: "当前版本", text: model.pendingUpdateBeforeMarkdown)
                            markdownPreview(title: "新版本", text: model.pendingUpdateAfterMarkdown)
                        }
                        .padding(.vertical, 5)
                    }

                    if !installedDestinations.isEmpty {
                        GroupBox("更新并安装时会处理这些位置") {
                            VStack(spacing: 0) {
                                ForEach(installedDestinations, id: \.destinationPath) { installation in
                                    destinationRow(installation)
                                    if installation.destinationPath != installedDestinations.last?.destinationPath { Divider() }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Label(
                        isLocalUpdate
                            ? "开发项目保持原样。确认后会先保留旧版本；中途失败会恢复已经改动的 SkillBox 内容和应用副本。"
                            : "确认后会先保留旧版本。中央原件和可更新的应用副本会一起处理；中途失败会恢复已经改动的内容。",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }

            Divider()
            HStack(spacing: 10) {
                Button("取消") {
                    model.cancelCandidatePreview()
                    isPresented = false
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                Spacer()
                if installedDestinations.isEmpty {
                    Button("更新我的 Skills") { apply(deployToExisting: false) }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        .disabled(!canUpdate || model.isBusy)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("只更新我的 Skills") { apply(deployToExisting: false) }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        .disabled(!canUpdate || model.isBusy)
                    Button("更新并安装到原有应用") { apply(deployToExisting: true) }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        .disabled(!canUpdate || model.isBusy)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 760, idealWidth: 940, maxWidth: 1080, minHeight: 620, idealHeight: 760, maxHeight: 900)
        .interactiveDismissDisabled()
        .confirmationDialog(
            "新版本包含需要确认的内容",
            isPresented: Binding(
                get: { pendingHighRiskDeployChoice != nil },
                set: { if !$0 { pendingHighRiskDeployChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("我已查看证据，仍然更新", role: .destructive) {
                guard let deployToExisting = pendingHighRiskDeployChoice else { return }
                performUpdate(deployToExisting: deployToExisting, authorizingHighRisk: true)
            }
            Button("返回检查", role: .cancel) { pendingHighRiskDeployChoice = nil }
        } message: {
            Text("更新时不会运行文件。请确认你已经看过上方列出的文件、命中内容和说明。")
        }
    }

    private var headerSubtitle: String {
        let name = skill?.displayName ?? "这份 Skill"
        if isLocalUpdate {
            return "\(name) · 来源项目保持原样 · 确认后才替换 SkillBox 保存的纯净版本"
        }
        let version = model.pendingGitHubVersion?.versionName ?? "新版本"
        return "\(name) · \(version) · 下载的是这个版本的完整快照"
    }

    private var isLocalUpdate: Bool {
        guard let candidate, let skill else { return false }
        return candidate.source.kind == .localFolder &&
            model.snapshot.localSourceStates.contains { $0.skillID == skill.id }
    }

    @ViewBuilder
    private var riskChangeCard: some View {
        if let skill, let candidate {
            let becameRiskier = candidate.riskReport.highestSeverity > skill.riskReport.highestSeverity
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: candidate.riskReport.isBlocked ? "xmark.shield.fill" : becameRiskier ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(candidate.riskReport.isBlocked ? .red : becameRiskier ? .orange : .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.riskReport.isBlocked ? "新版本已被安全检查阻止" : becameRiskier ? "新版本出现了更高风险提示" : "没有发现更高的风险级别")
                        .font(.headline)
                    Text("新版本检查了 \(candidate.riskReport.scannedFileCount) 个文件，发现 \(candidate.riskReport.findings.count) 项提示。SkillBox 不会运行其中任何文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(candidate.riskReport.actionableFindings.prefix(4)) { finding in
                        Text("\(finding.relativePath) · \(finding.title)：\(finding.evidence)")
                            .font(.caption2)
                            .foregroundStyle(finding.severity == .blocked ? .red : .orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background((candidate.riskReport.isBlocked ? Color.red : becameRiskier ? Color.orange : Color.green).opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func markdownPreview(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ReadOnlyTextView(text: text)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.45)))
        }
        .frame(maxWidth: .infinity)
    }

    private func destinationRow(_ installation: ManagedInstallation) -> some View {
        let target = model.snapshot.targets.first { $0.id == installation.targetID }
        let action = model.syncPlan?.actions.first { $0.destinationPath == installation.destinationPath }
        let canWrite = target?.detectionStatus == .available && target?.writeStatus == .writable
        let pendingRemoval = action?.kind == .remove
        let blocked = action?.kind == .blocked || !canWrite
        let skipped = blocked || pendingRemoval
        return HStack(spacing: 10) {
            Image(systemName: skipped ? "exclamationmark.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(skipped ? .orange : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(target?.displayName ?? "已移除的应用").font(.callout.weight(.medium))
                Text(pendingRemoval ? "已取消选择，等待你单独确认卸载" : blocked ? "保持旧版本，不会覆盖" : "内容未被外部修改，可以更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(skipped ? "暂不处理" : "将更新")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(skipped ? .orange : .blue)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private func apply(deployToExisting: Bool) {
        if candidate?.riskReport.requiresUserAttention == true {
            pendingHighRiskDeployChoice = deployToExisting
            return
        }
        performUpdate(deployToExisting: deployToExisting, authorizingHighRisk: false)
    }

    private func performUpdate(deployToExisting: Bool, authorizingHighRisk: Bool) {
        pendingHighRiskDeployChoice = nil
        isPresented = false
        Task {
            await model.applyPendingUpdate(
                deployToExisting: deployToExisting,
                authorizingHighRisk: authorizingHighRisk
            )
        }
    }

    private func changeCount(_ kind: SkillFileChangeKind) -> Int {
        model.pendingUpdateChanges.count { $0.kind == kind }
    }

    private func changeLabel(_ kind: SkillFileChangeKind) -> String {
        switch kind { case .added: "新增"; case .modified: "修改"; case .removed: "移除" }
    }

    private func changeIcon(_ kind: SkillFileChangeKind) -> String {
        switch kind { case .added: "plus.circle.fill"; case .modified: "pencil.circle.fill"; case .removed: "minus.circle.fill" }
    }

    private func changeColor(_ kind: SkillFileChangeKind) -> Color {
        switch kind { case .added: .green; case .modified: .blue; case .removed: .orange }
    }
}

private struct UpdateMetric: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)").font(.headline)
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CandidateSummary: View {
    let candidate: SkillCandidate
    let sourceText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.displayName).font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(candidate.riskReport.isBlocked ? .red : .secondary)
            }
            Text(candidate.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(sourceText) · 内容编号 \(String(candidate.fingerprint.prefix(8)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if candidate.riskReport.requiresUserAttention {
                ForEach(candidate.riskReport.actionableFindings.prefix(3)) { finding in
                    Text("\(finding.relativePath) · \(finding.title)：\(finding.evidence)")
                        .font(.caption2)
                        .foregroundStyle(finding.severity == .blocked ? .red : .orange)
                        .lineLimit(2)
                }
            }
        }
    }

    private var statusText: String {
        if candidate.riskReport.isBlocked { return "无法添加" }
        if candidate.riskReport.requiresUserAttention { return "需要确认" }
        if candidate.riskReport.findings.isEmpty { return "检查通过" }
        return "有 \(candidate.riskReport.findings.count) 项需要留意"
    }
}

private struct SkillRemovalOptionsView: View {
    private enum Choice {
        case keepInstalledCopies
        case uninstallAll
    }

    @ObservedObject var model: AppModel
    let skill: SkillRecord
    @Binding var isPresented: Bool
    let onDeleted: () -> Void
    let onPreparedUninstall: () -> Void
    @State private var choice: Choice = .keepInstalledCopies
    @State private var isSubmitting = false

    private var installedTargetNames: [String] {
        let targetIDs = Set(model.snapshot.installations
            .filter { $0.skillID == skill.id }
            .map(\.targetID))
        return model.snapshot.targets
            .filter { targetIDs.contains($0.id) }
            .map(\.displayName)
    }

    private var targetSummary: String {
        guard !installedTargetNames.isEmpty else { return "已安装的应用" }
        if installedTargetNames.count <= 3 {
            return installedTargetNames.joined(separator: "、")
        }
        return installedTargetNames.prefix(2).joined(separator: "、") + "等 \(installedTargetNames.count) 个应用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("从 SkillBox 移除这份 Skill？")
                .font(.title2.bold())
            Text("选择如何处理由 SkillBox 安装到 \(targetSummary) 的副本。其他同名 Skill 不会受影响。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(spacing: 10) {
                optionCard(
                    .keepInstalledCopies,
                    title: "只清理 SkillBox 主 Skill",
                    description: "保留 \(targetSummary) 中现有副本；以后不再由 SkillBox 管理或更新。",
                    safeLabel: "不改应用文件"
                )
                optionCard(
                    .uninstallAll,
                    title: "全部卸载并清理",
                    description: "先从 \(targetSummary) 卸载这份 Skill，再清理 SkillBox 主 Skill。下一步仍会展示卸载清单。"
                )
            }
            .padding(.top, 20)

            Text("SkillBox 主 Skill 会移入 macOS 废纸篓，可以立即撤销；清空废纸篓后将无法恢复。保留的应用副本不会被修改。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 9) {
                Spacer()
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(choice == .keepInstalledCopies ? "只清理主 Skill" : "查看卸载清单") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 640)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func optionCard(
        _ value: Choice,
        title: String,
        description: String,
        safeLabel: String? = nil
    ) -> some View {
        let selected = choice == value
        return Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.red : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                if let safeLabel {
                    Text(safeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.10), in: Capsule())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.red.opacity(0.055) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.red.opacity(0.75) : Color.secondary.opacity(0.22), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)。\(description)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        switch choice {
        case .keepInstalledCopies:
            Task {
                let deleted = await model.deleteSkill(skill, preservingInstalledCopies: true)
                isSubmitting = false
                guard deleted else { return }
                isPresented = false
                onDeleted()
            }
        case .uninstallAll:
            Task {
                let prepared = await model.prepareUninstallEverywhere(skill, deletingAfterwards: true)
                isSubmitting = false
                guard prepared else { return }
                onPreparedUninstall()
            }
        }
    }
}

private struct ActionSummaryCard: View {
    let title: String
    let value: String
    let note: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(value).font(.title.bold())
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
    }
}

private struct SyncPreviewView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(previewTitle)
                .font(.title2.bold())
            Text("现在只是预览。确认前不会保存安装选择，也不会写入任何应用文件夹。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let plan = model.syncPlan {
                HStack {
                    ActionSummaryCard(title: "准备改动", value: "\(plan.executableActions.count)", note: "开始前会留备份", color: .blue)
                    ActionSummaryCard(title: "需要你处理", value: "\(plan.blockedActions.count)", note: "解决前不会改动", color: .orange)
                }
                List(plan.actions.filter { $0.kind != .noChange }) { action in
                    HStack {
                        Image(systemName: action.kind == .blocked ? "exclamationmark.triangle.fill" : "arrow.right.circle.fill")
                            .foregroundStyle(action.kind == .blocked ? .orange : .blue)
                        VStack(alignment: .leading) {
                            Text(action.summary).font(.headline)
                            Text("安装位置：\(targetName(for: action))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if action.kind == .blocked, action.blockReason == .unmanagedConflict {
                            Button(action.expectedSourceFingerprint == action.expectedDestinationFingerprint ? "让 SkillBox 管理这份内容" : "用 SkillBox 中的版本替换") {
                                Task {
                                    await model.authorize(
                                        action: action,
                                        replacement: action.expectedSourceFingerprint != action.expectedDestinationFingerprint
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 290)
                Text(model.isDeletingSkillAfterSync
                    ? "确认后才会卸载这些受管理副本；全部安全完成后，SkillBox 才会清理主 Skill。"
                    : "真正写入前，SkillBox 会再检查一次。如果文件在你确认后发生变化，会停下来并恢复已经完成的部分。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("取消，不保存") {
                    model.cancelSyncPreview()
                    isPresented = false
                }
                Spacer()
                Button(confirmButtonTitle) {
                    isPresented = false
                    Task { await model.executePlan() }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isDeletingSkillAfterSync ? .red : .accentColor)
                .disabled(model.syncPlan?.executableActions.isEmpty != false)
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(true)
    }

    private var isRemovalPreview: Bool {
        let actions = model.syncPlan?.executableActions ?? []
        return !actions.isEmpty && actions.allSatisfy { $0.kind == .remove }
    }

    private var previewTitle: String {
        if model.isDeletingSkillAfterSync { return "确认卸载并清理" }
        return isRemovalPreview ? "确认卸载改动" : "确认安装改动"
    }

    private var confirmButtonTitle: String {
        if model.isDeletingSkillAfterSync { return "确认卸载并清理" }
        return isRemovalPreview ? "确认卸载" : "确认安装"
    }

    private func targetName(for action: SyncAction) -> String {
        model.snapshot.targets.first { $0.id == action.targetID }?.displayName ?? "已移除的应用"
    }
}

private struct CustomTargetView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool; @Binding var name: String
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("添加其他安装位置").font(.title2.bold()); TextField("应用名称", text: $name); Text("给这个位置起个容易识别的名字，再选择该应用用来保存 Skills 的文件夹。为了安全，不能直接选整个磁盘或用户文件夹。").font(.caption).foregroundStyle(.secondary); HStack { Button("取消") { isPresented = false }; Spacer(); Button("选择文件夹…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { isPresented = false; Task { await model.addCustomTarget(name: name, url: url) } } }.buttonStyle(.borderedProminent) } }.padding(24).frame(width: 520) }
}

private struct EditCustomTargetView: View {
    @ObservedObject var model: AppModel
    let target: AgentTarget
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var selectedURL: URL

    init(model: AppModel, target: AgentTarget, isPresented: Binding<Bool>) {
        self.model = model
        self.target = target
        _isPresented = isPresented
        _name = State(initialValue: target.displayName)
        _selectedURL = State(initialValue: URL(fileURLWithPath: target.path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("编辑安装位置").font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("应用名称").font(.callout.weight(.semibold))
                TextField("应用名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Skills 文件夹").font(.callout.weight(.semibold))
                Text(selectedURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("选择其他文件夹…") { chooseDirectory() }
                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
            }
            Text("如果这个位置仍有 Skill 由 SkillBox 管理，需要先卸载才能更换文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("取消") { isPresented = false }
                Spacer()
                Button("保存") {
                    isPresented = false
                    Task { await model.updateCustomTarget(target, name: name, url: selectedURL) }
                }
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = selectedURL
        if panel.runModal() == .OK, let url = panel.url { selectedURL = url }
    }
}
