#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Configuration Management Module
# File: lib/config.sh
# Description: Global preferences and credential storage (/etc/clp/clp.conf).
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

CLP_CONFIG_DIR="${CLP_CONFIG_DIR:-/etc/clp}"
CLP_CONFIG_FILE="${CLP_CONFIG_FILE:-${CLP_CONFIG_DIR}/clp.conf}"

ensure_config_file() {
  if [[ ! -d "$CLP_CONFIG_DIR" ]]; then
    mkdir -p "$CLP_CONFIG_DIR"
    chmod 700 "$CLP_CONFIG_DIR"
    chown root:root "$CLP_CONFIG_DIR" 2>/dev/null || true
  fi

  if [[ ! -f "$CLP_CONFIG_FILE" ]]; then
    touch "$CLP_CONFIG_FILE"
    chmod 600 "$CLP_CONFIG_FILE"
    chown root:root "$CLP_CONFIG_FILE" 2>/dev/null || true
    cat << 'EOF' > "$CLP_CONFIG_FILE"
# ==============================================================================
# CLP Helper Global Configuration File
# Location: /etc/clp/clp.conf (chmod 600)
# ==============================================================================
EOF
  fi

  chmod 600 "$CLP_CONFIG_FILE" 2>/dev/null || true
  chown root:root "$CLP_CONFIG_FILE" 2>/dev/null || true
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
    *)
      echo "$k"
      ;;
  esac
}

# Helper: Get raw configuration value by key (supports canonical normalization and default value)
get_config_value() {
  local target_key="$1"
  local default_val="${2:-}"
  local conf_file="${CLP_CONFIG_FILE:-/etc/clp/clp.conf}"

  [[ -f "$conf_file" ]] || { echo "$default_val"; return 0; }

  local canon_key
  canon_key="$(canonical_config_key "$target_key")"
  local found_val=""

  if [[ "$canon_key" == "CLP_LANG" ]]; then
    found_val="$(grep -E '^(CLP_LANG|lang)=' "$conf_file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
  elif [[ "$canon_key" == "CF_API_TOKEN" ]]; then
    found_val="$(grep -E '^(CF_API_TOKEN|cf-token|cf_token|cloudflare_api_token)=' "$conf_file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
  else
    found_val="$(grep -E "^${canon_key}=" "$conf_file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
  fi

  if [[ -n "$found_val" ]]; then
    echo "$found_val"
  else
    echo "$default_val"
  fi
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
      # Validate & normalize language
      if [[ "$canon_key" == "CLP_LANG" ]]; then
        local norm_l
        norm_l="$(normalize_lang "$target_val")"
        if [[ "$norm_l" != "zh_TW" && "$norm_l" != "en_US" ]]; then
          log_error "$(_t "CONFIG_WARN_INVALID_LANG" "$target_val")"
          return 1
        fi
        target_val="$norm_l"
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
      fi

      # Remove existing keys (including legacy aliases)
      local del_pattern
      del_pattern="$(_config_del_pattern "$canon_key")"

      mkdir -p "$(dirname "$CLP_CONFIG_FILE")"
      local tmp_file
      local old_umask
      old_umask=$(umask)
      umask 077
      tmp_file="$(mktemp "${CLP_CONFIG_FILE}.tmp.XXXXXX")"
      umask "$old_umask"

      [[ -n "$del_pattern" ]] || { log_error "$(_t "CONFIG_ERR_EMPTY_PATTERN")"; rm -f "$tmp_file"; return 1; }
      if [[ -f "$CLP_CONFIG_FILE" ]]; then
        local rc=0
        grep -v -E "$del_pattern" "$CLP_CONFIG_FILE" > "$tmp_file" 2>/dev/null || rc=$?
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
      atomic_replace "$tmp_file" "$CLP_CONFIG_FILE"
      rm -f "$tmp_file"
      chmod 600 "$CLP_CONFIG_FILE" 2>/dev/null || true

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
          token_source="$(grep -E '^CF_API_TOKEN_SOURCE=' "$CLP_CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
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

      mkdir -p "$(dirname "$CLP_CONFIG_FILE")"
      local tmp_file
      local old_umask
      old_umask=$(umask)
      umask 077
      tmp_file="$(mktemp "${CLP_CONFIG_FILE}.tmp.XXXXXX")"
      umask "$old_umask"

      [[ -n "$del_pattern" ]] || { log_error "$(_t "CONFIG_ERR_EMPTY_PATTERN")"; rm -f "$tmp_file"; return 1; }
      if [[ -f "$CLP_CONFIG_FILE" ]]; then
        local rc=0
        grep -v -E "$del_pattern" "$CLP_CONFIG_FILE" > "$tmp_file" 2>/dev/null || rc=$?
        if [[ "$rc" -gt 1 ]]; then
          log_error "grep error ($rc) while filtering config; aborting to prevent data loss"
          rm -f "$tmp_file"
          return 1
        fi
      fi

      chmod 600 "$tmp_file"
      atomic_replace "$tmp_file" "$CLP_CONFIG_FILE"
      rm -f "$tmp_file"
      chmod 600 "$CLP_CONFIG_FILE" 2>/dev/null || true

      local disp_key
      disp_key="$(display_config_key "$canon_key")"
      log_success "$(_t "CONFIG_SUCCESS_UNSET" "$disp_key")"
      ;;

    "list")
      log_info "$(_t "CONFIG_INFO_LIST_HEADER")"
      local count=0
      local cf_source=""
      cf_source="$(grep -E '^CF_API_TOKEN_SOURCE=' "$CLP_CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"

      while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" == *=* ]]; then
          local raw_k="${line%%=*}"
          local raw_v="${line#*=}"
          raw_k="$(echo "$raw_k" | tr -d '[:space:]')"
          raw_v="$(echo "$raw_v" | tr -d '"'"'"'[:space:]')"

          local disp_k
          disp_k="$(display_config_key "$raw_k")"
          local disp_v
          disp_v="$(mask_secret_value "$raw_k" "$raw_v")"

          # Skip internal metadata key
          [[ "$raw_k" == "CF_API_TOKEN_SOURCE" ]] && continue

          if [[ "$raw_k" == "CF_API_TOKEN" && -n "$cf_source" ]]; then
            echo -e "  • ${C_CYAN}${disp_k}${C_NC} = ${disp_v} ($(_t "CONFIG_LABEL_SOURCE"): ${cf_source})"
          else
            echo -e "  • ${C_CYAN}${disp_k}${C_NC} = ${disp_v}"
          fi
          ((count++)) || true
        fi
      done < "$CLP_CONFIG_FILE"

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
