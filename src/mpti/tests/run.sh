#!/usr/bin/env bash
#
# Builds and runs MPTI's recurring test suite:
#   - mptidemo: pure/headless checks (MptiTypes, MptiCell, MptiCaps,
#     MptiInput) - safe anywhere, no tty required.
#   - mptidrivertest + drive_pty.py: live-pty exercise of MptiDriver
#     (raw mode, SIGWINCH self-pipe, mode-enable sequences, real-fd
#     event decoding) - requires python3 with pty support (Unix only).
#
# Env overrides: FPCBIN, FPCDIR, TARGET, OUTDIR, UNITDIR, OPT

set -euo pipefail
cd "$(dirname "$0")/../../.."

FPCBIN=${FPCBIN:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}
FPCDIR=${FPCDIR:-$HOME/fpcupdeluxe/fpc}
TARGET=${TARGET:-x86_64-linux}
OUTDIR=${OUTDIR:-mpti-bin}
UNITDIR=${UNITDIR:-mpti-units/$TARGET}
OPT=${OPT:--O2}

mkdir -p "$OUTDIR" "$UNITDIR"

echo "=== building + running mptidemo (headless) ==="
"$FPCBIN" -Mobjfpc -Sh $OPT -Xs \
  -FE"$OUTDIR" -FU"$UNITDIR" -Fusrc/mpti \
  -omptidemo src/mpti/tests/mptidemo.lpr
"$OUTDIR/mptidemo"

echo
echo "=== building mptidrivertest (live pty) ==="
"$FPCBIN" -Mobjfpc -Sh $OPT -Xs \
  -FE"$OUTDIR" -FU"$UNITDIR" -Fusrc/mpti \
  -omptidrivertest src/mpti/tests/mptidrivertest.lpr

if command -v python3 >/dev/null 2>&1; then
  echo
  echo "=== running drive_pty.py ==="
  MPTIDRIVERTEST_BIN="$OUTDIR/mptidrivertest" python3 "$(dirname "$0")/drive_pty.py" \
    || { echo "drive_pty.py FAILED"; exit 1; }
else
  echo "python3 not found - skipping live-pty driver test"
fi

echo
echo "all mpti tests passed"
