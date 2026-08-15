# 交接文档

> 用途:换设备、隔了很久回来、或交给别人续做时,**先读这一篇就能续上**。
> 中断前花 5 分钟更新它,未来省 5 小时。

## 当前状态快照

- **阶段**：GitHub Release 纯净 ZIP 导入、完整性校验和风险上下文已接入，真实外部验收前
- **最近在做**：Release Asset 选择、无 ZIP 源码回退、SHA-256 校验、Asset 版本记录和 GitHub Actions 令牌风险分级
- **下一步**：用一个真实公开 Release 完成 ZIP/多 ZIP/无 ZIP 验收；Computer Use 通道恢复后补鼠标、键盘、VoiceOver 和减少动态效果验收

## 怎么把环境跑起来

```bash
cd app
swift test
./Scripts/package-app.sh release
```

- 本地测试应用：`app/.build/release/SkillBox.app`
- 只读真机扫描：`swift run SkillBoxDiagnostics --read-only-scan`
- 直接运行源码应用：`swift run SkillBox`（会打开前台应用，需用户明确同意后再做）

## 现在卡在哪 / 待决策

- 真实 Agent 写入尚未授权，不得用自动化测试代替这个验收门槛。
- GitHub v7 原型已得到用户确认，正式 SwiftUI 已接入。
- 私人仓库需先注册 GitHub App，构建仅接收公开 Client ID 和安装地址；不得放入 Client Secret、私钥或个人 Token。
- 尚未做真实私人仓库授权、真实鼠标/键盘/VoiceOver/减少动态效果验收、Developer ID 签名、公证和 DMG。
- Computer Use 退出旧 SkillBox 进程后连续返回 `Sky Computer Use native pipe closed before response`；通道恢复前不要宣称新 SwiftUI 已通过真实前台验收。

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
- 设计参考:`design/`
- GitHub 原型：`design/ui/skillbox-github-v7.html`
- GitHub 设计说明：`design/ui/skillbox-github-v7.md`
- Release 安装包选择说明：`design/ui/skillbox-release-package-v12.md`
- GitHub 来源决策：`docs/decisions/0004-github-source-tracking-and-auth.md`

---
最近更新:2026-08-15
