#!/usr/bin/env bash
# 开发期测试：只在 macOS/Linux 上运行，不属于 iOS 运行时依赖。
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/wanxiang-update-ios.sh"
BASH_BIN=${BASH:-/bin/bash}
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/wanxiang-tests.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1"); printf 'not ok - %s%s\n' "$1" "${2:+: $2}"; }

assert_eq() { # expected actual name
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}
assert_rc() { # expected actual name
  if [[ "$1" -eq "$2" ]]; then pass "$3"; else fail "$3" "expected rc $1, got $2"; fi
}
assert_contains() { # haystack needle name
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" "missing [$2] in [$1]" ;; esac
}
assert_not_contains() { # haystack needle name
  case "$1" in *"$2"*) fail "$3" "unexpected [$2]" ;; *) pass "$3" ;; esac
}
assert_exists() { [[ -e "$1" ]] && pass "$2" || fail "$2" "missing $1"; }
assert_absent() { [[ ! -e "$1" ]] && pass "$2" || fail "$2" "unexpected $1"; }

load_script() {
  # shellcheck disable=SC1090
  source "$SCRIPT" >/dev/null 2>&1
}

new_temp() { mktemp -d "$TEST_TMP/t.XXXXXX"; }

make_stub() { # dir name
  printf '#!/bin/sh\nexit 0\n' >"$1/$2"
  chmod +x "$1/$2"
}

# 只保留脚本启动/帮助真正需要的 mktemp/cat, 用于模拟没有 jq 等依赖的环境
make_minbin() {
  local bin="$1" real_mktemp real_cat
  real_mktemp=$(command -v mktemp) || return 1
  real_cat=$(command -v cat) || return 1
  mkdir -p "$bin"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_mktemp" >"$bin/mktemp"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_cat" >"$bin/cat"
  chmod +x "$bin/mktemp" "$bin/cat"
}

make_zip_two_files() { # zip_path topdir name1 name2
  python3 - "$@" <<'PY'
import sys
import zipfile

path, top, first, second = sys.argv[1:5]
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr(top + "/" + first, "first-content")
    zf.writestr(top + "/" + second, "second-content")
PY
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

make_zip_with_topdir() { # zip_path topdir inner_name content
  python3 - "$@" <<'PY'
import sys
import zipfile

path, top, name, content = sys.argv[1:5]
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr(top + "/" + name, content)
PY
}

start_404_server() { # port_file
  python3 - "$1" >/dev/null 2>&1 <<'PY' &
import http.server
import socketserver
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_error(404)

    def log_message(self, *args):
        pass


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.handle_request()
PY
  local i
  for i in $(seq 1 50); do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

# ---------------- 1. 入口与依赖 ----------------

test_entry_help_without_jq() {
  local bin out rc
  bin="$TEST_TMP/minbin-help"; make_minbin "$bin"
  out=$(PATH="$bin" "$BASH_BIN" "$SCRIPT" --help 2>&1); rc=$?
  assert_rc 0 "$rc" "entry_help_without_jq: exit code"
  assert_contains "$out" "用法" "entry_help_without_jq: usage output"
}

test_entry_doctor_without_jq() {
  local bin out rc
  bin="$TEST_TMP/minbin-doctor"; make_minbin "$bin"
  out=$(PATH="$bin" "$BASH_BIN" "$SCRIPT" --doctor 2>&1); rc=$?
  assert_rc 0 "$rc" "entry_doctor_without_jq: exit code"
  assert_contains "$out" "环境自检" "entry_doctor_without_jq: doctor output"
  assert_contains "$out" "缺少必装项" "entry_doctor_without_jq: reports missing deps"
  assert_contains "$out" "jq" "entry_doctor_without_jq: jq listed"
}

test_args_missing_value() {
  local out rc
  out=$(PATH=/usr/bin:/bin "$BASH_BIN" "$SCRIPT" --fuzhu 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && pass "args_missing_value: nonzero" || fail "args_missing_value: nonzero" "rc=$rc"
  assert_contains "$out" "缺少取值" "args_missing_value: message"

  out=$(PATH=/usr/bin:/bin "$BASH_BIN" "$SCRIPT" --depdir 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && pass "args_missing_value: depdir nonzero" || fail "args_missing_value: depdir nonzero" "rc=$rc"
  assert_contains "$out" "缺少取值" "args_missing_value: depdir message"

  out=$(PATH=/usr/bin:/bin "$BASH_BIN" "$SCRIPT" --bogus 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && pass "args_unknown: nonzero" || fail "args_unknown: nonzero" "rc=$rc"
  assert_contains "$out" "未知参数" "args_unknown: message"
}

test_args_invalid_fuzhu() {
  local out rc
  out=$(PATH=/usr/bin:/bin "$BASH_BIN" "$SCRIPT" --fuzhu nope 2>&1); rc=$?
  [[ "$rc" -ne 0 ]] && pass "args_invalid_fuzhu: nonzero" || fail "args_invalid_fuzhu: nonzero" "rc=$rc"
  assert_contains "$out" "fuzhu" "args_invalid_fuzhu: message"
}

test_doctor_optional_only() {
  local bin out
  bin="$TEST_TMP/minbin"
  mkdir -p "$bin"
  make_stub "$bin" jq
  make_stub "$bin" unzip
  make_stub "$bin" curl
  # 脚本 source 时会先 mktemp 建临时目录; 把它指回真实实现, 其余工具保持隔离
  printf '#!/bin/sh\nexec /usr/bin/mktemp "$@"\n' >"$bin/mktemp"
  chmod +x "$bin/mktemp"
  out=$(PATH="$bin" "$BASH_BIN" -c 'source "$1" >/dev/null 2>&1; show_doctor' _ "$SCRIPT" 2>&1)
  assert_not_contains "$out" "缺少必装项" "doctor_optional_only: no required missing"
  assert_contains "$out" "必装依赖齐全" "doctor_optional_only: required ready"
  assert_contains "$out" "可选" "doctor_optional_only: optional hint"
}

# ---------------- 2. HTTP 与哈希 ----------------

test_http_404_removes_partial() {
  local port_file port pid out rc
  port_file="$TEST_TMP/port404"
  start_404_server "$port_file" || { fail "http_404_removes_partial: server" "could not start"; return; }
  pid=$!
  port=$(cat "$port_file")
  load_script
  HTTP_CLIENT="curl"
  out="$TEST_TMP/http404.out"
  rc=0
  ( http_get "http://127.0.0.1:$port/missing" "$out" ) || rc=$?
  [[ "$rc" -ne 0 ]] && pass "http_404_removes_partial: nonzero" || fail "http_404_removes_partial: nonzero" "rc=$rc"
  assert_absent "$out" "http_404_removes_partial: partial removed"
  wait "$pid" 2>/dev/null || true
}

test_hash_normalize_and_verify() {
  local file good bad rc
  load_script
  assert_eq "abcdef" "$(normalize_hash 'sha256:ABCDEF')" "hash_normalize: digest prefix and case"

  file="$TEST_TMP/hashfile"
  printf 'hello' >"$file"
  good=$(shasum -a 256 "$file" | awk '{print $1}')
  bad="0000000000000000000000000000000000000000000000000000000000000000"

  rc=0; ( verify_file_size_hash "$file" 5 "$good" "test" ) || rc=$?
  assert_rc 0 "$rc" "hash_verify: correct hash"

  rc=0; ( verify_file_size_hash "$file" 5 "$bad" "test" ) || rc=$?
  [[ "$rc" -ne 0 ]] && pass "hash_verify: bad hash rejected" || fail "hash_verify: bad hash rejected" "rc=$rc"
  assert_absent "$file" "hash_verify: bad file removed"
}

test_hash_tool_absent_degrades() {
  local file rc
  file="$TEST_TMP/hashfile-no-tool"
  printf 'hello' >"$file"
  load_script
  HASH_TOOL_READY="true"
  HASH_TOOL=""
  rc=0; ( verify_file_size_hash "$file" 5 "deadbeef" "test" ) || rc=$?
  assert_rc 0 "$rc" "hash_tool_absent: degraded to size-only"
  assert_exists "$file" "hash_tool_absent: file kept"
}

test_empty_and_unverifiable_rejected() {
  local file rc
  load_script
  file="$TEST_TMP/empty.bin"
  : >"$file"
  rc=0; ( verify_file_size_hash "$file" 10 "" "空响应" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "verify_empty: empty file rejected" || fail "verify_empty: empty file rejected" "rc=$rc"
  assert_absent "$file" "verify_empty: empty file removed"

  printf 'hello' >"$file"
  rc=0; ( verify_file_size_hash "$file" "" "" "无元数据" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "verify_empty: no size/hash rejected" || fail "verify_empty: no size/hash rejected" "rc=$rc"
  assert_absent "$file" "verify_empty: unverifiable file removed"
}

test_partial_download_fails() {
  local dest rc out
  dest="$TEST_TMP/partial.bin"
  load_script
  http_get_progress() { printf 'partial' >"$2"; return 1; }
  rc=0
  out=$( ( download_and_verify "http://invalid/x" "$dest" 100 "部分下载" ) 2>&1 ) || rc=$?
  [[ "$rc" -ne 0 ]] && pass "partial_download: nonzero" || fail "partial_download: nonzero" "rc=$rc"
  assert_absent "$dest" "partial_download: partial removed"
}

# ---------------- 3. Release 与版本 ----------------

test_version_compare_portable() {
  load_script
  local rc
  rc=0; ( version_gt v18.1.10 v18.1.8 ) || rc=$?
  assert_rc 0 "$rc" "version_gt: 18.1.10 > 18.1.8"
  rc=0; ( version_gt v9.9.9 v18.1.8 ) && rc=1 || rc=0
  assert_rc 0 "$rc" "version_gt: 9.9.9 < 18.1.8"
  rc=0; ( version_gt v18.1.8 v18.1.8 ) && rc=1 || rc=0
  assert_rc 0 "$rc" "version_gt: equal is not greater"
  assert_eq "v18.1.10" "$(get_newer v18.1.8 v18.1.10)" "get_newer: picks greater"
  assert_eq "v18.1.8" "$(get_newer v18.1.8 v18.1.8)" "get_newer: equal stays"
}

test_cnb_page_size() {
  local urls
  urls="$TEST_TMP/cnb_urls"
  load_script
  TEMP_DIR=$(new_temp)
  CNB_API="https://example.invalid/releases"
  http_get() { printf '%s\n' "$1" >>"$urls"; printf '{"releases":[]}\n' >"$2"; return 0; }
  cache_cnb
  assert_contains "$(cat "$urls")" "page_size=100" "cnb_page_size: page_size=100"
}

test_github_per_page_shared_cache() {
  local urls count
  urls="$TEST_TMP/github_urls"
  count="$TEST_TMP/github_count"
  : >"$urls"
  printf '0\n' >"$count"
  load_script
  TEMP_DIR=$(new_temp)
  SCHEMA_API="https://example.invalid/releases"
  http_get() {
    local n
    n=$(cat "$count"); printf '%s\n' "$((n + 1))" >"$count"
    printf '%s\n' "$1" >>"$urls"
    printf '[{"tag_name":"v18.1.8","name":"v18.1.8-Rime万象拼音输入方案","assets":[]}]\n' >"$2"
    return 0
  }
  cache_github "github_releases.json" "$SCHEMA_API"
  cache_github "github_releases.json" "$SCHEMA_API"
  assert_contains "$(cat "$urls")" "per_page=100" "github_per_page: per_page=100"
  assert_eq "1" "$(cat "$count")" "github_per_page: shared cache"
}

test_release_select_by_title() {
  local cnb gh
  cnb="$TEST_TMP/cnb.json"
  gh="$TEST_TMP/gh.json"
  cat >"$cnb" <<'JSON'
{"releases":[
 {"tag_ref":"refs/tags/v18.1.8","title":"v18.1.8-Rime万象拼音输入方案","body":"","assets":[]},
 {"tag_ref":"refs/tags/v18.1.7","title":"v18.1.7-Rime万象拼音输入方案","body":"","assets":[]},
 {"tag_ref":"refs/tags/v1.0.0","title":"🚀 实时全量预览版 (Rolling Preview)","body":"","assets":[]},
 {"tag_ref":"refs/tags/model","title":"语法模型","body":"","assets":[]}
]}
JSON
  cat >"$gh" <<'JSON'
[
 {"tag_name":"v18.1.8","name":"v18.1.8-Rime万象拼音输入方案","assets":[]},
 {"tag_name":"v18.1.7","name":"v18.1.7-Rime万象拼音输入方案","assets":[]},
 {"tag_name":"dict-nightly","name":"🚀 实时全量预览版 (Rolling Preview)","assets":[]}
]
JSON
  load_script
  assert_eq "v18.1.8" "$(select_scheme_release cnb "$cnb")" "release_select: cnb scheme"
  assert_eq "v1.0.0" "$(select_dict_release cnb "$cnb")" "release_select: cnb dict"
  assert_eq "v18.1.8" "$(select_scheme_release github "$gh")" "release_select: github scheme"
  assert_eq "dict-nightly" "$(select_dict_release github "$gh")" "release_select: github dict"
}

test_asset_suffix_fallback() {
  local json release rc out
  json="$TEST_TMP/assets.json"
  cat >"$json" <<'JSON'
{"tag_name":"v1.0.0","assets":[
 {"name":"base-dicts.zip","size":10,"digest":"sha256:aa"},
 {"name":"pro-flypy-fuzhu-dicts.zip","size":20,"digest":"sha256:bb"}
]}
JSON
  release=$(cat "$json")
  load_script
  assert_contains "$(get_asset github "$release" "pro-flypy-fuzhu-dicts.zip")" "pro-flypy-fuzhu-dicts.zip" "asset_exact: exact name"

  rc=0; out=$( ( get_asset github "$release" "missing-name-dicts.zip" ) 2>/dev/null ) || rc=$?
  [[ "$rc" -ne 0 ]] && pass "asset_fallback: ambiguous candidates rejected" || fail "asset_fallback: ambiguous candidates rejected" "rc=$rc"
  assert_eq "" "$out" "asset_fallback: no arbitrary pick"

  cat >"$json" <<'JSON'
{"tag_name":"v1.0.0","assets":[
 {"name":"base-dicts.zip","size":10,"digest":"sha256:aa"}
]}
JSON
  release=$(cat "$json")
  assert_contains "$(get_asset github "$release" "other-dicts.zip")" "base-dicts.zip" "asset_fallback: unique suffix"
}

# ---------------- 4. 部署识别与兼容 ----------------

test_cnb_pagination_merge() {
  local merged
  load_script
  TEMP_DIR=$(new_temp)
  CNB_API="https://example.invalid/releases"
  http_get() {
    case "$1" in
      *page=1*) printf '{"releases":[{"tag_ref":"refs/tags/v1","title":"a"},{"tag_ref":"refs/tags/v2","title":"b"}]}\n' >"$2" ;;
      *) printf '{"releases":[]}\n' >"$2" ;;
    esac
    return 0
  }
  cache_cnb
  merged=$(jq '.releases | length' "$TEMP_DIR/cnb.json")
  assert_eq "2" "$merged" "cnb_pagination: merged across pages"
}

test_depdir_engine_inference() {
  load_script
  DEPLOY_DIR="$TEST_TMP/RimeUserData/wanxiang"
  detect_deploy_dir
  assert_eq "元书" "$RIME_ENGINE" "depdir_engine: RimeUserData"
  DEPLOY_DIR="$TEST_TMP/Hamster/RIME/Rime"
  detect_deploy_dir
  assert_eq "仓" "$RIME_ENGINE" "depdir_engine: Hamster"
  DEPLOY_DIR="RimeUserData/wanxiang"
  detect_deploy_dir
  assert_eq "元书" "$RIME_ENGINE" "depdir_engine: relative RimeUserData"
  DEPLOY_DIR="./RimeUserData/wanxiang"
  detect_deploy_dir
  assert_eq "元书" "$RIME_ENGINE" "depdir_engine: dot-relative RimeUserData"
}

# ---------------- 4. 方案同步 ----------------

test_scheme_decision_cases() {
  load_script
  assert_eq "update" "$(scheme_decision v18.1.8 aa v18.1.7 bb)" "scheme_decision: newer remote"
  assert_eq "skip" "$(scheme_decision v18.1.8 aa v18.1.8 aa)" "scheme_decision: same version same hash"
  assert_eq "update" "$(scheme_decision v18.1.8 aa v18.1.8 bb)" "scheme_decision: same version different hash"
  assert_eq "update" "$(scheme_decision v18.1.8 aa v18.1.8 '')" "scheme_decision: record missing"
  assert_eq "downgrade" "$(scheme_decision v18.1.7 aa v18.1.8 bb)" "scheme_decision: local newer"
  assert_eq "skip" "$(scheme_decision v18.1.8 '' v18.1.8 aa)" "scheme_decision: no remote hash"
  assert_eq "unknown" "$(scheme_decision bad aa v18.1.8 bb)" "scheme_decision: invalid version"
}

test_exclude_root_only() {
  local file rc
  file="$TEST_TMP/exclude.txt"
  cat >"$file" <<'EOF'
# 注释
custom/user_exclude_file.txt
*.custom.yaml
*.userdb
custom_phrase.txt
EOF
  load_script
  rc=0; ( is_excluded "custom/wanxiang.custom.yaml" "$file" ) || rc=$?
  assert_rc 1 "$rc" "exclude: nested custom template not excluded"
  rc=0; ( is_excluded "wanxiang.custom.yaml" "$file" ) || rc=$?
  assert_rc 0 "$rc" "exclude: root custom file excluded"
  rc=0; ( is_excluded "custom/user_exclude_file.txt" "$file" ) || rc=$?
  assert_rc 0 "$rc" "exclude: slash pattern matches full path"
  rc=0; ( is_excluded "dicts/foo.userdb" "$file" ) || rc=$?
  assert_rc 1 "$rc" "exclude: nested userdb not excluded"
  rc=0; ( is_excluded "custom_phrase.txt" "$file" ) || rc=$?
  assert_rc 0 "$rc" "exclude: root custom_phrase excluded"
}

test_scheme_root_and_build_cleanup() {
  local extract deploy exclude bad rc
  load_script
  extract="$TEST_TMP/extract"; deploy="$TEST_TMP/deploy-apply"; exclude="$TEST_TMP/exclude-apply"
  mkdir -p "$extract/pkg/custom" "$extract/pkg/dicts" "$deploy/build"
  printf 'new-template\n' >"$extract/pkg/custom/template.yaml"
  printf 'new-root\n' >"$extract/pkg/default.yaml"
  printf 'bundled-dict\n' >"$extract/pkg/dicts/bundled.dict.yaml"
  printf 'squirrel\n' >"$extract/pkg/squirrel.yaml"
  printf 'stale\n' >"$deploy/build/stale.txt"
  printf 'user\n' >"$deploy/wanxiang.custom.yaml"
  printf '*.custom.yaml\n' >"$exclude"
  apply_scheme_files "$extract" "$deploy" "$exclude"
  assert_exists "$deploy/default.yaml" "scheme_apply: root resolved and file deployed"
  assert_exists "$deploy/custom/template.yaml" "scheme_apply: custom template deployed"
  assert_absent "$deploy/squirrel.yaml" "scheme_apply: platform file skipped"
  assert_absent "$deploy/dicts/bundled.dict.yaml" "scheme_apply: bundled dicts owned by dict updater"
  assert_absent "$deploy/build" "scheme_apply: build dir removed"
  assert_eq "user" "$(cat "$deploy/wanxiang.custom.yaml")" "scheme_apply: root user file kept"

  bad="$TEST_TMP/extract-bad"; mkdir -p "$bad/a" "$bad/b"
  printf 'x\n' >"$bad/a/file.yaml"
  rc=0; ( apply_scheme_files "$bad" "$TEST_TMP/deploy-bad" "$exclude" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "scheme_apply: malformed package rejected" || fail "scheme_apply: malformed package rejected" "rc=$rc"
}

test_scheme_bad_hash_no_change() {
  local tmp deploy json size before rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-scheme-bad"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'v18.1.7\n' >"$deploy/version.txt"
  printf 'keep-me\n' >"$deploy/wanxiang.custom.yaml"
  printf 'old\n' >"$deploy/old.yaml"
  printf '*.custom.yaml\n' >"$deploy/custom/user_exclude_file.txt"
  SCHEME_FIXTURE="$tmp/pkg.zip"
  make_zip_with_topdir "$SCHEME_FIXTURE" "pkg" "new.yaml" "new-scheme"
  size=$(wc -c <"$SCHEME_FIXTURE" | tr -d ' ')
  json="$tmp/cnb.json"
  cat >"$json" <<JSON
{"releases":[{"tag_ref":"refs/tags/v18.1.8","title":"v18.1.8-Rime万象拼音输入方案","body":"","assets":[{"name":"rime-wanxiang-flypy-fuzhu.zip","size_in_byte":$size,"path":"/x/pkg.bin","hash_algo":"sha256","hash_value":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}]}]}
JSON
  cache_cnb() { return 0; }
  DOWNLOAD_MARK="$TEST_TMP/scheme-bad-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp "$SCHEME_FIXTURE" "$2"; }
  before=$(cd "$deploy" && find . -type f | LC_ALL=C sort)
  rc=0; ( update_schema cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "scheme_bad_hash: aborted" || fail "scheme_bad_hash: aborted" "rc=$rc"
  assert_exists "$DOWNLOAD_MARK" "scheme_bad_hash: failure after download"
  assert_eq "$before" "$(cd "$deploy" && find . -type f | LC_ALL=C sort)" "scheme_bad_hash: deploy unchanged"
  assert_absent "$deploy/custom/.scheme_sha256" "scheme_bad_hash: no record"
}

# ---------------- 5. 词库与模型 ----------------

write_dict_cnb() { # json zip hash
  local size; size=$(wc -c <"$2" | tr -d ' ')
  cat >"$1" <<JSON
{"releases":[{"tag_ref":"refs/tags/v1.0.0","title":"🚀 实时全量预览版 (Rolling Preview)","assets":[{"name":"pro-flypy-fuzhu-dicts.zip","size_in_byte":$size,"path":"/x/dicts.zip","hash_algo":"sha256","hash_value":"sha256:$3"}]}]}
JSON
}

test_dict_bad_hash_keeps_existing() {
  local tmp deploy json zip rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-dict-bad"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/dicts" "$deploy/custom"
  printf 'old-dict\n' >"$deploy/dicts/old.dict.yaml"
  zip="$tmp/dicts.zip"
  make_zip_with_topdir "$zip" "pro-flypy-fuzhu-dicts" "new.dict.yaml" "new-dict"
  json="$tmp/cnb.json"
  write_dict_cnb "$json" "$zip" "0000000000000000000000000000000000000000000000000000000000000000"
  cache_cnb() { return 0; }
  DOWNLOAD_MARK="$TEST_TMP/dict-bad-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp "$zip" "$2"; }
  rc=0; ( update_dict cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "dict_bad_hash: aborted" || fail "dict_bad_hash: aborted" "rc=$rc"
  assert_exists "$DOWNLOAD_MARK" "dict_bad_hash: failure after download"
  assert_eq "old-dict" "$(cat "$deploy/dicts/old.dict.yaml")" "dict_bad_hash: existing dict kept"
  assert_absent "$deploy/dicts/new.dict.yaml" "dict_bad_hash: new dict not applied"
  assert_absent "$deploy/custom/.dict_sha256" "dict_bad_hash: no record"
}

test_dict_topdir_stripped() {
  local tmp deploy json zip hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-dict-top"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  zip="$tmp/dicts.zip"
  make_zip_with_topdir "$zip" "some-other-topdir" "wanxiang.dict.yaml" "dict-content"
  hash=$(sha_of "$zip")
  json="$tmp/cnb.json"
  write_dict_cnb "$json" "$zip" "$hash"
  cache_cnb() { return 0; }
  http_get_progress() { cp "$zip" "$2"; }
  rc=0; ( update_dict cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  assert_rc 0 "$rc" "dict_topdir: update succeeded"
  assert_exists "$deploy/dicts/wanxiang.dict.yaml" "dict_topdir: file deployed at root"
  assert_absent "$deploy/dicts/some-other-topdir" "dict_topdir: extra dir stripped"
  assert_exists "$deploy/custom/.dict_sha256" "dict_topdir: record written"
}

test_dict_missing_forces_update() {
  local tmp deploy json zip hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-dict-missing"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  zip="$tmp/dicts.zip"
  make_zip_with_topdir "$zip" "t" "wanxiang.dict.yaml" "dict-content"
  hash=$(sha_of "$zip")
  printf '%s\n' "$hash" >"$deploy/custom/.dict_sha256"
  json="$tmp/cnb.json"
  write_dict_cnb "$json" "$zip" "$hash"
  cache_cnb() { return 0; }
  DOWNLOAD_MARK="$TEST_TMP/dict-missing-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp "$zip" "$2"; }
  rc=0; ( update_dict cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  assert_rc 0 "$rc" "dict_missing: update succeeded"
  assert_exists "$DOWNLOAD_MARK" "dict_missing: forced download"
  assert_exists "$deploy/dicts/wanxiang.dict.yaml" "dict_missing: dicts populated"
}

test_dict_partial_copy_retries() {
  local tmp deploy json zip hash rc n
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-dict-partial"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/dicts" "$deploy/custom"
  zip="$TEST_TMP/dict-partial.zip"
  json="$TEST_TMP/dict-partial.json"
  make_zip_two_files "$zip" "t" "a.dict.yaml" "b.dict.yaml"
  hash=$(sha_of "$zip")
  # 记录与远端一致, 但 dicts/ 为空 -> 首次强制重装
  printf '%s\n' "$hash" >"$deploy/custom/.dict_sha256"
  write_dict_cnb "$json" "$zip" "$hash"
  # 首次失败会清理 TEMP_DIR, 所以缓存和下载源都放在 TEMP_DIR 之外
  DICT_JSON_FIXTURE="$json"
  cache_cnb() { mkdir -p "$TEMP_DIR"; cp "$DICT_JSON_FIXTURE" "$TEMP_DIR/cnb.json"; }
  http_get_progress() { cp "$zip" "$2"; }

  n=0
  cp() { # 第二次复制到 dicts/ 时失败, 模拟中断
    if [[ "${3:-}" == *"/dicts/"* ]]; then
      n=$((n + 1))
      if [[ "$n" -eq 2 ]]; then return 1; fi
    fi
    command cp "$@"
  }
  rc=0; ( update_dict cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  unset -f cp
  [[ "$rc" -ne 0 ]] && pass "dict_partial: interrupted copy fails" || fail "dict_partial: interrupted copy fails" "rc=$rc"
  assert_absent "$deploy/custom/.dict_sha256" "dict_partial: stale record invalidated"

  rc=0; ( update_dict cnb flypy pro ) >/dev/null 2>&1 || rc=$?
  assert_rc 0 "$rc" "dict_partial: retry succeeds"
  assert_exists "$deploy/dicts/a.dict.yaml" "dict_partial: first file restored"
  assert_exists "$deploy/dicts/b.dict.yaml" "dict_partial: missing file restored"
  assert_exists "$deploy/custom/.dict_sha256" "dict_partial: record rewritten"
}

write_gram_cnb() { # json size hash
  cat >"$1" <<JSON
{"releases":[{"tag_ref":"refs/tags/model","title":"语法模型","assets":[{"name":"wanxiang-lts-zh-hans.gram","size_in_byte":$2,"path":"/x/model.gram","hash_algo":"sha256","hash_value":"sha256:$3"}]}]}
JSON
}

test_gram_skip_when_local_matches() {
  local tmp deploy json size hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-gram-skip"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'model-content' >"$deploy/wanxiang-lts-zh-hans.gram"
  hash=$(sha_of "$deploy/wanxiang-lts-zh-hans.gram")
  printf '%s\n' "$hash" >"$deploy/custom/.gram_sha256"
  size=$(wc -c <"$deploy/wanxiang-lts-zh-hans.gram" | tr -d ' ')
  json="$tmp/cnb.json"
  write_gram_cnb "$json" "$size" "$hash"
  cache_cnb() { return 0; }
  DOWNLOAD_MARK="$TEST_TMP/gram-skip-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp /dev/null "$2"; }
  rc=0; ( update_gram cnb ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "gram_skip: reported no update" || fail "gram_skip: reported no update" "rc=$rc"
  assert_absent "$DOWNLOAD_MARK" "gram_skip: no download"
  assert_eq "model-content" "$(cat "$deploy/wanxiang-lts-zh-hans.gram")" "gram_skip: model kept"
}

test_gram_bad_hash_keeps_old() {
  local tmp deploy json size rc dest_seen
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-gram-bad"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'old-model' >"$deploy/wanxiang-lts-zh-hans.gram"
  GRAM_FIXTURE="$tmp/new.gram"
  printf 'corrupt-content' >"$GRAM_FIXTURE"
  size=$(wc -c <"$GRAM_FIXTURE" | tr -d ' ')
  json="$tmp/cnb.json"
  write_gram_cnb "$json" "$size" "0000000000000000000000000000000000000000000000000000000000000000"
  cache_cnb() { return 0; }
  dest_seen="$TEST_TMP/gram-dest-path"; rm -f "$dest_seen"
  http_get_progress() { printf '%s' "$2" >"$dest_seen"; cp "$GRAM_FIXTURE" "$2"; }
  rc=0; ( update_gram cnb ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "gram_bad_hash: aborted" || fail "gram_bad_hash: aborted" "rc=$rc"
  assert_eq "$deploy/.wanxiang-lts-zh-hans.gram.tmp" "$(cat "$dest_seen" 2>/dev/null)" "gram_bad_hash: downloads to deploy temp"
  assert_eq "old-model" "$(cat "$deploy/wanxiang-lts-zh-hans.gram")" "gram_bad_hash: old model kept"
  assert_absent "$deploy/.wanxiang-lts-zh-hans.gram.tmp" "gram_bad_hash: no temp file"
  assert_absent "$deploy/custom/.gram_sha256" "gram_bad_hash: no record"
}

test_gram_repairs_local_mismatch() {
  local tmp deploy json size hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-gram-repair"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'tampered-model' >"$deploy/wanxiang-lts-zh-hans.gram"
  GRAM_FIXTURE="$tmp/good.gram"
  printf 'good-model' >"$GRAM_FIXTURE"
  hash=$(sha_of "$GRAM_FIXTURE")
  printf '%s\n' "$hash" >"$deploy/custom/.gram_sha256"
  size=$(wc -c <"$GRAM_FIXTURE" | tr -d ' ')
  json="$tmp/cnb.json"
  write_gram_cnb "$json" "$size" "$hash"
  cache_cnb() { return 0; }
  DOWNLOAD_MARK="$TEST_TMP/gram-repair-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp "$GRAM_FIXTURE" "$2"; }
  rc=0; ( update_gram cnb ) >/dev/null 2>&1 || rc=$?
  assert_rc 0 "$rc" "gram_repair: update succeeded"
  assert_exists "$DOWNLOAD_MARK" "gram_repair: downloaded"
  assert_eq "good-model" "$(cat "$deploy/wanxiang-lts-zh-hans.gram")" "gram_repair: model replaced"
}

test_gram_no_hash_tool_size_fallback() {
  local tmp deploy json size hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-gram-nohash"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'model-content' >"$deploy/wanxiang-lts-zh-hans.gram"
  hash=$(sha_of "$deploy/wanxiang-lts-zh-hans.gram")
  printf '%s\n' "$hash" >"$deploy/custom/.gram_sha256"
  size=$(wc -c <"$deploy/wanxiang-lts-zh-hans.gram" | tr -d ' ')
  json="$tmp/cnb.json"
  write_gram_cnb "$json" "$size" "$hash"
  cache_cnb() { return 0; }
  detect_hash_tool() { return 1; }
  DOWNLOAD_MARK="$TEST_TMP/gram-nohash-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp /dev/null "$2"; }
  rc=0; ( update_gram cnb ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "gram_nohash: reported no update" || fail "gram_nohash: reported no update" "rc=$rc"
  assert_absent "$DOWNLOAD_MARK" "gram_nohash: size match skips download"
  assert_eq "model-content" "$(cat "$deploy/wanxiang-lts-zh-hans.gram")" "gram_nohash: model kept"
}

test_gram_no_hash_tool_size_mismatch_repairs() {
  local tmp deploy json size hash rc
  load_script
  tmp=$(new_temp); TEMP_DIR="$tmp"
  deploy="$TEST_TMP/deploy-gram-nohash-bad"; DEPLOY_DIR="$deploy"; mkdir -p "$deploy/custom"
  printf 'short' >"$deploy/wanxiang-lts-zh-hans.gram"
  GRAM_FIXTURE="$tmp/good.gram"; printf 'model-content' >"$GRAM_FIXTURE"
  hash=$(sha_of "$GRAM_FIXTURE")
  printf '%s\n' "$hash" >"$deploy/custom/.gram_sha256"
  size=$(wc -c <"$GRAM_FIXTURE" | tr -d ' ')
  json="$tmp/cnb.json"
  write_gram_cnb "$json" "$size" "$hash"
  cache_cnb() { return 0; }
  detect_hash_tool() { return 1; }
  DOWNLOAD_MARK="$TEST_TMP/gram-nohash-repair-downloaded"; rm -f "$DOWNLOAD_MARK"
  http_get_progress() { : >"$DOWNLOAD_MARK"; cp "$GRAM_FIXTURE" "$2"; }
  rc=0; ( update_gram cnb ) >/dev/null 2>&1 || rc=$?
  assert_rc 0 "$rc" "gram_nohash_mismatch: update succeeded"
  assert_exists "$DOWNLOAD_MARK" "gram_nohash_mismatch: downloaded"
  assert_eq "model-content" "$(cat "$deploy/wanxiang-lts-zh-hans.gram")" "gram_nohash_mismatch: model replaced"
}

test_deploy_scheme_inference() {
  local out empty
  load_script
  empty="$TEST_TMP/emptybin-scheme"; mkdir -p "$empty"

  DEPLOY_DIR="$TEST_TMP/RimeUserData/wanxiang"
  detect_deploy_dir
  out=$( PATH="$empty"; sleep() { :; }; deploy_ios 2>&1 )
  assert_contains "$out" "hamster3://dev.fuxiao.app.hamster3/rime?action=deploy" "deploy_scheme: 元书 RimeUserData"

  DEPLOY_DIR="$TEST_TMP/Hamster/RIME/Rime"
  detect_deploy_dir
  out=$( PATH="$empty"; sleep() { :; }; deploy_ios 2>&1 )
  assert_contains "$out" "hamster://dev.fuxiao.app.hamster/rime?deploy" "deploy_scheme: 仓 Hamster"
}

test_deploy_disabled_no_call() {
  local out rc empty mark
  load_script
  empty="$TEST_TMP/emptybin-nocall"; mkdir -p "$empty"
  mark="$TEST_TMP/uiopen-called"; rm -f "$mark"
  cat >"$empty/uiopen" <<EOF
#!/bin/sh
: >"$mark"
EOF
  chmod +x "$empty/uiopen"
  rc=0
  out=$( PATH="$empty"; sleep() { :; }; AUTO_DEPLOY="false"; deploy_ios 2>&1 ) || rc=$?
  assert_rc 0 "$rc" "deploy_disabled: exit code"
  assert_absent "$mark" "deploy_disabled: no command called"
  assert_contains "$out" "AUTO_DEPLOY=false" "deploy_disabled: hint"
}

test_deploy_tool_missing_hint() {
  local out rc empty
  load_script
  empty="$TEST_TMP/emptybin-notool"; mkdir -p "$empty"
  rc=0
  out=$( PATH="$empty"; sleep() { :; }; AUTO_DEPLOY="true"; RIME_ENGINE="仓"; deploy_ios 2>&1 ) || rc=$?
  assert_rc 0 "$rc" "deploy_tool_missing: not a failure"
  assert_contains "$out" "自动跳转未成功" "deploy_tool_missing: warning"
  assert_contains "$out" "URL: hamster://dev.fuxiao.app.hamster/rime?deploy" "deploy_tool_missing: url printed"
  assert_contains "$out" "手动" "deploy_tool_missing: manual hint"
}

test_static_compat() {
  local bad help_out
  bad=$(grep -nE 'sort -V|sort -rV|mapfile|readarray|declare -A|local -n|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|head -n -1' "$SCRIPT" || true)
  assert_eq "" "$bad" "static_compat: no bash4/non-portable features"
  help_out=$("$BASH_BIN" "$SCRIPT" --help 2>&1)
  assert_contains "$help_out" "用法" "static_compat: /bin/bash --help"
}

# ---------------- 运行 ----------------

TESTS=(
  test_entry_help_without_jq
  test_entry_doctor_without_jq
  test_args_missing_value
  test_args_invalid_fuzhu
  test_doctor_optional_only
  test_http_404_removes_partial
  test_hash_normalize_and_verify
  test_hash_tool_absent_degrades
  test_empty_and_unverifiable_rejected
  test_partial_download_fails
  test_version_compare_portable
  test_cnb_page_size
  test_cnb_pagination_merge
  test_github_per_page_shared_cache
  test_release_select_by_title
  test_asset_suffix_fallback
  test_depdir_engine_inference
  test_scheme_decision_cases
  test_exclude_root_only
  test_scheme_root_and_build_cleanup
  test_scheme_bad_hash_no_change
  test_dict_bad_hash_keeps_existing
  test_dict_topdir_stripped
  test_dict_missing_forces_update
  test_dict_partial_copy_retries
  test_gram_skip_when_local_matches
  test_gram_repairs_local_mismatch
  test_gram_bad_hash_keeps_old
  test_gram_no_hash_tool_size_fallback
  test_gram_no_hash_tool_size_mismatch_repairs
  test_deploy_scheme_inference
  test_deploy_disabled_no_call
  test_deploy_tool_missing_hint
  test_static_compat
)

for t in "${TESTS[@]}"; do
  printf '# %s\n' "$t"
  "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'failures:\n'
  printf ' - %s\n' "${FAILURES[@]}"
  exit 1
fi
