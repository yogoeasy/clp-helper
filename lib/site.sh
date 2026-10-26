#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - CloudPanel CLI Tool
# File: lib/site.sh
# Description: WordPress Site Management Module
#              Commands: -new, -list, -on, -off, -ssl, -clone-from, -migrate, delete
# ==============================================================================

# Ensure core and php-pm are loaded
if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  echo "Error: core library must be loaded first." >&2
  exit 1
fi

source "${CLP_ROOT_DIR}/lib/php_fpm.sh"
if [[ -f "${CLP_ROOT_DIR}/lib/cloudflare.sh" ]]; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/cloudflare.sh"
fi

# ------------------------------------------------------------------------------
# 1. Site Listing (clp site -list)
# ------------------------------------------------------------------------------
# _site_list_match_filter <filter> <status> <ssl>：網站是否符合 -list=<filter> 篩選條件（-raw 與表格輸出共用）
_site_list_match_filter() {
  local filter="${1,,}" status="$2" ssl="$3"
  case "$filter" in
    "") return 0 ;;
    enabled|main|wordpress|php|html) [[ "$status" == "Enabled" ]] ;;
    disabled) [[ "$status" == "Disabled" ]] ;;
    # CloudPanel 每個網站都有自簽憑證：只有受信任的憑證（Yes）才算有 SSL
    ssl) [[ "$ssl" == "Yes" ]] ;;
    nossl) [[ "$ssl" != "Yes" ]] ;;
    *) return 0 ;;
  esac
}

site_list() {
  local is_raw=0
  if has_opt "raw"; then
    is_raw=1
  fi

  if [[ $is_raw -eq 0 ]]; then
    log_step "$(_t "SITE_LIST_STEP_QUERY")"
  fi

  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  local enabled_dir="/etc/nginx/sites-enabled"
  local available_dir="/etc/nginx/sites-available"

  declare -A site_map=()
  declare -A user_map=()
  declare -A php_map=()
  declare -A ssl_map=()
  declare -A root_map=()

  # ------------------------------------------------------------------
  # 1. 優先從 CloudPanel SQLite 取得完整網站資料
  #    使用最簡單的單行查詢，避免 JOIN 失敗靜默返回空值
  # ------------------------------------------------------------------
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    # 基本網站資料（不做 JOIN，最保守寫法）
    local sqlite_out
    sqlite_out=$(sqlite3 -readonly "$clp_db" "SELECT domain_name,user,root_directory,type FROM site;" 2>/dev/null || true)
    while IFS='|' read -r db_domain db_user db_root db_type; do
      [[ -z "$db_domain" ]] && continue
      site_map["$db_domain"]="Enabled"
      [[ -n "$db_user"  ]] && user_map["$db_domain"]="$db_user"
      if [[ -n "$db_root" ]]; then
        if [[ "$db_root" =~ ^/ ]]; then
          root_map["$db_domain"]="$db_root"
        elif [[ -n "$db_user" ]]; then
          root_map["$db_domain"]="/home/${db_user}/htdocs/${db_root}"
        else
          root_map["$db_domain"]="$db_root"
        fi
      fi
      if [[ "$db_type" == "reverse-proxy" ]]; then
        php_map["$db_domain"]="proxy"
      else
        php_map["$db_domain"]="$(get_default_php_version)"  # 先給預設值，後續再由 php_settings 補充
      fi
    done <<< "$sqlite_out"

    # 嘗試補充 PHP 版本（CloudPanel 欄位為 php_version，部分版本可能為 version）
    local php_out
    php_out=$(sqlite3 -readonly "$clp_db" \
      "SELECT s.domain_name, ps.php_version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id;" \
      2>/dev/null || true)
    if [[ -z "$php_out" ]]; then
      php_out=$(sqlite3 -readonly "$clp_db" \
        "SELECT s.domain_name, ps.version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id;" \
        2>/dev/null || true)
    fi
    while IFS='|' read -r pd pv; do
      [[ -z "$pd" || -z "$pv" ]] && continue
      php_map["$pd"]="$pv"
    done <<< "$php_out"
  fi


  # ------------------------------------------------------------------
  # 2. 從 Nginx 設定檔名稱取得網站網域，補充或校正啟用/停用狀態
  #    (注意: 網站以設定檔名稱為主，不可從內部 server_name 提取 www 等別名/轉址)
  # ------------------------------------------------------------------
  local conf
  for conf in "$enabled_dir"/*.conf "$available_dir"/*.conf; do
    [[ -f "$conf" ]] || continue
    local conf_name
    conf_name=$(basename "$conf")
    [[ "$conf_name" == "default.conf" || "$conf_name" == "custom-domain.conf" ]] && continue

    local dom="${conf_name%.conf}"
    [[ "$dom" =~ ^[a-zA-Z0-9.-]+\.([a-zA-Z]{2,}|[xX][nN]--[a-zA-Z0-9-]{1,59})$ ]] || continue  # 與 is_valid_domain 相同，含 punycode TLD

    if [[ -f "$enabled_dir/${dom}.conf" ]]; then
      site_map["$dom"]="Enabled"
    elif [[ -f "$available_dir/${dom}.conf" ]]; then
      site_map["$dom"]="Disabled"
    fi
  done

  # ------------------------------------------------------------------
  # 3. 對仍缺資訊的網站，從 /home/*/htdocs/<domain> 補充
  # ------------------------------------------------------------------
  local dom
  for dom in "${!site_map[@]}"; do
    if [[ -z "${user_map[$dom]:-}" || -z "${root_map[$dom]:-}" ]]; then
      local htpath
      for htpath in /home/*/htdocs/"$dom"; do
        [[ -d "$htpath" ]] || continue
        local u
        u=$(stat -c '%U' "$htpath" 2>/dev/null \
            || ls -ld "$htpath" 2>/dev/null | awk '{print $3}' \
            || echo "unknown")
        user_map["$dom"]="$u"
        root_map["$dom"]="$htpath"
        break
      done
    fi
    [[ -z "${php_map[$dom]:-}" ]] && \
      php_map["$dom"]=$(find_site_php_version "$dom" 2>/dev/null || get_default_php_version)

    # SSL 狀態檢測 (區分已受信任的正式憑證 vs CloudPanel 預設自簽憑證)
    local crt_file="/etc/nginx/ssl-certificates/${dom}.crt"
    local le_cert="/etc/letsencrypt/live/${dom}/fullchain.pem"
    if [[ -f "$le_cert" || -L "$crt_file" ]]; then
      ssl_map["$dom"]="Yes"
    elif [[ -f "$crt_file" ]]; then
      local issuer
      issuer=$(openssl x509 -in "$crt_file" -noout -issuer 2>/dev/null || true)
      if [[ "$issuer" =~ "Let's Encrypt" || "$issuer" =~ "ZeroSSL" || "$issuer" =~ "Cloudflare" || "$issuer" =~ "Google" ]]; then
        ssl_map["$dom"]="Yes"
      elif [[ "$issuer" =~ "CN = ${dom}" || "$issuer" =~ "CN=${dom}" ]]; then
        ssl_map["$dom"]="Self-Signed"
      else
        ssl_map["$dom"]="Yes"
      fi
    else
      ssl_map["$dom"]="No"
    fi
  done

  # ------------------------------------------------------------------
  # 4. 如果三個來源都沒找到，用 /home/*/htdocs/* 全掃一遍
  # ------------------------------------------------------------------
  if [[ ${#site_map[@]} -eq 0 ]]; then
    [[ $is_raw -eq 0 ]] && log_warn "$(_t "SITE_LIST_WARN_FALLBACK_SCAN")"
    local htpath
    for htpath in /home/*/htdocs/*/; do
      [[ -d "$htpath" ]] || continue
      local dom
      dom=$(basename "$htpath")
      [[ "$dom" =~ \. ]] || continue
      local u
      u=$(stat -c '%U' "$htpath" 2>/dev/null || echo "unknown")
      site_map["$dom"]="Unknown"
      user_map["$dom"]="$u"
      root_map["$dom"]="$htpath"
      php_map["$dom"]=$(find_site_php_version "$dom" 2>/dev/null || get_default_php_version)
      ssl_map["$dom"]="No"
    done
  fi

  # ------------------------------------------------------------------
  # 5. 輸出
  # ------------------------------------------------------------------
  local list_filter
  list_filter=$(opt_get "list" "")
  [[ "$list_filter" == "true" || "$list_filter" == "all" || "$list_filter" == "1" ]] && list_filter=""

  local sorted_domains
  sorted_domains=$(printf '%s\n' "${!site_map[@]}" | sort)

  # 若指定 -raw，輸出純粹的網域名稱清單 (不含 ANSI 顏色、標題與表格，適合腳本迴圈呼叫)
  if [[ $is_raw -eq 1 ]]; then
    while IFS= read -r dom; do
      [[ -z "$dom" ]] && continue
      local status="${site_map[$dom]:-Unknown}"
      local ssl="${ssl_map[$dom]:-No}"
      _site_list_match_filter "$list_filter" "$status" "$ssl" || continue
      echo "$dom"
    done <<< "$sorted_domains"
    return 0
  fi

  local match_count=0
  local enabled_count=0 disabled_count=0

  echo ""
  printf "${C_BOLD}%-32s %-12s %-16s %-8s %-13s %s${C_NC}\n" \
    "DOMAIN" "STATUS" "USER" "PHP" "SSL" "WEB ROOT"
  echo "-----------------------------------------------------------------------------------------------------------"

  while IFS= read -r dom; do
    [[ -z "$dom" ]] && continue
    local status="${site_map[$dom]:-Unknown}"
    local user="${user_map[$dom]:-unknown}"
    local php="${php_map[$dom]:-?}"
    local ssl="${ssl_map[$dom]:-No}"
    local root="${root_map[$dom]:-}"

    # 套用篩選條件
    _site_list_match_filter "$list_filter" "$status" "$ssl" || continue

    match_count=$((match_count + 1))
    local status_color="${C_GREEN}"
    if [[ "$status" == "Disabled" ]]; then
      status_color="${C_RED}"
      disabled_count=$((disabled_count + 1))
    else
      enabled_count=$((enabled_count + 1))
    fi
    local ssl_color="${C_GREEN}"
    if [[ "$ssl" == "No" ]]; then
      ssl_color="${C_DIM}"
    elif [[ "$ssl" == "Self-Signed" ]]; then
      ssl_color="${C_YELLOW}"
    fi

    printf "%-32s ${status_color}%-12s${C_NC} %-16s %-8s ${ssl_color}%-13s${C_NC} %s\n" \
      "$dom" "$status" "$user" "$php" "$ssl" "$root"
  done <<< "$sorted_domains"

  echo "-----------------------------------------------------------------------------------------------------------"
  if [[ -n "$list_filter" ]]; then
    echo -e "${C_BOLD}$(_t "SITE_LIST_SUMMARY_FILTERED" "$match_count" "${#site_map[@]}" "$list_filter")${C_NC}"
  else
    echo -e "${C_BOLD}$(_t "SITE_LIST_SUMMARY_ALL" "${#site_map[@]}" "${C_GREEN}${enabled_count}${C_NC}" "${C_RED}${disabled_count}${C_NC}")${C_NC}"
  fi
  echo ""
}

# ------------------------------------------------------------------------------
# 2. Site On / Off (clp site <domain> -on / -off)
# ------------------------------------------------------------------------------
site_on() {
  local domain
  domain=$(clean_domain "$1")

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_ON_ERR_DOMAIN")"
    return 1
  fi

  require_site_exists "$domain" "$(_t "SITE_ON_STEP" "$domain")" || return 1

  local enabled_conf="/etc/nginx/sites-enabled/${domain}.conf"
  local available_conf="/etc/nginx/sites-available/${domain}.conf"

  if [[ -f "$enabled_conf" ]]; then
    log_warn "$(_t "SITE_ON_WARN_ALREADY_ON" "$domain")"
    return 0
  fi

  if [[ ! -f "$available_conf" ]]; then
    log_error "$(_t "SITE_ON_ERR_CONF_NOT_FOUND" "$available_conf")"
    return 1
  fi

  log_step "$(_t "SITE_ON_STEP" "$domain")"
  mv "$available_conf" "$enabled_conf"

  # 語法驗證
  if ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "SITE_ON_ERR_NGINX_FAIL")"
    mv -f "$enabled_conf" "$available_conf"
    nginx -t || true
    return 1
  fi

  # 重載 Nginx
  systemctl reload nginx 2>/dev/null || log_warn "$(_t "SITE_ON_WARN_RELOAD_FAIL")"
  log_success "$(_t "SITE_ON_SUCCESS" "$domain")"
  # PHP-FPM pool 固定值只在建立網站時套用；啟用／停用不改動使用者或 php-pm 調整過的值
  return 0
}

site_off() {
  local domain
  domain=$(clean_domain "$1")

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_OFF_ERR_DOMAIN")"
    return 1
  fi

  require_site_exists "$domain" "$(_t "SITE_OFF_STEP" "$domain")" || return 1

  local enabled_conf="/etc/nginx/sites-enabled/${domain}.conf"
  local available_conf="/etc/nginx/sites-available/${domain}.conf"

  if [[ -f "$available_conf" && ! -f "$enabled_conf" ]]; then
    log_warn "$(_t "SITE_OFF_WARN_ALREADY_OFF" "$domain")"
    return 0
  fi

  if [[ ! -f "$enabled_conf" ]]; then
    log_error "$(_t "SITE_OFF_ERR_CONF_NOT_FOUND" "$enabled_conf")"
    return 1
  fi

  mkdir -p "/etc/nginx/sites-available"
  log_step "$(_t "SITE_OFF_STEP" "$domain")"
  mv "$enabled_conf" "$available_conf"

  # 語法驗證
  if ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "SITE_OFF_ERR_NGINX_FAIL")"
    mv -f "$available_conf" "$enabled_conf"
    nginx -t || true
    return 1
  fi

  # 重載 Nginx
  systemctl reload nginx 2>/dev/null || log_warn "$(_t "SITE_OFF_WARN_RELOAD_FAIL")"
  log_success "$(_t "SITE_OFF_SUCCESS" "$domain")"
  return 0
}

# ------------------------------------------------------------------------------
# 3. Site Delete (clp site delete <domain> / clp site <domain> -delete)
# ------------------------------------------------------------------------------
site_delete() {
  local domain
  domain=$(clean_domain "$1")

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_DELETE_ERR_DOMAIN")"
    return 1
  fi

  # 檢查網站是否存在
  require_site_exists "$domain" "$(_t "SITE_DELETE_STEP" "$domain")" || return 1

  local enabled_conf="/etc/nginx/sites-enabled/${domain}.conf"
  local available_conf="/etc/nginx/sites-available/${domain}.conf"

  # 防呆確認
  local is_force=0
  if has_opt "force" || has_opt "y" || has_opt "yes" || has_opt "force-replace" || has_opt "force_replace" || [[ "${CLP_AUTO_YES:-false}" == "true" ]] || [[ "${2:-}" =~ ^--?(force|y|yes)$ ]]; then
    is_force=1
  fi

  if [[ $is_force -eq 0 ]]; then
    echo ""
    echo -e "${C_RED}${C_BOLD}$(_t "SITE_DELETE_WARN_PROMPT_1" "$domain")${C_NC}"
    echo -e "${C_RED}$(_t "SITE_DELETE_WARN_PROMPT_2")${C_NC}"
    # 非 TTY 且沒有 -y 時明確報錯；讀到 EOF（Ctrl-D）視為取消
    require_tty_or_yes || return 1
    local confirm_del=""
    read -r -p "$(_t "SITE_DELETE_PROMPT_CONFIRM")" confirm_del || confirm_del=""
    if [[ "$confirm_del" != "yes" && "$confirm_del" != "YES" ]]; then
      log_warn "$(_t "SITE_DELETE_WARN_CANCELLED")"
      return 0
    fi
  fi

  log_step "$(_t "SITE_DELETE_STEP" "$domain")"

  # 1. 查詢關聯資料庫與網站使用者 (必須在 clpctl site:delete 刪除 SQLite 記錄前查詢)
  #    僅採用 CloudPanel 資料庫中確實關聯到此網站的資料庫名稱；不可用 domain_to_dbname 推導，
  #    因為不同網域可能推導出相同名稱（例如 a.b.com 與 a-b.com），會誤刪其他網站的資料庫。
  local dbname=""
  local site_user
  site_user=$(find_site_user "$domain" 2>/dev/null || true)
  local clp_db="/home/clp/htdocs/app/data/db.sq3"
  if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local queried_db
    queried_db=$(sqlite3 -readonly "$clp_db" "SELECT d.name FROM \"database\" d JOIN site s ON d.site_id=s.id WHERE s.domain_name='$domain' LIMIT 1;" 2>/dev/null || true)
    [[ -n "$queried_db" ]] && dbname="$queried_db"
  fi

  # 2. 透過 CloudPanel 刪除網站
  if command -v clpctl >/dev/null 2>&1; then
    log_info "$(_t "SITE_DELETE_INFO_CLP" "$domain")"
    if ! clpctl site:delete --domainName="$domain" --force 2>&1; then
      # clpctl 失敗時，若 CloudPanel 資料庫仍有此網站，停止後續手動清理，
      # 避免面板仍列出網站、vhost 與憑證卻已被刪除的不一致狀態
      if [[ -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1 && \
         sqlite3 -readonly "$clp_db" "SELECT 1 FROM site WHERE domain_name='$domain' LIMIT 1;" 2>/dev/null | grep -q 1; then
        log_error "$(_t "SITE_DELETE_ERR_CLPCTL_FAILED" "$domain")"
        return 1
      fi
    fi

    # CloudPanel 的 site:delete 內部已自動刪除網站關聯的資料庫與使用者
    # 僅在資料庫仍殘留於系統時才嘗試獨立刪除，避免顯示 does not exist 誤導訊息
    if [[ -n "$dbname" && -f "$clp_db" ]] && command -v sqlite3 >/dev/null 2>&1; then
      if sqlite3 -readonly "$clp_db" "SELECT 1 FROM \"database\" WHERE name='$dbname' LIMIT 1;" 2>/dev/null | grep -q 1; then
        log_info "$(_t "SITE_DELETE_INFO_DB" "$dbname")"
        clpctl db:delete --databaseName="$dbname" 2>&1 || true
      fi
    fi
  fi

  # 3. 清理殘留檔案
  rm -f "$enabled_conf" "$available_conf"
  for pool in /etc/php/*/fpm/pool.d/"${domain}.conf"; do
    rm -f "$pool" 2>/dev/null || true
  done
  # 僅刪除此網域的憑證檔（萬用字元 ${domain}.* 會誤刪 example.com.au 等其他網域的憑證）
  rm -f "/etc/nginx/ssl-certificates/${domain}.crt" "/etc/nginx/ssl-certificates/${domain}.key" 2>/dev/null || true

  # 清理網站 Nginx 日誌目錄與 httpauth 安全設定
  # 不用 ${domain}-* 萬用字元：會吃到 example.com-shop.net 等其他網站的檔案
  rm -f "/var/log/nginx/${domain}.access.log" \
        "/var/log/nginx/${domain}.error.log" 2>/dev/null || true
  # 網站使用者目錄中的路徑可能被換成 symlink：任何一層是 symlink 就不刪
  if [[ -n "$site_user" && -d "/home/${site_user}/logs/${domain}" && \
        ! -L "/home/${site_user}" && ! -L "/home/${site_user}/logs" && ! -L "/home/${site_user}/logs/${domain}" ]]; then
    rm -rf "/home/${site_user}/logs/${domain}" 2>/dev/null || true
  fi
  # 清理 httpauth 相關設定
  rm -f "/etc/nginx/security/.htpasswd-${domain}" \
        "/etc/nginx/security/${domain}.whitelist" 2>/dev/null || true

  # 4. 重載服務
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  log_success "$(_t "SITE_DELETE_SUCCESS" "$domain")"
}

# ------------------------------------------------------------------------------
# 4. SSL Management (clp site <domain> -ssl=on|off)
# ------------------------------------------------------------------------------
remove_www() {
  local domain="$1"
  if [[ "$domain" =~ ^www\.(.+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$domain"
  fi
}

# certbot_cf_ini <ssl_domain> <token>：寫入 certbot 用的 Cloudflare 憑證檔，輸出路徑
#   固定位置 /root/.clp/cf-certbot/<網域>.ini（目錄 700、檔案 600）：certbot 會把這個路徑記在續期設定中，
#   每週續期時還要讀取，所以不可以用完就刪（舊版用暫存檔並在函式結束時刪除，造成續期失敗）。
certbot_cf_ini() {
  local ssl_domain="$1" token="$2"
  local dir="/root/.clp/cf-certbot"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 /root/.clp "$dir" 2>/dev/null || true
  local ini="${dir}/${ssl_domain}.ini" tmp
  tmp=$(umask 077; mktemp "${dir}/.cf.XXXXXX") || return 1
  if ! printf '# Generated by CLP Helper for certbot DNS-01 (used again on renewal; do not delete)\ndns_cloudflare_api_token = %s\n' "$token" > "$tmp" || \
     ! mv -f "$tmp" "$ini"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$ini"
  echo "$ini"
}

# _certbot_credentials_file <ssl_domain>：依 cf_resolve_credentials 的結果決定給 certbot 的憑證檔（輸出路徑）
#   找到的檔案含 certbot 讀得懂的 dns_cloudflare_api_token 鍵時直接使用；
#   否則（只有 token、純 token 檔、cloudflare_api_token 鍵）以 token 寫入固定的 certbot 憑證檔
_certbot_credentials_file() {
  local ssl_domain="$1"
  if [[ -n "$CF_RESOLVED_FILE" && -f "$CF_RESOLVED_FILE" ]] && \
     { grep -qE '^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=' "$CF_RESOLVED_FILE" 2>/dev/null || \
       cf_is_global_key_file "$CF_RESOLVED_FILE"; }; then
    log_info >&2 "$(_t "SITE_SSL_INFO_CF_MATCH" "$CF_RESOLVED_FILE" "$(basename "$CF_RESOLVED_FILE" .ini)")"
    echo "$CF_RESOLVED_FILE"
    return 0
  fi
  [[ -n "$CF_RESOLVED_TOKEN" ]] || return 1
  local ini
  ini="$(certbot_cf_ini "$ssl_domain" "$CF_RESOLVED_TOKEN")" || return 1
  log_info >&2 "$(_t "SITE_SSL_INFO_CF_TOKEN_RESOLVED" "$ini")"
  echo "$ini"
}

site_ssl() {
  local domain
  domain=$(clean_domain "$1")

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_SSL_ERR_DOMAIN_REQUIRED")"
    return 1
  fi

  require_site_exists "$domain" "$(_t "SITE_SSL_ACTION_DESC")" || return 1

  export CLP_CF_CREDENTIALS=""

  # 第二個參數可明確指定模式 (http | dns | off)；未指定時才依命令列參數判斷
  local ssl_mode="${2:-}"
  local ssl_action
  if [[ -n "$ssl_mode" ]]; then
    [[ "$ssl_mode" == "off" ]] && ssl_action="off" || ssl_action="on"
  else
    ssl_action=$(opt_get "ssl" "on")
    if has_opt "http" && ! has_opt "dns"; then
      ssl_mode="http"
    else
      ssl_mode="dns"
    fi
    # 與 site -new 一致：-ssl=no 是移除；-ssl=http／-ssl=dns 直接指定簽發方式
    case "$(printf '%s' "$ssl_action" | tr '[:upper:]' '[:lower:]')" in
      off|false|no) ssl_action="off" ;;
      http) ssl_action="on"; ssl_mode="http" ;;
      dns) ssl_action="on"; ssl_mode="dns" ;;
    esac
  fi

  if [[ "$ssl_action" == "off" || "$ssl_action" == "false" ]]; then
    log_step "$(_t "SITE_SSL_STEP_REMOVE" "${domain}")"
    # CloudPanel 的 vhost 固定引用 ssl-certificates/<domain>.crt/.key，直接刪除會讓 nginx 設定失效。
    # 改回 CloudPanel 建立網站時的自簽憑證：它一直保存在 CloudPanel 資料庫（certificate.type=1），
    # 寫回檔案即為初始狀態。不呼叫 clpctl：-dns 之後這兩個檔案是指向 /etc/letsencrypt 的 symlink，
    # clpctl 寫檔會跟隨 symlink 覆寫 Let's Encrypt 的憑證與私鑰。資料庫沒有該紀錄時才產生新的自簽憑證。
    local ssl_dir="/etc/nginx/ssl-certificates"
    local crt_path="${ssl_dir}/${domain}.crt"
    local key_path="${ssl_dir}/${domain}.key"
    local work_dir
    work_dir=$(mktemp -d)

    if ! ( umask 077; python3 -I - "/home/clp/htdocs/app/data/db.sq3" "$domain" "${work_dir}/selfsigned.crt" "${work_dir}/selfsigned.key" ) <<'PYEOF' 2>/dev/null
import sqlite3, sys
db, domain, crt_out, key_out = sys.argv[1:5]
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
row = con.execute(
    "SELECT c.certificate, c.private_key FROM certificate c JOIN site s ON s.id = c.site_id "
    "WHERE s.domain_name = ? AND c.type = 1 ORDER BY c.default_certificate DESC, c.id LIMIT 1",
    (domain,)).fetchone()
if not row or not row[0] or not row[1]:
    sys.exit(1)
for path, val in ((crt_out, row[0]), (key_out, row[1])):
    with open(path, "w") as f:
        f.write(val + "\n")  # 與 CloudPanel 寫出的檔案相同：資料庫內容再加一個換行
PYEOF
    then
      log_info "$(_t "SITE_SSL_INFO_SELFSIGNED_NEW" "${domain}")"
      if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
          -subj "/CN=${domain}" \
          -keyout "${work_dir}/selfsigned.key" -out "${work_dir}/selfsigned.crt" >/dev/null 2>&1; then
        rm -rf "$work_dir"
        log_error "$(_t "SITE_SSL_ERR_SELFSIGNED_FAILED" "${domain}")"
        return 1
      fi
    fi

    mkdir -p "$ssl_dir"
    [[ -e "$crt_path" || -L "$crt_path" ]] && cp -P "$crt_path" "${work_dir}/orig.crt"
    [[ -e "$key_path" || -L "$key_path" ]] && cp -P "$key_path" "${work_dir}/orig.key"

    # 先刪除（可能是 symlink），再寫入新檔，不會寫到 symlink 指向的位置
    rm -f "$crt_path" "$key_path"
    install -m 644 "${work_dir}/selfsigned.crt" "$crt_path"
    install -m 600 "${work_dir}/selfsigned.key" "$key_path"

    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
      rm -f "$crt_path" "$key_path"
      [[ -e "${work_dir}/orig.crt" || -L "${work_dir}/orig.crt" ]] && cp -P "${work_dir}/orig.crt" "$crt_path"
      [[ -e "${work_dir}/orig.key" || -L "${work_dir}/orig.key" ]] && cp -P "${work_dir}/orig.key" "$key_path"
      rm -rf "$work_dir"
      log_error "$(_t "SITE_SSL_ERR_SELFSIGNED_FAILED" "${domain}")"
      return 1
    fi
    rm -rf "$work_dir"
    systemctl reload nginx 2>/dev/null || true
    log_success "$(_t "SITE_SSL_SUCCESS_REMOVED" "${domain}")"
    return 0
  fi

  log_step "$(_t "SITE_SSL_STEP_START" "${domain}")"

  # 1. 原生 HTTP-01 驗證
  if [[ "$ssl_mode" == "http" ]]; then
    log_info "$(_t "SITE_SSL_INFO_NATIVE_HTTP")"
    if clpctl lets-encrypt:install:certificate --domainName="$domain"; then
      log_success "$(_t "SITE_SSL_SUCCESS_NATIVE")"
      return 0
    else
      local srv_ip
      srv_ip=$(get_server_ip 2>/dev/null || true)
      local ip_hint=""
      [[ -n "$srv_ip" ]] && ip_hint=" (${srv_ip})"
      log_warn "$(_t "SITE_SSL_WARN_NATIVE_FAILED" "${ip_hint}")"
      return 1
    fi
  fi

  # 2. 採用 Cloudflare DNS-01 憑證申請 (-dns 或預設)
  check_certbot || return 1
  ensure_certbot_renew_cron

  local ssl_domain
  ssl_domain=$(remove_www "$domain")

  local credentials_file=""

  local api_param
  api_param=$(opt_get "api" "")

  if [[ -n "$api_param" ]]; then
    if ! cf_resolve_credentials "$ssl_domain" "" "$api_param"; then
      if ! _resolve_cf_token_file "$api_param" >/dev/null 2>&1; then
        log_error "$(_t "SITE_SSL_ERR_API_FILE_NOT_FOUND" "$api_param")"
      fi
      return 1
    fi

    credentials_file="$(_certbot_credentials_file "$ssl_domain")" || {
      log_error "$(_t "SITE_SSL_ERR_API_FILE_NOT_FOUND" "$api_param")"
      return 1
    }
  else
    if cf_resolve_credentials "$ssl_domain" "" ""; then
      credentials_file="$(_certbot_credentials_file "$ssl_domain")" || credentials_file=""
    fi

    if [[ -z "$credentials_file" || ! -f "$credentials_file" ]]; then
      log_warn "$(_t "SITE_SSL_WARN_NO_CF_CREDS")"
      if command -v clpctl >/dev/null 2>&1; then
        clpctl lets-encrypt:install:certificate --domainName="$domain" || {
          log_warn "$(_t "SITE_SSL_WARN_NATIVE_RETRY_FAILED")"
          return 1
        }
        log_success "$(_t "SITE_SSL_SUCCESS_NATIVE")"
        return 0
      else
        log_error "$(_t "SITE_SSL_ERR_NO_TOOLS")"
        return 1
      fi
    fi
  fi

  local d_args=("-d" "$ssl_domain")
  local dot_count
  dot_count=$(tr -cd '.' <<< "$ssl_domain" | wc -c)
  # 根網域 (example.com，或 .com.tw / .co.uk / .idv.tw 等二級網域下的根網域) 同時申請 www；
  # 網站本身就是 www.<sub> 時也必須包含 www 主機名稱，否則憑證不涵蓋網站自己的網域
  if [[ $dot_count -eq 1 || ( "$ssl_domain" =~ \.(com|net|org|edu|gov|co|ac|or|ne|go|idv|ltd|plc|me)\.[a-z]{2}$ && $dot_count -eq 2 ) || "$domain" == "www.${ssl_domain}" ]]; then
    d_args+=("-d" "www.$ssl_domain")
    log_info "$(_t "SITE_SSL_INFO_REQ_MAIN" "${ssl_domain}" "${ssl_domain}")"
  else
    log_info "$(_t "SITE_SSL_INFO_REQ_SUB" "${ssl_domain}")"
  fi

  local email_param
  email_param=$(opt_get "email" "")
  local email_args=()
  if [[ -n "$email_param" ]]; then
    email_args=("--email" "$email_param")
  else
    email_args=("--register-unsafely-without-email")
  fi

  # --cert-name 固定 lineage 目錄名稱：網域清單變更時更新同一份憑證，
  # 避免 certbot 另建 example.com-0001 而 symlink 仍指向舊憑證
  certbot certonly \
    --non-interactive \
    --cert-name "$ssl_domain" \
    --keep-until-expiring \
    --agree-tos \
    "${email_args[@]}" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$credentials_file" \
    --dns-cloudflare-propagation-seconds 30 \
    "${d_args[@]}" || {
      log_warn "$(_t "SITE_SSL_WARN_CERTBOT_FAILED")"
      return 1
    }

  # 記錄本次使用的 Cloudflare 憑證路徑，供流程結尾之 DNS 指向檢查使用
  export CLP_CF_CREDENTIALS="$credentials_file"

  local ssl_key_le="/etc/letsencrypt/live/${ssl_domain}/privkey.pem"
  local ssl_cert_le="/etc/letsencrypt/live/${ssl_domain}/fullchain.pem"
  local clp_ssl_dir="/etc/nginx/ssl-certificates"
  local clp_key_path="${clp_ssl_dir}/${domain}.key"
  local clp_crt_path="${clp_ssl_dir}/${domain}.crt"

  mkdir -p "$clp_ssl_dir"

  # clpctl 寫檔會跟隨 symlink，重新簽發時會寫進 /etc/letsencrypt：先把既有的 symlink 原子地換成一般檔案的副本
  #   （同目錄暫存檔 + mv，過程中檔案一直存在，中斷也不會讓 nginx 找不到憑證）
  local cert_link tmp_copy
  for cert_link in "$clp_key_path" "$clp_crt_path"; do
    if [[ -L "$cert_link" ]]; then
      tmp_copy=$(mktemp "${clp_ssl_dir}/.clp-cert.XXXXXX") && cp -L "$cert_link" "$tmp_copy" && mv -f "$tmp_copy" "$cert_link" || rm -f "${tmp_copy:-}" "$cert_link"
    fi
  done

  # 安裝憑證至 CloudPanel（記錄到 CloudPanel 資料庫；之後再改為指向 Let's Encrypt 的 symlink）
  if command -v clpctl >/dev/null 2>&1; then
    clpctl site:install:certificate \
      --domainName="$domain" \
      --privateKey="$ssl_key_le" \
      --certificate="$ssl_cert_le" 2>/dev/null || true
  fi

  # 建立符號連結；nginx -t 失敗時放回原本的檔案（與 -ssl=off 相同），不顯示成功
  local orig_dir
  orig_dir=$(mktemp -d) || return 1
  if { [[ -e "$clp_crt_path" || -L "$clp_crt_path" ]] && ! cp -pP "$clp_crt_path" "${orig_dir}/orig.crt"; } || \
     { [[ -e "$clp_key_path" || -L "$clp_key_path" ]] && ! cp -pP "$clp_key_path" "${orig_dir}/orig.key"; }; then
    rm -rf "$orig_dir"
    log_error "$(_t "SITE_SSL_ERR_CERT_LINK" "${domain}")"
    return 1
  fi
  if ! ln -sf "$ssl_key_le" "$clp_key_path" || ! ln -sf "$ssl_cert_le" "$clp_crt_path"; then
    rm -f "$clp_crt_path" "$clp_key_path"
    [[ -e "${orig_dir}/orig.crt" || -L "${orig_dir}/orig.crt" ]] && cp -pP "${orig_dir}/orig.crt" "$clp_crt_path"
    [[ -e "${orig_dir}/orig.key" || -L "${orig_dir}/orig.key" ]] && cp -pP "${orig_dir}/orig.key" "$clp_key_path"
    rm -rf "$orig_dir"
    log_error "$(_t "SITE_SSL_ERR_CERT_LINK" "${domain}")"
    return 1
  fi

  if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
    rm -f "$clp_crt_path" "$clp_key_path"
    [[ -e "${orig_dir}/orig.crt" || -L "${orig_dir}/orig.crt" ]] && cp -pP "${orig_dir}/orig.crt" "$clp_crt_path"
    [[ -e "${orig_dir}/orig.key" || -L "${orig_dir}/orig.key" ]] && cp -pP "${orig_dir}/orig.key" "$clp_key_path"
    rm -rf "$orig_dir"
    log_error "$(_t "SITE_SSL_ERR_NGINX_TEST_RESTORED" "${domain}")"
    return 1
  fi
  rm -rf "$orig_dir"
  systemctl reload nginx 2>/dev/null || true
  log_success "$(_t "SITE_SSL_SUCCESS_CONFIGURED" "${domain}")"

  # 獨立呼叫 site_ssl 時，若使用 Cloudflare DNS 憑證，立即進行 DNS 設定檢查引導
  if [[ "${CLP_INTERNAL_SSL_CALL:-0}" -ne 1 && -n "${CLP_CF_CREDENTIALS:-}" ]]; then
    prompt_cloudflare_dns "$domain" "$CLP_CF_CREDENTIALS"
  fi

  return 0
}

# ------------------------------------------------------------------------------
# 4b. Cloudflare DNS Record Management & Verification (CF DNS-01 SSL 整合)
# ------------------------------------------------------------------------------

cf_parse_auth() {
  local cred_file="$1"
  CF_AUTH_HEADERS=()

  if [[ ! -f "$cred_file" ]]; then
    return 1
  fi

  local token="" email="" key=""
  # 最後一行沒有換行也要讀；值的處理與 _extract_token_from_file 相同（有引號取引號內，沒有引號去掉行內 # 註解）
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    k=$(echo "$k" | tr -d '[:space:]')
    v="${v#"${v%%[![:space:]]*}"}"
    if [[ "$v" == \"* ]]; then
      v="${v#\"}"; v="${v%%\"*}"
    elif [[ "$v" == \'* ]]; then
      v="${v#\'}"; v="${v%%\'*}"
    else
      v="${v%%#*}"
    fi
    v=$(echo "$v" | tr -d '[:space:]')
    case "$k" in
      "dns_cloudflare_api_token") token="$v" ;;
      "dns_cloudflare_email")     email="$v" ;;
      "dns_cloudflare_api_key")   key="$v" ;;
    esac
  done < "$cred_file"

  if [[ -n "$token" ]]; then
    CF_AUTH_HEADERS=("Authorization: Bearer ${token}")
    return 0
  elif [[ -n "$email" && -n "$key" ]]; then
    CF_AUTH_HEADERS=("X-Auth-Email: ${email}" "X-Auth-Key: ${key}")
    return 0
  fi

  return 1
}

cf_find_zone() {
  local domain="$1"

  # 1. 拆解候選 Zone (由長到短，例如: sub.deep.example.com -> sub.deep.example.com, deep.example.com, example.com)
  local parts=()
  IFS='.' read -ra parts <<< "$domain"
  local n=${#parts[@]}
  local candidates=()
  for ((i=0; i<n-1; i++)); do
    local cand=""
    for ((j=i; j<n; j++)); do
      cand="${cand}${parts[j]}."
    done
    candidates+=("${cand%.}")
  done

  # 2. 依序查詢候選 Zone
  for cand in "${candidates[@]}"; do
    local resp
    resp=$(curl -s4 -m 10 -X GET "https://api.cloudflare.com/client/v4/zones?name=${cand}&status=active" \
      -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
      -H "Content-Type: application/json" 2>/dev/null || true)

    local zid="" zname=""
    read -r zid zname < <(echo "$resp" | python3 -I -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('success') and data.get('result'):
        r = data['result'][0]
        print(f\"{r['id']} {r['name']}\")
except Exception:
    pass
" 2>/dev/null || true)

    if [[ -n "$zid" && -n "$zname" ]]; then
      echo "${zid}|${zname}"
      return 0
    fi
  done

  # 3. 備援：嘗試列出 token 權限下的所有 Zone 做最長字尾匹配
  local resp_all
  resp_all=$(curl -s4 -m 10 -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
    -H "Content-Type: application/json" 2>/dev/null || true)

  local zid="" zname=""
  read -r zid zname < <(echo "$resp_all" | CLP_DOMAIN="$domain" python3 -I -c '
import sys, json, os
dom = os.environ.get("CLP_DOMAIN", "").lower()
try:
    data = json.load(sys.stdin)
    if data.get("success") and data.get("result"):
        zones = sorted(data["result"], key=lambda z: len(z.get("name", "")), reverse=True)
        for z in zones:
            zn = z.get("name", "").lower()
            if dom == zn or dom.endswith("." + zn):
                print(z["id"], zn)
                sys.exit(0)
except Exception:
    pass
' 2>/dev/null || true)

  if [[ -n "$zid" && -n "$zname" ]]; then
    echo "${zid}|${zname}"
    return 0
  fi

  return 1
}

cf_get_dns_records() {
  local zone_id="$1"
  local target_domain="$2"

  local resp
  resp=$(curl -s4 -m 10 -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${target_domain}" \
    -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
    -H "Content-Type: application/json" 2>/dev/null || true)

  if [[ -z "$resp" ]]; then
    return 1
  fi

  # 僅輸出與網站相關的記錄 (A / AAAA / CNAME)；MX、TXT 等其他類型不列入，避免被當成主要記錄而遭覆寫。
  # API 回應失敗或無法解析時回傳 1，呼叫端必須中止，不可視為「尚無記錄」。
  echo "$resp" | python3 -I -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not d.get('success'):
    sys.exit(1)
for r in d.get('result', []):
    if r.get('type') not in ('A', 'AAAA', 'CNAME'):
        continue
    p = 'true' if r.get('proxied') else 'false'
    print(f\"{r.get('id')}\t{r.get('type')}\t{r.get('name')}\t{r.get('content')}\t{p}\t{r.get('ttl', 1)}\")
" 2>/dev/null
}

cf_create_record() {
  local zone_id="$1"
  local rec_type="$2"
  local rec_name="$3"
  local rec_content="$4"
  local rec_proxied="$5"

  local payload
  payload=$(python3 -I -c "
import sys, json
t, n, c, p = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4] == 'true')
print(json.dumps({'type': t, 'name': n, 'content': c, 'ttl': 1, 'proxied': p}))
" "$rec_type" "$rec_name" "$rec_content" "$rec_proxied")

  local resp
  resp=$(curl -s4 -m 10 -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true)

  local result
  result=$(echo "$resp" | python3 -I -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('success'):
        print('SUCCESS')
    else:
        errs = [e.get('message', 'unknown error') for e in d.get('errors', [])]
        print('ERROR: ' + ', '.join(errs))
except Exception as e:
    print(f'ERROR: invalid API response ({e})')
" 2>/dev/null || echo "ERROR: $(_t "SITE_CF_ERR_NETWORK")")

  echo "$result"
}

cf_update_record() {
  local zone_id="$1"
  local rec_id="$2"
  local rec_type="$3"
  local rec_name="$4"
  local rec_content="$5"
  local rec_proxied="$6"
  local orig_type="${7:-}"      # 原記錄類型/內容/代理狀態 (供備援失敗時還原)
  local orig_content="${8:-}"
  local orig_proxied="${9:-false}"

  local payload
  payload=$(python3 -I -c "
import sys, json
t, n, c, p = sys.argv[1], sys.argv[2], sys.argv[3], (sys.argv[4] == 'true')
print(json.dumps({'type': t, 'name': n, 'content': c, 'ttl': 1, 'proxied': p}))
" "$rec_type" "$rec_name" "$rec_content" "$rec_proxied")

  local resp
  resp=$(curl -s4 -m 10 -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rec_id}" \
    -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || true)

  local result
  result=$(echo "$resp" | python3 -I -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('success'):
        print('SUCCESS')
    else:
        errs = [e.get('message', 'unknown error') for e in d.get('errors', [])]
        print('ERROR: ' + ', '.join(errs))
except Exception as e:
    print(f'ERROR: invalid API response ({e})')
" 2>/dev/null || echo "ERROR: $(_t "SITE_CF_ERR_NETWORK")")

  # 若 PUT 失敗且記錄類型確實改變 (A <-> CNAME 轉換受阻)，備援：刪除舊記錄後重建；
  # 重建失敗時把原記錄建回去，避免記錄遺失
  if [[ "$result" =~ ^ERROR: && -n "$orig_type" && "$orig_type" != "$rec_type" ]]; then
    # CNAME 不能與同名稱的其他記錄並存（例如 AAAA）：這種情況重建一定失敗，不可先刪除原記錄
    if [[ "$rec_type" == "CNAME" ]]; then
      local others
      if ! others=$(cf_get_dns_records "$zone_id" "$rec_name") || \
         [[ -n "$(awk -F'\t' -v id="$rec_id" '$1 != id' <<< "$others")" ]]; then
        echo "${result} ($(_t "SITE_CF_ERR_CNAME_CONFLICT" "$rec_name"))"
        return 0
      fi
    fi
    local del_resp
    del_resp=$(curl -s4 -m 10 -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rec_id}" \
      -K <(curl_header_config "${CF_AUTH_HEADERS[@]}") \
      -H "Content-Type: application/json" 2>/dev/null || true)
    if echo "$del_resp" | grep -q -E '"success"[[:space:]]*:[[:space:]]*true'; then
      local recreate_res
      recreate_res=$(cf_create_record "$zone_id" "$rec_type" "$rec_name" "$rec_content" "$rec_proxied")
      if [[ "$recreate_res" == "SUCCESS" ]]; then
        echo "SUCCESS"
        return 0
      fi
      local restore_res
      restore_res=$(cf_create_record "$zone_id" "$orig_type" "$rec_name" "$orig_content" "$orig_proxied")
      if [[ "$restore_res" == "SUCCESS" ]]; then
        result="$(_t "SITE_UPDATE_RECORD_1" "${recreate_res}")"
      else
        result="$(_t "SITE_UPDATE_RECORD_2" "${recreate_res}" "${orig_type}" "${orig_content}")"
      fi
    fi
  fi

  echo "$result"
}

_cf_check_and_prompt_single_target() {
  local zone_id="$1"
  local zone_name="$2"
  local target="$3"
  local srv_ip="$4"
  local srv_hostname="${5:-}"

  log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_1" "${C_BOLD}" "${target}" "${C_NC}")"
  local records_raw
  if ! records_raw=$(cf_get_dns_records "$zone_id" "$target"); then
    log_error "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_2" "${target}")"
    return 1
  fi

  # 名稱上沒有 A / CNAME 記錄時視為「尚未建立」（可能只有 AAAA），改為新建記錄，不轉換其他類型的記錄
  if [[ -z "$(awk -F'\t' '$2 == "A" || $2 == "CNAME"' <<< "$records_raw")" ]]; then
    # --------------------------------------------------------------------------
    # 狀況 A: 尚未建立記錄 -> 詢問是否建立 (A or CNAME 與 value)
    # --------------------------------------------------------------------------
    log_warn "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_3" "${target}")"
    read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_4")" do_create || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
    do_create="${do_create:-y}"
    if [[ ! "$do_create" =~ ^[Yy]$ ]]; then
      log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_5" "${target}")"
      return 0
    fi

    echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_6")"
    echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_7" "${srv_ip:+: ${srv_ip}}")"
    if [[ -n "$srv_hostname" ]]; then
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_8" "${srv_hostname}")"
    else
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_9")"
    fi

    local def_type_choice="1"
    if has_opt "cname"; then
      def_type_choice="2"
    fi
    read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_10" "${def_type_choice}")" type_choice || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
    type_choice="${type_choice:-$def_type_choice}"

    local rec_type="A"
    local rec_val=""

    if [[ "$type_choice" == "2" ]]; then
      rec_type="CNAME"
      local def_cname=""
      if [[ -n "$srv_hostname" ]]; then
        def_cname="$srv_hostname"
      elif [[ "$target" == "www.${zone_name}" ]]; then
        def_cname="$zone_name"
      fi
      local prompt_hint=""
      [[ -n "$def_cname" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${def_cname}")"
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_12" "${prompt_hint}")" input_cname || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      rec_val="${input_cname:-$def_cname}"
      while [[ -z "$rec_val" ]]; do
        read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_13")" rec_val || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      done
    else
      rec_type="A"
      local prompt_hint=""
      [[ -n "$srv_ip" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${srv_ip}")"
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_14" "${prompt_hint}")" input_ip || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      rec_val="${input_ip:-$srv_ip}"
      while [[ -z "$rec_val" ]]; do
        read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_15")" rec_val || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      done
    fi

    # 詢問 Proxy 代理狀態
    read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_16")" input_proxy || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
    local rec_proxied="false"
    if [[ "$input_proxy" =~ ^[Yy]$ ]]; then
      rec_proxied="true"
    fi

    log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_17" "${rec_type}" "${target}" "${rec_val}" "${rec_proxied}")"
    local create_res
    create_res=$(cf_create_record "$zone_id" "$rec_type" "$target" "$rec_val" "$rec_proxied")

    if [[ "$create_res" == "SUCCESS" ]]; then
      local proxy_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_18")"
      [[ "$rec_proxied" == "true" ]] && proxy_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_19")"
      log_success "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_20" "${target}" "${rec_val}" "${rec_type}" "${proxy_badge}")"
    else
      log_error "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_21" "${create_res}")"
      return 1
    fi

  else
    # --------------------------------------------------------------------------
    # 狀況 B: 已建立記錄 -> 顯示現有內容並詢問是否修改
    # --------------------------------------------------------------------------
    log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_22")"

    local primary_id="" primary_type="" primary_content="" primary_proxied=""
    local has_aaaa=""

    while IFS=$'\t' read -r r_id r_type r_name r_content r_proxied r_ttl; do
      [[ -z "$r_id" ]] && continue
      local p_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_18")"
      [[ "$r_proxied" == "true" ]] && p_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_19")"
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_23" "${C_BOLD}" "${r_type}" "${C_NC}" "${C_BOLD}" "${r_content}" "${C_NC}" "${C_BOLD}" "${p_badge}" "${C_NC}")"

      if [[ "$r_type" == "A" && -z "$primary_id" ]]; then
        primary_id="$r_id"
        primary_type="$r_type"
        primary_content="$r_content"
        primary_proxied="$r_proxied"
      elif [[ "$r_type" == "CNAME" && -z "$primary_id" ]]; then
        primary_id="$r_id"
        primary_type="$r_type"
        primary_content="$r_content"
        primary_proxied="$r_proxied"
      elif [[ "$r_type" == "AAAA" ]]; then
        has_aaaa="$r_content"
      fi
    done <<< "$records_raw"

    if [[ -n "$has_aaaa" ]]; then
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_24" "${C_YELLOW}" "${has_aaaa}" "${C_NC}")"
    fi

    local is_pointing_here=0
    local cname_resolved_ip=""

    if [[ "$primary_type" == "A" && -n "$srv_ip" && "$primary_content" == "$srv_ip" ]]; then
      is_pointing_here=1
    elif [[ "$primary_type" == "CNAME" ]]; then
      # 若 CNAME 直接指向本主機名稱 (例如 server1.example.com)
      if [[ -n "$srv_hostname" && "$primary_content" == "$srv_hostname" ]]; then
        is_pointing_here=1
      elif [[ "$target" == "www.${zone_name}" && "$primary_content" == "$zone_name" ]]; then
        is_pointing_here=1
      else
        # 嘗試解析該 CNAME 指向的網址 IP，若解析出來為本機 IP，亦視為指向本伺服器
        cname_resolved_ip=$(python3 -I -c "import socket, sys; socket.setdefaulttimeout(2.0); print(socket.gethostbyname(sys.argv[1]))" "$primary_content" 2>/dev/null || true)
        if [[ -n "$srv_ip" && "$cname_resolved_ip" == "$srv_ip" ]]; then
          is_pointing_here=1
        fi
      fi
    fi

    local do_modify="n"
    if [[ $is_pointing_here -eq 1 ]]; then
      if [[ "$primary_type" == "CNAME" ]]; then
        if [[ -z "$cname_resolved_ip" ]]; then
          if [[ -n "$srv_hostname" && "$primary_content" == "$srv_hostname" && -n "$srv_ip" ]]; then
            cname_resolved_ip="$srv_ip"
          else
            cname_resolved_ip=$(python3 -I -c "import socket, sys; socket.setdefaulttimeout(2.0); print(socket.gethostbyname(sys.argv[1]))" "$primary_content" 2>/dev/null || true)
          fi
        fi
        log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_25" "${primary_content}" "${cname_resolved_ip:+ [${cname_resolved_ip}]}")"
      else
        log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_26" "${srv_ip}")"
      fi
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_27")" do_modify || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      do_modify="${do_modify:-n}"
    else
      local local_target=""
      if [[ -n "$srv_hostname" && -n "$srv_ip" ]]; then
        local_target="${srv_hostname} [${srv_ip}]"
      else
        local_target="${srv_hostname:-$srv_ip}"
      fi

      if [[ "$primary_type" == "CNAME" ]]; then
        if [[ -z "$cname_resolved_ip" ]]; then
          cname_resolved_ip=$(python3 -I -c "import socket, sys; socket.setdefaulttimeout(2.0); print(socket.gethostbyname(sys.argv[1]))" "$primary_content" 2>/dev/null || true)
        fi
        log_warn "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_28" "${primary_content}" "${cname_resolved_ip:+ [${cname_resolved_ip}]}" "${local_target}")"
      elif [[ -n "$srv_ip" ]]; then
        log_warn "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_29" "${primary_content}" "${local_target}")"
      else
        log_warn "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_30" "${primary_content}")"
      fi
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_31")" do_modify || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      do_modify="${do_modify:-y}"
    fi

    if [[ ! "$do_modify" =~ ^[Yy]$ ]]; then
      log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_32" "${target}")"
      return 0
    fi

    echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_33")"
    echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_7" "${srv_ip:+: ${srv_ip}}")"
    if [[ -n "$srv_hostname" ]]; then
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_8" "${srv_hostname}")"
    else
      echo -e "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_9")"
    fi
    local def_type_choice="1"
    if [[ "$primary_type" == "CNAME" ]] || has_opt "cname"; then
      def_type_choice="2"
    fi
    read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_10" "${def_type_choice}")" new_type_choice || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
    new_type_choice="${new_type_choice:-$def_type_choice}"

    local new_type="A"
    local new_val=""

    if [[ "$new_type_choice" == "2" ]]; then
      new_type="CNAME"
      local def_cname=""
      if [[ -n "$srv_hostname" ]]; then
        def_cname="$srv_hostname"
      elif [[ "$primary_type" == "CNAME" ]]; then
        def_cname="$primary_content"
      elif [[ "$target" == "www.${zone_name}" ]]; then
        def_cname="$zone_name"
      fi
      local prompt_hint=""
      [[ -n "$def_cname" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${def_cname}")"
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_12" "${prompt_hint}")" input_cname || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      new_val="${input_cname:-$def_cname}"
      while [[ -z "$new_val" ]]; do
        read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_13")" new_val || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      done
    else
      new_type="A"
      local def_ip="$srv_ip"
      [[ -z "$def_ip" && "$primary_type" == "A" ]] && def_ip="$primary_content"
      local prompt_hint=""
      [[ -n "$def_ip" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${def_ip}")"
      read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_14" "${prompt_hint}")" input_ip || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      new_val="${input_ip:-$def_ip}"
      while [[ -z "$new_val" ]]; do
        read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_15")" new_val || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
      done
    fi

    local def_proxy_char="N"
    [[ "$primary_proxied" == "true" ]] && def_proxy_char="Y"
    read -r -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_34" "${def_proxy_char}")" input_proxy || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 2; }
    local new_proxied="$primary_proxied"
    if [[ "$input_proxy" =~ ^[Yy]$ ]]; then
      new_proxied="true"
    elif [[ "$input_proxy" =~ ^[Nn]$ ]]; then
      new_proxied="false"
    fi

    log_info "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_35" "${new_type}" "${target}" "${new_val}" "${new_proxied}")"
    local update_res
    update_res=$(cf_update_record "$zone_id" "$primary_id" "$new_type" "$target" "$new_val" "$new_proxied" "$primary_type" "$primary_content" "$primary_proxied")

    if [[ "$update_res" == "SUCCESS" ]]; then
      local proxy_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_18")"
      [[ "$new_proxied" == "true" ]] && proxy_badge="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_19")"
      log_success "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_36" "${target}" "${new_val}" "${new_type}" "${proxy_badge}")"
    else
      log_error "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_37" "${update_res}")"
      return 1
    fi
  fi
}

prompt_cloudflare_dns() {
  local domain="$1"
  local cred_file="$2"

  if [[ -z "${CLP_TEST_MODE:-}" && ! -t 0 ]] || has_opt "no-cf-dns" || has_opt "skip-cf-dns"; then
    return 0
  fi

  if [[ ! -f "$cred_file" ]]; then
    return 0
  fi

  echo ""
  log_step "$(_t "SITE_CF_DNS_STEP_CHECK")"

  if ! cf_parse_auth "$cred_file"; then
    log_warn "$(_t "SITE_CF_DNS_WARN_NO_AUTH")"
    return 0
  fi

  log_info "$(_t "SITE_CF_DNS_INFO_QUERY_ZONES")"
  local zone_info
  # 查不到 zone（API 錯誤、權限不足、超過 50 個 zone）時回傳 1；不可讓 set -e 在顯示警告前結束整個指令
  zone_info=$(cf_find_zone "$domain") || zone_info=""

  if [[ -z "$zone_info" ]]; then
    log_warn "$(_t "SITE_CF_DNS_WARN_ZONE_NOT_FOUND" "${domain}")"
    return 0
  fi

  local zone_id zone_name
  IFS='|' read -r zone_id zone_name <<< "$zone_info"
  log_info "$(_t "SITE_CF_DNS_INFO_ZONE_FOUND" "${C_BOLD}${zone_name}${C_NC}" "${zone_id}")"

  local srv_ip
  srv_ip=$(get_server_ip 2>/dev/null || true)

  local srv_hostname
  srv_hostname=$(get_server_hostname 2>/dev/null || true)

  if [[ -n "$srv_ip" || -n "$srv_hostname" ]]; then
    local host_alias_label=""
    [[ -n "$srv_hostname" ]] && host_alias_label="$(_t "SITE_CF_DNS_LABEL_HOST_ALIAS" "$srv_hostname")"
    log_info "$(_t "SITE_CF_DNS_INFO_SERVER_TARGET" "${srv_ip:-$(_t "SITE_UNKNOWN")}" "$host_alias_label")"
  fi

  # 判斷要查詢的網址清單 (root domain + www 或 subdomain)
  local targets=()
  local clean_dom
  clean_dom=$(clean_domain "$domain")

  if [[ "$clean_dom" == "$zone_name" ]]; then
    # 根網域：查詢根網域與 www
    targets=("$zone_name" "www.${zone_name}")
  elif [[ "$clean_dom" == "www.${zone_name}" ]]; then
    # 以 www 建立之網站：查詢 www 與根網域
    targets=("www.${zone_name}" "$zone_name")
  else
    # 子網域 (如 test.yogapiece.org)
    targets=("$clean_dom")
  fi

  local total_targets=${#targets[@]}
  local idx=1 any_failed=0

  for target in "${targets[@]}"; do
    echo ""
    echo -e "${C_CYAN}----------------------------------------------------------------------${C_NC}"
    echo -e "${C_BOLD}$(_t "SITE_CF_DNS_BANNER_TARGET" "$idx" "$total_targets" "$target")${C_NC}"
    echo -e "${C_CYAN}----------------------------------------------------------------------${C_NC}"

    # 回傳 2：使用者在提示中按 Ctrl-D 取消，停止處理其餘目標
    local target_rc=0
    _cf_check_and_prompt_single_target "$zone_id" "$zone_name" "$target" "$srv_ip" "$srv_hostname" || target_rc=$?
    if [[ "$target_rc" -eq 2 ]]; then
      return 0
    elif [[ "$target_rc" -ne 0 ]]; then
      log_warn "$(_t "SITE_CF_DNS_WARN_TARGET_FAILED" "$target")"
      any_failed=1
    fi
    idx=$((idx + 1))
  done

  # 有目標失敗時不顯示「完成」（各目標已顯示警告）；呼叫端直接呼叫，維持回傳 0
  echo ""
  [[ "$any_failed" -eq 0 ]] && log_success "$(_t "SITE_CF_DNS_SUCCESS_COMPLETE")"
  return 0
}

# ------------------------------------------------------------------------------
# 4b. Site New Modular Plan Registry & Helpers
# ------------------------------------------------------------------------------
SITE_NEW_MODULES=(
  "wp_core"
  "php_fpm_tuning"
  "wp_hardening"
  "cache_plugin"
  "cf_dns"
  "cloudflare_waf"
)

init_site_modules_default() {
  set_site_mod_enabled "wp_core" "yes"
  set_site_mod_enabled "php_fpm_tuning" "yes"
  set_site_mod_enabled "wp_hardening" "yes"
  set_site_mod_enabled "cache_plugin" "yes"
  set_site_mod_enabled "cf_dns" "yes"
  if has_opt "cf-waf" || has_opt "cf_waf"; then
    set_site_mod_enabled "cloudflare_waf" "yes"
  else
    set_site_mod_enabled "cloudflare_waf" "no"
  fi
}

is_site_mod_enabled() {
  local mod="$1"
  local var="SITE_MOD_ENABLED_${mod}"
  [[ "${!var:-no}" == "yes" ]]
}

set_site_mod_enabled() {
  local mod="$1"
  local val="$2"
  local var="SITE_MOD_ENABLED_${mod}"
  printf -v "$var" '%s' "$val"
}

get_site_mod_desc() {
  local mod="$1"
  case "$mod" in
    wp_core)        _t "SITE_NEW_MOD_WP_CORE" ;;
    php_fpm_tuning) _t "SITE_NEW_MOD_PHP_FPM" ;;
    wp_hardening)   _t "SITE_NEW_MOD_WP_HARDENING" ;;
    cache_plugin)   _t "SITE_NEW_MOD_CACHE_PLUGIN" ;;
    cf_dns)         _t "SITE_NEW_MOD_CF_DNS" ;;
    cloudflare_waf) _t "SITE_NEW_MOD_CF_WAF" ;;
    *)              echo "$mod" ;;
  esac
}

# ------------------------------------------------------------------------------
# 5. Site New (clp site <domain> -new [-ssl=on|off] [-php=8.4] [-user=...])
# ------------------------------------------------------------------------------
site_new() {
  local domain
  domain=$(clean_domain "$1")

  # 1. 網域名稱驗證與輸入
  while [[ -z "$domain" ]] || ! is_valid_domain "$domain"; do
    if [[ -n "$domain" ]]; then
      log_error "$(_t "SITE_NEW_ERR_INVALID_DOMAIN")"
    fi
    read -p "$(_t "SITE_NEW_PROMPT_DOMAIN")" input_dom
    domain=$(clean_domain "$input_dom")
  done

  log_step "$(_t "SITE_NEW_STEP_START" "${domain}")"
  require_clp_db_server_ready || return 1

  # 2. 前置依賴檢查
  check_cloudpanel
  check_wpcli

  # 3. 檢查網站是否已存在
  #    -force-replace 的刪除延後到使用者確認建置計畫之後才執行，避免在選單中取消時網站已被刪除
  local site_root
  local replace_existing=0
  site_root=$(find_site_root "$domain" 2>/dev/null || true)
  if [[ -n "$site_root" && -d "$site_root" ]]; then
    if has_opt "force-replace" || has_opt "force_replace"; then
      replace_existing=1
    else
      log_error "$(_t "SITE_NEW_ERR_SITE_EXISTS" "${domain}")"
      log_info "$(_t "SITE_NEW_INFO_FORCE_HINT" "${domain}")"
      return 1
    fi
  fi

  # 4. 決定預設站台基本參數 (Site User, PHP, SSL)
  local default_user=""
  if (( replace_existing == 1 )); then
    default_user=$(find_site_user "$domain" 2>/dev/null || true)
  fi
  [[ -z "$default_user" ]] && default_user=$(suggest_site_user "$domain")
  local siteuser
  siteuser=$(opt_get "user" "$default_user")
  siteuser=$(echo "$siteuser" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]//g')

  local default_php
  default_php=$(get_default_php_version)
  local php_ver
  php_ver=$(opt_get "php" "$default_php")
  if ! get_installed_php_versions | grep -qxF "$php_ver"; then
    log_error "$(_t "SITE_ERR_PHP_NOT_INSTALLED" "$php_ver" "$(get_installed_php_versions | paste -sd ' ' -)")"
    return 1
  fi

  local default_wp_locale="en_US"
  if [[ "${CLP_CURRENT_LANG:-}" == "zh_TW" ]]; then
    default_wp_locale="zh_TW"
  fi
  local wp_locale
  wp_locale=$(opt_get "wplang" "")
  [[ -z "$wp_locale" ]] && wp_locale=$(opt_get "wp_lang" "")
  [[ -z "$wp_locale" ]] && wp_locale="$default_wp_locale"
  wp_locale=$(normalize_wp_locale "$wp_locale")

  local ssl_type="http"
  if has_opt "no-ssl" || has_opt "nossl" || [[ "$(opt_get "ssl" "on")" == "off" || "$(opt_get "ssl" "on")" == "false" ]]; then
    ssl_type="off"
  elif has_opt "http"; then
    ssl_type="http"
  elif has_opt "dns"; then
    ssl_type="dns"
  elif has_opt "ssl"; then
    local s_val
    s_val="$(opt_get "ssl" "http")"
    case "$s_val" in
      "dns"|"-dns") ssl_type="dns" ;;
      "off"|"false"|"no") ssl_type="off" ;;
      *) ssl_type="http" ;;
    esac
  fi

  # 5. WordPress 站台建置計畫互動選單 (比照 clp server install，一進來即顯示完整計畫)
  init_site_modules_default

  local non_interactive=false
  if has_opt "y" || has_opt "yes" || has_opt "non_interactive" || ! [[ -t 0 ]]; then
    non_interactive=true
  fi

  if [[ "$non_interactive" != "true" ]]; then
    while true; do
      echo ""
      echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
      echo -e " 🌐 $(_t "SITE_NEW_PLAN_TITLE" "${domain}")"
      echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
      echo "$(_t "SITE_NEW_PLAN_SUBTITLE")"
      echo ""
      local p_idx=1
      for smod in "${SITE_NEW_MODULES[@]}"; do
        local sym=" "
        local sym_col="${C_NC}"
        local tag=""

        if is_site_mod_enabled "$smod"; then
          sym="✔"
          sym_col="${C_GREEN}"
        fi

        if [[ "$smod" == "wp_core" || "$smod" == "php_fpm_tuning" ]]; then
          tag=" ${C_YELLOW}$(_t "SITE_NEW_PLAN_TAG_REQUIRED")${C_NC}"
        elif [[ "$smod" == "wp_hardening" || "$smod" == "cache_plugin" ]]; then
          tag=" ${C_CYAN}$(_t "SITE_NEW_PLAN_TAG_RECOMMENDED")${C_NC}"
        elif is_site_mod_enabled "$smod"; then
          tag=" ${C_GREEN}$(_t "SITE_NEW_PLAN_TAG_OPTIONAL")${C_NC}"
        else
          tag=" ${C_DIM}$(_t "SITE_NEW_PLAN_TAG_SKIPPED")${C_NC}"
        fi

        printf "  ${C_BOLD}%2d)${C_NC} [%b%s%b] %-18s %s%b\n" \
          "$p_idx" \
          "$sym_col" "$sym" "${C_NC}" \
          "$smod" \
          "$(get_site_mod_desc "$smod")" \
          "$tag"
        p_idx=$((p_idx + 1))
      done

      echo ""
      echo "----------------------------------------------------------------------"
      echo -e " $(_t "SITE_NEW_PLAN_CONFIG_BAR" "${C_BOLD}${siteuser}${C_NC}" "${C_BOLD}${php_ver}${C_NC}" "${C_BOLD}${wp_locale}${C_NC}" "${C_BOLD}${ssl_type}${C_NC}")"
      echo "----------------------------------------------------------------------"
      echo -e " $(_t "SITE_NEW_PLAN_FOOTER_HINT")"
      echo "----------------------------------------------------------------------"
      local choice=""
      read -r -p "$(echo -e "${C_CYAN}$(_t "SITE_NEW_PLAN_PROMPT")${C_NC}")" choice
      choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

      case "$choice" in
        ""|"y"|"yes"|"c"|"confirm")
          break
          ;;
        "q"|"quit"|"exit")
          log_info "$(_t "SITE_NEW_PLAN_CANCELLED")"
          return 0
          ;;
        "a"|"all")
          for smod in "${SITE_NEW_MODULES[@]}"; do
            set_site_mod_enabled "$smod" "yes"
          done
          ;;
        "m"|"min"|"minimal")
          for smod in "${SITE_NEW_MODULES[@]}"; do
            if [[ "$smod" != "wp_core" && "$smod" != "php_fpm_tuning" ]]; then
              set_site_mod_enabled "$smod" "no"
            fi
          done
          ;;
        "u"|"user")
          read -p "$(_t "SITE_NEW_PLAN_PROMPT_CHANGE_USER" "${siteuser}")" input_u
          input_u=$(echo "${input_u:-$siteuser}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]//g')
          if [[ -n "$input_u" ]]; then
            siteuser="$input_u"
          fi
          ;;
        "p"|"php")
          local avail_phps
          avail_phps=$(get_installed_php_versions | grep -E '^8\.' | head -n 5 | paste -sd '/' - | sed 's/\// \/ /g' || echo "8.5 / 8.4 / 8.3")
          read -p "$(_t "SITE_NEW_PLAN_PROMPT_CHANGE_PHP" "${avail_phps}" "${php_ver}")" input_p
          input_p=$(echo "${input_p:-$php_ver}" | tr -d '[:space:]')
          if [[ -n "$input_p" ]]; then
            if get_installed_php_versions | grep -qxF "$input_p"; then
              php_ver="$input_p"
            else
              log_warn "$(_t "SITE_ERR_PHP_NOT_INSTALLED" "$input_p" "$(get_installed_php_versions | paste -sd ' ' -)")"
              sleep 1.2
            fi
          fi
          ;;
        "l"|"lang"|"wplang"|"locale")
          read -p "$(_t "SITE_NEW_PLAN_PROMPT_CHANGE_LOCALE" "${wp_locale}")" input_l
          # 直接按 Enter 代表保留目前語系（normalize_wp_locale("") 會回傳 en_US）
          if [[ -n "${input_l// /}" ]]; then
            wp_locale=$(normalize_wp_locale "$input_l")
          fi
          ;;
        "s"|"ssl")
          read -p "$(_t "SITE_NEW_PLAN_PROMPT_CHANGE_SSL" "${ssl_type}")" input_s
          input_s=$(echo "${input_s:-$ssl_type}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
          case "$input_s" in
            "dns"|"-dns"|"2") ssl_type="dns" ;;
            "off"|"none"|"n"|"-ssl=off") ssl_type="off" ;;
            *) ssl_type="http" ;;
          esac
          ;;
        1|2)
          log_warn "$(_t "SITE_NEW_PLAN_CANT_TOGGLE_CORE")"
          sleep 1.2
          ;;
        *)
          [[ "$choice" =~ ^[0-9]{1,6}$ ]] && choice=$((10#$choice))  # 010 不可被當成八進位的 8
          if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 3 && choice <= ${#SITE_NEW_MODULES[@]} )); then
            local target_smod="${SITE_NEW_MODULES[$((choice-1))]}"
            if is_site_mod_enabled "$target_smod"; then
              set_site_mod_enabled "$target_smod" "no"
            else
              set_site_mod_enabled "$target_smod" "yes"
            fi
          else
            log_warn "$(_t "SITE_NEW_PLAN_INVALID_INPUT")"
            sleep 1.2
          fi
          ;;
      esac
    done
  fi

  # 5b. 建置計畫已確認，才刪除要被取代的既有網站
  if [[ "$replace_existing" -eq 1 ]]; then
    log_warn "$(_t "SITE_NEW_WARN_EXISTING_FORCE")"
    site_delete "$domain"
  fi

  # 6. 檢查 siteuser 是否已存在系統中 (/etc/passwd 衝突防護)
  while id -u "$siteuser" >/dev/null 2>&1; do
    log_error "$(_t "SITE_NEW_ERR_USER_EXISTS" "${siteuser}")"
    default_user=$(suggest_site_user "$domain")
    if [[ "$non_interactive" == "true" ]]; then
      # suggest_site_user 已回傳未使用、不超過 32 字元的名稱；不再加 _$RANDOM（可能超過 CloudPanel 的 32 字元上限）
      siteuser="$default_user"
      log_warn "$(_t "SITE_NEW_WARN_AUTO_USER" "${siteuser}")"
      continue
    fi
    read -p "$(_t "SITE_NEW_PROMPT_RETRY_USER" "${default_user}")" input_user
    siteuser="${input_user:-$default_user}"
    siteuser=$(echo "$siteuser" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]//g')
  done

  log_info "$(_t "SITE_NEW_INFO_SELECTED_USER" "${siteuser}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_PHP" "${php_ver}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_LOCALE" "${wp_locale}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_SSL" "${ssl_type}")"

  # 6a. -cf-waf 的值在建立網站之前檢查（原本到最後一步才報錯，網站已經建好）
  if has_opt "cf-waf" || has_opt "cf_waf"; then
    local cfw_val
    cfw_val="$(opt_get "cf_waf" "")"
    [[ -z "$cfw_val" ]] && cfw_val="$(opt_get "cf-waf" "")"
    case "${cfw_val,,}" in
      ""|true|on|status|off) ;;
      *) log_error "$(_t "SITE_CF_WAF_ERR_VALUE" "$cfw_val")"; return 1 ;;
    esac
  fi

  # 6b. WordPress 管理員 email：不使用第三方預設值（例如 wpadmin@wp.com 會收到密碼重設與錯誤通知）。
  #     以 -email= 指定，否則在終端機中詢問（即使有 -y）；沒有終端機又沒有 -email 時，在建立任何東西之前停止
  local wp_admin_email
  wp_admin_email=$(opt_get "email" "")
  if [[ -z "$wp_admin_email" || "$wp_admin_email" == "true" ]]; then
    wp_admin_email=""
    if [[ ! -t 0 ]]; then
      log_error "$(_t "SITE_NEW_ERR_EMAIL_REQUIRED")"
      return 1
    fi
    while true; do
      read -r -p "$(_t "SITE_NEW_PROMPT_ADMIN_EMAIL_REQUIRED")" wp_admin_email || { echo ""; log_warn "$(_t "CORE_PROMPT_CANCELLED")"; return 1; }
      [[ "$wp_admin_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
      log_warn "$(_t "SITE_NEW_WARN_EMAIL_INVALID")"
    done
  elif ! [[ "$wp_admin_email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    log_error "$(_t "SITE_NEW_WARN_EMAIL_INVALID")"
    return 1
  fi

  # 7. 建立資料庫名稱與密碼 (MySQL 32 字元限制處理)
  local dbname
  dbname=$(domain_to_dbname "$domain")
  local dbpass
  dbpass=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
  local siteuserpass="Clp_$(openssl rand -hex 6)!1"

  log_info "$(_t "SITE_NEW_INFO_TARGET_DB" "${dbname}")"

  # 8. 呼叫 CloudPanel 建立網站與資料庫
  log_step "$(_t "SITE_NEW_STEP_CREATE_SITE")"
  clpctl site:add:php \
    --domainName="$domain" \
    --phpVersion="$php_ver" \
    --vhostTemplate="WordPress" \
    --siteUser="$siteuser" \
    --siteUserPassword="$siteuserpass" || {
      log_error "$(_t "SITE_NEW_ERR_CREATE_SITE")"
      return 1
    }
  log_success "$(_t "SITE_NEW_SUCCESS_CREATE_SITE")"

  log_step "$(_t "SITE_NEW_STEP_CREATE_DB")"
  if ! clpctl db:add \
    --domainName="$domain" \
    --databaseName="$dbname" \
    --databaseUserName="$dbname" \
    --databaseUserPassword="$dbpass"; then
      log_error "$(_t "SITE_NEW_ERR_CREATE_DB")"
      clpctl site:delete --domainName="$domain" --force >/dev/null 2>&1 || true
      return 1
  fi
  log_success "$(_t "SITE_NEW_SUCCESS_CREATE_DB")"

  # 9. SSL 憑證配置
  local CLP_INTERNAL_SSL_CALL=1
  if [[ "$ssl_type" == "off" ]]; then
    log_info "$(_t "SITE_NEW_INFO_SKIP_SSL")"
  elif [[ "$ssl_type" == "http" ]]; then
    if ! site_ssl "$domain" "http"; then log_warn "$(_t "SITE_NEW_WARN_SSL_INCOMPLETE_HTTP" "${domain}")"; fi
  else
    if ! site_ssl "$domain" "dns"; then log_warn "$(_t "SITE_NEW_WARN_SSL_INCOMPLETE_DNS" "${domain}")"; fi
  fi

  # 9. WordPress 核心下載與安裝
  local wpdir="/home/${siteuser}/htdocs/${domain}"
  # 網站目錄中的檔案操作以網站使用者身分執行（root 不以路徑操作網站使用者可控制的目錄）
  sudo -H -u "$siteuser" mkdir -p -- "$wpdir"
  sudo -H -u "$siteuser" find "${wpdir:?}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true

  log_step "$(_t "SITE_NEW_STEP_WP_DOWNLOAD" "$wp_locale")"
  if [[ "$wp_locale" == "en_US" ]]; then
    if ! sudo -H -u "$siteuser" wp core download --force --path="$wpdir"; then
      log_error "$(_t "SITE_NEW_ERR_WP_DOWNLOAD")"
      return 1
    fi
  else
    if ! sudo -H -u "$siteuser" wp core download --locale="$wp_locale" --force --path="$wpdir" 2>/dev/null; then
      log_warn "$(_t "SITE_NEW_WARN_WP_DOWNLOAD_FALLBACK" "$wp_locale")"
      if ! sudo -H -u "$siteuser" wp core download --force --path="$wpdir"; then
        log_error "$(_t "SITE_NEW_ERR_WP_DOWNLOAD")"
        return 1
      fi
    fi
  fi
  log_success "$(_t "SITE_NEW_SUCCESS_WP_DOWNLOAD")"

  # 建立 wp-config.php (注意 CloudPanel 必須使用 127.0.0.1)
  log_step "$(_t "SITE_NEW_STEP_CREATE_CONFIG")"
  # 密碼由 stdin 傳入（--prompt），不出現在命令列（ps 看得到）
  printf '%s\n' "$dbpass" | sudo -H -u "$siteuser" wp config create \
    --dbname="$dbname" \
    --dbuser="$dbname" \
    --dbhost="127.0.0.1" \
    --prompt=dbpass \
    --path="$wpdir" >/dev/null || {
      log_error "$(_t "SITE_NEW_ERR_CREATE_CONFIG")"
      return 1
    }

  # 詢問管理員帳密 (若直接 Enter 預設為 wpadmin / 自動產生之強密碼)
  # 非互動模式 (-y 或無 TTY) 不詢問，直接採用預設值，避免 read 遇到 EOF 在 set -e 下中止
  echo ""
  log_step "$(_t "SITE_NEW_STEP_ADMIN_SETUP")"
  local input_admin_user="" input_admin_pass=""
  if [[ "$non_interactive" != "true" ]]; then
    read -r -p "$(_t "SITE_NEW_PROMPT_ADMIN_USER")" input_admin_user || true
  fi
  local wp_admin_user="${input_admin_user:-wpadmin}"

  local default_admin_pass="Clp_$(openssl rand -hex 8)!9"
  if [[ "$non_interactive" != "true" ]]; then
    echo -n "$(_t "SITE_NEW_PROMPT_ADMIN_PASS")"
    read -s -r input_admin_pass || true
    echo ""
  fi
  local wp_admin_pass="${input_admin_pass:-$default_admin_pass}"

  # wp_admin_email 已在建立網站之前決定（-email= 或詢問）

  # CloudPanel 的 vhost 一律將 http 轉址到 https（未申請憑證時使用自簽憑證），
  # 因此網站網址固定使用 https；改用 http 只會讓每個連結多一次轉址（已實機驗證）
  local site_scheme="https"

  # 自動產生的密碼不以明碼顯示於終端機 (AGENTS.md 安全規範)，改存於僅 root 可讀的檔案
  local admin_cred_file=""
  if [[ -z "$input_admin_pass" ]]; then
    mkdir -p /root/.clp && chmod 700 /root/.clp
    admin_cred_file="/root/.clp/${domain}-wp-admin.txt"
    ( umask 077; printf 'URL: %s://%s/wp-admin/\nUser: %s\nPassword: %s\n' "$site_scheme" "$domain" "$wp_admin_user" "$wp_admin_pass" > "$admin_cred_file" )
  fi

  log_step "$(_t "SITE_NEW_STEP_INSTALLING_CORE")"
  # 管理員密碼由 stdin 傳入（--prompt），不出現在命令列
  printf '%s\n' "$wp_admin_pass" | sudo -H -u "$siteuser" wp core install \
    --url="${site_scheme}://${domain}" \
    --title="New WordPress" \
    --admin_user="$wp_admin_user" \
    --admin_email="$wp_admin_email" \
    --skip-email \
    --prompt=admin_password \
    --path="$wpdir" || {
      # 嘗試以 http 協議安裝 (若尚未配置 SSL)
      printf '%s\n' "$wp_admin_pass" | sudo -H -u "$siteuser" wp core install \
        --url="http://${domain}" \
        --title="New WordPress" \
        --admin_user="$wp_admin_user" \
        --admin_email="$wp_admin_email" \
        --skip-email \
        --prompt=admin_password \
        --path="$wpdir" || {
          log_error "$(_t "SITE_NEW_ERR_INSTALL_CORE")"
          return 1
        }
    }
  log_success "$(_t "SITE_NEW_SUCCESS_INSTALL_CORE")"

  # 啟用目標語系套件 (若非 en_US)
  if [[ "$wp_locale" != "en_US" ]]; then
    sudo -H -u "$siteuser" wp language core install "$wp_locale" --activate --path="$wpdir" 2>/dev/null || true
  fi

  # 10. 客製化 wp-config.php (安全與效能常數、快取隔離)
  if is_site_mod_enabled "wp_hardening"; then
    log_step "$(_t "SITE_NEW_STEP_HARDENING_CONFIG")"
    if ! update_cloned_wpconfig "$wpdir" "$dbname" "$dbpass" "$domain" "$siteuser" "$wp_admin_email"; then
      log_error "$(_t "SITE_NEW_ERR_WPCONFIG_UPDATE")"
      return 1
    fi
    if [[ "$wp_locale" != "en_US" ]]; then
      sudo -H -u "$siteuser" wp config set WPLANG "$wp_locale" --type=constant --path="$wpdir" 2>/dev/null || true
    else
      sudo -H -u "$siteuser" wp config delete WPLANG --path="$wpdir" 2>/dev/null || true
    fi

    local wpconfig="${wpdir}/wp-config.php"
    if [[ -f "$wpconfig" ]]; then
      # 只把 DB_CHARSET 由 utf8 改為 utf8mb4（全域取代會把既有的 utf8mb4 變成 utf8mb4mb4）
      sudo -H -u "$siteuser" sed -i -E "s/(define\([[:space:]]*['\"]DB_CHARSET['\"][[:space:]]*,[[:space:]]*['\"])utf8(['\"])/\1utf8mb4\2/" "$wpconfig"
      if ! sudo -H -u "$siteuser" grep -q "WP_DEBUG_LOG" "$wpconfig"; then
        # 必須放在 require_once wp-settings.php 之前，WordPress 啟動後才定義的常數不會生效
        CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="$siteuser" python3 -I - "$wpconfig" <<'PYDEBUG'
import os, re, sys
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

path = sys.argv[1]
site_user = clp_fileops.get_required_site_user()
src = clp_fileops.read_text_nofollow(path)
block = """// CLP Debug Configuration
if ( ! defined( 'WP_DEBUG' ) ) {
    define( 'WP_DEBUG', false );
}
if ( WP_DEBUG ) {
    define( 'WP_DEBUG_LOG', true );
    define( 'WP_DEBUG_DISPLAY', false );
    @ini_set( 'display_errors', 0 );
}
"""
m = re.search(r"^/\*\s*That's all, stop editing.*$|^[ \t]*require_once[^\n]*wp-settings\.php[^\n]*$", src, re.M)
if m:
    src = src[:m.start()] + block + "\n" + src[m.start():]
else:
    src = src.rstrip("\n") + "\n\n" + block
clp_fileops.safe_atomic_write(path, src, user=site_user, allow_create=False)
PYDEBUG
      fi
    fi
  fi

  # 11. 安裝 CloudPanel 快取外掛
  if is_site_mod_enabled "cache_plugin"; then
    log_step "$(_t "SITE_NEW_STEP_INSTALL_CACHE_PLUGIN")"
    sudo -H -u "$siteuser" wp plugin install clp-varnish-cache --activate --path="$wpdir" 2>/dev/null || true
  fi

  # 校正目錄權限：只處理不屬於網站使用者的項目；find 不跟隨 symlink，-execdir 在檔案所在目錄執行（不以完整路徑解析中間目錄），
  # chown -h 不經由 symlink 修改
  if [[ -d "$wpdir" && ! -L "$wpdir" ]]; then
    find "$wpdir" -xdev \( ! -user "$siteuser" -o ! -group "$siteuser" \) -execdir chown -h "$siteuser:$siteuser" {} + 2>/dev/null || true
  fi

  # 12. PHP-FPM Pool 自動調校
  if is_site_mod_enabled "php_fpm_tuning"; then
    optimize_site_php_fpm "$domain" "$php_ver" || log_warn "$(_t "PHP_FPM_WARN_OPTIMIZE_SKIPPED")"
  fi

  # 13. 重載 Nginx 服務
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  # 14. 若 SSL 申請使用 Cloudflare DNS，於最後檢查並引導設定 DNS 指向
  if is_site_mod_enabled "cf_dns" && [[ -n "${CLP_CF_CREDENTIALS:-}" ]]; then
    prompt_cloudflare_dns "$domain" "$CLP_CF_CREDENTIALS"
  fi

  # 15. Cloudflare 邊緣 WAF 與安全防護配置整合 (僅在模組啟用時執行)
  if is_site_mod_enabled "cloudflare_waf"; then
    site_cf_waf "$domain" "$@" || true
  fi

  # 16. 建立完成總結報告 (i18n，不顯示 SFTP 帳密，密碼不以明碼顯示)
  echo ""
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e " 🎉 $(_t "SITE_NEW_SUCCESS_TITLE" "$domain")"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "  • $(_t "SITE_NEW_LABEL_URL"):       ${C_CYAN}${site_scheme}://${domain}${C_NC}"
  echo -e "  • $(_t "SITE_NEW_LABEL_ADMIN_URL"): ${C_CYAN}${site_scheme}://${domain}/wp-admin/${C_NC}"
  echo -e "  • $(_t "SITE_NEW_LABEL_ADMIN_USER"): ${C_BOLD}${wp_admin_user}${C_NC}"
  if [[ -n "$admin_cred_file" ]]; then
    echo -e "  • $(_t "SITE_NEW_LABEL_ADMIN_PASS"): ${C_YELLOW}$(_t "SITE_NEW_ADMIN_PASS_SAVED" "$admin_cred_file")${C_NC}"
  else
    echo -e "  • $(_t "SITE_NEW_LABEL_ADMIN_PASS"): ${C_YELLOW}********${C_NC}"
  fi
  echo -e "  • $(_t "SITE_NEW_LABEL_ADMIN_EMAIL"): ${C_BOLD}${wp_admin_email}${C_NC}"
  echo -e "  • $(_t "SITE_NEW_LABEL_PHP"):      ${C_BOLD}${php_ver}${C_NC}"
  echo -e "  • $(_t "SITE_NEW_LABEL_LOCALE"):   ${C_BOLD}${wp_locale}${C_NC}"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e " 🚀 $(_t "SITE_NEW_SUCCESS_FOOTER")"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo ""

  return 0
}

# ------------------------------------------------------------------------------
# 5b. 輔助函式：設定複製/搬移網站之 wp-config.php (參考 clp-new-wp.sh 客製化與快取隔離)
# ------------------------------------------------------------------------------
update_cloned_wpconfig() {
  local target_root="$1"
  local target_dbname="$2"
  local target_dbpass="$3"
  local target_domain="$4"
  local target_user="$5"
  local recovery_email="${6:-}"
  local mode="${7:-new}"   # new：site -new（加入強化常數）；clone：clone／migrate（不動 DISABLE_WP_CRON 等四個常數）
  local target_wpconfig="${target_root}/wp-config.php"

  if [[ ! -f "$target_wpconfig" ]]; then
    return 0
  fi

  log_info "$(_t "SITE_NEW_INFO_CONFIGURING_WPCONFIG")"

  local new_cache_salt
  new_cache_salt="${target_domain}:$(openssl rand -hex 8)"

  CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" CLP_WPCONFIG_MODE="$mode" CLP_DBPASS="$target_dbpass" python3 -I - "$target_wpconfig" "$target_domain" "$target_dbname" "$new_cache_salt" "$recovery_email" << 'PYEOF'
import os, sys, re
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

wpconfig_path = sys.argv[1]
target_domain = sys.argv[2]
target_dbname = sys.argv[3]
# 密碼以環境變數傳入，不出現在命令列（ps 看得到）
target_dbpass = os.environ.get("CLP_DBPASS", "")
new_cache_salt = sys.argv[4]
recovery_email = sys.argv[5] if len(sys.argv) > 5 else ""
site_user = clp_fileops.get_required_site_user()

try:
    content = clp_fileops.read_text_nofollow(wpconfig_path)

    # 1. 若先前曾有 define 語句被錯誤插入 docblock (/** ... */) 內，先行清理以還原註解結構
    def clean_docblock(match):
        lines = match.group(0).splitlines()
        cleaned = [l for l in lines if not re.match(r"^\s*define\s*\(", l)]
        return "\n".join(cleaned)

    # 只處理位於行首的 docblock（鹽值字串中的 /** 不是註解）
    content = re.sub(r"(?m)^[ \t]*/\*\*.*?\*/", clean_docblock, content, flags=re.DOTALL)

    # 2. 定義需設定或校正之常數 (常數名, 設定值, 是否為 raw PHP 代碼值)
    configs = [
        ("DB_NAME", target_dbname, False),
        ("DB_USER", target_dbname, False),
        ("DB_PASSWORD", target_dbpass, False),
        ("DB_HOST", "127.0.0.1", False),
        ("WP_HOME", f"https://{target_domain}", False),
        ("WP_SITEURL", f"https://{target_domain}", False),
        ("WP_CACHE_KEY_SALT", new_cache_salt, False),
    ]
    # 強化常數只在建立新網站時寫入；clone／migrate 保留來源網站原本的值（沒有就不加）
    if os.environ.get("CLP_WPCONFIG_MODE", "new") != "clone":
        configs += [
            ("DISABLE_WP_CRON", "true", True),
            ("WP_MEMORY_LIMIT", "512M", False),
            ("WP_POST_REVISIONS", "10", True),
            ("DISALLOW_FILE_EDIT", "true", True),
        ]

    if recovery_email:
        configs.append(("RECOVERY_MODE_EMAIL", recovery_email, False))

    if "WP_REDIS_PREFIX" in content:
        configs.append(("WP_REDIS_PREFIX", f"{target_domain}:", False))

    missing_defines = []
    for key, val, is_raw in configs:
        # PHP 單引號字串：跳脫反斜線與單引號（例如 o'neil@corp.com 或含反斜線的密碼）
        formatted_val = val if is_raw else "'" + val.replace("\\", "\\\\").replace("'", "\\'") + "'"
        new_line = f"define( '{key}', {formatted_val} );"
        # 行尾的 // 或 # 註解也算同一行（保留註解），否則會重複加入 define
        pattern = re.compile(
            # 值以 PHP 字串為單位比對：字串內的 ); 或 # 不可被當成結尾或註解（否則舊值的一部分會留在行尾）
            r"^[ \t]*define\s*\(\s*['\"]" + re.escape(key) + r"['\"]\s*,\s*"
            r"(?:'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"|[^'\";\n])*?"
            r"\)\s*;(?P<tail>[ \t]*(?://|#)[^\n]*)?[ \t]*$",
            re.MULTILINE
        )
        if pattern.search(content):
            content = pattern.sub(lambda m, nl=new_line: nl + (m.group("tail") or ""), content)
        else:
            missing_defines.append(new_line)

    # 3. 缺漏之常數統一乾淨插入於 <?php 之後、主註解區塊之前
    #    以字串切片插入（re.sub 的取代字串會解讀 \1、反斜線）；檔頭有 BOM 時 <?php 不在行首也找得到
    if missing_defines:
        block = "\n".join(missing_defines) + "\n"
        m = re.search(r"<\?php[^\n]*\n", content)
        if m:
            content = content[:m.end()] + block + "\n" + content[m.end():]
        elif "<?php" in content:
            i = content.index("<?php") + len("<?php")
            content = content[:i] + "\n" + block + "\n" + content[i:]
        else:
            content = "<?php\n" + block + "\n" + content

    clp_fileops.safe_atomic_write(wpconfig_path, content, user=site_user, allow_create=False)
except Exception as e:
    # 只印出錯誤細節；說明由 bash 端以語系訊息顯示
    print(f"  {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ------------------------------------------------------------------------------
# 5b. Update Cloned robots.txt Sitemap & Domain
# ------------------------------------------------------------------------------
update_cloned_robots_txt() {
  local target_root="$1"
  local source_domain="$2"
  local target_domain="$3"
  local target_user="${4:-}"

  local robots_file="${target_root}/robots.txt"
  [[ ! -f "$robots_file" ]] && return 0
  [[ "$source_domain" == "$target_domain" ]] && return 0

  local res="" rc=0
  res=$(CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" python3 -I - "$robots_file" "$source_domain" "$target_domain" << "PYEOF"
import sys, re, os
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

robots_path = sys.argv[1]
source_domain = sys.argv[2]
target_domain = sys.argv[3]
site_user = clp_fileops.get_required_site_user()

s_apex = re.sub(r"^www\.", "", source_domain, flags=re.IGNORECASE)

try:
    content = clp_fileops.read_text_nofollow(robots_path)

    pattern = re.compile(
        r"(?<![a-zA-Z0-9.-])(?:https?://)?(?:www\.)?" + re.escape(s_apex) + r"(?![a-zA-Z0-9.-])",
        re.IGNORECASE
    )

    if not pattern.search(content):
        sys.exit(0)

    def replacer(match):
        m = match.group(0)
        if m.lower().startswith("http"):
            return f"https://{target_domain}"
        else:
            return target_domain

    new_content = pattern.sub(replacer, content)

    if new_content != content:
        clp_fileops.safe_atomic_write(robots_path, new_content, user=site_user, allow_create=False)
        print("MODIFIED")
except Exception as e:
    sys.stderr.write(f"  {e}\n")
    sys.exit(1)
PYEOF
) || rc=$?

  if [[ $rc -ne 0 ]]; then
    log_warn "$(_t "SITE_WARN_UPDATE_ROBOTS_FAILED")"
    return 0
  fi

  if [[ "$res" == *"MODIFIED"* ]]; then
    log_success "$(_t "SITE_UPDATE_CLONED_ROBOTS_TXT_1" "${source_domain}" "${target_domain}")"
  fi
}

# ------------------------------------------------------------------------------
# 5c. Sanitize Cloned Environment Paths (.user.ini, Wordfence, Advanced-Cache)
# ------------------------------------------------------------------------------
sanitize_cloned_environment_paths() {
  local target_root="$1"
  local source_root="$2"
  local target_user="${3:-}"

  [[ ! -d "$target_root" ]] && return 0

  log_step "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_1")"

  # 1. 處理 .user.ini
  local user_ini="${target_root}/.user.ini"
  if [[ -f "$user_ini" ]]; then
    local wf_exists="0"
    [[ -f "${target_root}/wordfence-waf.php" ]] && wf_exists="1"

    if CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" python3 -I - "$user_ini" "$target_root" "$source_root" "$wf_exists" << "PYEOF"
import sys, re, os
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

user_ini = sys.argv[1]
target_root = sys.argv[2]
source_root = sys.argv[3] if len(sys.argv) > 3 else ""
wf_exists = (sys.argv[4] == "1") if len(sys.argv) > 4 else False
site_user = clp_fileops.get_required_site_user()

try:
    content = clp_fileops.read_text_nofollow(user_ini)

    lines = []
    modified = False
    for line in content.splitlines():
        # 只處理指向 Wordfence 的 auto_prepend_file；其他防火牆（例如 NinjaFirewall）或自訂檔案只更新路徑，保持啟用
        if re.match(r"^\s*auto_prepend_file\s*=", line) and "wordfence-waf.php" in line:
            if wf_exists:
                new_line = f"auto_prepend_file = '{target_root}/wordfence-waf.php'"
            else:
                new_line = f"; {line}  # auto-disabled by CLP Helper because file was missing"
            if new_line != line:
                modified = True
            lines.append(new_line)
        elif re.match(r"^\s*auto_prepend_file\s*=", line):
            # 其他 auto_prepend_file（例如 NinjaFirewall）：更新路徑；指向的檔案在新網站不存在時註解掉，避免每個請求都 PHP fatal
            if source_root and source_root in line:
                line = line.replace(source_root, target_root)
                modified = True
            m = re.match(r"""^\s*auto_prepend_file\s*=\s*["']?([^"';]+)""", line)
            if m and not os.path.exists(m.group(1).strip()):
                line = f"; {line}  # auto-disabled by CLP Helper because file was missing"
                modified = True
            lines.append(line)
        else:
            if source_root and source_root in line:
                line = line.replace(source_root, target_root)
                modified = True
            lines.append(line)

    if modified:
        clp_fileops.safe_atomic_write(user_ini, "\n".join(lines) + "\n", user=site_user, allow_create=False)
        print("USER_INI_MODIFIED")
except Exception as e:
    sys.stderr.write(f"  {e}\n")
    sys.exit(1)
PYEOF
    then
      log_success "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_2")"
    else
      log_warn "$(_t "SITE_WARN_UPDATE_USER_INI_FAILED")"
    fi
  fi

  # 2. 處理 wordfence-waf.php
  local wf_waf="${target_root}/wordfence-waf.php"
  if [[ -f "$wf_waf" ]]; then
    if CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" python3 -I - "$wf_waf" "$target_root" "$source_root" << "PYEOF"
import sys, re, os
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

wf_path = sys.argv[1]
target_root = sys.argv[2]
source_root = sys.argv[3] if len(sys.argv) > 3 else ""
site_user = clp_fileops.get_required_site_user()

try:
    content = clp_fileops.read_text_nofollow(wf_path)

    orig = content
    if source_root and source_root != target_root:
        content = content.replace(source_root, target_root)

    # 一般通用正規表達式：將所有指向 /wp-content/ 的絕對路徑開頭替換為目標站根目錄
    # 只改寫本機絕對路徑（以 / 開頭、不含 ://），網址 (https://cdn.example.com/wp-content/) 保持不變
    content = re.sub(r"(['\"])/(?![^'\"]*://)[^'\"]*?/wp-content/", lambda m: m.group(1) + target_root + "/wp-content/", content)

    if content != orig:
        clp_fileops.safe_atomic_write(wf_path, content, user=site_user, allow_create=False)
        print("WF_WAF_MODIFIED")
except Exception as e:
    sys.stderr.write(f"  {e}\n")
    sys.exit(1)
PYEOF
    then
      log_success "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_3")"
    else
      log_warn "$(_t "SITE_WARN_UPDATE_WORDFENCE_FAILED")"
    fi
  fi

  # 3. 清理 Wordfence 日誌快取 (避免讀取舊網站日誌與快取衝突)
  #    以網站使用者身分刪除，且不跟隨 symlink：wflogs 來自來源網站，可能是指向其他目錄的 symlink
  if [[ -n "$target_user" && -d "${target_root}/wp-content/wflogs" ]]; then
    sudo -H -u "$target_user" find "${target_root}/wp-content/wflogs" -mindepth 1 -maxdepth 1 ! -type d -delete 2>/dev/null || true
    log_info "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_4")"
  fi

  # 4. 處理 wp-content/advanced-cache.php (WP Rocket / W3TC / LiteSpeed 等寫死路徑)
  local adv_cache="${target_root}/wp-content/advanced-cache.php"
  if [[ -f "$adv_cache" ]]; then
    if CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" python3 -I - "$adv_cache" "$target_root" "$source_root" << "PYEOF"
import sys, re, os
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

adv_path = sys.argv[1]
target_root = sys.argv[2]
source_root = sys.argv[3] if len(sys.argv) > 3 else ""
site_user = clp_fileops.get_required_site_user()

try:
    content = clp_fileops.read_text_nofollow(adv_path)

    orig = content
    if source_root and source_root != target_root:
        content = content.replace(source_root, target_root)

    # 只改寫本機絕對路徑（以 / 開頭、不含 ://），網址 (https://cdn.example.com/wp-content/) 保持不變
    content = re.sub(r"(['\"])/(?![^'\"]*://)[^'\"]*?/wp-content/", lambda m: m.group(1) + target_root + "/wp-content/", content)

    if content != orig:
        clp_fileops.safe_atomic_write(adv_path, content, user=site_user, allow_create=False)
        print("ADV_CACHE_MODIFIED")
except Exception as e:
    sys.stderr.write(f"  {e}\n")
    sys.exit(1)
PYEOF
    then
      log_info "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_5")"
    else
      log_warn "$(_t "SITE_WARN_UPDATE_ADV_CACHE_FAILED")"
    fi
  fi
}

# ------------------------------------------------------------------------------
# 5b. 查詢與互動式檢視來源站 WordPress 線上登入使用者與文章編輯鎖定
# ------------------------------------------------------------------------------
# 內嵌 Python / PHP 顯示用的翻譯標籤，以 CLP_L_* 環境變數傳入（{n}、{ago} 等為佔位符）
_wp_session_label_env() {
  export CLP_L_AGO_SEC="$(_t "SITE_SESS_AGO_SEC")"
  export CLP_L_AGO_MIN="$(_t "SITE_SESS_AGO_MIN")"
  export CLP_L_AGO_HOUR="$(_t "SITE_SESS_AGO_HOUR")"
  export CLP_L_AGO_DAY="$(_t "SITE_SESS_AGO_DAY")"
  export CLP_L_NO_USERS="$(_t "SITE_SESS_NO_USERS")"
  export CLP_L_RECENT="$(_t "SITE_SESS_RECENT")"
  export CLP_L_TODAY="$(_t "SITE_SESS_TODAY")"
  export CLP_L_STALE="$(_t "SITE_SESS_STALE")"
  export CLP_L_UNKNOWN_IP="$(_t "SITE_SESS_UNKNOWN_IP")"
  export CLP_L_STATUS_LINE="$(_t "SITE_SESS_STATUS_LINE")"
  export CLP_L_EDITING="$(_t "SITE_SESS_EDITING")"
  export CLP_L_ROLE_COUNT="$(_t "SITE_SESS_ROLE_COUNT")"
  export CLP_L_TOTAL="$(_t "SITE_SESS_TOTAL")"
  export CLP_L_EDITING_WARN="$(_t "SITE_SESS_EDITING_WARN")"
  export CLP_L_UNTITLED="$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_2")"
}

render_wp_users_detail() {
  local json_data="$1"   # JSON 檔案路徑（資料可能很大，不可當成命令列參數）
  local target_role="${2:-all}"

  _wp_session_label_env
  if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$json_data" "$target_role" << "PYEOF"
import json, os, re, sys

# 來源網站的資料（文章標題、帳號、email、角色）可能含終端機控制字元，顯示前移除
def _clean(o):
    if isinstance(o, str):
        return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", o)
    if isinstance(o, list):
        return [_clean(x) for x in o]
    if isinstance(o, dict):
        return {_clean(k): _clean(v) for k, v in o.items()}
    return o

def L(key, default):
    return os.environ.get("CLP_L_" + key) or default

sample_json = open(sys.argv[1], encoding="utf-8", errors="replace").read()
filter_role = sys.argv[2] if len(sys.argv) > 2 else "all"

try:
    data = _clean(json.loads(sample_json))
except Exception:
    sys.exit(0)

def format_ago(sec):
    if sec < 60:
        return L("AGO_SEC", "{n} 秒前").replace("{n}", str(sec))
    elif sec < 3600:
        return L("AGO_MIN", "{n} 分鐘前").replace("{n}", str(sec // 60))
    elif sec < 86400:
        return L("AGO_HOUR", "{n} 小時前").replace("{n}", str(sec // 3600))
    else:
        return L("AGO_DAY", "{n} 天前").replace("{n}", str(sec // 86400))

users = [u for u in data.get("users", []) if filter_role == "all" or u.get("role") == filter_role]
if not users:
    print(L("NO_USERS", "  (此角色無登入使用者)"))
else:
    for u in users:
        role = u.get("role", "unknown")
        status = u.get("status", "idle")
        ago_str = format_ago(u.get("login_ago", 0))
        if status == "recent":
            st_badge = "\033[32m" + L("RECENT", "🟢 近期登入 ({ago})").replace("{ago}", ago_str) + "\033[0m"
        elif status == "today":
            st_badge = "\033[33m" + L("TODAY", "🟡 本日登入 ({ago})").replace("{ago}", ago_str) + "\033[0m"
        else:
            st_badge = "\033[90m" + L("STALE", "⚪ 長期留存 ({ago}，Remember-Me 憑證)").replace("{ago}", ago_str) + "\033[0m"
        
        ip = u.get("ip") or L("UNKNOWN_IP", "未知 IP")
        login = u.get("login", "")
        email = u.get("email", "")
        print(" • \033[1m" + login + "\033[0m (" + email + ") [" + role + "]")
        print(L("STATUS_LINE", "   - 狀態: {badge} | 登入 IP: {ip}").replace("{badge}", st_badge).replace("{ip}", ip))
        editing = u.get("editing", [])
        if editing:
            for ed in editing:
                diff_str = format_ago(ed.get("diff", 0))
                title = ed.get("title") or L("UNTITLED", "(無標題)")
                pid = str(ed.get("post_id", ""))
                msg = L("EDITING", "⚠️ 警告: 正在編輯文章「{title}」(ID: {id}，{diff}有心跳鎖定)")
                print("   - \033[31m\033[1m" + msg.replace("{title}", title).replace("{id}", pid).replace("{diff}", diff_str) + "\033[0m")
PYEOF
  elif command -v php >/dev/null 2>&1; then
    php -r '
function clp_clean($v) {
  if (is_string($v)) { return preg_replace("/[\\x{00}-\\x{1F}\\x{7F}-\\x{9F}]/u", "", $v); }
  if (is_array($v)) { $o = array(); foreach ($v as $k => $x) { $o[clp_clean($k)] = clp_clean($x); } return $o; }
  return $v;
}
$data = clp_clean(json_decode(file_get_contents($argv[1]), true));
$filter_role = isset($argv[2]) ? $argv[2] : "all";
function L($key, $default) { $v = getenv("CLP_L_" . $key); return ($v !== false && $v !== "") ? $v : $default; }
function format_ago($sec) {
  if ($sec < 60) return str_replace("{n}", $sec, L("AGO_SEC", "{n} 秒前"));
  if ($sec < 3600) return str_replace("{n}", floor($sec / 60), L("AGO_MIN", "{n} 分鐘前"));
  if ($sec < 86400) return str_replace("{n}", floor($sec / 3600), L("AGO_HOUR", "{n} 小時前"));
  return str_replace("{n}", floor($sec / 86400), L("AGO_DAY", "{n} 天前"));
}
$users = array();
foreach (($data["users"] ?? array()) as $u) {
  if ($filter_role === "all" || ($u["role"] ?? "") === $filter_role) {
    $users[] = $u;
  }
}
if (empty($users)) {
  echo L("NO_USERS", "  (此角色無登入使用者)") . "\n";
} else {
  foreach ($users as $u) {
    $role = $u["role"] ?? "unknown";
    $status = $u["status"] ?? "idle";
    $ago_str = format_ago($u["login_ago"] ?? 0);
    if ($status === "recent") {
      $st_badge = "\033[32m" . str_replace("{ago}", $ago_str, L("RECENT", "🟢 近期登入 ({ago})")) . "\033[0m";
    } elseif ($status === "today") {
      $st_badge = "\033[33m" . str_replace("{ago}", $ago_str, L("TODAY", "🟡 本日登入 ({ago})")) . "\033[0m";
    } else {
      $st_badge = "\033[90m" . str_replace("{ago}", $ago_str, L("STALE", "⚪ 長期留存 ({ago}，Remember-Me 憑證)")) . "\033[0m";
    }
    $ip = $u["ip"] ?: L("UNKNOWN_IP", "未知 IP");
    $login = $u["login"] ?? "";
    $email = $u["email"] ?? "";
    echo " • \033[1m" . $login . "\033[0m (" . $email . ") [" . $role . "]\n";
    echo str_replace(array("{badge}", "{ip}"), array($st_badge, $ip), L("STATUS_LINE", "   - 狀態: {badge} | 登入 IP: {ip}")) . "\n";
    foreach (($u["editing"] ?? array()) as $ed) {
      $diff_str = format_ago($ed["diff"] ?? 0);
      $title = (!empty($ed["title"])) ? $ed["title"] : L("UNTITLED", "(無標題)");
      $pid = $ed["post_id"] ?? "";
      echo "   - \033[31m\033[1m" . str_replace(array("{title}", "{id}", "{diff}"), array($title, $pid, $diff_str), L("EDITING", "⚠️ 警告: 正在編輯文章「{title}」(ID: {id}，{diff}有心跳鎖定)")) . "\033[0m\n";
    }
  }
}
' "$json_data" "$target_role"
  fi
}

prompt_wp_active_sessions() {
  local target_host="$1" # "local" or remote ssh host
  local domain="$2"
  local site_root="$3"
  local site_user="$4"

  # 1. 檢查是否為 WordPress 站點與 WP-CLI 可用性
  if [[ "$target_host" == "local" ]]; then
    if [[ ! -f "${site_root}/wp-config.php" ]] || ! command -v wp >/dev/null 2>&1; then
      return 0
    fi
  else
    if ! ssh -n "$target_host" "test -f '${site_root}/wp-config.php' && command -v wp >/dev/null 2>&1" 2>/dev/null; then
      return 0
    fi
  fi

  log_info "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_1" "${domain}")"

  local php_code='
$now = time();
global $wpdb;
$cap_key = $wpdb->get_blog_prefix() . "capabilities";
$users_data = $wpdb->get_results("
  SELECT u.ID, u.user_login, u.user_email, m_sess.meta_value AS sessions, m_cap.meta_value AS capabilities
  FROM {$wpdb->users} u
  JOIN {$wpdb->usermeta} m_sess ON u.ID = m_sess.user_id AND m_sess.meta_key = \"session_tokens\"
  LEFT JOIN {$wpdb->usermeta} m_cap ON u.ID = m_cap.user_id AND m_cap.meta_key = \"{$cap_key}\"
  WHERE m_sess.meta_value != \"\"
");
$recent_locks = array();
$locks = $wpdb->get_results("
  SELECT pm.post_id, pm.meta_value AS lock_val, p.post_title
  FROM {$wpdb->postmeta} pm
  JOIN {$wpdb->posts} p ON pm.post_id = p.ID
  WHERE pm.meta_key = \"_edit_lock\"
");
if (!empty($locks)) {
  foreach ($locks as $l) {
    $parts = explode(":", $l->lock_val);
    if (count($parts) >= 2) {
      $lock_time = (int)$parts[0];
      $lock_uid = (int)$parts[1];
      $diff = $now - $lock_time;
      if ($diff >= 0 && $diff <= 600) {
        $recent_locks[$lock_uid][] = array(
          "post_id" => $l->post_id,
          "title" => $l->post_title ? $l->post_title : "",
          "diff" => $diff
        );
      }
    }
  }
}
$active_users = array();
$role_counts = array();
if (!empty($users_data)) {
  foreach ($users_data as $u) {
    $sess_arr = maybe_unserialize($u->sessions);
    if (!is_array($sess_arr)) continue;
    $valid_sessions = array();
    foreach ($sess_arr as $s) {
      if (isset($s["expiration"]) && $s["expiration"] > $now) {
        $valid_sessions[] = $s;
      }
    }
    if (empty($valid_sessions)) continue;
    $latest_login = 0;
    $latest_ip = "";
    foreach ($valid_sessions as $s) {
      $login_ts = isset($s["login"]) ? (int)$s["login"] : 0;
      if ($login_ts >= $latest_login) {
        $latest_login = $login_ts;
        $latest_ip = isset($s["ip"]) ? $s["ip"] : "";
      }
    }
    $caps = maybe_unserialize($u->capabilities);
    $role = "subscriber";
    if (is_array($caps)) {
      foreach ($caps as $r => $enabled) {
        if ($enabled) {
          $role = $r;
          break;
        }
      }
    }
    if (!isset($role_counts[$role])) {
      $role_counts[$role] = 0;
    }
    $role_counts[$role]++;
    $diff_login = $now - $latest_login;
    if ($diff_login <= 3600) {
      $status = "recent";
    } elseif ($diff_login <= 86400) {
      $status = "today";
    } else {
      $status = "idle";
    }
    $uid = (int)$u->ID;
    $active_users[] = array(
      "id" => $uid,
      "login" => $u->user_login,
      "email" => $u->user_email,
      "role" => $role,
      "login_time" => $latest_login,
      "login_ago" => $diff_login,
      "ip" => $latest_ip,
      "status" => $status,
      "editing" => isset($recent_locks[$uid]) ? $recent_locks[$uid] : array()
    );
  }
}
echo "CLP_JSON_START" . json_encode(array(
  "total" => count($active_users),
  "roles" => $role_counts,
  "users" => $active_users
)) . "CLP_JSON_END";
'

  local b64_code
  b64_code=$(echo "$php_code" | base64 | tr -d '\n')

  local cmd_out=""
  if [[ "$target_host" == "local" ]]; then
    local decoded_php
    decoded_php=$(echo "$b64_code" | base64 --decode 2>/dev/null || echo "$b64_code" | base64 -d)
    cmd_out=$(sudo -H -u "$site_user" wp eval "$decoded_php" --skip-plugins --skip-themes --path="$site_root" 2>/dev/null || true)
  else
    cmd_out=$(ssh -n "$target_host" "sudo -H -u '${site_user}' wp eval \"\$(echo '${b64_code}' | base64 -d)\" --skip-plugins --skip-themes --path='${site_root}'" 2>/dev/null || true)
  fi

  # JSON 寫到 root 專屬的暫存檔再傳路徑：使用者很多時 JSON 會超過單一命令列參數的長度上限（約 128KB），
  # 原本以參數傳入時會失敗並被當成「沒有登入中的使用者」
  local json_data
  json_data=$(umask 077; mktemp "/tmp/clp-wp-sessions.XXXXXX") || return 0
  trap '[[ -n "${json_data:-}" ]] && rm -f "$json_data"; trap - RETURN' RETURN
  sed -n 's/.*CLP_JSON_START\(.*\)CLP_JSON_END.*/\1/p' <<< "$cmd_out" > "$json_data"

  if [[ ! -s "$json_data" ]]; then
    return 0
  fi

  local total_users=0
  if command -v python3 >/dev/null 2>&1; then
    total_users=$(python3 -I -c "import json, sys; print(json.load(open(sys.argv[1])).get('total', 0))" "$json_data" 2>/dev/null || echo 0)
  elif command -v php >/dev/null 2>&1; then
    total_users=$(php -r '$d=json_decode(file_get_contents($argv[1]),true); echo $d["total"] ?? 0;' "$json_data" 2>/dev/null || echo 0)
  fi

  if [[ "$total_users" -eq 0 ]]; then
    log_info "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_3" "${domain}")"
    return 0
  fi

  # 顯示統計摘要
  echo ""
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_4" "${C_CYAN}" "${C_BOLD}" "${domain}" "${C_NC}")"
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"

  _wp_session_label_env
  if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$json_data" << "PYEOF"
import json, os, re, sys

# 來源網站的資料（文章標題、帳號、email、角色）可能含終端機控制字元，顯示前移除
def _clean(o):
    if isinstance(o, str):
        return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", o)
    if isinstance(o, list):
        return [_clean(x) for x in o]
    if isinstance(o, dict):
        return {_clean(k): _clean(v) for k, v in o.items()}
    return o

def L(key, default):
    return os.environ.get("CLP_L_" + key) or default

data = _clean(json.load(open(sys.argv[1], encoding="utf-8", errors="replace")))
roles = data.get("roles", {})
for r, cnt in roles.items():
    print(L("ROLE_COUNT", "   • {role} : {count} 位").replace("{role}", f"{r:<15}").replace("{count}", str(cnt)))
print(L("TOTAL", "   (總計 {total} 位使用者有效 Session 登入中)").replace("{total}", str(data.get("total", 0))))
editing_count = sum(1 for u in data.get("users", []) if u.get("editing"))
if editing_count > 0:
    warn = L("EDITING_WARN", "⚠️  注意: 偵測到 {count} 位使用者在近 10 分鐘內有文章編輯心跳鎖定！").replace("{count}", str(editing_count))
    print("\n   \033[31m\033[1m" + warn + "\033[0m")
PYEOF
  elif command -v php >/dev/null 2>&1; then
    php -r '
function clp_clean($v) {
  if (is_string($v)) { return preg_replace("/[\\x{00}-\\x{1F}\\x{7F}-\\x{9F}]/u", "", $v); }
  if (is_array($v)) { $o = array(); foreach ($v as $k => $x) { $o[clp_clean($k)] = clp_clean($x); } return $o; }
  return $v;
}
$d = clp_clean(json_decode(file_get_contents($argv[1]), true));
function L($key, $default) { $v = getenv("CLP_L_" . $key); return ($v !== false && $v !== "") ? $v : $default; }
foreach (($d["roles"] ?? array()) as $r => $cnt) {
    echo str_replace(array("{role}", "{count}"), array(sprintf("%-15s", $r), (int)$cnt), L("ROLE_COUNT", "   • {role} : {count} 位")) . "\n";
}
echo str_replace("{total}", (int)($d["total"] ?? 0), L("TOTAL", "   (總計 {total} 位使用者有效 Session 登入中)")) . "\n";
$editing_count = 0;
foreach (($d["users"] ?? array()) as $u) {
    if (!empty($u["editing"])) $editing_count++;
}
if ($editing_count > 0) {
    echo "\n   \033[31m\033[1m" . str_replace("{count}", $editing_count, L("EDITING_WARN", "⚠️  注意: 偵測到 {count} 位使用者在近 10 分鐘內有文章編輯心跳鎖定！")) . "\033[0m\n";
}
' "$json_data"
  fi
  echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
  echo ""

  # 若為 --force 或 --force-replace 或 -y 模式，印出摘要後不阻擋執行
  if has_opt "force" || has_opt "force-replace" || has_opt "force_replace" || has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]]; then
    return 0
  fi

  # 取得角色清單供選單建立
  # 一次解析出「角色<TAB>人數」，選單重繪時不再每個角色各啟動一次直譯器（角色名稱也不再嵌入程式碼）
  local roles=() role_counts=() role_lines="" r_name r_cnt
  if command -v python3 >/dev/null 2>&1; then
    role_lines="$(python3 -I -c "import json, sys; d=json.load(open(sys.argv[1])); [print(f'{k}\t{v}') for k, v in d.get('roles', {}).items()]" "$json_data" 2>/dev/null || true)"
  elif command -v php >/dev/null 2>&1; then
    role_lines="$(php -r '$d=json_decode(file_get_contents($argv[1]),true); foreach (($d["roles"] ?? array()) as $k => $v) { echo $k . "\t" . $v . "\n"; }' "$json_data" 2>/dev/null || true)"
  fi
  while IFS=$'\t' read -r r_name r_cnt; do
    [[ -z "$r_name" ]] && continue
    roles+=("$r_name")
    role_counts+=("${r_cnt:-0}")
  done <<< "$role_lines"

  if [[ ! -t 0 ]]; then
    log_error "$(_t "SITE_ERR_NON_INTERACTIVE_REQUIRES_YES")"
    return 1
  fi

  while true; do
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_5")"
    local idx=1 ri
    for ri in "${!roles[@]}"; do
      echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_6" "$idx" "$(strip_ctrl_chars "${roles[ri]}")" "$(strip_ctrl_chars "${role_counts[ri]}")")"
      idx=$((idx + 1))
    done
    local all_idx=$idx
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_7" "${all_idx}")"
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_8")"
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_9")"
    echo ""
    # 讀到 EOF（Ctrl-D）視為取消（q），不可當成「繼續」
    read -r -p "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_10" "${all_idx}")" user_choice || user_choice="q"
    user_choice="${user_choice:-0}"

    case "$user_choice" in
      0)
        break
        ;;
      q|Q)
        log_warn "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_11")"
        return 1
        ;;
      "$all_idx")
        echo ""
        echo -e "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_12" "${C_BOLD}" "${C_NC}")"
        render_wp_users_detail "$json_data" "all"
        echo ""
        ;;
      *)
        [[ "$user_choice" =~ ^[0-9]{1,6}$ ]] && user_choice=$((10#$user_choice))  # 010 不可被當成八進位的 8
        if [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ "$user_choice" -ge 1 && "$user_choice" -lt "$all_idx" ]]; then
          local selected_role="${roles[$((user_choice - 1))]}"
          echo ""
          echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_13" "${C_BOLD}" "$(strip_ctrl_chars "$selected_role")" "${C_NC}")"
          render_wp_users_detail "$json_data" "$selected_role"
          echo ""
        else
          echo -e "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_14" "${C_YELLOW}" "${C_NC}")"
        fi
        ;;
    esac
  done

  return 0
}

# ------------------------------------------------------------------------------
# 6. Site Clone (clp site -clone-from=<domain1> <domain2>)
# ------------------------------------------------------------------------------
# _site_db_import <db_name> <db_pass> <sql_file> <root_msg_key>：clone／migrate 匯入資料庫
#   SQL 內容由來源網站使用者（clone 以 wp db export 匯出，會載入其 wp-config.php）或遠端主機（migrate）決定，不可信任：
#   預設只用新網站自己的 DB 帳號；加上 -db-root 才改用 MySQL root 重試（規則同 backup／restore 的 -db-root：
#   連 CloudPanel 的 MySQL master，名稱限英數字開頭、其後為英數字／底線／-）
#   --no-defaults：不讀 /root/.my.cnf（其中的密碼優先於 MYSQL_PWD）
#   mysql 的錯誤訊息會引用 SQL 片段（內容不可信任）：ERROR 行移除控制字元、截斷後以 log_warn 顯示並寫入 log
_site_db_import() {
  local db_name="$1" db_pass="$2" sql_file="$3" root_msg_key="$4"
  local err_file rc=0
  err_file=$(mktemp) || return 1
  MYSQL_PWD="${db_pass}" mysql --no-defaults -h"127.0.0.1" -u"${db_name}" "${db_name}" < "$sql_file" 2>"$err_file" || rc=$?
  if [[ $rc -eq 0 ]]; then
    rm -f "$err_file"
    return 0
  fi
  _site_db_import_show_err "$err_file"
  if ! has_opt "db-root" && ! has_opt "db_root"; then
    rm -f "$err_file"
    log_warn "$(_t "SITE_DB_IMPORT_HINT_ROOT")"
    return 1
  fi
  local master_host master_port master_pass
  if [[ "$db_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    read -r master_host master_port <<< "$(get_mysql_master_host_port)"
  fi
  if ! [[ "${master_host:-}" =~ ^[A-Za-z0-9.:_-]+$ && "${master_port:-}" =~ ^[0-9]+$ ]]; then
    rm -f "$err_file"
    return 1
  fi
  master_pass=$(get_mysql_master_pass)
  if [[ -z "$master_pass" ]]; then
    rm -f "$err_file"
    return 1
  fi
  log_warn "$(_t "$root_msg_key")"
  rc=0
  MYSQL_PWD="${master_pass}" mysql --no-defaults -h"${master_host}" -P"${master_port}" -uroot "${db_name}" < "$sql_file" 2>"$err_file" || rc=$?
  [[ $rc -ne 0 ]] && _site_db_import_show_err "$err_file"
  rm -f "$err_file"
  return "$rc"
}

# _site_db_import_show_err <err_file>：顯示 mysql 的 ERROR 行（最後 3 行，每行最多 300 字元）
#   MariaDB 會在 ERROR 前印出失敗的整段 SQL（可能含資料內容），不顯示也不寫入 log
_site_db_import_show_err() {
  local line
  [[ -s "$1" ]] || return 0
  while IFS= read -r line; do
    line=$(strip_ctrl_chars "$line")
    log_warn "$(_t "SITE_DB_IMPORT_ERR_LINE" "${line:0:300}")"
  done < <(grep -E '^ERROR' "$1" | tail -n 3)
}

# _wp_replace_domain <site_user> <site_root> <source_domain> <target_domain> [<source_root>]
#   以 WP-CLI 替換資料庫中的網址與網站路徑（規則參考 UpdraftPlus 的遷移，計畫 52）；任何一次失敗回傳 1
#   - 只替換網址形式：http://、https://、//、JSON 跳脫的 \/\/，各含 www. 與不含 www.；裸網域與 email 不動
#   - www.來源 一律換成不含 www 的目標；http:// 與 https:// 都換成 https://目標（clp 寫入 wp-config.php 的 WP_HOME 固定為 https，
#     clone 也要求先有 SSL）；protocol-relative 與 JSON 保留原本的寫法
#   - 來源網域取 CloudPanel 的網域與資料庫中 home／siteurl 的主機（去掉 www.，長的先換，避免短的以前綴比對到長的）
#   - 先換成佔位字串，最後再換成目標：目標以來源開頭時（example.com → example.com.tw）後面的規則不會再比對到前面的結果
#   - 網站絕對路徑（<source_root> → <site_root>）一併替換；posts.guid 不替換
_wp_replace_domain() {
  local u="$1" root="$2" src="$3" dst="$4" src_root="${5:-}" rc=0 i h url host
  local -a wpsr=(search-replace --all-tables --skip-plugins --skip-themes --precise --skip-columns=guid --report-changed-only --path="$root")

  # 來源網站的 home／siteurl（clone／migrate 時目標資料庫仍是來源的內容）。直接查資料庫：
  # wp-config.php 的 WP_HOME／WP_SITEURL（clp 已改成目標網域）會讓 wp option get 讀到常數
  local -a hosts=("${src#www.}") urls=()
  local prefix
  prefix="$(sudo -H -u "$u" wp db prefix --skip-plugins --skip-themes --path="$root" 2>/dev/null || true)"
  if [[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]]; then
    mapfile -t urls < <(sudo -H -u "$u" wp db query \
      "SELECT option_value FROM ${prefix}options WHERE option_name IN ('home','siteurl') ORDER BY option_name='siteurl'" \
      --skip-column-names --skip-plugins --skip-themes --path="$root" 2>/dev/null || true)
  fi
  for url in "${urls[@]}"; do
    if [[ "$url" =~ ^https?://([^/:?#]+) ]]; then
      host="${BASH_REMATCH[1],,}"
      host="${host#www.}"
      [[ " ${hosts[*]} " == *" ${host} "* ]] || hosts+=("$host")
    fi
  done
  if [[ "${#hosts[@]}" -gt 1 ]]; then
    mapfile -t hosts < <(printf '%s\n' "${hosts[@]}" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
  fi

  local ph="clp-replace-${RANDOM}${RANDOM}.invalid"
  local -a from=() to=()
  for h in "${hosts[@]}"; do
    for i in "www.${h}" "$h"; do
      from+=("https://${i}" "http://${i}" "//${i}" '\/\/'"${i}")
      to+=("https://${ph}" "https://${ph}" "//${ph}" '\/\/'"${ph}")
    done
  done
  for i in "${!from[@]}"; do
    sudo -H -u "$u" wp "${wpsr[@]}" "${from[$i]}" "${to[$i]}" 2>&1 || rc=1
  done
  # 最後把佔位主機換成目標；失敗時資料庫中會留下佔位字串，明確告知以便手動處理
  if ! sudo -H -u "$u" wp "${wpsr[@]}" "$ph" "$dst" 2>&1; then
    log_error "$(_t "SITE_ERR_REPLACE_PLACEHOLDER_LEFT" "$ph" "$dst" "$ph" "$dst")"
    rc=1
  fi
  _wp_replace_path "$u" "$root" "$src_root" || rc=1
  return "$rc"
}

# _wp_replace_path <site_user> <site_root> <source_root>：資料庫中的網站絕對路徑換成新路徑（外掛存的檔案路徑）；
#   路徑相同或沒有來源路徑時不做事；失敗回傳 1
#   來源路徑必須是 CloudPanel 的網站路徑（/home/<使用者>/htdocs/<網域>），避免過短的路徑（例如 /home）換掉不相關的字串
_wp_replace_path() {
  local u="$1" root="$2" src_root="${3%/}" rc=0
  [[ -n "$src_root" && "$src_root" != "$root" ]] || return 0
  [[ "$src_root" =~ ^/home/[A-Za-z0-9._-]+/htdocs/[A-Za-z0-9.-]+$ ]] || return 0
  local -a wpsr=(search-replace --all-tables --skip-plugins --skip-themes --precise --skip-columns=guid --report-changed-only --path="$root")
  sudo -H -u "$u" wp "${wpsr[@]}" "$src_root" "$root" 2>&1 || rc=1
  # JSON 跳脫的路徑（\/home\/<使用者>\/…）
  sudo -H -u "$u" wp "${wpsr[@]}" "${src_root//\//\\/}" "${root//\//\\/}" 2>&1 || rc=1
  return "$rc"
}

# php_version_installed <版本>：本機是否安裝了該版本的 PHP-FPM（CloudPanel 建站需要）
php_version_installed() {
  get_installed_php_versions | grep -qxF "$1"
}

# replace_user_available <使用者> <要被取代的網站>：使用者名稱可否用於新網站
#   尚未存在，或正是即將被 -force-replace 刪除的那個網站的使用者（刪除時會一併移除）
replace_user_available() {
  local user="$1" replaced="${2:-}"
  id -u "$user" >/dev/null 2>&1 || return 0
  [[ -n "$replaced" && "$(find_site_user "$replaced" 2>/dev/null || true)" == "$user" ]]
}

site_clone() {
  local source_domain
  source_domain=$(clean_domain "$(opt_get 'clone_from' "$(opt_get 'clone-from')")")

  local target_domain=""
  for pos in "${POSITIONAL[@]}"; do
    local clean_pos
    clean_pos=$(clean_domain "$pos")
    if [[ "$clean_pos" != "$source_domain" && "$clean_pos" != "site" ]]; then
      target_domain="$clean_pos"
      break
    fi
  done

  if [[ -z "$source_domain" || -z "$target_domain" ]]; then
    log_error "$(_t "SITE_CLONE_1")"
    return 1
  fi

  if ! is_valid_domain "$target_domain"; then
    log_error "$(_t "SITE_CLONE_2" "${target_domain}")"
    return 1
  fi

  if [[ "$source_domain" == "$target_domain" ]]; then
    log_error "$(_t "SITE_CLONE_3" "${source_domain}")"
    return 1
  fi

  log_step "$(_t "SITE_CLONE_4" "${source_domain}" "${target_domain}")"
  require_clp_db_server_ready || return 1
  # 留存的資料庫備份寫入 clp config 的 backup-dir；先讀取，設定不合法時在建立任何東西之前停止
  local backup_dir
  backup_dir="$(config_get_valid BACKUP_DIR)" || return 1

  # 1. 檢查來源站是否存在
  require_site_exists "$source_domain" "$(_t "SITE_CLONE_5")" || return 1
  local source_root
  source_root=$(find_site_root "$source_domain" 2>/dev/null || true)
  if [[ -z "$source_root" || ! -d "$source_root" ]]; then
    log_error "$(_t "SITE_CLONE_6" "${source_domain}")"
    return 1
  fi

  local source_user
  source_user=$(find_site_user "$source_domain" 2>/dev/null || echo "wpuser")

  # 1a. 檢查來源站線上登入使用者狀態
  prompt_wp_active_sessions "local" "$source_domain" "$source_root" "$source_user" || return 1

  # 2. 檢查目標站是否已存在
  local target_root
  target_root=$(find_site_root "$target_domain" 2>/dev/null || true)
  # -force-replace 的刪除延後到所有檢查與來源資料庫匯出完成之後，避免檢查失敗時目標網站已被刪除
  local replace_target=""
  if site_exists "$target_domain" || [[ -n "$target_root" && -d "$target_root" ]]; then
    if has_opt "force-replace" || has_opt "force_replace"; then
      replace_target="$target_domain"
    else
      log_error "$(_t "SITE_CLONE_8" "${target_domain}")"
      return 1
    fi
  fi

  # 3. 取得來源站擁有者與決定目標站 Site User (CloudPanel 要求每個網站必須擁有獨立且尚未存在於 /etc/passwd 的使用者)

  local target_user replaced_user=""
  target_user=$(opt_get "user" "")
  if [[ -n "$target_user" ]]; then
    target_user=$(echo "$target_user" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    if ! replace_user_available "$target_user" "$replace_target"; then
      log_error "$(_t "SITE_CLONE_9" "${target_user}")"
      return 1
    fi
  elif [[ -n "$replace_target" ]] && replaced_user=$(find_site_user "$replace_target" 2>/dev/null) && [[ -n "$replaced_user" ]]; then
    # 取代既有網站時沿用它的使用者（刪除時會一併移除，再由新網站建立）
    target_user="$replaced_user"
  else
    target_user=$(suggest_site_user "$target_domain")
  fi
  log_info "$(_t "SITE_CLONE_10" "${target_user}")"

  # 4. 偵測 PHP 版本 (沿用來源站)
  local php_ver
  php_ver=$(opt_get "php" "$(find_site_php_version "$source_domain" 2>/dev/null || get_default_php_version)")
  if ! php_version_installed "$php_ver"; then
    log_error "$(_t "SITE_ERR_PHP_NOT_INSTALLED" "$php_ver" "$(get_installed_php_versions | paste -sd ' ' -)")"
    return 1
  fi
  log_info "$(_t "SITE_CLONE_11" "${php_ver}")"

  # 4b. 先匯出來源資料庫（不依賴目標網站）；失敗時目標網站還沒有被動到
  log_step "$(_t "SITE_CLONE_18")"
  mkdir -p "$backup_dir" && chmod 700 "$backup_dir" 2>/dev/null || true
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local sql_backup="${backup_dir}/${source_domain}-backup-${timestamp}.sql"
  ( umask 077; : > "$sql_backup" )
  if ! sudo -H -u "$source_user" wp db export - --add-drop-table --path="$source_root" > "$sql_backup"; then
    log_error "$(_t "SITE_CLONE_19")"
    rm -f "$sql_backup"
    return 1
  fi
  chmod 600 "$sql_backup" 2>/dev/null || true
  # 只在不存在或原本就是連結時建立，不可覆蓋使用者自己放的同名檔案
  if [[ ! -e "/root/${source_domain}.sql" || -L "/root/${source_domain}.sql" ]]; then
    ln -sfn "$sql_backup" "/root/${source_domain}.sql"
  fi
  log_info "$(_t "SITE_CLONE_20" "${sql_backup}")"

  # 4c. 檢查與來源資料都準備好之後，才刪除要被取代的目標網站
  if [[ -n "$replace_target" ]]; then
    log_warn "$(_t "SITE_CLONE_7" "${target_domain}")"
    if ! site_delete "$target_domain" -force; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_3" "${target_domain}")"
      return 1
    fi
    # 沿用的使用者若沒有被刪除（例如仍有行程），改用新的名稱，避免建站失敗
    if id -u "$target_user" >/dev/null 2>&1; then
      target_user=$(suggest_site_user "$target_domain")
      log_info "$(_t "SITE_CLONE_10" "${target_user}")"
    fi
  fi

  # 5. 自動產生資料庫帳密
  local target_dbname
  target_dbname=$(domain_to_dbname "$target_domain")
  local target_dbpass
  target_dbpass=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
  local siteuserpass="Clp_$(openssl rand -hex 6)!1"

  # 6. 本地建立目標網站與資料庫
  log_step "$(_t "SITE_CLONE_12" "${target_domain}")"
  clpctl site:add:php \
    --domainName="$target_domain" \
    --phpVersion="$php_ver" \
    --vhostTemplate="WordPress" \
    --siteUser="$target_user" \
    --siteUserPassword="$siteuserpass" || {
      log_error "$(_t "SITE_CLONE_13")"
      return 1
    }

  log_step "$(_t "SITE_CLONE_14" "${target_dbname}")"
  if ! clpctl db:add \
    --domainName="$target_domain" \
    --databaseName="$target_dbname" \
    --databaseUserName="$target_dbname" \
    --databaseUserPassword="$target_dbpass"; then
      log_error "$(_t "SITE_CLONE_15")"
      clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
      return 1
  fi

  target_root="/home/${target_user}/htdocs/${target_domain}"
  mkdir -p "$target_root"

  # 7. SSL 憑證配置 (Fail-Fast: 建立網站後立即配置，確保 HTTPS 即刻就緒且避免後續搬移白做工)
  local enable_ssl="y"
  if has_opt "no-ssl" || has_opt "nossl"; then
    enable_ssl="n"
  elif has_opt "ssl"; then
    enable_ssl=$(opt_get "ssl" "on")
  fi

  local clone_ssl_mode="dns"
  case "$enable_ssl" in
    http) clone_ssl_mode="http"; enable_ssl="y" ;;
    dns|true|on|yes|y|Y) enable_ssl="y" ;;
  esac
  if has_opt "http" && ! has_opt "dns"; then clone_ssl_mode="http"; fi
  if [[ "$enable_ssl" == "y" ]]; then
    log_step "$(_t "SITE_CLONE_16")"
    local CLP_INTERNAL_SSL_CALL=1
    site_ssl "$target_domain" "$clone_ssl_mode" || log_warn "$(_t "SITE_CLONE_17" "${target_domain}")"
  fi

  # 8. 匯入資料庫（來源已在步驟 4b 匯出到 $sql_backup）
  # 匯入至新資料庫 (使用 MYSQL_PWD 避免密碼洩漏至行程清單)
  if ! _site_db_import "$target_dbname" "$target_dbpass" "$sql_backup" "SITE_CLONE_21"; then
    log_error "$(_t "SITE_CLONE_22")"
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    return 1
  fi
  log_success "$(_t "SITE_CLONE_23")"

  # 9. 同步網站檔案 (排除快取與備份暫存檔)
  log_step "$(_t "SITE_CLONE_24" "${source_domain}" "${target_domain}")"
  local rsync_rc=0
  rsync -a --delete \
    --exclude='wp-content/cache' \
    --exclude='wp-content/updraft' \
    --exclude='wp-content/wpvividbackups' \
    "${source_root}/" "${target_root}/" || rsync_rc=$?
  # 24：同步時來源檔案消失（忙碌的網站常見），其餘檔案已複製；其他失敗則清除新網站
  if [[ "$rsync_rc" -eq 24 ]]; then
    log_warn "$(_t "SITE_CLONE_WARN_VANISHED")"
  elif [[ "$rsync_rc" -ne 0 ]]; then
    log_error "$(_t "SITE_ERR_RSYNC_FAILED" "$rsync_rc")"
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    return 1
  fi
  chown -R "${target_user}:${target_user}" "$target_root"
  log_success "$(_t "SITE_CLONE_25")"

  # 10. 安全與環境絕對路徑修復 (.user.ini / Wordfence / 快取外掛)
  sanitize_cloned_environment_paths "$target_root" "$source_root" "$target_user" || true

  # 11. 更新目標站 wp-config.php DB 帳密與快取隔離前綴
  # 失敗時新網站仍帶著來源網站的資料庫帳密，不可留下：清除新網站與資料庫
  if ! update_cloned_wpconfig "$target_root" "$target_dbname" "$target_dbpass" "$target_domain" "$target_user" "" "clone"; then
    log_error "$(_t "SITE_ERR_WPCONFIG_UPDATE")"
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    return 1
  fi

  # 12. WP-CLI 網址全面替換 (精準替換，避免子網域二次替換衝突)
  log_step "$(_t "SITE_CLONE_26" "${source_domain}" "${target_domain}")"
  if _wp_replace_domain "$target_user" "$target_root" "$source_domain" "$target_domain" "$source_root"; then
    log_success "$(_t "SITE_CLONE_27")"
  else
    log_warn "$(_t "SITE_WARN_SEARCH_REPLACE_FAILED" "$source_domain" "$target_domain" "$target_domain")"
  fi

  # 13. 自動校正實體 robots.txt 內之 Sitemap 與網域
  update_cloned_robots_txt "$target_root" "$source_domain" "$target_domain" "$target_user" || true

  # 14. 清理持久化物件快取 (避免讀取來源站快取殘留)
  log_info "$(_t "SITE_CLONE_28")"
  sudo -H -u "$target_user" wp cache flush --path="$target_root" 2>/dev/null || true
  sudo -H -u "$target_user" wp transient delete --all --path="$target_root" 2>/dev/null || true

  # 15. 權限校正、PHP-FPM Pool 調校與 Nginx 重載
  chown -R "${target_user}:${target_user}" "$target_root"
  optimize_site_php_fpm "$target_domain" "$php_ver" || log_warn "$(_t "PHP_FPM_WARN_OPTIMIZE_SKIPPED")"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  echo ""
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "SITE_CLONE_29" "${C_GREEN}" "${C_BOLD}" "${source_domain}" "${target_domain}" "${C_NC}")"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "SITE_CLONE_30" "${C_CYAN}" "${target_domain}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_31" "${C_BOLD}" "${target_user}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_32" "${C_BOLD}" "${target_dbname}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_33" "${C_YELLOW}" "${sql_backup}" "${C_NC}")"
  echo ""

  # 若 SSL 申請使用 Cloudflare DNS，於最後檢查並引導設定 DNS 指向
  if [[ -n "${CLP_CF_CREDENTIALS:-}" ]]; then
    prompt_cloudflare_dns "$target_domain" "$CLP_CF_CREDENTIALS"
  fi

  return 0
}

# ------------------------------------------------------------------------------
# 7x. 輔助函式：自動檢測並準備 SSH 連線 (支援 Passphrase 自動提示輸入與 ssh-agent 調度)
# ------------------------------------------------------------------------------
check_and_prepare_ssh() {
  local remote_host="$1"
  log_info "$(_t "SITE_CHECK_AND_PREPARE_SSH_1" "${remote_host}")"

  # 1. 快速檢測：若已可免密碼連線（無密碼金鑰、或環境已載入 agent），直接放行
  if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$remote_host" "echo Connected" >/dev/null 2>&1; then
    log_success "$(_t "SITE_CHECK_AND_PREPARE_SSH_2")"
    return 0
  fi

  # 2. 若無法免密連線，自動檢查是否需要解鎖金鑰 Passphrase
  log_info "$(_t "SITE_CHECK_AND_PREPARE_SSH_3" "${remote_host}")"
  # ssh-add -l：0 = 有金鑰、1 = agent 存在但沒有金鑰、2 = 無法連線到 agent。
  # 只有在沒有可用的 agent 時才啟動新的 agent（agent 存在但沒有金鑰時直接 ssh-add 即可）
  local agent_rc=0
  ssh-add -l >/dev/null 2>&1 || agent_rc=$?
  if [[ -z "${SSH_AUTH_SOCK:-}" || "$agent_rc" -eq 2 ]]; then
    eval "$(ssh-agent -s)" >/dev/null 2>&1
    # 串接既有的 EXIT trap：以 eval 解析 trap -p 的輸出，正確處理含引號的指令
    CLP_PREV_EXIT_TRAP=""
    local prev_trap_def
    prev_trap_def=$(trap -p EXIT)
    if [[ -n "$prev_trap_def" ]]; then
      eval "set -- ${prev_trap_def}"
      CLP_PREV_EXIT_TRAP="${3:-}"
    fi
    trap '[[ -n "${SSH_AGENT_PID:-}" ]] && kill "${SSH_AGENT_PID}" >/dev/null 2>&1; eval "${CLP_PREV_EXIT_TRAP:-}"' EXIT
  fi

  echo ""
  echo -e "$(_t "SITE_CHECK_AND_PREPARE_SSH_4" "${C_CYAN}" "${C_BOLD}" "${C_NC}")"
  if ( exec < /dev/tty ) 2>/dev/null; then
    ssh-add < /dev/tty || true
  elif [ -t 0 ]; then
    ssh-add || true
  else
    log_warn "$(_t "SITE_CHECK_AND_PREPARE_SSH_5")"
    log_warn "$(_t "SITE_CHECK_AND_PREPARE_SSH_6")"
  fi
  echo ""

  # 3. 解鎖後再次驗證連線
  if ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$remote_host" "echo Connected" >/dev/null 2>&1; then
    log_success "$(_t "SITE_CHECK_AND_PREPARE_SSH_7")"
    return 0
  fi

  # 4. 備援：若仍未成功，以正常互動模式執行一次 ssh 測試 (若有終端直接呈現 SSH 訊息)
  if ssh -n -o ConnectTimeout=10 "$remote_host" "echo Connected" 2>/dev/null; then
    log_success "$(_t "SITE_CHECK_AND_PREPARE_SSH_2")"
    return 0
  fi

  log_error "$(_t "SITE_CHECK_AND_PREPARE_SSH_8" "${remote_host}")"
  return 1
}

# ------------------------------------------------------------------------------
# 7y. 輔助函式：探測遠端網站是否存在、身分與路徑 (比對 CloudPanel 網站清單與 Nginx)
# ------------------------------------------------------------------------------
probe_remote_site() {
  local remote_host="$1"
  local source_domain="$2"
  local domain="$2"

  local probe_out
  probe_out=$(ssh -n "$remote_host" "
    domain='${source_domain}'
    clp_db='/home/clp/htdocs/app/data/db.sq3'
    found=0
    ruser=''
    rpath=''
    all_sites=''

    # 1. 優先比對遠端 CloudPanel SQLite 資料庫 (同 clp site -list 標準) 並驗證實體目錄
    if [ -f \"\$clp_db\" ] && command -v sqlite3 >/dev/null 2>&1; then
      site_row=\$(sqlite3 -readonly \"\$clp_db\" \"SELECT user, root_directory FROM site WHERE domain_name='\$domain' LIMIT 1;\" 2>/dev/null || true)
      if [ -n \"\$site_row\" ]; then
        ruser=\$(echo \"\$site_row\" | cut -d'|' -f1)
        rroot=\$(echo \"\$site_row\" | cut -d'|' -f2)
        if [ \"\${rroot#/}\" != \"\$rroot\" ]; then
          rpath=\"\$rroot\"
        else
          rpath=\"/home/\${ruser}/htdocs/\${rroot}\"
        fi
        [ -d \"\$rpath\" ] && found=1
      fi
      all_sites=\$(sqlite3 -readonly \"\$clp_db\" \"SELECT domain_name FROM site;\" 2>/dev/null | tr '\n' ' ')
    fi

    # 2. 備援 A：若資料庫未命中，比對 Nginx vhost 設定檔名稱與 htdocs 目錄
    if [ \$found -eq 0 ]; then
      if [ -f \"/etc/nginx/sites-enabled/\${domain}.conf\" ] || [ -f \"/etc/nginx/sites-available/\${domain}.conf\" ]; then
        rpath=\$(ls -d /home/*/htdocs/\${domain} 2>/dev/null | head -n 1)
        if [ -n \"\$rpath\" ] && [ -d \"\$rpath\" ]; then
          ruser=\$(stat -c '%U' \"\$rpath\" 2>/dev/null || ls -ld \"\$rpath\" | awk '{print \$3}')
          found=1
        fi
      fi
      if [ -z \"\$all_sites\" ]; then
        for conf in /etc/nginx/sites-enabled/*.conf; do
          [ -f \"\$conf\" ] || continue
          cname=\$(basename \"\$conf\" .conf)
          [ \"\$cname\" = 'default' ] && continue
          [ \"\$cname\" = 'custom-domain' ] && continue
          all_sites=\"\${all_sites}\${cname} \"
        done
      fi
    fi

    # 3. 備援 B (原本的純目錄檢查)：若上述皆未命中，直接檢查 /home/*/htdocs/實體目錄
    if [ \$found -eq 0 ]; then
      rpath=\$(ls -d /home/*/htdocs/\${domain} 2>/dev/null | head -n 1)
      if [ -n \"\$rpath\" ] && [ -d \"\$rpath\" ]; then
        ruser=\$(stat -c '%U' \"\$rpath\" 2>/dev/null || ls -ld \"\$rpath\" | awk '{print \$3}')
        found=1
      fi
    fi

    # 4. 若找到網站，探測 PHP 版本
    rphp=''
    if [ \$found -eq 1 ]; then
      if [ -f \"\$clp_db\" ] && command -v sqlite3 >/dev/null 2>&1; then
        rphp=\$(sqlite3 -readonly \"\$clp_db\" \"SELECT ps.php_version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id WHERE s.domain_name='\$domain' LIMIT 1;\" 2>/dev/null || true)
        if [ -z \"\$rphp\" ]; then
          rphp=\$(sqlite3 -readonly \"\$clp_db\" \"SELECT ps.version FROM site s JOIN php_settings ps ON s.php_settings_id=ps.id WHERE s.domain_name='\$domain' LIMIT 1;\" 2>/dev/null || true)
        fi
      fi
      if [ -z \"\$rphp\" ]; then
        for pconf in /etc/php/*/fpm/pool.d/\"\${domain}.conf\"; do
          if [ -f \"\$pconf\" ]; then
            rphp=\$(echo \"\$pconf\" | awk -F'/' '{print \$4}')
            break
          fi
        done
      fi
    fi

    # 5. 回傳狀態
    if [ \$found -eq 1 ]; then
      echo \"FOUND|\$ruser|\$rpath|\$rphp\"
    else
      echo \"NOT_FOUND|\$all_sites\"
    fi
  " 2>/dev/null || true)

  if [[ "$probe_out" == FOUND* ]]; then
    echo "$probe_out"
    return 0
  else
    local all_sites=""
    all_sites=$(echo "$probe_out" | cut -d'|' -f2)
    log_error "$(_t "SITE_PROBE_REMOTE_SITE_1" "${remote_host}" "${source_domain}")"
    if [[ -n "$all_sites" ]]; then
      log_info "$(_t "SITE_PROBE_REMOTE_SITE_2" "${remote_host}")"
      local -a all_sites_arr=()
      read -ra all_sites_arr <<< "$all_sites"
      # 呼叫端以 $(...) 取得 stdout：清單寫到 stderr 才看得到；清單來自遠端主機，顯示前移除控制字元
      for s in "${all_sites_arr[@]}"; do
        printf '  - %s%s%s\n' "$C_CYAN" "$(strip_ctrl_chars "$s")" "$C_NC" >&2
      done
    fi
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 7. Site Migrate All (clp site -migrate=<vps> -all [-exclude=<pattern>] [-force-replace])
# ------------------------------------------------------------------------------
site_migrate_all() {
  local remote_host
  remote_host=$(opt_get "migrate" "")

  if [[ -z "$remote_host" ]]; then
    log_error "$(_t "SITE_MIGRATE_ALL_1")"
    return 1
  fi

  log_step "$(_t "SITE_MIGRATE_ALL_2" "${remote_host}")"
  require_clp_db_server_ready || return 1
  log_warn "$(_t "SITE_MIGRATE_ALL_3" "${remote_host}")"

  # 1. 測試 SSH 連線 (若有 Passphrase 自動提示輸入解鎖)
  check_and_prepare_ssh "$remote_host" || return 1

  # 2. 確認遠端為 CloudPanel 系統
  log_info "$(_t "SITE_MIGRATE_ALL_4")"
  local is_clp
  is_clp=$(ssh -n "$remote_host" "command -v clpctl >/dev/null 2>&1 && echo 'yes'" 2>/dev/null || true)
  if [[ "$is_clp" != "yes" ]]; then
    log_error "$(_t "SITE_MIGRATE_ALL_5" "${remote_host}")"
    return 1
  fi
  log_success "$(_t "SITE_MIGRATE_ALL_6")"

  # 3. 掃描遠端已啟用網站清單 (優先比對 SQLite 資料庫，備援比對 Nginx sites-enabled)
  log_info "$(_t "SITE_MIGRATE_ALL_7")"
  local remote_domains_raw
  remote_domains_raw=$(ssh -n "$remote_host" "
    clp_db='/home/clp/htdocs/app/data/db.sq3'
    if [ -f \"\$clp_db\" ] && command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 -readonly -separator ' ' \"\$clp_db\" \"SELECT domain_name, type, COALESCE(application, '') FROM site;\" 2>/dev/null
    fi
  " 2>/dev/null || true)

  # 只搬移 WordPress（PHP）網站：搬移以 wp db export 匯出資料庫，其他類型（Node.js、Python、反向代理、非 WordPress 的 PHP）會失敗
  #   CloudPanel 資料庫有結果時不再改用 nginx 清單（即使過濾後一個都不剩）
  local remote_from_db=0
  if [[ -n "$remote_domains_raw" ]]; then
    remote_from_db=1
    local r_dom r_type r_app wp_domains=""
    while read -r r_dom r_type r_app; do
      [[ -z "$r_dom" ]] && continue
      if [[ "$r_type" == "php" && "${r_app,,}" == "wordpress" ]]; then
        wp_domains+="${r_dom}"$'\n'
      else
        log_warn "$(_t "SITE_MIGRATE_ALL_SKIP_TYPE" "$(strip_ctrl_chars "$r_dom")" "$(strip_ctrl_chars "${r_type}${r_app:+/${r_app}}")")"
      fi
    done <<< "$remote_domains_raw"
    remote_domains_raw="${wp_domains%$'\n'}"
  fi

  if [[ -z "$remote_domains_raw" && "$remote_from_db" -eq 0 ]]; then
    remote_domains_raw=$(ssh -n "$remote_host" "
      for conf in /etc/nginx/sites-enabled/*.conf; do
        [ -f \"\$conf\" ] || continue
        dom=\$(basename \"\$conf\" .conf)
        [ \"\$dom\" = 'default' ] && continue
        [ \"\$dom\" = 'custom-domain' ] && continue
        echo \"\$dom\"
      done
    " 2>/dev/null || true)
  fi

  if [[ -z "$remote_domains_raw" ]]; then
    log_error "$(_t "SITE_MIGRATE_ALL_8" "${remote_host}")"
    return 1
  fi

  # 4. 套用 -exclude pattern 過濾
  local exclude_raw
  exclude_raw=$(opt_get "exclude" "")
  declare -a exclude_patterns=()
  if [[ -n "$exclude_raw" ]]; then
    IFS=',' read -ra exclude_patterns <<< "$exclude_raw"
    log_info "$(_t "SITE_MIGRATE_ALL_9" "${exclude_patterns[*]}")"
  fi

  declare -a domains_to_migrate=()
  while IFS= read -r dom; do
    [[ -z "$dom" ]] && continue
    # 網域清單來自遠端主機：_migrate_single_site 會拒絕的名稱（例如含控制字元）不列入確認清單
    if [[ "$(clean_domain "$dom")" != "$dom" ]] || ! is_valid_domain "$dom"; then
      log_warn "$(_t "SITE_MIGRATE_ALL_SKIP_INVALID" "$(strip_ctrl_chars "$dom")")"
      continue
    fi
    local skip=0
    for pat in "${exclude_patterns[@]}"; do
      if domain_matches_exclude "$dom" "$pat"; then
        log_info "$(_t "SITE_MIGRATE_ALL_10" "${pat}" "${dom}")"
        skip=1
        break
      fi
    done
    [[ $skip -eq 0 ]] && domains_to_migrate+=("$dom")
  done <<< "$remote_domains_raw"

  if [[ ${#domains_to_migrate[@]} -eq 0 ]]; then
    log_warn "$(_t "SITE_MIGRATE_ALL_11")"
    return 0
  fi

  # 5. 列出搬移清單並請求確認 (支援互動式輸入序號排除，例如: 2,3 或 2-4)
  if has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]]; then
    echo ""
    echo -e "${C_BOLD}======================================================${C_NC}"
    echo -e "$(_t "SITE_MIGRATE_ALL_12" "${C_BOLD}" "${#domains_to_migrate[@]}" "${C_NC}")"
    echo -e "${C_BOLD}======================================================${C_NC}"
    local idx=1
    for dom in "${domains_to_migrate[@]}"; do
      printf "  [%2d] %s\n" "$idx" "$dom"
      idx=$((idx + 1))
    done
    echo ""
    log_info "$(_t "SITE_MIGRATE_ALL_AUTO_YES_CONFIRMED")"
  else
    if [[ ! -t 0 ]]; then
      log_error "$(_t "SITE_MIGRATE_ALL_ERR_NON_INTERACTIVE")"
      return 1
    fi
    while true; do
      echo ""
      echo -e "${C_BOLD}======================================================${C_NC}"
      echo -e "$(_t "SITE_MIGRATE_ALL_12" "${C_BOLD}" "${#domains_to_migrate[@]}" "${C_NC}")"
      echo -e "${C_BOLD}======================================================${C_NC}"
      local idx=1
      for dom in "${domains_to_migrate[@]}"; do
        printf "  [%2d] %s\n" "$idx" "$dom"
        idx=$((idx + 1))
      done
      echo ""
      echo -e "$(_t "SITE_MIGRATE_ALL_13" "${C_YELLOW}" "${C_NC}")"
      echo -e "$(_t "SITE_MIGRATE_ALL_14" "${C_GREEN}" "${C_NC}" "${C_RED}" "${C_NC}" "${C_CYAN}" "${C_NC}" "${C_CYAN}" "${C_NC}")"
      read -r -p "$(_t "SITE_MIGRATE_ALL_15")" confirm || confirm="n"
      confirm=$(echo "${confirm:-y}" | tr -d '[:space:]')

      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        break
      elif [[ "$confirm" =~ ^[NnQq]$ ]]; then
        log_warn "$(_t "SITE_MIGRATE_ALL_16")"
        return 0
      else
        # 解析使用者輸入的數字或範圍 (例如 2,3 或 2-4 或 e 2,3)
        local clean_input
        clean_input=$(echo "$confirm" | sed -e 's/^[eE]//' | tr ',' ' ')
        local -a to_remove_indexes=()
        local valid_input=0

        local -a clean_items=()
        read -ra clean_items <<< "$clean_input"
        for item in "${clean_items[@]}"; do
          # 以十進位解讀（08、010 不可被當成八進位）；範圍上限不超過清單長度（避免 1-999999999 跑很久）
          if [[ "$item" =~ ^([0-9]{1,6})-([0-9]{1,6})$ ]]; then
            local start=$((10#${BASH_REMATCH[1]}))
            local end=$((10#${BASH_REMATCH[2]}))
            if (( start > end )); then
              local tmp=$start; start=$end; end=$tmp
            fi
            (( end > ${#domains_to_migrate[@]} )) && end=${#domains_to_migrate[@]}
            for ((n=start; n<=end; n++)); do
              if (( n >= 1 && n <= ${#domains_to_migrate[@]} )); then
                to_remove_indexes+=("$n")
                valid_input=1
              fi
            done
          elif [[ "$item" =~ ^[0-9]{1,6}$ ]]; then
            item=$((10#$item))
            if (( item >= 1 && item <= ${#domains_to_migrate[@]} )); then
              to_remove_indexes+=("$item")
              valid_input=1
            fi
          fi
        done

        if [[ $valid_input -eq 1 ]]; then
          local -a new_domains=()
          for ((i=1; i<=${#domains_to_migrate[@]}; i++)); do
            local is_excluded=0
            for rem in "${to_remove_indexes[@]}"; do
              if [[ $i -eq $rem ]]; then
                is_excluded=1
                log_info "$(_t "SITE_MIGRATE_ALL_17" "${rem}" "${domains_to_migrate[$((i-1))]}")"
                break
              fi
            done
            if [[ $is_excluded -eq 0 ]]; then
              new_domains+=("${domains_to_migrate[$((i-1))]}")
            fi
          done
          domains_to_migrate=("${new_domains[@]}")

          if [[ ${#domains_to_migrate[@]} -eq 0 ]]; then
            log_warn "$(_t "SITE_MIGRATE_ALL_18")"
            return 0
          fi
        else
          log_warn "$(_t "SITE_MIGRATE_ALL_19")"
        fi
      fi
    done
  fi

  # 6. 逐站搬移
  local global_force_replace=0
  if has_opt "force-replace" || has_opt "force_replace"; then
    global_force_replace=1
  fi

  local count_success=0
  local count_skip=0
  local count_fail=0
  declare -a skipped_domains=()
  declare -a failed_domains=()
  local start_time
  start_time=$(date +%s)

  for dom in "${domains_to_migrate[@]}"; do
    echo ""
    echo -e "${C_CYAN}${C_BOLD}------------------------------------------------------${C_NC}"
    echo -e "$(_t "SITE_MIGRATE_ALL_20" "${C_CYAN}" "${C_BOLD}" "${dom}" "${C_NC}")"
    echo -e "${C_CYAN}${C_BOLD}------------------------------------------------------${C_NC}"

    # 檢查本地是否已存在
    local local_root
    local replace_dom=0
    local_root=$(find_site_root "$dom" 2>/dev/null || true)
    if site_exists "$dom" || [[ -n "$local_root" && -d "$local_root" ]]; then
      if [[ $global_force_replace -eq 1 ]]; then
        log_warn "$(_t "SITE_MIGRATE_ALL_21" "${dom}")"
        replace_dom=1
      elif has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]]; then
        log_warn "$(_t "SITE_MIGRATE_ALL_WARN_CONFLICT_SKIPPED" "${dom}")"
        skipped_domains+=("$dom")
        count_skip=$((count_skip + 1))
        continue
      else
        if [[ ! -t 0 ]]; then
          log_error "$(_t "SITE_MIGRATE_ALL_ERR_CONFLICT_NON_INTERACTIVE" "${dom}")"
          return 1
        fi
        echo -e "$(_t "SITE_MIGRATE_ALL_22" "${C_YELLOW}" "${dom}" "${C_NC}")"
        echo "$(_t "SITE_MIGRATE_ALL_23")"
        echo "$(_t "SITE_MIGRATE_ALL_24")"
        echo "$(_t "SITE_MIGRATE_ALL_25")"
        read -r -p "$(_t "SITE_MIGRATE_ALL_26")" conflict_choice || conflict_choice="s"
        conflict_choice="${conflict_choice:-s}"
        case "$conflict_choice" in
          o|O)
            log_warn "$(_t "SITE_MIGRATE_ALL_27" "${dom}")"
            replace_dom=1
            ;;
          q|Q)
            log_warn "$(_t "SITE_MIGRATE_ALL_28")"
            break
            ;;
          *)
            log_info "$(_t "SITE_MIGRATE_ALL_29" "${dom}")"
            skipped_domains+=("$dom")
            count_skip=$((count_skip + 1))
            continue
            ;;
        esac
      fi
    fi

    # 執行單站搬移（網域不變，不需要 search-replace）
    if CLP_MIGRATE_BATCH=1 _migrate_single_site "$remote_host" "$dom" "$dom" "same_domain" "$replace_dom"; then
      log_success "$(_t "SITE_MIGRATE_ALL_30" "${dom}")"
      count_success=$((count_success + 1))
    else
      log_error "$(_t "SITE_MIGRATE_ALL_31" "${dom}")"
      failed_domains+=("$dom")
      count_fail=$((count_fail + 1))
    fi
  done

  # 7. 摘要報告
  local end_time elapsed total_min total_sec
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  total_min=$((elapsed / 60))
  total_sec=$((elapsed % 60))

  echo ""
  echo -e "$(_t "SITE_MIGRATE_ALL_32" "${C_BOLD}" "${C_GREEN}" "${C_NC}")"
  echo -e "$(_t "SITE_MIGRATE_ALL_33" "${C_GREEN}" "${count_success}" "${C_NC}")"
  local skipped_detail="" failed_detail=""
  [[ ${#skipped_domains[@]} -gt 0 ]] && skipped_detail=" (${skipped_domains[*]})"
  [[ ${#failed_domains[@]} -gt 0 ]] && failed_detail=" (${failed_domains[*]})"
  echo -e "$(_t "SITE_MIGRATE_ALL_SKIPPED_SUMMARY" "${C_YELLOW}" "${count_skip}" "${C_NC}" "${skipped_detail}")"
  echo -e "$(_t "SITE_MIGRATE_ALL_FAILED_SUMMARY" "${C_RED}" "${count_fail}" "${C_NC}" "${failed_detail}")"
  printf "$(_t "SITE_MIGRATE_ALL_34")" "$total_min" "$total_sec"
  echo -e "${C_BOLD}${C_GREEN}=============================${C_NC}"
  # 有網站搬移失敗時回傳非 0，讓腳本與排程能偵測
  [[ "$count_fail" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# 7a. 內部輔助：搬移單一網站至本地 (供 site_migrate 與 site_migrate_all 共用)
#     參數: <remote_host> <source_domain> <target_domain> [same_domain|diff_domain]
# ------------------------------------------------------------------------------
_migrate_single_site() {
  local remote_host="$1"
  local source_domain="$2"
  local target_domain="$3"
  local domain_mode="${4:-diff_domain}"   # same_domain | diff_domain
  local replace_existing="${5:-0}"        # 1 = 確認遠端可搬移後刪除本地既有網站

  # 來源網域也要驗證：會放進遠端的 ls /home/*/htdocs/<網域> 與本機檔名（-from='*' 會比對到任意網站；
  # -all 時網域名稱來自遠端主機）
  # is_valid_domain 驗證的是 clean_domain 之後的值（會去掉引號、分號）；名稱必須本來就是乾淨的，
  # 否則 a.com';id;' 會通過檢查，原字串卻被放進遠端指令
  if [[ "$(clean_domain "$source_domain")" != "$source_domain" ]] || ! is_valid_domain "$source_domain"; then
    log_error "$(_t "SITE_MIGRATE_ERR_INVALID_SOURCE" "${source_domain}")"
    return 1
  fi
  if [[ "$(clean_domain "$target_domain")" != "$target_domain" ]] || ! is_valid_domain "$target_domain"; then
    log_error "$(_t "SITE_CLONE_2" "${target_domain}")"
    return 1
  fi

  # 留存的資料庫備份寫入 clp config 的 backup-dir；先讀取，設定不合法時在刪除或建立任何東西之前停止
  local backup_dir
  backup_dir="$(config_get_valid BACKUP_DIR)" || return 1

  # 探測遠端網站 (比對 CloudPanel 網站清單與 Nginx)
  local remote_info
  remote_info=$(probe_remote_site "$remote_host" "$source_domain") || return 1

  local remote_user remote_root remote_php
  remote_user=$(echo "$remote_info" | cut -d'|' -f2)
  remote_root=$(echo "$remote_info" | cut -d'|' -f3)
  remote_php=$(echo "$remote_info" | cut -d'|' -f4)
  [[ -z "$remote_php" ]] && remote_php="$(get_default_php_version)"
  log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_1" "$(strip_ctrl_chars "$remote_user")" "$(strip_ctrl_chars "$remote_root")" "$(strip_ctrl_chars "$remote_php")")"

  # 檢查遠端來源站線上登入使用者狀態
  prompt_wp_active_sessions "$remote_host" "$source_domain" "$remote_root" "$remote_user" || return 1

  # -force-replace 的本地網站刪除延後到使用者、PHP 檢查與遠端資料庫下載完成之後
  local replace_target=""
  [[ "$replace_existing" -eq 1 ]] && replace_target="$target_domain"

  # 決定本地 site user（單站支援 -user= 覆寫；若預設使用者已存在於系統則自動建議可用名稱）
  local target_user=""
  # -user 只適用於單站搬移；批次搬移 (-all) 每個網站必須各自使用不同的系統使用者
  if [[ "${CLP_MIGRATE_BATCH:-0}" -ne 1 ]]; then
    target_user=$(opt_get "user" "")
  fi
  if [[ -n "$target_user" ]]; then
    target_user=$(echo "$target_user" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    if ! replace_user_available "$target_user" "$replace_target"; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_4" "${target_user}")"
      return 1
    fi
  else
    local replaced_user=""
    if replace_user_available "$remote_user" "$replace_target"; then
      target_user="$remote_user"
    elif [[ -n "$replace_target" ]] && replaced_user=$(find_site_user "$replace_target" 2>/dev/null) && [[ -n "$replaced_user" ]]; then
      # 取代既有網站時沿用它的使用者（刪除時會一併移除，再由新網站建立）
      target_user="$replaced_user"
    else
      target_user=$(suggest_site_user "$target_domain")
    fi
  fi
  log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_5" "${target_user}")"

  # 決定 PHP 版本（支援 -php= 覆寫，若未指定則自動採用遠端探測版本）
  local php_ver
  php_ver=$(opt_get "php" "$remote_php")
  if ! php_version_installed "$php_ver"; then
    log_error "$(_t "SITE_ERR_PHP_NOT_INSTALLED" "$php_ver" "$(get_installed_php_versions | paste -sd ' ' -)")"
    return 1
  fi
  log_info "$(_t "SITE_CLONE_11" "${php_ver}")"

  # 先完整下載遠端資料庫並驗證（不依賴本地網站）；失敗時本地網站還沒有被動到
  #   - 遠端不經 gzip 管線（改用 ssh -C 壓縮傳輸），ssh 的結束狀態即為 wp db export 的狀態
  #   - 以 mysqldump 結尾的 "-- Dump completed" 標記確認 dump 完整，避免匯入只有一半資料表的檔案
  log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_10")"
  mkdir -p "$backup_dir" && chmod 700 "$backup_dir" 2>/dev/null || true
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local sql_backup="${backup_dir}/${source_domain}-backup-${timestamp}.sql"
  ( umask 077; : > "$sql_backup" )
  if ! ssh -n -C "$remote_host" "cd '${remote_root}' && sudo -H -u '${remote_user}' wp db export - --add-drop-table" > "$sql_backup"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_11")"
    rm -f "$sql_backup"
    return 1
  fi
  if [[ ! -s "$sql_backup" ]] || ! tail -n 5 "$sql_backup" | grep -q -- "-- Dump completed"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_12")"
    rm -f "$sql_backup"
    return 1
  fi

  # 檢查與遠端資料都準備好之後，才刪除要被覆寫的本地網站
  if [[ -n "$replace_target" ]]; then
    log_warn "$(_t "SITE__MIGRATE_SINGLE_SITE_2" "${target_domain}")"
    if ! site_delete "$target_domain" -force; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_3" "${target_domain}")"
      rm -f "$sql_backup"
      return 1
    fi
    # 沿用的使用者若沒有被刪除（例如仍有行程），改用新的名稱，避免建站失敗
    if id -u "$target_user" >/dev/null 2>&1; then
      target_user=$(suggest_site_user "$target_domain")
      log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_5" "${target_user}")"
    fi
  fi

  # 自動產生本地資料庫帳密
  local target_dbname
  target_dbname=$(domain_to_dbname "$target_domain")
  local target_dbpass
  target_dbpass=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
  local siteuserpass="Clp_$(openssl rand -hex 6)!1"

  # 建立本地網站
  log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_6" "${target_domain}")"
  clpctl site:add:php \
    --domainName="$target_domain" \
    --phpVersion="$php_ver" \
    --vhostTemplate="WordPress" \
    --siteUser="$target_user" \
    --siteUserPassword="$siteuserpass" || {
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_7")"
      rm -f "$sql_backup"
      return 1
    }

  # 建立本地資料庫
  log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_8" "${target_dbname}")"
  if ! clpctl db:add \
    --domainName="$target_domain" \
    --databaseName="$target_dbname" \
    --databaseUserName="$target_dbname" \
    --databaseUserPassword="$target_dbpass"; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_9")"
      clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
      rm -f "$sql_backup"
      return 1
  fi

  local target_root="/home/${target_user}/htdocs/${target_domain}"
  mkdir -p "$target_root"

  # SSL 憑證配置 (Fail-Fast: 建立網站後立即配置，確保 HTTPS 即刻就緒且避免搬移白做工)
  # 與 clone 相同的 SSL 參數解析（-ssl=http、-http、-ssl=off／no 等）
  local enable_ssl="y"
  if has_opt "no-ssl" || has_opt "nossl"; then
    enable_ssl="n"
  elif has_opt "ssl"; then
    enable_ssl=$(opt_get "ssl" "on")
  fi
  local migrate_ssl_mode="dns"
  case "$enable_ssl" in
    http) migrate_ssl_mode="http"; enable_ssl="y" ;;
    dns|true|on|yes|y|Y) enable_ssl="y" ;;
  esac
  if has_opt "http" && ! has_opt "dns"; then migrate_ssl_mode="http"; fi
  if [[ "$enable_ssl" == "y" ]]; then
    log_step "$(_t "SITE_CLONE_16")"
    local CLP_INTERNAL_SSL_CALL=1
    site_ssl "$target_domain" "$migrate_ssl_mode" || log_warn "$(_t "SITE_CLONE_17" "${target_domain}")"
  fi

  # 匯入已下載的遠端資料庫；本地帳號匯入失敗時，只有加上 -db-root 才改用 root 重試
  _migrate_abort_db() {
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    rm -f "$sql_backup"
  }

  if ! _site_db_import "$target_dbname" "$target_dbpass" "$sql_backup" "SITE__MIGRATE_SINGLE_SITE_13"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_14")"
    _migrate_abort_db
    return 1
  fi

  chmod 600 "$sql_backup" 2>/dev/null || true
  # 只在不存在或原本就是連結時建立，不可覆蓋使用者自己放的同名檔案
  if [[ ! -e "/root/${source_domain}.sql" || -L "/root/${source_domain}.sql" ]]; then
    ln -sfn "$sql_backup" "/root/${source_domain}.sql"
  fi
  log_success "$(_t "SITE__MIGRATE_SINGLE_SITE_15" "${sql_backup}")"

  # 網站檔案同步
  log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_16")"
  if ! rsync -avzP \
    --exclude='wp-content/cache' \
    --exclude='wp-content/updraft' \
    --exclude='wp-content/wpvividbackups' \
    "${remote_host}:${remote_root}/" "${target_root}/"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_17" "${sql_backup}")"
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    return 1
  fi
  chown -R "${target_user}:${target_user}" "$target_root"
  log_success "$(_t "SITE__MIGRATE_SINGLE_SITE_18")"

  # 安全與環境絕對路徑修復 (.user.ini / Wordfence / 快取外掛)
  sanitize_cloned_environment_paths "$target_root" "$remote_root" "$target_user" || true

  # 更新 wp-config.php DB 帳密與快取隔離前綴
  if ! update_cloned_wpconfig "$target_root" "$target_dbname" "$target_dbpass" "$target_domain" "$target_user" "" "clone"; then
    log_error "$(_t "SITE_ERR_WPCONFIG_UPDATE")"
    _migrate_abort_db
    return 1
  fi

  # WP search-replace（只在網域不同時才執行，加入 --skip-plugins --skip-themes）
  if [[ "$domain_mode" != "same_domain" ]]; then
    log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_19" "${source_domain}" "${target_domain}")"
    if _wp_replace_domain "$target_user" "$target_root" "$source_domain" "$target_domain" "$remote_root"; then
      log_success "$(_t "SITE_CLONE_27")"
    else
      log_warn "$(_t "SITE_WARN_SEARCH_REPLACE_FAILED" "$source_domain" "$target_domain" "$target_domain")"
    fi

    # 自動校正實體 robots.txt 內之 Sitemap 與網域
    update_cloned_robots_txt "$target_root" "$source_domain" "$target_domain" "$target_user" || true
  else
    log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_20")"
    # 網域相同但網站使用者不同時，資料庫中的網站路徑仍要更新
    _wp_replace_path "$target_user" "$target_root" "$remote_root" || \
      log_warn "$(_t "SITE_WARN_PATH_REPLACE_FAILED" "$remote_root" "$target_root")"
  fi

  # 清理持久化物件快取與暫存
  log_info "$(_t "SITE_CLONE_28")"
  sudo -H -u "$target_user" wp cache flush --path="$target_root" 2>/dev/null || true
  sudo -H -u "$target_user" wp transient delete --all --path="$target_root" 2>/dev/null || true

  # 權限校正、PHP-FPM 調校、Nginx reload
  chown -R "${target_user}:${target_user}" "$target_root"
  optimize_site_php_fpm "$target_domain" "$php_ver" || log_warn "$(_t "PHP_FPM_WARN_OPTIMIZE_SKIPPED")"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true

  echo ""
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "SITE__MIGRATE_SINGLE_SITE_21" "${C_GREEN}" "${C_BOLD}" "${remote_host}" "${source_domain}" "${target_domain}" "${C_NC}")"
  echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
  echo -e "$(_t "SITE_CLONE_30" "${C_CYAN}" "${target_domain}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_31" "${C_BOLD}" "${target_user}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_32" "${C_BOLD}" "${target_dbname}" "${C_NC}")"
  echo -e "$(_t "SITE_CLONE_33" "${C_YELLOW}" "${sql_backup}" "${C_NC}")"
  echo ""

  # 若 SSL 申請使用 Cloudflare DNS，於最後檢查並引導設定 DNS 指向
  if [[ -n "${CLP_CF_CREDENTIALS:-}" ]]; then
    prompt_cloudflare_dns "$target_domain" "$CLP_CF_CREDENTIALS"
  fi

  return 0
}

# ------------------------------------------------------------------------------
# 7. Site Migrate (clp site -migrate=<remote_host> -from=<domain1> [<domain2>])
# ------------------------------------------------------------------------------
site_migrate() {
  # 若帶有 -all 旗標，轉發至批次搬移函式
  if has_opt "all"; then
    site_migrate_all "$@"
    return $?
  fi

  local remote_host
  remote_host=$(opt_get "migrate" "")

  local source_domain
  source_domain=$(clean_domain "$(opt_get 'from' '')")

  local target_domain=""
  for pos in "${POSITIONAL[@]}"; do
    local clean_pos
    clean_pos=$(clean_domain "$pos")
    if [[ "$clean_pos" != "site" && "$clean_pos" != "$remote_host" ]]; then
      target_domain="$clean_pos"
      break
    fi
  done

  # 若未特別指定 target_domain，預設為同網域搬移 (沿用 source_domain)
  if [[ -z "$target_domain" && -n "$source_domain" ]]; then
    target_domain="$source_domain"
  fi

  # 若未指定 -from 但有 positional domain (例如 clp site example.com -migrate=remote-vps)
  if [[ -z "$source_domain" && -n "$target_domain" ]]; then
    source_domain="$target_domain"
  fi

  if [[ -z "$remote_host" || -z "$source_domain" || -z "$target_domain" ]]; then
    log_error "$(_t "SITE_MIGRATE_1")"
    return 1
  fi

  if ! is_valid_domain "$target_domain"; then
    log_error "$(_t "SITE_CLONE_2" "${target_domain}")"
    return 1
  fi

  log_step "$(_t "SITE_MIGRATE_2" "${remote_host}" "${source_domain}" "${target_domain}")"
  require_clp_db_server_ready || return 1
  log_warn "$(_t "SITE_MIGRATE_ALL_3" "${remote_host}")"

  # 1. 測試 SSH 連線 (若有 Passphrase 自動提示輸入解鎖)
  check_and_prepare_ssh "$remote_host" || return 1

  # 2. 檢查遠端是否為 CloudPanel 系統
  log_info "$(_t "SITE_MIGRATE_ALL_4")"
  local is_clp
  is_clp=$(ssh -n "$remote_host" "command -v clpctl >/dev/null 2>&1 && echo 'yes'" 2>/dev/null || true)
  if [[ "$is_clp" != "yes" ]]; then
    log_error "$(_t "SITE_MIGRATE_ALL_5" "${remote_host}")"
    return 1
  fi
  log_success "$(_t "SITE_MIGRATE_ALL_6")"

  # 3. 檢查本地目標站是否存在
  #    覆寫本地網站必須明確指定 -force-replace（-y 只代表自動回答提示，不代表同意刪除既有網站）；
  #    實際刪除延後到確認遠端來源存在且使用者同意繼續之後
  local target_root
  local replace_existing=0
  target_root=$(find_site_root "$target_domain" 2>/dev/null || true)
  if site_exists "$target_domain" || [[ -n "$target_root" && -d "$target_root" ]]; then
    if has_opt "force-replace" || has_opt "force_replace"; then
      log_warn "$(_t "SITE_MIGRATE_3" "${target_domain}")"
      replace_existing=1
    else
      log_error "$(_t "SITE_MIGRATE_4" "${target_domain}")"
      return 1
    fi
  fi

  # 4. 判斷網域模式並委派執行單站搬移
  local domain_mode="diff_domain"
  if [[ "$source_domain" == "$target_domain" ]]; then
    domain_mode="same_domain"
  fi

  _migrate_single_site "$remote_host" "$source_domain" "$target_domain" "$domain_mode" "$replace_existing"
}

# ------------------------------------------------------------------------------
# 7. Cloudflare Edge WAF & Security Optimization (clp site <domain> -cf-waf)
# ------------------------------------------------------------------------------
site_cf_waf() {
  # 與其他 site 指令相同先整理網域（https://、結尾 /、大小寫）；不檢查本機是否有該網站（zone 網域也可以設定 WAF）
  local domain
  domain="$(clean_domain "${1:-}")"

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_CF_WAF_1")"
    return 1
  fi

  if ! command -v cf_resolve_token >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${CLP_ROOT_DIR}/lib/cloudflare.sh"
  fi

  local waf_action="on"
  local cf_action_val
  cf_action_val="$(opt_get "cf_waf" "")"
  [[ -z "$cf_action_val" ]] && cf_action_val="$(opt_get "cf-waf" "")"

  # 值不分大小寫；不認得的值直接報錯（原本一律當成 on，會部署規則並修改整個 zone）
  cf_action_val="${cf_action_val,,}"
  case "$cf_action_val" in
    ""|true|on) waf_action="on" ;;
    status) waf_action="status" ;;
    off) waf_action="off" ;;
    *)
      log_error "$(_t "SITE_CF_WAF_ERR_VALUE" "$cf_action_val")"
      return 1
      ;;
  esac

  local cli_token
  cli_token="$(opt_get "token" "")"
  local api_param
  api_param="$(opt_get "api" "")"
  local whitelist
  whitelist="$(opt_get "whitelist" "")"
  local dry_run=false
  if has_opt "dry-run" || has_opt "dry_run"; then
    dry_run=true
  fi
  local custom_rules
  custom_rules="$(opt_get "rules" "")"

  local token
  if ! token="$(cf_resolve_token "$domain" "$cli_token" "$api_param")"; then
    return 1
  fi

  local zone_id
  if ! zone_id="$(cf_get_zone_id "$domain" "$token")"; then
    return 1
  fi

  case "$waf_action" in
    status)
      cf_show_status "$zone_id" "$domain" "$token"
      return 0
      ;;
    off)
      log_warn "$(_t "CF_WARN_ZONE_WIDE" "$domain")"
      local rm_res=0
      cf_remove_waf_rules "$zone_id" "$domain" "$token" "$dry_run" || rm_res=$?
      return $rm_res
      ;;
    on)
      echo ""
      echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
      echo -e " 🛡️  $(_t "CF_STATUS_TITLE" "$domain")"
      echo -e "${C_CYAN}${C_BOLD}======================================================================${C_NC}"
      log_warn "$(_t "CF_WARN_ZONE_WIDE" "$domain")"
      # 先部署 WAF 規則；配額不足或讀取規則失敗而中止時，不變更 zone 設定
      local res=0
      cf_deploy_waf_rules "$zone_id" "$domain" "$token" "$whitelist" "$custom_rules" "$dry_run" || res=$?
      if [[ $res -eq 0 ]]; then
        local zone_rc=0
        cf_configure_zone_settings "$zone_id" "$token" "$dry_run" || zone_rc=$?
        if [[ "$zone_rc" -ne 0 ]]; then
          log_warn "$(_t "CF_WARN_ZONE_SETTINGS_FAILED")"
        fi
        cf_check_and_enable_proxy "$zone_id" "$domain" "$token" "$dry_run" || true
        echo ""
        # zone 設定有失敗時不顯示「完成」，並回傳失敗（WAF 規則已部署）
        if [[ "$zone_rc" -ne 0 ]]; then
          log_warn "$(_t "CF_BANNER_PARTIAL")"
          return 1
        fi
        echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
        echo -e " 🎉 $(_t "CF_BANNER_COMPLETE")"
        echo -e "$(_t "SITE_CF_WAF_2")"
        echo -e " 💡 $(_t "CF_BANNER_SUGGESTION")"
        echo -e "${C_GREEN}${C_BOLD}======================================================================${C_NC}"
        echo ""
      fi
      return $res
      ;;
  esac
}

# ------------------------------------------------------------------------------
# CloudPanel「Allow traffic from Cloudflare only」(clp site -cf-only)
#   CloudPanel 的設定存在 site.allow_traffic_from_cloudflare_only，並依此重新產生 vhost：
#   主要 server 區塊的 access_log 改用 cloudflare 格式，{{settings}} 處加上
#   include /etc/nginx/cloudflare/ips;（CloudPanel 維護的 Cloudflare IP allow 清單 + deny all）。
#   clp 同時修改 vhost 與資料庫，之後在後台重新產生 vhost 也會保留這個設定。
# ------------------------------------------------------------------------------
CF_ONLY_DB="/home/clp/htdocs/app/data/db.sq3"
CF_ONLY_IPS="/etc/nginx/cloudflare/ips"
CF_ONLY_BACKUP_DIR=""

cf_only_py() {
  python3 -I "${CLP_LIB_DIR}/cf_only.py" "$@"
}

cf_only_precheck() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"
    return 1
  fi
  if [[ ! -f "$CF_ONLY_DB" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_DB" "$CF_ONLY_DB")"
    return 1
  fi
  if [[ ! -f "$CF_ONLY_IPS" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_IPS" "$CF_ONLY_IPS")"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# nginx.conf 的 set_real_ip_from 0.0.0.0/0（CloudPanel nginx 套件預設）
#   nginx 會信任任何來源送來的 X-Real-IP 並換掉 $remote_addr，所以直連主機帶上
#   X-Real-IP: <Cloudflare IP> 就能通過 cloudflare/ips 的 allow 清單。
#   開啟 cf-only 時把這一行註解掉（不刪除，並加上標記）；私有網段與 127.0.0.1 保留，
#   Varnish（6081）與 wp-admin 轉到 8080 都是從 127.0.0.1 連線，不受影響。
# ------------------------------------------------------------------------------
# real-ip 的狀態判斷與 nginx.conf 改寫在 core.sh（httpauth 白名單共用）
CF_ONLY_NGINX_CONF="$CLP_REALIP_NGINX_CONF"

# cf_only_realip_state：輸出 active（生效中）| clp（已由 clp 註解）| none（不存在）
cf_only_realip_state() {
  clp_realip_state
}

# cf_only_realip_header：輸出未註解、且不是預設 X-Real-IP 的 real_ip_header 值（沒有則輸出空字串）
#   改讀 X-Forwarded-For／CF-Connecting-IP 時，$remote_addr 會在 allow 檢查之前被換成訪客 IP，cf-only 會擋掉所有訪客
cf_only_realip_header() {
  awk '
    /^[[:space:]]*real_ip_header[[:space:]]+/ {
      v = $2; sub(/;.*/, "", v)
      if (tolower(v) != "x-real-ip") { print v; exit }
    }
  ' "$CF_ONLY_NGINX_CONF" 2>/dev/null || true
}

# cf_only_realip_check_header：有衝突的 real_ip_header 時報錯（開啟前呼叫）
cf_only_realip_check_header() {
  local hdr
  hdr=$(cf_only_realip_header)
  if [[ -n "$hdr" ]]; then
    log_error "$(_t "SITE_CF_ONLY_REALIP_ERR_HEADER" "$hdr" "$CF_ONLY_NGINX_CONF")"
    return 1
  fi
}

# cf_only_realip_need_confirm：該行生效中、非 TTY、又沒有 -y 時報錯（在修改任何東西之前呼叫）
cf_only_realip_need_confirm() {
  [[ "$(cf_only_realip_state)" == "active" ]] || return 0
  if has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_error "$(_t "SITE_CF_ONLY_REALIP_ERR_NON_TTY")"
    return 1
  fi
}

# cf_only_realip_write <disable|restore>：備份 CloudPanel DB 後改寫 nginx.conf（見 core.sh 的 clp_realip_write）
cf_only_realip_write() {
  cf_only_backup_init || return 1
  clp_realip_write "$1" "$CF_ONLY_BACKUP_DIR"
}

# cf_only_realip_disable <dry_run>：開啟 cf-only 後呼叫；互動模式先詢問（預設 yes），-y 直接處理
#   失敗或使用者拒絕時只警告，不影響已完成的 cf-only 設定
cf_only_realip_disable() {
  local dry_run="$1"
  [[ "$(cf_only_realip_state)" == "active" ]] || return 0
  log_warn "$(_t "SITE_CF_ONLY_REALIP_EXPLAIN" "$CF_ONLY_NGINX_CONF")"
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_CF_ONLY_REALIP_DRY_RUN" "$CF_ONLY_NGINX_CONF")"
    return 0
  fi
  if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
    local ans=""
    if ! read -r -p "$(_t "SITE_CF_ONLY_REALIP_PROMPT")" ans; then
      ans="n"
    fi
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"  # Yes／YES 也算同意
    if [[ -n "$ans" && "$ans" != "y" && "$ans" != "yes" ]]; then
      log_warn "$(_t "SITE_CF_ONLY_WARN_REAL_IP")"
      return 0
    fi
  fi
  if cf_only_realip_write disable; then
    log_success "$(_t "SITE_CF_ONLY_REALIP_DONE" "$CF_ONLY_NGINX_CONF" "${CF_ONLY_BACKUP_DIR}/nginx.conf")"
  else
    log_warn "$(_t "SITE_CF_ONLY_WARN_REAL_IP")"
  fi
  return 0
}

# cf_only_realip_maybe_restore：關閉 cf-only 後呼叫；已沒有任何網站開啟、且該行是 clp 註解的，才詢問是否恢復（預設不恢復）
#   -y 或非 TTY 時不恢復，只說明手動恢復的方法
cf_only_realip_maybe_restore() {
  [[ "$(cf_only_realip_state)" == "clp" ]] || return 0
  if cf_only_py db-get "$CF_ONLY_DB" 2>/dev/null | cut -f2 | grep -qx 1; then
    return 0
  fi
  # 仍有網站使用 httpauth IP 白名單時不提議恢復，否則白名單會再次可被繞過
  if clp_realip_whitelists_exist; then
    log_info "$(_t "SITE_CF_ONLY_REALIP_KEEP_WHITELIST" "$CF_ONLY_NGINX_CONF")"
    return 0
  fi
  if has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]] || [[ ! -t 0 ]]; then
    log_info "$(_t "SITE_CF_ONLY_REALIP_RESTORE_INFO" "$CF_ONLY_NGINX_CONF")"
    return 0
  fi
  local ans=""
  read -r -p "$(_t "SITE_CF_ONLY_REALIP_RESTORE_PROMPT")" ans || ans=""
  if [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]; then
    cf_only_realip_write restore && log_success "$(_t "SITE_CF_ONLY_REALIP_RESTORED" "$CF_ONLY_NGINX_CONF")"
  else
    log_info "$(_t "SITE_CF_ONLY_REALIP_RESTORE_INFO" "$CF_ONLY_NGINX_CONF")"
  fi
  return 0
}

# cf_only_firewall_check：UFW 沒啟用，或明確開放 8080（nginx backend）／6081（Varnish）時警告——直連這些埠不受 cf-only 限制
cf_only_firewall_check() {
  if ! command -v ufw >/dev/null 2>&1 || ! LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    log_warn "$(_t "SITE_CF_ONLY_WARN_FIREWALL_OFF")"
    return 0
  fi
  # verbose 才會顯示預設政策；預設允許連入時 8080／6081 都對外開放
  local port st
  st=$(LC_ALL=C ufw status verbose 2>/dev/null || true)
  for port in 8080 6081; do
    if grep -qE '^Default:.*allow \(incoming\)' <<< "$st" || awk -v p="$port" '
      $0 ~ /ALLOW/ {
        split($1, a, "/"); n = split(a[1], items, ",")
        for (i = 1; i <= n; i++) {
          spec = items[i]
          if (spec == p) { found = 1 }
          else if (index(spec, ":") > 0) {
            split(spec, r, ":"); if (p + 0 >= r[1] + 0 && p + 0 <= r[2] + 0) found = 1
          }
        }
      }
      END { exit found ? 0 : 1 }
    ' <<< "$st"; then
      log_warn "$(_t "SITE_CF_ONLY_WARN_FIREWALL_PORT" "$port")"
    fi
  done
  return 0
}

# cf_only_realip_status：顯示該行狀態（-cf-only=status 用）
cf_only_realip_status() {
  local st key
  st=$(cf_only_realip_state)
  case "$st" in
    active) key="SITE_CF_ONLY_REALIP_STATE_ACTIVE" ;;
    clp) key="SITE_CF_ONLY_REALIP_STATE_CLP" ;;
    *) key="SITE_CF_ONLY_REALIP_STATE_NONE" ;;
  esac
  if [[ "$st" == "active" ]]; then
    log_warn "$(_t "SITE_CF_ONLY_REALIP_STATE" "$(_t "$key")")"
  else
    log_info "$(_t "SITE_CF_ONLY_REALIP_STATE" "$(_t "$key")")"
  fi
  local hdr
  hdr=$(cf_only_realip_header)
  [[ -n "$hdr" ]] && log_warn "$(_t "SITE_CF_ONLY_REALIP_ERR_HEADER" "$hdr" "$CF_ONLY_NGINX_CONF")"
  return 0
}

# cf_only_backup_init：本次執行的備份目錄（vhost 副本、資料庫欄位原值、資料庫備份）；資料庫備份只保留最近 3 份
cf_only_backup_init() {
  [[ -n "$CF_ONLY_BACKUP_DIR" ]] && return 0
  local base="/root/.clp/cf-only-backup" dir
  dir="${base}/$(date +%Y%m%d_%H%M%S)"
  ( umask 077; mkdir -p "$dir" ) || return 1
  # 資料庫備份成功後才記錄目錄：失敗時下一個網站要重新嘗試，不可在沒有備份的情況下繼續修改
  if ! ( umask 077; cf_only_py db-backup "$CF_ONLY_DB" "${dir}/db.sq3" ); then
    log_error "$(_t "SITE_CF_ONLY_ERR_DB_BACKUP")"
    return 1
  fi
  CF_ONLY_BACKUP_DIR="$dir"
  chmod 600 "${CF_ONLY_BACKUP_DIR}/db.sq3" 2>/dev/null || true
  local old
  while IFS= read -r old; do
    rm -f "${old}/db.sq3"
  done < <(find "$base" -mindepth 2 -maxdepth 2 -name db.sq3 -printf '%h\n' 2>/dev/null | sort -r | tail -n +4)
  log_info "$(_t "SITE_CF_ONLY_INFO_BACKUP" "$CF_ONLY_BACKUP_DIR")"
}

# cf_only_dns_check <domain>：網域與 www／非 www 對應名稱的 A／AAAA 記錄必須全部在 Cloudflare 範圍內
cf_only_dns_check() {
  local domain="$1" out rc=0 name addr res
  out=$(cf_only_py dns-check "$domain" "$CF_ONLY_IPS" 2>&1) || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    log_error "$out"
    return 1
  fi
  local any=0
  while IFS=$'\t' read -r name addr res; do
    [[ -z "$name" ]] && continue
    case "$res" in
      ok) any=1 ;;
      bad) any=1; log_warn "$(_t "SITE_CF_ONLY_DNS_BAD" "$name" "$addr")" ;;
      none) ;;
    esac
  done <<< "$out"
  if [[ "$rc" -eq 1 ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_DNS" "$domain")"
    return 1
  fi
  [[ "$any" -eq 0 ]] && log_info "$(_t "SITE_CF_ONLY_INFO_DNS_NONE" "$domain")"
  return 0
}

# cf_only_apply <domain> <on|off> <force:0|1> <dry_run:0|1>
#   設定 CF_ONLY_RESULT=changed|already|dry-run|failed；失敗時回傳 1
cf_only_apply() {
  local domain="$1" action="$2" force="$3" dry_run="$4"
  CF_ONLY_RESULT="failed"
  local vhost="/etc/nginx/sites-enabled/${domain}.conf"
  if [[ ! -f "$vhost" ]]; then
    if [[ -f "/etc/nginx/sites-available/${domain}.conf" ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_DISABLED" "$domain" "$domain")"
    else
      log_error "$(_t "SITE_CF_ONLY_ERR_NO_VHOST" "$vhost")"
    fi
    return 1
  fi

  local st_out st_rc=0 vstate names
  st_out=$(cf_only_py vhost-status "$vhost" 2>&1) || st_rc=$?
  if [[ "$st_rc" -ne 0 ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_STRUCTURE" "$vhost" "$st_out")"
    return 1
  fi
  vstate=$(sed -n 1p <<< "$st_out")
  names=$(sed -n 2p <<< "$st_out")
  local want_db=0
  [[ "$action" == "on" ]] && want_db=1
  local db_val
  db_val=$(cf_only_py db-get "$CF_ONLY_DB" "$domain" 2>/dev/null | cut -f2)
  if [[ -z "$db_val" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NOT_IN_DB" "$domain")"
    return 1
  fi

  if [[ "$vstate" == "$action" && "$db_val" == "$want_db" ]]; then
    log_info "$(_t "SITE_CF_ONLY_INFO_ALREADY" "$domain" "$action")"
    CF_ONLY_RESULT="already"
    return 0
  fi

  if [[ "$action" == "on" ]]; then
    if [[ "$force" -eq 1 ]]; then
      log_warn "$(_t "SITE_CF_ONLY_WARN_FORCE" "$domain")"
    elif ! cf_only_dns_check "$domain"; then
      return 1
    fi
    # 主要網域與 www 以外的 server_name（例如 CloudPanel 測試用的 www1.*）不檢查，只提醒
    local n base="${domain#www.}" others=() name_list=()
    # read -a 只依空白分割，不做萬用字元展開（*.example.com 不可展開成目前目錄的檔名）
    read -r -a name_list <<< "$names"
    for n in ${name_list[@]+"${name_list[@]}"}; do
      [[ "$n" == "$base" || "$n" == "www.${base}" ]] || others+=("$n")
    done
    [[ ${#others[@]} -gt 0 ]] && log_info "$(_t "SITE_CF_ONLY_INFO_OTHER_NAMES" "${others[*]}")"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_CF_ONLY_INFO_DRY_RUN" "$domain" "$action")"
    CF_ONLY_RESULT="dry-run"
    return 0
  fi

  cf_only_backup_init || return 1
  local vbak="${CF_ONLY_BACKUP_DIR}/${domain}.conf"
  cp -p "$vhost" "$vbak" || return 1

  # 1. vhost（已是目標狀態時只同步資料庫）
  local vhost_changed=0
  if [[ "$vstate" != "$action" ]]; then
    local tmp set_rc=0
    tmp=$(mktemp "${CF_ONLY_BACKUP_DIR}/.vhost.XXXXXX") || return 1
    cf_only_py vhost-set "$action" "$vhost" "$tmp" 2> "${tmp}.err" || set_rc=$?
    if [[ "$set_rc" -ne 0 && "$set_rc" -ne 3 ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_STRUCTURE" "$vhost" "$(cat "${tmp}.err")")"
      rm -f "$tmp" "${tmp}.err"
      return 1
    fi
    if [[ "$set_rc" -eq 0 ]]; then
      if ! atomic_replace "$tmp" "$vhost"; then
        rm -f "$tmp" "${tmp}.err"
        return 1
      fi
      vhost_changed=1
    fi
    rm -f "$tmp" "${tmp}.err"

    if [[ "$vhost_changed" -eq 1 ]]; then
      if ! nginx -t >/dev/null 2>&1; then
        log_error "$(_t "SITE_CF_ONLY_ERR_NGINX_TEST" "$domain")"
        atomic_replace "$vbak" "$vhost" || log_error "$(_t "SITE_CF_ONLY_ERR_RESTORE" "$vbak" "$vhost")"
        return 1
      fi
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
    fi
  fi

  # 2. CloudPanel 資料庫
  if [[ "$db_val" != "$want_db" ]]; then
    local prev
    if ! prev=$(cf_only_py db-set "$CF_ONLY_DB" "$domain" "$want_db" 2>&1); then
      log_error "$(_t "SITE_CF_ONLY_ERR_DB_SET" "$domain" "$prev")"
      # vhost 有改過才還原；訊息依實際結果顯示
      if [[ "$vhost_changed" -eq 1 ]]; then
        if atomic_replace "$vbak" "$vhost"; then
          log_info "$(_t "SITE_CF_ONLY_INFO_VHOST_RESTORED" "$domain")"
        else
          log_error "$(_t "SITE_CF_ONLY_ERR_RESTORE" "$vbak" "$vhost")"
        fi
        nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true; }
      fi
      return 1
    fi
    printf '%s\t%s\n' "$domain" "$prev" >> "${CF_ONLY_BACKUP_DIR}/db-previous-values.tsv"
  fi

  log_success "$(_t "SITE_CF_ONLY_SUCCESS" "$domain" "$action")"
  CF_ONLY_RESULT="changed"
  return 0
}

# cf_only_status_line <domain>：輸出 "<db>\t<vhost>\t<dns>"
cf_only_status_line() {
  local domain="$1" db vstate dns="-"
  db=$(cf_only_py db-get "$CF_ONLY_DB" "$domain" 2>/dev/null | cut -f2)
  [[ -z "$db" ]] && db="?"
  local vhost="/etc/nginx/sites-enabled/${domain}.conf"
  if [[ -f "$vhost" ]]; then
    vstate=$(cf_only_py vhost-status "$vhost" 2>/dev/null | sed -n 1p) || true
    [[ -z "$vstate" ]] && vstate="error"
  elif [[ -f "/etc/nginx/sites-available/${domain}.conf" ]]; then
    vstate="disabled"
  else
    vstate="missing"
  fi
  local out rc=0
  out=$(cf_only_py dns-check "$domain" "$CF_ONLY_IPS" 2>/dev/null) || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    dns="bad"
  elif [[ "$rc" -eq 0 ]]; then
    if grep -q $'\tok$' <<< "$out"; then dns="ok"; else dns="none"; fi
  fi
  printf '%s\t%s\t%s\n' "$db" "$vstate" "$dns"
}

cf_only_status() {
  local domain="$1"
  cf_only_realip_status
  cf_only_firewall_check
  local -a domains=()
  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    # 先取得清單再處理：讀取 CloudPanel 資料庫失敗時不可當成「沒有網站」
    local site_list
    site_list=$(cf_only_py db-get "$CF_ONLY_DB") || { log_error "$(_t "SITE_ERR_LIST_SITES" "$CF_ONLY_DB")"; return 1; }
    while IFS=$'\t' read -r d _; do
      [[ -n "$d" ]] && domains+=("$d")
    done <<< "$site_list"
  fi
  echo ""
  printf "%-40s %-6s %-9s %-6s %s\n" "$(_t "SITE_CF_ONLY_COL_DOMAIN")" "DB" "vhost" "DNS" "$(_t "SITE_CF_ONLY_COL_NOTE")"
  echo "----------------------------------------------------------------------------------------"
  local d line db vs dns note
  for d in "${domains[@]}"; do
    line=$(cf_only_status_line "$d")
    IFS=$'\t' read -r db vs dns <<< "$line"
    note=""
    if [[ "$vs" == "on" || "$vs" == "off" ]]; then
      if { [[ "$vs" == "on" ]] && [[ "$db" != "1" ]]; } || { [[ "$vs" == "off" ]] && [[ "$db" != "0" ]]; }; then
        note="$(_t "SITE_CF_ONLY_NOTE_MISMATCH")"
      fi
    elif [[ "$vs" == "mixed" ]]; then
      note="$(_t "SITE_CF_ONLY_NOTE_MIXED")"
    fi
    if [[ "$vs" != "on" && "$dns" == "bad" ]]; then
      note="${note:+$note; }$(_t "SITE_CF_ONLY_NOTE_DNS_BAD")"
    fi
    printf "%-40s %-6s %-9s %-6s %s\n" "$d" "$db" "$vs" "$dns" "$note"
  done
  echo ""
  if [[ -n "$domain" ]]; then
    cf_only_py dns-check "$domain" "$CF_ONLY_IPS" 2>/dev/null | sed 's/^/    /' || true
  fi
  return 0
}

# cf_only_batch <on|off> <dry_run> <force>
#   使用者在確認時取消會設定 CF_ONLY_BATCH_CANCELLED=1（之後不再處理 nginx.conf）
CF_ONLY_BATCH_CANCELLED=0
cf_only_batch() {
  local action="$1" dry_run="$2" force="$3"
  local -a todo=() skipped=() ex_patterns=()
  local exclude
  exclude=$(opt_get "exclude" "")
  [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
  local d line db vs dns pat
  # 先取得清單再處理：讀取 CloudPanel 資料庫失敗時不可當成「沒有網站」而回報成功
  local batch_list
  batch_list=$(cf_only_py db-get "$CF_ONLY_DB") || { log_error "$(_t "SITE_ERR_LIST_SITES" "$CF_ONLY_DB")"; return 1; }
  while IFS=$'\t' read -r d _; do
    [[ -z "$d" ]] && continue
    local excluded=0
    for pat in ${ex_patterns[@]+"${ex_patterns[@]}"}; do
      if domain_matches_exclude "$d" "$pat"; then excluded=1; break; fi
    done
    [[ "$excluded" -eq 1 ]] && continue
    line=$(cf_only_status_line "$d")
    IFS=$'\t' read -r db vs dns <<< "$line"
    if [[ "$vs" == "disabled" || "$vs" == "missing" || "$vs" == "error" ]]; then
      skipped+=("${d} (${vs})")
      continue
    fi
    local want_db=0
    [[ "$action" == "on" ]] && want_db=1
    if [[ "$vs" == "$action" && "$db" == "$want_db" ]]; then
      continue
    fi
    if [[ "$action" == "on" && "$dns" == "bad" && "$force" -eq 0 ]]; then
      skipped+=("${d} ($(_t "SITE_CF_ONLY_NOTE_DNS_BAD"))")
      continue
    fi
    todo+=("$d")
  done <<< "$batch_list"

  echo ""
  log_info "$(_t "SITE_CF_ONLY_BATCH_TODO" "$action" "${#todo[@]}")"
  for d in "${todo[@]}"; do echo "    $d"; done
  if [[ ${#skipped[@]} -gt 0 ]]; then
    log_info "$(_t "SITE_CF_ONLY_BATCH_SKIPPED" "${#skipped[@]}")"
    for d in "${skipped[@]}"; do echo "    $d"; done
  fi
  [[ ${#todo[@]} -eq 0 ]] && return 0
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_CF_ONLY_BATCH_DRY_RUN")"
    return 0
  fi

  if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_NON_TTY")"
      return 1
    fi
    local confirm=""
    read -r -p "$(_t "SITE_CF_ONLY_BATCH_PROMPT" "${#todo[@]}")" confirm || confirm=""
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
      log_info "$(_t "SITE_CF_ONLY_CANCELLED")"
      CF_ONLY_BATCH_CANCELLED=1
      return 0
    fi
  fi

  local ok=0 failed=()
  for d in "${todo[@]}"; do
    echo -e "\n${C_CYAN}>>> ${d}${C_NC}"
    # DNS 已在清單階段檢查過；-force 時略過
    if cf_only_apply "$d" "$action" "$force" 0; then
      ok=$((ok + 1))
    else
      failed+=("$d")
    fi
  done
  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    log_success "$(_t "SITE_CF_ONLY_BATCH_DONE" "$ok" "${#todo[@]}")"
    return 0
  fi
  log_error "$(_t "SITE_CF_ONLY_BATCH_PARTIAL" "$ok" "${#todo[@]}" "${failed[*]}")"
  return 1
}

# site_cf_only <domain>
#   clp site <domain> -cf-only[=on|off|status]
#   clp site -cf-only=status
#   clp site -cf-only[=off] -all [-exclude=<patterns>] [-dry-run] [-y] [-force]
site_cf_only() {
  local domain
  domain=$(clean_domain "${1:-}")
  local val
  val=$(opt_get "cf_only" "$(opt_get "cf-only" "")")
  val=$(echo "$val" | tr '[:upper:]' '[:lower:]')
  local action
  case "$val" in
    ""|true|on) action="on" ;;
    off) action="off" ;;
    status) action="status" ;;
    *)
      log_error "$(_t "SITE_CF_ONLY_ERR_VALUE" "$val")"
      return 1
      ;;
  esac
  local all=0 dry_run=0 force=0
  has_opt "all" && all=1
  { has_opt "dry-run" || has_opt "dry_run"; } && dry_run=1
  has_opt "force" && force=1

  cf_only_precheck || return 1

  if [[ "$action" == "status" ]]; then
    if [[ -n "$domain" && "$all" -eq 0 ]]; then
      require_site_exists "$domain" "-cf-only" || return 1
    fi
    [[ "$all" -eq 1 ]] && domain=""
    cf_only_status "$domain"
    return $?
  fi

  if [[ "$all" -eq 1 ]]; then
    if [[ -n "$domain" ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_ALL_WITH_DOMAIN")"
      return 1
    fi
    local brc=0
    if [[ "$action" == "on" ]]; then
      cf_only_realip_check_header || return 1
      [[ "$dry_run" -eq 1 ]] || cf_only_realip_need_confirm || return 1
      cf_only_batch "$action" "$dry_run" "$force" || brc=$?
      [[ "$CF_ONLY_BATCH_CANCELLED" -eq 1 ]] && return 0
      # 整批只處理一次 nginx.conf；沒有任何網站是 on（全部失敗）時不修改
      if cf_only_py db-get "$CF_ONLY_DB" 2>/dev/null | cut -f2 | grep -qx 1 || [[ "$dry_run" -eq 1 ]]; then
        cf_only_realip_disable "$dry_run"
      fi
      cf_only_firewall_check
    else
      cf_only_batch "$action" "$dry_run" "$force" || brc=$?
      [[ "$dry_run" -eq 1 || "$CF_ONLY_BATCH_CANCELLED" -eq 1 ]] || cf_only_realip_maybe_restore
    fi
    return "$brc"
  fi

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_USAGE")"
    return 1
  fi
  require_site_exists "$domain" "-cf-only" || return 1
  if [[ "$action" == "on" ]]; then
    cf_only_realip_check_header || return 1
    [[ "$dry_run" -eq 1 ]] || cf_only_realip_need_confirm || return 1
    cf_only_apply "$domain" "$action" "$force" "$dry_run" || return 1
    # 網站已經是 on 時也處理（讓先前已開啟的主機補上）
    cf_only_realip_disable "$dry_run"
    cf_only_firewall_check
    return 0
  fi
  cf_only_apply "$domain" "$action" "$force" "$dry_run" || return 1
  [[ "$dry_run" -eq 1 ]] || cf_only_realip_maybe_restore
  return 0
}

# ------------------------------------------------------------------------------
# Varnish 快取診斷與修正 (clp site -varnish=status|fix)
#   CloudPanel 的 Varnish 只快取 PHP 送出 Cache-Control 的頁面，這些 header 由
#   /home/<user>/.varnish-cache/controller.php 送出，必須經由 auto_prepend_file 載入：
#   vhost 8080 區塊的 PHP_VALUE 要有那一行；若 Wordfence 的 .user.ini 改用 wordfence-waf.php，
#   wordfence-waf.php 也要 include controller.php。
# ------------------------------------------------------------------------------
VARNISH_DB="/home/clp/htdocs/app/data/db.sq3"
VARNISH_BACKUP_DIR=""

varnish_py() {
  python3 -I "${CLP_LIB_DIR}/varnish_fix.py" "$@"
}

# varnish_diagnose <domain>：設定 VD_* 變數；失敗回傳 1
varnish_diagnose() {
  local domain="$1" out rc=0
  # 先重設所有欄位：失敗時不可沿用上一個網站的值，也不可留下未定義的變數（set -u）
  VD_TYPE="" VD_DB="" VD_SETTINGS="" VD_FRONT="" VD_VHOST="" VD_USERINI="" VD_WFWAF="" VD_CACHED="" VD_CONCLUSION="" VD_USER="" VD_ROOT=""
  out=$(varnish_py diagnose "$VARNISH_DB" "$domain" 2>&1) || rc=$?
  VD_ERROR=""
  if [[ "$rc" -ne 0 ]]; then
    VD_ERROR="$out"
    VD_CONCLUSION="error"
    return 1
  fi
  local k v
  VD_TYPE="" VD_DB="" VD_SETTINGS="" VD_FRONT="" VD_VHOST="" VD_USERINI="" VD_WFWAF="" VD_CACHED="" VD_CONCLUSION="" VD_USER="" VD_ROOT=""
  while IFS='=' read -r k v; do
    case "$k" in
      type) VD_TYPE="$v" ;; varnish_db) VD_DB="$v" ;; settings) VD_SETTINGS="$v" ;; front) VD_FRONT="$v" ;;
      vhost) VD_VHOST="$v" ;; userini) VD_USERINI="$v" ;; wfwaf) VD_WFWAF="$v" ;;
      cached) VD_CACHED="$v" ;; conclusion) VD_CONCLUSION="$v" ;; user) VD_USER="$v" ;; root) VD_ROOT="$v" ;;
    esac
  done <<< "$out"
}

varnish_conclusion_text() {
  case "$1" in
    ok) _t "SITE_VARNISH_C_OK" ;;
    fix-vhost) _t "SITE_VARNISH_C_FIX_VHOST" ;;
    fix-wfwaf) _t "SITE_VARNISH_C_FIX_WFWAF" ;;
    fix-both) _t "SITE_VARNISH_C_FIX_BOTH" ;;
    off) _t "SITE_VARNISH_C_OFF" ;;
    off-db) _t "SITE_VARNISH_C_OFF_DB" ;;
    not-php) _t "SITE_VARNISH_C_NOT_PHP" ;;
    disabled-site) _t "SITE_VARNISH_C_DISABLED" ;;
    skip-other) _t "SITE_VARNISH_C_SKIP_OTHER" ;;
    skip-vhost) _t "SITE_VARNISH_C_SKIP_VHOST" ;;
    save-vhost) _t "SITE_VARNISH_C_SAVE_VHOST" ;;
    skip-front) _t "SITE_VARNISH_C_SKIP_FRONT" ;;
    unknown) _t "SITE_VARNISH_C_UNKNOWN" ;;
    *) _t "SITE_VARNISH_C_ERROR" ;;
  esac
}

varnish_print_row() {
  local domain="$1"
  printf "%-32s %-9s %-6s %-8s %-10s %-9s %-6s %s\n" "$domain" "${VD_SETTINGS:--}" "${VD_FRONT:--}" "${VD_VHOST:--}" \
    "$(ui="${VD_USERINI:--}"; echo "${ui%%:*}")" "${VD_WFWAF:--}" "${VD_CACHED:--}" "$(varnish_conclusion_text "$VD_CONCLUSION")"
}

varnish_print_header() {
  echo ""
  printf "%-32s %-9s %-6s %-8s %-10s %-9s %-6s %s\n" "Domain" "settings" "front" "vhost" ".user.ini" "wf-waf" "cached" "$(_t "SITE_VARNISH_COL_RESULT")"
  echo "---------------------------------------------------------------------------------------------------------------"
}

varnish_backup_init() {
  [[ -n "$VARNISH_BACKUP_DIR" ]] && return 0
  VARNISH_BACKUP_DIR="/root/.clp/varnish-backup/$(date +%Y%m%d_%H%M%S)"
  ( umask 077; mkdir -p "$VARNISH_BACKUP_DIR" ) || return 1
  log_info "$(_t "SITE_CF_ONLY_INFO_BACKUP" "$VARNISH_BACKUP_DIR")"
}

# varnish_fix_site <domain> <dry_run>：依診斷結論修正；設定 VF_RESULT=fixed|nothing|dry-run|skipped|failed
varnish_fix_site() {
  local domain="$1" dry_run="$2"
  VF_RESULT="failed"
  if ! varnish_diagnose "$domain"; then
    log_error "$VD_ERROR"
    return 1
  fi
  local before="$VD_CONCLUSION"
  case "$before" in
    ok)
      log_info "$(_t "SITE_VARNISH_INFO_ALREADY_OK" "$domain")"
      VF_RESULT="nothing"; return 0 ;;
    fix-vhost|fix-wfwaf|fix-both) ;;
    *)
      log_warn "$(_t "SITE_VARNISH_WARN_NOT_FIXABLE" "$domain" "$(varnish_conclusion_text "$before")")"
      VF_RESULT="skipped"; return 0 ;;
  esac
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_VARNISH_INFO_DRY_RUN" "$domain" "$(varnish_conclusion_text "$before")")"
    VF_RESULT="dry-run"; return 0
  fi
  varnish_backup_init || return 1
  local bdir="${VARNISH_BACKUP_DIR}/${domain}"
  ( umask 077; mkdir -p "$bdir" ) || return 1

  # 1. vhost
  if [[ "$before" == "fix-vhost" || "$before" == "fix-both" ]]; then
    local vhost="/etc/nginx/sites-enabled/${domain}.conf"
    cp -p "$vhost" "${bdir}/${domain}.conf" || return 1
    local tmp rc=0
    tmp=$(mktemp "${bdir}/.vhost.XXXXXX") || return 1
    varnish_py fix-vhost "$vhost" "/home/${VD_USER}/.varnish-cache/controller.php" "$tmp" 2> "${tmp}.err" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      if ! atomic_replace "$tmp" "$vhost"; then
        rm -f "$tmp" "${tmp}.err"; return 1
      fi
      if ! nginx -t >/dev/null 2>&1; then
        log_error "$(_t "SITE_VARNISH_ERR_NGINX_TEST" "$domain")"
        atomic_replace "${bdir}/${domain}.conf" "$vhost" || log_error "$(_t "SITE_CF_ONLY_ERR_RESTORE" "${bdir}/${domain}.conf" "$vhost")"
        rm -f "$tmp" "${tmp}.err"; return 1
      fi
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
      log_success "$(_t "SITE_VARNISH_OK_VHOST" "$domain")"
    elif [[ "$rc" -ne 3 ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_STRUCTURE" "$vhost" "$(cat "${tmp}.err")")"
      rm -f "$tmp" "${tmp}.err"; return 1
    fi
    rm -f "$tmp" "${tmp}.err"
  fi

  # 2. wordfence-waf.php（不修改 .user.ini）
  if [[ "$before" == "fix-wfwaf" || "$before" == "fix-both" ]]; then
    local err rc=0
    err=$(varnish_py fix-wfwaf "$VD_ROOT" "$VD_USER" "$bdir" 2>&1) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      [[ -n "$err" ]] && log_warn "$err"
      log_success "$(_t "SITE_VARNISH_OK_WFWAF" "$domain")"
    elif [[ "$rc" -ne 3 ]]; then
      log_error "$(_t "SITE_VARNISH_ERR_WFWAF" "$domain" "$err")"
      return 1
    fi
  fi

  # 3. 重新檢查實際結果（nginx reload 為非同步；opcache.revalidate_freq 也可能讓
  #    剛改的 wordfence-waf.php 晚幾秒才生效，所以最多重試 5 次、每次間隔 2 秒）
  local after="" i
  for i in 1 2 3 4 5; do
    sleep 2
    after=$(varnish_py probe "$domain" 2>/dev/null || echo error)
    [[ "$after" == "yes" ]] && break
  done
  if [[ "$after" == "yes" ]]; then
    log_success "$(_t "SITE_VARNISH_OK_CACHED" "$domain")"
    VF_RESULT="fixed"; return 0
  fi
  log_warn "$(_t "SITE_VARNISH_WARN_STILL_NOT_CACHED" "$domain" "$VARNISH_BACKUP_DIR")"
  VF_RESULT="fixed"
  return 1
}

# varnish_warn_save_vhost <domain>...：列出前端沒有經過 Varnish、要在 CloudPanel 後台儲存 vhost 的網站（clp 不修改前端）
varnish_warn_save_vhost() {
  [[ $# -eq 0 ]] && return 0
  log_warn "$(_t "SITE_VARNISH_WARN_SAVE_VHOST" "$*")"
}

varnish_status() {
  local domain="$1"
  local -a domains=()
  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    local site_list
    site_list=$(varnish_py list "$VARNISH_DB") || { log_error "$(_t "SITE_ERR_LIST_SITES" "$VARNISH_DB")"; return 1; }
    while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done <<< "$site_list"
  fi
  varnish_print_header
  local d
  local -a save=()
  for d in "${domains[@]}"; do
    varnish_diagnose "$d" || true
    varnish_print_row "$d"
    [[ "$VD_CONCLUSION" == "save-vhost" ]] && save+=("$d")
  done
  echo ""
  varnish_warn_save_vhost ${save[@]+"${save[@]}"}
  if [[ -n "$domain" && -n "$VD_ERROR" ]]; then
    log_error "$VD_ERROR"
    return 1
  fi
  return 0
}

# varnish_check_class <conclusion>：-check 的分類 ok | off | problem（not-php 不屬於任何一類，輸出空字串）
varnish_check_class() {
  case "$1" in
    ok) echo "ok" ;;
    off|off-db|disabled-site) echo "off" ;;
    not-php) echo "" ;;
    *) echo "problem" ;;
  esac
}

# varnish_check <domain> <filter>：給其他 script 用；stdout 每行「網域<TAB>結論代碼」，不印表格、顏色與語系文字
#   filter：ok | off | problem，可用逗號組合
#   回傳 0＝正常、1＝filter 含 problem 且有符合的網站、2＝執行失敗
varnish_check() {
  local domain="$1" filter="$2" f pat d
  local want_ok=0 want_off=0 want_problem=0
  local -a parts=() domains=() ex_patterns=()
  IFS=',' read -ra parts <<< "$filter"
  for f in ${parts[@]+"${parts[@]}"}; do
    f=$(echo "$f" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$f" in
      ok) want_ok=1 ;;
      off) want_off=1 ;;
      problem) want_problem=1 ;;
      *) log_error "$(_t "SITE_VARNISH_ERR_CHECK_VALUE" "$f")"; return 2 ;;
    esac
  done
  if [[ $((want_ok + want_off + want_problem)) -eq 0 ]]; then
    log_error "$(_t "SITE_VARNISH_ERR_CHECK_VALUE" "$filter")"; return 2
  fi

  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    local list rc=0
    list=$(varnish_py list "$VARNISH_DB") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log_error "$list"; return 2
    fi
    local exclude
    exclude=$(opt_get "exclude" "")
    [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      local excluded=0
      for pat in ${ex_patterns[@]+"${ex_patterns[@]}"}; do
        if domain_matches_exclude "$d" "$pat"; then excluded=1; break; fi
      done
      [[ "$excluded" -eq 0 ]] && domains+=("$d")
    done <<< "$list"
  fi

  local cls found=0
  for d in ${domains[@]+"${domains[@]}"}; do
    if ! varnish_diagnose "$d"; then
      log_warn "${d}: ${VD_ERROR}"
    fi
    cls=$(varnish_check_class "$VD_CONCLUSION")
    case "$cls" in
      ok) [[ "$want_ok" -eq 1 ]] && printf '%s\t%s\n' "$d" "$VD_CONCLUSION" ;;
      off) [[ "$want_off" -eq 1 ]] && printf '%s\t%s\n' "$d" "$VD_CONCLUSION" ;;
      problem)
        if [[ "$want_problem" -eq 1 ]]; then
          printf '%s\t%s\n' "$d" "$VD_CONCLUSION"
          found=1
        fi
        ;;
    esac
  done
  [[ "$found" -eq 1 ]] && return 1
  return 0
}

varnish_batch_fix() {
  local dry_run="$1"
  local exclude pat d
  exclude=$(opt_get "exclude" "")
  local -a ex_patterns=() todo=() save=()
  [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
  local site_list
  site_list=$(varnish_py list "$VARNISH_DB") || { log_error "$(_t "SITE_ERR_LIST_SITES" "$VARNISH_DB")"; return 1; }
  varnish_print_header
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local excluded=0
    for pat in ${ex_patterns[@]+"${ex_patterns[@]}"}; do
      if domain_matches_exclude "$d" "$pat"; then excluded=1; break; fi
    done
    [[ "$excluded" -eq 1 ]] && continue
    varnish_diagnose "$d" || true
    varnish_print_row "$d"
    case "$VD_CONCLUSION" in fix-vhost|fix-wfwaf|fix-both) todo+=("$d") ;; save-vhost) save+=("$d") ;; esac
  done <<< "$site_list"
  echo ""
  varnish_warn_save_vhost ${save[@]+"${save[@]}"}
  log_info "$(_t "SITE_VARNISH_BATCH_TODO" "${#todo[@]}")"
  [[ ${#todo[@]} -eq 0 ]] && return 0
  log_warn "$(_t "SITE_VARNISH_WARN_CACHE_START")"
  if [[ "$dry_run" -eq 1 ]]; then
    log_info "$(_t "SITE_CF_ONLY_BATCH_DRY_RUN")"
    return 0
  fi
  if ! has_opt "y" && ! has_opt "yes" && [[ "${CLP_AUTO_YES:-false}" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      log_error "$(_t "SITE_CF_ONLY_ERR_NON_TTY")"
      return 1
    fi
    local confirm=""
    read -r -p "$(_t "SITE_CF_ONLY_BATCH_PROMPT" "${#todo[@]}")" confirm || confirm=""
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
      log_info "$(_t "SITE_CF_ONLY_CANCELLED")"
      return 0
    fi
  fi
  local ok=0 failed=()
  for d in "${todo[@]}"; do
    echo -e "\n${C_CYAN}>>> ${d}${C_NC}"
    if varnish_fix_site "$d" 0; then ok=$((ok + 1)); else failed+=("$d"); fi
  done
  echo ""
  if [[ ${#failed[@]} -eq 0 ]]; then
    log_success "$(_t "SITE_CF_ONLY_BATCH_DONE" "$ok" "${#todo[@]}")"
    return 0
  fi
  log_error "$(_t "SITE_CF_ONLY_BATCH_PARTIAL" "$ok" "${#todo[@]}" "${failed[*]}")"
  return 1
}

# site_varnish <domain>
#   clp site <domain> -varnish=status | -varnish=fix [-dry-run]
#   clp site -varnish=status
#   clp site -varnish=fix -all [-exclude=...] [-dry-run] [-y]
#   clp site [<domain>] -varnish=status -check[=ok|off|problem[,...]] [-exclude=...]（見 varnish_check）
site_varnish() {
  local domain
  domain=$(clean_domain "${1:-}")
  local val
  val=$(echo "$(opt_get "varnish" "")" | tr '[:upper:]' '[:lower:]')
  local all=0 dry_run=0 check="" err_rc=1
  has_opt "all" && all=1
  { has_opt "dry-run" || has_opt "dry_run"; } && dry_run=1
  if has_opt "check"; then
    check=$(opt_get "check" "")
    [[ -z "$check" || "$check" == "true" ]] && check="problem"
    err_rc=2
    if [[ "$val" != "status" ]]; then
      log_error "$(_t "SITE_VARNISH_ERR_USAGE")"; return 2
    fi
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"; return "$err_rc"
  fi
  if [[ ! -f "$VARNISH_DB" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_DB" "$VARNISH_DB")"; return "$err_rc"
  fi
  if [[ -n "$check" ]]; then
    local rc=0
    if [[ -n "$domain" && "$all" -eq 0 ]]; then
      require_site_exists "$domain" "-varnish" >&2 || return 2
      varnish_check "$domain" "$check" || rc=$?
    else
      varnish_check "" "$check" || rc=$?
    fi
    return "$rc"
  fi
  case "$val" in
    status)
      if [[ -n "$domain" && "$all" -eq 0 ]]; then
        require_site_exists "$domain" "-varnish" || return 1
        varnish_status "$domain"
      else
        varnish_status ""
      fi
      ;;
    fix)
      if [[ "$all" -eq 1 ]]; then
        [[ -n "$domain" ]] && { log_error "$(_t "SITE_CF_ONLY_ERR_ALL_WITH_DOMAIN")"; return 1; }
        varnish_batch_fix "$dry_run"
        return $?
      fi
      [[ -z "$domain" ]] && { log_error "$(_t "SITE_VARNISH_ERR_USAGE")"; return 1; }
      require_site_exists "$domain" "-varnish" || return 1
      varnish_status "$domain" || return 1
      varnish_fix_site "$domain" "$dry_run"
      ;;
    *)
      log_error "$(_t "SITE_VARNISH_ERR_USAGE")"
      return 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# 網站 vhost 範本與 CloudPanel 官方範本比較、更新（clp site -vhost=...，計畫 53）
#   CloudPanel 建站時把範本複製到 site.vhost_template，官方範本之後的更新不會套用到既有網站。
#   資料庫：root 只以唯讀方式讀取（vhost_tpl.py）；寫入與重新產生 vhost 由 clp 使用者以 CloudPanel
#   自己的程式執行（clp_regen.php，與後台儲存相同）。CloudPanel 版本不相容時，只更新資料庫中的範本，
#   請使用者到後台按儲存。
# ------------------------------------------------------------------------------
VHOST_DB="/home/clp/htdocs/app/data/db.sq3"
VHOST_TPL_STATE="/root/.clp/vhost-templates"
VHOST_BACKUP_BASE="/root/.clp/vhost-backup"
VHOST_STAGE=""
VHOST_PHP_BIN=""
VHOST_PHP_INI=""
VHOST_WRITER="php"
VHOST_PENDING=""

vhost_tpl_py() {
  python3 -I "${CLP_LIB_DIR}/vhost_tpl.py" "$@"
}

# vhost_stage_init：暫存目錄；呼叫端負責 vhost_stage_cleanup
#   clp 使用者只需要讀兩支輔助程式（目錄 711、程式 644）；匯出資料與新範本只有 root 可讀（600），
#   以 stdin 交給 clp 使用者
vhost_stage_init() {
  [[ -n "$VHOST_STAGE" && -d "$VHOST_STAGE" ]] && return 0
  VHOST_STAGE="$(mktemp -d /tmp/clp-vhost.XXXXXX)" || return 1
  chmod 711 "$VHOST_STAGE" || return 1
  install -m 644 "${CLP_LIB_DIR}/clp_regen.php" "${CLP_LIB_DIR}/vhost_tpl.py" "$VHOST_STAGE/" || return 1
}

vhost_stage_cleanup() {
  if [[ -n "$VHOST_STAGE" ]]; then rm -rf "$VHOST_STAGE"; fi
  VHOST_STAGE=""
}

# vhost_php_init：從 /usr/bin/clpctlWrapper 讀出 CloudPanel 使用的 PHP 與 php.ini（與 clpctl 相同）
vhost_php_init() {
  [[ -n "$VHOST_PHP_BIN" ]] && return 0
  local line
  line="$(grep -oE '/usr/bin/php[0-9.]+ -c [^ ]+' /usr/bin/clpctlWrapper 2>/dev/null | head -n1 || true)"
  [[ -n "$line" ]] || return 1
  VHOST_PHP_BIN="${line%% -c *}"
  VHOST_PHP_INI="${line#* -c }"
  [[ -x "$VHOST_PHP_BIN" && -f "$VHOST_PHP_INI" ]] || { VHOST_PHP_BIN=""; return 1; }
}

# vhost_php <mode> [<domain>]：以 clp 使用者執行 clp_regen.php；回傳 4 表示 CloudPanel 版本不相容（未寫入）
vhost_php() {
  vhost_php_init || return 4
  ( cd / && sudo -H -u clp "$VHOST_PHP_BIN" -c "$VHOST_PHP_INI" "${VHOST_STAGE}/clp_regen.php" "$@" )
}

# vhost_export：輸出 CloudPanel 網站與範本到 ${VHOST_STAGE}/export.json，並記錄目前的官方範本版本
vhost_export() {
  ( umask 077; vhost_tpl_py export --db "$VHOST_DB" > "${VHOST_STAGE}/export.json" ) || return 1
  ( umask 077; vhost_tpl_py record --state "$VHOST_TPL_STATE" < "${VHOST_STAGE}/export.json" >/dev/null ) || true
}

# vhost_status_label <status>
vhost_status_label() {
  case "$1" in
    latest) _t "SITE_VHOST_ST_LATEST" ;;
    old) _t "SITE_VHOST_ST_OLD" ;;
    custom) _t "SITE_VHOST_ST_CUSTOM" ;;
    *) _t "SITE_VHOST_ST_SKIP" ;;
  esac
}

# vhost_httpauth_state <vhost>：輸出 clp httpauth 在 vhost 中啟用的防護，每行一項：wpadmin、path <路徑>
vhost_httpauth_state() {
  local vhost="$1"
  grep -q '# --- CLP HTTPAUTH WPADMIN START ---' "$vhost" && echo "wpadmin"
  grep -q '# --- CLP HTTPAUTH ROOT START ---' "$vhost" && echo "path /"
  sed -n 's/^[[:space:]]*# --- CLP HTTPAUTH PATH: \(.*\) START ---[[:space:]]*$/path \1/p' "$vhost"
  return 0
}

# vhost_httpauth_reapply <domain> <state_file>：CloudPanel 重新產生 vhost 後，重新套用 clp 的 httpauth 防護
vhost_httpauth_reapply() {
  local domain="$1" state_file="$2" kind arg
  [[ -s "$state_file" ]] || return 0
  if ! declare -F httpauth_set_path >/dev/null; then
    # shellcheck source=/dev/null
    source "${CLP_LIB_DIR}/httpauth.sh" || return 1
  fi
  while read -r kind arg; do
    case "$kind" in
      wpadmin) httpauth_set_wp_admin "$domain" on || return 1 ;;
      path) httpauth_set_path "$domain" "$arg" on || return 1 ;;
    esac
  done < "$state_file"
}

# vhost_restore <domain> <backup_dir>：還原資料庫中的範本與 vhost 檔，nginx -t 後 reload
vhost_restore() {
  local domain="$1" bdir="$2" rc=0 vhost="/etc/nginx/sites-enabled/${1}.conf"
  if [[ "$VHOST_WRITER" == "php" ]]; then
    vhost_php set-template "$domain" < "${bdir}/site.tpl" >/dev/null || rc=1
  else
    ( cd / && sudo -H -u clp python3 -I "${VHOST_STAGE}/vhost_tpl.py" set-template --db "$VHOST_DB" --domain "$domain" \
        < "${bdir}/site.tpl" >/dev/null ) || rc=1
  fi
  if [[ -f "${bdir}/vhost.conf" ]]; then
    cp -p "${bdir}/vhost.conf" "$vhost" || rc=1
  fi
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || rc=1
  else
    rc=1
  fi
  return "$rc"
}

# vhost_update_site <domain> <template_name|""> <force 0|1>
vhost_update_site() {
  local domain="$1" name="$2" force="$3"
  local vhost="/etc/nginx/sites-enabled/${domain}.conf"
  # 已停用（vhost 不在 sites-enabled）的網站不處理：CloudPanel 重新產生時會寫入 sites-enabled，等於重新啟用
  if [[ ! -f "$vhost" ]]; then
    log_error "$(_t "SITE_VHOST_ERR_DISABLED" "$domain")"
    return 1
  fi
  local row status cur_name n
  row="$(vhost_tpl_py status --state "$VHOST_TPL_STATE" --domain "$domain" < "${VHOST_STAGE}/export.json")" || return 1
  IFS=$'\t' read -r _ status cur_name n <<< "$row"
  [[ -n "$name" ]] || name="$cur_name"
  if [[ "$status" == "skip" ]]; then
    log_error "$(_t "SITE_VHOST_ERR_NOT_PHP" "$domain")"
    return 1
  fi
  if [[ "$status" == "latest" && "$name" == "$cur_name" ]]; then
    log_success "$(_t "SITE_VHOST_INFO_LATEST" "$domain" "$name")"
    return 0
  fi
  if [[ "$status" == "custom" && "$force" -ne 1 ]]; then
    vhost_tpl_py diff --domain "$domain" --name "$name" < "${VHOST_STAGE}/export.json" || true
    log_error "$(_t "SITE_VHOST_ERR_CUSTOM" "$domain" "$name")"
    return 1
  fi

  local new_tpl="${VHOST_STAGE}/new.tpl" brc=0
  ( umask 077; vhost_tpl_py build --domain "$domain" --name "$name" < "${VHOST_STAGE}/export.json" > "$new_tpl" ) || brc=$?
  if [[ "$brc" -eq 2 ]]; then
    log_error "$(_t "SITE_VHOST_ERR_NO_TEMPLATE" "$name")"
    return 1
  elif [[ "$brc" -ne 0 ]]; then
    log_error "$(_t "SITE_VHOST_ERR_BUILD" "$domain")"
    return 1
  fi
  vhost_tpl_py diff --domain "$domain" --name "$name" < "${VHOST_STAGE}/export.json" || true
  log_info "$(_t "SITE_VHOST_INFO_REGEN_NOTE")"
  if ! prompt_confirm "$(_t "SITE_VHOST_PROMPT_UPDATE" "$domain" "$name")" "n"; then
    log_info "$(_t "CORE_PROMPT_CANCELLED")"
    return 1
  fi

  # 備份：資料庫、網站目前的範本、vhost 檔
  local bdir
  bdir="${VHOST_BACKUP_BASE}/$(date +%Y%m%d_%H%M%S)/${domain}"
  ( umask 077; mkdir -p "$bdir" ) || return 1
  if ! ( umask 077; vhost_tpl_py backup-db --db "$VHOST_DB" --dest "${bdir}/db.sq3" ) \
     || ! ( umask 077; vhost_tpl_py current --domain "$domain" < "${VHOST_STAGE}/export.json" > "${bdir}/site.tpl" ) \
     || ! cp -p "$vhost" "${bdir}/vhost.conf"; then
    log_error "$(_t "SITE_VHOST_ERR_BACKUP" "$bdir")"
    return 1
  fi
  # httpauth 狀態一定要正確記下，否則重新產生後不會重新套用、網站變成公開
  local markers=0
  markers=$(grep -c '# --- CLP HTTPAUTH \(ROOT\|WPADMIN\|PATH: .*\) START ---' "$vhost" || true)
  if ! ( umask 077; vhost_httpauth_state "$vhost" > "${bdir}/httpauth.state" ) \
     || [[ "$(grep -c . "${bdir}/httpauth.state" || true)" -ne "${markers:-0}" ]]; then
    log_error "$(_t "SITE_VHOST_ERR_BACKUP" "$bdir")"
    return 1
  fi
  log_info "$(_t "SITE_VHOST_INFO_BACKUP" "$bdir")"

  # 寫入新範本：優先用 CloudPanel 自己的程式；版本不相容（4）時改以 clp 使用者直接寫入資料庫
  local rc=0
  VHOST_WRITER="php"
  vhost_php set-template "$domain" < "$new_tpl" >/dev/null || rc=$?
  if [[ "$rc" -eq 4 ]]; then
    VHOST_WRITER="sqlite"
    rc=0
    ( cd / && sudo -H -u clp python3 -I "${VHOST_STAGE}/vhost_tpl.py" set-template --db "$VHOST_DB" --domain "$domain" \
        < "$new_tpl" >/dev/null ) || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    log_error "$(_t "SITE_VHOST_ERR_WRITE" "$domain")"
    # 確認資料庫中的範本沒有被改到；已改到（例如寫入後才失敗）就還原
    if ! vhost_export || ! vhost_tpl_py current --domain "$domain" < "${VHOST_STAGE}/export.json" | cmp -s - "${bdir}/site.tpl"; then
      log_warn "$(_t "SITE_VHOST_WARN_WRITE_PARTIAL" "$domain")"
      vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
    fi
    return 1
  fi
  # 從這裡開始到完成前被中斷（Ctrl-C、SSH 斷線）時，由 vhost_on_signal 還原
  VHOST_PENDING="${domain}|${bdir}"

  if [[ "$VHOST_WRITER" == "sqlite" ]]; then
    # 無法呼叫 CloudPanel 的程式：vhost 檔仍是舊的，請使用者到後台儲存
    VHOST_PENDING=""
    log_warn "$(_t "SITE_VHOST_WARN_SAVE_IN_PANEL" "$domain")"
    [[ -s "${bdir}/httpauth.state" ]] && log_warn "$(_t "SITE_VHOST_WARN_HTTPAUTH_AFTER_SAVE" "$domain")"
    return 0
  fi

  # 由 CloudPanel 重新產生 vhost（失敗時它會還原 vhost 檔；這裡再還原範本並確認 nginx）
  rc=0
  vhost_php regen "$domain" >/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]] || ! nginx -t >/dev/null 2>&1; then
    log_error "$(_t "SITE_VHOST_ERR_REGEN" "$domain")"
    vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
    VHOST_PENDING=""
    return 1
  fi

  # 重新產生會移除 clp 寫在 vhost 中的 httpauth 防護：重新套用，失敗就整個還原（不可讓網站變成公開）
  if [[ -s "${bdir}/httpauth.state" ]]; then
    log_info "$(_t "SITE_VHOST_INFO_HTTPAUTH_REAPPLY" "$domain")"
    if ! vhost_httpauth_reapply "$domain" "${bdir}/httpauth.state"; then
      log_error "$(_t "SITE_VHOST_ERR_HTTPAUTH" "$domain")"
      vhost_restore "$domain" "$bdir" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "$bdir")"
      VHOST_PENDING=""
      return 1
    fi
  fi
  VHOST_PENDING=""
  log_success "$(_t "SITE_VHOST_SUCCESS_UPDATED" "$domain" "$name")"
}

# vhost_on_signal：update 進行中被中斷時，還原範本與 vhost；清除暫存目錄
vhost_on_signal() {
  trap - INT TERM HUP
  if [[ -n "$VHOST_PENDING" ]]; then
    log_error "$(_t "SITE_VHOST_ERR_INTERRUPTED" "${VHOST_PENDING%%|*}")"
    vhost_restore "${VHOST_PENDING%%|*}" "${VHOST_PENDING#*|}" || log_error "$(_t "SITE_VHOST_ERR_RESTORE" "${VHOST_PENDING#*|}")"
    VHOST_PENDING=""
  fi
  vhost_stage_cleanup
  exit 130
}

# site_vhost <domain>
#   clp site <domain> -vhost=status | -vhost=diff [-template=<名稱>] | -vhost=update [-template=<名稱>] [-force] [-y]
#   clp site -vhost=status [-all]
#   clp site -vhost=record（cron 用：記錄官方範本版本，不輸出、一律回傳 0）
site_vhost() {
  local domain val name force=0 all=0 rc=0
  domain=$(clean_domain "${1:-}")
  val=$(echo "$(opt_get "vhost" "")" | tr '[:upper:]' '[:lower:]')
  name="$(opt_get "template" "")"
  [[ "$name" == "true" ]] && name=""
  has_opt "force" && force=1
  has_opt "all" && all=1

  if [[ "$val" == "record" ]]; then
    [[ -f "$VHOST_DB" ]] && command -v python3 >/dev/null 2>&1 || return 0
    ( umask 077; vhost_tpl_py export --db "$VHOST_DB" 2>/dev/null \
        | vhost_tpl_py record --state "$VHOST_TPL_STATE" >/dev/null 2>&1 ) || true
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"; return 1
  fi
  if [[ ! -f "$VHOST_DB" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_DB" "$VHOST_DB")"; return 1
  fi
  case "$val" in
    status|diff|update) ;;
    *) log_error "$(_t "SITE_VHOST_ERR_USAGE")"; return 1 ;;
  esac
  if [[ "$val" != "status" ]]; then
    [[ -n "$domain" && "$all" -eq 0 ]] || { log_error "$(_t "SITE_VHOST_ERR_USAGE")"; return 1; }
  fi
  if [[ -n "$domain" && "$all" -eq 0 ]]; then
    require_site_exists "$domain" "-vhost" || return 1
  fi
  if [[ "$val" == "update" ]]; then
    require_tty_or_yes || return 1
  fi

  trap vhost_on_signal INT TERM HUP
  vhost_stage_init || { vhost_stage_cleanup; trap - INT TERM HUP; log_error "$(_t "SITE_VHOST_ERR_STAGE")"; return 1; }
  if ! vhost_export; then
    vhost_stage_cleanup
    trap - INT TERM HUP
    log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$VHOST_DB")"
    return 1
  fi

  case "$val" in
    status)
      local row d st tn n
      local -a rows=()
      local out="" src=0
      if [[ -n "$domain" && "$all" -eq 0 ]]; then
        out="$(vhost_tpl_py status --state "$VHOST_TPL_STATE" --domain "$domain" < "${VHOST_STAGE}/export.json")" || src=$?
      else
        out="$(vhost_tpl_py status --state "$VHOST_TPL_STATE" < "${VHOST_STAGE}/export.json")" || src=$?
      fi
      if [[ "$src" -ne 0 ]]; then
        vhost_stage_cleanup
        trap - INT TERM HUP
        log_error "$(_t "SITE_VHOST_ERR_EXPORT" "$VHOST_DB")"
        return 1
      fi
      [[ -n "$out" ]] && mapfile -t rows <<< "$out"
      printf "%-40s %-24s %-16s %s\n" "$(_t "SITE_VHOST_COL_DOMAIN")" "$(_t "SITE_VHOST_COL_STATUS")" "$(_t "SITE_VHOST_COL_TEMPLATE")" "$(_t "SITE_VHOST_COL_LINES")"
      for row in "${rows[@]}"; do
        IFS=$'\t' read -r d st tn n <<< "$row"
        printf "%-40s %-24s %-16s %s\n" "$d" "$(vhost_status_label "$st")" "$tn" "$n"
      done
      log_info "$(_t "SITE_VHOST_INFO_STATUS_LEGEND")"
      ;;
    diff)
      if [[ -n "$name" ]]; then
        vhost_tpl_py diff --domain "$domain" --name "$name" < "${VHOST_STAGE}/export.json" || rc=$?
      else
        vhost_tpl_py diff --domain "$domain" --state "$VHOST_TPL_STATE" < "${VHOST_STAGE}/export.json" || rc=$?
      fi
      ;;
    update)
      vhost_update_site "$domain" "$name" "$force" || rc=$?
      ;;
  esac
  vhost_stage_cleanup
  trap - INT TERM HUP
  return "$rc"
}

# ------------------------------------------------------------------------------
# Dispatcher for `clp site`
# ------------------------------------------------------------------------------
site_handler() {
  local -a raw_args=("$@")
  parse_arguments "$@"

  # 語法支援:
  # 1. clp site -list / clp site list
  # 2. clp site delete <domain>
  # 3. clp site <domain> -on / -off / -delete
  # 4. clp site <domain> -new ...
  # 5. clp site <domain> -cf-waf[=status|=off]
  # 5b. clp site <domain> -cf-only[=off|=status] / clp site -cf-only[=off|=status] -all
  # 5c. clp site <domain> -varnish=status|fix / clp site -varnish=status / clp site -varnish=fix -all
  # 6. clp site -clone-from=<domain1> <domain2>
  # 7. clp site -migrate=<remote_host> -from=<domain1> [<domain2>]

  local target_domain=""
  local action=""

  # 檢查第一個 positional 是否為子動詞 (list / delete)
  if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
    local first_pos="${POSITIONAL[0]}"
    if [[ "$first_pos" == "list" ]]; then
      action="list"
    elif [[ "$first_pos" == "delete" ]]; then
      action="delete"
      if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
        target_domain="${POSITIONAL[1]}"
      fi
    else
      target_domain="$first_pos"
    fi
  fi

  local -a used_pos=("site")
  [[ -n "$action" ]] && used_pos+=("$action")
  [[ -n "$target_domain" ]] && used_pos+=("$target_domain")
  reject_extra_positionals raw_args "on|off|new|list|delete|del|ssl|dns|http|cf-waf|cf_waf|cf-only|cf_only|varnish|fix|all|status|check|exclude|clone-from|clone_from|migrate|db-root|db_root|y|yes|force-replace|force_replace|vhost|template|force" "${used_pos[@]}" || return 1

  # 檢查 options
  if has_opt "list" || [[ "$action" == "list" ]]; then
    site_list
    return 0
  fi

  if has_opt "delete" || [[ "$action" == "delete" ]]; then
    site_delete "$target_domain"
    return 0
  fi

  # Varnish 快取診斷與修正
  if has_opt "varnish"; then
    site_varnish "$target_domain"
    return $?
  fi

  # vhost 範本與 CloudPanel 官方範本比較、更新
  if has_opt "vhost"; then
    site_vhost "$target_domain"
    return $?
  fi

  # CloudPanel「Allow traffic from Cloudflare only」
  if has_opt "cf-only" || has_opt "cf_only"; then
    site_cf_only "$target_domain"
    return $?
  fi

  if has_opt "on"; then
    site_on "$target_domain"
    return 0
  fi

  if has_opt "off"; then
    site_off "$target_domain"
    return 0
  fi

  # Cloudflare Edge WAF (獨立呼叫，非新建站模式)
  if (has_opt "cf-waf" || has_opt "cf_waf") && ! has_opt "new"; then
    site_cf_waf "$target_domain" "$@"
    return $?
  fi

  # 後續模組將於 Step 4, 5 接續完善
  if has_opt "new"; then
    site_new "$target_domain"
    return 0
  fi

  # clone / migrate 必須先於 SSL 判斷：這兩個流程本身也接受 -ssl / -dns / -http 參數
  if has_opt "clone_from" || has_opt "clone-from"; then
    site_clone "$@"
    return 0
  fi

  if has_opt "migrate"; then
    site_migrate "$@"
    return 0
  fi

  if has_opt "ssl" || has_opt "dns" || has_opt "http"; then
    site_ssl "$target_domain"
    return 0
  fi

  # 若無匹配選項，顯示說明
  log_error "$(_t "SITE_ERR_INVALID_OPTION")"
  return 1
}
