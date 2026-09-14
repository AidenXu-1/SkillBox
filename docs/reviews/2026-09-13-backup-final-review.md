# Build 12 备份与恢复最终独立评审

结论：未通过。评审目标为 `cdc59f7`，三个新子 Agent 独立检查核心恢复、App 备份清理和用户入口；主 Agent 回读源码并复跑全部发现。确认 1 项 P1、1 项 P2，另有 1 项不影响数据保护的 P3。仅评审和隔离验证，未修改产品、真实资料、真实备份或本机 App。

## P1：更新失败后的回拷再次失败，当前内容及唯一旧归档可能丢失

位置：`app/Sources/SkillBoxCore/LibraryStore.swift:693-697`，状态写入在 `SkillUpdateCoordinator.swift:52-56`，清理规则在 `BackupRetention.swift:25-47`。

用户确认只更新“我的 Skills”，新内容已替换成功，但保存记录失败。现有异常处理先删除当前内容，再尝试复制旧归档；复制也失败时忽略错误。协调器仍将操作记为 `rolledBack`。后续备份清理不把它视作未完成救援，删除唯一旧归档；重启也不再恢复这条记录。

主 Agent 使用当前核心对象及真实 `SkillUpdateCoordinator.updateCentralOnly` 入口复跑：注入一次保存空间不足错误，再让恢复复制同样失败，得到当前目录不存在、记录 `rolledBack`；调用真实清理后归档也不存在；重新打开资料并启动恢复，处理 0 条，内容仍缺失。对照组只让保存失败，允许恢复复制，则当前内容完整，排除了普通单次失败误报。

证据：`scratch/final-review-core/update-failure.swift`、`primary-failure.log`、`primary-control.log`。使用 FileManager 故障注入，没有实际耗尽硬盘；开发源仍保留，不能描述为电脑上所有副本丢失。该异常处理行始于 `b5b81760`，属于旧更新分支遗漏，与 Build 12 修复的手动恢复分支不同。

修复应先准备并校验恢复副本，再安全替换；补偿失败保留明确失败状态及救援内容，禁止按已完成回退清理。

## P2：备份删除到一半失败后，解除原故障仍不能重试

位置：`app/Sources/SkillBoxCore/AppRollbackBackups.swift:155-163`，重试校验 `118-125`；Python 对应 `app/Scripts/rollback-backups.py:233-239`、`189-204`。

备份中一个文件在登记前已带 macOS Finder 锁定标志，登记摘要仍正确。真实递归删除先移除了其他文件及登记标记，随后因锁定文件报权限错误。解除锁定后，新 Python 实例及全新原生进程各重试两次，仍因登记标记已被自身删除而失败。目录与 `removalStartedAt` 持续保留。

主 Agent 用 `python3 scratch/final-review-app-backup/probe.py` 复跑，两个生产实现结果一致。原生探针直接编译未修改的 `AppRollbackBackups.swift`，没有替换删除函数。输出 `scratch/final-review-app-backup/primary-confirmation.log`；每次使用新的 UUID 隔离目录，结束后清除测试文件锁定。

这使到期残留无法通过启动或手动检查清除，且会阻碍后续批次清理。修复需记录可验证的逐步删除进度，同时保护尚存文件的外部改动；不能简单跳过完整性检查。

## P3：恢复受阻后，历史状态暂未刷新

位置：`app/Sources/SkillBoxApp/AppModel.swift:3474`。

安装副本被外部修改后点击恢复，执行层正确阻止并保存 `undoBlocked` 与错误；界面失败出口只弹出错误，历史仍保留原 `succeeded` 状态及空错误列表。右上角刷新后显示正确。

主 Agent 复跑 `scratch/final-review-flow/probe scratch/final-review-flow/primary`：错误弹窗明确、外部内容保留、再次恢复仍会阻止覆盖。该项仅为非阻断的显示问题，不能称为误报恢复成功或数据覆盖风险。证据 `scratch/final-review-flow/primary-confirmation.log`。

## 通过项与边界

- 本轮重跑 10 组相关 Swift 测试共 66 项、Python 21 项，均通过；日志 `scratch/final-review-swift.log`、`scratch/final-review-python.log`。现有测试未覆盖上述更新双重失败及部分删除边界，不能代替异常验证。
- 三组覆盖了恢复来源核对、组合补偿、外部修改、原生/Python 摘要兼容、权限/类型、七天/一份、启动排队与手动入口、本地来源迟到结果保护；未将已被保护阻止的情况列为缺陷。
- 本轮只读核对正式 App 仍为 0.2.3 Build 12，SHA `e7c5f5075b95d01f71e923e083e46c3373fae43d4cd54e309e34a927967bd101` 与上一轮已安装产物一致。
- 本轮未做新的真实前台操作、真实磁盘耗尽、断电或跨磁盘试验，也未公开发布；这些评审发现尚未修复。
