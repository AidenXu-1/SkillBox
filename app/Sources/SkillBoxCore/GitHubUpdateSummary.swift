public struct GitHubUpdateSummary: Sendable, Hashable {
    public var versionUpdateCount: Int
    public var cleanPackageCount: Int
    public var unavailableCount: Int

    public init(statuses: [GitHubSourceStatus]) {
        versionUpdateCount = statuses.count { $0 == .updateAvailable }
        cleanPackageCount = statuses.count { $0 == .releasePackageAvailable }
        unavailableCount = statuses.count { $0 == .authenticationRequired || $0 == .unavailable }
    }

    public var actionableCount: Int { versionUpdateCount + cleanPackageCount }

    public var statusMessage: String {
        if versionUpdateCount == 0, cleanPackageCount == 0, unavailableCount == 0 {
            return "所有 GitHub Skills 都是最新内容"
        }
        if versionUpdateCount == 0, cleanPackageCount > 0, unavailableCount == 0 {
            return "检查完成：\(cleanPackageCount) 个 Skill 有更干净的安装包"
        }

        var parts: [String] = []
        if versionUpdateCount > 0 { parts.append("\(versionUpdateCount) 个新版本") }
        if cleanPackageCount > 0 { parts.append("\(cleanPackageCount) 个更干净的安装包") }
        if unavailableCount > 0 { parts.append("\(unavailableCount) 个来源暂时不可用") }
        return "检查完成：" + parts.joined(separator: "，")
    }
}
