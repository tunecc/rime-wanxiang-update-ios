# Comet Design Handoff

- Change: harden-ios-updater
- Phase: design
- Mode: compact
- Context hash: 427198dfab2cdcde3ba10227dc3fcdb642bc98385a77dc216cdd214980238c29

Generated-by: comet-handoff.sh
Task hash policy: task-content-v1. Read tasks.md for live completion; excerpts are design-time context.

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## docs/openspec/changes/harden-ios-updater/proposal.md

- Source: docs/openspec/changes/harden-ios-updater/proposal.md
- Lines: 1-42
- SHA256: 02eaf99d9d31bf7e3a32da00af714cb5e276a0a91c230dafcafcb38ab291138f

```md
# 提案：加固 iOS 万象更新脚本

## 为什么

`wanxiang-update-ios.sh` 是越狱 iOS（Filza / NewTerm / SSH）上更新万象方案的主线脚本，当前存在会直接损坏用户数据或让更新静默失败的问题：

- 排除规则 `*.custom.yaml` 会同时跳过方案包 `custom/` 下的默认模板，导致新装或更新后缺少模板文件，用户无法按文档初始化自定义配置。
- `http_get` 不带 `-f`，curl 遇到 HTTP 4xx/5xx 仍返回 0；下载失败后残留的非空文件会被当作成功，方案包与词库没有任何内容哈希校验。
- 词库在 sha256 校验之前就解压覆盖 `dicts/`，坏包会污染本地词库；420MB 语法模型不先比对本地文件哈希，镜像时间漂移就会重复下载。
- 方案版本靠 `grep` tag + `sort -V` 猜测，而不是按 release 标题与版本号正则选择，`sort -V` 在 iOS 上也不保证可用。
- CNB 分页固定按默认 page_size 拉 14–15 次；缺少 `--help`/`--doctor` 在依赖缺失时的可用性；`--depdir` 自定义目录时部署仍按仓输入法跳转。
- 参数缺值时静默 `shift`，可能把下一个参数当作值吞掉。

这些缺陷与参考实现 `rime-wanxiang-update-win-mac-ios-android.py` 已有语义不一致，需要在保持现有 CLI 与默认行为不变的前提下对齐。

## 变更内容

- **排除规则语义**：不含 `/` 的模式只匹配部署根目录下的文件（保护根目录 `*.custom.yaml` 用户文件）；含 `/` 的模式按完整相对路径匹配；`custom/` 下的模板正常写入，不再被 `*.custom.yaml` 误伤。
- **下载健壮性**：`curl -fSL --retry` / `wget` 重试；失败删除残包；应用前完成大小 + sha256 校验；无哈希工具时明确告警并降级为仅大小校验，而不是误判失败。
- **版本选择**：按 release 标题（`万象拼音输入方案` / `词库` / `实时全量预览`）与 tag 正则选择方案与词库 release，移除对 `sort -V` 的依赖，改为可移植的版本比较。
- **CNB 分页**：请求 `page_size=100`，并保留分页安全上限；GitHub 使用 `per_page=100`，方案与词库共享同一份 releases JSON。
- **方案更新**：引入远端 sha256 记录 `custom/.scheme_sha256`；同版本但哈希变化也更新；记录缺失时执行一次更新以补齐模板；校验通过后再增量同步；成功后清理 `build/`。
- **词库更新**：先校验哈希再解压覆盖；`dicts/` 缺失或为空时强制更新；解压时泛化剥离单一顶层目录，不再依赖 zip 文件名。
- **模型更新**：下载前先对本地文件计算哈希，命中记录则跳过；校验通过后通过临时文件 + `mv` 原子替换。
- **入口与参数**：`--help`/`--doctor` 在依赖检查之前解析；`--doctor` 区分必装与可选工具；所有带值参数检查缺值并报错退出；`--depdir` 指向 `RimeUserData` 时按元书输入法选择部署 URL。

## 能力

### 新增能力

- `wanxiang-ios-updater`：iOS 越狱终端上万象方案、词库、语法模型的检查、下载、校验、增量部署与跳转重新部署行为。

### 修改的能力

无（仓库当前没有已归档的 spec）。

## 影响

- 仅修改 `wanxiang-update-ios.sh`；`rime-wanxiang-update-win-mac-ios-android.py` 仅作参考，不改动。
- 依赖保持不变：`jq`、`unzip`（或支持 zip 的 `tar`）、`curl` 或 `wget`；`shasum`/`sha256sum` 为可选，缺失时降级。
- 不删除用户已有文件，不改变现有 CLI 参数与默认镜像/辅助码/更新范围。
- 不涉及自更新、Token 鉴权、断点续传或 Python 脚本行为变更。

```

## docs/openspec/changes/harden-ios-updater/design.md

- Source: docs/openspec/changes/harden-ios-updater/design.md
- Lines: 1-128
- SHA256: 93d7d1b6fc94b600d26411ce1bc9bb6ce6970154c63772c815904e013329da4b

[TRUNCATED]

```md
---
comet_change: harden-ios-updater
role: technical-design
canonical_spec: openspec
---

# 设计：加固 iOS 万象更新脚本

## 上下文

参见 `proposal.md` 的“为什么”。当前脚本是单文件 bash 脚本，运行在越狱 iOS 的 Filza / NewTerm / SSH 中，需兼容 iOS 自带的 bash 3.2 与 BSD 工具链，并尽量不新增依赖。方案、词库、模型分别来自 GitHub Releases 与 CNB Releases，两者的 JSON 结构与分页方式不同。

已确认的远端事实：

- CNB release 列表默认每页 10 条，`page_size=100` 可用；方案 tag 形如 `v18.1.8`，词库预览 tag 为 `v1.0.0`，模型 tag 为 `model`。
- GitHub 方案 tag 形如 `v18.1.8`，词库预览 tag 为 `dict-nightly`，模型按 `LTS` 精确请求。
- 方案包 `rime-wanxiang-base.zip` 没有统一顶层目录；词库包 `base-dicts.zip` 有与包名同名的顶层目录。
- 方案包内 `custom/` 是项目维护的模板，根目录 `*.custom.yaml` 是用户文件。
- 远端资产同时提供 sha256（GitHub `digest`、CNB `hash_value`）。

## 目标 / 非目标

**目标：**

- 修复会导致数据损坏或静默失败的问题，且不改变现有 CLI、默认值和更新范围。
- 所有覆盖部署目录的操作都可验证、可失败即停。
- 保持 bash 3.2 与 BSD 工具链兼容。

**非目标：**

- 不删除新方案包中已不存在的旧文件（用户已确认保留）。
- 不保护根目录 `custom_phrase.dict.yaml`（用户已确认继续覆盖）。
- 不实现脚本自更新、Token 鉴权、断点续传。
- 不修改 Python 参考脚本。

## 决策

### 1. 排除规则按“是否含 `/`”区分根目录与全路径

排除文件中的模式分两类：

- 不含 `/`（如 `*.custom.yaml`、`*.userdb`）：仅匹配部署根目录下的文件名，即相对路径不含 `/` 时才参与匹配。
- 含 `/`（如 `custom/user_exclude_file.txt`）：按完整相对路径匹配。

实现时先判断相对路径是否含 `/`，再决定是否应用无斜杠模式。保留 bash `[[ ]]` 中 `*` 可跨 `/` 的行为用于含斜杠模式。生成的排除文件增加注释说明该语义，避免用户误以为 `*.custom.yaml` 会递归匹配。

备选：完全移除 `*.custom.yaml`。否决，因为会失去对根目录用户配置的保护；改为根目录匹配即可同时满足两个目标。

### 2. Release 选择改为标题 + tag 正则，移除 `sort -V`

- 方案：标题包含 `万象拼音输入方案`，且 tag 匹配 `^v[0-9]+\.[0-9]+\.[0-9]+$`。
- 词库：标题包含 `词库` 或 `实时全量预览`，并使用该 release 内的词库资产。
- 若标题规则在某一镜像上未命中，回退为：排除模型/安卓/词库预览后的 tag 候选，用可移植比较器取最大，并输出告警说明使用了回退。
- 词库资产名解析失败时，可按资产名后缀模式（`*-dicts.zip`）在该 release 内匹配唯一资产，而不是写死完整名称。

版本比较实现为按 `.` 拆分、逐段数值比较；忽略 `v` 前缀，非数字段按 0 处理或直接判定不可比较并报错。不依赖 `sort -V`。

### 3. HTTP 与完整性校验分层

- `curl`：`-fSL --connect-timeout 10 --retry 3 --retry-delay 2`；`wget`：`--tries=3 --timeout=30`。API 与文件下载共用同一失败语义。
- 下载到临时路径；命令失败即删除临时文件。
- 应用前依次校验：文件非空 → 大小（双方均为数字时）→ sha256（远端提供且本地有哈希工具时）。
- 哈希工具检测一次，结果存入全局变量；工具缺失时只告警一次并降级，不把更新判失败。
- 哈希统一转小写后比较，兼容不同镜像的大小写写法。

备选：仅依赖大小校验。否决，大小相同但内容损坏的情况无法发现，且用户明确要求对齐 Python 参考实现。

### 4. 方案更新增加内容哈希记录

新增 `custom/.scheme_sha256`，保存当前已应用方案资产的远端 sha256。判定顺序：

1. 本地版本缺失 → 更新。
2. 远端版本高于本地 → 更新。
3. 版本相同且远端哈希可用：与记录不同 → 更新；相同 → 跳过。
4. 版本相同但记录缺失 → 更新一次以补齐模板与记录。
5. 本地版本更高 → 不降级。

更新后写入新记录；记录只在下载、校验、同步全部成功后写入。远端未提供哈希时退化为仅按版本判定，并告警。

### 5. 解压根目录通用化

```

Full source: docs/openspec/changes/harden-ios-updater/design.md

## docs/openspec/changes/harden-ios-updater/tasks.md

- Source: docs/openspec/changes/harden-ios-updater/tasks.md
- Lines: 1-39
- SHA256: 3f884e7af2745af3ea50085754c0436e7ca459df9cc5c29240cd5dda36cfb053

```md
# 任务

## 1. 入口参数与依赖检查

- [ ] 1.1 调整入口顺序：先解析参数并校验取值，再执行依赖检查；`--help`、`--doctor` 在依赖检查前直接输出并退出（验证：临时 PATH 移除 `jq` 后执行 `--help` 与 `--doctor` 均能正常输出） <!-- comet-task:599c9c5a-b2b6-4926-a780-68a4bd04c8c2 -->
- [ ] 1.2 为 `--mirror`、`--fuzhu`、`--schema`、`--depdir` 增加缺值与非法值检查，未知参数报错退出（验证：单独执行 `--fuzhu` 返回非零并提示缺值；`--fuzhu foo` 提示非法取值；`--bogus` 报未知参数） <!-- comet-task:4ab2fa02-0327-4af3-bb33-824475ded634 -->
- [ ] 1.3 `--doctor` 区分必装与可选工具，缺少可选工具时只给出可选提示（验证：构造缺少 `shasum`、`uiopen` 的环境，输出仍判定环境可用） <!-- comet-task:f83538df-22e5-4609-af97-2d0548ace5a6 -->

## 2. HTTP 下载与完整性校验

- [ ] 2.1 更新 HTTP 封装：curl 使用 `-fSL --retry`，wget 使用重试参数，失败后删除残留文件（验证：对返回 404 的 URL 调用下载函数，函数返回非零且目标路径不存在） <!-- comet-task:3f2d9f5f-18d8-4aaa-ae00-0d552e781975 -->
- [ ] 2.2 增加哈希工具一次性检测与哈希小写规范化，统一“大小 + sha256”校验入口（验证：大小正确但哈希错误的文件校验失败；隐藏 `shasum`/`sha256sum` 后校验仅告警并通过大小检查） <!-- comet-task:b42a96af-2e0d-4b9e-adeb-2b9ddb1b29ef -->
- [ ] 2.3 移除“下载命令失败但文件非空即视为成功”的逻辑（验证：模拟中途失败并留下部分文件的场景，更新流程判定失败且不进入解压） <!-- comet-task:07a12564-ad67-410b-bc06-c154c4aeab13 -->

## 3. Release 发现与版本比较

- [ ] 3.1 CNB 分页改为 `page_size=100`，GitHub 改为 `per_page=100`，方案与词库共用同一份 GitHub releases 缓存，移除未使用的 `TOOLS_API`（验证：抓取 CNB 列表的 release 总数与远端一致；一次运行中 GitHub releases 端点只被请求一次） <!-- comet-task:cc2292d4-26f3-4db0-93c3-a6828518f862 -->
- [ ] 3.2 方案与词库 release 改为按标题 + tag 正则选择，标题未命中时使用 tag 回退并告警（验证：使用保存的 CNB 与 GitHub JSON 响应，选出方案 `v18.1.8` 和对应词库 release，不选模型/安卓包） <!-- comet-task:79eb794f-3991-4d1a-8431-fbf9c7bba5f6 -->
- [ ] 3.3 用可移植的逐段数值比较替换 `sort -V`（验证：`v18.1.8` < `v18.1.9`、`v9.9.9` < `v18.1.8`、相同版本返回相等，且在 `/bin/bash` 下运行通过） <!-- comet-task:69c0cfec-2479-4032-9346-7ea537bd3c2e -->

## 4. 方案更新

- [ ] 4.1 增加 `custom/.scheme_sha256` 记录与判定：同版本哈希不同则更新、记录缺失则更新一次、本地版本更高不降级、全部一致则跳过（验证：分别构造四种场景的本地状态与远端信息，确认走对应分支且只在成功应用后写记录） <!-- comet-task:045e2216-2e12-471b-8b20-95fb28f64153 -->
- [ ] 4.2 重写排除匹配：不含 `/` 的模式只匹配根目录，含 `/` 的模式匹配完整相对路径（验证：`custom/wanxiang.custom.yaml` 被写入，根目录 `wanxiang.custom.yaml` 保持不变，`custom/user_exclude_file.txt` 自身保留） <!-- comet-task:8635cd3c-f42a-43d6-a337-d4049f539b4e -->
- [ ] 4.3 增加通用解压根解析并在方案同步中使用，安装模板后清理 `build/`（验证：用真实方案包解压到临时部署目录，确认无多余顶层目录、模板存在、`build/` 被删除） <!-- comet-task:4db929fb-ee54-49ce-b1b8-a86a15228d9c -->
- [ ] 4.4 方案下载或哈希校验失败时中止，不修改部署目录、不写哈希记录（验证：使用被篡改的压缩包运行更新，部署目录文件列表与哈希记录均未变化） <!-- comet-task:cd7cccee-b8b6-4000-933a-5b4b4fb01466 -->

## 5. 词库与语法模型

- [ ] 5.1 词库改为校验通过后再解压覆盖；剥离单一顶层目录；`dicts/` 缺失或为空时强制更新（验证：坏包不改变 `dicts/`；顶层目录名与压缩包名不同的 fixture 能正确落盘；删除 `dicts/` 后触发更新） <!-- comet-task:7e5a1cd1-e25c-46d1-85d8-0eec1d18d4c3 -->
- [ ] 5.2 模型下载前先比对本地文件哈希，下载到部署目录内临时文件并原子替换（验证：本地模型与远端一致时不发起下载；校验失败时旧模型保留且无临时文件残留） <!-- comet-task:6b5429c2-dc1f-408b-966a-c337783f590c -->

## 6. 部署触发、兼容性与实测

- [ ] 6.1 `--depdir` 指向 `RimeUserData` 时按元书选择 URL Scheme，其他路径按仓选择（验证：两种路径分别输出 `hamster3://` 与 `hamster://` 对应 Scheme） <!-- comet-task:6a07cd03-6602-4006-8540-b38b3babebcb -->
- [ ] 6.2 保持 `AUTO_DEPLOY=false` 与跳转工具缺失时的行为：不调用命令、输出目标 URL 与手动部署提示，且不判定更新失败（验证：关闭自动部署运行后无命令调用且退出正常；隐藏跳转工具后输出警告与 URL） <!-- comet-task:86748c94-e884-4269-985c-11636b801b67 -->
- [ ] 6.3 检查 bash 3.2 兼容性（验证：`bash -n` 通过；脚本中不出现关联数组、`mapfile`、`${var,,}`、`sort -V`；用 `/bin/bash` 执行 `--help` 正常） <!-- comet-task:a524bcd8-a909-4fac-beb4-4a47be934c41 -->
- [ ] 6.4 在当前 macOS 环境用临时部署目录做端到端实测：CNB 与 GitHub 各跑一次方案+词库，再跑一次模型检查（验证：版本号、`custom/` 模板、`custom/.scheme_sha256`、`custom/.dict_sha256`、模型文件与日志一致，用户文件未被删除） <!-- comet-task:71928f0e-329f-477d-b39a-3318bbdd7631 -->
- [ ] 6.5 更新脚本头部的依赖说明与排除规则注释，使其与实现一致（验证：`--help`、`--doctor` 输出和注释描述与代码行为一致） <!-- comet-task:b90de09b-63c8-457c-9320-e38d2a43a7b5 -->

```

## docs/openspec/changes/harden-ios-updater/.openspec.yaml

- Source: docs/openspec/changes/harden-ios-updater/.openspec.yaml
- Lines: 1-2
- SHA256: 63c33196de2338bdf6e21f3250c142e14ca5861ffa1e6f6d57f9775f783b11ac

```md
schema: spec-driven
created: 2026-10-26

```

## docs/openspec/changes/harden-ios-updater/specs/wanxiang-ios-updater/spec.md

- Source: docs/openspec/changes/harden-ios-updater/specs/wanxiang-ios-updater/spec.md
- Lines: 1-203
- SHA256: fb817731d6926c963ba3b61d95dbe3a0ef1e5284a356e2e2610abd63d7c8e32c

[TRUNCATED]

```md
# Spec Delta

## Purpose

定义 iOS 越狱终端（Filza / NewTerm / SSH）上使用 `wanxiang-update-ios.sh` 更新万象拼音方案、词库与语法模型时的可观察行为，包括依赖检查、版本发现、下载校验、增量部署、用户数据保护和输入法跳转。

## ADDED Requirements

### Requirement: 入口参数与依赖检查

脚本 SHALL 先解析命令行参数，再执行依赖检查。`--help` 和 `--doctor` MUST 在缺少任何运行时依赖时仍可正常输出。带值参数（`--mirror`、`--fuzhu`、`--schema`、`--depdir`）缺少值或值非法时，脚本 MUST 以非零退出码报错，且不得把后续参数误当作该参数的值。

#### Scenario: 缺少 jq 时查看帮助

- **WHEN** 系统未安装 `jq`，用户执行 `--help` 或 `--doctor`
- **THEN** 脚本输出帮助或自检信息并正常退出，不因依赖缺失而提前中止

#### Scenario: 参数缺值

- **WHEN** 用户执行 `--fuzhu` 后未提供值
- **THEN** 脚本报告该参数缺少取值并以非零退出码退出，不继续执行更新

#### Scenario: 自检区分必装与可选工具

- **WHEN** 用户执行 `--doctor`，且只安装了必装工具（jq、解压工具、curl 或 wget）
- **THEN** 自检将必装工具标记为已满足，将缺少的可选工具（另一 HTTP 客户端、哈希工具、跳转工具）标记为可选提示，不把整体环境判定为不可用

### Requirement: 远端 Release 发现与分页

脚本 SHALL 通过 release 标题和 tag 规则识别方案与词库 release，而不是仅依赖 tag 排序。CNB 请求 MUST 使用 `page_size=100`（或在单页上限内请求），GitHub 请求 MUST 使用 `per_page=100`，并保留分页安全上限。脚本 MUST NOT 依赖 `sort -V` 等不保证在 iOS 上可用的外部排序能力来判断版本高低。

#### Scenario: 从混合 release 列表选方案版本

- **WHEN** 远端 release 列表同时包含方案、词库预览、模型和安卓包
- **THEN** 脚本仅选择标题含“万象拼音输入方案”且 tag 符合版本号格式的 release 作为方案版本

#### Scenario: 选择词库 release

- **WHEN** 脚本查询词库更新
- **THEN** 脚本选择标题含“词库”或“实时全量预览”的 release，并使用其中的词库资产，不使用方案 release 内的同名资产

#### Scenario: CNB 分页

- **WHEN** 脚本读取 CNB release 列表
- **THEN** 每页请求 100 条并在达到安全上限前完成翻页，且合并结果的 release 数量与远端一致

#### Scenario: 无可比较版本

- **WHEN** 本地或远端版本号无法解析为数字段
- **THEN** 脚本报告版本比较失败或按可确定的规则处理，不得错误地判定为“远端更新”并覆盖本地

### Requirement: 下载完整性与失败处理

脚本 SHALL 将 HTTP 4xx/5xx、连接中断和空响应视为下载失败。失败时 MUST 删除不完整的临时文件并可根据配置重试，不得把残留文件当作有效下载。应用任何下载内容前，脚本 MUST 校验文件大小；远端提供 sha256 时 MUST 校验内容哈希。系统缺少哈希工具时，脚本 MUST 明确告警并降级为大小校验，不得直接判定校验失败。

#### Scenario: 服务端返回 404

- **WHEN** 下载 URL 返回 HTTP 404
- **THEN** 脚本报告下载失败并退出或跳过该项，不把错误页面保存为资产文件

#### Scenario: 下载被截断

- **WHEN** 下载完成后文件大小与远端声明不一致
- **THEN** 脚本删除该文件并报告下载出错，不进入解压或覆盖流程

#### Scenario: 哈希不匹配

- **WHEN** 下载文件的大小校验通过但 sha256 与远端不一致
- **THEN** 脚本删除该文件并中止该项更新，不改动部署目录中的现有文件

#### Scenario: 缺少哈希工具

- **WHEN** 系统既没有 `shasum` 也没有 `sha256sum`，但远端提供了 sha256
- **THEN** 脚本告警说明无法校验内容哈希，继续使用大小校验结果，不把更新判定为失败

### Requirement: 方案增量部署与排除规则

方案更新 SHALL 以增量方式覆盖部署目录，不得清空整个部署目录。排除规则中不含 `/` 的模式 MUST 只匹配部署根目录下的文件；含 `/` 的模式 MUST 按完整相对路径匹配。方案包 `custom/` 下的默认模板 MUST 被写入部署目录，根目录下的用户 `*.custom.yaml` MUST 被保留。更新成功后，脚本 MUST 清理部署目录内的 `build/`。

#### Scenario: 安装 custom 模板

```

Full source: docs/openspec/changes/harden-ios-updater/specs/wanxiang-ios-updater/spec.md
