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

数据库驱动按需安装，并仅下载当前 Mac 架构需要的版本。

## 核心体验

- 多连接、多数据库上下文与独立工作区
- 可恢复的查询文档、标签页与编辑状态
- SQL 高亮、补全、格式化、当前语句及批量执行
- Safety Lock 写入保护、SQL 预览和统一提交
- 为大量结果设计的原生虚拟化直接绘制网格
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
XcodeBuildMCP 构建应用和五类驱动。

## 仓库结构

```text
QueryCraft.xcworkspace/       Xcode 工作区
QueryCraft.xcodeproj/         macOS 应用壳
QueryCraft/                   应用入口、资源与配置
QueryCraftPackage/            主要功能及测试
QueryCraftDrivers/            五类可安装数据库驱动
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
