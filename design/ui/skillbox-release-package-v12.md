# SkillBox Release 安装包选择 v12

本轮只新增两个必要的决策点，不把 GitHub 的技术字段暴露给普通用户。

- Release 只有一个 ZIP：直接下载并进入 Skill 预览。
- Release 有多个 ZIP：弹出「选择要添加的安装包」，不预选，用户选定后才能继续。
- ZIP 旁边有同名 `.sha256` 或 GitHub 提供摘要时，仅显示「带完整性校验」；内部 ID 和摘要不进入主流程。
- Release 没有 ZIP：弹出独立提示，清楚告知会导入测试、CI 和开发文件，只有用户点击「导入完整源码」才继续。
- 校验不通过时停止导入，不提供绕过按钮。

预览：

- `skillbox-release-package-v12-choice.png`
- `skillbox-release-package-v12-fallback.png`

界面采用单任务 Sheet，主操作始终放在右下角；按钮有悬停、按下、禁用反馈，减少动态效果时仅使用短暂透明度变化。
