# QueryCraft 结构对比与同步设计

## 2026-10-16 当前实现与验证状态

按用户确认，核心全部使用 Swift；DBX 本地参考源码固定在 `3de078190e8f7cd3905e635ead0353d337b3e459`。产品无 Rust 源码、构建步骤、Cargo 依赖或辅助进程。参考算法的出处与 Apache 2.0 许可随应用资源保留。

原生独立窗口按「选择两端与范围 → 读取进度 → 选择差异 → SQL 审核 → 部署及结果」切换整页。连接和数据库使用 NSPopUpButton / NSComboBox，结果使用 NSOutlineView，DDL 使用 NSTextView / NSSplitView，配置使用原生文件面板。选项使用系统侧栏与 grouped Form；Glass 采用系统导航、工具栏和按钮，不给数据内容绘制玻璃卡片。

当前 MySQL 能力：

- 5.7 / 8.0 / 8.4 catalog 与原始 DDL；表、字段、普通/主键/唯一索引、组合外键、检查约束、生成列、视图、函数、存储过程、触发器内容及执行顺序。
- 对象范围、注释、字符集/排序规则、字段顺序、正则包含/排除及冲突优先级、可选字段/表重命名、兼容性提示、批次分组与回退脚本。MySQL 不支持的 PostgreSQL 对象禁用并说明原因。
- 差异选择联动依赖；索引与 AUTO_INCREMENT 字段合并 ALTER；建表依赖排序，外键延后创建；相同名称的函数和存储过程保持独立；存储程序导出使用 DELIMITER，直接执行保留整条语句。
- 独立审核、风险确认、逐条执行与日志。执行前重新读取两端，结构已变则拒绝旧计划；执行后再次读取并核对所选变更。失败停止后续语句。回退需单独审核，仅恢复结构，无法恢复已删除的数据。
- 元数据不完整、权限无法证明清单完整、catalog 与 DDL 不一致时中止；缺失数据不作为对象删除。刷新保留旧结果并禁止导出过期脚本，处理取消与过期回调。源/目标真实计数分别保存，进度位置固定。
- 使用现有 API 5 驱动和 WorkspaceSession，没有修改驱动协议或外部驱动包。PostgreSQL 的关系模型适用但尚无 adapter；Doris 的 DDL 能力不能按 MySQL 推断；Redis、Elasticsearch、Kafka 不使用此 SQL schema 模型。五类连接未开放到这个工具，共享数据页/查询结果页未改动。

本轮 90 项结构比较测试与 8 项 DDL 编辑器测试通过。隔离实库 5.7.44→8.0.46、5.7.44→8.4.11、8.4.11→8.0.46 已通过部署、回读收敛、结构回退、过期计划拦截及导出脚本独立执行。最后一组覆盖生成列、函数索引和检查约束。

2026-10-19 已完成最终原生界面回归：三个版本方向均走通连接切换、慢读取稳定进度、差异与审核、部署与回读、审核回退和四组选项；浅深色与 940px 窄窗口通过系统合成截图检查。DDL 改用系统分栏控制器，修复初始比例偏斜及执行页子按钮辅助功能标识。最终签名候选包为 `output/schema-comparison-build/native-swift-preview-20261019-ready/QueryCraftDev.app`；未覆盖 /Applications 稳定版。完整证据见 [回归记录](SCHEMA_COMPARE_REGRESSION.md)。

2026-10-19 结果页精修已完成：全流程底栏共用 large 系统 Glass 按钮及统一间距；列表/详情默认 60/40，用户拖动比例可保存；分组与表节点展示选择计数；DDL 使用原生行号、系统语义配色与缺失侧提示。最新已验证并严格签名的包为 `output/schema-comparison-build/native-glass-polish-20261019-verified/QueryCraftDev.app`，三个版本方向均重跑完整流程与实际部署/回退通过。

2026-10-19 按用户指定的现有表数据页规格调整：内容按钮统一为系统 bordered/borderedProminent、roundedRectangle、regular，复用 24pt 指标，底栏 44pt；不再使用 large Glass 胶囊。审核侧栏按数据库对象汇总所选字段/索引，底栏跨整个窗口。比较用 SQL 编辑器采用局部 contentInsets 并裁剪，修复大窗口正文与行号穿过顶/底栏；默认 DDL 页面行为不变。复制/导出无需风险确认，部署仍受确认限制。最新签名包 `output/schema-comparison-build/native-compact-review-20261019/QueryCraftDev.app` 的三个 MySQL 方向原生完整流程已验证。

审核页头部后续精简：右上统计改为更大、对比清楚的文字与彩色图标，移除中间设置/已审核整行，部署仅保留既有原生确认。最新包为 `output/schema-comparison-build/native-review-header-20261019/QueryCraftDev.app`，已通过代表性完整原生部署/回退及浅深色窗口复核。

以下为原始设计与后续方向，其中阶段性边界不是当前实现状态。

## 1. 产品方向

新增「结构对比与同步」工作台：选择两端 → 读取结构 → 审查差异 → 勾选变更 → 生成目标端 SQL → 执行 → 重新读取验证。源端代表期望结构，只有目标端接收变更；页面始终显示方向。

优先打通 MySQL 同类型数据库的完整闭环，再接 PostgreSQL。首批公开版本以同类型、已验证版本的数据库为边界；不因 Doris 使用 MySQL 协议就开放 MySQL→Doris 同步。数据同步和数据传输作为后续独立任务，复用连接选择、计划预览和执行记录。

竞品参考：

- [Navicat 官方结构同步介绍](https://www.navicat.com/en/company/aboutus/blog/1313-database-structure-synchronization-using-navicat-15)：借鉴源/目标选择、差异与双栏 DDL、部署脚本审查的分阶段流程。
- [DBX 官方 Schema 与数据对比文档](https://dbxio.com/cn/docs/schema-diff)：借鉴对象级勾选、依赖提示、可复用配置，以及结构对比与数据对比的清晰分工。

本方案后续的默认策略、模型、分期和界面安排是针对 QueryCraft 的设计，不代表竞品实现或现有产品能力。

## 2. 首版范围

### MySQL 第一条纵向链路

- 同类型、同主版本优先，先验证 MySQL 8.0；跨主版本和 MariaDB 不默认宣称兼容。
- 表、字段、主键、普通/唯一索引、字段与表注释。支持完整性已确认的普通表创建、增列、普通索引添加和已验证的字段属性修改。
- 主键、唯一索引、非空约束、类型改变、删除表/字段都显示差异，但需相应依赖与数据前置检查后才允许生成可执行计划；删除默认不勾选。
- 外键、Check、分区、生成列、特殊索引等先完成元数据识别与阻断规则。若不能完整采集或保真生成，标为「仅对比 / 需手动处理」，禁止生成会遗漏它们的建表或重建语句。
- 同名精确匹配；首版不推断重命名。疑似重命名仍展示为两项差异，不能自动组合成 DROP + ADD。
- 导出 SQL、保存对比配置、语句级执行记录、执行后复核必须纳入首个完整版本。
- 单表和整库使用同一个引擎；整库支持包含/排除对象，失败对象不得被当作不存在。

### 后续范围

1. PostgreSQL：database/schema 明确分层，字段、约束、索引、注释；再逐项开放 identity/sequence、视图等。
2. 补齐 MySQL 外键/Check/生成列/视图和 PostgreSQL 特有结构；实现依赖闭包后再扩充可执行操作。
3. Doris 只读结构对比；Elasticsearch mapping/settings 专项对比。
4. 数据对比与同步、数据传输；重命名映射、离线快照对比、批量多目标随后评估。

不在首版：跨数据库方言自动迁移、持续复制、CDC、定时同步、权限/用户同步、存储过程/触发器的自动部署、自动回滚数据、自动创建缺失的目标数据库。

## 3. 入口和窗口

QueryCraft 属于密集信息的专业工具。主流程放在已有工作区的「结构对比」内容页签中；选择连接与范围用短 Sheet 完成，避免把长时间审查放进阻塞主窗口的向导。

- 菜单新增「工具 → 结构对比与同步…」。后续实现数据同步/传输时再加入对应菜单项，不放可点击的空功能。
- 数据库/Schema 右键「与其他数据库比较结构…」，表右键「比较表结构…」，预填源端与范围。
- 内容页签标题示例：「结构对比 · dev → test」。重新打开已保存配置会重新读取元数据，不恢复旧计划为可执行状态。
- 页签归属于发起它的工作区上下文，但对比任务自己持有两端连接引用和专用会话，不依赖侧边栏当前选中表。切换主工作区连接不改变已配置的目标。
- 关闭页签/连接上下文时，比较任务可取消；执行任务需停在语句边界、查明当前语句结果并完成会话清理后再关闭。未保存配置走现有待保存机制；已提交 DDL 不支持 ⌘Z。

### 配置 Sheet

左右选择源与目标：连接、数据库、Schema（仅适用驱动显示）。连接名之外显示 host:port 与数据库版本；支持交换方向，但交换后清除选择与计划并重新比较。

对象范围支持全库/指定表，比较选项包括字段、索引、注释。默认忽略行数、存储大小、索引基数、自增当前计数、序列当前值等运行状态；列顺序默认不作为部署目标。字符集/排序规则等结构语义不能一律忽略。

拦截同一实际服务器上同一数据库/Schema 的自比较。连接 ID 不同不代表服务器不同，结合可取得的服务端身份、实际会话端点与库标识判断；无法核实身份时执行前明确目标证据，不把相同名称作为身份依据。

### 对比工作台

窗口顶部：沿用公共刷新按钮（此处语义为重新读取两端并比较）。内容顶部固定显示「源 → 目标」、范围和快照时间。

主区域左右分栏：

- 左侧约 280pt：对象树、搜索和「差异 / 全部」筛选；表下展开字段/索引/约束。状态为「待新增、待修改、目标独有、一致、无法比较、仅对比」。统计单位固定为差异项，不能混用表数和 SQL 数。
- 右侧：对象路径；「结构差异 / 两端 DDL / 此对象 SQL」切换。结构差异表列为属性、目标当前值、源期望值、拟执行操作。两端 DDL 明确标源/目标；空白与格式差异不冒充语义差异。
- 底部复用一行：左侧加载/错误/选择摘要，右侧「保存配置」「导出 SQL」「预览同步」。危险变更数量紧邻主操作。辅助按钮不额外占行。
- 首次结果不默认勾选任何变更，提供「选择可执行新增项」。目标独有不等于应删除，保留为默认处理方式。
- 不允许仅按分类全选跳过风险审查；选择操作需要添加依赖时，展示将连带选择的对象。取消依赖要同步取消或阻断依赖者。

### 预览和结果

点击「预览同步」在同一页签进入审查面板，可返回差异选择。显示目标连接/地址/database/schema、选中差异数、SQL 语句数、事务边界、风险说明和完整脚本。

脚本按执行顺序只读展示；复制/导出允许。首版不在这里随意编辑 SQL，以保证审查内容等于执行内容。「在查询页打开副本」属于手工 SQL 流程，不继承自动同步的验证结论。

「执行到目标…」打开确认 Sheet，绑定具体计划及摘要；破坏性操作需明确确认其对象。已有安全锁仍为硬门槛，不能因进入同步页面自动解锁。首版不引入对所有低风险点击反复确认的流程。

执行期间显示逐句状态：待执行、执行中、已提交、已回滚、失败、结果未知、未执行。取消意为停止发送后续语句，不承诺中断或撤回已提交 DDL。成功后重新读受影响对象，显示「所选变更已验证」；仍未选择的差异保留，不宣称整个数据库完全一致。

### 加载与原生体验

- 首次打开立即保留对象区、表头、详情容器和固定底栏；底栏轻量进度。不闪空态。
- 状态分为未加载、加载中、成功（含空结果）、失败；局部失败进一步记录对象/元数据分区。
- 重新比较保留旧内容、选择与滚动位置，同时标记「正在更新，暂不可执行」。成功后只保留定义和差异指纹未变的选择；失败保留旧内容但标记过期。
- 变更连接/对象范围时旧结果不作为新范围结果；任务 generation ID + cancellation 双重防过期响应。公共刷新、重试、执行后复核走同一采集协调层。
- 原生实现采用 SwiftUI 分栏和 AppKit/现有表格控件；内容区不用玻璃材质。最低窗口沿用当前 1000×520；窄窗口缩减详情列、按需折叠树，主操作始终可用。
- 菜单建议快捷键 ⌃⌥⌘S（实施前查冲突）；⌘R 公共刷新，⌘F 查找差异，Space 勾选行，箭头展开对象；执行只提供可聚焦按钮和菜单命令，不设易误触的默认 Return 执行。
- VoiceOver 读出源/目标、对象路径、状态和勾选；状态配文字不只靠颜色；尊重减少动态效果、系统字体和高对比度。

## 4. 现有代码与缺口

路径均相对仓库根目录。

| 现有位置 | 可复用内容 | 必须补足的边界 |
| --- | --- | --- |
| `QueryCraftPackage/Sources/QueryCraftFeature/WorkspaceSession.swift` | 连接、库/schema、对象/列/索引读取与语句执行 | 新增独立同步能力，避免所有驱动被迫实现关系结构同步 |
| `…/DatabaseSchemaEditingProvider.swift`、`…/WorkspaceDatabaseSchemaExecutionPlan.swift` | 方言 SQL 生成与语句预览概念 | 目前输入是单表 changes/tableMutation，缺跨对象依赖、指纹、风险和逐句结果 |
| `QueryCraftDrivers/Sources/QueryCraftMySQLDriver/MySQLWorkspaceSession.swift` | information_schema、SHOW CREATE、SHOW INDEX | `fetchDetails` 的生成表达式当前为空，默认值语义也需补足；不能只比较字段显示串 |
| `QueryCraftDrivers/Sources/QueryCraftPostgreSQLDriver/PostgreSQLWorkspaceSession.swift` | pg_catalog、列注释、独立 schema、索引读取 | 当前表 DDL 由列拼接，不含完整约束/identity 等；不可直接用于同步建表 |
| `…/WorkspaceSchemaCatalogSnapshot.swift` | 补全目录和缓存协调经验 | ObjectReference 统一忽略大小写，且列仅有 name/type/position/comment；新快照不能沿用其身份与完整性判断 |
| `…/WorkspaceModel.swift` 的 `applySchemaExecutionPlan` | 安全锁、临时写会话、清理模式 | 强绑定当前 selectedObject；跨库同步不能伪造选中状态来调用它 |
| `…/WorkspaceContentTabID.swift`、`…/WorkspaceContentTabItem.swift`、`…/WorkspaceContentTabsModel.swift` | 内容页签、选择及恢复 | 新增 `.schemaComparison(UUID)` 并审查所有 switch、关闭/恢复/历史逻辑 |
| `…/WorkspaceContentRefreshActions.swift` | 按 content ID 注册公共刷新 | 为对比页签注册实际对比任务完成状态 |
| `…/WorkspaceDatabaseContext.swift`、`…/WorkspaceWindowController.swift` | 保留内容容器、窗口工具栏与上下文生命周期 | 对比任务需要双连接所有权与明确关闭行为 |
| `QueryCraft/QueryCraftApp.swift` | Commands 注册 | 新增 WorkspaceSchemaComparisonCommands |
| `…/SQLiteApplicationDatabase.swift` | 本地存储基础 | 新增有版本的配置和执行记录迁移，脱敏并限制保留量 |

其中 `…/` 代表 `QueryCraftPackage/Sources/QueryCraftFeature/`。

## 5. 引擎设计

### 分层

```text
ComparisonConfiguration + 两端独立会话
  → 驱动结构采集器
  → SchemaSnapshot（完整性、方言、版本、结构化定义）
  → SchemaDiffEngine（纯函数）
  → 差异选择 + 依赖闭包
  → 目标驱动 SchemaSyncPlanner
  → SchemaSyncPlan（已审查且不可变）
  → SchemaSyncExecutor（权限/指纹复核、逐句记录）
  → 目标端重读 + 结果验证
```

建议新增文件：`WorkspaceSchemaComparisonModel.swift`、`WorkspaceSchemaComparisonView.swift`、`SchemaSnapshot.swift`、`SchemaDiffEngine.swift`、`SchemaSyncPlan.swift`、`SchemaSyncExecutor.swift`、`SchemaComparisonRepository.swift`。首版留在 QueryCraftFeature 内独立分层，不为了一个功能立即拆新包。不要继续把逻辑堆到 WorkspaceModel。

### 公共合约（拟新增名称）

- `SchemaSyncCapabilityProviding`：独立可选协议，声明可读对象/属性、可规划操作、可执行操作、版本条件、DDL 事务模式、取消能力。未声明默认不支持，不能沿用 session 缺省 `.standard` 推定支持。
- `SchemaSnapshotProviding`：按显式 scope 采集结构；字段带 `known(value)` / `unsupported` / `unavailable(reason)` 状态。支持范围内的空数组必须表示采集成功且确实为空。
- `SchemaSyncPlanning`：由目标驱动根据两端快照和所选差异生成有依赖的计划；共享层不硬编码 MySQL/PG DDL。
- `SchemaSyncExecuting`：接收审核过的步骤、操作上下文和进度回调；明确事务边界与结果未知语义。可以复用底层 executeStatement，但不能绕过安全策略。

公共模型建议：

| 模型 | 关键数据 |
| --- | --- |
| ComparisonEndpoint | connectionID、服务端身份、database、schema、serverVersion、driverVersion、配置修订 |
| SchemaObjectID | engine、catalog/database、schema、kind、原始标识符；按方言规则建立匹配键 |
| SchemaSnapshot | scope、捕获时间区间、对象集合、coverage、diagnostics、canonicalFingerprint、normalizerVersion |
| SchemaObjectDefinition | columns、constraints、indexes、options、dependencies、原始 DDL 与方言扩展 |
| SchemaDifference | sourceID、targetID、属性路径、前后值、类别、依赖、风险、可部署性与阻断原因 |
| SchemaSyncStep | 固定 stepID、所选差异、SQL、预计结构后置条件、前置条件、依赖、事务组、风险 |
| SchemaSyncPlan | source/target 指纹、目标身份、选项、步骤、版本、planHash、reviewedAt |
| SchemaSyncRun | planHash、实际执行端、开始结束、逐句状态/耗时/错误、提交结果、复核结果 |

对象标识不得简单拼 `schema.table` 再按点切割；标识符可包含点/引号。PostgreSQL 保留服务端实际大小写；MySQL 按 `lower_case_table_names` 及对象类型规则处理。目标引用使用已确认映射，不能对 DDL 全文字符串替换数据库名。

默认值区分无默认、NULL、字符串字面量、数值字面量与表达式。类型规范化必须保留精度、长度、时区、unsigned、字符集/排序规则；表达式只做方言证实等价的规范化，不全局小写或正则删括号。

索引记录列顺序、前缀、方向、表达式及方言特性；PG 还需 predicate、INCLUDE、operator class 等。任何未建模语义保留为扩展并标识能力边界，不能静默丢弃。DDL 文本 diff 用于解释，结构化定义才决定操作。

### 采集与规模

独立只读元数据会话避免改变用户查询页的 database/search_path。能批量读取则按库/schema 批量读取；限制并发，允许取消，按对象更新进度，避免每字段一次请求。首次优先构造对象清单，再填充详情；所有依赖未完整读取前不能执行涉及它们的变更。

元数据通常不是跨对象原子快照。记录读取区间，执行前重新读取受影响对象、必要依赖和目标对象存在性；任何已审核定义变化使计划失效。无法确认采集完整时，尤其不能生成删除操作。并发 DDL 的竞态不能仅靠一次指纹完全消除：事务/锁能力允许时使用短锁或事务；其余按步骤检查且首个异常停止，不宣称无竞态。

### 差异与计划

DiffEngine 不执行 I/O，同样快照/规则产出稳定排序和稳定 ID。先匹配对象，再比较属性。忽略选项属于显式配置并参与计划 hash；忽略某项不等于其依赖可以忽略。

Planner 形成操作级依赖图：先移除阻碍变更的约束/索引，再进行结构修改，再恢复依赖。新表先创建结构，跨表外键在被引用对象就绪后添加。循环依赖仅在方言可安全拆分时处理，否则阻断；不默认关闭外键检查，也不允许任意拖拽到无效顺序。

新表必须由完整结构生成；源表带未支持的结构时仅对比，不用不完整 CREATE 假装成功。部分选择若不能闭合依赖，给出具体缺项，用户可补选或取消该操作。

## 6. 执行的正确性

1. 固化两端身份、范围、快照、选项和步骤；展示的 SQL 与提交执行的 SQL 必须同源且 hash 一致。
2. 执行前检查安全锁、目标实际身份、权限、版本/驱动兼容性、源/目标指纹和依赖。源端在预览后变化也要求重比，不静默换成新 SQL。
3. 对 unique/PK 检查重复，对 NOT NULL 检查 NULL，对类型收窄检查可转换性；昂贵检查应显式展示成本并可取消。检查不等于消除并发写入，必要时在同一事务/锁保护下实施，无法保证时阻断或明确要求手工迁移。
4. 每个实际目标范围设置本地执行互斥；同一物理库的不同连接别名不能绕过。外部客户端并发通过重读、数据库锁与异常停机处理。
5. MySQL 当前计划为非事务执行，DDL 可能隐式提交；不显示整体回滚承诺。部分提交记录到具体步骤。反向 DDL 至多是结构恢复建议，不能找回删列/删表数据。
6. PostgreSQL 普通事务 DDL 可组成事务组；遇到不能放事务的操作（如并发建索引）拆组并重新审查，不能只看 `supportsTransactions`。
7. 首版首次错误即停止，记录已提交、已回滚、未执行；断线/超时若无法判断服务端是否提交，标「结果未知」，重新连接查验，禁止自动重放 DDL。
8. 取消只停止后续步骤；驱动支持时请求取消正在运行语句，最终仍查询事务/服务端结果。关闭窗口不得导致用户误以为未执行。
9. 成功后重读验证所选操作的期望后置条件，并刷新目标侧相关表详情、目录和索引。验证失败显示「执行完成，验证未通过」，不能提前亮成功。
10. 执行记录保存目标标识、SQL hash、状态和错误摘要；不保存连接密码/令牌。SQL/默认值可能包含业务敏感信息，导出与日志需沿用本地数据保护并允许删除。

保存配置只含连接引用、scope、匹配/忽略选项和配置版本；不含凭据、自动执行授权或可复用的审核状态。再次运行必须重新比较。

## 7. 六类驱动评估

| 驱动 | 当前观察 | 建议开放范围 | 首版降级 |
| --- | --- | --- | --- |
| MySQL | 元数据/SHOW CREATE/结构编辑已有基础 | 第一优先，同类型已验证版本的表结构与计划执行 | 未完整支持的特性仅对比，删除/改键需审查 |
| PostgreSQL | 列、索引、schema 与结构编辑已有基础，DDL 有缺项 | 第二优先，补完整 pg_catalog 与约束依赖后开放 | 分区、特殊类型/索引、序列未完整处理前不生成有损计划 |
| Doris | 列与 SHOW CREATE 可读，现有索引读取错误会退为空 | 后续同类型只读比较；补 key model、分桶、分区、properties | 不复用 MySQL ALTER；异步 schema change 需要作业级跟踪，首版不执行 |
| Redis | 无关系表结构；当前关系对象读取不可用 | 结构同步不适用；后续数据工具独立建模 key/type/TTL | 入口说明不适用，不用抽样 key 推断强 schema |
| Elasticsearch | 平铺 mapping 字段，关系 DDL 为空 | 后续原始 mapping/settings/alias 专项比较 | 既有字段类型不能原地改为另一类型；需 reindex 时独立迁移，不转 SQL |
| Kafka | 普通 details 为消息列；另有 Topic 详情与配置接口 | 后续 Topic 配置/分区专项比较 | 不当作表结构；不缩减分区，不把副本分配/消息/消费位点当配置同步 |

前两类的链路为协议元数据 → 驱动结构采集 → 公共快照 → 差异/计划 → 工作台。Doris/ES/Kafka 不从展示表格反推定义。SQL 查询结果（别名、关联、表达式）不作为任何结构同步来源，入口来自真实库/schema/表身份。

本次只进行了六类驱动静态代码评估，未连接实库或验证其权限/版本差异。

## 8. 实施顺序和验收

| 阶段 | 交付 | 出口条件 | 粗估有效开发日 |
| --- | --- | --- | --- |
| A | 新身份/快照/能力模型、MySQL 采集、DiffEngine fixtures | 相等/差异/未知严格区分，引用/大小写/默认值测试通过 | 3–5 |
| B | 配置 Sheet、对象差异树、双栏查看、只读计划与导出 | 能完成 MySQL 单表/整库比较并审核 SQL；不支持的操作有原因 | 3–5 |
| C | 目标执行器、前置校验、逐句记录、重读验证、配置保存 | MySQL 可重复验证的闭环，断线/部分提交/漂移测试通过 | 4–6 |
| D | PostgreSQL 完整采集与方言计划、事务分组 | 跨 schema、quoted identifiers、约束/序列边界验证通过 | 5–8 |
| E | UI/性能回归、六驱动兼容、打包与 Dev 加载 | 主程序及适用驱动测试通过，旧驱动拒绝/降级明确 | 2–4 |

按一名熟悉项目的开发者粗估，完整 MySQL+PostgreSQL 基础版约 17–28 个有效开发日；依赖已具备可用测试库，不包含复杂对象全覆盖。先交付 A+B 的可审查版本，再进入 C；不是先做一个看起来能同步但不能验证结果的按钮。

### 必须覆盖的验证

- 纯模型：结构相同但格式不同、NULL 与字符串 `'NULL'`、表达式默认、组合索引顺序、quoted 大小写、名称含点、源/目标数据库映射、空库、权限不足、局部失败。
- 规划：列修改不丢原属性、只选部分差异、外键依赖闭包、循环依赖、目标独有不默认删除、未支持特性阻断 CREATE/重建、版本差异不误放行。
- MySQL 实库：安全新增与修改；约束失败；第二条失败前第一条已提交；目标漂移；同库不同连接别名；执行超时/断线后结果查验。
- PostgreSQL 实库：事务提交/回滚、跨 schema 同名表、identity/sequence、约束与索引区分、非事务操作分组、权限限制。
- UI：慢请求首次打开、快速交换两端/范围、重复公共刷新、成功为空、局部失败/重试、保留滚动/列宽/勾选、执行中关闭页签、键盘与 VoiceOver。使用真实桌面输入验证前按 AGENTS.md 启用可靠蒙屏及退出方式。
- 回归：SQL 表数据页、查询结果页、已有单表结构编辑与只读锁不受影响；查询别名/关联表达式不会被当作结构来源；六类驱动菜单能力与降级一致。
- 性能：以 100/1000 表夹具测量采集次数、首屏响应、内存、取消延迟，定标后设门槛；不预先声称整库比较固定耗时。

### Driver API 与交付

当前 `DatabaseDriverPackage.swift` 的 Driver API 为 5。新增公开 Swift 合约要评估动态二进制兼容；不能因为采用可选协议就默认旧驱动二进制可用。若升级 API，按 `docs/RELEASE_PROCESS.md` 同步主程序、版本常量、脚本、六类 manifest，并构建全部六类驱动的 Intel/Apple Silicon 包。

每个改动驱动都单独编译、打包并确认 Dev 的实际加载路径/版本；只有运行时加载新版并完成对应实库验证后，才对外标为支持。每次提交、tag、发布前重新阅读发布流程，不能用本设计里的记录代替当次检查。

## 9. 数据同步和传输如何接上

数据同步是另一种 Diff：按可验证的主键/唯一业务键匹配行，先过滤范围，分块读取和比较，生成参数化 INSERT/UPDATE/DELETE。无稳定唯一键不做自动更新/删除；区分 NULL、编码、时区、浮点与二进制，使用目标行原值/版本校验避免覆盖比较后修改。删除仍默认不选；断点恢复需要独立设计。

数据传输是结构/行的复制：选表、目标映射、批量写入、冲突策略、检查点和行数校验。结构不同先进入结构对比。Kafka 的消息搬运、Redis key/TTL、ES reindex 属于各自数据模型，不能都塞进关系表同步引擎。

复用的部分是连接配置、任务生命周期、计划审查、日志和导出；各自的快照、比较算法、事务及恢复语义保持独立。
