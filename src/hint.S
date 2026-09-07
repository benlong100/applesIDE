*--------------------------------------
* HINT.S -- show the syntax of the keyword you are working on
*
* The row ZipEdit spent on a Markdown cheat sheet, toggled with OA-/. Here it
* carries the syntax of the last Applesoft keyword before the cursor.
*
* THE LAST KEYWORD, not the one under the cursor. Typing PRINT and then a
* space would lose a hint that only looked at the word being typed, and that is
* precisely the moment it is wanted: the syntax is for the arguments, and the
* arguments come after the keyword. So it stays up until another keyword
* replaces it.
*
* Found by walking the line from its first character to the cursor. That
* sounds expensive and is not: the line begins exactly CCOL bytes before the
* gap, so there is nothing to search for, an Applesoft line is 239 characters
* at the very most, and the same first-letter dispatch the highlighter uses
* means most characters cost one table lookup. It runs once a keystroke, not
* once a character drawn.
*
* Strings and REM are honoured, so PRINT "GOTO" leaves the hint on PRINT, and
* nothing after a REM changes it.
*--------------------------------------

*--------------------------------------
* DRAWCHEAT -- the hint row. Named for the hook it replaces in display.S.
*--------------------------------------
DRAWCHEAT    jsr   HNFIND
             bcs   :none

             lda   HNW              ; the keyword's syntax string
             tax
             lda   TKSLO,x
             sta   STRPTR
             lda   TKSHI,x
             sta   STRPTR+1
             lda   #CHEATROW
             jmp   SHOWSTR

*--- nothing to say: the placeholder, so the row does not look broken
:none        lda   #<CHEATTXT
             sta   STRPTR
             lda   #>CHEATTXT
             sta   STRPTR+1
             lda   #CHEATROW
             jmp   SHOWSTR

*--------------------------------------
* HNFIND -- which keyword was the last one before the cursor?
*
* Carry clear and HNW set if there was one.
*--------------------------------------
HNFIND       lda   #$ff
             sta   HNW
             lda   #$00
             sta   HNSTR

*--- the line starts CCOL bytes back from the gap
             lda   GAPBEG
             sec
             sbc   CCOL
             sta   HNP
             lda   GAPBEG+1
             sbc   CCOL+1
             sta   HNP+1

:loop        lda   HNP+1            ; reached the cursor?
             cmp   GAPBEG+1
             bne   :go
             lda   HNP
             cmp   GAPBEG
             bne   :go
             jmp   :out             ; :out is out of branch range from here
:go          lda   HNP
             sta   AUXPTR
             lda   HNP+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             sta   HNCH

             cmp   #$a2             ; a quote flips the string state
             bne   :nq
             lda   HNSTR
             eor   #$01
             sta   HNSTR
             jmp   :step
:nq          lda   HNSTR
             bne   :step            ; inside a string: not code

             lda   HNCH             ; could this begin a keyword?
             cmp   #$c1
             bcc   :step
             cmp   #$db
             bcs   :step
             sec
             sbc   #$c1
             tay
             lda   TKCOUNT,y
             beq   :step
             sta   HNC
             lda   TKFIRST,y
             sta   HNK

:try         ldx   HNK
             lda   TKLEN,x
             sta   HNL
             lda   TKLO,x
             sta   TKP
             lda   TKHI,x
             sta   TKP+1
             jsr   HNCMP            ; does it sit here, and end by the cursor?
             bcc   :hit
             inc   HNK
             dec   HNC
             bne   :try
             beq   :step            ; always taken

*--- a keyword. Remember it and step the whole way over it, so PRINT is not
*    then read as RINT.
:hit         lda   HNK
             sta   HNW
             cmp   #TKREMI
             bne   :past
             jmp   :out             ; REM: nothing after it is code
:past

             lda   HNP
             clc
             adc   HNL
             sta   HNP
             bcc   :again
             inc   HNP+1
:again       jmp   :loop

:step        inc   HNP
             bne   :again
             inc   HNP+1
             jmp   :loop

:out         lda   HNW
             cmp   #$ff
             beq   :no
             clc
             rts
:no          sec
             rts

*--------------------------------------
* HNCMP -- is the keyword at TKP, length HNL, sitting at HNP?
*
* Carry clear if it is. It must also finish at or before the cursor: a
* half-typed PRINT is not a PRINT, and reading past the gap would compare
* against text the writer has not reached.
*--------------------------------------
HNCMP        ldy   #$00
:loop        cpy   HNL
             beq   :yes
             tya                    ; HNP+Y still before the cursor?
             clc
             adc   HNP
             sta   HNQ
             lda   HNP+1
             adc   #$00
             sta   HNQ+1
             cmp   GAPBEG+1
             bcc   :read
             bne   :no
             lda   HNQ
             cmp   GAPBEG
             bcs   :no              ; at or past the cursor: too short
:read        lda   HNQ
             sta   AUXPTR
             lda   HNQ+1
             sta   AUXPTR+1
             sty   HNY
             ldy   #$00
             jsr   AUXRD
             ldy   HNY
             cmp   (TKP),y
             bne   :no
             iny
             bne   :loop
:yes         clc
             rts
:no          sec
             rts

             dum   $1380
HNP          ds    2                ; the walk
HNQ          ds    2                ; HNCMP's scratch pointer
HNW          ds    1                ; the keyword found, $ff for none
HNK          ds    1                ; candidate being tried
HNC          ds    1                ; candidates left
HNL          ds    1                ; its length
HNCH         ds    1
HNSTR        ds    1                ; inside a string literal
HNY          ds    1                ; Y across the aux read
             dend
