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
| BENCH1 | 33.77s | 9.09s | 3.7× | 4501500 |
| BENCH2 | 66.70s | 9.00s | 7.4× | 4501500 |
| BENCH3 | 38.84s | 9.28s | 4.2× | 4501500 |
| BENCH4 | 71.56s | 9.73s | 7.4× | 4501500 |
| BENCH5 | 26.83s | 6.96s | 3.9× | 3000 |

Every answer is the interpreter's own.

**The compiled times barely move across the five**, and that is the whole
claim made visible. What differs between those programs is the line search and
the variable scan; compiling does not reduce them, it removes them. BENCH4 is
the realistically shaped one, and it is the one that gains most.

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

### What it compiles

`LET` (named or implied), `GOTO`, `GOSUB`, `RETURN`, `IF ... THEN`, `FOR` /
`NEXT` with `STEP`, `PRINT` of numbers and string literals with `;`, `REM`,
`END`, and expressions over `+ - * /`, unary minus, brackets and the six
comparisons.

Not yet: arrays, strings as values, `DATA`/`READ`, `INPUT`, `AND`/`OR`, the
functions, `ON ... GOTO`, and `,` in a `PRINT`. Each is refused with a code
rather than compiled wrongly — a compiler that carried on would write a
program that ran and gave a wrong answer, which is the one outcome worse than
refusing.

### The gap to the hand-compiled model, and what closes it

The model did BENCH1 in 7.25s; the compiler's output does it in 9.09s. The
difference is one thing: `IF I < 3000` compiles the comparison into a proper
Applesoft value — it materialises 1 or 0 in the accumulator — and then `IF`
tests that value. The model branched straight off `FCOMP`'s answer.

Producing a value is the right general behaviour, since Applesoft lets a
comparison BE one. Closing the gap means recognising the common case, where an
`IF`'s expression is a single top-level comparison, and branching directly.
That is a peephole, not a redesign, and it is the obvious next piece of work
on speed.

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
