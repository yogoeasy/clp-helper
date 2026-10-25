#!/usr/bin/env python3
"""
CLP Helper - compare site vhost templates with CloudPanel's official templates (used by lib/site.sh)

CloudPanel copies a vhost template into site.vhost_template when a site is created (only the
{{server_name}} lines are filled in); later updates of the official template never reach existing
sites. This tool tells which official template (and version) a site uses and builds the updated one.

Usage (root; the database is opened read-only, nothing is written to it):
  vhost_tpl.py export --db DB                         JSON {"sites":[...],"templates":{...}} on stdout
  vhost_tpl.py record --state DIR                     (stdin: export JSON) archive the official templates
  vhost_tpl.py status --state DIR [--domain D]        (stdin: export JSON) one line per site, tab separated:
                                                      <domain> <status> <template> <changed lines>
                                                      status: latest | old | custom | skip
  vhost_tpl.py diff --domain D [--name N] [--state DIR]  (stdin: export JSON) unified diff site -> official
  vhost_tpl.py build --domain D --name N              (stdin: export JSON) new template on stdout
  vhost_tpl.py current --domain D                     (stdin: export JSON) the site's template on stdout
  vhost_tpl.py backup-db --db DB --dest FILE          sqlite backup of the database (read-only source)
  vhost_tpl.py set-template --db DB --domain D        (stdin: template) fallback writer, run as the clp user

Comparison ignores CR/LF differences, trailing whitespace and trailing blank lines, and treats every
"server_name ...;" line as {{server_name}}. The template that is written is the official text itself.
Exit status: 0 ok, 1 error, 2 usage / site not found, 3 server_name lines cannot be mapped
"""
import datetime
import difflib
import hashlib
import json
import os
import re
import sqlite3
import sys
import tempfile

SERVER_NAME_RE = re.compile(r'^(\s*)server_name\s+[^;{}]*;\s*$')
PLACEHOLDER_RE = re.compile(r'^(\s*)\{\{server_name\}\}\s*$')
SAFE_NAME_RE = re.compile(r'[^A-Za-z0-9._-]+')


def fail(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def lines_of(text):
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    lines = [l.rstrip() for l in text.split('\n')]
    while lines and lines[-1] == '':
        lines.pop()
    return lines


def normalize(text):
    out = []
    for line in lines_of(text):
        m = SERVER_NAME_RE.match(line)
        out.append(m.group(1) + '{{server_name}}' if m else line)
    return out


def digest(norm_lines):
    return hashlib.sha256('\n'.join(norm_lines).encode('utf-8', 'surrogateescape')).hexdigest()


def changed_lines(a, b):
    return sum(1 for l in difflib.unified_diff(a, b, lineterm='', n=0)
               if l[:1] in '+-' and not l.startswith(('+++', '---')))


def read_export():
    try:
        data = json.load(sys.stdin)
    except ValueError as e:
        fail("invalid export data: %s" % e)
    if not isinstance(data, dict) or not isinstance(data.get('sites'), list) or not isinstance(data.get('templates'), dict):
        fail("invalid export data")
    return data


def find_site(data, domain):
    for s in data['sites']:
        if s.get('domain') == domain:
            return s
    fail("site not found: %s" % domain, 2)


def load_archive(state):
    """{name: {digest: normalized lines}} of every official template version seen before"""
    arch = {}
    if not state or not os.path.isdir(state):
        return arch
    for fn in os.listdir(state):
        if not fn.endswith('.tpl'):
            continue
        try:
            with open(os.path.join(state, fn), encoding='utf-8', errors='surrogateescape') as f:
                first = f.readline()
                body = f.read()
        except OSError:
            continue
        if not first.startswith('# name: '):
            continue
        name = first[len('# name: '):].rstrip('\n')
        norm = normalize(body)
        arch.setdefault(name, {})[digest(norm)] = norm
    return arch


def classify(site, templates, archive):
    """(status, template name, changed lines against the current official template)"""
    if str(site.get('type', '')).lower() != 'php':
        return 'skip', '-', 0
    norm = normalize(site.get('template', ''))
    current = {name: normalize(t) for name, t in templates.items()}
    # 'WordPress' first: WooCommerce and WordPress are almost identical
    names = sorted(current, key=lambda n: (n != 'WordPress', n))
    for name in names:
        if current[name] == norm:
            return 'latest', name, 0
    d = digest(norm)
    for name in names:
        if d in archive.get(name, {}) and name in current:
            return 'old', name, changed_lines(norm, current[name])
    best = min(names, key=lambda n: changed_lines(norm, current[n])) if names else '-'
    return 'custom', best, changed_lines(norm, current[best]) if names else 0


def build(site, official):
    """The official template with {{server_name}} replaced by the site's own server_name lines"""
    site_names = [l.strip() for l in lines_of(site.get('template', '')) if SERVER_NAME_RE.match(l)]
    out_lines = official.split('\n')
    slots = [i for i, l in enumerate(out_lines) if PLACEHOLDER_RE.match(l)]
    if slots:
        if len(site_names) == len(slots):
            values = site_names
        elif site_names and len(set(site_names)) == 1:
            values = [site_names[0]] * len(slots)
        else:
            fail("cannot map the site's server_name lines to the template", 3)
        for i, v in zip(slots, values):
            m = PLACEHOLDER_RE.match(out_lines[i])
            out_lines[i] = m.group(1) + v + ('\r' if out_lines[i].endswith('\r') else '')
    # 與官方範本逐字相同（只換 server_name 那幾行），換行與檔尾不另外調整
    return '\n'.join(out_lines)


def cmd_export(db):
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    try:
        sites = [{'domain': d, 'type': t, 'template': v or ''} for d, t, v in
                 conn.execute("SELECT domain_name, type, vhost_template FROM site ORDER BY domain_name")]
        templates = {n: v or '' for n, v in conn.execute("SELECT name, template FROM vhost_template ORDER BY name")}
    finally:
        conn.close()
    json.dump({'sites': sites, 'templates': templates}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def cmd_record(state):
    data = read_export()
    os.makedirs(state, mode=0o700, exist_ok=True)
    have = load_archive(state)
    added = 0
    for name, text in data['templates'].items():
        norm = normalize(text)
        d = digest(norm)
        if d in have.get(name, {}):
            continue
        fn = "%s-%s.tpl" % (SAFE_NAME_RE.sub('_', name)[:80], d[:16])
        fd, tmp = tempfile.mkstemp(dir=state, prefix='.tmp_')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', errors='surrogateescape') as f:
                f.write("# name: %s\n" % name.replace('\n', ' '))
                f.write(text)
            os.chmod(tmp, 0o600)
            os.replace(tmp, os.path.join(state, fn))
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        added += 1
    print(added)


def cmd_status(state, domain=None):
    data = read_export()
    archive = load_archive(state)
    sites = [find_site(data, domain)] if domain else data['sites']
    for s in sites:
        status, name, n = classify(s, data['templates'], archive)
        print("%s\t%s\t%s\t%d" % (s['domain'], status, name, n))


def cmd_diff(domain, name=None, state=None):
    data = read_export()
    site = find_site(data, domain)
    if not name:
        # 與 status／update 相同的判斷（含歷史版本），才會比對同一個範本
        _, name, _ = classify(site, data['templates'], load_archive(state))
    if name not in data['templates']:
        fail("template not found: %s" % name, 2)
    new = build(site, data['templates'][name])
    old_lines = lines_of(site.get('template', ''))
    new_lines = lines_of(new)
    for l in difflib.unified_diff(old_lines, new_lines, fromfile='%s (current)' % domain,
                                  tofile='%s (official: %s)' % (domain, name), lineterm=''):
        print(l)


def cmd_build(domain, name):
    data = read_export()
    site = find_site(data, domain)
    if name not in data['templates']:
        fail("template not found: %s" % name, 2)
    sys.stdout.write(build(site, data['templates'][name]))


def cmd_current(domain):
    data = read_export()
    sys.stdout.write(find_site(data, domain).get('template', ''))


def cmd_backup_db(db, dest):
    src = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15)
    dst = sqlite3.connect(dest)
    try:
        with dst:
            src.backup(dst)
    finally:
        dst.close()
        src.close()


def cmd_set_template(db, domain):
    """Fallback writer when CloudPanel's own code cannot be used; must run as the database owner (clp)."""
    template = sys.stdin.read()
    if not template.strip():
        fail("empty template", 2)
    if os.geteuid() == 0:
        fail("refusing to write the CloudPanel database as root")
    conn = sqlite3.connect(db, timeout=15)
    try:
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        with conn:
            cur = conn.execute("UPDATE site SET vhost_template = ?, updated_at = ? WHERE domain_name = ?",
                               (template, now, domain))
            if cur.rowcount != 1:
                fail("site not found: %s" % domain, 2)
    finally:
        conn.close()
    print("ok")


def main(argv):
    args = {}
    cmd = argv[1] if len(argv) > 1 else ''
    rest = argv[2:]
    i = 0
    while i < len(rest):
        if rest[i] in ('--db', '--state', '--domain', '--name', '--dest') and i + 1 < len(rest):
            args[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            fail(__doc__, 2)
    try:
        if cmd == 'export' and 'db' in args:
            cmd_export(args['db'])
        elif cmd == 'record' and 'state' in args:
            cmd_record(args['state'])
        elif cmd == 'status' and 'state' in args:
            cmd_status(args['state'], args.get('domain'))
        elif cmd == 'diff' and 'domain' in args:
            cmd_diff(args['domain'], args.get('name'), args.get('state'))
        elif cmd == 'build' and 'domain' in args and 'name' in args:
            cmd_build(args['domain'], args['name'])
        elif cmd == 'current' and 'domain' in args:
            cmd_current(args['domain'])
        elif cmd == 'backup-db' and 'db' in args and 'dest' in args:
            cmd_backup_db(args['db'], args['dest'])
        elif cmd == 'set-template' and 'db' in args and 'domain' in args:
            cmd_set_template(args['db'], args['domain'])
        else:
            fail(__doc__, 2)
    except (OSError, sqlite3.Error) as e:
        fail("error: %s" % e)


if __name__ == '__main__':
    main(sys.argv)
