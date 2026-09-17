# ADR-0023：应用内更新使用 Sparkle

- 状态：已采纳，用户确认按预览与简化备份方案实施
- 日期：2026-09-17
- 对应：Spec v2.61

## 决定

使用固定版本 Sparkle 2.10.0，锁定 SwiftPM revision。设置“关于”和应用菜单共用一个更新对象；默认每天自动检查、默认不自动下载。下载完成由用户选择重启，也可正常退出后安装；Skill 文件操作期间不通过更新入口重启。按构建号比较版本。

Sparkle 负责下载、验证和原位置替换，不向更新器传入用户资料目录。不为普通 App 更新复制中央 Skill、安装副本、来源、分类或寻找记录，也不额外建立七天全量备份。替换过程使用框架的临时下载和暂存目录；成功清理，失败保留原应用。原有 Skill 操作恢复规则保持独立。

公开清单地址为仓库默认分支 `master` 下的 `appcast.xml`。ZIP 和清单使用 Ed25519 签名，私钥只保存在本机钥匙串的专用账户；源码与 App 只保存公钥。发行脚本本地生成并验证签名，不自动上传。默认分支已通过远端 HEAD 实际核对，不从旧文档推断。没有可达更新源时呈现失败，不能宣称最新。

## 与现有无证书发行的兼容

延续 ADR-0010 的 ad-hoc Hardened Runtime。官方 Sparkle framework 保持原始签名及文件；主 App 使用仅含 `com.apple.security.cs.disable-library-validation` 的 entitlement，允许无 Team ID 的主 App 加载官方签名 framework。这是主 App 范围的运行库验证例外，不更改系统 Gatekeeper、隐私权限或更新包签名要求。打包核验将 framework 的文件内容、模式与符号链接逐项对照固定依赖，不允许通过笼统跳过依赖来绕开包态检查。

依据：[Sparkle 官方接入文档](https://sparkle-project.org/documentation/)，以及固定依赖内的 `Sparkle/SPUUserDriver.h`、`SPUUpdaterDelegate.h`、`SUErrors.h` 和 `Autoupdate/SUPlainInstaller.m`。本轮没有引入购买证书或 Apple 公证流程。

## 取舍与验证

自行编写替换器会扩大安装、签名和退出协调的维护范围；跳转下载网页无法提供应用内更新。使用公开框架的安装流程，应用层只负责原生设置界面和用户选择。

隔离测试宿主复用实际 ApplicationUpdater：18→19 同路径替换并重启成功，样本内容保持；签名不匹配时拒绝安装且旧版18保持；本机20面对源19不下载、不降级。完整 SkillBox 的删除、恢复、关于和开关通过独立原生窗口验证。完整生产 App 经公网跨版本更新仍需发布后验证，不能以测试宿主代替该项结论。

旧版0.2.4没有更新器，用户必须手动安装一次0.2.5，之后方可应用内升级。
