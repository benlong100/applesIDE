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
DBUFP        equ   $1c              ; 2 more, for reaching into the DATA buffer
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

             lda   #$00
             sta   ISINT
             jsr   ASKNAME
             jsr   OPENSRC
             bcc   :ok

*--- ONE MESSAGE, NOT TWO. An Integer BASIC file was reported as itself and
*    then as a file that would not open, with an error code of 01 that meant
*    nothing -- three lines, two of them wrong, for one plain fact.
             lda   ISINT
             beq   :cantopen
             lda   #<MSGINT
             ldy   #>MSGINT
             jsr   PRSTR
             jmp   FINISH
:cantopen    lda   #<MSGNOFILE
             ldy   #>MSGNOFILE
             jsr   PRSTR
             lda   MLIERR           ; say WHICH failure: $40 and $46 send the
             jsr   PRHEX            ; reader to different places entirely
             lda   #$8d
             jsr   COUT
             jmp   FINISH
:ok

             jsr   PASS1
             jsr   PICKORG          ; after pass 1 has seen every token, and
             jsr   LAYOUT           ; before LAYOUT fixes a single address

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
             beq   :go
             jmp   :stop            ; :stop is past the whole driver now
:go
*--- Pass 2 sizes the code and records where every line begins; pass 3 writes
*    it, resolving branches from what pass 2 left behind.
             lda   #$02
             sta   PASSNO
             jsr   GENPASS
             bcs   :stop

*--- WILL IT FIT? BASIC.SYSTEM's workspace starts a little under $9600 on a
*    //e with one file buffer open. Nothing checked, so a large enough program
*    compiled quietly into a binary that loaded over the top of the
*    interpreter that was loading it. Checked BEFORE the output file is
*    created, so a program too big does not also leave half of itself on the
*    disk.
*
*    THE CEILING IS FIXED; the floor is not, since PICKORG chooses it. How
*    much room a program gets is $9600 less wherever it was put.
             lda   FINPC+1
             cmp   #>ORGCEIL
             bcc   :fits
             lda   #<MSGBIG
             ldy   #>MSGBIG
             jsr   PRSTR
             lda   FINPC+1
             jsr   PRHEX
             lda   FINPC
             jsr   PRHEX
             jsr   PRCR
             jmp   :stop
:fits
             jsr   OPENOUT
             bcs   :noout
             lda   #$03
             sta   PASSNO
             jsr   GENPASS
             php
             jsr   CLOSEOUT
             plp
             bcs   :stop

             jsr   CLOSESRC

*--- WHAT PASS 1 SAW AND CANNOT DO ANYTHING ABOUT. A program that reads
*    TXTTAB or DATLIN is looking for its own source in memory, and a compiled
*    program has not got any: it will run, and quietly do nothing.
*
*    SAID HERE, NEXT TO THE RESULT, and not when pass 1 noticed. Printed
*    there it came out ahead of the line and variable and constant listings,
*    which are long enough to scroll it off the top of the screen -- so the
*    one thing worth reading was the one thing that had gone.
             jsr   SAYPEEKS
             lda   #<MSGWROTE
             ldy   #>MSGWROTE
             jsr   PRSTR
             lda   #<OUTNAME        ; the length byte first: PRLOW reads it
             ldy   #>OUTNAME
             jsr   PRLOW
             lda   #<MSGBYTES
             ldy   #>MSGBYTES
             jsr   PRSTR
             lda   FINPC            ; the size is where it stopped, less the
             sec                     ; address it was laid out from
             sbc   ORG
             sta   WORD
             lda   FINPC+1
             sbc   ORG+1
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

*--- EVERY BYTE OF THE SOURCE PASSES HERE, which is why the watch for a PEEK
*    of Applesoft's own pointers sits here and not in SCANBODY. There it saw
*    only the FIRST digit of a number: SCANBODY reads one byte, decides it has
*    a number, and its own scanner eats the rest without coming back. PEEK(103)
*    arrived as a 1 and matched nothing.
*
*    NOT ON THE PUSHED-BACK PATH above -- a byte read twice would be counted
*    twice, and 103 would come out as 1033. And the clc below is what keeps
*    RDBYTE's promise about the carry, which NOTEPK's own compares destroy.
             jsr   NOTEPK
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
*--------------------------------------
* WHAT KIND OF FILE IS IT? ProDOS knows, and asking is cheaper than finding
* out the hard way. BIORHYTHM on the distribution disk is INTEGER BASIC: a
* different language in a different format, lines held as a length and a
* number where Applesoft holds a link and a number. Read as Applesoft its
* first line is numbered 25600, and the compiler reported a fault in a line
* the program has not got -- DEF FN HEADER, at line 27825.
*
* Only $FA is refused. A file typed anything else might still be a tokenised
* Applesoft program -- plenty are BIN, or TXT, or have no type worth the name
* -- and refusing those would turn a working compile into an error.
*--------------------------------------
OPENSRC      jsr   MLI
             dfb   $c4              ; GET_FILE_INFO
             da    INFOPARM
             bcs   :notint          ; it will fail again below, and say so
             lda   INFOPARM+4       ; the file type
             cmp   #$fa             ; INT
             bne   :notint
             lda   #$01
             sta   ISINT            ; the caller picks the message
             sec
             rts
:notint
             jsr   MLI
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
*--------------------------------------
* BADSAY -- what went wrong, where, in words
*
* ALWAYS SAYS SOMETHING. A stop with no code set once printed nothing at all,
* which said only that generation had not happened and not one word about
* where.
*
* AND IN WORDS, WITH A LINE NUMBER. It used to print a stage letter and a
* number -- STOPPED AT 2 5 -- which was enough for me and useless to anybody
* else, including me a fortnight later. The line is what you need to find it;
* the words are what tell you whether it is your mistake or a thing the
* compiler cannot do yet.
*--------------------------------------
*--------------------------------------
* SAYPEEKS -- name the lines that read Applesoft's own pointers
*--------------------------------------
SAYPEEKS     lda   PKTXT
             beq   :dat
             lda   #<MSGPKTXT
             ldy   #>MSGPKTXT
             jsr   PRSTR
             lda   PKTLINE
             sta   WORD
             lda   PKTLINE+1
             sta   WORD+1
             jsr   PRWORD
             lda   #<MSGPKTXT2
             ldy   #>MSGPKTXT2
             jsr   PRSTR
:dat         lda   PKDAT
             beq   :done
             lda   #<MSGPKTXT
             ldy   #>MSGPKTXT
             jsr   PRSTR
             lda   PKDLINE
             sta   WORD
             lda   PKDLINE+1
             sta   WORD+1
             jsr   PRWORD
             lda   #<MSGPKDAT2
             ldy   #>MSGPKDAT2
             jsr   PRSTR
:done        lda   PKTXT
             ora   PKDAT
             beq   :out
             lda   #<MSGPKBOTH
             ldy   #>MSGPKBOTH
             jsr   PRSTR
:out         rts

*--------------------------------------
BADSAY       lda   BADFLG
             beq   :none

             lda   #<MSGSTOP
             ldy   #>MSGSTOP
             jsr   PRSTR
             lda   BADLINE
             sta   WORD
             lda   BADLINE+1
             sta   WORD+1
             jsr   PRWORD
             lda   #<MSGCOLON
             ldy   #>MSGCOLON
             jsr   PRSTR

*--- the message for this code, from the table
             lda   BADFLG
             cmp   #NMSG+1
             bcs   :plain
             sec
             sbc   #$01
             asl
             tax
             lda   MSGTAB,x
             ldy   MSGTAB+1,x
             jsr   PRSTR

*--- AND THE NUMBER. The words are for the person reading; the number says
*    which of several places that share a wording actually stopped, which the
*    words cannot.
             lda   #$a0
             jsr   COUT
             lda   #$a3
             jsr   COUT
             lda   BADFLG
             jsr   PRHEX
             jsr   PRCR
             jmp   FINISH

*--- a code with no message: say the number rather than nothing
:plain       lda   #<MSGCODE
             ldy   #>MSGCODE
             jsr   PRSTR
             lda   BADFLG
             sta   WORD
             lda   #$00
             sta   WORD+1
             jsr   PRWORD
             jsr   PRCR
:none        jmp   FINISH

*--- Indexed by the code, which is why the order matters and why each one is
*    written next to the place that raises it in the source.
MSGTAB       da    BADSUF           ; 1
             da    BADLINES         ; 2
             da    BADVARS          ; 3
             da    BADCONS          ; 4
             da    BADSTMT          ; 5
             da    BADLET           ; 6
             da    BADTGT           ; 7
             da    BADTHEN          ; 8
             da    BADCOMMA         ; 9
             da    BADQUOTE         ; 10
             da    BADLONG          ; 11
             da    BADTERM          ; 12
             da    BADNAME          ; 13
             da    BADDEEP          ; 14
             da    BADCMP           ; 15
             da    BADFDEEP         ; 16
             da    BADFOR           ; 17
             da    BADNEXT          ; 18
             da    BADWHICH         ; 19
             da    BADEXP           ; 20
             da    BADDIM           ; 21
             da    BADARRS          ; 22
             da    BADONGS          ; 23
             da    BADONN           ; 24
             da    BADSARR          ; 25
             da    BADNSTR          ; 26
             da    BADJOIN          ; 27
             da    BADMIX           ; 28
             da    BADDATA          ; 29
             da    BADDEF           ; 30
             da    BADNFN           ; 31
             da    BADNOFN          ; 32
             da    BADFNARG         ; 33
             da    BADDEFH          ; 34
             da    BADDEFB          ; 35
             da    BADSDESC         ; 36
             da    BADGET           ; 37
             da    BADPRIM          ; 38
             da    BADSUBS          ; 39
             da    BADFARG          ; 40
             da    BADIARR          ; 41
             da    BADDIMV          ; 42
NMSG         equ   42

BADSUF       asc   "NO STRINGS OR ARRAYS"
             dfb   $00
BADLINES     asc   "TOO MANY LINES"
             dfb   $00
BADVARS      asc   "TOO MANY VARIABLES"
             dfb   $00
BADCONS      asc   "TOO MANY CONSTANTS"
             dfb   $00
BADSTMT      asc   "STATEMENT NOT YET"
             dfb   $00
BADLET       asc   "BAD ASSIGNMENT"
             dfb   $00
BADTGT       asc   "NO SUCH LINE"
             dfb   $00
BADTHEN      asc   "IF WITHOUT THEN"
             dfb   $00
BADCOMMA     asc   "NO COMMA IN PRINT YET"
             dfb   $00
BADQUOTE     asc   "STRING NOT CLOSED"
             dfb   $00
BADLONG      asc   "STRING TOO LONG"
             dfb   $00
BADTERM      asc   "CANNOT READ THAT"
             dfb   $00
BADNAME      asc   "UNKNOWN VARIABLE"
             dfb   $00
BADDEEP      asc   "EXPRESSION TOO DEEP"
             dfb   $00
BADCMP       asc   "BAD COMPARISON"
             dfb   $00
BADFDEEP     asc   "FOR NESTED TOO DEEP"
             dfb   $00
BADFOR       asc   "BAD FOR"
             dfb   $00
BADNEXT      asc   "NEXT WITHOUT FOR"
             dfb   $00
BADWHICH     asc   "NEXT: WRONG FOR"
             dfb   $00
BADEXP       asc   "EXPONENT TOO BIG"
             dfb   $00
BADDIM       asc   "ONE DIMENSION ONLY"
             dfb   $00
BADARRS      asc   "TOO MANY ARRAYS"
             dfb   $00
BADONGS      asc   "ON NEEDS GOTO OR GOSUB"
             dfb   $00
BADONN       asc   "TOO MANY IN ON GOTO"
             dfb   $00
BADSARR      asc   "NO STRING ARRAYS YET"
             dfb   $00
BADNSTR      asc   "TOO MANY STRINGS"
             dfb   $00
BADJOIN      asc   "NO STRING JOIN YET"
             dfb   $00
BADMIX       asc   "STRING AGAINST NUMBER"
             dfb   $00
BADDATA      asc   "TOO MUCH DATA"
             dfb   $00
BADDEF       asc   "DEF FN NOT LIKE THAT"
             dfb   $00
BADNFN       asc   "TOO MANY FUNCTIONS"
             dfb   $00
BADNOFN      asc   "NO SUCH FUNCTION"
             dfb   $00
BADFNARG     asc   "FN WANTS ONE NUMBER IN BRACKETS"
             dfb   $00
BADDEFH      asc   "DEF FN HEADER"
             dfb   $00
BADDEFB      asc   "DEF FN BODY"
             dfb   $00
BADSDESC     asc   "TOO MANY STRINGS AT ONCE"
             dfb   $00
BADGET       asc   "GET WANTS A STRING"
             dfb   $00
BADPRIM      asc   "CANNOT READ THAT"
             dfb   $00
BADSUBS      asc   "BAD SUBSCRIPT"
             dfb   $00
BADFARG      asc   "BAD FUNCTION ARGUMENT"
             dfb   $00
BADIARR      asc   "NO INTEGER ARRAYS YET"
             dfb   $00
BADDIMV      asc   "DIM SIZE MUST BE A NUMBER"
             dfb   $00

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

*--- THE LOAD ADDRESS GOES IN HERE, not into an assembled constant. It is
*    chosen per program now, so the aux_type CREATE stamps on the file -- the
*    address BRUN restores it to -- has to be the one this program was laid
*    out from, or it loads somewhere its own JMPs do not point.
             lda   ORG
             sta   CREPARM+5
             lda   ORG+1
             sta   CREPARM+6

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
INFOPARM     dfb   $0a              ; GET_FILE_INFO
             da    SRCNAME
             ds    16               ; access, type, aux, storage, blocks, dates
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
             da    $0000            ; filled in by OPENOUT: see there
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
MSGINT       asc   "THAT IS INTEGER BASIC, NOT APPLESOFT"
             dfb   $8d,$00
MSGBIG       asc   "TOO BIG: IT WOULD REACH $"
             dfb   $00
MSGWROTE     asc   "WROTE "
             dfb   $00
MSGBYTES     asc   ", "
             dfb   $00
MSGNOOUT     asc   "CANNOT WRITE THE OUTPUT, CODE "
             dfb   $00
MSGSTOP      asc   "STOPPED IN "
             dfb   $00
*--- Kept inside forty columns. The first wording ran over and broke a word
*    across the wrap -- "THE PROGRAM PO/INTER" -- and the screen swallowed the
*    indent on the line after it.
MSGPKTXT     asc   "NOTE: LINE "
             dfb   $00
MSGPKTXT2    asc   " READS 103, PROGRAM TEXT"
             dfb   $8d,$00
MSGPKDAT2    asc   " READS 123, DATA LINE"
             dfb   $8d,$00
MSGPKBOTH    asc   "IT WANTS ITS OWN LISTING IN MEMORY,"
             dfb   $8d
             asc   "WHICH A COMPILED PROGRAM HAS NOT GOT"
             dfb   $8d,$00
MSGNOLOM     asc   "NOTE: LOMEM: ON LINE "
             dfb   $00
MSGNOLOM2    asc   " DOES NOTHING"
             dfb   $8d,$00
MSGNOSAVE    asc   "NOTE: SAVE ON LINE "
             dfb   $00
MSGNOSAVE2   asc   " DOES NOTHING"
             dfb   $8d,$00
MSGCOLON     asc   ": "
             dfb   $00
MSGCODE      asc   "CODE "
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
ISINT        ds    1                ; the source was an Integer BASIC file
TMPA         ds    1
LOWN         ds    1
OUTNAME      ds    17
             dend

*--- The stub at $300 reads these AFTER BASIC.SYSTEM has landed on top of
*    everything this program was assembled into, so they cannot live with it.
             dum   $1600
BREADPARM    ds    8
BCLOSPARM    ds    2
BQPARM       ds    7
             dend

*--- Two ProDOS buffers, a window into the source and one out to the output
*    file. They were at $1800, which stopped fitting the moment there were two
*    of them: $1E00 onwards is the compiler's own code.
*--- THE TWO BIG ONES BACK DOWN TO LOW MEMORY, and this time below the code
*    rather than into it. At $a800 they sat immediately above the tables,
*    which capped those at $9000-$A7FF -- and DBUF, which every DATA item in
*    the program is collected into, could be no bigger than 2K because of it.
*    PHONE.LIST has 6,004 bytes of DATA and stopped at line 250, TOO MUCH
*    DATA, having compiled everything else about it perfectly well.
*
*    $0800 and $0C00 are free. ProDOS's system bitmap protects pages $00-$07
*    and $BF, and everything between belongs to whoever is running -- which
*    here is a SYS program that owns the machine: BASIC.SYSTEM is NOT resident
*    while the compiler runs, which is why quitting has to load it again. The
*    variable blocks in this program start at $1400, so $1000-$13FF is spare.
             dum   $0800
IOBUF        ds    1024             ; ProDOS wants these page aligned
IOBUF2       ds    1024
             dend

*--- AND THE SMALL ONES BELOW THE CODE, not above the tables.
*
*    They were at $ba00, immediately over the tables, which capped those at
*    $9000-$B9FF -- and the constant table with them, at a hundred and twenty
*    eight entries. LEMONADE off the distribution disk needs two hundred and
*    fifty.
*
*    $1611-$1FFF is free: the variable blocks stop at $1610 and the compiler's
*    own code does not start until $2000. Nothing else is down there, and it
*    leaves $BA00-$BEFF for the tables to grow into.
*
*    OUTBUF still begins on a page boundary, which it needs.
             dum   $1700
DATBUF       ds    512              ; $1700
OUTBUF       ds    256              ; $1900 -- a whole page, so a string
PFXBUF       ds    64               ; literal's JMP is still reachable to patch
ONLBUF       ds    16
ONBUF        ds    80               ; an ON GOTO's targets, collected first
STRBUF       ds    256              ; a literal, collected before it is emitted
             dend                   ; ends $1B9F, clear of the code at $2000                   ; ends $BE9F, clear of ProDOS at $BF00
