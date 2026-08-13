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
