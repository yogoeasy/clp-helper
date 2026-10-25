#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Layered configuration reader
# File: lib/conf_read.sh
# Description: Dependency-free reader for the shipped defaults and the user's
#              overrides. Must not depend on _t / log_* (i18n.sh sources it).
#
#   Key-value files (clp.conf):  per key, first layer that has a value wins
#     1. /etc/clp/clp.local   user file, never touched by install/update
#     2. /etc/clp/clp.conf    shipped defaults (managed marker on line 1)
#     3. templates/clp.conf   fallback when not installed / key missing above
#   A clp.conf WITHOUT the managed marker is a pre-1.1 user file: it is read
#   as a user layer ("custom") so existing settings keep working.
#
#   Multi-line files (cf-rules, nginx-scan-block): clp_conf_pick_file picks one
#   whole file: <dir>/<base>.local > <dir>/<base>.conf > templates/<base>.conf
# ==============================================================================

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || set -euo pipefail

_CLP_CONF_READ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLP_CONFIG_DIR="${CLP_CONFIG_DIR:-/etc/clp}"
CLP_CONFIG_FILE="${CLP_CONFIG_FILE:-${CLP_CONFIG_DIR}/clp.conf}"
CLP_CONFIG_LOCAL_FILE="${CLP_CONFIG_LOCAL_FILE:-${CLP_CONFIG_DIR}/clp.local}"
CLP_CONF_MARKER="# CLP-HELPER-MANAGED-DEFAULTS"

# Path of the shipped template (CLP_CONFIG_TEMPLATE_FILE overrides it, for tests)
_clp_conf_template_file() {
  if [[ -n "${CLP_CONFIG_TEMPLATE_FILE:-}" ]]; then
    echo "$CLP_CONFIG_TEMPLATE_FILE"
  else
    echo "${CLP_ROOT_DIR:-${_CLP_CONF_READ_LIB_DIR}/..}/templates/clp.conf"
  fi
}

# True when the first line of <file> is the managed-defaults marker
clp_conf_is_managed() {
  local first=""
  [[ -f "$1" ]] || return 1
  IFS= read -r first < "$1" || true
  [[ "$first" == "$CLP_CONF_MARKER"* ]]
}

# Regex (for grep -E) of the names a key may be written as, including legacy aliases.
# Must list every alias that canonical_config_key (lib/config.sh) maps to the key.
_clp_conf_key_regex() {
  case "$1" in
    CLP_LANG) echo "CLP_LANG|clp_lang|lang|LANG" ;;
    CF_API_TOKEN) echo "CF_API_TOKEN|CF_TOKEN|cf_api_token|cf-api-token|cf_token|cf-token|cloudflare_api_token" ;;
    CF_DEFAULT_MODE) echo "CF_DEFAULT_MODE|cf_default_mode|cf-default-mode" ;;
    CF_ALWAYS_HTTPS) echo "CF_ALWAYS_HTTPS|cf_always_https|cf-always-https" ;;
    CF_MIN_TLS) echo "CF_MIN_TLS|cf_min_tls|cf-min-tls" ;;
    PHP_FPM_MAX_CHILDREN) echo "PHP_FPM_MAX_CHILDREN|php_max_children|php-max-children" ;;
    PHP_FPM_IDLE_TIMEOUT) echo "PHP_FPM_IDLE_TIMEOUT|php_idle_timeout|php-idle-timeout" ;;
    PHP_FPM_MAX_REQUESTS) echo "PHP_FPM_MAX_REQUESTS|php_max_requests|php-max-requests" ;;
    BACKUP_DIR) echo "BACKUP_DIR|backup_dir|backup-dir" ;;
    BACKUP_REMOTE_DIR) echo "BACKUP_REMOTE_DIR|backup_remote_dir|backup-remote-dir" ;;
    BACKUP_TYPE) echo "BACKUP_TYPE|backup_type|backup-type" ;;
    BACKUP_TO) echo "BACKUP_TO|backup_to|backup-to" ;;
    BACKUP_EXPIRE) echo "BACKUP_EXPIRE|backup_expire|backup-expire" ;;
    *) echo "$1" ;;
  esac
}

# Regex (for grep -E) of a line that sets <canonical_key>; spaces around the name and "=" are allowed
_clp_conf_line_regex() {
  echo "^[[:space:]]*($(_clp_conf_key_regex "$1"))[[:space:]]*="
}

# Secrets are only read from user layers, never from shipped defaults
_clp_conf_user_only() {
  [[ "$1" == "CF_API_TOKEN" || "$1" == "CF_API_TOKEN_SOURCE" ]]
}

# clp_conf_read_src <canonical_key>: prints "<value>\t<layer>" (layer = custom|default|template)
# and returns 0, or returns 1 when no layer has a value. Writes nothing else.
clp_conf_read_src() {
  local key="$1" re f layer val
  re="$(_clp_conf_line_regex "$key")"
  local -a files=("$CLP_CONFIG_LOCAL_FILE" "$CLP_CONFIG_FILE" "$(_clp_conf_template_file)")
  local i
  for i in 0 1 2; do
    f="${files[$i]}"
    [[ -f "$f" ]] || continue
    case "$i" in
      0) layer="custom" ;;
      1) if clp_conf_is_managed "$f"; then layer="default"; else layer="custom"; fi ;;
      2) layer="template" ;;
    esac
    if [[ "$layer" != "custom" ]] && _clp_conf_user_only "$key"; then
      continue
    fi
    val="$(grep -E "$re" "$f" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
    if [[ -n "$val" ]]; then
      printf '%s\t%s\n' "$val" "$layer"
      return 0
    fi
  done
  return 1
}

# clp_conf_read <canonical_key>: prints the value; returns 1 when not found
clp_conf_read() {
  local line
  line="$(clp_conf_read_src "$1")" || return 1
  printf '%s\n' "${line%%$'\t'*}"
}

# clp_conf_sha256 <file>: prints the sha256 of a file (sha256sum on Linux, shasum on macOS)
clp_conf_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# sha256 of every version of a multi-line template that clp ever shipped. Before clp managed
# /etc/clp/<base>.conf, users copied the template there by hand; an unmarked copy that matches one
# of these was never edited, so it is treated as "not customised".
CLP_CONF_KNOWN_SHIPPED_cf_rules="041d2ce253281a274332e6841406078745056807590054a68dc1988a049fed99
0d311359b5839d63b99c64be6c2a9e3ea23ae0668195cb50eac6bb5ed847cf89
50f0bfda77d1f81ea9b5cbcb0b22825ddbb9547be5ccb2b1d1ada0a3a09e34f4
df984c7dbbc4fe2e324f11274e2dbf93bf0084a135fa97c9db43204436f2ebc6
e6ac3d4cc7fe0f02312bf38a38ecbadd1b8e51d129582e5c15edd7feb602f129"

# clp_conf_is_known_shipped <base> <file>: true when <file> is byte-identical to a shipped version
clp_conf_is_known_shipped() {
  local var="CLP_CONF_KNOWN_SHIPPED_${1//-/_}" sum
  [[ -f "$2" && -n "${!var:-}" ]] || return 1
  sum="$(clp_conf_sha256 "$2")" || return 1
  [[ $'\n'"${!var}"$'\n' == *$'\n'"${sum}"$'\n'* ]]
}

# clp_conf_pick_file <dir> <base>: prints the path of the file to use, returns 1 if none exists.
# An unmarked <base>.conf that is an unedited copy of a shipped version is skipped (the template
# is newer); an unmarked edited copy is the user's file and is used as before.
clp_conf_pick_file() {
  local dir="$1" base="$2" f
  for f in "${dir}/${base}.local" "${dir}/${base}.conf" \
           "${CLP_ROOT_DIR:-${_CLP_CONF_READ_LIB_DIR}/..}/templates/${base}.conf"; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == "${dir}/${base}.conf" ]] && ! clp_conf_is_managed "$f" && clp_conf_is_known_shipped "$base" "$f"; then
      continue
    fi
    echo "$f"
    return 0
  done
  return 1
}
