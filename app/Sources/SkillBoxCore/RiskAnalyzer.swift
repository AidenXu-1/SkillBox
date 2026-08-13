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
                title: "缺少 SKILL.md",
                evidence: "目录不符合标准 Skill 结构"
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
                    title: escapes ? "软链接指向 Skill 目录之外" : "包含软链接",
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
                    title: "文件体积异常",
                    evidence: "\(size) bytes"
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
                    title: "文件具有执行权限",
                    evidence: String(format: "%o", permissions)
                ))
            }

            guard size <= 512 * 1024, let data = try? Data(contentsOf: url) else { continue }
            if data.contains(0) {
                findings.append(.init(
                    severity: .high,
                    category: .binaryFile,
                    relativePath: relative,
                    title: "包含二进制内容",
                    evidence: "静态检查无法解释此文件行为"
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
            (.network, #"\b(curl|wget)\b|https?://"#, .caution, "包含网络访问或下载模式"),
            (.privilege, #"\bsudo\b|chmod\s+[0-7]*7"#, .high, "包含提权或宽泛权限模式"),
            (.deletion, #"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f\b|FileManager\.default\.removeItem"#, .high, "包含递归删除模式"),
            (.credentialAccess, #"\.ssh|\.aws|keychain|security\s+find-|GH_TOKEN|GITHUB_TOKEN|API_KEY"#, .high, "可能访问凭据或密钥"),
            (.dynamicExecution, #"\beval\s*\(|exec\s*\(|child_process|Process\s*\("#, .high, "包含动态执行或启动进程模式"),
        ]

        for (category, pattern, scriptSeverity, title) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            findings.append(.init(
                severity: isDocumentation ? .info : scriptSeverity,
                category: category,
                relativePath: relativePath,
                title: isDocumentation ? "文档中说明了相关命令" : title,
                evidence: isDocumentation ? "仅在文本说明中发现，不代表导入时会执行" : "请在导入前人工检查该文件"
            ))
        }
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        return String(itemPath.dropFirst(min(itemPath.count, rootPath.count + 1)))
    }
}
