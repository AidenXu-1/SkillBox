# 刷新样式和 DeepSeek Harness 识别修复

## 原因与范围

- 工具栏原代码在忙碌时额外插入 ProgressView，同时保留禁用刷新按钮，macOS 将两者合成双图标胶囊。改为同一个固定占位按钮内切换图标和转圈。
- 本机已安装 dsh 且存在 `~/.dsh`，但尚无 `~/.dsh/skills`。原识别仅检查后者，导致已安装应用显示未找到。
- 已核对本机官方安装包 `@deepseek-ai/dsh-skill-filesystem` 和[官方目录说明](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/skill/skill-filesystem/README.md)：全局目录为 `<DSH_HOME>/skills`，默认 `~/.dsh/skills`。
- 通用修复在检测时为已存在且可写的 DSH 根目录准备缺失的空 skills 子目录，再检测。未安装时不创建 DSH 根目录；已有文件不覆盖；环境变量与应用排序保持。没有自动安装任何 Skill。

## 验证

- 默认和环境变量配置两种已安装未初始化场景在旧实现复现 6 条失败，修复后通过；未安装与同名文件占位均保持。
- 完整测试：Swift 633 项报告（632 实际通过、1 既有公网跳过），Python 28 通过。
- Xcode 新许可未确认，本轮没有接受协议。使用已可独立运行的 Command Line Tools 6.3.1，为其 Testing.framework 和 lib_TestingInterop 显式提供进程级路径后完成测试；未更改系统默认工具配置。临时 wrapper 位于 scratch/dsh-fix/tool-bin。
- Release 构建、严格签名与隐私检查通过。本机原位置更新为 0.2.6 Build28；640 个资料文件在 App 替换期间完全保持，启动后 537 个中央内容文件及 DSH 既有 8 文件核对保持；新增 skills 为空，没有自动安装 Skill。临时旧 App 已清理。
- 原生启动时工具栏仅有一个忙指示器，完成后恢复一个刷新按钮；实机截图显示正常单按钮及 DeepSeek Harness 已找到。再次手动点击验证因用户同时操作窗口被 CUA 拒绝，停止额外点击，不将该点击计为通过。截图 `scratch/dsh-fix/refresh-found.png`。
- 已保留应用排序；本轮修复在通用代码中，本机已生效，公开版本仍 v0.2.6 Build27，本轮未另行发布。
- 程序 SHA-256：`9377eee9e9faaaf2df9bfef44c7b8d7292b8b24309d79d568f84f00f07a1a888`。
