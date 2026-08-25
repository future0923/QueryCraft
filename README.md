# QueryCraft

**为 macOS 打造的原生数据库工作台。**

[English](#english) | [下载最新版](https://github.com/future0923/QueryCraft/releases/latest) | [反馈问题](https://github.com/future0923/QueryCraft/issues)

QueryCraft 不只是另一个查询窗口集合。它把连接、数据库对象、SQL 文档、查询结果与数据编辑组织在独立工作区中，让日常数据库工作保持清晰、连贯，同时保留 macOS 应有的交互质感。

当前支持 **MySQL、PostgreSQL、Apache Doris 和 SelectDB**。更多数据系统将通过插件化能力持续加入。

## 下载

当前版本：**QueryCraft 0.1.4** · 需要 **macOS 15 或更高版本**

| Mac | 安装包 |
| --- | --- |
| Apple Silicon（M1、M2、M3、M4 及后续芯片） | [下载 arm64 DMG](https://github.com/future0923/QueryCraft/releases/download/v0.1.4/QueryCraft-0.1.4-arm64.dmg) |
| Intel | [下载 x86_64 DMG](https://github.com/future0923/QueryCraft/releases/download/v0.1.4/QueryCraft-0.1.4-x86_64.dmg) |

`QueryCraft-0.1.4.zip` 是供应用内自动更新使用的通用包，普通安装请选择与你的 Mac 对应的 DMG。

QueryCraft 当前采用免费分发阶段的 ad-hoc 签名。首次打开若被 macOS 阻止，请前往 **系统设置 > 隐私与安全性**，确认应用来源后选择 **仍要打开**。

## 已支持的数据库

| 数据库 | 当前能力 |
| --- | --- |
| MySQL | 连接与对象浏览、SQL 查询、表数据编辑、结构与索引编辑、导出 |
| PostgreSQL | Database / Schema 上下文、SQL 查询、数据与结构工作流、导出 |
| Apache Doris | 连接与对象浏览、只读 SQL 查询 |
| SelectDB | 复用 Doris 驱动，支持连接、对象浏览与只读 SQL 查询 |

## 为什么是原生 macOS

许多数据库工具用同一套跨平台界面覆盖多个桌面系统。QueryCraft 选择专注 Mac：

- **真正的原生交互**：使用 SwiftUI、AppKit 与系统控件，遵循 macOS 的窗口、菜单、快捷键、焦点、钥匙串、深浅色外观和辅助功能习惯。
- **为大数据表格设计**：结果网格采用原生虚拟化与直接绘制，滚动、选择、搜索和列操作不依赖庞大的逐单元格视图层级。
- **控制内存增长**：查询、搜索和导出采用分页、批处理、流式处理与临时磁盘存储，避免把无界结果一次性堆进内存。
- **驱动按需安装**：数据库驱动与主应用分离，只下载当前 Mac 架构和实际需要的驱动，不让所有数据库运行时常驻安装包。
- **Mac 工作流优先**：多窗口、多工作区、标签页恢复、系统菜单快捷键与中文输入法下的键盘操作从一开始就是产品能力，而不是跨平台实现后的补丁。

这意味着 QueryCraft 不追求“所有平台看起来完全一样”，而是追求在 Mac 上更自然、更轻、更稳定的数据库体验。

## 核心体验

- 多连接、多数据库上下文与独立工作区
- 可恢复的查询文档、标签页与编辑状态
- SQL 高亮、补全、格式化、当前语句与批量执行
- Safety Lock 写入保护，以及执行前的 SQL 预览
- 表数据和可定位查询结果的暂存编辑、统一提交与失败回滚
- 原生数据网格搜索、复制、分页和服务端排序 / 筛选
- Excel、CSV、JSON、JSON Lines 与 SQL 导出
- 简体中文 / English、浅色 / 深色外观
- 应用内自动更新

## 接下来

QueryCraft 的数据库能力采用插件化方向演进。计划逐步覆盖 **Redis、Elasticsearch、Kafka**，以及更多数据库、分析引擎和数据基础设施。新增产品不会以牺牲现有原生体验或把全部依赖塞进主应用为代价。

## 关于此仓库

这是 QueryCraft 的公开产品与下载仓库，用于发布安装包、版本说明和收集反馈。QueryCraft 应用源码目前未在此仓库公开；第三方组件继续遵循各自许可证。

---

## English

**A native database workspace built for macOS.**

[Latest release](https://github.com/future0923/QueryCraft/releases/latest) | [Report an issue](https://github.com/future0923/QueryCraft/issues)

QueryCraft brings connections, database objects, SQL documents, results, and data editing into focused workspaces instead of scattering them across disconnected query windows. It is built to make everyday database work coherent while feeling at home on macOS.

QueryCraft currently supports **MySQL, PostgreSQL, Apache Doris, and SelectDB**, with more data systems planned through its plugin architecture.

### Download

Current release: **QueryCraft 0.1.4** · Requires **macOS 15 or later**

| Mac | Installer |
| --- | --- |
| Apple Silicon (M1, M2, M3, M4, and later) | [Download arm64 DMG](https://github.com/future0923/QueryCraft/releases/download/v0.1.4/QueryCraft-0.1.4-arm64.dmg) |
| Intel | [Download x86_64 DMG](https://github.com/future0923/QueryCraft/releases/download/v0.1.4/QueryCraft-0.1.4-x86_64.dmg) |

`QueryCraft-0.1.4.zip` is the universal archive used by in-app updates. For a normal installation, download the DMG matching your Mac.

QueryCraft currently uses ad-hoc signing for its free distribution channel. If macOS blocks the first launch, open **System Settings > Privacy & Security**, verify the app source, and choose **Open Anyway**.

### Database support

| Database | Current capabilities |
| --- | --- |
| MySQL | Connections and object browsing, SQL queries, table-data editing, structure and index editing, export |
| PostgreSQL | Database / Schema contexts, SQL queries, data and schema workflows, export |
| Apache Doris | Connections, object browsing, and read-only SQL queries |
| SelectDB | Connections, object browsing, and read-only SQL queries through the Doris driver |

### Native by design

Many database tools share one cross-platform interface across several desktop systems. QueryCraft deliberately focuses on the Mac:

- **Native interaction** with SwiftUI, AppKit, and system controls, following macOS conventions for windows, menus, shortcuts, focus, Keychain, appearance, and accessibility.
- **A grid built for substantial results**, using native virtualization and direct drawing instead of a large hierarchy of per-cell views.
- **Bounded memory use** through paging, batching, streaming, and temporary disk-backed result storage rather than materializing unbounded results in memory.
- **On-demand database drivers** separated from the main app, so users download only the driver and Mac architecture they need.
- **Mac-first workflows** including multiple windows and workspaces, tab restoration, real menu commands, and shortcuts that remain reliable across input sources.

QueryCraft is not trying to look identical everywhere. It is trying to be lighter, more stable, and more natural on the Mac.

### What you can do

- Work with multiple connections and database contexts in isolated workspaces
- Restore query documents, tabs, and editing state
- Highlight, complete, format, and execute the current SQL statement or a batch
- Protect writes with Safety Lock and preview generated SQL before committing
- Stage and atomically commit table-data and editable query-result changes
- Search, copy, page, sort, and filter in a native data grid
- Export Excel, CSV, JSON, JSON Lines, and SQL
- Use Simplified Chinese or English in Light or Dark appearance
- Receive signed in-app updates

### Roadmap

QueryCraft's database layer is evolving around installable plugins. Planned areas include **Redis, Elasticsearch, Kafka**, and additional databases, analytical engines, and data infrastructure without compromising the native experience or bundling every dependency into the main app.

### About this repository

This is QueryCraft's public product and download repository for installers, release notes, and feedback. The QueryCraft application source is not currently published here. Third-party components remain governed by their respective licenses.
