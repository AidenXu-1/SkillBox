# GitHub 版本跟踪与更新交互 v7

## 设计目标

- 用日常语言区分“只检查”、“下载更新”和“安装到应用”。
- 登录只在用户打开私人仓库时出现，同时明确“只读”和“钥匙串保存”。
- 新版本先作为平静的状态提醒，不使用弹窗打断用户。
- 更新前把文件变化、风险变化和安装去向放在同一个可检查页面。

## 主要状态

- `#account`：GitHub 账号、授权仓库和断开连接。
- `#import`：Release 与默认分支选择。
- `#update`：新版本提醒、忽略当前版本和停止检查。
- `#diff`：更新差异、风险与安装范围确认。
- `#access`：Device Flow 验证码与浏览器登录。

## 交互与可访问性

- 按钮和选择卡片均有悬停、按下与禁用反馈。
- “减少动态效果”开启后取消缩放，保留颜色状态。
- 主要操作名称包含真实影响范围，例如“更新并安装到 2 个应用”。

## 产物

- 可操作原型：`skillbox-github-v7.html`
- 账号与仓库：`skillbox-github-v7-account.png`
- 来源选择：`skillbox-github-v7-import.png`
- 更新提醒：`skillbox-github-v7-update.png`
- 更新确认：`skillbox-github-v7-diff.png`
- 登录授权：`skillbox-github-v7-access.png`

OpenDesign 未在当前会话加载，因此本轮使用 HTML + PNG 作为可视化兜底。
