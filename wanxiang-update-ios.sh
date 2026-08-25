#!/usr/bin/env bash

# 万象方案更新工具 - iOS 越狱终端版 (仓输入法 / 元书输入法)
# 依赖: jq + 解压(unzip 或 tar) + curl/wget 二选一
#   (coreutils 只提供 stat/cp/rm 等, 不含这些; 不想装 curl 就装 wget)
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
TOOLS_API="https://api.github.com/repos/rimeinn/rime-wanxiang-update-tools/releases"
GRAM_NAME="wanxiang-lts-zh-hans.gram"
FUZHU_LIST=("base" "flypy" "hanxin" "moqi" "tiger" "wubi" "zrm" "shouyou" "shyplus" "wx")
# 方案压缩包里这些文件不覆盖回输入法目录(各端专用, iOS 不需要)
DELETE_FILES=("简纯+.trime.yaml" "squirrel.yaml" "weasel.yaml" "custom_phrase.txt")
TEMP_DIR=$(mktemp -d /tmp/wanxiang-ios-XXXXXX)

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

cleanup() { [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true; }

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

# 文件的 sha256 (macOS/BSD 用 shasum, GNU 用 sha256sum)
local_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
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
http_get() {
  local url="$1" out="$2"; shift 2
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    local args=(-sL --connect-timeout 10)
    for h in "$@"; do args+=(-H "$h"); done
    curl "${args[@]}" -o "$out" "$url"
  else
    local args=(-q --timeout=30)
    for h in "$@"; do args+=(--header="$h"); done
    wget "${args[@]}" "$url" -O "$out"
  fi
}

# http_get_progress URL OUT_FILE : 带进度条的大文件下载(方案 41MB / 模型 420MB)
http_get_progress() {
  local url="$1" out="$2"
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    curl -L --connect-timeout 10 -o "$out" "$url"
  else
    wget --timeout=30 "$url" -O "$out"
  fi
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

# ---------- 依赖检查 ----------
deps_check() {
  command -v jq >/dev/null 2>&1 || error_exit "缺少依赖: jq (Sileo/Zebra 搜索 jq 安装)"
  command -v unzip >/dev/null 2>&1 || command -v tar >/dev/null 2>&1 \
    || error_exit "缺少依赖: unzip (Sileo/Zebra 搜索 unzip 安装)"
  detect_http_client
}

fuzhu_check() {
  local f="$1"
  for _f in "${FUZHU_LIST[@]}"; do [[ "$f" == "$_f" ]] && return 0; done
  return 1
}

# ---------- 部署目录识别 (仓 / 元书) ----------
detect_deploy_dir() {
  if [[ -n "$DEPLOY_DIR" ]]; then
    RIME_ENGINE="自定义"
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
  mkdir -p "$(dirname "$EXCLUDE_FILE")"
  cat >"$EXCLUDE_FILE" <<EOF
# 排除文件本身(请勿删除)
custom/user_exclude_file.txt
# 用户数据库与 custom 文件(通配)
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

# ---------- 远端 API 缓存 ----------
GITHUB_ERROR=""
cache_github() { # $1 = 文件名  $2 = api url ; 成功返回0, 失败返回1(原因写入 GITHUB_ERROR)
  local out="$TEMP_DIR/$1"
  [[ -f "$out" ]] && return 0
  if ! http_get "$2" "$out" "Accept: application/vnd.github.v3+json"; then
    GITHUB_ERROR="网络/代理连接失败"
    return 1
  fi
  # GitHub 出错时(限流/404等)返回 {"message": "..."} 对象而非正常数据, 提前暴露真实原因
  GITHUB_ERROR=$(jq -r 'if type == "object" and .message then .message else empty end' "$out" 2>/dev/null)
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
    http_get "${CNB_API}?page=${page}" "$page_file" "accept: application/vnd.cnb.web+json" \
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

# get_info: 从指定缓存 JSON 里按精确文件名取单个 asset 对象
#   $1 json文件  $2 mirror  $3 version(tag)  $4 asset 精确文件名
# 注意: github 分支同时兼容 数组(releases 列表) 和 单对象(按 tag 精确请求) 两种响应
get_info() {
  local json="$1" mirror="$2" version="$3" name="$4"
  if [[ "$mirror" == "github" ]]; then
    jq -e --arg v "$version" --arg n "$name" '
      (if type == "array" then .[] else . end)
      | select(.tag_name == $v) | .assets[] | select(.name == $n)' \
      "$json"
  else
    jq -e --arg v "refs/tags/$version" --arg n "$name" '
      .releases[] | select(.tag_ref == $v) | .assets[] | select(.name == $n)' \
      "$json"
  fi
}

# 资产的 sha256: GitHub 用 digest, CNB 用 hash_value
asset_sha256() {
  local mirror="$1" asset="$2"
  if [[ "$mirror" == "github" ]]; then
    echo "$asset" | jq -r '.digest // "" | sub("^sha256:"; "")'
  else
    echo "$asset" | jq -r '
      (.hash_algo // "") as $a |
      if ($a | ascii_downcase) == "sha256"
      then (.hash_value // "" | sub(".*:"; ""))
      else "" end'
  fi
}

# ---------- 下载并校验大小 ----------
download_and_verify() { # $1 url  $2 dest  $3 expected_size  $4 label
  local url="$1" dest="$2" expected="$3" label="$4"
  log INFO "正在下载 $label"
  http_get_progress "$url" "$dest" || { [[ -f "$dest" ]] && [[ -s "$dest" ]] || error_exit "$label 下载失败, 请重试"; }
  local actual; actual=$(file_size "$dest")
  # 只有双方都是纯数字才比大小; 远端没给 size 或本地 stat 异常时跳过, 不让非数字进算术求值
  if is_uint "$expected" && is_uint "$actual"; then
    if [[ "$actual" -ne "$expected" ]]; then
      log ERROR "期望大小: $expected, 实际大小: $actual"
      rm -f "$dest"
      error_exit "$label 下载出错, 请重试"
    fi
    log INFO "校验通过 (大小 $actual 字节)"
  else
    log WARN "跳过大小校验 (远端=$expected 本地=$actual), 请自行确认文件完整"
  fi
}

# ---------- 版本比较 (sort -V) ----------
get_newer() { # $1 $2 -> 较大者(带 v 前缀)
  local a="$1" b="$2"
  { printf '%s\n%s\n' "${a#v}" "${b#v}"; } | sort -V | tail -n1 | sed 's/^/v/'
}

# ---------- 更新方案 ----------
update_schema() {
  local mirror="$1" fuzhu="$2" schema="$3"
  local asset_name; asset_name=$(schema_asset_name "$schema" "$fuzhu")
  # 缓存: github 统一缓存 schema 仓 release 列表; cnb 缓存全量分页
  if [[ "$mirror" == "github" ]]; then
    cache_github "github_schema.json" "$SCHEMA_API" \
      || error_exit "连接 GitHub API 失败: $GITHUB_ERROR (匿名限流 60 次/小时, 可稍后再试或 --mirror cnb)"
  else
    cache_cnb
  fi

  # 本地版本
  local local_version="v0"
  [[ -f "$DEPLOY_DIR/version.txt" ]] && { local_version=$(cat "$DEPLOY_DIR/version.txt"); [[ "$local_version" == v* ]] || local_version="v$local_version"; }

  # 远端版本: 过滤掉词库/安卓/模型等非方案 tag, 取最大
  local remote_version
  if [[ "$mirror" == "github" ]]; then
    remote_version=$(jq -r '.[].tag_name' "$TEMP_DIR/github_schema.json" | grep -vE "dict-nightly|apk" | sort -rV | head -n1)
  else
    remote_version=$(jq -r '.releases[].tag_ref' "$TEMP_DIR/cnb.json" | grep -vE "model" | sort -rV | head -n1)
    remote_version="${remote_version#refs/tags/}"
  fi
  [[ -n "$remote_version" ]] || error_exit "未能获取远端方案版本号"
  [[ "$remote_version" == v* ]] || remote_version="v$remote_version"

  if [[ "$remote_version" == "$local_version" ]]; then
    log INFO "方案 本地=$local_version 远端=$remote_version, 无需更新"
    return 1
  fi

  local newer; newer=$(get_newer "$remote_version" "$local_version")
  if [[ "$newer" != "$remote_version" ]]; then
    log INFO "方案 本地=$local_version 已比远端 $remote_version 新, 不降级"
    return 1
  fi

  log INFO "方案 本地=$local_version 远端=$remote_version, 有更新"
  # 更新日志
  local changelog
  if [[ "$mirror" == "github" ]]; then
    changelog=$(jq -r --arg v "$remote_version" '.[] | select(.tag_name == $v) | .body' "$TEMP_DIR/github_schema.json")
  else
    changelog=$(jq -r --arg v "refs/tags/$remote_version" '.releases[] | select(.tag_ref == $v) | .body' "$TEMP_DIR/cnb.json")
  fi
  echo -e "$changelog" | sed -n '/## 📝 更新日志/,/## 🚀 下载引导/p' | drop_last_line

  log INFO "开始下载方案文件 ($asset_name)"
  local url name remote_size
  local json="$TEMP_DIR/github_schema.json"; [[ "$mirror" == "cnb" ]] && json="$TEMP_DIR/cnb.json"
  local asset; asset=$(get_info "$json" "$mirror" "$remote_version" "$asset_name") || error_exit "release $remote_version 里没有 $asset_name"
  if [[ "$mirror" == "github" ]]; then
    url=$(echo "$asset" | jq -r '.browser_download_url')
    remote_size=$(echo "$asset" | jq -r '.size')
  else
    url="https://cnb.cool$(echo "$asset" | jq -r '.path')"
    remote_size=$(echo "$asset" | jq -r '.size_in_byte')
  fi
  download_and_verify "$url" "$TEMP_DIR/$asset_name" "$remote_size" "方案文件"
  name="$asset_name"

  log INFO "解压并应用更新"
  extract_zip "$TEMP_DIR/$name" "$TEMP_DIR/${name%.zip}"
  local src="$TEMP_DIR/${name%.zip}"

  # 删除各端专用文件(方案包里夹带的非 iOS 配置)
  for _f in "${DELETE_FILES[@]}"; do
    [[ -f "$src/$_f" ]] && rm -rf "${src:?}/${_f:?}"
  done

  # === 增量同步到 DEPLOY_DIR (与原版 Python apply_update 语义一致) ===
  # 关键: 绝不整目录清空 DEPLOY_DIR — *.userdb(用户学习库, 含 LOG/CURRENT 等 LevelDB
  # 文件)、*.custom.yaml、gram 模型等都由部署/输入时生成, 不在方案包里, 一旦清空就丢失,
  # 且会导致部署时 AppGroup→Documents 同步 userdb 撞 "File exists" (NSCocoaErrorDomain 516) 报错。
  # 做法: 方案包里有的文件直接覆盖进去(命中排除清单则跳过, 保护用户已有同名文件);
  # 新包不再带的旧方案文件留在原地(无害, 避免误删用户文件)。
  # 注意 bash 的 [[ $rel == $pat ]] 里 * 跨 / (与 Python fnmatch 一致), 而 case 的 * 不跨 /。
  mkdir -p "$DEPLOY_DIR"

  local manifest="$TEMP_DIR/schema_manifest.txt"
  ( cd "$src" && find . -type f | sed 's|^\./||' ) >"$manifest"

  # 把新方案文件覆盖进 DEPLOY_DIR, 命中排除清单则跳过(保护用户已有同名文件)
  local rel _p hit
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    rel="${f#./}"
    # 命中排除清单则跳过: [[ ]] 里 * 跨 /, 对齐 Python fnmatch
    hit="false"
    if [[ -f "$EXCLUDE_FILE" ]]; then
      while IFS= read -r _p; do
        [[ "$_p" == \#* || -z "$_p" ]] && continue
        [[ "$rel" == $_p ]] && { hit="true"; break; }
      done <"$EXCLUDE_FILE"
    fi
    if [[ "$hit" == "true" ]]; then
      log INFO "跳过排除文件(保留本地): $rel"
      continue
    fi
    mkdir -p "$DEPLOY_DIR/$(dirname "$rel")"
    cp -rf "$src/$rel" "$DEPLOY_DIR/$rel"
  done <"$manifest"

  log INFO "已增量同步方案文件 (用户库/custom/模型原地保留)"
  NEEDED_DEPLOY="true"
  log INFO "方案更新成功 ($remote_version)"
  return 0
}

# ---------- 更新词库 ----------
update_dict() {
  local mirror="$1" fuzhu="$2" schema="$3"
  local asset_name; asset_name=$(dict_asset_name "$schema" "$fuzhu")

  if [[ "$mirror" == "github" ]]; then
    cache_github "github_dict.json" "$SCHEMA_API" \
      || error_exit "连接 GitHub API 失败: $GITHUB_ERROR (匿名限流 60 次/小时, 可稍后再试或 --mirror cnb)"
  else
    cache_cnb
  fi

  local tag="dict-nightly"; [[ "$mirror" == "cnb" ]] && tag="v1.0.0"
  local json="$TEMP_DIR/cnb.json"; [[ "$mirror" == "github" ]] && json="$TEMP_DIR/github_dict.json"
  local asset; asset=$(get_info "$json" "$mirror" "$tag" "$asset_name") || { log WARN "未找到词库 asset ($asset_name)"; return 1; }

  # 用 sha256 记录判断是否需要更新 (远端镜像的 updated_at 会漂移, 不可靠)
  local remote_hash record_file="$DEPLOY_DIR/custom/.dict_sha256" local_hash=""
  remote_hash=$(asset_sha256 "$mirror" "$asset")
  [[ -f "$record_file" ]] && local_hash=$(cat "$record_file")
  if [[ -n "$remote_hash" && "$remote_hash" == "$local_hash" ]]; then
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
  download_and_verify "$url" "$TEMP_DIR/$name" "$remote_size" "词库文件"

  extract_zip "$TEMP_DIR/$name" "$TEMP_DIR/${name%.zip}"
  mkdir -p "$DEPLOY_DIR/dicts"
  # 词库包可能多套一层同名目录
  if [[ -d "$TEMP_DIR/${name%.zip}/${name%.zip}" ]]; then
    cp -rf "$TEMP_DIR/${name%.zip}/${name%.zip}"/* "$DEPLOY_DIR/dicts/"
  else
    cp -rf "$TEMP_DIR/${name%.zip}"/* "$DEPLOY_DIR/dicts/"
  fi
  # 下载完整且大小校验通过才写哈希记录; 有远端哈希时顺带校验内容
  if [[ -n "$remote_hash" ]]; then
    local got_hash; got_hash=$(local_sha256 "$TEMP_DIR/$name")
    [[ "$got_hash" == "$remote_hash" ]] || error_exit "词库 sha256 校验失败 (期望 $remote_hash, 实际 $got_hash)"
  fi
  printf '%s\n' "$remote_hash" >"$record_file"
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

  local asset; asset=$(get_info "$json" "$mirror" "$tag" "$GRAM_NAME") || { log WARN "未找到模型 asset ($GRAM_NAME)"; return 1; }

  # 用 sha256 记录判断 (模型 420MB, 绝不能因为镜像时间漂移反复下载)
  local remote_hash record_file="$DEPLOY_DIR/custom/.gram_sha256" local_hash=""
  remote_hash=$(asset_sha256 "$mirror" "$asset")
  [[ -f "$record_file" ]] && local_hash=$(cat "$record_file")
  if [[ -n "$remote_hash" && "$remote_hash" == "$local_hash" && -f "$DEPLOY_DIR/$GRAM_NAME" ]]; then
    log INFO "模型记录哈希一致, 无需更新"
    return 1
  fi

  log INFO "模型有更新 (记录=$local_hash 远端=$remote_hash)"
  local url remote_size
  if [[ "$mirror" == "github" ]]; then
    url=$(echo "$asset" | jq -r '.browser_download_url')
    remote_size=$(echo "$asset" | jq -r '.size')
  else
    url="https://cnb.cool$(echo "$asset" | jq -r '.path')"
    remote_size=$(echo "$asset" | jq -r '.size_in_byte')
  fi
  download_and_verify "$url" "$TEMP_DIR/$GRAM_NAME" "$remote_size" "语法模型"
  if [[ -n "$remote_hash" ]]; then
    local got_hash; got_hash=$(local_sha256 "$TEMP_DIR/$GRAM_NAME")
    [[ "$got_hash" == "$remote_hash" ]] || error_exit "模型 sha256 校验失败 (期望 $remote_hash, 实际 $got_hash)"
  fi
  cp -rf "$TEMP_DIR/$GRAM_NAME" "$DEPLOY_DIR/$GRAM_NAME"
  printf '%s\n' "$remote_hash" >"$record_file"
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
  log INFO "环境自检 (打勾=已装, 打叉=缺失)"
  local ok="\033[0;32m✓\033[0m" bad="\033[0;31m✗\033[0m" missing=""
  check_one() { # $1 名  $2 命令  $3 用途
    if command -v "$2" >/dev/null 2>&1; then
      printf "  ${ok} %-10s  %s\n" "$1" "$3"
    else
      printf "  ${bad} %-10s  %s\n" "$1" "$3"
      missing="$missing $1"
    fi
  }
  check_one "jq"     jq     "解析 GitHub/CNB release JSON (必装)"
  check_one "unzip"  unzip   "解压方案/词库 zip (或用 tar)"
  check_one "tar"    tar    "unzip 的备选解压器"
  check_one "curl"   curl   "HTTP 下载 (与 wget 二选一)"
  check_one "wget"   wget   "HTTP 下载 (与 curl 二选一)"
  check_one "shasum" shasum "sha256 校验 (BSD 自带, 缺则用 sha256sum)"
  check_one "sha256sum" sha256sum "sha256 校验 (GNU coreutils)"
  check_one "sort"   sort   "版本号排序 (系统自带)"
  check_one "open"   open   "跳转输入法 (越狱, 与 uiopen 二选一)"
  check_one "uiopen" uiopen "跳转输入法 (越狱, 与 open 二选一)"

  echo ""
  if ! command -v jq >/dev/null 2>&1; then
    log ERROR "缺 jq: Sileo/Zebra 搜索 'jq' 安装"
  fi
  if ! command -v unzip >/dev/null 2>&1 && ! command -v tar >/dev/null 2>&1; then
    log ERROR "缺解压工具: Sileo/Zebra 搜索 'unzip' 安装"
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log ERROR "缺 HTTP 工具: 装其中之一即可 — 'curl' 或 'wget' (不想装 curl 就装 wget)"
  fi
  if ! command -v open >/dev/null 2>&1 && ! command -v uiopen >/dev/null 2>&1; then
    log WARN "缺跳转工具 open/uiopen: 不影响更新, 只是更新后需手动在输入法 App 里点一下重新部署"
  fi

  if [[ -z "$missing" ]]; then
    log INFO "自检通过 (有备选也算通过)"
  else
    log WARN "缺失项:$missing — 按上面提示在 Sileo/Zebra 安装后重试"
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
  --depdir PATH           手动指定部署目录 (默认按脚本位置自动识别仓/元书)
  --no-schema             不更新方案
  --no-dict               不更新词库
  --no-gram               不更新模型
  --no-deploy             更新后不跳转输入法
  --doctor                自检依赖并列出缺什么 (不执行更新)
  --help                  显示帮助

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
main() {
  trap cleanup EXIT
  log INFO "欢迎使用万象方案更新助手 (iOS 越狱终端版)"

  deps_check

  local mirror="" fuzhu="" schema="pro" do_schema="true" do_dict="true" do_gram="true"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror)    shift; [[ "$1" == "github" || "$1" == "cnb" ]] || error_exit "mirror 只能是 github/cnb"; mirror="$1" ;;
      --fuzhu)     shift; fuzhu_check "$1" || error_exit "fuzhu 只能是 ${FUZHU_LIST[*]}"; fuzhu="$1" ;;
      --schema)    shift; [[ "$1" == "base" || "$1" == "pro" ]] || error_exit "schema 只能是 base/pro"; schema="$1" ;;
      --depdir)    shift; DEPLOY_DIR="$1" ;;
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
    log INFO "有更新, 准备跳转重新部署"
    deploy_ios
  else
    log INFO "所有组件均为最新, 无需部署"
  fi
}

main "$@"
