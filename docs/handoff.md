# 交接文档

> 用途:换设备、隔了很久回来、或交给别人续做时,**先读这一篇就能续上**。
> 中断前花 5 分钟更新它,未来省 5 小时。

## 当前状态快照

- **2026-09-17 两项review问题已补修**：当前本机0.2.5 Build19，后台新版可见提醒与稍后结束会话均已真实验证；全量检查和本地发行产物通过，用户资料保持，临时旧App清理。尚未发布；下一步如获授权，应使用Build19产物，不使用旧Build18。见[补修记录](reviews/2026-09-17-update-review-fixes.md)。下方未通过记录为修复前历史。

- **2026-09-17 发布前review未通过**：产品`6dd60f4`有2项待修P2：后台发现新版没有可见提醒、缺少“稍后”结束更新会话。真实探针已复现；包、资料保留及签名未发现新问题。本轮只复核，未改产品/重装/发布。先处理[最终复核](reviews/2026-09-17-about-updates-final-review.md)再发行，下条为此前实现记录。

- **2026-09-17 当前任务**：Spec v2.61已实现，本机原位置0.2.5 Build18；关于/应用内更新/删除提示与历史恢复完成。本地已准备签名ZIP、DMG与appcast，尚未发布。普通App更新不创建用户资料或七天完整备份。远端默认分支是master。后续须取得本轮v0.2.5公开发行授权；下方历史版本的发布授权不能继承。见[验收记录](reviews/2026-09-17-about-updates.md)。

- **2026-09-14 v0.2.4 Build 14 已推送并正式发布**：[最新下载](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.4)，Release ID `388146249`，标签固定 `b2fb8557a75aedb02d5fdd7d4ed270bd757ebb7e`；三个附件已匿名下载核对，旧版保留。当前本地分支 `codex/release-v0.2.4` 为最终树的公开提交，原开发历史保留在 `codex/release-v0.2.2`，不要再将其含私人路径的旧中间提交推到远端。本机仍为相同修复逻辑的 Build 13，未重新安装/旋转备份；发布缓存已清理。见 [发布记录](reviews/2026-09-14-release-024.md)。以下均为历史状态。

- **2026-09-14 项目清理完成**：旧实验、4 个 QA App 和构建缓存等 135 项已移至 `~/.Trash/SkillBox-project-cleanup-20260914-015245`，约 1.42 GB，未清空。当前 Build 13、公开 v0.2.3 安装包、唯一有效 Build 12 回退备份、正式源码/测试/设计/文档保持；正式 App 已重开。`scratch` 中历史原始证据需按 [精确移动清单](reviews/2026-09-14-project-cleanup.md) 去废纸篓查找，不要将旧 QA 入口当作仍存在或重新开启验收。下次构建会重新生成缓存，不影响现在使用。

- **2026-09-14 本轮修复已验收通过并结束**：用户明确要求以代码测试及流程运行通过作为结论，后续实际使用问题另行反馈。最终完整测试退出 0，Swift 600 项实际通过、1 项公网跳过，Python 28 项通过，日志 `scratch/2026-09-14-final-acceptance.log`。本机仍为已核对的 0.2.3 Build 13。剩余隔离窗口点击验收已由用户取消为完成门槛，无待继续验收或追加评审的任务；此前未实测的事实不改写为通过。测试应用已退出，不自动重开，不重复安装/旋转备份，未公开发布。以下为历史记录。

- **2026-09-13 Spec v2.60 已修复并安装 Build 13，隔离前台验收有明确缺口**：限定检查及集中修复完成，产品提交 `933fff9`；Swift 600 项实际通过、1 项公网跳过，Python 28 项通过，独立复核通过，不重新扩展审计。正式 App 已安装 Build 13，程序 SHA `954d2fa76de65036135402ddf9dfd29c48fb617726852c449b8f465db2d8fac0`，真实启动/手动备份检查通过，174 个受保护文件及分类安装关系保持。回退仅留 Build 12 与配套资料，9 月 20 日 20:33 到期；证据 `scratch/bounded-installed.json`、`scratch/bounded-rotation.json`。隔离 QA 的 CUA 连接仍报 native pipe closed，15 秒超时也未能阻止长时间阻塞，因此停止重复连接；取消、更新、恢复、失败重试、同资料重开的本轮真实按钮验收尚未完成，不能记为通过。若连接恢复，仅补这部分，夹具入口 `scratch/bounded-flow-audit/ui-qa/qa-bundles.json`；不需要再安装或重复旋转备份。未公开发布。详见 [限定修复与验证](reviews/2026-09-13-bounded-update-recovery.md)。以下为历史状态。

- **2026-09-08 v0.2.3 Build 7 已正式发布并完成公开下载核对**：[最新下载](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.3)，Release ID `384462940`。标签固定为 `e96f1fd2f667173c5b8333715c106910bea422e6`，本机与公开 DMG 程序一致，旧版保留。534 项实际通过、1 项公网跳过；用户已允许披露首次安装未验证后先发布，另一用户启动报错仍未复现，二者均已写入发布说明。三个公开附件匿名下载与签名／版本／摘要核对通过，README 已回读；没有发布待确认项。详见 [发布与验证记录](reviews/2026-09-08-release-023.md)。以下均为历史状态。

- **2026-09-08 v0.2.3 Build 7 发布候选已就绪，尚未公开**：冻结源码 `e96f1fd2f667173c5b8333715c106910bea422e6`，DMG `f92bf9471e8eb7fc3b4e8d8a21c3c211eab11d84daf627915e9aa6547857a358`，程序 `7dca9af650de919a1407a0f231d5316fed5c3656511ae3877c77765a89fbb6a9`。534 项实际通过、1 项公网跳过，完整发行脚本与 DMG 只读回读通过；本机已备份更新并真实核对。唯一发布范围待决为干净账户首次安装缺少实测；另一用户启动报错允许无法复现时如实保留。还未推送或创建标签／Release；后续若获准发布，标签绑定上述冻结源码，保留旧版并完成公开下载回读。详见 [v0.2.3 候选](reviews/2026-09-08-release-023.md)。以下为历史状态。

- **2026-09-08 最新本机 v2.54**：收纳盒归类图标已确认并交付，静态／浮动标题一致，下层来源图标保留；完整 534 项实际通过、1 项公网跳过，真实正式窗口核对通过。程序 SHA `ffef1ccb45902e4123ebdf58de364d2ae2192b41f499e7c5c7ca8baa2fcc4964`，用户内容、分类排序和安装关系保留。此前所有图标待确认项均已完成；公开下载未更新。详见 [图标交付](reviews/2026-09-08-leading-source-icons.md)。以下为历史状态。

- **2026-09-08 最新本机 v2.53**：左侧来源图标已交付，程序 SHA `253c7d1eb5eec6f2e2a25ee2058725802801dae91380ea7829c985dc21f99888`。534 项实际通过、1 项公网跳过，正式窗口显示通过；分类／排序语义、7 份 Skill 和安装关系保留，公开下载未变。用户新反馈归类图标与本地来源相同，已制作 `design/ui/skill-source-leading-20260908/category-preview.html` 收纳盒／标签图标对比（叠层已被用户否定），当前待用户选择，未改原生分类图标。详见 [来源图标交付](reviews/2026-09-08-leading-source-icons.md)。以下为历史状态。

- **2026-09-08 最新本机 v2.52**：已确认的文件夹视觉层级已实施，534 项实际通过、1 项公网跳过；隔离原生拖动与本机显示验收通过。正式程序 SHA `cb2b158588ddc883db2114abe2c44f0b6e33871512cf52c9e8223125bc3bae0a`。用户当前两个文件夹、7 份 Skill 与安装关系保留。来源图标移到 Skill 左侧仍为待确认对比预览：`design/ui/skill-source-leading-20260908/`。详见 [层级交付](reviews/2026-09-08-folder-hierarchy.md)。以下为历史状态。

- **2026-09-08 最新本机版本**：用户指定文件夹优先，已完成 v2.51 并更新本机、置前验收。文件夹及其内容在上方、可互相拖动排序，未分类在下方。533 项实际通过、1 项公网跳过。程序 SHA `cf33bbcd790248f1d6dd465479b522ee5870355e1f04388939d8a9f6db5e0e5f`；原 7 份 Skill 与用户当前分类保留，公开下载未变。详见 [文件夹置顶](reviews/2026-09-08-folders-first.md)，以下为历史状态。

- **2026-09-08 当前本机已更新**：v2.50 原生整理完成，531 项实际通过、1 项公网跳过。正式 App 程序 SHA `8ba8bb4a3343858c783aff76a6dc4b1b7c6175cc76ef0dbb16a2e4c702142d15`，包含前述对话、启动及安装修复；原七份 Skill、分类和安装关系保留。公开下载仍是旧 v0.2.2 Build 6，本机为同版本号的本地修复程序。恢复位置及原生证据边界见 [整理完成与本机更新](reviews/2026-09-08-organizer-native-fix.md)。以下“候选未安装”记录均为此前状态。

- **2026-09-08 启动与安装修复候选**：523 项实际通过、1 项公网跳过，Release/签名/隐私与隔离原生安装、卸载通过。候选 `scratch/installation-fix-20260908/SkillBox.app`（SHA `352499505226ee9f65d5b117946d6ed3cb5f8c3ef9f3615493ebe80875f89193`），含上一轮对话修复，未替换正式 App 或发行。文件夹完整拖放仍是待确认的可操作预览，见 `design/ui/organizer-20260908/README.md`。不要把浏览器预览当成原生实现，也不要把启动取消旧扫描当成已复现另一用户的本地读取弹窗。

- **2026-09-07 本地修复候选**：已修复问句新查找、切换后自动处理补充、撤回条件同义表达残留三项 bug。520 项实际通过、1 项公网用例跳过；独立模拟来源原生 QA 通过。正式安装与线上仍为下述 v0.2.2 Build 6，本轮未替换或发布。详情及候选位置见 [对话修复与语义能力边界](reviews/2026-09-07-conversation-bug-fix.md)。用户关心保护既有查找效果；统一对话理解层仅作后续方案，尚未实施或获批大改。

- **阶段**：v0.2.2 Build 6 已发布为 GitHub 最新正式版本，保留旧版本；[下载页](https://github.com/AidenXu-1/SkillBox/releases/tag/v0.2.2)。本机正式安装与发现功能真实验收已完成，首次安装环境仍有单独待验证项。
- **最近在做**：收口全局 Skill 管理与发现对话；修复作者自然句、英文空格名称、中文身份别名和连续追问。最终 516 项检查通过，正式 App 与本地 DMG 对应同一运行内容。
- **下一步**：收集首次安装环境反馈，跟进公开版本真实使用问题。三个 GitHub 附件已匿名下载并逐字节核对，版本标签与安装包来源一致；禁止把本机旧账户的启动当作干净账户验收。
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
- 干净账户或另一台 Mac 的首次安装体验仍待提供本代证据；真实付费模型生成质量也没有在此轮额外验收。用户知悉范围后回复“可以，推进”，本次据此发布并公开保留未验证项，不将首次安装记为通过，不改变后续默认门槛。
- 旧资料与 AI 设置已保留，本机完整备份位于 `~/Library/Application Support/SkillBoxBackups/20260906-190132/`。精确名称、作者、模糊场景、停止/继续和历史恢复分别保留行为测试；功能通过不等于全网查全。

## 发布分支与本地历史

- 本次使用 `codex/release-v0.2.2`，从远端 master 承接清理后的完整源码。
- `v0.2.2` 固定指向 `5ae3e8c1651bb4837358d8aa66e7756ae5481369`，对应 Build 6 来源清单；发布后的文档提交不移动标签，不重打或替换该版本附件。后续开发以此发布分支或当前远端 master 为基础。
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
最近更新:2026-09-06
