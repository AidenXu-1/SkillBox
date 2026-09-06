# ADR-0012：Agent 品牌名称、适配器身份与目标路径分离

- **状态**：已采纳
- **日期**：2026-09-01

## 背景

OpenAI 将 Codex App 合并进 ChatGPT 桌面应用，但 Codex 仍作为其中一个正式视图存在；本机 App 的显示名称、Bundle ID、历史数据身份和 Skills 目录也没有同步使用同一个名称。其他 Agent 同样可能改品牌、改官网名称或迁移配置目录。

如果 SkillBox 用界面名称同时充当适配器 ID 和目录规则，一次品牌改名就可能被误判为新增应用，导致旧 Assignment、ManagedInstallation 与真实副本失去关联。当前 Kimi Code 还存在把旧假定路径 `~/.kimi/skills` 当成默认目录的问题。

## 决定

1. 每个内置 Agent 分开保存稳定适配器 ID、当前界面名称、官方图标、目标目录解析规则和固定目标 UUID。
2. GPT 在界面使用 ChatGPT 官方图标与名称「GPT」，底层继续使用 `codex` 适配器、原固定 UUID 和 `~/.codex/skills`。
3. Claude 只把界面名称从「Claude Code」收口为「Claude」，底层 `claudeCode` 身份与 `~/.claude/skills` 不变。
4. Kimi Code 的新目标改为 `$KIMI_CODE_HOME/skills`，默认 `~/.kimi-code/skills`。旧 `~/.kimi/skills` 只进入显式迁移检查，不自动搬动文件。
5. 内置应用可以从安装表隐藏并恢复。隐藏状态、目录是否可用、是否存在受管理副本是三个独立状态。
6. 自定义应用由用户填写名称并选择已经存在的全局 Skills 文件夹。移除任何目标都不得顺带删除应用或目录；存在受管理副本时必须先让用户选择卸载或停止管理。

## 核对依据

- [OpenAI：Codex App 合并进 ChatGPT 桌面应用](https://openai.com/index/chatgpt-for-your-most-ambitious-work/)
- [Claude Code：用户级 Skills 目录](https://code.claude.com/docs/en/skills)
- [Cursor：Skills 目录](https://prod.cursor.com/help/customization/skills)
- [ZCode：Skill 文档](https://zcode.z.ai/en/docs/skill)
- [Kimi Code：Skill Locations](https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/customization/skills.md)
- [Pi：Skills Locations](https://pi.dev/docs/latest/skills)
- [DeepSeek Harness：Local discovery priority](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/skills.md)
- [Trae：全局技能目录](https://docs.trae.cn/ide_skills)

## 理由

用户看到的是产品名称，SkillBox 写入的是具体目录，历史安装关系依赖稳定身份。三者拆开后，品牌变化只影响展示，目录变化可以走可预览迁移，旧数据不会因改名失联。

## 后果

- `AgentKind` 或等价适配器键不得直接由显示名称生成。
- 目标检测、安装预览和执行始终使用解析后的专属目录，不使用 `.agents` 或其他 Agent 目录推断“已经可用”。
- 目标目录规则变化需要独立迁移测试，覆盖旧目标、旧分配、旧安装所有权和用户排序。
- Gemini CLI、OpenCode 等老用户已有目标无损保留，但不进入新用户默认安装表。

## 回退

可以恢复旧界面名称或新用户默认列表，但不得回退稳定适配器 ID、固定目标 UUID与已保存目标路径。Kimi Code 迁移未获用户确认时继续保留旧记录为只读历史目标，不把它伪装成当前官方目录。
