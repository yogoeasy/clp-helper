#!/usr/bin/env python3
"""
CLP Helper - diagnose / fix "Varnish is on but nothing is cached" (used by lib/site.sh)

Usage:
  varnish_fix.py list <db>
      stdout: "<domain>" per PHP site
  varnish_fix.py diagnose <db> <domain>
      stdout: key=value lines (type, varnish_db, settings, front, vhost, userini, wfwaf, cached, conclusion, user, root)
  varnish_fix.py fix-vhost <vhost> <controller> <out_file>
      writes the edited vhost to <out_file>
  varnish_fix.py fix-wfwaf <site_root> <user> <backup_dir>
      adds the controller include to <site_root>/wordfence-waf.php (backup in <backup_dir>)
  varnish_fix.py probe <domain>
      stdout: yes | no  (X-Cache-Lifetime from the 8080 backend)

How CloudPanel's Varnish works:
  - Varnish only caches responses that carry Cache-Control (plus X-Cache-Lifetime /
    X-Cache-Tags); /home/<user>/.varnish-cache/controller.php sends them and must be
    loaded through PHP's auto_prepend_file.
  - CloudPanel adds "auto_prepend_file=<controller>;" right after "upload_max_filesize=...;"
    inside "fastcgi_param PHP_VALUE" of the 8080 server block, when site.varnish_cache=1
    and settings.json has "enabled": true.
  - The plain "location / {" of the front-end (80/443) server block has
    {{varnish_proxy_pass}} in the vhost template. CloudPanel renders it as
    "proxy_pass http://<settings.json server>;" when site.varnish_cache=1, "enabled" is
    true and "server" is set, otherwise as "proxy_pass http://127.0.0.1:8080;" (no
    Varnish). The vhost is only re-rendered when the site is saved in CloudPanel, so a
    settings.json switched on later (e.g. by the WordPress plugin) leaves it at 8080.
    The wp-admin location always proxies to 8080; that is not checked.
  - Wordfence's firewall optimization writes <root>/.user.ini with
    auto_prepend_file=<root>/wordfence-waf.php, which overrides the vhost value; the
    controller then only runs if wordfence-waf.php includes it ("Include" option).

Exit status: 0 success (fix-*: changed), 3 fix-*: nothing to change,
2 unexpected structure or other error.
"""
import datetime
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from clp_fileops import read_text_nofollow, safe_atomic_write  # noqa: E402

DOMAIN_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
USER_RE = re.compile(r'^[a-z_][a-z0-9_.-]{0,63}$')
SERVER_RE = re.compile(r'^\s*server\s*\{\s*$')
LISTEN_8080_RE = re.compile(r'^\s*listen\s+(\[::\]:)?8080\b')
LOCATION_ROOT_RE = re.compile(r'^\s*location\s+/\s*\{\s*$')
PLACEHOLDER_RE = re.compile(r'\{\{\s*([a-z0-9_]+)\s*\}\}')
DEFAULT_PROXY_PASS = "http://127.0.0.1:8080"


def fail(msg, code=2):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def controller_path(user):
    return "/home/%s/.varnish-cache/controller.php" % user


# ------------------------------------------------------------------ vhost
def server_blocks(lines):
    """[(start, end)] of the top-level server blocks."""
    blocks, depth, start = [], 0, None
    for i, line in enumerate(lines):
        code = line.split('#', 1)[0]
        if depth == 0 and SERVER_RE.match(code):
            start = i
        depth += code.count('{') - code.count('}')
        if depth == 0 and start is not None and '}' in code:
            blocks.append((start, i))
            start = None
    return blocks


def backend_block(lines):
    """(start, end) of the single 8080 server block."""
    found = [(s, e) for s, e in server_blocks(lines)
             if any(LISTEN_8080_RE.match(l) for l in lines[s:e + 1])]
    if len(found) != 1:
        fail("expected exactly one 8080 server block, found %d" % len(found))
    return found[0]


def php_value_range(lines):
    """(first_value_line, last_value_line) of the PHP_VALUE string in the 8080 block."""
    s, e = backend_block(lines)
    starts = [i for i in range(s, e + 1) if re.match(r'^\s*fastcgi_param\s+PHP_VALUE\s+"\s*$', lines[i])]
    if len(starts) != 1:
        fail("expected exactly one multi-line 'fastcgi_param PHP_VALUE \"' in the 8080 block, found %d" % len(starts))
    for j in range(starts[0] + 1, e + 1):
        if lines[j].rstrip().endswith('";'):
            return starts[0] + 1, j
    fail("unterminated PHP_VALUE")


def vhost_prepend(lines, controller):
    a, b = php_value_range(lines)
    vals = []
    for i in range(a, b + 1):
        m = re.match(r'^\s*auto_prepend_file\s*=\s*([^;"]+)', lines[i])
        if m:
            vals.append(m.group(1).strip())
    if not vals:
        return "absent"
    if vals == [controller]:
        return "present"
    return "other"


def front_location(lines):
    """Lines inside the plain 'location / {' of the single non-8080 server block; None when not found.
    {{placeholders}} (vhost templates) are turned into __clp_ph_<name>__ first so their braces do not count."""
    lines = [PLACEHOLDER_RE.sub(r'__clp_ph_\1__', l) for l in lines]
    found = []
    for s, e in server_blocks(lines):
        if any(LISTEN_8080_RE.match(l) for l in lines[s:e + 1]):
            continue
        locs = [i for i in range(s, e + 1) if LOCATION_ROOT_RE.match(lines[i].split('#', 1)[0])]
        if len(locs) == 1:
            found.append(locs[0])
    if len(found) != 1:
        return None
    depth = 0
    for j in range(found[0], len(lines)):
        code = lines[j].split('#', 1)[0]
        depth += code.count('{') - code.count('}')
        if depth == 0:
            return lines[found[0] + 1:j]
    return None


def front_proxy_pass(lines):
    """proxy_pass value of the front-end 'location /'; None when the layout is unexpected."""
    body = front_location(lines)
    if body is None:
        return None
    vals = [m.group(1) for m in (re.match(r'^\s*proxy_pass\s+([^\s;]+)\s*;', l) for l in body) if m]
    return vals[0] if len(vals) == 1 else None


def template_uses_placeholder(template):
    """True when the vhost template's front-end 'location /' has {{varnish_proxy_pass}}."""
    body = front_location((template or "").split("\n"))
    return body is not None and any(l.strip() == "__clp_ph_varnish_proxy_pass__" for l in body)


def port_of(url):
    m = re.match(r'^https?://[^/]+:(\d+)/?$', url or "")
    return m.group(1) if m else "other"


def cmd_fix_vhost(vhost, controller, out):
    with open(vhost, encoding="utf-8") as f:
        lines = f.read().split("\n")
    st = vhost_prepend(lines, controller)
    if st == "present":
        sys.exit(3)
    if st == "other":
        fail("PHP_VALUE already has a different auto_prepend_file; not modified")
    a, b = php_value_range(lines)
    ups = [i for i in range(a, b + 1) if re.match(r'^\s*upload_max_filesize\s*=', lines[i])]
    if len(ups) != 1:
        fail("expected exactly one upload_max_filesize line in PHP_VALUE, found %d" % len(ups))
    i = ups[0]
    if lines[i].rstrip().endswith('";'):
        fail("upload_max_filesize is the last PHP_VALUE line; unexpected layout")
    indent = re.match(r'^(\s*)', lines[i]).group(1)
    lines.insert(i + 1, "%sauto_prepend_file=%s;" % (indent, controller))
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ------------------------------------------------------------------ .user.ini / wordfence-waf.php
def read_user_file(path, user):
    """Read a file under /home/<user> without following symlinks; None when it does not exist."""
    if not os.path.lexists(path):
        return None
    return read_text_nofollow(path, user=user)


def userini_prepend(root, user):
    text = read_user_file(os.path.join(root, ".user.ini"), user)
    if text is None:
        return None
    val = None
    for line in text.splitlines():
        line = line.split(';', 1)[0] if line.lstrip().startswith(';') else line
        m = re.match(r'^\s*auto_prepend_file\s*=\s*["\']?([^"\'\s;]*)["\']?\s*$', line)
        if m:
            val = m.group(1)
    return val


def wfwaf_includes(text, controller):
    pat = r'\b(include|require)(_once)?\s*\(?\s*[\'"]%s[\'"]' % re.escape(controller)
    return re.search(pat, text) is not None


def cmd_fix_wfwaf(root, user, backup_dir):
    if not USER_RE.match(user):
        fail("invalid user")
    path = os.path.join(root, "wordfence-waf.php")
    controller = controller_path(user)
    text = read_user_file(path, user)
    if text is None:
        fail("%s not found" % path)
    if wfwaf_includes(text, controller):
        sys.exit(3)
    lines = text.split("\n")
    if not lines or not lines[0].startswith("<?php"):
        fail("wordfence-waf.php does not start with <?php; not modified")
    idx = [i for i, l in enumerate(lines) if l.startswith("if (file_exists(")]
    if not idx:
        fail("no 'if (file_exists(' line in wordfence-waf.php; not modified")
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    block = [
        "// Added by CLP Helper (%s): load the CloudPanel Varnish cache controller, "
        "same as Wordfence's \"Include\" option" % now,
        "if (file_exists('%s')) {" % controller,
        "\tinclude_once '%s';" % controller,
        "}",
    ]
    new_text = "\n".join(lines[:idx[0]] + block + lines[idx[0]:])

    os.makedirs(backup_dir, mode=0o700, exist_ok=True)
    bak = os.path.join(backup_dir, "wordfence-waf.php")
    with open(bak, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(bak, 0o600)

    php = shutil_which("php")
    if php:
        fd, tmp = tempfile.mkstemp(dir=backup_dir, suffix=".php")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        r = subprocess.run([php, "-l", tmp], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        os.unlink(tmp)
        if r.returncode != 0:
            fail("php -l failed for the edited wordfence-waf.php; not modified")
    else:
        sys.stderr.write("warning: php not found, skipped php -l\n")

    safe_atomic_write(path, new_text, user=user, allow_create=False)


def shutil_which(name):
    for d in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep):
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


# ------------------------------------------------------------------ probe / diagnose
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def probe(domain):
    req = urllib.request.Request("http://127.0.0.1:8080/", headers={
        "Host": domain, "X-Forwarded-Proto": "https", "User-Agent": "clp-helper-varnish-probe"})
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        resp = opener.open(req, timeout=30)
        headers = resp.headers
    except urllib.error.HTTPError as e:
        headers = e.headers
    except Exception:
        return "error"
    return "yes" if headers.get("X-Cache-Lifetime") else "no"


def site_row(db, domain):
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    row = conn.execute("SELECT type, varnish_cache, user, vhost_template FROM site WHERE domain_name = ?",
                       (domain,)).fetchone()
    conn.close()
    return row


def cmd_list(db):
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    for (d,) in conn.execute("SELECT domain_name FROM site WHERE type = 'php' ORDER BY domain_name"):
        print(d)
    conn.close()


def cmd_diagnose(db, domain):
    if not DOMAIN_RE.match(domain):
        fail("invalid domain: %s" % domain)
    row = site_row(db, domain)
    if row is None:
        fail("site not found in CloudPanel database: %s" % domain)
    stype, vdb, user = row[0], 1 if row[1] else 0, row[2]
    if not USER_RE.match(user or ""):
        fail("unexpected site user: %r" % user)
    root = "/home/%s/htdocs/%s" % (user, domain)
    controller = controller_path(user)
    out = {"type": stype, "varnish_db": str(vdb), "user": user, "root": root,
           "settings": "-", "front": "-", "vhost": "-", "userini": "-", "wfwaf": "-", "cached": "-"}

    def done(conclusion):
        out["conclusion"] = conclusion
        for k in ("type", "varnish_db", "settings", "front", "vhost", "userini", "wfwaf", "cached", "conclusion",
                  "user", "root"):
            print("%s=%s" % (k, out[k]))
        sys.exit(0)

    if stype != "php":
        done("not-php")

    s_text = read_user_file("/home/%s/.varnish-cache/settings.json" % user, user)
    server = None
    if s_text is None:
        out["settings"] = "missing"
    else:
        try:
            s_json = json.loads(s_text)
            if not isinstance(s_json, dict):
                raise ValueError
            out["settings"] = "enabled" if s_json.get("enabled") is True else "disabled"
            if isinstance(s_json.get("server"), str) and s_json["server"].strip("/"):
                server = s_json["server"].strip("/")
        except ValueError:
            out["settings"] = "invalid"
    if vdb != 1:
        done("off-db")
    if out["settings"] != "enabled":
        done("off")

    vhost = "/etc/nginx/sites-enabled/%s.conf" % domain
    if not os.path.isfile(vhost):
        done("disabled-site")
    with open(vhost, encoding="utf-8") as f:
        vlines = f.read().split("\n")
    try:
        out["vhost"] = vhost_prepend(vlines, controller)
    except SystemExit:
        out["vhost"] = "error"
    # same rule as CloudPanel's VarnishProxyPass (see the top of this file)
    front = front_proxy_pass(vlines)
    out["front"] = "error" if front is None else port_of(front)
    front_ok = server is not None and front == "http://%s" % server

    up = userini_prepend(root, user)
    if up is None or up == "":
        out["userini"] = "none"
    elif os.path.basename(up) == "wordfence-waf.php" and os.path.dirname(up) == root:
        out["userini"] = "wordfence"
    else:
        out["userini"] = "other:" + up

    if out["userini"] == "wordfence":
        wtext = read_user_file(os.path.join(root, "wordfence-waf.php"), user)
        if wtext is None:
            out["wfwaf"] = "absent"
        else:
            out["wfwaf"] = "included" if wfwaf_includes(wtext, controller) else "missing"

    out["cached"] = probe(domain)
    if not front_ok:
        # saving the vhost in CloudPanel only helps when it would render the Varnish server
        if server is not None and front == DEFAULT_PROXY_PASS and template_uses_placeholder(row[3]):
            done("save-vhost")
        done("skip-front")
    if out["cached"] == "yes":
        done("ok")
    if out["userini"].startswith("other:"):
        done("skip-other")
    if out["vhost"] in ("error", "other"):
        done("skip-vhost")
    need_vhost = out["vhost"] == "absent"
    need_wf = out["userini"] == "wordfence" and out["wfwaf"] == "missing"
    if out["userini"] == "wordfence" and out["wfwaf"] == "absent":
        done("unknown")
    if need_vhost and need_wf:
        done("fix-both")
    if need_vhost:
        done("fix-vhost")
    if need_wf:
        done("fix-wfwaf")
    done("unknown")


def main(argv):
    if len(argv) < 2:
        fail(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == "list" and len(args) == 1:
        cmd_list(*args)
    elif cmd == "diagnose" and len(args) == 2:
        cmd_diagnose(*args)
    elif cmd == "fix-vhost" and len(args) == 3:
        cmd_fix_vhost(*args)
    elif cmd == "fix-wfwaf" and len(args) == 3:
        cmd_fix_wfwaf(*args)
    elif cmd == "probe" and len(args) == 1:
        if not DOMAIN_RE.match(args[0]):
            fail("invalid domain")
        print(probe(args[0]))
    else:
        fail(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (OSError, PermissionError) as e:
        fail("error: %s" % e)
