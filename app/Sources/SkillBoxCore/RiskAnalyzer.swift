import Foundation

public protocol RiskAnalyzer: Sendable {
    func analyze(skillDirectory: URL) throws -> RiskReport
}

public struct StaticRiskAnalyzer: RiskAnalyzer, Sendable {
    public let maximumFileSize: Int

    public init(maximumFileSize: Int = 5 * 1024 * 1024) {
        self.maximumFileSize = maximumFileSize
    }

    public func analyze(skillDirectory: URL) throws -> RiskReport {
        let fileManager = FileManager.default
        var findings: [RiskFinding] = []
        var scannedFiles = 0
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md")

        if !fileManager.fileExists(atPath: skillFile.path) {
            findings.append(.init(
                severity: .blocked,
                category: .invalidFormat,
                relativePath: "SKILL.md",
                title: "缺少 Skill 必需的说明文件",
                evidence: "这个文件夹不是完整的 Skill"
            ))
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: skillDirectory, includingPropertiesForKeys: keys) else {
            return RiskReport(scannedFileCount: scannedFiles, findings: findings)
        }

        for case let url as URL in enumerator {
            let relative = relativePath(of: url, root: skillDirectory)
            let values = try url.resourceValues(forKeys: Set(keys))

            if values.isSymbolicLink == true {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                let resolved = url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
                let root = skillDirectory.standardizedFileURL
                let escapes = resolved.path != root.path && !resolved.path.hasPrefix(root.path + "/")
                findings.append(.init(
                    severity: escapes ? .blocked : .caution,
                    category: escapes ? .pathEscape : .symlink,
                    relativePath: relative,
                    title: escapes ? "文件连接指向 Skill 文件夹之外" : "包含指向其他文件的连接",
                    evidence: destination
                ))
                continue
            }
            guard values.isRegularFile == true else { continue }
            scannedFiles += 1

            let size = values.fileSize ?? 0
            if size > maximumFileSize {
                findings.append(.init(
                    severity: .high,
                    category: .oversizedFile,
                    relativePath: relative,
                    title: "有文件体积较大",
                    evidence: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                ))
            }

            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let executable = permissions & 0o111 != 0
            if executable {
                findings.append(.init(
                    severity: .caution,
                    category: .executableFile,
                    relativePath: relative,
                    title: "包含可以直接运行的文件",
                    evidence: String(format: "%o", permissions)
                ))
            }

            guard size <= 512 * 1024, let data = try? Data(contentsOf: url) else { continue }
            if data.contains(0) {
                findings.append(.init(
                    severity: .high,
                    category: .binaryFile,
                    relativePath: relative,
                    title: "包含无法直接阅读的程序文件",
                    evidence: "SkillBox 无法仅通过文字判断它的用途"
                ))
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let isDocumentation = ["md", "markdown", "txt", "rst"].contains(url.pathExtension.lowercased())
            inspectText(text, relativePath: relative, isDocumentation: isDocumentation, findings: &findings)
        }

        return RiskReport(scannedFileCount: scannedFiles, findings: findings)
    }

    private func inspectText(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        findings: inout [RiskFinding]
    ) {
        let patterns: [(RiskCategory, String, RiskSeverity, String)] = [
            (.network, #"\b(curl|wget)\b|https?://"#, .caution, "可能访问网络或下载文件"),
            (.privilege, #"\bsudo\b|chmod\s+[0-7]*7"#, .high, "可能请求更高的系统权限"),
            (.dynamicExecution, #"\beval\s*\(|exec\s*\(|child_process|Process\s*\("#, .high, "可能启动其他程序或命令"),
        ]

        for (category, pattern, scriptSeverity, title) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            findings.append(.init(
                severity: isDocumentation ? .info : scriptSeverity,
                category: category,
                relativePath: relativePath,
                title: isDocumentation ? "说明文字中提到了相关命令" : title,
                evidence: isDocumentation ? "只在说明文字里发现，添加时不会运行" : "建议在添加前查看这个文件"
            ))
        }
        inspectCredentialAccess(text, relativePath: relativePath, isDocumentation: isDocumentation, findings: &findings)
        inspectDeletion(text, relativePath: relativePath, isDocumentation: isDocumentation, findings: &findings)
    }

    private func inspectCredentialAccess(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        findings: inout [RiskFinding]
    ) {
        let pattern = #"\.ssh|\.aws|keychain|security\s+find-|GH_TOKEN|GITHUB_TOKEN|API_KEY|github\.token"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        else { return }

        if isGitHubActionsWorkflow(relativePath), containsOnlyGitHubActionsTemporaryTokenReferences(text) {
            findings.append(.init(
                severity: .info,
                category: .credentialAccess,
                relativePath: relativePath,
                title: "GitHub 自动化使用临时仓库令牌",
                evidence: "GitHub 自动化流程使用了任务期间生成的临时仓库令牌。该文件不会在本机安装 Skill 时自动运行"
            ))
            return
        }

        findings.append(.init(
            severity: isDocumentation ? .info : .high,
            category: .credentialAccess,
            relativePath: relativePath,
            title: isDocumentation ? "说明文字中提到了相关命令" : "可能读取账号信息或密钥",
            evidence: isDocumentation ? "只在说明文字里发现，添加时不会运行" : "建议在添加前查看这个文件"
        ))
    }

    private func isGitHubActionsWorkflow(_ relativePath: String) -> Bool {
        let path = relativePath.lowercased()
        return path.hasPrefix(".github/workflows/") && (path.hasSuffix(".yml") || path.hasSuffix(".yaml"))
    }

    private func containsOnlyGitHubActionsTemporaryTokenReferences(_ text: String) -> Bool {
        let broadSensitivePattern = #"\.ssh|\.aws|keychain|security\s+find-|API_KEY"#
        if let regex = try? NSRegularExpression(pattern: broadSensitivePattern, options: [.caseInsensitive]),
           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        {
            return false
        }

        let safeAssignment = #"^\s*(?:GH_TOKEN|GITHUB_TOKEN|[A-Za-z0-9_-]*token[A-Za-z0-9_-]*)\s*:\s*\$\{\{\s*(?:github\.token|secrets\.GITHUB_TOKEN)\s*\}\}\s*$"#
        guard let assignmentRegex = try? NSRegularExpression(pattern: safeAssignment, options: [.caseInsensitive])
        else { return false }

        let sensitiveLines = text.split(whereSeparator: \Character.isNewline).map(String.init).filter { line in
            let lowercased = line.lowercased()
            return lowercased.contains("gh_token") || lowercased.contains("github_token") || lowercased.contains("github.token")
        }
        guard !sensitiveLines.isEmpty else { return false }
        return sensitiveLines.allSatisfy { line in
            let range = NSRange(line.startIndex..., in: line)
            return assignmentRegex.firstMatch(in: line, range: range) != nil
        }
    }

    private func inspectDeletion(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        findings: inout [RiskFinding]
    ) {
        let deletionPattern = #"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b|FileManager\.default\.removeItem"#
        guard let deletionRegex = try? NSRegularExpression(pattern: deletionPattern, options: [.caseInsensitive]) else { return }
        guard let matchedLine = text.split(whereSeparator: \Character.isNewline).map(String.init).first(where: { line in
            deletionRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }) else { return }
        let command = matchedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDocumentation {
            findings.append(.init(
                severity: .info,
                category: .deletion,
                relativePath: relativePath,
                title: "说明文字中提到了相关命令",
                evidence: "只在说明文字里发现，添加时不会运行"
            ))
            return
        }

        let broadPathPattern = #"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+(?:--\s+)?[\"']?(?:/|~|\$HOME|\$\{HOME\})"#
        let removesBroadPath = (try? NSRegularExpression(pattern: broadPathPattern, options: [.caseInsensitive]))?.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
        ) != nil
        let usesFileManager = command.localizedCaseInsensitiveContains("FileManager.default.removeItem")
        let severity: RiskSeverity = removesBroadPath || usesFileManager ? .high : .caution
        findings.append(.init(
            severity: severity,
            category: .deletion,
            relativePath: relativePath,
            title: severity == .high ? "可能删除宽泛位置的内容" : "包含清理文件的命令",
            evidence: command
        ))
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return String(itemPath.dropFirst(min(itemPath.count, rootPath.count + 1)))
    }
}
