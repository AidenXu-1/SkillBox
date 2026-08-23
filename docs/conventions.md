# 编码约定

> 本文件只管「代码长什么样」:命名、风格、目录、测试。
> 「行为规矩」(小步提交、加依赖先问、完成=已验证等)在 [agent-guide.md](agent-guide.md),这里不重复。
> 多数条目要等技术栈定了(M1)才能填实。

## 现在就成立的

- 与现有代码风格对齐:新代码读起来应像周围的代码。
- 命名保持一致风格(具体规范选型后定)。

## 已确认技术约定

- Swift 6、SwiftUI、macOS 15+、arm64。
- 使用 SwiftFormat 与 SwiftLint 前先审查并固定配置；Kickoff 时随工程一起提交。
- 类型使用 `UpperCamelCase`，属性、函数和测试使用 `lowerCamelCase`；协议用职责名称，不强制添加 `Protocol` 后缀。
- 文件系统和网络错误必须转换为可展示、可记录的领域错误，不把底层路径或调试文本直接当用户文案。
- 使用 `OSLog` 分类记录诊断信息；不得记录 Skill 正文、凭据或用户主目录之外的敏感内容。

## app/ 内部布局(Kickoff 初始化 app/ 时必须填实)

> 技术栈定了之后,先把下面四个槽位定下来再写代码。
> 定下后,所有代码和测试按此归位,AI 不要随手另起目录乱放。

- **源码放哪**：`app/SkillBox/` 放应用入口与 SwiftUI；`app/Packages/SkillBoxCore/` 放可独立测试的纯 Swift 核心。
- **测试放哪**：应用测试随 Xcode target 放置；核心测试放 `app/Packages/SkillBoxCore/Tests/`。
- **配置 / 环境变量放哪**：构建配置放 `app/Config/`；若未来启用签名、公证，凭据只存在开发者钥匙串或 CI Secrets，不进仓库。当前 GitHub 发行使用 ad-hoc 签名且不公证。
- **怎么算“验证过了”**：核心 `swift test`、应用 `xcodebuild test`、静态检查与对应功能的前台体验验收均通过。

> 注:这里管的是**自动化测试(代码)**。审核层出具的**把关报告**不在 `app/`,见 `docs/collaboration/部门/<审核部门>/把关报告/`(若已启用多会话协作层)。

---
关联:[行为规矩见 agent-guide.md](agent-guide.md) ·[决策记录](decisions/)
