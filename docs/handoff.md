# 交接文档

> 用途:换设备、隔了很久回来、或交给别人续做时,**先读这一篇就能续上**。
> 中断前花 5 分钟更新它,未来省 5 小时。

## 当前状态快照

- **阶段**：v0.2.2 Build 6 已完成本机正式安装与发现功能真实验收，正在准备 GitHub 发布；公开最新版本当前仍为 v0.2.1。
- **最近在做**：收口全局 Skill 管理与发现对话；修复作者自然句、英文空格名称、中文身份别名和连续追问。最终 516 项检查通过，正式 App 与本地 DMG 对应同一运行内容。
- **下一步**：补齐首次安装环境验收，按用户本轮授权在评审通过后发布 GitHub v0.2.2，再下载附件核对来源和摘要。禁止把本机旧账户的启动当作干净账户验收。
- **验收记录**：见 [指定对象与连续追问修复](reviews/2026-09-06-named-request-fix.md) 和 [最后发布评审](reviews/2026-09-06-github-release-review.md)。

## 怎么把环境跑起来

```bash
cd app
./Scripts/test-all.sh
./Scripts/package-app.sh release
```

- 本地测试应用：`app/.build/release/SkillBox.app`
- 只读真机扫描：`swift run SkillBoxDiagnostics --read-only-scan`
- 直接运行源码应用：`swift run SkillBox`（会打开前台应用，需用户明确同意后再做）

## 现在卡在哪 / 待决策

- 用户已授权最后评审、必要修复，以及通过后的 GitHub 发布；不重复索要同范围发布授权。
- 当前继续采用 ad-hoc Hardened Runtime DMG，不做 Developer ID 签名与 Apple 公证；如 macOS 阻止，用户按安装说明完成“仍要打开”。不改系统信任或代输 Mac 密码。
- 干净账户或另一台 Mac 的首次安装体验仍待提供本代证据；真实付费模型生成质量也没有在此轮额外验收。前者按 Spec 属于正式上线门槛，后者在发布说明中保留验证范围。
- 旧资料与 AI 设置已保留，本机完整备份位于 `~/Library/Application Support/SkillBoxBackups/20260906-190132/`。精确名称、作者、模糊场景、停止/继续和历史恢复分别保留行为测试；功能通过不等于全网查全。

## 发布分支与本地历史

- 本次使用 `codex/release-v0.2.2`，从远端 master 承接清理后的完整源码。
- 本地旧 master 保留此前未公开的开发过程，包含一条旧本机路径记录；后续以本次发布分支继续开发，勿直接把旧 master 历史推送到公开仓库。

## 容易踩的坑 / 注意事项

- 扫描阶段必须只读，不可顺手创建不存在的 Agent 目录。
- GitHub 版本检查只请求元数据，用户确认后才能下载完整快照；候选文件位于临时目录，只能在导入/更新完成或取消后清理。
- Release 和 `main` 相互独立；Release 模式优先使用作者上传的 ZIP 安装包，多个 ZIP 必须由用户选择，没有 ZIP 时明示确认后才使用 Tag 源码。
- Release ZIP 的同名 `.sha256` 必须校验；版本记录要保留 Release ID、Asset ID 和实际 SHA-256，不能只用仓库 Tree SHA 判断 Release 资源是否变化。
- GitHub Token 只能保存在 macOS 钥匙串，不要加入持久化 JSON、诊断输出或操作记录。
- 未托管同名目录与外部改动必须阻塞；仅有用户明确授权才能接管或替换。
- 撤销时也要重新校验当前指纹，不得覆盖事务后的外部修改。

## 关键文件在哪

- 规划入口:[docs/README.md](README.md)
- 当前开发准绳:[spec.md](spec.md)
- Agent 共用规则:[agent-guide.md](agent-guide.md)
- 工程与验证命令：[app/README.md](../app/README.md)
- 核心代码：`app/Sources/SkillBoxCore/`
- 界面代码：`app/Sources/SkillBoxApp/`
- 自动化测试：`app/Tests/SkillBoxCoreTests/`
- 稳定全量门禁：`app/Scripts/test-all.sh`
- 正式发行门禁：`app/Scripts/release-distribution.sh`
- 设计参考:`design/`
- GitHub 原型：`design/ui/skillbox-github-v7.html`
- GitHub 设计说明：`design/ui/skillbox-github-v7.md`
- Release 安装包选择说明：`design/ui/skillbox-release-package-v12.md`
- GitHub 来源决策：`docs/decisions/0004-github-source-tracking-and-auth.md`

---
最近更新:2026-09-01
