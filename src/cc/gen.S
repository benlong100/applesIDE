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
COUTA        equ   $fded

NTEMPS       equ   8
FDEPTH       equ   8                ; nested FOR loops

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
TAND         equ   $cd
TOR          equ   $ce

*--------------------------------------
* GENPASS -- run one pass over the source. PASSNO says which.
*--------------------------------------
GENPASS      lda   #$00
             sta   LINEI
             sta   LINEI+1
             sta   TEMPTOP
             sta   FORN
             sta   FSTKTOP
             sta   PENDOK
             sta   OUTLEN
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

*--- remember where the stack was, so END can unwind a GOSUB
:prologue    lda   #$ba             ; TSX
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
             bcs   :fail
             inc   LINEI
             bne   :line
             inc   LINEI+1
             jmp   :line

*--- falling off the end returns to BASIC, the same as END does
:end         lda   PC
             sta   ENDPC
             lda   PC+1
             sta   ENDPC+1
             jsr   EMEND
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
GENSTMT      lda   CH
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
GLET         jsr   GETVAR
             bcs   :bad
             lda   VARI
             pha
             lda   CH               ; GETVAR leaves what ended the name
             cmp   #TEQ
             bne   :bad2
             jsr   EXPR
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
             jsr   EXPR             ; where it starts
             bcs   FORBAD
             lda   FVAR
             sta   TMPA
             jsr   VADDR
             jsr   EMSTP

             jsr   NEXTB
             bcs   FORBAD
             cmp   #TTO
             bne   FORBAD
             jsr   EXPR             ; and where it stops
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
             jsr   EXPR
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
             cmp   #$2c              ; a comma: Merlin cannot quote one
             beq   :unsup
             cmp   #'"'
             beq   :str
             lda   #$00
             sta   NONL
             jsr   EXPR
             bcs   :bad
             jsr   EMPRFAC
             jmp   :sep

:str         jsr   NEXTB            ; the opening quote
             lda   #$00
             sta   NONL
             jsr   EMPRSTR
             bcs   :bad
             jmp   :sep

:sep         jsr   PEEK
             bcs   :end
             cmp   #';'
             bne   :item
             jsr   NEXTB
             lda   #$01
             sta   NONL
             jmp   :item

:end         lda   NONL
             bne   :done
             jsr   EMCR
:done        clc
             rts
:unsup       lda   #$09
             jsr   SETBAD
:bad         sec
             rts

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
* EMPRSTR -- a literal, emitted inline with a JMP over it
*
* The text has to live somewhere, and the byte after the JMP is somewhere the
* compiler already knows the address of -- no pool, no second pass over the
* output, no fixups.
*--------------------------------------
EMPRSTR      lda   #$00
             sta   STRLEN
:read        jsr   NEXTB
             bcs   :badj
             sta   CH
             bne   :notend
:unterm2     jmp   :unterm          ; the failures are past the whole routine
:badj        jmp   :bad
:notend      cmp   #'"'
             beq   :have
             ldx   STRLEN
             cpx   #$ff
             bcc   :put
             jmp   :toolong
:put
             lda   CH
             ora   #$80             ; high bits set, as COUT wants them
             sta   STRBUF,x
             inc   STRLEN
             jmp   :read

*--- Now the length is known, so the jump over the text can be emitted with
*    its real target the first time.
*
*    IT USED TO BE PATCHED, reaching back into the output window after the
*    text had gone by -- which worked until a program grew enough for a
*    string to straddle a window boundary, and then failed on programs that
*    had compiled the week before. Collecting the string first removes the
*    coupling between a literal and the size of the write buffer rather than
*    making the buffer bigger, which would only move the boundary.
:have        ldx   STRLEN
             lda   #$00
             sta   STRBUF,x         ; terminate it

             lda   #$4c             ; JMP
             jsr   EMIT
             lda   PC               ; the text starts past the two address
             clc                    ; bytes that follow
             adc   #$02
             sta   STRAT
             lda   PC+1
             adc   #$00
             sta   STRAT+1

             lda   STRAT            ; and the jump lands past the text and
             clc                    ; its terminator
             adc   STRLEN
             sta   TMPP
             lda   STRAT+1
             adc   #$00
             sta   TMPP+1
             inc   TMPP
             bne   :nc
             inc   TMPP+1
:nc          lda   TMPP
             jsr   EMIT
             lda   TMPP+1
             jsr   EMIT

             lda   #$00
             sta   EMI
:text        ldx   EMI
             cpx   STRLEN
             bcs   :done
             lda   STRBUF,x
             jsr   EMIT
             inc   EMI
             jmp   :text
:done        lda   #$00
             jsr   EMIT

             lda   #$00
             sta   EMI
:blob        ldy   EMI
             lda   PRSTRB,y
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #PRSTRA-PRSTRB
             bcc   :blob
             lda   STRAT            ; the LDA abs,X operand
             jsr   EMIT
             lda   STRAT+1
             jsr   EMIT
             lda   #$00
             sta   EMI
:blob2       ldy   EMI
             lda   PRSTRA,y
             jsr   EMIT
             inc   EMI
             lda   EMI
             cmp   #PRSTRE-PRSTRA
             bcc   :blob2
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

PRSTRB       dfb   $a2,$00          ; LDX #$00
             dfb   $bd              ; LDA <text>,X -- the address follows
PRSTRA       dfb   $f0,$06          ; BEQ past the loop
             dfb   $20,$ed,$fd      ; JSR COUT
             dfb   $e8              ; INX
             dfb   $d0,$f5          ; BNE back
PRSTRE

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
EXPR         jsr   ECONDC
             bcs   :bad
             lda   GOTCMP
             beq   :plain
             jmp   MATCMP           ; a comparison, wanted as a value
:plain       jmp   OPFLUSH
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
ECMPC        jsr   ESUM
             bcc   :ok
             jmp   :bad             ; the tail of this routine is out of reach
:ok          jsr   PEEK
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
             bcs   :bad
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
             cmp   #$80
             bcs   :fn
             cmp   #'('
             beq   :paren
             jsr   ISDIGIT
             bcc   :num
             lda   CH
             cmp   #'.'
             beq   :num
             jsr   ISALNUM
             bcc   :var
:bad         lda   #$0c
             jsr   SETBAD
             sec
             rts

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
             jsr   EXPR
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
:num         jsr   RDNUM
             bcs   :bad
             jsr   PUTBACK          ; what ended it is not ours
             jsr   NUMCONV
             jsr   CFIND
             bcs   :bad
             jsr   CADDR
             jmp   DEFER

:var         jsr   GETVAR
             bcs   :bad
             jsr   PUTBACK          ; what ended the name is not ours
             lda   VARI
             sta   TMPA
             jsr   VADDR
*--- fall through

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
GETVAR       lda   #$00
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
:end         jsr   VFIND
             bcs   :bad
             lda   TMPA
             sta   VARI
             clc
             rts
:bad         lda   #$0d
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

             lda   TMPP             ; and the code, one byte past it
             clc
             adc   #$01
             sta   CODESTA
             lda   TMPP+1
             adc   #$00
             sta   CODESTA+1
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
LOGTGT       ds    1                ; an index EMIT cannot clobber
             dend
