# What does Applesoft spend its time on?

    make bench

Five programs that compute the same sum, three thousand times, and differ only
in the **shape of the program around the loop**. The difference between them is
what the interpreter spends looking things up rather than calculating — which
is exactly what a compiler resolves once and never pays for again.

Run at 1MHz deliberately. At the emulator's default speed the differences are
still there and the wall clock stops meaning anything.

## What was measured

| | | |
|---|---|---|
| `BENCH1` | the loop and nothing else | **33.79s** |
| `BENCH2` | 200 lines of program in front of the loop | **66.72s** |
| `BENCH3` | 30 variables created before the loop's two | **38.87s** |
| `BENCH4` | both, which is the shape a real program has | **71.52s** |
| `BENCH5` | the baseline with one statement removed | **26.93s** |

## What it says

- **Line search: 32.93s, 46% of a real-shaped program.** One `GOTO` per
  iteration. Applesoft finds a line by walking the program from the start, so
  this is proportional to how far in the target sits.
- **Variable table: 5.08s, 7%.** Every reference scans the table by name.
- **Together, 53%** — and both are addresses a compiler works out once.
- **One statement costs 2.29ms**, most of it the ROM's floating point, which a
  compiler still calls and cannot make faster.

**A compiler that did nothing but resolve addresses would be 2.12× faster**,
and that is a floor rather than a ceiling: removing per-statement dispatch and
the re-parsing of numeric constants eats into the other half too. It lands
where TASC and the Beagle Compiler reported in period (2–5×), which is some
comfort that the number is not an artefact of this benchmark.

**The model holds.** Adding the two costs to the baseline predicts BENCH4 at
71.80s against 71.52s measured — 0.4%. The costs are independent and additive.

## What this benchmark is not

Arithmetic in a tight loop is the **best case** for compiling: it is the shape
where interpretation overhead dominates. A program that mostly `PRINT`s, works
on strings, or draws will show far less, because that time is spent inside the
ROM either way and a compiler calls the same routines.

Nearly all of the win is the `GOTO` search, and that needs no code generator:
resolving line-number references to addresses is a far smaller program than a
compiler, and captures most of the benefit.

## Three ways this lied before it told the truth

Kept here because each produced a confident, wrong number.

- **A shared end marker.** Every program printed `DONE`, so the wait matched
  the *previous* run's output still on screen and timed every benchmark at
  0.27s. Each program has its own marker now.
- **A timeout reported as a measurement.** BENCH4 "took" 119.36s when it had
  not loaded at all; the poll simply ran out. The harness says `TIMEOUT` now
  and exits, because a number-shaped thing is worse than no number.
- **A file added to a mounted image.** That is why BENCH4 failed to load:
  Virtual ][ holds the image and never saw the addition. The disk is built
  with the emulator ejected.
