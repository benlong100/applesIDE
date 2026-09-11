# ApplesIDE

An Applesoft BASIC editor for the Enhanced Apple //e, written in 6502 assembly
and running under ProDOS 8.

**Very early.** It boots, opens an empty program, and lets you type and move
around. None of the things that would make it an Applesoft editor rather than
a text editor are built yet.

    make          assemble src/aside.S
    make disk     bootable ProDOS 8 image at build/APPLESIDE.po
    make run      build and boot it in Virtual ][
    make test     run the regression suite (73 assertions)
    make dist     an image to give away: adds BASIC.SYSTEM and a README
    make card VOL=NAME   copy the image to an SD card
    make tools    fetch the toolchain on a fresh clone

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
