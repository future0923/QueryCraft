# 表右键数据导出

状态：已实现，2026-10-14。主程序 Debug 构建成功，35 项相关测试通过；尚未完成实库回灌和原生界面手动验证。

## 已实现的交互

在 MySQL、PostgreSQL、Doris 的表右键菜单新增“导出数据”：CSV、JSON、SQL INSERT、XLSX。选择格式后直接打开系统保存面板，默认文件名为表名及对应扩展名；确认保存后进入现有导出中心。新增入口没有参数配置页，也不需要先打开表数据。

导出范围固定为右键表的整张表，不继承当前页面筛选或排序。点击时捕获连接、数据库、表及配置快照，不依赖当前选中对象。取消保存不创建任务、不连接数据库。确认后在现有并发队列内建立独立会话并读取数据，复用进度、取消、错误展示和打开文件位置功能。

参数统一放在“设置 → 数据”的导出分组，有效值自动保存，恢复数据默认设置时一并重置。现有数据页和查询结果页仍保留原有范围配置流程，并读取全局格式默认值。

## 参数与默认值

| 格式 | 默认值及可配置项目 |
| --- | --- |
| 通用 | CSV/XLSX 包含列名；NULL 输出为 `NULL`，可改为空值 |
| CSV | 逗号、CRLF、UTF-8 BOM、按需引号、公式保护；均可调整 |
| JSON | 对象数组、格式化开启；可选表格结构或 JSON Lines（扩展名 `.jsonl`） |
| SQL INSERT | 每条最多 1000 行，可自定义 1～100000；事务默认关闭；默认不包含库/schema 名，可开启 |
| XLSX | 冻结标题行、自动筛选默认开启；无表头时不启用这两项 |

1000 表示一条 INSERT 最多包含 1000 个 VALUES 元组。例如 2500 行生成 1000 + 1000 + 500 三条语句，读取批次不会提前截断 INSERT。另设 8 MiB 语句大小上限，先达到行数或字节上限即分句，单行超限明确报错。无效批量输入不覆盖最近有效值。

仅保存格式偏好，不保存来源表、连接、保存路径、筛选条件或选区。右键 SQL 导出使用普通 INSERT；原有配置页的 IGNORE/REPLACE 仅向 MySQL 提供。

## 六类驱动覆盖

| 驱动 | 新增表右键入口 | 现有数据页 / 查询结果页及限制 |
| --- | --- | --- |
| MySQL | CSV、JSON、SQL INSERT、XLSX | 使用 MySQL 引用及字符串转义；整表 SQL 排除生成列。非空 BINARY/VARBINARY/BLOB/BIT/GEOMETRY 等字段因现有传输无法保证原始字节完整，拒绝直接整表导出 |
| PostgreSQL | 四格式 | 使用双引号和转义字符串；整表目标优先采用协议 origin，保留名称中的点；排除生成列，identity 使用 OVERRIDING SYSTEM VALUE；bytea 使用传输提供的完整文本 |
| Doris | 四格式 | 普通 INSERT，不包装事务、不提供 MySQL 冲突策略；SQL 拒绝 HLL、BITMAP、AGG_STATE、ARRAY、MAP、STRUCT 等特殊类型；非完整二进制值同样拒绝 |
| Redis | 不提供关系表四格式菜单 | 维持现有键值专用能力 |
| Elasticsearch | 不新增整索引导出 | 保留已有表格/响应数据导出，隐藏 SQL 格式 |
| Kafka | 不新增整个 Topic 导出 | 保留已有读取结果导出，隐藏 SQL 格式 |

已分别评估驱动适用性和共享页面接入，未修改 Driver API 或外部驱动，未宣称完成六类驱动的实库验证。

## 实现结构

- `WorkspaceDatabaseObjectRow`、`WorkspaceDatabaseItems`、`WorkspaceModel`：右键菜单与捕获来源。
- `WorkspaceTableDataExportPresenter`：直接展示 NSSavePanel。
- `WorkspaceTableDataExportTarget`：在导出任务中准备独立连接、字段、SQL 目标及方言配置。
- `WorkspaceTableDataExportRowSource`：沿用每批 5000 行的分页读取，保留准备阶段首批数据，校验跨页列元数据及原始值完整性，结束时关闭会话。
- `WorkspaceDataExportPreferences`、`ApplicationPreferences`、`DataExportSettingsSections`、`DataExportBatchSizeField`：默认值、持久化和设置 UI。
- `WorkspaceDataExportJobManager`：支持延迟构造请求，准备阶段纳入并发限制和取消；排队取消不会建立数据库连接。
- `WorkspaceSQLExportDialect`、`WorkspaceDataExporter`：方言、标识符、转义和批量边界；继续复用四种 writer 和临时文件成功后替换目标的流程。

## 验证结果与边界

主程序 Debug 构建成功，最终代码重新编译并通过以下五个测试套件，共 35 项，0 失败、0 跳过：

- WorkspaceTableDataExportTests
- WorkspaceDataExportPreferencesTests
- WorkspaceDataExporterTests
- WorkspaceDataExportJobManagerTests
- ApplicationPreferencesTests

新增验证覆盖捕获数据库和设置、三种 SQL 方言、5003 行跨读取批次、生成列和 identity、四格式空表、1/200/1000/2000 自定义批量、语句字节上限、无损数据检查、偏好持久化/恢复默认，以及排队取消不连接。上述三驱动测试使用内存会话，不能替代实际数据库导入比对。

明确保留的限制：

- 尚未连接实库做导出及回灌比对；未做桌面保存面板和设置交互验证，未安装或启动新构建的 Dev 应用。
- 整表仍使用现有 offset 分页；并发写入下不保证一致性快照，不能作为一致性备份承诺。
- 查询结果 SQL 仍采用现有目标表配置，不新增别名、表达式或关联查询的自动回灌字段映射；本轮生成列和 identity 处理用于新增整表入口。
- 二进制仅有预览或已被驱动有损转换时明确失败，不输出伪造的可恢复数据。补充完整字节需要另行扩展数据链路。
- 复用现有导出中心，失败后可重新从右键发起，未新增单独重试按钮。
- XLSX 注释表头、多表目录导出、整库备份、DDL 导出、稳定游标/一致性快照及更多特殊类型编码属于后续工作。

无提交、打 tag 或发布。未来执行这些操作前，仍需重新阅读并遵循 `docs/RELEASE_PROCESS.md`。

## DBX 的实际做法

参考用户截图及 [DBX 公开源码](https://github.com/t8y2/dbx/tree/0db01f7f284ec6b0b090fe7369de7d05c37b25b0)，以该提交为调查基准。未对本机 DBX 做桌面点击验证；公开源码版本不保证与截图/已安装版本一致。

| 格式 | 已核对的行为 | QueryCraft 取舍 |
| --- | --- | --- |
| CSV | 表右键直接进入保存流程，后台表导出；引用全局引号模式、NULL 表示、读取批次和行数上限设置。默认全部加引号，NULL 标记为 `\N` | 分隔符、换行符、BOM、公式保护使用全局默认设置；右键选 CSV 后直接选择文件 |
| JSON | 当前右键入口仍走先读取数据、再保存 JSON 的 legacy 路径；输出对象数组 | 保留 QueryCraft 流式输出；新表右键默认对象数组，已有结果页保留表格结构偏好，支持 JSON Lines |
| SQL INSERT | 支持源数据库方言；当前源码菜单还多了“标准 SQL INSERT”。表导出 writer 的 INSERT 批次常量为 100 | 首期以源数据库方言输出，不增加第五个菜单项；1000 行默认值依用户需求，允许自定义 |
| XLSX | 先取字段信息，弹窗选择字段名、注释、字段名加注释或双行表头；自动筛选默认关闭，再选路径导出 | 右键选 XLSX 后也直接选择文件；字段名表头、冻结和筛选使用全局设置。注释表头作为第二阶段，必须具备可信来源 |

DBX 全局 `exportBatchSize` 默认 2000，指数据库读取批次；后端未传值时读取默认 10000。它与 `SQL_INSERT_BATCH_SIZE = 100` 是独立参数，不能把读取批次当作每条 INSERT 行数。

源码定位：

- `apps/desktop/src/components/sidebar/SidebarTreeRuntimeHost.vue` 的 `exportDataSubmenu`。
- `apps/desktop/src/composables/useSidebarTreeExportRuntime.ts` 的 `exportData`、`exportTableData`、`exportDataLegacyForTarget`、`exportDataXlsx`。
- `apps/desktop/src/stores/settingsStore.ts` 的 `exportBatchSize`。
- `crates/dbx-core/src/data/table_export.rs` 的 `SQL_INSERT_BATCH_SIZE`。
- `apps/desktop/src/components/export/XlsxHeaderDialog.vue`、`apps/desktop/src/lib/export/csvQuoteMode.ts`、`csvNullMode.ts`。

截图中的“导出数据库”“导出表结构”“复制表结构为 TSV/Markdown”分别属于整库备份、DDL 导出、结构文档复制，不混入本次四种数据格式。后续独立设计；单表导出不默认生成建表语句。


## 最终验证补充（2026-10-14）

相关 57 项自动测试和无窗口扩大回归已通过；MySQL 8.0/8.4、PostgreSQL 17 四格式回灌以及 Doris 四格式导出和 SQL 原文重放均已实库验证。原生菜单与文件面板未点击验收，全量窗口测试存在 AppKit 崩溃；详见 [DATA_TRANSFER_VALIDATION.md](DATA_TRANSFER_VALIDATION.md)。
