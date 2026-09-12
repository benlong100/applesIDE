*--------------------------------------
* RENUM.S -- renumber the program, and carry every reference with it
*
* The thing the whole project was asked for: "when lines are added to the code,
* the GOTO statement would automatically update to the new line number."
*
* Lines become 10, 20, 30 and so on, and every GOTO, GOSUB, THEN and RUN that
* pointed at a line still points at the same line.
*
* IT REFUSES TO RUN ON A BROKEN PROGRAM. OA-K's check goes first, and if any
* reference points at a line that is not there, RENUM stops and says so
* instead. This is not tidiness. Renumbering a program with a dangling GOTO
* 999 would leave that 999 untouched while every real line moved -- and 999
* might now BE a line, so a reference that was visibly broken becomes a jump
* to somewhere arbitrary. Better to fix it first.
*
* HOW IT MOVES. The gap buffer makes an edit cheap at the cursor and expensive
* anywhere else, so this works strictly left to right and the gap only ever
* moves forwards: total cost is one walk of the document, not one per line.
* At each number -- a line's own, or a reference's target -- the old digits are
* deleted with DELFWD, which does not move the cursor, and the new ones are
* inserted at it. So the replacement lands exactly where the original was, and
* lengths need not match.
*
* THE FILE ON DISK IS NOT TOUCHED. If a renumber goes wrong the remedy is to
* not save, which is worth knowing because there is no undo.
*--------------------------------------

*--------------------------------------
* KRENUM -- the command behind OA-R
*--------------------------------------
KRENUM       jsr   RFCOLL           ; the table of old numbers, in order
             lda   RFN
             ora   RFN+1
             bne   :any
             rts                    ; nothing numbered: nothing to do
:any         jsr   RFSCAN           ; and are they all reachable?
             bcc   :go
             jmp   RFREPORT         ; no: say which, and change nothing

:go          jsr   RNTOP            ; the gap to the very start
             jsr   RNPASS
             jsr   RNTOP            ; and back, since the walk left it at the end

             lda   #$00
             sta   SCROLLTOP
             sta   SCROLLTOP+1
             sta   HOFF
             lda   #<MSGRENUM
             sta   STRPTR
             lda   #>MSGRENUM
             sta   STRPTR+1
             jmp   SHOWMSG

*--------------------------------------
* RNTOP -- put the cursor at the start of the buffer
*
* The same walk OA-< does. Everything below assumes the gap is where it is
* about to work, and the cheapest way to be sure is to start from one end.
*--------------------------------------
RNTOP        jsr   GAPLEFT
             bcc   RNTOP
             rts

*--------------------------------------
* RNPASS -- walk the document once, rewriting every number
*--------------------------------------
RNPASS       lda   #$00
             sta   RNIDX
             sta   RNIDX+1

*--- a line begins under the cursor
:line        jsr   RNPEEK           ; how many digits, and what do they say?
             lda   RNN
             beq   :body            ; unnumbered: leave it alone

             jsr   RNDEL            ; take the old digits out
             inc   RNIDX            ; this line's place in the program...
             bne   :num
             inc   RNIDX+1
:num         jsr   RNNEW            ; ...times ten is its new number
             jsr   LNDIGITS

*--- and now the rest of the line
:body        lda   #$00
             sta   RFSTR
             ldx   #RFNKW-1
:clr         sta   RFHIT,x
             dex
             bpl   :clr

:scan        jsr   RNAT             ; what is under the cursor?
             bcc   :have
             jmp   :done            ; end of buffer. A jump, because the DATA
:have        cmp   #TEXTLO           ; dispatch above put :done out of reach
             bcs   :text
             jsr   GAPRIGHT         ; a break: step over it, next line
             jmp   :line

:text        cmp   #$a2             ; a double quote flips the string state
             bne   :nq
             lda   RFSTR
             eor   #$01
             sta   RFSTR
             jsr   GAPRIGHT
             jmp   :scan
:nq          lda   RFSTR
             beq   :code
             jsr   GAPRIGHT         ; inside a string: nothing counts
             jmp   :scan

*--- outside a string. Feed the character to the same matcher OA-K uses, then
*    step over it -- the keyword's own characters are not being changed.
:code        jsr   RNAT
             sta   RFCH
             jsr   RNMATCH
             php
             jsr   GAPRIGHT
             plp
             bcc   :scan            ; no keyword completed

*--- X AGAIN. GAPRIGHT just above uses X as scratch -- it holds the byte it
*    stepped over -- so the index RNMATCH left there is long gone, and
*    RFKWR,x was being read at an offset equal to a character code.
*
*    It looked like it worked because the only test was `bne :target`, and a
*    garbage byte is almost never zero, so keywords that DO take a line number
*    took the right path by accident. REM did not: it fell into :target, found
*    no digits after it, and carried on scanning the comment -- so a line
*    number mentioned in one was renumbered. The suite missed it because its
*    REM test used 999, which maps to nothing whatever you do.
             ldx   RFWH
             lda   RFKWR,x          ; X is which one: 1 takes a number, 0 ends
             beq   :rem             ; the line, 2 ends the statement
             cmp   #$02
             beq   :dataj
             bne   :target
:dataj       jmp   :data            ; the block sits after this routine's exit:
                                    ; put in the middle of the walk it pushed
                                    ; half the loop's branches out of range

*--- REM. Nothing after it is code, so run to the break without looking.
:rem         jsr   RNAT
             bcs   :done
             cmp   #TEXTLO
             bcc   :scan            ; the break itself; :scan will handle it
             jsr   GAPRIGHT
             jmp   :rem

*--- a keyword that takes a line number, possibly a list of them
:target      jsr   RNAT
             bcs   :done
             cmp   #' '+$80
             bne   :tnum
             jsr   GAPRIGHT         ; skip spaces before the number
             jmp   :target
:tnum        jsr   RNPEEK
             lda   RNN
             beq   :scan            ; THEN PRINT, or a bare RUN: not a number

             jsr   RNMAP            ; old number -> its new one
             bcs   :scan            ; unmappable; the check said this cannot
             jsr   RNDEL            ; happen, so this is belt and braces
             jsr   LNDIGITS

             jsr   RNAT             ; a comma means another one follows
             bcs   :done
             cmp   #$ac
             beq   :comma
             jmp   :scan            ; the routine is long enough now that the
:comma       jsr   GAPRIGHT         ; top of the walk needs a jump
             jmp   :target

:done        rts

*--- DATA. Its contents are values, so a number among them is not a reference
*    and MUST NOT BE REWRITTEN. Demonstrated before it was fixed:
*    100 DATA GOTO 500 renumbered to 10 DATA GOTO 30, quietly changing the
*    program's data rather than a reference to a line.
*
*    Unlike REM it ends at a COLON rather than at the break, so the GOTO in
*    10 DATA 1,2:GOTO 888 is still followed. A colon inside quotes does not
*    end it, which is why the string state is tracked here too.
*
*    Jumps rather than branches back to the walk: this sits past the end of
*    the routine, well outside branch range of either.
:data        jsr   RNAT
             bcc   :dchk
             jmp   :done
:dchk        cmp   #TEXTLO
             bcs   :dtext
             jmp   :scan            ; the break; :scan will handle it
:dtext       cmp   #$a2
             bne   :dnq
             lda   RFSTR
             eor   #$01
             sta   RFSTR
             jsr   GAPRIGHT
             jmp   :data
:dnq         lda   RFSTR
             bne   :dstep
             jsr   RNAT
             cmp   #':'+$80
             beq   :dout
:dstep       jsr   GAPRIGHT
             jmp   :data
:dout        jsr   GAPRIGHT         ; over the colon: code again after it
             jmp   :scan

*--------------------------------------
* RNAT -- the character under the cursor, without moving it
*
* Everything after the cursor is contiguous from GAPEND, so this is one read.
* Carry set at the end of the buffer.
*--------------------------------------
RNAT         jsr   ATEND
             bcc   :ok
             sec
             rts
:ok          lda   GAPEND
             sta   AUXPTR
             lda   GAPEND+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             clc
             rts

*--------------------------------------
* RNPEEK -- read the run of digits under the cursor WITHOUT consuming it
*
* LNUM gets the value, RNN how many digits. Reading ahead rather than stepping
* is what lets the digits be deleted afterwards: DELFWD takes the character
* after the cursor, so the cursor must still be sitting in front of them.
*--------------------------------------
RNPEEK       lda   #$00
             sta   LNUM
             sta   LNUM+1
             sta   RNN
             lda   GAPEND
             sta   RNP
             lda   GAPEND+1
             sta   RNP+1

:loop        lda   RNP+1
             cmp   #BUFHI
             bcs   :done
             lda   RNP
             sta   AUXPTR
             lda   RNP+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             jsr   LNDIGIT
             bcs   :done
             jsr   LNMUL10
             inc   RNN
             inc   RNP
             bne   :loop
             inc   RNP+1
             jmp   :loop
:done        rts

*--------------------------------------
* RNDEL -- delete RNN characters at the cursor
*--------------------------------------
RNDEL        lda   RNN
             beq   :done
:loop        jsr   DELFWD
             dec   RNN
             bne   :loop
:done        rts

*--------------------------------------
* RNNEW -- LNUM = RNIDX * 10, the new number for the RNIDX'th line
*
* RFMAX caps the table at 2000 lines, so the largest number this can produce is
* 20000 -- comfortably inside Applesoft's ceiling of 63999, which is why there
* is no check here.
*--------------------------------------
RNNEW        lda   RNIDX
             sta   LNUM
             lda   RNIDX+1
             sta   LNUM+1
             asl   LNUM
             rol   LNUM+1           ; x2
             lda   LNUM
             sta   RNT
             lda   LNUM+1
             sta   RNT+1
             asl   LNUM
             rol   LNUM+1           ; x4
             asl   LNUM
             rol   LNUM+1           ; x8
             lda   LNUM
             clc
             adc   RNT
             sta   LNUM
             lda   LNUM+1
             adc   RNT+1
             sta   LNUM+1           ; x8 + x2 = x10
             rts

*--------------------------------------
* RNMAP -- LNUM holds an old line number; replace it with the new one
*
* Its position in RFTAB is its position in the program, and the line in that
* position is going to be numbered (position+1)*10. So the mapping needs no
* second table: the first one already says everything.
*
* Carry set if the number is not in the table at all, which RFSCAN has already
* ruled out.
*--------------------------------------
RNMAP        lda   #<RFTAB
             sta   RFTP
             lda   #>RFTAB
             sta   RFTP+1
             lda   #$00
             sta   RNJ
             sta   RNJ+1

:loop        lda   RNJ              ; run off the end of the table?
             cmp   RFN
             bne   :test
             lda   RNJ+1
             cmp   RFN+1
             beq   :no

:test        ldy   #$00
             lda   (RFTP),y
             cmp   LNUM
             bne   :next
             iny
             lda   (RFTP),y
             cmp   LNUM+1
             beq   :found
:next        lda   RFTP
             clc
             adc   #$02
             sta   RFTP
             bcc   :j
             inc   RFTP+1
:j           inc   RNJ
             bne   :loop
             inc   RNJ+1
             jmp   :loop

:found       inc   RNJ              ; positions count from zero, lines from ten
             bne   :mul
             inc   RNJ+1
:mul         lda   RNJ
             sta   RNIDX2
             lda   RNJ+1
             sta   RNIDX2+1
             jsr   RNTEN
             clc
             rts
:no          sec
             rts

*--- RNIDX2 * 10 into LNUM, so RNMAP does not disturb RNIDX
RNTEN        lda   RNIDX2
             sta   LNUM
             lda   RNIDX2+1
             sta   LNUM+1
             asl   LNUM
             rol   LNUM+1
             lda   LNUM
             sta   RNT
             lda   LNUM+1
             sta   RNT+1
             asl   LNUM
             rol   LNUM+1
             asl   LNUM
             rol   LNUM+1
             lda   LNUM
             clc
             adc   RNT
             sta   LNUM
             lda   LNUM+1
             adc   RNT+1
             sta   LNUM+1
             rts

*--------------------------------------
* RNMATCH -- RFMATCH, but leaving the matched keyword's index in X
*
* RFMATCH already puts it in RFWH; this is only a wrapper so that the caller
* reads one register rather than remembering a variable name.
*--------------------------------------
RNMATCH      lda   #$01
             sta   RNONLY
             jsr   RFMATCH
             bcc   :none
             ldx   RFWH
             sec
             rts
:none        clc
             rts

             dum   $1350
RNIDX        ds    2                ; which line we are on, counting from zero
RNIDX2       ds    2                ; RNMAP's, kept apart from RNIDX
RNJ          ds    2                ; RNMAP's walk through the table
RNN          ds    1                ; digits under the cursor
RNP          ds    2                ; RNPEEK's read-ahead pointer
RNT          ds    2                ; multiply scratch
             dend
