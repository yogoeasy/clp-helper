#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# Module: httpauth (HTTP Basic Authentication & Whitelist Management)
# ==============================================================================

# Ensure core functions are loaded
if ! command -v log_info >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/core.sh" ]]; then
    source "${SCRIPT_DIR}/core.sh"
  fi
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
# Nginx vhost 編輯邏輯集中於同目錄的 httpauth_vhost.py（區塊插入、refresh、舊格式遷移）
HTTPAUTH_VHOST_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/httpauth_vhost.py"
# 計畫 51：防護寫在 nginx hook 檔（/etc/nginx/clp-helper/sites/<domain>/httpauth.conf），由 httpauth_hook.py 產生
HTTPAUTH_HOOK_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/httpauth_hook.py"
if ! declare -F nh_site_dir >/dev/null; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx_hooks.sh"
fi

httpauth_get_siteuser() {
  local domain="$1"
  local user
  user=$(find_site_user "$domain" 2>/dev/null || true)
  if [[ -z "$user" ]]; then
    user="clp"
  fi
  echo "$user"
}

httpauth_get_htpasswd_file() {
  local domain="$1"
  local user
  # 只在確實找到網站使用者時使用其家目錄；找不到時改用網域專屬檔案，
  # 避免多個網站共用 /home/clp/.htpasswd（帳密互通）
  user=$(find_site_user "$domain" 2>/dev/null || true)
  if [[ -n "$user" && -d "/home/${user}" ]]; then
    echo "/home/${user}/.htpasswd"
  else
    mkdir -p /etc/nginx/security
    echo "/etc/nginx/security/.htpasswd-${domain}"
  fi
}

httpauth_get_whitelist_file() {
  local domain="$1"
  mkdir -p /etc/nginx/security
  echo "/etc/nginx/security/${domain}.whitelist"
}

# Validate an IPv4/IPv6 address or CIDR network (e.g. 192.168.1.10, 10.0.0.0/24, 2001:db8::/32)
httpauth_validate_ip() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  python3 -I -c '
import sys, re, ipaddress
v = sys.argv[1]
# 只接受位址字元：ip_network 也接受 IPv6 scope ID（fe80::1%x;}），其中的任意字元會寫進 nginx 設定
if not re.fullmatch(r"[0-9A-Fa-f.:/]+", v):
    sys.exit(1)
# nginx allow 僅接受前綴長度 (10.0.0.0/8)，不接受 netmask/hostmask 寫法 (10.0.0.0/255.0.0.0)
if "/" in v and not v.split("/", 1)[1].isdigit():
    sys.exit(1)
try:
    ipaddress.ip_network(v, strict=False)
except ValueError:
    sys.exit(1)
' "$ip" 2>/dev/null
}

httpauth_read_whitelist_directives() {
  local domain="$1"
  local wl_file
  wl_file=$(httpauth_get_whitelist_file "$domain")
  if [[ -f "$wl_file" && -s "$wl_file" ]]; then
    # 以單次 python3 驗證整份白名單（stdout 輸出有效項目，無效項目以 "INVALID\t" 前綴標示）
    local -a valid_ips=()
    local line
    while IFS= read -r line; do
      if [[ "$line" == INVALID$'\t'* ]]; then
        log_warn "$(_t "HTTPAUTH_READ_WHITELIST_DIRECTIVES_1" "${line#INVALID$'\t'}")" >&2
      elif [[ -n "$line" ]]; then
        valid_ips+=("$line")
      fi
    done < <(python3 -I -c '
import sys, re, ipaddress
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    v = raw.strip()
    if not v or v.startswith("#"):
        continue
    ok = True
    if not re.fullmatch(r"[0-9A-Fa-f.:/]+", v):
        ok = False
    elif "/" in v and not v.split("/", 1)[1].isdigit():
        ok = False
    else:
        try:
            ipaddress.ip_network(v, strict=False)
        except ValueError:
            ok = False
    print(v if ok else "INVALID\t" + v)
' "$wl_file")
    [[ ${#valid_ips[@]} -eq 0 ]] && return 0
    printf '    satisfy any;\n'
    printf '    allow %s;\n' "${valid_ips[@]}"
    printf '    deny all;\n'
  fi
}

# 使用者名稱僅允許英數字與 . _ @ -（避免 regex、sed 分隔字元或冒號破壞 htpasswd 檔）
httpauth_validate_username() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]+$ ]]
}

# httpauth_read_htpasswd <file>：透過 clp_fileops 讀取（不跟隨 symlink、拒絕 FIFO 等非一般檔案）；
#   檔案位於網站使用者家目錄，網站使用者可以把它換成指向其他檔案的 symlink。不存在或無法讀取時輸出空字串
httpauth_read_htpasswd() {
  local file="$1"
  local cmd=(python3 -I "${CLP_LIB_DIR}/clp_fileops.py" read "$file")
  [[ "$file" =~ ^/home/([^/]+)/ ]] && cmd+=(--user "${BASH_REMATCH[1]}")
  if ! "${cmd[@]}" 2>/dev/null; then
    if [[ -e "$file" || -L "$file" ]]; then
      log_warn >&2 "$(_t "HTTPAUTH_WARN_HTPASSWD_UNREADABLE" "$file")"
    fi
  fi
  return 0
}

# httpauth_count_users <file>：計算有效的使用者行數
httpauth_count_users() {
  httpauth_read_htpasswd "$1" | awk -F':' 'NF > 1 && $1 !~ /^[[:space:]]*#/ && $1 != "" { n++ } END { print n + 0 }'
}

httpauth_user_exists() {
  local file="$1" user="$2"
  [[ -f "$file" ]] && httpauth_read_htpasswd "$file" | awk -F':' -v u="$user" '$1 == u { found = 1 } END { exit !found }'
}

httpauth_remove_user_line() {
  local file="$1" user="$2"
  local site_user=""
  if [[ "$file" =~ ^/home/([^/]+)/ ]]; then
    site_user="${BASH_REMATCH[1]}"
  fi
  local cmd=(python3 -I "${CLP_LIB_DIR}/clp_fileops.py" htpasswd-del "$file" "$user")
  [[ -n "$site_user" ]] && cmd+=(--user "$site_user")
  "${cmd[@]}"
}

# httpauth_will_write_whitelist <domain>：本次指令是否會把 IP 白名單（satisfy any + allow）寫進 vhost
#   -whitelist 的新增／取代，或網站已有白名單時開啟 -wp-admin、-path 防護
httpauth_will_write_whitelist() {
  local domain="$1" v
  if has_opt "whitelist"; then
    v=$(opt_get "whitelist" "")
    if ! has_opt "delete-all" && ! has_opt "delete_all" && ! has_opt "delete" && ! has_opt "del" && \
       ! has_opt "remove" && ! has_opt "off" && [[ -n "$v" && "$v" != "true" && "$v" != "off" && "$v" != "clear" && "$v" != "none" ]]; then
      return 0
    fi
  fi
  # 以下判斷與 httpauth_handler 的 -wp-admin、-path 分支一致
  httpauth_has_whitelist "$domain" || return 1
  if has_opt "wp_admin" || has_opt "wp-admin"; then
    v=$(opt_get "wp_admin" "$(opt_get "wp-admin" "on")")
    if ! has_opt "off" && [[ "$v" != "off" ]]; then
      return 0
    fi
  fi
  if has_opt "path" && ! has_opt "delete-all" && ! has_opt "delete_all"; then
    v=$(opt_get "path" "")
    if [[ -n "$v" && "$v" != "true" ]] && ! has_opt "off" && ! has_opt "delete" && ! has_opt "del" && ! has_opt "remove"; then
      return 0
    fi
  fi
  return 1
}

# httpauth_realip_disable：白名單生效後呼叫；set_real_ip_from 0.0.0.0/0 仍生效時說明並詢問（預設 yes），
#   -y 直接處理；讀到 EOF 或回答否時只警告。nginx.conf 備份到 /root/.clp/httpauth-backup/<時間>/
httpauth_realip_disable() {
  [[ "$(clp_realip_state)" == "active" ]] || return 0
  local conf="$CLP_REALIP_NGINX_CONF"
  log_warn "$(_t "HTTPAUTH_REALIP_EXPLAIN" "$conf")"
  if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
    local ans=""
    if ! read -r -p "$(_t "SITE_CF_ONLY_REALIP_PROMPT")" ans; then
      ans="n"
    fi
    if [[ -n "$ans" && "$ans" != "y" && "$ans" != "Y" && "$ans" != "yes" ]]; then
      log_warn "$(_t "HTTPAUTH_REALIP_WARN_KEPT" "$conf")"
      return 0
    fi
  fi
  local backup_dir
  backup_dir="/root/.clp/httpauth-backup/$(date +%Y%m%d_%H%M%S)"
  if ( umask 077; mkdir -p "$backup_dir" ) && clp_realip_write disable "$backup_dir"; then
    log_success "$(_t "SITE_CF_ONLY_REALIP_DONE" "$conf" "${backup_dir}/nginx.conf")"
  else
    log_warn "$(_t "HTTPAUTH_REALIP_WARN_KEPT" "$conf")"
  fi
  return 0
}

# _httpauth_nginx_active_workers <master_pid>：仍在接受新連線的 worker PID（不含 reload 後正在結束的舊 worker）
_httpauth_nginx_active_workers() {
  local master="$1" pid title
  for pid in $(pgrep -P "$master" 2>/dev/null || true); do
    title=$(tr '\0' ' ' 2>/dev/null < "/proc/${pid}/cmdline") || continue
    if [[ "$title" == *"worker process"* && "$title" != *"shutting down"* ]]; then
      echo "$pid"
    fi
  done
}

# httpauth_reload_nginx：套用設定；reload 失敗時報錯（vhost 已更新但尚未生效），不可顯示成功
#   reload 只是送信號給 nginx 主行程，新設定要等新的 worker 啟動、舊的 worker 進入結束狀態才生效
#   （實測約 2 秒）：等到舊 worker 都不再接受新連線才回傳，最多 15 秒；逾時表示 nginx 沒有載入新設定
httpauth_reload_nginx() {
  local master="" old="" pid title i pending
  master=$(cat /run/nginx.pid 2>/dev/null || true)
  if [[ "$master" =~ ^[0-9]+$ && -d "/proc/${master}" ]]; then
    old=$(_httpauth_nginx_active_workers "$master")
  fi
  if ! systemctl reload nginx 2>/dev/null && ! nginx -s reload 2>/dev/null; then
    log_error "$(_t "HTTPAUTH_ERR_RELOAD")"
    return 1
  fi
  # 找不到主行程或 worker 時無法判斷，沿用原本的行為
  [[ -n "$old" ]] || return 0
  for ((i = 0; i < 75; i++)); do
    pending=0
    for pid in $old; do
      title=$(tr '\0' ' ' 2>/dev/null < "/proc/${pid}/cmdline") || continue
      if [[ -n "$title" && "$title" != *"shutting down"* ]]; then
        pending=1
        break
      fi
    done
    [[ "$pending" -eq 0 ]] && return 0
    sleep 0.2
  done
  log_error "$(_t "HTTPAUTH_ERR_RELOAD")"
  return 1
}

httpauth_has_whitelist() {
  local domain="$1"
  local wl_file
  wl_file=$(httpauth_get_whitelist_file "$domain")
  [[ -f "$wl_file" && -s "$wl_file" ]]
}

# _httpauth_fileops_user_args <target_file> [fallback_owner]
#   建立 clp_fileops 權限參數（--user / --owner）。
#   若路徑位於 /home/<user>/ 則帶入 --user <user> --owner <user>；
#   若非 /home/ 且指定了 fallback_owner 則帶入 --owner <fallback_owner>。
#   設定全域陣列 HTTPAUTH_USER_ARGS，並輸出至 stdout（每行一參數）。
_httpauth_fileops_user_args() {
  local target_file="${1:-}"
  local fallback_owner="${2:-}"
  HTTPAUTH_USER_ARGS=()
  if [[ "$target_file" =~ ^/home/([^/]+)/ ]]; then
    local home_user="${BASH_REMATCH[1]}"
    HTTPAUTH_USER_ARGS=(--user "$home_user" --owner "$home_user")
  elif [[ -n "$fallback_owner" ]]; then
    HTTPAUTH_USER_ARGS=(--owner "$fallback_owner")
  fi
  if [[ ${#HTTPAUTH_USER_ARGS[@]} -gt 0 ]]; then
    printf '%s\n' "${HTTPAUTH_USER_ARGS[@]}"
  fi
}

# ------------------------------------------------------------------------------
# nginx hook 檔（計畫 51）
#   開啟防護需要網站已加入 nginx hook（clp server -nginx-hooks=on、clp site <domain> -nginx-hooks）；
#   vhost 中舊格式的區塊（httpauth_vhost.py）只保留關閉、列出與白名單／帳號變更時的 refresh
# ------------------------------------------------------------------------------
httpauth_hook_file() {
  echo "$(nh_site_dir "$1")/httpauth.conf"
}

# httpauth_protect_state <domain>：目前的防護，每行一項：wpadmin、path <路徑>
#   有 hook 檔時以它為準，沒有時讀 vhost 中舊格式的區塊
httpauth_protect_state() {
  local domain="$1" f vhost
  f=$(httpauth_hook_file "$domain")
  if [[ -f "$f" ]]; then
    python3 -I "$HTTPAUTH_HOOK_PY" state "$f"
    return 0
  fi
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  [[ -n "$vhost" && -f "$vhost" ]] || return 0
  grep -q '# --- CLP HTTPAUTH WPADMIN START ---' "$vhost" && echo "wpadmin"
  grep -q '# --- CLP HTTPAUTH ROOT START ---' "$vhost" && echo "path /"
  sed -n 's/^[[:space:]]*# --- CLP HTTPAUTH PATH: \(.*\) START ---[[:space:]]*$/path \1/p' "$vhost"
  return 0
}

# httpauth_hook_render <domain> <dir>（stdin：防護清單）：產生 <dir>/server.conf 與（有白名單時）<dir>/http.conf
httpauth_hook_render() {
  local domain="$1" dir="$2" out="" line rc=0
  out=$(python3 -I "$HTTPAUTH_HOOK_PY" render --domain "$domain" \
          --htpasswd "$(httpauth_get_htpasswd_file "$domain")" \
          --whitelist "$(httpauth_get_whitelist_file "$domain")" --out "$dir") || rc=$?
  while IFS= read -r line; do
    if [[ "$line" == INVALID$'\t'* ]]; then
      log_warn >&2 "$(_t "HTTPAUTH_READ_WHITELIST_DIRECTIVES_1" "${line#INVALID$'\t'}")"
    fi
  done <<< "$out"
  return "$rc"
}

# httpauth_hook_ready <domain>：網站的範本與 vhost 都已加入 hook（開啟防護的前提）；
#   否則報錯並提示要執行的指令。HTTPAUTH_LEGACY_OK=1（vhost 更新後重新套用舊格式防護）時回傳 2
httpauth_hook_ready() {
  local domain="$1" state
  state=$(nh_site_state "$domain")
  [[ "$state" == "on" ]] && return 0
  [[ "${HTTPAUTH_LEGACY_OK:-0}" == "1" ]] && return 2
  if ! nh_enabled; then
    log_error "$(_t "HTTPAUTH_ERR_HOOKS_NOT_ENABLED")"
  else
    log_error "$(_t "HTTPAUTH_ERR_HOOKS_SITE" "$domain" "$(nh_state_label "$state")" "$domain")"
  fi
  return 1
}

# httpauth_cp_basic_auth_check <domain>：CloudPanel 內建的 Basic Auth 也啟用時拒絕（server 層會有兩個 auth_basic）
httpauth_cp_basic_auth_check() {
  local domain="$1"
  [[ -f "$NH_DB" ]] || return 0
  if [[ "$(python3 -I "$HTTPAUTH_HOOK_PY" basic-auth --db "$NH_DB" --domain "$domain" 2>/dev/null || echo 0)" == "1" ]]; then
    log_error "$(_t "HTTPAUTH_ERR_CP_BASIC_AUTH" "$domain")"
    return 1
  fi
  return 0
}

# httpauth_hook_apply <domain> <wpadmin-on|wpadmin-off|path-on|path-off|clear-paths|refresh> [<path>]
#   依新的防護清單重新產生 hook 檔，nginx -t 失敗時還原；回傳 0 成功、1 失敗（已還原）、2 已寫入但 reload 失敗
httpauth_hook_apply() {
  local domain="$1" op="$2" arg="${3:-}"
  local dir file http_file cur new tmpd rc=0
  dir=$(nh_site_dir "$domain")
  file="${dir}/httpauth.conf"
  http_file="${dir}/http/httpauth.conf"
  cur=$(python3 -I "$HTTPAUTH_HOOK_PY" state "$file") || return 1
  case "$op" in
    wpadmin-on) new=$(printf '%s\nwpadmin\n' "$cur") ;;
    wpadmin-off) new=$(grep -vx 'wpadmin' <<< "$cur" || true) ;;
    path-on) new=$(printf '%s\npath %s\n' "$cur" "$arg") ;;
    path-off) new=$(grep -vxF "path ${arg}" <<< "$cur" || true) ;;
    clear-paths) new=$(grep -vE '^path /.+' <<< "$cur" || true) ;;  # 全站（path /）不在 -delete-all 的範圍
    refresh) new="$cur" ;;
    *) return 1 ;;
  esac
  new=$(sed '/^[[:space:]]*$/d' <<< "$new" | sort -u)

  tmpd=$(mktemp -d) || return 1
  chmod 755 "$tmpd"
  if [[ -n "$new" ]] && ! httpauth_hook_render "$domain" "$tmpd" <<< "$new"; then
    rm -rf "$tmpd"
    log_error "$(_t "HTTPAUTH_ERR_HOOK_RENDER" "$domain")"
    return 1
  fi
  [[ -f "$file" ]] && cp -p "$file" "${tmpd}/old.server"
  [[ -f "$http_file" ]] && cp -p "$http_file" "${tmpd}/old.http"

  if ! _nh_mkdirs "$domain"; then
    rm -rf "$tmpd"
    log_error "$(_t "NH_ERR_WRITE" "$dir")"
    return 1
  fi
  if [[ -n "$new" ]]; then
    _nh_install "${tmpd}/server.conf" "$file" || rc=1
    if [[ "$rc" -eq 0 && -f "${tmpd}/http.conf" ]]; then
      _nh_install "${tmpd}/http.conf" "$http_file" || rc=1
    elif [[ "$rc" -eq 0 ]]; then
      rm -f "$http_file"
    fi
  else
    rm -f "$file" "$http_file"
  fi
  if [[ "$rc" -ne 0 ]] || ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
    if [[ -f "${tmpd}/old.server" ]]; then cp -p "${tmpd}/old.server" "$file"; else rm -f "$file"; fi
    if [[ -f "${tmpd}/old.http" ]]; then cp -p "${tmpd}/old.http" "$http_file"; else rm -f "$http_file"; fi
    rm -rf "$tmpd"
    return 1
  fi
  rm -rf "$tmpd"
  if [[ "$(nh_site_state "$domain")" != "on" && -f "$file" ]]; then
    log_warn "$(_t "HTTPAUTH_WARN_HOOK_INACTIVE" "$domain")"
  fi
  httpauth_reload_nginx || return 2
  return 0
}

# ------------------------------------------------------------------------------
# 1. Add User (Interactive or Inline)
# ------------------------------------------------------------------------------
httpauth_add_user() {
  local domain="$1"
  local username="${2:-}"
  local password="${3:-}"

  local user_dir
  user_dir=$(httpauth_get_siteuser "$domain")
  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")

  # If not provided, prompt interactively
  if [[ -z "$username" ]]; then
    echo -e "$(_t "HTTPAUTH_ADD_USER_1" "${C_CYAN}" "${C_BOLD}" "${domain}" "${C_NC}")"
    if ! read -r -p "$(_t "HTTPAUTH_ADD_USER_2")" username; then
      echo ""
      log_info "$(_t "CORE_PROMPT_CANCELLED")"
      return 1
    fi
    username=$(echo "$username" | tr -d '[:space:]')
  fi

  if [[ -z "$username" ]]; then
    log_error "$(_t "HTTPAUTH_ADD_USER_3")"
    return 1
  fi
  if ! httpauth_validate_username "$username"; then
    log_error "$(_t "HTTPAUTH_ADD_USER_4" "${username}")"
    return 1
  fi

  if [[ -z "$password" ]]; then
    if ! IFS= read -r -s -p "$(_t "HTTPAUTH_ADD_USER_5")" password; then
      echo ""
      log_info "$(_t "CORE_PROMPT_CANCELLED")"
      return 1
    fi
    echo ""
    if [[ -z "$password" ]]; then
      log_error "$(_t "HTTPAUTH_ADD_USER_6")"
      return 1
    fi
    local password_confirm=""
    if ! IFS= read -r -s -p "$(_t "HTTPAUTH_ADD_USER_7")" password_confirm; then
      echo ""
      log_info "$(_t "CORE_PROMPT_CANCELLED")"
      return 1
    fi
    echo ""
    if [[ "$password" != "$password_confirm" ]]; then
      log_error "$(_t "HTTPAUTH_ADD_USER_8")"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$htpasswd_file")"

  local is_update=0
  if httpauth_user_exists "$htpasswd_file" "$username"; then
    is_update=1
  fi

  local cmd_args=("$htpasswd_file" "$username" --mode 640)
  _httpauth_fileops_user_args "$htpasswd_file" "$user_dir" >/dev/null
  cmd_args+=("${HTTPAUTH_USER_ARGS[@]}")

  if command -v htpasswd >/dev/null 2>&1; then
    local htpasswd_out
    if ! htpasswd_out=$(printf '%s\n' "$password" | htpasswd -n -i "$username" 2>&1); then
      log_error "$(_t "HTTPAUTH_ADD_USER_9" "${htpasswd_out}")"
      return 1
    fi
    if ! printf '%s\n' "$htpasswd_out" | python3 -I "${CLP_LIB_DIR}/clp_fileops.py" htpasswd-set "${cmd_args[@]}"; then
      log_error "$(_t "HTTPAUTH_ADD_USER_9" "$(_t "HTTPAUTH_ERR_FILEOPS_FAILED")")"
      return 1
    fi
  elif command -v openssl >/dev/null 2>&1; then
    local hashed
    hashed=$(printf '%s\n' "$password" | openssl passwd -apr1 -stdin 2>/dev/null || printf '%s\n' "$password" | openssl passwd -6 -stdin 2>/dev/null || true)
    if [[ -z "$hashed" ]]; then
      log_error "$(_t "HTTPAUTH_ADD_USER_13")"
      return 1
    fi
    if ! printf '%s:%s\n' "$username" "$hashed" | python3 -I "${CLP_LIB_DIR}/clp_fileops.py" htpasswd-set "${cmd_args[@]}"; then
      log_error "$(_t "HTTPAUTH_ADD_USER_9" "$(_t "HTTPAUTH_ERR_FILEOPS_FAILED")")"
      return 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    local hashed
    hashed=$(printf '%s\n' "$password" | python3 -I -c "
import sys, hashlib, base64
pw = sys.stdin.readline().rstrip('\r\n')
try:
    import crypt
    h = crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512))
except (ImportError, AttributeError):
    h = '{SHA}' + base64.b64encode(hashlib.sha1(pw.encode('utf-8')).digest()).decode('ascii')
print(h)
" 2>/dev/null || true)
    if [[ -z "$hashed" ]]; then
      log_error "$(_t "HTTPAUTH_ADD_USER_13")"
      return 1
    fi
    if ! printf '%s:%s\n' "$username" "$hashed" | python3 -I "${CLP_LIB_DIR}/clp_fileops.py" htpasswd-set "${cmd_args[@]}"; then
      log_error "$(_t "HTTPAUTH_ADD_USER_9" "$(_t "HTTPAUTH_ERR_FILEOPS_FAILED")")"
      return 1
    fi
  else
    log_error "$(_t "HTTPAUTH_ADD_USER_10")"
    return 1
  fi

  if [[ "$is_update" -eq 1 ]]; then
    log_success "$(_t "HTTPAUTH_ADD_USER_11" "${username}" "${htpasswd_file}")"
  else
    log_success "$(_t "HTTPAUTH_ADD_USER_12" "${username}" "${htpasswd_file}")"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# 2. Delete User
# ------------------------------------------------------------------------------
httpauth_del_user() {
  local domain="$1"
  local username="${2:-}"
  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")

  if [[ ! -f "$htpasswd_file" ]]; then
    log_warn "$(_t "HTTPAUTH_DEL_USER_1" "${htpasswd_file}")"
    return 0
  fi

  if [[ -z "$username" ]]; then
    # 沒有終端機時無法詢問：明確報錯（用 -delete=<使用者>）；讀到 EOF（Ctrl-D）視為取消
    if [[ ! -t 0 ]]; then
      log_error "$(_t "HTTPAUTH_ERR_DEL_NEEDS_USER")"
      return 1
    fi
    echo -e "$(_t "HTTPAUTH_DEL_USER_2" "${C_CYAN}" "${C_BOLD}" "${domain}" "${C_NC}")"
    if ! read -r -p "$(_t "HTTPAUTH_DEL_USER_3")" username; then
      echo ""
      log_info "$(_t "CORE_PROMPT_CANCELLED")"
      return 1
    fi
    username=$(echo "$username" | tr -d '[:space:]')
  fi

  if [[ -z "$username" ]]; then
    log_error "$(_t "HTTPAUTH_ADD_USER_3")"
    return 1
  fi

  if ! httpauth_validate_username "$username"; then
    log_error "$(_t "HTTPAUTH_ADD_USER_4" "${username}")"
    return 1
  fi

  if ! httpauth_user_exists "$htpasswd_file" "$username"; then
    log_warn "$(_t "HTTPAUTH_DEL_USER_4" "${username}" "${htpasswd_file}")"
    return 0
  fi

  # 檢查是否為最後一位使用者且網站仍有啟用中的 HTTP Auth 防護
  local user_count=0
  if [[ -f "$htpasswd_file" ]]; then
    user_count=$(httpauth_count_users "$htpasswd_file")
  fi

  if [[ "$user_count" -le 1 ]]; then
    local vhost
    vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
    local wpadmin_active=false
    local -a active_paths=()
    local kind arg

    while read -r kind arg; do
      case "$kind" in
        wpadmin) wpadmin_active=true ;;
        path) active_paths+=("$arg") ;;
      esac
    done < <(httpauth_protect_state "$domain")
    # 使用者在 CloudPanel 後台自行取消註解的 wp-admin 認證
    if [[ "$wpadmin_active" == "false" && -n "$vhost" && -f "$vhost" ]] && \
       grep -A 8 -E 'location\s*~\*?\s*[\^/]*\s*\(wp-admin/\|wp-login\.php\)' "$vhost" 2>/dev/null | grep -E -q '^[[:space:]]*auth_basic[[:space:]]+"'; then
      wpadmin_active=true
    fi

    if [[ "$wpadmin_active" == "true" || ${#active_paths[@]} -gt 0 ]]; then
      log_warn "======================================================================"
      log_warn "$(_t "HTTPAUTH_DEL_LAST_USER_WARN" "$username" "$domain")"
      if [[ "$wpadmin_active" == "true" ]]; then
        echo -e "  • wp-admin: $(_t "HTTPAUTH_DEL_LAST_USER_HINT_WPADMIN" "$domain")"
      fi
      local p
      for p in "${active_paths[@]}"; do
        echo -e "  • $(_t "HTTPAUTH_LABEL_PATH" "$p"): $(_t "HTTPAUTH_DEL_LAST_USER_HINT_PATH" "$domain" "$p")"
      done
      log_warn "======================================================================"

      if has_opt "y" || has_opt "yes"; then
        log_info "$(_t "HTTPAUTH_DEL_LAST_USER_AUTO_YES")"
      elif [[ ! -t 0 ]]; then
        log_error "$(_t "HTTPAUTH_DEL_LAST_USER_ERR_NON_TTY" "$domain")"
        return 1
      else
        local confirm=""
        read -r -p "$(_t "HTTPAUTH_DEL_LAST_USER_PROMPT")" confirm || confirm="n"
        confirm=$(echo "${confirm:-n}" | tr -d '[:space:]')
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          log_info "$(_t "HTTPAUTH_DEL_LAST_USER_CANCELLED")"
          return 0
        fi
      fi
    fi
  fi

  httpauth_remove_user_line "$htpasswd_file" "$username"

  log_success "$(_t "HTTPAUTH_DEL_USER_5" "${username}")"
  return 0
}

# ------------------------------------------------------------------------------
# 3. List Users
# ------------------------------------------------------------------------------
httpauth_list_users() {
  local domain="$1"
  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")

  echo ""
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "HTTPAUTH_LIST_USERS_1" "${C_CYAN}" "${C_BOLD}" "${domain}" "${C_NC}")"
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "HTTPAUTH_LIST_USERS_2" "${C_YELLOW}" "${htpasswd_file}" "${C_NC}")"
  echo ""

  local htpasswd_content=""
  [[ -f "$htpasswd_file" ]] && htpasswd_content=$(httpauth_read_htpasswd "$htpasswd_file")
  if [[ -z "$htpasswd_content" ]]; then
    echo -e "$(_t "HTTPAUTH_LIST_USERS_3")"
    echo -e "$(_t "HTTPAUTH_LIST_USERS_4" "${C_CYAN}" "${domain}" "${C_NC}")"
    echo ""
    return 0
  fi

  printf "%-6s %-30s\n" "#" "$(_t "HTTPAUTH_LIST_HEADER_USER")"
  echo "--------------------------------------------------"
  local idx=1
  while IFS=':' read -r u _ || [[ -n "$u" ]]; do
    [[ -z "$u" || "$u" =~ ^# ]] && continue
    printf "%-6s %-30s\n" "$idx" "$u"
    idx=$((idx + 1))
  done <<< "$htpasswd_content"
  echo "--------------------------------------------------"
  echo -e "$(_t "HTTPAUTH_LIST_USERS_5" "${C_BOLD}" "$((idx-1))" "${C_NC}")"
  echo ""
}

# ------------------------------------------------------------------------------
# 4. List Protected Paths & Whitelist
# ------------------------------------------------------------------------------
httpauth_list_protected() {
  local domain="$1"
  local vhost
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")
  local wl_file
  wl_file=$(httpauth_get_whitelist_file "$domain")

  echo ""
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_1" "${C_CYAN}" "${C_BOLD}" "${domain}" "${C_NC}")"
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"

  # 1. 密碼檔與使用者統計
  local user_count=0
  if [[ -f "$htpasswd_file" ]]; then
    user_count=$(httpauth_count_users "$htpasswd_file")
  fi
  echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_2" "${C_YELLOW}" "${htpasswd_file}" "${C_NC}" "${user_count}")"
  if httpauth_has_whitelist "$domain" && [[ "$(clp_realip_state)" == "active" ]]; then
    log_warn "$(_t "HTTPAUTH_REALIP_WARN_LIST" "$CLP_REALIP_NGINX_CONF" "$domain")"
  fi

  # 防護清單：hook 檔或 vhost 中舊格式的區塊
  local state kind arg
  state=$(httpauth_protect_state "$domain")
  if [[ -n "$state" ]]; then
    if [[ -f "$(httpauth_hook_file "$domain")" ]]; then
      if [[ "$(nh_site_state "$domain")" != "on" ]]; then
        log_error "$(_t "HTTPAUTH_WARN_HOOK_INACTIVE" "$domain")"
        log_info "$(_t "NH_INFO_FIX_CMD" "$domain")"
      fi
    else
      log_warn "$(_t "HTTPAUTH_WARN_LEGACY" "$domain" "$domain")"
    fi
  fi

  # 2. 檢查 WordPress 後台防護
  local wpadmin_status="$(_t "HTTPAUTH_LIST_PROTECTED_3")"
  if grep -qx 'wpadmin' <<< "$state"; then
    wpadmin_status="$(_t "HTTPAUTH_LIST_PROTECTED_4" "${C_GREEN}" "${C_NC}")"
  elif [[ -n "$vhost" && -f "$vhost" ]] && \
       grep -A 8 -E 'location\s*~\*?\s*[\^/]*\s*\(wp-admin/\|wp-login\.php\)' "$vhost" 2>/dev/null | grep -E -q '^[[:space:]]*auth_basic[[:space:]]+"'; then
    wpadmin_status="$(_t "HTTPAUTH_LIST_PROTECTED_4" "${C_GREEN}" "${C_NC}")"
  fi
  echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_5" "${wpadmin_status}")"

  # 3. 檢查受保護路徑
  echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_6")"
  local found_paths=0
  while read -r kind arg; do
    [[ "$kind" == "path" ]] || continue
    if [[ "$arg" == "/" ]]; then
      echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_7" "${C_GREEN}" "${C_NC}")"
    else
      echo -e "  - ${C_GREEN}${arg}${C_NC}"
    fi
    found_paths=1
  done <<< "$state"
  if [[ "$found_paths" -eq 0 ]]; then
    echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_8" "${C_DIM}" "${C_NC}")"
  fi

  # 4. 檢查 IP 白名單
  echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_9")"
  if [[ -f "$wl_file" && -s "$wl_file" ]]; then
    while IFS= read -r ip || [[ -n "$ip" ]]; do
      ip=$(echo "$ip" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [[ -z "$ip" || "$ip" =~ ^# ]] && continue
      echo -e "  - ${C_CYAN}${ip}${C_NC}"
    done < "$wl_file"
  else
    echo -e "$(_t "HTTPAUTH_LIST_PROTECTED_10" "${C_DIM}" "${C_NC}")"
  fi
  echo ""
}

# ------------------------------------------------------------------------------
# 5. Set WordPress Admin Protection (-wp-admin)
# ------------------------------------------------------------------------------
httpauth_set_wp_admin() {
  local domain="$1"
  local action="${2:-on}" # on / off

  local vhost
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  if [[ -z "$vhost" || ! -f "$vhost" ]]; then
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_1" "${domain}")"
    return 1
  fi

  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")
  local siteuser
  siteuser=$(httpauth_get_siteuser "$domain")

  if [[ "$action" == "on" ]]; then
    # 開啟防護需要網站已加入 nginx hook（計畫 51）
    local use_hook=1 hrc=0
    httpauth_hook_ready "$domain" || hrc=$?
    if [[ "$hrc" -eq 2 ]]; then
      use_hook=0
    elif [[ "$hrc" -ne 0 ]]; then
      return 1
    fi
    if [[ "$use_hook" -eq 1 ]]; then
      httpauth_cp_basic_auth_check "$domain" || return 1
    fi
    # 若尚無使用者或為 symlink，提示新增或檢查
    if [[ -L "$htpasswd_file" || ! -f "$htpasswd_file" || ! -s "$htpasswd_file" ]]; then
      if has_opt "y" || has_opt "yes" || [[ ! -t 0 ]]; then
        log_error "$(_t "HTTPAUTH_ERR_NO_USERS_ADD_FIRST" "${domain}")"
        return 1
      fi
      log_warn "$(_t "HTTPAUTH_SET_WP_ADMIN_2")"
      read -r -p "$(_t "HTTPAUTH_SET_WP_ADMIN_3")" create_u || create_u=""
      if [[ "$create_u" =~ ^[Yy]$ ]]; then
        httpauth_add_user "$domain"
      else
        log_warn "$(_t "HTTPAUTH_SET_WP_ADMIN_4")"
        if [[ -L "$htpasswd_file" || ! -e "$htpasswd_file" ]]; then
          local cmd_args=("$htpasswd_file" --allow-create --mode 640)
          _httpauth_fileops_user_args "$htpasswd_file" "$siteuser" >/dev/null
          cmd_args+=("${HTTPAUTH_USER_ARGS[@]}")
          if ! printf '' | python3 -I "${CLP_LIB_DIR}/clp_fileops.py" write "${cmd_args[@]}"; then
            log_error "$(_t "HTTPAUTH_ADD_USER_9" "$(_t "HTTPAUTH_ERR_FILEOPS_FAILED")")"
            return 1
          fi
        fi
      fi
    fi

    log_step "$(_t "HTTPAUTH_SET_WP_ADMIN_5" "${domain}")"
    if [[ "$use_hook" -eq 1 ]]; then
      httpauth_hook_apply "$domain" wpadmin-on || return 1
      log_success "$(_t "HTTPAUTH_SET_WP_ADMIN_7")"
      return 0
    fi
    local wl_directives
    wl_directives=$(httpauth_read_whitelist_directives "$domain")

    # Python 腳本更新 Nginx 設定檔中的 location ~/(wp-admin/|wp-login.php)
    cp -p "$vhost" "${vhost}.clpbak"
    if ! python3 -I "$HTTPAUTH_VHOST_PY" wpadmin-on "$vhost" "$htpasswd_file" "$wl_directives"; then
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_6")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    fi

    if nginx -t >/dev/null 2>&1; then
      rm -f "${vhost}.clpbak"
      httpauth_reload_nginx || return 1
      log_success "$(_t "HTTPAUTH_SET_WP_ADMIN_7")"
      return 0
    else
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    fi

  else
    # Turn off wp-admin protection
    log_step "$(_t "HTTPAUTH_SET_WP_ADMIN_9" "${domain}")"
    if [[ -f "$(httpauth_hook_file "$domain")" ]]; then
      httpauth_hook_apply "$domain" wpadmin-off || return 1
      log_success "$(_t "HTTPAUTH_SET_WP_ADMIN_11")"
      return 0
    fi
    cp -p "$vhost" "${vhost}.clpbak"

    python3 -I "$HTTPAUTH_VHOST_PY" wpadmin-off "$vhost" "$siteuser" || {
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_10")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    }

    if nginx -t >/dev/null 2>&1; then
      rm -f "${vhost}.clpbak"
      httpauth_reload_nginx || return 1
      log_success "$(_t "HTTPAUTH_SET_WP_ADMIN_11")"
      return 0
    else
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    fi
  fi
}

# ------------------------------------------------------------------------------
# 6. Set Path Protection (-path=<url_path>)
# ------------------------------------------------------------------------------
httpauth_set_path() {
  local domain="$1"
  local target_path="$2"
  local action="${3:-on}" # on / off

  local vhost
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  if [[ -z "$vhost" || ! -f "$vhost" ]]; then
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_1" "${domain}")"
    return 1
  fi

  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")
  local siteuser
  siteuser=$(httpauth_get_siteuser "$domain")

  # Ensure target_path starts with /
  [[ "$target_path" != /* ]] && target_path="/${target_path}"

  # Reject characters that would break or inject into the Nginx config
  if [[ "$target_path" =~ [[:space:]\\\{\}\;\#\'\"\$] ]]; then
    log_error "$(_t "HTTPAUTH_SET_PATH_1" "${target_path}")"
    return 1
  fi

  if [[ "$action" == "on" ]]; then
    # 開啟防護需要網站已加入 nginx hook（計畫 51）
    local use_hook=1 hrc=0
    httpauth_hook_ready "$domain" || hrc=$?
    if [[ "$hrc" -eq 2 ]]; then
      use_hook=0
    elif [[ "$hrc" -ne 0 ]]; then
      return 1
    fi
    if [[ "$use_hook" -eq 1 ]]; then
      httpauth_cp_basic_auth_check "$domain" || return 1
    fi
    # 若尚無使用者或為 symlink，提示新增或檢查
    if [[ -L "$htpasswd_file" || ! -f "$htpasswd_file" || ! -s "$htpasswd_file" ]]; then
      if has_opt "y" || has_opt "yes" || [[ ! -t 0 ]]; then
        log_error "$(_t "HTTPAUTH_ERR_NO_USERS_ADD_FIRST" "${domain}")"
        return 1
      fi
      log_warn "$(_t "HTTPAUTH_SET_WP_ADMIN_2")"
      read -r -p "$(_t "HTTPAUTH_SET_PATH_2")" create_u || create_u=""
      if [[ "$create_u" =~ ^[Yy]$ ]]; then
        httpauth_add_user "$domain"
      else
        log_warn "$(_t "HTTPAUTH_SET_PATH_3")"
        if [[ -L "$htpasswd_file" || ! -e "$htpasswd_file" ]]; then
          local cmd_args=("$htpasswd_file" --allow-create --mode 640)
          _httpauth_fileops_user_args "$htpasswd_file" "$siteuser" >/dev/null
          cmd_args+=("${HTTPAUTH_USER_ARGS[@]}")
          if ! printf '' | python3 -I "${CLP_LIB_DIR}/clp_fileops.py" write "${cmd_args[@]}"; then
            log_error "$(_t "HTTPAUTH_ADD_USER_9" "$(_t "HTTPAUTH_ERR_FILEOPS_FAILED")")"
            return 1
          fi
        fi
      fi
    fi

    log_step "$(_t "HTTPAUTH_SET_PATH_4" "${domain}" "${target_path}")"
    if [[ "$use_hook" -eq 1 ]]; then
      httpauth_hook_apply "$domain" path-on "$target_path" || return 1
      log_success "$(_t "HTTPAUTH_SET_PATH_6" "${target_path}")"
      return 0
    fi
    local wl_directives
    wl_directives=$(httpauth_read_whitelist_directives "$domain")

    cp -p "$vhost" "${vhost}.clpbak"

    python3 -I "$HTTPAUTH_VHOST_PY" path-on "$vhost" "$htpasswd_file" "$target_path" "$wl_directives" || {
      log_error "$(_t "HTTPAUTH_SET_PATH_5")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    }

    if nginx -t >/dev/null 2>&1; then
      rm -f "${vhost}.clpbak"
      httpauth_reload_nginx || return 1
      log_success "$(_t "HTTPAUTH_SET_PATH_6" "${target_path}")"
      return 0
    else
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    fi

  else
    # Turn off path protection
    log_step "$(_t "HTTPAUTH_SET_PATH_7" "${domain}" "${target_path}")"
    if [[ -f "$(httpauth_hook_file "$domain")" ]]; then
      httpauth_hook_apply "$domain" path-off "$target_path" || return 1
      log_success "$(_t "HTTPAUTH_SET_PATH_8" "${target_path}")"
      return 0
    fi
    cp -p "$vhost" "${vhost}.clpbak"

    python3 -I "$HTTPAUTH_VHOST_PY" path-off "$vhost" "$target_path" || {
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_10")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    }

    if nginx -t >/dev/null 2>&1; then
      rm -f "${vhost}.clpbak"
      httpauth_reload_nginx || return 1
      log_success "$(_t "HTTPAUTH_SET_PATH_8" "${target_path}")"
      return 0
    else
      log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
      mv "${vhost}.clpbak" "$vhost"
      return 1
    fi
  fi
}

# ------------------------------------------------------------------------------
# 7. Set IP Whitelist (-whitelist=<ip|subnet>)
# ------------------------------------------------------------------------------
# Apply a whitelist file change to the vhost; restore the previous whitelist file if it fails
httpauth_commit_whitelist_change() {
  local domain="$1"
  local wl_file="$2"
  local wl_bak="$3"
  local had_wl="$4"

  local refresh_rc=0
  httpauth_refresh_active_blocks "$domain" || refresh_rc=$?
  if [[ "$refresh_rc" -eq 0 ]]; then
    rm -f "$wl_bak"
    return 0
  fi
  if [[ "$refresh_rc" -eq 2 ]]; then
    # vhost 已寫入新的白名單，只是尚未 reload：保留新的白名單檔，與 vhost 一致
    rm -f "$wl_bak"
    return 1
  fi

  if [[ "$had_wl" -eq 1 ]]; then
    mv -f "$wl_bak" "$wl_file"
  else
    rm -f "$wl_file" "$wl_bak"
  fi
  log_error "$(_t "HTTPAUTH_COMMIT_WHITELIST_CHANGE_1")"
  return 1
}

httpauth_set_whitelist() {
  local domain="$1"
  local raw_val="$2" # e.g. "192.168.1.100", "192.168.1.100,10.0.0.0/24", "off", "clear"
  local mode="${3:-add}" # "add" (追加，預設), "del" (刪除特定), "set" (覆寫), "clear" (清空全部)

  local wl_file
  wl_file=$(httpauth_get_whitelist_file "$domain")

  # 備份現有白名單，以便套用失敗時還原
  local wl_bak="${wl_file}.clpbak"
  local had_wl=0

  # 1. 清空全部模式
  if [[ "$mode" == "clear" || "$raw_val" == "off" || "$raw_val" == "clear" || "$raw_val" == "none" ]]; then
    log_step "$(_t "HTTPAUTH_SET_WHITELIST_1" "${domain}")"
    if [[ -f "$wl_file" ]]; then
      cp -p "$wl_file" "$wl_bak"
      had_wl=1
    fi
    rm -f "$wl_file"
    httpauth_commit_whitelist_change "$domain" "$wl_file" "$wl_bak" "$had_wl" || return 1
    log_success "$(_t "HTTPAUTH_SET_WHITELIST_2")"
    return 0
  fi

  # 2. 讀取現有白名單
  local -a current_ips=()
  if [[ -f "$wl_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      current_ips+=("$line")
    done < "$wl_file"
  fi

  # 3. 解析輸入的 IP 清單 (支援逗號或空格分隔)
  local input_ips
  input_ips=$(echo "$raw_val" | tr ',' '\n' | tr ' ' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  # 驗證輸入格式 (del 模式不驗證，以便移除舊有的無效項目)
  if [[ "$mode" != "del" ]]; then
    local invalid_count=0
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      if ! httpauth_validate_ip "$ip"; then
        log_error "$(_t "HTTPAUTH_SET_WHITELIST_3" "${ip}")"
        invalid_count=$((invalid_count + 1))
      fi
    done <<< "$input_ips"
    if [[ "$invalid_count" -gt 0 ]]; then
      log_error "$(_t "HTTPAUTH_SET_WHITELIST_4")"
      return 1
    fi
  fi

  if [[ -f "$wl_file" ]]; then
    cp -p "$wl_file" "$wl_bak"
    had_wl=1
  fi

  # 4. 刪除指定 IP 模式 (del)
  if [[ "$mode" == "del" ]]; then
    local -a remaining_ips=()
    local removed_any=0
    while IFS= read -r target_ip; do
      [[ -z "$target_ip" ]] && continue
      local found=0
      for idx in "${!current_ips[@]}"; do
        if [[ "${current_ips[idx]}" == "$target_ip" ]]; then
          found=1
          unset 'current_ips[idx]'
          removed_any=1
          log_info "$(_t "HTTPAUTH_SET_WHITELIST_5" "${target_ip}")"
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        log_warn "$(_t "HTTPAUTH_SET_WHITELIST_6" "${target_ip}")"
      fi
    done <<< "$input_ips"

    for item in ${current_ips[@]+"${current_ips[@]}"}; do
      remaining_ips+=("$item")
    done

    if [[ ${#remaining_ips[@]} -eq 0 ]]; then
      rm -f "$wl_file"
      local wl_done_msg="$(_t "HTTPAUTH_SET_WHITELIST_7")"
    else
      mkdir -p "$(dirname "$wl_file")"
      local tmp_wl
      tmp_wl=$(mktemp "$(dirname "$wl_file")/.whitelist.tmp.XXXXXX")
      printf "%s\n" "${remaining_ips[@]}" > "$tmp_wl"
      chmod 644 "$tmp_wl"
      atomic_replace "$tmp_wl" "$wl_file"
      rm -f "$tmp_wl"
      chmod 644 "$wl_file" 2>/dev/null || true
      local wl_done_msg="$(_t "HTTPAUTH_SET_WHITELIST_8" "${wl_file}" "${#remaining_ips[@]}")"
    fi
    httpauth_commit_whitelist_change "$domain" "$wl_file" "$wl_bak" "$had_wl" || return 1
    log_success "$wl_done_msg"
    return 0
  fi

  # 5. 覆寫模式 (set / replace)
  if [[ "$mode" == "set" ]]; then
    current_ips=()
  fi

  # 6. 追加模式 (add，預設)
  local added_count=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local already_exists=0
    for existing in ${current_ips[@]+"${current_ips[@]}"}; do
      if [[ "$existing" == "$ip" ]]; then
        already_exists=1
        break
      fi
    done

    if [[ "$already_exists" -eq 1 ]]; then
      log_info "$(_t "HTTPAUTH_SET_WHITELIST_9" "${ip}")"
    else
      current_ips+=("$ip")
      added_count=$((added_count + 1))
      log_info "$(_t "HTTPAUTH_SET_WHITELIST_10" "${ip}")"
    fi
  done <<< "$input_ips"

  if [[ ${#current_ips[@]} -gt 0 ]]; then
    mkdir -p "$(dirname "$wl_file")"
    local tmp_wl
    tmp_wl=$(mktemp "$(dirname "$wl_file")/.whitelist.tmp.XXXXXX")
    printf "%s\n" "${current_ips[@]}" > "$tmp_wl"
    chmod 644 "$tmp_wl"
    atomic_replace "$tmp_wl" "$wl_file"
    rm -f "$tmp_wl"
    chmod 644 "$wl_file" 2>/dev/null || true
    local wl_done_msg="$(_t "HTTPAUTH_SET_WHITELIST_11" "${wl_file}" "${#current_ips[@]}")"
  else
    rm -f "$wl_file"
    local wl_done_msg="$(_t "HTTPAUTH_SET_WHITELIST_12")"
  fi

  httpauth_commit_whitelist_change "$domain" "$wl_file" "$wl_bak" "$had_wl" || return 1
  log_success "$wl_done_msg"
  return 0
}

# ------------------------------------------------------------------------------
# 8a. Clear All Custom Path Protections (-path -delete-all)
# ------------------------------------------------------------------------------
httpauth_clear_all_paths() {
  local domain="$1"
  local vhost
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  if [[ -z "$vhost" || ! -f "$vhost" ]]; then
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_1" "${domain}")"
    return 1
  fi

  if [[ -f "$(httpauth_hook_file "$domain")" ]]; then
    httpauth_hook_apply "$domain" clear-paths || return 1
    log_success "$(_t "HTTPAUTH_CLEAR_ALL_PATHS_1" "${domain}")"
    return 0
  fi

  cp -p "$vhost" "${vhost}.clpbak"

  python3 -I "$HTTPAUTH_VHOST_PY" clear-paths "$vhost" || {
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_10")"
    mv "${vhost}.clpbak" "$vhost"
    return 1
  }

  if nginx -t >/dev/null 2>&1; then
    rm -f "${vhost}.clpbak"
    httpauth_reload_nginx || return 1
    log_success "$(_t "HTTPAUTH_CLEAR_ALL_PATHS_1" "${domain}")"
    return 0
  else
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
    mv "${vhost}.clpbak" "$vhost"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 8. Refresh Active HTTP Auth Blocks with Current Whitelist & Htpasswd
# ------------------------------------------------------------------------------
httpauth_refresh_active_blocks() {
  local domain="$1"
  if [[ -f "$(httpauth_hook_file "$domain")" ]]; then
    local arc=0
    httpauth_hook_apply "$domain" refresh || arc=$?
    return "$arc"
  fi
  local vhost
  vhost=$(find_nginx_vhost "$domain" 2>/dev/null || true)
  if [[ -z "$vhost" || ! -f "$vhost" ]]; then
    return 0
  fi

  local htpasswd_file
  htpasswd_file=$(httpauth_get_htpasswd_file "$domain")
  local wl_directives
  wl_directives=$(httpauth_read_whitelist_directives "$domain")

  cp -p "$vhost" "${vhost}.clpbak"

  python3 -I "$HTTPAUTH_VHOST_PY" refresh "$vhost" "$htpasswd_file" "$wl_directives" || {
    log_error "$(_t "HTTPAUTH_REFRESH_ACTIVE_BLOCKS_1")"
    mv "${vhost}.clpbak" "$vhost"
    return 1
  }

  if nginx -t >/dev/null 2>&1; then
    rm -f "${vhost}.clpbak"
    # 回傳 2：vhost 已更新但 reload 失敗（呼叫端不可再還原白名單檔，否則與 vhost 不一致）
    httpauth_reload_nginx || return 2
    return 0
  else
    log_error "$(_t "HTTPAUTH_SET_WP_ADMIN_8")"
    mv "${vhost}.clpbak" "$vhost"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Dispatcher for `clp httpauth`
# ------------------------------------------------------------------------------
httpauth_handler() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"
    return 1
  fi

  local -a raw_args=("$@")
  parse_arguments "$@"

  local domain=""
  local domain_idx=-1
  local i
  for i in "${!POSITIONAL[@]}"; do
    local pos="${POSITIONAL[$i]}"
    local clean_pos
    clean_pos=$(clean_domain "$pos")
    if [[ "$clean_pos" != "httpauth" && -n "$clean_pos" ]] && is_valid_domain "$clean_pos"; then
      domain="$clean_pos"
      domain_idx=$i
      break
    fi
  done
  if [[ -z "$domain" ]]; then
    for i in "${!POSITIONAL[@]}"; do
      local pos="${POSITIONAL[$i]}"
      local clean_pos
      clean_pos=$(clean_domain "$pos")
      if [[ "$clean_pos" != "httpauth" && -n "$clean_pos" ]]; then
        domain="$clean_pos"
        domain_idx=$i
        break
      fi
    done
  fi

  if [[ -z "$domain" ]]; then
    log_error "$(_t "HTTPAUTH_HANDLER_1")"
    echo -e "$(_t "HTTPAUTH_HANDLER_2")"
    echo -e "  sudo clp httpauth example.com -add"
    echo -e "  sudo clp httpauth example.com -delete=user"
    echo -e "  sudo clp httpauth example.com -list"
    echo -e "  sudo clp httpauth example.com -list=protected"
    echo -e "  sudo clp httpauth example.com -wp-admin"
    echo -e "  sudo clp httpauth example.com -wp-admin -off"
    echo -e "  sudo clp httpauth example.com -path=/staging"
    echo -e "  sudo clp httpauth example.com -path=/staging -off"
    echo -e "  sudo clp httpauth example.com -path=/ -off"
    echo -e "  sudo clp httpauth example.com -path -delete-all"
    echo -e "  sudo clp httpauth example.com -whitelist=192.168.1.100"
    echo -e "  sudo clp httpauth example.com -whitelist=192.168.1.100 -delete"
    echo -e "  sudo clp httpauth example.com -whitelist=off"
    echo -e "  sudo clp httpauth example.com -whitelist -delete-all"
    return 1
  fi

  reject_extra_positionals raw_args "off|list|add|delete|del|wp-admin|wp_admin|path|whitelist|delete-all|delete_all|remove|set|replace|overwrite|y|yes" "$domain" "httpauth" || return 1

  require_site_exists "$domain" "$(_t "HTTPAUTH_HANDLER_3")" || return 1

  # 會寫入 IP 白名單、且 nginx.conf 的 set_real_ip_from 0.0.0.0/0 仍生效時，結束前要詢問是否註解掉；
  # 非 TTY 又沒有 -y 時在任何修改之前報錯
  local realip_fix=0
  if httpauth_will_write_whitelist "$domain" && [[ "$(clp_realip_state)" == "active" ]]; then
    if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" && ! -t 0 ]]; then
      log_error "$(_t "HTTPAUTH_REALIP_ERR_NON_TTY")"
      return 1
    fi
    realip_fix=1
  fi

  local action_performed=0 handler_rc=0 skip_rest=0

  # 1. 處理 -add：只接受互動輸入（密碼不可出現在命令列，會被 ps 看到）
  if has_opt "add"; then
    action_performed=1
    if [[ "$(opt_get "add" "")" != "true" ]] || has_opt "pass" || has_opt "password" || has_opt "user" || has_opt "username"; then
      log_error "$(_t "HTTPAUTH_ERR_ADD_NO_INLINE")"
      return 1
    fi
    if [[ ! -t 0 ]]; then
      log_error "$(_t "HTTPAUTH_ERR_ADD_NEEDS_TTY")"
      return 1
    fi
    httpauth_add_user "$domain" || handler_rc=$?
  fi

  # 2. 處理 -delete (使用者刪除，僅在非 whitelist / 非 path 刪除時觸發)
  if (has_opt "delete" || has_opt "del") && ! has_opt "whitelist" && ! has_opt "path"; then
    action_performed=1
    local del_val
    del_val=$(opt_get "delete" "$(opt_get "del" "")")
    if [[ "$del_val" == "true" || -z "$del_val" ]]; then
      del_val=$(opt_get "user" "$(opt_get "username" "")")
    fi
    httpauth_del_user "$domain" "$del_val"
  fi

  # 3. 處理 -whitelist
  if has_opt "whitelist"; then
    action_performed=1
    local wl_val
    wl_val=$(opt_get "whitelist" "")
    local wl_mode="add"

    if has_opt "delete-all" || has_opt "delete_all" || \
       [[ "$wl_val" == "off" || "$wl_val" == "clear" || "$wl_val" == "none" ]]; then
      wl_mode="clear"
      wl_val="off"
    elif has_opt "delete" || has_opt "del" || has_opt "remove"; then
      if [[ -z "$wl_val" || "$wl_val" == "true" ]]; then
        wl_mode="clear"
        wl_val="off"
      else
        wl_mode="del"
      fi
    elif has_opt "off"; then
      if [[ -z "$wl_val" || "$wl_val" == "true" ]]; then
        wl_mode="clear"
        wl_val="off"
      else
        wl_mode="del"
      fi
    elif has_opt "set" || has_opt "replace" || has_opt "overwrite"; then
      wl_mode="set"
    else
      if [[ -z "$wl_val" || "$wl_val" == "true" ]]; then
        log_warn "$(_t "HTTPAUTH_HANDLER_4")"
        return 1
      fi
      wl_mode="add"
    fi
    httpauth_set_whitelist "$domain" "$wl_val" "$wl_mode"
  fi

  # 4. 處理 -wp-admin
  if has_opt "wp_admin" || has_opt "wp-admin"; then
    action_performed=1
    local wp_val
    wp_val=$(opt_get "wp_admin" "$(opt_get "wp-admin" "on")")
    if has_opt "off" || [[ "$wp_val" == "off" ]]; then
      httpauth_set_wp_admin "$domain" "off"
    else
      httpauth_set_wp_admin "$domain" "on"
    fi
  fi

  # 5. 處理 -path
  if has_opt "path"; then
    action_performed=1
    local path_val
    path_val=$(opt_get "path" "")

    # -path -delete-all：清除所有自訂路徑保護（不需要指定路徑）
    #   不提早 return：同一指令可能已寫入白名單，結尾仍要處理 real-ip
    if has_opt "delete-all" || has_opt "delete_all"; then
      log_step "$(_t "HTTPAUTH_HANDLER_5" "${domain}")"
      httpauth_clear_all_paths "$domain" || handler_rc=$?
      skip_rest=1
    elif [[ -z "$path_val" || "$path_val" == "true" ]]; then
      log_error "$(_t "HTTPAUTH_HANDLER_6")"
      log_info "$(_t "HTTPAUTH_HANDLER_7" "${domain}")"
      handler_rc=1
      skip_rest=1
    elif has_opt "off" || has_opt "delete" || has_opt "del" || has_opt "remove"; then
      httpauth_set_path "$domain" "$path_val" "off"
    else
      httpauth_set_path "$domain" "$path_val" "on"
    fi
  fi

  # 6. 處理 -list
  if [[ "$skip_rest" -eq 0 ]] && has_opt "list"; then
    action_performed=1
    local list_val
    list_val=$(opt_get "list" "")
    if [[ "$list_val" == "protected" ]]; then
      httpauth_list_protected "$domain"
    else
      httpauth_list_users "$domain"
    fi
  fi

  if [[ "$skip_rest" -eq 0 && "$action_performed" -eq 0 ]]; then
    # 若未帶特定動作，預設列出防護狀態與使用者
    httpauth_list_protected "$domain"
    httpauth_list_users "$domain"
  fi

  if [[ "$realip_fix" -eq 1 ]] && httpauth_has_whitelist "$domain"; then
    httpauth_realip_disable
  fi

  clp_warn_cf_only_whitelist "$domain"
  return "$handler_rc"
}
