import AppKit
import SkillBoxCore
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "总览"
    case library = "我的 Skills"
    case agents = "安装到应用"
    case history = "最近操作"
    case settings = "设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .library: "books.vertical"
        case .agents: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var selection: SidebarItem? = .overview
    @State private var selectedSkillID: UUID?
    @State private var showGitHub = false
    @State private var showImportPreview = false
    @State private var showUpdatePreview = false
    @State private var showSyncPreview = false
    @State private var showCustomTarget = false
    @State private var customTargetName = "其他应用"
    @State private var editingCustomTarget: AgentTarget?

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("SkillBox")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Text("已找到 \(model.snapshot.targets.filter { $0.detectionStatus == .available }.count) 个应用位置")
                    .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    OverviewView(
                        model: model,
                        goTo: { selection = $0 },
                        reviewConflict: { conflict in
                            model.prepareConflictImport(conflict)
                            showImportPreview = true
                        },
                        reviewAllConflicts: {
                            model.prepareScanImport()
                            showImportPreview = true
                        }
                    )
                case .library:
                    LibraryView(
                        model: model,
                        selectedSkillID: $selectedSkillID,
                        showSyncPreview: $showSyncPreview,
                        importLocal: chooseLocalFolder,
                        importGitHub: { showGitHub = true },
                        openSettings: { selection = .settings },
                        connectGitHub: {
                            selection = .settings
                            if model.isGitHubConfigured { Task { await model.connectPrivateGitHub() } }
                        }
                    )
                case .agents:
                    AgentsView(
                        model: model,
                        addCustom: { showCustomTarget = true },
                        addSkill: { selection = .library },
                        editCustom: { editingCustomTarget = $0 }
                    )
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(selection?.rawValue ?? "SkillBox")
            .toolbar {
                Button { Task { await model.scanInstalledSkills() } } label: {
                    Label("重新扫描本机 Skills", systemImage: "arrow.clockwise")
                }
                .help("重新扫描本机 Skills，不会修改任何文件")
                .disabled(model.isBusy)
            }
            .overlay(alignment: .bottomLeading) {
                StatusPill(model: model)
                    .padding(18)
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $showGitHub) { GitHubImportView(model: model, isPresented: $showGitHub) }
        .sheet(item: $model.pendingReleasePackageChoice) { choice in
            GitHubReleasePackageChoiceView(model: model, choice: choice)
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
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.canRetryGitHubWithDefaultBranch {
                Button("改用默认分支继续") { model.retryGitHubUsingDefaultBranch() }
            }
            Button("取消", role: .cancel) {
                model.canRetryGitHubWithDefaultBranch = false
                model.errorMessage = nil
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
}

private struct StatusPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label(model.statusMessage, systemImage: model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(model.isBusy ? Color.secondary : Color.green)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator.opacity(0.35)))
            .accessibilityLabel("当前状态：\(model.statusMessage)")
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
            Text("已删除 \(deletion.record.displayName)").font(.callout.weight(.medium))
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

private struct MetricCard: View {
    let title: String; let value: String; let note: String; let color: Color
    var body: some View { VStack(alignment: .leading, spacing: 7) { HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Circle().fill(color).frame(width: 8, height: 8) }; Text(value).font(.title.bold()); Text(note).font(.caption2).foregroundStyle(.tertiary) }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4))) }
}

private struct OverviewView: View {
    @ObservedObject var model: AppModel
    let goTo: (SidebarItem) -> Void
    let reviewConflict: (ConflictGroup) -> Void
    let reviewAllConflicts: () -> Void
    private var updateCount: Int {
        model.snapshot.sourceStates.count { $0.status == .updateAvailable || $0.status == .releasePackageAvailable }
    }
    private var sourceAttentionCount: Int {
        model.snapshot.sourceStates.count { $0.status == .authenticationRequired || $0.status == .unavailable }
    }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) { PageHeader(eyebrow: "当前情况", title: "你的 Skills 一目了然", subtitle: "本机查看到 \(model.scanResult?.candidates.count ?? 0) 份内容；这里优先显示需要你处理的事情。") ; Spacer(); Button("把找到的 Skills 加入管理", action: reviewAllConflicts).disabled(model.scanResult?.candidates.isEmpty != false); if updateCount > 0 { Button("查看 \(updateCount) 个更新") { goTo(.library) } }; Button("选择安装位置") { goTo(.agents) }.buttonStyle(.borderedProminent) }
            HStack(spacing: 12) {
                MetricCard(title: "已加入 SkillBox", value: "\(model.snapshot.skills.count)", note: "集中保存在本机", color: .blue)
                MetricCard(title: "可以更新", value: "\(updateCount)", note: "由你确认后才下载", color: updateCount > 0 ? .blue : .green)
                MetricCard(title: "需要处理", value: "\((model.scanResult?.conflicts.count ?? 0) + sourceAttentionCount)", note: "内容冲突或来源失效", color: (model.scanResult?.conflicts.isEmpty != false && sourceAttentionCount == 0) ? .green : .orange)
                MetricCard(title: "已找到的应用", value: "\(model.snapshot.targets.filter { $0.detectionStatus == .available }.count)", note: "共支持 9 款应用", color: .green)
            }
            GroupBox("需要你选择") { VStack(alignment: .leading, spacing: 0) {
                if let conflicts = model.scanResult?.conflicts, !conflicts.isEmpty {
                    ForEach(conflicts.prefix(5)) { conflict in
                        ConflictRow(conflict: conflict) { reviewConflict(conflict) }
                    }
                    if conflicts.count > 5 {
                        Divider()
                        Button("整理全部 \(conflicts.count) 组") { reviewAllConflicts() }
                            .padding(.top, 10)
                    }
                } else { ContentUnavailableView("没有需要处理的同名内容", systemImage: "checkmark.circle", description: Text("以后发现同名但内容不同的 Skill，会在这里请你选择")) }
            }.padding(.vertical, 4) }
            GroupBox("应用位置") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 10) { ForEach(model.snapshot.targets) { target in HStack { Image(systemName: target.detectionStatus == .available ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(target.detectionStatus == .available ? .green : .secondary); VStack(alignment: .leading) { Text(target.displayName).font(.callout.weight(.medium)); Text(target.detectionStatus == .available ? "已找到" : "尚未在本机使用").font(.caption2).foregroundStyle(.secondary) }; Spacer() }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).help(target.path) } }.padding(.vertical, 5) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(28) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConflictRow: View {
    let conflict: ConflictGroup
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(conflict.canonicalName) 有 \(conflict.versions.count) 份不同内容")
                        .font(.callout.weight(.medium))
                    Text("点击查看来源并选择保留哪一份")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isHovering ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint("查看这些版本并选择一份加入 SkillBox")
    }
}

private struct LibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    @Binding var showSyncPreview: Bool
    let importLocal: () -> Void
    let importGitHub: () -> Void
    let openSettings: () -> Void
    let connectGitHub: () -> Void
    @State private var searchText = ""
    @State private var filter: SkillListFilter = .all
    @State private var isAddMenuHovered = false
    var selected: SkillRecord? { model.snapshot.skills.first { $0.id == selectedSkillID } ?? model.snapshot.skills.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(eyebrow: "集中管理", title: "我的 Skills", subtitle: "每个 Skill 在这里保留一份，再由你决定安装到哪些应用。")
                Spacer()
                if !model.snapshot.skills.isEmpty {
                    HStack(spacing: 10) {
                        if !model.snapshot.sourceStates.isEmpty {
                            Button {
                                Task { await model.checkAllGitHubUpdates() }
                            } label: {
                                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            .disabled(model.isBusy)
                            .help("检查 GitHub 来源是否有新版本")
                        }
                        if !model.isGitHubConnected {
                            Button(action: model.isGitHubConfigured ? connectGitHub : openSettings) {
                                Label(model.isGitHubConfigured ? "连接私人仓库" : "私人仓库暂不可用", systemImage: "lock.open")
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            .help(model.isGitHubConfigured ? "连接 GitHub 后可以添加和跟踪私人仓库" : "查看私人仓库连接状态")
                        }
                        Menu {
                            Button("从电脑文件夹添加", action: importLocal)
                            Button("从 GitHub 仓库添加", action: importGitHub)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("添加 Skill")
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
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
                    .padding(.top, 1)
                }
            }
            .padding(28)
            if model.snapshot.skills.isEmpty {
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
                            Button(model.isGitHubConfigured ? "连接私人仓库" : "了解私人仓库状态", action: model.isGitHubConfigured ? connectGitHub : openSettings)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
            } else {
                HSplitView {
                    SkillOrganizerSidebar(
                        model: model,
                        selectedSkillID: $selectedSkillID,
                        searchText: $searchText,
                        filter: $filter
                    )
                        .frame(minWidth: 280, idealWidth: 330)
                    if let selected {
                        SkillDetailView(
                            model: model,
                            skill: selected,
                            showSyncPreview: $showSyncPreview,
                            openSettings: openSettings
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
}

private enum SkillListFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case updates = "有更新"
    case installed = "已安装"
    case attention = "需要处理"

    var id: String { rawValue }
}

private struct SkillOrganizerSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    @Binding var searchText: String
    @Binding var filter: SkillListFilter
    @State private var collapsedFolderIDs: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private var folders: [SkillFolder] { model.orderedFolders().filter { !filteredSkills(in: $0.id).isEmpty } }
    private var uncategorized: [SkillRecord] { filteredSkills(in: nil) }
    private var hasResults: Bool { !uncategorized.isEmpty || !folders.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("我的分类").font(.headline)
                    Text("拖动 Skill 可整理和排序").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                .help("新建文件夹")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            HStack(spacing: 8) {
                TextField("搜索 Skills", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("筛选", selection: $filter) {
                    ForEach(SkillListFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                if hasResults {
                    LazyVStack(alignment: .leading, spacing: 5) {
                    OrganizerGroupHeader(title: "未分类", count: uncategorized.count, systemImage: "tray")
                        .dropDestination(for: String.self) { items, _ in
                            guard let skillID = firstSkillID(in: items) else { return false }
                            Task { await model.moveSkill(skillID, to: nil) }
                            return true
                        }
                    ForEach(uncategorized) { skill in
                        SkillOrganizerRow(
                            model: model,
                            skill: skill,
                            folderID: nil,
                            selectedSkillID: $selectedSkillID
                        )
                    }
                    ForEach(folders) { folder in
                        OrganizerFolderHeader(
                            model: model,
                            folder: folder,
                            count: model.orderedSkills(in: folder.id).count,
                            isCollapsed: collapsedFolderIDs.contains(folder.id),
                            onToggle: {
                                if collapsedFolderIDs.contains(folder.id) { collapsedFolderIDs.remove(folder.id) }
                                else { collapsedFolderIDs.insert(folder.id) }
                            }
                        )
                        if !collapsedFolderIDs.contains(folder.id) {
                            ForEach(filteredSkills(in: folder.id)) { skill in
                                SkillOrganizerRow(
                                    model: model,
                                    skill: skill,
                                    folderID: folder.id,
                                    selectedSkillID: $selectedSkillID
                                )
                            }
                        }
                    }
                    }
                    .padding(8)
                } else {
                    ContentUnavailableView(
                        "没有符合条件的 Skill",
                        systemImage: "magnifyingglass",
                        description: Text("换一个关键词或筛选条件试试")
                    )
                    .padding(.top, 44)
                }
            }
        }
        .background(.quaternary.opacity(0.12))
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("例如：写作、开发、运营", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                Task { _ = await model.createSkillFolder(named: newFolderName) }
            }
        } message: {
            Text("文件夹只用于整理列表，不会移动或修改 Skill 原件。")
        }
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
                return status == .updateAvailable || status == .releasePackageAvailable
            case .installed:
                return model.snapshot.installations.contains { $0.skillID == skill.id }
            case .attention:
                let sourceStatus = model.snapshot.sourceStates.first { $0.skillID == skill.id }?.status
                return skill.riskReport.highestSeverity >= .caution || sourceStatus == .authenticationRequired || sourceStatus == .unavailable
            }
        }
    }

    private func firstSkillID(in items: [String]) -> UUID? {
        items.compactMap(OrganizerDragItem.init).compactMap(\.skillID).first
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
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct OrganizerFolderHeader: View {
    @ObservedObject var model: AppModel
    let folder: SkillFolder
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameValue = ""

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(folder.name).font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
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
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(isHovered ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .draggable("folder:\(folder.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.compactMap(OrganizerDragItem.init).first else { return false }
            switch item {
            case let .skill(skillID): Task { await model.moveSkill(skillID, to: folder.id) }
            case let .folder(folderID): Task { await model.moveFolder(folderID, before: folder.id) }
            }
            return true
        }
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
    @ObservedObject var model: AppModel
    let skill: SkillRecord
    let folderID: UUID?
    @Binding var selectedSkillID: UUID?
    @State private var isHovered = false

    private var isSelected: Bool { selectedSkillID == skill.id }

    var body: some View {
        Button { selectedSkillID = skill.id } label: {
            HStack(spacing: 9) {
                Image(systemName: riskIcon)
                    .foregroundStyle(riskColor)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 3) {
                    Text(skill.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(skill.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                let status = model.snapshot.sourceStates.first(where: { $0.skillID == skill.id })?.status
                if status == .updateAvailable || status == .releasePackageAvailable {
                    Text("有更新")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.10), in: Capsule())
                }
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .draggable("skill:\(skill.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            guard let movingID = items.compactMap(OrganizerDragItem.init).compactMap(\.skillID).first,
                  movingID != skill.id
            else { return false }
            Task { await model.moveSkill(movingID, to: folderID, before: skill.id) }
            return true
        }
        .contextMenu {
            Menu("移动到") {
                Button("未分类") { Task { await model.moveSkill(skill.id, to: nil) } }
                ForEach(model.orderedFolders()) { folder in
                    Button(folder.name) { Task { await model.moveSkill(skill.id, to: folder.id) } }
                }
            }
        }
        .help("拖动调整顺序，或拖到文件夹中分类")
    }

    private var rowBackground: Color {
        if isSelected { return .accentColor.opacity(0.16) }
        if isHovered { return .primary.opacity(0.055) }
        return .clear
    }

    private var riskIcon: String {
        switch skill.riskReport.highestSeverity {
        case .blocked: "xmark.shield.fill"
        case .high: "exclamationmark.triangle.fill"
        case .caution: "info.circle.fill"
        case .info: "checkmark.circle.fill"
        }
    }

    private var riskColor: Color {
        switch skill.riskReport.highestSeverity {
        case .blocked: .red
        case .high: .orange
        case .caution: .blue
        case .info: .green
        }
    }
}

private enum OrganizerDragItem {
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
                .buttonStyle(SkillBoxHoverButtonStyle(kind: state?.status == .updateAvailable || state?.status == .releasePackageAvailable ? .primary : .secondary))
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
        switch state?.status {
        case .updateAvailable: "发现新版本"
        case .releasePackageAvailable: "有更干净的安装包"
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
        switch state?.status {
        case .updateAvailable: "先查看文件变化，再决定是否更新和重新安装。"
        case .releasePackageAvailable: "这是同一个 GitHub Release，不是作者新发了版本。建议查看后替换为作者提供的纯净安装包。"
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
        switch state?.status {
        case .updateAvailable, .ignored: "查看这次更新"
        case .releasePackageAvailable: "查看安装包变化"
        case .checkingStopped: "重新开启"
        case .authenticationRequired: "前往设置"
        default: "检查更新"
        }
    }

    private var icon: String {
        switch state?.status {
        case .updateAvailable: "arrow.down.circle.fill"
        case .releasePackageAvailable: "archivebox.fill"
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
        switch state?.status {
        case .updateAvailable, .releasePackageAvailable: .blue
        case .ignored, .checkingStopped, .needsInitialCheck: .orange
        case .authenticationRequired, .unavailable: .red
        case .current: .green
        case nil: .secondary
        }
    }

    private func primaryAction() {
        switch state?.status {
        case .updateAvailable, .releasePackageAvailable, .ignored:
            model.startAvailableUpdatePreview(skill)
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
}

private struct SkillDetailView: View {
    private enum Confirmation: String, Identifiable {
        case installEverywhere
        case uninstallEverywhere
        case delete
        case uninstallBeforeDelete
        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let skill: SkillRecord
    @Binding var showSyncPreview: Bool
    let openSettings: () -> Void
    let onDeleted: () -> Void
    @State private var showRawSource = false
    @State private var showDetails = true
    @State private var showSafetyDetails = false
    @State private var directoryEntries: [SkillDirectoryEntry] = []
    @State private var usageGuide: SkillUsageGuide?
    @State private var isLoadingDirectory = true
    @State private var isDetailsHeaderHovered = false
    @State private var confirmation: Confirmation?

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top, spacing: 14) {
                    Text(String(skill.displayName.prefix(1)).uppercased())
                        .font(.title3.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 48, height: 48)
                        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(skill.displayName)
                            .font(.title2.bold())
                        Text(skill.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    Button("在 Finder 中显示") { Task { model.reveal(await model.contentURL(for: skill)) } }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                }
                HStack(spacing: 8) {
                    Label(skill.source.displayName, systemImage: "tray.full")
                    Text("·")
                    Label("\(skill.riskReport.scannedFileCount) 个文件", systemImage: "doc.on.doc")
                    Text("·")
                    Text(skill.importedAt, format: .dateTime.year().month().day())
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if skill.source.kind == .github {
                    GitHubSourceCard(model: model, skill: skill, openSettings: openSettings)
                }
                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("安装到你的 AI 应用")
                                .font(.headline)
                            Text(installationAvailabilityMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(availableTargets.count) 个可用")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(availableTargets.isEmpty ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                (availableTargets.isEmpty ? Color.secondary : Color.accentColor).opacity(0.09),
                                in: Capsule()
                            )
                    }
                    HStack(spacing: 8) {
                        Button {
                            confirmation = .installEverywhere
                        } label: {
                            Label("安装到全部应用", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(availableTargets.isEmpty)
                        .help(availableTargets.isEmpty ? "本机还没有找到可安装 Skill 的应用" : "先查看完整安装清单")
                        Button {
                            confirmation = .uninstallEverywhere
                        } label: {
                            Label("卸载全部", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(!hasInstallations && !hasDesiredAssignments)
                        Spacer()
                    }
                    Divider().opacity(0.55)
                    HStack {
                        Text(installedTargets.isEmpty ? "尚未通过 SkillBox 安装" : "已安装到 \(installedTargets.count) 个应用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("删除这份 Skill", role: .destructive) {
                            confirmation = hasInstallations ? .uninstallBeforeDelete : .delete
                        }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .destructiveText))
                    }
                }
                .padding(16)
                .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.blue.opacity(0.15)))

                if !installedTargets.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("已安装到")
                            .font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(installedTargets) { target in
                                    Label(target.displayName, systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(.quaternary.opacity(0.4), in: Capsule())
                                }
                            }
                        }
                    }
                }

                if let usageGuide {
                    SkillUsageGuideCard(guide: usageGuide)
                }

                riskSummary

                VStack(spacing: 0) {
                    Button {
                        if reduceMotion { showDetails.toggle() }
                        else {
                            withAnimation(.easeOut(duration: 0.14)) { showDetails.toggle() }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showDetails ? 90 : 0))
                                .foregroundStyle(isDetailsHeaderHovered ? Color.blue : Color.secondary)
                            Text("查看 Skill 详情").font(.headline)
                            Spacer()
                            Text("\(skill.riskReport.scannedFileCount) 个文件")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(isDetailsHeaderHovered ? Color.blue.opacity(0.07) : .clear)
                    .onHover { isDetailsHeaderHovered = $0 }
                    .help(showDetails ? "收起 Skill 详情" : "展开 Skill 详情")

                    if showDetails {
                        Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 11) {
                            Image(systemName: "doc.richtext.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 34, height: 34)
                                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("SKILL.md").font(.callout.weight(.semibold))
                                Text(mainMarkdownSubtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("预览") { showRawSource = true }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        }
                        .padding(11)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

                        HStack {
                            Text("完整目录").font(.callout.weight(.semibold))
                            Spacer()
                            Text("文件只读展示").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if isLoadingDirectory {
                            ProgressView("正在读取目录…")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else if directoryEntries.isEmpty {
                            ContentUnavailableView("无法读取目录", systemImage: "folder.badge.questionmark")
                                .frame(minHeight: 140)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    Label(skill.canonicalName, systemImage: "folder.fill")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                    ForEach(directoryEntries) { entry in
                                        SkillDirectoryRow(entry: entry)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(5)
                            }
                            .frame(maxHeight: 240)
                            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.45)))
                        }
                        Text("内容校验码 \(String(skill.fingerprint.prefix(12)))… · 用于发现文件是否被改过")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .transition(.opacity)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.55)))
            }
            .padding(26)
        }
        .sheet(isPresented: $showRawSource) {
            SkillRawSourceView(model: model, skill: skill, isPresented: $showRawSource)
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
            case .uninstallBeforeDelete:
                Button("准备全部卸载") {
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

    private var mainMarkdownSubtitle: String {
        guard let fileSize = mainMarkdown?.fileSize else { return "主说明文件" }
        return "主说明文件 · \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))"
    }

    @ViewBuilder
    private var riskSummary: some View {
        if skill.riskReport.findings.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("文件检查未发现需要处理的内容")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("只读检查")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if reduceMotion { showSafetyDetails.toggle() }
                    else {
                        withAnimation(.easeOut(duration: 0.14)) { showSafetyDetails.toggle() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: riskSummaryIcon)
                            .foregroundStyle(riskTint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("文件检查")
                                .font(.callout.weight(.medium))
                            Text("\(skill.riskReport.findings.count) 项内容提示 · 安装时不会运行这些文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(showSafetyDetails ? "收起" : "查看")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showSafetyDetails ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showSafetyDetails ? "收起文件检查" : "查看文件检查的具体提示")

                if showSafetyDetails {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                    Image(systemName: riskSummaryIcon)
                        .font(.title3)
                        .foregroundStyle(riskTint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(riskSummaryTitle)
                            .font(.headline)
                        Text("添加和安装 Skill 时不会运行这些文件。下面的命令只有在你或 AI 应用主动运行脚本时才可能执行。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                        ForEach(skill.riskReport.findings.prefix(6)) { finding in
                            Divider().opacity(0.45)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(riskFindingTitle(finding)).font(.callout.weight(.medium))
                                    Spacer()
                                    Text(riskLevel(finding.severity))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(riskFindingColor(finding.severity))
                                }
                                Text(riskFindingExplanation(finding))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let evidence = riskEvidence(finding) {
                                    Text(evidence)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Text("这是文件内容提示，不代表 Skill 已经运行，也不代表它一定有问题。静态检查无法保证绝对安全。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .transition(.opacity)
                }
            }
            .background(riskTint.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(riskTint.opacity(0.15)))
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .installEverywhere: "安装到全部可用应用？"
        case .uninstallEverywhere: "从所有应用卸载？"
        case .uninstallBeforeDelete: "请先从所有应用卸载"
        case .delete: "从「我的 Skills」删除？"
        case nil: "请确认"
        }
    }

    private func confirmationMessage(for choice: Confirmation) -> String {
        switch choice {
        case .installEverywhere: installEverywhereMessage
        case .uninstallEverywhere: "下一步会列出准备移除的位置。只有 SkillBox 管理且内容没有被其他软件改过的副本才能卸载。"
        case .uninstallBeforeDelete: "这份 Skill 仍安装在应用中。先完成卸载，可以避免留下 SkillBox 无法继续管理的副本。"
        case .delete: "中央内容会移到 SkillBox 的「已删除」文件夹，不会立即永久清除。其他应用中未由 SkillBox 管理的文件不会被改动。"
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
        return "已找到 \(availableTargets.count) 个可安装应用。继续后会先让你查看完整清单。"
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

private struct SkillUsageGuideCard: View {
    let guide: SkillUsageGuide
    @State private var copiedPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("这个 Skill 怎么用")
                        .font(.headline)
                    Text("根据作者提供的说明整理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            guideSection(title: "能帮你什么", icon: "sparkles") {
                Text(guide.purpose)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let useWhen = guide.useWhen {
                Divider()
                guideSection(title: "什么时候适合", icon: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(useWhen)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let avoidWhen = guide.avoidWhen {
                            Text("不适合：\(avoidWhen)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let starterPrompt = guide.starterPrompt {
                Divider()
                guideSection(title: "可以这样告诉 AI", icon: "quote.bubble") {
                    HStack(alignment: .center, spacing: 12) {
                        Text(starterPrompt)
                            .font(.callout)
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
                    .padding(11)
                    .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if !guide.experienceSteps.isEmpty {
                Divider()
                guideSection(title: "使用时会发生什么", icon: "point.3.connected.trianglepath.dotted") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(guide.experienceSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 22, height: 22)
                                    .background(.blue.opacity(0.09), in: Circle())
                                Text(step)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.blue.opacity(0.13)))
    }

    @ViewBuilder
    private func guideSection<Content: View>(
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

private struct AgentsView: View {
    @ObservedObject var model: AppModel
    let addCustom: () -> Void
    let addSkill: () -> Void
    let editCustom: (AgentTarget) -> Void
    @State private var targetToRemove: AgentTarget?
    @State private var assignmentProposal: AssignmentProposal?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(eyebrow: "按需调整", title: "安装到应用", subtitle: "点击一个状态，就会立即让你确认这一项安装或卸载；批量操作仍在 Skill 详情中。")
                Spacer()
                Button("添加其他应用", action: addCustom)
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
                    AssignmentLegend(symbol: "plus", color: .secondary, text: "点击安装")
                    AssignmentLegend(symbol: "checkmark", color: .green, text: "已安装")
                    AssignmentLegend(symbol: "square.stack.3d.up.fill", color: .orange, text: "已有同名，点击比较")
                    AssignmentLegend(symbol: "link", color: .purple, text: "间接可用")
                    AssignmentLegend(symbol: "nosign", color: .secondary, text: "应用不可用")
                    AssignmentLegend(symbol: "exclamationmark", color: .orange, text: "需要处理")
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("我的 Skills").font(.caption.weight(.semibold)).frame(width: 210, alignment: .leading)
                            ForEach(model.snapshot.targets) { target in
                                TargetColumnHeader(
                                    target: target,
                                    edit: { editCustom(target) },
                                    remove: { targetToRemove = target }
                                )
                                .frame(width: 84)
                            }
                        }
                        Divider().gridCellColumns(model.snapshot.targets.count + 1)
                        ForEach(model.snapshot.skills) { skill in
                            GridRow {
                                Text(skill.displayName)
                                    .font(.callout.weight(.medium))
                                    .frame(width: 210, alignment: .leading)
                                ForEach(model.snapshot.targets) { target in
                                    AssignmentButton(model: model, skill: skill, target: target) {
                                        Task {
                                            assignmentProposal = await model.prepareAssignmentProposal(skill: skill, target: target)
                                        }
                                    }
                                    .frame(width: 84)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "移除“\(targetToRemove?.displayName ?? "")”的安装位置？",
            isPresented: Binding(get: { targetToRemove != nil }, set: { if !$0 { targetToRemove = nil } })
        ) {
            if let targetToRemove {
                Button("移除安装位置", role: .destructive) {
                    Task { await model.removeCustomTarget(targetToRemove) }
                    self.targetToRemove = nil
                }
            }
            Button("取消", role: .cancel) { targetToRemove = nil }
        } message: {
            Text("这不会删除应用文件夹。若这里仍有 Skill 由 SkillBox 管理，会为了安全阻止移除。")
        }
        .sheet(item: $assignmentProposal) { proposal in
            AgentAssignmentSheet(model: model, proposal: proposal)
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
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Text(target.displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if target.isCustom {
                Menu {
                    Button("编辑名称或位置", action: edit)
                    Button("移除安装位置", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("管理这个安装位置")
            }
        }
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

    private var indirect: Bool {
        target.kind == .kimiCode && model.scanResult?.candidates.contains(where: {
            $0.fingerprint == skill.fingerprint && !$0.sourceURL.path.hasPrefix(target.path + "/")
        }) == true
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
        if action?.blockReason == .unmanagedConflict || hasUnmanagedSameName {
            return "square.stack.3d.up.fill"
        }
        if action?.kind == .blocked { return "exclamationmark" }
        if !available && !desired { return "nosign" }
        if action?.kind == .create || action?.kind == .update { return "arrow.up" }
        if indirect && !desired { return "link" }
        return desired ? "checkmark" : "plus"
    }

    private var color: Color {
        if action?.blockReason == .unmanagedConflict || hasUnmanagedSameName { return .orange }
        if action?.kind == .blocked { return .orange }
        if !available { return .secondary }
        if indirect && !desired { return .purple }
        return desired ? .green : .secondary
    }

    private var help: String {
        if action?.blockReason == .unmanagedConflict || hasUnmanagedSameName {
            return "这里已有同名 Skill，点击比较内容"
        }
        if !available && !desired {
            return "本机没有找到可用的安装位置"
        }
        if indirect && !desired {
            return "Kimi Code 已能通过其他位置使用这个 Skill"
        }
        if action?.kind == .blocked { return action?.summary ?? "这项需要处理" }
        return desired ? "已安装，点击卸载" : "点击安装到 \(target.displayName)"
    }
}

private struct AgentAssignmentSheet: View {
    @ObservedObject var model: AppModel
    let proposal: AssignmentProposal
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

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
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isActionable ? "取消" : "知道了") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isActionable {
                    Button(confirmTitle) {
                        isConfirming = true
                        Task {
                            let succeeded = await model.confirmAssignmentProposal(proposal)
                            isConfirming = false
                            if succeeded { dismiss() }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(eyebrow: "可以反悔", title: "最近操作", subtitle: "安装、卸载和原件更新都会留在这里，需要时可以恢复。")
                if model.snapshot.transactions.isEmpty {
                    ContentUnavailableView("还没有操作记录", systemImage: "clock.arrow.circlepath", description: Text("第一次安装、更新或卸载完成后会出现在这里"))
                } else {
                    ForEach(model.snapshot.transactions) { transaction in
                        HistoryTransactionCard(model: model, transaction: transaction)
                    }
                }
            }
            .padding(28)
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
                if transaction.status == .succeeded {
                    Button("恢复到操作前") { Task { await model.undo(transaction) } }
                        .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
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

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDisconnect = false
    @State private var confirmClearGitHub = false
    @State private var confirmOpenGitHubRevoke = false
    @State private var showAllRepositories = false

    var body: some View {
        Form {
            Section("GitHub 账号") {
                if model.isGitHubConnected {
                    HStack(spacing: 12) {
                        Image(systemName: model.githubAuthorizedRepositories.isEmpty ? "person.crop.circle.badge.checkmark" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(model.githubAuthorizedRepositories.isEmpty ? .blue : .green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.githubAuthorizedRepositories.isEmpty ? "GitHub 身份已确认" : "私人仓库已连接").font(.headline)
                            Text(model.githubAuthorizedRepositories.isEmpty
                                 ? "还需在 GitHub 选择 SkillBox 可以读取的仓库。"
                                 : "SkillBox 只能读取你亲自选择的仓库，不能修改其中内容。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("管理可访问仓库") { model.manageGitHubRepositories() }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                        Menu {
                            Button("断开连接") { confirmDisconnect = true }
                            Button("在 GitHub 撤销授权") { confirmOpenGitHubRevoke = true }
                            Divider()
                            Button("清除 GitHub 信息", role: .destructive) { confirmClearGitHub = true }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if model.githubAuthorizedRepositories.isEmpty {
                        HStack(spacing: 12) {
                            if model.isWaitingForGitHubRepositorySelection {
                                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundStyle(.blue)
                                    .frame(width: 28, height: 28)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.isWaitingForGitHubRepositorySelection ? "正在等待你选择仓库" : "还差一步：选择仓库")
                                    .font(.callout.weight(.semibold))
                                Text("在 GitHub 选好并安装后，直接回到 SkillBox，这里会自动完成。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.isWaitingForGitHubRepositorySelection ? "重新打开 GitHub" : "选择仓库") { model.manageGitHubRepositories() }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                        }
                        .padding(12)
                        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("可访问仓库").font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(model.githubAuthorizedRepositories.count) 个")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(model.githubAuthorizedRepositories.prefix(showAllRepositories ? model.githubAuthorizedRepositories.count : 6))) { repository in
                                HStack(spacing: 9) {
                                    Image(systemName: repository.isPrivate ? "lock.fill" : "globe")
                                        .foregroundStyle(repository.isPrivate ? .orange : .blue)
                                        .frame(width: 18)
                                    Text(repository.fullName)
                                    Spacer()
                                    Text(repository.isPrivate ? "私人" : "公开")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            if model.githubAuthorizedRepositories.count > 6 {
                                Button(showAllRepositories ? "收起仓库列表" : "查看全部仓库") {
                                    showAllRepositories.toggle()
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("连接私人仓库", systemImage: "lock.open.fill")
                            .font(.headline)
                        Text("只有添加私人仓库时才需要连接。整个过程在浏览器中完成，不用下载其他软件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("你只需在 GitHub 页面确认身份和选择仓库，页面跳转和结果检查由 SkillBox 完成。", systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            GitHubConnectionStep(number: 1, title: "确认身份", detail: "打开 GitHub")
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            GitHubConnectionStep(number: 2, title: "选择仓库", detail: "只选需要的")
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            GitHubConnectionStep(number: 3, title: "回到 SkillBox", detail: "开始检查更新")
                        }

                        if model.isGitHubConfigured {
                            Button("开始连接") { Task { await model.connectPrivateGitHub() } }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                                .disabled(model.isBusy)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("当前版本尚未启用私人仓库", systemImage: "exclamationmark.circle.fill")
                                    .font(.callout.weight(.semibold))
                                Text("这不是加载过程，不需要继续等待。公开仓库仍然可以直接添加。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                    if let authorization = model.githubAuthorization {
                        GitHubDeviceAuthorizationCard(model: model, authorization: authorization)
                    }
                }
                if !model.githubLoginStatus.isEmpty {
                    Text(model.githubLoginStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("数据与隐私") {
                LabeledContent("SkillBox 保存位置", value: model.libraryRoot.path)
                LabeledContent("联网", value: "只在添加 GitHub 来源或检查更新时")
                LabeledContent("使用数据收集", value: "不收集")
            }
            Section("安全承诺") {
                Label("查看 Skill 时不会运行里面的文件", systemImage: "checkmark.shield")
                Label("已有文件不会被悄悄替换", systemImage: "hand.raised")
                Label("如果其他软件改过文件，SkillBox 会先停下来提醒你", systemImage: "exclamationmark.triangle")
            }
            Section {
                Button("重新查看欢迎说明") { model.showOnboarding = true }
                Button("在访达中打开保存位置") { model.reveal(model.libraryRoot) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 12)
        .task {
            if model.isGitHubConnected && model.githubAuthorizedRepositories.isEmpty {
                await model.refreshGitHubRepositories()
            }
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
            Text("SkillBox 会删除登录信息、仓库地址和更新记录。现有 Skills 会保留为本地副本，之后不会再从 GitHub 检查更新。")
        }
        .confirmationDialog("前往 GitHub 撤销授权？", isPresented: $confirmOpenGitHubRevoke) {
            Button("打开 GitHub") { model.openGitHubAuthorizationSettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("GitHub 端的访问许可需要在 GitHub 设置中撤销。完成后也可以回到这里清除本机信息。")
        }
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
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
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
                    Text("连接后选择允许 SkillBox 读取的仓库。整个过程在浏览器中完成，不用下载其他软件。公开仓库可以直接继续。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isGitHubConfigured {
                        Button("连接私人仓库") { Task { await model.connectPrivateGitHub() } }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    } else {
                        Label("当前版本尚未启用私人仓库，公开仓库仍可直接添加。", systemImage: "info.circle")
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
                    isPresented = false
                    Task { await model.importSelectedCandidates() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedCandidateIDs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .interactiveDismissDisabled()
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
                        "确认后会先保留旧版本。中央原件和可更新的应用副本会一起处理；中途失败会恢复已经改动的内容。",
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
    }

    private var headerSubtitle: String {
        let name = skill?.displayName ?? "这份 Skill"
        let version = model.pendingGitHubVersion?.versionName ?? "新版本"
        return "\(name) · \(version) · 下载的是这个版本的完整快照"
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
        isPresented = false
        Task { await model.applyPendingUpdate(deployToExisting: deployToExisting) }
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
        }
    }

    private var statusText: String {
        if candidate.riskReport.isBlocked { return "无法添加" }
        if candidate.riskReport.findings.isEmpty { return "检查通过" }
        return "有 \(candidate.riskReport.findings.count) 项需要留意"
    }
}

private struct SyncPreviewView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("确认安装改动").font(.title2.bold()); if let plan = model.syncPlan { HStack { MetricCard(title: "准备改动", value: "\(plan.executableActions.count)", note: "开始前会留备份", color: .blue); MetricCard(title: "需要你处理", value: "\(plan.blockedActions.count)", note: "解决前不会改动", color: .orange) }; List(plan.actions.filter { $0.kind != .noChange }) { action in HStack { Image(systemName: action.kind == .blocked ? "exclamationmark.triangle.fill" : "arrow.right.circle.fill").foregroundStyle(action.kind == .blocked ? .orange : .blue); VStack(alignment: .leading) { Text(action.summary).font(.headline); Text("安装位置：\(targetName(for: action))").font(.caption2).foregroundStyle(.secondary) }; Spacer(); if action.kind == .blocked, action.blockReason == .unmanagedConflict { Button(action.expectedSourceFingerprint == action.expectedDestinationFingerprint ? "让 SkillBox 管理这份内容" : "用 SkillBox 中的版本替换") { Task { await model.authorize(action: action, replacement: action.expectedSourceFingerprint != action.expectedDestinationFingerprint) } } } } }.frame(minHeight: 290); Text("真正写入前，SkillBox 会再检查一次。如果文件在你确认后发生变化，会停下来并恢复已经完成的部分。").font(.caption).foregroundStyle(.secondary) }; HStack { Button("返回调整") { isPresented = false }; Spacer(); Button("确认并开始") { isPresented = false; Task { await model.executePlan() } }.buttonStyle(.borderedProminent).disabled(model.syncPlan?.executableActions.isEmpty != false) } }.padding(24).frame(width: 760, height: 560) }

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
