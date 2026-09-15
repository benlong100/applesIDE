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

### The statement list was full

`GENSTMT`'s keyword tests reached their targets with little to spare, and
adding to the front of the list pushed the ones at the back out of branch
range — four separate build failures, each naming a different innocent
statement. The answer was not more trampolines but a second list, which the
first falls through to when it does not recognise a keyword. It costs one jump
for the keywords that reach it, leaves the first list alone, and is where
anything added later should go.

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
