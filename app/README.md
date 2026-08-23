# SkillBox 应用工程

## 目录

- `Package.swift`：Swift Package 入口，可直接构建应用并运行测试。
- `Sources/SkillBoxCore/`：不依赖 SwiftUI 的扫描、风险、仓库和同步核心。
- `Sources/SkillBoxApp/`：SwiftUI macOS 应用。
- `Tests/SkillBoxCoreTests/`：使用临时目录的核心自动化测试。

## 本地运行

```bash
cd app
swift run SkillBox
```

## 验证

```bash
cd app
./Scripts/test-all.sh
swift build
```

`test-all.sh` 会自动发现全部测试。由于 SwiftPM 偶尔会在 GitHub 压缩包测试与其余测试同进程运行后停留，它会先跑其余用例，再把该组拆成小批；任何一批失败都会停止。

## 生成本地测试 App

```bash
./Scripts/package-app.sh release
```

默认使用 ad-hoc 签名并启用 Hardened Runtime。Release 构建会移除调试信息与开发者本机路径，再对应用包执行最小内容检查和隐私扫描。

## 生成公开发行 DMG

```bash
./Scripts/release-distribution.sh
```

该脚本强制依次通过：全部测试、ad-hoc Hardened Runtime 签名、包内容与隐私扫描、品牌图标回读、DMG 创建与验证、隔离属性模拟、来源快照、发布清单和 SHA-256 生成。它会明确拒绝 Developer ID、notarytool 凭据和测试 GitHub 身份覆盖，最终只在 `app/.build/distribution/` 生成供你上传 GitHub 的文件，不会自动上传或安装。

当前发行策略由产品负责人明确选择：不使用 Developer ID，不提交 Apple 公证。用户第一次打开或更新后若看到“无法验证开发者”，需前往“系统设置 → 隐私与安全”点击“仍要打开”。这条路径无法让 macOS 验证发布者身份，因此只应从项目官方 GitHub 仓库下载，并对照 Release 中的 SHA-256。

SkillBox 已内置正式 GitHub 应用的公开 Client ID 和安装地址。用户只需在浏览器中登录 GitHub，选择允许 SkillBox 读取的仓库，无需自行注册或下载 GitHub App。

如果开发者需要在本机测试另一个 GitHub App，可在打包时临时覆盖这两项公开配置：

```bash
SKILLBOX_GITHUB_CLIENT_ID=... \
SKILLBOX_GITHUB_INSTALL_URL=https://github.com/apps/.../installations/new \
./Scripts/package-app.sh release
```

Client Secret、GitHub App 私钥和用户 Token 不得写入工程或应用包。用户令牌由运行中的 SkillBox 保存到 macOS 钥匙串。
