# SkillBox 使用说明降噪 v14

本轮预览验证三件事：

- Skill 列表使用中性的首字标识，不再把静态检查等级画成蓝色 `i` 或绿色勾。
- 使用说明只展示能从作者资料中高置信度确定的内容；不完整时省略区块，不拼接英文残句，也不把内部操作规则伪装成用户话术。
- 普通脚本、说明文字和低级提醒不再显示常驻「文件检查」。后台检查、危险导入阻止和安装前高风险确认继续保留。

预览：

- `skillbox-guidance-cleanup-v14-agent-team.png`：作者没有提供简洁使用示例时，只显示可靠用途。
- `skillbox-guidance-cleanup-v14-writing.png`：README 提供自然使用示例时，显示可复制话术。

确定性提取顺序建议：

1. README / SKILL.md 明确的用户说明与使用示例。
2. `agents/openai.yaml` 中简短、可直接面向用户的展示字段。
3. 完整且可读的 Frontmatter description。
4. 仍无法确定时只保留用途，避免自动补写。
