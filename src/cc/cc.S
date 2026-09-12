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
COUT         equ   $FDED
HOME         equ   $FC58

*--- the tokenised format, established by reading files Applesoft wrote:
*    two bytes of next-line address, two of line number, the body, a zero.
*    A next-line address of zero ends the program.

START        jsr   HOME
             lda   #<MSGOPEN
             ldy   #>MSGOPEN
             jsr   PRSTR

*--- A PREFIX, IF NOBODY LEFT ONE. BASIC.SYSTEM leaves none behind when it
*    launches a SYS file, so every relative pathname fails with $40 -- invalid
*    pathname syntax, which looks exactly like a mistyped filename. The editor
*    and ZipEdit both had this; it is the third time.
             jsr   SETPFX

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

*--- walk the lines
:line        jsr   RDWORD           ; the next-line address
             bcs   :done
             lda   WORD
             ora   WORD+1
             beq   :done            ; zero: the program ends here

             jsr   RDWORD           ; the line number
             bcs   :done
             jsr   PRWORD
             lda   #$8d
             jsr   COUT
             inc   COUNT
             bne   :body
             inc   COUNT+1

*--- and step over the body, which ends at its zero
:body        jsr   RDBYTE
             bcs   :done
             cmp   #$00
             bne   :body
             jmp   :line

:done        jsr   CLOSESRC
             lda   #<MSGLINES
             ldy   #>MSGLINES
             jsr   PRSTR
             lda   COUNT
             sta   WORD
             lda   COUNT+1
             sta   WORD+1
             jsr   PRWORD
             lda   #$8d
             jsr   COUT

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
             jmp   QUIT

*--------------------------------------
* The source, read through a window rather than all at once.
*
* RDBYTE hands back the next byte of the file, refilling from disk when the
* window runs dry. Carry set at end of file.
*--------------------------------------
RDBYTE       lda   SRCLEFT
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
QUITPARM     dfb   $04
             dfb   $00
             da    $0000
             dfb   $00
             da    $0000

*--- the file to compile. Hard-coded for this increment; the editor will hand
*    it over the way Ctrl-R hands a name to BASIC.
SRCNAME      dfb   6
             asc   'BENCH1'

MSGOPEN      asc   "APPLESOFT COMPILER"
             dfb   $8d,$8d,$00
MSGNOFILE    asc   "CANNOT OPEN THE SOURCE"
             dfb   $8d,$00
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
             dend

             dum   $1800
IOBUF        ds    1024             ; ProDOS wants this page aligned
DATBUF       ds    512
PFXBUF       ds    64
ONLBUF       ds    16
             dend
