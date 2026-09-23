# ApplesIDE

An Applesoft BASIC editor for the Enhanced Apple //e, written in 6502 assembly
and running under ProDOS 8.

**Early, and now two programs.** The editor, and a compiler for what you
write in it — a separate application on the same disk, so that the editor
stays light for somebody who only wants an editor.

    make          assemble src/aside.S
    make disk     bootable ProDOS 8 image at build/APPLESIDE.po
    make run      build and boot it in Virtual ][
    make test     run the regression suite (141 assertions)
    make dist     an image to give away: adds BASIC.SYSTEM, the compiler
                  and a README
    make card VOL=NAME   copy the image to an SD card
    make tools    fetch the toolchain on a fresh clone

    make cc       assemble the compiler, src/cc/cc.S
    make cctest   compile every program in tests/cc and check it against
                  the interpreter
    make ccbench  time the five benchmark programs both ways, at 1MHz
    make bench    what the interpreter spends its time on

## What it is

ZipEdit's engine with a different front end — the same gap buffer, screen
drivers, ProDOS file I/O, prompt and help machinery, and localisation
pipeline, with the one thing a BASIC editor must not have taken out.

ZipEdit hard-wraps as you type, so a logical line is always one screen row.
That is free in Markdown and fatal in Applesoft, where breaking a line changes
the program. ApplesIDE keeps the same one-line-per-row invariant the opposite
way round: it never breaks a line, and will scroll sideways instead.

`docs/design.md` has the reasoning, including the three decisions that shaped
the project and the one component deliberately deferred.

## What works now

- boots, splash, empty program buffer
- typing, arrows, Return, Delete, selection
- the two-page help screen
- the status row: filename, line, column, free memory
- **long lines**: the view scrolls sideways in jumps of 16 columns to follow
  the cursor, which is how a BASIC line stays one screen row without ever
  being broken. The line number stays pinned at the left when it does, with a
  `>` marking where text has been scrolled past
- **`?` types PRINT**, the way Applesoft itself reads it — but not inside a
  string or after REM, where it would change the program
- **real Applesoft files.** Saves tokenized `$FC` at `$0801`, so `RUN` works
  straight off. Opens either those or plain text
- **automatic line numbers**: press Return and the next number is supplied,
  taking the midpoint when you insert between two existing lines
- **the syntax hint row**, on by default, showing the keyword you are
  working on; OA-/ turns it off for the extra text row
- **Applesoft keywords are drawn inverse**, all 98 of them, ignoring anything
  inside a string or after REM
- **Ctrl-R saves and runs**: the program is written out, BASIC.SYSTEM is
  loaded, and your program runs — and the next time the editor starts it opens
  that program again. See below
- **OA-Q quits straight to BASIC**, and `-ASIDE.SYSTEM` from the `]` prompt
  brings you back
- **OA-F finds and OA-G repeats**, both wrapping round the end of the program
- **OA-C, OA-X, OA-V** copy, cut and paste a line; **OA-L** goes to a line by
  its NUMBER, not the n'th line of the file
- **OA-left and OA-right** move by word
- **FOR bodies are indented** — derived from the nesting rather than stored,
  because Applesoft drops every space outside a string. Return indents as you
  type, and opening a program re-derives the lot
- **OA-R renumbers** to 10, 20, 30, and every GOTO, GOSUB, THEN and RUN
  follows its line. Refuses to run if any reference is already broken
- **OA-K checks line references**: every GOTO, GOSUB, THEN and RUN target,
  ignoring keywords inside strings and after REM
- English and any other language you write a `lang/<code>.txt` for

## The compiler

`ASIDECC.SYSTEM`, 28K, running on the //e. It reads a tokenised
Applesoft file and writes a binary you can `BRUN`.

```
]-ASIDECC.SYSTEM
COMPILE WHICH FILE? MYPROG
...
WROTE CMYPROG, 289
```

and then puts you back at the `]` prompt, because that is where you want to be
after compiling something.

Measured on the machine at 1MHz, the same five programs `make bench` uses:

| program | interpreted | compiled | speedup |
|---|---|---|---|
| the loop alone | 33.79s | 6.04s | 5.6× |
| 200 lines before the target | 66.73s | 6.03s | 11.1× |
| 30 variables before its two | 38.78s | 6.11s | 6.3× |
| both, as a real program is | 71.48s | 6.13s | 11.7× |

Every answer identical to the interpreter's. **The compiled times barely move
across the four** — a tenth of a second, against interpreted times from 33 to
71 seconds. That is the whole point: what differs between those programs is
Applesoft searching for a line and scanning for a variable, and compiling does
not reduce that work, it removes it.

Both sides are timed the same way, with the program already in memory. Timing
the compiled side as a `BRUN` charged it for loading its own file and made it
look several seconds slower than it is; `docs/compiler.md` has the correction.

It compiles the language real programs are written in: `LET` named and
implied, `GOTO`, `GOSUB`, `RETURN`, `POP`, `IF ... THEN` and `IF ... GOTO`,
`FOR`/`NEXT` with `STEP` and with several variables on one `NEXT`,
`ON ... GOTO` and `ON ... GOSUB`, `DATA`/`READ`/`RESTORE`, `INPUT`, `GET`,
`DEF FN`, `POKE`, `CALL`, `PRINT` with `;`, `,`, `TAB(` and `SPC(`, `REM`,
`END`, `STOP`, `CLEAR` and `RUN`.

**The screen and the ports:** `HOME`, `HTAB`, `VTAB`, `TEXT`, `INVERSE`,
`NORMAL`, `FLASH`, `SPEED=`, `PR#` and `LOMEM:`.

**Graphics:** `GR`, `COLOR=`, `PLOT`, `HLIN` and `VLIN`, and `HGR`, `HGR2`,
`HCOLOR=` and `HPLOT`, including `HPLOT TO` carrying on from the last point.

**Variables and arrays:** real and integer (`I%`) variables, arrays of one,
two or three dimensions, string arrays including two-dimensional ones, and
`DIM` with a size worked out while the program runs.

**Expressions** over `+ - * /` and `^`, unary minus, brackets, the six
comparisons — in either spelling, since Applesoft takes `=>` for `>=` —
`AND`/`OR`/`NOT`, `PEEK`, the eleven numeric functions
(`SGN INT ABS SQR RND LOG EXP COS SIN TAN ATN`), and `FRE`, `POS`, `PDL`
and `SCRN(`.

**Strings**, with a heap: assignment, all six comparisons, joining with `+`,
and `LEN`, `LEFT$`, `RIGHT$`, `MID$`, `ASC`, `CHR$`, `STR$` and `VAL`. A
string value is a descriptor — a length and a pointer — so assignment copies
three bytes rather than the text, exactly as Applesoft does, and a literal's
characters live in the compiled program. What is built while the program runs
comes off a heap descending from the top of free memory, with **a compacting
garbage collector** when it fills, so a program that builds strings in a loop
runs as far as the interpreter would.

**What it cannot compile it refuses by name and line number** rather than
compiling something that runs and gives a wrong answer:

```
STOPPED IN 30: STATEMENT NOT YET
STOPPED IN 20: STRING AGAINST NUMBER
STOPPED IN 70: NO SUCH LINE
```

The absences worth knowing about are `ONERR GOTO` and `RESUME`, integer
arrays (`A%(n)`), the shape-table statements (`DRAW`, `XDRAW`, `ROT=`,
`SCALE=`, `SHLOAD`), `HIMEM:`, `IN#`, `WAIT`, `TRACE`, `USR` and `&`, and
`GET` into an integer variable. `SAVE` is recognised and refused:
a bare `SAVE` writes the BASIC program to tape, and a compiled program has
none to write.

Every one of these is checked against the interpreter rather than against a
table of what Applesoft is supposed to do. `tests/cc.sh` runs 71 programs
twice on the machine — once interpreted, once compiled — and compares what
came out; `make cctest` is the whole suite.

A compiled program carries only the runtime it uses: one that never touches a
string is 128 bytes where it used to be 1,104.

`docs/compiler.md` has the design, what was established on the machine rather
than recalled, and the measurements.

## Short lines, now that there is a compiler

Open almost any Applesoft program written in the 1980s and you will find
statements packed onto one line with colons:

```
100 CR = FN S(X) - 0.6:ZR = 0:ZI = 0:N = 0
```

That was not laziness. It bought two things that mattered on the machine:

- **Speed.** Applesoft finds a line by walking the program from the beginning.
  Every `GOTO`, `GOSUB` and `THEN` pays for every line in front of its target,
  on every pass. Fewer lines, less walking.
- **Memory.** A numbered line costs five bytes of overhead before it holds
  anything — two for the link, two for the number, one terminator.

**The compiler removes the first of those completely.** Not reduces —
removes. From `make ccbench`, the same loop run three thousand times, with the
program around it changed and nothing else:

| the same loop… | Applesoft | compiled |
|---|---|---|
| on its own, at the top | 33.79s | 6.04s |
| with 200 lines in front of it | 66.73s | 6.03s |
| with 30 other variables first | 38.78s | 6.11s |
| with both | 71.48s | 6.13s |

The interpreted column doubles for a program doing not one sum more. **The
compiled column does not move**: 6.04, 6.03, 6.11, 6.13. A line number becomes
an address while it compiles, and the line table is gone by the time the
program runs. Searching is not made quicker; it stops happening.

The second cost is five bytes a line against 46K of program space — real, and
not worth a thought until you are near the end of the disk.

**So write one statement per line.** The editor is already built for it:
Return supplies the next number, inserting between two lines takes the
midpoint, and `OA-R` renumbers by ten and drags every `GOTO`, `GOSUB`, `THEN`
and `RUN` along with it. Nothing about the old habit is worth keeping for
code you are writing today.

Two limits worth knowing before you go too far the other way:

- **512 lines** is the compiler's table (`LTMAX`). The real programs used to
  test it run 27 to 80 lines, so unpacking one three or four times over is
  nowhere near it — but the ceiling is there.
- **`Ctrl-R` runs interpreted.** The penalty does not vanish, it moves to the
  edit-and-try loop, which is the part you repeat most. `OA-B` compiles
  instead when that starts to matter.

### The sample on the disk breaks this rule

`MANDELBROT` packs its statements with colons, and it is meant to. It was
written to fit twenty lines on one screen, so that the whole program could be
read at once and photographed in one piece. Unpacked it runs to about
twenty-six lines and overflows the screen it was built for.

Which is the actual rule, stated properly: **know what you are packing for.**
Old programs packed for speed and memory, and the compiler has answered the
first and made the second trivial. The sample packs to fit a screen, which no
compiler can help with — and is a perfectly good reason, as long as it is the
reason you actually have.

## Running what you have written

`Ctrl-R` saves the program, leaves the editor, and runs it. If the document has
no name yet it asks for one first, exactly as `OA-S` does.

The program ends at the `]` prompt. To get back:

```
]BYE
```

which lands in the ProDOS selector with `ASIDE.SYSTEM` at the top of the list —
so it is `BYE`, then Return. **The editor then opens the program you just ran**,
without being asked.

It manages that by leaving a note: a one-block file called `ASIDE.LAST`, beside
your program, naming it. The note is read and **deleted** on the next start, so
it only ever brings you back once — quit with `OA-Q`, or start the editor
fresh, and you get an empty document as usual. That file appearing on your disk
is the honest cost of the trick; nothing else would survive, because a program
runs in between and BASIC.SYSTEM is loaded over everything the editor had.

Two things have to be true for `Ctrl-R` to run anything:

- **`BASIC.SYSTEM` must be on the same disk.** Without it the editor still
  saves and still leaves, but lands in the selector instead.
- **The name must be a plain one** — fifteen characters at most and no `/`.
  BASIC.SYSTEM's start-up field holds no more than that. A longer name or a
  path is saved and says so rather than running the wrong thing.

### Making a disk that comes back to the editor

ProDOS launches the **first** `.SYSTEM` file in directory order, so put
`ASIDE.SYSTEM` on the disk before `BASIC.SYSTEM` and the disk boots into the
editor. That is also what makes `BYE` land on `ASIDE.SYSTEM` in the selector
rather than somewhere else. `make dist` builds exactly such a disk; for one of
your own:

```
tools/ac -pro140 MYDISK.po MYDISK
tools/ac -p MYDISK.po PRODOS SYS 0x2000 < prodos.bin
tools/ac -p MYDISK.po ASIDE.SYSTEM SYS 0x2000 < build/ASIDE.SYSTEM
tools/ac -p MYDISK.po BASIC.SYSTEM SYS 0x2000 < basic.system.bin
```

The order of those last three is the whole point.

## What does not yet

- the program does not come back by itself when it finishes; you press `BYE`
  and Return. Returning automatically would mean staying resident underneath
  BASIC, which is a much larger thing than this
- `OA-P` does not print
- `src/unbuilt.S` still holds the Markdown emphasis keys, which Applesoft has
  no notion of, and the wrap routines, which a BASIC editor must never have

## Requirements

Merlin32, AppleCommander and Virtual ][ on a Mac; `make tools` fetches the
first two. The target is a real Enhanced //e, so anything emulator-specific
belongs in the harness rather than in the editor.

## Licence

MIT. See [LICENSE](LICENSE).
