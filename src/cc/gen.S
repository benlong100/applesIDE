*--------------------------------------
* GEN.S -- passes 2 and 3: turn the program into 6502
*
* The same code runs twice. In pass 2 EMIT counts bytes and throws them away,
* so every line's address gets recorded without any branch target being known;
* in pass 3 it writes them, and the targets come out of the table pass 2 built.
* A JMP is three bytes whatever it jumps to, which is what makes the two
* passes produce identical addresses.
*
* WHAT THE COMPILED PROGRAM LOOKS LIKE
*
*   $6000  JMP CODESTART      so BRUN enters at the front and still finds it
*   $6003  the variables      five bytes each, zero as loaded
*          the constants      five bytes each, converted in pass 1
*          eight temporaries  for the middle of an expression
*          one byte           the stack pointer as the program was entered
*   CODESTART
*          TSX / STX          so END can get back to BASIC from inside a GOSUB
*          the code
*
* Data first because pass 1 can size it and cannot size the code.
*
* EVALUATION. Everything arrives in the floating point accumulator. A binary
* operator evaluates its LEFT side, parks it in a temporary, evaluates its
* right side into the accumulator, and then applies the operation naming the
* temporary. That order is not a preference: the ROM's subtract and divide
* compute memory MINUS accumulator and memory OVER accumulator, so the left
* operand has to be the one in memory. Written the obvious way round, every
* subtraction and division in every compiled program would come out backwards
* and the benchmark would still have printed a plausible number.
*--------------------------------------

FCOMP        equ   $ebb2            ; 1 greater, 255 less, 0 equal

*--- FAC to a signed 16-bit integer and back. Both read off a running machine:
*    a round trip of -1234 through the pair comes back as -1234 with the high
*    byte in $A0, and as 12027 with the bytes the other way round -- which is
*    the sort of wrong that looks like a number.
AYINT        equ   $e10c            ; FAC -> signed integer in FACHI/FACLO
GIVAYF       equ   $e2f2            ; A high, Y low -> FAC, signed
FACHI        equ   $a0
FACLO        equ   $a1
FACEXP       equ   $9d              ; zero is the only way a float is zero

*--- Six bytes of zero page for the COMPILED program -- four for the address
*    helper below, two for an element address being held across an assignment.
*    $1A-$1F belongs to the hires routines, which a compiled program does not
*    call; it is clear of the floating point at $9D-$A5, of COUT's screen
*    pointers at $24-$29, and of the MLI at $40-$4F. The compiler's own TMPP
*    sits at $1A as well, which is harmless: the two never run at once.
ZPB          equ   $1a
ZPELEM       equ   $1e
COUTA        equ   $fded
CHCOL        equ   $24              ; the cursor's column
WNDWDTH      equ   $21              ; and how wide the window is

NTEMPS       equ   8
FDEPTH       equ   8                ; nested FOR loops

*--- The string runtime's scratch, past the collector's roots:
*    0 MID$'s start, 1-2 the heap pointer, 3-4 a join's destination,
*    5 its length, 6-7 where the collector is moving to, 8-9 the best
*    descriptor it has found, 10-11 that string's address, 12 its length,
*    13 how many descriptors are left to look at, 14-15 which part of a
*    string a slice wants, 16-17 a POKE's address across its value.
SCRASZ       equ   18

TFORK        equ   $81
TNEXT        equ   $82
TLET         equ   $aa
TGOTOK       equ   $ab
TIF          equ   $ad
TGOSUBK      equ   $b0
TRETURN      equ   $b1
TPRINT       equ   $ba
TEND         equ   $80
TPLUS        equ   $c8
TMINUS       equ   $c9
TSTAR        equ   $ca
TSLASH       equ   $cb
TGT          equ   $cf
TEQ          equ   $d0
TLT          equ   $d1
TTO          equ   $c1
TSTEP        equ   $c7
TNOT         equ   $c6
TDIMK        equ   $86
TON          equ   $b4
TLEN         equ   $e3
TASC         equ   $e6
TCHR         equ   $e7
TSTR         equ   $e4
TPEEK        equ   $e2
TVAL         equ   $e5
TPOKE        equ   $b9
TCALL        equ   $8c
GETADR       equ   $e752            ; FAC -> unsigned 16 bits in $50 and $51
TLEFT        equ   $e8
TRIGHT       equ   $e9
TMID         equ   $ea
ONMAX        equ   40
TAND         equ   $cd
TOR          equ   $ce

*--------------------------------------
* Strings, as far as they go without a heap
*
* A string value is a DESCRIPTOR: one byte of length and two of pointer, which
* is what Applesoft uses too. Assignment copies the three bytes rather than
* the text, so A$ = B$ leaves both pointing at the same characters -- again
* what Applesoft does.
*
* NOTHING IS ALLOCATED, and that is what makes this increment self-contained.
* A literal's characters are emitted into the compiled program and the
* descriptor points at them; a variable's descriptor is copied from another.
* Joining two strings, or CHR$ and LEFT$ and the rest, all have to MAKE a
* string, and that needs somewhere to put it and something to reclaim it --
* which is the next piece of work, not this one.
*
* SDA and SDB are two descriptor slots in the compiled program's data. The
* comparison helper reads both; everything else uses SDA.
*--------------------------------------

*--- TMPP = the first descriptor slot
SDAADDR      lda   SDESCA
             sta   TMPP
             lda   SDESCA+1
             sta   TMPP+1
             rts

SDBADDR      lda   SDESCA
             clc
             adc   #$03
             sta   TMPP
             lda   SDESCA+1
             adc   #$00
             sta   TMPP+1
             rts

*--- SDA IS THE ONLY PLACE A STRING VALUE IS EVER BUILT.
*
*    It used to be built wherever the statement wanted it -- straight into the
*    variable for an assignment, into SDB for the right of a comparison. That
*    works while a string is only ever copied, and stops working the moment
*    anything OPERATES on one: LEFT\$ has to be told where its string is, and
*    an address chosen by the statement is not something a JSR can carry.
*
*    So every string value lands in SDA, and the two places that want it
*    somewhere else copy it there afterwards. The copy is six bytes; the
*    alternative is a pointer argument on every string helper for ever.
SDSET        lda   TMPP             ; TMPP -> DSTA, for EMSDESC
             sta   DSTA
             lda   TMPP+1
             sta   DSTA+1
             rts

*--- the string variable table, which pass 1 filled
SVFIND       lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NSVARS
             bcs   :no
             asl
             tax
             lda   SVTAB,x
             cmp   VN0
             bne   :step
             lda   SVTAB+1,x
             cmp   VN1
             beq   :yes
:step        inc   TMPA
             jmp   :loop
:yes         clc
             rts
:no          lda   #$0d
             jsr   SETBAD
             sec
             rts

*--- emit the two bytes of TMPP
EMADDR       lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jmp   EMIT

*--------------------------------------
* EMSDESC -- emit code copying the three bytes at SRCA to DSTA
*--------------------------------------
EMSDESC      lda   #$00
             sta   EMI
:byte        lda   #$ad             ; LDA abs
             jsr   EMIT
             lda   SRCA
             clc
             adc   EMI
             sta   TMPP
             lda   SRCA+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$8d             ; STA abs
             jsr   EMIT
             lda   DSTA
             clc
             adc   EMI
             sta   TMPP
             lda   DSTA+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             inc   EMI
             lda   EMI
             cmp   #$03
             bcc   :byte
             rts

*--------------------------------------
* EMSLIT -- a literal: its characters, and a descriptor pointing at them
*
* The text is stored with its high bits CLEAR, the way Applesoft stores a
* string, so that comparing two of them compares the same bytes the
* interpreter would. The print helper puts the bit back on its way to COUT.
*--------------------------------------
EMSLIT       lda   #$00
             sta   STRLEN
:read        jsr   NEXTB
             bcc   :got
             jmp   :bad
:got         sta   CH
             bne   :notend
             jmp   :unterm
:notend      cmp   #'"'
             beq   :have
             ldx   STRLEN
             cpx   #$ff
             bcc   :put
             jmp   :toolong
:put         lda   CH
             and   #$7f
             sta   STRBUF,x
             inc   STRLEN
             jmp   :read

:have        lda   #$4c             ; JMP over the text
             jsr   EMIT
             lda   PC               ; which begins past the two address bytes
             clc
             adc   #$02
             sta   STRAT
             lda   PC+1
             adc   #$00
             sta   STRAT+1
             lda   STRAT
             clc
             adc   STRLEN
             sta   TMPP
             lda   STRAT+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR

             lda   #$00
             sta   EMI
:text        ldx   EMI
             cpx   STRLEN
             bcs   :desc
             lda   STRBUF,x
             jsr   EMIT
             inc   EMI
             jmp   :text

*--- LDA #len / STA dest, and the pointer after it
:desc        lda   #$a9
             jsr   EMIT
             lda   STRLEN
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             jsr   SDAADDR
             jsr   EMADDR

             lda   #$a9
             jsr   EMIT
             lda   STRAT
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS

             lda   #$a9
             jsr   EMIT
             lda   STRAT+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             clc
             rts

:toolong     lda   #$0b
             jsr   SETBAD
             sec
             rts
:unterm      lda   #$0a
             jsr   SETBAD
:bad         sec
             rts

*--------------------------------------
* EMPUSHSD / EMPULLSD -- SDA on and off the 6502 stack
*
* LEFT\$(A\$, LEN(B\$)) is why. Every string value is built in SDA, so working
* out the count builds B\$ there and A\$ is gone. The stack costs twelve bytes
* each way and survives any depth of that, which a second slot would not.
*--------------------------------------
EMPUSHSD     lda   #$00
             sta   EMI
:b           lda   #$ad             ; LDA SDA+n
             jsr   EMIT
             lda   EMI
             jsr   EMSDOFS
             lda   #$48             ; PHA
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #$03
             bcc   :b
             rts

EMPULLSD     lda   #$02
             sta   EMI
:b           lda   #$68             ; PLA
             jsr   EMIT
             lda   #$8d             ; STA SDA+n, in the order they come back
             jsr   EMIT
             lda   EMI
             jsr   EMSDOFS
             dec   EMI
             bpl   :b
             rts

*--- emit an absolute address of SCRA + A
EMSCOFS      clc
             adc   SCRA
             sta   TMPP
             lda   SCRA+1
             adc   #$00
             sta   TMPP+1
             jmp   EMADDR

*--- and the count of descriptors the collector has to walk
EMNDESC      lda   NSVARS
             clc
             adc   #$02
             jmp   EMIT

*--- emit an absolute address of SDESCA + A
EMSDOFS      clc
             adc   SDESCA
             sta   TMPP
             lda   SDESCA+1
             adc   #$00
             sta   TMPP+1
             jmp   EMADDR

*--------------------------------------
* EMHSPR -- the helper that prints the descriptor in SDA
*
* Thirty-four bytes, counted from this layout rather than guessed:
*
*    0  LDA SDA+1      3      the pointer, into the zero page where an
*    3  STA ZPB        2      indirect can reach it
*    5  LDA SDA+2      3
*    8  STA ZPB+1      2
*   10  LDA #0         2      the index, in memory because COUT does not
*   12  STA ZPB+2      2      keep Y
*   14  LDY ZPB+2      2   <- loop
*   16  CPY SDA        3      the length
*   19  BCS done       2   -> 33
*   21  LDA (ZPB),Y    2
*   23  ORA #$80       2      stored high-bit-clear, printed high-bit-set
*   25  JSR COUT       3
*   28  INC ZPB+2      2
*   30  JMP loop       3   -> 14
*   33  RTS            1
*--------------------------------------
EMHSPR       lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB+1
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #ZPB+2
             jsr   EMIT

             lda   #$a4             ; the loop, at +14
             jsr   EMIT
             lda   #ZPB+2
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$0c
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$09
             jsr   EMIT
             lda   #$80
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #ZPB+2
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HSPR
             clc
             adc   #$0e
             sta   TMPP
             lda   HSPR+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHSCMP -- compare SDA with SDB, answering as FCOMP does
*
* THE LEFT SIDE IS IN SDB and the right in SDA, which is the other way round
* from how it reads: every string value is built in SDA, so the left has to
* move aside before the right is built on top of it.
*
* 1 if the RIGHT side is the greater, $FF if it is the lesser, 0 if they are
* the same -- which is FCOMP's convention with the left operand in memory, so
* CMPWANT and CMPSENS mean exactly what they already meant.
*
* Byte by byte, and a string that runs out first is the lesser: "AB" < "ABC"
* and "AB" is not "AB ". Read off the machine before this was written.
*
*    0  LDA SDB+1   3      the left pointer into ZPB
*    3  STA ZPB     2
*    5  LDA SDB+2   3
*    8  STA ZPB+1   2
*   10  LDA SDA+1   3      and the right into ZPB+2
*   13  STA ZPB+2   2
*   15  LDA SDA+2   3
*   18  STA ZPB+3   2
*   20  LDY #0      2
*   22  CPY SDB     3   <- loop: has the left run out?
*   25  BCS aend    2   -> 43
*   27  CPY SDA     3      has the right, with the left still going?
*   30  BCS rless   2   -> 51
*   32  LDA (ZPB),Y 2
*   34  CMP (ZPB+2),Y 2
*   36  BCC rgreat  2   -> 54
*   38  BNE rless   2   -> 51
*   40  INY         1
*   41  BNE loop    2   -> 22
*   43  CPY SDA     3   <- aend: the left ended; is there more right?
*   46  BCC rgreat  2   -> 54
*   48  LDA #0      2      both ended together
*   50  RTS         1
*   51  LDA #$FF    2   <- rless
*   53  RTS         1
*   54  LDA #$01    2   <- rgreat
*   56  RTS         1
*--------------------------------------
EMHSCMP      lda   #$ad
             jsr   EMIT
             lda   #$04
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$05
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB+1
             jsr   EMIT

             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB+2
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB+3
             jsr   EMIT

             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT

             lda   #$cc             ; 22: the loop
             jsr   EMIT
             lda   #$03
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$13
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$d1
             jsr   EMIT
             lda   #ZPB+2
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$0b
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$eb
             jsr   EMIT

             lda   #$cc             ; 43: the left ran out
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$90
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$60
             jsr   EMIT

             lda   #$a9             ; 51: the right is the lesser
             jsr   EMIT
             lda   #$ff
             jsr   EMIT
             lda   #$60
             jsr   EMIT

             lda   #$a9             ; 54: the right is the greater
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHASC -- ASC: the first character as a number
*
* An EMPTY STRING is a divergence: Applesoft says ILLEGAL QUANTITY and this
* reads whatever the pointer happens at, which for a string never assigned is
* address zero. Harmless, and wrong, and written down rather than left to be
* found.
*--------------------------------------
EMHASC       lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPB+1
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$a8             ; TAY -- the low byte
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   #<GIVAYF
             jsr   EMIT
             lda   #>GIVAYF
             jmp   EMIT

*--------------------------------------
* EMMSG -- a run-time message: high ASCII, a return, and a zero
*--------------------------------------
EMMSG        sta   STRPTR
             sty   STRPTR+1
             lda   #$00
             sta   EMI
:loop        ldy   EMI
             lda   (STRPTR),y
             beq   :end
             ora   #$80
             jsr   EMIT
             inc   EMI
             jmp   :loop
:end         lda   #$8d
             jsr   EMIT
             lda   #$00
             jmp   EMIT

MSGOOM       asc   "?OUT OF MEMORY ERROR"
             dfb   $00
MSGLONG      asc   "?STRING TOO LONG ERROR"
             dfb   $00

*--------------------------------------
* EMHERR -- say what went wrong at run time, and stop
*
* A\$ = A\$ + \"X\" in a loop will run out of string space eventually, and a
* compiled program has to say so rather than write over its own code. The
* message address comes in A and Y; the stack pointer the prologue saved is
* what gets it back to BASIC.
*
*    0  STA ZPB     2
*    2  STY ZPB+1   2
*    4  LDA #0      2      the index, in memory: COUT does not keep Y
*    6  STA ZPB+2   2
*    8  LDY ZPB+2   2   <- loop
*   10  LDA (ZPB),Y 2
*   12  BEQ done    2   -> 22
*   14  JSR COUT    3
*   17  INC ZPB+2   2
*   19  JMP loop    3   -> 8
*   22  LDX SPSAVE  3   <- done
*   25  TXS         1
*   26  RTS         1
*--------------------------------------
EMHERR       lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$84
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$a4
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$08
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$fd
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HERR
             clc
             adc   #$08
             sta   TMPP
             lda   HERR+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$ae
             jsr   EMIT
             jsr   SPADDR
             jsr   EMADDR
             lda   #$9a
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHCHR -- CHR$: one byte, allocated
*
* Stored as given and printed with its high bit set, which is what Applesoft
* does -- CHR$(65) and CHR$(193) both print A there and both print A here.
*--------------------------------------
EMHCHR       lda   #$a9
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             jsr   EMIT
             lda   HALLOC+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$84
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$8c
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$a5
             jsr   EMIT
             lda   #$a1
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHJOIN -- A$ + B$
*
* The LEFT side is in SDB and the right in SDA, as with the comparison: every
* string value is built in SDA, so the left has to move aside before the right
* is built on top of it.
*
* Over 255 characters is ?STRING TOO LONG ERROR, which is what Applesoft says.
*
*    0  LDA SDB      3      the two lengths
*    3  CLC          1
*    4  ADC SDA      3
*    7  BCC ok       2   -> 16
*    9  LDA #<msg    2
*   11  LDY #>msg    2
*   13  JMP HERR     3
*   16  STA JOINLEN  3   <- ok
*   19  JSR HALLOC   3
*   22  STA JOINDST  3      keep the base: SDA is still the right operand
*   25  STA ZPELEM   2      and cannot be written until it is copied
*   27  STY JOINDST+1 3
*   30  STY ZPELEM+1 2
*   32  LDA SDB+1    3      copy the left
*   35  STA ZPB      2
*   37  LDA SDB+2    3
*   40  STA ZPB+1    2
*   42  LDY #0       2
*   44  CPY SDB      3   <- l1
*   47  BCS d1       2   -> 56
*   49  LDA (ZPB),Y  2
*   51  STA (ZPELEM),Y 2
*   53  INY          1
*   54  BNE l1       2   -> 44
*   56  TYA          1   <- d1: Y is the left's length exactly
*   57  CLC          1
*   58  ADC ZPELEM   2
*   60  STA ZPELEM   2
*   62  BCC n1       2   -> 66
*   64  INC ZPELEM+1 2
*   66  LDA SDA+1    3   <- n1: copy the right after it
*   69  STA ZPB      2
*   71  LDA SDA+2    3
*   74  STA ZPB+1    2
*   76  LDY #0       2
*   78  CPY SDA      3   <- l2
*   81  BCS d2       2   -> 90
*   83  LDA (ZPB),Y  2
*   85  STA (ZPELEM),Y 2
*   87  INY          1
*   88  BNE l2       2   -> 78
*   90  LDA JOINLEN  3   <- d2: and only now the descriptor
*   93  STA SDA      3
*   96  LDA JOINDST  3
*   99  STA SDA+1    3
*  102  LDA JOINDST+1 3
*  105  STA SDA+2    3
*  108  RTS          1
*--------------------------------------
EMHJOIN      lda   #$ad
             jsr   EMIT
             lda   #$03
             jsr   EMSDOFS
             lda   #$18
             jsr   EMIT
             lda   #$6d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$90
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   MLONG
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   MLONG+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HERR
             jsr   EMIT
             lda   HERR+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             jsr   EMIT
             lda   HALLOC+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$03
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$8c
             jsr   EMIT
             lda   #$04
             jsr   EMSCOFS
             lda   #$84
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$04
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$05
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$03
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$f4
             jsr   EMIT
             lda   #$98
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$65
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$f4
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$03
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$04
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHSTR -- STR$: a number as its characters
*
* FOUT leaves a zero-terminated string at $0100, which is counted, allocated
* for and copied. The same routine PRINT uses for a number.
*
*    0  JSR FOUT     3
*    3  LDX #0       2
*    5  LDA $0100,X  3   <- count
*    8  BEQ got      2   -> 14
*   10  INX          1
*   11  JMP count    3   -> 5
*   14  TXA          1   <- got
*   15  STA JOINLEN  3
*   18  JSR HALLOC   3
*   21  STA ZPELEM   2
*   23  STA SDA+1    3
*   26  STY ZPELEM+1 2
*   28  STY SDA+2    3
*   31  LDA JOINLEN  3
*   34  STA SDA      3
*   37  LDY #0       2
*   39  CPY JOINLEN  3   <- copy
*   42  BCS done     2   -> 52
*   44  LDA $0100,Y  3
*   47  STA (ZPELEM),Y 2
*   49  INY          1
*   50  BNE copy     2   -> 39
*   52  RTS          1
*--------------------------------------
EMHSTR       lda   #$20
             jsr   EMIT
             lda   #$34
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$a2
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$bd
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$04
             jsr   EMIT
             lda   #$e8
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HSTR
             clc
             adc   #$05
             sta   TMPP
             lda   HSTR+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$8a
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             jsr   EMIT
             lda   HALLOC+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$84
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$8c
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$08
             jsr   EMIT
             lda   #$b9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$f3
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHGC -- the garbage collector
*
* Applesoft's own method: repeatedly find the live string sitting highest
* below where the last one was moved to, slide it up against it, and lower the
* boundary. Quadratic in the number of descriptors, of which there are at most
* sixty-six, for something that runs only when the heap is full.
*
* THE ROOTS ARE ONE UNBROKEN RUN: SDA, SDB, then three bytes per string
* variable, which is why the layout puts them together. SDA and SDB are roots
* because a collection happens inside an allocation, in the middle of an
* expression -- a join holds its left side in SDB and its right in SDA.
*
* A descriptor pointing below the floor is a literal in the compiled program's
* own text and never moves. One comparison tells them apart.
*
* EVERY DESCRIPTOR POINTING AT THE MOVED STRING IS UPDATED, not just the one
* that won the search. Two can hold the same address -- A\$ = B\$ makes two,
* and C\$ = C\$ + \"C\" leaves the join's saved left side aliasing C\$ exactly.
* Updating one of them left the other pointing at the old address, which the
* next round found and moved again, on top of something else. That is what
* made A\$ and B\$ print as CCC.
*
* The copy runs high to low: the destination is at or above the source, and a
* block moved upward over itself has to be copied from its end.
*--------------------------------------
EMHGC        lda   #$a5
             jsr   EMIT
             lda   #$73
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$06
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$74
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$07
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   SDESCA
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   SDESCA+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             jsr   EMNDESC
             lda   #$8d
             jsr   EMIT
             lda   #$0d
             jsr   EMSCOFS
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$4e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$c9
             jsr   EMIT
             lda   FINPC+1
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$3e
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c9
             jsr   EMIT
             lda   FINPC
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$36
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$07
             jsr   EMSCOFS
             lda   #$90
             jsr   EMIT
             lda   #$09
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$2d
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$06
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$26
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$90
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$09
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$90
             jsr   EMIT
             lda   #$16
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$14
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$08
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$09
             jsr   EMSCOFS
             lda   #$18
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$69
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$ce
             jsr   EMIT
             lda   #$0d
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$9c
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$0d
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$f0
             jsr   EMIT
             lda   #$7d
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$08
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$09
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0c
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$06
             jsr   EMSCOFS
             lda   #$38
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$0c
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$07
             jsr   EMSCOFS
             lda   #$e9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1d
             jsr   EMIT
             lda   #$ac
             jsr   EMIT
             lda   #$0c
             jsr   EMSCOFS
             lda   #$88
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$f7
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   SDESCA
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   SDESCA+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             jsr   EMNDESC
             lda   #$8d
             jsr   EMIT
             lda   #$0d
             jsr   EMSCOFS
             lda   #$a0
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$0a
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$13
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$0b
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$0b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$69
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$ce
             jsr   EMIT
             lda   #$0d
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$d4
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$06
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$07
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HGC
             clc
             adc   #$0a
             sta   TMPP
             lda   HGC+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$ad
             jsr   EMIT
             lda   #$06
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$07
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHALLOC -- take bytes off the top of the heap, collecting if it must
*
*   try; if that failed, collect and try once more; if that failed, say so
*
* Once only: a collection that did not free enough will not free more for
* being run again.
*--------------------------------------
EMHALLOC     lda   #$8d
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             clc
             adc   #$1b
             sta   TMPP
             lda   HALLOC+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$90
             jsr   EMIT
             lda   #$0f
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             clc
             adc   #$18
             sta   TMPP
             lda   HALLOC+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             clc
             adc   #$1b
             sta   TMPP
             lda   HALLOC+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$90
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   MOOM
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   MOOM+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HERR
             jsr   EMIT
             lda   HERR+1
             jsr   EMIT
             lda   #$60
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HGC
             jsr   EMIT
             lda   HGC+1
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$38
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$05
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS
             lda   #$e9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$c9
             jsr   EMIT
             lda   FINPC+1
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$c9
             jsr   EMIT
             lda   FINPC
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS
             lda   #$a4
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$60
             jsr   EMIT
             lda   #$38
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--- JSR AYINT: the number in the accumulator as an integer
EMAYINT      lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jmp   EMIT

*--------------------------------------
* EMHSLICE -- what LEFT$, RIGHT$ and MID$ all end with
*
* SLOFF and SLLEN say which part of the string in SDA is wanted; this
* allocates that many bytes and copies them, and SDA comes out pointing at a
* block of its own.
*
* IT HAS TO COPY, and I had it sharing. A substring that points into the
* middle of another string is a pointer the collector cannot fix up: it finds
* strings by the address they start at, and an interior pointer matches
* nothing. So the parent moves and the substring is left pointing at whatever
* is there now. Applesoft copies here, and this is why.
*
* The source pointer is read AFTER the allocation, deliberately: allocating
* may collect, and a collection may move the very string being sliced. SDA is
* a root, so by then it says where the text went.
*--------------------------------------
EMHSLICE     lda   #$ad
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$04
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$60
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   HALLOC
             jsr   EMIT
             lda   HALLOC+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$03
             jsr   EMSCOFS
             lda   #$84
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$8c
             jsr   EMIT
             lda   #$04
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$18
             jsr   EMIT
             lda   #$6d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$69
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$f4
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$03
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$04
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$60
             jmp   EMIT

*--- LEFT$: from the start, for as many as asked or as many as there are
EMHLEFT      lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$0d
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$a1
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jmp   EMIT

*--- RIGHT$: the last so many, which is an offset and the same length
EMHRIGHT     lda   #$a5
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$17
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$a1
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$b0
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$38
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jmp   EMIT

*--- MID$: from a place, for a length, both clamped to what is there.
*    MID$(A$,0) is an error in Applesoft and is treated here as 1.
EMHMID       lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   #$ee
             jsr   EMIT
             lda   #$00
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSCOFS
             lda   #$38
             jsr   EMIT
             lda   #$e9
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$90
             jsr   EMIT
             lda   #$0b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$38
             jsr   EMIT
             lda   #$ed
             jsr   EMIT
             lda   #$0e
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$0a
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$a1
             jsr   EMIT
             lda   #$cd
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$0f
             jsr   EMSCOFS
             lda   #$4c
             jsr   EMIT
             lda   HSLICE
             jsr   EMIT
             lda   HSLICE+1
             jmp   EMIT

*--------------------------------------
* EMHPEEK -- PEEK: a byte from anywhere in memory
*
* GETADR, not AYINT. AYINT is signed and refuses anything above 32767, which
* would rule out every address a PEEK is usually interested in -- $C000 and
* up. GETADR gives an unsigned sixteen bits in $50 and $51: read off the
* machine, where 49152 comes back as 0 and 192.
*--------------------------------------
EMHPEEK      lda   #$20
             jsr   EMIT
             lda   #$52
             jsr   EMIT
             lda   #$e7
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$50
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$51
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a8
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   #$f2
             jsr   EMIT
             lda   #$e2
             jmp   EMIT

*--------------------------------------
* EMHPOKE -- POKE: the tail of it, after both sides have been worked out
*
* The address is kept in the program's own scratch rather than the zero page,
* because working out the value in between can be an array subscript or a
* string operation, and both of those use the zero page the address would
* have been sitting in.
*--------------------------------------
EMHPOKE      lda   #$20
             jsr   EMIT
             lda   #$52
             jsr   EMIT
             lda   #$e7
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$10
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$11
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$50
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHCALL -- three bytes that turn an address in the zero page into a call
*
* JSR HCALL pushes the return, HCALL jumps through ZPB, and the RTS at the
* other end comes back to the instruction after the JSR. CALL and ON..GOSUB
* both need exactly this and neither needs anything more.
*--------------------------------------
EMHCALL      lda   #$6c
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$00
             jmp   EMIT

*--------------------------------------
* EMHVAL -- VAL: a number out of a string, parsed by the ROM
*
* FIN parses a number from wherever Applesoft's text pointer points, and is
* reached through CHRGET. Established on the machine: 123.5, -72, "  42" with
* the spaces skipped, and 7E2 as 700.
*
* TWO THINGS HAVE TO BE PUT BACK. The text pointer is Applesoft's own, so it
* is saved and restored -- otherwise the interpreter carries on from a pointer
* into our string. And a string here has a length, not a terminator, so the
* byte just past it is zeroed for the duration and restored after, or FIN
* reads straight on into whatever follows: VAL("12") with a 3 after it in the
* heap would be 123.
*
* The address of that byte is worked out twice rather than kept, because FIN
* is free to use any of the zero page it likes and the descriptor it comes
* from is not in the zero page.
*--------------------------------------
EMHVAL       lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$d0
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$a8
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   #$f2
             jsr   EMIT
             lda   #$e2
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$b8
             jsr   EMIT
             lda   #$48
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$b9
             jsr   EMIT
             lda   #$48
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$18
             jsr   EMIT
             lda   #$6d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$69
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$48
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$38
             jsr   EMIT
             lda   #$e9
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$b8
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$e9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$b9
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #$b1
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #$4a
             jsr   EMIT
             lda   #$ec
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$18
             jsr   EMIT
             lda   #$6d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$69
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$68
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$68
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$b9
             jsr   EMIT
             lda   #$68
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$b8
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* NEED -- record that the program uses something
*
* A compiled program used to carry the array helper, the string helpers, the
* heap and the collector whether it touched them or not: about nine hundred
* bytes on a program that never sees a string.
*
* PASS 2 ALREADY KNOWS. It generates every line before it emits a single
* helper, so a bit set at each call site is complete by the time the helpers
* go down -- and pass 3 sets the same bits from the same source and emits the
* same set, so the addresses pass 2 recorded still land where pass 3 puts
* them.
*
*   $01 arrays      $02 printing a string   $04 comparing two
*   $08 a substring $10 CHR$                $20 joining
*   $40 STR$        $80 ASC
*
* The heap and the collector come in with any of the four that allocate.
*--------------------------------------
NEED         ora   USES
             sta   USES
             rts

NEED2        ora   USES2
             sta   USES2
             rts

UHEAP        equ   $78              ; $08+$10+$20+$40: the ones that allocate

*--------------------------------------
* ARRBLOB -- base + 5 * index, the one piece of runtime a compiled program has
*
* Entered with the base in A and Y and the subscript already through AYINT, so
* it is in FACHI/FACLO. Leaves the element's address in A and Y, which is what
* MOVFM wants and one TAX short of what MOVMF wants.
*
* A SUBROUTINE, not code emitted at each subscript, and that is the only place
* this compiler does that. Inline it costs about forty-five bytes a subscript
* against thirteen; a program that walks an array in a loop has a dozen of
* them. The float printer and the string printer stay inline because a PRINT
* happens a handful of times in a program and a subscript happens everywhere.
*
* No branches and nothing absolute but the zero page, so it can be dropped
* wherever the layout puts it without a single fixup.
*--------------------------------------
ARRBLOB      dfb   $85,ZPB          ; STA base lo
             dfb   $84,ZPB+1        ; STY base hi
             dfb   $a5,FACLO
             dfb   $85,ZPB+2
             dfb   $a5,FACHI
             dfb   $85,ZPB+3
             dfb   $06,ZPB+2        ; ASL, ROL: twice round is four times
             dfb   $26,ZPB+3
             dfb   $06,ZPB+2
             dfb   $26,ZPB+3
             dfb   $18              ; CLC -- and the index once more is five
             dfb   $a5,ZPB+2
             dfb   $65,FACLO
             dfb   $85,ZPB+2
             dfb   $a5,ZPB+3
             dfb   $65,FACHI
             dfb   $85,ZPB+3
             dfb   $18              ; CLC -- then the base
             dfb   $a5,ZPB+2
             dfb   $65,ZPB
             dfb   $85,ZPB+2
             dfb   $a5,ZPB+3
             dfb   $65,ZPB+1
             dfb   $a8              ; TAY: the high byte
             dfb   $a5,ZPB+2        ; and the low in A
             dfb   $60
ARRBEND
HELPSZ       equ   ARRBEND-ARRBLOB

*--------------------------------------
* GENPASS -- run one pass over the source. PASSNO says which.
*--------------------------------------
GENPASS      lda   #$00
             sta   LINEI
             sta   LINEI+1
             sta   TEMPTOP
             sta   FORN
             sta   USES
             sta   USES2
             sta   FSTKTOP
             sta   PENDOK
             sta   OUTLEN
*--- Somewhere plausible for PASS 2, which emits calls to the helpers before
*    it knows where they will be. Only the SIZE of those calls matters there.
*
*    PASS 2 ONLY. Doing it every pass wiped the addresses pass 2 had recorded,
*    so pass 3 emitted JSR $6000 for every array subscript -- which is the
*    program's own entry, so it restarted itself for ever and printed nothing
*    at all. The same shape as a forward GOTO, and it needs the same care.
             lda   PASSNO
             cmp   #$02
             bne   :keep
             lda   #<CODEORG
             sta   HARR
             sta   HSCMP
             sta   HSPR
             sta   HLEFT
             sta   HRIGHT
             sta   HMID
             sta   HASC
             sta   HCHR
             sta   HJOIN
             sta   HSTR
             sta   HERR
             sta   HALLOC
             sta   HGC
             sta   HSLICE
             sta   HPEEK
             sta   HVAL
             sta   HPOKE
             sta   HCALL
             sta   MOOM
             sta   MLONG
             lda   #>CODEORG
             sta   HARR+1
             sta   HSCMP+1
             sta   HSPR+1
             sta   HLEFT+1
             sta   HRIGHT+1
             sta   HMID+1
             sta   HASC+1
             sta   HCHR+1
             sta   HJOIN+1
             sta   HSTR+1
             sta   HERR+1
             sta   HALLOC+1
             sta   HGC+1
             sta   HSLICE+1
             sta   HPEEK+1
             sta   HVAL+1
             sta   HPOKE+1
             sta   HCALL+1
             sta   MOOM+1
             sta   MLONG+1
:keep

             jsr   REWIND
             bcc   :ready
             jmp   :fail            ; :fail is a long way down this routine
:ready

             lda   #<CODEORG
             sta   PC
             sta   OUTBASE
             lda   #>CODEORG
             sta   PC+1
             sta   OUTBASE+1

*--- the JMP at the front, to the code that follows all the data
             jsr   CODEST
             lda   #$4c
             jsr   EMJ2

*--- the variables, zero, and the constants as pass 1 converted them
             lda   #$00
             sta   TMPA
:var         lda   TMPA
             cmp   NVARS
             bcs   :consts
             lda   #$05
             sta   EMI
:vz          lda   #$00
             jsr   EMIT
             dec   EMI
             bne   :vz
             inc   TMPA
             jmp   :var

:consts      lda   #$00
             sta   TMPA
:con         lda   TMPA
             cmp   NCONST
             bcs   :temps
             jsr   CSLOT
             lda   #$00
             sta   TMPB
:cb          ldy   TMPB
             lda   (TMPP),y
             jsr   EMIT
             inc   TMPB
             lda   TMPB
             cmp   #$05
             bcc   :cb
             inc   TMPA
             jmp   :con

*--- The temporaries, the FOR slots and SPSAVE, filled to the address LAYOUT
*    named rather than counted again here. If the two ever disagreed this
*    would not terminate, which is a louder failure than quietly starting the
*    code one byte out.
:temps       lda   PC
             cmp   CODESTA
             bne   :tz
             lda   PC+1
             cmp   CODESTA+1
             beq   :prologue
:tz          lda   #$00
             jsr   EMIT
             jmp   :temps

*--- The heap runs down from the top of free memory, read at run time rather
*    than assumed: MEMSIZ at $73 is $9600 under BASIC.SYSTEM with one file
*    buffer, and a compiled program leaves it alone. Read off the machine.
:prologue    lda   #$a5             ; LDA $73
             jsr   EMIT
             lda   #$73
             jsr   EMIT
             lda   #$8d             ; STA FRETOP
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$a5             ; LDA $74
             jsr   EMIT
             lda   #$74
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS

*--- remember where the stack was, so END can unwind a GOSUB
             lda   #$ba             ; TSX
             jsr   EMIT
             lda   #$8e             ; STX abs
             jsr   EMIT
             jsr   SPADDR
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT

*--- the program
:line        jsr   RDWORD
             bcs   :end
             lda   WORD
             ora   WORD+1
             beq   :end
             jsr   RDWORD           ; the line number, which pass 1 already has
             bcs   :end
             lda   WORD
             sta   CURLINE
             lda   WORD+1
             sta   CURLINE+1
             jsr   LTSETA           ; this line starts here
             jsr   GENLINE
             bcc   :next
             jmp   :fail            ; :fail is past the helpers now
:next        inc   LINEI
             bne   :line
             inc   LINEI+1
             jmp   :line

*--- falling off the end returns to BASIC, the same as END does
*--- ENDPC is where a false IF on the LAST line jumps: the ending itself.
:end         lda   PC
             sta   ENDPC
             lda   PC+1
             sta   ENDPC+1
             jsr   EMEND

*--- The runtime helpers, after all of the code.
*
*    AFTER, so that nothing has to predict how long they are. They were in
*    front of the code, which meant LAYOUT needed each one's size as a
*    constant and a helper that grew by a byte moved every line in the
*    program. Here each one records where it landed as it is emitted, and the
*    calls to it are resolved the same way a forward GOTO is: pass 2 puts
*    something plausible there, pass 3 puts the address pass 2 recorded.
*
*    AND ONLY THE ONES THE PROGRAM USES. USES was filled in as the code was
*    generated, above, so it is complete by now; pass 3 fills it in the same
*    way from the same source and emits the same set.

*--- the address helper, for a program with arrays
             lda   USES
             and   #$01
             beq   :noarr
             lda   PC
             sta   HARR
             lda   PC+1
             sta   HARR+1
             lda   #$00
             sta   EMI
:hb          ldy   EMI
             lda   ARRBLOB,y
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #HELPSZ
             bcc   :hb
:noarr

*--- comparing two strings, and printing one
             lda   USES
             and   #$04
             beq   :nocmp
             lda   PC
             sta   HSCMP
             lda   PC+1
             sta   HSCMP+1
             jsr   EMHSCMP
:nocmp
             lda   USES
             and   #$02
             beq   :nospr
             lda   PC
             sta   HSPR
             lda   PC+1
             sta   HSPR+1
             jsr   EMHSPR
:nospr

*--- The heap and the collector, which any of the four that allocate bring in
*    with them. In an order where each one's address is already known by the
*    time the next refers to it: the messages, the error exit, the collector,
*    then the allocator that calls both.
             lda   USES
             and   #UHEAP
             bne   :heap
             jmp   :noheap
:heap
             lda   PC
             sta   MOOM
             lda   PC+1
             sta   MOOM+1
             lda   #<MSGOOM
             ldy   #>MSGOOM
             jsr   EMMSG

             lda   PC
             sta   MLONG
             lda   PC+1
             sta   MLONG+1
             lda   #<MSGLONG
             ldy   #>MSGLONG
             jsr   EMMSG

             lda   PC
             sta   HERR
             lda   PC+1
             sta   HERR+1
             jsr   EMHERR

             lda   PC
             sta   HGC
             lda   PC+1
             sta   HGC+1
             jsr   EMHGC

             lda   PC
             sta   HALLOC
             lda   PC+1
             sta   HALLOC+1
             jsr   EMHALLOC

*--- the three substring functions, which share an ending
             lda   USES
             and   #$08
             beq   :noslice
             lda   PC
             sta   HSLICE
             lda   PC+1
             sta   HSLICE+1
             jsr   EMHSLICE

             lda   PC
             sta   HLEFT
             lda   PC+1
             sta   HLEFT+1
             jsr   EMHLEFT

             lda   PC
             sta   HRIGHT
             lda   PC+1
             sta   HRIGHT+1
             jsr   EMHRIGHT

             lda   PC
             sta   HMID
             lda   PC+1
             sta   HMID+1
             jsr   EMHMID
:noslice

             lda   USES
             and   #$10
             beq   :nochr
             lda   PC
             sta   HCHR
             lda   PC+1
             sta   HCHR+1
             jsr   EMHCHR
:nochr
             lda   USES
             and   #$20
             beq   :nojoin
             lda   PC
             sta   HJOIN
             lda   PC+1
             sta   HJOIN+1
             jsr   EMHJOIN
:nojoin
             lda   USES
             and   #$40
             beq   :nostr
             lda   PC
             sta   HSTR
             lda   PC+1
             sta   HSTR+1
             jsr   EMHSTR
:nostr
:noheap

*--- PEEK, POKE and CALL, none of which touch the heap
             lda   USES2
             and   #$01
             beq   :nopeek
             lda   PC
             sta   HPEEK
             lda   PC+1
             sta   HPEEK+1
             jsr   EMHPEEK
:nopeek      lda   USES2
             and   #$02
             beq   :nopoke
             lda   PC
             sta   HPOKE
             lda   PC+1
             sta   HPOKE+1
             jsr   EMHPOKE
:nopoke      lda   USES2
             and   #$04
             beq   :nocall
             lda   PC
             sta   HCALL
             lda   PC+1
             sta   HCALL+1
             jsr   EMHCALL
:nocall      lda   USES2
             and   #$08
             beq   :noval
             lda   PC
             sta   HVAL
             lda   PC+1
             sta   HVAL+1
             jsr   EMHVAL
:noval

*--- ASC allocates nothing, so it is not part of that group
             lda   USES
             and   #$80
             beq   :noasc
             lda   PC
             sta   HASC
             lda   PC+1
             sta   HASC+1
             jsr   EMHASC
:noasc

             lda   PC               ; where the program really ends
             sta   FINPC
             lda   PC+1
             sta   FINPC+1
             jsr   FLUSH
             clc
             rts
:fail        sec
             rts

*--- what LAYOUT decided, into TMPP
CODEST       lda   CODESTA
             sta   TMPP
             lda   CODESTA+1
             sta   TMPP+1
             rts

SPADDR       lda   SPSAVEA
             sta   TMPP
             lda   SPSAVEA+1
             sta   TMPP+1
             rts


*--------------------------------------
* GENLINE -- the statements on one line, separated by colons
*--------------------------------------
GENLINE      jsr   NEXTB
             bcs   :eof
             sta   CH
             beq   :done            ; the line's terminating zero
             cmp   #':'
             beq   GENLINE
             jsr   GENSTMT
             bcs   :bad
             jmp   GENLINE
:done        clc
             rts
:bad         sec
             rts
:eof         sec
             rts

*--------------------------------------
* GENSTMT -- one statement, its first byte already in CH
*--------------------------------------
GENSTMT      lda   #$00
             sta   ISSTR
             lda   CH
             cmp   #TLET
             beq   :let
             cmp   #TGOTOK
             beq   :goto
             cmp   #TIF
             beq   :if
             cmp   #TGOSUBK
             beq   :gosub
             cmp   #TRETURN
             beq   :return
             cmp   #TPRINT
             beq   :print
             cmp   #TEND
             beq   :end
             cmp   #TREM
             beq   :rem
             cmp   #TDIMK
             beq   :dim
             cmp   #TON
             beq   :on
             cmp   #TPOKE
             beq   :poke
             cmp   #TCALL
             beq   :call
             cmp   #TFORK
             beq   :for
             cmp   #TNEXT
             beq   :next
             cmp   #$80
             bcs   :unsup           ; some other keyword: not this milestone
             jsr   ISALNUM
             bcs   :unsup
             jmp   GLET             ; a bare name: an implied LET

:let         jsr   NEXTB
             bcs   :unsup
             sta   CH
             jmp   GLET
:goto        jmp   GGOTO
:if          jmp   GIF
:gosub       jmp   GGOSUB
:return      lda   #$60             ; RTS
             jsr   EMIT
             clc
             rts
:print       jmp   GPRINT
:end         jmp   GEND
:for         jmp   GFOR
:next        jmp   GNEXT
:on          jmp   GON
:poke        jmp   GPOKE
:call        jmp   GCALL

*--- DIM generates nothing at all: pass 1 read the sizes and the space is
*    already in the file. Its arguments are skipped rather than compiled --
*    A(20) here is a declaration, and reading it as a subscript would send
*    the generator looking for a constant 20 that pass 1 never made.
:dim         jsr   NEXTB
             bcs   :unsup
             sta   CH
             beq   :dimend
             cmp   #':'
             bne   :dim
:dimend      jsr   PUTBACK
             clc
             rts

*--- A REM generates nothing at all, which is most of what a compiler has to
*    say about a comment. Everything to the end of the line goes with it --
*    including any colon, since a REM swallows the rest of the line in
*    Applesoft too. The terminating zero is handed back so the line ends the
*    ordinary way rather than by reading into the next one's link.
:rem         jsr   NEXTB
             bcs   :unsup
             sta   CH
             bne   :rem
             jsr   PUTBACK
             clc
             rts
:unsup       lda   #$05
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GEND -- END, and the fall-off-the-end that behaves the same
*
* LDX SPSAVE / TXS before the RTS. A compiled GOSUB is a JSR, so END reached
* from inside one would otherwise return into the middle of the program
* instead of to BASIC. The prologue recorded where the stack stood on entry
* and this puts it back.
*--------------------------------------
GEND         jsr   EMEND
             clc
             rts

EMEND        lda   #$ae             ; LDX abs
             jsr   EMIT
             jsr   SPADDR
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$9a             ; TXS
             jsr   EMIT
             lda   #$60             ; RTS
             jmp   EMIT

*--------------------------------------
* GLET -- name = expression
*--------------------------------------
GLET         jsr   GETNAME
             bcs   :bad
             lda   CH
             cmp   #'$'
             beq   GLETSTR
             cmp   #'('
             beq   :arrj
             bne   :plainlet
:arrj        jmp   GLETARR          ; GLETSTR sits between the two now
:plainlet
             jsr   GETVAR2
             bcs   :bad
             lda   VARI
             pha
             lda   CH               ; GETNAME leaves what ended the name
             cmp   #TEQ
             bne   :bad2
             jsr   NEXPR
             bcs   :bad2
             pla
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP
             clc                    ; EMIT's own CMP leaves the carry set in
             rts                    ; pass 3; falling out of it reported that
                                    ; as a failure to compile

:bad2        pla
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GLETSTR -- A$ = a string
*
* The descriptor is emitted STRAIGHT INTO the variable, so A$ = B$ is three
* loads and three stores and A$ = "X" is the characters plus six. Nothing is
* copied and nothing is allocated.
*--------------------------------------
GLETSTR      jsr   SVFIND
             bcs   :bad
             jsr   SVADDR
             lda   TMPP             ; keep where it goes; the value is built
             sta   DSTSV            ; in SDA and copied here at the end
             lda   TMPP+1
             sta   DSTSV+1

             jsr   NEXTB
             bcs   :bad
             cmp   #TEQ
             bne   :bad
             lda   #$00
             sta   ISSTR
             jsr   ESUM             ; a whole string expression, joins and all
             bcs   :bad
             lda   ISSTR
             beq   :notstr
             lda   #$00
             sta   ISSTR

             jsr   SDAADDR
             lda   TMPP
             sta   SRCA
             lda   TMPP+1
             sta   SRCA+1
             lda   DSTSV
             sta   DSTA
             lda   DSTSV+1
             sta   DSTA+1
             jsr   EMSDESC

*--- ESUM has consumed any joins, so the statement really should be over
*    here; what used to complain about a trailing + now compiles it.
             clc
             rts

:notstr      lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
             sec
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GLETARR -- A(subscript) = expression
*
* THE ADDRESS IS WORKED OUT FIRST AND KEPT, because evaluating the right-hand
* side runs the whole expression machinery over the accumulator and the
* helper's zero page with it. Applesoft evaluates the subscript first too, so
* A(I) = I + 1 with I changing inside the expression would agree -- not that
* anything in this milestone can change it.
*--------------------------------------
GLETARR      jsr   GETARR
             bcs   :bad
             jsr   EMSUBS
             bcs   :bad

             lda   #$85             ; STA ZPELEM  -- keep the element address
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$84             ; STY ZPELEM+1
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT

             jsr   NEXTB
             bcs   :bad
             cmp   #TEQ
             bne   :bad
             jsr   NEXPR
             bcs   :bad

             lda   #$a6             ; LDX ZPELEM -- MOVMF wants X and Y
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$a4             ; LDY ZPELEM+1
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<MOVMF
             jsr   EMIT
             lda   #>MOVMF
             jsr   EMIT
             clc
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GGOTO / GGOSUB -- a line number, which is ASCII digits in the file
*--------------------------------------
GGOTO        jsr   RDLNUM
             bcs   GOBAD
             jsr   LTFIND
             bcs   GOBAD
             lda   #$4c             ; JMP
             jsr   EMJ2
             clc
             rts

GGOSUB       jsr   RDLNUM
             bcs   GOBAD
             jsr   LTFIND
             bcs   GOBAD
             lda   #$20             ; JSR
             jsr   EMJ2
             clc
             rts

GOBAD        lda   #$07             ; no such line
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GIF -- IF expression THEN ...
*
* Two shapes, because the common one is worth generating well: a single
* comparison branches straight off FCOMP, and anything else is tested as a
* value.
*--------------------------------------
*--- ECMPC, NOT EXPR: it stops at the CMP and says whether there was one, so
*    the common IF -- a single comparison -- branches straight off FCOMP's
*    answer instead of building a 1 or a 0 in the accumulator and then asking
*    whether it is zero. That is a ROM call and twenty-two bytes saved on
*    every pass of every loop, and it is the whole of the gap between the
*    generated code and the hand-compiled model.
GIF          jsr   ECONDC
             bcs   :bad
             lda   ISSTR            ; IF A$ THEN is a type mismatch, not a
             bne   :mixed           ; test of whatever the accumulator holds
             lda   GOTCMP
             beq   :value

*--- The branch is the OPPOSITE of the one the value form uses: this one skips
*    the jump when the test is TRUE. $d0 and $f0 differ by one bit.
             lda   CMPSENS
             eor   #$20
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             jmp   :jump

*--- Anything else leaves a value, and an Applesoft float is zero only when
*    its exponent is, so a single LDA and BNE decides it.
:value       jsr   OPFLUSH
             lda   #$ad             ; LDA abs
             jsr   EMIT
             lda   #$9d             ; the exponent byte of the accumulator
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$d0             ; BNE over the jump
             jsr   EMIT
             lda   #$03
             jsr   EMIT

*--- False goes to the NEXT LINE, which is right even when the line has more
*    statements after a colon -- THEN covers the rest of the line.
:jump        jsr   LTNEXT
             lda   #$4c
             jsr   EMJ2

*--- What follows the test. THEN and a line number, THEN and a statement, or
*    GOTO and a line number -- Applesoft accepts all three, and IF X GOTO 30
*    was being refused for want of a THEN that Applesoft does not require
*    either.
             jsr   NEXTB
             bcs   :bad
             sta   CH
             cmp   #TGOTOK
             beq   :isgoto
             cmp   #TTHEN
             bne   :nothen
             jsr   PEEK
             bcs   :bad
             sta   CH
             jsr   ISDIGIT
             bcs   :stmt
:isgoto      jmp   GGOTO
:stmt        jsr   NEXTB            ; a statement instead
             bcs   :bad
             sta   CH
             beq   :done
             jmp   GENSTMT
:mixed       lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
             sec
             rts
:nothen      lda   #$08
             jsr   SETBAD
:bad         sec
             rts
:done        clc
             rts

*--------------------------------------
* GFOR -- FOR v = start TO limit [STEP step]
*
* The limit and the step go into two slots of the loop's own, which is what
* pass 1 counted the FORs for. Applesoft evaluates all three once, on entry,
* and so does this -- a limit that is an expression is not re-evaluated every
* time round, and a program that relies on it being re-evaluated is relying on
* something Applesoft does not do either.
*
* The loop's top is remembered at compile time, on a stack of open FORs, so
* NEXT needs no run-time bookkeeping at all: no frame to push, nothing to
* search for, just a JMP to an address decided while compiling. That is most
* of what makes a compiled loop quicker than an interpreted one.
*--------------------------------------
*--- Reached by BRANCH, not by call: these end in RTS, so control returns to
*    whoever called GFOR. They sit in front of it because the routine is longer
*    than a branch can reach across.
FORBAD       lda   #$11             ; a FOR that does not read as one
             jsr   SETBAD
             sec
             rts
FORDEEP      lda   #$10             ; nested deeper than the compiler's stack
             jsr   SETBAD
             sec
             rts

GFOR         jsr   NEXTB
             bcs   FORBAD
             sta   CH
             jsr   GETVAR
             bcs   FORBAD
             lda   VARI
             sta   FVAR
             lda   CH
             cmp   #TEQ
             bne   FORBAD
             jsr   NEXPR            ; where it starts
             bcs   FORBAD
             lda   FVAR
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP

             jsr   NEXTB
             bcs   FORBAD
             cmp   #TTO
             bne   FORBAD
             jsr   NEXPR            ; and where it stops
             bcs   FORBAD
             lda   FORN
             sta   TMPA
             jsr   FLADDR
             jsr   EMSTP

*--- STEP, or one
             jsr   PEEK
             bcs   :one
             cmp   #TSTEP
             bne   :one
             jsr   NEXTB
             jsr   NEXPR
             bcs   FORBAD
             jmp   :setstep
:one         lda   #$01             ; constant one is always in the table
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD
:setstep     lda   FORN
             sta   TMPA
             jsr   FSADDR
             jsr   EMSTP

*--- open it: the next byte emitted is the top of the loop
             ldx   FSTKTOP
             cpx   #FDEPTH
             bcs   FORDEEP
             lda   FVAR
             sta   FSTKV,x
             lda   FORN
             sta   FSTKN,x
             lda   PC
             sta   FSTKAL,x
             lda   PC+1
             sta   FSTKAH,x
             inc   FSTKTOP
             inc   FORN
             clc
             rts

*--------------------------------------
* GNEXT -- NEXT [v]
*
*   v = v + step ; reload v ; compare with the limit ; go round unless past it
*
* RELOADED rather than compared straight out of the accumulator, because what
* the loop is about is the value the variable now HOLDS, and storing it packs
* it into five bytes and rounds it. Comparing the unrounded accumulator
* against the limit would let a loop run one extra time on values where the
* two differ.
*
* WHICH WAY "PAST IT" LIES DEPENDS ON THE STEP, and the step is not known
* until the program runs -- it can be an expression. So the sign is tested at
* run time. FCOMP answers 1 when the variable is the greater; for a negative
* step the loop ends when it is the LESSER, so the two answers are swapped
* with an EOR and one test serves both.
*--------------------------------------
NEXTBAD      sec                    ; GETVAR has already said what was wrong
             rts
NEXTNONE     lda   #$12             ; NEXT without a FOR
             jsr   SETBAD
             sec
             rts
NEXTWRONG    lda   #$13             ; NEXT naming the wrong variable
             jsr   SETBAD
             sec
             rts

GNEXT        lda   #$ff             ; no name given: the innermost loop
             sta   VARI
             jsr   PEEK
             bcs   :pop
             sta   CH
             beq   :pop
             cmp   #':'
             beq   :pop
             jsr   ISALNUM
             bcs   :pop
             jsr   NEXTB
             sta   CH
             jsr   GETVAR
             bcs   NEXTBAD
             jsr   PUTBACK

:pop         lda   FSTKTOP
             beq   NEXTNONE
             dec   FSTKTOP
             ldx   FSTKTOP
             lda   VARI
             cmp   #$ff
             beq   :ok
             cmp   FSTKV,x
             bne   NEXTWRONG
:ok          lda   FSTKV,x
             sta   FVAR
             lda   FSTKN,x
             sta   FSLOT
             lda   FSTKAL,x
             sta   FTOP
             lda   FSTKAH,x
             sta   FTOP+1

*--- v = v + step, and back into v
             lda   FVAR
             sta   TMPA
             jsr   VADDR
             jsr   EMLOAD
             lda   FSLOT
             sta   TMPA
             jsr   FSADDR
             lda   #<FADD
             sta   ROMA
             lda   #>FADD
             sta   ROMA+1
             jsr   EMOPA
             lda   FVAR
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP

*--- read it back and compare it with the limit
             lda   FVAR
             sta   TMPA
             jsr   VADDR
             jsr   EMLOAD
             lda   FSLOT
             sta   TMPA
             jsr   FLADDR
             lda   #<FCOMP
             sta   ROMA
             lda   #>FCOMP
             sta   ROMA+1
             jsr   EMOPA

*--- LDX step+1 -- the sign is bit 7 of the first fraction byte
             lda   #$ae
             jsr   EMIT
             lda   FSLOT
             sta   TMPA
             jsr   FSADDR
             lda   TMPP
             clc
             adc   #$01
             sta   TMPP
             bcc   :nc
             inc   TMPP+1
:nc          lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT

             lda   #$10             ; BPL over the EOR: a positive step leaves
             jsr   EMIT             ; FCOMP's answer as it is
             lda   #$02
             jsr   EMIT
             lda   #$49             ; EOR #$FE: swaps 1 and $FF, so "past the
             jsr   EMIT             ; limit" reads as 1 for either sign
             lda   #$fe
             jsr   EMIT
             lda   #$c9             ; CMP #$01
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$f0             ; BEQ over the jump: the loop is done
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   FTOP
             sta   TMPP
             lda   FTOP+1
             sta   TMPP+1
             lda   #$4c
             jsr   EMJ2
             clc
             rts

*--------------------------------------
* GPOKE -- POKE address, value
*
* The address is worked out and PUT AWAY before the value is, because working
* out the value can be an array subscript or a string operation and both of
* those use the zero page.
*--------------------------------------
GPOKE        jsr   NEXPR
             bcs   :bad
             lda   #$20             ; JSR GETADR
             jsr   EMIT
             lda   #<GETADR
             jsr   EMIT
             lda   #>GETADR
             jsr   EMIT
             lda   #$a5             ; LDA $50
             jsr   EMIT
             lda   #$50
             jsr   EMIT
             lda   #$8d             ; STA the scratch
             jsr   EMIT
             lda   #$10
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$51
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$11
             jsr   EMSCOFS

             jsr   NEXTB
             bcs   :bad
             cmp   #$2c
             bne   :bad
             jsr   NEXPR
             bcs   :bad
             lda   #$02
             jsr   NEED2
             lda   #$20
             jsr   EMIT
             lda   HPOKE
             jsr   EMIT
             lda   HPOKE+1
             jsr   EMIT
             clc
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GCALL -- CALL address
*--------------------------------------
GCALL        jsr   NEXPR
             bcs   :bad
             lda   #$20             ; JSR GETADR
             jsr   EMIT
             lda   #<GETADR
             jsr   EMIT
             lda   #>GETADR
             jsr   EMIT
             lda   #$a5             ; the address into the zero page
             jsr   EMIT
             lda   #$50
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$51
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #ZPB+1
             jsr   EMIT
             lda   #$04
             jsr   NEED2
             lda   #$20
             jsr   EMIT
             lda   HCALL
             jsr   EMIT
             lda   HCALL+1
             jsr   EMIT
             clc
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* GON -- ON expression GOTO a,b,c
*
* One-based: 1 picks the first, and anything outside the list falls through to
* whatever follows on the line, which is what Applesoft does rather than an
* error.
*
* THE TARGETS ARE COLLECTED BEFORE ANYTHING IS EMITTED, so the size of the
* jump table -- and therefore how far the three out-of-range branches have to
* reach -- is known when they are written. The alternative is emitting a jump
* over a table whose length is not known yet, which is the patching scheme
* that string literals had to be rescued from.
*
* The layout, counted rather than guessed:
*
*    0  JSR AYINT      3
*    3  LDA FACHI      2
*    5  BNE over       2   -> 30 + 2n
*    7  LDA FACLO      2
*    9  BEQ over       2   -> 30 + 2n
*   11  CMP #n+1       2
*   13  BCS over       2   -> 30 + 2n
*   15  ASL            1       two bytes to an entry
*   16  TAX            1
*   17  LDA tbl-2,X    3       X is 2 for the first target
*   20  STA ZPB        2
*   22  LDA tbl-1,X    3
*   25  STA ZPB+1      2
*   27  JMP (ZPB)      3
*   30  the table      2n
*--------------------------------------
*--- The failure exits are at the far end of a long routine, past the whole
*    emitter, so they are reached by jump rather than by branch.
GON          jsr   NEXPR
             bcc   :got
:badj        jmp   :bad
:got         jsr   NEXTB
             bcs   :badj
*--- GOTO or GOSUB. The only difference in what comes out is the three bytes
*    that leave: a jump through the zero page, or a call through it followed
*    by a jump past the table. Everything else shifts by those three.
             ldx   #$00
             cmp   #TGOTOK
             beq   :start
             inx
             cmp   #TGOSUBK
             beq   :start
             jmp   :notgoto

:start       stx   ONGS
             lda   #$00
             sta   ONN
:list        lda   ONN
             cmp   #ONMAX
             bcc   :room
             jmp   :toomany
:room        jsr   RDLNUM
             bcs   :badj
             jsr   LTFIND
             bcc   :have
             jmp   :nosuch
:have
             lda   ONN
             asl
             tax
             lda   TMPP
             sta   ONBUF,x
             lda   TMPP+1
             sta   ONBUF+1,x
             inc   ONN
             jsr   PEEK
             bcs   :emit
             cmp   #$2c
             bne   :emit
             jsr   NEXTB
             jmp   :list

*--- now the sizes are known
*--- where the table sits, counted from the start of what is about to be
*    emitted: past the jump out, and past the jump over the table as well
*    when this is a GOSUB and has to come back
:emit        ldx   ONGS
             beq   :goff
             lda   #$21
             bne   :soff
:goff        lda   #$1e
:soff        sta   ONTOF

             lda   PC               ; where the table will land
             clc
             adc   ONTOF
             sta   ONTBL
             lda   PC+1
             adc   #$00
             sta   ONTBL+1

             lda   ONN              ; 2n, which every distance is counted from
             asl
             sta   ONW

             lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT

             lda   #$a5             ; LDA FACHI -- anything over 255, or
             jsr   EMIT             ; negative, is outside the list
             lda   #FACHI
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   ONW              ; past the table, wherever it starts
             clc
             adc   ONTOF
             sec
             sbc   #$07
             jsr   EMIT

             lda   #$a5             ; LDA FACLO -- and so is zero
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   ONW              ; past the table, wherever it starts
             clc
             adc   ONTOF
             sec
             sbc   #$0b
             jsr   EMIT

             lda   #$c9             ; CMP #count+1
             jsr   EMIT
             lda   ONN
             clc
             adc   #$01
             jsr   EMIT
             lda   #$b0
             jsr   EMIT
             lda   ONW              ; past the table, wherever it starts
             clc
             adc   ONTOF
             sec
             sbc   #$0f
             jsr   EMIT

             lda   #$0a             ; ASL -- two bytes to an entry
             jsr   EMIT
             lda   #$aa             ; TAX
             jsr   EMIT

             lda   #$bd             ; LDA tbl-2,X
             jsr   EMIT
             lda   ONTBL
             sec
             sbc   #$02
             sta   TMPP
             lda   ONTBL+1
             sbc   #$00
             sta   TMPP+1
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT

             lda   #$bd             ; LDA tbl-1,X
             jsr   EMIT
             lda   ONTBL
             sec
             sbc   #$01
             sta   TMPP
             lda   ONTBL+1
             sbc   #$00
             sta   TMPP+1
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #ZPB+1
             jsr   EMIT

*--- and out: a GOTO never comes back, a GOSUB does and has to step over the
*    table when it lands
             lda   ONGS
             bne   :isgosub
             lda   #$6c             ; JMP (ZPB)
             jsr   EMIT
             lda   #ZPB
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             jmp   :table

:isgosub     lda   #$04
             jsr   NEED2
             lda   #$20             ; JSR HCALL, which jumps through ZPB
             jsr   EMIT
             lda   HCALL
             jsr   EMIT
             lda   HCALL+1
             jsr   EMIT
             lda   #$4c             ; JMP past the table
             jsr   EMIT
             lda   ONTBL
             clc
             adc   ONW
             sta   TMPP
             lda   ONTBL+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
:table

             lda   #$00             ; and the table itself
             sta   EMI
:tbl         ldx   EMI
             lda   ONBUF,x
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   ONW
             bcc   :tbl
             clc
             rts

:notgoto     lda   #$17             ; ON without GOTO or GOSUB after it
             jsr   SETBAD
             sec
             rts
:toomany     lda   #$18             ; TOO MANY IN ON GOTO
             jsr   SETBAD
             sec
             rts
:nosuch      lda   #$07             ; NO SUCH LINE
             jsr   SETBAD
             sec
             rts
:bad         sec
             rts

*--------------------------------------
* GPRINT -- strings, numbers, and semicolons between them
*
* Both printers are emitted inline rather than called, which is what the
* hand-compiled model did and what it was measured at. A PRINT happens a
* handful of times in a program; a runtime library to save a dozen bytes each
* time would be a page of code to hold, relocate and explain.
*--------------------------------------
GPRINT       lda   #$00
             sta   NONL
:item        jsr   PEEK
             bcs   :end
             sta   CH
             beq   :end
             cmp   #':'
             beq   :end
             cmp   #$2c
             beq   :comma
             cmp   #';'
             beq   :semi

             lda   #$00
             sta   NONL
             jsr   EXPR
             bcs   :bad
             lda   ISSTR
             bne   :pstr
             jsr   EMPRFAC
             jmp   :item
:pstr        lda   #$02        ; ON the label, not above it: reached by a
             jsr   NEED             ; branch, so anything in front is skipped
             lda   #$20             ; JSR the print helper
             jsr   EMIT
             lda   HSPR
             jsr   EMIT
             lda   HSPR+1
             jsr   EMIT
             lda   #$00
             sta   ISSTR
             jmp   :item

:semi        jsr   NEXTB
             lda   #$01
             sta   NONL
             jmp   :item

*--- A comma tabs, and like a semicolon it also suppresses the newline when it
*    is the last thing on the statement.
:comma       jsr   NEXTB
             jsr   EMTAB
             lda   #$01
             sta   NONL
             jmp   :item

:end         lda   NONL
             bne   :done
             jsr   EMCR
:done        clc
             rts
:bad         sec
             rts

*--------------------------------------
* EMTAB -- what a comma does in a PRINT
*
* Read off the screen rather than recalled. Applesoft's stops are every
* sixteen columns, and from column 23 at a width of 40 it tabs to 32 while
* from column 24 it goes to a new line instead. That is not a magic 24: it is
* "is there room for a whole sixteen-wide field", which is why this compares
* the column plus sixteen against the WINDOW WIDTH and so follows a program
* that changes it.
*
*    0  LDA CHCOL      2
*    2  CLC            1
*    3  ADC #16        2
*    5  CMP WNDWDTH    2
*    7  BCC tab        2   -> 17
*    9  LDA #$8D       2
*   11  JSR COUT       3
*   14  JMP done       3   -> 28
*   17  LDA #$A0       2   <- tab: at least one space, so a comma at a stop
*   19  JSR COUT       3      still moves on to the next one
*   22  LDA CHCOL      2
*   24  AND #$0F       2
*   26  BNE tab        2   -> 17
*   28
*--------------------------------------
EMTAB        lda   PC               ; where the jump over the newline lands
             clc
             adc   #$1c
             sta   TMPP
             lda   PC+1
             adc   #$00
             sta   TMPP+1

             lda   #$a5
             jsr   EMIT
             lda   #CHCOL
             jsr   EMIT
             lda   #$18             ; CLC
             jsr   EMIT
             lda   #$69             ; ADC #16
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$c5             ; CMP WNDWDTH
             jsr   EMIT
             lda   #WNDWDTH
             jsr   EMIT
             lda   #$90             ; BCC the tab loop
             jsr   EMIT
             lda   #$08
             jsr   EMIT

             lda   #$a9             ; no room: a new line instead
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jsr   EMIT
             lda   #$4c             ; JMP past the tab loop
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT

             lda   #$a9             ; spaces until the column divides by 16
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #CHCOL
             jsr   EMIT
             lda   #$29             ; AND #$0F
             jsr   EMIT
             lda   #$0f
             jsr   EMIT
             lda   #$d0             ; BNE back
             jsr   EMIT
             lda   #$f5
             jmp   EMIT

*--- LDA #$8D / JSR COUT
EMCR         lda   #$a9
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jmp   EMIT

*--------------------------------------
* EMPRFAC -- the accumulator as a number
*
*   JSR FOUT ; LDX #0 ; LDA $0100,X ; BEQ done ; ORA #$80 ; JSR COUT ; INX ;
*   BNE loop
*
* FOUT leaves a zero-terminated string at $0100 with its high bits clear.
* The index is in X because COUT does not keep Y.
*--------------------------------------
EMPRFAC      lda   #$00
             sta   EMI
:loop        ldy   EMI
             lda   PRFACB,y
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #PRFACE-PRFACB
             bcc   :loop
             rts

PRFACB       dfb   $20,$34,$ed      ; JSR FOUT
             dfb   $a2,$00          ; LDX #$00
             dfb   $bd,$00,$01      ; LDA $0100,X
             dfb   $f0,$08          ; BEQ past the loop
             dfb   $09,$80          ; ORA #$80
             dfb   $20,$ed,$fd      ; JSR COUT
             dfb   $e8              ; INX
             dfb   $d0,$f3          ; BNE back
PRFACE

*--------------------------------------
* The precedence chain, loosest first:
*
*   EXPR   := ECONDC, as a value
*   ECONDC := EANDC { OR EANDC }
*   EANDC  := ENOTC { AND ENOTC }
*   ENOTC  := [NOT] ECMPC
*   ECMPC  := ESUM [ < = > ESUM ]
*   ESUM   := ETERM { + - ETERM }
*   ETERM  := EFACT { * / EFACT }
*
* That is Applesoft's own order: OR below AND below NOT below the relational
* operators. NOT binds looser than a comparison, so NOT A = B is NOT (A = B).
*
* AND, OR AND NOT ARE LOGICAL, and give 1 or 0. I had them down as bitwise on
* sixteen-bit integers, wrote that in this comment, implemented it, and the
* interpreter said otherwise: 3 AND 5 is 1 and not 7, NOT 0 is 1 and not -1,
* NOT NOT 5 is 1 and not 5. tests/cc/logic is what asked it. Being confidently
* wrong about this in a comment is exactly how it would have survived.
*
* So the test is on the accumulator's exponent, which is zero only when the
* value is -- no integer conversion, and therefore no way to raise ILLEGAL
* QUANTITY on an operand too big to be one.
*--------------------------------------
*--------------------------------------
* NEXPR -- an expression that must be a number
*
* Everywhere but a PRINT item and the two sides of a string assignment or
* comparison wants a number. Without this a string reaching one of them --
* FOR I = A$ TO 5 -- compiled into arithmetic on whatever the accumulator
* happened to hold, which is the sort of wrong that runs.
*--------------------------------------
NEXPR        jsr   EXPR
             bcs   :bad
             lda   ISSTR
             bne   :mixed
             clc
             rts
:mixed       lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
:bad         sec
             rts

EXPR         jsr   ECONDC
             bcs   :bad
             lda   ISSTR
             bne   :string          ; the value is a descriptor, not a number
             lda   GOTCMP
             beq   :plain
             jmp   MATCMP           ; a comparison, wanted as a value
:plain       jmp   OPFLUSH
:string      clc
             rts
:bad         sec
             rts

*--------------------------------------
* VALNOW -- whatever the last operand was, have it as a value
*--------------------------------------
VALNOW       lda   GOTCMP
             beq   :done
             jsr   MATCMP
:done        clc
             rts

*--------------------------------------
* ECONDC / EANDC -- OR, then AND
*--------------------------------------
ECONDC       jsr   EANDC
             bcs   :bad
             lda   ISSTR
             bne   :done
:loop        jsr   PEEK
             bcs   :done
             cmp   #TOR
             bne   :done
             jsr   NEXTB
             jsr   VALNOW
             lda   PENDOK
             beq   :infac

             lda   PENDA
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   EANDC
             bcs   :drop2
             jsr   VALNOW
             jsr   OPFLUSH
             pla
             sta   LEFTA+1
             pla
             sta   LEFTA
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   EANDC
             bcs   :bad
             jsr   VALNOW
             jsr   OPFLUSH
             jsr   POPTMP
             lda   TMPP
             sta   LEFTA
             lda   TMPP+1
             sta   LEFTA+1

:emit        lda   #$d0             ; BNE: either side true gives one
             sta   LOGBR
             lda   #$00
             sta   LOGFALL
             lda   #$01
             sta   LOGTGT
             jsr   EMLOGOP
             jmp   :loop

:drop2       pla
             pla
:bad         sec
             rts
:done        clc
             rts

EANDC        jsr   ENOTC
             bcs   :bad
             lda   ISSTR
             bne   :done
:loop        jsr   PEEK
             bcs   :done
             cmp   #TAND
             bne   :done
             jsr   NEXTB
             jsr   VALNOW
             lda   PENDOK
             beq   :infac

             lda   PENDA
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   ENOTC
             bcs   :drop2
             jsr   VALNOW
             jsr   OPFLUSH
             pla
             sta   LEFTA+1
             pla
             sta   LEFTA
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   ENOTC
             bcs   :bad
             jsr   VALNOW
             jsr   OPFLUSH
             jsr   POPTMP
             lda   TMPP
             sta   LEFTA
             lda   TMPP+1
             sta   LEFTA+1

:emit        lda   #$f0             ; BEQ: either side false gives zero
             sta   LOGBR
             lda   #$01
             sta   LOGFALL
             lda   #$00
             sta   LOGTGT
             jsr   EMLOGOP
             jmp   :loop

:drop2       pla
             pla
:bad         sec
             rts
:done        clc
             rts

*--------------------------------------
* ENOTC -- NOT, which is also bitwise: NOT 0 is -1 and NOT 1 is -2
*--------------------------------------
ENOTC        jsr   PEEK
             bcs   :plain
             cmp   #TNOT
             bne   :plain
             jsr   NEXTB
             jsr   ENOTC            ; NOT NOT A is allowed
             bcs   :bad
             jsr   VALNOW
             jsr   OPFLUSH
             jsr   EMNOT
             lda   #$00
             sta   GOTCMP
             clc
             rts
:plain       jmp   ECMPC
:bad         sec
             rts

*--------------------------------------
* MATCMP -- a comparison's answer as a proper 1 or 0 in the accumulator
*--------------------------------------
MATCMP       lda   CMPSENS          ; $d0 BNE, or $f0 BEQ for a negated test
             jsr   EMIT
             lda   #$0a             ; past the seven that load one and the
             jsr   EMIT             ; three of the jump over the zero
             lda   #$01
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD
             lda   #$4c             ; JMP over the other one
             jsr   EMIT
             lda   PC               ; two bytes of address, then seven more
             clc
             adc   #$09
             sta   TMPP
             lda   PC+1
             adc   #$00
             sta   TMPP+1
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$00
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD
             lda   #$00
             sta   GOTCMP
             clc
             rts

*--------------------------------------
* EMNOT -- zero becomes one, anything else becomes zero
*
*   LDA FACEXP ; BEQ +10 ; FAC = 0 ; JMP +7 ; FAC = 1
*
* The distances are counted from the layout below, not guessed: a load of the
* accumulator from an address is LDA #lo, LDY #hi, JSR -- seven bytes.
*
*    0  LDA FACEXP     2
*    2  BEQ  +10       2   -> 14
*    4  load zero      7
*   11  JMP  21        3
*   14  load one       7
*   21
*--------------------------------------
EMNOT        lda   #$a5             ; LDA FACEXP, in the direct page
             jsr   EMIT
             lda   #FACEXP
             jsr   EMIT
             lda   #$f0             ; BEQ past the zero and the jump
             jsr   EMIT
             lda   #$0a
             jsr   EMIT
             lda   #$00
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD
             lda   #$4c
             jsr   EMIT
             lda   PC               ; two address bytes, then seven
             clc
             adc   #$09
             sta   TMPP
             lda   PC+1
             adc   #$00
             sta   TMPP+1
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$01
             sta   TMPA
             jsr   CADDR
             jmp   EMLOAD

*--------------------------------------
* EMLOGOP -- AND or OR, on the truth of both sides
*
* The right side is already in the accumulator and the left is at LEFTA.
* LOGBR says which way the test jumps, LOGTGT which constant sits at the far
* end and LOGFALL which one falls through:
*
*   AND   BEQ to zero    right false -> 0, else test left
*   OR    BNE to one     right true  -> 1, else test left
*
*    0  LDA FACEXP     2
*    2  branch +21     2   -> 25
*    4  load left      7
*   11  LDA FACEXP     2
*   13  branch +10     2   -> 25
*   15  load LOGFALL   7
*   22  JMP 32         3
*   25  load LOGTGT    7
*   32
*--------------------------------------
EMLOGOP      lda   #$a5
             jsr   EMIT
             lda   #FACEXP
             jsr   EMIT
             lda   LOGBR
             jsr   EMIT
             lda   #$15             ; past everything but the far constant
             jsr   EMIT

             lda   LEFTA
             sta   TMPP
             lda   LEFTA+1
             sta   TMPP+1
             jsr   EMLOAD

             lda   #$a5
             jsr   EMIT
             lda   #FACEXP
             jsr   EMIT
             lda   LOGBR
             jsr   EMIT
             lda   #$0a
             jsr   EMIT

             lda   LOGFALL
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD

             lda   #$4c
             jsr   EMIT
             lda   PC
             clc
             adc   #$09
             sta   TMPP
             lda   PC+1
             adc   #$00
             sta   TMPP+1
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT

             lda   LOGTGT
             sta   TMPA
             jsr   CADDR
             jsr   EMLOAD
             lda   #$00
             sta   PENDOK
             sta   GOTCMP
             clc
             rts

*--------------------------------------
* SCMPC -- the left side was a string
*
* Its descriptor is in SDA. If a comparison follows, the right side goes into
* SDB and the helper answers in exactly FCOMP's convention, so everything that
* reads CMPWANT and CMPSENS works unchanged.
*
* If no comparison follows, the string IS the value -- PRINT A$ -- and ISSTR
* stays set for whoever asked.
*--------------------------------------
SCMPC        jsr   PEEK
             bcs   :value
             cmp   #TLT
             beq   :cmp
             cmp   #TEQ
             beq   :cmp
             cmp   #TGT
             beq   :cmp
:value       lda   #$00
             sta   GOTCMP
             clc
             rts

:cmp         jsr   RDCMPOP
             bcs   :bad
             lda   CMPWANT
             pha
             lda   CMPSENS
             pha

*--- The left side is in SDA and the right side is about to be built there
*    too, so the left moves aside first. SDB is where the helper looks for it.
             jsr   SDAADDR
             lda   TMPP
             sta   SRCA
             lda   TMPP+1
             sta   SRCA+1
             jsr   SDBADDR
             jsr   SDSET
             jsr   EMSDESC

             lda   #$00
             sta   ISSTR
             jsr   ESUM             ; so that A$ = B$ + C$ compares too
             bcs   :drop
             lda   ISSTR
             beq   :mixed           ; a string against a number

             pla
             sta   CMPSENS
             pla
             sta   CMPWANT

             lda   #$04
             jsr   NEED
             lda   #$20             ; JSR the comparison helper
             jsr   EMIT
             lda   HSCMP
             jsr   EMIT
             lda   HSCMP+1
             jsr   EMIT
             lda   #$c9             ; CMP #what it must answer
             jsr   EMIT
             lda   CMPWANT
             jsr   EMIT
             lda   #$01
             sta   GOTCMP
             lda   #$00
             sta   ISSTR
             clc
             rts

:mixed       pla
             pla
             lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
             sec
             rts
:drop        pla
             pla
:bad         sec
             rts

*--------------------------------------
* ECMPC -- a sum, optionally compared with another, stopping at the CMP
*
* FCOMP answers about the accumulator against memory: 1 if the accumulator is
* the greater. The left side is the one in memory here, so the answer reads
* the other way round from the operator as written -- A < B asks whether the
* accumulator, holding B, is the greater, and that is 1.
*
* This stops after emitting the CMP, with GOTCMP saying whether there was a
* comparison at all. Two callers want different things from that point: ECMP
* turns it into a value, and an IF turns it straight into a branch.
*
* GOTCMP IS SET LAST, on both paths, because the nested ESUM below can itself
* contain a comparison in brackets and would leave the flag set on its way
* out. Anything read before that returns is the inner expression's answer, not
* this one's.
*--------------------------------------
ECMPC        lda   #$00
             sta   ISSTR
             jsr   ESUM
             bcc   :ok
             jmp   :bad             ; the tail of this routine is out of reach
:ok          lda   ISSTR
             beq   :num
             jmp   SCMPC            ; a string on the left: a different compare
:num         jsr   PEEK
             bcs   :none
             cmp   #TLT
             beq   :cmp
             cmp   #TEQ
             beq   :cmp
             cmp   #TGT
             bne   :none
:cmp         jsr   RDCMPOP
             bcs   :bad

*--- ACROSS THE RIGHT-HAND SIDE, on the stack. It may hold a comparison of its
*    own in brackets, and RDCMPOP would then have written this one's answer
*    over with the inner one's -- so A < (B < C) would have compiled the outer
*    test against the inner operator's expectation.
             lda   CMPWANT
             pha
             lda   CMPSENS
             pha
             lda   PENDOK
             beq   :infac

             lda   PENDA
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   ESUM
             bcs   :drop4
             jsr   OPFLUSH
             pla
             sta   TMPP+1
             pla
             sta   TMPP
             jmp   :have

:infac       jsr   PUSHFAC
             jsr   ESUM
             bcs   :drop
             jsr   OPFLUSH
             jsr   POPTMP           ; TMPP = the left side's temporary
:have        pla
             sta   CMPSENS
             pla
             sta   CMPWANT

             lda   #<FCOMP
             sta   ROMA
             lda   #>FCOMP
             sta   ROMA+1
             jsr   EMOPA
             lda   #$c9             ; CMP immediate
             jsr   EMIT
             lda   CMPWANT
             jsr   EMIT
             lda   #$01
             sta   GOTCMP
             clc
             rts

:none        lda   #$00
             sta   GOTCMP
             clc
             rts
:drop4       pla
             pla
:drop        pla
             pla
:bad         sec
             rts

*--------------------------------------
* RDCMPOP -- the one or two tokens of a comparison
*
* Applesoft stores <= as two tokens, and so >= and <>. CMPWANT is what FCOMP
* must answer and CMPSENS is whether the test is equality or inequality --
* <= is simply "not greater".
*--------------------------------------
RDCMPOP      jsr   NEXTB
             bcs   :bad
             sta   CMPA
             jsr   PEEK
             bcs   :one
             sta   CMPB
             cmp   #TLT
             beq   :two
             cmp   #TEQ
             beq   :two
             cmp   #TGT
             bne   :one
:two         jsr   NEXTB
             lda   CMPA
             cmp   #TLT
             bne   :gt
             lda   CMPB
             cmp   #TEQ
             beq   :le
             cmp   #TGT
             beq   :ne
             jmp   :bad
:gt          cmp   #TGT
             bne   :bad
             lda   CMPB
             cmp   #TEQ
             beq   :ge
             cmp   #TLT
             beq   :ne
             jmp   :bad

*--- A < B is "the accumulator, holding B, is the greater" -- FCOMP answers 1
:one         lda   CMPA
             cmp   #TLT
             beq   :lt
             cmp   #TGT
             beq   :gtt
             cmp   #TEQ
             beq   :eq
:bad         lda   #$0f
             jsr   SETBAD
             sec
             rts
:lt          lda   #$01
             ldy   #$d0
             jmp   :set
:gtt         lda   #$ff
             ldy   #$d0
             jmp   :set
:eq          lda   #$00
             ldy   #$d0
             jmp   :set
:le          lda   #$ff             ; not greater
             ldy   #$f0
             jmp   :set
:ge          lda   #$01             ; not less
             ldy   #$f0
             jmp   :set
:ne          lda   #$00             ; not equal
             ldy   #$f0
:set         sta   CMPWANT
             sty   CMPSENS
             clc
             rts

*--------------------------------------
* ESUM / ETERM -- + and -, then * and /
*
* A LEAF IS NOT EMITTED WHEN IT IS PARSED. A plain variable or constant only
* records its address, in PENDA, and whoever wants it decides what to do with
* it. That one deferral is worth two ROM calls on every binary operator in
* every program.
*
* Because when the left side is still just an address, the RIGHT side can go
* into the accumulator and the operation can name the left -- which is what
* FSUB and FDIV want anyway, since they compute memory minus accumulator and
* memory over accumulator. So I + 1 compiles to a load and an add, where
* storing the left into a temporary first and reloading it made it a load, a
* store, a load and an add.
*
* When the left is already a value in the accumulator -- because it was itself
* an expression -- the temporary is still needed, and that is what it is for.
*--------------------------------------
ESUM         jsr   ETERM
             bcc   :ok
             sec                    ; its own exit: :bad is past the whole of
             rts                    ; the operator loop below
:ok          lda   ISSTR
             beq   :loop

*--- A string, and the only operator it takes is +.
*
*    THE LEFT SIDE MOVES ASIDE FIRST. Every string value is built in SDA, so
*    parsing the right would build it on top of the left; SDB is where the
*    join helper looks for the left, as the comparison helper does.
:sjoin       jsr   PEEK
             bcs   :sdone
             cmp   #TPLUS
             bne   :sdone
             jsr   NEXTB

             jsr   SDAADDR
             lda   TMPP
             sta   SRCA
             lda   TMPP+1
             sta   SRCA+1
             jsr   SDBADDR
             jsr   SDSET
             jsr   EMSDESC

             lda   #$00
             sta   ISSTR
             jsr   EPRIM
             bcs   :sfail
             lda   ISSTR
             beq   :smix

             lda   #$20
             jsr   NEED
             lda   #$20
             jsr   EMIT
             lda   HJOIN
             jsr   EMIT
             lda   HJOIN+1
             jsr   EMIT
             lda   #$01
             sta   ISSTR
             jmp   :sjoin

:smix        lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
:sfail       sec
             rts
:sdone       clc
             rts
:loop        jsr   PEEK
             bcs   :done
             cmp   #TPLUS
             beq   :op
             cmp   #TMINUS
             bne   :done
:op          jsr   NEXTB
             pha                    ; the operator, across the right side
             lda   PENDOK
             beq   :infac

             lda   PENDA            ; and the left side's address with it
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   ETERM
             bcs   :drop3
             jsr   OPFLUSH
             pla
             sta   TMPP+1
             pla
             sta   TMPP
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   ETERM
             bcs   :drop1
             jsr   OPFLUSH
             jsr   POPTMP

:emit        pla
             cmp   #TPLUS
             bne   :sub
             lda   #<FADD
             sta   ROMA
             lda   #>FADD
             sta   ROMA+1
             jmp   :go
:sub         lda   #<FSUB           ; memory MINUS accumulator: the left side
             sta   ROMA             ; is the one named here
             lda   #>FSUB
             sta   ROMA+1
:go          jsr   EMOPA
             lda   #$00
             sta   PENDOK
             jmp   :loop

:drop3       pla
             pla
:drop1       pla
:bad         sec
             rts
:done        clc
             rts

ETERM        jsr   EFACT
             bcs   :bad
             lda   ISSTR            ; no * or / on a string
             bne   :done
:loop        jsr   PEEK
             bcs   :done
             cmp   #TSTAR
             beq   :op
             cmp   #TSLASH
             bne   :done
:op          jsr   NEXTB
             pha
             lda   PENDOK
             beq   :infac

             lda   PENDA
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   EFACT
             bcs   :drop3
             jsr   OPFLUSH
             pla
             sta   TMPP+1
             pla
             sta   TMPP
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   EFACT
             bcs   :drop1
             jsr   OPFLUSH
             jsr   POPTMP

:emit        pla
             cmp   #TSTAR
             bne   :div
             lda   #<FMUL
             sta   ROMA
             lda   #>FMUL
             sta   ROMA+1
             jmp   :go
:div         lda   #<FDIV           ; memory OVER accumulator, the same way
             sta   ROMA
             lda   #>FDIV
             sta   ROMA+1
:go          jsr   EMOPA
             lda   #$00
             sta   PENDOK
             jmp   :loop

:drop3       pla
             pla
:drop1       pla
:bad         sec
             rts
:done        clc
             rts

*--------------------------------------
* OPFLUSH -- put a deferred leaf into the accumulator after all
*
* Called by everything that actually needs the value there rather than an
* address: the end of an expression, and the right-hand side of any operator.
*--------------------------------------
OPFLUSH      lda   PENDOK
             beq   :done
             lda   #$00
             sta   PENDOK
             lda   PENDA
             sta   TMPP
             lda   PENDA+1
             sta   TMPP+1
             jsr   EMLOAD
:done        clc                    ; NOT the emitter's carry, which its own
             rts                    ; test of the pass number leaves set

*--------------------------------------
* EFACT -- a negation, a number, a variable, or a bracketed expression
*
* Negating is zero minus the value, which the ROM's subtract does directly
* since it takes memory minus the accumulator and constant zero is always the
* first thing in the data area.
*--------------------------------------
EFACT        jsr   PEEK
             bcs   :bad
             cmp   #TMINUS
             bne   EPRIM
             jsr   NEXTB
             jsr   EPRIM
             bcs   :bad
             jsr   OPFLUSH
             lda   #$00
             sta   TMPA
             jsr   CADDR
             lda   #<FSUB
             sta   ROMA
             lda   #>FSUB
             sta   ROMA+1
             jsr   EMOPA
             clc
             rts
:bad         sec
             rts

EPRIM        lda   #$00
             sta   PENDOK
             jsr   NEXTB
             bcs   :bad
             sta   CH
             cmp   #TLEN            ; these take a STRING, so none of them is
             beq   :lenj            ; one of the eleven
             cmp   #TASC
             beq   :ascj
             cmp   #TCHR
             beq   :chrj
             cmp   #TSTR
             beq   :strj
             cmp   #TPEEK
             beq   :peekj
             cmp   #TVAL
             beq   :valj
             cmp   #TLEFT
             beq   :slicej
             cmp   #TRIGHT
             beq   :slicej
             cmp   #TMID
             beq   :slicej
             cmp   #$80
             bcs   :fn
             cmp   #'"'
             beq   :slitj
             cmp   #'('
             beq   :paren
             jsr   ISDIGIT
             bcc   :numj
             lda   CH
             cmp   #'.'
             beq   :numj
             jsr   ISALNUM
             bcc   :varj
:bad         lda   #$0c
             jsr   SETBAD
             sec
             rts

*--- Past the RTS above, so nothing falls into them. The handlers are all
*    further down this routine than a branch from the dispatch can reach.
:slitj       jmp   :slit
:numj        jmp   :num
:varj        jmp   :var
:lenj        jmp   FLEN
:ascj        jmp   FASC
:chrj        jmp   FCHR
:strj        jmp   FSTR
:peekj       jmp   FPEEK
:valj        jmp   FVAL
:slicej      jmp   FSLICE

:paren       jsr   EXPR
             bcs   :bad2
             jsr   NEXTB
             bcs   :bad2
             cmp   #')'
             bne   :bad2
             clc
             rts
:bad2        sec
             rts

*--- A function: its token says which, and each is a single call once the
*    argument is in the accumulator. Brackets are required, as Applesoft
*    requires them.
:fn          jsr   FNFIND
             bcs   :bad
             jsr   NEXTB
             bcs   :bad2
             cmp   #'('
             bne   :bad3

*--- ACROSS THE ARGUMENT, on the stack. Generating the argument emits loads
*    and adds, and every one of those sets ROMA on its way through -- so the
*    call that came out was to whatever the last load had used, not to the
*    function. INT(2.7) compiled into a call to MOVFM and printed 2.7.
             lda   ROMA
             pha
             lda   ROMA+1
             pha
             jsr   NEXPR
             bcs   :drop2
             jsr   NEXTB
             bcs   :drop2
             cmp   #')'
             bne   :drop3
             jsr   OPFLUSH
             pla
             sta   ROMA+1
             pla
             sta   ROMA
             jsr   EMJSR
             lda   #$00
             sta   PENDOK
             clc
             rts
:drop3       pla
             pla
             jmp   :bad3
:drop2       pla
             pla
             sec
             rts
:bad3        lda   #$0c
             jsr   SETBAD
             sec
             rts

*--- a literal: converted the same way pass 1 did, then looked up rather than
*    added, because pass 1 already put it in the table
*--- Its own exits: EPRIM has grown long enough that the one at the top is
*    out of branch range from down here.
:num         jsr   RDNUM
             bcc   :nok
             sec
             rts
:nok         jsr   PUTBACK          ; what ended it is not ours
             jsr   NUMCONV
             jsr   CFIND
             bcc   :ngot
             lda   #$0c
             jsr   SETBAD
             sec
             rts
:ngot        jsr   CADDR
             jmp   DEFER

:slit        jsr   EMSLIT           ; its characters, and a descriptor
             bcs   :sfail
             lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts
:sfail       sec
             rts

:var         jsr   GETNAME
             bcc   :got
             jmp   :bad             ; :bad is back past the whole of EPRIM
:got         lda   CH
             cmp   #'$'
             beq   :svarj
             cmp   #'('
             beq   :elem
             jsr   GETVAR2          ; a plain variable
             bcc   :plain
             sec                    ; its own exit: this is a long way from
             rts                    ; the top of EPRIM now
:plain       jsr   PUTBACK          ; what ended the name is not ours
             lda   VARI
             sta   TMPA
             jsr   VADDR
             jmp   DEFER

*--- An element. Its address is not known until the program runs, so there is
*    nothing to defer: the value goes straight into the accumulator.
:elem        jsr   GETARR
             bcs   :ebad
             jsr   EMSUBS
             bcs   :ebad
             lda   #$20             ; JSR MOVFM, with the address in A and Y
             jsr   EMIT
             lda   #<MOVFM
             jsr   EMIT
             lda   #>MOVFM
             jsr   EMIT
             lda   #$00
             sta   PENDOK
             clc
             rts
:ebad        sec                    ; its own name: EPRIM already has a :bad2
             rts                    ; and it is a long way up the routine
:svarj       jmp   SVARP            ; LEN's body sits between here and there

*--- LEN: a string in, a number out. The length is already in the descriptor,
*    so this is the descriptor and then GIVAYF, which takes a signed sixteen
*    bit value with the high byte in A and the low in Y.
*--------------------------------------
* The string functions, each a routine of its own
*
* THEY WERE INSIDE EPRIM, and EPRIM grew past the point where a branch could
* cross it: every one of these blocks ended up with a private failure exit
* because no shared one was in reach, and each addition cost two or three
* builds finding the next branch that had gone out of range. Split out, each
* has a label scope the length of itself.
*--------------------------------------
FLEN         jsr   SOPEN
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$00
             sta   ISSTR

             lda   #$ad             ; LDA the length
             jsr   EMIT
             jsr   SDAADDR
             jsr   EMADDR
             lda   #$a8             ; TAY
             jsr   EMIT
             lda   #$a9             ; LDA #0 -- the high byte
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<GIVAYF
             jsr   EMIT
             lda   #>GIVAYF
             jsr   EMIT
             lda   #$00
             sta   PENDOK
             clc
             rts
:no          sec
             rts

*--- CHR$: a number in, a string out, and the first thing here that has to
*    MAKE one.
FCHR         jsr   NEXTB
             bcs   :no
             cmp   #'('
             bne   :no
             lda   #$00
             sta   ISSTR
             jsr   NEXPR
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$10
             jsr   NEED
             jsr   EMAYINT
             lda   #$20
             jsr   EMIT
             lda   HCHR
             jsr   EMIT
             lda   HCHR+1
             jsr   EMIT
             lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts
:no          sec
             rts

*--- VAL: a string in, the number it spells out.
FVAL         jsr   SOPEN
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$08
             jsr   NEED2
             lda   #$00
             sta   ISSTR
             sta   PENDOK
             lda   #$20
             jsr   EMIT
             lda   HVAL
             jsr   EMIT
             lda   HVAL+1
             jsr   EMIT
             clc
             rts
:no          sec
             rts

*--- PEEK: the byte at an address.
FPEEK        jsr   NEXTB
             bcs   :no
             cmp   #'('
             bne   :no
             lda   #$00
             sta   ISSTR
             jsr   NEXPR
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$01
             jsr   NEED2
             lda   #$20
             jsr   EMIT
             lda   HPEEK
             jsr   EMIT
             lda   HPEEK+1
             jsr   EMIT
             lda   #$00
             sta   PENDOK
             clc
             rts
:no          sec
             rts

*--- STR$: a number in, its characters out.
FSTR         jsr   NEXTB
             bcs   :no
             cmp   #'('
             bne   :no
             lda   #$00
             sta   ISSTR
             jsr   NEXPR
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$40
             jsr   NEED
             lda   #$20
             jsr   EMIT
             lda   HSTR
             jsr   EMIT
             lda   HSTR+1
             jsr   EMIT
             lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts
:no          sec
             rts

*--- ASC: a string in, a number out, and nothing allocated.
FASC         jsr   SOPEN
             bcs   :no
             jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :no
             lda   #$00
             sta   ISSTR
             sta   PENDOK
             lda   #$80
             jsr   NEED
             lda   HASC
             sta   TMPP
             lda   HASC+1
             sta   TMPP+1
             lda   #$20
             jsr   EMIT
             jsr   EMADDR
             clc
             rts
:no          sec
             rts

*--------------------------------------
* LEFT$, RIGHT$ and MID$
*
* The string goes on the stack while the numbers are worked out, because
* working one out may well build another string in SDA -- LEFT$(A$, LEN(B$))
* is not a strange thing to write.
*--------------------------------------
FSLICE       lda   CH
             sta   SLICEF
             jsr   SOPEN
             bcs   :sbad
             jsr   EMPUSHSD

             jsr   NEXTB
             bcs   :sbad
             cmp   #$2c
             bne   :sbad
             lda   #$00
             sta   ISSTR
             jsr   NEXPR
             bcs   :sbad
*--- MID$ goes to a routine of its own: the two together are longer than a
*    branch can reach end to end, which is how they came to be split.
*
*    BRANCHED PAST, NOT INTO. This jump was written directly under a
*    'beq :ismid', so LEFT$ and RIGHT$ fell straight through it and every one
*    of them compiled as MID$ -- LEFT$("ABCDEFG",3) printed CDEFG. The test
*    caught it at once; the assembler could not, because there is nothing
*    wrong with the instruction.
             lda   SLICEF
             cmp   #TMID
             bne   :notmid
             jmp   FMID

*--- LEFT$ or RIGHT$: one number and the bracket
:notmid
             jsr   NEXTB
             bcs   :sbad
             cmp   #')'
             bne   :sbad
             jsr   EMAYINT
             jsr   EMPULLSD
             lda   SLICEF
             cmp   #TLEFT
             beq   :isleft
             lda   #$08
             jsr   NEED
             lda   HRIGHT
             ldy   HRIGHT+1
             jmp   :slcall
:isleft      lda   #$08        ; ON the label, not above it: reached by a
             jsr   NEED             ; branch, so anything in front is skipped
             lda   HLEFT
             ldy   HLEFT+1
:slcall      sta   TMPP
             sty   TMPP+1
             lda   #$20
             jsr   EMIT
             jsr   EMADDR
*--- SAID, NOT FALLEN INTO. This used to run straight on into the ending
*    below it, and moving the failure exit in between turned every LEFT$ and
*    RIGHT$ into a silent refusal -- carry set with nothing to report, so the
*    compiler stopped and printed no reason at all.
             jmp   SLOK

*--- FSLICE's own failure exit, inside FSLICE's own scope. It was sitting
*    above the label, which put it in the previous routine's -- exactly the
*    mistake the split was meant to stop making.
:sbad        sec
             rts

SLOK         lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts

*--- And MID$ has one of its own again: the slice block is over a branch's
*    reach end to end.
:mbad        sec
             rts

*--- MID$: the start, which goes on the stack too because working out the
*    count can reach another MID$ through a LEN
FMID         jsr   EMAYINT
             lda   #$a5
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$48             ; PHA
             jsr   EMIT

             jsr   NEXTB
             bcs   :mbad
             cmp   #')'
             beq   :midrest
             cmp   #$2c
             bne   :mbad
             lda   #$00
             sta   ISSTR
             jsr   NEXPR
             bcs   :mbad
             jsr   NEXTB
             bcs   :mbad
             cmp   #')'
             bne   :mbad
             jsr   EMAYINT
             jmp   :midgo

*--- no count given: 255, which the helper clamps to the length anyway
:midrest     lda   #$a9
             jsr   EMIT
             lda   #$ff
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT

:midgo       lda   #$68             ; PLA -- the start, back off the stack
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSCOFS
             jsr   EMPULLSD
             lda   #$08
             jsr   NEED
             lda   #$20
             jsr   EMIT
             lda   HMID
             jsr   EMIT
             lda   HMID+1
             jsr   EMIT
             jmp   SLOK

*--- A string variable: its descriptor is copied to wherever this expression
*    wants one. The $ was read by GETNAME and is part of the name, so unlike
*    a plain variable there is nothing to hand back.
SVARP        jsr   SVFIND
             bcc   :vok
             sec                    ; and one of its own: EPRIM is long enough
             rts                    ; now that no shared exit is in reach
:vok
             jsr   SVADDR
             lda   TMPP
             sta   SRCA
             lda   TMPP+1
             sta   SRCA+1
             jsr   SDAADDR
             jsr   SDSET
             jsr   EMSDESC
             lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts

*--- Remember where it is rather than loading it. See ESUM.
DEFER        lda   TMPP
             sta   PENDA
             lda   TMPP+1
             sta   PENDA+1
             lda   #$01
             sta   PENDOK
             clc
             rts

*--------------------------------------
* SOPEN -- the ( and the string argument after it, into SDA
*--------------------------------------
*--- ESUM, not EPRIM: LEFT$(A$ + B$, 2) should work, and joining lives in
*    ESUM's string path.
SOPEN        jsr   NEXTB
             bcs   :no
             cmp   #'('
             bne   :no
             lda   #$00
             sta   ISSTR
             jsr   ESUM
             bcs   :no
             lda   ISSTR
             beq   :notstr
             clc
             rts
:notstr      lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
:no          sec
             rts

*--------------------------------------
* FNFIND -- a function token to the ROM routine that does it, into ROMA
*
* THE ELEVEN THAT TAKE THE ACCUMULATOR AND LEAVE IT THERE. Every address was
* confirmed by pointing Applesoft's own USR vector straight at it and printing
* what came back -- SGN(-4) is -1, SQR(9) is 3, ATN(1) is .785398163. None of
* it is from memory, which is the rule here: two of the arithmetic routines
* this compiler already depends on turned out to take their operands the
* opposite way round from the obvious guess.
*
* PEEK, LEN, STR$ and the rest are not here. PEEK needs the integer
* conversion and a POKE to go with it; the others are string work.
*--------------------------------------
FNFIND       lda   #$00
             sta   TMPB
:loop        lda   TMPB
             cmp   #FNCOUNT
             bcs   :no
             asl                    ; three bytes to an entry
             clc
             adc   TMPB
             tax
             lda   FNTAB,x
             cmp   CH
             beq   :yes
             inc   TMPB
             jmp   :loop
:yes         lda   FNTAB+1,x
             sta   ROMA
             lda   FNTAB+2,x
             sta   ROMA+1
             clc
             rts
:no          lda   #$05             ; a keyword, but not one that compiles
             jsr   SETBAD
             sec
             rts

FNTAB        dfb   $d2
             da    $eb90            ; SGN
             dfb   $d3
             da    $ec23            ; INT
             dfb   $d4
             da    $ebaf            ; ABS
             dfb   $da
             da    $ee8d            ; SQR
             dfb   $db
             da    $efae            ; RND
             dfb   $dc
             da    $e941            ; LOG
             dfb   $dd
             da    $ef09            ; EXP
             dfb   $de
             da    $efea            ; COS
             dfb   $df
             da    $eff1            ; SIN
             dfb   $e0
             da    $f03a            ; TAN
             dfb   $e1
             da    $f09e            ; ATN
FNCOUNT      equ   11

*--------------------------------------
* GETVAR -- read a name and find it in pass 1's table
*
* It cannot be missing: pass 1 walked the same bytes. If it is, something has
* gone wrong enough to stop rather than guess.
*--------------------------------------
GETNAME      lda   #$00
             sta   VN1
             sta   NCH
             lda   CH
             sta   VN0
:loop        jsr   NEXTB
             bcs   :bad
             sta   CH
             jsr   ISALNUM
             bcs   :end
             lda   NCH
             bne   :more
             lda   CH
             sta   VN1
:more        inc   NCH
             jmp   :loop
:end         clc
             rts
:bad         sec
             rts

*--- and then look it up. A name ending in ( is an array, and A and A( are
*    different variables to Applesoft, so they are looked up in different
*    tables here.
*--- GETVAR2 is a global label, so it ends GETVAR's local scope and the two
*    halves cannot share a :bad. One named exit for both.
GETVAR       jsr   GETNAME
             bcs   GVBAD
GETVAR2      jsr   VFIND
             bcs   GVBAD
             lda   TMPA
             sta   VARI
             clc
             rts
GVBAD        lda   #$0d
             jsr   SETBAD
             sec
             rts

GETARR       jsr   AFIND
             bcs   GVBAD
             lda   TMPA
             sta   VARI
             clc
             rts

*--- the array table, which pass 1 filled
AFIND        lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NARR
             bcs   :no
             jsr   ASLOT
             ldy   #$00
             lda   (TMPP),y
             cmp   VN0
             bne   :step
             iny
             lda   (TMPP),y
             cmp   VN1
             beq   :yes
:step        inc   TMPA
             jmp   :loop
:yes         clc
             rts
:no          sec
             rts

*--------------------------------------
* EMSUBS -- a subscript: the expression, then the element's address in A and Y
*
* Entered after the opening bracket. Leaves the closing one consumed.
*--------------------------------------
EMSUBS       lda   VARI
             pha
             jsr   NEXPR
             bcs   :drop
             jsr   NEXTB
             bcs   :drop
             cmp   #')'
             bne   :dropbad

             lda   #$20             ; JSR AYINT -- the subscript as an integer
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT

             pla                    ; which array, and where it starts
             sta   TMPA
             jsr   AADDR
             lda   #$a9             ; LDA #lo
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   #$a0             ; LDY #hi
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$01
             jsr   NEED
             lda   #$20             ; JSR the address helper
             jsr   EMIT
             lda   HARR
             jsr   EMIT
             lda   HARR+1
             jsr   EMIT
             clc
             rts

:dropbad     pla
             lda   #$0c
             jsr   SETBAD
             sec
             rts
:drop        pla
             sec
             rts

*--------------------------------------
* RDLNUM -- a branch target: ASCII digits, into WORD
*--------------------------------------
RDLNUM       lda   #$00
             sta   WORD
             sta   WORD+1
             sta   NCH
:loop        jsr   NEXTB
             bcs   :end
             sta   CH
             jsr   ISDIGIT
             bcs   :back
             jsr   LNMUL10
             inc   NCH
             jmp   :loop
:back        jsr   PUTBACK
:end         lda   NCH
             beq   :bad
             clc
             rts
:bad         sec
             rts

*--- WORD = WORD * 10 + the digit in CH
LNMUL10      lda   WORD
             asl
             sta   TMPB
             lda   WORD+1
             rol
             sta   TMPB+1           ; twice
             asl   TMPB
             rol   TMPB+1
             asl   TMPB
             rol   TMPB+1           ; eight times
             lda   WORD
             asl
             sta   WORD
             lda   WORD+1
             rol
             sta   WORD+1           ; twice
             lda   WORD
             clc
             adc   TMPB
             sta   WORD
             lda   WORD+1
             adc   TMPB+1
             sta   WORD+1
             lda   CH
             sec
             sbc   #'0'
             clc
             adc   WORD
             sta   WORD
             bcc   :done
             inc   WORD+1
:done        rts

*--------------------------------------
* Temporaries: a stack, one deep per level of unfinished operator
*--------------------------------------
PUSHFAC      lda   TEMPTOP
             cmp   #NTEMPS
             bcs   :full
             sta   TMPA
             jsr   TADDR
             jsr   EMSTP
             inc   TEMPTOP
             rts
:full        lda   #$0e
             jsr   SETBAD
             rts

POPTMP       dec   TEMPTOP
             lda   TEMPTOP
             sta   TMPA
             jmp   TADDR

*--------------------------------------
* The emitter
*--------------------------------------
*--- PC ADVANCES FIRST. FLUSH takes the next window's base address from PC,
*    and a byte counted after the flush rather than before would have left
*    every window after the first believing it started one byte early -- which
*    only shows up as a string literal's JMP patched into the wrong place,
*    a long way from here.
EMIT         pha
             inc   PC
             bne   :on
             inc   PC+1
:on          lda   PASSNO
             cmp   #$03
             bne   :done
             pla
             pha
             ldx   OUTLEN
             sta   OUTBUF,x
             inc   OUTLEN
             bne   :done
             jsr   FLUSH
:done        pla
             rts

*--- LDA #lo / LDY #hi / JSR (ROMA)
EMOPA        lda   #$a9
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
EMJSR        lda   #$20
             jsr   EMIT
             lda   ROMA
             jsr   EMIT
             lda   ROMA+1
             jmp   EMIT

*--- the accumulator from the address in TMPP
EMLOAD       lda   #<MOVFM
             sta   ROMA
             lda   #>MOVFM
             sta   ROMA+1
             jmp   EMOPA

*--- and into it: MOVMF wants the address in X and Y rather than A and Y
EMSTP        lda   #$a2
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #<MOVMF
             sta   ROMA
             lda   #>MOVMF
             sta   ROMA+1
             jmp   EMJSR

*--- a JMP or JSR to TMPP, the opcode already in A
EMJ2         jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jmp   EMIT

*--------------------------------------
* FLUSH -- the output window to disk
*--------------------------------------
FLUSH        lda   PASSNO
             cmp   #$03
             bne   :done
             lda   OUTLEN
             beq   :full
             sta   WRPARM+4
             lda   #$00
             sta   WRPARM+5
             jmp   :write
:full        lda   #$00
             sta   WRPARM+4
             lda   #$01
             sta   WRPARM+5
:write       jsr   MLI
             dfb   $cb              ; WRITE
             da    WRPARM
             sta   MLIERR
             lda   #$00
             sta   OUTLEN
             lda   PC               ; where the next window starts
             sta   OUTBASE
             lda   PC+1
             sta   OUTBASE+1
:done        rts

*--------------------------------------
* The line table, which pass 2 fills in and pass 3 reads
*--------------------------------------
LTSETA       lda   PASSNO
             cmp   #$02
             bne   :done
             lda   LINEI
             pha
             lda   LINEI+1
             pha
             jsr   LTHERE
             ldy   #$02
             lda   PC
             sta   (TMPP),y
             iny
             lda   PC+1
             sta   (TMPP),y
             pla
             sta   LINEI+1
             pla
             sta   LINEI
:done        rts

*--- TMPP = the entry for line LINEI
LTHERE       lda   LINEI
             sta   NLTMP
             lda   LINEI+1
             sta   NLTMP+1
             jmp   LTSLOTN

*--- TMPP = LTAB + 4 * NLTMP
LTSLOTN      lda   NLTMP
             asl
             sta   TMPP
             lda   NLTMP+1
             rol
             sta   TMPP+1
             asl   TMPP
             rol   TMPP+1
             lda   TMPP
             clc
             adc   #<LTAB
             sta   TMPP
             lda   TMPP+1
             adc   #>LTAB
             sta   TMPP+1
             rts

*--------------------------------------
* LTFIND -- the address of the line numbered WORD, into TMPP
*
* Pass 2 has no addresses yet and returns a plausible one so that the code it
* sizes is the same size as the code pass 3 writes. Anything would do; the
* origin is used because a wild address in a program that is never written is
* still worth not having.
*--------------------------------------
LTFIND       lda   PASSNO
             cmp   #$02
             bne   :real
             lda   #<CODEORG
             sta   TMPP
             lda   #>CODEORG
             sta   TMPP+1
             clc
             rts
:real        lda   #$00
             sta   NLTMP
             sta   NLTMP+1
:loop        lda   NLTMP+1
             cmp   NLINES+1
             bcc   :try
             lda   NLTMP
             cmp   NLINES
             bcc   :try
             sec                    ; no such line
             rts
:try         jsr   LTSLOTN
             ldy   #$00
             lda   (TMPP),y
             cmp   WORD
             bne   :step
             iny
             lda   (TMPP),y
             cmp   WORD+1
             bne   :step
             ldy   #$02
             lda   (TMPP),y
             pha
             iny
             lda   (TMPP),y
             sta   TMPP+1
             pla
             sta   TMPP
             clc
             rts
:step        inc   NLTMP
             bne   :loop
             inc   NLTMP+1
             jmp   :loop

*--------------------------------------
* LTNEXT -- where the line AFTER this one starts, for a false IF
*
* The last line has no next one, and the answer there is the end of the
* program -- which is where falling off the last line goes anyway.
*--------------------------------------
LTNEXT       lda   PASSNO
             cmp   #$02
             bne   :real
             lda   #<CODEORG
             sta   TMPP
             lda   #>CODEORG
             sta   TMPP+1
             rts
:real        lda   LINEI
             clc
             adc   #$01
             sta   NLTMP
             lda   LINEI+1
             adc   #$00
             sta   NLTMP+1
             lda   NLTMP+1
             cmp   NLINES+1
             bcc   :have
             lda   NLTMP
             cmp   NLINES
             bcc   :have
             lda   ENDPC            ; past the last line
             sta   TMPP
             lda   ENDPC+1
             sta   TMPP+1
             rts
:have        jsr   LTSLOTN
             ldy   #$02
             lda   (TMPP),y
             pha
             iny
             lda   (TMPP),y
             sta   TMPP+1
             pla
             sta   TMPP
             rts

*--------------------------------------
* VFIND / CFIND -- the index of a name, or of a converted constant
*--------------------------------------
VFIND        lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NVARS
             bcs   :no
             asl
             tax
             lda   VTAB,x
             cmp   VN0
             bne   :step
             lda   VTAB+1,x
             cmp   VN1
             beq   :yes
:step        inc   TMPA
             jmp   :loop
:yes         clc
             rts
:no          sec
             rts

CFIND        lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NCONST
             bcs   :no
             jsr   CSLOT
             ldy   #$04
:cmp         lda   (TMPP),y
             cmp   TMPF,y
             bne   :step
             dey
             bpl   :cmp
             clc
             rts
:step        inc   TMPA
             jmp   :loop
:no          sec
             rts

*--------------------------------------
* SLOTN -- TMPP = SLOTB + TMPA * A
*
* One routine rather than one per table. There were four copies of this
* multiply and they had already drifted: one tested the wrong byte for its
* loop counter and would have handed back the base address for every
* temporary.
*--------------------------------------
SLOTN        sta   ACCSZ
             lda   SLOTB
             sta   TMPP
             lda   SLOTB+1
             sta   TMPP+1
             lda   TMPA
             sta   ACCN
             jmp   BUMP

*--- TMPP += ACCSZ, ACCN times
BUMP         lda   ACCN
             beq   :done
             lda   TMPP
             clc
             adc   ACCSZ
             sta   TMPP
             bcc   :nc
             inc   TMPP+1
:nc          dec   ACCN
             jmp   BUMP
:done        rts

*--- TMPP = the address of constant TMPA in the compiled program
CADDR        lda   CONSTBASE
             sta   SLOTB
             lda   CONSTBASE+1
             sta   SLOTB+1
             lda   #$05
             jmp   SLOTN

*--- and of temporary TMPA
TADDR        lda   TEMPBASE
             sta   SLOTB
             lda   TEMPBASE+1
             sta   SLOTB+1
             lda   #$05
             jmp   SLOTN

*--- a FOR's pair: the limit, then the step five bytes after it
FLADDR       lda   FORBASE
             sta   SLOTB
             lda   FORBASE+1
             sta   SLOTB+1
             lda   #$0a
             jmp   SLOTN

FSADDR       jsr   FLADDR
             lda   TMPP
             clc
             adc   #$05
             sta   TMPP
             bcc   :done
             inc   TMPP+1
:done        rts

*--------------------------------------
* LAYOUT -- where everything in the compiled program lives
*
* All of it decided here, after pass 1 has counted and before a byte is
* generated, so the two generating passes cannot disagree about an address.
*--------------------------------------
LAYOUT       lda   #<CODEORG+3      ; past the JMP at the front
             sta   VARBASE
             sta   TMPP
             lda   #>CODEORG+3
             sta   VARBASE+1
             sta   TMPP+1

             lda   #$05
             sta   ACCSZ
             lda   NVARS
             sta   ACCN
             jsr   BUMP
             lda   TMPP
             sta   CONSTBASE
             lda   TMPP+1
             sta   CONSTBASE+1

             lda   NCONST
             sta   ACCN
             jsr   BUMP
             lda   TMPP
             sta   TEMPBASE
             lda   TMPP+1
             sta   TEMPBASE+1

             lda   #NTEMPS
             sta   ACCN
             jsr   BUMP
             lda   TMPP
             sta   FORBASE
             lda   TMPP+1
             sta   FORBASE+1

             lda   #$0a             ; a limit and a step for each FOR
             sta   ACCSZ
             lda   NFORS
             sta   ACCN
             jsr   BUMP
             lda   TMPP
             sta   SPSAVEA
             lda   TMPP+1
             sta   SPSAVEA+1

*--- THE COLLECTOR'S ROOTS, ALL TOGETHER. The two working descriptors and
*    every string variable sit in one unbroken run, so a collection walks a
*    single range instead of two: SDA, SDB, then three bytes per string
*    variable. Everything else the runtime scratches in goes after them.
             lda   TMPP
             clc
             adc   #$01
             sta   SDESCA
             lda   TMPP+1
             adc   #$00
             sta   SDESCA+1

             lda   SDESCA           ; the string variables follow the two
             clc
             adc   #$06
             sta   SVBASE
             sta   TMPP
             lda   SDESCA+1
             adc   #$00
             sta   SVBASE+1
             sta   TMPP+1

             lda   #$03             ; a length and a pointer each
             sta   ACCSZ
             lda   NSVARS
             sta   ACCN
             jsr   BUMP

*--- and past the roots, everything else the string runtime works in:
*    MID$'s start, the heap pointer, the join's destination and length, and
*    the collector's own five.
             lda   TMPP
             sta   SCRA
             lda   TMPP+1
             sta   SCRA+1
             lda   TMPP
             clc
             adc   #SCRASZ
             sta   ARRBASE
             lda   TMPP+1
             adc   #$00
             sta   ARRBASE+1

             lda   NARR             ; ...and run for five bytes an element
             sta   TMPA
             jsr   ASUM
             lda   ARRBASE
             clc
             adc   ATOT
             sta   CODESTA
             lda   ARRBASE+1
             adc   ATOT+1
             sta   CODESTA+1
             rts

*--------------------------------------
* ASUM -- ATOT = the bytes taken by arrays 0 to TMPA-1
*
* Five a time round rather than a multiply: a count is sixteen bits and five
* additions are shorter than the shifting would be, and this runs once per
* array per pass rather than once per subscript.
*--------------------------------------
ASUM         lda   #$00
             sta   ATOT
             sta   ATOT+1
             sta   AIDX
             lda   TMPA
             sta   AEND
:loop        lda   AIDX
             cmp   AEND
             bcs   :done
             sta   TMPA
             jsr   ASLOT
             ldy   #$02
             lda   (TMPP),y
             sta   ACNT
             iny
             lda   (TMPP),y
             sta   ACNT+1
             ldx   #$05
:five        lda   ATOT
             clc
             adc   ACNT
             sta   ATOT
             lda   ATOT+1
             adc   ACNT+1
             sta   ATOT+1
             dex
             bne   :five
             inc   AIDX
             jmp   :loop
:done        rts

*--- TMPP = the base of array TMPA
AADDR        jsr   ASUM
             lda   ATOT
             clc
             adc   ARRBASE
             sta   TMPP
             lda   ATOT+1
             adc   ARRBASE+1
             sta   TMPP+1
             rts

*--------------------------------------
* Reading, with one byte of lookahead
*--------------------------------------
NEXTB        jmp   RDBYTE

PEEK         jsr   RDBYTE
             bcs   :no
             sta   PBACK
             pha
             lda   #$01
             sta   PBFLAG
             pla
             clc
             rts
:no          sec
             rts

PUTBACK      lda   CH
             sta   PBACK
             lda   #$01
             sta   PBFLAG
             rts

             dum   $14a0
PASSNO       ds    1
PC           ds    2                ; where the next emitted byte will live
ENDPC        ds    2
LINEI        ds    2                ; which line, by position
NLTMP        ds    2
VARI         ds    1
TEMPTOP      ds    1
ROMA         ds    2
OUTLEN       ds    1
OUTBASE      ds    2                ; the address the output window starts at
STRAT        ds    2
STRLEN       ds    1
NONL         ds    1
CMPA         ds    1
CMPB         ds    1
CMPWANT      ds    1
CMPSENS      ds    1
EMI          ds    1
FVAR         ds    1
FORN         ds    1                ; which FOR is being compiled
FSTKTOP      ds    1
FSTKV        ds    FDEPTH           ; its variable
FSTKN        ds    FDEPTH           ; its pair of slots
FSTKAL       ds    FDEPTH           ; and where its loop begins
FSTKAH       ds    FDEPTH
FSLOT        ds    1
FTOP         ds    2
GOTCMP       ds    1                ; the expression ended in a comparison
PENDOK       ds    1                ; a leaf parsed but not yet emitted
PENDA        ds    2                ; and where it lives
LEFTA        ds    2                ; a bitwise operator's left side
LOGBR        ds    1                ; which way a logical operator branches
LOGFALL      ds    1                ; and which constant goes where
LOGTGT       ds    1
HARR         ds    2                ; where the address helper landed
FINPC        ds    2                ; and the end of the whole thing
HSCMP        ds    2                ; the string comparison helper
HSPR         ds    2                ; and the one that prints one
HLEFT        ds    2
HRIGHT       ds    2
HMID         ds    2
HASC         ds    2
HCHR         ds    2
HJOIN        ds    2
HSTR         ds    2
HERR         ds    2
HALLOC       ds    2
HGC          ds    2
HSLICE       ds    2
HPEEK        ds    2
HVAL         ds    2
HPOKE        ds    2
HCALL        ds    2
MOOM         ds    2                ; where the two messages landed
MLONG        ds    2
SLICEF       ds    1                ; which of the three is being compiled
SCRA         ds    2                ; where the runtime's scratch begins
USES         ds    1                ; which helpers the program actually needs
USES2        ds    1                ; ...and the second byte of them
ISSTR        ds    1                ; the value just parsed is a string
DSTA         ds    2                ; where EMSDESC is to copy to
DSTSV        ds    2                ; and where an assignment finally lands
SRCA         ds    2
SDESCA       ds    2                ; the two string descriptors
ATOT         ds    2
ACNT         ds    2
AIDX         ds    1
AEND         ds    1
ONN          ds    1                ; how many targets in an ON
ONW          ds    1                ; twice that: the table's length
ONTBL        ds    2
ONGS         ds    1                ; 0 for GOTO, 1 for GOSUB
ONTOF        ds    1                ; how far in the table starts                ; an index EMIT cannot clobber
             dend
