# SkillBox v25：轨道内 Skill 排序候选

## 结论

v24 的大面积白色浮层和完整空卡位视觉过重，像在移动一块面板。v25 收回到 macOS 列表的纵向轨道里：被拖动行保持原来的蓝色选中外观，只沿上下方向跟随；相邻行自然换位，蓝线贴着当前落位边缘，不再出现一块裸露的大空白。

本文件是待确认设计候选，不是正式实现准绳。当前 `docs/spec.md` 和产品代码暂未改动。

## 用户会感受到什么

1. 按住卡片时仍是选择状态，移动超过 `8 px` 才真正开始拖动，避免普通点击误触。
2. 被拖动行保持蓝色选中背景，只沿列表的纵向轨道移动，横向不会飘到详情区。
3. 指针越过相邻行中线时，相邻行用约 `180 ms` 无回弹动画换位。
4. `2 pt` 系统蓝线紧贴落位边缘；没有圆点、文字胶囊或大面积裸露空位。
5. 松手后卡片在约 `180 ms` 内落入空位。插入线和空位立即清除，移动后的卡片保持选中。
6. 按 `Esc`、拖出列表、窗口失焦或系统取消拖动时，卡片回到原位，不保存排序，也不留下任何提示。

## 来源图标

- 图标紧跟在 Skill 名称后面，存储大小继续固定在最右侧。
- GitHub 来源直接使用 GitHub 官方章鱼猫标志，保持深色。
- 本地来源使用 macOS 用户熟悉的蓝色实心文件夹。
- 不再用“链路”“远程网络”等抽象符号代替来源。
- 图标保持 `16 pt`，悬停和 VoiceOver 分别显示“GitHub 来源”与“本地来源”。

Apple 的图标规范要求小图标采用熟悉、直接、无需猜测的视觉隐喻；GitHub 自己也把 Invertocat 作为用于快速识别 GitHub 的主标志。

## 交互状态

统一由一个拖动会话管理，不再让每个列表行分别记住自己的提示状态。

- `idle`：普通列表。
- `armed`：已按下，移动不足 `8 px`，仍可视为点击。
- `dragging`：卡片跟手，列表实时让位。
- `settling`：有效松手，卡片落入新位置。
- `cancelling`：取消或无效松手，卡片回到原位。
- 任何结束路径最终都必须回到 `idle`。

必须覆盖的结束出口：有效放置、拖出列表后松手、`Esc`、系统取消、鼠标事件中断、窗口失焦、页面消失、拖动对象被刷新移除。

## 边界规则

- 同一文件夹内拖动只负责排序。
- 移动到其他文件夹继续使用右键菜单“移动到”，避免一个动作同时表达排序和归类。
- 指针离开有效列表区域时，蓝线立即消失；拖动行仍被限制在列表轨道，松手则回原位。
- 长列表靠近顶部或底部 `34 px` 时自动滚动，越靠边滚动越快。
- 普通排序成功不弹 Toast，位置变化本身就是结果。跨文件夹移动和删除保留结果提示与撤销入口。
- VoiceOver 宣读“已抓取 Skill 名称”“当前位置第 N 项，共 M 项”“已移动到第 N 项”；右键菜单仍是完整替代路径。
- 开启“减少动态效果”时保留落位线，取消换位动画。

## 设计依据

- Apple Human Interface Guidelines 要求拖放过程提供清楚、连续的反馈；目标提示只在内容位于可接受目标上方时出现，拖走后移除。
- Apple 还建议同一容器内默认执行移动、放置后保持选择，并为拖放提供菜单等替代操作。
- macOS 的提醒事项、备忘录清单和 Finder 侧栏都采用直接拖动排序，用户不需要额外阅读一句“放到谁上方”。
- Windows ListView 也把列表重排作为系统级原生能力，说明这种模式已经形成稳定的跨平台心智。

参考：

- https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
- https://developer.apple.com/design/human-interface-guidelines/icons
- https://brand.github.com/foundations/logo
- https://support.apple.com/guide/reminders/remnda262a43/mac
- https://support.apple.com/en-mt/guide/notes/apd93c815aa0/mac
- https://support.apple.com/en-au/guide/mac-help/mchl83c9e8b8/mac
- https://learn.microsoft.com/en-us/windows/apps/develop/data/drag-and-drop

## 预览

- 可操作原型：`skillbox-library-reorder-v25.html`
- 打开后默认展示“拖动中”，可用顶部按钮查看普通、松手落位、取消拖动和右键菜单。
- 在“普通列表”状态下，可直接按住任意卡片上下拖动；按 `Esc` 可验证取消。
- 普通列表预览：`skillbox-library-reorder-v25-normal.png`
- 静态预览：`skillbox-library-reorder-v25-drag.png`

## 正式实施验收

1. 连续完成 30 次拖动、取消和拖出列表，结束后均无残留空位、蓝线或浮层。
2. 点击卡片不会误触拖动；移动达到阈值后才开始排序。
3. 快速跨越多行时目标位置稳定，不在相邻位置来回抖动。
4. 排序持久化失败时恢复原顺序并给出可恢复提示，视觉状态仍立即收口。
5. 键盘、VoiceOver、减少动态效果和高对比度模式均有等价反馈。
