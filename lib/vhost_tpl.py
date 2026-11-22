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
  vhost_tpl.py hooks-add --domain D [--file F]        template (stdin: export JSON) or file F with the clp
                                                      nginx hook lines on stdout
  vhost_tpl.py hooks-remove --domain D [--file F]     the same without the hook lines
  vhost_tpl.py hooks-state [--domain D] [--file F]    on | partial | none (export JSON: "<domain>\t<state>" lines)
  vhost_tpl.py hooks-report --vhost-dir DIR [--domain D]  (stdin: export JSON) one line per site, tab separated:
                                                      <domain> <php|other> <template state> <vhost state|disabled>

hooks-add exit 3 (no place for the hook lines): the one stderr line is
  clp-no-place <code> <a> <b> -- no place for the clp hook lines: <English reason>
code/a/b (see diagnose_no_place; '-' = none; line numbers are 1-based lines of the checked text):
  markers - - | braces L - | no_https N - | multi_https N L1,L2,.. | no_root L - | multi_root L R1,R2,..
(unknown - - when the cause cannot be told). lib/nginx_hooks.sh parses it; the English text is for people.

Comparison ignores CR/LF differences, trailing whitespace, trailing blank lines and the clp hook lines,
and treats every "server_name ...;" line as {{server_name}}. The template that is written is the official
text itself (plus the hook lines when the site had them).
Exit status: 0 ok, 1 error, 2 usage / site not found, 3 server_name lines cannot be mapped /
             no place for the hook lines
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
DOMAIN_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')

# clp nginx hooks: an http-level include at the top of the file and a server-level include
# right after the root line of the HTTPS server block (redirect-only blocks are not counted)
HOOK_DIR = '/etc/nginx/clp-helper'
HOOK_HTTP_START = '# --- CLP HELPER HOOKS (http) START ---'
HOOK_HTTP_END = '# --- CLP HELPER HOOKS (http) END ---'
HOOK_START = '# --- CLP HELPER HOOKS START ---'
HOOK_END = '# --- CLP HELPER HOOKS END ---'
ROOT_LINE_RE = re.compile(r'^\s*(\{\{root\}\}|root\s+[^;{}]+;\s*(#.*)?)\s*$')
# 與 lib/httpauth_vhost.py 的 https_server_span 相同的轉址判斷（對遮罩後的區塊頂層文字比對）
REDIRECT_RETURN_RE = re.compile(r'(?:^|;)\s*return\s+(?:30[1278]\b|https?://)', re.MULTILINE)
INCLUDE_RE = re.compile(r'(?:^|;)\s*include\s', re.MULTILINE)


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
    for line in lines_of(strip_hooks(text)):
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


# ---------------------------------------------------------------------------
# clp nginx hooks
# ---------------------------------------------------------------------------
def code_mask(text):
    """text with quoted strings, # comments and {{placeholders}} blanked out (same length),
    so that braces can be counted"""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '{' and text.startswith('{{', i):
            j = text.find('}}', i + 2)
            if j != -1 and '\n' not in text[i:j]:
                for k in range(i, j + 2):
                    out[k] = ' '
                i = j + 2
                continue
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == '\\' else 1
            for k in range(i, min(j + 1, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 1
            continue
        if c == '#' and (i == 0 or text[i - 1] in ' \t\r\n;{}'):
            # nginx 只在 token 開頭把 # 當成註解（location ~ ^/a#b 的 # 是 regex 的一部分；同 httpauth_vhost.py）
            j = text.find('\n', i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def hook_blocks(lines):
    """[(start, end, kind)] of the hook blocks in a list of lines (kind 'http' or 'server');
    raises ValueError on an unterminated block"""
    blocks = []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s in (HOOK_HTTP_START, HOOK_START):
            end_marker = HOOK_HTTP_END if s == HOOK_HTTP_START else HOOK_END
            j = i + 1
            while j < len(lines) and lines[j].strip() != end_marker:
                j += 1
            if j >= len(lines):
                raise ValueError("unterminated clp hook block")
            blocks.append((i, j, 'http' if s == HOOK_HTTP_START else 'server'))
            i = j + 1
            continue
        if s in (HOOK_HTTP_END, HOOK_END):
            raise ValueError("clp hook end marker without start")
        i += 1
    return blocks


def strip_hooks(text):
    return _strip_hooks_map(text)[0]


def hooks_state(text):
    try:
        kinds = {k for _, _, k in hook_blocks(text.splitlines(True))}
    except ValueError:
        return 'partial'
    if kinds == {'http', 'server'}:
        return 'on'
    return 'partial' if kinds else 'none'


def _scan_https(text):
    """Scan the top-level server blocks of text (the rules of https_root_line).
    ('braces', line) when a top-level server block is not closed (line of its "server {");
    otherwise ('ok', candidates, skipped): candidates = [(line, [root line index, ...]), ...] for the
    blocks that listen on 443 and not on 8080 and are not redirect-only (line = 1-based line of the
    block's "server {", root line index as in text.splitlines(True)), skipped = number of redirect-only blocks."""
    mask = code_mask(text)
    depth_at = []
    depth = 0
    for c in mask:
        depth_at.append(depth)
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
    root_pos = []
    pos = 0
    for idx, line in enumerate(text.splitlines(True)):
        if depth_at[pos] == 1 and ROOT_LINE_RE.match(line.rstrip('\r\n')):
            root_pos.append((pos, idx))
        pos += len(line)
    candidates = []
    skipped = 0
    for m in re.finditer(r'(?<![\w$])server\s*\{', mask):
        if depth_at[m.start()] != 0:
            continue
        open_idx = mask.index('{', m.start())
        close_idx = open_idx + 1
        while close_idx < len(mask) and not (mask[close_idx] == '}' and depth_at[close_idx] == 1):
            close_idx += 1
        if close_idx >= len(mask):
            return ('braces', text.count('\n', 0, m.start()) + 1)
        top = ''.join(ch for k, ch in enumerate(mask[open_idx + 1:close_idx], open_idx + 1)
                      if depth_at[k] == 1 and ch not in '{}')
        listens = re.findall(r'(?:^|[;\s])listen\s+([^;]*);', top)
        if any(re.search(r'(?<![\d.])443(?!\d)', l) for l in listens) and \
                not any(re.search(r'(?<![\d.])8080(?!\d)', l) for l in listens):
            roots = [idx for p, idx in root_pos if open_idx < p < close_idx]
            nested = '{' in mask[open_idx + 1:close_idx]
            if not roots and not nested and REDIRECT_RETURN_RE.search(top) and not INCLUDE_RE.search(top):
                skipped += 1
                continue
            candidates.append((text.count('\n', 0, m.start()) + 1, roots))
    return ('ok', candidates, skipped)


def https_root_line(text):
    """Index (in text.splitlines(True)) of the root line of the one server block that listens on 443
    and not on 8080; None when there is not exactly one such block or root line.
    A redirect-only block (CloudPanel's www redirect) is not counted: a top-level 30x/http(s) return,
    no root line, no nested block and no include. Anything less certain still counts, so the site is skipped."""
    res = _scan_https(text)
    if res[0] != 'ok':
        return None
    candidates = res[1]
    if len(candidates) != 1 or len(candidates[0][1]) != 1:
        return None
    return candidates[0][1][0]


def _strip_hooks_map(text):
    """(strip_hooks(text), the 1-based line number in text of each line of the result)"""
    lines = text.splitlines(True)
    try:
        blocks = hook_blocks(lines)
    except ValueError:
        return text, list(range(1, len(lines) + 1))
    drop = set()
    for s, e, _ in blocks:
        drop.update(range(s, e + 1))
    keep = [i for i in range(len(lines)) if i not in drop]
    return ''.join(lines[i] for i in keep), [i + 1 for i in keep]


def diagnose_no_place(text):
    """Why add_hooks(text, ...) finds no place for the hook lines: (code, a, b), or None when there is one.
    Existing (balanced) hook blocks are stripped before scanning, but every line number reported is the
    1-based line number in the original text, so it matches the file or template the user looks at.
      markers      -   -                  clp hook markers are unbalanced
      braces       L   -                  the server block starting at line L is not closed
      no_https     N   -                  no HTTPS server block to use (N redirect-only blocks were not counted)
      multi_https  N   L1,L2,..           N HTTPS server blocks (their starting lines; redirect-only blocks not counted)
      no_root      L   -                  the one HTTPS block starting at line L has no top-level root line
      multi_root   L   R1,R2,..           the one HTTPS block starting at line L has several top-level root lines"""
    base, nums = _strip_hooks_map(text)
    if hooks_state(base) != 'none':
        return ('markers', '-', '-')
    res = _scan_https(base)
    if res[0] == 'braces':
        return ('braces', str(nums[res[1] - 1]), '-')
    cands, skipped = res[1], res[2]
    if not cands:
        return ('no_https', str(skipped), '-')
    if len(cands) > 1:
        return ('multi_https', str(len(cands)), ','.join(str(nums[c[0] - 1]) for c in cands))
    line, roots = cands[0]
    if not roots:
        return ('no_root', str(nums[line - 1]), '-')
    if len(roots) > 1:
        return ('multi_root', str(nums[line - 1]), ','.join(str(nums[r]) for r in roots))
    return None


NO_PLACE_TEXT = {
    'markers': "the clp hook markers are unbalanced",
    'braces': "the server block starting at line %(a)s is not closed",
    'no_https': "no HTTPS server block to use (redirect-only blocks found and not counted: %(a)s)",
    'multi_https': "%(a)s HTTPS server blocks (lines %(b)s; redirect-only blocks not counted), exactly one is required",
    'no_root': "the HTTPS server block starting at line %(a)s has no top-level root line",
    'multi_root': "the HTTPS server block starting at line %(a)s has several top-level root lines (lines %(b)s)",
}


def no_place_reason(diag):
    """English text of a diagnose_no_place result"""
    code, a, b = diag
    return NO_PLACE_TEXT[code] % {'a': a, 'b': b}


def add_hooks(text, domain):
    """text with the clp hook lines (existing ones are replaced); None when there is no place for them"""
    if not DOMAIN_RE.match(domain):
        raise ValueError("invalid domain")
    # 標記不成對時 strip_hooks 不會改動，下面的檢查會拒絕
    base = strip_hooks(text)
    if hooks_state(base) != 'none':
        return None
    lines = base.splitlines(True)
    idx = https_root_line(base)
    if idx is None:
        return None
    eol = '\r\n' if lines[idx].endswith('\r\n') else '\n'
    root = lines[idx]
    if not root.endswith('\n'):
        root += eol
    indent = re.match(r'[ \t]*', root).group(0)
    server = [indent + l + eol for l in (HOOK_START,
                                         'include %s/*.conf;' % HOOK_DIR,
                                         'include %s/sites/%s/*.conf;' % (HOOK_DIR, domain),
                                         HOOK_END)]
    lines[idx:idx + 1] = [root] + server
    first_eol = '\r\n' if lines[0].endswith('\r\n') else '\n'
    http = [l + first_eol for l in (HOOK_HTTP_START,
                                    'include %s/sites/%s/http/*.conf;' % (HOOK_DIR, domain),
                                    HOOK_HTTP_END)]
    return ''.join(http + lines)


def build(site, official):
    """The official template with {{server_name}} replaced by the site's own server_name lines
    (and the clp hook lines when the site has them)"""
    text = build_plain(site, official)
    if hooks_state(site.get('template', '')) != 'none':
        hooked = add_hooks(text, site['domain'])
        if hooked is None:
            diag = diagnose_no_place(text)
            fail("no place for the clp hook lines in the template" + (": " + no_place_reason(diag) if diag else ""), 3)
        return hooked
    return text


def build_plain(site, official):
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


def hook_source(domain, path):
    """Text of file F, or the site's template from the export JSON on stdin"""
    if path:
        with open(path, encoding='utf-8', errors='surrogateescape', newline='') as f:
            return f.read()
    return find_site(read_export(), domain).get('template', '')


def cmd_hooks_report(vhost_dir, domain=None):
    """<domain> <php|other> <template state> <vhost state|disabled> for each site (stdin: export JSON)"""
    data = read_export()
    sites = [find_site(data, domain)] if domain else data['sites']
    for s in sites:
        d = s.get('domain', '')
        kind = 'php' if str(s.get('type', '')).lower() == 'php' else 'other'
        vstate = 'disabled'
        p = os.path.join(vhost_dir, d + '.conf')
        if DOMAIN_RE.match(d) and os.path.isfile(p):
            with open(p, encoding='utf-8', errors='surrogateescape', newline='') as f:
                vstate = hooks_state(f.read())
        print("%s\t%s\t%s\t%s" % (d, kind, hooks_state(s.get('template', '')), vstate))


def cmd_hooks(cmd, domain, path):
    if cmd == 'hooks-state':
        if path or domain:
            print(hooks_state(hook_source(domain, path)))
        else:
            for s in read_export()['sites']:
                print("%s\t%s" % (s['domain'], hooks_state(s.get('template', ''))))
        return
    if not domain or not DOMAIN_RE.match(domain):
        fail("invalid domain", 2)
    text = hook_source(domain, path)
    if cmd == 'hooks-remove':
        if hooks_state(text) == 'partial' and strip_hooks(text) == text:
            fail("unbalanced clp hook markers", 3)
        out = strip_hooks(text)
    else:
        out = add_hooks(text, domain)
        if out is None:
            diag = diagnose_no_place(text)
            if diag is None:
                diag = ('unknown', '-', '-')
                reason = "one HTTPS server block with one root line is required"
            else:
                reason = no_place_reason(diag)
            fail("clp-no-place %s %s %s -- no place for the clp hook lines: %s" % (diag + (reason,)), 3)
    sys.stdout.buffer.write(out.encode('utf-8', 'surrogateescape'))


def main(argv):
    args = {}
    cmd = argv[1] if len(argv) > 1 else ''
    rest = argv[2:]
    i = 0
    while i < len(rest):
        if rest[i] in ('--db', '--state', '--domain', '--name', '--dest', '--file', '--vhost-dir') and i + 1 < len(rest):
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
        elif cmd == 'hooks-report' and 'vhost-dir' in args:
            cmd_hooks_report(args['vhost-dir'], args.get('domain'))
        elif cmd in ('hooks-add', 'hooks-remove', 'hooks-state'):
            cmd_hooks(cmd, args.get('domain'), args.get('file'))
        else:
            fail(__doc__, 2)
    except (OSError, sqlite3.Error) as e:
        fail("error: %s" % e)


if __name__ == '__main__':
    main(sys.argv)
