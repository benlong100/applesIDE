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

## 3. Line numbers are text, and the screen pins them

The buffer holds `10 HOME` exactly as the file does. Line numbers are not
metadata the editor owns; they are characters, the cursor can move into them,
and you can edit one by hand the way you always could in BASIC.

That was not the obvious choice, so here is why.

**References are text whatever you decide.** `GOTO 20` carries its operand
inside the line body, typed by the user. An editor that owned every line's
number as metadata would still need the same scanner over `GOTO`, `GOSUB`,
`THEN`, `ON…GOTO`, `RUN` and `LIST` — and would now hold *two* representations
of a line number that have to agree. Since §8 already chose `RENUM` over
symbolic identity, and `RENUM` rewrites numbers and references together as
text, owning the numbers separately buys very little and costs the thing this
editor is built on: a gap buffer holding plain text, where save and load are
trivially correct and what you see is what is in the file.

**But scrolling took something away.** Scroll out to column 100 and the line
number goes off the left edge, so you are editing a long line with no idea
which line it is. The status row shows `L:2`, and that is the ordinal, not the
BASIC line number.

So the number is **pinned on screen**: when `HOFF` is non-zero, `RENDER` draws
the leading digit run in its own columns and never scrolls it. This is a
display trick, not a data-model change. `RINNUM` tracks whether we are still
in the digit run, `RNUMW` counts how wide it is.

Two consequences had to be handled, and both were found by looking at the
screen rather than by reasoning:

- **The pinned number and the scrolled body together read as a line that does
  not exist.** `20 PRINT "THE QUICK...` looks like the whole of line 20 when
  sixteen characters have been skipped. A `>` in the cell between them says so.
- **The cursor could sit under the pinned number**, where the character it is
  on is not drawn — typing somewhere you cannot see. `HSCROLLFIX` treats the
  first `HPIN` (6) cells as unavailable and jumps the view home rather than let
  the cursor enter them. Six is five digits, Applesoft's ceiling being 63999,
  plus the marker.

Unscrolled, none of this is visible: no marker, no pinning, the line drawn
exactly as it is stored.

## 4. Automatic line numbers

Press Return and the editor supplies the next number. Because numbers are
ordinary text (§3), this is not a data-structure change: read the number off
the line just ended, work out the next one, type it.

**It fires only when the line just ended starts with a number.** Follow the
pattern that is there and nothing else — open a text file that is not a BASIC
program, press Return, and having `10 ` appear would be vandalism. Number the
first line yourself and every line after it is automatic.

**Which number.** Ten more than the line just ended, which is why everyone
numbered by tens: the gaps are where inserted lines go. If a numbered line
*follows*, ten more may already be taken, so it takes the midpoint instead —
Return between 20 and 30 gives 25. Between 20 and 21 there is no whole number
free, so it says `NO FREE LINE NUMBER HERE` and types nothing. The honest
answer there is that the program wants renumbering, and `RENUM` is §8 and not
built.

**Splitting a line** mid-way gets a number on the tail, deliberately: the tail
is about to be a line of its own and a BASIC line without a number is not a
line. It may be the wrong number, because the text after the cursor is the
rest of the split line rather than a following line, so nothing can be read
from it.

### Three bugs worth keeping written down

All three were found by looking at the machine, and none would have been
caught by reading the code again.

1. **`INSCHR` clobbers X.** It sets `MODFLAG` through `ldx #$01`, so a loop
   counter in X does not survive writing a digit — the emit loop restarted at
   index 1 and hung the editor outright. This is in ZipEdit's `CLAUDE.md`
   under "X cannot hold a loop counter across `INSCHR`", read earlier the same
   afternoon and walked into anyway. `LNPI` lives in memory.
2. **`LNFOLL` accumulates into `LNUM`** so it can share `LNMUL10`, and so
   destroys it. `AUTONUM` computed the candidate first and found zero
   afterwards, emitting line `0`. It asks about the following line *before*
   doing any arithmetic now.
3. **The first byte past the gap is a break, not the next line's digits.**
   The cursor sits on a new empty line and the break that ends it is what
   `GAPEND` points at, so `LNFOLL` read `$8D`, found no digits, and reported
   no following line — which turned an insert between 10 and 20 into a second
   line 20. It steps over exactly one break now; mid-line the first byte is
   ordinary text, nothing is skipped, and "no following number" is then the
   right answer.

## 5. The reference scanner

`OA-K` walks the program and reports the first `GOTO`, `GOSUB`, `THEN` or
`RUN` pointing at a line that is not there — a bug you would otherwise meet at
run time, half way through doing something.

It exists mainly because **it is the scan `RENUM` needs**. Finding a reference
and rewriting one differ only in what you do once you have found it, and the
finding is all of the difficulty. Building it with a consumer that is useful on
its own means it gets exercised properly before anything depends on it.

Two passes, because a `GOTO` may point forwards: pass one collects every
line's own number into a table at `$6000`, pass two walks again and looks each
reference up. The lookup is a linear scan — a few hundred lines against a few
dozen references is well under a second at 1MHz, and a binary search is an
optimisation to make when something is actually slow.

**The rules that make it worth writing**, all verified on the machine:

- a keyword inside a string is not a keyword — `PRINT "GOTO 999"` is text
- everything after `REM` is literal
- the number after `GOTO` may be a list — `ON X GOTO 10,20,30` is three
  references, and the third is checked
- a keyword need not be followed by a number at all: `THEN PRINT` and a bare
  `RUN` are both legal

### Not handled yet

- **`LIST`**, which takes a range with a hyphen rather than a plain number.
- **lowercase keywords.** Applesoft tokenizes uppercase only, so `goto 10` is
  not a `GOTO` to the machine either — but the editor ought to say so rather
  than silently agreeing.
- **`DATA`**, whose contents are literal in ways this does not model.

### Three bugs, and where they came from

1. **`(RFTP),y` needs a zero-page pointer.** The scratch block was at `$1200`,
   and indirect indexed addressing reaches nowhere but page zero. Merlin says
   so plainly — *"located outside of the Direct Page"* — but only after the
   whole listing has been written, and `make` reported nothing but a failure.
2. **The character `RFNUMBER` stopped on was saved three lines too late**, by
   which point `A` held `RFEOL`. `RFCH2` came out as 0, which is below
   `TEXTLO`, so every line's body looked like an immediate end of line: the
   scanner ran, found nothing, and reported all references OK. **A checker
   that never checks anything passes every test you give it**, which is why
   the first thing tried after it worked was a program known to be broken.
3. **`REM` ended the line logically but not in the buffer.** The walk
   restarted at the character after `REM` and read the comment as a fresh
   line, so `20 REM GOTO 888` reported a missing line 888. `RFEOL2` grew a
   third value meaning "run on to the real break first".

## 6. Tokenized files

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

## 7. The tokenizer will be the sharp edge

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

## 8. Renumbering

`OA-R` renumbers the program to 10, 20, 30 and carries every reference with it.
This is the thing the project was asked for: *"when lines are added to the
code, the GOTO statement would automatically update to the new line number."*

**It refuses to run on a broken program.** `OA-K`'s check goes first, and if
any reference points at a line that is not there, `RENUM` says so and changes
nothing. That is not tidiness. Renumbering around a dangling `GOTO 999` would
leave the 999 untouched while every real line moved — and 999 might now *be* a
line, so a reference that was visibly broken becomes a jump to somewhere
arbitrary. A visible bug is worth more than a hidden one.

**How it moves.** The gap buffer makes an edit cheap at the cursor and
expensive anywhere else, so the pass works strictly left to right and the gap
only ever moves forwards — one walk of the document, not one per line. At each
number the old digits are removed with `DELFWD`, which does not move the
cursor, and the new ones inserted at it. The replacement therefore lands
exactly where the original was and the lengths need not match, which is what
makes `1` → `10` and `500` → `40` equally safe.

**No second table.** A line's position in `RFTAB` *is* its position in the
program, and the line in position *n* is about to be numbered *(n+1)×10*. So
mapping an old reference to a new one needs nothing the check did not already
build.

**There is no undo**, and the file on disk is untouched until you save — so the
remedy for a renumber you did not want is to not save.

Verified on the machine: `100/200/300/500` with `GOSUB 500` and `THEN 100`
became `10/20/30/40` with `GOSUB 40` and `THEN 10`; `1/2/3/4` grew to
`10/20/30/40` with `ON X GOTO 1,2,3` becoming `ON X GOTO 10,20,30`, while
`REM GOTO 999` and `PRINT "GOTO 3"` kept their numbers; and a program with a
dangling reference was reported and left alone.

`OA-R` took the slot that was reflow, which a program has no use for.

## 9. Where the syntax hints go

ZipEdit spends one screen row on a Markdown cheat sheet, toggled with `OA-/`.
That row is already wired up, already toggleable, and already excluded from the
text area's height. It is where the syntax of the keyword under the cursor
belongs. Nothing new is needed but content.

## 10. The AI window — deferred, deliberately

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

## 11. The name

ProDOS truncates a filename at fifteen characters. `APPLESIDE.SYSTEM` is
sixteen — it would land as `APPLESIDE.SYSTE`, stop looking like a `.SYSTEM`
file, and never auto-launch. Hence **`ASIDE.SYSTEM`**, which also reads as a
word. The volume is `/APPLESIDE/`, where fifteen characters is plenty.

## 12. What is deliberately absent

`src/unbuilt.S` holds a stub for every handler the inherited keymaps still name
and this editor has not written. It is meant to shrink to nothing and then be
deleted. Two entries in it are not "not yet" but "no":

- **`WRAPCHECK`** — hard wrap, per §1. It should end up deleted, not written.
- **`KBOLD` / `KITALIC`** — Markdown emphasis. Applesoft has no such thing;
  they exist only because the shared keymaps still name them, and they go when
  the keymaps are rewritten.

`main.S` also lost 47 lines of deferred-reflow logic, which existed purely to
keep hard wrap cheap during a burst of typing.
