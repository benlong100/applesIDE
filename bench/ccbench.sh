#!/bin/bash
#
# The acceptance test the design named: the same five programs, compiled by
# the native compiler on the machine, giving the same answers in less time.
#
#   make ccbench
#
# 1MHz, like bench.sh, because at the emulator's default speed the wall clock
# stops meaning anything.
#
# Each program is timed twice -- interpreted, then compiled -- in the same
# session on the same disk, so the two numbers are comparable without any
# argument about the machine's state in between.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
V=tools/vii.sh
AC=tools/ac
DIST=build/APPLESIDE-DIST.po
IMG=build/bench/CCBENCH.po
export VII_SPEED=regular

[ -f "$DIST" ] || { echo "no $DIST -- run: make dist" >&2; exit 1; }
[ -f build/ASIDECC.SYSTEM ] || { echo "no compiler -- run: make cc" >&2; exit 1; }

python3 bench/programs.py
echo

# Built while the emulator does NOT hold the image: adding a file to a mounted
# one leaves the emulator unable to see it, which has cost a measurement here
# before.
osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
sleep 2
cp "$DIST" "$IMG"
"$AC" -p "$IMG" ASIDECC.SYSTEM SYS 0x2000 < build/ASIDECC.SYSTEM
for b in BENCH1 BENCH2 BENCH3 BENCH4 BENCH5; do
    "$AC" -p "$IMG" "$b" BAS 0x0801 < "build/bench/$b.bas"
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

# HOME FIRST, EVERY TIME. The end marker is looked for on the screen, and the
# previous run's is still up there: a shared marker once timed every program
# in this directory at a quarter of a second.
timed() {                          # command marker -> seconds, or a loud failure
    local cmd="$1" mark="$2" t0 t1 found=0 i
    "$V" line "HOME" >/dev/null
    "$V" settle 5 >/dev/null
    t0=$(python3 -c 'import time;print(time.time())')
    "$V" line "$cmd" >/dev/null
    for i in $(seq 1 1200); do
        if "$V" screen 2>/dev/null | grep -q "$mark"; then found=1; break; fi
    done
    t1=$(python3 -c 'import time;print(time.time())')
    # A timeout is NOT a measurement.
    [ "$found" = "1" ] || { echo "TIMEOUT"; return; }
    python3 -c "print(f'{$t1-$t0:.2f}')"
}

compile_one() {                    # name -> the size it reported, or a failure
    local name="$1" i
    "$V" line "-ASIDECC.SYSTEM" >/dev/null
    "$V" await "COMPILE WHICH FILE" 90 >/dev/null || { echo "NOSTART"; return; }
    "$V" line "$name" >/dev/null
    for i in $(seq 1 900); do
        if "$V" screen 2>/dev/null | grep -qE "WROTE|STOPPED|CANNOT"; then break; fi
    done
    local line
    line=$("$V" screen | grep -E "WROTE|STOPPED|CANNOT" | tail -1)
    "$V" text " " >/dev/null        # any key: the compiler then loads BASIC
    to_basic
    echo "$line"
}

printf '%-8s %10s %10s %8s   %s\n' program interpreted compiled speedup answer
for spec in "BENCH1 ENDONE" "BENCH2 ENDTWO" "BENCH3 ENDTRE" "BENCH4 ENDFOR" "BENCH5 ENDFIV"; do
    set -- $spec
    name="$1"; mark="$2"
    "$V" line "LOAD $name" >/dev/null
    "$V" settle 10 >/dev/null
    ti=$(timed "RUN" "$mark")
    ansi=$("$V" screen | grep -B1 "$mark" | head -1)

    msg=$(compile_one "$name")
    case "$msg" in
        WROTE*) ;;
        *) printf '%-8s %10s   %s\n' "$name" "$ti" "$msg"; continue;;
    esac
    tc=$(timed "BRUN C$name" "$mark")
    ansc=$("$V" screen | grep -B1 "$mark" | head -1)

    if [ "$ansi" != "$ansc" ]; then
        printf '%-8s %10s %10s %8s   DIFFERENT: %s vs %s\n' \
               "$name" "$ti" "$tc" "-" "$ansi" "$ansc"
        continue
    fi
    sp=$(python3 -c "
try: print(f'{$ti/$tc:.1f}x')
except Exception: print('-')" 2>/dev/null || echo "-")
    printf '%-8s %10s %10s %8s   %s\n' "$name" "$ti" "$tc" "$sp" "$ansc"
done
