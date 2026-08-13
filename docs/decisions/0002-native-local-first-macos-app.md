# ADR-0002：采用原生、本地优先的 macOS 架构

- **状态**：已采纳
- **日期**：2026-08-14

## 背景

SkillBox 要频繁扫描隐藏目录、监测本地文件、提供 Finder 与系统权限体验，并以可预测和低资源占用建立信任。

## 候选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| SwiftUI 原生应用 | 系统体验自然、体积轻、本地文件能力完整 | 首版仅覆盖 macOS |
| Tauri | 未来跨平台更顺 | 多语言边界和打包复杂度更高 |
| Electron | Web UI 生态成熟 | 体积和资源成本高，文件权限边界更复杂 |

## 决定

使用 Swift 6 与 SwiftUI，最低 macOS 15，首发 arm64。中央数据使用普通文件和版本化 JSON，不使用账号、遥测、云端或数据库。

公开版通过 Developer ID、Hardened Runtime、公证 DMG 和 GitHub Releases 发行。为实现标准目录自动扫描，不启用 App Store Sandbox；代码必须把可访问路径限制在 Spec 声明范围。

## 后果

- 获得原生交互、文件监测和较小安装包。
- Windows、Linux 与 Mac App Store 不在 v1 范围。
- 无沙盒意味着路径校验、最小网络行为、开源透明度和安全测试必须成为发布门槛。
