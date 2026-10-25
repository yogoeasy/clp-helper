#!/usr/bin/env python3
"""
CLP Helper - Secure File Operations Module (clp_fileops.py)
Provides atomic, symlink-resistant file operations and permissions preservation
for files residing in user home directories and system paths.
"""

import io
import sys
import os
import re
import stat
import tempfile
import argparse
import pwd
import grp
import secrets

# read_file_nofollow only serves small config files (wp-config.php, .user.ini, .htpasswd, ...)
MAX_READ_BYTES = 8 * 1024 * 1024


def home_split(path):
    """
    Returns (user, path_under_real_home) when path lies under the home base (CLP_HOME_DIR, default
    /home), matched against both the base as given and its realpath, so a host where /home is a
    symlink (e.g. /home -> /data/home) still gets the fd-based path. Returns (None, path) otherwise.
    """
    raw = os.path.abspath(os.environ.get("CLP_HOME_DIR", "/home")).rstrip("/")
    real = os.path.realpath(raw).rstrip("/")
    for base in (real, raw):
        rel = os.path.relpath(path, base)
        if rel == "." or rel == ".." or rel.startswith(".." + os.sep):
            continue
        parts = rel.split(os.sep)
        if parts and parts[0]:
            return parts[0], os.path.join(real, rel)
    return None, path


def write_all(fd, data):
    """Writes all of data to fd; raises instead of leaving a short write behind."""
    total_written = 0
    while total_written < len(data):
        n = os.write(fd, data[total_written:])
        if n <= 0:
            raise OSError(f"short write: {total_written} of {len(data)} bytes")
        total_written += n


def open_dir_tree_nofollow(home_user_dir, target_dir):
    """
    Step-by-step opens directories from home_user_dir down to target_dir using
    O_RDONLY | O_DIRECTORY | O_NOFOLLOW with dir_fd.
    Returns (target_dir_fd, list_of_all_open_fds_to_close).
    Raises OSError / PermissionError if any component is a symlink or missing.
    """
    rel_dir = os.path.relpath(target_dir, home_user_dir)
    flags = os.O_RDONLY | os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    home_fd = os.open(home_user_dir, flags)
    open_fds = [home_fd]
    current_fd = home_fd
    try:
        if rel_dir != ".":
            parts = rel_dir.split(os.sep)
            for part in parts:
                if not part or part == ".":
                    continue
                if part == "..":
                    raise PermissionError("Security violation: path traverses upwards via '..'")
                next_fd = os.open(part, flags, dir_fd=current_fd)
                open_fds.append(next_fd)
                current_fd = next_fd
    except BaseException:
        # 中途失敗（symlink、不存在）時關閉已開啟的目錄，不留給呼叫端
        for fd in reversed(open_fds):
            try:
                os.close(fd)
            except OSError:
                pass
        raise
    return current_fd, open_fds


def safe_atomic_write(target_path, content, user=None, allow_create=False, owner=None, mode=None):
    """
    Safely and atomically writes content to target_path using file descriptors.
    - Rejects symbolic links (both target file and target directory checks).
    - If user is specified or path is under /home/<user>, traverses directory tree step-by-step
      with O_RDONLY | O_DIRECTORY | O_NOFOLLOW using dir_fd, creates temp file using dir_fd,
      and replaces atomically via os.replace with src_dir_fd and dst_dir_fd.
    - If user is specified, ensures realpath of target_dir starts with /home/{user}/.
    - If target exists, inherits owner and permissions via fchown / fchmod.
    - If target does not exist, requires allow_create=True, and sets owner / mode via fchown / fchmod.
    - Paths outside /home/<user> retain existing standard atomic replace behavior.
    """
    target_path = os.path.abspath(target_path)
    target_dir = os.path.dirname(target_path)
    base_name = os.path.basename(target_path)
    base_home = os.path.realpath(os.environ.get("CLP_HOME_DIR", "/home")).rstrip("/")

    # 1. Target directory boundary check
    if user:
        real_dir = os.path.realpath(target_dir)
        expected_prefix = f"{base_home}/{user}/"
        if not (real_dir == f"{base_home}/{user}" or real_dir.startswith(expected_prefix)):
            raise PermissionError(f"Security violation: target directory '{real_dir}' is not within '{expected_prefix}'")

    split_user, home_path = home_split(target_path)
    inferred_user = user or split_user
    if split_user:
        target_path = home_path
        target_dir = os.path.dirname(target_path)

    home_user_dir = f"{base_home}/{inferred_user}" if inferred_user else None
    if user and not os.path.isdir(home_user_dir):
        raise FileNotFoundError(f"Home directory of '{user}' not found: {home_user_dir}")
    if home_user_dir and os.path.isdir(home_user_dir):
        # Step-by-step traversal with dir_fd under /home/<user> (#10)
        target_fd, open_fds = open_dir_tree_nofollow(home_user_dir, target_dir)
        tmp_fd = None
        tmp_name = None
        replaced = False
        try:
            try:
                st = os.stat(base_name, dir_fd=target_fd, follow_symlinks=False)
                exists = True
            except FileNotFoundError:
                st = None
                exists = False

            if exists:
                if stat.S_ISLNK(st.st_mode):
                    raise OSError(f"Security violation: target file '{target_path}' is a symbolic link; operation rejected")
                target_uid = st.st_uid
                target_gid = st.st_gid
                target_mode = stat.S_IMODE(st.st_mode)
            else:
                if not allow_create:
                    raise FileNotFoundError(f"Target file does not exist and allow_create=False: {target_path}")
                if owner:
                    try:
                        pw = pwd.getpwnam(owner)
                        target_uid = pw.pw_uid
                        target_gid = pw.pw_gid
                    except KeyError:
                        raise ValueError(f"Unknown owner user: {owner}")
                else:
                    target_uid = os.getuid()
                    target_gid = os.getgid()
                if mode is not None:
                    target_mode = int(mode, 8) if isinstance(mode, str) else int(mode)
                else:
                    target_mode = 0o640

            tmp_name = f".clp_tmp.{os.getpid()}.{secrets.token_hex(8)}"
            tmp_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                tmp_flags |= os.O_NOFOLLOW
            tmp_fd = os.open(tmp_name, tmp_flags, 0o600, dir_fd=target_fd)

            try:
                os.fchown(tmp_fd, target_uid, target_gid)
            except PermissionError:
                if os.getuid() != 0:
                    pass
                else:
                    raise
            os.fchmod(tmp_fd, target_mode)

            data = content.encode("utf-8") if isinstance(content, str) else content
            write_all(tmp_fd, data)

            os.fsync(tmp_fd)
            os.close(tmp_fd)
            tmp_fd = None

            os.replace(tmp_name, base_name, src_dir_fd=target_fd, dst_dir_fd=target_fd)
            replaced = True
        finally:
            if tmp_fd is not None:
                try:
                    os.close(tmp_fd)
                except OSError:
                    pass
            if tmp_name and not replaced:
                try:
                    os.unlink(tmp_name, dir_fd=target_fd)
                except OSError:
                    pass
            for fd in reversed(open_fds):
                try:
                    os.close(fd)
                except OSError:
                    pass
        return True

    # Fallback: Paths outside /home/<user> retain existing behavior
    if os.path.islink(target_path):
        raise OSError(f"Security violation: target file '{target_path}' is a symbolic link; operation rejected")

    exists = os.path.exists(target_path)
    if not exists:
        if not allow_create:
            raise FileNotFoundError(f"Target file does not exist and allow_create=False: {target_path}")

        if owner:
            try:
                pw = pwd.getpwnam(owner)
                target_uid = pw.pw_uid
                target_gid = pw.pw_gid
            except KeyError:
                raise ValueError(f"Unknown owner user: {owner}")
        else:
            target_uid = os.getuid()
            target_gid = os.getgid()

        if mode is not None:
            if isinstance(mode, str):
                target_mode = int(mode, 8)
            else:
                target_mode = int(mode)
        else:
            target_mode = 0o640
    else:
        st = os.lstat(target_path)
        if stat.S_ISLNK(st.st_mode):
            raise OSError(f"Security violation: target file '{target_path}' is a symbolic link; operation rejected")
        target_uid = st.st_uid
        target_gid = st.st_gid
        target_mode = stat.S_IMODE(st.st_mode)

    fd, tmp_path = tempfile.mkstemp(dir=target_dir, prefix=".clp_tmp.")
    try:
        try:
            os.fchown(fd, target_uid, target_gid)
        except PermissionError:
            if os.getuid() != 0:
                pass
            else:
                raise

        os.fchmod(fd, target_mode)

        if isinstance(content, str):
            data = content.encode("utf-8")
        else:
            data = content

        write_all(fd, data)

        os.fsync(fd)
        os.close(fd)
        fd = None

        os.replace(tmp_path, target_path)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    return True


def open_regular_nofollow(path, user=None):
    """
    Opens path read-only without following symlinks (O_NOFOLLOW, fd walk under /home/<user>) and
    returns the fd. Opens with O_NONBLOCK and refuses anything but a regular file, so a FIFO or
    device planted by the site user cannot block or feed root; refuses files over MAX_READ_BYTES.
    """
    path = os.path.abspath(path)
    if os.path.islink(path):
        raise OSError(f"Security violation: refusing to read symlink '{path}'")

    split_user, home_path = home_split(path)
    if split_user:
        path = home_path
    target_dir = os.path.dirname(path)
    base_name = os.path.basename(path)
    base_home = os.path.realpath(os.environ.get("CLP_HOME_DIR", "/home")).rstrip("/")

    inferred_user = user or split_user
    home_user_dir = f"{base_home}/{inferred_user}" if inferred_user else None
    if user and not os.path.isdir(home_user_dir):
        raise FileNotFoundError(f"Home directory of '{user}' not found: {home_user_dir}")
    if home_user_dir and os.path.isdir(home_user_dir):
        target_fd, open_fds = open_dir_tree_nofollow(home_user_dir, target_dir)
        try:
            flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(base_name, flags, dir_fd=target_fd)
        finally:
            for d_fd in reversed(open_fds):
                try:
                    os.close(d_fd)
                except OSError:
                    pass
    else:
        flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)

    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        raise OSError(f"Security violation: refusing to read non-regular file '{path}'")
    if st.st_size > MAX_READ_BYTES:
        os.close(fd)
        raise OSError(f"Refusing to read '{path}': larger than {MAX_READ_BYTES} bytes")
    return fd


def read_file_nofollow(path, user=None):
    """
    Reads all lines from path preventing symlink traversal via O_NOFOLLOW (see open_regular_nofollow).
    Returns [] when the file does not exist.
    """
    if not os.path.exists(os.path.abspath(path)):
        return []
    fd = open_regular_nofollow(path, user=user)
    with open(fd, "r", encoding="utf-8", errors="replace", closefd=True) as f:
        data = f.read(MAX_READ_BYTES + 1)
    if len(data) > MAX_READ_BYTES:
        raise OSError(f"Refusing to read '{path}': larger than {MAX_READ_BYTES} bytes")
    return io.StringIO(data).readlines()


def read_bytes_nofollow(path, user=None):
    """Like read_file_nofollow, but returns the exact bytes (no newline translation or decoding)."""
    fd = open_regular_nofollow(path, user=user)
    with open(fd, "rb", closefd=True) as f:
        data = f.read(MAX_READ_BYTES + 1)
    if len(data) > MAX_READ_BYTES:
        raise OSError(f"Refusing to read '{path}': larger than {MAX_READ_BYTES} bytes")
    return data


def read_text_nofollow(path, user=None):
    """
    Reads entire text content from path preventing symlink traversal via O_NOFOLLOW.
    """
    lines = read_file_nofollow(path, user=user)
    return "".join(lines)


def get_required_site_user():
    """
    Retrieves and validates CLP_SITE_USER from environment variable.
    Raises ValueError if empty.
    """
    site_user = os.environ.get("CLP_SITE_USER", "").strip()
    if not site_user:
        raise ValueError("Security violation: CLP_SITE_USER environment variable must not be empty")
    return site_user


class PrefixSyncError(Exception):
    def __init__(self, code, message=""):
        super().__init__(message)
        self.code = code
        self.message = message


def sync_wp_table_prefix(target_wpconfig, backup_source, user=None):
    """
    Compares $table_prefix between target wp-config.php and backup_source (wp-config.php or .sql/.sql.gz).
    If they differ, atomically updates target wp-config.php using safe_atomic_write and returns the new prefix.
    """
    def get_wpconfig_prefix(path, path_user=None):
        try:
            content = read_text_nofollow(path, user=path_user)
        except Exception as e:
            raise PrefixSyncError(1, f"Cannot read wp-config '{path}': {e}")
        m = re.search(r"""^\s*\$table_prefix\s*=\s*(['"])(.*?)\1\s*;""", content, re.MULTILINE)
        if not m:
            return None
        p = m.group(2)
        if not re.match(r"^[A-Za-z0-9_]+$", p):
            raise PrefixSyncError(4, p)
        return p

    def get_sql_prefix(path):
        table_names = set()
        pattern = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?['\x60]?([A-Za-z0-9_]+)['\x60]?", re.IGNORECASE)

        def process_stream(f):
            overlap = ""
            while True:
                buf = f.read(262144)
                if not buf:
                    break
                data = overlap + buf
                for m in pattern.finditer(data):
                    table_names.add(m.group(1))
                overlap = data[-1024:]

        try:
            if path.endswith(".sql.gz"):
                import gzip
                with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
                    process_stream(f)
            elif path.endswith(".sql"):
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    process_stream(f)
            else:
                raise PrefixSyncError(1, f"Unsupported backup file format: {path}")
        except PrefixSyncError:
            raise
        except Exception as e:
            raise PrefixSyncError(1, f"Failed to read backup SQL: {e}")

        candidates = []
        for t in table_names:
            if t.endswith("options"):
                p = t[:-len("options")]
                if f"{p}posts" in table_names and f"{p}users" in table_names:
                    if re.match(r"^[A-Za-z0-9_]+$", p):
                        candidates.append(p)
                    else:
                        raise PrefixSyncError(4, p)

        candidates = sorted(list(set(candidates)))
        if len(candidates) == 0:
            raise PrefixSyncError(3, "No matching WordPress tables (options, posts, users) found in backup SQL")
        elif len(candidates) > 1:
            raise PrefixSyncError(2, ", ".join(candidates))

        return candidates[0]

    target_prefix = get_wpconfig_prefix(target_wpconfig, path_user=user)
    if not target_prefix:
        raise PrefixSyncError(1, f"table_prefix not found in target wp-config '{target_wpconfig}'")

    backup_prefix = None
    if backup_source.endswith(".php"):
        backup_prefix = get_wpconfig_prefix(backup_source, path_user=None)
        if not backup_prefix:
            raise PrefixSyncError(3, f"table_prefix not found in backup wp-config '{backup_source}'")
    elif backup_source.endswith((".sql", ".sql.gz")):
        backup_prefix = get_sql_prefix(backup_source)
    else:
        raise PrefixSyncError(1, f"Unknown backup source type: {backup_source}")

    if backup_prefix and target_prefix != backup_prefix:
        content = read_text_nofollow(target_wpconfig, user=user)
        new_content = re.sub(
            r"""^(\s*\$table_prefix\s*=\s*)(['"]).*?\2""",
            r"\g<1>'%s'" % backup_prefix,
            content,
            count=1,
            flags=re.MULTILINE
        )
        safe_atomic_write(target_wpconfig, new_content, user=user, allow_create=False)
        return backup_prefix
    return None


def htpasswd_set(file_path, username, new_line, owner=None, mode=0o640, user=None):
    """
    Safely adds or updates a user in .htpasswd:
    - Reads existing file with O_NOFOLLOW
    - Replaces or adds username line
    - Atomically writes back with safe_atomic_write
    - user: boundary check user (path must be inside /home/{user}/)
    - owner: file owner username for new files
    """
    file_path = os.path.abspath(file_path)
    target_dir = os.path.dirname(file_path)
    base_home = os.path.realpath(os.environ.get("CLP_HOME_DIR", "/home")).rstrip("/")
    if user:
        real_dir = os.path.realpath(target_dir)
        expected_prefix = f"{base_home}/{user}/"
        if not (real_dir == f"{base_home}/{user}" or real_dir.startswith(expected_prefix)):
            raise PermissionError(f"Security violation: target directory '{real_dir}' is not within '{expected_prefix}'")

    lines = []
    if os.path.exists(file_path):
        lines = read_file_nofollow(file_path, user=user)

    prefix = f"{username}:"
    # 最後一行若沒有換行，補上，避免新的一行接在它後面
    filtered = [l if l.endswith("\n") else l + "\n"
                for l in lines if not l.startswith(prefix) and l.strip()]

    new_line = new_line.strip()
    if not new_line.startswith(prefix):
        new_line = f"{prefix}{new_line}"
    filtered.append(new_line + "\n")

    content = "".join(filtered)
    return safe_atomic_write(
        file_path,
        content,
        user=user,
        allow_create=True,
        owner=owner,
        mode=mode
    )


def htpasswd_del(file_path, username, user=None):
    """
    Safely removes a user from .htpasswd:
    - Reads existing file with O_NOFOLLOW
    - Filters out username line
    - Atomically writes back with safe_atomic_write
    - user: boundary check user (path must be inside /home/{user}/)
    """
    file_path = os.path.abspath(file_path)
    target_dir = os.path.dirname(file_path)
    base_home = os.path.realpath(os.environ.get("CLP_HOME_DIR", "/home")).rstrip("/")
    if user:
        real_dir = os.path.realpath(target_dir)
        expected_prefix = f"{base_home}/{user}/"
        if not (real_dir == f"{base_home}/{user}" or real_dir.startswith(expected_prefix)):
            raise PermissionError(f"Security violation: target directory '{real_dir}' is not within '{expected_prefix}'")

    if not os.path.exists(file_path):
        return True

    lines = read_file_nofollow(file_path, user=user)
    prefix = f"{username}:"
    filtered = [l for l in lines if not l.startswith(prefix) and l.strip()]

    content = "".join(filtered)
    if content and not content.endswith("\n"):
        content += "\n"

    return safe_atomic_write(
        file_path,
        content,
        user=user,
        allow_create=False
    )


def main():
    parser = argparse.ArgumentParser(description="CLP Helper Safe File Operations")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # Subcommand: write
    p_write = subparsers.add_parser("write", help="Atomically write stdin to target file")
    p_write.add_argument("path", help="Target file path")
    p_write.add_argument("--user", help="Require path inside /home/<user>/", default=None)
    p_write.add_argument("--owner", help="Owner username for new file", default=None)
    p_write.add_argument("--mode", help="Octal file mode for new file (e.g. 640)", default=None)
    p_write.add_argument("--allow-create", action="store_true", help="Allow creating file if not existing")

    # Subcommand: read
    p_read = subparsers.add_parser("read", help="Print a file without following symlinks (empty if missing)")
    p_read.add_argument("path", help="File path")
    p_read.add_argument("--user", help="Require path inside /home/<user>/", default=None)

    # Subcommand: htpasswd-set
    p_hset = subparsers.add_parser("htpasswd-set", help="Add or update user in htpasswd file")
    p_hset.add_argument("path", help="Path to .htpasswd file")
    p_hset.add_argument("username", help="Username")
    p_hset.add_argument("--user", help="Require path inside /home/<user>/", default=None)
    p_hset.add_argument("--owner", help="Site user owner for new file", default=None)
    p_hset.add_argument("--mode", help="Octal file mode", default="640")

    # Subcommand: htpasswd-del
    p_hdel = subparsers.add_parser("htpasswd-del", help="Remove user from htpasswd file")
    p_hdel.add_argument("path", help="Path to .htpasswd file")
    p_hdel.add_argument("username", help="Username")
    p_hdel.add_argument("--user", help="Require path inside /home/<user>/", default=None)
    p_hdel.add_argument("--owner", help="Site user owner (for backward compat)", default=None)

    # Subcommand: sync-wp-table-prefix
    p_sync = subparsers.add_parser("sync-wp-table-prefix", help="Sync $table_prefix in wp-config.php")
    p_sync.add_argument("target", help="Target wp-config.php path")
    p_sync.add_argument("source", help="Backup wp-config.php or SQL dump path")
    p_sync.add_argument("--user", help="Require path inside /home/<user>/", default=None)

    args = parser.parse_args()

    try:
        if args.subcommand == "write":
            content = sys.stdin.read()
            safe_atomic_write(
                args.path,
                content,
                user=args.user,
                allow_create=args.allow_create,
                owner=args.owner,
                mode=args.mode
            )
        elif args.subcommand == "read":
            sys.stdout.write(read_text_nofollow(args.path, user=args.user))
        elif args.subcommand == "htpasswd-set":
            line = sys.stdin.read().strip()
            if not line:
                sys.stderr.write("Error: empty input for htpasswd-set\n")
                sys.exit(1)
            htpasswd_set(
                args.path,
                args.username,
                line,
                owner=args.owner,
                mode=args.mode,
                user=args.user
            )
        elif args.subcommand == "htpasswd-del":
            target_user = args.user if args.user is not None else args.owner
            htpasswd_del(
                args.path,
                args.username,
                user=target_user
            )
        elif args.subcommand == "sync-wp-table-prefix":
            try:
                res = sync_wp_table_prefix(
                    args.target,
                    args.source,
                    user=args.user
                )
                if res:
                    sys.stdout.write(res)
                sys.exit(0)
            except PrefixSyncError as pe:
                if pe.message:
                    sys.stderr.write(f"{pe.message}\n")
                sys.exit(pe.code)
    except Exception as e:
        sys.stderr.write(f"clp_fileops error: {e}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
