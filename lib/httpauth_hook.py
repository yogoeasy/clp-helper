#!/usr/bin/env python3
"""
CLP Helper - httpauth nginx hook files (plan 51; used by lib/httpauth.sh and lib/nginx_hooks.sh)

The protection of a site lives in clp's own files, included from the site's vhost through the clp
hook lines (vhost_tpl.py hooks-add), so CloudPanel regenerating the vhost no longer removes it:
  /etc/nginx/clp-helper/sites/<domain>/httpauth.conf       server level: state, auth_basic with a variable
  /etc/nginx/clp-helper/sites/<domain>/http/httpauth.conf  http level: geo of the IP whitelist (only if any)
No location is defined and "satisfy any" is not used: deny-all locations and CloudPanel's blocked IPs
stay denied for whitelisted IPs and for users with a password.

Usage:
  httpauth_hook.py state <file>       protections recorded in a hook file, one per line: "wpadmin", "path <p>"
  httpauth_hook.py render --domain D --htpasswd F [--whitelist W] --out DIR
                                      (stdin: protections, one per line) writes DIR/server.conf and,
                                      when the whitelist has valid entries, DIR/http.conf; invalid
                                      whitelist entries are printed as "INVALID\\t<entry>"
  httpauth_hook.py check-path <path>  exit 0 when the path can be protected
  httpauth_hook.py basic-auth --db DB --domain D
                                      1 when CloudPanel's own Basic Auth is active for the site, else 0
                                      (database opened read-only)

Exit status: 0 ok, 1 error, 2 usage / invalid input
"""
import hashlib
import ipaddress
import os
import re
import sqlite3
import sys

STATE_PREFIX = '# clp-httpauth: '
DOMAIN_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
# 路徑會放進雙引號中的 regex：拒絕會破壞或注入設定的字元，$ 會被 nginx 當成變數
PATH_BAD_RE = re.compile(r'[\s\\{};#\'"$\x00-\x1f\x7f]')
FILE_BAD_RE = re.compile(r'[\s\\{};#\'"$\x00-\x1f\x7f]')
PCRE_META = set('.^*+?()[]|')
WPADMIN_RE = r'/(wp-admin/|wp-login\.php)'
REALM_WPADMIN = 'Restricted Area'
REALM_PATH = 'Restricted Access'


def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def var_id(domain):
    return hashlib.sha256(domain.encode('utf-8')).hexdigest()[:12]


def valid_path(p):
    return p.startswith('/') and not PATH_BAD_RE.search(p) and len(p) <= 1024


def path_regex(p):
    return '^' + ''.join('\\' + c if c in PCRE_META else c for c in p)


def parse_state(lines):
    wpadmin = False
    paths = set()
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line == 'wpadmin':
            wpadmin = True
        elif line.startswith('path '):
            p = line[5:].strip()
            if not valid_path(p):
                fail("invalid path: %s" % p, 2)
            paths.add(p)
        else:
            fail("invalid state line: %s" % line, 2)
    return wpadmin, sorted(paths)


def read_whitelist(path):
    valid, invalid = [], []
    if not path or not os.path.isfile(path):
        return valid, invalid
    with open(path, encoding='utf-8', errors='replace') as f:
        for raw in f:
            v = raw.strip()
            if not v or v.startswith('#'):
                continue
            ok = bool(re.fullmatch(r'[0-9A-Fa-f.:/]+', v))
            if ok and '/' in v and not v.split('/', 1)[1].isdigit():
                ok = False
            if ok:
                try:
                    ipaddress.ip_network(v, strict=False)
                except ValueError:
                    ok = False
            if ok and v not in valid:
                valid.append(v)
            elif not ok:
                invalid.append(v)
    return valid, invalid


def render_server(domain, htpasswd, wpadmin, paths, has_wl):
    v = '$clp_ha_' + var_id(domain)
    out = ['# Managed by CLP Helper (clp httpauth %s). Do not edit: this file is rewritten.' % domain]
    if wpadmin:
        out.append(STATE_PREFIX + 'wpadmin')
    for p in paths:
        out.append(STATE_PREFIX + 'path ' + p)
    out.append('set %s off;' % v)
    if '/' in paths:
        out.append('set %s "%s";' % (v, REALM_PATH))
    if wpadmin:
        out += ['if ($uri ~ "%s") {' % WPADMIN_RE, '  set %s "%s";' % (v, REALM_WPADMIN), '}']
    for p in paths:
        if p != '/':
            out += ['if ($uri ~ "%s") {' % path_regex(p), '  set %s "%s";' % (v, REALM_PATH), '}']
    if has_wl:
        out += ['if ($clp_hawl_%s) {' % var_id(domain), '  set %s off;' % v, '}']
    out.append('auth_basic %s;' % v)
    out.append('auth_basic_user_file %s;' % htpasswd)
    return '\n'.join(out) + '\n'


def render_http(domain, ips):
    out = ['# Managed by CLP Helper (clp httpauth %s). Do not edit: this file is rewritten.' % domain,
           'geo $clp_hawl_%s {' % var_id(domain), '  default 0;']
    out += ['  %s 1;' % ip for ip in ips]
    out.append('}')
    return '\n'.join(out) + '\n'


def write_file(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(text)


def cmd_state(path):
    if not os.path.isfile(path):
        return
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith(STATE_PREFIX):
                print(line[len(STATE_PREFIX):].strip())


def cmd_render(domain, htpasswd, whitelist, out_dir):
    if not DOMAIN_RE.match(domain):
        fail("invalid domain", 2)
    if not htpasswd.startswith('/') or FILE_BAD_RE.search(htpasswd):
        fail("invalid htpasswd path", 2)
    wpadmin, paths = parse_state(sys.stdin)
    if not wpadmin and not paths:
        fail("nothing to protect", 2)
    ips, invalid = read_whitelist(whitelist)
    for v in invalid:
        print("INVALID\t%s" % v)
    write_file(os.path.join(out_dir, 'server.conf'), render_server(domain, htpasswd, wpadmin, paths, bool(ips)))
    if ips:
        write_file(os.path.join(out_dir, 'http.conf'), render_http(domain, ips))


def cmd_basic_auth(db, domain):
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    try:
        row = conn.execute("SELECT b.is_active FROM site s JOIN basic_auth b ON b.id = s.basic_auth_id "
                           "WHERE s.domain_name = ?", (domain,)).fetchone()
    except sqlite3.OperationalError:
        row = None  # 沒有 basic_auth 資料表的 CloudPanel 版本
    finally:
        conn.close()
    print(1 if row and str(row[0]) == '1' else 0)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ''
    rest = argv[2:]
    if cmd == 'state' and len(rest) == 1:
        return cmd_state(rest[0])
    if cmd == 'check-path' and len(rest) == 1:
        sys.exit(0 if valid_path(rest[0]) else 2)
    args = {}
    i = 0
    while i < len(rest):
        if rest[i] in ('--domain', '--htpasswd', '--whitelist', '--out', '--db') and i + 1 < len(rest):
            args[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            fail(__doc__, 2)
    try:
        if cmd == 'render' and {'domain', 'htpasswd', 'out'} <= set(args):
            cmd_render(args['domain'], args['htpasswd'], args.get('whitelist'), args['out'])
        elif cmd == 'basic-auth' and {'db', 'domain'} <= set(args):
            cmd_basic_auth(args['db'], args['domain'])
        else:
            fail(__doc__, 2)
    except (OSError, sqlite3.Error) as e:
        fail("error: %s" % e)


if __name__ == '__main__':
    main(sys.argv)
