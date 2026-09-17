# 手动删除安装副本后的状态修复

用户确认：修改过的 WorkBuddy 安装副本被保护而无法卸载，随后手动删除真实目录，SkillBox 多次刷新仍显示“内容后来被改过，暂时不能移除”。

## 原因与修复

旧安装记录仍在，计划把不存在的目录指纹当作内容变更，界面沿用冲突标记。启动和手动刷新现在先核对受管理的实际位置：根目录可列举、安装位置是其直接子项且 lstat 明确返回 ENOENT，才清除旧安装关系、取消期望安装及旧覆盖授权。不改中央内容，不自动重装。

仍存在的修改内容、失效软链接、根目录缺失或无法读取、未完成恢复涉及的位置保留。保存失败恢复内存状态，最后一次完整快照仍用于重启恢复。

## 验证

- 先复现“修改、拒绝卸载、手动删除、刷新”的失败，再验证已安装期望为开/关的两种情况；重启保存状态正确。
- 补充缺失根目录、失效链接、存在目录、未完成恢复和保存失败回归。
- `app/Scripts/test-all.sh` 退出 0：Swift 608 项实际通过、1 项既有公网跳过；Python 28 项通过，合计 636 项通过。
- Release 构建、严格签名、隐私检查与 `git diff --check` 通过。
- 本机 `~/Applications/SkillBox.app` 更新为 0.2.4 Build 17，程序 SHA-256：`2b3a7ba8a58db9f78ea81d96b47e9e8f141d240a3f281f31729140385efebdf5`。
- 实际窗口启动后 WorkBuddy 对应格显示“点击安装到 WorkBuddy”和 plus 图标，手动点击刷新仍保持正确；未点击安装。
- 真实资料比对：仅移除目标旧安装记录，安装记录从 7 条变 6 条；其余关系、全部期望安装记录和分类一致；5 份中央 Skill 的 110 个文件一致。启动例行扫描的风险发现随机 ID 重新生成，其他 Skill 元数据一致。目标目录仍不存在。

## 回退与范围

更新前退出应用，依一份/7 天规则保存 Build 16 和完整资料，新备份核验后淘汰上一份登记备份。当前回退资料：`scratch/rollback-backups/20260917-114800-beb5d753-c7b2-41eb-935d-6a3749f84bc1`，到期时间 2026-09-24 19:48（中国时间）。未公开发布。

本轮日志：`scratch/deleted-copy-red.log`、`scratch/deleted-copy-all.log`、`scratch/deleted-copy-package.log`、`scratch/deleted-copy-backup.json`、`scratch/deleted-copy-data-result.json`。
