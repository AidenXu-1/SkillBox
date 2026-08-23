public struct GitHubUpdateSummary: Sendable, Hashable {
    public var versionUpdateCount: Int
    public var cleanPackageCount: Int
    public var packageReviewCount: Int
    public var authenticationCount: Int
    public var permissionCount: Int
    public var rateLimitedCount: Int
    public var missingCount: Int
    public var unavailableCount: Int

    public init(statuses: [GitHubSourceStatus]) {
        versionUpdateCount = statuses.count { $0 == .updateAvailable }
        cleanPackageCount = statuses.count { $0 == .releasePackageAvailable }
        packageReviewCount = statuses.count { $0 == .packageReviewRequired }
        authenticationCount = statuses.count { $0 == .authenticationRequired }
        permissionCount = 0
        rateLimitedCount = 0
        missingCount = 0
        unavailableCount = statuses.count { $0 == .unavailable }
    }

    public init(states: [GitHubSourceState]) {
        versionUpdateCount = states.count { $0.status == .updateAvailable }
        cleanPackageCount = states.count { $0.status == .releasePackageAvailable }
        packageReviewCount = states.count { $0.status == .packageReviewRequired }
        authenticationCount = states.count { $0.lastCheckIssue == .authenticationRequired }
        permissionCount = states.count { $0.lastCheckIssue == .repositoryPermissionRequired }
        rateLimitedCount = states.count { $0.lastCheckIssue == .rateLimited }
        missingCount = states.count { $0.lastCheckIssue == .repositoryMissing }
        unavailableCount = states.count { $0.lastCheckIssue == .temporarilyUnavailable }
    }

    public var actionableCount: Int { versionUpdateCount + cleanPackageCount + packageReviewCount }

    public var statusMessage: String {
        let issueCount = authenticationCount + permissionCount + rateLimitedCount + missingCount + unavailableCount
        if versionUpdateCount == 0, cleanPackageCount == 0, packageReviewCount == 0, issueCount == 0 {
            return "所有 GitHub Skills 都是最新内容"
        }
        if versionUpdateCount == 0, cleanPackageCount > 0, packageReviewCount == 0, issueCount == 0 {
            return "检查完成：\(cleanPackageCount) 个 Skill 有更干净的安装包"
        }
        if versionUpdateCount == 0, cleanPackageCount == 0, packageReviewCount == 0,
           rateLimitedCount > 0, issueCount == rateLimitedCount
        {
            return "GitHub 暂时无法继续检查，SkillBox 会保留当前结果"
        }

        var parts: [String] = []
        if versionUpdateCount > 0 { parts.append("\(versionUpdateCount) 个新版本") }
        if cleanPackageCount > 0 { parts.append("\(cleanPackageCount) 个更干净的安装包") }
        if packageReviewCount > 0 { parts.append("\(packageReviewCount) 个 Skill 需要确认新的可安装内容") }
        if authenticationCount > 0 { parts.append("\(authenticationCount) 个私人仓库需要重新连接") }
        if permissionCount > 0 { parts.append("\(permissionCount) 个私人仓库需要允许访问") }
        if missingCount > 0 { parts.append("\(missingCount) 个仓库地址需要确认") }
        if rateLimitedCount > 0 { parts.append("GitHub 暂时无法继续检查") }
        if unavailableCount > 0 { parts.append("\(unavailableCount) 个来源暂时不可用") }
        return "检查完成：" + parts.joined(separator: "，")
    }
}
