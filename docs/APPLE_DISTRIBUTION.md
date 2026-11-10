# Apple Developer 分发配置

macOS 使用官网/GitHub 直接分发，保留现有 Sparkle 与组件目录的 Ed25519 更新签名。此配置不启用 Mac App Store 分发，也不改变现有数据库功能。

## macOS 身份与公证

`Config/DeveloperID.json` 只保存公开证书指纹、名称和 Team ID。当前 Team 为 `5975A7N3W3`。私钥保留在本机 login Keychain；可通过 `QUERYCRAFT_SIGNING_KEYCHAIN` 指定其他钥匙串。`scripts/code-signing.py check` 在签名之前核对指定证书及其私钥，不自动生成或回退到临时签名。

主程序、Feature、凭据助手、MCP、SSH 和七类数据库驱动均需要 Developer ID、可信时间戳和 Hardened Runtime。Sparkle 的框架、Autoupdate、Updater.app 与 XPC 服务由内向外使用同一 Developer ID 重签，保留功能 entitlement、移除旧身份/调试 entitlement。主程序及 MCP 保留 Library Validation；数据库/SSH 安装器还会独立严格校验插件签名与 Team，不能放行旧临时签名驱动。

本机公证使用 `QueryCraft-Notary` Keychain profile，可通过 `QUERYCRAFT_NOTARY_PROFILE` 指定已有 profile。使用 Apple 官方 `notarytool store-credentials` 在本机配置；不要把 Apple 密码、应用专用密码或 API 私钥粘贴到聊天或提交到仓库。

也可在被忽略的 `Config/LocalDistribution.json` 保存 `{"notaryProfile":"已有 profile 名称"}`，仅引用本机凭据，不复制密码或修改其他应用的配置。环境变量优先。当前维护者本机已验证可复用 PiDeck 的既有 profile。

```sh
python3 scripts/code-signing.py check
python3 scripts/notarize.py check
python3 scripts/notarize.py /absolute/path/QueryCraft.app --log /absolute/path/app-notary.json
```

必须等待 Apple 返回 Accepted，并保存公证日志。主程序/MCP 的 `.app` 在生成更新归档前装订并验证票据；最终 DMG 签名、公证、装订，再验证 Gatekeeper。独立插件 ZIP 在生成摘要和目录记录前提交公证，其代码票据保存在 Apple 服务端；ZIP 不能装订。失败或超时中止打包，不能继续发布。

正式 CI 使用当前已验证的 Apple ID 公证认证，需要以下五项 Actions secrets（旧自签名 secrets 不能直接充当 Developer ID）：

- `QUERYCRAFT_DEVELOPER_ID_P12_BASE64`：仅导出指定 Developer ID 证书及对应私钥的加密 P12，再进行 base64 编码。
- `QUERYCRAFT_DEVELOPER_ID_P12_PASSWORD`：该 P12 密码。
- `APPLE_ID`：Apple 开发者账号。
- `APPLE_APP_SPECIFIC_PASSWORD`：该账号的应用专用密码，不是 Apple 登录密码。
- `APPLE_TEAM_ID`：开发者团队 `5975A7N3W3`，必须与固定 Developer ID 身份匹配。

开发者证书与公证认证属于开发者团队，可用于该团队的多个应用，与应用采用 Electron 或 Swift/AppKit/SwiftUI 无关。QueryCraft 只复用账号身份，使用自身的原生构建、嵌套签名、插件校验及 Sparkle 分发链路。引用本机既有 profile 不会修改 PiDeck 或其他应用的配置。GitHub Secrets 无法读取回明文，不能直接从另一个仓库下载或复制。

如以后确需 API Key 认证，可改为配置完整的 `QUERYCRAFT_NOTARY_KEY_ID`、`QUERYCRAFT_NOTARY_ISSUER_ID`、`QUERYCRAFT_NOTARY_PRIVATE_KEY_BASE64`，分别为支持公证的 App Store Connect 团队 Key ID、Issuer ID 和 base64 编码的 P8；这组配置优先于 Apple ID。不要把 APNs 推送密钥当成 App Store Connect API 密钥。当前方案不需要新建 API Key。

原 `SPARKLE_PRIVATE_KEY` 保持不变。公证凭据只注入客户端与驱动打包步骤，发布服务任务不接收 Apple 私钥或公证密码。

每个客户端/驱动原生 job 导入临时钥匙串，结束时恢复搜索列表并清理；不覆盖本机钥匙串。CI 禁止 `QUERYCRAFT_NOTARIZE=false`。本地可显式使用该值只做签名/加载验证，其产物未经公证，不能作为正式发布验收。

`lastLegacyAppVersion` 记录已发布旧渠道的上限 0.1.15。正式 CI 会先要求新主程序版本和待发布 MCP/SSH 的 minimumAppVersion 高于该上限；驱动打包自动使用本次新主程序版本作为 minimumAppVersion。待验证身份为主程序 0.1.16 (26)、MCP 0.1.6 (7)、SSH 0.9.1 (12) 及七类驱动的新版本，最低主程序均为 0.1.16，不能直接以旧身份重新发布。

## iCloud 同步

容器为 `iCloud.io.github.future0923.QueryCraft`，Mac、iPhone、iPad 共用同一个私有数据库，同步连接配置、连接分组、保存的查询和代码片段。密码写入 CloudKit 加密字段 `secret`，由用户 iCloud 钥匙串中的密钥加密，Apple 无法读取。同步默认关闭，用户在设置中开启。

数据结构以 `Config/CloudKitSchema.ckdb` 为准，2026-11-10 已导入 Development 并部署到 Production。新增字段时先修改该文件，在 CloudKit Console 的 Development 环境 Import Schema，再 Deploy Schema Changes 到 Production。Production 只能新增，不能删除或改类型。`CloudSyncTests` 会检查代码写入的每个字段都已在该文件中声明。

macOS 直接分发版使用 iCloud 需要嵌入描述文件：`Config/QueryCraft-DeveloperID.provisionprofile`（Developer ID 类型，含该容器，2044 年到期）和 `Config/DeveloperID.entitlements`（`icloud-container-environment=Production`）。`scripts/developer-id-signing.py` 只对正式包 `io.github.future0923.QueryCraft` 嵌入描述文件并使用这份 entitlements，签名前核对 Team、Bundle ID、容器和有效期；`.Dev` 包不带 iCloud。应用启动时会检查当前签名是否真的带有 iCloud entitlement，没有时同步入口显示不可用，不会崩溃。描述文件不含私钥，可以提交。

iOS/iPadOS 使用 `QueryCraftMobile/QueryCraftMobile.entitlements` 与自动签名；导出到 App Store Connect 时 Xcode 把 `aps-environment` 换成 production。Debug 真机包连接 Development 环境，TestFlight 与商店包连接 Production 环境，两边数据互不相通。

## 凭据助手与旧版升级

旧安装目录 `v1/`、`shared-v2/` 及旧证书备份不删除。新助手安装到各自目录内的 `developer-id-5975A7N3W3/`。协议版本、Keychain service、连接 UUID、vault ID 保持不变；新旧共享助手使用同一 vault.lock，避免并发写入丢失。新助手调用者要求 Apple 信任链、Developer ID 类型、相同 Team 和既有允许的 Bundle ID；宿主在每次请求前验证助手。

旧 Keychain 项目的 ACL 可能需要用户首次授权新助手。这一步不能由更换证书自动消除。拒绝授权时保留已有内容并返回错误；不清空密码、不改用明文文件，也不覆盖旧助手。后续同 Team 换证继续使用已安装的新助手。

正式发版必须验证：旧正式版升级、已有共享 vault 首次授权/拒绝/重试、桌面端/MCP 混合版本、连续两次升级及真实 Keychain ACL。自动测试仅使用临时凭据并关闭授权 UI，不能冒充用户旧 ACL 已验收。

## 驱动和组件切换门禁

MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka、Milvus 均适用相同签名要求。Driver API 仍为 5，无业务协议改动。SSH、MCP 也需要随签名打包流程变化重新发布；Skill 内容未变，不因此发版。

当前 Apple Team 宿主按既有规则拒绝旧 ad-hoc 驱动，旧自签名宿主也不能使用新的 Apple Team 驱动。正式发布前必须：

1. 按 `RELEASE_PROCESS.md` 分配主程序与受影响驱动/组件的新 version/build，禁止覆盖已发布资源。
2. 新驱动/SSH/MCP 的 minimumAppVersion 设置为实际首次启用 Developer ID 的新主程序版本，防止旧客户端选择不兼容签名包；旧目录历史继续保留。不能提前把门槛写成仍采用旧签名的 0.1.15。
3. 先准备双架构公证驱动和组件，再发布新客户端；检查客户端自动选择/下载新驱动的链路。新宿主不得继续加载缓存中的旧临时签名包。
4. ARM/Intel 分别验证全部七驱动、MySQL/Doris 独立加载和混合升级。历史驱动同 Team 时验证兼容加载；跨签名渠道时验证拒绝，不能跳过或放宽校验。
5. 旧缓存 run 必须通过最终 Developer ID 和公证票据检查，不能仅按附件名称复用旧自签名产物。

GitHub Actions 手动选择 `validate_only=true`，其余发布开关全部保持 false，可构建、公证并验证双架构主程序与实际改动的组件/驱动。该模式拒绝同时请求发布，不创建正式 Release、不切换线上目录。发布时仍需完整执行门禁。

## iOS / iPadOS 与 TestFlight

`QueryCraftMobile/project.yml` 为 XcodeGen 源；生成的 `.xcodeproj` 不提交。应用 target 启用自动签名和上述 Team，模拟器继续使用 ad-hoc。Debug 保留 `io.github.future0923.QueryCraft.MobileProof`；Release 使用正式标识 `io.github.future0923.QueryCraft.Mobile`，两者数据隔离。移动端独立版本初始为 0.1.0/build 1，上传新构建时递增 build。

```sh
xcodegen generate --spec QueryCraftMobile/project.yml
bash scripts/archive-mobile.sh /absolute/path/new-export-directory
```

脚本先准备 iOS arm64 原生依赖，再 Archive 和导出 IPA。XcodeBuildMCP 没有 Archive/Export 操作，因此这两步使用 Xcode 原生命令；平时编译仍使用 XcodeBuildMCP。导出配置采用 app-store-connect、automatic signing，destination 为 export，不会自动上传。

前置工具为 Xcode 26、XcodeGen、XcodeBuildMCP 和 CMake 3.31+；原生依赖脚本使用 `CMAKE_BIN` 或项目内 `.build/ios-tools/cmake/data/bin/cmake`。移动端 `Package.resolved` 保存在源码目录，Archive 脚本复制到生成工程并禁止自动改版本。

Archive 默认将 DerivedData 放在本次输出目录，也可通过 `IOS_DERIVED_DATA` 指定已有缓存。导出目录必须是新的，避免覆盖旧 Archive/IPA。

首次需在 Xcode 登录付费账号，确保 App ID/签名描述文件可创建；在 App Store Connect 建立与正式 Bundle ID 对应的应用记录。完成隐私信息、截图、测试说明及真实加密出口合规评估后，用 Organizer 上传并配置 TestFlight。数据库客户端包含 OpenSSL/数据库传输加密，不预填“未使用非豁免加密”的声明。Apple Distribution/描述文件的最终可用性、实际 Archive/IPA 和 TestFlight 处理结果需单独验证。

## 2026-11-09 本机验证

- Intel macOS 主程序和独立 MCP 的 Release 构建通过。主程序、DMG、MCP、七驱动和 SSH 共 11 个最终公证记录均为 Accepted、无问题；三个可装订产物完成票据验证和 Gatekeeper 检查，DMG 另通过 hdiutil 校验。
- 已签名并迁移到隔离目录的 Release MCP 实际加载全部七类 API 5 驱动；MySQL/Doris 独立加载及跨渠道旧签名拒绝通过。stdio/HTTP 认证、Origin、会话、令牌轮换、资源与权限检查通过。未连接实库验证业务查询。
- 临时 Keychain 凭据覆盖主程序升级、桌面/MCP 共享、并发写入、迁移不覆盖新值、删除标记和篡改/调用者拒绝；未读取或修改用户已保存的连接密码。真实旧用户 ACL 授权及 GUI 自动升级仍属发版验收。
- SSH 原生 C ABI、依赖闭包与终端 renderer 验证通过。Sparkle 实际框架的本机/Intel/ARM 选包测试通过；ARM 条件模拟不等于 ARM 机器运行。
- 79 项脚本回归通过：分发失败/兼容门禁 11、组件范围 31、产物恢复 19、SSH 分发 10、更新归档 8。工作流 YAML、Python/Shell 语法和 diff 检查通过。
- iOS arm64 Release 源码/链接构建通过，使用 `CODE_SIGNING_ALLOWED=NO`。生成工程的设备/测试自动签名、模拟器临时签名及 Debug/Release 身份已核对。Development 证书 Team 匹配；没有对应移动端描述文件，未完成签名 Archive/IPA 或 TestFlight 上传。

本机证据汇总位于 `.build/developer-id-validation/validation.json`。这些历史本机产物仅用于隔离验收，沿用旧版本号，禁止上传覆盖正式资源。现有安装未替换。新分配版本的签名与双架构 CI、账号侧配置及真实用户迁移验收另行记录，不能由这些本机证据推定已完成。

## 2026-11-09 后续验收

- QueryCraft GitHub 仓库已配置 Developer ID P12/密码及 Apple ID/应用专用密码/Team 五项 Secrets；应用专用密码提交 GitHub 前已通过 Apple 公证历史接口认证。证书仅导出固定指纹对应身份，加密备份在仓库外，导出密码保存在本机钥匙串，不读取其他仓库 Secret、不改动其他应用。
- 发布失败门禁、组件选择、验证模式、产物恢复、SSH 与更新归档共 84 项回归通过。工作流 YAML、依赖关系及 Bash/Zsh/Python 语法检查通过。
- iOS arm64 Release 已通过真实 Apple Development 签名构建，正式 Bundle ID 与开发者 Team 匹配，包含有效描述文件；签名构建证据为 `.build/release-0.1.16/mobile-signing-build.log`。Archive/IPA 与 TestFlight 的完成状态仍需单独核实。
