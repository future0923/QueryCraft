# MCP 权限继承 / MCP permission inheritance

## 中文

删除全局权限上限的设置、目录入口、保存预览、持久化字段和执行检查。操作权限按“对象/数据库 → 连接 → 分组 → 默认只读”查找，找到明确设置就采用，可以放宽或收紧上级默认值；清除该级设置才恢复继承。连接授权和对象名单仍独立检查，明确对象权限不会自动授权连接或扩大名单。

旧策略的根级 `mode` 不再参与计算，下次保存时移除；已有分组、连接和对象规则保留。主程序与独立 MCP 必须一起更新；已运行的 MCP 会话需要重连。SSH 继续使用独立账号授权和工具开关，破坏性操作仍需逐次确认。本机脚本保存、编辑、删除不执行脚本。

本次是功能提交和本机正式环境安装，不创建发布 tag，不推送或发布线上产物。相对主程序基线 `v0.1.12` 核对六类驱动源码、依赖与打包规则，没有数据库驱动或 Driver API 改动。

| 组件 | 本次决定 |
| --- | --- |
| 主程序 | 包含 MCP 设置变化；已完成本机 Intel Release 安装，公共发版另行安排，版本保持 0.1.12 (22) |
| MCP | 包含权限执行变化，纳入尚未发布的 0.1.3 (4) 双语说明；已完成本机安装 |
| Skill | 无资源内容变化，不单独发布 |
| SSH 插件 | 本次只改宿主授权判断，不改插件二进制、C ABI 或打包规则，不由本次变更触发插件发布 |
| MySQL | 不发布，无驱动实现或打包变化 |
| PostgreSQL | 不发布，无驱动实现或打包变化 |
| Doris | 不发布，共享 MariaDBTransport 无变化 |
| Redis | 不发布，无驱动实现或打包变化 |
| Elasticsearch | 不发布，无驱动实现或打包变化 |
| Kafka | 不发布，无驱动实现或打包变化 |
| Driver API | Swift 与驱动打包脚本均保持 5 |

验证（2026-10-26）：工作区内 170 项 MCP/SSH/脚本测试串行通过；Intel 主程序与独立 MCP Release 构建通过。签名、可迁移运行、SQL 资源、stdio/HTTP、凭据助手调用方拒绝、脚本 CRUD 和六类 API 5 驱动隔离加载均通过，MySQL/Doris 还分别验证独立加载。正式安装入口的新进程已核对实际加载身份、已有连接授权及五类已安装 API 5 驱动；PostgreSQL 使用已有兼容包在隔离目录验收，未改动正式驱动目录。原授权配置逐字节保持不变。

六类驱动的 Intel/Apple Silicon 在线目录均已检查包含 API 5 兼容记录；本次未重新下载并校验所有线上包摘要。未做实库写入、Apple Silicon 原生构建/运行或鼠标键盘 UI 验收。表数据及 SQL 结果表格没有布局或元数据变化；本次覆盖两者共用的 MCP 权限计算、SQL 授权和各驱动请求链路，不据此宣称已完成数据库侧隔离验证。

## English

Removes the global ceiling from settings, review, persistence and execution. The nearest explicit rule wins: object/database, connection, group, then read-only. Clearing a rule restores inheritance. Connection grants and object allowlists remain independent.

Legacy root-level mode is ignored and removed on the next save. Update both desktop and MCP; existing MCP sessions must reconnect. SSH retains account grants, tool switches and destructive-operation confirmations. Saving or editing scripts does not execute them.

This is a feature commit and local formal-channel installation, without a public release or tag. Desktop and MCP need distribution updates; MCP changes are included in unreleased 0.1.3 (4). Skill, SSH plugin binaries, all six database drivers and Driver API remain unchanged by this patch; no driver release is required.

Validation passed 170 serial worktree regressions, native Intel Release desktop/runtime builds, signed relocated stdio/HTTP and helper checks, script CRUD, six-driver isolated loading and independent MySQL/Doris loading. A fresh process through the installed formal launcher loaded the new runtime; saved permissions remained byte-identical. PostgreSQL was validated in isolation rather than added to the formal installation. Both architecture catalogs expose API 5 records for all six drivers; remote archive digests were not rechecked. Live database writes, native Apple Silicon validation and physical-input UI checks were not performed. Table-data and SQL-result layouts and metadata are unchanged.
