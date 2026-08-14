# SkillBox 空状态与冲突处理 v3

## 本次目标

- 页面标题始终靠近窗口顶部，避免内容整体漂浮在垂直中间。
- Skill 库为空时移除无意义的左右分栏，直接提供添加入口。
- 没有 Skill 时不显示空安装矩阵，先引导用户添加 Skill。
- “需要你选择”中的每一组同名内容都可以点击，并直接进入对应版本选择。

## 交互合同

### 空 Skill 库

- 页面标题和说明固定在顶部。
- 空状态在标题下方的剩余空间内居中。
- 提供“从电脑添加”和“从 GitHub 添加”两个明确入口。

### 空安装页

- 保留“添加其他应用”，因为用户仍可提前登记自定义位置。
- 隐藏没有内容的安装矩阵和“检查安装改动”按钮。
- 主操作“去添加 Skill”返回“我的 Skills”。

### 同名内容选择

- 冲突条目显示悬停反馈、右箭头和“点击查看”的说明。
- 点击后只展示这一组 Skill 的不同版本。
- 每个版本展示出现在哪些应用以及内容编号。
- 版本采用单选；未选择时确认按钮不可用。
- 选择加入 SkillBox 后，其他应用中的原文件仍然保留。

## 可视化预览

- `skillbox-layout-v3-empty-library.png`
- `skillbox-layout-v3-empty-agents.png`
- `skillbox-layout-v3-conflict-choice.png`

## 验证边界

- HTML 原型的导航、版本单选和按钮状态已自动点击验证。
- Swift 应用已通过 19 项自动化测试和 release 打包。
- 本机 Computer Use 通道返回 `Sky Computer Use native pipe closed before response`，所以本轮尚未完成真实 SwiftUI 窗口的鼠标验收。
