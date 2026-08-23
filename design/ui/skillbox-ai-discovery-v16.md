# SkillBox 情境化 AI 与“发现 Skills”v16

## 本轮结论

- AI 在服务层统一，在界面层按任务出现，不把 SkillBox 变成通用聊天产品。
- 左侧增加一级“发现 Skills”，与“我的 Skills”并列；这是用户反复寻找新能力的长期入口。
- 总览提供“描述你想解决的问题”快捷输入，提交后进入同一个发现流程，不生成聊天历史、对话气泡或长期记忆。
- “添加 Skill”继续处理用户已经知道来源的本地目录和 GitHub 地址。
- GitHub Star 作为仓库级知名度信号，明确标为“所在仓库 Stars”，不与质量、安全或适配度合成总分。
- 发现详情与“我的 Skills”共享用户说明结构：“能帮你什么、适合这些情况、可以这样告诉 AI、使用时会发生什么”。发现详情额外解释“为什么适合你这次需求”。

## 可操作页面

- `skillbox-ai-discovery-v16.html?screen=overview`：总览状态和 Skill 专用智能搜索。
- `skillbox-ai-discovery-v16.html?screen=discover`：一级“发现 Skills”、候选切换、仓库 Star 与使用热度。
- `skillbox-ai-discovery-v16.html?screen=detail`：面向普通用户的完整发现详情。
- `skillbox-ai-discovery-v16.html?screen=library`：“我的 Skills”中的通用用户说明。
- `skillbox-ai-discovery-v16.html?screen=safety`：加入前四层安全说明。
- `skillbox-ai-discovery-v16.html?screen=settings`：AI 服务商与发送边界。

## 内容生成合同

1. 先读取作者资料：`agents/openai.yaml`、`SKILL.md` Frontmatter、明确的用户章节、README 用途与示例、GitHub 简介和 Release 资料。
2. AI 只负责整理成用户语言，每项内容必须带可验证来源。
3. 作者没有说明的内容自动省略或显示“作者暂未说明”，不得根据常识补写。
4. 不把 Agent 内部执行步骤、安全规则或工具调用说明当成用户体验流程。
5. 使用指南与 Skill 内容指纹绑定；版本变化后旧说明不再作为当前结论。

## 原型数据说明

候选名称、Star、安装量、更新时间和检查结果只用于验证信息层级，不代表实时目录数据。正式实现必须从 `SkillDiscoveryProvider`、GitHub、公开目录和本地安全引擎读取真实结果，并记录获取时间。

## 交互与视觉

- 左侧导航固定展示“发现 Skills”，当前区域始终有明确选中状态。
- 主操作使用蓝色；Star 使用低强调金色，只提供社会关注度线索。
- 所有按钮、列表项、候选、复制和服务商选项都有悬停、按下或完成反馈。
- 弹窗从当前任务出现并返回当前任务；短时、无弹跳，支持减少动态效果。
- 常见窗口宽度优先保持操作按钮、Star 和内容标题完整显示；不足时内容区内部自适应。

当前会话没有 OpenDesign 工具，因此继续使用本地 HTML 与 PNG 作为可视化兜底。正式 SwiftUI 开发必须等待用户确认本原型。
