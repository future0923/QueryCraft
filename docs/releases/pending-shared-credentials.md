# 统一凭据授权 / Shared credential authorization (待发版 / Unreleased)

## 中文

- 普通连接与 MCP 共用一个受签名验证的凭据助手，同一数据目录的所有连接密码保存在一个钥匙串保险库中，避免按连接反复授权。
- 主程序统一迁移可读取的旧凭据；后台 MCP 和旧凭据读取不再逐条触发系统弹窗。无法读取的历史凭据需先解锁钥匙串或在连接编辑器重新保存。
- 新增、修改、清除密码共用同一存储；并发写入、重复迁移和删除标记防止密码丢失或旧密码恢复。
- 此功能需同时更新主程序和 MCP；旧 MCP 会明确提示升级。

提交前范围核对（基线 `v0.1.10`）：

| 组件 | 本次决定 |
| --- | --- |
| 主程序 | 后续发版包含；本次仅提交功能，保持 `0.1.10 (20)`，版本由单独发版提交确定 |
| MCP | 后续发版包含；正式发布前按已发布身份分配新 version/build，不覆盖已发布包 |
| Skill | 不发布，无实现变化 |
| Driver API | 保持 5，Swift 与打包脚本一致 |
| MySQL | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |
| PostgreSQL | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |
| Doris | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |
| Redis | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |
| Elasticsearch | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |
| Kafka | 不发布，无实现、依赖或打包变化；本地 API 5 加载通过 |

已通过主程序 Debug 编译、46 项凭据/MCP/会话/设置/连接模型回归、13 项组件与优化回归、15 项发版范围与工作流检查、八条临时密码共用一个保险库的签名集成验证，以及独立 MCP 的 stdio、HTTP、签名和六类驱动加载检查。真实数据库认证、锁定钥匙串的交互、Arm64/Universal 主程序构建及线上逐架构清单核对留待发版验收。

## English

- Desktop connections and MCP share one signature-validated helper and one Keychain vault per data directory, avoiding repeated authorization for each saved password.
- The desktop migrates readable legacy credentials without per-item system prompts. Inaccessible historical items require unlocking Keychain or restoring their password in the connection editor.
- Password creation, edits and deletion use the same storage. Cross-process locking, insert-only migration and deletion markers protect concurrent updates.
- Update both the desktop app and MCP to use this feature. Older runtimes produce an explicit upgrade message.

This is a feature commit, not a release. The desktop and MCP need future releases; allocate their release identities separately and never overwrite published packages. Skill and all six drivers have no implementation, dependency or packaging changes. Driver API remains 5. Existing local API 5 packages loaded successfully for all six drivers, including individual MySQL/Doris loading.

Validation passed the Debug build, 46 selected regressions, 13 component/optimization regressions, 15 release-scope/workflow checks, signed integration with eight disposable passwords in one vault, and standalone stdio/HTTP/signature/driver-loading checks. Live database authentication, interactive locked-Keychain behavior, Arm64/Universal desktop builds and online architecture-specific manifest checks remain release-time acceptance items.
