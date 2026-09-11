#!/bin/bash
#
# What does Applesoft spend its time on, and how much of that could a compiler
# take away? Times five programs that compute the same thing and differ only in
# the shape of the program around the loop.
#
#   make bench
#
# Runs at 1MHz deliberately: at the emulator's default speed the differences
# are still there but the wall clock stops meaning anything.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
V=tools/vii.sh
AC=tools/ac
DIST=build/APPLESIDE-DIST.po
IMG=build/bench/BENCH.po
export VII_SPEED=regular

[ -f "$DIST" ] || { echo "no $DIST -- run: make dist" >&2; exit 1; }

python3 bench/programs.py
echo

# The disk is a COPY OF THE DIST IMAGE, not a fresh one: AppleCommander can
# format a ProDOS volume but the boot blocks it writes are its own, and such a
# disk stops at "INSERT ANOTHER DISK". mkdisk.sh clones a known-good image for
# the same reason.
#
# And the image is built while the emulator does NOT hold it. Adding a file to
# a mounted image leaves the emulator unable to see it -- which cost a
# measurement that then reported its own timeout as a result.
osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1 || true
sleep 2
cp "$DIST" "$IMG"
for b in BENCH1 BENCH2 BENCH3 BENCH4 BENCH5; do
    "$AC" -p "$IMG" "$b" BAS 0x0801 < "build/bench/$b.bas"
done

"$V" boot "$IMG" >/dev/null
"$V" await "ApplesIDE" 180 >/dev/null || { echo "the disk never booted" >&2; exit 1; }
"$V" text " " >/dev/null
"$V" settle 15 >/dev/null
"$V" caps true >/dev/null
"$V" oa "Q" >/dev/null
"$V" await "PRODOS BASIC" 120 >/dev/null || { echo "never reached BASIC" >&2; exit 1; }

time_one() {                       # name marker -> seconds, or a loud failure
    local name="$1" mark="$2"
    "$V" line "LOAD $name" >/dev/null
    "$V" settle 10 >/dev/null
    if "$V" screen 2>/dev/null | grep -qE "NOT FOUND|SYNTAX ERROR"; then
        echo "LOAD-FAILED"; return
    fi
    local t0 t1 found=0
    t0=$(python3 -c 'import time;print(time.time())')
    "$V" line "RUN" >/dev/null
    local i
    for i in $(seq 1 1200); do
        if "$V" screen 2>/dev/null | grep -q "$mark"; then found=1; break; fi
    done
    t1=$(python3 -c 'import time;print(time.time())')
    # A timeout is NOT a measurement. Saying so is the difference between a
    # number and a number-shaped thing.
    [ "$found" = "1" ] || { echo "TIMEOUT"; return; }
    python3 -c "print(f'{$t1-$t0:.2f}')"
}

# Plain variables, not an associative array: macOS ships bash 3.2, where
# `declare -A` is a syntax error.
RESULTS=""
for spec in "BENCH1 ENDONE" "BENCH2 ENDTWO" "BENCH3 ENDTRE" "BENCH4 ENDFOR" "BENCH5 ENDFIV"; do
    set -- $spec
    printf '%-8s ' "$1"
    r="$(time_one "$1" "$2")"
    echo "$r"
    RESULTS="$RESULTS $r"
done

echo
python3 - $RESULTS <<'PYEOF'
import sys
try:
    b1, b2, b3, b4, b5 = (float(x) for x in sys.argv[1:6])
except ValueError:
    print("a run did not produce a time; nothing to conclude"); raise SystemExit(1)
search, vars_ = b2 - b1, b3 - b1
print(f"line search   {search:7.2f}s  {search/b4*100:5.1f}% of a real-shaped program")
print(f"variable scan {vars_:7.2f}s  {vars_/b4*100:5.1f}%")
print(f"both          {search+vars_:7.2f}s  {(search+vars_)/b4*100:5.1f}%  <- what resolving addresses removes")
print(f"one statement {b1-b5:7.2f}s  {(b1-b5)/3000*1000:5.2f}ms each, mostly the ROM's floating point")
print()
print(f"predicted BENCH4 by addition: {b1+search+vars_:.2f}s, measured {b4:.2f}s")
print(f"speedup available from address resolution alone: {b4/b1:.2f}x")
PYEOF
