*--------------------------------------
* HILITE.S -- draw Applesoft's reserved words inverse
*
* Called by RENDER once per row, on the finished LINEBUF and just before
* DRAWLINE. Working on the assembled row rather than inside the character loop
* is what makes it affordable: the row is eighty contiguous bytes of main
* memory, so a keyword can be matched by looking forward from a cell instead of
* by carrying ninety-eight half-finished candidates through every character
* the editor draws.
*
* MATCHING AT A POSITION, NOT ROLLING. At each cell that could begin a keyword
* -- a letter, and not inside a string -- the first-letter index says which
* candidates to try and there are rarely more than a handful. A cell that
* begins no keyword costs one table lookup. After a match the scan skips the
* whole keyword, so PRINT is not re-examined as RINT, INT, NT and T; that is
* also what Applesoft does, and it is why the match must be greedy.
*
* LONGEST FIRST, which tools/gentokens.py arranges: ATN before AT, so ATN(1)
* highlights as one word. Applesoft's own tokenizer finds AT first -- it comes
* earlier in the token table -- and carries a special case to recover. Sorting
* the table differently gets the same answer without one.
*
* WHAT IT DOES NOT KNOW. Whether a cell is inside a string is not decidable
* from the row alone, since the quote may have opened off the left edge, so
* RENDER records it in MASKBUF as it goes and this reads it back. REM is
* handled here, because everything after it on the line is literal.
*
* Lowercase is not matched. Applesoft tokenizes uppercase only, so `print` is
* a variable name to the machine and drawing it as a keyword would be a lie.
*--------------------------------------

*--------------------------------------
* TKLINE -- invert every keyword in LINEBUF
*--------------------------------------
TKLINE       lda   #$00
             sta   TKI

*--- The pinned line number is not part of the line's text, so start past it.
*    HOFF is zero almost always, and then all of this is skipped.
             lda   HOFF
             beq   :loop
             lda   RNUMW
             beq   :edge
             clc
             adc   #$01
             sta   TKI

*--- The leftmost visible character is somewhere in the middle of the line, and
*    quite possibly in the middle of a WORD -- whose beginning is off the
*    screen where nothing can see it. PRINT scrolled by sixteen columns shows
*    as INT, which is itself an Applesoft keyword and was being highlighted as
*    one. So skip whatever partial word is against the left edge.
*
*    A keyword starting exactly at the edge is lost this way. That is the
*    right trade: a missing highlight is a smaller lie than a highlight over
*    the tail of some longer word.
:edge        lda   TKI
             cmp   GSCRW
             bcs   :loop
             tax
             lda   LINEBUF,x
             cmp   #$c1
             bcc   :loop            ; not a letter: the word has ended
             cmp   #$db
             bcs   :loop
             inc   TKI
             jmp   :edge

:loop        lda   TKI
             cmp   GSCRW
             bcc   :incell
             jmp   :done            ; :done is out of branch range from here
:incell      tax
             lda   MASKBUF,x
             beq   :iscode          ; inside a string: not code
:nextj       jmp   :next            ; a trampoline: :next is out of range of
                                    ; every test below it
:iscode      lda   LINEBUF,x
             cmp   #$c1             ; A-Z only. Lowercase is not a keyword to
             bcc   :nextj           ; Applesoft and must not look like one.
             cmp   #$db
             bcs   :nextj

*--- which candidates start with this letter?
             sec
             sbc   #$c1
             tay
             lda   TKCOUNT,y
             beq   :nextj
             sta   TKC
             lda   TKFIRST,y
             sta   TKK

:try         ldx   TKK
             lda   TKLEN,x
             sta   TKL
             lda   TKLO,x
             sta   TKP
             lda   TKHI,x
             sta   TKP+1

             ldy   #$00
:cmp         cpy   TKL
             beq   :hit
             tya
             clc
             adc   TKI
             cmp   GSCRW
             bcs   :fail            ; runs off the end of the row
             tax
             lda   MASKBUF,x
             bne   :fail            ; ...or into a string
             lda   LINEBUF,x
             cmp   (TKP),y
             bne   :fail
             iny
             bne   :cmp

:fail        inc   TKK
             dec   TKC
             bne   :try
             jmp   :next            ; no candidate matched

*--- a keyword. Invert its cells, then step the whole way over it.
:hit         lda   TKI
             sta   TKJ
             lda   TKL
             sta   TKM
:inv         ldx   TKJ
             lda   LINEBUF,x
             jsr   INVCHR
             sta   LINEBUF,x
             inc   TKJ
             dec   TKM
             bne   :inv

             lda   TKI
             clc
             adc   TKL
             sta   TKI

*--- REM, and the rest of the line is a comment rather than code
             lda   TKK
             cmp   #TKREMI
             beq   :remdone
             jmp   :loop
:remdone     rts

:next        inc   TKI
             jmp   :loop
:done        rts

             dum   $1370
TKI          ds    1                ; cell being examined
TKK          ds    1                ; candidate keyword
TKC          ds    1                ; how many candidates are left
TKL          ds    1                ; its length
TKJ          ds    1                ; cell being inverted
TKM          ds    1                ; cells left to invert
             dend
