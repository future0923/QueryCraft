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

Kafka 驱动使用 librdkafka，支持无认证、SASL/PLAIN、SCRAM-SHA-256/512 和 TLS。

Kafka 数据页默认使用 JSON 表格展示，可在读取栏切换“JSON 表格 / 原始 Value”。对象字段按 `value.user.id` 路径展开，路径中的字面点与反斜杠会转义；数组保持原样，数字保留原始精度。原始 Value 与非 JSON 内容始终保留，检查器及“复制为新消息”使用原始消息。查找、复制和当前数据导出使用所见字段；导出范围为当前已读取的消息。实时读取固定首批 JSON 字段布局，使用菜单中的“重新展开字段”纳入后续字段。展开最多 128 列，超过 1 MB、32 层或解析预算的值保留原文。

侧边栏 Topic 右键菜单支持“删除 Topic…”，需输入完整名称并停用安全锁。服务端确认后同步移除列表项和已打开的页签；权限拒绝或超时保留页面并提示原因，结果未确认时需刷新列表核实，不会自动重试。Kafka 内部 Topic 禁止删除；该 Topic 有未提交配置时需先提交或放弃。

Topic 的“结构”页支持双击配置值直接编辑全部可写项，继承默认值的项会自动变为 Topic 覆盖；右键可恢复默认值或撤销本项更改，Broker 标记的只读项及敏感项不可编辑。草稿高亮，通过顶部统一工具栏预览、提交或放弃；刷新保留草稿及原始冲突基线。提交需确认安全锁，仅增量提交改动项，提交前检查配置冲突，提交后回读确认。写入要求 Kafka 2.3+ 及 DescribeConfigs / AlterConfigs 权限；结果未确认时，放弃草稿并刷新当前值后再编辑。

Topic 数据页底栏的“发送消息”支持自动或指定分区、可空 Key、JSON / 文本 Value 和重复名称的 Headers（UTF-8，总大小最多 1 MB）。发送前需停用工作区安全锁；成功后显示 Kafka 确认的分区和 Offset。发送中防止重复提交，失败保留草稿；未确认送达时先检查 Topic，再决定是否重新发送。
Topic 页面中的“消费组”可查看各分区已提交 Offset、日志范围和 Lag；未提交或不可用的位置显示为未知。
“结构”页展示分区 Leader、副本、ISR 和 Topic 配置（含保留时间、保留大小及清理策略）。配置读取权限不足时仍保留分区信息。
消费组优先显示已确认与当前 Topic 关联的组，汇总总 Lag 和积压分区数；可启用每 15 秒刷新当前组。关联检查受时间限制，未确认的组保留在列表中。
消费组的“成员”页展示 Client ID、主机、Member ID、静态 Instance ID，以及当前 Topic 的分区分配，同时显示组状态和分配策略；支持手动或自动刷新。
选中有已知积压的分区，点击底部“查看积压消息”，可直接从该分区已提交 Offset 开始读取；没有积压或位置未知、失效时不可跳转。
查看消息和消费组不会提交 Offset。Lag 按 Offset 差值计算，压缩清理后的 Topic 不一定等于实际消息数。

读取栏的“过滤”可按 Key、Value 或两者进行包含 / 完全匹配，可区分大小写；启用后点击“扫描”，按指定分区和起点读取。默认最多扫描 1 万条，可选 1 千 / 10 万条；约 30 秒或 64 MB 上限也会结束扫描，并显示扫描数、匹配数和停止原因。结果复用消息表格、原始查看和分页，顶部刷新重新扫描，取消或失败保留上次结果。底栏“查找”仅搜索已加载的数据。

“实时”从当前末尾持续接收消息，沿用分区和过滤条件。暂停会关闭读取连接，继续从保存的下一条 Offset 接收；停止后可重新点击“实时”从新的末尾开始。默认保留最近 1 万条或 32 MB，显示接收、匹配和淘汰数量；向上查看时保留滚动位置，“回到最新”返回底部。实时期间顶部刷新从当前位置补读，断线显示错误并保留已有结果；切换页签会暂停读取，不提交消费位点。

数据库驱动按需安装，并仅下载当前 Mac 架构需要的版本。

## 核心体验

- 多连接、多数据库上下文与独立工作区
- 可恢复的查询文档、标签页与编辑状态
- SQL 高亮、补全、格式化、当前语句及批量执行
- Safety Lock 写入保护、SQL 预览和统一提交
- 为大量结果设计的原生虚拟化直接绘制网格
- SQL、Kafka、Elasticsearch 表格自动将常见时间戳列显示为本地年月日时分秒（设置 → 数据中可关闭，默认开启）；列头右键可选择原始值、秒或毫秒，编辑、复制和导出保留原始值
- 搜索、复制、分页、服务端排序与筛选
- Excel、CSV、JSON、JSON Lines 与 SQL 导出
- 简体中文 / English、浅色 / 深色外观
- Sparkle 签名自动更新

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
