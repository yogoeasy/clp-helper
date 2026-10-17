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
    ssl) [[ "$ssl" != "No" ]] ;;
    nossl) [[ "$ssl" == "No" ]] ;;
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
    [[ "$dom" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || continue

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

  # 連帶確認與調校 PHP-FPM pool
  optimize_site_php_fpm "$domain" 2>/dev/null || true
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

  # 聯動確認 PHP-FPM pool 配置健康狀態
  optimize_site_php_fpm "$domain" 2>/dev/null || true
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
    read -p "$(_t "SITE_DELETE_PROMPT_CONFIRM")" confirm_del
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
  rm -f "/var/log/nginx/${domain}.access.log" \
        "/var/log/nginx/${domain}.error.log" \
        "/var/log/nginx/${domain}-"* 2>/dev/null || true
  if [[ -n "$site_user" ]]; then
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

# _create_certbot_temp_cf_ini <token>
#   建立 Certbot DNS-01 驗證所需的暫存 Cloudflare INI 設定檔。
#   設定檔存放於 /root/.clp/，權限為 600，路徑由 stdout 回傳。
#   呼叫端需負責在 RETURN 或 EXIT 時清理暫存檔。
_create_certbot_temp_cf_ini() {
  local token="$1"
  local clp_dir="/root/.clp"
  mkdir -p "$clp_dir" && chmod 700 "$clp_dir"
  local old_umask
  old_umask=$(umask)
  umask 077
  local tmp_ini
  tmp_ini=$(mktemp "${clp_dir}/tmp-cf-certbot.XXXXXX.ini")
  cat << EOF > "$tmp_ini"
# Automatically generated by CLP Helper for Certbot DNS-01 challenge
dns_cloudflare_api_token = ${token}
EOF
  chmod 600 "$tmp_ini"
  umask "$old_umask"
  echo "$tmp_ini"
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
  fi

  if [[ "$ssl_action" == "off" || "$ssl_action" == "false" ]]; then
    log_step "$(_t "SITE_SSL_STEP_REMOVE" "${domain}")"
    # CloudPanel 的 vhost 固定引用 ssl-certificates/<domain>.crt/.key，直接刪除會讓 nginx 設定失效。
    # 改為換回自簽憑證（與 CloudPanel 新建網站時的預設狀態相同），nginx -t 失敗時還原原憑證。
    local ssl_dir="/etc/nginx/ssl-certificates"
    local crt_path="${ssl_dir}/${domain}.crt"
    local key_path="${ssl_dir}/${domain}.key"
    local work_dir
    work_dir=$(mktemp -d)
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=${domain}" \
        -keyout "${work_dir}/selfsigned.key" -out "${work_dir}/selfsigned.crt" >/dev/null 2>&1; then
      rm -rf "$work_dir"
      log_error "$(_t "SITE_SSL_ERR_SELFSIGNED_FAILED" "${domain}")"
      return 1
    fi

    mkdir -p "$ssl_dir"
    [[ -e "$crt_path" || -L "$crt_path" ]] && cp -P "$crt_path" "${work_dir}/orig.crt"
    [[ -e "$key_path" || -L "$key_path" ]] && cp -P "$key_path" "${work_dir}/orig.key"

    if command -v clpctl >/dev/null 2>&1; then
      clpctl site:install:certificate \
        --domainName="$domain" \
        --privateKey="${work_dir}/selfsigned.key" \
        --certificate="${work_dir}/selfsigned.crt" >/dev/null 2>&1 || true
    fi
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
  local tmp_cf_ini=""
  trap '[[ -n "${tmp_cf_ini:-}" && -f "${tmp_cf_ini:-}" ]] && rm -f "$tmp_cf_ini"; trap - RETURN' RETURN

  local api_param
  api_param=$(opt_get "api" "")

  if [[ -n "$api_param" ]]; then
    if ! cf_resolve_credentials "$ssl_domain" "" "$api_param"; then
      if ! _resolve_cf_token_file "$api_param" >/dev/null 2>&1; then
        log_error "$(_t "SITE_SSL_ERR_API_FILE_NOT_FOUND" "$api_param")"
      fi
      return 1
    fi

    if [[ -n "$CF_RESOLVED_FILE" && -f "$CF_RESOLVED_FILE" ]]; then
      credentials_file="$CF_RESOLVED_FILE"
      log_info "$(_t "SITE_SSL_INFO_CF_MATCH" "${credentials_file}" "$(basename "$credentials_file" .ini)")"
    elif [[ -n "$CF_RESOLVED_TOKEN" ]]; then
      tmp_cf_ini="$(_create_certbot_temp_cf_ini "$CF_RESOLVED_TOKEN")"
      credentials_file="$tmp_cf_ini"
      log_info "$(_t "SITE_SSL_INFO_CF_TOKEN_RESOLVED")"
    else
      log_error "$(_t "SITE_SSL_ERR_API_FILE_NOT_FOUND" "$api_param")"
      return 1
    fi
  else
    if cf_resolve_credentials "$ssl_domain" "" ""; then
      if [[ -n "$CF_RESOLVED_FILE" && -f "$CF_RESOLVED_FILE" ]]; then
        credentials_file="$CF_RESOLVED_FILE"
        log_info "$(_t "SITE_SSL_INFO_CF_MATCH" "${credentials_file}" "$(basename "$credentials_file" .ini)")"
      elif [[ -n "$CF_RESOLVED_TOKEN" ]]; then
        tmp_cf_ini="$(_create_certbot_temp_cf_ini "$CF_RESOLVED_TOKEN")"
        credentials_file="$tmp_cf_ini"
        log_info "$(_t "SITE_SSL_INFO_CF_TOKEN_RESOLVED")"
      fi
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

  # 安裝憑證至 CloudPanel
  if command -v clpctl >/dev/null 2>&1; then
    clpctl site:install:certificate \
      --domainName="$domain" \
      --privateKey="$ssl_key_le" \
      --certificate="$ssl_cert_le" 2>/dev/null || true
  fi

  # 建立符號連結
  ln -sf "$ssl_key_le" "$clp_key_path"
  ln -sf "$ssl_cert_le" "$clp_crt_path"

  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
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
  while IFS='=' read -r k v; do
    k=$(echo "$k" | tr -d '[:space:]')
    v=$(echo "$v" | tr -d '[:space:]"'\''')
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
    read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_4")" do_create
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
    read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_10" "${def_type_choice}")" type_choice
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
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_12" "${prompt_hint}")" input_cname
      rec_val="${input_cname:-$def_cname}"
      while [[ -z "$rec_val" ]]; do
        read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_13")" rec_val
      done
    else
      rec_type="A"
      local prompt_hint=""
      [[ -n "$srv_ip" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${srv_ip}")"
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_14" "${prompt_hint}")" input_ip
      rec_val="${input_ip:-$srv_ip}"
      while [[ -z "$rec_val" ]]; do
        read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_15")" rec_val
      done
    fi

    # 詢問 Proxy 代理狀態
    read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_16")" input_proxy
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
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_27")" do_modify
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
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_31")" do_modify
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
    read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_10" "${def_type_choice}")" new_type_choice
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
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_12" "${prompt_hint}")" input_cname
      new_val="${input_cname:-$def_cname}"
      while [[ -z "$new_val" ]]; do
        read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_13")" new_val
      done
    else
      new_type="A"
      local def_ip="$srv_ip"
      [[ -z "$def_ip" && "$primary_type" == "A" ]] && def_ip="$primary_content"
      local prompt_hint=""
      [[ -n "$def_ip" ]] && prompt_hint="$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_11" "${def_ip}")"
      read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_14" "${prompt_hint}")" input_ip
      new_val="${input_ip:-$def_ip}"
      while [[ -z "$new_val" ]]; do
        read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_15")" new_val
      done
    fi

    local def_proxy_char="N"
    [[ "$primary_proxied" == "true" ]] && def_proxy_char="Y"
    read -p "$(_t "SITE__CF_CHECK_AND_PROMPT_SINGLE_TARGET_34" "${def_proxy_char}")" input_proxy
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
  zone_info=$(cf_find_zone "$domain")

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
  local idx=1

  for target in "${targets[@]}"; do
    echo ""
    echo -e "${C_CYAN}----------------------------------------------------------------------${C_NC}"
    echo -e "${C_BOLD}$(_t "SITE_CF_DNS_BANNER_TARGET" "$idx" "$total_targets" "$target")${C_NC}"
    echo -e "${C_CYAN}----------------------------------------------------------------------${C_NC}"

    if ! _cf_check_and_prompt_single_target "$zone_id" "$zone_name" "$target" "$srv_ip" "$srv_hostname"; then
      log_warn "$(_t "SITE_CF_DNS_WARN_TARGET_FAILED" "$target")"
    fi
    idx=$((idx + 1))
  done

  echo ""
  log_success "$(_t "SITE_CF_DNS_SUCCESS_COMPLETE")"
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
      siteuser="${default_user}_$RANDOM"
      log_warn "$(_t "SITE_NEW_WARN_AUTO_USER" "${siteuser}")"
      break
    fi
    read -p "$(_t "SITE_NEW_PROMPT_RETRY_USER" "${default_user}")" input_user
    siteuser="${input_user:-$default_user}"
    siteuser=$(echo "$siteuser" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9_-]//g')
  done

  log_info "$(_t "SITE_NEW_INFO_SELECTED_USER" "${siteuser}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_PHP" "${php_ver}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_LOCALE" "${wp_locale}")"
  log_info "$(_t "SITE_NEW_INFO_SELECTED_SSL" "${ssl_type}")"

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
  mkdir -p "$wpdir"
  find "${wpdir:?}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

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
  sudo -H -u "$siteuser" wp config create \
    --dbname="$dbname" \
    --dbuser="$dbname" \
    --dbpass="$dbpass" \
    --dbhost="127.0.0.1" \
    --path="$wpdir" || {
      log_error "$(_t "SITE_NEW_ERR_CREATE_CONFIG")"
      return 1
    }

  # 詢問管理員帳密 (若直接 Enter 預設為 wpadmin / 自動產生之強密碼)
  # 非互動模式 (-y 或無 TTY) 不詢問，直接採用預設值，避免 read 遇到 EOF 在 set -e 下中止
  echo ""
  log_step "$(_t "SITE_NEW_STEP_ADMIN_SETUP")"
  local input_admin_user="" input_admin_pass="" input_admin_email=""
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

  if [[ "$non_interactive" != "true" ]]; then
    read -r -p "$(_t "SITE_NEW_PROMPT_ADMIN_EMAIL")" input_admin_email || true
  fi
  local wp_admin_email="${input_admin_email:-wpadmin@wp.com}"

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
  sudo -H -u "$siteuser" wp core install \
    --url="${site_scheme}://${domain}" \
    --title="New WordPress" \
    --admin_user="$wp_admin_user" \
    --admin_password="$wp_admin_pass" \
    --admin_email="$wp_admin_email" \
    --skip-email \
    --path="$wpdir" || {
      # 嘗試以 http 協議安裝 (若尚未配置 SSL)
      sudo -H -u "$siteuser" wp core install \
        --url="http://${domain}" \
        --title="New WordPress" \
        --admin_user="$wp_admin_user" \
        --admin_password="$wp_admin_pass" \
        --admin_email="$wp_admin_email" \
        --skip-email \
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
    update_cloned_wpconfig "$wpdir" "$dbname" "$dbpass" "$domain" "$siteuser" "$wp_admin_email"
    if [[ "$wp_locale" != "en_US" ]]; then
      sudo -H -u "$siteuser" wp config set WPLANG "$wp_locale" --type=constant --path="$wpdir" 2>/dev/null || true
    else
      sudo -H -u "$siteuser" wp config delete WPLANG --path="$wpdir" 2>/dev/null || true
    fi

    local wpconfig="${wpdir}/wp-config.php"
    if [[ -f "$wpconfig" ]]; then
      # 只把 DB_CHARSET 由 utf8 改為 utf8mb4（全域取代會把既有的 utf8mb4 變成 utf8mb4mb4）
      sed -i -E "s/(define\([[:space:]]*['\"]DB_CHARSET['\"][[:space:]]*,[[:space:]]*['\"])utf8(['\"])/\1utf8mb4\2/" "$wpconfig"
      if ! grep -q "WP_DEBUG_LOG" "$wpconfig"; then
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

  # 校正目錄權限
  chown -R "$siteuser:$siteuser" "$wpdir"

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
  local target_wpconfig="${target_root}/wp-config.php"

  if [[ ! -f "$target_wpconfig" ]]; then
    return 0
  fi

  log_info "$(_t "SITE_NEW_INFO_CONFIGURING_WPCONFIG")"

  local new_cache_salt
  new_cache_salt="${target_domain}:$(openssl rand -hex 8)"

  CLP_LIB_DIR="${CLP_LIB_DIR}" CLP_SITE_USER="${target_user}" python3 -I - "$target_wpconfig" "$target_domain" "$target_dbname" "$target_dbpass" "$new_cache_salt" "$recovery_email" << 'PYEOF'
import os, sys, re
sys.path.insert(0, os.environ.get("CLP_LIB_DIR", "/usr/local/share/clp-helper/lib"))
import clp_fileops

wpconfig_path = sys.argv[1]
target_domain = sys.argv[2]
target_dbname = sys.argv[3]
target_dbpass = sys.argv[4]
new_cache_salt = sys.argv[5]
recovery_email = sys.argv[6] if len(sys.argv) > 6 else ""
site_user = clp_fileops.get_required_site_user()

try:
    content = clp_fileops.read_text_nofollow(wpconfig_path)

    # 1. 若先前曾有 define 語句被錯誤插入 docblock (/** ... */) 內，先行清理以還原註解結構
    def clean_docblock(match):
        lines = match.group(0).splitlines()
        cleaned = [l for l in lines if not re.match(r"^\s*define\s*\(", l)]
        return "\n".join(cleaned)

    content = re.sub(r"/\*\*.*?\*/", clean_docblock, content, flags=re.DOTALL)

    # 2. 定義需設定或校正之常數 (常數名, 設定值, 是否為 raw PHP 代碼值)
    configs = [
        ("DB_NAME", target_dbname, False),
        ("DB_USER", target_dbname, False),
        ("DB_PASSWORD", target_dbpass, False),
        ("DB_HOST", "127.0.0.1", False),
        ("WP_HOME", f"https://{target_domain}", False),
        ("WP_SITEURL", f"https://{target_domain}", False),
        ("WP_CACHE_KEY_SALT", new_cache_salt, False),
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
        pattern = re.compile(
            r"^[ \t]*define\s*\(\s*['\"]" + re.escape(key) + r"['\"]\s*,\s*.*?\)\s*;\s*$",
            re.MULTILINE
        )
        if pattern.search(content):
            content = pattern.sub(lambda m, nl=new_line: nl, content)
        else:
            missing_defines.append(new_line)

    # 3. 缺漏之常數統一乾淨插入於 <?php 之後、主註解區塊之前
    if missing_defines:
        block = "\n".join(missing_defines) + "\n"
        if re.search(r"<\?php", content):
            content = re.sub(r"^(<\?php[^\n]*\n)", r"\1" + block + "\n", content, count=1, flags=re.MULTILINE)
        else:
            content = "<?php\n" + block + "\n" + content

    clp_fileops.safe_atomic_write(wpconfig_path, content, user=site_user, allow_create=False)
except Exception as e:
    print(f"Error updating wp-config.php: {e}", file=sys.stderr)
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
    sys.stderr.write(f"Error updating robots.txt: {e}\n")
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
        if re.match(r"^\s*auto_prepend_file\s*=", line):
            if wf_exists:
                new_line = f"auto_prepend_file = '{target_root}/wordfence-waf.php'"
            else:
                new_line = f"; {line}  # auto-disabled by CLP Helper because file was missing"
            if new_line != line:
                modified = True
            lines.append(new_line)
        else:
            if source_root and source_root in line:
                line = line.replace(source_root, target_root)
                modified = True
            lines.append(line)

    if modified:
        clp_fileops.safe_atomic_write(user_ini, "\n".join(lines) + "\n", user=site_user, allow_create=False)
        print("USER_INI_MODIFIED")
except Exception as e:
    sys.stderr.write(f"Error updating .user.ini: {e}\n")
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
    sys.stderr.write(f"Error updating wordfence-waf.php: {e}\n")
    sys.exit(1)
PYEOF
    then
      log_success "$(_t "SITE_SANITIZE_CLONED_ENVIRONMENT_PATHS_3")"
    else
      log_warn "$(_t "SITE_WARN_UPDATE_WORDFENCE_FAILED")"
    fi
  fi

  # 3. 清理 Wordfence 日誌快取 (避免讀取舊網站日誌與快取衝突)
  if [[ -d "${target_root}/wp-content/wflogs" ]]; then
    rm -f "${target_root}/wp-content/wflogs/"* 2>/dev/null || true
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
    sys.stderr.write(f"Error updating advanced-cache.php: {e}\n")
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
  local json_data="$1"
  local target_role="${2:-all}"

  _wp_session_label_env
  if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$json_data" "$target_role" << "PYEOF"
import json, os, sys

def L(key, default):
    return os.environ.get("CLP_L_" + key) or default

sample_json = sys.argv[1]
filter_role = sys.argv[2] if len(sys.argv) > 2 else "all"

try:
    data = json.loads(sample_json)
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
$data = json_decode($argv[1], true);
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

  local json_data
  json_data=$(echo "$cmd_out" | sed -n 's/.*CLP_JSON_START\(.*\)CLP_JSON_END.*/\1/p')

  if [[ -z "$json_data" ]]; then
    return 0
  fi

  local total_users=0
  if command -v python3 >/dev/null 2>&1; then
    total_users=$(python3 -I -c "import json, sys; print(json.loads(sys.argv[1]).get('total', 0))" "$json_data" 2>/dev/null || echo 0)
  elif command -v php >/dev/null 2>&1; then
    total_users=$(php -r '$d=json_decode($argv[1],true); echo $d["total"] ?? 0;' "$json_data" 2>/dev/null || echo 0)
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
import json, os, sys

def L(key, default):
    return os.environ.get("CLP_L_" + key) or default

data = json.loads(sys.argv[1])
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
$d = json_decode($argv[1], true);
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
    role_lines="$(python3 -I -c "import json, sys; d=json.loads(sys.argv[1]); [print(f'{k}\t{v}') for k, v in d.get('roles', {}).items()]" "$json_data" 2>/dev/null || true)"
  elif command -v php >/dev/null 2>&1; then
    role_lines="$(php -r '$d=json_decode($argv[1],true); foreach (($d["roles"] ?? array()) as $k => $v) { echo $k . "\t" . $v . "\n"; }' "$json_data" 2>/dev/null || true)"
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
      echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_6" "$idx" "${roles[ri]}" "${role_counts[ri]}")"
      idx=$((idx + 1))
    done
    local all_idx=$idx
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_7" "${all_idx}")"
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_8")"
    echo "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_9")"
    echo ""
    read -r -p "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_10" "${all_idx}")" user_choice || user_choice="0"
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
        if [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ "$user_choice" -ge 1 && "$user_choice" -lt "$all_idx" ]]; then
          local selected_role="${roles[$((user_choice - 1))]}"
          echo ""
          echo -e "$(_t "SITE_PROMPT_WP_ACTIVE_SESSIONS_13" "${C_BOLD}" "${selected_role}" "${C_NC}")"
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
  if site_exists "$target_domain" || [[ -n "$target_root" && -d "$target_root" ]]; then
    if has_opt "force-replace" || has_opt "force_replace"; then
      log_warn "$(_t "SITE_CLONE_7" "${target_domain}")"
      site_delete "$target_domain"
    else
      log_error "$(_t "SITE_CLONE_8" "${target_domain}")"
      return 1
    fi
  fi

  # 3. 取得來源站擁有者與決定目標站 Site User (CloudPanel 要求每個網站必須擁有獨立且尚未存在於 /etc/passwd 的使用者)

  local target_user
  target_user=$(opt_get "user" "")
  if [[ -n "$target_user" ]]; then
    target_user=$(echo "$target_user" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    if id -u "$target_user" >/dev/null 2>&1; then
      log_error "$(_t "SITE_CLONE_9" "${target_user}")"
      return 1
    fi
  else
    target_user=$(suggest_site_user "$target_domain")
  fi
  log_info "$(_t "SITE_CLONE_10" "${target_user}")"

  # 4. 偵測 PHP 版本 (沿用來源站)
  local php_ver
  php_ver=$(opt_get "php" "$(find_site_php_version "$source_domain" 2>/dev/null || get_default_php_version)")
  log_info "$(_t "SITE_CLONE_11" "${php_ver}")"

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

  # 8. 資料庫複製與留存備份
  log_step "$(_t "SITE_CLONE_18")"
  local backup_dir="/root/clpBackup"
  mkdir -p "$backup_dir" && chmod 700 "$backup_dir" 2>/dev/null || true
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local sql_backup="${backup_dir}/${source_domain}-backup-${timestamp}.sql"

  if ! sudo -H -u "$source_user" wp db export - --add-drop-table --path="$source_root" > "$sql_backup"; then
    log_error "$(_t "SITE_CLONE_19")"
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    rm -f "$sql_backup"
    return 1
  fi
  chmod 600 "$sql_backup" 2>/dev/null || true
  ln -sf "$sql_backup" "/root/${source_domain}.sql"
  log_info "$(_t "SITE_CLONE_20" "${sql_backup}")"

  # 匯入至新資料庫 (使用 MYSQL_PWD 避免密碼洩漏至行程清單)
  if ! MYSQL_PWD="${target_dbpass}" mysql -h"127.0.0.1" -u"${target_dbname}" "${target_dbname}" < "$sql_backup" 2>/dev/null; then
    log_warn "$(_t "SITE_CLONE_21")"
    local master_pass
    master_pass=$(get_mysql_master_pass)
    if ! MYSQL_PWD="${master_pass}" mysql -h"127.0.0.1" -uroot "${target_dbname}" < "$sql_backup"; then
      log_error "$(_t "SITE_CLONE_22")"
      clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
      clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
      return 1
    fi
  fi
  log_success "$(_t "SITE_CLONE_23")"

  # 9. 同步網站檔案 (排除快取與備份暫存檔)
  log_step "$(_t "SITE_CLONE_24" "${source_domain}" "${target_domain}")"
  rsync -a --delete \
    --exclude='wp-content/cache' \
    --exclude='wp-content/updraft' \
    --exclude='wp-content/wpvividbackups' \
    "${source_root}/" "${target_root}/"
  chown -R "${target_user}:${target_user}" "$target_root"
  log_success "$(_t "SITE_CLONE_25")"

  # 10. 安全與環境絕對路徑修復 (.user.ini / Wordfence / 快取外掛)
  sanitize_cloned_environment_paths "$target_root" "$source_root" "$target_user" || true

  # 11. 更新目標站 wp-config.php DB 帳密與快取隔離前綴
  update_cloned_wpconfig "$target_root" "$target_dbname" "$target_dbpass" "$target_domain" "$target_user"

  # 12. WP-CLI 網址全面替換 (精準替換，避免子網域二次替換衝突)
  log_step "$(_t "SITE_CLONE_26" "${source_domain}" "${target_domain}")"
  sudo -H -u "$target_user" wp search-replace "https://${source_domain}" "https://${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
  sudo -H -u "$target_user" wp search-replace "http://${source_domain}" "http://${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
  sudo -H -u "$target_user" wp search-replace "//${source_domain}" "//${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
  if [[ "$target_domain" != *"$source_domain"* ]]; then
    sudo -H -u "$target_user" wp search-replace "${source_domain}" "${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
  fi
  log_success "$(_t "SITE_CLONE_27")"

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
      [ -z \"\$rphp\" ] && rphp='8.4'
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
      for s in "${all_sites_arr[@]}"; do
        echo -e "  - ${C_CYAN}${s}${C_NC}"
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
      sqlite3 -readonly \"\$clp_db\" \"SELECT domain_name FROM site;\" 2>/dev/null
    fi
  " 2>/dev/null || true)

  if [[ -z "$remote_domains_raw" ]]; then
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
          if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            if (( start > end )); then
              local tmp=$start; start=$end; end=$tmp
            fi
            for ((n=start; n<=end; n++)); do
              if (( n >= 1 && n <= ${#domains_to_migrate[@]} )); then
                to_remove_indexes+=("$n")
                valid_input=1
              fi
            done
          elif [[ "$item" =~ ^[0-9]+$ ]]; then
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
  return 0
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

  if ! is_valid_domain "$target_domain"; then
    log_error "$(_t "SITE_CLONE_2" "${target_domain}")"
    return 1
  fi

  # 探測遠端網站 (比對 CloudPanel 網站清單與 Nginx)
  local remote_info
  remote_info=$(probe_remote_site "$remote_host" "$source_domain") || return 1

  local remote_user remote_root remote_php
  remote_user=$(echo "$remote_info" | cut -d'|' -f2)
  remote_root=$(echo "$remote_info" | cut -d'|' -f3)
  remote_php=$(echo "$remote_info" | cut -d'|' -f4)
  [[ -z "$remote_php" ]] && remote_php="$(get_default_php_version)"
  log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_1" "${remote_user}" "${remote_root}" "${remote_php}")"

  # 檢查遠端來源站線上登入使用者狀態
  prompt_wp_active_sessions "$remote_host" "$source_domain" "$remote_root" "$remote_user" || return 1

  # 遠端來源已確認且使用者同意繼續，才刪除要被覆寫的本地網站
  if [[ "$replace_existing" -eq 1 ]]; then
    log_warn "$(_t "SITE__MIGRATE_SINGLE_SITE_2" "${target_domain}")"
    if ! site_delete "$target_domain" -force; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_3" "${target_domain}")"
      return 1
    fi
  fi

  # 決定本地 site user（單站支援 -user= 覆寫；若預設使用者已存在於系統則自動建議可用名稱）
  local target_user=""
  # -user 只適用於單站搬移；批次搬移 (-all) 每個網站必須各自使用不同的系統使用者
  if [[ "${CLP_MIGRATE_BATCH:-0}" -ne 1 ]]; then
    target_user=$(opt_get "user" "")
  fi
  if [[ -n "$target_user" ]]; then
    target_user=$(echo "$target_user" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')
    if id -u "$target_user" >/dev/null 2>&1; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_4" "${target_user}")"
      return 1
    fi
  else
    if ! id -u "$remote_user" >/dev/null 2>&1; then
      target_user="$remote_user"
    else
      target_user=$(suggest_site_user "$target_domain")
    fi
  fi
  log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_5" "${target_user}")"

  # 決定 PHP 版本（支援 -php= 覆寫，若未指定則自動採用遠端探測版本）
  local php_ver
  php_ver=$(opt_get "php" "$remote_php")
  log_info "$(_t "SITE_CLONE_11" "${php_ver}")"

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
      return 1
  fi

  local target_root="/home/${target_user}/htdocs/${target_domain}"
  mkdir -p "$target_root"

  # SSL 憑證配置 (Fail-Fast: 建立網站後立即配置，確保 HTTPS 即刻就緒且避免搬移白做工)
  local enable_ssl="y"
  if has_opt "no-ssl" || has_opt "nossl" || [[ "$(opt_get "ssl" "on")" == "off" || "$(opt_get "ssl" "on")" == "false" ]]; then
    enable_ssl="n"
  fi
  if [[ "$enable_ssl" == "y" ]]; then
    log_step "$(_t "SITE_CLONE_16")"
    local CLP_INTERNAL_SSL_CALL=1
    site_ssl "$target_domain" || log_warn "$(_t "SITE_CLONE_17" "${target_domain}")"
  fi

  # 遠端資料庫串流搬移
  log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_10")"
  local backup_dir="/root/clpBackup"
  mkdir -p "$backup_dir" && chmod 700 "$backup_dir" 2>/dev/null || true
  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local sql_backup="${backup_dir}/${source_domain}-backup-${timestamp}.sql"

  # 兩階段搬移：先完整下載 dump 並驗證，再匯入。
  # - 遠端不經 gzip 管線（改用 ssh -C 壓縮傳輸），ssh 的結束狀態即為 wp db export 的狀態
  # - 以 mysqldump 結尾的 "-- Dump completed" 標記確認 dump 完整，避免匯入只有一半資料表的檔案
  # - 本地匯入失敗時可改用 root 重試（不再因 SIGPIPE 被誤判為遠端匯出失敗）
  _migrate_abort_db() {
    clpctl site:delete --domainName="$target_domain" --force >/dev/null 2>&1 || true
    clpctl db:delete --databaseName="$target_dbname" 2>/dev/null || true
    rm -f "$sql_backup"
  }

  ( umask 077; : > "$sql_backup" )
  if ! ssh -n -C "$remote_host" "cd '${remote_root}' && sudo -H -u '${remote_user}' wp db export - --add-drop-table" > "$sql_backup"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_11")"
    _migrate_abort_db
    return 1
  fi
  if [[ ! -s "$sql_backup" ]] || ! tail -n 5 "$sql_backup" | grep -q -- "-- Dump completed"; then
    log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_12")"
    _migrate_abort_db
    return 1
  fi

  if ! MYSQL_PWD="${target_dbpass}" mysql -h"127.0.0.1" -u"${target_dbname}" "${target_dbname}" < "$sql_backup" 2>/dev/null; then
    log_warn "$(_t "SITE__MIGRATE_SINGLE_SITE_13")"
    local master_pass
    master_pass=$(get_mysql_master_pass)
    if ! MYSQL_PWD="${master_pass}" mysql -h"127.0.0.1" -uroot "${target_dbname}" < "$sql_backup"; then
      log_error "$(_t "SITE__MIGRATE_SINGLE_SITE_14")"
      _migrate_abort_db
      return 1
    fi
  fi

  chmod 600 "$sql_backup" 2>/dev/null || true
  ln -sf "$sql_backup" "/root/${source_domain}.sql"
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
  update_cloned_wpconfig "$target_root" "$target_dbname" "$target_dbpass" "$target_domain" "$target_user"

  # WP search-replace（只在網域不同時才執行，加入 --skip-plugins --skip-themes）
  if [[ "$domain_mode" != "same_domain" ]]; then
    log_step "$(_t "SITE__MIGRATE_SINGLE_SITE_19" "${source_domain}" "${target_domain}")"
    sudo -H -u "$target_user" wp search-replace "https://${source_domain}" "https://${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
    sudo -H -u "$target_user" wp search-replace "http://${source_domain}" "http://${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
    sudo -H -u "$target_user" wp search-replace "//${source_domain}" "//${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
    if [[ "$target_domain" != *"$source_domain"* ]]; then
      sudo -H -u "$target_user" wp search-replace "${source_domain}" "${target_domain}" --all-tables --skip-plugins --skip-themes --precise --path="$target_root" 2>&1 || true
    fi
    log_success "$(_t "SITE_CLONE_27")"

    # 自動校正實體 robots.txt 內之 Sitemap 與網域
    update_cloned_robots_txt "$target_root" "$source_domain" "$target_domain" "$target_user" || true
  else
    log_info "$(_t "SITE__MIGRATE_SINGLE_SITE_20")"
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
    if has_opt "force-replace" || has_opt "force_replace" || has_opt "force"; then
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
  local domain="${1:-}"

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

  if [[ "$cf_action_val" == "status" ]]; then
    waf_action="status"
  elif [[ "$cf_action_val" == "off" ]]; then
    waf_action="off"
  fi

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
        cf_configure_zone_settings "$zone_id" "$token" "$dry_run" || log_warn "$(_t "CF_WARN_ZONE_SETTINGS_FAILED")"
        cf_check_and_enable_proxy "$zone_id" "$domain" "$token" "$dry_run" || true
        echo ""
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

# nginx.conf 若信任所有來源的 X-Real-IP，任何人都能偽造 Cloudflare IP 繞過此設定（只警告，不修改）
cf_only_warn_real_ip() {
  if grep -Eq '^[[:space:]]*set_real_ip_from[[:space:]]+0\.0\.0\.0/0[[:space:]]*;' /etc/nginx/nginx.conf 2>/dev/null; then
    log_warn "$(_t "SITE_CF_ONLY_WARN_REAL_IP")"
  fi
}

# cf_only_backup_init：本次執行的備份目錄（vhost 副本、資料庫欄位原值、資料庫備份）；資料庫備份只保留最近 3 份
cf_only_backup_init() {
  [[ -n "$CF_ONLY_BACKUP_DIR" ]] && return 0
  local base="/root/.clp/cf-only-backup"
  CF_ONLY_BACKUP_DIR="${base}/$(date +%Y%m%d_%H%M%S)"
  ( umask 077; mkdir -p "$CF_ONLY_BACKUP_DIR" ) || return 1
  if ! cf_only_py db-backup "$CF_ONLY_DB" "${CF_ONLY_BACKUP_DIR}/db.sq3"; then
    log_error "$(_t "SITE_CF_ONLY_ERR_DB_BACKUP")"
    return 1
  fi
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
    local n base="${domain#www.}" others=()
    for n in $names; do
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
      if [[ "$vhost_changed" -eq 1 ]]; then
        atomic_replace "$vbak" "$vhost" || log_error "$(_t "SITE_CF_ONLY_ERR_RESTORE" "$vbak" "$vhost")"
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
  cf_only_warn_real_ip
  local -a domains=()
  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    while IFS=$'\t' read -r d _; do
      [[ -n "$d" ]] && domains+=("$d")
    done < <(cf_only_py db-get "$CF_ONLY_DB")
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
cf_only_batch() {
  local action="$1" dry_run="$2" force="$3"
  local -a todo=() skipped=() ex_patterns=()
  local exclude
  exclude=$(opt_get "exclude" "")
  [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
  local d line db vs dns pat
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
  done < <(cf_only_py db-get "$CF_ONLY_DB")

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
    cf_only_warn_real_ip
    cf_only_batch "$action" "$dry_run" "$force"
    return $?
  fi

  if [[ -z "$domain" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_USAGE")"
    return 1
  fi
  require_site_exists "$domain" "-cf-only" || return 1
  [[ "$action" == "on" ]] && cf_only_warn_real_ip
  cf_only_apply "$domain" "$action" "$force" "$dry_run"
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
  out=$(varnish_py diagnose "$VARNISH_DB" "$domain" 2>&1) || rc=$?
  VD_ERROR=""
  if [[ "$rc" -ne 0 ]]; then
    VD_ERROR="$out"
    VD_CONCLUSION="error"
    return 1
  fi
  local k v
  VD_TYPE="" VD_DB="" VD_SETTINGS="" VD_VHOST="" VD_USERINI="" VD_WFWAF="" VD_CACHED="" VD_CONCLUSION="" VD_USER="" VD_ROOT=""
  while IFS='=' read -r k v; do
    case "$k" in
      type) VD_TYPE="$v" ;; varnish_db) VD_DB="$v" ;; settings) VD_SETTINGS="$v" ;;
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
    unknown) _t "SITE_VARNISH_C_UNKNOWN" ;;
    *) _t "SITE_VARNISH_C_ERROR" ;;
  esac
}

varnish_print_row() {
  local domain="$1"
  printf "%-32s %-9s %-8s %-10s %-9s %-6s %s\n" "$domain" "${VD_SETTINGS:--}" "${VD_VHOST:--}" \
    "${VD_USERINI%%:*}" "${VD_WFWAF:--}" "${VD_CACHED:--}" "$(varnish_conclusion_text "$VD_CONCLUSION")"
}

varnish_print_header() {
  echo ""
  printf "%-32s %-9s %-8s %-10s %-9s %-6s %s\n" "Domain" "settings" "vhost" ".user.ini" "wf-waf" "cached" "$(_t "SITE_VARNISH_COL_RESULT")"
  echo "--------------------------------------------------------------------------------------------------------"
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

  # 3. 重新檢查實際結果（nginx reload 為非同步，稍候再測）
  sleep 2
  local after
  after=$(varnish_py probe "$domain" 2>/dev/null || echo error)
  if [[ "$after" == "yes" ]]; then
    log_success "$(_t "SITE_VARNISH_OK_CACHED" "$domain")"
    VF_RESULT="fixed"; return 0
  fi
  log_warn "$(_t "SITE_VARNISH_WARN_STILL_NOT_CACHED" "$domain" "$VARNISH_BACKUP_DIR")"
  VF_RESULT="fixed"
  return 1
}

varnish_status() {
  local domain="$1"
  local -a domains=()
  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(varnish_py list "$VARNISH_DB")
  fi
  varnish_print_header
  local d
  for d in "${domains[@]}"; do
    varnish_diagnose "$d" || true
    varnish_print_row "$d"
  done
  echo ""
  if [[ -n "$domain" && -n "$VD_ERROR" ]]; then
    log_error "$VD_ERROR"
    return 1
  fi
  return 0
}

varnish_batch_fix() {
  local dry_run="$1"
  local exclude pat d
  exclude=$(opt_get "exclude" "")
  local -a ex_patterns=() todo=()
  [[ -n "$exclude" ]] && IFS=',' read -ra ex_patterns <<< "$exclude"
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
    case "$VD_CONCLUSION" in fix-vhost|fix-wfwaf|fix-both) todo+=("$d") ;; esac
  done < <(varnish_py list "$VARNISH_DB")
  echo ""
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
site_varnish() {
  local domain
  domain=$(clean_domain "${1:-}")
  local val
  val=$(echo "$(opt_get "varnish" "")" | tr '[:upper:]' '[:lower:]')
  local all=0 dry_run=0
  has_opt "all" && all=1
  { has_opt "dry-run" || has_opt "dry_run"; } && dry_run=1
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "$(_t "CORE_ERR_PYTHON3_REQUIRED")"; return 1
  fi
  if [[ ! -f "$VARNISH_DB" ]]; then
    log_error "$(_t "SITE_CF_ONLY_ERR_NO_DB" "$VARNISH_DB")"; return 1
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
  reject_extra_positionals raw_args "on|off|new|list|delete|del|ssl|dns|http|cf-waf|cf_waf|cf-only|cf_only|varnish|fix|all|status|exclude|clone-from|clone_from|migrate|y|yes|force-replace|force_replace" "${used_pos[@]}" || return 1

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
