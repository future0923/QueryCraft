# iOS / iPadOS MySQL 验证记录

日期：2026-10-22。独立 worktree `ios-ipad-proof/QueryCraftPublic`，不替换已安装 Mac/Dev 或驱动，不提交、打 tag、发布或修改用户数据库。

## 当前验证

- iPad Pro 13-inch (M5)、iPhone 17 Pro，iOS 26.3 Simulator。SQL 编辑器版本各通过 206 项测试（0 失败、0 跳过），最新记录为 sql-editor-acceptance-ipad-tests.json / sql-editor-acceptance-phone-tests.json（32.248 / 31.931 秒）。
- 原 51 项包括九项查询状态、四项目录/表状态、十项文件/历史/钥匙串/导航、五项 SQL/来源/原生网格、三项目录模糊搜索、一项横屏声明、十一项 MariaDB 集成、四项轴锁规则、四项原生全屏/视口/代理回归；其中十项真实连接临时只读 MySQL，另一项拒绝未实现的严格 TLS。随后增加六项共享查找与三项原生查找界面回归、五项时间戳共享/实库和两项原生格式回归，总计 67 项。
- 最新 Mac 主程序完整 Debug 构建成功。既有 Security 弃用警告不属于此次更改。
- 新 Feature 运行时下，六类已安装 API5 驱动均通过加载、activate 和会话工厂创建；桌面共用网格抽样和单元格预览断言通过。这不代表其他五类驱动已接入移动端。
- 最终 ARM64 iPhoneOS 版本编译和链接成功。后续实体 iPhone 已完成开发签名、描述文件核对与安装（见下方记录）；用户确认开发者信任后启动成功，触摸与实库功能尚未完成真机验收。
- MySQL/Doris 桌面驱动已独立重新编译、ad-hoc 打包并通过签名检查；与四类旧包混合加载通过。新 MySQL 包在本轮打包后实际加载并以 TLS 查询两行，验证别名来源；Doris 未做本轮实库测试。

## 覆盖的行为

- 首次加载、成功为空、慢刷新保留数据、失败重试、重复请求、取消、连接/库/表快速切换和过期成功/失败。
- 首页等待密码不提前进入工作区；返回首页/重开连接保留草稿和目录；删除当前连接返回首页。原生导航页签切换保留查询草稿、刷新派发到当前目录。
- 真实 MySQL BASE TABLE / VIEW 分别查询（服务端类型过滤在 LIMIT 之前），视图字段/数据读取通过。
- 翻页失败保留已提交页号与内容，数据/结构页签切换不接收过期数据。
- 原生 UICollectionView 刷新后保留有效滚动位置、选择与列宽，切对象立即清空旧单元格；表头先出现后首批行到达时重新抽样，后续刷新保持列宽。
- 百万行/千列逻辑尺寸下只生成可见区域布局属性；不是百万行真实查询或内存基准。
- 全屏使用同一个虚拟网格实现与同一页数据，另用非可观察视口状态保存位置、列宽和选择。原生视图往返测试覆盖恢复与对象隔离，并拒绝被遮挡普通视图对全屏视口状态的过期写入。
- 真正挂载 UIHostingController 的原生测试核对：全屏网格在有硬件安全区的窗口内滚动、改变尺寸及左右不对称安全区时仍落在安全区域内，固定表头保持可见。残留 UITextField 响应者在全屏进入、尺寸变化、延迟 keyboardWillShow 时被清除，移除全屏保护后可正常重新输入；不把该原生响应者测试当成实体第三方输入法验收。
- 斜向/水平/垂直起步、起步微小抖动、手势中途改变方向、惯性目标、同对象刷新继续锁轴、新手势换轴与程序化恢复均有断言。原生 UIScrollView 代理断言验证实际偏移约束；不把它当作物理触屏手势测试。
- 保守单语句只读策略、SQL 注释/引号/服务端转义模式，SQL 字节数限制；真实服务端同时使用只读事务。
- 原生传输行数/字节上限、截断后连接关闭与显式重连、真实二进制 00/41/FF、Unicode、NULL/空字符串、实际 TLS 加密、错误密码/SQL 错误和取消后继续查询。
- 真实字段类型、别名来源、表达式无来源、结构注释、主键分页/排序、搜索字面量安全；字段注释按 database/table/column 来源匹配。
- 连接文件不含密码、坏文件不覆盖、文件写失败恢复钥匙串凭据、历史记录去重/限制、真实系统钥匙串读写/更新/删除。

## 实际发现与处理

- Connector/C 3.4.9 loopback 地址的证书校验特殊行为，导致不能承诺严格身份验证。移动端仅关闭 TLS / 要求加密（不验证身份），拒绝 verifyCA / verifyIdentity；桌面 TLS 未改。
- 测试 target 重复链接静态核心/传输曾导致类型身份不一致，已改为仅依赖 host 应用。
- 模拟器工程最初完全禁用签名，真实钥匙串访问返回 -34018。已仅为 Simulator 开启系统 ad-hoc 签名，实际读写/更新/删除测试通过；真机仍需开发团队与有效签名。
- 首次 iPhone 原型测试在 XCTest bootstrap 前被 signal kill，根因未证实；串行启动后通过。最终结果只记录成功执行的套件。
- Intel / iOS 26.3 的 accessibility snapshot 工具返回 translation 错误。采用截图、原生视图断言和真实数据库测试；没有进行桌面输入模拟。
- 该 runtime 缺少 AppleColorEmoji 字体，部分 emoji 截图显示缺字符号；数据库返回的 Unicode 内容断言通过，字体外观不算验收通过。

## UI 与验证边界

UI 使用原生 SwiftUI TabView「表 / 查询 / 视图」导航、表单/分组列表，UIKit 双向虚拟网格；系统 TabView 在 iOS 26 呈现 Liquid Glass，iPad 自适应顶部页签。数据页默认表格，不再叠加自定义浮动操作条；显示/查找/排序及查询历史收进系统顶部菜单，行数/翻页共享固定底栏。表格/编辑器是清晰的不透明内容层。大文本详情最多排版 16,384 个字符，并明确提供完整文本分享。参考 TablePro 信息层级，未引入其源码/资源/依赖。Mac AppKit 页面不替换。

实体 iPhone 已签名安装并启动，用户提供了实库页面截图。iPhone 右横屏在模拟器通过原生 scene geometry 请求实际渲染；iPad 核对了宽表分栏布局与四向配置，该截图仍是竖向窗口，不当成物理横转验证。原生网格尺寸变化测试核对了固定表头、列宽与选择。尚未由自动化验收实体设备转动、触摸、拖列宽、中文软键盘/IME、分屏/超大字体、后台恢复、外网/VPN、可信 CA 验证。程序化截图只证明实际渲染，不代替这些交互验收。

SQL 最多保留 500 行 / 4 MiB 原始字段字节，超限明确标记；零行若由截断造成，不显示成功为空。数组、字符串、元数据和单个传输包有额外开销，不承诺整个进程的内存硬上限。表页最多 200 行 / 8 MiB，超大页报错并保留上一页。没有移植 Mac 的大结果磁盘缓存、增量流、多语句页签、完整 SQL 编辑器、任意写 SQL/DDL、导入、选中范围导出与跨执行事务。其他驱动移动端延后，Kafka 按用户要求不做。完整同步清单见 `MAC_PARITY.md`。

目录按类型读取完整有界元数据后复用桌面搜索/排序；目录上限为 10,000 个对象 / 8 MiB，溢出明确失败，绝不在前 200 个对象内搜索却假称完整结果。当前页/SQL 结果查找复用 Mac 的 worker/controller/operators/match，支持列范围、包含/等于/开头/结尾、大小写和循环前后定位，保留全部行。范围仍是已加载页/结果，移动端未移植磁盘大结果缓存。

## 本地证据

均位于 worktree 忽略目录 `.build/`：

- `fullscreen-final-iphone-tests.json`、`fullscreen-final-ipad-tests.json`：最终各 49 项通过；`fullscreen-device-update.json`：本轮签名构建、覆盖安装与启动结果。
- `safearea-keyboard-iphone-retry-tests.json`、`safearea-keyboard-ipad-tests.json`：安全区/焦点修复最终各 51 项通过（18.424 / 22.396 秒）。最初 `safearea-keyboard-iphone-tests.json` 为新测试辅助方法缺少显式 self 的编译失败，不是通过；已修正。脚本新增结构化结果核对，失败时不继续渲染旧应用。
- `safearea-keyboard-device-update.json`：最新签名构建、覆盖安装与启动全部成功（21.051 秒，PID 1112），没有附带模拟器夹具环境。用户手机上第三方键盘/真实转动仍待人工确认。
- `ios-validation/safearea-keyboard-<phone/ipad>-<fullscreen/fullscreen-landscape/query-fullscreen>.jpg`：修复后的系统安全区布局截图，已检查 iPhone 竖/右横屏和 iPad 表/查询全屏；不将程序化尺寸变化当成 iPad 实体转动验收。
- `fullscreen-device-update.json` 的组合动作被标记失败：原始日志实际 BUILD SUCCEEDED，后续启动因手机锁屏被拒绝。严格签名验证通过后，另行 device install 成功（`fullscreen-device-install.json`）；未声称最新版本已在锁屏手机自动启动。
- `ios-validation/mysql-first-<UUID>-<fullscreen/fullscreen-landscape/query-fullscreen>-screenshot.jpg`：真实有界表页/SQL 查询的纯网格渲染，退出按钮自动隐藏后不保留工具栏或状态/分页栏。
- `compact-detail-iphone-tests.json`、`compact-detail-final-ipad-tests.json`：紧凑表详情各 43 项通过；`compact-detail-final-device-update.json`：最新签名构建、覆盖安装并启动成功。
- `landscape-iphone-tests.json`、`landscape-ipad-tests.json`：横屏配置与宽表版本各 43 项通过；`landscape-device-update.json`：该阶段签名构建、覆盖安装并启动成功。
- `clean-grid-shared-iphone-tests.json`、`clean-grid-final-ipad-tests.json`：共享匹配/排序、完整目录与 78 字段 / 120 行隔离宽表的 42 项回归及截图。
- `clean-grid-mac-build.json`：公共排序方法提取后桌面完整构建；`ios-validation/mac-search-check.txt`：直接调用最新编译框架中实际 macOS 对象列表入口，表/视图/index/alias/data stream 的匹配分级、分数、同分顺序、空搜索及原有 bo 回归均通过。
- `clean-grid-mac-search-tests.json`：最初尝试 Xcode scheme 测试未执行用例，原因是 QueryCraftFeature scheme 未配置 test action；未将此计为通过。随后以上述实际框架回归验证入口。
- `tabs-iphone-tests.json`、`tabs-ipad-tests.json`、`tabs-device-build.json`：此前首页整理与系统 Glass 页签版本，37 项测试各通过一次及 ARM64 真机目标编译成功。
- `mysql-first-ipad-tests.json`、`mysql-first-iphone-tests.json`：测试统计、各用例与 xcresult 路径。
- `mysql-first-device-build.json`、`mysql-first-mac-build.json`：ARM64 真机目标与 Mac 构建。
- `mysql-first-driver-build.json`、`mysql-first-doris-build.json`：受影响驱动独立构建。
- `ios-validation/mysql-first-<simulator UUID>-<query/table/structure>-screenshot.jpg`：真实查询、表数据和结构渲染；同名前缀 JSON 记录工具原始截图路径与启动日志。
- `ios-validation/mysql-first-six-driver-load.txt`：六类旧驱动加载与共享网格断言。
- `ios-validation/mysql-first-mixed-driver-load.txt`：本地新 MySQL/Doris 包与四类旧包加载及新 MySQL 实库断言。
- `ios-validation/mysql-first-package.log`、`doris-first-package.log`、`ios-driver-catalog/`：本轮打包及签名检查。
- `ios-native/`：OpenSSL 3.6.3 / MariaDB Connector/C 3.4.9 三切片、SHA-256 清单和构建日志。

临时 loopback MySQL 仅包含本次创建的测试数据，用完由脚本删除容器及卷。Debug 渲染入口使用内存连接库，不将测试配置/密码写入用户文件或钥匙串。每个系统钥匙串用例使用随机 UUID 并清理自身凭据。


## 实体 iPhone 安装进展（2026-10-22）

- 设备报告机型 iPhone 15 Pro Max、iOS 27.2；手机自定义名称含 iPhone 18 Pro Max，不以该名称判断硬件。
- 开启开发者模式后，Xcode 完成了实际设备的描述文件注册和应用签名。构建工具同时添加 generic 与具体设备两个 destination，generic 阶段先报无设备错误，但具体设备阶段生成了完整签名包；因此没有把该组合命令记录为构建成功。
- 对实际产物独立执行 codesign --verify --deep --strict 通过；应用标识/团队 entitlement 与 embedded.mobileprovision 匹配，描述文件包含当前连接手机。以 XcodeBuildMCP device install 安装成功，证据 .build/iphone-device-install.json。
- 首次启动被设备系统安全校验拒绝（包含未明确受信任的 profile 提示）；用户在手机上确认开发者 App 信任后，XcodeBuildMCP device launch 成功（PID 665）。失败证据 .build/iphone-device-launch.json，成功证据 .build/iphone-device-launch-trusted.json。没有关闭代码签名校验或绕过设备信任。
- 当前个人开发描述文件有效至 2026-10-29；过期需重新签名安装。签名设置仅通过本机命令覆盖，不将个人团队/证书/描述文件加入工程源码。
- 截至此记录确认签名、安装及设备系统接受启动请求；未自动读取手机屏幕，尚未将触摸、IME、旋转、后台恢复或实库连接算作通过。

## 紧凑表详情（2026-10-22）

删除数据/结构切换占用的整行；改用系统顶部标题菜单。在紧凑宽度或紧凑高度的表详情中隐藏主 Tab 导航，依靠原生返回按钮回到目录；常规 iPad 分栏保留顶部紧凑主页签，避免隐藏后没有方便的查询/视图入口。底部仅保留 44 pt 行数/进度/错误/翻页栏。已检查 iPhone 竖屏、右横屏和结构页及 iPad 分栏渲染，不以截图代替真实触摸验收。

## 表格查找对齐（2026-10-22）

- 从 Mac 的真实表页、SQL 结果与 Redis 集合入口提取数据源协议，原算法与状态控制源码直接供移动端编译。Mac 的磁盘结果访问仍保留原适配器。
- iPhone/iPad 使用同一查找控制器定位并高亮匹配单元格，保留全部原始行；支持全部列/指定列、四种匹配方式、区分大小写、匹配计数与循环前后跳转。NULL、二进制、长文本和重复列名按实际类型/列索引处理，匹配上限沿用 Mac 的 10,000 项。
- 查找条按需出现，可明确收起键盘或结束查找。SQL 查找期间收起编辑区，结束后恢复草稿。紧凑横屏输入期间让出标题/底栏空间。键盘缩小视口时保持匹配格可见，结束输入后的尺寸变化保留用户手动滚动位置，避免全屏返回时跳回旧匹配项。
- 新增六项共享查找状态/算法回归与三项原生选择/视口/SwiftUI 编辑区恢复回归。原生 UI 测试使用实际 UIWindowScene 驱动响应式更新；早期 legacy UIWindow 导致的失败如实保留，不视为通过。
- Mac 完整构建成功（grid-find-mac-build.json）；直接调用已编译 Feature 的表页/查询/Redis 适配器、匹配规则、控制器以及磁盘缓存第 50,002 行匹配通过（ios-validation/mac-grid-find-check.txt）。六类驱动加载/会话工厂与隔离 MySQL TLS 查询通过（ios-validation/grid-find-six-driver-load.txt）。其他五类未做本轮实库查询，移动端仍只有 MySQL；驱动 API/转换未改。
- 最新签名构建、覆盖安装与启动均成功（grid-find-final-device-update.json，18.586 秒，PID 1194）。此前 grid-find-device-update.json 因锁屏未启动，另行安装成功；本条仅以最终组合结果确认更新。
- 用户体验用 querycraft-ios-experience-* 容器有意保持运行，使两个模拟器可刷新、翻页和查询。自动测试自己的 querycraft-ios-proof-* 容器仍由脚本退出清理。
- 最终 iPhone/iPad 各 60 项通过，截图 ios-validation/grid-find-{phone,ipad}-{find,query-find,fullscreen}.jpg 已检查：表格查找高亮并保留行、查询编辑区收起、全屏安全区与自动隐藏退出控件均正确。截图渲染为横屏，原始像素轴仍为竖向；不当作实体转动/第三方 IME 验收。

## 时间戳显示对齐（2026-10-22）

- 直接编译 Mac formatter，仅添加条件导入与等价 origin 访问。移动网格保留传输 workspaceColumns 中的真实类型/来源，不按注释或显示名称猜测物理字段。自动识别、整数/日期范围、本地时区、缓存及有界预览沿用 Mac。
- 表头原生上下文菜单及辅助功能动作提供四种模式。只重新测量当前列，表刷新/翻页/全屏往返保留模式，换对象、完整元数据改变或 SQL 新结果重置；隐藏后台视图不能重置全屏状态，过期表头动作不能修改新结果。
- 六类桌面驱动适用范围见 MAC_PARITY.md。此次未改 Driver API、外置驱动或 Mac 数值解析；其他五类没有本轮实库查询，移动端仍仅 MySQL。
- 新增五项 Swift Testing 和两项原生 UIKit 回归：协议类型/别名、秒/毫秒/原值、日期边界、大整数、超长字符串、本地时区与 typed NULL/空字符串/二进制；原始值查找；模式生命周期；原生可见单元格、菜单/辅助功能、列宽/选择/视口与全屏所有权。真实自有 MySQL fixture 覆盖表页、跨库关联、别名、表达式与零行元数据。
- 初次测试引用 private cell 类型、遗漏 nullDisplayText，以及直接调用 datasource 的 dequeue 入口导致的 UIKit 一致性失败均保留为失败证据；随后通过实际可见单元格读取修正测试，没有放宽产品类型访问或绕过 UIKit 检查。
- 截图检查发现紧凑横屏 SQL 编辑区压缩结果到零高度，已将紧凑高度的编辑区改为 60 pt，并移除重复结果标题；常规布局仍保留 130 pt 编辑区。已有原生查询查找回归同时断言结果区域保留实际高度。
- 最终测试各 67/0/0：timestamp-final-phone-tests.json（84.745 秒）、timestamp-final-ipad-tests.json（32.861 秒）。两次较早的 67 项通过记录发生在紧凑布局修正前，以最终记录为准。
- Mac 完整 Debug 构建通过（timestamp-mac-build.json，598.306 秒）；实际编译 Feature 的原生表/SQL 网格、显示模式生命周期、原始复制/导出与格式化边界回归通过（ios-validation/mac-timestamp-check.txt）。六类驱动加载/activate/会话工厂和自有 MySQL TLS 查询通过（ios-validation/timestamp-six-driver-load.txt）。
- 最新签名构建、安装和实体 iPhone 启动成功（timestamp-device-update.json，79.830 秒，PID 1227），codesign 严格验证通过。程序化测试和截图不代替实体触摸/第三方 IME/转动验收。
- 最终表页、别名 SQL 与全屏实际渲染均已检查，截图为 ios-validation/timestamp{,-query,-fullscreen}-{phone,ipad}.jpg；显示本地日期、18 位原始 ID、varchar 原始内容均正确。两个模拟器已恢复至保留的用户体验 fixture 中 epoch_values 普通表格页，可长按表头体验模式切换。测试 fixture 均已清理。

## 侧栏顶部与紧凑导航（2026-10-22）

- 用户截图指出 iPad 侧栏被全局 Tab 导航压低，随后要求移除占用整行的 Tab。最终常规宽度采用根 NavigationSplitView，表/查询/视图放入左侧现有导航标题菜单；右侧为当前内容及其唯一公共工具栏，紧凑宽度保留原生 Glass 页签。
- 新原生回归验证常规导航不包含 UITabBarController，根分栏不位于 Tab 内；实际常规高度下侧栏导航栏对齐系统顶部安全区；三模式切换保留同一分栏及 SQL 草稿。模拟常规宽度的紧凑高度 iPhone 仍有原生状态栏 inset，不以其几何值作为 iPad 顶部验收，但仍检查其控制器层级。
- 改动仅涉及移动容器和测试，公共数据、Mac 和六类外部驱动均未改，不需要重复构建 Mac/驱动，也不宣称增加其他驱动移动支持。已有 MySQL 全链路回归随移动套件执行。
- 最终标题菜单版 iPad/iPhone 各 68/0/0（sidebar-menu-ipad-tests.json，42.433 秒；sidebar-menu-phone-tests.json，25.875 秒）。实际表/查询/视图截图确认侧栏顶部、取消整行 Tab，以及原生数据/结构菜单和公共刷新/结果工具栏可见；iPhone 紧凑导航仍保留原生 Tab 和返回。
- sidebar-menu-device-update.json：签名构建、安装、启动成功（22.202 秒，PID 1257）。两个模拟器已恢复到保留的体验 fixture，iPad 请求右横屏。截图保留于 ios-validation/sidebar-menu-{ipad,phone}-*.jpg。本次没有用户桌面鼠标/键盘模拟。

## Server-side MySQL filters and input alignment (2026-10-22)

- Mobile compiles the actual Mac MySQL predicate builder, filter models/operators/validation and enum/bool/default-column helpers. WHERE runs before sort and paging; table/view filtering includes rows beyond the loaded page. SQL custom results retain loaded-data find rather than rewriting arbitrary SQL.
- Native optional filter sheet has persistent left labels and right values/inputs, including both range bounds. Independent cancelable draft, disabled conditions, all/any, clear and error repair use the same shared semantics. No extra toolbar row.
- Added 7 shared/real-MySQL cases, 4 slow/failure/stale state cases and 1 native viewport case to the previous 68. Final each 80/0/0, reports above; screenshots: ios-validation/mysql-first-<UUID>-{server-filter,filter-editor}-screenshot.jpg. Actual results show 110-115; right-side input placeholders inspected on both devices. Raw iPad screenshot axes are inverted, not physical rotation acceptance.
- Live tests include default/NO_BACKSLASH_ESCAPES modes, literal wildcards/backslash/quotes/Unicode, injection-like text, NULL/empty, enum/bool/date/number/binary, cross-database long IDs, views, paging/sort and empty metadata. Pending filters cannot relabel old committed data; failure retains grid, retry starts at zero, stale replies and stale object editors rejected.
- Same logical page refresh keeps offset/selection; changed filter/page/sort resets vertical row and selection while preserving horizontal offset, widths and timestamp modes. Fullscreen restores only matching page/metadata context.
- Mac main full build passed (server-filter-mac-build.json,555.836s). Independent MySQL build passed (server-filter-mysql-driver-build.json,739.405s), packaged/ad-hoc signature verified. ios-validation/mac-server-filter-check.txt confirms actual compiled Mac helpers, all six Dev registry/factories, new MySQL TLS/live filter/paging/sort/count. Rerun after main build also passed. Installed Mac/Dev and driver library were not replaced; other five drivers have no new live-query validation or mobile support.
- Latest signed device build/install/launch succeeded (filter-value-alignment-device-update.json,18.641s,PID1392), strict signature verified. Physical touch/IME acceptance remains manual. Both simulator experiences restored to retained read-only fixture without auto editor/fullscreen. Binary filter values retain Mac text-input limits. No commit/tag/release or desktop input simulation.

## Loaded-data export (2026-10-22)

- Same Mac writer, request, defaults, dialect and original Foundation copy types compiled on mobile. New JSON alias collision regression preserves distinct existing suffixed names without dictionary-key collisions. No query/driver/API changes.
- iPhone/iPad each 89 passed, zero failed/skipped. Eight new shared/model/live-MySQL tests cover CSV BOM/quoting/null/empty/formula protection, all JSON layouts/duplicate aliases/binary descriptions/long IDs, actual XLSX ZIP/XML/raw controls/header options, SQL identifier/literal/atomic rollback, native file-wrapper contents, immutable snapshot/cleanup, noncooperative cancellation/retry and filtered page/query aliases. One native hosting regression verifies that Files opens and its source survives presentation/cancel for retry. No physical desktop input was simulated.
- First test build rejected a non-Sendable asynchronous polling predicate; fixed its Sendable boundary. Failed attempt remains recorded, not counted as validation. Phone retry and iPad reports above are successful. Real export options screenshots: ios-validation/mysql-first-<UUID>-{export,query-export}-screenshot.jpg. The primary save button uses one stable row before and after generation.
- Mac full build: data-export-mac-build.json (194.816s). Native compiled framework four-format/default/dialect assertions: ios-validation/mac-export-check.txt; independent Python zipfile/XML reads actual generated XLSX, preserving long IDs/text and header options. Six driver registry/factories and owned MySQL TLS filter checks: ios-validation/data-export-six-driver-check.txt. Installed Mac/Dev and driver library remain unchanged. No new non-MySQL live queries or mobile drivers.
- Scope is committed current page/query preview, explicitly including truncated-query notices; not whole-table or selected-range export. Binary summaries and SQL binary rejection match Mac. Output files use native Files destination selection, bounded input snapshots, cancel/retry fencing and temporary cleanup. Export preferences/task center/full-table streaming remain unported.
- Final binary-summary disclosure polish compiled for Simulator and signed ARM64 iOS (data-export-final-simulator-build.json,16.785s; data-export-final-device-build.json,12.737s). Strict signature passed. Physical install attempt failed because CoreDevice could not locate the disconnected device; data-export-device-list.json confirms disconnected/unavailable. No claim of phone update or physical Files/IME/touch acceptance. Final simulator screenshots stored as ios-validation/data-export-{phone,ipad}-final.jpg; live read-only experience restored after capture.
- Final Form footer review caught SwiftUI showing only the first footer child; grouped the conditional binary disclosure in a VStack. Final phone 89/0/0 (data-export-final-phone-tests.json,27.111s), signed ARM64 build passed (data-export-final-footer-device-build.json,8.016s), strict signature passed. Phone render now visibly explains binary summaries; same final app installed on iPad and screenshot inspected. No further database/driver/Mac changes.

## Shared SQL editor (2026-10-22)

- Same Mac SQLStructuralParser/SQLCompletionEngine/Ranker/source range/scope/highlight recovery/default color source; native UITextView and recyclable candidate input accessory. Actual engine distinguishes aliases/joins/subqueries/CTEs/comments/strings and inserts with original UTF-16 ranges/cursor offsets. Same-source/caret/marked-text/generation guards prevent stale edits.
- Original Mac completion/parser suites and their 88 KiB grammar fixtures compile directly in mobile tests via conditional imports/bundle lookup. Added real metadata and native input regressions: lazy/cached columns, true type/comment/ordinal, cross-schema/view/aliases, failures/retry, noncooperative stale connection replies, merged column loads/inactive cancellation, Unicode mid-source insertion/native undo, marked text, theme changes, Escape/late responses, and long-draft visible-range scrolling. Product factory used for native editor tests; an earlier default-font test view caused a viewport failure and is not a pass.
- Initial iPhone/iPad each 204/0/0; cache/viewport follow-up iPad 206/0/0 (sql-editor-complete-ipad-tests.json,33.756s). Final IME/Escape phone acceptance 206/0/0 (sql-editor-acceptance-phone-tests.json,31.931s). Final iPad acceptance recorded separately after the same source is exercised there. Failed manifest/signing/import/selector/test-resource attempts remain failure evidence, not validation.
- Mac full Debug build passed (sql-editor-mac-build.json,203.631s); actual compiled Mac engine/highlight/parser resource/shared palette/application guards for MySQL/PG/Doris passed (ios-validation/mac-sql-check.txt). NonSQL editor behavior remains separate and unchanged.
- Extracted the driver's actual object/column query projections and conversions into MySQLSchemaCatalog source, preserving full type, actual ordinal and comments. MySQL driver rebuilt independently (sql-editor-mysql-driver-build.json,406.998s), isolated ad-hoc package/signature passed (archive hash prefix 9f1e962816afe904). Actual Dev registry/factories load all six bundles; newly packaged MySQL TLS schema catalog/view/78-column/ordinal and existing filter/paging checks passed (ios-validation/mac-sql-driver-check.txt). Installed Mac/Dev/library not replaced; other five drivers have no new live-query validation or mobile support.
- Native renders show shared syntax colors, contextual user_name/user_nick/user_real_name above keyboard for u.us, and retained query grid. iPad input accessory works in the simulator hardware-keyboard presentation. Screenshots are native renders, not physical keyboard/IME/rotation acceptance; phone landscape geometry request did not rotate the raw capture and is not claimed as physical rotation verification.
- Signed ARM64 build/signature passed (sql-editor-acceptance-device-build.json,9.579s). Physical device state checked separately before delivery. SQLite/Keychain/profile state preserved. Custom editor color preferences/snippet manager/multicursor/formatting/statement execution selection remain unported; existing single read-only execution policy unchanged. Resource bundle layout changed to copied SQL/JSON directories for iOS signing; actual query-resource tests and Mac parser verify lookup. SwiftTreeSitter 0.25.0 / tree-sitter 0.25.10 pinned to current Mac versions.
- Final same-source iPad acceptance passed 206/0/0 (sql-editor-acceptance-ipad-tests.json,32.248s), matching phone 206/0/0. Latest signature verification passed; sql-editor-final-device-list.json confirms disconnected/unavailable device, so the new SQL-editor version was not installed on the physical phone. Both simulators restored to live read-only query editor without automatic focus/completion probes; retained fixture intentionally remains alive. Final native render snapshots: ios-validation/sql-editor-{phone,ipad}-{query,editor}.jpg. No commit/tag/release or physical desktop input injection.

## Whole-table export (2026-10-22)

- Final iPhone/iPad each 213 passed, 0 failed/skipped: `all-export-final-phone-tests.json` (33.517s), `all-export-final-ipad-tests.json` (33.516s). Includes native Files URL picker lifetime/cancel, real MySQL TLS 455-row table/view, four formats, committed filter/descending order across batches from a nonzero displayed page, empty filtered export, >8-MiB row rejection with existing file preserved, captured target across browser navigation, schema-change fencing, pending cancellation and failed second-batch retry starting from zero. Prior first suites each 212/0/0 are retained separately.
- `all-export-mac-build.json`: full Mac Debug build passed (391.663s). Actual compiled Mac framework harness `ios-validation/mac-whole-table-export-check.txt` verifies 5,000/5,000/2,050 batches for MySQL/PG/Doris, filtered/sorted four-format exports, direct table preparation/generated-column/identity behavior, binary/NULL validation, six packaged driver activation/factories and a real TLS MySQL export through Dev registry/session. Independent Python CSV and ZIP/XML readers verified 1,050 rows/header/order in all three dialect test outputs. Other five drivers had no new live database queries. No new external-driver source changes in this increment; installed Mac/Dev and driver library untouched.
- `all-export-signed-device-build.json`: signed ARM64 iOS build passed (21.417s), `codesign --verify --strict` passed. `all-export-device-list.json` confirms phone disconnected/unavailable, so this version was not installed on the physical device. Native Files provider/cloud destination and physical touch/background acceptance still require device experience.
- Inspected final iPhone/iPad scope forms and loaded-query scope screenshots, saved as `ios-validation/whole-table-export-{phone,ipad}-{all-export,export,query-export}.jpg`. Both simulators restored to live `admin_user` table using retained owned read-only fixture (`all-export-{phone,ipad}-experience.json`); only the experience container remains. Test fixtures/volumes removed, whitespace and shell syntax checks passed. No desktop mouse/keyboard injection, commit/tag/release.
- Entire-table scope is bounded paged reading, not a transaction snapshot. Mobile batch <=200 rows /8 MiB original fields with one writer prefetch; process memory has additional transport/string/array overhead. Oversized pages fail explicitly, binary values remain summaries (SQL rejects binary). Arbitrary-query rerun, selected-range export, task center and persisted export preferences are still unported.


## MySQL data editing (2026-10-22)

- Final iPhone/iPad each **224 passed, 0 failed/skipped**: `data-edit-acceptance-phone-tests.json` (28.027s), `data-edit-acceptance-ipad-tests.json` (31.734s). Real isolated writable MySQL fixtures cover raw 18-digit/composite PKs and grouped updates (including PK edits), Unicode/quotes/backslash/NUL, NULL/defaults, staged inserts/deletes/restoration, generated/binary/no-PK guards, whole-transaction rollback and correction/retry, cancellation after first successful write, server SELECT-only account denial, object navigation/insert correction/connection replacement guards and uncertain-COMMIT blocking. Native UIKit tests verify pending/delete accessibility, grid widths/viewport stability and actual Done responder dismissal without text change or staging. Existing editor/search/filter/export/loading regressions remain in these full suites.
- Earlier phone 220/0/0 (48.550s), intermediate iPad 222/0/0 (52.698s). A later native vertical TextField keyboard test failed at `MobileDataEditingPresentationTests.swift:48`; log `test_sim_2026-10-22T10-55-34-116Z_pid98124_cfc953c9.log` and corresponding xcresult retain it. The failed CLI invocation left its JSON summary empty, and is **not** counted as a pass. Native UITextView adapter fixed the actual behavior; targeted native suite 2/0/0 (28.814s) then final full suites above passed.
- Mac main full Debug build `data-edit-mac-build.json` passed (148.651s). MySQL independent build `data-edit-mysql-driver-build.json` passed (393.577s). Isolated signed bundle/archive `.build/data-edit-driver-mixed/mysql-driver-1.0.8-x86_64-ea1e3f3ac17e52e6.zip`; package signature verified. `ios-validation/mac-data-editing-check.txt` uses actual compiled host and real Dev registry/session: six driver activation/factories, new MySQL packaged runner, grouped composite PK update, exact Unicode/NUL, insert/default/NULL/delete, later-statement failure rolling back earlier writes, Mac details overloads and generated-field guard. Only owned `querycraft_ios_edit.mac_*` fixtures were written, not user databases. Installed Mac/Dev and driver library were not replaced; other five drivers had no new live database writes.
- Signed ARM64 iOS `data-edit-final-signed-device-build.json` passed (17.948s), strict codesign passed. `data-edit-device-list.json` shows phone disconnected/unavailable; no physical install or physical third-party IME/rotation/external-keyboard acceptance claim.
- Native editing forms inspected and saved as `ios-validation/data-edit-{phone,ipad}-cell.jpg`. Both simulators launched the retained owned writable example database with safety lock on (`data-edit-{phone,ipad}-experience.json`). Read-only example database remains intact. Ephemeral proof containers/volumes removed; only the retained experience container remains. No real desktop mouse/keyboard injection, commit/tag/release.
- Scope: ordinary grid editing for MySQL InnoDB base tables. Updates/deletes require available original PKs; views/complex query results, full binary mutation, nontransactional engines, arbitrary write SQL/DDL and persisted drafts are unported. Mac PK-only matching is preserved, with no original-value optimistic comparison. Mobile blocks blind repeat of uncertain COMMIT. Native Files export still uses committed server values, not local staging. Existing MariaDB placeholder resolution still does not support `?` inside quoted identifiers; this inherited Mac transport limitation fails before SQL execution and preserves drafts. The transport escape implementation follows server NO_BACKSLASH_ESCAPES status; no new literal renderer was introduced.

## SQL query result editing (2026-10-22)

- Full owned MySQL acceptance: iPhone **239 passed/0 failed/0 skipped**, `query-edit-acceptance-phone-tests.json` (33.873s); iPad **239/0/0**, `query-edit-acceptance-ipad-tests.json` (53.012s). Covers aliases/quoted Unicode aliases, real physical comments/types, duplicate projections, expression named PK rejection, raw 18-digit/composite keys and PK edits, cross-database writes, NULL/defaults, delete/restore, rollback/correction/retry, SELECT-only denial, views/joins/self-joins/no-PK/empty results, slow/failed/cancelled/late metadata, stale presented requests, pending connection/database/reexecution protection, home/navigation retention and uncertain-COMMIT blocking. Existing editor/filter/find/export/table/loading regressions remain in these full runs.
- Native UIKit query-entry test drives the real grid delegate into the shared edit sheet, tests actual Return/Done responder dismissal without staging or SQL-draft changes, closes the sheet preserving grid widths/frame, then verifies staged accessibility/color and default safety lock. Final focused same-source state/native checks each passed 7/0/0 (phone 22.056s, iPad 18.330s), recorded separately as `query-edit-{phone,ipad}-native-final.json`; no physical mouse/keyboard injection.
- First run exposed recursive Observation setters during a blocked database change (231 passed/1 crash); fixed with an explicit restoration guard. Raw failure evidence remains in XcodeBuildMCP log `test_sim_2026-10-22T11-28-13-524Z_pid23641_3aeb0da0.log` and local crash report `QueryCraftMobileProof-2026-10-22-192905.ips`; these are not counted as passes. An early render used unsupported unquoted Unicode aliases and remained read-only; final renders use tested quoted aliases and show actual editing/pending sheets.
- Mac complete build `query-edit-mac-build.json` passed (387.686s). Actual compiled host harness `ios-validation/mac-query-editing-check.txt` verifies six real Dev registry/session factories, actual MySQL TLS query origins, aliases/raw keys/cross-database selection, expression/missing-physical-PK edit/delete guards, resident result patch, and schema-qualified PG resolver models. Harness uses retained owned fixtures read-only; mobile writes use isolated ephemeral test databases only. Shared query validation is used by Mac inline, inspector update and deletion paths; ordinary table preparation unchanged. No external driver source/protocol change this increment, so reused the previously independently built/packaged/verified `.build/data-edit-driver-mixed` directory. Other five drivers have no new live DB writes.
- Final ARM64 build `query-edit-signed-device-final.json` passed (13.756s), strict codesign verification passed. `query-edit-device-list.json` confirms physical phone disconnected/unavailable: this increment was not installed there; physical IME/rotation/external-keyboard acceptance remains manual.
- Phone/iPad query/form/pending snapshots: `ios-validation/mysql-first-<UUID>-query-edit{,-form,-pending}-screenshot.jpg`. Native forms and existing compact toolbar/sidebar inspected. Both simulators restored separately to retained owned writable query experience, safety lock on, no automatic focus/pending/edit probes. Transient containers/volumes cleaned; retained experience intentionally alive. No commit/tag/release, installed Mac/Dev or driver-library replacement.
- Scope/limits: MySQL InnoDB reliably parsed single-relation result updates/deletes only; expressions, ambiguous/missing physical keys, binaries/generated cells readonly. No query-result inserts, arbitrary write SQL/DDL, persisted drafts or complex-query editing; record/fullscreen entry is covered by the following increment. Submitted physical fields patch local results without rerunning SQL; computed/default/server-trigger effects and WHERE/ORDER BY membership require explicit reexecution. DEFAULT/unknown COMMIT blocks further edits until requery. PK-only concurrency semantics remain inherited; no original-value optimistic check. Raw export excludes unsubmitted staging. Existing quoted-identifier `?` binding limitation remains documented above.

## Fullscreen and record editing (2026-10-22)

- Full owned MySQL acceptance: phone **248 passed/0 failed/0 skipped**, `surface-edit-phone-acceptance.json` (47.059s); iPad **248/0/0**, `surface-edit-ipad-acceptance.json` (53.899s). Includes the existing real MySQL table/query mutation, rollback/cancel/permission/default/raw-PK/alias/expression/navigation regressions. New presentation adapters reuse those exact models and writer; no separate fullscreen or inspector mutation implementation.
- Added 5 Swift Testing source cases: same pending model/raw keys across surfaces, edit/revert, pending-vs-raw generation, loading/changed page/query/object fencing, stale source cannot regain ownership, readonly/binary/generated cells, and aliased query physical-origin/expression behavior. Added 4 native XCTest cases: actual fullscreen grid delegate into the native editor, legitimate keyboard through notifications/resize/Done, guard resumes on actual sheet dismissal, live pending repaint with valid viewport/width preservation, transient pending/accessibility entry with no permanent toolbar, record scroll-anchor recreation and live inspector/capture behavior.
- Final focused native/state suites passed 16/0/0 each (`surface-edit-phone-final-native.json`,38.747s; `surface-edit-ipad-final-native.json`,46.609s). Large-detent follow-up phone 4/0/0 (`surface-edit-phone-large-detail.json`,24.297s). Strengthened record-anchor tests force an actual new scroll-view identity and verify nonzero restoration/live staging on both sizes (`surface-edit-{phone,ipad}-record-recreate.json`, each 1/0/0;15.629s/20.065s). Earlier failed native tests exposed blanket keyboard suppression/viewport movement and are failure evidence, not passes: `test_sim_2026-10-22T12-13-57-627Z_pid62516_fa4e2f0f.log` and subsequent focused run. Initial iPad 247/1 used an impossible nonzero horizontal offset when all fixture columns fit; corrected to begin with a valid offset. Existing narrow-grid nonzero horizontal restoration tests remain unchanged.
- Fullscreen input protection now checks actual presented-controller/responder ancestry in the same window, including delayed callbacks. Sheet fields stay active; background input is dismissed. Background keyboard-safe-area changes no longer move pure fullscreen data, viewport writes pause while its sheet is open, and dismissal restores state. Hardware safe areas and strict one-axis scrolling retain their native regressions.
- Native table fullscreen/edit/pending and record/detail/edit screenshots: `ios-validation/mysql-first-<UUID>-surface-*-screenshot.jpg`; actual retained MySQL query-result fullscreen/edit and record details: `ios-validation/surface-{phone,ipad}-query-*.jpg`. Phone landscape and iPad landscape captures retain the simulator tool's raw pixel orientation; they do not replace physical rotation acceptance. Record detail opens large after render review found inherited medium height too short on a landscape iPad.
- Mobile-only source changes. Actual Mac coordinator/inspector paths traced; no Mac source, driver public model, transport, writer or external driver change this increment. MySQL table and supported query-result surfaces covered; five other drivers remain unported mobile-wise. PostgreSQL/Doris desktop origin/PK/SQL flow, Redis/ES specialized mutations and Kafka remain unchanged; no new five-driver real DB verification claimed, and no Mac/Dev or installed driver-library replacement.
- Final ARM64 signed build passed (16.709s), strict signature verification passed; records: `surface-edit-device-final.json` / `surface-edit-device-list.json`. Physical phone disconnected/unavailable, so this build was not installed there; physical third-party IME/rotation/external-keyboard acceptance remains manual. Both simulators restored to retained owned example with safety lock on, no automatic edit/pending probe. Ephemeral test containers/volumes cleaned; retained experience remains alive. No desktop mouse/keyboard injection, commit/tag/release.
- Limits remain MySQL InnoDB, safe original PK and supported single-relation SQL result editing; complex query/expression/binary/generated/no-PK guards retained. Record details close on raw result replacement and old editors refuse staging, rather than remapping a captured index to a different row. Pending drafts remain in the same per-object/result model. Large text stays bounded in display with full sharing; no arbitrary write SQL, DDL or persisted drafts added.

## 连接与后台可靠性（2026-10-22，最终 262 项）

- iPhone 17 Pro：`.build/reliability-phone-final.json`，262 通过 / 0 失败 / 0 跳过，49.511 秒。iPad Pro 13-inch (M5)：`.build/reliability-ipad-final.json`，262/0/0，49.744 秒。此前 261/0/0 的整套验证后，增加已确认提交但后台未回刷的只读保护，再重跑两端整套；不把旧结果冒充最终版本。
- 本轮新增 14 项：表数据/查询后台中断、慢响应失效、SQL 草稿及暂存保留、实际不可用端口的连接失败与显式重试、元数据暂停、未完成导出取消及已完成文件保留、普通表不明提交后的失败核对保护、后台确认成功后的显式回刷保护、四项真实事务故障、原生网格固定布局回归。
- 自有 MySQL 测试表 `reliability_cancel/commit/inflight/disconnect` 与用户库隔离。真实 UPDATE 后取消，核对 ROLLBACK 确实执行且服务器值未变，即使安全锁已经重新启用；再次明确解锁/提交才执行写入。真实连接关闭后确认服务器回滚。真实 COMMIT 后故意丢失确认或延迟确认期间取消，核对服务器已变、客户端仍保留草稿且禁止第二次 COMMIT。确认丢失是连接边界故障注入，不是物理网络丢包测试。
- 原生 UIHostingController/UICollectionView 验证暂停前后 frame、列宽、实际 contentOffset 和选中项不变，原 100 行仍保留；不新增占高度的提示栏。原 Files picker 源文件寿命、全屏/记录编辑、键盘、分页/筛选/导出/查找/时间显示以及共享 SQL 解析等既有回归仍通过。
- 最初 previewSQL 长表达式编译诊断通过拆分预览数组修复；首次整套手机 259/1/0，失败是独立 UIHostingController 未收到 SwiftUI Scene 的前台环境，导出模型正确拒绝后台生成。原生测试明确设置当前窗口的 active 环境后重测；生产后台 guard 保留。最终结果无新增警告、无错误；失败不计为通过。
- 最终 ARM64 Debug 签名构建 `.build/reliability-device-final.json` 成功，22.346 秒；`codesign --verify --deep --strict` 通过。`.build/reliability-device-list.json` 显示实体手机 disconnected/unavailable，本轮没有安装或声称真机弱网/锁屏验收。
- 两个模拟器恢复到保留的自有 MySQL `edit_rows` 普通网格，安全锁开启，无待提交修改、无自动键盘探针。此轮修改仅编译于移动目标，未改共享业务/传输、Mac 或外部六类驱动，不需要重新打包驱动；六类适用范围及平台限制见 MAC_PARITY。所有临时测试容器及卷由脚本清理，体验用容器保留；未操作用户桌面输入、提交、打 tag 或发布。
- 限制：系统强制终止或用户结束进程后不恢复内存草稿，按用户决定不增加持久恢复/多工作区/SQL 页签。真实弱网、锁屏、系统后台时间授予和硬件触摸仍需真机验收。

## 选区／当前语句执行（2026-10-22，302 项）

- 最终手机 `.build/sql-target-phone-full.json`：302 通过 / 0 失败 / 0 跳过，44.046 秒；iPad `.build/sql-target-ipad-full.json`：302/0/0，49.880 秒。262 项既有回归加 24 项原 Mac 目标/预检测试、10 项移动执行状态测试、2 项原生选区/IME/Cmd-Return、4 项真实 MySQL 测试。
- 实库验证只运行多语句文稿中的当前 SELECT、精确所选前缀，不运行旁边的 DELETE 或谓词；物理字段来源、真实基础表字段注释和查询结果编辑准备来自实际执行 SQL。验证字符串分号、Unicode、NULL、空结果仍保留列；多语句选区不发起任何子集且保留前次结果。编辑草稿/移动光标后刷新仍查询先前实际结果 SQL。
- 原生 UITextView 上故意使模型选区落后，Cmd-Return 仍使用实际 UIKit 选区；全篇文本、选区、当前会话选择保持。标记中文输入期间 toolbar 请求拒绝，Cmd-Return 仅结束组合，不执行查询。未使用用户桌面鼠标或键盘输入。
- 初次缺失 Core import 的编译诊断已修正；初始缓存 parser 不接受相同 revision，导致旧 continuation 测试等待第二请求，已停止该失败运行并改为独立有界解析。第一次 focused 42/2/0 的两个失败来自错误测试假定（选中注释不等于空白；并非所有派生表子查询都能可靠分类）；对照真实 Mac 规则修正，并新增不可靠选区同样拒绝的回归，没有放宽生产解析规则。这些失败不计为通过。
- Mac 主程序 `.build/sql-target-mac-build.json` 完整 Debug 成功，56.001 秒；实际编译 Feature 的 mysql/PG/Doris 当前/选区/UTF-16/分号定位和整文稿批量写策略检查见 `.build/sql-target-mac-check.txt`。Mac 命令行测试首次缺少 SwiftPM 资源查找路径，补上实际构建产物资源目录后通过，App 包内资源无需修复。六个隔离驱动实际 activate/会话工厂检查见 `.build/sql-target-six-drivers.txt`。无外部驱动源码/ABI 变化，不重打包或替换用户 Dev；其余五类没有本轮实库查询。
- ARM64 Debug `.build/sql-target-device-build.json` 成功，17.587 秒，严格深度签名通过。`.build/sql-target-device-list.json` 为 disconnected/unavailable，本轮没有安装到实体手机。真实手机触屏/外接键盘/IME仍不能用模拟器测试冒充验收。
- 两个模拟器已更新并停在自有 MySQL 的三语句示例，当前实际执行第二条查询，安全锁开启，无待提交修改、无自动弹出的键盘；已检查 `.build/ios-validation/sql-target-phone.jpg`、`sql-target-ipad.jpg`。脚本临时容器/卷清理，仅保留原体验容器。未提交、打 tag、发布或操作用户数据库。
- 范围：文稿内单条只读查询，仍为 500 行/4 MiB 预览及 256 KiB 文稿限制；多条批量/多结果、写 SQL、运行整个文稿及格式化等仍未移植，不能声称完整 SQL 执行能力对齐。


## Six MySQL table operations (2026-10-23)

- Final full owned MySQL acceptance: phone `.build/table-actions-phone-acceptance.json` **324 passed / 0 failed / 0 skipped**, 46.238 s; iPad `.build/table-actions-ipad-acceptance.json` **324/0/0**, 57.002 s. Original shared six-action statement/input/capability tests compile on mobile, alongside new service/controller/native integration checks and existing loading/grid/filter/find/export/editor/transaction regressions.
- Real MySQL fixtures distinguish DELETE trigger effects and next ID 43 from TRUNCATE reset to 1; quoted Unicode/backtick/semicolon rename preserves data and drop removes the object. Set auto-increment 700, nonempty reset follows max+1, empty reset starts at 1. Real App navigation follows rename/drop. Missing/view/no-auto/SELECT-only/FK rejection stays server-controlled, without disabling constraints. SQL authorization is rechecked immediately before sending. Actual autocommitted TRUNCATE plus deliberately withheld acknowledgement is classified as unknown and cannot be blindly repeated; this is injected at the real-client boundary, not a physical packet-loss test.
- Native UIKit tests cover right-aligned input, actual Return/Done control-event responder dismissal without executing, server auto value, exact-name confirmation and actual SQL. State tests cover target pending table/query changes, unrelated query drafts, database away/back, background/late success/cancellation, completed-write refresh failure and retained unknown operation across close/reopen. No desktop mouse/keyboard injection.
- Initial native/state failures exposed comment-sensitive identity guarding and an incomplete synthetic Return event; corrected physical selection checks and real submit event pipeline. First full phone was 322/1/0 (keyboard simulation only); subsequent 323/0/0 passed, then a real App-route rename/drop test was added for final 324 acceptance. Initial compiler issues and raw failed reports remain recorded in findings; not counted as passes.
- Mac full `.build/table-actions-mac-build.json` succeeded in 136.968 s. Actual compiled six-driver shared capability/SQL checks `.build/table-actions-mac-check.txt` passed; `.build/table-actions-six-drivers.txt` confirms all six isolated original bundles activated and created sessions. MySQL mobile six actions live-tested; PostgreSQL/Doris existing dialect/capability rules remain; Redis/Elasticsearch/Kafka SQL table operations unsupported. Other five have no new live database writes. No external driver source/ABI change or package/installed Dev replacement.
- ARM64 `.build/table-actions-device-build.json` succeeded in 36.617 s; strict deep codesign verification passed. `.build/table-actions-device-list.json` reports the physical phone disconnected/unavailable; this increment is not installed there. Real device IME/touch/rotation remain outside this acceptance.
- Owned simulator preview uses a separate `querycraft_ios_table_actions` database and a scoped DDL account; existing query/edit demo databases remain. Phone clear/truncate/set-auto and iPad rename/drop/reset-auto native previews are captured as `.build/ios-validation/table-actions-{phone,ipad}-<action>.jpg`; previews neither unlock nor execute. Final normal captures show both simulators on `action_demo`, safety lock on, no pending edits or keyboard. Transient test containers/volumes removed; retained experience intentionally alive.
- Scope: six explicit MySQL base-table commands, independent of the still-read-only arbitrary SQL editor. DELETE/TRUNCATE and DDL cannot be undone by the application; cancellation after sending cannot promise rollback. Unknown outcomes require explicit server verification and acknowledgement; refresh failure after confirmed success never becomes a retryable write. Current server auto value may change due to other clients, and low requested values follow actual MySQL rules. No commit/tag/release or user database writes.


## Physical iPad installation follow-up (2026-10-23)

The paired iPad Pro (iPadOS 26.5) is connected/available after enabling Developer Mode. Initial install failed because the existing embedded provisioning profile did not include this new device. Rebuilt for the named physical iPad with automatic signing and device registration: `.build/ipad-physical-signed-build.json` succeeded in 14.887 s, no diagnostics; strict deep signature verification passed. `.build/ipad-physical-install-final.json` confirms successful installation. `.build/ipad-physical-launch.json` was denied by iPadOS Security, reporting signature/entitlement/profile trust; device-side Developer App trust is still required before launch. No successful physical launch or touch acceptance claimed. No proof environment or test DB credentials supplied to the physical launch.


Physical iPad follow-up: user confirmed Developer App trust. `.build/ipad-physical-launch-trusted.json` now reports SUCCEEDED, PID 661, no diagnostics. Installed current MySQL test app launched with no proof environment or injected connection. Physical touch/layout/database acceptance remains user-driven; no screenshot/UI verification claimed.


Physical iPhone update (2026-10-23): device connected on iOS 27.2; `.build/iphone-physical-install-current.json` and `.build/iphone-physical-launch-current.json` both report SUCCEEDED with no diagnostics. Same current signed build as the physical iPad, launched without proof environment/injected connections. This confirms installation/process launch only; no physical UI/database acceptance claimed.


## Mobile display name (2026-10-23)

Changed the shared iPhone/iPad display name in XcodeGen from QueryCraft MySQL to QueryCraft; app bundle identity and data-container identity retained. Regenerated project, signed ARM64 build passed in 12.624 s with no diagnostics. Built Info.plist display name and bundle ID asserted, strict deep signature passed. Both physical device installs and launches succeeded (`.build/mobile-display-name-{phone,ipad}-{install,launch}.json`). Metadata-only change; no new behavior tests or driver changes, no claim of additional mobile driver support. No uninstall, user-data migration, commit or release.
