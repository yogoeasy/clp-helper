#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool Installer
# File: install.sh
# ==============================================================================

set -euo pipefail

CLP_VERSION="1.0.0"
CLP_BUILD_TIME="2026-10-16 17:09:25"

# Colors
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_NC=$'\033[0m'

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/lib/clp-helper"
LEGACY_TARGET_DIR="/home/clp/clp"

# ------------------------------------------------------------------------------
# 1. Parse Command Line Arguments
# ------------------------------------------------------------------------------
cli_lang=""
action="install"
show_help=false
show_version=false

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
    --uninstall|uninstall)
      action="uninstall"
      shift
      ;;
    -h|--help|help)
      show_help=true
      shift
      ;;
    -v|-V|--version|-version|version)
      show_version=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Language Detection Cascade: CLI --lang > CLP_LANG > System Locale > Default (en_US)
# ------------------------------------------------------------------------------
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

detect_language() {
  local chosen_lang=""

  # Priority 1: CLI parameter (--lang=... / -lang=...)
  if [[ -n "$cli_lang" ]]; then
    chosen_lang="$cli_lang"
  # Priority 2: Environment variable CLP_LANG
  elif [[ -n "${CLP_LANG:-}" ]]; then
    chosen_lang="${CLP_LANG}"
  # Priority 3: Global configuration file (same as clp: clp config -set lang=...)
  elif [[ -f /etc/clp/clp.conf ]] && grep -qE '^(CLP_LANG|lang)=' /etc/clp/clp.conf 2>/dev/null; then
    chosen_lang="$(grep -E '^(CLP_LANG|lang)=' /etc/clp/clp.conf 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]')"
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

  # Normalize language string
  chosen_lang="$(normalize_lang "$chosen_lang")"

  # Priority 4: Fallback default to en_US if unsupported
  if [[ "$chosen_lang" != "zh_TW" && "$chosen_lang" != "en_US" ]]; then
    chosen_lang="en_US"
  fi

  echo "$chosen_lang"
}

LANG_CODE="$(detect_language)"
export CLP_LANG="$LANG_CODE"

# ------------------------------------------------------------------------------
# 3. Bilingual Strings
# ------------------------------------------------------------------------------
if [[ "$LANG_CODE" == "zh_TW" ]]; then
  MSG_HELP_BANNER="CLP Helper (clp) 安裝程式"
  MSG_HELP_USAGE="使用方式:"
  MSG_HELP_USAGE_CMD="  sudo bash install.sh [選項]"
  MSG_HELP_OPTIONS="選項:"
  MSG_HELP_OPT_LANG="  --lang=<lang>     指定安裝程式語言 (en_US, zh_TW)"
  MSG_HELP_OPT_UNINSTALL="  --uninstall       從系統中解除安裝 CLP Helper"
  MSG_HELP_OPT_VERSION="  -v, --version     顯示版本資訊"
  MSG_HELP_OPT_HELP="  -h, --help        顯示此說明訊息"

  MSG_ROOT_REQ="[ERROR] 請使用 root 權限執行此安裝程式: sudo bash $0"
  MSG_UNINSTALLING="正在解除安裝 CLP Helper..."
  MSG_UNINSTALLED="CLP Helper 已成功從系統中移除。"
  MSG_UNINSTALL_LEFTOVERS="以下資料未刪除（可能包含 Cloudflare API Token 等機密），若不再需要請手動移除："
  MSG_SRC_ERR_TITLE="[ERROR] 在目前目錄 (%s) 找不到 clp.sh、lib 或 locales 目錄！\n"
  MSG_SRC_ERR_DESC="請確認您是在完整解壓縮的 CLP Helper 專案目錄內執行安裝程式: sudo bash install.sh\n"
  MSG_BANNER_TITLE="          CLP Helper (clp) 安裝程式"
  MSG_SOURCE_DIR="安裝來源目錄: %s\n"
  MSG_TARGET_DIR="安裝目標目錄: %s\n"
  MSG_COPYING="正在複製核心程式檔案到 %s...\n"
  MSG_PERMS="正在配置權限...\n"
  MSG_SYMLINK="建立全域軟連結 /usr/local/bin/clp...\n"
  MSG_READY="已就緒"
  MSG_SUCCESS_BANNER=" 🎉 CLP Helper 安裝成功！(%s)"
  MSG_RUN_ANYWHERE="您現在可以在任何目錄直接執行: %s\n"
  MSG_NOTE_LABEL="提示:"
  MSG_NOTE_LOC="安裝檔案已完整安置於 %s。"
  MSG_NOTE_CLEANUP="您可以安全刪除本次上傳的暫存資料夾 (例如: %s)。\n"
  MSG_PATH_CONFIGURED="[✔] 已自動配置 /etc/profile.d/clp.sh，確保系統登入環境自動載入 /usr/local/bin。"
  MSG_PATH_WARN="備註: 目前系統 PATH 未包含 /usr/local/bin，建議加入 /etc/environment 以便全域直接呼叫。"
  MSG_PATH_ERR="[ERROR] 安裝完成但未能在 PATH 中偵測到 clp 指令，請檢查 /usr/local/bin 是否在 PATH 中。"
  MSG_MIGRATE_LEGACY="[INFO] 偵測到舊版安裝目錄 (%s)，正在自動安全遷移至系統目錄 (%s)...\n"
  MSG_MIGRATE_LEGACY_DONE="[✔] 舊版安裝目錄已成功遷移並移除 (%s)。\n"
else
  MSG_HELP_BANNER="CLP Helper (clp) Installer"
  MSG_HELP_USAGE="Usage:"
  MSG_HELP_USAGE_CMD="  sudo bash install.sh [options]"
  MSG_HELP_OPTIONS="Options:"
  MSG_HELP_OPT_LANG="  --lang=<lang>     Specify installer language (en_US, zh_TW)"
  MSG_HELP_OPT_UNINSTALL="  --uninstall       Uninstall CLP Helper from system"
  MSG_HELP_OPT_VERSION="  -v, --version     Show version information"
  MSG_HELP_OPT_HELP="  -h, --help        Show this help message"

  MSG_ROOT_REQ="[ERROR] Please run this installer with root privileges: sudo bash $0"
  MSG_UNINSTALLING="Uninstalling CLP Helper..."
  MSG_UNINSTALLED="CLP Helper has been successfully removed from the system."
  MSG_UNINSTALL_LEFTOVERS="The following data was kept (it may contain secrets such as the Cloudflare API token). Remove it manually if no longer needed:"
  MSG_SRC_ERR_TITLE="[ERROR] clp.sh, lib, or locales directory not found in current directory (%s)!\n"
  MSG_SRC_ERR_DESC="Please ensure you are running the installer from the extracted CLP Helper project directory: sudo bash install.sh\n"
  MSG_BANNER_TITLE="          CLP Helper (clp) Installer"
  MSG_SOURCE_DIR="Installation source: %s\n"
  MSG_TARGET_DIR="Installation target: %s\n"
  MSG_COPYING="Copying core files to %s...\n"
  MSG_PERMS="Configuring permissions...\n"
  MSG_SYMLINK="Creating global symlink /usr/local/bin/clp...\n"
  MSG_READY="Ready"
  MSG_SUCCESS_BANNER=" 🎉 CLP Helper installed successfully! (%s)"
  MSG_RUN_ANYWHERE="You can now run from any directory: %s\n"
  MSG_NOTE_LABEL="Note:"
  MSG_NOTE_LOC="Installation files are located at %s."
  MSG_NOTE_CLEANUP="You can safely remove the temporary directory (e.g. %s).\n"
  MSG_PATH_CONFIGURED="[✔] Automatically configured /etc/profile.d/clp.sh to ensure /usr/local/bin is in PATH upon login."
  MSG_PATH_WARN="Note: Current system PATH does not include /usr/local/bin. Consider adding it to /etc/environment."
  MSG_PATH_ERR="[ERROR] Installation completed but 'clp' command was not found in PATH. Please verify /usr/local/bin is in PATH."
  MSG_MIGRATE_LEGACY="[INFO] Detected legacy installation directory (%s), automatically migrating to secure system directory (%s)...\n"
  MSG_MIGRATE_LEGACY_DONE="[✔] Legacy installation directory successfully migrated and removed (%s).\n"
fi

# ------------------------------------------------------------------------------
# 4. Handle Help & Version Options
# ------------------------------------------------------------------------------
if [[ "$show_version" == "true" ]]; then
  if [[ "$LANG_CODE" == "zh_TW" ]]; then
    echo "CLP Helper v${CLP_VERSION} (建置時間 ${CLP_BUILD_TIME})"
  else
    echo "CLP Helper v${CLP_VERSION} (build ${CLP_BUILD_TIME})"
  fi
  exit 0
fi

if [[ "$show_help" == "true" ]]; then
  echo -e "${C_CYAN}${C_BOLD}${MSG_HELP_BANNER}${C_NC}"
  echo ""
  echo -e "${C_BOLD}${MSG_HELP_USAGE}${C_NC}"
  echo -e "${MSG_HELP_USAGE_CMD}"
  echo ""
  echo -e "${C_BOLD}${MSG_HELP_OPTIONS}${C_NC}"
  echo -e "${MSG_HELP_OPT_LANG}"
  echo -e "${MSG_HELP_OPT_UNINSTALL}"
  echo -e "${MSG_HELP_OPT_VERSION}"
  echo -e "${MSG_HELP_OPT_HELP}"
  echo ""
  exit 0
fi

# ------------------------------------------------------------------------------
# 5. Check Root Privileges
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo -e "${C_RED}${MSG_ROOT_REQ}${C_NC}" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 6. Handle Uninstall Option
# ------------------------------------------------------------------------------
if [[ "$action" == "uninstall" ]]; then
  echo -e "${C_YELLOW}${MSG_UNINSTALLING}${C_NC}"
  rm -f /usr/local/bin/clp
  rm -f /etc/profile.d/clp.sh
  if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
  fi
  if [[ -d "$LEGACY_TARGET_DIR" ]]; then
    rm -rf "$LEGACY_TARGET_DIR"
  fi
  echo -e "${C_GREEN}${MSG_UNINSTALLED}${C_NC}"
  leftovers=()
  for p in /etc/clp /var/log/clp /root/php /root/.clp /root/clpBackup; do
    [[ -e "$p" ]] && leftovers+=("$p")
  done
  if [[ ${#leftovers[@]} -gt 0 ]]; then
    echo -e "${C_YELLOW}${MSG_UNINSTALL_LEFTOVERS}${C_NC}"
    for p in "${leftovers[@]}"; do
      echo "  - ${p}"
    done
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# 7. Check Source Directory Completeness
# ------------------------------------------------------------------------------
if [[ "${CURRENT_DIR}" != "${TARGET_DIR}" ]]; then
  if [[ ! -f "${CURRENT_DIR}/clp.sh" || ! -d "${CURRENT_DIR}/lib" || ! -d "${CURRENT_DIR}/locales" ]]; then
    echo -e "${C_RED}$(printf "${MSG_SRC_ERR_TITLE}" "${CURRENT_DIR}")${C_NC}" >&2
    echo -e "$(printf "${MSG_SRC_ERR_DESC}")" >&2
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# 8. Display Installer Header
# ------------------------------------------------------------------------------
echo -e "${C_CYAN}${C_BOLD}"
echo "======================================================================"
echo "${MSG_BANNER_TITLE}"
echo "======================================================================"
echo -e "${C_NC}"
printf "${MSG_SOURCE_DIR}" "${CURRENT_DIR}"
printf "${MSG_TARGET_DIR}" "${TARGET_DIR}"
echo ""

# ------------------------------------------------------------------------------
# 9. Create Target Directories
# ------------------------------------------------------------------------------
mkdir -p "$TARGET_DIR"
mkdir -p /var/log/clp
chmod 755 /var/log/clp 2>/dev/null || true

# ------------------------------------------------------------------------------
# 10. Copy Application Files
# ------------------------------------------------------------------------------
if [[ "${CURRENT_DIR}" != "${TARGET_DIR}" ]]; then
  printf "${MSG_COPYING}" "${TARGET_DIR}"
  cp -rf "${CURRENT_DIR}/clp.sh" "$TARGET_DIR/"
  cp -rf "${CURRENT_DIR}/install.sh" "$TARGET_DIR/"
  cp -rf "${CURRENT_DIR}/README"*.md "$TARGET_DIR/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/LICENSE" "$TARGET_DIR/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/lib" "$TARGET_DIR/"
  cp -rf "${CURRENT_DIR}/templates" "$TARGET_DIR/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/locales" "$TARGET_DIR/" 2>/dev/null || true
fi
rm -rf "${TARGET_DIR}/logs" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 11. Configure Ownership and Permissions
# ------------------------------------------------------------------------------
printf "${MSG_PERMS}"
chown -R root:root "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod 755 {} +
find "$TARGET_DIR" -type f -exec chmod 644 {} +
chmod 755 "${TARGET_DIR}/clp.sh"
chmod 755 "${TARGET_DIR}/install.sh"

# ------------------------------------------------------------------------------
# 12. Create Global Symlink
# ------------------------------------------------------------------------------
printf "${MSG_SYMLINK}"
mkdir -p /usr/local/bin
ln -sf "${TARGET_DIR}/clp.sh" /usr/local/bin/clp
hash -r 2>/dev/null || true

# ------------------------------------------------------------------------------
# 12.1 Migrate Legacy Installation Directory (/home/clp/clp -> /usr/local/lib/clp-helper)
# ------------------------------------------------------------------------------
if [[ -d "$LEGACY_TARGET_DIR" && "$LEGACY_TARGET_DIR" != "$TARGET_DIR" ]]; then
  printf "${C_YELLOW}${MSG_MIGRATE_LEGACY}${C_NC}" "$LEGACY_TARGET_DIR" "$TARGET_DIR"
  rm -rf "$LEGACY_TARGET_DIR"
  printf "${C_GREEN}${MSG_MIGRATE_LEGACY_DONE}${C_NC}" "$LEGACY_TARGET_DIR"
fi

# ------------------------------------------------------------------------------
# 13. Verify Installation & PATH Setup
# ------------------------------------------------------------------------------
echo ""
local_bin_in_path=true
if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
  local_bin_in_path=false
  export PATH="/usr/local/bin:$PATH"
fi

if command -v clp >/dev/null 2>&1 || [[ -x /usr/local/bin/clp ]]; then
  CLP_VER=$(clp --lang="$LANG_CODE" -v 2>/dev/null || /usr/local/bin/clp --lang="$LANG_CODE" -v 2>/dev/null || echo "$MSG_READY")
  CLP_VER_DISPLAY="${CLP_VER#CLP Helper }"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "${C_GREEN}${C_BOLD}$(printf "${MSG_SUCCESS_BANNER}" "${CLP_VER_DISPLAY:-$CLP_VER}")${C_NC}"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  printf "${MSG_RUN_ANYWHERE}" "${C_CYAN}sudo clp --help${C_NC}"
  echo ""
  echo -e "${C_YELLOW}${C_BOLD}${MSG_NOTE_LABEL}${C_NC} $(printf "${MSG_NOTE_LOC}" "${C_BOLD}${TARGET_DIR}${C_NC}")"
  # 由 get.sh 執行時，暫存目錄會自動刪除，不需要提示使用者手動清理
  if [[ "${CURRENT_DIR}" != "${TARGET_DIR}" && "${CLP_BOOTSTRAP:-0}" != "1" ]]; then
    case "${CURRENT_DIR}" in
      /|/root|/home|/home/*[!/]|/tmp|/usr|/usr/*|/etc|/etc/*|/var|/opt)
        # 只在 /home/<user> 底下的子目錄（例如 /home/u/clp-helper）才提示刪除
        if [[ "${CURRENT_DIR}" == /home/*/* && "${CURRENT_DIR}" != "${HOME:-/nonexistent}" ]]; then
          printf "${MSG_NOTE_CLEANUP}" "${C_CYAN}rm -rf $(printf '%q' "${CURRENT_DIR}")${C_NC}"
        fi
        ;;
      *)
        printf "${MSG_NOTE_CLEANUP}" "${C_CYAN}rm -rf $(printf '%q' "${CURRENT_DIR}")${C_NC}"
        ;;
    esac
  fi
  if [[ "$local_bin_in_path" == "false" ]]; then
    if [[ -d /etc/profile.d ]]; then
      tmp_profile=$(mktemp "/etc/profile.d/.clp.XXXXXX")
      echo 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="/usr/local/bin:$PATH"; export PATH ;; esac' > "$tmp_profile"
      chmod 644 "$tmp_profile"
      mv -f "$tmp_profile" /etc/profile.d/clp.sh
      echo -e "${C_GREEN}${MSG_PATH_CONFIGURED}${C_NC}"
    else
      echo -e "${C_YELLOW}${MSG_PATH_WARN}${C_NC}"
    fi
  fi
  echo ""
else
  echo -e "${C_RED}${MSG_PATH_ERR}${C_NC}" >&2
  exit 1
fi
