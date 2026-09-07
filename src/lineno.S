*--------------------------------------
* LINENO.S -- supply the next line number when Return is pressed
*
* The first half of what was actually asked for: "automatic line number
* generation". Because line numbers are ordinary text (design.md sec 3), this
* is not a data-structure change at all -- it reads the number off the line
* just ended, works out the next one, and types it.
*
* WHEN IT FIRES. Only when the line just ended STARTS WITH A NUMBER. Follow the
* pattern that is there and nothing else: open a text file that is not a BASIC
* program, press Return, and having "10 " appear would be an act of vandalism.
* Number the first line yourself and every line after it is automatic.
*
* WHICH NUMBER. Ten more than the line just ended, which is why everybody
* numbered by tens in the first place -- the gaps are where inserted lines go.
* If a numbered line FOLLOWS, ten more may already be taken, so it takes the
* midpoint instead: Return between 20 and 30 gives 25. When even the midpoint
* has no room -- 20 and 21 -- it says so and types nothing, because the honest
* answer is that the program needs renumbering and RENUM is not built yet.
*
* SPLITTING A LINE mid-way through gets a number too, on the tail. That is
* deliberate: the tail is about to be a line of its own and a BASIC line
* without a number is not a line. It may well be the wrong number, since the
* text after the cursor is the rest of the split line rather than a following
* line, so nothing can be read from it -- renumbering is the cure.
*--------------------------------------

*--------------------------------------
* AUTONUM -- called from KRETURN once the break itself has gone in
*--------------------------------------
AUTONUM      jsr   LNPREV           ; what was the line we just left?
             bcs   :none            ; not numbered: leave well alone

             lda   LNUM             ; keep it: the arithmetic below needs it
             sta   LNPRV
             lda   LNUM+1
             sta   LNPRV+1

*--- Ask about the line below FIRST. LNFOLL accumulates into LNUM so that it
*    can share LNMUL10, which means it destroys whatever is there -- computing
*    the candidate before this call and expecting to find it afterwards is a
*    silent way to emit line 0.
             jsr   LNFOLL           ; sets LNNXT; CLOBBERS LNUM
             php                    ; and carry says whether there was one

*--- the ordinary answer: ten more than the line just ended
             lda   LNPRV
             clc
             adc   #10
             sta   LNUM
             lda   LNPRV+1
             adc   #$00
             sta   LNUM+1

             plp
             bcs   LNEMIT           ; no line below: nothing to collide with

*--- room for prev+10 below the next line's number?
             lda   LNUM
             cmp   LNNXT
             lda   LNUM+1
             sbc   LNNXT+1
             bcc   LNEMIT           ; LNUM < LNNXT: it fits

*--- no: take the midpoint of prev and next instead
             lda   LNPRV
             clc
             adc   LNNXT
             sta   LNUM
             lda   LNPRV+1
             adc   LNNXT+1
             sta   LNUM+1
             lsr   LNUM+1           ; halve it, 16 bits
             ror   LNUM

*--- and if the midpoint is not actually between them, there is no room at all
             lda   LNPRV
             cmp   LNUM
             lda   LNPRV+1
             sbc   LNUM+1
             bcc   LNEMIT           ; LNPRV < LNUM: a genuine gap

             lda   #<MSGNOROOM
             sta   STRPTR
             lda   #>MSGNOROOM
             sta   STRPTR+1
             jmp   SHOWMSG
:none        rts

*--------------------------------------
* LNEMIT -- type LNUM as decimal, then a space
*
* Straight subtract-and-count against a table of powers, leading zeros
* suppressed, and the units digit always drawn so that line 0 is "0" rather
* than nothing. INSCHR is the same routine the keyboard uses, so the digits
* are inserted exactly as if they had been typed -- CCOL, CURLNO and MODFLAG
* all follow for free.
*--------------------------------------
*--- LNPI is the index into LNPOW and lives in MEMORY, not in X. INSCHR sets
*    MODFLAG through X -- `ldx #$01` -- so X does not survive a call to it, and
*    a loop counter kept there restarts at 1 the moment the first digit is
*    written. That hangs the editor outright. It is the trap already written
*    down in ZipEdit's notes, walked into anyway.
LNEMIT       jsr   LNDIGITS
             lda   #' '+$80         ; and the space after it
             jmp   INSCHR

*--- the digits alone. RENUM wants these without the space, because it is
*    replacing a number that already has whatever follows it.
LNDIGITS     lda   #$00
             sta   LNLEAD
             sta   LNPI

:pow         lda   #$00
             sta   LNDGT
:sub         ldx   LNPI
             lda   LNUM             ; LNUM - power, 16 bits
             sec
             sbc   LNPOW,x
             tay
             lda   LNUM+1
             sbc   LNPOW+1,x
             bcc   :digit           ; went negative: that is the digit
             sta   LNUM+1
             sty   LNUM
             inc   LNDGT
             jmp   :sub

:digit       lda   LNDGT
             bne   :show
             lda   LNLEAD
             bne   :show
             lda   LNPI             ; the units place always prints
             cmp   #8
             bne   :next
:show        lda   #$01
             sta   LNLEAD
             lda   LNDGT
             clc
             adc   #'0'+$80
             jsr   INSCHR
:next        lda   LNPI
             clc
             adc   #$02
             sta   LNPI
             cmp   #10
             bne   :pow
             rts

LNPOW        dw    10000,1000,100,10,1

*--------------------------------------
* LNPREV -- read the leading number of the line that just ended
*
* Carry clear and LNUM set if it had one. GAPBEG points one past the break
* KRETURN inserted, so that break is at GAPBEG-1 and the line runs back from
* there. Everything before the gap is contiguous, so this is a plain walk.
*--------------------------------------
LNPREV       lda   GAPBEG           ; LNEND = the break we just inserted
             sec
             sbc   #$01
             sta   LNEND
             lda   GAPBEG+1
             sbc   #$00
             sta   LNEND+1

             lda   LNEND            ; LNPOS walks back to the line's start
             sta   LNPOS
             lda   LNEND+1
             sta   LNPOS+1

:back        lda   LNPOS+1          ; at the very start of the buffer?
             cmp   #BUFLO
             bne   :peek
             lda   LNPOS
             beq   :read            ; yes: the line starts here

:peek        lda   LNPOS            ; look at the byte BEFORE this one
             sec
             sbc   #$01
             sta   AUXPTR
             lda   LNPOS+1
             sbc   #$00
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO
             bcc   :read            ; a break: the line starts at LNPOS

             lda   AUXPTR           ; step back over it
             sta   LNPOS
             lda   AUXPTR+1
             sta   LNPOS+1
             jmp   :back

*--- LNPOS is the first character of the line, LNEND one past its last
:read        lda   #$00
             sta   LNUM
             sta   LNUM+1
             sta   LNANY

:loop        lda   LNPOS+1          ; reached the end of the line?
             cmp   LNEND+1
             bne   :get
             lda   LNPOS
             cmp   LNEND
             beq   :out

:get         lda   LNPOS
             sta   AUXPTR
             lda   LNPOS+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             jsr   LNDIGIT          ; carry set if it is not a digit
             bcs   :out
             jsr   LNMUL10
             inc   LNANY
             inc   LNPOS
             bne   :loop
             inc   LNPOS+1
             jmp   :loop

:out         lda   LNANY            ; any digits at all?
             bne   :yes
             sec
             rts
:yes         clc
             rts

*--------------------------------------
* LNFOLL -- read the leading number of the line BELOW the cursor
*
* The text after the cursor is contiguous from GAPEND, and the cursor is now
* on a fresh empty line, so GAPEND is where the following line begins. Carry
* clear and LNNXT set if it starts with a number. ACCUMULATES INTO LNUM, which
* it therefore destroys -- see the note in AUTONUM.
*
* After a mid-line split this reads the TAIL of the split line, which will not
* start with a digit, and the answer is correctly "no following number".
*--------------------------------------
LNFOLL       lda   GAPEND
             sta   LNPOS
             lda   GAPEND+1
             sta   LNPOS+1

*--- The cursor is now on a line of its own, and the FIRST thing past the gap
*    is the break that ends it -- not the next line's digits. Step over
*    exactly one. Mid-line the first byte is ordinary text, nothing is
*    skipped, and the parse correctly reports no following number.
             lda   LNPOS+1
             cmp   #BUFHI
             bcs   :init            ; nothing there at all
             lda   LNPOS
             sta   AUXPTR
             lda   LNPOS+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO
             bcs   :init            ; text, not a break: leave it alone
             inc   LNPOS
             bne   :init
             inc   LNPOS+1

:init        lda   #$00
             sta   LNUM
             sta   LNUM+1
             sta   LNANY

:loop        lda   LNPOS+1          ; off the end of the buffer?
             cmp   #BUFHI
             bcs   :out
             lda   LNPOS
             sta   AUXPTR
             lda   LNPOS+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             jsr   LNDIGIT
             bcs   :out
             jsr   LNMUL10
             inc   LNANY
             inc   LNPOS
             bne   :loop
             inc   LNPOS+1
             jmp   :loop

:out         lda   LNUM             ; hand it over under its own name
             sta   LNNXT
             lda   LNUM+1
             sta   LNNXT+1
             lda   LNANY
             bne   :yes
             sec
             rts
:yes         clc
             rts

*--------------------------------------
* LNDIGIT -- carry clear if A is a high-ASCII digit, and A becomes its value
*--------------------------------------
LNDIGIT      cmp   #'0'+$80
             bcc   :no
             cmp   #'9'+$80+1
             bcs   :no
             sec
             sbc   #'0'+$80
             clc
             rts
:no          sec
             rts

*--------------------------------------
* LNMUL10 -- LNUM = LNUM * 10 + A
*
* x2, x4, add the original for x5, x2 again for x10. Cheaper than a divide and
* the only multiply this file needs.
*--------------------------------------
LNMUL10      pha
             lda   LNUM
             sta   LNTMP
             lda   LNUM+1
             sta   LNTMP+1
             asl   LNUM
             rol   LNUM+1           ; x2
             asl   LNUM
             rol   LNUM+1           ; x4
             lda   LNUM
             clc
             adc   LNTMP
             sta   LNUM
             lda   LNUM+1
             adc   LNTMP+1
             sta   LNUM+1           ; x5
             asl   LNUM
             rol   LNUM+1           ; x10
             pla
             clc
             adc   LNUM
             sta   LNUM
             bcc   :done
             inc   LNUM+1
:done        rts

*--- $1450-$14a7 was wrap.S's in ZipEdit and is free here; GEOM begins at
*    $14a8. Started clear of $1451, which file.S's comment claims.
             dum   $1460
LNUM         ds    2                ; the number being read or written
LNPRV        ds    2                ; the line we just left
LNNXT        ds    2                ; the line below, if it has a number
LNTMP        ds    2                ; LNMUL10's scratch
LNEND        ds    2                ; one past the last character of a line
LNPOS        ds    2                ; walking pointer
LNANY        ds    1                ; digits seen, so "no number" is not zero
LNDGT        ds    1                ; the digit being emitted
LNLEAD       ds    1                ; non-zero once a digit has been printed
LNPI         ds    1                ; index into LNPOW; see LNEMIT as to why
                                    ; it is not simply held in X
             dend
