# 模糊需求推荐漏失与 Star 缺失

## 原始证据

用户输入 `推荐去文案AI味的skill。`，正式记录推荐五份；前一条近义需求仅推荐一份。没有固定五个的产品上限。原记录有 233 次资料请求、12 次 GitHub API、1,610 个待核验候选、13 次正文核验失败、3 个失败来源；模型比较结构校验失败后使用本地结果。

## 已确认的原因与处理

1. **入口用词与目录匹配方式不合。** 原补充词主要是 humanize writing、remove AI writing style、natural writing rewrite。免费目录并非覆盖全面的语义搜索；实查 humanizer、slop、human writing 才分别出现目标对象。有限正文核验名额又优先给重复出现在近似查询中的对象。新增来源已核对的用途索引，使模糊需求在八条总查询内优先获得完整 Skill 名称，沿用现有同名优先与核验预算。
2. **内置目录的来源偏窄。** 原 921 项集中于三个大仓库，没有四份独立作者作品。现在补充四份为 curated 条目，附可维护的用途别名；更新脚本重新读取作者文件核对身份。条目在 `app/Scripts/trusted-skill-supplements.json`，名称没有写成路由分支。别名只用于召回，不能替代真实正文、使用量或其他推荐品质证据。
3. **真实能力与用途范围误判。** 卡兹克长文写作的活人感要求在正文，仅读简介会漏掉；现允许使用最多 8,000 字符的核验正文，简介明确否认能力时禁止用正文覆盖否认。no-ai-slop 同时支持改稿与只检测，旧规则看到 detect 且没有 rewrite 原形便当作只能检测；现识别肯定的 edit drafts 等改稿表述，保留明确诊断专用的排除。
4. **仓库热度没有补齐。** 目录搜索接口主要提供安装数，读取 raw 正文的节流路径跳过仓库 API，已请求的目录页面却只解析简介。现从页面明确标注的 GitHub Stars 读取显示值并缓存，额外 GitHub API 请求为零。7.3K 等近似值按原文存储，不伪造成精确整数；缺失字段仍未知，安装数与 Star 不混用。
5. **真实窗口补查。** 第一轮正式验收找到七份及四个指定对象，但暴露多行简介被显示为 `|`、韩语专用工具混入的问题。目录正文读取现复用已有多行解析器，目录摘要不覆盖作者说明；韩语原文的语言限制也参与过滤，用户明确要韩语时仍可推荐。下一轮又发现 API 文档示例可触发正文用途匹配，现增加前置条件：简介须先证明属于写作／改稿领域，正文只能补足能力，不能为 API 示例创建写作用途。
6. **保护精准查找时发现的结束状态竞争。** 完整回归捕捉澄清完成后立即输入名称偶尔被挡住：内层先把 UI 置为空闲，外层尚在保存队列且任务仍存在。现在仅由外层在整轮和队列处理完毕后统一清理，保留原断言，不靠延时掩盖。

7. **搜索服务故障的独立出口。** 14:03 的最终包验收遇到 skills.sh 搜索接口连续超时，返回零推荐；独立读取主域名与 www 的三个搜索地址均在 12.5 秒超时，但作者文件和目录详情页分别约 1.2／1.4 秒成功。不是筛选通过便算交付，保留了该失败记录。现为场景用途索引命中的最多四份作品增加独立直读来源，核验已知作者路径，再从公开详情页读取使用量与 Star；不依赖搜索接口完成，也不把 curated 本身算作强推荐。K/M 安装数按原文保存，资格判断使用保守舍入下界，例如 0.5K 按至少 450 处理，不能冒充达到 500。点名路线不接入此通道。

## 验证与边界

- 三轮针对性失败回归分别捕捉用途入口／正文能力、双用途误判、多行简介／韩语范围，修复后转绿。
- 最终完整 `test-all.sh` 通过 474 项（437 普通、1 时限隔离、36 来源隔离）。包括搜索接口失效仍保留直读推荐、近似安装数不虚增门槛、九个合格结果无五个上限、热度与安装量分离、多行作者说明优先、API 示例不得冒充能力、以及既有精准名称 432 种表达组合与真实原句测试。432 种组合属于一项矩阵测试，不重复计数。
- 使用 13:51 正式应用保存的同一批真实候选，无网络重放最终规则及原用户记录里的模型理解条件，两种输入均保留六份推荐、包含指定四份，并排除 API 和韩语对象；不是换一批候选碰巧通过。证据 `scratch/scenario-discovery-fix/replayed-final-results.txt`。
- 中间真实核心对照加载完整 925 项目录、不开模型：27.8 秒、218 次资料请求、1 次 GitHub API，找回四份对象；当时 no-ai-slop 在其他候选，已据此定位并修复双用途误判。这个对照不冒充最终正式验收。
- 精确路线不带入场景别名，原八查询／十二次 API 上限保持。四份条目的来源为 [Humanizer](https://github.com/blader/humanizer)、[no-ai-slop](https://github.com/petergyang/no-ai-slop)、[human-writing](https://github.com/KKKKhazix/human-writing)、[khazix-writer](https://github.com/KKKKhazix/khazix-skills/tree/main/khazix-writer)。后者主要面向公众号长文与个人风格，不能等同于通用短文本改稿器。
- 此改动补齐本次领域的用途索引和已复现的处理缺陷，免费目录覆盖、其他媒体失败和核验预算仍会造成漏失；不承诺任意模糊描述能找到全网全部热门作品。

## 最终正式验收

- 最终安装路径 `~/Applications/SkillBox.app`，可执行文件 SHA-256 `fe3e2a555fb786590733cf525c590f5fab9587170e3b346feaad3d958c48791d`，运行进程 PID 19689。Release、包内隐私、严格签名与 `git diff --check` 通过。
- 14:16 用户原句 `推荐去文案AI味的skill。` 在正式窗口约 34 秒得到六份推荐：aboudjem/humanizer-skill、blader/humanizer、petergyang/no-ai-slop、kkkkhazix/khazix-skills 的 khazix-writer、KKKKhazix/human-writing、hardikpandya/stop-slop。没有 API 或韩语专用工具，也没有 `|` 简介。
- 逐份点击四个目标核对：Humanizer 43.4K Stars、no-ai-slop 7.3K Stars、khazix-writer 所属仓库 20.4K Stars、human-writing 3.5K Stars；原文近似值保持近似，Star 只属于仓库。完整六份均有使用量和仓库热度。
- 本轮 240 次资料请求、12 次 GitHub API、6 次复用，31 次追加被现有预算阻止；3 个来源未完成（含 YouTube 未参与）、6 个词失败、16 个正文未核验、1,427 个候选待后续核验。没有提高原有请求上限，也不能声称本次降低了总请求量或完成全网覆盖。14:03 的零推荐故障记录保留；故障测试确定在搜索接口全失败、详情和作者正文可读时仍保留有依据的推荐。14:16 网络已有部分恢复，因此不把该窗口说成搜索接口全断下的实测。
- 14:18 再用 `我找一下vibe-project-foundation-skill这个skill`，约一秒返回唯一正确对象 AidenXu-1/vibe-project-foundation-skill，15 次资料请求、1 次 API、零模型调用，精确查询仅含完整名称，没有进入新增用途通道。
- 本轮模糊搜索临时关闭发现 AI 开关，验收后已恢复，与本任务首次替换前 `ai-settings.json` 逐字节一致；精准搜索在开关开启时仍跳过模型。不消耗付费模型，不把该验收说成模型回答质量通过。原记录的模型条件已用真实候选重放通过。
- 最终旧应用与完整 755 项文件／链接备份 `~/Library/Application Support/SkillBoxBackups/20260906-141524/`，原子替换时数据逐字节未变。相对本任务首次备份，所有旧记录和文件保留；仅 catalog.json、library-state.json 在启动扫描时重新生成风险条目 ID，移除这些 ID 后内容一致，配置、安装与管理关系保持。新增验收记录保留，不清理用户内容。
- 最终三栏窗口已置前，停在六份推荐和 no-ai-slop 详情。截图 `scratch/scenario-discovery-fix/scenario-formal-final.jpg`；精准截图 `exact-outage-final.jpg`；结构化记录 `formal-outage-result.json`、`exact-final-result.json`、`data-final-audit.json`、`replacement-outage.json`。全量日志 `/private/tmp/skillbox-scenario-outage-full.log`，474 项通过。保留现有多切片工作区，不混合提交或发布。
