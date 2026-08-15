#!/usr/bin/env bash
#
# Build the MPTI smoke-test/demo program for x64 linux. Same conventions
# as build-dysnomia.sh: plain fpc, no lazbuild, no LCL. Unlike Dysnomia's
# build, this one has no FV/LazUtils unit path at all - MPTI is
# dependency-free by design (mpti.md requirement 9), so if a uses clause
# ever needs a path outside src/mpti, that is a bug to fix in the code,
# not in this script.
#
# Env overrides: FPCBIN, FPCDIR, TARGET, OUTDIR, UNITDIR, OPT

set -euo pipefail
cd "$(dirname "$0")"

FPCBIN=${FPCBIN:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}
FPCDIR=${FPCDIR:-$HOME/fpcupdeluxe/fpc}
TARGET=${TARGET:-x86_64-linux}
OUTDIR=${OUTDIR:-mpti-bin}
UNITDIR=${UNITDIR:-mpti-units/$TARGET}
OPT=${OPT:--O3}

mkdir -p "$OUTDIR" "$UNITDIR"

"$FPCBIN" \
  -Mobjfpc -Sh $OPT -Xs \
  -FE"$OUTDIR" -FU"$UNITDIR" \
  -Fusrc/mpti \
  -omptidemo \
  src/mpti/tests/mptidemo.lpr

echo "built $OUTDIR/mptidemo ($TARGET)"
