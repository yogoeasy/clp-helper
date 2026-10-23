#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# File: lib/php_fpm.sh
# Description: PHP-FPM Pool Optimization Module
# ==============================================================================

# Ensure core is loaded
if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  echo "Error: core library must be loaded first." >&2
  exit 1
fi

# pool 設定的改寫前備份：clp config 的 backup-dir 底下的 php/（由 init_php_backup_dir 設定；舊版固定為 /root/php）
PHP_BACKUP_DIR=""
# 全域關聯陣列，記錄批次調校中待重載之 PHP 版本（保留 -g 以確保在 main() 內 source 時提升為全域）
declare -gA PHP_FPM_RELOAD_VERSIONS=()

# ==============================================================================
# PHP-FPM Pool 調校參數
#   優先順序：指令參數 (-max-children= / -idle-timeout= / -max-requests=)
#             > 環境變數 (PHP_FPM_MAX_CHILDREN 等)
#             > clp.local (clp config -set php-max-children 等) > clp.conf > templates/clp.conf
#   預設值（15 / 30s / 300）寫在 templates/clp.conf，程式碼中不留數值。
# ==============================================================================
# 載入時保存環境變數覆寫值（之後每次調校前由 php_fpm_resolve_settings 重新決定實際使用的值）
PHP_FPM_ENV_MAX_CHILDREN="${PHP_FPM_MAX_CHILDREN:-}"
PHP_FPM_ENV_IDLE_TIMEOUT="${PHP_FPM_IDLE_TIMEOUT:-}"
PHP_FPM_ENV_MAX_REQUESTS="${PHP_FPM_MAX_REQUESTS:-}"
PHP_FPM_MAX_CHILDREN=""
PHP_FPM_IDLE_TIMEOUT=""
PHP_FPM_MAX_REQUESTS=""
PHP_FPM_SETTINGS_SOURCE=""

if ! command -v get_config_value >/dev/null 2>&1 && [[ -f "${CLP_ROOT_DIR}/lib/config.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/config.sh"
fi

# _php_fpm_pick <cli_value> <env_value> <config_key>：輸出 "<value>\t<source>"
# source：cli／env／config（來自使用者的 clp.local）／default（來自 clp.conf 或 templates/clp.conf）。
# 找不到任何值時回傳 1（錯誤訊息輸出到 stderr）。
_php_fpm_pick() {
  local cli="$1" env="$2" key="$3" row="" layer=""
  if [[ -n "$cli" && "$cli" != "true" ]]; then
    printf '%s\tcli\n' "$cli"; return 0
  fi
  if [[ -n "$env" ]]; then
    printf '%s\tenv\n' "$env"; return 0
  fi
  if ! row="$(clp_conf_read_src "$key")"; then
    log_error "$(_t "CONFIG_ERR_MISSING_DEFAULT" "$(display_config_key "$key")")"
    return 1
  fi
  layer="${row##*$'\t'}"
  if [[ "$layer" == "custom" ]]; then
    printf '%s\tconfig\n' "${row%%$'\t'*}"
  else
    printf '%s\tdefault\n' "${row%%$'\t'*}"
  fi
}

_php_fpm_src_label() {
  case "$1" in
    cli) _t "PHP_FPM_SRC_CLI" ;;
    env) _t "PHP_FPM_SRC_ENV" ;;
    config) _t "PHP_FPM_SRC_CONFIG" ;;
    *) _t "PHP_FPM_SRC_DEFAULT" ;;
  esac
}

# php_fpm_resolve_settings：決定 PHP_FPM_MAX_CHILDREN / IDLE_TIMEOUT / MAX_REQUESTS 與各自的來源
php_fpm_resolve_settings() {
  local line v1 s1 v2 s2 v3 s3
  line=$(_php_fpm_pick "$(opt_get "max-children" "$(opt_get "max_children" "")")" "$PHP_FPM_ENV_MAX_CHILDREN" "PHP_FPM_MAX_CHILDREN") || return 1
  IFS=$'\t' read -r v1 s1 <<< "$line"
  line=$(_php_fpm_pick "$(opt_get "idle-timeout" "$(opt_get "idle_timeout" "")")" "$PHP_FPM_ENV_IDLE_TIMEOUT" "PHP_FPM_IDLE_TIMEOUT") || return 1
  IFS=$'\t' read -r v2 s2 <<< "$line"
  line=$(_php_fpm_pick "$(opt_get "max-requests" "$(opt_get "max_requests" "")")" "$PHP_FPM_ENV_MAX_REQUESTS" "PHP_FPM_MAX_REQUESTS") || return 1
  IFS=$'\t' read -r v3 s3 <<< "$line"
  PHP_FPM_MAX_CHILDREN="$v1"
  PHP_FPM_IDLE_TIMEOUT="$v2"
  PHP_FPM_MAX_REQUESTS="$v3"
  PHP_FPM_SETTINGS_SOURCE="pm.max_children=${v1} ($(_php_fpm_src_label "$s1")), pm.process_idle_timeout=${v2} ($(_php_fpm_src_label "$s2")), pm.max_requests=${v3} ($(_php_fpm_src_label "$s3"))"
}

# php_fpm_validate_value <max_children|idle_timeout|max_requests> <value>：clp config -set 與調校前共用的檢查
# （規則定義在 config.sh 的 config_validate_value，只有一份）
php_fpm_validate_value() {
  case "$1" in
    max_children) config_validate_value PHP_FPM_MAX_CHILDREN "$2" ;;
    max_requests) config_validate_value PHP_FPM_MAX_REQUESTS "$2" ;;   # 0 = 不回收行程
    idle_timeout) config_validate_value PHP_FPM_IDLE_TIMEOUT "$2" ;;
    *) return 1 ;;
  esac
}

# backup-dir 不合法時回傳 1（呼叫端在改寫任何 pool 之前停止）
init_php_backup_dir() {
  local base
  base="$(config_get_valid BACKUP_DIR)" || return 1
  PHP_BACKUP_DIR="${base%/}/php"
  if [[ ! -d "$PHP_BACKUP_DIR" ]]; then
    (umask 077; mkdir -p "$PHP_BACKUP_DIR") 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------------------
# Optimize a single site's PHP-FPM pool configuration
# ------------------------------------------------------------------------------
optimize_site_php_fpm() {
  local domain
  domain=$(clean_domain "$1")
  local php_ver="${2:-}"

  if [[ -z "$domain" ]]; then
    log_error "$(_t "PHP_FPM_ERR_DOMAIN_REQUIRED")"
    return 1
  fi

  if [[ -z "$php_ver" ]]; then
    php_ver=$(find_site_php_version "$domain")
  fi

  local pool_file="/etc/php/${php_ver}/fpm/pool.d/${domain}.conf"

  # 若該版本下無設定檔，嘗試搜尋系統已安裝之其他 PHP 版本 pool.d
  if [[ ! -f "$pool_file" ]]; then
    local alt_file
    for alt_file in /etc/php/*/fpm/pool.d/"${domain}.conf"; do
      if [[ -f "$alt_file" ]]; then
        local detected_ver
        detected_ver=$(echo "$alt_file" | awk -F'/' '{print $4}')
        log_warn "$(_t "PHP_FPM_WARN_AUTO_SWITCH" "$domain" "$php_ver" "$detected_ver" "$detected_ver")"
        pool_file="$alt_file"
        php_ver="$detected_ver"
        break
      fi
    done
  fi

  if [[ ! -f "$pool_file" ]]; then
    log_warn "$(_t "PHP_FPM_WARN_CONF_NOT_FOUND" "$pool_file")"
    return 1
  fi

  # 參數值驗證（指令參數、環境變數、clp config 的值都會直接寫入 pool 設定）
  php_fpm_resolve_settings || return 1
  if ! php_fpm_validate_value max_children "$PHP_FPM_MAX_CHILDREN" || \
     ! php_fpm_validate_value max_requests "$PHP_FPM_MAX_REQUESTS" || \
     ! php_fpm_validate_value idle_timeout "$PHP_FPM_IDLE_TIMEOUT"; then
    log_error "$(_t "PHP_FPM_ERR_INVALID_SETTINGS" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_MAX_REQUESTS")"
    return 1
  fi

  # 僅調整 pm = ondemand 的 pool；dynamic / static 另有 start_servers、spare_servers 等限制，
  # 強制改 max_children 可能讓 pool 設定失效
  local pm_mode
  pm_mode=$(awk -F'=' '/^[[:space:]]*pm[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); v=$2} END{print v}' "$pool_file")
  if [[ "$pm_mode" != "ondemand" ]]; then
    log_warn "$(_t "PHP_FPM_WARN_NOT_ONDEMAND" "$domain" "${pm_mode:-unknown}")"
    return 0
  fi

  local rc=0
  _php_fpm_write_pool "$domain" "$php_ver" "$pool_file" \
    "pm.max_children=${PHP_FPM_MAX_CHILDREN}" \
    "pm.process_idle_timeout=${PHP_FPM_IDLE_TIMEOUT}" \
    "pm.max_requests=${PHP_FPM_MAX_REQUESTS}" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    log_info "$(_t "PHP_FPM_INFO_ALREADY_OPTIMIZED" "$domain" "$php_ver" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_MAX_REQUESTS")"
    return 0
  fi
  [[ "$rc" -ne 0 ]] && return 1
  log_success "$(_t "PHP_FPM_SUCCESS_UPDATED" "$domain" "$php_ver" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_MAX_REQUESTS")"
  _php_fpm_reload_or_defer "$php_ver"
  return 0
}

# _php_fpm_write_pool <domain> <php_ver> <pool_file> <key=value>...
#   改寫 pool 設定：先備份到 <backup-dir>/php，寫入後以 php-fpm<ver> -t 檢查，失敗時還原。
#   回傳 0 = 已變更、3 = 設定已相同（未變更）、1 = 失敗。不重載 PHP-FPM。
_php_fpm_write_pool() {
  local domain="$1" php_ver="$2" pool_file="$3"
  shift 3

  init_php_backup_dir || return 1
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_file="${PHP_BACKUP_DIR}/${domain}.conf.backup.${timestamp}"

  # 1. 在暫存目錄產生新的設定，原檔另存一份供還原（不依賴 <backup-dir>/php 備份是否成功）
  local work_dir
  work_dir=$(mktemp -d)
  local orig_copy="${work_dir}/orig.conf"
  local tmp_file="${work_dir}/new.conf"
  cp -p "$pool_file" "$orig_copy"
  cp "$pool_file" "$tmp_file"
  local kv
  for kv in "$@"; do
    _php_fpm_set_directive "$tmp_file" "${kv%%=*}" "${kv#*=}"
  done

  # 設定已相同時，無需重複備份與重載
  if cmp -s "$pool_file" "$tmp_file"; then
    rm -rf "$work_dir"
    return 3
  fi

  # 2. 備份現有設定（供使用者日後參考）
  if cp -p "$pool_file" "$backup_file" 2>/dev/null; then
    log_info "$(_t "PHP_FPM_INFO_BACKUP_CREATED" "$backup_file")"
  else
    log_warn "$(_t "PHP_FPM_WARN_BACKUP_FAILED")"
  fi

  # 3. 寫回原檔（以原子化方式置換並繼承原檔的權限與擁有者）
  atomic_replace "$tmp_file" "$pool_file"

  # 4. 語法測試；失敗時以暫存的原檔還原
  local fpm_bin=""
  if command -v "php-fpm${php_ver}" >/dev/null 2>&1; then
    fpm_bin="php-fpm${php_ver}"
  elif [[ -x "/usr/sbin/php-fpm${php_ver}" ]]; then
    fpm_bin="/usr/sbin/php-fpm${php_ver}"
  fi
  if [[ -n "$fpm_bin" ]]; then
    if "$fpm_bin" -t >/dev/null 2>&1; then
      log_info "$(_t "PHP_FPM_INFO_SYNTAX_OK" "$php_ver")"
    else
      log_error "$(_t "PHP_FPM_ERR_SYNTAX_FAILED" "$php_ver")"
      atomic_replace "$orig_copy" "$pool_file"
      rm -rf "$work_dir"
      return 1
    fi
  fi
  rm -rf "$work_dir"
  return 0
}

# 重載 PHP-FPM（批次模式由呼叫端在全部處理完後統一重載）
_php_fpm_reload_or_defer() {
  if [[ "${PHP_FPM_DEFER_RELOAD:-0}" -eq 1 ]]; then
    PHP_FPM_RELOAD_VERSIONS["$1"]=1
    return 0
  fi
  _php_fpm_reload "$1"
}

# _php_fpm_set_directive <file> <key> <value>
#   設定 pool 參數：容許 "key=value"、"key = value"、Tab 等各種空白寫法。
#   有生效中的設定 → 改寫第一筆生效的設定（註解副本保持不動）；
#   只有註解的設定 → 解除第一筆註解；都沒有 → 附加至檔尾。
_php_fpm_set_directive() {
  local file="$1" key="$2" value="$3"
  local key_re="${key//./[.]}"   # 以 [.] 比對字面上的點，避免 awk -v 處理反斜線跳脫
  local out
  out=$(mktemp)
  awk -v key_re="$key_re" -v line="${key} = ${value}" '
    BEGIN { active_re = "^[ \t]*" key_re "[ \t]*="; comment_re = "^[ \t]*;[ \t]*" key_re "[ \t]*=" }
    { lines[NR] = $0 }
    $0 ~ active_re && !a { a = NR }
    $0 ~ comment_re && !c { c = NR }
    END {
      target = a ? a : c
      for (i = 1; i <= NR; i++) print (i == target ? line : lines[i])
      if (!target) print line
    }' "$file" > "$out"
  atomic_replace "$out" "$file"
  rm -f "$out"
}

_php_fpm_reload() {
  local php_ver="$1"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl reload "php${php_ver}-fpm" 2>/dev/null; then
      log_success "$(_t "PHP_FPM_SUCCESS_RELOADED" "$php_ver")"
    else
      log_warn "$(_t "PHP_FPM_WARN_RELOAD_FAILED" "$php_ver" "$php_ver")"
    fi
  fi
}

# ------------------------------------------------------------------------------
# Optimize all sites PHP-FPM pools
# ------------------------------------------------------------------------------
optimize_all_php_fpm() {
  init_php_backup_dir || return 1

  log_step "$(_t "PHP_FPM_STEP_BATCH_START")"

  declare -A site_targets=() # site_name -> php_version

  # 1. 從 CloudPanel SQLite 取得網站與其 PHP 版本
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local sqlite_out
    sqlite_out=$(sqlite3 -readonly "$clp_db" \
      "SELECT s.domain_name, COALESCE(ps.php_version, '') FROM site s LEFT JOIN php_settings ps ON s.php_settings_id=ps.id WHERE s.type='php';" \
      2>/dev/null || true)
    while IFS='|' read -r s_dom s_ver; do
      [[ -z "$s_dom" ]] && continue
      if [[ -z "$s_ver" ]]; then
        s_ver=$(find_site_php_version "$s_dom" 2>/dev/null || get_default_php_version)
      fi
      site_targets["$s_dom"]="$s_ver"
    done <<< "$sqlite_out"
  fi

  # 2. 掃描 /etc/php/*/fpm/pool.d/*.conf 補充或校正實際存在的 pool 檔案
  for conf in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$conf" ]] || continue
    local site_name
    site_name=$(basename "$conf" .conf)
    # 略過系統預設 pool
    [[ "$site_name" == "www" || "$site_name" == "default" || "$site_name" == "global" ]] && continue

    local v
    v=$(echo "$conf" | awk -F'/' '{print $4}')
    [[ -n "$v" ]] || continue

    # 若尚未記錄，或記錄的版本設定檔不存在但此版本存在，則以此版本為準
    if [[ -z "${site_targets[$site_name]:-}" ]]; then
      site_targets["$site_name"]="$v"
    else
      local curr_ver="${site_targets[$site_name]}"
      if [[ ! -f "/etc/php/${curr_ver}/fpm/pool.d/${site_name}.conf" && -f "$conf" ]]; then
        site_targets["$site_name"]="$v"
      fi
    fi
  done

  if [[ ${#site_targets[@]} -eq 0 ]]; then
    log_warn "$(_t "PHP_FPM_WARN_NO_POOLS_FOUND")"
    return 0
  fi

  local updated_count=0
  local failed_count=0
  # 全部 pool 改完後，每個有變更的 PHP 版本只重載一次
  PHP_FPM_RELOAD_VERSIONS=()
  local PHP_FPM_DEFER_RELOAD=1
  local sorted_sites
  sorted_sites=$(printf '%s\n' "${!site_targets[@]}" | sort)

  while IFS= read -r site_name; do
    [[ -z "$site_name" ]] && continue
    local s_ver="${site_targets[$site_name]}"

    log_info "$(_t "PHP_FPM_INFO_PROCESSING_SITE" "$site_name" "$s_ver")"
    if optimize_site_php_fpm "$site_name" "$s_ver"; then
      updated_count=$((updated_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
  done <<< "$sorted_sites"

  local reload_ver
  for reload_ver in "${!PHP_FPM_RELOAD_VERSIONS[@]}"; do
    _php_fpm_reload "$reload_ver"
  done

  echo ""
  log_info "$(_t "PHP_FPM_INFO_BATCH_COMPLETE" "$updated_count" "$failed_count")"
}

# ------------------------------------------------------------------------------
# 用量診斷與建議值 (clp php-pm -status / -fix)
#   lib/php_pm.py 讀取各 pool 的 status 頁面（啟動以來的 max active processes、
#   max children reached）、近 7 天 FPM log 的滿載紀錄與主機記憶體，算出 pm.max_children
#   的建議值；-fix 只改 pm.max_children，其他參數不動。計算規則見 php_pm.py 開頭說明。
# ------------------------------------------------------------------------------
PHP_PM_ROWS=()

php_pm_py() {
  python3 -I "${CLP_LIB_DIR}/php_pm.py" "$@"
}

# php_pm_load [domain]：設定 PHP_PM_HOST_* 與 PHP_PM_ROWS（每列為 php_pm.py 的 site 列，Tab 分隔）
php_pm_load() {
  local out rc=0 line kind
  out=$(php_pm_py status "$@" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log_error "$(_t "PHP_PM_ERR_ANALYZE" "$out")"
    return 1
  fi
  PHP_PM_ROWS=()
  while IFS= read -r line; do
    kind="${line%%$'\t'*}"
    if [[ "$kind" == "host" ]]; then
      IFS=$'\t' read -r _ PHP_PM_HOST_TOTAL PHP_PM_HOST_BUDGET PHP_PM_HOST_MYSQL PHP_PM_HOST_VARNISH \
        PHP_PM_HOST_REDIS PHP_PM_HOST_RESERVE PHP_PM_HOST_WORKER PHP_PM_HOST_SAMPLES PHP_PM_HOST_CAP <<< "$line"
    elif [[ "$kind" == "site" ]]; then
      PHP_PM_ROWS+=("${line#site$'\t'}")
    fi
  done <<< "$out"
}

php_pm_conclusion_text() {
  case "$1" in
    ok) _t "PHP_PM_C_OK" ;;
    raise) _t "PHP_PM_C_RAISE" ;;
    lower) _t "PHP_PM_C_LOWER" ;;
    tight) _t "PHP_PM_C_TIGHT" ;;
    short) _t "PHP_PM_C_SHORT" ;;
    not-ondemand) _t "PHP_PM_C_NOT_ONDEMAND" ;;
    *) _t "PHP_PM_C_NO_STATUS" ;;
  esac
}

php_pm_print_table() {
  local worker_src
  if [[ "$PHP_PM_HOST_SAMPLES" -gt 0 ]]; then
    worker_src=$(_t "PHP_PM_WORKER_MEASURED" "$PHP_PM_HOST_SAMPLES")
  else
    worker_src=$(_t "PHP_PM_WORKER_DEFAULT")
  fi
  echo ""
  log_info "$(_t "PHP_PM_INFO_MEMORY" "$PHP_PM_HOST_TOTAL" "$PHP_PM_HOST_BUDGET" "$PHP_PM_HOST_MYSQL" "$PHP_PM_HOST_VARNISH" "$PHP_PM_HOST_REDIS" "$PHP_PM_HOST_RESERVE")"
  log_info "$(_t "PHP_PM_INFO_WORKER" "$PHP_PM_HOST_WORKER" "$worker_src" "$PHP_PM_HOST_CAP")"
  echo ""
  printf "%-30s %-4s %-6s %-5s %-7s %-5s %-5s %-8s %-7s %s\n" "Domain" "PHP" "max_ch" "idle" "max_req" "days" "peak" "reached" "suggest" "$(_t "SITE_VARNISH_COL_RESULT")"
  echo "--------------------------------------------------------------------------------------------------------"
  local row d ver pool pm cur idle maxreq days peak rs rl sug concl tight text
  for row in ${PHP_PM_ROWS[@]+"${PHP_PM_ROWS[@]}"}; do
    IFS=$'\t' read -r d ver pool pm cur idle maxreq days peak rs rl sug concl tight <<< "$row"
    text=$(php_pm_conclusion_text "$concl")
    [[ "$tight" == "1" && "$concl" != "tight" ]] && text="${text} $(_t "PHP_PM_C_TIGHT_NOTE")"
    printf "%-30s %-4s %-6s %-5s %-7s %-5s %-5s %-8s %-7s %s\n" "$d" "$ver" "$cur" "$idle" "$maxreq" "$days" "$peak" "${rs}/${rl}" "$sug" "$text"
  done
  echo ""
}

php_pm_status() {
  php_pm_load "$@" || return 1
  php_pm_print_table
  log_info "$(_t "PHP_PM_INFO_LEGEND")"
}

# php_pm_apply_row <row>：依建議值改寫 pm.max_children；回傳 0 成功、1 失敗
php_pm_apply_row() {
  local d ver pool pm cur idle maxreq days peak rs rl sug concl tight rc=0
  IFS=$'\t' read -r d ver pool pm cur idle maxreq days peak rs rl sug concl tight <<< "$1"
  if ! php_fpm_validate_value max_children "$sug"; then
    log_error "$(_t "PHP_FPM_ERR_INVALID_SETTINGS" "$sug" "$idle" "$maxreq")"
    return 1
  fi
  _php_fpm_write_pool "$d" "$ver" "$pool" "pm.max_children=${sug}" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    log_info "$(_t "PHP_PM_INFO_NO_CHANGE" "$d")"
    return 0
  fi
  [[ "$rc" -ne 0 ]] && return 1
  log_success "$(_t "PHP_PM_OK_APPLIED" "$d" "$cur" "$sug")"
  _php_fpm_reload_or_defer "$ver"
  return 0
}

php_pm_fix_site() {
  local domain="$1" dry_run="$2"
  php_pm_load "$domain" || return 1
  php_pm_print_table
  local row="${PHP_PM_ROWS[0]:-}" concl sug cur
  IFS=$'\t' read -r _ _ _ _ cur _ _ _ _ _ _ sug concl _ <<< "$row"
  case "$concl" in
    raise|lower) ;;
    *)
      log_info "$(_t "PHP_PM_INFO_NOTHING_TO_DO" "$domain" "$(php_pm_conclusion_text "$concl")")"
      return 0 ;;
  esac
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "PHP_PM_INFO_DRY_RUN" "$domain" "$cur" "$sug")"
    return 0
  fi
  php_pm_apply_row "$row" || return 1
  log_warn "$(_t "PHP_PM_WARN_COUNTERS_RESET")"
}

php_pm_batch_fix() {
  local dry_run="$1"
  local exclude pat row d cur sug concl excluded
  exclude=$(opt_get "exclude" "")
  local -a ex_patterns=() todo=()
  [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
  php_pm_load || return 1
  php_pm_print_table
  for row in ${PHP_PM_ROWS[@]+"${PHP_PM_ROWS[@]}"}; do
    IFS=$'\t' read -r d _ _ _ cur _ _ _ _ _ _ sug concl _ <<< "$row"
    [[ "$concl" == "raise" || "$concl" == "lower" ]] || continue
    excluded=0
    for pat in ${ex_patterns[@]+"${ex_patterns[@]}"}; do
      if domain_matches_exclude "$d" "$pat"; then excluded=1; break; fi
    done
    [[ "$excluded" -eq 1 ]] && continue
    todo+=("$row")
    log_info "  ${d}: pm.max_children ${cur} -> ${sug}"
  done
  log_info "$(_t "PHP_PM_BATCH_TODO" "${#todo[@]}")"
  [[ ${#todo[@]} -eq 0 ]] && return 0
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_CF_ONLY_BATCH_DRY_RUN")"
    return 0
  fi
  if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_NON_TTY")"
      return 1
    fi
    local confirm=""
    read -r -p "$(_t "SITE_CF_ONLY_BATCH_PROMPT" "${#todo[@]}")" confirm || confirm=""
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
      log_info "$(_t "SITE_CF_ONLY_CANCELLED")"
      return 0
    fi
  fi
  local ok=0 reload_ver
  local -a failed=()
  PHP_FPM_RELOAD_VERSIONS=()
  local PHP_FPM_DEFER_RELOAD=1
  for row in "${todo[@]}"; do
    d="${row%%$'\t'*}"
    if php_pm_apply_row "$row"; then ok=$((ok + 1)); else failed+=("$d"); fi
  done
  for reload_ver in "${!PHP_FPM_RELOAD_VERSIONS[@]}"; do
    _php_fpm_reload "$reload_ver"
  done
  echo ""
  log_warn "$(_t "PHP_PM_WARN_COUNTERS_RESET")"
  if [[ ${#failed[@]} -eq 0 ]]; then
    log_success "$(_t "SITE_CF_ONLY_BATCH_DONE" "$ok" "${#todo[@]}")"
    return 0
  fi
  log_error "$(_t "SITE_CF_ONLY_BATCH_PARTIAL" "$ok" "${#todo[@]}" "${failed[*]}")"
  return 1
}

# ------------------------------------------------------------------------------
# CLI Handler for `clp php-pm`
#   clp php-pm <domain> | -all [-max-children= ...]   套用固定值（舊寫法 `all` 仍可使用）
#   clp php-pm [<domain>] -status                     用量與建議值
#   clp php-pm <domain> -fix | -fix -all [-exclude=] [-dry-run] [-y]
# ------------------------------------------------------------------------------
php_fpm_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  local arg0="" domain="" all=0 dry_run=0
  if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    arg0="${POSITIONAL[0]}"
    domain=$(clean_domain "$arg0")
  fi
  if [[ "$domain" == "all" ]]; then
    all=1; domain=""
  fi
  has_opt "all" && all=1
  { has_opt "dry-run" || has_opt "dry_run"; } && dry_run=1

  if has_opt "php"; then
    log_error "$(_t "PHP_FPM_ERR_NO_PHP_ARG" "${domain:-<domain>}")"
    return 1
  fi

  reject_extra_positionals raw_args "y|yes|all|status|fix|dry-run|exclude|max-children|idle-timeout|max-requests" "$arg0" || return 1

  local mode=""
  has_opt "status" && mode="status"
  if has_opt "fix"; then
    [[ -n "$mode" ]] && { log_error "$(_t "PHP_FPM_ERR_TARGET_REQUIRED")"; return 1; }
    mode="fix"
  fi
  if [[ -n "$mode" ]]; then
    if has_opt "max-children" || has_opt "idle-timeout" || has_opt "max-requests"; then
      log_error "$(_t "PHP_PM_ERR_FIX_WITH_VALUES")"
      return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"; return 1
    fi
    [[ -n "$domain" ]] && { require_site_exists "$domain" "php-pm" || return 1; }
  fi

  case "$mode" in
    status)
      if [[ "$all" -eq 1 || -z "$domain" ]]; then
        php_pm_status
      else
        php_pm_status "$domain"
      fi
      ;;
    fix)
      if [[ "$all" -eq 1 ]]; then
        [[ -n "$domain" ]] && { log_error "$(_t "SITE_CF_ONLY_ERR_ALL_WITH_DOMAIN")"; return 1; }
        php_pm_batch_fix "$dry_run"
        return $?
      fi
      [[ -z "$domain" ]] && { log_error "$(_t "PHP_FPM_ERR_TARGET_REQUIRED")"; return 1; }
      php_pm_fix_site "$domain" "$dry_run"
      ;;
    *)
      if [[ "$all" -eq 1 && -n "$domain" ]]; then
        log_error "$(_t "SITE_CF_ONLY_ERR_ALL_WITH_DOMAIN")"; return 1
      fi
      if [[ "$all" -eq 0 && -z "$domain" ]]; then
        log_error "$(_t "PHP_FPM_ERR_TARGET_REQUIRED")"
        return 1
      fi
      php_fpm_resolve_settings || return 1
      log_info "$(_t "PHP_FPM_INFO_SETTINGS" "$PHP_FPM_SETTINGS_SOURCE")"
      if [[ "$all" -eq 0 ]]; then
        require_site_exists "$domain" "$(_t "PHP_FPM_STEP_OPTIMIZE_SINGLE" "$domain")" || return 1
        log_step "$(_t "PHP_FPM_STEP_OPTIMIZE_SINGLE" "$domain")"
        optimize_site_php_fpm "$domain"
      else
        optimize_all_php_fpm
      fi
      ;;
  esac
}
