# QueryCraft 发版流程

每次发版前先阅读本文件和仓库根目录的 `AGENTS.md`。发版分为主程序和外部驱动两条链路，不能因为主程序版本变化就自动升级全部驱动。

## 1. 发布前检查

1. 确认当前分支是 `main`，工作区没有无关改动。
2. 从上一个正式 tag 到当前提交检查变更范围：

   ```bash
   git diff --name-only <上一个tag>..HEAD
   ```

3. 检查 `Config/Shared.xcconfig` 中的 `MARKETING_VERSION` 和唯一的 `CURRENT_PROJECT_VERSION`。
4. 检查 `docs/releases/<版本>.md` 是否同时包含中英文说明。
5. 先跑核心测试，再编译主程序；发布构建必须使用仓库的 `xcodebuildmcp` 流程。

## 2. 判断是否发布驱动

逐个检查 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka：

- 只有该驱动的源代码、驱动专属依赖、驱动打包脚本，或 Driver API 合约发生变化时，才升级该驱动的 `DRIVER_VERSION/DRIVER_BUILD` 并发布它。
- 只有主程序、共享编辑器、界面、测试或文档变化时，不升级任何驱动。
- Driver API 变化必须同时检查 `DatabaseDriverCompatibilityValidator.currentDriverAPIVersion`、`scripts/driver-package-common.sh` 和所有驱动 manifest；需要发布全部兼容驱动时才批量升级。
- 没有代码变化的驱动仍要做兼容性检查，确认旧版本能被新主程序加载；不要为了凑版本重新上传同一驱动。

记录发布决策，例如：

```text
主程序：发布
MySQL：不发布，未改动
PostgreSQL：不发布，未改动
Doris：不发布，未改动
Redis：不发布，未改动
Elasticsearch：不发布，未改动
Kafka：不发布，未改动
Driver API：未变化，仍为 5
```

## 3. 提交和打 tag

先提交功能代码，再提交版本和发布说明：

```bash
git add <功能文件>
git commit -m "<功能提交说明>"
git add Config/Shared.xcconfig docs/releases/<版本>.md
git commit -m "release: QueryCraft <版本>"
git push origin main
git tag -a v<版本> -m "QueryCraft <版本>"
git push origin v<版本>
```

tag 会触发主程序 Intel、Apple Silicon 和 Universal Sparkle 更新包构建。tag 默认不发布驱动。

## 4. 需要发布驱动时

使用 `workflow_dispatch`，明确选择 `publish_drivers=true` 和 `rebuild_driver`。只改了一个驱动时只选择一个驱动；不要使用全部驱动矩阵代替变更判断。复用已完成的主程序构建时填写 `source_run_id`。

每个发布驱动都必须验证：

- Intel 与 Apple Silicon 包装成功；
- manifest 的数据库类型、版本、build、Driver API、最低主程序版本和架构一致；
- 驱动可以被对应版本的 Dev 主程序加载；
- 发布后的目录 manifest、压缩包摘要和下载地址一致。

## 5. 发布后验证

1. 检查 GitHub Actions 的 metadata、主程序、Universal update 和所选驱动任务全部成功。
2. 检查 GitHub Release、主程序下载包、appcast 和资源服务状态。
3. 检查主程序和驱动版本：未选择发布的驱动不应出现新版本记录。
4. 在 Dev 中确认新主程序启动，并检查实际加载的驱动目录和 Driver API。
5. 记录 workflow URL、tag、提交、测试结果和未发布驱动清单。
