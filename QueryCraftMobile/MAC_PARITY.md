# Mac 加载与展示优化同步

用户要求：保留 Mac 已有优化，并同步到 iPhone / iPad。Mac 保留 AppKit 表格、原有查询与磁盘缓存；移动端适配触控。没有替换已有桌面页面。

| 行为 | Mac | 当前 iOS / iPadOS |
| --- | --- | --- |
| 自动列宽只抽样少量行，宽表减少样本 | 原算法完整保留 | 直接编译同一个 `WorkspaceGridSampling`，30/10 行，96–480 触控自动宽度 |
| 单元格长文本预览按字符安全截断 | 原行为保留 | 直接编译同一个 `WorkspaceDatabaseDataCell.gridPreviewText`，避免对每个可见单元格全文排版 |
| 表格仅呈现可见内容 | NSTableView | UICollectionView 双向复用，布局按可见行列计算；测试使用百万行/千列的逻辑尺寸 |
| 表头、横向列宽一致 | 原行为保留 | 同一网格布局，固定纵向表头，拖动列宽并保存 |
| 刷新稳定、失败不清空 | 原行为保留 | SQL/表页保留已有结果；固定尺寸底栏进度/错误，无首次假空状态 |
| 防过期响应 | 原行为保留 | 查询、目录、表页分别使用取消与请求代次；切库/表立即清空其旧对象数据，保留容器 |
| 滚动位置/选择/列宽 | 原行为保留 | 同结构刷新还原有效偏移与单元格选择；字段变化重新计算；对象切换重新定位 |
| 公共刷新和重试 | 原行为保留 | 唯一顶部刷新，按 SQL/表数据/结构/目录分派同一实际请求 |
| NULL、空字符串、二进制 | 原模型保留 | 共用类型，二进制按字节显示且只取 128 bytes 预览；单元格详情可查看文本 |
| 字段类型、来源与注释 | 原驱动链路保留 | 原协议类型/来源，表结构含真实注释；注释仅按完整来源匹配，不按列显示名猜测 |
| 表分页/排序 | 原行为保留 | 服务端 LIMIT/OFFSET，默认主键/排序字段加主键；无主键提示顺序限制 |
| 表/视图服务端筛选 | Mac 原绑定参数路径保留 | 直接编译同一 MySQL 谓词构造与条件模型；共用字段默认值、菜单值与换字段规则；WHERE 在排序/分页前，刷新保留位置，新条件/页码/排序回首行并保留横向位置 |
| 表格内查找 | 原行为保留 | 直接编译同一个 `WorkspaceGridSearchWorker/Controller/Operator/Match`；支持列范围、包含/等于/开头/结尾、大小写、上一项/下一项循环定位，不隐藏数据行；范围仍为已加载的当前页/结果 |
| 表/视图名称模糊搜索与排序 | 完全保留既有匹配分级、分数及同分顺序 | 直接编译同一份 `CompletionLabelMatcher`，桌面与移动对象列表均调用同一个 `matching` 方法；完整目录在本地筛选，不做截断窗口内搜索 |
| 已有 MySQL 表选项 | 原选项页和变更计划保留 | 同源 information_schema 读取／选项联动／差异 SQL；与字段、索引共用结构草稿、预览、安全锁与刷新 |
| 新建 MySQL 表 | 原入口、驱动和完整草稿行为保留 | 同源新表草稿／字段／索引／表选项／SQL 计划；原生预览与安全锁，独立连接建表，成功刷新并定位新表 |
| 大结果增量流/磁盘缓存 | 同一结果缓存；MySQL 查询接入真实分批流 | 同源 GRDB 结果库／有界导出行源；移动立即落盘，500 行／约 4 MiB 缓存页、256 MiB 整批载荷上限，保留部分结果并明确停止 |
| 写 SQL／跨执行事务 | 现有分类、策略和服务端事务状态保留 | 同源解析／分类／危险语句规则；不可变 SQL 确认、安全锁、同连接跨执行、保存点／提交／回滚、未知写入结果防重放 |
| 时间戳显示 | 原行为保留 | 直接编译同一 formatter；真实类型/来源、自动/原始值/秒/毫秒、按列菜单及全屏共享状态；原始值保持不变 |
| 已加载数据导出 | Mac 原导出器与默认值保留，修复重复 JSON 字段后缀冲突 | 同源码 CSV/JSON/XLSX/SQL writer、类型值与选项；系统文件保存、取消及临时文件清理；当前页/预览，不冒充整表 |
| SQL 语法高亮与上下文补全 | 桌面入口与优化保留 | 同结构解析器、语法/恢复规则、上下文/排行、默认配色；原生触控候选和 UTF-16 插入守卫；元数据同查询/转换源码 |
| 选区／当前语句执行 | 原解析、范围定位、预检与批量能力保留 | 同源 resolver/preflight，UIKit 实际选区／IME 校验和异步修订防护；选区／整篇文稿多语句，写入经确认，多结果独立状态；公共刷新仅重读读取语句 |
| 自定义 SQL 配色、完整编辑等 | 原行为保留 | 尚未移植完整设置；当前支持 MySQL 查询、写入、事务与浏览 |

Kafka 的移动链路仍未移植。PostgreSQL 支持 SQL 写入/事务、查询磁盘缓存与表数据编辑，Redis 支持键/成员编辑、搜索、Stream 浏览与命令事务控制台，Doris 提供只读浏览，Elasticsearch 当前完整专用链路见下方新节；范围、源码共享方式和未移植能力见 README 的“新增驱动范围”。MySQL 原编辑和事务行为保留；MariaDB 原 `query` 路径仍不施加预览限制。桌面页面保留原入口和状态。

加载验证覆盖：慢首次打开、成功为空、失败重试、保留内容刷新、重复请求、快速换表/库、页签切换、下一页失败和取消。程序化截图只确认真实渲染，不替代真机触摸、拖列宽、键盘/IME、旋转或后台恢复验收。

## PostgreSQL 当前整体范围（2026-10-24）

在原 SQL 事务/磁盘缓存/基础表编辑上，接通来源明确的查询结果编辑与跨页缓存更新、共享图形字段/索引、新表、表操作及多格式文件导入。provider/descriptor、索引目录转换、事务 executor 和导入 parser/plan/engine 与 Mac 同源；物理 Schema 与表名不按显示名称猜测。完整矩阵见 [POSTGRESQL_PARITY.md](POSTGRESQL_PARITY.md)，最终实测证据见 VALIDATION 最新节。下方历史 PG「尚未移植」只代表当轮状态。

## Elasticsearch 当前整体范围（2026-10-24）

本轮按 Mac 的真实入口完成专用工作区：目录/统计/同源模糊搜索，PIT 深分页、筛选/排序和全部匹配导出，Mapping 字段编辑，文档完整/局部/CAS/跨行暂存/粘贴/批量删除，索引新建/删除/设置、Alias、索引模板/模拟，以及 REST 解析/格式化/端点与DSL补全/多结果/历史/诊断/任务读取。对应源码和验收矩阵见 [ELASTICSEARCH_PARITY.md](ELASTICSEARCH_PARITY.md)，预算、协议边界和原生入口见 README 当前节。下文历史“ES只读/未迁移”说明仅代表当轮状态。

移动直接编译原 driver session 与 worker；Mac HTTP 默认预算和入口保留。共享 session 新增可选响应预算、真实 Mapping 列类型，并拒绝超时/失败分片；移动刷新调用同一读上下文重建，后台真正关闭后创建新会话。外置包须独立验证，Driver API 不变。

## Redis 当前整体范围（2026-10-23，覆盖下方历次增量记录）

Mac 真实入口与移动入口逐项核对：侧栏逻辑库/键名搜索/前缀树 → `RedisKeySearchMatchMode` / `RedisKeyTreeBuilder`；详情/编辑 → `RedisCollectionReader`、Hash 字段 TTL 读取器、`RedisKeyMutationPlan`；新建/重命名 → 原共享计划；整键 TTL/删除 → 共享 `RedisKeyMetadataMutationPlan`；控制台 → 原 `WorkspaceRedisCommandDocumentModel` / catalog / tokenizer / suggestions / history；导出 → 原 `RedisKeyCommandExporter`；String → 原 HEX/JSON/100 MiB 规则；Stream → 新提取的公共 `RedisStreamReader`。Mac 入口保留，新增预算参数默认为 nil，搜索批量默认仍为 2,000，移动仅调整传输批量和触控呈现。

移动端已接通以上入口。成员搜索覆盖整个键而非当前页，共用匹配/排序；成功后切换结果，慢请求/失败保持原结果并标明查询状态，草稿阻止切换。String 完整读取与保存、大值分段展示、HEX/JSON/原始字节/命令导出、成员选择/批量删除、独立整键操作和同连接命令事务均有原生页面。独立弹窗保留自身范围的重读/核实，主内容只用顶部公共刷新。控制台关闭/后台会丢弃未 EXEC 的事务，回前台等待旧连接实际关闭；未知写回执不会自动重放或被刷新误当成功。

协议和平台边界：二进制集合编辑/模块值编辑沿 Mac 不支持；二进制成员可原字节导出，非 UTF-8 键名不做有损操作。Stream 图形页只读，写入走控制台；TLS 和集群 MOVED/ASK 路由均未新增（集群直连仅 DB0）。集合单页 1,000 项/1 MiB、目录 10,000 名称/8 MiB 是明确预算；SCAN 非快照。String 完整编辑 ≤100 MiB，触控长文本约32 KiB片段；移动 JSON 格式化输出≤100 MiB。控制台有界保留历史/回复，不保证 hiredis 任意响应的硬内存上限。真实设备触控、系统挂起/杀进程和真实弱网仍不能用模拟器/门控故障注入替代。

六类逐项：Redis 的外置驱动读取器和 shared host 变化独立构建/打包/实际 registry 加载验证；MySQL/PG SQL 表页、查询结果页、事务不经过 Redis 计划；Doris 只读路径保持；ES 共用资源容器但不显示 Redis 菜单；Kafka 未迁移移动端。公共网格/导出保留真实元数据，不增加名称猜测。完整五库移动回归与六类 Mac 加载的具体结果见 VALIDATION 最新节；Driver API 保持 5，不覆盖用户 Dev 安装。

下方章节为历史增量记录；其中“尚未移植”的列表只代表当轮状态，当前范围以上述说明和 README 为准。

## TablePro UI 参考

已阅读本地参考快照中的 `TableProMobile/Views/ConnectionListView.swift`、`ConnectedView.swift`、`QueryEditorView.swift`、`TableListView.swift`、`StructureView.swift` 和 `Components/RowCard.swift`。借鉴连接摘要、紧凑主次信息、窄屏记录摘要/整行详情和宽屏结构化表格的交互思路；实现继续使用 QueryCraft 模型与原生 UIKit/SwiftUI，没有引入 TablePro 源码、资源或依赖。

iPhone/iPad 现在均默认表格，字段名只在表头出现；顶部菜单可切换记录摘要，每条最多四个字段并提供整行详情。连接行显示名称/地址，表/视图行显示注释摘要。加载保留内容、固定提示及唯一公共刷新仍按本项目规则执行。

## Liquid Glass 视觉调整

根据用户对早期截图的反馈，结构页改为原生 insetGrouped 字段列表：字段名/主键、类型、可空/默认值和注释分层。SQL 编辑区采用系统分组背景与清晰阅读面，网格触控行高提高至 44 pt。最新数据页取消额外的浮动 Glass 操作条，显示/查找/排序收进系统顶部菜单，翻页与状态共享固定底栏；导航页签使用系统样式。移动端自动列宽增加 96 pt 触控下限；Mac 原有 60 pt 下限和算法不改。

## 连接首页整理

首页仅展示连接名称、服务器地址和单一添加入口；无连接时只展示首次添加引导。数据库切换、表搜索、SQL 与对象列表移到连接工作区内部。当前工作区返回首页后保留已有结果/草稿，重新打开相同配置时复用已加载目录，主页面刷新仍对应当前库/表/SQL。iPad 首页限定阅读宽度，避免连接卡片横跨整屏。

此轮仅修改移动入口、移动目录搜索请求标记及工作区呈现状态，桌面界面与六类外置驱动均未改动，不代表其移动支持范围有变化。


## 原生导航页签

连接工作区改为系统 TabView「表 / 查询 / 视图」。iPhone 使用系统底部 Glass 标签栏，iPad 常规宽度通过侧栏标题菜单切换三种模式，侧栏与详情分栏占满可用高度。目录中的 SQL 入口已移除；表和视图分别在服务端按类型读取完整有界目录（最多 10,000 对象 / 8 MiB，溢出明确失败），随后共用桌面匹配逻辑在本地搜索。SQL 草稿/结果跨页签保留；切换对象类型立即隔离旧目录与对象数据，取消旧请求并拒绝过期响应。顶部刷新仍按当前查询、对象数据/结构或目录派发。

本轮涉及移动端呈现、导航状态及 MobileMySQLService 类型过滤；MySQL 的移动浏览与查询已实库验证。PostgreSQL、Doris、Redis、Elasticsearch、Kafka 桌面驱动/页面均不受这些移动专用文件影响，移动端仍未接入。没有更改 Driver API 或外部驱动，不需要为本轮重新打包桌面驱动。

## 共享搜索与横屏回归（2026-10-22）

桌面实际对象入口是 WorkspaceDatabaseItems.objects(in:matching:)，不是 WorkspaceModel.visibleDatabases 的数据库可见性判断。匹配后的 tier、score 和稳定同分顺序现已一起提取到 CompletionLabelMatcher.matching；桌面和移动对象列表直接调用同一个实现，未维护第二套相似排序。空搜索保留原目录顺序，精确/前缀/连续包含优先于顺序子序列匹配。

六类驱动评估：MySQL/PostgreSQL/Doris 的桌面表/视图对象、Elasticsearch 资源与 Kafka Topic 沿原对象列表入口调用共享方法，提取前后规则不变；Redis Key 的 SCAN/精确搜索为独立链路，本轮不改。外置驱动协议、转换和元数据链路没有更改，无须重新打包驱动；移动实库只覆盖 MySQL，不宣称其他驱动移动支持完成。

iPhone 明确声明竖屏和左右横屏；iPad 原有四向声明保留。原生 UICollectionView 根据实际视口计算可见单元格，右横屏已在模拟器实际渲染，宽度变化测试保留列宽/选择并核对表头。实体设备的姿态传感器、旋转过程和分屏仍待手动验收。主仓库和当前 worktree 的 AGENTS.md 已记录移动功能必须主动对齐桌面并优先共享逻辑。

## 全屏数据与移动手势（2026-10-22）

Mac 现有全屏入口位于 WorkspaceWindowController，使用原生 macOS 窗口能力；这次不修改桌面窗口或滚轮行为。移动端通过原生 fullScreenCover 隐去导航、侧栏、SQL 编辑器和状态/分页栏，仍使用同一 MobileDataGrid / WorkspaceGridSampling / typed cell preview，显示当前已加载的页或查询结果。全屏期间不追加加载其他页；分页需退出后操作。

非可观察的视口状态共享偏移、列宽、选择与对象上下文，并用所有权令牌隔离被遮挡普通网格的写入。关闭全屏后重新应用同一状态；新对象不套用旧视口。退出控件短暂显示后自动隐藏，轻点表格可重新显示；Escape/辅助功能 escape 可退出，VoiceOver 开启时不自动隐藏退出按钮。

移动端普通/全屏、MySQL 表数据/SQL 查询结果都复用同一 UIScrollView 代理与主轴锁，覆盖拖动及其惯性；横/纵均可在下一次手势切换。仅表头有列宽拖动识别，数据单元格不劫持手势。此次为移动平台交互适配，没有改动 Mac 公共模型或外置驱动，PostgreSQL/Doris/Redis/Elasticsearch/Kafka 的桌面链路不受影响，也未因此增加其移动支持。

全屏跟随当前视图的原生安全区排布表头、内容和退出控件，仅背景铺满屏幕，不按某款 iPhone 写死灵动岛尺寸。目录搜索在选择对象时解除焦点但保留搜索词；结果查找和 SQL 编辑器进入全屏前解除焦点，全屏期间只清理所在窗口中残留的输入响应（包括尺寸变化/延迟键盘恢复），退出后解除这层保护。SQL 编辑器另提供收起键盘入口。该修复不更改桌面搜索规则、驱动能力、分页与已加载数据。

## 表格查找对齐（2026-10-22）

真实桌面路径为 WorkspaceGridSearchController → WorkspaceGridSearchWorker → queryResult/tablePage/redisCollection 的原始行。仅将平台数据源边界抽成 Sendable 协议并把 Mac 枚举适配移到独立文件；原调用签名通过具体类型重载保留。手机和 iPad 共用原来的匹配、180 ms 防抖、取消/代次检查、10,000 匹配上限及循环定位状态，使用原始类型值而非截断预览。NULL 与二进制说明保持桌面语义，同名列按数据索引区分。

移动端用触控查找条和 UIKit 单元格定位适配：所有行及原始行号保留，定位时避开固定表头，键盘或视口变小时保持匹配项可见，进入全屏后后台查找不抢走视口。结果查找时临时收起 SQL 编辑区，结束后保留原草稿恢复。iPad 外接键盘可用 ⌘F、⌘G、⇧⌘G 和 Escape。

六类驱动评估：MySQL/PostgreSQL/Doris 的表页/SQL 结果、ES/Kafka 的网格页及 Redis 集合本地查找均保留原 Mac 数据源适配；不改变服务端查询或 Redis 远程扫描。新 Mac 主程序构建通过，实际编译框架的三类数据源/原匹配规则和磁盘结果第 50,002 行定位通过，六类现有驱动加载/会话工厂通过，自有 MySQL 夹具 TLS 查询通过。其他五类没有本轮实库查询，也没有获得移动支持；外置驱动协议未改，不需要重新打包。

## 时间戳显示对齐（2026-10-22）

移动网格直接编译 Mac 的 WorkspaceTimestampDisplayFormatter。自动识别仍同时检查真实字段类型、显示名称与协议返回的原字段名；使用本地时区，秒/毫秒判断、日期范围、整数解析、缓存和预览限制均沿用 Mac。移动端通过传输已有的 workspaceColumns 保留类型和 origin，不从注释或相似字段名推断来源。SQL 别名、跨库关联、表达式和空结果单独验证；表达式只有实际返回的名称/类型参与原有规则，不伪造物理来源。

长按表头可选择自动、原始值、Unix 秒或毫秒，辅助功能动作提供同样入口。切换时只调整这一列的自动宽度；其他列、选中项和有效滚动位置保留。格式状态在表刷新/翻页和普通/全屏往返时保留，换对象、元数据改变或 SQL 产生新结果时重置，与桌面实际生命周期一致。普通表格和全屏共用同一份非观察显示状态，隐藏背景不能覆盖全屏选择。

转换仅用于网格展示与自动测宽，记录/单元格详情、分享、查找及传输仍读取原始类型值，18 位 ID 不经过浮点转换。全局格式偏好尚未接入移动设置，可逐列选择原始值；没有因这项展示迁移而放开只读限制。

六类驱动评估：MySQL/PostgreSQL/Doris 的表页和 SQL 查询、Elasticsearch 结果与 Kafka 消息表继续使用各自原有列元数据/设置调用同一格式化器，Kafka 配置表明确关闭转换；Redis 保持其原有专用视图路径。此次共享源码只新增 iOS 条件导入并把 sourceColumnName 等价展开为 origin?.columnName ?? name，没有修改 Mac 转换规则、驱动 API 或转换链路。移动端仅 MySQL 做实库验证，其他驱动仍未迁移。

## iPad 侧栏顶部对齐（2026-10-22）

常规宽度改由 NavigationSplitView 作为工作区根容器，表/查询/视图收进左侧栏现有标题菜单；取消常规宽度的整条 Tab 导航，左侧栏不再被其顶栏压低，右侧也不再为它预留一行。三种模式切换共享同一个侧栏与分栏控制器，保留原工作区模型、数据库选择、查询草稿和公共刷新派发。紧凑宽度继续使用原有页签加折叠导航，按实际 size class 自适应。

本次只调整移动呈现容器，没有修改共享数据逻辑、Mac 页面或 MySQL/PostgreSQL/Doris/Redis/Elasticsearch/Kafka 的外部驱动，因此无需重新构建 Mac/驱动，也没有增加其他驱动的移动支持。新增原生回归检查根分栏不位于 UITabBarController 内、侧栏导航栏紧贴系统顶部安全区，以及切换三页签时分栏身份和 SQL 草稿保持。

## MySQL 服务端筛选对齐（2026-10-22）

追踪 MySQLWorkspaceSession 的实际过滤链路，把谓词构造提取到驱动同模块源码，Mac 保留绑定参数；移动端有界预览直接编译该源码，通过 UTF-8 十六进制字符串值避免 SQL 模式/引号差异。条件模型、合法运算符、校验、枚举/布尔菜单、默认条件及换字段重置规则共用现有源码。原 Driver API 与查询结果 ABI 不变。

表/视图的现有顶部菜单打开原生筛选 Form，支持全部/任一、启用、范围、NULL、增删与清空；草稿取消不修改实际条件。两端字段标签固定在左，值与输入靠右。请求中的条件和已成功页面的条件分别保存，失败保留原结果并允许修正/重试，拒绝过期响应。成功空结果保留字段元数据。与 Mac 一致，同页刷新保留纵向位置/选择，条件、页码或排序变化回到首行并清除选择，保留横向位置/列宽/时间戳模式。

六类评估：MySQL 表/视图接入本次移动筛选，并重建/打包/签名、以 Dev 实际 registry/factory 加载新版驱动做实库验证；未替换已安装 Mac/Dev 或其驱动库。PostgreSQL、Doris 保留独立 SQL 谓词和绑定链路；共享字段默认值提取保持原行为。Elasticsearch 保持其专用条件/协议，Redis 与 Kafka 不套用 SQL 过滤。六类驱动加载/会话工厂通过，其他五类未做本轮实库查询，也未增加移动支持。任意 SQL 查询结果不自动改写 SQL；二进制条件沿 Mac 的文本输入能力，不提供任意字节编辑。

## 已加载数据导出对齐（2026-10-22）

真实路径为 WorkspaceDataExportController → WorkspaceDataExportSnapshot/Request → WorkspaceDataExporter。仅把原本位于 AppKit encoder 的 CopyColumn/Rows/Snapshot 原样拆到 Foundation 文件，保持 Mac 模块类型身份；移动端直接编译相同 exporter/request/preferences/dialect。默认 CSV BOM/CRLF/公式保护、JSON 对象数组、XLSX 文本单元格与表头、SQL 不包装事务均沿用 Mac。额外修复 JSON 重复列与现存后缀名冲突导致的字典键崩溃，普通重复命名保持原规则，原有字段名不被新后缀抢占。

数据按导出入口捕获已成功提交的原始类型快照，刷新和时间显示转换不影响文件。表/视图仅当前页；SQL 仅当前已加载预览并说明截断。字段按数据索引映射，重复别名、表达式和长整数不推断物理来源或转成浮点。CSV/JSON/XLSX 的二进制字节数说明、SQL 二进制拒绝行为与 Mac 一致，不宣称完整二进制导出。本阶段最初仅已加载数据，整表迁移见下节；选中范围、任务中心和持久偏好尚未移植。

原生可选 Form 和 Files 保存面板放在现有菜单，生成时固定进度位置，失败保留结果。每次生成使用独立临时目录和代次，取消旧任务不能删除或替换新文件；保存取消可重试，关闭清理文件。

六类驱动评估：MySQL/PostgreSQL/Doris 的表页与查询结果、ES/Kafka 网格结果以及 Redis 的现有导出入口继续共用该 host writer，三类 SQL 方言和非 SQL 的能力判断不变。Mac 完整构建及实际编译 writer 四格式/方言规则通过，六类现有驱动加载与会话工厂通过，自有 MySQL TLS 夹具通过。驱动协议与元数据转换未变，无需重新打包驱动；移动实库仍只覆盖 MySQL，其他五类本轮未查询实库。

## SQL 编辑器对齐（2026-10-22）

追踪 WorkspaceCodeEditQueryEditor → WorkspaceSQLLanguageService/CompletionService → SQLStructuralParser/CompletionEngine/Ranker，直接把相同解析、恢复、作用域、排分、范围、配色源码编译进移动端。Mac AppKit/CodeEdit 适配器保持原有流程；通用补全插入守卫共用 SQLCompletionApplication，仍校验原文版本、UTF-16 替换边界、光标和组合文本。语言包增加 iOS 平台，查询资源按两个独立子目录复制，以符合 iOS 资源包签名；既有路径回退同时支持 Mac，语法内容不变。

移动端用原生 UITextView/UICollectionView 输入附件适配触控。候选按原引擎完整顺序提供，支持点选、Return/Tab、Ctrl-Space、上下选择和 Escape，不单独占用内容工具栏。原生输入、撤销/重做、组合文字、明暗切换与滚动位置保护；着色只作用于展示属性，长文本只处理可见范围，不改写执行文本。Escape 关闭后迟到响应不能复开；组合输入不重载输入视图，不抢输入法按键。

MySQL 驱动的目录/字段 SQL 与原字典转换提取为同驱动模块的 MySQLSchemaCatalog，移动端直接编译；真实库名、对象类型、字段类型/序号/注释来自协议结果。保留当前关系字段加载、过期拒绝、同请求合并和离开范围后的字段缓存回收。元数据异常是知识缺失，不伪造字段，也不清空查询数据。

六类评估：MySQL/PG/Doris 的桌面 SQL 引擎、方言与高亮语义保留；Redis/ES/Kafka 不套用 SQL 补全，没有改变其专用编辑入口。移动端只支持 MySQL。Mac 完整构建、实际编译引擎三方言/高亮/IME 插入守卫与六类驱动加载通过；修改后的 MySQL 驱动独立重建/打包/验签，并通过实际 Dev registry/session 在隔离包目录验证真实目录、视图、78 字段、序号及原 TLS/筛选/分页链路。未替换用户已安装的 Mac/Dev 或驱动库，其他五类本轮未做实库查询。

直接复用原 Mac 解析/补全测试及语法夹具，另测移动 IME、撤销、UTF-16、中途光标、过期响应、主题、原生长文本滚动和真实 MySQL 元数据。自定义主题、多光标和格式化尚未移植；片段管理与语句执行选择见下方后续增量，只读／单语句执行限制保持原样。真机第三方输入法、外接键盘和物理旋转仍需人工体验，模拟器渲染不替代这些验收。


## 全部匹配数据导出对齐（2026-10-22）

追踪真实 Mac 网格路径 WorkspaceModel.dataExportAllRowsProvider → WorkspaceTableDataExportRowSource → WorkspaceDataExporter，将页推进、字段签名检查、首批准备和关闭状态提取到 WorkspacePagedDataExportRowSource。Mac 仍由独立 session 分批读取 5,000 行，保留 PostgreSQL 对象身份初始化、原始值完整性校验及单独 sidebar SQL target 的规则；移动端直接共用同一批次 actor 和四格式写入器，通过已有只读 MySQL page 服务读取每批最多 200 行 / 8 MiB 原始字段字节。写入器最多预取下一批，不积攒全表。实际字符串、数组及原生传输包另有开销，不承诺整个进程的硬内存上限。

当前表/视图页的原菜单改为“导出数据”，原生 Form 增加当前页/全部匹配数据范围。默认当前页不变，全部从 offset 0 开始，捕获已成功页的连接、对象、筛选、排序、真实列元数据；不读取请求中尚未提交的条件。更换表或刷新页面不会改写旧导出目标；失败重试创建新行源从头生成，旧取消不能覆盖新文件。空表/筛选为空可以导出表头或空 JSON，字段变化与超大批次明确报错，不保存半截文件。SQL 查询结果仍仅已加载预览，不自动改写或重跑 SQL。

保存改由原生 UIDocumentPicker 直接复制已提交文件 URL，避免 FileDocument/FileWrapper 在选择目的地时把整份大文件读进内存；取消 Files 保留文件以便重试，关闭导出清理临时数据。全部匹配数据是分批读取，不是数据库事务快照：并发增删可能影响 OFFSET 分页结果，无主键仍沿用既有不稳定顺序提示。二进制描述和 SQL 二进制拒绝保持 Mac 网格导出语义，不冒充无损二进制备份或直接侧栏表导出规则。

六类评估：MySQL/PostgreSQL/Doris 的 Mac 表/视图页保留既有分页/类型链路。Elasticsearch 的同一路源继续把返回实际行数作为 offset 推进，驱动仍按原有 500 行上限、PIT/search_after、mapping 签名工作；不把请求的 5,000 当成实际步长。Redis 继续专用集合导出入口，Kafka 主网格明确不提供 allRowsProvider，二者不套用整表 SQL 逻辑，已加载导出 writer 不变。本次没有新增外部驱动修改或移动非 MySQL 支持；已有驱动只需与新 host 验证加载，其他五类没有本轮实库查询。


## MySQL 数据编辑对齐（2026-10-22）

真实 Mac 入口 WorkspaceDatabaseDataCellEditRequest / RowInsertRequest / RowDeleteRequest → PendingChanges SQL preview → WorkspaceModel 的 safetyLock/context 检查 → 独立 MySQLWorkspaceSession.applyDataChanges。把相同请求准备实现改为接收真实列数组，保留所有旧 Mac details/page 重载；移动端直接编译这些实现和公共 changeSet、row grouping、三类 MySQL SQL statement/bindings/previewTokens。同一行以原始主键合并，别名沿协议来源匹配，不用显示文本猜测字段。

MySQLWorkspaceDataChangeExecutor 提取原驱动相同事务顺序和受影响行数校验：删除 → 分组更新 → 新增，COMMIT 成功或失败 ROLLBACK；新 Mac 驱动和移动事务服务直接调用。空参数事务语句仍经无绑定的 transport.query，保留取消时 ROLLBACK 的清理特例。驱动 API 公共模型布局与原协议未改，但新版 MySQL 驱动依赖新版 host 的共享 runner 符号，未来正式发版必须配套处理，当前只在隔离目录加载验证，未替换已安装驱动。

移动端普通表格进入原生编辑/新增 Form，独立待提交 SQL 预览和原状态栏入口；不新增整行工具栏。默认共享 WorkspaceSafetyLock 开启，提交需解锁。按对象保留暂存，表格更新/删除标色及辅助功能说明；预览可修改或移除新增草稿、撤销全部。页面与连接变化分别检查，不能把旧页行号应用到新页；编辑呈现捕获 page/row/request/model，实际提交按原始主键。连接有草稿时禁止静默替换或删除；返回主页保留草稿并重新启锁。

新事务连接重新确认基础表和 InnoDB 引擎；为避免假装支持回滚，移动端暂不支持非事务引擎。默认/NULL/空字符串、生成列、原始二进制/主键缺失规则共用 Mac。字段类型/约束仍由数据库验证。未知 COMMIT 状态保留草稿但禁用重新提交，要求核对服务器；没有自动写重试。当前没有原字段值 CAS 并发检查，和 Mac 一样使用主键定位；数据库并发修改可能被覆盖。复杂 SQL 查询结果的编辑入口，以及 DDL/任意写 SQL/跨执行事务/关闭应用后的草稿持久化尚未移植，不能称为全部桌面编辑能力完成。

六类驱动：MySQL 独立重建/打包/验签后通过真实 Dev registry/session 在自有可写夹具验证更新/插入/删除/回滚；PG/Doris 只共用准备/变更模型，原方言 SQL 与事务实现不改；Redis/Elasticsearch 的专用 mutation/文档模型不套用 SQL，Kafka 没有新增移动写入。六类现有驱动激活/会话工厂与新 host 兼容检查通过，其他五类没有本轮实库写入验证。Mac 主程序构建保留所有原调用签名和行为。

SwiftUI 多行 TextField 的 Done 不触发收键盘，在原生测试中实际复现；编辑值改用小型 UITextView 适配，原生 IME/撤销和多行内容保留，Return 完成只解除自身响应，不全局抢焦点，也不添加键盘附件按钮。输入内容不截断，复制粘贴多行可保留换行。

## SQL 查询结果编辑对齐（2026-10-22）

追踪真实 Mac WorkspaceQueryResultView → WorkspaceQueryResultEditing → 公共 CellEditRequest/RowDeleteRequest → pending/safetyLock/session 链路。相同单基础表来源选择器增加数组重载，旧 Mac page 重载保留；移动直接编译同一源码，复用 MobileTableChanges、原生编辑 Form、待提交 SQL 预览和独立事务服务。

共用查询请求准备验证物理主键，Mac 查询的内联、检查器回写和删除入口同步接入：nil-origin 表达式不能仅凭 `id` 名称提供主键；重复物理主键投影值不一致或 NULL 时拒绝。普通表请求签名/准备不变。Mac 的来源、当前库回退、PG schema 身份保持，驱动协议及其元数据转换未变。

移动捕获执行时配置、SQL、结果身份，元数据来自实际基础表目录/字段；慢请求、失败、取消、迟到响应不清空成功数据、不替换新上下文。提交成功按捕获原始主键本地修补物理列/重复投影和删除行，类型、来源、二进制、未修改表达式保留，不重跑 SQL。数据修订与执行身份分离，提交不误记查询历史或重建时间显示范围。无待提交时不复制整张网格。与 Mac 一样，本地结果不重算表达式或重新应用 WHERE/ORDER BY；服务器约束/生成值以重新执行结果为准。

查询与表页共享安全锁；暂存保护连接、查询数据库和执行结果替换，离开保留、主页启锁，旧结果编辑请求失效。未知 COMMIT 保留草稿禁重试；显式丢弃后结果只读直到重新查询。DEFAULT 实际值未知，也必须显式读取后再编辑。移动仍限可靠解析、单关系引用的 MySQL InnoDB 查询；关联、自关联、嵌套、复杂 CTE、解析不可靠语句只读，因为 MySQL org_table 不保留关系别名。中文反引号别名已测，不能声称所有 Mac 查询编辑已移植。写 SQL、DDL、持久草稿仍未移植；记录/全屏入口见下一节。

六类逐项评估：MySQL 表页准备不变，查询按 transport 实际 database/table/column 来源；PG 查询按 OID/attribute 转换的 schema/table/column 来源，表达式来源缺失保持只读；Doris 经 MySQL transport 保留来源规则和自身写能力判断。Redis、ES、Kafka 不启用 SQL 结果编辑，不套用主键/SQL 模型，专用更新入口不变。Mac 完整编译和六类实际 registry/factory 加载通过；自有 MySQL 查询验证别名、假主键表达式拒绝、跨库来源、真实删除准备、resident store 修补，PG schema 身份仅纯模型验证。外部驱动源码本轮未改，沿用上轮已验证的隔离包；其他五类没有本轮实库写入验证。

## 全屏与记录详情编辑（2026-10-22）

追踪 Mac 表格 coordinator 的 prepareCellEdit/Async 与 QueryResultInspectorContext.withDataEditing：两者都使用原始行/列、公共请求、同一 pending/preview/safetyLock/session。此次只扩展移动呈现入口，MobileResultSource 适配同一 MobileTableChanges、原始 page 和 readonly reason；没有新增 SQL writer、修改共用业务规则、Mac 代码或外部驱动协议。

普通网格、全屏、记录详情共用编辑/只读呈现工厂和原生表单；捕获真实请求与页行，打开时保存来源代次，实际暂存/删除前重新验证。显示修订与原始数据修订分离，单纯暂存不使正在编辑的请求失效；刷新成功后旧表单拒绝暂存，切换对象/查询/页上下文后旧全屏/详情失效并关闭。刷新失败保留内容及有效来源，pending 始终来自同一模型。记录详情在原始数据被替换后关闭，避免把旧行号显示成另一条记录。

全屏仍只有数据网格和自动收起的退出按钮。点单元格进入编辑或只读检查器，暂存后网格同步标色；已有改动时长按数据格或使用辅助功能动作打开同一待提交预览，编辑表单也提供预览图标。没有新增常驻工具栏。键盘保护依据当前窗口实际呈现的控制器与响应者，允许自己表单的输入，继续清理背景残留输入；异步清理前再次判断。全屏背景忽略键盘避让，表单期间暂停写入网格 viewport，关闭时恢复偏移/列宽/选择；硬件安全区域仍保留。

记录模式保留独立滚动锚点，返回网格恢复原有位置/列宽/选择。详情展示全部字段与真实类型/注释，逐字段提供编辑/查看入口，显示待提交/待删除状态，已有导航栏内提供行删除/恢复及预览。长文本有界展示并可分享完整内容；NULL、空文本、二进制和表达式只读语义不变。键盘右下角完成仅收起输入，不额外添加附件按钮。

六类范围：此次修改的网格和 source 均仅编译在移动目标；MySQL 表页及已支持的单关系查询结果获得入口，视图身份、表达式、生成列、二进制、缺失主键及复杂查询继续复用既有限制。PG/Doris 的 Mac 物理来源/主键/方言和提交链路未改，Redis/ES 专用模型未改，Kafka 未新增移动能力。不把移动呈现验证当成其他五类的实库验证；未改外部驱动，无需重建/重打包驱动或替换用户 Mac/Dev。

## 连接与后台可靠性（2026-10-22）

对照 Mac 的 WorkspaceModel.refreshDatabases / connectedDataSession：刷新先验证会话，失效时替换连接。移动端沿用每次读请求/写事务独立 MariaDBClient 的边界，显式刷新即重新建立连接；不依靠网络可达性推断已连接，不自动重放请求。传输原有 connect/read/write 10 秒超时及取消机制保持，本次未修改共享传输、Mac 或任何外部驱动。

App 真正进入 background 时取消读取并使代次失效，保留目录、表页、查询结果、SQL 草稿及暂存改动；active 只解除请求阻挡，由公共刷新手动重连。短暂 inactive（控制中心/权限面板）不触发事务中断。后台重新启用安全锁并取消已开始的提交，保持提交独占至清理完成；使用系统有限后台时间完成 rollback/close，过期回调再次取消，不安排后台写入。ROLLBACK 绕过前台授权及锁校验；普通语句和 COMMIT 发送前仍检查取消与上下文。

COMMIT 发送前的取消会回滚并保留草稿；COMMIT 调用期间失败/取消则保守标记结果不明并禁止提交。普通表显式丢弃不明草稿后，必须成功重新读取表数据才能解除编辑限制，刷新失败仍保留旧表只读；查询仍须重新执行后才能编辑。后台完成已确认提交时不偷偷刷新，状态区提示手动读取最新数据。错误/暂停提示复用固定状态区，网格大小和滚动位置不变。SQL 补全停止后台元数据任务并拒收迟到响应；导出停止正在生成的文件，但保留已生成且交给 Files 的源文件。

六类范围：MySQL 普通表、结构、目录、已支持的查询结果及两种导出范围适用。PostgreSQL/Doris 的 Mac 会话重连、方言、元数据和事务保持，移动端未接入；Redis/Elasticsearch 专用模型保持，Kafka 不在移动范围。本轮不将 MySQL 结果当作其余五类的实库验证；未改外部驱动，无需重新打包或替换用户 Dev。

仅保护当前进程会话；系统终止进程或用户强制退出后不保留内存草稿，按用户决定不增加跨启动恢复、工作区切换或 SQL 页签。真实弱网、锁屏及系统后台时间是否授予仍以真机为准，确定性故障注入不能代替硬件验收。

## 选区与当前语句执行（2026-10-22）

追踪 Mac WorkspaceQueryEditorCommandCoordinator 的 Cmd-Return → WorkspaceSQLLanguageService.executionPlan → SQLExecutionTargetResolver → SQLExecutionBatchPreflight → WorkspaceQueryDocumentModel.execute(plan)。移动端直接编译这套 target/request/statement/plan/resolver/preflight/error 源码以及原有全部 24 项范围/预检测试；共享源码只增加 iOS 模块 import，不改变 Mac 的任何判断。没有按分号自行拆分或按当前行猜 SQL。

MobileSQLExecutionInput 保留会话选区，挂载时以 UITextView 的实际选区和 markedText 为准。顶部运行及外接键盘 Cmd-Return 共用入口；组合文字期间按钮拒绝执行，Cmd-Return 沿现有行为结束组合而不运行。按 UTF-16 捕获文稿修订、选区及当前配置，异步解析后再次校验；改字又改回也通过修订号识别，移动光标、组合输入、取消、后台或换连接的过期请求不得连接服务器。每次显式运行使用独立有界 parser，避免 parser 不接受相同 revision 导致重复运行失败，也隔离快速连续请求。更换文稿时选区按新长度保留/夹取，界面重建不丢当前会话选区。

文稿可保留多条 SQL，每次运行光标所在语句或所选的单条只读查询。字符串分号、转义、注释、空白选区、分号后插入点、完整 SELECT 前缀及可靠的 UNION 分支选区复用 Mac 规则。无法可靠分类的局部选区与 Mac 只读策略一致拒绝，不拼接 SQL。所选多条不执行任何子集，明确提示逐条运行；本轮未移植 Mac 多结果批量执行、写 SQL、运行整个文稿等能力，不把单条执行宣称成完整批量对齐。MySQL 现有服务端 sql_mode 校验和只读事务仍最终检查实际 SQL，预览仍有 500 行 / 4 MiB 上限，文稿不超过 256 KiB。

成功结果、类型/物理来源、查询编辑基础表元数据、历史和导出只关联实际执行 SQL，不关联文稿中未执行的邻句；SQL 文稿和原生选区保持。公共刷新重复当前结果/已发起的失败 SQL，独立于之后移动的光标和编辑中的草稿；新连接会清除旧重试上下文。暂存改动继续阻止运行与刷新，旧结果在解析、读取、失败时保留，迟到结果通过原请求代次隔离。未新加工具栏或工作区。

六类逐项：MySQL 移动执行及结果编辑路径实库覆盖；PostgreSQL/Doris 的 Mac 使用同一通用定位/预检模型，实际编译产物上的范围和写策略检查通过；三类原批量/事务能力保持。Redis、Elasticsearch、Kafka 的 Mac 专用请求链路未改，不启用移动 SQL 范围执行。六类原驱动均实际加载、activate、创建会话通过；此轮无外部驱动代码或 ABI 改动，不需重打包驱动；未做其余五类实库查询。

## 六项表操作（2026-10-23）

追踪实际 Mac WorkspaceTableActionMenu/Sheet → WorkspaceModel.requestTableAction/isCurrentTableAction/performTableAction → 独立 session.executeStatement。移动端直接编译同一 WorkspaceTableAction/Statement/Error，沿用六项名称、说明、能力矩阵、SQL 标识符转义、重命名与 UInt64 参数校验、操作结果对象身份。WorkspaceDatabaseObject 是可移植值模型，加入移动 Core，selection.object 访问器两端共用；Mac 的既有实现与行为不变。原表操作测试的六组纯模型/参数化检查同步编译到移动端，Mac 专属 WorkspaceModel 两项测试留在 Mac。

目录表行的原生 contextMenu、数据页既有 ellipsis 菜单和结构页同位置菜单提供入口，不新增整行工具栏；视图无表操作。原生 Form 以左标签/右输入展示目标、参数和精确表名确认，可展开同源 SQL 预览；默认安全锁、显式解锁、提交前重复校验与 Mac 一致。键盘右下角完成只结束输入，不提交操作。自增值从实际 information_schema TABLES/COLUMNS 读取，不伪造默认当前值；加载进度和反馈占固定区域，无自增列必须报告，提交前再次验证。

独立 MySQL 连接执行捕获的单个共享 statement；元数据和 SQL 均在同连接中，发送前复核锁、数据库代次和目标暂存状态。重命名只改名保留数据；DROP 删除结构及数据；TRUNCATE 重置自增；DELETE FROM 保留自增并按服务器规则触发 DELETE/外键动作；重置与设置自增不删除数据，低值调整由服务器决定。DDL 隐式提交，不套用行编辑事务，也不宣称取消能撤销。权限/外键等明确服务端拒绝如实显示，不关闭 foreign_key_checks、不添加 CASCADE。

目标表的行暂存和单表查询暂存都会阻止表操作，按物理数据库/表/种类判断，不受目录注释变化影响。别的表的暂存保留，操作期间暂时阻止新的写入，已确认操作不会破坏无关查询草稿。已确认成功先封住再次提交，再刷新目录/数据；重命名同步当前导航，删除退出该对象。刷新失败保留成功结论和有效内容，提示公共刷新，不把它改为重试写入。受影响查询保持原结果并只读，显式刷新成功后再编辑；补全元数据失效。

发送前的取消不执行语句；发送期间取消/客户端连接错误按结果不明处理，保留原操作并锁定写入，关闭/重开或探测网络都不能自动解除。用户核对服务器后才明确结束该次操作，不自动重放。后台通过系统有限时间清理连接；已确认操作在后台完成仍记为成功，保留待刷新状态。返回前台不自动执行表操作。

六类评估：MySQL 移动六项均实库验证；PG 的 schema、CONTINUE IDENTITY RESTRICT 和所属序列逻辑保持；Doris 仅 rename/drop/truncate 的原语法与限制保持；Redis/Elasticsearch/Kafka 明确不支持 SQL 表操作，专用动作不受影响。实际 Mac 构建及六类能力/SQL 检查、六类原驱动加载通过；此轮没有外部驱动源码或 ABI 改动，不需重打包或替换用户 Dev。其余五类未做本轮实库变更，移动端仍仅支持 MySQL。

## 表结构编辑与两种展示（2026-10-23）

追踪实际 Mac 的编辑状态、描述、提供器、执行计划和 MySQL session；移动端直接编译同一份字段／索引草稿、类型／字符设置联动、主键／索引引用更新、验证和 SQL 生成。表格与列表共用草稿、选择和 SQL 计划。字段支持新增、修改、暂存删除／恢复、类型、NULL、默认值／表达式、自增、注释、可见性、生成列和字符设置；索引支持种类、字段顺序、前缀、降序、表达式、方法、可见性和注释。原生输入左标签、右值，键盘完成只收起键盘。

完整结构转换提取为两端同源的 MySQLTableSchemaMetadata，同时修正 Mac 原先未读取真实生成列表达式的问题。视图保留结构只读，读取字段不增加 SHOW VIEW 权限。结构提交后同步失效相关表数据、查询编辑来源、目录和补全元数据。提交先预览共享 SQL、显式解锁，再在同一新连接重读结构并逐条授权。MySQL DDL 分别自动提交；部分执行、结果不明或取消后禁止重放，需显式核对。已确认成功但刷新失败只允许重读。目标切换、后台和过期回包受代次约束；公共刷新不能覆盖未提交草稿。

读取保留固定容器、进度与错误底栏；刷新不清空已有内容，空状态只对应当前成功的空快照。表格保留宽度／视口，列表身份稳定，刷新后按原名称恢复选择。iPad 目录、导航和底栏使用基础层级系统背景，继续适配深浅色和高对比度；Mac 设置使用一致的不透明语义背景，保留原生分组控件。另修复移动 SQL 文字／光标改变后旧候选延迟清除的问题，接收校验和共享匹配规则不变。

六类评估：MySQL 移动结构编辑实库覆盖，Mac 新元数据链路由新包的真实 TLS session 验证。PostgreSQL／Doris 保留各自 Mac 提供器和方言；Redis／Elasticsearch／Kafka 不适用 SQL 字段／索引编辑，其专用功能不变。六类真实 bundle 激活和 registry session 工厂检查通过。新版 MySQL 独立编译、打包、签名并在隔离目录实际加载，用户安装的 Dev 驱动未覆盖。其余五类没有本轮新增实库操作，移动端仍仅支持 MySQL。


2026-10-23 移动补全触控适配：普通词接受后的空格复用／补齐通过共享 SQLCompletionApplication 的显式选项完成，Mac 默认精确插入及函数／片段光标不变。下一步候选直接使用同一个共享引擎的空前缀上下文结果，以原文和光标约束生命周期；不另外维护关键词／字段预测规则。iPad 完整键盘上方候选栏使用不透明明暗底色，浮动／外接键盘仍使用光标旁列表。MySQL／PG／Doris 桌面方言与排行未改变，移动端仍仅 MySQL；Redis／ES／Kafka 不适用 SQL 补全。本轮未修改外部驱动或结果元数据链路。

## SQL snippets on mobile (2026-10-23)

Mobile now compiles the actual Mac SQLSnippetTemplate, SQLSnippetStore, completion sources/ranking and SQLSnippetSession. Only native view adapters and emphasis rendering differ; placeholder ownership, filled states, empty stops, edit shifts, next/backtab and exit rules share one source. Touch controls and keyboard commands enter that session; IME composition temporarily disables navigation. The existing SQL header opens native management of eleven built-ins and custom definitions, with CRUD/toggle/restore and shared trigger validation. Templates preserve literal SQL punctuation. Custom definitions remain local per device, without synchronization; write templates do not expand SQL execution permissions.

Original shared three-SQL-driver tests run on mobile and Mac. MySQL/PG/Doris matching and dialect behavior remain; Redis/ES/Kafka do not use SQL snippets. Mobile remains MySQL only and external drivers are unchanged. Phone/iPad full suites each 380 passed; Mac complete build and original snippet 56 tests passed. User selected simulator delivery for this increment; installation/process logs are not physical touch acceptance.


## SQL 格式化对齐（2026-10-23）

追踪 Mac WorkspaceQueryEditorCommandCoordinator 的 commandI／format → WorkspaceSQLLanguageService.formattingEdit → SQLFormattingWorker → SQLFormatter → 原生文本替换与撤销。移动端直接编译相同 request/worker/formatter/options/edit/error 和 SQLKeywordCase，保留选区、当前语句（含原有语法恢复范围）、整篇文稿、字符串／注释及源修订规则；默认采用 Mac 的标准大写关键字和四空格缩进。尚未提供移动自定义格式偏好。

现有 SQL 操作行提供格式化菜单，外接键盘 ⌘I 处理选区或当前语句。原生 UITextView 替换使用单组撤销并发布实际文稿和选区；格式化不执行 SQL，已有结果／历史／公共刷新目标不变。输入法组合期间明确拒绝，异步结果应用前复查实际文字、UTF-16 选区、文字／光标／组合状态代次和取消。改字或移动光标后又恢复也拒收旧结果；仅补全元数据、主题或可视区高亮调度不误判为文稿修改。离开页面、切换连接和进入后台取消格式化，卸载编辑器使迟到结果失效。有效格式化结束旧片段会话，保留原生编辑和撤销。

六类评估：MySQL 移动 SQL 编辑器适用；MySQL/PostgreSQL/Doris 的 Mac 格式化继续使用原引擎，未更改格式规则。Redis/Elasticsearch/Kafka 的专用请求编辑器不接入此 SQL 功能，也未新增移动支持。格式化只在本地修改文稿，未改协议、Driver API、结果模型或外部驱动，无需重新打包驱动，不把这次编辑器验证作为六类实库验证。

## 只读批量执行与多个结果（2026-10-23）

追踪 Mac 的 CmdReturn／CmdShiftReturn → SQLExecutionTargetResolver → SQLExecutionBatchPreflight → WorkspaceQueryDocumentModel.execute(plan)，包括整批预检、顺序执行、遇错／取消停止和保留完成结果。移动端共用已有解析、范围和预检源码，并将原来的执行循环提取为同一 SQLExecutionBatchRunner，两端均使用该循环；Mac 的会话、策略、写入／事务能力和结果模型保持。

移动端支持当前语句、所选完整多条查询和整个文稿，默认仍为只读；20 条／256 KiB 执行范围，单结果 500 行／4 MiB，整批 8 MiB 原始数据预算。MySQL 批次在同一真实连接和只读事务里先按实际 sql_mode 检查所有语句，再逐条执行。超限预览会主动丢弃未读完连接，后续明确标记未执行；不自动重连、不声称跨执行事务或磁盘缓存已完成。未知／写入／事务语句整批拒绝，不执行安全子集。

每个结果拥有自己的 typed preview、原语句／来源范围、元数据、编辑草稿、网格视口及格式状态；单语句仍保持数据加载与编辑元数据加载分开的原生命周期。新执行保留可见旧结果并标明「上次」，成功才替换；刷新只重读当前语句，失败保留内容。错误、取消和后续未执行均记录到对应结果；切换结果不添加历史，成功回调逐条写历史。所有结果的草稿共同保护连接变更、新执行、结构和表操作；提交后令同表其他旧结果失效，防止继续用旧值编辑。

MySQL 移动表格、查询结果检查器、导出及元数据路径适用；MySQL／PostgreSQL／Doris 的 Mac 批次沿原会话和方言调用共享循环，未增加或削减其写入／事务能力。Redis、Elasticsearch、Kafka 的专用请求链路不接入移动 SQL 批次；各自 Mac 能力保持，也未新增移动支持。Driver API、外置驱动及协议转换未改，本轮无需重新打包驱动；不把移动 MySQL 实库检查当作其余五类实库验证。


## 新建表对齐（2026-10-23）

追踪真实 Mac 的 WorkspaceDatabaseObjectFooter → WorkspaceWindowGroup.createTableDraft → WorkspaceNewTableDraft／WorkspaceNewTableDetailView → WorkspaceModel.schemaExecutionPlan／applyTableMutation → MySQLSchemaEditingProvider → MySQLWorkspaceSchemaStatement。将原有 WorkspaceNewTableDraft 原样提取为可跨平台编译的文件，桌面仍使用同一类型；初始化、重置、schema 限定和完成回调行为未改。移动新建表和已有表复用同一原生字段／索引表单，所有定义、类型语义、主键约束、索引引用、字符设置和 SQL 转换均使用现有公共源码。

移动表目录的现有底栏增加新建入口，不额外占用工具栏行。原生三类定义页、固定位置的选项加载／失败提示、不可变 SQL 预览、安全锁确认、独立写连接、发送前取消与上下文复核，以及成功后的目录／选择／数据导航均已接入。未知建表回执保守封锁后续写入；成功后刷新失败不将建表变为可重试。草稿只在当前进程内保留，不增加工作区或 SQL 页签。

六类逐项：MySQL 移动新表实际使用现有 provider 和 builder，覆盖全部十项表选项。PostgreSQL 的 Mac schema 限定、新表能力和方言保留；Doris 的 Mac 自有 provider／能力限制保留，两者尚未迁移到移动端。Redis、Elasticsearch、Kafka 的专有对象创建不套用 SQL 表模型，原 Mac 行为不变，移动端未接入。不把 MySQL 验证算作其余五类实库验证。Driver API 和所有外置驱动源码均未改变，无需重打包驱动或替换用户 Dev；本轮 macOS 编译及实际产物上的共享草稿回归用于确认提取未改变桌面行为。


## 已有表选项对齐（2026-10-23）

追踪 Mac WorkspaceDatabaseObjectDetailsTabContent.options → WorkspaceNewTableOptionsView(allowsDatabaseDefaults:false) → schemaEditor.tableOptions／tableOptionsChange → WorkspaceDatabaseSchemaChangeSet → MySQLWorkspaceSchemaStatement.alterTableOptions。移动端在结构页已有菜单加入表选项的原生暂存表单，不增加工具栏或重复刷新按钮。新表与已有表复用同一份 MobileTableOptionsForm，已有表显示「下一个自增值」，且不提供数据库默认值建议。

MySQLWorkspaceSession.fetchTableInformation 原查询／转换提取进已有跨平台 MySQLTableSchemaMetadata；Mac 和移动端共用相同 UTF-8 安全文本条件、information_schema 数据及 WorkspaceDatabaseTableInformation.tableOptions。公共模型及原有 builder 继续处理字符集／排序规则联动、显式变更、清空注释、数值／行格式的默认规则；未另做 ALTER SQL。新增共享 changed-values 比较仅用于移动提交前的并发保护，只核对实际编辑的字段，避免未编辑的动态自增计数导致误拒绝或被写回。Mac 原有提交规则保持。

结构字段、索引、选项共用一份草稿和有序 SQL；原生表单和 SQL 预览各自保留展示时的代次／计划，父视图重建也不会更新确认依据。成功读取后同步目录注释、当前路由和数据对象身份；结构改动继续使表数据／查询编辑元数据失效。既有 pending、失败保留内容、取消和不明回执保护完整沿用。

六类评估：MySQL 表页适用，查询结果页只沿用结构变更后的编辑来源失效，不把表选项套到 SQL 投影。PostgreSQL provider 明确 supportsTableOptions:false；Doris、Redis、Elasticsearch、Kafka 未提供此通用 schemaEditingProvider，保留各自已有专用能力。移动端未接入其余五类，本轮不声称其有实库选项编辑验证。只改变 MySQL 驱动的读取逻辑提取，MariaDBTransport、Driver API、版本和其他驱动源码未变；单独构建／打包 MySQL，并用隔离 Dev 驱动安装器／registry 验证新版包及与原五类包共存，不替换用户正在使用的 Dev。


## 大结果缓存与任意 SQL／事务（2026-10-23，替代前文各轮的旧范围限制）

真实 Mac 链路为 SQLExecutionBatchPreflight／SQLStatementKind → WorkspaceQueryDocumentModel → MySQLWorkspaceSession → MariaDB transport → WorkspaceQueryResultStore。移动直接编译相同分类、预检、只读文件写入校验、事务状态、缓存与导出源码；UI 按触控采用缓存页，不把全结果数组放入网格。共享缓存新增可选驻留行数／页大小配置与有界游标窗口，Mac 默认 50,000 行／256 行页／16 页不变。移动驻留阈值为零、缓存页最多 500 行／约 4 MiB、单行 8 MiB、每批编码载荷 256 MiB；长文本与导出也按字节分批。查找当前页，全部缓存导出不重跑 SQL；缓存释放删除数据库及 sidecar，启动清理旧进程目录。

原 MySQL executeQuery 缓冲整结果再发布一次，本轮改为真实 mysql_use_result 流，500 行／1 MiB 背压批次，并保留类型、字段来源与二进制预览；旧 query／queryPreview API 保留。新符号使用 V4 transport，避免先载入已安装旧 Doris V3 导致新 MySQL 绑定缺失符号。MySQL 与 Doris 均独立重编译、打包、验签并在隔离目录验证；没有替换用户在用的驱动。Driver API 5 不改。

写入／事务状态由服务器 OK／EOF 状态提供，支持同连接跨执行、保存点、隐式 DDL 提交；不会仅凭 SQL 文本推断。安全锁和危险语句沿用共享分类，确认捕获全文与配置，发送前复核锁／代次／后台状态。事务或写入在途阻止独立页面写入和连接切换；后台／返回首页断开会话，未提交事务回滚。明确权限／语法拒绝和未知写入结果分开处理；后者需核对服务器才可解除，刷新不重放写入。

六类评估：MySQL Mac 查询及移动链路实库覆盖；Doris 只升级同源 transport V4 及重编译，保留原查询／事务和方言，不假称完成 Doris 实库或移动支持。PostgreSQL 的执行／协议不变，共享缓存默认不变；Redis／Elasticsearch／Kafka 专用链路不接入 SQL 事务，六类加载与会话工厂需逐项验证。移动仍仅支持 MySQL；大结果和事务内结果暂不提供单元格编辑，来源明确且不超过 500 行的读取保留原编辑路径。


## 驱动扩展边界（2026-10-23）

| 驱动 | 移动链路与共享边界 | 尚未对齐 |
| --- | --- | --- |
| MySQL | 原连接、MariaDBTransport、目录/表页/SQL/编辑/导出继续使用原链路 | 原记录的移动限制 |
| PostgreSQL | 共用 libpq、PostgreSQLCatalog、类型/物理来源；支持 Schema、只读表页和 SQL，详见下节 | 写入、结构编辑、跨执行事务、SQL 磁盘缓存及其他桌面功能 |
| Doris | 共用 MariaDBTransport；结构解析同 Mac `DorisSchemaMetadata`；过滤复用相同条件模型和 SQL 谓词构造，文本使用 Doris UNHEX；只读 SQL 与表页分别接入 | SQL 流式磁盘缓存、索引/DDL详情；不支持写入或事务，与桌面只读能力一致 |
| Redis | 共用 hiredis/RedisClient、回复模型、Keyspace 解析与 `RedisScanCodec`；表格和检查器共用移动公共组件 | 键/值写入、Stream/模块类型、完整二进制集合、集群路由；与桌面一致暂无 TLS |
| Elasticsearch | 共用 HTTP/TLS/认证/服务器身份/请求策略与 Mapping 解析；真实文档 JSON 与类型分别展示 | PIT 深分页、筛选/排序、REST 控制台、文档/Mapping 编辑；当前前 10,000 条，明确提示限制 |
| Kafka | 保留此前“不做”的移动范围；桌面及现有驱动不变 | Kafka 移动传输、元数据与消费状态全部链路 |

新增页面不会把缺失的物理来源或字段注释从显示名称推断出来。Doris 的表达式/别名/空结果依赖协议真实来源；ES 文档保留 JSON，Mapping 类型单独展示；Redis 的属性来自 TYPE/PTTL，均不套用 SQL 表元数据。公共 Swift 类型只拆分文件，仍在原桌面 Feature 模块，Driver API 保持 5。


## PostgreSQL 只读链路（2026-10-23）

追踪 macOS `PostgreSQLWorkspaceSession` → `LibPQClient` 的数据库、Schema、对象目录、字段、筛选、SQL 查询与物理来源。新增 `PostgreSQLCatalog` 后两端直接编译同一份 SQL、转换和谓词；桌面类型的原名义模块和公开协议不变。发现只读 SELECT 用户在 information_schema 中看不到主键约束，因此主键识别改用 pg_catalog.pg_index；物化视图字段在 information_schema 中缺失，使用 pg_attribute 的真实信息补齐。两处修复在共用目录中同时生效，保留普通表的类型、默认值、生成列及注释行为。

移动连接增加真实 PostgreSQL 驱动、数据库/默认 Schema、5432/TLS 配置；Schema 默认选择对齐 Mac 的 public/首项规则，显式全部 Schema 在刷新后保持。目录使用共享匹配排序，跨 Schema 同名对象有独立身份，物理 Schema 与表名不通过点号拆分。SQL 上下文共用 Schema 标识符引用设置 search_path，修正桌面带点号/引号的 Schema 被当作路径拆分的问题；成功历史保存/恢复对应 Schema；旧配置和历史继续解码。查询结果以 libpq 的类型 OID、表 OID、字段编号建立完整来源；表页、别名、关联、表达式、空结果分别处理，注释不按显示名猜测。

现有 MariaDB 配置/结果边界改为移动通用适配，但 MySQL 原会话/流式缓存、Doris 只读执行链仍使用各自传输。PG 专用查询用服务端只读事务，libpq 单行模式在行数/字节超限时关闭连接；取消通过原客户端的 PQcancel 路径中断实际查询。表分页/排序/筛选、列注释、已加载页导出、SQL 当前语句/选区/批量多结果和原生网格复用现有公共链路。刷新保留同页内容，换 Schema/库/对象隔离旧数据并拒收过期响应。

范围：MySQL 保留完整移动功能；PostgreSQL/Doris 仅本轮已列明的只读浏览和 SQL，PG 尚无写入/结构编辑/跨执行事务/磁盘缓存；Redis/Elasticsearch 继续使用上一轮专用只读链路；Kafka 没有新增移动支持。不能将此轮当作五类驱动全部对齐 macOS。PG 多语句各自独立连接，bytea 与当前桌面协议一样使用文本形式；名称模型无法唯一解析的 SQL 补全不猜物理字段。真机触控、后台弱网、TLS 证书及全部桌面 PostgreSQL 版本仍需进一步验收。


## PostgreSQL 表数据编辑（2026-10-23）

沿 macOS `PostgreSQLWorkspaceSession` 的行编辑链路提取 `PostgreSQLDataMutation`，两端直接共用 INSERT/UPDATE/DELETE SQL 生成、删除→更新→新增的批次顺序和受影响行数检查。移动端复用现有 `MobileTableChanges` 暂存、安全锁、预览、撤销、取消/后台及结果不明状态；每次提交捕获当前字段快照和独立 Schema/表名，事务内锁表后复查真实字段/主键。主键仍是 Mac 的原始主键定位规则，不宣称新增了旧字段值冲突检测。

表格、记录和全屏页面共享同一份改动状态；目录中的建表和结构操作继续按独立能力限制，PG 不会进入 MySQL DDL 链路。SQL 控制台保持只读，查询结果编辑和跨执行事务尚未开放。视图不写入；无主键表可新增，不能更新/删除已有行。生成列、NULL/默认值与 identity 使用桌面共享字段规则；bytea 沿桌面文本表示；NUL 文本明确拒绝。提交回执不明后保留草稿并禁止重放，丢弃后仍需实际刷新成功才能继续编辑。

六类评估：MySQL 共用暂存接口但继续走原 MariaDB 写入服务；PG 表数据新增写入，SQL 查询页仍只读；Doris 的只读表/查询能力不变；Redis/Elasticsearch 的专用只读页不进入 SQL 编辑链路；Kafka 移动链路仍未移植。此次未改变 Driver API。桌面 PG 共享源码的实际打包/加载与移动端实库结果见 VALIDATION.md 最新记录。


## PostgreSQL SQL 会话与缓存（2026-10-23，当前范围）

在前一节表数据编辑上增加 SQL 控制台写入、DDL、RETURNING、跨执行事务/保存点/提交/回滚。读取、写入分类和危险 SQL 确认继续使用桌面共享 parser/preflight；移动端与 MySQL 直接共用 `MobileSQLSession`、确认 UI、磁盘缓存、结果页、刷新和取消状态，驱动适配只处理协议、连接设置与真实错误分类。SQL 查询结果单元格编辑和图形结构编辑仍未开放；Doris/Redis/ES 继续只读，Kafka 仍未接入。

libpq 新流式入口使用 extended query protocol 保证一次请求只能包含一个服务端语句，单行模式配合 Mac/MySQL 共用 `WorkspaceTransferBatchChannel` 背压和 `WorkspaceQueryResultStore` 磁盘缓存，避免一次收齐大结果。当前可见页 500 行/4 MiB、单行 8 MiB、整批缓存 256 MiB。字段元数据在完整响应后通过同一连接解析，临时表和事务内 DDL 可见；最终 Schema/类型/真实来源和注释写回缓存，分页保留。原桌面执行入口保持原路径，新流式传输供移动会话使用。

自动提交读取使用服务端只读事务；显式事务内读取不另开事务。错误/取消停止后续批次并关闭 SQL 会话、回滚未提交事务；不会自动重连恢复事务。活动事务或未核实写入阻止端点及 Schema 切换。已确认成功的写入不因刷新重放；丢失提交回执要求显式核实。SQL 改变 `standard_conforming_strings` 后，目录/编辑共用字面量通过显式 E 字符串正确处理反斜线。

功能语义与限制以本节和 README 为准，前面的只读阶段记录为历史基线。真机输入/弱网/后台、真实 TLS 证书和全部服务器版本尚待验收。

## Redis 键值编辑（2026-10-23，第五轮）

沿桌面 RedisKeyEditorState → RedisKeyMutationPlan → RedisOptimisticMutationSession → RedisClient 的真实链路接入移动弹窗，直接编译共享 planner、editable row、HEX codec、命令预览和原值断言模型。适用 string、list、hash、set、zset；默认安全锁、预览/确认、TTL 保留语义及 List 删除顺序与 Mac 共用。属性/数据页共用原有底栏编辑入口，不新增主内容刷新按钮或独占工具栏。弹窗的加载/错误在固定底栏，刷新保留已加载内容和草稿，取消及后台失效令牌隔离旧响应。

编辑快照读取真实二进制数据，上限 1,000 个成员或 1 MiB；未完整读取就不生成写入请求。string 支持文本/HEX，集合中的非 UTF-8 成员明确只读；非 UTF-8 键名不会被有损转换后写到另一个同名键。值编辑直接使用共享 planner 的成员级断言，不把其他无关字段的并发变化误判为冲突；独立 TTL/DEL 操作检查完整已加载键的类型、数量和原值。未知回执和 EXEC 部分失败必须重新读取核实，确认绑定当前草稿和固定 DB/key。切对象/逻辑库/端点不会丢失编辑中的草稿；后台重新上锁、失效确认，已发送的写入等待真实结果，绝不自动重试。

同步修正共享 RedisClient 的两个问题：WATCH/断言读取被 ACL 拒绝必须立即失败；RESP3 ZSCORE 的 double 与 ZSCAN bulk string 的等值分数按数值比较，避免 2.0 和 2 的误冲突。Driver API 保持 5，未新增公开协议能力。六类评估：Redis 适用并有移动/桌面独立实库验证；MySQL/PostgreSQL SQL 表页和查询页不经过 Redis planner；Doris/Elasticsearch 继续只读，Kafka 未新增移动能力。公共结果组件只在 resourcePagination.driver == redis 时显示编辑入口，其余页面行为保留。新版 Redis 驱动单独编译/打包并通过真实安装器和 registry 验证，与其他五类包共同加载；不替换用户现有 Dev 配置。

尚未对齐：新建/重命名键、Hash 字段 TTL、超限键分页编辑、二进制集合编辑、Stream/模块、任意命令和集群路由；TLS 与现有桌面 Redis 驱动一样未支持。完整基线比较不是持久版本号，无法检测外部将值改回原值，TTL 本身也没有并发断言。真实设备触控、系统挂起/杀进程、真实网络断连及旧 Redis 版本仍待验收；隔离测试的回执丢失注入不冒充真实弱网测试。


## Redis 新建与重命名（2026-10-23，当前范围）

移动端直接编译 macOS `RedisKeyCreationPlan` / `RedisKeyRenamePlan`，共用五类新建类型、名称 trim、Hash/Set/ZSet 身份与分数校验、List 空白过滤和顺序、TTL 命令。Mac 新建从 EXISTS 后直接事务改为共享缺失断言的 WATCH/MULTI/EXEC，消除检查后其他客户端抢先创建导致覆盖的窗口。重命名继续使用原 RENAMENX；同名不覆盖、源数据和 TTL 保留，空名/未变名称不提交。Driver API 仍为 5，未修改外置驱动源码。

新建入口放在现有数据库选择行，重命名在目录上下文菜单和数据/属性共用底栏编辑菜单；不新增主内容刷新行。弹窗复用安全锁、精确命令预览/确认、后台上锁，键身份操作与值编辑互斥。默认持久化；新建允许空 String，集合依 Mac 规则至少一个有效成员；新建值限 1,000 个成员/1 MiB，键名限 64 KiB。原始非 UTF-8 键名不开放操作；RENAMENX 不读取值，超限值和 Stream 可重命名，内容浏览/编辑仍遵循已有能力限制。

提交后读取 TYPE/PTTL，丢失回执时保留已提交操作和草稿，禁止重放；核实失败保留未核实状态，切后台取消读取并隔离迟到响应，已发送写入等待真实结果。核实成功显示原/目标当前存在性、类型和 TTL，未知回执不能据目标存在推断本次成功；确认关闭后刷新实际目录/详情。已确认成功且目标仍存在时更新选中项，目录始终重新 SCAN 当前 MATCH，不混入不匹配目标。外部后续写入与 TTL 到期可能改变核实时状态，不宣称原子历史快照。

六类评估：仅 Redis 新增键操作；MySQL/PostgreSQL 表页和查询页不进入此链路，Doris 仍只读，Elasticsearch 共用资源页面但没有 Redis 操作菜单，Kafka 仍无移动入口。此次修改 Feature 内部共享计划与桌面调用，既有六类外置包用新版 Feature 验证加载，不替换用户 Dev 安装目录。仍未对齐 Hash 字段 TTL、超限键分页编辑、二进制集合成员编辑、Stream/模块内容、任意命令、集群路由和 TLS；实体设备弱网、系统挂起/杀进程待验收。


## Redis Hash 字段 TTL（2026-10-23，当前增量）

Mac 分页读取和移动编辑快照共用 RedisHashFieldExpirationReader 的 COMMAND INFO HPTTL 能力探测、二进制参数与 HPTTL 回复校验；移动端直接使用已有 RedisKeyMutationPlan 的 HPEXPIRE/HPERSIST 生成和字段原值断言。支持设置正整数毫秒、留空移除 TTL；旧版服务不显示输入且模型拒绝 TTL 改动。探测权限不足标为未知，不能当作永久；已确认支持后的 TTL 读取失败或字段已消失会失败，保留旧内容，不发布假的永久状态。桌面分页读取也同步采用失败行为。

字段值 HSET 会清除字段 TTL；仅修改值时沿用 Mac 行为，UI 已明确提示。字段重命名沿 Mac 规则用已读取的 TTL 时长重新计时，不宣称保留绝对截止时间。TTL 本身没有原值断言，外部只改变 TTL 的并发不会被检测；不增加 Driver API。

此增量只适用 Redis Hash 编辑；MySQL、PostgreSQL、Doris、Elasticsearch、Kafka 不使用该读取器或字段 TTL 输入。Hash 全量编辑仍有 1,000 成员/1 MiB 限制；大键分页编辑、Stream 内容、二进制成员修改和真实设备弱网仍待后续。


## Redis 大集合分页编辑（2026-10-23，当前增量）

将 Mac 既有 RedisDriverWorkspaceSession+PagedValues 的分页实现整体提取为 RedisCollectionReader actor，桌面 session 持有同一连接的读取器并在重连/关闭时失效；移动端编译同一份源码，List 绝对索引、Hash/Set 游标、ZSet 默认降序、搜索匹配规则和字段 TTL 读取不另写一套。移动编辑集合超过 1,000 项自动切入分页，单页请求 200 项，SCAN 可多返回；单页仍有 1,000 成员/1 MiB 上限。

读取新页时保留旧内容/固定底栏，只有成功才更新页号和历史。草稿阻止翻页，提交和核实刷新当前页；翻页失败、后台取消与迟到响应不会发布新页或破坏历史。List 修改继续以完整总长度和真实绝对索引断言；Hash/Set/ZSet 使用 Mac 成员原值断言。部分页不提供整键 TTL 或删除，模型也拒绝绕过 UI 提交，不将一页数据当整键快照。

本轮只接入逐页编辑入口；共享读取器支持的成员搜索 UI 尚未移植。String 仍是 1 MiB 整值编辑，未做分块写入；二进制集合成员仍只读。SCAN 不是稳定快照，前后翻页可能因外部写入而重复/变化；ZSet 改分数可能使成员移出当前页。五类其他驱动不经过该读取器和编辑页，协议/API 不变。实际覆盖与驱动包验证见 VALIDATION.md 最新记录。
