# 当前发现机制风险审查

## 范围与证据

本轮响应“目前是否还存在风险”，只审查，不修改产品源码、设置、安装或运行状态。正式可执行文件仍为 `fe3e2a555fb786590733cf525c590f5fab9587170e3b346feaad3d958c48791d`。实验调用当前构建的 SkillBoxCore；网络用本机 URLProtocol 模拟，没有联网搜索 Skill 或调用付费模型。脚本和原始输出为 `scratch/discovery-risk-review/RiskProbe.swift` 与 `results.txt`。

上一轮 474 项检查覆盖当时的修复，不构成本轮新增场景已通过的证据；本轮没有重新跑全量或实际使用远程 Skill。

## 已确认缺口

### P1：必须条件没有独立的逐项资格检查

`DiscoveryModels.swift:1496` 的写作相关性判断在命中去 AI 味用途词后直接返回 true。mustHaves 参与用途理解和部分排序，但没有对离线、上传限制等条件作逐项必需检查。

实验在 intent 中明确设置“必须离线运行”“禁止上传原文”，给候选的作者简介明确写入“Requires uploading the full text to an external cloud service. Does not work offline.”；候选满足改稿能力、已读正文和 2,000 次安装，仍进入 recommended。

这是推荐资格错误，可让用户选到违反必需条件的工具；实验没有执行工具或上传内容。AI 比较无法修复该硬条件缺口，因为最终本地资格不由模型否决。应优先确保明确冲突不进入推荐；证据不足也不能当作满足。

### P2：GitHub 的搜索和普通请求额度被混用

`DiscoveryModels.swift:838` 读取 Remaining 和 Reset，却没有按 X-RateLimit-Resource 分开保存；`832` 对所有匿名请求统一要求剩余额度大于 12。GitHub 官方明确区分 resource，搜索端点有独立、更严格的限额。

实验给额度门输入一次成功的搜索响应，resource=search、remaining=9、reset=一分钟后，下一次匿名 API 申请被拒绝。对照 core=59 时允许。会误挡仍有额度的后续请求，共用此门的精准查找也可能受影响。不能把该现象说成 GitHub 真的限流，也不能保证刷新或改词能恢复。

来源：[GitHub REST 限额文档](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)。

### P2：缺少覆盖所有来源的统一总请求预算，统计也未覆盖全部访问

`DiscoveryRequestContext.swift:88` 只为 api.github.com 设置每轮 12 次的累计硬上限。128 项限制是可淘汰的缓存／进行中请求数量，不是整轮请求总数。实验在同一 context 顺序读取 250 个不同非 GitHub 地址，全部被接受，blocked=0。

各来源仍有查询数、候选量、正文数和超时限制，因此本实验不证明生产流程会无限循环；它证明缺少所有渠道统一的累计次数与访问节奏约束。`SilentCommunityMediaSearchSources.swift:53` 和 `308` 直接使用 BoundedNetworkResponseLoader，yt-dlp 也有独立访问，均未计入 DiscoveryRequestContext 的统一计数。

需要纠正前面的口头表述：上轮 240 是纳入该统计的资料请求，不是全部网络访问，也不是全渠道总上限。扩大候选和媒体来源后仍可能出现较多请求、延迟和外部限流。

## 已知局限，未伪装成新复现的 bug

- 用途索引目前新增四份人工核对作品，附别名，最多四份独立直读。可维护性有所改善，但不能推断其他领域热门作品已经自动补齐。
- Star 和直读安装量依赖目录 HTML 的明确字段标签，标签或布局变化会使解析回到未知；目录搜索与详情页还共享站点，整站不可用时直读无效。
- 500 次安装、官方或社区证据是推荐筛选信号，核对正文也不等于实际执行后的效果或安全保证。skills.sh 安装指标来自其 CLI 的匿名安装统计，而非全世界的活跃使用量。[官方说明](https://www.skills.sh/docs)
- 上下文有任务状态、消息边界和有限近期引用的保护。本轮没有复现新的串任务 bug，也没有重新验收真实模型长对话质量。上下文截断不应直接等同于已证实的条件丢失。
- 原精准输入在本地实验仍保持完整名称单条查询；它的身份识别保护继续有效，但仍受公共来源可用性和共享请求额度影响。

## 建议顺序

先补必须条件资格判断，再修 GitHub 分类型额度和全渠道请求统计／预算，最后扩充用途索引维护与页面变更探测。修复前把本轮实验转成正式失败回归，并继续保护精准原句和正式窗口出口。本轮没有自行进入修复。
