*--------------------------------------
* REFS.S -- find every line-number reference, and check they exist
*
* The machinery RENUM will need, built first with a consumer that is useful on
* its own: OA-K walks the program and reports the first GOTO, GOSUB, THEN or
* RUN that points at a line which is not there. That is a bug you would
* otherwise meet at run time, with the program half-way through doing
* something.
*
* It is deliberately the same scan RENUM wants. Finding a reference and
* rewriting one differ only in what you do once you have found it, and the
* finding is all of the difficulty: keywords inside strings are not keywords,
* everything after REM is literal, and the number after GOTO may be a list.
*
* TWO PASSES, because a GOTO may point forwards. The first collects every
* line's own number into a table; the second walks again and looks each
* reference up in it.
*
* WHAT IT DOES NOT DO YET
*   - LIST, which takes a range with a hyphen rather than a plain number.
*   - lowercase keywords. Applesoft tokenizes uppercase only, so `goto 10` is
*     not a GOTO to the machine either -- but the editor should eventually say
*     so rather than silently agreeing.
*   - DATA, whose contents are literal in ways this does not model.
*--------------------------------------

*--- MOVED UP FROM $6000 so that the code can have that page range instead.
*    Tokenised files took the binary to within 350 bytes of the old $2000-$5FFF
*    ceiling, and the ceiling was where it was only because $6000 held this
*    table. A thousand lines is a real limit rather than a generous one: an
*    Applesoft program lives in 48K, so a thousand lines is 48 bytes apiece.
RFTAB        equ   $7000            ; line numbers, two bytes each
RFMAX        equ   1000

*--------------------------------------
* KCHECK -- the command behind OA-K
*--------------------------------------
KCHECK       jsr   RFCOLL           ; pass one: every line's own number
             jsr   RFSCAN           ; pass two: every reference
             bcs   :bad

             lda   #<MSGREFOK
             sta   STRPTR
             lda   #>MSGREFOK
             sta   STRPTR+1
             jmp   SHOWMSG

*--- RFLINE is the line the reference sits on, RFWANT what it asked for.
*    RENUM jumps here too, since a program with a dangling reference is
*    exactly the one that must not be renumbered.
:bad
RFREPORT     lda   #$00
             sta   RFMI
             ldx   #$00
:copy        lda   MSGNOLINE,x      ; " LINE " and so on, up to the first $00
             beq   :num1
             sta   MSGBUF,x
             inx
             cpx   #20
             bcc   :copy
:num1        stx   RFMI
             lda   RFLINE
             sta   LNUM
             lda   RFLINE+1
             sta   LNUM+1
             jsr   RFPUTN

             ldx   RFMI             ; " -> "
             lda   #' '+$80
             sta   MSGBUF,x
             inx
             lda   #'-'+$80
             sta   MSGBUF,x
             inx
             lda   #'>'+$80
             sta   MSGBUF,x
             inx
             lda   #' '+$80
             sta   MSGBUF,x
             inx
             stx   RFMI

             lda   RFWANT
             sta   LNUM
             lda   RFWANT+1
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
* RFPUTN -- append LNUM to MSGBUF as decimal, leading zeros suppressed
*
* Same subtract-and-count as LNEMIT, writing to a buffer rather than through
* INSCHR. The index is in memory rather than in X for the same reason it is
* there: nothing here may assume a register survives a call.
*--------------------------------------
RFPUTN       lda   #$00
             sta   RFLEAD
             sta   RFPI
:pow         lda   #$00
             sta   RFDGT
:sub         ldx   RFPI
             lda   LNUM
             sec
             sbc   LNPOW,x
             tay
             lda   LNUM+1
             sbc   LNPOW+1,x
             bcc   :digit
             sta   LNUM+1
             sty   LNUM
             inc   RFDGT
             jmp   :sub
:digit       lda   RFDGT
             bne   :show
             lda   RFLEAD
             bne   :show
             lda   RFPI
             cmp   #8
             bne   :next
:show        lda   #$01
             sta   RFLEAD
             lda   RFDGT
             clc
             adc   #'0'+$80
             ldx   RFMI
             sta   MSGBUF,x
             inc   RFMI
:next        lda   RFPI
             clc
             adc   #$02
             sta   RFPI
             cmp   #10
             bne   :pow
             rts

*--------------------------------------
* RFRESET / RFGET -- walk the whole buffer as one logical string
*
* The gap is the cursor, so the text is in two pieces; this steps over it the
* same way RENDER does. Carry set means the end.
*--------------------------------------
RFRESET      lda   #$00
             sta   RFPTR
             lda   #BUFLO
             sta   RFPTR+1
             rts

RFGET        lda   RFPTR            ; standing at the gap? jump it
             cmp   GAPBEG
             bne   :notgap
             lda   RFPTR+1
             cmp   GAPBEG+1
             bne   :notgap
             lda   GAPEND
             sta   RFPTR
             lda   GAPEND+1
             sta   RFPTR+1
:notgap      lda   RFPTR+1          ; off the end?
             cmp   #BUFHI
             bcs   :end
             lda   RFPTR
             sta   AUXPTR
             lda   RFPTR+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             pha
             inc   RFPTR
             bne   :ok
             inc   RFPTR+1
:ok          pla
             clc
             rts
:end         sec
             rts

*--------------------------------------
* RFCOLL -- pass one: every line's own number into RFTAB
*--------------------------------------
RFCOLL       jsr   RFRESET
             lda   #$00
             sta   RFN
             sta   RFN+1
             lda   #<RFTAB
             sta   RFTP
             lda   #>RFTAB
             sta   RFTP+1

:line        jsr   RFNUMBER         ; read a leading number, if any
             lda   RFANY
             beq   :skip
             jsr   RFSTORE
:skip        lda   RFEOL            ; RFNUMBER stopped where?
             cmp   #$02
             beq   :done            ; end of buffer
             cmp   #$01
             beq   :line            ; end of line: straight on to the next
:rest        jsr   RFGET            ; mid-line: run out to the break
             bcs   :done
             cmp   #TEXTLO
             bcs   :rest
             jmp   :line
:done        rts

*--------------------------------------
* RFSTORE -- append LNUM to RFTAB
*--------------------------------------
RFSTORE      lda   RFN+1            ; table full? drop it on the floor rather
             cmp   #>RFMAX          ; than scribble past $7FFF
             bcc   :ok
             lda   RFN
             cmp   #<RFMAX
             bcs   :full
:ok          ldy   #$00
             lda   LNUM
             sta   (RFTP),y
             iny
             lda   LNUM+1
             sta   (RFTP),y
             lda   RFTP
             clc
             adc   #$02
             sta   RFTP
             bcc   :n
             inc   RFTP+1
:n           inc   RFN
             bne   :full
             inc   RFN+1
:full        rts

*--------------------------------------
* RFNUMBER -- read a run of digits into LNUM
*
* RFANY counts them; RFEOL says why it stopped: 0 a non-digit, 1 a line break,
* 2 the end of the buffer. The caller needs all three apart, or a program
* whose last line has no break loses its final line number.
*--------------------------------------
RFNUMBER     lda   #$00
             sta   LNUM
             sta   LNUM+1
             sta   RFANY
             sta   RFEOL
:loop        jsr   RFGET
             bcc   :got
             lda   #$02             ; end of buffer
             sta   RFEOL
             rts
:got         cmp   #TEXTLO
             bcs   :dig
             lda   #$01             ; a break
             sta   RFEOL
             rts
:dig         jsr   LNDIGIT
             bcs   :stop
             jsr   LNMUL10
             inc   RFANY
             jmp   :loop
:stop        rts                    ; RFEOL still 0: stopped on a non-digit

*--------------------------------------
* RFSCAN -- pass two: every reference, checked against the table
*
* Carry set if one is missing, with RFLINE and RFWANT saying which and what.
*--------------------------------------
RFSCAN       jsr   RFRESET
             lda   #$00
             sta   RNONLY
             sta   RFLINE
             sta   RFLINE+1
             sta   RFBAD
             sta   RFAGAIN

*--- a line begins: its own number first
*--- RFNUMBER stopped ON a character and it is still in A. Save it FIRST:
*    everything below reads memory into A, and this was written three lines
*    later, where A held RFEOL. RFCH2 came out as 0, which is below TEXTLO, so
*    every line's body looked like an immediate end of line and not one
*    keyword was ever seen. Keeping the character matters for its own sake too
*    -- Applesoft allows 10GOTO20 with no space, and losing that byte loses
*    the G.
:line        jsr   RFNUMBER
             sta   RFCH2
             lda   RFANY
             beq   :nonum
             lda   LNUM
             sta   RFLINE
             lda   LNUM+1
             sta   RFLINE+1
:nonum       lda   RFEOL
             cmp   #$02
             beq   :done
             cmp   #$01
             beq   :line

             lda   #$00
             sta   RFSTR            ; a string cannot span a line
             ldx   #RFNKW-1
:clr0        sta   RFHIT,x          ; nor can a half-matched keyword
             dex
             bpl   :clr0
             lda   RFCH2

:body        jsr   RFCLASS
             bcs   :eol
             lda   RFBAD
             bne   :done
             lda   RFAGAIN          ; RFTARGET left one for us to look at again
             beq   :fetch
             lda   #$00
             sta   RFAGAIN
             lda   RFCH2
             jmp   :body
:fetch       jsr   RFGET
             bcc   :body
             jmp   :done

:eol         lda   RFBAD
             bne   :done
             lda   RFEOL2
             cmp   #$02
             beq   :done
             cmp   #$03
             bne   :line

*--- REM. The line is finished but the buffer is not: without this the walk
*    restarts at the character after REM and reads the comment as a new line,
*    so "20 REM GOTO 888" reported a missing line 888.
:remskip     jsr   RFGET
             bcs   :done
             cmp   #TEXTLO
             bcs   :remskip
             jmp   :line

:done        lda   RFBAD
             bne   :bad
             clc
             rts
:bad         sec
             rts

*--------------------------------------
* RFCLASS -- deal with one body character
*
* Carry set to say the line is finished (a break, or REM). This is where the
* rules that make the scan worth writing live: a quote flips in and out of a
* string, keywords do not count inside one, and REM ends the line for good.
*--------------------------------------
RFCLASS      sta   RFCH
             cmp   #TEXTLO          ; a break ends the line
             bcs   :text
             lda   #$01
             sta   RFEOL2
             sec
             rts
:text        lda   #$00
             sta   RFEOL2

             lda   RFCH
             cmp   #$a2              ; a double quote, ditto: written as a value
             bne   :nq
             lda   RFSTR            ; a quote flips the string state
             eor   #$01
             sta   RFSTR
             clc
             rts
:nq          lda   RFSTR
             beq   :code
             clc                    ; inside a string: nothing else counts
             rts

*--- outside a string. Match the keywords one character at a time: RFKW is how
*    far into the current candidate we are, and RFWH which candidate it is.
:code        jsr   RFMATCH
             rts

*--------------------------------------
* RFMATCH -- feed RFCH to the keyword matcher
*
* A rolling match rather than a lookahead, because the walk only goes forwards
* and the gap makes backing up expensive. Every keyword is tried at once: RFHIT
* holds one nibble-per-keyword of "how many characters have matched so far",
* which for five short keywords fits in five bytes and costs one compare each.
*--------------------------------------
RFMATCH      ldx   #$00
:each        lda   RFHIT,x          ; how far into this keyword are we?
             tay
             lda   RFKWT,x          ; where does its text start?
             sta   RFSP
             lda   RFKWT+8,x
             sta   RFSP+1
             lda   (RFSP),y
             cmp   RFCH
             bne   :reset
             iny
             tya
             sta   RFHIT,x
             cmp   RFKWL,x          ; the whole keyword?
             beq   :whole
             jmp   :nextk
:reset       lda   #$00             ; start this one over. If the character we
             sta   RFHIT,x          ; just failed on is the keyword's OWN first
             lda   RFKWT,x          ; letter, it starts again here.
             sta   RFSP
             lda   RFKWT+8,x
             sta   RFSP+1
             ldy   #$00
             lda   (RFSP),y
             cmp   RFCH
             bne   :nextk
             lda   #$01
             sta   RFHIT,x
:nextk       inx
             cpx   #RFNKW
             bcc   :each
             clc                    ; nothing completed
             rts

*--- a whole keyword landed. Clear every candidate and act on it.
:whole       stx   RFWH
             ldx   #RFNKW-1
:clr         lda   #$00
             sta   RFHIT,x
             dex
             bpl   :clr
             ldx   RFWH
*--- RENUM calls this through RNMATCH and wants only the fact of a match, so
*    RFWH is set before anything acts on it.
             lda   RNONLY           ; renumbering? hand it back rather than
             beq   :act             ; chasing the target ourselves
             sec
             rts
:act         lda   RFKWR,x          ; does this one take a line number?
             bne   :takes
             sec                    ; REM: the line is over as far as meaning
             lda   #$03             ; goes -- but NOT as far as the buffer is
             sta   RFEOL2           ; concerned. 3 tells RFSCAN to run on to
             rts                    ; the real break first.
:takes       jmp   RFTARGET

*--------------------------------------
* RFTARGET -- read the line number after a keyword and look it up
*
* Skips spaces, reads a number, and repeats while the separator is a comma so
* that ON X GOTO 10,20,30 is three references and not one. A keyword with no
* number after it is not an error: THEN is followed by a statement as often as
* by a line, and RUN on its own is legal.
*--------------------------------------
RFTARGET     jsr   RFGET
             bcs   :eof
             cmp   #' '+$80         ; skip spaces before the number
             beq   RFTARGET
             cmp   #TEXTLO
             bcc   :eol

             jsr   LNDIGIT
             bcs   :again           ; THEN PRINT, or RUN on its own: fine
             sta   RFD
             lda   #$00
             sta   LNUM
             sta   LNUM+1
             lda   RFD
             jsr   LNMUL10

:more        jsr   RFGET
             bcs   :last
             cmp   #TEXTLO
             bcc   :lasteol
             sta   RFCH2            ; keep it: it may be a comma, or ordinary
             jsr   LNDIGIT
             bcs   :end
             jsr   LNMUL10
             jmp   :more

*--- the number is complete. Check it, then decide what the character that
*    ended it means: a comma starts another (ON X GOTO 10,20,30), anything
*    else goes back to the scanner to be read as an ordinary character.
:end         jsr   RFLOOK
             bcs   :missing
             lda   RFCH2
             cmp   #$ac              ; a comma. Merlin splits operands on commas,
             beq   RFTARGET
:again       sta   RFCH2
             lda   #$01
             sta   RFAGAIN
             clc
             rts

:last        jsr   RFLOOK
             bcs   :missing
:eof         lda   #$02
             sta   RFEOL2
             sec
             rts

:lasteol     jsr   RFLOOK
             bcs   :missing
:eol         lda   #$01
             sta   RFEOL2
             sec
             rts

:missing     lda   #$01
             sta   RFBAD
             lda   #$02
             sta   RFEOL2
             sec
             rts

*--------------------------------------
* RFLOOK -- is LNUM in RFTAB? carry set if not, and RFWANT records it
*
* A linear walk. With a few hundred lines and a few dozen references that is
* well under a second at 1MHz, and a sorted table with a binary search is an
* optimisation to make when something is actually slow.
*--------------------------------------
RFLOOK       lda   LNUM
             sta   RFWANT
             lda   LNUM+1
             sta   RFWANT+1

             lda   #<RFTAB
             sta   RFTP
             lda   #>RFTAB
             sta   RFTP+1
             lda   RFN
             sta   RFI
             lda   RFN+1
             sta   RFI+1

:loop        lda   RFI              ; run out of table?
             ora   RFI+1
             beq   :no
             ldy   #$00
             lda   (RFTP),y
             cmp   RFWANT
             bne   :next
             iny
             lda   (RFTP),y
             cmp   RFWANT+1
             beq   :yes
:next        lda   RFTP
             clc
             adc   #$02
             sta   RFTP
             bcc   :d
             inc   RFTP+1
:d           lda   RFI
             bne   :d1
             dec   RFI+1
:d1          dec   RFI
             jmp   :loop
:yes         clc
             rts
:no          sec
             rts

*--------------------------------------
* The keywords. RFKWT is split into low and high halves eight bytes apart so
* that one X indexes both; RFKWL is each one's length, RFKWR whether it takes
* a line number after it.
*--------------------------------------
RFNKW        equ   5

RFKWT        dfb   <KWGOTO,<KWGOSUB,<KWTHEN,<KWRUN,<KWREM,0,0,0
             dfb   >KWGOTO,>KWGOSUB,>KWTHEN,>KWRUN,>KWREM,0,0,0
RFKWL        dfb   4,5,4,3,3
RFKWR        dfb   1,1,1,1,0        ; REM is the one that takes nothing

KWGOTO       asc   "GOTO"
KWGOSUB      asc   "GOSUB"
KWTHEN       asc   "THEN"
KWRUN        asc   "RUN"
KWREM        asc   "REM"

*--- file.S's block at $0800 ends around $11EA and the editor's own variables
*    start at $1420, so $1200 is free and has room for the message buffer.
*    $1470 does not: forty bytes from there runs into GEOM at $14a8.
*    RFTP and RFSP are NOT here: they are indirect-indexed and so must live on
*    zero page. See equates.S.
*
*    MOVED FROM $1200. file.S lays its buffers out from $0800 and the block
*    grew past $1200 when SETPFX added a prefix buffer -- straight over these,
*    silently, because a dum block is only a promise about addresses and
*    nothing checks two of them do not overlap. The symptom was PRODOS ERROR
*    $40 from a prefix that had been correctly built and then overwritten.
*    Everything here now starts at $1300; $1400 upward is the editor's.
             dum   $1300
RFPTR        ds    2                ; the walk
RFN          ds    2                ; how many lines are in it
RFI          ds    2                ; RFLOOK's countdown
RFLINE       ds    2                ; the line a reference sits on
RFWANT       ds    2                ; and what it asked for
RFANY        ds    1
RFEOL        ds    1                ; why RFNUMBER stopped
RFEOL2       ds    1                ; why RFCLASS stopped
RFCH         ds    1
RFCH2        ds    1                ; a character to be looked at again
RFAGAIN      ds    1                ; ...and whether there is one
RFSTR        ds    1                ; inside a string literal
RFWH         ds    1                ; which keyword matched
RFBAD        ds    1                ; a reference went nowhere
RFD          ds    1
RFMI         ds    1                ; write index into MSGBUF
RFLEAD       ds    1
RFDGT        ds    1
RFPI         ds    1
RNONLY       ds    1                ; RENUM wants the match, not the action
RFHIT        ds    8                ; per-keyword progress
MSGBUF       ds    40
             dend
