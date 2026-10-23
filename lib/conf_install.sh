#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Settings files on install / reinstall
# File: lib/conf_install.sh
# Description: Installs the shipped defaults (/etc/clp/<base>.conf) and migrates
#              files left by older versions, without losing the user's settings.
#              Called by install.sh in a separate process:
#                conf_install.sh check [-y]   nothing is written; exit 2 when a file needs a
#                                             decision that cannot be asked (no TTY, no -y)
#                conf_install.sh apply [-y]   apply (asks when needed; -y = recommended choice)
#              Scenario labels in the comments below (A1-A7, B1-B3, C*, L*) name the
#              reinstall cases: A = default file, B = file from an older version,
#              C = other install situations, L = the user's .local file.
#
#   <base>.conf             shipped defaults; line 1 = "# CLP-HELPER-MANAGED-DEFAULTS v1 sha256=<body>"
#   <base>.local            the user's file; never rewritten except when merging old settings into it
#   .shipped/<base>.conf    pristine copy of the last installed default (to tell which values the
#                           user changed when the default file was edited by hand). Not read by clp.
# ==============================================================================

set -euo pipefail

CLP_ROOT_DIR="${CLP_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CLP_ROOT_DIR
# shellcheck source=/dev/null
source "${CLP_ROOT_DIR}/lib/core.sh"
# shellcheck source=/dev/null
source "${CLP_ROOT_DIR}/lib/config.sh"

# Files handled here: <base>:<kind>  (kv = key=value, merged per key; ml = multi-line, whole file)
CI_FILES=("clp:kv" "cf-rules:ml")

CI_DIR="${CLP_CONFIG_DIR:-/etc/clp}"
CI_SHIPPED_DIR="${CI_DIR}/.shipped"
CI_TS="$(date '+%Y%m%d-%H%M%S')"

CI_MODE="${1:-}"
shift || true
CI_YES=0
for _a in "$@"; do
  case "$_a" in -y|--yes|-yes|yes) CI_YES=1 ;; esac
done
# Prompts read from stdin; tests set CLP_CONF_INSTALL_ASSUME_TTY=1 to feed answers through a pipe.
# (This only allows prompting; it never relaxes the directory safety checks below.)
CI_TTY=0
if [[ -t 0 || "${CLP_CONF_INSTALL_ASSUME_TTY:-}" == "1" ]]; then CI_TTY=1; fi

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
_ci_sha_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

_ci_out() { printf '%s\n' "$*" >&2; }

# _ci_is_secret <canonical_key>: values never printed by the installer (not even partially)
_ci_is_secret() {
  local k
  k="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$k" != "cf_api_token_source" && "$k" =~ (token|secret|key|pass|pwd) ]]
}

_ci_show_val() {
  if _ci_is_secret "$1"; then _t "CONF_INST_HIDDEN"; else printf '%s' "$2"; fi
}

_ci_owner_uid() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || echo "-1"; }

# _ci_dir_safe <dir>: when running as root the directory must be a real directory owned by root
_ci_dir_safe() {
  local d="$1"
  [[ -e "$d" ]] || return 0
  if [[ -L "$d" || ! -d "$d" ]]; then return 1; fi
  if [[ "${EUID:-$(id -u)}" -eq 0 && "$(_ci_owner_uid "$d")" != "0" ]]; then return 1; fi
  return 0
}

_ci_prepare_dir() {
  local d="$1"
  if ! _ci_dir_safe "$d"; then
    log_error "$(_t "CONF_INST_ERR_UNSAFE_DIR" "$d")"
    return 1
  fi
  if [[ ! -d "$d" ]]; then
    (umask 077; mkdir -p "$d") || return 1
  fi
  chmod 700 "$d" || return 1
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then chown root:root "$d" || return 1; fi
}

# _ci_write <target> <source_file>: atomic replace (temp file in the same directory, 600, mv)
_ci_write() {
  local target="$1" src="$2" dir tmp
  dir="$(dirname "$target")"
  if ! _ci_dir_safe "$dir"; then
    log_error "$(_t "CONF_INST_ERR_UNSAFE_DIR" "$dir")"
    return 1
  fi
  tmp="$(umask 077; mktemp "${dir}/.clp-tmp.XXXXXX")" || return 1
  if ! cat "$src" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && ! chown root:root "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"; return 1
  fi
}

# _ci_backup <file>: copies <file> to <file>.bak-<time> (600) and prints the backup path
_ci_backup() {
  local f="$1" b n=1
  b="${f}.bak-${CI_TS}"
  while [[ -e "$b" ]]; do b="${f}.bak-${CI_TS}-${n}"; n=$((n + 1)); done
  _ci_write "$b" "$f" || return 1
  printf '%s\n' "$b"
}

_ci_tmp() { mktemp "${TMPDIR:-/tmp}/clp-conf.XXXXXX"; }

# Template body (without the template's own marker line)
_ci_template_body() {
  local tpl="$1"
  if clp_conf_is_managed "$tpl"; then tail -n +2 "$tpl"; else cat "$tpl"; fi
}

# _ci_render <base> <out>: the default file to install = marker with sha256 of the body + body
_ci_render() {
  local base="$1" out="$2" body sum
  body="$(_ci_tmp)"
  _ci_template_body "${CLP_ROOT_DIR}/templates/${base}.conf" > "$body"
  sum="$(_ci_sha_stdin < "$body")"
  { printf '%s v1 sha256=%s\n' "$CLP_CONF_MARKER" "$sum"; cat "$body"; } > "$out"
  rm -f "$body"
}

_ci_marker_sha() {
  local first=""
  IFS= read -r first < "$1" || true
  if [[ "$first" =~ sha256=([0-9a-f]{64}) ]]; then echo "${BASH_REMATCH[1]}"; fi
}

_ci_body_sha() { tail -n +2 "$1" | _ci_sha_stdin; }

# _ci_install_default <base>: writes /etc/clp/<base>.conf and the pristine copy
_ci_install_default() {
  local base="$1" r
  r="$(_ci_tmp)"
  _ci_render "$base" "$r"
  if ! _ci_write "${CI_DIR}/${base}.conf" "$r"; then rm -f "$r"; return 1; fi
  if ! _ci_prepare_dir "$CI_SHIPPED_DIR" || ! _ci_write "${CI_SHIPPED_DIR}/${base}.conf" "$r"; then
    rm -f "$r"; return 1
  fi
  rm -f "$r"
}

# ------------------------------------------------------------------------------
# key=value files
# ------------------------------------------------------------------------------
# _ci_kv_load <file> <assoc_name> [<order_array_name>]: canonical key -> value (last line wins)
_ci_kv_load() {
  local file="$1" line rk k v
  local -n _kv="$2"
  if [[ -n "${3:-}" ]]; then local -n _ord="$3"; else local -a _ord_dummy=(); local -n _ord=_ord_dummy; fi
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    rk="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
    [[ "$rk" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || continue
    k="$(canonical_config_key "$rk")"
    v="$(printf '%s' "${line#*=}" | tr -d '"'"'"'[:space:]')"
    [[ -n "${_kv[$k]+x}" ]] || _ord+=("$k")
    _kv[$k]="$v"
  done < "$file"
}

_ci_kv_count() {
  local -A _c=()
  _ci_kv_load "$1" _c
  echo "${#_c[@]}"
}

# _ci_local_put <local_file> <assoc_name> <order_array_name>: sets these keys in the user file
# (existing lines for the same key and its aliases are removed first; the token removes its source too)
_ci_local_put() {
  local lf="$1" k pat tmp out
  local -n _put="$2"
  local -n _porder="$3"
  tmp="$(_ci_tmp)"; out="$(_ci_tmp)"
  if [[ -f "$lf" ]]; then cat "$lf" > "$tmp"; else config_local_header > "$tmp"; fi
  for k in "${_porder[@]}"; do
    [[ -n "${_put[$k]+x}" ]] || continue
    pat="$(_config_del_pattern "$k")"
    local rc=0
    grep -v -E "$pat" "$tmp" > "$out" || rc=$?
    if [[ "$rc" -gt 1 ]]; then rm -f "$tmp" "$out"; return 1; fi
    cat "$out" > "$tmp"
  done
  for k in "${_porder[@]}"; do
    [[ -n "${_put[$k]+x}" ]] || continue
    printf '%s="%s"\n' "$k" "${_put[$k]}" >> "$tmp"
  done
  local wrc=0
  _ci_write "$lf" "$tmp" || wrc=$?
  rm -f "$tmp" "$out"
  return "$wrc"
}

# Display names of keys
_ci_names() {
  local out="" k
  for k in "$@"; do out+="${out:+, }$(display_config_key "$k")"; done
  printf '%s' "$out"
}

# ------------------------------------------------------------------------------
# Prompt
# ------------------------------------------------------------------------------
# _ci_ask <allowed choices, e.g. "1 2 3 d"> <default>: sets CI_ANS; returns 1 on EOF (= skip)
_ci_ask() {
  local allowed=" $1 " def="$2" ans=""
  if [[ "$CI_YES" -eq 1 ]]; then
    CI_ANS="$def"
    _ci_out "  $(_t "CONF_INST_AUTO_CHOICE" "$def")"
    return 0
  fi
  [[ "$CI_TTY" -eq 1 ]] || return 1
  while true; do
    printf '  %s' "$(_t "CONF_INST_PROMPT_CHOICE" "$(echo $1 | tr ' ' '/')" "$def")" >&2
    if ! IFS= read -r ans; then
      _ci_out ""
      return 1
    fi
    ans="$(echo "$ans" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$ans" ]] && ans="$def"
    if [[ "$allowed" == *" ${ans} "* ]]; then
      CI_ANS="$ans"
      return 0
    fi
    log_warn "$(_t "CONF_INST_INVALID_CHOICE" "$ans")"
  done
}

# ------------------------------------------------------------------------------
# Classification (A1-A7, B1-B3)
# ------------------------------------------------------------------------------
# _ci_state <base> <kind>: prints one of
#   missing | same | update | edited | edited_nochange | legacy_empty | legacy_user | legacy_both | unsafe
_ci_state() {
  local base="$1" kind="$2" d l rec cur
  d="${CI_DIR}/${base}.conf"; l="${CI_DIR}/${base}.local"
  if [[ -L "$d" || ( -e "$d" && ! -f "$d" ) ]]; then echo "unsafe"; return 0; fi
  if [[ ! -e "$d" ]]; then echo "missing"; return 0; fi
  if clp_conf_is_managed "$d"; then
    rec="$(_ci_marker_sha "$d")"
    cur="$(_ci_body_sha "$d")"
    local unmodified=0
    if [[ -n "$rec" ]]; then
      [[ "$rec" == "$cur" ]] && unmodified=1
    else
      # marker without hash (hand-copied template): unmodified only if identical to the template body
      [[ "$cur" == "$(_ci_template_body "${CLP_ROOT_DIR}/templates/${base}.conf" | _ci_sha_stdin)" ]] && unmodified=1
    fi
    if [[ "$unmodified" -eq 1 ]]; then
      local r; r="$(_ci_tmp)"; _ci_render "$base" "$r"
      if cmp -s "$r" "$d"; then echo "same"; else echo "update"; fi
      rm -f "$r"
      return 0
    fi
    if [[ "$kind" == "kv" && "$(_ci_kv_changed_keys "$base" | wc -l | tr -d ' ')" -eq 0 ]]; then
      echo "edited_nochange"; return 0
    fi
    echo "edited"; return 0
  fi
  # no marker: a file from an older clp version (or copied there by hand)
  if [[ "$kind" == "kv" ]]; then
    [[ "$(_ci_kv_count "$d")" -eq 0 ]] && { echo "legacy_empty"; return 0; }
  else
    clp_conf_is_known_shipped "$base" "$d" && { echo "legacy_empty"; return 0; }
  fi
  if [[ -e "$l" ]]; then echo "legacy_both"; else echo "legacy_user"; fi
}

# _ci_kv_changed_keys <base>: keys whose value in the (hand-edited) default file differs from the
# last installed default (.shipped copy; the template when the copy is missing). One key per line.
_ci_kv_changed_keys() {
  local base="$1" ref k
  ref="${CI_SHIPPED_DIR}/${base}.conf"
  [[ -f "$ref" ]] || ref="${CLP_ROOT_DIR}/templates/${base}.conf"
  local -A cur=() old=()
  local -a order=()
  _ci_kv_load "${CI_DIR}/${base}.conf" cur order
  _ci_kv_load "$ref" old
  for k in "${order[@]}"; do
    if [[ -z "${old[$k]+x}" || "${old[$k]}" != "${cur[$k]}" ]]; then echo "$k"; fi
  done
}

_ci_needs_decision() {
  case "$1" in edited|legacy_user|legacy_both) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------------------
# Handlers
# ------------------------------------------------------------------------------
_ci_handle_edited() {
  local base="$1" kind="$2" d l b
  d="${CI_DIR}/${base}.conf"; l="${CI_DIR}/${base}.local"
  if [[ "$kind" == "kv" ]]; then
    local -a changed=()
    mapfile -t changed < <(_ci_kv_changed_keys "$base")
    _ci_out ""
    log_warn "$(_t "CONF_INST_A4_TITLE_KV" "$d" "${#changed[@]}" "$(_ci_names "${changed[@]}")")"
    while true; do
      _ci_out "  $(_t "CONF_INST_A4_OPT1_KV" "$l")"
      _ci_out "  $(_t "CONF_INST_A4_OPT2")"
      _ci_out "  $(_t "CONF_INST_A4_OPT3")"
      _ci_out "  $(_t "CONF_INST_OPT_DIFF")"
      _ci_ask "1 2 3 d" 1 || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
      [[ "$CI_ANS" != "d" ]] && break
      local -A cur=() ref=()
      local reff="${CI_SHIPPED_DIR}/${base}.conf"; [[ -f "$reff" ]] || reff="${CLP_ROOT_DIR}/templates/${base}.conf"
      _ci_kv_load "$d" cur; _ci_kv_load "$reff" ref
      local k
      for k in "${changed[@]}"; do
        _ci_out "    $(_t "CONF_INST_DIFF_KEY" "$(display_config_key "$k")" "$(_ci_show_val "$k" "${ref[$k]:-}")" "$(_ci_show_val "$k" "${cur[$k]}")")"
      done
    done
    case "$CI_ANS" in
      1)
        local -A cur1=() loc=() put=()
        local -a porder=()
        _ci_kv_load "$d" cur1; _ci_kv_load "$l" loc
        local k
        for k in "${changed[@]}"; do
          [[ -n "${loc[$k]+x}" ]] && continue   # clp.local already has it: keep the user's file
          [[ "$k" == "CF_API_TOKEN_SOURCE" ]] && continue
          put[$k]="${cur1[$k]}"; porder+=("$k")
          if [[ "$k" == "CF_API_TOKEN" && -n "${cur1[CF_API_TOKEN_SOURCE]+x}" ]]; then
            put[CF_API_TOKEN_SOURCE]="${cur1[CF_API_TOKEN_SOURCE]}"; porder+=("CF_API_TOKEN_SOURCE")
          fi
        done
        if [[ ${#porder[@]} -gt 0 ]]; then _ci_local_put "$l" put porder || return 1; fi
        b="$(_ci_backup "$d")" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_KEPT_CHANGES" "$(_ci_names "${porder[@]}")" "$l")"
        log_info "$(_t "CONF_INST_BACKUP" "$b")"
        ;;
      2)
        b="$(_ci_backup "$d")" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_UPDATED" "$d")"
        log_info "$(_t "CONF_INST_BACKUP" "$b")"
        ;;
      3) log_info "$(_t "CONF_INST_SKIPPED" "$d")" ;;
    esac
    return 0
  fi

  # multi-line file
  local def=1 allowed="1 2 3 d"
  _ci_out ""
  log_warn "$(_t "CONF_INST_A4_TITLE_ML" "$d")"
  if [[ -e "$l" ]]; then def=2; allowed="2 3 d"; fi
  while true; do
    if [[ -e "$l" ]]; then
      _ci_out "  $(_t "CONF_INST_A4_LOCAL_EXISTS_ML" "$l")"
    else
      _ci_out "  $(_t "CONF_INST_A4_OPT1_ML" "$l")"
    fi
    _ci_out "  $(_t "CONF_INST_A4_OPT2")"
    _ci_out "  $(_t "CONF_INST_A4_OPT3")"
    _ci_out "  $(_t "CONF_INST_OPT_DIFF")"
    _ci_ask "$allowed" "$def" || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
    [[ "$CI_ANS" != "d" ]] && break
    local reff="${CI_SHIPPED_DIR}/${base}.conf"; [[ -f "$reff" ]] || reff="${CLP_ROOT_DIR}/templates/${base}.conf"
    diff -u "$reff" "$d" >&2 || true
  done
  case "$CI_ANS" in
    1)
      local t; t="$(_ci_tmp)"; tail -n +2 "$d" > "$t"
      if ! _ci_write "$l" "$t"; then rm -f "$t"; return 1; fi
      rm -f "$t"
      _ci_install_default "$base" || return 1
      log_success "$(_t "CONF_INST_MOVED_LOCAL" "$d" "$l")"
      ;;
    2)
      b="$(_ci_backup "$d")" || return 1
      _ci_install_default "$base" || return 1
      log_success "$(_t "CONF_INST_UPDATED" "$d")"
      log_info "$(_t "CONF_INST_BACKUP" "$b")"
      ;;
    3) log_info "$(_t "CONF_INST_SKIPPED" "$d")" ;;
  esac
}

_ci_show_kv_file() {
  local -A shown=()
  local -a shown_order=()
  local sk
  _ci_kv_load "$1" shown shown_order
  for sk in "${shown_order[@]}"; do
    _ci_out "    $(display_config_key "$sk") = $(_ci_show_val "$sk" "${shown[$sk]}")"
  done
}

# Header written by clp 1.0.x into /etc/clp/clp.conf; it names the wrong file once moved to clp.local
CI_LEGACY_KV_HEADER='# ==============================================================================
# CLP Helper Global Configuration File
# Location: /etc/clp/clp.conf (chmod 600)
# =============================================================================='

# _ci_legacy_to_local <old clp.conf>: prints the file with that header swapped for the clp.local
# header; any other content (or a file without that exact header) is printed unchanged
_ci_legacy_to_local() {
  local f="$1"
  if [[ "$(head -n 4 "$f")" == "$CI_LEGACY_KV_HEADER" ]]; then
    config_local_header
    tail -n +5 "$f"
  else
    cat "$f"
  fi
}

_ci_handle_legacy_user() {
  local base="$1" kind="$2" d l b
  d="${CI_DIR}/${base}.conf"; l="${CI_DIR}/${base}.local"
  _ci_out ""
  if [[ "$kind" == "kv" ]]; then
    log_warn "$(_t "CONF_INST_B1_TITLE_KV" "$d" "$(_ci_kv_count "$d")")"
  else
    log_warn "$(_t "CONF_INST_B1_TITLE_ML" "$d")"
  fi
  while true; do
    _ci_out "  $(_t "CONF_INST_B1_OPT1" "$l")"
    _ci_out "  $(_t "CONF_INST_B1_OPT2")"
    _ci_out "  $(_t "CONF_INST_B1_OPT3")"
    _ci_out "  $(_t "CONF_INST_OPT_SHOW")"
    _ci_ask "1 2 3 d" 1 || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
    [[ "$CI_ANS" != "d" ]] && break
    if [[ "$kind" == "kv" ]]; then _ci_show_kv_file "$d"; else sed 's/^/    /' "$d" >&2; fi
  done
  case "$CI_ANS" in
    1)
      # C6: write the user file first, then the new default (a rerun gives the same result)
      if [[ "$kind" == "kv" ]]; then
        local t; t="$(_ci_tmp)" || return 1
        _ci_legacy_to_local "$d" > "$t" && _ci_write "$l" "$t" || { rm -f "$t"; return 1; }
        rm -f "$t"
      else
        _ci_write "$l" "$d" || return 1
      fi
      _ci_install_default "$base" || return 1
      log_success "$(_t "CONF_INST_MOVED_LOCAL" "$d" "$l")"
      ;;
    2)
      b="$(_ci_backup "$d")" || return 1
      _ci_install_default "$base" || return 1
      log_success "$(_t "CONF_INST_UPDATED" "$d")"
      log_info "$(_t "CONF_INST_BACKUP" "$b")"
      ;;
    3) log_info "$(_t "CONF_INST_SKIPPED" "$d")" ;;
  esac
}

_ci_handle_legacy_both() {
  local base="$1" kind="$2" d l b
  d="${CI_DIR}/${base}.conf"; l="${CI_DIR}/${base}.local"
  _ci_out ""
  log_warn "$(_t "CONF_INST_B2_TITLE" "$d" "$l")"

  if [[ "$kind" == "ml" ]]; then
    while true; do
      _ci_out "  $(_t "CONF_INST_B2ML_OPT1" "$l")"
      _ci_out "  $(_t "CONF_INST_B2ML_OPT2" "$l" "$l")"
      _ci_out "  $(_t "CONF_INST_B2ML_OPT3")"
      _ci_out "  $(_t "CONF_INST_OPT_DIFF")"
      _ci_ask "1 2 3 d" 1 || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
      [[ "$CI_ANS" != "d" ]] && break
      diff -u "$l" "$d" >&2 || true
    done
    case "$CI_ANS" in
      1)
        b="$(_ci_backup "$d")" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_KEPT_LOCAL" "$l")"
        log_info "$(_t "CONF_INST_BACKUP" "$b")"
        ;;
      2)
        b="$(_ci_backup "$l")" || return 1
        _ci_write "$l" "$d" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_MOVED_LOCAL" "$d" "$l")"
        log_info "$(_t "CONF_INST_BACKUP" "$b")"
        ;;
      3) log_info "$(_t "CONF_INST_SKIPPED" "$d")" ;;
    esac
    return 0
  fi

  # key=value: per-key merge (B2)
  local -A old=() loc=()
  local -a oorder=() lorder=()
  _ci_kv_load "$d" old oorder
  _ci_kv_load "$l" loc lorder
  local -a only_old=() conflict=()
  local k token_conflict=0
  for k in "${oorder[@]}"; do
    [[ "$k" == "CF_API_TOKEN_SOURCE" ]] && continue
    if [[ -z "${loc[$k]+x}" ]]; then
      only_old+=("$k")
    elif [[ "${loc[$k]}" != "${old[$k]}" ]]; then
      conflict+=("$k")
      [[ "$k" == "CF_API_TOKEN" ]] && token_conflict=1
    fi
  done
  # the token source alone differing is part of the token group
  if [[ -n "${old[CF_API_TOKEN]+x}" && -n "${loc[CF_API_TOKEN]+x}" && "$token_conflict" -eq 0 && \
        "${old[CF_API_TOKEN_SOURCE]:-}" != "${loc[CF_API_TOKEN_SOURCE]:-}" ]]; then
    conflict+=("CF_API_TOKEN"); token_conflict=1
  fi

  [[ ${#only_old[@]} -gt 0 ]] && _ci_out "  $(_t "CONF_INST_B2_ONLY_OLD" "$(_ci_names "${only_old[@]}")")"
  [[ ${#conflict[@]} -gt 0 ]] && _ci_out "  $(_t "CONF_INST_B2_CONFLICT" "$(_ci_names "${conflict[@]}")")"
  while true; do
    _ci_out "  $(_t "CONF_INST_B2_OPT1" "$l")"
    _ci_out "  $(_t "CONF_INST_B2_OPT2")"
    _ci_out "  $(_t "CONF_INST_B2_OPT3")"
    _ci_out "  $(_t "CONF_INST_B2_OPT4" "$l")"
    _ci_out "  $(_t "CONF_INST_B2_OPT5")"
    _ci_out "  $(_t "CONF_INST_OPT_DIFF")"
    _ci_ask "1 2 3 4 5 d" 1 || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
    [[ "$CI_ANS" != "d" ]] && break
    for k in "${only_old[@]}" "${conflict[@]}"; do
      [[ -n "$k" ]] || continue
      _ci_out "    $(_t "CONF_INST_DIFF_BOTH" "$(display_config_key "$k")" "$(_ci_show_val "$k" "${loc[$k]:-}")" "$(_ci_show_val "$k" "${old[$k]:-}")")"
    done
  done
  [[ "$CI_ANS" == "5" ]] && { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }

  # decide which keys take the old file's value
  local -A take_old=()
  if [[ "$CI_ANS" == "1" || "$CI_ANS" == "2" || "$CI_ANS" == "3" ]]; then
    for k in "${only_old[@]}"; do [[ -n "$k" ]] && take_old[$k]=1; done
  fi
  if [[ "$CI_ANS" == "2" ]]; then
    for k in "${conflict[@]}"; do [[ -n "$k" ]] && take_old[$k]=1; done
  elif [[ "$CI_ANS" == "3" ]]; then
    for k in "${conflict[@]}"; do
      [[ -n "$k" ]] || continue
      local lv ov
      if [[ "$k" == "CF_API_TOKEN" ]]; then
        lv="$(_t "CONF_INST_TOKEN_DESC" "${loc[CF_API_TOKEN_SOURCE]:-$(_t "CONF_INST_HIDDEN")}")"
        ov="$(_t "CONF_INST_TOKEN_DESC" "${old[CF_API_TOKEN_SOURCE]:-$(_t "CONF_INST_HIDDEN")}")"
      else
        lv="$(_ci_show_val "$k" "${loc[$k]}")"; ov="$(_ci_show_val "$k" "${old[$k]}")"
      fi
      _ci_out "  $(_t "CONF_INST_B2_KEY_TITLE" "$(display_config_key "$k")" "$l" "$lv" "$ov")"
      _ci_ask "1 2" 1 || { log_info "$(_t "CONF_INST_SKIPPED" "$d")"; return 0; }
      [[ "$CI_ANS" == "2" ]] && take_old[$k]=1
    done
  fi

  local -A put=()
  local -a porder=()
  for k in "${oorder[@]}"; do
    [[ -n "${take_old[$k]+x}" ]] || continue
    put[$k]="${old[$k]}"; porder+=("$k")
    if [[ "$k" == "CF_API_TOKEN" && -n "${old[CF_API_TOKEN_SOURCE]+x}" ]]; then
      put[CF_API_TOKEN_SOURCE]="${old[CF_API_TOKEN_SOURCE]}"; porder+=("CF_API_TOKEN_SOURCE")
    fi
  done
  # C6: user file first, then the backup of the old file, then the new default
  if [[ ${#porder[@]} -gt 0 ]]; then _ci_local_put "$l" put porder || return 1; fi
  b="$(_ci_backup "$d")" || return 1
  _ci_install_default "$base" || return 1

  local -a kept=()
  for k in "${conflict[@]}"; do [[ -n "$k" && -z "${take_old[$k]+x}" ]] && kept+=("$k"); done
  if [[ ${#porder[@]} -gt 0 ]]; then
    log_success "$(_t "CONF_INST_MERGED" "$d" "$l" "$(_ci_names "${porder[@]}")")"
  else
    log_success "$(_t "CONF_INST_KEPT_LOCAL" "$l")"
  fi
  if [[ ${#kept[@]} -gt 0 ]]; then
    log_info "$(_t "CONF_INST_B2_CONFLICT_KEPT" "$l" "$(_ci_names "${kept[@]}")")"
  fi
  if [[ -z "${take_old[CF_API_TOKEN]+x}" && "$token_conflict" -eq 1 ]]; then
    log_warn "$(_t "CONF_INST_B2_TOKEN_KEPT" "$l")"
  fi
  log_info "$(_t "CONF_INST_BACKUP" "$b")"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
ci_check() {
  local item base kind st
  local -a pending=()
  if ! _ci_dir_safe "$CI_DIR"; then
    log_error "$(_t "CONF_INST_ERR_UNSAFE_DIR" "$CI_DIR")"
    return 1
  fi
  for item in "${CI_FILES[@]}"; do
    base="${item%%:*}"; kind="${item##*:}"
    st="$(_ci_state "$base" "$kind")"
    if [[ "$st" == "unsafe" ]]; then
      log_error "$(_t "CONF_INST_ERR_UNSAFE_FILE" "${CI_DIR}/${base}.conf")"
      return 1
    fi
    _ci_needs_decision "$st" && pending+=("${CI_DIR}/${base}.conf")
  done
  if [[ ${#pending[@]} -gt 0 && "$CI_YES" -eq 0 && "$CI_TTY" -eq 0 ]]; then
    log_error "$(_t "CONF_INST_ERR_NON_INTERACTIVE")"
    local p
    for p in "${pending[@]}"; do _ci_out "  - ${p}"; done
    return 2
  fi
  return 0
}

ci_apply() {
  local item base kind st d l
  ci_check || return $?
  _ci_prepare_dir "$CI_DIR" || return 1
  log_step "$(_t "CONF_INST_STEP" "$CI_DIR")"
  for item in "${CI_FILES[@]}"; do
    base="${item%%:*}"; kind="${item##*:}"
    d="${CI_DIR}/${base}.conf"; l="${CI_DIR}/${base}.local"
    st="$(_ci_state "$base" "$kind")"
    case "$st" in
      missing)
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_CREATED" "$d")"
        ;;
      same)
        [[ -f "${CI_SHIPPED_DIR}/${base}.conf" ]] || _ci_install_default "$base" || return 1
        log_info "$(_t "CONF_INST_UNCHANGED" "$d")"
        ;;
      update)
        # L7: the user's whole-file .local hides the updated shipped content
        local hint=0
        [[ "$kind" == "ml" && -e "$l" ]] && hint=1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_UPDATED" "$d")"
        [[ "$hint" -eq 1 ]] && log_warn "$(_t "CONF_INST_HINT_LOCAL_SHADOWS" "$base" "$l" "$d")"
        ;;
      edited_nochange)
        local b
        b="$(_ci_backup "$d")" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_UPDATED" "$d")"
        log_info "$(_t "CONF_INST_BACKUP" "$b")"
        ;;
      edited) _ci_handle_edited "$base" "$kind" || return 1 ;;
      legacy_empty)
        local b2
        b2="$(_ci_backup "$d")" || return 1
        _ci_install_default "$base" || return 1
        log_success "$(_t "CONF_INST_LEGACY_DEFAULT" "$d")"
        log_info "$(_t "CONF_INST_BACKUP" "$b2")"
        ;;
      legacy_user) _ci_handle_legacy_user "$base" "$kind" || return 1 ;;
      legacy_both) _ci_handle_legacy_both "$base" "$kind" || return 1 ;;
    esac
    # L3: the user's file is always 600 root:root
    if [[ -f "$l" && ! -L "$l" ]]; then
      chmod 600 "$l" || return 1
      if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then chown root:root "$l" || return 1; fi
    fi
  done

  # L4: invalid values in clp.local only produce a warning here
  local -A uv=()
  local -a uo=()
  local k
  _ci_kv_load "${CI_DIR}/clp.local" uv uo
  for k in "${uo[@]}"; do
    [[ "$k" == "CF_API_TOKEN" || "$k" == "CF_API_TOKEN_SOURCE" ]] && continue
    if ! config_validate_value "$k" "${uv[$k]}"; then
      log_warn "$(_t "CONF_INST_WARN_INVALID_LOCAL" "${CI_DIR}/clp.local" "$(display_config_key "$k")" "${uv[$k]}")"
    fi
  done
  return 0
}

case "$CI_MODE" in
  check) ci_check ;;
  apply) ci_apply ;;
  *) echo "Usage: $0 check|apply [-y]" >&2; exit 64 ;;
esac
