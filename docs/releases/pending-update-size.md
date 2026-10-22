# 更新包瘦身 / Smaller application updates

本文保留实现提交时的测量与范围记录；新格式服务端已于 2026-10-22 部署，客户端发布安排已纳入 [QueryCraft 0.1.12](0.1.12.md)。下文“未发布”等描述指实现提交当时的状态。
This preserves implementation-time measurements and scope. The new server format was deployed on 2026-10-22 and client publication is included in [QueryCraft 0.1.12](0.1.12.md). Statements below about unreleased work describe that earlier implementation checkpoint.

## 中文

- Intel 与 Apple Silicon 分别提供签名 `.tar.xz` 更新包，每台 Mac 只下载适用架构；初次安装继续使用 DMG，并优化其压缩封装。
- 保留公共更新源 URL，现有 Sparkle 2.9+ 客户端按硬件选择更新，Apple Silicon 上通过 Rosetta 运行的旧版也可迁移到原生包。
- 两个架构各构建一次，DMG 与更新包复用同一 Release 应用，不再额外构建 Universal 更新应用。
- 发布前检查两包的版本、build、最低系统、架构、大小、摘要与签名；服务端只有在完整双包验证成功后才切换更新源。历史 ZIP 保留。
- 调整发布缓存身份、部分失败恢复和发布后校验，避免混用旧 ZIP 与新 XZ，避免只校验更新源的第一个架构。

首次发布此格式前，必须先部署私有 QueryCraft 仓库中的 LicenseServer 支持。当前实现未增加应用、MCP、Skill 或驱动版本，也未发布资源。

第一轮本地源码验证：Intel Release 构建通过，ARM Release 交叉编译通过。Intel 完整签名 XZ 为 **13,736,948 字节（13.74 MB）**，ARM 为 **11,895,032 字节（11.90 MB）**；相同 Intel 应用的 ZIP 为 19,003,788 字节。与已发布 0.1.11 的 32,430,979 字节 Universal ZIP 相比，下载量分别减少约 57.6% 和 63.3%（源码版本不同，该比较体现实际下载量，非编译器优化基准）。

两架构解压后的 216 个条目逐项比对文件摘要、权限与符号链接目标，均一致；解压后严格签名及固定证书验证通过。两份真实归档同时通过 Go 服务端的发行公钥验签、XZ 校验、路径/展开上限和原生 CPU 检查。实际 Sparkle 选包通过本机 Intel 与进程内 Intel/ARM 硬件条件测试；新旧缓存、空缺/混合包、签名错误、篡改、重放、历史导入及旧数据库迁移有回归覆盖。

Intel 解压后功能库已加载 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 六类现有 API 5 驱动，未发起数据库连接。本轮不改变驱动协议、二进制或加载路径。ARM 实机运行及真实系统替换安装仍需 ARM 机器/原生 CI 验收；本轮没有修改用户安装的应用、触发线上部署或模拟桌面输入。

### 第二轮最终测量（同一源码基础，2026-10-21）

- MCP SDK、stdio/HTTP 和 NIO 移入独立 `QueryCraftMCPPackage`。主程序保留权限、凭据、执行逻辑和驱动共享类型；独立服务动态引用同一 Feature 模块，不静态重复嵌入驱动类型。
- DMG 无损改用系统 ULMO/LZMA 封装；应用图标、全部分辨率及六类驱动能力保持原样。图标重编码收益有限且原生转换出现像素差异，因此没有采用。

| 架构 | DMG：第一轮 → 最终 | XZ：第一轮 → 最终 |
| --- | --- | --- |
| Intel | 19,929,880 → **13,489,484 字节**（−32.32%） | 13,736,948 → **12,206,792 字节**（−11.14%） |
| Apple Silicon | 17,672,477 → **11,793,774 字节**（−33.26%） | 11,895,032 → **10,614,872 字节**（−10.76%） |

两架构的主程序和 MCP Release 均编译通过（ARM 为交叉编译）。80 项 Swift 测试和 35 项脚本测试通过；Intel 签名 MCP 在搬迁后通过 stdio/HTTP、权限撤销、令牌轮换、六类 API 5 驱动加载及 MySQL/Doris 单独和新旧混装验证。独立组件实际下载、CLI 更新、旧会话继续调用、失败恢复、回退、卸载保留策略也通过。

最终 XZ 解压与最终 DMG 只读挂载后，文件摘要、权限、符号链接及签名均与对应签名 App 一致；验证挂载已全部卸载。SQL 三类驱动、Redis、Elasticsearch、Kafka 的协议/公共模型/驱动入口未变，表数据页及 SQL 结果页的数据链路未改。本轮没有新增实库操作，也未执行 ARM 原生运行、持久 launchd 注册或真实系统替换安装。提交前以最终第二轮双架构签名归档再次运行 Go 全量测试和 `go vet ./...`，均通过。

### 本次提交范围与后续发布决定

本次仅提交功能、测试和文档，不推送、打 tag 或部署；主程序仍为 0.1.11 (21)，MCP 仍为 0.1.1+2。正式发布前须另行准备新版本身份及对应双语发布说明，不能覆盖已有发行。

| 项目 | 本次瘦身提交 | 相对已发布 v0.1.11 的后续发布范围 |
| --- | --- | --- |
| 主程序 | 构建、归档和共享 MCP 边界有变化 | 需新版本 |
| MCP | 独立运行包及传输依赖有变化 | 需新的 version/build，0.1.1+2 已发布 |
| Skill | 未变化 | 不发布 |
| MySQL | 未变化 | 之前的事务状态提交有变化，需发布双架构驱动 |
| PostgreSQL | 未变化 | 之前的事务状态提交有变化，需发布双架构驱动 |
| Doris | 未变化 | 之前的事务状态提交有变化，需发布双架构驱动 |
| Redis | 未变化 | 不发布 |
| Elasticsearch | 未变化 | 不发布 |
| Kafka | 未变化 | 不发布 |
| Driver API | 保持 5 | 无不兼容合约变化 |

2026-10-21 提交前检查了六类驱动的 12 份线上架构目录，均为 API 5，最低主程序版本 0.1.5，与当前主程序兼容。该检查仅确认目录兼容性，不代替后续驱动发布时的产物摘要与实库验收。

## English

- Ship separately signed Intel and Apple Silicon `.tar.xz` updates while retaining DMG installation with stronger lossless compression.
- Keep the public feed URL. Sparkle 2.9+ chooses the compatible archive, including migration from an Intel process running under Rosetta to native ARM.
- Reuse each architecture's Release app for its installer and update; remove the additional Universal build.
- Validate the complete pair before publication and preserve legacy ZIP history. Version/build/OS, CPU, hashes, lengths and signatures must agree.
- Version cache identities and validate both published entries during recovery and metadata synchronization.

Deploy the sibling LicenseServer implementation before publishing this format. No application, component or driver version has been increased and nothing has been published.

Local validation produced a 13,736,948-byte Intel XZ and an 11,895,032-byte cross-compiled ARM XZ. The identical Intel app's ZIP is 19,003,788 bytes. Both 216-entry extraction manifests and pinned signatures match; the actual signed archives passed server signature, bounded XZ/tar and CPU validation. Bundled Sparkle selection, incomplete/mixed/tampered pairs, replay, import, legacy schema migration and six installed Intel driver families were exercised. ARM hardware execution and an actual operating-system replacement install remain unverified; existing app installations and public resources were not changed.


### Final second-pass measurements (2026-10-21)

The standalone QueryCraftMCPPackage now owns the SDK and stdio/HTTP/NIO transport; shared permissions, credentials, execution and all six driver API 5 identities remain in the dynamic Feature product. DMGs use lossless ULMO/LZMA; icons and their resolutions are unchanged.

Intel: installer **19,929,880 → 13,489,484 bytes**, update **13,736,948 → 12,206,792 bytes**. ARM: installer **17,672,477 → 11,793,774 bytes**, update **11,895,032 → 10,614,872 bytes**. Both Release app/runtime architectures compiled; 80 Swift and 35 script tests passed. Relocated native Intel stdio/HTTP, six driver families, independent MySQL/Doris loading, mixed upgrades, actual signed component downloads, standalone CLI updates, existing-session continuity, rollback and failure recovery passed.

Final extracted XZ and read-only mounted DMG contents matched the signed apps' hashes, permissions, symlinks and signatures. All validation mounts were detached. ARM native execution, real databases, persistent launchd registration and system replacement installation were not exercised; installed apps, user settings, versions and public resources were not changed.

Pre-commit validation reran the complete Go test suite against the final signed archive pair and passed `go vet ./...`. All 12 live driver catalogs advertise compatible API 5 and minimum app version 0.1.5. This source-only commit changes the app and MCP, leaves Skill and every driver unchanged, and does not push, tag or deploy. Future publication requires fresh app/MCP release identities and bilingual notes. Since v0.1.11, earlier transaction-state changes also require new MySQL, PostgreSQL and Doris releases; Redis, Elasticsearch and Kafka remain unchanged. Driver API stays at 5.
