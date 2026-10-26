---
change: harden-ios-updater
design-doc: docs/openspec/changes/harden-ios-updater/design.md
base-ref: af5ae0540c80f8b4137d3c872514294fa3cd2c5e
---

<!-- comet-task-authority: docs/openspec/changes/harden-ios-updater/tasks.md -->

# 实施计划：加固 iOS 万象更新脚本

## 约束

- 只修改 `wanxiang-update-ios.sh`，新增 `tests/` 下的开发期测试；不修改 `rime-wanxiang-update-win-mac-ios-android.py`。
- 保持现有 CLI 参数、默认值与更新范围；不删除旧方案文件、不保护根目录 `custom_phrase.dict.yaml`。
- 兼容 bash 3.2 与 BSD 工具链；不新增运行时依赖。
- 采用 TDD：每个实现任务先写测试并确认 RED，再实现并确认 GREEN；RED 必须因待实现行为失败。
- 提交策略：按任务组提交，提交前运行对应测试与 `bash -n`。

## 测试脚手架

- 新增 `tests/test-wanxiang-update.sh`，使用 `/bin/bash` 运行，自带最小断言函数与临时目录清理。
- 脚本底部增加 source guard（`BASH_SOURCE[0]` 与 `$0` 比较），使测试可以在不执行 `main` 的情况下加载函数；这是无行为变化的可测试性改造，随 1.1 一起完成。
- 夹具放在测试脚本内的 heredoc 或 `tests/fixtures/`：CNB/GitHub release JSON 片段、排除文件、单顶层目录 zip 结构。
- 统一测试入口：`bash tests/test-wanxiang-update.sh`，支持按组运行（`entry`、`http`、`release`、`scheme`、`dict-model`、`deploy`）。

## 1. 入口参数与依赖检查

### 任务 1.1 入口顺序与 source guard
<!-- comet-task-ref:599c9c5a-b2b6-4926-a780-68a4bd04c8c2 -->

- 范围：把参数解析移到 `deps_check` 之前；`--help`/`--doctor` 在依赖检查前直接输出并退出；脚本底部增加 source guard。
- 依赖：无。
- 实现要点：`main` 内先解析参数到局部变量，再调用 `deps_check`；`--doctor` 与 `--help` 分支直接 `exit 0`；保持 `detect_deploy_dir`、`create_exclude_file`、更新调用顺序不变。
- RED：新增测试 `entry_help_without_jq`，在 `PATH=/usr/bin:/bin` 下执行 `--help`，当前实现因缺少 jq 退出非零。
- GREEN：同一测试通过；`bash -n` 通过。
- 验收：`--help` 与 `--doctor` 在无 jq 环境下正常输出并返回 0。

### 任务 1.2 参数缺值与非法值
<!-- comet-task-ref:4ab2fa02-0327-4af3-bb33-824475ded634 -->

- 范围：`--mirror`、`--fuzhu`、`--schema`、`--depdir` 的缺值与非法值检查；未知参数继续报错。
- 依赖：1.1。
- 实现要点：新增 `need_value` 辅助函数，在 `shift` 前检查剩余参数数；`--depdir` 拒绝空值；错误信息包含参数名与合法取值。
- RED：新增 `args_missing_value`、`args_invalid_fuzhu`，当前实现缺值时输出 `unbound variable` 或不退出。
- GREEN：两类测试通过；`--bogus` 仍报未知参数。
- 验收：缺值/非法值均以非零退出且无下载请求。

### 任务 1.3 自检必需/可选分离
<!-- comet-task-ref:f83538df-22e5-4609-af97-2d0548ace5a6 -->

- 范围：`show_doctor` 区分必装（jq、解压、HTTP 客户端）与可选（另一 HTTP 客户端、哈希工具、跳转工具）；移除 `sort` 依赖展示。
- 依赖：1.1。
- 实现要点：分别累计 `missing_required` 与 `missing_optional`；仅可选缺失时输出“可选缺失”，不输出整体不可用；保留安装建议。
- RED：新增 `doctor_optional_only`，构造只有必装工具的 PATH，当前实现把所有缺失都计入 `missing` 并输出“缺失项”。
- GREEN：测试通过，输出包含“可选”且不包含“不可用”。
- 验收：最小环境自检通过；缺少 `shasum`/`uiopen` 只提示可选。

## 2. HTTP 下载与完整性校验

### 任务 2.1 HTTP 失败语义与重试
<!-- comet-task-ref:3f2d9f5f-18d8-4aaa-ae00-0d552e781975 -->

- 范围：`http_get`、`http_get_progress` 增加 curl `-fSL --retry 3 --retry-delay 2` 与 wget 重试参数；失败删除目标文件。
- 依赖：1.2。
- 实现要点：两个客户端分支统一返回非零；所有失败路径执行 `rm -f "$out"`；API 请求保留自定义 Header。
- RED：新增 `http_404_removes_partial`，用本地 Python HTTP 服务返回 404（或 `file://` 不存在路径），断言返回非零且目标不存在。
- GREEN：测试通过；正常 `file://` 下载成功。
- 验收：HTTP 错误与连接失败均不留下残包。

### 任务 2.2 哈希工具检测与统一校验
<!-- comet-task-ref:b42a96af-2e0d-4b9e-adeb-2b9ddb1b29ef -->

- 范围：一次性检测 `shasum`/`sha256sum`；哈希统一小写；新增 `verify_file_size_hash` 供方案/词库/模型复用。
- 依赖：2.1。
- 实现要点：`HASH_TOOL` 为空时只告警一次并跳过内容哈希；远端哈希为空时告警并仅校验大小；大小或哈希不匹配返回非零且删除文件。
- RED：新增 `hash_mismatch_fails`、`hash_tool_absent_degrades`，当前实现没有哈希校验，测试失败。
- GREEN：两个测试通过；哈希大小写不同仍视为一致。
- 验收：坏哈希中止；无哈希工具时降级而非误判。

### 任务 2.3 移除残包即成功逻辑
<!-- comet-task-ref:07a12564-ad67-410b-bc06-c154c4aeab13 -->

- 范围：删除 `download_and_verify` 中“命令失败但文件非空即成功”的分支。
- 依赖：2.1、2.2。
- 实现要点：下载命令失败直接 `error_exit` 或返回非零；随后再做大小与哈希校验。
- RED：新增 `partial_download_fails`，让 fake HTTP 客户端写入部分内容后返回非零，当前实现会接受该文件。
- GREEN：测试通过，流程不进入解压。
- 验收：残包不会进入应用阶段。

## 3. Release 发现与版本比较

### 任务 3.1 分页与缓存
<!-- comet-task-ref:cc2292d4-26f3-4db0-93c3-a6828518f862 -->

- 范围：CNB `page_size=100`、GitHub `per_page=100`；方案与词库共用 `github_releases.json`；移除 `TOOLS_API`。
- 依赖：2.1。
- 实现要点：`cache_cnb` 拼接两个查询参数；`cache_github` 接受完整 URL；`update_schema` 与 `update_dict` 使用同一缓存键。
- RED：新增 `cnb_page_size`（fake curl 记录请求 URL）与 `github_single_request`（统计请求次数），当前实现失败。
- GREEN：测试通过；CNB 合并数量正确。
- 验收：CNB 分页参数与 GitHub 请求次数符合预期。

### 任务 3.2 标题 + tag 选择与资产回退
<!-- comet-task-ref:79eb794f-3991-4d1a-8431-fbf9c7bba5f6 -->

- 范围：方案/词库 release 选择改为标题 + tag 正则；标题未命中时 tag 回退并告警；词库资产名精确匹配失败时按 `-dicts.zip` 后缀匹配。
- 依赖：3.1、3.3。
- 实现要点：新增 `select_scheme_release`、`select_dict_release`、`get_asset`；CNB 标题字段 `.title`，GitHub 为 `.name`；tag 去 `refs/tags/` 与 `v` 后比较。
- RED：新增 `scheme_release_by_title`、`dict_release_by_title`、`dict_asset_suffix_fallback`，当前实现按 tag 排序，测试失败。
- GREEN：测试通过，选择 `v18.1.8` 与词库 release，不选模型/安卓。
- 验收：fixture 下选择结果稳定，回退路径有告警。

### 任务 3.3 可移植版本比较
<!-- comet-task-ref:69c0cfec-2479-4032-9346-7ea537bd3c2e -->

- 范围：实现逐段数值比较，移除 `sort -V` 与 `sort -rV`。
- 依赖：无（可在 3.2 前完成）。
- 实现要点：`version_gt` 按 `.` 拆分，缺段补 0，非数字返回不可比较；`get_newer` 改为调用它。
- RED：新增 `version_compare_cases`，当前 `sort -V` 在模拟无 `sort -V` 的环境下失败。
- GREEN：测试通过，覆盖 `v18.1.8 < v18.1.9`、`v9.9.9 < v18.1.8`、相等。
- 验收：不依赖 `sort -V`，在 `/bin/bash` 下通过。

## 4. 方案更新

### 任务 4.1 方案哈希记录与判定
<!-- comet-task-ref:045e2216-2e12-471b-8b20-95fb28f64153 -->

- 范围：新增 `custom/.scheme_sha256`；实现同版本哈希不同、记录缺失、本地更高、全部一致四种分支。
- 依赖：2.2、3.2。
- 实现要点：抽取纯函数 `scheme_decision` 返回 `update|skip|downgrade|unknown`，便于测试；记录只在同步成功后写入。
- RED：新增 `scheme_decision_cases`，当前无该函数。
- GREEN：四类用例通过。
- 验收：分支判定正确，且跳过时无下载。

### 任务 4.2 排除匹配语义
<!-- comet-task-ref:8635cd3c-f42a-43d6-a337-d4049f539b4e -->

- 范围：不含 `/` 的模式只匹配根目录；含 `/` 的模式匹配完整相对路径。
- 依赖：4.1。
- 实现要点：新增 `is_excluded`；`create_exclude_file` 增加语义注释；同步循环调用该函数。
- RED：新增 `exclude_root_only`，当前 `*.custom.yaml` 会跳过 `custom/wanxiang.custom.yaml`。
- GREEN：测试通过：模板写入、根目录用户文件保留、排除文件自身保留。
- 验收：三类文件结果符合 spec。

### 任务 4.3 通用解压根与 build 清理
<!-- comet-task-ref:4db929fb-ee54-49ce-b1b8-a86a15228d9c -->

- 范围：`resolve_extract_root` 支持单一顶层目录；方案同步使用它；成功后 `rm -rf "$DEPLOY_DIR/build"`。
- 依赖：4.2。
- 实现要点：用 `find -mindepth 1 -maxdepth 1` 统计顶层条目；同步源改为解析后的根。
- RED：新增 `scheme_root_and_build_cleanup`，使用带单顶层目录的 fixture，当前会多一层目录。
- GREEN：测试通过，文件落点正确且 `build/` 被删除。
- 验收：真实方案包与 fixture 均正确。

### 任务 4.4 失败不落盘
<!-- comet-task-ref:cd7cccee-b8b6-4000-933a-5b4b4fb01466 -->

- 范围：方案下载/哈希失败时中止，不修改部署目录、不写记录。
- 依赖：4.1-4.3。
- 实现要点：校验全部放在解压与同步之前；`error_exit` 前不改动部署目录；记录写入放在同步成功之后。
- RED：新增 `scheme_bad_hash_no_change`，当前实现会先解压覆盖。
- GREEN：测试通过，部署目录快照与记录均未变化。
- 验收：坏包零副作用。

## 5. 词库与语法模型

### 任务 5.1 词库校验后应用
<!-- comet-task-ref:7e5a1cd1-e25c-46d1-85d8-0eec1d18d4c3 -->

- 范围：词库先校验再解压覆盖；剥离单一顶层目录；`dicts/` 缺失或为空强制更新。
- 依赖：4.3、2.2。
- 实现要点：复用 `resolve_extract_root`；用 `find | head -n 1` 判断目录是否为空；哈希记录成功后写入。
- RED：新增 `dict_bad_hash_keeps_existing`、`dict_topdir_stripped`、`dict_missing_forces_update`，当前实现先覆盖。
- GREEN：三个测试通过。
- 验收：坏包不改变 `dicts/`；顶层目录正确剥离；缺失目录触发更新。

### 任务 5.2 模型本地哈希与原子替换
<!-- comet-task-ref:6b5429c2-dc1f-408b-966a-c337783f590c -->

- 范围：下载前比对本地文件哈希；下载到部署目录内临时文件，校验后 `mv` 替换。
- 依赖：5.1、2.2。
- 实现要点：临时文件路径 `$DEPLOY_DIR/.${GRAM_NAME}.tmp`；`cleanup` 删除未完成的临时文件；记录与远端一致且本地哈希一致才跳过。
- RED：新增 `gram_skip_when_local_matches`、`gram_bad_hash_keeps_old`，当前实现会重复下载或直接覆盖。
- GREEN：两个测试通过。
- 验收：已最新不下载；失败保留旧模型且无临时文件。

## 6. 部署触发、兼容性与实测

### 任务 6.1 自定义部署目录引擎推断
<!-- comet-task-ref:6a07cd03-6602-4006-8540-b38b3babebcb -->

- 范围：`--depdir` 含 `RimeUserData` 时识别为元书，否则仓。
- 依赖：1.2。
- 实现要点：`detect_deploy_dir` 在 `DEPLOY_DIR` 非空时按路径推断；`deploy_ios` 复用 `RIME_ENGINE`。
- RED：新增 `depdir_engine_inference`，当前自定义目录固定走仓 URL。
- GREEN：测试通过，分别输出 `hamster3://` 与 `hamster://`。
- 验收：两种路径 Scheme 正确。

### 任务 6.2 自动部署关闭与工具缺失
<!-- comet-task-ref:86748c94-e884-4269-985c-11636b801b67 -->

- 范围：`--no-deploy`/`AUTO_DEPLOY=false` 不调用命令；跳转工具缺失输出 URL 与手动提示，不判失败。
- 依赖：6.1。
- 实现要点：保持现有分支；确保返回值不设置失败状态；输出完整 Scheme。
- RED：新增 `deploy_disabled_no_call` 与 `deploy_tool_missing_hint`，当前工具缺失时输出基本符合，但需断言不失败。
- GREEN：测试通过。
- 验收：关闭时零调用；缺失时提示完整。

### 任务 6.3 bash 3.2 兼容与静态检查
<!-- comet-task-ref:a524bcd8-a909-4fac-beb4-4a47be934c41 -->

- 范围：语法与禁用特性扫描；`/bin/bash` 运行帮助。
- 依赖：全部实现任务。
- 实现要点：检查关联数组、`mapfile`、`${var,,}`、`sort -V`、`head -n -1` 不出现；`bash -n`。
- RED：新增 `compat_no_bash4_features`，当前实现含 `sort -V`。
- GREEN：测试通过；`/bin/bash wanxiang-update-ios.sh --help` 正常。
- 验收：兼容性检查全绿。

### 任务 6.4 端到端实测
<!-- comet-task-ref:71928f0e-329f-477d-b39a-3318bbdd7631 -->

- 范围：临时部署目录分别用 CNB 与 GitHub 运行方案+词库；模型验证“已最新则跳过”。
- 依赖：6.1-6.3。
- 实现要点：使用 `--depdir` 指向临时目录；保留日志与文件清单；不触碰真实输入法目录。
- RED：无（集成验收任务，依赖前述测试）。
- GREEN：两次运行均成功，检查 `version.txt`、`custom/` 模板、`custom/.scheme_sha256`、`custom/.dict_sha256`、模型文件与用户文件保留。
- 验收：两个镜像均可完成更新且行为一致。

### 任务 6.5 帮助与注释一致性
<!-- comet-task-ref:b90de09b-63c8-457c-9320-e38d2a43a7b5 -->

- 范围：更新头部依赖说明、排除规则注释、`--help` 文案。
- 依赖：6.3。
- 实现要点：说明哈希工具可选、`--doctor` 不依赖 jq、排除规则根目录语义。
- RED：无（文档一致性任务）。
- GREEN：人工核对 `--help`/`--doctor` 输出与注释一致。
- 验收：文档与实现无偏差。

## 7. 复审修复（Verify 返回 Build）

Verify 最终集成审查发现 2 个 IMPORTANT（GitHub release 未分页；方案记录缺失且远端无 sha256 时误跳过）与 2 个可修复 WARNING（大小无法比较时校验失效；记录写入未检查）。本节任务只修复这些问题与对应测试强度，不改变已确认的 CLI、默认行为和排除语义。

### 任务 7.1 GitHub releases 分页
<!-- comet-task-ref:e88067f3-5b33-4368-910d-25ba03cdbea4 -->

- 范围：`cache_github` 按 `page=N&per_page=100` 循环请求并合并 `.` 数组，安全上限 100 页；方案与词库仍共用 `github_releases.json`；模型 `tags/LTS` 端点不分页。
- 依赖：3.1。
- 实现要点：复用 CNB 分页的合并与错误检测模式；每页为数组且非空时继续，空数组或请求失败时结束并保留已合并结果；达到上限报错。
- RED：新增 `github_pagination_merge` 用例，fake curl 按 `page` 返回 1/2/3 页，断言合并数量与请求次数，当前单次请求实现失败。
- GREEN：测试通过；已有 `github_single_request` 仍通过。
- 验收：GitHub 414 条 release 可完整抓取，且一次运行只抓一次列表。

### 任务 7.2 方案判定记录缺失分支
<!-- comet-task-ref:cff45634-ab37-48b7-91c1-1719cd94ed3a -->

- 范围：`scheme_decision` 在本地记录缺失时返回 `update`，不受远端哈希是否为空影响。
- 依赖：4.1。
- 实现要点：先判本地版本；同版本时 `[[ -z "$local_hash" ]]` 直接 `update`；有记录且远端无哈希时按版本 `skip`。
- RED：扩展 `scheme_decision_cases`，新增 `v18.1.8 '' v18.1.8 aa` 期望 `update`，当前实现返回 `skip`。
- GREEN：全部用例通过。
- 验收：记录缺失只触发一次更新用于补模板与记录。

### 任务 7.3 校验缺口
<!-- comet-task-ref:859267d8-3b34-4431-a031-81d1d845c1aa -->

- 范围：`verify_file_size_hash` 在大小无法比较且无哈希工具时返回非零并删除文件。
- 依赖：2.2。
- 实现要点：记录是否实际完成大小校验；哈希工具缺失且大小也未校验时视为失败；仅大小校验成功时保持降级通过。
- RED：新增 `unverifiable_without_hash_tool`，远端大小非数字并隐藏哈希工具，断言返回非零且文件被删除；当前实现返回 0。
- GREEN：测试通过；`hash_tool_absent_degrades` 仍通过。
- 验收：未经任何校验的文件不进入应用阶段。

### 任务 7.4 记录写入失败处理
<!-- comet-task-ref:2ea7a52a-a07f-4cc2-8357-28472613a37e -->

- 范围：方案与模型哈希记录写入失败时设置 `UPDATE_FAILED` 并报错。
- 依赖：4.1、5.2。
- 实现要点：`printf > file` 后检查返回码；失败时 `log ERROR` 并 `UPDATE_FAILED="true"`，不中断其他组件更新。
- RED：无独立测试（只读 `custom/` 在 root 下不可靠），由代码审查核对。
- GREEN：现有测试全绿。
- 验收：记录无法写入时不会静默报告成功。

### 任务 7.5 测试补强
<!-- comet-task-ref:90a9a0b0-2f14-4a04-9d33-5fb5e7d4f452 -->

- 范围：CNB 分页用例改为第 1、2 页均非空第 3 页空；新增 GitHub 分页、方案成功更新用例。
- 依赖：7.1-7.4。
- 实现要点：`test_cnb_pagination_merge` 增加第 2 页数据并断言 3 条；`test_scheme_update_success` 用 zip fixture 验证明文落盘与记录写入；`test_scheme_decision_cases` 覆盖记录缺失。
- RED：新断言在当前实现下失败（CNB 单页实现也能通过旧断言，需先强化）。
- GREEN：`bash tests/test-wanxiang-update.sh` 与 `/bin/bash tests/test-wanxiang-update.sh` 均 0 失败。
- 验收：分页与方案成功路径有真实覆盖。

## 风险与回退

- 首次升级会执行一次方案更新：预期行为；回退只需恢复旧脚本，哈希记录会被忽略。
- 端到端实测依赖网络：若 CNB/GitHub 不可达，保留单元与 fixture 结果，记录未完成项并在 Verify 前重试。
- 测试使用本地 HTTP 服务与 fixture，不依赖外网；外网仅用于 6.4。
