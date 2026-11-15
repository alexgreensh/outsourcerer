#!/usr/bin/env python3
"""Keep the preflight result pipe out of the shell and its probes."""
import hashlib
import hmac
import os
import secrets
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:
    print('ERROR: background route pinning needs a POSIX-compatible Python 3.', file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--emit':
        token = sys.stdin.read().strip()
        record = sys.argv[3].encode()
        mac = hmac.new(bytes.fromhex(token), record, hashlib.sha256).hexdigest()
        fd = os.open(sys.argv[2], os.O_WRONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
        try:
            message = mac.encode() + b'|' + record + b'\n'
            if not stat.S_ISFIFO(os.fstat(fd).st_mode) or len(message) > os.fpathconf(fd, 'PC_PIPE_BUF'):
                return 1
            if os.write(fd, message) != len(message):
                return 1
        finally:
            os.close(fd)
        return 0
    if len(sys.argv) < 2:
        return 1
    if not hasattr(os, 'mkfifo') or not hasattr(signal, 'pthread_sigmask'):
        print('ERROR: background route pinning needs POSIX pipe support.', file=sys.stderr)
        return 1
    home = os.environ['OSRC_HOME']
    directory = None
    child = None
    read_fifo = None
    key_fd = None
    write_key = None

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    try:
        directory = tempfile.mkdtemp(prefix='.preflight.', dir=home)
        fifo = os.path.join(directory, 'route')
        for sig in signals:
            signal.signal(sig, interrupted)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        old_mask = None
        os.mkfifo(fifo, 0o600)
        read_fifo = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        read_key, write_key = os.pipe()
        key_fd = fcntl.fcntl(read_key, fcntl.F_DUPFD, 20)
        os.close(read_key)
        token = secrets.token_hex(32)
        wrapper = ('unset _OSRC_RELAY_SECRET _OSRC_RELAY_PYTHON; IFS= read -r _OSRC_RELAY_SECRET <&"$1" || exit 1; '
                   'IFS= read -r _OSRC_RELAY_PYTHON <&"$1" || exit 1; '
                   'eval "exec $1<&-"; shift; . "$0" "$@"')
        script, args = sys.argv[1], sys.argv[2:]
        child_env = os.environ.copy()
        for name in ('BASH_ENV', 'ENV', 'SHELLOPTS', 'BASHOPTS', '_OSRC_RELAY_SECRET'):
            child_env.pop(name, None)
        child = subprocess.Popen(
            ['/bin/bash', '-c', wrapper, script, str(key_fd),
             '--osrc-preflight-internal', '--osrc-preflight-relay', fifo] + args,
            close_fds=True, pass_fds=(key_fd, 18), env=child_env)
        os.close(key_fd)
        key_fd = None
        os.write(write_key, (token + '\n' + sys.executable + '\n').encode())
        os.close(write_key)
        write_key = None
        data = bytearray()
        while True:
            ready, _, _ = select.select([read_fifo], [], [], 0.1)
            if ready:
                part = os.read(read_fifo, 8192)
                if part:
                    data.extend(part)
                    if len(data) > 65536:
                        return 1
                else:
                    time.sleep(0.02)
            rc = child.poll()
            if rc is not None:
                while True:
                    try:
                        part = os.read(read_fifo, 8192)
                    except BlockingIOError:
                        break
                    if not part:
                        break
                    data.extend(part)
                    if len(data) > 65536:
                        return 1
                if rc:
                    return rc if rc > 0 else 128 - rc
                records = []
                for line in data.splitlines():
                    mac, separator, record = line.partition(b'|')
                    expected = hmac.new(bytes.fromhex(token), record, hashlib.sha256).hexdigest().encode()
                    if separator and hmac.compare_digest(mac, expected):
                        records.append(record)
                if len(records) != 1:
                    return 1
                os.write(3, records[0] + b'\n')
                return 0
    except (KeyboardInterrupt, BrokenPipeError):
        return 130
    finally:
        if child is not None and child.poll() is None:
            try:
                child.terminate()
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    child.kill()
                except ProcessLookupError:
                    pass
                child.wait()
        for fd in (read_fifo, key_fd, write_key):
            if fd is not None:
                os.close(fd)
        if directory is not None:
            shutil.rmtree(directory)
        if old_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


if __name__ == '__main__':
    sys.exit(main())
