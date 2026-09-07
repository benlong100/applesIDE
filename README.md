# ApplesIDE

An Applesoft BASIC editor for the Enhanced Apple //e, written in 6502 assembly
and running under ProDOS 8.

**Very early.** It boots, opens an empty program, and lets you type and move
around. None of the things that would make it an Applesoft editor rather than
a text editor are built yet.

    make          assemble src/aside.S
    make disk     bootable ProDOS 8 image at build/APPLESIDE.po
    make run      build and boot it in Virtual ][
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
- **automatic line numbers**: press Return and the next number is supplied,
  taking the midpoint when you insert between two existing lines
- **OA-R renumbers** to 10, 20, 30, and every GOTO, GOSUB, THEN and RUN
  follows its line. Refuses to run if any reference is already broken
- **OA-K checks line references**: every GOTO, GOSUB, THEN and RUN target,
  ignoring keywords inside strings and after REM
- English and any other language you write a `lang/<code>.txt` for

## What does not yet

- no keyword display, no syntax hints
- no Applesoft file support — nothing reads or writes tokenized `$FC` files
- find, clipboard and go-to-line are stubs in `src/unbuilt.S`

## Requirements

Merlin32, AppleCommander and Virtual ][ on a Mac; `make tools` fetches the
first two. The target is a real Enhanced //e, so anything emulator-specific
belongs in the harness rather than in the editor.

## Licence

MIT. See [LICENSE](LICENSE).
