# 表右键导入/导出验收记录

日期：2026-10-14。功能与真实数据库链路验证已完成。窗口释放崩溃已定位到测试辅助窗口的关闭所有权并修复，完整回归已通过，Dev 安装结果见下文。

## 自动测试

| 范围 | 结果 |
| --- | --- |
| 导入解析、导入执行/窗口挂载、表导出、导出器、队列及设置七个相关套件 | 57 项通过，0 失败，0 跳过 |
| 排除依赖 AppKit/SwiftUI 窗口套件的扩大回归 | 712 项通过，0 失败，3 项条件跳过 |
| 3 万行 × 12 列 XLSX 性能 | 3.886 秒，通过原有 5 秒阈值；ZIP 完整性通过 |
| 完整 Feature 回归 | 窗口崩溃已修复，1216 项通过，0 失败，3 项条件跳过（82.1 秒） |
| 五步导入窗口布局 | 960×720 / 760×580 挂载通过；蒙屏下五步真实原生窗口截图核对通过 |
| 原生打开/保存面板 | 四格式保存面板的文件名、类型限制、取消及导入单文件选择/取消检查通过（调用真实 AppKit 面板，未模拟物理鼠标） |

相关测试和扩大回归有重叠，数量不能相加。3 个跳过项是未设置 `QUERYCRAFT_ES_LIVE_TESTS` 的 Elasticsearch 创建、删除及设置实库用例。早期完整测试即使关闭 Xcode 并行仍崩溃；不把那些中断结果算成通过。最终以修复后的完整结果为准。

## 真实数据库

通过与最终 Debug 主程序匹配的 API 5 打包驱动连接本机 Docker 数据库。每次使用独立 UUID 数据库/schema 和现有测试表，不读取用户保存的连接。临时库/schema 在 `finally` 中删除。

| 驱动/服务 | 已验证 |
| --- | --- |
| MySQL 8.0 / 8.4 | CSV、JSON、SQL INSERT、XLSX 各 5003 行导出后导入，逐字段一致；原始导出 SQL 执行一致；第二批主键冲突与实际 Task 取消均整笔回滚，目标表 0 行 |
| PostgreSQL 17 | 同上；额外覆盖 schema、带点表名、GENERATED ALWAYS IDENTITY 和生成列 |
| Doris 4.1.3 | 四格式各 5003 行导出，逐字段一致；原始 SQL INSERT 执行结果一致；不提供导入入口 |
| Redis / Elasticsearch / Kafka | 三种打包驱动加载和激活通过；本次表右键 SQL 导入/导出不适用，保留各自原有功能 |

样例包含大于 JavaScript 精度范围的整数、30 位精度小数、中文和 emoji、NULL、文字 `NULL`、空字符串、布尔、单引号、反斜杠、逗号、双引号、CRLF、Tab、`_x0041_` 和公式形似文本。SQL 默认 1000 行一批，5003 行导出确认生成 6 条 INSERT；导入每批 500 行。

CSV 无损回灌关闭公式防护；XLSX 导出设置 NULL 为空单元格、导入清空 NULL 文本标记。这是明确的无损模式；默认显示为同一文字的 Excel NULL 和文字 `NULL` 无法事后区分。

Doris 首轮遇到测试环境内存不足。最终使用专用临时容器，镜像参数 `FE_HEAP=512m`、`BE_HEAP=256m`，未修改其他容器；验证完成后删除专用容器。

## 本轮发现并修复

- MySQL 执行严格模式设置后，现有驱动不能推断事务状态而报错：仅容忍该特定错误，再查询服务器确认 `STRICT_ALL_TABLES`，之后才开始事务。
- CSV 文字 `NULL` 与空值混淆：文字加引号。CRLF 是 Swift 中一个 Character，改为按 `isNewline` 判断并正确引用。
- XLSX 形似 OOXML 转义的文字、回车和 XML 控制字符保真；增加普通单元格快速路径以恢复导出性能。

## 窗口问题与界面验证

- NSZombie 最小组合复现明确报告向已释放的 SettingsWindow 发送 release。设置、SQL 编辑器及 DDL 测试辅助窗口由 ARC 持有，却保留 AppKit 的 isReleasedWhenClosed=true；补齐 false 并关闭无意义的测试窗口动画。生产控制器已有正确配置，未修改产品窗口生命周期。
- 完整回归还发现长文本重排列测试的错误断言：payload 移到第 1 列后，第 2 列仍是 ID，应该为 "1"；另用 tableColumns.count 检查真正越界。保留完整长文本与剪贴板内容断言。
- 建立临时全屏蒙屏及 HID 输入隔离，所有屏幕覆盖确认后才开始窗口验证。Esc 可立即停止并恢复桌面，最多 5 分钟自动解除；隔离失效时监督进程同步停止测试。每轮结束后已解除。
- Xcode 派生的截图进程被 TCC 拒绝，改由已有录屏权限的监督进程按指定测试窗口 ID 截图。五步真实窗口已核对，字段映射预览从左上角显示，系统控件可见。
- Peekaboo 因 GitHub 下载不可达未安装成功。尚未用真实鼠标完成从主程序表右键到选文件、保存/导入确认的整段点击；原生面板打开/取消与数据库执行分别有自动验证，不能等同于完整点击路径。
- 已安装 `/Applications/QueryCraftDev.app`，构建标记 `20261014-164837-606ae7aa`；持久签名与 `codesign --verify --deep --strict` 通过。旧包备份于 `.build/dev-app-backups/20261014-164837-606ae7aa/QueryCraftDev.app`。
- 使用安装包内的 QueryCraftFeature.framework 再次加载并激活六类 API 5 驱动通过；后台启动 Dev 后，lsof 确认实际加载 `/Applications/QueryCraftDev.app/Contents/Frameworks/QueryCraftFeature.framework/Versions/A/QueryCraftFeature`，未使用构建目录框架。
- 所有蒙屏和监督进程均已退出。未提交、打 tag 或发布。

## 复现与证据

真实数据库脚本：`scripts/test-data-transfer-docker.py` 和同名 Swift 文件。可用 `CHECK_MYSQL80_CONTAINER`、`CHECK_MYSQL84_CONTAINER`、`CHECK_POSTGRES_CONTAINER`、`CHECK_DORIS_CONTAINER` 指定已有本机测试容器，`CHECK_DRIVER_DIRECTORY` 指定匹配当前主程序的驱动目录。`CHECK_CONTAINER` 只测试一个容器。

```sh
python3 scripts/test-data-transfer-docker.py
CHECK_ALL_DRIVER_LOADS=1 CHECK_LOAD_ONLY=1 python3 scripts/test-data-transfer-docker.py
```

脚本要求对应 Debug Framework 已构建、测试容器已就绪，并用 UUID 临时对象核对真实数据。SQL 回放仅在脚本生成的测试文件和测试表上执行。

本地日志保存在 `.build/validation/data-transfer-20261014/`：`feature-tests.log`、`headless-tests.log`、`database-roundtrip.log`、`driver-loads.log`、`full-window-attempt.log`；扩大回归精确过滤参数保存在同目录 `headless-command.json`。

相关测试结果包：`test_macos_2026-10-14T06-54-39-590Z_pid51493_d700dc5b.xcresult`；扩大回归结果包：`test_macos_2026-10-14T06-58-57-587Z_pid57175_4b5dfe62.xcresult`。均位于本机 XcodeBuildMCP 的 QueryCraftPublic 工作区结果目录。

最终完整结果包：`test_macos_2026-10-14T08-46-58-340Z_pid12587_d5626810.xcresult`；原生窗口/面板验证结果包：`test_macos_2026-10-14T08-45-53-770Z_pid11135_ad607e94.xcresult`。证据目录增加 `full-feature-tests.log`、`native-panels-tests.log`、`visible-import-0.png` 至 `visible-import-4.png`。

## 原生 macOS 菜单调整
右键导出采用四个直接菜单项并配 SF Symbol，点击后立即打开系统 NSSavePanel；不再增加额外的导出子菜单。调整后的导入/导出相关 33 项测试全部通过，Dev 已重新安装并完成签名校验。

## 根据界面反馈的 macOS 原生化调整
SQL INSERT 批量数使用紧凑原生 Stepper；右键导出合并为单个“导出数据”子菜单；导入向导步骤指示改为进度条和轻量文本，减少自绘圆点与大块视觉。调整后导入测试 10 项通过，Dev 已重新安装。


## 2026-10-15 导入性能专项

- 左右均采用 AppKit NSTableView；原生弹出菜单按需构造，映射变化只更新对应目标行。以不显示的 NSWindow 验证 1000 个源/目标字段、78 列×200 行预览的独立滚动和可见控件复用，未模拟物理输入。
- 预览每单元格最多 512 字符；确认 SQL 示例从有界预览生成。实际执行保留完整值，不在 SwiftUI body 内同步生成整批 SQL。
- UTF-8/BOM SQL 64 KiB 分块解析，数字采用词法状态机，避免每个数值调用正则。约 4 MiB 后转磁盘快照，行索引占约每行 8 字节；每批读取独立句柄。行解析和批次解码及时释放 Foundation 临时对象。没有新增导入体积上限。
- 当前导入解析/执行/原生控件测试 **31 通过、0 失败、0 跳过**（106.8 秒），结果包 `test_macos_2026-10-15T01-20-45-324Z_pid28965_c40e1fa3.xcresult`。本次没有重新跑完整 Feature；前述 1216 项是此前版本的记录。

### 合成文件性能

命令：`python3 scripts/benchmark-data-import.py --rows 28311 300000 --columns 78`。直接以 `-O` 编译实际解析和快照源文件，仅替换本地化文案对象；数据混合 Unicode、转义、NULL、高精度数字。包含解析和磁盘快照创建，不包含数据库网络/写入或主程序界面帧率。RSS 为独立测量进程的峰值，包含运行库及生成夹具的开销。

| 行×列 | 文件大小 | 解析暂存 | 500 行一批完整读取快照 | 峰值 RSS |
| --- | --- | --- | --- | --- |
| 28311×78 | 61.5 MiB | 3.862 秒 | 0.456 秒 | 122.7 MiB |
| 300000×78 | 651.7 MiB | 35.310 秒 | 4.350 秒 | 108.7 MiB |

两次独立进程的分配器/运行库驻留不同，不能按两行内存数字比较“更大更省”。重点是 651.7 MiB 输入不再需要驻留全部文本/字节/解析行。仍需至少容纳单行/单值、当前批次和预览；索引随行数增长。CSV、JSON、XLSX 和非 UTF-8 SQL 当前未完成全程流式解析。

证据位于 `.build/validation/import-performance/`。实际文件可能有不同字段长度和语法，数字不作为通用速度承诺。


### 当前 SQL 磁盘快照实库回归与 Dev

`CHECK_LARGE_VALUES=1 CHECK_FORMAT=sql CHECK_CONTAINER=<容器> python3 scripts/test-data-transfer-docker.py`，分别测试 MySQL 8.0、8.4 和 PostgreSQL 17。5003 行夹具中加入长 Unicode 字段，强制解析结果进入磁盘快照。每库原始 SQL 重放、重新映射回灌均逐字段一致；第二批失败与任务取消均验证目标表 0 行。日志 `mysql80.log`、`mysql84.log`、`postgres.log`，临时库/schema 均由脚本 finally 清理。

Dev 已安装并后台启动，标记 `20261015-092359-79b07e42`，持久签名校验通过。未改 Driver API/外部驱动、未提交或发版。最新 UI 覆盖是非显示窗口的原生程序化滚动测试，不等于物理鼠标滚动的帧率测量。


## 2026-10-15 CSV / JSON / XLSX 流式解析与显示窗口性能

本节取代上节“其他格式尚未流式解析”的阶段状态。CSV/TSV/分隔文本、JSON/JSONL、SQL 均使用 64 KiB 字节窗口；GB18030 和 UTF-16 流式转码。XLSX 通过 ZIP/ZIP64 目录定位，分块解压到自有临时文件，XML 输入流解析；共享字符串使用磁盘索引与有界缓存。所有格式共用约 4 MiB 后转磁盘的行快照，执行与预校验按批读取；没有增加文件体积、数据行或单元格数量上限。仍需容纳单条记录、当前批次、预览和随行数增长的偏移索引。

### 当前四格式实库验证

`CHECK_LARGE_VALUES=1 CHECK_CONTAINER=<容器> python3 scripts/test-data-transfer-docker.py`，MySQL 8.0、MySQL 8.4、PostgreSQL 17 各自四格式 5003 行逐字段回灌一致，长 Unicode 字段使各格式进入磁盘快照。原始导出 SQL 重放一致，第二批失败和实际 Task 取消都验证整笔回滚到 0 行。临时数据库/schema 在 finally 中清理。日志：`stream-mysql80.log`、`stream-mysql84.log`、`stream-postgres.log`。

### 当前优化构建文件性能

复现：`python3 scripts/benchmark-data-import.py --rows 30000 100000 --columns 78 --formats csv json jsonl xlsx`。直接编译实际生产解析器与快照源码（`-O`），文件在测量进程外生成。耗时为解析和快照创建，不含数据库写入；峰值 RSS 包含独立进程运行库，不是整个主程序的内存。每个案例还按批读取完整快照核对行数。

| 行×列 | 格式 | 输入 MiB | 解析暂存秒 | 峰值 RSS MiB |
| --- | --- | --- | --- | --- |
| 30000×78 | CSV | 30.44 | 2.375 | 43.34 |
| 30000×78 | JSON | 32.76 | 3.110 | 40.60 |
| 30000×78 | JSONL | 59.25 | 4.003 | 37.37 |
| 30000×78 | XLSX | 6.23（压缩） | 15.168 | 44.19 |
| 100000×78 | CSV | 101.47 | 8.201 | 55.70 |
| 100000×78 | JSON | 109.20 | 10.175 | 46.32 |
| 100000×78 | JSONL | 197.51 | 13.341 | 46.98 |
| 100000×78 | XLSX | 20.76（压缩） | 48.689 | 46.62 |

测量修复了 CSV FileHandle 读取窗口的 autorelease 积累（101 MiB 文件的 RSS 从约 137 MiB 降至约 56 MiB）。XLSX 仍需解压和解析全部选中工作表，不能以压缩文件大小与文本格式直接比较吞吐率。实际耗时取决于文件内容、磁盘及主机负载，不作为通用速度承诺。

### 显示窗口滚动

右侧预览复用主数据页/查询结果的 `WorkspaceDatabaseDataRowView`，不再逐单元格创建 NSTextField。共享绘制只处理可见列，Core Text 单行按宽度排版，使用原生 UTF-16 和每行最多 32 项缓存；保留数据、复制值、列类型与 origin。左侧原生表格按需建立弹出菜单，改映射只更新对应行。

`scripts/benchmark-import-scroll.py` 先启用所有屏幕蒙屏及 HID 输入隔离，Esc 随时退出、5 分钟自动解除；仅合成测试窗口显示在屏障之上，结束自动恢复。窗口为 960×720、760×580，浅色/深色；2000 个映射字段、200×78 预览，单元格为约 512 字符的中文/emoji。以 60 Hz 定时投递到自己的原生 scrollWheel，再完成布局/绘制；每段丢弃前 10 次预热。这是事件处理与绘制测量，不是物理触控板或显示链路帧率。

同一压力场景下，旧逐单元格控件预览纵向约 8～9 Hz、横向约 10～12 Hz；当前纵向约 57～60 Hz，左侧约 57～60 Hz。前一轮极端长文本宽表横向约 42～45 Hz；最终重复测量横向约 28～45 Hz，p95 主线程绘制约 23～35 ms，仍有掉帧及负载波动，不能宣称全程 60 fps。额外的表格图层合并试验未改善，因此未进入产品。前一轮证据 `current-native-utf16.json`，最终重复测量 `scroll.json` 与截图位于 `.build/validation/import-scroll/`。

导入专项最终 38 项通过、0 失败、0 跳过；包含编码跨块、JSON 后出现字段、ZIP64、共享字符串落盘、CRC、快照损坏、取消与事务链路。对应结果包 `test_macos_2026-10-15T01-59-46-156Z_pid50034_da7ccfe7.xcresult`。共享 renderer 的最终完整 Feature 回归及 Dev 安装记录见下文。


### 最终完整回归

共享单行 renderer 改动后的当前代码：**1232 通过、0 失败、3 条件跳过，83.8 秒**。3 个跳过仍为未设置 `QUERYCRAFT_ES_LIVE_TESTS` 的 Elasticsearch 实库用例。结果包 `test_macos_2026-10-15T02-29-04-776Z_pid74559_efebb2cc.xcresult`，完整日志 `.build/validation/import-performance/full-feature-final.log`。

首轮 1228 通过、4 失败、3 跳过，失败集中于选择状态延迟发布测试。它们固定睡眠 300ms，在全量窗口并发负载中会早于产品的延迟任务实际开始；改为最多 10 秒等待实际发布条件，保留原断言与产品选择逻辑，随后完整重跑通过。没有将首轮失败计作通过。

覆盖共享数据/查询结果绘制、编辑选择、长文本、列拖动、导入导出、SQL/Kafka/Elasticsearch 视图等 Feature 用例；六种驱动 API 和协议转换未改。Redis 专用集合绘制独立。该回归不等于六种服务的全部操作都做了实库验收。


### 当前 Dev 交付

已签名安装并后台启动 `/Applications/QueryCraftDev.app`，标记 `20261015-103054-e9bdb667`。持久签名验证通过，旧包备份于 `.build/dev-app-backups/20261015-103054-e9bdb667/QueryCraftDev.app`。使用安装包内框架加载/激活 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 六类 API 5 驱动全部通过；lsof 确认 Dev 进程实际加载安装路径下的 QueryCraftFeature.framework。

安装日志 `/tmp/qc-stream-install.log`，驱动日志 `.build/validation/import-performance/installed-driver-loads.log`。最后一次滚动验证结束，所有屏幕蒙屏和 HID 隔离已解除。`git diff --check` 及新增 Python 脚本语法检查通过。未提交、打 tag 或发布。

完成本次剩余的格式流式解析、实库回灌、显示窗口性能测量及完整回归；极端宽表横向滚动的残留掉帧是明确限制，未宣称全软件性能问题全部消除。


### 提交与合并检查（2026-10-15）

本次仅提交功能并合并到本地 main，不创建 tag、不推送、不发布。主程序版本保持 0.1.9（build 19）。相对 v0.1.9，本次功能范围内 Driver API 仍为 5，驱动源代码、专属依赖、manifest 与打包脚本均无改动。主程序构建及完整 Feature 回归、安装版六驱动加载证据见上文。

| 项目 | 本次决策 |
| --- | --- |
| 主程序 | 提交导入导出及性能改动；本次不发布 |
| Driver API | 未变化，保持 5 |
| MySQL | 未改驱动，不重新编译/打包/发布；8.0/8.4 四格式回灌通过 |
| PostgreSQL | 未改驱动，不重新编译/打包/发布；17 四格式回灌通过 |
| Doris | 未改驱动，不重新编译/打包/发布；此前四格式导出通过，不提供导入 |
| Redis | 未改驱动，不重新编译/打包/发布；安装版加载/激活通过 |
| Elasticsearch | 未改驱动，不重新编译/打包/发布；共享视图回归通过，三项未配置实库测试跳过 |
| Kafka | 未改驱动，不重新编译/打包/发布；安装版加载/激活及共享视图回归通过 |

本次不进行线上 catalog、双架构发布包与 appcast 验收；这些属于未来发布前的必要检查，不以本地通过代替线上兼容性验收。


### 与 main 编辑器改动的合并验证

导入导出功能提交 `af6e031`，与 main 的编辑器配色提交 `dab2db0` 自动合并，双方功能保留；清理了共同修改测试窗口时重复的 `isReleasedWhenClosed = false` 赋值。

合并后的 Debug 主程序构建通过（111.1 秒）；完整 Feature 回归 **1281 通过、0 失败、5 条件跳过**（155.2 秒）。跳过为原有三项 Elasticsearch 实库测试，以及 main 新增的两项需显式启用 `QUERYCRAFT_EDITOR_PERFORMANCE=1` 的编辑器性能测试。未把未启用项计为通过。结果包 `test_macos_2026-10-15T02-39-54-214Z_pid85442_e3fb702e.xcresult`。

用合并后的构建框架再次加载/激活六类 API 5 打包驱动全部通过。日志位于 `.build/validation/import-performance/merged-main-build.log`、`merged-main-tests.log`、`merged-main-driver-loads.log`。本轮没有重跑实库回灌；导入导出数据处理与驱动协议代码未受 main 配色合并影响，实库覆盖仍以上述四格式逐字段验证为准。窗口测试的蒙屏与输入隔离结束后已正常解除。

本次合并不替换已安装 Dev、不推送、不发版；main 工作区原有未跟踪文件保留。
