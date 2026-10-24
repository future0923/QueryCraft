# Elasticsearch iPhone / iPad 验收清单

2026-10-24 用户要求一次完成当前 macOS Elasticsearch 功能后交付。本文件记录已完成的 ES 专用功能与验证范围，具体证据以 VALIDATION 最新节为准。

| Mac 真实入口 / 共享链路 | 移动实现 / 验收范围 |
| --- | --- |
| Sidebar → ElasticsearchWorkspaceSession.fetchObjects | 索引 / Alias / Data Stream 分组、列表文档数/健康与统计页空间信息、同源模糊搜索；完整有界目录 |
| WorkspaceModel.loadData → 原 ES session | 同一 PIT / search_after 游标、旧版/权限不足有界降级、排序、Bool 筛选与 Field Caps 类型能力；超过10k顺序翻页与刷新重建快照 |
| Mapping inspector / WorkspaceMappingCodec | Mapping/Field Caps 表格、完整原始响应、字段/嵌套/多字段新增与允许参数编辑、类型冲突/基线复核 |
| 文档 inspector / WorkspaceDocumentEditingSession | 真实 index/id/routing/version/seq_no/primary_term；完整 source、新建/替换/局部更新/删除、只读超限和409冲突 |
| 网格字段 / WorkspaceElasticsearchDocumentCellEditor + CellChangesModel | 原编辑值转换、NULL/JSON类型、跨文档暂存、统一预览提交/撤销、按文档并发版本保护 |
| 网格粘贴 / WorkspaceElasticsearchDocumentPasteParser | 表头CSV/TSV、保留真实类型/id/routing、500篇/8MiB/每篇1MiB同源预算、逐篇创建/部分成功不重放 |
| 批量删除文档 | 当前页多选、每篇读取版本后预览、顺序发送/错误停止、结果不明读核实与显式结束 |
| 索引新建 / WorkspaceIndexCreationWorker | 精确名称/分片/副本/初始Mapping校验、真实创建ack与分片等待状态 |
| 索引删除 / WorkspaceIndexDeletionWorker | 单个普通索引、完整名称确认、发送前解析资源身份、禁止Alias/DataStream/backing索引；无原子UUID删除协议 |
| 设置/统计 / WorkspaceIndexSettingsWorker | 完整设置/默认值/统计响应、副本与refresh_interval编辑、索引UUID及变更字段复核；无原子CAS协议 |
| Alias管理 / WorkspaceElasticsearchAliasWorker | 多索引绑定/移除/恢复/write index、保留完整filter/routing/高级选项、基线复核 |
| 模板管理 / WorkspaceElasticsearchIndexTemplateWorker | 列表/新建/编辑/删除、原始JSON/index_patterns/priority/composed_of/data_stream；基线复核 |
| 模板模拟 / WorkspaceElasticsearchTemplateSimulationWorker | 只读模拟未来索引、命中模板/settings/mappings/aliases与完整响应 |
| REST文稿 / ConsoleParser/ConsoleWorker | 当前请求/完整选区/整篇多请求、NDJSON、多结果、共享格式化和请求分类、默认锁/完整确认、错误停止 |
| REST补全 / DSLCompletionWorker + RequestCompletion | 同源字段/DSL/方法/资源/端点/模板；原Mac纯路径算法抽为两端共用，UIKit选区/IME守卫 |
| REST结果 / ResponseConverter + ResponseDetails | 表格/JSON切换、命中/耗时/分片/聚合/失败/任务信息、当前表格导出与完整响应分享、历史 |
| 全部匹配数据导出 / WorkspacePagedDataExportRowSource | 独立原生会话和 PIT，500行分批，捕获筛选排序/真实列，CSV/JSON/XLSX；不含未提交草稿，关闭/取消释放PIT |
| 顶部公共刷新 / pageRefresh | 目录/当前数据或Mapping/控制台最后读取派发；新PIT不冒用旧游标；保留旧内容/列宽/滚动/错误重试 |
| 生命周期 | 请求取消/代次防覆盖；后台锁定、读取消/PIT关闭；已发写入等回执；结果不明阻止重发、ACL核实失败保留保护 |

## 六类驱动影响

- Elasticsearch：直接复用同一原生HTTP/session/filter/mapping/document源码。移动16MiB单响应预算可选参数默认为Mac原值；共享页拒绝超时/失败分片。须独立构建、打包和验证真实加载。
- MySQL / PostgreSQL / Doris：SQL、表编辑、事务和缓存链路不进入ES操作；共享网格新增可选ES回调/分页参数默认nil，原行为需五库完整回归。
- Redis：原Resource工作区保留；ES改用专用工作区并保持统一app切换/后台与草稿保护；原完整回归需重跑。
- Kafka：无新增移动传输；只验证Mac现有包与公共API加载兼容，不伪称迁移完成。

## 通用移动工作区边界

本轮覆盖 ES 专用业务入口。桌面通用的多文稿持久恢复、多光标、自定义编辑器主题等仍沿现有移动工作区范围，不将它们冒称为本轮已经移植。实体设备触控、完整外接键盘/输入法、多版本真实 TLS 和真正系统挂起/杀进程仍需单独验证。

## 已完成验证

五库完整回归：iPad、iPhone 各647通过/0失败/1个旧环境用例跳过。最新 ES 专项：iPhone79/0/1，iPad连同共享全屏回归83/0/1。Mac共享功能163项、驱动45项与最后共享改动的26/15/12项补验通过；外置ES独立编译/签名打包、实际新包六驱动加载及真实PIT/文档/CAS/Mapping通过，最新arm64编译通过。证据、跳过项与预算见 [VALIDATION](VALIDATION.md#elasticsearch-完整移动业务链路--2026-10-24)。

真机触控、真实弱网/系统杀进程、实体键盘与多版本TLS未实测。当前Mac ES专用业务清单已落实；上述平台验证及通用编辑器边界保持明确。未提交、打tag、发布或操作用户数据库。
