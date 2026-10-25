#!/usr/bin/env python3
"""
CLP Helper - httpauth Nginx vhost editor (used by lib/httpauth.sh)

Usage:
  httpauth_vhost.py wpadmin-on  <vhost> <htpasswd> <whitelist_directives>
  httpauth_vhost.py wpadmin-off <vhost> <siteuser>
  httpauth_vhost.py path-on     <vhost> <htpasswd> <path> <whitelist_directives>
  httpauth_vhost.py path-off    <vhost> <path>
  httpauth_vhost.py clear-paths <vhost>
  httpauth_vhost.py refresh     <vhost> <htpasswd> <whitelist_directives>

Block layout managed by CLP:
  - WPADMIN: auth directives between "# --- CLP HTTPAUTH WPADMIN START/END ---"
    inside the wp-admin/wp-login regex location.
  - ROOT: auth directives at server level of the HTTPS server block between
    "# --- CLP HTTPAUTH ROOT START/END ---" (inherited by every location).
  - PATH: a whole "location ^~ <path> { ... }" between
    "# --- CLP HTTPAUTH PATH: <path> START/END ---"; inside it the generated
    auth directives sit between "# --- CLP HTTPAUTH AUTH START/END ---" so a
    refresh only replaces that region and never touches the pass-through
    directives (B-8). Legacy PATH blocks without the AUTH markers are migrated
    on refresh.

Exit status: 0 on success, 1 when the vhost cannot be edited safely.
"""
import os
import re
import stat
import sys
import tempfile
import textwrap

ROOT_RE = re.compile(r'(?:^[ \t]*\n)?^[ \t]*# --- CLP HTTPAUTH ROOT START ---.*?# --- CLP HTTPAUTH ROOT END ---[ \t]*\n',
                     re.DOTALL | re.MULTILINE)
WPADMIN_RE = re.compile(r'[ \t]*# --- CLP HTTPAUTH WPADMIN START ---.*?# --- CLP HTTPAUTH WPADMIN END ---[ \t]*\n', re.DOTALL)
AUTH_RE = re.compile(r'[ \t]*# --- CLP HTTPAUTH AUTH START ---.*?# --- CLP HTTPAUTH AUTH END ---[ \t]*\n', re.DOTALL)
# 只移除「整行」的存取控制指令 (B-7)：避免切斷 add_header ... "no-auth_basic" 之類的指令
ACCESS_LINE_RE = re.compile(r'^\s*(auth_basic(_user_file)?|satisfy|allow|deny)\b[^;{}]*;\s*(#.*)?$')
# 同時比對 wp-admin 與 wp-login 的 regex location（含自訂寫法），避免另外新增一個排在後面而無效的 location；
# 只含 wp-admin 的（例如 admin-ajax.php 例外）不算
WPADMIN_LOC_RE = re.compile(r'(?m)^[ \t]*location\s*~\*?\s*(?=[^{;\n]*wp-admin)(?=[^{;\n]*wp-login)[^{;\n]*\{')
LOCATION_SLASH_RE = re.compile(r'(?m)^[ \t]*location\s+/\s*\{')
DEFAULT_PASS = 'proxy_pass http://127.0.0.1:8080;\n'


def read(path):
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
        return f.read()


def write(path, content):
    dirname = os.path.dirname(os.path.abspath(path))
    st = os.stat(path) if os.path.exists(path) else None
    fd, tmp_path = tempfile.mkstemp(dir=dirname, prefix='.tmp_vhost_')
    try:
        with open(fd, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.write(content)
        if st is not None:
            os.chmod(tmp_path, stat.S_IMODE(st.st_mode))
            try:
                os.chown(tmp_path, st.st_uid, st.st_gid)
            except PermissionError:
                pass
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        raise


def block_end(text, open_idx):
    """Return the index just after the '}' matching the '{' at open_idx (B-3: brace counting,
    ignoring braces inside quotes and # comments). Returns -1 if unbalanced."""
    depth = 0
    i = open_idx
    n = len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in ('"', "'"):
            quote = c
        elif c == '#':
            nl = text.find('\n', i)
            i = n if nl == -1 else nl
            continue
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def code_chars(text, start, end):
    """Yield (index, char) for characters between start and end that are outside quotes and # comments."""
    i = start
    quote = None
    while i < end:
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            i += 1
            continue
        if c == '#':
            nl = text.find('\n', i, end)
            if nl == -1:
                return
            i = nl
            continue
        yield i, c
        i += 1


def toplevel_text(body):
    """Directives of this block only: nested {...} blocks, comments and quoted strings removed."""
    out = []
    depth = 0
    for _, c in code_chars(body, 0, len(body)):
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif depth == 0:
            out.append(c)
    return ''.join(out)


def https_server_span(text):
    """(start, end) of the main HTTPS server block (not a redirect block, has location / or root),
    or None when there is no such block (callers then change nothing)."""
    candidate = None
    for m in re.finditer(r'(?m)^[ \t]*server\s*\{', text):
        open_idx = text.index('{', m.start())
        end = block_end(text, open_idx)
        if end == -1:
            continue
        # listen／return／root 只看 server 本身的指令：location 內的 return 301（例如舊網址轉址）不算轉址區塊
        top = toplevel_text(text[open_idx + 1:end - 1])
        if re.search(r'\blisten\s[^;]*443', top):
            # return 可能與其他指令寫在同一行（單行 server 區塊）；toplevel_text 已去掉巢狀區塊與大括號
            if re.search(r'(?:^|;)\s*return\s+(?:30[1278]\b|https?://)', top, re.MULTILINE):
                continue
            if re.search(r'(?m)^\s*location\s+/\s*\{', text[open_idx + 1:end - 1]):
                return (m.start(), end)
            if candidate is None:
                candidate = (m.start(), end)
    return candidate


def search_https(rx, text):
    """Search only inside the main HTTPS server block (B-12: never edit the 8080 or redirect block)."""
    span = https_server_span(text)
    if span:
        return rx.search(text, span[0], span[1])
    return None


def search_wpadmin_loc(text):
    """The wp-admin/wp-login location of the HTTPS server block that serves requests:
    a location that only denies or redirects (e.g. a hardening rule naming both) is skipped;
    one that passes requests on (proxy_pass etc.) is used even if it also has allow/deny."""
    span = https_server_span(text)
    if not span:
        return None
    for m in WPADMIN_LOC_RE.finditer(text, span[0], span[1]):
        open_idx = m.end() - 1
        end = block_end(text, open_idx)
        if end == -1:
            continue
        top = toplevel_text(text[open_idx + 1:end - 1])
        if re.search(r'\b(proxy_pass|fastcgi_pass|try_files)\b', top):
            return m
        if re.search(r'\bdeny\s+all\s*;', top) or re.search(r'(?:^|;)\s*return\b', top, re.MULTILINE):
            continue
        return m
    return None


def patch_deny_all_locations(content):
    """Ensure deny-all locations (e.g. .git, xmlrpc.php) include 'auth_basic off;' (B-6: prevent satisfy any bypass)."""
    pos = 0
    pieces = []
    for m in re.finditer(r'(?m)^[ \t]*location\s+([^{]+)\{', content):
        open_idx = content.index('{', m.start())
        end = block_end(content, open_idx)
        if end == -1:
            continue
        if m.start() < pos:
            continue
        body = content[open_idx + 1:end - 1]
        # 只看這個 location 本身的指令：巢狀 location、limit_except 或註解裡的 deny all 不算
        top = toplevel_text(body)
        if re.search(r'\bdeny\s+all\s*;', top) and not re.search(r'\bauth_basic\b', top):
            if not re.search(r'\b(proxy_pass|fastcgi_pass|try_files)\b', top):
                indent_m = re.search(r'(?m)^([ \t]+)\S', body)
                indent = indent_m.group(1) if indent_m else '    '
                if body.startswith('\n'):
                    new_body = '\n' + indent + 'auth_basic off;\n' + body[1:]
                else:
                    new_body = indent + 'auth_basic off;\n' + body
                pieces.append(content[pos:open_idx + 1])
                pieces.append(new_body)
                pos = end - 1
                continue
    pieces.append(content[pos:])
    return ''.join(pieces)


def auth_lines(htpasswd, wl, realm='Restricted Access', indent='    '):
    out = ''
    if wl.strip():
        out += '\n'.join(indent + l.strip() for l in wl.strip().splitlines() if l.strip()) + '\n'
    out += f'{indent}auth_basic "{realm}";\n'
    out += f'{indent}auth_basic_user_file {htpasswd};\n'
    return out


def strip_access_lines(body):
    return '\n'.join(l for l in body.splitlines() if not ACCESS_LINE_RE.match(l))


def reindent(body, indent='    '):
    body = textwrap.dedent(body.strip('\n'))
    lines = [l.rstrip() for l in body.splitlines()]
    lines = [l for l in lines if l.strip()]
    if not lines:
        return ''
    return '\n'.join(indent + l for l in lines) + '\n'


def get_pass_directives(text):
    """Pass-through directives copied from 'location /' of the HTTPS server block (A-2: single copy)."""
    span = https_server_span(text)
    scope = text[span[0]:span[1]] if span else text
    m = re.search(r'(?m)^[ \t]*location\s+/\s*\{', scope)
    if m:
        open_idx = scope.index('{', m.start())
        end = block_end(scope, open_idx)
        if end != -1:
            body = scope[open_idx + 1:end - 1]
            body = ROOT_RE.sub('', body)
            body = strip_access_lines(body)
            out = reindent(body)
            if out:
                return out
    return '    ' + DEFAULT_PASS


def insert_root_block(text, block):
    """Insert after the server-level 'root' of the HTTPS server block (B-11: never the 8080 block),
    or right after 'server {' when that block has no server-level root."""
    span = https_server_span(text)
    if not span:
        return None
    open_idx = text.index('{', span[0])
    line_starts = []
    depth = 0
    for i, c in code_chars(text, open_idx + 1, span[1] - 1):
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif c == '\n' and depth == 0:
            line_starts.append(i + 1)
    if not line_starts:
        return None
    root_re = re.compile(r'[ \t]*root\s+[^;{}]+;[ \t]*(?:#[^\n]*)?\n')
    for pos in line_starts:
        m = root_re.match(text, pos)
        if m:
            return text[:m.end()] + '\n' + block + text[m.end():]
    pos = line_starts[0]
    return text[:pos] + block + '\n' + text[pos:]


def root_block(htpasswd, wl):
    return ('  # --- CLP HTTPAUTH ROOT START ---\n'
            + auth_lines(htpasswd, wl)
            + '  # --- CLP HTTPAUTH ROOT END ---\n')


def wpadmin_block(htpasswd, wl):
    return ('    # --- CLP HTTPAUTH WPADMIN START ---\n'
            + auth_lines(htpasswd, wl, realm='Restricted Area')
            + '    # --- CLP HTTPAUTH WPADMIN END ---\n')


def path_auth_block(htpasswd, wl):
    return ('    # --- CLP HTTPAUTH AUTH START ---\n'
            + auth_lines(htpasswd, wl)
            + '    # --- CLP HTTPAUTH AUTH END ---\n')


def path_block(path, htpasswd, wl, pass_dirs):
    return (f'# --- CLP HTTPAUTH PATH: {path} START ---\n'
            f'  location ^~ {path} {{\n'
            + path_auth_block(htpasswd, wl)
            + pass_dirs
            + '  }\n'
            f'  # --- CLP HTTPAUTH PATH: {path} END ---\n')


def path_region_re(path):
    p = re.escape(path)
    return re.compile(rf'[ \t]*# --- CLP HTTPAUTH PATH: {p} START ---.*?# --- CLP HTTPAUTH PATH: {p} END ---[ \t]*\n(?:[ \t]*\n)?',
                      re.DOTALL)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_wpadmin_on(vhost, htpasswd, wl):
    content = WPADMIN_RE.sub('', read(vhost))
    block = wpadmin_block(htpasswd, wl)
    # 插入在既有 wp-admin location 開頭；CloudPanel 範本原有的 #auth_basic 註解行保留不動，關閉時即可完整還原
    m = search_wpadmin_loc(content)
    if m:
        open_idx = m.end() - 1
        nl = content.find('\n', open_idx)
        rest = content[open_idx + 1:nl] if nl != -1 else content[open_idx + 1:]
        if nl != -1 and re.fullmatch(r'[ \t\r]*(?:#.*)?', rest):
            # '{' 後面只有空白、CR 或註解：插在下一行
            new_content = content[:nl + 1] + block + content[nl + 1:]
        else:
            new_content = content[:open_idx + 1] + '\n' + block + content[open_idx + 1:]
    else:
        wp_loc = (f'location ~/(wp-admin/|wp-login.php) {{\n{block}{get_pass_directives(content)}  }}\n\n')
        m = search_https(LOCATION_SLASH_RE, content)
        if not m:
            return 1
        line_start = content.rfind('\n', 0, m.start()) + 1
        indent = re.match(r'[ \t]*', content[line_start:]).group(0)
        new_content = content[:line_start] + indent + wp_loc + content[line_start:]
    write(vhost, new_content)
    return 0


def cmd_wpadmin_off(vhost, siteuser):
    content = read(vhost)
    default_comment = (f'    #auth_basic "Restricted Area";\n'
                       f'    #auth_basic_user_file /home/{siteuser}/.htpasswd;\n')

    def replace_block(m):
        # 若同一 location 內仍保有範本原本的註解行（新版啟用時不會移除），只需移除 CLP 區塊
        after = content[m.end():m.end() + 300]
        return '' if re.match(r'\s*#\s*auth_basic\b', after) else default_comment

    content = WPADMIN_RE.sub(replace_block, content)
    # Comment out any remaining active auth lines inside the wp-admin location
    m = search_wpadmin_loc(content)
    if m:
        open_idx = m.end() - 1
        end = block_end(content, open_idx)
        if end != -1:
            body = content[open_idx:end]
            body = re.sub(r'(?m)^[ \t]*auth_basic\s+.*$', '    #auth_basic "Restricted Area";', body)
            body = re.sub(r'(?m)^[ \t]*auth_basic_user_file\s+.*$', f'    #auth_basic_user_file /home/{siteuser}/.htpasswd;', body)
            content = content[:open_idx] + body + content[end:]
    write(vhost, content)
    return 0


def cmd_path_on(vhost, htpasswd, path, wl):
    content = read(vhost)
    if path == '/':
        cleaned = ROOT_RE.sub('', content)
        patched = patch_deny_all_locations(cleaned)
        new_content = insert_root_block(patched, root_block(htpasswd, wl))
        if new_content is None:
            return 1
        write(vhost, new_content)
        return 0

    content = path_region_re(path).sub('', content)
    block = path_block(path, htpasswd, wl, get_pass_directives(content)) + '\n'
    # 插入於 HTTPS server 區塊內的 wp-admin regex location 或 location / 之前
    m = search_wpadmin_loc(content) or search_https(LOCATION_SLASH_RE, content)
    if not m:
        return 1
    line_start = content.rfind('\n', 0, m.start()) + 1
    indent = re.match(r'[ \t]*', content[line_start:]).group(0)
    content = content[:line_start] + indent + block + content[line_start:]
    write(vhost, content)
    return 0


def cmd_path_off(vhost, path):
    content = read(vhost)
    if path == '/':
        content = ROOT_RE.sub('', content)
    else:
        content = path_region_re(path).sub('', content)
    write(vhost, content)
    return 0


def cmd_clear_paths(vhost):
    content = read(vhost)
    content = re.sub(r'[ \t]*# --- CLP HTTPAUTH PATH: (?!ROOT|WPADMIN)(.*?) START ---.*?# --- CLP HTTPAUTH PATH: \1 END ---[ \t]*\n(?:[ \t]*\n)?',
                     '', content, flags=re.DOTALL)
    write(vhost, content)
    return 0


def refresh_path_region(region, path, htpasswd, wl, fallback_pass):
    """Refresh one PATH region; migrate legacy blocks (no AUTH markers) to the new layout."""
    if AUTH_RE.search(region):
        new_auth = path_auth_block(htpasswd, wl)
        region = AUTH_RE.sub(lambda m: new_auth, region, count=1)
        # 舊版產生的一般前綴 location 一併改為 ^~
        region = re.sub(rf'location\s+{re.escape(path)}\s*\{{', f'location ^~ {path} {{', region, count=1)
        return region

    # Legacy block: keep its own pass-through directives (minus access-control lines)
    m = re.search(rf'location\s+(?:\^~\s+)?{re.escape(path)}\s*\{{', region)
    pass_dirs = fallback_pass
    if m:
        open_idx = region.index('{', m.start())
        end = block_end(region, open_idx)
        if end != -1:
            inner = reindent(strip_access_lines(region[open_idx + 1:end - 1]))
            if inner:
                pass_dirs = inner
    return '  ' + path_block(path, htpasswd, wl, pass_dirs)


def cmd_refresh(vhost, htpasswd, wl):
    content = read(vhost)

    if '# --- CLP HTTPAUTH WPADMIN START ---' in content:
        block = wpadmin_block(htpasswd, wl)
        content = WPADMIN_RE.sub(lambda m: block, content)

    # ROOT: replace and (for legacy blocks inside 'location /') move to server level
    if '# --- CLP HTTPAUTH ROOT START ---' in content:
        cleaned = ROOT_RE.sub('', content)
        patched = patch_deny_all_locations(cleaned)
        relocated = insert_root_block(patched, root_block(htpasswd, wl))
        if relocated is None:
            return 1
        content = relocated

    fallback_pass = get_pass_directives(content)
    for path in re.findall(r'# --- CLP HTTPAUTH PATH: (.*?) START ---', content):
        rx = path_region_re(path)
        m = rx.search(content)
        if not m:
            continue
        trailing_blank = m.group(0).endswith('\n\n')
        new_region = refresh_path_region(m.group(0).rstrip('\n') + '\n', path, htpasswd, wl, fallback_pass)
        if trailing_blank:
            new_region += '\n'
        content = content[:m.start()] + new_region + content[m.end():]

    write(vhost, content)
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 1
    cmd, args = argv[1], argv[2:]
    handlers = {
        'wpadmin-on': (cmd_wpadmin_on, 3),
        'wpadmin-off': (cmd_wpadmin_off, 2),
        'path-on': (cmd_path_on, 4),
        'path-off': (cmd_path_off, 2),
        'clear-paths': (cmd_clear_paths, 1),
        'refresh': (cmd_refresh, 3),
    }
    if cmd not in handlers or len(args) != handlers[cmd][1]:
        sys.stderr.write(__doc__)
        return 1
    try:
        return handlers[cmd][0](*args)
    except Exception as e:  # never leave a half-written vhost without telling the caller
        sys.stderr.write(f'httpauth_vhost.py {cmd} failed: {e}\n')
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
