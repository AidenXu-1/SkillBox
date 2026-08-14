# ui —— 自己的 UI 设计稿

线框图、界面稿、Figma 导出、交互说明放这里。

> 命名建议:`<界面名>-v<版本>.<扩展名>`,例如 `主界面-v1.png`,方便看演进。

## 当前设计

- [SkillBox 交互原型 v1](skillbox-prototype-v1.html)
- [设计说明](skillbox-prototype-v1.md)
- [资产总览截图](skillbox-prototype-v1-overview.png)
- [首次盘点截图](skillbox-prototype-v1-onboarding.png)
- [同步预览截图](skillbox-prototype-v1-sync-preview.png)
- [通俗文案版·总览](skillbox-copy-v2-overview.png)
- [通俗文案版·欢迎页](skillbox-copy-v2-onboarding.png)
- [通俗文案版·安装确认](skillbox-copy-v2-install-preview.png)
- [空状态与冲突处理 v3 说明](skillbox-layout-v3.md)
- [空 Skill 库 v3](skillbox-layout-v3-empty-library.png)
- [空安装页 v3](skillbox-layout-v3-empty-agents.png)
- [同名内容选择 v3](skillbox-layout-v3-conflict-choice.png)

## 可视化交付要求

- UI / 交互 / 视觉 / 页面布局 / 用户体验路径节点必须提供用户能直接看的预览。
- 优先使用 OpenDesign artifact 或 Figma 等可编辑产物。
- OpenDesign 不可用时,用本地 HTML + PNG 截图或可打开图片兜底。本次 v1 原型使用此兜底路径。
- OpenDesign 未安装 / 未运行、无 active project、权限不足、连接失败或 MCP 未热加载时,先问用户是否需要帮忙安装 / 启动 / 授权 / 注册 MCP / 重载或新开会话;没有 active project 时要求用户在 OpenDesign 内创建或点进项目;用户不想处理 OpenDesign 时,直接按用户偏好走兜底预览。
- 每次设计回报同时给设计说明文档路径和可视化预览路径;兜底时写清 OpenDesign 当前状态和恢复条件。
