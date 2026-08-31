# SkillBox v23：克制版 Skill 列表与拖动落点

## 本轮结论

v22 的落点圆点和文字胶囊会抢占注意力，卡片第二行的来源文字也让列表显得拖沓。v23 收敛为两条规则：

1. 拖动时只显示一根 `2 pt` 系统蓝插入线。
2. 卡片只保留单行「Skill 名称＋来源图标＋占用大小」。

## 拖动反馈

- 指针进入目标卡片上半区时，线显示在卡片上边界。
- 指针进入下半区时，线显示在卡片下边界。
- 不再显示端点、「放到某 Skill 上方／下方」文字胶囊，也不为提示腾出额外空白。
- 离开目标、取消拖动或完成放置时立即清除插入线，不做滞后退场动画。
- 「放到某 Skill 上方／下方」仍作为 VoiceOver 名称保留，只是不占视觉空间。

## 来源与大小

- GitHub 来源：尾部远程网络图标。
- 本地来源：尾部文件夹图标。
- 应用导入：尾部导入图标。
- 图标后紧跟中央库占用大小；来源全称放在悬停说明和 VoiceOver 名称中。

## 预览

- 普通状态：`skillbox-library-reorder-v23.html?state=normal`
- 拖动落点：`skillbox-library-reorder-v23.html?state=below`
- 右键菜单：`skillbox-library-reorder-v23.html?state=menu`
- 真实 SwiftUI 普通状态：`skillbox-library-reorder-v23-normal.png`
- 真实 SwiftUI 拖动中：`skillbox-library-reorder-v23-drag.png`

v22 产物保留为上一轮历史记录，v23 是当前实施准绳。
