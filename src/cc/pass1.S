*--------------------------------------
* PASS1.S -- read the program once and find out how big its data is
*
* THREE PASSES, and this is the first. The reason there are three is worth
* stating, because two would be the obvious guess:
*
*   1. this one -- every line number, every variable, every constant. At the
*      end the data area's size is known, so every variable and constant has
*      a fixed address.
*   2. generate code with the output thrown away, recording where each line
*      starts. Sizes do not depend on branch targets -- a JMP is three bytes
*      whatever it jumps to -- so this can be done before any target is known.
*   3. generate it again for real, resolving branches from the table pass 2
*      built.
*
* Passes 2 and 3 are the same code with writing switched off, which is how
* every two-pass assembler has worked since before this machine existed. The
* extra pass over the FILE is cheap next to the arithmetic; holding the whole
* program in memory to avoid it is what is not affordable.
*
* THE OUTPUT'S LAYOUT, decided here:
*
*   $6000  JMP to the code, so BRUN enters at the front and still finds it
*   $6003  variables, five bytes each
*          constants, five bytes each
*          the code
*
* Data first because pass 1 can size it and cannot size the code. The JMP is
* three bytes spent once to make the file BRUNnable.
*--------------------------------------

*--- Every one of these was confirmed on a running //e; docs/compiler.md says
*    how, and says which two are the other way round from the obvious guess.
MOVFM        equ   $eaf9            ; FAC <- packed at (A lo, Y hi)
MOVMF        equ   $eb2b            ; packed at (X lo, Y hi) <- FAC
FADD         equ   $e7be            ; FAC <- FAC + memory
FSUB         equ   $e7a7            ; FAC <- memory - FAC   -- NOT FAC-memory
FMUL         equ   $e97f            ; FAC <- FAC * memory
FDIV         equ   $ea66            ; FAC <- memory / FAC   -- NOT FAC/memory
FOUT         equ   $ed34            ; FAC -> string at $0100

CODEORG      equ   $6000

*--- Applesoft's tokens, by value. tools/gentokens.py has the table these come
*    out of: END is $80 and they run in order from there.
TGOTO        equ   $ab
TGOSUB       equ   $b0
TREM         equ   $b2
TTHEN        equ   $c4

*--------------------------------------
* PASS1 -- walk the program, filling the three tables
*--------------------------------------
PASS1        lda   #$00
             sta   COUNT
             sta   COUNT+1
             sta   NVARS
             sta   NCONST
             sta   NLINES
             sta   NLINES+1
             sta   BADFLG

*--- ZERO AND ONE ARE ALWAYS THERE, whether the program mentions them or not.
*    A comparison compiles to code that loads one of them, and negation is
*    zero minus the value; a program with neither in its text would otherwise
*    have nowhere for that code to point.
             lda   #$00
             sta   TMPA
             ldy   #$04
:z           sta   CTAB,y
             sta   CTAB+5,y
             dey
             bpl   :z
             lda   #$81             ; one, packed
             sta   CTAB+5
             lda   #$02
             sta   NCONST

:line        jsr   RDWORD           ; the next-line address
             bcs   :done
             lda   WORD
             ora   WORD+1
             beq   :done            ; zero: the program ends here
             jsr   RDWORD           ; the line number
             bcs   :done
             jsr   LTADD
             jsr   SCANBODY
             bcc   :line
:done        rts

*--------------------------------------
* SCANBODY -- one line's tokens, as far as its terminating zero
*
* Carry set means the file ended mid-line, which is a truncated file rather
* than a program.
*--------------------------------------
SCANBODY     lda   #$00
             sta   INSTR
             sta   LINEREF

:next        jsr   RDBYTE
             bcs   :eof
             sta   CH
             bne   :notend
             clc
             rts
:notend      cmp   #'"'
             bne   :notq
             lda   INSTR            ; a quote flips the string state
             eor   #$01
             sta   INSTR
             jmp   :next
:notq        lda   INSTR
             bne   :next            ; inside a string: text, not code

             lda   CH
             cmp   #TREM
             beq   :rem
             cmp   #$80
             bcs   :token

*--- Not a token. A letter begins a name; a digit or a point begins a number.
*    Both are far enough down the file to be out of branch range, so the tests
*    set up a JMP rather than branching straight there.
             cmp   #'0'
             bcc   :notdig
             cmp   #'9'+1
             bcc   :numj
:notdig      cmp   #'.'
             beq   :numj
             cmp   #'A'
             bcc   :next
             cmp   #'Z'+1
             bcc   :namej
             jmp   :next
:numj        jmp   :number
:namej       jmp   :name

*--- A token. It clears the expectation of a line number unless it is one of
*    the three that CREATE one. GOTO, GOSUB and THEN are followed by digits
*    that are a branch target, not a value, and allocating a constant for
*    them would put 30 in the data area of every program that says GOTO 30.
:token       lda   #$00
             sta   LINEREF
             lda   CH
             cmp   #TGOTO
             beq   :branch
             cmp   #TGOSUB
             beq   :branch
             cmp   #TTHEN
             bne   :next
:branch      lda   #$01
             sta   LINEREF
             jmp   :next

*--- REM, and the rest of the line is a comment
:rem         jsr   RDBYTE
             bcs   :eof
             cmp   #$00
             bne   :rem
             clc
             rts
:eof         sec
             rts

*--------------------------------------
* A name. Two characters are significant to Applesoft, so S and SUM and
* SUMMARY are one variable and this keeps only the first two -- which is not
* a simplification but the machine's own rule, and a compiler that gave them
* separate slots would disagree with the interpreter about a running program.
*--------------------------------------
:name        lda   #$00
             sta   LINEREF
             sta   VN1
             sta   NCH
             lda   CH
             sta   VN0
:nloop       jsr   RDBYTE
             bcs   :eof
             sta   CH
             jsr   ISALNUM
             bcs   :nend
             lda   NCH
             bne   :nmore           ; past the second: not significant
             lda   CH
             sta   VN1
:nmore       inc   NCH
             jmp   :nloop

*--- What ENDED the name says what kind it is. $ and % are string and integer
*    variables and ( is an array; none are in this milestone, and compiling
*    them as though they were plain floats would produce a program that ran
*    and gave wrong answers, which is worse than refusing.
:nend        lda   CH
             cmp   #'$'
             beq   :unsup
             cmp   #'%'
             beq   :unsup
             cmp   #'('
             beq   :unsup
             jsr   VARADD
             jmp   :redo
:unsup       lda   #$01
             sta   BADFLG
             jmp   :next

*--- A number. Either a branch target -- digits Applesoft parses at run time,
*    which pass 3 turns into an address -- or a constant to be converted once
*    and put in the data area.
:number      lda   LINEREF
             beq   :const
             lda   #$00
             sta   LINEREF
:skip        jsr   RDBYTE
             bcs   :eof
             sta   CH
             jsr   ISDIGIT
             bcc   :skip
             jmp   :redo

:const       lda   #$00
             sta   NUMLEN
             jsr   NUMPUT
:cloop       jsr   RDBYTE
             bcs   :eof
             sta   CH
             jsr   ISDIGIT
             bcc   :cput
             cmp   #'.'
             bne   :cend
:cput        jsr   NUMPUT
             jmp   :cloop
:cend        jsr   NUMCONV
             jsr   CONSTADD
*--- fall through

*--- The byte that ended the name or number has been read but not USED, and it
*    may be a token, a quote or the line's terminating zero. Put it back rather
*    than dropping it: dropping the zero ran two lines together.
:redo        lda   CH
             sta   PBACK
             lda   #$01
             sta   PBFLAG
             jmp   :next

*--- one character into NUMBUF, ignoring any past its length. A number long
*    enough to overflow it cannot be represented anyway.
NUMPUT       ldx   NUMLEN
             cpx   #NUMMAX
             bcs   :full
             lda   CH
             sta   NUMBUF,x
             inc   NUMLEN
:full        rts

*--------------------------------------
* ISALNUM / ISDIGIT -- carry clear if CH is one
*--------------------------------------
*--- Local labels belong to the global one above them, so the two routines
*    cannot share a yes and a no: Merlin looks for ISDIGIT's :yes and finds
*    ISALNUM's, which is a different label with the same name.
ISALNUM      lda   CH
             cmp   #'A'
             bcc   ISDIGIT
             cmp   #'Z'+1
             bcc   ALNYES
             bcs   ISDIGIT          ; a digit after a letter is still part of
                                    ; the name, so both ranges are tried
ALNYES       clc
             rts
ISDIGIT      lda   CH
             cmp   #'0'
             bcc   ALNNO
             cmp   #'9'+1
             bcs   ALNNO
             clc
             rts
ALNNO        sec
             rts

*--------------------------------------
* NUMCONV -- NUMBUF, NUMLEN characters of it, into five packed bytes at TMPF
*
* value = 0; for each digit: value = value * 10 + digit; then divide by ten
* once per place after the point. The arithmetic is the ROM's own, so a
* compiled constant is bit for bit what Applesoft would have produced from the
* same text -- which is the point of doing it this way rather than with
* integer arithmetic and a table of powers.
*
* The ROM has a routine that reads a number out of program text, and it is not
* used: it works through the interpreter's own text pointer and would be one
* more thing to establish on the machine for no gain.
*--------------------------------------
NUMCONV      lda   #$00
             sta   NUMDP
             sta   NUMDOT
             sta   NUMI
             lda   #<CZERO
             ldy   #>CZERO
             jsr   MOVFM            ; FAC = 0

:loop        lda   NUMI
             cmp   NUMLEN
             bcs   :frac
             tax
             lda   NUMBUF,x
             cmp   #'.'
             bne   :dig
             lda   #$01
             sta   NUMDOT
             jmp   :step
:dig         sec
             sbc   #'0'
             sta   NUMD
             lda   NUMDOT
             beq   :nodp
             inc   NUMDP
:nodp        lda   #<CTEN
             ldy   #>CTEN
             jsr   FMUL             ; FAC = FAC * 10

             lda   NUMD             ; five bytes to a constant
             sta   TMPA
             asl
             asl
             clc
             adc   TMPA
             clc
             adc   #<CDIGS
             sta   TMPP
             lda   #>CDIGS
             adc   #$00
             tay
             lda   TMPP
             jsr   FADD             ; FAC = FAC + the digit
:step        inc   NUMI
             jmp   :loop

*--- One division per decimal place. FDIV is memory over FAC, so the value has
*    to be the MEMORY operand and ten the accumulator -- the other way round
*    computes ten divided by the number, which for 2.5 would give 4 and look
*    like a plausible answer.
:frac        lda   NUMDP
             beq   :done
:fl          ldx   #<FTEMP
             ldy   #>FTEMP
             jsr   MOVMF
             lda   #<CTEN
             ldy   #>CTEN
             jsr   MOVFM
             lda   #<FTEMP
             ldy   #>FTEMP
             jsr   FDIV
             dec   NUMDP
             bne   :fl

:done        ldx   #<TMPF
             ldy   #>TMPF
             jsr   MOVMF
             rts

*--- Produced by src/cc/fp.py, which asserts itself against the three values
*    read out of a running machine's variable table.
CZERO        dfb   $00,$00,$00,$00,$00
CTEN         dfb   $84,$20,$00,$00,$00
CDIGS        dfb   $00,$00,$00,$00,$00
             dfb   $81,$00,$00,$00,$00
             dfb   $82,$00,$00,$00,$00
             dfb   $82,$40,$00,$00,$00
             dfb   $83,$00,$00,$00,$00
             dfb   $83,$20,$00,$00,$00
             dfb   $83,$40,$00,$00,$00
             dfb   $83,$60,$00,$00,$00
             dfb   $84,$00,$00,$00,$00
             dfb   $84,$10,$00,$00,$00

*--------------------------------------
* The three tables
*--------------------------------------
LTADD        lda   NLINES+1
             cmp   #>LTMAX
             bcc   :room
             lda   NLINES
             cmp   #<LTMAX
             bcc   :room
             lda   #$02             ; too many lines
             sta   BADFLG
             rts
:room        jsr   LTSLOT
             ldy   #$00
             lda   WORD
             sta   (TMPP),y
             iny
             lda   WORD+1
             sta   (TMPP),y
             iny
             lda   #$00             ; the address, filled in by pass 2
             sta   (TMPP),y
             iny
             sta   (TMPP),y
             inc   NLINES
             bne   :ok
             inc   NLINES+1
:ok          rts

*--- TMPP <- LTAB + 4 * NLINES
LTSLOT       lda   NLINES
             asl
             sta   TMPP
             lda   NLINES+1
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
* VARADD -- VN0/VN1 into the variable table, if it is not already there
*--------------------------------------
VARADD       lda   #$00
             sta   TMPA
:find        lda   TMPA
             cmp   NVARS
             bcs   :new
             asl
             tax
             lda   VTAB,x
             cmp   VN0
             bne   :step
             lda   VTAB+1,x
             cmp   VN1
             beq   :done            ; already known
:step        inc   TMPA
             jmp   :find

:new         lda   NVARS
             cmp   #VMAX
             bcc   :room
             lda   #$03             ; too many variables
             sta   BADFLG
             rts
:room        asl
             tax
             lda   VN0
             sta   VTAB,x
             lda   VN1
             sta   VTAB+1,x
             inc   NVARS
:done        rts

*--------------------------------------
* CONSTADD -- the five bytes at TMPF into the constant table, if new
*
* Deduplicated BY VALUE rather than by the text that produced it, so 1, 1.0
* and 01 are one constant. Comparing the packed bytes is what makes that true
* without any thought about what the text looked like.
*--------------------------------------
CONSTADD     lda   #$00
             sta   TMPA
:find        lda   TMPA
             cmp   NCONST
             bcs   :new
             jsr   CSLOT
             ldy   #$04
:cmp         lda   (TMPP),y
             cmp   TMPF,y
             bne   :step
             dey
             bpl   :cmp
             rts                    ; already known
:step        inc   TMPA
             jmp   :find

:new         lda   NCONST
             cmp   #CMAX
             bcc   :room
             lda   #$04             ; too many constants
             sta   BADFLG
             rts
:room        jsr   CSLOT
             ldy   #$04
:put         lda   TMPF,y
             sta   (TMPP),y
             dey
             bpl   :put
             inc   NCONST
             rts

*--- TMPP <- CTAB + 5 * TMPA
CSLOT        lda   TMPA
             sta   TMPB
             asl
             asl
             clc
             adc   TMPB
             sta   TMPP
             lda   #$00
             adc   #$00
             sta   TMPP+1
             lda   TMPP
             clc
             adc   #<CTAB
             sta   TMPP
             lda   TMPP+1
             adc   #>CTAB
             sta   TMPP+1
             rts

*--------------------------------------
* REPORT -- what pass 1 found, and where it decided to put it
*--------------------------------------
REPORT       lda   #<MSGVARS
             ldy   #>MSGVARS
             jsr   PRSTR
             lda   NVARS
             sta   WORD
             lda   #$00
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR

             lda   #$00
             sta   TMPA
:var         lda   TMPA
             cmp   NVARS
             bcs   :consts
             asl
             tax
             lda   VTAB,x
             ora   #$80
             jsr   PRCH
             lda   VTAB+1,x
             beq   :sp
             ora   #$80
             jsr   PRCH
             jmp   :addr
:sp          lda   #$a0
             jsr   PRCH
:addr        lda   #$a0
             jsr   PRCH
             jsr   VADDR
             lda   TMPP+1
             jsr   PRHEX
             lda   TMPP
             jsr   PRHEX
             jsr   PRCR
             inc   TMPA
             jmp   :var

*--- The constants, printed back through the ROM's own FOUT. If the digit
*    conversion were wrong this is where it would say so, in the clearest
*    possible way: the number would come out different from the one in the
*    program.
:consts      lda   #<MSGCONST
             ldy   #>MSGCONST
             jsr   PRSTR
             lda   NCONST
             sta   WORD
             lda   #$00
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR

             lda   #$00
             sta   TMPA
:con         lda   TMPA
             cmp   NCONST
             bcs   :bad
             jsr   CSLOT
             lda   TMPP
             ldy   TMPP+1
             jsr   MOVFM
             jsr   PRFAC
             jsr   PRCR
             inc   TMPA
             jmp   :con

:bad         lda   BADFLG
             beq   :ok
             sta   WORD
             lda   #$00
             sta   WORD+1
             lda   #<MSGBAD
             ldy   #>MSGBAD
             jsr   PRSTR
             jsr   PRWORD
             jsr   PRCR
:ok          rts

*--- TMPP <- the address of variable TMPA in the compiled program
VADDR        lda   TMPA
             sta   TMPB
             asl
             asl
             clc
             adc   TMPB
             sta   TMPP
             lda   #$00
             adc   #$00
             sta   TMPP+1
             lda   TMPP
             clc
             adc   VARBASE
             sta   TMPP
             lda   TMPP+1
             adc   VARBASE+1
             sta   TMPP+1
             rts

*--- CONSTBASE <- VARBASE + 5 * NVARS
CONSTBS      lda   NVARS
             sta   TMPB
             asl
             asl
             clc
             adc   TMPB
             sta   CONSTBASE
             lda   #$00
             adc   #$00
             sta   CONSTBASE+1
             lda   CONSTBASE
             clc
             adc   VARBASE
             sta   CONSTBASE
             lda   CONSTBASE+1
             adc   VARBASE+1
             sta   CONSTBASE+1
             rts

*--------------------------------------
* PRFAC -- the accumulator as a decimal number, the way Applesoft would
*
* FOUT leaves a zero-terminated string at $0100 with its high bits clear.
*--------------------------------------
PRFAC        jsr   FOUT
             ldx   #$00
:loop        lda   $0100,x
             beq   :done
             stx   XSAVE
             ora   #$80
             jsr   COUT
             ldx   XSAVE
             inx
             bne   :loop
:done        rts

PRCH         sty   YSAVE
             stx   XSAVE
             jsr   COUT
             ldx   XSAVE
             ldy   YSAVE
             rts

PRCR         lda   #$8d
             jmp   PRCH

MSGVARS      asc   "VARIABLES: "
             dfb   $00
MSGCONST     asc   "CONSTANTS: "
             dfb   $00
MSGBAD       asc   "UNSUPPORTED, CODE "
             dfb   $00

NUMMAX       equ   24
VMAX         equ   128
CMAX         equ   128
LTMAX        equ   512

             dum   $1440
CH           ds    1                ; the byte being looked at
INSTR        ds    1                ; inside a string literal
LINEREF      ds    1                ; the next number is a branch target
VN0          ds    1                ; the two significant characters of a name
VN1          ds    1
NCH          ds    1                ; characters of it seen so far
NUMBUF       ds    NUMMAX
NUMLEN       ds    1
NUMI         ds    1
NUMD         ds    1
NUMDP        ds    1                ; places after the point
NUMDOT       ds    1
TMPF         ds    5                ; a packed float being built
FTEMP        ds    5                ; and one the ROM divides
TMPB         ds    2                ; LNMUL10 needs both bytes
PBACK        ds    1                ; a byte read and not used
PBFLAG       ds    1
XSAVE        ds    1
NVARS        ds    1
NCONST       ds    1
NLINES       ds    2
BADFLG       ds    1
VARBASE      ds    2                ; where the compiled program keeps them
CONSTBASE    ds    2
             dend

*--- The tables, well clear of the compiler, its buffers and ProDOS.
             dum   $8000
VTAB         ds    VMAX*2
CTAB         ds    CMAX*5
LTAB         ds    LTMAX*4
             dend
