# 应用内更新发布前复核

日期：2026-09-17。审查产品提交：`6dd60f4`（0.2.5 Build18）。结论：暂缓发布，有2项P2交互问题待修复。本轮不修改产品代码、不重装、不发布。

补修状态：用户确认后，以下两项已在Build19修复并实测通过，见[补修记录](2026-09-17-update-review-fixes.md)。下文保留原始审查证据。

## 发现

### P2：后台发现新版没有用户可见的提醒

位置：`app/Sources/SkillBoxApp/ApplicationUpdater.swift:178-187`。

自动检查发现新版时，`state.userInitiated`为false，更新对象只写入available状态；`showUpdateInFocus`只在用户主动检查时调用。其余页面没有观察更新状态并提供提醒的入口。用户一直停在“我的Skills”等页面时，看不到新版提示；必须自行打开“关于”。这与开关“发现新版本时提醒你”的承诺不符。

真实Sparkle后台检查探针输出：`phase=available, focusRequested=false, canCancel=false, action=下载更新, session=true`。源码搜索确认更新状态只在关于页展示，排除了其他提醒出口。自动下载准备完成的代理同样只改关于页状态。

建议：提供不会抢走当前操作的轻量更新提醒或明显入口，并验证用户不在关于页时能发现、进入更新。无需新增系统通知权限。

### P2：发现新版后无法选择稍后，检查会话无法正常结束

位置：`app/Sources/SkillBoxApp/AboutSettingsView.swift:65-71`；`ApplicationUpdater.swift:183-187`。

发现新版后将`canCancel`置false，页面只留下下载按钮；没有“稍后”或跳过入口向Sparkle返回dismiss/skip。切换页面也不结束会话。用户暂不接受当前版本、继续保持App打开时，这次检查一直等待；再次点击菜单“检查更新”仅聚焦旧结果，不重新请求更新源。该会话结束前也不会安排下一轮自动检查。

真实探针在收到新版后再次手动检查，前后均`session=true`、`phase=available`，HTTP服务器总计只有一次`GET /appcast.xml`。固定依赖`SPUUpdater.m`的显示中分支直接聚焦后return，下一轮检查安排在会话完成回调；`SPUUIBasedUpdateDriver.m`提供了dismiss结束该阶段的正常路径，当前UI无法触发。

建议：添加“稍后”并确实调用本次选择回调结束会话；测试稍后后可重新检查、更晚的新版可被发现。不要用定时关闭界面来冒充结束后台会话。

## 已通过的复核

- 27项相关测试通过：更新按钮单次执行与繁忙等待、取消、错误状态、版本比较、删除提示计时/暂停与历史恢复、设置导航。
- 独立使用CryptoKit与已安装App内的公钥验证待发ZIP Ed25519签名成功，不读取私钥。
- ZIP摘要、DMG摘要、清单长度与构建号一致；ZIP内App元数据、程序与本机已安装App及发行清单一致。
- 固定Sparkle framework和许可比对、发行隐私检查通过。
- 复核此前实际18→19同路径升级、签名拒绝、20不降级及资料保留的回执；这些属于上一轮实测证据，本轮未重新安装或复制用户资料。
- 未发现需要为普通更新新增用户资料备份的理由；现有无全量备份方案保持。

本轮新探针及回执：`scratch/about-updates-final-review/background-probe.log`、`background-requests.json`、`targeted-tests.log`、`artifact-checks.json`、`privacy.log`。临时后台探针App已清理，未改动本机正式App。

## 发布边界

公开更新源与v0.2.5尚未发布；这属于待执行的发行步骤，不计为产品缺陷。修复上述两项后应重新验证相关真实路径并生成对应发行包。当前不将本次review标记为通过，也不沿用上一轮准备就绪的结论直接发布。
