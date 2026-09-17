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

# ONE AT A TIME. Two of these share one emulator and interleave their
# keystrokes into it: the run crawls and the answers are meaningless, but they
# are meaningless in a way that reads as a compiler bug. A stale run from an
# interrupted session is the usual cause, so say so rather than join in.
if pgrep -f "bash $0" | grep -qv "^$$\$"; then
    echo "another $0 is already running -- kill it first:" >&2
    pgrep -fl "bash $0" >&2
    exit 1
fi
V=tools/vii.sh
AC=tools/ac
DIST=build/APPLESIDE-DIST.po
IMG=build/bench/CCTEST-RUN.po
export VII_SPEED=maximum          # correctness, not timing: go as fast as it will

[ -f "$DIST" ] || { echo "no $DIST -- run: make dist" >&2; exit 1; }
[ -f build/ASIDECC.SYSTEM ] || { echo "no compiler -- run: make cc" >&2; exit 1; }

mkdir -p build/bench
# One program by name -- tests/cc.sh data -- for when a single failure is being
# chased and a full pass costs twenty minutes.
SRCS=(tests/cc/*.bas.txt)
if [ -n "$1" ]; then
    SRCS=("tests/cc/$1.bas.txt")
    [ -f "${SRCS[0]}" ] || { echo "no such program: ${SRCS[0]}" >&2; exit 1; }
fi

NAMES=()
for src in "${SRCS[@]}"; do
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

# THE ROOT DIRECTORY HOLDS FIFTY-ONE ENTRIES, and the suite outgrew it: with
# forty-eight programs plus the system files, `ac -p` refused the last of them
# with "Unable to allocate another file entry in root directory" and the run
# produced nothing at all -- no failures, no passes, which reads like the
# harness having done nothing rather than like a full disk.
#
# So the programs go on in batches, a fresh image and a reboot for each. The
# same limit already bit the compiled OUTPUTS, which is why each one is
# deleted as soon as its answer has been read; this is the same wall reached
# from the other side, by the sources.
BATCH=20

build_image() {                    # the names for this batch
    # Built while the emulator does not hold it: a file added to a mounted
    # image is one the emulator cannot see.
    osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
    sleep 2
    cp "$DIST" "$IMG"
# DELETE IT FIRST. `ac -p` on a name that is already in the catalogue ADDS a
# second entry rather than replacing it, and ProDOS runs the first one it
# finds -- so the image built from the distribution disk, which already ships
# a compiler, kept running THAT one no matter what had just been assembled.
# Every result here was a verdict on whatever `make dist` last baked in.
#
# It looks exactly like a fix not working: the source is right, the binary is
# right, and the machine disagrees.
    "$AC" -d "$IMG" ASIDECC.SYSTEM 2>/dev/null || true
    "$AC" -p "$IMG" ASIDECC.SYSTEM SYS 0x2000 < build/ASIDECC.SYSTEM

# and say so if a stale one survived anyway
    if [ "$("$AC" -l "$IMG" | grep -c ASIDECC.SYSTEM)" -ne 1 ]; then
        echo "more than one ASIDECC.SYSTEM on $IMG -- the wrong one will run" >&2
        exit 1
    fi
    local n
    for n in "$@"; do
        "$AC" -p "$IMG" "$n" BAS 0x0801 < "build/bench/$n.bas"
    done
}

to_basic() {
    "$V" await "PRODOS BASIC" 180 >/dev/null || { echo "never reached BASIC" >&2; exit 1; }
    "$V" settle 8 >/dev/null
}

boot_image() {
    "$V" boot "$IMG" >/dev/null
    "$V" await "ApplesIDE" 180 >/dev/null || { echo "the disk never booted" >&2; exit 1; }
    "$V" text " " >/dev/null
    "$V" settle 15 >/dev/null
    "$V" caps true >/dev/null
    "$V" oa "Q" >/dev/null
    to_basic
}

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
# A program that asks gets answered, from tests/cc/<name>.in, one line per
# INPUT. BOTH RUNS ARE GIVEN THE SAME ANSWERS, which is what makes an
# interactive program testable at all: the prompts are part of the screen, so
# a compiled INPUT that printed ? where Applesoft prints nothing shows up as a
# difference like any other.
#
# `IFS= read -r` on purpose: a trailing space is meaningful here. Applesoft
# keeps the trailing spaces of an unquoted string item and strips the leading
# ones, and the test that says so has to be able to send them.
capture() {                        # command [answers] -> what it printed
    "$V" line "HOME" >/dev/null
    "$V" settle 4 >/dev/null
    "$V" line "$1" >/dev/null
    if [ -n "$2" ] && [ -f "$2" ]; then
        local ln
        while IFS= read -r ln; do
            "$V" settle 3 >/dev/null
            "$V" line "$ln" >/dev/null
        done < "$2"
    fi
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

# ONE BATCH AT A TIME, each on its own image: see BATCH above for why. The
# index into NAMES is kept across batches so the answers file still lines up
# with the source it answers.
idx=0
while [ $idx -lt ${#NAMES[@]} ]; do
    build_image "${NAMES[@]:$idx:$BATCH}"
    boot_image
    last=$((idx + BATCH))
    [ $last -gt ${#NAMES[@]} ] && last=${#NAMES[@]}

for (( ; idx < last; idx++ )); do
    n="${NAMES[$idx]}"
    # the answers file sits beside the source it answers
    ANSWERS="${SRCS[$idx]%.bas.txt}.in"
    [ -f "$ANSWERS" ] || ANSWERS=""
    printf '%-10s ' "$n"
    "$V" line "LOAD $n" >/dev/null
    "$V" settle 6 >/dev/null
    interp=$(capture "RUN" "$ANSWERS")

    "$V" line "-ASIDECC.SYSTEM" >/dev/null
    # A WEDGED MACHINE IS NOT TWENTY MORE FAILURES. When a compiled program
    # hangs, the prompt never comes back, and every program after it sat out
    # its full two-minute timeout against the same dead screen -- seven of
    # them, which is where a run that should have taken ten minutes spent
    # twenty-five. Reboot once and carry on; give up if that does not help.
    if ! "$V" await "COMPILE WHICH FILE" 120 >/dev/null; then
        echo "compiler did not start -- rebooting"
        "$V" boot "$IMG" >/dev/null
        "$V" await "ApplesIDE" 180 >/dev/null && "$V" text " " >/dev/null
        "$V" settle 15 >/dev/null; "$V" caps true >/dev/null
        "$V" oa "Q" >/dev/null
        to_basic
        "$V" line "-ASIDECC.SYSTEM" >/dev/null
        "$V" await "COMPILE WHICH FILE" 120 >/dev/null || {
            echo "still wedged after a reboot -- stopping" >&2; exit 1; }
        fail=1
    fi
    "$V" line "$n" >/dev/null
    for i in $(seq 1 900); do
        "$V" screen 2>/dev/null | grep -qE "WROTE|STOPPED|CANNOT|TOO BIG" && break
    done
    msg=$("$V" screen | grep -E "WROTE|STOPPED|CANNOT|TOO BIG" | tail -1)
    "$V" text " " >/dev/null
    to_basic
    case "$msg" in
        WROTE*) ;;
        *) echo "did not compile: $msg"; fail=1; continue;;
    esac

    comp=$(capture "BRUN C$n" "$ANSWERS")

    # DELETED AS SOON AS IT HAS BEEN RUN. A ProDOS root directory holds 51
    # entries, and a compiled output for every test program plus the sources
    # plus the system files reached exactly that: the last two programs of the
    # run could not write their output and reported it as a compiler failure,
    # CANNOT WRITE THE OUTPUT, CODE 49 -- which is volume directory full, and
    # says nothing about the compiler at all. Each one goes as soon as its
    # answer has been read, so the count stays where it was when twenty
    # programs fitted.
    "$V" line "DELETE C$n" >/dev/null
    "$V" settle 3 >/dev/null

    if [ "$interp" = "$comp" ]; then
        echo "agrees  ($(echo "$interp" | wc -l | tr -d ' ') lines)"
    else
        echo "DIFFERS"
        diff <(echo "$interp") <(echo "$comp") | sed 's/^/           /'
        fail=1
    fi
done
done

exit $fail
