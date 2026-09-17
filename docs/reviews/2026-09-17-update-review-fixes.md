# 发布前两项更新交互补修

日期：2026-09-17。用户已确认“修复吧”。版本0.2.5 Build19。

## 修复与复核结论

此前最终复核的两项P2已修复并验证：

1. 后台发现新版或准备完成时，非关于页工具栏显示“有新版本/更新已就绪”。点击进入同一关于页，不自动切换页面、不抢焦点、不申请通知权限。在关于页不重复显示工具栏提醒。
2. 关于页待下载的新版增加“稍后更新”。实际消费本次选择回调并返回dismiss，结束Sparkle会话；重复点击只执行一次。后续仍可自动或手动检查。已准备安装的更新保持原有等待重启流程。

[原生工具栏提醒](../../design/ui/about-updates-20260917/native-update-reminder.png) · [原生稍后更新](../../design/ui/about-updates-20260917/native-update-later.png)。沿用已确认原生布局，HTML预览同步补充按钮。截图中的0.2.6/0.2.7属于本地样本，不代表公开发行。

## 本轮验证

- 更新交互9项测试通过，新增覆盖后台提醒不抢焦点、稍后只执行一次、后续新版能接受或延后、安装准备阶段保持。
- 真实Sparkle探针连续三次检查：后台0.2.6→稍后→后台0.2.7→稍后→手动0.2.8。每次稍后后session=false、canCheck=true，服务器实际收到3次GET；前两次未请求聚焦，第三次手动检查请求聚焦。它复用了实际ApplicationUpdater代码，未模拟检查完成回调。
- 完整原生App的独立资料窗口自动发现0.2.6，停在“我的Skills”显示提醒；点击进入关于页，选择稍后，再次检查发现0.2.7，服务器实际记录2次GET。没有下载或安装样本更新。临时测试App已关闭并清理。
- 完整release-distribution通过：全量Swift测试（1项既有公网跳过）、Python28项、Release构建、固定Sparkle文件与许可、严格签名、隐私、图标、DMG及ZIP/appcast签名检查。沿用已知无Developer ID/无Apple公证发行方式。

证据：忽略目录 `scratch/about-updates-fixes/` 内的tests.log、background-probe.log、background-requests.json、native-requests.json、release.log和local-install.json。

## 本机及发行状态

本机原位置 `~/Applications/SkillBox.app` 已更新并启动0.2.5(19)，原有5份Skill保留。替换过程中175个资料文件完全一致；正常启动仅刷新3份扫描状态，172个其他文件保持。没有复制用户资料，替换用的临时旧App已清理。安装程序SHA-256：`f805f5f03023519f2622e2927d1f0d239d6fd6f6d70d1227a8ff6b4fe8ab24d5`，与本地发行包一致。

本地DMG、更新ZIP、清单及校验文件已重生成，构建号统一19。公开仓库和更新源尚未发布，本轮不执行发布；后续发行使用本轮产物，不使用旧Build18包。本次只重新验证受影响的交互，普通覆盖升级、拒绝签名错误和较新版本不降级的安装机制沿用此前验证，相关实现未改动。
