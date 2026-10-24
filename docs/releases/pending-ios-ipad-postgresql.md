# PostgreSQL mobile parity / iOS・iPadOS PostgreSQL

Local feature commit on `codex/ios-ipad-editor`; no version bump, tag, push or release requested. Preserve earlier Redis/ES/mobile-driver release decisions.

## 中文

- PostgreSQL 查询结果接入同源物理目标/主键编辑和删除；完整自动提交缓存页可修改并保留全部磁盘结果及导出，表达式/关联/活动事务保持真实限制。
- 复用 Mac PostgreSQL provider/descriptor、新表草稿、索引目录转换及事务 executor，提供字段/索引/注释/IDENTITY/生成列、新表和表操作入口。
- Files 多格式导入复用原解析、冻结磁盘快照、映射及事务执行器；失败/取消回滚，提交结果不明不重放。
- 特殊 Schema/表名计算身份与 SQL 预览对齐。共享磁盘缓存删除使用流式 SQLite 压缩，保持 Mac 结果与优化。

主程序保持现有身份；Driver API5及公开存储模型布局不变。PostgreSQL 驱动抽取共享元数据/执行器并修正显式引号身份；正式发布必须分配新驱动身份并执行双架构编译、签名、包加载和实库门槛；新版驱动依赖新增的 host 计算身份符号，必须与新主程序配套并设置相应最低主程序版本，不能沿用旧兼容下限直接上线。MySQL 只继承共享默认行为/导入引擎/缓存优化，需回归；Doris、Redis、ES 专用协议未改，Kafka 无移动新增。前序分支已有的驱动发行影响仍按对应 pending 记录执行。

仅生成隔离本地验证包，不覆盖用户 Dev、上传目录或发布。最终测试、跳过项、真机与 TLS/多版本边界见 QueryCraftMobile/VALIDATION.md。正式发版须重新阅读 docs/RELEASE_PROCESS.md。

## English

The mobile PG workspace shares Mac query-editing identity/PK validation, PostgreSQL schema/new-table plans and descriptors, index metadata conversion, transactional schema execution and file-import parsing/mapping/execution. Completed auto-commit query-cache pages retain the whole result through edits/deletions and export. Disk compaction streams payloads instead of materializing the full cache. Unknown commit outcomes fence replay; quoted physical names remain exact.

App identity and Driver API5 stay unchanged. PG requires a fresh release identity plus dual-architecture build/sign/package/live-load verification before publication. It also depends on a new host identity helper; publish only with the paired host release and an appropriate minimum app version. Other drivers retain their prior release decisions and explicit capability limits. No installed user driver, remote catalog or release is changed. General cross-connection transfer workbench UI and physical/server/TLS acceptance boundaries are recorded separately.

## 本次本地提交检查 / Local commit checklist

2026-10-24 用户要求提交后停止开发。重新读取 AGENTS.md 与 RELEASE_PROCESS.md，以本地正式基线 v0.1.12 核对。主程序0.1.12(22)及Driver API5不变；本次不发版、不查询或修改线上发行目录。六类驱动累计影响：MySQL/Doris共享transport、PG、Redis、ES均保留各pending记录中的新身份/双架构发布门槛；Kafka无实现变更，不发新版本。MCP/Skill无本轮变更。PG新增host符号所需最低主程序版本必须在正式发布前配置。已通过的模拟器、Mac、独立驱动包与实际加载结果见VALIDATION；未将本机Intel包检查冒称双架构发布验收。

The user requested a local commit and no further development. Repository instructions were reread against the local v0.1.12 baseline. App/API identities remain unchanged; no remote publication or catalog mutation is included. Preserve prior release gates for MySQL/Doris, PG, Redis and ES; Kafka/MCP/Skill receive no new release identity. Final verification evidence and physical-device/TLS/dual-architecture limits remain in VALIDATION.
