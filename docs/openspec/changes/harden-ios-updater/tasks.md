# 任务

## 1. 入口参数与依赖检查

- [x] 1.1 调整入口顺序：先解析参数并校验取值，再执行依赖检查；`--help`、`--doctor` 在依赖检查前直接输出并退出（验证：临时 PATH 移除 `jq` 后执行 `--help` 与 `--doctor` 均能正常输出） <!-- comet-task:599c9c5a-b2b6-4926-a780-68a4bd04c8c2 -->
- [x] 1.2 为 `--mirror`、`--fuzhu`、`--schema`、`--depdir` 增加缺值与非法值检查，未知参数报错退出（验证：单独执行 `--fuzhu` 返回非零并提示缺值；`--fuzhu foo` 提示非法取值；`--bogus` 报未知参数） <!-- comet-task:4ab2fa02-0327-4af3-bb33-824475ded634 -->
- [x] 1.3 `--doctor` 区分必装与可选工具，缺少可选工具时只给出可选提示（验证：构造缺少 `shasum`、`uiopen` 的环境，输出仍判定环境可用） <!-- comet-task:f83538df-22e5-4609-af97-2d0548ace5a6 -->

## 2. HTTP 下载与完整性校验

- [x] 2.1 更新 HTTP 封装：curl 使用 `-fSL --retry`，wget 使用重试参数，失败后删除残留文件（验证：对返回 404 的 URL 调用下载函数，函数返回非零且目标路径不存在） <!-- comet-task:3f2d9f5f-18d8-4aaa-ae00-0d552e781975 -->
- [x] 2.2 增加哈希工具一次性检测与哈希小写规范化，统一“大小 + sha256”校验入口（验证：大小正确但哈希错误的文件校验失败；隐藏 `shasum`/`sha256sum` 后校验仅告警并通过大小检查） <!-- comet-task:b42a96af-2e0d-4b9e-adeb-2b9ddb1b29ef -->
- [x] 2.3 移除“下载命令失败但文件非空即视为成功”的逻辑（验证：模拟中途失败并留下部分文件的场景，更新流程判定失败且不进入解压） <!-- comet-task:07a12564-ad67-410b-bc06-c154c4aeab13 -->

## 3. Release 发现与版本比较

- [x] 3.1 CNB 分页改为 `page_size=100`，GitHub 改为 `per_page=100`，方案与词库共用同一份 GitHub releases 缓存，移除未使用的 `TOOLS_API`（验证：抓取 CNB 列表的 release 总数与远端一致；一次运行中 GitHub releases 端点只被请求一次） <!-- comet-task:cc2292d4-26f3-4db0-93c3-a6828518f862 -->
- [x] 3.2 方案与词库 release 改为按标题 + tag 正则选择，标题未命中时使用 tag 回退并告警（验证：使用保存的 CNB 与 GitHub JSON 响应，选出方案 `v18.1.8` 和对应词库 release，不选模型/安卓包） <!-- comet-task:79eb794f-3991-4d1a-8431-fbf9c7bba5f6 -->
- [x] 3.3 用可移植的逐段数值比较替换 `sort -V`（验证：`v18.1.8` < `v18.1.9`、`v9.9.9` < `v18.1.8`、相同版本返回相等，且在 `/bin/bash` 下运行通过） <!-- comet-task:69c0cfec-2479-4032-9346-7ea537bd3c2e -->

## 4. 方案更新

- [x] 4.1 增加 `custom/.scheme_sha256` 记录与判定：同版本哈希不同则更新、记录缺失则更新一次、本地版本更高不降级、全部一致则跳过（验证：分别构造四种场景的本地状态与远端信息，确认走对应分支且只在成功应用后写记录） <!-- comet-task:045e2216-2e12-471b-8b20-95fb28f64153 -->
- [x] 4.2 重写排除匹配：不含 `/` 的模式只匹配根目录，含 `/` 的模式匹配完整相对路径（验证：`custom/wanxiang.custom.yaml` 被写入，根目录 `wanxiang.custom.yaml` 保持不变，`custom/user_exclude_file.txt` 自身保留） <!-- comet-task:8635cd3c-f42a-43d6-a337-d4049f539b4e -->
- [x] 4.3 增加通用解压根解析并在方案同步中使用，安装模板后清理 `build/`（验证：用真实方案包解压到临时部署目录，确认无多余顶层目录、模板存在、`build/` 被删除） <!-- comet-task:4db929fb-ee54-49ce-b1b8-a86a15228d9c -->
- [x] 4.4 方案下载或哈希校验失败时中止，不修改部署目录、不写哈希记录（验证：使用被篡改的压缩包运行更新，部署目录文件列表与哈希记录均未变化） <!-- comet-task:cd7cccee-b8b6-4000-933a-5b4b4fb01466 -->

## 5. 词库与语法模型

- [x] 5.1 词库改为校验通过后再解压覆盖；剥离单一顶层目录；`dicts/` 缺失或为空时强制更新（验证：坏包不改变 `dicts/`；顶层目录名与压缩包名不同的 fixture 能正确落盘；删除 `dicts/` 后触发更新） <!-- comet-task:7e5a1cd1-e25c-46d1-85d8-0eec1d18d4c3 -->
- [x] 5.2 模型下载前先比对本地文件哈希，下载到部署目录内临时文件并原子替换（验证：本地模型与远端一致时不发起下载；校验失败时旧模型保留且无临时文件残留） <!-- comet-task:6b5429c2-dc1f-408b-966a-c337783f590c -->

## 6. 部署触发、兼容性与实测

- [x] 6.1 `--depdir` 指向 `RimeUserData` 时按元书选择 URL Scheme，其他路径按仓选择（验证：两种路径分别输出 `hamster3://` 与 `hamster://` 对应 Scheme） <!-- comet-task:6a07cd03-6602-4006-8540-b38b3babebcb -->
- [x] 6.2 保持 `AUTO_DEPLOY=false` 与跳转工具缺失时的行为：不调用命令、输出目标 URL 与手动部署提示，且不判定更新失败（验证：关闭自动部署运行后无命令调用且退出正常；隐藏跳转工具后输出警告与 URL） <!-- comet-task:86748c94-e884-4269-985c-11636b801b67 -->
- [x] 6.3 检查 bash 3.2 兼容性（验证：`bash -n` 通过；脚本中不出现关联数组、`mapfile`、`${var,,}`、`sort -V`；用 `/bin/bash` 执行 `--help` 正常） <!-- comet-task:a524bcd8-a909-4fac-beb4-4a47be934c41 -->
- [x] 6.4 在当前 macOS 环境用临时部署目录做端到端实测：CNB 与 GitHub 各跑一次方案+词库，再跑一次模型检查（验证：版本号、`custom/` 模板、`custom/.scheme_sha256`、`custom/.dict_sha256`、模型文件与日志一致，用户文件未被删除） <!-- comet-task:71928f0e-329f-477d-b39a-3318bbdd7631 -->
- [x] 6.5 更新脚本头部的依赖说明与排除规则注释，使其与实现一致（验证：`--help`、`--doctor` 输出和注释描述与代码行为一致） <!-- comet-task:b90de09b-63c8-457c-9320-e38d2a43a7b5 -->

## 7. 复审修复（Verify 返回 Build）

- [ ] 7.1 GitHub releases 补充分页：`page=N&per_page=100` 循环合并，保留安全上限，方案与词库仍共用同一份缓存（验证：GitHub fixture 第 1 页 100 条、第 2 页非空、第 3 页为空时合并数量正确；一次运行 releases 端点被请求 3 次且 `--tags/LTS` 不参与分页） <!-- comet-task:e88067f3-5b33-4368-910d-25ba03cdbea4 -->
- [ ] 7.2 方案判定修正：本地哈希记录缺失时必须更新一次，即使远端未提供 sha256；已有记录且远端无哈希时按版本跳过（验证：`scheme_decision` 在记录缺失/远端空哈希时返回 `update`） <!-- comet-task:cff45634-ab37-48b7-91c1-1719cd94ed3a -->
- [ ] 7.3 校验缺口：大小无法比较且无哈希工具时校验失败并删除文件，避免未经校验的包进入应用阶段（验证：远端大小非数字、隐藏哈希工具时校验返回非零） <!-- comet-task:859267d8-3b34-4431-a031-81d1d845c1aa -->
- [ ] 7.4 记录写入失败处理：方案与模型的哈希记录写入失败时判定更新失败，不静默忽略（验证：让记录路径不可写（同名目录）后运行方案更新，返回非零且 `UPDATE_FAILED=true`） <!-- comet-task:2ea7a52a-a07f-4cc2-8357-28472613a37e -->
- [ ] 7.5 测试补强：CNB 分页改为两页非空后合并、GitHub 分页用例、方案成功更新用例与 `scheme_decision` 记录缺失用例，全量测试在 bash 5 与 `/bin/bash` 下通过（验证：`bash tests/test-wanxiang-update.sh` 与 `/bin/bash tests/test-wanxiang-update.sh` 均 0 失败） <!-- comet-task:90a9a0b0-2f14-4a04-9d33-5fb5e7d4f452 -->
