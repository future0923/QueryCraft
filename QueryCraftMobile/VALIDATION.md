# iOS / iPadOS 验证记录

## 合并 main 前的提交检查（2026-10-26）

本次提交、合并源码，不发版、不打 tag，不调整 0.1.12/build22。已重新阅读 RELEASE_PROCESS。相对 v0.1.12 的分支累计包含移动端、公共业务逻辑及 MySQL/PostgreSQL/Doris/Redis/Elasticsearch 驱动源码适配；不能将最后一轮 UI 改动无驱动变化误当作整个分支无驱动变化。MariaDBTransport 变更同时涉及 MySQL/Doris。相关本机驱动独立构建、打包、签名、隔离加载与六类工厂验证见本文件各阶段记录；不覆盖用户当前 Dev 安装。Kafka 无移动新增实现，保留桌面兼容范围。Driver API 仍为 5，兼容常量及打包脚本相对发布基线未改变。此次六类驱动均不发布；正式发版须对上述五类受影响驱动重新评估发行身份、最低主程序版本及双架构包验证，不能直接发布本地验收包。MCP/SSH 的 main 并行工作保留其既有提交与独立发布安排。

## 保留原生灰色 Tab 胶囊，移除额外目录底板（2026-10-26）

按用户最后确认的截图，保留单条原生 Tab 的灰色玻璃胶囊背景、选中态和系统材质效果；撤销隐藏目录底部 scroll edge effect 的改动。目录内容延伸至导航后方，SQL/Redis/ES 的目录计数改为列表内滚动内容，搜索使用顶部导航搜索区，不额外添加固定目录状态底板或第二排导航。iPad 常规宽度维持原有标题菜单和分栏导航。AGENTS.md 明确记录“保留灰色玻璃胶囊背景”的边界。

最终验证：物理 iPhone 3/0/0（71.009s，`native-navigation-gray-restored-device.json`）；iPad 模拟器 4/0/0（166.442s，`native-navigation-gray-restored-ipad.json`）。覆盖原生 Tab 唯一性、页签切换、查询草稿保留、列表延伸区域、顶部搜索及键盘，Redis 类型展示/刷新失败/过期响应，以及 iPad 基础背景与分栏。原生搜索控件在页签切换后异步挂载，测试改为有上限地等待 UISearchBar/UISearchTextField，不更改产品搜索行为。真机截图已从 xcresult 导出并检查，灰色玻璃胶囊存在，列表延伸到其背后（`native-navigation-gray-restored-device-attachments/EF6FFF1E-1163-461E-85E9-24315E989436.png`）。历史失败报告保留，没有覆盖为通过。

驱动范围：MySQL/PostgreSQL/Doris 共用 SQL 目录；Redis、Elasticsearch 分别移除目录固定状态区；Kafka 无对应移动入口。此次仅展示与布局，不改驱动协议/数据模型，不据此宣称六类驱动实库全量验证。测试使用内存目录和 Redis 服务替身，无实库测试数据写入。iPad 为模拟器验证，未宣称真机验证。真机沿用原应用标识和数据安装，测试后正常启动记录为 `native-navigation-gray-restored-normal-launch.json`。未提交或发布。

## 移除移动端常驻底部操作面板（2026-10-26）

按用户截图要求，数据迁移及迁移确认、SQL 执行确认、结构 SQL、新建表、表选项、PG 文件导入、Redis 编辑/键操作/命令和 ES 操作表单移除底部固定操作/说明面板。迁移预览、运行记录、保存、已保存任务和交换来源收进右上角操作菜单，确认使用原生导航栏按钮；新建表预览/选项重试与 Redis 读取核实进入导航栏。目录新建表与 Redis 继续扫描也移入操作菜单。说明与状态改为滚动内容，加载指示与三行反馈区域尺寸稳定。安全锁、预览、未知结果核实、确认、禁用与取消条件沿原模型执行。紧凑的分页/计数状态栏和主动查找条保留；Mac 页面未因本轮调整而改变。

| 检查 | 结果 | 证据（`.build/ios-validation/`） |
| --- | --- | --- |
| iPhone 真机布局专项 | 2 成功 / 0 失败 / 0 跳过 | `action-layout-device.json` |
| iPad 模拟器布局专项 | 2 成功 / 0 失败 / 0 跳过 | `action-layout-ipad.json` |
| 真机相关回归 | 新建表 3、SQL 输入 2、Redis 创建成员输入 1 均通过 | `action-layout-device-navigation-group-locator-failure.json` 中对应 6 条 passed；该批新增布局用例曾仅因菜单定位失败，最终专项已通过 |
| iPad 相关回归 | 新建表 3、表选项 3、SQL 输入 2、Redis 创建成员输入 1 均通过 | `action-layout-ipad-navigation-group-locator-failure.json` 中对应 9 条 passed；最终专项已通过 |

新增布局验收将真实 SwiftUI 表单挂载在原生窗口，覆盖 320pt 窄宽、横向尺寸、375pt 分栏大字体与当前设备完整尺寸，断言表单可视区域到达安全区底部、错误反馈不缩小视口、操作保留在导航栏，并检查键盘输入后恢复。自定义尺寸是同一窗口内的布局约束测试；真机运行时窗口保持既有横屏，不将它表述为真机旋转全覆盖。导出的真机与 iPad 附件已目视确认底部没有固定面板；保存在 `action-layout-final-device-attachments/` 与 `action-layout-final-ipad-attachments/`。最初测试只检查 UIView/普通导航按钮，未覆盖 UIKit 的 trailingItemGroups，定位断言失败；按本机 UIKit 公共 API 修正后双端专项通过，失败历史保留。

驱动适用范围：MySQL/PG 共用 SQL 确认与目录操作，PG 另有导入；Doris 迁移仅作来源，目录仍只读；Redis、ES 使用各自编辑/命令表单；Kafka 暂无移动端工作区，本轮无入口可改。数据迁移的对象语义、planner/runner/manager 与 Mac 共用逻辑已核对，未修改驱动协议、公共模型或写入链路。本轮验证使用临时目录和内存 fixture，没有实库写入；临时文件在测试结束清理。iPad 真机未连接，相关结果来自模拟器。iPhone 已安装本轮构建并恢复正常启动；本轮未提交代码。

## MySQL / PostgreSQL 真机验收、基础背景与开关（2026-10-26）

用户授权iPhone真机自动化验收并清理测试数据。沿实际MobileCatalogView、MobileBrowserModel、MobileWorkspaceView、MobileSQLEditor、MobileTableFilterEditor、MobileCellEditView和MobileTableChanges链路，使用原生UIKit输入/集合回调与实际数据库请求；不操作用户电脑的真实鼠标或键盘。MySQL使用手机已保存连接，密码仅在设备钥匙串读取，不导出。手机无保存的PG连接，使用带独立所有权label的临时PostgreSQL17实例，从真实iPhone连接电脑局域网映射端口；不新增保存连接。

工作期间原工作树被用户归档；从归档快照40f5c5c确认Redis修复和新测试源码完整，恢复到新受管工作树`ios-ipad-validation/QueryCraftPublic`。忽略的构建缓存没有随快照保存，重新从原固定版本/校验值构建原生库。原分支历史、主检出目录现有功能改动均未重置；仅按用户明确要求在主目录和恢复工作树两份AGENTS.md记录背景规范。

本轮外观范围：只将深色基础页面/目录/分栏空白画布改为不透明#000000，不按此要求修改按钮、图标、字体、输入框、选中态、布局和编辑器自定义主题。移动SQL/Redis/ES目录共用MobileAppearance画布规则，显式隐藏系统目录背景并设置导航栏底色，避免elevated灰底。Mac基础分栏/窗口/原生表格/内容画布使用动态NSColor：深色纯黑，浅色回退原生颜色；侧栏背景仅在深色添加，浅色材质不覆盖。控件/字段背景的扩大替换已撤回，按钮和搜索框保留原生层次。移动Switch单独按用户要求使用系统绿色开启色，保留原生形状/尺寸和关闭灰色；局部button样式Toggle不被转换成Switch。

| 最终验证 | 成功/失败/跳过 | 证据（`.build/ios-validation/`） |
| --- | --- | --- |
| 物理iPhone：MySQL/PG实库、原生输入、网格、执行/IME、背景和开关 | 12/0/0，64.092s | `sql-physical-acceptance.json` |
| 物理iPhone：独立MySQL清理核验 | 1/0/0，13.891s | `sql-physical-independent-cleanup.json` |
| iPad模拟器：实际分栏、开关、SQL工作区、Redis/ES原生展示和执行/IME | 7/0/0，145.114s | `canvas-switch-ipad.json` |
| 最终合成组字测试边界增量：iPad模拟器 | 2/0/0，55.814s | `sql-ime-final-ipad.json` |
| Mac原生动态颜色/侧栏与主内容离屏像素/分栏状态 | 6/0/0，315.768s | `mac-canvas-tests.json` |

真机每个驱动覆盖原生搜索ad/amu（共用Mac模糊匹配）、真实目录与主键/分页、刷新保留当前结果、筛选输入不误删/焦点行删除后迟到回调不改其他行、筛选命中/空结果/清除、SQL原生输入与执行、别名的真实字段来源、大整数主键9007199254740993、NULL/空串区分、查询结果与表数据两条单元格编辑路径、安全锁阻止提交、解锁提交后独立查询读回，以及查询错误后修正重试。表名只使用本轮UUID，创建时设置所有权注释；清理前读回注释匹配才DROP，并验证information_schema/pg_class记录为空。两条成功清理回执已从xcresult导出检查于`sql-physical-final-attachments/`，MySQL额外独立核验回执在`sql-physical-final-cleanup-attachments/`。临时PG容器在finally核对label后销毁，每次失败同样清理。

外观验证在真实展开的UISplitViewController中检查SQL/Redis/ES侧栏像素，覆盖深→浅→深；标准色深截图确认黑色RGB均为0。Switch检查实际UISwitch的系统绿色RGBA、开启/关闭、同等原生尺寸，button Toggle仍非Switch，并检查最终截图。Mac验证动态颜色在深色/高对比深色为RGB0、alpha1，浅色与原生色相同，以及实际分栏侧栏与主内容离屏像素；不将隐藏检查器的零尺寸离屏图当作通过。

SQL组字行为追踪到Mac的WorkspaceQueryEditorCommandCoordinator：commandReturn与commandShiftReturn在hasMarkedText时直接消费按键，不结束组字。iOS原先主动unmarkText，现两条执行快捷键同样在markedTextRange非空时直接返回。合成组字回归在命令同步执行边界核对正文、绑定和标记均未变化，并在异步等待后确认没有SQL发出。真机第三方输入法可在后续IPC回写中替换通过UITextInput合成的组字；早期用例将这种延迟替换误当作快捷键同步结果，相关阶段文本附件保留于`sql-ime-guarded-attachments/`。最终没有替换生产键盘，也没有通过关闭输入法或强行恢复字符串掩盖平台回写；不把合成组字验证冒称真实候选词/完整第三方输入法兼容验收。

失败证据保留：首轮新增测试的函数引用与PG结果桥接类型编译错误（尚未执行写入）；截图HDR16位字节误按8位与绿色CGColor色彩空间标签比较，均改为标准截图/真实RGBA核对；首次PG初始化出现一次InvalidTransition，未定位为驱动协议缺陷、未宣称已修复，后续多轮同链路通过；iPad先使用了与本机不匹配的arm64原生库，补齐x86_64后通过；Mac离屏隐藏检查器无尺寸，最终只验证真实展开的侧栏和主内容。最终物理iPhone12项、独立清理、iPad最终增量和Mac6项均无测试失败；既有历史失败报告没有覆写成通过。

最新签名App严格深度codesign验证通过，无测试环境正常启动PID14758（`sql-physical-normal-launch.json`），沿用原应用标识和数据。iPad物理设备仍离线，仅模拟器验证；Mac已编译测试主功能模块，未覆盖用户正在运行的Mac应用。真实手指手势、外接键盘全矩阵、候选词输入法、多版本/TLS组合及弱网/后台完整验收不在本轮完成声明内。

六类范围：MySQL/PG真机实库；Doris共用SQL目录背景和执行输入保护，但本轮未重测Doris实库；Redis/ES移动目录与Mac公共原生表格/侧栏按同一背景规则，未据此宣称其业务全量复测；Kafka仅Mac现有入口适用，移动仍未移植。无外置驱动实现/协议、Driver API5和发行身份变化，不需要重打驱动包。本轮未手动提交、推送、打tag或发布。

## Redis Hash 输入崩溃、真机验收与左右布局（2026-10-26）

用户报告在新建Hash中输入字段/值即闪退。读取本机连接iPhone的本App崩溃报告 `redis-hash-physical-crash.ips`：主线程SIGABRT，`_swift_reportExclusivityConflict` / `swift_beginAccess`，调用链为Form行primary action → 删除成员 → `removeAll(where:)` → 经Binding再次读取 `MobileRedisKeyAction.rows`。根因是输入框和删除按钮同处Form行，默认按钮样式将删除变成整行操作；删除谓词又读取被修改集合里的行绑定。

修复：行内按钮使用borderless限定点击；删除使用值快照里的稳定ID；新建和编辑集合的输入绑定按ID实时定位，移除后的迟到回调忽略而不落到下一行。泛型行/ID明确Sendable且从MainActor创建，无unchecked或关闭独占访问检查。SQL/ES筛选条件相同的删除谓词/索引绑定风险一起修正。

最终图标基线修正：key/value 与删除、撤销和选择图标采用 firstTextBaseline；图标以同字号内联 Text 呈现，44pt 点击区单独保留，长值仍对齐首行。显式固定行分隔线起点，避免系统根据图标推断出短分隔线。两端相关回归各9/0/0（49.187s/32.718s，`redis-member-baseline-{iphone,ipad}.json`）；最终分隔线增量后的四类型输入专项每端1/0/0（46.398s/30.455s，`redis-member-baseline-final-{iphone,ipad}.json`）。最新真机再次2/0/0、53.538s，无诊断（`redis-member-baseline-final-physical-final.json`），完成真实Hash读写及所有权清理，EXISTS=0文本和截图已导出检查于 `redis-member-baseline-final-physical-attachments/`。无测试环境正常启动PID14498（`redis-member-baseline-final-normal-launch.json`）。本分支AGENTS补充图标首行基线与点击区规范。

按用户左右原则，新建/编辑共用MobileRedisMemberRow：Hash左字段右值、ZSet左成员右分数、List左真实位置右值、Set成员编辑；右侧长值最多四行并保留完整草稿。键名、重命名和TTL用LabeledContent左右布局。默认不显示选择圆圈，批量选择由成员操作显式开启，选择/导出/删除能力保留；删除为44pt点击范围的行尾图标。规则补入本分支AGENTS.md，不修改主检出目录的规范或用户文件。

| 验证阶段 | 结果 | 证据（`.build/ios-validation/`） |
| --- | --- | --- |
| 崩溃修复iPhone/iPad相关回归 | 每端31/0/0，77.089s/52.476s | `redis-hash-input-fixed-{iphone,ipad}.json` |
| 绑定并发约束专项 | 每端10/0/0，63.556s/37.027s | `redis-hash-input-final-{iphone,ipad}.json` |
| 最新左右布局iPhone/iPad回归 | 每端34/0/0，52.489s/84.134s | `redis-member-layout-final-{iphone,ipad}.json` |
| 首次物理iPhone输入/实库验收 | 2/0/0，117.379s | `redis-hash-physical-acceptance.json` |
| 最新左右布局物理iPhone验收 | 2/0/0，85.862s | `redis-member-layout-physical-final.json` |

真机测试在实际App宿主、保存的Redis连接和设备钥匙串下执行，不导出或记录密码。原生UICollectionView表单primary-action回调复现崩溃路径，并经UITextField/UITextView输入，验证新建Hash/List/Set/ZSet不会误删。Hash在用户授权下使用独立UUID键和所有权字段：真实输入→预览/创建→HGET读回→编辑添加字段→再次读回→删除字段→HEXISTS=0。结束时Lua仅删除所有权标记仍匹配的测试键，随后EXISTS=0；异常路径同样清理，并提供同owner的独立清理用例。物理测试必须显式配置授权flag和UUID，常规测试不访问保存连接。

最新真机清理文本与截图位于 `redis-member-layout-physical-attachments/`（从xcresult导出），均已检查。两端新建四类集合截图为 `.build/ios-driver-previews/redis-member-create-*-{iphone,ipad}.png`；原生输入用例还核对key/value控件横向位置。真机无测试环境正常启动成功，`redis-member-layout-physical-normal-launch.json`，PID14408；严格深度签名通过，沿用原App标识和数据。UIKit回调/输入是设备内程序化验证，没有移动用户桌面鼠标或注入桌面键盘事件；不冒充完整手指手势/第三方输入法矩阵。iPad物理设备离线，仅其模拟器验证通过。

初始新回归中的枚举名拼写导致编译失败，布局初验中旧TTL控件定位断言失效，均保留失败报告并修正后重跑。初次device test使用CoreDevice UUID无法匹配Xcode目标（`redis-hash-physical-destination-failure.json`），改用Xcode列出的真实UDID才执行成功；不将零用例失败计为真机验收。最新真机仅余既有测试weak变量/多余await提示，无错误；首次泛型绑定产生的Sendable提示已通过约束消除。

驱动范围：Redis集合新建/编辑与实际配置实库；MySQL/PostgreSQL/Doris共用SQL筛选表单的稳定绑定；ES筛选表单同修且既有资源入口回归。未据此宣称五类数据库业务全量或多版本实库复测。Kafka无移动链路，Mac和六类外置驱动协议/实现、Driver API5及发行身份均不变，无需重打外置驱动。本轮未提交、推送、tag或发布。


## 全局移动中性色（2026-10-26）

沿用户认可的Redis目录样式，将 MobileAppearance 放到 MobileLibraryView 所有 presentation 修饰器外侧，覆盖首页、各连接工作区及下层 sheet/dialog。SwiftUI统一tint；零尺寸、不可点击的UIView锚点仅设置所属场景窗口的UIKit默认tint，不影响布局，也不覆盖已有编辑器明确设置的主题/光标。选中背景、补全行和片段占位符使用动态label灰阶；连接编辑侧滑为中性深灰。普通实心按钮显式使用反差文字，危险确认仍显式红色。源代码审查剩余的一处systemBlue仅用于ES请求行的语法强调，用户编辑器主题与系统原生查找内容颜色保持原语义。

- iPhone/iPad相关检查各 **20/0/0**，166.527s/77.507s，`.build/ios-validation/neutral-appearance-{iphone,ipad}.json`。覆盖原生SQL布局/加载保留、公共网格/全屏、补全/片段导航、字体/主题/IME、Redis类型与刷新、ES资源入口、原生文件导出弹窗。独立UIHostingController显式应用与实际App根入口相同的appearance环境；未为单纯颜色常量另写镜像断言。
- 真实App根入口明暗截图 `neutral-home-{iphone,ipad}-{dark,light}.jpg` 已查看；暗色空首页实心按钮为白底黑字，浅色为中性配色，保存连接的卡片/工具栏无蓝色。仅使用内存调试连接库且不连接数据库，截图后两端均移除调试启动环境正常启动成功（`neutral-normal-{iphone,ipad}.json`），临时连接不落用户文件。
- 最新iPhoneOS arm64开发签名构建/覆盖安装/启动成功，`neutral-appearance-physical-iphone.json`，110.370s，PID14212，严格深度签名校验通过。沿用原标识和应用数据，无测试环境传入真机。iPad真机仍离线，未安装；程序化验证不替代物理触控/IME验收。

六类影响：MySQL/PostgreSQL/Doris、Redis和ES移动页面共用根主题与公共网格；Kafka仍无移动链路。仅改移动展示与相应预览环境，不改Mac、驱动协议/实现、Driver API5或发行身份，无需重打外置驱动。本轮没有新增实库业务验收或声称六库协议均复测。未操作用户真实桌面鼠标/键盘，未提交、推送、tag或发布。


## Redis 目录导航与配色（2026-10-26）

按真机反馈移除目录中独占44pt的DB/操作行；标题合并为“连接名 · DB n”，通过原生 toolbarTitleMenu/Picker 选择DB，仍复用 selectScope 的清理、取消和草稿保护。顶部公共刷新保持直接可点击，目录显示/匹配、控制台、新建键归入旁边的原生“更多键操作”菜单。加载时同一按钮切换为停止，不额外挤开工具栏。Redis的按钮、文件夹、选中背景改用随明暗模式变化的中性色，其他驱动主题不变。iPad数据页的显示选项使用滑杆图标，与键操作菜单区分。

- 菜单收敛后 iPhone/iPad 相关专项各 **6/0/0**，56.241s/45.106s，报告 `.build/ios-validation/redis-navigation-final-{iphone,ipad}.json`。覆盖真实资源入口的编辑、新建/重命名及Redis类型、原文/JSON/Hex、刷新失败/迟到响应、选区/滚动，以及原ES资源页面。
- 最终仅Redis结果选项图标区分后，两端原生Redis/ES页面专项各 **2/0/0**，46.184s/36.165s，报告 `redis-navigation-icons-{iphone,ipad}.json`；最新两端截图核对刷新与两个菜单的图标可区分。
- 实际查看 `.build/ios-driver-previews/redis-type-catalog-{dark,light,db1}-{iphone,ipad}.png`，标题DB0/DB1与明暗模式均核对。四按钮并排的初版触发系统溢出，刷新因此被隐藏；该版记录 `redis-navigation-{iphone,ipad}.json` 保留，最终使用固定刷新加更多菜单。浅色预览使用新的UIHostingController，避免跨外观切换时原生搜索控件尚未完成更新的截图。

真机：最新arm64开发签名构建、覆盖安装和启动成功（`redis-navigation-physical-iphone-final.json`，35.707s，PID 14145）；沿用原应用标识和数据，不传入测试夹具环境。iPad当前离线，未安装；原生截图与程序化验证不冒充物理触控/输入法验收。

本轮仅调整移动Redis界面入口；MySQL/PostgreSQL/Doris、Elasticsearch专用工作区及Kafka的协议/数据链路无变化。共享结果选项仅Redis资源页换图标，ES资源页继续单独回归；Mac、Driver API5、应用和六类驱动发行身份不变，无外置驱动实现变更。未使用真实桌面鼠标/键盘，未提交、推送、tag或发布。


## Redis 类型展示修正（2026-10-26）

用户真机反馈 String 被展示为“位置 / 成员、值”两列表格。追踪发现 iPhone/iPad 共用 MobileResourceService/Workspace 的通用网格入口，未使用 Mac 的 String 专用展示。现根据真实 TYPE 分支：String 可换行/选择原文，支持有效文本、完整对象/数组 JSON 和 Hex；仅提供当前内容支持的格式，复用 Mac RedisValueFormatter/RedisValueDisplayFormat，保留大整数、数字词法和原始字节。空 String 显示“空字符串”，二进制显示完整当前段 Hex。List 索引/值、Hash 字段/值、Set 仅成员、ZSet 成员/分数、Stream 实际 entryID/fields；仅 Hash/Set 显示真实 SCAN 提示。属性页及无后续数据的集合不显示分页。

String 复用原 RedisCollectionReader 读取，最多64KiB一段；移动展示收齐 UTF-8 边界，下一段从实际字节结尾继续，完整拼接不丢字节。仅大值显示上一段/下一段，状态展示总字节数及当前段大小，导出明确区分完整值与当前段；并发缩短造成不一致字节数量时保留旧内容报错，不允许空段无限翻页。普通刷新保留内容、文本选区和有效滚动位置，错误复用公共顶部刷新重试；切键清除旧对象内容并拒绝迟到响应。

- 两端 Redis 相关回归各 **52/0/0**，iPhone151.793s、iPad89.467s：`.build/ios-validation/redis-types-{iphone,ipad}.json`。包括原编辑/写保护、分页、搜索、控制台、键操作，以及新增真实 TYPE/UTF-8/二进制读取和原生展示。
- 最终格式选项/滚动选区增量后，两端专项各 **5/0/0**，iPhone43.092s、iPad44.936s：`redis-types-final-{iphone,ipad}.json`。原生 UI 实际挂载并核对无 String 网格、选取/换行、空值、Hex、JSON大整数及1.00、全部集合列、刷新挂起/失败重试/迟到响应及更新长文本后的滚动/选区。一次测试持有格式切换前的旧UITextView导致断言失败，改为重新获取当前视图后通过；失败原始记录保留 `redis-types-final-iphone-initial-failure.json`。
- 查看了两端实际 UIHostingController/UIKit 截图：`.build/ios-driver-previews/redis-type-*.png`。均为程序化挂载，不使用真实桌面鼠标/键盘，不冒充物理触控验收。实库仅本次自有 loopback Redis7.2.4，结束清理。

真机：最新 iPhoneOS arm64 开发签名构建、覆盖安装、启动成功（`redis-types-physical-iphone.json`，63.962s，PID 14108），严格深度签名验证通过；沿用原应用标识，未卸载或清除应用数据。未传入测试入口或夹具凭据。iPad离线，未安装；真实触控、完整IME/外接键盘及服务器/TLS矩阵仍待用户体验与后续验收。

驱动影响：Redis复用既有读取器，不改外置驱动协议/实现；MySQL/PostgreSQL/Doris的SQL结果路径、Elasticsearch专用工作区、Kafka均无业务变更。共享结果页仅收敛 resourcePagination 分支，原ES资源页展示回归通过；Mac共享格式枚举只补iOS条件import，Mac行为不变。Driver API5、应用与驱动发行身份均不变，无需重新打包外置驱动；本轮无提交、推送、tag或发布。


## 剩余工作区整体验收（2026-10-25，完成）

本轮完成 Doris、持久多 SQL 文稿、通用迁移和编辑器设置，以3e2a2df为基线；功能矩阵见 [WORKSPACE_PARITY.md](WORKSPACE_PARITY.md)。属于模拟器交付，Kafka继续排除移动移植。2026-10-25 用户授权将本轮功能和验证记录提交至 `codex/ios-ipad-editor`；不推送、打 tag 或发布。

| 验证 | 最终结果（成功/失败/跳过） | 证据（`.build/ios-validation/`） |
| --- | --- | --- |
| iPad五库完整回归 | 752/0/9，322.023s | `workspace-full-ipad.json` |
| iPhone五库完整回归 | 752/0/9，275.267s | `workspace-full-iphone.json` |
| 最新iPad工作区/编辑器/安全专项 | 80/0/0，69.403s | `workspace-final-ipad.json` |
| 最新iPhone工作区/编辑器/安全专项 | 80/0/0，53.209s | `workspace-final-iphone.json` |
| Mac共享逻辑/主工程测试构建 | 65/0/0，287.794s | `workspace-mac-final.json` |
| 独立Doris驱动回归 | 5/0/0，27.684s | `workspace-doris-tests-final.json` |
| 最新iPhoneOS arm64编译/链接 | 通过，33.001s，unsigned | `workspace-arm64-final.json` |

完整回归使用自有隔离 MySQL8.4、PG17、Doris4.1.3、ES8.18和本地临时Redis。每端9个跳过项中，迁移3个函数、文稿/凭据/切库4个函数及原生迁移入口1项需要另一个专用数据夹具，已在每端80项专项全部执行；另1项是原ES双端口服务器测试（QUERYCRAFT_ES_LIVE_TESTS，19280/19290），本轮未启用。原生ES8.18真实写入/Mapping/REST等既有路径在完整回归执行。两端完整回归各有1条夹具回滚提示 `there is no transaction in progress`，无测试失败；Mac保留既存Keychain废弃、测试及Swift Collections依赖扫描提示。

最终专项包含完整原迁移SQL/runner/library/bulk及实际原生入口。MySQL/PG各1001行长值、NULL/空字符串、原二进制和超2^53主键；Doris迁移源2行，Doris查询另验10k流式缓存/分页/导出。六个迁移方向、COPY/LOCAL INFILE、Upsert/覆盖及取消回滚均实连。文稿保存/重启恢复、损坏保留/备份导出、落盘失败禁止丢弃、历史打开新文稿、独立SQL事务和PG数据库/Schema列表、迟到响应/失败保留/重试、凭据队列和任务草稿均验证。最后补充跨文稿未知写入保护：另一篇文稿仍可读取和回滚，写SQL/提交/结果编辑须先核实。此增量及最终行号/错误栏样式由最新80项覆盖；完整回归保留其实际源码阶段，不将早期失败计为通过。

MySQL、PG、Doris独立构建通过（199.354/20.818/44.441s），分别见 `workspace-driver-*.json`。新本地ad-hoc签名包hash：MySQL `502c895d51974ba5`、PG `894c4daa80fc32e1`、Doris `58451f7d6121bedd`，位于 `.build/ios-support-desktop-drivers/`。真实installer/registry核对六类包签名/API/实际bundle路径和session工厂；新Doris包实连10k多批流、7行上限、注释/SHOW CREATE/真实索引目录通过（`workspace-packaged-load.txt`）。没有覆盖用户Dev安装。Intel包不是双架构发布验收，正式身份/最低host版本门槛见 [pending记录](../docs/releases/pending-ios-ipad-workspace.md)。

两端原生UIHostingController挂载并查看文稿、深色SQL编辑器、主题设置、迁移配置/长错误/底部确认及任务库，截图 `.build/ios-driver-previews/workspace-*.png`。可见行号/当前行/选区不切换TextKit模式；长文稿滚动、高亮、源文/光标保持、原生Tab/Return/IME及主题即时应用验证通过。迁移错误区域预留固定尺寸；确认按钮位于安全区底部。过程中修复了长文稿滚动与PG历史Schema回归，保留原断言重跑。

已确认本机iOS26.3 Simulator缺失 `Fonts/Core/AppleColorEmoji.ttc`，日志明确回退LastResort；原生SQL与普通系统UILabel对照均缺字（`workspace-editor-font-runtime-iphone.png`）。SQL Unicode原文、UTF16选区、字体属性和实库迁移值均通过；未改写系统运行时或用替代字符改SQL，未声称Emoji像素验收通过。

边界：系统查找匹配颜色由UIKit绘制，主题交换仍保留对应值；Mac CodeEdit控件/多光标不复刻。物理设备检查时均离线，未安装；真实触控、完整硬件键盘/IME、真实弱网/系统挂起及更广服务器/TLS/证书矩阵仍待验收。原有协议/权限限制保持。所有自有夹具退出清理；两端最新版无PROOF环境正常启动通过，见 `workspace-normal-*.json`。未操作真实桌面鼠标/键盘或用户数据库。

复现：`python3 scripts/test-ios-driver-support.py <simulator> --full`；`python3 scripts/test-ios-workspace.py <iPad simulator> <iPhone simulator>`。脚本不拉镜像、只使用loopback自有夹具，Doris就绪检查实际tablet分配，finally清理本次资源。

## Redis 整体验收（2026-10-23，当前范围）

本轮按完整 Redis iPhone/iPad 功能链路验收，当前范围以 README / MAC_PARITY 最新节为准；下方逐轮记录保留当时的限制，不代表当前缺失。

- 完整五库移动回归（自有隔离 MySQL 8.4、PostgreSQL 17、Doris 4.1.3、Elasticsearch 8.18、Redis 7.2.4）：iPad **567/0/0**（234.443 s），iPhone **568/0/0**（179.128 s）。报告 `redis-complete-ipad-full.json` / `redis-complete-iphone-full.json` 位于 `.build/ios-validation/`。iPhone 包含最终主网格共享读取器的新增回归；最后 ACL 核实修正在后续最终专项覆盖。两次 SQL 回滚夹具各产生一条 `there is no transaction in progress` 提示，无失败或编译错误。
- 最终 Redis 7.4.2 专项：iPad **50/0/0**（81.139 s），iPhone **50/0/0**（60.427 s），均无警告/错误。报告 `redis-complete-ipad-74.json` / `redis-complete-iphone-74.json`；最终代码包含主网格排序/分页/二进制显示、快速前后台关闭门控和真实 ACL 拒绝核实保护，补齐完整回归后最后修正的路径。
- Mac 真实共享模型/解析/计划/格式化/树/历史/导出回归 **29/0/0**（86.245 s）；Redis 驱动独立实库 **11/0/0**（187.209 s）。报告 `redis-complete-mac-feature.json` / `redis-mac-tests.json`。后者有既存 Keychain 废弃 API 提示，不影响通过；未运行涉及真实 AppKit 鼠标/键盘的桌面窗口测试。
- 最终 iPhoneOS arm64 编译/链接 **通过**（13.098 s，unsigned），`redis-complete-device.json`，无诊断错误；不把编译当作实体设备运行。
- Redis 外置包独立打包/ad-hoc 签名：`redis-driver-1.0.1-x86_64-ad4e7535116eb1cd.zip`。真实 installer/registry 确认六类包各自从隔离 bundle 加载并创建会话；新 Redis 包实连验证 RESP3 分数 CAS、条件创建、保 TTL 重命名、Hash 字段 TTL、List 第二页绝对索引200、共用 Stream 实际ID/有界截断及整键 TTL/删除。记录 `.build/ios-redis-field-desktop-load.txt`；用户 Dev 安装目录未覆盖，Driver API 5 不变，本地包不构成发版。

覆盖场景：五类值增删改、新建/重命名/TTL/删除；超过1,000项集合分页与跨页全键搜索；大小写/变音符号/字面glob/Hash字段和值/ZSet分数与降序/List绝对索引；主数据页与编辑页共用读取器；Stream按真实ID翻页；大于1MiB文本及二进制完整保存/导出、Unicode分段边界、JSON大数字/转义不改原文、超100MiB拒绝、预览外尾字节CAS冲突；二进制只读成员导出和批量删除跳过；命令引号/历史/SELECT/MULTI/EXEC/后台DISCARD、未知回执不重放、立即回前台等待旧连接关闭；ACL拒绝核实保留保护；有界回复/历史保留。加载/取消/迟到回复/失败保留与重试沿门控状态测试核对。

原生 UIHostingController 挂载两端真实入口，检查新建/重命名/编辑/Hash TTL/搜索/分页/控制台/大值与 Stream 整键TTL弹窗；深色目录/弹窗与浅色控制台截图已查看，`.build/ios-driver-previews/redis-*.png`。固定底栏、表格边界、绝对索引及有界 UITextView 均验证；没有移动真实桌面鼠标或模拟键盘。手机紧凑导航和 iPad 分栏实际渲染通过，不声称完成真实手指、键盘遮挡全场景或硬件旋转验证。

边界：TLS、MOVED/ASK集群路由、模块内容与二进制集合编辑沿 Mac 限制；Stream图形页只读，控制台可写。SCAN不是稳定快照，TTL不是版本号，值改回原值无法检出。String编辑上限100MiB，共享Mac规则；触控仅展示约32KiB片段，保存完整值。集合页1,000项/1MiB、目录10,000名称/8MiB、控制台保留预算不是进程/协议内存硬上限。真实设备触控、真实网络断连、系统挂起/杀进程仍未实测；隔离故障注入不冒充弱网。未提交、tag、发布或操作用户数据库。

可复现：`python3 scripts/test-ios-driver-support.py '<UUID>' --full`；`python3 scripts/test-ios-redis-field-ttl.py '<UUID>'`。脚本退出清理本次自有容器/临时数据，保留用户原有夹具。



## Redis 大集合分页编辑（2026-10-23，第八轮）

本轮直接抽取并共用 Mac 的完整 RedisCollectionReader（含游标、原始索引、ZSet 排序和搜索规则），移动端对超过 1,000 成员的 List/Hash/Set/ZSet 自动启用按页编辑。Mac session 缓存同连接的读取器并在连接变化时失效；Driver API 不变。

- Redis 7.4.2：iPad **33/0/0**（38.439 s），iPhone 最终 **33/0/0**（22.098 s）。报告 `.build/ios-validation/redis-page-ipad-74.json` / `redis-page-iphone-74.json`。Redis 7.2.4 最终 iPad **33/0/0**（35.448 s），报告 `redis-page-ipad-72.json`；包含新增的键类型改变时旧游标不能发布不同类型页面的检查。保留以前的完整回归基线，不将其计为本轮完整测试。
- 真实 1,200 项 List/Hash/Set/ZSet：后续页成员改写成功，整键 TTL 保留、DB 隔离；草稿阻止前后翻页，提交后读取当前页，部分页模型和 UI 均禁止整键 TTL/删除。List 第二页原始索引从 200 开始，外部 LPUSH 后原值/长度冲突阻止错误写入。
- 慢请求用 continuation 门控：翻页时保留旧内容，后台取消后迟到响应不能发布新页；失败保持页号、原内容与历史，重试后正常前进。键从 List 改为 Hash 后，旧页刷新失败并保留原草稿，不沿用旧游标展示其他类型结果。
- 两端原生挂载验证第二页实际显示位置/值 200、容器 bounds 保持，截图 `.build/ios-driver-previews/redis-paging-ipad.png` / `redis-paging-iphone.png` 已查看。首轮测试修正了夹具跨库操作后未切回和原生多行输入控件识别问题；失败结果没有计为通过。没有模拟桌面鼠标/键盘。
- 最终 arm64 编译/链接通过（12.476 s），报告 `.build/ios-validation/redis-page-device.json`。桌面 Redis **11/0/0**（21.937 s）及单独编译通过，报告 `redis-page-mac.json`。
- 新外置 Redis 包单独打包/ad-hoc 签名，归档 `redis-driver-1.0.1-x86_64-94f6d9bd5e47e06f.zip`。真实 installer/registry 验证六类包共同加载；加载后的 Redis 包实连检查 Hash 字段 TTL、1,200 项 List 第二页原始索引 200，以及既有条件创建/重命名/分数冲突。记录 `.build/ios-redis-page-desktop-load.txt`，用户 Dev 安装目录未覆盖，未提交/发布。

范围：每页请求 200 项（SCAN COUNT 非硬限制），单页仍限 1,000 项/1 MiB；String 仍为 1 MiB 整值编辑。成员搜索 UI、String 分块编辑、二进制成员修改尚未移植。SCAN 外部变更可引起重复或遗漏，返回上一页会重新读取当前数据，ZSet 改分数可使成员离开本页；不承诺稳定历史快照。其他五类驱动不经过此读取器与编辑页，仅校验桌面加载兼容，未重做其全部实库测试。实体设备触控/弱网/系统挂起待验收。


## Redis Hash 字段 TTL 验证（2026-10-23，第七轮）

本轮增量只涉及 Redis Hash 字段 TTL，移动端与 Mac 共用能力探测/HPTTL 读取器及已有提交计划；在此前 545 项完整回归基线上定向验证 Redis，不把历史完整回归计为本轮新增测试。

- Redis 7.4.2 隔离容器：iPad **29 passed / 0 failed / 0 skipped**（72.769 s）；iPhone **29/0/0**（22.216 s）。报告 `.build/ios-validation/redis-field-<simulator UUID>.json`。覆盖 TTL 设置/移除、无效值拒绝、字段重命名重新计时、仅 HSET 改值清除字段 TTL、保留整键 TTL、DB 隔离，以及原 Redis 值编辑/新建/重命名/安全锁/未知结果/后台状态。
- Redis 7.2.4：iPad 初轮 **28/0/0**（65.682 s）；新增原生能力控件验证后 iPhone **29/0/0**（20.013 s）。不显示字段 TTL 输入，模型也拒绝 TTL 改动。旧版 ACL 专项函数没有发送 7.4 命令，此项不计为旧版实库字段过期支持。
- 7.4 ACL：HPTTL 被拒绝时快照读取失败，不假造永久 TTL；COMMAND 探测被拒绝时标记未知，仍可读取普通字段值，TTL 编辑被阻止。字段已消失的 -2 回复视作快照冲突；错误不会替换已有快照。延续已有取消/迟到读取/后台与回执不明状态测试。
- 原生 UIHostingController 验证 Hash TTL 输入是否随服务器能力出现，iPad/iPhone 7.4 与 iPhone 7.2 降级界面已查看；iPhone 最终原生 UI 单项补验 1/0/0（20.473 s），报告 `.build/ios-validation/redis-field-ui-ECA68ECD-218B-4708-A9DA-94381CBF653F.json`。截图按 `redis-field-ttl-74-*` / `redis-field-ttl-72-*` 区分。没有模拟真实桌面鼠标/键盘。
- arm64 iPhoneOS 编译/链接通过（17.913 s）；报告 `.build/ios-validation/redis-field-device.json`。桌面 Redis 独立编译及 **11/0/0** 回归通过（18.894 s），报告 `.build/ios-validation/redis-field-mac.json`。
- 新 Redis 外置驱动独立打包/ad-hoc 签名，包归档 `redis-driver-1.0.1-x86_64-906e5248fecc370a.zip`。真实 installer/registry 加载全部六类驱动，实连新 Redis 包的分页 Hash 读取，确认返回实际字段 TTL；既有分数冲突、条件创建和重命名也通过。记录 `.build/ios-redis-field-desktop-load.txt`。用户 Dev 安装未覆盖，Driver API 仍为 5，未提交/发布。

可复现：`python3 scripts/test-ios-redis-field-ttl.py '<simulator UUID>'` 使用已有本地 redis:7.4.2 镜像，退出清理自己的容器。其他五类驱动不经过该读取器和字段 TTL 控件，本轮没有改变其数据协议/SQL/结果展示。

限制：TTL 本身没有并发原值断言，字段重命名按已读取时长重新计时；字段修改值沿 Mac/HSET 清除字段 TTL 的语义，UI 已提示。大键仍限 1,000 成员/1 MiB 编辑，尚未提供分页编辑；二进制集合成员只读。实体设备触控、真正弱网和系统挂起仍待验收。


## Redis 新建与重命名验证（2026-10-23，第六轮）

本轮继续在 `codex/ios-ipad-editor` 独立工作区实现 Redis 五类新建与整键重命名。共用 Mac 创建/重命名计划，桌面新建同步改用 WATCH 缺失断言，阻止并发创建覆盖。前面的工作区改动继续保留；未提交、未发布。

- iPad Pro 13-inch (M5) / iOS 26.3，隔离 MySQL 8.4、PostgreSQL 17、Doris 4.1.3、Elasticsearch 8.18.0、Redis：完整回归 **545 passed / 0 failed / 0 skipped**（264.537 s）。报告 `.build/ios-validation/redis-key-ipad-full.json`。覆盖共享结果页、原 SQL 表/查询链路及 Redis 创建/重命名；新增操作不进入其他驱动写入服务。
- 最终 Redis 定向回归（包括超长键名提示与关闭文本自动纠错的最终代码）：iPad **26/0/0**（48.762 s），iPhone 17 Pro / iOS 26.3 **26/0/0**（19.553 s）；报告 `.build/ios-validation/redis-key-ipad.json` / `redis-key-iphone.json`。两端新建弹窗的命令预览与确认截图均已查看。
- Redis 实库：string（含空值）、hash、list、set、zset 新建与 TTL；逻辑库隔离；两个独立客户端并发创建同名键只有一个成功，失败方不覆盖原值；RENAMENX 同名目标拒绝、原二进制值/TTL 保留、源键不存在明确失败、Stream 无需编辑快照即可重命名。
- 状态测试覆盖安全锁、草稿变化使旧确认失效、空名/未变名称/无效 TTL/重复字段/超长键名、Mac List 空白过滤和顺序。故障注入覆盖回执丢失、核实读取失败/重试、后台等待写入结果、迟到读取不能清除待核实状态；读核实不重放，未知结果不自动认定成功。
- 原生资源页程序化挂载：数据库行新建菜单、详情/属性共用编辑菜单及目录重命名入口；草稿期间禁止切库。成功创建选中新键，重命名更新选中项，目录按原 MATCH 重新扫描，不插入不匹配目标；已有值编辑与刷新 frame 验证继续通过。截图 `.build/ios-driver-previews/redis-create-ipad.png` / `redis-create-iphone.png`。没有模拟用户桌面鼠标/键盘。
- Mac 主工程构建成功，11 项共享创建/重命名及草稿测试 **11/0/0**（29.442 s），报告 `.build/ios-validation/redis-key-mac-feature.json`。第一次使用 Feature scheme 不支持 test action，之后一次函数筛选缺少括号空跑；两者均不计为测试通过，最终使用主工程 scheme 的完整函数标识获得 11 项实际结果。
- iPhoneOS arm64 最终编译/链接成功（21.135 s），报告 `.build/ios-validation/redis-key-device-build.json`；未签名或安装实体设备。原六类外置驱动包使用新版 Feature 通过真实 installer/registry 的签名、API、实际 bundle 路径和会话工厂校验；加载后的 Redis 包实连验证条件创建/重复创建拒绝/重命名值与 TTL 保留，以及既有 RESP3 分数冲突检查。记录 `.build/ios-redis-desktop-load.txt`。此次没有修改外置驱动源码，不需重新发布包；用户 Dev 安装目录不变，Driver API 仍为 5。

范围：新建内容限 1,000 个成员/1 MiB，键名限 64 KiB；原非 UTF-8 键名禁用身份操作。超限值/Stream 可重命名，尚无 Stream 内容编辑。Hash 字段 TTL、大键分页编辑、二进制集合编辑、任意命令、集群路由和 TLS 仍未移植。TYPE/PTTL 结果是后续观察，不能证明未知回执的操作成功，也不保证外部写入下的原子历史快照。物理设备触控、真正网络断连、系统挂起/杀进程及多版本 Redis 仍需验收。

## Redis 键值编辑（2026-10-23，第五轮）

同一 `codex/ios-ipad-editor` 工作区新增 string 文本/HEX、TTL/PERSIST、整键删除，以及 list/hash/set/zset 成员增删改。直接共享 Mac planner、二进制预览和 WATCH/MULTI/EXEC 客户端；后面的 Redis 只读记录为历史基线。

- iPad Pro 13-inch (M5) / iOS 26.3：隔离五类移动驱动的全量回归 **535 passed / 0 failed / 0 skipped**（176.267 s），报告 `.build/ios-validation/redis-ipad-full.json`，xcresult `test_sim_2026-10-23T11-06-43-159Z_pid25793_f1cd8253.xcresult`。保留 PG 测试的服务端 “there is no transaction in progress” notice，编译/测试无错误。
- iPhone 17 Pro / iOS 26.3：新驱动与原生呈现回归 **63/0/0**（38.061 s），报告 `.build/ios-validation/driver-support-ECA68ECD-218B-4708-A9DA-94381CBF653F-tests.json`。
- 最终调整成员级冲突语义、控制字节预览和编辑后分页历史后，Redis 专项重新验证：iPad **16/0/0**（38.524 s），iPhone **16/0/0**（17.225 s），无诊断。报告 `.build/ios-validation/redis-focused-DFE8BA44-CBD5-4403-BB51-949A1FD64AA6.json` 和 `redis-focused-ECA68ECD-218B-4708-A9DA-94381CBF653F.json`；xcresult 分别为 `test_sim_2026-10-23T11-10-26-437Z_pid28060_0761ba45.xcresult`、`test_sim_2026-10-23T11-11-22-040Z_pid29872_e8f594c0.xcresult`。
- Redis 7.2.4 隔离实库覆盖：原始二进制字符串、KEEPTTL、DB 隔离、TTL/PERSIST、整键删除及原值冲突；Hash 改名/新增/删除、目标已存在拒绝、无关字段变化按 Mac 规则放行；List 重复值的精确位置删除、更新与头尾顺序；Set/ZSet 成员改名/新增/删除与非法分数拒绝；集合二进制成员只读保护、非 UTF-8 键名与替换字符键隔离、编辑超限及键消失。默认安全锁、过期确认、后台确认失效和对象/逻辑库草稿保护均覆盖。
- EXEC 成功后注入回执丢失，确认服务器值已变但 UI 禁止重放；首次核实读取失败仍保持核实状态，再次读取成功才解除。真实 Redis EXEC 中的运行期类型错误验证前一条命令可能已生效；ACL 拒绝 WATCH/HGET 验证绝不继续写入。三个可控异步状态测试覆盖首次失败/成功为空、慢刷新保留内容/旧响应丢弃、后台中的提交完成后必须核实。
- 实际资源页入口挂载原生编辑弹窗，核对 TextEditor 原值、安全锁、确认命令、成功写入和返回后网格 frame。已查看 `.build/ios-driver-previews/redis-edit-ipad.png`、`redis-edit-iphone.png`，命令和确认按钮可见；加载/错误固定在底栏。没有模拟真实桌面鼠标/键盘。
- 最终 arm64 iPhoneOS 编译/链接通过（29.0 s），日志 `/tmp/querycraft-redis-final-device.log`；未签名或安装实体设备。桌面 Redis 驱动 **11/0/0**（26.501 s），包括两个新增的隔离实库 ACL/RESP3 分数回归；原有依赖其他环境的 pipeline 测试未作为此次实库证据。报告 `.build/ios-validation/redis-mac-tests.json`，独立构建通过（31.3 s）。
- 新 Redis 外置驱动独立打包、ad-hoc 签名校验，SHA-256 `bfba3c6a5e4d5024ac92ddd9565539285efcc1fffed18ee0390dd801fe85fda9`。隔离真实 installer/registry 验证六类签名/API/实际 bundle 路径/会话工厂，新 Redis 包实际完成 RESP3 ZSet 更新和旧原值冲突拒绝，记录 `.build/ios-redis-desktop-load.txt`。Driver API 仍为 5；未替换用户正在使用的 Dev 安装目录，未提交或发布。所有本轮自建容器/Redis 进程已清理，原有 `querycraft-ios-schema-experience` 保留。

限制：完整编辑快照限 1,000 个成员/1 MiB；新建/重命名键、Hash 字段 TTL、超限键分页编辑、二进制集合编辑、Stream/模块、任意命令、集群路由和 TLS 尚未移植。值编辑沿 Mac 的成员级断言，独立 TTL/DEL 检查完整已加载基线；没有持久版本号及 TTL 并发断言。故障注入不等同真实弱网；实体设备输入、系统挂起/杀进程及其他 Redis 版本仍待验收。MySQL/PG 原功能在完整回归覆盖，Doris/ES 保持只读，Kafka 无移动入口，仅验证桌面加载兼容。


## PostgreSQL SQL 会话与磁盘缓存（2026-10-23，第四轮）

SQL 控制台现支持 PG 写入/DDL、RETURNING、持续会话、事务与保存点，复用移动 SQL 的确认/安全锁/取消/缓存和 Mac 的分类规则。下方只读、表数据编辑记录是历史阶段，不代表当前能力上限。

- iPad Pro 13-inch (M5) / iOS 26.3：五类可用移动驱动的隔离实库完整回归 **519 passed / 0 failed / 0 skipped**（174.924 s），包含原 MySQL 会话/写入/结构/缓存回归。报告 `.build/ios-validation/postgresql-session-ipad-full.json`；xcresult `test_sim_2026-10-23T10-29-42-968Z_pid72119_6ebd280f.xcresult`。
- iPhone 17 Pro / iOS 26.3：最终新增驱动/PG 会话与原生呈现定向回归 **50 passed / 0 failed / 0 skipped**（30.472 s）。报告 `.build/ios-validation/postgresql-session-iphone.json`；xcresult `test_sim_2026-10-23T10-33-33-309Z_pid77007_15a4752d.xcresult`。
- 实库覆盖锁定时先确认、确认内容过期拒绝、受影响行数、RETURNING 原始大整数/注释、刷新不重放、同连接 pg_backend_pid、事务内可见写入/保存点/提交/回滚、事务中禁止端点和 Schema 切换、事务临时表字段来源、SQL 错误停止后续语句并断开回滚、权限/CHECK 拒绝不误报未知结果、后台关闭未提交事务。模拟真实 COMMIT 成功后回执丢失，确认模型阻止重放，显式核实后只重新读取。
- libpq 分批传输：12,000 行全部落盘、可见窗口 500 行、分页和全部缓存导出不重执行 SQL；Schema/注释/别名/表达式/空结果和事务临时表来源保留。extended query protocol 拒绝一次夹带多条语句；单行超限关闭未读完的连接。取消前通过 pg_stat_activity 确认 pg_sleep 正在执行，保留前条结果、跳过后续语句。用户关闭 standard_conforming_strings 后的含反斜线表名、注释和文本字面量另外实测。
- 原生 MobileWorkspaceView 挂载检查缓存翻页网格 frame 稳定、实际捕获的 PG UPDATE 出现在确认弹窗、安全锁仍开启。已查看 `.build/ios-driver-previews/postgresql-session-ipad.png` 和 `postgresql-session-iphone.png`。未模拟用户桌面鼠标/键盘。
- iPhoneOS arm64 编译/链接通过（32.4 s），没有签名或安装实体设备；桌面 PG 13 项测试全部通过（28.782 s）、独立构建通过（23.0 s）。报告 `.build/ios-validation/postgresql-session-mac.json`。
- PG 外置驱动重新打包/签名并由隔离 installer/registry 实际加载，全部六类驱动签名/API/bundle 路径/会话工厂通过；新 PG 包实连只读元数据和带点物理对象的增删改/整批回滚。记录 `.build/ios-postgres-session-desktop-load.txt`。未覆盖用户的 Dev 安装目录、未修改 Driver API、未提交或发布。

范围与差异：MySQL 与 PG 共用移动 SQL 会话和缓存，MySQL 继续使用 MariaDB 传输；Doris、Redis、ES 仍只读，Kafka 未提供移动入口。PG 图形结构编辑、查询结果单元格编辑、导入/COPY 未移植。错误后主动关闭会话并回滚，不提供在失败事务中继续恢复的操作；物理设备触控/弱网/后台、真实 TLS/证书和多版本服务器仍待验收。中途显示的结果可能尚未解析字段类型/来源，完成后在原连接补齐，不按名称猜测。

## PostgreSQL 表数据编辑验证（2026-10-23，第三轮）

本轮在同一 `codex/ios-ipad-editor` 工作区开放 PG 表数据新增/修改/删除。沿用暂存、安全锁、SQL 预览、撤销与刷新状态，和 macOS 共用 `PostgreSQLDataMutation`；后面的只读记录保留为历史基线。

- iPad Pro 13-inch (M5) / iOS 26.3：隔离 MySQL 8.4、PostgreSQL 17、Doris 4.1.3、Elasticsearch 8.18.0 和 Redis，完整回归 **508 passed / 0 failed / 0 skipped**（172.675 s）。报告 `.build/ios-validation/postgresql-mutation-ipad-full.json`；xcresult `test_sim_2026-10-23T10-11-03-161Z_pid55406_e2ebc51a.xcresult`。
- iPhone 17 Pro / iOS 26.3：最终新驱动、PG 编辑与原生呈现定向回归 **39 passed / 0 failed / 0 skipped**（25.530 s）。报告 `.build/ios-validation/postgresql-mutation-iphone.json`；xcresult `test_sim_2026-10-23T10-15-29-361Z_pid60641_ef255f41.xcresult`。
- PG 实库写入覆盖：原始大整数主键、同名跨 Schema 和带点对象名、引号/反斜线/中文、NULL/DEFAULT、identity 默认新增、生成列限制、bytea 文本往返、无主键更新/删除保护、视图禁写、NUL 文本拒绝、只读账号拒绝、字段快照不匹配、目标行消失。CHECK 失败会回滚此前的删除并保留草稿，修正后可显式重提。
- 故障验证包装真实 libpq 连接：在 UPDATE 已执行后进入后台/取消，确认 ROLLBACK 和原值恢复；COMMIT 已在服务器成功后丢失回执，确认真实数据已变但草稿保留、重复提交被阻止，丢弃后仍需成功刷新。未将故障注入等同于物理设备弱网验收。
- 实际 `MobileApplicationModel` → PG 工作区 → 表编辑状态 → `MobileCellEditView` / `MobilePendingChangesView` 程序化挂载，检查字段值、Schema-qualified SQL 和安全锁；保留既有刷新 frame/列宽验证。截图 `.build/ios-driver-previews/postgresql-edit-ipad.png` 和 `postgresql-edit-iphone.png` 已查看。没有模拟桌面鼠标或键盘。
- arm64 iPhoneOS 应用编译/链接成功（50.0 s），未签名、未安装实体设备。桌面 PG 编译成功（26.5 s）、现有 13 项测试全部通过（21.936 s）；报告 `.build/ios-validation/postgresql-mutation-mac.json`。
- 新 PG 外置驱动独立重新打包、ad-hoc 签名校验，在隔离安装目录由真实 installer/registry 加载。六类驱动的签名/API/实际 bundle 路径/会话工厂全部通过；新 PG 包实连只读账号检查原元数据链路，并以写账号对带点 Schema/表名实际执行新增、修改、删除及重复主键引起的整批回滚。记录 `.build/ios-postgres-mutation-desktop-load.txt`。Driver API 仍为 5，用户安装的 Dev 目录未覆盖，未提交/发布。

六类适用范围：MySQL 原写入、结构编辑、查询结果编辑、SQL 会话在完整回归中覆盖；PG 新增表数据写入，SQL 查询结果仍只读；Doris、Redis、Elasticsearch 保持原只读范围且同次实连回归；Kafka 无移动入口，桌面加载兼容通过。PG SQL 控制台写入、跨执行事务、结构编辑、导入和磁盘缓存未移植。主键定位沿 Mac 规则，不提供旧字段值乐观冲突检查；真实 PG TLS/证书、多版本服务器及物理设备触控/弱网仍待验收。

## PostgreSQL 只读验证（2026-10-23，第二轮）

在 `codex/ios-ipad-editor` 的同一独立工作区接入第五类移动驱动。后面的第一轮和 MySQL 记录是历史基线，当前能力范围见 README / MAC_PARITY.md。

- iPad Pro 13-inch (M5) / iOS 26.3：隔离 MySQL 8.4、PostgreSQL 17、Doris 4.1.3、Elasticsearch 8.18.0 和 Redis 夹具，同一次完整回归 **495 passed / 0 failed / 0 skipped**（287.467 s）。报告 `.build/ios-validation/postgresql-ipad-full.json`；xcresult `test_sim_2026-10-23T09-36-59-314Z_pid71685_096a0d9b.xcresult`。
- iPad 最终补验：同一四类新增驱动实库/状态/呈现套件 **27 passed / 0 failed / 0 skipped**（42.330 s），包括完整回归后新增的查询入口/历史恢复及 Schema 数量修正；报告 `.build/ios-validation/driver-support-DFE8BA44-CBD5-4403-BB51-949A1FD64AA6-tests.json`。
- iPhone 17 Pro / iOS 26.3：最终新驱动、PG 原生呈现和查询历史等套件 **27 passed / 0 failed / 0 skipped**（42.550 s）。报告 `.build/ios-validation/driver-support-ECA68ECD-218B-4708-A9DA-94381CBF653F-tests.json`；xcresult `test_sim_2026-10-23T09-43-02-927Z_pid87985_7da31f9d.xcresult`。
- 最终传输补验：截断后补读元数据的连接同样支持取消，并设置 UTF-8/30 秒查询超时。iPad **10/0/0**（42.021 s）、iPhone **10/0/0**（17.036 s），`.build/ios-validation/postgresql-final-ipad.json` / `postgresql-final-iphone.json`；对应桌面 PostgreSQL **13/0/0**（34.4 s）、驱动构建（14.2 s）与 arm64 应用构建（23.0 s）通过。
- PostgreSQL 真实只读账号：库/Schema/完整目录与共享模糊搜索，public/audit 同名表独立来源、普通视图与物化视图、SELECT 权限用户的主键、注释、分页和中文筛选；别名/关联/表达式/空结果、带点 Schema/表名、search_path 和查询历史恢复；百万行查询只保留指定前缀，单行字节预算、bytea/NULL/空文本。取消前通过 pg_stat_activity 确认 pg_sleep 已在服务端运行，取消在 3 秒内返回，随后查询成功；拒绝 DELETE 和混入事务的批量 SQL。
- 真正的 `MobileApplicationModel` → PostgreSQL executor → 查询结果/历史及实际 `MobileLibraryView` 原生表格均验证；刷新后 frame/列宽/Schema 保持，标题显示 Schema，目录数量按当前 Schema 计算。`.build/ios-driver-previews/postgresql-ipad.png` 与 `postgresql-iphone.png` 用 UIHostingController 在模拟器生成并查看；没有模拟真实桌面鼠标/键盘。
- libpq 18.6 分别从校验后的源码构建 iOS simulator x86_64 和 iphoneos arm64 静态库。arm64 应用构建通过，真机目标未签名，也未安装到物理设备；hiredis 上游 C 源码仍有 size_t 窄化的编译警告。
- macOS PostgreSQL 13 项回归通过；独立驱动编译、重新打包和签名校验通过。真实 DatabaseDriverPackageInstaller / registry 在隔离目录同进程加载全部六类驱动、检查实际 bundle 路径并建立会话工厂；新 PG 包以测试只读账号实际读取主键、注释、物化视图、空查询来源及带点 Schema 的 search_path，记录 `.build/ios-postgres-desktop-load.txt`。其余五类沿用第一轮相同源码/Feature 构建的隔离包，未替换用户的安装目录。Driver API 保持 5，未修改版本或发布。

通用移动配置/预览适配使 MySQL、Doris、PG 保留各自传输和类型/来源；完整回归覆盖原 MySQL 编辑、结构、SQL 会话、磁盘缓存和导出。Redis/ES 专用只读链路继续实连；Kafka 无本轮移动入口。PG 写入、结构编辑、跨执行事务、SQL 磁盘缓存/完整桌面编辑器未移植；bytea 沿桌面文本格式。尚无真实 PG TLS/证书、多版本服务器和物理设备触控/弱网/后台验收，不用模拟器构建代替真机验收。全部夹具使用 loopback 临时账号，脚本结束清理；用户原有测试容器保持。

## 新增驱动验证（2026-10-23，第一轮）

当前分支 `codex/ios-ipad-editor`，工作区 `ios-drivers/QueryCraftPublic`。以下为本轮新证据；后续的 MySQL 首版记录保留作历史基线，新增驱动的当前范围以 README / MAC_PARITY.md 为准。

- **iPad Pro 13-inch (M5) / iOS 26.3**：复用原完整 MySQL 夹具，加本轮 Redis 进程、Elasticsearch 8.18.0、Doris 4.1.3 独立容器，同一次完整测试 **484 passed / 0 failed / 0 skipped**。当次 XcodeBuildMCP xcresult `test_sim_2026-10-23T08-55-05-931Z_pid58554_6233e4e8.xcresult`。
- **iPhone 17 Pro / iOS 26.3**：新驱动、状态与原生资源页面测试 **15 passed / 0 failed / 0 skipped**，包含三类新服务实连；xcresult `test_sim_2026-10-23T09-00-07-230Z_pid79846_af2a3f04.xcresult`。最终补充了“已删除默认库不影响 Doris 元数据”和“Redis DB 1 名称选择正确逻辑库”两项状态回归，见下面的补充验证。
- **最终补充回归**：iPad 新驱动/原生页面套件 **14 passed / 0 failed / 3 skipped**，三项实库在此无夹具复跑中按预期跳过，已在前面的四库全量及 iPhone 实连运行中通过；xcresult `test_sim_2026-10-23T09-07-31-844Z_pid88911_4249cc19.xcresult`。覆盖最后两项默认库/逻辑库修正及全部新增页面状态。
- 新用例覆盖旧 MySQL 连接解码兼容、驱动默认值/Redis TLS 限制、Doris 无事务/编辑入口、Doris 导出方言、非 SQL 拒绝 SQL 导出、服务端身份与索引路径编码、SCAN 非零游标空批次、首次/失败/空/重试、慢刷新保留内容、快速换库/换键、取消/后台与拒绝迟到回复。原生 UIHostingController 检查加载时网格 frame/列宽/100 行内容保持稳定。
- **实库读取**：Doris 数据库/表、字段注释、首/下一页、中文文本筛选、别名/表达式空结果及拒绝 DELETE；Redis 逻辑库、SCAN 与 string/list/hash/set/zset；Elasticsearch 索引/别名、中文文档 `_source`、Mapping 和 10,000 条边界。仅使用隔离夹具，退出后容器和临时 Redis 已清理。
- **macOS 回归**：主程序构建成功；六类驱动分别编译成功。MySQL **47**、Doris **5**、Redis **9**、Elasticsearch **45** 项测试通过，Elasticsearch 的 2 项环境相关实库用例跳过。六类驱动均在 `.build/ios-support-desktop-drivers` 重新打包及 ad-hoc 签名；使用当前 Feature 的真实 `DatabaseDriverPackageInstaller` 验证签名/API、同进程加载、确认 principalClass 所在 bundle 路径并创建全部会话工厂，六项 PASS，记录 `.build/ios-driver-desktop-load.txt`。Driver API 保持 5；没有修改版本号或发布线上驱动，也没有替换用户当前桌面安装目录。
- **原生渲染**：`.build/ios-driver-previews/elasticsearch-ipad.png` 与 `elasticsearch-iphone.png` 已查看，确认宽屏目录分栏、窄屏详情导航、单一顶部刷新及底栏分页。画面数据是测试服务，用于布局；真实 HTTP/数据库读取由独立实库测试断言。没有移动真实鼠标或模拟桌面键盘输入。

重现：`python3 scripts/test-ios-driver-support.py <simulator UUID> --full`。不传 `--full` 仅验证新增驱动及资源页面。两者均记录结构化测试结果；完整模式复用原 MySQL 准备脚本，防止把未配置 MySQL 的集成用例误当成代码回归。

尚未验证：实体设备、arm64 iPhoneOS 原生库构建/签名、远程/VPN、Redis ACL/集群重定向、Elasticsearch Basic/API Key 及四类 TLS 的真实证书服务器、Doris 老版本回退的实库。认证/TLS/路径安全直接使用原桌面实现；本轮仅实连了本机无认证/禁用 TLS 的新驱动夹具。Redis Stream/模块类型、ES PIT 深分页和写入、PG/Kafka 移动驱动仍未移植，不视为完成桌面全功能对齐。

---


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

## Schema editing, appearance and archive recovery (2026-10-23)

- Recovered the original source snapshot `3195231` after accidental worktree archival into the attached `ios-ipad-continue/QueryCraftPublic` worktree; unarchived the original chat. Ignored build outputs were removed by archival, so final evidence below was rebuilt here. The main checkout and its concurrent SSH work were not modified.
- Final full real-MySQL acceptance: phone `.build/continuation-phone-final.json` **343 passed / 0 failed / 0 skipped**, 82.983 s; iPad `.build/continuation-ipad-final.json` **343/0/0**, 133.231 s. Covers shared field/index plans; real rename/type/default/NULL/comment/generated/invisible metadata preservation; index expression/prefix/direction/visibility/unique/comment; add/drop/restore; stale/permission/authorization guards; partial DDL, cancellation between statements and injected lost acknowledgement; view metadata without SHOW VIEW privilege; native right-aligned inputs, Return dismissal, table/list draft and geometry retention. Existing query editing, foreground, grid, SQL completion/selection, filter/find/export regressions remain covered.
- Initial continuation phone was also 343/0/0. Initial iPad was 342/1/0: old SQL completion candidates remained visible while new text parsing/debounce ran. Text/caret-mismatched candidates now clear synchronously; tests assert immediate invalidation. Same-context metadata suggestions and shared matching/ranking rules remain unchanged. Error styling now clears on schema discard/retry and marks confirmed-write reread failure without making the write retryable.
- Test wrappers' optional post-test rendering initially failed because XcodeBuildMCP restored a shutdown simulator. These wrapper exits are not counted as successful render runs. Separate rendering explicitly boots/installs the tested binary. Native XCTest attachments and actual simulator table/list/field/index/dark/light captures are in `.build/ios-validation/native-{phone,ipad}` and `schema-renders/`. The DEBUG index screenshot route initially opened a field sheet before selecting the index section; reordered that fixture setup, rebuilt simulator (35.557 s) and signed ARM64 (20.203 s), and recaptured the actual index sheet. This final fixture-only ordering change does not affect normal launches.
- iPad sidebar resolves the base UIKit surface with current SwiftUI color scheme and contrast, including navigation/footer; black sidebar and detail match, with normal native search and selection materials. Mac sidebar/detail/toolbar use opaque semantic text background. Actual Mac general/appearance/query/data windows captured in both light and dark via independent ScreenCaptureKit window capture without activating the helper or simulating desktop input. The first offscreen `cacheDisplay` attempt was incomplete and is not visual acceptance; valid captures are `settings-renders/` and `.build/continuation-settings-renders.txt`.
- Mac complete build `.build/continuation-mac-build.json` succeeded in 582.420 s. New MySQL driver independently built in 494.541 s, packaged and strictly signed (`continuation-mysql-package.txt`, isolated archive hash prefix `10b5d5247d288c66`). `continuation-mysql-schema-smoke.txt` confirms the actual newly packaged bundle loaded through the Dev driver API/registry, TLS session, real generated/invisible columns and ordered index attributes, and a generated-column edit plan retaining its expression/storage. This also verifies the shared metadata extraction corrects the previous Mac empty generation expression. The smoke helper's initial compile issues (internal initializer/import, selection argument labels, protocol's throwing plan method) were corrected before it ran; none counted as passes.
- Original six installed bundles and a mixed catalog containing the newly packaged MySQL plus original PostgreSQL/Doris/Redis/Elasticsearch/Kafka each activated and created sessions (`continuation-six-drivers-{original,mixed}.txt`). Only the isolated MySQL package was replaced for validation; the user's installed Dev bundles remain intact. PostgreSQL/Doris keep their Mac-specific providers/dialects; Redis/Elasticsearch/Kafka have no SQL field/index editor. Other five drivers had no new live database operations. Mobile remains MySQL only; no new-table/options/foreign-key editor or arbitrary write-SQL expansion.
- Final signed ARM64 product verifies with strict deep codesign and still has display name QueryCraft and the existing bundle identity. Physical installation/launch reports are `.build/continuation-{phone,ipad}-*install*.json` and `*-launch*.json`; see the latest completion entry below. These verify installation and process launch, not physical touch/IME/rotation/database acceptance. Simulator connections use a retained owned local fixture `querycraft-ios-schema-experience`; tests used disposable containers, never user databases. DDL remains independently committed and cannot be rolled back as a batch; uncertain results require explicit server verification rather than replay.


Completion: both final physical installs succeeded (`continuation-phone-install.json`, `continuation-ipad-install-final.json`) and final no-environment launches succeeded (`continuation-phone-launch-final.json`, PID 4206; `continuation-ipad-launch-final.json`, PID 988). No uninstall or injected connection profile. Corrected actual phone/iPad index sheets inspected; both simulator sessions restored to the owned live table schema in dark mode, safety lock on, no pending changes. `git diff --check` passed. Full 343-case suites preceded only the final DEBUG render-fixture ordering correction; normal-source completion/background/schema fixes were included in both final full suites.


## iPad caret-anchored completion (2026-10-23)

Replaced iPad's fixed 44-point keyboard accessory with a reusable, vertically scrolling native candidate overlay anchored to the actual UITextView caret in its own window. Geometry is bounded by the window safe area and editor column, chooses above/below the caret, and avoids docked or floating keyboard frames. Up/down selection scrolls the selected row into view; touch and Return/Tab use the unchanged shared source/selection/IME insertion guards. Escape, blur, dismantling and app deactivation remove the overlay. Outside touches pass through. Phone keeps its existing accessory; Mac shared engine/ranking/catalog and all external drivers are unchanged.

Initial existing editor native tests: 5/0/0. Added real iPad popup lifecycle/last-row scroll/touch-dispatch checks and geometry invariants for portrait, landscape, narrow-window, no/docked/floating keyboard bounds. Final iPad full real-MySQL/native regression: `.build/completion-ipad-full.json`, 345/0/0, 225.858 s, no diagnostics. Phone final result is recorded in completion progress. Actual live SQL editor render `.build/ios-validation/ipad-completion-caret.jpg` shows the three real alias-qualified user fields at the caret with type details, rather than the screen bottom. This render uses simulator hardware-keyboard mode; software/floating keyboard avoidance is covered by geometry injection, not a physical floating-keyboard test.

Signed ARM64 `.build/completion-device-build.json` passed in 33.787 s without diagnostics, strict deep signature passed. Initial physical installation failed when CoreDeviceService could no longer find the iPad; `.build/completion-device-list.json` confirmed both devices disconnected. No successful installation claimed until a later explicit success report. No desktop mouse/keyboard input simulation, no user database changes, no new commit/tag/release.


Completion delivery: final phone full suite `.build/completion-phone-full.json` also 345/0/0, 136.464 s with no diagnostics. User explicitly chose simulator delivery after the device disconnected, so physical installation remains undone for this increment. iPad simulator retains the owned live SQL editor/caret-completion scene for immediate use; actual screenshot inspected. No Mac/driver implementation changed, so their previous validation is unaffected and no new driver package is required.


## iPad software keyboard and touch completion (2026-10-23)

User requested a visible software keyboard and easier candidate placement, then delegated the final choice. A docked full iPad software keyboard now uses a fixed 76-point accessory shelf directly above the keyboard: large 64-point cards show candidate and type/source details and scroll horizontally. The shelf remains stable while candidates refresh or temporarily clear during typing. Hardware keyboards use the caret list; floating keyboards retain the keyboard-avoiding caret geometry. iPhone retains its original 44-point accessory. Shared Mac catalog/matching/ranking/insertion and source/selection/IME guards are unchanged.

Final full iPad `.build/completion-touch-ipad-full.json`: **346 passed / 0 failed / 0 skipped**, 76.273 s, no diagnostics. Final phone focused editor `.build/completion-touch-phone-native.json`: **8/0/0**, 53.038 s, no diagnostics; this is a focused rerun, not a new phone full-suite result. Native tests cover stable shelf height, touch insertion, keyboard-mode transitions, stale candidates, IME, undo and caret/keyboard geometry. An initial injected transition test failed because actual software-keyboard notifications competed with injected hardware frames; notification isolation was corrected before successful native and full reruns.

Simulator hardware-keyboard connection was disabled through preferences and Simulator reopened without desktop mouse/keyboard input simulation. Actual owned live SQL editor capture `.build/ios-validation/ipad-completion-software-shelf.jpg` was inspected: full software keyboard visible, three actual alias-qualified fields with details in the shelf, no candidate list covering SQL. Floating-keyboard geometry is injected test coverage, not physical touch acceptance. iPad retains this live simulator scene. Latest touch shelf is simulator-only per user choice and has not been installed on physical devices; earlier ARM64/install evidence applies to earlier source states. No Mac/external-driver changes, new driver package, user database mutation, commit/tag/release.


Physical iPad follow-up (2026-10-23): user requested another connection attempt after discussing installation without USB. Device discovery now reports the paired iPad connected/available. Latest touch-shelf source was rebuilt, installed and launched successfully with `device build-and-run`: `.build/completion-touch-ipad-wireless-run.json`, SUCCEEDED in 23.069 s, PID 1146, no diagnostics. Strict deep signature verification passed. No injected proof environment or launch arguments. The report confirms build/install/process launch; it does not identify the underlying network/cable transport or establish physical touch/IME acceptance. This supersedes the earlier simulator-only delivery status for the latest touch shelf on iPad; iPhone was not updated in this follow-up.


## Completion acceptance, next context and opaque keyboard shelf (2026-10-23)

Accepted mobile keyword/table/view/column/output tokens now append one space at document end or advance across an existing space/tab, using an opt-in `SQLCompletionApplication.Insertion` plan. Punctuation, identifier suffixes and newlines are not consumed/split; functions, database qualifiers and snippet selections retain their exact shared carets. Desktop's original exact insertion remains the default. The next empty-prefix candidate list comes from the same shared engine and is tied to the resulting text/caret; non-advancing acceptance is dismissed at its new revision, preventing same-word reopening. Late manual requests also respect subsequent Escape. The full keyboard shelf/collection now have opaque semantic surfaces and a top separator in both appearances.

Initial focused iPad native acceptance `.build/completion-chain-native.json`: 13/0/0, 87.802 s. Final full iPad `.build/completion-chain-ipad-full.json`: **351/0/0**, 133.311 s, no diagnostics. Final phone focused `.build/completion-chain-phone-native.json`: **13/0/0**, 92.582 s, no diagnostics. The final chained test dispatches the shelf collection selection callback, then verifies FROM → actual catalog table → WHERE → real column candidates, no old-prefix reopening, exact empty replacement ranges, SELECT next-context candidates and single-step native undo. Additional checks cover manual Escape/late work, function argument caret, punctuation acceptance, existing spaces/tabs, UTF-16 offsets, database/placeholder semantics, light/dark opaque alpha and all existing IME/stale/geometry checks. Phone is a focused rerun, not a new full-suite claim.

Actual full-software-keyboard SQL editor renders were inspected at `.build/ios-validation/ipad-completion-opaque-{dark,light}.jpg`; the solid candidate shelf separates clearly from the background query/result UI in both appearances. No simulated desktop input was used. Simulator restored to dark live owned demo; user databases untouched. MySQL/PG/Doris engines/dialects/ranking and desktop insertion entry are unchanged; Redis/Elasticsearch/Kafka have no SQL completion adapter. Only mobile MySQL opts into token separation; no external drivers were modified or repackaged.

Per the user's standing instruction to update the physical iPad after every mobile change, latest source was rebuilt/signed/installed/launched with no proof environment or launch arguments. `.build/completion-chain-ipad-device-run.json`: SUCCEEDED, 77.086 s, PID 1174, no diagnostics; strict deep signature passed. This confirms installation/process launch, not physical touch/IME acceptance. iPhone was not updated. User-authorized iPad delivery should be attempted each future verified increment without another permission question; report actual connection/install blockers. No commit/tag/release.

## SQL snippets on iPhone and iPad (2026-10-23)

Mobile compiles the actual Mac SQLSnippetStore and SQLSnippetSession alongside the shared template/completion engine. Conditional native view adapters preserve one placeholder/range/navigation state implementation; Mac emphasis rendering stays intact. Mobile adds touch previous/next/finish controls in the existing SQL header, native unfilled/current hints, Tab/Shift-Tab/Escape, and native library/editor CRUD, enable/disable and confirmed default restoration. Trigger validation is shared with Mac settings. The eleven built-ins, matching/ranking and persistence key are identical; custom definitions remain local to each device, without cloud synchronization. Literal template input disables smart punctuation/autocorrection. Existing read-only SQL execution restrictions remain in force.

First focused acceptance: 38 passed / 1 failed. UIKit IME repeats selection/text callbacks while the parser snapshot intentionally stays frozen until unmarking; deriving snippet edits from that frozen snapshot replayed the mutation. A separate last-observed native text now translates each real edit once into the shared session during composition. Navigation stays disabled while marked text is active. Two diagnostic runs isolated the problem before correction; none counted as passes. Final focused `.build/snippet-ipad-focused-final.json`: **39/0/0**, 47.313 s, no diagnostics. Coverage includes original shared template/store/completion tests across MySQL/PG/Doris; UTF-16 insertion, disabled candidate invalidation, native undo, touch navigation, empty stops, backtab wrapping, IME/external replacement, actual representable binding and manager/template rendering.

Final owned real-MySQL/native full regressions: `.build/snippet-ipad-full.json` **380/0/0**, 121.429 s; `.build/snippet-phone-full.json` **380/0/0**, 154.630 s; no diagnostics. Native navigation in both appearances and library/template views were exported to `.build/ios-validation/snippet-{ipad,phone}-final/` and inspected. After these suites, only the existing DEBUG render setup gained a snippet-trigger environment value; normal launches are unchanged. Final fixture-only source rebuilt with `.build/snippet-simulator-final-render-build.json`: **2/0/0**, 53.397 s. Actual live scenes `.build/ios-validation/{ipad,phone}-snippet-live.jpg` inspected: software keyboards visible, real sel snippet candidates ready in both actual SQL editor routes. Simulator.app opened for use. No simulated desktop input or user database mutations. Disposable test containers cleaned by wrappers; owned live demo retained.

Mac complete build `.build/snippet-mac-build.json` passed in 415.825 s. `.build/snippet-mac-tests.json` passed **56/0/0** in 501.720 s: original snippet template/store/completion/session tests, including native CodeEdit selection, edits and emphasis. Existing unrelated deprecation/build/test warnings remain; no errors or test failures. No full-Mac-suite claim or driver repackaging. SQL snippets apply to MySQL/PostgreSQL/Doris; Redis/Elasticsearch/Kafka retain their separate editors. Mobile remains MySQL only; external drivers are unchanged.

Physical delivery audit before simulator override: previous completion fix installed on iPhone (`completion-chain-phone-device-install.json`); launch timed out and retry could not discover it. Snippet ARM64 binary passed strict deep signature verification. Combined `.build/snippet-ipad-device-run.json` labels the result Build failed, but raw diagnostics identify the blocking step as launch denied because the iPad was locked, with no compiler errors. Separate `.build/snippet-ipad-device-install.json` explicitly reports SUCCEEDED, no diagnostics. No physical snippet launch/touch success claimed; final DEBUG-only renderer change was not installed there. User then explicitly selected simulator delivery; physical retries/unlock waiting stopped. No new commit/tag/release.

## Functional commit audit (2026-10-23)

Read root AGENTS.md and docs/RELEASE_PROCESS.md before the user-requested commit. Save the recovered worktree changes on branch `codex/ios-ipad-editor`, based on archive snapshot `3195231`; preserve that snapshot/history. This is a local functional commit, not a version/release commit. Source and test changes are covered by the final mobile 380/0/0 suites, Mac build and snippet 56/0/0, plus the final DEBUG-only presentation 2/0/0. No new executable source changes were made during commit preparation.

Checked the actual last local release tag `v0.1.12`, Config/Shared.xcconfig, Swift Driver API, packaging constant and all six manifest templates. Main version remains 0.1.12/build 22; Swift/packaging API both remain 5 and every manifest receives the same packaging API placeholder. This commit changes no external driver implementation, transport, driver dependencies, packaging, manifest, component identity or protocol. MySQL/PostgreSQL/Doris share the existing completion engine and portable snippet regression coverage; Redis/Elasticsearch/Kafka retain their own editors. Previously recorded original/mixed six-bundle activation/session-factory checks and isolated packaged MySQL/TLS/schema smoke remain evidence for the recovered snapshot, not a new six-live-database claim.

Current commit release decisions: main app, MySQL, PostgreSQL, Doris, Redis, Elasticsearch, Kafka, MCP and Skill are not published or version-bumped; no tag or push is requested. Do not confuse the current diff with the full unpublished branch: relative to v0.1.12, the inherited archive snapshot already contains MySQL/schema and shared MariaDBTransport changes. Any later actual release must therefore reevaluate MySQL and Doris together, validate both architectures and their separate/simultaneous loading and upgrade compatibility, and check the online catalog then. The other four drivers and API/package/manifest identities have no such inherited diff in this branch. No production catalog compatibility or full release readiness is claimed by this functional commit.


## SQL formatting — 2026-10-23

Final owned real-MySQL/native full suites: `.build/ios-validation/mysql-first-DFE8BA44-CBD5-4403-BB51-949A1FD64AA6-tests.json` **404 passed / 0 failed / 0 skipped**, 237.007 s including rebuild; phone `.build/ios-validation/mysql-first-ECA68ECD-218B-4708-A9DA-94381CBF653F-tests.json` **404/0/0**, 76.977 s. Same-source original formatter golden/range/idempotence/recovery tests plus eight native checks cover actual workspace publication, unchanged query status/result identity, UTF-16 selection and untouched neighbor statements, whole-document formatting, one-step native undo, IME preservation, blank-document errors, Mac Cmd-I, away-and-back text/caret changes, cancellation/detach, and unchanged highlight scheduling. Existing SQL snippets/completion, controlled writes/schema, foreground, grid/filter/export and owned MySQL regressions also pass. Initial focused build failed because the resource marker in another test file was private; added a formatter-local bundle marker. Corrected focused run passed 22/0/0 before the final two native checks and input-only revision tracking were added. Initial failure is not counted as acceptance.

Phone/iPad actual MobileWorkspaceView light/dark attachments were exported to `.build/formatting-renders-{phone,ipad}` and inspected. No desktop keyboard/mouse input simulation. Full iPad rebuild reports stale artifact warnings from relocating the initial derived-data directory and pre-existing grammar scanner / unnecessary-await warnings; no errors or test failures. Phone final diagnostics contain no errors or test failures. Disposable MySQL fixtures were cleaned by script traps. A first attempt to reuse the retained demo with its old reader account was denied; it was not a feature/test failure. Restored the existing `querycraft-ios-schema-experience` using its actual table-admin demo route; iPad displays the existing action_demo rows successfully with the new app, no demo data/password changes.

Scope: mobile MySQL SQL text formatting, shared unmodified Mac formatter rules, standard uppercase/four-space options. No SQL execution added, no external drivers or Driver API changed, no additional driver packaging or five-other-driver live validation claimed. MySQL/PostgreSQL/Doris Mac formatting source behavior remains unchanged; Redis/Elasticsearch/Kafka specialized requests do not use this mobile SQL feature. No new physical build/install/touch acceptance; latest simulator-delivery override retained. No commit/tag/release or user database mutation.


## Read-only SQL batches and independent results — 2026-10-23

Final full owned-MySQL/native suites: iPad `.build/ios-validation/mysql-first-DFE8BA44-CBD5-4403-BB51-949A1FD64AA6-tests.json` **420/0/0**, 97.012 s; phone `.build/ios-validation/mysql-first-ECA68ECD-218B-4708-A9DA-94381CBF653F-tests.json` **420/0/0**, 65.441 s. Both final reports contain no compiler errors or test failures. Initial retained single-query checks passed 19/0/0, expanded focused checks 28/0/0. First full iPad was 419/1/0: it caught isLoading remaining true during optional single-result editing-metadata loading. Restored the original separate row-loading/metadata lifecycle before both final full runs. The failed run is not acceptance.

New tests verify exact selected statements and UTF-16 boundaries, whole-document preflight and 20-statement cap, unsafe/transaction rejection before sending any statement, ordered first-error stop, failed/skipped states, selected-result-only retry after editing the draft, prior visible result retention with an explicit previous-result label, truncation and aggregate byte-budget stops, cancellation/endpoint-switch late replies, hidden pending drafts, per-completion history, shared runner cancellation/order, native Cmd-Shift-Return and retained editor/grid frame while switching results. Owned real MySQL verifies identical CONNECTION_ID across statements, actual Unicode/quoted semicolons, real origins/comments on a successful empty result, server failures, 500-row truncation and active SLEEP cancellation. Existing write/schema/filter/export/completion/snippet/formatting regressions pass. No user database mutations.

Actual phone/iPad light/dark result-view attachments exported to `.build/batch-renders-{phone,ipad}` and inspected. `.build/batch-mac-build.json` succeeds in 222.410 s; source extracts only the shared ordered/cancellable loop, retaining desktop connection/policy/results. `.build/batch-mac-regression-final.log` verifies actual compiled framework target/preflight/order/failure/cancellation behavior over the common SQL path used by MySQL/PG/Doris; it is not three live-server tests. The standalone runner initially needed explicit SDK, C module maps and PACKAGE_RESOURCE_BUNDLE_PATH for the Xcode-built framework/resources; those harness failures are not product failures. Redis/ES/Kafka specialized requests and all external driver binaries/API remain unchanged. No new other-five-driver live verification or driver packaging claimed.

Each current batch is read-only, uses one actual MySQL connection/read-only transaction and retains bounded independent results. It does not provide arbitrary SQL writes, transaction controls, disk-spooled results or persistent/multiple SQL workspaces. Preview truncation closes the session and stops the suffix explicitly. Raw-data budgets exclude metadata/runtime overhead and temporarily retained old visible data. Disposable fixture traps clean their owned containers; retained action_demo simulator fixture remains. Latest simulator delivery override retained; no physical installation/touch acceptance, desktop mouse/keyboard simulation, commit/tag/release.


## 新建 MySQL 表 — 2026-10-23

实现从真实 Mac 新表入口追踪至 draft、WorkspaceModel、provider、SQL builder 和独立建表连接。WorkspaceNewTableDraft 原样提取供两端使用；移动新表直接复用公共结构状态／表选项及已有原生字段和索引表单。主程序、Driver API 和外部驱动版本不变，本轮无提交、tag 或发布。

验证证据：

- 初始 iPad 原有结构状态／原生表单回归 11/0/0，59.031 s：`.build/new-table-initial-ipad.json`；新表状态检查 10/0/0，26.833 s：`.build/new-table-state-ipad.json`。
- 完整隔离 MySQL 测试：iPad 438/0/0，116.901 s，`.build/new-table-final-ipad.json`；iPhone 438/0/0，74.242 s，`.build/new-table-final-phone.json`。两份报告均无编译警告、错误或测试失败。
- 新增真实 MySQL 五项：中文／反引号表列索引名、默认值和注释、实际生成值、主键／自增初值、主键和索引前缀／方向、全部表选项提交；重复建表 1050 与只读账户 1142 保持已知失败；末次授权拒绝不发送；实际自动提交 CREATE 后丢弃回执并读回确认存在，关闭重开仍禁止重复；真实 App 创建后清搜索、刷新目录、导航并读取新空表。只操作测试脚本新建的自有临时 MySQL 容器，结束删除容器和卷。
- 新增状态检查覆盖 Mac 共享草稿默认／重置／索引引用／类型语义，保留和丢弃、锁及其他写入、过期预览、选项加载失败／重试／迟到响应、重复点击、后台和上下文变化、已成功但刷新失败与回执不明封锁。原有字段／索引编辑测试随完整套件再次通过。
- macOS 完整构建成功，63.159 s，`.build/new-table-mac-build.json`。实际编译的 QueryCraftFeature.framework 草稿回归通过，`.build/new-table-mac-regression.log`：默认字段、主键约束、重命名索引引用、PostgreSQL schema 限定、完成回调及重置保留选项。不改变 Mac 新表业务逻辑。
- 原生 UIKit/XCTest 渲染导出至 `.build/new-table-renders-ipad` 和 `.build/new-table-renders-phone`；目录底栏、实际原生 sheet、字段／索引／选项、SQL 预览、安全锁与未知结果画面已检查。模拟器截图不作为真机触摸验收。

驱动范围：MySQL 移动新表实库覆盖；PG／Doris 的 Mac 新表能力及方言保持，未移植移动端；Redis／Elasticsearch／Kafka 的专用对象模型和创建入口未改。没有其余五类的本轮实库验证；没有外置驱动源码改动，无需独立重编译／打包或替换用户 Dev。尚未提供已有表选项修改、外键设计、任意写 SQL 或跨启动草稿。继续按用户最新选择仅交付模拟器，未操作物理设备或用户数据库。


补充原生验收：为避开系统分段控件尚未完成的渲染，截图等待稳定后明确检查实际 UISegmentedControl 的选中索引，并滚动到高级选项。首次补充测试 2/1 是定位错误：SwiftUI 的 accessibilityIdentifier 位于包装层，不能据此寻找内部 UITextField；画面实际已正确显示键块大小。改为检查真实原生 placeholder 后，iPad 3/0/0（39.230 s）、iPhone 3/0/0（29.307 s），均无诊断；报告 `.build/new-table-native-final-{ipad,phone}.json`，失败证据保留在 `.build/new-table-native-selector-ipad.json`。最终明暗与高级选项截图在 `.build/new-table-native-renders-{ipad,phone}-final`，均已检查。此轮只完善测试，完整 438 项通过后的应用源码未再修改。

两台模拟器恢复至保留的自有 `querycraft-ios-schema-experience` 测试库，入口在目录底栏「新建表」，默认安全锁开启。没有操作真实桌面鼠标／键盘或安装物理设备。


## 已有 MySQL 表选项 — 2026-10-23

真实 Mac 选项页／绑定／tableOptionsChange／provider／ALTER SQL 路径已追踪。移动结构页已有菜单打开原生暂存表单，十项表选项与字段、索引进入同一结构草稿；新表和已有表共用选项表单，默认值建议及自增标签按用途区分。选项从 Mac 驱动的查询和转换提取进 MySQLTableSchemaMetadata，两端直接共用；SQL builder、Driver API 及共享 transport 未改变。

初始原结构状态／原生表单 11/0/0（70.969 s），`.build/options-initial-ipad.json`；新增选项状态 8/0/0（63.664 s），`.build/options-state-ipad.json`。首次新增测试编译失败来自 WritableKeyPath 参数不满足 Swift Testing 的跨隔离 Sendable 要求；改为参数化字段编号，在测试函数内创建 key path。失败保留 `.build/options-state-keypath-compile.json`，不计为通过。

首轮完整隔离 MySQL iPad 454/0/0（246.013 s），`.build/options-first-ipad.json`。五项新增实库测试覆盖：InnoDB 改为 MyISAM 后数据保持、行格式和注释、实际下一自增值、AVG_ROW_LENGTH／MIN_ROWS／MAX_ROWS／KEY_BLOCK_SIZE 的真实保存及清空；更改默认字符集不转换已有文本列，并发 INSERT 不把原自增值写回；已编辑选项被外部修改时拒绝、ALTER 权限拒绝；实际执行 ALTER 后丢失回执、明确核对后只重新读取；App 侧栏注释、当前路由和数据对象身份同步、待提交选项保护数据编辑。所有写入均在脚本新建的自有临时容器中进行，结束清理容器和卷。

Mac 主程序编译成功（74.154 s），`.build/options-mac-build.json`。MySQL 外置驱动独立编译成功（280.443 s），`.build/options-mysql-build.json`；本地打包和严格签名通过，`.build/options-mysql-package.log`，隔离 ZIP `mysql-driver-1.0.8-x86_64-7d13ca46e7ca9d04.zip`。版本和 build 保留原值，本包仅本地验证，未上传或发布；未声明 ARM64 驱动包已验证。

`.build/options-driver-load.log` 验证新的 MySQL 包通过实际 Dev 的 DatabaseDriverPackageInstaller／签名与 API 检查／registry 激活，从 `.build/options-driver-mixed/MySQL-x86_64.querycraftdriver` 加载，并通过 TLS 连接保留的自有 action_demo 读取真实选项，再检查注释变更计划不夹带自增修改（只预览，不写入保留示例）。原 PostgreSQL、Doris、Redis、Elasticsearch、Kafka 包与新包同时激活，六类 session factory 全部通过。最初独立检查器错误地给 Redis 传 required TLS，触发其真实不支持错误；改为只有 MySQL 使用 TLS／数据库参数后全部通过，初始证据 `.build/options-driver-harness-initial.log`。没有把这个检查器参数错误算作产品故障。

六类范围：MySQL 移动真实表适用；SQL 查询结果不提供表选项，仅沿用结构提交后的元数据失效。PG 明确不支持通用表选项，Doris／Redis／Elasticsearch／Kafka 使用各自能力且未提供此通用编辑器；未新增其移动接入或实库选项写入。共享查询、类型、来源、注释和现有加载规则保持。只验证本机 x86_64 外置驱动；没有替换用户正在使用的 Dev、安装物理设备、提交、tag 或发布。


最终 iPad `.build/options-final-ipad.json` 454/0/0（143.236 s），无警告、错误或失败。首轮通过后补强了原生表单捕获代次和 SQL 预览的 State 归属：父视图重建不更新正在编辑的来源或已展示计划；原生刷新失效测试通过重新构造父视图覆盖这一情况。已有表的引擎／字符集／排序规则也不能清空后制造没有 SQL 的假改动，与 Mac 不提供空选项的入口保持一致。更新后完整套件再次通过。

最终 iPad 原生明暗／高级滚动／失效表单／待提交 SQL 画面导出并检查：`.build/options-final-renders-ipad`。实际模拟器恢复到保留测试库的 action_demo 结构页，`.build/options-restored-ipad.json` 启动成功，`.build/options-restored-ipad-screenshot.jpg` 已检查；安全锁保持开启，没有自动暂存或提交。

限制保持真实：information_schema 返回引擎报告的选项，未报告的数字留空；并发核对是发送前的快照检查，不提供跨外部 DDL 的原子锁。DDL 自动提交及引擎／版本限制由服务器处理；其他五类驱动无本轮实库选项写入。原生程序化截图不代替真机触摸／弱网／旋转验收。


最终 iPhone `.build/options-final-phone.json` 454/0/0（91.979 s），无警告、错误或失败；与最终 iPad 使用相同应用源码，覆盖所有原 SQL／新表／结构／结果／编辑／导出回归。手机原生深浅色、滚动到高级选项、失效状态及同一 SQL 预览截图导出至 `.build/options-final-renders-phone` 并检查。两台模拟器已恢复自有测试库结构页，原有底部菜单可进入表选项，无待提交改动，未操作真实桌面鼠标／键盘。

## SQL 分批磁盘缓存与写 SQL／事务（2026-10-23）

在 `codex/ios-ipad-editor` 的独立 worktree 验证，继续使用模拟器交付；未安装物理设备、替换用户驱动、提交、打 tag 或发版。

- iPad Pro 13 M5／iOS 26.3：完整回归 467 passed / 0 failed / 0 skipped，250.006 s，`.build/sql-session-ipad4.json`；最后新增的刷新保护等 SQL／缓存／原生页面补验 14/0/0，47.599 s，`.build/sql-session-ipad-focused.json`。
- iPhone 17 Pro／iOS 26.3：完整回归 468/0/0，124.070 s，`.build/sql-session-phone.json`。新增一次用例覆盖首次空结果刷新，以及写入失败后旧读取结果仍显示时刷新不得退回执行编辑器。
- 真实自有 MySQL/TLS：100,000 行缓存与完整导出，不截成 500 行；缓存翻页无需再查询；字段类型／来源／别名／NULL／二进制与空结果；超长文本页／导出批次按字节有界；编码载荷预算跨语句共享；释放实际 SQLite／WAL／SHM 后确认文件消失。
- 真实写入：首写安全锁确认、危险语句再次确认、不可变 SQL 失效、权限拒绝、影响行数／插入 ID；跨执行 connection ID、事务内读自己写入、保存点回滚、COMMIT／ROLLBACK、DDL 隐式提交、失败后不执行后续语句、后台断开回滚和连接变更保护。长写取消保留“待核实”防重放栅栏，核对后才解除。
- 原生渲染附件：`.build/sql-cache-renders-ipad-final` 与 `.build/sql-cache-renders-phone-final`，实际缓存下一页、明暗模式、确认页完整 SQL。iPad 同时捕获实际可见窗口，确认等待 sheet 动画结束后 SQL／数据库／警示／执行按钮均可见；未模拟真实鼠标或键盘。
- 手机模拟器停止／重启应用：只在本应用沙盒 Results 中放置自有 `mobile-startup-probe-*` 标记，真实启动清理删除成功，未读写用户连接配置或钥匙串。
- Mac 主程序构建通过，223.873 s，`.build/sql-cache-mac-build.json`。共享缓存／查询文档／只读文件写入校验 41/0/0，312.485 s，`.build/sql-cache-mac-tests2.json`；Mac 原 50,000 行驻留阈值及换页／导出行为保持。
- MySQL 独立构建 94.457 s、Doris 独立构建 39.496 s，分别打包／签名校验通过。新 V4 在真实 Dev installer／registry 的隔离目录激活，新 MySQL 真实读取 999 行返回多个带类型批次；先加载旧 V3 后再加载新 V4，确认实际映像来自新打包的 MySQL bundle。六类驱动 activate／会话工厂全部通过，`.build/sql-cache-driver-load.log`。

范围：移动仍只有 MySQL。Doris 没有本轮实库查询，PostgreSQL／Redis／Elasticsearch／Kafka 没有本轮实库验证；其专用协议与桌面行为没有套用移动 SQL 规则。大结果和活动事务内结果暂不提供单元格编辑；查找只查当前缓存页。二进制保留长度与 128 字节预览，SQL 导出拒绝二进制值。256 MiB 是整批编码缓存载荷，SQLite 页／WAL 另有开销；刷新保留旧快照或导出窗口持有缓存时会暂时并存，释放后删除，下次启动清理残留，不持久恢复工作区。


最终补验：手机 SQL／缓存／原生页面／结构状态 24/0/0（44.315 s，`.build/sql-session-phone-focused.json`）；iPad 新的结构过期响应检查所在状态套件 10/0/0（21.250 s，`.build/sql-cache-ipad-schema-final.json`）。SQL 写入确认后会取消此前尚未完成的结构读取，避免旧回复解除刷新要求；新加闸门用例已覆盖。所有最终结构化报告均无编译或测试诊断。两端实际可见窗口截图均已核对，完整 SQL、库名、提示及确认按钮可见。


## Elasticsearch 完整移动业务链路 — 2026-10-24

在 `codex/ios-ipad-editor` 独立 worktree 完成当前 Mac Elasticsearch 专用业务入口的迁移。直接共用实际 Mac 会话、PIT/search_after、筛选/排序、Mapping/Field Caps、文档编辑/字段暂存/粘贴、索引/设置/Alias/模板 worker、REST 解析/格式化/补全/结果转换。详细范围见 [ES 功能矩阵](ELASTICSEARCH_PARITY.md)。桌面通用多文稿恢复、自定义主题、多光标不在本轮 ES 专用范围；不将模拟器验证冒称真机验收。

### 全量回归与共享源码

- iPad Pro 13 M5 / iOS 26.3：自有 MySQL、PostgreSQL、Doris、Redis、Elasticsearch 五库完整回归 **647 passed / 0 failed / 1 skipped**，295.434 s，`.build/ios-validation/es-final-full-ipad.json`。
- iPhone 17 Pro / iOS 26.3：同一五库完整回归 **647/0/1**，329.766 s，`.build/ios-validation/es-final-full-iphone.json`。
- 上述完整运行后仅补齐 ES 全屏待提交入口、模板名称/索引模式同源搜索及 ES 原生呈现细节；最终两端 ES 专项与 arm64 结果另列于本节末尾。SQL/Redis 共享网格的 ES 参数默认 nil，原有协议实现未改。
- Mac 完整主程序构建成功，211.363 s，`es-mac-build.json`；原 ES 功能测试 **163/0/0**，133.455 s，`es-mac-feature.json`。最后共享调整分别补验 REST/响应诊断 **26/0/0**、字段暂存 **15/0/0**、模板 **12/0/0**，报告 `es-final-mac-console.json`、`es-final-mac-cells.json`、`es-final-mac-templates.json`。后者同时构建最新 Mac 主程序。
- 原 ES 驱动测试 **45/0/2**，175.488 s，`es-mac-driver-tests.json`。跳过的是原测试依赖固定地址的 live 环境；当前自有容器的真实 Mapping、文档与 PIT 用例另行通过。未冒称完成所有 ES 版本或 TLS/认证组合的实库测试。

### 真实协议与稳定状态

所有真实写入只发生于脚本创建、结束销毁的自有临时 Elasticsearch 8.18.0 容器。覆盖超过 10k 的 PIT 顺序分页和独立完整匹配导出（10,250 篇）、原始整数 9007199254740993、真实 index/id/routing、版本/seq_no/primary_term、409 冲突、Mapping 写入、索引创建/删除、设置、Alias 高级选项、模板 CRUD/模拟、Data Stream 与物理 backing index。字段暂存复用 Mac 类型转换和 CAS；后台中断后保留原快照重新校验。批量创建/删除顺序发送，保留已确认部分成功回执，失败停止后续；未知回执不能重复发送。

状态/原生检查覆盖慢首次加载、成功为空与失败分离、刷新保留内容、取消/过期响应、快速对象切换、共享模糊匹配、HTTP/分片失败、后台重建连接、补全与工作区释放、不可变请求预览、默认安全锁、ACL 核实失败继续封锁、诊断 sourceID 防错位、REST 当前/选区/整篇与多结果。统一顶部刷新只派发当前对象/页签或最后读取请求，不重新执行编辑器的新写入。全屏继续使用同一编辑/待提交模型。

16 MiB 是单响应传输预算，32 MiB 是 REST 批次保留响应预算，1 MiB 是文稿/历史条目/可编辑单篇文档预算；并非全进程硬内存上限。超限文档明确只读和预览身份；当前页导出排除未提交草稿；全部匹配数据使用独立会话/PIT，500 行分批并可取消。刷新保留旧快照时会暂时并存。桌面未指定预算的原值保持。

### 外置驱动与六类兼容

ES 驱动独立构建成功，25.244 s，`es-driver-build.json`；隔离本地打包并严格签名通过，包为 `elasticsearch-driver-1.0.1-x86_64-e5a2f9c9fe3030a3.zip`。本轮不变更发行身份、不上传该验证包；正式发版须重新分配身份并完成双架构门槛。

使用最新主程序框架的真实 DatabaseDriverPackageInstaller / registry / session factory 从隔离 `.build/ios-support-desktop-drivers` 加载。报告 `.build/ios-validation/es-packaged-load.txt`、`es-final-packaged-load.log`：MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 六类签名/API/实际 bundle 路径/会话工厂通过；新 ES 包真实 typed PIT 列类型、文档/routing/CAS 和 Mapping 更新通过，验证实际加载新版包而非旧映像。Driver API 保持 5。Kafka 无移动传输新增；本轮只验证桌面包兼容，没有 Kafka 实库功能或移动功能完成的声明。用户正在使用的 Dev 驱动安装未替换。

### 原生呈现、失败修复与边界

实际 UIHostingController / UIKit 原生明暗画面导出到 `.build/ios-driver-previews/es-*-ipad.png` 和 `es-*-iphone.png`，检查工作区、文档/确认、Mapping、设置、Alias、模板/模拟、索引、批量操作、REST 单/多结果与筛选。没有移动真实鼠标或模拟桌面键盘，亦未安装物理设备。

早期真实测试发现并修复两个生命周期问题：关闭后的 URLSession 不能重新 connect；异步补全在所属工作区释放后访问 unowned owner。现在刷新只失效读取上下文，真正关闭时排空取消任务并在前台创建新 actor；异步任务只在执行期间保持 owner。失败运行保留于 progress 记录，未作为通过证据。额外修复后台字段校验持有旧会话的问题，补入真实恢复回归。已有依赖/Keychain 构建警告及 SQL fixture 的 “there is no transaction in progress” 不掩盖为无警告；最终验收不包含任何测试失败。

实体验证仍有明确边界：真实触控、外接键盘/输入法、多版本服务器/TLS/认证、真实弱网和系统挂起/杀进程尚未实测；当前程序化生命周期/HTTP 故障测试不能替代它们。索引设置/Alias/模板的发送前基线复核不是 ES 提供的原子 CAS；索引删除也没有原子 UUID 条件。保留 Mac 的真实协议限制。


最终源码补验：iPhone ES 专项 **79/0/1**（95.607 s，`.build/ios-validation/es-delivery-scoped-iphone.json`）；iPad ES 专项及原共享全屏回归 **83/0/1**（68.644 s，`es-delivery-scoped-ipad.json`）。覆盖最后的全屏待提交入口、同源模板名称/模式搜索、固定高度多结果栏和最新原生页面；两端相同的一个跳过项为依赖专用环境的旧 driver live 测试，真实自有 Mapping/PIT 用例通过。iPad 无编译/测试诊断；iPhone 增量编译有一条测试中 weak 局部变量的无害建议，无错误/失败。最新 arm64 编译 **SUCCEEDED**（32.953 s，`es-delivery-arm64.json`），无诊断，未据此声明真机安装或触控通过。最终新包加载再次通过全部六类工厂及新 ES 真实读取/写入；最新原生模板和全屏截图已检查。


共享网格手机补验 **4/0/0**（16.376 s，`es-delivery-grid-iphone.json`），无诊断；最后 ES 可选 sheet/待提交入口保持原 SQL 全屏选中/列宽/滚动/输入隔离行为。自有临时五库/ES/package-load 容器均已清理，仅保留此前的 `querycraft-ios-schema-experience`。

两台最新版模拟器应用均已按正常环境重启（iPad PID22181 / iPhone PID22180），无启动诊断；保留原连接库。没有提交、推送、tag、发布或真实设备安装。


## PostgreSQL 查询编辑／结构／导入 — 2026-10-24（已完成）

在原分支工作区 `codex/ios-ipad-editor` 继续，保留已完成 ES 改动。直接共用 Mac PG provider/descriptor、查询编辑物理来源/主键规则、新表草稿、表操作、目录转换和文件导入 parser/plan/transaction engine。当前能力范围见 [POSTGRESQL_PARITY.md](POSTGRESQL_PARITY.md)。所有真实写入只针对脚本新建、结束销毁的自有 PostgreSQL17 容器。

已完成证据：

- 初始 PG iPad 专项75/0/0（140.601s），扩展专项78/0/0（137.038s）；均为阶段性证据，最终缓存页身份和零字段表/原生预览身份修正需后续当前源码验收。
- 五库完整 iPad694/0/1（397.236s，`.build/ios-validation/pg-final-full-ipad.json`）。一个跳过为此前 ES 依赖固定环境的旧 live 用例，当前自有 ES 实库测试通过。此运行包含跨页缓存修改/删除/1500行完整导出，晚于它的缓存旧页编辑器守卫/零字段表等由最后专项补验。
- Mac 原共享导入/解析/查询编辑/新表/表操作58/0/0（151.872s，`pg-mac-shared3.json`）；共享缓存/删除呈现/检查器18/0/0（228.411s，`pg-mac-cache.json`），覆盖50000行后磁盘分页、删除压缩和原有检查器。PG 原驱动13/0/0（169.271s，`pg-mac-driver-tests2.json`）。现有 Keychain/依赖编译警告如报告记录；无最终测试错误。
- PG 动态产品独立构建198.502s成功（`pg-driver-build.json`）。测试 scheme 自身构建测试模块，并不会更新 PackageFrameworks 的可分发动态产品；首个包实际加载检查因此发现旧二进制。只有等待动态产品构建完成、重新打包并重测的新包才能作为验收，不能用测试通过替代打包输入核对。

真实协议检查包含：带点号/双引号/Unicode 的 Schema和表名、别名/重复投影/原始大整数主键/表达式/视图/关联/空结果，跨页缓存编辑/删除并保留1500行完整CSV导出，字段/索引/注释/IDENTITY/生成列事务、新表、序列重置/截断保留/重命名/清空/删除，失效结构基线、失败批次回滚、真实已提交但丢失回执与后台取消。文件导入使用完整原值，4MiB以上自动磁盘快照3001行、每行520个Unicode字符，服务器核对完整数量/长度；CSV NULL/空串/大整数/GENERATED ALWAYS identity覆盖与部分批次失败整批回滚。原 LibPQ COPY FROM 在真实事务中写入再回滚，Mac 表文件导入实际是 INSERT 批次，不将通用跨连接迁移工作台冒称为已移植。

原生 UIHostingController/UIKit 测试呈现真实结构页、字段/索引表单、新表/确认、导入选项/映射/滚动确认、查询待提交与表操作；明暗截图保存为 `.build/ios-driver-previews/pg-parity-*-ipad|iphone.png`。不使用真实桌面鼠标或键盘模拟，不代表真机触控通过。

共享缓存删除现在逐个读取 SQLite payload 到临时表压缩位置，保留原行ID/顺序，避免删除一行就物化整份结果。PG缓存页提交后保留同一磁盘结果，异步发布期间阻止换连接/新写入，旧页编辑器身份失效。默认值/计算值不伪造新服务器结果；需要服务器重算时明确刷新。活动SQL事务、未完成缓存、临时表/复杂来源编辑保留明确限制。原数据编辑按主键定位，与Mac一样不提供原字段值CAS；并发修改可能覆盖。

导入异步读取保留旧容器和固定底部加载/错误；文件及选项冻结，选项变化/重读失败不能提交旧快照。所有批次同一事务，COMMIT回执不明保留全工作区写保护，只能明确核对后结束。原导入器无新增人为文件上限，磁盘快照/临时SQLite/运行时和文件解析仍有内存、磁盘开销，不宣称全进程硬内存上限。零字段表支持沿Mac提供的CREATE TABLE()计划，加载需确认对象实际存在。

六类影响：PG外置驱动必须新产品独立构建/签名/真实加载；共享对象只增计算逻辑，不改公开存储布局和API5；MySQL原默认表单、选项、分别提交DDL与导入严格模式保留，五库全量回归核对；Doris仍只读，Redis/ES专用协议不进入PG计划；Kafka只验证现有包兼容，无移动传输新增。正式发行的新PG包需要与新host配套的最低主程序版本和双架构门槛，当前本地包不发布、不覆盖用户Dev。

真实设备触控、外接键盘/IME全矩阵、真实弱网/系统挂起和跨版本PG/TLS/证书尚未实测。通用跨连接迁移、多文稿持久工作区及完整编辑器设置仍是独立范围；未用缩减协议结果或虚构来源替代功能。


最终阶段新增证据：五库完整 iPhone **695/0/1**（299.480s，`.build/ios-validation/pg-final-full-iphone.json`）；iPad 当前源码 PG 专项 **80/0/0**（83.424s，`pg-delivery-ipad.json`），包括旧缓存页编辑器失效、零字段表、稳定文件预览身份、结构 SQL 与所有最后原生确认页。最新 arm64 **SUCCEEDED**（32.122s，`pg-delivery-arm64.json`），无诊断。

新 PG 动态产品构建完成后再次打包/严格签名：`postgresql-driver-1.0.7-x86_64-850f7b8725f6b4f7.zip`。`.build/ios-validation/pg-packaged-load2.log` / `pg-packaged-load.txt` 验证真实 installer/registry 从隔离包加载、六类 bundle 路径/签名/API/会话工厂；新 PG 实际执行含点号/双引号/Unicode 的 Schema 与表、事务建表、原共享字段/主键索引元数据，以及9007199254740993插入/查询/真实来源，全部通过。第一次旧二进制包的失败不计入验收；新包没有覆盖用户 Dev 安装，也没有上传。只验证本机x86_64动态驱动包，不能冒称ARM64驱动包已验证。


最终 iPhone 当前源码专项 **80/0/0**（41.799s，`.build/ios-validation/pg-delivery-iphone.json`），与 iPad 最新80项一致。最后新建表/表操作目标、导入滚动确认、查询待提交、结构 SQL 原生画面已检查，手机完整请求可滚动/选择/分享，默认安全锁保持。没有应用源码改动发生在最后两端80项及arm64通过之后。自有测试容器均已移除，仅保留之前已有的 querycraft-ios-schema-experience。最终文件检查仅含源码/测试/脚本/自有SQL夹具/文档，无构建包或凭据文件进入Git；主 checkout 仅保留原来的 AGENTS/规划修改。未提交、推送、tag、发布或安装物理设备。

两台模拟器已正常启动当前版本：iPad PID97821、iPhone PID97822；启动报告 pg-delivery-launch-ipad.json / pg-delivery-launch-iphone.json 均 SUCCEEDED，无警告或错误。最终交付验证完成。
