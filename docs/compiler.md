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
| BENCH1 | 33.78s | 6.14s | 5.5× | 4501500 |
| BENCH2 | 66.73s | 6.04s | 11.0× | 4501500 |
| BENCH3 | 38.88s | 6.11s | 6.4× | 4501500 |
| BENCH4 | 71.53s | 6.14s | 11.6× | 4501500 |
| BENCH5 | 26.80s | 4.40s | 6.1× | 3000 |

Every answer is the interpreter's own.

**The compiled times barely move across the first four** — 6.04 to 6.14, a
spread of a tenth of a second across programs whose interpreted times run from
33 to 71 seconds. That is the whole claim made visible: what differs between
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

### Every program carries the whole runtime

A compiled program gets the array helper, the string helpers, the heap and the
collector whether it uses them or not — about 900 bytes on a program that
never touches a string. Pass 1 already knows which features a program uses, so
this is bookkeeping rather than a design problem, and it is worth doing: it is
most of the difference between a 300-byte binary and an 1,100-byte one.

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

### What it compiles

`LET` (named or implied), `DIM` and one-dimensional arrays, `GOTO`, `GOSUB`,
`RETURN`, `IF ... THEN` and `IF ... GOTO`, `FOR` / `NEXT` with `STEP`,
`ON ... GOTO`, string variables and literals with assignment, comparison and
`LEN`, `LEFT$`, `RIGHT$`, `MID$`, `ASC`, `CHR$`, `STR$` and joining with `+`,
`PRINT` of numbers and strings with `;` and `,`, `REM`, `END`, and expressions over `+ - * /`, unary minus,
brackets, the six comparisons, `AND` / `OR` / `NOT`, and the eleven numeric
functions.

Not yet: `VAL`, `DATA`/`READ`, `INPUT`, `ON ... GOSUB`, `PEEK`/`POKE`,
`DEF FN`, the graphics statements, arrays of more than one dimension, and
arrays of strings. Each
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
