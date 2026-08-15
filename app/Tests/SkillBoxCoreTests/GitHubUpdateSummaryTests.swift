import Testing
@testable import SkillBoxCore

@Suite("GitHub update summary")
struct GitHubUpdateSummaryTests {
    @Test("Clean Release package availability is not summarized as a new version")
    func cleanPackageIsNotANewVersion() {
        let summary = GitHubUpdateSummary(statuses: [.releasePackageAvailable])
        #expect(summary.statusMessage == "检查完成：1 个 Skill 有更干净的安装包")
    }

    @Test("Real version updates and clean packages are counted separately")
    func versionUpdatesAndCleanPackagesAreSeparate() {
        let summary = GitHubUpdateSummary(statuses: [.updateAvailable, .releasePackageAvailable, .unavailable])
        #expect(summary.statusMessage == "检查完成：1 个新版本，1 个更干净的安装包，1 个来源暂时不可用")
    }

    @Test("No actionable updates stays calm")
    func noActionableUpdatesStayCalm() {
        let summary = GitHubUpdateSummary(statuses: [.current, .ignored, .checkingStopped])
        #expect(summary.statusMessage == "所有 GitHub Skills 都是最新内容")
    }
}
