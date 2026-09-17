#!/bin/bash
#
# Does the compiler ACCEPT this program?
#
#   tests/cccompile.sh FILE.bas [FILE.bas ...]
#
# cc.sh asks the only question worth asking of a test program -- does the
# compiled run print what the interpreter printed -- but it can only ask it of
# a program that prints, terminates, and fits on a screen. Real Applesoft is
# mostly none of those: BRIAN is a graphics demo with no output and no end,
# and LITTLE waits on the paddles.
#
# So this asks the smaller question those programs can answer. It takes
# ALREADY-TOKENISED .bas files, the form they arrive in off a real disk, puts
# them on a test image and compiles them, and reports what the compiler said.
# A program that compiles still has to be run by hand to know it is right --
# this says only that nothing was refused, which is exactly the step BRIAN and
# LITTLE keep failing at.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if pgrep -f "bash $0" | grep -qv "^$$\$"; then
    echo "another $0 is already running -- kill it first:" >&2; exit 1
fi
V=tools/vii.sh
AC=tools/ac
DIST=build/APPLESIDE-DIST.po
IMG=build/bench/CCOMPILE.po
export VII_SPEED=maximum

[ -f "$DIST" ] || { echo "no $DIST -- run: make dist" >&2; exit 1; }
[ -f build/ASIDECC.SYSTEM ] || { echo "no compiler -- run: make cc" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: $0 FILE.bas ..." >&2; exit 1; }

mkdir -p build/bench
osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
sleep 2
cp "$DIST" "$IMG"
# the same stale-binary trap cc.sh documents: -p ADDS, it does not replace
"$AC" -d "$IMG" ASIDECC.SYSTEM 2>/dev/null || true
"$AC" -p "$IMG" ASIDECC.SYSTEM SYS 0x2000 < build/ASIDECC.SYSTEM
[ "$("$AC" -l "$IMG" | grep -c ASIDECC.SYSTEM)" -eq 1 ] || {
    echo "more than one ASIDECC.SYSTEM -- the wrong one will run" >&2; exit 1; }

NAMES=()
for f in "$@"; do
    n=$(basename "$f" .bas | tr 'a-z' 'A-Z'); n=${n:0:7}
    "$AC" -d "$IMG" "$n" 2>/dev/null || true
    "$AC" -p "$IMG" "$n" BAS 0x0801 < "$f"
    NAMES+=("$n")
done

"$V" boot "$IMG" >/dev/null
"$V" await "ApplesIDE" 180 >/dev/null || { echo "the disk never booted" >&2; exit 1; }
"$V" text " " >/dev/null
"$V" settle 15 >/dev/null
"$V" caps true >/dev/null
"$V" oa "Q" >/dev/null
"$V" await "PRODOS BASIC" 180 >/dev/null || { echo "never reached BASIC" >&2; exit 1; }
"$V" settle 8 >/dev/null

fail=0
ORGS=()
for n in "${NAMES[@]}"; do
    printf '%-10s ' "$n"
    "$V" line "-ASIDECC.SYSTEM" >/dev/null
    "$V" await "COMPILE WHICH FILE" 120 >/dev/null || {
        echo "compiler did not start"; fail=1; continue; }
    "$V" line "$n" >/dev/null
    for i in $(seq 1 900); do
        "$V" screen 2>/dev/null | grep -qE "WROTE|STOPPED|CANNOT|TOO BIG" && break
    done
    msg=$("$V" screen | grep -E "WROTE|STOPPED|CANNOT|TOO BIG" | tail -1)
    echo "${msg:-NO VERDICT -- the compiler never answered}"
    case "$msg" in WROTE*) ;; *) fail=1;; esac
    ORGS+=("$n")
    "$V" text " " >/dev/null
    "$V" await "PRODOS BASIC" 180 >/dev/null || true
    "$V" settle 8 >/dev/null
done

# WHERE EACH ONE ACTUALLY LANDED. PICKORG's choice is stamped on the file as
# its ProDOS aux_type -- the address BRUN restores it to -- so this reads back
# what the compiler decided rather than what it was expected to decide.
#
# The emulator has to let go of the image first: it writes back to the .po,
# and reading it while a machine still holds it gets the catalogue as it was
# at boot, before anything was compiled into it.
if [ ${#ORGS[@]} -gt 0 ]; then
    osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
    sleep 2
    echo
    echo "load addresses:"
    for n in "${ORGS[@]}"; do
        printf '  %-10s ' "C$n"
        "$AC" -l "$IMG" 2>/dev/null | grep -E "^ *C$n " | grep -oE 'A=\$[0-9A-Fa-f]+' || echo "(not written)"
    done
fi
exit $fail
