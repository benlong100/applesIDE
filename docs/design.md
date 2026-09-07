# ApplesIDE — design

An Applesoft BASIC editor for the Apple //e, written in 6502 assembly. It is
ZipEdit's engine with a different front end, and the differences are the
interesting part of this document.

The idea came from a user of ZipEdit, who asked for "a modern Applesoft IDE —
first component is a proper editor, like ZipEdit is now, but with automatic
line number generation and inverse reserved words."

## 1. Why this is a separate program

ZipEdit is a prose editor whose founding decision is **hard wrap on entry**:
typing past column 76 breaks the line at the last space, the newline is a real
byte in the buffer, and so one logical line is always one screen row. That is
safe in Markdown, where a single newline inside a paragraph renders as a space.

**Breaking an Applesoft line changes the program.** So the one decision ZipEdit
is built around is the one decision this editor must not make.

Almost everything below the keymap survives the move: the gap buffer, both
screen drivers, both memory drivers, ProDOS file I/O, the prompt and help
machinery, the localisation pipeline, and the `geom` record that keeps column
numbers out of the code. `src/aside.S` is a `put` list, the same way ZipEdit's
three builds are.

## 2. Long lines: scroll, don't wrap

An Applesoft line can be 239 characters and routinely is, once statements are
packed with colons.

The first instinct was soft wrap — flowing a long line onto continuation rows.
That is the right answer for prose and the wrong one here, for a reason that
has nothing to do with difficulty: **row-equals-line is what the rest of the
design rests on.** The line number in the gutter, the `+`/`−` version markers,
and cursor-up meaning "the previous program line" all assume one row is one
line. Soft wrap breaks all three at once.

So ApplesIDE keeps ZipEdit's invariant by the opposite means. It never breaks a
line, and **scrolls sideways** when the cursor passes the right edge. That is a
horizontal offset in the renderer; the line model, the scroll model and the
cursor arithmetic are untouched.

Soft wrap remains on *ZipEdit's* wishlist, where it belongs.

**Status: built.** `HOFF` is the logical column drawn in screen cell 0.
`RENDER` puts a character in cell `CURCOL - HOFF` and skips it if that falls
outside the screen; `HSCROLLFIX` in `scroll.S` is the horizontal twin of
`SCROLLFIX` and slides `HOFF` to keep the cursor in view.

**It jumps in steps of `HSTEP` (16) rather than tracking column by column.**
Two reasons, and the second is the one that matters:

- A horizontal scroll shifts every row, so it costs a full `RENDER`. Tracking
  by single columns would pay that on *every keystroke* past the margin;
  jumping pays it once every sixteen characters.
- It lands the cursor well inside the screen rather than pinned against the
  edge, so you can see what you are typing towards.

Two limits, both deliberate and both documented at the code:

- `CURCOL` is one byte and **saturates rather than wrapping**. An Applesoft
  line is 239 characters at most, so this is only reachable by a line longer
  than the language allows — and saturating misrenders from column 255 on,
  where wrapping would send characters back to the left margin and look like
  buffer corruption. Enforcing the 239-character limit is a real feature and
  is not built.
- `HOFF` is one byte and saturates at 255 for the same reason. `HSCROLLFIX`
  stops looping when it does, or it would spin.

Verified on the emulator: a 104-character line scrolls to `HOFF` 32 — the
first multiple of 16 that keeps the cursor on screen — `Ctrl-A` brings it home
and `Ctrl-E` sends it back out, an insert twelve characters back from the
cursor lands in the right place while scrolled, and moving up to a short line
brings the view home on its own.

## 3. Tokenized files

An Applesoft program on disk is normally ProDOS file type `$FC`: a dump of
memory from `$801`, structured as a linked list of lines, each one two bytes of
next-line pointer, two bytes of line number, tokenized content, and a zero
terminator. Keywords are single bytes `$80`–`$EA`.

Reading that format is worth the work for three reasons:

1. It is the only way to open programs that already exist.
2. **The file format hands over the line structure.** Line numbers arrive as
   integers rather than as text to be parsed.
3. The token table needed to detokenize is the same table the inverse-keyword
   display and the reference scanner need. One table, three jobs.

Plain-text import and export comes afterwards, for moving code to the Mac.

## 4. The tokenizer will be the sharp edge

Applesoft matches keywords **greedily against a table, in table order**, and the
table is not sorted helpfully. `AT` is `$C5`; `ATN` is `$E1`. A naive matcher
reads `ATN(1)` as `AT` followed by `N(1)`. Applesoft itself carries a special
case for exactly this, and for the `A TO` / `AT O` ambiguity.

A highlighter that does not reproduce the real tokenizer is worse than none,
because the entire point is showing what the machine will see. Three more rules
that are easy to miss:

- keywords inside a string literal are not keywords
- everything after `REM` is literal
- `DATA` has its own quoting rules

## 5. Renumbering

The request was that `GOTO` targets follow their lines automatically. Two ways:

**Symbolic references.** A `GOTO` points at a line's identity, and real numbers
are generated only on save. Impossible to get wrong; replaces the flat-text gap
buffer with something structured.

**Gapped numbering plus a real `RENUM`.** Number by tens, use the gaps on
insert, and renumber — rewriting every reference — only when a gap runs out.
This is what every BASIC toolchain has done, and it gets essentially all of
what was asked for at a fraction of the cost. **Chosen.**

Either way the essential piece is the same, and it is where the actual work is:
a scanner that finds every line-number reference — `GOTO`, `GOSUB`, `THEN`,
`ON…GOTO`, `ON…GOSUB`, `RUN`, `LIST`.

## 6. Where the syntax hints go

ZipEdit spends one screen row on a Markdown cheat sheet, toggled with `OA-/`.
That row is already wired up, already toggleable, and already excluded from the
text area's height. It is where the syntax of the keyword under the cursor
belongs. Nothing new is needed but content.

## 7. The AI window — deferred, deliberately

The original request ended with an AI panel talking to OpenAI over Uthernet or
FujiNet. The hardware reading in it is correct: Uthernet II is a W5100 with a
hardware TCP stack and **no TLS**, so it really is plain HTTP to something
self-hosted on the LAN; FujiNet terminates TLS on the ESP32 and so can reach
public APIs.

The hard part is not the network. It is JSON on a 6502, and context size —
encoding several KB with escaped strings, parsing a response of similar size,
with buffers for both alongside the program.

It is deferred because it is the only component that does nothing when the
machine is offline, and because letting it shape the editor's design would be
the wrong trade. It is not ruled out.

## 8. The name

ProDOS truncates a filename at fifteen characters. `APPLESIDE.SYSTEM` is
sixteen — it would land as `APPLESIDE.SYSTE`, stop looking like a `.SYSTEM`
file, and never auto-launch. Hence **`ASIDE.SYSTEM`**, which also reads as a
word. The volume is `/APPLESIDE/`, where fifteen characters is plenty.

## 9. What is deliberately absent

`src/unbuilt.S` holds a stub for every handler the inherited keymaps still name
and this editor has not written. It is meant to shrink to nothing and then be
deleted. Two entries in it are not "not yet" but "no":

- **`WRAPCHECK`** — hard wrap, per §1. It should end up deleted, not written.
- **`KBOLD` / `KITALIC`** — Markdown emphasis. Applesoft has no such thing;
  they exist only because the shared keymaps still name them, and they go when
  the keymaps are rewritten.

`main.S` also lost 47 lines of deferred-reflow logic, which existed purely to
keep hard wrap cheap during a burst of typing.
