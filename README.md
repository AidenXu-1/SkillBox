# SkillBox

<img src="design/brand/skillbox-app-icon-master.png" width="96" alt="SkillBox 图标">

**把一份 Skill 安装到多个 AI 应用，在一个地方管理版本、更新和恢复。**

SkillBox 是一款原生 macOS 应用。你可以从本地开发文件夹或 GitHub 添加 Skill，先查看文件和风险提示，再选择安装到哪些 AI 应用。

[**下载 v0.2.4**](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.4) · [反馈问题](https://github.com/AidenXu-1/SkillBox/issues) · [历史版本](https://github.com/AidenXu-1/SkillBox/releases)

**适用系统：Apple Silicon Mac · macOS 15.0 及以上**

无需注册 SkillBox 账号。核心管理功能不依赖 AI，Skill 内容默认保存在本机。

<!-- 界面截图：〔待补〕。按 github-readme-draft 规则保留占位，不生成截图或下载量、Star 等数据。 -->

## 为什么用 SkillBox

如果你同时使用几个 AI 应用，或者经常修改自己写的 Skill，SkillBox 可以帮你减少反复复制文件、核对版本的工作。

| 你想做什么 | SkillBox 怎么帮你 |
| --- | --- |
| 同一份 Skill 用在多个 AI 应用里 | 选择安装位置，用同一份已确认的内容安装 |
| 开发文件夹改了，想更新正在用的版本 | 检查来源变化，预览差异后确认更新 |
| 确认一次安装会改哪些文件 | 安装、更新和卸载前查看操作预览 |
| 更新后想恢复上一版 | 在操作记录里查看可恢复的操作，恢复前重新核对文件 |
| 找到适合某项任务的 Skill | 在“发现 Skills”中输入名称、GitHub 地址或用途，查看核验后的候选 |

**管理范围是跨项目使用的全局 Skills。** 项目文件夹里的专用 Skills 不在扫描和管理范围内。发现结果取决于可访问的公开来源，不能保证找全所有 Skill。

## 下载与安装

当前发布版本：**v0.2.4（Build 14）**。

1. 在 [下载页](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.4) 获取 `SkillBox-0.2.4.dmg`。
2. 打开安装包，将 SkillBox 拖进「应用程序」。
3. 打开 SkillBox。如果 macOS 提示无法验证开发者，进入「系统设置 → 隐私与安全」。
4. 找到 SkillBox，点击「仍要打开」，由你本人按系统提示完成确认。

> 当前安装包采用 ad-hoc 签名并启用 Hardened Runtime，没有 Apple Developer ID 签名，也没有经过 Apple 公证。macOS 无法通过 Apple 证书确认开发者身份；首次安装或更新后可能需要手动放行。请只从本项目官方 GitHub 下载。

每次发布都附带安装包、`.sha256` 校验文件和 `-release.json` 来源清单，便于核对下载文件。

## 第一次使用

1. **添加来源**：在「我的 Skills」点击添加，选择本地开发文件夹，或添加 GitHub 仓库。还没有合适的 Skill 时，可以先去「发现 Skills」寻找。
2. **确认内容**：查看 `SKILL.md`、将被加入的文件和风险提示，确认后保存这一版。
3. **安装到应用**：选择要使用它的 AI 应用，检查操作预览并确认安装。

以后可以在「我的 Skills」查看来源和版本，在「安装到应用」管理安装位置，在「设置 → 操作记录与恢复」查看历史操作。

## 来源、保存版本和应用里的副本，有什么区别？

可以把它理解成：**开发原稿 → 确认要使用的一版 → 发给各个 AI 应用的副本。**

| 位置 | 用途 |
| --- | --- |
| 本地开发文件夹或 GitHub 仓库 | Skill 的来源。每份 Skill 关联一个来源 |
| SkillBox 保存的版本 | 你确认过、准备用于安装的那一版内容 |
| 各 AI 应用的 Skills 目录 | 实际供应用使用的安装副本 |

本地开发文件夹会留在原位，SkillBox 只读取你确认的内容，不移动、不改写，也不执行其中的脚本。修改开发原稿后，仍需确认更新，才会替换 SkillBox 保存的版本或应用中的安装副本。

## 更新与恢复

**检查更新**：在 Skill 详情点击「检查更新」，或使用右上角刷新。SkillBox 也会在应用打开期间检查来源变化；发现变化后由你确认是否更新。本地来源、GitHub 正式 Release 和默认分支均可跟踪。

**保护现有内容**：遇到同名但不受管理的文件夹，或安装后被其他工具改动的内容，会提示处理，不直接覆盖。更新失败后会尝试恢复旧内容；如果恢复也受阻，会保留救援资料并说明原因。

**保留上一版**：普通回退备份只保留上一份，保留 7 天。到期后在下次启动时检查清理，也可以前往「设置 → 存储与记录 → 检查并清理备份」。应用长期不开，实际清理会延后；备份维护没有每小时任务，不调用 AI。

恢复前仍会核对当前文件与备份。备份已经过期、内容缺失或文件后来被修改时，恢复可能被阻止，不能保证任何时候都能撤销。

## 支持哪些 AI 应用？

默认提供 GPT（Codex）、Claude（Claude Code）、WorkBuddy、ZCode、Kimi Code、Cursor、HanaAgent、Pi、DeepSeek Harness 和 Trae 的安装入口，显示它们在本机的实际可用状态。

你可以移出或恢复应用列，也可以添加自定义的全局 Skills 目录。老用户已有的 Gemini CLI、OpenCode 安装关系继续保留。

## 隐私与可选 AI

- Skill 内容默认保存在本机，没有云端 Skill 库，也没有遥测。
- 扫描、导入和检查不会运行 Skill 内的脚本；内容风险提示不能替代你对来源和用途的判断。
- GitHub 来源检查需要联网，私人仓库需要你授权。
- 关闭 AI 后，添加、安装、更新、卸载和恢复仍可使用。
- AI 功能使用你自己的 API Key，密钥只存入 macOS 钥匙串，费用按服务商规则计算。
- 「获取 Skill 介绍」由你主动点击后，把经过处理的相关说明文字发给已配置的 Agnes；打开应用、切换 Skill 或来源检查不会自动生成介绍。

## 问题反馈与验证范围

遇到问题请到 [GitHub Issues](https://github.com/AidenXu-1/SkillBox/issues) 反馈，尽量写清 SkillBox 版本、macOS 版本、操作步骤、预期结果和实际提示。上传截图或日志前，请移除 API Key 和私人文件内容。

v0.2.4 的更新、失败恢复和备份清理已通过自动化测试；现有安装环境中的启动与手动备份检查已实测。部分异常恢复场景尚未完成真实窗口逐步点击验证；另一台 Mac 或干净账户的首次安装与手动放行也尚未单独实测。详见 [本次发布说明](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.4)。

## 项目文档与参与开发

普通用户下载上面的 DMG 即可。需要了解实现或参与开发时，可以阅读 [工程说明](app/README.md)、[功能规格](docs/spec.md) 和 [协作规则](docs/agent-guide.md)。

<details>
<summary>从源码验证与打包</summary>

项目使用 SwiftUI 和 Swift Package Manager。以下命令从仓库根目录开始，分别运行测试并生成本地 App：

```bash
cd app
./Scripts/test-all.sh
./Scripts/package-app.sh release
```

生成公开发行候选的流程见 [工程说明](app/README.md)。测试结果以当次执行为准；发行脚本不会自动上传 GitHub 或替换本机应用。

</details>

## 许可证

本项目采用 [MIT License](LICENSE)。
