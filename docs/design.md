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

## 7. Inverse reserved words

Applesoft's keywords are drawn inverse. `tools/gentokens.py` holds the token
table — `$80`–`$EA`, 107 entries — and emits `src/tokens.S`. Ninety-eight are
alphabetic and get highlighted; the nine single-character operators (`+ - * /
^ > = <` and `&`) are tokens too but are not reserved *words*, and inverting
them would make an expression look like a rash.

Generating the table rather than typing it is the point: ninety-eight `asc`
lines with hand-counted lengths is where a typo hides, and one wrong length
byte highlights half a word with nothing to say why.

**Matching at a position, not rolling.** `TKLINE` runs once per row on the
finished `LINEBUF`, not inside `RENDER`'s character loop. Ninety-eight
simultaneous candidates would be ninety-eight compares per character drawn and
a redraw touches seventeen hundred of them; instead the table is grouped by
first letter, so a cell that begins no keyword costs one lookup. After a match
the scan skips the whole keyword, so `PRINT` is not re-examined as `RINT`,
`INT`, `NT`, `T` — which is also what Applesoft does.

**Longest first**, which the generator arranges: `ATN` before `AT`, so `ATN(1)`
highlights as one word. Applesoft's own tokenizer finds `AT` first, because it
comes earlier in the token table, and carries a special case to recover.
Sorting differently gets the same answer without one.

**Strings and `REM`.** Whether a cell is inside a string cannot be decided from
the row alone — the quote may have opened off the left edge — so `RENDER`
records it per cell in `MASKBUF` as it walks the buffer, and the highlighter
reads it back. `REM` is handled in the highlighter, since everything after it
is literal.

**Lowercase is not matched.** Applesoft tokenizes uppercase only, so `print` is
a variable name to the machine, and drawing it as a keyword would be a lie.

### The bug real hardware found

The string state was recorded at the point a cell is **drawn** — and undrawn
characters never reach it. Scroll a long `PRINT` line and its opening quote
goes off the left edge, toggles nothing, and every keyword inside the string
lights up. Reported exactly that way from the machine: *"keywords within the
quotes don't highlight within the first 80 characters. After the screen
scrolls to the left, keywords within the quotes inverse."*

The state is now tracked for every character the walk sees, drawn or not, and
`RSTRC` carries the value that applies to the current cell — captured before
the toggle, because a quote belongs to the string it opens.

Nothing in the emulator would have caught this without deliberately scrolling a
string, which is the sort of case a person finds in a minute and a test suite
finds only if someone thought of it.

### The known limitation

On a **scrolled** row the leftmost character is mid-line and possibly
mid-*word*, and the rest of that word is off-screen where nothing can see it.
`PRINT` scrolled by sixteen columns shows as `INT`, which is itself a keyword
and was being highlighted as one. The partial word at the left edge is now
skipped, which loses a keyword that starts exactly at the edge — the right
trade, because a missing highlight is a smaller lie than a highlight over the
tail of a longer word.

### Two paths draw a row, and both had to learn

Found by looking at the screen, not the code:

1. **`RENDERROW`, the one-row fast path**, block-copies a line and never walks
   it, so it filled no `MASKBUF` and called no highlighter — the row being
   typed was the one row with no highlighting. It now derives the string state
   from `LINEBUF` itself, which is exact, since the copy starts at the line's
   first character. It also has **no notion of `HOFF`** and would repaint a
   scrolled row unscrolled, so a non-zero `HOFF` now forces the full redraw.
2. **The last line of the buffer has no break after it**, so it never reaches
   `RENDER`'s end-of-line case and is flushed at the exit instead. That path
   needed the keyword pass too — otherwise the final line of every program,
   which is usually the one being written, was the only one left plain.

## 8. Renumbering## 8. Renumbering

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

## 9. Syntax hints

`OA-/` shows a row carrying the syntax of the Applesoft keyword you are
working on. It is the row ZipEdit spent on a Markdown cheat sheet — already
wired up, already toggleable, already excluded from the text area's height.
Only the content is new.

**The LAST keyword before the cursor, not the one under it.** Typing `PRINT`
and then a space would lose a hint that only looked at the word being typed,
and that is exactly the moment it is wanted: the syntax is *for the
arguments*, and the arguments come after the keyword. So it stays up until
another keyword replaces it — `FOR I=1 TO 9` shows `FOR` while you type `I=1`,
then switches to `TO`.

Found by walking the line from its first character to the cursor. That sounds
expensive and is not: the line begins exactly `CCOL` bytes before the gap so
there is nothing to search for, an Applesoft line is 239 characters at the
most, and the same first-letter dispatch the highlighter uses means most
characters cost one table lookup. It runs once a keystroke, not once per
character drawn.

Strings and `REM` are honoured, so `PRINT "GOTO` keeps `PRINT`'s hint and
`REM GOSUB 10` keeps `REM`'s. Longest-match holds too: `ATN(1)` shows `ATN`.

The syntax strings live in `tools/gentokens.py` beside the keywords, one per
keyword, 2,440 bytes in all. For the many that take no arguments the string is
a short description instead — `HOME - clear the text screen` — because for
those the syntax alone would say nothing.

### It had to be drawn from two places

`REDRAW` called the old `DRAWCHEAT`, but `REDRAW` is the *full* redraw and
ordinary typing takes the one-row path. So the hint only ever changed on a
full redraw and otherwise showed whatever had been true when the row was
switched on. This is the second time a feature has had to learn that a row
reaches the screen by two different routes — see §7.

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

## 12. Known limits

**A line number above 65535 wraps.** The suite found this by accident: a
mis-counted test merged two lines into `10 GOTO 99920 END`, and `OA-K`
reported the target as `34384` — which is 99920 less 65536. `LNMUL10`
accumulates in sixteen bits and nothing checks the range.

It takes an invalid program to reach: Applesoft's ceiling is 63999 and it
would reject the line itself. But `OA-K` would report a number nobody typed,
and `RENUM` would map it wrongly, so it is a real gap rather than a
theoretical one. Fixing it means range-checking in `LNMUL10` and giving its
callers somewhere to put the failure; it is not done, and the binary has about
1.5K of the 16K budget left to do it in.

Worth noting how it turned up. The test was wrong, not the code — but a wrong
test still ran a program no deliberate test would have written, which is most
of the value of running one at all.

## 13. What is deliberately absent

`src/unbuilt.S` holds a stub for every handler the inherited keymaps still name
and this editor has not written. It is meant to shrink to nothing and then be
deleted. Two entries in it are not "not yet" but "no":

- **`WRAPCHECK`** — hard wrap, per §1. It should end up deleted, not written.
- **`KBOLD` / `KITALIC`** — Markdown emphasis. Applesoft has no such thing;
  they exist only because the shared keymaps still name them, and they go when
  the keymaps are rewritten.

`main.S` also lost 47 lines of deferred-reflow logic, which existed purely to
keep hard wrap cheap during a burst of typing.
