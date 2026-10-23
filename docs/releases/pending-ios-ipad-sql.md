# iOS / iPadOS SQL 功能完善 / iOS and iPadOS SQL improvements

本记录用于功能分支提交，尚未安排正式版本或发布。范围以 `v0.1.12` 为基线。
This records a feature-branch commit relative to `v0.1.12`; no release version or publication is scheduled.

## 中文

- iPhone 和 iPad 共用 Mac 的 SQL 格式化、执行范围解析及批次预检，支持当前语句、完整选区、整篇文稿执行和独立结果切换。
- MySQL 新建表及已有表选项沿用 Mac 的草稿、元数据、选项联动和 SQL 变更计划；保留安全锁、SQL 预览、过期草稿与未知结果保护。
- SQL 查询使用有背压的类型化分批读取和同源 GRDB 结果库；移动端按缓存页查看，可分批导出全部查询缓存，无需重新执行 SQL。
- 默认安全锁保护写 SQL，危险语句须确认。支持同连接跨执行事务、保存点、提交和回滚，事务状态来自服务器；后台断开并回滚未提交事务。刷新只执行读取，不重放写入或提交。
- 每批查询编码缓存载荷上限为 256 MiB，SQLite 页和 WAL 另计。释放结果会清理文件，启动清理上次运行的自有缓存目录；不增加工作区持久恢复。

提交前组件核对：

| 组件 | 本次决定与影响 |
| --- | --- |
| 主程序 | 共享 SQL、缓存及表草稿代码有变化；本次仅提交，保持 `0.1.12 (22)` |
| Driver API | 保持 5；Swift 常量、打包脚本及六类 manifest 模板一致，原公共协议和模型布局不变 |
| MySQL | 表元数据及查询分批链路变化，使用动态 transport V4；正式发布前分配新驱动身份并发布双架构包 |
| Doris | 同源 transport 升级到 V4，与 MySQL 一起视为受影响；正式发布前同样完成双架构发布 |
| PostgreSQL | 无驱动实现、专属依赖或打包变化；共享缓存沿用默认参数，本次不发布驱动 |
| Redis | 无适用驱动变化，专用数据链路不接入 SQL 事务；本次不发布驱动 |
| Elasticsearch | 无驱动变化，保留专用协议和数据链路；本次不发布驱动 |
| Kafka | 无驱动变化，不接入移动 SQL 事务；本次不发布驱动 |
| MCP / Skill | 本提交不修改实现或发行身份，本次不发布 |

验证：iPhone 全量 468/0/0，最终补验 24/0/0；iPad 全量 467/0/0，最后 SQL/缓存/原生页面 14/0/0、结构状态 10/0/0；Mac 共享缓存和查询状态 41/0/0，主程序构建通过。自有 MySQL/TLS 验证 10 万行缓存/完整导出、类型/来源/二进制/空结果、确认失效、写入权限、事务、DDL 隐式提交、取消和未知结果栅栏。缓存文件删除与真实重启残留清理均通过，两端原生明暗页面已核对。

MySQL 和 Doris 已各自完成本地 Intel 构建、打包和签名检查。真实 Dev installer/registry 在隔离目录加载新包，六类驱动激活与会话工厂通过；新 MySQL 返回多个类型化查询批次，实际映像确认来自新包，旧 V3 与新 V4 共存通过。未替换用户正在使用的 Dev 驱动。

限制与后续发布门槛：移动仍仅支持 MySQL，查找范围为当前缓存页，大结果与事务内结果暂不提供单元格编辑；二进制只保留长度和 128 字节预览。Doris 和其他四类驱动没有本轮实库查询；Apple Silicon 构建/运行与线上双架构归档、摘要和 API 目录复核未完成。本次不打 tag、不发布、不修改线上目录；正式发版须重新读取发版流程、分配版本和驱动身份并完成上述检查。详细记录见 [移动验证](../../QueryCraftMobile/VALIDATION.md)。

## English

- iPhone and iPad share the Mac SQL formatter, execution target resolver and batch preflight. Current statements, complete selections and documents can produce separate results.
- MySQL table creation and existing table options reuse the Mac drafts, metadata, dependent choices and SQL plans, including safety locks, previews and stale or uncertain outcome guards.
- Typed query batches use backpressure and the shared GRDB result store. Mobile displays bounded cache windows and exports the complete cached query without re-executing SQL.
- Writes use the safety lock and immutable SQL confirmation; dangerous statements require confirmation. Transactions and savepoints persist across executions on the same connection, with server-reported state. Backgrounding disconnects and rolls back uncommitted work; refresh never replays writes or commits.
- Each batch permits at most 256 MiB of encoded cache payload, plus SQLite/WAL overhead. Releasing results removes cache files; startup removes this application's previous-run cache directories. This does not add persistent workspace restoration.

Component decision: this is a functional commit, not a release. The desktop version remains `0.1.12 (22)` and Driver API remains 5, consistent across the Swift constant, packaging helper and all six manifest templates. MySQL and Doris both require future native Intel and Apple Silicon driver releases because their shared dynamic transport moves to V4; allocate fresh release identities before publishing. PostgreSQL, Redis, Elasticsearch and Kafka have no applicable driver implementation, dedicated dependency or packaging changes and must not be republished for this commit. MCP and Skill are unchanged.

Validation passed: iPhone full 468 tests plus 24 final focused tests; iPad full 467 tests plus 14 SQL/cache/native and 10 schema-state tests; Mac shared cache/query regressions 41 tests and the desktop build. Owned MySQL/TLS fixtures cover 100,000-row cache/export, typed metadata, writes, transactions, cancellation and no-replay fences. Native light/dark renders, actual file cleanup and real application restart cleanup were checked. Independent local Intel MySQL/Doris builds, packages and signatures passed; the isolated Dev installer/registry activated all six drivers. The new MySQL package streamed typed batches, and the loaded V4 image was verified alongside the older V3 framework. Installed user drivers were not replaced.

Mobile remains MySQL-only; search covers the current cache window, and large or transactional query results are read-only in the grid. Binary values retain their size and a 128-byte preview. Live Doris/other-driver queries, Apple Silicon builds/runs and online native archive/API/catalog verification remain release gates. No tags, publication or online catalog changes are part of this commit.
