#!/usr/bin/env python3
"""Write the benchmark programs into build/bench/.

    bench/programs.py

Five programs, all computing the same sum the same number of times. They
differ only in the SHAPE of the program around the loop, which is the whole
point: the difference between them is what Applesoft spends looking things up
rather than calculating.
"""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tokenise import program

N = 3000            # iterations; about half a minute for the baseline at 1MHz
OUT = pathlib.Path(__file__).resolve().parent.parent / "build" / "bench"

def loop(base):
    return [(base + 0,  "I = I + 1"),
            (base + 10, "S = S + I"),
            (base + 20, f"IF I < {N} THEN GOTO {base}")]

def tail(base, tag):
    # A UNIQUE marker per program. A shared one matched the previous run's
    # output still on screen and timed every benchmark at a quarter second.
    return [(base + 30, "PRINT S"), (base + 40, f'PRINT "END{tag}"')]

head = [(10, "S = 0"), (20, "I = 0")]
filler = [(100 + n, "REM FILLER") for n in range(200)]
# Two characters are significant in an Applesoft name, so Z00 and Z01 would be
# the same variable. These thirty are genuinely distinct.
names = [f"{c}{d}" for c in "ZYX" for d in "0123456789"]
dummies = [(30 + n, f"{names[n]} = 1") for n in range(30)]

PROGRAMS = {
    # the loop and nothing else: target line third, S and I the first variables
    "BENCH1": (head + loop(30) + tail(30, "ONE"), "ENDONE",
               "baseline: nothing to look past"),
    # 200 lines in front of the loop, so every GOTO walks to it
    "BENCH2": (head + filler + loop(1000) + tail(1000, "TWO"), "ENDTWO",
               "line search: 200 lines before the target"),
    # thirty variables exist before the loop's two
    "BENCH3": (head + dummies + loop(400) + tail(400, "TRE"), "ENDTRE",
               "variable table: 30 names to scan past"),
    # both, which is the shape a real program has
    "BENCH4": (head + dummies + filler + loop(1000) + tail(1000, "FOR"), "ENDFOR",
               "both, as a real program would be"),
    # the baseline with one statement removed, to price a statement
    "BENCH5": (head + [(30, "I = I + 1"), (40, f"IF I < {N} THEN GOTO 30"),
                       (50, "PRINT I"), (60, 'PRINT "ENDFIV"')], "ENDFIV",
               "one statement fewer than the baseline"),
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (lines, mark, what) in PROGRAMS.items():
        data = program(lines)
        (OUT / f"{name}.bas").write_bytes(data)
        print(f"{name}  {len(lines):3d} lines  {len(data):5d} bytes   {what}")
