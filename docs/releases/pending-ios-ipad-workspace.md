# Mobile workspace completion / 移动工作区完善

Feature commit on `codex/ios-ipad-editor` after 3e2a2df, authorized by the user on 2026-10-25. No version change, push, tag or publication is included.

## 中文

- Doris SQL 接入原 MariaDB 背压流、磁盘缓存/分页/完整导出；结构页读取 SHOW CREATE 和真实索引能力，保持只读。
- SQL 独立多文稿、保存查询和恢复，复用 Mac 恢复模型、关闭快照与 PG Schema 选择规则；持久写入标记阻止重启后盲目重放，连接切换失败保留草稿。
- 跨连接迁移复用原 planner/catalog/runner/manager/library 和三类 SQL session，含完整 SQL 预览、真实 COPY/LOCAL INFILE、任务文件夹、取消/备份和待核实运行记录。
- 编辑器设置复用主题/归档/历史/设置键/格式化/缩进补全规则；触控行号、原生选区/IME/撤销及长文稿滚动保持。

主程序0.1.12(22)、Driver API5及公开存储模型布局不变。共享新增计算方法与源码拆分需配套新版主程序；正式发行前重新阅读 RELEASE_PROCESS，沿用各前序 pending 记录的发行身份决策，配置真实最低主程序版本，不直接上线本地验证包。

| 驱动 | 本轮影响与正式发行门槛 |
| --- | --- |
| MySQL | iOS 条件编译和迁移 session 复用；共享元数据匹配/配置方法，独立编译打包与加载回归；保留前序新驱动身份/双架构门槛 |
| PostgreSQL | iOS 条件编译和迁移 session 复用；共享 Schema/字段来源匹配；保留前序新身份及新版 host 符号/最低版本门槛 |
| Doris | 实际查询改为流式，索引转换共享；正式发布须新驱动身份、配套主程序、双架构构建/签名/加载/实库验证 |
| Redis | 协议与移动功能未改；共享 host 回归及包工厂加载，保留前序发行门槛 |
| Elasticsearch | 专用协议与移动功能未改；完整移动回归及包工厂加载，保留前序发行门槛 |
| Kafka | 无移动链路/协议改动，继续排除移动移植；仅共享 host/包加载兼容，不新增发行身份 |

本轮只使用自有隔离实库和本地签名包，不覆盖用户 Dev 或数据库。Intel 包加载不是双架构发行验收。实体设备、真实弱网/系统挂起、多版本服务器/TLS/证书矩阵仍未完成；系统查找颜色和 CodeEdit 多光标是原生控件边界。最终证据见 QueryCraftMobile/VALIDATION.md。

## English

The native workspace adds streamed read-only Doris queries and real DDL/index metadata, independent persistent SQL documents and saved queries, the original Mac transfer engine and task library, and shared editor/theme preferences. Physical field origins determine metadata; projection names never fabricate comments. SQL sessions and PG schema catalogs belong to each document. Recovery excludes credentials/results/server transactions; unresolved writes and interrupted transfers stay fenced until explicit verification.

App/API identities remain unchanged. The Doris streaming binary requires a fresh release identity and paired host release; retain earlier MySQL/PG/Redis/ES release decisions. Before any release, re-read RELEASE_PROCESS, set an appropriate minimum host version, and complete both architectures, signing, packaging, real bundle loading and server checks. Kafka has no new mobile implementation or release identity. This local validation does not publish artifacts, replace installed user Dev drivers, or claim physical-device/network/TLS acceptance.
