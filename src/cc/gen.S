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
*    helper below, two for an element address being held across an assignment,
*    and the two DIM allocators borrow the same four while they run.
*
*    $1A-$1F is clear of the floating point at $9D-$A5, of COUT's screen
*    pointers at $24-$29, and of the MLI at $40-$4F.
*
*    IT IS NOT CLEAR OF THE HI-RES ROUTINES, and the note here used to say it
*    was on the grounds that a compiled program never calls them. It does:
*    HGR, HPLOT and HCOLOR= compile to calls into that ROM, and BRIAN uses all
*    three. What makes it safe is narrower and worth stating properly --
*    nothing of ours is LIVE across such a call. The address helper is done
*    with $1A-$1D before the statement that used it ends, ZPELEM is held only
*    across an assignment, which cannot contain an HPLOT, and a DIM has
*    finished allocating before anything else runs.
*
*    The compiler's own TMPP sits at $1A as well, which is harmless for the
*    reason the old note gave correctly: the two never run at once.
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
*    string a slice wants, 16-17 a POKE's address across its value,
*    18-19 how far through the DATA a READ has got, 38 which of the
*    collector's runs is being walked, 39-40 what is left of it, 41 how many
*    runs there are.
SCRASZ       equ   42               ; $24 a PLOT's column, kept across its row               ; $1a/$1b an array element being assigned
*                                     to, $1c-$23 the running subscript and
*                                     the multiply a comma in one needs               ; $14-$17 the input line and its split,
*                                     $18/$19 an item on its way to the heap

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
TREAD        equ   $87
TRESTORE     equ   $ae
TDATAK       equ   $83
TINPUT       equ   $84
TDEFK        equ   $b8
TVTAB        equ   $a2
THTAB        equ   $96
THOME        equ   $97
TTEXTK       equ   $89
TSPEEDK      equ   $a9
TINVERSE     equ   $9e
TNORMAL      equ   $9d
TFLASH       equ   $9f
CV           equ   $25              ; the cursor's row, and the monitor's
VTABZ        equ   $fc22            ; way of acting on it
CHPOS        equ   $24
TTABK        equ   $c0              ; TAB( -- the token carries the bracket
TSPCK        equ   $c3              ; SPC( likewise
TPOPK        equ   $a1
TPOW         equ   $cc              ; ^
TLOMEM       equ   $a4
TFREK        equ   $d6
TPOSK        equ   $d9
FPWRT        equ   $ee97            ; FAC <- ARG ^ FAC. Read off the ROM: it
                                    ; opens by testing ARGEXP, which is what
                                    ; CONUPK leaves in A
CONUPK       equ   $e9e3            ; ARG <- the packed float at (A,Y), and
                                    ; ARGEXP into A. Found from FMUL, which
                                    ; begins by calling it
TSAVEK       equ   $b7
TSTOPK       equ   $b3
TPRNK        equ   $8a
OUTPORT      equ   $fe95            ; the monitor's PR#: slot in A. Read off
                                    ; the ROM rather than recalled -- it sets
                                    ; CSW to $Cn00, or back to $F0xx for 0
HOMEROM      equ   $fc58
TEXTROM      equ   $fb39
INVFLG       equ   $32
TGR          equ   $88
TCOLOR       equ   $a0
TPLOT        equ   $8d
SETGR        equ   $fb40            ; low-res, mixed, cleared
SETCOL       equ   $f864            ; the colour in A, into both nibbles
PLOTROM      equ   $f800            ; row in A, column in Y
THLIN        equ   $8e
TVLIN        equ   $8f
TAT          equ   $c5
HLINROM      equ   $f819            ; row in A, from Y to H2
VLINROM      equ   $f828            ; from A to V2, in column Y
H2           equ   $2c
THGR         equ   $91
THCOLOR      equ   $92
THPLOT       equ   $93
HGRROM       equ   $f3e2            ; page one, mixed, cleared
HGR2ROM      equ   $f3d8            ; page TWO, full screen, cleared
TGR2K        equ   $90
TCLEARK      equ   $bd
TRUNK        equ   $ac
TPDL         equ   $d8
TSCRN        equ   $d7
TGETK        equ   $be
PREAD        equ   $fb1e            ; paddle X, count back in Y
SCRNROM      equ   $f871            ; row in A, column in Y, colour back in A
RDKEY        equ   $fd0c
INTROM       equ   $ec23            ; FAC <- floor(FAC)
HCOLBYTE     equ   $e4              ; where HCOLOR= puts the mask...
HPLOTCOL     equ   $30              ; ...and where the plotting reads it
HPOSN        equ   $f411            ; row in A, column in X and Y
HPLOT0       equ   $f457            ; position and plot, HPOSN included
HLINEROM     equ   $f53a            ; a line TO there from where it is
V2           equ   $2d
TFNK         equ   $c2
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

*--- THE END OF THE LINE CLOSES THE STRING, which is what Applesoft does and
*    what this refused to do. PRINT "---- with no second quote is ordinary
*    Applesoft and saves the byte a closing quote would cost; the Beagle Bros
*    listings use it freely, and CHR$ POKER line 30 ends on one.
*
*    The terminator is PUT BACK rather than eaten. It belongs to the line, not
*    to the string, and the caller is about to look for the end of a statement
*    -- swallowing it here would send it reading the next line's link bytes as
*    though they were code.
             jsr   PUTBACK
             jmp   :have
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

*--- and the count of descriptors the collector has to walk: SDA, SDB, every
*    string variable, and every element of every array of strings. ONE BYTE,
*    which is why LAYOUT refuses a program whose total passes 255 rather than
*    emitting a count that has wrapped -- a collector that walks 3 of 259
*    descriptors would move a string out from under the other 256.
*--------------------------------------
* EMNDESC -- how many roots the collector has, as TWO bytes
*
* SDA and SDB, every string variable, and every element of every array of
* strings. The field in the run table has always been two bytes wide -- the
* caller used to emit a zero after this for "room for more" -- but the sum
* was worked out in one, and LAYOUT refused any program whose roots passed
* 255 rather than emit a count that had wrapped.
*
* WORDS.WORTH says DIM W$(1000), which is 1001 of them, and was refused for
* it. The arithmetic is sixteen bits now and the refusal is gone; a dynamic
* DIM has always written this field as sixteen bits, so the collector's walker
* already reads it that way.
*
* The old version added twice with a CLC in front of each, which threw away
* the carry out of the first -- harmless while the total could not exceed a
* byte anyway, and wrong the moment it could.
*--------------------------------------
EMNDESC      lda   NSVARS
             clc
             adc   #$02
             sta   ABTMP
             lda   #$00
             adc   #$00
             sta   ABTMP+1
             lda   ABTMP
             clc
             adc   NSAEL
             sta   ABTMP
             lda   ABTMP+1
             adc   NSAEL+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
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
* EMDATA -- every DATA item, as pass 1 collected them, and an $FF to stop
*--------------------------------------
EMDATA       lda   #$00
             sta   DEMI
             sta   DEMI+1
:loop        lda   DEMI+1
             cmp   DBP+1
             bcc   :more
             lda   DEMI
             cmp   DBP
             bcs   :end
:more        lda   DEMI
             clc
             adc   #<DBUF
             sta   DBUFP
             lda   DEMI+1
             adc   #>DBUF
             sta   DBUFP+1
             ldy   #$00
             lda   (DBUFP),y
             jsr   EMIT
             inc   DEMI
             bne   :loop
             inc   DEMI+1
             jmp   :loop
:end         lda   #$ff
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
MSGDATA2     asc   "?OUT OF DATA ERROR"
             dfb   $00
MSGLONG      asc   "?STRING TOO LONG ERROR"
             dfb   $00

*--- WHAT A NUMERIC GET SAYS when the key is not a digit. Established on a
*    //e: `GET A` with 7 gives A=7 and echoes nothing, and with X or with
*    RETURN it stops on ?SYNTAX ERROR -- with no IN line, which is why this
*    carries none.
MSGSYN       asc   "?SYNTAX ERROR"
             dfb   $00

*--- Both carry their own return: what follows them is a fresh prompt.
MSGREENT     asc   "?REENTER"
             dfb   $8d
             dfb   $00
MSGEXTRA     asc   "?EXTRA IGNORED"
             dfb   $8d
             dfb   $00

*--------------------------------------
* EMHINPUT -- one line from the keyboard, ready to be split
*
* GETLN1 rather than GETLN: it reads without printing a prompt of its own, and
* the prompt is the caller's business -- INPUT A prints ? and INPUT "P";A
* prints P and no question mark, which is the machine's rule and not a choice
* made here.
*
* THE HIGH BIT COMES OFF EVERY CHARACTER. GETLN returns high ascii and every
* string this compiler makes is low, so a line left as it arrived would
* compare unequal to an identical literal and print as inverse text.
*
*   31 bytes
*--------------------------------------
EMHINPUT     lda   #$20
             jsr   EMIT
             lda   #$6f
             jsr   EMIT
             lda   #$fd
             jsr   EMIT
             lda   #$8e
             jsr   EMIT
             lda   #$15
             jsr   EMSCOFS
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$15
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$0c
             jsr   EMIT
             lda   #$b9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$29
             jsr   EMIT
             lda   #$7f
             jsr   EMIT
             lda   #$99
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HINPUT
             clc
             adc   #$08
             sta   TMPP
             lda   HINPUT+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$14
             jsr   EMSCOFS
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHNEXTI -- the next item on the line, as a descriptor in SDA
*
* Applesoft's splitting, established on the machine: items are separated by
* commas; an unquoted item loses its LEADING spaces and keeps its trailing
* ones; a quoted one is what lies between the quotes, commas included.
*
* That is deliberately NOT what DATA does -- DATA trims both ends. Two rules
* that look alike and are not, which is why both were asked of the machine
* rather than assumed from the other.
*
* Running out mid-statement prints ?? and reads another line, keeping what has
* already been assigned.
*
*   165 bytes
*--------------------------------------
EMHNEXTI     lda   #HNXIBEND-HNXIB
             sta   BLOBN
             lda   #<HNXIB
             ldy   #>HNXIB
             jmp   EMBLOB

*--- 165 bytes of helper from 136 of blob and 32 of
*    table, where straight-line emits took 739.
HNXIB
             dfb   $ad,$ff,$cd,$ff,$90,$10,$a9,$bf
             dfb   $20,$ed,$fd,$a9,$bf,$20,$ed,$fd
             dfb   $20,$ff,$4c,$ff,$ac,$ff,$cc,$ff
             dfb   $b0,$0b,$b9,$00,$02,$c9,$20,$d0
             dfb   $04,$c8,$4c,$ff,$cc,$ff,$b0,$07
             dfb   $b9,$00,$02,$c9,$22,$f0,$30,$8c
             dfb   $ff,$cc,$ff,$b0,$0b,$b9,$00,$02
             dfb   $c9,$2c,$f0,$04,$c8,$4c,$ff,$98
             dfb   $38,$ed,$ff,$8d,$ff,$ad,$ff,$8d
             dfb   $ff,$a9,$02,$8d,$ff,$cc,$ff,$b0
             dfb   $01,$c8,$8c,$ff,$60,$c8,$8c,$ff
             dfb   $cc,$ff,$b0,$0b,$b9,$00,$02,$c9
             dfb   $22,$f0,$04,$c8,$4c,$ff,$98,$38
             dfb   $ed,$ff,$8d,$ff,$ad,$ff,$8d,$ff
             dfb   $a9,$02,$8d,$ff,$cc,$ff,$b0,$0e
             dfb   $c8,$cc,$ff,$b0,$08,$b9,$00,$02
             dfb   $c8,$c9,$2c,$d0,$f3,$8c,$ff,$60
HNXIBEND
*--- its placeholders. The $A0 entries are a place INSIDE another helper
*    and eat the byte after them for the offset -- see EMBLOB.
             dfb   $54,$55,$83,$84,$54,$55,$a4,$1b
             dfb   $55,$56,$55,$a4,$3a,$56,$00,$56
             dfb   $01,$02,$55,$54,$56,$55,$a4,$6b
             dfb   $56,$00,$56,$01,$02,$55,$55,$54

EMHIVAL      lda   #HIVALBEND-HIVALB
             sta   BLOBN
             lda   #<HIVALB
             ldy   #>HIVALB
             jmp   EMBLOB

*--- 123 bytes of helper from 111 of blob and 12 of
*    table, where straight-line emits took 555.
HIVALB
             dfb   $ad,$ff,$d0,$08,$a9,$00,$a8,$20
             dfb   $f2,$e2,$18,$60,$a5,$b8,$48,$a5
             dfb   $b9,$48,$ad,$ff,$18,$6d,$ff,$85
             dfb   $1a,$ad,$ff,$69,$00,$85,$1b,$a0
             dfb   $00,$b1,$1a,$48,$a9,$00,$91,$1a
             dfb   $ad,$ff,$38,$e9,$01,$85,$b8,$ad
             dfb   $ff,$e9,$00,$85,$b9,$20,$b1,$00
             dfb   $20,$4a,$ec,$ad,$ff,$18,$6d,$ff
             dfb   $85,$1a,$ad,$ff,$69,$00,$85,$1b
             dfb   $a9,$00,$8d,$ff,$a5,$b8,$c5,$1a
             dfb   $d0,$0b,$a5,$b9,$c5,$1b,$d0,$05
             dfb   $a9,$01,$8d,$ff,$a0,$00,$68,$91
             dfb   $1a,$68,$85,$b9,$68,$85,$b8,$ad
             dfb   $ff,$d0,$02,$38,$60,$18,$60
HIVALBEND
*--- its placeholders, one byte each and in order. See EMBLOB for what
*    the ranges mean; the table FOLLOWS the blob because that is how
*    EMBLOB finds it.
             dfb   $00,$01,$00,$02,$01,$02,$01,$00
             dfb   $02,$57,$57,$57

EMHPMSG      lda   #$85
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
             lda   HPMSG
             clc
             adc   #$08
             sta   TMPP
             lda   HPMSG+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHIREENT -- ?REENTER
*
*   7 bytes
*--------------------------------------
EMHIREENT    lda   #$a9
             jsr   EMIT
             lda   MREENT
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   MREENT+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HPMSG
             jsr   EMIT
             lda   HPMSG+1
             jmp   EMIT

*--------------------------------------
* EMHIEXTRA -- ?EXTRA IGNORED, if anything on the line went unread
*
*   16 bytes
*--------------------------------------
EMHIEXTRA    lda   #$ad
             jsr   EMIT
             lda   #$14
             jsr   EMSCOFS
             lda   #$cd
             jsr   EMIT
             lda   #$15
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   MEXTRA
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   MEXTRA+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HPMSG
             jsr   EMIT
             lda   HPMSG+1
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* EMHICOPY -- an input item into a string of its own
*
* DATA items can be pointed at where they lie, because they lie in the
* program and never move. An input line cannot: the next INPUT reads over it.
* So this allocates and copies, which is what Applesoft does too.
*
* SDA IS EMPTIED BEFORE THE ALLOCATION, and that is the whole point of writing
* this rather than calling the slice helper. Allocating may collect, the
* collector walks the roots, and SDA is a root -- pointing at $0200, which is
* not in the heap and belongs to no block. A root aimed outside the heap is
* not a question worth asking of the collector, so it is not asked: the
* length goes to zero first and the pointer is kept in scratch instead.
*
*   63 bytes
*--------------------------------------
EMHICOPY     lda   #$ad
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$8d
             jsr   EMIT
             lda   #$18
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$60
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$8d
             jsr   EMIT
             lda   #$19
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$18
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
             lda   #$84
             jsr   EMIT
             lda   #$1f
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$8c
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$18
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$ae
             jsr   EMIT
             lda   #$19
             jsr   EMSCOFS
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$cc
             jsr   EMIT
             lda   #$18
             jsr   EMSCOFS
             lda   #$b0
             jsr   EMIT
             lda   #$0a
             jsr   EMIT
             lda   #$bd
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1e
             jsr   EMIT
             lda   #$e8
             jsr   EMIT
             lda   #$c8
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HICOPY
             clc
             adc   #$2f
             sta   TMPP
             lda   HICOPY+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$60
             jmp   EMIT


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
EMHJOIN      lda   #HJOINBEND-HJOINB
             sta   BLOBN
             lda   #<HJOINB
             ldy   #>HJOINB
             jmp   EMBLOB

*--- 109 bytes of helper from 90 of blob and 21 of
*    table, where straight-line emits took 466.
HJOINB
             dfb   $ad,$ff,$18,$6d,$ff,$90,$07,$a9
             dfb   $ff,$a0,$ff,$4c,$ff,$8d,$ff,$20
             dfb   $ff,$8d,$ff,$85,$1e,$8c,$ff,$84
             dfb   $1f,$ad,$ff,$85,$1a,$ad,$ff,$85
             dfb   $1b,$a0,$00,$cc,$ff,$b0,$07,$b1
             dfb   $1a,$91,$1e,$c8,$d0,$f4,$98,$18
             dfb   $65,$1e,$85,$1e,$90,$02,$e6,$1f
             dfb   $ad,$ff,$85,$1a,$ad,$ff,$85,$1b
             dfb   $a0,$00,$cc,$ff,$b0,$07,$b1,$1a
             dfb   $91,$1e,$c8,$d0,$f4,$ad,$ff,$8d
             dfb   $ff,$ad,$ff,$8d,$ff,$ad,$ff,$8d
             dfb   $ff,$60
HJOINBEND
*--- its placeholders, one byte each and in order. See EMBLOB for what
*    the ranges mean; the table FOLLOWS the blob because that is how
*    EMBLOB finds it.
             dfb   $03,$00,$c0,$e0,$81,$45,$82,$43
             dfb   $44,$04,$05,$03,$01,$02,$00,$45
             dfb   $00,$43,$01,$44,$02

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
EMHGC        lda   #HGCB1E-HGCB1
             sta   BLOBN
             lda   #<HGCB1
             ldy   #>HGCB1
             jsr   EMBLOB
             jsr   EMSETRUN
             lda   #HGCB2E-HGCB2
             sta   BLOBN
             lda   #<HGCB2
             ldy   #>HGCB2
             jsr   EMBLOB
             lda   PC
             sta   HBNDHI
             lda   PC+1
             sta   HBNDHI+1
             lda   #HGCB3E-HGCB3
             sta   BLOBN
             lda   #<HGCB3
             ldy   #>HGCB3
             jsr   EMBLOB
             lda   PC
             sta   HBNDLO
             lda   PC+1
             sta   HBNDLO+1
             lda   #HGCB4E-HGCB4
             sta   BLOBN
             lda   #<HGCB4
             ldy   #>HGCB4
             jsr   EMBLOB
             jsr   EMSETRUN
             lda   #HGCB5E-HGCB5
             sta   BLOBN
             lda   #<HGCB5
             ldy   #>HGCB5
             jmp   EMBLOB

*--- WRITTEN AS DATA AND COPIED, not as 186 `lda #x : jsr EMIT` pairs. That
*    cost five bytes of compiler for each byte of program and made this the
*    largest thing in the image by a wide margin. FIVE RUNS, because three
*    things interrupt the copy and none of them can be a byte in a blob: the
*    two SETRUNs, which emit thirteen bytes apiece, and the two points where
*    PC is captured to say where the byte about to be written will land.
*
*    HRUNA, HGC and FINPC are named through BVARS now rather than loaded
*    here. HGC is the one that carries an offset -- $0a into the collector,
*    the entry a full heap jumps back to -- which is the marker kind that
*    eats the following table byte.

HGCB1
             dfb   $a5,$73,$8d,$ff,$a5,$74,$8d,$ff
             dfb   $a9,$00,$8d,$ff,$8d,$ff
HGCB1E
             dfb   $46,$47,$4a,$4b

HGCB2
             dfb   $a0,$00,$b1,$1a,$f0,$4e,$c8,$b1
             dfb   $1a,$85,$1e,$c8,$b1,$1a,$85,$1f
             dfb   $a5,$1f,$c9
HGCB2E

HGCB3
             dfb   $ff,$90,$3e,$d0,$06,$a5,$1e,$c9
HGCB3E
             dfb   $e5

HGCB4
             dfb   $ff,$90,$36,$a5,$1f,$cd,$ff,$90
             dfb   $09,$d0,$2d,$a5,$1e,$cd,$ff,$b0
             dfb   $26,$a5,$1f,$cd,$ff,$90,$1f,$d0
             dfb   $09,$a5,$1e,$cd,$ff,$90,$16,$f0
             dfb   $14,$a5,$1e,$8d,$ff,$a5,$1f,$8d
             dfb   $ff,$a5,$1a,$8d,$ff,$a5,$1b,$8d
             dfb   $ff,$18,$a5,$1a,$69,$03,$85,$1a
             dfb   $90,$02,$e6,$1b,$20,$ff,$d0,$9c
             dfb   $ad,$ff,$0d,$ff,$f0,$7d,$ad,$ff
             dfb   $85,$1a,$ad,$ff,$85,$1b,$a0,$00
             dfb   $b1,$1a,$8d,$ff,$ad,$ff,$38,$ed
             dfb   $ff,$85,$1e,$ad,$ff,$e9,$00,$85
             dfb   $1f,$ad,$ff,$85,$1c,$ad,$ff,$85
             dfb   $1d,$ac,$ff,$88,$b1,$1c,$91,$1e
             dfb   $c0,$00,$d0,$f7
HGCB4E
             dfb   $c5,$47,$46,$4b,$4a,$4a,$4b,$48
             dfb   $49,$86,$4a,$4b,$48,$49,$4c,$46
             dfb   $4c,$47,$4a,$4b,$4c

HGCB5
             dfb   $a0,$01,$b1,$1a,$cd,$ff,$d0,$13
             dfb   $c8,$b1,$1a,$cd,$ff,$d0,$0b,$a0
             dfb   $01,$a5,$1e,$91,$1a,$c8,$a5,$1f
             dfb   $91,$1a,$18,$a5,$1a,$69,$03,$85
             dfb   $1a,$90,$02,$e6,$1b,$20,$ff,$d0
             dfb   $d4,$a5,$1e,$8d,$ff,$a5,$1f,$8d
             dfb   $ff,$4c,$ff,$ad,$ff,$8d,$ff,$ad
             dfb   $ff,$8d,$ff,$60
HGCB5E
             dfb   $4a,$4b,$86,$46,$47,$a7,$0a,$46
             dfb   $41,$47,$42



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
*
* WRITTEN OUT AS A BLOB, not as code that emits it: it was 410 bytes of
* compiler to emit these 91, and it is now 112. See EMBLOB.
*--------------------------------------
EMHVAL       lda   #HVALBEND-HVALB
             sta   BLOBN
             lda   #<HVALB
             ldy   #>HVALB
             jmp   EMBLOB

*--- 91 bytes of helper from 82 of blob and 9 of
*    table, where straight-line emits took 410.
HVALB
             dfb   $ad,$ff,$d0,$06,$a9,$00,$a8,$4c
             dfb   $f2,$e2,$a5,$b8,$48,$a5,$b9,$48
             dfb   $ad,$ff,$18,$6d,$ff,$85,$1a,$ad
             dfb   $ff,$69,$00,$85,$1b,$a0,$00,$b1
             dfb   $1a,$48,$a9,$00,$91,$1a,$ad,$ff
             dfb   $38,$e9,$01,$85,$b8,$ad,$ff,$e9
             dfb   $00,$85,$b9,$20,$b1,$00,$20,$4a
             dfb   $ec,$ad,$ff,$18,$6d,$ff,$85,$1a
             dfb   $ad,$ff,$69,$00,$85,$1b,$a0,$00
             dfb   $68,$91,$1a,$68,$85,$b9,$68,$85
             dfb   $b8,$60
HVALBEND
*--- its placeholders, one byte each and in order. See EMBLOB for what
*    the ranges mean; the table FOLLOWS the blob because that is how
*    EMBLOB finds it.
             dfb   $00,$01,$00,$02,$01,$02,$01,$00
             dfb   $02

EMHNEXTD     lda   #$ad
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$13
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
             lda   #$c9
             jsr   EMIT
             lda   #$ff
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$2f
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$18
             jsr   EMIT
             lda   #$69
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$ad
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
             lda   #$69
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS
             lda   #$18
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$6d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$8d
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
             lda   #$69
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
             lda   #$ee
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$d0
             jsr   EMIT
             lda   #$03
             jsr   EMIT
             lda   #$ee
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
             lda   #$60
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   MDATA
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   MDATA+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   HERR
             jsr   EMIT
             lda   HERR+1
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

NEED3        ora   USES3
             sta   USES3
             rts
NEED2        ora   USES2
             sta   USES2
             rts

UHEAP        equ   $78              ; $08+$10+$20+$40: the ones that allocate

*--- black, green, violet, white, and the four with the high bit set that
*    shift the pixels half a dot across
HCMASKS      dfb   $00,$2a,$55,$7f,$80,$aa,$d5,$ff

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
* SARRBLOB -- base + 3 * index, for an array of strings
*
* The same shape as the one above with one doubling instead of two, because a
* descriptor is three bytes where a float is five. Entered and left the same
* way, and just as free of anything absolute, so it needs no fixing up either.
*--------------------------------------
SARRBLOB     dfb   $85,ZPB          ; STA base lo
             dfb   $84,ZPB+1        ; STY base hi
             dfb   $a5,FACLO
             dfb   $85,ZPB+2
             dfb   $a5,FACHI
             dfb   $85,ZPB+3
             dfb   $06,ZPB+2        ; ASL, ROL: once round is twice
             dfb   $26,ZPB+3
             dfb   $18              ; CLC -- and the index once more is three
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
SARRBEND
SHELPSZ      equ   SARRBEND-SARRBLOB

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
             sta   USES3
             sta   FSTKTOP
             sta   FSTKMAX          ; NOT LEFT OVER: the closed-loop scan reads
                                    ; FSTKV up to here, and an uninitialised
                                    ; one sends it through entries no FOR ever
                                    ; wrote
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
             beq   :setup
             jmp   :keep            ; the list below has outgrown a branch
:setup       lda   ORG
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
             sta   HNEXTD
             sta   DTAB
             sta   MDATA
             sta   HPOKE
             sta   HCALL
             sta   HINPUT
             sta   HNEXTI
             sta   HIVAL
             sta   HPMSG
             sta   HIREENT
             sta   HIEXTRA
             sta   MREENT
             sta   MEXTRA
             sta   HICOPY
             sta   HSARR
             sta   HMUL
             sta   HCTAB
             sta   MOOM
             sta   MLONG
*--- WHERE THE ALLOCATOR'S FLOOR IS, before there is an allocator.
*
*    HDIMB always writes the new break to those two bytes, and EMHALLOC only
*    records where they are if the heap is emitted at all -- which it is not
*    for a program with arrays and no strings. Pointed at the array break
*    itself, the write lands on the value it has just stored there and does
*    nothing; pointed at a stale address it landed in screen memory, which is
*    how this was found: a lone Q, being the low byte of the break.
             lda   ABRKA
             sta   HBNDLO
             lda   ABRKA+1
             sta   HBNDLO+1
             lda   ABRKA
             clc
             adc   #$01
             sta   HBNDHI
             lda   ABRKA+1
             adc   #$00
             sta   HBNDHI+1

             lda   ORG+1
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
             sta   HNEXTD+1
             sta   DTAB+1
             sta   MDATA+1
             sta   HPOKE+1
             sta   HCALL+1
             sta   HINPUT+1
             sta   HNEXTI+1
             sta   HIVAL+1
             sta   HPMSG+1
             sta   HIREENT+1
             sta   HIEXTRA+1
             sta   MREENT+1
             sta   MEXTRA+1
             sta   HICOPY+1
             sta   HSARR+1
             sta   HMUL+1
             sta   HCTAB+1
             sta   MOOM+1
             sta   MLONG+1
:keep

             jsr   REWIND
             bcc   :ready
             jmp   :fail            ; :fail is a long way down this routine
:ready

             lda   ORG
             sta   PC
             sta   OUTBASE
             lda   ORG+1
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
             bcs   :abase
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

*--- AND THE ARRAY BASES, in the same order LAYOUT counted them. Emitted as
*    data rather than left to the zero fill below, because a subscript reads
*    its array's base from here. For an array whose size is known these are
*    fixed now; ABASES is where a runtime DIM will write instead.
:abase       lda   #$00
             sta   ABI
:ab          lda   ABI
             cmp   NARR
             bcs   :sabase
             sta   TMPA
             jsr   AADDR            ; TMPP = where array TMPA's elements start
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             inc   ABI
             jmp   :ab

*--- and the bases of the arrays of strings, the same way
:sabase      lda   #$00
             sta   ABI
:sab         lda   ABI
             cmp   NSARR
             bcs   :runtab
             sta   TMPA
             jsr   SAADDR           ; TMPP = where its descriptors start
             lda   TMPP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             inc   ABI
             jmp   :sab

*--- and the run table. Entry 0 is the static run; the others start empty and
*    their DIMs fill them in.
:runtab      lda   SDESCA
             sta   ABTMP
             lda   SDESCA+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             jsr   EMNDESC          ; how many, both halves
             lda   NSDYN
             sta   ABI
             beq   :runz
:rune        lda   #$00             ; four empty bytes per dynamic array
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             dec   ABI
             bne   :rune
:runz

*--- and the array break, which starts where the program ends. FINPC is not
*    known while pass 2 is running; pass 3 uses what pass 2 recorded, the same
*    way the heap allocator's own floor does.
:abrk        lda   FINPC
             sta   ABTMP
             lda   FINPC+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT

*--- The temporaries, the FOR slots and SPSAVE, filled to the address LAYOUT
*    named rather than counted again here. If the two ever disagreed this
*    would not terminate, which is a louder failure than quietly starting the
*    code one byte out.
*
*--- WHERE THE ZERO FILL BEGINS is noted, because CLEAR has to put this range
*    back the way it starts. It cannot simply sweep from the first variable:
*    the array base slots and the collector's run table sit between, and both
*    hold addresses LAYOUT worked out and nothing at run time can rebuild.
             lda   PC
             sta   ZFILLA
             lda   PC+1
             sta   ZFILLA+1
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

*--- HOW MANY RUNS THE COLLECTOR HAS. SCRA is in the zero-filled range, so
*    this one is stored by code rather than laid down as data.
             lda   #$a9
             jsr   EMIT
             lda   NSDYN
             clc
             adc   #$01
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$29             ; 41
             jsr   EMSCOFS

*--- and the DATA pointer at the first item. DTAB is not known until the
*    items have been emitted, which is after all of this -- so it is resolved
*    the way a forward GOTO is.
*--- FDATA, not the running tally: see pass 1. The tally is still empty here.
             lda   FDATA
             beq   :nodat
             lda   #$a9
             jsr   EMIT
             lda   DTAB
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   DTAB+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
:nodat

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
             lda   USES3
             and   #$02
             beq   :nohct
             lda   PC
             sta   HCTAB
             lda   PC+1
             sta   HCTAB+1
             lda   #$00
             sta   EMI
:hct         ldx   EMI
             lda   HCMASKS,x
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #$08
             bcc   :hct
:nohct       lda   USES3
             and   #$01
             beq   :nomul
             lda   PC
             sta   HMUL
             lda   PC+1
             sta   HMUL+1
             jsr   EMHMUL
:nomul       lda   USES2
             and   #$80
             beq   :nosarr
             lda   PC
             sta   HSARR
             lda   PC+1
             sta   HSARR+1
             lda   #$00
             sta   EMI
:sb          ldy   EMI
             lda   SARRBLOB,y
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #SHELPSZ
             bcc   :sb
:nosarr

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
             lda   USES2            ; a DIM whose size is worked out at runtime
             and   #$10
             beq   :nodim
             lda   PC
             sta   HDIMA
             lda   PC+1
             sta   HDIMA+1
             jsr   EMHDIM
:nodim       lda   NSDYN            ; and the string kind, which pass 1 counted
             beq   :nosdim
             lda   PC
             sta   HSDIMA
             lda   PC+1
             sta   HSDIMA+1
             jsr   EMHSDIM
:nosdim

*--- The heap and the collector, which any of the four that allocate bring in
*    with them. In an order where each one's address is already known by the
*    time the next refers to it: the messages, the error exit, the collector,
*    then the allocator that calls both.
             lda   USES
             and   #UHEAP
             bne   :heap
             lda   USES2            ; a string INPUT allocates too
             and   #$40
             bne   :heap
             lda   USES2            ; and so does a runtime DIM: it can run out
             and   #$10             ; of room just as an allocation can
             bne   :heap
             jmp   :nohmsg
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

:nohmsg
             lda   USES3            ; a numeric GET has a message of its
             and   #$04             ; own, string program or not
             beq   :nosyn
             lda   PC
             sta   MSYN
             lda   PC+1
             sta   MSYN+1
             lda   #<MSGSYN
             ldy   #>MSGSYN
             jsr   EMMSG
:nosyn
*--- THE ERROR EXIT IS NOT THE HEAP'S ALONE. Running out of DATA reports
*    through it too, so it is wanted by any program that READs -- and one
*    that READs without ever building a string left it unemitted. The JMP
*    then went to the placeholder pass 2 seeds these with, which is the
*    program's own entry, so OUT OF DATA restarted the program instead of
*    saying so. Nothing in the suite runs out of items, which is why it went
*    unseen; the disassembly of a compiled READ is what showed it.
             lda   USES
             and   #UHEAP
             bne   :wanterr
             lda   USES2
             and   #$40
             bne   :wanterr
             lda   FDATA
             bne   :wanterr
             lda   USES3            ; a numeric GET stops through HERR too
             and   #$04
             beq   :noerr
:wanterr     lda   PC
             sta   HERR
             lda   PC+1
             sta   HERR+1
             jsr   EMHERR
:noerr

*--- and the rest of it belongs to the heap alone
             lda   USES
             and   #UHEAP
             bne   :heap2
             lda   USES2
             and   #$40
             bne   :heap2
             lda   NSDYN            ; a runtime DIM A$(N) puts a run in the
             bne   :heap2           ; collector's table, so it needs one
             jmp   :noheap
:heap2       lda   PC               ; the run walker FIRST: the collector
             sta   HRUNA            ; calls it, so its address must be known
             lda   PC+1
             sta   HRUNA+1
             jsr   EMHRUN

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
:noval       lda   FDATA            ; the same answer the prologue used, so the
             beq   :nodata           ; table is there if the pointer was set
             lda   PC
             sta   MDATA
             lda   PC+1
             sta   MDATA+1
             lda   #<MSGDATA2
             ldy   #>MSGDATA2
             jsr   EMMSG
             lda   PC
             sta   HNEXTD
             lda   PC+1
             sta   HNEXTD+1
             jsr   EMHNEXTD
             lda   PC                ; and the items themselves
             sta   DTAB
             lda   PC+1
             sta   DTAB+1
             jsr   EMDATA
:nodata

*--- The six an INPUT is made of, in an order where each one's address is
*    already recorded by the time the next refers to it.
             lda   USES2
             and   #$20
             bne   :inp
             jmp   :noinput
:inp         lda   PC
             sta   MREENT
             lda   PC+1
             sta   MREENT+1
             lda   #<MSGREENT
             ldy   #>MSGREENT
             jsr   EMMSG
             lda   PC
             sta   MEXTRA
             lda   PC+1
             sta   MEXTRA+1
             lda   #<MSGEXTRA
             ldy   #>MSGEXTRA
             jsr   EMMSG
             lda   PC
             sta   HPMSG
             lda   PC+1
             sta   HPMSG+1
             jsr   EMHPMSG
             lda   PC
             sta   HIREENT
             lda   PC+1
             sta   HIREENT+1
             jsr   EMHIREENT
             lda   PC
             sta   HIEXTRA
             lda   PC+1
             sta   HIEXTRA+1
             jsr   EMHIEXTRA
             lda   PC
             sta   HINPUT
             lda   PC+1
             sta   HINPUT+1
             jsr   EMHINPUT
             lda   PC
             sta   HNEXTI
             lda   PC+1
             sta   HNEXTI+1
             jsr   EMHNEXTI
             lda   PC
             sta   HIVAL
             lda   PC+1
             sta   HIVAL+1
             jsr   EMHIVAL
:noinput
             lda   USES2            ; a string INPUT wants the copier, and so
             and   #$40             ; does GET: it is not part of INPUT
             beq   :nohicopy
             lda   PC
             sta   HICOPY
             lda   PC+1
             sta   HICOPY+1
             jsr   EMHICOPY
:nohicopy

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
             beq   :remj
             cmp   #TDIMK
             beq   :dimj
             cmp   #TON
             beq   :on
             cmp   #TPOKE
             beq   :poke
             cmp   #TREAD
             beq   :read
             cmp   #TRESTORE
             beq   :rest
             cmp   #TDATAK
             beq   :datak
             cmp   #TINPUT
             beq   :input
             cmp   #TDEFK
             beq   :defk
             cmp   #TCALL
             beq   :call
             cmp   #TFORK
             beq   :for
             cmp   #TNEXT
             beq   :next
             cmp   #$80
             bcs   :second          ; some other keyword: try the second list
             jsr   ISALNUM
             bcs   :unsup
             jmp   GLET             ; a bare name: an implied LET
:second      jmp   GSTMT2

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
:input       jmp   GINPUT
:defk        jmp   GDEF
:dimj        jmp   :dim             ; the body is at the end: this is in reach
:remj        jmp   :rem
:read        jmp   GREAD
:rest        jmp   GRESTORE
:datak       jmp   GDATA
:call        jmp   GCALL

*--- DIM generates nothing at all: pass 1 read the sizes and the space is
*    already in the file. Its arguments are skipped rather than compiled --
*    A(20) here is a declaration, and reading it as a subscript would send
*    the generator looking for a constant 20 that pass 1 never made.
:dim         jmp   GDIM

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
             cmp   #'%'
             beq   :intj
             cmp   #'('
             beq   :arrj
             bne   :plainlet
:arrj        jmp   GLETARR          ; GLETSTR sits between the two now
:intj        jmp   GLETINT
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
GLETSTR
             jmp   :head
:sarrj       jmp   :sarr            ; the element case is past the plain one
:badj        jmp   :bad
:head        jsr   NEXTB            ; a bracket after the $ makes it an array
             bcs   :plain
             sta   CH               ; PUTBACK hands back CH, not A
             cmp   #'('
             beq   :sarrj
             jsr   PUTBACK
:plain       jsr   SVFIND
             bcs   :badj
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

*--- Into an element of an array of strings. The element's address is worked
*    out first and PUT AWAY, because building the value can allocate, and an
*    allocation can collect: what moves is the text, never the descriptor, so
*    the address stays good -- but the accumulator and the zero page it is
*    held in do not survive an expression.
:sarr        jsr   SAFIND
             bcs   :sabad
             jsr   EMSSUBS
             bcs   :sabad
             jsr   EMSASAVE
             jsr   NEXTB
             bcs   :sabad
             cmp   #TEQ
             bne   :sabad
             lda   #$00
             sta   ISSTR
             jsr   ESUM
             bcs   :sabad
             lda   ISSTR
             beq   :sanotstr
             lda   #$00
             sta   ISSTR
             jsr   EMSAPUT
             clc
             rts
:sanotstr    lda   #$1c             ; STRING AGAINST NUMBER
             jsr   SETBAD
:sabad       sec
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

*--- HOW DEEP IT HAS EVER BEEN. A NEXT is allowed to name a loop that another
*    NEXT has already closed -- see GNEXT -- and the entry is still sitting
*    there above FSTKTOP when it does.
             lda   FSTKTOP
             cmp   FSTKMAX
             bcc   :nomax
             sta   FSTKMAX
:nomax       inc   FORN
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

*--- ONE FOR MAY HAVE SEVERAL NEXTS. Applesoft matches them on a stack it
*    keeps while the program runs, so a loop with an exit on either side of an
*    IF can be closed by whichever NEXT is reached:
*
*        930 FOR N = 1 TO W
*        945 IF ... THEN ... : NEXT N: RETURN
*        960 ...             : NEXT N: RETURN
*
*    This compiler matches them where it reads them, and the second NEXT found
*    the loop already closed and called it a NEXT WITHOUT FOR. KALEIDO is
*    built that way throughout.
*
*    So: close it as before, and if there is nothing open -- or the name does
*    not match what is -- look through the entries that HAVE been closed.
*    Popping only moves FSTKTOP down, so they are still there, and the code a
*    second NEXT wants is the same code the first one emitted.
:pop         lda   FSTKTOP
             bne   :open
             jmp   :closed          ; the scan is at the end of the routine
:open        dec   FSTKTOP
             ldx   FSTKTOP
             lda   VARI
             cmp   #$ff
             beq   :ok
             cmp   FSTKV,x
             beq   :ok
             inc   FSTKTOP          ; not this one: leave it open
             jmp   :closed
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

*--- NEXT S,X CLOSES TWO LOOPS, innermost first, and is the same as NEXT S
*    followed by NEXT X. A comma here means go round again for the next name.
*    The loop that was just closed has already been taken off the stack, so
*    what the second name is matched against is the one outside it.
             jsr   PEEK
             bcs   :done
             cmp   #$2c
             bne   :done
             jsr   NEXTB            ; the comma
             jmp   GNEXT
:done        clc
             rts

*--------------------------------------
* GDATA -- a DATA statement generates nothing
*
* Pass 1 took its items; all that is left is to step over exactly the same
* bytes, which means honouring the quotes the same way -- a colon inside one
* does not end the statement.
*--------------------------------------
*--- A LOOP THAT IS ALREADY CLOSED. Search from the deepest it has ever been
*    down to the top of the open ones, most recent first. An unnamed NEXT
*    takes the innermost, which is the one it would have taken when open.
:closed      ldx   FSTKMAX
:cloop       cpx   FSTKTOP
             bne   :cstep
             jmp   NEXTNONE         ; nothing open and nothing closed matches
:cstep       dex
             lda   VARI
             cmp   #$ff
             beq   :okj
             cmp   FSTKV,x
             beq   :okj
             jmp   :cloop
:okj         jmp   :ok              ; the shared tail is back at the top

GDATA        lda   #$00
             sta   DQUOTE
:loop        jsr   NEXTB
             bcs   :bad
             sta   CH
             beq   :done
             cmp   #'"'
             bne   :notq
             lda   DQUOTE
             eor   #$01
             sta   DQUOTE
             jmp   :loop
:notq        lda   DQUOTE
             bne   :loop
             lda   CH
             cmp   #':'
             bne   :loop
:done        jsr   PUTBACK
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GRESTORE -- back to the first item
*--------------------------------------
GRESTORE     lda   #$10
             jsr   NEED2
             lda   #$a9
             jsr   EMIT
             lda   DTAB
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$12
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   DTAB+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$13
             jsr   EMSCOFS
             clc
             rts

*--------------------------------------
* GINPUT -- INPUT [ "prompt" ; ] var [ , var ]...
*
* All of it asked of the machine rather than remembered, because INPUT's rules
* are close enough to DATA's to invite guessing and different in two places:
*
*   INPUT A       prints ?        INPUT "P";A   prints P and no ?
*   an unquoted item loses its LEADING spaces and keeps its trailing ones
*   too few items prints ?? and asks again, keeping what it already has
*   a bad number prints ?REENTER and RUNS THE WHOLE STATEMENT AGAIN
*   anything left over prints ?EXTRA IGNORED
*
* The last two shape the code. ?REENTER re-runs the statement, so the first
* thing done here is remember where the statement's code begins and the
* bad-number path jumps back to it -- backwards, inside one statement, so the
* address is already known in both passes and needs none of the machinery a
* forward reference does.
*--------------------------------------
GINPUT       lda   #$20
             jsr   NEED2
             lda   PC               ; where ?REENTER comes back to
             sta   INPPC
             lda   PC+1
             sta   INPPC+1

             jsr   PEEK
             bcs   :qmark
             cmp   #$22
             bne   :qmark

*--- a prompt of its own, and then NO question mark
             jsr   EXPR
             bcs   :badj
             lda   ISSTR
             beq   :badj            ; INPUT 3;A is not a prompt
             lda   #$02
             jsr   NEED
             lda   #$20
             jsr   EMIT
             lda   HSPR
             jsr   EMIT
             lda   HSPR+1
             jsr   EMIT
             lda   #$00
             sta   ISSTR
             jsr   NEXTB
             bcs   :badj
             cmp   #';'
             bne   :badj
             jmp   :line
:badj        jmp   :bad

*--- LDA #'?' : JSR COUT
:qmark       lda   #$a9
             jsr   EMIT
             lda   #$bf
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUT
             jsr   EMIT
             lda   #>COUT
             jsr   EMIT

:line        lda   #$20             ; JSR HINPUT
             jsr   EMIT
             lda   HINPUT
             jsr   EMIT
             lda   HINPUT+1
             jsr   EMIT
             jmp   :one

:strj        jmp   :str
:elemj       jmp   :elem
:badj2       jmp   :bad

:one         jsr   NEXTB
             bcs   :badj2
             sta   CH
             jsr   ISALNUM
             bcs   :badj2
             jsr   GETNAME
             bcs   :badj2
             lda   CH
             cmp   #'$'
             beq   :dollar
             cmp   #'('
             beq   :elemj

*--- a plain number
             jsr   GETVAR2
             bcs   :badj2
             jsr   PUTBACK
             lda   VARI
             pha
             jsr   EMNEXTI
             jsr   EMIVAL
             pla
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP
             jmp   :more

*--- A BRACKET AFTER THE $ MAKES IT AN ELEMENT, the same test GLETSTR makes.
*    Without it INPUT A$(J) looked up a string VARIABLE called A$, did not
*    find one, and said UNKNOWN VARIABLE about a line that names an array.
:dollar      jsr   NEXTB
             bcs   :str
             sta   CH               ; PUTBACK hands back CH, not A
             cmp   #'('
             beq   :sarrin
             jsr   PUTBACK

*--- a string, which has to be copied out of the line before the next INPUT
*    reads over it
:str         lda   #$40             ; the heap, for the copy
             jsr   NEED2
             jsr   SVFIND
             bcs   :badj2
             jsr   SVADDR
             lda   TMPP
             sta   DSTSV
             lda   TMPP+1
             sta   DSTSV+1
             jsr   EMNEXTI
             lda   #$20             ; JSR HICOPY
             jsr   EMIT
             lda   HICOPY
             jsr   EMIT
             lda   HICOPY+1
             jsr   EMIT
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
             jmp   :more

*--- INPUT A$(J) -- the same, into an element. The address is worked out and
*    kept first, exactly as an assignment to one does it: EMSASAVE puts it in
*    the program's own scratch rather than zero page, so it survives the copy
*    to the heap and any collection that copy sets off. The array's
*    descriptors do not move in a collection -- they are not in the heap --
*    so the address stays good even for an array sized at run time.
:sarrin      jsr   GINSARR          ; ITS OWN ROUTINE, and a JSR not a JMP: it
             bcs   :badj3           ; has to come back to this loop, not
             jmp   :more            ; return to whoever called GINPUT


*--- Under the string block's JMP, so nothing falls into it.
:badj3       jmp   :bad

*--- an element, whose address is worked out first: reading the item runs the
*    parser over the accumulator, exactly as it does for READ
:elem        jsr   GETARR
             bcs   :badj3
             jsr   EMSUBS
             bcs   :badj3
             lda   #$85             ; STA ZPELEM
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$84
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             jsr   EMNEXTI
             jsr   EMIVAL
             lda   #$a6             ; LDX ZPELEM
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$a4
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             lda   #$20             ; JSR MOVMF
             jsr   EMIT
             lda   #<MOVMF
             jsr   EMIT
             lda   #>MOVMF
             jsr   EMIT

:more        jsr   PEEK
             bcs   :done
             cmp   #$2c
             bne   :done
             jsr   NEXTB
             jmp   :one

*--- and say so if the line had more on it than was asked for
:done        lda   #$20
             jsr   EMIT
             lda   HIEXTRA
             jsr   EMIT
             lda   HIEXTRA+1
             jsr   EMIT
             clc
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* EMNEXTI -- JSR the item reader
*--------------------------------------
EMNEXTI      lda   #$20
             jsr   EMIT
             lda   HNEXTI
             jsr   EMIT
             lda   HNEXTI+1
             jmp   EMIT

*--------------------------------------
* EMIVAL -- the item as a number, or ?REENTER and round again
*
*    0  JSR HIVAL    3
*    3  BCC ok       2   -> 11
*    5  JSR HIREENT  3
*    8  JMP INPPC    3
*   11  ...          <- ok
*--------------------------------------
EMIVAL       lda   #$20
             jsr   EMIT
             lda   HIVAL
             jsr   EMIT
             lda   HIVAL+1
             jsr   EMIT
             lda   #$90             ; BCC over the two that go back
             jsr   EMIT
             lda   #$06
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   HIREENT
             jsr   EMIT
             lda   HIREENT+1
             jsr   EMIT
             lda   #$4c
             jsr   EMIT
             lda   INPPC
             jsr   EMIT
             lda   INPPC+1
             jmp   EMIT

*--------------------------------------
* EMHMUL -- MR = MA * MB, in the compiled program
*
* Shift and add. A subscript with a comma in it needs the extents
* multiplied at run time; one with a single subscript never calls this,
* and a program without a multi-dimensional array never carries it.
*
*   47 bytes
*--------------------------------------
EMHMUL       lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$22
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$23
             jsr   EMSCOFS
             lda   #$a2
             jsr   EMIT
             lda   #$10
             jsr   EMIT
             lda   #$4e
             jsr   EMIT
             lda   #$21
             jsr   EMSCOFS
             lda   #$6e
             jsr   EMIT
             lda   #$20
             jsr   EMSCOFS
             lda   #$90
             jsr   EMIT
             lda   #$13
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$22
             jsr   EMSCOFS
             lda   #$6d
             jsr   EMIT
             lda   #$1e
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$22
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$23
             jsr   EMSCOFS
             lda   #$6d
             jsr   EMIT
             lda   #$1f
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$23
             jsr   EMSCOFS
             lda   #$0e
             jsr   EMIT
             lda   #$1e
             jsr   EMSCOFS
             lda   #$2e
             jsr   EMIT
             lda   #$1f
             jsr   EMSCOFS
             lda   #$ca
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$dc
             jsr   EMIT
             lda   #$60
             jmp   EMIT

*--------------------------------------
* SAFIND -- the array of strings named in VN0/VN1
*--------------------------------------
SAFIND       lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NSARR
             bcs   :no
             jsr   SASLOT
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
* SAADDR -- TMPP <- where the elements of string array TMPA begin
*--------------------------------------
SAADDR       jsr   SASUM            ; the ones before it, in bytes
             lda   SABASE
             clc
             adc   SATOT
             sta   TMPP
             lda   SABASE+1
             adc   SATOT+1
             sta   TMPP+1
             rts

*--------------------------------------
* EMS2D -- A$(I,J), the index for it, left where one subscript would leave it
*
* The elements are laid out as the one-dimensional array of I*stride+J that
* they are, and the stride was worked out by pass 1 and kept in SATAB. So this
* is the numeric multi-subscript code with the general case taken out: one
* multiply by a number known now, and one add.
*
* TWO SUBSCRIPTS AND NO MORE. A numeric array keeps its extents in DIMTAB and
* takes as many as MAXDIM; a string array keeps one stride and takes two. A
* third is refused rather than dropped.
*
* THE STRIDE IS READ FIRST, before NEXPR is allowed to run: NEXPR compiles a
* whole expression, which may mention another array and leave TMPA pointing
* at it.
*--------------------------------------
EMS2D        jsr   SASLOT           ; SATAB entry for TMPA
             ldy   #$04
             lda   (TMPP),y
             sta   SSTR
             iny
             lda   (TMPP),y
             sta   SSTR+1
             ora   SSTR
             bne   :two
             jmp   :notwo           ; a stride of zero: DIMmed with one
:two

             lda   #$20             ; JSR AYINT -- the first subscript
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT

*--- into the multiply's left, and the stride into its right
             lda   #$a5
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1e
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1f
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   SSTR
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$20
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   SSTR+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$21
             jsr   EMSCOFS
             lda   #$01
             jsr   NEED3            ; this program wants the multiply
             lda   #$20
             jsr   EMIT
             lda   HMUL
             jsr   EMIT
             lda   HMUL+1
             jsr   EMIT

             jsr   NEXPR            ; the second subscript
             bcs   :bad
             jsr   NEXTB
             bcs   :bad
             cmp   #')'
             bne   :badsub
             lda   #$20             ; JSR AYINT
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT

*--- and the index is the product plus it
             lda   #$18             ; CLC
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$22
             jsr   EMSCOFS
             lda   #$65             ; ADC FACLO
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$23
             jsr   EMSCOFS
             lda   #$65             ; ADC FACHI
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             clc
             rts

:notwo       lda   #$27             ; BAD SUBSCRIPT: two given, one DIMmed
             jsr   SETBAD
             sec
             rts
:badsub      lda   #$27
             jsr   SETBAD
:bad         sec
             rts

*--------------------------------------
* EMSSUBS -- the subscript of an array of strings, leaving the element's
*            address in A and Y
*--------------------------------------
EMSSUBS      lda   TMPA
             pha
             jsr   NEXPR
             bcs   :dropj
             jsr   NEXTB
             bcs   :dropj
             cmp   #')'
             beq   :one
             cmp   #$2c             ; A$(I,J) -- the other shape
             bne   :dropbad
             pla                    ; EMS2D wants to know which array before
             sta   TMPA             ; NEXPR runs and moves TMPA on
             pha
             jsr   EMS2D
             bcs   :dropj
             jmp   :base
:dropj       jmp   :drop            ; the real exits are past the base code
:one         lda   #$20             ; JSR AYINT
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
:base        pla
             sta   TMPA
             jsr   SABSLOT          ; where this array's base is kept
             lda   TMPP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   #$ad             ; LDA base
             jsr   EMIT
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   #$ac             ; LDY base+1
             jsr   EMIT
             inc   ABTMP
             bne   :sahi
             inc   ABTMP+1
:sahi        lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   #$80
             jsr   NEED2
             lda   #$20             ; JSR the three-byte address helper
             jsr   EMIT
             lda   HSARR
             jsr   EMIT
             lda   HSARR+1
             jsr   EMIT
             clc
             rts
:dropbad     pla
             lda   #$27
             jsr   SETBAD
             sec
             rts
:drop        pla
             sec
             rts

*--------------------------------------
* EMSAGET -- the descriptor at the address in A and Y, into SDA
*--------------------------------------
*    THE COUNTER LIVES IN MEMORY, NOT IN X. EMIT does nothing in pass 2 and
*    writes to the file in pass 3, and it does not promise to bring X back --
*    so a loop counting in X round a JSR EMIT ends in pass 2 and never ends in
*    pass 3. Which is exactly what it did.
EMSAGET      lda   #$85
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$84
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             sta   SDI
:one         lda   #$b1             ; LDA (ZPELEM),Y
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$8d             ; STA SDA + n
             jsr   EMIT
             lda   SDI
             jsr   EMSDOFS
             lda   SDI
             cmp   #$02
             beq   :done
             lda   #$c8             ; INY
             jsr   EMIT
             inc   SDI
             jmp   :one
:done        rts

*--------------------------------------
* EMSAPUT -- SDA into the descriptor whose address was put by EMSASAVE
*--------------------------------------
EMSASAVE     lda   #$8d
             jsr   EMIT
             lda   #$1a
             jsr   EMSCOFS
             lda   #$8c
             jsr   EMIT
             lda   #$1b
             jmp   EMSCOFS

EMSAPUT      lda   #$ad
             jsr   EMIT
             lda   #$1a
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$1b
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             sta   SDI
:one         lda   #$ad             ; LDA SDA + n
             jsr   EMIT
             lda   SDI
             jsr   EMSDOFS
             lda   #$91             ; STA (ZPELEM),Y
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   SDI
             cmp   #$02
             beq   :done
             lda   #$c8             ; INY
             jsr   EMIT
             inc   SDI
             jmp   :one
:done        rts

*--------------------------------------
* GR, COLOR= and PLOT
*
* The ROM does the work: SETGR puts the screen in low resolution with four
* lines of text left at the bottom, SETCOL spreads the colour across both
* nibbles of a byte, and PLOT wants the row in A and the column in Y.
*
* THE COLUMN IS KEPT IN SCRATCH, not on the stack, because what sits between
* the two coordinates is a whole expression and expressions use the stack.
*--------------------------------------
GGR          lda   #<SETGR
             ldy   #>SETGR
             jmp   EMCALLAY

GCOLOR       jsr   EMCOORD
             bcs   :bad
             lda   #$20
             jsr   EMIT
             lda   #<SETCOL
             jsr   EMIT
             lda   #>SETCOL
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

GPLOT        jsr   EMCOORD          ; the column
             bcs   :bad
             lda   #$8d             ; STA the scratch
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             jsr   NEXTB
             bcs   :bad
             cmp   #$2c
             bne   :badsyn
             jsr   EMCOORD          ; the row
             bcs   :bad
             lda   #$ac             ; LDY the column back
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   #<PLOTROM
             jsr   EMIT
             lda   #>PLOTROM
             jsr   EMIT
             clc
             rts
:badsyn      lda   #$28
             jsr   SETBAD
:bad         sec
             rts

*--------------------------------------
* HLIN a,b AT c  and  VLIN a,b AT c
*
* The ROM draws both: HLINE wants the row in A, the first column in Y and the
* last in H2; VLINE wants the first row in A, the column in Y and the last row
* in V2. Each reads three expressions, and the first is kept in scratch across
* the other two for the same reason PLOT's column is.
*--------------------------------------
GHLIN        jsr   EMLINE3
             bcs   :bad
             lda   #$85             ; STA H2 -- zero page
             jsr   EMIT
             lda   #H2
             jsr   EMIT
             jsr   EMATV            ; the row, left in A
             bcs   :bad
             lda   #$ac             ; LDY the first column back
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   #<HLINROM
             jsr   EMIT
             lda   #>HLINROM
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

GVLIN        jsr   EMLINE3
             bcs   :bad
             lda   #$85             ; STA V2
             jsr   EMIT
             lda   #V2
             jsr   EMIT
             jsr   EMATV            ; the column
             bcs   :bad
             lda   #$a8             ; TAY -- the column goes in Y
             jsr   EMIT
             lda   #$ad             ; and the first row comes back into A
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   #<VLINROM
             jsr   EMIT
             lda   #>VLINROM
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--- the first two of the three: the first into scratch, the second left in A
EMLINE3      jsr   EMCOORD
             bcs   :no
             lda   #$8d
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             jsr   NEXTB
             bcs   :no
             cmp   #$2c
             bne   :syn
             jmp   EMCOORD
:syn         lda   #$28
             jsr   SETBAD
:no          sec
             rts

*--- AT, and then the third
EMATV        jsr   NEXTB
             bcs   :no
             cmp   #TAT
             bne   :syn
             jmp   EMCOORD
:syn         lda   #$28
             jsr   SETBAD
:no          sec
             rts

*--------------------------------------
* HGR, HCOLOR= and HPLOT
*
* A HI-RES COLUMN DOES NOT FIT IN A BYTE. It runs to 279, so unlike every
* coordinate above it this one is wanted whole: AYINT leaves both halves and
* both are kept, the low in X and the high in Y, which is what HPOSN wants
* alongside the row in A.
*--------------------------------------
GHGR         lda   #<HGRROM
             ldy   #>HGRROM
             jmp   EMCALLAY

*--- HGR2 is the OTHER page and the whole screen, not four text rows short of
*    it. Pass 1 already knew this token -- it has to, because a program using
*    HGR2 owns $4000-$5FFF as well and cannot be loaded below $6000 -- so all
*    that was missing was somewhere for pass 2 to send it. GRAPH stopped on
*    line 2000 for want of these seven bytes.
GHGR2        lda   #<HGR2ROM
             ldy   #>HGR2ROM
             jmp   EMCALLAY

*--- THE MASK GOES IN TWO PLACES, and finding out why took reading the ROM.
*
*    A program that snapshotted the zero page either side of an HCOLOR= showed
*    $E4 going to $7F for colour 3 -- the white mask -- so that is where
*    Applesoft keeps it. But the plotting routine at $F457 reads $30:
*
*        JSR $F411 : LDA $1C : EOR ($26),Y : AND $30 : EOR ($26),Y
*        STA ($26),Y : RTS
*
*    peeked out of the ROM and disassembled. Setting only $E4 left the plot
*    drawing in whatever $30 held, which after HGR is zero -- black on a
*    cleared page, invisible, and a sum of nothing.
GHCOLOR      jsr   EMCOORD
             bcs   :bad
             lda   #$02
             jsr   NEED3
             lda   #$29             ; AND #$07
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$aa             ; TAX
             jsr   EMIT
             lda   #$bd             ; LDA table,X
             jsr   EMIT
             lda   HCTAB
             jsr   EMIT
             lda   HCTAB+1
             jsr   EMIT
             lda   #$85             ; STA where HCOLOR= keeps it
             jsr   EMIT
             lda   #HCOLBYTE
             jsr   EMIT
             lda   #$85             ; and where the plotting reads it
             jsr   EMIT
             lda   #HPLOTCOL
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--- HPLOT x,y  /  HPLOT x,y TO x,y TO x,y  /  HPLOT TO x,y
*
*    THE LINE ROUTINE TAKES ITS REGISTERS THE OTHER WAY ROUND from HPOSN,
*    which is not a thing to guess at: HPOSN reads the row from A and the
*    column from X and Y, and $F53A reads the column from A and X and the row
*    from Y. Peeked out of the ROM and disassembled -- it begins by
*    subtracting $E0 and $E1, the position HPOSN last stored.
GHPLOT
             jmp   :start
:badj        jmp   :bad             ; the exits are past the whole of the loop
:herej       jmp   :fromhere
:badsynj     jmp   :badsyn
:start       jsr   PEEK
             bcs   :badj
             cmp   #TTO
             beq   :herej           ; carry on from wherever the last one left
             jsr   NEXPR            ; the column, both halves of it
             bcs   :badj
             lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5             ; LDA FACLO : STA scratch
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$a5             ; LDA FACHI : STA scratch+1
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$25
             jsr   EMSCOFS

             jsr   NEXTB
             bcs   :badj
             cmp   #$2c
             bne   :badsynj
             jsr   EMCOORD          ; the row, left in A
             bcs   :badj
             lda   #$ae             ; LDX the column's low half
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$ac             ; LDY its high half
             jsr   EMIT
             lda   #$25
             jsr   EMSCOFS
             lda   #$20             ; HPLOT0 calls HPOSN itself -- read out
             jsr   EMIT             ; of the ROM, not assumed
             lda   #<HPLOT0
             jsr   EMIT
             lda   #>HPLOT0
             jsr   EMIT

*--- and then any number of TO pairs, each a line from where the last ended
:fromhere
:toloop      jsr   PEEK
             bcs   :done
             cmp   #TTO
             bne   :done
             jsr   NEXTB            ; the TO itself
             jsr   NEXPR            ; the column it goes to
             bcs   :bad
             lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$25
             jsr   EMSCOFS
             jsr   NEXTB
             bcs   :bad
             cmp   #$2c
             bne   :badsyn
             jsr   EMCOORD          ; and the row, left in A
             bcs   :bad
             lda   #$a8             ; TAY -- the row goes in Y for this one
             jsr   EMIT
             lda   #$ad             ; and the column into A and X
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$ae
             jsr   EMIT
             lda   #$25
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   #<HLINEROM
             jsr   EMIT
             lda   #>HLINEROM
             jsr   EMIT
             jmp   :toloop
:done        clc
             rts
:badsyn      lda   #$28
             jsr   SETBAD
:bad         sec
             rts

*--------------------------------------
* GET -- one key, not echoed, into a string variable
*
* THE CHARACTER GOES THROUGH THE HEAP, for the same reason an input line does:
* two GETs in a row would otherwise hand two variables the same address, and
* the second keypress would change what the first had already been given.
*
* It is written where HICOPY reads from -- the input buffer at $0200 -- so the
* copier that INPUT already carries does the allocating.
*
* A NUMERIC GET takes the key as a digit and complains if it is not one, which
* is what Applesoft does -- see the note at :notstr. GET A% is still refused:
* the integer store is a different one and nothing on the card wants it.
*--------------------------------------
GGET
             jmp   :go
:badj        jmp   :bad             ; the exits are past the whole of it
:nostrj      jmp   :notstr
:go          jsr   NEXTB
             bcs   :badj
             sta   CH
             jsr   ISALNUM
             bcs   :badj
             jsr   GETNAME
             lda   CH
             cmp   #'$'
             bne   :nostrj

             lda   #$40             ; the heap, for the copy
             jsr   NEED2
             jsr   SVFIND
             bcs   :badj
             jsr   SVADDR
             lda   TMPP
             sta   DSTSV
             lda   TMPP+1
             sta   DSTSV+1

             lda   #$20             ; JSR RDKEY
             jsr   EMIT
             lda   #<RDKEY
             jsr   EMIT
             lda   #>RDKEY
             jsr   EMIT
             lda   #$29             ; AND #$7F -- our strings are low ascii
             jsr   EMIT
             lda   #$7f
             jsr   EMIT
             lda   #$8d             ; STA $0200, where HICOPY reads
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$02
             jsr   EMIT

             lda   #$a9             ; a descriptor for that one character
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$00
             jsr   EMSDOFS
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSDOFS
             lda   #$a9
             jsr   EMIT
             lda   #$02
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSDOFS

             lda   #$20             ; JSR HICOPY
             jsr   EMIT
             lda   HICOPY
             jsr   EMIT
             lda   HICOPY+1
             jsr   EMIT

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
             clc
             rts
*--- A NUMBER, WHICH IS ONE DIGIT AND NOTHING ELSE. Established on a //e:
*    `GET A` with 7 leaves A=7 and echoes nothing, and anything that is not a
*    digit -- a letter, a space, RETURN -- stops the program on ?SYNTAX ERROR.
*    So the key comes back, loses its high bit, and has '0' taken off it; one
*    unsigned compare then covers both ends at once, because a key below '0'
*    wraps past $0A just as one above '9' passes it.
*
*    THE BRANCH OVER THE ERROR IS A FIXED SEVEN BYTES -- two loads and a jump
*    -- and does not depend on what the store below turns out to be.
:notstr      lda   CH
             cmp   #'%'
             bne   :num             ; the complaint is past the whole emission
             jmp   :noint
:num         jsr   GETVAR2
             bcc   :ok
             jmp   :bad
:ok          lda   VARI
             sta   TMPA

             lda   #$04             ; this program wants ?SYNTAX ERROR
             jsr   NEED3

             lda   #$20             ; JSR RDKEY
             jsr   EMIT
             lda   #<RDKEY
             jsr   EMIT
             lda   #>RDKEY
             jsr   EMIT
             lda   #$29             ; AND #$7F
             jsr   EMIT
             lda   #$7f
             jsr   EMIT
             lda   #$38             ; SEC
             jsr   EMIT
             lda   #$e9             ; SBC #'0'
             jsr   EMIT
             lda   #$30
             jsr   EMIT
             lda   #$c9             ; CMP #$0A -- 0 to 9 and nothing else
             jsr   EMIT
             lda   #$0a
             jsr   EMIT
             lda   #$90             ; BCC over the complaint
             jsr   EMIT
             lda   #$07
             jsr   EMIT
             lda   #$a9             ; LDA #<MSYN
             jsr   EMIT
             lda   MSYN
             jsr   EMIT
             lda   #$a0             ; LDY #>MSYN
             jsr   EMIT
             lda   MSYN+1
             jsr   EMIT
             lda   #$4c             ; JMP HERR
             jsr   EMIT
             lda   HERR
             jsr   EMIT
             lda   HERR+1
             jsr   EMIT

             jsr   EMBYTEFAC        ; the digit, as a float
             bcs   :bad
             jsr   VADDR
             jsr   EMSTP

*--- AND HAND THE TERMINATOR BACK. GETNAME stops on the first byte that is
*    not part of a name and keeps it. For A$ that byte is the $, so the line's
*    terminator is still unread and the statement loop finds it -- which is
*    why the string path above returns without this. For a bare A it IS the
*    terminator, and returning without putting it back sent the loop reading
*    into the next line's link bytes, which it duly reported as STATEMENT NOT
*    YET in a line whose statement was perfectly good.
             jsr   PUTBACK
             clc                    ; EMIT's carry is set in pass 3
             rts

:noint       lda   #$25             ; GET: NOT AN INTEGER VARIABLE
             jsr   SETBAD
:bad         sec
             rts

*--------------------------------------
* PDL and SCRN(, both of which hand back a number the ROM works out
*
* Read out of the ROM rather than remembered: PREAD wants the paddle in X and
* leaves its count in Y, and SCRN wants the row in A and the column in Y and
* halves the row itself. Both answers are a byte, so GIVAYF turns one into a
* float with nothing in the high half.
*--------------------------------------
FPDL         jsr   FARGOPEN
             bcs   :bad
             lda   #$aa             ; TAX -- the paddle number
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<PREAD
             jsr   EMIT
             lda   #>PREAD
             jsr   EMIT
             jmp   EMBYTEFAC
:bad         sec
             rts

FSCRN        jsr   NEXPR            ; the column
             bcs   :bad
             lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d             ; kept across the row's expression
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             jsr   NEXTB
             bcs   :bad
             cmp   #$2c
             bne   :badsyn
             jsr   EMCOORD          ; the row, left in A
             bcs   :bad
             jsr   FARGCLOSE
             bcs   :bad
             lda   #$ac             ; LDY the column back
             jsr   EMIT
             lda   #$24
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   #<SCRNROM
             jsr   EMIT
             lda   #>SCRNROM
             jsr   EMIT
             jmp   EMBYTEFAC
:badsyn      lda   #$28
             jsr   SETBAD
:bad         sec
             rts

*--- the bracket, then one expression, then the bracket
FARGOPEN     jsr   NEXTB
             bcs   :no
             cmp   #'('
             bne   :syn
             jsr   EMCOORD
             bcs   :no
             jmp   FARGCLOSE
:syn         lda   #$28
             jsr   SETBAD
:no          sec
             rts

*--- and the bracket that closes one. Its own exits: the label above opens a
*    scope, so sharing them would put these in it.
FARGCLOSE    jsr   NEXTB
             bcs   :no
             cmp   #')'
             bne   :syn
             clc
             rts
:syn         lda   #$28
             jsr   SETBAD
:no          sec
             rts

*--- the byte in A as a float, and the expression is numeric
EMBYTEFAC    lda   #$a8             ; TAY -- the low half
             jsr   EMIT
             lda   #$a9             ; and nothing in the high
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
             sta   ISSTR
             sta   PENDOK
             clc
             rts

*--------------------------------------
* GSTMT2 -- the statements that did not fit in GENSTMT's list
*
* Not a matter of taste: that list's branches reach their targets with little
* to spare, and adding a test to the front of it pushes the ones at the back
* out of range. A second list costs one jump for the keywords that reach it
* and leaves the first one alone.
*--------------------------------------
GSTMT2       lda   CH
             cmp   #TVTAB
             beq   :vtab
             cmp   #THTAB
             beq   :htab
             cmp   #THOME
             beq   :homek
             cmp   #TTEXTK
             beq   :textk
             cmp   #TINVERSE
             beq   :invk
             cmp   #TNORMAL
             beq   :normk
             cmp   #TFLASH
             beq   :flashk
             cmp   #TGETK
             beq   :getk
             cmp   #TGR
             beq   :grk
             cmp   #TCOLOR
             beq   :colk
             cmp   #TPLOT
             beq   :plotk
             cmp   #THLIN
             beq   :hlink
             cmp   #TVLIN
             beq   :vlink
             cmp   #THGR
             beq   :hgrk
             cmp   #THCOLOR
             beq   :hcolk
             cmp   #THPLOT
             beq   :hplotk
             cmp   #TPOPK
             beq   :popk
             cmp   #TSAVEK
             beq   :savej
             cmp   #TSTOPK
             beq   :stopj
             cmp   #TLOMEM
             beq   :lomj
             cmp   #TPRNK
             beq   :prnj
             jmp   GSTMT3          ; the list is full again -- see below
*--- POP -- FORGET THE INNERMOST GOSUB, so the next RETURN goes back one
*    level further out. GOSUB compiles to JSR and RETURN to RTS, so the thing
*    to forget is simply the return address on the stack: two bytes of it.
*    Nothing else of the compiled program's lives there -- a FOR's state is in
*    slots laid out at compile time, not pushed.
:popk        lda   #$68             ; PLA. No NEXTB: the token is already
                                    ; read, and consuming another would take
                                    ; the colon or the terminator with it
             jsr   EMIT
             lda   #$68             ; PLA
             jsr   EMIT
             clc
             rts
:savej       jmp   GSAVE
:lomj        jmp   GLOMEM
:stopj       jmp   GSTOP
:prnj        jmp   GPRN
:vtab        jmp   GVTAB
:htab        jmp   GHTAB
:homek       jmp   GHOME
:textk       jmp   GTEXT
:invk        jmp   GINVERSE
:normk       jmp   GNORMAL
:flashk      jmp   GFLASH
:getk        jmp   GGET
:grk         jmp   GGR
:colk        jmp   GCOLOR
:plotk       jmp   GPLOT
:hlink       jmp   GHLIN
:vlink       jmp   GVLIN
:hgrk        jmp   GHGR
:hcolk       jmp   GHCOLOR
:hplotk      jmp   GHPLOT

*--------------------------------------
* VTAB and HTAB, and the switches that take no argument
*
* Applesoft counts rows and columns from one and the monitor counts from zero,
* so each of these is the expression less one. What the compiled program does
* with it is what the monitor does: CV and then VTABZ to work out the line's
* address, or CHPOS on its own.
*
* An argument outside 1 to 24 (or 1 to 40) is ?ILLEGAL QUANTITY in Applesoft
* and is not checked here; the agreement tests cover the range a program
* actually uses.
*--------------------------------------
GVTAB        jsr   EMTABV
             bcs   :bad
             lda   #$8d             ; STA CV
             jsr   EMIT
             lda   #CV
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$20             ; JSR VTABZ
             jsr   EMIT
             lda   #<VTABZ
             jsr   EMIT
             lda   #>VTABZ
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

GHTAB        jsr   EMTABV
             bcs   :bad
             lda   #$85             ; STA CHPOS -- zero page
             jsr   EMIT
             lda   #CHPOS
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--- an expression as a byte in the accumulator
EMCOORD      jsr   NEXPR
             bcs   :no
             lda   #$20             ; JSR AYINT
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5             ; LDA FACLO -- zero page
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             clc
             rts
:no          sec
             rts

*--- and the same, one less: rows and columns are counted from one by
*    Applesoft and from zero by the monitor
EMTABV       jsr   EMCOORD
             bcs   :no
             lda   #$38             ; SEC : SBC #1
             jsr   EMIT
             lda   #$e9
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             clc
             rts
:no          sec
             rts

GHOME        lda   #<HOMEROM
             ldy   #>HOMEROM
             jmp   EMCALLAY

GTEXT        lda   #<TEXTROM
             ldy   #>TEXTROM
             jmp   EMCALLAY

GINVERSE     lda   #$3f
             jmp   EMINVF

GNORMAL      lda   #$ff
             jmp   EMINVF

GFLASH       lda   #$7f
             jmp   EMINVF

*--------------------------------------
* GRUN -- RUN, from the top or from a line
*
* Applesoft's RUN forgets everything and starts again, which is CLEAR followed
* by a GOTO -- so this is those two, and costs almost nothing beyond them.
* GCLEAR already restores the stack, resets the heap and moves the array break
* back; all that is left is where to jump.
*
* A bare RUN goes to CODESTA, the first thing compiled. RUN 500 hands the line
* number to GGOTO, which reads and resolves it exactly as a GOTO would -- so a
* line that does not exist is named here rather than found at run time.
*--------------------------------------
GRUN         jsr   GCLEAR
             bcs   :bad
             jsr   PEEK
             bcs   :top             ; nothing follows: from the beginning
             sta   CH
             jsr   ISDIGIT
             bcs   :top
             jmp   GGOTO            ; RUN 500 -- it emits the jump itself
:top         lda   #$4c             ; JMP the first line
             jsr   EMIT
             lda   CODESTA
             jsr   EMIT
             lda   CODESTA+1
             jsr   EMIT
             clc                    ; NOT `jmp EMIT`: EMIT returns carry
             rts                    ; SET in pass 3 -- see the note there
:bad         sec
             rts

*--------------------------------------
* GSTMT3 -- the statements that did not fit in the second list either
*
* The same reason the second list exists. GSTMT2's tests reach their jump
* table with nothing to spare, and the keywords added since -- SPEED=, HGR2,
* CLEAR -- pushed the first of those jumps out of branch range. A third list
* costs one more jump for the keywords that reach it and leaves the second
* alone, and it is where the next one should go.
*--------------------------------------
GSTMT3       lda   CH
             cmp   #TSPEEDK
             beq   :speedj
             cmp   #TGR2K
             beq   :hgr2j
             cmp   #TCLEARK
             beq   :clrj
             cmp   #TRUNK
             beq   :runj
             lda   #$05             ; STATEMENT NOT YET
             jsr   SETBAD
             sec
             rts
:speedj      jmp   GSPEED
:hgr2j       jmp   GHGR2
:clrj        jmp   GCLEAR
:runj        jmp   GRUN

*--------------------------------------
* GCLEAR -- CLEAR: put the program back the way it started
*
* Applesoft's CLEAR forgets every variable, every array, the string heap, the
* DATA pointer and the GOSUB stack. A compiled program has all of those too,
* laid out rather than allocated, so this is the prologue done again at run
* time -- with the one difference that the prologue writes zeros into the
* image and this has to write them into memory.
*
* NOT A SINGLE SWEEP from the first variable to the code. Between them sit the
* array base slots, the array break and the collector's run table, which carry
* addresses LAYOUT worked out and nothing at run time could rebuild. So two
* ranges are zeroed and the rest is put back by hand:
*
*   VARBASE..CONSTBASE   the scalars
*   ZFILLA..CODESTA      everything the prologue zero-fills
*
* THE STACK IS RESTORED FIRST, because SPSAVE lives inside the second range
* and is about to be zeroed; it is saved again afterwards. Applesoft discards
* pending GOSUBs on CLEAR in the same way, so a CLEAR inside a subroutine
* loses the way back there too.
*
* AND THE ARRAY BREAK WITH IT. ARGO says CLEAR : GOSUB 5100, and 5100 has a
* DIM A(N) in it -- a runtime-sized array. Zeroing the variables without
* moving the break back would allocate a fresh copy on every pass and run out
* of memory rather than start again. The allocator's floor, which a dynamic
* DIM raises, goes back with it.
*
* Emitted inline rather than as a helper: a program says CLEAR once or twice,
* and a helper would cost the registering machinery to save nothing.
*--------------------------------------
GCLEAR
             lda   #$ae
             jsr   EMIT
             lda   SPSAVEA
             jsr   EMIT
             lda   SPSAVEA+1
             jsr   EMIT
             lda   #$9a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   VARBASE
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   VARBASE+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   CONSTBASE
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   CONSTBASE+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1d
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$c5
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$06             ; -> az
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$c5
             jsr   EMIT
             lda   #$1d
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$0c             ; -> ao
             jsr   EMIT
             lda   #$98
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$ed             ; -> at
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$e8             ; -> at
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   ZFILLA
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   ZFILLA+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   CODESTA
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   CODESTA+1
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$1d
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$c5
             jsr   EMIT
             lda   #$1c
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$06             ; -> bz
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$c5
             jsr   EMIT
             lda   #$1d
             jsr   EMIT
             lda   #$f0
             jsr   EMIT
             lda   #$0c             ; -> bo
             jsr   EMIT
             lda   #$98
             jsr   EMIT
             lda   #$91
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1a
             jsr   EMIT
             lda   #$d0
             jsr   EMIT
             lda   #$ed             ; -> bt
             jsr   EMIT
             lda   #$e6
             jsr   EMIT
             lda   #$1b
             jsr   EMIT
             lda   #$18
             jsr   EMIT
             lda   #$90
             jsr   EMIT
             lda   #$e8             ; -> bt
             jsr   EMIT
             lda   #$ba
             jsr   EMIT
             lda   #$8e
             jsr   EMIT
             lda   SPSAVEA
             jsr   EMIT
             lda   SPSAVEA+1
             jsr   EMIT
             lda   #$a5
             jsr   EMIT
             lda   #$73
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #$74
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   NSDYN
             clc
             adc   #$01
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$29
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   FINPC
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   ABRKA
             jsr   EMIT
             lda   ABRKA+1
             jsr   EMIT
             lda   #$a9
             jsr   EMIT
             lda   FINPC+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   ABRKA
             clc
             adc   #$01
             sta   TMPP
             lda   ABRKA+1
             adc   #$00
             sta   TMPP+1
             jsr   EMADDR
             lda   #$a9
             jsr   EMIT
             lda   #$00
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #$a2
             jsr   EMIT
*--- NO RTS: this is emitted INLINE. It was first written as a subroutine,
*    and the RTS left over from that returned out of the program altogether
*    -- the compiled run stopped dead at the CLEAR.
             clc
             rts

GSPEED       jsr   EMCOORD          ; the value, in A when the program runs
             bcs   :bad
             lda   #$00
             sta   EMI
:loop        ldy   EMI
             cpy   #SPEEDEND-SPEEDB
             bcs   :done
             lda   SPEEDB,y
             jsr   EMIT
             inc   EMI
             jmp   :loop
:done        clc
             rts
:bad         sec
             rts

SPEEDB       dfb   $49,$ff          ; EOR #$FF
             dfb   $18              ; CLC
             dfb   $69,$01          ; ADC #$01  -- A is now -n
             dfb   $85,$f1          ; STA SPEEDZ
SPEEDEND

*--- JSR the routine whose address is in A and Y
EMCALLAY     sta   TMPP
             sty   TMPP+1
             lda   #$20
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             clc
             rts

*--- LDA #flag : STA INVFLG, which is all three of them are
EMINVF       sta   TMPP
             lda   #$a9
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   #$85
             jsr   EMIT
             lda   #INVFLG
             jsr   EMIT
             clc
             rts

*--------------------------------------
* Integer variables: two bytes, converted at every touch
*
* AYINT one way and GIVAYF the other, which is what Applesoft does and why an
* integer variable is no quicker there than a real one. Here it saves three
* bytes apiece and nothing else -- but a program that says I% means I%, and
* one that rounds where the writer wrote truncation is a wrong answer.
*
* Stored high byte first, as Applesoft stores them. Nothing outside the
* compiled program reads them, so the order is a convention rather than a
* requirement, and matching the machine costs nothing.
*--------------------------------------
IVARP        jsr   PEEK             ; an array of them is refused, not guessed
             bcs   :ok
             cmp   #'('
             bne   :ok
             lda   #$29
             jsr   SETBAD
             sec
             rts
*--- BOTH ADDRESSES ARE TAKEN BEFORE ANYTHING IS EMITTED. EMIT works in
*    TMPP, so an address still sitting there when the first byte goes out is
*    not there for the second -- which is how every FN call came to jump to
*    its own save slot.
:ok          jsr   IVFIND
             bcs   :bad
             jsr   IVADDR
             lda   TMPP
             sta   CPT
             lda   TMPP+1
             sta   CPT+1
             lda   #$ad             ; LDA the high byte
             jsr   EMIT
             lda   CPT
             jsr   EMIT
             lda   CPT+1
             jsr   EMIT
             inc   CPT              ; the low half is the byte after it
             bne   :nohi
             inc   CPT+1
:nohi        lda   #$ac             ; LDY the low
             jsr   EMIT
             lda   CPT
             jsr   EMIT
             lda   CPT+1
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<GIVAYF
             jsr   EMIT
             lda   #>GIVAYF
             jsr   EMIT
             lda   #$00
             sta   ISSTR
             sta   PENDOK
             clc
             rts
:bad         sec
             rts

GLETINT      jsr   IVFIND
             bcs   :bad
             jsr   IVADDR
             lda   TMPP
             sta   IVDEST
             lda   TMPP+1
             sta   IVDEST+1
             jsr   NEXTB
             bcs   :bad
             cmp   #TEQ
             bne   :bad
             jsr   NEXPR
             bcs   :bad

*--- FLOORED, NOT TRUNCATED. Applesoft makes I% = -2.5 into -3, not -2, which
*    the interpreter said and memory would not have: INT first, then AYINT.
             lda   #$20             ; JSR INT
             jsr   EMIT
             lda   #<INTROM
             jsr   EMIT
             lda   #>INTROM
             jsr   EMIT
             lda   #$20             ; JSR AYINT
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5             ; LDA FACHI -- zero page
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   IVDEST
             jsr   EMIT
             lda   IVDEST+1
             jsr   EMIT
             lda   #$a5             ; and the low half
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             inc   IVDEST           ; in memory, not in X and Y: EMIT keeps
             bne   :nohi2           ; no promise about either
             inc   IVDEST+1
:nohi2       lda   IVDEST
             jsr   EMIT
             lda   IVDEST+1
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--- the integer variable named in VN0/VN1: TMPA its index
IVFIND       lda   #$00
             sta   TMPA
:loop        lda   TMPA
             cmp   NIVARS
             bcs   :no
             asl
             tax
             lda   IVTAB,x
             cmp   VN0
             bne   :step
             lda   IVTAB+1,x
             cmp   VN1
             beq   :yes
:step        inc   TMPA
             jmp   :loop
:yes         clc
             rts
:no          sec
             rts

*--------------------------------------
* GDEF -- DEF FN name ( parameter ) = expression
*
* The body is compiled where it stands and jumped over, so the program runs
* past a definition without executing it. The jump is forward and its target
* is not known until the body has been compiled -- which is the same shape as
* a forward GOTO, and takes the same answer: pass 2 records where the body
* ended, pass 3 emits it. Both passes emit three bytes either way, so the
* sizes agree and the address pass 2 wrote is the right one.
*--------------------------------------
GDEF
             jmp   :dstart
:badj        jmp   :bad
:dstart      jsr   NEXTB
             bcs   :badj
             cmp   #TFNK
             bne   :badj
             jsr   NEXTB
             bcs   :badj
             sta   CH
             jsr   ISALNUM
             bcs   :badj
             jsr   GETNAME
             jsr   DFFIND
             bcs   :badj
             lda   TMPA
             sta   DEFIDX

*--- past the ( parameter ), which pass 1 has already read and allocated.
*    GETNAME LEAVES WHAT ENDED THE NAME IN CH -- reading another byte here
*    stepped over the bracket and found the parameter instead.
             lda   CH
             cmp   #'('
             bne   :badj
             jsr   NEXTB
             bcs   :badj
             sta   CH
             jsr   ISALNUM
             bcs   :badj
             jsr   GETNAME
             lda   CH
             cmp   #')'
             bne   :badj
             jsr   NEXTB
             bcs   :badj
             cmp   #TEQ
             bne   :badj

*--- JMP past the body, to where pass 2 said it ends
             lda   #$4c
             jsr   EMIT
             ldy   #$05
             lda   (TMPP),y
             sta   CPT
             ldy   #$06
             lda   (TMPP),y
             sta   CPT+1
             lda   CPT
             jsr   EMIT
             lda   CPT+1
             jsr   EMIT

             lda   DEFIDX
             sta   TMPA
             jsr   DFSLOT
             ldy   #$03
             lda   PC
             sta   (TMPP),y
             iny
             lda   PC+1
             sta   (TMPP),y

             jsr   NEXPR
             bcs   :bodybad
             lda   #$60             ; RTS: the value is in FAC
             jsr   EMIT

             lda   DEFIDX
             sta   TMPA
             jsr   DFSLOT
             ldy   #$05
             lda   PC
             sta   (TMPP),y
             iny
             lda   PC+1
             sta   (TMPP),y
             clc
             rts
:bad         lda   #$1e
             jsr   SETBAD
             sec
             rts
:bodybad     lda   #$23             ; DEF FN BODY
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* UFN -- FN name ( expression )
*
* FN S(3) LEAVES X AT WHATEVER IT WAS, asked of the machine rather than
* assumed, so the parameter is an ordinary variable that the call site saves
* and puts back. Nothing in the body needs to know, which is why the parameter
* needs no special kind of slot and no substitution while compiling.
*
* What is kept about the function goes on the stack before the argument is
* compiled, because the argument may itself be a call -- FN T(FN S(2)) does
* work -- and a second call would otherwise overwrite the first one's answer.
*--------------------------------------
UFN
             jmp   :ustart
:badj        jmp   :bad
:nofnj       jmp   :nofn
:badpj       jmp   :badp            ; the same, with four things still pushed
:ustart      jsr   NEXTB
             bcs   :badj
             sta   CH
             jsr   ISALNUM
             bcs   :badj
             jsr   GETNAME
             jsr   DFFIND
             bcs   :nofnj           ; called before its DEF ran, or never defined
             ldy   #$02
             lda   (TMPP),y
             pha                    ; which variable the parameter is
             ldy   #$03
             lda   (TMPP),y
             pha
             ldy   #$04
             lda   (TMPP),y
             pha                    ; and where the body is
             lda   TMPA
             pha                    ; and which function, for its save slot

             lda   CH               ; GETNAME already read the bracket
             cmp   #'('
             bne   :badpj
             jsr   NEXPR            ; the argument
             bcs   :badpj
             jsr   NEXTB
             bcs   :badpj
             cmp   #')'
             bne   :badpj

             pla
             sta   TMPA
             jsr   FNSADDR          ; the function's five-byte save slot
             lda   TMPP
             sta   DSTA
             lda   TMPP+1
             sta   DSTA+1
             pla
             sta   UFNADR+1
             pla
             sta   UFNADR           ; the body address, low then high
             pla
             sta   TMPA             ; the parameter's variable
             jsr   VADDR
             lda   TMPP
             sta   SRCA
             lda   TMPP+1
             sta   SRCA+1

*--- the parameter goes into the slot, the argument into the parameter
             jsr   EMCOPY5
             lda   #$a2             ; LDX #lo
             jsr   EMIT
             lda   SRCA
             jsr   EMIT
             lda   #$a0             ; LDY #hi
             jsr   EMIT
             lda   SRCA+1
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<MOVMF
             jsr   EMIT
             lda   #>MOVMF
             jsr   EMIT

             lda   #$20             ; JSR the body
             jsr   EMIT
             lda   UFNADR
             jsr   EMIT
             lda   UFNADR+1
             jsr   EMIT

*--- and back it goes, which does not disturb the answer in FAC
             lda   DSTA
             sta   CPT
             lda   DSTA+1
             sta   CPT+1
             lda   SRCA
             sta   DSTA
             lda   SRCA+1
             sta   DSTA+1
             lda   CPT
             sta   SRCA
             lda   CPT+1
             sta   SRCA+1
             jsr   EMCOPY5
             lda   #$00
             sta   ISSTR
             clc
             rts
:badp        pla
             pla
             pla
             pla
:bad         lda   #$21             ; FN WANTS ONE NUMBER IN BRACKETS
             jsr   SETBAD
             sec
             rts
:nofn        lda   #$20             ; NO SUCH FUNCTION
             jsr   SETBAD
             sec
             rts

*--------------------------------------
* DFFIND -- the function named in VN0/VN1: TMPA its index, TMPP its entry
*--------------------------------------
DFFIND       lda   #$00
             sta   TMPA
:find        lda   TMPA
             cmp   NDEFS
             bcs   :no
             jsr   DFSLOT
             ldy   #$00
             lda   (TMPP),y
             cmp   VN0
             bne   :step
             iny
             lda   (TMPP),y
             cmp   VN1
             beq   :yes
:step        inc   TMPA
             jmp   :find
:yes         clc
             rts
:no          sec
             rts

*--------------------------------------
* EMCOPY5 -- five bytes from SRCA to DSTA, as ten instructions
*
* A float is five bytes and there is no shorter way to move one that does not
* disturb FAC, which is holding the answer by the time this runs the second
* time.
*--------------------------------------
EMCOPY5      lda   #$00
             sta   EMI
:loop        lda   EMI
             cmp   #$05
             bcs   :done
             lda   #$ad             ; LDA abs
             jsr   EMIT
             lda   SRCA
             clc
             adc   EMI
             sta   CPT
             lda   SRCA+1
             adc   #$00
             sta   CPT+1
             lda   CPT
             jsr   EMIT
             lda   CPT+1
             jsr   EMIT
             lda   #$8d             ; STA abs
             jsr   EMIT
             lda   DSTA
             clc
             adc   EMI
             sta   CPT
             lda   DSTA+1
             adc   #$00
             sta   CPT+1
             lda   CPT
             jsr   EMIT
             lda   CPT+1
             jsr   EMIT
             inc   EMI
             jmp   :loop
:done        rts

*--------------------------------------
* GREAD -- READ a, b$, c(i)
*
* A string item needs nothing allocated: its characters are in the compiled
* program and never move, so the descriptor can point straight at them. A
* numeric one goes through the same parser VAL uses.
*--------------------------------------
GREAD        lda   #$10             ; before the loop deliberately: the flag
             jsr   NEED2             ; is wanted once, and :one is branched to
             jmp   :one
:badj        jmp   :bad             ; the exit is past the whole of the body
:one         jsr   NEXTB
             bcs   :badj
             sta   CH
             jsr   ISALNUM
             bcs   :badj
             jsr   GETNAME
             bcs   :badj
             lda   CH
             cmp   #'$'
             beq   :str
             cmp   #'('
             beq   :elem

*--- a plain number
             jsr   GETVAR2
             bcs   :badj
             jsr   PUTBACK
             lda   VARI
             pha
             jsr   EMNEXTD
             jsr   EMVAL
             pla
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP
             jmp   :more

*--- a string. A BRACKET AFTER THE $ MAKES IT AN ARRAY, the same test
*    GLETSTR makes: READ D$(J) used to come here, look for a plain variable
*    called D$, not find one, and say UNKNOWN VARIABLE about a name the
*    program had dimensioned.
:str         jsr   NEXTB
             bcs   :badj
             sta   CH               ; PUTBACK hands back CH, not A
             cmp   #'('
             beq   :sarrj
             jsr   PUTBACK
             jsr   SVFIND
             bcs   :badj
             jsr   SVADDR
             lda   TMPP
             sta   DSTSV
             lda   TMPP+1
             sta   DSTSV+1
             jsr   EMNEXTD
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
             jmp   :more

*--- AN ELEMENT OF AN ARRAY OF STRINGS. Its address is worked out and put
*    away first for the same reason as everywhere else: fetching the item
*    runs the parser, and the zero page the address was held in does not
*    survive that. EMSAPUT copies the item's descriptor into the element.
:sarrj       jsr   SAFIND
             bcs   :sabadj
             jsr   EMSSUBS
             bcs   :sabadj
             jsr   EMSASAVE
             jsr   EMNEXTD
             jsr   EMSAPUT
             jmp   :more
:sabadj      jmp   :bad             ; the shared exit is back at the top now

*--- an element: its address is worked out first and kept, because reading
*    the item runs the parser over the accumulator
:elem        jsr   GETARR
             bcs   :sabadj
             jsr   EMSUBS
             bcs   :sabadj
             lda   #$85             ; STA ZPELEM
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$84
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             jsr   EMNEXTD
             jsr   EMVAL
             lda   #$a6             ; LDX ZPELEM
             jsr   EMIT
             lda   #ZPELEM
             jsr   EMIT
             lda   #$a4
             jsr   EMIT
             lda   #ZPELEM+1
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<MOVMF
             jsr   EMIT
             lda   #>MOVMF
             jsr   EMIT

:more        jsr   PEEK
             bcs   :done
             cmp   #$2c
             bne   :done
             jsr   NEXTB
             jmp   :one
:done        clc
             rts
:bad         lda   #$06
             jsr   SETBAD
             sec
             rts

*--- JSR the two helpers a READ is made of
EMNEXTD      lda   #$20
             jsr   EMIT
             lda   HNEXTD
             jsr   EMIT
             lda   HNEXTD+1
             jmp   EMIT

EMVAL        lda   #$08
             jsr   NEED2
             lda   #$20
             jsr   EMIT
             lda   HVAL
             jsr   EMIT
             lda   HVAL+1
             jmp   EMIT

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
* EMSPCGO -- SPC(n): n spaces, and no argument about it
*
* NOT TAB(. Established on the machine: SPC(3) after "AB" leaves the cursor at
* 5, SPC(0) prints nothing, and SPC(5) at the start of a line gives five
* spaces. It counts spaces out where TAB( moves to a column, so there is no
* comparison with the cursor and nothing to do when the cursor is already
* past -- there is no "past".
*
* THE OFFSETS ARE COUNTED FROM THIS LAYOUT, not estimated. The last routine
* that laid a loop out by eye had all three of its branches wrong.
*
*    0  BEQ done      2  loop: PHA
*                     3  LDA #" "
*                     5  JSR COUT
*                     8  PLA
*                     9  SEC
*                    10  SBC #1
*                    12  BNE loop
*                    14  done
*--------------------------------------
EMSPCGO      jsr   NEXTB            ; the SPC( token, bracket included
             jsr   EMCOORD          ; the count, a byte in A -- and the LDA it
             bcs   :bad             ; ends with sets Z for the BEQ below
             jsr   PEEK
             bcs   :bad
             cmp   #')'
             bne   :bad
             jsr   NEXTB

             lda   #$f0             ; BEQ done -- none wanted
             jsr   EMIT
             lda   #$0c             ; 14 - 2
             jsr   EMIT
             lda   #$48             ; loop: PHA
             jsr   EMIT
             lda   #$a9             ; LDA #" "
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$20             ; JSR COUT
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jsr   EMIT
             lda   #$68             ; PLA
             jsr   EMIT
             lda   #$38             ; SEC
             jsr   EMIT
             lda   #$e9             ; SBC #1
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$d0             ; BNE loop
             jsr   EMIT
             lda   #$f4             ; 2 - 14
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* EMTABGO -- TAB( n ), SPACES FORWARD TO COLUMN n, and does nothing at all if the
*    cursor is already at or past it.
*
*    Established on a //e rather than recalled, because the obvious reading is
*    wrong. It is not "move to column n": Applesoft works out n-1 minus the
*    current column AS A BYTE and prints that many spaces. The two readings
*    agree on every ordinary case and part company on TAB(0), which on the
*    machine printed 253 spaces and wrapped -- 255 less a column of 2 -- where
*    "move to column 0" would have done nothing or gone backwards.
*
*      PRINT "ABCDEFGH"; TAB( 3);"<"   ABCDEFGH<        at 8, wants 2: nothing
*      PRINT "AB"; TAB( 6);"<"         AB   <           3 spaces, lands at 5
*      PRINT TAB( 5);"<"                   <            4 spaces, lands at 4
*      PRINT "AB"; TAB( 0);"<"         wraps, lands at 15
*      PRINT "AB"; TAB( 45);"<"        wraps, lands at 4
*
*    So: target = n-1; if it is below the cursor, nothing; otherwise print
*    target-cursor spaces. The count goes on the STACK and not in X, because
*    COUT does not promise to preserve a register.
EMTABGO      jsr   NEXTB            ; the TAB( token, bracket included
             jsr   EMTABV           ; the expression, less one, a byte in A
             bcs   :bad
             jsr   PEEK
             bcs   :bad
             cmp   #')'
             bne   :bad
             jsr   NEXTB

             lda   #$38             ; SEC
             jsr   EMIT
             lda   #$e5             ; SBC CHPOS -- zero page
             jsr   EMIT
             lda   #CHPOS
             jsr   EMIT
*--- THE DISTANCES ARE COUNTED FROM THE LAYOUT BELOW, not estimated. All
*    three were wrong first time and the compiled program printed nothing at
*    all: BNE came out as -11 rather than -12, which lands one byte inside the
*    loop, skips the PHA, and unbalances the stack against the PLA.
*
*       0  SEC              7  PHA        <- loop
*       1  SBC CHPOS        8  LDA #" "
*       3  BEQ done        10  JSR COUT
*       5  BCC done        13  PLA
*                          14  SEC
*                          15  SBC #1
*                          17  BNE loop
*                          19  done
             lda   #$f0             ; BEQ done -- already there
             jsr   EMIT
             lda   #$0e             ; 19 - 5
             jsr   EMIT
             lda   #$90             ; BCC done -- the cursor is past it
             jsr   EMIT
             lda   #$0c             ; 19 - 7
             jsr   EMIT
             lda   #$48             ; loop: PHA
             jsr   EMIT
             lda   #$a9             ; LDA #" "
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   #$20             ; JSR COUT
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jsr   EMIT
             lda   #$68             ; PLA
             jsr   EMIT
             lda   #$38             ; SEC
             jsr   EMIT
             lda   #$e9             ; SBC #1
             jsr   EMIT
             lda   #$01
             jsr   EMIT
             lda   #$d0             ; BNE loop
             jsr   EMIT
             lda   #$f4             ; 7 - 19
             jsr   EMIT

             clc
             rts
:bad         sec
             rts

*--------------------------------------
* HDIMB -- the runtime side of DIM A(N): take N+1 elements off the array
* break, zero them, and hand back where they start
*
* ASSEMBLED BY MERLIN, NOT BY HAND. It is emitted a byte at a time like
* ARRBLOB, but written as instructions rather than a dfb table so the
* assembler computes the branch offsets. Three hand-counted branch offsets
* went in wrong earlier today; this removes the opportunity.
*
* Only relative branches and zero page inside, so it runs wherever it lands.
* THE ABSOLUTE OPERANDS ARE ALL $FFFF and are substituted as the bytes go
* out, in order, from HDIMWHAT below -- so there are no offsets to count
* here either. $FF appears nowhere else in the blob: every immediate is 0 or
* 1 and every zero page address is $1A-$1D or $A0-$A1.
*
*   in    FAC = N, the subscript as written
*   out   A/Y = where the elements start; the break moved past them; the
*         elements zeroed, as Applesoft leaves a freshly DIMmed array
*
* $1A-$1D is all the zero page there is, so it is used twice over: the count
* becomes the new break, and the size becomes the pointer that walks the
* elements zeroing them.
*--------------------------------------
HDIMB        jsr   AYINT            ; N as a signed integer
             lda   FACLO
             clc
             adc   #$01             ; DIM A(20) holds twenty-one
             sta   ZPB
             lda   FACHI
             adc   #$00
             sta   ZPB+1

             lda   ZPB              ; five bytes an element: n*4 + n
             sta   ZPB+2
             lda   ZPB+1
             sta   ZPB+3
             asl   ZPB+2
             rol   ZPB+3
             asl   ZPB+2
             rol   ZPB+3
             lda   ZPB+2
             clc
             adc   ZPB
             sta   ZPB+2
             lda   ZPB+3
             adc   ZPB+1
             sta   ZPB+3

             lda   $ffff            ; 1  the break, and this array's base
             clc
             adc   ZPB+2
             sta   ZPB              ; ZPB is the NEW break from here on
             lda   $ffff            ; 2
             adc   ZPB+3
             sta   ZPB+1

*--- below the string heap's lower edge? then there is no room
             lda   ZPB+1
             cmp   $ffff            ; 3  the heap pointer, high half
             bcc   :room
             bne   :full
             lda   ZPB
             cmp   $ffff            ; 4  and low
             bcc   :room
:full        jmp   $ffff            ; 5  out of memory, and does not return

*--- zero the elements, from the old break up to the new one
:room        lda   $ffff            ; 6  the walking pointer starts at the base
             sta   ZPB+2            ;    and ZPB+2 is free again by now
             lda   $ffff            ; 7
             sta   ZPB+3
             ldy   #$00
:zero        lda   ZPB+2
             cmp   ZPB
             bne   :zap
             lda   ZPB+3
             cmp   ZPB+1
             beq   :done
:zap         tya                    ; Y is zero here and stays zero
             sta   (ZPB+2),y
             inc   ZPB+2
             bne   :zero
             inc   ZPB+3
*--- CLC : BCC, NOT JMP, and this is not a style choice. This blob is COPIED
*    into the compiled program, and the only absolute addresses relocated on
*    the way are the $FFFF placeholders. A jmp :zero keeps the address :zero
*    has HERE, inside the compiler at $6Axx, so the compiled program jumped
*    into nothing. Three bytes either way, and a branch carries no address.
*
*    It is reached ONLY when the zeroing crosses a page -- the bne above takes
*    every other pass -- so it survived every test whose array happened to sit
*    inside one page, and crashed the two real programs whose did not. Two
*    extra scalars in the source were enough to move an array across $1000 and
*    turn a working compile into a monitor prompt.
*
*    The offset must not assemble to $FF, which the emitter reads as the start
*    of a placeholder. It is about -$17.
             clc
             bcc   :zero            ; always

*--- the base is still in the break; take a copy before moving it on
:done        lda   $ffff            ; 8
             pha
             lda   $ffff            ; 9
             pha

             lda   ZPB              ; the break moves up
             sta   $ffff            ; 10
             lda   ZPB+1
             sta   $ffff            ; 11

*--- AND THE HEAP ALLOCATOR'S FLOOR WITH IT. The allocator refuses to bring
*    the heap below a constant compiled into it; now that arrays grow up from
*    there, that constant has to move up too. EMHALLOC recorded where those
*    two bytes landed as it wrote them.
             lda   ZPB
             sta   $ffff            ; 12  the floor's low byte, inside HALLOC
             lda   ZPB+1
             sta   $ffff            ; 13  and its high byte

             pla
             tay
             pla
             rts
HDIMBEND

*--- which address each $FFFF in the blob stands for, in the order they occur
HDIMWHAT     dfb   0,1,3,2,4,0,1,0,1,0,1,5,6
HDIMNPAT     equ   13

*--------------------------------------
* GSDIMDYN -- the emission for DIM A$(N)
*
* As GDIMDYN, with the run number handed to the allocator in X: the array's
* descriptors have to be entered in the collector's table, and which entry is
* theirs was settled by pass 1.
*--------------------------------------
GSDIMDYN     lda   TMPA
             pha
             jsr   NEXPR            ; the size, into FAC
             pla
             sta   TMPA
             bcs   :bad
             jsr   PEEK
             bcs   :bad
             cmp   #')'
             bne   :bad
             jsr   NEXTB

             lda   TMPA
             pha
             ldx   TMPA             ; LDX #run, for the allocator
             lda   SADYNF,x
             sta   ABTMP
             lda   #$a2
             jsr   EMIT
             lda   ABTMP
             jsr   EMIT
             lda   #$20             ; JSR the string DIM helper
             jsr   EMIT
             lda   HSDIMA
             jsr   EMIT
             lda   HSDIMA+1
             jsr   EMIT
             pla
             sta   TMPA

             jsr   SABSLOT          ; and into this array's base slot
             lda   TMPP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   #$8d             ; STA base
             jsr   EMIT
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   #$8c             ; STY base+1
             jsr   EMIT
             inc   ABTMP
             bne   :hi
             inc   ABTMP+1
:hi          lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GDIM -- a DIM statement
*
* Most of one generates nothing: pass 1 worked the sizes out and LAYOUT put
* the elements somewhere, so by here there is nothing left to do. A DIM whose
* subscript is an EXPRESSION is different -- pass 1 reserved nothing and only
* noted which array it was -- so this evaluates it, calls the allocator, and
* writes the answer into that array's base slot.
*--------------------------------------
*--------------------------------------
* EMCHAR -- emit LDA #char / JSR COUT
*--------------------------------------
EMCHAR       ora   #$80
             sta   EMCH
             lda   #$a9
             jsr   EMIT
             lda   EMCH
             jsr   EMIT
             lda   #$20
             jsr   EMIT
             lda   #<COUTA
             jsr   EMIT
             lda   #>COUTA
             jmp   EMIT

*--------------------------------------
* EMWORD -- emit the code to print WORD as decimal
*
* PRWORD's own loop, emitting instead of printing. ITS INDEX IS KEPT IN
* MEMORY: PRWORD counts digits in X, and every character here goes out through
* EMIT, which puts the output length in X on its way to the buffer.
*--------------------------------------
EMWORD       lda   #$00
             sta   LEADING
             ldx   #$00
:digit       stx   EMX
             lda   #$00
             sta   DIGIT
:sub         lda   WORD
             sec
             sbc   POWLO,x
             tay
             lda   WORD+1
             sbc   POWHI,x
             bcc   :done
             sta   WORD+1
             sty   WORD
             inc   DIGIT
             jmp   :sub
:done        lda   DIGIT
             bne   :show
             lda   LEADING
             bne   :show
             cpx   #$04             ; the units digit always prints
             bne   :next
:show        lda   #$01
             sta   LEADING
             lda   DIGIT
             clc
             adc   #$30
             jsr   EMCHAR
:next        ldx   EMX
             inx
             cpx   #$05
             bcc   :digit
             rts

*--------------------------------------
* GSTOP -- STOP, which says BREAK IN and the line, then ends
*
* Applesoft prints BREAK IN nnnn and stops; established on a //e rather than
* recalled, along with the fact that it begins on a line of its own. The line
* number is known while this is compiled, so the whole message goes out as
* characters -- no string machinery, and nothing to look up at run time.
*
* PHONE.LIST has six, every one of them a guard on a line the program should
* never reach.
*--------------------------------------
*--- NO NEXTB. The statement's token has already been read by the time a
*    handler is entered -- GHOME, GEND and the rest start straight in -- so
*    consuming one here ate the byte AFTER it. For STOP that was the line's
*    terminating zero, and the statement loop then read on into the next
*    line's link bytes and tried to compile them, which is where IF A = 2
*    THEN STOP got UNKNOWN VARIABLE from.
GSTOP
*--- a newline first, unless the cursor is already at the start of one
             lda   #$a5             ; LDA CH
             jsr   EMIT
             lda   #CHPOS
             jsr   EMIT
             lda   #$f0             ; BEQ over the five that follow
             jsr   EMIT
             lda   #$05
             jsr   EMIT
             lda   #$8d
             jsr   EMCHAR

             lda   #$00
             sta   EMI
:msg         ldy   EMI
             cpy   #MSGBRKE-MSGBRK
             bcs   :num
             lda   MSGBRK,y
             jsr   EMCHAR
             inc   EMI
             jmp   :msg

:num         lda   CURLINE
             sta   WORD
             lda   CURLINE+1
             sta   WORD+1
             jsr   EMWORD
             lda   #$8d
             jsr   EMCHAR
             jsr   EMEND
             clc
             rts

MSGBRK       asc   'BREAK IN '
MSGBRKE

*--------------------------------------
* GPRN -- PR# n, which sends what is printed to a slot
*
* The monitor's OUTPORT does the work and wants the slot in A, which is what
* EMCOORD leaves there. PHONE.LIST turns a printer on with PR# SL and off
* again with PR# 0.
*--------------------------------------
GPRN         jsr   EMCOORD          ; the slot, as a byte in A. NO NEXTB
                                    ; first -- it would have eaten the first
                                    ; byte of the expression
             bcs   :bad
             lda   #$20             ; JSR OUTPORT
             jsr   EMIT
             lda   #<OUTPORT
             jsr   EMIT
             lda   #>OUTPORT
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GLOMEM -- LOMEM:, which compiles to nothing
*
* It moves the bottom of Applesoft's variable space. A compiled program's
* memory was settled while it was compiled -- PICKORG chose where it loads and
* LAYOUT put everything in it -- so there is nothing left for LOMEM: to move.
*
* The expression is still compiled and thrown away, rather than skipped: it is
* allowed to contain a function call, and a program that wrote one there meant
* it to happen. A few bytes for a value nobody reads.
*
* Said by name and line, as SAVE is. LEMONADE opens with LOMEM: 14080.
*--------------------------------------
GLOMEM       jsr   NEXPR            ; the address it wanted, evaluated and lost
             bcs   :bad
             lda   PASSNO
             cmp   #$03
             bne   :done
             lda   #<MSGNOLOM
             ldy   #>MSGNOLOM
             jsr   PRSTR
             lda   CURLINE
             sta   WORD
             lda   CURLINE+1
             sta   WORD+1
             jsr   PRWORD
             lda   #<MSGNOLOM2
             ldy   #>MSGNOLOM2
             jsr   PRSTR
:done        clc
             rts
:bad         sec
             rts

*--------------------------------------
* FPOS -- POS(x), where the cursor is across the line
*
* ASKED ON THE MACHINE: after HTAB 10, POS(0) is 9 and PEEK(36) is 11 -- the
* eleven being where the cursor had got to by the time the second item was
* evaluated. POS is CH at $24, counted from zero, which is the same byte
* PEEK(36) reads and not the one-based column HTAB takes.
*
* The argument is evaluated and dropped, as Applesoft drops it: GROAN writes
* Q = POS(0) after a prompt to find out where to put the answer.
*--------------------------------------
FPOS         jsr   FARGOPEN         ; and its value is not wanted
             bcs   :bad
             lda   #$a5             ; LDA $24
             jsr   EMIT
             lda   #$24
             jsr   EMIT
             jmp   EMBYTEFAC        ; and that byte as a float
:bad         sec
             rts

*--------------------------------------
* FFRE -- FRE(x), the memory that is left
*
* Applesoft's answer is the gap between its variables and its strings. A
* compiled program has the same shape and both ends of it already: the array
* break at the bottom, and the string heap coming down from HIMEM above. The
* space between them is what is free.
*
* SIGNED, through GIVAYF, which is what Applesoft does too -- and is why its
* own FRE goes negative on a machine with more than 32K free. Matching the
* quirk costs nothing and surprises nobody who knows it.
*
* The argument is evaluated and dropped, as Applesoft drops it. LEMONADE
* writes I = FRE(0) twice and then uses I as a loop counter: the value is not
* the point, the collection it forces is.
*--------------------------------------
FFRE         jsr   FARGOPEN         ; and its value is not wanted
             bcs   :bad

             lda   #$ad             ; LDA heap pointer, low
             jsr   EMIT
             lda   #$01
             jsr   EMSCOFS
             lda   #$38             ; SEC
             jsr   EMIT
             lda   #$ed             ; SBC the array break, low
             jsr   EMIT
             lda   ABRKA
             jsr   EMIT
             lda   ABRKA+1
             jsr   EMIT
             lda   #$a8             ; TAY -- the low half, and the carry keeps
             jsr   EMIT

             lda   #$ad             ; LDA heap pointer, high
             jsr   EMIT
             lda   #$02
             jsr   EMSCOFS
             lda   #$ed             ; SBC the array break, high
             jsr   EMIT
             lda   ABRKA
             clc
             adc   #$01
             sta   ABTMP
             lda   ABRKA+1
             adc   #$00
             tay
             lda   ABTMP
             jsr   EMIT
             tya
             jsr   EMIT

             lda   #$20             ; JSR GIVAYF -- A high, Y low, signed
             jsr   EMIT
             lda   #<GIVAYF
             jsr   EMIT
             lda   #>GIVAYF
             jsr   EMIT
             lda   #$00
             sta   PENDOK
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GSAVE -- SAVE, the cassette one, which compiles to nothing
*
*    A bare SAVE writes the BASIC program to tape. A compiled program has no
*    BASIC program in it to write, so there is nothing this could honestly
*    emit -- and emitting the ROM's tape routine would write whatever the
*    Applesoft program pointers happen to span, producing a tape that will not
*    load rather than an error anybody can see.
*
*    So it generates nothing AND SAYS SO, by name and line number, because a
*    statement that silently stops happening is exactly the kind of change a
*    compiler should never make quietly. PHONE.LIST has two, both on the tape
*    branch of a disk-or-tape choice that a ProDOS machine never takes.
*
*    Said in pass 3 only: pass 2 generates the same statements with its output
*    thrown away, and would otherwise say everything twice.
*--------------------------------------
GSAVE                             ; no NEXTB: see GSTOP
             lda   PASSNO
             cmp   #$03
             bne   :saved
             lda   #<MSGNOSAVE
             ldy   #>MSGNOSAVE
             jsr   PRSTR
             lda   CURLINE
             sta   WORD
             lda   CURLINE+1
             sta   WORD+1
             jsr   PRWORD
             lda   #<MSGNOSAVE2
             ldy   #>MSGNOSAVE2
             jsr   PRSTR
:saved       clc
             rts

*--------------------------------------
* GINSARR -- INPUT A$(J), into an element of an array of strings
*
* The address is worked out and kept first, exactly as an assignment to one
* does it: EMSASAVE puts it in the program's own scratch rather than zero
* page, so it survives the copy to the heap and any collection that copy sets
* off. The array's descriptors do not move in a collection -- they are not in
* the heap -- so the address stays good even for an array sized at run time.
*
* Ends by rejoining GINPUT's loop, which is why it takes the carry back with
* it rather than returning a value.
*--------------------------------------
GINSARR      lda   #$40             ; the heap, for the copy
             jsr   NEED2
             jsr   SAFIND
             bcs   :bad
             jsr   EMSSUBS
             bcs   :bad
             jsr   EMSASAVE
             jsr   EMNEXTI
             lda   #$20             ; JSR HICOPY
             jsr   EMIT
             lda   HICOPY
             jsr   EMIT
             lda   HICOPY+1
             jsr   EMIT
             jsr   EMSAPUT
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GDIMDYN -- the emission for DIM A(N): allocate, and keep where it landed
*
* Its own routine because inline it made GDIM long enough that three of its
* branches stopped reaching, which is the third time today. TMPA holds the
* array; the subscript is still to be read.
*--------------------------------------
GDIMDYN      lda   TMPA
             pha
             jsr   NEXPR            ; the size, into FAC
             pla
             sta   TMPA
             bcs   :bad
             jsr   PEEK
             bcs   :bad
             cmp   #')'
             bne   :bad
             jsr   NEXTB

             lda   USES2
             ora   #$10
             sta   USES2

             lda   TMPA
             pha
             lda   #$20             ; JSR the DIM helper
             jsr   EMIT
             lda   HDIMA
             jsr   EMIT
             lda   HDIMA+1
             jsr   EMIT
             pla
             sta   TMPA

             jsr   ABSLOT           ; and into this array's base slot
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   #$8d             ; STA base
             jsr   EMIT
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   #$8c             ; STY base+1
             jsr   EMIT
             inc   ABTMP
             bne   :hi
             inc   ABTMP+1
:hi          lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* GDIM -- a DIM statement
*
* Most of one generates nothing: pass 1 worked the sizes out and LAYOUT put
* the elements somewhere. A DIM whose subscript is an EXPRESSION is different
* -- pass 1 reserved nothing for it and only noted which array it was.
*--------------------------------------
*--- NEXTB, NOT PEEK. GETNAME takes the name's FIRST character from CH and
*    expects it to have been read already -- every other caller reaches it
*    that way, from a dispatcher that has just read the byte. Peeking left CH
*    holding whatever the statement before had put there, so the name looked
*    up was not the one written and every DIM said UNKNOWN VARIABLE.
GDIM         jsr   NEXTB
             bcs   :endn
             sta   CH
             beq   :back
             cmp   #':'
             beq   :back
             cmp   #$2c             ; DIM A(3),B(N): the comma between them
             bne   :name
             jmp   GDIM
:back        jsr   PUTBACK
:endn        clc                    ; after the jump: nothing falls in
             rts
:badj        sec
             rts

:name        jsr   ISALNUM
             bcs   :skip
             jsr   GETNAME          ; the name, and what ended it in CH
             bcs   :badj
             lda   CH
             cmp   #'$'
             beq   :str
             cmp   #'('
             bne   :skip
             jsr   GETARR
             bcs   :badj
             ldx   TMPA
             lda   ADYNF,x
             beq   :skip            ; an ordinary DIM: LAYOUT did it all
             jsr   GDIMDYN
             bcs   :badj
             jmp   GDIM

*--- DIM A$(N): the other kind, and the one that needs a collector run
:str         jsr   NEXTB            ; past the $
             bcs   :badj
             cmp   #'('
             bne   :skip
             jsr   SAFIND
             bcs   :badj
             ldx   TMPA
             lda   SADYNF,x
             beq   :skip            ; an ordinary DIM A$(5)
             jsr   GSDIMDYN
             bcs   :badj
             jmp   GDIM

*--- everything else is read and thrown away, as a DIM always was
:skip        jsr   NEXTB
             bcs   :badj
             sta   CH
             beq   :endp
             cmp   #':'
             beq   :endp
             cmp   #$2c
             beq   :comma
             jmp   :skip
:comma       jmp   GDIM
:endp        jsr   PUTBACK
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* HRUNB -- the collector's roots, as a list of runs rather than one run
*
* THE ROOTS WERE ONE UNBROKEN RUN and the collector walked it with a pointer
* and a one-byte count, both loaded as immediates. A string array whose size
* is not known until the program runs cannot be in that run -- it is not there
* when the layout is fixed -- so the roots became a TABLE of runs, and this is
* what walks it.
*
* Two entry points, and they are the first two instructions so that their
* addresses need no working out: MORE at the start, SETRUN three bytes on.
* The collector calls SETRUN where it used to load the pointer and count, and
* MORE where it used to decrement the count -- both replacements are exactly
* the length of what they replace, so not one branch offset inside that
* hand-assembled routine moves.
*
*   SETRUN   start at run 0
*   MORE     one descriptor fewer; returns with Z clear while there is
*            another to walk, anywhere in any run, and Z set when there is not
*
* A run may be longer than a byte can count, so it is handed out in chunks of
* 128 and the remainder kept. The pointer walks on by itself between chunks --
* the collector advances it -- so only the count needs reloading.
*
* $FF marks an absolute operand, substituted in order from HRUNWHAT. Every
* immediate here is 0, 1 or $80 so that no real byte can be mistaken for one.
*--------------------------------------
HRUNB                             ; ITS OWN LINE: a local on a global label's
             jmp   :more            ; own line resolves in the previous scope
             jmp   :setrun          ; 4-5: likewise

:setrun      lda   #$00
             sta   $ffff            ; RUNI
             beq   :load            ; always

:load        lda   $ffff            ; RUNI
             asl                    ; four bytes an entry
             asl
             tax
             lda   $ffff,x          ; RUNTAB   -- where the run starts
             sta   ZPB
             lda   $ffff,x          ; RUNTAB+1
             sta   ZPB+1
             lda   $ffff,x          ; RUNTAB+2 -- and how many it holds
             sta   $ffff            ; RUNREM
             lda   $ffff,x          ; RUNTAB+3
             sta   $ffff            ; RUNREM+1

:chunk       lda   $ffff            ; RUNREM+1
             bne   :big
             lda   $ffff            ; RUNREM
             beq   :next            ; an empty run: on to the following one
             cmp   #$80
             bcs   :big
             sta   $ffff            ; COUNT
             lda   #$00
             sta   $ffff            ; RUNREM
             beq   :go              ; always

:big         lda   #$80
             sta   $ffff            ; COUNT
             lda   $ffff            ; RUNREM
             sec
             sbc   #$80
             sta   $ffff            ; RUNREM
             lda   $ffff            ; RUNREM+1
             sbc   #$00
             sta   $ffff            ; RUNREM+1
:go          lda   #$01             ; Z clear: keep going
             rts

:next        inc   $ffff            ; RUNI
             lda   $ffff            ; RUNI
             cmp   $ffff            ; NRUNS
             bcc   :load
             lda   #$00             ; Z set: every run walked
             rts

:more        dec   $ffff            ; COUNT
             beq   :spent
             lda   #$01
             rts
:spent       lda   $ffff            ; RUNREM
             ora   $ffff            ; RUNREM+1
             bne   :chunk           ; more of this run, in the next chunk
             beq   :next
HRUNBEND

*--- which address each $FF stands for, in the order they occur
*    0-3 the run table's four fields, 4 the count the collector decrements,
*    5 which run, 6-7 what is left of it, 8 how many runs there are
HRUNWHAT     dfb   5,5,0,1,2,6,3,7,7,6,4,6,4,6,6,7,7,5,5,8,4,6,7

*--------------------------------------
* HSDIMB -- the runtime side of DIM A$(N)
*
* Like HDIMB, with two differences that matter. A descriptor is three bytes,
* not five; and the elements ARE THE COLLECTOR'S ROOTS, so the run they form
* has to be entered in its table or a collection will walk past them and
* leave every string in the array pointing at memory it has moved.
*
*   in    FAC = N, the subscript as written; X = which run table entry
*   out   A/Y = where the descriptors start
*
* Zeroing them is what makes them safe to walk before anything is assigned: a
* descriptor of length zero is one the collector skips.
*--------------------------------------
*--- X FIRST, BEFORE AYINT. The run number arrives in X and AYINT is an
*    Applesoft ROM routine that reaches QINT, which uses X for its own ends.
*    It survived the test, which proves nothing: the same code with a
*    different value in FAC could take a path through the ROM that does not.
HSDIMB       stx   $ffff            ; RUNI: which entry this array fills in
             jsr   AYINT            ; N as a signed integer
             lda   FACLO
             clc
             adc   #$01             ; DIM A$(20) holds twenty-one
             sta   ZPB
             lda   FACHI
             adc   #$00
             sta   ZPB+1

             lda   ZPB              ; three bytes a descriptor: n*2 + n
             sta   ZPB+2
             lda   ZPB+1
             sta   ZPB+3
             asl   ZPB+2
             rol   ZPB+3
             lda   ZPB+2
             clc
             adc   ZPB
             sta   ZPB+2
             lda   ZPB+3
             adc   ZPB+1
             sta   ZPB+3

*--- the run table entry: where these will start, and how many
             lda   $ffff            ; RUNI
             asl
             asl
             tax
             lda   $ffff            ; ABRK
             sta   $ffff,x          ; RUNTAB
             lda   $ffff            ; ABRK+1
             sta   $ffff,x          ; RUNTAB+1
             lda   ZPB
             sta   $ffff,x          ; RUNTAB+2 -- the count, not the size
             lda   ZPB+1
             sta   $ffff,x          ; RUNTAB+3

*--- and the room for them, off the same break the numeric arrays use
             lda   $ffff            ; ABRK
             clc
             adc   ZPB+2
             sta   ZPB
             lda   $ffff            ; ABRK+1
             adc   ZPB+3
             sta   ZPB+1

             lda   ZPB+1
             cmp   $ffff            ; the heap pointer, high half
             bcc   :room
             bne   :full
             lda   ZPB
             cmp   $ffff            ; and low
             bcc   :room
:full        jmp   $ffff            ; out of memory

:room        lda   $ffff            ; ABRK: the walking pointer starts there
             sta   ZPB+2
             lda   $ffff            ; ABRK+1
             sta   ZPB+3
             ldy   #$00
:zero        lda   ZPB+2
             cmp   ZPB
             bne   :zap
             lda   ZPB+3
             cmp   ZPB+1
             beq   :done
:zap         tya
             sta   (ZPB+2),y
             inc   ZPB+2
             bne   :zero
             inc   ZPB+3
*--- CLC : BCC, NOT JMP, and this is not a style choice. This blob is COPIED
*    into the compiled program, and the only absolute addresses relocated on
*    the way are the $FFFF placeholders. A jmp :zero keeps the address :zero
*    has HERE, inside the compiler at $6Axx, so the compiled program jumped
*    into nothing. Three bytes either way, and a branch carries no address.
*
*    It is reached ONLY when the zeroing crosses a page -- the bne above takes
*    every other pass -- so it survived every test whose array happened to sit
*    inside one page, and crashed the two real programs whose did not. Two
*    extra scalars in the source were enough to move an array across $1000 and
*    turn a working compile into a monitor prompt.
*
*    The offset must not assemble to $FF, which the emitter reads as the start
*    of a placeholder. It is about -$17.
             clc
             bcc   :zero            ; always

:done        lda   $ffff            ; ABRK
             pha
             lda   $ffff            ; ABRK+1
             pha
             lda   ZPB
             sta   $ffff            ; ABRK
             lda   ZPB+1
             sta   $ffff            ; ABRK+1
             lda   ZPB
             sta   $ffff            ; the allocator's floor, low
             lda   ZPB+1
             sta   $ffff            ; and high
             pla
             tay
             pla
             rts
HSDIMBEND

*--- 0 ABRK, 1 ABRK+1, 2 the heap pointer low, 3 its high, 4 out of memory,
*    5 the floor low, 6 the floor high, 7 RUNI, 8-11 the run table's fields
HSDIMWHAT    dfb   7,7,0,8,1,9,10,11,0,1,3,2,4,0,1,0,1,0,1,5,6

*--------------------------------------
* EMHSDIM -- put HSDIMB into the program
*--------------------------------------
EMHSDIM      lda   #$00
             sta   EMI
             sta   HDPI
:loop        ldy   EMI
             cpy   #HSDIMBEND-HSDIMB
             bcs   :done
             lda   HSDIMB,y
             cmp   #$ff
             beq   :patch
             jsr   EMIT
             inc   EMI
             jmp   :loop
:patch       jsr   HSDADDR
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             inc   HDPI
             lda   EMI
             clc
             adc   #$02
             sta   EMI
             jmp   :loop
:done        rts

*--------------------------------------
* HSDADDR -- TMPP = the address placeholder HDPI stands for
*
* 0-6 are HDADDR's own codes and mean the same things; 7 is which run is being
* filled in and 8-11 are that entry's four fields.
*--------------------------------------
HSDADDR      ldy   HDPI
             lda   HSDIMWHAT,y
             cmp   #$07
             bcs   :mine
             jmp   HDADDRA          ; codes 0-6 mean what they mean there.
                                    ; THE CODE GOES IN A, not into HDIMWHAT:
                                    ; writing it there would have overwritten
                                    ; the numeric blob's own first entry, in
                                    ; the compiler's table, for good.
:mine        cmp   #$07
             bne   :field
             lda   #$26             ; 38: which run
             jsr   SCOFS
             jmp   :back
:field       sec                    ; 8-11: a field of the run table
             sbc   #$08
             clc
             adc   RUNTABA
             sta   TMPP
             lda   RUNTABA+1
             adc   #$00
             sta   TMPP+1
:back        rts

*--------------------------------------
* EMSETRUN -- JSR SETRUN, padded to the thirteen bytes it stands in for
*
* SETRUN is three bytes into the run walker: the blob begins with a JMP to
* MORE and a JMP to SETRUN, so both entry points are at known offsets and
* neither needs working out.
*--------------------------------------
EMSETRUN     lda   #$20             ; JSR
             jsr   EMIT
             lda   HRUNA
             clc
             adc   #$03
             sta   ABTMP
             lda   HRUNA+1
             adc   #$00
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
*--- COUNTED IN MEMORY, NOT IN X. EMIT puts the output length in X on its way
*    to the buffer, so a loop counting in X across it does not count.
             lda   #$0a             ; and ten NOPs, to keep the length
             sta   PADI
:pad         lda   #$ea
             jsr   EMIT
             dec   PADI
             bne   :pad
             rts

*--------------------------------------
* EMHRUN -- put HRUNB into the program
*
* Like EMHDIM, but with two JMPs at the front whose operands point INSIDE the
* blob and so have to be moved along with it: the assembler wrote them as
* addresses in the compiler, and they are needed as addresses in the compiled
* program. Their positions are 1 and 4, which needs no working out.
*--------------------------------------
EMHRUN       lda   #$00
             sta   EMI
             sta   HDPI
:loop        ldy   EMI
             cpy   #HRUNBEND-HRUNB
             bcs   :done
             cpy   #$01
             beq   :reloc
             cpy   #$04
             beq   :reloc
             lda   HRUNB,y
             cmp   #$ff
             beq   :patch
             jsr   EMIT
             inc   EMI
             jmp   :loop

*--- an address inside the blob: where it will be, not where it was
:reloc       lda   HRUNB,y
             sec
             sbc   #<HRUNB
             sta   ABTMP
             iny
             lda   HRUNB,y
             sbc   #>HRUNB
             sta   ABTMP+1
             lda   ABTMP
             clc
             adc   HRUNA
             sta   ABTMP
             lda   ABTMP+1
             adc   HRUNA+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   EMI
             clc
             adc   #$02
             sta   EMI
             jmp   :loop

:patch       jsr   HRADDR
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             inc   HDPI
             lda   EMI
             clc
             adc   #$02
             sta   EMI
             jmp   :loop
:done        rts

*--------------------------------------
* HRADDR -- TMPP = the address placeholder HDPI stands for
*--------------------------------------
HRADDR       ldy   HDPI
             lda   HRUNWHAT,y
             cmp   #$04
             bcs   :scratch

*--- 0-3: a field of the run table
             clc
             adc   RUNTABA
             sta   TMPP
             lda   RUNTABA+1
             adc   #$00
             sta   TMPP+1
             rts

*--- 4-8: somewhere in the string runtime's scratch
:scratch     cmp   #$04
             bne   :not4
             lda   #$0d             ; the count the collector decrements
             jmp   SCOFS
:not4        cmp   #$05
             bne   :not5
             lda   #$26             ; 38: which run
             jmp   SCOFS
:not5        cmp   #$06
             bne   :not6
             lda   #$27             ; 39: what is left of it
             jmp   SCOFS
:not6        cmp   #$07
             bne   :nruns
             lda   #$28             ; 40
             jmp   SCOFS
:nruns       lda   #$29             ; 41: how many runs
             jmp   SCOFS

*--------------------------------------
* EMHDIM -- put HDIMB into the program, substituting its absolute operands
*
* Every $FF in the blob begins a placeholder; HDIMWHAT says, in order, which
* address each one wanted. Nothing here counts an offset.
*--------------------------------------
EMHDIM       lda   #$00
             sta   EMI
             sta   HDPI
:loop        ldy   EMI
             cpy   #HDIMBEND-HDIMB
             bcs   :done
             lda   HDIMB,y
             cmp   #$ff
             beq   :patch
             jsr   EMIT
             inc   EMI
             jmp   :loop
:patch       jsr   HDADDR           ; TMPP = what this one stands for
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             inc   HDPI
             lda   EMI
             clc
             adc   #$02
             sta   EMI
             jmp   :loop
:done        rts

*--------------------------------------
* HDADDR -- TMPP = the address placeholder HDPI stands for
*--------------------------------------
HDADDR       ldy   HDPI
             lda   HDIMWHAT,y

*--------------------------------------
* HDADDRA -- the same, for a code already in A
*--------------------------------------
HDADDRA                           ; its own line: a local on a global label's
                                    ; own line resolves in the previous scope
*--- CMP #$00 FIRST, and it is not redundant. HDADDR reaches here by falling
*    through a LDA, which sets Z from the code itself. HSDADDR reaches here by
*    JMP, after a CMP #$07 that leaves Z saying whether the code was seven --
*    so code 0 took the branch, fell past every test below it, and came out as
*    code 6: the allocator's floor instead of the array break.
*
*    A string array DIMmed at run time therefore took the floor's high byte as
*    the low half of its base. The floor starts at the end of the program, so
*    the two bytes it came back with were the program's own high byte twice --
*    $35C7 became $3535 -- and the DIM zeroed 146 bytes of the program before
*    filling in its descriptors. STATS crashed the first time it called a
*    helper that had been sitting there.
             cmp   #$00
             bne   :not0
             lda   ABRKA            ; 0  the array break
             sta   TMPP
             lda   ABRKA+1
             sta   TMPP+1
             rts
:not0        cmp   #$01
             bne   :not1
             lda   ABRKA            ; 1  its high half
             clc
             adc   #$01
             sta   TMPP
             lda   ABRKA+1
             adc   #$00
             sta   TMPP+1
             rts
:not1        cmp   #$02
             bne   :not2
             lda   #$01             ; 2  the heap pointer, low
             jmp   SCOFS
:not2        cmp   #$03
             bne   :not3
             lda   #$02             ; 3  the heap pointer, high
             jmp   SCOFS
:not3        cmp   #$04
             bne   :not4
             lda   MOOM             ; 4  out of memory
             sta   TMPP
             lda   MOOM+1
             sta   TMPP+1
             rts
:not4        cmp   #$05
             bne   :bndhi
             lda   HBNDLO           ; 5  the allocator's floor, low byte
             sta   TMPP
             lda   HBNDLO+1
             sta   TMPP+1
             rts
:bndhi       lda   HBNDHI           ; 6  and its high byte
             sta   TMPP
             lda   HBNDHI+1
             sta   TMPP+1
             rts

*--------------------------------------
* SCOFS -- TMPP = SCRA + A, the arithmetic EMSCOFS does before emitting
*--------------------------------------
SCOFS        clc
             adc   SCRA
             sta   TMPP
             lda   SCRA+1
             adc   #$00
             sta   TMPP+1
             rts

*--------------------------------------
* SABSLOT -- TMPP = where string array TMPA's base address is kept
*--------------------------------------
SABSLOT      lda   TMPA
             asl
             clc
             adc   SABASES
             sta   TMPP
             lda   #$00
             adc   SABASES+1
             sta   TMPP+1
             rts

*--------------------------------------
* ABSLOT -- TMPP = where array TMPA's base address is kept
*
* Two bytes an array, in the order LAYOUT counted them.
*--------------------------------------
ABSLOT       lda   TMPA
             asl
             clc
             adc   ABASES
             sta   TMPP
             lda   #$00
             adc   ABASES+1
             sta   TMPP+1
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
             cmp   #TTABK
             beq   :tabk
             cmp   #TSPCK
             beq   :spck

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

:tabk        jsr   EMTABGO          ; its own routine: inline, it pushed this
             bcs   :bad             ; routine's own :bad out of branch reach
             lda   #$00             ; an item like any other: a newline still
             sta   NONL             ; follows unless something suppresses it
             jmp   :item

:spck        jsr   EMSPCGO
             bcs   :bad
             lda   #$00
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
             bcs   :nonj
             cmp   #TLT
             beq   :cmp
             cmp   #TEQ
             beq   :cmp
             cmp   #TGT
             beq   :cmp

*--- The chaining loop above put enough between here and the tail that :none
*    and :bad are both out of branch reach. These two hops are REACHED ONLY BY
*    BRANCH OR BY THE TEST ABOVE FALLING THROUGH, which is the "no operator"
*    case and is what :nonj wants; :badj sits after an unconditional jump, so
*    nothing falls into it.
:nonj        jmp   :none
:badj        jmp   :bad
:cmp         jsr   RDCMPOP
             bcs   :badj

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

*--- A CHAINED COMPARISON: A = B = C, which Applesoft reads left to right as
*    (A = B) = C. LITTLE line 2140 is eighteen of them in a row -- naming the
*    variables in the order the interpreter should find them, a speed trick
*    that does nothing once compiled but is still an expression that has to
*    evaluate the same way.
*
*    MATCMP turns the comparison just emitted into a plain 1 or 0 in FAC,
*    which is precisely the shape the left-hand side takes on the :infac path
*    below -- value in FAC, nothing pending -- so going back to :num compares
*    it against whatever follows. MATCMP clears GOTCMP; the next time round
*    sets it again, so the LAST comparison in the chain is the one the caller
*    materialises, which is what EXPR expects.
             jsr   PEEK
             bcs   :fin
             cmp   #TLT
             beq   :chain
             cmp   #TEQ
             beq   :chain
             cmp   #TGT
             bne   :fin
:chain       jsr   MATCMP
             lda   #$00
             sta   ISSTR            ; a comparison's answer is a number
             jmp   :num
:fin         clc
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
             bne   :eqf
             lda   CMPB
             cmp   #TEQ
             beq   :ge
             cmp   #TLT
             beq   :ne
             jmp   :bad

*--- AND THE OTHER WAY ROUND. Applesoft takes => for >= and =< for <=, and
*    stores them as the two tokens in the order they were typed -- so the
*    equals can come first and this used to fall through to the > branch and
*    call it a BAD COMPARISON. AMAZING says IF X = > 36 and means what
*    everyone else writes as >=.
:eqf         cmp   #TEQ
             bne   :badj
             lda   CMPB
             cmp   #TGT
             beq   :ge
             cmp   #TLT
             beq   :le
:badj        jmp   :bad

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

ETERM        jsr   EPOW
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
             jsr   EPOW
             bcs   :drop3
             jsr   OPFLUSH
             pla
             sta   TMPP+1
             pla
             sta   TMPP
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   EPOW
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
             beq   :neg
             jmp   EPRIM            ; EPOW sits between here and there now
:neg         jsr   NEXTB
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

*--------------------------------------
* EPOW -- x ^ y
*
* LOOSER THAN A UNARY MINUS and tighter than * and /, so it sits between
* ETERM and EFACT. Built like ETERM, which is the same shape: left side into
* a temporary, right side into FAC, then the ROM.
*
* The other way round first, on the reasoning that every other language binds
* ^ tighter than negation. Applesoft does not: it makes -2^2 into FOUR, which
* is (-2)^2. The suite said so -- the interpreter is the only authority on
* this and guessing produced the wrong answer.
*
* APPLESOFT'S OWN ROUTINE, not EXP(y * LOG(x)). The two agree on ordinary
* numbers and part company at nothing: LOG(0) has no answer, and LEMONADE
* squares a price -- `(P9 ^ 2) * S2 / P(I) ^ 2` -- which is zero whenever the
* stand has not sold any. FPWRT gives 0, the logarithm gives an error.
*
* CONUPK takes the left side out of the temporary into ARG and leaves ARGEXP
* in A, which is exactly what FPWRT wants to see on entry.
*--------------------------------------
EPOW         jsr   EFACT
             bcs   :bad
             lda   ISSTR            ; a string has no power
             bne   :done
:loop        jsr   PEEK
             bcs   :done
             cmp   #TPOW
             bne   :done
             jsr   NEXTB
             lda   PENDOK
             beq   :infac

             lda   PENDA
             pha
             lda   PENDA+1
             pha
             lda   #$00
             sta   PENDOK
             jsr   EFACT
             bcs   :drop2
             jsr   OPFLUSH
             pla
             sta   TMPP+1
             pla
             sta   TMPP
             jmp   :emit

:infac       jsr   PUSHFAC
             jsr   EFACT
             bcs   :bad
             jsr   OPFLUSH
             jsr   POPTMP

:emit        lda   #<CONUPK         ; ARG <- the base, ARGEXP into A
             sta   ROMA
             lda   #>CONUPK
             sta   ROMA+1
             jsr   EMOPA
             lda   #$20             ; JSR FPWRT
             jsr   EMIT
             lda   #<FPWRT
             jsr   EMIT
             lda   #>FPWRT
             jsr   EMIT
             lda   #$00
             sta   PENDOK
             jmp   :loop

:drop2       pla
             pla
:bad         sec
             rts
:done        clc
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
             cmp   #TFNK
             beq   :ufnj
             cmp   #TPDL
             beq   :pdlj
             cmp   #TFREK
             beq   :frej
             cmp   #TSCRN
             beq   :scrnj
             cmp   #TPOSK
             beq   :posj
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
:bad         lda   #$26
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
:ufnj        jmp   UFN
:pdlj        jmp   FPDL
:frej        jmp   FFRE
:scrnj       jmp   FSCRN
:posj        jmp   FPOS

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
:bad3        lda   #$26
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
             lda   #$26             ; CANNOT READ THAT
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
             cmp   #'%'
             beq   :ivarj
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
:svarj       jmp   SVARP
:ivarj       jmp   IVARP            ; LEN's body sits between here and there

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

*--- MID$: the start, which goes on the stack too because working out the
*    count can reach another MID$ through a LEN
*--- Its failure exit belongs INSIDE this routine. It was sitting above the
*    label, which put it in the previous one's scope -- it resolved to the
*    right address only because it happened to sit just before FMID.
FMID
             jmp   :go
:mbad        sec
             rts
:go          jsr   EMAYINT
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
SVARP        jsr   NEXTB            ; what follows the $ says which kind
             bcs   :plain
             sta   CH               ; PUTBACK hands back CH, not A
             cmp   #'('
             beq   :arr
             jsr   PUTBACK
:plain       jsr   SVFIND
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

*--- An element of one. Its address is only known when the program runs, so
*    the descriptor is copied through a pointer rather than from a fixed
*    address the way a plain string variable is.
:arr         jsr   SAFIND
             bcs   :arrbad
             jsr   EMSSUBS
             bcs   :arrbad
             jsr   EMSAGET
             lda   #$01
             sta   ISSTR
             lda   #$00
             sta   PENDOK
             clc
             rts
:arrbad      sec
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
             cmp   #$2c
             beq   :multij          ; a comma: there are more to come
             cmp   #')'
             bne   :dropbad

             lda   #$20             ; JSR AYINT -- the subscript as an integer
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT

             pla                    ; which array, and where its base is kept
             sta   TMPA
             jsr   ABSLOT           ; TMPP = the array's base slot
             lda   TMPP             ; copied out before emitting: see ABTMP
             sta   ABTMP
             lda   TMPP+1
             sta   ABTMP+1
             lda   #$ad             ; LDA base
             jsr   EMIT
             lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
             jsr   EMIT
             lda   #$ac             ; LDY base+1
             jsr   EMIT
             inc   ABTMP            ; the high half of the same address
             bne   :abhi
             inc   ABTMP+1
:abhi        lda   ABTMP
             jsr   EMIT
             lda   ABTMP+1
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

:multij      jmp   :multi
:dropbad     pla
             lda   #$27             ; BAD SUBSCRIPT
             jsr   SETBAD
             sec
             rts
:drop        pla
             sec
             rts

*--------------------------------------
*    SEVERAL SUBSCRIPTS. The index is built up as
*
*        i1, then (idx * extent-of-k) + ik for each one after
*
*    which is the mixed-radix sum, and the extents come from the DIM. The
*    multiplying is done by the compiled program because the subscripts are
*    only known when it runs; the extents are known here.
*
*    A PROGRAM MUST HAVE SAID DIM A(3,4) BEFORE WRITING A(I,J). A bare use
*    gives an array eleven elements and one dimension, and pass 1 cannot count
*    the commas from the use -- what is inside the bracket is scanned as
*    ordinary code. So a subscript with more commas than the DIM allowed is
*    refused by name rather than folded into one dimension.
:multi       pla                    ; which array, kept where EMDIMX can see it
             sta   MULARR
             pha
             lda   #$01
             jsr   NEED3            ; this program wants the multiply
             lda   #$01
             sta   DIMN

             lda   #$20             ; JSR AYINT
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$a5             ; the running index starts as the first one
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1c
             jsr   EMSCOFS
             lda   #$a5
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1d
             jsr   EMSCOFS

:more        jsr   EMDIMX           ; DEXT = the extent of dimension DIMN
             bcs   :dropbad
             lda   #$ad             ; idx into the multiply's left side
             jsr   EMIT
             lda   #$1c
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$1e
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$1d
             jsr   EMSCOFS
             lda   #$8d
             jsr   EMIT
             lda   #$1f
             jsr   EMSCOFS
             lda   #$a9             ; and the extent into its right
             jsr   EMIT
             lda   DEXT
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$20
             jsr   EMSCOFS
             lda   #$a9
             jsr   EMIT
             lda   DEXT+1
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$21
             jsr   EMSCOFS
             lda   #$20
             jsr   EMIT
             lda   HMUL
             jsr   EMIT
             lda   HMUL+1
             jsr   EMIT

             lda   DIMN             ; an inner subscript may be an array too
             pha
             lda   MULARR
             pha
             jsr   NEXPR            ; the subscript for this dimension
             bcc   :inner
             pla
             pla
             jmp   :drop
:inner       pla
             sta   MULARR
             pla
             sta   DIMN
             lda   #$20
             jsr   EMIT
             lda   #<AYINT
             jsr   EMIT
             lda   #>AYINT
             jsr   EMIT
             lda   #$18             ; idx = product + this one
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$22
             jsr   EMSCOFS
             lda   #$65
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1c
             jsr   EMSCOFS
             lda   #$ad
             jsr   EMIT
             lda   #$23
             jsr   EMSCOFS
             lda   #$65
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT
             lda   #$8d
             jsr   EMIT
             lda   #$1d
             jsr   EMSCOFS

             inc   DIMN
             jsr   NEXTB
             bcs   :dropn
             cmp   #$2c
             beq   :moren
             cmp   #')'
             beq   :allsubs
             jmp   :dropbad         ; the shared exits are a long way back
:moren       jmp   :more            ; and so is the top of this loop
:dropn       jmp   :drop
:allsubs

*--- and the finished index goes where a single one would have left it
             lda   #$ad
             jsr   EMIT
             lda   #$1c
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #FACLO
             jsr   EMIT
             lda   #$ad
             jsr   EMIT
             lda   #$1d
             jsr   EMSCOFS
             lda   #$85
             jsr   EMIT
             lda   #FACHI
             jsr   EMIT

             pla
             sta   TMPA
             jsr   AADDR
             lda   #$a9
             jsr   EMIT
             lda   TMPP
             jsr   EMIT
             lda   #$a0
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT
             lda   #$01
             jsr   NEED
             lda   #$20
             jsr   EMIT
             lda   HARR
             jsr   EMIT
             lda   HARR+1
             jsr   EMIT
             clc
             rts

*--------------------------------------
* EMDIMX -- DEXT <- the extent of dimension DIMN of the array on the stack
*
* Carry set if the program never said DIM for that many, which is the one
* thing that cannot be compiled: the size was fixed before the subscript was
* read, and guessing here would write outside it.
*--------------------------------------
EMDIMX       lda   MULARR
             sta   TMPA
             jsr   DIMSLOT
             ldy   #$00
             lda   (TMPP),y         ; how many dimensions it was given
             cmp   DIMN
             bcc   :nodim
             beq   :nodim           ; this one is past the last of them
             lda   DIMN             ; entry 1 + 2*DIMN is the next extent
             asl
             tay
             iny
             lda   (TMPP),y
             sta   DEXT
             iny
             lda   (TMPP),y
             sta   DEXT+1
             clc
             rts
:nodim       lda   #$15             ; that many were never declared
             jsr   SETBAD
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
* CARRY OUT IS NOT A RESULT. It falls out of `cmp #$03` below: CLEAR in
* passes 1 and 2, SET in pass 3. Nothing here can fail, so no caller should
* read it -- but a statement handler that ends `jmp EMIT` hands that carry to
* the dispatcher as its own success flag, and then compiles clean right up to
* the pass that writes the file. GRUN did exactly that: the listing printed,
* pass 3 stopped at the RUN, and the output was closed half-written with no
* complaint to say why. Tail-call EMIT only where the carry is discarded.
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

*--------------------------------------
* EMBLOB -- copy a helper into the program, filling in its addresses
*
* THE POINT OF IT. A helper written as `lda #x : jsr EMIT` costs five bytes of
* compiler for every byte that reaches the program. Written out once as data
* and copied, it costs one. The emitters were the largest thing in the image
* -- EMHGC alone was 1,144 bytes to emit about 277 -- and this is where the
* room for anything new comes from. HDIMB has always been done this way; this
* is the same idea with the copier shared.
*
*   in   A,Y    where the blob is
*        BLOBN  how many bytes it is
*
* ONE $FF IN THE BLOB IS ONE ENTRY in a table that FOLLOWS THE BLOB -- EMBLOB
* finds it by adding the length, so a caller passes one address rather than
* two. The blob advances by a byte whatever the entry turns out to be worth,
* which is why the marker is one byte and not two: LDA #<X / LDY #>X puts the
* halves of an address four instructions apart, and a two-byte marker cannot
* say that.
*
*   $00-$3F   SDESCA + offset          two bytes
*   $40-$7F   SCRA + offset            two bytes
*   $80-$9F   BVARS entry, whole       two bytes
*   $A0-$BF   BVARS entry + offset     two bytes, and EATS THE NEXT TABLE BYTE
*                                      for the offset -- a place inside another
*                                      helper, which is how one branches to a
*                                      label in a second one
*   $C0-$DF   BVARS entry, low half    one byte
*   $E0-$FF   BVARS entry, high half   one byte
*
* SO NO EMITTED BYTE MAY BE $FF, and no offset may reach $40. Both are checked
* when a blob is generated rather than left to hold by luck.
*
* The reads are self-modified rather than indirect, which keeps this off the
* zero page -- there are two spare bytes there and they are spoken for. The
* compiler runs from RAM, so there is nothing clever about it.
*--------------------------------------
EMBLOB                             ; ITS OWN LINE: a local on a global label's
             sta   :rd+1            ; own line resolves in the previous scope
             sty   :rd+2
             clc                    ; the WHAT table sits just past the blob
             adc   BLOBN
             sta   :rw+1
             sta   :vr+1
             tya
             adc   #$00
             sta   :rw+2
             sta   :vr+2
             lda   #$00
             sta   EMI
             sta   HDPI
:loop        ldy   EMI
             cpy   BLOBN
             bcs   :done
:rd          lda   $ffff,y
             cmp   #$ff
             beq   :what
             jsr   EMIT
:next        inc   EMI
             jmp   :loop
:done        rts

:what        ldy   HDPI
:rw          lda   $ffff,y
             inc   HDPI
             cmp   #$40
             bcc   :sd
             cmp   #$80
             bcc   :sc
             cmp   #$a0
             bcc   :var
             cmp   #$c0
             bcc   :voff
             jmp   :half

:sd          jsr   EMSDOFS          ; SDESCA + offset, both bytes
             jmp   :next
:sc          and   #$3f
             jsr   EMSCOFS          ; SCRA + offset, both bytes
             jmp   :next

*--- A TWO-BYTE COMPILER VARIABLE, named by its place in BVARS: where another
*    helper landed, which is not known until it lands.
:var         and   #$1f
             jsr   BVGET
             jsr   EMADDR
             jmp   :next

*--- OR A PLACE INSIDE ONE. The offset is the next byte of the table, which
*    this kind eats: a helper that branches to a label in another one knows
*    the label's distance from the top but not where the top will be.
:voff        and   #$1f
             jsr   BVGET
             ldy   HDPI
             inc   HDPI
:vr          lda   $ffff,y
             clc
             adc   TMPP
             sta   TMPP
             bcc   :vnc
             inc   TMPP+1
:vnc         jsr   EMADDR
             jmp   :next

*--- OR ONE HALF OF ONE, for LDA #<X and LDY #>X. Bit 5 picks the half.
:half        pha
             and   #$20
             sta   BHALF
             pla
             and   #$1f
             jsr   BVGET
             lda   BHALF
             bne   :hi
             lda   TMPP
             jmp   :emit
:hi          lda   TMPP+1
:emit        jsr   EMIT
             jmp   :next

*--------------------------------------
* BVGET -- TMPP = what the BVARS entry in A is holding
*
* Both bytes are read BEFORE TMPP is written, because TMPP is the pointer
* being read through.
*--------------------------------------
BVGET        asl
             tax
             lda   BVARS,x
             sta   TMPP
             lda   BVARS+1,x
             sta   TMPP+1
             ldy   #$01
             lda   (TMPP),y
             tax
             dey
             lda   (TMPP),y
             stx   TMPP+1
             sta   TMPP
             rts

*--- WHICH VARIABLES A BLOB MAY NAME. Two bytes an entry, and the number in a
*    WHAT byte is its place here. Add to the end; the generator that writes
*    the WHAT tables carries the same list and nothing else depends on it.
BVARS        da    MLONG
             da    HERR
             da    HALLOC
             da    HINPUT
             da    HNEXTI
             da    FINPC            ; 5 -- added for EMHGC
             da    HRUNA            ; 6
             da    HGC              ; 7

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
             lda   ORG
             sta   TMPP
             lda   ORG+1
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
             lda   ORG
             sta   TMPP
             lda   ORG+1
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
LAYOUT       lda   ORG              ; past the JMP at the front
             clc
             adc   #$03
             sta   VARBASE
             sta   TMPP
             lda   ORG+1
             adc   #$00
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

*--- A BASE ADDRESS PER ARRAY, two bytes each, and IN FRONT OF TEMPBASE on
*    purpose: the prologue zero-fills everything from there up to the code,
*    and these have to carry real addresses rather than zeros.
*
*    Every array goes through one, not just the ones that need to. A subscript
*    used to carry its array's base as an immediate, which only works while
*    the base is known when the code is generated -- and DIM A(N) does not
*    know it until the program runs. One path for both costs two bytes an
*    array and a load instead of an immediate.
             lda   TMPP
             sta   ABASES
             lda   TMPP+1
             sta   ABASES+1
             lda   #$02
             sta   ACCSZ
             lda   NARR
             sta   ACCN
             jsr   BUMP

*--- and the same for the arrays of strings
             lda   TMPP
             sta   SABASES
             lda   TMPP+1
             sta   SABASES+1
             lda   #$02
             sta   ACCSZ
             lda   NSARR
             sta   ACCN
             jsr   BUMP

*--- THE COLLECTOR'S TABLE OF ROOT RUNS. Entry 0 is the static run the layout
*    knows about -- the two working descriptors, the string variables and the
*    string arrays sized at compile time. One more entry for each string array
*    sized at run time, filled in by its DIM. Four bytes each: where it starts
*    and how many descriptors it holds.
             lda   TMPP
             sta   RUNTABA
             lda   TMPP+1
             sta   RUNTABA+1
             lda   #$04
             sta   ACCSZ
             lda   NSDYN
             clc
             adc   #$01             ; the static run is entry 0
             sta   ACCN
             jsr   BUMP

*--- THE ARRAY BREAK: how far up the free space the arrays have reached. It
*    starts at the end of the program and a runtime DIM moves it up. The
*    string heap comes down from HIMEM to meet it, which is the arrangement
*    Applesoft itself uses.
             lda   TMPP
             sta   ABRKA
             lda   TMPP+1
             sta   ABRKA+1
             lda   #$02
             sta   ACCSZ
             lda   #$01
             sta   ACCN
             jsr   BUMP

             lda   #$05
             sta   ACCSZ
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
             sta   FNBASE           ; five bytes per DEF FN, holding the
             lda   TMPP+1           ; caller's parameter while the body runs
             sta   FNBASE+1

             lda   #$05
             sta   ACCSZ
             lda   NDEFS
             sta   ACCN
             jsr   BUMP

*--- the integer variables, two bytes apiece and outside the collector's run
             lda   TMPP
             sta   IVBASE
             lda   TMPP+1
             sta   IVBASE+1
             lda   #$02
             sta   ACCSZ
             lda   NIVARS
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

*--- THE ARRAYS OF STRINGS GO HERE, still inside the run. Every element is a
*    descriptor and therefore a root, so putting them anywhere else would give
*    the collector two ranges to walk instead of one. Three bytes an element,
*    the same as a plain string variable, and for the same reason.
             lda   TMPP
             sta   SABASE
             lda   TMPP+1
             sta   SABASE+1
             lda   NSARR
             sta   TMPA
             jsr   SASUM            ; SATOT = the elements of all of them
             lda   SAELT            ; kept once: every later call is partial
             sta   NSAEL
             lda   SAELT+1
             sta   NSAEL+1

*--- FROM SABASE, NOT TMPP. SASUM reaches the table through SLOTN, which
*    works in TMPP, so by the time it returns TMPP is pointing at a table
*    entry up at $8000 rather than at the layout. Adding to that put the
*    program's data fifteen thousand bytes further on and the size guard
*    caught it -- which is the only reason this was a refusal and not a
*    program that overwrote ProDOS.
             lda   SABASE
             clc
             adc   SATOT
             sta   TMPP
             lda   SABASE+1
             adc   SATOT+1
             sta   TMPP+1

*--- and past the roots, everything else the string runtime works in:
*    MID$'s start, the heap pointer, the join's destination and length, and
*    the collector's own five.
*--- THE COLLECTOR COUNTS ITS ROOTS IN TWO BYTES now, so there is no ceiling
*    here to check against. The memory guard further down is what stops a
*    program whose strings will not fit; this used to stop one whose strings
*    merely could not be COUNTED.
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
* SASUM -- SATOT = the bytes taken by string arrays 0 to TMPA-1, and NSAEL
*          the number of descriptors in them
*
* Three a time round rather than a multiply, as ASUM does five: this runs once
* per array per pass, not once per subscript.
*--------------------------------------
SASUM        lda   #$00
             sta   SATOT
             sta   SATOT+1
             sta   SAELT
             sta   SAELT+1
             sta   SAI
:each        lda   SAI
             cmp   TMPA
             bcs   :done
             sta   TMPA2
             jsr   SASLOTG
             ldy   #$02
             lda   (TMPP),y
             sta   ACOUNT
             iny
             lda   (TMPP),y
             sta   ACOUNT+1
             lda   SAELT            ; a running count, not the kept one
             clc
             adc   ACOUNT
             sta   SAELT
             lda   SAELT+1
             adc   ACOUNT+1
             sta   SAELT+1
             ldx   #$03             ; three bytes for each of them
:three       lda   SATOT
             clc
             adc   ACOUNT
             sta   SATOT
             lda   SATOT+1
             adc   ACOUNT+1
             sta   SATOT+1
             dex
             bne   :three
             inc   SAI
             jmp   :each
:done        rts

*--- SASLOT reads TMPA; this one reads TMPA2, so the loop above can keep its
*    own index without the slot routine treading on it
SASLOTG      lda   TMPA
             pha
             lda   TMPA2
             sta   TMPA
             jsr   SASLOT
             pla
             sta   TMPA
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

             dum   $14d0            ; pass 1's block below keeps growing
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
SSTR         ds    2                ; a string array's row stride, while it is used
BHALF        ds    1                ; which half of an address a placeholder wants
BLOBN        ds    1                ; how long the blob EMBLOB is copying is
FVAR         ds    1
FORN         ds    1                ; which FOR is being compiled
FSTKTOP      ds    1
FSTKMAX      ds    1                ; the deepest it has been, for a reused NEXT
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
SABASE       ds    2                ; where the arrays of strings begin
SATOT        ds    2                ; and how many bytes they take
NSAEL        ds    2                ; how many descriptors that is
SAELT        ds    2                ; SASUM's running count of them
ACOUNT       ds    2                ; one array's element count
TMPA2        ds    1
SAI          ds    1                ; SASUM's own index
SDI          ds    1                ; and the descriptor byte being emitted
HCTAB        ds    2                ; where the eight colour masks landed
HMUL         ds    2                ; the runtime multiply, if the program has
USES3        ds    1                ; a subscript with a comma in it
DIMN         ds    1                ; how many subscripts one has been given
DEXT         ds    2                ; and the extent being multiplied in
MULARR       ds    1                ; which array the subscripts belong to
HSARR        ds    2                ; the three-byte address helper
HARR         ds    2                ; where the address helper landed
FINPC        ds    2                ; and the end of the whole thing
ZFILLA       ds    2                ; where the zero-filled range begins, for CLEAR
ABASES       ds    2                ; where the per-array base addresses live
ABRKA        ds    2                ; where the array break lives in the image
HDIMA        ds    2                ; and where the DIM helper landed
HRUNA        ds    2                ; and the collector's run walker
RUNTABA      ds    2                ; where the table of runs lives
SABASES      ds    2                ; the string arrays' base addresses
HSDIMA       ds    2                ; where the string DIM helper landed
PADI         ds    1                ; EMSETRUN's pad count, which cannot be X
EMCH         ds    1                ; a character on its way out
EMX          ds    1                ; EMWORD's digit index, likewise not X
HDPI         ds    1                ; which of its placeholders is being filled
HBNDHI       ds    2                ; the two bytes of the heap allocator's
HBNDLO       ds    2                ; floor, so a DIM can raise it
ABI          ds    1                ; the array-base loop's own counter: ASUM
                                    ; writes TMPA as it runs, so a loop that
                                    ; counted in TMPA never moved past one
ABTMP        ds    2                ; an address being emitted, copied out of
                                    ; TMPP first. NOT because EMIT clobbers it
                                    ; -- it does not, and code all over this
                                    ; file has held TMPP across EMIT since the
                                    ; beginning -- but because the routines
                                    ; that COMPUTE these addresses work in
                                    ; TMPP, so a second call between the two
                                    ; halves would lose the first. Copying out
                                    ; makes that impossible to get wrong.
ORG          ds    2                ; where the compiled program loads, chosen
                                    ; per program -- see pass 1's PICKORG
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
HNEXTD       ds    2
DTAB         ds    2                ; where the DATA items landed
MDATA        ds    2
DEMI         ds    2                ; walking them out
DEFIDX       ds    1                ; which function is being compiled
CPT          ds    2                ; an address being emitted a byte at a time
IVDEST       ds    2                ; where an integer assignment is going, which
*                                     CANNOT be CPT: the expression on the
*                                     right may read an integer variable, and
*                                     reading one works in CPT
UFNADR       ds    2                ; the body of the function being called, which
*                                     CANNOT live in CPT: EMCOPY5 works there
DQUOTE       ds    1
HPOKE        ds    2
HCALL        ds    2
HINPUT       ds    2                ; a line from the keyboard
HNEXTI       ds    2                ; and the next item on it
HIVAL        ds    2
HPMSG        ds    2
HIREENT      ds    2
HIEXTRA      ds    2
MREENT       ds    2
MEXTRA       ds    2
HICOPY       ds    2
INPPC        ds    2                ; where this INPUT began, for ?REENTER
MOOM         ds    2                ; where the two messages landed
MSYN         ds    2                ; and where a numeric GET's went
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
