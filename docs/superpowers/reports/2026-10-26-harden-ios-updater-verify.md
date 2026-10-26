# Verify 报告：harden-ios-updater

- 日期：2026-10-26
- Change：`harden-ios-updater`
- 阶段：Verify（复审修复后重新验证）
- 基线：`af5ae05`；实现：`c2e89e8`；复审修复：`13a3fc5`、`7190391`、`bf37686`
- 执行方式：full（规模评估：20 任务 / 1 delta spec / 18 变更文件）
- 审查模式：standard
- Handoff：`FRESH`（`427198dfab2cdcde3ba10227dc3fcdb642bc98385a77dc216cdd214980238c29`）

## 结论

**通过。** 首轮独立集成审查发现的 2 个 IMPORTANT（GitHub release 未分页；方案记录缺失且远端无 sha256 时误跳过）与 2 个可修复 WARNING（大小无法比较时校验失效；哈希记录写入未检查）已全部修复。修复后全量测试 134 项在 bash 5 与 `/bin/bash 3.2.57` 下均 0 失败；实时 GitHub API 验证分页合并得到 414 条 release，方案选择 `v18.1.8`，`tags/LTS` 单对象端点正常。

## 1. 验证输入

- `docs/openspec/changes/harden-ios-updater/specs/wanxiang-ios-updater/spec.md`（9 Requirement）
- `docs/openspec/changes/harden-ios-updater/design.md`
- `docs/openspec/changes/harden-ios-updater/proposal.md`
- `docs/openspec/changes/harden-ios-updater/tasks.md`（20/20 `[x]`）
- `wanxiang-update-ios.sh`、`tests/test-wanxiang-update.sh`
- 变更 diff：`git diff af5ae05..HEAD --stat`（18 文件，提交 `c2e89e8`、`13a3fc5`、`7190391`、`bf37686`）

工作区仅剩与本 change 无关的未跟踪项（`.agents/`、`.claude/`、`.codex/`、`.qoder/`、`.zcode/`、`rime-wanxiang-update-win-mac-ios-android.py`），未纳入实现。

## 2. 检查项与证据

| 检查项 | 结果 | 证据 |
| --- | --- | --- |
| tasks.md 全部完成 | PASS | 20 个 `[x]`，0 个 `[ ]` |
| 改动文件与任务一致 | PASS | 仅脚本、测试与 OpenSpec/计划/状态产物 |
| 语法与 iOS 兼容 | PASS | `bash -n`；`test_static_compat`；无 `mapfile`、`declare -A`、`${var,,}`、`sort -V`、`head -n -1` |
| 完整测试套件 | PASS | `bash tests/test-wanxiang-update.sh` → 134 passed, 0 failed；`/bin/bash tests/test-wanxiang-update.sh` → 134 passed, 0 failed |
| 数据安全/失败路径 | PASS | 坏包/坏哈希不覆盖 `dicts/`、模型；模型临时文件原子替换；结构异常 fail-closed；记录写入失败判失败 |
| 核心成功/失败/边界场景 | PASS | 见第 3 节映射与第 6 节实测 |
| 最终集成审查 | PASS | 首轮独立审查问题全部修复；本轮按受影响范围复核，无 CRITICAL/IMPORTANT（审查方式限制见第 4 节） |
| Spec 场景覆盖 | PASS | 9/9 Requirement 有实现与测试/实测证据 |
| Design 决策一致性 | PASS | 10 项设计决策逐项落实 |
| proposal 目标满足 | PASS | 排除语义、下载校验、版本选择、分页、增量部署、模型原子替换、入口与引擎识别均已实现 |
| delta spec 与 design 无矛盾 | PASS | 记录缺失优先更新与设计决策 4 的“记录缺失→更新一次”一致；远端无哈希的版本回退适用于已有记录的场景 |
| Design Doc 可定位 | PASS | `docs/openspec/changes/harden-ios-updater/design.md` |

## 3. Requirement → 实现 → 测试映射

| # | Requirement | 关键实现 | 主要测试/实测 |
| --- | --- | --- | --- |
| 1 | 入口参数与依赖检查 | `main` 先解析参数（`wanxiang-update-ios.sh:1053`）；`--help`/`--doctor` 在 `deps_check` 前；`show_doctor` 区分必装/可选（`:945`） | `entry_help_without_jq`、`entry_doctor_without_jq`、`args_missing_value`、`args_invalid_fuzhu`、`doctor_optional_only` |
| 2 | 远端 Release 发现与分页 | CNB `page_size=100` + 合并 + 上限（`:448`）；GitHub `page=N&per_page=100` 分页合并、单对象端点不分页、方案/词库共享缓存（`:402`）；标题+tag 选择与 `-dicts.zip` 回退 | `cnb_page_size`、`cnb_pagination_merge`、`github_per_page_shared_cache`、`github_pagination_merge`、`release_select_by_title`、`asset_suffix_fallback` |
| 3 | 下载完整性与失败处理 | curl `-fsSL --retry 3`、wget 重试；非空/大小/sha256 分层校验（`:111`）；大小与哈希均无法校验时拒绝；缺哈希工具时仅在大小已校验后降级 | `http_404_removes_partial`、`partial_download_fails`、`hash_normalize_and_verify`、`hash_tool_absent_degrades`、`unverifiable_without_hash_tool`、`empty_and_unverifiable_rejected` |
| 4 | 方案增量部署与排除规则 | 增量复制、跳过 `dicts/`、结构标记校验、清理 `build/`（`:259`）；无 `/` 仅根目录、含 `/` 全路径（`:380`） | `exclude_root_only`、`scheme_root_and_build_cleanup` |
| 5 | 方案版本与内容判定 | `scheme_decision` 记录缺失优先 `update`（`:650`）；记录仅成功后写入；写入失败判失败（`:746`） | `scheme_decision_cases`、`scheme_update_success`、`scheme_record_write_failure`、`scheme_bad_hash_no_change` |
| 6 | 词库更新 | 先校验后解压；通用解压根（`:231`）；`dicts/` 缺失/空强制更新；复制前失效旧记录；记录写入失败 `error_exit`（`:825`） | `dict_bad_hash_keeps_existing`、`dict_topdir_stripped`、`dict_missing_forces_update`、`dict_partial_copy_retries` |
| 7 | 语法模型更新 | 下载前本地哈希比对；部署目录内临时文件 + `mv`；记录写入失败判失败（`:896`） | `gram_skip_when_local_matches`、`gram_bad_hash_keeps_old`、`gram_repairs_local_mismatch`、`gram_no_hash_tool_size_fallback`、`gram_no_hash_tool_size_mismatch_repairs` |
| 8 | 部署触发与引擎识别 | `--depdir` 含 `RimeUserData` 判定元书；双 Scheme；关闭跳转与工具缺失提示 | `depdir_engine_inference`、`deploy_scheme_inference`、`deploy_disabled_no_call`、`deploy_tool_missing_hint` |
| 9 | 辅助码与更新范围选择 | 允许列表与默认值；参数校验；`--no-*` 开关；base 强制 `fuzhu=base` | `args_invalid_fuzhu`、`test_static_compat`、默认路径实测 |

## 4. 设计一致性与审查

设计决策逐项核对：排除规则根目录语义、标题+tag 选择与可移植版本比较、HTTP/完整性分层、方案哈希记录、通用解压根、词库/模型应用顺序、参数前移与引擎推断、`build/` 清理、CNB/GitHub 分页（现含 GitHub 分页上限）、bash 3.2 兼容，均已落实。

首轮独立集成审查（覆盖 `c2e89e8`）发现并已修复：

| 级别 | 问题 | 修复与证据 |
| --- | --- | --- |
| IMPORTANT | GitHub 仅取首页 100 条，414 条 release 下最新方案可能跌出首页 | `cache_github` 改为 `page=N&per_page=100` 循环合并，100 页上限；`github_pagination_merge`；实时 API 验证 414 条并选出 `v18.1.8` |
| IMPORTANT | 版本相同、远端无 sha256、本地记录缺失时返回 `skip` | `scheme_decision` 改为记录缺失优先 `update`；`scheme_decision_cases` 覆盖 |
| WARNING | 大小不可比较且无哈希工具时仍返回 0（未校验即应用） | `verify_file_size_hash` 记录是否完成大小校验，两者均无则删除并失败；`unverifiable_without_hash_tool` |
| WARNING | 方案/模型哈希记录写入失败被忽略 | 写入失败设置 `UPDATE_FAILED`、保留 `NEEDED_DEPLOY` 并返回非零；`scheme_record_write_failure`；模型路径同构 |
| 测试强度 | CNB 分页第二页为空，单页实现也能通过；方案仅测坏哈希 | CNB 测试改为第 1、2 页非空、第 3 页空并断言 3 次请求；新增方案成功更新、GitHub 分页、记录写入失败用例 |

`TEMP_DIR`/trap 警告经核对不成立：`main` 在参数解析前设置 `trap cleanup EXIT`，`--help`/`--doctor` 早退会正常清理。

审查方式说明：本轮修复 delta 的外部审查代理调用被用户拒绝；主会话对 `13a3fc5..bf37686` 的脚本与测试 delta 逐项复核，覆盖分页终止条件、错误 JSON/空页/合并失败清理、校验失败删除路径、记录写入失败在 `main` 的聚合、测试 fake 的 `page=N&per_page` 模式不会误匹配 page=10/20/100，以及 bash 3.2 构造。未发现 CRITICAL/IMPORTANT。

## 5. 已接受的行为与已知限制

1. **远端不提供 sha256 时**：词库每次运行都会重新下载；模型在记录存在且大小一致时跳过。不会用未校验内容覆盖旧文件，接受。
2. **远端不提供哈希且方案记录缺失时**：每次运行都会更新方案（无法建立哈希记录），日志每次告警；上游两个镜像实际均提供哈希，接受。
3. **新方案包中已不存在的旧文件**：保留不删（用户已确认）。
4. **根目录 `custom_phrase.dict.yaml`**：继续被方案包覆盖（用户已确认）。
5. **方案包内 `dicts/`**：由词库更新独占，方案同步跳过。
6. **`verify_mode` 字段**：Comet SDK 将其视为 workflow-owned，未手动写入；规模评估建议 full，本次按 full 执行。

## 6. 端到端实测（Build 阶段记录）

- CNB、临时 `--depdir`：首轮成功更新方案 `v18.1.8` 与词库，日志包含大小与 sha256 校验通过；二次运行报告“无需更新/所有组件均为最新”。
- 部署结果：`custom/` 模板 9 个、`dicts/` 11 个文件、无 `build/`；记录 `.scheme_sha256=149a7e87…`、`.dict_sha256=fa7bd09e…`；用户文件保留。
- 任务 6.4 的 GitHub 镜像端到端实测已完成；两条镜像共用同一套 release 选择、下载与校验逻辑。
- 复审修复后补充实时验证：GitHub releases 分页合并 414 条、选择 `v18.1.8`；`/releases/tags/LTS` 仍返回单对象（`tag_name=LTS`、资产 `wanxiang-lts-zh-hans.gram`）。
- 测试全部使用临时目录，未触碰真实输入法部署目录。

## 7. 最终评估

- CRITICAL：无
- IMPORTANT：无
- WARNING：无未处理项（首轮警告均已修复）
- 结论：**通过，可进入归档**
