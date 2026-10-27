# MCP 权限修复与验证记录

日期：2026-10-26。已完成本地代码修复、回归、实库验收及 MCP/skill 替换，未提交或公开发布。

## 结论

原问题包含实际代码缺陷，单改 skill 不能解决。`DATABASE()`、`VERSION()` 被过度限制；指定数据库的完整访问仍被统一拦截 DDL，且部分操作只检查当前数据库模式，未正确检查实际目标的单独模式。现已修复。完整访问仍受用户选择的对象范围、独立工具开关和实际驱动能力约束；高风险确认不授予权限。

已安装 MCP runtime build：`20261026-111132-aabe3a8b`，组件版本 `0.1.3+4`，本机 x86_64 签名构建。正式固定启动入口的新客户端验证通过；本聊天的旧进程仍是 `20261026-085152-a2cf3f75`，`runtime_info` 明确返回 `reconnect_required: true`，重连后加载新版。

## 修复范围

| 链路 | 已修复行为 |
| --- | --- |
| SQL 通用 | 无参上下文函数可用；使用完整语义树检查真实读写目标；指定库完整访问允许可验证的 DDL；跨库写入遵守目标库单独模式；每条批处理重新核验授权、确认及连接配置 |
| SQL 解析 | Doris 仅修改注释的 ALTER、COMMENT/RENAME 分类、多表 DROP、限定名索引、INSERT upsert 分类；编辑器原有格式快照保留 |
| Redis | `8` 与保存的 `DB 8` 使用同一权限身份；冲突别名采用更严格模式；FLUSHDB/FLUSHALL 正确检查范围、全部覆盖模式及确认 |
| Elasticsearch | 指定索引完整访问的建删索引、mapping/settings；批量与多索引按各目标模式检查；查询引用验证；普通文档字段不再误判为越权指令 |
| Kafka | 发送使用目标 Topic 模式；接受合法空字符串；只读拒绝与不支持能力使用不同错误码 |
| 发现与路由 | 能力发现不要求预选数据库；直接和 plugin_call 入口一致；连接枚举返回 mcp_access；数据库发现不连接到无关或不存在的默认库；调用前检查协议支持 |
| skill | 源码及已安装副本均更新；逐份检查 SKILL、SQL、非 SQL、SSH/Shell 引用，说明真实权限继承、范围、确认、错误恢复和重连行为 |

## 权限组合和回归

矩阵实现在 `QueryCraftPackage/Tests/QueryCraftFeatureTests/MCPAuthorizationMatrixTests.swift`。组合计数是程序化策略/运行时用例数量，不代表执行了同等数量的外部数据库请求。

| 范围 | 组合数 | 维度 |
| --- | ---: | --- |
| 六类驱动基础策略 | 61,440 | 组/连接/对象模式各 4 态，授权来源 8 态，启用开关、5 种对象范围、工具开关；每驱动 10,240 |
| 三类 SQL 实际运行时 | 2,304 | 模式、范围、确认、工具禁用、直接/委托、query/batch、8 类 SQL |
| 三类非 SQL 运行时 | 432 | 模式、范围、确认、工具禁用、直接/委托及实际操作 |
| SSH 独立授权 | 3,456 | 5 个授权位、全局启用、工具禁用及 27 个 SSH 工具 |
| Redis 名称等价 | 150 | 保存名称、传入名称、3 种模式、两种范围 |
| SQL 操作分类 | 270 | 三类驱动、3 种模式、两种范围、15 类语句 |

另含跨目标覆盖、批处理中撤权/删除连接、只读事务、错误类型、REST lookup/bulk/msearch、能力发现、元数据及解析器/格式化/补全兼容回归。最终 **260 项测试通过，0 失败、0 跳过**；以上矩阵包含在测试方法内部，不与方法数相加。

中间运行发现并修复了旧断言、SSH 测试配置缺项、保存连接时间精度测试夹具及 COMMENT 分类问题；最终结果来自修正后的完整重跑。

## 原生实服务验收

使用同一待安装签名组件和正式 API 5 驱动，对独立容器执行 `scripts/test-mcp-live.py --permission-matrix`。六类均通过，测试容器及其数据已清理。

| 驱动 | 原生验证 |
| --- | --- |
| MySQL 8.4 | 元数据、NULL/decimal、限额、读写、事务/提交/原子回滚、超时恢复、指定库 DDL/字段注释、目标库只读覆盖及确认 |
| PostgreSQL 17 | 同类 SQL 验证，另含 schema DDL、COMMENT 及 schema.object 范围语义 |
| Doris 4.1.3 | DDL、插入/读取/元数据、仅修改字段注释、只读覆盖、确认及不支持事务的明确拒绝 |
| Redis Stack | SET/GET/SCAN、只读拒绝、DB 8 别名、FLUSHDB/FLUSHALL 范围/覆盖/确认 |
| Elasticsearch 8.18.0 | 索引/文档/搜索/mapping、指定索引 DDL、多目标只读覆盖、bulk 重定向拒绝、全局空头 msearch |
| Kafka 3.9.1 | produce/peek/groups、空消息、Topic 只读覆盖 |

`scripts/test-ssh-mcp-loopback.py --expect-reuse` 使用独立 localhost sshd 完成独立授权、确认、直接/委托、连接复用、超时未知结果不重放、SFTP、任务和传输状态/取消/清理验收；未改用户 SSH 配置。

`scripts/test-mcp-package.py` 完成移动后的签名/资源/动态依赖、凭据 helper 调用方拒绝、stdio、HTTP 认证/Origin/token 轮换、Resources、实时撤权、六驱动加载及 MySQL/Doris 独立加载验收。

## 用户原连接验收

使用用户原有正式授权，未改权限或提取凭据：

- 原始 `SELECT 1 AS connection_ok, DATABASE() AS current_database, VERSION() AS server_version` 成功。
- `test_zfb_intelligence` 保持“指定数据库 + 完整访问”；新建唯一临时表、仅修改字段注释、刷新结构核对及删除均成功，缺少确认时正确拒绝。
- 临时表 `qc_mcp_perm_8f8a34246f4e4c` 已校验所有权、删除并确认不存在；未修改业务表或业务记录。
- `prod_zfb_intelligence` 的只读覆盖仍生效；针对唯一不存在测试表的 ALTER 在权限层拒绝。
- 原 Redis 连接保存的默认 `DB 8` 在未显式传库时 PING 返回 PONG。
- 完成安装后，通过固定正式启动入口再次执行原始只读 SQL，确认加载新版、`connection_ok = 1`、六驱动可加载且新客户端无需重连。
- 安装前后权限文件字节哈希相同。桌面主程序、外部驱动、SSH 插件及 Driver API 5 未替换。

## 安装与证据

正式 `MCP/Current` 已原子切换到 `Versions/local-permission-matrix-20261026-111132-aabe3a8b/QueryCraft MCP.app`，`Previous` 保留旧版。更新已管理的 `/Users/weilai/.agents/skills/querycraft`，四份文件与源码哈希一致，skill 校验通过。安装具有组件锁、旧版备份及失败回滚，未终止现有客户端进程。

本机证据：

- 完整回归：`/tmp/querycraft-permission-all-tests.log`
- 六驱动实库：`/tmp/querycraft-permission-six-live.log`
- 组件验收：`/tmp/querycraft-permission-package-acceptance.log`
- SSH 回环：`/tmp/querycraft-permission-ssh-live.log`
- 原连接验证：`/tmp/querycraft-permission-user-live.log`
- 安装后验证：`/tmp/querycraft-permission-install.log`
- 安装回执、临时对象清理回执、镜像 ID：`.build/mcp-permission-audit-iub1nrbi/`
- Xcode 结果包：`~/Library/Developer/XcodeBuildMCP/workspaces/QueryCraftPublic-21b5c5ce48ed/result-bundles/test_macos_2026-10-26T11-06-45-624Z_pid48630_58b94339.xcresult`

## 验证边界

“全组合”指上述有限权限维度的笛卡尔积，另配操作/越权边界用例，并非穷尽任意 SQL、REST、服务端插件或外部授权配置。预存视图、触发器和例程内部的隐藏访问仍需数据库原生角色隔离。MCP 不支持的会话控制、过程语句、Redis 命令和 DDL 事务不会因完整访问变为可用。

此次为本机 Intel 原生验证与本地组件替换，未执行 ARM 硬件、iOS/iPadOS 或公开发布验收。数据库页面和六个外部驱动二进制未改动。
