import AppKit
import SwiftUI
import SkillBoxCore

struct SkillMarkdownComparison: View {
    let before: String
    let after: String
    var beforeTitle = "当前版本"
    var afterTitle = "新版本"
    var height: CGFloat = 220
    private struct Input: Hashable { let before: String; let after: String }

    var body: some View {
        // Ranges belong to exactly these strings. Reset the child synchronously
        // when preview text changes, before AppKit can render stale ranges.
        MarkdownComparisonContent(before: before, after: after,
            beforeTitle: beforeTitle, afterTitle: afterTitle, height: height)
            .id(Input(before: before, after: after))
    }
}

private struct MarkdownComparisonContent: View {
    let before: String
    let after: String
    var beforeTitle = "当前版本"
    var afterTitle = "新版本"
    var height: CGFloat = 220
    @State private var difference: MarkdownLineDiff?
    private struct Input: Equatable { let before: String; let after: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                pane(beforeTitle, before, difference?.removed ?? [], true)
                pane(afterTitle, after, difference?.added ?? [], false)
            }
            if difference == nil {
                ProgressView("正在标记变化…").controlSize(.small)
            } else {
                Text(difference?.usesChangedRegion == true
                     ? "内容变化较多，已标记变化区段。旧版删除线 · 新版黄色背景"
                     : "旧版删除线 · 新版黄色背景（按行标记）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: Input(before: before, after: after)) {
            difference = nil
            let old = before, new = after
            let work = Task.detached(priority: .userInitiated) { MarkdownLineDiff(before: old, after: new) }
            let result = await work.value
            guard !Task.isCancelled else { return }
            difference = result
        }
    }

    private func pane(_ title: String, _ text: String, _ ranges: [NSRange], _ deletion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HighlightedMarkdownText(text: text, ranges: ranges, deletion: deletion)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.45)))
        }.frame(maxWidth: .infinity)
    }
}

private struct HighlightedMarkdownText: NSViewRepresentable {
    let text: String
    let ranges: [NSRange]
    let deletion: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        for range in ranges {
            if deletion {
                value.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                     .foregroundColor: NSColor.systemRed], range: range)
            } else {
                value.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
            }
        }
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
    }
}

struct AssignmentUpdateDetails: View {
    @ObservedObject var model: AppModel
    let proposal: AssignmentProposal
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: (String?, String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("查看本次更新").font(.title2.bold())
                    Text("\(proposal.skill.displayName) · \(proposal.target.displayName)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("文件变化") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(proposal.changes, id: \.path) { change in
                                HStack {
                                    Text(change.path).font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Text(change.kind == .added ? "新增" : change.kind == .removed ? "移除" : "修改")
                                        .foregroundStyle(change.kind == .added ? .green : change.kind == .removed ? .orange : .blue)
                                }
                            }
                            if proposal.changes.isEmpty { Text("没有可显示的文件变化").foregroundStyle(.secondary) }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("SKILL.md 更新前后") {
                        if let markdown {
                            VStack(alignment: .leading, spacing: 8) {
                                if markdown.0 == nil || markdown.1 == nil {
                                    Text("部分版本没有可读取的 SKILL.md，对应窗口留空。").font(.caption).foregroundStyle(.secondary)
                                }
                                SkillMarkdownComparison(before: markdown.0 ?? "", after: markdown.1 ?? "",
                                    beforeTitle: "当前版本 · \(proposal.target.displayName)", afterTitle: "替换后 · 我的 Skills 版本", height: 340)
                            }.padding(.vertical, 5)
                        } else { ProgressView("正在读取内容…").frame(maxWidth: .infinity, minHeight: 340) }
                    }
                }
            }
        }.padding(24).frame(width: 940, height: 650)
        .task {
            let result = await model.assignmentMarkdown(proposal)
            guard !Task.isCancelled else { return }
            markdown = result
        }
    }
}
