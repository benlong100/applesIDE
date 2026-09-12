*--------------------------------------
* CC.S -- the Applesoft compiler, as a ProDOS SYS file
*
* Runs on the //e. Reads a tokenised Applesoft file and writes a binary that
* calls the Applesoft ROM for arithmetic -- see docs/compiler.md for why that
* shape, and for the nine ROM entry points, every one of which was confirmed
* on a running machine rather than remembered.
*
* FILE TO FILE, STREAMING. The source is read a block at a time through a
* small window rather than loaded whole: the compiler, its input and its
* output would otherwise be competing for the same 48K and only toy programs
* would fit.
*
* THIS INCREMENT IS THE READER. It opens a source file, walks its lines, and
* prints the line numbers it found. Nothing is generated yet. The point is to
* be sure the walk is right before anything is built on top of it -- a
* compiler that misreads its input produces confident nonsense.
*--------------------------------------
             org   $2000
             typ   $ff              ; SYS
             dsk   ASIDECC.SYSTEM

MLI          equ   $BF00

*--- Indirect indexed addressing needs the pointer in the direct page, and a
*    dum block at $1400 is not it: Merlin assembles as far as the addressing
*    mode and then says so. $06 and $08 are where the editor keeps its own
*    pointers, and it runs under ProDOS the same way; $40-$4F belong to the
*    MLI and are not free.
SRCPTR       equ   $06              ; 2 bytes, into the window
STRPTR       equ   $08              ; 2 bytes, a message being printed
*--- A third pointer, and $0A was not free enough to be sure of: $06-$09 is
*    the documented spare, and beyond it the safe ground is $19-$1D, which
*    belongs to the hires routines this program never calls. Clear of the MLI
*    at $40-$4F, of COUT's screen pointers at $24-$29, and of the floating
*    point up at $93-$AA.
TMPP         equ   $1a              ; 2 bytes, a table entry being reached
COUT         equ   $FDED
HOME         equ   $FC58

*--- the tokenised format, established by reading files Applesoft wrote:
*    two bytes of next-line address, two of line number, the body, a zero.
*    A next-line address of zero ends the program.

START        lda   #$00
             sta   PBFLAG
             jsr   HOME
             lda   #<MSGOPEN
             ldy   #>MSGOPEN
             jsr   PRSTR

*--- A PREFIX, IF NOBODY LEFT ONE. BASIC.SYSTEM leaves none behind when it
*    launches a SYS file, so every relative pathname fails with $40 -- invalid
*    pathname syntax, which looks exactly like a mistyped filename. The editor
*    and ZipEdit both had this; it is the third time.
             jsr   SETPFX

             jsr   ASKNAME
             jsr   OPENSRC
             bcc   :ok
             lda   #<MSGNOFILE
             ldy   #>MSGNOFILE
             jsr   PRSTR
             lda   MLIERR           ; say WHICH failure: $40 and $46 send the
             jsr   PRHEX            ; reader to different places entirely
             lda   #$8d
             jsr   COUT
             jmp   FINISH
:ok

             jsr   PASS1
             jsr   LAYOUT

             lda   #<MSGLINES
             ldy   #>MSGLINES
             jsr   PRSTR
             lda   NLINES
             sta   WORD
             lda   NLINES+1
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR
             jsr   REPORT

*--- Nothing is generated from a program pass 1 already objected to. A
*    compiler that carried on would write a file that ran and gave a wrong
*    answer, which is the one outcome worse than refusing.
             lda   BADFLG
             bne   :stop

*--- Pass 2 sizes the code and records where every line begins; pass 3 writes
*    it, resolving branches from what pass 2 left behind.
             lda   #'2'
             sta   STAGE
             lda   #$02
             sta   PASSNO
             jsr   GENPASS
             bcs   :stop

             lda   #'O'
             sta   STAGE
             jsr   OPENOUT
             bcs   :noout
             lda   #'3'
             sta   STAGE
             lda   #$03
             sta   PASSNO
             jsr   GENPASS
             php
             jsr   CLOSEOUT
             plp
             bcs   :stop

             jsr   CLOSESRC
             lda   #<MSGWROTE
             ldy   #>MSGWROTE
             jsr   PRSTR
             lda   #<OUTNAME        ; the length byte first: PRLOW reads it
             ldy   #>OUTNAME
             jsr   PRLOW
             lda   #<MSGBYTES
             ldy   #>MSGBYTES
             jsr   PRSTR
             lda   ENDPC            ; the size is where it stopped, less $6000
             sec
             sbc   #<CODEORG
             sta   WORD
             lda   ENDPC+1
             sbc   #>CODEORG
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR
             jmp   FINISH

:noout       lda   #<MSGNOOUT
             ldy   #>MSGNOOUT
             jsr   PRSTR
             lda   MLIERR
             jsr   PRHEX
             jsr   PRCR
:stop        jsr   CLOSESRC
             jsr   BADSAY
*--- Wait before leaving. QUIT goes to the selector, which clears the screen,
*    so without this the compiler's own report is gone before it can be read.
*    EVERY exit comes through here, including the failures: an error path that
*    quits without pausing is indistinguishable from a program that never ran,
*    which cost an hour of looking in the wrong place.
FINISH       lda   #<MSGKEY
             ldy   #>MSGKEY
             jsr   PRSTR
*--- Throw away anything already waiting first. A key struck while the
*    compiler was working sits in the latch, satisfies this instantly, and the
*    report is gone before it can be read -- which is exactly what happened.
             sta   $c010
:key         lda   $c000
             bpl   :key
             sta   $c010
             jmp   TOBASIC

             put   pass1
             put   gen

*--------------------------------------
* The source, read through a window rather than all at once.
*
* RDBYTE hands back the next byte of the file, refilling from disk when the
* window runs dry. Carry set at end of file.
*--------------------------------------
RDBYTE       lda   PBFLAG
             beq   :fresh
             lda   #$00
             sta   PBFLAG
             lda   PBACK
             clc
             rts
:fresh       lda   SRCLEFT
             ora   SRCLEFT+1
             bne   :have
             jsr   REFILL
             bcs   :eof
:have        ldy   #$00
             lda   (SRCPTR),y
             pha
             inc   SRCPTR
             bne   :dec
             inc   SRCPTR+1
:dec         lda   SRCLEFT
             bne   :lo
             dec   SRCLEFT+1
:lo          dec   SRCLEFT
             pla
             clc
             rts
:eof         sec
             rts

REFILL       jsr   READF
             bcs   :none
             lda   READPARM+6       ; how much actually arrived
             sta   SRCLEFT
             lda   READPARM+7
             sta   SRCLEFT+1
             ora   SRCLEFT
             beq   :none            ; nothing left: end of file
             lda   #<DATBUF
             sta   SRCPTR
             lda   #>DATBUF
             sta   SRCPTR+1
             clc
             rts
:none        sec
             rts

*--- two bytes, low first, into WORD
RDWORD       jsr   RDBYTE
             bcs   :no
             sta   WORD
             jsr   RDBYTE
             bcs   :no
             sta   WORD+1
             clc
             rts
:no          sec
             rts

*--------------------------------------
* Output. Decimal, because a compiler that reports line numbers in hex is
* asking the writer to do arithmetic to find their own mistake.
*--------------------------------------
PRWORD       lda   #$00
             sta   LEADING
             ldx   #$00
:digit       lda   #$00
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
             adc   #$b0
             jsr   COUT
:next        inx
             cpx   #$05
             bcc   :digit
             rts

POWLO        dfb   $10,$e8,$64,$0a,$01
POWHI        dfb   $27,$03,$00,$00,$00

*--- a null-terminated high-ASCII string at A,Y
*--- COUT CLOBBERS Y, so the index cannot live there across the call. The
*    compiled output prints with its index in X and works; this printed one
*    character and wandered off, which looked from outside exactly like the
*    program never running at all. Same shape as INSCHR clobbering X in the
*    editor, which is written down in that project's notes and was walked into
*    anyway.
PRSTR        sta   STRPTR
             sty   STRPTR+1
             ldy   #$00
:loop        lda   (STRPTR),y
             beq   :done
             sty   YSAVE
             jsr   COUT
             ldy   YSAVE
             iny
             bne   :loop
:done        rts

*--------------------------------------
* ProDOS. STA preserves the carry, so callers can branch on it.
*--------------------------------------
OPENSRC      jsr   MLI
             dfb   $c8
             da    OPENPARM
             sta   MLIERR
             bcs   :out
             lda   OPENPARM+5
             sta   READPARM+1
             sta   CLOSEPARM+1
             lda   #$00
             sta   SRCLEFT
             sta   SRCLEFT+1
             sta   COUNT
             sta   COUNT+1
             clc
:out         rts

READF        jsr   MLI
             dfb   $ca
             da    READPARM
             sta   MLIERR
             rts

CLOSESRC     jsr   MLI
             dfb   $cc
             da    CLOSEPARM
             sta   MLIERR
             rts

*--------------------------------------
* BADSAY -- name the objection, if there was one
*--------------------------------------
*--- ALWAYS SAYS SOMETHING. A stop with no code set printed nothing at all,
*    which said only that generation had not happened and not one word about
*    where -- so the stage letter is reported whether there is a code or not.
BADSAY       lda   #<MSGSTOP
             ldy   #>MSGSTOP
             jsr   PRSTR
             lda   STAGE
             jsr   PRCH
             lda   #$a0
             jsr   PRCH
             lda   BADFLG
             sta   WORD
             lda   #$00
             sta   WORD+1
             lda   #$00
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR
             jmp   FINISH

*--------------------------------------
* A low-ASCII string, length byte first: a ProDOS filename as it is stored
*--------------------------------------
PRLOW        sta   STRPTR
             sty   STRPTR+1
             ldy   #$00
             lda   (STRPTR),y
             beq   :done
             sta   LOWN
:loop        iny
             lda   (STRPTR),y
             ora   #$80
             sty   YSAVE
             jsr   COUT
             ldy   YSAVE
             dec   LOWN
             bne   :loop
:done        rts

*--------------------------------------
* The output file. Its name is the source's with a C in front, which is what
* the hand-compiled model was called and is short enough to stay inside
* ProDOS's fifteen characters for any name that could be typed at the prompt.
*--------------------------------------
OPENOUT      lda   SRCNAME
             cmp   #$0f
             bcc   :fits
             lda   #$0e             ; room for the C
:fits        tay
             iny
             sty   OUTNAME
             lda   #'C'
             sta   OUTNAME+1
             ldy   #$00
:copy        lda   SRCNAME+1,y
             sta   OUTNAME+2,y
             iny
             cpy   OUTNAME
             bcc   :copy

             jsr   MLI
             dfb   $c1              ; DESTROY: a stale file of the same name
             da    DESTPARM         ; would otherwise be appended to
             jsr   MLI
             dfb   $c0              ; CREATE
             da    CREPARM
             sta   MLIERR
             bcs   :bad
             jsr   MLI
             dfb   $c8              ; OPEN
             da    OOPENPARM
             sta   MLIERR
             bcs   :bad
             lda   OOPENPARM+5
             sta   WRPARM+1
             sta   OCLOSPARM+1
             clc
             rts
:bad         sec
             rts

CLOSEOUT     jsr   MLI
             dfb   $cc
             da    OCLOSPARM
             rts

*--------------------------------------
* REWIND -- back to the start of the source for the next pass
*
* The window and the pushback byte have to go with it. Leaving either behind
* would start the pass one byte into the file, or with a character from the
* end of the previous one.
*--------------------------------------
REWIND       lda   #$00
             sta   SRCLEFT
             sta   SRCLEFT+1
             sta   PBFLAG
             lda   OPENPARM+5
             sta   MARKPARM+1
             jsr   MLI
             dfb   $ce              ; SET_MARK
             da    MARKPARM
             sta   MLIERR
             rts

*--------------------------------------
* ASKNAME -- which file to compile
*
* GETLN, in the monitor at $FD6A: it hands back the line at $0200 with its
* length in X and the high bits set, and brings backspace and Ctrl-X with it
* for nothing. ProDOS wants the name in LOW ascii, so the high bit comes off
* on the way into SRCNAME.
*
* An empty line keeps whatever SRCNAME already holds, which is BENCH1 -- the
* benchmark is what this is aimed at, so it is worth a bare Return.
*--------------------------------------
ASKNAME      lda   #<MSGSRC
             ldy   #>MSGSRC
             jsr   PRSTR
             lda   #$a0             ; GETLN echoes this as the prompt
             sta   $33
             jsr   $fd6a
             cpx   #$00
             beq   :keep
             cpx   #$10             ; a ProDOS name is fifteen at the most
             bcs   :keep
             stx   SRCNAME
             ldy   #$00
:copy        lda   $0200,y
             and   #$7f
             sta   SRCNAME+1,y
             iny
             dex
             bne   :copy
:keep        rts

*--------------------------------------
* SETPFX -- make sure there is a prefix, deriving one from the last device
* ProDOS touched if nobody left one behind.
*--------------------------------------
SETPFX       jsr   MLI
             dfb   $c7              ; GET_PREFIX
             da    GETPPARM
             bcs   :derive
             lda   PFXBUF
             bne   :done

:derive      lda   $bf30            ; DEVNUM: the device we came from
             sta   ONLPARM+1
             jsr   MLI
             dfb   $c5              ; ON_LINE
             da    ONLPARM
             bcs   :done
             lda   ONLBUF
             and   #$0f             ; the name length is the low nibble
             beq   :done
             sta   TMPA

             lda   #'/'             ; ProDOS pathnames are LOW ascii
             sta   PFXBUF+1
             ldy   #$00
:copy        cpy   TMPA
             beq   :tail
             lda   ONLBUF+1,y
             sta   PFXBUF+2,y
             iny
             bne   :copy
:tail        lda   #'/'
             sta   PFXBUF+2,y
             tya
             clc
             adc   #$02
             sta   PFXBUF
             jsr   MLI
             dfb   $c6              ; SET_PREFIX
             da    SETPPARM
:done        rts

*--- one byte as two hex digits
PRHEX        pha
             lsr
             lsr
             lsr
             lsr
             jsr   :dig
             pla
             and   #$0f
:dig         cmp   #$0a
             bcc   :num
             clc
             adc   #$37
             bne   :out
:num         clc
             adc   #$30
:out         ora   #$80
             jmp   COUT

*--------------------------------------
* TOBASIC -- leave into BASIC, where the thing just compiled can be run
*
* MLI QUIT lands at the dispatcher, which on 2.4 is a file picker, and from
* there BASIC.SYSTEM is another choice away. What you want after compiling is
* the ] prompt, so this loads BASIC.SYSTEM and enters it, exactly as the
* editor's OA-Q does, and falls back to the dispatcher on a disk without one.
*
* A SYS file loads at $2000 and is entered there -- which is where THIS
* program is running -- so the few instructions that do the reading are copied
* to $300 and run from there while $2000 is overwritten. Everything they touch
* lives at $15xx, below the read, because an absolute reference to a parameter
* block assembled next to the code would be read from an address BASIC.SYSTEM
* had just landed on.
*
* AND IT CHECKS ITS WORK: BASIC.SYSTEM's first act is to relocate thirty-five
* pages of itself, so a short read leaves it copying whatever is still lying
* at $2400 into high memory and then entering it. The editor's tester saw
* exactly that. So the read must not fail, must have delivered at least 8K --
* ProDOS stops at end of file without complaining -- and $2000 must hold the
* JMP every SYS file starts with.
*--------------------------------------
TOBASIC      jsr   MLI
             dfb   $c8              ; OPEN BASIC.SYSTEM
             da    BOPENPARM
             bcs   PLAINQUIT
             lda   BOPENPARM+5
             sta   BREADPARM+1

             lda   #$04             ; the READ block, where the read cannot
             sta   BREADPARM        ; reach it
             lda   #$00
             sta   BREADPARM+2
             sta   BREADPARM+4
             lda   #$20
             sta   BREADPARM+3
             lda   #$50
             sta   BREADPARM+5

*--- CLOSE EVERY FILE, not just this one: a ref_num of zero means all of them,
*    and it is what releases the ProDOS buffers and the pages they hold in the
*    system bitmap. Jumping to another SYS file with a buffer still allocated
*    leaves BASIC.SYSTEM relocating itself around memory ProDOS believes is
*    spoken for.
             lda   #$01
             sta   BCLOSPARM
             lda   #$00
             sta   BCLOSPARM+1

             lda   #$04
             sta   BQPARM
             ldx   #$05
             lda   #$00
:qz          sta   BQPARM+1,x
             dex
             bpl   :qz

             ldx   #LAUNEND-LAUNCH-1
:copy        lda   LAUNCH,x
             sta   $0300,x
             dex
             bpl   :copy
             jmp   $0300

PLAINQUIT    lda   #$01
             sta   CLOSEPARM
             lda   #$00
             sta   CLOSEPARM+1
             jsr   MLI
             dfb   $cc
             da    CLOSEPARM
             jmp   QUIT

*--- Copied to $300 and run there, because it is about to overwrite the code
*    it was assembled next to. Only branches inside, and absolute references
*    only to $BF00, $2000 and the blocks at $15xx.
LAUNCH       jsr   MLI
             dfb   $ca              ; READ
             da    BREADPARM
             bcs   :bad
             lda   BREADPARM+7      ; how much actually arrived, high byte
             cmp   #$20             ; under 8K is not a BASIC.SYSTEM
             bcc   :bad
             lda   $2000
             cmp   #$4c             ; JMP -- how a SYS file begins
             bne   :bad
             jsr   MLI
             dfb   $cc
             da    BCLOSPARM
             jmp   $2000
:bad         jsr   MLI
             dfb   $cc
             da    BCLOSPARM
             jsr   MLI
             dfb   $65
             da    BQPARM
             rts
LAUNEND

QUIT         jsr   MLI
             dfb   $65
             da    QUITPARM
             rts                    ; QUIT does not come back

*--------------------------------------
* Parameter blocks and buffers
*--------------------------------------
OPENPARM     dfb   $03
             da    SRCNAME
             da    IOBUF
             dfb   $00
READPARM     dfb   $04
             dfb   $00
             da    DATBUF
             da    $0200            ; a block at a time
             da    $0000
CLOSEPARM    dfb   $01
             dfb   $00
GETPPARM     dfb   $01
             da    PFXBUF
SETPPARM     dfb   $01
             da    PFXBUF
ONLPARM      dfb   $02
             dfb   $00
             da    ONLBUF
BOPENPARM    dfb   $03
             da    BASNAME
             da    IOBUF
             dfb   $00
BASNAME      dfb   12
             asc   'BASIC.SYSTEM'   ; single quotes: ProDOS wants LOW ascii
DESTPARM     dfb   $01
             da    OUTNAME
CREPARM      dfb   $07
             da    OUTNAME
             dfb   $c3              ; read, write, rename, destroy
             dfb   $06              ; BIN
             da    CODEORG          ; so BRUN puts it back where it belongs
             dfb   $01              ; a seedling, to start with
             da    $0000            ; ProDOS dates it itself
             da    $0000
OOPENPARM    dfb   $03
             da    OUTNAME
             da    IOBUF2
             dfb   $00
WRPARM       dfb   $04
             dfb   $00
             da    OUTBUF
             da    $0000
             da    $0000
OCLOSPARM    dfb   $01
             dfb   $00
MARKPARM     dfb   $02
             dfb   $00
             dfb   $00,$00,$00
QUITPARM     dfb   $04
             dfb   $00
             da    $0000
             dfb   $00
             da    $0000

*--- the file to compile. Hard-coded for this increment; the editor will hand
*    it over the way Ctrl-R hands a name to BASIC.
SRCNAME      dfb   6
             asc   'BENCH1'
             ds    9                ; ASKNAME writes up to fifteen here

MSGOPEN      asc   "APPLESOFT COMPILER"
             dfb   $8d,$8d,$00
MSGNOFILE    asc   "CANNOT OPEN THE SOURCE"
             dfb   $8d,$00
MSGWROTE     asc   "WROTE "
             dfb   $00
MSGBYTES     asc   ", "
             dfb   $00
MSGNOOUT     asc   "CANNOT WRITE THE OUTPUT, CODE "
             dfb   $00
MSGSTOP      asc   "STOPPED AT "
             dfb   $00
MSGSRC       asc   "COMPILE WHICH FILE? "
             dfb   $00
MSGKEY       asc   "PRESS A KEY"
             dfb   $8d,$00
MSGLINES     asc   "LINES: "
             dfb   $00

             dum   $1400
WORD         ds    2
SRCLEFT      ds    2                ; bytes still in it
COUNT        ds    2                ; lines seen
DIGIT        ds    1
LEADING      ds    1
YSAVE        ds    1                ; Y across COUT, which does not keep it
MLIERR       ds    1
TMPA         ds    1
LOWN         ds    1
STAGE        ds    1
OUTNAME      ds    17
             dend

*--- The stub at $300 reads these AFTER BASIC.SYSTEM has landed on top of
*    everything this program was assembled into, so they cannot live with it.
             dum   $1500
BREADPARM    ds    8
BCLOSPARM    ds    2
BQPARM       ds    7
             dend

*--- Two ProDOS buffers, a window into the source and one out to the output
*    file. They were at $1800, which stopped fitting the moment there were two
*    of them: $1E00 onwards is the compiler's own code.
             dum   $9000
IOBUF        ds    1024             ; ProDOS wants these page aligned
IOBUF2       ds    1024
DATBUF       ds    512
OUTBUF       ds    256              ; a whole page, so a string literal's JMP
PFXBUF       ds    64               ; is still reachable to patch
ONLBUF       ds    16
             dend
