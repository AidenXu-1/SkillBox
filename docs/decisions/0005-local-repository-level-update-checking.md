# ADR-0005：本机仓库级 GitHub 更新检查

- **状态**：已采纳
- **日期**：2026-08-16

## 背景

SkillBox 会管理越来越多的 Skill，但用户只需要知道已发布的版本是否发生变化，不需要实时跟踪 GitHub 的每一次提交。

旧实现逐 Skill 查询仓库信息、Release、Commit 和目录 Tree。同一仓库的多个 Skill 会重复发送相同请求，正常的公开仓库也容易触发 GitHub 未登录查询限制。

## 决定

1. GitHub 更新检查保持在 macOS 客户端完成，不增加 SkillBox 服务端、公共版本索引、Webhook 或云端数据库。
2. 检查按「规范化仓库名 + 跟踪方式」归并，串行执行。同一仓库的多个 Skill 共用仓库、Release、Commit 和 Tree 结果。
3. Release 含可用 ZIP 时，Latest Release 响应已足够判断新版本或资源替换，日常检查不再追加 Commit 和 Tree 请求。
4. 默认分支先检查分支头 Commit。只有 Commit 变化时才读取 Tree，并在本次仓库检查中共享目录结果，避免 README 或其他 Skill 的改动制造误报。
5. 每个来源保存 GitHub `ETag`。后续请求使用 `If-None-Match`；`304 Not Modified` 只更新检查时间，不清空已知版本状态。
6. 应用打开期间每 24 小时最多自动检查一次。用户可手动检查当前 Skill 或全部来源，批量检查需显示仓库级进度并可取消。大型库优先处理最久未成功检查的仓库，避免后排来源长期得不到检查。
7. 「连接 GitHub」作为一个可选入口。公开仓库始终使用无需登录的读取通道；GitHub App 连接只用于用户明确选择的私人仓库。这遵循 GitHub App 用户令牌只能访问「应用已安装仓库」与「用户可访问仓库」交集的官方权限边界。

权限和请求策略依据 GitHub 官方文档：[GitHub App 用户令牌的仓库交集边界](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)、[REST API 条件请求与串行队列建议](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)。

## 不选择的方案

- **SkillBox 公共版本索引**：需要服务器、隐私说明、监控、数据删除和运维，v1 的用户价值不足以支持这层复杂度。
- **Webhook**：需要外部接收服务器，且不能覆盖未安装 SkillBox GitHub App 的普通第三方仓库。用户不需要实时更新，因此不采用。
- **GraphQL 批量查询**：会引入第二套 API 数据模型，而 REST 的仓库归并、条件请求和已登录额度已足以支撑大型个人 Skill 库。只有真实使用数据证明 REST 不足时才重新评估。

## 后果

- SkillBox 仍然是不需要账号和服务器的本地应用。
- 请求数从「Skill 数 × 多个端点」降为「仓库数 × 一个主检查端点」，只有真正变化时才进入后续检查。
- GitHub 临时不可用时，本地 Skill、安装、卸载和撤销仍然完全可用。
