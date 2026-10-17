#!/usr/bin/env python3
"""
CLP Helper - CloudPanel "Allow traffic from Cloudflare only" helper (used by lib/site.sh)

Usage:
  cf_only.py vhost-status <vhost>
      stdout line 1: on | off | mixed ; line 2: server_name list of the main block
  cf_only.py vhost-set <on|off> <vhost> <out_file>
      writes the edited vhost to <out_file>
  cf_only.py dns-check <domain> <ips_file>
      stdout: "<name>\t<ip>\t<ok|bad>" per resolved address, or "<name>\t-\tnone"
  cf_only.py db-get <db> [<domain>]
      stdout: "<domain>\t<0|1>" per site (all sites when <domain> is omitted)
  cf_only.py db-set <db> <domain> <0|1>
      stdout: previous "<value>\t<updated_at>"
  cf_only.py db-backup <db> <dest>

CloudPanel renders the setting in the main server block (the one with the
`location ~ /.well-known` block and a document root, not the 8080 backend):
  - {{nginx_access_log}}: "access_log <path> main;" <-> "access_log <path> cloudflare;"
  - {{settings}} (the line after the .well-known block and one blank line):
    "  " (off) <-> "    include /etc/nginx/cloudflare/ips;" (on)
Only those two places are touched; anything else rendered into {{settings}}
(for example basic auth) is left as it is.

Exit status: 0 success (vhost-set: changed), 3 vhost-set: already in the
requested state, 1 dns-check: some address is outside Cloudflare,
2 unexpected structure or other error.
"""
import datetime
import ipaddress
import re
import socket
import sqlite3
import sys

INCLUDE_LINE = "    include /etc/nginx/cloudflare/ips;"
INCLUDE_RE = re.compile(r'^\s*include\s+/etc/nginx/cloudflare/ips\s*;\s*$')
ACCESS_RE = re.compile(r'^(\s*access_log\s+\S+\s+)(main|cloudflare)(\s*;\s*)$')
WELLKNOWN_RE = re.compile(r'^\s*location\s+~\s*/\.well-known\s*\{\s*$')
SERVER_RE = re.compile(r'^\s*server\s*\{\s*$')
DOMAIN_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')


def fail(msg, code=2):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def server_blocks(lines):
    """Return [(start, end)] line indexes of top-level server blocks."""
    blocks, depth, start = [], 0, None
    for i, line in enumerate(lines):
        code = line.split('#', 1)[0]
        if depth == 0 and SERVER_RE.match(code):
            start = i
        depth += code.count('{') - code.count('}')
        if depth < 0:
            fail("unbalanced braces in vhost")
        if depth == 0 and start is not None and '}' in code:
            blocks.append((start, i))
            start = None
    if depth != 0:
        fail("unbalanced braces in vhost")
    return blocks


def main_block(lines):
    found = []
    for s, e in server_blocks(lines):
        body = lines[s:e + 1]
        if any(re.match(r'^\s*listen\s+(\[::\]:)?8080\b', l) for l in body):
            continue
        has_root = any(re.match(r'^\s*root\s+\S+', l) for l in body)
        has_wk = any(WELLKNOWN_RE.match(l) for l in body)
        if has_root and has_wk:
            found.append((s, e))
    if len(found) != 1:
        fail("expected exactly one main server block with a root and a .well-known location, found %d" % len(found))
    return found[0]


def block_end(lines, start):
    depth = 0
    for i in range(start, len(lines)):
        code = lines[i].split('#', 1)[0]
        depth += code.count('{') - code.count('}')
        if depth == 0:
            return i
    fail("unterminated location block")


def analyse(lines):
    s, e = main_block(lines)
    access = [i for i in range(s, e + 1) if ACCESS_RE.match(lines[i])]
    if len(access) != 1:
        fail("expected exactly one 'access_log ... main|cloudflare;' line in the main server block, found %d" % len(access))
    includes = [i for i in range(s, e + 1) if INCLUDE_RE.match(lines[i])]
    wk = [i for i in range(s, e + 1) if WELLKNOWN_RE.match(lines[i])]
    if len(wk) != 1:
        fail("expected exactly one .well-known location in the main server block")
    wk_end = block_end(lines, wk[0])
    return s, e, access[0], includes, wk_end


def state_of(lines):
    _, _, acc, includes, _ = analyse(lines)
    cf_log = ACCESS_RE.match(lines[acc]).group(2) == "cloudflare"
    if includes and cf_log:
        return "on"
    if not includes and not cf_log:
        return "off"
    return "mixed"


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def server_names(lines):
    s, e = main_block(lines)
    names = []
    for l in lines[s:e + 1]:
        m = re.match(r'^\s*server_name\s+([^;]+);', l)
        if m:
            names.extend(m.group(1).split())
    return names


def cmd_vhost_status(path):
    lines = read_lines(path)
    print(state_of(lines))
    print(" ".join(server_names(lines)))


def cmd_vhost_set(action, path, out):
    lines = read_lines(path)
    if state_of(lines) == action:
        sys.exit(3)
    _, _, acc, includes, wk_end = analyse(lines)
    m = ACCESS_RE.match(lines[acc])
    lines[acc] = m.group(1) + ("cloudflare" if action == "on" else "main") + m.group(3)
    if action == "on":
        if not includes:
            pos = wk_end + 2
            if wk_end + 1 >= len(lines) or lines[wk_end + 1].strip() != "" or pos >= len(lines):
                fail("unexpected layout after the .well-known location (expected a blank line and the settings line)")
            if lines[pos].strip() == "":
                lines[pos] = INCLUDE_LINE
            else:
                lines.insert(pos, INCLUDE_LINE)
    else:
        for i in sorted(includes, reverse=True):
            prev_blank = i > 0 and lines[i - 1].strip() == ""
            next_blank = i + 1 < len(lines) and lines[i + 1].strip() == ""
            if prev_blank and next_blank:
                lines[i] = "  "   # CloudPanel renders an empty {{settings}} as two spaces
            else:
                del lines[i]
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def load_networks(ips_file):
    nets = []
    with open(ips_file, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^\s*allow\s+([0-9a-fA-F:.]+/\d+)\s*;', line)
            if m:
                nets.append(ipaddress.ip_network(m.group(1), strict=False))
    if not nets:
        fail("no 'allow' networks found in %s" % ips_file)
    return nets


def cmd_dns_check(domain, ips_file):
    if not DOMAIN_RE.match(domain):
        fail("invalid domain: %s" % domain)
    nets = load_networks(ips_file)
    other = domain[4:] if domain.startswith("www.") else "www." + domain
    bad = False
    for name in (domain, other):
        try:
            infos = socket.getaddrinfo(name, None, proto=socket.IPPROTO_TCP)
        except socket.gaierror:
            print("%s\t-\tnone" % name)
            continue
        addrs = sorted({i[4][0] for i in infos})
        for a in addrs:
            ip = ipaddress.ip_address(a.split('%', 1)[0])
            ok = any(ip.version == n.version and ip in n for n in nets)
            bad = bad or not ok
            print("%s\t%s\t%s" % (name, a, "ok" if ok else "bad"))
    sys.exit(1 if bad else 0)


def connect(db):
    conn = sqlite3.connect(db, timeout=15)
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    if str(mode).lower() == "wal":
        # root 寫入會產生 root 擁有的 -wal/-shm 檔，CloudPanel（clp 使用者）之後可能無法寫入
        conn.close()
        fail("CloudPanel database is in WAL mode; refusing to write as root")
    return conn


def cmd_db_get(db, domain=None):
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    if domain:
        rows = conn.execute("SELECT domain_name, allow_traffic_from_cloudflare_only FROM site WHERE domain_name = ?",
                            (domain,)).fetchall()
    else:
        rows = conn.execute("SELECT domain_name, allow_traffic_from_cloudflare_only FROM site ORDER BY domain_name").fetchall()
    for d, v in rows:
        print("%s\t%d" % (d, 1 if v else 0))


def cmd_db_set(db, domain, value):
    if not DOMAIN_RE.match(domain) or value not in ("0", "1"):
        fail("invalid arguments")
    conn = connect(db)
    row = conn.execute("SELECT allow_traffic_from_cloudflare_only, updated_at FROM site WHERE domain_name = ?",
                       (domain,)).fetchone()
    if row is None:
        fail("site not found in CloudPanel database: %s" % domain)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    with conn:
        cur = conn.execute("UPDATE site SET allow_traffic_from_cloudflare_only = ?, updated_at = ? WHERE domain_name = ?",
                           (int(value), now, domain))
        if cur.rowcount != 1:
            fail("unexpected update count %d" % cur.rowcount)
    conn.close()
    print("%d\t%s" % (1 if row[0] else 0, row[1]))


def cmd_db_backup(db, dest):
    src = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    dst = sqlite3.connect(dest)
    with dst:
        src.backup(dst)
    dst.close()
    src.close()


def main(argv):
    if len(argv) < 2:
        fail(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == "vhost-status" and len(args) == 1:
        cmd_vhost_status(args[0])
    elif cmd == "vhost-set" and len(args) == 3 and args[0] in ("on", "off"):
        cmd_vhost_set(*args)
    elif cmd == "dns-check" and len(args) == 2:
        cmd_dns_check(*args)
    elif cmd == "db-get" and len(args) in (1, 2):
        cmd_db_get(*args)
    elif cmd == "db-set" and len(args) == 3:
        cmd_db_set(*args)
    elif cmd == "db-backup" and len(args) == 2:
        cmd_db_backup(*args)
    else:
        fail(__doc__)


if __name__ == "__main__":
    main(sys.argv)
