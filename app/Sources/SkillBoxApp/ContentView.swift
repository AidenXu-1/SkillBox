import AppKit
import SkillBoxCore
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "总览"
    case library = "我的 Skills"
    case agents = "自定义安装"
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
    @State private var showSyncPreview = false
    @State private var showCustomTarget = false
    @State private var customTargetName = "其他应用"

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("SkillBox")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    statusLabel
                    Text("已找到 \(model.snapshot.targets.filter { $0.detectionStatus == .available }.count) 个应用位置")
                        .font(.caption2).foregroundStyle(.secondary)
                }
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
                        importGitHub: { showGitHub = true }
                    )
                case .agents:
                    AgentsView(
                        model: model,
                        showSyncPreview: $showSyncPreview,
                        addCustom: { showCustomTarget = true },
                        addSkill: { selection = .library }
                    )
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(selection?.rawValue ?? "SkillBox")
            .toolbar { Button { Task { await model.scanInstalledSkills() } } label: { Label("重新查看", systemImage: "arrow.clockwise") }.disabled(model.isBusy) }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $showGitHub) { GitHubImportView(model: model, isPresented: $showGitHub) }
        .sheet(isPresented: $showImportPreview) { ImportPreviewView(model: model, isPresented: $showImportPreview) }
        .sheet(isPresented: $showSyncPreview) { SyncPreviewView(model: model, isPresented: $showSyncPreview) }
        .sheet(isPresented: $showCustomTarget) { CustomTargetView(model: model, isPresented: $showCustomTarget, name: $customTargetName) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("知道了") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .alert("提示", isPresented: Binding(get: { model.noticeMessage != nil }, set: { if !$0 { model.noticeMessage = nil } })) { Button("知道了") { model.noticeMessage = nil } } message: { Text(model.noticeMessage ?? "") }
        .onChange(of: model.pendingCandidates) { _, candidates in if !candidates.isEmpty { showImportPreview = true } }
    }

    private var statusLabel: some View {
        let icon = model.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
        let color: Color = model.isBusy ? .secondary : .green
        return Label(model.statusMessage, systemImage: icon).font(.caption).foregroundStyle(color)
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "查看可添加的 Skills"
        if panel.runModal() == .OK, let url = panel.url { Task { await model.previewLocalFolder(url) } }
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
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) { PageHeader(eyebrow: "当前情况", title: "你的 Skills 一目了然", subtitle: "这里汇总本机已找到、已加入 SkillBox 和需要你选择的内容。") ; Spacer(); Button("把找到的 Skills 加入管理", action: reviewAllConflicts).disabled(model.scanResult?.candidates.isEmpty != false); Button("选择安装位置") { goTo(.agents) }.buttonStyle(.borderedProminent) }
            HStack(spacing: 12) {
                MetricCard(title: "已加入 SkillBox", value: "\(model.snapshot.skills.count)", note: "集中保存在本机", color: .blue)
                MetricCard(title: "本机找到", value: "\(model.scanResult?.candidates.count ?? 0)", note: "只查看，没有改动", color: .green)
                MetricCard(title: "需要选择", value: "\(model.scanResult?.conflicts.count ?? 0)", note: "名字相同但内容不同", color: .orange)
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
    let importLocal: () -> Void; let importGitHub: () -> Void
    var selected: SkillRecord? { model.snapshot.skills.first { $0.id == selectedSkillID } ?? model.snapshot.skills.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(eyebrow: "集中管理", title: "我的 Skills", subtitle: "每个 Skill 在这里保留一份，再由你决定安装到哪些应用。")
                Spacer()
                if !model.snapshot.skills.isEmpty {
                    Button("从电脑添加", action: importLocal)
                    Button("从 GitHub 添加", action: importGitHub).buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
            if model.snapshot.skills.isEmpty {
                ContentUnavailableView {
                    Label("还没有添加 Skill", systemImage: "shippingbox")
                } description: {
                    Text("从电脑文件夹或公开 GitHub 地址添加，确认前只会查看内容。")
                } actions: {
                    HStack {
                        Button("从电脑添加", action: importLocal)
                        Button("从 GitHub 添加", action: importGitHub)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 72)
            } else {
                HSplitView {
                    SkillOrganizerSidebar(model: model, selectedSkillID: $selectedSkillID)
                        .frame(minWidth: 280, idealWidth: 330)
                    if let selected {
                        SkillDetailView(model: model, skill: selected, showSyncPreview: $showSyncPreview) {
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

private struct SkillOrganizerSidebar: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    @State private var collapsedFolderIDs: Set<UUID> = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private var folders: [SkillFolder] { model.orderedFolders() }
    private var uncategorized: [SkillRecord] { model.orderedSkills(in: nil) }

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
            Divider()
            ScrollView {
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
                            ForEach(model.orderedSkills(in: folder.id)) { skill in
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
        skill.riskReport.highestSeverity >= .high ? "exclamationmark.triangle.fill" : skill.riskReport.highestSeverity == .caution ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private var riskColor: Color {
        skill.riskReport.highestSeverity >= .high ? .red : skill.riskReport.highestSeverity == .caution ? .orange : .green
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
    let onDeleted: () -> Void
    @State private var showRawSource = false
    @State private var showDetails = true
    @State private var directoryEntries: [SkillDirectoryEntry] = []
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
                    if skill.source.kind == .github {
                        Button("检查更新") { Task { await model.checkForUpdate(skill) } }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                    }
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
                Divider()

                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("安装到你的 AI 应用")
                                .font(.headline)
                            Text("只会选择已经找到且可以写入的位置，继续后先给你看安装清单。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button {
                                confirmation = .installEverywhere
                            } label: {
                                Label("安装到全部可用应用", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                            Button {
                                confirmation = .uninstallEverywhere
                            } label: {
                                Text("全部卸载")
                            }
                            .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            .disabled(!hasInstallations && !hasDesiredAssignments)
                        }
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
                .padding(15)
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
            directoryEntries = await model.skillDirectory(skill)
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
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("没有发现需要阻止的内容")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("SkillBox 只查看文件，不会运行里面的内容。仍建议只使用你信任的来源。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.green.opacity(0.15)))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("使用前检查")
                    .font(.headline)
                ForEach(skill.riskReport.findings.prefix(6)) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(riskTitle(finding.category)).font(.callout.weight(.medium))
                            Spacer()
                            Text(riskLevel(finding.severity))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(finding.severity >= .high ? .red : finding.severity == .caution ? .orange : .secondary)
                        }
                        Text("\(riskAdvice(finding.severity)) 位置：\(finding.relativePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("SkillBox 只查看文件，不会运行里面的内容。静态检查无法保证绝对安全。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.orange.opacity(0.15)))
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

    private func riskTitle(_ category: RiskCategory) -> String {
        switch category {
        case .invalidFormat: "文件结构不完整"
        case .executableFile: "包含可以直接运行的文件"
        case .binaryFile: "包含无法直接阅读的程序文件"
        case .oversizedFile: "有文件体积较大"
        case .symlink: "包含指向其他文件的连接"
        case .pathEscape: "文件连接指向 Skill 文件夹之外"
        case .network: "可能访问网络"
        case .privilege: "可能请求更高的系统权限"
        case .deletion: "可能删除文件"
        case .credentialAccess: "可能读取账号或密钥"
        case .dynamicExecution: "可能启动其他程序或命令"
        }
    }

    private func riskLevel(_ severity: RiskSeverity) -> String {
        switch severity { case .info: "说明"; case .caution: "请留意"; case .high: "高风险"; case .blocked: "已阻止" }
    }

    private func riskAdvice(_ severity: RiskSeverity) -> String {
        switch severity { case .info: "只在说明文字里出现，添加时不会运行。"; case .caution: "建议使用前查看这个文件。"; case .high: "建议确认用途后再安装。"; case .blocked: "为了安全，SkillBox 已阻止添加。" }
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
    @Binding var showSyncPreview: Bool
    let addCustom: () -> Void
    let addSkill: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(eyebrow: "按需调整", title: "自定义安装", subtitle: "在这里逐个选择安装位置。常用的全部安装和全部卸载放在每个 Skill 的详情页。")
                Spacer()
                Button("添加其他应用", action: addCustom)
                if !model.snapshot.skills.isEmpty {
                    Button("检查 \(model.syncPlan?.executableActions.count ?? 0) 项安装改动") { showSyncPreview = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.syncPlan?.executableActions.isEmpty != false)
                }
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
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow { Text("我的 Skills").font(.caption.weight(.semibold)).frame(width: 210, alignment: .leading); ForEach(model.snapshot.targets) { Text($0.displayName).font(.caption2.weight(.medium)).frame(width: 72).lineLimit(2) } }
                        Divider().gridCellColumns(model.snapshot.targets.count + 1)
                        ForEach(model.snapshot.skills) { skill in GridRow { Text(skill.displayName).font(.callout.weight(.medium)).frame(width: 210, alignment: .leading); ForEach(model.snapshot.targets) { target in AssignmentButton(model: model, skill: skill, target: target).frame(width: 72) } } }
                    }
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AssignmentButton: View {
    @ObservedObject var model: AppModel; let skill: SkillRecord; let target: AgentTarget
    var desired: Bool { model.snapshot.assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true }
    var action: SyncAction? { model.syncPlan?.actions.first { $0.skillID == skill.id && $0.targetID == target.id } }
    var indirect: Bool { target.kind == .kimiCode && model.scanResult?.candidates.contains(where: { $0.fingerprint == skill.fingerprint && !$0.sourceURL.path.hasPrefix(target.path + "/") }) == true }
    var available: Bool { target.detectionStatus == .available && target.writeStatus == .writable }
    var body: some View { Button { Task { await model.toggleAssignment(skill: skill, target: target) } } label: { Image(systemName: symbol).foregroundStyle(color).frame(width: 26, height: 26).background(color.opacity(0.12), in: Circle()) }.buttonStyle(.plain).help(help) }
    var symbol: String { if action?.kind == .blocked { return "exclamationmark" }; if !available && !desired { return "nosign" }; if action?.kind == .create || action?.kind == .update { return "arrow.up" }; if indirect && !desired { return "link" }; return desired ? "checkmark" : "plus" }
    var color: Color { action?.kind == .blocked ? .orange : !available ? .secondary : indirect && !desired ? .purple : desired ? .green : .secondary }
    var help: String { if !available && !desired { return "本机没有找到可用的安装位置，点击查看说明" }; return indirect && !desired ? "Kimi Code 已能通过其他位置使用这个 Skill" : action?.summary ?? (desired ? "已选择，等待确认" : "未选择") }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { PageHeader(eyebrow: "可以反悔", title: "最近操作", subtitle: "每次安装前都会留一份备份，需要时可以恢复。"); if model.snapshot.transactions.isEmpty { ContentUnavailableView("还没有安装记录", systemImage: "clock.arrow.circlepath", description: Text("完成第一次安装后会出现在这里")) } else { ForEach(model.snapshot.transactions) { transaction in HStack { Image(systemName: transaction.status == .succeeded ? "checkmark.circle.fill" : transaction.status == .undone ? "arrow.uturn.backward.circle.fill" : "exclamationmark.circle.fill").font(.title2).foregroundStyle(transaction.status == .succeeded ? .green : .orange); VStack(alignment: .leading) { Text("改动了 \(transaction.backups.count) 个位置").font(.headline); Text("\(transactionStatus(transaction.status)) · \(transaction.createdAt.formatted())").font(.caption).foregroundStyle(.secondary) }; Spacer(); if transaction.status == .succeeded { Button("恢复到操作前") { Task { await model.undo(transaction) } } } }.padding().background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4))) } } }.padding(28) } }

    private func transactionStatus(_ status: TransactionStatus) -> String {
        switch status { case .running: "正在处理"; case .succeeded: "已完成"; case .failed: "没有完成"; case .rolledBack: "已恢复到操作前"; case .undone: "已恢复"; case .undoBlocked: "发现新改动，暂未恢复" }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View { Form { Section("数据与隐私") { LabeledContent("SkillBox 保存位置", value: model.libraryRoot.path); LabeledContent("联网", value: "只在你从 GitHub 添加或检查更新时"); LabeledContent("使用数据收集", value: "不收集") }; Section("安全承诺") { Label("查看 Skill 时不会运行里面的文件", systemImage: "checkmark.shield"); Label("已有文件不会被悄悄替换", systemImage: "hand.raised"); Label("如果其他软件改过文件，SkillBox 会先停下来提醒你", systemImage: "exclamationmark.triangle") }; Section { Button("重新查看欢迎说明") { model.showOnboarding = true }; Button("在访达中打开保存位置") { model.reveal(model.libraryRoot) } } }.formStyle(.grouped).padding(.top, 12) }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var body: some View { VStack(alignment: .leading, spacing: 22) { Label("SkillBox", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.blue); Text("先看清，再决定怎么整理").font(.largeTitle.bold()); Text("SkillBox 会查看各个 AI 应用已经安装的 Skills，找出重复、不同内容和需要留意的地方。这个过程不会改动任何文件。").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 14) { PromiseRow(title: "先看一遍，不动文件", detail: "不会创建、移动、改名或删除已有内容"); PromiseRow(title: "相同内容只整理一次", detail: "名字相同但内容不同时，会留给你选择"); PromiseRow(title: "安装前一定让你确认", detail: "每次安装都有备份，需要时可以恢复") }; Spacer(); HStack { Text("全部处理都在本机完成").font(.caption).foregroundStyle(.secondary); Spacer(); Button("开始") { model.finishOnboarding() }.buttonStyle(.borderedProminent).controlSize(.large) } }.padding(38).frame(width: 650, height: 470).interactiveDismissDisabled() }
}

private struct PromiseRow: View { let title: String; let detail: String; var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: "checkmark").foregroundStyle(.green).frame(width: 24, height: 24).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) } } } }

private struct GitHubImportView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("从 GitHub 添加 Skill").font(.title2.bold()); Text("粘贴一个公开 GitHub 仓库地址。SkillBox 会先下载到临时位置并检查内容，你确认前不会加入「我的 Skills」。").foregroundStyle(.secondary); TextField("https://github.com/owner/repo", text: $model.githubURL).textFieldStyle(.roundedBorder); HStack { Button("取消") { isPresented = false }; Spacer(); Button("查看可添加的 Skills") { isPresented = false; Task { await model.previewGitHub() } }.buttonStyle(.borderedProminent).disabled(model.githubURL.isEmpty) } }.padding(28).frame(width: 570) }
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
