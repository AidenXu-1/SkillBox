# 备份与恢复第二轮独立评审

后续状态：以下为修复前的评审记录；六项问题已复核并修复，本机已更新 Build 12。验证与剩余边界见 [第二轮修复与验收](2026-09-13-backup-second-fixes.md)。

结论：未通过。评审提交 `f65e095`，用户要求再次调用子 Agent 检查。三个独立子 Agent 分别检查核心保留与恢复、App 备份登记与清理、启动/手动检查及界面恢复出口。主 Agent 回读调用链并复跑关键隔离复现，确认 6 项问题：1 项 P1、5 项 P2。第 4 项为上一轮修复新增的重试回归，其余为现有流程中此前漏检的问题。

本轮只评审，未修改产品源码、替换本机 App 或清理真实备份。下文为当前源码行号；隔离复现放在 `scratch/`，正式回归测试需在修复时加入 `app/Tests/`。

## 1. P1：启动恢复会先删完好安装，再发现备份不能使用

位置：`app/Sources/SkillBoxCore/SyncEngine.swift:441-445`，入口为 `app/Sources/SkillBoxApp/AppModel.swift:433`，启动检查在 `SyncEngine.swift:290-312`。

存在运行中更新记录，目标仍符合操作前或操作后指纹，但登记的救援备份已经缺失或损坏时，启动恢复只核对目标当前内容，随后直接删除目标并复制备份。缺失样例中，原本完好的安装被删除，恢复失败；损坏样例中，完好的安装被换成 `CORRUPTED BACKUP`，记录却标成已恢复成功。普通撤销新增的备份预检没有覆盖这条自动恢复路径。

主 Agent 复跑两个隔离样例得到相同结果。证据：`scratch/review2-retention/RecoveryProbe.swift`、`recovery-output.txt`、`recovery-root-confirmed.txt`。既存缺口，`restore` 源自 2026-08-14；`f65e095` 未修改该文件。修复应在任何目标变动前核对全部恢复来源，并在复制失败时保留当前内容。

## 2. P2：只更新保存版本后，界面无法确认恢复

位置：`app/Sources/SkillBoxApp/ContentView.swift:5421-5426`；关联 `SkillUpdateCoordinator.swift:35-38`、`ContentView.swift:5358-5359`。

用户选择“只更新我的 Skills”，成功后到“设置 → 操作记录与恢复”点击恢复。该事务有中央版本备份，`canRestore()` 为真，但安装动作数组为空。恢复窗只统计安装动作，显示“将恢复 0 个位置”，确认按钮因空数组一直禁用。尚未安装到应用的中央更新也受影响。

这是完整调用链可直接确定的界面条件问题，本轮未操作正式 App。现有 `centralOnlyUpdateUndo` 定向测试通过，因为直接调用底层撤销而没有经过按钮；日志 `scratch/backup-second-review-central-undo.log`。禁用条件源自 2026-08-28，空动作事务源自 2026-08-15。修复应把中央版本恢复作为独立、可确认的恢复对象。

## 3. P2：中央内容被外部改过时，组合撤销会只恢复一部分

位置：`app/Sources/SkillBoxCore/SyncEngine.swift:379-383`，缺少的当前中央内容预检在 `350-369`。

中央保存版本与 Agent 安装同时从 A 更新到 B，之后中央文件被外部编辑。撤销先把 Agent 安装恢复 A，才在 `LibraryStore.restoreSkillVersion` 核对中央实际文件并报错。隔离结果为中央外部内容保留、Agent 已是 A、事务仍为成功且安装记录仍记录 B，形成部分恢复与记录不一致。

主 Agent 复跑确认。证据：`scratch/review2-retention/UndoProbe.swift`、`undo-output.txt`、`undo-root-confirmed.txt`。既存缺口，非 `f65e095` 新增。修复应在第一次写入前核对中央实际内容，并处理后续步骤失败的恢复一致性。

## 4. P2：删除后登记失败，后续检查持续卡住

位置：`app/Sources/SkillBoxCore/AppRollbackBackups.swift:94-101`、`83-85`；Python 对应 `app/Scripts/rollback-backups.py:150-154`、`138-142`。

两份 App 备份都过期，清理先删最新份，再写登记。如果登记写入失败，最新目录已不存在，登记仍把它视为有效。解除写入问题后再次检查，新加入的替代备份核验报“最新备份已缺失”，旧过期份无法通过普通重试清理。

Python 注入登记写入失败，原生用隔离登记文件的临时文件锁触发真实写入失败，两端结果一致；锁已解除。主 Agent 另在临时目录复现 Python 路径。证据：`scratch/review2-app-backups/results.json` 的 `post-delete-registry-failure`、`scratch/backup-second-review-registry-root.json`。这是 `f65e095` 新保护条件与既有先删后登记顺序组合引入的重试回归。应可靠记录清理状态，使重启或重试能区分已清理与外部丢失。

## 5. P2：新备份失去运行权限，仍被当成完整替代份

位置：`app/Sources/SkillBoxCore/AppRollbackBackups.swift:155-163`；`app/Scripts/rollback-backups.py:68-78`。

通过正常登记创建两份备份后，把新份中可执行文件权限从 0755 改成 0644。文件字节没变，摘要也没变；实际运行已报 `Permission denied`，两端清理仍删除旧完整份。空目录被替换成特殊文件也会漏检，因为摘要把所有非普通文件、非链接都记成目录。

证据：`scratch/review2-app-backups/permissions-results.json` 和 `probe_permissions.py`；特殊文件补充见 `results.json`。这是既存摘要缺口，原生源自 `dc29a2f`、Python 源自 `5fda112`。权限验证使用隔离可执行脚本，没有声称做过真实 App 恢复。应补充影响可恢复性的类型和权限验证，并兼容旧登记格式。

## 6. P2：清理失败后，界面仍显示已经失效的恢复入口

位置：`app/Sources/SkillBoxApp/AppModel.swift:1597-1600`；关联 `LibraryStore.swift:224-245`。

升级遗留的两条近期同位置成功记录，需要淘汰较旧一条。核心先持久化旧记录的失效标志，再删文件；删除因权限失败后，界面只显示错误，没有重新读取记录。隔离调用实际 AppModel 证明：存储中的旧记录已不可恢复，界面仍认为可恢复，并允许打开预览。底层最终会拒绝，未证明误删，但用户看到了无效的操作入口。

证据：`scratch/review2-flow/probe.swift`、`probe.log`，删除失败只注入隔离 FileManager；主 Agent 回读确认先持久化、后删除和失败出口漏刷新。修复应在失败出口也同步最新恢复状态。

## 文档和验证边界

- `docs/spec.md:417` 仍保留“至少 30 天、至少 10 个事务”，与顶部 v2.58 的一份/7 天冲突；应同步旧条款。该项不计入 6 个代码问题。
- 现有 20 项备份 Swift 专项、12 项 Python 专项、1 项中央更新撤销测试均通过。日志为 `scratch/backup-second-review-swift.log`、`scratch/backup-second-review-python.log`、`scratch/backup-second-review-central-undo.log`；这些测试尚未覆盖本次发现，不能据此宣称无 bug。
- 本机 Build 11 与现有 Release 构建程序 SHA 一致：`9725652bff794560bae3b5326b80b8c366dfddcf5ad4006a8fe1abb1990f3705`。只读登记仍显示唯一 Build 10 回退套组，9 月 20 日 15:25 到期。
- 没有执行真实清理、磁盘满、断电或正式 App 的破坏性实验；登记重复 ID 和仅用钩子模拟的并发窗口不列正式问题。启动补检去重、正常手动入口及上一轮七项修复的常规回归本轮没有发现其他确定问题。
