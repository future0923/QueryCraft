# MCP 设置与开发环境隔离 / MCP settings and development isolation

本文保留实现提交时的验证与范围记录；发布安排已纳入 [QueryCraft 0.1.12](0.1.12.md) 和 [MCP 0.1.2](mcp/0.1.2.md)。
This records the implementation-time validation and scope. Publication is included in [QueryCraft 0.1.12](0.1.12.md) and [MCP 0.1.2](mcp/0.1.2.md).

## 中文

- MCP 设置改为单排七个页签，完整设置目录位于左下角；分组与连接直接列出，权限及范围操作对齐。
- 分组可批量授权，连接保留独立权限；数据库、Redis DB、索引与 Topic 范围使用可取消的独立编辑弹窗。全局、分组、连接及对象权限仍取最严格规则，打开设置不迁移策略。
- 数据发现保留已有结果，处理取消、失败及过期响应；保存前核对最终权限。
- Dev 使用 `QueryCraft Dev` / `querycraft-dev`，独立客户端配置、运行程序名称及 Skill 安装目录。只迁移可验证归属的旧 Dev 注册，保留正式版和手动修改。
- 未配置独立 Dev 组件源时，MCP/Skill 检查及安装升级明确报错并保留本地组件，禁止回退生产源。
- 权限菜单改用稳定的原生控件并合并策略更新。五连接离屏样例整组布局更新中位数由约 207 ms 降至 34 ms，单连接约 18–20 ms；该结果不代表所有连接规模。

提交前范围核对（基线 `v0.1.11`，同时区分此前已提交的事务修复）：

| 组件 | 决定 |
| --- | --- |
| 主程序 | 设置及安装逻辑变化，后续需要发布；本次仅提交，保持 `0.1.11 (21)` |
| MCP | 协议显示名、安装和独立 CLI 渠道逻辑变化，后续需要新 version/build 及双架构包；本次保持 `0.1.1 (2)`，不发布 |
| Skill | 资源源文件未改动，无需单独发布；Dev 安装转换由 MCP 安装器管理 |
| Driver API | 保持 5，Swift 与打包脚本一致；协议及驱动模型未改动 |
| MySQL | 本次无新增驱动改动；此前事务修复仍需后续发布，见下方关联说明 |
| PostgreSQL | 本次无新增驱动改动；此前事务修复仍需后续发布 |
| Doris | 本次无新增驱动改动；此前共享 transport 修复仍须与 MySQL 一起发布 |
| Redis | 无实现、依赖或打包变化，不发布 |
| Elasticsearch | 无实现、依赖或打包变化，不发布 |
| Kafka | 无实现、依赖或打包变化，不发布 |

此前驱动变化及未完成条件见 [SQL 事务状态修复](pending-transaction-state.md)，本次不修改其版本或发布决定。

验证：

- 提交前 MCP 全量筛选回归 77 项通过，零失败或跳过，包含组件、会话、权限、加载、注册及协议初始化。
- 最终优化 Release 主程序编译通过；中文/英文宽窄窗口原生预览、范围弹窗取消/应用、目录跳转和禁用控件行为通过。最新签名 Dev `20261021-165550-9c498363` 已安装，主程序与功能框架 UUID 匹配构建产物。
- 独立本地 Dev MCP 的 stdio/HTTP 身份、签名与六驱动加载通过；无 Dev 源时的安装器及 CLI 检查验证不访问生产下载。
- 2026-10-21 重新检查六类驱动的 12 个线上架构目录，均存在 API 5 版本；此次未重新下载线上归档核对摘要。
- 设置及公共策略模型适用于六类驱动；表数据页和 SQL 结果页未修改。本次未执行实库查询/写入，Apple Silicon 原生构建运行与正式双架构发布验收留待发版完成。无真实鼠标键盘模拟。

## English

MCP settings now use seven direct tabs, a bottom-left settings index, always-visible connection rows and a transactional object-scope sheet. Permission ceilings remain restrictive and existing policies are preserved. Native permission menus and batched policy changes reduce update work in the five-connection fixture (group median about 207 ms to 34 ms; individual changes about 18–20 ms).

Development uses `QueryCraft Dev` / `querycraft-dev` with separate registration ownership, runtime names and installed Skill paths. Without a separate development feed, component checks and installation fail while preserving local components; production downloads are disabled. Only verifiably owned legacy Dev entries migrate.

This is a feature commit, not a release. Desktop and independent MCP need future releases with new identities; current versions remain unchanged. Skill source assets and Driver API 5 are unchanged. No new driver changes are introduced here. Earlier MySQL/PostgreSQL/Doris transaction fixes still require releases as recorded in [their pending notes](pending-transaction-state.md); MySQL/Doris must ship together. Redis, Elasticsearch and Kafka require no republication.

All 77 selected MCP regressions passed before commit. The final optimized Release build, Chinese/English wide/narrow native previews and isolated interaction checks passed; signed Dev installation matches the built executable/framework UUIDs. Local independent Dev runtime identity, signature and six-driver loading checks passed. All 12 online architecture catalogs contain API 5 releases; archive digests were not rechecked. No live database requests, physical input simulation, public release or Apple Silicon native validation were performed in this change.
