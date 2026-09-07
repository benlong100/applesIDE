*--------------------------------------
* COLUMN.S -- recount the cursor's column by looking at the buffer
*
* Lifted out of ZipEdit's wrap.S, which is where it lived because that is what
* first needed it -- but nothing here is about wrapping. buffer.S calls it
* whenever the cursor lands on a line whose length it does not already know,
* and ApplesIDE has no wrap module for it to hide in.
*--------------------------------------

*--------------------------------------
* CALCCOL -- CCOL = characters between the start of the current line and the
*            cursor, counted the slow way by scanning back through the buffer.
*
* Off the hot path: CCOL is maintained incrementally by the buffer primitives,
* and this is only called when the cursor crosses onto a previous line, where
* the new column genuinely has to be discovered.
*
* Counts in sixteen bits, and writes CCOL itself rather than returning a byte
* in A. ZipEdit learned that the hard way: it used to count in one byte and
* claim to saturate, but `inc TMPC / beq :done` returns ZERO on the 256th
* character, not $ff, so a long line came back as column 1 and every decision
* taken from it was made on a lie. That matters more here than it did there --
* an Applesoft line can be 239 characters and is MEANT to be, so the long case
* is ordinary rather than pathological.
*--------------------------------------
CALCCOL      lda   #$00
             sta   CCOL
             sta   CCOL+1
             lda   GAPBEG
             sta   AUXPTR
             lda   GAPBEG+1
             sta   AUXPTR+1
:loop        lda   AUXPTR+1         ; start of buffer?
             cmp   #BUFLO
             bne   :dec
             lda   AUXPTR
             beq   :done
:dec         lda   AUXPTR
             bne   :d1
             dec   AUXPTR+1
:d1          dec   AUXPTR
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO          ; start of line
             bcc   :done
             inc   CCOL
             bne   :loop
             inc   CCOL+1
             jmp   :loop
:done        rts
