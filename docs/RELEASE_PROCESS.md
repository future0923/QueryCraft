# QueryCraft 发版流程

每次发版前必须先阅读本文件和仓库根目录的 `AGENTS.md`。发版要同时检查主程序和 MySQL、PostgreSQL、Doris、Redis、Elasticsearch、Kafka 六类驱动；是否发布驱动由相对上一个正式版本的实际代码和协议变化决定。

## 1. 发布前建立基线

```bash
git switch main
git status --short --branch
git fetch origin --tags
previous_tag="$(git describe --tags --abbrev=0)"
git diff --name-status "$previous_tag..HEAD"
```

确认工作区没有无关改动，并检查 `Config/Shared.xcconfig` 中唯一的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。版本号、`docs/releases/<版本>.md` 的中英文说明、测试结果和发布决策必须在提交前准备好。

发版判断要以“上一个已发布 tag”到当前提交为范围。特别检查：

- 主程序、共享 Swift 包、编辑器和 UI 是否变化；
- 每个驱动的源代码、专属依赖、打包脚本和 manifest 是否变化；
- `DatabaseDriverCompatibilityValidator.currentDriverAPIVersion`、`scripts/driver-package-common.sh` 和所有驱动 manifest 的 Driver API 是否变化；
- 线上每个架构的驱动目录是否真的已经达到当前主程序要求的 API，而不是只看本地脚本版本。

决策记录必须逐项写明。例如 API 没变化且驱动代码没变时：

```text
主程序：发布
MySQL：不发布，未改动且线上 API 兼容
PostgreSQL：不发布，未改动且线上 API 兼容
Doris：不发布，未改动且线上 API 兼容
Redis：不发布，未改动且线上 API 兼容
Elasticsearch：不发布，未改动且线上 API 兼容
Kafka：不发布，未改动且线上 API 兼容
Driver API：未变化
```

如果 Driver API 从 4 变为 5，或某个驱动的协议、实现、依赖、打包内容发生变化，就必须发布受影响驱动的 Intel 与 Apple Silicon 包。API 合约变化需要发布全部依赖该合约的驱动，不能只升级当前截图中正在使用的驱动。

## 2. 本地验证

先运行核心测试并通过仓库的 `xcodebuildmcp` 流程编译主程序。共享页面变化要按 `AGENTS.md` 覆盖六类驱动的适用范围、公共模型、表数据页和 SQL 结果页；驱动变化要分别编译、打包并确认 Dev 实际加载了新包。加载中、空结果、失败重试、快速切换和重复刷新也要按规范验证。

## 3. 提交和创建 tag

先提交功能和测试，再提交版本与发布说明：

```bash
git add <功能文件>
git commit -m "<功能提交说明>"
git add Config/Shared.xcconfig docs/releases/<版本>.md AGENTS.md docs/RELEASE_PROCESS.md
git commit -m "release: QueryCraft <版本>"
git push origin main
git tag -a v<版本> -m "QueryCraft <版本>"
git push origin v<版本>
```

tag 工作流构建 Intel、Apple Silicon 和 Universal Sparkle 更新包，并默认只发布主程序。tag 不会因为主程序版本变化而自动上传六类驱动。

## 4. 需要发布驱动时

先完成主程序构建，再用同一个 source run 复用客户端产物。全部驱动因 API 合约升级时：

```bash
gh workflow run release.yml --ref main \
  -f publish=true \
  -f source_run_id=<主程序构建run-id> \
  -f publish_drivers=true \
  -f rebuild_driver=none
```

只改一个驱动时，只构建并上传那个驱动：

```bash
gh workflow run release.yml --ref main \
  -f publish=true \
  -f source_run_id=<主程序构建run-id> \
  -f publish_drivers=true \
  -f rebuild_driver=mysql
```

`rebuild_driver` 选择单个数据库时，发布脚本只上传该数据库的两个架构；其他驱动只做线上兼容性检查，不重新生成版本记录。需要发布全部驱动时使用 `none`，不能用“顺手跑完整矩阵”代替决策。

每个待发布驱动必须检查：数据库类型、版本、build、Driver API、最低主程序版本、架构、压缩包摘要和下载地址一致；Intel 与 Apple Silicon 都成功；Dev 能加载；线上目录 manifest 与压缩包摘要一致。

## 5. 发布后验收

```bash
gh run view <run-id> --json status,conclusion,jobs,url
gh release view v<版本>
curl -fsSL https://querycraft.debug-tools.cc/appcast.xml
curl -fsSL https://querycraft.debug-tools.cc/drivers/mysql-arm64.json
```

确认 Actions 的 metadata、主程序、Universal update、选定驱动任务和 publish 全部成功；确认 GitHub Release、DMG、ZIP、appcast 和资源服务下载地址可用；确认未选择的驱动没有新增版本；在 Dev 中确认主程序版本、实际驱动目录和 Driver API。记录 workflow URL、tag、提交、测试结果、已发布驱动和未发布驱动。

如果线上检查发现当前主程序所需 Driver API 尚未覆盖，发版脚本必须失败并停止切换，而不是让不兼容的主程序继续被宣称为完整发布。协议不支持或没有实库条件的验证要明确记录，不能用相似名称或旧 manifest 代替真实结果。
