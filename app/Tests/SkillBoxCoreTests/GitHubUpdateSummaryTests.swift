import Foundation
import Testing
@testable import SkillBoxCore

@Suite("GitHub update summary")
struct GitHubUpdateSummaryTests {
    @Test("Rate limiting explicitly says public repositories do not need private access")
    func rateLimitHasClearPublicRepositoryMessage() {
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

        #expect(summary.statusMessage == "GitHub 暂时限制了查询。公开仓库无需连接私人仓库，请稍后再试")
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
}
