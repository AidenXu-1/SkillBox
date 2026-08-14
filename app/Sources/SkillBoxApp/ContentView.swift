import AppKit
import SkillBoxCore
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "总览"
    case library = "我的 Skills"
    case agents = "安装到哪里"
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
                case .library: LibraryView(model: model, selectedSkillID: $selectedSkillID, importLocal: chooseLocalFolder, importGitHub: { showGitHub = true })
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
                    List(model.snapshot.skills, selection: $selectedSkillID) { skill in HStack { Image(systemName: riskIcon(skill.riskReport.highestSeverity)).foregroundStyle(riskColor(skill.riskReport.highestSeverity)); VStack(alignment: .leading) { Text(skill.displayName).font(.callout.weight(.medium)); Text(skill.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1) } }.tag(skill.id) }.frame(minWidth: 280, idealWidth: 330)
                    if let selected {
                        SkillDetailView(model: model, skill: selected)
                            .frame(minWidth: 480)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func riskIcon(_ severity: RiskSeverity) -> String { severity >= .high ? "exclamationmark.triangle.fill" : severity == .caution ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    private func riskColor(_ severity: RiskSeverity) -> Color { severity >= .high ? .red : severity == .caution ? .orange : .green }
}

private struct SkillDetailView: View {
    @ObservedObject var model: AppModel; let skill: SkillRecord
    @State private var markdown = "正在读取…"
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) {
        HStack { VStack(alignment: .leading, spacing: 5) { Text(skill.displayName).font(.title2.bold()); Text(skill.description).foregroundStyle(.secondary) }; Spacer(); if skill.source.kind == .github { Button("检查更新") { Task { await model.checkForUpdate(skill) } } }; Button("在 Finder 中显示") { Task { model.reveal(await model.contentURL(for: skill)) } } }
        Divider(); LabeledContent("来自", value: skill.source.displayName); LabeledContent("包含", value: "\(skill.riskReport.scannedFileCount) 个文件")
        GroupBox("使用前检查") { VStack(alignment: .leading, spacing: 10) { if skill.riskReport.findings.isEmpty { Label("没有发现需要留意的内容", systemImage: "checkmark.shield.fill").foregroundStyle(.green) } else { ForEach(skill.riskReport.findings.prefix(8)) { finding in VStack(alignment: .leading, spacing: 3) { HStack { Text(riskTitle(finding.category)).font(.callout.weight(.medium)); Spacer(); Text(riskLevel(finding.severity)).font(.caption2.weight(.semibold)).foregroundStyle(finding.severity >= .high ? .red : finding.severity == .caution ? .orange : .secondary) }; Text("\(riskAdvice(finding.severity)) 位置：\(finding.relativePath)").font(.caption).foregroundStyle(.secondary) } } }; Text("SkillBox 只检查文件，不会运行它。检查能发现明显问题，但仍建议只添加你信任的来源。").font(.caption2).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
        DisclosureGroup("查看技术信息") { VStack(alignment: .leading, spacing: 10) { LabeledContent("内容校验码", value: String(skill.fingerprint.prefix(12)) + "…"); Text("用于发现文件是否被改过，平时不需要关心。").font(.caption).foregroundStyle(.secondary); Text("Skill 原始说明").font(.headline); Text(markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)) }.padding(.top, 8) }
    }.padding(24) }.task(id: skill.id) { markdown = await model.skillMarkdown(skill) } }

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

private struct AgentsView: View {
    @ObservedObject var model: AppModel
    @Binding var showSyncPreview: Bool
    let addCustom: () -> Void
    let addSkill: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(eyebrow: "选择使用位置", title: "安装到哪些应用", subtitle: "点一下选择或取消。只有最后点击「确认并开始」时才会改动文件。")
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
    var body: some View { Button { Task { await model.toggleAssignment(skill: skill, target: target) } } label: { Image(systemName: symbol).foregroundStyle(color).frame(width: 26, height: 26).background(color.opacity(0.12), in: Circle()) }.buttonStyle(.plain).help(help) }
    var symbol: String { if action?.kind == .blocked { return "exclamationmark" }; if action?.kind == .create || action?.kind == .update { return "arrow.up" }; if indirect && !desired { return "link" }; return desired ? "checkmark" : "plus" }
    var color: Color { action?.kind == .blocked ? .orange : indirect && !desired ? .purple : desired ? .green : .secondary }
    var help: String { indirect && !desired ? "Kimi Code 已能通过其他位置使用这个 Skill" : action?.summary ?? (desired ? "已选择，等待确认" : "未选择") }
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
