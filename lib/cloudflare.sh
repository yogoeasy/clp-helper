#!/usr/bin/env bash
# ==============================================================================
# CLP Helper - Cloudflare API & Edge WAF Module
# File: lib/cloudflare.sh
# Description: Cloudflare Zone optimization, TLS hardening, and Ruleset WAF management.
# ==============================================================================

[[ "${BASH_SOURCE[0]}" != "${0}" ]] || set -euo pipefail

if [[ -z "${CLP_ROOT_DIR:-}" ]]; then
  CLP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export CLP_ROOT_DIR
fi

# Load dependencies
if ! command -v _t >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/i18n.sh"
fi

if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/core.sh"
fi

if ! command -v canonical_config_key >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${CLP_ROOT_DIR}/lib/config.sh"
fi

CF_API_BASE="https://api.cloudflare.com/client/v4"

# ------------------------------------------------------------------------------
# 1. Server IP & Utility Helpers
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# 2. Token Resolution Cascade (4-level priority)
# ------------------------------------------------------------------------------
# cf_is_global_key_file <檔案>：是否為 certbot 的 Global API Key 格式（dns_cloudflare_email + dns_cloudflare_api_key）
cf_is_global_key_file() {
  grep -qE '^[[:space:]]*dns_cloudflare_email[[:space:]]*=[[:space:]]*[^[:space:]]' "$1" 2>/dev/null && \
    grep -qE '^[[:space:]]*dns_cloudflare_api_key[[:space:]]*=[[:space:]]*[^[:space:]]' "$1" 2>/dev/null
}

cf_resolve_credentials() {
  local domain="${1:-}"
  local cli_token="${2:-}"
  local api_param="${3:-}"

  CF_RESOLVED_FILE=""
  CF_RESOLVED_TOKEN=""
  CF_RESOLVED_SOURCE=""

  local token=""
  local credentials_file=""
  local source_desc=""
  local single_secret_fallback=""

  # Priority 1: Command line token parameter
  if [[ -n "$cli_token" ]]; then
    if _resolve_cf_token_file "$cli_token" >/dev/null 2>&1; then
      local f
      f="$(_resolve_cf_token_file "$cli_token")"
      if token="$(_extract_token_from_file "$f")"; then
        credentials_file="$f"
        source_desc="CLI: ${f}"
      else
        # 明確指定的檔案無法取得 token 時直接失敗，不可默默改用其他帳號的 token
        log_error "$(_t "CF_ERR_TOKEN_FILE_NO_TOKEN" "$f")"
        return 1
      fi
    else
      token="$cli_token"
      source_desc="CLI parameter"
    fi
  fi

  # Priority 2: Specified -api or search .secrets/*.ini (aligned with site.sh)
  if [[ -z "$token" && -z "$credentials_file" ]]; then
    if [[ -n "$api_param" ]]; then
      if _resolve_cf_token_file "$api_param" >/dev/null 2>&1; then
        local f
        f="$(_resolve_cf_token_file "$api_param")"
        if token="$(_extract_token_from_file "$f")"; then
          credentials_file="$f"
          source_desc="${f}"
        else
          # 明確指定的檔案無法取得 token 時直接失敗，不可默默改用其他帳號的 token
          log_error "$(_t "CF_ERR_TOKEN_FILE_NO_TOKEN" "$f")"
          return 1
        fi
      else
        return 1
      fi
    fi

    if [[ -z "$credentials_file" && -z "$token" ]]; then
      local secret_dirs=("/root/.secrets" "${HOME}/.secrets" "${HOME}/.secret")
      local available_secrets=() seen_dirs=" " real_dir
      for sdir in "${secret_dirs[@]}"; do
        # 以 root 執行時 HOME=/root，同一個目錄不可重複計算（否則「只有一個 .ini」的備援永遠不會成立）
        real_dir=$(realpath "$sdir" 2>/dev/null || echo "$sdir")
        [[ "$seen_dirs" == *" ${real_dir} "* ]] && continue
        seen_dirs+="${real_dir} "
        if [[ -d "$sdir" ]]; then
          while IFS= read -r -d '' sf; do
            available_secrets+=("$sf")
          done < <(find "$sdir" -maxdepth 1 -name "*.ini" -print0 2>/dev/null || true)
          # 取不到 token 的檔案（例如舊版留下的佔位範本）不列入，否則會擋住「只有一個 .ini」的備援
          local usable=() cand
          for cand in ${available_secrets[@]+"${available_secrets[@]}"}; do
            if _extract_token_from_file "$cand" >/dev/null 2>&1 || cf_is_global_key_file "$cand"; then
              usable+=("$cand")
            fi
          done
          available_secrets=(${usable[@]+"${usable[@]}"})
        fi
      done

      if [[ ${#available_secrets[@]} -gt 0 ]]; then
        # Smart domain match：見 cf_credentials_match_score（完整網域／上層網域優先，其次網域主要名稱）；
        # 不使用子字串比對，避免選到其他帳號。
        if [[ -n "$domain" ]]; then
          local best_score=0 score
          for sec in "${available_secrets[@]}"; do
            score=$(cf_credentials_match_score "$(basename "$sec" .ini)" "$domain")
            if [[ "$score" -gt "$best_score" ]]; then
              credentials_file="$sec"
              best_score="$score"
            fi
          done
        fi

        # 只有一個 .ini 檔時，留待全域設定 (Priority 3) 之後才作為備援
        if [[ -z "$credentials_file" && ${#available_secrets[@]} -eq 1 ]]; then
          single_secret_fallback="${available_secrets[0]}"
        fi
      fi
    fi

    if [[ -n "$credentials_file" && -f "$credentials_file" ]]; then
      if token="$(_extract_token_from_file "$credentials_file")"; then
        source_desc="${credentials_file}"
      else
        credentials_file=""
        token=""
      fi
    fi
  fi

  # Priority 3: Global config（token 只讀使用者檔 /etc/clp/clp.local；尚未遷移的舊版 clp.conf 也視為使用者檔）
  if [[ -z "$token" && -z "$credentials_file" ]]; then
    local conf_file="${CLP_CONFIG_LOCAL_FILE:-/etc/clp/clp.local}"
    if ! grep -qE '^(CF_API_TOKEN|cf-token|cf_token|cloudflare_api_token)=' "$conf_file" 2>/dev/null; then
      conf_file="${CLP_CONFIG_FILE:-/etc/clp/clp.conf}"
    fi
    local conf_val
    conf_val="$(get_config_value CF_API_TOKEN)"
    if [[ -n "$conf_val" ]]; then
      if _resolve_cf_token_file "$conf_val" >/dev/null 2>&1; then
        local resolved_cf_f
        resolved_cf_f="$(_resolve_cf_token_file "$conf_val")"
        if ! token="$(_extract_token_from_file "$resolved_cf_f")"; then
          # Global API Key 檔（dns_cloudflare_email + dns_cloudflare_api_key）：certbot 與 cf_parse_auth 都支援，沿用檔案
          # 其他無法取得 token 的檔案直接失敗，不可回報成功卻帶著空的 token
          if ! cf_is_global_key_file "$resolved_cf_f"; then
            log_error "$(_t "CF_ERR_TOKEN_FILE_NO_TOKEN" "$resolved_cf_f")"
            return 1
          fi
          token=""
        fi
        credentials_file="$resolved_cf_f"
        source_desc="${conf_file} -> ${resolved_cf_f}"
      else
        token="$conf_val"
        local token_src
        token_src="$(get_config_value CF_API_TOKEN_SOURCE)"
        if [[ -n "$token_src" ]]; then
          source_desc="${conf_file} (${token_src})"
        else
          source_desc="${conf_file}"
        fi
      fi
    fi
  fi

  # Priority 3b: 唯一的 .secrets/*.ini（不符合網域名稱時，優先順序低於明確設定的全域 token）
  if [[ -z "$token" && -z "$credentials_file" && -n "$single_secret_fallback" ]]; then
    if token="$(_extract_token_from_file "$single_secret_fallback")"; then
      credentials_file="$single_secret_fallback"
      source_desc="${single_secret_fallback}"
    else
      token=""
      credentials_file=""
    fi
  fi

  # Priority 4: Environment variables
  if [[ -z "$token" && -z "$credentials_file" ]]; then
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      token="${CLOUDFLARE_API_TOKEN}"
      source_desc="env:CLOUDFLARE_API_TOKEN"
    elif [[ -n "${CF_API_TOKEN:-}" ]]; then
      token="${CF_API_TOKEN}"
      source_desc="env:CF_API_TOKEN"
    fi
  fi

  if [[ -n "$credentials_file" || -n "$token" ]]; then
    CF_RESOLVED_FILE="$credentials_file"
    CF_RESOLVED_TOKEN="$token"
    CF_RESOLVED_SOURCE="$source_desc"
    return 0
  fi

  return 1
}

cf_resolve_token() {
  local domain="${1:-}"
  local cli_token="${2:-}"
  local api_param="${3:-}"

  if cf_resolve_credentials "$domain" "$cli_token" "$api_param"; then
    log_info "$(_t "CF_INFO_RESOLVED_TOKEN_SOURCE" "$CF_RESOLVED_SOURCE")" >&2
    echo "$CF_RESOLVED_TOKEN"
    return 0
  else
    log_error "$(_t "CF_ERR_TOKEN_NOT_FOUND")"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 3. Cloudflare API Caller
# ------------------------------------------------------------------------------
cf_api_call() {
  local method="$1"
  local endpoint="$2"
  local token="$3"
  local payload="${4:-}"

  local url="${CF_API_BASE}${endpoint}"

  if [[ -n "$payload" ]]; then
    curl -s -S --connect-timeout 10 --max-time 60 -X "$method" \
      -K <(curl_header_config "Authorization: Bearer ${token}") \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$url"
  else
    curl -s -S --connect-timeout 10 --max-time 60 -X "$method" \
      -K <(curl_header_config "Authorization: Bearer ${token}") \
      -H "Content-Type: application/json" \
      "$url"
  fi
}

# ------------------------------------------------------------------------------
# 4. Resolve Zone ID by Domain
# ------------------------------------------------------------------------------
cf_get_zone_id() {
  local domain="$1"
  local token="$2"

  log_step "$(_t "CF_STEP_FETCH_ZONE" "$domain")" >&2

  # Build candidate zones (e.g. sub.example.com -> sub.example.com, example.com)
  local candidates=("$domain")
  local d_temp="$domain"
  while [[ "$d_temp" == *.* ]]; do
    local parent="${d_temp#*.}"
    if [[ "$parent" == *.* ]]; then
      candidates+=("$parent")
      d_temp="$parent"
    else
      break
    fi
  done

  local zone_id=""
  local matched_zone=""
  local api_err=""

  for cz in "${candidates[@]}"; do
    local resp
    resp="$(cf_api_call "GET" "/zones?name=${cz}" "$token" || true)"
    # 同時解析 zone_id 與 API 錯誤（例如 token 無效 9109 / 權限不足 10000），單次啟動 Python
    local parsed_out
    parsed_out="$(python3 -I -c "
import sys, json
z_id = ''
err = ''
try:
    d = json.loads(sys.argv[1])
    if d.get('success') and d.get('result'):
        z_id = str(d['result'][0].get('id', ''))
    elif not d.get('success'):
        err = '; '.join('%s %s' % (e.get('code', ''), e.get('message', '')) for e in d.get('errors') or []) or 'unknown error'
except Exception:
    err = 'invalid or empty API response'
print(f'{z_id}\x1f{err}')
" "$resp" 2>/dev/null || true)"

    IFS=$'\x1f' read -r zone_id api_err <<< "$parsed_out"

    if [[ -n "$zone_id" ]]; then
      matched_zone="$cz"
      break
    fi
  done

  if [[ -n "$zone_id" ]]; then
    log_success "$(_t "CF_SUCCESS_ZONE_FOUND" "$zone_id" "$matched_zone")" >&2
    echo "$zone_id"
    return 0
  else
    if [[ -n "$api_err" ]]; then
      log_error "$(_t "CF_ERR_API_REQUEST_FAILED" "$api_err")"
    fi
    log_error "$(_t "CF_ERR_ZONE_NOT_FOUND" "$domain")"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 5. Zone Security Settings (Full Strict, Always HTTPS, TLS 1.2)
# ------------------------------------------------------------------------------
cf_configure_zone_settings() {
  local zone_id="$1"
  local token="$2"
  local dry_run="${3:-false}"

  # 讀取設定（cf-default-mode / cf-always-https / cf-min-tls）：clp.local > clp.conf > templates/clp.conf。
  # 預設值寫在 templates/clp.conf，程式碼中不留備援值；缺值或不合法時報錯並停止（不套用任何 zone 設定）。
  local ssl_mode https_mode min_tls
  ssl_mode="$(config_get_valid CF_DEFAULT_MODE)" || return 1
  https_mode="$(config_get_valid CF_ALWAYS_HTTPS)" || return 1
  min_tls="$(config_get_valid CF_MIN_TLS)" || return 1

  log_step "$(_t "CF_STEP_CONFIG_SETTINGS")"

  if [[ "$dry_run" == "true" ]]; then
    log_info "[DRY-RUN] PATCH /zones/${zone_id}/settings/ssl {\"value\":\"${ssl_mode}\"}"
    log_info "[DRY-RUN] PATCH /zones/${zone_id}/settings/always_use_https {\"value\":\"${https_mode}\"}"
    log_info "[DRY-RUN] PATCH /zones/${zone_id}/settings/min_tls_version {\"value\":\"${min_tls}\"}"
    return 0
  fi

  local ok_count=0 resp
  resp="$(cf_api_call "PATCH" "/zones/${zone_id}/settings/ssl" "$token" "{\"value\":\"${ssl_mode}\"}" || true)"
  if echo "$resp" | grep -q '"success":true'; then
    log_success "$(_t "CF_SUCCESS_SSL_SET") (${ssl_mode})"; ok_count=$((ok_count + 1))
  else
    log_warn "$(_t "CF_WARN_SETTING_FAILED" "ssl" "$resp")"
  fi

  resp="$(cf_api_call "PATCH" "/zones/${zone_id}/settings/always_use_https" "$token" "{\"value\":\"${https_mode}\"}" || true)"
  if echo "$resp" | grep -q '"success":true'; then
    log_success "$(_t "CF_SUCCESS_HTTPS_SET") (${https_mode})"; ok_count=$((ok_count + 1))
  else
    log_warn "$(_t "CF_WARN_SETTING_FAILED" "always_use_https" "$resp")"
  fi

  resp="$(cf_api_call "PATCH" "/zones/${zone_id}/settings/min_tls_version" "$token" "{\"value\":\"${min_tls}\"}" || true)"
  if echo "$resp" | grep -q '"success":true'; then
    log_success "$(_t "CF_SUCCESS_TLS_SET") (${min_tls})"; ok_count=$((ok_count + 1))
  else
    log_warn "$(_t "CF_WARN_SETTING_FAILED" "min_tls_version" "$resp")"
  fi

  [[ "$ok_count" -gt 0 ]]
}

# ------------------------------------------------------------------------------
# 6. Parse and Interpolate WAF Rules Configuration
# ------------------------------------------------------------------------------
cf_load_waf_rules_json() {
  local domain="$1"
  local whitelist_ips="${2:-}"
  local custom_conf="${3:-}"

  local conf_file=""
  if [[ -n "$custom_conf" && ! -f "$custom_conf" ]]; then
    log_error "$(_t "CF_ERR_RULES_FILE_NOT_FOUND" "$custom_conf")"
    return 1
  fi
  # -rules=<檔案> > /etc/clp/cf-rules.local > /etc/clp/cf-rules.conf > templates/cf-rules.conf
  # （舊版手動複製、從未修改過的 cf-rules.conf 會略過，改讀 template；修改過的照舊使用）
  if [[ -n "$custom_conf" ]]; then
    conf_file="$custom_conf"
  elif ! conf_file="$(clp_conf_pick_file "${CLP_CONFIG_DIR:-/etc/clp}" cf-rules)"; then
    log_error "$(_t "CF_ERR_RULES_FILE_NOT_FOUND" "${CLP_ROOT_DIR}/templates/cf-rules.conf")"
    return 1
  fi

  # 只有規則內容用到 ${SERVER_IP} 時才查詢伺服器 IP（使用 core 的 get_server_ip，含 IPv4 格式驗證）
  local s_ip=""
  if grep -q '${SERVER_IP}' "$conf_file" 2>/dev/null; then
    s_ip="$(get_server_ip 2>/dev/null || true)"
    if [[ ! "$s_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      log_error "$(_t "CF_ERR_SERVER_IP_UNKNOWN")"
      return 1
    fi
  fi

  # Format space-separated IP literals for Cloudflare Ruleset (only if provided)
  local ip_list=""
  if [[ -n "$whitelist_ips" ]]; then
    ip_list="$(echo "$whitelist_ips" | tr ',' ' ' | tr -s ' ')"
  fi
  # Deduplicate IPs
  local final_ip_set=""
  if [[ -n "$ip_list" ]]; then
    final_ip_set="$(echo "$ip_list" | tr ' ' '\n' | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi

  python3 -I - "$conf_file" "$domain" "$s_ip" "$final_ip_set" <<'PYEOF'
import sys, re, json

conf_path = sys.argv[1]
domain = sys.argv[2]
server_ip = sys.argv[3]
ip_whitelist = sys.argv[4].strip()

with open(conf_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace macros
content = content.replace('${DOMAIN}', domain)
content = content.replace('${SERVER_IP}', server_ip)

# Handle legacy or explicit ADMIN_IP_WHITELIST macro
if ip_whitelist:
    content = content.replace('${ADMIN_IP_WHITELIST}', ip_whitelist)
else:
    # If no whitelist provided, cleanly strip legacy "and not ip.src in {${ADMIN_IP_WHITELIST}}"
    content = re.sub(r'\s*and\s+not\s+(\(?ip\.src\s+in\s*\{\$\{ADMIN_IP_WHITELIST\}\}\)?)', '', content)
    content = content.replace('${ADMIN_IP_WHITELIST}', '')

sections = re.findall(r'\[rule:([a-zA-Z0-9_\-]+)\](.*?)(?=\n\[rule:|\Z)', content, re.DOTALL)
rules = []

for name, body in sections:
    rule_dict = {'name': name, 'enabled': True, 'action': 'block', 'description': '', 'expression': ''}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        if '=' in line:
            k, v = line.split('=', 1)
            k = k.strip().lower()
            v = v.strip()
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                if len(v) >= 2:
                    v = v[1:-1]
            if k == 'enabled':
                rule_dict['enabled'] = v.lower() in ('true', '1', 'yes', 'on')
            elif k == 'action':
                rule_dict['action'] = v
            elif k == 'description':
                rule_dict['description'] = v
            elif k == 'expression':
                rule_dict['expression'] = v

    if rule_dict['enabled'] and rule_dict['expression']:
        expr = rule_dict['expression'].strip()

        # If whitelist was provided and rule protects admin, append whitelist bypass to each group
        if ip_whitelist and ('wp_admin' in name.lower() or 'wp-admin' in expr.lower()) and 'ip.src' not in expr:
            # 以括號包住整個運算式再排除白名單，巢狀或括號內的 or 也不會被拆壞
            expr = f"({expr}) and not ip.src in {{{ip_whitelist}}}"

        # Ensure single conditions without parens get wrapped, without adding outer parens to multi-group rules
        if ' or ' not in expr and not (expr.startswith('(') and expr.endswith(')')):
            expr = f'({expr})'

        # Ensure description starts with [CLP]
        desc = rule_dict['description']
        if not desc.startswith('[CLP]'):
            desc = f'[CLP] {desc}' if desc else f'[CLP] {name}'
        rule_dict['description'] = desc

        rules.append({
            'action': rule_dict['action'],
            'description': rule_dict['description'],
            'expression': expr,
            'enabled': True
        })

print(json.dumps(rules))
PYEOF
}

# ------------------------------------------------------------------------------
# 7. Deploy Custom WAF Ruleset with Coexistence & Quota Guard
# ------------------------------------------------------------------------------
cf_deploy_waf_rules() {
  local zone_id="$1"
  local domain="$2"
  local token="$3"
  local whitelist_ips="${4:-}"
  local custom_conf="${5:-}"
  local dry_run="${6:-false}"

  local planned_rules_json
  if ! planned_rules_json="$(cf_load_waf_rules_json "$domain" "$whitelist_ips" "$custom_conf")"; then
    return 1
  fi

  # 依 zone 方案決定自訂規則上限（Free 5 / Pro 20 / Business 100 / Enterprise 1000）
  local rule_limit
  rule_limit="$(python3 -I -c "
import sys, json
limits = {'free': 5, 'pro': 20, 'business': 100, 'enterprise': 1000}
try:
    d = json.loads(sys.argv[1])
    print(limits.get(((d.get('result') or {}).get('plan') or {}).get('legacy_id', ''), 5))
except Exception:
    print(5)
" "$(cf_api_call "GET" "/zones/${zone_id}" "$token" || true)" 2>/dev/null || echo 5)"

  local planned_count
  planned_count="$(python3 -I -c "import sys, json; print(len(json.loads(sys.argv[1])))" "$planned_rules_json")"

  log_step "$(_t "CF_STEP_DEPLOY_RULES" "$planned_count")"

  # Print active planned rules
  python3 -I -c "
import sys, json
rules = json.loads(sys.argv[1])
for i, r in enumerate(rules, 1):
    print(f\"{i}|{r['description']}|{r['action']}\")
" "$planned_rules_json" | while IFS='|' read -r idx r_desc r_act; do
    log_info "$(_t "CF_INFO_DEPLOY_RULE_ITEM" "$idx" "$r_desc" "$r_act")"
  done

  # Fetch remote entrypoint ruleset (abort on any failure other than "entrypoint not found")
  local existing_rules_json
  if ! existing_rules_json="$(cf_get_entrypoint_rules "$zone_id" "$token")"; then
    log_error "$(_t "CF_ERR_FETCH_RULES_FAILED" "$existing_rules_json")"
    return 1
  fi

  # Run Python merge and quota evaluation
  local merge_result
  merge_result="$(python3 -I -c "
import sys, json

existing_rules = json.loads(sys.argv[1])
planned_json_str = sys.argv[2]

planned_rules = json.loads(planned_json_str)

# Separate non-CLP rules
non_clp_rules = [r for r in existing_rules if not r.get('description', '').startswith('[CLP]')]

total_rules_count = len(non_clp_rules) + len(planned_rules)

# 輸出格式（只需解析一次）：
#   quota_exceeded\n<非 CLP 數>\t<計畫數>\t<總數>\n<每條既有規則一行>
#   ok\n<合併後的 payload JSON>
if total_rules_count > int(sys.argv[3]):
    print('quota_exceeded')
    print(f'{len(non_clp_rules)}\t{len(planned_rules)}\t{total_rules_count}')
    for r in non_clp_rules:
        print(f\"  • {r.get('description', 'Untitled')} (Action: {r.get('action')})\")
    sys.exit(0)

# Merge: Preserve non-CLP rules and add/update CLP rules
merged = []
for r in non_clp_rules:
    merged.append(r)

for pr in planned_rules:
    merged.append(pr)

print('ok')
print(json.dumps({'rules': merged}))
" "$existing_rules_json" "$planned_rules_json" "$rule_limit")"

  local status
  status="$(head -n1 <<< "$merge_result")"

  if [[ "$status" == "quota_exceeded" ]]; then
    local non_clp_cnt planned_cnt tot_cnt
    IFS=$'\t' read -r non_clp_cnt planned_cnt tot_cnt < <(sed -n 2p <<< "$merge_result")

    log_warn "$(_t "CF_WARN_LIMIT_EXCEEDED" "$non_clp_cnt" "$planned_cnt" "$tot_cnt" "$rule_limit")"
    log_info "$(_t "CF_INFO_EXISTING_RULES")"
    tail -n +3 <<< "$merge_result"
    log_warn "$(_t "CF_WARN_ABORT_DEPLOY")"
    return 1
  fi

  local final_payload
  final_payload="$(sed -n 2p <<< "$merge_result")"

  if [[ "$dry_run" == "true" ]]; then
    echo ""
    log_info "$(_t "CF_STATUS_DRY_RUN_HEADER")"
    echo "$final_payload" | python3 -I -m json.tool
    echo ""
    log_success "$(_t "CF_SUCCESS_RULES_DEPLOYED") (DRY-RUN)"
    return 0
  fi

  local put_resp
  put_resp="$(cf_api_call "PUT" "/zones/${zone_id}/rulesets/phases/http_request_firewall_custom/entrypoint" "$token" "$final_payload")"

  if echo "$put_resp" | grep -q -E '"success"[[:space:]]*:[[:space:]]*true'; then
    log_success "$(_t "CF_SUCCESS_RULES_DEPLOYED")"
    return 0
  else
    log_error "Cloudflare API Error: $put_resp"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# cf_get_entrypoint_rules <zone_id> <token>
#   取得 http_request_firewall_custom entrypoint 的現有規則，成功時輸出 JSON 陣列，失敗時輸出錯誤摘要。
#   僅在 Cloudflare 明確回應「entrypoint 不存在」時視為空陣列；其他任何失敗
#   （權限不足、速率限制、網路錯誤、無法解析的回應）都回傳 1，呼叫端必須中止，
#   避免以空清單 PUT 覆寫使用者的自訂規則。
# ------------------------------------------------------------------------------
cf_get_entrypoint_rules() {
  local zone_id="$1"
  local token="$2"
  local get_resp
  get_resp="$(cf_api_call "GET" "/zones/${zone_id}/rulesets/phases/http_request_firewall_custom/entrypoint" "$token" 2>&1 || true)"

  python3 -I -c "
import sys, json
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    print(raw[:500] or 'empty response')
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if d.get('success') and isinstance(d.get('result'), dict):
    print(json.dumps(d['result'].get('rules') or []))
    sys.exit(0)
for e in d.get('errors') or []:
    if e.get('code') == 10003 or 'could not find entrypoint' in str(e.get('message', '')).lower():
        print('[]')
        sys.exit(0)
print(json.dumps(d.get('errors') or d)[:500])
sys.exit(1)
" "$get_resp"
}

# ------------------------------------------------------------------------------
# 8. Remove CLP Custom WAF Rules (Preserve User Custom Rules)
# ------------------------------------------------------------------------------
cf_remove_waf_rules() {
  local zone_id="$1"
  local domain="$2"
  local token="$3"
  local dry_run="${4:-false}"

  log_step "$(_t "CF_STEP_REMOVE_RULES" "$domain")"

  local existing_rules_json
  if ! existing_rules_json="$(cf_get_entrypoint_rules "$zone_id" "$token")"; then
    log_error "$(_t "CF_ERR_FETCH_RULES_FAILED" "$existing_rules_json")"
    return 1
  fi

  local filtered_payload
  filtered_payload="$(python3 -I -c "
import sys, json
rules = json.loads(sys.argv[1])
remaining = [r for r in rules if not r.get('description', '').startswith('[CLP]')]
if len(remaining) == len(rules):
    print('NOOP')
else:
    print(json.dumps({'rules': remaining}))
" "$existing_rules_json")"

  if [[ "$filtered_payload" == "NOOP" ]]; then
    log_success "$(_t "CF_SUCCESS_RULES_REMOVED")"
    return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    log_info "[DRY-RUN] PUT /zones/${zone_id}/rulesets/phases/http_request_firewall_custom/entrypoint"
    echo "$filtered_payload" | python3 -I -m json.tool
    log_success "$(_t "CF_SUCCESS_RULES_REMOVED")"
    return 0
  fi

  local put_resp
  put_resp="$(cf_api_call "PUT" "/zones/${zone_id}/rulesets/phases/http_request_firewall_custom/entrypoint" "$token" "$filtered_payload")"

  if echo "$put_resp" | grep -q -E '"success"[[:space:]]*:[[:space:]]*true'; then
    log_success "$(_t "CF_SUCCESS_RULES_REMOVED")"
    return 0
  else
    log_error "Cloudflare API Error: $put_resp"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 9. Query Cloudflare Edge WAF & Security Status
# ------------------------------------------------------------------------------
# cf_setting_value：從 stdin 的 Cloudflare 設定查詢回應取出 result.value；查詢失敗（success 不是 true、
# 沒有 value、無法解析）時回傳 1，呼叫端顯示「查詢失敗」而不是 unknown
cf_setting_value() {
  python3 -I -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    v = d.get('result', {}).get('value') if d.get('success') is True and isinstance(d.get('result'), dict) else None
except Exception:
    v = None
if v is None:
    sys.exit(1)
print(v)
" 2>/dev/null
}

cf_show_status() {
  local zone_id="$1"
  local domain="$2"
  local token="$3"

  echo -e "${C_CYAN}${C_BOLD}"
  echo "======================================================================"
  echo " $(_t "CF_STATUS_TITLE" "$domain")"
  echo "======================================================================"
  echo -e "${C_NC}"

  echo -e "  • $(_t "CF_STATUS_ZONE_ID" "$zone_id")"

  # Query SSL
  local resp_ssl ssl_val
  resp_ssl="$(cf_api_call "GET" "/zones/${zone_id}/settings/ssl" "$token" 2>/dev/null || true)"
  ssl_val="$(echo "$resp_ssl" | cf_setting_value)" || ssl_val="$(_t "CF_STATUS_QUERY_FAILED")"
  echo -e "  • $(_t "CF_STATUS_SSL_MODE" "$ssl_val")"

  # Query Always HTTPS
  local resp_https https_val
  resp_https="$(cf_api_call "GET" "/zones/${zone_id}/settings/always_use_https" "$token" 2>/dev/null || true)"
  https_val="$(echo "$resp_https" | cf_setting_value)" || https_val="$(_t "CF_STATUS_QUERY_FAILED")"
  echo -e "  • $(_t "CF_STATUS_ALWAYS_HTTPS" "$https_val")"

  # Query Min TLS
  local resp_tls tls_val
  resp_tls="$(cf_api_call "GET" "/zones/${zone_id}/settings/min_tls_version" "$token" 2>/dev/null || true)"
  tls_val="$(echo "$resp_tls" | cf_setting_value)" || tls_val="$(_t "CF_STATUS_QUERY_FAILED")"
  echo -e "  • $(_t "CF_STATUS_MIN_TLS" "$tls_val")"

  # Query DNS Proxy Status
  local resp_dns dns_proxy_badge="Unknown"
  resp_dns="$(cf_api_call "GET" "/zones/${zone_id}/dns_records?name=${domain}" "$token" 2>/dev/null || true)"
  dns_proxy_badge="$(echo "$resp_dns" | python3 -I -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('success'):
        recs = [r for r in d.get('result', []) if r.get('type') in ['A', 'CNAME', 'AAAA'] and r.get('proxiable')]
        if not recs:
            print('No A/CNAME/AAAA')
        elif all(r.get('proxied') for r in recs):
            print('PROXIED')
        else:
            print('DNS_ONLY')
    else:
        print('Error')
except Exception:
    print('Unknown')
" 2>/dev/null || echo "Unknown")"
  case "$dns_proxy_badge" in
    PROXIED) dns_proxy_badge="$(_t "CF_STATUS_DNS_PROXIED")" ;;
    DNS_ONLY) dns_proxy_badge="$(_t "CF_STATUS_DNS_ONLY")" ;;
  esac
  echo -e "  • $(_t "CF_STATUS_DNS_PROXY" "$dns_proxy_badge")"

  echo ""
  # Query Ruleset（查詢失敗時顯示錯誤，不顯示成 0 條規則）
  local rules_json
  if ! rules_json="$(cf_get_entrypoint_rules "$zone_id" "$token")"; then
    echo -e "  ${C_RED}$(_t "CF_STATUS_RULES_QUERY_FAILED" "$rules_json")${C_NC}"
    echo ""
    echo "======================================================================"
    echo ""
    return 0
  fi

  python3 -I -c "
import sys, json
try:
    rules = json.loads(sys.argv[1])
    clp_rules = [r for r in rules if r.get('description', '').startswith('[CLP]')]
    non_clp_rules = [r for r in rules if not r.get('description', '').startswith('[CLP]')]
    total = len(rules)
    print(f'TOTAL|{total}')
    print(f'CLP_COUNT|{len(clp_rules)}')
    for r in clp_rules:
        en = 'Enabled' if r.get('enabled', True) else 'Disabled'
        print(f'CLP_RULE|{r.get(\"description\")}|{r.get(\"action\")}|{en}')
    for r in non_clp_rules:
        en = 'Enabled' if r.get('enabled', True) else 'Disabled'
        print(f'USER_RULE|{r.get(\"description\", \"User Custom Rule\")}|{r.get(\"action\")}|{en}')
except Exception:
    print('TOTAL|0')
" "$rules_json" | while IFS='|' read -r type f1 f2 f3; do
    case "$type" in
      TOTAL)
        echo -e "  $(_t "CF_STATUS_RULES_HEADER" "$f1")"
        ;;
      CLP_RULE)
        echo -e "    ${C_GREEN}✔${C_NC} ${f1} (Action: ${f2}, Status: ${f3})"
        ;;
      USER_RULE)
        echo -e "    ${C_BLUE}ℹ${C_NC} [Custom] ${f1} (Action: ${f2}, Status: ${f3})"
        ;;
    esac
  done

  echo ""
  echo "======================================================================"
  echo ""
}

# ------------------------------------------------------------------------------
# 10. DNS Proxy Status Check and Enablement
# ------------------------------------------------------------------------------
cf_check_and_enable_proxy() {
  local zone_id="$1"
  local domain="$2"
  local token="$3"
  local dry_run="${4:-false}"

  log_step "$(_t "CF_STEP_CHECK_DNS_PROXY" "$domain")"

  # 1. 取得該網域在 Cloudflare 上的 DNS 解析記錄
  local resp
  resp="$(cf_api_call "GET" "/zones/${zone_id}/dns_records?name=${domain}" "$token" || true)"

  # 2. 解析可支援代理的記錄 (A, CNAME, AAAA 且 proxiable 為 true)
  local records_data
  records_data="$(python3 -I -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    if d.get('success'):
        for r in d.get('result', []):
            rtype = r.get('type', '')
            proxiable = r.get('proxiable', False)
            if rtype in ['A', 'CNAME', 'AAAA'] and proxiable:
                rid = r.get('id', '')
                proxied = 'true' if r.get('proxied') else 'false'
                print(f\"{rid}\t{rtype}\t{proxied}\")
except Exception:
    pass
" "$resp" 2>/dev/null || true)"

  if [[ -z "$records_data" ]]; then
    log_warn "$(_t "CF_WARN_DNS_NO_RECORD_FOUND" "$domain")"
    return 0
  fi

  # 3. 檢查是否有任何記錄尚未開啟 Proxy (proxied == false)
  local unproxied_records=()
  local all_proxied=true

  while IFS=$'\t' read -r r_id r_type r_proxied; do
    [[ -z "$r_id" ]] && continue
    if [[ "$r_proxied" == "true" ]]; then
      : # already proxied (orange cloud)
    else
      all_proxied=false
      unproxied_records+=("${r_id}:${r_type}")
    fi
  done <<< "$records_data"

  if [[ "$all_proxied" == "true" ]]; then
    log_success "$(_t "CF_INFO_DNS_PROXY_ALREADY_ON" "$domain")"
    return 0
  fi

  # 4. 偵測到目前為灰色雲朵
  echo ""
  log_warn "$(_t "CF_WARN_DNS_PROXY_OFF" "$domain")"

  local proxy_opt
  proxy_opt="$(opt_get "proxy" "")"
  local enable_proxy=false

  if [[ "$proxy_opt" == "off" || "$proxy_opt" == "false" || "$proxy_opt" == "no" ]]; then
    log_info "$(_t "CF_INFO_KEEP_DNS_PROXY_OFF")"
    return 0
  elif [[ "$proxy_opt" == "on" || "$proxy_opt" == "true" || "$proxy_opt" == "yes" ]]; then
    enable_proxy=true
  elif has_opt "y" || has_opt "yes" || [[ "${CLP_AUTO_YES:-false}" == "true" ]] || ! [[ -t 0 ]]; then
    # -y 只代表自動回答提示，不代表同意切換橘雲（會中斷經由同名稱的 SSH、郵件等服務）；需要明確加 -proxy=on
    log_info "$(_t "CF_INFO_KEEP_DNS_PROXY_OFF")"
    log_info "$(_t "CF_INFO_PROXY_HINT")"
    return 0
  else
    local ans=""
    # 讀到 EOF（Ctrl-D）視為取消
    read -r -p "$(echo -e "${C_CYAN}$(_t "CF_PROMPT_ENABLE_DNS_PROXY")${C_NC}")" ans || ans="n"
    ans=$(echo "${ans:-y}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
      enable_proxy=true
    fi
  fi

  if [[ "$enable_proxy" != "true" ]]; then
    log_info "$(_t "CF_INFO_KEEP_DNS_PROXY_OFF")"
    return 0
  fi

  # 5. 更新為 Proxied (橘色雲朵)
  for item in "${unproxied_records[@]}"; do
    local r_id="${item%%:*}"
    local r_type="${item##*:}"

    log_step "$(_t "CF_STEP_UPDATING_DNS_PROXY" "${domain} (${r_type})")"

    if [[ "$dry_run" == "true" ]]; then
      log_info "[DRY-RUN] PATCH /zones/${zone_id}/dns_records/${r_id} {\"proxied\":true}"
      continue
    fi

    local patch_resp
    patch_resp="$(cf_api_call "PATCH" "/zones/${zone_id}/dns_records/${r_id}" "$token" '{"proxied":true}' || true)"
    if echo "$patch_resp" | grep -q '"success":true'; then
      log_success "$(_t "CF_SUCCESS_DNS_PROXY_ENABLED")"
    else
      log_error "$(_t "CF_ERR_DNS_UPDATE_FAILED" "$patch_resp")"
    fi
  done

  return 0
}
