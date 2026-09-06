# 卡兹克 human-writing 漏找修复验收

## 用户出口

用户指出能找到 khazix-writer，但漏掉卡兹克的 human-writing。后者实际位于独立仓库 [KKKKhazix/human-writing](https://github.com/KKKKhazix/human-writing)，并非 khazix-skills 的子目录。公开 skills.sh 按作者账号查询即可召回两个仓库。

当前测试版重新输入用户原句“帮我找到卡兹克那个写作的Skill。”，三栏主列表同时显示 khazix-writer 和 human-writing。右侧选中后者，显示来源 kkkkhazix/human-writing、502 次安装和实际 SKILL.md 中文摘要。没有把名称硬编码成推荐，也没有放宽 500 次使用量等既有品质门槛。

## 已复现原因与修复

1. 旧作者解析只覆盖紧连的“某人的…”，未识别“卡兹克那个写作的Skill”及作者名两侧空格。用户实际运行被记为 scenario、targets 为空。现在两种表达均保留作者目标。
2. 旧补充词只点名 khazix-writer，混合查找又未按仓库所有者收窄。现在已知别名只映射 GitHub 账号；按账号跨仓库查询目录、skills.sh 和 GitHub，正文核验前过滤其他所有者，返回和排名再次检查作者。不再让广域媒体搜索或其他作者耗尽这个定位阶段的名额。每轮 12 次 GitHub API 上限保持不变。
3. 作者名被混进能力词，“那个”等口语词也能建立匹配；摘要中的“不要用于公众号写作”没有被识别为否定，导致 hv-analysis 被错推。现在作者身份与用途判断分开，作者补充词不再作为应用排序的能力偏好，口语词排除，补齐“不要用于／勿用于”否定表达。

未知中文作者不猜测 GitHub 账号。作者身份不能替代品质和用途证据。不同作者的同名 Skill 不进入限定作者的结果。

## 验证证据

- 原始三栏截图 `scratch/discovery-outcome-fix/author-before.jpg`：主列表 11 项，含 khazix-writer、hv-analysis 和其他作者作品，缺少 human-writing。
- 新增 DiscoveryAuthorTests 4 项（作者表达测试另含 3 个参数样本）。改前复现作者识别、跨仓库召回和排序失败；改后覆盖实际 DefaultSkillDiscovery 组合及 AppModel 的最终可见列表。
- 最终完整 `app/Scripts/test-all.sh` 退出 0，399 项普通测试＋36 项 GitHub 隔离测试，共 **435 项通过**。最终日志为临时目录中的 `skillbox-author-all-tests.log`。
- 真实运行在同一寻找记录中重发原句，启动于北京时间 2026-09-06 01:15:37；route=hybrid，author=卡兹克，最终推荐恰为两个作者写作 Skill。没有修改原始历史运行。
- 旧原句运行资料请求 231 次、GitHub API 12 次、复用 1 次；当前原句运行分别为 **44、2、9**，预算阻止 0 次。这是两次真实运行的现场对比，不能解释为所有作者查询的固定成本。
- 当前仍为 partiallyCompleted：1 个来源未完成（匿名代码搜索没有可用身份，不发送该请求），3 个候选正文未核验成功。窗口如实提示，不宣称覆盖作者全部作品。human-writing 实时正文与来源均核验通过。
- 修复后三栏截图 `scratch/discovery-outcome-fix/author-after.jpg`；原始及当前运行摘要 `author-live-acceptance.json`。已通过 Finder 从精确路径打开到前台，停在 human-writing 详情。

## 构建与边界

Spec v2.40。Release 构建与严格签名通过，应用 9,456 KiB，比上一请求预算候选增加 16 KiB；相对正式版增加 112 KiB。候选可执行文件 SHA-256：`2225dd5988d597fb6ed4d626e3975c609e6259ed3621a54b412208fd281f6906`。当前运行 QA 指纹：`16c05088229a6367e9d1b05660c3707d30e545ee27a7ef3cdc60f212014fc225`。

本轮没有改变三栏设计、增加依赖、数据库、持久缓存或存储上限，没有调用付费模型、添加或安装 Skill。正式应用指纹仍为 `4d855171a1d08287374b664e69ebe0fa836b07fdcd944e518db05c8423a75956`，未替换或发布。工作区包含此前多个未提交切片，保留现状，未混合提交。
