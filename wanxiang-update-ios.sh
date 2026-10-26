#!/usr/bin/env bash

# 万象方案更新工具 - iOS 越狱终端版 (仓输入法 / 元书输入法)
# 依赖: jq + 解压(unzip 或 tar) + curl/wget 二选一
#   (coreutils 只提供 stat/cp/rm 等, 不含这些; 不想装 curl 就装 wget)
# 可选: shasum/sha256sum(下载内容校验; 缺失时只校验大小)
#       uiopen/open/sbopenurl(自动跳转部署; 缺失时打印 URL 手动部署)
# --help / --doctor 不依赖 jq, 缺依赖时也能查看。
# 运行: 把本脚本放到输入法配置目录的同级, 然后:
#   bash wanxiang-update-ios.sh                 # 默认: cnb(免代理) + 小鹤flypy + 方案/词库/模型
#   bash wanxiang-update-ios.sh --mirror github # 走 GitHub(需代理, 匿名 60 次/小时)
#   bash wanxiang-update-ios.sh --fuzhu moqi --schema base
#   bash wanxiang-update-ios.sh --help
# 全程无交互提示, 可直接在 Filza 终端 / NewTerm / SSH 里一键跑完.

set -uo pipefail

# ====================== 配置区(可改) ======================
# 留空 = 自动按脚本所在目录自动识别仓/元书(见 detect_deploy_dir)
DEPLOY_DIR=""
# 辅助码方案: base flypy hanxin moqi tiger wubi zrm shouyou shyplus wx
DEFAULT_FUZHU="flypy"
# 下载源: github 或 cnb (默认 cnb, 免代理且无限流, 越狱机更省心)
DEFAULT_MIRROR="cnb"
# 是否跳转输入法重新部署(仓/元书各自的 URL Scheme); 设为 false 则只更新不跳转
AUTO_DEPLOY="true"
# ====================== 配置结束 ======================

CNB_API="https://cnb.cool/amzxyz/rime-wanxiang/-/releases"
SCHEMA_API="https://api.github.com/repos/amzxyz/rime_wanxiang/releases"
GRAM_API="https://api.github.com/repos/amzxyz/RIME-LMDG/releases"
GRAM_NAME="wanxiang-lts-zh-hans.gram"
FUZHU_LIST=("base" "flypy" "hanxin" "moqi" "tiger" "wubi" "zrm" "shouyou" "shyplus" "wx")
# 方案压缩包里这些文件不覆盖回输入法目录(各端专用, iOS 不需要)
DELETE_FILES=("简纯+.trime.yaml" "squirrel.yaml" "weasel.yaml" "custom_phrase.txt")
TEMP_DIR=$(mktemp -d /tmp/wanxiang-ios-XXXXXX) || { echo "无法创建临时目录 /tmp/wanxiang-ios-XXXXXX" >&2; exit 1; }

# ---------- 日志 ----------
log() {
  local red="\033[0;31m" green="\033[0;32m" yellow="\033[0;33m" nc="\033[0m"
  local level="$1" color="$nc"; shift
  case "$level" in
    INFO)  color="$green" ;;
    WARN)  color="$yellow" ;;
    ERROR) color="$red" ;;
  esac
  printf "${color}[%s] %s${nc}\n" "$level" "$*"
}

error_exit() { log ERROR "$*"; cleanup; exit 1; }

cleanup() {
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true
  # 模型下载临时文件必须在部署目录内(同分区)才能原子替换; 中断时清掉残留
  if [[ -n "$DEPLOY_DIR" && -n "$GRAM_NAME" ]]; then
    rm -f "$DEPLOY_DIR/.${GRAM_NAME}.tmp" 2>/dev/null || true
  fi
}

# ---------- 跨平台 stat / date / head ----------
# 注意: 装了 coreutils 后 stat 会变成 GNU 版, 其 -f 是"文件系统信息",
# stat -f %z 会输出 "File: <path>" 这种摘要而非字节数。所以必须只接受纯数字结果,
# 否则非数字进 [[ -ne ]] 算术求值会触发 "File: unbound variable" 崩溃。
is_uint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
file_size() { # $1 path -> 纯数字字节数 (BSD stat / GNU stat / wc 三级回退)
  local s
  s=$(stat -f %z "$1" 2>/dev/null)        # BSD/mac/iOS 自带 stat
  is_uint "$s" && { echo "$s"; return; }
  s=$(stat -c %s "$1" 2>/dev/null)         # GNU coreutils stat
  is_uint "$s" && { echo "$s"; return; }
  [[ -f "$1" ]] && wc -c <"$1" | tr -dc '0-9'   # 兜底: 读字节计数
}
# 打印除最后一行外的所有行(BSD head 不支持 -n -1)
drop_last_line() { sed -e '$d'; }

# ---------- 哈希工具 ----------
# 哈希工具是可选依赖: 有就做内容校验, 没有则降级为仅校验大小。
HASH_TOOL=""
HASH_TOOL_READY="false"
detect_hash_tool() {
  if [[ "$HASH_TOOL_READY" != "true" ]]; then
    HASH_TOOL_READY="true"
    if command -v shasum >/dev/null 2>&1; then
      HASH_TOOL="shasum"
    elif command -v sha256sum >/dev/null 2>&1; then
      HASH_TOOL="sha256sum"
    else
      HASH_TOOL=""
    fi
  fi
  [[ -n "$HASH_TOOL" ]]
}

normalize_hash() { # 去 sha256: 前缀并转小写
  local h="$1"
  case "$h" in
    [sS][hH][aA]256:*) h="${h#*:}" ;;
  esac
  printf '%s' "$h" | tr 'A-Z' 'a-z'
}

local_sha256() { # $1 path -> 小写 sha256; 无哈希工具时返回非零
  detect_hash_tool || return 1
  case "$HASH_TOOL" in
    shasum)    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' ;;
    sha256sum) sha256sum "$1" 2>/dev/null | awk '{print $1}' ;;
  esac
}

# 统一校验: 大小(可缺省) + sha256(可缺省)。失败删除文件并返回非零。
verify_file_size_hash() { # $1 file  $2 expected_size  $3 expected_hash  $4 label
  local file="$1" expected="$2" expected_hash="$3" label="$4"
  if [[ ! -f "$file" ]]; then
    log ERROR "$label 文件不存在: $file"
    return 1
  fi
  # 空响应 (HTTP 200 但 0 字节) 必须当下载失败, 否则可能用空文件覆盖旧模型
  if [[ ! -s "$file" ]]; then
    log ERROR "$label 文件为空, 已删除"
    rm -f "$file"
    return 1
  fi

  local actual; actual=$(file_size "$file")
  expected_hash=$(normalize_hash "$expected_hash")
  if ! is_uint "$expected" && [[ -z "$expected_hash" ]]; then
    log ERROR "$label 远端未提供大小或 sha256, 无法校验, 已删除"
    rm -f "$file"
    return 1
  fi
  if is_uint "$expected" && is_uint "$actual"; then
    if [[ "$actual" -ne "$expected" ]]; then
      log ERROR "$label 大小不符 (期望 $expected, 实际 $actual)"
      rm -f "$file"
      return 1
    fi
    log INFO "$label 大小校验通过 ($actual 字节)"
  else
    log WARN "$label 跳过大小校验 (远端=$expected 本地=$actual)"
  fi

  if [[ -z "$expected_hash" ]]; then
    log WARN "$label 远端未提供 sha256, 跳过内容校验"
    return 0
  fi
  if ! detect_hash_tool; then
    log WARN "$label 缺少 shasum/sha256sum, 跳过内容校验"
    return 0
  fi
  local actual_hash; actual_hash=$(normalize_hash "$(local_sha256 "$file")")
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    log ERROR "$label sha256 不符 (期望 $expected_hash, 实际 $actual_hash)"
    rm -f "$file"
    return 1
  fi
  log INFO "$label sha256 校验通过"
  return 0
}

# ---------- HTTP 客户端封装 (curl 优先, 回退 wget) ----------
# 选谁只看是否装了; 不强求 curl。
detect_http_client() {
  if command -v curl >/dev/null 2>&1; then HTTP_CLIENT="curl"
  elif command -v wget >/dev/null 2>&1; then HTTP_CLIENT="wget"
  else error_exit "缺少 HTTP 客户端: 请装 curl 或 wget 之一 (coreutils 不含)"
  fi
}

# http_get URL OUT_FILE [HEADER...] : 静默下载/API 请求(自动跟随重定向)
# curl 必须带 -f: 否则 404/500 也返回 0, 残包会被当成成功。
http_get() {
  local url="$1" out="$2"; shift 2
  local rc
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    local args=(-fsSL --connect-timeout 10 --retry 3 --retry-delay 2)
    for h in "$@"; do args+=(-H "$h"); done
    curl "${args[@]}" -o "$out" "$url"; rc=$?
  else
    local args=(-q --timeout=30 --tries=3 --waitretry=2)
    for h in "$@"; do args+=(--header="$h"); done
    wget "${args[@]}" "$url" -O "$out"; rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$out"
    return "$rc"
  fi
  return 0
}

# http_get_progress URL OUT_FILE : 带进度条的大文件下载(方案 41MB / 模型 420MB)
http_get_progress() {
  local url="$1" out="$2" rc
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    curl -fSL --connect-timeout 10 --retry 3 --retry-delay 2 -o "$out" "$url"; rc=$?
  else
    wget --timeout=30 --tries=3 --waitretry=2 "$url" -O "$out"; rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$out"
    return "$rc"
  fi
  return 0
}

# ---------- 解压 zip (unzip 优先, 回退支持 zip 的 tar/bsdtar) ----------
extract_zip() { # $1 zip 文件  $2 目标目录
  mkdir -p "$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$1" -d "$2" || error_exit "解压失败: $1 (文件可能损坏, 请重试)"
  elif command -v tar >/dev/null 2>&1; then
    tar -xf "$1" -C "$2" 2>/dev/null \
      || error_exit "解压失败: 本机 tar 不支持 zip, 请安装 unzip (Sileo/Zebra)"
  else
    error_exit "缺少解压工具: 请安装 unzip (Sileo/Zebra)"
  fi
}

# 若解压目录只有一个顶层目录, 视其为内容根; 否则目录本身即根。
resolve_extract_root() { # $1 解压目录
  local dir="$1" count first
  count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -eq 1 ]]; then
    first=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
    if [[ -d "$first" ]]; then
      printf '%s\n' "$first"
      return 0
    fi
  fi
  printf '%s\n' "$dir"
}

# 递归复制目录内所有文件(保留相对路径, 不复制空目录)
copy_tree() { # $1 源目录  $2 目标目录
  local src="$1" dest="$2" f rel manifest="$TEMP_DIR/copy_manifest.txt"
  mkdir -p "$dest"
  ( cd "$src" && find . -type f | sed 's|^\./||' ) >"$manifest" || return 1
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    mkdir -p "$dest/$(dirname "$rel")"
    cp -rf "$src/$rel" "$dest/$rel" || return 1
  done <"$manifest"
  return 0
}

# 方案增量同步: 剔除平台专用文件, 跳过排除项, 保留用户文件, 清理 build/
apply_scheme_files() { # $1 解压目录  $2 部署目录  $3 排除文件
  local src="$1" deploy="$2" exclude="$3"
  local root; root=$(resolve_extract_root "$src")
  local f rel manifest="$TEMP_DIR/schema_manifest.txt" copied=0

  [[ -f "$exclude" ]] || { log ERROR "排除文件不存在: $exclude"; return 1; }
  # 防止解压根解析错误时把文件散落到意外子目录后仍记录成功
  if [[ ! -f "$root/version.txt" && ! -f "$root/default.yaml" && ! -d "$root/custom" ]]; then
    log ERROR "方案包结构异常: 缺少 version.txt/default.yaml/custom/"
    return 1
  fi

  for f in "${DELETE_FILES[@]}"; do
    [[ -f "$root/$f" ]] && rm -f "$root/$f"
  done

  mkdir -p "$deploy"
  ( cd "$root" && find . -type f | sed 's|^\./||' ) >"$manifest" || return 1
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    # dicts/ 由词库更新独占: 方案包只带部分词库, 混入会让 .dict_sha256 与实际内容脱节
    case "$rel" in dicts|dicts/*) continue ;; esac
    if is_excluded "$rel" "$exclude"; then
      log INFO "跳过排除文件(保留本地): $rel"
      continue
    fi
    mkdir -p "$deploy/$(dirname "$rel")"
    cp -rf "$root/$rel" "$deploy/$rel" || return 1
    copied=$((copied + 1))
  done <"$manifest"

  if [[ "$copied" -eq 0 ]]; then
    log ERROR "方案包没有可应用的文件"
    return 1
  fi

  rm -rf "${deploy:?}/build"
  log INFO "已增量同步方案文件 (用户库/模型/根目录用户文件已保留)"
  return 0
}

# ---------- 依赖检查 ----------
deps_check() {
  command -v jq >/dev/null 2>&1 || error_exit "缺少依赖: jq (Sileo/Zebra 搜索 jq 安装)"
  command -v unzip >/dev/null 2>&1 || command -v tar >/dev/null 2>&1 \
    || error_exit "缺少依赖: unzip (Sileo/Zebra 搜索 unzip 安装)"
  detect_http_client
  detect_hash_tool || log WARN "未找到 shasum/sha256sum, 本次只校验文件大小, 不校验 sha256"
}

fuzhu_check() {
  local f="$1"
  for _f in "${FUZHU_LIST[@]}"; do [[ "$f" == "$_f" ]] && return 0; done
  return 1
}

# ---------- 部署目录识别 (仓 / 元书) ----------
detect_deploy_dir() {
  if [[ -n "$DEPLOY_DIR" ]]; then
    # 自定义目录也按路径推断引擎, 否则 --depdir 指到元书时会唤起错误的 URL Scheme
    # 同时覆盖相对路径 (RimeUserData/wanxiang) 与绝对路径
    case "$DEPLOY_DIR" in
      RimeUserData|RimeUserData/*|*/RimeUserData|*/RimeUserData/*) RIME_ENGINE="元书" ;;
      *) RIME_ENGINE="仓" ;;
    esac
    return 0
  fi
  local here
  here="$( cd "$( dirname "$0" )" && pwd )"

  # 元书: 脚本放在 .../RimeUserData/ 下, 方案目录 = RimeUserData/wanxiang
  if [[ -d "$here/RimeUserData" ]]; then
    RIME_ENGINE="元书"
    DEPLOY_DIR="$here/RimeUserData/wanxiang"
    return 0
  fi
  # 仓: 脚本放在 Hamster 容器根下, 同级有 RIME 或 Rime
  if [[ -d "$here/RIME" ]]; then
    RIME_ENGINE="仓"
    DEPLOY_DIR="$here/RIME/Rime"
    return 0
  fi
  if [[ -d "$here/Rime" ]]; then
    RIME_ENGINE="仓"
    DEPLOY_DIR="$here/Rime"
    return 0
  fi
  error_exit "未识别到输入法目录。请把脚本放到输入法配置目录同级(仓: 与 RIME/Rime 同级; 元书: 与 RimeUserData 同级), 或在脚本顶部设置 DEPLOY_DIR"
}

# ---------- 排除文件 ----------
EXCLUDE_FILE=""
create_exclude_file() {
  EXCLUDE_FILE="$DEPLOY_DIR/custom/user_exclude_file.txt"
  if [[ -f "$EXCLUDE_FILE" ]]; then
    log INFO "排除文件已存在: $EXCLUDE_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$EXCLUDE_FILE")" || error_exit "无法创建排除文件目录: $(dirname "$EXCLUDE_FILE")"
  cat >"$EXCLUDE_FILE" <<EOF || error_exit "无法写入排除文件: $EXCLUDE_FILE"
# 排除文件本身(请勿删除)
custom/user_exclude_file.txt
# 用户数据库与用户 custom 文件(仅匹配根目录, custom/ 下的模板会被安装)
*.userdb
*.custom.yaml
# 用户自定义短语(新包不带, 已有文件保留)
custom_phrase.txt
# 其他平台专用配置(iOS 不需要但已存在则保留)
简纯+.trime.yaml
squirrel.yaml
weasel.yaml
# 部署信息
installation.yaml
user.yaml
# ##############以上内容请在了解万象方案机制后自行更改, 否则请不要更改##############
EOF
  log INFO "已创建排除文件: $EXCLUDE_FILE"
}

# 排除匹配: 不含 / 的模式只匹配根目录; 含 / 的模式匹配完整相对路径。
is_excluded() { # $1 相对路径  $2 排除文件
  local rel="$1" file="$2" pat
  [[ -f "$file" ]] || return 1
  while IFS= read -r pat; do
    case "$pat" in
      ''|'#'*) continue ;;
    esac
    case "$pat" in
      */*)
        [[ "$rel" == $pat ]] && return 0
        ;;
      *)
        case "$rel" in */*) continue ;; esac
        [[ "$rel" == $pat ]] && return 0
        ;;
    esac
  done <"$file"
  return 1
}

# ---------- 远端 API 缓存 ----------
GITHUB_ERROR=""
cache_github() { # $1 = 文件名  $2 = api url ; 成功返回0, 失败返回1(原因写入 GITHUB_ERROR)
  local out="$TEMP_DIR/$1" url="$2"
  [[ -f "$out" ]] && return 0
  case "$url" in
    *\?*) url="${url}&per_page=100" ;;
    *)    url="${url}?per_page=100" ;;
  esac
  if ! http_get "$url" "$out" "Accept: application/vnd.github.v3+json"; then
    rm -f "$out"
    GITHUB_ERROR="网络/代理连接失败或 HTTP 错误"
    return 1
  fi
  # 正常响应是数组或 release 对象; 若仍是 {"message": "..."} 则暴露真实原因
  GITHUB_ERROR=$(jq -r 'if type == "object" and .message and (.tag_name == null) then .message else empty end' "$out" 2>/dev/null)
  if [[ -n "$GITHUB_ERROR" ]]; then
    rm -f "$out"
    return 1
  fi
  return 0
}

cache_cnb() {
  # CNB release 列表分页, 合并到一个文件里供 get_info 复用
  local out="$TEMP_DIR/cnb.json"
  [[ -f "$out" ]] && return 0
  local merged="$TEMP_DIR/cnb_merged.json" next="$TEMP_DIR/cnb_next.json" page_file page release_count completed="false"
  printf '{"releases":[]}\n' >"$merged"
  for ((page=1; page<=100; page++)); do
    page_file="$TEMP_DIR/cnb_page_${page}.json"
    http_get "${CNB_API}?page=${page}&page_size=100" "$page_file" "accept: application/vnd.cnb.web+json" \
      || error_exit "连接 CNB 失败, 检查网络"
    jq -e '.releases | type == "array"' "$page_file" >/dev/null \
      || error_exit "CNB 返回非法 JSON"
    release_count=$(jq '.releases | length' "$page_file")
    if [[ "$release_count" -eq 0 ]]; then completed="true"; break; fi
    jq -s '{releases: (.[0].releases + .[1].releases)}' "$merged" "$page_file" >"$next" \
      || error_exit "合并 CNB 分页失败"
    mv "$next" "$merged"
  done
  [[ "$completed" == "true" ]] || error_exit "CNB 分页超过安全上限"
  mv "$merged" "$out"
}

# 精确 asset 名 (仓库命名规律: 方案 rime-wanxiang-<码>-fuzhu.zip / 词库 pro-<码>-fuzhu-dicts.zip)
# 注: 微信辅助码在仓库里叫 wx, 无辅助码纯净版叫 pure
schema_asset_name() { # $1 schema(base|pro)  $2 fuzhu
  if [[ "$1" == "base" ]]; then echo "rime-wanxiang-base.zip"
  elif [[ "$2" == "base" ]]; then echo "rime-wanxiang-pure.zip"
  elif [[ "$2" == "wx" ]]; then echo "rime-wanxiang-wx-fuzhu.zip"
  else echo "rime-wanxiang-${2}-fuzhu.zip"; fi
}
dict_asset_name() { # $1 schema  $2 fuzhu
  if [[ "$1" == "base" ]]; then echo "base-dicts.zip"
  elif [[ "$2" == "base" ]]; then echo "pure-dicts.zip"
  else echo "pro-${2}-fuzhu-dicts.zip"; fi
}

# 从缓存 JSON 中取 release: GitHub 兼容数组/单对象, CNB 为 {releases:[...]}
release_by_tag() { # $1 mirror  $2 json文件  $3 tag
  local mirror="$1" json="$2" tag="$3"
  if [[ "$mirror" == "github" ]]; then
    jq -ec --arg v "$tag" '
      (if type == "array" then .[] else . end) | select(.tag_name == $v)' "$json"
  else
    jq -ec --arg v "refs/tags/$tag" '
      .releases[] | select(.tag_ref == $v)' "$json"
  fi
}

# 方案 release: 标题含“万象拼音输入方案”且 tag 为 vX.Y.Z; 标题不命中时回退按最大版本 tag 选择。
select_scheme_release() { # $1 mirror  $2 json文件 -> 输出 tag
  local mirror="$1" json="$2" lines tag title best="" fallback=""
  if [[ "$mirror" == "github" ]]; then
    lines=$(jq -r '(if type == "array" then .[] else . end)
      | [(.tag_name // ""), (.name // "")] | @tsv' "$json" 2>/dev/null)
  else
    lines=$(jq -r '.releases[]
      | [(.tag_ref // ""), (.title // "")] | @tsv' "$json" 2>/dev/null)
  fi
  local re='^v?[0-9]+\.[0-9]+\.[0-9]+$'
  while IFS=$'\t' read -r tag title; do
    tag="${tag#refs/tags/}"
    [[ -z "$tag" ]] && continue
    [[ "$tag" =~ $re ]] || continue
    if [[ -z "$fallback" ]] || version_gt "$tag" "$fallback"; then
      fallback="$tag"
    fi
    case "$title" in
      *万象拼音输入方案*)
        if [[ -z "$best" ]] || version_gt "$tag" "$best"; then
          best="$tag"
        fi
        ;;
    esac
  done <<<"$lines"
  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
    return 0
  fi
  if [[ -n "$fallback" ]]; then
    log WARN "方案 release 标题未命中, 回退按版本 tag 选择: $fallback" >&2
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

# 词库 release: 标题含“词库”或“实时全量预览”; 标题不命中时回退到 v1.0.0 / dict-nightly。
select_dict_release() { # $1 mirror  $2 json文件 -> 输出 tag
  local mirror="$1" json="$2" lines tag title fallback=""
  if [[ "$mirror" == "github" ]]; then
    lines=$(jq -r '(if type == "array" then .[] else . end)
      | [(.tag_name // ""), (.name // "")] | @tsv' "$json" 2>/dev/null)
  else
    lines=$(jq -r '.releases[]
      | [(.tag_ref // ""), (.title // "")] | @tsv' "$json" 2>/dev/null)
  fi
  while IFS=$'\t' read -r tag title; do
    tag="${tag#refs/tags/}"
    [[ -z "$tag" ]] && continue
    if [[ "$tag" == "dict-nightly" || "$tag" == "v1.0.0" ]]; then
      fallback="$tag"
    fi
    case "$title" in
      *词库*|*实时全量预览*)
        printf '%s\n' "$tag"
        return 0
        ;;
    esac
  done <<<"$lines"
  if [[ -n "$fallback" ]]; then
    log WARN "词库 release 标题未命中, 回退按 tag 选择: $fallback" >&2
    printf '%s\n' "$fallback"
    return 0
  fi
  return 1
}

# get_asset: 从单个 release 对象里取 asset; 词库名未精确命中时按 -dicts.zip 后缀回退。
get_asset() { # $1 mirror  $2 release JSON  $3 期望文件名
  local mirror="$1" release="$2" name="$3" asset=""
  asset=$(printf '%s' "$release" | jq -ec --arg n "$name" '
    [.assets[]? | select(.name == $n)][0]' 2>/dev/null) || asset=""
  if [[ -n "$asset" ]]; then
    printf '%s\n' "$asset"
    return 0
  fi
  case "$name" in
    *-dicts.zip)
      # 仅在 release 内恰好只有一个 *-dicts.zip 时回退; 多个候选说明有 base/pro 等版本,
      # 随便取第一个会装错词库, 此时宁可失败让用户看到明确错误。
      asset=$(printf '%s' "$release" | jq -ec '
        [.assets[]? | select(.name | endswith("-dicts.zip"))]
        | if length == 1 then .[0] else empty end' 2>/dev/null) || asset=""
      if [[ -n "$asset" ]]; then
        log WARN "词库资产 $name 未找到, 回退使用 $(printf '%s' "$asset" | jq -r '.name')" >&2
        printf '%s\n' "$asset"
        return 0
      fi
      ;;
  esac
  return 1
}

# 资产的 sha256: GitHub 用 digest, CNB 用 hash_value
asset_sha256() {
  local mirror="$1" asset="$2" h=""
  if [[ "$mirror" == "github" ]]; then
    h=$(printf '%s' "$asset" | jq -r '.digest // ""')
  else
    h=$(printf '%s' "$asset" | jq -r '
      (.hash_algo // "") as $a |
      if ($a | ascii_downcase) == "sha256"
      then (.hash_value // "")
      else "" end')
  fi
  normalize_hash "$h"
}

# ---------- 下载并校验 ----------
download_and_verify() { # $1 url  $2 dest  $3 expected_size  $4 label  [$5 expected_hash]
  local url="$1" dest="$2" expected="$3" label="$4" expected_hash="${5:-}"
  log INFO "正在下载 $label"
  if ! http_get_progress "$url" "$dest"; then
    rm -f "$dest"
    error_exit "$label 下载失败, 请重试"
  fi
  verify_file_size_hash "$dest" "$expected" "$expected_hash" "$label" \
    || error_exit "$label 校验失败, 已删除损坏文件, 请重试"
}

# ---------- 版本比较(可移植, 不依赖 GNU 排序扩展) ----------
version_gt() { # $1 $2 -> 0 表示 $1 > $2; 非数字返回 2
  local a="${1#v}" b="${2#v}" ai bi i n
  local IFS=.
  local av bv
  # shellcheck disable=SC2206
  av=($a); bv=($b)
  n=${#av[@]}
  [[ ${#bv[@]} -gt $n ]] && n=${#bv[@]}
  for ((i=0; i<n; i++)); do
    ai="${av[i]:-0}"; bi="${bv[i]:-0}"
    is_uint "$ai" || return 2
    is_uint "$bi" || return 2
    ai=$((10#$ai)); bi=$((10#$bi))
    if [[ $ai -gt $bi ]]; then return 0; fi
    if [[ $ai -lt $bi ]]; then return 1; fi
  done
  return 1
}

get_newer() { # $1 $2 -> 较大者(带 v 前缀); 相等时返回第一个
  local a="$1" b="$2"
  if version_gt "$a" "$b"; then
    printf '%s\n' "$a"
  elif version_gt "$b" "$a"; then
    printf '%s\n' "$b"
  else
    printf '%s\n' "$a"
  fi
}

# 方案更新判定: 输出 update / skip / downgrade / unknown
scheme_decision() { # $1 remote_version  $2 remote_hash  $3 local_version  $4 local_hash
  local rv="$1" rh="$2" lv="${3:-v0}" lh="$4" rc
  [[ -n "$lv" ]] || lv="v0"
  version_gt "$rv" "$lv"; rc=$?
  case "$rc" in
    0) printf 'update\n'; return 0 ;;
    2) printf 'unknown\n'; return 0 ;;
  esac
  version_gt "$lv" "$rv"; rc=$?
  case "$rc" in
    0) printf 'downgrade\n'; return 0 ;;
    2) printf 'unknown\n'; return 0 ;;
  esac
  if [[ -z "$rh" ]]; then
    printf 'skip\n'
  elif [[ "$rh" == "$lh" ]]; then
    printf 'skip\n'
  else
    printf 'update\n'
  fi
}

# ---------- 更新方案 ----------
update_schema() {
  local mirror="$1" fuzhu="$2" schema="$3"
  local asset_name; asset_name=$(schema_asset_name "$schema" "$fuzhu")
  # 缓存: 方案与词库共用同一份 GitHub release 列表; CNB 缓存全量分页
  local json
  if [[ "$mirror" == "github" ]]; then
    cache_github "github_releases.json" "$SCHEMA_API" \
      || error_exit "连接 GitHub API 失败: $GITHUB_ERROR (匿名限流 60 次/小时, 可稍后再试或 --mirror cnb)"
    json="$TEMP_DIR/github_releases.json"
  else
    cache_cnb
    json="$TEMP_DIR/cnb.json"
  fi

  # 本地版本与哈希记录
  local local_version="v0"
  [[ -f "$DEPLOY_DIR/version.txt" ]] && { local_version=$(cat "$DEPLOY_DIR/version.txt"); [[ "$local_version" == v* ]] || local_version="v$local_version"; }

  local remote_version
  remote_version=$(select_scheme_release "$mirror" "$json") \
    || error_exit "未能获取远端方案版本号"
  [[ "$remote_version" == v* ]] || remote_version="v$remote_version"

  # 先取 release/asset 才能拿到远端哈希, 再决定是否需要下载
  local release asset
  release=$(release_by_tag "$mirror" "$json" "$remote_version") \
    || error_exit "未找到方案 release $remote_version"
  asset=$(get_asset "$mirror" "$release" "$asset_name") \
    || error_exit "release $remote_version 里没有 $asset_name"

  local remote_hash record_file="$DEPLOY_DIR/custom/.scheme_sha256" local_hash=""
  remote_hash=$(asset_sha256 "$mirror" "$asset")
  [[ -f "$record_file" ]] && local_hash=$(normalize_hash "$(cat "$record_file")")
  local decision; decision=$(scheme_decision "$remote_version" "$remote_hash" "$local_version" "$local_hash")
  log INFO "方案 本地=$local_version 远端=$remote_version"
  case "$decision" in
    skip)
      log INFO "方案版本与内容均一致, 无需更新"
      return 1 ;;
    downgrade)
      log INFO "方案本地版本更高, 不降级"
      return 1 ;;
    unknown)
      log WARN "方案版本号无法比较, 已停止 (本地=$local_version 远端=$remote_version)"
      UPDATE_FAILED="true"
      return 1 ;;
  esac

  local changelog
  changelog=$(printf '%s' "$release" | jq -r '.body // ""')
  echo -e "$changelog" | sed -n '/## 📝 更新日志/,/## 🚀 下载引导/p' | drop_last_line

  log INFO "开始下载方案文件 ($asset_name)"
  local url name remote_size
  if [[ "$mirror" == "github" ]]; then
    url=$(printf '%s' "$asset" | jq -r '.browser_download_url')
    remote_size=$(printf '%s' "$asset" | jq -r '.size')
  else
    url="https://cnb.cool$(printf '%s' "$asset" | jq -r '.path')"
    remote_size=$(printf '%s' "$asset" | jq -r '.size_in_byte')
  fi
  download_and_verify "$url" "$TEMP_DIR/$asset_name" "$remote_size" "方案文件" "$remote_hash"
  name="$asset_name"

  log INFO "解压并应用更新"
  extract_zip "$TEMP_DIR/$name" "$TEMP_DIR/${name%.zip}"
  apply_scheme_files "$TEMP_DIR/${name%.zip}" "$DEPLOY_DIR" "$EXCLUDE_FILE" \
    || error_exit "同步方案文件失败"

  if [[ -n "$remote_hash" ]]; then
    mkdir -p "$DEPLOY_DIR/custom"
    printf '%s\n' "$remote_hash" >"$record_file"
  else
    log WARN "远端未提供方案 sha256, 本次跳过内容记录"
  fi
  NEEDED_DEPLOY="true"
  log INFO "方案更新成功 ($remote_version)"
  return 0
}

# ---------- 更新词库 ----------
update_dict() {
  local mirror="$1" fuzhu="$2" schema="$3"
  local asset_name; asset_name=$(dict_asset_name "$schema" "$fuzhu")

  local json
  if [[ "$mirror" == "github" ]]; then
    cache_github "github_releases.json" "$SCHEMA_API" \
      || error_exit "连接 GitHub API 失败: $GITHUB_ERROR (匿名限流 60 次/小时, 可稍后再试或 --mirror cnb)"
    json="$TEMP_DIR/github_releases.json"
  else
    cache_cnb
    json="$TEMP_DIR/cnb.json"
  fi

  local tag release
  tag=$(select_dict_release "$mirror" "$json") || { log WARN "未找到词库 release"; UPDATE_FAILED="true"; return 1; }
  release=$(release_by_tag "$mirror" "$json" "$tag") || { log WARN "未找到词库 release $tag"; UPDATE_FAILED="true"; return 1; }
  local asset; asset=$(get_asset "$mirror" "$release" "$asset_name") || { log WARN "未找到词库 asset ($asset_name)"; UPDATE_FAILED="true"; return 1; }

  # 用 sha256 记录判断是否需要更新 (远端镜像的 updated_at 会漂移, 不可靠)
  local remote_hash record_file="$DEPLOY_DIR/custom/.dict_sha256" local_hash=""
  remote_hash=$(asset_sha256 "$mirror" "$asset")
  [[ -f "$record_file" ]] && local_hash=$(normalize_hash "$(cat "$record_file")")

  # dicts/ 缺失或为空时必须重新安装: 记录存在不代表文件还在(用户清理过/首次部署)
  local force="false"
  if [[ ! -d "$DEPLOY_DIR/dicts" ]]; then
    force="true"
  elif [[ -z "$(find "$DEPLOY_DIR/dicts" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
    force="true"
  fi
  if [[ "$force" != "true" && -n "$remote_hash" && "$remote_hash" == "$local_hash" ]]; then
    log INFO "词库记录哈希一致, 无需更新"
    return 1
  fi

  log INFO "词库有更新 (记录=$local_hash 远端=$remote_hash)"
  local url name remote_size
  if [[ "$mirror" == "github" ]]; then
    url=$(echo "$asset" | jq -r '.browser_download_url')
    name=$(echo "$asset" | jq -r '.name')
    remote_size=$(echo "$asset" | jq -r '.size')
  else
    url="https://cnb.cool$(echo "$asset" | jq -r '.path')"
    name=$(echo "$asset" | jq -r '.name')
    remote_size=$(echo "$asset" | jq -r '.size_in_byte')
  fi
  # 先校验后解压: 坏包绝不覆盖已有词库
  download_and_verify "$url" "$TEMP_DIR/$name" "$remote_size" "词库文件" "$remote_hash"

  log INFO "解压并应用词库"
  extract_zip "$TEMP_DIR/$name" "$TEMP_DIR/${name%.zip}"
  local root; root=$(resolve_extract_root "$TEMP_DIR/${name%.zip}")
  if [[ -z "$(find "$root" -type f 2>/dev/null | head -n 1)" ]]; then
    error_exit "词库包内容为空, 未写入任何文件"
  fi
  # 复制前先失效旧记录: 若复制中断, 下次不会被旧记录误判为"已是最新"
  if [[ -f "$record_file" ]]; then
    rm -f "$record_file" || error_exit "无法清除词库哈希记录: $record_file"
  fi
  copy_tree "$root" "$DEPLOY_DIR/dicts" || error_exit "应用词库失败"

  if [[ -n "$remote_hash" ]]; then
    mkdir -p "$DEPLOY_DIR/custom"
    printf '%s\n' "$remote_hash" >"$record_file" || error_exit "无法写入词库哈希记录: $record_file"
  else
    log WARN "远端未提供词库 sha256, 本次跳过内容记录"
  fi
  NEEDED_DEPLOY="true"
  log INFO "词库更新成功"
  return 0
}

# ---------- 更新语法模型 ----------
update_gram() {
  local mirror="$1"
  local tag="LTS" json
  if [[ "$mirror" == "github" ]]; then
    # 与原版 Python 对齐: 按 tag 精确请求模型仓的单个 release (而非拉全列表)
    cache_github "github_gram.json" "${GRAM_API}/tags/LTS" \
      || error_exit "连接 GitHub API 失败: $GITHUB_ERROR (匿名限流 60 次/小时, 可稍后再试或 --mirror cnb)"
    json="$TEMP_DIR/github_gram.json"
  else
    cache_cnb
    tag="model"
    json="$TEMP_DIR/cnb.json"
  fi

  local release asset
  release=$(release_by_tag "$mirror" "$json" "$tag") || { log WARN "未找到模型 release ($tag)"; UPDATE_FAILED="true"; return 1; }
  asset=$(get_asset "$mirror" "$release" "$GRAM_NAME") || { log WARN "未找到模型 asset ($GRAM_NAME)"; UPDATE_FAILED="true"; return 1; }

  # 用 sha256 记录判断 (模型 420MB, 绝不能因为镜像时间漂移反复下载)
  local remote_hash record_file="$DEPLOY_DIR/custom/.gram_sha256" local_hash=""
  remote_hash=$(asset_sha256 "$mirror" "$asset")
  [[ -f "$record_file" ]] && local_hash=$(normalize_hash "$(cat "$record_file")")

  local url remote_size
  if [[ "$mirror" == "github" ]]; then
    url=$(echo "$asset" | jq -r '.browser_download_url')
    remote_size=$(echo "$asset" | jq -r '.size')
  else
    url="https://cnb.cool$(echo "$asset" | jq -r '.path')"
    remote_size=$(echo "$asset" | jq -r '.size_in_byte')
  fi

  local dest="$DEPLOY_DIR/$GRAM_NAME" tmp="$DEPLOY_DIR/.${GRAM_NAME}.tmp"
  # 记录一致只说明"下载过"; 还必须核对本地文件, 避免文件被截断/篡改后一直跳过
  if [[ -f "$dest" && -n "$local_hash" && ( -z "$remote_hash" || "$remote_hash" == "$local_hash" ) ]]; then
    if [[ -n "$remote_hash" ]] && detect_hash_tool; then
      local actual_hash; actual_hash=$(normalize_hash "$(local_sha256 "$dest")")
      if [[ "$actual_hash" == "$remote_hash" ]]; then
        log INFO "模型本地文件与远端一致, 无需更新"
        return 1
      fi
      log WARN "模型本地文件哈希与记录不符, 将重新下载修复"
    else
      # 无哈希工具(或远端未给哈希)时退回大小校验, 避免 420MB 每次都重下, 也不盲信记录
      local actual_size; actual_size=$(file_size "$dest")
      if is_uint "$remote_size" && is_uint "$actual_size" && [[ "$actual_size" -eq "$remote_size" ]]; then
        log WARN "缺少哈希依据, 模型大小与远端一致, 按记录跳过下载"
        return 1
      fi
      log WARN "缺少哈希依据且模型大小不符, 将重新下载修复"
    fi
  fi

  log INFO "模型有更新 (记录=$local_hash 远端=$remote_hash)"
  # 下载到部署目录内的临时文件, 校验通过后再 mv 原子替换(避免半包覆盖旧模型)
  mkdir -p "$DEPLOY_DIR"
  download_and_verify "$url" "$tmp" "$remote_size" "语法模型" "$remote_hash"
  mv -f "$tmp" "$dest" || error_exit "替换语法模型失败"

  if [[ -n "$remote_hash" ]]; then
    mkdir -p "$DEPLOY_DIR/custom"
    printf '%s\n' "$remote_hash" >"$record_file"
  else
    log WARN "远端未提供模型 sha256, 本次跳过内容记录"
  fi
  NEEDED_DEPLOY="true"
  log INFO "模型更新成功"
  return 0
}

# ---------- 跳转输入法部署 ----------
# URL Scheme 与原版 Python (webbrowser.open) 完全一致:
#   仓  : hamster://dev.fuxiao.app.hamster/rime?deploy
#   元书: hamster3://dev.fuxiao.app.hamster3/rime?action=deploy
# 差别只在触发: 原版在 App 内走 iOS 系统 API (必成);
#   越狱终端靠命令行工具唤起, 需装 uiopen/open 之一, 且终端要在前台 App 上下文.
deploy_ios() {
  [[ "$AUTO_DEPLOY" != "true" ]] && { log INFO "已设 AUTO_DEPLOY=false, 跳过跳转, 请在输入法 App 内手动重新部署"; return 0; }
  local scheme info
  if [[ "$RIME_ENGINE" == "元书" ]]; then
    scheme="hamster3://dev.fuxiao.app.hamster3/rime?action=deploy"; info="元书输入法"
  else
    scheme="hamster://dev.fuxiao.app.hamster/rime?deploy"; info="仓输入法"
  fi
  log INFO "将于 3 秒后跳转 $info 部署"
  sleep 3
  # 越狱环境唤起 URL Scheme, 按 scheme 支持可靠度排序依次尝试, 不吞错误
  #   uiopen   (uikittools) - 专门 open URL, 对自定义 scheme 最可靠
  #   open     (部分版本)   - 能 open URL, 但有的实现只认文件/bundle id
  #   sbopenurl              - 通过 SpringBoard 打开, 兼容性好
  local err rc
  for _cmd in uiopen open sbopenurl; do
    command -v "$_cmd" >/dev/null 2>&1 || continue
    err=$("$_cmd" "$scheme" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then
      log INFO "已通过 $_cmd 触发跳转 ($info) — 若 App 未弹出, 请在 $info 内手动点一下'重新部署'"
      return 0
    fi
    log WARN "$_cmd 退出码 $rc: $err"
  done
  log WARN "自动跳转未成功 (未装 uiopen/open/sbopenurl 或都失败)"
  log WARN "请在 $info App 内手动点一下'重新部署', 或装 uiopen: Sileo 搜 'uiopen' / 'uikittools'"
  log WARN "URL: $scheme"
}

show_doctor() {
  log INFO "环境自检 (必装项缺一不可, 可选工具只影响附加能力)"
  local ok="\033[0;32m✓\033[0m" bad="\033[0;31m✗\033[0m"
  local missing_required="" missing_optional=""

  if command -v jq >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "jq" "解析 GitHub/CNB release JSON (必装)"
  else
    printf "  ${bad} %-12s %s\n" "jq" "解析 GitHub/CNB release JSON (必装)"
    missing_required="$missing_required jq"
  fi

  if command -v unzip >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "unzip" "解压方案/词库 zip (必装, 或用 tar)"
  elif command -v tar >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "tar" "解压方案/词库 zip (unzip 的备选)"
  else
    printf "  ${bad} %-12s %s\n" "unzip/tar" "解压方案/词库 zip (必装)"
    missing_required="$missing_required unzip"
  fi

  if command -v curl >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "curl" "HTTP 下载 (必装, 与 wget 二选一)"
  elif command -v wget >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "wget" "HTTP 下载 (curl 的备选)"
  else
    printf "  ${bad} %-12s %s\n" "curl/wget" "HTTP 下载 (必装)"
    missing_required="$missing_required curl"
  fi

  echo ""
  log INFO "可选工具 (缺失不影响方案/词库/模型更新)"
  if command -v shasum >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "shasum" "sha256 内容校验 (可选)"
  elif command -v sha256sum >/dev/null 2>&1; then
    printf "  ${ok} %-12s %s\n" "sha256sum" "sha256 内容校验 (可选)"
  else
    printf "  ${bad} %-12s %s\n" "shasum" "sha256 内容校验 (可选, 缺则只校验大小)"
    missing_optional="$missing_optional shasum/sha256sum"
  fi

  local t
  for t in wget sbopenurl open uiopen; do
    if command -v "$t" >/dev/null 2>&1; then
      printf "  ${ok} %-12s %s\n" "$t" "附加工具 (可选)"
    else
      printf "  ${bad} %-12s %s\n" "$t" "附加工具 (可选)"
      missing_optional="$missing_optional $t"
    fi
  done

  echo ""
  if [[ -n "$missing_required" ]]; then
    log ERROR "缺少必装项:$missing_required — 请在 Sileo/Zebra 安装后重试"
  else
    log INFO "必装依赖齐全"
  fi
  if [[ -n "$missing_optional" ]]; then
    log WARN "可选工具缺失:$missing_optional (不影响基本更新)"
  else
    log INFO "可选工具齐全"
  fi
  exit 0
}

show_help() {
  cat <<EOF
万象更新工具 - iOS 越狱终端版
用法: $0 [选项]

选项:
  --mirror [github|cnb]   下载源 (默认 $DEFAULT_MIRROR; cnb 免代理无限流, github 需代理且匿名 60 次/小时)
  --fuzhu SCHEMA          辅助码: ${FUZHU_LIST[*]} (默认 $DEFAULT_FUZHU; wx=微信辅助码)
  --schema base|pro       方案类型 (默认 pro; base 时 fuzhu 自动用 base)
  --depdir PATH           手动指定部署目录 (默认按脚本位置自动识别仓/元书; URL Scheme 按路径推断)
  --no-schema             不更新方案
  --no-dict               不更新词库
  --no-gram               不更新模型
  --no-deploy             更新后不跳转输入法
  --doctor                自检依赖并列出缺什么 (不执行更新, 不依赖 jq)
  --help                  显示帮助

排除规则 (custom/user_exclude_file.txt):
  不含 / 的模式只匹配根目录: *.custom.yaml 保护根目录用户配置, 但会安装 custom/ 下的模板
  含 / 的模式匹配完整相对路径: custom/user_exclude_file.txt 保护排除文件自身

部署目录识别 (脚本放哪里就识别哪种输入法):
  仓输入法  : 脚本与 RIME 或 Rime 文件夹同级 -> 方案目录 = RIME/Rime
  元书输入法: 脚本与 RimeUserData 文件夹同级 -> 方案目录 = RimeUserData/wanxiang

示例:
  $0                                    # cnb + flypy + 方案/词库/模型 + 自动跳转
  $0 --mirror github                    # 走 GitHub(需代理)
  $0 --fuzhu moqi --schema base         # 墨奇基础版
  $0 --no-deploy                        # 只更新不跳转
EOF
}

# ====================== 主流程 ======================
NEEDED_DEPLOY="false"
UPDATE_FAILED="false"

need_value() { # $1 选项  $2 剩余参数个数
  if [[ "$2" -lt 2 ]]; then
    error_exit "参数 $1 缺少取值 (用 --help 查看)"
  fi
}

main() {
  trap cleanup EXIT

  local mirror="" fuzhu="" schema="pro" do_schema="true" do_dict="true" do_gram="true"
  # 参数解析放在依赖检查之前: 缺 jq 时也应当能看帮助和自检
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror)
        need_value "$1" "$#"
        [[ "$2" == "github" || "$2" == "cnb" ]] || error_exit "参数 --mirror 只能是 github/cnb"
        mirror="$2"; shift ;;
      --fuzhu)
        need_value "$1" "$#"
        fuzhu_check "$2" || error_exit "参数 --fuzhu 只能是 ${FUZHU_LIST[*]}"
        fuzhu="$2"; shift ;;
      --schema)
        need_value "$1" "$#"
        [[ "$2" == "base" || "$2" == "pro" ]] || error_exit "参数 --schema 只能是 base/pro"
        schema="$2"; shift ;;
      --depdir)
        need_value "$1" "$#"
        [[ -n "$2" && "$2" != -* ]] || error_exit "参数 --depdir 缺少取值 (用 --help 查看)"
        DEPLOY_DIR="$2"; shift ;;
      --no-schema) do_schema="false" ;;
      --no-dict)   do_dict="false" ;;
      --no-gram)   do_gram="false" ;;
      --no-deploy) AUTO_DEPLOY="false" ;;
      --doctor)    show_doctor ;;
      --help|-h)   show_help; exit 0 ;;
      *) error_exit "未知参数: $1 (用 --help 查看)" ;;
    esac
    shift
  done

  log INFO "欢迎使用万象方案更新助手 (iOS 越狱终端版)"
  deps_check

  [[ -n "$mirror" ]] || mirror="$DEFAULT_MIRROR"
  [[ -n "$fuzhu"   ]] || fuzhu="$DEFAULT_FUZHU"
  # base 方案强制 fuzhu=base
  [[ "$schema" == "base" ]] && fuzhu="base"

  detect_deploy_dir
  log INFO "输入法: $RIME_ENGINE  部署目录: $DEPLOY_DIR  下载源: $mirror  辅助码: $fuzhu"
  mkdir -p "$DEPLOY_DIR"
  create_exclude_file

  [[ "$do_schema" == "true" ]] && update_schema "$mirror" "$fuzhu" "$schema"
  [[ "$do_dict"   == "true" ]] && update_dict   "$mirror" "$fuzhu" "$schema"
  [[ "$do_gram"   == "true" ]] && update_gram   "$mirror"

  if [[ "$NEEDED_DEPLOY" == "true" ]]; then
    if [[ "$AUTO_DEPLOY" == "true" ]]; then
      log INFO "有更新, 准备跳转重新部署"
    fi
    deploy_ios
  elif [[ "$UPDATE_FAILED" != "true" ]]; then
    log INFO "所有组件均为最新, 无需部署"
  fi

  if [[ "$UPDATE_FAILED" == "true" ]]; then
    log ERROR "部分组件更新失败, 请查看上方日志"
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
