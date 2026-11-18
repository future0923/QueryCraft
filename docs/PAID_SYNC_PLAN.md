# 免费版与付费同步改造计划

最新状态：2026-11-13。下方“历史实施记录”保留当时的状态；当前完成项与门禁以本节为准。

## 当前验收状态

- 本地数据库能力免费；Mac/iPhone 同步与分组双向修改、删除已验证，iPad 真机仍待验收。
- Apple 四档商品已配置。用户完成月度沙盒购买和恢复购买，同 iCloud 账户的官网 Mac 沙盒授权已验证；不能据此声称四档正式购买均已验证。
- Apple 本地 StoreKit 集成测试已改为独立 Mac 宿主，直接编译生产 `CloudSyncStoreKit` 和权益源码。四档购买/价格/账户 UUID/恢复/退款，三档订阅续期/到期共 7 个参数用例全部通过。证据：`.build/sync-billing/storekit-macos.log`。测试不调用真实支付或生产授权接口，不能替代真实沙盒、正式环境和商店审核。
- 爱猹收月 ¥3.90、年 ¥26.90、永久 ¥39.90 均已上架；生产授权服务已部署，正式身份与签名权益校验、三档价格及创建支付入口通过。没有替用户执行正式自购，真实买家付款/退款和交易限额尚未验收。
- 生产和 Sandbox 服务、数据库、签名密钥隔离；测试购买不会解锁正式账户。`/privacy` 已部署。证据：`.build/watchapay-live/validation.json`。
- Mac 商店渠道已新增独立工程：不依赖 Sparkle，随包提供七类驱动和 SSH，禁止下载、导入或卸载可执行插件。MCP 复用现有协议/权限/工具实现，通过内置 HTTP 服务提供；需要保持应用运行。官网渠道继续支持独立 MCP 进程与 Sparkle。
- Mac 商店渠道 Intel Debug 已通过真实 Apple Development 签名。独立签名沙盒宿主实际验证了未选择文件拒绝访问、七驱动加载、SSH ABI/终端组件校验、MCP HTTP 鉴权及停止、容器内书签与 Skill 安装/卸载；未连接用户数据库或启动 CloudKit。证据：`.build/sync-billing/mac-store-sandbox-runtime.log`。
- MCP/更新隔离/本机文件授权回归合计 13 项通过。SSH 私钥与配置文件采用设备本地只读安全书签；Skill 使用显式选择目录的读写书签，不同步授权书签。真实外部目录选择、SSH agent/Include/SFTP、ARM 原生运行仍待验收。证据：`.build/sync-billing/mac-store-file-grant-tests.log`。
- App Store Connect 已在现有 App 6832782588 下添加 macOS 平台，保存 0.1.16 草稿及中国产品说明、支持链接和审核联系人，设为手动发布；三订阅及永久内购均为“准备提交”，尚未提交审核。用户亲自补齐联系姓名及电话。证据：`.build/sync-billing/appstore-review-status.json`。
- 已从可信正式包组装商店专用通用组件副本。Kafka 两架构的 OpenSSL 主版本不同，保留各自依赖，最终包须逐架构核验真实依赖链；未覆盖或重发线上驱动。Intel Release 归档及商店安装包导出成功，展开包通过签名、分发 profile、沙盒/CloudKit 及 Intel 依赖闭包检查。证据：`.build/sync-billing/mac-store-export-validation.json`。通用商店主应用 Debug 已签名构建通过；最终通用 Release 分发归档仍待完成，不能把 Intel 分发包通过当作双架构发布验收。
- 通用签名沙盒宿主构建成功，arm64/x86_64 的实际依赖闭包均检查通过；同一通用包在 Intel 上重复通过七驱动、SSH、MCP 与 Skill fixture 沙盒探针。构建时移除 DerivedData 运行路径，确保探针不会借用构建目录中的框架。另以删掉 Kafka TLS 库的临时包验证门禁确实拒绝缺失依赖。证据：`mac-store-universal-structure.json`、`mac-store-universal-runtime.log`、`mac-store-negative-gate.json`（均位于 `.build/sync-billing/`）。不代表 ARM 真机执行或最终通用分发包通过。
- 源码官网/iOS 默认配置仍为 preview，商店工程单独使用 appStore；本轮未替换 `/Applications`、未发布新客户端、未提交商店审核。

## 发布前仍需完成

1. Mac 沙盒完整实测：七驱动加载、SSH/TLS/证书文件持久授权、Shell/Skill 与外部客户端配置的文件访问、MCP 生命周期。不能仅凭编译或单元测试认为商店功能已就绪。
2. App Store 首版/四档内购审核材料；处理当前无法关闭的“简化购买”及缺少 appAccountToken 的安全绑定门禁。
3. TestFlight 与生产内购环境路由、正式 App Store Server API 权限、续期/退款跨设备恢复，真实买家官网付款及退款验收。
4. iPad 真机、ARM Mac、正式签名和分发包验收，审核通过后才发布。

## 历史实施记录

以下条目记录各阶段完成当时的状态，其中“尚未部署”“等待首笔购买”等描述已被上面的最新状态替代。

## 收费口径

- 免费版包含全部功能：7 类数据源插件与 SSH、SQL 编辑器与智能补全、MCP、跨库传输与导入导出、结构对比、安全锁与事务写入，以及 macOS、iPhone、iPad 的自动更新。不限时、不阉割、不限速、无广告。
- 付费只增加 iCloud 同步：连接配置、密码、保存的查询语句和代码片段在 Mac、iPhone、iPad 之间自动同步。
- 付费方案：App Store 月度 ¥3.8、半年 ¥16.8、年度 ¥26.8、永久 ¥39.9；官网（爱猹收，人民币）月度 ¥3.9、年度 ¥26.9、永久 ¥39.9（一次买断）；官网暂不提供半年方案，时长方案到期不自动续费。同步功能可免费试用 30 天。
- macOS、iPhone、iPad 都会上架 App Store。

## 应用待改造

1. 去掉官方版 30 天试用结束后限制连接数据库的逻辑（`WorkspaceSessionError` 等授权拦截），改为只对 iCloud 同步做授权校验。
2. 实现 iCloud 同步：连接配置、保存的查询语句和代码片段（CloudKit）与密码（iCloud 钥匙串）在 Mac、iPhone、iPad 间同步，包含冲突处理、删除同步和关闭同步后的本地数据保留。
3. 同步的付费授权：App Store 版本使用 StoreKit（订阅与买断），macOS 直接下载版沿用现有授权；一次购买在三端通用。
4. macOS 上架 Mac App Store 的适配（沙盒、插件下载与加载方式、自动更新改由商店负责）。

完成以上改造前，官网的收费说明与应用实际行为不一致，正式部署官网时需要注意。

## 进度

- 第 1 项已完成：`LicenseAccessGate` 不限制任何数据库功能。旧授权状态只供同步权益适配使用；停用旧授权配置不等于拥有付费同步权益。
- 第 2 项：Mac 与 iPhone 的连接、片段双向修改/删除、分组恢复已实测，用户于 2026-11-12 确认验证完成；iPad 真机按用户安排延后。密码使用 CloudKit 加密字段，与连接记录一起处理冲突和删除；不再将其表述为 iCloud 钥匙串实现。
- 第 3 项进行中：StoreKit 2 购买、恢复购买、订阅/永久授权、退款撤销和宽限期处理已实现，三端共享同一源码。官网下载渠道提供现有已付费激活的签名校验适配，**跨渠道服务端桥接已实现，仍需真实沙盒购买验收和部署**。
- 当前构建显式使用 `QCCloudSyncBillingMode=preview`，保留本轮同步验收能力；缺失/非法配置不放行。未切换生产收费，未上传 TestFlight。商品后台、账户级 30 天试用和跨渠道授权桥接完成前，不得把模式改为正式收费后发布。
- 第 4 项（Mac App Store 沙盒及插件适配）尚未完成。

## 购买实现与验收边界（2026-11-12）

`CloudSyncBilling` 组合经过验证的权益；StoreKit 适配只接受 `.verified`、商品白名单和正确商品类型。月/半年/年为同组自动续期订阅，永久为非消耗型商品。待批准或取消购买不解锁；退款、撤销或过期不删除本地数据。价格显示使用 StoreKit 的 `displayPrice`，本地测试价格不代表 Apple 已批准的销售价格。

| 方案 | 预留 Product ID | 类型 |
| --- | --- | --- |
| 月度 | `io.github.future0923.QueryCraft.sync.monthly` | 自动续期订阅，1 个月 |
| 半年 | `io.github.future0923.QueryCraft.sync.halfYear` | 自动续期订阅，6 个月 |
| 年度 | `io.github.future0923.QueryCraft.sync.annual` | 自动续期订阅，1 年 |
| 永久 | `io.github.future0923.QueryCraft.sync.perpetual` | 非消耗型，一次购买 |

没有默认推荐方案。正式 StoreKit 页面还需配置并验证 `QCPrivacyPolicyURL`，校验使用条款、实际价格及续费说明。

同步的启用、手动刷新、本地编辑上传、前台恢复和周期请求均经过授权检查。到期暂停保留开关意图、待上传编辑/删除和服务端游标；恢复有效权益后可以继续。正式收费模式由控制器调度请求（本地编辑后约 2 秒、回到前台、后台允许时每 10 分钟），关闭 CKSyncEngine 自主请求以避免绕过门禁；预览模式保留原来的 CloudKit 自动调度。iOS 挂起时不保证上述定时器执行。

### 尚未完成，不能当作已上线

- 账户级 **30 天**试用和官网下载授权 → 同 iCloud 账户跨设备识别：源码已实现，详细验证和部署状态见下节；生产模式尚未启用。
- 官网 ↔ App Store 的权益桥接：已实现可验证的账户绑定及服务端签名校验，处理续期、退款、撤销和切换 iCloud 账户。旧设备 token 不复制；任意 iCloud `paid=true` 记录不可信。真实沙盒购买仍待验收。
- App Store Connect：已重新登录，创建独立 In-App Purchase 服务端密钥；商品配置进展见下节。未来 Mac App Store 应加入同一个 app 记录实现 universal purchase。
- StoreKit 实测独立方案：`QueryCraftSyncPurchases`，测试资源只进入测试 bundle；主 app 不打包模拟商品。当前 iOS 26.3 模拟器返回 `SKInternalErrorDomain Code=3`（无法保存配置），商品为空；独立方案复查仍失败，**不能声称真实 StoreKit 购买已验证通过**。逻辑回归与此环境集成测试分别记录。

参考：[Apple 当前购买权益](https://developer.apple.com/documentation/storekit/transaction/currententitlements)、[通用购买](https://developer.apple.com/help/glossary/universal-purchase)、[StoreKit 测试环境问题的 Apple 讨论](https://developer.apple.com/forums/thread/826971)。


## 账户级试用与已有官网授权（2026-11-12 续）

- 账户身份来自原生 `CKFetchWebAuthTokenOperation`，服务端只接受 Apple `users/caller` 返回的身份。客户端自己提交的 record name、邮箱、`paid=true` 均不是认证。真实 Mac Developer ID 签名探针已取得凭据，Apple 校验成功，服务端与客户端的账户摘要一致。
- 身份摘要按 container + environment + user record name 计算，开发/生产完全隔离。API token 是可随客户端分发的容器标识，不是用户凭据；原生临时认证 token 不持久化、不写日志。
- 用户显式领取后，服务端 PostgreSQL 用账户唯一键记录首次开始和固定 `30 × 24h` 截止。状态查询不启动试用；换设备、重装、并发领取和过期重领不能重置。旧设备级全应用试用表不参与。
- Mac 已有授权通过原本的 device credential + installation ID 验证后，显式关联当前 iCloud。每份授权最多关联一个 iCloud 账户；跨账户重复关联被拒绝。同一账户其他设备只提交自己的 Apple 身份证明，不复制 Mac 的设备密钥，也不额外占用旧硬件激活名额。
- 账户状态每次读取原授权当前状态和有效期，停用/到期不继续签发权益。返回 Ed25519 签名、账户/用途/随机请求 nonce 绑定的短期权益，最长十分钟；同一同步流程的自动检查最多复用 60 秒，手动检查始终重新校验；客户端不持久化账户授权缓存，以单调时钟限制有效期，账户切换立即清理，迟到响应被丢弃。
- 原生设置增加“免费试用同步 30 天”、试用截止日期、“检查授权”和 Mac 的“将现有授权关联到当前 iCloud”。领取不绑定银行卡、不自动续费；本地数据库功能保持免费，失效只暂停同步。
- 未改变当前安装的预览应用，未上传 TestFlight，未部署生产服务或启用扣费。生产开启依赖服务端环境配置、最终双端真实账户验收。
- **边界：App Store 购买 → 官网 Mac 的反向桥接现已实现，真实沙盒购买及正式部署仍未验收，不代表已可上线收费。** App Store 内同一商店账户仍走 StoreKit 恢复购买；官网改用爱猹收，沙箱购买闭环仍需验收。

服务端路由：`POST /api/v1/sync/status`、`/trial`、`/link`。跨渠道 proof 不通过现有数据同步记录传递，服务端不读取用户连接/密码/SQL。

参考：[原生 CloudKit 身份凭据](https://developer.apple.com/documentation/cloudkit/ckfetchwebauthtokenoperation)、[当前 CloudKit 身份](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/FetchCurrentUserIdentity.html)。

本机隔离全链路证据：`.build/sync-billing/integration/result.json`。使用真实 Mac iCloud 身份、独立服务/数据库/签名密钥，验证领取、原期限恢复、官网授权关联和无旧设备凭据的新客户端恢复；这不是 iPad 真机或正式支付验收。


## App Store → 官网 Mac 桥接（2026-11-12，未启用收费）

- 购买前用当前 iCloud 身份从服务端取得固定 UUID，通过 StoreKit `appAccountToken` 传入购买。账户切换或预检失败时不打开付款流程。
- 购买/恢复/交易更新后上传 verified JWS。服务端验证 Apple 根链、ES256、bundle、环境、白名单商品、类型、所有权和账户 UUID，并实时调用 App Store Server API 获取最新状态。JWS 本身不授予跨渠道权益。
- 原始交易只能绑定一个 iCloud 账户。官网 Mac 通过自己的 iCloud 身份读取签名权益，不需要复制 iPhone 凭据。每次服务端状态查询重新核对续费、到期、宽限期及退款，不依赖通知是否送达。
- 网络中断保留本机 StoreKit 已验证权益，明确提示跨设备同步待完成、无需重复购买；恢复购买补同步。生产和沙盒必须使用隔离服务、数据库和签名配置，生产失败不降级到沙盒。
- Family Sharing 和多名额购买不在当前模型中，正式启用前保持关闭；关闭“简化购买”，确保先绑定 iCloud 再购买。无 appAccountToken 的历史交易当前不支持迁移（当前尚无售出订单）。
- 新服务端密钥已在本机受限目录保存；没有放入仓库或客户端。Sandbox 真实 API 请求返回 404（合格式但不存在的交易），说明凭据可访问接口，**不等于真实购买成功**。Production 返回 401；[Apple 工程师说明](https://developer.apple.com/forums/thread/806452)首次正式发布前该接口访问受限，上架后仍须复核。
- 新增接口：`POST /api/v1/sync/purchase`（预检）、`/appstore`（关联）。新增表仅保存账户 UUID、环境及原始交易引用，没有连接、密码和 SQL 内容。
- 服务端 `appstore/licensing/store/api` race 回归通过；iOS 共享权益与分组测试 24/24 通过。Mac 46/46 测试通过，完整证据 `.build/sync-billing/appstore-validation.json`。
- 仍保持 `preview`。本轮未部署生产、未上传 TestFlight、未更换用户运行中的应用、未产生真实扣款。

### Apple 后台配置进展（2026-11-12 更新）

- App：6832782588；订阅群组：22571276；群组中英文名称已保存。
- 已保存月度 6833792193（¥3.8）、半年 6833793038（¥16.8）、年度 6833793667（¥26.8）及永久非消耗型 6833831126（¥39.9）；用户确认的 Apple 价格已落实。永久创建的空白协议弹窗已恢复，未签署新协议。
- 三项订阅已全部调整为服务级别 1，时长不同但功能相同，不作为功能升级/降级。
- 四项商品中英名称/说明已保存；当前只选中国大陆用于验收，未提交审核。三种订阅多名额已关闭、仅 App Store；家人共享均未开启。年度为一年预付，不启用十二个月分期。
- 用户已创建中国大陆 Sandbox 测试账户；密码由用户保管，未读取或记录。
- “简化购买”关闭被 Apple 明确拒绝：最新已批准二进制文件尚不含所需 StoreKit API。当前仍开启，正式收费前必须在首版审核后关闭，或实现无 appAccountToken 交易的安全认领流程；不能假称已完成。
- 审核截图、备注和首次上架提交待真实购买验收后准备。

### 独立 Sandbox 服务（2026-11-12）

- DebugTools 新增 `querycraft-sync-sandbox.service`，仅监听 `127.0.0.1:8788`；单独 PostgreSQL 数据库/角色 `querycraft_sync_sandbox`、授权签名密钥和配置目录。正式 `querycraft-license` 未替换或重启，生产配置不接收 Sandbox。
- HTTPS 测试入口 `https://querycraft.debug-tools.cc/sandbox-sync/api/v1/` 只开放同步鉴权接口；管理及其他路径返回 404。Nginx 语法及两服务 health 检查通过。
- Apple 服务端私钥仅复制到沙盒服务受限配置目录（root/专属服务组 0640），未写入仓库或客户端。沙盒授权公钥与生产不同。
- 测试包使用 `.build/sync-billing/sandbox/` 的独立 Info.plist/entitlements，仓库默认仍 preview；未替换运行中 Mac，未上传 TestFlight。
- 真机购买、跨设备恢复、续费和退款仍未验收；手机无线连接当前不可用，等待恢复连接后继续。

- 真实 Mac iCloud → HTTPS Sandbox → Ed25519 签名响应校验 → 新客户端重复购买预检的固定 appAccountToken 验证通过。首次 CloudKit 网络错误后一次独立复测成功；未创建试用或付费交易，沙盒购买记录仍为0。证据 `.build/sync-billing/sandbox/preflight-result.json`。

- 手机无线连接恢复后，已原地安装开发签名 build5 并启动。该安装包为 appStore 模式、独立 Sandbox 授权服务，CloudKit 仍 Production；默认源码配置仍 preview。等待用户在 Apple 沙盒弹窗登录并完成首笔测试购买，暂未宣称购买链路通过。

### 同步/购买页重做与隐私政策（2026-11-12 晚）

- Mac、iPhone、iPad 共用 `CloudSyncAccessSummary` 按状态显示：未试用（开始 30 天试用）、试用中（剩余天数/到期日）、已订阅（方案、有效期至、管理订阅，不再显示购买列表）、永久、官网授权。同步开关和状态放在最前，“本地功能免费”只出现一次；去掉“检查授权”，仅出错时显示重试。半年/年度按 App Store 实际价格显示节省比例，不推荐、不预选。
- Mac 官网版在同一区域保留授权码激活、购买链接和“关联到当前 iCloud”。
- 官网新增 `/privacy` 中英文隐私政策并在页脚链接；`QCPrivacyPolicyURL` 已写入 Mac 与 iOS 配置。**该页面尚未部署到线上**（线上服务未改动），正式提交审核前需随服务端一起部署。
- 验证：Mac 同步/授权测试 58 项、官网服务端全部测试通过；iPhone 预览 6 种状态（含深色、超大字号、500pt、出错重试）、Mac 预览 5 种状态截图检查通过；iPhone Release 测试包已构建签名，待手机可用后安装并做沙盒购买。


## 官网改用爱猹收（2026-11-13）

- 用户确认官网仅保留月度 ¥3.9、年度 ¥26.9、永久 ¥39.9；半年只保留在 Apple 内购。官网按时长购买，不自动续费；本地数据库功能仍全部免费。
- 已删除服务端 Creem 收银、回调及新订单代码，隔离测试服务器已移除 Creem 配置加载和公开入口。历史测试记录与回滚备份保留；不涉及关闭 Creem 平台账户。
- 爱猹收三个沙箱商品均为 active，金额/有效期已读取核实。服务端凭据只保存在私密文件及测试服务配置中，不进入应用或仓库。
- 服务端使用 Apple 验证后的 iCloud 账户摘要检查权益；客户端只接受绑定账户、nonce 和短期有效期的签名响应。付款回跳不作为解锁证据。
- Swift CloudSync/License 62 项通过；Go 全量 race 测试通过。覆盖无效付款链接、过期、退款、账户绑定与 Apple/官网渠道故障隔离。
- 隔离沙箱健康检查通过，正式服务健康检查通过。真实 Mac iCloud 身份和共享源码签名校验通过，准确下发三档价格并取得月度模拟付款入口。用户已确认模拟付款；全新原生 Mac 校验进程重新获取同一 iCloud 身份，收到签名验证通过的有效月度 directLicense 权益，沙箱付款→账户授权闭环通过。此轮没有操作已安装 Mac 应用界面或 iPad 真机。
- 未开启爱猹收正式环境、未进行真实扣款、未修改生产服务二进制、未提交或推送代码。数据库驱动和 Driver API 未变，不涉及重新打包驱动。
