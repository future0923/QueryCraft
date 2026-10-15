# QueryCraft MCP 使用说明

QueryCraft MCP 是独立的原生 macOS 程序。安装后，数据库工具不依赖
QueryCraft 主窗口；只有 `open_table` 和 `execute_and_show` 需要打开桌面应用。
支持范围跟随已安装的 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 驱动。
不需要安装 Node.js、npm、Docker 或数据库代理中间件。

## 安装与接入

1. 打开 QueryCraft「设置 → MCP」，点击「安装」。安装器验证签名和签名者、
   在暂存目录执行 MCP 握手与资源自检，再替换本地安装；更新失败恢复旧包。
2. 启用 MCP，在「权限管理」选择连接或分组，限定数据库范围和执行权限，保存。
3. 使用已保存密码的连接，可点击「授权访问已保存的密码」，按系统钥匙串提示授权。
   后续后台 MCP 请求不会自动弹出钥匙串授权窗口。
4. 选择 stdio 或 HTTP，选择客户端后点击「一键添加」，重新连接 MCP 或重启客户端。
   Codex、Claude Code、Cursor、VS Code、OpenCode 支持自动添加和移除。
   其他客户端可复制配置；共提供 Claude Code、Cursor、CodeBuddy Code、ZCode、TRAE、VS Code、Windsurf、Codex、DeepSeek Harness、OpenCode、Pi、Cherry Studio 12 个配置入口。
   Codex 使用 TOML，DeepSeek Harness 使用 YAML，其他使用相应 JSON 结构。Pi 需安装 MCP 桥接扩展；Pi 和 DeepSeek Harness 当前仅提供 stdio 模板。

「一键添加／一键移除」只管理用户配置中的 `querycraft` 条目。已有文件在修改前生成
私有备份（文件名包含 `.querycraft-backup-`）；重复添加不会产生重复条目。
添加后可再次点击以更新 stdio/HTTP 方式或令牌。移除保留其他 MCP、客户端设置和数据库授权。
添加和移除后需重新连接 MCP 或重启客户端，使其重新读取配置；移除不会强制结束客户端已建立的会话。
如需立即撤销数据库访问，关闭「启用 MCP」并保存。
同名配置不属于本应用或被手动修改时，拒绝覆盖／移除；完全一致的手动复制配置可直接接管。
检测到文件损坏、符号链接或操作期间的外部修改时保留原文件，并提供错误反馈。

| 客户端 | 自动配置位置 |
| --- | --- |
| Codex | `$CODEX_HOME/config.toml`，默认 `~/.codex/config.toml`；需要本机 Codex CLI |
| Claude Code | `~/.claude.json`；设置 `CLAUDE_CONFIG_DIR` 时使用其中的 `.claude.json` |
| Cursor | `~/.cursor/mcp.json` |
| VS Code | 默认 Profile 的 `~/Library/Application Support/Code/User/mcp.json`；自定义 Profile 使用复制配置 |
| OpenCode | `$XDG_CONFIG_HOME/opencode/opencode.json`，默认 `~/.config/opencode/opencode.json`；支持绝对路径 `OPENCODE_CONFIG` |

Codex 配置由其原生命令行工具在隔离暂存目录解析与修改，保留模型、代理、其他 MCP 和 TOML 注释。
JSON 配置按语义合并并重新排版；带注释的 JSON / JSONC 暂使用复制配置，避免丢失注释。
项目级同名 MCP 可能覆盖用户配置，请在客户端检查实际生效的条目。

stdio 由客户端按需启动。HTTP 通过用户级 launchd 任务运行，关闭主程序后继续服务；
设置页可以启动、停止服务或轮换 Bearer Token。默认只监听 `127.0.0.1:5226/mcp`。
修改监听地址、端口或路径后，需要停止并重新启动 HTTP 服务；令牌及权限修改在后续请求生效。
停止服务不保存编辑中的设置，即使填写了无效端口也能停止，未保存的内容保留。
远程访问必须配置 Host / Origin 白名单。HTTP 本身不提供 TLS，跨网络部署应通过 HTTPS 反向代理接入。

安装位置为 `~/Library/Application Support/QueryCraft/MCP/QueryCraft MCP.app`；
Dev 使用独立的 `QueryCraftDev` 目录。更新使用当前桌面应用随附的 MCP 包。
卸载 MCP 保留连接、钥匙串密码和授权设置；HTTP 服务先停止，再移除可执行程序。
已经由客户端启动的 stdio 进程在断开连接前可能仍在运行；立即撤销访问请关闭「启用 MCP」并保存。

## 权限与六类驱动

| 驱动 | 授权范围 | 功能 |
| --- | --- | --- |
| MySQL / PostgreSQL | 数据库 | 表/视图、结构、SQL、批量执行、会话、事务、例程定义 |
| Doris | 数据库 | 表/视图、结构、SQL、批量执行；不提供事务保证 |
| Redis | 逻辑 DB 编号 | 键及结构、明确允许的读写命令；完整访问可显式确认清库 |
| Elasticsearch | 索引、别名或数据流名称 | 元数据、受权限约束的 REST 请求 |
| Kafka | Topic 名称 | 结构、消息读取、发送、消费组和积压；读取不提交消费偏移 |

未安装或缺少对应能力的驱动返回明确错误。API 5 是当前驱动要求，不兼容的旧驱动
不会因为 MCP 启动而被删除或替换。请在桌面驱动管理中安装兼容版本。

权限取全局、分组、连接、数据库规则中最严格的一项，例外只能收紧，不能提升全局权限。
“访问权限”使用标准弹出菜单切换连接、数据库与对象、权限限制、工具与执行，设置项目可直接访问。
连接授权使用系统表格勾选，支持搜索和分组授权；数据库和权限限制使用连接菜单选择目标，
无需在嵌套侧栏或步骤向导间跳转。客户端通过标准菜单选择；配置、Skill、高级设置和工具分组
直接铺开显示，通过页面滚动查看。字号与其他设置页一致，使用系统正文／说明文字和常规尺寸控件；
配置预览按内容高度展示 3～6 行，超出后滚动查看，底部操作区保持紧凑。
同一设置窗口内切换页面保留 MCP 的页签、连接选择和未保存的编辑，不会每次重新初始化。
进入时先在后台读取基础设置，随后独立检查签名、版本和 HTTP 状态；检查期间已加载的设置可以继续编辑。
「重新检查」会更新运行状态及连接列表，保留未保存的权限；运行状态检查失败也不会清空已加载的设置。
数据库范围可选「全部／指定／禁止」；切换模式保留已选名单。指定名单为空或选择禁止时，所有驱动均拒绝数据库访问。
连接授权和数据库授权分别校验，关闭 MCP 默认拒绝所有访问；工具和资源读取遵循同一策略。
数据库列表可以发现、搜索和勾选，也可以手动填写精确名称。

- **只读**：拒绝写语句；MySQL / PostgreSQL 查询使用数据库只读事务，结束或失败时回滚；显式只读会话事务同样以 `START TRANSACTION READ ONLY` 开始。
- **数据读写**：允许插入及带可验证过滤条件的更新、删除，拒绝 DDL。
  当前可验证过滤为字段与常量比较、以 AND 连接；恒真条件及复杂谓词需完整访问。
- **完整访问**：可执行 DDL 等高级操作。破坏性 SQL、删除连接、清库及危险 REST 操作
  还需在调用中显式设置 `confirm_high_risk: true`。客户端仍应向用户展示操作内容。

数据库范围校验检查直接引用的数据库/对象，不能替代数据库账号权限。
视图、别名、函数以及服务端配置可能引用其他数据；需要严格隔离时应使用数据库侧最小权限账号。
受限 SQL 拒绝无法验证的自定义函数、动态语句及部分元数据语法，建议使用专门的元数据工具。
Doris 没有与 MySQL / PostgreSQL 相同的事务只读保证。Elasticsearch 的受限请求拒绝跨索引查找、
脚本、pipeline、编码路径和无法验证的路由；Redis 不开放订阅、阻塞命令、任意 Lua 或连接状态控制。

## 工具与结果

所有工具以 `querycraft_` 开头，可在设置中逐项关闭：

- 元数据：`list_connections`、`list_databases`、`list_tables`、`describe_table`、`get_schema_context`、`list_routines`、`get_routine_source`。
- SQL：`execute_query`、`execute_batch`、`open_session`、`close_session`、`begin_transaction`、`commit_transaction`、`rollback_transaction`。
- Redis：`execute_redis_command`；Elasticsearch：`execute_request`。
- Kafka：`peek_messages`、`send_message`、`consumer_groups`。
- 连接：`add_connection`、`duplicate_connection`、`remove_connection`。
- 桌面：`open_table`、`execute_and_show`；驱动发现与统一调用：`plugin_list`、`plugin_tools`、`plugin_call`。

资源 URI 包括 `querycraft://connections`、`querycraft://connections/{connection_id}/databases`，
以及 `tables`、`table-schema` 模板。权限和工具开关与对应工具一致。

会话及最大会话数限制属于创建它的 MCP 客户端；HTTP 服务最多接纳 32 个协议会话。每个会话同时只能执行一个操作，空闲后自动关闭。
修改连接配置或执行级别后要重新打开会话；权限撤销或配置损坏后仍可关闭/回滚已有会话。
SQL 脚本先整体解析和校验，再逐条执行；执行中每条语句重新检查权限。原子批量执行仅限支持事务的
MySQL / PostgreSQL 的查询和 DML。两类驱动的事务中均不执行 DDL；DDL 仅限完整访问下独立执行。
会话控制和无法分类的 SQL 在执行前拒绝，避免驱动执行成功后无法跟踪事务状态。
错误、取消和超时不会自动重试写操作。

查询超时留空时继承 QueryCraft 的全局查询设置（保存 MCP 设置时同步），0 表示不限时，正整数覆盖。
当前连接模型没有单独的连接超时设置，因此不显示不存在的“继承连接配置”。
连接建立、提交、回滚仍有独立超时保护；不限时查询仍受连接数与结果大小约束。

结果保留 NULL、列类型、大整数/小数文本精度与二进制预览，受最大行数、结果字节数、
单元格长度及超时限制，截断会明确标记。`execute_and_show` 只执行一次，桌面显示收到的结果快照，
复用 QueryCraft 原生结果表格、查找、复制和导出；快照不可直接编辑。
桌面展示失败会保留已执行的查询结果并返回 `display_status: failed`，不要为重试展示重复执行 SQL。
例程定义来自 `information_schema.routines`，权限不足可能返回 NULL，也受服务端定义长度限制。

## AI 调用体验与可选 Skill

MCP 初始化会提供连接发现、结构核对、限量查询、长字段展开和失败处理说明。
工具附带只读/破坏性提示；这些提示不替代服务端权限检查。

- `get_schema_context` 默认返回 8 张表的紧凑字段上下文，可用 `max_tables`（最多 20）、
  `max_chars` 调整；`format: "detailed"` 返回含 DDL 的结构。需要完整单表结构时用 `describe_table`。
- 字符串默认每格 200 个字符，展开返回 `offset`、`next_offset` 和 `truncated`。
  先把查询缩小到目标行和列，再用 `cell_char_offset` 续读，避免反复拉取整张结果表。
- 设置支持直接工具、按需发现和两者同时。按需模式用 `plugin_list` →
  `plugin_tools(connection_id)` → `plugin_call`，避免一次载入全部驱动参数。
  工具权限仍在调用时校验；会话回滚和关闭保留直接入口。
- 元数据缓存默认 30 秒，可设置为 0 关闭；`refresh: true` 绕过缓存。
  缓存绑定连接配置、数据库、schema、参数和权限快照；当前运行时执行 DDL 前后失效。
  其他客户端或外部程序的变更最多等待缓存 TTL，需要立即确认时强制刷新。
  Redis 键不缓存，SQL 结果、消息内容和消费组积压也不缓存。
- 最多保留 4 个空闲元数据连接，60 秒回收，可配置为 0 关闭。
  普通 SQL 继续使用独立连接，跨调用复用通过显式会话进行；避免连接状态串扰。
- 错误返回结构化 `code`、`message`、`recovery` 和 `automatic_retry: false`。
  超时、取消或输出过大可能发生在写入完成之后，不要自动重试写入。
  凭据问题分别返回 `CREDENTIAL_ACCESS_DENIED`、`CREDENTIAL_AUTHORIZATION_CANCELLED`、
  `CREDENTIAL_UNAVAILABLE`。在设置中重新授权或解锁钥匙串；缺失的密码需到连接编辑器重新保存。
  「授权完成」只会在所选连接的已保存凭据全部读取成功后出现。

「调用记录」保留最近 500 条调用摘要，包括工具名、连接 ID、耗时、结果大小与错误码。
不保存 SQL、参数、凭据、原始异常或结果正文。可关闭记录或清空已有记录。
各独立进程共享本机记录，设置页保留已有列表直到重新检查成功。

QueryCraft Skill 独立发布和下载，主程序不内置 Skill 资源。设置页提供 Shared（`.agents/skills`）、
Codex（`.codex/skills`）、Claude Code（`.claude/skills`）安装目标以及更新/卸载入口。
Skill 教授六类驱动的工作流，依赖已配置好的 MCP；不需要 QueryCraft CLI。
安装器通过文件摘要识别自己管理的文件；发现本地修改、额外文件或符号链接时保留文件。
不同客户端对 Skill 的发现方式不同，只有支持对应 Skill 目录的客户端会加载；MCP 始终可单独使用。

## 构建与验证

使用 XcodeBuildMCP 构建 `QueryCraft` scheme 后：

```bash
python3 scripts/package-mcp.py \
  --build-dir .build/DerivedData/Build/Products/Debug \
  --output '/tmp/QueryCraft MCP.app' --development
python3 scripts/test-mcp-protocol.py '/tmp/QueryCraft MCP.app/Contents/MacOS/querycraft-mcp'
```

独立包使用 C 启动器动态链接 `QueryCraftFeature.framework`，与驱动保持同一模块身份。
SwiftPM 的 `querycraft-mcp` 用于开发测试，不是分发包；不能直接用它替代签名的独立包。
`--self-test` 验证协议握手与 SQL 资源，`--check-drivers --data-dir <隔离目录>` 列出实际加载的驱动。
Dev 主程序安装不再附带 MCP；release 构建仅在 MCP 有相关改动时独立打包。协议测试不读取用户连接或访问真实数据库。

### 新增连接的认证与传输

`add_connection` 可指定 `authentication`（`usernamePassword`、`apiKey`、`none`）、
`tls_mode`（`disabled`、`required`、`verifyCA`、`verifyIdentity`），以及 Kafka 的
`kafka_sasl_mechanism`（`PLAIN`、`SCRAM-SHA-256`、`SCRAM-SHA-512`）。API Key 仅适用于
Elasticsearch。未提供凭据的 Kafka / Elasticsearch 默认使用无认证；TLS 默认仍为
`verifyIdentity`，本机明文测试服务须显式选择 `disabled`。密码或 API Key 通过 `password`
参数存入钥匙串，不写入连接配置或调用历史。

### 开发验收

六驱动真实服务验证使用 `scripts/test-mcp-live.py`，需要 Docker，自动创建并清理独立的
本机测试容器。`scripts/test-mcp-desktop.py` 验证签名安装、更新回滚、launchd 和原生页面
离屏渲染，并检查宿主退出后服务可用及已保存任务重新启动；加 `--drivers-dir` 可检查桌面加载六类驱动。
`scripts/test-mcp-lifecycle.py` 验证客户端退出、并发断开重连及服务重启后的会话失效。
实库脚本加 `--drivers mysql,doris --stress` 验证两库并发及断开时的事务回滚。
`scripts/test-mcp-credentials.py` 仅操作新建的临时钥匙串条目并清理；
`scripts/test-mcp-clients.py` 使用已安装的客户端 CLI 检查生成配置。
`scripts/test-mcp-codex.py MCP可执行文件 --codex Codex可执行文件` 使用隔离配置验证 Codex 真正的聊天 MCP 连接、工具发现与调用；
加 `--transport http` 验证 HTTP。测试只创建临时协议上下文，不发送模型请求。具体覆盖与限制见
[MCP_IMPLEMENTATION.md](MCP_IMPLEMENTATION.md)。

## 独立组件安装与更新

MCP 与 Skill 的版本和兼容范围由 `Components/versions.json` 声明，各自发布到资源服务 `/components/`。设置页的安装/升级从签名目录下载，不再复制主程序内部安装包。未发布或网络失败显示错误并保留现有安装与授权。

MCP 目录使用 `Versions/<version>-<build>/QueryCraft MCP.app` 和原子切换的 `Current`。客户端命令固定为 `MCP/bin/querycraft-mcp`，启动器校验签名后 exec 到真实版本路径。已有会话使用旧版本的框架和资源，新连接使用新版本。主程序关闭后也可调用：

```sh
querycraft-mcp --check-updates --data-dir /absolute/data-directory
querycraft-mcp --update --data-dir /absolute/data-directory
querycraft-mcp --rollback --data-dir /absolute/data-directory
querycraft-mcp --update-skill --skill-target codex --data-dir /absolute/data-directory
```

也可用 `--skill-destination /absolute/skill-directory` 指定项目或其他客户端位置。更新/回退时若该配置的 HTTP 服务正在运行，使用已保存配置重启；stdio 客户端重新连接后使用新版本。旧客户端可继续使用原路径，在设置页重新添加后迁移到固定入口。

Skill 按兼容 MCP 范围选择版本。MCP 回退后，再更新 Skill 会选择仍兼容的版本；对仍兼容的 Skill 不自动降级。安装和卸载保留本地修改；MCP、Skill 和主程序不要求版本号一一相同。六类驱动仍按现有 Driver API 独立安装，本次组件拆分不增加驱动版本。
