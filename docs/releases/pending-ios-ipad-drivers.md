# iOS / iPadOS 驱动完善 / Mobile database driver improvements

本记录用于 `codex/ios-ipad-editor` 功能提交，尚未安排正式版本或发布。检查基线为 `v0.1.12`；此前 SQL 工作记录见 [pending-ios-ipad-sql.md](pending-ios-ipad-sql.md)。
This records a feature-branch commit relative to `v0.1.12`, extending the earlier SQL work. No release is scheduled.

## 中文

- 保留 MySQL 已有移动能力，新增 PostgreSQL、Doris、Redis、Elasticsearch 连接及对应原生页面，复用 Mac 的协议、目录、元数据和业务逻辑。
- PostgreSQL 支持表数据增删改、SQL 写入、持续事务/保存点及磁盘结果缓存；Doris 和 Elasticsearch 当前提供只读能力，Kafka 尚无移动入口。
- Redis 支持五类常用值的新建/编辑、重命名、整键及 Hash 字段 TTL、集合分页/全键成员搜索、Stream 浏览、HEX/JSON、大值分段显示与完整保存、原始字节和命令导出，以及同连接命令事务控制台。
- 加载保留容器和已有内容，处理取消、过期响应、后台事务关闭、精确确认和未知写入结果；核实被 ACL 拒绝时保留保护，写入不会自动重放。

提交前主程序、API 与六类驱动检查：

| 组件 | 当前提交与后续正式发布影响 |
| --- | --- |
| 主程序 | 移动页面及共享源码变化；保持 `0.1.12 (22)`，本次仅本地提交 |
| Driver API | 保持 5；公共类型拆分保留同模块符号/布局，Swift 常量、脚本及六类 manifest 模板一致 |
| MySQL | 新增共享筛选模式；加上基线后的元数据/分批传输变化，正式发布前需新身份与双架构包 |
| PostgreSQL | 提取共用目录/写入逻辑，增加可取消的 libpq 分批读取；正式发布前需新身份与双架构包 |
| Doris | 提取共用元数据，并承接基线后的 MariaDB transport V4 变更；与 MySQL 同时完成双架构及共存验证 |
| Redis | 共享集合/字段 TTL/Stream 读取器、乐观写入与协议错误处理变化；正式发布前需新身份与双架构包 |
| Elasticsearch | 共用服务器身份验证/Mapping 与移动条件适配；正式发布前需新身份与双架构包 |
| Kafka | 无实现、依赖或打包变化；不增加版本或发布，仅验证现有包加载兼容 |
| MCP / Skill | 无组件实现或发行身份变化，本次不发布 |

验证记录已检查：五库隔离全量 iPad **567/0/0**、iPhone **568/0/0**；最后修正后的 Redis 7.4 专项两端各 **50/0/0**；Mac 共享 Redis **29/0/0**、驱动实库 **11/0/0**；最新 iPhoneOS arm64 编译/链接通过。受影响驱动已分别完成本地 Intel 构建、打包、验签；真实隔离 installer/registry 验证六类驱动加载及会话工厂，新 Redis 包另实连验证 Stream、字段 TTL、集合分页和 CAS。完整证据与前几轮 PG/Doris/ES 结果见 [VALIDATION.md](../../QueryCraftMobile/VALIDATION.md)。未替换用户 Dev 驱动或操作用户数据库。

边界：Redis TLS、MOVED/ASK 路由、模块内容与二进制集合编辑沿既有 Mac 限制；PG 图形结构/查询单元格编辑、ES 写入与 PIT 深分页、Kafka 移动链路未移植。实体设备触控、真实弱网/系统挂起、多版本 TLS 和正式发布所需双架构驱动运行/线上目录检查仍是后续验收门槛。本次不推送、打 tag、改版本或发布；正式发版重新读取 RELEASE_PROCESS，分配版本并完成上述检查。

## English

The mobile workspace retains existing MySQL functionality and adds PostgreSQL, Doris, Redis and Elasticsearch through shared Mac transport, metadata and business logic. PostgreSQL supports table mutations, SQL writes, persistent transactions/savepoints and disk-backed results. Doris and Elasticsearch remain read-only; Kafka has no mobile entry point.

Redis now includes creation/editing of five common types, rename, key and hash-field expiration, collection paging and whole-key member search, Stream browsing, HEX/JSON, segmented large-value presentation with complete-value saves, raw-byte/command export and a same-connection command/transaction console. Stable loading, cancellation, stale-response guards, background teardown, immutable confirmation and unknown-write fences are preserved. Denied verification reads cannot clear the fence or replay a write.

This is a local functional commit. App identity stays `0.1.12 (22)` and Driver API stays 5, consistent across Swift, packaging helpers and all six templates. Public declarations retain their module identities/layouts when split into shared files. MySQL, PostgreSQL, Doris and Redis have applicable implementation changes since `v0.1.12`; Elasticsearch has shared identity-validation/mobile adaptations and likewise requires updated release packages. Allocate fresh affected-driver identities and validate native Intel/Apple Silicon packages before publication. MySQL/Doris also share the changed V4 dynamic transport and require joint compatibility checks. Kafka, MCP and Skill implementations/identities are unchanged and must not be republished merely for this commit.

Verified evidence: isolated five-database full suites passed on iPad (567 tests) and iPhone (568); final Redis 7.4 suites passed 50 tests on each device simulator; Mac shared Redis tests passed 29 and driver integration tests passed 11. The latest unsigned iPhoneOS arm64 build linked successfully. Independent local Intel driver builds/packages/signatures and actual isolated installer/registry loading of all six driver factories passed. The new Redis package additionally passed live Stream, field TTL, pagination and optimistic-write checks. Earlier PostgreSQL/Doris/Elasticsearch evidence and precise coverage are in VALIDATION.md. Installed user drivers were not replaced.

Physical touch, real network failure/suspension, broader server/TLS versions, release-grade dual-architecture driver execution and online catalog verification remain separate gates. Existing Redis protocol limits and unported PG/ES/Kafka features are explicitly documented. No push, tag, version bump or publication is part of this commit.
