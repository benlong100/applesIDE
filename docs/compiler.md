# The compiler — as decided, and what has been established

A separate program on the same disk, so the editor stays what it is for
somebody who only wants an editor. Native: it runs on the //e rather than on
the Mac.

## Why a compiler and not something smaller

`make bench` measured it. On a realistically shaped program, 53% of the
running time is Applesoft looking up addresses — 46% walking the program from
the start to find a `GOTO`'s target, 7% scanning the variable table by name.
`bench/README.md` has the numbers.

I first proposed a much smaller program that would resolve line-number
references to addresses and leave everything else alone. **That is not
possible**, and the tokenised file says so plainly. Here is `IF I < 3000 THEN
GOTO 30`:

```
AD 49 D1 33 30 30 30 C4 AB 33 30
IF  I  <  "3 0 0 0"  THEN GOTO "3 0"
```

The branch target is **ASCII digits**. Applesoft parses them at run time and
then searches. There is nowhere in the format to put an address and the parser
expects digits, so no rewriting of the file can resolve a branch. Resolving
addresses means either patching the interpreter or generating code. The claim
that there was a cheap version of this was wrong, and it was wrong before any
code was written, which is the only good time.

## The shape

**File to file, streaming.** The compiler reads the tokenised source a line at
a time and writes output as it goes. Holding the whole program in memory would
put the compiler, its input and its output in the same 48K, and only toy
programs would fit.

**Emit 6502 that calls the ROM for arithmetic.** Applesoft's floating point is
not worth rewriting and would not be faster. What compiling wins is everything
around it: branch targets resolved, variables at fixed addresses, constants
converted once, no per-statement dispatch.

## The first milestone

Enough to compile the benchmark: scalar FP variables, `LET`, `+ - * /`,
comparisons, `IF/THEN <line>`, `GOTO`, `GOSUB`/`RETURN`, `FOR`/`NEXT`,
`PRINT`, `END`.

That makes **`make bench` the acceptance test**: the same five programs, the
same answers, and a measured speedup rather than a claimed one. Arrays,
strings and `DATA`/`READ` come after.

## Established on the machine, not recalled

Everything here was read off a running //e rather than remembered, because the
ROM interface is exactly where a wrong assumption would be expensive.

### The variable table and the float format

A probe that printed the bytes at `VARTAB` after `A = 2.5 : B = 1 : C = -1`:

```
65  0 | 130  32   0   0   0     A = 2.5
66  0 | 129   0   0   0   0     B = 1
67  0 | 129 128   0   0   0     C = -1
```

The first entry reading `65 0` — the name `A` — is what confirms both that
`VARTAB` is at `$69/$6A` and that an entry is two name bytes followed by five
of value. A probe that cannot check its own premise is not worth running.

**The float is five bytes**: an exponent biased by 129, then four fraction
bytes, with the **sign in bit 7 of the first fraction byte** and a leading 1
implied rather than stored. An exponent of zero is the value zero.

Checking it: 2.5 is 1.25 × 2¹, so the exponent is 130 and the fraction `.01`
becomes `$20` once bit 7 is given to the sign. `1` is 1.0 × 2⁰ — exponent 129,
fraction empty. `-1` is the same with bit 7 set. All three agree.

**An earlier probe of this got nothing**, and the reason is worth keeping: it
read `$9D` expecting the FP accumulator to still hold 2.5, but the `FOR` loop
and the `PEEK` that did the reading are themselves floating-point evaluations
and had overwritten it. The variable table holds still; the accumulator does
not.

### The floating-point accumulator

Read through `USR`, which hands a value to machine code with the accumulator
still holding it — no chance for anything to overwrite it in between, which is
what spoiled the first attempt.

`USR(2.5)` then `USR(-2.5)`, copying `$9D` onward out to be printed:

```
POS 130 160 0 0 0 0
NEG 130 160 0 0 0 255
```

**The accumulator is not the packed format.** `$9E` reads `160` where the
packed variable held `32` — the same value with bit 7 set, because the
accumulator stores the mantissa's leading 1 explicitly and keeps the sign in a
byte of its own at `$A2`, zero for positive and `255` for negative. The
mantissa is identical between the two readings; only `$A2` moves.

So: **exponent `$9D`, mantissa `$9E-$A1` with an explicit leading 1, sign
`$A2`.** Assuming the accumulator and the packed form were the same layout
would have produced numbers wrong by a factor of two and a sign.

### The ROM entry points, each confirmed

| address | what it does | confirmed by |
|---|---|---|
| `$EAF9` | FAC ← packed at (A lo, Y hi) | loading 4.0 and packing it back |
| `$EB2B` | packed at (X lo, Y hi) ← FAC | 2.5 arriving as `130 32 0 0 0` |
| `$E7BE` | FAC ← FAC + memory | 2.5 + 1 giving `130 96 0 0 0`, which is 3.5 |
| `$E7A7` | FAC ← **memory − FAC** | 4 in FAC, 2 in memory, result −2 |
| `$E97F` | FAC ← FAC × memory | 4 × 2 giving 8 |
| `$EA66` | FAC ← **memory ÷ FAC** | 4 in FAC, 2 in memory, result 0.5 |
| `$EBB2` | compare FAC with memory, answer in A | 1 greater, 255 less, 0 equal |
| `$ED34` | FAC → string at `$0100` | `USR(2.5)` printing `2.5` unaided |
| `$FDED` | put one character on the screen | the same |

The pack test is conclusive rather than suggestive because the packed byte
(`32`) differs from the accumulator's (`160`): a routine that merely copied
would have left `160` there.

**SUBTRACT AND DIVIDE TAKE THEIR OPERANDS THE OTHER WAY ROUND.** Not
`FAC - memory` but `memory - FAC`. The probe was built to show this — 4 and 2
chosen because −2 and 2 are different answers, where 2 and 2 would have hidden
it. Had they been assumed, every subtraction and division in every compiled
program would have come out backwards, and the benchmark would still have
printed a plausible number.

So the code generator's rule for `A - B` and `A / B` is: **evaluate the RIGHT
operand into FAC, then apply the operation naming the LEFT one's address.**
For `+` and `×` the order does not matter.

The comparison was tested three ways — greater, less and equal — because two
of the three would have left the convention ambiguous. Each case reloads the
accumulator first rather than assuming the compare leaves it alone; that
assumption is the sort that surfaces as a wrong answer three bugs later.

### Turning a decimal constant into a float

The compiler runs on the //e, so it has to convert `3000` in the source into
five packed bytes itself. There is a ROM routine for reading a number out of
program text, but it works through the interpreter's own text pointer and
would be **another unverified dependency** — and it is not needed, because the
routines above are already enough:

    value = 0; for each digit: value = value × 10 + digit

which is `$E97F` against a packed ten and `$E7BE` against a packed digit.
Eleven constants — ten digits and a ten — computed once and built into the
compiler. Nothing new to establish, and the arithmetic is the machine's own,
so a compiled constant is bit-for-bit what Applesoft would have produced.

### What is now known

Everything the first milestone needs: load, store, four operations, compare,
and printing a number. Every one of them confirmed on a running machine, and
two of them — subtract and divide — are the opposite way round from the
obvious guess.

## The model, proved before building the thing that produces it

`src/cc/emit.py` is a small 6502 emitter and BENCH1 compiled through it by
hand. **It is not the compiler.** It is the compiler's intended output,
produced on the Mac so the shape of the generated code could be run on the
machine before anything was written to generate it. If the output were not
faster, nothing built on top of it would have been either.

```
]BRUN CBENCH1
4501500
```

**7.25s, against 33.79s interpreted.** The same answer, which matters as much
as the time — `4501500` is what the interpreter printed too.

- **4.7× on the same program.**
- **9.9× against BENCH4**, the realistically shaped one at 71.52s, because the
  compiled form has no line to search for and no variable table to scan.

That is far better than the 2.1× the benchmark predicted, and the reason is
that 2.1× was only ever the win from resolving addresses. Compiling also
removes the per-statement dispatch, the re-parsing of `3000` on every pass,
and the token walking.

**It has reached the floor.** One statement was measured at 2.29ms, mostly the
ROM's floating point; three thousand iterations of about three floating-point
operations is around 7.2 seconds, which is what it took. The compiled code is
now almost entirely arithmetic, and the interpretation overhead is not reduced
but gone. Beating this would mean replacing Applesoft's floating point, which
is a different project and probably a slower one.

### What this does and does not settle

It settles the **code generation model**: ROM calls with variables and
constants at fixed addresses, branches resolved, is correct and fast. The
generated code is the shape the native compiler must produce.

It does not settle the compiler. Reading tokenised source on the machine,
allocating variables, converting constants and emitting this automatically is
the work that remains — but it is now engineering against a known target
rather than a bet.

### Still to establish

Nothing, for the milestone. The next work is the compiler itself.

## The compiler, built

`src/cc/` — `ASIDECC.SYSTEM`, about 5.3K, running on the //e. It reads a
tokenised Applesoft file and writes a BRUNnable binary.

```
]-ASIDECC.SYSTEM
COMPILE WHICH FILE? BENCH1
...
WROTE CBENCH1, 289
```

and then drops into BASIC rather than the file selector, because what you want
after compiling something is the `]` prompt to run it from.

### Three passes, and why not two

1. **Pass 1** — every line number, every variable, every constant, every
   `FOR`. At the end the data area's size is known, so every variable and
   constant has a fixed address.
2. **Pass 2** — generate code with the output thrown away, recording where
   each line begins.
3. **Pass 3** — generate it again for real, resolving branches from the table
   pass 2 built.

Two passes look sufficient until you ask what the address of a forward `GOTO`
is. Sizes do not depend on branch targets — a `JMP` is three bytes whatever it
jumps to — so pass 2 can record every line's address before any target is
known. Passes 2 and 3 are the same code with writing switched off, which is
how every two-pass assembler has worked since before this machine existed.

### What the compiled program looks like

```
$6000  JMP CODESTART      so BRUN enters at the front and still finds it
$6003  the variables      five bytes each, zero as loaded
       the constants      five bytes each, converted in pass 1
       eight temporaries  for the middle of an expression
       two slots per FOR  its limit and its step
       one byte           the stack pointer as the program was entered
CODESTART
       TSX / STX          so END can get back to BASIC from inside a GOSUB
       the code
```

Data first because pass 1 can size it and cannot size the code.

### The measurement, at 1MHz

`make ccbench` compiles all five benchmark programs on the machine and times
each one interpreted and then compiled, in the same session on the same disk.

| program | interpreted | compiled | speedup | answer |
|---|---|---|---|---|
| BENCH1 | 33.72s | 6.00s | 5.6× | 4501500 |
| BENCH2 | 66.73s | 6.10s | 10.9× | 4501500 |
| BENCH3 | 38.82s | 6.05s | 6.4× | 4501500 |
| BENCH4 | 71.53s | 6.15s | 11.6× | 4501500 |
| BENCH5 | 26.80s | 4.41s | 6.1× | 3000 |

Re-measured after the DIM fix and after the benchmark was made to use the
compiler it had just built rather than the one on the distribution disk. The
figures moved by hundredths, which is the answer to the question worth asking
of a harness fault: it had been measuring a compiler one commit old, not one
generation old, so the numbers it gave were near enough to be believed and
near enough to be right. They were still not measurements of the thing they
named.

Every answer is the interpreter's own.

**The compiled times barely move across the first four** — 6.00 to 6.15, a
spread of fifteen hundredths of a second across programs whose interpreted
times run from 33 to 71 seconds. That is the whole claim made visible: what differs between
them is the line search and the variable scan, and compiling does not reduce
that work, it removes it. BENCH4 is the realistically shaped one and gains
most.

### These numbers were wrong until they were measured properly

Every compiled figure reported before this was several seconds too slow, and
the fault was in the harness rather than the compiler.

The two sides were not timed the same way. The interpreted run had its `LOAD`
done before the clock started, so only the running was measured. The compiled
run was timed as a `BRUN` — which loads **and** runs — so the compiler was
charged for reading its own file off the disk and the interpreter was not.

What settled it: a compiled program whose entire body is `PRINT "ENDTINY"`
takes **3.35 seconds**, essentially all of it loading. That was the constant
being added to one side of every comparison.

It surfaced as a 7% "regression" after the string runtime went in. Nothing in
the arithmetic path had changed; the binary had grown from about 300 bytes to
about 1,100 as the runtime went in, and the extra load time showed up as
slower execution. Treating that as noise would have buried the real fault.

Both sides now load before the clock starts: `BLOAD` and then `CALL 24576`.

**And the precision.** The screen is polled to spot the end marker and a poll
costs 0.119s, measured. That is the granularity: nothing against an
interpreted run of half a minute, and worth stating against a compiled one of
six seconds. Two decimal places is more than these carry.

### A program carries only the runtime it uses

| | before | after |
|---|---|---|
| a program whose whole body is one `PRINT` | 1,104 | **128** |
| BENCH1 | ~1,200 | **266** |
| BENCH4 | — | 836 |
| the join test, which uses everything | — | 2,024 |

**Pass 2 already knew.** It generates every line before it emits a single
helper, so a bit set at each call site is complete by the time the helpers go
down — and pass 3 sets the same bits from the same source and emits the same
set, so the addresses pass 2 recorded still land where pass 3 puts them. No
extra pass and no analysis: the information was already there in the right
order.

**And it confirmed the timing fix.** Taking about 900 bytes out of every
binary moved the measured times by around a tenth of a second — which is the
granularity, so: by nothing. That is what should happen once loading is
outside the timer, and before the fix the same change would have shown up as a
large false speedup.

The dependencies are recorded rather than assumed. The heap and the collector
come in with any of the four operations that allocate; the three substring
functions share an ending, so they come in together; `ASC` allocates nothing
and stays out of that group.

### The fourth fall-through, and a way to stop making them

The flag has to sit **on** the label, not above it. I put two of them above —
`:pstr`, reached by a `bne`, and `:isleft`, reached by a `beq` — so printing a
string never recorded that it needed the print helper, and `LEFT$` never
recorded that it needed the slicing ones. The compiler then emitted `JSR` to
routines it had decided not to include, and the program ran off into unwritten
memory. The emulator sat in the monitor at `6048- 00 BRK`.

That is the fourth bug of this shape in the compiler's history, all of them
code placed by physical position where control arrives by a branch:

- a trampoline written under its own branch, so every `LEFT$` compiled as
  `MID$`
- a routine's failure exit dropped into a fall-through path, so every `LEFT$`
  returned failure with nothing to report
- the pass 1 string report placed above the label its own loop jumps to, so it
  never ran
- and this one

**The shape is mechanical enough to check for mechanically.** After fixing
both, grepping for any remaining `jsr NEED` immediately followed by a label
found none — which is the check that should have come before the first run,
not after it.

What did work: a missed flag was named in advance as silent in the compiler
and fatal in the output, so the crash pointed straight at the cause instead of
starting an investigation. And a program that dies in the monitor says
*jumped somewhere impossible*, which is a better diagnosis than a wrong
number.

### Correctness, against the interpreter rather than against a table

`make cctest` runs every program in `tests/cc` twice — `RUN`, then compiled
and `BRUN` — and compares the screens. The interpreter is the specification. A
hand-written table of expected output would only record what was believed at
the time.

Three programs agree: arithmetic including the reversed-operand subtract and
divide, all six comparisons with `GOSUB` and `GOTO`, and loops with negative
steps, nesting, a named `NEXT`, an expression limit, and the case where
Applesoft runs a loop body once even though the start is already past the
limit.

### The functions, and what the interpreter had to correct

`SGN INT ABS SQR RND LOG EXP COS SIN TAN ATN` — each one a single ROM call
once the argument is in the accumulator. Every address was confirmed by
pointing Applesoft's own `USR` vector straight at it and printing what came
back: `SGN(-4)` is −1, `SQR(9)` is 3, `ATN(1)` is `.785398163`. Nothing from
memory, which is the rule here — two of the arithmetic routines this compiler
already depends on take their operands the opposite way round from the obvious
guess.

`AND`, `OR` and `NOT` came with a correction. **I had them down as bitwise on
sixteen-bit integers**, wrote that in a comment, implemented it with the
integer-conversion routines, and `tests/cc/logic` reported that the
interpreter disagreed: `3 AND 5` is 1 and not 7, `NOT 0` is 1 and not −1, `NOT
NOT 5` is 1 and not 5. They are **logical**, giving 1 or 0. The test on the
accumulator's exponent that replaced it is smaller, needs no integer
conversion, and cannot raise `ILLEGAL QUANTITY` on an operand too big to be
one.

Being confidently wrong about that in a comment is exactly how it would have
survived to the next person reading the file.

### Two bugs the new code brought with it

**A function's address did not survive its own argument.** `EMJSR` emits a
call to whatever is in `ROMA`, and generating the argument emits loads and
adds, every one of which sets `ROMA` on its way through. `INT(2.7)` compiled
into a call to `MOVFM` and printed `2.7`.

**String literals were patched in place after the fact**, reaching back into
the 256-byte output window to fill in the jump over the text. That worked
until programs grew enough for a string to straddle a window boundary — and
then programs that had compiled the week before stopped. The literal is now
collected into a buffer first, so its length is known before anything is
emitted and there is nothing to patch. That removes the coupling between a
string literal and the size of the write buffer, rather than making the buffer
bigger, which would only have moved the boundary.

### Arrays

`DIM A(20)`, `A(I)`, `A(I) = x`. One dimension; `DIM A(3,4)` is refused.

`DIM A(20)` is twenty-**one** elements, 0 to 20, which is the machine's rule
rather than a spare one added for safety. An array used without a `DIM` gets
eleven, as Applesoft gives it, and a `DIM` anywhere in the program replaces
that — which took a fix, because a bare use later in the text was overwriting
the size the `DIM` had set and `DIM A(20)` came out as eleven again.

`A` and `A(` are **different variables** to Applesoft — a program can use both
at once and they do not share a value — so they live in different tables here
for the same reason.

**The one piece of runtime a compiled program has.** An element's address is
`base + 5 × index`, and that is forty-five bytes emitted inline against
thirteen through a subroutine. A `PRINT` happens a handful of times in a
program and a subscript happens everywhere, so the float printer and the
string printer stay inline and this does not:

```
JSR AYINT              the subscript, as an integer
LDA #<base / LDY #>base
JSR ARRADDR            leaves the element's address in A and Y
JSR MOVFM              which is exactly what MOVFM wants
```

`ARRADDR` is forty-eight bytes with no branches and nothing absolute but the
zero page, so the layout can drop it wherever it likes without a fixup. Its
scratch is `$1A-$1F` — the hires routines' bytes, which a compiled program
never calls, clear of the floating point at `$9D-$A5`, of `COUT` at
`$24-$29`, and of the MLI at `$40-$4F`.

Assigning to an element works out the address **first** and keeps it, because
evaluating the right-hand side runs the whole expression machinery over the
accumulator and the helper's zero page with it.

**No bounds check, and that is a real difference from the interpreter.**
Applesoft raises `?BAD SUBSCRIPT ERROR`; a compiled program writes wherever
the arithmetic points, which for a subscript past the end is the program's own
code. Every correct program is unaffected, and an incorrect one is diagnosed
by running it interpreted first — which is what `make cctest` does anyway. The
fix, when it comes, is a count stored in front of each array and a test in
`ARRADDR`; it is not done yet because the helper would then need an error exit
and stop being the position-independent blob that makes it free to place.

### ON ... GOTO, and the comma in a PRINT

`ON X GOTO 100,200,300` is one-based, and anything outside the list falls
through to whatever follows on the line — which is what Applesoft does rather
than an error. **The targets are collected before anything is emitted**, so the
size of the jump table, and therefore how far the three out-of-range branches
have to reach, is known when they are written. Emitting a jump over a table
whose length is not yet known is the patching scheme string literals had to be
rescued from; once was enough.

Pass 1 needed a fix for it: `ON X GOTO 10,20,30` is three branch targets, and
it was treating only the first as one. The other two became constants —
harmless in themselves, but they take room in a table a large program can run
out of, and they say the program contains numbers it does not.

`ON ... GOSUB` is refused by name. It needs a return address pushed before an
indirect jump, which is a small thunk rather than a variation.

**The comma in a `PRINT` was read off the screen, not recalled.** Applesoft's
stops are every sixteen columns; from column 23 at a width of 40 it tabs to
32, and from column 24 it starts a new line instead:

```
PRINT "01234567890123456789012","*"     -> * at column 32
PRINT "012345678901234567890123","*"    -> * on the next line
```

That 24 is not a magic number: it is *is there room for a whole sixteen-wide
field*, so the emitted code compares the column plus sixteen against the
**window width** and follows a program that changes it. A comma also
suppresses the trailing newline when it ends the statement, as a semicolon
does.

### Strings, as far as they go without a heap

`A$`, literals, `A$ = B$`, `A$ = "text"`, `PRINT` of strings mixed with
numbers, all six comparisons, and `LEN`.

**A string value is a descriptor** — one byte of length and two of pointer,
which is what Applesoft uses. Assignment copies the three bytes rather than
the text, so `A$ = B$` leaves both pointing at the same characters; again what
Applesoft does. A literal's characters are emitted into the compiled program
and the descriptor points at them.

**Nothing is allocated**, and that is what makes this a self-contained piece
of work rather than a research project. None of Applesoft's heap is touched —
no `FRETOP`, no `STREND`, no garbage collector, and no need to set up the
interpreter's zero page as though it were running. Joining two strings, and
`CHR$` and `LEFT$` and the rest, all have to **make** a string: somewhere to
put it and something to reclaim it. That is the next piece and it is a real
one; until then each is refused by name.

**The end of a line closes a literal.** `PRINT "----------` with no second
quote is ordinary Applesoft: the string runs to the end of the line, and
leaving the quote off saves the byte. The Beagle Bros listings use it freely —
CHR\$ POKER ends line 30 on one — and the compiler used to answer `STRING NOT
CLOSED`, which was the second of the two things stopping that program after
its `SPEED=` was in.

The line's terminator is **put back** rather than eaten. It belongs to the
line and not to the string, and the caller is about to go looking for the end
of a statement; swallowing it there would send the scanner reading the next
line's link bytes as though they were code. That left `STRING NOT CLOSED`
with no site that raises it — a true end of source mid-literal already
returns through the carry — so complaint 10 is now unreachable, and its text
is still in the table because the numbering either side of it is not worth
disturbing to save eighteen bytes.

`A`, `A(` and `A$` are **three different variables** to Applesoft, so there
are three tables here rather than one with a type column.

Two more runtime helpers join the array one: a print loop, and a comparison
that answers in exactly `FCOMP`'s convention, so everything already reading
`CMPWANT` and `CMPSENS` works unchanged.

The semantics were read off the machine first:

| | |
|---|---|
| `"AB" < "ABC"` | 1 — a prefix is the lesser |
| `"AB" = "AB "` | 0 — no padding with spaces |
| `PRINT "[";"";"]"` | `[]` |

Text is stored with its high bits **clear**, the way Applesoft stores it, so
that comparing two strings compares the bytes the interpreter would; the print
helper puts the bit back on its way to `COUT`.

**One place a number is insisted on.** `NEXPR` is `EXPR` plus a refusal, and
everywhere but a `PRINT` item, a string assignment and a comparison's two
sides goes through it. Without it a string reaching a numeric context — `FOR
I = A$ TO 5` — compiled into arithmetic on whatever the accumulator happened
to hold, which is the sort of wrong that runs. Finding all the call sites took
two goes: a search for `jsr EXPR` missed every one with a trailing comment, so
`FOR`'s three expressions and `ON`'s kept the unguarded version until a second
look listed what should have changed rather than counting what had.

### The slicing functions

`LEFT$`, `RIGHT$`, `MID$` and `ASC`.

**I first wrote these to share their parent's text**, on the grounds that a
substring is the same characters with a shorter length, or from further in,
and a compiled program never writes into a string's text — it only ever
replaces a descriptor. That let the whole family arrive before the heap rather
than after it, and it was true right up until the collector existed.

It is wrong with a compacting collector, and the reason is worth keeping. The
collector finds strings **by the address they start at**. A substring shares
its parent's block, so its pointer lands in the middle of one, and matches
nothing: the parent moves and the substring is left pointing at whatever
occupies that memory afterwards. Applesoft copies here, and this is why —
knowing *that* it copies was never the same as knowing why.

So they allocate and copy, through a shared ending, `HSLICE`. That ending
reads the source pointer **after** the allocation, deliberately: allocating
may collect, and a collection may move the very string being sliced. SDA is a
root, so by then it says where the text went.

**`LEFT$(A$, LEN(B$))` is not a strange thing to write**, and working out the
count builds `B$` in the one descriptor slot, losing `A$`. So the string goes
on the 6502 stack across the numeric arguments, which survives any depth of
nesting where a second slot would not. `MID$`'s starting position goes on the
stack too, because working out its count can reach another `MID$` through a
`LEN`.

**`LEFT$(A$,0)` is `?ILLEGAL QUANTITY` in Applesoft** — the range is 1 to 255,
not 0 to 255. I had it returning an empty string, and the interpreter said
otherwise. The compiled version clamps where Applesoft refuses, so the two
differ on invalid input; a program the interpreter rejects cannot serve as a
specification, so `tests/cc/slice` uses only arguments it accepts.

### EPRIM was too long, and splitting it cost two bugs

`EPRIM` reached 366 source lines with eight nested blocks. Every addition cost
two or three builds finding the next branch that had gone out of range, and
each block had grown a private failure exit because no shared one was in
reach. The string handlers are now five routines — `FLEN`, `FASC`, `FSLICE`,
`FMID`, `SVARP` — each with a label scope the length of itself.

**Both bugs the split introduced were fall-throughs**, which is what happens
when code that used physical adjacency as control flow gets moved without
making the flow explicit first:

- The `MID$` trampoline went directly under its own `beq`, so `LEFT$` and
  `RIGHT$` fell straight into it and every one of them compiled as `MID$`.
  `LEFT$("ABCDEFG",3)` printed `CDEFG`.
- `FSLICE`'s `LEFT$`/`RIGHT$` path used to fall through into the shared
  ending, and the routine's new failure exit went into exactly that gap. Every
  `LEFT$` then returned carry set with nothing reported, so the compiler
  stopped and printed no reason at all.

Neither is something an assembler can catch: there is nothing wrong with any
instruction involved. Only running it showed anything, and the refactor was
supposed to change nothing — which is the reason to run the suite over a
change that is supposed to change nothing.

**And the pass 1 report had stopped describing the program.** The variable
loop ends by jumping to the array report, and the string section went in above
that label rather than below it, so a program full of strings reported none.
Harmless to the output and not harmless at all: the report exists to say what
the compiler saw, and it had been quietly wrong since it was written. It
surfaced only because I was reading it to debug something else.

### The heap: joining, CHR$ and STR$

The operations that have to **make** a string. `MEMSIZ` at `$73` is `$9600`
under BASIC.SYSTEM with one file buffer, and a compiled program leaves it
alone — read off the machine before and after a `BRUN`, not assumed. So the
heap runs **down** from the top of free memory to the compiled program's own
last byte. That floor is `FINPC`, which is not known until every helper has
been emitted, so the allocator that needs it as a constant is emitted with the
value pass 2 recorded — the same forward reference as a `GOTO`.

**Joining puts the left side aside first.** Every string value is built in
SDA, so parsing the right of `A$ + B$` would build it on top of the left; the
left moves to SDB, which is where the join helper looks for it, exactly as the
comparison helper does.

**And the destination is written last.** `HJOIN` allocates and then holds the
new address in two places, because the result descriptor lives in the same
slot that still holds the right-hand operand — writing it early would destroy
the thing being copied.

Three call sites had to widen from a string *primary* to a string
*expression*: `A$ = B$ + C$`, `IF A$ = B$ + C$`, and `LEFT$(A$ + B$, 2)`. That
retired the `NO STRING JOIN YET` complaint, which existed only to name a plus
sign the parser could not reach.

### The garbage collector

Applesoft's own method: repeatedly find the live string sitting highest below
where the last one was moved to, slide it up against it, lower the boundary.
Quadratic in the number of descriptors, of which there are at most sixty-six,
for something that runs only when the heap is full.

**The roots are one unbroken run** — SDA, SDB, then three bytes per string
variable — which is why the layout puts them together and everything else the
runtime scratches in after them. SDA and SDB are roots because a collection
happens inside an allocation, in the middle of an expression: a join holds its
left side in SDB and its right in SDA, and both must survive.

A descriptor pointing below the floor is a literal living in the compiled
program's own text, and never moves. One comparison separates the two kinds.

The program that forced the work, before and after:

```
10 F$ = "X"
20 FOR I = 1 TO 400 : F$ = F$ + "Y" : NEXT
```

| | |
|---|---|
| interpreted | `?STRING TOO LONG ERROR IN 30` |
| before the collector | `?OUT OF MEMORY ERROR` at about 160 characters |
| after | `?STRING TOO LONG ERROR` |

It now stops for the same reason at the same point. The missing `IN 30` is the
line number a compiled program cannot know, which is the same limitation as
the division-by-zero case.

### Three bugs in the collector, and what each one taught

**Aliasing.** Two descriptors can hold the same address: `A$ = B$` makes two,
and `C$ = C$ + "C"` leaves the join's saved left side aliasing `C$` exactly.
Updating only the descriptor that won the search left the other pointing at
the old address, which the next round found and moved again, on top of
something else. Every descriptor pointing at the moved string is updated now.

**The wrong addressing mode**, and this was the one that mattered. The
descriptor walk began

```
LDA $xx        A5 — zero page
```

where it needed

```
LDA #<SDESCA   A9 — immediate
```

One byte. The collector never walked the string descriptors at all: it walked
whatever lived at that zero-page address, found "descriptors" in unrelated
memory, and moved bytes on their say-so. The same typo appeared twice, because
I copied it forward while fixing the aliasing bug.

**This is the limit of the generator.** It computes branch offsets and sizes
so those cannot be wrong, and it confirmed `HGC` at 277 bytes with every
branch in range — but it has no idea whether `A5` is the opcode that was
meant. It checks the arithmetic, not the intent.

**And the near miss is the lesson.** The first failure looked exactly like an
aliasing bug; aliasing *was* a real bug; fixing it changed nothing, because it
was never the cause. Had the fix happened to mask the symptom, a collector
that walks arbitrary memory would have shipped. **The unchanged failure was
the useful signal** — the same value as a test that fails for the reason you
expected it to.

### What a full heap cost before the collector

An allocation that does not fit collects once and tries again; only then does
it give up with `?OUT OF MEMORY ERROR`, back to the `]` prompt by way of the
stack pointer the prologue saved. Once, because a collection that did not free
enough will not free more for being run again.

### Writing the runtime with a generator

The string runtime is about 380 bytes now, and writing `lda #$xx / jsr EMIT`
twice per byte by hand is tedious and a good way to mistype an opcode. The
helpers are written as byte specs and the emitter source is generated from
them.

Its first useful act was confirming that `HERR`, `HALLOC` and `HCHR` came out
at exactly 27, 53 and 27 bytes — the sizes the hand-counted branch offsets in
their comments assume. That check used to be done by eye.

### A harness fault wearing a compiler fault's clothes

The string test failed with one extra `HELLO` in the compiled output, which
reads exactly like a code generation bug. It was not one.

`capture()` dropped the screen's first row, taking it for the echoed command.
That is true only while the output is short enough not to scroll. The test had
grown past a screenful, `]RUN` went off the top, row 0 became a real line of
output, and the capture ate it — and the compiled run scrolled differently, so
the two disagreed by one line.

What settled it was dumping the raw screen with row numbers and finding **both**
`HELLO`s sitting there. The output was right; the reading of it was wrong.

The capture now finds the echo rather than assuming where it is, and a program
whose output fills the screen is **refused outright** rather than compared on
whatever survived. Same rule as the benchmark refusing to report a timeout as
a measurement: a truncation is not a result. The string tests are two programs
now, both comfortably inside a screen.

### PEEK, POKE, CALL and ON ... GOSUB

**The integer conversion had to be established again.** `AYINT`, which the
array subscripts and the logical operators use, is **signed** and refuses
anything above 32767 — which rules out every address a `PEEK` is usually
interested in. `GETADR` at `$E752` gives an unsigned sixteen bits in `$50` and
`$51`; read off the machine, where 49152 comes back as `0, 192`. Reusing the
routine already to hand would have given a compiler that handled `PEEK(1000)`
and failed on `PEEK(49152)`.

**`CALL` and `ON ... GOSUB` share three bytes.** `JMP (ZPB)` reached by a
`JSR` *is* a computed call: the return address is already pushed and the
target's `RTS` comes back to the right place. One helper serves both and
neither needs more.

**`ON ... GOSUB` differs from `ON ... GOTO` by exactly those three bytes**, at
the end. A `GOTO` never comes back, so the jump table can sit immediately
after the jump out; a `GOSUB` does come back, and would land on the table
unless a `JMP` steps over it. So the table starts at 30 or at 33, and the
three range-check branches are computed from that rather than written twice.

**`POKE` puts its address away before working out its value**, in the
program's own scratch rather than the zero page — because working out the
value can be an array subscript or a string operation, and both use exactly
the zero-page bytes the address would have been sitting in.

### VAL, and two things that have to be put back

The ROM does the parsing. `FIN` at `$EC4A` reads a number from wherever
Applesoft's text pointer points, reached through `CHRGET` — established on the
machine with `123.5`, `-72`, `"  42"` with its spaces skipped, and `7E2` as
700.

**The text pointer is Applesoft's own.** Pointing it at our string means the
interpreter resumes from a pointer into the heap when the program returns, so
it is saved and restored around the call.

**And an Applesoft string has a length, not a terminator.** `FIN` reads until
it meets a non-numeric character, which for a string in the heap is whatever
happens to follow it — `VAL("12")` with a `3` next door would be 123. So the
byte just past the string is zeroed for the duration and put back afterwards,
which is what Applesoft's own `VAL` does.

The address of that byte is computed **twice**, once to zero it and once to
restore it, rather than kept in the zero page across the call: `FIN` may use
any of the zero page it likes, and the descriptor it comes from lives in the
program's data area where `FIN` cannot reach.

### What it compiles

`LET` (named or implied), `DIM` and one-dimensional arrays, `GOTO`, `GOSUB`,
`RETURN`, `IF ... THEN` and `IF ... GOTO`, `FOR` / `NEXT` with `STEP`,
`ON ... GOTO` and `ON ... GOSUB`, `PEEK`, `POKE` and `CALL`, string
variables and literals with assignment, comparison and
`LEN`, `LEFT$`, `RIGHT$`, `MID$`, `ASC`, `CHR$`, `STR$`, `VAL` and joining with `+`,
`PRINT` of numbers and strings with `;` and `,`, `REM`, `END`, and expressions over `+ - * /`, unary minus,
brackets, the six comparisons, `AND` / `OR` / `NOT`, and the eleven numeric
functions.

Not yet: `DATA`/`READ`, `INPUT`, `DEF FN`, the graphics statements,
arrays of more than one dimension, and arrays of strings. Each
is refused **by name and line number** rather than compiled wrongly:

```
STOPPED IN 30: NO STRINGS OR ARRAYS
STOPPED IN 20: NO SUCH LINE
STOPPED IN 30: NEXT: WRONG FOR
STOPPED IN 10: EXPONENT TOO BIG
```

A compiler that carried on would write a program that ran and gave a wrong
answer, which is the one outcome worse than refusing.

### What happens when a compiled program goes wrong

Established rather than assumed, because the ROM's arithmetic raises errors
through Applesoft's own handler and a compiled program has not set that up.
A compiled `1/0`:

```
]BRUN CDIVZ
BEFORE
?DIVISION BY ZERO ERROR
]
```

It prints and returns cleanly to the prompt. The only difference from the
interpreter is the `IN 40`, which a compiled program genuinely cannot know.

**The compiler itself cannot afford the same thing**, being a SYS file with
BASIC.SYSTEM gone from memory — so the constant converter guards on the size
of the *result* rather than on the exponent as written, and refuses `9E38`
instead of raising an overflow inside the ROM.

### Closing the gap to the hand-compiled model

The model did BENCH1 in 7.25s. The first working compiler did it in 9.09s, and
two changes closed the gap and then went past it, to **7.11s**.

**The first was the smaller one, and I expected it to be the larger.** `IF I <
3000` was compiling the comparison into a proper Applesoft value — materialising
1 or 0 in the accumulator — and then testing whether that value was zero.
Producing a value is right in general, since Applesoft lets a comparison BE
one, so the fix was to recognise the common case: an `IF` whose expression is a
single top-level comparison branches straight off `FCOMP`. Twenty-two bytes and
a ROM call per iteration. It bought 0.25s.

**The second was the real cost, and it was in every expression in every
program.** A binary operator was storing its left side into a temporary and
loading it back:

```
MOVFM I ; MOVMF temp ; MOVFM C1 ; FADD temp ; MOVMF I      five ROM calls
```

where the model wrote

```
MOVFM I ; FADD C1 ; MOVMF I                                three
```

The fix is one deferral: **a leaf is not emitted when it is parsed.** A plain
variable or constant only records its address, and the operator decides what to
do with it. When the left side is still just an address, the right side can go
into the accumulator and the operation can name the left — which is what `FSUB`
and `FDIV` want anyway. The temporary is still there for when the left side is
itself an expression, which is what it was always for.

That is worth two ROM calls on every binary operator in the program, and it
took BENCH1 from 8.84s to 7.11s.

Both changes were checked against the interpreter before being measured, which
matters more than usual here: a faster wrong answer is not an improvement, and
the deferral touches the operand order of exactly the two operations that are
already the other way round from the obvious guess.

### Three bugs worth keeping

**A routine that ended in a JMP to the emitter returned the emitter's carry**,
which its own `CMP` of the pass number leaves set in pass 3. Pass 2 succeeded
and pass 3 reported failure, and the driver's silent stop printed nothing at
all — indistinguishable from a program that never ran. Every exit now names
the stage it stopped at.

**`LDA #lo / LDY #hi / JSR` is seven bytes, not eight.** Counted as eight, a
comparison's false branch landed one byte inside the load it was aiming at.
The benchmark ran its loop exactly once and printed `1` — a believable number,
which is the dangerous kind of wrong.

**Two `dum` blocks on top of each other**, because `dumcheck.py` globbed
`src/*.S` and the compiler lives in `src/cc`. It takes a directory now, one
program at a time. It also sizes `VMAX*2` rather than silently calling it
zero, and reads an equate that has a comment after it — so the editor's
`SCRW`-sized blocks are being checked for the first time as well. The symptom
was an output file named `CS300`.

### Two more, from the DATA work

**Merlin silently accepts a local label that does not exist.** A slice while
adding `DATA` deleted the `DIM` parser; the `jmp :dim` that reached it stayed
behind, and the assembler said nothing — no error, no warning, and a binary
came out the other end. Every array then got the default eleven elements, so a
`DIM A(20)` wrote the last ten over the program's own code.

The test suite passed that program. `ARRAYS` printed every number correctly
and was recorded as agreeing, because code that has already run is code whose
corruption you cannot see. It only surfaced as the *next* thing the machine
was asked to do hanging — a failure with no visible connection to arrays at
all. The layout had to be read back out of the compiled binary to find it:
arrays started at `$605A`, the code at `$6091`, and fifty-five bytes is
eleven elements where twenty-one were wanted.

`tools/scopecheck.py` now reports a local label used in one global label's
scope and defined in another. Run against the whole tree it found a second
real case immediately — `:mbad` sitting above `FMID`'s own label, and so in
the previous routine's scope.

**A prologue cannot consult a tally the code generator has not filled in
yet.** Helpers are emitted after all the code, so asking "did anything use the
string collector?" works there. The prologue is emitted first, and its
question — "does this program use `DATA`?" — was always answered no, because
no `READ` had been compiled at the point it asked. The data pointer was never
initialised and `READ` fetched from address zero. The size was consistent
across passes, so nothing complained; the program simply printed nothing.

Anything the prologue needs must be a fact pass 1 established, so `FDATA` is
set there, by the scan that already walks every token. The helper block and
the prologue now test the same flag, which is also what keeps the table and
the pointer that addresses it from disagreeing about whether to exist.

### The test disk was running a different compiler

`ac -p` on a filename that is already in the catalogue **adds a second entry
rather than replacing it**, and ProDOS runs the first one it finds. The test
image is copied from the distribution disk, which already ships a compiler —
so `-ASIDECC.SYSTEM` ran the one `make dist` last baked in, and the freshly
assembled binary sat further down the catalogue, never executed.

The image had two files of the same name, seventeen thousand two hundred and
ninety-two bytes and seventeen thousand three hundred and twelve, and it was
the older one that ran.

This is the worst shape a harness fault can take, because it is indis-
tinguishable from a fix that does not work. The source was right, the
assembled binary was right, and the machine disagreed — so the evidence all
pointed at the compiler. Reading the compiled output back and finding the
prologue's data-pointer setup missing only confirmed the false conclusion; the
bytes really were missing, because a compiler that predated the fix had
written them.

What settled it was comparing the binary on the disk against the one on the
host: same name, different length. `tests/cc.sh` now deletes the file before
adding it, and refuses to run if more than one survives.

That makes four faults this project has traced to its instruments rather than
its programs — the screen capture that dropped a row once output scrolled, the
benchmark that timed `BRUN` and so charged the compiled side for loading
itself, the process patterns that matched the very shell doing the matching,
and now this. The pattern worth naming: **an instrument that is wrong in a
plausible direction costs more than no instrument at all**, because it does not
merely fail to answer, it argues for a specific wrong answer, and it keeps
arguing as long as you keep asking it.

## INPUT

Asked of the machine before any of it was written, because INPUT's rules are
close enough to DATA's to invite assuming they are the same, and they are not:

| | |
|---|---|
| `INPUT A` | prints `?` |
| `INPUT "P";A` | prints `P` and **no** question mark |
| an unquoted item | loses its **leading** spaces, keeps its **trailing** ones |
| a quoted item | is what lies between the quotes, commas included |
| too few items | `??`, and asks again, keeping what it already assigned |
| a bad number | `?REENTER`, then **the whole statement runs again** |
| items left over | `?EXTRA IGNORED` |

`DATA` trims an unquoted item at both ends; `INPUT` trims only the front. Two
rules that look alike and are not, which is the entire argument for asking
rather than remembering.

The last two shaped the code. `?REENTER` re-runs the statement, so `GINPUT`
records where its own output began and the bad-number path jumps back there —
backwards, inside one statement, so the address is already known in both
passes and none of the forward-reference machinery is involved.

**What says a number is bad** is not the conversion, which cannot fail: `FIN`
parses what it can and stops, so `ABC` quietly becomes zero. What says so is
*where it stopped*. If `TXTPTR` did not reach the end of the item there was
something left over that is not part of a number, and that is the `?REENTER`.

**An input string is copied, a DATA string is not.** A `DATA` item can be
pointed at where it lies, because it lies in the program and never moves. An
input line cannot: the next `INPUT` reads over it.

The copy is its own helper rather than the slice helper, and the reason is the
collector. Allocating may collect, the collector walks the roots, and `SDA` is
a root — at that moment pointing into `$0200`, which is not in the heap and
belongs to no block. Whether this collector skips a root aimed outside the
heap is a question with a right answer, but it is not one the code needs to
ask: `HICOPY` sets the length to zero before allocating and keeps the buffer
position in scratch instead.

**The high bit comes off every character.** `GETLN` returns high ASCII and
every string this compiler makes is low, so a line left as it arrived would
compare unequal to an identical literal and print as inverse text.

`tests/cc.sh` answers a program that asks, from `tests/cc/<name>.in`, giving
both runs the same input. The prompts are part of the screen being compared,
so a compiled `INPUT` that printed `?` where Applesoft prints nothing is a
difference like any other.

### A size check the compiler did not have

The editor's build refuses a binary that will not fit its budget; the
compiler's did not have one. It runs from `$2000` and its tables are at
`$8000`, so there are 24,576 bytes to grow into and nothing was watching. The
build says where it ends now, and stops if it would reach the tables.

## DEF FN

Asked of the machine first, as usual, and the answers decided the design:

| probe | result |
|---|---|
| `X=99`, `DEF FN S(X)=X*X+Y`, `Y=10`, `FN S(3)` | `19` |
| `PRINT X` afterwards | **`99`** |
| `Y=100`, `FN S(3)` again | `109` |
| `DEF FN T(Z)=FN S(Z)+1`, `FN T(2)` | `105` |

`X` surviving as 99 is the one that shapes the code. The parameter is an
ordinary variable — no special slot, no substitution while compiling the body
— and the **call site** saves it into five bytes of its own, sets it to the
argument, calls the body, and puts it back. The restore is two memory copies,
which do not disturb the answer sitting in FAC.

The body is compiled where it stands and jumped over. The jump is forward and
its target is unknown until the body is compiled, which is the shape of a
forward `GOTO` and takes the same answer: pass 2 records where the body ended,
pass 3 emits it, and both emit three bytes either way.

What the call knows about the function goes on the compiler's stack before the
argument is compiled, because the argument may itself be a call — `FN T(FN
S(2))` — and the inner one would otherwise overwrite the outer one's recorded
address.

### A local label on a global label's own line belongs to the PREVIOUS scope

This cost eight runs on the machine, and every one of them looked impossible.
`FN S(3)` reported a complaint from `GDEF`, the routine that compiles `DEF` —
in a program with no `DEF` in it.

The dispatcher was right, the token values were right, the message table was
right, and the error codes were right. What was wrong was one instruction:

    UFN          jmp   :go        <- resolved to GDEF's :go, not UFN's

Merlin resolves a local label referenced **on a global label's own line** in
the scope the label is closing, not the one it is opening. Both routines
defined `:go`, so `UFN` jumped into the middle of `GDEF`, which then complained
about a header that was not there. Every reference on a *later* line scoped
correctly — `:bad`, `:nofn` and `:badp` all pointed into `UFN` — which is
exactly what made it unreadable from the source.

The disassembly said it in three lines:

    6190: JMP $553F      EPRIM's FN branch -> UFN          (right)
    553F: JMP $548F      UFN's "jmp :go"   -> GDEF's :go   (wrong)
    554B: LDA #$24       UFN's own :go, never reached

`tools/scopecheck.py` now refuses a local label on a global's own line, and
found a second one immediately: `FMID`, whose comment already recorded a near
miss with `:mbad` in the previous scope. It works today only because the
routine above it happens not to define `:go`.

That is the second way this assembler accepts a local label and does something
other than what the source says. The first was accepting one that did not
exist at all.

**The lesson about method, not about Merlin:** the symptom contradicted the
source, and the answer was to stop reading the source. Eight runs went into
narrowing by inference — checking the dispatcher, the tokeniser's output, the
message table, the free tally bits — when one look at the compiled bytes
settled it. When what the machine does cannot be reconciled with what the code
says, the code is not the thing to read.

The bug underneath it was found the other way round and took one look: every
call compiled to `JSR` the function's *save slot* instead of its body, because
the body address was parked in `CPT` and `EMCOPY5` uses `CPT` as scratch for
the addresses it emits.

## Arrays of strings

The elements go **immediately after the string variables**, inside the run the
collector already walks. Every element is a descriptor and therefore a root,
so putting them anywhere else would have meant teaching the collector a second
range; putting them here meant giving it a larger count. That the layout was
already arranged as one unbroken run is what made this a small change.

The count is a single byte, so `LAYOUT` refuses a program whose descriptors
pass 255 rather than emitting one that has wrapped. A collector told to walk 3
of 259 descriptors would move a string out from under the other 256.

`tests/cc/sgc` is the test that checks the claim rather than the syntax: three
hundred and sixty allocations of growing strings against a heap that cannot
hold them, so collection happens repeatedly with array elements live, and
`A$(I) = A$(I) + "Y"` makes the aliasing case that broke the collector once
before — a descriptor whose old and new values name the same text.

### Three bugs, sorted by what found them

**Reading found one.** `SAADDR` recomputes the descriptor total for every
subscript, and the helpers are emitted after the code, so the collector would
have been handed whatever partial sum the last element reference left behind.
It would have walked too few roots: silent corruption, not a crash. The total
is taken once now, in `LAYOUT`.

**The size guard found the second.** `SASUM` reaches the table through
`SLOTN`, which works in `TMPP` — so adding its result to `TMPP` put the
program's data fifteen thousand bytes further on. The guard turned what would
have been a compiled program that overwrote ProDOS into a refusal with an
address in it.

**Only the machine could find the third.** A loop counter in `X` across `JSR
EMIT`. `EMIT` discards in pass 2 and writes the file in pass 3, and makes no
promise about `X`, so the same loop ended in one pass and never ended in the
other — a hang that appears halfway through compiling and not at all in the
half that ran first. The codebase already counts in memory in its other emit
loops; this did not.

Markers printed around each step of the element read said `ABCD` in pass 2 and
`ABC` in pass 3. Two runs: one to learn it was pass 3 and which line, one to
learn which routine. That is the shape to reach for first when a symptom
cannot be reconciled with the source — it was reached for late with the `:go`
scope bug and early here, and the difference was six emulator runs.

### And one about an existing contract

`PUTBACK` hands back `CH`, not the accumulator. A lookahead therefore has to
store what it read before pushing it back, which is what `EPRIM` does a few
lines away and what both new ones failed to do — so they handed back the `$`
that `GETNAME` had left there, and the `=` after it was never seen.

## Arrays of more than one dimension

`DIM A(3,4)` is four by five, twenty elements, up to three dimensions. The
index is the mixed-radix sum — `i1`, then `idx * extent-of-k + ik` for each
one after — with the multiplying done by the compiled program, because the
subscripts are only known when it runs, and the extents worked out here,
because they are known when it compiles.

**The element order need not be Applesoft's**, which is what kept this small.
The compiled program is the only reader of its own arrays; nothing outside it
ever sees the layout. So the only thing that has to hold is that `A(1,2)`
reads what `A(1,2)` wrote, and that let the whole question of Applesoft's
internal ordering go unasked.

**A multi-dimensional use must follow its DIM.** A bare use gives an array
eleven elements in one dimension, and pass 1 cannot count the commas from the
use — what is inside the bracket is scanned as ordinary code, not parsed. So a
subscript with more commas than the `DIM` declared is refused by name rather
than folded into one dimension and written outside the array.

`A(I,B(J))` works: the inner subscript runs the same routine again, so the
dimension counter and which-array are kept across the expression.

### Absolute opcodes with a one-byte operand

The compiled program printed nothing at all — not even the `PRINT` on a line
that had no array in it. The disassembly said why in one instruction:

    61AC: 6D A1 8D   ADC $8DA1

`FACLO` and `FACHI` are `$A1` and `$A0`: **zero page**. Emitting `$6D` — `ADC`
absolute — with a single operand byte made each of those instructions swallow
the byte after it, and from there the whole stream ran together into
something that returned to BASIC without doing anything.

Six of them, all mine, all in the new code. The fix is the zero-page opcode:
`$A5`, `$85`, `$65`.

**And the fix nearly went in incomplete.** A pattern that repaired five of the
six skipped the one with a trailing comment after the opcode — the same shape
that once made `dumcheck.py` miss an equate with a comment on it. Counting the
opcodes afterwards is what caught it, which is the habit worth keeping: after
a mechanical edit, count what changed rather than trusting that it all did.

## VTAB, HTAB, and the screen switches

`VTAB`, `HTAB`, `HOME`, `TEXT`, `INVERSE`, `NORMAL`, `FLASH`. Applesoft counts
rows and columns from one and the monitor counts from zero, so each of the
first two is the expression less one: `VTAB` stores `CV` and calls the
monitor's `VTABZ` to work out the line's address, `HTAB` writes `CHPOS`.

An argument outside the legal range is `?ILLEGAL QUANTITY` in Applesoft and is
not checked here.

### SPEED= is stored upside down

`SPEED=` looks like a store and is not. Asked on the machine, `SPEED= 175`
leaves 81 at `$F1`, `SPEED= 255` leaves 1, `SPEED= 1` leaves 255, `SPEED= 128`
leaves 128 and `SPEED= 0` leaves 0 — which is `(0 - n) & $FF`, the two's
complement. Both of the plausible readings fit the first two samples and fail
on the rest: it is neither `n` nor `255 - n`.

`COUT1` counts that byte down between characters, so a bigger `SPEED` is a
smaller wait and `SPEED= 255` is asking for a delay of one rather than of
none. Storing `n` directly would have made every `SPEED=` mean nearly its
opposite, and a program that opens `SPEED= 175` for readability would have
crawled — slowly enough to read as a hang rather than as a wrong number.

This is the fifth or sixth time the machine has contradicted the obvious guess
about a ROM location. The guess cost nothing here only because it was never
written down as code.

Two Beagle Bros programs — CHR\$ POKER and the DOS BOSS demo — were refused on
their `SPEED=` and nothing else. The compiler stops at the first refusal, so
one missing keyword on an early line reads from the outside as "none of my
programs compile".

### The statement list was full

`GENSTMT`'s keyword tests reached their targets with little to spare, and
adding to the front of the list pushed the ones at the back out of branch
range — four separate build failures, each naming a different innocent
statement. The answer was not more trampolines but a second list, which the
first falls through to when it does not recognise a keyword. It costs one jump
for the keywords that reach it, leaves the first list alone, and is where
anything added later should go.

### A blob that is copied may not name an address inside itself

The runtime helpers are assembled here as ordinary code and COPIED into the
compiled program, with the `$FFFF` placeholders substituted on the way. That
substitution is the only relocation there is. So every absolute address inside
such a blob must be a placeholder, and the assembler will happily give you one
that is not:

    inc   ZPB+3
    jmp   :zero          ; <- assembles to :zero's address HERE, $6AF5

The compiled program jumped to `$6AF5`, which is inside the compiler, and the
machine stopped in the monitor at `$6AF8`. The fix is three bytes either way:

    clc
    bcc   :zero          ; always -- a branch carries no address

**It hid for a long time because of which path reaches it.** The zeroing loop
is `inc ZPB+2 / bne :zero`, and the `jmp` is only reached when that increment
wraps -- once per 256 bytes. An array that happened to sit inside one page
never touched it. `dynh` and `dyn4` differ by two scalar variables: the extra
eight bytes of layout moved the array from `$0F7C` to `$0FFC`, across `$1000`,
and turned a working compile into a monitor prompt. Nothing about the source
said arrays; the trigger was the SIZE of everything in front of them.

Both `HDIMB` and `HSDIMB` had it. `tests/cc/dynpage.bas.txt` and
`sdynpage.bas.txt` now dimension 201 and 121 elements, which cannot fit in a
page whatever the layout does, so the path is taken every run. Both were
checked by putting the `jmp` back and watching them fail.

**And the knowledge was already here.** `EMHRUN` relocates two `JMP`s at the
front of `HRUNB` -- its comment says they "point INSIDE the blob and so have
to be moved along with it", and names their positions. So the hazard was
understood, written down, and handled correctly in one of the three blobs
while the other two shipped with it. Knowing a rule in one routine is not
knowing it in the next one; that is what the grep below is for.

The general rule, and it is worth grepping for after any edit to a helper:
inside a copied blob, `jmp`/`jsr` to a local label is a bug unless the target
is one of the substituted operands. Branches are always safe. And an emitted
byte must never be `$FF` by accident, because the substitution reads `$FF` as
the start of a placeholder -- which is a second, quieter version of the same
trap.

### The image filled up, and where the room came from

It reached **12 bytes** — the code ending at `$8FF4` against tables starting at
`$9000` — with three features waiting and none of them fitting. What the
measuring found is worth writing down, because the answer was not where the
guess would have put it.

The assembler writes a listing (`ASIDECC.SYSTEM_Output.txt`, which the
Makefile deletes). Reading it: `gen.s` 21,987 bytes, `pass1.s` 4,075, `cc.S`
2,598 — and the largest single things in the image were not the compiler's
logic but its **emitters**. `EMHGC` alone was 1,144 bytes to emit about 277.
A helper written as `lda #x : jsr EMIT` costs **five bytes of compiler for
every byte that reaches the program**.

`HDIMB` had always been done the other way — written out as data and copied,
with `$FFFF` placeholders filled in on the way. That costs one byte per
emitted byte: blob, table and copier together are 97 bytes to emit a 76-byte
helper, **26% of straight-line**. `EMBLOB` is that copier, shared.

Converting `EMHVAL` (410 → 112) and `EMHIVAL` (555 → 147) freed **618 bytes**
for 88 spent once on `EMBLOB`. The conversions were proved rather than
tested: twelve programs compiled with the old compiler and the new one came
out **byte-identical**, which says the change cannot have altered anything
reaching a compiled program.

**Two of the other three needed a richer marker, and got one.** The marker is
now ONE blob byte whose table entry says what it stands for, which is what
lets a blob express things a two-byte address cannot:

| entry | means | emits |
|---|---|---|
| `$00-$3F` | `SDESCA` + offset | two bytes |
| `$40-$7F` | `SCRA` + offset | two bytes |
| `$80-$9F` | a `BVARS` variable, whole | two bytes |
| `$A0-$BF` | a `BVARS` variable + offset — **eats the next table byte** | two bytes |
| `$C0-$DF` | its low half | one byte |
| `$E0-$FF` | its high half | one byte |

The halves are what `EMHJOIN` needed: `LDA #<MLONG / LDY #>MLONG` puts them
four instructions apart, so no two-byte marker could say it. The offset kind
is what `EMHNEXTI` needed: it branches to a label INSIDE another helper, and
knows the label's distance from the top but not where the top will land.

So `EMHVAL` 410 → 112, `EMHIVAL` 555 → 147, `EMHJOIN` 466 → ~125, `EMHNEXTI`
739 → ~180. All four proved byte-identical over twelve programs.

**`EMHGC` is the one left**, and its blockers are not addresses at all: it
calls `EMSETRUN`, and it captures `PC` mid-stream into `HBNDHI`/`HBNDLO` to
backpatch forward branches. That is compile-time bookkeeping interleaved with
emission, and reaching it means splitting the routine into blob runs around
the bookkeeping rather than inventing another kind. Worth about 900 bytes
when something needs them.

Two other levers, measured and not used: the tables can move up about **709
bytes** before they reach ProDOS, and putting them in auxiliary memory would
free all **11,323** at the cost of requiring a 128K machine.

### Two things the room was spent on

`HGR2` cost fourteen bytes, because pass 1 already knew the token — it has to,
since a program using `HGR2` owns `$4000-$5FFF` as well and cannot load below
`$6000`. Only the generator entry was missing, which is why GRAPH stopped with
STATEMENT NOT YET rather than at a wrong address. `$F3D8` was confirmed on the
machine: `HGR2` and `CALL -3112` both leave 64 in `$E6`, and `HGR` leaves 32.

**Two-dimensional arrays of strings.** Numeric ones have worked for a long
time — `DIM A(3,4)` keeps its extents in `DIMTAB` and takes as many as
`MAXDIM`. Strings took one subscript and answered ONE DIMENSION ONLY, which
is an odd thing for a compiler to say about `DIM W$(8,10)`.

They are stored as the one-dimensional array of `i*stride+j` that they are,
with the stride kept in `SATAB` — widened from four bytes an entry to six.
`EMS2D` emits one multiply by a number known at compile time and one add,
reusing the same `HMUL` helper and the same `SCRA+$1E..$23` the numeric path
uses. **Two subscripts and no more**: a numeric array can afford a table of
extents, a string array keeps one stride, and a third subscript is refused by
name.

Deliberately NOT shared with the numeric multi-subscript code. That path works
and `dim2`/`dim3` prove it; factoring it to serve both would have put the
working case at risk to save bytes that were not needed.

## Straight from the editor: OA-B

The editor hands the document to the compiler and gets you back, which is the
"integrated" part of the name and the one axis on which TASC -- a batch
compiler you leave the editor to run -- is not in the comparison at all.

`OA-B` saves the document, leaves the note Ctrl-R has always left, writes the
filename at **$0380**, and launches the compiler. The compiler finds the name
there instead of asking, clears the mark so a later compile by hand asks for
its own, and on the way out goes back where it came from -- but **only if the
program was refused**. After a compile that worked, what is wanted is the `]`
prompt to `BRUN` from, which is where it has always gone.

`$0380` survives because it is below the load, above the relaunch stub both
programs copy to `$0300`, and clear of ProDOS's vectors at `$03D0`. Neither
program keeps data there. **Nothing is handed back** on the return trip: the
editor's note is already on the disk, and `RSLOAD` reads and deletes it on the
way up, so the document reopens by the mechanism that already existed.

The compiler side costs 95 bytes; the rest is in the editor, which has room.

### Both our SYS files were missing their JMP

The whole thing failed at first, and the cause was neither end of the new
code. The relaunch stub checks `$2000` for the `JMP` "every SYS file starts
with" as its guard against a short read -- a guard written while BASIC.SYSTEM
was the only thing it ever launched. BASIC.SYSTEM does start with `JMP`.
**ASIDE.SYSTEM and ASIDECC.SYSTEM both began with `LDA`**, and were refused by
it. They open with `jmp START` now, which is the convention anyway; the guard
would have rejected the return trip too, since the compiler's stub makes the
same test.

And `HOME` clears the current **text window**, not the screen. The editor
leaves a window of its own, so the compiler wrote into a box inside the
editor's leftovers and looked like it had not run at all. `SETTXT` first.
BASIC.SYSTEM did that for itself, which is why it had never shown.

### How not to find this

Three of the false trails were self-inflicted, and all three would have been
caught by one control -- *does Ctrl-R still work with this instrumentation in
place?*

- A **stale disk image**: the emulator still had it mounted and flushed its own
  copy back over the new one. `tests/run.sh` has a guard for exactly this and
  refuses to report results about the wrong binary; `cccompile.sh` ejects
  first. Do the same by hand.
- Markers written through **`$C005`, which is write-AUX**, not `$C004`. Every
  one of them landed in auxiliary memory, invisible -- which made "the stub is
  never entered" look true when it was not.
- A marker poked into **`$0800`, which is the editor's ProDOS buffer**,
  corrupting the very read being observed.

Those produced two confident and wrong bisections. What settled it in one look
was `tools/vii.sh dump`, which reads the emulated machine's memory **from the
host**: the handoff held `CC 09 "HELLO.BAS"`, the READ block showed a transfer
count of `$6FAF` -- the whole file -- and `$2000` held `A9 00 8D ...`, the
compiler's own first instruction. Read the machine; do not ask it to tell you
about itself.

## A skip that did not stop at the comma

SIMEQN "compiled" and wrote no file. `SKIPEXPR` walks past a subscript whose
size is not a literal, counting brackets, and it stopped only at the closing
one. So `DIM A(N,N)` skipped BOTH extents, found the bracket where it wanted
it, and the array was filed as **one**-dimensional and sized at run time.
Nothing said otherwise.

The two-subscript uses of `A` later on then asked `DIMTAB` for an extent no
`DIM` had written, and the compiler went off into the weeds and never printed
a verdict at all — which from the outside looks exactly like a successful
compile that forgot to save.

It stops at a top-level comma now. Both callers already test for `)` straight
afterwards and complain otherwise, so the whole fix is three instructions and
it turns a silent wrong answer into ONE DIMENSION ONLY on the line that
deserves it.

**A refusal, not a compile.** SIMEQN wants runtime-sized multi-dimensional
arrays: `DIM A(N,N)` where both extents are variables. That needs each array's
extents kept at run time and the index multiply reading them instead of the
compile-time immediates `EMDIMX` supplies — 200 to 400 bytes, against the 154
that are left.

## SPC

`SPC(n)` counts n spaces out; `TAB(n)` moves to a column. Asked on the
machine, because the two look alike and are not: `SPC(3)` after `"AB"` leaves
the cursor at 5, `SPC(0)` prints nothing, and `SPC(5)` at the start of a line
gives five. There is no comparison with the cursor and no "already past"
case — there is no past.

Its loop is fourteen bytes and its two branch offsets are **counted from a
layout written into the comment**, the way `TAB(`'s are, because the last
routine laid out by eye had all three of its branches wrong and printed
nothing at all.

## A flag that meant two different things

The worst bug of the lot, because nothing about it is visible at the place it
goes wrong. Two routines resolve a blob's placeholders, and one falls into the
other:

    HSDADDR   lda  HSDIMWHAT,y
              cmp  #$07          ; sets Z from (code == 7)
              bcs  :mine
              jmp  HDADDRA

    HDADDRA   bne  :not0         ; expects Z from a LDA of the code

`HDADDR` gets here by **falling through a `LDA`**, so `Z` says *is the code
zero*. `HSDADDR` gets here by **`JMP`, after a `CMP #$07`**, so `Z` says *is
the code seven*. Code 0 took the branch, fell past every test below it, and
came out as code 6 — the allocator's floor instead of the array break.

So a string array dimensioned at run time took the FLOOR'S HIGH BYTE as the
low half of its base. The floor starts at the end of the program, so the two
bytes that came back were the program's own high byte twice: `$35C7` became
`$3535`. The DIM zeroed 146 bytes of the program and then filled in its
descriptors, and STATS crashed the first time it called a helper that had been
sitting there — at a `GET`, hundreds of lines and one whole screen of output
after the DIM that actually did the damage.

**It was diagnosed from the run-time layout, not from the source.** The base
slot held `$3535` and the break had finished at `$36C7`, its high byte moved
and its low byte untouched. Both of those are exactly what "code 0 resolves to
the floor's high byte" predicts, and neither is what any other theory
predicts. Reading those two words turned a guess into a diagnosis; five
reductions before that had reproduced nothing.

The fix is `cmp #$00` at `HDADDRA`'s entry — two bytes, and the comment beside
it says why it is not redundant.

**What the tests missed and why.** `sdynpage` dimensions a dynamic string
array and passed throughout. It only ever assigns literals, so it never forces
the allocator, and a base pointing into the program's tail did no visible harm.
`sabase` is the test that catches it: a dynamic string array AND a dynamic
numeric one, a real allocation, and then calls into the compare and join
helpers — which live in the tail that gets zeroed. Confirmed by putting the
bug back and watching it crash.

The general lesson, and it is not about this routine: **an entry point reached
two ways must not depend on flags the caller happened to leave.** One caller
fell in, the other jumped, and the two disagreed about what `Z` meant.

## One FOR, several NEXTs

Applesoft matches `FOR` and `NEXT` on a stack it keeps **while the program
runs**. So a loop with an exit either side of an `IF` can be closed by
whichever `NEXT` is reached, and KALEIDO is built that way throughout:

    930 FOR N = 1 TO W
    945 IF ... THEN ... : NEXT N: RETURN
    960 ...             : NEXT N: RETURN

This compiler matches them **where it reads them**, which is what lets a `FOR`
become four slots laid out at compile time instead of a stack frame. The
second `NEXT` found the loop already closed and said NEXT WITHOUT FOR about a
program Applesoft runs.

The fix is small, because popping only moves `FSTKTOP` down: the entry is
still sitting there, and the code a second `NEXT` wants is exactly the code
the first one emitted. `GNEXT` closes a loop as before, and if there is
nothing open — or the name does not match what is — it scans the entries that
have already been closed, most recent first.

`FSTKMAX` is how far up that scan may look, and **it has to be initialised
with everything else**. It was not, the first time, and the nested case
walked through `FSTKV` entries no `FOR` had ever written and compiled a crash.
That is the third time in this file that a new table or counter has gone in
without being cleared at start-up — `SATAB`'s row stride and `ADYNF` were the
others. The habit worth having: when a new variable is added to the generator,
find the routine that zeroes the rest and put it there in the same edit.

## READ into an array of strings

`READ D$(J)` came to the string-variable path, looked for a plain variable
called `D$`, did not find one, and said UNKNOWN VARIABLE about a name the
program had dimensioned. `GLETSTR` has always made the right test — a bracket
after the `$` makes it an array — and `GREAD` simply did not. It does now, and
the element is filled the same way `INPUT` fills one: the address is worked
out and put away first, because fetching the item runs the parser over the
accumulator.

## POS

`POS(x)` is `CH` at `$24`, counted from zero. Asked on the machine, because
the obvious guess is the column `HTAB` takes and it is not: after `HTAB 10`,
`POS(0)` is 9 while `PEEK(36)` is 11 — the eleven being where the cursor had
got to by the time the second item of the same `PRINT` was evaluated. The
argument is evaluated and dropped, as Applesoft drops it.

## CLEAR, and the three ways it went wrong

`CLEAR` forgets every variable, every array, the string heap, the DATA pointer
and the GOSUB stack. A compiled program has all of those, laid out rather than
allocated, so `CLEAR` is the prologue done again at run time — except that the
prologue writes zeros into the image and this has to write them into memory.

**It cannot be one sweep** from the first variable to the code. The array base
slots, the array break and the collector's run table sit in between, and carry
addresses LAYOUT worked out that nothing at run time could rebuild. So two
ranges are zeroed — `VARBASE..CONSTBASE` and `ZFILLA..CODESTA` — and the rest
is put back by hand.

**The break moves back with them**, and this is the part that matters. ARGO
says `CLEAR : GOSUB 5100`, and 5100 has `DIM A(N)` in it. Zeroing the
variables without moving the break back would allocate a fresh copy on every
pass and run out of memory rather than start again.

**The stack is restored first**, because `SPSAVE` lives inside the second
range and is about to be zeroed; it is saved again after. Applesoft discards
pending GOSUBs on CLEAR the same way.

Three things went wrong, and the interpreter comparison found all three:

1. **A trailing `RTS`.** It was written as a subroutine and emitted inline, so
   it returned out of the program; the compiled run stopped dead at the CLEAR.
2. **The allocator's floor could not be reset here.** `HBNDLO`/`HBNDHI` are
   not known when CLEAR is emitted, because `HALLOC` is a helper emitted after
   the code — the stores went to a stale address. They are gone: the next
   dynamic DIM sets the floor from the new break, so leaving it raised until
   then is correct rather than merely convenient.
3. **A stale `FACSGN`.** A variable zeroed in place has had no floating point
   operation performed on it, so the ROM's sign byte still held the sign of
   whatever was last in `FAC`, and the first `PRINT` of a cleared variable came
   out as `-0`. Applesoft never meets this: its CLEAR forgets the variable
   rather than zeroing it, and the next reference builds a fresh one through
   the arithmetic. CLEAR zeroes `$A2` now.

The helper is 121 bytes and its branch offsets are COMPUTED, in the script
that generates the emitter, rather than counted by eye. The last helper whose
offsets were worked out by hand had three of them wrong.

**And a third dispatch list.** `CLEAR` pushed `GSTMT2`'s tests past the reach
of its own jump table, exactly as the first list had overflowed into the
second. `GSTMT3` is where the next one goes.

Three things there were checked rather than assumed: all three element paths —
assignment, `INPUT`, and read — go through `EMSSUBS`, so there is one place to
change; the stride is read BEFORE `NEXPR` runs, because compiling an
expression can leave `TMPA` pointing at a different array; and the stride is
written on every `SATAB` entry including one-dimensional ones, because the
table is not cleared at start-up and a stale slot would be multiplied by.

## Low-resolution graphics

`GR`, `COLOR=`, `PLOT`, `HLIN ... AT`, `VLIN ... AT`. The ROM does the drawing:
`SETGR` for the mode, `SETCOL` to spread a colour across both nibbles, and
`PLOT`/`HLINE`/`VLINE` with the coordinates in the registers they expect. The
first coordinate of each is kept in scratch rather than on the stack, because
what sits between it and the next one is a whole expression, and expressions
use the stack.

### Testing something that does not print

The agreement harness compares the text screen, and these statements draw
somewhere else. So the test draws, reads the screen memory back with `PEEK`,
returns to `TEXT`, and prints the numbers — the comparison is still ordinary
text, but what it is comparing is what the two programs drew.

Two harness faults came out of that, both mine, and both because the graphics
page is less uniform than it looks:

**Leftover pixels are text.** Once `TEXT` switches back, the cleared graphics
area is reinterpreted as characters — `$00` is an inverse `@` — and the two
runs had scrolled that leftover by one row. The numbers all matched; the test
was comparing scroll history. The screen is read before it is cleared, so
clearing it before printing removes the noise without weakening the check.

**`$400-$7FF` is not all screen.** Every 128-byte block holds an eight-byte
hole that is never displayed — sixty-four bytes in all — used by peripheral
firmware and ProDOS, and their contents differ between two runs for reasons
that have nothing to do with the program. Summing the whole page therefore
compares that too. Summing forty bytes from each line base covers every byte a
statement can draw to and no byte it cannot.

Both times the real signal was already visible: the individually sampled bytes
agreed, and only the totals that included non-drawing memory did not.

## High-resolution graphics

`HGR`, `HCOLOR=`, `HPLOT`. A hi-res column runs to 279 and so does not fit in
a byte: unlike every coordinate above it, both halves of the integer are kept
and handed to `HPOSN` as the low in X and the high in Y, with the row in A.

### Reading the ROM rather than remembering it

The first two attempts drew nothing at all — a sum of zero over a page the
`HGR` had plainly cleared, which is what plotting in black looks like.

`HCOLOR=` was established the usual way, by asking the machine: a program that
snapshotted the zero page either side of one showed `$E4` going to `$7F` for
colour 3, the white mask. So the compiled program carries the eight masks and
sets the byte itself, rather than calling a ROM entry whose address could not
be confirmed.

That was right and still drew nothing, because **the plotting routine reads a
different byte**. `PEEK` reaches ROM where the emulator's own memory dump does
not, so the bytes at `$F457` came back and disassembled to:

    JSR $F411 : LDA $1C : EOR ($26),Y : AND $30 : EOR ($26),Y : STA ($26),Y : RTS

The colour comes from `$30`, not `$E4`. Setting only `$E4` left every point
drawn in whatever `$30` held, which after `HGR` is zero. The mask goes to both
now.

The same four lines showed the other thing: **`$F457` calls `HPOSN` itself**.
Every point was being positioned twice, which was harmless only by luck.

The habit this project keeps returning to, pointing the other way for once:
the remembered ROM addresses looked like the risky part and the emitted code
like the sure thing, and reading the ROM showed the code was right and the
model of what those routines *do* was wrong.

### HPLOT ... TO

`HPLOT x,y`, `HPLOT x,y TO x,y TO x,y`, and `HPLOT TO x,y` continuing from
wherever the last one ended.

**The line routine takes its registers the other way round from HPOSN**, which
is not something to guess at: `HPOSN` reads the row from A and the column from
X and Y; `$F53A` reads the column from A and X and the row from Y. Peeked out
of the ROM and disassembled — it opens by subtracting `$E0` and `$E1`, the
position `HPOSN` last stored, which is what makes it a line *from where the
pen is* rather than between two given points.

## Four things to reach for sooner

Each of these was arrived at late in a session that had already spent runs on
the same bug. They are written down because the cost of not using them is
measured in emulator runs, and each run is a minute and a half.

### 1. Read the ROM with PEEK

The emulator's own memory dump stops at `$BFFF` and refuses anything above it,
so the ROM looks unreadable. It is not: `PEEK` reaches it from the Apple side.
A program that prints twenty-eight bytes from an address, disassembled here,
answers what a routine actually does.

This settled three separate faults in one afternoon, each after a remembered
address had failed:

- `SETHCOL`'s address could not be confirmed, so `HCOLOR=` now sets the mask
  itself from a table the compiled program carries.
- The plotting routine reads its colour from `$30`, not the `$E4` that
  `HCOLOR=` writes. Setting only `$E4` drew every point in black.
- The line routine's registers are the reverse of `HPOSN`'s.

The general form: **when a ROM call does not do what it is supposed to, read
it.** Not another remembered address, and not another guess at the convention.

### 2. Print a marker before reasoning about which routine ran

When the machine's behaviour contradicts the source, the source is not the
thing to read. A unique error code, or a letter printed at each step, names
the routine in one run.

The two occasions to compare: the `:go` scope bug took **eight** runs of
re-reading a dispatcher, token table and message table that were all correct,
because the conclusion "this cannot happen" kept sending me back to the text.
The string-array hang took **two** — one to learn it was pass 3 and which
line, one more to learn it was `EMSAGET`.

A marker also answers questions inference cannot. `ABCD` in pass 2 and `ABC`
in pass 3 named the routine *and* the fact that the passes differed, which is
what identified a loop counter held in `X` across `JSR EMIT`.

### 3. Disassemble the compiled output

The source says what was meant; the output says what was emitted. Two bugs
were obvious on sight and invisible in the source:

- `ADC $8DA1` — an absolute opcode given a one-byte zero-page operand, so the
  instruction swallowed the byte after it.
- `JSR $6066` — a call to a function's save slot rather than its body,
  because the address had been parked in a variable another routine used as
  scratch.

`tools/ac -g <image> <file>` pulls a compiled program off the disk and the
scratch disassembler reads it. Worth doing whenever a compiled program does
something a compiler bug would not obviously explain — running to the wrong
place, printing nothing, returning at once.

## The constant table was corrupting itself past sixty-three entries

Found by a user's program, not by the suite, and it had been there all along.

`CSLOT` works out where constant N lives as `CTAB + 5*N`, and did it by hand:

    lda TMPA / sta TMPB / asl / asl / clc / adc TMPB

The second `asl` puts the top bit into carry and **the `clc` that follows
throws it away**. So from entry 64 — where four times the index first passes
255 — the address wraps and every constant lands on top of an earlier one.
Entry 64 wrote over entry 12.

Nothing complained, because nothing was out of range: the address computed was
a perfectly legal address for a different entry. Pass 1 stored the value, pass
2 looked it up and found something else there, and reported `CANNOT READ THAT`
against whichever line happened to need the lost constant.

`SLOTN` exists precisely because this multiply had been written by hand four
times and drifted. `CSLOT` was a fifth copy, spelled differently enough to
escape that cleanup, and it now carries properly.

**Why thirty-three passing tests never found it.** The largest test program
has a couple of dozen constants. Sixty-four distinct numeric literals is a
real program — `LITTLE` reaches a hundred and twenty-four, most of them from
lines that poke a machine-code routine in byte by byte. A limit that only
bites at scale needs a test at scale, and the suite has none.

### And the codes that shared a message

Seven sites raised `$0c`, all reporting `CANNOT READ THAT`, which named the
category and hid the place. They are three messages now — `CANNOT READ THAT`
for an expression that will not parse, `BAD SUBSCRIPT` for an array index, and
`BAD FUNCTION ARGUMENT` for the brackets around one.

Finding the site took giving all eleven a distinct number temporarily. Codes
above `NMSG` already print as a bare number, so that needed no message table
at all — a fallback built for unknown codes turning out to be the fastest
debugging tool in the compiler.

## Keywords the compiler supports in a form real programs do not use

`BRIAN` stopped at line 320, `NEXT S,X`, reporting `STATEMENT NOT YET #05`.
`NEXT` had been on the supported list since the first FOR loop worked. What
was not supported was `NEXT` taking a *list* of variables, so the comma was
reached as though it began a statement of its own.

`LITTLE` had failed the same way one line earlier in the alphabet: line 2140
is `Q=I=LL=J=...`, a chained comparison, and `=` was long since supported.

Both are the same mistake, and it is a mistake about **testing**, not about
6502. The suite's programs were written to exercise features, one per test,
by someone who knew which features existed. Every one of them uses `NEXT I`,
because that is what `NEXT` looks like when you are testing `NEXT`. Real
Applesoft was written against the interpreter, where `NEXT S,X` costs less
than two `NEXT`s and everyone knew it, and so it appears constantly.

A checklist of keywords cannot show this gap, because the keyword is present
in both cases. Only a program somebody actually wrote can. Two of them found
two holes within an hour of each other, after thirty-three hand-written tests
had found none.

**`NEXT S,X` is exactly `NEXT S` then `NEXT X`** — the loops close innermost
first — so the generator simply goes round again while a comma follows. By
that point the first loop is already off the FOR stack, which is what makes
the second name match the loop enclosing it rather than the one just closed.

The test uses `A*100 + B*10 + C` summed over three nested loops, rather than a
plain count: a wrong nesting order, or a loop closed twice, changes the total,
where a count could come out right for the wrong reason.

### Chained comparison

`A = B = C` is one expression, not two, and Applesoft reads it left to right
as `(A = B) = C`: relational operators share a precedence and associate
leftwards. `ECMPC` read a sum, then *at most one* operator, so the second `=`
was left unread and came back as a statement — `STATEMENT NOT YET`, pointing
at an expression.

The loop that fixes it is three instructions of thought and none of new
machinery. `MATCMP` already turns a just-emitted comparison into a plain 1 or
0 in FAC, and a value sitting in FAC with nothing pending is exactly the shape
`ECMPC`'s existing left-hand side takes on its `:infac` path. So a chain is:
emit the comparison, materialise it, go back and look for another operator.

Two invariants make that safe, and both were already true rather than
arranged:

- `PENDOK` is 0 wherever the `CMP` is emitted — one path sets it explicitly,
  the other can only have arrived with it clear — and `MATCMP` does not
  disturb it. So the materialised value really is in FAC, not pending at some
  address.
- `MATCMP` clears `GOTCMP` and the next turn sets it again, so the *last*
  comparison in the chain is the one the caller materialises. `EXPR` needs no
  changes.

The test checks the associativity, not just the parse, and picking cases for
that takes care — most chains give the same answer folded either way.
`2 > 1 > 0` is 1 left-associatively and 1 right-associatively; so is
`1 = 1 = 1`, and so is `A = B = 0`. They prove nothing.

What does discriminate, with `A` and `B` both 5 and `C` 1:

    A = B = C     left  ((5=5)=1) = (1=1) = 1
                  right (5=(5=1)) = (5=0) = 0

and with `D` 3 and `E` 4, `D < E = 1` is 1 leftwards and 0 rightwards. The
suite runs both, and the interpreter arbitrates.

Chaining after a *string* comparison (`A$ = B$ = 0`) still goes through
`SCMPC`, which has no such loop. Legal Applesoft, not yet compiled, and it
refuses by name rather than compiling it wrongly.

## Where the compiled program loads

`CODEORG` was `$6000` for as long as the compiler has existed, chosen so that
a program could use hi-res without anyone having to think about it: `$6000` is
above both graphics pages, `$2000-$3FFF` and `$4000-$5FFF`.

It costs every program the 18K underneath it, and `LITTLE` is the program that
made that matter. It compiles to 18,426 bytes against the 13,824 that `$6000`
leaves below BASIC.SYSTEM at `$9600`, and it uses **no hi-res at all** — its
graphics are lo-res, and lo-res page 1 is `$400-$7FF`, below anything we would
ever choose.

So the address is picked per program now, by `PICKORG`, from what pass 1 saw:

| what the program uses | CODEORG | room |
|---|---|---|
| `HGR2` | `$6000` | 13,824 |
| `HGR`/`HPLOT`/`HCOLOR=`/`DRAW`/`XDRAW` | `$4000` | 22,016 |
| neither | `$0C00` | 35,328 |

`$0C00` and not `$0800`, because lo-res page 2 is `$800-$BFF`.

It runs between pass 1 and `LAYOUT`: by then every token has been seen and not
one address has been fixed. Three things had to stop being assembly-time
constants — the eleven `#<CODEORG` loads, `LAYOUT`'s `CODEORG+3` (which had to
become a real add, since `ORG+3` is a different *byte*, not a different
address), and the `aux_type` in the CREATE parameter block, which is the
address BRUN restores the file to. Get that last one wrong and the program
loads somewhere its own JMPs do not point.

The compiler itself did not have to move: `EMIT` streams into a 256-byte
buffer and flushes to disk, so the image is never held at the address it is
being built for, and `PC` is only a counter.

### What the scan cannot see

A program that reaches hi-res by poking `$C057` uses no hi-res token, would be
placed at `$0C00`, and would draw over its own code. This is not hypothetical:
`BRIAN` pokes `-16298` itself, to turn hi-res off.

So there is an override, and it wins outright: `REM $ORG=6000`, four hex
digits, anywhere in the program. A later one beats an earlier one.

### The tokeniser was tokenising REM text

The directive did not match, and the reason was not in the compiler.
`bench/tokenise.py` tokenised the whole line, so `REM $ORG=6000` came out with
`$D0` — the `=` token — where the ASCII `=` should be, and a matcher reading
REM text could never see it.

Applesoft stores a comment exactly as typed. That is not a recollection: it is
44 REMs across `BRIAN` and `LITTLE`, two programs off a real disk, with **zero**
tokens inside any of them. The test tokeniser had been producing files no
Apple would have written, which had not mattered until something wanted to
read REM text.

### And the pattern was in the wrong ASCII

With the tokeniser fixed the directive still did nothing, and the compiled
`ORGDIR` came out at `$0C00` rather than the `$6000` its REM asked for.

`ORGPAT asc "$ORG="`. In Merlin, **double quotes mean high ASCII** and single
quotes mean low. A REM's text is low ASCII, so the pattern could not match a
single character of it -- not the `$`, not anything. One character of
punctuation, and the whole feature was inert while looking perfectly correct.

The convention is not obscure and this codebase already writes it down, in
`ops.S`: `asc 'BASIC.SYSTEM'   ; single quotes: ProDOS wants LOW ascii`.

What made it cheap to find was that the test reads back the `aux_type` ProDOS
stamped on the output rather than trusting that the right thing happened --
`CORGDIR ... A=$0C00` is unambiguous in a way that "it compiled" is not. The
check is worth more than the feature: three of the four addresses were right,
and nothing but reading them back would have said which.

    CBRIAN   A=$4000     uses HGR
    CLITTLE  A=$0C00     no hi-res at all
    CORGDIR  A=$6000     REM $ORG=6000
    CORGHR   A=$4000     uses HGR

### Three branches that stopped reaching

Adding the scan inline pushed `SCANBODY`'s trampolines out of branch range,
one after another — `:rem`, then `:dataj`, then the rest. The fix that worked
was not a longer chain of hops but taking the new code out of `SCANBODY`
altogether: `SKIPREM` and `NOTEHR` are their own routines, costing one `JMP`
and one `JSR`, and every distance inside `SCANBODY` went back to what it was.

`ECMPC` needed the other kind of fix, two hops, because its growth was in the
middle of a routine that genuinely wanted to be one. Both are placed where
nothing can fall into them wrongly — which this file already documents four
instances of getting wrong.

### 4. Read the program, not a list of its keywords

Added after `BRIAN` and `LITTLE`, because a keyword checklist said both were
fully supported and both failed to compile.

The gap a checklist cannot show is a supported keyword used in an unsupported
*form*: `NEXT` with a list of variables, `=` chained. Both keywords had been
implemented for months. What found them, in the end, was detokenising the
programs and scanning their raw token bytes:

    tools/detok.py little.bas                    # the program, as text
    tools/detok.py --tokens brian.bas little.bas # every token, by frequency

Scan the BYTES, not the detokenised text. The first attempt grepped the
listing for keyword spellings and reported `ONERR`, `STOP` and `DRAW` as
things the compiler would need — all three were words inside REM comments.
Half an hour of implementing `ONERR` would have bought nothing at all.

The byte scan also settles questions no amount of reasoning does: whether
`LITTLE` uses hi-res (it does not, which is what let it load at `$0C00`), and
whether Applesoft tokenises REM text (it does not, which is what made
`REM $ORG=` possible and what exposed the test tokeniser's bug).

### What running the real programs proved that the suite could not

`BRIAN` and `LITTLE` were compiled and then actually run, which is a different
question from whether they compile and a different one again from whether the
suite passes.

`LITTLE`'s instructions screen draws its asterisk border with

    2160 COLOR= 10: VLIN 1,46 AT 0: VLIN 0,47 AT 39

in TEXT mode. Lo-res page 1 and text page 1 are the same memory, `$400-$7FF`;
`COLOR= 10` writes `$AA`; `$AA` is what the character generator shows as `*`.
A 1979 trick, and it only comes out right if the compiled `COLOR=` and `VLIN`
put exactly the bytes in exactly the places the ROM would. A test that checked
printed output could not have asked that question, and neither could one that
compared a lo-res screen in lo-res mode.

`LITTLE` also pokes its cursor straight into the screen at line 2450 --
`POKE PEEK(40) + PEEK(41)*256 + PEEK(36), 96` -- which reads BASL, BASH and CH
out of zero page. That comes out in the right cell only if the compiled VTAB
and HTAB leave the same zero page behind them that Applesoft's do.

Neither of those is a thing anyone would think to write a test for. Both are
ordinary technique in a program written in 1979, and running one real program
asked both questions at once.

## Runtime array sizing

`DIM A(N)`, where `N` is not known until the program runs. The compiler laid
arrays out at compile time and baked each one's base address into every
subscript as an immediate, so a size that only exists at runtime had nowhere
to go. `RETRIEVE.TEXT` does `INPUT I : DIM A$(I)` and was refused.

The memory arrangement it fits into is Applesoft's own, and the compiled
program already had most of it:

    ORG    +-------------------+
           | data, code, helpers|
    FINPC  +-------------------+
           |   arrays grow up   |
           |                    |
           |  strings grow down |
    HIMEM  +-------------------+   from $73/$74, as the prologue reads it

The string heap already grew down from HIMEM and refused to pass `FINPC`.
Arrays growing up from `FINPC` meet it from the other side, so the only thing
that changes is *which* number the allocator refuses to pass: a compile-time
constant becomes a cell the two share.

### Every array through a base slot, including the ones that did not need it

Two bytes per array in the image, and a subscript loads from there instead of
carrying an immediate. Done for all arrays rather than only the dynamic ones,
because one path is easier to be sure of than two, and it costs two bytes and
a load. They sit IN FRONT of `TEMPBASE`: the prologue zero-fills everything
from there to the code, and these carry real addresses.

Proved as a refactor before anything dynamic was built -- same arrays, same
addresses, one more indirection, and the suite still agreeing -- so that a
later failure could only be about the new part.

### The same bug three times in one afternoon

A value in shared scratch, live across a call that scratches the same place.
This file already documents `CPT`/`EMCOPY5`, `TMPP`/`EMIT` and `CPT`/`NEXPR`,
and writing the base-slot code produced three more without the lesson once
occurring to me:

- the prologue's loop counted in `TMPA` across `JSR AADDR`, and `ASUM` --
  which `AADDR` calls -- writes `TMPA` as it goes
- `EMSETRUN` counted its padding in `X` across `JSR EMIT`, and `EMIT` puts the
  output length in `X` on its way to the buffer

The first hung the compiler outright: the counter was reset to one every time
round, so it never reached the array count.

**A correction, because the first version of this section had it wrong.** I
also "fixed" two places for holding an address in `TMPP` across `JSR EMIT`,
and wrote that `EMIT` clobbers `TMPP` when it flushes. It does not. `EMSSUBS`
and the old array-subscript site have held `TMPP` across `EMIT` since the
beginning, through eighteen-kilobyte outputs where `FLUSH` runs seventy times,
and the compiler works. What is true is narrower: the routines that COMPUTE
those addresses -- `AADDR`, `ABSLOT`, `SAADDR` -- work in `TMPP`, so calling
one between emitting the low byte and the high byte loses the first. The
copies are still there because they make that impossible to get wrong, but the
reason in the comments now says so.

The rule that would have caught them, stated as a question to ask before
writing the call rather than after: **what does the routine I am about to call
use as its scratch, and is anything of mine in there?** `TMPA`, `TMPB`, `TMPP`
and `CPT` are the four that keep doing this, and `X` is the fifth. None of
them belongs to a caller.

And its converse, which the wrong version of this section ignored: **check
before you believe a routine clobbers something.** Code that has worked for
months is evidence. Two of the three "bugs" here were not bugs.

### A lone Q, in the corner of the screen

The first working `DIM A(N)` printed the right answers and then left a `Q` on
the screen, thirty-two columns along, after the prompt.

`Q` is `$D1` in high ASCII, and `$D1` was the low byte of the array break.
`HDIMB` ends by writing the new break into the heap allocator's floor -- the
two bytes the allocator refuses to bring the heap below -- and `EMHALLOC`
records where those bytes landed only when the heap is emitted at all. A
program with arrays and no strings has no heap, so nothing recorded them, and
the write went to whatever address was left over. That address was in the text
page.

The floor now defaults to the array break itself, so with no heap present the
write lands on the value it has just stored and does nothing.

Worth keeping for what made it findable rather than what it was: a wild store
into `$400-$7FF` is the only kind that puts its own evidence on the screen in
a readable font. The same store a page lower would have corrupted the program
quietly, and the same bug in a program that used strings would never have
fired at all -- the allocator would have been there and the address correct.
It showed up because the test was the simplest possible one.

## The collector's roots became a list of runs

`DIM A$(N)` was the half of runtime array sizing that needed the collector.
A string array's elements are descriptors, and every descriptor is a root: if
a collection walks past them, every string the array holds is left pointing at
memory that has moved. The roots were one unbroken run, counted in a single
byte, both loaded into the collector as immediates -- and an array that does
not exist when the layout is fixed cannot be in it.

So the roots are a TABLE of runs now. Entry 0 is the static one the layout
already knew; each `DIM A$(N)` fills in one more as it allocates.

### Not one branch offset moved

The collector is 237 emitted bytes with about nineteen hand-counted branch
offsets, and it is the part of this compiler where a mistake is hardest to
see. Rewriting it was the obvious approach and the wrong one.

What the disassembly showed instead was that each of its two root walks begins
with a thirteen-byte initialisation and ends with `DEC count / BNE back`:

    a9 ?? 85 1a  a9 ?? 85 1b  a9 ?? 8d ?? ??     pointer, then count
    ...
    ce ?? ??  d0 9c                              one fewer; round again

Both have exact-length replacements. `JSR SETRUN` and ten `NOP`s is thirteen
bytes; `JSR MORE` is three, as `DEC abs` was. Four edits, no byte moved, and
every offset in that routine is still the one that was counted when it was
written.

`MORE` returns with Z clear while any descriptor remains anywhere in any run,
so the `BNE` that was already there needed no changing either.

### And the 255 limit went with it

`MORE` hands a run out in chunks of 128 and keeps a sixteen-bit remainder --
the pointer walks on by itself between chunks, since the collector advances
it, so only the count is reloaded. The one-byte root count is gone, for the
static run as much as the dynamic ones.

### And one the passing test did not catch

`HSDIMB` takes the run number in `X` and called `AYINT` -- Applesoft's
FAC-to-integer, which reaches `QINT` -- before reading it. `AYINT` promises
nothing about `X`.

The test agreed with the interpreter anyway. That proves only that the path
the ROM took for that particular value left `X` alone; another value could
take a different one, write the run table entry at the wrong offset, and
corrupt the collector's roots -- which is the least visible failure available
in this program. Found by reading the code after it passed, not because
anything went wrong.

The question that catches these is the same one as always, asked this time of
a routine in ROM rather than one of ours: **what does the thing I am about to
call use as its scratch?**

### Two bugs the tools caught before the machine did

`scopecheck.py` refused `HRUNB jmp :more`: a local label on a global label's
own line resolves in the PREVIOUS scope. That quirk cost eight runs to find
the first time; the check written from it found this one instantly, and again
later for `HDADDRA`.

The other was mine to catch by reading: `EMSETRUN` counted its ten `NOP`s in
`X` across `JSR EMIT`, and `EMIT` puts the output length in `X` on its way to
the buffer. The same bug this file already documents, in a routine written to
avoid counting mistakes.

### INPUT A$(J)

`RETRIEVE.TEXT` got past `DIM A$(I)` and stopped at line 70, `INPUT A$(J)`,
with `UNKNOWN VARIABLE` -- about a line that plainly names an array.

`GINPUT` dispatched on the `$` straight to its string-variable path, which
looks the name up among the string VARIABLES and does not find an array there.
`GLETSTR` makes the test that was missing: a bracket after the `$` makes it an
element. Once it does the same, the rest is machinery that already existed --
`SAFIND`, `EMSSUBS`, `EMSASAVE`, then the input item copied to the heap and
`EMSAPUT` to store the descriptor.

Two things make it safe for an array whose size is not known until it runs:
`EMSASAVE` keeps the element's address in the program's own scratch rather
than zero page, so it survives the copy and any collection that copy sets off;
and the array's descriptors never move in a collection, because they are not
in the heap.

### Six routines split in one day

`SKIPREM`, `NOTEHR`, `EMTABGO`, `GDIMDYN`, `SDYNDIM`, `GINSARR` -- every one
of them taken out of its parent because adding to that parent put its own
branches out of reach, and every one of them found by the assembler refusing
rather than by thinking about it first.

The parents are the dispatch routines -- `SCANBODY`, `GPRINT`, `GINPUT`, the
DIM block -- and they are all near their limit. The lesson, six instances in:
**anything added to one of those should start as its own routine.** It costs a
JSR and saves a round trip through the assembler every time.

## A buffer that climbed into ProDOS

Growing DBUF to 6,912 bytes meant moving the ProDOS buffers off the top of the
tables. Two went low, to $0800 and $0C00; the rest went under ProDOS at $BB00.

    DATBUF 512  OUTBUF 256  PFXBUF 64  ONLBUF 16  ONBUF 80  STRBUF 256

That is 1,184 bytes, and $BB00 + 1,184 is $BF9F. The global page starts at
$BF00. STRBUF -- where a string literal is collected before it is emitted --
ran a hundred and sixty bytes into the MLI's own vectors.

The comment written beside the block said 848 bytes and named four buffers.
There are six. Having written the wrong number, the thing reasoned from
afterwards was the comment rather than the source.

**It does not fail like a memory bug.** Compiling a program whose literals are
long enough overwrote ProDOS; the next MLI call came back wrong; and the
compiler ended up executing its own message table, arriving in the monitor at
$87DB with nothing to say for itself. RANDOM did that. RETRIEVE.TEXT, compiled
in the same run, was fine -- its literals are shorter.

### What found it

Not the crash address, which was a dead end -- $87DB is inside `BADGET`'s
text. It was ruling out the new code: `DIM A$(9),B(9),C(9),D(9)` was the one
construction in RANDOM that had never been compiled before, so that got a test
of its own, and it passed. With the new code cleared, what was left was the
layout, and the layout is arithmetic that can be checked without the machine.

### dumcheck.py knows about $BF00 now

It compared the blocks with each other, which is what it was written for, and
had nothing whatever to say about one of them climbing into ProDOS. It does
now -- and the check was verified by putting the bad address back and watching
it report `INTO PRODOS: $bb00-$bf9f DATBUF`. A guard that has never been seen
to catch its bug is not yet a guard.

## STOP, PR#, SAVE, and a convention not checked

The last three statements PHONE.LIST wanted.

**STOP** prints `BREAK IN nnnn` and ends. Established on a //e, along with the
fact that it starts on a line of its own -- and the mid-line case was left for
the suite to arbitrate rather than guessed: a program that stops after
`PRINT "TWO";` agrees, so the leading newline really is conditional on the
cursor's column. The line number is known while it compiles, so the whole
message goes out as characters.

**PR#** is the monitor's `OUTPORT` at `$FE95`, slot in A. Read off the ROM,
not recalled -- `PEEK` and a disassembly showed it storing `$Cn00` into CSW,
or the `$F0xx` default back for slot 0.

**SAVE** compiles to nothing and says so, by name and line. A bare SAVE writes
the BASIC program to tape and a compiled program has none; emitting the ROM's
tape routine would write whatever the Applesoft pointers happen to span and
produce a tape that will not load, which is worse than an error anybody can
see. PHONE.LIST has two, both on the tape branch of a disk-or-tape choice a
ProDOS machine never takes.

### Four handlers written against an assumption

All three, plus `POP` from earlier in the day, began with `jsr NEXTB` to
"consume the token". The token is already consumed: `GENSTMT` reads it and
`CH` holds it, which is why `GHOME`, `GTEXT` and `GEND` start straight in.
So each of them ate the byte AFTER the statement -- for `PR#` the first byte
of its slot expression, for the others the line's terminating zero, after
which the statement loop read on into the next line's link bytes and tried to
compile them. `IF A = 2 THEN STOP` reported `UNKNOWN VARIABLE`.

**`POP` had been wrong for hours and was reported as working.** PHONE.LIST
never compiled far enough to reach one, and no test used it -- so nothing
contradicted the claim. There is a `popf` test now, which GOSUBs, POPs, and
jumps past the line a RETURN would have come back to.

The rule this breaks is one already written down a few sections above, about
believing a routine clobbers something without checking: **check the
convention against a caller that already works.** `GHOME` and `GEND` were
three lines away in the same file and would have settled it in seconds.

### PR# cannot be tested against the interpreter, and here is why

The obvious test -- `PR# 0`, print something, compare -- fails, and the
interpreter is the side that looks strange:

    interpreted             compiled
    #30 AFTER               AFTER
    #40 #50 #60 STILLHERE   STILLHERE
    #70 DONEPRN             DONEPRN

Those are the test's own line numbers. A bare `PR#` from a program under
ProDOS sets CSW directly, which tears BASIC.SYSTEM's output hook out from
under it; BASIC.SYSTEM notices between statements and re-announces itself with
`#` and the line. It is an artifact of the INTERPRETER'S statement loop, and a
compiled program has no statement loop for it to happen in.

Before dropping the test, the question worth settling was whether the
compiler's PR# is right. Applesoft's own handler, read off the machine at
$F1E5:

    20 F8 E6    JSR $E6F8     GETBYT -- a byte from the program text, into X
    8A          TXA
    4C 95 FE    JMP $FE95     OUTPORT

That is the whole of it, and the compiler emits the same thing: the expression
as a byte in A, then `JSR OUTPORT`. So the implementation is faithful and the
disagreement is not about the compiler at all.

**The test is deleted rather than kept failing or quietly excluded.** No PR#
test can agree under ProDOS, because agreeing would mean the compiled program
imitating BASIC.SYSTEM's confusion. What stands in for it is this note and the
disassembly above -- and PHONE.LIST, which uses `PR# SL` and `PR# 0` to drive
a printer and compiles.

A test that cannot pass for a reason outside the thing being tested is worse
than no test: it trains you to ignore a red line.

## A program that keeps its data inside itself

PHONE LIST, off the DOS 3.3 System Master, compiles and runs. Type in a name
and a number and the list stays empty.

Nothing is wrong with the compiled code. The program stores its records in its
own DATA statements and edits them in place:

    510  START = PEEK(103) + PEEK(104) * 256 + 458    TXTTAB, the program text
    4320 LN = PEEK(123) + PEEK(124) * 256             DATLIN, the DATA line READ
    4360 CU = START + ((LN - 201) * 46)               that line, in memory
    4420 POKE I, ASC(MID$(NN$, I + 1 - CU, 1))        write the record into it

and the count of records lives in line 200, `DATA 1000`, which gets a new
number poked over it. Saving the program is what saves the phone book -- which
is also why line 840 is a bare cassette SAVE.

A compiled program has no Applesoft program in memory. `PEEK(103)` returns
BASIC.SYSTEM's idea of where a BASIC program would start, which has nothing to
do with the compiled code; the pokes land somewhere harmless and the count
READ back is for ever the 1000 that is in the file. The entry is accepted and
has nowhere to go.

**This cannot be compiled, and not for want of a feature.** The source is what
a compiler consumes; it is not there afterwards to be rewritten. Even the
arithmetic is Applesoft's own -- `(LN - 201) * 46` is the length of a DATA
line in APPLESOFT's line format, two bytes of link, two of line number, one of
token and forty-one of text. Nothing the compiler could lay out would make
that stride mean anything.

### So it says so, and says which lines

`NOTEPK` watches the source for a PEEK of 103, 104, 123 or 124 -- the four
addresses that describe an Applesoft program in memory -- and names the first
line that reads each. Not a refusal: reading a byte of zero page is legal and
a program might do it innocently. But never silent, because nothing else about
the failure tells you anything at all.

It stays quiet on BRIAN, LITTLE, RANDOM and RETRIEVE.TEXT, every one of which
uses PEEK constantly for the keyboard at -16384 and the speaker at -16336. A
warning that appears on every program teaches you to stop reading warnings.

### Three tries to make a state machine see a number

Worth keeping for the pattern rather than the detail, because all three were
assumptions about code that could have been read in seconds:

- hooked into SCANBODY's byte loop. SCANBODY reads ONE byte, recognises the
  start of a number, and hands the rest to its own scanner without coming
  back, so `PEEK(103)` arrived as a 1;
- moved to RDBYTE, the real funnel, and used ISDIGIT to test the byte. ISDIGIT
  reads CH -- which the CALLER sets, after RDBYTE returns -- so it answered
  about the previous byte and no digit was ever recognised;
- printed the notes where pass 1 noticed them, which put them ahead of the
  line and variable and constant listings. They scrolled off the top.

What actually moved it along was writing the state machine in Python first and
running it over the file: six hits, so the ALGORITHM was right and the fault
had to be in the 6502 or the hook. That halved the search in one step, and it
is the same move that settled TAB('s semantics and the DOS sector map -- get
the answer somewhere cheap, then make the machine agree with it.

### And two things that had to be right inside RDBYTE

Every byte of every pass goes through it, so a mistake there is not a wrong
warning but a wrong compilation:

- **not on the pushed-back path.** A byte read again after PUTBACK would be
  counted twice and 103 would come out as 1033;
- **the carry.** RDBYTE promises it clear on success and NOTEPK's own compares
  destroy it, so the `clc` goes after the call.

## LEMONADE, and four limits it found

Four things stopped it, each invisible until the one before was fixed.

**A hundred and twenty-eight constants was not enough.** It has about two
hundred and fifty. Raising CMAX meant finding room: the tables ended at $B9BF
with the next block sixty-four bytes above them, so the ProDOS buffers moved
to $1700 -- the variable blocks stop at $1610 and the compiler's own code does
not begin until $2000, so there was 2.5K sitting unused down there the whole
time.

**NCONST COUNTS THEM IN ONE BYTE**, so 255 is the ceiling and LEMONADE is
close to it. Going further means widening that counter through every loop that
walks the constant table, and through CSLOT -- which is where this compiler's
subtlest bug lived, the lost carry that put entry 64 on top of entry 12.

**`^`** is Applesoft's own FPWRT at $EE97, not EXP(y * LOG(x)). The two agree
until the base is zero: LOG(0) has no answer, and LEMONADE squares a price,
which is zero whenever the stand has sold nothing.

**`FRE`** is the gap between the array break and the string heap -- a compiled
program already tracks both ends. Signed, through GIVAYF, which is why
Applesoft's own FRE goes negative with more than 32K free. LEMONADE writes
`I = FRE(0)` and then uses I as a loop counter: the value is not the point,
the collection it forces is.

**`LOMEM:`** compiles to nothing and says so. A compiled program's memory was
settled before it ran.

### Applesoft binds unary minus TIGHTER than ^

`-2^2` is **4**. Not -4, which is what C, Python and most BASIC dialects give,
and what this compiler gave when `^` was put where every other language puts
it -- above negation rather than below.

The suite said so on the first run and the fix was to swap two levels of the
expression parser. Worth keeping because it is the clearest case all session
of reasoning from what is usual producing a confident wrong answer. The
machine costs one test to ask.

Left-associative, incidentally: `2^3^2` is 64, not 512. That one the guess got
right, which is exactly why guessing is not a method.

### Both ROM addresses came off the machine

FPWRT was confirmed by what it does first -- `BEQ` on ARGEXP, which is what
CONUPK leaves in A, so the calling convention is visible in the opening
instruction. CONUPK was found by disassembling FMUL, which is FAC times
memory and must therefore begin by unpacking that memory into ARG. Its first
three bytes are `20 E3 E9`.

Neither was looked up. This compiler has been wrong about a recalled ROM
address before.

## BIORHYTHM is Integer BASIC

It reported `DEF FN HEADER` in line 27825, a line the program has not got.
Integer BASIC holds a line as a length and a number where Applesoft holds a
link and a number, so read as Applesoft the first line of BIORHYTHM is
numbered 25600 and everything after is noise.

ProDOS knows what the file is. GET_FILE_INFO before the open costs nothing and
the compiler now says `THAT IS INTEGER BASIC, NOT APPLESOFT`.

**Only $FA is refused.** A tokenised Applesoft program can arrive typed BIN or
TXT or as nothing in particular, and refusing those would turn working
compiles into errors.

### One message, not three

The first version printed the truth and then two falsehoods:

    THAT IS INTEGER BASIC, NOT APPLESOFT
    CANNOT OPEN THE SOURCE
    01

The file opened perfectly well. A failure had been faked to stop the compile,
and the error path reported the fake faithfully. An error that says two
contradictory things is worse than a terse one, because now the reader has to
work out which half to believe.

That is the fourth message this session where the code knew something true and
printed something else -- with `1 copied, and that came to 0 files` when
nothing was copied, `ONE DIMENSION ONLY` about an array with one dimension,
and a fault reported in a line that does not exist.
