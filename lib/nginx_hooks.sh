#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - nginx hooks（計畫 51）
# File: lib/nginx_hooks.sh
#
# 在 CloudPanel 網站的 vhost 範本（site.vhost_template）與渲染後的 vhost 中加入 clp 的 include：
#   檔案最上面（http 層）：include /etc/nginx/clp-helper/sites/<domain>/http/*.conf;
#   HTTPS server 的 root 之後：include /etc/nginx/clp-helper/*.conf;
#                              include /etc/nginx/clp-helper/sites/<domain>/*.conf;
# 範本中有 include，CloudPanel 重新產生 vhost（例如後台 Vhost 分頁儲存）時就會保留，
# 功能的設定（例如 httpauth）放在 include 的檔案中，不會被移除。
#
# - 寫入範本：clp 使用者以 CloudPanel 自己的程式（clp_regen.php set-template），不相容時直接寫資料庫；
#   root 只以唯讀方式讀取 db.sq3（與 `clp site -vhost` 相同的機制，函式在 site.sh）
# - 渲染後的 vhost：直接插入 hook 行（atomic_replace），不呼叫 CloudPanel 重新產生，
#   以免順便套用其他設定的變更（例如 Varnish 前端）
# - 加入時，vhost 中舊格式的 httpauth 區塊在同一次寫入中移除，改寫成 hook 檔
# ==============================================================================

NH_DIR="/etc/nginx/clp-helper"
NH_ENABLED_FILE="${NH_DIR}/.enabled"
NH_DB="/home/clp/htdocs/app/data/db.sq3"
NH_NEED_RELOAD=0
NH_PREV_TRAPS=""

# 需要 site.sh 的 vhost_* 函式（範本匯出、備份、寫入、還原）
_nh_require_site_lib() {
  declare -F vhost_stage_init >/dev/null && return 0
  # shellcheck source=/dev/null
  source "${CLP_LIB_DIR}/site.sh"
}

_nh_require_httpauth_lib() {
  declare -F httpauth_get_htpasswd_file >/dev/null && return 0
  # shellcheck source=/dev/null
  source "${CLP_LIB_DIR}/httpauth.sh"
}

nh_enabled() {
  [[ -f "$NH_ENABLED_FILE" ]]
}

nh_site_dir() {
  echo "${NH_DIR}/sites/$1"
}

# nh_site_features <domain>：hook 目錄中的設定檔（每行一個，例如 httpauth.conf、http/httpauth.conf）
nh_site_features() {
  local dir f
  dir="$(nh_site_dir "$1")"
  for f in "$dir"/*.conf "$dir"/http/*.conf; do
    [[ -f "$f" ]] && echo "${f#"${dir}/"}"
  done
  return 0
}

# nh_state_of <php|other> <template state> <vhost state> <domain>：網站的 hook 狀態
#   on | template-only | vhost-only | missing | off | skip | disabled
nh_state_of() {
  local kind="$1" t="$2" v="$3" domain="$4"
  if [[ "$kind" != "php" ]]; then
    echo "skip"
  elif [[ "$v" == "disabled" ]]; then
    echo "disabled"
  elif [[ "$t" == "on" && "$v" == "on" ]]; then
    echo "on"
  elif [[ "$t" == "on" ]]; then
    echo "template-only"
  elif [[ "$v" == "on" ]]; then
    echo "vhost-only"
  elif [[ -f "$(nh_site_dir "$domain")/.hooked" ]]; then
    echo "missing"
  else
    echo "off"
  fi
}

# nh_report [<domain>]：每個網站一行「<domain>\t<狀態>」（不需要暫存目錄；資料庫唯讀）
nh_report() {
  local domain="${1:-}" d kind t v
  local -a extra=()
  [[ -n "$domain" ]] && extra=(--domain "$domain")
  [[ -f "$NH_DB" ]] || return 1
  local out
  out="$(python3 -I "${CLP_LIB_DIR}/vhost_tpl.py" export --db "$NH_DB" \
          | python3 -I "${CLP_LIB_DIR}/vhost_tpl.py" hooks-report --vhost-dir /etc/nginx/sites-enabled ${extra[@]+"${extra[@]}"})" || return 1
  [[ -n "$out" ]] || return 0
  while IFS=$'\t' read -r d kind t v; do
    [[ -n "$d" ]] || continue
    printf '%s\t%s\n' "$d" "$(nh_state_of "$kind" "$t" "$v" "$d")"
  done <<< "$out"
}

# nh_site_state <domain>：單一網站的 hook 狀態（查不到時輸出 unknown）
nh_site_state() {
  local line
  line="$(nh_report "$1" 2>/dev/null)" || { echo "unknown"; return 0; }
  echo "${line#*$'\t'}"
}

# nh_state_label <state>
nh_state_label() {
  case "$1" in
    on) _t "NH_ST_ON" ;;
    template-only) _t "NH_ST_TEMPLATE_ONLY" ;;
    vhost-only) _t "NH_ST_VHOST_ONLY" ;;
    missing) _t "NH_ST_MISSING" ;;
    off) _t "NH_ST_OFF" ;;
    disabled) _t "NH_ST_DISABLED" ;;
    skip) _t "NH_ST_SKIP" ;;
    *) _t "NH_ST_UNKNOWN" ;;
  esac
}

# _nh_install <src> <target>：root 擁有的 hook 目錄中以原子方式寫入（644）
_nh_install() {
  chmod 644 "$1" && atomic_replace "$1" "$2" && chmod 644 "$2"
}

# _nh_mkdirs <domain>：建立 hook 目錄（root:root 755）
_nh_mkdirs() {
  local dir
  dir="$(nh_site_dir "$1")"
  ( umask 022; mkdir -p "${dir}/http" ) || return 1
  chown root:root "$NH_DIR" "${NH_DIR}/sites" "$dir" "${dir}/http" 2>/dev/null || true
  chmod 755 "$NH_DIR" "${NH_DIR}/sites" "$dir" "${dir}/http"
}

# _nh_rmdirs <domain>：hook 目錄已沒有設定檔時移除
_nh_rmdirs() {
  local dir
  dir="$(nh_site_dir "$1")"
  rmdir "${dir}/http" 2>/dev/null || true
  rmdir "$dir" 2>/dev/null || true
}

# nh_add_site <domain>：在網站的範本與 vhost 加入 hook（呼叫端已執行 vhost_stage_init 與 vhost_export）
#   回傳 0 已加入或原本就有、1 失敗（已還原）、3 跳過
#   成功時設定 NH_NEED_RELOAD=1，由呼叫端統一 reload
nh_add_site() {
  local domain="$1"
  local vhost="/etc/nginx/sites-enabled/${domain}.conf"
  local line kind t v state
  line="$(vhost_tpl_py hooks-report --vhost-dir /etc/nginx/sites-enabled --domain "$domain" < "${VHOST_STAGE}/export.json")" || {
    log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$VHOST_DB")"; return 1; }
  IFS=$'\t' read -r _ kind t v <<< "$line"
  state="$(nh_state_of "$kind" "$t" "$v" "$domain")"
  case "$state" in
    on) log_info "$(_t "NH_INFO_ALREADY" "$domain")"; return 0 ;;
    skip) log_warn "$(_t "NH_WARN_SKIP_NOT_PHP" "$domain")"; return 3 ;;
    disabled) log_warn "$(_t "NH_WARN_SKIP_DISABLED" "$domain")"; return 3 ;;
  esac

  # 舊格式的 httpauth 區塊：狀態一定要完整讀出，否則遷移後防護會少掉
  local legacy="${VHOST_STAGE}/legacy.state" markers=0
  ( umask 077; vhost_httpauth_state "$vhost" > "$legacy" ) || return 1
  markers=$(grep -c '# --- CLP HTTPAUTH \(ROOT\|WPADMIN\|PATH: .*\) START ---' "$vhost" || true)
  if [[ "$(grep -c . "$legacy" || true)" -ne "${markers:-0}" ]]; then
    log_error "$(_t "NH_ERR_LEGACY_STATE" "$domain")"
    return 1
  fi

  # 新的範本與 vhost
  local new_tpl="${VHOST_STAGE}/hooks.tpl" new_vhost="${VHOST_STAGE}/hooks.vhost" src="$vhost" rc=0
  if [[ "$t" != "on" ]]; then
    ( umask 077; vhost_tpl_py hooks-add --domain "$domain" < "${VHOST_STAGE}/export.json" > "$new_tpl" ) || rc=$?
    if [[ "$rc" -eq 3 ]]; then
      log_warn "$(_t "NH_WARN_NO_PLACE" "$domain")"; return 3
    elif [[ "$rc" -ne 0 ]]; then
      log_error "$(_t "NH_ERR_BUILD" "$domain")"; return 1
    fi
  fi
  if [[ -s "$legacy" ]]; then
    _nh_require_httpauth_lib || return 1
    src="${VHOST_STAGE}/stripped.vhost"
    if ! ( umask 077; python3 -I "${CLP_LIB_DIR}/httpauth_vhost.py" strip-legacy "$vhost" "$(httpauth_get_siteuser "$domain")" > "$src" ); then
      log_error "$(_t "NH_ERR_LEGACY_STATE" "$domain")"; return 1
    fi
  fi
  rc=0
  ( umask 077; vhost_tpl_py hooks-add --domain "$domain" --file "$src" > "$new_vhost" ) || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    log_warn "$(_t "NH_WARN_NO_PLACE" "$domain")"; return 3
  elif [[ "$rc" -ne 0 ]]; then
    log_error "$(_t "NH_ERR_BUILD" "$domain")"; return 1
  fi

  # 舊格式的防護先寫成 hook 檔（vhost 還沒有 include，不會生效）
  local ha_dir="${VHOST_STAGE}/ha"
  if [[ -s "$legacy" ]]; then
    rm -rf "$ha_dir"
    ( umask 022; mkdir -p "$ha_dir" ) || return 1
    if ! httpauth_hook_render "$domain" "$ha_dir" < "$legacy"; then
      log_error "$(_t "NH_ERR_LEGACY_STATE" "$domain")"; return 1
    fi
  fi

  # 備份
  local bdir
  bdir="${VHOST_BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)/${domain}"
  if ! vhost_backup "$domain" "$bdir"; then
    log_error "$(_t "SITE_VHOST_ERR_BACKUP" "$bdir")"
    return 1
  fi
  log_info "$(_t "SITE_VHOST_INFO_BACKUP" "$bdir")"

  # 寫入範本
  if [[ "$t" != "on" ]]; then
    vhost_write_template "$domain" "$new_tpl" "$bdir" || return 1
  fi
  VHOST_PENDING="${domain}|${bdir}"

  # hook 檔與 vhost
  local dir created=""
  dir="$(nh_site_dir "$domain")"
  if ! _nh_mkdirs "$domain"; then
    log_error "$(_t "NH_ERR_WRITE" "$dir")"
    vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
    VHOST_PENDING=""
    return 1
  fi
  if [[ -s "$legacy" ]]; then
    _nh_install "${ha_dir}/server.conf" "${dir}/httpauth.conf" && created="${dir}/httpauth.conf" || rc=1
    if [[ "$rc" -eq 0 && -f "${ha_dir}/http.conf" ]]; then
      _nh_install "${ha_dir}/http.conf" "${dir}/http/httpauth.conf" && created="${created} ${dir}/http/httpauth.conf" || rc=1
    fi
  fi
  if [[ "$rc" -eq 0 && "$v" != "on" ]]; then
    atomic_replace "$new_vhost" "$vhost" || rc=1
  fi
  if [[ "$rc" -ne 0 ]] || ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "NH_ERR_NGINX" "$domain")"
    # shellcheck disable=SC2086
    [[ -n "$created" ]] && rm -f $created
    vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
    _nh_rmdirs "$domain"
    VHOST_PENDING=""
    return 1
  fi
  date '+%Y-%m-%d %H:%M:%S' > "${dir}/.hooked"
  chmod 644 "${dir}/.hooked"
  VHOST_PENDING=""
  NH_NEED_RELOAD=1
  [[ -s "$legacy" ]] && log_info "$(_t "NH_INFO_MIGRATED" "$domain")"
  [[ "$VHOST_WRITER" == "sqlite" && "$t" != "on" ]] && log_warn "$(_t "NH_WARN_SQLITE_WRITER" "$domain")"
  log_success "$(_t "NH_SUCCESS_ADDED" "$domain")"
  return 0
}

# nh_remove_site <domain>：移除網站的 hook 行；hook 目錄中有設定檔時拒絕（移除會讓防護失效）
#   回傳 0 已移除或原本就沒有、1 失敗或拒絕、3 跳過
nh_remove_site() {
  local domain="$1"
  local vhost="/etc/nginx/sites-enabled/${domain}.conf"
  local line kind t v state f
  local -a feats=()
  mapfile -t feats < <(nh_site_features "$domain")
  if [[ ${#feats[@]} -gt 0 ]]; then
    log_error "$(_t "NH_ERR_HAS_FEATURES" "$domain")"
    for f in "${feats[@]}"; do printf '  %s\n' "$(nh_site_dir "$domain")/${f}"; done
    [[ -f "$(nh_site_dir "$domain")/httpauth.conf" ]] && log_info "$(_t "NH_INFO_HTTPAUTH_OFF_HINT" "$domain")"
    return 1
  fi
  line="$(vhost_tpl_py hooks-report --vhost-dir /etc/nginx/sites-enabled --domain "$domain" < "${VHOST_STAGE}/export.json")" || {
    log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$VHOST_DB")"; return 1; }
  IFS=$'\t' read -r _ kind t v <<< "$line"
  state="$(nh_state_of "$kind" "$t" "$v" "$domain")"
  case "$state" in
    skip) return 3 ;;
    disabled) log_warn "$(_t "NH_WARN_SKIP_DISABLED" "$domain")"; return 3 ;;
  esac
  if [[ "$t" == "none" && "$v" == "none" ]]; then
    rm -f "$(nh_site_dir "$domain")/.hooked"
    _nh_rmdirs "$domain"
    return 0
  fi

  local new_tpl="${VHOST_STAGE}/hooks.tpl" new_vhost="${VHOST_STAGE}/hooks.vhost"
  if [[ "$t" != "none" ]] && ! ( umask 077; vhost_tpl_py hooks-remove --domain "$domain" < "${VHOST_STAGE}/export.json" > "$new_tpl" ); then
    log_error "$(_t "NH_ERR_BUILD" "$domain")"; return 1
  fi
  if [[ "$v" != "none" ]] && ! ( umask 077; vhost_tpl_py hooks-remove --domain "$domain" --file "$vhost" > "$new_vhost" ); then
    log_error "$(_t "NH_ERR_BUILD" "$domain")"; return 1
  fi
  local bdir
  bdir="${VHOST_BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)/${domain}"
  if ! vhost_backup "$domain" "$bdir"; then
    log_error "$(_t "SITE_VHOST_ERR_BACKUP" "$bdir")"
    return 1
  fi
  if [[ "$t" != "none" ]]; then
    vhost_write_template "$domain" "$new_tpl" "$bdir" || return 1
  fi
  VHOST_PENDING="${domain}|${bdir}"
  local rc=0
  if [[ "$v" != "none" ]]; then
    atomic_replace "$new_vhost" "$vhost" || rc=1
  fi
  if [[ "$rc" -ne 0 ]] || ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "NH_ERR_NGINX" "$domain")"
    vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
    VHOST_PENDING=""
    return 1
  fi
  VHOST_PENDING=""
  rm -f "$(nh_site_dir "$domain")/.hooked"
  _nh_rmdirs "$domain"
  NH_NEED_RELOAD=1
  log_success "$(_t "NH_SUCCESS_REMOVED" "$domain")"
  return 0
}

# _nh_reload：批次處理後 reload 一次
_nh_reload() {
  [[ "$NH_NEED_RELOAD" -eq 1 ]] || return 0
  NH_NEED_RELOAD=0
  if ! systemctl reload nginx 2>/dev/null && ! nginx -s reload 2>/dev/null; then
    log_error "$(_t "NH_ERR_RELOAD")"
    return 1
  fi
}

# _nh_begin / _nh_end：暫存目錄、匯出與中斷時的還原（沿用 clp site -vhost 的機制）
_nh_begin() {
  _nh_require_site_lib || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"; return 1
  fi
  if [[ ! -f "$VHOST_DB" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_DB" "$VHOST_DB")"; return 1
  fi
  NH_PREV_TRAPS="$(trap -p INT TERM HUP)"
  trap vhost_on_signal INT TERM HUP
  if ! vhost_stage_init; then
    _nh_end
    log_error "$(_t "SITE_VHOST_ERR_STAGE")"; return 1
  fi
  if ! vhost_export; then
    _nh_end
    log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$VHOST_DB")"; return 1
  fi
}

# _nh_end：清除暫存目錄；建站流程中呼叫時恢復呼叫端原本的 INT／TERM／HUP trap
_nh_end() {
  vhost_stage_cleanup
  trap - INT TERM HUP
  if [[ -n "$NH_PREV_TRAPS" ]]; then
    eval "$NH_PREV_TRAPS"
  fi
  NH_PREV_TRAPS=""
}

# nh_print_status [<domain>]：狀態表與異常提示
nh_print_status() {
  local domain="${1:-}" out d st
  if nh_enabled; then
    log_info "$(_t "NH_INFO_ENABLED" "$NH_DIR")"
  else
    log_info "$(_t "NH_INFO_NOT_ENABLED")"
  fi
  out="$(nh_report "$domain")" || { log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$NH_DB")"; return 1; }
  printf "%-40s %-28s %s\n" "$(_t "SITE_VHOST_COL_DOMAIN")" "$(_t "SITE_VHOST_COL_STATUS")" "$(_t "NH_COL_FILES")"
  [[ -n "$out" ]] || return 0
  local -a bad=()
  while IFS=$'\t' read -r d st; do
    local feats
    feats="$(nh_site_features "$d" | paste -sd, - || true)"
    printf "%-40s %-28s %s\n" "$d" "$(nh_state_label "$st")" "${feats:--}"
    case "$st" in missing|template-only|vhost-only) bad+=("$d|$st|$feats") ;; esac
  done <<< "$out"
  local item
  for item in ${bad[@]+"${bad[@]}"}; do
    IFS='|' read -r d st feats <<< "$item"
    if [[ -n "$feats" && "$st" != "template-only" ]]; then
      log_error "$(_t "NH_ERR_INACTIVE" "$d")"
    else
      log_warn "$(_t "NH_WARN_STATE" "$d" "$(nh_state_label "$st")")"
    fi
    log_info "$(_t "NH_INFO_FIX_CMD" "$d")"
  done
  return 0
}

# nh_list_warnings：clp site -list 表格後的提示（只在全域啟用時）
nh_list_warnings() {
  nh_enabled || return 0
  local out d st feats
  out="$(nh_report 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  while IFS=$'\t' read -r d st; do
    case "$st" in
      missing|template-only|vhost-only)
        feats="$(nh_site_features "$d" | paste -sd, - || true)"
        if [[ -n "$feats" && "$st" != "template-only" ]]; then
          log_error "$(_t "NH_ERR_INACTIVE" "$d")"
        else
          log_warn "$(_t "NH_WARN_STATE" "$d" "$(nh_state_label "$st")")"
        fi
        log_info "$(_t "NH_INFO_FIX_CMD" "$d")"
        ;;
      off) log_info "$(_t "NH_INFO_SITE_OFF" "$d" "$d")" ;;
    esac
  done <<< "$out"
  return 0
}

# nginx_hooks_after_create <domain>：clp 建立網站（new、clone、migrate）後，已啟用時立即加入 hook；
#   失敗只警告（網站本身已建立完成）
nginx_hooks_after_create() {
  local domain="$1" rc=0
  nh_enabled || return 0
  _nh_begin || { log_warn "$(_t "NH_WARN_AFTER_CREATE" "$domain" "$domain")"; return 0; }
  nh_add_site "$domain" || rc=$?
  _nh_reload || rc=1
  _nh_end
  [[ "$rc" -eq 0 ]] || log_warn "$(_t "NH_WARN_AFTER_CREATE" "$domain" "$domain")"
  return 0
}

# nginx_hooks_site_cmd <domain> <on|off|status>
#   clp site <domain> -nginx-hooks[=on|off|status]、clp site -nginx-hooks=status
nginx_hooks_site_cmd() {
  local domain="$1" val="$2" rc=0
  case "$val" in
    status)
      nh_print_status "$domain"
      return $?
      ;;
    on|off) ;;
    *) log_error "$(_t "NH_ERR_USAGE")"; return 1 ;;
  esac
  if [[ -z "$domain" ]]; then
    log_error "$(_t "NH_ERR_USAGE")"; return 1
  fi
  if [[ "$val" == "on" ]] && ! nh_enabled; then
    log_error "$(_t "NH_ERR_NOT_ENABLED")"; return 1
  fi
  _nh_begin || return 1
  if [[ "$val" == "on" ]]; then
    nh_add_site "$domain" || rc=$?
  else
    nh_remove_site "$domain" || rc=$?
  fi
  _nh_reload || rc=1
  _nh_end
  [[ "$rc" -eq 3 ]] && rc=1
  return "$rc"
}

# nginx_hooks_server_cmd <on|off|status>：clp server -nginx-hooks=on|off|status
nginx_hooks_server_cmd() {
  local val="$1" d st rc=0
  case "$val" in
    status) nh_print_status; return $? ;;
    on|off) ;;
    *) log_error "$(_t "NH_ERR_USAGE")"; return 1 ;;
  esac
  require_tty_or_yes || return 1
  _nh_require_site_lib || return 1

  if [[ "$val" == "off" ]]; then
    # 任何網站還有 hook 設定檔（例如 httpauth 防護）就拒絕：移除 include 會讓它們在不知情下失效
    local -a busy=()
    local f
    for d in "${NH_DIR}"/sites/*/; do
      [[ -d "$d" ]] || continue
      d="$(basename "$d")"
      [[ -n "$(nh_site_features "$d")" ]] && busy+=("$d")
    done
    for f in "${NH_DIR}"/*.conf; do
      [[ -f "$f" ]] && busy+=("$f")
    done
    if [[ ${#busy[@]} -gt 0 ]]; then
      log_error "$(_t "NH_ERR_OFF_BUSY")"
      for d in "${busy[@]}"; do printf '  %s\n' "$d"; done
      return 1
    fi
    log_info "$(_t "NH_INFO_OFF_EXPLAIN")"
  else
    log_info "$(_t "NH_INFO_ON_EXPLAIN" "$NH_DIR" "$VHOST_BACKUP_BASE")"
  fi
  if ! prompt_confirm "$(_t "NH_PROMPT_${val^^}")" "n"; then
    log_info "$(_t "CORE_PROMPT_CANCELLED")"
    return 1
  fi

  _nh_begin || return 1
  if [[ "$val" == "on" ]]; then
    ( umask 022; mkdir -p "${NH_DIR}/sites" ) && chmod 755 "$NH_DIR" "${NH_DIR}/sites" \
      && date '+%Y-%m-%d %H:%M:%S' > "$NH_ENABLED_FILE" && chmod 644 "$NH_ENABLED_FILE" || {
        _nh_end; log_error "$(_t "NH_ERR_WRITE" "$NH_DIR")"; return 1; }
  fi
  local -a domains=()
  mapfile -t domains < <(vhost_tpl_py hooks-report --vhost-dir /etc/nginx/sites-enabled < "${VHOST_STAGE}/export.json" | cut -f1)
  local ok=0 skipped=0 failed=0 src
  for d in ${domains[@]+"${domains[@]}"}; do
    [[ -n "$d" ]] || continue
    src=0
    if [[ "$val" == "on" ]]; then
      nh_add_site "$d" || src=$?
    else
      nh_remove_site "$d" || src=$?
    fi
    case "$src" in
      0) ok=$((ok + 1)) ;;
      3) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
    # 每站處理後重新匯出，下一站的備份與比對使用最新的資料庫內容
    vhost_export || { failed=$((failed + 1)); break; }
  done
  _nh_reload || rc=1
  if [[ "$val" == "off" && "$failed" -eq 0 ]]; then
    rm -f "$NH_ENABLED_FILE"
    rmdir "${NH_DIR}/sites" 2>/dev/null || true
    rmdir "$NH_DIR" 2>/dev/null || true
  fi
  _nh_end
  log_info "$(_t "NH_INFO_SUMMARY" "$ok" "$skipped" "$failed")"
  [[ "$failed" -eq 0 ]] || rc=1
  return "$rc"
}
