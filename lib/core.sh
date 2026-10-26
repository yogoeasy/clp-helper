#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Extension
# File: lib/core.sh
# Description: Core foundation library: logging, pre-flight checks,
#              unified parameter parser, and system helpers.
# ==============================================================================

# Ensure strict mode when executed, but safe when sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || set -euo pipefail

# Ensure CLP_LIB_DIR is defined and exported
if [[ -z "${CLP_LIB_DIR:-}" ]]; then
  if [[ -n "${CLP_ROOT_DIR:-}" ]]; then
    CLP_LIB_DIR="${CLP_ROOT_DIR}/lib"
  else
    CLP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  export CLP_LIB_DIR
fi

# Ensure i18n engine is sourced
if [[ ! $(type -t _t) == "function" ]]; then
  if [[ -f "${CLP_ROOT_DIR:-}/lib/i18n.sh" ]]; then
    source "${CLP_ROOT_DIR}/lib/i18n.sh"
  elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/i18n.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
  fi
fi

# ------------------------------------------------------------------------------
# 1. Colors and Formatting
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_PURPLE=$'\033[0;35m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_NC=$'\033[0m'
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_PURPLE=''
  C_CYAN=''
  C_BOLD=''
  C_DIM=''
  C_NC=''
fi

# ------------------------------------------------------------------------------
# 2. Logging System
# ------------------------------------------------------------------------------
CLP_LOG_DIR="/var/log/clp"
CLP_LOG_FILE="${CLP_LOG_DIR}/clp.log"

# log 會記錄網域、路徑等資訊：目錄 750、檔案 600（只有 root 可讀）。umask 只在子 shell 中設定，
# 不影響之後 clp 建立的其他檔案；非 root 執行時失敗忽略
init_logging() {
  if [[ ! -d "$CLP_LOG_DIR" ]]; then
    (umask 077; mkdir -p "$CLP_LOG_DIR") 2>/dev/null || true
  fi
  if [[ -d "$CLP_LOG_DIR" && ! -f "$CLP_LOG_FILE" ]]; then
    (umask 077; touch "$CLP_LOG_FILE") 2>/dev/null || true
  fi
  chmod 750 "$CLP_LOG_DIR" 2>/dev/null || true
  chmod 600 "$CLP_LOG_FILE" 2>/dev/null || true
}

log_write() {
  local level_color="$1"
  local level_tag="$2"
  shift 2
  local msg="$*"
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')

  # Terminal output（以 printf %s 輸出至 stderr，訊息內容中的反斜線序列不會被解譯或截斷）
  printf '%s[%s]%s %s\n' "$level_color" "$level_tag" "$C_NC" "$msg" >&2

  # File output (strip ANSI colors)
  if [[ -w "$CLP_LOG_FILE" ]]; then
    printf '[%s] [%s] %s\n' "$now" "$level_tag" "$msg" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" >> "$CLP_LOG_FILE" 2>/dev/null || true
  fi
}

log_info()    { log_write "${C_GREEN}"  "${CLP_TAG_INFO:-INFO }" "$*"; }
log_success() { log_write "${C_GREEN}${C_BOLD}" "${CLP_TAG_SUCCESS:-OK   }" "${C_GREEN}$*${C_NC}"; }
log_warn()    { log_write "${C_YELLOW}" "${CLP_TAG_WARN:-WARN }" "${C_YELLOW}$*${C_NC}"; }
log_error()   { log_write "${C_RED}${C_BOLD}" "${CLP_TAG_ERROR:-ERROR}" "${C_RED}$*${C_NC}"; }
log_step()    { log_write "${C_CYAN}${C_BOLD}"  "${CLP_TAG_STEP:-STEP }" "${C_BOLD}$*${C_NC}"; }

# ------------------------------------------------------------------------------
# 3. Pre-Flight & Dependency Checks
# ------------------------------------------------------------------------------
check_root() {
  if [[ "${CLP_SKIP_ROOT_CHECK:-}" == "true" ]]; then
    return 0
  fi
  for _chk_arg in "$@"; do
    if [[ "$_chk_arg" == "--dry-run" || "$_chk_arg" == "-dry-run" || "$_chk_arg" == "--dry_run" || "$_chk_arg" == "-dry_run" || "$_chk_arg" == "-h" || "$_chk_arg" == "--help" || "$_chk_arg" == "help" ]]; then
      return 0
    fi
  done
  if command -v has_opt >/dev/null 2>&1; then
    if has_opt "dry_run" || has_opt "dry-run" || has_opt "h" || has_opt "help"; then
      return 0
    fi
  fi
  if [[ $EUID -ne 0 ]]; then
    local example="sudo clp"
    if [[ $# -gt 0 ]]; then
      example="sudo clp $*"
    fi
    log_error "$(_t "CORE_ERR_ROOT_REQUIRED" "$example")"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_warn "$(_t "CORE_WARN_OS_RELEASE_NOT_FOUND")"
    return 0
  fi

  local os_id="" os_ver="" pretty_name=""
  os_id=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || true)
  os_ver=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || true)
  pretty_name=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || true)

  log_info "$(_t "CORE_INFO_OS_DETECTED" "${pretty_name:-$os_id}" "$os_id" "$os_ver")"

  case "$os_id" in
    ubuntu)
      if [[ "$os_ver" != "22.04" && "$os_ver" != "24.04" && "$os_ver" != "26.04" ]]; then
        log_warn "$(_t "CORE_WARN_UBUNTU_VERSION" "$os_ver")"
      fi
      ;;
    debian)
      if [[ "$os_ver" != "11" && "$os_ver" != "12" ]]; then
        log_warn "$(_t "CORE_WARN_DEBIAN_VERSION" "$os_ver")"
      fi
      ;;
    *)
      log_warn "$(_t "CORE_WARN_UNSUPPORTED_OS" "$os_id")"
      ;;
  esac
}

# require_clp_db_server_ready：CloudPanel 全新安裝後，資料庫伺服器要等第一位管理員在網頁建立帳號時才會初始化，
# 在此之前 clpctl db:add 會失敗。建站／複製／搬移前先檢查，避免網站建好了才在建立資料庫時失敗。
require_clp_db_server_ready() {
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1 || return 0
  local n
  n=$(sqlite3 -readonly "$clp_db" "SELECT count(*) FROM database_server;" 2>/dev/null || echo "")
  [[ -z "$n" || "$n" -gt 0 ]] && return 0
  log_error "$(_t "CORE_ERR_CLP_DB_SERVER_NOT_READY" "$(get_server_ip 2>/dev/null || echo "<server-ip>")")"
  return 1
}

# 取得 CloudPanel MySQL master (root) 密碼；失敗時輸出空字串
get_mysql_master_pass() {
  clpctl db:show:master-credentials 2>/dev/null | grep -i 'Password' | awk -F'|' '{print $3}' | tr -d ' ' || true
}

# 取得 CloudPanel MySQL master 的連線位置，輸出「主機 埠號」（例如 127.0.0.1 3306）；失敗時輸出空字串
#   由 CloudPanel 管理，不受網站使用者控制（不可改用 wp-config.php 的 DB_HOST）
get_mysql_master_host_port() {
  clpctl db:show:master-credentials 2>/dev/null | awk -F'|' '
    /^\| *Host *\|/ { h = $3; gsub(/ /, "", h) }
    /^\| *Port *\|/ { p = $3; gsub(/ /, "", p) }
    END { if (h != "") print h, (p != "" ? p : 3306) }' || true
}

# mysql_no_cmds_opt：設定 CLP_MYSQL_NO_CMDS_OPT，匯入不可信任的 SQL 時讓 mysql 用戶端不執行 \!（system）、tee、source 等用戶端指令
#   clp 以 root 執行 mysql 用戶端：SQL 中的 \! 會以 root 身分執行 shell 指令（與使用哪個 DB 帳號無關）
#   用戶端支援 --sandbox（MariaDB）就用它；否則用 --binary-mode（MySQL 與 MariaDB 都支援，非互動模式下只保留 \C 與 DELIMITER）
#   不在 $(...) 中呼叫（快取會留在子 shell）
mysql_no_cmds_opt() {
  [[ -n "${CLP_MYSQL_NO_CMDS_OPT:-}" ]] && return 0
  local help_out
  help_out=$(mysql --no-defaults --help 2>/dev/null || true)
  if [[ "$help_out" == *"--sandbox"* ]]; then
    CLP_MYSQL_NO_CMDS_OPT="--sandbox"
  else
    CLP_MYSQL_NO_CMDS_OPT="--binary-mode"
  fi
}

# ------------------------------------------------------------------------------
# nginx real-ip：CloudPanel 的 nginx.conf 預設有 set_real_ip_from 0.0.0.0/0（http 層級、讀 X-Real-IP），
#   任何 IPv4 用戶端都能以偽造的 X-Real-IP 換掉 $remote_addr，依 IP 判斷的 allow
#   （cf-only、httpauth 白名單）因此可被繞過。cf-only 與 httpauth 共用以下函式。
#   標記字串沿用 cf-only 最早的寫法，已被註解的主機才能繼續辨識。
# ------------------------------------------------------------------------------
CLP_REALIP_NGINX_CONF="/etc/nginx/nginx.conf"
CLP_REALIP_MARK="# disabled by CLP Helper (cf-only)"
CLP_REALIP_RE='^[[:space:]]*set_real_ip_from[[:space:]]+0\.0\.0\.0/0[[:space:]]*;'

# clp_realip_state：輸出 active（生效中）| clp（已由 clp 註解）| none（不存在）
clp_realip_state() {
  if grep -Eq "$CLP_REALIP_RE" "$CLP_REALIP_NGINX_CONF" 2>/dev/null; then
    echo "active"
  elif grep -Fq "$CLP_REALIP_MARK" "$CLP_REALIP_NGINX_CONF" 2>/dev/null; then
    echo "clp"
  else
    echo "none"
  fi
}

# clp_warn_cf_only_whitelist <domain> [skip-realip]：vhost 同時有 cf-only 的 include 與 satisfy any
#   （clp httpauth 或 CloudPanel Basic Auth 的 IP 白名單）時警告，不改設定：
#   經 Cloudflare 時 $remote_addr 是 Cloudflare 節點，白名單比對不到（一律要密碼）；
#   直連主機的人只要密碼正確或 IP 在白名單內，就能繞過 cf-only（satisfy any 的 allow／deny 與 cf-only 的清單合在一起判斷）
#   skip-realip：呼叫端之後才處理 set_real_ip_from 0.0.0.0/0（cf-only），不顯示 real-ip 的補充警告
clp_warn_cf_only_whitelist() {
  local domain="$1" vhost="/etc/nginx/sites-enabled/${1}.conf"
  [[ -f "$vhost" ]] || return 0
  grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/cloudflare/ips;' "$vhost" || return 0
  grep -Eq '^[[:space:]]*satisfy[[:space:]]+any;' "$vhost" || return 0
  log_warn "$(_t "CORE_WARN_CF_ONLY_WHITELIST" "$domain" "$domain")"
  if [[ "${2:-}" != "skip-realip" && "$(clp_realip_state)" == "active" ]]; then
    log_warn "$(_t "CORE_WARN_CF_ONLY_WHITELIST_REALIP")"
  fi
  return 0
}

# clp_realip_whitelists_exist：是否有網站設定 httpauth IP 白名單（非空的 /etc/nginx/security/*.whitelist）
clp_realip_whitelists_exist() {
  local f
  for f in /etc/nginx/security/*.whitelist; do
    [[ -s "$f" ]] && return 0
  done
  return 1
}

# clp_realip_write <disable|restore> <backup_dir>：改寫 nginx.conf（先備份到 <backup_dir>、原子置換、
#   nginx -t 失敗則還原），成功後 reload
clp_realip_write() {
  local mode="$1" backup_dir="$2"
  local conf="$CLP_REALIP_NGINX_CONF"
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 1
  local bak="${backup_dir}/nginx.conf"
  cp -p "$conf" "$bak" || return 1
  local tmp
  tmp=$(mktemp "${backup_dir}/.nginx.XXXXXX") || return 1
  if [[ "$mode" == "disable" ]]; then
    # 保留原縮排，在行首加 # 並附上標記
    awk -v mark="$CLP_REALIP_MARK" '
      /^[[:space:]]*set_real_ip_from[[:space:]]+0\.0\.0\.0\/0[[:space:]]*;/ {
        match($0, /^[[:space:]]*/)
        ind = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
        print ind "#" rest " " mark; next
      }
      { print }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    awk -v mark="$CLP_REALIP_MARK" '
      index($0, mark) > 0 && /^[[:space:]]*#[[:space:]]*set_real_ip_from[[:space:]]+0\.0\.0\.0\/0/ {
        line = substr($0, 1, index($0, mark) - 1)
        sub(/[[:space:]]+$/, "", line)
        sub(/#[[:space:]]*/, "", line)
        print line; next
      }
      { print }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if ! atomic_replace "$tmp" "$conf"; then
    rm -f "$tmp"
    log_error "$(_t "SITE_CF_ONLY_REALIP_ERR_WRITE" "$conf")"
    return 1
  fi
  rm -f "$tmp"
  if ! nginx -t >/dev/null 2>&1; then
    atomic_replace "$bak" "$conf" || log_error "$(_t "SITE_CF_ONLY_ERR_RESTORE" "$bak" "$conf")"
    log_error "$(_t "SITE_CF_ONLY_REALIP_ERR_TEST" "$conf")"
    return 1
  fi
  systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
}

# cf_credentials_match_score <ini 檔名(不含 .ini)> <domain>
#   評估 Cloudflare 憑證檔名與網域的對應程度（數字越大越精確，0 = 不符合）：
#   - 檔名等於網域或其上層網域（example.com.ini 對應 shop.example.com）：1000 + 長度
#   - 檔名等於網域的主要名稱（example.ini 對應 *.example.com 與 example.co.uk）：1
#   主機名稱的第一段（shop.example.net 的 shop）不列入，避免 shop.ini 誤配到其他網域
cf_credentials_match_score() {
  local name="$1" domain="$2"
  if [[ "$domain" == "$name" || "$domain" == *".${name}" ]]; then
    echo $((1000 + ${#name}))
    return 0
  fi
  local -a labels=()
  IFS='.' read -ra labels <<< "$domain"
  local n=${#labels[@]}
  local brand_idx=$((n - 2))
  # 二級網域後綴 (com.tw、co.uk、idv.tw ...) 時，主要名稱再往前一段
  if [[ $n -ge 3 && "${labels[n-2]}" =~ ^(com|net|org|edu|gov|co|ac|or|ne|go|idv|ltd|plc|me)$ && ${#labels[n-1]} -eq 2 ]]; then
    brand_idx=$((n - 3))
  fi
  if [[ $brand_idx -ge 0 && "${labels[brand_idx]}" == "$name" ]]; then
    echo 1
    return 0
  fi
  echo 0
}

# Print curl config lines (for `curl -K <(curl_header_config ...)`) so that secret headers such as
# API tokens are passed through a file descriptor instead of the process argument list (ps, /proc/*/cmdline).
curl_header_config() {
  local h
  for h in "$@"; do
    h="${h//\\/\\\\}"
    h="${h//\"/\\\"}"
    printf 'header = "%s"\n' "$h"
  done
}

backup_file() {
  local target="$1"
  if [[ -f "$target" ]]; then
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local backup_path="${target}.bak_${timestamp}"
    cp "$target" "$backup_path"
    log_info "$(_t "CORE_INFO_BACKUP_CREATED" "$backup_path")"
  fi
}

# atomic_replace <source_temp_file> <target_file>
#   以原子化方式置換目標檔案，避免先截斷再寫入導致異常中斷留下空檔：
#   1. 在目標檔同一目錄用 mktemp 建立暫存檔，確保與目標處於同一檔案系統（Same Filesystem），
#      保證後續 mv 為原子性 rename(2) 操作。
#   2. 將來源暫存檔內容複製至該暫存檔。
#   3. 若目標檔已存在，繼承其權限與擁有者（GNU chmod/chown --reference，或 macOS stat 退避）。
#   4. 執行 mv -f 置換。
atomic_replace() {
  local src="$1" target="$2"
  local target_dir
  target_dir="$(dirname "$target")"

  if [[ ! -f "$src" ]]; then
    log_error "$(_t "CORE_ERR_ATOMIC_SRC_MISSING" "$src")"
    return 1
  fi

  local dir_uid
  dir_uid=$(stat -c "%u" "$target_dir" 2>/dev/null || stat -f "%u" "$target_dir" 2>/dev/null || echo "999")
  if [[ "$dir_uid" -ne 0 ]]; then
    log_error "$(_t "CORE_ERR_ATOMIC_DIR_NOT_ROOT" "$target_dir" "$dir_uid")"
    return 1
  fi

  local tmp
  tmp=$(mktemp "${target_dir}/.atomic.XXXXXX") || return 1

  if ! cat "$src" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  local ref_file=""
  if [[ -e "$target" ]]; then
    ref_file="$target"
  elif [[ -e "$src" ]]; then
    ref_file="$src"
  fi

  if [[ -n "$ref_file" ]]; then
    if chmod --reference="$ref_file" "$tmp" 2>/dev/null; then
      chown --reference="$ref_file" "$tmp" 2>/dev/null || true
    else
      local mode owner
      mode=$(stat -f "%Lp" "$ref_file" 2>/dev/null || true)
      [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null || true
      owner=$(stat -f "%u:%g" "$ref_file" 2>/dev/null || true)
      [[ -n "$owner" ]] && chown "$owner" "$tmp" 2>/dev/null || true
    fi
  fi

  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# remove_marked_block <file> <start_tag> <end_tag>
#   安全移除檔案中的成對標記區塊：
#   1. 比對開始與結束標記數量，必須相等且大於 0。
#   2. 使用 awk 逐行處理，若 END 時仍處於區塊內（表示標記順序顛倒或缺失），立即 exit 1。
#   3. 執行成功才透過 atomic_replace 置換，失敗時絕不修改原檔。
remove_marked_block() {
  local target="$1" start_tag="$2" end_tag="$3"
  [[ ! -f "$target" ]] && return 0

  local sc ec
  sc=$(grep -cF -- "$start_tag" "$target" 2>/dev/null || true)
  ec=$(grep -cF -- "$end_tag" "$target" 2>/dev/null || true)
  if [[ "$sc" -ne "$ec" ]]; then
    log_error "$(_t "CORE_ERR_MARKED_BLOCK_COUNT" "$target" "$start_tag" "$sc" "$end_tag" "$ec")"
    return 1
  fi
  [[ "$sc" -eq 0 ]] && return 0

  local tmp_out
  tmp_out=$(mktemp "$(dirname "$target")/.rmblock.XXXXXX") || return 1
  if ! awk -v s="$start_tag" -v e="$end_tag" '
    !in_block && ($0 == s || index($0, s)) { in_block=1; next }
    in_block && ($0 == e || index($0, e)) { in_block=0; next }
    !in_block { print }
    END { if (in_block) exit 1 }
  ' "$target" > "$tmp_out"; then
    log_error "$(_t "CORE_ERR_MARKED_BLOCK_PARSE" "$target")"
    rm -f "$tmp_out"
    return 1
  fi

  if ! atomic_replace "$tmp_out" "$target"; then
    rm -f "$tmp_out"
    return 1
  fi
  rm -f "$tmp_out"
  return 0
}

# 全域非互動免確認開關 (由 -y / --yes 觸發)
CLP_AUTO_YES=false

# clp_auto_yes：使用者是否已事先同意（-y / -yes / -non-interactive / CLP_AUTO_YES）
clp_auto_yes() {
  [[ "${CLP_AUTO_YES:-false}" == "true" ]] || has_opt "y" || has_opt "yes" || \
    has_opt "non_interactive" || has_opt "non-interactive"
}

# require_tty_or_yes：沒有終端機又沒有 -y 時報錯並回傳 1（AGENTS.md 第 8 節：不可讓 read 讀到 EOF 後靜默中止，
#   也不可在沒有確認的情況下套用預設值）。會詢問確認的指令在任何修改之前呼叫。
require_tty_or_yes() {
  clp_auto_yes && return 0
  [[ -t 0 ]] && return 0
  log_error "$(_t "CORE_ERR_NEED_TTY_OR_Y")"
  return 1
}

prompt_confirm() {
  local prompt_msg="$1"
  local default_ans="${2:-y}" # y or n

  # 若明確指定 -y / --yes / -non-interactive 或啟用 CLP_AUTO_YES，一律視為同意 (return 0)
  if clp_auto_yes; then
    return 0
  fi

  # 非終端環境（且未指定 -y）一律視為否；需要執行的指令應先呼叫 require_tty_or_yes 明確報錯
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local yn_display="[Y/n]"
  [[ "$default_ans" == "n" ]] && yn_display="[y/N]"

  local ans
  while true; do
    # 讀到 EOF（Ctrl-D）視為取消，不套用預設值
    if ! read -r -p "$(echo -e "${C_YELLOW}? ${prompt_msg} ${yn_display}: ${C_NC}")" ans; then
      echo ""
      return 1
    fi
    ans="${ans:-$default_ans}"
    case "$ans" in
      [Yy]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "$(_t "CORE_PROMPT_INVALID_CHOICE")" ;;
    esac
  done
}

check_cloudpanel() {
  if ! command -v clpctl >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_CLOUDPANEL_NOT_FOUND")"
    exit 1
  fi
}

check_wpcli() {
  if command -v wp >/dev/null 2>&1; then
    return 0
  fi

  log_warn "$(_t "CORE_WARN_WPCLI_NOT_FOUND")"
  if [[ ! -t 0 ]]; then
    log_warn "$(_t "CORE_WARN_NON_INTERACTIVE_WPCLI")"
    return 1
  fi

  read -p "$(_t "CORE_PROMPT_INSTALL_WPCLI")" install_wp
  if [[ "$install_wp" =~ ^[Yy]$ ]]; then
    log_info "$(_t "CORE_INFO_DOWNLOADING_WPCLI")"
    local wpcli_tmp
    wpcli_tmp=$(mktemp /tmp/wp-cli.XXXXXX)
    # -f：HTTP 錯誤時失敗（不把錯誤頁面當成 wp-cli 安裝）；並確認下載的是可執行的 phar
    if curl -fsSL --connect-timeout 15 --max-time 300 -o "$wpcli_tmp" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
       && php "$wpcli_tmp" --info --allow-root >/dev/null 2>&1; then
      # mktemp 建立的檔案是 600：改成 755，網站使用者（sudo -u）才能執行
      chmod 755 "$wpcli_tmp"
      mv "$wpcli_tmp" /usr/local/bin/wp
      log_success "$(_t "CORE_SUCCESS_WPCLI_INSTALLED" "$(/usr/local/bin/wp --version --allow-root 2>/dev/null || _t "CORE_TXT_INSTALLED")")"
      return 0
    else
      rm -f "$wpcli_tmp"
      log_error "$(_t "CORE_ERR_WPCLI_DOWNLOAD_FAILED")"
      return 1
    fi
  else
    log_warn "$(_t "CORE_WARN_SKIP_WPCLI")"
    return 1
  fi
}

check_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    return 0
  fi

  log_warn "$(_t "CORE_WARN_RCLONE_NOT_FOUND")"
  if [[ ! -t 0 ]]; then
    log_warn "$(_t "CORE_WARN_NON_INTERACTIVE_RCLONE")"
    return 1
  fi

  read -p "$(_t "CORE_PROMPT_INSTALL_RCLONE")" install_rc
  if [[ "$install_rc" =~ ^[Yy]$ ]]; then
    log_info "$(_t "CORE_INFO_INSTALLING_RCLONE")"
    # 下載失敗時往下由 command -v 判斷並顯示錯誤（不讓 set -e 直接中止）
    curl -fsSL --connect-timeout 15 --max-time 120 https://rclone.org/install.sh | bash || true
    if command -v rclone >/dev/null 2>&1; then
      log_success "$(_t "CORE_SUCCESS_RCLONE_INSTALLED")"
      return 0
    else
      log_error "$(_t "CORE_ERR_RCLONE_FAILED")"
      return 1
    fi
  else
    log_warn "$(_t "CORE_WARN_SKIP_RCLONE")"
    return 1
  fi
}

check_certbot() {
  if command -v certbot >/dev/null 2>&1 && certbot plugins 2>/dev/null | grep -q "dns-cloudflare"; then
    return 0
  fi

  log_step "$(_t "CORE_STEP_INSTALLING_CERTBOT")"

  export DEBIAN_FRONTEND=noninteractive
  log_info "$(_t "CORE_INFO_APT_UPDATE")"
  apt-get -o DPkg::Lock::Timeout=60 update -y || true

  log_info "$(_t "CORE_INFO_INSTALL_PYTHON_DEPS")"
  apt-get -o DPkg::Lock::Timeout=60 install -y python3 python3-dev python3-venv libaugeas-dev gcc || {
    log_error "$(_t "CORE_ERR_DEPS_FAILED")"
    return 1
  }

  log_info "$(_t "CORE_INFO_REMOVE_OLD_CERTBOT")"
  apt-get -o DPkg::Lock::Timeout=60 remove -y certbot 2>/dev/null || true

  log_info "$(_t "CORE_INFO_VENV_CREATE")"
  mkdir -p /opt
  python3 -I -m venv /opt/certbot/ || {
    log_error "$(_t "CORE_ERR_VENV_FAILED")"
    return 1
  }

  log_info "$(_t "CORE_INFO_PIP_UPGRADE")"
  /opt/certbot/bin/pip install --upgrade pip || true

  log_info "$(_t "CORE_INFO_PIP_INSTALL_CERTBOT")"
  if ! /opt/certbot/bin/pip install certbot certbot-nginx; then
    log_error "$(_t "CORE_ERR_CERTBOT_FAILED")"
    return 1
  fi

  log_info "$(_t "CORE_INFO_SYMLINK_CERTBOT")"
  ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

  log_info "$(_t "CORE_INFO_PIP_INSTALL_CF")"
  if ! /opt/certbot/bin/pip install certbot-dns-cloudflare; then
    log_error "$(_t "CORE_ERR_CERTBOT_FAILED")"
    return 1
  fi

  # 確認 certbot 與 dns-cloudflare 外掛都可用
  if command -v certbot >/dev/null 2>&1 && certbot plugins 2>/dev/null | grep -q "dns-cloudflare"; then
    local cb_ver
    cb_ver=$(certbot --version 2>/dev/null || _t "CORE_TXT_READY")
    log_success "$(_t "CORE_SUCCESS_CERTBOT_INSTALLED" "$cb_ver")"
    return 0
  else
    log_error "$(_t "CORE_ERR_CERTBOT_FAILED")"
    return 1
  fi
}

ensure_certbot_renew_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    log_warn "$(_t "CORE_WARN_CRONTAB_NOT_FOUND")"
    return 0
  fi

  local existing_cron
  existing_cron=$(crontab -l 2>/dev/null || true)

  local cb_path="/usr/bin/certbot"
  if [[ ! -x "$cb_path" ]]; then
    cb_path=$(command -v certbot 2>/dev/null || echo "certbot")
  fi

  local cron_job="0 3 * * 0 ${cb_path} renew --quiet --deploy-hook \"systemctl reload nginx\""

  # 1. 已有生效中的 certbot renew 排程（不論時間與參數）就不改寫，保留使用者自訂的時間與 hook
  if printf '%s\n' "$existing_cron" | grep -v '^[[:space:]]*#' | grep -qE "certbot.*renew"; then
    log_info "$(_t "CORE_INFO_CRON_ALREADY_SET")"
    return 0
  fi

  # 2. 沒有任何 certbot renew 排程時，新增每週日排程；失敗只警告（呼叫端此時憑證已簽發完成）
  log_step "$(_t "CORE_STEP_CRON_ADDING")"
  local cron_rc=0
  if [[ -n "$existing_cron" ]]; then
    printf "%s\n%s\n" "$existing_cron" "$cron_job" | crontab - || cron_rc=$?
  else
    printf "%s\n" "$cron_job" | crontab - || cron_rc=$?
  fi
  if [[ "$cron_rc" -ne 0 ]]; then
    log_warn "$(_t "CORE_WARN_CRON_ADD_FAILED" "$cron_job")"
    return 0
  fi

  log_success "$(_t "CORE_SUCCESS_CRON_ADDED" "$cron_job")"
}

get_server_ip() {
  local ip=""
  # 1. 嘗試由外部公網 IP 服務快速探測 (逾時 2 秒)
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -s4 --max-time 2 https://api.ipify.org 2>/dev/null || curl -s4 --max-time 2 https://icanhazip.com 2>/dev/null || curl -s4 --max-time 2 https://ifconfig.me 2>/dev/null || true)
    ip=$(echo "$ip" | tr -d '[:space:]')
  fi

  # 2. 備援：透過系統路由或預設網路介面取得
  if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if command -v ip >/dev/null 2>&1; then
      ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
    fi
  fi

  if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if command -v hostname >/dev/null 2>&1; then
      ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
  fi

  echo "$ip"
}

get_server_hostname() {
  local host=""

  # 0. 命令列參數 -cname= 優先
  if command -v opt_get >/dev/null 2>&1; then
    local opt_cname
    opt_cname=$(opt_get "cname" "")
    if [[ -n "$opt_cname" && "$opt_cname" != "true" ]]; then
      echo "$opt_cname"
      return 0
    fi
  fi

  # 1. 檢查 CloudPanel 內部資料庫 (db.sq3) 之 custom_domain 設定
  if [[ -f "/home/clp/htdocs/app/data/db.sq3" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local db_cname
    db_cname=$(sqlite3 -readonly /home/clp/htdocs/app/data/db.sq3 'SELECT value FROM config WHERE key="custom_domain";' 2>/dev/null || true)
    db_cname=$(echo "$db_cname" | tr -d '[:space:]')
    if [[ -n "$db_cname" && "$db_cname" =~ \. && ! "$db_cname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$db_cname"
      return 0
    fi
  fi

  # 2. 檢查 CloudPanel Nginx 自訂控制台網域設定檔 (custom-domain.conf / cloudpanel.conf)
  for conf in /etc/nginx/sites-enabled/custom-domain.conf \
              /etc/nginx/sites-available/custom-domain.conf \
              /etc/nginx/sites-enabled/cloudpanel.conf \
              /etc/nginx/sites-available/cloudpanel.conf; do
    if [[ -f "$conf" ]]; then
      local s_name
      s_name=$(grep -E '^[[:space:]]*server_name[[:space:]]+' "$conf" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d ';' || true)
      if [[ -n "$s_name" && "$s_name" != "_" && "$s_name" =~ \. && ! "$s_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        host="$s_name"
        break
      fi
    fi
  done

  # 3. 掃描反向代理至 8443 控制台的 Nginx 設定檔
  if [[ -z "$host" && -d "/etc/nginx/sites-enabled" ]]; then
    for conf in /etc/nginx/sites-enabled/*.conf; do
      [[ ! -f "$conf" ]] && continue
      if grep -qE 'proxy_pass[[:space:]]+https?://[^:]+:8443' "$conf" 2>/dev/null; then
        local s_name
        s_name=$(grep -E '^[[:space:]]*server_name[[:space:]]+' "$conf" 2>/dev/null | head -n1 | awk '{print $2}' | tr -d ';' || true)
        if [[ -n "$s_name" && "$s_name" != "_" && "$s_name" =~ \. && ! "$s_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          host="$s_name"
          break
        fi
      fi
    done
  fi

  # 4. 檢查系統 FQDN (hostname -f)
  if [[ -z "$host" ]] && command -v hostname >/dev/null 2>&1; then
    local fqdn
    fqdn=$(hostname -f 2>/dev/null || true)
    if [[ -n "$fqdn" && "$fqdn" =~ \. && ! "$fqdn" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && ! "$fqdn" =~ \.local$ ]]; then
      host="$fqdn"
    fi
  fi

  # 5. 檢查 /etc/hostname
  if [[ -z "$host" && -f /etc/hostname ]]; then
    local h_file
    h_file=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$h_file" && "$h_file" =~ \. && ! "$h_file" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && ! "$h_file" =~ \.local$ ]]; then
      host="$h_file"
    fi
  fi

  echo "$host"
}

# ------------------------------------------------------------------------------
# 4. Domain & String Utilities
# ------------------------------------------------------------------------------
clean_domain() {
  local dom="$1"
  # Strip quotes, backslashes, semicolons, trim spaces, lowercase, remove trailing slash and http/https scheme if typed
  dom=$(echo "$dom" | sed -E "s/['\"\\\\;]//g; s~^https?://~~; s~/$~~; s~^[[:space:]]+|[[:space:]]+$~~g" | tr '[:upper:]' '[:lower:]')
  echo "$dom"
}

# strip_ctrl_chars <字串>：移除終端機控制字元（C0、DEL、UTF-8 編碼的 C1），供顯示來自遠端主機或網站使用者的字串
#   只用於顯示；不可用來「修正」之後還要拿去使用的值（會變成另一個名稱）
strip_ctrl_chars() {
  local LC_ALL=C s="$1"
  s="${s//[$'\x01'-$'\x1f'$'\x7f']/}"
  s="${s//$'\xc2'[$'\x80'-$'\x9f']/}"
  printf '%s' "$s"
}

is_valid_domain() {
  local dom
  dom=$(clean_domain "$1")
  if [[ -z "$dom" ]]; then
    return 1
  fi
  # Standard domain regex
  # 頂級網域允許純英文字母，或 punycode 國際化頂級網域（例如 .台灣 = xn--kpry57d）
  if [[ "$dom" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+([a-zA-Z]{2,}|[xX][nN]--[a-zA-Z0-9-]{1,59})$ ]]; then
    return 0
  fi
  return 1
}

# domain_matches_exclude <domain> <pattern>
#   判斷網域是否符合排除規則：
#   1. 含萬用字元 (* 或 ?)：Glob 通配比對
#   2. 以點結尾 (如 test.、dev.、staging.、www.)：前綴比對
#   3. 不含點的關鍵字 (如 staging、shop)：子字串比對 (舊版相容)
#   4. 其他 (如 a.com、test.org)：完整網域、www 前綴或子網域邊界比對
domain_matches_exclude() {
  local dom="$1" pat="$2"
  pat=$(echo "$pat" | tr -d '[:space:]')
  [[ -z "$pat" || -z "$dom" ]] && return 1

  local no_www="${pat#www.}"

  # 1. 含萬用字元 (* 或 ?)，走 Glob 比對
  if [[ "$pat" == *"*"* || "$pat" == *"?"* ]]; then
    if [[ "$dom" == $pat || ( -n "$no_www" && "$dom" == $no_www ) ]]; then
      return 0
    fi
    return 1
  fi

  # 2. 以點結尾 (如 test.、dev.、staging.、www.)：前綴比對
  if [[ "$pat" == *.* && "${pat: -1}" == "." ]]; then
    if [[ "$dom" == "$pat"* || "$dom" == "www.$pat"* ]]; then
      return 0
    fi
    return 1
  fi

  # 3. 不含點的關鍵字 (如 staging、shop)：維持舊版子字串相容
  if [[ "$pat" != *"."* ]]; then
    if [[ "$dom" == *"$pat"* ]]; then
      return 0
    fi
    return 1
  fi

  # 4. 其他（一般網域，如 a.com、test.org）：完整網域、www 前綴或子網域邊界比對
  if [[ "$dom" == "$pat" || "$dom" == "www.$pat" || "$dom" == *".$pat" ]]; then
    return 0
  fi
  if [[ -n "$no_www" && "$no_www" != "$pat" && ( "$dom" == "$no_www" || "$dom" == "www.$no_www" || "$dom" == *".$no_www" ) ]]; then
    return 0
  fi

  return 1
}


domain_to_dbname() {
  local dom
  dom=$(clean_domain "$1")
  local dbname
  # CloudPanel 規定資料庫與使用者名稱格式：/^[a-z][-a-z0-9]+$/iu
  # 僅允許英數字與減號 (-)，不允許底線 (_) 或其他特殊符號
  dbname=$(echo "$dom" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/--*-/-/g' | sed 's/^-//; s/-$//' | tr '[:upper:]' '[:lower:]')
  # 確保首字為小寫字母 (CloudPanel 限制: ^[a-z])
  if [[ ! "$dbname" =~ ^[a-z] ]]; then
    dbname="db-${dbname}"
  fi
  # CloudPanel 資料庫使用者名稱長度上限為 32 字元
  if [[ ${#dbname} -gt 32 ]]; then
    local prefix="${dbname:0:25}"
    prefix="${prefix%-}"
    local suffix
    suffix=$(openssl rand -hex 3)
    dbname="${prefix}-${suffix}"
  fi
  echo "$dbname"
}

suggest_site_user() {
  local dom
  dom=$(clean_domain "$1")
  local base_user
  # CloudPanel siteUser 規定格式：/^[a-z][-a-z0-9_]+$/iu, 長度 3~32 字元, 且不可存在於 /etc/passwd
  base_user=$(echo "$dom" | cut -d'.' -f1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
  # 確保首字為字母
  if [[ ! "$base_user" =~ ^[a-z] ]]; then
    base_user="u${base_user}"
  fi
  # 確保長度至少 3 字元
  while [[ ${#base_user} -lt 3 ]]; do
    base_user="${base_user}site"
  done
  # 截斷保留後綴編號空間 (最多 28 字元)
  base_user="${base_user:0:28}"

  local candidate="$base_user"
  local counter=1
  while id -u "$candidate" >/dev/null 2>&1; do
    candidate="${base_user}${counter}"
    counter=$((counter + 1))
  done
  echo "$candidate"
}

# ------------------------------------------------------------------------------
# 5. Unified Parameter Parser
# ------------------------------------------------------------------------------
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
  declare -A OPTS=()
fi
POSITIONAL=()

parse_arguments() {
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    OPTS=()
  fi
  POSITIONAL=()

  # Clear previously defined opt_* dynamic variables
  local _prev_opt
  for _prev_opt in $(compgen -v opt_ 2>/dev/null || true); do
    unset -v "$_prev_opt"
  done

  while [[ $# -gt 0 ]]; do
    local arg="$1"
    if [[ "$arg" =~ ^--?([a-zA-Z0-9_-]+)[=:](.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      local key_norm
      key_norm="${key//-/_}"

      # Set dynamic variables
      printf -v "opt_${key_norm}" '%s' "$val" 2>/dev/null || eval "opt_${key_norm}=\$val"

      # Also store in associative array if supported
      if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        OPTS["$key"]="$val"
        OPTS["$key_norm"]="$val"
      fi
      shift
    elif [[ "$arg" == "--lang" || "$arg" == "-lang" ]] && [[ $# -ge 2 ]]; then
      local val="$2"
      printf -v "opt_lang" '%s' "$val" 2>/dev/null || eval "opt_lang=\$val"
      if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        OPTS["lang"]="$val"
      fi
      shift 2
    elif [[ "$arg" =~ ^--?([a-zA-Z0-9_-]+)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local key_norm
      key_norm="${key//-/_}"

      printf -v "opt_${key_norm}" '%s' "true" 2>/dev/null || eval "opt_${key_norm}=true"

      if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        OPTS["$key"]="true"
        OPTS["$key_norm"]="true"
      fi
      shift
    else
      POSITIONAL+=("$arg")
      shift
    fi
  done

  # 自動偵測 -y 或 --yes 旗標，同步啟用全域免確認
  if has_opt "y" || has_opt "yes"; then
    CLP_AUTO_YES=true
  else
    CLP_AUTO_YES=false
  fi

  # 自動偵測 --lang 旗標並同步初始化語系
  if has_opt "lang"; then
    init_i18n "$(opt_get "lang")"
  fi
}

has_opt() {
  local key="$1"
  local key_norm
  key_norm="${key//-/_}"

  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 && -n "${OPTS[$key]+isset}" ]]; then
    return 0
  fi
  local var_name="opt_${key_norm}"
  [[ -n "${!var_name:-}" ]]
}

opt_get() {
  local key="$1"
  local default_val="${2:-}"
  local key_norm
  key_norm="${key//-/_}"

  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 && -n "${OPTS[$key]+isset}" ]]; then
    echo "${OPTS[$key]}"
    return 0
  fi

  local var_name="opt_${key_norm}"
  if [[ -n "${!var_name:-}" ]]; then
    echo "${!var_name}"
  else
    echo "$default_val"
  fi
}

# ------------------------------------------------------------------------------
# 5b. Positional Argument Validation
# ------------------------------------------------------------------------------
# reject_extra_positionals <raw_args_var_name> <known_flags_regex> [used_positionals...]
#   檢查 POSITIONAL 中是否存在未被指令使用的多餘位置參數。
#   若有多餘參數：輸出錯誤並針對常見寫法提供提示，回傳 1；無多餘參數則回傳 0。
reject_extra_positionals() {
  local _raw_var="$1"
  local _known_flags="${2:-}"
  shift 2
  local -a _used_pos=("$@")

  local -a _raw_args=()
  if [[ -n "$_raw_var" ]]; then
    eval "_raw_args=(\"\${${_raw_var}[@]}\")" 2>/dev/null || true
  fi

  # 比對 POSITIONAL 與已使用的位置參數
  local -a _used_matched=()
  local i
  for ((i = 0; i < ${#_used_pos[@]}; i++)); do
    _used_matched+=(0)
  done

  local -a extra_args=()
  for pos in "${POSITIONAL[@]}"; do
    local clean_p
    clean_p=$(clean_domain "$pos")
    local matched=false
    local j=0
    for used in "${_used_pos[@]}"; do
      if [[ -n "$used" && "${_used_matched[$j]}" -eq 0 ]]; then
        local clean_u
        clean_u=$(clean_domain "$used")
        if [[ "$pos" == "$used" || "$clean_p" == "$used" || "$clean_p" == "$clean_u" ]]; then
          _used_matched[$j]=1
          matched=true
          break
        fi
      fi
      j=$((j + 1))
    done
    if [[ "$matched" == "false" ]]; then
      extra_args+=("$pos")
    fi
  done

  [[ ${#extra_args[@]} -eq 0 ]] && return 0

  log_error "$(_t "CORE_ERR_EXTRA_ARGS" "${extra_args[*]}")"
  local extra
  for extra in "${extra_args[@]}"; do
    local extra_lower
    extra_lower=$(echo "$extra" | tr '[:upper:]' '[:lower:]')
    local prev_opt=""
    local k
    for ((k = 1; k < ${#_raw_args[@]}; k++)); do
      if [[ "${_raw_args[$k]}" == "$extra" ]]; then
        local prev="${_raw_args[$((k - 1))]}"
        if [[ "$prev" =~ ^--?([a-zA-Z0-9_-]+)$ ]]; then
          prev_opt="${BASH_REMATCH[1]}"
          break
        fi
      fi
    done

    # 若緊接在需要帶值的選項後面（例如 -cf-waf off、-delete user、-file backup.sql.gz、-expire 30d、-ufw off）
    if [[ -n "$prev_opt" && "$prev_opt" =~ ^(delete|del|add|path|whitelist|list|user|username|pass|password|cf-waf|cf_waf|file|expire|to|type|ufw|allow|deny|icmp|unban|install|ssl|clone-from|clone_from|migrate|from|timezone|dns|smtp|exclude|port|max-children|idle-timeout|max-requests)$ ]]; then
      log_info "$(_t "CORE_HINT_OPT_VALUE_FORMAT" "$prev_opt" "$extra")"
    elif [[ -n "$_known_flags" && "$extra_lower" =~ ^(${_known_flags})$ ]]; then
      log_info "$(_t "CORE_HINT_DID_YOU_MEAN_OPT" "$extra_lower")"
    else
      log_info "$(_t "CORE_HINT_OPT_GENERAL_SYNTAX")"
    fi
  done
  return 1
}

# ------------------------------------------------------------------------------
# 6. CloudPanel Site Helpers
# ------------------------------------------------------------------------------
find_site_user() {
  local domain
  domain=$(clean_domain "$1")
  # 空白網域會讓 /home/*/htdocs/"" 比對到所有網站目錄，必須拒絕
  [[ -z "$domain" ]] && return 1

  # 1. Check CloudPanel SQLite db if accessible
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local user
    user=$(sqlite3 -readonly "$clp_db" "SELECT user FROM site WHERE domain_name='$domain' LIMIT 1;" 2>/dev/null || true)
    if [[ -n "$user" ]]; then
      echo "$user"
      return 0
    fi
  fi

  # 2. Check Nginx vhost config（root 擁有，優先於網站使用者可以自行建立的目錄）
  local conf_file="/etc/nginx/sites-enabled/${domain}.conf"
  [[ ! -f "$conf_file" ]] && conf_file="/etc/nginx/sites-available/${domain}.conf"
  if [[ -f "$conf_file" ]]; then
    local user
    user=$(grep -E 'root /home/[^/]+/htdocs/' "$conf_file" | head -n 1 | awk -F'/' '{print $3}' || true)
    if [[ -n "$user" ]]; then
      echo "$user"
      return 0
    fi
  fi

  # 3. Check directory ownership in /home/*/htdocs/<domain>
  #    任何網站使用者都能在自己的家目錄建立同名目錄：只接受擁有者就是該家目錄使用者的目錄
  for htdocs_dir in /home/*/htdocs/"$domain"; do
    if [[ -d "$htdocs_dir" ]]; then
      local user home_user
      home_user="${htdocs_dir#/home/}"
      home_user="${home_user%%/*}"
      user=$(stat -c '%U' "$htdocs_dir" 2>/dev/null || stat -f '%Su' "$htdocs_dir" 2>/dev/null || true)
      if [[ -n "$user" && "$user" != "root" && "$user" == "$home_user" ]]; then
        echo "$user"
        return 0
      fi
    fi
  done

  return 1
}

# find_site_root：只回傳 find_site_user 解析出的使用者底下的目錄
#   不可改用其他 /home/*/htdocs/<網域>：那可能是其他網站使用者建立的，會讓 backup／restore 以本站使用者身分執行對方的程式
find_site_root() {
  local domain
  domain=$(clean_domain "$1")
  [[ -z "$domain" ]] && return 1
  local user
  user=$(find_site_user "$domain" 2>/dev/null || true)
  if [[ -n "$user" && -d "/home/$user/htdocs/$domain" ]]; then
    echo "/home/$user/htdocs/$domain"
    return 0
  fi
  return 1
}

find_site_php_version() {
  local domain
  domain=$(clean_domain "$1")

  # 1. Try CloudPanel SQLite db
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local ver
    ver=$(sqlite3 -readonly "$clp_db" "SELECT ps.php_version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id WHERE s.domain_name='$domain' LIMIT 1;" 2>/dev/null || true)
    if [[ -z "$ver" ]]; then
      ver=$(sqlite3 -readonly "$clp_db" "SELECT ps.version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id WHERE s.domain_name='$domain' LIMIT 1;" 2>/dev/null || true)
    fi
    if [[ -n "$ver" ]]; then
      echo "$ver"
      return 0
    fi
  fi

  # 2. Check PHP pool configs in /etc/php/*/fpm/pool.d/<domain>.conf
  for conf in /etc/php/*/fpm/pool.d/"${domain}.conf"; do
    if [[ -f "$conf" ]]; then
      local ver
      ver=$(echo "$conf" | awk -F'/' '{print $4}')
      if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
      fi
    fi
  done

  # Default fallback
  get_default_php_version
}

get_installed_php_versions() {
  local vers=()
  if [[ -d "/etc/php" ]]; then
    for vdir in /etc/php/*; do
      if [[ -d "$vdir" ]]; then
        local v
        v="$(basename "$vdir")"
        if [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
          vers+=("$v")
        fi
      fi
    done
  fi

  if [[ ${#vers[@]} -gt 0 ]]; then
    printf "%s\n" "${vers[@]}" | sort -V -r
  else
    echo "8.5"
    echo "8.4"
    echo "8.3"
    echo "8.2"
    echo "8.1"
  fi
}

get_default_php_version() {
  get_installed_php_versions | head -n1
}

normalize_wp_locale() {
  local l="${1:-}"
  local clean_l
  clean_l="$(echo "$l" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  case "$clean_l" in
    tw|zh-tw|zh_tw|zhtw)
      echo "zh_TW"
      ;;
    cn|zh-cn|zh_cn|zhcn)
      echo "zh_CN"
      ;;
    en|us|en-us|en_us|enus|"")
      echo "en_US"
      ;;
    ja|jp|ja-jp|ja_jp)
      echo "ja"
      ;;
    ko|kr|ko-kr|ko_kr)
      echo "ko_KR"
      ;;
    de|de-de|de_de)
      echo "de_DE"
      ;;
    fr|fr-fr|fr_fr)
      echo "fr_FR"
      ;;
    es|es-es|es_es)
      echo "es_ES"
      ;;
    it|it-it|it_it)
      echo "it_IT"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

find_nginx_vhost() {
  local domain
  domain=$(clean_domain "$1")

  # 1. 優先查 sites-enabled (網站啟用中)
  local enabled="/etc/nginx/sites-enabled/${domain}.conf"
  if [[ -f "$enabled" ]]; then
    echo "$enabled"
    return 0
  fi

  # 2. 查 sites-available (網站已停用)
  local available="/etc/nginx/sites-available/${domain}.conf"
  if [[ -f "$available" ]]; then
    echo "$available"
    return 0
  fi

  # 3. 搜尋 conf.d 或其他可能位置
  for f in /etc/nginx/conf.d/"${domain}.conf" \
            /etc/nginx/sites-enabled/"${domain}" \
            /etc/nginx/sites-available/"${domain}"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done

  return 1
}

# ------------------------------------------------------------------------------
# 6b. Site Existence & Typo Detection Helpers
# ------------------------------------------------------------------------------
get_all_site_domains() {
  local domains=()
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && domains+=("$line")
    done < <(sqlite3 -readonly "$clp_db" "SELECT domain_name FROM site;" 2>/dev/null || true)
  fi

  if [[ ${#domains[@]} -eq 0 ]]; then
    for f in /etc/nginx/sites-enabled/*.conf /etc/nginx/sites-available/*.conf; do
      if [[ -f "$f" ]]; then
        local b
        b=$(basename "$f" .conf)
        [[ "$b" != "*" && "$b" != "default" && "$b" != "catch-all" ]] && domains+=("$b")
      fi
    done
  fi

  printf '%s\n' "${domains[@]}" 2>/dev/null | sort -u
}

suggest_similar_domain() {
  local target="$1"
  shift
  local candidates=("$@")
  [[ ${#candidates[@]} -eq 0 ]] && return 0

  python3 -I - "$target" "${candidates[@]}" << "PYEOF" 2>/dev/null || true
import sys, difflib
target = sys.argv[1]
candidates = sys.argv[2:]
matches = difflib.get_close_matches(target, candidates, n=1, cutoff=0.5)
if matches:
    print(matches[0])
PYEOF
}

site_exists() {
  local domain
  domain=$(clean_domain "$1")
  [[ -z "$domain" ]] && return 1

  # 1. 檢查 Nginx 設定檔 (sites-enabled 或 sites-available 或 conf.d)
  if find_nginx_vhost "$domain" >/dev/null 2>&1; then
    return 0
  fi

  # 2. 檢查 CloudPanel SQLite DB
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local count
    count=$(sqlite3 -readonly "$clp_db" "SELECT count(*) FROM site WHERE domain_name='$domain';" 2>/dev/null || echo 0)
    if [[ "$count" -gt 0 ]]; then
      return 0
    fi
  fi

  # 3. 檢查實體根目錄
  if find_site_root "$domain" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

require_site_exists() {
  local domain
  domain=$(clean_domain "$1")
  local action_desc="${2:-}"

  if [[ -z "$domain" ]]; then
    log_error "$(_t "CORE_ERR_DOMAIN_REQUIRED")"
    return 1
  fi

  if ! site_exists "$domain"; then
    if [[ -n "$action_desc" ]]; then
      log_error "$(_t "CORE_ERR_SITE_NOT_FOUND_ACTION" "$domain" "$action_desc")"
    else
      log_error "$(_t "CORE_ERR_SITE_NOT_FOUND" "$domain")"
    fi

    local -a all_domains=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && all_domains+=("$line")
    done < <(get_all_site_domains)

    if [[ ${#all_domains[@]} -gt 0 ]]; then
      local suggestion
      suggestion=$(suggest_similar_domain "$domain" "${all_domains[@]}")
      if [[ -n "$suggestion" ]]; then
        echo -e "${C_YELLOW}${C_BOLD}$(_t "CORE_SUGGEST_DID_YOU_MEAN" "$suggestion")${C_NC}"
      fi
    fi

    log_info "$(_t "CORE_INFO_SITE_LIST_HINT")"
    return 1
  fi

  return 0
}

run_wp() {
  local domain="$1"
  shift
  local site_root
  site_root=$(find_site_root "$domain" 2>/dev/null || true)
  local site_user
  site_user=$(find_site_user "$domain" 2>/dev/null || true)

  if [[ -z "$site_root" || ! -d "$site_root" ]]; then
    log_error "$(_t "CORE_ERR_SITE_ROOT_NOT_FOUND" "$domain")"
    return 1
  fi

  # 不以 root 執行 WP-CLI（會以 root 身分載入網站的 PHP 程式）
  if [[ -z "$site_user" || "$site_user" == "root" ]]; then
    log_error "$(_t "CORE_ERR_WP_SITE_USER" "$domain")"
    return 1
  fi
  sudo -H -u "$site_user" wp --path="$site_root" "$@"
}

# Initialize log file on load
init_logging
