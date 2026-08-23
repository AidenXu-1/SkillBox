# SkillBox

> 一个统一管理本地 Skills，并同步安装到多个 Agent 产品的本地工具。

本仓库采用「三层物理隔离 + AI 工作层」的方式管理：把**想清楚 / 做出来 / 长什么样**分开，并为不同 AI Agent 提供统一入口。

## 仓库结构

```
SkillBox/
├── CLAUDE.md         ← AI 工作入口(Claude Code 自动加载)
├── AGENTS.md         ← 通用 Agent 工作入口(Codex / Copilot 等)
├── README.md         ← 你在这里:项目总入口与导航
├── docs/             ← 规划与管理:spec、agent-guide、overview、roadmap、progress、handoff、决策记录
├── app/              ← SwiftUI 应用、纯 Swift 核心和自动化测试
├── design/           ← 设计与 UI 参考
└── scratch/          ← 草稿/实验区(git 忽略)
```

## 三层各管什么

| 文件夹 | 回答的问题 | 谁主要在这里工作 |
|--------|-----------|----------------|
| `docs/` | 我们要做什么、做到什么程度、做到哪了 | 规划 / 决策 / 交接 |
| `app/` | 怎么做出来 | 写代码 |
| `design/` | 它长什么样、参考了谁 | 设计 / 体验 |

## 从哪开始

1. 读 [`docs/spec.md`](docs/spec.md) —— 当前唯一开发准绳。
2. 读 [`docs/agent-guide.md`](docs/agent-guide.md) —— AI 协作规则与安全边界。
3. 读 [`docs/roadmap.md`](docs/roadmap.md) —— 阶段地图。
4. 想了解进展，看 [`docs/progress.md`](docs/progress.md)。
5. 接手项目 / 换设备继续,先读 [`docs/handoff.md`](docs/handoff.md)。

## 当前阶段

🟡 **GitHub 上传候选已生成** —— [Spec v1.9](docs/spec.md) 已采用 GitHub DMG 分发策略。262 项测试、隐私扫描、SHA-256、来源清单、图标回读、DMG 完整性与隔离属性模拟通过；Developer ID 与 Apple 公证不再是上线强制条件。正式对外宣称上线前仍需完成一次干净账户“仍要打开”安装与核心鼠标流程。

## 快速验证

```bash
cd app
./Scripts/test-all.sh
./Scripts/package-app.sh release
```

更详细的运行方式见 [`app/README.md`](app/README.md)。
