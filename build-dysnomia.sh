#!/usr/bin/env bash
#
# Build Dysnomia, the Free Vision frontend for Eris, for x64 linux. This is
# the primary target until Dysnomia works as a real application here; the
# PowerPC port comes after, see build-dysnomia-ppc.sh.
#
# Plain fpc, no lazbuild, no LCL. The unit search path below is the whole
# isolation mechanism: src/ui and src/themeengine are deliberately absent,
# so a Lazarus unit cannot reach the binary. If one is pulled in by some
# uses clause the compiler errors out - that is the intended behaviour,
# fix the uses clause, do not add the path.
#
# Env overrides: FPCBIN, FPCDIR, TARGET, OUTDIR, UNITDIR, OPT

set -euo pipefail
cd "$(dirname "$0")"

FPCBIN=${FPCBIN:-$HOME/fpcupdeluxe/fpc/bin/x86_64-linux/fpc}
FPCDIR=${FPCDIR:-$HOME/fpcupdeluxe/fpc}
TARGET=${TARGET:-x86_64-linux}
OUTDIR=${OUTDIR:-dysnomia-bin}
UNITDIR=${UNITDIR:-dysnomia-units/$TARGET}
OPT=${OPT:--O3}
# LazUtils source (FileUtil etc., pulled in by src/project/ProjectFile.pas
# for Load/Save) - a Lazarus-IDE-adjacent package, not LCL: no widgetset,
# no Forms/Graphics, safe under the Isolation rule in tui.md (only src/ui
# and src/themeengine are actually forbidden).
LAZUTILSDIR=${LAZUTILSDIR:-$HOME/fpcupdeluxe/lazarus/components/lazutils}

mkdir -p "$OUTDIR" "$UNITDIR"

"$FPCBIN" \
  -Mobjfpc -Sh $OPT -Xs \
  -FE"$OUTDIR" -FU"$UNITDIR" \
  -Fu"$FPCDIR/units/$TARGET/fv" \
  -Fu"$LAZUTILSDIR" \
  -Fusrc/tui \
  -Fusrc/mpti \
  -Fusrc/aengine -Fusrc/abackend -Fusrc/project -Fusrc/util \
  -dERIS_TUI \
  -odysnomia \
  src/tui/dysnomia.lpr

echo "built $OUTDIR/dysnomia ($TARGET)"
