# SSH 插件与 MCP

SSH 使用独立的 `QueryCraftSSH.bundle`，底层为 libssh2。主程序和 MCP 宿主只链接版本化的 C 接口，不链接 libssh2 或 OpenSSL。SSH 不属于 `DatabaseType`，不改变现有 Driver API 5 和六类数据库驱动。

## 基础工具

- `querycraft_ssh_list_connections`：列出明确授权的 SSH 连接。
- `querycraft_ssh_add_connection`：保存连接，密码或私钥口令存入现有 Keychain 凭据服务；不自动授权。
- `querycraft_ssh_remove_connection`：删除已授权连接及其保存凭据，要求完整访问及明确确认，活动命令期间拒绝删除。
- `querycraft_ssh_test_connection`：验证固定主机指纹并完成认证，不执行命令。
- `querycraft_ssh_execute`：执行一个远程命令，返回 stdout、stderr、退出码和截断状态。
- `querycraft_plugin_list` 包含已加载的 SSH 插件。`querycraft_plugin_tools` / `querycraft_plugin_call` 通过 `plugin_id: "ssh"` 发现和调用上述工具，权限与直接调用一致。

0.4 及以后插件可复用经认证连接（见下文）；命令使用 exec 通道，关闭标准输入，不分配 PTY，不保留工作目录或环境变量。不自动重试任何命令。超时、取消或断线不能证明远程进程已经停止，失败消息会提示检查实际结果。调用方取消和 MCP 退出会取消本地执行；维护周期也检查授权撤销。

当前支持密码认证和本地私钥认证（包括加密私钥），主机指纹必须为经独立验证的 OpenSSH `SHA256:...` 格式。0.6.0 已支持本机 SSH agent、保存的跳板链和常用 SSH config 导入（见下文）。当前未实现键盘交互/MFA、SSH agent 转发、持久交互 Shell 与终端界面。libssh2 具备部分相关底层能力，但不能把这些尚未接入的功能视为已支持。

## 构建插件

在仓库根目录执行：

```sh
python3 scripts/build-ssh-plugin.py --arch x86_64 --identity "<本地签名身份>"
python3 scripts/build-ssh-plugin.py --arch arm64 --identity "<本地签名身份>"
```

默认构建固定校验和的 libssh2 1.11.1 和 OpenSSL 3.6.3，以静态库包含在插件中。插件最低 macOS 15，产物位于 `.build/ssh-plugin/packages/<架构>/QueryCraftSSH.bundle`，并生成对应 ZIP。构建日志位于 `.build/ssh-plugin/<架构>/build.log`。插件内附 libssh2 和 OpenSSL 许可声明。此版本选择应随后续上游安全更新重新评估和验证。

本地快速开发可指定 `--openssl-prefix /usr/local/opt/openssl@3`，使用已有静态 OpenSSL 开发安装；此模式会记录实际 OpenSSL 版本，不能当成默认依赖版本的可重现发布构建。两种模式都不依赖用户机器上的 Homebrew 动态库。

未指定身份时生成 ad-hoc 开发签名。Debug 宿主沿用现有驱动的开发签名规则；正式宿主接受与自身相同叶证书的插件签名（支持 QueryCraft 自签名分发），或符合现有 Apple Team 验证规则的签名。插件签名在加载和安装前验证，ABI 必须为 1。构建脚本分别生成单架构产物；发布、签名、双架构验收仍须遵循 `RELEASE_PROCESS.md`，本次实现不自动发布。

## 本地安装

桌面入口为设置 → 插件 → **SSH · libssh2** → 管理。可选择签名的 `QueryCraftSSH.bundle` 或构建生成的 ZIP，安装前验证代码签名、架构与 ABI。卸载只停用插件，保留服务器账号与凭据；安装、更新、卸载后重新连接 stdio MCP 客户端。

使用本次源码编译的独立 MCP 可执行文件：

```sh
/absolute/querycraft-mcp --data-dir /absolute/QueryCraftData \
  --install-ssh-plugin /absolute/QueryCraftSSH.bundle
/absolute/querycraft-mcp --data-dir /absolute/QueryCraftData --check-ssh-plugin
```

安装器把插件复制到 `Plugins/SSH/Versions/<唯一版本目录>/QueryCraftSSH.bundle`，验证后原子切换 `Current`。现有进程保留旧库，新连接的 MCP 进程使用新版本；安装后重新连接客户端。旧目录保留，不覆盖正在使用的二进制。无插件时不会暴露直接 SSH 工具，六类数据库仍可独立工作。

## 在线下载安装

插件页的“下载并安装”读取独立组件源下的 `ssh-x86_64.json` 或 `ssh-arm64.json`，采用与 MCP/Skill 相同的 Ed25519 签名目录格式，组件类型为 `ssh`。下载时核对声明大小、SHA256、宿主版本和架构，解压后再次核对插件签名、版本、构建号及 ABI 1。失败保留现有版本；下载进度在固定区域显示。

生成待分发目录（仅准备产物，不上传）：

```sh
python3 scripts/package-ssh-catalog.py \
  --packages .build/ssh-plugin/packages \
  --output .build/ssh-plugin/catalog-staging \
  --base-url https://your-component-host.example/components/ \
  --key-file /absolute/path/to/ed25519-private-key
```

输出双架构不可变 ZIP、`.package.json`、`.release.json` 和两个架构目录。签名私钥必须对应宿主配置的组件公钥；不指定 `--key-file` 时沿用既有 Sparkle/组件签名工具的本机 Keychain 配置。

生产版使用 `QCComponentCatalogBaseURL` / `QUERYCRAFT_COMPONENT_CATALOG_BASE_URL`；Dev 使用独立 `QCDevelopmentComponentCatalogBaseURL` / `QUERYCRAFT_DEV_COMPONENT_CATALOG_BASE_URL`，未配置时不回退到生产。线上目录未发布或不可用时，页面仍显示本地安装状态并提供本地导入。当前代码与本地产物不代表公共服务器已部署 SSH 分发支持；公开发布需按仓库发版流程另行完成。

## 连接与授权

在设置 → **SSH 服务器** 中添加、编辑、测试和删除服务器账号。支持密码、本地私钥及加密私钥口令；编辑时凭据留空保留原值，切换到无口令私钥会清除旧凭据。密码只在本机 SecureField 中输入并保存到共享 Keychain 服务，独立 stdio MCP 根据连接 ID 读取同一凭据。

先填写地址、端口、用户名及认证方式，再点击“读取指纹”或填写管理员提供的指纹。网络读取结果本身不可信，必须通过可信渠道核对后勾选确认；指纹或地址变化后重新确认。测试只验证服务器身份与账号认证，不执行命令，可在保存前进行。

每个账号可选择“禁止 MCP”“允许连接”“允许执行命令”，并独立选择文件读取、上传/下载与文件管理。保存即更新该账号的独立授权，不会自动启用 MCP 或提高全局上限。删除时先撤销 MCP 授权，再清理凭据和连接。界面中的测试不依赖 MCP 的启用状态。

也可通过 MCP 添加连接，或在数据目录的 `ssh-connections.json` 配置连接（文件权限应为 `0600`）：

```json
[
  {
    "id": "11111111-1111-4111-8111-111111111111",
    "name": "开发服务器",
    "host": "server.example.com",
    "port": 22,
    "username": "deploy",
    "hostFingerprint": "SHA256:<经独立验证的43字符base64摘要>",
    "privateKeyPath": "/absolute/path/to/id_ed25519",
    "storesCredential": false
  }
]
```

以上指纹是占位符，必须替换为真实值。可由服务器管理员在服务器端执行 `ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub -E sha256` 提供，并经可信渠道核对。指纹必须对应实际协商的主机密钥；当前 libssh2 优先 ECDSA，其次 Ed25519，随后 RSA。只提供 Ed25519 的服务器应核对其 `ssh_host_ed25519_key.pub`。不要把未经核对的网络扫描结果自动视为可信主机。当前尚未提供手动选择主机密钥算法的配置。

私钥路径必须绝对路径。无口令私钥使用 `storesCredential: false`；密码或私钥口令通过 `ssh_add_connection` 的 `password` / `passphrase` 保存，不能写入 JSON 文件。私钥文件必须能被独立 MCP 进程读取。

在现有 `mcp-policy.json` 中加入下面的可选字段，保留文件原有其他配置：

```json
"ssh": {
  "connectionIDs": ["11111111-1111-4111-8111-111111111111"],
  "executionConnectionIDs": ["11111111-1111-4111-8111-111111111111"],
  "fileReadConnectionIDs": [],
  "fileTransferConnectionIDs": [],
  "fileManagementConnectionIDs": []
}
```

`connectionIDs` 允许发现和测试该服务器；`executionConnectionIDs` 额外允许执行命令。执行还要求现有全局 `mode` 为 `high_risk_write`（完整访问），并在确认具体命令后传 `confirm_high_risk: true`。任意 Shell 命令不会通过关键词猜测降级成只读操作。数据库的 `allConnections`、分组授权和连接名单均不会授予 SSH 权限。旧策略没有 `ssh` 字段时默认拒绝 SSH 访问。桌面通过 SSH 服务器页管理这些独立字段；MCP 设置的保存会合并最新 SSH 授权，避免不同页面互相覆盖。

调用示例：

```json
{
  "name": "querycraft_ssh_execute",
  "arguments": {
    "connection_id": "11111111-1111-4111-8111-111111111111",
    "command": "cd /srv/myapp && tail -n 100 logs/application.log",
    "confirm_high_risk": true,
    "timeout_seconds": 15,
    "max_output_bytes": 16384
  }
}
```

默认总超时 30 秒，最多 300 秒，同时受现有 MCP 查询超时上限约束；查询超时为 0 时仍保留 SSH 自身总超时。默认 stdout/stderr 合计保留 16 KiB，最大 1 MiB，同时根据 MCP JSON 结果预算收紧。超出部分继续读取并丢弃，避免远端阻塞；结果带总字节数与 `truncated`。文本展示中非法 UTF-8 会替换，不保证二进制输出无损。每个命令有独立的通道和本地输出缓冲区。

## 文件工具（SSH 插件 0.2.0）

基础 ABI 仍为 1，新增可选 SFTP 扩展 1。旧插件保留连接、命令与长任务能力，不展示文件工具；新插件安装后需重新连接 stdio 客户端。

| 工具 | 用途 | 账号授权 |
| --- | --- | --- |
| `ssh_list_files` | 分页浏览目录，返回名称与真实属性 | 连接 + 文件读取 |
| `ssh_stat_file` | 查看文件/目录/符号链接属性 | 连接 + 文件读取 |
| `ssh_read_file` | 按字节偏移读取，支持 UTF-8 / base64 | 连接 + 文件读取 |
| `ssh_upload_file` | 本机普通文件流式上传 | 连接 + 传输 + 完整访问 + 确认 |
| `ssh_download_file` | 远程普通文件流式下载到本机 | 连接 + 文件读取 + 传输 + 完整访问 + 确认 |

`fileReadConnectionIDs` 与 `fileTransferConnectionIDs` 默认空，升级不会扩大原有账号权限。文件读取不需要任意命令执行授权；读取范围为该 SSH 账号有权访问的路径，不是目录沙箱。执行授权本身不代替 SFTP 文件授权，但任意 Shell 命令仍可访问该账号的文件。

文件路径必须为绝对路径。本机路径属于运行 MCP 的机器。默认拒绝覆盖目标；传输要求确认两端的具体路径，覆盖还需明确指定 `overwrite: true`。默认大小上限 64 MiB，最多 1 GiB；流式传输不把文件内容放入 MCP JSON。上传只接受普通本机文件，拒绝最终路径符号链接与 FIFO。临时文件以 0600 创建，完成后发布到目标；覆盖上传要求服务器支持 POSIX rename，不支持时保留原目标。目标文件权限不会继承旧目标。上传摘要对应读取的源字节，下载摘要对应接收的字节，没有额外重读远端做端到端摘要校验。

传输检查源大小与修改时间，不能保证正在被其他进程改写的文件获得一致快照。连接中断时可能遗留 `.querycraft-<UUID>.upload` 临时文件；目标发布结果不确定时先检查目标，禁止自动重试。目录按服务器顺序分页，目录变化会影响偏移；非法 UTF-8 名称保留 `name_base64`，当前工具路径参数只支持 UTF-8。二进制文件或截断 UTF-8 字符的窗口使用 `encoding: "base64"`。返回缺失属性为 null，不按名称猜测。

## 文件管理与恢复（SSH 插件 0.3.0）

基础 ABI 1 与 SFTP 扩展 1 保持不变，新增独立可选管理能力 1。新宿主连接 0.1 插件时隐藏所有文件工具，连接 0.2 插件时隐藏文件管理和临时文件清理工具；升级插件后重连客户端。0.3 插件继续接受旧宿主的原有请求。

| MCP 方法 | 行为 |
| --- | --- |
| `ssh_create_directory` | 创建单个 0700 目录；父目录须存在，不递归创建 |
| `ssh_move_path` | 移动或重命名单个路径，不覆盖已有目标；跨文件系统由服务器决定支持情况 |
| `ssh_remove_path` | `kind=file` 删除一个文件/最终符号链接，`kind=empty_directory` 只删除空目录；不递归 |
| `ssh_list_transfers` | 分页列出当前账号在本机登记的未完成/待核对传输；返回 transfers、next_offset、total_records |
| `ssh_inspect_transfer` | 核对指定 transfer_id 的临时路径和目标元数据，返回 inspection_token |
| `ssh_cleanup_transfer` | 核对 token 后只清理该记录的临时文件并移除登记，始终不修改目标文件 |
| `ssh_forget_task` | 经明确确认只移除本机任务登记，不终止任何进程，也不删除远端文件 |

文件管理采用独立 `ssh.fileManagementConnectionIDs`，升级默认为空。可在 SSH 账号和 MCP 连接权限的同一份授权中开启。原有上传下载权限不会自动获得任意文件删除权限。三种管理操作均要求完整访问及确认具体路径；拒绝根目录、尾随斜线、空路径组件和 `.`/`..`。最终符号链接的移动/删除作用于链接本身，不访问其目标；路径不是目录沙箱，中间组件仍按服务器文件系统解析。

传输恢复使用既有传输授权，清理自身已登记的临时文件不需要任意文件管理授权。完整访问和 `confirm_high_risk=true`、`acknowledge_outcome_unknown=true` 仍然必须提供。`ssh_list_transfers` 支持 offset（0–512）、max_records（1–100，默认 20），受结果字节预算约束。权限按精确账号和服务器指纹绑定，不可查看其他账号的记录。

0.3 宿主与插件对上传、下载先写入本机 `ssh-transfers.json`（0600，最多 512 条），生成同目录独占的 `.querycraft-<UUID>.transfer` 临时路径，早期宿主成功后移除登记；当前宿主保留成功结果，失败或客户端崩溃保留待核对登记（见下文进度与结果查询）。上传临时路径位于服务器，下载临时路径位于运行 MCP 的本机。原插件 0.2 继续支持传输，但不生成可管理的下载临时路径；历史未登记文件不自动扫描或批量清理。

清理流程为：列出记录 → 核对临时/目标信息 → 明确未知的目标结果不能据此判定失败 → 使用返回的 token 确认清理。正在进行的传输持有跨进程锁，核对/清理均拒绝。元数据变化时必须重新核对，临时路径变为目录、符号链接或特殊文件时拒绝清理。远端 SFTP 不提供条件删除原语，因此 token 是操作前元数据核对，不是远端事务快照；用户不应同时手动改写同一个临时路径。目标摘要和完整性未自动验证，禁止因清理完成而自动重跑传输。

未知任务仍须人工核实。确认不再需要本机跟踪时，可调用 `ssh_forget_task` 并传 `acknowledge_task_may_be_running=true`，要求执行授权、完整访问和逐次确认。该方法不会向服务器发信号，返回 `remote_task_stopped=false`、`remote_files_removed=false`。正在进行的本机任务操作持有锁，不能同时忘记其记录。已确认结束的任务继续使用 `ssh_remove_task` 清理远端日志与登记。

## 长任务（使用服务器已有 Shell）

| 工具 | 用途 |
| --- | --- |
| `ssh_start_task` | 启动后台任务，返回 `task_id` |
| `ssh_list_tasks` | 列出当前账号在本机登记的任务，不代表实时状态 |
| `ssh_task_status` | 查询状态、退出码及输出字节数 |
| `ssh_task_output` | 按流和字节偏移读取日志，返回 base64 与展示文本 |
| `ssh_cancel_task` | 请求终止受监督的进程组，再查询实际状态 |
| `ssh_remove_task` | 清理已结束任务的日志和登记，拒绝运行中/未知任务 |

六个工具都要求连接与显式命令执行授权；启动、取消和清理还需要完整访问与 `confirm_high_risk: true`。全局只读模式可以查询已授权任务的状态和日志，不可启动或取消。任务使用服务器已有的 `/bin/bash` 及标准系统工具（nohup、base64、dd、wc、grep、date、sleep、mkfifo 等），通过 `/bin/sh` 执行命令。无需 Python、额外安装包或下载远端运行时；没有监听端口、PTY 或交互输入。启动前检查工具是否已经可用，缺少时明确返回不支持，不会自动安装。普通 SSH 与 SFTP 不依赖后台任务工具链。

监督器、命令和日志位于服务器账号的 `~/.querycraft-ssh-tasks/shell-v1/<任务UUID>`（0700）。默认工作目录为账号 home，也可指定绝对路径。MCP 断开不结束任务；服务器重启、监督器被杀或命令主动退出会影响任务。超过 10 秒未更新心跳时状态按 unknown 返回，不据此杀进程或自动重启。默认执行上限 3600 秒，最多 86400 秒，与单次 SSH RPC 超时独立。stdout/stderr 合计默认最多保留 4 MiB，可设 1 KiB–64 MiB，超出继续排空并标记截断。取消/超时向监督器创建的进程组发送 SIGKILL；脱离该进程组的进程可能继续运行。主命令退出后最多额外排空 2 秒，后台后代继续持有管道时标记输出不完整。

本机 `ssh-tasks.json` 以 0600 保存 ID、账号绑定和创建时间，不保存命令或凭据，最多 512 条。账号绑定包含服务器、端口、用户名和指纹，重命名/凭据轮换不影响任务，改为其他服务器后不展示旧任务。服务器同时最多 16 个运行中/未知任务；未知状态需要人工核实，不自动重启或清理。任务目录的 `meta.json` 含命令，因此不要把密码直接写进命令。

启动先登记再提交。超时或不完整响应返回 `state: "unknown"` 与任务 ID，必须检查该 ID，不能直接重跑。监督器不存在时也不能断言命令已经结束。`ssh_task_output` 的 EOF 只对已结束任务为最终 EOF；持续读取使用返回的 `next_offset`。

## 验证

```sh
python3 scripts/test-ssh-plugin.py --bundle /absolute/QueryCraftSSH.bundle
```

此脚本在当前用户下启动临时 loopback OpenSSH，使用临时 host/client 私钥与高位端口，结束后停止服务并删除配置，不修改系统 sshd 或用户账号。覆盖固定指纹、普通/加密私钥、失败认证、stdout/stderr/退出码、stdin EOF、大输出排空、超时、取消及并发连接，并验证 SFTP 属性、目录、字节窗口、流式二进制往返、摘要、覆盖、大小上限与原目标保留。Swift Testing 的 `MCPSSHTests` 覆盖独立授权、间接调用、保存凭据、结果预算、授权读取竞态和退出取消。真实 MCP 协议调用、安装验收及当前运行结果记录在 `progress.md`。

`SSHSettingsTests` 覆盖本机账号凭据生命周期、编辑冲突、保存失败补偿、认证方式切换、授权合并和加载失败保留内容。`scripts/test-ssh-desktop.py --mcp /absolute/DevMCP.app --output /absolute/test-output` 验证签名目录下载、错误恢复及原生明暗界面。可额外指定 `--live-host`、`--username`、`--fingerprint`，通过隐藏输入读取测试密码，验证桌面保存账号后独立 stdio MCP 使用同一 Keychain 凭据，结束后删除测试账号和凭据。

当前宿主为 macOS。插件 C ABI 和业务模型不依赖终端界面；iOS/iPadOS 尚未接入，不能将此 macOS 动态插件安装方式视为移动端已完成。

长任务监督器单测：`python3 scripts/test-ssh-tasks.py`。完整实机验收：`python3 scripts/test-ssh-mcp.py --mcp /absolute/querycraft-mcp --bundle /absolute/QueryCraftSSH.bundle --host <host> --username <user> --fingerprint <verified> --extended`，密码使用隐藏输入；只建立独立 UUID 临时文件及有上限的测试任务，并在结束时清理。

临时 loopback SSH 全链路：`python3 scripts/test-ssh-mcp-loopback.py --mcp /absolute/querycraft-mcp --bundle /absolute/QueryCraftSSH.bundle`。它使用临时 OpenSSH 配置与密钥，验证断开 stdio 后任务继续、重连读取输出、取消、超时和清理。测试脚本的 Python 仅在开发机上用于验收；后台任务的远端执行不调用 Python。旧 Python 后端任务目录不自动迁移、删除或终止，需先人工核对旧任务；新后端使用独立 shell-v1 目录。删除或改变账号服务器信息前应先完成/清理其任务；失去原账号后不能继续查询原服务器任务。

## 双入口授权

SSH 账号和凭据只配置一次。设置 → SSH 服务器的账号编辑器，以及 MCP → 连接权限 → SSH 服务器授权，读取和保存同一份 `mcp-policy.json` 账号授权。MCP 入口的“保存授权”立即生效，不会提交其他未保存的 MCP 设置。两处本机页面保存后同步显示；同时编辑同一账号时，旧授权不能覆盖已保存的新授权，冲突需重新打开编辑器。

全局工具开关是所有账号共用的总开关；启用某个工具不自动授予账号访问权。全局上限继续约束账号授权。数据库连接范围/连接权限只作用于六类数据库，不会把“全部数据库连接”扩展成 SSH 授权。

## MCP 任务与传输

任务、日志、取消和传输恢复只通过 MCP 工具操作。SSH 服务器页面保留账号、凭据及授权配置，不提供“任务与传输”面板入口。两处授权仍使用同一份设置，账号无需重复配置。

新启动任务的监督器按单次管道读取及时写入短日志，不等待输入块凑齐或任务退出；已有远端任务的监督器不会自动替换。传输所有者继续监听本机私有取消标记并保留未知结果登记；取消不代表目标未发布，也不会回滚或自动重传。

## 连接复用（SSH 插件 0.4.0）

可选连接池扩展 1 不改变基础 ABI 1、SFTP 1 或现有 23 个 SSH 方法。新宿主配合 0.4.0 插件自动复用连接，旧插件保持单次连接方式；旧宿主调用新版插件的原有入口也保持单次连接行为。升级宿主和插件后重连 stdio 客户端，无需重复配置账号或安装服务器软件。

复用的是已认证的 SSH 连接；每条命令仍创建独立 exec 通道，文件操作使用独立 SFTP 子系统，不保留上条命令的工作目录或环境状态。

每个运行时的 SSH transport 持有独立连接池，最多 8 条连接，每次租用由一个工作线程独占，多个命令不同时操作同一个 libssh2 session；各个 stdio 进程之间不共享。空闲 60 秒或总寿命 5 分钟后回收，维护周期内清理空闲连接，退出时关闭；并发达到池上限时返回容量错误，遵守已有的全局并发上限。

缓存身份包含连接 UUID、地址/端口、用户名、固定指纹、认证方式、密码/口令及私钥实际内容。每次调用仍读取当前凭据并核对授权，不能借已认证连接绕过新密码、口令或私钥认证。空闲条目只保存带池内随机盐的认证摘要，不保存明文密码或私钥。账号/授权/工具开关/全局访问上限变化时在下次 SSH 调用及维护中失效连接池；正在使用的旧连接标记为不再缓存，撤销的活动调用按既有维护链路取消。

只有成功并完成通道/子系统清理的连接才可回收。错误、超时、取消、未知结果及清理不完整的连接直接关闭。操作前发现空闲 TCP 已关闭，可以先新建连接；若提交后断线，则返回本次失败/未知结果，绝不重放命令或传输。下一次明确调用建立新连接。连接复用不会保证命令跨网络故障继续运行；后台任务仍通过已有 task_id 查询实际状态。

实现遵守 [libssh2 的线程安全要求](https://libssh2.org/)：句柄不同时跨线程使用。SSH 服务器设置仅负责账号、凭据与授权，不增加任务或传输操作面板。

## 传输进度与结果（SSH 插件 0.5.0）

仅增加 MCP 工具，不增加任务或传输页面。当前共 27 个 SSH 工具。可选进度扩展 1 保持基础 ABI 1、SFTP 1、文件管理 1 和连接池 1 不变；旧宿主仍可调用新版插件，新宿主使用旧插件时如实返回 `progress_available: false`，运行中的未知字节数为 null。

| 方法 | 行为 |
| --- | --- |
| `ssh_start_transfer` | direction 为 upload/download，立即返回 transfer_id；其余路径、覆盖、大小、超时和确认规则与同步上传/下载一致 |
| `ssh_transfer_status` | 按精确账号和 transfer_id 读取本机持久进度及最终结果；可从另一个 MCP 进程查询，不发起 SSH 请求 |
| `ssh_cancel_transfer` | 完整访问、传输授权和明确确认后请求取消；继续查询实际结果 |
| `ssh_forget_transfer` | 明确确认后仅移除已完成的本机结果记录，不操作目标或网络 |

异步启动还需允许对应 `ssh_upload_file` / `ssh_download_file`，下载仍要求独立文件读取授权。禁用启动工具、底层工具、撤销授权或更改账号会阻止/取消正在执行的操作。每个 MCP 进程至多 8 个后台传输，仍受全局连接容量、结果预算及最长 300 秒单次请求限制。同步上传/下载也返回 transfer_id，并保留相同结果。

0.5 插件直接报告已成功写入 SFTP/本机文件的实际字节及源文件实际大小；未提供大小时 total_bytes 为 null。phase 分为 preparing、transferring、verifying、publishing、finished。已传字节达到源大小不代表目标已发布，必须等 state=completed。速度为 updated_at_unix 时刻的平均速度，查询不按墙钟推算进度；快照最多约每 250 ms 更新一次，阶段变化立即写入。摘要基于本次流式传输字节，不额外重读目标。

结果以本机私有文件原子保存：成功时保存 SHA256、字节数及当时的发布结果，失败/取消时保留错误码与未知的目标结果。查询不会据此保证目标现在的内容未被修改。缺少终态且所有者进程已退出时返回 unknown，不能当成失败、停止或未发布。最终结果无法持久保存时同步调用返回 OUTCOME_UNKNOWN，禁止重传；后台调用通过状态核对。

异步传输由发起的 MCP 进程持有，进程退出会尝试取消并记录结果；不提供跨进程继续传输、断点续传或自动重试。重连可查询记录，不能恢复已中断的网络传输。无需服务器安装 Python、Node、代理或服务。

登记与结果合计最多 512 条。新建传输时清除超过 7 天的成功结果，或为容量移除最旧的成功结果；不会自动移除活动、失败或未知记录。无可清理容量时拒绝新传输。`ssh_list_transfers` 默认保留原语义，只列待核对记录；传 `include_completed: true` 可查保留的成功历史。失败/未知记录沿用 inspect/token/cleanup 流程。锁文件保留以避免跨进程锁 inode 竞态，不删除任意路径或历史未登记临时文件。

## 跳板机、SSH agent 与配置导入（0.6.0）

账号仍在 SSH 服务器设置中保存一次，MCP 使用同一记录。连接编辑器可选择已保存的跳板机；嵌套引用组成最多四跳的链，拒绝自身引用、循环、缺失账号和过长链。删除仍被引用的跳板机会在修改凭据/授权前拒绝，需先调整依赖连接。

每跳通过 libssh2 direct-tcpip 建立下一跳的加密 SSH 会话，先核对该跳指纹再提交其账号凭据。目标主机名由最后一跳解析；跳板转发被服务器拒绝时返回失败，不改为直连。连接/命令/SFTP/任务使用同一路径；MCP 要求目标原有操作授权，以及每一跳单独的连接授权，不要求跳板机拥有命令或文件权限。观察到授权/账号变化会取消不再允许的活动操作，维护周期也是撤销后备检查。没有远程代理、ProxyCommand 子进程或终端模拟器。

认证可选 password、private_key、agent。agent 模式不保存密码或读取私钥内容，使用指定的本机 Unix socket，留空则使用运行进程的 SSH_AUTH_SOCK；GUI 与不同 MCP 客户端环境可能不同，可显式填写 socket。socket 必须属于当前用户，消息和身份数有上限（1 MiB、64 个身份），等待共用本次操作的超时和取消。签名仅在本机完成，绝不转发 agent，不自动加载/删除用户 agent 中的密钥。普通密码/私钥直连仍复用连接；agent 和跳板路径每次重新认证，避免移除 agent 身份后仍使用旧认证会话。

MCP `ssh_add_connection` 新增可选参数：

```json
{
  "authentication": "agent",
  "agent_socket_path": "/absolute/local/agent.sock",
  "jump_connection_id": "saved-jump-connection-uuid"
}
```

这些是原有 name/host/username/host_fingerprint 等参数的补充；agent 不可与 password/passphrase/private_key_path 混用。未指定 authentication 时保持旧密码/私钥推断。添加连接不自动授予权限。旧插件仍支持普通直连；agent/跳板和经跳板读取指纹需 0.6.0 及新 MCP 宿主。可选 route 扩展1不改变原有 ABI1、文件/管理/连接池/进度扩展或 27 个方法。读取指纹只完成目标握手；跳板仍须认证，目标不会收到账号凭据，读取结果仍需独立核对确认。

首次保存 agent/跳板账号时，ssh-connections.json 使用 `{ "version": 2, "connections": [...] }`。新宿主兼容旧数组；有旧数据时先保留私有 `.ssh-connections-v1.backup.json`。格式不会自动降回 v1。旧运行中的 MCP 不认识跳板字段，必须拒绝读取新格式而不能忽略路由直连，因此保存前应重连更新后的客户端；旧账号、凭据和授权不会重复配置。备份不自动恢复，避免覆盖之后的账号变更。

SSH 设置的“导入…”读取 ~/.ssh/config 或用户选择的文件，先展示具体 Host 别名的地址、端口、账号、认证、密钥路径及跳板链，之后进入现有账号编辑器核对指纹并保存，初始 MCP 权限保持禁止。先保存跳板账号，再导入依赖它的目标；不会自动创建未验证的跳板、覆盖已有同名账号或授予权限。

导入支持关键词大小写、首值优先、Host 的 `*`/`?` 与否定匹配、引号/注释、全局 Include（通配文件、最多16层/128文件/1 MiB），以及常用路径 token `%h/%n/%p/%r/%u/%d/%%`、`~/`、`${ENV}`。IdentityFile 多项会提示仅选第一项供编辑确认。支持简单/多跳 ProxyJump，以及单跳别名的嵌套路由；显式多跳与嵌套混合需人工核对。未知路径 token、循环路由、Match、条件 Include、ProxyCommand、额外身份/来源地址/算法限制会阻止自动导入并提示。LocalCommand、RemoteCommand、agent forwarding 不导入、不执行。此功能不是 OpenSSH 全配置解释器，也不调用可能运行 Match exec 的 ssh -G。

## 逐跳诊断与版本自检（0.7.0）

`querycraft_runtime_info` 是只读的本机自检工具，在平铺、按插件发现及混合模式均可发现，受 MCP 启用状态和工具开关约束。无需连接服务器、读取账号凭据或启动桌面。返回当前进程启动时捕获的宿主版本、组件 build、唯一 `runtime_build`，以及实际加载的 SSH 插件版本、ABI 与可选扩展能力；`plugin_list` 的 SSH 项也附带实际加载能力。

`host.loaded` / `ssh.loaded` 指当前进程正在用的版本，`host.installed` / `ssh.installed_metadata` 是磁盘 Current 的本机元数据，后者不代表已执行或校验了新插件。更新插件或切换 MCP Current 后，旧进程仍报告原能力，并返回 `reconnect_required: true`；关闭并重新连接该 MCP 客户端后才加载新版本。独立 MCP 包每次打包都生成唯一 runtime_build，即使营销版本/组件 build 相同也能识别本地构建。普通桌面/测试宿主的主程序比较为 `unmanaged_host`，宿主重连标记为 null；不把它冒充独立 MCP。缺失或不可读的安装元数据会明确标记，不加载新代码来做自检。

SSH 0.7.0 新增可选诊断扩展 1；基础 ABI 1 及既有请求/结果布局保持不变。失败的 MCP 错误可附带：

```json
{
  "details": {
    "ssh": {
      "endpoint_index": 3,
      "jump_count": 2,
      "role": "target",
      "phase": "forwarding",
      "connection_id": "目标账号 UUID",
      "via_connection_id": "第二跳账号 UUID",
      "resolution_scope": "forwarding_server"
    }
  }
}
```

endpoint_index 从 1 开始按本机至服务器方向编号，目标为 jump_count+1。阶段包括 preparing、resolve、connect、handshake、host_key、authentication、forwarding、pool、command、sftp。转发失败标明目的账号及负责转发的前一跳；下一跳域名由转发服务器解析，协议可能无法区分其 DNS 失败、连接拒绝或转发策略拒绝，不能将其伪报为本机 DNS 故障。阶段仅定位失败时正在进行的动作，不保证命令/目标文件未改变；原有未知结果及禁止自动重试规则不变。

诊断只输出固定阶段名、跳数和本机账号 ID，不输出密码、口令、私钥/agent 路径、原始协议报文或底层错误文本。旧插件不支持诊断时，底层连接错误继续返回原错误格式，不猜测阶段；宿主自己检测出的凭据/agent 准备错误可按 preparing 明确定位对应账号。任务/传输操作仍仅通过 MCP 提供，本轮不增加页面、远端依赖或断点续传。

后台传输失败时，`ssh_transfer_status` 的 `ssh_diagnostic` 保留同一份经过校验的跳数/阶段/账号 ID，可跨客户端重连查询；老状态文件没有该字段时为 null。它描述当时的失败，不代表连接或目标文件现在的状态。

同步上传/下载补充 transfer_id 核对提示时保留相同的错误详情。任务启动已提交但连接失败时仍返回 task_id 和 state=unknown，并可附带 error_code/ssh_diagnostic；诊断不能证明任务未启动，必须先按 task_id 核对，禁止自动重启。


## 安装包分发与更新

SSH 从独立组件源下载，提供 `ssh-x86_64.json` 和 `ssh-arm64.json` 两份签名发行目录。版本及兼容信息统一维护在 `Components/versions.json.ssh`；包内 `Contents/Resources/component.json` 必须与签名发行记录一致。安装前验证固定证书、目录 Ed25519 签名、SHA-256、架构及 ABI。打包、服务端和 CI 发布步骤见 [发版流程](RELEASE_PROCESS.md#ssh-插件分发与更新)。

在设置的“插件 → SSH · libssh2 → 管理 → 下载并安装”更新；离线时选择本地 ZIP 或 bundle。在线更新拒绝降级，失败保留当前版本。旧 MCP 会话继续使用原插件，重连后通过 `querycraft_runtime_info` 确认新版本与实际能力。账号、凭据和授权不随安装包重复配置。Dev 使用独立的开发组件源；未配置时保持已有本地插件，不自动下载生产版。

SSH 独立更新不触发 MySQL、PostgreSQL、Doris、Redis、Elasticsearch 或 Kafka 驱动发版；Driver API 仍为 5。发布前必须先更新资源服务器，双架构构建和在线目录验收完成后才能宣布线上可下载。
