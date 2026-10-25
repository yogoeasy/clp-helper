#!/usr/bin/env python3
"""
CLP Helper - PHP-FPM pool usage report and pm.max_children suggestion (used by lib/php_fpm.sh)

Usage:
  php_pm.py status [<domain>]
      stdout, tab separated:
        host <mem_total_mb> <budget_mb> <mysql_mb> <varnish_mb> <redis_mb> <reserve_mb> <worker_mb> <worker_samples> <cap>
             (worker_samples 0 = DEFAULT_WORKER_MB was used)
        site <domain> <php_ver> <pool_file> <pm> <max_children> <idle_timeout> <max_requests>
             <days> <max_active> <reached_status> <reached_log> <suggest> <conclusion> <mem_tight>
      ("-" for unknown values)

Where the numbers come from:
  - The pool's status page (pm.status_path, queried over FastCGI on the pool's listen
    address): "max active processes" and "max children reached" since PHP-FPM started.
    A reload or restart resets them, so "days" tells how much history they cover.
  - The PHP-FPM error log of the last LOG_DAYS days (rotated files included):
    "[pool <domain>] server reached max_children setting (N)" (ondemand pools; dynamic
    pools write "pm.max_children"). Only hits with
    N >= the current pm.max_children count: a hit under a lower, older limit says
    nothing about the current one. A line without "setting (N)" is counted.
  - Memory: MemTotal minus MySQL/MariaDB and Redis RSS, Varnish's malloc size and
    RESERVE_MB is the budget for PHP; one worker is the average PSS of the busy
    php-fpm workers seen in WORKER_SNAPSHOTS one-second snapshots
    (DEFAULT_WORKER_MB when fewer than MIN_WORKER_SAMPLES are found).

Suggestion (pm.max_children only, ondemand pools only):
  base  = max active x HEADROOM (max(current, max active) x HEADROOM after a "reached"),
          rounded up to a multiple of 5, at least MIN_CHILDREN
  limit = max(budget / worker, max active)   -- memory caps the headroom, never the observed peak
  raise when "reached" happened or current < max active x OK_LOW;
  lower when current > base x OK_HIGH or current > limit; otherwise ok.

Conclusions: ok raise lower tight short not-ondemand no-status
Exit status: 0 success, 2 error.
"""
import datetime
import glob
import gzip
import json
import math
import os
import re
import socket
import struct
import sys
import time

DOMAIN_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
SYSTEM_POOLS = ("www", "default", "global")

MIN_CHILDREN = 10
HEADROOM = 1.5
OK_LOW = 1.2
OK_HIGH = 2.0
MIN_DAYS = 3
LOG_DAYS = 7
RESERVE_MB = 512
MIN_BUDGET_MB = 256
DEFAULT_WORKER_MB = 100
BUSY_WORKER_RSS_MB = 30
MIN_WORKER_SAMPLES = 3
WORKER_SNAPSHOTS = 3


def fail(msg, code=2):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


# ------------------------------------------------------------------ pool files
def read_pool(path):
    """Effective (last active) values of a pool file, keys lower-cased."""
    conf = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s[0] in ";#[":
                continue
            if "=" in s:
                k, v = s.split("=", 1)
                conf[k.strip().lower()] = v.strip().strip('"').strip("'")
    return conf


def list_pools():
    """[(domain, php_ver, pool_file)] sorted by domain; newest PHP version wins on duplicates."""
    found = {}
    for path in sorted(glob.glob("/etc/php/*/fpm/pool.d/*.conf")):
        name = os.path.basename(path)[:-5]
        if name in SYSTEM_POOLS:
            continue
        ver = path.split("/")[3]
        found[name] = (name, ver, path)
    return [found[k] for k in sorted(found)]


# ------------------------------------------------------------------ FastCGI status
def _fcgi_record(rtype, content, req_id=1):
    return struct.pack("!BBHHBx", 1, rtype, req_id, len(content), 0) + content


def _fcgi_pair(name, value):
    out = b""
    for s in (name, value):
        n = len(s)
        out += struct.pack("!B", n) if n < 128 else struct.pack("!I", n | 0x80000000)
    return out + name + value


def _connect(listen, timeout):
    if listen.startswith("/"):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(listen)
        return s
    host, port = "127.0.0.1", listen
    if ":" in listen:
        host, port = listen.rsplit(":", 1)
        host = host.strip("[]")
        if host in ("", "*", "0.0.0.0", "::"):
            host = "127.0.0.1"
    return socket.create_connection((host, int(port)), timeout=timeout)


def fpm_status(listen, status_path, timeout=5):
    """The pool's status page as a dict (json format); None when unreachable."""
    params = {
        "SCRIPT_NAME": status_path, "SCRIPT_FILENAME": status_path,
        "REQUEST_URI": status_path + "?json", "QUERY_STRING": "json",
        "REQUEST_METHOD": "GET", "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1", "REMOTE_ADDR": "127.0.0.1",
    }
    body = b"".join(_fcgi_pair(k.encode(), v.encode()) for k, v in params.items())
    req = (_fcgi_record(1, struct.pack("!HB5x", 1, 0))        # BEGIN_REQUEST, responder
           + _fcgi_record(4, body) + _fcgi_record(4, b"")     # PARAMS
           + _fcgi_record(5, b""))                            # STDIN
    try:
        s = _connect(listen, timeout)
    except (OSError, ValueError):
        return None
    data = b""
    try:
        s.sendall(req)
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError:
        return None
    finally:
        s.close()
    out, pos = b"", 0
    while pos + 8 <= len(data):
        _ver, rtype, _rid, clen, plen = struct.unpack("!BBHHB", data[pos:pos + 7])
        content = data[pos + 8:pos + 8 + clen]
        pos += 8 + clen + plen
        if rtype == 6:
            out += content
        elif rtype == 3:
            break
    sep = out.find(b"\r\n\r\n")
    payload = out[sep + 4:] if sep >= 0 else out
    try:
        return json.loads(payload.decode("utf-8", "replace"))
    except ValueError:
        return None


# ------------------------------------------------------------------ error log
LOG_LINE_RE = re.compile(r'^\[(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}:\d{2})\].*\[pool ([^\]]+)\] server reached (?:pm\.)?max_children'
                         r'(?: setting \((\d+)\))?')


def fpm_log_files(ver):
    path = "/var/log/php%s-fpm.log" % ver
    try:
        for line in open("/etc/php/%s/fpm/php-fpm.conf" % ver, encoding="utf-8", errors="replace"):
            m = re.match(r'^\s*error_log\s*=\s*(\S+)', line)
            if m and m.group(1).startswith("/"):
                path = m.group(1)
    except OSError:
        pass
    return [path] + sorted(glob.glob(path + ".*"))


def reached_in_logs(versions):
    """{pool: [setting N or None, ...]} of 'reached [pm.]max_children' in the last LOG_DAYS days."""
    since = datetime.datetime.now() - datetime.timedelta(days=LOG_DAYS)
    counts = {}
    for ver in versions:
        for path in fpm_log_files(ver):
            try:
                if os.path.getmtime(path) < since.timestamp():
                    continue
                opener = gzip.open if path.endswith(".gz") else open
                with opener(path, "rt", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        if "max_children" not in line:
                            continue
                        m = LOG_LINE_RE.match(line)
                        if not m:
                            continue
                        try:
                            ts = datetime.datetime.strptime(m.group(1), "%d-%b-%Y %H:%M:%S")
                        except ValueError:
                            continue
                        if ts >= since:
                            counts.setdefault(m.group(2), []).append(int(m.group(3)) if m.group(3) else None)
            except (OSError, EOFError):
                continue
    return counts


def count_reached(settings, current):
    """Hits that apply to the current limit: setting N >= current (or N unknown)."""
    if current is None:
        return len(settings)
    return sum(1 for n in settings if n is None or n >= current)


# ------------------------------------------------------------------ memory
def _proc_kb(pid, fname, key):
    try:
        with open("/proc/%s/%s" % (pid, fname)) as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def _size_mb(text):
    m = re.match(r'^(\d+)([kKmMgGtT]?)$', text)
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2).lower()
    return {"": n / 1048576.0, "k": n / 1024.0, "m": n, "g": n * 1024, "t": n * 1048576}[unit]


def busy_workers():
    """{pid: PSS kB} of php-fpm workers above BUSY_WORKER_RSS_MB, over a few snapshots."""
    seen = {}
    for i in range(WORKER_SNAPSHOTS):
        if i:
            time.sleep(1)
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open("/proc/%s/cmdline" % pid, "rb") as f:
                    if not f.read(14).startswith(b"php-fpm: pool "):
                        continue
            except OSError:
                continue
            rss = _proc_kb(pid, "status", "VmRSS") or 0
            if rss >= BUSY_WORKER_RSS_MB * 1024:
                seen[pid] = max(seen.get(pid, 0), _proc_kb(pid, "smaps_rollup", "Pss") or rss)
    return seen


def memory_info():
    total = _proc_kb("self", "../meminfo", "MemTotal") or 0
    mysql = redis = varnish_rss = 0
    varnish_malloc = None
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                argv = f.read().split(b"\0")
            with open("/proc/%s/comm" % pid) as f:
                comm = f.read().strip()
        except OSError:
            continue
        rss = _proc_kb(pid, "status", "VmRSS") or 0
        if comm in ("mysqld", "mariadbd"):
            mysql += rss
        elif comm.startswith("redis-server"):
            redis += rss
        elif comm in ("varnishd", "cache-main"):
            varnish_rss += rss
            args = [a.decode("utf-8", "replace") for a in argv]
            for i, a in enumerate(args):
                spec = args[i + 1] if a == "-s" and i + 1 < len(args) else (a[2:] if a.startswith("-s") and len(a) > 2 else "")
                if spec.startswith("malloc,"):
                    mb = _size_mb(spec.split(",")[1])
                    if mb is not None:
                        varnish_malloc = max(varnish_malloc or 0, mb)
    varnish = varnish_malloc if varnish_malloc is not None else varnish_rss / 1024.0
    total_mb, mysql_mb, redis_mb = total / 1024.0, mysql / 1024.0, redis / 1024.0
    budget = max(MIN_BUDGET_MB, total_mb - mysql_mb - redis_mb - varnish - RESERVE_MB)
    workers = list(busy_workers().values())
    if len(workers) >= MIN_WORKER_SAMPLES:
        worker = sum(workers) / len(workers) / 1024.0
    else:
        worker = DEFAULT_WORKER_MB
    return {
        "total": int(total_mb), "budget": int(budget), "mysql": int(mysql_mb),
        "varnish": int(varnish), "redis": int(redis_mb), "reserve": RESERVE_MB,
        "worker": max(1, int(round(worker))),
        "samples": len(workers) if len(workers) >= MIN_WORKER_SAMPLES else 0,
    }


# ------------------------------------------------------------------ suggestion
def ceil5(x):
    return int(math.ceil(x / 5.0) * 5)


def suggest(current, max_active, reached, days, cap):
    """(suggested value or None, conclusion, mem_tight)"""
    tight = max_active is not None and max_active > cap
    if max_active is None or days is None:
        return None, "no-status", False
    if days < MIN_DAYS and not reached:
        return None, "short", tight
    peak = max(current, max_active) if reached else max_active
    base = max(MIN_CHILDREN, ceil5(peak * HEADROOM))
    limit = max(cap, max_active, MIN_CHILDREN)
    target = min(base, limit)
    if reached or current < math.ceil(max_active * OK_LOW):
        if target <= current:
            return current, "tight", True
        return target, "raise", tight
    if current > base * OK_HIGH or current > limit:
        return target, "lower", tight
    return current, "ok", tight


# ------------------------------------------------------------------ status
def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def cmd_status(domain=None):
    if domain is not None and not DOMAIN_RE.match(domain):
        # 給 php_fpm.sh 的錯誤代碼（訊息由 bash 端翻譯）
        fail("clp-error:invalid-domain:%s" % domain)
    pools = list_pools()
    if domain is not None:
        pools = [p for p in pools if p[0] == domain]
        if not pools:
            fail("clp-error:no-pool:%s" % domain)
    mem = memory_info()
    cap = max(MIN_CHILDREN, mem["budget"] // mem["worker"])
    logs = reached_in_logs(sorted({p[1] for p in pools}))
    print("\t".join(str(x) for x in ("host", mem["total"], mem["budget"], mem["mysql"], mem["varnish"],
                                     mem["redis"], mem["reserve"], mem["worker"], mem["samples"], cap)))
    for name, ver, path in pools:
        try:
            conf = read_pool(path)
        except OSError:
            conf = {}
        pm = conf.get("pm", "-")
        current = _int(conf.get("pm.max_children"))
        days = max_active = reached_status = None
        status_path = conf.get("pm.status_path", "")
        listen = conf.get("listen", "")
        if status_path and listen:
            st = fpm_status(listen, status_path)
            if st:
                since = _int(st.get("start since"))
                days = since / 86400.0 if since is not None else None
                max_active = _int(st.get("max active processes"))
                reached_status = _int(st.get("max children reached"))
        reached_log = count_reached(logs.get(name, []), current)
        if pm != "ondemand":
            value, conclusion, tight = None, "not-ondemand", False
        elif current is None:
            value, conclusion, tight = None, "no-status", False
        else:
            value, conclusion, tight = suggest(current, max_active, bool(reached_status or reached_log), days, cap)
        row = ("site", name, ver, path, pm, current, conf.get("pm.process_idle_timeout"), conf.get("pm.max_requests"),
               "%.1f" % days if days is not None else None, max_active, reached_status, reached_log,
               value, conclusion, 1 if tight else 0)
        print("\t".join("-" if x is None or x == "" else str(x) for x in row))


def main(argv):
    if len(argv) >= 2 and argv[1] == "status" and len(argv) <= 3:
        cmd_status(argv[2] if len(argv) == 3 else None)
    else:
        fail(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (OSError, PermissionError) as e:
        fail("error: %s" % e)
