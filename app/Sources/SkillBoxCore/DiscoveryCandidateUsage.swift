import Foundation

/// App-owned onboarding instructions. These describe SkillBox's real workflow,
/// rather than inventing steps that a downloaded Skill promises to perform.
public enum DiscoveryCandidateUsage {
    public static func guide(for candidate: DiscoveryCandidate) -> SkillUsageGuide {
        let name = SkillMetadataParser.canonicalize(candidate.name)
        return .init(
            purpose: candidate.userFacingSummary ?? "作者暂未提供可核对的用途说明，请先打开作者说明。",
            useWhen: "先核对上面的作者说明是否符合你的任务；具体输入要求以作者说明为准。",
            starterPrompt: "请使用 \(name) 帮我完成【写下你的具体任务】。开始前，请告诉我需要提供哪些材料。",
            experienceSteps: [
                "点击“加入我的 Skills”，查看下载内容和检查结果，再确认加入。",
                "在“我的 Skills”中，将它安装到你使用的 AI 应用。",
                "打开该 AI 应用，粘贴下面的提示词并填写任务；按 Skill 的要求提供材料。",
            ],
            origin: nil,
            sourceDocuments: candidate.evidence.skillContentVerified ? ["SKILL.md"] : nil
        )
    }
}
