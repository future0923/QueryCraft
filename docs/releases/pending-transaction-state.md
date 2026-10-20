# SQL 事务状态修复 / SQL transaction state fix（待发版 / Unreleased）

## 中文

- MySQL 和 PostgreSQL 从服务器响应读取当前事务状态，修复 `SET NAMES` 等语句执行成功后被误报为“服务器未返回当前事务状态”的问题。
- 保留 PostgreSQL 事务内查询的事务状态；依据服务器结果处理 MySQL DDL 隐式提交、保存点、提交及回滚。
- MySQL/Doris 共享库使用 `QueryCraftMariaDBTransportV3`，避免旧 V2 库先加载时缺少新增符号，支持两类驱动独立升级。
- 回归脚本检查嵌套框架的严格签名完整性，并使用主程序启动时的驱动加载器验证兼容性和激活。安装 Dev 驱动须使用保留符号链接的复制方式（例如 `ditto`），否则主程序可能拒绝损坏的包。

提交前范围核对（基线 `v0.1.11`）：

| 组件 | 本次决定 |
| --- | --- |
| 主程序 | 无运行时代码变化，保持 `0.1.11 (21)`；本次提交不发布主程序 |
| Driver API | 保持 5，公共协议表及模型布局不变，Swift 与打包脚本一致 |
| MySQL | 后续需要发布，修改了事务状态及共享 transport；保持当前 `1.0.7 (8)`，正式发布前分配新 version/build |
| PostgreSQL | 后续需要发布，修改了协议结果及事务状态转换；保持当前 `1.0.6 (8)`，正式发布前分配新 version/build |
| Doris | 后续与 MySQL 一起发布，共享 transport 发生变化；保持当前 `1.0.7 (8)`，正式发布前分配新 version/build |
| Redis | 不发布，无实现、依赖或打包变化；本地启动加载通过 |
| Elasticsearch | 不发布，无实现、依赖或打包变化；本地启动加载通过 |
| Kafka | 不发布，无实现、依赖或打包变化；本地启动加载通过 |
| MCP / Skill | 不发布，无实现或公共协议变化 |

验证记录（本地 Intel）：

- 主程序及测试目标编译通过；SQL 编辑器模型 31 项、MySQL 驱动 47 项、PostgreSQL 驱动 13 项、Doris 驱动 5 项回归通过。
- MySQL 5.6、8.4 和 PostgreSQL 17 本地实库验证通过，覆盖 SET、事务内空查询、保存点、DDL、提交/回滚，以及编辑器完整执行 SET → CREATE → INSERT → SELECT → DROP。
- 三类受影响驱动分别编译、打包；新旧 MySQL/Doris 混合加载与六类驱动共同加载通过。重装时保留框架符号链接，六驱动通过签名、兼容性和激活检查；已核对真实 Dev 进程加载 V3 库及修复后的 MySQL 包，用户确认原 SQL 正常执行。
- 2026-10-20 核对线上六类驱动的 12 个架构目录，均存在 API 5 兼容版本；此次未重新下载核对线上归档摘要。
- 改动覆盖 SQL 编辑器与驱动查询执行结果；表数据页布局未改动。Redis、Elasticsearch、Kafka 不适用此次 SQL 事务状态转换。

本次仅提交修复。Doris 实库、MariaDB 服务端实测及 Apple Silicon 构建/运行尚未完成；正式发布前三类驱动均需完成双架构构建、打包、签名与线上归档验收，不覆盖已发布的版本身份。

## English

- MySQL and PostgreSQL now read transaction state from server responses, preventing successful statements such as `SET NAMES` from being reported as transaction-state failures.
- PostgreSQL reads retain an open transaction. MySQL DDL implicit commits, savepoints, commits and rollbacks follow the server response.
- MySQL and Doris use the separately named `QueryCraftMariaDBTransportV3`, allowing independent upgrades when an older V2 peer loads first.
- The regression harness verifies nested framework signatures and uses the application's startup loader. Preserve framework symlinks when installing Dev packages, for example with `ditto`.

This is a fix commit, not a release. Relative to `v0.1.11`, MySQL, PostgreSQL and Doris require future driver releases; MySQL/Doris must ship together because their transport changed. Allocate new version/build identities before publishing. Desktop remains `0.1.11 (21)`, Driver API remains 5, and public protocol/model layouts are unchanged. Redis, Elasticsearch, Kafka, MCP and Skill have no implementation or applicable dependency changes and require no republication.

Intel validation passed the app/test builds and 96 selected regressions (31 editor-model, 47 MySQL, 13 PostgreSQL, 5 Doris). Live local MySQL 5.6/8.4 and PostgreSQL 17 checks covered transaction transitions and complete editor scripts. The affected drivers were built and packaged separately; mixed old/new MySQL/Doris loading, six-driver coexistence, strict package integrity and startup-loader checks passed. The running Dev process was verified to load the fixed MySQL package and V3 transport; the user confirmed the original SQL succeeds.

All 12 online architecture catalogs contained API 5 compatible releases on 2026-10-20; remote archive digests were not revalidated in this commit. SQL editor/query execution is covered, with no table-data layout change. Redis, Elasticsearch and Kafka do not use this SQL transaction conversion. Live Doris/MariaDB server validation and Apple Silicon builds/runs remain outstanding; complete both-architecture packaging, signatures and published-archive acceptance before release.
