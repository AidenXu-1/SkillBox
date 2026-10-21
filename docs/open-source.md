# 完整源码与本地构建

SkillBox 的产品实现按 [MIT License](../LICENSE) 提供，包括 macOS 界面、Skill 扫描与来源管理、文件风险检查、安装与恢复、版本比较、发现与可选 AI 接入，以及相应测试和构建脚本。产品用到的提示词和规则随对应源码提供，没有另留功能删减版。

## 源码范围

| 路径 | 内容 |
| --- | --- |
| `app/Sources/` | 全部产品源码与内置可信目录 |
| `app/Tests/` | 行为、故障保护和包检查测试 |
| `app/Scripts/` | 测试、打包、更新文件生成及验证脚本 |
| `app/Config/`、`app/Package.swift`、`app/Package.resolved` | 应用配置、依赖和版本锁定 |
| `app/Resources/`、`design/` | 构建必需的应用图标、资源和设计来源记录 |
| `docs/`、README、LICENSE | 功能边界、工程说明、验证记录与许可 |

源码归档按指定 Git 提交导出全部受版本控制文件。用户的 Skill 库、安装副本、账号资料、令牌、更新签名私钥、本机路径日志、构建缓存及临时实验不进入源码包。

## 构建和测试

使用 Apple Silicon Mac、完整 Xcode 及其 Swift 6.2 或更新工具链；目标系统最低为 macOS 15。先完成 Xcode 的首次启动设置，再在仓库根目录运行：

```sh
cd app
./Scripts/test-all.sh
./Scripts/package-app.sh release
./Scripts/verify-release-privacy.sh .build/release/SkillBox.app
```

构建依赖会按 `Package.resolved` 获取 Sparkle。外部依赖与产品图标声明见 [第三方说明](../THIRD_PARTY_NOTICES.md)。运行基本 Skill 管理功能无需付费 AI 服务；可选 AI 功能需自行配置服务和凭据，凭据留在本机钥匙串。

普通开发者可以生成本地 ad-hoc 签名 App。生成官方可验证的自动更新文件，还需要维护者本机钥匙串中的更新签名密钥；该密钥不会进入源码或安装包。克隆者可为自己的发行配置自己的公开更新身份与密钥，核心源码和本地打包不依赖维护者私钥。更多命令见 [工程说明](../app/README.md)。

## 当前版本

3.0.3（Build32）包含本轮七类修复，保留现有正常界面及资料规则。[GitHub 发行页](https://github.com/AidenXu-1/SkillBox/releases/tag/v3.0.3)提供安装包、完整源码 ZIP、更新文件与校验清单。公开标签、源码归档和来源清单绑定同一个发布提交；本机已验证构建的全部 `app/` 输入与该提交逐字节一致。开发过程的本机路径、凭据与临时记录不作为源码发布历史的一部分。
