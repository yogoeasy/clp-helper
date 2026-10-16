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

  if ! echo "$remotes" | grep -E -q "^${remote}:"; then
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

  python3 -I - "$wpconfig" << 'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
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

  # UNIX domain socket (以 "/" 開頭)
  if [[ "$raw_host" == /* ]]; then
    socket="$raw_host"
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
# backup_export_site_db <siteroot> <siteuser> <outfile>
#   匯出網站資料庫至 <outfile>（由 root 寫入，網站使用者不需要對目標目錄有寫入權）
#   依序嘗試：WP-CLI (stdout) → 網站 DB 帳號 mysqldump → MySQL root mysqldump
#   成功回傳 0；全部失敗回傳 1 並移除不完整的檔案
# ------------------------------------------------------------------------------
backup_export_site_db() {
  local siteroot="$1"
  local siteuser="$2"
  local outfile="$3"

  ( umask 077; : > "$outfile" )

  if command -v wp >/dev/null 2>&1 && sudo -H -u "$siteuser" wp core is-installed --path="$siteroot" >/dev/null 2>&1; then
    if sudo -H -u "$siteuser" wp db export - --add-drop-table --skip-plugins --skip-themes --path="$siteroot" > "$outfile" 2>/dev/null && [[ -s "$outfile" ]]; then
      return 0
    fi
    log_warn "$(_t "BACKUP_EXPORT_SITE_DB_1")"
  fi

  local db_creds
  db_creds=$(backup_get_site_db_credentials "$siteroot")
  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"
  if [[ -z "$db_name" ]]; then
    rm -f "$outfile"
    return 1
  fi
  build_mysql_conn_args "$db_host" >/dev/null
  local mysql_conn_args=("${MYSQL_CONN_ARGS[@]}")

  if MYSQL_PWD="${db_pass}" mysqldump "${mysql_conn_args[@]}" -u"${db_user}" "${db_name}" > "$outfile" 2>/dev/null && [[ -s "$outfile" ]]; then
    return 0
  fi

  local master_pass
  master_pass=$(get_mysql_master_pass)
  if MYSQL_PWD="${master_pass}" mysqldump "${mysql_conn_args[@]}" -uroot "${db_name}" > "$outfile" 2>/dev/null && [[ -s "$outfile" ]]; then
    return 0
  fi

  rm -f "$outfile"
  return 1
}

# ------------------------------------------------------------------------------
# restore_import_sql <sql_file> <db_creds_str>
#   將 .sql 或 .sql.gz 匯入網站資料庫：先用網站 DB 帳號，失敗再用 MySQL root。
#   以 if 判斷結果，失敗時回傳 1（不會在 set -e 下中途結束，呼叫端可執行 rollback）。
# ------------------------------------------------------------------------------
restore_import_sql() {
  local sql_file="$1"
  local db_creds="$2"
  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"
  [[ -z "$db_name" ]] && return 1
  build_mysql_conn_args "$db_host" >/dev/null
  local mysql_conn_args=("${MYSQL_CONN_ARGS[@]}")

  local reader=(cat "$sql_file")
  [[ "$sql_file" == *.gz ]] && reader=(gunzip -c "$sql_file")

  if "${reader[@]}" | MYSQL_PWD="${db_pass}" mysql "${mysql_conn_args[@]}" -u"${db_user}" "${db_name}" 2>/dev/null; then
    return 0
  fi
  log_warn "$(_t "BACKUP_IMPORT_SQL_1")"
  local master_pass
  master_pass=$(get_mysql_master_pass)
  if "${reader[@]}" | MYSQL_PWD="${master_pass}" mysql "${mysql_conn_args[@]}" -uroot "${db_name}"; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# Restore Rollback Helpers
#   restore_take_snapshot <domain> <siteroot> <db_creds_str>
#     → 建立快照至 /root/clpBackup/rollback/<domain>-<ts>/
#     → 回傳快照目錄路徑（供後續 rollback 使用）
#   restore_rollback <domain> <siteroot> <siteuser> <snapshot_dir>
#     → 從快照目錄還原 DB 與檔案
# ------------------------------------------------------------------------------
restore_take_snapshot() {
  local domain="$1"
  local siteroot="$2"
  local db_creds="$3"   # backup_get_site_db_credentials 的輸出（\x1f 分隔）

  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"

  build_mysql_conn_args "$db_host" >/dev/null
  local mysql_conn_args=("${MYSQL_CONN_ARGS[@]}")

  local rollback_base="/root/clpBackup/rollback"
  # 自動相容：若歷史版本產生的隱藏目錄 .rollback 存在，自動改名為 rollback
  if [[ -d "/root/clpBackup/.rollback" && ! -d "$rollback_base" ]]; then
    mv "/root/clpBackup/.rollback" "$rollback_base" 2>/dev/null || true
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local snap_dir="${rollback_base}/${domain}-${timestamp}"
  mkdir -p "$snap_dir"
  chmod 700 "/root/clpBackup" "$snap_dir" 2>/dev/null || true

  log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_1" "${snap_dir}")"

  # 保存快照當下的 DB 憑證；還原失敗時 wp-config.php 可能已被覆寫，rollback 須沿用原憑證
  ( umask 077; printf '%s\n' "$db_creds" > "${snap_dir}/db_creds" )

  # 1. DB 快照
  if [[ -n "$db_name" ]]; then
    local snap_sql="${snap_dir}/db.sql.gz"
    if MYSQL_PWD="${db_pass}" mysqldump "${mysql_conn_args[@]}" -u"${db_user}" \
        --add-drop-table "${db_name}" 2>/dev/null | gzip -c > "$snap_sql"; then
      log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_2" "${snap_sql}")"
    else
      # 備援用 root
      local master_pass
      master_pass=$(get_mysql_master_pass)
      MYSQL_PWD="${master_pass}" mysqldump "${mysql_conn_args[@]}" -uroot \
        --add-drop-table "${db_name}" 2>/dev/null | gzip -c > "$snap_sql" || {
          log_warn >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_3")"
          rm -f "$snap_sql"
        }
    fi
  fi

  # 2. 網站檔案快照（排除快取以節省空間）
  local snap_files="${snap_dir}/files.tar.gz"
  if [[ -d "$siteroot" ]]; then
    tar -czf "$snap_files" \
      --exclude="wp-content/cache" \
      --exclude="wp-content/updraft" \
      --exclude="wp-content/wpvividbackups" \
      -C "$(dirname "$siteroot")" "$(basename "$siteroot")" 2>/dev/null && \
      log_info >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_4" "${snap_files}")" || \
      log_warn >&2 "$(_t "BACKUP_TAKE_SNAPSHOT_5")"
  fi

  chmod 600 "${snap_dir}"/* 2>/dev/null || true
  echo "$snap_dir"
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

  log_step "$(_t "BACKUP_ROLLBACK_2" "${snap_dir}")"

  # 取得 DB 憑證（優先使用快照當下保存的憑證）
  local db_creds
  if [[ -s "${snap_dir}/db_creds" ]]; then
    db_creds=$(head -n 1 "${snap_dir}/db_creds")
  else
    db_creds=$(backup_get_site_db_credentials "$siteroot")
  fi
  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"

  build_mysql_conn_args "$db_host" >/dev/null
  local mysql_conn_args=("${MYSQL_CONN_ARGS[@]}")

  # 1. 回復資料庫
  local snap_sql="${snap_dir}/db.sql.gz"
  if [[ -f "$snap_sql" && -n "$db_name" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_3")"
    gunzip -c "$snap_sql" | MYSQL_PWD="${db_pass}" mysql "${mysql_conn_args[@]}" -u"${db_user}" "${db_name}" 2>/dev/null || {
      local master_pass
      master_pass=$(get_mysql_master_pass)
      gunzip -c "$snap_sql" | MYSQL_PWD="${master_pass}" mysql "${mysql_conn_args[@]}" -uroot "${db_name}"
    } && log_success "$(_t "BACKUP_ROLLBACK_4")" || log_error "$(_t "BACKUP_ROLLBACK_5")"
  fi

  # 2. 回復網站檔案
  local snap_files="${snap_dir}/files.tar.gz"
  if [[ -f "$snap_files" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_6")"
    rm -rf "$siteroot"
    tar -xzf "$snap_files" -C "$(dirname "$siteroot")" 2>/dev/null && \
      chown -R "${siteuser}:${siteuser}" "$siteroot" && \
      log_success "$(_t "BACKUP_ROLLBACK_7")" || \
      log_error "$(_t "BACKUP_ROLLBACK_8")"
  fi

  # 3. 清除快取 (wp cache flush)
  if command -v wp >/dev/null 2>&1 && [[ -f "${siteroot}/wp-config.php" ]]; then
    log_info "$(_t "BACKUP_ROLLBACK_9")"
    sudo -H -u "$siteuser" wp cache flush --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp cache flush --path="$siteroot" --skip-plugins 2>/dev/null || true
    sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" 2>/dev/null || sudo -H -u "$siteuser" wp transient delete --all --path="$siteroot" --skip-plugins 2>/dev/null || true
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
  local current_year
  current_year=$(date +"%Y")

  # Local working temp directory
  local tmp_work_dir
  tmp_work_dir=$(mktemp -d "/tmp/clpBackup_${domain}_XXXXXX")
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

    gzip -f "$sql_file"
    target_file="$sql_gz"

  # ----------------------------------------------------------------------------
  # Type B: Full Site (-type=full)
  # ----------------------------------------------------------------------------
  elif [[ "$b_type" == "full" ]]; then
    # DB dump 寫在 root 專屬的工作目錄（不放在公開網站根目錄），打包時以 <domain>/.clp_db_export.sql 路徑加入，
    # 與舊版備份的封裝結構相容
    local db_stage_dir="${tmp_work_dir}/dbstage"
    mkdir -p "${db_stage_dir}/${domain}"
    local db_dump_file="${db_stage_dir}/${domain}/.clp_db_export.sql"
    local db_tar_args=()
    log_info "$(_t "BACKUP_SITE_5")"

    if backup_export_site_db "$siteroot" "$siteuser" "$db_dump_file"; then
      db_tar_args=(-C "$db_stage_dir" "${domain}/.clp_db_export.sql")
    elif [[ -f "${siteroot}/wp-config.php" ]]; then
      log_error "$(_t "BACKUP_SITE_6")"
      rm -rf "$tmp_work_dir"
      return 1
    else
      log_warn "$(_t "BACKUP_SITE_7")"
    fi

    local tar_file="${tmp_work_dir}/${domain}-full-${timestamp}.tar.gz"
    log_info "$(_t "BACKUP_SITE_8")"

    tar --warning=no-file-changed \
      --ignore-failed-read \
      -czf "$tar_file" \
      -C "$(dirname "$siteroot")" \
      --exclude="${domain}/wp-content/cache" \
      --exclude="${domain}/wp-content/updraft" \
      --exclude="${domain}/wp-content/wpvividbackups" \
      "$domain" \
      ${db_tar_args[@]+"${db_tar_args[@]}"} || {
        log_error "$(_t "BACKUP_SITE_9")"
        rm -rf "$tmp_work_dir"
        return 1
      }

    rm -rf "$db_stage_dir"
    target_file="$tar_file"

  # ----------------------------------------------------------------------------
  # Type C: Compact Site (-type=compact)
  # ----------------------------------------------------------------------------
  elif [[ "$b_type" == "compact" ]]; then
    local tar_file="${tmp_work_dir}/${domain}-compact-${timestamp}.tar.gz"
    log_info "$(_t "BACKUP_SITE_10" "${current_year}")"

    local exclude_args=()
    exclude_args+=(--exclude="${domain}/wp-content/cache")
    exclude_args+=(--exclude="${domain}/wp-content/updraft")
    exclude_args+=(--exclude="${domain}/wp-content/wpvividbackups")
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

    tar --warning=no-file-changed \
      --ignore-failed-read \
      -czf "$tar_file" \
      -C "$(dirname "$siteroot")" \
      "${exclude_args[@]}" \
      "$domain" || {
        log_error "$(_t "BACKUP_SITE_11")"
        rm -rf "$tmp_work_dir"
        return 1
      }

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
    local dest_dir="${b_path:-/root/clpBackup}"
    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir" 2>/dev/null || true
    mv "$target_file" "${dest_dir}/${file_basename}"
    log_success "$(_t "BACKUP_SITE_13" "${dest_dir}" "${file_basename}" "${file_size_h}")"

    # Expire cleanup (local)
    if [[ -n "$b_expire" ]]; then
      local days
      days=$(echo "$b_expire" | tr -d 'dD')
      if [[ "$days" =~ ^[0-9]+$ ]]; then
        log_info "$(_t "BACKUP_SITE_14" "${days}" "${b_type}")"
        case "$b_type" in
          "db")
            find "$dest_dir" -type f \( -name "${domain}-backup-*.sql*" -o -name "${domain}-db-*.sql*" \) -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          "full")
            find "$dest_dir" -type f -name "${domain}-full-*.tar.gz" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          "compact")
            find "$dest_dir" -type f -name "${domain}-compact-*.tar.gz" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
          *)
            find "$dest_dir" -type f -name "${domain}*" -mtime "+${days}" -delete 2>/dev/null || true
            ;;
        esac

        # 清理本機超過 N 天之 rollback 快照目錄
        if [[ -d "/root/clpBackup/rollback" ]]; then
          find "/root/clpBackup/rollback" -mindepth 1 -maxdepth 1 -type d -name "${domain}-*" -mtime "+${days}" -exec rm -rf {} + 2>/dev/null || true
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

    local remote_dest_path="${b_path:-clpBackup/${domain}}"
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
            rclone delete "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-backup-*.sql*" --include "${domain}-db-*.sql*" 2>/dev/null || true
            ;;
          "full")
            rclone delete "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-full-*.tar.gz" 2>/dev/null || true
            ;;
          "compact")
            rclone delete "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}-compact-*.tar.gz" 2>/dev/null || true
            ;;
          *)
            rclone delete "${remote}:${remote_dest_path}" --min-age "${days}d" --include "${domain}*" 2>/dev/null || true
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
    echo -e "$(_t "BACKUP_HANDLER_8")"
    echo -e "  sudo clp backup example.com -type=db"
    echo -e "  sudo clp backup example.com -type=full -to=local"
    echo -e "  sudo clp backup example.com -type=compact -to=google -expire=30d"
    echo -e "  sudo clp backup all -type=full -to=b2 -expire=14d -exclude='test.,dev.'"
    return 1
  fi

  reject_extra_positionals raw_args "to|type|path|expire|exclude|y|yes" "$domain" "backup" || return 1

  local b_type
  b_type=$(opt_get "type" "full")
  local b_to
  b_to=$(opt_get "to" "local")
  b_to="${b_to%:}"
  local b_path
  b_path=$(opt_get "path" "")
  local b_expire
  b_expire=$(opt_get "expire" "")
  local b_exclude
  b_exclude=$(opt_get "exclude" "")

  if [[ "$domain" == "all" ]]; then
    log_step "$(_t "BACKUP_HANDLER_9")"
    local sites=()
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
          sites+=("$d_name")
        fi
      fi
    done

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

# ------------------------------------------------------------------------------
# 2. Restore Core Function
# ------------------------------------------------------------------------------
restore_site() {
  local domain="$1"
  local r_file="${2:-}"     # specific backup filename
  local r_type="${3:-}"     # db | full | compact filter
  local r_to="${4:-local}"  # local | <remote_name>
  local r_path="${5:-}"     # custom local dir or remote path
  local force_mode="${6:-0}"
  if has_opt "y" || has_opt "yes" || has_opt "force" || [[ "${CLP_AUTO_YES:-false}" == "true" ]]; then
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

  # ----------------------------------------------------------------------------
  # Step 1: Locate or Select Backup File
  # ----------------------------------------------------------------------------
  local selected_file="$r_file"
  local source_is_remote=0
  [[ "$r_to" != "local" ]] && source_is_remote=1

  if [[ -z "$selected_file" ]]; then
    log_step "$(_t "BACKUP_SITE_20" "${domain}" "${r_to}")"

    local available_files=()
    local available_sizes=()
    local available_dates=()
    local available_types=()

    if [[ "$source_is_remote" -eq 0 ]]; then
      local search_dir="${r_path:-/root/clpBackup}"
      if [[ ! -d "$search_dir" ]]; then
        log_error "$(_t "BACKUP_SITE_21" "${search_dir}")"
        return 1
      fi

      # List matching local backup files sorted newest to oldest
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local fname
        fname=$(basename "$f")
        local fbytes
        fbytes=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || wc -c < "$f")
        local fsize
        fsize=$(backup_format_size "$fbytes")
        local fdate
        fdate=$(date -r "$f" +"%Y-%m-%d %H:%M" 2>/dev/null || date -d "@$(stat -c '%Y' "$f" 2>/dev/null)" +"%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")

        local ftype="unknown"
        if [[ "$fname" =~ -db- || "$fname" =~ -backup- || "$fname" =~ \.sql ]]; then ftype="db"; fi
        if [[ "$fname" =~ -full- ]]; then ftype="full"; fi
        if [[ "$fname" =~ -compact- ]]; then ftype="compact"; fi

        # Filter by r_type if requested
        if [[ -n "$r_type" && "$ftype" != "$r_type" ]]; then
          continue
        fi

        available_files+=("$fname")
        available_sizes+=("$fsize")
        available_dates+=("$fdate")
        available_types+=("$ftype")
      done < <(find "$search_dir" -maxdepth 1 -type f \( -name "${domain}-*.tar.gz" -o -name "${domain}-*.sql.gz" -o -name "${domain}-*.sql" \) -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2- || true)

    else
      local remote="${r_to%:}"
      backup_validate_remote "$remote" || return 1
      local remote_dir="${r_path:-clpBackup/${domain}}"
      remote_dir=$(echo "$remote_dir" | sed 's~^/~~; s~/$~~')

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
        local fbytes fdate ftime fname
        read -r fbytes fdate ftime fname <<< "$line"
        ftime="${ftime%%.*}"
        fname="${fname##*/}"

        local fsize
        fsize=$(backup_format_size "$fbytes")
        local ftype="unknown"
        if [[ "$fname" =~ -db- || "$fname" =~ -backup- || "$fname" =~ \.sql ]]; then ftype="db"; fi
        if [[ "$fname" =~ -full- ]]; then ftype="full"; fi
        if [[ "$fname" =~ -compact- ]]; then ftype="compact"; fi

        if [[ -n "$r_type" && "$ftype" != "$r_type" ]]; then
          continue
        fi

        available_files+=("$fname")
        available_sizes+=("$fsize")
        available_dates+=("${fdate} ${ftime}")
        available_types+=("$ftype")
      done <<< "$raw_lsl"
    fi

    if [[ ${#available_files[@]} -eq 0 ]]; then
      log_error "$(_t "BACKUP_SITE_22" "${r_to}" "${domain}")"
      return 1
    fi

    echo ""
    echo -e "${C_CYAN}${C_BOLD}========================================================================================================${C_NC}"
    echo -e "$(_t "BACKUP_SITE_23" "${C_CYAN}" "${C_BOLD}" "${domain}" "${r_to}" "${C_NC}")"
    echo -e "${C_CYAN}${C_BOLD}========================================================================================================${C_NC}"
    printf "%-5s %-45s %-10s %-12s %-18s\n" "#" "$(_t "BACKUP_SITE_24")" "$(_t "BACKUP_SITE_25")" "$(_t "BACKUP_SITE_26")" "$(_t "BACKUP_SITE_27")"
    echo "--------------------------------------------------------------------------------------------------------"
    for i in "${!available_files[@]}"; do
      local idx=$((i + 1))
      printf "%-5s %-45s %-10s %-12s %-18s\n" "$idx" "${available_files[$i]}" "${available_types[$i]}" "${available_sizes[$i]}" "${available_dates[$i]}"
    done
    echo "--------------------------------------------------------------------------------------------------------"
    echo ""

    read -r -p "$(_t "BACKUP_SITE_28" "${#available_files[@]}")" user_choice
    if [[ "$user_choice" =~ ^[Qq]$ || -z "$user_choice" ]]; then
      log_info "$(_t "BACKUP_SITE_29")"
      return 0
    fi

    if ! [[ "$user_choice" =~ ^[0-9]+$ ]] || [[ "$user_choice" -lt 1 || "$user_choice" -gt "${#available_files[@]}" ]]; then
      log_error "$(_t "BACKUP_SITE_30" "${user_choice}")"
      return 1
    fi

    selected_file="${available_files[$((user_choice - 1))]}"
  fi

  # ----------------------------------------------------------------------------
  # Step 2: Confirmation Prompt
  # ----------------------------------------------------------------------------
  echo ""
  echo -e "$(_t "BACKUP_SITE_31" "${C_YELLOW}" "${C_BOLD}" "${C_NC}")"
  echo -e "$(_t "BACKUP_SITE_32" "${C_CYAN}" "${domain}" "${C_NC}")"
  echo -e "$(_t "BACKUP_SITE_33" "${C_YELLOW}" "${selected_file}" "${C_NC}")"
  echo ""

  if [[ "$force_mode" -eq 0 ]]; then
    read -r -p "$(_t "BACKUP_SITE_34")" confirm
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
      log_info "$(_t "BACKUP_SITE_29")"
      return 0
    fi
  fi

  # ----------------------------------------------------------------------------
  # Step 3: Fetch file to local restore cache if remote
  # ----------------------------------------------------------------------------
  # 每次還原使用獨立且不可預測的暫存目錄（mktemp 會以 700 權限建立，避免其他本機使用者預先建立或替換檔案）
  local restore_cache=""
  trap '[[ -n "${restore_cache:-}" && -d "${restore_cache:-}" ]] && rm -rf "$restore_cache"; trap - RETURN' RETURN
  local local_restore_file=""

  if [[ "$source_is_remote" -eq 1 ]]; then
    restore_cache=$(mktemp -d "/tmp/clpRestore.XXXXXX")
    local remote="${r_to%:}"
    local remote_dir="${r_path:-clpBackup/${domain}}"
    remote_dir=$(echo "$remote_dir" | sed 's~^/~~; s~/$~~')

    log_step "$(_t "BACKUP_SITE_35" "${remote}" "${selected_file}")"
    rclone copy -P "${remote}:${remote_dir}/${selected_file}" "$restore_cache/" || {
      # Fallback: try root of remote
      rclone copy -P "${remote}:${selected_file}" "$restore_cache/" || {
        log_error "$(_t "BACKUP_SITE_36")"
        return 1
      }
    }
    local_restore_file="${restore_cache}/${selected_file}"
  else
    local search_dir="${r_path:-/root/clpBackup}"
    if [[ -f "${search_dir}/${selected_file}" ]]; then
      local_restore_file="${search_dir}/${selected_file}"
    elif [[ -f "$selected_file" ]]; then
      local_restore_file="$selected_file"
    else
      log_error "$(_t "BACKUP_SITE_37" "${selected_file}")"
      return 1
    fi
  fi

  if [[ ! -f "$local_restore_file" ]]; then
    log_error "$(_t "BACKUP_SITE_38" "${local_restore_file}")"
    return 1
  fi

  # ----------------------------------------------------------------------------
  # Step 4: Snapshot (Rollback Safety) + Execute Restore
  # ----------------------------------------------------------------------------
  log_step "$(_t "BACKUP_SITE_39")"
  local db_creds
  db_creds=$(backup_get_site_db_credentials "$siteroot")
  local db_name db_user db_pass db_host
  IFS=$'\x1f' read -r db_name db_user db_pass db_host <<< "$db_creds"
  build_mysql_conn_args "$db_host" >/dev/null
  local mysql_conn_args=("${MYSQL_CONN_ARGS[@]}")

  local snap_dir
  snap_dir=$(restore_take_snapshot "$domain" "$siteroot" "$db_creds")
  log_info "$(_t "BACKUP_SITE_40" "${snap_dir}")"

  log_step "$(_t "BACKUP_SITE_41" "${domain}")"

  if [[ "$local_restore_file" == *.sql.gz || "$local_restore_file" == *.sql ]]; then
    # Pure DB Restore
    log_info "$(_t "BACKUP_SITE_42")"
    local db_restore_ok=0
    restore_import_sql "$local_restore_file" "$db_creds" && db_restore_ok=1

    if [[ "$db_restore_ok" -eq 0 ]]; then
      log_error "$(_t "BACKUP_SITE_43")"
      restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir"
      return 1
    fi
    log_success "$(_t "BACKUP_SITE_44")"
    if [[ -f "${siteroot}/wp-config.php" ]]; then
      restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "$local_restore_file" "$siteuser"
    fi

  elif [[ "$local_restore_file" == *.tar.gz ]]; then
    [[ -z "$restore_cache" ]] && restore_cache=$(mktemp -d "/tmp/clpRestore.XXXXXX")
    local unpack_dir="${restore_cache}/unpack_$(date +%s)"
    mkdir -p "$unpack_dir"
    log_info "$(_t "BACKUP_SITE_45")"
    if ! tar -xzf "$local_restore_file" -C "$unpack_dir"; then
      log_error "$(_t "BACKUP_SITE_46")"
      restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir"
      return 1
    fi

    # Identify source directory inside unpack
    local extracted_root="$unpack_dir"
    if [[ -d "${unpack_dir}/${domain}" ]]; then
      extracted_root="${unpack_dir}/${domain}"
    fi

    # Check for embedded SQL dump (only CLP's own dump at the archive root; never import
    # arbitrary .sql files that happen to be part of the site, e.g. old migration dumps)
    local embedded_sql="${extracted_root}/.clp_db_export.sql"
    if [[ -f "$embedded_sql" ]]; then
      log_step "$(_t "BACKUP_SITE_47")"
      local db_restore_ok=0
      restore_import_sql "$embedded_sql" "$db_creds" && db_restore_ok=1
      if [[ "$db_restore_ok" -eq 0 ]]; then
        log_error "$(_t "BACKUP_SITE_43")"
        restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir"
        return 1
      fi
      log_success "$(_t "BACKUP_SITE_48")"
      if [[ -f "${siteroot}/wp-config.php" && ! -f "${extracted_root}/wp-config.php" ]]; then
        restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "$embedded_sql" "$siteuser"
      fi
      rm -f "$embedded_sql"
    fi

    # Sync web files
    # 保留目前的 wp-config.php：資料庫已匯入目前 wp-config 指定的資料庫，若改用備份中的
    # wp-config（可能是舊主機或舊網站的 DB 帳密），網站會無法連線資料庫。
    # 備份中的版本另存於 root 專屬的快照目錄（不可放在網站根目錄，否則會被當成純文字公開）。
    local rsync_excludes=(--exclude='/.clp_db_export.sql')
    if [[ -f "${siteroot}/wp-config.php" && -f "${extracted_root}/wp-config.php" ]]; then
      rsync_excludes+=(--exclude='/wp-config.php')
      install -m 600 "${extracted_root}/wp-config.php" "${snap_dir}/wp-config.from-backup.php"
      log_info "$(_t "BACKUP_SITE_49" "${snap_dir}")"
      restore_sync_wp_table_prefix "${siteroot}/wp-config.php" "${extracted_root}/wp-config.php" "$siteuser"
    fi
    log_info "$(_t "BACKUP_SITE_50" "${siteroot}")"
    if ! rsync -a "${rsync_excludes[@]}" "${extracted_root}/" "${siteroot}/"; then
      log_error "$(_t "BACKUP_SITE_51")"
      restore_rollback "$domain" "$siteroot" "$siteuser" "$snap_dir"
      return 1
    fi
    rm -rf "$unpack_dir"

    # Fix ownership
    chown -R "${siteuser}:${siteuser}" "$siteroot"
    log_success "$(_t "BACKUP_SITE_52")"

    # Optimize PHP-FPM and reload Nginx
    local php_ver
    php_ver=$(find_site_php_version "$domain")
    optimize_site_php_fpm "$domain" "$php_ver" || log_warn "$(_t "BACKUP_SITE_53")"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  else
    log_error "$(_t "BACKUP_SITE_54" "${local_restore_file}")"
    return 1
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
  echo -e "$(_t "BACKUP_SITE_60" "${C_YELLOW}" "${selected_file}" "${C_NC}")"
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
    echo -e "$(_t "BACKUP_HANDLER_8")"
    echo -e "  sudo clp restore example.com"
    echo -e "  sudo clp restore example.com -file=example.com-db-20260921_120000.sql.gz"
    echo -e "  sudo clp restore example.com -to=google -type=full"
    return 1
  fi

  reject_extra_positionals raw_args "to|type|path|file|force|y|yes" "$domain" "restore" || return 1

  require_site_exists "$domain" "$(_t "BACKUP_HANDLER_21")" || return 1

  local r_file
  r_file=$(opt_get "file" "")
  local r_type
  r_type=$(opt_get "type" "")
  local r_to
  r_to=$(opt_get "to" "local")
  r_to="${r_to%:}"
  local r_path
  r_path=$(opt_get "path" "")
  local force_mode=0
  if has_opt "force"; then
    force_mode=1
  fi

  restore_site "$domain" "$r_file" "$r_type" "$r_to" "$r_path" "$force_mode"
}
