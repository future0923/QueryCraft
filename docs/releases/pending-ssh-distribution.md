# SSH 分发准备记录（2026-10-23）

这是一份本地验证和待发布范围记录，不表示线上已发布。公开分发必须先部署支持 SSH 的资源服务器，再通过 release.yml 发布同一源码提交的双架构产物。

## 发布范围

| 项目 | 决策 | 原因 |
| --- | --- | --- |
| 主程序 | 下次正式版本包含 SSH 设置及下载入口；本轮更新 Dev | 自 v0.1.12 起已有 SSH 页面与共享授权改动，正式版本/tag 尚未创建 |
| MCP | 准备 0.1.3 (4) | SSH 工具、凭据恢复、运行状态与兼容校验实际变更 |
| SSH 插件 | 准备 0.7.0 (7) 首次独立分发 | libssh2、SFTP、连接池、跳板、Agent、诊断及分发元数据 |
| Skill | 不发布 | 内容未改动 |
| MySQL | 不发布，1.0.8 (9) | 实现未改动，两个在线架构均兼容 API 5 |
| PostgreSQL | 不发布，1.0.7 (9) | 实现未改动，两个在线架构均兼容 API 5 |
| Doris | 不发布，1.0.8 (9) | 实现未改动，两个在线架构均兼容 API 5 |
| Redis | 不发布，1.0.1 (2) | 实现未改动，两个在线架构均兼容 API 5 |
| Elasticsearch | 不发布，1.0.1 (2) | 实现未改动，两个在线架构均兼容 API 5 |
| Kafka | 不发布，1.0.1 (2) | 实现未改动，两个在线架构均兼容 API 5 |
| Driver API | 保持 5 | SSH 采用独立 C ABI 1，没有数据库合约变化 |

用隔离 Git index 对工作区进行完整快照，版本规划器相对 v0.1.12 得到：MCP/SSH 变更、Skill/六类数据库驱动均未变更。该检查使用隔离暂存区；提交审查结果见下文。

## 本地产物与验证

目录：`.build/ssh-plugin/distribution/`。双架构 ZIP 带固定证书签名，发行记录带 Ed25519 签名，下载 URL 指向正式 components 路径，但尚未上传。

- Intel：`querycraft-ssh-0.7.0-7-x86_64.zip`，SHA-256 `53df185a690de70284f30253c7a8bcb312956e894107b54e11cdbd35b2c41807`。
- Apple Silicon：`querycraft-ssh-0.7.0-7-arm64.zip`，SHA-256 `f867f65c8ccf4650311b19253bed69a50f565314a8bc40f74870a2f6460848ac`。
- 22 项发布范围测试、10 项缓存恢复/工作流测试、8 项包身份与部署选择测试通过。
- 本机 Intel 原生解包、固定签名、Mach-O 架构、依赖闭包、ABI 与全部可选扩展加载通过；ARM 已交叉编译/签名，ARM 真机加载由双架构 CI 验收，尚未运行。
- 客户端真实签名 ZIP：旧 0.6 → 在线 0.7 更新、拒绝在线降级、包内兼容信息不匹配、目录伪造、下载损坏、失败保留 Current、卸载/重新安装通过。测试在隔离目录和临时 loopback HTTP 服务中完成，没有改动生产配置。
- LicenseServer 全量 Go 测试通过；旧 SQLite 组件表迁移保留签名清单/状态/唯一约束，MCP/Skill/SSH 上传、发布、幂等重试、下架历史、目录重建和权限测试通过。
- 真实 Intel/ARM ZIP 与正式公开验签密钥通过服务端上传/发布联验，使用临时数据库，不接触线上库。
- 主程序 Debug 编译通过；工作流 YAML 和 actionlint 校验通过（旧版 actionlint 仅忽略其尚未收录的现有 macos-15-intel runner 名称）；Shell 语法和 git diff --check 通过。

## 上线顺序与待办

1. 合并 sibling `QueryCraft/LicenseServer` 的 SSH 支持并部署，备份生产 SQLite，核对健康检查和 `/admin/resources/ssh` 权限。
2. 按正式发版流程选择主程序新版本及双语说明，提交这次完整源码；不要覆盖已发布 0.1.12、MCP 0.1.2 或其 tag。
3. 用 `release.yml` 构建并验证双架构 Release 客户端/MCP/SSH。MCP/SSH 改动由组件计划自动选择；六类数据库驱动不重新发版。
4. 发布后核对 `/components/ssh-x86_64.json`、`ssh-arm64.json`、两个 ZIP 的签名/摘要/版本、GitHub `ssh-v0.7.0+7` 附件，以及 MCP 0.1.3 两架构的独立运行目录。
5. 在正式客户端检查下载/更新，重连 MCP，通过 `querycraft_runtime_info` 确认加载版本；旧账号和授权应保持。


## 提交前审查

服务端提交：`27c684b3`（sibling QueryCraft 仓库）。全量 Go 测试通过。客户端审查补充了激活阶段的跨进程保护：下载完成后，在持有 `.install.lock` 时再次读取 Current 并拒绝降级，避免两个更新进程的旧快照覆盖较新版本；显式本地导入仍保留人工回退语义。

当前结论为代码可提交；正式投产仍以双架构 Release CI 原生执行、先部署资源服务器和公开下载验收通过为条件。没有通过本地 Intel 验证宣称 ARM 已完成实机验收，也没有自动创建正式 tag 或推送发布。
