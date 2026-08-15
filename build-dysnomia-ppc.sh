#!/usr/bin/env bash
#
# Cross-build Dysnomia for powerpc-darwin (G4, Tiger+). Phase 2 only - the
# x64 build is the one to work against until Dysnomia is a finished
# application, see tui.md. This script exists now so the PPC path is never
# a surprise, not so it gets used yet.
#
# Same source, same flags as the x64 build, different target triple.
# Because no Lazarus is involved there is no Carbon widgetset to satisfy
# and no host Mac needed - this produces a shippable binary. A TUI binary
# is a plain CLI executable, so no .app bundle is required.
#
# Env overrides: FPCBIN, FPCDIR, CROSSDIR, TARGET, BINUTILSPREFIX,
#                MACOSVER, OUTDIR, UNITDIR, OPT, CPUOPT

set -euo pipefail
cd "$(dirname "$0")"

FPCBIN=${FPCBIN:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}
FPCDIR=${FPCDIR:-$HOME/fpcupdeluxe/fpc}
CROSSDIR=${CROSSDIR:-$HOME/fpcupdeluxe/cross}
TARGET=${TARGET:-powerpc-darwin}
BINUTILSPREFIX=${BINUTILSPREFIX:-powerpc64-apple-darwin8-}
MACOSVER=${MACOSVER:-10.4}
OUTDIR=${OUTDIR:-dysnomia-bin}
UNITDIR=${UNITDIR:-dysnomia-units/$TARGET}
OPT=${OPT:--O3}

# CPU tuning for the 7400/7447A. Left empty by default - set CPUOPT once
# the AltiVec work in avector.pas lands and the right -Cp/-Cf values for
# this fpc build have been confirmed.
CPUOPT=${CPUOPT:-}

mkdir -p "$OUTDIR" "$UNITDIR"

"$FPCBIN" \
  -Tdarwin -Ppowerpc \
  -Mobjfpc -Sh $OPT $CPUOPT -Xs \
  -XP"$BINUTILSPREFIX" \
  -FD"$CROSSDIR/bin/$TARGET/bin" \
  -XR"$CROSSDIR/lib/$TARGET" \
  -WM"$MACOSVER" \
  -FE"$OUTDIR" -FU"$UNITDIR" \
  -Fu"$FPCDIR/units/$TARGET/fv" \
  -Fusrc/tui \
  -Fusrc/mpti \
  -Fusrc/aengine -Fusrc/abackend -Fusrc/project -Fusrc/util \
  -dERIS_TUI \
  -odysnomia-ppc \
  src/tui/dysnomia.lpr

echo "built $OUTDIR/dysnomia-ppc ($TARGET, min macOS $MACOSVER)"
