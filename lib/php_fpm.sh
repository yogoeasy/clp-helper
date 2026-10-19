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

PHP_BACKUP_DIR="/root/php"
# 全域關聯陣列，記錄批次調校中待重載之 PHP 版本（保留 -g 以確保在 main() 內 source 時提升為全域）
declare -gA PHP_FPM_RELOAD_VERSIONS=()

# ==============================================================================
# PHP-FPM Pool 調校參數
#   優先順序：指令參數 (-max-children= / -idle-timeout= / -max-requests=)
#             > 環境變數 (PHP_FPM_MAX_CHILDREN 等) > clp config (php-max-children 等) > 預設值
# ==============================================================================
PHP_FPM_DEFAULT_MAX_CHILDREN="35"
PHP_FPM_DEFAULT_IDLE_TIMEOUT="30s"
PHP_FPM_DEFAULT_MAX_REQUESTS="300"
# 載入時保存環境變數覆寫值（之後每次調校前由 php_fpm_resolve_settings 重新決定實際使用的值）
PHP_FPM_ENV_MAX_CHILDREN="${PHP_FPM_MAX_CHILDREN:-}"
PHP_FPM_ENV_IDLE_TIMEOUT="${PHP_FPM_IDLE_TIMEOUT:-}"
PHP_FPM_ENV_MAX_REQUESTS="${PHP_FPM_MAX_REQUESTS:-}"
PHP_FPM_MAX_CHILDREN="$PHP_FPM_DEFAULT_MAX_CHILDREN"
PHP_FPM_IDLE_TIMEOUT="$PHP_FPM_DEFAULT_IDLE_TIMEOUT"
PHP_FPM_MAX_REQUESTS="$PHP_FPM_DEFAULT_MAX_REQUESTS"
PHP_FPM_SETTINGS_SOURCE=""

if ! command -v get_config_value >/dev/null 2>&1 && [[ -f "${CLP_ROOT_DIR}/lib/config.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/config.sh"
fi

# _php_fpm_pick <cli_value> <env_value> <config_key> <default>：輸出 "<value>\t<source>"
_php_fpm_pick() {
  local cli="$1" env="$2" key="$3" def="$4" conf=""
  if [[ -n "$cli" && "$cli" != "true" ]]; then
    printf '%s\tcli\n' "$cli"; return 0
  fi
  if [[ -n "$env" ]]; then
    printf '%s\tenv\n' "$env"; return 0
  fi
  if command -v get_config_value >/dev/null 2>&1; then
    conf=$(get_config_value "$key" "")
  fi
  if [[ -n "$conf" ]]; then
    printf '%s\tconfig\n' "$conf"; return 0
  fi
  printf '%s\tdefault\n' "$def"
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
  line=$(_php_fpm_pick "$(opt_get "max-children" "$(opt_get "max_children" "")")" "$PHP_FPM_ENV_MAX_CHILDREN" "PHP_FPM_MAX_CHILDREN" "$PHP_FPM_DEFAULT_MAX_CHILDREN")
  IFS=$'\t' read -r v1 s1 <<< "$line"
  line=$(_php_fpm_pick "$(opt_get "idle-timeout" "$(opt_get "idle_timeout" "")")" "$PHP_FPM_ENV_IDLE_TIMEOUT" "PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_DEFAULT_IDLE_TIMEOUT")
  IFS=$'\t' read -r v2 s2 <<< "$line"
  line=$(_php_fpm_pick "$(opt_get "max-requests" "$(opt_get "max_requests" "")")" "$PHP_FPM_ENV_MAX_REQUESTS" "PHP_FPM_MAX_REQUESTS" "$PHP_FPM_DEFAULT_MAX_REQUESTS")
  IFS=$'\t' read -r v3 s3 <<< "$line"
  PHP_FPM_MAX_CHILDREN="$v1"
  PHP_FPM_IDLE_TIMEOUT="$v2"
  PHP_FPM_MAX_REQUESTS="$v3"
  PHP_FPM_SETTINGS_SOURCE="pm.max_children=${v1} ($(_php_fpm_src_label "$s1")), pm.process_idle_timeout=${v2} ($(_php_fpm_src_label "$s2")), pm.max_requests=${v3} ($(_php_fpm_src_label "$s3"))"
}

# php_fpm_validate_value <max_children|idle_timeout|max_requests> <value>：clp config -set 與調校前共用的檢查
php_fpm_validate_value() {
  case "$1" in
    max_children) [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] ;;
    max_requests) [[ "$2" =~ ^(0|[1-9][0-9]{0,8})$ ]] ;;   # 0 = 不回收行程
    idle_timeout) [[ "$2" =~ ^[1-9][0-9]{0,5}[smhd]?$ ]] ;;
    *) return 1 ;;
  esac
}

init_php_backup_dir() {
  if [[ ! -d "$PHP_BACKUP_DIR" ]]; then
    mkdir -p "$PHP_BACKUP_DIR" 2>/dev/null || true
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
  php_fpm_resolve_settings
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

  init_php_backup_dir
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_file="${PHP_BACKUP_DIR}/${domain}.conf.backup.${timestamp}"

  # 1. 在暫存目錄產生最佳化後的設定，原檔另存一份供還原（不依賴 /root/php 備份是否成功）
  local work_dir
  work_dir=$(mktemp -d)
  local orig_copy="${work_dir}/orig.conf"
  local tmp_file="${work_dir}/new.conf"
  cp -p "$pool_file" "$orig_copy"
  cp "$pool_file" "$tmp_file"
  _php_fpm_set_directive "$tmp_file" "pm.max_children" "$PHP_FPM_MAX_CHILDREN"
  _php_fpm_set_directive "$tmp_file" "pm.process_idle_timeout" "$PHP_FPM_IDLE_TIMEOUT"
  _php_fpm_set_directive "$tmp_file" "pm.max_requests" "$PHP_FPM_MAX_REQUESTS"

  # 若設定檔已經是最佳化設定，無需重複備份與重載
  if cmp -s "$pool_file" "$tmp_file"; then
    rm -rf "$work_dir"
    log_info "$(_t "PHP_FPM_INFO_ALREADY_OPTIMIZED" "$domain" "$php_ver" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_MAX_REQUESTS")"
    return 0
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
  log_success "$(_t "PHP_FPM_SUCCESS_UPDATED" "$domain" "$php_ver" "$PHP_FPM_MAX_CHILDREN" "$PHP_FPM_IDLE_TIMEOUT" "$PHP_FPM_MAX_REQUESTS")"

  # 5. 重載 PHP-FPM（批次模式由呼叫端在全部處理完後統一重載）
  if [[ "${PHP_FPM_DEFER_RELOAD:-0}" -eq 1 ]]; then
    PHP_FPM_RELOAD_VERSIONS["$php_ver"]=1
    return 0
  fi
  _php_fpm_reload "$php_ver"
  return 0
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
  init_php_backup_dir

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
# CLI Handler for `clp php-pm`
# ------------------------------------------------------------------------------
php_fpm_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  local domain=""
  if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    domain=$(clean_domain "${POSITIONAL[0]}")
  fi

  if has_opt "php"; then
    log_error "$(_t "PHP_FPM_ERR_NO_PHP_ARG" "${domain:-<domain>}")"
    return 1
  fi

  if [[ -z "$domain" ]]; then
    log_error "$(_t "PHP_FPM_ERR_TARGET_REQUIRED")"
    return 1
  fi

  reject_extra_positionals raw_args "y|yes|max-children|idle-timeout|max-requests" "$domain" || return 1

  php_fpm_resolve_settings
  log_info "$(_t "PHP_FPM_INFO_SETTINGS" "$PHP_FPM_SETTINGS_SOURCE")"

  if [[ "$domain" != "all" ]]; then
    require_site_exists "$domain" "$(_t "PHP_FPM_STEP_OPTIMIZE_SINGLE" "$domain")" || return 1
    log_step "$(_t "PHP_FPM_STEP_OPTIMIZE_SINGLE" "$domain")"
    optimize_site_php_fpm "$domain"
  else
    optimize_all_php_fpm
  fi
}
