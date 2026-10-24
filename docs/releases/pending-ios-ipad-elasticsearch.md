# iOS / iPadOS Elasticsearch 完整业务链路 / Elasticsearch mobile workspace

本记录用于 `codex/ios-ipad-editor` 的 Elasticsearch 后续改造，本轮纳入本地功能提交，尚未安排正式发布。此前多驱动提交记录保留在 `pending-ios-ipad-drivers.md`；本轮当前范围与实际验证见 [ES 功能矩阵](../../QueryCraftMobile/ELASTICSEARCH_PARITY.md)、[移动验证](../../QueryCraftMobile/VALIDATION.md)。

## 中文

- iPhone/iPad 直接共用 Mac Elasticsearch 会话、PIT/search_after、Mapping/Field Caps、筛选/排序、文档/Mapping 计划及索引/设置/Alias/模板 worker；提供完整原生入口。
- 支持文档并发版本保护、跨行字段暂存、CSV/TSV 粘贴、批量删除与真实部分成功回执；结果不明只读核实，不自动重放。
- REST 支持当前/选区/整篇、多结果、同源格式化/补全、完整 JSON、诊断定位/任务读取；表格可查找/全屏/导出，独立 PIT 分批导出全部匹配数据。
- 刷新保留内容并重建读取上下文；后台锁定并排空取消任务后关闭连接，前台创建新会话。异步任务只在执行期间保留所属工作区，避免释放后的引用和永久循环引用；后台中断的字段校验可在预览时保留原版本重新构建。

| 组件 | 本轮决定 |
| --- | --- |
| 主程序 | 移动 ES 专用页面和共享纯逻辑改变；保持现有版本身份，不在本轮发布 |
| Driver API | 保持 5；不改变公共会话协议、已发布模型布局或六类 manifest API 约定 |
| Elasticsearch | 原生会话新增默认保留 Mac 行为的响应预算参数、读上下文重建、真实 Mapping 列类型、超时/失败分片拒绝；正式发布须分配新身份并完成双架构包与运行验证 |
| MySQL / PostgreSQL / Doris / Redis | 本轮未改专属协议/驱动实现；共享网格可选 ES 参数默认为 nil，完整五库回归核对原行为。分支前序改造已有的发版影响仍按此前记录执行 |
| Kafka | 无移动链路新增；核对现有包加载/会话工厂，不因本轮重复发版 |
| MCP / Skill | 本轮无实现或发行身份变化 |

本轮只生成隔离本地验证包，不替换用户 Dev 安装，不推送、打 tag、改线上目录或发布。正式发版重新读取 RELEASE_PROCESS 并执行完整主程序/API/六驱动清单，不能以本地测试替代线上双架构门槛。真实设备、真实弱网/系统挂起、多版本 TLS/服务器范围以验证记录为准。桌面通用多文稿持久恢复、主题/多光标仍沿当前移动工作区范围，不能冒称本轮已经移植。

## English

The iPhone/iPad Elasticsearch workspace uses the same Mac session, PIT/search_after pagination, mapping/field capabilities, filters/sorts, document/mapping plans and index/settings/alias/template workers. Native entry points cover document CAS, staged field edits, tabular paste, batch deletion and explicit partial-success receipts, plus REST parsing, formatting, completions, multiple results, diagnostics and full responses. Independent PIT sessions export all matching documents in bounded batches.

Loading retains content. Refresh resets read context; background cleanup drains cancelled reads before transport shutdown and recreates the session on return. Asynchronous tasks retain the workspace only while executing. Unknown write outcomes cannot be replayed, and interrupted staged validation rebuilds against the current session without changing its original concurrency version.

The existing app identity and Driver API 5 remain unchanged. Elasticsearch requires a fresh driver identity and native dual-architecture release verification before publication. Other drivers retain their prior release decisions; all six installed-driver factories are part of local compatibility validation. No installed user driver, remote catalog, tag or release is changed. Physical-device, real network/suspension, broader TLS/server coverage and general desktop workspace features retain the explicit limits in the validation and parity records.
