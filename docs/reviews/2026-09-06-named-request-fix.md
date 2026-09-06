# 指定对象与连续追问修复验收

日期：2026-09-06。用户已明确授权修复及正式应用交付。

## 根因与范围

基于正式历史记录和上轮只读重放，已确认卡兹克自然句中的作者识别依赖固定句式，空格名称的命名句不被识别，追问被当作新任务，中文叫法缺少与公开作品身份的关联。前次完整测试没有覆盖这些真实输入。清理安装包不影响源码与正式 App；不把时间先后误写成因果证据。

## 本轮改动

- 作者别名与句式分别识别；“帮我找卡兹克写作的skill。”保留作者，核对作品用途后展示。
- 命名句支持空格、连字符和单词名称；作者任务中的“有个human writing的skill。”保留作者与原任务，同时限定名称。新任务或明确不同用途会改变任务。
- 精确查找同时核对作者和名称；询问热度也不得丢掉其中一项。补充名称或纠正作者时，新的必须条件和明确偏好继续保留。
- 中文身份别名采用独立字段 nameAliases / nameAliasSource；用途扩展 searchAliases 不得进入身份匹配。冲突或无来源的别名不指定作品。
- 小黑配图关联作者 helloianneo 的 ian-xiaohei-illustrations/SKILL.md。名称映射只提供核验位置，远端缺失或改名不能返回成功。
- 没有改变三栏布局、推荐数量、场景质量标准、请求预算、付费服务配置或模型调用次数。

## 验证证据

所有本轮证据保存在 scratch/named-request-fix/。author-red、names-red、context-red、aliases-red、combined-red、refinement-red 分别记录原始失败；对应 green 记录修复通过。最后一次补充复核发现“有个名称，而且必须离线”可能吞掉新增条件，已经先复现再修正，并加入固定检查。

完整检查与正式安装窗口结果在本报告后续验收记录中填写；不以本地测试代替真实联网出口。此轮不调用真实付费模型，模型规划边界由已有模拟与一致性测试验证。

## 有效范围

公开名称能够在已接入来源中发现时才可核验；中文别名索引有明确收录范围，不能承诺任意昵称或全网作品均被收录。身份相符不等于推荐品质或作者提供的能力一定达到预期。旧失败记录保留，不伪造历史成功；通过新查询确认当前行为。

本轮开始前已有大量功能改动未提交。保留它们，并用 before-source 快照区分本轮改动；不混合提交此前多轮工作。

## 最终正式验收

正式安装并打开 `~/Applications/SkillBox.app`，版本 0.2.2 Build 6；窗口输入用户原句并读取最终列表。实际联网测试期间 AI 关闭，随后原 AI 设置逐字节恢复，再次打开窗口，模型选择显示 agnes-2.5-flash。没有付费模型验收，不据此宣称所有模型生成回答的质量已验证。

| 真实输入 | 最终可见结果 | HTTP / GitHub API / 外部工具 |
| --- | --- | --- |
| 帮我找卡兹克写作的skill。 | khazix-writer、human-writing，两份均属于 KKKKhazix | 56 / 12 / 0 |
| 我记得卡兹克有两个写作skill啊。 | 仍保留两份，原任务连续 | 2 / 1 / 0 |
| 有个human writing的skill。 | 只保留 KKKKhazix/human-writing，无同名他人作品 | 103 / 12 / 0 |
| 我找一下vibe-project-foundation-skill这个skill | 唯一命中 AidenXu-1/vibe-project-foundation-skill | 15 / 1 / 0 |
| 推荐去文案AI味的skill。 | 5 份推荐，包含用户指定的卡兹克两份、blader/humanizer、petergyang/no-ai-slop | 256 / 12 / 2 |
| 我要找一个小黑配图的skill。 | 唯一命中 helloianneo/ian-xiaohei-illustrations | 1 / 0 / 0 |

模糊本轮为实际 5 份，不能用这次恰好 5 份证明固定数量上限；全量检查包含超过五份的既有案例。模糊查询到达既有请求上限，作者与具名查询也有部分 GitHub API 请求被预算阻止；已核验目标保留，但不宣称所有来源均已查完。没有增加预算，也没有证明所有查询都已达到最低请求量。原三栏保持，作者和模糊结果的使用量与 Star 均可查看；小黑的这次直接核验未取得热度数据，界面诚实显示未知。

最终完整检查 516 项、38 个测试进程全部通过。Release 构建、严格签名、隐私检查、系统图标、DMG 校验以及只读挂载后包内程序同一性通过。仍为既有 ad-hoc hardened-runtime 分发方式，未公证，未完成干净账户安装验收；没有改系统信任。

正式程序摘要：`a620076b613ebcc0ae0943e14aff86bb3a6c087842e38ec913a88aafb95a301a`。
最终 DMG 摘要：`2e10f963ee9fc6c30209a4a01bc4ed44bc1fd2f1e7daf5fb124e6d40b82e85c6`。
最终三件套：`app/.build/distribution/SkillBox-0.2.2.dmg`、`.sha256`、`SkillBox-0.2.2-release.json`。清单绑定构建时源码快照，后续本验收文档与进度记录不改变程序。

替换前备份：`~/Library/Application Support/SkillBoxBackups/20260906-190132/`。替换时 740 个原始资料文件未变。真实验收后，旧寻找记录、用户 Skill、来源关系、安装关系与 AI 设置保留；仅两个派生索引中的风险检查 UUID 在自动扫描后刷新，排除这些 UUID 后 JSON 完全相等。新增 4 条真实验收记录，没有改写此前失败历史。完整核对见 `scratch/named-request-fix/live-acceptance.json`。
