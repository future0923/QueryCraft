# iPhone / iPad 真机验收 — 2026-10-27

Redis完整既有专项的后续补跑见 [Redis专项真机验证](REDIS_PHYSICAL_VALIDATION.md)：7.4全部59条通过；7.2为58条通过、1条字段TTL权限专用检查不适用；跨库测试清理修正后的7.4写入12条复核通过。与本文件的移动端117项存在交集，不直接相加。

设备为“魏崃的 iPad Pro”，iPadOS 26.5，Xcode 目标 UDID `00008112-001969510E08201E`。使用现有配对的 Wi-Fi 开发连接。源码基线为移动端集成分支 `154a646`，在独立受管工作树验证，未改主检出目录中的 MCP 工作。

## 最终真机验收：通过

用户开启本地网络权限、解锁后，在同一台物理 iPad 重跑：**115 成功 / 0 失败 / 0 跳过**（143.651 秒）；随后独立 MySQL/Redis 清理检查 **2/0/0**（9.248 秒）。共 117 项通过，未将首轮通过数重复相加。

五类实库请求全部通过，含 MySQL/PG 原生输入、搜索 ad/amu、SQL、分页/刷新、筛选、表数据和查询结果两条编辑提交/独立读回；Redis 原生 Hash 新建/修改/读回；Doris 流式 10,000 行缓存、分页、完整导出与真实结构；ES 工作区、PIT 超过 10k 分页、编辑/冲突、Mapping/设置/Alias/模板和 REST。同步组字拒绝及异步开始前输入改变的新回归均通过。

服务器侧验证 MySQL/PG 临时表与 Redis 测试键均不存在；五个带所有权标签的临时容器全部销毁。最终导出 80 份附件，已检查 MySQL/PG 原生单元格编辑、Redis Hash 和清理文本。严格深度签名通过；无测试环境的普通 App 启动成功（PID2533），保留原应用标识和数据。

最终证据：`.build/ipad-physical/native-and-five-drivers.json`、`independent-cleanup.json`、`verification.json`、`container-cleanup.json`、`final-attachments/`、`normal-launch.json`。结果包为 `test_device_2026-10-27T00-16-09-473Z_pid76574_f59177e9.xcresult`；日志 `/tmp/querycraft-ipad-physical-resumed.log`。

## 首轮失败与修复历史

- 首轮物理设备运行：**95 成功 / 19 失败 / 0 跳过**，228.067 秒。真实 iPad 编译、开发签名、安装及测试启动成功；不是模拟器结果。
- 通过项目包括实际分栏/基础黑色背景与明暗切换、原生绿色开关、导航与底部 Tab、输入/执行保护、网格刷新/滚动/选中、表单/编辑确认、工作区恢复与相关状态回归。截图已导出，实际 SQL 分栏和原生导航截图已检查。
- 18 项实库或依赖实库的页面检查失败。URLSession 记录 `unsatisfied (Local network prohibited)`；Redis 记录 `No route to host`，SQL 建表前记录 `InvalidTransition idle → failed(deinit)`。这些失败尚不能计为数据库功能通过；需打开 iPad 上 QueryCraft 的本地网络权限后重新核验。
- 另 1 项发现移动端格式化请求在异步任务启动前未检查组字的竞态。已对齐 Mac 同步入口检查：组字中立即拒绝，捕获点击时文本/选区，任务启动前变化则拒绝。原协调器在格式化返回后的修订检查继续保留。新增“任务启动前改文本/选区”回归，并修正组字测试只在同步入口检查合成组字，不将真实输入法之后的 IPC 回写当作产品命令结果。
- 修复后的 ARM64 编译成功（20.826 秒），严格深度签名校验通过；真机专项复验仍待完成。第一次专项因 Xcode 等待设备连接超时而 **0 项执行**；再次尝试的日志明确为 `Unlock 魏崃的iPad Pro to Continue`，不能把安装或编译当作测试通过。

## 隔离与可复现入口

`scripts/test-ipad-physical.py` 创建五类带唯一所有权标签的临时 MySQL8.4、PostgreSQL17、Redis7.4.2、Elasticsearch8.18.0、Doris4.1.3 服务，通过 Mac 局域网随机映射端口供 iPad 连接。测试专用 LAN 地址和 MySQL/Redis 临时配置不会保存到设备连接库；没有导出设备钥匙串凭据。测试数据仅存在于自有服务中。首轮五个服务均已核对标签并删除，清理回执保留。

```sh
python3 scripts/test-ipad-physical.py \
  --device-id '<Xcode iPad UDID>' --host '<Mac LAN IP>' --team-id '<development team>'
```

移动 App 无独立 MCP 服务或 MCP 权限页。MySQL/PG 检查真实 SQL、表/查询结果编辑、安全锁与读回；Redis 检查原生 Hash 输入/写入/读回；ES 使用现有原生协议/工作区实库套件；Doris 检查只读流式缓存、分页/导出与真实结构。Kafka 未有移动端入口，不冒称覆盖。

本轮未卸载 App、清除已有连接、改业务库、替换桌面主程序或外置驱动、调整 Driver API5、提交或发布。所有 UIKit 输入在测试进程内完成，未移动用户桌面鼠标或注入桌面键盘事件。程序化真机测试不替代真实手指、第三方输入法候选词、物理旋转及完整弱网/TLS/后台系统矩阵。

## 证据

工作树 `.build/ipad-physical/` 内：

- `native-and-five-drivers-local-network-denied.json`：首轮结构化报告及 xcresult 路径。
- `container-cleanup-local-network-denied.json`：五个服务完整清理回执。
- `first-native-attachments/`：首轮设备截图和 manifest，包含设备名称与 UDID。
- `formatting-build.json`：修复后的 ARM64 编译。
- `formatting-guard.json`：连接超时、零测试，不计通过。
- `formatting-guard-reconnected.json`：解锁等待后的专项结果，仍需核对实际完成状态。

首次结果包：`~/Library/Developer/XcodeBuildMCP/workspaces/QueryCraftPublic-90b6d13e1a00/result-bundles/test_device_2026-10-26T23-57-38-424Z_pid53203_ad49bfae.xcresult`。日志 `/tmp/querycraft-ipad-physical.log`。

上述继续条件已由用户恢复，后续完整重跑、对象清理和普通启动均成功，最终结果见本页顶部。

专项复验持续停在系统锁屏等待，已仅向本任务的 Xcode 测试进程发送取消信号；需要解锁和本地网络权限后重新执行。未启动写入或结束其他应用。

## 两端 App 图标跟进

用户随后发现 iPhone/iPad 没有 App 图标。确认移动工程未包含资产目录，也未配置 App Icon 名称。新增移动端 AppIcon asset，复用桌面现有 1024px 品牌图；XcodeGen 配置接入 Assets.xcassets 并指定 ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon。生成的实体构建同时含 CFBundleIcons、CFBundleIcons~ipad、120px/152px 图标与 Assets.car；构建成功（22.919秒），无警告/错误。源图与桌面原图字节相同，未重绘品牌图。此资源接入不改变桌面图标、驱动协议或数据库行为。

图标版已分别通过 XcodeBuildMCP 覆盖安装到两台真机，保留同一应用标识和已有数据，严格签名通过。iPad 普通启动 PID2564，iPhone 普通启动 PID18183，均无测试环境或夹具参数。安装/普通启动、图标元数据和编译资源均已验证；没有将测试进程截图表述为 SpringBoard 主屏幕图标目视验收。

- iPad：`.build/ipad-physical/icon-build.json`、`icon-verification.json`、`icon-install.json`、`icon-normal-launch.json`。
- iPhone：`.build/iphone-physical/icon-install.json`、`normal-launch.json`。

## iPhone 补充真机验收：通过

设备为 iPhone 18 Pro Max，iOS27.2，Xcode UDID `00008130-001E65E20A88001C`。同一套五服务/native验收在图标版上 **115/0/0**（208.198秒），独立清理 **2/0/0**（14.503秒）；与 iPad 各117项，不重复累计首轮/失败运行。覆盖同一 SQL/Redis/ES/Doris 实库链路、同步组字拒绝、新的格式化请求快照保护和移动页面/状态回归。

服务器再次验证 MySQL/PG 临时表和 Redis 键不存在；本轮五个带标签容器全部清理。另导出80份iPhone附件，已检查查询单元格、Redis Hash 原生截图和 MySQL/PG 清理文本。最终签名校验通过，图标版明确覆盖安装并恢复正常启动。

历史：首个 iPhone 准备尝试命中了 MySQL 容器的临时 socket 引导服务退出，尚未执行真机用例，所属容器已清理。验收脚本改为等待最终 TCP 监听，PG 同样使用 TCP 就绪检查；新一轮全部通过。Xcode 曾因 iPhone 锁屏等待，用户解锁后在同一次任务内继续完成；未把等待算成测试通过。

证据在 `.build/iphone-physical/`：`native-and-five-drivers.json`、`independent-cleanup.json`、`verification.json`、`container-cleanup.json`、`final-attachments/`；早期准备清理记录为 `container-cleanup-bootstrap-retry.json`。最终结果包 `test_device_2026-10-27T00-31-26-403Z_pid94224_049b997f.xcresult`；日志 `/tmp/querycraft-iphone-physical-final.log`。测试脚本新增 `--output-dir`、`--derived-data-path`，两端报告分别保留，未覆盖 iPad 证据。
