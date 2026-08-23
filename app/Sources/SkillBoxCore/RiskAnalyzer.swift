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
        let skillInstructions = readableUTF8Text(at: skillFile, maximumBytes: maximumFileSize) ?? ""

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

            guard size <= maximumFileSize, let data = try? Data(contentsOf: url) else { continue }
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
            inspectText(
                text,
                relativePath: relative,
                isDocumentation: isDocumentation,
                isAgentInstruction: isAgentInstruction(
                    relativePath: relative,
                    isDocumentation: isDocumentation,
                    skillInstructions: skillInstructions
                ),
                findings: &findings
            )
        }

        return RiskReport(scannedFileCount: scannedFiles, findings: findings)
    }

    private func inspectText(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool,
        findings: inout [RiskFinding]
    ) {
        let patterns: [(RiskCategory, String, RiskSeverity, String)] = [
            (.network, #"\b(curl|wget|nc|ncat|netcat|socat|scp|sftp|rsync|ftp)\b|https?://"#, .caution, "可能访问网络或下载文件"),
            (.privilege, #"\bsudo\b|chmod\s+[0-7]*7"#, .high, "可能请求更高的系统权限"),
            (.dynamicExecution, #"\beval\s*\(|exec\s*\(|child_process|Process\s*\("#, .high, "可能启动其他程序或命令"),
        ]

        for (category, pattern, scriptSeverity, title) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            let severity = effectiveSeverity(
                scriptSeverity,
                relativePath: relativePath,
                isDocumentation: isDocumentation,
                isAgentInstruction: isAgentInstruction
            )
            findings.append(.init(
                severity: severity,
                category: category,
                relativePath: relativePath,
                title: severity == .info ? "说明文字中提到了相关命令" : title,
                evidence: riskEvidence(severity: severity, isDocumentation: isDocumentation)
            ))
        }
        inspectCredentialAccess(text, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction, findings: &findings)
        inspectSensitiveDataFlow(text, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction, findings: &findings)
        inspectEncodedExecution(text, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction, findings: &findings)
        inspectSystemModification(text, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction, findings: &findings)
        inspectDeletion(text, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction, findings: &findings)
    }

    private func inspectSystemModification(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool,
        findings: inout [RiskFinding]
    ) {
        let locationPattern = #"(?:/System/|/Library/(?:LaunchDaemons|PrivilegedHelperTools)|(?:\$HOME|\$\{HOME\}|~)/Library/LaunchAgents|launchctl\s+(?:load|bootstrap))"#
        let mutationPattern = #"(?:\bcp\b|\bmv\b|\binstall\b|mkdir\s+-p|write\s*\(|createDirectory|launchctl\s+(?:load|bootstrap))"#
        guard let location = try? NSRegularExpression(pattern: locationPattern, options: [.caseInsensitive]),
              let mutation = try? NSRegularExpression(pattern: mutationPattern, options: [.caseInsensitive]),
              location.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              mutation.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        else { return }
        let severity = effectiveSeverity(.high, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction)
        findings.append(.init(
            severity: severity,
            category: .privilege,
            relativePath: relativePath,
            title: severity == .info ? "说明文字提到系统管理位置" : "可能修改开机启动或系统管理位置",
            evidence: severity == .info
                ? "只在普通说明文字里发现"
                : riskEvidence(severity: severity, isDocumentation: isDocumentation)
        ))
    }

    private func inspectEncodedExecution(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool,
        findings: inout [RiskFinding]
    ) {
        let decoderPattern = #"(?:base64\.b64decode|\batob\s*\(|Data\s*\(\s*base64Encoded:|\bbase64\b[^\r\n]*(?:-d|--decode))"#
        let executionPattern = #"(?:subprocess\.(?:run|Popen|call)|shell\s*=\s*True|child_process|Process\s*\()"#
        guard let decoder = try? NSRegularExpression(pattern: decoderPattern, options: [.caseInsensitive]),
              let execution = try? NSRegularExpression(pattern: executionPattern, options: [.caseInsensitive]),
              decoder.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              execution.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        else { return }
        let severity = effectiveSeverity(.high, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction)
        findings.append(.init(
            severity: severity,
            category: .dynamicExecution,
            relativePath: relativePath,
            title: severity == .info ? "说明文字提到解码后执行" : "可能解码并运行隐藏指令",
            evidence: severity == .info
                ? "只在普通说明文字里发现"
                : riskEvidence(severity: severity, isDocumentation: isDocumentation)
        ))
    }

    private func inspectSensitiveDataFlow(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool,
        findings: inout [RiskFinding]
    ) {
        let sourcePattern = #"(?:Library/Application Support/(?:Google/Chrome|Chromium|Firefox)|Library/Safari|Login Data|Cookies(?:\.binarycookies)?|Web Data|Local State|\.ssh|\.aws|keychain|security\s+find-)"#
        let sinkPattern = #"(?:requests\.(?:post|put)|axios\.(?:post|put)|fetch\s*\(\s*[\"']https?://|URLSession\.(?:shared\.)?(?:uploadTask|dataTask)|\bcurl\b[^\r\n]*(?:-d|--data|--upload-file|-F)|\b(?:nc|ncat|netcat|socat|scp|sftp|rsync|ftp)\b)"#
        guard let sourceRegex = try? NSRegularExpression(pattern: sourcePattern, options: [.caseInsensitive]),
              let sinkRegex = try? NSRegularExpression(pattern: sinkPattern, options: [.caseInsensitive]),
              sourceRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              sinkRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        else { return }

        let sourceLine = text.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first {
                sourceRegex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "发现浏览器或账号数据读取"
        let severity = effectiveSeverity(.high, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction)
        findings.append(.init(
            severity: severity,
            category: .credentialAccess,
            relativePath: relativePath,
            title: severity == .info ? "说明文字提到敏感数据传输" : "可能读取并发送浏览器或账号数据",
            evidence: severity == .info
                ? "只在普通说明文字里发现"
                : (isDocumentation ? "Skill 的主说明要求 Agent 读取并向外发送敏感数据" : String(sourceLine.prefix(240)))
        ))
    }

    private func inspectCredentialAccess(
        _ text: String,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool,
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

        let severity = effectiveSeverity(.high, relativePath: relativePath, isDocumentation: isDocumentation, isAgentInstruction: isAgentInstruction)
        findings.append(.init(
            severity: severity,
            category: .credentialAccess,
            relativePath: relativePath,
            title: severity == .info ? "说明文字中提到了相关命令" : "可能读取账号信息或密钥",
            evidence: riskEvidence(severity: severity, isDocumentation: isDocumentation)
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
        isAgentInstruction: Bool,
        findings: inout [RiskFinding]
    ) {
        let deletionPattern = #"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b|FileManager\.default\.removeItem"#
        guard let deletionRegex = try? NSRegularExpression(pattern: deletionPattern, options: [.caseInsensitive]) else { return }
        guard let matchedLine = text.split(whereSeparator: \Character.isNewline).map(String.init).first(where: { line in
            deletionRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }) else { return }
        let command = matchedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let broadPathPattern = #"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\s+(?:--\s+)?[\"']?(?:/|~|\$HOME|\$\{HOME\})"#
        let removesBroadPath = (try? NSRegularExpression(pattern: broadPathPattern, options: [.caseInsensitive]))?.firstMatch(
            in: command,
            range: NSRange(command.startIndex..., in: command)
        ) != nil
        let usesFileManager = command.localizedCaseInsensitiveContains("FileManager.default.removeItem")
        let severity = effectiveSeverity(
            removesBroadPath || usesFileManager ? .high : .caution,
            relativePath: relativePath,
            isDocumentation: isDocumentation,
            isAgentInstruction: isAgentInstruction
        )
        if severity == .info {
            findings.append(.init(
                severity: .info,
                category: .deletion,
                relativePath: relativePath,
                title: "说明文字中提到了相关命令",
                evidence: "只在说明文字里发现，添加时不会运行"
            ))
            return
        }
        findings.append(.init(
            severity: severity,
            category: .deletion,
            relativePath: relativePath,
            title: severity == .high ? "可能删除宽泛位置的内容" : "包含清理文件的命令",
            evidence: command
        ))
    }

    private func effectiveSeverity(
        _ executableSeverity: RiskSeverity,
        relativePath: String,
        isDocumentation: Bool,
        isAgentInstruction: Bool
    ) -> RiskSeverity {
        guard isDocumentation else { return executableSeverity }
        return isAgentInstruction && executableSeverity >= .high ? executableSeverity : .info
    }

    private func riskEvidence(severity: RiskSeverity, isDocumentation: Bool) -> String {
        if severity == .info { return "只在普通说明文字里发现" }
        if isDocumentation { return "Skill 指令要求 Agent 执行此行为" }
        return "建议在添加前查看这个文件"
    }

    private func readableUTF8Text(at url: URL, maximumBytes: Int) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func isAgentInstruction(
        relativePath: String,
        isDocumentation: Bool,
        skillInstructions: String
    ) -> Bool {
        guard isDocumentation else { return false }
        if relativePath.caseInsensitiveCompare("SKILL.md") == .orderedSame { return true }

        let normalizedInstructions = skillInstructions.lowercased().replacingOccurrences(of: "\\", with: "/")
        let normalizedPath = relativePath.lowercased().replacingOccurrences(of: "\\", with: "/")
        if normalizedInstructions.contains(normalizedPath) { return true }

        let components = normalizedPath.split(separator: "/")
        guard components.count > 1 else { return false }
        for index in 1..<components.count {
            let directory = components.prefix(index).joined(separator: "/") + "/"
            if normalizedInstructions.contains(directory) { return true }
        }
        return false
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return String(itemPath.dropFirst(min(itemPath.count, rootPath.count + 1)))
    }
}
