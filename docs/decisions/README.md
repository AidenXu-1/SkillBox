# decisions —— 架构决策记录(ADR)

> ADR = Architecture Decision Record。每做一个**以后会被反复追问"当初为什么这么选"**的决定,就在这留一条。
> 一个决策一个文件,编号递增。复制 [`_template.md`](_template.md) 开始。

## 为什么要这个

开发到中期一定会问:「当初为什么选 X 不选 Y?」没记录就会反复纠结、甚至推翻重来。写下来,决策就有了"判例"。

## 决策清单

| 编号 | 决策 | 状态 | 日期 |
|------|------|------|------|
| [0001](0001-record-architecture-decisions.md) | 采用 ADR 记录架构决策 | 已采纳 | 2026-08-14 |
| [0009](0009-local-development-source-and-release-snapshot.md) | 外部本地开发源与纯净发布快照 | 已采纳 | 2026-08-21 |
| [0010](0010-github-adhoc-distribution.md) | GitHub 无证书 DMG 发行 | 已采纳 | 2026-08-22 |
| [0011](0011-global-skill-source-and-installation-snapshot.md) | 全局 Skill 唯一来源与安装快照 | 已采纳 | 2026-09-01 |
| [0012](0012-agent-brand-identity-and-target-path.md) | Agent 品牌名称、适配器身份与目标路径分离 | 已采纳 | 2026-09-01 |
| [0013](0013-built-in-agnes-skill-introduction-service.md) | 内置 Agnes Skill 介绍服务 | 已被 0014 取代 | 2026-09-02 |
| [0014](0014-user-owned-agnes-manual-skill-introduction.md) | 用户自有 Agnes API 与手动获取 Skill 介绍 | 已采纳 | 2026-09-02 |
| [0015](0015-quality-first-free-skill-discovery.md) | 质量优先且不引入付费搜索的 Skill 发现 | 已采纳 | 2026-09-03 |
| [0016](0016-community-first-skill-discovery.md) | 先看社区反复提及，再回 GitHub 核验 Skill | 已被 0017 扩展 | 2026-09-04 |
| [0017](0017-multi-platform-recommendation-evidence.md) | 多平台反复推荐后再核验 Skill | 已被 0018 修正运行边界 | 2026-09-04 |
| [0018](0018-silent-community-media-search.md) | 默认媒体发现必须安静运行 | 已采纳 | 2026-09-04 |
| [0019](0019-discovery-quality-and-stability-hardening.md) | 发现质量、上下文与运行稳定性收口 | 已采纳 | 2026-09-04 |
| [0020](0020-semantic-discovery-routing.md) | 精确查找与社区场景发现分流 | 已采纳 | 2026-09-04 |
| [0021](0021-result-first-quality-evidence.md) | 结果优先、强推荐门槛与热度口径统一 | 已采纳 | 2026-09-05 |

| [0022](0022-discovery-request-budget.md) | 按一次寻找共享请求并控制 GitHub 用量 | 已采纳 | 2026-09-05 |

> 状态:提议中 / 已采纳 / 已弃用 / 被取代
