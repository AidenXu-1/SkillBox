# 具体 Skill 名称漏找修复

## 真实失败与根因

正式应用记录中，`wechat-layout-publisher找一下这个skill` 被识别为 scenario，返回 wechat-article-publisher 等五个近似用途对象，144 次资料请求／12 次 GitHub API。`帮我找一个叫Agent-Team-Skill的开发Skill。` 同样为 scenario，返回 team 等三个对象，243 次资料请求／12 次 GitHub API。

名称提取只覆盖少数固定语序，漏掉名称在句首、名称紧贴中文、直接输入名称与“叫／名为”句式。`Agent Team Skill` 又只提取最后一个 Team。模型规划虽然保留原词，但路由仍为场景，扩展查询后无法保证最终对象相同。

第二层是召回渠道：skills.sh 对这两个名称返回大量词语相近对象；GitHub 原实现只提供需要登录的代码搜索，没有公开仓库名称搜索。正确识别名称后仍可能漏找。另有仓库名与根目录 Skill 声明名不同的情况，AidenXu-1/agent-team-skill 根文件声明 agent-team。

## 修改

- 先提取明确的命名语句、完整多词名称和常见完整标识，避免中文单词边界导致漏匹配。
- 精确名称使用独立来源组合，目录近似名称在正文核验前过滤，不调用媒体、模型规划或模型排序。
- GitHub 每次精确名称读取一页公开仓库信息；只核验最多五个同名、公开、未归档且未禁用仓库，每仓库最多三个固定正文位置。共享现有请求预算，不递归或无限翻页。
- 真实根 SKILL.md 可按仓库名定位；集合仓库的无关子 Skill 不继承仓库名。多个真实同名对象保留作者，来源未查完如实显示。
- Spec v2.43；未改变三栏、增加付费服务或将本地库上传。

## 证据

- 六种自然名称输入的修复前测试出现 16 项失败断言；第二层模拟测试确认仅改路由仍找不到未收录的仓库，并浪费近似正文请求。
- 修复后 15 项初步定向检查通过，最终完整脚本 458 项通过（421 普通、1 独立时限测试、36 来源隔离）。覆盖原句、完整名称、作者与场景保留、公开仓库召回、仅一次 API、跳过无关正文、根与子目录身份、应用最终候选及零模型诊断。
- 使用当前生产核心、匿名公开来源重放两句原话，没有读取用户密钥或调用模型。`Agent-Team-Skill` 用时 5.887 秒，13 次资料请求／1 次 GitHub API，找到 AidenXu-1/agent-team-skill（声明 agent-team）及 realqiyan/agent-team-skill 两个真实对象；另外三个同名仓库未完成正文核验，未混入结果。
- `wechat-layout-publisher` 用时 1.103 秒，4 次资料请求／1 次 GitHub API，找到 AidenXu-1/wechat-layout-publisher 的同名 Skill。此前只根据本机本地来源登记和未命中的检索不足以判断公开状态；真实仓库搜索纠正了这一点。
- 原始计数 `scratch/discovery-outcome-fix/exact-name-live.jsonl`。这证明当前两句真实输入的公开召回与核心结果，不代表全网无限覆盖，也不替代正式窗口核验。

已有多个切片处于未提交状态，本次保留它们，未混合提交或公开发布。

## 正式应用验收

Release 构建、隐私检查、严格签名与差异格式检查通过。11:36 将本次修复替换到 `~/Applications/SkillBox.app`，可执行文件 SHA-256 `573cf52af0a7e7b7478efa552faa1b6d138b9e4924200c6b35558191032d3099` 与构建一致，当前进程 PID 96056 来自正式路径。旧应用和完整数据保留在 `~/Library/Application Support/SkillBoxBackups/20260906-113644/`；AI 设置、分配、安装关系、分类与目标文件逐字节未变。

在正式应用新建两条验证记录，保留原失败记录，用原句实际点击发送：

- Agent-Team-Skill：11:38:03 至 11:38:09，最终两项，AidenXu-1 的 agent-team 首位且标记已加入，另一项为 realqiyan/agent-team-skill。最终列表、选中对象和右侧作者说明一致。
- wechat-layout-publisher：11:39:06 至 11:39:08，最终一项，作者为 AidenXu-1，详情指向其真实 `wechat-layout-publisher/SKILL.md`；旧近似推荐没有进入这条新结果。

正式包包含完整内置目录，每轮比独立核心重放多 12 次目录资料读取。因此正式应用的完整请求数分别为 25 与 16，不能用前述 13 与 4 冒充正式计数。两轮各 1 次 GitHub API、0 次预算阻止，模型诊断为空，未调用模型。记录均为部分完成，已核验的精确对象仍正常交付；没有宣称全部公开来源均已查完。截图为 `scratch/discovery-outcome-fix/exact-agent-team-formal.jpg` 和 `exact-wechat-formal.jpg`，记录摘要 `exact-name-formal.json`。正式窗口停留在公众号 Skill 结果页。
