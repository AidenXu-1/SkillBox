import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var updater: ApplicationUpdater
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 22) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().frame(width: 82, height: 82)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SkillBox").font(.system(size: 33, weight: .bold))
                        Text("让每个应用，都用上你的 Skills。")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Text("版本 \(updater.versionLabel)").foregroundStyle(.secondary)
                            Button(didCopy ? "已复制" : "复制版本信息") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                didCopy = pasteboard.setString("SkillBox \(updater.versionLabel)", forType: .string)
                            }
                            .buttonStyle(.plain).foregroundStyle(.blue)
                            .task(id: didCopy) {
                                guard didCopy else { return }
                                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                                didCopy = false
                            }
                        }.font(.caption)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 12) {
                    Text("软件更新").font(.headline)
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: statusSymbol)
                                .font(.title3).foregroundStyle(updater.phase == .failed ? .orange : .blue)
                                .frame(width: 36, height: 36)
                                .background(.blue.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 6) {
                                Text(updater.title).font(.callout.weight(.semibold))
                                Text(updater.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if [.checking, .downloading, .extracting].contains(updater.phase) {
                                    if updater.phase == .checking { ProgressView().controlSize(.small) }
                                    else { ProgressView(value: updater.progress).progressViewStyle(.linear) }
                                }
                                if updater.phase == .ready && model.isBusy {
                                    Text("请等待当前操作完成后再重启。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let date = updater.lastChecked, [.latest, .idle].contains(updater.phase) {
                                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Button(updater.actionTitle) { updater.performPrimaryAction() }
                                .buttonStyle(SkillBoxHoverButtonStyle(kind: .primary))
                                .disabled(!updater.actionEnabled || ([.ready, .installing].contains(updater.phase) && model.isBusy))
                            if updater.canCancel {
                                Button("取消") { updater.cancel() }
                                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            }
                            if updater.canDeferUpdate {
                                Button("稍后更新") { updater.deferUpdate() }
                                    .buttonStyle(SkillBoxHoverButtonStyle(kind: .secondary))
                            }
                        }.padding(20)
                        if !updater.availableVersion.isEmpty && [.available, .ready].contains(updater.phase) {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                if !updater.releaseNotes.isEmpty {
                                    Text(updater.releaseNotes).font(.caption).textSelection(.enabled)
                                }
                                Link("查看完整更新日志 ↗", destination: ApplicationUpdater.releases).font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(.blue.opacity(0.035))
                        }
                        Divider()
                        updateToggle("自动检查更新", detail: "发现新版本时提醒你。", value: Binding(
                            get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }
                        ), disabled: !updater.isConfigured)
                        Divider()
                        updateToggle("自动下载更新", detail: "在后台准备好更新，安装前由你决定何时重启。", value: Binding(
                            get: { updater.automaticallyDownloads }, set: { updater.setAutomaticallyDownloads($0) }
                        ), disabled: !updater.isConfigured || !updater.automaticallyChecks)
                    }.aboutCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("项目与作者").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        projectLink("GitHub 仓库", subtitle: "源码、文档与项目动态", icon: "chevron.left.forwardslash.chevron.right", url: ApplicationUpdater.repository)
                        projectLink("作者主页", subtitle: "兆基 · AidenXu-1", icon: "person", url: ApplicationUpdater.author)
                        projectLink("更新日志", subtitle: "了解每个版本的变化", icon: "doc.text", url: ApplicationUpdater.releases)
                        projectLink("问题反馈", subtitle: "报告问题或提出建议", icon: "bubble.left", url: ApplicationUpdater.issues)
                    }
                }
                HStack(spacing: 12) {
                    Text("为 macOS 打造")
                    Link("开源许可 ↗", destination: ApplicationUpdater.license)
                    Spacer()
                    Text("© 2026 SkillBox contributors")
                }.font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 42)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var statusSymbol: String {
        switch updater.phase {
        case .failed: "exclamationmark.circle"
        case .latest: "checkmark.circle"
        case .ready: "arrow.down.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func updateToggle(_ title: String, detail: String, value: Binding<Bool>, disabled: Bool) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch)
                .disabled(disabled).accessibilityLabel(title)
        }.padding(20)
    }

    private func projectLink(_ title: String, subtitle: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Group {
                    if url == ApplicationUpdater.repository { GitHubSourceMark().frame(width: 22, height: 22) }
                    else { Image(systemName: icon).font(.title3) }
                }.frame(width: 24).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).aboutCard()
        }.buttonStyle(.plain)
    }
}

private extension View {
    func aboutCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }
}
