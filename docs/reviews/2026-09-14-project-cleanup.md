# SkillBox 项目文件清理评估与结果

用户已明确要求盘点、评估后清理。本轮只处理项目内已结束任务的临时产物和可再生缓存，采用保留原相对路径的废纸篓移动，可按清单移回。废纸篓不自动清空，磁盘空间暂未真正释放。

保留：全部 348 份 Git 跟踪文件及 Git 历史（含正式测试、设计原件、文档）；正式安装 Build 13 及同摘要构建 App；公开 v0.2.3 安装包、校验文件、来源清单；唯一尚未到期的 Build 12 与配套资料备份及登记入口；本轮最终验收日志和关键交付记录。没有活跃测试/构建进程。构建脚本不依赖 scratch 内的旧实验文件；正式代码使用的设计图标保留。清理缓存后下次构建需要重新生成，不影响当前已安装 App。

旧实验的原始日志与临时探针移入废纸篓，docs/reviews 中的正式结论继续保留。旧记录若指向已清理 scratch 路径，可根据本清单在废纸篓找到。

## 执行结果

- 2026-09-14 已移动清单中的 135 项、4,965 个文件，共 1,418,981,147 字节（约 1.42 GB），包含 4 个独立 QA App；逐项回读核对文件内容和符号链接，全部一致。原项目路径已不存在，恢复时按本清单保留的相对路径移回。
- 废纸篓目录：`~/.Trash/SkillBox-project-cleanup-20260914-015245`。废纸篓未清空，仍可恢复，磁盘空间尚未真正释放。
- 全部原有 348 份版本管理文件在移动前后逐字节一致；正式安装 App、当前构建 App、公开发行三个文件、有效回退备份和稳定的用户资料快照均一致。正式 App 与构建 App 严格签名通过；公开 DMG 和来源清单的 SHA 校验通过。
- 首次保护校验因运行中的 App 刷新 `library-state.json` / `local-source-state.json` 而停止，尚未移动任何文件。确认 174 个内容文件及 Skill/分类/安装关系保持后正常退出 App，刷新资料基线并执行；清理后资料整树与稳定基线一致。
- 唯一 Build 12 与资料备份约 79 MiB，2026-09-20 20:33 到期，目前应保留。原生登记路径和 registry 未移动，维护预览为空。
- 项目目录现约 164 MiB（约 170 MB），其中约 83 MiB 是有效备份及关键验证记录，构建目录约 16 MiB 保留当前 App 和公开安装包。历史设计原件及正式文档有参考价值，未因年代旧而删除。
- 正式 SkillBox 已重新启动，界面显示 4 份 Skill 与“备份检查完成”；未打开测试应用。本轮未修改产品代码，不重复构建/测试来重建刚清理的缓存，也未公开发布。
- 本地完整盘点、哈希及执行回执：`scratch/cleanup-20260914/inventory.json`、`receipt.json`。此前 docs 中引用的旧 scratch 原始证据可依下表在废纸篓寻找；正式验收结论保留。

## 精确移动清单

已移动 135 项，4965 个文件，共 1,418,981,147 字节。

|路径|MiB|理由|
|---|---:|---|
|`scratch/SkillBox-v0.2.1-release-notes.md`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-20260913`|0.011|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-before.json`|0.048|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-final-install.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-final-verification.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-flow-red.log`|0.005|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-full-tests.log`|0.147|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-package.log`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-privacy.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-python.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-real-copy-expiry.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-rotation.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-targeted.log`|0.007|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-fix-verification.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-before.json`|0.048|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-full-tests.log`|0.143|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-package.log`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-rotation.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-targeted-tests.log`|0.003|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-launch-verification.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-before.json`|0.048|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-final-verification.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-full-tests.log`|0.154|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-installed.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-package.log`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-presentation-green.log`|0.006|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-presentation-red.log`|0.003|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-privacy.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-real-compat.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-rotation.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-ui-cancel.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-ui-final-cancel.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-repair2-ui-final-restored.json`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-before.json`|0.053|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-debug.log`|0.004|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-full-tests.log`|0.143|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-package.log`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-rotation.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-tests.log`|0.007|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-retention-verification.json`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-review-20260913`|60.539|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-second-review-central-undo.log`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-second-review-python.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-second-review-registry-root.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/backup-second-review-swift.log`|0.006|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/blind-release-review`|0.718|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-app-backup-audit`|0.020|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-app-cleanup-red.log`|0.006|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-flow-audit`|236.783|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-full-tests.log`|0.160|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-install.py`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-installed-before-update.json`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-related-green.log`|0.038|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-ui-build.log`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/bounded-update-audit`|40.277|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/category-box-20260908`|0.121|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/cleanup-blind-review-20260907`|0.197|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/cleanup-execution-20260907`|1.339|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/discovery-outcome-fix`|1.501|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/discovery-result-first-preview.html`|0.005|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/discovery-review-20260905`|0.039|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/discovery-review-fix-20260907`|0.173|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/discovery-risk-review`|0.004|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/drag-slot-evidence`|31.773|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/empty-folder-cleanup-20260901-0115`|0.104|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/final-review-app-backup`|30.285|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/final-review-core`|40.284|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/final-review-flow`|90.464|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/final-review-python.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/final-review-swift.log`|0.018|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/folders-first-20260908`|0.125|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/github-release-022`|0.236|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/github-release-023`|0.296|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/hierarchy-20260908`|0.125|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/install-discovery-result-fix.sh`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/install-evidence`|1.649|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/installation-fix-20260908`|0.020|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-fix-20260913`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-full-tests.log`|0.141|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-package.log`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-preview-tests.log`|0.002|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-privacy.log`|0.000|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-refresh-red.log`|0.006|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/local-source-refresh-tests.log`|0.007|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/named-request-fix`|3.064|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/named-request-regression`|5.885|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/organizer-fix-20260908`|0.132|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/package-cleanup-inventory-20260906`|3.883|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/preview-render`|0.231|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/render-library-reorder-v22.cjs`|0.001|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/request-budget-fix`|1.138|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/review2-app-backups`|81.642|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/review2-flow`|157.772|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/review2-retention`|42.946|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/scenario-discovery-fix`|1.444|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`scratch/source-leading-20260908`|0.121|已结束任务的临时实验、测试副本或历史原始日志；正式结论已存 docs/reviews|
|`app/.build/(A Document Being Saved By swift-test 2)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 3)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 4)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 5)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 6)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 7)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test 8)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/(A Document Being Saved By swift-test)`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/.lock`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/artifacts`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/build.db`|0.199|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/checkouts`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/debug`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/debug.yaml`|0.133|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/module-cache`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/plugin-tools.yaml`|0.133|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/release.yaml`|0.131|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/repositories`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/swiftpm-cache`|0.601|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/workspace-state.json`|0.000|可由构建脚本重新生成的编译或测试缓存|
|`app/.build/arm64-apple-macosx/debug`|410.270|可重新生成的调试与测试构建产物|
|`app/.build/arm64-apple-macosx/release/ModuleCache`|64.522|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/Modules`|3.675|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBox`|15.092|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBox.product`|0.007|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBoxApp.build`|11.633|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBoxCore.build`|9.869|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBoxCoreTests.build`|0.036|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBoxDiagnostics.build`|0.001|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/SkillBoxPackageTests.build`|0.001|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/description.json`|0.162|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/plugin-tools-description.json`|0.162|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`app/.build/arm64-apple-macosx/release/swift-version--58304C5D6DBC2206.txt`|0.000|可重新生成的发行构建中间文件；完整当前 App 已保留|
|`.DS_Store`|0.006|系统索引或 Python 自动缓存|
|`design/.DS_Store`|0.006|系统索引或 Python 自动缓存|
|`app/.DS_Store`|0.006|系统索引或 Python 自动缓存|
|`app/Tests/.DS_Store`|0.006|系统索引或 Python 自动缓存|
|`app/Sources/.DS_Store`|0.006|系统索引或 Python 自动缓存|
|`docs/.DS_Store`|0.006|系统索引或 Python 自动缓存|
