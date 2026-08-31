# 交接文档

> 用途:换设备、隔了很久回来、或交给别人续做时,**先读这一篇就能续上**。
> 中断前花 5 分钟更新它,未来省 5 小时。

## 当前状态快照

- **阶段**：v0.2.0 已正式发布并完成 GitHub／本地开发／本地安装三端运行内容对齐
- **最近在做**：收口「我的 Skills」列表与拖动排序，升级到 `0.2.0 (3)`，完成公开 Release、附件回读和本机正式替换
- **下一步**：如需补齐陌生用户安装证据，在另一台干净 Mac 通过浏览器下载 v0.2.0，走一次“隐私与安全 → 仍要打开”并完成核心鼠标流程

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

- 真实 Agent 写入尚未授权，不得用自动化测试代替这个验收门槛。
- GitHub v7 原型已得到用户确认，正式 SwiftUI 已接入；构建只允许公开 Client ID 和安装地址，不得放入 Client Secret、私钥或个人 Token。
- 当前产品决策明确采用 ad-hoc Hardened Runtime DMG，不做 Developer ID 签名与 Apple 公证；Gatekeeper 阻止并要求用户走“仍要打开”属于预期安装路径。v0.2.0 的 277 项测试、DMG、包内隐私、图标、来源清单、SHA-256、GitHub Release 下载回读和本机正式启动均已通过。
- 另一台干净 Mac 的浏览器下载、隔离属性和“仍要打开”安装体验仍是独立验收门，不能用本机通过 GitHub CLI 下载后的启动代替。
- 尚未做当前候选的真实私人仓库授权、真实 Agent 安装/更新/卸载/撤销闭环和完整鼠标前台回归。
- 只读鼠标与基础键盘主路径已完成真实前台验收；涉及 Agent 文件改动的操作均在确认前取消，不能替代后续真实生命周期验收。

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
