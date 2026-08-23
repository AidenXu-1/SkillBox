# SkillBox 品牌图像

## 文件

- `skillbox-mascot-original.png`：用户确认的原始 IP 形象，作为角色比例、眼睛和胸前 `S` 的唯一视觉母板。
- `skillbox-app-icon-master.png`：macOS 应用图标母版，1024 × 1024，带透明外角。
- `app/Resources/SkillBox.icns`：当前 macOS 应用包通过 `CFBundleIconFile` 实际读取的图标资源。
- `app/Resources/Assets.car`：保留的 16–1024 px 品牌资源归档；当前应用图标由 `SkillBox.icns` 提供。

## 使用约定

- IP 形象不改变头身比例、黑色点状眼睛和胸前单个大写 `S`。
- 小尺寸图标优先保证眼睛和 `S` 的识别度，不再加文字、徽章或其他符号。
- 原图不直接替换；新场景从原图派生并保留可追溯文件。

## 图标母版生成说明

使用内置图像编辑模式，以原始 IP 图为权威参考：保留角色、黑眼和发光大写 `S`，只增加淡银白圆角底座和轻微边缘层次，使其在浅色与深色 macOS 桌面上都可辨认。不添加文字、道具、水印或第二符号。
