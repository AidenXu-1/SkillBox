# ADR-0010：采用 GitHub 无证书 DMG 发行

- **状态**：已采纳
- **日期**：2026-08-22
- **取代范围**：ADR-0002 中关于 Developer ID 与 Apple 公证的发行要求

## 背景

SkillBox 由官方 GitHub 仓库直接提供给用户下载。产品负责人明确决定当前版本不购买 Apple Developer Program，不使用 Developer ID Application 证书，也不提交 Apple 公证；用户接受首次安装或应用更新后在 macOS“隐私与安全”中点击“仍要打开”的流程。

## 决定

公开产物采用 ad-hoc 签名并启用 Hardened Runtime，以 DMG、SHA-256 和 JSON 来源清单共同发布。发布门禁必须执行全量测试、最小包内容检查、开发者本机路径与凭据扫描、图标回读、DMG 完整性验证和隔离属性模拟。安装说明必须明确没有开发者身份验证与 Apple 公证。

Developer ID 与 Apple 公证是未来可选加固，不再阻断当前上线。

## 后果

- 用户可能需要在每次新版本后重新点击“仍要打开”并输入 Mac 登录密码。
- macOS 无法用 Apple 证书确认发布者身份；官方 GitHub 账号或 Release 被攻破时，ad-hoc 签名本身不能识别恶意替包。
- 官方仓库、开源代码、固定来源快照、SHA-256、最小产物和发布清单成为必要的信任证据。
- 相机、麦克风、文件夹等隐私授权与 Gatekeeper 放行相互独立，仍由用户在系统设置中按需批准。
