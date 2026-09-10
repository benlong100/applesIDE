*--------------------------------------
* CLIP.S -- cut, copy and paste, a line at a time
*
* Ported from ZipEdit's edit_ops.S, which is why it is short: CLIPBUF, CLIPLEN,
* CLIPPTR, CLIPLINE, DECLEN, COPYSEL and DELSEL all came across with the engine
* and were already sitting here unused. Only the three handlers were missing.
*
* LINE BASED, with a selection taking precedence where there is one. A line is
* the natural unit in a BASIC program in a way it is not in prose: it is the
* thing that carries a number, the thing GOTO points at, and the thing a
* programmer means by "this bit".
*
* WHAT THIS DELIBERATELY DOES NOT DO is renumber a pasted line. Paste puts back
* exactly what was taken, line number and all, which means pasting a copied
* line leaves two lines with the same number -- and Applesoft will keep only
* one of them when the file is loaded. That is a real trap, and the answer is
* OA-R rather than magic here: a paste that silently rewrote the number would
* be a paste that did not give back what it took. The status row says nothing
* about it because OA-K already reports duplicate trouble properly.
*--------------------------------------

*--------------------------------------
* KCOPY -- copy the cursor's line to the clipboard (OA-C)
*--------------------------------------
KCOPY        jsr   COPYSEL          ; a selection wins over the whole line
             bcs   :line
             lda   #$00
             sta   CLIPLINE
             jsr   SELDONE
             jmp   :say
:line        jsr   GRABLINE
             lda   #$01
             sta   CLIPLINE
:say         lda   #<MSGCOPIED
             sta   STRPTR
             lda   #>MSGCOPIED
             sta   STRPTR+1
             jmp   SHOWMSG

*--------------------------------------
* GRABLINE -- CLIPBUF/CLIPLEN = the cursor's line, without its break
*--------------------------------------
GRABLINE     lda   #$00
             sta   CLIPLEN

*--- The copy below counts in X, and takes 255 characters at most, so the run
*    before the cursor is clamped to that. CCOL is two bytes and X is one:
*    left unclamped, `cpx CCOL` would compare against the low byte alone and
*    take an arbitrary slice out of the middle of a long line.
             lda   CCOL+1
             beq   :precnt
             lda   #$ff             ; longer than that: take the last 255
             bne   :setpre          ; characters before the cursor
:precnt      lda   CCOL
:setpre      sta   GRABPRE

*--- the part before the cursor is contiguous, ending at the gap
             lda   GAPBEG
             sec
             sbc   GRABPRE
             sta   AUXPTR
             lda   GAPBEG+1
             sbc   #$00
             sta   AUXPTR+1
             ldx   #$00
:pre         cpx   GRABPRE
             beq   :post
             ldy   #$00
             jsr   AUXRD
             sta   CLIPBUF,x
             inx
             inc   AUXPTR
             bne   :pre
             inc   AUXPTR+1
             jmp   :pre

*--- the rest resumes past the gap, up to the break
:post        lda   GAPEND
             sta   AUXPTR
             lda   GAPEND+1
             sta   AUXPTR+1
:ploop       cpx   #$ff
             bcs   :done
             lda   AUXPTR+1
             cmp   #BUFHI
             bcs   :done
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO
             bcc   :done
             sta   CLIPBUF,x
             inx
             inc   AUXPTR
             bne   :ploop
             inc   AUXPTR+1
             jmp   :ploop
:done        stx   CLIPLEN
             lda   #$00
             sta   CLIPLEN+1
             rts

*--------------------------------------
* KCUT -- copy the line, then remove it (OA-X)
*
* No message either way: the text visibly goes away, and a status row saying
* so would be telling the writer what they can already see.
*--------------------------------------
KCUT         jsr   COPYSEL          ; a selection wins over the whole line
             bcs   :line
             lda   #$00
             sta   CLIPLINE
             jmp   DELSEL

:line        jsr   GRABLINE
             lda   #$01
             sta   CLIPLINE
             jsr   BOL              ; stand at the start of the line
             lda   CLIPLEN
             sta   TMPA
             beq   :nl
:del         jsr   DELFWD
             dec   TMPA
             bne   :del
:nl          jsr   PEEKFWD          ; and take the break with it
             bcs   :done
             cmp   #TEXTLO
             bcs   :done
             jsr   DELFWD
:done        rts

*--------------------------------------
* KPASTE -- put the clipboard back at the cursor (OA-V)
*
* ZipEdit ended this with a reflow, because inserting text there could push a
* paragraph past the wrap margin. Nothing wraps here, so there is nothing to
* tidy: the insert changed the size of the gap, which is all the main loop
* needs to know to repaint properly.
*
* A WHOLE LINE GOES BACK AS A WHOLE LINE. ZipEdit inserts at the cursor
* wherever it happens to be, which in prose merely joins two bits of text.
* Here it produced `30 PRINT 30 PRINT` from a copied line pasted mid-line --
* not a mess to tidy up but a syntax error, and one Applesoft would reject on
* the line the writer was in the middle of. So a line-wise clipboard steps to
* the start of the line first and the pasted line lands ABOVE the one the
* cursor was on, which is where the eye expects it and where every other
* editor with a line-cut puts it.
*
* A SELECTION still pastes at the cursor: it was taken from mid-line and
* belongs back mid-line. CLIPLINE is what tells the two apart.
*--------------------------------------
KPASTE       jsr   DELSEL
             lda   CLIPLEN
             ora   CLIPLEN+1
             beq   :done
             lda   CLIPLINE
             beq   :at
             jsr   BOL              ; a line goes in as a line
:at          lda   #<CLIPBUF
             sta   CLIPPTR
             lda   #>CLIPBUF
             sta   CLIPPTR+1
             lda   CLIPLEN          ; SELLEN doubles as the counter
             sta   SELLEN
             lda   CLIPLEN+1
             sta   SELLEN+1
:loop        ldy   #$00
             lda   (CLIPPTR),y
             jsr   INSCHR
             bcs   :done            ; buffer full: stop where it stopped
             inc   CLIPPTR
             bne   :dec
             inc   CLIPPTR+1
:dec         jsr   DECLEN
             bne   :loop
             lda   CLIPLINE
             beq   :done
             lda   #HARDCR          ; a pasted line ends with a real break
             jsr   INSCHR
:done        rts

             dum   $13c0
GRABPRE      ds    1                ; characters to take from before the cursor
             dend
