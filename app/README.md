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
swift test
swift build
```

## 生成本地测试 App

```bash
./Scripts/package-app.sh release
```

默认使用 ad-hoc 签名并启用 Hardened Runtime，只用于本机测试。设置 `SKILLBOX_CODESIGN_IDENTITY` 后可以使用 Developer ID 签名；公证和 DMG 仍属于正式发行门槛。

需要测试私人 GitHub 仓库时，先注册只有 `Contents: read` 权限且已开启 Device Flow 的 GitHub App，再在打包时提供可公开的配置：

```bash
SKILLBOX_GITHUB_CLIENT_ID=... \
SKILLBOX_GITHUB_INSTALL_URL=https://github.com/apps/.../installations/new \
./Scripts/package-app.sh release
```

Client Secret、GitHub App 私钥和用户 Token 不得写入工程或应用包。用户令牌由运行中的 SkillBox 保存到 macOS 钥匙串。
