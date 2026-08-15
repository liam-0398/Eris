#!/usr/bin/env python3
"""
Drives mptidrivertest under a real pty and asserts on its stderr log.

This is the regression test for the parts of MptiDriver (src/mpti/
MptiDriver.pas) that can only be exercised against a live tty: raw-mode
enable/disable, the SIGWINCH self-pipe, the mode-enable/disable escape
sequences, and MRunOnce actually decoding bytes that arrived over a real
fd (as opposed to MptiInput's pure parser, which tests/mptidemo.lpr
already covers with a synthetic byte array).

Usage: run.sh builds mptidrivertest.lpr and invokes this. Exits nonzero
and prints what was expected vs. seen on any assertion failure.
"""
import os
import pty
import time
import fcntl
import struct
import termios
import select
import sys

BIN = os.environ.get(
    "MPTIDRIVERTEST_BIN",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "mptidrivertest"),
)

EXPECTED_SUBSTRINGS = [
    "hastty=TRUE",
    "\x1b[?1000h\x1b[?1006h",   # mouse tracking enabled
    "\x1b[?2004h",              # bracketed paste enabled
    "\x1b[?1004h",              # focus events enabled
    "\x1b[c",                   # DA1 probe sent
    "key code=6 cp=0 ctrl=FALSE alt=FALSE shift=FALSE",   # arrow up
    "key code=1 cp=97 ctrl=TRUE alt=FALSE shift=FALSE",   # Ctrl+A
    "mouse btn=1 x=4 y=2",                                 # SGR mouse press
    'paste="pasted text"',                                 # bracketed paste
    "key code=5 cp=0 ctrl=FALSE alt=FALSE shift=FALSE",   # lone ESC -> Escape
    "resize -> 120x40",                                    # SIGWINCH -> resize
    "\x1b[?1004l\x1b[?2004l\x1b[?1006l\x1b[?1000l",        # modes disabled on exit
    "done, events=",
]


def main():
    if not os.path.exists(BIN):
        print(f"FAIL: {BIN} not built - run run.sh, not this script directly", file=sys.stderr)
        return 1

    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        os.execv(BIN, [BIN])

    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    time.sleep(0.3)
    os.write(master_fd, b"\x1b[A")                          # arrow up
    time.sleep(0.1)
    os.write(master_fd, b"\x01")                             # Ctrl+A
    time.sleep(0.1)
    os.write(master_fd, b"\x1b[<0;5;3M")                     # SGR mouse press
    time.sleep(0.2)
    os.write(master_fd, b"\x1b[200~pasted text\x1b[201~")    # bracketed paste
    time.sleep(0.2)
    os.write(master_fd, b"\x1b")                             # lone ESC
    time.sleep(0.2)
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    time.sleep(0.3)

    out = b""
    start = time.time()
    while time.time() - start < 8:
        r, _, _ = select.select([master_fd], [], [], 0.5)
        if master_fd in r:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        pidr, _ = os.waitpid(pid, os.WNOHANG)
        if pidr == pid:
            break

    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    text = out.decode("utf-8", errors="replace")
    failures = [s for s in EXPECTED_SUBSTRINGS if s not in text]

    if failures:
        print("FAIL: missing expected output:", file=sys.stderr)
        for f in failures:
            print(f"  - {f!r}", file=sys.stderr)
        print("--- full output ---", file=sys.stderr)
        print(text, file=sys.stderr)
        return 1

    print(f"ok: all {len(EXPECTED_SUBSTRINGS)} expected markers seen")
    return 0


if __name__ == "__main__":
    sys.exit(main())
