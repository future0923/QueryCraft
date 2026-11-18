# MCP SQL 查询导出（本地 MySQL MVP）

AI 确认业务口径、字段和 SQL；MCP 执行完整查询并分批写入文件，不把明细返回聊天。
不使用聊天查询的 1,000 行、响应字节或 200 字符预览限制。

## 工具

- `querycraft_export_query`：异步提交，返回 `job_id` 和私有 `access_token`。
- `querycraft_get_export_status`：状态、逐表行数、有效预算；仅完整成功后返回文件。
- `querycraft_cancel_export`：请求取消，需等终态确认停止。权限撤销后仍可凭任务 token 清理。
- `querycraft_delete_export`：删除终态任务和文件；活动任务必须先取消。

lazy 模式通过 `plugin_tools(connection_id)` 发现。仅 MySQL 广告此能力。
每条查询必须是一条可验证的非锁定只读 SELECT；`per_query` 可接受可验证只读 CTE。
列映射按从 0 开始的结果位置定位，不猜重名字段。省略 columns 时按原列名导出全部列为文本。
`expected_rows` 是可选硬性断言，允许 0，不符合则整个任务失败。不默认额外 COUNT。

示例 SQL 仅说明接口，不能代替实际生产业务口径：

```json
{
  "connection_id": "<已授权连接 UUID>",
  "database": "<已授权数据库>",
  "format": "xlsx",
  "filename": "2026-10.xlsx",
  "idempotency_key": "<新生成的随机 UUID>",
  "timezone": "+08:00",
  "consistency": "single_snapshot",
  "queries": [{
    "name": "用户",
    "sql": "SELECT id, created_at FROM users WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01' ORDER BY id",
    "columns": [
      {"source_index": 0, "title": "用户 ID", "type": "text"},
      {"source_index": 1, "title": "创建时间", "type": "datetime", "date_format": "yyyy-mm-dd hh:mm:ss"}
    ]
  }],
  "limits": {"max_rows": 100000, "timeout_seconds": 600}
}
```

返回字段包括 status、current_query（从 0 开始）、queries[].rows_written、total_rows、
complete、effective_limits、consistency、timezone、时间戳及 warnings。
只有 succeeded 返回 artifact.local_path、manifest_path、filename、size_bytes、sha256、media_type。
失败任务的部分计数仅用于诊断，不表示文件可用。
相同 idempotency_key 和相同请求/连接返回同一任务；参数变化必须用新 UUID。
该 key 也是提交恢复凭据，应保密。新 key 重试整项任务，使用新快照，不能续接旧行号。

## 文件及类型

XLSX 每条查询一个独立 sheet，表头加粗、冻结首行、筛选、按表头及首行样本估算有限列宽。
名称不区分大小写去重，最多 31 个 UTF-16 单位，拒绝非法名称；不自动拆表或截断。

- NULL 写空单元格；空字符串写显式文本；默认文本保持前导零、ID 和手机号。
- integer 仅对规范且不超过 15 位的整数写数值，其他保留文本。decimal 始终保留原始文本，
  不经过 Double；需要在 Excel 中计算金额时须由使用者明确转换。
- date/datetime 仅显式指定 date_format 时写原生 Excel 日期，支持 yyyy-mm-dd 和
  yyyy-mm-dd hh:mm:ss。微秒、零/非法日期、1900-03-01 之前日期保留原文，报告文本降级计数。
- timezone 是 MySQL UTC 偏移，默认 +00:00，例如 +08:00，影响 TIMESTAMP 读取；
  DATETIME 是墙上时间，不自动位移。Excel 日期不含时区，偏移记录在 manifest。
  暂不支持命名时区或夏令时转换。
- 公式样式文本和表头一律使用 inline string，不生成公式/外部链接。
  保留 SpreadsheetML/XML 转义；超出 32,767 UTF-16 单位的单元格明确失败。
- 拒绝只有预览的二进制，不把 BINARY 占位符作为完整数据。

CSV 使用 UTF-8 BOM、逗号、CRLF、带引号字段及双写双引号。
单查询生成 .csv 和 manifest；多查询生成 .zip，包含 1-名称.csv、2-名称.csv 及 manifest.json。
NULL 标记是 `\N`；非 NULL 原值的反斜杠双写，因此字面量 `\N` 不与 NULL 混淆。
空字符串是空引号字段。公式/控制/前导空白或数字开头的风险值，在引号内加一个 TAB。
解码先识别 NULL 标记，再去除新增的首 TAB，最后还原双写反斜杠。
此策略改变 CSV 表示并记录在 manifest，不能保证所有表格软件自动识别类型；应以文本导入，
需要可靠类型及公式文本安全时优先 XLSX。

## 授权和快照

复用已保存连接、凭据、数据库范围。即使连接是完整访问，导出也强制只读 SQL 校验。
拒绝多语句、写入、INTO、可执行注释、不可验证函数、会话变量及锁定查询；后端事务也只读。
不使用 OUTFILE、Shell、任意文件路径或新增数据库授权。

默认 single_snapshot：同一专用 MySQL 会话，REPEATABLE READ + WITH CONSISTENT SNAPSHOT + READ ONLY。
只支持可验证的 InnoDB 基础表，持有表元数据锁后复核引擎；视图、CTE 和不可确认来源明确拒绝。
不承诺分布式或跨连接快照。per_query 显式允许每条查询各自只读事务，两表可能不同快照。
专用连接将 SQL_SELECT_LIMIT 显式设为最大值，不能用可能继承全局上限的 DEFAULT。
SQL 自带 LIMIT 属于查询本身，不会移除。所有查询必须正常 EOF，驱动/写入行数一致，列结构稳定。

每条查询及发布前复核授权和连接；250ms watchdog 检查取消、总超时和授权/配置变化，变化时保守停止。
状态读取再次检查当前权限。已交付副本不能撤销。

## 预算及生命周期

上限：20 条查询，256 个来源/输出列，总计 100 万数据行，每行原始值 8 MiB，成品 512 MiB，
未压缩输出 2 GiB，总时长 600 秒（含排队）；调用方只能降低。
每次数据库查询还遵循 MCP 查询超时，初始化/探测上限 30 秒。
原生流在 Swift 解码前检查单行预算；底层客户端库仍可能先分配一个网络行。

同一数据目录的多个进程共用文件锁：最多 2 个活动导出、每连接 1 个、20 个排队/活动任务、
200 条保留记录，以及 2 GiB 成品预留预算。活动任务按申请的成品上限预留；这些导出槽位不替代
现有普通查询的每客户端连接限制。驱动批次背压和 inline strings 避免全量明细驻留内存。

状态：queued → running → finalizing → succeeded；异常终态 failed/cancelled/interrupted。
进度返回已写行数和当前查询，建议每 0.5–1 秒轮询；未知总量时不伪造百分比，也不预先执行 COUNT。
取消先返回 cancel_requested，需等待终态。任意一张表失败即整份失败；不自动重试。
提交成品是取消与完成竞争的提交点，完成后取消不能把成功文件误标成失败。

文件位于 `<数据目录>/MCP/Exports/<job UUID>/`，目录 0700、文件 0600。
仅接受文件名，默认不覆盖，不支持任意绝对路径。写 artifact.partial，完成计数、文件关闭及哈希后
原子移动到成品文件名。进程 owner 锁在进程死亡时释放；再次访问标记 interrupted 并清理残片。
不恢复游标。成品默认保留 24h，服务运行时及停机后下次维护/提交时清理；所有宿主停止期间
不能准时清理。delete_export 可主动清理。

## 运行模式和驱动兼容

任务管理器独立于 MCP 协议会话。独立 HTTP/launchd 不依赖桌面；stdio 进程必须存活，退出即中断。
App Store 内嵌 MCP 依赖宿主进程并使用沙盒数据目录。无需保存弹窗或桌面输入模拟。
本机路径要求调用方共享服务器文件系统；远程 HTTPS 下载、票据、Range 交付属于后续阶段。
PostgreSQL 普通查询仍有全量缓冲，Doris 快照语义不同；Redis/ES/Kafka/Milvus 不属于本轮 SQL 导出。

MySQL 实现新增可选 WorkspaceQueryExportConfiguring 能力，向已有 MariaDB V4 流传递行预算。
旧驱动导出明确提示升级，原有查询仍可用；WorkspaceSession 既有 vtable、MariaDB transport ABI 不变。
发布前必须分配主程序/MCP/MySQL 新身份，并将 MySQL minimumAppVersion 提升到首个包含新协议符号
的主程序版本，不能发布给旧宿主。本次实现不发布、不覆盖正式组件；按 RELEASE_PROCESS.md 完成
双架构、七驱动兼容及组件签名检查后才能发布。

## 验证

MCPExportTests 覆盖输入/权限、类型/多表、CSV ZIP、超限、所有权、幂等、会话关闭、取消/撤权、
进程中断、第二表失败，以及 4,404×5 + 56,945×4 的完整写出。
现有导出和 MCP 权限/发现测试作为回归门禁；native/隔离 MySQL 验收结果记录在 progress.md。
`scripts/test-mcp-query-export.py` 接受已打包的 MCP executable、`--drivers-dir` 和 `--output`，
创建临时 loopback Docker MySQL、独立数据目录和合成数据，结束后删除容器及临时连接。
它检查真实驱动加载、全局/聊天行数限制绕过、跨表并发修改时的一致性快照、中文 CSV ZIP、
锁等待中的原生取消/超时，以及超限和第二表失败不交付残片。
这些测试不代表生产业务 SQL、真实十月数据或远程下载已验收。
