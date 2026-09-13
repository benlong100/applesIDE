#!/bin/bash
#
# Does the compiler agree with the interpreter?
#
#   make cctest
#
# That is the whole specification, and the only one worth testing against: a
# compiled program is correct when it prints exactly what Applesoft prints for
# the same source. So every program in tests/cc is RUN and then compiled and
# BRUN, in the same session on the same disk, and the two screens are compared.
#
# The programs deliberately print rather than compute silently. A wrong answer
# has to be visible to be caught, and the interpreter is the thing that says
# what right looks like -- not a table of expected output written by hand,
# which would only record what was believed at the time.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
V=tools/vii.sh
AC=tools/ac
DIST=build/APPLESIDE-DIST.po
IMG=build/bench/CCTEST-RUN.po
export VII_SPEED=maximum          # correctness, not timing: go as fast as it will

[ -f "$DIST" ] || { echo "no $DIST -- run: make dist" >&2; exit 1; }
[ -f build/ASIDECC.SYSTEM ] || { echo "no compiler -- run: make cc" >&2; exit 1; }

mkdir -p build/bench
NAMES=()
for src in tests/cc/*.bas.txt; do
    n=$(basename "$src" .bas.txt | tr 'a-z' 'A-Z')
    n=${n:0:7}                     # the compiler prepends a C; ProDOS allows 15
    python3 - "$src" "build/bench/$n.bas" <<'PY'
import sys, pathlib
sys.path.insert(0, "bench")
from tokenise import program
src, out = sys.argv[1], sys.argv[2]
lines = []
for line in open(src):
    line = line.strip()
    if not line:
        continue
    num, rest = line.split(" ", 1)
    lines.append((int(num), rest))
pathlib.Path(out).write_bytes(program(lines))
PY
    NAMES+=("$n")
done

# Built while the emulator does not hold it: a file added to a mounted image
# is one the emulator cannot see.
osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
sleep 2
cp "$DIST" "$IMG"
"$AC" -p "$IMG" ASIDECC.SYSTEM SYS 0x2000 < build/ASIDECC.SYSTEM
for n in "${NAMES[@]}"; do
    "$AC" -p "$IMG" "$n" BAS 0x0801 < "build/bench/$n.bas"
done

to_basic() {
    "$V" await "PRODOS BASIC" 180 >/dev/null || { echo "never reached BASIC" >&2; exit 1; }
    "$V" settle 8 >/dev/null
}

"$V" boot "$IMG" >/dev/null
"$V" await "ApplesIDE" 180 >/dev/null || { echo "the disk never booted" >&2; exit 1; }
"$V" text " " >/dev/null
"$V" settle 15 >/dev/null
"$V" caps true >/dev/null
"$V" oa "Q" >/dev/null
to_basic

# HOME first, every time: the previous run's output is still on the screen and
# would otherwise be read as this one's.
#
# THE ECHO IS FOUND, NOT ASSUMED. This used to drop the screen's first row,
# taking it for the echoed command -- which it is only while the output is
# short enough not to scroll. A program that printed a screenful pushed the
# echo off the top, so the first row became a real line of output and the
# capture ate it. The compiled run of the same program scrolled differently
# and the two disagreed by one line: a harness fault wearing a compiler
# fault's clothes. Prompt lines start with ] and nothing a test prints does.
#
# And a program whose output fills the screen is refused outright rather than
# silently compared on what is left of it. A truncation is not a result.
capture() {                        # command -> what it printed, one line each
    "$V" line "HOME" >/dev/null
    "$V" settle 4 >/dev/null
    "$V" line "$1" >/dev/null
    local i
    for i in $(seq 1 400); do
        "$V" screen 2>/dev/null | grep -qE "^DONE|\\?.*ERROR" && break
    done
    "$V" settle 4 >/dev/null
    local out
    out=$("$V" screen | grep -v '^\]' | sed '/^$/d')
    if [ "$(printf '%s\n' "$out" | wc -l)" -ge 22 ]; then
        echo "OUTPUT-FILLS-THE-SCREEN--SPLIT-THIS-PROGRAM"
        return
    fi
    printf '%s\n' "$out"
}

fail=0
for n in "${NAMES[@]}"; do
    printf '%-10s ' "$n"
    "$V" line "LOAD $n" >/dev/null
    "$V" settle 6 >/dev/null
    interp=$(capture "RUN")

    "$V" line "-ASIDECC.SYSTEM" >/dev/null
    "$V" await "COMPILE WHICH FILE" 120 >/dev/null || { echo "compiler did not start"; fail=1; continue; }
    "$V" line "$n" >/dev/null
    for i in $(seq 1 900); do
        "$V" screen 2>/dev/null | grep -qE "WROTE|STOPPED|CANNOT" && break
    done
    msg=$("$V" screen | grep -E "WROTE|STOPPED|CANNOT" | tail -1)
    "$V" text " " >/dev/null
    to_basic
    case "$msg" in
        WROTE*) ;;
        *) echo "did not compile: $msg"; fail=1; continue;;
    esac

    comp=$(capture "BRUN C$n")
    if [ "$interp" = "$comp" ]; then
        echo "agrees  ($(echo "$interp" | wc -l | tr -d ' ') lines)"
    else
        echo "DIFFERS"
        diff <(echo "$interp") <(echo "$comp") | sed 's/^/           /'
        fail=1
    fi
done

exit $fail
