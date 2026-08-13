# 交接文档

> 用途:换设备、隔了很久回来、或交给别人续做时,**先读这一篇就能续上**。
> 中断前花 5 分钟更新它,未来省 5 小时。

## 当前状态快照

- **阶段**：M6/M7 真实验收前（见 [roadmap.md](roadmap.md)）
- **最近在做**：原生核心、安全同步、GitHub 导入与功能型 UI
- **下一步**：获得用户明确授权后，完成一次可恢复的真实同步/撤销验收，再进入 UI 优化

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
- 尚未做真实 GitHub 网络导入、鼠标前台验收、Developer ID 签名、公证和 DMG。
- 用户已决定先打磨功能，所以当前 SwiftUI 仅保证流程可用，不要提前扩展视觉范围。

## 容易踩的坑 / 注意事项

- 扫描阶段必须只读，不可顺手创建不存在的 Agent 目录。
- GitHub 预览返回的候选文件位于临时目录，只能在导入完成或取消后清理。
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

---
最近更新:2026-08-14
