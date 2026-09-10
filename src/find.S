*--------------------------------------
* FIND.S -- OA-F and OA-G
*
* Taken whole from ZipEdit's edit_ops.S, deliberately and almost unaltered.
* The wrap logic was only got right in ZipEdit 1.4, and getting it right
* flushed out two bugs that had been shipping since the feature was written:
* OA-G never advancing, and a match lying against the end of the document
* being unfindable. Both were invisible to a suite that already had a find
* test. Retyping this from memory would have been a good way to reintroduce
* them, so it is a port rather than a rewrite, and the comments explaining
* which byte does what have come across with it.
*
* WHAT IS NOT DONE HERE, on purpose: nothing knows about Applesoft. A search
* for PRINT matches the keyword, the same letters inside a string, and the
* same letters in a REM, because that is what a search for PRINT means. The
* highlighter and the hint row care about the difference; a search does not.
*--------------------------------------

*--------------------------------------
* KFIND -- ask for a pattern, then search forward (OA-F)
*--------------------------------------
KFIND        lda   #<MSGFIND
             sta   STRPTR
             lda   #>MSGFIND
             sta   STRPTR+1
             jsr   PROMPT
             bcs   :quit
             lda   PLEN
             sta   FINDLEN
             ldx   #$00
:copy        cpx   PLEN
             beq   FINDFIRST
             lda   PBUF,x
             sta   FINDBUF,x
             inx
             bne   :copy
:quit        rts

*--------------------------------------
* FINDFIRST / FINDNEXT -- search for FINDBUF, wrapping at the end
*
* Both walk forward and both wrap. They differ in one thing: whether the
* character UNDER the cursor is a candidate. A fresh pattern (OA-F) has to be
* able to match it, or a program whose first line is the pattern reports NOT
* FOUND with the cursor sitting on it. Find again (OA-G) must not, or it
* re-matches where it stands and the cursor never moves -- which is exactly
* what it used to do, every time, for want of this one byte.
*
* The search is two passes because the gap splits the text in two. Pass one is
* everything after the cursor, contiguous from GAPEND to the top of the
* buffer. Pass two is everything before it, contiguous from the bottom of the
* buffer up to GAPBEG. Between them they cover the program exactly once, which
* is what wrapping means.
*
* A hit in the second pass says so on the status row, so a cursor that has
* jumped backwards is explained rather than surprising.
*
* Neither pass sees a match STRADDLING the gap -- one starting before the
* cursor and ending after it. Reaching it would mean testing for a
* discontinuity on every byte of every compare, and it can only arise when the
* cursor has been parked inside an occurrence by hand: a find always leaves it
* on a match's FIRST character, never inside one.
*--------------------------------------
FINDFIRST    lda   #$00
             sta   FSKIP
             beq   FINDGO           ; always taken -- STA leaves Z alone
FINDNEXT     lda   #$01
             sta   FSKIP
FINDGO       lda   FINDLEN
             bne   :tail
             rts                    ; OA-G with nothing to look for

*--- Pass one. Stop where a compare would run past $BFFF: $C000 is the I/O
*    page, and merely READING $C010 there would eat the keyboard strobe. The
*    last legal start is BUFHI*256-FINDLEN, so the limit is one past it. That
*    +1 is not cosmetic -- the text after the cursor always ends at $BFFF, so
*    without it a match lying against the end of the program was unfindable.
:tail        lda   #$00
             sec
             sbc   FINDLEN
             sta   TMPA
             lda   #BUFHI
             sbc   #$00
             sta   TMPB
             inc   TMPA
             bne   :from
             inc   TMPB

:from        lda   GAPEND           ; at the cursor, or one past it
             clc
             adc   FSKIP
             sta   AUXPTR
             lda   GAPEND+1
             adc   #$00
             sta   AUXPTR+1
             jsr   FSCAN
             bcs   :wrap

             lda   FDIST            ; the character we stepped over counts
             clc
             adc   FSKIP
             sta   FDIST
             bcc   :right
             inc   FDIST+1
:right       jmp   FMOVER

*--- Pass two: the text before the cursor. The last start worth trying is the
*    one whose match ends at GAPBEG, so the limit is GAPBEG-FINDLEN+1. If the
*    text before the cursor is shorter than the pattern that lands at or below
*    the buffer base and FSCAN gives up on its first test, which is right.
:wrap        lda   GAPBEG
             sec
             sbc   FINDLEN
             sta   TMPA
             lda   GAPBEG+1
             sbc   #$00
             sta   TMPB
             inc   TMPA
             bne   :top
             inc   TMPB

:top         lda   #$00
             sta   AUXPTR
             lda   #BUFLO
             sta   AUXPTR+1
             jsr   FSCAN
             bcs   :nope

*--- The hit is at BUFLO*256+FDIST, behind the cursor, so the gap walks back
*    GAPBEG-(BUFLO*256+FDIST) characters to reach it.
             lda   GAPBEG
             sec
             sbc   FDIST
             tax
             lda   GAPBEG+1
             sbc   FDIST+1
             sec                    ; less the buffer base, whose low byte is
             sbc   #BUFLO           ; zero, so this cannot borrow again
             sta   FDIST+1
             stx   FDIST
             jsr   FMOVEL

             lda   #<MSGWRAPPED
             sta   STRPTR
             lda   #>MSGWRAPPED
             sta   STRPTR+1
             jmp   SHOWMSG

:nope        lda   #<MSGNOTFND
             sta   STRPTR
             lda   #>MSGNOTFND
             sta   STRPTR+1
             jmp   SHOWMSG

*--------------------------------------
* FSCAN -- look for FINDBUF from AUXPTR up to, but not including, TMPA/TMPB.
*
* Carry clear on a hit, AUXPTR left on its first byte and FDIST holding how
* far that is from where this scan began. Carry set if the region ran out.
* A plain linear scan: within one pass the region is contiguous, so there is
* no gap arithmetic here at all.
*--------------------------------------
FSCAN        lda   #$00
             sta   FDIST
             sta   FDIST+1

:outer       lda   AUXPTR+1         ; past the end of the region?
             cmp   TMPB
             bcc   :try
             bne   :out
             lda   AUXPTR
             cmp   TMPA
             bcs   :out

:try         ldy   #$00
:cmp         cpy   FINDLEN
             beq   :hit
             jsr   AUXRD            ; reads AUXPTR+Y
             sta   TMPC
             lda   FINDBUF,y
             cmp   TMPC
             bne   :step
             iny
             bne   :cmp

:step        inc   AUXPTR
             bne   :dist
             inc   AUXPTR+1
:dist        inc   FDIST
             bne   :outer
             inc   FDIST+1
             jmp   :outer

:hit         clc
             rts
:out         sec
             rts

*--------------------------------------
* FMOVER / FMOVEL -- walk the cursor FDIST characters onto the hit, forwards
* or backwards. Going through the gap movers rather than just setting GAPBEG
* is the point: CURLNO and CCOL are maintained incrementally, so the line and
* column follow for free and the redraw knows where to put the cursor.
*--------------------------------------
FMOVER       lda   FDIST
             ora   FDIST+1
             beq   :done
:step        jsr   GAPRIGHT
             jsr   FDEC
             bne   :step
:done        rts

FMOVEL       lda   FDIST
             ora   FDIST+1
             beq   :done
:step        jsr   GAPLEFT
             jsr   FDEC
             bne   :step
:done        rts

*--- one off FDIST, leaving Z set when it reaches zero. A counter cannot live
*    in X across GAPLEFT or GAPRIGHT -- both TAX the byte they carry over.
FDEC         lda   FDIST
             bne   :lo
             dec   FDIST+1
:lo          dec   FDIST
             lda   FDIST
             ora   FDIST+1
             rts

             dum   $13d0
FSKIP        ds    1                ; is the character under the cursor a
                                    ; candidate? OA-F yes, OA-G no
FDIST        ds    2                ; how far the hit is from where we started
             dend
