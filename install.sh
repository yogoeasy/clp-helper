#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool Installer
# File: install.sh
# ==============================================================================

set -euo pipefail

CLP_VERSION="1.3.5"
CLP_BUILD_TIME="2026-10-27 22:26:28"

# Colors
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
C_NC=$'\033[0m'

# 實體路徑：來源檢查（第 7.1 節）與之後的執行、複製都用同一個路徑，不經過 symlink
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_DIR="/usr/local/lib/clp-helper"
LEGACY_TARGET_DIR="/home/clp/clp"

# ------------------------------------------------------------------------------
# 1. Parse Command Line Arguments
# ------------------------------------------------------------------------------
cli_lang=""
action="install"
auto_yes=0
show_help=false
show_version=false
unknown_args=()

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
    -y|--yes|-yes)
      auto_yes=1
      shift
      ;;
    *)
      # 不認得的參數（例如打錯的 --unistall）不可變成一般安裝；語系決定後再報錯
      unknown_args+=("$1")
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

# read_conf_lang：clp.local > clp.conf > 安裝來源的 templates/clp.conf（與 lib/conf_read.sh 相同的順序）
# 安裝程式在複製檔案之前就需要判斷語言，不能依賴 lib，所以在這裡內嵌同樣的邏輯。
read_conf_lang() {
  local f v
  for f in /etc/clp/clp.local /etc/clp/clp.conf "${CURRENT_DIR}/templates/clp.conf"; do
    [[ -f "$f" ]] || continue
    v="$(grep -E '^[[:space:]]*(CLP_LANG|clp_lang|lang|LANG)[[:space:]]*=' "$f" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d '"'"'"'[:space:]' || true)"
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  done
  return 1
}

detect_language() {
  local chosen_lang=""
  local conf_lang=""

  # Priority 1: CLI parameter (--lang=... / -lang=...)
  if [[ -n "$cli_lang" ]]; then
    chosen_lang="$cli_lang"
  # Priority 2: Environment variable CLP_LANG (auto = follow the system locale)
  elif [[ -n "${CLP_LANG:-}" && "${CLP_LANG}" != "auto" ]]; then
    chosen_lang="${CLP_LANG}"
  # Priority 3: Global configuration (same as clp: clp config -set lang=...; auto = follow the system locale)
  elif conf_lang="$(read_conf_lang)" && [[ -n "$conf_lang" && "$conf_lang" != "auto" ]]; then
    chosen_lang="$conf_lang"
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
  MSG_ERR_UNKNOWN_ARG="[ERROR] 不認得的參數：%s（可用的選項見 --help）。沒有做任何變更。\n"
  MSG_HELP_USAGE="使用方式:"
  MSG_HELP_USAGE_CMD="  sudo bash install.sh [選項]"
  MSG_HELP_OPTIONS="選項:"
  MSG_HELP_OPT_LANG="  --lang=<lang>     指定安裝程式語言 (en_US, zh_TW)"
  MSG_HELP_OPT_UNINSTALL="  --uninstall       從系統中解除安裝 CLP Helper"
  MSG_HELP_OPT_VERSION="  -v, --version     顯示版本資訊"
  MSG_HELP_OPT_HELP="  -h, --help        顯示此說明訊息"
  MSG_HELP_OPT_YES="  -y, --yes         設定檔需要決定處理方式時，採用建議的選項（不詢問）"
  MSG_CONF_FAILED="[ERROR] 程式檔已安裝，但 /etc/clp 的設定檔處理失敗（見上方訊息）。修正後請重新執行安裝程式。"

  MSG_ROOT_REQ="[ERROR] 請使用 root 權限執行此安裝程式: sudo bash $0"
  MSG_UNINSTALLING="正在解除安裝 CLP Helper..."
  MSG_UNINSTALLED="CLP Helper 已成功從系統中移除。"
  MSG_UNINSTALL_LEFTOVERS="以下資料未刪除（可能包含 Cloudflare API Token 等機密），若不再需要請手動移除："
  MSG_SRC_ERR_TITLE="[ERROR] 在目前目錄 (%s) 找不到 clp.sh、lib 或 locales 目錄！\n"
  MSG_SRC_ERR_DESC="請確認您是在完整解壓縮的 CLP Helper 專案目錄內執行安裝程式: sudo bash install.sh\n"
  MSG_SRC_UNSAFE_TITLE="[ERROR] 安裝來源不安全，已停止：%s（%s）\n"
  MSG_SRC_UNSAFE_DESC="安裝程式會以 root 執行並安裝這個目錄中的檔案；其他帳號能修改或替換它時，就能以 root 執行程式。\n請改用一行安裝（get.sh），或把專案放到 root 或您自己擁有的目錄（例如 /root）後再執行 sudo bash install.sh。\n"
  MSG_SRC_UNSAFE_OWNER="擁有者不是 root 或執行 sudo 的使用者"
  MSG_SRC_UNSAFE_OTHER_W="其他使用者可寫入"
  MSG_SRC_UNSAFE_GROUP_W="非擁有者私人群組的群組可寫入"
  MSG_SRC_UNSAFE_SYMLINK="是 symlink"
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
  MSG_ERR_UNKNOWN_ARG="[ERROR] Unknown argument: %s (see --help for the options). Nothing was changed.\n"
  MSG_HELP_USAGE="Usage:"
  MSG_HELP_USAGE_CMD="  sudo bash install.sh [options]"
  MSG_HELP_OPTIONS="Options:"
  MSG_HELP_OPT_LANG="  --lang=<lang>     Specify installer language (en_US, zh_TW)"
  MSG_HELP_OPT_UNINSTALL="  --uninstall       Uninstall CLP Helper from system"
  MSG_HELP_OPT_VERSION="  -v, --version     Show version information"
  MSG_HELP_OPT_HELP="  -h, --help        Show this help message"
  MSG_HELP_OPT_YES="  -y, --yes         Use the recommended choice when a settings file needs a decision (no prompts)"
  MSG_CONF_FAILED="[ERROR] The program files were installed, but handling the settings files in /etc/clp failed (see above). Fix it and run the installer again."

  MSG_ROOT_REQ="[ERROR] Please run this installer with root privileges: sudo bash $0"
  MSG_UNINSTALLING="Uninstalling CLP Helper..."
  MSG_UNINSTALLED="CLP Helper has been successfully removed from the system."
  MSG_UNINSTALL_LEFTOVERS="The following data was kept (it may contain secrets such as the Cloudflare API token). Remove it manually if no longer needed:"
  MSG_SRC_ERR_TITLE="[ERROR] clp.sh, lib, or locales directory not found in current directory (%s)!\n"
  MSG_SRC_ERR_DESC="Please ensure you are running the installer from the extracted CLP Helper project directory: sudo bash install.sh\n"
  MSG_SRC_UNSAFE_TITLE="[ERROR] Unsafe installation source, stopping: %s (%s)\n"
  MSG_SRC_UNSAFE_DESC="The installer runs and installs the files in this directory as root; any account that can modify or replace them could run code as root.\nUse the one-line install (get.sh), or move the project to a directory owned by root or by you (for example /root) and run sudo bash install.sh again.\n"
  MSG_SRC_UNSAFE_OWNER="not owned by root or by the sudo user"
  MSG_SRC_UNSAFE_OTHER_W="writable by other users"
  MSG_SRC_UNSAFE_GROUP_W="writable by a group other than the owner's private group"
  MSG_SRC_UNSAFE_SYMLINK="is a symlink"
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
if [[ ${#unknown_args[@]} -gt 0 ]]; then
  # shellcheck disable=SC2059
  printf "$MSG_ERR_UNKNOWN_ARG" "${unknown_args[*]}" >&2
  exit 1
fi

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
  echo -e "${MSG_HELP_OPT_YES}"
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
  rm -f /etc/cron.d/clp-helper
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
# 7.1 Check Source Tree Ownership
#     安裝程式以 root 執行來源中的 lib/conf_install.sh，並把來源複製到 TARGET_DIR：
#     其他帳號能修改或替換來源（例如放在網站使用者的家目錄）時，就能以 root 執行程式。
#     來源目錄到 / 的每一層、以及要複製的每個項目：擁有者為 root 或 SUDO_UID；不可 other 可寫
#     （root 擁有且有 sticky 的目錄如 /tmp 例外）；group 可寫只限擁有者的私人群組；不可有 symlink。
#     GitHub tarball 為 uid 0、664／775；一般使用者（umask 002）的 git clone／tar 為自己擁有＋私人群組，都會通過。
# ------------------------------------------------------------------------------
declare -A src_private_gid=()
src_reason=""
# src_check_entry <path>：不安全時設定 src_reason
src_check_entry() {
  local p="$1" s_uid s_gid s_mode mode
  src_reason=""
  if [[ -L "$p" ]]; then
    src_reason="$MSG_SRC_UNSAFE_SYMLINK"
    return 0
  fi
  if ! read -r s_uid s_gid s_mode < <(stat -c '%u %g %a' -- "$p" 2>/dev/null); then
    src_reason="$MSG_SRC_UNSAFE_OWNER"
    return 0
  fi
  mode=$((8#$s_mode))
  if [[ "$s_uid" != "0" && "$s_uid" != "${SUDO_UID:-0}" ]]; then
    src_reason="$MSG_SRC_UNSAFE_OWNER"
  elif (( mode & 8#0002 )) && ! { [[ -d "$p" && "$s_uid" == "0" ]] && (( mode & 8#1000 )); }; then
    src_reason="$MSG_SRC_UNSAFE_OTHER_W"
  elif (( mode & 8#0020 )); then
    if [[ -z "${src_private_gid[$s_uid]+set}" ]]; then
      local pw owner_name owner_gid group_name
      pw="$(getent passwd "$s_uid" || true)"
      owner_name="${pw%%:*}"
      owner_gid="$(cut -d: -f4 <<< "$pw")"
      group_name="$(getent group "$owner_gid" | cut -d: -f1 || true)"
      src_private_gid[$s_uid]=""
      [[ -n "$owner_name" && "$group_name" == "$owner_name" ]] && src_private_gid[$s_uid]="$owner_gid"
    fi
    if [[ -z "${src_private_gid[$s_uid]}" || "$s_gid" != "${src_private_gid[$s_uid]}" ]]; then
      src_reason="$MSG_SRC_UNSAFE_GROUP_W"
    fi
  fi
  return 0
}
src_unsafe() {
  echo -e "${C_RED}$(printf "${MSG_SRC_UNSAFE_TITLE}" "$1" "$src_reason")${C_NC}" >&2
  echo -e "$(printf "${MSG_SRC_UNSAFE_DESC}")" >&2
  exit 1
}
src_path="$CURRENT_DIR"
while :; do
  src_check_entry "$src_path"
  [[ -n "$src_reason" ]] && src_unsafe "$src_path"
  [[ "$src_path" == "/" ]] && break
  src_path="$(dirname "$src_path")"
done
src_items=()
for src_item in clp.sh install.sh README*.md LICENSE lib templates locales; do
  [[ -e "${CURRENT_DIR}/${src_item}" || -L "${CURRENT_DIR}/${src_item}" ]] && src_items+=("${CURRENT_DIR}/${src_item}")
done
while IFS= read -r -d '' src_path; do
  src_check_entry "$src_path"
  [[ -n "$src_reason" ]] && src_unsafe "$src_path"
done < <(find "${src_items[@]}" -print0)

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
# 8.1 Settings Files Pre-check (/etc/clp; nothing is written)
#     A file that needs a decision cannot be asked about without a terminal: stop here,
#     before any program file is replaced, unless -y was given.
# ------------------------------------------------------------------------------
conf_args=()
[[ "$auto_yes" -eq 1 ]] && conf_args+=("-y")
if ! CLP_ROOT_DIR="$CURRENT_DIR" bash "${CURRENT_DIR}/lib/conf_install.sh" check "${conf_args[@]}"; then
  exit 1
fi

# ------------------------------------------------------------------------------
# 9. Create Target Directories
# ------------------------------------------------------------------------------
TARGET_PARENT="${TARGET_DIR%/*}"
mkdir -p "$TARGET_PARENT"
# log 只有 root 可讀（clp 本身也會把目錄設為 750、檔案設為 600）
mkdir -p /var/log/clp
chmod 750 /var/log/clp 2>/dev/null || true

# set_install_perms <dir>：root:root，目錄 755、檔案 644，clp.sh 與 install.sh 755
set_install_perms() {
  chown -R root:root "$1"
  find "$1" -type d -exec chmod 755 {} +
  find "$1" -type f -exec chmod 644 {} +
  chmod 755 "${1}/clp.sh"
  chmod 755 "${1}/install.sh"
}

# ------------------------------------------------------------------------------
# 10. Copy Application Files, 11. Configure Ownership and Permissions
#     The new version is prepared in a directory next to TARGET_DIR (same file system) and then
#     renamed into place, so a running clp never reads a half-written file and files removed in
#     the new version do not linger. Between the two renames TARGET_DIR is briefly missing.
# ------------------------------------------------------------------------------
stage_dir=""
old_parent=""
install_cleanup() {
  # 換上新版之前中斷：放回舊版
  if [[ -n "$old_parent" && -d "${old_parent}/clp-helper" && ! -e "$TARGET_DIR" ]]; then
    mv "${old_parent}/clp-helper" "$TARGET_DIR" 2>/dev/null || true
  fi
  if [[ -n "$stage_dir" ]]; then rm -rf "$stage_dir"; fi
  if [[ -n "$old_parent" && ! -e "${old_parent}/clp-helper" ]]; then rm -rf "$old_parent"; fi
}

if [[ "${CURRENT_DIR}" != "${TARGET_DIR}" ]]; then
  # 先前中斷的安裝留下的暫存目錄
  rm -rf "${TARGET_PARENT}"/.clp-helper.new.* 2>/dev/null || true
  for d in "${TARGET_PARENT}"/.clp-helper.old.*; do
    if [[ -d "$d" && ! -e "${d}/clp-helper" ]]; then rm -rf "$d"; fi
  done

  trap install_cleanup EXIT
  stage_dir="$(mktemp -d "${TARGET_PARENT}/.clp-helper.new.XXXXXX")"
  printf "${MSG_COPYING}" "${TARGET_DIR}"
  cp -rf "${CURRENT_DIR}/clp.sh" "$stage_dir/"
  cp -rf "${CURRENT_DIR}/install.sh" "$stage_dir/"
  cp -rf "${CURRENT_DIR}/README"*.md "$stage_dir/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/LICENSE" "$stage_dir/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/lib" "$stage_dir/"
  cp -rf "${CURRENT_DIR}/templates" "$stage_dir/" 2>/dev/null || true
  cp -rf "${CURRENT_DIR}/locales" "$stage_dir/" 2>/dev/null || true
  printf "${MSG_PERMS}"
  set_install_perms "$stage_dir"

  if [[ -e "$TARGET_DIR" || -L "$TARGET_DIR" ]]; then
    old_parent="$(mktemp -d "${TARGET_PARENT}/.clp-helper.old.XXXXXX")"
    mv "$TARGET_DIR" "${old_parent}/clp-helper"
  fi
  mv "$stage_dir" "$TARGET_DIR"
  trap - EXIT
  stage_dir=""
  if [[ -n "$old_parent" ]]; then rm -rf "$old_parent"; fi
  old_parent=""
else
  rm -rf "${TARGET_DIR}/logs" 2>/dev/null || true
  printf "${MSG_PERMS}"
  set_install_perms "$TARGET_DIR"
fi

# ------------------------------------------------------------------------------
# 12. Create Global Symlink
# ------------------------------------------------------------------------------
printf "${MSG_SYMLINK}"
mkdir -p /usr/local/bin
ln -sf "${TARGET_DIR}/clp.sh" /usr/local/bin/clp
hash -r 2>/dev/null || true

# 每天記錄 CloudPanel 的官方 vhost 範本版本（clp site -vhost=status 判斷舊版官方範本用；CloudPanel 06:15 更新範本）
if [[ -d /etc/cron.d ]]; then
  cron_tmp="$(mktemp /etc/cron.d/.clp-helper.XXXXXX)" && {
    printf '%s\n' "# Managed by CLP Helper: record CloudPanel's official vhost templates (clp site -vhost=status)" \
      "30 7 * * * root /usr/local/bin/clp site -vhost=record >/dev/null 2>&1" > "$cron_tmp"
    chmod 644 "$cron_tmp"
    mv -f "$cron_tmp" /etc/cron.d/clp-helper
  } || rm -f "${cron_tmp:-}"
fi

# ------------------------------------------------------------------------------
# 12.1 Migrate Legacy Installation Directory (/home/clp/clp -> /usr/local/lib/clp-helper)
# ------------------------------------------------------------------------------
if [[ -d "$LEGACY_TARGET_DIR" && "$LEGACY_TARGET_DIR" != "$TARGET_DIR" ]]; then
  printf "${C_YELLOW}${MSG_MIGRATE_LEGACY}${C_NC}" "$LEGACY_TARGET_DIR" "$TARGET_DIR"
  rm -rf "$LEGACY_TARGET_DIR"
  printf "${C_GREEN}${MSG_MIGRATE_LEGACY_DONE}${C_NC}" "$LEGACY_TARGET_DIR"
fi

# ------------------------------------------------------------------------------
# 12.2 Settings Files (/etc/clp/clp.conf, cf-rules.conf; migrate files from older versions)
#      The user's files (*.local) are never overwritten. See lib/conf_install.sh.
# ------------------------------------------------------------------------------
if ! CLP_ROOT_DIR="$TARGET_DIR" bash "${TARGET_DIR}/lib/conf_install.sh" apply "${conf_args[@]}"; then
  echo -e "${C_RED}${MSG_CONF_FAILED}${C_NC}" >&2
  exit 1
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
