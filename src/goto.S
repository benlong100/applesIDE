*--------------------------------------
* GOTO.S -- OA-L, go to a line by its NUMBER
*
* ZipEdit's OA-L takes an ordinal: the fourteenth line of the document. Here
* that would be the wrong question. A BASIC program's lines carry numbers of
* their own, those numbers are what GOTO and GOSUB refer to and what OA-K
* reports, and "line 1230" means the line labelled 1230 -- not the 1230th,
* which in a program numbered by tens does not exist at all. So this is a
* rewrite rather than a port, and the only thing it borrows is the prompt.
*
* IT SCANS WITHOUT MOVING THE CURSOR, and moves it once at the end. The
* obvious implementation walks the cursor forward a line at a time and stops
* when the number matches, but then a number that is not in the program leaves
* the cursor stranded at the bottom of it -- having destroyed the position the
* writer was at, to tell them it could not find anything. The scan here is a
* read-only walk over auxiliary memory; a miss costs nothing but the time.
*
* RFRESET, RFGET and RFNUMBER do the walking, and they already know how to
* step over the gap and how to read a leading number. The control flow below
* is RFCOLL's, with the comparison where its RFSTORE call was.
*--------------------------------------

*--------------------------------------
* KGOTO -- prompt for a line number and go there
*--------------------------------------
KGOTO        lda   #<MSGGOTO
             sta   STRPTR
             lda   #>MSGGOTO
             sta   STRPTR+1
             jsr   PROMPT
             bcs   :quit
             jsr   GTPARSE
             bcs   :quit            ; nothing typed, or not a number

             jsr   RFRESET
:line        lda   RFPTR            ; where this line starts, before anything
             sta   GTPOS            ; reads it
             lda   RFPTR+1
             sta   GTPOS+1
             jsr   RFNUMBER
             lda   RFANY
             beq   :skip            ; a line with no number cannot be asked for
             lda   LNUM
             cmp   GTWANT
             bne   :skip
             lda   LNUM+1
             cmp   GTWANT+1
             beq   :found
:skip        lda   RFEOL            ; RFNUMBER stopped where?
             cmp   #$02
             beq   :none            ; end of buffer
             cmp   #$01
             beq   :line            ; end of line: straight on to the next
:rest        jsr   RFGET            ; mid-line: run out to the break
             bcs   :none
             cmp   #TEXTLO
             bcs   :rest
             jmp   :line

:found       jmp   GTMOVE
:quit        rts

*--- not there. The number is worth repeating back: at a prompt it has already
*    scrolled away, and "no such line" alone leaves the writer wondering
*    whether they mistyped it or the line really is gone.
:none        lda   #$00
             sta   RFMI
             ldx   #$00
:copy        lda   MSGNOLINE,x
             beq   :num
             sta   MSGBUF,x
             inx
             cpx   #20
             bcc   :copy
:num         stx   RFMI
             lda   GTWANT
             sta   LNUM
             lda   GTWANT+1
             sta   LNUM+1
             jsr   RFPUTN
             ldx   RFMI
             lda   #$00
             sta   MSGBUF,x
             lda   #<MSGBUF
             sta   STRPTR
             lda   #>MSGBUF
             sta   STRPTR+1
             jmp   SHOWMSG

*--------------------------------------
* GTPARSE -- PBUF/PLEN as a number into GTWANT. Carry set if it is not one.
*
* Anything that is not a digit fails the whole thing rather than stopping at
* it: "12X" is a typo, and going to line 12 because that is the part that
* parsed would be obeying something nobody asked for.
*
* LNMUL10 is `LNUM = LNUM * 10 + A` -- it takes the digit itself, and adding
* it again afterwards counts every digit twice. Typing 30 then asked for line
* 60, which is 3+3 tens and 0+0 units and looks nothing like a doubling until
* the arithmetic is written out. It accumulates into LNUM, so the answer is
* moved out afterwards.
*--------------------------------------
GTPARSE      lda   PLEN
             beq   :no
             lda   #$00
             sta   LNUM
             sta   LNUM+1
             ldx   #$00
:loop        cpx   PLEN
             beq   :done
             lda   PBUF,x
             and   #$7f             ; the prompt collects high ASCII
             cmp   #'0'
             bcc   :no
             cmp   #'9'+1
             bcs   :no
             sec
             sbc   #'0'
             jsr   LNMUL10          ; takes the digit in A, and adds it itself
             inx
             bne   :loop
:done        lda   LNUM
             sta   GTWANT
             lda   LNUM+1
             sta   GTWANT+1
             clc
             rts
:no          sec
             rts

*--------------------------------------
* GTMOVE -- put the cursor at the aux address in GTPOS
*
* The gap primitives are the only things that may move the cursor: they carry
* CURLNO and CCOL with them, and anything that set GAPBEG directly would leave
* both lying. So this counts the distance and steps.
*
* Which direction, and how far, falls out of where the target sits relative to
* the gap. Text before the cursor is [BUFLO*256, GAPBEG) and text after it
* starts at GAPEND, so a target below GAPBEG is that many bytes to the left,
* and one at or above GAPEND is that many to the right.
*--------------------------------------
GTMOVE       lda   GTPOS            ; a target sitting exactly at the gap is
             cmp   GAPBEG           ; really the first byte past it
             bne   :cmp
             lda   GTPOS+1
             cmp   GAPBEG+1
             bne   :cmp
             lda   GAPEND
             sta   GTPOS
             lda   GAPEND+1
             sta   GTPOS+1

:cmp         lda   GTPOS+1
             cmp   GAPBEG+1
             bcc   :left
             bne   :right
             lda   GTPOS
             cmp   GAPBEG
             bcc   :left

:right       lda   GTPOS            ; distance = GTPOS - GAPEND
             sec
             sbc   GAPEND
             sta   GTN
             lda   GTPOS+1
             sbc   GAPEND+1
             sta   GTN+1
:rloop       lda   GTN
             ora   GTN+1
             beq   :done
             jsr   GAPRIGHT
             jsr   GTDEC
             jmp   :rloop

:left        lda   GAPBEG           ; distance = GAPBEG - GTPOS
             sec
             sbc   GTPOS
             sta   GTN
             lda   GAPBEG+1
             sbc   GTPOS+1
             sta   GTN+1
:lloop       lda   GTN
             ora   GTN+1
             beq   :done
             jsr   GAPLEFT
             jsr   GTDEC
             jmp   :lloop
:done        rts

GTDEC        lda   GTN
             bne   :lo
             dec   GTN+1
:lo          dec   GTN
             rts

             dum   $13c8
GTWANT       ds    2                ; the number asked for
GTPOS        ds    2                ; where its line starts, in aux
GTN          ds    2                ; bytes still to step
             dend
