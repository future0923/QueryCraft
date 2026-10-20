# 数据传输

入口：**工具 → 数据传输…**。原生可调整大小的独立窗口，左侧保存任务，右侧配置来源、目标、对象与传输策略。关闭窗口不停止后台任务；退出程序时可取消并等待当前事务结束。

来源和目标按两行对齐，每行依次选择连接、数据库和 PostgreSQL Schema。下方左侧是对象列表，右侧是统一宽度的配置表单，底部保留状态与保存、预览操作。208 点任务栏可从顶部“已存任务”展开，没有保存任务时默认收起。逐表过滤在已选表的对象行设置；批大小、超时和 PostgreSQL 所有者直接展示在配置列，任务名称和文件夹在“保存任务…”中设置。传输流程不设安全锁，经过 SQL 预览后确认执行；覆盖和重建仍需确认操作范围。默认窗口 1060×740，窗口最小尺寸 920×660。

连接、数据库与 Schema 的选择器共用表格字段选择器的原生搜索框和列表：不透明背景、左侧勾选、整行选中、方向键导航、回车选择及 Esc 关闭。传输说明及空白引导使用较高对比度文字；“已存任务”按钮保留键盘操作并关闭矩形焦点环。

功能对照以本机 `/Users/weilai/.codex/reference-repos/DBX` 的 `3de07819` 为基准，核对了 DataTransferDialog、ObjectSelectionTree、TransferTaskTree、任务库、transfer runner 和传输核心。实现使用 QueryCraft 自己的 Swift/AppKit/SwiftUI 和现有会话接口。

## 配置与任务

| 配置 | 行为 |
| --- | --- |
| 源和目标 | 可搜索的连接、数据库和 PostgreSQL Schema；可交换两端 |
| 对象 | 表、视图；同引擎按能力开放物化视图、过程、函数、触发器、序列和事件；重载函数使用目录 OID 和完整签名区分 |
| 选择 | 搜索、全选/取消全选、批量粘贴名称匹配，反馈未匹配项 |
| 逐表过滤 | WHERE 条件或单个完整 SELECT；完整 SELECT 需返回所有可写列并保留原字段名；禁止多语句、写入、锁定和可执行版本注释 |
| 内容 | 默认结构和数据；可选仅结构、仅数据 |
| 目标处理 | 默认追加；覆盖、Upsert、重建；仅结构还支持保留已有对象和重建，MySQL 非表对象可显式替换 |
| 表名 | 保持原样、转小写、转大写；名称冲突和目标标识符长度超限在规划时拒绝 |
| 批大小 | 默认 1000，范围 100～10000；写入还按目标包大小拆分 |
| 超时 | 默认驱动/数据库默认值；自定义 0～3600 秒。PostgreSQL 使用 statement_timeout，MySQL 使用 SELECT 执行超时和锁等待超时；这不是整个任务总时长或所有网络等待的硬截止时间 |
| PostgreSQL 所有者 | 保留、跳过、缺失角色映射到目标当前用户；保留模式存在缺失角色时必须返回修改 |

保存任务包括两端位置、选中对象、过滤、内容、策略、大小写、批大小和超时；不保存密码或“已确认破坏操作”的授权。支持任务复制、重命名、删除、文件夹层级、移动和拖动调整。切换任务和关闭未保存配置时提示处理修改。配置文件原子替换；损坏或未知版本不会被空任务库覆盖。

## 执行与数据语义

- 预览实际规划的结构、约束、所有者及备份清理 SQL。开始前重新获取元数据，字段、对象存在性、SQL 或物理实例身份变化后必须重新预览。
- SQL 预览的对象映射显示“来源库.对象 → 目标库.对象”；PostgreSQL 同时包含数据库和 Schema。各段按引擎标识符规则引用，名称中的点、空格和引号不会被误当成层级；名称中的换行在注释行中转义显示。
- 所选表的数据传输方式和批大小汇总为一条说明，并列出表数量；不再为每张表重复输出同样的批处理注释。对象列表用分组名称区分类型，不显示逐行及分组下划线。
- 源/目标不仅按连接 ID 判断，还核对 MySQL server UUID、PostgreSQL system identifier 及兼容回退信息，防止不同连接别名指向相同位置。运行任务按实际目标实例/数据库/Schema/对象互斥。
- MySQL 和 PostgreSQL 来源在独立只读、可重复读事务中按固定排序分批读取；不能调用会为每次读取另起事务的旧导出接口。普通表或 WHERE 过滤若具有单个非生成、非空的精确数值主键，使用上一批末尾主键继续读取，避免 OFFSET 深分页；主键值直接使用经校验的精确数值字面量，不经过 Double。完整 SELECT、复合/文本/浮点主键、生成主键及无主键表保留原 OFFSET 方式；无主键时按完整字段文本/字节排序，这些场景的大数据量传输可能较慢。Doris 不启用主键分页优化。
- MySQL 二进制列使用 HEX 读取完整字节，PostgreSQL bytea 使用完整十六进制文本；不读取网格截断预览。大整数和小数不经过 Double，NULL、空字符串和文字 NULL 分开处理。
- 每张表一次性准备字段编码、列顺序、identity 和 Upsert 语句片段，各批次直接拼接 SQL 并复用规则，避免逐格重复解析字段类型和复制元组数组。文本按 UTF-8 字节转义，正确处理引号/反斜杠后接组合字符；MySQL/Doris 的控制字符和反斜杠使用十六进制，PostgreSQL 拒绝 NUL。
- MySQL 目标需 InnoDB 且验证 STRICT_ALL_TABLES。生成列不写入，PostgreSQL identity 支持 OVERRIDING SYSTEM VALUE；写入后推进目标序列且不倒退已有正向序列。
- 追加和 Upsert 每表一个事务。覆盖先按依赖反序清空，再按正序写入所有所选表，统一提交或回滚，避免先永久清空子表再因父表失败留下半套数据。Upsert 需要完整目标主键，MySQL 使用原生 ON DUPLICATE KEY，PostgreSQL 使用 ON CONFLICT。
- 重建先把旧表改名为 `__qc_bak_` 备份，之后创建、写入并建立约束。只有全部表、外键、对象和所有者处理成功才删除备份；失败或取消保留仍存在的备份并显示名称。不能承诺 MySQL DDL 跟随数据事务回滚。
- 新表外键在数据写入后建立。视图、物化视图、触发器、事件也在数据完成后建立，避免新复制的触发器作用于历史数据，以及物化视图过早读取空表。例程和序列可先于表执行，以满足默认值等依赖。
- 取消是合作式取消，等待当前数据库请求返回，再回滚当前数据事务；此前已提交的数据与已创建结构保留。COMMIT/ROLLBACK 不被 UI 取消中断。响应丢失时显示结果未知，不自动重试写入。
- 任务记录读取行数、已确认提交行数、每个对象的结果及原表备份。重启后未结束任务标为中断，需要核对目标；不会自动重放。

## 六驱动与页面范围

| 驱动 | 来源 | 目标 | 边界 |
| --- | --- | --- | --- |
| MySQL / MariaDB | 支持表及同引擎目录对象 | 支持，表需 InnoDB | 特定版本的例程/事件权限和 DEFINER 仍由服务器检查 |
| PostgreSQL | 支持表及同引擎目录对象 | 支持 | 同引擎复制约束、普通/表达式索引、生成列、identity、注释、列排序规则；自动准备当前 Schema 枚举及枚举数组 |
| Doris | 表来源 | 当前驱动只读，不提供目标 | 无事务一致性快照，需要来源静止；不传输 HLL/BITMAP/AGG_STATE 等聚合状态和复杂类型 |
| Redis | 不适用 | 不适用 | Key 类型、TTL 和冲突需专用迁移协议 |
| Elasticsearch | 不适用 | 不适用 | Mapping、文档 ID、Bulk 逐项结果需专用链路 |
| Kafka | 不适用 | 不适用 | 消息字节、分区、Headers 和交付语义需专用转发链路 |

本功能在工具菜单和独立工作台接入；原有表数据页、SQL 查询结果页的文件导出及表右键导入保持原链路。未新增查询结果网格“导出到数据库”和侧边栏复制粘贴入口，不能把它们计作已完成的 DBX 功能。

跨 MySQL/PostgreSQL 的表按字段元数据生成目标类型，复制主键和可表达的默认值；不翻译任意生成表达式、例程、外键、非主键索引和表选项，预览明确列出范围。MySQL tinyint(1) 仍可存储 0/1 以外的数值，因此转换为 PostgreSQL smallint，不根据显示宽度猜测布尔语义。时区时间、位串和不能无损转换的类型明确拒绝。

尚不等同于完整数据库迁移工具：不迁移账号授权、RLS 策略、扩展、任意自定义类型/排序规则、跨命名空间依赖和动态 SQL。PostgreSQL 分区/继承图不自动克隆，需预先准备目标结构并使用仅数据模式；同一数据任务不得同时选择父表和子分区，避免父表读取已经包含子表数据时重复写入。MySQL 重建表时若同名选中触发器仍属于原表备份，规划会拒绝替换，避免破坏备份。复杂依赖必须明确修正，不能静默降级成全 TEXT 或伪造元数据。

## 验证记录

2026-10-19 已完成的核心验证：

- 最终 8 个测试套件、84 个方法通过，0 失败、0 跳过；包括传输 SQL、任务库、执行器、离屏布局/慢请求/刷新状态，以及现有导入、导出和驱动注册回归。
- 实库 MySQL 5.7 → 8.0、PostgreSQL 17 → 17、MySQL → PostgreSQL、PostgreSQL → MySQL 各 203 行逐字段一致，覆盖完整二进制、30 位小数、Unicode、引号、反斜杠、NULL 和空字符串。
- 四组均验证创建/追加、Upsert、覆盖、WHERE/完整 SELECT 过滤、大写目标表名、自定义超时 0/1、取消覆盖后原数据完整回滚；同引擎另验证外键关联表重建、视图替换、索引、例程、触发器及成功后备份清理。
- PostgreSQL 另验证枚举及枚举数组、生成列、identity 后续生成值、独立序列当前位置、列注释，以及视图 security_barrier/security_invoker/CHECK OPTION；物化视图在数据完成后正确填充。
- `scripts/test-database-transfer.py` 使用唯一临时库/Schema，凭据仅驻留内存，不读取用户保存连接；最终清理夹具和临时 PostgreSQL 容器。
- `scripts/verify-data-transfer-ui.py` 仅在仓库蒙屏/输入隔离助手确认就绪后进行可见原生窗口截图，Esc 和五分钟看门狗可解除。本次用户按 Esc 停止，已解除隔离，未取得完整截图，因此可见界面验收尚未完成。普通布局回归保持离屏，不模拟物理鼠标或键盘；离屏缓存位图缺少部分系统控件图层，不能替代可见界面验收。
- 最终 Debug 构建成功；六类已安装 API 5 驱动全部通过加载及激活检查。签名 Dev 已安装到 `/Applications/QueryCraftDev.app`，标记 `20261019-155653-d6bcfc35`；旧 Dev 已备份，本次安装后没有启动窗口。

未修改 Driver API 或外部驱动。Doris 真实传输及 MariaDB 不在上述实库矩阵中；六驱动加载检查不能代替这两项实库验证。没有提交、打 tag 或发布。

布局修订后，5 个展示及状态回归方法通过，覆盖首次空白配置、已选对象、慢请求、失败重试、成功为空及任务切换。离屏 CALayer 渲染补齐了原缓存截图遗漏的控件层，已检查浅色/深色、最小窗口和常规窗口的布局；没有重新进行前台输入或蒙屏验证。

布局修订的 Debug 构建成功，签名 Dev 已更新并重新启动，标记 `20261019-161457-f6c8802a`。

后续层级修订采用顶部两行连接、左侧对象与右侧配置的布局，空任务栏默认收起。5 个展示/状态回归方法再次通过，新增实际下拉控件宽度、对齐、窗口边界和选项回写校验。Debug 构建通过，最新签名 Dev 标记为 `20261019-163229-d1a53bba`，已安装并重新启动。

选择器共用、移除传输安全锁、展开配置、文字对比度、任务按钮焦点环和预览库名修订后，36 个 SQL/执行器/展示/表格搜索回归方法通过，0 失败、0 跳过；Debug 构建通过。用户确认退出后已安装并重启签名 Dev，当前标记为 `20261019-164722-ddfa9b54`。

去除对象列表逐行/分组横线、合并批处理说明后，26 个 SQL/执行器/展示回归方法通过，最终 6 个展示方法再次通过；均无失败或跳过。Debug 构建通过，已安装并重启签名 Dev，标记为 `20261019-165820-25888978`。

### 2026-10-20 INSERT 基线（原生通道接入前）

该基线引擎使用 Release `-O`、关闭 Swift/Clang 覆盖率插桩；为独立测试程序开放 testable 导入。使用用户 Dev 中实际安装的 API 5 驱动，未修改或替换外部驱动。六类驱动均通过 Release 主程序的加载/激活检查。SQL/执行器/表数据导出的 29 个回归方法通过，另有四方向各 1003 行的实库小样本验证。

测试直接调用实际 `DataTransferPlanner`、`DataTransferManager` 和 `DataTransferRunner`，启动后调用工作台模型关闭路径并释放模型，确认后台执行继续、最终历史可持久化。没有模拟鼠标或键盘，也没有进行前台界面交互压测。

本机 Docker VM 为 16 vCPU、约 7.66 GiB 内存；每个测试数据库容器限制 4 CPU、2 GiB。MySQL 5.7 和 8.0 为两个容器；PostgreSQL 17 在同一容器的不同 Schema 间传输。固定每批 **1000 行**，每张表五列，含超过 2⁵³ 的整数 ID、30 位精确小数、16 字节二进制、布尔/0–1，以及中文、Emoji、引号、反斜杠、换行、组合字符、NULL、空字符串。

| 来源 → 目标 | 行数 | 传输耗时 | 平均行/秒 | 测试进程采样峰值 RSS |
| --- | ---: | ---: | ---: | ---: |
| MySQL 5.7 → 8.0 | 1,000,000 | 34.11 秒 | 29,319 | 31.98 MiB |
| PostgreSQL 17 → 17 | 1,000,000 | 32.79 秒 | 30,496 | 33.40 MiB |
| MySQL 5.7 → PostgreSQL 17 | 1,000,000 | 30.52 秒 | 32,768 | 33.37 MiB |
| PostgreSQL 17 → MySQL 8.0 | 1,000,000 | 36.74 秒 | 27,215 | 35.78 MiB |
| MySQL 5.7 → 8.0 | 10,000,000 | 376.35 秒 | 26,571 | 39.74 MiB |
| PostgreSQL 17 → 17 | 10,000,000 | 321.83 秒 | 31,073 | 37.70 MiB |

以上全部提交成功，目标行数、ID 汇总及每行文本/精确小数/二进制/标志值校验均为零差异。耗时包含执行阶段的元数据二次校验和事务提交，夹具生成与整表校验时间另计；RSS 每秒采样，属于无可见工作台的测试进程，不代表完整 App 的总内存。最长 100ms 主线程心跳间隔约 0.215 秒，不能替代可见 UI 的交互验收。

另在两种引擎分别执行追加、覆盖的取消，共 4 项：读入约 10 万行后取消，均报告 0 行提交；追加目标经查询为空，覆盖目标原有哨兵行及所有字段完整保留。MySQL 取消完成约 0.72/0.83 秒，PostgreSQL 约 0.11/0.11 秒。测试容器及其数据卷均已清理，未读取用户保存连接或操作真实数据库。

本轮优化为单个精确数值主键的索引分页、预备字段/INSERT 编码器、UTF-8 字节转义及减少中间数组复制。SQL 生成微基准在 `-O` 下从 100,000 行约 3.20 秒降到 0.40 秒；整体传输收益见上表。较早 MySQL 千万行 Debug 基线为 1221.24 秒，当前 Release 为 376.35 秒，包含代码与编译配置两项变化，不能作为单独一种优化的倍数。该基线尚未接入原生 COPY/LOAD DATA 通道；下节记录新的原生实现。

跨引擎本轮覆盖百万行，千万行覆盖两个同引擎方向。Doris 未做真实大数据传输，MariaDB 未实测；Redis、Elasticsearch、Kafka 不适用关系表传输，仅通过驱动加载和能力边界检查。原有表数据页/SQL 结果页的文件导入导出链路保持原范围。

本次工作区原始结果：

- 小样本：`.build/validation/transfer-performance/20261020-092101-7dde85/results.json`
- 百万行：`.build/validation/transfer-performance/20261020-092307-6c548a/results.json`
- 千万行与取消：`.build/validation/transfer-performance/20261020-092837-0b7533/results.json`
- 编码对照：`.build/validation/transfer-performance/20261020-082925-b71930/encoding-baseline/` 和 `encoding-comparison/`

可复现命令（需先构建上述 Release 测试引擎；脚本默认只测百万行，千万行显式选择）：

```sh
python3 scripts/benchmark-database-transfer.py --configuration Release --rows 1003 --skip-cancellation
python3 scripts/benchmark-database-transfer.py --configuration Release --rows 1000000 --skip-cancellation
python3 scripts/benchmark-database-transfer.py --configuration Release --rows 10000000 --cases mysql-mysql postgresql-postgresql
```

该基线的签名 Dev 使用上述 Release 产物安装并启动，标记 `20261020-094450-26feb753`，`QCDevelopmentConfiguration=Release`；已核对安装后的主功能框架 UUID 与测试的 Release 产物一致。旧 Dev 已备份，未提交、打 tag 或发布。

### 2026-10-20 原生批量与持续流式传输

通道由驱动能力自动选择。MySQL 使用受控的 `LOAD DATA LOCAL INFILE`，PostgreSQL 使用 `COPY FROM STDIN`。PostgreSQL 同类型字段、普通 WHERE 过滤可直接 `COPY TO STDOUT → COPY FROM STDIN`；完整 SELECT 可能改变结果类型，必须经过字段编码和二进制校验。MySQL/Doris 使用未缓冲结果流，PostgreSQL 转换路径使用单行模式，读取与写入通过有界通道重叠执行。

Upsert 先导入私有临时表，再按配置的批次和来源顺序执行 `INSERT … SELECT` 合并，沿用原有冲突子句，不使用 REPLACE、不去重、不关闭触发器。临时表序号有索引，避免每批重新全表扫描。临时表准备由 SAVEPOINT 保护；权限或代理限制导致准备失败时，先恢复事务，再使用普通 Upsert，尚未写入目标数据。MySQL 未开启 LOCAL 时采用持续流式读取和批量 INSERT；PostgreSQL 的 RLS、INSERT 规则、语句级触发器保留原有 INSERT 语义。

MySQL LOCAL 会把部分数据错误转换为警告，因此任何导入警告都会中止提交并回滚，且额外核对导入行数。客户端默认拒绝所有 LOCAL 文件请求，本次任务的回调只接受随机令牌对应的内存流，不读取文件。参见 [MySQL LOAD DATA 文档](https://dev.mysql.com/doc/refman/8.0/en/load-data.html)。PostgreSQL COPY 的行级安全限制及输入行为参见 [PostgreSQL COPY 文档](https://www.postgresql.org/docs/current/sql-copy.html)。

内存通道最多排队一批；另有生产者和消费者各自的当前批次。行批次由配置行数或 1 MiB 限制（另加最大单行），编码块为 256 KiB，C 写入块为 64 KiB，不累计整表数据。界面进度最多每 100ms 报告一次，最终行数精确同步。取消会唤醒两端并中断数据库查询；失败时丢弃专用只读来源连接，避免继续排空整张来源表，目标仍按原事务范围回滚。

Doris 继续仅作为来源，支持原生协议的流式读取。补齐 STRING、DECIMALV2/DECIMALV3、DATEV2/DATETIMEV2 的标准类型映射，并修正旧版来源的 keyless 排序语法。PostgreSQL TEXT、无长度 VARCHAR 和 Doris STRING 自动建 MySQL 表时映射为 LONGTEXT，避免 64 KiB 容量限制；目标已有字段容量不足时不会静默接受 MySQL LOAD 的截断警告。Doris 仍要求来源静止；聚合状态及复杂类型继续明确拒绝。

现有 Driver API 5 的协议表及公共模型布局保持不变，新增可选能力协议。新 MySQL/PostgreSQL/Doris 包要求主程序至少 0.1.10。MySQL 与 Doris 使用独立名称的 `QueryCraftMariaDBTransportV2`，可与旧 V1 动态库同时加载，支持两类驱动独立升级。Redis、Elasticsearch、Kafka 不适用本次关系表通道，保持原有实现。

本轮主引擎和修改的 MySQL/PostgreSQL/Doris 驱动均使用 Release `-O`，关闭覆盖率插桩。固定每批 1000 行；硬件、Docker 限额、五字段数据及全行校验规则沿用上节基线。追加包含创建目标表和最终提交；Upsert 预先在目标准备同样数量的旧值，要求每行全部更新正确，预置夹具及验证时间不计入传输耗时。

| 来源 → 目标 | 行数 | 策略 | 传输耗时 | 平均行/秒 | 测试进程采样峰值 RSS |
| --- | ---: | --- | ---: | ---: | ---: |
| MySQL 5.7 → 8.0 | 1,000,000 | 追加 | 11.33 秒 | 88,236 | 34.25 MiB |
| MySQL 5.7 → 8.0 | 1,000,000 | Upsert | 38.17 秒 | 26,199 | 36.39 MiB |
| PostgreSQL 17 → 17 | 1,000,000 | 追加 | 4.43 秒 | 225,622 | 26.22 MiB |
| PostgreSQL 17 → 17 | 1,000,000 | Upsert | 13.82 秒 | 72,371 | 34.86 MiB |
| MySQL 5.7 → PostgreSQL 17 | 1,000,000 | 追加 | 4.55 秒 | 219,943 | 37.68 MiB |
| MySQL 5.7 → PostgreSQL 17 | 1,000,000 | Upsert | 13.54 秒 | 73,848 | 39.03 MiB |
| PostgreSQL 17 → MySQL 8.0 | 1,000,000 | 追加 | 11.00 秒 | 90,892 | 37.28 MiB |
| PostgreSQL 17 → MySQL 8.0 | 1,000,000 | Upsert | 37.71 秒 | 26,515 | 39.22 MiB |

上述 8 项全部提交成功，行数、ID 汇总和每行五字段校验均为零差异；每项实际进度均确认使用 COPY 或 LOAD DATA。百万行追加相比上节实测分别约 3.01×、7.40×、6.71×、3.34×；此前安装驱动的独立编译模式没有留证，因此这是整体版本的前后实测比较，不能归因于单一改动。RSS 为无可见工作台的引擎测试进程，每秒采样，不代表完整 App 总内存。

最终 45 个 SQL/执行器/编码器/表数据导出回归方法通过，0 失败、0 跳过。四个实际数据库方向另外覆盖创建、追加、Upsert、覆盖、过滤、二进制、Unicode/组合字符、精确数值、超宽文本、警告回滚、错误/取消后的恢复，以及无 TEMP 权限时回退。额外验证关闭 MySQL LOCAL 后仍可流式读取并使用 INSERT。

六类驱动完成加载/激活检查；Doris → MySQL/PostgreSQL 小样本传输及自动建表类型转换通过，并分别验证新新、旧 Doris/新 MySQL、新 Doris/旧 MySQL 三种实际组合。Doris 未做千万行实测，MariaDB 服务端未实测；Redis、Elasticsearch、Kafka 不适用本次关系表通道。表数据页、SQL 结果页的文件导入导出未切换到本通道。

百万行原始结果：`.build/validation/transfer-performance/20261020-113229-5a65b4/`。每次压测目录保存 `results.json`、逐项日志/RSS、`environment.json` 和 `provenance.json`；指纹包含主引擎 UUID/SHA256 及六类驱动的实际二进制哈希、版本与 API/最低主程序版本。测试只使用随机自建 Docker 夹具，不读取用户连接，结束删除本轮容器和数据卷。

四方向千万行追加的最终结果：

| 来源 → 目标 | 传输耗时 | 平均行/秒 | 测试进程采样峰值 RSS |
| --- | ---: | ---: | ---: |
| MySQL 5.7 → 8.0 | 102.06 秒 | 97,984 | 36.62 MiB |
| PostgreSQL 17 → 17 | 45.75 秒 | 218,600 | 26.34 MiB |
| MySQL 5.7 → PostgreSQL 17 | 48.94 秒 | 204,326 | 40.05 MiB |
| PostgreSQL 17 → MySQL 8.0 | 121.81 秒 | 82,096 | 40.62 MiB |

四项均实际提交 10,000,000 行，每项 ID 汇总为 50,000,005,000,000，逐行五字段校验均为零差异。MySQL 同引擎相比上次 Release 实测约 3.69×，PostgreSQL 同引擎约 7.04×。100ms 主线程心跳最大间隔约 0.147 秒；它验证后台调度，没有进行物理输入或可见 UI 验收。

随后对两类引擎分别取消追加、覆盖、Upsert 合并，共 6 项：追加与覆盖约读入 10 万行后取消，Upsert 在 100 万行导入临时表并开始合并后取消。全部报告 0 行提交，实库确认追加为空、覆盖原哨兵行完整保留、Upsert 的 100 万条旧行及全部字段完整恢复。

| 引擎 | 取消追加 | 取消覆盖 | 取消 Upsert 合并 |
| --- | ---: | ---: | ---: |
| MySQL | 0.722 秒 | 0.724 秒 | 4.280 秒 |
| PostgreSQL | 0.109 秒 | 0.109 秒 | 0.107 秒 |

取消耗时从发出取消到任务完成回滚；Upsert 的回滚仍有数据库自身处理时间。原始结果及产物指纹：`.build/validation/transfer-performance/20261020-113616-289698/`。MySQL/PostgreSQL/Doris 测试包均为本地候选 1.0.6 build 8、API 5，最低主程序 0.1.10；没有发布到公共驱动目录。

可复现原生测试（先构建相同 Release 主程序和驱动，在 `--driver-root` 指定实际包目录；不加 `--require-native` 时允许测试降级通道）：

```sh
python3 scripts/benchmark-database-transfer.py --configuration Release --rows 1000000 --strategies append upsert --skip-cancellation --require-native --driver-root .build/native-transfer-driver-catalog
python3 scripts/benchmark-database-transfer.py --configuration Release --rows 10000000 --require-native --driver-root .build/native-transfer-driver-catalog
```

签名 Dev 已以 Release 安装并启动，标记 `20261020-114655-8a63b4d1`。安装后的主功能框架 UUID `3CDC441A-DED7-3F94-8738-401A8C71EC0C` 与千万行测试产物一致；MySQL/PostgreSQL/Doris 包全部文件与候选包相同，六类驱动二进制哈希与测试指纹相同，其余三类包未修改。使用安装后的主框架通过六驱动加载检查，并核对实际 Dev 进程已加载安装目录中的六个驱动及新的 V2 传输框架。

旧 Dev 备份于 `.build/dev-app-backups/20261020-114655-8a63b4d1/QueryCraftDev.app`，旧三类驱动备份于 `.build/dev-driver-backups/20261020-114654-1719ba30/`。安装使用正常退出，没有强制结束用户 App。未模拟物理鼠标或键盘，未提交、打 tag 或公开发布。
