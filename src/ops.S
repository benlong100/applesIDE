*--------------------------------------
* OPS.S -- editing commands this editor needs and ZipEdit's did not
*--------------------------------------

*--------------------------------------
* KQUERY -- "?" expands to PRINT
*
* Applesoft accepts ? as a shorthand for PRINT and stores it as the PRINT
* token, so LIST prints it back as PRINT. Typing ? and getting PRINT is
* therefore not a convenience the editor invented: it is what the machine is
* going to do anyway, done early enough to see.
*
* NOT INSIDE A STRING, and not after a REM. PRINT "?" has to keep its question
* mark, and so does a comment -- Applesoft would not expand either, and an
* editor that did would silently change the program. HNFIND already walks the
* line tracking exactly those two things for the hint row, so this asks it.
*--------------------------------------
KQUERY       jsr   DELSEL           ; typing replaces the selection
             jsr   HNFIND           ; carry set = no keyword on the line
             bcs   :maybe
             lda   HNW
             cmp   #TKREMI
             beq   :literal         ; after REM: it is a comment
:maybe       lda   HNSTR
             bne   :literal         ; inside a string: it is text

             lda   #<KWPRINT
             sta   STRPTR
             lda   #>KWPRINT
             sta   STRPTR+1
             jsr   INSSTR
             jmp   FASTOK           ; one row changed, like ordinary typing

:literal     lda   #'?'+$80
             jsr   INSCHR
             jmp   FASTOK

KWPRINT      asc   "PRINT"
             dfb   $00

*--------------------------------------
* KDELEOL -- delete from the cursor to the end of the line (Ctrl-Y)
*
* DELFWD takes the character after the cursor without moving it, so this is a
* plain loop that stops at the first break. The line count cannot change --
* the break itself is never eaten -- but the row's contents do, so it does not
* opt into the one-row redraw and takes the full one.
*--------------------------------------
KDELEOL      jsr   ATEND
             bcs   :done
             lda   GAPEND
             sta   AUXPTR
             lda   GAPEND+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO
             bcc   :done            ; a break: the line ends here
             jsr   DELFWD
             jmp   KDELEOL
:done        rts

*--------------------------------------
* KQUIT -- leave, into BASIC where there is one
*
* MLI QUIT lands at the ProDOS dispatcher, which on 2.4 is Bitsy Bye: a file
* picker, from which you then choose BASIC.SYSTEM. That is two steps to reach
* the thing you almost always want, which is the ] prompt with your program
* sitting next to you ready to RUN.
*
* So this loads BASIC.SYSTEM itself and jumps to it, and falls back to the
* dispatcher when the disk has not got one -- the plain build image, for
* instance. A SYS file loads at $2000 and is entered there, which is where
* THIS program is running, so the few instructions that do the reading are
* copied to $300 first and run from there while $2000 is overwritten.
*--------------------------------------
KQUIT        lda   #$00             ; OA-Q leaves; it does not run anything
             sta   RUNNAME
             jsr   ASKUNSAVED
             bcs   :go
             rts                    ; carry clear: stay put
:go
*--------------------------------------
* RUNGO -- load BASIC.SYSTEM and enter it. RUNFLAG says whether the document
* is named to it on the way -- see the stub.
*--------------------------------------
RUNGO        ldx   #BASNEND-BASNAME-1
:name        lda   BASNAME,x        ; FNAME is the document; we are leaving
             sta   FNAME,x
             dex
             bpl   :name

             jsr   OPENF
             bcs   PLAINQUIT        ; no BASIC.SYSTEM here
             lda   OPENPARM+5
             sta   READPARM+1
             sta   CLOSEPARM+1

*--- $2000 up to just below ProDOS. READ hands back what is actually there.
             lda   #$00
             sta   READPARM+2
             lda   #$20
             sta   READPARM+3
             lda   #$00
             sta   READPARM+4
             lda   #$70
             sta   READPARM+5

*--- Put the screen back the way it was found. DISPINIT turned on 80-column
*    video, 80STORE and the alternate character set; BASIC.SYSTEM assumes
*    none of them and does not undo them, so its banner came up interleaved
*    with the editor's last screen -- "P R O D O S   B A S I C", every other
*    cell still holding the aux half.
             sta   CLR80VID
             sta   CLR80STORE
             sta   CLRALTCHAR
             sta   MAINWR
             sta   TXTSET
             sta   MIXCLR
             jsr   $fc58            ; HOME, in the monitor

*--- CLOSE EVERY FILE, not just this one. A ref_num of zero means all of them,
*    and it is what releases the ProDOS I/O buffers and the pages they hold in
*    the system bitmap. Jumping to another SYS file with a buffer still
*    allocated leaves BASIC.SYSTEM to relocate itself around memory ProDOS
*    still believes is spoken for -- which is a plausible way to arrive in the
*    monitor, and to lose the SmartPort volumes ProDOS had listed. Reported
*    from a //c with volumes on slots 1 and 2, intermittently, which is the
*    shape of a thing that depends on whether a file happened to be open.
             lda   #$00
             sta   CLOSEPARM+1

*--- The QUIT block the stub falls back on. QUITPARM itself is assembled into
*    the code at $2000 and will not survive the read, so a copy goes somewhere
*    that will.
             lda   #$04
             sta   QPARM
             ldx   #$05
             lda   #$00
:qz          sta   QPARM+1,x
             dex
             bpl   :qz

             ldx   #LAUNEND-LAUNCH-1
:copy        lda   LAUNCH,x
             sta   $0300,x
             dex
             bpl   :copy
             jmp   $0300

PLAINQUIT    lda   #$00             ; close every file here too: the dispatcher
             sta   CLOSEPARM+1      ; inherits whatever we leave allocated
             jsr   CLOSEF
             jsr   MLI
             dfb   $65
             da    QUITPARM
             rts                    ; the MLI quit does not come back

QUITPARM     dfb   $04
             dfb   $00
             da    $0000
             dfb   $00
             da    $0000

BASNAME      dfb   12
             asc   'BASIC.SYSTEM'   ; single quotes: ProDOS wants LOW ascii
BASNEND

*--- Copied to $300 and run there, because it is about to overwrite the code
*    it was assembled next to.
*
*    IT CHECKS ITS WORK BEFORE JUMPING. BASIC.SYSTEM's first act is to copy
*    thirty-five pages from $2400 to $9A00 -- it relocates its own bulk -- so a
*    read that fell short leaves it copying whatever of the editor is still
*    lying at $2400 into high memory and then entering it. A tester saw exactly
*    that: a break at $2022, which is inside BASIC.SYSTEM's own zero padding,
*    with A=$00 and X=$FF -- the X this stub's copy loop leaves behind.
*
*    So: the read must not report an error, it must have delivered at least 8K
*    -- ProDOS stops at EOF without complaining, so a short read is silent --
*    and the first byte must be the JMP
*    every SYS file starts with. Failing either, quit to the dispatcher, which
*    is where OA-Q went before any of this and always worked.
*
*    Only branches inside, and absolute references only to addresses that
*    survive the read -- $BF00, $2000, and the parameter blocks, which live at
*    $11xx and $13xx. Nothing here refers to a label in the overwritten range.
LAUNCH       jsr   MLI
             dfb   $ca              ; READ
             da    READPARM
             bcs   :bad
             lda   READPARM+7       ; how much actually arrived, high byte
             cmp   #$20             ; under 8K is not a BASIC.SYSTEM
             bcc   :bad
             lda   $2000
             cmp   #$4c             ; JMP -- how a SYS file begins
             bne   :bad

*--- NAME THE PROGRAM TO IT, if this was Ctrl-R rather than OA-Q.
*
*    FROM RUNNAME, NOT FNAME, and that is the whole reason RUNNAME exists:
*    RUNGO's first act is to copy "BASIC.SYSTEM" into FNAME so that OPENF
*    opens the interpreter. The document's name is gone by the time the stub
*    runs, and reading FNAME there named BASIC.SYSTEM to itself -- which
*    lands at the ] prompt having run nothing, looking exactly like the patch
*    not working at all.
*
*    BASIC.SYSTEM keeps the name it runs at start-up inside its own image, at
*    $2006: a length byte and up to fifteen characters, holding STARTUP as it
*    comes off the disk. Overwrite that between loading it and entering it and
*    it runs what you name instead. ProDOS 2.4's own selector does the same
*    thing, and ZipFiler's launch.S documents the two ways that do NOT work --
*    the pathname at $0280, which only sets a prefix, and hooking KSW, which
*    BASIC.SYSTEM undoes as it starts.
*
*    FNAME is already a length byte and low ASCII, which is exactly the shape
*    that field wants, and it lives at $0D00 -- far below the read, so it is
*    still there to copy.
             jsr   MLI
             dfb   $cc              ; CLOSE
             da    CLOSEPARM

*--- AFTER the close, matching ZipFiler's stub.
*
*    RUNNAME, at $13E0, and NOT a table inside this stub. The stub is
*    relocated to $0300 but its absolute references are not, so a name
*    assembled next to it here would be read from its address in the code --
*    which BASIC.SYSTEM has just been read over. Tried, while trying to prove
*    the patch worked, and it read garbage.
             ldx   RUNNAME
             beq   :enter
:name        lda   RUNNAME,x
             sta   $2006,x
             dex
             bpl   :name
:enter       jmp   $2000
:bad         jsr   MLI
             dfb   $cc
             da    CLOSEPARM
             jsr   MLI
             dfb   $65              ; QUIT to the dispatcher
             da    QPARM
             rts
LAUNEND

*--- Outside $2000-$6FFF on purpose: the stub reads this after BASIC.SYSTEM
*    has landed on top of everything the editor was assembled into.
             dum   $13b0
QPARM        ds    7                ; QUIT: count 4, then six reserved bytes
             dend

*--- Its own block: appended to QPARM's it ran into clip.S at $13c0, which
*    tools/dumcheck.py said so before the assembler saw it.
             dum   $13e0
RUNNAME      ds    16               ; what BASIC.SYSTEM should run: a length
                                    ; byte and up to fifteen characters, zero
                                    ; length meaning run nothing. Kept clear
                                    ; of FNAME, which RUNGO overwrites.
             dend
