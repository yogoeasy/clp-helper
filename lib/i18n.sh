#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# File: lib/i18n.sh
# Description: Internationalization (i18n) runtime engine.
#              Supports English (default / primary: en_US) and Taiwan Traditional Chinese (zh_TW).
#              Adheres to WordPress / GNU gettext language code standard (ISO-639_ISO-3166).
# ==============================================================================

# Ensure strict mode when executed, but safe when sourced
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || set -euo pipefail

# Ensure CLP_ROOT_DIR is defined
if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  CLP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export CLP_ROOT_DIR
fi

CLP_CURRENT_LANG="${CLP_CURRENT_LANG:-en_US}"
export CLP_CURRENT_LANG

normalize_lang() {
  local l="${1:-}"
  local l_norm="${l//-/_}"
  local l_lower
  l_lower=$(echo "$l_norm" | tr '[:upper:]' '[:lower:]')
  case "$l_lower" in
    zh_tw*|zh_hk*|zh_mo*|tw|zh_hant*|zh_cht*|zh)
      echo "zh_TW"
      ;;
    en*|c|posix|us)
      echo "en_US"
      ;;
    *)
      echo "$l"
      ;;
  esac
}

_load_locale() {
  local target_lang="${1:-}"
  [[ -z "$target_lang" ]] && return 0
  # 語系字串載入後即常駐，同一行程內不重複 source（i18n.sh 自動初始化與 clp.sh main 都會呼叫）
  [[ " ${CLP_LOADED_LOCALES:-} " == *" ${target_lang} "* ]] && return 0
  local locale_file="${CLP_ROOT_DIR}/locales/${target_lang}.sh"
  if [[ -f "$locale_file" ]]; then
    # shellcheck source=/dev/null
    source "$locale_file"
    CLP_LOADED_LOCALES="${CLP_LOADED_LOCALES:-} ${target_lang}"
  fi
}

init_i18n() {
  local cli_lang="${1:-}"
  local chosen_lang=""

  # Priority 1: CLI parameter (--lang=... / -lang=...)
  if [[ -n "$cli_lang" ]]; then
    chosen_lang="$cli_lang"
  # Priority 2: Environment variable CLP_LANG
  elif [[ -n "${CLP_LANG:-}" ]]; then
    chosen_lang="${CLP_LANG}"
  # Priority 3: Global configuration file /etc/clp/clp.conf
  # 註：i18n.sh 為最早被載入以提供 _t 翻譯函式的模組，此時 config.sh 尚未載入（config.sh
  # 本身亦依賴 _t 函式，若互相 source 會產生循環依賴），故此處保留直接 grep 解析 clp.conf。
  elif [[ -f "${CLP_CONFIG_FILE:-/etc/clp/clp.conf}" ]] && grep -qE '^(CLP_LANG|lang)=' "${CLP_CONFIG_FILE:-/etc/clp/clp.conf}" 2>/dev/null; then
    # 與 clp config -get 相同：取最後一筆 (tail -n1)，值取 = 之後全部 (cut -f2-)
    chosen_lang="$(grep -E '^(CLP_LANG|lang)=' "${CLP_CONFIG_FILE:-/etc/clp/clp.conf}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]')"
  # Priority 4: System environment variables (LC_ALL, LC_MESSAGES, LANG)
  else
    local sys_locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    local norm_sys
    norm_sys="$(normalize_lang "$sys_locale")"
    if [[ "$norm_sys" == "zh_TW" ]]; then
      chosen_lang="zh_TW"
    else
      chosen_lang="en_US"
    fi
  fi

  # Normalize language string (e.g. en -> en_US, zh-tw -> zh_TW)
  chosen_lang="$(normalize_lang "$chosen_lang")"

  # Priority 5: Fallback default to en_US if unsupported
  if [[ "$chosen_lang" != "zh_TW" && "$chosen_lang" != "en_US" ]]; then
    chosen_lang="en_US"
  fi

  CLP_CURRENT_LANG="$chosen_lang"
  export CLP_CURRENT_LANG

  # Always load en_US first as primary & fallback
  _load_locale "en_US"

  # If target language is zh_TW, load zh_TW
  if [[ "$CLP_CURRENT_LANG" != "en_US" ]]; then
    _load_locale "$CLP_CURRENT_LANG"
  fi

  # Update core log tags
  CLP_TAG_INFO="$(_t "LOG_TAG_INFO")"
  CLP_TAG_SUCCESS="$(_t "LOG_TAG_SUCCESS")"
  CLP_TAG_WARN="$(_t "LOG_TAG_WARN")"
  CLP_TAG_ERROR="$(_t "LOG_TAG_ERROR")"
  CLP_TAG_STEP="$(_t "LOG_TAG_STEP")"
  export CLP_TAG_INFO CLP_TAG_SUCCESS CLP_TAG_WARN CLP_TAG_ERROR CLP_TAG_STEP
}

_t() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    return 0
  fi
  shift || true

  local lang="${CLP_CURRENT_LANG:-en_US}"
  local clean_key="${key//[^a-zA-Z0-9_]/_}"
  local var_name="CLP_I18N_${lang}_${clean_key}"
  local pattern=""
  local found=0

  if [[ -n "${!var_name+isset}" ]]; then
    pattern="${!var_name}"
    found=1
  else
    local fallback_name="CLP_I18N_en_US_${clean_key}"
    if [[ -n "${!fallback_name+isset}" ]]; then
      pattern="${!fallback_name}"
      found=1
    fi
  fi

  if [[ $found -eq 0 ]]; then
    pattern="$key"
  fi

  if [[ $found -eq 0 && $# -gt 0 && "$pattern" != *%* ]]; then
    printf '%s [%s]' "$key" "$*"
  elif [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2059
    printf "$pattern" "$@"
  else
    printf '%s' "$pattern"
  fi
}

get_current_lang() {
  echo "${CLP_CURRENT_LANG:-en_US}"
}

# Auto-initialize on source if not yet initialized
if [[ -z "${CLP_TAG_INFO:-}" ]]; then
  init_i18n ""
fi
