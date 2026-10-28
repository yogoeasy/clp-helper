#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# Module: backup & restore (Multi-type Backup & Multi-remote Restore via rclone)
# ==============================================================================

# Ensure core functions are loaded
if ! command -v log_info >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/core.sh" ]]; then
    source "${SCRIPT_DIR}/core.sh"
  fi
fi

# Ensure php_fpm module is available for pool tuning on restore
if [[ -f "${CLP_ROOT_DIR:-}/lib/php_fpm.sh" ]]; then
  source "${CLP_ROOT_DIR}/lib/php_fpm.sh"
fi

# 備份預設值（BACKUP_DIR / BACKUP_REMOTE_DIR / BACKUP_TYPE / BACKUP_TO）由 config.sh 讀取
if ! command -v config_get_valid >/dev/null 2>&1 && [[ -f "${CLP_ROOT_DIR:-}/lib/config.sh" ]]; then
  source "${CLP_ROOT_DIR}/lib/config.sh"
fi

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
backup_format_size() {
  local bytes="$1"
  if [[ -z "$bytes" || "$bytes" -le 0 ]] 2>/dev/null; then
    echo "0 B"
    return 0
  fi

  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
  else
    awk -v b="$bytes" 'BEGIN {
      if (b >= 1073741824) printf "%.2f GiB\n", b/1073741824;
      else if (b >= 1048576) printf "%.2f MiB\n", b/1048576;
      else if (b >= 1024) printf "%.2f KiB\n", b/1024;
      else printf "%d B\n", b;
    }'
  fi
}

# 所有備份類型、還原前快照、restore／rollback 的 rsync --delete 共用的排除清單（相對於網站根目錄，可用萬用字元）。
# 快取與其他備份外掛的本機備份目錄：不備份，還原時也不會被刪除。
CLP_BACKUP_EXCLUDES=(
  "wp-content/cache"
  "wp-content/updraft"                      # UpdraftPlus
  "wp-content/wpvividbackups"               # WPvivid
  "wp-content/ai1wm-backups"                # All-in-One WP Migration
  "wp-content/backups-dup-lite"             # Duplicator
  "wp-content/backups-dup-pro"              # Duplicator Pro
  "wp-snapshots"                            # Duplicator（舊版）
  "wp-content/backup-migration*"            # Backup Migration (BackupBliss)
  "wp-content/backupwordpress-*-backups"    # BackUpWordPress
  "wp-content/uploads/backwpup-*"           # BackWPup（backups／logs／temp）
  "wp-content/uploads/backupbuddy_backups"  # Solid Backups (BackupBuddy)
  "wp-content/uploads/backupbuddy_temp"     # Solid Backups (BackupBuddy)
  "wp-content/uploads/wp-staging/backups"   # WP Staging
)

# backup_tar_exclude_args <top_dir_name>
#   設定 BACKUP_TAR_EXCLUDES 陣列：以 tar -C <網站上層目錄> <top_dir_name> 打包時使用的 --exclude 參數。
backup_tar_exclude_args() {
  local top="$1" p
  BACKUP_TAR_EXCLUDES=()
  for p in "${CLP_BACKUP_EXCLUDES[@]}"; do
    BACKUP_TAR_EXCLUDES+=(--exclude="${top}/${p}")
  done
}

# backup_rsync_exclude_args
#   設定 BACKUP_RSYNC_EXCLUDES 陣列：以網站根目錄為傳輸根目錄的 rsync 排除規則（錨定在根目錄）。
backup_rsync_exclude_args() {
  local p
  BACKUP_RSYNC_EXCLUDES=()
  for p in "${CLP_BACKUP_EXCLUDES[@]}"; do
    BACKUP_RSYNC_EXCLUDES+=(--exclude="/${p}")
  done
}

# backup_path_is_excluded <相對於網站根目錄的路徑>
#   路徑符合 CLP_BACKUP_EXCLUDES 任一規則時回傳 0。
backup_path_is_excluded() {
  local rel="$1" p
  for p in "${CLP_BACKUP_EXCLUDES[@]}"; do
    # shellcheck disable=SC2053
    [[ "$rel" == $p ]] && return 0
  done
  return 1
}

# backup_file_type <filename> <domain>
#   依檔名判斷備份類型：db | full | compact | archive | unknown
backup_file_type() {
  local fname="$1" domain="$2"
  local rest="${fname#"${domain}"-}"
  case "$rest" in
    db-*|backup-*) echo "db" ;;
    full-*) echo "full" ;;
    compact-*) echo "compact" ;;
    archive-*) echo "archive" ;;
    *)
      if [[ "$fname" == *.sql || "$fname" == *.sql.gz ]]; then
        echo "db"
      else
        echo "unknown"
      fi
      ;;
  esac
}

# backup_file_year <filename>
#   從備份檔名的時間戳記（YYYYMMDD_HHMMSS）取得備份當年的年份；取不到時輸出空字串。
backup_file_year() {
  local fname="$1"
  if [[ "$fname" =~ -((19|20)[0-9]{2})[0-9]{4}_[0-9]{6}\. ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

backup_validate_remote() {
  local remote="$1"
  remote="${remote%:}" # strip trailing colon if typed

  if ! command -v rclone >/dev/null 2>&1; then
    log_warn "$(_t "BACKUP_VALIDATE_REMOTE_1")"
    check_rclone || return 1
  fi

  local remotes
  remotes=$(rclone listremotes 2>/dev/null || true)
  if [[ -z "$remotes" ]]; then
    log_error "$(_t "BACKUP_VALIDATE_REMOTE_2")"
    return 1
  fi

  if ! echo "$remotes" | grep -Fxq "${remote}:"; then
    log_error "$(_t "BACKUP_VALIDATE_REMOTE_3" "${remote}")"
    echo -e "$(_t "BACKUP_VALIDATE_REMOTE_4")"
    echo "$remotes" | while read -r r; do
      echo -e "  - ${C_CYAN}${r%:}${C_NC}"
    done
    return 1
  fi

  return 0
}

# 輸出以 \x1f (Unit Separator) 分隔的 "name\x1fuser\x1fpass\x1fhost"。
# 使用 Python 解析 define()，支援單引號／雙引號與跳脫字元，密碼中含 | 或 ' 也不會錯位。
# 讀取方式: IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"
backup_get_site_db_credentials() {
  local siteroot="$1"
  local wpconfig="${siteroot}/wp-config.php"

  if [[ ! -f "$wpconfig" ]]; then
    printf '\x1f\x1f\x1f127.0.0.1\n'
    return 0
  fi

  # 以 clp_fileops 讀取（不跟隨 symlink）；讀不到時與沒有 wp-config.php 相同（欄位留空）
  if [[ -L "$wpconfig" ]]; then
    log_warn "$(_t "BACKUP_WARN_WPCONFIG_SYMLINK" "$wpconfig")" >&2
  fi
  CLP_LIB_DIR="${CLP_LIB_DIR}" python3 -I - "$wpconfig" << 'PYEOF'
import os, re, sys
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/lib/clp-helper/lib"))
import clp_fileops
try:
    raw = clp_fileops.read_text_nofollow(sys.argv[1])
except Exception:
    raw = ""

def strip_php_comments(s):
    # 移除字串外的 //、#、/* */ 註解，被註解掉的 define() 不採用；字串內的 // 與 # 保留
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in "\x27\"":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            out.append(s[i:j + 1])
            i = j + 1
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        elif c == "#" or s.startswith("//", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out)

src = strip_php_comments(raw)
def decode_php_str(val, quote_char):
    if quote_char == "\x27":
        return re.sub(r"\\([\\'\x27])", r"\1", val)
    def replace_double(m):
        esc = m.group(1)
        if esc == "n": return "\n"
        elif esc == "r": return "\r"
        elif esc == "t": return "\t"
        elif esc == "v": return "\v"
        elif esc == "e": return "\x1b"
        elif esc == "f": return "\f"
        elif esc == "\\": return "\\"
        elif esc == "$": return "$"
        elif esc == "\"": return "\""
        elif esc.startswith("x"):
            try: return chr(int(esc[1:], 16))
            except: return m.group(0)
        elif esc[0].isdigit():
            try: return chr(int(esc, 8))
            except: return m.group(0)
        return esc
    return re.sub(r"\\([nrtvef\\$\"]|x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)", replace_double, val)

def get(key):
    m = re.search(r"""define\s*\(\s*([\x27"])%s\1\s*,\s*([\x27"])((?:\\.|(?!\2).)*)\2""" % key, src)
    return decode_php_str(m.group(3), m.group(2)) if m else ""
host = get("DB_HOST") or "127.0.0.1"
print("\x1f".join([get("DB_NAME"), get("DB_USER"), get("DB_PASSWORD"), host]))
PYEOF
}

# ==============================================================================
# build_mysql_conn_args <db_host>
#   根據 DB_HOST 解析並建立 MySQL / mysqldump 連線參數（-h, -P, 或 -S）。
#   輸出結果至 stdout（每參數一行），同時設定陣列 MYSQL_CONN_ARGS。
#   支援範圍：
#   - 標準主機名稱 / IPv4（如 localhost, 127.0.0.1, db.example.com）-> -h<host>
#   - 主機含埠號（如 127.0.0.1:3307, db.example.com:3306）-> -h<host> -P<port>
#   - IPv6 格式（如 [::1]:3306 -> -h::1 -P3306；[::1] -> -h::1）
#   - UNIX Domain Socket 路徑（以 "/" 開頭，如 /var/run/mysqld/mysqld.sock）-> -S<socket>
# ==============================================================================
build_mysql_conn_args() {
  local raw_host="${1:-localhost}"
  local host="$raw_host"
  local port=""
  local socket=""
  MYSQL_CONN_ARGS=()

  # UNIX domain socket（以 "/" 開頭，或 WordPress 的 host:/path/to.sock 寫法）
  if [[ "$raw_host" == /* || "$raw_host" =~ ^[^/]*:/ ]]; then
    socket="${raw_host#*:}"
    [[ "$raw_host" == /* ]] && socket="$raw_host"
    MYSQL_CONN_ARGS=("-S${socket}")
    printf '%s\n' "-S${socket}"
    return 0
  fi

  # IPv6 格式: [::1]:3306 或 [::1]
  if [[ "$raw_host" =~ ^\[([a-fA-F0-9:]+)\](:([0-9]+))?$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-}"
  # host:port 格式
  elif [[ "$raw_host" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  fi

  MYSQL_CONN_ARGS=("-h${host}")
  printf '%s\n' "-h${host}"
  if [[ -n "$port" ]]; then
    MYSQL_CONN_ARGS+=("-P${port}")
    printf '%s\n' "-P${port}"
  fi
}

# ------------------------------------------------------------------------------
# 資料庫連線（網站帳號／MySQL root）
#   wp-config.php 由網站使用者控制：DB_HOST 可能指向網站使用者自己的 socket 或主機，
#   DB_NAME 以 - 開頭時會被 mysql／mysqldump 當成選項。所以：
#   - 一律拒絕以 - 開頭的資料庫名稱；
#   - 預設只用網站自己的權限（WP-CLI 或 wp-config 帳密）；MySQL root 只有加上 -db-root 才會使用，
#     而且連 CloudPanel 的 MySQL master（clpctl 提供的主機與埠號，不使用 DB_HOST），名稱限英數字開頭、其後為英數字／底線／-。
# ------------------------------------------------------------------------------
# backup_db_root_allowed：使用者是否以 -db-root 允許改用 MySQL root
backup_db_root_allowed() {
  has_opt "db-root" || has_opt "db_root"
}

# backup_db_conn <db_creds> <site|root>
#   設定 BACKUP_DB_ARGS（連線與帳號參數）、BACKUP_DB_PASS、BACKUP_DB_NAME；名稱不安全或缺少資料時回傳 1
backup_db_conn() {
  local db_creds="$1" who="$2"
  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"
  BACKUP_DB_ARGS=()
  BACKUP_DB_PASS=""
  BACKUP_DB_NAME="$db_name"
  [[ -n "$db_name" && "$db_name" != -* ]] || return 1
  if [[ "$who" == "root" ]]; then
    [[ "$db_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
    local master_host master_port
    read -r master_host master_port <<< "$(get_mysql_master_host_port)"
    [[ "$master_host" =~ ^[A-Za-z0-9.:_-]+$ && "$master_port" =~ ^[0-9]+$ ]] || return 1
    BACKUP_DB_ARGS=(--no-defaults "-h${master_host}" "-P${master_port}" -uroot)
    BACKUP_DB_PASS="$(get_mysql_master_pass)"
    [[ -n "$BACKUP_DB_PASS" ]] || return 1
  else
    [[ -n "$db_user" ]] || return 1
    build_mysql_conn_args "$db_host" >/dev/null
    # --no-defaults：不讀 /root/.my.cnf，避免其中的密碼（優先於 MYSQL_PWD）被送到 DB_HOST 指定的目標
    BACKUP_DB_ARGS=(--no-defaults "${MYSQL_CONN_ARGS[@]}" "-u${db_user}")
    BACKUP_DB_PASS="$db_pass"
  fi
}

# backup_db_hint <db_creds>：網站帳號無法存取資料庫時的說明（寫到 stderr，可在 $(...) 中呼叫）
backup_db_hint() {
  local db_name="${1%%$'\x1f'*}"
  if [[ "$db_name" == -* ]]; then
    log_error >&2 "$(_t "BACKUP_DB_ERR_NAME_UNSAFE" "$db_name")"
  elif backup_db_root_allowed; then
    log_error >&2 "$(_t "BACKUP_DB_ERR_ROOT_FAILED" "$db_name")"
  else
    log_warn >&2 "$(_t "BACKUP_DB_HINT_ROOT")"
  fi
}

# backup_db_check <db_creds> [siteroot] [siteuser]：還原前確認資料庫可以存取
#   （WP-CLI → 網站帳號 → -db-root 時再試 root）；不顯示說明，由呼叫端決定是錯誤或警告
backup_db_check() {
  local db_creds="$1" siteroot="${2:-}" siteuser="${3:-}" who
  if [[ -n "$siteroot" ]] && backup_wp_ready "$siteroot" "$siteuser" && \
     sudo -H -u "$siteuser" wp db query "SELECT 1" --path="$siteroot" >/dev/null 2>&1; then
    return 0
  fi
  for who in site root; do
    [[ "$who" == "root" ]] && ! backup_db_root_allowed && break
    if backup_db_conn "$db_creds" "$who" && \
       MYSQL_PWD="$BACKUP_DB_PASS" mysql "${BACKUP_DB_ARGS[@]}" -N -B -e "SELECT 1" "$BACKUP_DB_NAME" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# backup_tar_create <tar 參數...>：封裝含 DB dump 與 wp-config，先 umask 077 再建立（不先寫再 chmod）
backup_tar_create() {
  ( umask 077; tar "$@" )
}

# backup_db_dump <db_creds> <outfile> <gzip:0|1> [mysqldump 選項...]
#   以 mysqldump 匯出（網站帳號，-db-root 時再試 root）；gzip=1 時邊匯出邊壓縮，不需要額外空間
backup_db_dump() {
  local db_creds="$1" outfile="$2" gz="$3" who
  shift 3
  ( umask 077; : > "$outfile" ) || return 1
  for who in site root; do
    [[ "$who" == "root" ]] && ! backup_db_root_allowed && break
    backup_db_conn "$db_creds" "$who" || continue
    if [[ "$gz" -eq 1 ]]; then
      if MYSQL_PWD="$BACKUP_DB_PASS" mysqldump "${BACKUP_DB_ARGS[@]}" "$@" "$BACKUP_DB_NAME" 2>/dev/null | gzip -c > "$outfile"; then
        return 0
      fi
    elif MYSQL_PWD="$BACKUP_DB_PASS" mysqldump "${BACKUP_DB_ARGS[@]}" "$@" "$BACKUP_DB_NAME" > "$outfile" 2>/dev/null && [[ -s "$outfile" ]]; then
      return 0
    fi
  done
  return 1
}

# backup_db_load <db_creds> <sql_file>：以 mysql 匯入 .sql／.sql.gz（網站帳號，-db-root 時再試 root）
backup_db_load() {
  local db_creds="$1" sql_file="$2" who
  local reader=(cat "$sql_file")
  [[ "$sql_file" == *.gz ]] && reader=(gunzip -c "$sql_file")
  mysql_no_cmds_opt
  for who in site root; do
    [[ "$who" == "root" ]] && ! backup_db_root_allowed && break
    local err_out=/dev/null
    [[ "$who" == "root" ]] && err_out=/dev/stderr
    if backup_db_conn "$db_creds" "$who" && \
       "${reader[@]}" | MYSQL_PWD="$BACKUP_DB_PASS" mysql "${BACKUP_DB_ARGS[@]}" "$CLP_MYSQL_NO_CMDS_OPT" "$BACKUP_DB_NAME" 2>"$err_out"; then
      return 0
    fi
  done
  return 1
}

# backup_db_drop_all_tables <db_creds>：刪除資料庫中的所有資料表（rollback 用；網站帳號，-db-root 時再試 root）
backup_db_drop_all_tables() {
  local db_creds="$1" who tables sql
  for who in site root; do
    [[ "$who" == "root" ]] && ! backup_db_root_allowed && break
    backup_db_conn "$db_creds" "$who" || continue
    tables=$(MYSQL_PWD="$BACKUP_DB_PASS" mysql "${BACKUP_DB_ARGS[@]}" -N -B -e "SHOW TABLES" "$BACKUP_DB_NAME" 2>/dev/null) || continue
    [[ -z "$tables" ]] && return 0
    sql="SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS $(awk '{ gsub(/`/, "``"); printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }' <<< "$tables");"
    # 由 stdin 傳入（資料表很多時 -e 參數可能超過長度上限）；資料表名稱由網站決定，同樣停用用戶端指令
    mysql_no_cmds_opt
    printf '%s\n' "$sql" | MYSQL_PWD="$BACKUP_DB_PASS" mysql "${BACKUP_DB_ARGS[@]}" "$CLP_MYSQL_NO_CMDS_OPT" "$BACKUP_DB_NAME" 2>/dev/null && return 0
  done
  return 1
}

# backup_wp_ready <siteroot> <siteuser>：可以用網站使用者身分執行 WP-CLI
backup_wp_ready() {
  [[ -n "$2" ]] && command -v wp >/dev/null 2>&1 && \
    sudo -H -u "$2" wp core is-installed --path="$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# backup_export_site_db <siteroot> <siteuser> <outfile>
#   匯出網站資料庫至 <outfile>（由 root 寫入，網站使用者不需要對目標目錄有寫入權）
#   依序嘗試：WP-CLI (stdout) → 網站 DB 帳號 mysqldump →（-db-root）MySQL root mysqldump
#   成功回傳 0；全部失敗回傳 1 並移除不完整的檔案
# ------------------------------------------------------------------------------
backup_export_site_db() {
  local siteroot="$1"
  local siteuser="$2"
  local outfile="$3"

  ( umask 077; : > "$outfile" )

  if backup_wp_ready "$siteroot" "$siteuser"; then
    if sudo -H -u "$siteuser" wp db export - --add-drop-table --skip-plugins --skip-themes --path="$siteroot" > "$outfile" 2>/dev/null && [[ -s "$outfile" ]]; then
      return 0
    fi
    log_warn "$(_t "BACKUP_EXPORT_SITE_DB_1")"
  fi

  local db_creds
  db_creds=$(backup_get_site_db_credentials "$siteroot")
  if [[ -z "${db_creds%%$'\x1f'*}" ]]; then
    rm -f "$outfile"
    return 1
  fi

  if backup_db_dump "$db_creds" "$outfile" 0; then
    return 0
  fi

  backup_db_hint "$db_creds"
  rm -f "$outfile"
  return 1
}

# ------------------------------------------------------------------------------
# restore_import_sql <sql_file> <db_creds_str> [siteroot] [siteuser]
#   將 .sql 或 .sql.gz 匯入網站資料庫：WP-CLI（網站使用者）→ 網站 DB 帳號 →（-db-root）MySQL root。
#   以 if 判斷結果，失敗時回傳 1（不會在 set -e 下中途結束，呼叫端可執行 rollback）。
# ------------------------------------------------------------------------------
restore_import_sql() {
  local sql_file="$1"
  local db_creds="$2"
  local siteroot="${3:-}" siteuser="${4:-}"
  [[ -z "${db_creds%%$'\x1f'*}" ]] && return 1

  if [[ -n "$siteroot" ]] && backup_wp_ready "$siteroot" "$siteuser"; then
    local reader=(cat "$sql_file")
    [[ "$sql_file" == *.gz ]] && reader=(gunzip -c "$sql_file")
    if "${reader[@]}" | sudo -H -u "$siteuser" wp db import - --path="$siteroot" >/dev/null 2>&1; then
      return 0
    fi
    log_warn "$(_t "BACKUP_IMPORT_SQL_WP_FAILED")"
  fi

  if backup_db_load "$db_creds" "$sql_file"; then
    return 0
  fi
  backup_db_hint "$db_creds"
  return 1
}

# ------------------------------------------------------------------------------
# Restore Rollback Helpers
#   restore_take_snapshot <domain> <siteroot> <db_creds_str>
#     → 建立快照至 <backup-dir>/rollback/<domain>-<ts>/
#     → 回傳快照目錄路徑（供後續 rollback 使用）
#   restore_rollback <domain> <siteroot> <siteuser> <snapshot_dir>
#     → 從快照目錄還原 DB 與檔案
# ------------------------------------------------------------------------------
# backup_rollback_base：還原前快照的上層目錄（clp config 的 backup-dir 底下的 rollback/）；設定不合法時回傳 1
backup_rollback_base() {
  local b
  b="$(config_get_valid BACKUP_DIR)" || return 1
  printf '%s\n' "${b%/}/rollback"
}

restore_take_snapshot() {
  local domain="$1"
  local siteroot="$2"
  local db_creds="$3"   # backup_get_site_db_credentials 的輸出（\x1f 分隔）
  local mode="${4:-full}" # full：建立 DB 與檔案快照；files：只建立檔案快照（資料庫無法存取、且本次還原不涉及資料庫）；none：只建立目錄（-no-snapshot，供保存 db_creds 與備份中的 wp-config）
  local siteuser="${5:-}"

  local db_name="${db_creds%%$'\x1f'*}"

  local rollback_base
  rollback_base="$(backup_rollback_base)" || return 1
  # 自動相容：歷史版本在 /root/clpBackup 產生的隱藏目錄 .rollback，改名為 rollback
  if [[ -d "/root/clpBackup/.rollback" && ! -d "/root/clpBackup/rollback" ]]; then
    mv "/root/clpBackup/.rollback" "/root/clpBackup/rollback" 2>/dev/null || true
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local snap_dir="${rollback_base}/${domain}-${timestamp}"
  [[ "$mode" == "none" ]] && snap_dir="${snap_dir}-nosnap"
  (umask 077; mkdir -p "$snap_dir") || return 1
  chmod 700 "$(dirname "$rollback_base")" "$rollback_base" "$snap_dir" 2>/dev/null || true

  # 保存快照當下的 DB 憑證；還原失敗時 wp-config.php 可能已被覆寫，rollback 須沿用原憑證
  ( umask 077; printf '%s\n' "$db_creds" > "${snap_dir}/db_creds" ) || { rm -rf "$snap_dir"; return 1; }

  if [[ "$mode" == "none" ]]; then
    echo "$snap_dir"
    return 0
  fi

  log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_1" "${snap_dir}")"

  # 1. DB 快照
  # 依序：WP-CLI（網站使用者）→ 快照當下的網站帳密 mysqldump →（-db-root）MySQL root；邊匯出邊壓縮
  if [[ -n "$db_name" && "$mode" == "full" ]]; then
    local snap_sql="${snap_dir}/db.sql.gz" snap_ok=0
    ( umask 077; : > "$snap_sql" )
    if backup_wp_ready "$siteroot" "$siteuser" && \
       sudo -H -u "$siteuser" wp db export - --add-drop-table --skip-plugins --skip-themes --path="$siteroot" 2>/dev/null | gzip -c > "$snap_sql"; then
      snap_ok=1
    elif backup_db_dump "$db_creds" "$snap_sql" 1 --add-drop-table; then
      snap_ok=1
    fi
    if [[ "$snap_ok" -eq 1 ]]; then
      log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_2" "${snap_sql}")"
    else
      backup_db_hint "$db_creds"
      log_warn >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_3")"
      rm -rf "$snap_dir"
      return 1
    fi
  fi

  # 2. 網站檔案快照（排除 CLP_BACKUP_EXCLUDES；tar 結束代碼 1 只表示有檔案在打包時變動，可接受）
  local snap_files="${snap_dir}/files.tar.gz"
  if [[ -d "$siteroot" ]]; then
    backup_tar_exclude_args "$(basename "$siteroot")"
    local tar_rc=0
    backup_tar_create --warning=no-file-changed -czf "$snap_files" \
      "${BACKUP_TAR_EXCLUDES[@]}" \
      -C "$(dirname "$siteroot")" "$(basename "$siteroot")" 2>/dev/null || tar_rc=$?
    if [[ "$tar_rc" -le 1 ]]; then
      log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_4" "${snap_files}")"
    else
      log_warn >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_5")"
      rm -rf "$snap_dir"
      return 1
    fi
  fi

  chmod 600 "${snap_dir}"/* 2>/dev/null || true
  echo "$snap_dir"
}

# restore_snapshot_space_check <siteroot> <db_creds>
#   估算快照需要的空間（網站目錄扣除 CLP_BACKUP_EXCLUDES，加上資料庫大小，再加 10% 餘裕），
#   與 backup-dir 所在磁碟的剩餘空間比較。設定 SNAP_NEED_BYTES、SNAP_AVAIL_BYTES；空間不足時回傳 1。
restore_snapshot_space_check() {
  local siteroot="$1" db_creds="$2"
  local need=0 p m sz
  if [[ -d "$siteroot" ]]; then
    # du 遇到消失的檔案會回傳 1，但仍輸出總計；只取第一行，避免「數字＋0」兩行造成算術錯誤
    need=$(du -sb "$siteroot" 2>/dev/null | head -n1 | cut -f1 || true)
    [[ "$need" =~ ^[0-9]+$ ]] || need=0
    for p in "${CLP_BACKUP_EXCLUDES[@]}"; do
      # shellcheck disable=SC2206
      for m in "$siteroot"/$p; do
        [[ -e "$m" ]] || continue
        sz=$(du -sb "$m" 2>/dev/null | head -n1 | cut -f1 || true)
        [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
        need=$((need - ${sz:-0}))
      done
    done
  fi
  if backup_db_conn "$db_creds" site; then
    local db_bytes
    db_bytes=$(MYSQL_PWD="$BACKUP_DB_PASS" mysql "${BACKUP_DB_ARGS[@]}" -N -B -e \
      "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()" \
      "$BACKUP_DB_NAME" 2>/dev/null || echo 0)
    [[ "$db_bytes" =~ ^[0-9]+$ ]] || db_bytes=0
    need=$((need + db_bytes))
  fi
  [[ "$need" -lt 0 ]] && need=0
  need=$((need + need / 10))
  local snap_base
  snap_base="$(backup_rollback_base)" || return 1
  snap_base="$(dirname "$snap_base")"
  (umask 077; mkdir -p "$snap_base") 2>/dev/null || true
  SNAP_NEED_BYTES="$need"
  SNAP_AVAIL_BYTES=$(df -P -B1 "$snap_base" 2>/dev/null | awk 'NR==2 {print $4}')
  [[ "$SNAP_AVAIL_BYTES" =~ ^[0-9]+$ ]] || return 0
  [[ "$SNAP_AVAIL_BYTES" -ge "$SNAP_NEED_BYTES" ]]
}

# restore_stage_for_user <siteuser> <dir> <open_dir...>
#   把 root 專屬暫存目錄中的解壓結果交給網站使用者，之後以網站使用者身分 rsync 回網站：
#   網站目錄由網站使用者控制（可換成 symlink），以 root 寫入會被導到網站以外的位置。
#   呼叫時 <dir> 的上層必須仍是 root 專屬（700），網站使用者還進不來，所以以下處理不會被搶先替換路徑：
#   移除一般檔案、目錄、symlink 以外的項目（裝置檔、FIFO、socket）；補上擁有者的 rwX（略過 symlink，
#   避免封裝中的權限讓網站使用者無法讀取）；由下而上逐一 chown -h（不跟隨 symlink）。
#   全部完成後才把 <open_dir...>（上層暫存目錄）改為 711，讓網站使用者進入。
restore_stage_for_user() {
  local siteuser="$1" dir="$2"
  shift 2
  [[ -n "$siteuser" && -d "$dir" && ! -L "$dir" ]] || return 1
  find "$dir" ! -type f ! -type d ! -type l -delete || return 1
  find "$dir" ! -type l -exec chmod u+rwX {} + || return 1
  find "$dir" -depth -exec chown -h "${siteuser}:${siteuser}" {} + || return 1
  chmod 711 "$@" || return 1
}

# restore_foreign_owned <siteuser> <siteroot>：列出網站中不屬於網站使用者的項目（最多 10 筆，不跟隨 symlink）
restore_foreign_owned() {
  find "$2" ! -user "$1" -print 2>/dev/null | head -n 10 || true
}

# restore_rsync_as_user <siteuser> <src_dir> <siteroot> [rsync 選項...]
#   以網站使用者身分同步（-rlpt：不保留擁有者、群組與裝置檔）；結束代碼 24（來源檔案在同步時消失）只警告，
#   其餘失敗（包括 23：部分檔案無法寫入，rsync 也會因此略過 --delete）回傳原結束代碼，由呼叫端 rollback
restore_rsync_as_user() {
  local siteuser="$1" src="$2" dst="$3" rc=0
  shift 3
  sudo -H -u "$siteuser" rsync -rlpt "$@" "${src}/" "${dst}/" || rc=$?
  if [[ "$rc" -eq 24 ]]; then
    log_warn "$(_t "BACKUP_RESTORE_WARN_VANISHED")"
    return 0
  fi
  return "$rc"
}

restore_rollback() {
  local domain="$1"
  local siteroot="$2"
  local siteuser="$3"
  local snap_dir="$4"

  if [[ -z "$snap_dir" || ! -d "$snap_dir" ]]; then
    log_error "$(_t "BACKUP_ROLLBACK_1" "${snap_dir}")"
    return 1
  fi
  if [[ ! -f "${snap_dir}/db.sql.gz" && ! -f "${snap_dir}/files.tar.gz" ]]; then
    # -no-snapshot 或快照失敗後選擇繼續：沒有可回復的內容
    log_error "$(_t "BACKUP_ROLLBACK_NO_SNAPSHOT" "${snap_dir}")"
    return 1
  fi

  log_step "$(_t "BACKUP_ROLLBACK_2" "${snap_dir}")"
  local rb_failed=0

  # 取得 DB 憑證（優先使用快照當下保存的憑證）
  local db_creds
  if [[ -s "${snap_dir}/db_creds" ]]; then
    db_creds=$(head -n 1 "${snap_dir}/db_creds")
  else
    db_creds=$(backup_get_site_db_credentials "$siteroot")
  fi
  # 1. 回復資料庫（先用快照當下的帳密：還原失敗時 wp-config.php 可能已不同；再試 WP-CLI）
  local snap_sql="${snap_dir}/db.sql.gz"
  if [[ -f "$snap_sql" && -n "${db_creds%%$'\x1f'*}" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_3")"
    # 快照只有 DROP TABLE IF EXISTS 快照當時的表；失敗的還原新增的資料表要先清掉，才是真正回到原狀
    # 先確認快照檔完整，才刪除資料表（否則載入失敗會留下空的資料庫）
    if ! gunzip -t "$snap_sql" 2>/dev/null; then
      log_error "$(_t "BACKUP_ROLLBACK_5")"
      rb_failed=1
    elif backup_db_drop_all_tables "$db_creds" && backup_db_load "$db_creds" "$snap_sql"; then
      log_success "$(_t "BACKUP_ROLLBACK_4")"
    elif backup_wp_ready "$siteroot" "$siteuser" && \
         sudo -H -u "$siteuser" wp db reset --yes --path="$siteroot" >/dev/null 2>&1 && \
         gunzip -c "$snap_sql" | sudo -H -u "$siteuser" wp db import - --path="$siteroot" >/dev/null 2>&1; then
      log_success "$(_t "BACKUP_ROLLBACK_4")"
    else
      backup_db_hint "$db_creds"
      log_error "$(_t "BACKUP_ROLLBACK_5")"
      rb_failed=1
    fi
  fi

  # 2. 回復網站檔案
  local snap_files="${snap_dir}/files.tar.gz"
  if [[ -f "$snap_files" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_6")"
    # 不可先刪除整個網站目錄：快照沒有包含 CLP_BACKUP_EXCLUDES（快取、其他備份外掛的本機備份），
    # 改為解壓到暫存目錄後以 rsync --delete 鏡像回去，並帶相同的排除清單保護這些目錄。
    #    寫入由網站使用者執行（見 restore_stage_for_user）。
    local rb_tmp="" rb_ok=0 rb_src
    rb_tmp=$(mktemp -d "/var/tmp/clpRollback.XXXXXX") || rb_tmp=""
    rb_src="${rb_tmp}/$(basename "$siteroot")"
    if [[ -z "$siteuser" ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_NO_SITE_USER" "$domain")"
    elif [[ -n "$rb_tmp" ]] && \
       tar --no-same-owner -xzf "$snap_files" -C "$rb_tmp" 2>/dev/null && \
       restore_stage_for_user "$siteuser" "$rb_src" "$rb_tmp"; then
      backup_rsync_exclude_args
      sudo -H -u "$siteuser" mkdir -p "$siteroot" 2>/dev/null || true
      if restore_rsync_as_user "$siteuser" "$rb_src" "$siteroot" --delete "${BACKUP_RSYNC_EXCLUDES[@]}"; then
        rb_ok=1
      fi
    fi
    [[ -n "$rb_tmp" ]] && rm -rf "$rb_tmp"
    if [[ "$rb_ok" -eq 1 ]]; then
      log_success "$(_t "BACKUP_ROLLBACK_7")"
    else
      log_error "$(_t "BACKUP_ROLLBACK_8")"
      rb_failed=1
    fi
  fi

  # 3. 清除快取 (wp cache flush)
  if command -v wp >/dev/null 2>&1 && [[ -f "${siteroot}/wp-config.php" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_9")"
    sudo -H -u "$siteuser" wp cache flush --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp cache flush --path="$siteroot" --skip-plugins 2>/dev/null || true
    sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" --skip-plugins 2>/dev/null || true
  fi

  if [[ "$rb_failed" -eq 1 ]]; then
    log_error "$(_t "BACKUP_ROLLBACK_INCOMPLETE" "${snap_dir}")"
    return 1
  fi
  log_success "$(_t "BACKUP_ROLLBACK_10" "${snap_dir}")"
  return 0
}

# restore_sync_wp_table_prefix <target_wpconfig> <backup_source> <siteuser>
#   比對本地 wp-config.php 與備份來源（wp-config.php 或 .sql/.sql.gz）之 $table_prefix。
#   若不同，使用 clp_fileops.py 安全原子更新本地 wp-config.php，並輸出提示。
restore_sync_wp_table_prefix() {
  local target_wpconfig="$1"
  local backup_source="$2"
  local siteuser="$3"

  [[ ! -f "$target_wpconfig" || ! -f "$backup_source" ]] && return 0

  local output rc=0
  output=$(python3 -I "${CLP_LIB_DIR}/clp_fileops.py" sync-wp-table-prefix "$target_wpconfig" "$backup_source" --user "$siteuser" 2>&1) || rc=$?

  case "$rc" in
    0)
      if [[ -n "$output" ]]; then
        log_info "$(_t "BACKUP_RESTORE_PREFIX_SYNCED" "$output")"
      fi
      ;;
    2)
      log_warn "$(_t "BACKUP_RESTORE_PREFIX_WARN_AMBIGUOUS" "$output")"
      ;;
    3)
      log_warn "$(_t "BACKUP_RESTORE_PREFIX_WARN_UNDETERMINED")"
      ;;
    4)
      log_warn "$(_t "BACKUP_RESTORE_PREFIX_WARN_INVALID" "$output")"
      ;;
    *)
      log_warn "$(_t "BACKUP_RESTORE_PREFIX_WARN_FAILED" "$output")"
      ;;
  esac
}

# ------------------------------------------------------------------------------
# 1. Backup Core Function
# ------------------------------------------------------------------------------
backup_site() {
  local domain="$1"
  local b_type="${2:-full}" # db | full | compact
  local b_to="${3:-local}"  # local | <remote_name>
  local b_path="${4:-}"     # custom local dir or remote path
  local b_expire="${5:-}"   # e.g. 7d, 30d

  domain=$(clean_domain "$domain")

  # 未指定 -path 時的預設位置（clp config: backup-dir / backup-remote-dir），缺值或不合法時在動工前就停止
  local cfg_local_dir="" cfg_remote_dir=""
  if [[ -z "$b_path" ]]; then
    if [[ "$b_to" == "local" ]]; then
      cfg_local_dir="$(config_get_valid BACKUP_DIR)" || return 1
    else
      cfg_remote_dir="$(config_get_valid BACKUP_REMOTE_DIR)" || return 1
    fi
  fi

  local siteroot
  siteroot=$(find_site_root "$domain" 2>/dev/null || true)
  local siteuser
  siteuser=$(find_site_user "$domain" 2>/dev/null || true)

  if [[ -z "$siteroot" || ! -d "$siteroot" ]]; then
    log_error "$(_t "BACKUP_SITE_1" "${domain}")"
    return 1
  fi

  # 清理歷史或異常中斷留下的臨時 SQL 傾印檔
  if [[ -f "${siteroot}/.clp_db_export.sql" ]]; then
    rm -f "${siteroot}/.clp_db_export.sql" 2>/dev/null || true
    log_warn "$(_t "BACKUP_SITE_WARN_CLEAN_LEGACY_SQL" "${domain}")"
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  # 年份取自同一個時間戳記（跨年那一秒分開呼叫 date 會不一致，還原時以檔名的年份為準）
  local current_year="${timestamp:0:4}"

  # Local working temp directory
  local tmp_work_dir
  # backup all 在 if 中呼叫 backup_site，set -e 在函式內不會生效：每個會失敗的步驟都要自行檢查
  if ! tmp_work_dir=$(mktemp -d "/var/tmp/clpBackup_${domain}_XXXXXX"); then
    log_error "$(_t "BACKUP_ERR_TMP_DIR")"
    return 1
  fi
  chmod 700 "$tmp_work_dir"

  log_step "$(_t "BACKUP_SITE_2" "${domain}" "${b_type}" "${b_to}")"

  local target_file=""

  # ----------------------------------------------------------------------------
  # Type A: Database Only (-type=db)
  # ----------------------------------------------------------------------------
  if [[ "$b_type" == "db" ]]; then
    local sql_file="${tmp_work_dir}/${domain}-db-${timestamp}.sql"
    local sql_gz="${sql_file}.gz"

    log_info "$(_t "BACKUP_SITE_3")"
    if ! backup_export_site_db "$siteroot" "$siteuser" "$sql_file"; then
      log_error "$(_t "BACKUP_SITE_4")"
      rm -rf "$tmp_work_dir"
      return 1
    fi

    if ! gzip -f "$sql_file"; then
      log_error "$(_t "BACKUP_ERR_COMPRESS" "$sql_file")"
      rm -rf "$tmp_work_dir"
      return 1
    fi
    target_file="$sql_gz"

  # ----------------------------------------------------------------------------
  # Type B: Full Site (-type=full)
  # ----------------------------------------------------------------------------
  elif [[ "$b_type" == "full" ]]; then
    # DB dump 寫在 root 專屬的工作目錄（不放在公開網站根目錄），打包時以封裝最上層的 backup.sql 加入
    # （與 <domain>/ 並排，不會和網站內的同名檔案衝突；舊版備份的 <domain>/.clp_db_export.sql 仍可還原）
    local db_stage_dir="${tmp_work_dir}/dbstage"
    mkdir -p "$db_stage_dir"
    local db_dump_file="${db_stage_dir}/backup.sql"
    local db_tar_args=()
    log_info "$(_t "BACKUP_SITE_5")"

    if backup_export_site_db "$siteroot" "$siteuser" "$db_dump_file"; then
      db_tar_args=(-C "$db_stage_dir" "backup.sql")
    elif [[ -f "${siteroot}/wp-config.php" ]]; then
      log_error "$(_t "BACKUP_SITE_6")"
      rm -rf "$tmp_work_dir"
      return 1
    else
      log_warn "$(_t "BACKUP_SITE_7")"
    fi

    local tar_file="${tmp_work_dir}/${domain}-full-${timestamp}.tar.gz"
    log_info "$(_t "BACKUP_SITE_8")"

    backup_tar_exclude_args "$domain"
    local tar_rc=0
    backup_tar_create --warning=no-file-changed \
      --ignore-failed-read \
      -czf "$tar_file" \
      -C "$(dirname "$siteroot")" \
      "${BACKUP_TAR_EXCLUDES[@]}" \
      "$domain" \
      ${db_tar_args[@]+"${db_tar_args[@]}"} || tar_rc=$?
    # 結束代碼 1 只表示打包期間有檔案變動（忙碌的網站常見），備份仍可用；2 以上才是失敗
    if [[ "$tar_rc" -eq 1 ]]; then
      log_warn "$(_t "BACKUP_WARN_FILES_CHANGED")"
    elif [[ "$tar_rc" -gt 1 ]]; then
        log_error "$(_t "BACKUP_SITE_9")"
        rm -rf "$tmp_work_dir"
        return 1
    fi

    rm -rf "$db_stage_dir"
    target_file="$tar_file"

  # ----------------------------------------------------------------------------
  # Type C: Compact Site (-type=compact)
  # ----------------------------------------------------------------------------
  elif [[ "$b_type" == "compact" ]]; then
    local tar_file="${tmp_work_dir}/${domain}-compact-${timestamp}.tar.gz"
    log_info "$(_t "BACKUP_SITE_10" "${current_year}")"

    backup_tar_exclude_args "$domain"
    local exclude_args=("${BACKUP_TAR_EXCLUDES[@]}")
    # shield、WPvivid_Uploads 由 archive 類型備份
    exclude_args+=(--exclude="${domain}/wp-content/shield")
    exclude_args+=(--exclude="${domain}/wp-content/WPvivid_Uploads")

    # Exclude all upload subdirectories except current year
    local uploads_dir="${siteroot}/wp-content/uploads"
    if [[ -d "$uploads_dir" ]]; then
      for item in "$uploads_dir"/*; do
        if [[ -e "$item" ]]; then
          local base
          base=$(basename "$item")
          if [[ "$base" != "$current_year" ]]; then
            exclude_args+=(--exclude="${domain}/wp-content/uploads/${base}")
          fi
        fi
      done
    fi

    local tar_rc=0
    backup_tar_create --warning=no-file-changed \
      --ignore-failed-read \
      -czf "$tar_file" \
      -C "$(dirname "$siteroot")" \
      "${exclude_args[@]}" \
      "$domain" || tar_rc=$?
    # 結束代碼 1 只表示打包期間有檔案變動，備份仍可用；2 以上才是失敗
    if [[ "$tar_rc" -eq 1 ]]; then
      log_warn "$(_t "BACKUP_WARN_FILES_CHANGED")"
    elif [[ "$tar_rc" -gt 1 ]]; then
      log_error "$(_t "BACKUP_SITE_11")"
      rm -rf "$tmp_work_dir"
      return 1
    fi

    target_file="$tar_file"

  # ----------------------------------------------------------------------------
  # Type D: Archive (-type=archive)
  #   與 compact 互補：uploads 中「今年」以外的全部項目（與 compact 用同一個 current_year 判斷），
  #   加上 compact 排除的 wp-content/shield、WPvivid_Uploads。compact + db + archive = full 的檔案範圍。
  # ----------------------------------------------------------------------------
  elif [[ "$b_type" == "archive" ]]; then
    local tar_file="${tmp_work_dir}/${domain}-archive-${timestamp}.tar.gz"
    log_info "$(_t "BACKUP_SITE_ARCHIVE_PACKING" "${current_year}")"

    local archive_members=()
    local uploads_dir="${siteroot}/wp-content/uploads"
    if [[ -d "$uploads_dir" ]]; then
      for item in "$uploads_dir"/*; do
        if [[ -e "$item" ]]; then
          local base
          base=$(basename "$item")
          if [[ "$base" != "$current_year" ]] && ! backup_path_is_excluded "wp-content/uploads/${base}"; then
            archive_members+=("${domain}/wp-content/uploads/${base}")
          fi
        fi
      done
    fi
    local extra_dir
    for extra_dir in shield WPvivid_Uploads; do
      if [[ -e "${siteroot}/wp-content/${extra_dir}" ]]; then
        archive_members+=("${domain}/wp-content/${extra_dir}")
      fi
    done

    if [[ ${#archive_members[@]} -eq 0 ]]; then
      log_warn "$(_t "BACKUP_SITE_ARCHIVE_EMPTY" "${domain}" "${current_year}")"
      rm -rf "$tmp_work_dir"
      return 0
    fi

    backup_tar_exclude_args "$domain"
    local tar_rc=0
    backup_tar_create --warning=no-file-changed \
      --ignore-failed-read \
      -czf "$tar_file" \
      -C "$(dirname "$siteroot")" \
      "${BACKUP_TAR_EXCLUDES[@]}" \
      -- "${archive_members[@]}" || tar_rc=$?
    # 結束代碼 1 只表示打包期間有檔案變動，備份仍可用；2 以上才是失敗
    if [[ "$tar_rc" -eq 1 ]]; then
      log_warn "$(_t "BACKUP_WARN_FILES_CHANGED")"
    elif [[ "$tar_rc" -gt 1 ]]; then
      log_error "$(_t "BACKUP_SITE_ARCHIVE_FAILED")"
      rm -rf "$tmp_work_dir"
      return 1
    fi

    target_file="$tar_file"

  else
    log_error "$(_t "BACKUP_SITE_12" "${b_type}")"
    rm -rf "$tmp_work_dir"
    return 1
  fi

  local file_basename
  file_basename=$(basename "$target_file")
  local file_size_bytes
  file_size_bytes=$(stat -c '%s' "$target_file" 2>/dev/null || stat -f '%z' "$target_file" 2>/dev/null || wc -c < "$target_file")
  local file_size_h
  file_size_h=$(backup_format_size "$file_size_bytes")

  # ----------------------------------------------------------------------------
  # Transfer Target (Local or Remote)
  # ----------------------------------------------------------------------------
  if [[ "$b_to" == "local" ]]; then
    local dest_dir="${b_path:-${cfg_local_dir}}"
    if ! mkdir -p "$dest_dir" || ! mv "$target_file" "${dest_dir}/${file_basename}"; then
      log_error "$(_t "BACKUP_ERR_MOVE" "$dest_dir")"
      rm -rf "$tmp_work_dir"
      return 1
    fi
    chmod 700 "$dest_dir" 2>/dev/null || true
    log_success "$(_t "BACKUP_SITE_13" "${dest_dir}" "${file_basename}" "${file_size_h}")"

    # Expire cleanup (local)
    if [[ -n "$b_expire" ]]; then
      local days
      days=$(echo "$b_expire" | tr -d 'dD')
      if [[ "$days" =~ ^[0-9]+$ ]]; then
        log_info "$(_t "BACKUP_SITE_14" "${days}" "${b_type}")"
        case "$b_type" in
          "db")
            find "$dest_dir" -maxdepth 1 -type f \( -name "${domain}-backup-*.sql*" -o -name "${domain}-db-*.sql*" \) -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          "full")
            find "$dest_dir" -maxdepth 1 -type f -name "${domain}-full-*.tar.gz" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          "compact")
            find "$dest_dir" -maxdepth 1 -type f -name "${domain}-compact-*.tar.gz" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          "archive")
            find "$dest_dir" -maxdepth 1 -type f -name "${domain}-archive-*.tar.gz" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          *)
            find "$dest_dir" -maxdepth 1 -type f -name "${domain}*" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
        esac

        # 清理本機超過 N 天之 rollback 快照目錄
        local rb_base
        rb_base="$(backup_rollback_base 2>/dev/null)" || rb_base=""
        if [[ -n "$rb_base" && -d "$rb_base" ]]; then
          find "$rb_base" -mindepth 1 -maxdepth 1 -type d -name "${domain}-*" -mtime "+${days}" -exec rm -rf {} + 2>/dev/null || true
        fi
      fi
    fi

  else
    # Remote upload via rclone
    local remote="${b_to%:}"
    backup_validate_remote "$remote" || {
      rm -rf "$tmp_work_dir"
      return 1
    }

    local remote_dest_path="${b_path:-${cfg_remote_dir}/${domain}}"
    remote_dest_path=$(echo "$remote_dest_path" | sed 's~^/~~; s~/$~~')

    log_step "$(_t "BACKUP_SITE_15" "${remote}" "${remote_dest_path}" "${file_basename}")"
    rclone copy -P "$target_file" "${remote}:${remote_dest_path}" || {
      log_error "$(_t "BACKUP_SITE_16")"
      rm -rf "$tmp_work_dir"
      return 1
    }

    log_success "$(_t "BACKUP_SITE_17" "${remote}" "${remote_dest_path}" "${file_basename}" "${file_size_h}")"

    # Expire cleanup (remote)
    if [[ -n "$b_expire" ]]; then
      local days
      days=$(echo "$b_expire" | tr -d 'dD')
      if [[ "$days" =~ ^[0-9]+$ ]]; then
        log_info "$(_t "BACKUP_SITE_18" "${days}" "${b_type}")"
        case "$b_type" in
          "db")
            rclone delete --max-depth 1 "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-backup-*.sql*" --include "${domain}-db-*.sql*" 2>/dev/null || true
            ;;
          "full")
            rclone delete --max-depth 1 "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-full-*.tar.gz" 2>/dev/null || true
            ;;
          "compact")
            rclone delete --max-depth 1 "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-compact-*.tar.gz" 2>/dev/null || true
            ;;
          "archive")
            rclone delete --max-depth 1 "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-archive-*.tar.gz" 2>/dev/null || true
            ;;
          *)
            rclone delete --max-depth 1 "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}*" 2>/dev/null || true
            ;;
        esac
      fi
    fi
  fi

  rm -rf "$tmp_work_dir"
  return 0
}

# ------------------------------------------------------------------------------
# Dispatcher for `clp backup`
# ------------------------------------------------------------------------------
backup_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  local domain=""
  for pos in "${POSITIONAL[@]}"; do
    local clean_pos
    clean_pos=$(clean_domain "$pos")
    if [[ "$clean_pos" != "backup" && -n "$clean_pos" ]]; then
      domain="$clean_pos"
      break
    fi
  done

  if [[ -z "$domain" ]]; then
    log_error "$(_t "BACKUP_HANDLER_1")"
    echo -e "$(_t "BACKUP_HANDLER_2")"
    echo -e "$(_t "BACKUP_HANDLER_3")"
    echo -e "$(_t "BACKUP_HANDLER_4")"
    echo -e "$(_t "BACKUP_HANDLER_5")"
    echo -e "$(_t "BACKUP_HANDLER_6")"
    echo -e "$(_t "BACKUP_HANDLER_7")"
    echo -e "$(_t "BACKUP_HANDLER_SKIP_DISABLED")"
    echo -e "$(_t "BACKUP_HANDLER_8")"
    echo -e "  sudo clp backup example.com -type=db"
    echo -e "  sudo clp backup example.com -type=full -to=local"
    echo -e "  sudo clp backup example.com -type=compact -to=google -expire=30d"
    echo -e "  sudo clp backup example.com -type=archive -to=google -expire=35d"
    echo -e "  sudo clp backup all -type=full -to=b2 -expire=14d -exclude='test.,dev.'"
    echo -e "  sudo clp backup example.com -type=db -db-root"
    return 1
  fi

  reject_extra_positionals raw_args "to|type|path|expire|exclude|skip-disabled|db-root|db_root|y|yes" "$domain" "backup" || return 1

  # -type / -to 未指定時使用 clp config 的 backup-type / backup-to
  local b_type
  b_type=$(opt_get "type" "")
  if [[ -z "$b_type" ]]; then
    b_type="$(config_get_valid BACKUP_TYPE)" || return 1
  fi
  local b_to
  b_to=$(opt_get "to" "")
  if [[ -z "$b_to" ]]; then
    b_to="$(config_get_valid BACKUP_TO)" || return 1
  fi
  b_to="${b_to%:}"
  local b_path
  b_path=$(opt_get "path" "")
  # -path 與 backup-dir 套用相同的檢查（不可為 /、/home、/tmp 等系統或可被其他使用者寫入的目錄）
  if [[ -n "$b_path" && "$b_to" == "local" ]] && ! config_validate_value BACKUP_DIR "$b_path"; then
    log_error "$(_t "BACKUP_ERR_BAD_PATH" "$b_path")"
    return 1
  fi
  # 批次備份（all）先檢查一次預設目錄，避免每個網站各報一次錯
  if [[ -z "$b_path" ]]; then
    if [[ "$b_to" == "local" ]]; then
      config_get_valid BACKUP_DIR >/dev/null || return 1
    else
      config_get_valid BACKUP_REMOTE_DIR >/dev/null || return 1
    fi
  fi
  # -expire 未指定時使用 clp config 的 backup-expire（出廠值 off = 不清理）；-expire=off 可在單次執行停用
  local b_expire
  b_expire=$(opt_get "expire" "")
  # 相容舊寫法：7 → 7d、30D → 30d
  b_expire="${b_expire,,}"
  [[ "$b_expire" =~ ^[0-9]+$ ]] && b_expire="${b_expire}d"
  # -expire 與 backup-expire 套用相同的檢查（1d～3650d 或 off；0d 會刪掉剛上傳的備份）
  if [[ -n "$b_expire" ]] && ! config_validate_value BACKUP_EXPIRE "$b_expire"; then
    log_error "$(_t "BACKUP_ERR_BAD_EXPIRE" "$b_expire")"
    return 1
  fi
  local b_expire_off=0
  if [[ "$b_expire" == "off" ]]; then
    b_expire=""
    b_expire_off=1
  fi
  if [[ -z "$b_expire" && "$b_expire_off" -eq 0 ]]; then
    b_expire="$(config_get_valid BACKUP_EXPIRE)" || return 1
    [[ "$b_expire" == "off" ]] && b_expire=""
  fi
  local b_exclude
  b_exclude=$(opt_get "exclude" "")

  if [[ "$domain" == "all" ]]; then
    log_step "$(_t "BACKUP_HANDLER_9")"
    local sites=() skipped_disabled=()
    local skip_disabled=0
    if has_opt "skip-disabled" || has_opt "skip_disabled"; then
      skip_disabled=1
    fi
    for d in /home/*/htdocs/*; do
      if [[ -d "$d" ]]; then
        local d_name
        d_name=$(basename "$d")
        if [[ "$d_name" =~ \. ]]; then
          if [[ -n "$b_exclude" ]]; then
            local skip=0
            IFS=',' read -ra ex_patterns <<< "$b_exclude"
            for pat in "${ex_patterns[@]}"; do
              if domain_matches_exclude "$d_name" "$pat"; then
                skip=1
                break
              fi
            done
            [[ $skip -eq 1 ]] && continue
          fi
          # -skip-disabled：跳過已停用（vhost 不在 sites-enabled）的網站
          if [[ "$skip_disabled" -eq 1 && ! -f "/etc/nginx/sites-enabled/${d_name}.conf" ]]; then
            skipped_disabled+=("$d_name")
            continue
          fi
          sites+=("$d_name")
        fi
      fi
    done

    if [[ ${#skipped_disabled[@]} -gt 0 ]]; then
      log_info "$(_t "BACKUP_HANDLER_SKIPPED_DISABLED" "${#skipped_disabled[@]}" "${skipped_disabled[*]}")"
    fi

    if [[ ${#sites[@]} -eq 0 ]]; then
      log_warn "$(_t "BACKUP_HANDLER_10")"
      return 0
    fi

    local success_count=0
    for s in "${sites[@]}"; do
      echo -e "$(_t "BACKUP_HANDLER_11" "${C_CYAN}" "${s}" "${C_NC}")"
      if backup_site "$s" "$b_type" "$b_to" "$b_path" "$b_expire"; then
        success_count=$((success_count + 1))
      fi
    done
    echo ""
    if [[ "$success_count" -eq "${#sites[@]}" ]]; then
      log_success "$(_t "BACKUP_HANDLER_12" "${success_count}" "${#sites[@]}")"
      return 0
    fi
    log_error "$(_t "BACKUP_HANDLER_13" "${success_count}" "${#sites[@]}")"
    return 1
  else
    require_site_exists "$domain" "$(_t "BACKUP_HANDLER_14")" || return 1
    backup_site "$domain" "$b_type" "$b_to" "$b_path" "$b_expire"
  fi
}

# restore_build_rsync_rules <type> <backup_year> <extracted_root> <siteroot> [<skip_year>]
#   設定 RESTORE_RSYNC_RULES：還原時 rsync 的 include/exclude 規則（以網站根目錄為傳輸根目錄）。
#   預設會搭配 --delete 鏡像，所以規則必須把「該類型備份範圍以外」的路徑全部排除（被排除的路徑不會被刪除）。
#   回傳 0：可安全使用 --delete；2：取不到備份年份；3：無法判斷類型（兩者都只能不帶 --delete 還原）。
restore_build_rsync_rules() {
  local kind="$1" year="$2" src="$3" siteroot="$4"
  local skip_year="${5:-}"  # archive：同時還原的 compact 年份，以 compact 為準，archive 不處理
  local rc=0
  backup_rsync_exclude_args
  RESTORE_RSYNC_RULES=(--exclude='/.clp_db_export.sql' "${BACKUP_RSYNC_EXCLUDES[@]}")
  # 保留目前的 wp-config.php：資料庫已匯入目前 wp-config 指定的資料庫，若改用備份中的
  # wp-config（可能是舊主機或舊網站的 DB 帳密），網站會無法連線資料庫。
  if [[ -f "${siteroot}/wp-config.php" ]]; then
    RESTORE_RSYNC_RULES+=(--exclude='/wp-config.php')
  fi
  case "$kind" in
    full)
      ;;
    compact)
      # compact 不含 shield、WPvivid_Uploads，以及 uploads 下備份當年以外的項目（由 archive 負責）
      RESTORE_RSYNC_RULES+=(--exclude='/wp-content/shield' --exclude='/wp-content/WPvivid_Uploads')
      if [[ -n "$year" ]]; then
        RESTORE_RSYNC_RULES+=(--include="/wp-content/uploads/${year}" --exclude='/wp-content/uploads/[!.]*')
      else
        rc=2
      fi
      ;;
    archive)
      # archive 只作用在「封裝中實際存在」的 wp-content/uploads 子項目（備份當年與隱藏檔除外，屬於 compact），
      # 以及備份中確實存在的 wp-content/shield、WPvivid_Uploads；其餘路徑（包括比備份新的年份）一律不動。
      # 被排除的路徑不會被 --delete 刪除。名稱含 rsync 萬用字元或換行時略過，避免規則變成比對所有項目。
      RESTORE_RSYNC_RULES+=(--include='/wp-content/')
      if [[ -d "${src}/wp-content/uploads" ]]; then
        [[ -z "$year" ]] && rc=2
        RESTORE_RSYNC_RULES+=(--include='/wp-content/uploads/')
        local entry name
        for entry in "${src}/wp-content/uploads/"*; do
          [[ -e "$entry" || -L "$entry" ]] || continue
          name="${entry##*/}"
          [[ -n "$year" && "$name" == "$year" ]] && continue
          [[ -n "$skip_year" && "$name" == "$skip_year" ]] && continue
          if [[ "$name" == *[\*\?\[\\]*|| "$name" == *$'\n'* ]]; then
            log_warn "$(_t "BACKUP_RESTORE_WARN_SKIP_NAME" "$name")"
            continue
          fi
          if [[ -d "$entry" && ! -L "$entry" ]]; then
            RESTORE_RSYNC_RULES+=(--include="/wp-content/uploads/${name}/***")
          else
            RESTORE_RSYNC_RULES+=(--include="/wp-content/uploads/${name}")
          fi
        done
      fi
      local extra_dir
      for extra_dir in shield WPvivid_Uploads; do
        if [[ -e "${src}/wp-content/${extra_dir}" ]]; then
          RESTORE_RSYNC_RULES+=(--include="/wp-content/${extra_dir}/***")
        fi
      done
      RESTORE_RSYNC_RULES+=(--exclude='*')
      ;;
    *)
      rc=3
      ;;
  esac
  return "$rc"
}

# ------------------------------------------------------------------------------
# 2. Restore Core Function
# ------------------------------------------------------------------------------
# backup-dir 改過之後，舊的備份（含 clone／migrate 之前留存的資料庫）還在原本的預設位置；
# 該處有這個網站的檔案時提示可用 -path 指定
CLP_LEGACY_BACKUP_DIR="/root/clpBackup"
_restore_hint_old_dir() {
  local domain="$1" search_dir="$2"
  [[ "${search_dir%/}" == "$CLP_LEGACY_BACKUP_DIR" ]] && return 0
  [[ -d "$CLP_LEGACY_BACKUP_DIR" ]] || return 0
  if find "$CLP_LEGACY_BACKUP_DIR" -maxdepth 1 -type f \( -name "${domain}-*.tar.gz" -o -name "${domain}-*.sql.gz" -o -name "${domain}-*.sql" \) -print -quit 2>/dev/null | grep -q .; then
    log_info "$(_t "BACKUP_RESTORE_HINT_OLD_DIR" "$domain" "$CLP_LEGACY_BACKUP_DIR" "$domain" "$CLP_LEGACY_BACKUP_DIR")"
  fi
  return 0
}

# _restore_print_rows <index...>：列出選單（使用呼叫端 restore_site 的 avail_* 陣列與 RESTORE_MARKS）
_restore_print_rows() {
  local n=0 idx
  printf "%-5s %-45s %-10s %-12s %-18s\n" "#" "$(_t "BACKUP_SITE_24")" "$(_t "BACKUP_SITE_25")" "$(_t "BACKUP_SITE_26")" "$(_t "BACKUP_SITE_27")"
  echo "--------------------------------------------------------------------------------------------------------"
  for idx in "$@"; do
    n=$((n + 1))
    printf "%-5s %-45s %-10s %-12s %-18s %s\n" "$n" "${avail_files[$idx]}" "${avail_types[$idx]}" "${avail_sizes[$idx]}" "${avail_dates[$idx]}" "${RESTORE_MARKS[$idx]:-}"
  done
  echo "--------------------------------------------------------------------------------------------------------"
}

# _restore_ask <count> <prompt>：讀取 1～count 的編號，設定 RESTORE_PICK（直接按 Enter 時為空字串）；
#   輸入 q 或讀到 EOF 時回傳 1（取消）；無效的輸入重新詢問
_restore_ask() {
  local count="$1" prompt="$2" ans=""
  while true; do
    if ! read -r -p "$prompt" ans; then
      echo ""
      return 1
    fi
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    [[ "$ans" =~ ^[Qq]$ ]] && return 1
    if [[ -z "$ans" ]]; then
      RESTORE_PICK=""
      return 0
    fi
    # 以十進位解讀（010 不可被當成八進位的 8）
    if [[ "$ans" =~ ^[0-9]{1,6}$ ]] && (( 10#$ans >= 1 && 10#$ans <= count )); then
      RESTORE_PICK=$((10#$ans))
      return 0
    fi
    log_warn "$(_t "BACKUP_SITE_30" "$ans")"
  done
}

# 套用順序：archive → compact → full → db（compact 在 archive 之後，資料庫最後）
_restore_kind_order() {
  case "$1" in
    archive) echo 1 ;;
    compact) echo 2 ;;
    db) echo 4 ;;
    *) echo 3 ;;
  esac
}

# restore_site <domain> [<file[,file...]>] [<type>] [<to>] [<path>] [<force>]
#   一次可以還原多個檔案（db、compact、archive 各最多一個；full 只能單獨還原）。流程：
#   1. 選擇檔案（-file 或選單）；2. 準備：下載、解壓、建立規則、算出要刪除的項目（任何失敗都還沒有變更）；
#   3. 確認一次；4. 快照一次；5. 依 archive → compact → db 套用，任何一步失敗就用同一份快照回復。
restore_site() {
  local domain="$1"
  local r_file="${2:-}"     # backup filename(s), comma separated
  local r_type="${3:-}"     # db | full | compact | archive filter for the menu
  local r_to="${4:-local}"  # local | <remote_name>
  local r_path="${5:-}"     # custom local dir or remote path
  local force_mode="${6:-0}"
  if clp_auto_yes || has_opt "force"; then
    force_mode=1
  fi

  domain=$(clean_domain "$domain")

  local siteroot
  siteroot=$(find_site_root "$domain" 2>/dev/null || true)
  local siteuser
  siteuser=$(find_site_user "$domain" 2>/dev/null || true)

  if [[ -z "$siteroot" || ! -d "$siteroot" ]]; then
    log_error "$(_t "BACKUP_SITE_19" "${domain}" "${domain}")"
    return 1
  fi

  local source_is_remote=0
  [[ "$r_to" != "local" ]] && source_is_remote=1

  # 未指定 -path 時的預設搜尋位置（clp config: backup-dir / backup-remote-dir）
  local cfg_local_dir="" cfg_remote_dir=""
  if [[ -z "$r_path" ]]; then
    if [[ "$source_is_remote" -eq 0 ]]; then
      cfg_local_dir="$(config_get_valid BACKUP_DIR)" || return 1
    else
      cfg_remote_dir="$(config_get_valid BACKUP_REMOTE_DIR)" || return 1
    fi
  fi
  # 還原前快照寫在 backup-dir 底下的 rollback/；先檢查設定，不合法時在確認與下載之前停止
  backup_rollback_base >/dev/null || return 1

  local remote="" remote_dir="" search_dir=""
  if [[ "$source_is_remote" -eq 1 ]]; then
    remote="${r_to%:}"
    remote_dir="${r_path:-${cfg_remote_dir}/${domain}}"
    remote_dir=$(echo "$remote_dir" | sed 's~^/~~; s~/$~~')
  else
    search_dir="${r_path:-${cfg_local_dir}}"
  fi

  # ----------------------------------------------------------------------------
  # Step 1: Select backup file(s)
  # ----------------------------------------------------------------------------
  local -a sel_files=()
  if [[ -n "$r_file" ]]; then
    local -a parts=()
    local part
    IFS=',' read -ra parts <<< "$r_file"
    for part in "${parts[@]}"; do
      part="$(printf '%s' "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "$part" ]] && sel_files+=("$part")
    done
    if [[ ${#sel_files[@]} -eq 0 ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_EMPTY_LIST")"
      return 1
    fi
    if [[ ${#sel_files[@]} -gt 1 && -n "$r_type" ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_TYPE_WITH_LIST")"
      return 1
    fi
  else
    log_step "$(_t "BACKUP_SITE_20" "${domain}" "${r_to}")"

    local -a avail_files=() avail_sizes=() avail_dates=() avail_types=()
    local -A RESTORE_MARKS=()
    local -A seen_types=() # 過濾 -type 之前看到的類型，找不到指定類型時列出可用的類型

    if [[ "$source_is_remote" -eq 0 ]]; then
      [[ -z "$r_path" ]] && _restore_hint_old_dir "$domain" "$search_dir"
      if [[ ! -d "$search_dir" ]]; then
        log_error "$(_t "BACKUP_SITE_21" "${search_dir}")"
        return 1
      fi

      # List matching local backup files sorted newest to oldest
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local fname fbytes fsize fdate ftype
        fname=$(basename "$f")
        fbytes=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || wc -c < "$f")
        fsize=$(backup_format_size "$fbytes")
        fdate=$(date -r "$f" +"%Y-%m-%d %H:%M" 2>/dev/null || date -d "@$(stat -c '%Y' "$f" 2>/dev/null)" +"%Y-%m-%d %H:%M" 2>/dev/null || _t "BACKUP_DATE_UNKNOWN")
        ftype=$(backup_file_type "$fname" "$domain")
        seen_types[$ftype]=1

        # Filter by r_type if requested
        if [[ -n "$r_type" && "$ftype" != "$r_type" ]]; then
          continue
        fi

        avail_files+=("$fname")
        avail_sizes+=("$fsize")
        avail_dates+=("$fdate")
        avail_types+=("$ftype")
      done < <(find "$search_dir" -maxdepth 1 -type f \( -name "${domain}-*.tar.gz" -o -name "${domain}-*.sql.gz" -o -name "${domain}-*.sql" \) -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2- || true)

    else
      backup_validate_remote "$remote" || return 1

      # Query rclone lsl (依日期時間由新到舊排序)
      local raw_lsl
      # 只列出該目錄本身（不遞迴）且以 "<domain>-" 開頭的檔案，避免列出子目錄中無法下載的檔案或 example.com.au 等其他網域
      raw_lsl=$(rclone lsl --max-depth 1 "${remote}:${remote_dir}" --include "${domain}-*" 2>/dev/null | sort -k2,2r -k3,3r || true)
      if [[ -z "$raw_lsl" ]]; then
        # Try root of remote
        raw_lsl=$(rclone lsl --max-depth 1 "${remote}:" --include "${domain}-*" 2>/dev/null | sort -k2,2r -k3,3r || true)
      fi

      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Format of rclone lsl: "  123456 2026-09-21 12:34:56.000000000 filename"
        local fbytes fdate ftime fname fsize ftype
        read -r fbytes fdate ftime fname <<< "$line"
        ftime="${ftime%%.*}"
        fname="${fname##*/}"
        fsize=$(backup_format_size "$fbytes")
        ftype=$(backup_file_type "$fname" "$domain")
        seen_types[$ftype]=1

        if [[ -n "$r_type" && "$ftype" != "$r_type" ]]; then
          continue
        fi

        avail_files+=("$fname")
        avail_sizes+=("$fsize")
        avail_dates+=("${fdate} ${ftime}")
        avail_types+=("$ftype")
      done <<< "$raw_lsl"
    fi

    if [[ ${#avail_files[@]} -eq 0 ]]; then
      local have_types="" t
      for t in db full compact archive; do
        [[ -n "${seen_types[$t]:-}" ]] && have_types="${have_types:+${have_types}, }${t}"
      done
      if [[ -n "$r_type" && -n "$have_types" ]]; then
        log_error "$(_t "BACKUP_RESTORE_ERR_TYPE_NONE" "${r_to}" "${domain}" "${r_type}" "${have_types}")"
      else
        log_error "$(_t "BACKUP_SITE_22" "${r_to}" "${domain}")"
      fi
      return 1
    fi

    # 選單需要終端機（-y 不會自動挑選檔案）；讀到 EOF 或輸入 q 視為取消
    if [[ ! -t 0 ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_MENU_NEEDS_TTY")"
      return 1
    fi

    echo ""
    echo -e "${C_CYAN}${C_BOLD}========================================================================================================${C_NC}"
    echo -e "$(_t "BACKUP_SITE_23" "${C_CYAN}" "${C_BOLD}" "${domain}" "${r_to}" "${C_NC}")"
    echo -e "${C_CYAN}${C_BOLD}========================================================================================================${C_NC}"

    local -a whole_idx=() part_idx=()
    local i
    for i in "${!avail_files[@]}"; do
      case "${avail_types[$i]}" in
        db|compact|archive) part_idx+=("$i") ;;
        *) whole_idx+=("$i") ;;
      esac
    done

    # -type 指定時與只有一種備份時：一張清單選一個（full 與無法判斷類型的封裝只能單獨還原）
    local mode=2
    if [[ -n "$r_type" ]]; then
      mode=0
    elif [[ ${#part_idx[@]} -eq 0 ]]; then
      mode=1
    elif [[ ${#whole_idx[@]} -gt 0 ]]; then
      echo ""
      echo "$(_t "BACKUP_RESTORE_MODE_TITLE")"
      echo "$(_t "BACKUP_RESTORE_MODE_OPT1")"
      echo "$(_t "BACKUP_RESTORE_MODE_OPT2")"
      local mode_ans=""
      while true; do
        if ! read -r -p "$(_t "BACKUP_RESTORE_MODE_PROMPT")" mode_ans; then
          echo ""
          log_info "$(_t "BACKUP_SITE_29")"
          return 0
        fi
        mode_ans="$(printf '%s' "$mode_ans" | tr -d '[:space:]')"
        case "$mode_ans" in
          1|2) mode="$mode_ans"; break ;;
          q|Q) log_info "$(_t "BACKUP_SITE_29")"; return 0 ;;
          *) log_warn "$(_t "BACKUP_SITE_30" "$mode_ans")" ;;
        esac
      done
    fi

    local RESTORE_PICK=""
    if [[ "$mode" -ne 2 ]]; then
      local -a list_idx=()
      if [[ "$mode" -eq 0 ]]; then
        list_idx=("${!avail_files[@]}")
      else
        list_idx=("${whole_idx[@]}")
      fi
      echo ""
      _restore_print_rows "${list_idx[@]}"
      echo ""
      if ! _restore_ask "${#list_idx[@]}" "$(_t "BACKUP_SITE_28" "${#list_idx[@]}")" || [[ -z "$RESTORE_PICK" ]]; then
        log_info "$(_t "BACKUP_SITE_29")"
        return 0
      fi
      sel_files=("${avail_files[${list_idx[$((RESTORE_PICK - 1))]}]}")
    else
      # 依序選 db、compact、archive，每一步可以按 Enter 跳過
      # 來源中沒有的類型先說明並略過，步驟編號只算實際有的類型
      local step_kind step_key c_pick_year="" a_year step_no=0
      local -a step_idx=() step_kinds=()
      for step_kind in db compact archive; do
        for i in "${part_idx[@]}"; do
          if [[ "${avail_types[$i]}" == "$step_kind" ]]; then
            step_kinds+=("$step_kind")
            break
          fi
        done
        if [[ " ${step_kinds[*]} " != *" ${step_kind} "* ]]; then
          log_info "$(_t "BACKUP_RESTORE_STEP_MISSING" "$step_kind")"
        fi
      done
      for step_kind in "${step_kinds[@]}"; do
        step_no=$((step_no + 1))
        step_idx=()
        for i in "${part_idx[@]}"; do
          [[ "${avail_types[$i]}" == "$step_kind" ]] && step_idx+=("$i")
        done
        if [[ "$step_kind" == "archive" && -n "$c_pick_year" ]]; then
          for i in "${step_idx[@]}"; do
            a_year=$(backup_file_year "${avail_files[$i]}")
            if [[ -n "$a_year" && "$a_year" -lt "$c_pick_year" ]]; then
              RESTORE_MARKS[$i]="$(_t "BACKUP_RESTORE_MARK_YEAR_GAP" "$a_year")"
            fi
          done
        fi
        step_key="BACKUP_RESTORE_STEP_${step_kind^^}"
        echo ""
        echo -e "${C_BOLD}$(_t "BACKUP_RESTORE_STEP_HEADER" "$step_no" "${#step_kinds[@]}" "$(_t "$step_key")")${C_NC}"
        _restore_print_rows "${step_idx[@]}"
        if ! _restore_ask "${#step_idx[@]}" "$(_t "BACKUP_RESTORE_STEP_PROMPT" "${#step_idx[@]}")"; then
          log_info "$(_t "BACKUP_SITE_29")"
          return 0
        fi
        if [[ -n "$RESTORE_PICK" ]]; then
          i="${step_idx[$((RESTORE_PICK - 1))]}"
          sel_files+=("${avail_files[$i]}")
          [[ "$step_kind" == "compact" ]] && c_pick_year=$(backup_file_year "${avail_files[$i]}")
        fi
      done
      if [[ ${#sel_files[@]} -eq 0 ]]; then
        log_info "$(_t "BACKUP_SITE_29")"
        return 0
      fi
    fi
  fi

  # 確認需要終端機或 -y；在下載與解壓之前就檢查
  if [[ "$force_mode" -eq 0 ]]; then
    require_tty_or_yes || return 1
  fi

  # 檢查組合並排出套用順序：每種類型最多一個；full 與無法判斷類型的封裝只能單獨還原
  local -a item_name=() item_kind=() item_year=()
  local -A seen_kind=()
  local f fname fkind
  for f in "${sel_files[@]}"; do
    fname=$(basename "$f")
    fkind=$(backup_file_type "$fname" "$domain")
    if [[ ${#sel_files[@]} -gt 1 ]]; then
      case "$fkind" in
        full)
          log_error "$(_t "BACKUP_RESTORE_ERR_FULL_MIXED" "$fname")"
          return 1 ;;
        db|compact|archive) ;;
        *)
          log_error "$(_t "BACKUP_RESTORE_ERR_UNKNOWN_IN_SET" "$fname")"
          return 1 ;;
      esac
      if [[ -n "${seen_kind[$fkind]+x}" ]]; then
        log_error "$(_t "BACKUP_RESTORE_ERR_DUP_TYPE" "$fkind")"
        return 1
      fi
    fi
    seen_kind[$fkind]=1
    if [[ "$f" != *.sql && "$f" != *.sql.gz && "$f" != *.tar.gz ]]; then
      log_error "$(_t "BACKUP_SITE_54" "${f}")"
      return 1
    fi
  done
  local -a ordered=()
  local i k
  for k in 1 2 3 4; do
    for i in "${!sel_files[@]}"; do
      fname=$(basename "${sel_files[$i]}")
      [[ "$(_restore_kind_order "$(backup_file_type "$fname" "$domain")")" == "$k" ]] && ordered+=("${sel_files[$i]}")
    done
  done
  sel_files=("${ordered[@]}")
  local c_year="" a_year=""
  for f in "${sel_files[@]}"; do
    fname=$(basename "$f")
    fkind=$(backup_file_type "$fname" "$domain")
    item_name+=("$fname")
    item_kind+=("$fkind")
    item_year+=("$(backup_file_year "$fname")")
    [[ "$fkind" == "compact" ]] && c_year="${item_year[-1]}"
    [[ "$fkind" == "archive" ]] && a_year="${item_year[-1]}"
  done
  local n_items="${#sel_files[@]}"

  # 這組會不會匯入資料庫、會不會寫入檔案（只看檔名；full 與無法判斷類型的封裝可能含資料庫）
  local needs_db=0 any_tar=0
  for i in "${!sel_files[@]}"; do
    [[ "${sel_files[$i]}" == *.tar.gz ]] && any_tar=1
    case "${item_kind[$i]}" in
      compact|archive) [[ "${sel_files[$i]}" == *.tar.gz ]] || needs_db=1 ;;
      *) needs_db=1 ;;
    esac
  done

  # ----------------------------------------------------------------------------
  # Step 2: Prepare every file (nothing on the site or in the database changes yet)
  # ----------------------------------------------------------------------------
  # 先確認資料庫可以存取（不再自動改用 MySQL root）：
  #   會匯入資料庫時，失敗就在下載與任何變更之前停止；只還原檔案（compact、archive）時只警告，快照不含資料庫。
  local db_creds
  db_creds=$(backup_get_site_db_credentials "$siteroot")
  local snap_db_mode="full"
  if [[ -n "${db_creds%%$'\x1f'*}" ]] && ! backup_db_check "$db_creds" "$siteroot" "$siteuser"; then
    backup_db_hint "$db_creds"
    if [[ "$needs_db" -eq 1 ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_DB_ACCESS" "$domain")"
      return 1
    fi
    log_warn "$(_t "BACKUP_RESTORE_WARN_DB_SNAPSHOT_SKIP")"
    snap_db_mode="files"
  fi

  if [[ "$any_tar" -eq 1 ]]; then
    # 檔案寫入改由網站使用者執行，找不到網站使用者時不可繼續
    if [[ -z "$siteuser" ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_NO_SITE_USER" "$domain")"
      return 1
    fi
    # 網站中有不屬於網站使用者的檔案時，網站使用者無法覆寫或刪除，還原會失敗後 rollback；先列出並停止
    local foreign_owned
    foreign_owned=$(restore_foreign_owned "$siteuser" "$siteroot")
    if [[ -n "$foreign_owned" ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_FOREIGN_OWNED" "$siteuser" "$siteuser" "$siteroot")"
      printf '%s\n' "$foreign_owned" | sed 's/^/    /'
      return 1
    fi
  fi

  # 每次還原使用獨立且不可預測的暫存目錄（mktemp 以 700 建立）。root_dir 放 root 要讀取的檔案
  # （下載的封裝、SQL、備份中的 wp-config.php、rsync 規則），永遠不交給網站使用者
  local restore_cache=""
  trap '[[ -n "${restore_cache:-}" && -d "${restore_cache:-}" ]] && rm -rf "$restore_cache"; trap - RETURN' RETURN
  restore_cache=$(mktemp -d "/var/tmp/clpRestore.XXXXXX") || return 1
  local root_dir="${restore_cache}/root"
  (umask 077; mkdir "$root_dir") || return 1

  local -a item_path=()
  for i in "${!sel_files[@]}"; do
    f="${sel_files[$i]}"
    if [[ "$source_is_remote" -eq 1 ]]; then
      log_step "$(_t "BACKUP_SITE_35" "${remote}" "${f}")"
      rclone copy -P "${remote}:${remote_dir}/${f}" "$root_dir/" || {
        # Fallback: try root of remote
        rclone copy -P "${remote}:${f}" "$root_dir/" || {
          log_error "$(_t "BACKUP_SITE_36")"
          return 1
        }
      }
      item_path+=("${root_dir}/${item_name[$i]}")
      chmod 600 "${item_path[$i]}" 2>/dev/null || true
    elif [[ -f "${search_dir}/${f}" ]]; then
      item_path+=("${search_dir}/${f}")
    elif [[ -f "$f" ]]; then
      item_path+=("$f")
    else
      log_error "$(_t "BACKUP_SITE_37" "${f}")"
      return 1
    fi
    if [[ ! -f "${item_path[$i]}" ]]; then
      log_error "$(_t "BACKUP_SITE_38" "${item_path[$i]}")"
      return 1
    fi
  done

  local site_dirname
  site_dirname="$(basename "$siteroot")"
  local mirror_default=1
  if has_opt "keep-extra" || has_opt "keep_extra"; then
    mirror_default=0
  fi
  # 每個封裝的準備結果（索引與 sel_files 相同；SQL 檔沒有封裝相關欄位）
  local -a item_src=() item_unpack=() item_sql=() item_wpcfg=() item_hascfg=() item_mirror=() item_del=()
  for i in "${!sel_files[@]}"; do
    item_src+=(""); item_unpack+=(""); item_sql+=(""); item_wpcfg+=(""); item_hascfg+=(0); item_mirror+=(0); item_del+=("")
    if [[ "${item_path[$i]}" != *.tar.gz ]]; then
      item_sql[$i]="${item_path[$i]}"
      continue
    fi
    local unpack_dir="${restore_cache}/unpack_${i}"
    (umask 077; mkdir "$unpack_dir") || return 1
    log_info "$(_t "BACKUP_SITE_45")"
    if ! tar --no-same-owner -xzf "${item_path[$i]}" -C "$unpack_dir"; then
      log_error "$(_t "BACKUP_RESTORE_ERR_PREPARE" "${item_name[$i]}")"
      return 1
    fi

    # 封裝最上層必須是這個網站的目錄（備份時以網站目錄名稱打包）。沒有時拒絕：
    # 不可退回以解壓根目錄為來源，否則其他網站的目錄與最上層的 backup.sql 會被複製進網站根目錄（公開下載）
    if [[ ! -d "${unpack_dir}/${site_dirname}" || -L "${unpack_dir}/${site_dirname}" ]]; then
      log_error "$(_t "BACKUP_RESTORE_ERR_FOREIGN_ARCHIVE" "${item_name[$i]}" "$site_dirname")"
      return 1
    fi
    local extracted_root="${unpack_dir}/${site_dirname}"
    item_unpack[$i]="$unpack_dir"
    item_src[$i]="$extracted_root"

    # ------------------------------------------------------------------------
    # rsync 規則：預設以 --delete 鏡像（還原結果 = 備份當時的檔案），只作用在該類型的備份範圍內。
    # 被排除的路徑不會被 --delete 刪除，所以必須帶上與備份時相同的排除清單。
    # 年份以「備份當時」為準（取自檔名時間戳記），不是還原當天。
    # 同時還原 compact 時，archive 不處理 compact 的年份（以 compact 為準）。
    # ------------------------------------------------------------------------
    local skip_year=""
    [[ "${item_kind[$i]}" == "archive" && -n "$c_year" ]] && skip_year="$c_year"
    local rules_rc=0
    restore_build_rsync_rules "${item_kind[$i]}" "${item_year[$i]}" "$extracted_root" "$siteroot" "$skip_year" || rules_rc=$?
    local mirror_mode="$mirror_default"
    if [[ "$mirror_mode" -eq 1 && "$rules_rc" -ne 0 ]]; then
      if [[ "$rules_rc" -eq 2 ]]; then
        log_warn "$(_t "BACKUP_RESTORE_WARN_NO_YEAR" "${item_name[$i]}")"
      else
        log_warn "$(_t "BACKUP_RESTORE_WARN_UNKNOWN_TYPE" "${item_name[$i]}")"
      fi
      mirror_mode=0
    fi
    item_mirror[$i]="$mirror_mode"
    printf '%s\0' "${RESTORE_RSYNC_RULES[@]}" > "${root_dir}/rules_${i}" || return 1

    # 交給網站使用者之前，先把要由 root 讀取的檔案移到 root_dir（之後網站使用者可以替換暫存目錄中的檔案）：
    # 新版封裝最上層的 backup.sql、舊版的 <domain>/.clp_db_export.sql，以及備份中的 wp-config.php
    # （之後另存於 root 專屬的快照目錄，不可放在網站根目錄，否則會被當成純文字公開）
    if [[ -f "${unpack_dir}/backup.sql" && ! -L "${unpack_dir}/backup.sql" ]]; then
      item_sql[$i]="${root_dir}/sql_${i}.sql"
      mv "${unpack_dir}/backup.sql" "${item_sql[$i]}" || { log_error "$(_t "BACKUP_RESTORE_ERR_PREPARE" "${item_name[$i]}")"; return 1; }
    elif [[ -f "${extracted_root}/.clp_db_export.sql" && ! -L "${extracted_root}/.clp_db_export.sql" ]]; then
      item_sql[$i]="${root_dir}/sql_${i}.sql"
      mv "${extracted_root}/.clp_db_export.sql" "${item_sql[$i]}" || { log_error "$(_t "BACKUP_RESTORE_ERR_PREPARE" "${item_name[$i]}")"; return 1; }
    fi
    if [[ -f "${extracted_root}/wp-config.php" && ! -L "${extracted_root}/wp-config.php" ]]; then
      item_hascfg[$i]=1
      if [[ -f "${siteroot}/wp-config.php" ]]; then
        item_wpcfg[$i]="${root_dir}/wpcfg_${i}.php"
        install -m 600 "${extracted_root}/wp-config.php" "${item_wpcfg[$i]}" || { log_error "$(_t "BACKUP_RESTORE_ERR_PREPARE" "${item_name[$i]}")"; return 1; }
      fi
    fi
    if ! restore_stage_for_user "$siteuser" "$extracted_root" "$restore_cache" "$unpack_dir"; then
      log_error "$(_t "BACKUP_RESTORE_ERR_PREPARE" "${item_name[$i]}")"
      return 1
    fi

    # 先以 dry-run 計算會被刪除的檔案（確認時列出）
    if [[ "$mirror_mode" -eq 1 ]]; then
      item_del[$i]=$(sudo -H -u "$siteuser" rsync -rlpt --delete --dry-run --itemize-changes "${RESTORE_RSYNC_RULES[@]}" "${extracted_root}/" "${siteroot}/" 2>/dev/null \
        | sed -n 's/^\*deleting  *//p' || true)
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 3: Confirm once (files, years, items to be deleted)
  # ----------------------------------------------------------------------------
  echo ""
  echo -e "$(_t "BACKUP_SITE_31" "${C_YELLOW}" "${C_BOLD}" "${C_NC}")"
  echo -e "$(_t "BACKUP_SITE_32" "${C_CYAN}" "${domain}" "${C_NC}")"
  if [[ "$n_items" -eq 1 ]]; then
    echo -e "$(_t "BACKUP_SITE_33" "${C_YELLOW}" "${item_name[0]}" "${C_NC}")"
  else
    echo "$(_t "BACKUP_RESTORE_FILES_HEADER")"
    for i in "${!item_name[@]}"; do
      echo -e "  $((i + 1)). ${C_YELLOW}${item_name[$i]}${C_NC} (${item_kind[$i]})"
    done
  fi
  echo ""
  if [[ -n "$c_year" && -n "$a_year" && "$c_year" != "$a_year" ]]; then
    if [[ "$a_year" -gt "$c_year" ]]; then
      log_info "$(_t "BACKUP_RESTORE_INFO_YEAR_OVERLAP" "$c_year")"
    else
      log_warn "$(_t "BACKUP_RESTORE_WARN_YEAR_GAP" "$a_year" "$c_year" "$a_year")"
    fi
  fi

  local total_del=0 any_keep_extra=0 del_count del_preview
  for i in "${!item_name[@]}"; do
    [[ -n "${item_src[$i]}" && "${item_mirror[$i]}" -eq 0 ]] && any_keep_extra=1
    [[ -n "${item_del[$i]}" ]] || continue
    del_count=$(printf '%s\n' "${item_del[$i]}" | wc -l | tr -d '[:space:]')
    [[ "$del_count" -gt 0 ]] || continue
    total_del=$((total_del + del_count))
    if [[ "$n_items" -eq 1 ]]; then
      log_warn "$(_t "BACKUP_RESTORE_DELETE_COUNT" "$del_count")"
    else
      log_warn "$(_t "BACKUP_RESTORE_DELETE_COUNT_FILE" "${item_name[$i]}" "$del_count")"
    fi
    # 先截取再輸出（避免清單很長時 head 提早結束，printf 收到 SIGPIPE 而在 pipefail 下中止）
    del_preview=$(sed -n '1,20p' <<< "${item_del[$i]}")
    printf '%s\n' "$del_preview" | sed 's/^/    /'
    if [[ "$del_count" -gt 20 ]]; then
      echo "    $(_t "BACKUP_RESTORE_DELETE_MORE" "$((del_count - 20))")"
    fi
  done
  [[ "$any_keep_extra" -eq 1 ]] && log_info "$(_t "BACKUP_RESTORE_INFO_KEEP_EXTRA")"

  if [[ "$force_mode" -eq 0 ]]; then
    local confirm="" prompt_key="BACKUP_SITE_34"
    [[ "$total_del" -gt 0 ]] && prompt_key="BACKUP_RESTORE_DELETE_PROMPT"
    read -r -p "$(_t "$prompt_key")" confirm || confirm=""
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
      log_info "$(_t "BACKUP_SITE_29")"
      return 0
    fi
  fi

  # ----------------------------------------------------------------------------
  # Step 4: Snapshot (Rollback Safety), once for the whole set
  # ----------------------------------------------------------------------------
  log_step "$(_t "BACKUP_SITE_39")"
  # 快照：預設建立；空間不足或快照失敗時，互動模式讓使用者決定是否在沒有快照的情況下繼續，
  # -y／--force 時一律中止（保守預設，需要明確加上 -no-snapshot 才會略過）。
  local snap_dir="" snap_mode="full" snap_problem=""
  if has_opt "no-snapshot" || has_opt "no_snapshot"; then
    snap_mode="none"
    log_warn "$(_t "BACKUP_SNAPSHOT_SKIPPED_BY_OPTION")"
  elif ! restore_snapshot_space_check "$siteroot" "$db_creds"; then
    snap_problem="$(_t "BACKUP_SNAPSHOT_ERR_SPACE" "$(backup_format_size "$SNAP_NEED_BYTES")" "$(backup_format_size "$SNAP_AVAIL_BYTES")")"
  elif ! snap_dir=$(restore_take_snapshot "$domain" "$siteroot" "$db_creds" "$snap_db_mode" "$siteuser"); then
    snap_dir=""
    snap_problem="$(_t "BACKUP_SNAPSHOT_ERR_FAILED")"
  fi

  if [[ -n "$snap_problem" ]]; then
    log_error "$snap_problem"
    log_info "$(_t "BACKUP_SNAPSHOT_HINT_CLEANUP" "$(backup_rollback_base 2>/dev/null)")"
    if [[ "$force_mode" -eq 1 ]]; then
      log_error "$(_t "BACKUP_SNAPSHOT_ERR_AUTO_ABORT")"
      return 1
    fi
    local snap_confirm=""
    read -r -p "$(_t "BACKUP_SNAPSHOT_PROMPT_CONTINUE")" snap_confirm || snap_confirm=""
    if [[ "$snap_confirm" != "yes" ]]; then
      log_info "$(_t "BACKUP_SITE_29")"
      return 0
    fi
    snap_mode="none"
  fi

  if [[ "$snap_mode" == "none" ]]; then
    if ! snap_dir=$(restore_take_snapshot "$domain" "$siteroot" "$db_creds" "none"); then
      log_error "$(_t "BACKUP_SNAPSHOT_ERR_FAILED")"
      return 1
    fi
    log_warn "$(_t "BACKUP_SNAPSHOT_NONE_WARN")"
  else
    log_info "$(_t "BACKUP_SITE_40" "${snap_dir}")"
  fi

  # 備份中的 wp-config.php 另存於快照目錄（root 專屬）
  for i in "${!item_wpcfg[@]}"; do
    [[ -n "${item_wpcfg[$i]}" ]] || continue
    if install -m 600 "${item_wpcfg[$i]}" "${snap_dir}/wp-config.from-backup.php"; then
      log_info "$(_t "BACKUP_SITE_49" "${snap_dir}")"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 5: Apply in order (archive → compact → full → db); any failure rolls back the whole set
  # ----------------------------------------------------------------------------
  log_step "$(_t "BACKUP_SITE_41" "${domain}")"
  local any_files=0
  for i in "${!item_name[@]}"; do
    if [[ -z "${item_src[$i]}" ]]; then
      # Pure DB Restore
      log_info "$(_t "BACKUP_SITE_42")"
      if ! restore_import_sql "${item_sql[$i]}" "$db_creds" "$siteroot" "$siteuser"; then
        log_error "$(_t "BACKUP_SITE_43")"
        restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir" || true
        return 1
      fi
      log_success "$(_t "BACKUP_SITE_44")"
      if [[ -f "${siteroot}/wp-config.php" ]]; then
        restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "${item_sql[$i]}" "$siteuser"
      fi
      continue
    fi

    # Embedded SQL dump (only CLP's own dump at the archive root or the legacy .clp_db_export.sql;
    # never import arbitrary .sql files that happen to be part of the site)
    if [[ -n "${item_sql[$i]}" ]]; then
      log_step "$(_t "BACKUP_SITE_47")"
      if ! restore_import_sql "${item_sql[$i]}" "$db_creds" "$siteroot" "$siteuser"; then
        log_error "$(_t "BACKUP_SITE_43")"
        restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir" || true
        return 1
      fi
      log_success "$(_t "BACKUP_SITE_48")"
      if [[ -f "${siteroot}/wp-config.php" && "${item_hascfg[$i]}" -eq 0 ]]; then
        restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "${item_sql[$i]}" "$siteuser"
      fi
      rm -f "${item_sql[$i]}"
    fi

    # Sync web files（備份中的 wp-config.php 已另存，依它同步 table prefix）
    if [[ -n "${item_wpcfg[$i]}" ]]; then
      restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "${item_wpcfg[$i]}" "$siteuser"
    fi
    local -a rsync_rules=() rsync_mode_args=()
    mapfile -d '' -t rsync_rules < "${root_dir}/rules_${i}"
    [[ "${item_mirror[$i]}" -eq 1 ]] && rsync_mode_args=(--delete)
    log_info "$(_t "BACKUP_SITE_50" "${siteroot}")"
    # 以網站使用者身分寫入，檔案直接屬於網站使用者，不需要再以 root chown -R
    if ! restore_rsync_as_user "$siteuser" "${item_src[$i]}" "$siteroot" ${rsync_mode_args[@]+"${rsync_mode_args[@]}"} "${rsync_rules[@]}"; then
      log_error "$(_t "BACKUP_SITE_51")"
      restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir" || true
      return 1
    fi
    rm -rf "${item_unpack[$i]}"
    log_success "$(_t "BACKUP_SITE_52")"
    any_files=1
  done

  if [[ "$any_files" -eq 1 ]]; then
    # PHP-FPM pool 固定值只在建立網站時套用；還原不改動使用者或 php-pm 調整過的值
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  fi

  # 清理 WordPress 快取與 Transient
  if command -v wp >/dev/null 2>&1 && [[ -f "${siteroot}/wp-config.php" ]]; then
    log_info "$(_t "BACKUP_SITE_55")"
    if sudo -H -u "$siteuser" wp cache flush --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp cache flush --path="$siteroot" --skip-plugins 2>/dev/null; then
      log_success "$(_t "BACKUP_SITE_56")"
    fi
    sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" --skip-plugins 2>/dev/null || true
  fi

  log_info "$(_t "BACKUP_SITE_57" "${snap_dir}" "${snap_dir}")"

  echo ""
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "BACKUP_SITE_58" "${C_GREEN}" "${C_BOLD}" "${domain}" "${C_NC}")"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "BACKUP_SITE_59" "${C_CYAN}" "${domain}" "${C_NC}")"
  for i in "${!item_name[@]}"; do
    echo -e "$(_t "BACKUP_SITE_60" "${C_YELLOW}" "${item_name[$i]}" "${C_NC}")"
  done
  echo ""
  return 0
}

# ------------------------------------------------------------------------------
# Dispatcher for `clp restore`
# ------------------------------------------------------------------------------
restore_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  local domain=""
  for pos in "${POSITIONAL[@]}"; do
    local clean_pos
    clean_pos=$(clean_domain "$pos")
    if [[ "$clean_pos" != "restore" && -n "$clean_pos" ]]; then
      domain="$clean_pos"
      break
    fi
  done

  if [[ -z "$domain" ]]; then
    log_error "$(_t "BACKUP_HANDLER_15")"
    echo -e "$(_t "BACKUP_HANDLER_2")"
    echo -e "$(_t "BACKUP_HANDLER_16")"
    echo -e "$(_t "BACKUP_HANDLER_17")"
    echo -e "$(_t "BACKUP_HANDLER_18")"
    echo -e "$(_t "BACKUP_HANDLER_19")"
    echo -e "$(_t "BACKUP_HANDLER_20")"
    echo -e "$(_t "BACKUP_HANDLER_KEEP_EXTRA")"
    echo -e "$(_t "BACKUP_HANDLER_NO_SNAPSHOT")"
    echo -e "$(_t "BACKUP_HANDLER_MIRROR_NOTE")"
    echo -e "$(_t "BACKUP_HANDLER_8")"
    echo -e "  sudo clp restore example.com"
    echo -e "  sudo clp restore example.com -file=example.com-db-20260921_120000.sql.gz"
    echo -e "  sudo clp restore example.com -file=example.com-archive-20260901_030000.tar.gz,example.com-compact-20260921_030000.tar.gz,example.com-db-20260921_030000.sql.gz"
    echo -e "  sudo clp restore example.com -to=google -type=full"
    echo -e "  sudo clp restore example.com -type=compact -keep-extra"
    echo -e "  sudo clp restore example.com -file=example.com-db-20260921_120000.sql.gz -db-root"
    return 1
  fi

  reject_extra_positionals raw_args "to|type|path|file|force|keep-extra|no-snapshot|db-root|db_root|y|yes" "$domain" "restore" || return 1

  require_site_exists "$domain" "$(_t "BACKUP_HANDLER_21")" || return 1

  local r_file
  r_file=$(opt_get "file" "")
  local r_type
  r_type=$(opt_get "type" "")
  # -to 未指定時使用 clp config 的 backup-to（備份到遠端的主機，還原也預設從同一個遠端找）
  local r_to
  r_to=$(opt_get "to" "")
  if [[ -z "$r_to" ]]; then
    r_to="$(config_get_valid BACKUP_TO)" || return 1
  fi
  r_to="${r_to%:}"
  local r_path
  r_path=$(opt_get "path" "")
  local force_mode=0
  if has_opt "force"; then
    force_mode=1
  fi

  restore_site "$domain" "$r_file" "$r_type" "$r_to" "$r_path" "$force_mode"
}
