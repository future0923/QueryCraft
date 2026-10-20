# QueryCraft

**为 macOS 打造的原生开源数据库工作台。**

[English](README_EN.md) · [下载最新版](https://github.com/future0923/QueryCraft/releases/latest) · [构建说明](BUILDING.md) · [反馈问题](https://github.com/future0923/QueryCraft/issues)

QueryCraft 把连接、数据库对象、SQL 文档、查询结果与数据编辑组织在独立工作区中，让日常数据库工作保持清晰、连贯，同时保留 macOS 应有的原生交互。

当前版本的全部功能免费，无需购买或激活许可证。项目自有代码采用
[GNU Affero General Public License v3.0](LICENSE) 开源。

## 支持的数据库

| 数据库 | 当前能力 |
| --- | --- |
| MySQL / MariaDB | 对象浏览、SQL 查询、表数据及结构编辑、导出 |
| PostgreSQL | Database / Schema 上下文、SQL 查询、数据与结构工作流、导出 |
| Apache Doris / SelectDB | 连接、对象浏览和 SQL 查询 |
| Redis | DB 与 Key 浏览、类型识别、值编辑、命令文档 |
| Elasticsearch | 索引、别名、数据流、Mapping、文档和 REST 请求 |
| Kafka | 创建 / 删除 Topic、消息发送、分区 / Offset / 时间定位、原始消息查看、消费组与 Lag |


数据库驱动按需安装，仅下载当前 Mac 架构需要的版本。

## 产品特色与能力

- 原生 macOS 多连接工作区，查询文档与标签状态可恢复，支持浅色和深色外观。
- SQL 高亮、补全、格式化与批量执行，编辑器配色可自定义。
- 面向大量结果的虚拟化直接绘制网格，支持搜索、筛选和数据编辑。
- SQL 预览、安全锁与事务写入，让数据库修改可检查、可控制。
- 覆盖常用表格、文本和 SQL 格式的数据导入导出。
- MySQL 结构对比与同步，差异检查与部署 SQL 预览。
- 可复用的跨库传输任务，支持结构与数据复制、Upsert、后台进度和取消。
- MySQL LOAD DATA、PostgreSQL COPY 原生批量通道，持续流式传输并控制内存占用。
- 独立 MCP 集成，为 AI 工具提供按范围授权的数据库能力与统一凭据授权。
- 简体中文与 English，支持签名自动更新。

## 实测性能

Release 模式传输 **1000 万行**，完成后逐字段全量校验：

| 传输方向 | 耗时 | 峰值内存* |
| --- | ---: | ---: |
| MySQL → MySQL | 102.06 秒 | 36.62 MiB |
| PostgreSQL → PostgreSQL | 45.75 秒 | 26.34 MiB |
| MySQL → PostgreSQL | 48.94 秒 | 40.05 MiB |
| PostgreSQL → MySQL | 121.81 秒 | 40.62 MiB |

*内存为传输测试进程每秒采样的 RSS，不是完整 App 或数据库总内存。本地 Docker 使用 MySQL 5.7/8.0、PostgreSQL 17，五列混合类型、每批 1000 行；每个数据库容器限制 4 CPU、2 GiB。耗时包含执行复核和提交，不含夹具生成及最终校验；实际表现取决于表结构、硬件和网络。

## 下载与构建

Release 页面提供 Apple Silicon 与 Intel Mac 对应的 DMG。QueryCraft 要求
**macOS 15 或更高版本**。当前免费分发采用 ad-hoc 签名，首次打开若被
macOS 阻止，请在 **系统设置 > 隐私与安全性** 中确认来源并选择
**仍要打开**。

源码构建无需付费 Apple Developer 账号。请打开 `QueryCraft.xcworkspace`
并选择 `QueryCraft` scheme，或按照 [BUILDING.md](BUILDING.md) 使用
XcodeBuildMCP 构建应用和六类驱动。

## 仓库结构

```text
QueryCraft.xcworkspace/       Xcode 工作区
QueryCraft.xcodeproj/         macOS 应用壳
QueryCraft/                   应用入口、资源与配置
QueryCraftPackage/            主要功能及测试
QueryCraftDrivers/            六类可安装数据库驱动
QueryCraftUITests/            UI 自动化测试
Config/                       公共构建配置
scripts/                      本地构建与客户端发布工具
ThirdParty/                   按原许可证保留的第三方源码
ThirdPartyLicenses/           第三方许可证和来源说明
```

授权服务、部署凭据和内部设计资料不属于本公开仓库。

## 许可证

项目自有代码采用 `AGPL-3.0-only`。第三方源码、库和资源继续遵循各自的
许可证，详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和
`ThirdPartyLicenses/`。
