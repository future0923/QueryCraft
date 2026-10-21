# QueryCraft 发版流程

每次发版前必须先阅读本文件和仓库根目录的 `AGENTS.md`。发版要同时检查主程序和 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 六类驱动；是否发布驱动由相对上一个正式版本的实际代码和协议变化决定。

## 1. 发布前建立基线

```bash
git switch main
git status --short --branch
git fetch origin --tags
previous_tag="$(git describe --tags --match 'v*' --abbrev=0)"
git diff --name-status "$previous_tag..HEAD"
```

确认工作区没有无关改动，并检查 `Config/Shared.xcconfig` 中唯一的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。版本号、`docs/releases/<版本>.md` 的中英文说明、测试结果和发布决策必须在提交前准备好。

发版判断要以“上一个已发布 tag”到当前提交为范围。特别检查：

- 主程序、共享 Swift 包、编辑器和 UI 是否变化；
- 每个驱动的源代码、专属依赖、打包脚本和 manifest 是否变化；
- `DatabaseDriverCompatibilityValidator.currentDriverAPIVersion`、`scripts/driver-package-common.sh` 和所有驱动 manifest 的 Driver API 是否变化；
- 线上每个架构的驱动目录是否真的已经达到当前主程序要求的 API，而不是只看本地脚本版本。

决策记录必须逐项写明。例如 API 没变化且驱动代码没变时：

```text
主程序：发布
MySQL：不发布，未改动且线上 API 兼容
PostgreSQL：不发布，未改动且线上 API 兼容
Doris：不发布，未改动且线上 API 兼容
Redis：不发布，未改动且线上 API 兼容
Elasticsearch：不发布，未改动且线上 API 兼容
Kafka：不发布，未改动且线上 API 兼容
Driver API：未变化
```

未修改某类驱动的实现、专属依赖、打包逻辑或其适用的共享协议时，**不得增加该驱动的版本号或 build，也不得重新发布该驱动**。仅重新编译/签名主程序、修改 MCP 设置界面或调整主程序版本不构成驱动发布理由。版本号改动本身不能作为“驱动实现有变化”的证据。共享 MariaDBTransport 的变更同时计入 MySQL 和 Doris；Driver API 不兼容变更计入所有驱动。

如果 Driver API 从 4 变为 5，或某个驱动的协议、实现、依赖、打包内容发生变化，就必须发布受影响驱动的 Intel 与 Apple Silicon 包。API 合约变化需要发布全部依赖该合约的驱动，不能只升级当前截图中正在使用的驱动。

MySQL 和 Doris 共用 `QueryCraftDrivers/MariaDBTransport` 动态库。该目录或其打包依赖发生变化时，
两类驱动均视为受影响，必须一起构建、打包并验证单独加载、同时加载和独立升级兼容性。
不得把 transport 改回同包静态 target，否则两个插件会重复注册 Swift/Objective-C 运行时类型。
共享动态库的已有公开 ABI 必须保持兼容；若需破坏性变更，使用新的模块/安装名称并同步评估 Driver API。

## 2. 本地验证

先运行核心测试并通过仓库的 `xcodebuildmcp` 流程编译主程序。共享页面变化要按 `AGENTS.md` 覆盖六类驱动的适用范围、公共模型、表数据页和 SQL 结果页；驱动变化要分别编译、打包并确认 Dev 实际加载了新包。加载中、空结果、失败重试、快速切换和重复刷新也要按规范验证。

### 独立 MCP 与 Skill 发布检查

主程序不得内置 MCP 安装包或 Skill 资源。主程序、MCP、Skill 及六类驱动各自维护版本与发布决定。

- `Components/versions.json` 是 MCP/Skill 独立版本及兼容范围的来源。对应说明为 `docs/releases/mcp/<version>.md`、`docs/releases/skill/<version>.md`，必须包含中文与 English。
- `scripts/component-release-plan.py --require-notes` 相对各组件已发布 tag（首次发布回退至上一个主程序 tag）判断实际改动。MCP 设置界面变化不单独触发 MCP 包发布；Skill 内容变化只触发 Skill。版本号或 build 单独变化不得被当作实现改动。已发布组件发生实现改动时必须提供新的 version/build 身份。
- Actions 自动构建、签名并发布相关组件；未改动组件保持已有发布。手动 `publish_components` 可独立发布变更的 MCP/Skill，支持 `source_run_id` 复用原构建产物。生产环境审批和发布令牌要求与现有资源发布一致。
- 选择 `publish_drivers` 时只允许发布实际变动的驱动；无相关改动或仅变动版本号/build 必须失败。共享 MariaDBTransport 涉及 MySQL/Doris，Driver API 不兼容变化涉及全部六类。
- 构建矩阵、服务端部署、发布后清单同步和 GitHub 驱动附件使用同一份实际变更名单。复用旧 run 时，产物目录中残留的其他驱动包不得随之上传；只修改驱动测试也不触发驱动发版。Swift 与打包脚本的 Driver API 常量不一致时必须失败。
- 主程序 `QueryCraftPackage` 不得依赖 MCP SDK、Logging 或 NIO；协议入口、stdio/HTTP 传输只在独立的 `QueryCraftMCPPackage`。需要 MCP 产物时，先构建 `QueryCraft`，再以相同架构、配置和 DerivedData 构建 `querycraft-mcp`，最后运行 `scripts/package-mcp.py`。MCP 必须动态链接同一份 `QueryCraftFeature.framework`，禁止把 Feature 静态复制进可执行文件。
- MCP 分别提供原生 Intel 与 Apple Silicon ZIP；Skill 提供一个资源 ZIP。包内兼容元数据必须与 CI 签名的 `.release.json` 一致。GitHub 组件 tag 为 `mcp-v<version>+<build>` / `skill-v<version>+<build>`，已发布资源不可覆盖，完全相同的重试可幂等通过。
- 运行 `scripts/test-mcp-package.py <MCP.app> --drivers-dir <六类驱动目录>`，逐架构检查签名、完整运行依赖、SQL 资源、stdio/HTTP、凭据助手与六驱动加载。MCP 只引用自己的运行目录，不依赖主程序路径。
- 运行 `scripts/test-mcp-desktop.py <MCP.app> --component-checks --output <隔离结果目录>`，验证真实签名目录下载、兼容回退、固定启动入口、独立 CLI 更新、旧会话继续调用、失败保留旧版、显式回退、旧客户端路径保留及 Skill 本地修改保护。
- `QueryCraftMCPTests`（握手、初始化兼容、JSON/工具 schema 边界）以及共享模块内的 `MCPComponentTests`、`MCPTests`、`MCPSessionTests`、`MCPOptimizationTests` 应通过。设置仍使用原有左右对齐原生布局，加载与状态反馈保持稳定。
- LicenseServer 提供 MCP 管理、Skill 管理、上传草稿/发布/下架/删除草稿、管理员/CSRF、部署令牌和审计。服务端只持有发行公钥；CI 对单个不可变发行记录签名，服务端聚合已发布记录供客户端下载。
- 发布前先部署支持 `/components/` 及对应管理/部署路由的服务端。Nginx 使用新配置，或使用已验证的大包上传兼容入口 `/admin/resources/deploy/drivers?component=mcp|skill`；兼容入口仍走组件鉴权、签名与独立存储。组件包、签名记录及双语说明全部就绪后再发布。核对三处版本：包内、下载清单、GitHub Release。
- 新版入口 `<数据目录>/MCP/bin/querycraft-mcp` 固定不变。原 `<数据目录>/MCP/QueryCraft MCP.app` 保留给旧客户端；更新后在设置中重新添加客户端即可迁移。保留不可变旧版本供已有会话及回退使用，不自动删除运行中的资源。


DMG 仍为双击挂载、拖入 Applications 的标准安装形式。最终镜像使用 ULMO/LZMA（系统支持 10.15+，本项目最低 15）；先创建完成的临时文件系统镜像，再无损转换为 ULMO，保留原应用签名。发布前应校验镜像、挂载后固定证书、文件摘要、权限和符号链接；不要通过减少图标尺寸或删减驱动能力缩小安装包。

## 3. 提交和创建 tag

先提交功能和测试，再提交版本与发布说明：

```bash
git add <功能文件>
git commit -m "<功能提交说明>"
git add Config/Shared.xcconfig docs/releases/<版本>.md AGENTS.md docs/RELEASE_PROCESS.md
git commit -m "release: QueryCraft <版本>"
git push origin main
git tag -a v<版本> -m "QueryCraft <版本>"
git push origin v<版本>
```

主程序 tag 工作流构建 Intel、Apple Silicon DMG 及各自的 XZ Sparkle 更新包，发布主程序、实际变更的 MCP/Skill 和受影响的驱动；未变更组件保持原版本。tag 不会因为主程序版本变化而自动上传未改动驱动。手动构建保持 `publish_drivers` 显式选择。

## 4. 需要发布驱动时

先完成主程序构建，再用同一个 source run 复用客户端产物。全部驱动因 API 合约升级时：

```bash
gh workflow run release.yml --ref main \
  -f publish=true \
  -f source_run_id=<主程序构建run-id> \
  -f publish_drivers=true \
  -f rebuild_driver=none
```

只改一个驱动时，只构建并上传那个驱动：

```bash
gh workflow run release.yml --ref main \
  -f publish=true \
  -f source_run_id=<主程序构建run-id> \
  -f publish_drivers=true \
  -f rebuild_driver=mysql
```

`rebuild_driver` 选择单个数据库时，发布脚本只上传该数据库的两个架构；其他驱动只做线上兼容性检查，不重新生成版本记录。需要发布全部驱动时使用 `none`，不能用“顺手跑完整矩阵”代替决策。

每个待发布驱动必须检查：数据库类型、版本、build、Driver API、最低主程序版本、架构、压缩包摘要和下载地址一致；Intel 与 Apple Silicon 都成功；Dev 能加载；线上目录 manifest 与压缩包摘要一致。

### 部分构建失败后的恢复

客户端及驱动构建上限为 90 分钟，更新源合并不再重新编译 Universal 主程序；产物上传失败会在同一任务内重试一次，避免为临时网络失败重新编译。

以 `source_run_id` 恢复时，工作流先核对来源 run 已结束、属于本仓库的发布工作流，且源码提交与当前版本 tag 完全一致。按未过期产物清单只构建缺失项；源码仍固定在原 tag，不移动 tag，也不混用 main 后续功能。明确指定 `rebuild_driver` 时才强制重建该驱动。

```bash
gh workflow run release.yml --ref main \
  -f publish=true -f publish_components=true -f publish_drivers=true \
  -f source_run_id=<部分成功的发布run-id> -f rebuild_driver=none
```

独立 MCP 有变化时，即使复用全部构建产物，也必须重新完成两个架构的实际运行目录与六驱动检查。发布前合并来源 run 与恢复 run 的产物，客户端与驱动一并补齐；成功缓存不等于跳过运行验证。

## 5. 发布后验收

```bash
gh run view <run-id> --json status,conclusion,jobs,url
gh release view v<版本>
curl -fsSL https://querycraft.debug-tools.cc/appcast.xml
curl -fsSL https://querycraft.debug-tools.cc/drivers/mysql-arm64.json
```

确认 Actions 的 metadata、主程序、双架构 update 合并、选定驱动任务和 publish 全部成功；确认 GitHub Release、DMG、双架构 tar.xz、驱动/组件 ZIP、appcast 和资源服务下载地址可用；确认未选择的驱动没有新增版本；在 Dev 中确认主程序版本、实际驱动目录和 Driver API。记录 workflow URL、tag、提交、测试结果、已发布驱动和未发布驱动。

如果线上检查发现当前主程序所需 Driver API 尚未覆盖，发版脚本必须失败并停止切换，而不是让不兼容的主程序继续被宣称为完整发布。协议不支持或没有实库条件的验证要明确记录，不能用相似名称或旧 manifest 代替真实结果。

## 主程序更新包体积与架构检查

- 每个原生客户端任务使用同一份签名 Release 应用生成 DMG 与 `QueryCraft-<version>-<architecture>.tar.xz`，并输出 `update-<architecture>.json`（schemaVersion 2、版本/build、最低系统、架构、大小、SHA-256、EdDSA 签名）。主程序和 Feature 二进制必须只有指定架构；上游 Sparkle 保留原签名。
- `scripts/update-archives.py assemble` 只在两架构完整、版本/build/最低系统一致且大小/摘要正确后合并公共 `appcast.xml`。同 build 的 ARM 条目必须在前并声明 `sparkle:hardwareRequirements=arm64`，Intel 条目为后备。不改变现有 SUFeedURL；现有客户端已使用 Sparkle 2.9+，包括 Rosetta 场景。
- 两架构任务均运行 `scripts/test-sparkle-updates.py`，使用实际 Sparkle 解析与选包，测试本机与进程内硬件条件模拟；模拟不替代 ARM 实机运行验收。
- 必须先部署 sibling QueryCraft/LicenseServer 对 `update_format=2` 的支持（可加列迁移保留旧 ZIP 记录），再发布新格式客户端。部署请求必须同时提交两个 XZ、两个签名和两个 DMG；服务端验签、限制展开大小、检查归档路径与原生 CPU，保存同一版本的完整双包后才切换公共更新源。保留旧 ZIP 下载及历史条目。
- 新产物缓存名称以 `-v2` 结尾，不能把旧 ZIP 缓存当成 XZ 产物复用；重建任一架构后必须重新合并更新源。恢复旧 ZIP tag 时使用该 tag 自带的发布工作流，新流程会拒绝不含新格式脚本的旧 tag。
- 发布完成检查两个架构的 canonical URL、大小及签名，不能只检查公共源中的第一个条目。GitHub 附件上传两份 `.tar.xz`，不再上传 Universal ZIP。
- 归档格式不会改变 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 的协议、加载路径或 Driver API。仅此项优化不增加任何驱动或 MCP/Skill 版本；实际待发改动仍按前文独立判断。
