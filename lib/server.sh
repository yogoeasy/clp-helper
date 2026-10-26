#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# File: lib/server.sh
# Description: Server Management, Hardening & Fresh VPS Installer Module
#              Absorbs clp-install.sh (16 modules) and provides:
#              - clp server install (Fresh VPS automated deployment)
#              - clp server (status & security audit dashboard)
#              - clp server -harden (Step-by-step interactive hardening)
#              - clp server -install=<component> (netdata/rclone/certbot/smtp/basics)
#              - clp server -ufw, -ssh, -fail2ban, -dns, -timezone, -smtp, -clean
# ==============================================================================

# Ensure core library is loaded
if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  echo "Error: core library must be loaded first." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Help Display for Server Module
# ------------------------------------------------------------------------------
show_server_help() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "======================================================================"
  echo "$(_t "SERVER_HELP_BANNER_TITLE")"
  echo "======================================================================"
  echo -e "${C_NC}"
  echo -e "${C_BOLD}$(_t "SERVER_HELP_USAGE_TITLE"):${C_NC}"
  echo -e "  sudo clp server [subcommand|options...]"
  echo ""
  echo -e "${C_BOLD}$(_t "SERVER_HELP_MAIN_COMMANDS_TITLE"):${C_NC}"
  echo -e "  ${C_GREEN}$(_t "HELP_OPT_SERVER_NONE_LABEL")${C_NC} / ${C_GREEN}-status${C_NC} / ${C_GREEN}-audit${C_NC}"
  echo -e "               $(_t "SERVER_HELP_DESC_STATUS")"
  echo ""
  echo -e "  ${C_GREEN}install${C_NC}      $(_t "SERVER_HELP_DESC_INSTALL")"
  echo -e "               -y, --yes     $(_t "SERVER_HELP_OPT_INSTALL_Y")"
  echo -e "               --force       $(_t "SERVER_HELP_OPT_INSTALL_FORCE")"
  echo -e "               --dry-run     $(_t "SERVER_HELP_OPT_INSTALL_DRY_RUN")"
  echo -e "               --db=ENGINE   $(_t "SERVER_HELP_OPT_INSTALL_DB")"
  echo -e "               --timezone=TZ $(_t "SERVER_HELP_OPT_INSTALL_TZ")"
  echo ""
  echo -e "  ${C_GREEN}-harden${C_NC}      $(_t "SERVER_HELP_DESC_HARDEN")"
  echo -e "               $(_t "SERVER_HELP_DESC_HARDEN_ITEMS")"
  echo ""
  echo -e "  ${C_GREEN}-install=<c>${C_NC} $(_t "SERVER_HELP_DESC_INSTALL_PKG")"
  echo -e "  ${C_GREEN}-install=all${C_NC} $(_t "SERVER_HELP_DESC_INSTALL_ALL")"
  echo ""
  echo -e "${C_BOLD}$(_t "SERVER_HELP_MAINTENANCE_TITLE"):${C_NC}"
  echo -e "  ${C_GREEN}-ufw${C_NC}         $(_t "SERVER_HELP_DESC_UFW")"
  echo -e "  ${C_GREEN}-ssh${C_NC}         $(_t "SERVER_HELP_DESC_SSH")"
  echo -e "  ${C_GREEN}-fail2ban${C_NC}    $(_t "SERVER_HELP_DESC_FAIL2BAN")"
  echo -e "  ${C_GREEN}-dns${C_NC}         $(_t "SERVER_HELP_DESC_DNS")"
  echo -e "  ${C_GREEN}-timezone${C_NC}    $(_t "SERVER_HELP_DESC_TIMEZONE")"
  echo -e "  ${C_GREEN}-smtp${C_NC}        $(_t "SERVER_HELP_DESC_SMTP")"
  echo -e "  ${C_GREEN}-clean${C_NC}       $(_t "SERVER_HELP_DESC_CLEAN")"
  echo ""
  echo -e "${C_DIM}$(_t "SERVER_HELP_HINT_DASH")${C_NC}"
  echo ""
}

# ------------------------------------------------------------------------------
# 1. Constants & 16 Core Modules Registry
# ------------------------------------------------------------------------------
CLP_SERVER_VERSION="${CLP_VERSION:-1.0.0}"
CLP_DOCS_URL="https://www.cloudpanel.io/docs/v2/getting-started/other/"
CLP_INSTALLER_URL="https://installer.cloudpanel.io/ce/v2/install.sh"

get_clp_version() {
  local ver
  ver=$(dpkg -s cloudpanel 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1 || true)
  if [[ -z "$ver" ]] && command -v clpctl >/dev/null 2>&1; then
    ver=$(clpctl --version 2>/dev/null | awk '{print $NF}' || true)
  fi
  # 只用於顯示
  [[ -n "$ver" ]] || ver="$(_t "SERVER_DASH_UNKNOWN")"
  echo "$ver"
}

# 偵測已安裝之資料庫引擎類型與完整版本號 (如 MySQL 8.4.11 或 MariaDB 11.4.13)
get_database_engine_info() {
  local raw=""
  if command -v mariadbd >/dev/null 2>&1; then
    raw=$(mariadbd -V 2>&1 || true)
  elif command -v mysqld >/dev/null 2>&1; then
    raw=$(mysqld -V 2>&1 || true)
  elif command -v mariadb >/dev/null 2>&1; then
    raw=$(mariadb -V 2>&1 || true)
  elif command -v mysql >/dev/null 2>&1; then
    raw=$(mysql -V 2>&1 || true)
  fi

  local db_name=""
  local db_ver=""

  if echo "$raw" | grep -qi "mariadb"; then
    db_name="MariaDB"
    # 伺服器版本緊接在 -MariaDB 之前；10.x 用戶端的 "Ver 15.1 Distrib 10.6.18-MariaDB" 第一個數字是用戶端協定版本
    db_ver=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?-MariaDB' | head -n 1 | sed 's/-MariaDB$//' || true)
    [[ -n "$db_ver" ]] || db_ver=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
  elif echo "$raw" | grep -qiE "percona|mysql"; then
    db_name="MySQL"
    db_ver=$(echo "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
  fi

  # 備援：透過 dpkg 查詢套件版本
  if [[ -z "$db_ver" ]]; then
    if dpkg -s mariadb-server 2>/dev/null | grep -q "Status: install ok"; then
      db_name="MariaDB"
      db_ver=$(dpkg -s mariadb-server 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d':' -f2 | cut -d'+' -f1 || true)
    elif dpkg -s percona-server-server 2>/dev/null | grep -q "Status: install ok"; then
      db_name="MySQL"
      db_ver=$(dpkg -s percona-server-server 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1 || true)
    elif dpkg -s mysql-server 2>/dev/null | grep -q "Status: install ok"; then
      db_name="MySQL"
      db_ver=$(dpkg -s mysql-server 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1 || true)
    fi
  fi

  if [[ -n "$db_name" && -n "$db_ver" ]]; then
    echo "${db_name} ${db_ver}"
  elif [[ -n "$db_name" ]]; then
    echo "${db_name}"
  fi
}

# 格式化資料庫引擎代碼為友善說明標籤 (如 MYSQL_8.4 -> MySQL 8.4)
format_db_engine_label() {
  local eng="$1"
  case "$eng" in
    MYSQL_8.4)     _t "SERVER_DB_LABEL_MYSQL_8_4" ;;
    MYSQL_8.0)     _t "SERVER_DB_LABEL_MYSQL_8_0" ;;
    MARIADB_11.4)  _t "SERVER_DB_LABEL_MARIADB_11_4" ;;
    MARIADB_10.11) _t "SERVER_DB_LABEL_MARIADB_10_11" ;;
    MARIADB_12.3)  _t "SERVER_DB_LABEL_MARIADB_12_3" ;;
    MARIADB_11.8)  _t "SERVER_DB_LABEL_MARIADB_11_8" ;;
    MARIADB_10.6)  _t "SERVER_DB_LABEL_MARIADB_10_6" ;;
    *)             format_db_engine_short "$eng" ;;
  esac
}

format_db_engine_short() {
  local eng="$1"
  if [[ "$eng" =~ ^MYSQL_(.*)$ ]]; then
    echo "MySQL ${BASH_REMATCH[1]}"
  elif [[ "$eng" =~ ^MARIADB_(.*)$ ]]; then
    echo "MariaDB ${BASH_REMATCH[1]}"
  else
    echo "$eng"
  fi
}

# 規範化使用者輸入之資料庫引擎代碼 (支援別名如 mariadb, 11.4, mysql 等)
normalize_db_engine() {
  local input="$1"
  local upper
  upper=$(echo "$input" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]-')

  case "$upper" in
    MYSQL|MYSQL8.4|8.4)
      echo "MYSQL_8.4"
      ;;
    MYSQL8.0|8.0)
      echo "MYSQL_8.0"
      ;;
    MARIADB|MARIADB11.4|11.4)
      echo "MARIADB_11.4"
      ;;
    MARIADB10.11|10.11)
      echo "MARIADB_10.11"
      ;;
    MARIADB12.3|12.3)
      echo "MARIADB_12.3"
      ;;
    MARIADB11.8|11.8)
      echo "MARIADB_11.8"
      ;;
    MARIADB10.6|10.6)
      echo "MARIADB_10.6"
      ;;
    MYSQL_8.4|MYSQL_8.0|MARIADB_11.4|MARIADB_10.11|MARIADB_12.3|MARIADB_11.8|MARIADB_10.6)
      echo "$upper"
      ;;
    *)
      if [[ "$upper" =~ ^(MYSQL|MARIADB)_[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$upper"
      elif [[ "$upper" =~ ^MYSQL([0-9]+(\.[0-9]+)?)$ ]]; then
        echo "MYSQL_${BASH_REMATCH[1]}"
      elif [[ "$upper" =~ ^MARIADB([0-9]+(\.[0-9]+)?)$ ]]; then
        echo "MARIADB_${BASH_REMATCH[1]}"
      else
        echo "$input"
      fi
      ;;
  esac
}

MODULES=(
  "cloudpanel"
  "system_basics"
  "ufw"
  "ssh_hardening"
  "fail2ban"
  "dns"
  "sysctl"
  "journald"
  "unattended_upgrades"
  "snap_retention"
  "php_timezone"
  "nginx_security"
  "smtp"
  "certbot"
  "netdata"
  "rclone"
)

get_mod_desc() {
  local mod="$1"
  local db_engine="${2:-}"
  case "$mod" in
    cloudpanel)
      if command -v clpctl >/dev/null 2>&1; then
        local db_installed
        db_installed=$(get_database_engine_info)
        if [[ "${clp_already_installed:-true}" == "false" && -n "$db_installed" ]]; then
          # 本次執行才全新安裝（摘要在安裝後產生，此時 clpctl 已存在）
          _t "SERVER_MOD_DESC_CLP_FRESH_WITH_DB" "$db_installed"
        elif [[ -n "$db_installed" ]]; then
          _t "SERVER_MOD_DESC_CLP_INSTALLED_WITH_DB" "$db_installed"
        else
          _t "SERVER_MOD_DESC_CLP_INSTALLED"
        fi
      elif [[ -n "$db_engine" ]]; then
        if [[ "$db_engine" == "MYSQL_8.4" ]]; then
          _t "SERVER_MOD_DESC_CLP_DEFAULT_DB"
        else
          _t "SERVER_MOD_DESC_CLP_CUSTOM_DB" "$(format_db_engine_short "$db_engine")"
        fi
      else
        _t "SERVER_MOD_DESC_CLP_OFFICIAL"
      fi
      ;;
    system_basics)       _t "SERVER_MOD_DESC_SYSTEM_BASICS" ;;
    ufw)                 _t "SERVER_MOD_DESC_UFW" ;;
    ssh_hardening)       _t "SERVER_MOD_DESC_SSH_HARDENING" ;;
    fail2ban)            _t "SERVER_MOD_DESC_FAIL2BAN" ;;
    dns)                 _t "SERVER_MOD_DESC_DNS" ;;
    sysctl)              _t "SERVER_MOD_DESC_SYSCTL" ;;
    journald)            _t "SERVER_MOD_DESC_JOURNALD" ;;
    unattended_upgrades) _t "SERVER_MOD_DESC_UNATTENDED_UPGRADES" ;;
    snap_retention)      _t "SERVER_MOD_DESC_SNAP_RETENTION" ;;
    php_timezone)        _t "SERVER_MOD_DESC_PHP_TIMEZONE" ;;
    nginx_security)      _t "SERVER_MOD_DESC_NGINX_SECURITY" ;;
    smtp)                _t "SERVER_MOD_DESC_SMTP" ;;
    certbot)             _t "SERVER_MOD_DESC_CERTBOT" ;;
    netdata)             _t "SERVER_MOD_DESC_NETDATA" ;;
    rclone)              _t "SERVER_MOD_DESC_RCLONE" ;;
    *)                   echo "$1" ;;
  esac
}

# Module state getters and setters
is_mod_enabled() {
  local mod="$1"
  local var="MOD_ENABLED_${mod}"
  [[ "${!var:-no}" == "yes" ]]
}

set_mod_enabled() {
  local mod="$1"
  local val="$2"
  # 單純的旗標 (--netdata 解析為 true) 或 1/true/on 都視為啟用；0/false/off 視為停用
  case "$(echo "$val" | tr '[:upper:]' '[:lower:]')" in
    yes|y|true|1|on|enable|enabled) val="yes" ;;
    no|n|false|0|off|disable|disabled) val="no" ;;
  esac
  printf -v "MOD_ENABLED_${mod}" "%s" "$val"
}

get_mod_status() {
  local mod="$1"
  local var="MOD_STATUS_${mod}"
  echo "${!var:-SKIPPED}"
}

set_mod_status() {
  local mod="$1"
  local val="$2"
  printf -v "MOD_STATUS_${mod}" "%s" "$val"
}

init_modules_default() {
  for mod in "${MODULES[@]}"; do
    case "$mod" in
      cloudpanel|system_basics)
        set_mod_enabled "$mod" "yes"
        ;;
      ufw|ssh_hardening|fail2ban|dns|sysctl|journald|unattended_upgrades|snap_retention|php_timezone|nginx_security)
        set_mod_enabled "$mod" "yes"
        ;;
      smtp|certbot|netdata|rclone)
        set_mod_enabled "$mod" "no"
        ;;
    esac
    set_mod_status "$mod" "SKIPPED"
  done
}

# ------------------------------------------------------------------------------
# 2. Reusable Modular Core Actions (Shared Across Install, Harden & Maintenance)
# ------------------------------------------------------------------------------

# Module 1: CloudPanel Core
install_cloudpanel_core() {
  local selected_db="${1:-MYSQL_8.4}"
  local dry_run="${2:-false}"

  log_step "$(_t "SERVER_INSTALL_STEP_CORE")"

  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_INSTALL_INFO_DRY_RUN_CORE" "${selected_db}")"
    return 0
  fi

  # 若系統已安裝 CloudPanel，直接略過核心安裝
  if command -v clpctl >/dev/null 2>&1; then
    local installed_ver
    installed_ver=$(get_clp_version)
    local installed_db
    installed_db=$(get_database_engine_info)
    log_info "$(_t "SERVER_INSTALL_INFO_ALREADY_INSTALLED" "${installed_ver}" "${installed_db}")"
    # 自動自我修復可能殘留的 dpkg postinst 狀態 (防止後續 apt 安裝報錯)
    #   只在套件確實停在 half-configured／unpacked 時才改官方的 postinst（正常安裝的主機不動）
    local clp_pkg_status=""
    clp_pkg_status=$(dpkg-query -W -f='${Status}' cloudpanel 2>/dev/null || true)
    if [[ "$clp_pkg_status" =~ (half-configured|unpacked)$ ]] && \
       [[ -f /var/lib/dpkg/info/cloudpanel.postinst ]] && ! grep -qF 'if [ ! -d /tmp/cloudpanel ]; then exit 0; fi' /var/lib/dpkg/info/cloudpanel.postinst 2>/dev/null; then
      sed -i '2i if [ ! -d /tmp/cloudpanel ]; then exit 0; fi' /var/lib/dpkg/info/cloudpanel.postinst 2>/dev/null || true
      dpkg --configure cloudpanel >/dev/null 2>&1 || true
    fi
    return 2
  fi

  # 記憶體與 Swap 防護：
  # 若伺服器已有 >= 1G Swap，設定 SWAP=false 傳入官方安裝腳本，防止 dphys-swapfile 執行 swapoff 造成 1G 記憶體主機 OOM Crash
  local swap_kb=0
  if [[ -f /proc/meminfo ]]; then
    swap_kb=$(grep '^SwapTotal:' /proc/meminfo | awk '{print $2}' || echo 0)
  fi
  local swap_flag="true"
  if (( swap_kb >= 1048576 )); then
    log_info "$(_t "SERVER_INSTALL_INFO_SWAP_FLAG" "$((swap_kb / 1024))")"
    swap_flag="false"
  fi

  # 基礎下載與憑證套件
  log_info "$(_t "SERVER_INSTALL_INFO_APT_DEPS")"
  apt-get -o DPkg::Lock::Timeout=60 update -y
  apt-get -o DPkg::Lock::Timeout=60 install -y curl wget sudo ca-certificates gnupg

  local checksum="${CUSTOM_CLP_CHECKSUM:-}"

  if [[ -n "$checksum" ]]; then
    log_info "$(_t "SERVER_INSTALL_INFO_CHECKSUM_PASTED" "${C_CYAN}${checksum}${C_NC}")"
  else
    # 步驟 A: 動態爬取官方文件 SHA256 驗證碼與資料庫引擎清單
    log_info "$(_t "SERVER_INSTALL_INFO_FETCHING_HASH")"
    local page_content=""
    page_content=$(curl -fsSL --connect-timeout 10 --max-time 30 "$CLP_DOCS_URL" 2>/dev/null || true)

    if [[ -n "$page_content" ]]; then
      checksum=$(echo "$page_content" | grep -oE '[a-f0-9]{64}' | head -n 1 || true)
    fi

    # 步驟 B: 若自動擷取失敗，提供手動貼上備援
    if [[ -z "$checksum" ]]; then
      log_warn "$(_t "SERVER_INSTALL_WARN_DOCS_FAILED")"
      # 非互動模式 (-y 或無 TTY) 不可進入貼上流程，否則會清除畫面並卡在等待輸入
      if [[ -t 0 ]] && ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
        if handle_paste_official_command; then
          checksum="${CUSTOM_CLP_CHECKSUM:-}"
          # 使用者貼上的官方指令已指定 DB_ENGINE，以它為準
          [[ -n "${db_engine:-}" ]] && selected_db="$db_engine"
        fi
      fi
    else
      log_info "$(_t "SERVER_INSTALL_INFO_DOCS_HASH_OK" "${C_CYAN}${checksum}${C_NC}")"
    fi
  fi

  if [[ -z "$checksum" ]]; then
    log_error "$(_t "SERVER_INSTALL_ERR_NO_CHECKSUM")"
    return 1
  fi

  log_info "$(_t "SERVER_INSTALL_INFO_DB_ENGINE" "${C_BOLD}${selected_db}${C_NC}")"

  # 步驟 C: 下載並進行雜湊值檢驗
  local installer_tmp
  installer_tmp=$(mktemp /tmp/clp_install.XXXXXX)
  log_info "$(_t "SERVER_INSTALL_INFO_DOWNLOADING_SCRIPT")"
  if ! curl -fsSL --connect-timeout 15 --max-time 600 "$CLP_INSTALLER_URL" -o "$installer_tmp"; then
    log_error "$(_t "SERVER_INSTALL_ERR_DOWNLOAD_FAILED" "$CLP_INSTALLER_URL")"
    rm -f "$installer_tmp"
    return 1
  fi

  log_info "$(_t "SERVER_INSTALL_INFO_VERIFYING_SHA")"
  if ! echo "${checksum}  ${installer_tmp}" | sha256sum -c -; then
    log_error "$(_t "SERVER_INSTALL_ERR_SHA_MISMATCH")"
    rm -f "$installer_tmp"
    return 1
  fi
  log_success "$(_t "SERVER_INSTALL_SUCCESS_SHA_OK")"

  # 步驟 D: 執行官方安裝流程
  log_info "$(_t "SERVER_INSTALL_INFO_RUNNING_SCRIPT" "${selected_db}" "${swap_flag}")"
  # sudo 預設會重設環境變數，必須明確傳入 DEBIAN_FRONTEND，否則 postfix 等套件可能跳出 debconf 對話框而卡住
  if ! sudo DEBIAN_FRONTEND=noninteractive DB_ENGINE="${selected_db}" SWAP="${swap_flag}" bash "$installer_tmp"; then
    log_error "$(_t "SERVER_INSTALL_ERR_SCRIPT_FAILED")"
    log_info "$(_t "SERVER_INSTALL_INFO_DB_INCOMPATIBLE_HINT" "${selected_db}")"
    log_info "$(_t "SERVER_INSTALL_INFO_CHECK_DOCS_HINT" "${CLP_DOCS_URL}")"
    rm -f "$installer_tmp"
    return 1
  fi
  rm -f "$installer_tmp"

  # 步驟 E: 驗證 clpctl
  if ! command -v clpctl >/dev/null 2>&1; then
    log_error "$(_t "SERVER_INSTALL_ERR_CLPCTL_NOT_FOUND")"
    return 1
  fi
  log_success "$(_t "SERVER_INSTALL_SUCCESS_CORE_DONE")"

  # 步驟 F: 確保伺服器主機 SSH 金鑰存在
  if [[ ! -f /root/.ssh/id_ed25519 ]]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    log_info "$(_t "SERVER_INSTALL_INFO_GEN_SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -C "$(hostname)" -f /root/.ssh/id_ed25519 >/dev/null 2>&1 || true
  fi

  return 0
}

# Module 2: System Basics
# 驗證時區名稱（必須存在於 /usr/share/zoneinfo，例如 Asia/Taipei、UTC）
is_valid_timezone() {
  local tz="$1"
  [[ -n "$tz" && "$tz" != *..* && "$tz" =~ ^[A-Za-z0-9_+/-]+$ && -f "/usr/share/zoneinfo/${tz}" ]] || return 1
  # 只接受時區檔（TZif 開頭），leapseconds 等其他檔案不是時區
  [[ "$(head -c 4 "/usr/share/zoneinfo/${tz}" 2>/dev/null)" == "TZif" ]]
}

# 取得目前系統時區
get_current_timezone() {
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -z "$tz" && -f /etc/timezone ]] && tz=$(tr -d '[:space:]' < /etc/timezone)
  echo "${tz:-UTC}"
}

# resolve_server_timezone <non_interactive>
#   決定要套用的系統時區：有 --timezone 時以它為準；否則偵測目前時區，
#   互動模式下詢問是否變更（直接 Enter 保留），非互動模式維持目前時區不變。
#   結果輸出至 stdout，提示與錯誤輸出至 stderr。
resolve_server_timezone() {
  local non_interactive="${1:-false}"
  if has_opt "y" || has_opt "yes"; then
    non_interactive="true"
  fi
  local tz
  if has_opt "timezone"; then
    tz=$(opt_get "timezone" "")
    if [[ "$tz" == "true" ]] || ! is_valid_timezone "$tz"; then
      log_error "$(_t "SERVER_TZ_ERR_INVALID" "$tz")" >&2
      return 1
    fi
    echo "$tz"
    return 0
  fi

  local current_tz
  current_tz=$(get_current_timezone)
  if [[ "$non_interactive" == "true" || ! -t 0 ]]; then
    echo "$current_tz"
    return 0
  fi

  local input_tz=""
  while true; do
    read -r -p "$(_t "SERVER_TZ_PROMPT_KEEP_OR_CHANGE" "$current_tz")" input_tz || input_tz=""
    input_tz=$(echo "$input_tz" | tr -d '[:space:]')
    if [[ -z "$input_tz" ]]; then
      echo "$current_tz"
      return 0
    fi
    if is_valid_timezone "$input_tz"; then
      echo "$input_tz"
      return 0
    fi
    log_warn "$(_t "SERVER_TZ_ERR_INVALID" "$input_tz")" >&2
  done
}

# 設定系統時區（不安裝任何套件）
set_system_timezone() {
  local tz="$1"
  if ! is_valid_timezone "$tz"; then
    log_error "$(_t "SERVER_TZ_ERR_INVALID" "$tz")"
    return 1
  fi
  if ! timedatectl set-timezone "$tz" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    local tz_tmp
    if tz_tmp=$(mktemp 2>/dev/null); then
      # atomic_replace 沿用原檔權限，原檔不存在時沿用暫存檔（mktemp 為 600）：先設為 644
      printf '%s\n' "$tz" > "$tz_tmp" && chmod 644 "$tz_tmp" && atomic_replace "$tz_tmp" /etc/timezone 2>/dev/null || true
      rm -f "$tz_tmp"
    fi
  fi
}

setup_system_basics() {
  local target_tz="${1:-Asia/Taipei}"
  local dry_run="${2:-false}"

  log_step "$(_t "SERVER_BASICS_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_BASICS_INFO_DRY_RUN" "${target_tz}")"
    return 0
  fi

  log_info "$(_t "SERVER_BASICS_INFO_INSTALL_PKGS")"
  # 呼叫端以 || 擷取結果，set -e 在函式內不會生效，必須自行檢查
  apt-get -o DPkg::Lock::Timeout=60 update -y || log_warn "$(_t "SERVER_WARN_APT_UPDATE_FAILED")"
  if ! apt-get -o DPkg::Lock::Timeout=60 install -y build-essential tar zip unzip git sudo cron rsync ncdu jq trash-cli expect ca-certificates; then
    log_error "$(_t "SERVER_ERR_APT_INSTALL_FAILED")"
    return 1
  fi

  log_info "$(_t "SERVER_BOOTSTRAP_INFO_LOCALES_GEN")"
  locale-gen en_US.UTF-8 2>/dev/null || true
  locale-gen zh_TW.UTF-8 2>/dev/null || true
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true

  log_info "$(_t "SERVER_BASICS_INFO_SET_TZ" "${target_tz}")"
  set_system_timezone "$target_tz" || return 1
  log_success "$(_t "SERVER_BASICS_SUCCESS")"
  return 0
}

# ------------------------------------------------------------------------------
# SSH 共用工具（UFW 與 SSH hardening）
# ------------------------------------------------------------------------------
# ssh_prepare_privsep：sshd -t／-T 需要 /run/sshd；ssh.socket 啟動的主機在 ssh.service 尚未執行時
#   （例如重開機後只用 console 登入）這個目錄不存在，測試會因此失敗而不是設定有錯
ssh_prepare_privsep() {
  [[ -d /run/sshd ]] || mkdir -p -m 0755 /run/sshd 2>/dev/null || true
}

# ssh_config_test：檢查 sshd 設定語法；錯誤訊息輸出到 stdout 供呼叫端顯示
ssh_config_test() {
  ssh_prepare_privsep
  sshd -t 2>&1
}

# ssh_detect_ports：輸出所有 SSH 監聽埠（每行一個、排序去重）；完全抓不到時回傳 1
#   來源：sshd -T 的每個 port 與 listenaddress、ssh.socket 的 Listen、sshd／systemd 正在監聽的 TCP 埠
ssh_detect_ports() {
  local key val p
  local -a ports=()
  ssh_prepare_privsep
  while read -r key val; do
    case "$key" in
      port) ports+=("$val") ;;
      listenaddress) p="${val##*:}"; [[ "$val" == *:* ]] && ports+=("$p") ;;
    esac
  done < <(sshd -T 2>/dev/null || true)
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    while read -r p; do
      ports+=("$p")
    done < <(systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+' || true)
  fi
  while read -r p; do
    ports+=("$p")
  done < <(ss -Hltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' || true)
  local out
  out=$(for p in ${ports[@]+"${ports[@]}"}; do [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] && echo "$p"; done | sort -un)
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# ufw_port_has_rule <port>：UFW 是否已有提到這個埠號的 allow／limit 規則（包括只允許特定來源 IP 的規則與 OpenSSH）
#   用於啟用前補 SSH 規則：已有任何規則時不再加入對所有來源開放的 allow，避免放寬原本的限制
ufw_port_has_rule() {
  local p="$1" names="${1}(/tcp)?|port ${1}"
  # OpenSSH 應用程式設定檔固定是 22
  [[ "$p" == "22" ]] && names="${names}|OpenSSH"
  ufw show added 2>/dev/null | grep -qE "^ufw (allow|limit) (.* )?(${names})( |\$)"
}

# ssh_config_snapshot：把 sshd_config 與 sshd_config.d/ 複製到 root 專屬暫存目錄，輸出目錄路徑
ssh_config_snapshot() {
  local d
  d=$(mktemp -d /tmp/clp-sshd.XXXXXX) || return 1
  if ! cp -p /etc/ssh/sshd_config "${d}/sshd_config"; then
    rm -rf "$d"
    return 1
  fi
  if [[ -d /etc/ssh/sshd_config.d ]] && ! cp -a /etc/ssh/sshd_config.d "${d}/sshd_config.d"; then
    rm -rf "$d"
    return 1
  fi
  echo "$d"
}

# ssh_config_restore <snapshot_dir>：還原 sshd_config 與 sshd_config.d/（刪除快照之後新增的檔案）
ssh_config_restore() {
  local d="$1"
  [[ -n "$d" && -f "${d}/sshd_config" ]] || return 1
  atomic_replace "${d}/sshd_config" /etc/ssh/sshd_config || return 1
  if [[ -d "${d}/sshd_config.d" ]]; then
    local f
    for f in /etc/ssh/sshd_config.d/* /etc/ssh/sshd_config.d/.[!.]*; do
      [[ -e "$f" || -L "$f" ]] || continue
      [[ -e "${d}/sshd_config.d/${f##*/}" ]] || rm -f "$f" || return 1
    done
    cp -a "${d}/sshd_config.d/." /etc/ssh/sshd_config.d/ || return 1
  fi
}

# ssh_write_file <path> <content>：原子寫入 sshd 設定檔（同目錄暫存檔、644）
ssh_write_file() {
  local path="$1" content="$2" tmp
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 644 "$tmp" || ! atomic_replace "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  chmod 644 "$path" 2>/dev/null || true
}

# ssh_insert_block <sshd_config> <block>：把設定區塊寫進主設定檔（原子置換）
#   sshd 採用第一個讀到的值，所以寫在第一個 Match 之前；沒有 Match 時寫在檔案開頭（寫在結尾會被前面的同名設定蓋過）
ssh_insert_block() {
  local cfg="$1" block="$2" tmp
  tmp=$(mktemp "${cfg}.tmp.XXXXXX") || return 1
  if grep -qiE '^[[:space:]]*Match[[:space:]]' "$cfg"; then
    # 區塊含換行，awk -v 無法傳遞，改以環境變數傳入
    CLP_SSHD_BLOCK="$block" awk '
      !done && tolower($0) ~ /^[[:space:]]*match[[:space:]]/ { printf "%s\n", ENVIRON["CLP_SSHD_BLOCK"]; done = 1 }
      { print }' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    { printf '%s\n' "$block"; cat "$cfg"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if ! atomic_replace "$tmp" "$cfg"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

# ssh_operator_has_key：實際操作的帳號是否有可用的金鑰
#   以 sudo 執行時看 SUDO_USER 自己的 authorized_keys（root 有金鑰不代表這位操作者能用金鑰登入）；直接以 root 執行時看 root 的
#   只計算沒有前置選項的金鑰行（雲端映像常見的 command="echo Please login as ..." 不算）
ssh_operator_has_key() {
  local user="root" home="/root"
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    user="$SUDO_USER"
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
    [[ -n "$home" ]] || home="/home/${user}"
  fi
  SSH_OPERATOR="$user"
  [[ -s "${home}/.ssh/authorized_keys" ]] && \
    grep -qE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null
}

# Module 3: UFW Firewall & ICMP
setup_ufw() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_UFW_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_UFW_INFO_DRY_RUN")"
    return 0
  fi

  if ! apt-get -o DPkg::Lock::Timeout=60 install -y ufw; then
    log_error "$(_t "SERVER_UFW_ERR_INSTALL_FAILED")"
    return 1
  fi

  # SSH 埠必須先確定，抓不到就不啟用（default deny 之後會鎖死）
  local ssh_ports
  if ! ssh_ports=$(ssh_detect_ports); then
    log_error "$(_t "SERVER_UFW_ERR_SSH_PORT_UNKNOWN")"
    return 1
  fi

  # 先加入 SSH 允許規則，再設定 default deny（UFW 已啟用時 default deny 會立即生效）
  log_info "$(_t "SERVER_UFW_INFO_ALLOW_PORTS" "$(echo $ssh_ports)")"
  local sp
  for sp in $ssh_ports; do
    if ! ufw allow "${sp}/tcp" comment 'SSH'; then
      log_error "$(_t "SERVER_UFW_ERR_ALLOW_SSH" "$sp")"
      return 1
    fi
  done

  log_info "$(_t "SERVER_UFW_INFO_DEFAULT_POLICY")"
  ufw default deny incoming || return 1
  ufw default allow outgoing || return 1
  ufw allow http || log_warn "$(_t "SERVER_UFW_WARN_ALLOW_FAILED" "http")"
  ufw allow https || log_warn "$(_t "SERVER_UFW_WARN_ALLOW_FAILED" "https")"
  ufw allow 8443/tcp comment 'CloudPanel Control Panel' || log_warn "$(_t "SERVER_UFW_WARN_ALLOW_FAILED" "8443/tcp")"
  # CloudPanel 官方安裝程式會加入 8433:8443/tcp 範圍規則（多開放 8433–8442），收斂為只開放 8443
  # （ufw show added 在 UFW 尚未啟用時也會列出規則）
  if ufw show added 2>/dev/null | grep -qE 'allow 8433:8443/tcp'; then
    ufw --force delete allow 8433:8443/tcp >/dev/null 2>&1 || true
    log_info "$(_t "SERVER_UFW_INFO_REMOVED_8433_RANGE")"
  fi

  if [[ -f /etc/ufw/before.rules ]]; then
    backup_file /etc/ufw/before.rules
    log_info "$(_t "SERVER_UFW_INFO_DROP_ICMP")"
    sed -i '/ufw-before-input.*icmp.*echo-request/s/ACCEPT/DROP/g' /etc/ufw/before.rules
  fi

  log_info "$(_t "SERVER_UFW_INFO_ENABLE")"
  if ! ufw --force enable; then
    log_error "$(_t "SERVER_UFW_ERR_ENABLE")"
    return 1
  fi

  # 處理 Oracle Cloud / 雲端發行版預設 iptables REJECT 規則衝突 (常見於 /etc/iptables/rules.v4)
  # 這些預設規則會攔截在 UFW 鏈之前，導致除 22 以外的所有連接埠 (80, 443, 8443) 即使在 UFW 放行也被強行拒絕！
  log_info "$(_t "SERVER_UFW_INFO_CLEAN_IPTABLES")"
  while iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
    log_info "$(_t "SERVER_UFW_INFO_REMOVED_INPUT_REJECT")"
  done
  while iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
    log_info "$(_t "SERVER_UFW_INFO_REMOVED_FORWARD_REJECT")"
  done

  # 清理任何在 UFW 鏈之前的其他舊 INPUT 殘留規則，確保流量完全由 UFW 接管
  iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p icmp -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

  # 同步註解 /etc/iptables/rules.v4 中的 REJECT 規則，避免重開機覆蓋
  for rfile in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    # 只處理尚未註解的規則，重複執行不會再加 "# " 也不會產生多餘備份
    if [[ -f "$rfile" ]] && grep -qE '^[^#]*icmp-host-prohibited' "$rfile" 2>/dev/null; then
      backup_file "$rfile"
      sed -i -E 's/^([^#].*icmp-host-prohibited.*)$/# \1/' "$rfile"
      log_info "$(_t "SERVER_UFW_INFO_NEUTRALIZED_RULE" "${rfile}")"
    fi
  done

  log_success "$(_t "SERVER_UFW_SUCCESS")"
  return 0
}

# Module 4: SSH Hardening (With SUDO_USER check & sshd_config.d protection)
setup_ssh_hardening() {
  local skip_check="${1:-false}"
  local dry_run="${2:-false}"
  # 因沒有金鑰而略過時設為 1（回傳 0 但沒有套用，server -harden 不計入已套用）
  SSH_HARDEN_SKIPPED=0

  log_step "$(_t "SERVER_SSH_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_SSH_INFO_DRY_RUN")"
    return 0
  fi

  # 1. 不放寬既有設定：目前生效的 PermitRootLogin 比 prohibit-password 嚴格時沿用
  local root_login="prohibit-password" cur_root_login
  ssh_prepare_privsep
  cur_root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2; exit }' || true)
  if [[ "$cur_root_login" == "no" || "$cur_root_login" == "forced-commands-only" ]]; then
    root_login="$cur_root_login"
    log_info "$(_t "SERVER_SSH_INFO_KEEP_ROOT_LOGIN" "$cur_root_login")"
  fi

  # 2. 鎖死檢查：實際操作的帳號（sudo 的 SUDO_USER，或直接登入的 root）必須有可用的金鑰；
  #    root 不允許 SSH 登入（沿用 no／forced-commands-only）時，root 的金鑰不算（可能是 su - 之後執行）
  local operator_ok=true
  ssh_operator_has_key || operator_ok=false
  if [[ "$operator_ok" == "true" && "$SSH_OPERATOR" == "root" && "$root_login" != "prohibit-password" ]]; then
    operator_ok=false
  fi
  if [[ "$operator_ok" != "true" ]]; then
    # 若為非互動模式 (-y / --yes / CLP_AUTO_YES / --non-interactive)，強制安全略過，絕對不可自動停用密碼登入導致反鎖！
    if [[ "${CLP_AUTO_YES:-false}" == "true" ]] || has_opt "y" || has_opt "yes" || has_opt "non_interactive" || has_opt "non-interactive"; then
      log_warn "======================================================================"
      log_warn "$(_t "SERVER_SSH_WARN_NO_KEY_AUTO_SKIP_1")"
      log_warn "$(_t "SERVER_SSH_WARN_NO_KEY_AUTO_SKIP_2")"
      log_warn "$(_t "SERVER_SSH_WARN_NO_KEY_AUTO_SKIP_3")"
      log_warn "$(_t "SERVER_SSH_WARN_OPERATOR" "$SSH_OPERATOR")"
      log_warn "======================================================================"
      SSH_HARDEN_SKIPPED=1
      return 0
    fi

    if [[ "$skip_check" != "true" ]]; then
      log_warn "======================================================================"
      log_warn "$(_t "SERVER_SSH_WARN_NO_KEY_PROMPT_1")"
      log_warn "$(_t "SERVER_SSH_WARN_NO_KEY_PROMPT_2")"
      log_warn "$(_t "SERVER_SSH_WARN_OPERATOR" "$SSH_OPERATOR")"
      log_warn "======================================================================"
      if ! prompt_confirm "$(_t "SERVER_SSH_PROMPT_FORCE_DISABLE")" "n"; then
        log_warn "$(_t "SERVER_SSH_WARN_CANCELLED_LOCKOUT")"
        SSH_HARDEN_SKIPPED=1
        return 0
      fi
    fi
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    log_info "$(_t "SERVER_SSH_INFO_SUDO_KEY_DETECTED" "${SUDO_USER}")"
  fi

  local sshd_config="/etc/ssh/sshd_config"
  if [[ ! -f "$sshd_config" ]]; then
    log_error "$(_t "SERVER_SSH_ERR_CONFIG_NOT_FOUND" "$sshd_config")"
    return 1
  fi

  # 3. 修改前快照 sshd_config 與 sshd_config.d/，語法檢查失敗時全部還原
  backup_file "$sshd_config"
  local snap
  if ! snap=$(ssh_config_snapshot); then
    log_error "$(_t "SERVER_SSH_ERR_SNAPSHOT")"
    return 1
  fi

  # 清理任何先前的緊急復原 drop-in 與設定
  rm -f "/etc/ssh/sshd_config.d/00-clp-emergency.conf"
  local changed_ok=true
  remove_marked_block "$sshd_config" "# === CloudPanel Emergency Unharden ===" "# === End CloudPanel Emergency Unharden ===" || changed_ok=false

  local settings="PermitRootLogin ${root_login}
PasswordAuthentication no
KbdInteractiveAuthentication no"

  # 處理 Ubuntu/Debian 雲端主機 /etc/ssh/sshd_config.d/ 覆蓋問題 (如 50-cloud-init.conf)
  if [[ "$changed_ok" == "true" && -d "/etc/ssh/sshd_config.d" ]]; then
    local dropin_file="/etc/ssh/sshd_config.d/01-clp-hardening.conf"
    log_info "$(_t "SERVER_SSH_INFO_APPLYING")"
    ssh_write_file "$dropin_file" "# === CloudPanel Hardening Drop-in ===
${settings}
# === End CloudPanel Hardening ===" || changed_ok=false

    # 同步中和 50-cloud-init.conf 等衝突項：只改 Match 區塊之前的全域設定，
    # Match 區塊中的 PasswordAuthentication yes 通常是刻意的例外（例如只允許內網），保留並提示
    local conf tmp_conf
    for conf in /etc/ssh/sshd_config.d/*.conf; do
      [[ "$changed_ok" == "true" && -f "$conf" && "$conf" != "$dropin_file" ]] || continue
      grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$conf" 2>/dev/null || continue
      backup_file "$conf"
      tmp_conf=$(mktemp "${conf}.tmp.XXXXXX") || { changed_ok=false; break; }
      awk '
        tolower($0) ~ /^[[:space:]]*match[[:space:]]/ { in_match = 1 }
        !in_match && tolower($0) ~ /^[[:space:]]*passwordauthentication[[:space:]]+yes/ { print "PasswordAuthentication no"; next }
        { print }' "$conf" > "$tmp_conf" && atomic_replace "$tmp_conf" "$conf" || changed_ok=false
      rm -f "$tmp_conf"
      log_info "$(_t "SERVER_SSH_INFO_FIXED_OVERRIDE" "${conf}")"
      if awk 'tolower($0) ~ /^[[:space:]]*match[[:space:]]/ { m = 1 } m && tolower($0) ~ /^[[:space:]]*passwordauthentication[[:space:]]+yes/ { f = 1 } END { exit !f }' "$conf"; then
        log_warn "$(_t "SERVER_SSH_WARN_MATCH_PASSWORD_KEPT" "${conf}")"
      fi
    done
  fi

  # 更新主設定檔 /etc/ssh/sshd_config（寫在第一個 Match 之前；沒有 Match 時寫在開頭）
  if [[ "$changed_ok" == "true" ]]; then
    remove_marked_block "$sshd_config" "# === CloudPanel Hardening Settings ===" "# === End CloudPanel Hardening ===" || changed_ok=false
  fi
  if [[ "$changed_ok" == "true" ]]; then
    ssh_insert_block "$sshd_config" "# === CloudPanel Hardening Settings ===
${settings}
# === End CloudPanel Hardening ===" || changed_ok=false
  fi

  # 驗證語法；任何一步失敗都還原快照
  log_info "$(_t "SERVER_SSH_INFO_TESTING")"
  local sshd_err=""
  if [[ "$changed_ok" != "true" ]] || ! sshd_err=$(ssh_config_test); then
    log_error "$(_t "SERVER_SSH_ERR_SYNTAX_FAILED" "${sshd_err}")"
    log_error "$(_t "SERVER_SSH_ERR_REVERTING")"
    if ssh_config_restore "$snap"; then
      rm -rf "$snap"
    else
      log_error "$(_t "SERVER_SSH_ERR_RESTORE" "$snap")"
    fi
    return 1
  fi
  rm -rf "$snap"

  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

  # 驗證最終生效狀態
  local active_passauth
  active_passauth=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}' || true)
  if [[ "$active_passauth" == "no" ]]; then
    log_success "$(_t "SERVER_SSH_SUCCESS")"
  else
    log_warn "$(_t "SERVER_SSH_WARN_PASSAUTH_STILL_ACTIVE" "${active_passauth}")"
  fi

  return 0
}

# Module 5: Fail2ban
setup_fail2ban() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_F2B_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_F2B_INFO_DRY_RUN")"
    return 0
  fi

  apt-get -o DPkg::Lock::Timeout=60 install -y fail2ban
  local active_ssh_port
  active_ssh_port=$(sshd -T 2>/dev/null | grep -i '^port[[:space:]]' | head -n1 | awk '{print $2}' || true)
  [[ -z "$active_ssh_port" ]] && active_ssh_port="ssh"

  local jail_local="/etc/fail2ban/jail.local"
  if [[ ! -f "$jail_local" ]]; then
    log_info "$(_t "SERVER_F2B_INFO_CONFIGURING")"
    # UFW 未啟用時 banaction=ufw 不會有效封鎖，改用 iptables
    local f2b_banaction="iptables-multiport" f2b_ufw_out=""
    command -v iptables >/dev/null 2>&1 || f2b_banaction="nftables-multiport"
    if command -v ufw >/dev/null 2>&1; then
      f2b_ufw_out=$(LC_ALL=C ufw status 2>/dev/null || true)
      grep -q "Status: active" <<< "$f2b_ufw_out" && f2b_banaction="ufw"
    fi
    cat <<EOF > "$jail_local"
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ${f2b_banaction}

[sshd]
enabled = true
port    = ${active_ssh_port}
logpath = %(sshd_log)s
backend = %(default_backend)s
EOF
  else
    if grep -q '^\[sshd\]' "$jail_local" 2>/dev/null; then
      if sed -n '/^\[sshd\]/,/^\[/p' "$jail_local" | grep -q '^[[:space:]]*port[[:space:]]*='; then
        sed -i "/^\[sshd\]/,/^\[/ s|^[[:space:]]*port[[:space:]]*=.*|port    = ${active_ssh_port}|" "$jail_local"
      else
        sed -i "/^\[sshd\]/a port    = ${active_ssh_port}" "$jail_local"
      fi
    fi
  fi

  systemctl enable fail2ban 2>/dev/null || true
  if ! systemctl restart fail2ban 2>/dev/null; then
    log_error "$(_t "SERVER_F2B_ERR_RESTART")"
    return 1
  fi
  log_success "$(_t "SERVER_F2B_SUCCESS")"
  return 0
}

# Module 6: DNS Configuration
setup_dns() {
  local provider="${1:-auto}"
  local dry_run="${2:-false}"

  log_step "$(_t "SERVER_DNS_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_DNS_INFO_DRY_RUN" "${provider}")"
    return 0
  fi

  # 寫在 drop-in（resolved.conf.d/99-clp.conf），不改套件的 resolved.conf（改了 conffile 會讓升級時 dpkg 詢問）
  local resolved_dropin_dir="/etc/systemd/resolved.conf.d"
  local resolved_dropin="${resolved_dropin_dir}/99-clp.conf"
  # 沒有 systemd-resolved（例如 Debian 12、部分 LXC）：與舊版相同，警告後略過，不算失敗
  if ! command -v resolvectl >/dev/null 2>&1 && [[ ! -f /etc/systemd/resolved.conf ]]; then
    log_warn "$(_t "SERVER_DNS_WARN_CONF_NOT_FOUND" "/etc/systemd/resolved.conf")"
    return 0
  fi

  local primary_dns="8.8.8.8 8.8.4.4"
  local fallback_dns="1.1.1.1 1.0.0.1"

  case "$provider" in
    cloudflare)
      primary_dns="1.1.1.1 1.0.0.1"
      fallback_dns="8.8.8.8 8.8.4.4"
      ;;
    google)
      primary_dns="8.8.8.8 8.8.4.4"
      fallback_dns="1.1.1.1 1.0.0.1"
      ;;
    *)
      primary_dns="8.8.8.8 8.8.4.4"
      fallback_dns="1.1.1.1 1.0.0.1"
      ;;
  esac

  # 目錄固定 755：umask 077 時 systemd-resolved（以 systemd-resolve 身分執行）讀不到 drop-in
  install -d -m 0755 "$resolved_dropin_dir"
  [[ -f "$resolved_dropin" ]] && backup_file "$resolved_dropin"
  local tmp_resolved
  tmp_resolved=$(mktemp) || return 1
  # DNS=／FallbackDNS= 是清單，drop-in 會「附加」在 resolved.conf 的值後面：先以空值清空再設定
  printf '# Managed by CLP Helper (clp server -dns)\n[Resolve]\nDNS=\nDNS=%s\nFallbackDNS=\nFallbackDNS=%s\n' "$primary_dns" "$fallback_dns" > "$tmp_resolved"
  chmod 644 "$tmp_resolved"
  if ! atomic_replace "$tmp_resolved" "$resolved_dropin"; then
    rm -f "$tmp_resolved"
    return 1
  fi
  rm -f "$tmp_resolved"

  systemctl restart systemd-resolved 2>/dev/null || true
  log_success "$(_t "SERVER_DNS_SUCCESS" "${primary_dns}" "${fallback_dns}")"
  return 0
}

# Module 7: Sysctl Optimizations
setup_sysctl() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_SYSCTL_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_SYSCTL_INFO_DRY_RUN")"
    return 0
  fi

  local dropin_dir="/etc/sysctl.d"
  local dropin_file="${dropin_dir}/99-clp.conf"

  mkdir -p "$dropin_dir"
  [[ -f "$dropin_file" ]] && backup_file "$dropin_file"

  local tmp_dropin
  tmp_dropin=$(mktemp "${dropin_dir}/.99-clp.XXXXXX")
  # 不設定 fs.file-max：systemd 開機時已設為最大值，舊版寫入的 500000 反而會調低上限
  cat <<'EOF' > "$tmp_dropin"
# === CloudPanel Sysctl Optimizations ===
vm.swappiness = 10
EOF
  chmod 644 "$tmp_dropin"
  if ! atomic_replace "$tmp_dropin" "$dropin_file"; then
    rm -f "$tmp_dropin"
    return 1
  fi
  rm -f "$tmp_dropin"

  sysctl --system >/dev/null 2>&1 || true
  # 舊版設定的 500000 在重新開機前仍有效，恢復 systemd 的預設值
  if [[ "$(sysctl -n fs.file-max 2>/dev/null)" == "500000" ]]; then
    sysctl -qw fs.file-max=9223372036854775807 2>/dev/null || true
  fi
  log_success "$(_t "SERVER_SYSCTL_SUCCESS")"
  return 0
}

# Module 8: Journald Log Size Limit
setup_journald() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_JOURNALD_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_JOURNALD_INFO_DRY_RUN")"
    return 0
  fi

  # 寫在 drop-in（journald.conf.d/99-clp.conf），不改套件的 journald.conf（改了 conffile 會讓升級時 dpkg 詢問）
  local journal_dropin_dir="/etc/systemd/journald.conf.d"
  local journal_dropin="${journal_dropin_dir}/99-clp.conf"
  if ! command -v journalctl >/dev/null 2>&1; then
    log_warn "$(_t "SERVER_JOURNALD_WARN_CONF_NOT_FOUND" "/etc/systemd/journald.conf")"
    return 0
  fi
  install -d -m 0755 "$journal_dropin_dir"
  [[ -f "$journal_dropin" ]] && backup_file "$journal_dropin"
  local tmp_journal
  tmp_journal=$(mktemp) || return 1
  printf '# Managed by CLP Helper (clp server -harden)\n[Journal]\nSystemMaxUse=500M\n' > "$tmp_journal"
  chmod 644 "$tmp_journal"
  if ! atomic_replace "$tmp_journal" "$journal_dropin"; then
    rm -f "$tmp_journal"
    return 1
  fi
  rm -f "$tmp_journal"

  systemctl restart systemd-journald.service 2>/dev/null || true
  log_success "$(_t "SERVER_JOURNALD_SUCCESS")"
  return 0
}

# Module 9: Unattended Upgrades
setup_unattended_upgrades() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_AUTOUP_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_AUTOUP_INFO_DRY_RUN")"
    return 0
  fi

  apt-get -o DPkg::Lock::Timeout=60 install -y unattended-upgrades
  if command -v debconf-set-selections >/dev/null 2>&1; then
    debconf-set-selections <<< "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" 2>/dev/null || \
    ( echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections 2>/dev/null ) || true
  else
    log_warn "$(_t "SERVER_AUTOUP_WARN_DEBCONF_NOT_FOUND")"
  fi
  dpkg-reconfigure -f noninteractive -plow unattended-upgrades 2>/dev/null || true
  log_success "$(_t "SERVER_AUTOUP_SUCCESS")"
  return 0
}

# Module 10: Snap Retention Limit
setup_snap_retention() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_SNAP_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_SNAP_INFO_DRY_RUN")"
    return 0
  fi

  if command -v snap >/dev/null 2>&1; then
    snap set system refresh.retain=2 2>/dev/null || true
    log_success "$(_t "SERVER_SNAP_SUCCESS")"
  else
    log_info "$(_t "SERVER_SNAP_INFO_NOT_FOUND")"
  fi
  return 0
}

# Module 11: PHP Timezone Synchronization
setup_php_timezone() {
  local target_tz="${1:-Asia/Taipei}"
  local dry_run="${2:-false}"

  log_step "$(_t "SERVER_PHPTZ_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_PHPTZ_INFO_DRY_RUN" "${target_tz}")"
    return 0
  fi

  local php_ini_found=false
  for ini in /etc/php/*/cli/php.ini /etc/php/*/fpm/php.ini; do
    if [[ -f "$ini" ]]; then
      php_ini_found=true
      sed -i "s|^;*date.timezone = .*|date.timezone = ${target_tz}|" "$ini"
    fi
  done

  if [[ "$php_ini_found" == "true" ]]; then
    for svc in $(systemctl list-unit-files 2>/dev/null | grep -oE 'php[0-9.]+-fpm\.service' || true); do
      # reload（USR2）會重新讀取 php.ini，不中斷進行中的請求；沒有執行中的服務 reload 失敗，維持停止
      systemctl reload "$svc" 2>/dev/null || true
    done
    log_success "$(_t "SERVER_PHPTZ_SUCCESS" "${target_tz}")"
  else
    log_warn "$(_t "SERVER_PHPTZ_WARN_NO_PHP_DIR")"
  fi
  return 0
}

# Module 12: Nginx Custom Security Rules
setup_nginx_security() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_NGINX_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_NGINX_INFO_DRY_RUN")"
    return 0
  fi

  # CloudPanel 的網站 vhost 在後端 (8080) server 區塊中 include /etc/nginx/global_settings（server context），
  # 因此將規則寫入獨立檔案，再由 global_settings include，即可套用到所有網站。
  local global_settings="/etc/nginx/global_settings"
  local target_file="/etc/nginx/clp-security.conf"
  local include_line="include ${target_file}; # CLP Security Rules"
  local marker="# === CloudPanel Custom Security Rules ==="

  if [[ ! -f "$global_settings" ]]; then
    log_warn "$(_t "SERVER_NGINX_INFO_DIR_NOT_FOUND")"
    return 0
  fi

  if [[ -f "$target_file" ]] && grep -q "$marker" "$target_file" && grep -qF "$include_line" "$global_settings"; then
    log_info "$(_t "SERVER_NGINX_INFO_ALREADY_EXISTS" "$target_file")"
    return 0
  fi

  backup_file "$global_settings"
  local gs_backup
  gs_backup=$(mktemp)
  cp -p "$global_settings" "$gs_backup"
  local target_existed=false
  local target_backup=""
  if [[ -f "$target_file" ]]; then
    target_existed=true
    target_backup=$(mktemp)
    cp -p "$target_file" "$target_backup"
  fi

  # 清除舊版直接寫入 global_settings 的規則區塊
  remove_marked_block "$global_settings" "# === CloudPanel Custom Security Rules ===" "# === End CloudPanel Custom Security Rules ===" || {
    rm -f "$gs_backup" "$target_backup"
    return 1
  }

  log_info "$(_t "SERVER_NGINX_INFO_WRITING")"
  local tmp_sec
  tmp_sec=$(mktemp "$(dirname "$target_file")/.clp-sec.XXXXXX")
  cat <<'EOF' > "$tmp_sec"
# === CloudPanel Custom Security Rules ===
# Managed by CLP Helper (clp server -harden). Included from /etc/nginx/global_settings.
location ~ /\.user\.ini$ {
    deny all;
}

location ~* /wp-content/debug\.log$ {
    deny all;
}

# Database dumps left behind by older CLP Helper full backups
location ~ /\.clp_db_export\.sql$ {
    deny all;
}
# === End CloudPanel Custom Security Rules ===
EOF
  chmod 644 "$tmp_sec"
  atomic_replace "$tmp_sec" "$target_file"
  rm -f "$tmp_sec"

  if ! grep -qF "$include_line" "$global_settings"; then
    # 確保檔案以換行結尾，再附加 include
    [[ -s "$global_settings" && -n "$(tail -c1 "$global_settings")" ]] && echo "" >> "$global_settings"
    echo "$include_line" >> "$global_settings"
  fi

  if command -v nginx >/dev/null 2>&1; then
    local nginx_err
    if nginx_err=$(nginx -t 2>&1); then
      systemctl reload nginx 2>/dev/null || true
      log_success "$(_t "SERVER_NGINX_SUCCESS")"
    else
      log_error "$(_t "SERVER_NGINX_ERR_TEST_FAILED" "${nginx_err}")"
      log_error "$(_t "SERVER_NGINX_ERR_REVERTING")"
      cp -p "$gs_backup" "$global_settings"
      if [[ "$target_existed" == "true" ]]; then
        cp -p "$target_backup" "$target_file"
      else
        rm -f "$target_file"
      fi
      rm -f "$gs_backup" "$target_backup"
      return 1
    fi
  fi

  # 舊版寫入的 /etc/nginx/common/security.conf 從未被 include，予以清除
  if [[ -f /etc/nginx/common/security.conf ]] && grep -q "$marker" /etc/nginx/common/security.conf 2>/dev/null; then
    rm -f /etc/nginx/common/security.conf
    rmdir /etc/nginx/common 2>/dev/null || true
  fi

  rm -f "$gs_backup" "$target_backup"
  return 0
}

# Module 13: Postfix SMTP Relay
setup_smtp() {
  local relay_host="${1:-}"
  local relay_port="${2:-587}"
  local smtp_user="${3:-}"
  local smtp_pass="${4:-}"
  local dry_run="${5:-false}"

  log_step "$(_t "SERVER_SMTP_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_SMTP_INFO_DRY_RUN" "${relay_host:-smtp.example.com}" "${relay_port}")"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=60 install -y mailutils libsasl2-modules postfix

  # 若未傳入參數且為互動環境，提示使用者輸入
  if [[ -z "$relay_host" && -t 0 && "${CLP_AUTO_YES:-false}" != "true" ]]; then
    echo ""
    echo "$(_t "SERVER_SMTP_PROMPT_CONFIG_HEADER")"
    # 讀到 EOF（Ctrl-D）一律視為取消；這些提示都在修改設定之前
    read -r -p "$(_t "SERVER_SMTP_PROMPT_HOST")" relay_host || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
    if [[ -n "$relay_host" ]]; then
      read -r -p "$(_t "SERVER_SMTP_PROMPT_PORT")" input_port || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      relay_port="${input_port:-587}"
      read -r -p "$(_t "SERVER_SMTP_PROMPT_USER")" smtp_user || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      read -s -r -p "$(_t "SERVER_SMTP_PROMPT_PASS")" smtp_pass || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      echo ""
    fi
  fi

  local main_cf="/etc/postfix/main.cf"
  if [[ -f "$main_cf" ]]; then
    backup_file "$main_cf"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "smtputf8_enable = no"
    postconf -e "default_transport = smtp"
    postconf -e "bounce_queue_lifetime = 1h"

    # 465 為 implicit TLS（SMTPS），需要 wrappermode 並強制加密
    if [[ -n "$relay_host" ]]; then
      if [[ "$relay_port" == "465" ]]; then
        postconf -e "smtp_tls_wrappermode = yes"
      else
        postconf -e "smtp_tls_wrappermode = no"
      fi
    fi

    if [[ -n "$relay_host" && ( -z "$smtp_user" || -z "$smtp_pass" ) ]]; then
      # 不需驗證的轉送主機（只填主機）
      postconf -e "relayhost = [${relay_host}]:${relay_port}"
      postconf -e "smtp_sasl_auth_enable = no"
      if [[ "$relay_port" == "465" ]]; then
        postconf -e "smtp_tls_security_level = encrypt"
      else
        postconf -e "smtp_tls_security_level = may"
      fi
      log_info "$(_t "SERVER_SMTP_INFO_CONFIGURING" "${relay_host}" "${relay_port}")"
    elif [[ -n "$relay_host" && -n "$smtp_user" && -n "$smtp_pass" ]]; then
      local sasl_passwd_file="/etc/postfix/sasl_passwd"
      # 以 umask 077 建立，避免密碼在 chmod 前短暫可被其他使用者讀取
      ( umask 077; echo "[${relay_host}]:${relay_port} ${smtp_user}:${smtp_pass}" > "$sasl_passwd_file" )
      chmod 600 "$sasl_passwd_file"
      postmap "$sasl_passwd_file" 2>/dev/null || true
      [[ -f "${sasl_passwd_file}.db" ]] && chmod 600 "${sasl_passwd_file}.db"

      postconf -e "relayhost = [${relay_host}]:${relay_port}"
      postconf -e "smtp_sasl_auth_enable = yes"
      postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
      postconf -e "smtp_sasl_security_options = noanonymous"
      # 有帳密時強制 TLS，避免密碼以明文送出
      postconf -e "smtp_tls_security_level = encrypt"
      log_info "$(_t "SERVER_SMTP_INFO_CONFIGURING" "${relay_host}" "${relay_port}")"
    fi
  fi

  # 靜音本機吵鬧的背景守護行程郵件 (例如 www-data 產生的 cron 失敗等)
  # 只比對寄往本機的收件者，寫在獨立檔案，不覆蓋使用者自己的 /etc/postfix/transport
  if [[ -d /etc/postfix ]]; then
    local transport_file="/etc/postfix/clp_transport"
    local old_transport="/etc/postfix/transport"
    local old_header="# Discard system background daemon noisy emails"
    local local_hosts="localhost" h
    for h in "$(postconf -h myhostname 2>/dev/null || true)" "$(cat /etc/mailname 2>/dev/null || true)"; do
      [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || continue
      local_hosts+="|${h//./\\.}"
    done
    local tmp_transport
    tmp_transport=$(mktemp "/etc/postfix/.clp_transport.XXXXXX")
    {
      echo "# Managed by clp: discard noisy local daemon mail (local recipients only)"
      printf '/^(www-data|localhost|wordpress)(@(%s))?$/ discard:\n' "$local_hosts"
    } > "$tmp_transport"
    chmod 644 "$tmp_transport"
    if atomic_replace "$tmp_transport" "$transport_file"; then
      # 保留既有的 transport_maps，移除舊版指向 /etc/postfix/transport 的設定（只在該檔是舊版 clp 寫的時候）
      local maps="" item new_maps="regexp:${transport_file}"
      local -a map_items=()
      maps=$(postconf -h transport_maps 2>/dev/null || true)
      IFS=', ' read -r -a map_items <<< "$maps"
      for item in ${map_items[@]+"${map_items[@]}"}; do
        [[ -z "$item" ]] && continue
        [[ "$item" == "regexp:${transport_file}" ]] && continue
        if [[ "$item" == "regexp:${old_transport}" ]] && [[ "$(head -n1 "$old_transport" 2>/dev/null)" == "$old_header" ]]; then
          continue
        fi
        new_maps+=", ${item}"
      done
      postconf -e "transport_maps = ${new_maps}" 2>/dev/null || true
    fi
    rm -f "$tmp_transport"
  fi

  systemctl restart postfix 2>/dev/null || true
  log_success "$(_t "SERVER_SMTP_SUCCESS")"
  return 0
}

# Module 14: Certbot (With Cloudflare DNS & Template)
setup_certbot() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_CERTBOT_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_CERTBOT_INFO_DRY_RUN")"
    return 0
  fi

  # 複用 core.sh 的完整建置邏輯
  check_certbot || return 1
  ensure_certbot_renew_cron

  # 建立憑證金鑰範本檔
  mkdir -p /root/.secrets && chmod 700 /root/.secrets
  # 範本檔不使用 .ini 副檔名：clp 會掃描 .secrets/*.ini 尋找 token，佔位字串不可被當成真的 token
  local cf_ini="/root/.secrets/cloudflare.ini.example"
  if [[ ! -f "$cf_ini" ]] && ! compgen -G "/root/.secrets/*.ini" >/dev/null; then
    (
      umask 077
      cat <<'EOF' > "$cf_ini"
# Cloudflare API Token for Certbot DNS-01 Challenge
# 請至 Cloudflare 建立 Token (權限需包含: Zone - DNS - Edit)
dns_cloudflare_api_token = YOUR_CLOUDFLARE_API_TOKEN_HERE
EOF
    )
    log_info "$(_t "SERVER_CERTBOT_INFO_TEMPLATE_CREATED")"
  fi

  log_success "$(_t "SERVER_CERTBOT_SUCCESS")"
  return 0
}

# Module 15: Netdata Real-time Monitoring
setup_netdata() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_NETDATA_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_NETDATA_INFO_DRY_RUN")"
    return 0
  fi

  log_info "$(_t "SERVER_NETDATA_INFO_INSTALLING")"
  local kickstart_tmp
  kickstart_tmp=$(mktemp /tmp/netdata-kickstart.XXXXXX)
  if curl -fsSL --connect-timeout 15 --max-time 300 https://get.netdata.cloud/kickstart.sh -o "$kickstart_tmp"; then
    local ks_rc=0
    sh "$kickstart_tmp" --non-interactive --stable-channel 2>&1 || ks_rc=$?
    rm -f "$kickstart_tmp"
    if [[ "$ks_rc" -ne 0 ]] || ! { command -v netdata >/dev/null 2>&1 || systemctl list-unit-files netdata.service >/dev/null 2>&1; }; then
      log_error "$(_t "SERVER_NETDATA_ERR_FAILED")"
      return 1
    fi
  else
    rm -f "$kickstart_tmp"
    log_warn "$(_t "SERVER_NETDATA_ERR_FAILED")"
    return 1
  fi

  # 配置 Netdata 主機名稱
  local netdata_conf="/etc/netdata/netdata.conf"
  if [[ -d /etc/netdata ]]; then
    if command -v netdatacli >/dev/null 2>&1 && [[ ! -f "$netdata_conf" ]]; then
      netdatacli dumpconfig > "$netdata_conf" 2>/dev/null || true
    fi
    if [[ -f "$netdata_conf" ]]; then
      sed -i "s|^[[:space:]]*hostname = .*|hostname = $(hostname)|" "$netdata_conf" 2>/dev/null || true
    fi
    systemctl restart netdata 2>/dev/null || true
  fi

  log_success "$(_t "SERVER_NETDATA_SUCCESS" "$(get_server_ip)")"

  # 主動檢查 UFW 狀態並給予 19999 放行提醒
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q "Status: active"; then
    echo ""
    log_warn "$(_t "SERVER_NETDATA_WARN_UFW" "$(get_server_ip)")"
    echo ""
  else
    # 沒有啟用 UFW：Netdata 預設監聽 0.0.0.0:19999 且不需登入，任何人都能看到行程、使用者與服務資訊
    echo ""
    log_warn "$(_t "SERVER_NETDATA_WARN_EXPOSED" "$(get_server_ip)")"
    echo ""
  fi

  return 0
}

# Module 16: Rclone Cloud Storage
setup_rclone() {
  local dry_run="${1:-false}"
  log_step "$(_t "SERVER_RCLONE_STEP")"
  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_RCLONE_INFO_DRY_RUN")"
    return 0
  fi

  check_rclone || return 1
  mkdir -p /root/.config/rclone
  log_success "$(_t "SERVER_RCLONE_SUCCESS")"
  return 0
}

# ------------------------------------------------------------------------------
# 2.8 Dynamic Database Engines Resolver (Online Sync + OS-Aware Fallback)
# ------------------------------------------------------------------------------
CUSTOM_CLP_CHECKSUM=""
CACHED_AVAILABLE_DB_ENGINES=()

load_available_db_engines() {
  # 若同一次執行中已載入過資料庫引擎清單，直接回傳
  if [[ ${#CACHED_AVAILABLE_DB_ENGINES[@]} -gt 0 ]]; then
    return 0
  fi

  local os_id="" os_ver=""
  if [[ -f /etc/os-release ]]; then
    os_id=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || true)
    os_ver=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || true)
  fi

  local os_target="${os_id} ${os_ver}"
  local engines=()

  # --dry-run 或系統已安裝 CloudPanel 時不需要連網
  local skip_network=false
  if has_opt "dry_run" || has_opt "dry-run" || command -v clpctl >/dev/null 2>&1; then
    skip_network=true
  fi

  local html=""
  if [[ "$skip_network" == "false" ]]; then
    html=$(curl -fsSL --connect-timeout 4 --max-time 15 "$CLP_DOCS_URL" 2>/dev/null || true)
  fi

  if [[ -n "$html" ]] && command -v python3 >/dev/null 2>&1; then
    while IFS= read -r eng; do
      [[ -n "$eng" ]] && engines+=("$eng")
    done < <(python3 -I -c '
import sys, re
os_target = sys.argv[1].lower()
html = sys.stdin.read()
tabs = re.findall(r"<li[^>]*class=\"[^\"]*tabs__item[^\"]*\"[^>]*>([^<]+)</li>", html)
panels = re.findall(r"<div role=\"tabpanel\"[^>]*>(.*?)</div></div></div></div>", html, re.DOTALL)
matched = []
for tab_name, panel in zip(tabs[:len(panels)], panels):
    if os_target in tab_name.lower():
        matched = re.findall(r"DB_ENGINE=([A-Z0-9_.]+)", panel)
        break
seen = set()
for x in matched:
    if x not in seen:
        seen.add(x)
        print(x)
' "$os_target" <<< "$html" 2>/dev/null || true)
  fi

  # 若線上解析為空 (或略過連網／無 python3)，依作業系統版本提供標準相容備援
  if [[ ${#engines[@]} -eq 0 ]]; then
    case "$os_ver" in
      22.04)
        engines=("MYSQL_8.0" "MARIADB_11.4" "MARIADB_10.11" "MARIADB_10.6")
        ;;
      24.04|12*)
        engines=("MYSQL_8.4" "MYSQL_8.0" "MARIADB_12.3" "MARIADB_11.4" "MARIADB_10.11")
        ;;
      26.04|13*)
        engines=("MYSQL_8.4" "MARIADB_12.3" "MARIADB_11.8")
        ;;
      *)
        engines=("MYSQL_8.4" "MARIADB_11.4" "MARIADB_10.11" "MARIADB_12.3" "MYSQL_8.0" "MARIADB_11.8" "MARIADB_10.6")
        ;;
    esac
  fi

  CACHED_AVAILABLE_DB_ENGINES=("${engines[@]}")
}

fetch_available_db_engines() {
  load_available_db_engines
  for e in "${CACHED_AVAILABLE_DB_ENGINES[@]}"; do
    echo "$e"
  done
}

# ------------------------------------------------------------------------------
# 2.9 Handle Official Command Paste (Robust Multi-line Paste Accumulator)
# ------------------------------------------------------------------------------
handle_paste_official_command() {
  clear 2>/dev/null || true
  echo "=============================================================================="
  echo -e " ${C_BOLD}$(_t "SERVER_PASTE_TITLE")${C_NC}"
  echo "=============================================================================="
  echo " $(_t "SERVER_INSTALL_COL_DESC"):"
  echo "$(_t "SERVER_PASTE_DESC_1" "${CLP_DOCS_URL}")"
  echo "$(_t "SERVER_PASTE_DESC_2")"
  echo "$(_t "SERVER_PASTE_DESC_3")"
  echo "=============================================================================="
  echo ""

  local pasted=""
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r')

    # 若第一行就是 b、q 或空白，代表使用者取消
    if [[ -z "$pasted" ]]; then
      if [[ -z "$line" || "$line" == "b" || "$line" == "q" ]]; then
        echo "$(_t "SERVER_PASTE_CANCELLED")"
        sleep 0.5
        return 2   # 2 = 使用者取消（與成功的 0、解析失敗的 1 區分）
      fi
    fi

    pasted+="$line"$'\n'

    # 若行尾有反斜線 (\)，代表 Shell 指令續行尚未結束，繼續等待下一行
    local trimmed
    trimmed=$(echo "$line" | sed 's/[[:space:]]*$//')
    if [[ "$trimmed" =~ \\$ ]]; then
      continue
    fi

    # 若行尾沒有反斜線，但輸入緩衝區內仍有瞬間連續送達的殘留行（如多行同時貼上），迅速收集
    local t_drain="1"
    (( BASH_VERSINFO[0] >= 4 )) && t_drain="0.05"
    while read -t "$t_drain" -r extra_line || [[ -n "$extra_line" ]]; do
      extra_line=$(echo "$extra_line" | tr -d '\r')
      pasted+="$extra_line"$'\n'
    done
    break
  done

  local extracted_csum extracted_db
  extracted_csum=$(echo "$pasted" | grep -oE '[a-f0-9]{64}' | head -n 1 || true)
  extracted_db=$(echo "$pasted" | grep -oE 'DB_ENGINE=[A-Z0-9_.]+' | cut -d'=' -f2 | head -n 1 || true)

  if [[ -z "$extracted_db" ]]; then
    local trimmed
    trimmed=$(echo "$pasted" | tr '[:lower:]' '[:upper:]' | grep -oE '(MYSQL|MARIADB)[A-Z0-9_.]+' | head -n 1 || true)
    [[ -n "$trimmed" ]] && extracted_db="$trimmed"
  fi

  if [[ -n "$extracted_db" ]]; then
    db_engine=$(normalize_db_engine "$extracted_db")
    if [[ -n "$extracted_csum" ]]; then
      CUSTOM_CLP_CHECKSUM="$extracted_csum"
    fi
    echo ""
    echo -e "${C_GREEN}$(_t "SERVER_PASTE_SUCCESS")${C_NC}"
    echo -e "$(_t "SERVER_PASTE_DB_ENGINE" "$(format_db_engine_label "$db_engine")" "${db_engine}")"
    if [[ -n "$extracted_csum" ]]; then
      echo -e "$(_t "SERVER_PASTE_CHECKSUM" "${extracted_csum}")"
    fi
    sleep 1.2
    return 0
  else
    echo ""
    echo -e "${C_RED}$(_t "SERVER_PASTE_ERR_NOT_FOUND")${C_NC}"
    echo -e "${C_DIM}$(_t "SERVER_PASTE_PREVIEW")${C_NC}"
    echo "$pasted" | head -n 5
    echo ""
    read -r -p "$(echo -e "${C_YELLOW}$(_t "SERVER_PASTE_PROMPT_RETURN")${C_NC}")" _ || true
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 2.10 Interactive Database Engine Selector (Dynamic + Paste Support)
# ------------------------------------------------------------------------------
select_db_engine_interactive() {
  local mode="${1:-normal}"
  local cur="${db_engine:-MYSQL_8.4}"
  local selected="$cur"

  local os_desc="Linux"
  if [[ -f /etc/os-release ]]; then
    os_desc=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "Linux")
  fi

  # 動態擷取適用於本機 OS 的官方支援資料庫版本
  load_available_db_engines
  local dyn_engines=("${CACHED_AVAILABLE_DB_ENGINES[@]}")
  [[ ${#dyn_engines[@]} -eq 0 ]] && dyn_engines=("MYSQL_8.4" "MYSQL_8.0" "MARIADB_12.3" "MARIADB_11.4" "MARIADB_10.11")

  local header_title="$(_t "SERVER_DB_MENU_TITLE")"
  local confirm_desc="$(_t "SERVER_DB_MENU_CMD_CONFIRM_RETURN")"
  local quit_desc="$(_t "SERVER_DB_MENU_CMD_QUIT_RETURN")"
  if [[ "$mode" == "initial" ]]; then
    header_title="$(_t "SERVER_DB_MENU_STEP1_TITLE")"
    confirm_desc="$(_t "SERVER_DB_MENU_CMD_CONFIRM_NEXT")"
    quit_desc="$(_t "SERVER_DB_MENU_CMD_QUIT_CANCEL")"
  fi

  while true; do
    clear 2>/dev/null || true
    echo "=============================================================================="
    echo -e " ${C_BOLD}${header_title}${C_NC}"
    echo "=============================================================================="
    echo -e "$(_t "SERVER_DB_MENU_SUBTITLE" "${os_desc}")"
    echo ""

    local idx=1
    for eng in "${dyn_engines[@]}"; do
      local sym=" "
      local sym_col="${C_NC}"
      if [[ "$selected" == "$eng" ]]; then
        sym="✔"
        sym_col="${C_GREEN}"
      fi

      local tag=""
      if [[ "$eng" == "MYSQL_8.4" ]]; then
        tag="${C_YELLOW}$(_t "SERVER_DB_TAG_RECOMMENDED")${C_NC}"
      elif [[ "$eng" == "MARIADB_11.4" ]]; then
        tag="${C_GREEN}$(_t "SERVER_DB_TAG_MARIADB_REC")${C_NC}"
      fi

      printf "   ${C_BOLD}%2d)${C_NC} [%b%s%b] %-28s ${C_DIM}[%-13s]${C_NC} %b\n" \
        "$idx" "$sym_col" "$sym" "${C_NC}" \
        "$(format_db_engine_short "$eng")" \
        "$eng" \
        "$tag"
      idx=$((idx + 1))
    done

    echo ""
    echo -e " ${C_BOLD}$(_t "SERVER_DB_MENU_SEC_SYNC")${C_NC}"
    echo -e "$(_t "SERVER_DB_MENU_OPT_PASTE")"
    echo -e "$(_t "SERVER_DB_MENU_OPT_CUSTOM")"
    echo ""
    echo -e "$(_t "SERVER_DB_MENU_DOCS" "${CLP_DOCS_URL}")"
    echo "------------------------------------------------------------------------------"
    echo -e "$(_t "SERVER_DB_MENU_CURRENT" "$(format_db_engine_label "$selected")" "${selected}")"
    echo " $(_t "SERVER_DB_MENU_CMDS")"
    echo -e "$(_t "SERVER_DB_MENU_CMD_SELECT" "${#dyn_engines[@]}")"
    echo -e "$(_t "SERVER_DB_MENU_CMD_PASTE")"
    echo -e "$(_t "SERVER_DB_MENU_CMD_CUSTOM")"
    echo -e "   ${C_BOLD}Enter${C_NC}   : ${confirm_desc}"
    echo -e "   ${C_BOLD}b${C_NC} / ${C_BOLD}q${C_NC}   : ${quit_desc}"
    echo "------------------------------------------------------------------------------"

    local db_choice
    read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_DB_MENU_PROMPT" "${#dyn_engines[@]}")${C_NC}")" db_choice || db_choice="q"
    db_choice=$(echo "$db_choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    case "$db_choice" in
      ""|"confirm")
        db_engine="$selected"
        return 0
        ;;
      "b"|"back"|"q"|"quit")
        if [[ "$mode" == "initial" ]]; then
          return 1
        fi
        return 0
        ;;
      "p"|"paste")
        if handle_paste_official_command; then
          selected="$db_engine"
          return 0
        fi
        ;;
      "c"|"custom")
        local custom_input=""
        read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_DB_MENU_CUSTOM_PROMPT")${C_NC}")" custom_input || custom_input=""
        custom_input=$(echo "$custom_input" | tr -d '[:space:]')
        if [[ -n "$custom_input" ]]; then
          selected=$(normalize_db_engine "$custom_input")
          db_engine="$selected"
          echo -e "${C_GREEN}$(_t "SERVER_DB_MENU_CUSTOM_SET" "$(format_db_engine_label "$selected")" "${selected}")${C_NC}"
          sleep 0.8
          return 0
        fi
        ;;
      *)
        [[ "$db_choice" =~ ^[0-9]{1,6}$ ]] && db_choice=$((10#$db_choice))  # 010 不可被當成八進位的 8
        if [[ "$db_choice" =~ ^[0-9]+$ ]] && (( db_choice >= 1 && db_choice <= ${#dyn_engines[@]} )); then
          selected="${dyn_engines[$((db_choice-1))]}"
          db_engine="$selected"
          echo -e "${C_GREEN}$(_t "SERVER_DB_MENU_SET" "$(format_db_engine_label "$selected")")${C_NC}"
          sleep 0.5
          return 0
        else
          echo -e "${C_RED}$(_t "SERVER_DB_MENU_INVALID" "${#dyn_engines[@]}")${C_NC}"
          sleep 1
        fi
        ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# 2.10 APT Lock Check Helper
# ------------------------------------------------------------------------------
_check_apt_locks() {
  local lock_files=(
    /var/lib/apt/lists/lock
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
  )

  if command -v fuser >/dev/null 2>&1; then
    if fuser "${lock_files[@]}" >/dev/null 2>&1; then
      return 0
    fi
  elif command -v lsof >/dev/null 2>&1; then
    if lsof "${lock_files[@]}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if command -v pgrep >/dev/null 2>&1; then
    # 常駐的 unattended-upgrade-shutdown 不持有 apt 鎖定，不可列入
    if pgrep -f "apt-get|apt\.systemd|dpkg|/usr/bin/unattended-upgrade( |$)" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# ------------------------------------------------------------------------------
# 2.11 Ensure System Bootstrap (Ubuntu Minimal & Cloud Environment Compatibility)
# ------------------------------------------------------------------------------
ensure_system_bootstrap() {
  local dry_run="${1:-false}"

  log_step "$(_t "SERVER_BOOTSTRAP_STEP_INIT")"

  # 1. 預檢根目錄可用磁碟空間 (至少 6GB / 6,000,000 KB)
  local avail_kb=""
  avail_kb=$(df -Pk / 2>/dev/null | tail -n 1 | awk '{print $4}' || echo "")
  if [[ -n "$avail_kb" && "$avail_kb" =~ ^[0-9]+$ ]]; then
    if (( avail_kb < 6000000 )); then
      local avail_gb
      avail_gb=$(awk "BEGIN {printf \"%.2f\", $avail_kb / 1048576}" 2>/dev/null || echo "0")
      if command -v clpctl >/dev/null 2>&1; then
        log_warn "$(_t "SERVER_BOOTSTRAP_WARN_DISK_LOW" "${avail_gb}" "${avail_kb}")"
      else
        log_error "$(_t "SERVER_BOOTSTRAP_ERR_DISK_INSUFFICIENT" "${avail_gb}" "${avail_kb}")"
        log_error "$(_t "SERVER_BOOTSTRAP_ERR_DISK_EXPAND_HINT")"
        return 1
      fi
    else
      local avail_gb
      avail_gb=$(awk "BEGIN {printf \"%.2f\", $avail_kb / 1048576}" 2>/dev/null || echo "0")
      log_info "$(_t "SERVER_BOOTSTRAP_INFO_DISK_OK" "${avail_gb}" "${avail_kb}")"
    fi
  else
    log_warn "$(_t "SERVER_BOOTSTRAP_WARN_DISK_UNKNOWN")"
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "$(_t "SERVER_BOOTSTRAP_INFO_DRY_RUN")"
    return 0
  fi

  # 2. 等待背景 cloud-init 與 APT 鎖定釋放 (預防 cloud-init 背景更新導致 apt-get 衝突失敗)
  if command -v cloud-init >/dev/null 2>&1; then
    if cloud-init status 2>/dev/null | grep -qi "running"; then
      log_info "$(_t "SERVER_BOOTSTRAP_INFO_CLOUD_INIT")"
      # cloud-init 卡住時不無限等待
      timeout 600 cloud-init status --wait >/dev/null 2>&1 || true
    fi
  fi

  local timeout=180
  local elapsed=0

  if _check_apt_locks; then
    log_info "$(_t "SERVER_BOOTSTRAP_INFO_APT_LOCKED" "${timeout}")"
    while _check_apt_locks; do
      if (( elapsed >= timeout )); then
        log_warn "$(_t "SERVER_BOOTSTRAP_WARN_APT_TIMEOUT" "${timeout}")"
        break
      fi
      sleep 3
      elapsed=$((elapsed + 3))
      if (( elapsed % 15 == 0 )); then
        log_info "$(_t "SERVER_BOOTSTRAP_INFO_APT_WAITING" "${elapsed}" "${timeout}")"
      fi
    done
    if ! _check_apt_locks; then
      log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_APT_RELEASED")"
    fi
  fi

  # 3. 自動修補 /etc/hosts 解析 (防止 CloudPanel 官方安裝腳本 checkIfHostnameResolves 報錯中斷)
  local current_host="${HOSTNAME:-}"
  if [[ -z "$current_host" ]]; then
    current_host=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")
    current_host=$(echo "$current_host" | tr -d '[:space:]')
  fi

  if [[ -n "$current_host" ]]; then
    export HOSTNAME="$current_host"
    local resolved_ip=""
    resolved_ip=$(getent hosts "$current_host" 2>/dev/null | awk '{print $1}' || true)

    if [[ -z "$resolved_ip" ]]; then
      log_info "$(_t "SERVER_BOOTSTRAP_INFO_HOSTS_RESOLVE_ADDING" "${current_host}")"
      backup_file /etc/hosts
      [[ -s /etc/hosts && -n "$(tail -c 1 /etc/hosts 2>/dev/null)" ]] && echo "" >> /etc/hosts
      printf "127.0.1.1\t%s\n" "$current_host" >> /etc/hosts
      log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_HOSTS_ADDED" "${current_host}")"
    else
      log_info "$(_t "SERVER_BOOTSTRAP_INFO_HOSTS_RESOLVED" "${current_host}" "${resolved_ip}")"
    fi
  fi

  # 4. 自動啟用 Ubuntu universe 套件庫 (確保 fail2ban, redis-server, ncdu, trash-cli 等套件可安裝)
  local os_id=""
  if [[ -f /etc/os-release ]]; then
    os_id=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
  fi

  if [[ "$os_id" == "ubuntu" ]]; then
    # 檢查 Ubuntu 24.04 DEB822 格式 (/etc/apt/sources.list.d/ubuntu.sources)
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
      local deb822_file="/etc/apt/sources.list.d/ubuntu.sources"
      local new_deb822=""
      local deb822_modified=0
      new_deb822=$(awk '
        /^[[:space:]]*Components:[[:space:]]*/ {
          has_universe = 0
          for (i = 2; i <= NF; i++) {
            if ($i == "universe") has_universe = 1
          }
          if (!has_universe) {
            $0 = $0 " universe"
            modified = 1
          }
        }
        { print }
        END { if (modified) exit 10; else exit 0; }
      ' "$deb822_file" 2>/dev/null) || deb822_modified=$?
      if [[ $deb822_modified -eq 10 && -n "$new_deb822" ]]; then
        log_info "$(_t "SERVER_BOOTSTRAP_INFO_DEB822_ADDING")"
        backup_file "$deb822_file"
        local write_ok=false
        local tmp_deb822=""
        tmp_deb822=$(mktemp "/etc/apt/sources.list.d/.ubuntu_sources.tmp.XXXXXX" 2>/dev/null || true)
        if [[ -n "$tmp_deb822" ]]; then
          if echo "$new_deb822" > "$tmp_deb822" && atomic_replace "$tmp_deb822" "$deb822_file"; then
            write_ok=true
          fi
          rm -f "$tmp_deb822"
        fi
        # 同目錄無法建立暫存檔時不寫入（不截斷原檔；atomic_replace 也需要在同目錄建立暫存檔），下方顯示警告

        if [[ "$write_ok" == "true" ]]; then
          log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_REPO_ENABLED" "${deb822_file}")"
        else
          log_warn "$(_t "SERVER_BOOTSTRAP_WARN_REPO_WRITE_FAILED" "${deb822_file}")"
        fi
      else
        log_info "$(_t "SERVER_BOOTSTRAP_INFO_REPO_INCLUDED" "${deb822_file}")"
      fi
    fi

    # 檢查 Ubuntu 22.04 傳統格式 (/etc/apt/sources.list)
    # 依 URI + Suite 追蹤是否已包含 universe；僅處理 deb 行（不處理 deb-src，伺服器安裝運行僅需二進位庫）
    # 建立 key 時正規化去除 URI 末尾斜線，避免相同來源因結尾斜線差異重複追加
    # 避免因元件分行定義（如 main 與 universe 獨立成行）導致逐行盲目追加引發重複定義警告
    if [[ -f /etc/apt/sources.list ]]; then
      local trad_file="/etc/apt/sources.list"
      local new_trad=""
      local trad_modified=0
      new_trad=$(awk '
        # Pass 1: 記錄所有行；對有效 deb 行，按 URI + Suite 追蹤是否已有 universe
        {
          lines[NR] = $0
          if ($0 ~ /^[[:space:]]*deb[[:space:]]+/) {
            line_clean = $0
            sub(/^[[:space:]]*deb[[:space:]]+(\[[^]]+\][[:space:]]*)?/, "", line_clean)
            n_parts = split(line_clean, parts, /[[:space:]]+/)
            if (n_parts >= 2) {
              uri = parts[1]
              sub(/\/+$/, "", uri)
              suite = parts[2]
              key = uri "::" suite
              for (i = 3; i <= n_parts; i++) {
                if (parts[i] == "universe") {
                  suite_has_universe[key] = 1
                }
              }
            }
          }
        }
        # Pass 2: 輸出所有行；若某 URI + Suite 完全未啟用 universe 且為包含 main 的行，補上 universe
        END {
          modified = 0
          for (line_idx = 1; line_idx <= NR; line_idx++) {
            cur_line = lines[line_idx]
            if (cur_line ~ /^[[:space:]]*deb[[:space:]]+/) {
              line_clean = cur_line
              sub(/^[[:space:]]*deb[[:space:]]+(\[[^]]+\][[:space:]]*)?/, "", line_clean)
              n_parts = split(line_clean, parts, /[[:space:]]+/)
              if (n_parts >= 2) {
                uri = parts[1]
                sub(/\/+$/, "", uri)
                suite = parts[2]
                key = uri "::" suite

                has_main = 0
                for (i = 3; i <= n_parts; i++) {
                  if (parts[i] == "main") {
                    has_main = 1
                  }
                }

                # 只處理 Ubuntu 官方來源與其鏡像（URI 含 ubuntu），不改第三方 repo 與 Launchpad PPA（沒有 universe 元件）
                if (has_main && !suite_has_universe[key] && uri ~ /ubuntu/ && uri !~ /launchpad/) {
                  cur_line = cur_line " universe"
                  suite_has_universe[key] = 1
                  modified = 1
                }
              }
            }
            print cur_line
          }
          if (modified) exit 10; else exit 0;
        }
      ' "$trad_file" 2>/dev/null) || trad_modified=$?
      if [[ $trad_modified -eq 10 && -n "$new_trad" ]]; then
        log_info "$(_t "SERVER_BOOTSTRAP_INFO_TRAD_ADDING")"
        backup_file "$trad_file"
        local write_ok=false
        local tmp_trad=""
        tmp_trad=$(mktemp "/etc/apt/.sources_list.tmp.XXXXXX" 2>/dev/null || true)
        if [[ -n "$tmp_trad" ]]; then
          if echo "$new_trad" > "$tmp_trad" && atomic_replace "$tmp_trad" "$trad_file"; then
            write_ok=true
          fi
          rm -f "$tmp_trad"
        fi
        # 同目錄無法建立暫存檔時不寫入（不截斷原檔；atomic_replace 也需要在同目錄建立暫存檔），下方顯示警告

        if [[ "$write_ok" == "true" ]]; then
          log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_REPO_ENABLED" "${trad_file}")"
        else
          log_warn "$(_t "SERVER_BOOTSTRAP_WARN_REPO_WRITE_FAILED" "${trad_file}")"
        fi
      elif grep -qE '^[[:space:]]*deb[[:space:]]+' "$trad_file" 2>/dev/null; then
        log_info "$(_t "SERVER_BOOTSTRAP_INFO_REPO_INCLUDED" "${trad_file}")"
      fi
    fi
  fi

  # 5. 低記憶體主機 Swap 防護 (RAM < 2GB 且 Swap < 1GB 時自動建立 2GB Swap，防止 MySQL OOM Crash)
  local mem_kb=0
  local swap_kb=0
  if [[ -f /proc/meminfo ]]; then
    mem_kb=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}' || echo 0)
    swap_kb=$(grep '^SwapTotal:' /proc/meminfo | awk '{print $2}' || echo 0)
  fi

  # 2GB = 2097152 KB, 1GB = 1048576 KB
  if (( mem_kb > 0 && mem_kb < 2097152 )) && (( swap_kb < 1048576 )); then
    log_info "$(_t "SERVER_BOOTSTRAP_INFO_SWAP_CREATING" "$((mem_kb / 1024))" "$((swap_kb / 1024))")"
    if [[ ! -f /swapfile || ! -s /swapfile ]]; then
      rm -f /swapfile
      if ! fallocate -l 2G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null || true
      fi
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null 2>&1 || true
    fi

    if [[ -f /swapfile ]] && ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
      chmod 600 /swapfile
      swapon /swapfile 2>/dev/null || true
    fi

    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
      if [[ -f /etc/fstab ]] && ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
        backup_file /etc/fstab
        [[ -s /etc/fstab && -n "$(tail -c 1 /etc/fstab 2>/dev/null)" ]] && echo "" >> /etc/fstab
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
      fi
      # 既有的 /swapfile 不會重建：總量仍不到 1G 時只警告（不自動調整大小）
      local swap_now_kb
      swap_now_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
      if [[ "${swap_now_kb:-0}" =~ ^[0-9]+$ ]] && (( swap_now_kb < 1048576 )); then
        log_warn "$(_t "SERVER_BOOTSTRAP_WARN_SWAP_SMALL" "$((swap_now_kb / 1024))")"
      else
        log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_SWAP_ENABLED")"
      fi
    else
      log_warn "$(_t "SERVER_BOOTSTRAP_WARN_SWAP_FAILED")"
    fi
  fi

  # 6. Bootstrap 安裝必備核心系統套件
  log_info "$(_t "SERVER_BOOTSTRAP_INFO_APT_INSTALL")"
  export DEBIAN_FRONTEND=noninteractive
  # 呼叫端以 || 擷取結果，set -e 在函式內不會生效，必須自行檢查
  apt-get -o DPkg::Lock::Timeout=60 update -y || log_warn "$(_t "SERVER_WARN_APT_UPDATE_FAILED")"
  if ! apt-get -o DPkg::Lock::Timeout=60 install -y \
    curl \
    wget \
    sudo \
    ca-certificates \
    gnupg \
    software-properties-common \
    locales \
    sqlite3 \
    debconf-utils \
    openssl \
    iproute2 \
    iptables; then
    log_error "$(_t "SERVER_ERR_APT_INSTALL_FAILED")"
    return 1
  fi

  # 7. 生成標準 UTF-8 語系 (en_US.UTF-8, zh_TW.UTF-8)
  log_info "$(_t "SERVER_BOOTSTRAP_INFO_LOCALES_GEN")"
  if [[ -f /etc/locale.gen ]]; then
    sed -i 's/^#[[:space:]]*\(en_US.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^#[[:space:]]*\(zh_TW.UTF-8[[:space:]]\+UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
    grep -q 'en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    grep -q 'zh_TW.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'zh_TW.UTF-8 UTF-8' >> /etc/locale.gen
  fi
  if command -v locale-gen >/dev/null 2>&1; then
    locale-gen en_US.UTF-8 2>/dev/null || true
    locale-gen zh_TW.UTF-8 2>/dev/null || true
  fi
  if command -v update-locale >/dev/null 2>&1; then
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
  fi
  export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

  log_success "$(_t "SERVER_BOOTSTRAP_SUCCESS_COMPLETE")"
  return 0
}

# CloudPanel 的 data 目錄屬於 clp 使用者：root 不以路徑寫入或 chmod（可能是 clp 放的 symlink）
# _clp_db_backup <db_file> <backup_file>：以 clp 身分複製
_clp_db_backup() {
  sudo -H -u clp cp -p -- "$1" "$2"
}

# _clp_data_fix_perms <data_dir>：root 執行 sqlite3 後產生的 root 檔案交回 clp（find 不跟隨 symlink，-execdir＋chown -h），
# 權限以 clp 身分設定
_clp_data_fix_perms() {
  local data_dir="$1"
  [[ -d "$data_dir" && ! -L "$data_dir" ]] || return 0
  find "$data_dir" -xdev \( ! -user clp -o ! -group clp \) -execdir chown -h clp:clp {} + 2>/dev/null || true
  sudo -H -u clp chmod 770 -- "$data_dir" 2>/dev/null || true
  find "$data_dir" -maxdepth 1 -type f -name 'db.sq3*' -execdir sudo -H -u clp chmod 660 -- {} + 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 3. Fresh VPS Installer Subcommand (clp server install)
# ------------------------------------------------------------------------------
server_install() {
  init_modules_default

  local non_interactive=false
  local dry_run=false
  local db_engine="MYSQL_8.4"
  local target_tz=""
  local skip_ssh_check=false
  local clp_already_installed=false
  local installed_clp_ver=""
  local installed_db_info=""
  local existing_admin_count=0
  local existing_admins=""

  # 解析參數
  if has_opt "y" || has_opt "yes" || has_opt "non_interactive"; then
    non_interactive=true
  fi
  if has_opt "dry_run" || has_opt "dry-run"; then
    dry_run=true
  fi
  # 沒有終端機又沒有 -y 時，不可在沒有確認的情況下安裝與強化主機
  if [[ "$dry_run" != "true" ]] && ! require_tty_or_yes; then
    return 1
  fi
  load_available_db_engines
  if has_opt "db"; then
    # 在 bootstrap 修改系統之前驗證：--db 沒有值（變成 true）或不在此作業系統支援清單中時報錯
    local db_raw
    db_raw="$(opt_get "db" "")"
    if [[ -z "$db_raw" || "$db_raw" == "true" ]]; then
      log_error "$(_t "SERVER_DB_ERR_VALUE_REQUIRED" "${CACHED_AVAILABLE_DB_ENGINES[*]:-}")"
      return 1
    fi
    db_engine=$(normalize_db_engine "$db_raw")
    if [[ ${#CACHED_AVAILABLE_DB_ENGINES[@]} -gt 0 ]]; then
      local e db_ok=0
      for e in "${CACHED_AVAILABLE_DB_ENGINES[@]}"; do
        [[ "$e" == "$db_engine" ]] && db_ok=1
      done
      if [[ "$db_ok" -eq 0 ]]; then
        log_error "$(_t "SERVER_DB_ERR_UNSUPPORTED" "$db_engine" "${CACHED_AVAILABLE_DB_ENGINES[*]}")"
        return 1
      fi
    fi
  else
    # 未指定時採用此作業系統支援清單中的第一個引擎（例如 Ubuntu 22.04 不支援 MySQL 8.4）
    if [[ ${#CACHED_AVAILABLE_DB_ENGINES[@]} -gt 0 ]]; then
      db_engine="${CACHED_AVAILABLE_DB_ENGINES[0]}"
    fi
  fi
  # 未指定 --timezone 時偵測目前系統時區並詢問是否變更（非互動模式維持不變）
  target_tz=$(resolve_server_timezone "$non_interactive") || return 1
  if has_opt "skip_ssh_check" || has_opt "skip-ssh-check"; then
    skip_ssh_check=true
  fi

  # 系統環境 Bootstrap（/etc/hosts、universe、Swap、套件、語系）會修改系統，
  # 改為在使用者確認安裝計畫之後才執行（見下方「依序執行已啟用的模組」之前）

  # 檢測系統是否已安裝 CloudPanel
  if command -v clpctl >/dev/null 2>&1; then
    clp_already_installed=true
    installed_clp_ver=$(get_clp_version)
    installed_db_info=$(get_database_engine_info)
    if [[ -f /home/clp/htdocs/app/data/db.sq3 ]] && command -v sqlite3 >/dev/null 2>&1; then
      existing_admin_count=$(sqlite3 -readonly /home/clp/htdocs/app/data/db.sq3 "SELECT count(*) FROM user WHERE role = 'ROLE_ADMIN';" 2>/dev/null || echo 0)
    fi
    if (( existing_admin_count > 0 )); then
      existing_admins=$(clpctl user:list 2>/dev/null | awk -F'|' '$6 ~ /Admin/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | tr '\n' ' ' | sed 's/ $//' || true)
    fi
  fi

  # 解析全部模組自訂覆蓋開關 (--module=yes|no 或 -module=yes|no)
  for mod in "${MODULES[@]}"; do
    local mod_hyphen="${mod//_/-}"
    if has_opt "$mod"; then
      set_mod_enabled "$mod" "$(opt_get "$mod")"
    elif has_opt "$mod_hyphen"; then
      set_mod_enabled "$mod" "$(opt_get "$mod_hyphen")"
    fi
  done

  # Wordfence CLI 已終止支援，若帶有此參數提示警告並繼續
  if has_opt "wordfence"; then
    log_warn "$(_t "SERVER_WORDFENCE_ERR_EOL")"
  fi

  # 若使用者未明確自訂關閉，核心項目預設為 yes
  if ! has_opt "cloudpanel"; then
    set_mod_enabled "cloudpanel" "yes"
  fi
  if ! has_opt "system_basics" && ! has_opt "system-basics"; then
    set_mod_enabled "system_basics" "yes"
  fi

  # DRY-RUN 模擬輸出 (若有 --dry-run 參數)
  if [[ "$dry_run" == "true" ]]; then
    echo ""
    echo "=============================================================================="
    echo -e " ${C_BOLD}${C_YELLOW}$(_t "SERVER_INSTALL_DRY_RUN_TITLE")${C_NC}"
    echo "=============================================================================="
    if [[ "$clp_already_installed" == "true" ]]; then
      echo -e " ${C_CYAN}$(_t "SERVER_INSTALL_DRY_RUN_CLP_DETECTED" "${installed_clp_ver}" "${installed_db_info}")${C_NC}"
      echo "  ----------------------------------------------------------------------------"
    fi
    printf "  %-4s %-22s %-10s %s\n" "$(_t "SERVER_INSTALL_COL_NO")" "$(_t "SERVER_INSTALL_COL_MODULE")" "$(_t "SERVER_INSTALL_COL_ACTION")" "$(_t "SERVER_INSTALL_COL_DESC")"
    echo "  ----------------------------------------------------------------------------"
    local dry_idx=1
    for mod in "${MODULES[@]}"; do
      local action="$(_t "SERVER_INSTALL_ACT_SKIP")"
      local color="${C_YELLOW}"
      if is_mod_enabled "$mod"; then
        if [[ "$mod" == "cloudpanel" && "$clp_already_installed" == "true" ]]; then
          action="$(_t "SERVER_INSTALL_ACT_SKIP_CORE")"
          color="${C_CYAN}"
        else
          action="$(_t "SERVER_INSTALL_ACT_APPLY")"
          color="${C_GREEN}"
        fi
      fi
      printf "  %2d)  %-22s %b%-10s%b %s\n" \
        "$dry_idx" "$mod" "$color" "$action" "$C_NC" "$(get_mod_desc "$mod" "$db_engine")"
      dry_idx=$((dry_idx + 1))
    done
    echo "=============================================================================="
    if [[ "$clp_already_installed" == "true" ]]; then
      echo -e " $(_t "SERVER_INSTALL_DRY_RUN_CURRENT_DB" "${C_BOLD}${installed_db_info}${C_NC}")"
    else
      echo -e " $(_t "SERVER_INSTALL_DRY_RUN_TARGET_DB" "${C_BOLD}$(format_db_engine_label "$db_engine")${C_NC}" "${db_engine}")"
    fi
    echo -e " $(_t "SERVER_INSTALL_DRY_RUN_TARGET_TZ" "${C_BOLD}${target_tz}${C_NC}")"
    echo ""
    return 0
  fi

  # 計畫輸出輔助函式
  _print_install_plan() {
    echo ""
    echo "=============================================================================="
    echo -e " ${C_BOLD}$(_t "SERVER_INSTALL_PLAN_TITLE" "${CLP_SERVER_VERSION}")${C_NC}"
    echo "=============================================================================="
    echo "$(_t "SERVER_INSTALL_PLAN_SUBTITLE")"
    echo ""
    local plan_idx=1
    for mod in "${MODULES[@]}"; do
      local sym=" "
      local sym_col="${C_NC}"
      local tag=""

      if is_mod_enabled "$mod"; then
        sym="✔"
        sym_col="${C_GREEN}"
      fi

      if [[ "$mod" == "cloudpanel" && "$clp_already_installed" == "true" ]]; then
        tag=" ${C_CYAN}$(_t "SERVER_INSTALL_PLAN_TAG_CLP_EXISTS")${C_NC}"
      elif [[ "$mod" == "cloudpanel" || "$mod" == "system_basics" ]]; then
        tag=" ${C_YELLOW}$(_t "SERVER_INSTALL_PLAN_TAG_REQUIRED")${C_NC}"
      elif ! is_mod_enabled "$mod"; then
        tag=" ${C_DIM}$(_t "SERVER_INSTALL_PLAN_TAG_SKIPPED")${C_NC}"
      fi

      printf "  ${C_BOLD}%2d)${C_NC} [%b%s%b] %-20s %s%b\n" \
        "$plan_idx" \
        "$sym_col" "$sym" "${C_NC}" \
        "$mod" \
        "$(get_mod_desc "$mod" "$db_engine")" \
        "$tag"
      plan_idx=$((plan_idx + 1))
    done

    echo ""
    echo "------------------------------------------------------------------------------"
    if [[ "$clp_already_installed" == "true" ]]; then
      echo -e " $(_t "SERVER_INSTALL_PLAN_CURRENT_DB" "${C_BOLD}${installed_db_info}${C_NC}")"
    else
      echo -e " $(_t "SERVER_INSTALL_PLAN_TARGET_DB" "${C_BOLD}$(format_db_engine_label "$db_engine")${C_NC}" "${db_engine}")"
    fi
    echo -e " $(_t "SERVER_INSTALL_PLAN_TARGET_TZ" "${C_BOLD}${target_tz}${C_NC}")"
    echo "=============================================================================="
    echo ""
  }

  # 互動式安裝引導流程 (若非 non_interactive 且有終端環境且非 dry-run)
  if [[ "$non_interactive" != "true" && "$dry_run" != "true" && -t 0 ]]; then
    if [[ "$clp_already_installed" == "true" ]]; then
      local server_ip
      server_ip=$(get_server_ip)

      clear 2>/dev/null || true
      echo "=============================================================================="
      echo -e " ${C_BOLD}${C_YELLOW}$(_t "SERVER_EXISTING_TITLE")${C_NC}"
      echo "=============================================================================="
      echo -e "$(_t "SERVER_EXISTING_SYS_INFO")"
      echo -e "$(_t "SERVER_EXISTING_VER" "${installed_clp_ver}")"
      echo -e "$(_t "SERVER_EXISTING_DB" "${installed_db_info:-$(_t "SERVER_EXISTING_DB_INSTALLED")}")"
      if (( existing_admin_count > 0 )); then
        echo -e "$(_t "SERVER_EXISTING_ADMIN_CONFIGURED" "${existing_admins:-$(_t "SERVER_EXISTING_ADMIN_EXISTS")}")"
        echo -e "$(_t "SERVER_EXISTING_LOGIN_URL" "${server_ip}")"
      else
        echo -e "$(_t "SERVER_EXISTING_ADMIN_NOT_CONFIGURED")"
        echo -e "$(_t "SERVER_EXISTING_SETUP_URL" "${server_ip}")"
      fi
      echo ""
      echo -e " ${C_BOLD}$(_t "SERVER_EXISTING_NOTICE_TITLE")${C_NC}"
      echo "$(_t "SERVER_EXISTING_NOTICE_LINE1")"
      echo "$(_t "SERVER_EXISTING_NOTICE_LINE2")"
      echo "$(_t "SERVER_EXISTING_NOTICE_LINE3")"
      echo ""
      echo -e " ${C_BOLD}$(_t "SERVER_EXISTING_CHOOSE_ACTION")${C_NC}"
      echo -e "$(_t "SERVER_EXISTING_ACT_1")"
      if (( existing_admin_count > 0 )); then
        echo -e "$(_t "SERVER_EXISTING_ACT_2")"
        echo -e "$(_t "SERVER_EXISTING_ACT_3")"
      fi
      echo -e "$(_t "SERVER_EXISTING_ACT_Q")"
      echo "=============================================================================="

      local existing_loop=true
      while [[ "$existing_loop" == "true" ]]; do
        local existing_choice
        read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_EXISTING_PROMPT_CHOICE" "$([ "${existing_admin_count:-0}" -gt 0 ] && echo "/2/3")")${C_NC}")" existing_choice || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
        existing_choice=$(echo "$existing_choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

        case "$existing_choice" in
          1|"")
            existing_loop=false
            ;;
          2)
            if (( existing_admin_count == 0 )); then
              echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_NO_ADMINS" "${server_ip}")${C_NC}"
              continue
            fi
            echo ""
            echo "------------------------------------------------------------------------------"
            echo -e " ${C_BOLD}$(_t "SERVER_EXISTING_RESET_TITLE")${C_NC}"
            echo "------------------------------------------------------------------------------"
            local target_user="${existing_admins%% *}"
            local input_user
            read -r -p "$(echo -e "$(_t "SERVER_EXISTING_RESET_PROMPT_USER" "${target_user}")")" input_user || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
            input_user="${input_user:-$target_user}"
            if [[ -z "$input_user" ]]; then
              echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_USER_EMPTY")${C_NC}"
              continue
            fi

            local new_pass=""
            local confirm_pass=""
            while true; do
              read -r -s -p "$(_t "SERVER_EXISTING_RESET_PROMPT_PASS")" new_pass || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              echo ""
              if [[ ${#new_pass} -lt 8 ]]; then
                echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_PASS_LENGTH")${C_NC}"
                continue
              fi
              read -r -s -p "$(_t "SERVER_EXISTING_RESET_PROMPT_CONFIRM_PASS")" confirm_pass || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              echo ""
              if [[ "$new_pass" != "$confirm_pass" ]]; then
                echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_PASS_MISMATCH")${C_NC}"
                continue
              fi
              break
            done

            log_info "$(_t "SERVER_EXISTING_RESET_INFO_RESETTING" "${input_user}")"
            if clpctl user:reset:password --userName="$input_user" --password="$new_pass" >/dev/null 2>&1; then
              echo -e "${C_GREEN}${C_BOLD}$(_t "SERVER_EXISTING_RESET_SUCCESS" "${input_user}")${C_NC}"
              echo -e "$(_t "SERVER_EXISTING_RESET_LOGIN_URL" "${server_ip}")"
            else
              echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_FAILED")${C_NC}"
            fi
            echo ""
            local cont_ans
            read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_EXISTING_PROMPT_CONTINUE_MODULES")${C_NC}")" cont_ans || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
            cont_ans="${cont_ans:-y}"
            if [[ "$cont_ans" =~ ^[Yy]$ ]]; then
              existing_loop=false
            else
              echo "$(_t "SERVER_EXISTING_RESET_DONE_EXIT")"
              return 0
            fi
            ;;
          3)
            if (( existing_admin_count == 0 )); then
              echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_NO_ADMINS" "${server_ip}")${C_NC}"
              continue
            fi
            local clp_db_file="/home/clp/htdocs/app/data/db.sq3"
            if [[ ! -f "$clp_db_file" ]]; then
              echo -e "${C_RED}$(_t "SERVER_EXISTING_CLEAR_ERR_NO_DB")${C_NC}"
              continue
            fi

            local db_srv_count
            db_srv_count=$(sqlite3 -readonly "$clp_db_file" "SELECT count(*) FROM database_server;" 2>/dev/null || echo 0)

            if [[ -n "$db_srv_count" && "$db_srv_count" -gt 0 ]]; then
              echo ""
              echo "------------------------------------------------------------------------------"
              echo -e " ${C_BOLD}$(_t "SERVER_EXISTING_REPLACE_TITLE")${C_NC}"
              echo "------------------------------------------------------------------------------"

              local other_users
              other_users=$(sqlite3 -readonly "$clp_db_file" "SELECT '   • ' || user_name || ' (' || role || ')' FROM user WHERE role != 'ROLE_ADMIN';" 2>/dev/null || true)
              if [[ -n "$other_users" ]]; then
                echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_PRESERVED_USERS" "$other_users")${C_NC}"
                echo ""
              fi

              local new_admin_user=""
              while true; do
                read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_USER")" new_admin_user || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
                new_admin_user=$(echo "$new_admin_user" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
                if [[ -z "$new_admin_user" ]]; then
                  echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_USER_EMPTY")${C_NC}"
                  continue
                fi
                if ! [[ "$new_admin_user" =~ ^[a-z0-9_.-]+$ ]]; then
                  echo -e "${C_RED}$(_t "SERVER_EXISTING_REPLACE_ERR_USER_INVALID")${C_NC}"
                  continue
                fi
                break
              done

              local new_admin_email=""
              while true; do
                read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_EMAIL")" new_admin_email || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
                new_admin_email=$(echo "$new_admin_email" | tr -d '[:space:]')
                if [[ -z "$new_admin_email" || ! "$new_admin_email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
                  echo -e "${C_RED}$(_t "SERVER_EXISTING_REPLACE_ERR_EMAIL_INVALID")${C_NC}"
                  continue
                fi
                break
              done

              local new_admin_first=""
              read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_FIRSTNAME" "Admin")" new_admin_first || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              new_admin_first="${new_admin_first:-Admin}"

              local new_admin_last=""
              read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_LASTNAME" "User")" new_admin_last || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              new_admin_last="${new_admin_last:-User}"

              local sys_tz
              sys_tz=$(get_current_timezone 2>/dev/null || echo "UTC")
              [[ -z "$sys_tz" || "$sys_tz" == "Etc/UTC" ]] && sys_tz="UTC"
              local new_admin_tz=""
              read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_TIMEZONE" "$sys_tz")" new_admin_tz || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              new_admin_tz="${new_admin_tz:-$sys_tz}"
              [[ "$new_admin_tz" == "Etc/UTC" ]] && new_admin_tz="UTC"

              local pass_mode=""
              read -r -p "$(_t "SERVER_EXISTING_REPLACE_PROMPT_PASS_MODE")" pass_mode || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              pass_mode="${pass_mode:-1}"

              local new_admin_pass=""
              local auto_pass_file=""
              if [[ "$pass_mode" == "2" ]]; then
                new_admin_pass="Clp_$(openssl rand -hex 8)!9"
                local pass_dir="/root/.clp"
                mkdir -p "$pass_dir"
                chmod 700 "$pass_dir"
                auto_pass_file="${pass_dir}/clp-admin-${new_admin_user}.txt"
                local umask_orig
                umask_orig=$(umask)
                umask 077
                printf '%s\n' "$new_admin_pass" > "$auto_pass_file"
                chmod 600 "$auto_pass_file"
                umask "$umask_orig"
              else
                local confirm_pass=""
                while true; do
                  read -r -s -p "$(_t "SERVER_EXISTING_RESET_PROMPT_PASS")" new_admin_pass || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
                  echo ""
                  if [[ ${#new_admin_pass} -lt 8 ]]; then
                    echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_PASS_LENGTH")${C_NC}"
                    continue
                  fi
                  read -r -s -p "$(_t "SERVER_EXISTING_RESET_PROMPT_CONFIRM_PASS")" confirm_pass || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
                  echo ""
                  if [[ "$new_admin_pass" != "$confirm_pass" ]]; then
                    echo -e "${C_RED}$(_t "SERVER_EXISTING_RESET_ERR_PASS_MISMATCH")${C_NC}"
                    continue
                  fi
                  break
                done
              fi

              # 建立新管理員之前先備份 db.sq3；備份失敗時什麼都不做，回到選單
              local clp_db_backup="${clp_db_file}.clpbak_$(date +%Y%m%d_%H%M%S)"
              if ! _clp_db_backup "$clp_db_file" "$clp_db_backup"; then
                echo -e "${C_RED}$(_t "SERVER_EXISTING_REPLACE_ERR_BACKUP" "${clp_db_file}")${C_NC}"
                [[ -n "$auto_pass_file" && -f "$auto_pass_file" ]] && rm -f "$auto_pass_file"
                continue
              fi

              log_info "$(_t "SERVER_EXISTING_REPLACE_INFO_CREATING" "${new_admin_user}")"
              local add_out=""
              local add_rc=0
              add_out=$(clpctl user:add --userName="$new_admin_user" --email="$new_admin_email" --firstName="$new_admin_first" --lastName="$new_admin_last" --password="$new_admin_pass" --role="admin" --timezone="$new_admin_tz" 2>&1) || add_rc=$?

              if (( add_rc != 0 )); then
                echo -e "${C_RED}$(_t "SERVER_EXISTING_REPLACE_ERR_ADD_FAILED" "${add_out}")${C_NC}"
                [[ -n "$auto_pass_file" && -f "$auto_pass_file" ]] && rm -f "$auto_pass_file"
                continue
              fi

              # 刪除其他管理員前列出名單確認；任何一位刪除失敗都不可回報成功（db.sq3 已在建立新管理員前備份）
              # db.sq3 由 clp 帳號（CloudPanel 網頁程式）寫入：名稱逐行讀取，不符合管理員名稱格式的不刪除
              #   （之後要放進 root 執行的 SQL），列為刪除失敗，請使用者到 CloudPanel 後台處理
              local old_admins_raw old_adm
              local -a old_admins_to_del=()
              local del_failed=""
              old_admins_raw=$(sqlite3 -readonly "$clp_db_file" "SELECT user_name FROM user WHERE role = 'ROLE_ADMIN' AND user_name != '$new_admin_user';" 2>/dev/null || true)
              while IFS= read -r old_adm; do
                [[ -z "$old_adm" ]] && continue
                if [[ "$old_adm" =~ ^[A-Za-z0-9_.-]+$ ]]; then
                  old_admins_to_del+=("$old_adm")
                else
                  del_failed+="$(strip_ctrl_chars "$old_adm") "
                fi
              done <<< "$old_admins_raw"
              if [[ -n "$del_failed" ]]; then
                printf '%s\n' "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_WARN_SKIP_INVALID" "${del_failed% }")${C_NC}"
              fi
              if [[ ${#old_admins_to_del[@]} -gt 0 ]]; then
                echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_INFO_WILL_DELETE" "${old_admins_to_del[*]}")${C_NC}"
                if ! prompt_confirm "$(_t "SERVER_EXISTING_REPLACE_PROMPT_DELETE")" "y"; then
                  echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_INFO_KEPT" "${new_admin_user}")${C_NC}"
                  old_admins_to_del=()
                  del_failed=""
                fi
              fi
              for old_adm in ${old_admins_to_del[@]+"${old_admins_to_del[@]}"}; do
                if ! clpctl user:delete --userName="$old_adm" --force >/dev/null 2>&1 && \
                   ! sqlite3 "$clp_db_file" "PRAGMA foreign_keys=ON; DELETE FROM user WHERE user_name = '$old_adm' AND role = 'ROLE_ADMIN';" 2>/dev/null; then
                  del_failed+="${old_adm} "
                fi
              done
              if [[ -n "$del_failed" ]]; then
                printf '%s\n' "${C_RED}$(_t "SERVER_EXISTING_REPLACE_ERR_DELETE" "${del_failed% }" "${clp_db_backup}")${C_NC}"
              fi

              _clp_data_fix_perms /home/clp/htdocs/app/data
              systemctl restart clp-php-fpm clp-nginx 2>/dev/null || systemctl restart cloudpanel 2>/dev/null || true

              existing_admin_count=1
              existing_admins="$new_admin_user"

              [[ -z "$del_failed" ]] && echo -e "${C_GREEN}${C_BOLD}$(_t "SERVER_EXISTING_REPLACE_SUCCESS" "${new_admin_user}")${C_NC}"
              if [[ -n "$auto_pass_file" ]]; then
                echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_INFO_AUTO_PASS_SAVED" "${auto_pass_file}")${C_NC}"
              fi
              echo -e "$(_t "SERVER_EXISTING_RESET_LOGIN_URL" "${server_ip}")"
            else
              echo ""
              echo "------------------------------------------------------------------------------"
              echo -e " ${C_BOLD}${C_RED}$(_t "SERVER_EXISTING_CLEAR_TITLE")${C_NC}"
              echo "------------------------------------------------------------------------------"
              echo "$(_t "SERVER_EXISTING_REPLACE_NO_DB_SRV_WARN")"
              echo "$(_t "SERVER_EXISTING_CLEAR_WARN1")"
              echo "$(_t "SERVER_EXISTING_CLEAR_WARN2" "${server_ip}")"
              echo ""
              local confirm_clear
              read -r -p "$(echo -e "${C_YELLOW}$(_t "SERVER_EXISTING_REPLACE_NO_DB_SRV_PROMPT")${C_NC}")" confirm_clear || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
              confirm_clear="${confirm_clear:-n}"
              if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then
                log_info "$(_t "SERVER_EXISTING_CLEAR_INFO_CLEARING")"
                local clp_db_backup="${clp_db_file}.clpbak_$(date +%Y%m%d_%H%M%S)"
                if ! _clp_db_backup "$clp_db_file" "$clp_db_backup" || \
                   ! sqlite3 "$clp_db_file" "PRAGMA foreign_keys=ON; DELETE FROM user;"; then
                  echo -e "${C_RED}$(_t "SERVER_EXISTING_CLEAR_ERR_FAILED" "${clp_db_backup}")${C_NC}"
                  continue
                fi
                _clp_data_fix_perms /home/clp/htdocs/app/data
                systemctl restart clp-php-fpm clp-nginx 2>/dev/null || systemctl restart cloudpanel 2>/dev/null || true
                existing_admin_count=0
                existing_admins=""
                echo -e "${C_GREEN}${C_BOLD}$(_t "SERVER_EXISTING_CLEAR_SUCCESS")${C_NC}"
                echo -e "$(_t "SERVER_EXISTING_CLEAR_REGISTER_URL" "${server_ip}")"
              else
                echo "$(_t "SERVER_EXISTING_CLEAR_CANCELLED")"
                continue
              fi
            fi

            echo ""
            local cont_ans
            read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_EXISTING_PROMPT_CONTINUE_MODULES")${C_NC}")" cont_ans || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
            cont_ans="${cont_ans:-y}"
            if [[ "$cont_ans" =~ ^[Yy]$ ]]; then
              existing_loop=false
            else
              echo "$(_t "SERVER_EXISTING_CLEAR_DONE_EXIT")"
              return 0
            fi
            ;;
          "q"|"quit"|"exit")
            echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
            return 0
            ;;
          *)
            echo -e "${C_RED}$(_t "SERVER_MOD_MENU_INVALID_INPUT")${C_NC}"
            ;;
        esac
      done
    else
      # 正常全新安裝流程：[步驟 1/2] 決定資料庫引擎 (若命令列未指定 --db)
      if ! has_opt "db"; then
        if ! select_db_engine_interactive "initial"; then
          echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
          return 0
        fi
      fi
    fi

    # [步驟 2/2] 決定要安裝與啟用的模組項目 (切換後直接進入確認畫面，支援 Back 返回修改)
    while true; do
      clear 2>/dev/null || true
      echo "=============================================================================="
      echo -e " ${C_BOLD}$(_t "SERVER_MOD_MENU_TITLE" "${CLP_SERVER_VERSION}")${C_NC}"
      echo "=============================================================================="
      echo "$(_t "SERVER_MOD_MENU_SUBTITLE")"
      echo ""
      local idx=1
      for mod in "${MODULES[@]}"; do
        local sym=" "
        local sym_col="${C_NC}"
        local lock_text=""

        if is_mod_enabled "$mod"; then
          sym="✔"
          sym_col="${C_GREEN}"
        fi

        if [[ "$mod" == "cloudpanel" && "$clp_already_installed" == "true" ]]; then
          lock_text=" ${C_CYAN}$(_t "SERVER_INSTALL_PLAN_TAG_CLP_EXISTS")${C_NC}"
        elif [[ "$mod" == "cloudpanel" || "$mod" == "system_basics" ]]; then
          lock_text=" ${C_YELLOW}$(_t "SERVER_INSTALL_PLAN_TAG_REQUIRED")${C_NC}"
        fi

        printf "  ${C_BOLD}%2d)${C_NC} [%b%s%b] %-20s %s%b\n" \
          "$idx" \
          "$sym_col" "$sym" "${C_NC}" \
          "$mod" \
          "$(get_mod_desc "$mod" "$db_engine")" \
          "$lock_text"
        idx=$((idx + 1))
      done

      echo ""
      echo "------------------------------------------------------------------------------"
      if [[ "$clp_already_installed" == "true" ]]; then
        echo -e " $(_t "SERVER_MOD_MENU_SETTINGS_CLP_EXISTS" "${C_BOLD}${installed_db_info}${C_NC}" "${C_BOLD}${target_tz}${C_NC}")"
      else
        echo -e " $(_t "SERVER_MOD_MENU_SETTINGS_FRESH" "${C_BOLD}$(format_db_engine_label "$db_engine")${C_NC}" "${db_engine}" "${C_BOLD}${target_tz}${C_NC}")"
      fi
      echo " $(_t "SERVER_MOD_MENU_CMDS")"
      echo -e "$(_t "SERVER_MOD_MENU_CMD_TOGGLE")"
      if [[ "$clp_already_installed" != "true" ]]; then
        echo -e "$(_t "SERVER_MOD_MENU_CMD_DB" "$(format_db_engine_short "$db_engine")")"
        echo -e "$(_t "SERVER_MOD_MENU_CMD_PASTE")"
      fi
      echo -e "$(_t "SERVER_MOD_MENU_CMD_ALL")"
      echo -e "$(_t "SERVER_MOD_MENU_CMD_MIN")"
      echo -e "$(_t "SERVER_MOD_MENU_CMD_CONFIRM")"
      echo -e "$(_t "SERVER_MOD_MENU_CMD_QUIT")"
      echo "------------------------------------------------------------------------------"
      read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_MOD_MENU_PROMPT")${C_NC}")" choice || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

      case "$choice" in
        "q"|"quit"|"exit")
          echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
          return 0
          ;;
        "d"|"db"|"database"|"mariadb"|"mysql")
          if [[ "$clp_already_installed" == "true" ]]; then
            echo -e "${C_YELLOW}$(_t "SERVER_MOD_MENU_HINT_CANT_SWITCH_DB" "${installed_db_info}")${C_NC}"
            sleep 1.2
            continue
          fi
          select_db_engine_interactive "normal"
          continue
          ;;
        "p"|"paste")
          if [[ "$clp_already_installed" == "true" ]]; then
            echo -e "${C_YELLOW}$(_t "SERVER_MOD_MENU_HINT_CANT_PASTE" "${installed_db_info}")${C_NC}"
            sleep 1.2
            continue
          fi
          handle_paste_official_command || true
          continue
          ;;
        "a"|"all")
          for mod in "${MODULES[@]}"; do
            set_mod_enabled "$mod" "yes"
          done
          # 切換後直接前往確認畫面
          ;;
        "m"|"min"|"minimal")
          for mod in "${MODULES[@]}"; do
            if [[ "$mod" != "cloudpanel" && "$mod" != "system_basics" ]]; then
              set_mod_enabled "$mod" "no"
            fi
          done
          # 切換後直接前往確認畫面
          ;;
        1)
          if [[ "$clp_already_installed" == "true" ]]; then
            echo -e "${C_YELLOW}$(_t "SERVER_MOD_MENU_HINT_SKIP_CLP")${C_NC}"
            sleep 1.2
            continue
          fi
          echo -e "${C_CYAN}$(_t "SERVER_MOD_MENU_HINT_CLP_REQUIRED")${C_NC}"
          sleep 0.6
          select_db_engine_interactive "normal"
          continue
          ;;
        2)
          echo -e "${C_YELLOW}$(_t "SERVER_MOD_MENU_HINT_BASICS_REQUIRED")${C_NC}"
          sleep 1.2
          continue
          ;;
        ""|"c"|"confirm"|"y"|"yes")
          # 直接前往確認畫面
          ;;
        *)
          [[ "$choice" =~ ^[0-9]{1,6}$ ]] && choice=$((10#$choice))  # 010 不可被當成八進位的 8
          if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 3 && choice <= ${#MODULES[@]} )); then
            local target_mod="${MODULES[$((choice-1))]}"
            if is_mod_enabled "$target_mod"; then
              set_mod_enabled "$target_mod" "no"
            else
              set_mod_enabled "$target_mod" "yes"
            fi
            # 切換後直接前往確認畫面！
          else
            echo -e "${C_RED}$(_t "SERVER_MOD_MENU_INVALID_INPUT")${C_NC}"
            sleep 1
            continue
          fi
          ;;
      esac

      # 顯示即將執行的安裝與加固計畫確認清單
      clear 2>/dev/null || true
      _print_install_plan

      local confirm_ans
      read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_INSTALL_PROMPT_CONFIRM_PLAN")${C_NC}")" confirm_ans || { echo ""; log_info "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      confirm_ans=$(echo "${confirm_ans:-y}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
      case "$confirm_ans" in
        "b"|"back")
          # 返回步驟 2 模組選擇清單
          continue
          ;;
        "y"|"yes")
          # 確認執行！跳出循環，進入安裝流程
          break
          ;;
        *)
          echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
          return 0
          ;;
      esac
    done
  else
    # 非互動模式 (-y 且非 dry-run)：顯示計畫清單並做執行前確認 (除非帶有 --force)
    if [[ "$clp_already_installed" == "true" ]]; then
      log_warn "$(_t "SERVER_EXISTING_WARN_DETECTED" "${installed_clp_ver}" "${installed_db_info}")"
      log_warn "$(_t "SERVER_EXISTING_WARN_SKIP_CORE")"
    fi
    _print_install_plan
    if [[ -t 0 ]] && ! has_opt "force"; then
      local confirm_ans
      if ! read -r -p "$(echo -e "${C_CYAN}$(_t "SERVER_INSTALL_PROMPT_CONFIRM_NON_INTERACTIVE")${C_NC}")" confirm_ans; then
        echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
        return 0
      fi
      confirm_ans="${confirm_ans:-y}"
      case "$confirm_ans" in
        [Yy]*|"")
          ;;
        *)
          echo "$(_t "SERVER_INSTALL_MSG_CANCELLED")"
          return 0
          ;;
      esac
      echo ""
    fi
  fi

  log_step "$(_t "SERVER_INSTALL_STEP_STARTING")"

  # 執行系統環境 Bootstrap 初始化 (APT 鎖定、/etc/hosts、universe、磁碟空間、Swap、必備套件)
  ensure_system_bootstrap "$dry_run" || return 1

  # 依序執行已啟用的模組；CloudPanel 核心安裝失敗時停止，不再繼續強化主機
  local install_failed=0 core_failed=0
  for mod in "${MODULES[@]}"; do
    if [[ "$core_failed" -eq 1 ]]; then
      set_mod_status "$mod" "SKIPPED"
      continue
    fi
    if is_mod_enabled "$mod"; then
      local status_code=0
      case "$mod" in
        cloudpanel)
          # 必須以 || 擷取回傳值（2 = 已安裝），否則 set -e 會在此直接結束整個安裝流程
          install_cloudpanel_core "$db_engine" "$dry_run" || status_code=$?
          ;;
        system_basics)
          setup_system_basics "$target_tz" "$dry_run" || status_code=1
          ;;
        ufw)
          setup_ufw "$dry_run" || status_code=1
          ;;
        ssh_hardening)
          setup_ssh_hardening "$skip_ssh_check" "$dry_run" || status_code=1
          ;;
        fail2ban)
          setup_fail2ban "$dry_run" || status_code=1
          ;;
        dns)
          setup_dns "auto" "$dry_run" || status_code=1
          ;;
        sysctl)
          setup_sysctl "$dry_run" || status_code=1
          ;;
        journald)
          setup_journald "$dry_run" || status_code=1
          ;;
        unattended_upgrades)
          setup_unattended_upgrades "$dry_run" || status_code=1
          ;;
        snap_retention)
          setup_snap_retention "$dry_run" || status_code=1
          ;;
        php_timezone)
          setup_php_timezone "$target_tz" "$dry_run" || status_code=1
          ;;
        nginx_security)
          setup_nginx_security "$dry_run" || status_code=1
          ;;
        smtp)
          setup_smtp "" "587" "" "" "$dry_run" || status_code=1
          ;;
        certbot)
          setup_certbot "$dry_run" || status_code=1
          ;;
        netdata)
          setup_netdata "$dry_run" || status_code=1
          ;;
        rclone)
          setup_rclone "$dry_run" || status_code=1
          ;;
      esac

      if [[ $status_code -eq 0 ]]; then
        set_mod_status "$mod" "SUCCESS"
      elif [[ $status_code -eq 2 ]]; then
        set_mod_status "$mod" "EXISTS"
      else
        log_warn "$(_t "SERVER_INSTALL_WARN_MOD_FAILED" "$mod")"
        set_mod_status "$mod" "FAILED"
        install_failed=1
        if [[ "$mod" == "cloudpanel" ]]; then
          log_error "$(_t "SERVER_INSTALL_ERR_CORE_FAILED")"
          core_failed=1
        fi
      fi
    else
      set_mod_status "$mod" "SKIPPED"
    fi
  done

  # 輸出安裝總結
  local server_ip
  server_ip=$(get_server_ip)

  echo ""
  echo "=============================================================================="
  echo -e " ${C_BOLD}${C_GREEN}$(_t "SERVER_INSTALL_SUMMARY_TITLE")${C_NC}"
  echo "=============================================================================="
  printf "  %-25s %-12s %s\n" "$(_t "SERVER_INSTALL_COL_CODE")" "$(_t "SERVER_INSTALL_COL_STATUS")" "$(_t "SERVER_INSTALL_COL_MODULE")"
  echo "  ----------------------------------------------------------------------------"
  for mod in "${MODULES[@]}"; do
    local st
    st="$(get_mod_status "$mod")"
    local color="${C_NC}"
    case "$st" in
      SUCCESS) color="${C_GREEN}" ;;
      EXISTS)  color="${C_CYAN}" ;;
      FAILED)  color="${C_RED}" ;;
      SKIPPED) color="${C_YELLOW}" ;;
    esac
    printf "  %-25s %b%-12s%b %s\n" "$mod" "$color" "$st" "$C_NC" "$(get_mod_desc "$mod" "$db_engine")"
  done
  echo "=============================================================================="
  if [[ "$clp_already_installed" == "true" ]]; then
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_CURRENT_DB" "${C_BOLD}${installed_db_info}${C_NC}")"
  else
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_TARGET_DB" "${C_BOLD}$(format_db_engine_label "$db_engine")${C_NC}" "${db_engine}")"
  fi
  echo -e " $(_t "SERVER_INSTALL_SUMMARY_TARGET_TZ" "${C_BOLD}${target_tz}${C_NC}")"
  echo "=============================================================================="
  echo ""
  # CloudPanel 核心沒有安裝成功時，不顯示「建立管理員」等後續步驟
  if [[ "$core_failed" -eq 1 ]]; then
    log_error "$(_t "SERVER_INSTALL_ERR_CORE_FAILED")"
    return 1
  fi
  echo -e "${C_BOLD}${C_CYAN}$(_t "SERVER_INSTALL_SUMMARY_NEXT_STEPS")${C_NC}"
  if [[ "$clp_already_installed" == "true" && $existing_admin_count -gt 0 ]]; then
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_ADMIN_EXISTS")"
    echo -e "    👉 ${C_BOLD}https://${server_ip}:8443/login${C_NC}"
    echo -e "    $(_t "SERVER_INSTALL_SUMMARY_NEXT_RESET_HINT")"
  else
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_CREATE_ADMIN")"
    echo -e "    👉 ${C_BOLD}https://${server_ip}:8443${C_NC}"
  fi
  echo ""
  if [[ "$(get_mod_status ssh_hardening)" == "SUCCESS" ]]; then
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_SSH_HARDENED")"
  fi
  if [[ "$(get_mod_status certbot)" == "SUCCESS" ]]; then
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_CERTBOT")"
  fi
  if [[ "$(get_mod_status rclone)" == "SUCCESS" ]]; then
    echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_RCLONE")"
  fi
  echo ""
  echo -e " $(_t "SERVER_INSTALL_SUMMARY_NEXT_REBOOT")"
  echo "=============================================================================="
  echo ""
  # 有任何模組失敗時回傳非 0，讓腳本與 CI 能偵測
  return "$install_failed"
}

# ------------------------------------------------------------------------------
# 4. Status & Security Audit Dashboard (clp server / status / audit)
# ------------------------------------------------------------------------------
server_status() {
  local hostname_str os_str kernel_str uptime_str server_ip date_str
  local load_str cpu_cores mem_used mem_total mem_pct swap_used swap_total swap_pct swappiness_val disk_info

  # 1. 蒐集系統概要資訊
  hostname_str=$(hostname 2>/dev/null || echo "unknown")
  if [[ -f /etc/os-release ]]; then
    os_str=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"' || uname -s)
  else
    os_str="$(uname -s) $(uname -r)"
  fi
  kernel_str=$(uname -r)
  server_ip=$(get_server_ip)
  date_str=$(date '+%Y-%m-%d %H:%M:%S (%Z)')
  cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

  # Uptime
  if command -v uptime >/dev/null 2>&1; then
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'( |,|:)+' '{if ($7=="min") m=$6; else {h=$6;m=$7}} {print h"h "m"m"}')
  else
    uptime_str="N/A"
  fi

  # Load average
  if [[ -f /proc/loadavg ]]; then
    load_str=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
  else
    load_str="N/A"
  fi

  # Memory & Swap
  if command -v free >/dev/null 2>&1; then
    local m_out
    m_out=$(LC_ALL=C free -m)  # 解析英文欄位名稱（Mem:、Swap:），不受語系影響
    local mem_tot mem_usd swap_tot swap_usd
    mem_tot=$(echo "$m_out" | awk '/^Mem:/{print $2}')
    mem_usd=$(echo "$m_out" | awk '/^Mem:/{print $3}')
    swap_tot=$(echo "$m_out" | awk '/^Swap:/{print $2}')
    swap_usd=$(echo "$m_out" | awk '/^Swap:/{print $3}')

    mem_total=$(awk -v t="$mem_tot" 'BEGIN{printf "%.1fG", t/1024}')
    mem_used=$(awk -v u="$mem_usd" 'BEGIN{printf "%.1fG", u/1024}')
    if [[ $mem_tot -gt 0 ]]; then
      mem_pct=$(awk -v u="$mem_usd" -v t="$mem_tot" 'BEGIN{printf "%.1f%%", (u*100)/t}')
    else
      mem_pct="0%"
    fi

    if [[ -n "$swap_tot" && $swap_tot -gt 0 ]]; then
      swap_total=$(awk -v t="$swap_tot" 'BEGIN{printf "%.1fG", t/1024}')
      swap_used=$(awk -v u="$swap_usd" 'BEGIN{printf "%.1fM", u}')
      swap_pct=$(awk -v u="$swap_usd" -v t="$swap_tot" 'BEGIN{printf "%.1f%%", (u*100)/t}')
    else
      swap_total="0G"
      swap_used="0M"
      swap_pct="0%"
    fi
  else
    mem_used="N/A"; mem_total="N/A"; mem_pct="N/A"
    swap_used="N/A"; swap_total="N/A"; swap_pct="N/A"
  fi

  swappiness_val=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")

  # Disk usage of /
  if command -v df >/dev/null 2>&1; then
    local df_line
    df_line=$(df -h / | tail -n 1)
    local d_usd d_tot d_pct
    d_usd=$(echo "$df_line" | awk '{print $3}')
    d_tot=$(echo "$df_line" | awk '{print $2}')
    d_pct=$(echo "$df_line" | awk '{print $5}')
    disk_info="${d_usd} / ${d_tot} (${d_pct})"
  else
    disk_info="N/A"
  fi

  # 2. 檢測關鍵服務運行狀態
  _svc_status() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo -e "${C_GREEN}$(_t "SERVER_DASH_SVC_RUNNING")${C_NC}"
    else
      echo -e "${C_RED}$(_t "SERVER_DASH_SVC_STOPPED")${C_NC}"
    fi
  }

  # Database engine info
  local db_engine_info
  db_engine_info=$(get_database_engine_info)

  # CloudPanel version
  local clp_ver
  clp_ver=$(get_clp_version)

  local clp_status
  if systemctl is-active --quiet clp-nginx 2>/dev/null || systemctl is-active --quiet cloudpanel 2>/dev/null; then
    clp_status="${C_GREEN}$(_t "SERVER_DASH_SVC_RUNNING")${C_NC}"
  else
    clp_status="${C_RED}$(_t "SERVER_DASH_SVC_STOPPED")${C_NC}"
  fi

  # Nginx
  local nginx_status nginx_ver
  nginx_status=$(_svc_status nginx)
  nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "$(_t "SERVER_DASH_UNKNOWN")")

  # PHP-FPM
  local php_fpm_str=""
  # 先存成變數再 grep：直接接 grep -q 時 systemctl 可能收到 SIGPIPE，在 pipefail 下誤判為未安裝
  local unit_files
  unit_files=$(systemctl list-unit-files 2>/dev/null || true)
  for php_svc in $(grep -oE 'php[0-9.]+-fpm\.service' <<< "$unit_files" | sort -r || true); do
    local v
    v=$(echo "$php_svc" | grep -oE '[0-9]+\.[0-9]+')
    if systemctl is-active --quiet "$php_svc" 2>/dev/null; then
      php_fpm_str+="${C_GREEN}🟢 ${v}${C_NC} "
    else
      php_fpm_str+="${C_RED}🔴 ${v}${C_NC} "
    fi
  done
  [[ -z "$php_fpm_str" ]] && php_fpm_str="${C_YELLOW}$(_t "SERVER_DASH_PHP_NOT_DETECTED")${C_NC}"

  # Database (MySQL / MariaDB)
  local db_status="${C_YELLOW}$(_t "SERVER_DASH_NOT_INSTALLED")${C_NC}"
  local db_port="3306"
  local db_label="${db_engine_info:-$(_t "SERVER_DASH_DB_FALLBACK")}"
  if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    db_status="${C_GREEN}$(_t "SERVER_DASH_DB_RUNNING" "${db_label}" "${db_port}")${C_NC}"
  elif grep -qiE 'mysql|mariadb' <<< "$unit_files"; then
    db_status="${C_RED}$(_t "SERVER_DASH_DB_STOPPED" "${db_label}" "${db_port}")${C_NC}"
  fi

  # Redis
  local redis_status="${C_YELLOW}$(_t "SERVER_DASH_NOT_INSTALLED")${C_NC}"
  if systemctl is-active --quiet redis 2>/dev/null || systemctl is-active --quiet redis-server 2>/dev/null; then
    redis_status="${C_GREEN}$(_t "SERVER_DASH_REDIS_RUNNING")${C_NC}"
  elif grep -qiE 'redis' <<< "$unit_files"; then
    redis_status="${C_RED}$(_t "SERVER_DASH_REDIS_STOPPED")${C_NC}"
  fi

  # UFW
  local ufw_status="${C_RED}$(_t "SERVER_DASH_UFW_DISABLED")${C_NC}"
  local icmp_status=""
  if command -v ufw >/dev/null 2>&1; then
    local ufw_out
    ufw_out=$(LC_ALL=C ufw status 2>/dev/null || true)
    if grep -q "Status: active" <<< "$ufw_out"; then
      ufw_status="${C_GREEN}$(_t "SERVER_DASH_UFW_ENABLED")${C_NC}"
      if [[ -f /etc/ufw/before.rules ]] && grep -q 'ufw-before-input.*icmp.*DROP' /etc/ufw/before.rules 2>/dev/null; then
        icmp_status="$(_t "SERVER_DASH_ICMP_BLOCKED")"
      else
        icmp_status="$(_t "SERVER_DASH_ICMP_ALLOWED")"
      fi
      ufw_status="${ufw_status}${icmp_status}"
    fi
  fi

  # Fail2ban
  local f2b_status="${C_YELLOW}$(_t "SERVER_DASH_NOT_INSTALLED")${C_NC}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
      local banned_count
      banned_count=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned:" | awk '{print $4}' || echo "0")
      f2b_status="${C_GREEN}$(_t "SERVER_DASH_F2B_RUNNING" "${banned_count:-0}")${C_NC}"
    else
      f2b_status="${C_RED}$(_t "SERVER_DASH_F2B_STOPPED")${C_NC}"
    fi
  fi

  # 3. 資安防護稽核
  local audit_ssh audit_ufw audit_nginx audit_upgrades audit_journald

  # SSH 稽核
  local ssh_passauth
  ssh_passauth=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}' || true)
  if [[ "$ssh_passauth" == "no" ]]; then
    audit_ssh="${C_GREEN}$(_t "SERVER_AUDIT_SSH_PASS_DISABLED")${C_NC}"
  else
    audit_ssh="${C_RED}$(_t "SERVER_AUDIT_SSH_PASS_ENABLED")${C_NC}"
  fi

  # UFW 埠號稽核
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q "Status: active"; then
    audit_ufw="${C_GREEN}$(_t "SERVER_AUDIT_UFW_ACTIVE")${C_NC}"
  else
    audit_ufw="${C_RED}$(_t "SERVER_AUDIT_UFW_INACTIVE")${C_NC}"
  fi

  # Nginx 全域防護
  if [[ -f "/etc/nginx/clp-security.conf" ]] && grep -q "CloudPanel Custom Security Rules" /etc/nginx/clp-security.conf 2>/dev/null && \
     grep -qF "include /etc/nginx/clp-security.conf;" /etc/nginx/global_settings 2>/dev/null; then
    audit_nginx="${C_GREEN}$(_t "SERVER_AUDIT_NGINX_PROTECTED")${C_NC}"
  else
    audit_nginx="${C_YELLOW}$(_t "SERVER_AUDIT_NGINX_UNPROTECTED")${C_NC}"
  fi

  # 自動安全性更新
  if dpkg -s unattended-upgrades 2>/dev/null | grep -q "Status: install ok installed"; then
    audit_upgrades="${C_GREEN}$(_t "SERVER_AUDIT_AUTOUP_ENABLED")${C_NC}"
  else
    audit_upgrades="${C_YELLOW}$(_t "SERVER_AUDIT_AUTOUP_DISABLED")${C_NC}"
  fi

  # Journald 上限
  # drop-in（新版）或舊版直接寫在 journald.conf
  if grep -qs '^SystemMaxUse=500M' /etc/systemd/journald.conf.d/99-clp.conf /etc/systemd/journald.conf; then
    audit_journald="${C_GREEN}$(_t "SERVER_AUDIT_JOURNALD_LIMITED")${C_NC}"
  else
    audit_journald="${C_YELLOW}$(_t "SERVER_AUDIT_JOURNALD_UNLIMITED")${C_NC}"
  fi

  # 輸出看板
  echo -e "${C_CYAN}${C_BOLD}"
  echo "======================================================================"
  echo "$(_t "SERVER_DASH_BANNER_TITLE")"
  echo "======================================================================"
  echo -e "${C_NC}"

  echo -e "${C_BOLD}$(_t "SERVER_DASH_SEC_OVERVIEW")${C_NC}"
  printf "$(_t "SERVER_DASH_ROW_HOSTNAME_OS")" "$hostname_str" "$os_str" "$(uname -m)"
  printf "$(_t "SERVER_DASH_ROW_KERNEL_UPTIME")" "$kernel_str" "$uptime_str"
  printf "$(_t "SERVER_DASH_ROW_IP_TIME")" "$server_ip" "$date_str"
  printf "$(_t "SERVER_DASH_ROW_LOAD_CPU")" "$load_str" "$cpu_cores"
  printf "$(_t "SERVER_DASH_ROW_MEM_SWAP")" \
    "${mem_used} / ${mem_total} (${mem_pct})" \
    "$swap_used" "$swap_total" "$swap_pct" "$swappiness_val"
  printf "$(_t "SERVER_DASH_ROW_DISK")" "$disk_info"
  echo ""

  echo -e "${C_BOLD}$(_t "SERVER_DASH_SEC_SERVICES")${C_NC}"
  local clp_db_display=""
  [[ -n "$db_engine_info" ]] && clp_db_display=" / ${db_engine_info}"
  printf "$(_t "SERVER_DASH_ROW_CLP")" "$clp_status" "$clp_ver" "$clp_db_display"
  printf "$(_t "SERVER_DASH_ROW_NGINX")" "$nginx_status" "$nginx_ver"
  printf "$(_t "SERVER_DASH_ROW_PHP")" "$php_fpm_str"
  printf "$(_t "SERVER_DASH_ROW_DB")" "$db_status"
  printf "$(_t "SERVER_DASH_ROW_REDIS")" "$redis_status"
  printf "$(_t "SERVER_DASH_ROW_UFW")" "$ufw_status"
  printf "$(_t "SERVER_DASH_ROW_F2B")" "$f2b_status"
  echo ""

  echo -e "${C_BOLD}$(_t "SERVER_DASH_SEC_AUDIT")${C_NC}"
  echo -e "  $audit_ssh"
  echo -e "  $audit_ufw"
  echo -e "  $audit_nginx"
  echo -e "  $audit_upgrades"
  echo -e "  $audit_journald"
  echo -e "${C_CYAN}======================================================================${C_NC}"
  echo ""
  return 0
}

# ------------------------------------------------------------------------------
# 5. Security Hardening Subcommand (clp server -harden / harden)
# ------------------------------------------------------------------------------
# _harden_ask <dry_run> <prompt>：dry-run 時不詢問，直接當作同意（各 setup_* 只會列出動作）
_harden_ask() {
  [[ "$1" == "true" ]] || prompt_confirm "$2" "y"
}

server_harden() {
  # -dry-run：不詢問、不修改，逐項列出會做的事
  local hd_dry=false
  if has_opt "dry-run" || has_opt "dry_run"; then
    hd_dry=true
  fi
  # 每一項都會詢問；沒有終端機又沒有 -y 時在任何修改之前報錯
  if [[ "$hd_dry" != "true" ]]; then
    require_tty_or_yes || return 1
  fi
  log_step "$(_t "SERVER_HARDEN_STEP_START")"
  echo ""

  local applied_count=0

  # [1/7] UFW 防火牆加固
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_UFW_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_UFW_PROMPT")"; then
    if setup_ufw "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_UFW_SKIPPED")"
  fi
  echo ""

  # [2/7] SSH 安全加固
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_SSH_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_SSH_PROMPT")"; then
    if setup_ssh_hardening "false" "$hd_dry" && [[ "${SSH_HARDEN_SKIPPED:-0}" -eq 0 ]]; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_SSH_SKIPPED")"
  fi
  echo ""

  # [3/7] Fail2ban 入侵防護
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_F2B_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_F2B_PROMPT")"; then
    if setup_fail2ban "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_F2B_SKIPPED")"
  fi
  echo ""

  # [4/7] Nginx 全域資安防護
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_NGINX_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_NGINX_PROMPT")"; then
    if setup_nginx_security "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_NGINX_SKIPPED")"
  fi
  echo ""

  # [5/7] Linux Kernel Sysctl 調校
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_SYSCTL_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_SYSCTL_PROMPT")"; then
    if setup_sysctl "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_SYSCTL_SKIPPED")"
  fi
  echo ""

  # [6/7] Systemd Journald 日誌限制
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_JOURNALD_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_JOURNALD_PROMPT")"; then
    if setup_journald "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_JOURNALD_SKIPPED")"
  fi
  echo ""

  # [7/7] 自動安全性更新
  echo -e "${C_BOLD}$(_t "SERVER_HARDEN_AUTOUP_TITLE")${C_NC}"
  if _harden_ask "$hd_dry" "$(_t "SERVER_HARDEN_AUTOUP_PROMPT")"; then
    if setup_unattended_upgrades "$hd_dry"; then applied_count=$((applied_count + 1)); fi
  else
    log_info "$(_t "SERVER_HARDEN_AUTOUP_SKIPPED")"
  fi
  echo ""

  if [[ "$hd_dry" == "true" ]]; then
    log_info "$(_t "SERVER_HARDEN_DRY_RUN_DONE")"
  else
    log_success "$(_t "SERVER_HARDEN_SUCCESS" "${applied_count}")"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# 6. Auxiliary Component Installer Subcommand (-install=... / -install=all)
# ------------------------------------------------------------------------------
server_install_component() {
  local comp
  local comp_failed=0
  local comp_tz=""
  local non_interactive="false"
  if has_opt "y" || has_opt "yes" || [[ ! -t 0 ]]; then
    non_interactive="true"
  fi
  comp=$(opt_get "install" "")
  comp=$(echo "$comp" | tr '[:upper:]' '[:lower:]')

  case "$comp" in
    netdata)
      setup_netdata "false"
      ;;
    rclone)
      setup_rclone "false"
      ;;
    certbot)
      setup_certbot "false"
      ;;
    wordfence)
      log_error "$(_t "SERVER_WORDFENCE_ERR_EOL")"
      return 1
      ;;
    smtp)
      setup_smtp "" "587" "" "" "false"
      ;;
    basics)
      comp_tz=$(resolve_server_timezone "$non_interactive") || return 1
      setup_system_basics "$comp_tz" "false"
      ;;
    all)
      require_tty_or_yes || return 1
      log_step "$(_t "SERVER_COMP_STEP_BATCH")"
      echo ""
      if prompt_confirm "$(_t "SERVER_COMP_PROMPT_NETDATA")" "y"; then
        setup_netdata "false" || comp_failed=1
      fi
      if prompt_confirm "$(_t "SERVER_COMP_PROMPT_RCLONE")" "y"; then
        setup_rclone "false" || comp_failed=1
      fi
      if prompt_confirm "$(_t "SERVER_COMP_PROMPT_CERTBOT")" "y"; then
        setup_certbot "false" || comp_failed=1
      fi
      if prompt_confirm "$(_t "SERVER_COMP_PROMPT_SMTP")" "n"; then
        setup_smtp "" "587" "" "" "false" || comp_failed=1
      fi
      if prompt_confirm "$(_t "SERVER_COMP_PROMPT_BASICS")" "y"; then
        if comp_tz=$(resolve_server_timezone "$non_interactive"); then
          setup_system_basics "$comp_tz" "false" || comp_failed=1
        else
          comp_failed=1
        fi
      fi
      if [[ "$comp_failed" -eq 1 ]]; then
        log_warn "$(_t "SERVER_COMP_WARN_BATCH_PARTIAL")"
        return 1
      fi
      log_success "$(_t "SERVER_COMP_SUCCESS_BATCH")"
      ;;
    *)
      log_error "$(_t "SERVER_COMP_ERR_UNKNOWN" "$comp")"
      return 1
      ;;
  esac
  return 0
}

# ------------------------------------------------------------------------------
# 7. Daily Maintenance Subcommands
# ------------------------------------------------------------------------------

# UFW Maintenance
server_ufw() {
  local ufw_opt
  ufw_opt=$(opt_get "ufw" "")
  ufw_opt=$(echo "$ufw_opt" | tr '[:upper:]' '[:lower:]')

  # 啟用 / 停用
  if [[ "$ufw_opt" == "on" || "$ufw_opt" == "enable" ]]; then
    # 啟用（default deny）前先確保 SSH 埠有允許規則，否則現有連線斷線後就無法再登入
    local ssh_ports sp
    if ! ssh_ports=$(ssh_detect_ports); then
      log_error "$(_t "SERVER_UFW_ERR_SSH_PORT_UNKNOWN")"
      return 1
    fi
    for sp in $ssh_ports; do
      if ! ufw_port_has_rule "$sp"; then
        log_info "$(_t "SERVER_UFW_MANAGE_INFO_ADD_SSH" "$sp")"
        if ! ufw allow "${sp}/tcp" comment 'SSH'; then
          log_error "$(_t "SERVER_UFW_ERR_ALLOW_SSH" "$sp")"
          return 1
        fi
      fi
    done
    log_info "$(_t "SERVER_UFW_MANAGE_INFO_ENABLING")"
    if ! ufw --force enable; then
      log_error "$(_t "SERVER_UFW_ERR_ENABLE")"
      return 1
    fi
    log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_ENABLED")"
    return 0
  elif [[ "$ufw_opt" == "off" || "$ufw_opt" == "disable" ]]; then
    log_info "$(_t "SERVER_UFW_MANAGE_INFO_DISABLING")"
    ufw disable
    log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_DISABLED")"
    return 0
  fi

  # 放行連接埠 (-allow=PORT)
  if has_opt "allow"; then
    local p
    p=$(opt_get "allow")
    if [[ -z "$p" || "$p" == "true" ]]; then
      log_error "$(_t "SERVER_UFW_MANAGE_ERR_NO_PORT" "allow")"
      return 1
    fi
    log_info "$(_t "SERVER_UFW_MANAGE_INFO_ALLOWING" "${p}")"
    if ! ufw allow "$p"; then
      log_error "$(_t "SERVER_UFW_MANAGE_ERR_FAILED" "$p")"
      return 1
    fi
    log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_ALLOWED" "${p}")"
    return 0
  fi

  # 阻擋/刪除連接埠 (-deny=PORT)
  #   不處理目前的 SSH 埠；有對應的 allow 規則（p、p/tcp、p/udp）時刪除它。
  #   ufw delete 找不到完全相符的規則時仍回傳 0，所以先用 ufw show added 確認；
  #   沒有 allow 規則時才加 deny，並插在最前面（ufw 採用第一條符合的規則，附加在後面可能無效）
  if has_opt "deny"; then
    local p
    p=$(opt_get "deny")
    if [[ -z "$p" || "$p" == "true" ]]; then
      log_error "$(_t "SERVER_UFW_MANAGE_ERR_NO_PORT" "deny")"
      return 1
    fi
    # 只接受單一數字埠號（可加 /tcp、/udp）；服務名稱、範圍、清單可能涵蓋 SSH 埠，請直接使用 ufw
    if ! [[ "$p" =~ ^[0-9]+(/(tcp|udp))?$ ]]; then
      log_error "$(_t "SERVER_UFW_MANAGE_ERR_DENY_FORMAT" "$p")"
      return 1
    fi
    local ssh_ports sp
    if ! ssh_ports=$(ssh_detect_ports); then
      log_error "$(_t "SERVER_UFW_ERR_SSH_PORT_UNKNOWN")"
      return 1
    fi
    for sp in $ssh_ports; do
      if [[ "${p%%/*}" == "$sp" ]]; then
        log_error "$(_t "SERVER_UFW_MANAGE_ERR_DENY_SSH" "$p")"
        return 1
      fi
    done
    log_info "$(_t "SERVER_UFW_MANAGE_INFO_DENYING" "${p}")"
    local added variant deleted=0
    added=$(ufw show added 2>/dev/null || true)
    for variant in "$p" "${p%%/*}/tcp" "${p%%/*}/udp"; do
      if awk -v r="ufw allow ${variant}" '$0 == r || index($0, r " ") == 1 { f = 1 } END { exit !f }' <<< "$added"; then
        if ufw --force delete allow "$variant" >/dev/null; then
          deleted=1
          log_info "$(_t "SERVER_UFW_MANAGE_INFO_DELETED_RULE" "allow ${variant}")"
        fi
      fi
      [[ "$p" == */* ]] && break
    done
    if [[ "$deleted" -eq 0 ]]; then
      if ! ufw insert 1 deny "$p" 2>/dev/null && ! ufw deny "$p"; then
        log_error "$(_t "SERVER_UFW_MANAGE_ERR_FAILED" "$p")"
        return 1
      fi
    fi
    log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_DENIED" "${p}")"
    return 0
  fi

  # Ping (ICMP) 控制 (-icmp=drop|allow)
  if has_opt "icmp"; then
    local mode
    mode=$(opt_get "icmp")
    if [[ ! -f /etc/ufw/before.rules ]]; then
      log_error "$(_t "SERVER_UFW_MANAGE_ERR_RULES_NOT_FOUND")"
      return 1
    fi
    backup_file /etc/ufw/before.rules
    if [[ "$mode" == "drop" || "$mode" == "deny" || "$mode" == "off" ]]; then
      log_info "$(_t "SERVER_UFW_MANAGE_INFO_ICMP_DROP")"
      sed -i '/ufw-before-input.*icmp.*echo-request/s/ACCEPT/DROP/g' /etc/ufw/before.rules
      ufw reload
      log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_ICMP_DROP")"
    else
      log_info "$(_t "SERVER_UFW_MANAGE_INFO_ICMP_ALLOW")"
      sed -i '/ufw-before-input.*icmp.*echo-request/s/DROP/ACCEPT/g' /etc/ufw/before.rules
      ufw reload
      log_success "$(_t "SERVER_UFW_MANAGE_SUCCESS_ICMP_ALLOW")"
    fi
    return 0
  fi

  # 預設：查看詳細狀態與規則
  log_step "$(_t "SERVER_UFW_MANAGE_STEP_STATUS")"
  ufw status verbose
  return 0
}

# SSH Maintenance
server_ssh() {
  if has_opt "harden"; then
    setup_ssh_hardening "false" "false"
    return 0
  fi

  # 緊急復原允許密碼登入 (-unharden)
  if has_opt "unharden"; then
    log_warn "======================================================================"
    log_warn "$(_t "SERVER_SSH_MANAGE_WARN_EMERGENCY")"
    log_warn "$(_t "SERVER_SSH_MANAGE_WARN_RISK")"
    log_warn "======================================================================"

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"
    # 修改前快照；任何一步失敗都還原，不留下改到一半的設定
    local snap
    if ! snap=$(ssh_config_snapshot); then
      log_error "$(_t "SERVER_SSH_ERR_SNAPSHOT")"
      return 1
    fi

    # 移除或更新 drop-in
    rm -f "/etc/ssh/sshd_config.d/01-clp-hardening.conf"

    # 清理主設定檔中的舊加固區塊與舊緊急復原區塊
    if ! remove_marked_block "$sshd_config" "# === CloudPanel Hardening Settings ===" "# === End CloudPanel Hardening ==="; then
      log_warn "$(_t "SERVER_SSH_WARN_REMOVE_BLOCK_FAILED" "$sshd_config")"
    fi
    if ! remove_marked_block "$sshd_config" "# === CloudPanel Emergency Unharden ===" "# === End CloudPanel Emergency Unharden ==="; then
      log_warn "$(_t "SERVER_SSH_WARN_REMOVE_BLOCK_FAILED" "$sshd_config")"
    fi

    local has_include=false
    if grep -qiE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$sshd_config" 2>/dev/null; then
      has_include=true
    fi

    local emergency_settings="PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes"
    local write_ok=true
    # 若存在 sshd_config.d 且主設定檔有 Include，寫入最高優先權 00-clp-emergency.conf，避免被 50-cloud-init.conf 覆蓋；
    # 否則寫入主設定檔（第一個 Match 之前；沒有 Match 時寫在開頭）。寫入失敗時報錯，不改用會截斷檔案的寫法
    if [[ -d "/etc/ssh/sshd_config.d" && "$has_include" == "true" ]]; then
      ssh_write_file "/etc/ssh/sshd_config.d/00-clp-emergency.conf" "# === CloudPanel Emergency Unharden Drop-in ===
${emergency_settings}
# === End CloudPanel Emergency Unharden ===" || write_ok=false
    else
      ssh_insert_block "$sshd_config" "# === CloudPanel Emergency Unharden ===
${emergency_settings}
# === End CloudPanel Emergency Unharden ===" || write_ok=false
    fi

    local sshd_err=""
    if [[ "$write_ok" == "true" ]] && sshd_err=$(ssh_config_test); then
      rm -rf "$snap"
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
      log_success "$(_t "SERVER_SSH_MANAGE_SUCCESS_UNHARDEN")"

      # 檢查實際生效之 PasswordAuthentication
      local active_passauth
      active_passauth=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}' || echo "unknown")
      if [[ "$active_passauth" != "yes" ]]; then
        log_warn "$(_t "SERVER_SSH_MANAGE_WARN_PASSAUTH_NOT_ENABLED" "$active_passauth")"
      fi
    else
      [[ "$write_ok" == "true" ]] || log_error "$(_t "SERVER_SSH_MANAGE_ERR_WRITE")"
      log_error "$(_t "SERVER_SSH_MANAGE_ERR_SYNTAX")"
      [[ -n "$sshd_err" ]] && log_error "$sshd_err"
      if ssh_config_restore "$snap"; then
        rm -rf "$snap"
      else
        log_error "$(_t "SERVER_SSH_ERR_RESTORE" "$snap")"
      fi
      return 1
    fi
    return 0
  fi

  # 預設：檢視目前 SSH 設定與金鑰狀況
  log_step "$(_t "SERVER_SSH_MANAGE_STEP_STATUS")"
  local passauth rootlogin port
  passauth=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication' | awk '{print $2}' || echo "unknown")
  rootlogin=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' | awk '{print $2}' || echo "unknown")
  port=$(sshd -T 2>/dev/null | grep -i '^port' | awk '{print $2}' || echo "22")

  local root_keys=0 sudo_keys=0
  if [[ -f /root/.ssh/authorized_keys ]]; then
    root_keys=$(grep -cE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-)' /root/.ssh/authorized_keys 2>/dev/null || true)
    root_keys="${root_keys:-0}"
  fi
  if [[ -n "${SUDO_USER:-}" && -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then
    sudo_keys=$(grep -cE '^[[:space:]]*(ssh-(rsa|ed25519|dss)|ecdsa-sha2-|sk-)' "/home/${SUDO_USER}/.ssh/authorized_keys" 2>/dev/null || true)
    sudo_keys="${sudo_keys:-0}"
  fi

  printf "$(_t "SERVER_SSH_MANAGE_ROW_PORT")\n" "${port}"
  printf "$(_t "SERVER_SSH_MANAGE_ROW_PASSAUTH")\n" "${passauth}"
  printf "$(_t "SERVER_SSH_MANAGE_ROW_ROOTLOGIN")\n" "${rootlogin}"
  printf "$(_t "SERVER_SSH_MANAGE_ROW_ROOT_KEYS")\n" "${root_keys}"
  if [[ -n "${SUDO_USER:-}" ]]; then
    printf "$(_t "SERVER_SSH_MANAGE_ROW_SUDO_KEYS")\n" "${SUDO_USER}" "${sudo_keys}"
  fi
  echo ""
  if [[ "$passauth" == "yes" ]]; then
    log_warn "$(_t "SERVER_SSH_MANAGE_WARN_DISABLE_PW")"
  fi
  return 0
}

# Fail2ban Maintenance
server_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1 || [[ ! -d /etc/fail2ban ]]; then
    log_warn "$(_t "SERVER_F2B_MANAGE_WARN_NOT_INSTALLED")"
    log_info "$(_t "SERVER_F2B_MANAGE_INFO_HINT_INSTALL")"
    return 0
  fi

  if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    log_warn "$(_t "SERVER_F2B_MANAGE_WARN_STOPPED")"
  fi

  # 一鍵解鎖所有 IP (-unban=all)
  if has_opt "unban"; then
    local target_ip
    target_ip=$(opt_get "unban")
    if [[ "$target_ip" == "all" ]]; then
      log_info "$(_t "SERVER_F2B_MANAGE_INFO_UNBAN_ALL")"
      fail2ban-client unban --all 2>/dev/null || {
        # 備援手動輪詢解鎖 sshd
        for ip in $(fail2ban-client status sshd 2>/dev/null | grep "Banned IP list:" | awk -F':' '{print $2}'); do
          fail2ban-client set sshd unbanip "$ip" 2>/dev/null || true
        done
      }
      log_success "$(_t "SERVER_F2B_MANAGE_SUCCESS_UNBAN_ALL")"
      return 0
    else
      log_info "$(_t "SERVER_F2B_MANAGE_INFO_UNBAN_IP" "${target_ip}")"
      if fail2ban-client set sshd unbanip "$target_ip" 2>/dev/null; then
        log_success "$(_t "SERVER_F2B_MANAGE_SUCCESS_UNBAN_IP" "${target_ip}")"
      else
        log_warn "$(_t "SERVER_F2B_MANAGE_WARN_UNBAN_FAIL" "${target_ip}")"
      fi
      return 0
    fi
  fi

  # 加入白名單 (-whitelist=IP)
  if has_opt "whitelist"; then
    local wl_ip
    wl_ip=$(opt_get "whitelist")
    if [[ -z "$wl_ip" || "$wl_ip" == "true" ]]; then
      log_error "$(_t "SERVER_F2B_MANAGE_ERR_WHITELIST_NO_IP")"
      return 1
    fi

    # 僅接受合法的 IP / CIDR；% 是 IPv6 scope，會被 fail2ban 當成插值語法
    if [[ "$wl_ip" == *%* ]] || ! python3 -I -c 'import sys, ipaddress; ipaddress.ip_network(sys.argv[1], strict=False)' "$wl_ip" 2>/dev/null; then
      log_error "$(_t "SERVER_F2B_ERR_INVALID_IP" "$wl_ip")"
      return 1
    fi

    local jail_conf="/etc/fail2ban/jail.local"
    if [[ ! -f "$jail_conf" ]]; then
      setup_fail2ban "false" || return 1
    fi

    backup_file "$jail_conf"

    # [DEFAULT] 一定要有 ignoreip；jail 區段自己的 ignoreip 會蓋掉 [DEFAULT]，所以既有的每一行都補上（完整欄位比對）
    local tmp_jail
    tmp_jail=$(mktemp "/etc/fail2ban/.jail.local.XXXXXX")
    if ! grep -qE '^[[:space:]]*\[DEFAULT\]' "$jail_conf"; then
      printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 %s\n\n' "$wl_ip" > "$tmp_jail"
      # jail.local 比 jail.d 晚讀：jail.d 若在 [DEFAULT] 設了 ignoreip，會被這裡的值取代
      local jaild_conf
      for jaild_conf in /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local; do
        [[ -f "$jaild_conf" ]] || continue
        if grep -qE '^ignoreip[[:space:]]*=' "$jaild_conf"; then
          log_warn "$(_t "SERVER_F2B_WARN_JAILD_IGNOREIP" "$jaild_conf")"
        fi
      done
    fi
    if ! awk -v ip="$wl_ip" '
      function has(line,   v, n, a, i) {
        v = line; sub(/^[^=]*=/, "", v)
        n = split(v, a, /[ \t,]+/)
        for (i = 1; i <= n; i++) if (a[i] == ip) return 1
        return 0
      }
      # 讀兩次：第一次只看 [DEFAULT] 是否已有 ignoreip，第二次輸出
      FNR == 1 { sec = "" }
      /^[ \t]*\[[^]]*\]/ {
        sec = $0; sub(/^[ \t]*\[/, "", sec); sub(/\].*$/, "", sec)
        if (NR == FNR) next
        print
        if (sec == "DEFAULT" && !def_has && !def_done) { print "ignoreip = 127.0.0.1/8 ::1 " ip; def_done = 1 }
        next
      }
      NR == FNR { if (sec == "DEFAULT" && $0 ~ /^ignoreip[ \t]*=/) def_has = 1; next }
      /^ignoreip[ \t]*=/ { if (!has($0)) $0 = $0 " " ip }
      { print }
    ' "$jail_conf" "$jail_conf" >> "$tmp_jail" || ! atomic_replace "$tmp_jail" "$jail_conf"; then
      rm -f "$tmp_jail"
      return 1
    fi
    rm -f "$tmp_jail"

    # 若該 IP 目前在黑名單中，自動同步解鎖
    fail2ban-client set sshd unbanip "$wl_ip" 2>/dev/null || true
    if ! systemctl restart fail2ban 2>/dev/null; then
      log_error "$(_t "SERVER_F2B_ERR_RESTART")"
      return 1
    fi
    log_success "$(_t "SERVER_F2B_MANAGE_SUCCESS_WHITELIST" "${wl_ip}")"
    return 0
  fi

  # 預設：查看詳細攔截狀態與黑名單清單
  log_step "$(_t "SERVER_F2B_MANAGE_STEP_STATUS")"
  fail2ban-client status sshd
  return 0
}

# DNS Maintenance
server_dns() {
  local dns_val
  dns_val=$(opt_get "dns" "")
  dns_val=$(echo "$dns_val" | tr '[:upper:]' '[:lower:]')

  if [[ -n "$dns_val" && "$dns_val" != "true" ]]; then
    # 不認得的名稱（例如打錯的 cloudfare）不可默默套用 Google DNS
    case "$dns_val" in
      auto|google|cloudflare) ;;
      *) log_error "$(_t "SERVER_DNS_ERR_PROVIDER" "$dns_val")"; return 1 ;;
    esac
    setup_dns "$dns_val" "false" || return 1
    return 0
  fi

  # 檢視目前 DNS 解析設定
  log_step "$(_t "SERVER_DNS_MANAGE_STEP_CONFIG")"
  if [[ -f /etc/systemd/resolved.conf || -d /etc/systemd/resolved.conf.d ]]; then
    # drop-in 的值優先於 resolved.conf；兩者都列出（含檔名）
    grep -HsE '^(DNS|FallbackDNS)=' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf || echo "$(_t "SERVER_DNS_MANAGE_USING_DEFAULT")"
  fi
  echo ""
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | head -n 25 || true
  fi
  log_info "$(_t "SERVER_DNS_MANAGE_INFO_HINT")"
  return 0
}

# Timezone Maintenance
server_timezone() {
  local tz_val
  tz_val=$(opt_get "timezone" "")

  if [[ -n "$tz_val" && "$tz_val" != "true" ]]; then
    log_info "$(_t "SERVER_TZ_MANAGE_INFO_SETTING" "${tz_val}")"
    # 只設定時區，不再透過 setup_system_basics 執行 apt 與安裝整套工具
    set_system_timezone "$tz_val" || return 1
    setup_php_timezone "$tz_val" "false"
    log_success "$(_t "SERVER_TZ_MANAGE_SUCCESS_SET" "${tz_val}")"
    return 0
  fi

  # 檢視目前系統與 PHP 時區
  log_step "$(_t "SERVER_TZ_MANAGE_STEP_VIEW")"
  printf "$(_t "SERVER_TZ_MANAGE_ROW_SYS_TZ")\n" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || date +%Z)"
  printf "$(_t "SERVER_TZ_MANAGE_ROW_SYS_TIME")\n" "$(date)"
  echo ""
  echo "$(_t "SERVER_TZ_MANAGE_PHP_VERSIONS")"
  for ini in /etc/php/*/cli/php.ini; do
    if [[ -f "$ini" ]]; then
      local ver
      ver=$(echo "$ini" | cut -d'/' -f4)
      local val
      val=$(grep -E '^[[:space:]]*date.timezone' "$ini" | awk '{print $3}' || echo "$(_t "SERVER_TZ_MANAGE_NOT_SET")")
      printf "    PHP %-4s : %s\n" "$ver" "${val:-$(_t "SERVER_TZ_MANAGE_NOT_SET")}"
    fi
  done
  echo ""
  log_info "$(_t "SERVER_TZ_MANAGE_INFO_HINT")"
  return 0
}

# Postfix SMTP Maintenance
server_smtp() {
  if has_opt "config"; then
    setup_smtp "" "587" "" "" "false"
    return 0
  fi

  if has_opt "test"; then
    local test_recipient
    test_recipient=$(opt_get "test")
    if [[ -z "$test_recipient" || "$test_recipient" == "true" ]]; then
      log_error "$(_t "SERVER_SMTP_MANAGE_ERR_RECIPIENT")"
      return 1
    fi
    log_info "$(_t "SERVER_SMTP_MANAGE_INFO_SENDING" "${test_recipient}")"
    local host_str
    host_str=$(hostname)
    echo "This is a verification test email dispatched from CLP Helper (clp server -smtp) on ${host_str}." | \
      mail -s "CloudPanel SMTP Test - ${host_str}" "$test_recipient" 2>/dev/null || true
    log_success "$(_t "SERVER_SMTP_MANAGE_SUCCESS_QUEUED" "${test_recipient}")"
    return 0
  fi

  # 預設：檢視 SMTP 狀態與 relayhost
  log_step "$(_t "SERVER_SMTP_MANAGE_STEP_STATUS")"
  local is_act
  is_act=$(systemctl is-active postfix 2>/dev/null || echo "inactive")
  printf "$(_t "SERVER_SMTP_MANAGE_ROW_STATUS")\n" "${is_act}"
  if [[ -f /etc/postfix/main.cf ]]; then
    local relay
    relay=$(postconf -h relayhost 2>/dev/null || echo "$(_t "SERVER_SMTP_MANAGE_NOT_SET")")
    local inet
    inet=$(postconf -h inet_interfaces 2>/dev/null || echo "all")
    printf "$(_t "SERVER_SMTP_MANAGE_ROW_RELAY")\n" "${relay:-$(_t "SERVER_SMTP_MANAGE_NOT_SET")}"
    printf "$(_t "SERVER_SMTP_MANAGE_ROW_INTERFACES")\n" "${inet}"
  fi
  echo ""
  log_info "$(_t "SERVER_SMTP_MANAGE_INFO_HINT")"
  return 0
}

# Clean / Vacuum Maintenance
server_clean() {
  log_step "$(_t "SERVER_CLEAN_STEP_START")"

  # 紀錄清理前磁碟可用空間
  local avail_before=0 avail_after=0
  if command -v df >/dev/null 2>&1; then
    avail_before=$(df -m / | tail -n1 | awk '{print $4}')
  fi

  # 1. 清理 Journald 日誌至 500M
  log_info "$(_t "SERVER_CLEAN_INFO_JOURNALD")"
  journalctl --vacuum-size=500M 2>/dev/null || true

  # 2. 清理 APT 套件庫快取與孤立套件
  log_info "$(_t "SERVER_CLEAN_INFO_APT")"
  apt-get -o DPkg::Lock::Timeout=60 autoremove -y 2>/dev/null || true
  apt-get -o DPkg::Lock::Timeout=60 clean 2>/dev/null || true

  # 3. 清理舊版已停用的 Snap 套件
  if command -v snap >/dev/null 2>&1; then
    log_info "$(_t "SERVER_CLEAN_INFO_SNAP")"
    snap set system refresh.retain=2 2>/dev/null || true
    snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
      [[ -n "$snapname" && -n "$revision" ]] && snap remove "$snapname" --revision="$revision" 2>/dev/null || true
    done
  fi

  # 4. 清理暫存安裝檔
  log_info "$(_t "SERVER_CLEAN_INFO_TMP")"
  rm -f /tmp/clp_install.* /tmp/netdata-kickstart.* 2>/dev/null || true

  if command -v df >/dev/null 2>&1; then
    avail_after=$(df -m / | tail -n1 | awk '{print $4}')
    local freed=$((avail_after - avail_before))
    if [[ $freed -gt 0 ]]; then
      log_success "$(_t "SERVER_CLEAN_SUCCESS_FREED" "${freed}")"
    else
      log_success "$(_t "SERVER_CLEAN_SUCCESS_HEALTHY")"
    fi
  else
    log_success "$(_t "SERVER_CLEAN_SUCCESS_DONE")"
  fi

  return 0
}

# ------------------------------------------------------------------------------
# 8. Main Dispatcher for Server Module
# ------------------------------------------------------------------------------
server_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  # Help check
  if has_opt "h" || has_opt "help"; then
    show_server_help
    return 0
  fi

  local action=""
  local -a used_pos=()

  # 1. 解析首個位置參數 (相容無前綴減號的子指令)
  if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    local p0="${POSITIONAL[0]}"
    p0=$(echo "$p0" | tr '[:upper:]' '[:lower:]')
    case "$p0" in
      help)
        show_server_help
        return 0
        ;;
      install)  action="install";  used_pos+=("${POSITIONAL[0]}") ;;
      status)   action="status";   used_pos+=("${POSITIONAL[0]}") ;;
      audit)    action="audit";    used_pos+=("${POSITIONAL[0]}") ;;
      harden)   action="harden";   used_pos+=("${POSITIONAL[0]}") ;;
      clean)    action="clean";    used_pos+=("${POSITIONAL[0]}") ;;
      ufw)      action="ufw";      used_pos+=("${POSITIONAL[0]}") ;;
      ssh)      action="ssh";      used_pos+=("${POSITIONAL[0]}") ;;
      fail2ban) action="fail2ban"; used_pos+=("${POSITIONAL[0]}") ;;
      dns)      action="dns";      used_pos+=("${POSITIONAL[0]}") ;;
      timezone) action="timezone"; used_pos+=("${POSITIONAL[0]}") ;;
      smtp)     action="smtp";     used_pos+=("${POSITIONAL[0]}") ;;
      *)        ;;
    esac
  fi

  # 2. 解析選項旗標 (若未由位置參數明確指定 install/harden，則以旗標分流)
  # 已由位置參數指定動作時（例如 server ssh -harden）不再以旗標改判，否則 -harden 會被當成完整的 harden
  if [[ -z "$action" ]]; then
    if has_opt "install"; then
      local opt_val
      opt_val=$(opt_get "install")
      if [[ "$opt_val" == "true" ]]; then
        action="install"
      else
        action="install_comp"
      fi
    elif has_opt "harden" && ! has_opt "ssh"; then
      action="harden"
    elif has_opt "status"; then
      action="status"
    elif has_opt "audit"; then
      action="audit"
    elif has_opt "clean"; then
      action="clean"
    elif has_opt "ufw"; then
      action="ufw"
    elif has_opt "ssh"; then
      action="ssh"
    elif has_opt "fail2ban"; then
      action="fail2ban"
    elif has_opt "dns"; then
      action="dns"
    elif has_opt "timezone"; then
      action="timezone"
    elif has_opt "smtp"; then
      action="smtp"
    fi
  fi

  # 3. 預設動作：未帶任何參數時，預設顯示綜合看板
  if [[ -z "$action" ]]; then
    action="status"
  fi

  # 4. 驗證位置參數是否有多餘項
  reject_extra_positionals raw_args "install|harden|unharden|status|audit|clean|ufw|ssh|fail2ban|dns|timezone|smtp|y|yes|dry-run|force" "${used_pos[@]}" || return 1

  # 5. 前置權限檢查 (所有 server 指令皆須 root 身分)
  check_root

  # 5. 指令調度分流
  if [[ "$action" == "install" ]]; then
    # 全新安裝：僅檢查作業系統，不可檢查 CloudPanel (因為此時尚未安裝)
    check_os
    server_install "$@"
    return $?
  fi

  # 其餘所有日常維運與加固指令，均需驗證 CloudPanel 系統已就緒
  check_cloudpanel

  case "$action" in
    status|audit)
      server_status "$@"
      ;;
    harden)
      server_harden "$@"
      ;;
    install_comp)
      server_install_component "$@"
      ;;
    ufw)
      server_ufw "$@"
      ;;
    ssh)
      server_ssh "$@"
      ;;
    fail2ban)
      server_fail2ban "$@"
      ;;
    dns)
      server_dns "$@"
      ;;
    timezone)
      server_timezone "$@"
      ;;
    smtp)
      server_smtp "$@"
      ;;
    clean)
      server_clean "$@"
      ;;
    *)
      log_error "$(_t "SERVER_ERR_UNKNOWN_OPTION" "$action")"
      echo ""
      show_server_help
      return 1
      ;;
  esac
}
