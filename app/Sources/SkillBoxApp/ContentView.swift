import AppKit
import SkillBoxCore
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "资产总览"
    case library = "Skill 库"
    case agents = "Agents"
    case history = "操作记录"
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
    @State private var customTargetName = "自定义 Agent"

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
                    Text("\(model.snapshot.targets.filter { $0.detectionStatus == .available }.count) 个 Agent 已识别")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(model: model, goTo: { selection = $0 })
                case .library: LibraryView(model: model, selectedSkillID: $selectedSkillID, importLocal: chooseLocalFolder, importGitHub: { showGitHub = true })
                case .agents: AgentsView(model: model, showSyncPreview: $showSyncPreview, addCustom: { showCustomTarget = true })
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationTitle(selection?.rawValue ?? "SkillBox")
            .toolbar { Button { Task { await model.scanInstalledSkills() } } label: { Label("重新盘点", systemImage: "arrow.clockwise") }.disabled(model.isBusy) }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $showGitHub) { GitHubImportView(model: model, isPresented: $showGitHub) }
        .sheet(isPresented: $showImportPreview) { ImportPreviewView(model: model, isPresented: $showImportPreview) }
        .sheet(isPresented: $showSyncPreview) { SyncPreviewView(model: model, isPresented: $showSyncPreview) }
        .sheet(isPresented: $showCustomTarget) { CustomTargetView(model: model, isPresented: $showCustomTarget, name: $customTargetName) }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("知道了") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
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
        panel.prompt = "预览 Skills"
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
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) { PageHeader(eyebrow: "本机状态", title: "你的 Skills 很清楚", subtitle: "盘点、归并和同步都从真实文件状态计算。") ; Spacer(); Button("收拢盘点结果") { model.prepareScanImport() }.disabled(model.scanResult?.candidates.isEmpty != false); Button("查看安装矩阵") { goTo(.agents) }.buttonStyle(.borderedProminent) }
            HStack(spacing: 12) {
                MetricCard(title: "中央原件", value: "\(model.snapshot.skills.count)", note: "由 SkillBox 管理", color: .blue)
                MetricCard(title: "扫描副本", value: "\(model.scanResult?.candidates.count ?? 0)", note: "扫描阶段零改动", color: .green)
                MetricCard(title: "内容冲突", value: "\(model.scanResult?.conflicts.count ?? 0)", note: "不会自动选边", color: .orange)
                MetricCard(title: "已识别 Agent", value: "\(model.snapshot.targets.filter { $0.detectionStatus == .available }.count)", note: "共 9 个内置目标", color: .green)
            }
            GroupBox("需要你决定") { VStack(alignment: .leading, spacing: 0) {
                if let conflicts = model.scanResult?.conflicts, !conflicts.isEmpty {
                    ForEach(conflicts.prefix(5)) { conflict in IssueRow(icon: "exclamationmark.triangle.fill", color: .orange, title: "\(conflict.canonicalName) 有 \(conflict.versions.count) 个版本", note: "内容不同，需要选择中央原件") }
                } else { ContentUnavailableView("暂时没有内容冲突", systemImage: "checkmark.circle", description: Text("同名不同内容的副本会出现在这里")) }
            }.padding(.vertical, 4) }
            GroupBox("已识别目录") { LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 10) { ForEach(model.snapshot.targets) { target in HStack { Image(systemName: target.detectionStatus == .available ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(target.detectionStatus == .available ? .green : .secondary); VStack(alignment: .leading) { Text(target.displayName).font(.callout.weight(.medium)); Text(target.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }; Spacer() }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)) } }.padding(.vertical, 5) }
        }.padding(28) }
    }
}

private struct IssueRow: View {
    let icon: String; let color: Color; let title: String; let note: String
    var body: some View { HStack(spacing: 12) { Image(systemName: icon).foregroundStyle(color).frame(width: 24); VStack(alignment: .leading, spacing: 3) { Text(title).font(.callout.weight(.medium)); Text(note).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 9) }
}

private struct LibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var selectedSkillID: UUID?
    let importLocal: () -> Void; let importGitHub: () -> Void
    var selected: SkillRecord? { model.snapshot.skills.first { $0.id == selectedSkillID } ?? model.snapshot.skills.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) { PageHeader(eyebrow: "中央原件库", title: "Skill 库", subtitle: "查看来源、风险与内容。原件暂不在应用内编辑。") ; Spacer(); Button("从本地导入", action: importLocal); Button("从 GitHub 导入", action: importGitHub).buttonStyle(.borderedProminent) }.padding(28)
            HSplitView {
                List(model.snapshot.skills, selection: $selectedSkillID) { skill in HStack { Image(systemName: riskIcon(skill.riskReport.highestSeverity)).foregroundStyle(riskColor(skill.riskReport.highestSeverity)); VStack(alignment: .leading) { Text(skill.displayName).font(.callout.weight(.medium)); Text(skill.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }.tag(skill.id) }.frame(minWidth: 280, idealWidth: 330)
                Group {
                    if let selected {
                        SkillDetailView(model: model, skill: selected)
                    } else {
                        ContentUnavailableView("中央仓库还是空的", systemImage: "shippingbox", description: Text("从现有目录、本地文件夹或公开 GitHub 仓库导入"))
                    }
                }
                .frame(minWidth: 480)
            }
        }
    }
    private func riskIcon(_ severity: RiskSeverity) -> String { severity >= .high ? "exclamationmark.triangle.fill" : severity == .caution ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    private func riskColor(_ severity: RiskSeverity) -> Color { severity >= .high ? .red : severity == .caution ? .orange : .green }
}

private struct SkillDetailView: View {
    @ObservedObject var model: AppModel; let skill: SkillRecord
    @State private var markdown = "正在读取…"
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        HStack { VStack(alignment: .leading, spacing: 5) { Text(skill.displayName).font(.title2.bold()); Text(skill.description).foregroundStyle(.secondary) }; Spacer(); if skill.source.kind == .github { Button("检查更新") { Task { await model.checkForUpdate(skill) } } }; Button("在 Finder 中显示") { Task { model.reveal(await model.contentURL(for: skill)) } } }
        Divider(); LabeledContent("来源", value: skill.source.displayName); LabeledContent("内容指纹", value: String(skill.fingerprint.prefix(12)) + "…"); LabeledContent("扫描文件", value: "\(skill.riskReport.scannedFileCount)")
        GroupBox("本地风险报告") { VStack(alignment: .leading, spacing: 8) { if skill.riskReport.findings.isEmpty { Label("未发现风险模式", systemImage: "checkmark.shield.fill").foregroundStyle(.green) } else { ForEach(skill.riskReport.findings.prefix(8)) { finding in VStack(alignment: .leading, spacing: 2) { Text(finding.title).font(.callout.weight(.medium)); Text("\(finding.relativePath) · \(finding.evidence)").font(.caption).foregroundStyle(.secondary) } } }; Text("静态检查提供证据与提示，不能保证 Skill 绝对安全。").font(.caption2).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
        Text("SKILL.md 预览").font(.headline); Text(markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }.padding(24) }.task(id: skill.id) { markdown = await model.skillMarkdown(skill) } }
}

private struct AgentsView: View {
    @ObservedObject var model: AppModel
    @Binding var showSyncPreview: Bool
    let addCustom: () -> Void
    var body: some View { ScrollView([.horizontal, .vertical]) { VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) { PageHeader(eyebrow: "期望安装关系", title: "Agents", subtitle: "点击只改变计划，确认同步前不会写入。") ; Spacer(); Button("添加自定义目录", action: addCustom); Button("预览 \(model.syncPlan?.executableActions.count ?? 0) 项变更") { showSyncPreview = true }.buttonStyle(.borderedProminent).disabled(model.syncPlan?.executableActions.isEmpty != false) }
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { Text("Skill").font(.caption.weight(.semibold)).frame(width: 210, alignment: .leading); ForEach(model.snapshot.targets) { Text($0.displayName).font(.caption2.weight(.medium)).frame(width: 72).lineLimit(2) } }
            Divider().gridCellColumns(model.snapshot.targets.count + 1)
            ForEach(model.snapshot.skills) { skill in GridRow { VStack(alignment: .leading) { Text(skill.displayName).font(.callout.weight(.medium)); Text(String(skill.fingerprint.prefix(8))).font(.caption2).foregroundStyle(.secondary) }.frame(width: 210, alignment: .leading); ForEach(model.snapshot.targets) { target in AssignmentButton(model: model, skill: skill, target: target).frame(width: 72) } } }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
    }.padding(28) } }
}

private struct AssignmentButton: View {
    @ObservedObject var model: AppModel; let skill: SkillRecord; let target: AgentTarget
    var desired: Bool { model.snapshot.assignments.first { $0.skillID == skill.id && $0.targetID == target.id }?.isDesired == true }
    var action: SyncAction? { model.syncPlan?.actions.first { $0.skillID == skill.id && $0.targetID == target.id } }
    var indirect: Bool { target.kind == .kimiCode && model.scanResult?.candidates.contains(where: { $0.fingerprint == skill.fingerprint && !$0.sourceURL.path.hasPrefix(target.path + "/") }) == true }
    var body: some View { Button { Task { await model.toggleAssignment(skill: skill, target: target) } } label: { Image(systemName: symbol).foregroundStyle(color).frame(width: 26, height: 26).background(color.opacity(0.12), in: Circle()) }.buttonStyle(.plain).help(help) }
    var symbol: String { if action?.kind == .blocked { return "exclamationmark" }; if action?.kind == .create || action?.kind == .update { return "arrow.up" }; if indirect && !desired { return "link" }; return desired ? "checkmark" : "plus" }
    var color: Color { action?.kind == .blocked ? .orange : indirect && !desired ? .purple : desired ? .green : .secondary }
    var help: String { indirect && !desired ? "Kimi Code 已从其他目录间接看见此 Skill" : action?.summary ?? (desired ? "已选择" : "未安装") }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { PageHeader(eyebrow: "恢复与追踪", title: "操作记录", subtitle: "每次写入都保留清单和恢复点。"); if model.snapshot.transactions.isEmpty { ContentUnavailableView("还没有同步记录", systemImage: "clock.arrow.circlepath", description: Text("完成第一次同步后会出现在这里")) } else { ForEach(model.snapshot.transactions) { transaction in HStack { Image(systemName: transaction.status == .succeeded ? "checkmark.circle.fill" : transaction.status == .undone ? "arrow.uturn.backward.circle.fill" : "exclamationmark.circle.fill").font(.title2).foregroundStyle(transaction.status == .succeeded ? .green : .orange); VStack(alignment: .leading) { Text("\(transaction.backups.count) 项文件变更").font(.headline); Text("\(transaction.status.rawValue) · \(transaction.createdAt.formatted())").font(.caption).foregroundStyle(.secondary) }; Spacer(); if transaction.status == .succeeded { Button("撤销") { Task { await model.undo(transaction) } } } }.padding().background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4))) } } }.padding(28) } }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View { Form { Section("本地管理") { LabeledContent("中央仓库", value: model.libraryRoot.path); LabeledContent("网络行为", value: "仅在主动导入或检查 GitHub 更新时访问"); LabeledContent("遥测", value: "不收集") }; Section("安全承诺") { Label("扫描不会执行 Skill 中的任何文件", systemImage: "checkmark.shield"); Label("未管理内容不会静默覆盖", systemImage: "hand.raised"); Label("外部改动会暂停同步和撤销", systemImage: "exclamationmark.triangle") }; Section { Button("重新体验首次盘点") { model.showOnboarding = true }; Button("在 Finder 中显示中央仓库") { model.reveal(model.libraryRoot) } } }.formStyle(.grouped).padding(.top, 12) }
}

private struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var body: some View { VStack(alignment: .leading, spacing: 22) { Label("SkillBox", systemImage: "shippingbox.fill").font(.headline).foregroundStyle(.blue); Text("先看清，再决定怎么整理").font(.largeTitle.bold()); Text("SkillBox 会只读盘点标准 Skills 目录，找出重复、冲突和风险。完成盘点不会自动迁移，也不会修改任何 Agent 文件。").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 14) { PromiseRow(title: "盘点阶段完全只读", detail: "不会创建、移动、重命名或删除 Agent 文件"); PromiseRow(title: "相同副本自动归并", detail: "内容不同的版本会保留给你选择"); PromiseRow(title: "每次写入都能预览和撤销", detail: "中央仓库与首次同步分开确认") }; Spacer(); HStack { Text("全部处理都在本机完成").font(.caption).foregroundStyle(.secondary); Spacer(); Button("开始") { model.finishOnboarding() }.buttonStyle(.borderedProminent).controlSize(.large) } }.padding(38).frame(width: 650, height: 470).interactiveDismissDisabled() }
}

private struct PromiseRow: View { let title: String; let detail: String; var body: some View { HStack(alignment: .top, spacing: 12) { Image(systemName: "checkmark").foregroundStyle(.green).frame(width: 24, height: 24).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) } } } }

private struct GitHubImportView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View { VStack(alignment: .leading, spacing: 18) { Text("从公开 GitHub 仓库导入").font(.title2.bold()); Text("支持 owner/repo、完整仓库地址或 /tree/分支/子目录。导入前会下载到临时目录并进行本地静态检查。").foregroundStyle(.secondary); TextField("https://github.com/owner/repo", text: $model.githubURL).textFieldStyle(.roundedBorder); HStack { Button("取消") { isPresented = false }; Spacer(); Button("预览 Skills") { isPresented = false; Task { await model.previewGitHub() } }.buttonStyle(.borderedProminent).disabled(model.githubURL.isEmpty) } }.padding(28).frame(width: 570) }
}

private struct ImportPreviewView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text(model.updatingSkillID == nil ? "导入预览" : "更新预览").font(.title2.bold()); Text(model.updatingSkillID == nil ? "选择要复制进中央仓库的 Skills。同名冲突默认不选择，并且一次只能选择一个版本。" : "确认后会归档当前原件，并用所选 GitHub 版本更新；Agent 仍需另行同步。").foregroundStyle(.secondary); List(model.pendingCandidates) { candidate in Toggle(isOn: Binding(get: { model.selectedCandidateIDs.contains(candidate.id) }, set: { model.setCandidate(candidate, selected: $0) })) { VStack(alignment: .leading) { HStack { Text(candidate.displayName).font(.headline); Spacer(); Text(candidate.riskReport.isBlocked ? "已阻断" : "\(candidate.riskReport.findings.count) 项提示").font(.caption).foregroundStyle(candidate.riskReport.isBlocked ? .red : .secondary) }; Text(candidate.description).font(.caption).foregroundStyle(.secondary); Text("\(candidate.source.displayName) · 指纹 \(String(candidate.fingerprint.prefix(12)))…").font(.caption2).foregroundStyle(.tertiary) } }.disabled(candidate.riskReport.isBlocked) }.frame(minHeight: 320); HStack { Button("取消") { model.cancelCandidatePreview(); isPresented = false }; Spacer(); Button(model.updatingSkillID == nil ? "导入所选" : "更新中央原件") { isPresented = false; Task { await model.importSelectedCandidates() } }.buttonStyle(.borderedProminent).disabled(model.selectedCandidateIDs.isEmpty) } }.padding(24).frame(width: 680, height: 520).interactiveDismissDisabled() }
}

private struct SyncPreviewView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("同步预览").font(.title2.bold()); if let plan = model.syncPlan { HStack { MetricCard(title: "执行", value: "\(plan.executableActions.count)", note: "会创建恢复点", color: .blue); MetricCard(title: "阻塞", value: "\(plan.blockedActions.count)", note: "不会执行", color: .orange) }; List(plan.actions.filter { $0.kind != .noChange }) { action in HStack { Image(systemName: action.kind == .blocked ? "exclamationmark.triangle.fill" : "arrow.right.circle.fill").foregroundStyle(action.kind == .blocked ? .orange : .blue); VStack(alignment: .leading) { Text(action.summary).font(.headline); Text(action.destinationPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.caption2).foregroundStyle(.secondary) }; Spacer(); if action.kind == .blocked, action.blockReason == .unmanagedConflict { Button(action.expectedSourceFingerprint == action.expectedDestinationFingerprint ? "授权接管" : "明确替换") { Task { await model.authorize(action: action, replacement: action.expectedSourceFingerprint != action.expectedDestinationFingerprint) } } } } }.frame(minHeight: 290); Text("执行前会再次核对目标指纹。任何状态变化都会停止写入并恢复本事务已经改动的项目。").font(.caption).foregroundStyle(.secondary) }; HStack { Button("返回调整") { isPresented = false }; Spacer(); Button("同步") { isPresented = false; Task { await model.executePlan() } }.buttonStyle(.borderedProminent).disabled(model.syncPlan?.executableActions.isEmpty != false) } }.padding(24).frame(width: 760, height: 560) }
}

private struct CustomTargetView: View {
    @ObservedObject var model: AppModel; @Binding var isPresented: Bool; @Binding var name: String
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text("添加自定义目标").font(.title2.bold()); TextField("显示名称", text: $name); Text("目录必须由系统选择器明确授权，不能选择用户主目录、磁盘根目录或 SkillBox 中央仓库。").font(.caption).foregroundStyle(.secondary); HStack { Button("取消") { isPresented = false }; Spacer(); Button("选择 Skills 目录…") { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { isPresented = false; Task { await model.addCustomTarget(name: name, url: url) } } }.buttonStyle(.borderedProminent) } }.padding(24).frame(width: 520) }
}
