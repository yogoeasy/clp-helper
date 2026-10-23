#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Configuration Management Module
# File: lib/config.sh
# Description: Global preferences and credential storage.
#              /etc/clp/clp.conf = shipped defaults (overwritten on install),
#              /etc/clp/clp.local = the user's own settings (written by `clp config -set`).
#              Strict permission enforcement (chmod 600, root-only access).
# ==============================================================================

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || set -euo pipefail

# Ensure CLP_ROOT_DIR is defined
if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  CLP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export CLP_ROOT_DIR
fi

# Load Core and i18n Libraries if not already loaded
if ! command -v _t >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/i18n.sh"
fi

if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/core.sh"
fi

# 分層設定讀取器（clp.local > clp.conf > templates/clp.conf），同時定義 CLP_CONFIG_* 路徑變數
if ! command -v clp_conf_read >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/conf_read.sh"
fi

# ensure_config_file：只建立使用者檔 clp.local；預設檔 clp.conf 由安裝程式管理，這裡不建立也不改寫
# Header of a new clp.local (also used when the installer moves an older clp.conf there)
config_local_header() {
  cat << 'EOF'
# ==============================================================================
# CLP Helper user settings (chmod 600)
# Written by "clp config -set" / "clp config -unset"; your own file, never
# overwritten by install or update. Only the keys you change are listed here;
# every other key uses the shipped default in /etc/clp/clp.conf.
# ==============================================================================
EOF
}

ensure_config_file() {
  if [[ ! -d "$CLP_CONFIG_DIR" ]]; then
    mkdir -p "$CLP_CONFIG_DIR"
    chmod 700 "$CLP_CONFIG_DIR"
    chown root:root "$CLP_CONFIG_DIR" 2>/dev/null || true
  fi

  if [[ ! -f "$CLP_CONFIG_LOCAL_FILE" ]]; then
    local old_umask
    old_umask=$(umask)
    umask 077
    config_local_header > "$CLP_CONFIG_LOCAL_FILE"
    umask "$old_umask"
  fi

  chmod 600 "$CLP_CONFIG_LOCAL_FILE" 2>/dev/null || true
  chown root:root "$CLP_CONFIG_LOCAL_FILE" 2>/dev/null || true
}

# Helper: Extract token from ini/credentials file
_extract_token_from_file() {
  local f="$1"
  [[ ! -f "$f" ]] && return 1

  # Priority 1: standard certbot / cloudflare ini key
  local t
  t="$(grep -E '^[[:space:]]*(dns_cloudflare_api_token|cloudflare_api_token)[[:space:]]*=' "$f" 2>/dev/null \
    | tail -n1 \
    | cut -d'=' -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' \
    | tr -d '[:space:]' || true)"

  if [[ -n "$t" ]]; then
    echo "$t"
    return 0
  fi

  # Priority 2: plain token file (single line, length >= 20, alphanumeric/dash/underscore)
  t="$(grep -v -E '^[[:space:]]*(#|$)' "$f" 2>/dev/null | head -n1 | tr -d '[:space:]"'"'"'' || true)"
  if [[ ${#t} -ge 20 && ! "$t" =~ [^a-zA-Z0-9_\-] ]]; then
    echo "$t"
    return 0
  fi

  return 1
}

# Helper: Resolve file path for CF credentials (supports absolute, relative, tilde, and .secrets/*.ini)
_resolve_cf_token_file() {
  local p="$1"
  # Expand tilde
  if [[ "$p" == ~* ]]; then
    p="${p/#\~/$HOME}"
  fi

  # Direct file check
  if [[ -f "$p" ]]; then
    if command -v realpath >/dev/null 2>&1; then
      realpath "$p"
    else
      echo "$p"
    fi
    return 0
  fi

  # Check standard secret directories if given a filename
  local search_paths=(
    "/root/.secrets/${p}"
    "/root/.secrets/${p}.ini"
    "${HOME}/.secrets/${p}"
    "${HOME}/.secrets/${p}.ini"
    "${HOME}/.secret/${p}"
    "${HOME}/.secret/${p}.ini"
  )

  for sp in "${search_paths[@]}"; do
    if [[ -f "$sp" ]]; then
      if command -v realpath >/dev/null 2>&1; then
        realpath "$sp"
      else
        echo "$sp"
      fi
      return 0
    fi
  done

  return 1
}

canonical_config_key() {
  local k="${1:-}"
  case "$k" in
    lang|clp_lang|CLP_LANG|LANG)
      echo "CLP_LANG"
      ;;
    cf-token|cf_token|CF_TOKEN|cf-api-token|cf_api_token|CF_API_TOKEN|cloudflare_api_token)
      echo "CF_API_TOKEN"
      ;;
    cf-default-mode|cf_default_mode|CF_DEFAULT_MODE)
      echo "CF_DEFAULT_MODE"
      ;;
    cf-always-https|cf_always_https|CF_ALWAYS_HTTPS)
      echo "CF_ALWAYS_HTTPS"
      ;;
    cf-min-tls|cf_min_tls|CF_MIN_TLS)
      echo "CF_MIN_TLS"
      ;;
    php-max-children|php_max_children|PHP_FPM_MAX_CHILDREN)
      echo "PHP_FPM_MAX_CHILDREN"
      ;;
    php-idle-timeout|php_idle_timeout|PHP_FPM_IDLE_TIMEOUT)
      echo "PHP_FPM_IDLE_TIMEOUT"
      ;;
    php-max-requests|php_max_requests|PHP_FPM_MAX_REQUESTS)
      echo "PHP_FPM_MAX_REQUESTS"
      ;;
    backup-dir|backup_dir|BACKUP_DIR)
      echo "BACKUP_DIR"
      ;;
    backup-remote-dir|backup_remote_dir|BACKUP_REMOTE_DIR)
      echo "BACKUP_REMOTE_DIR"
      ;;
    backup-type|backup_type|BACKUP_TYPE)
      echo "BACKUP_TYPE"
      ;;
    backup-to|backup_to|BACKUP_TO)
      echo "BACKUP_TO"
      ;;
    backup-expire|backup_expire|BACKUP_EXPIRE)
      echo "BACKUP_EXPIRE"
      ;;
    *)
      echo "$k"
      ;;
  esac
}

# Helper: Get raw configuration value by key（clp.local > clp.conf > templates/clp.conf；
# 找不到時輸出第二個參數。各模組的數值預設值已移到 templates/clp.conf，呼叫端不要再傳寫死的預設值）
get_config_value() {
  local canon_key
  canon_key="$(canonical_config_key "$1")"
  local default_val="${2:-}"
  local found_val=""

  found_val="$(clp_conf_read "$canon_key" || true)"

  if [[ -n "$found_val" ]]; then
    echo "$found_val"
  else
    echo "$default_val"
  fi
}

# _config_valid_backup_dir：絕對路徑、不可是 /、不可含 ..、不可在 /home 底下（避免把備份寫進網站使用者可存取的位置）
_config_valid_backup_dir() {
  local v="$1"
  [[ "$v" =~ ^/[A-Za-z0-9._/+-]+$ ]] || return 1
  [[ -n "${v//\//}" ]] || return 1
  [[ "/${v}/" != *"/../"* ]] || return 1
  [[ "$v" != "/home" && "$v" != /home/* ]] || return 1
}

# _config_valid_remote_dir：rclone 遠端上的相對路徑
_config_valid_remote_dir() {
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ ]] || return 1
  [[ "/${v}/" != *"/../"* ]] || return 1
}

# config_validate_value <正規化鍵名> <值>：clp config -set 與各模組使用處共用的檢查（不輸出訊息）。
# 使用者可以手動編輯 clp.local 而繞過 -set，所以使用處也要再檢查一次；沒有檢查規則的鍵回傳 0。
config_validate_value() {
  local key="$1" v="$2"
  case "$key" in
    CLP_LANG)             [[ "$v" == "auto" || "$v" == "zh_TW" || "$v" == "en_US" ]] ;;
    PHP_FPM_MAX_CHILDREN) [[ "$v" =~ ^[1-9][0-9]{0,5}$ ]] ;;
    PHP_FPM_MAX_REQUESTS) [[ "$v" =~ ^(0|[1-9][0-9]{0,8})$ ]] ;;   # 0 = 不回收行程
    PHP_FPM_IDLE_TIMEOUT) [[ "$v" =~ ^[1-9][0-9]{0,5}[smhd]?$ ]] ;;
    CF_DEFAULT_MODE)      [[ "$v" =~ ^(off|flexible|full|strict)$ ]] ;;
    CF_ALWAYS_HTTPS)      [[ "$v" =~ ^(on|off)$ ]] ;;
    CF_MIN_TLS)           [[ "$v" =~ ^1\.[0-3]$ ]] ;;
    BACKUP_DIR)           _config_valid_backup_dir "$v" ;;
    BACKUP_REMOTE_DIR)    _config_valid_remote_dir "$v" ;;
    BACKUP_TYPE)          [[ "$v" =~ ^(db|full|compact|archive)$ ]] ;;
    BACKUP_TO)            [[ "$v" =~ ^(local|[A-Za-z0-9_][A-Za-z0-9_.-]*:?)$ ]] ;;
    BACKUP_EXPIRE)        [[ "$v" == "off" ]] || { [[ "$v" =~ ^([1-9][0-9]{0,3})d$ ]] && (( BASH_REMATCH[1] <= 3650 )); } ;;
    *)                    return 0 ;;
  esac
}

# config_report_invalid <正規化鍵名> <值>：輸出「值不合法」的錯誤訊息（stderr）
config_report_invalid() {
  local key="$1" v="$2" disp
  disp="$(display_config_key "$key")"
  case "$key" in
    CLP_LANG)
      log_error "$(_t "CONFIG_WARN_INVALID_LANG" "$v")" ;;
    PHP_FPM_MAX_CHILDREN|PHP_FPM_IDLE_TIMEOUT|PHP_FPM_MAX_REQUESTS)
      log_error "$(_t "CONFIG_ERR_INVALID_PHP_FPM" "$disp" "$v")" ;;
    *)
      log_error "$(_t "CONFIG_ERR_INVALID_VALUE" "$disp" "$v" "$(_t "CONFIG_HINT_${key}")")" ;;
  esac
}

# config_get_valid <正規化鍵名>：取得設定值並驗證，值輸出到 stdout。
# 缺值（clp.local、clp.conf、templates/clp.conf 都沒有）或值不合法時，錯誤訊息輸出到 stderr 並回傳 1，
# 不使用任何寫死的備援值（程式碼中不留預設數值）。
config_get_valid() {
  local key="$1" val
  if ! val="$(clp_conf_read "$key")"; then
    log_error "$(_t "CONFIG_ERR_MISSING_DEFAULT" "$(display_config_key "$key")")"
    return 1
  fi
  if ! config_validate_value "$key" "$val"; then
    config_report_invalid "$key" "$val"
    return 1
  fi
  printf '%s\n' "$val"
}

display_config_key() {
  local k="${1:-}"
  case "$k" in
    CLP_LANG)
      echo "lang"
      ;;
    CF_API_TOKEN)
      echo "cf-token"
      ;;
    CF_DEFAULT_MODE)
      echo "cf-default-mode"
      ;;
    CF_ALWAYS_HTTPS)
      echo "cf-always-https"
      ;;
    CF_MIN_TLS)
      echo "cf-min-tls"
      ;;
    PHP_FPM_MAX_CHILDREN)
      echo "php-max-children"
      ;;
    PHP_FPM_IDLE_TIMEOUT)
      echo "php-idle-timeout"
      ;;
    PHP_FPM_MAX_REQUESTS)
      echo "php-max-requests"
      ;;
    BACKUP_DIR)
      echo "backup-dir"
      ;;
    BACKUP_REMOTE_DIR)
      echo "backup-remote-dir"
      ;;
    BACKUP_TYPE)
      echo "backup-type"
      ;;
    BACKUP_TO)
      echo "backup-to"
      ;;
    BACKUP_EXPIRE)
      echo "backup-expire"
      ;;
    *)
      echo "$k"
      ;;
  esac
}

# _config_del_pattern <正規化鍵名>：刪除設定時要一併移除的鍵（含舊版別名）的 grep -E 樣式（set／unset 共用）
_config_del_pattern() {
  case "$1" in
    CLP_LANG) echo "^(CLP_LANG|lang)=" ;;
    CF_API_TOKEN) echo "^(CF_API_TOKEN|CF_API_TOKEN_SOURCE|cf-token|cf_token|cloudflare_api_token)=" ;;
    *) echo "^${1}=" ;;
  esac
}

mask_secret_value() {
  local k="$1"
  local v="$2"
  local k_lower
  k_lower=$(echo "$k" | tr '[:upper:]' '[:lower:]')

  if [[ "$k_lower" =~ (token|secret|key|pass|pwd) ]]; then
    local len=${#v}
    if [[ $len -gt 8 ]]; then
      local prefix="${v:0:4}"
      local suffix="${v: -4}"
      echo "${prefix}****${suffix}"
    elif [[ $len -gt 0 ]]; then
      echo "********"
    else
      echo ""
    fi
  else
    echo "$v"
  fi
}

show_config_help() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "======================================================================"
  echo " $(_t "CONFIG_HELP_TITLE")"
  echo "======================================================================"
  echo -e "${C_NC}"
  echo -e "${C_DIM}$(_t "CONFIG_HELP_DESC")${C_NC}"
  echo -e "${C_DIM}$(_t "CONFIG_HELP_FILES")${C_NC}"
  echo ""
  echo -e "${C_BOLD}$(_t "HELP_USAGE_TITLE"):${C_NC}"
  echo "  sudo clp config [options]"
  echo ""
  echo -e "${C_BOLD}$(_t "HELP_AVAILABLE_MODULES_TITLE"):${C_NC}"
  echo -e "  ${C_GREEN}-set <key>=<val>${C_NC}    $(_t "HELP_OPT_CONFIG_SET")"
  echo -e "  ${C_GREEN}-get <key>${C_NC}         $(_t "HELP_OPT_CONFIG_GET")"
  echo -e "  ${C_GREEN}-list${C_NC}              $(_t "HELP_OPT_CONFIG_LIST")"
  echo -e "  ${C_GREEN}-unset <key>${C_NC}       $(_t "HELP_OPT_CONFIG_UNSET")"
  echo ""
  echo -e "${C_BOLD}$(_t "CONFIG_HELP_EXAMPLES"):${C_NC}"
  echo "  sudo clp config -set lang=zh_TW"
  echo "  sudo clp config -set lang=en_US"
  echo "  sudo clp config -set cf-token=\"your_cloudflare_api_token\""
  echo "  sudo clp config -set cf-token=/root/.secrets/example.ini"
  echo "  sudo clp config -set php-max-children=50"
  echo "  sudo clp config -set php-idle-timeout=60s"
  echo "  sudo clp config -set php-max-requests=500"
  echo "  sudo clp config -set backup-dir=/root/clpBackup"
  echo "  sudo clp config -set backup-to=google"
  echo "  sudo clp config -get lang"
  echo "  sudo clp config -get cf-token"
  echo "  sudo clp config -list"
  echo "  sudo clp config -unset lang"
  echo ""
}

config_handler() {
  local action=""
  local target_key=""
  local target_val=""
  local raw_output=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -set=*|--set=*)
        action="set"
        local pair="${1#*=}"
        if [[ "$pair" == *=* ]]; then
          target_key="${pair%%=*}"
          target_val="${pair#*=}"
        else
          target_key="$pair"
        fi
        shift
        ;;
      -set|--set|set)
        action="set"
        if [[ $# -ge 2 && "$2" == *=* ]]; then
          target_key="${2%%=*}"
          target_val="${2#*=}"
          shift 2
        elif [[ $# -ge 3 && "$2" != -* && "$3" != -* ]]; then
          target_key="$2"
          target_val="$3"
          shift 3
        elif [[ $# -ge 2 && "$2" != -* ]]; then
          target_key="$2"
          shift 2
        else
          shift
        fi
        ;;
      -get=*|--get=*)
        action="get"
        target_key="${1#*=}"
        shift
        ;;
      -get|--get|get)
        action="get"
        if [[ $# -ge 2 && "$2" != -* ]]; then
          target_key="$2"
          shift 2
        else
          shift
        fi
        ;;
      -list|--list|list)
        action="list"
        shift
        ;;
      -unset=*|--unset=*)
        action="unset"
        target_key="${1#*=}"
        shift
        ;;
      -unset|--unset|unset)
        action="unset"
        if [[ $# -ge 2 && "$2" != -* ]]; then
          target_key="$2"
          shift 2
        else
          shift
        fi
        ;;
      --raw|-raw)
        raw_output=true
        shift
        ;;
      -h|--help|help)
        show_config_help
        return 0
        ;;
      *)
        if [[ "$1" == *=* && -z "$action" ]]; then
          action="set"
          target_key="${1%%=*}"
          target_val="${1#*=}"
        fi
        shift
        ;;
    esac
  done

  # Default to help if no action provided
  if [[ -z "$action" ]]; then
    show_config_help
    return 0
  fi

  ensure_config_file

  case "$action" in
    "set")
      if [[ -z "$target_key" ]]; then
        log_error "$(_t "CONFIG_ERR_INVALID_FORMAT")"
        return 1
      fi

      local canon_key
      canon_key="$(canonical_config_key "$target_key")"
      # 鍵名僅允許英數字、底線與連字號，避免被當成 regex 樣式（例如 -unset '.*' 刪除全部設定）
      if [[ ! "$canon_key" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        log_error "$(_t "CONFIG_ERR_INVALID_KEY" "$target_key")"
        return 1
      fi

      # 不允許以空值覆寫既有設定（要刪除請使用 -unset）
      if [[ -z "$target_val" || "$target_val" == "true" ]]; then
        log_error "$(_t "CONFIG_ERR_EMPTY_VALUE" "$target_key")"
        return 1
      fi

      local cf_token_source=""
      if [[ "$canon_key" == "CLP_LANG" ]]; then
        # Normalize language（auto = 依系統 locale 判斷）
        if [[ "$(echo "$target_val" | tr '[:upper:]' '[:lower:]')" == "auto" ]]; then
          target_val="auto"
        else
          target_val="$(normalize_lang "$target_val")"
        fi
        if ! config_validate_value "$canon_key" "$target_val"; then
          config_report_invalid "$canon_key" "$target_val"
          return 1
        fi
      elif [[ "$canon_key" == "CF_API_TOKEN" ]]; then
        # Check if target_val is a file path or filename
        local is_path_like=false
        if [[ "$target_val" == /* || "$target_val" == ./* || "$target_val" == ../* || "$target_val" == ~* || "$target_val" == *.ini || "$target_val" == */* ]]; then
          is_path_like=true
        fi

        local resolved_file=""
        if resolved_file="$(_resolve_cf_token_file "$target_val")"; then
          local extracted_token=""
          if extracted_token="$(_extract_token_from_file "$resolved_file")"; then
            cf_token_source="$resolved_file"
            target_val="$extracted_token"
          else
            log_error "$(_t "CONFIG_ERR_NO_TOKEN_IN_FILE" "$resolved_file")"
            return 1
          fi
        elif [[ "$is_path_like" == "true" ]]; then
          log_error "$(_t "CONFIG_ERR_FILE_NOT_FOUND" "$target_val")"
          return 1
        fi
      else
        # 與各模組使用處相同的檢查（config_validate_value）；沒有檢查規則的鍵直接通過
        if ! config_validate_value "$canon_key" "$target_val"; then
          config_report_invalid "$canon_key" "$target_val"
          return 1
        fi
      fi

      # Remove existing keys (including legacy aliases)
      local del_pattern
      del_pattern="$(_config_del_pattern "$canon_key")"

      mkdir -p "$(dirname "$CLP_CONFIG_LOCAL_FILE")"
      local tmp_file
      local old_umask
      old_umask=$(umask)
      umask 077
      tmp_file="$(mktemp "${CLP_CONFIG_LOCAL_FILE}.tmp.XXXXXX")"
      umask "$old_umask"

      [[ -n "$del_pattern" ]] || { log_error "$(_t "CONFIG_ERR_EMPTY_PATTERN")"; rm -f "$tmp_file"; return 1; }
      if [[ -f "$CLP_CONFIG_LOCAL_FILE" ]]; then
        local rc=0
        grep -v -E "$del_pattern" "$CLP_CONFIG_LOCAL_FILE" > "$tmp_file" 2>/dev/null || rc=$?
        if [[ "$rc" -gt 1 ]]; then
          log_error "grep error ($rc) while filtering config; aborting to prevent data loss"
          rm -f "$tmp_file"
          return 1
        fi
      fi

      # Append new key-value pair
      echo "${canon_key}=\"${target_val}\"" >> "$tmp_file"
      if [[ -n "$cf_token_source" ]]; then
        echo "CF_API_TOKEN_SOURCE=\"${cf_token_source}\"" >> "$tmp_file"
      fi

      chmod 600 "$tmp_file"
      if ! atomic_replace "$tmp_file" "$CLP_CONFIG_LOCAL_FILE"; then
        rm -f "$tmp_file"
        log_error "$(_t "CONFIG_ERR_WRITE_FAILED" "$CLP_CONFIG_LOCAL_FILE")"
        return 1
      fi
      rm -f "$tmp_file"
      chmod 600 "$CLP_CONFIG_LOCAL_FILE" 2>/dev/null || true

      local disp_key
      disp_key="$(display_config_key "$canon_key")"
      local disp_val
      disp_val="$(mask_secret_value "$canon_key" "$target_val")"

      # If language was changed, update environment and re-initialize runtime i18n immediately
      if [[ "$canon_key" == "CLP_LANG" ]]; then
        export CLP_LANG="${target_val}"
        init_i18n "$target_val"
      fi

      if [[ -n "$cf_token_source" ]]; then
        log_success "$(_t "CONFIG_SUCCESS_SET_CF_FILE" "$cf_token_source" "$disp_val")"
      else
        log_success "$(_t "CONFIG_SUCCESS_SET" "$disp_key" "$disp_val")"
      fi
      ;;

    "get")
      if [[ -z "$target_key" ]]; then
        log_error "$(_t "CONFIG_ERR_NO_KEY" "-get")"
        return 1
      fi

      local canon_key
      canon_key="$(canonical_config_key "$target_key")"
      # 鍵名僅允許英數字、底線與連字號，避免被當成 regex 樣式（例如 -unset '.*' 刪除全部設定）
      if [[ ! "$canon_key" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        log_error "$(_t "CONFIG_ERR_INVALID_KEY" "$target_key")"
        return 1
      fi
      local found_val=""
      found_val="$(get_config_value "$canon_key")"

      if [[ -z "$found_val" ]]; then
        log_warn "$(_t "CONFIG_WARN_NOT_FOUND" "$target_key")"
        return 1
      fi

      if [[ "$raw_output" == "true" ]]; then
        echo "$found_val"
      else
        local disp_val
        disp_val="$(mask_secret_value "$canon_key" "$found_val")"
        local disp_key
        disp_key="$(display_config_key "$canon_key")"
        if [[ "$canon_key" == "CF_API_TOKEN" ]]; then
          local token_source
          token_source="$(get_config_value CF_API_TOKEN_SOURCE)"
          if [[ -n "$token_source" ]]; then
            echo "${disp_key} = ${disp_val} ($(_t "CONFIG_LABEL_SOURCE"): ${token_source})"
            return 0
          fi
        fi
        echo "${disp_key} = ${disp_val}"
      fi
      ;;

    "unset")
      if [[ -z "$target_key" ]]; then
        log_error "$(_t "CONFIG_ERR_NO_KEY" "-unset")"
        return 1
      fi

      local canon_key
      canon_key="$(canonical_config_key "$target_key")"
      # 鍵名僅允許英數字、底線與連字號，避免被當成 regex 樣式（例如 -unset '.*' 刪除全部設定）
      if [[ ! "$canon_key" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        log_error "$(_t "CONFIG_ERR_INVALID_KEY" "$target_key")"
        return 1
      fi

      local del_pattern
      del_pattern="$(_config_del_pattern "$canon_key")"

      mkdir -p "$(dirname "$CLP_CONFIG_LOCAL_FILE")"
      local tmp_file
      local old_umask
      old_umask=$(umask)
      umask 077
      tmp_file="$(mktemp "${CLP_CONFIG_LOCAL_FILE}.tmp.XXXXXX")"
      umask "$old_umask"

      [[ -n "$del_pattern" ]] || { log_error "$(_t "CONFIG_ERR_EMPTY_PATTERN")"; rm -f "$tmp_file"; return 1; }
      if [[ -f "$CLP_CONFIG_LOCAL_FILE" ]]; then
        local rc=0
        grep -v -E "$del_pattern" "$CLP_CONFIG_LOCAL_FILE" > "$tmp_file" 2>/dev/null || rc=$?
        if [[ "$rc" -gt 1 ]]; then
          log_error "grep error ($rc) while filtering config; aborting to prevent data loss"
          rm -f "$tmp_file"
          return 1
        fi
      fi

      chmod 600 "$tmp_file"
      if ! atomic_replace "$tmp_file" "$CLP_CONFIG_LOCAL_FILE"; then
        rm -f "$tmp_file"
        log_error "$(_t "CONFIG_ERR_WRITE_FAILED" "$CLP_CONFIG_LOCAL_FILE")"
        return 1
      fi
      rm -f "$tmp_file"
      chmod 600 "$CLP_CONFIG_LOCAL_FILE" 2>/dev/null || true

      local disp_key
      disp_key="$(display_config_key "$canon_key")"
      log_success "$(_t "CONFIG_SUCCESS_UNSET" "$disp_key")"

      # 恢復為預設值：顯示目前實際生效的值與來源（token 遮蔽）
      local eff_row eff_val eff_layer
      if eff_row="$(clp_conf_read_src "$canon_key")"; then
        eff_val="${eff_row%%$'\t'*}"
        eff_layer="${eff_row##*$'\t'}"
        [[ "$eff_layer" == "custom" ]] && eff_layer="$(_t "CONFIG_LABEL_CUSTOM")" || eff_layer="$(_t "CONFIG_LABEL_DEFAULT")"
        log_info "$(_t "CONFIG_INFO_UNSET_EFFECTIVE" "$disp_key" "$(mask_secret_value "$canon_key" "$eff_val")" "$eff_layer")"
      fi
      ;;

    "list")
      log_info "$(_t "CONFIG_INFO_LIST_HEADER")"
      local count=0
      local cf_source=""
      cf_source="$(get_config_value CF_API_TOKEN_SOURCE)"

      # 收集所有出現過的鍵（template、clp.conf、clp.local，依序，去除重複）
      local -a list_keys=()
      local seen=" " shipped=" " lf lline lk tplf
      tplf="$(_clp_conf_template_file)"
      for lf in "$tplf" "$CLP_CONFIG_FILE" "$CLP_CONFIG_LOCAL_FILE"; do
        [[ -f "$lf" ]] || continue
        while IFS= read -r lline || [[ -n "$lline" ]]; do
          [[ "$lline" =~ ^[[:space:]]*# ]] && continue
          [[ "$lline" == *=* ]] || continue
          lk="$(canonical_config_key "$(echo "${lline%%=*}" | tr -d '[:space:]')")"
          [[ -n "$lk" && "$lk" != "CF_API_TOKEN_SOURCE" ]] || continue
          [[ "$lf" == "$tplf" ]] && shipped+="${lk} "
          if [[ "$seen" != *" ${lk} "* ]]; then
            list_keys+=("$lk")
            seen+="${lk} "
          fi
        done < "$lf"
      done

      local raw_k row raw_v layer disp_k disp_v
      if [[ ${#list_keys[@]} -gt 0 ]]; then
        for raw_k in "${list_keys[@]}"; do
          # 機密只會出現在使用者層；找不到值的鍵（例如預設檔中的 token）不顯示
          row="$(clp_conf_read_src "$raw_k")" || continue
          raw_v="${row%%$'\t'*}"
          layer="${row##*$'\t'}"
          if [[ "$layer" == "custom" ]]; then layer="$(_t "CONFIG_LABEL_CUSTOM")"; else layer="$(_t "CONFIG_LABEL_DEFAULT")"; fi
          # 48 L6：clp.local 中有、但出廠預設已不使用的鍵（token 例外，它本來就不在預設檔中）
          if [[ "$shipped" != *" ${raw_k} "* && "$raw_k" != "CF_API_TOKEN" ]]; then
            layer="${layer}, $(_t "CONFIG_LABEL_UNUSED")"
          fi

          disp_k="$(display_config_key "$raw_k")"
          disp_v="$(mask_secret_value "$raw_k" "$raw_v")"

          if [[ "$raw_k" == "CF_API_TOKEN" && -n "$cf_source" ]]; then
            echo -e "  • ${C_CYAN}${disp_k}${C_NC} = ${disp_v} (${layer}; $(_t "CONFIG_LABEL_SOURCE"): ${cf_source})"
          else
            echo -e "  • ${C_CYAN}${disp_k}${C_NC} = ${disp_v} (${layer})"
          fi
          count=$((count + 1))
        done
      fi

      if [[ $count -eq 0 ]]; then
        echo "  $(_t "CONFIG_INFO_NO_CONFIG")"
      fi
      ;;

    *)
      log_error "$(_t "ERR_UNKNOWN_MODULE_OR_COMMAND" "$action")"
      show_config_help
      return 1
      ;;
  esac
}
