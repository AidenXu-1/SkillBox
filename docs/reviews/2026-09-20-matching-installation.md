# 已安装内容一致但历史记录落后的修复

## 根因与复现

实机 GPT github-readme-design 的记录仍为 `1b7e8e917c5c2d6dd7e036d1db4849bc12b2ed779358d300688aa5557d35e346`，中央当前版本与 GPT 目录完整指纹均为 `3f3b160087414a65c95fff2993059375ea7d71623930f7ed9e9c79f70758cc8a`。三份正文文件集合、字节与权限一致，无 .DS_Store 干扰。旧同步计划先检查当前副本与部署记录，不一致即阻断，未先校正已经达到目标状态的副本。不能从此证据推断究竟哪个程序修改了文件。

新增 refreshRecognizesMatchingCurrentVersion 测试在旧实现下明确失败：计划为 blocked，记录仍旧；修复后通过。日志 scratch/converged-red.log、converged-green.log。

## 修复

LibraryStore 在 AppModel.reload 读取快照前核对受管、仍期望安装的副本。只有路径归属正确、源与目标均为实际目录、真实中央指纹符合目录记录、完整目标指纹一致且没有相关未完成恢复时，更新安装记录的 deployedFingerprint。持久化失败恢复旧内存；不改文件、不改历史部署日期或事务、不自动接管非受管内容。完整校验保持默认规则，不忽略隐藏文件或权限。

原有拦截文案调整为“当前内容与上次安装记录不一致”，不推断修改者。

## 验证与安装

- 完整测试退出 0：Swift 报告 630 项，629 实际通过、1 公网跳过；Python 28 项通过。边界覆盖正文不同、额外文件、权限、中央内容变化、目录链接、恢复中、不期望安装、保存失败和重开持久状态。
- release 打包、签名、隐私检查通过。本机 0.2.5 Build 24，程序 SHA `28d6d380df79daa8a37137a706543bc7860b838153f38ee3b9a8f728adda7505`。
- 原位置替换期间核对 168 个资料文件一致。新版启动自动校正 GPT 安装记录，实机安装列表显示 github-readme-design GPT 已安装；ai-news WorkBuddy 的真实不一致仍保留。GPT 三个文件的字节、权限、修改时间全部未变。
- 证据 scratch/converged-install-20260920/evidence.json、local-install.json、installed.png；本次临时旧 App 已清理。未公开发布。
- 前一切片的正文详情点击验收仍有工具缺口：Build 23 真实同名确认有“查看更新”按钮，点击详情后 CUA native pipe 再次中断；本轮重启 Build 24 后列表操作正常。此项不冒充已验收，详见正文对比接入记录。
