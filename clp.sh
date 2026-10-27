#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# Main Router & Entry Point
# ==============================================================================

set -euo pipefail

CLP_VERSION="1.3.3"
CLP_BUILD_DATE="2026-10-27"
CLP_BUILD_TIME="2026-10-27 08:20:54"
CLP_TIMESTAMP="${CLP_BUILD_TIME}"
export CLP_VERSION CLP_BUILD_DATE CLP_BUILD_TIME CLP_TIMESTAMP
# 解析軟連結，取得腳本真實所在目錄
_clp_resolve_dir() {
  local src="${BASH_SOURCE[0]}"
  # 優先使用 realpath (現代 Linux / macOS 支援)
  if command -v realpath >/dev/null 2>&1; then
    dirname "$(realpath "$src")"
    return
  fi
  # 透過 readlink 逐層解析 (Linux)
  if command -v readlink >/dev/null 2>&1; then
    local real
    real=$(readlink -f "$src" 2>/dev/null)
    if [[ -n "$real" ]]; then
      dirname "$real"
      return
    fi
  fi
  # 備援：手動跟隨 symlink
  while [[ -L "$src" ]]; do
    local link
    link=$(readlink "$src" 2>/dev/null || ls -ld "$src" | awk '{print $NF}')
    [[ "$link" != /* ]] && link="$(dirname "$src")/$link"
    src="$link"
  done
  cd "$(dirname "$src")" && pwd
}
CLP_ROOT_DIR="$(_clp_resolve_dir)"
CLP_LIB_DIR="${CLP_ROOT_DIR}/lib"
export CLP_ROOT_DIR CLP_LIB_DIR

# Source i18n & Core Library
if [[ -f "${CLP_ROOT_DIR}/lib/i18n.sh" ]]; then
  source "${CLP_ROOT_DIR}/lib/i18n.sh"
else
  echo "[ERROR] i18n library not found at ${CLP_ROOT_DIR}/lib/i18n.sh" >&2
  exit 1
fi

if [[ -f "${CLP_ROOT_DIR}/lib/core.sh" ]]; then
  source "${CLP_ROOT_DIR}/lib/core.sh"
else
  echo "[ERROR] $(_t "ERR_CORE_LIB_NOT_FOUND" "${CLP_ROOT_DIR}/lib/core.sh")" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Help & Usage Display
# ------------------------------------------------------------------------------
show_help() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "======================================================================"
  _t "HELP_BANNER_TITLE" "${CLP_VERSION}" "${CLP_BUILD_TIME}"
  echo ""
  echo "======================================================================"
  echo -e "${C_NC}"
  echo -e "${C_BOLD}$(_t "HELP_USAGE_TITLE"):${C_NC}"
  echo -e "  sudo clp <module> <target> [options...]"
  echo ""
  echo -e "${C_BOLD}$(_t "HELP_AVAILABLE_MODULES_TITLE"):${C_NC}"
  echo -e "  ${C_GREEN}site${C_NC}       $(_t "HELP_DESC_SITE")"
  echo -e "               -new          $(_t "HELP_OPT_SITE_NEW")"
  echo -e "               -list         $(_t "HELP_OPT_SITE_LIST")"
  echo -e "               -on / -off    $(_t "HELP_OPT_SITE_ON_OFF")"
  echo -e "               -ssl          $(_t "HELP_OPT_SITE_SSL")"
  echo -e "               -cf-waf       $(_t "HELP_OPT_SITE_CF_WAF")"
  echo -e "               -cf-only      $(_t "HELP_OPT_SITE_CF_ONLY")"
  echo -e "               -varnish      $(_t "HELP_OPT_SITE_VARNISH")"
  echo -e "               -vhost        $(_t "HELP_OPT_SITE_VHOST")"
  echo -e "               -nginx-hooks  $(_t "HELP_OPT_SITE_NGINX_HOOKS")"
  echo -e "               -clone-from   $(_t "HELP_OPT_SITE_CLONE_FROM")"
  echo -e "               -migrate      $(_t "HELP_OPT_SITE_MIGRATE")"
  echo -e "               delete        $(_t "HELP_OPT_SITE_DELETE")"
  echo ""
  echo -e "  ${C_GREEN}httpauth${C_NC}   $(_t "HELP_DESC_HTTPAUTH")"
  echo -e "               -add          $(_t "HELP_OPT_HTTPAUTH_ADD")"
  echo -e "               -delete       $(_t "HELP_OPT_HTTPAUTH_DELETE")"
  echo -e "               -list         $(_t "HELP_OPT_HTTPAUTH_LIST")"
  echo -e "               -path         $(_t "HELP_OPT_HTTPAUTH_PATH")"
  echo -e "               -whitelist    $(_t "HELP_OPT_HTTPAUTH_WHITELIST")"
  echo -e "               -wp-admin     $(_t "HELP_OPT_HTTPAUTH_WP_ADMIN")"
  echo ""
  echo -e "  ${C_GREEN}backup${C_NC}     $(_t "HELP_DESC_BACKUP")"
  echo -e "               -type={db|full|compact}"
  echo -e "               -to={local|<remote>} $(_t "HELP_OPT_BACKUP_TO")"
  echo -e "               -path=<path>  $(_t "HELP_OPT_BACKUP_PATH")"
  echo -e "               -expire=<Nd>  $(_t "HELP_OPT_BACKUP_EXPIRE")"
  echo ""
  echo -e "  ${C_GREEN}restore${C_NC}    $(_t "HELP_DESC_RESTORE")"
  echo -e "               -type={db|full|compact}"
  echo -e "               -to={local|<remote>}"
  echo -e "               [-file=<name>] $(_t "HELP_OPT_RESTORE_FILE")"
  echo ""
  echo -e "  ${C_GREEN}php-pm${C_NC}     $(_t "HELP_DESC_PHP_PM")"
  echo -e "               <domain>      $(_t "HELP_OPT_PHP_PM_DOMAIN")"
  echo -e "               -all          $(_t "HELP_OPT_PHP_PM_ALL")"
  echo -e "               -status       $(_t "HELP_OPT_PHP_PM_STATUS")"
  echo -e "               -fix          $(_t "HELP_OPT_PHP_PM_FIX")"
  echo ""
  echo -e "  ${C_GREEN}server${C_NC}     $(_t "HELP_DESC_SERVER")"
  echo -e "               $(_t "HELP_OPT_SERVER_NONE_LABEL")      $(_t "HELP_OPT_SERVER_NONE")"
  echo -e "               install       $(_t "HELP_OPT_SERVER_INSTALL")"
  echo -e "               -harden       $(_t "HELP_OPT_SERVER_HARDEN")"
  echo -e "               -install=<c>  $(_t "HELP_OPT_SERVER_INSTALL_PKG")"
  echo -e "               -ufw          $(_t "HELP_OPT_SERVER_UFW")"
  echo -e "               -ssh          $(_t "HELP_OPT_SERVER_SSH")"
  echo -e "               -fail2ban     $(_t "HELP_OPT_SERVER_FAIL2BAN")"
  echo -e "               -dns          $(_t "HELP_OPT_SERVER_DNS")"
  echo -e "               -timezone     $(_t "HELP_OPT_SERVER_TIMEZONE")"
  echo -e "               -smtp         $(_t "HELP_OPT_SERVER_SMTP")"
  echo -e "               -clean        $(_t "HELP_OPT_SERVER_CLEAN")"
  echo ""
  echo -e "  ${C_GREEN}config${C_NC}     $(_t "HELP_DESC_CONFIG")"
  echo -e "               -set          $(_t "HELP_OPT_CONFIG_SET")"
  echo -e "               -get          $(_t "HELP_OPT_CONFIG_GET")"
  echo -e "               -list         $(_t "HELP_OPT_CONFIG_LIST")"
  echo -e "               -unset        $(_t "HELP_OPT_CONFIG_UNSET")"
  echo ""
  echo -e "${C_BOLD}$(_t "HELP_GLOBAL_OPTIONS_TITLE"):${C_NC}"
  echo -e "  --lang=<lang>       $(_t "HELP_OPT_LANG")"
  echo -e "  -h, --help          $(_t "HELP_OPT_HELP")"
  echo -e "  -v, -V, --version   $(_t "HELP_OPT_VERSION")"
  echo ""
  echo -e "${C_DIM}$(_t "HELP_FOOTER_DOCS" "${CLP_ROOT_DIR}")${C_NC}"
  echo ""
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
main() {
  local cli_lang=""
  local filtered_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang=*|-lang=*)
        cli_lang="${1#*=}"
        shift
        ;;
      --lang|-lang)
        if [[ $# -ge 2 && "$2" != -* ]]; then
          cli_lang="$2"
          shift 2
        else
          shift
        fi
        ;;
      *)
        filtered_args+=("$1")
        shift
        ;;
    esac
  done

  # Initialize / update i18n
  init_i18n "$cli_lang"

  if [[ ${#filtered_args[@]} -eq 0 ]]; then
    show_help
    exit 0
  fi

  local first_arg="${filtered_args[0]}"
  local remaining_args=()
  if [[ ${#filtered_args[@]} -gt 1 ]]; then
    remaining_args=("${filtered_args[@]:1}")
  fi

  case "$first_arg" in
    "-h"|"--help"|"help")
      show_help
      exit 0
      ;;
    "-v"|"-V"|"--version"|"-version"|"version")
      _t "MSG_VERSION" "${CLP_VERSION}" "${CLP_BUILD_TIME}"
      echo ""
      exit 0
      ;;
    "site")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/site.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/site.sh"
        site_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_SITE" "${CLP_ROOT_DIR}/lib/site.sh")"
        exit 1
      fi
      ;;
    "httpauth")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/httpauth.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/httpauth.sh"
        httpauth_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_HTTPAUTH" "${CLP_ROOT_DIR}/lib/httpauth.sh")"
        exit 1
      fi
      ;;
    "backup")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/backup.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/backup.sh"
        backup_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_BACKUP" "${CLP_ROOT_DIR}/lib/backup.sh")"
        exit 1
      fi
      ;;
    "restore")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/backup.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/backup.sh"
        restore_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_BACKUP" "${CLP_ROOT_DIR}/lib/backup.sh")"
        exit 1
      fi
      ;;
    "php-pm"|"phppm")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/php_fpm.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/php_fpm.sh"
        php_fpm_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_PHP_FPM" "${CLP_ROOT_DIR}/lib/php_fpm.sh")"
        exit 1
      fi
      ;;
    "server")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/server.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/server.sh"
        server_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_SERVER" "${CLP_ROOT_DIR}/lib/server.sh")"
        exit 1
      fi
      ;;
    "config")
      check_root "$first_arg" ${remaining_args[@]+"${remaining_args[@]}"}
      if [[ -f "${CLP_ROOT_DIR}/lib/config.sh" ]]; then
        source "${CLP_ROOT_DIR}/lib/config.sh"
        config_handler ${remaining_args[@]+"${remaining_args[@]}"}
      else
        log_error "$(_t "ERR_MODULE_NOT_FOUND_CONFIG" "${CLP_ROOT_DIR}/lib/config.sh")"
        exit 1
      fi
      ;;
    *)
      log_error "$(_t "ERR_UNKNOWN_MODULE_OR_COMMAND" "$first_arg")"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

main "$@"
