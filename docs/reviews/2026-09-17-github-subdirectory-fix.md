# GitHub 子目录添加与中文请求修复

日期：2026-09-17。状态：已更新本机 0.2.4 Build 15，两个原始入口真实窗口验收通过。未公开发布。

## 原因与改动

1. 添加 GitHub 子目录时，原实现先展开并审查整仓库。同仓库 `neat-freak/evals/fixtures` 中的 5 个软链接导致 `storage-analyzer` 被拒绝。统一添加与更新的展开流程，仅展开所选目录；所选目录内软链接仍拒绝，整包路径穿越与资源上限仍检查。整仓库、Release ZIP 保持原范围。对 unzip 模式中的通配符转义，避免特殊目录名扩大范围。
2. 发现入口把紧接网址的“帮我找到这个Skill”当作目录名。现在识别中文请求和标点边界，保留合法中文目录名。

## 验证

- 修复前：原句解析测试和同仓库兄弟目录含软链接的添加测试均失败，与用户故障一致。
- 修复后：同仓库其他目录隔离、当前目录链接拒绝、更新快照、原句解析通过。目录名 `demo[1]`、`demo*`、`demo?` 的 3 个参数样例通过，未展开其他目录。
- `app/Scripts/test-all.sh` 退出 0：Swift 汇总 604 项含 1 项原有公网跳过，即 603 项实际通过；Python 28 项通过。另补验 1 项通配符测试（3 个参数样例），合计 632 项实际通过。
- Release 构建、严格签名、包隐私检查、`git diff --check` 通过。
- 本机真实窗口：从“我的 Skills → 添加 → GitHub”输入用户原网址，选择默认分支，预览准确显示 storage-analyzer，点击添加后显示“已加入我的 Skills”，总数由 5 变为 6。
- 本机真实窗口：在用户原失败对话里重新发送 `https://github.com/KKKKhazix/khazix-skills/tree/main/storage-analyzer帮我找到这个Skill。`，显示推荐 1 个 storage-analyzer、已加入。落盘路径为 `storage-analyzer`，结果 `exactFound` / `completed`，1 次网络请求，0 个失败核验、未调用 AI。
- 更新后原 114 个内容与关系文件核对：添加前全部一致；添加后仅 organization.json 增加新 Skill 的末尾位置，原分类和排序条目完整保留，其余 113 个文件一致。
- SkillBox 保存内容与已全局安装到 Codex 的 storage-analyzer 7 个文件逐一一致；未执行 Skill 扫描或清理脚本。

## 本机身份与回退

- 当前 App：`/Users/aiden/Applications/SkillBox.app`，0.2.4 Build 15。
- 程序 SHA-256：`116fe03eea985bb71a19b8fe56c98493f14d341c3c18744854c2ffa068a6cf29`。
- 更新前退出 App，通过现有脚本建立上一版 App 和完整用户资料备份；按已有一份/7天规则淘汰被替代的旧备份。
- 本次备份：`/Users/aiden/AidenWorkflow/2-AI/01产品开发/01APP/SkillBox/scratch/rollback-backups/20260916-190231-333074d7-229f-4ed3-8980-02d29dc840f5`。登记到期为北京时间 2026-09-24 03:02。
- 测试、打包、备份回执与落盘核验：`scratch/storage-analyzer-diagnosis/`。
