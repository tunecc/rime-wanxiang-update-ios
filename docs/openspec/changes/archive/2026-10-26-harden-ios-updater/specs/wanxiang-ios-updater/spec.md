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

- **WHEN** 部署目录不存在 `custom/wanxiang.custom.yaml`，方案包内包含该模板且排除文件含 `*.custom.yaml`
- **THEN** 更新后该模板出现在部署目录的 `custom/` 下

#### Scenario: 保留根目录用户配置

- **WHEN** 部署根目录已存在 `wanxiang.custom.yaml`
- **THEN** 更新后该文件内容保持不变

#### Scenario: 保留用户数据库

- **WHEN** 部署目录中存在 `*.userdb`、用户自定义词库或其他不在方案包内的文件
- **THEN** 更新后这些文件仍然存在且未被修改

#### Scenario: 清理构建缓存

- **WHEN** 方案更新成功且部署目录中存在 `build/`
- **THEN** 脚本删除该 `build/` 目录并继续后续部署提示

### Requirement: 方案版本与内容判定

脚本 SHALL 使用本地版本文件与远端版本比较来决定是否更新。当版本相同但远端资产 sha256 与本地记录不同时，脚本 MUST 执行更新以同步内容；当本地哈希记录缺失时，脚本 MUST 执行一次更新以补齐模板与记录。哈希记录 MUST 只在下载与校验成功后写入。

#### Scenario: 同版本内容变化

- **WHEN** 本地 `version.txt` 与远端版本相同，但远端方案资产 sha256 与 `custom/.scheme_sha256` 记录不一致
- **THEN** 脚本下载并应用该方案更新

#### Scenario: 无本地哈希记录

- **WHEN** 本地版本与远端相同但 `custom/.scheme_sha256` 不存在
- **THEN** 脚本执行一次方案更新并在成功后写入新的哈希记录

#### Scenario: 已是最新

- **WHEN** 本地版本、远端版本和本地记录的哈希均一致
- **THEN** 脚本报告无需更新，不下载方案包，也不修改部署目录

#### Scenario: 本地版本更高

- **WHEN** 本地版本高于远端最新方案版本
- **THEN** 脚本不降级，并报告本地已是最新或更新

### Requirement: 词库更新

词库更新 SHALL 在应用前完成下载与哈希校验。校验通过后，脚本 MUST 解压到部署目录的 `dicts/`；解压时 MUST 能剥离压缩包自带的单一顶层目录，且不依赖压缩包文件名与目录名一致。`dicts/` 目录缺失或为空时，脚本 MUST 强制更新，即使哈希记录一致。

#### Scenario: 坏包不覆盖词库

- **WHEN** 词库包下载完成但 sha256 校验失败
- **THEN** 脚本不修改 `dicts/` 中任何现有文件

#### Scenario: 顶层目录名与压缩包名不同

- **WHEN** 词库压缩包内所有文件都位于一个与压缩包文件名不同的顶层目录下
- **THEN** 解压后词库文件直接位于部署目录的 `dicts/` 下，不出现多余的嵌套目录

#### Scenario: 词库目录缺失

- **WHEN** 哈希记录与远端一致但部署目录的 `dicts/` 不存在或为空
- **THEN** 脚本重新下载并部署词库

### Requirement: 语法模型更新

语法模型更新 SHALL 在下载前比对本地模型文件哈希与远端哈希；一致时 MUST 跳过下载。需要更新时，脚本 MUST 先校验下载文件，再通过临时文件与原子替换写入部署目录，避免中断留下损坏模型。

#### Scenario: 本地模型已是最新

- **WHEN** 本地模型文件存在，其 sha256 与远端一致，且记录文件一致
- **THEN** 脚本跳过下载并报告模型无需更新

#### Scenario: 校验后原子替换

- **WHEN** 模型下载与校验成功
- **THEN** 部署目录中的模型被完整替换，下载过程中不会出现半写入的模型文件

#### Scenario: 模型校验失败

- **WHEN** 模型文件大小或哈希校验失败
- **THEN** 脚本保留原有模型文件并报告失败

### Requirement: 部署触发与引擎识别

脚本 SHALL 根据部署目录识别输入法引擎：路径包含 `RimeUserData` 时按元书输入法处理，否则按仓输入法处理。识别结果 MUST 同时用于选择跳转 URL Scheme。用户设置 `AUTO_DEPLOY=false` 时，脚本 MUST 跳过自动跳转并提示手动部署；跳转失败时 MUST 输出所用 URL 与可用的手动操作方式。

#### Scenario: 自定义部署目录指向元书

- **WHEN** 用户通过 `--depdir` 指定包含 `RimeUserData` 的路径
- **THEN** 更新完成后脚本使用元书输入法的 URL Scheme 尝试跳转部署

#### Scenario: 自定义部署目录指向仓

- **WHEN** 用户通过 `--depdir` 指定不包含 `RimeUserData` 的路径
- **THEN** 更新完成后脚本使用仓输入法的 URL Scheme 尝试跳转部署

#### Scenario: 关闭自动跳转

- **WHEN** 用户使用 `--no-deploy` 或设置 `AUTO_DEPLOY=false` 并完成更新
- **THEN** 脚本不调用任何 URL Scheme，并提示用户在输入法 App 内手动重新部署

#### Scenario: 跳转工具缺失

- **WHEN** 系统没有可用的 URL 打开工具，或所有可用工具均执行失败
- **THEN** 脚本输出警告、目标 URL Scheme 和手动部署建议，且不把更新结果判定为失败

### Requirement: 辅助码与更新范围选择

脚本 SHALL 保持现有命令行接口：辅助码取值限于 `base`、`flypy`、`hanxin`、`moqi`、`tiger`、`wubi`、`zrm`、`shouyou`、`shyplus`、`wx`，方案类型限于 `base` 与 `pro`，镜像限于 `github` 与 `cnb`。更新范围 MUST 继续支持 `--no-schema`、`--no-dict`、`--no-gram` 分别关闭对应更新，以及 `--no-deploy` 关闭跳转。默认 MUST 使用 `cnb` 镜像与 `flypy` 辅助码，并更新方案、词库和模型。

#### Scenario: 非法辅助码

- **WHEN** 用户传入不在允许列表中的辅助码
- **THEN** 脚本报告非法取值并退出，不发起任何下载

#### Scenario: 关闭部分更新

- **WHEN** 用户传入 `--no-dict --no-gram`
- **THEN** 脚本只执行方案更新，不请求词库与模型的 release 信息

#### Scenario: 默认执行

- **WHEN** 用户不带参数运行脚本
- **THEN** 脚本使用 `cnb` 镜像、`flypy` 辅助码、`pro` 方案，更新方案、词库和模型
