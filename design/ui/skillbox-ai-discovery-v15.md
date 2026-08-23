# SkillBox AI、Skill 发现与安全审查 v15

## 设计目标

- 用户从“添加 Skill”进入“发现 Skill”，不增加市场式主导航。
- 搜索只问“你希望 AI 帮你做什么”，不要求用户掌握 Skill 名称或技术关键词。
- 推荐结果分别展示相关性、来源、维护和使用信号，不使用虚假的综合分数。
- 点击“加入我的 Skills”后先完成来源、全部文件、权限和上下文四层检查，再进入现有中央入库流程。
- 安全结论只使用“未发现明显问题、需要了解、需要确认、无法添加”，并给出可核对证据。
- AI 设置只暴露普通用户需要理解的服务商、模型、API Key 和私人内容开关；默认 Agnes，API Key 只保存到 macOS 钥匙串。

## 可操作页面

- `skillbox-ai-discovery-v15.html`：默认打开“发现 Skill”。
- `skillbox-ai-discovery-v15.html?screen=safety`：直接展示加入前安全检查。
- `skillbox-ai-discovery-v15.html?screen=settings`：展示 AI 助手设置。

截图：

- `skillbox-ai-discovery-v15-search.png`：自然语言搜索、候选比较与推荐理由。
- `skillbox-ai-discovery-v15-safety.png`：加入前四层检查与证据说明。
- `skillbox-ai-discovery-v15-settings.png`：Agnes、DeepSeek、自定义接口和隐私开关。

发现页支持：搜索、候选切换、推荐理由展开、加入前检查和取消。设置页支持服务商切换、连接测试、私人内容开关和删除密钥确认。

## 数据说明

原型中的候选名称、安装量和检查结果仅用于验证信息层级，不代表实时目录数据。正式实现必须从 `SkillDiscoveryProvider`、GitHub 和本地安全引擎读取真实结果。

## 视觉原则

- 主操作只有“加入我的 Skills”或“保存设置”。
- 搜索结果和详情保持稳定双栏，常用窗口宽度下不裁切操作按钮。
- 危险色只用于真正需要用户决定的内容；“需要了解”使用温和的琥珀色。
- 所有按钮、候选卡和开关提供悬停、按下和禁用反馈。
- 动画只用于搜索进度、弹窗出现和选择切换，使用短时、无弹跳过渡。

当前会话没有 OpenDesign 工具，因此使用本地 HTML 与 PNG 作为可视化兜底。正式 SwiftUI 开发必须等用户确认本原型的流程与信息层级。
