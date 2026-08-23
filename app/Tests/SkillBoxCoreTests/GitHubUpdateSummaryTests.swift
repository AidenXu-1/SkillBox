import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub update summary")
struct GitHubUpdateSummaryTests {
    @Test("Rate limiting stays calm and preserves the current result")
    func rateLimitHasCalmMessage() {
        let state = GitHubSourceState(
            skillID: UUID(),
            repositoryFullName: "example/public-skill",
            repositoryIsPrivate: false,
            currentTreeSHA: "tree",
            lastCheckIssue: .rateLimited,
            retryAfter: Date(timeIntervalSince1970: 2_000),
            status: .current
        )

        let summary = GitHubUpdateSummary(states: [state])

        #expect(summary.statusMessage == "GitHub 暂时无法继续检查，SkillBox 会保留当前结果")
    }

    @Test("Private login and repository permission are reported as different actions")
    func privateAccessActionsAreSeparated() {
        let login = GitHubSourceState(
            skillID: UUID(),
            repositoryFullName: "example/private-one",
            repositoryIsPrivate: true,
            currentTreeSHA: "tree",
            lastCheckIssue: .authenticationRequired,
            status: .current
        )
        let permission = GitHubSourceState(
            skillID: UUID(),
            repositoryFullName: "example/private-two",
            repositoryIsPrivate: true,
            currentTreeSHA: "tree",
            lastCheckIssue: .repositoryPermissionRequired,
            status: .current
        )

        let summary = GitHubUpdateSummary(states: [login, permission])

        #expect(summary.statusMessage == "检查完成：1 个私人仓库需要重新连接，1 个私人仓库需要允许访问")
    }

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

    @Test("新的可安装内容不会被误报成新版本")
    func packageReviewIsItsOwnAction() {
        let summary = GitHubUpdateSummary(statuses: [.packageReviewRequired])
        #expect(summary.statusMessage == "检查完成：1 个 Skill 需要确认新的可安装内容")
    }
}
