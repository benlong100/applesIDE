*--------------------------------------
* TOK.S -- read and write real Applesoft files
*
* Until now the editor saved plain ProDOS TXT, and Applesoft answers RUN on a
* TXT file with FILE TYPE MISMATCH. An Applesoft editor that cannot produce a
* file Applesoft will run is doing the main job badly, so this writes type $FC:
* a memory image from $801, which is what SAVE writes and RUN expects.
*
* THE FORMAT, taken off the machine rather than remembered. Applesoft was made
* to save a four-line program and the bytes read back:
*
*   0801: next=0807 line=10  | 97                          HOME
*   0807: next=0815 line=20  | BA 22 48 49 22 3A B2 20 58  PRINT"HI":REM X
*   0815: next=0822 line=30  | 41 D0 E1 28 31 29 C8 32     A=ATN(1)+2
*   0822: next=082A line=40  | AB 31 30                    GOTO10
*   082A: 00 00                                            end of program
*
* Each line is: the address of the NEXT line, the line number, the tokens, and
* a zero. A next-address of zero ends the program. Three things in there are
* not what one would guess:
*
*   - SPACES OUTSIDE STRINGS ARE DROPPED. "A = ATN (1) + 2" stores as
*     41 D0 E1 28 31 29 C8 32 with not one space in it. Keeping them would
*     make a file that runs but does not match what Applesoft would have
*     written, and would grow every program.
*   - THE OPERATORS ARE TOKENS. = is $D0 and + is $C8. They are not reserved
*     WORDS and the highlighter rightly ignores them, but a tokeniser that
*     ignored them would write a different program.
*   - TEXT IS STORED HIGH BIT CLEAR. Tokens are $80-$EA, so the high bit is
*     what tells them apart. The editor's buffer is high ASCII throughout, so
*     every literal character is masked on the way out and set on the way in.
*
* After REM, and inside a string, everything is literal -- spaces included.
*--------------------------------------

LNBUF        equ   $7800            ; one line of source, as typed
TOKBUF       equ   $7900            ; and the same line as Applesoft stores it
BASADDR      equ   $0801            ; where an Applesoft program lives

*--------------------------------------
* TOKSAVE -- write the program as type $FC
*
* Carry set on failure, with a message already shown.
*--------------------------------------
*--- Check EVERY line has a number BEFORE going near the file. The refusal
*    used to happen half way through writing -- after DESTROY had already
*    removed the previous version -- so a program the editor would not save
*    also took the last good copy of itself with it.
TOKSAVE      lda   #$00
             sta   TKQUIET
             jsr   TKCHECK
             bcc   :numok
             lda   #<MSGNEEDNUM
             sta   STRPTR
             lda   #>MSGNEEDNUM
             sta   STRPTR+1
             jsr   SHOWMSG
             lda   #$01             ; SAVENOW must not draw over this
             sta   TKQUIET
             sec
             rts

*--- NOT called :ok. There was already a :ok further down, Merlin resolved the
*    branch above to whichever it liked, and TKCHECK's verdict was silently
*    discarded: TKADDR read back as $0801, so the write had begun on a program
*    that had just been declared unsavable.
:numok       lda   #$fc             ; BAS, not TXT
             sta   CREATEPARM+4
             lda   #<BASADDR        ; aux type is the load address
             sta   CREATEPARM+5
             lda   #>BASADDR
             sta   CREATEPARM+6

             jsr   DESTROYF         ; a missing file is not an error here
             jsr   CREATEF
             bcc   :made
             jmp   :fail            ; :fail is out of branch range from here
:made        jsr   OPENF
             bcc   :open
             jmp   :fail
:open        lda   OPENPARM+5
             sta   WRITEPARM+1
             sta   CLOSEPARM+1

             lda   #<BASADDR
             sta   TKADDR
             lda   #>BASADDR
             sta   TKADDR+1
             jsr   RFRESET

*--- The LAST line of the buffer has no break after it, so TKREAD hands it
*    back WITH the end-of-buffer flag. Testing that flag first threw the line
*    away, and a program saved from the editor was short by its last line --
*    which is also, always, the line just written. The same shape of mistake
*    as RENDER's, and made twice in one project.
:line        jsr   TKREAD           ; one line of source into LNBUF
             lda   TKLL             ; a blank line carries nothing
             beq   :nextq

             jsr   TKONE            ; LNBUF -> TOKBUF+4, length in TKBL
             bcc   :ok
             jmp   :nonum

*--- A NUMBER WITH NOTHING AFTER IT IS NOT A LINE. Return supplies the next
*    number before there is anything to put on it, so a program written here
*    ends with one every time -- and it was being saved, and LISTed back in
*    Applesoft as a bare number sitting under the program.
*
*    Applesoft cannot make such a line itself: typing a number alone at the ]
*    prompt DELETES that line, so an empty numbered line is an artefact of
*    this editor and of nothing else. Dropping it is what makes the file look
*    like one Applesoft would have written.
*
*    TKBL counts the body, and TKONE has already dropped the spaces outside
*    strings, so "50" and "50   " both arrive here as zero and both go.
:ok          lda   TKBL
             bne   :body
             jmp   :nextq
:body

*--- The next line begins four bytes of header, the body, and a zero further
*    on. Add the whole offset in ONE 16-bit step.
*
*    This was `adc #$05` followed straight by `adc TKBL`, with no clc between
*    them, and the two adds are not independent: the carry out of TKADDR+5 was
*    added AGAIN as part of the second, and then lost before it could reach the
*    high byte. So whenever a line began at $xxFB or later the pointer came out
*    one too low and a page too low -- 257 bytes short.
*
*    It only bites where a line happens to start in the last five bytes of a
*    page, which is about one line in fifty: a four-line test program never
*    crosses one, a 343-line program does it seven times. And the editor could
*    not see it, because loading walks the bodies sequentially and never
*    follows these pointers. Applesoft does nothing else BUT follow them, so
*    the file read back perfectly here and was rubble there.
*
*    TKBL is at most 248, so the offset always fits in a byte.
             lda   TKBL
             clc
             adc   #$05
             sta   TKT1
             lda   TKADDR
             clc
             adc   TKT1
             sta   TOKBUF
             lda   TKADDR+1
             adc   #$00
             sta   TOKBUF+1
             lda   TOKBUF           ; and that is where we will be
             sta   TKADDR
             lda   TOKBUF+1
             sta   TKADDR+1

             lda   LNUM
             sta   TOKBUF+2
             lda   LNUM+1
             sta   TOKBUF+3
             ldx   TKBL
             lda   #$00
             sta   TOKBUF+4,x

             lda   TKBL             ; header + body + terminator
             clc
             adc   #$05
             jsr   TKWRITE
             bcc   :nextq
             jmp   :failed

*--- and only now ask whether there is any more
:nextq       lda   TKEOF
             cmp   #$02
             beq   :end
             jmp   :line

*--- the end of the program is a next-address of zero
:end         lda   #$00
             sta   TOKBUF
             sta   TOKBUF+1
             lda   #$02
             jsr   TKWRITE
             bcc   :shut
             jmp   :failed
:shut        jsr   CLOSEF
             lda   #$00
             sta   MODFLAG
             clc
             rts

*--- TKCHECK has already ruled this out, so reaching it means the two
*    disagree. Close the file and report rather than write half a program.
:nonum       jsr   CLOSEF
             lda   #<MSGNEEDNUM
             sta   STRPTR
             lda   #>MSGNEEDNUM
             sta   STRPTR+1
             jsr   SHOWMSG
             lda   #$01
             sta   TKQUIET
             sec
             rts

:failed      jsr   CLOSEF
:fail        jsr   SHOWERR
             sec
             rts

*--------------------------------------
* TKCHECK -- carry set if any line with text on it has no leading number
*
* A tokenised file has a number on every line and nowhere to put one that has
* not; inventing one would put statements somewhere the writer never asked for.
*--------------------------------------
TKCHECK      jsr   RFRESET
:loop        jsr   TKREAD
             lda   TKLL
             beq   :next            ; a blank line is nothing to save
             lda   LNBUF
             jsr   LNDIGIT
             bcs   :bad
:next        lda   TKEOF
             cmp   #$02
             beq   :ok
             jmp   :loop
:ok          clc
             rts
:bad         sec
             rts

*--------------------------------------
* TKWRITE -- write A bytes of TOKBUF
*--------------------------------------
TKWRITE      sta   WRITEPARM+4
             lda   #$00
             sta   WRITEPARM+5
             lda   #<TOKBUF
             sta   WRITEPARM+2
             lda   #>TOKBUF
             sta   WRITEPARM+3
             jmp   WRITEF

*--------------------------------------
* TKREAD -- the next line of source into LNBUF, length in TKLL
*
* TKEOF says why it stopped: 1 a line break, 2 the end of the buffer. Reading
* the line out whole first is what makes the tokeniser simple -- matching a
* keyword needs to look forward, and looking forward through the gap does not.
*--------------------------------------
TKREAD       lda   #$00
             sta   TKLL
             sta   TKEOF
             sta   TKIST            ; 0 = still in the leading number
:loop        jsr   RFGET
             bcc   :got
             lda   #$02
             sta   TKEOF
             rts
:got         cmp   #TEXTLO
             bcs   :keep
             lda   #$01             ; a break ends the line
             sta   TKEOF
             rts

*--- INDENTATION IS NOT PART OF THE LINE, and this is where that has to be
*    said, because of the cap below. An Applesoft line is 239 characters and
*    the rest is DROPPED -- so counting the spaces that indent a FOR body
*    would push a long line over and take real code off the end of it on the
*    way to disk. Silent truncation, in a save.
*
*    The spaces between the number and the code are dropped here instead.
*    TKONE drops every space outside a string anyway, so nothing downstream
*    can tell the difference, and the cap now applies to what the line
*    actually says.
:keep        sta   TKRC
             lda   TKIST
             cmp   #$02
             beq   :store           ; in the body: everything counts
             cmp   #$01
             beq   :sp

             lda   TKRC             ; still a digit of the line number?
             cmp   #$b0
             bcc   :numend
             cmp   #$ba
             bcc   :store
:numend      lda   #$01
             sta   TKIST

:sp          lda   TKRC
             cmp   #$a0
             beq   :loop            ; a space here is indentation: drop it
             lda   #$02
             sta   TKIST

:store       ldx   TKLL
             cpx   #$f0             ; an Applesoft line is 239 at the most;
             bcs   :loop            ; drop the rest rather than overrun
             lda   TKRC
             sta   LNBUF,x
             inc   TKLL
             jmp   :loop

*--------------------------------------
* TKONE -- tokenise LNBUF into TOKBUF+4
*
* Carry set if the line has no leading number. LNUM gets the number, TKBL the
* length of what was written.
*--------------------------------------
TKONE        lda   #$00
             sta   TKI2
             sta   TKBL
             sta   TKSTR
             sta   TKREM2
             sta   TKDATA
             sta   LNUM
             sta   LNUM+1
             sta   TKANY2

*--- the line number
:num         ldx   TKI2
             cpx   TKLL
             bcs   :numdone
             lda   LNBUF,x
             jsr   LNDIGIT
             bcs   :numdone
             jsr   LNMUL10
             inc   TKANY2
             inc   TKI2
             jmp   :num
:numdone     lda   TKANY2
             bne   :skipsp
             sec                    ; no number: the caller reports it
             rts

*--- Applesoft drops the space between the number and the first token, so the
*    editor's own "10 HOME" and a machine's "10HOME" store identically.
:skipsp      ldx   TKI2
             cpx   TKLL
             bcc   :sp2
             jmp   :done            ; :done is out of branch range from here
:sp2         lda   LNBUF,x
             cmp   #' '+$80
             bne   :body
             inc   TKI2
             jmp   :skipsp

*--- the statements
:body        ldx   TKI2
             cpx   TKLL
             bcc   :b2
             jmp   :done
:b2          lda   LNBUF,x

             ldy   TKREM2           ; after REM everything is literal
             bne   :litj
             ldy   TKDATA
             bne   :indata          ; and so is everything in a DATA
             ldy   TKSTR            ; and the inside of a string
             beq   :code
             cmp   #$a2             ; ...up to the closing quote
             bne   :litj
             lda   #$00
             sta   TKSTR
:litj        jmp   :lit             ; a trampoline: :lit is past every test
                                    ; below it

*--------------------------------------
* Inside a DATA.
*
* APPLESOFT DOES NOT TOKENISE HERE AND NEITHER MUST THIS. Read off a file it
* wrote: 10 DATA 144,-4,BOSTON is stored as <83> and then the characters, with
* the minus as a plain $2D and BOSTON untouched -- no ON token inside it. This
* editor was tokenising both, so a program with DATA -4 saved to a file that
* gave ?SYNTAX ERROR on READ, and DATA BOSTON came back as BOST and a stray
* token. It round-tripped through the editor unharmed, because the reader
* expanded the same tokens again; only Applesoft ever saw the damage.
*
* THE SPACES STAY TOO. Everywhere else a space outside a string is dropped,
* because Applesoft drops it. In a DATA it keeps it -- DATA HELLO WORLD is
* stored with the space, and it is part of the value.
*
* A COLON ENDS IT, and what follows is code again: DATA A:PRINT 1 stores the
* colon and then the PRINT token. A colon inside quotes does not -- DATA
* "A:B",C:PRINT 2 ends at the second one. All four rules read off the bytes of
* a file Applesoft saved, not recalled.
*--------------------------------------
:indata      ldy   TKSTR
             beq   :dopen
             cmp   #$a2             ; the closing quote
             bne   :litj
             lda   #$00
             sta   TKSTR
             jmp   :litj
:dopen       cmp   #$a2             ; an opening quote
             bne   :dcolon
             lda   #$01
             sta   TKSTR
             lda   LNBUF,x
             jmp   :litj
:dcolon      cmp   #':'+$80
             bne   :litj
             lda   #$00             ; the DATA ends here; the colon itself is
             sta   TKDATA           ; stored and the rest is code again
             lda   LNBUF,x
             jmp   :litj

:code        cmp   #$a2             ; an opening quote
             bne   :nq
             lda   #$01
             sta   TKSTR
             lda   LNBUF,x
             jmp   :lit
:nq          cmp   #' '+$80         ; spaces outside strings are not stored
             bne   :kw
             inc   TKI2
             jmp   :body

*--- a keyword?
:kw          jsr   TKMATCH
             bcs   :op
             ldx   TZKW             ; its token byte
             lda   TKTOK,x
             jsr   TKEMIT
             lda   TZKW
             cmp   #TKREMI
             bne   :nrem
             lda   #$01             ; REM: the rest of the line is a comment
             sta   TKREM2
             jmp   :adv
:nrem        cmp   #TKDATAI
             bne   :adv
             lda   #$01             ; DATA: the rest is values, up to a colon
             sta   TKDATA
:adv         lda   TKI2
             clc
             adc   TKL2
             sta   TKI2
             jmp   :body

*--- one of the nine operators?
:op          ldx   #$00
             lda   LNBUF,x
:opl         lda   TKOPC,x
             clc
             adc   #$80             ; the table is low ASCII; the buffer is high
             sta   TKCMP
             ldy   TKI2
             lda   LNBUF,y
             cmp   TKCMP
             beq   :ophit
             inx
             cpx   #TKOPN
             bcc   :opl
             ldy   TKI2             ; an ordinary character
             lda   LNBUF,y
             jmp   :lit2
:ophit       lda   TKOPT,x
             jsr   TKEMIT
             inc   TKI2
             jmp   :body

*--- literal: the buffer is high ASCII and a token file is not
:lit         ldx   TKI2
             lda   LNBUF,x
:lit2        and   #$7f
             jsr   TKEMIT
             inc   TKI2
             jmp   :body

:done        clc
             rts

*--------------------------------------
* TKEMIT -- append A to TOKBUF+4
*--------------------------------------
TKEMIT       ldx   TKBL
             cpx   #$f8
             bcs   :full
             sta   TOKBUF+4,x
             inc   TKBL
:full        rts

*--------------------------------------
* TKMATCH -- does a keyword start at LNBUF+TKI2?
*
* Carry clear, TZKW its index and TKL2 its length. The same first-letter
* dispatch the highlighter uses, over the same table, longest first -- so ATN
* is found before AT here too.
*--------------------------------------
TKMATCH      ldx   TKI2
             lda   LNBUF,x
             cmp   #$c1
             bcc   :no
             cmp   #$db
             bcs   :no
             sec
             sbc   #$c1
             tay
             lda   TKCOUNT,y
             beq   :no
             sta   TKC2
             lda   TKFIRST,y
             sta   TZKW

:try         ldx   TZKW
             lda   TKLEN,x
             sta   TKL2
             lda   TKLO,x
             sta   TKP
             lda   TKHI,x
             sta   TKP+1
             ldy   #$00
:cmp         cpy   TKL2
             beq   :yes
             tya
             clc
             adc   TKI2
             cmp   TKLL             ; must fit inside the line
             bcs   :fail
             tax
             lda   LNBUF,x
             cmp   (TKP),y
             bne   :fail
             iny
             bne   :cmp
:fail        inc   TZKW
             dec   TKC2
             bne   :try
:no          sec
             rts
:yes         clc
             rts

*--------------------------------------
* TOKLOAD -- read a type $FC file back into the buffer
*
* The reverse: each token becomes its keyword, each other byte becomes itself
* with the high bit set, and a line becomes its number, a space, and the lot.
*
* A space goes after an alphabetic keyword only when a letter or digit follows
* it, so GOTO 10 reads as GOTO 10 and PRINT"HI" is not padded out. Applesoft's
* own LIST puts a space on both sides of every token and prints " 30 A =  ATN
* (1) + 2", which is not what anybody typed either.
*--------------------------------------
TOKLOAD      lda   #$00
             sta   TKDROP
             sta   TKDEPTH
             jsr   TKRINIT
             jmp   :line

*--- The indent pushed :done out of branch range from the top of the loop, so
*    the branches go through here. It must be JUMPED OVER rather than fallen
*    into: put in the path above, it closed the file before a byte was read
*    and every program loaded as nothing at all.
:endj        jmp   :done
:line        jsr   TKRB             ; the next-line address
             bcs   :endj
             sta   TKT1
             jsr   TKRB
             bcs   :endj
             ora   TKT1
             beq   :endj            ; a zero address ends the program

             jsr   TKRB             ; the line number
             bcs   :endj
             sta   LNUM
             jsr   TKRB
             bcs   :endj
             sta   LNUM+1
             jsr   LNDIGITS         ; straight into the text buffer
             lda   #' '+$80
             jsr   TKPUT

*--- INDENT THE BODY BY ITS FOR NESTING.
*
*    Applesoft cannot store indentation: the tokeniser drops every space
*    outside a string, so anything typed is gone by the next save. Writing the
*    spaces into the FILE is not the way round it either -- a tokenised line
*    whose body begins with a literal space LISTs correctly and then fails
*    with ?SYNTAX ERROR when run. Tried, on the machine, before this was
*    written.
*
*    So it is DERIVED rather than stored, here, where the tokens are already
*    in hand and it costs nothing: no extra pass, no gap moves, and it comes
*    back the same on every load because it is computed from the program
*    rather than remembered about it.
*
*    A line beginning with NEXT closes a level, so the first body byte has to
*    be looked at BEFORE the indent is written -- hence the peek.
             lda   #$00
             sta   TKNF
             sta   TKNN
             sta   TKLEAD

             jsr   TKRB
             bcs   :endj
             sta   TKFB
             cmp   #$82             ; NEXT
             bne   :ind
             inc   TKLEAD
             lda   TKDEPTH
             beq   :ind
             dec   TKDEPTH

*--- THE COUNT LIVES IN MEMORY. TKPUT jumps to INSCHR, and INSCHR sets MODFLAG
*    through X -- so a depth counted in X comes back as 1 from every call and
*    every indented line gets exactly one level, whatever its nesting. Which
*    is what happened, and it is the second time this trap has been walked
*    into on this codebase; it is written down in the notes of both projects.
:ind         lda   TKDEPTH
             beq   :first
             sta   TKIC
:sp          lda   #' '+$80
             jsr   TKPUT
             lda   #' '+$80
             jsr   TKPUT
             dec   TKIC
             bne   :sp

:first       lda   TKFB             ; the byte the peek took
             jmp   :have

:byte        jsr   TKRB
             bcs   :done
:have        cmp   #$00
             beq   :eol
             cmp   #$80
             bcs   :token
             cmp   #$20
             bcc   :ctrl            ; see below
             ora   #$80             ; a literal, back to the editor's high ASCII
             jsr   TKPUT
             jmp   :byte

*--- A CONTROL CHARACTER CANNOT LIVE IN THE BUFFER. Every byte under $A0 is a
*    line break here -- that is the whole of how lines are stored -- so a $0A
*    read out of a program arrives as $8A and splits the line in two.
*
*    Real programs do this: REM lines with embedded line feeds, so that LIST
*    double-spaces. PHONE.LIST has forty of them. Loading one turned
*    "400 REM<0A><0A>SET PRINTER SLOT" into five lines, three with no number,
*    and the editor then refused to save the result because a line without a
*    number is not an Applesoft line.
*
*    They are dropped, and the loader says how the file differs from what is
*    on disk. Keeping them would need an escape in the buffer and a column
*    count that lies; silently rewriting the program without saying so is
*    worse than either.
:ctrl        inc   TKDROP
             bne   :byte
             dec   TKDROP           ; saturate rather than wrap to none
             jmp   :byte

:token       cmp   #$81             ; FOR opens a level
             bne   :nfor
             inc   TKNF
             bne   :emit            ; always taken
:nfor        cmp   #$82             ; NEXT closes one
             bne   :emit
             inc   TKNN
:emit        jsr   TKTEXT           ; write the keyword out
             jmp   :byte

*--- What this line did to the nesting. The leading NEXT, if there was one,
*    has already been taken off, so it must not be counted twice.
:eol         lda   TKNN
             sec
             sbc   TKLEAD
             sta   TKT2
             lda   TKDEPTH
             clc
             adc   TKNF
             sec
             sbc   TKT2
             bpl   :dcap
             lda   #$00             ; more NEXTs than FORs: the floor
:dcap        cmp   #$09             ; and a ceiling, so a program with runaway
             bcc   :dset            ; nesting does not indent off the screen
             lda   #$08
:dset        sta   TKDEPTH

             lda   #HARDCR
             jsr   INSCHR
             jmp   :line

:done        jmp   CLOSEF

*--------------------------------------
* TKTEXT -- write the keyword whose token byte is in A
*
* A linear search of the two tables rather than an index by token value. 107
* compares against a saving of three hundred bytes, once per token in a file
* that is loaded once: the wrong way round to optimise.
*--------------------------------------
TKPUT        sta   TKPREV
             jmp   INSCHR

*--- carry clear if A is a letter or a digit, high ASCII
TKALNUM      cmp   #$b0
             bcc   :no
             cmp   #$ba
             bcc   :yes
             cmp   #$c1
             bcc   :no
             cmp   #$db
             bcs   :no
:yes         clc
             rts
:no          sec
             rts

TKTEXT       sta   TKT2
             ldx   #$00
:find        lda   TKTOK,x
             cmp   TKT2
             beq   :got
             inx
             cpx   #TKN
             bcc   :find

*--- not a word: one of the operators, which are their own single character
             ldx   #$00
:oper        lda   TKOPT,x
             cmp   TKT2
             beq   :opgot
             inx
             cpx   #TKOPN
             bcc   :oper
             rts                    ; unknown token: drop it rather than guess
:opgot       lda   TKOPC,x
             ora   #$80
             jmp   TKPUT

:got         stx   TZKW
             lda   TKPREV           ; 2THENGOSUB is valid and unreadable
             jsr   TKALNUM
             bcs   :nolead
             lda   #' '+$80
             jsr   TKPUT
:nolead      ldx   TZKW
             lda   TKLEN,x
             sta   TKL2
             lda   TKLO,x
             sta   TKP
             lda   TKHI,x
             sta   TKP+1
             ldy   #$00
:emit        cpy   TKL2
             beq   :spc
             lda   (TKP),y
             sty   TKY2
             jsr   TKPUT
             ldy   TKY2
             iny
             bne   :emit

*--- REM swallows the rest of the line, so the reader must too or the comment
*    comes back tokenised
:spc         lda   TZKW
             cmp   #TKREMI
             bne   :peek
             lda   #$01
             sta   TKREM3
             rts

*--- a space only where the next byte would otherwise run into the keyword
:peek        jsr   TKPEEK
             bcs   :nospc
             cmp   #$30             ; a digit
             bcc   :nospc
             cmp   #$3a
             bcc   :yes
             cmp   #$41             ; or a letter
             bcc   :nospc
             cmp   #$5b
             bcs   :nospc
:yes         lda   #' '+$80
             jmp   TKPUT
:nospc       rts

*--------------------------------------
* The file reader: MLI hands over a block at a time and this doles it out.
*--------------------------------------
TKRINIT      lda   #$00
             sta   TKRN
             sta   TKRI
             sta   TKREM3
             rts

TKRB         lda   TKREM3           ; inside a REM, tokens are just characters
             beq   :go
             lda   #$00
             sta   TKREM3
:go          lda   TKRI
             cmp   TKRN
             bcc   :have
             jsr   TKFILL
             bcs   :eof
:have        ldx   TKRI
             lda   DATBUF,x
             inc   TKRI
             clc
             rts
:eof         sec
             rts

*--- one byte ahead, without taking it
TKPEEK       lda   TKRI
             cmp   TKRN
             bcc   :have
             jsr   TKFILL
             bcs   :eof
:have        ldx   TKRI
             lda   DATBUF,x
             clc
             rts
:eof         sec
             rts

TKFILL       lda   #<DATBUF
             sta   READPARM+2
             lda   #>DATBUF
             sta   READPARM+3
*--- 255, not 256. A full block comes back with a transfer count of $0100,
*    and TKRN is one byte: it would take the low half, read zero, and report
*    an empty file. The template in file.S says the same thing for the same
*    reason and I asked for 256 anyway.
             lda   #$ff
             sta   READPARM+4
             lda   #$00
             sta   READPARM+5
             jsr   READF
             bcs   :none
             lda   READPARM+7       ; transfer count, high byte
             bne   :some
             lda   READPARM+6
             beq   :none
:some        lda   READPARM+6
             sta   TKRN
             lda   #$00
             sta   TKRI
             clc
             rts
:none        sec
             rts

             dum   $1390
TKADDR       ds    2                ; where the line being written will live
TKBL         ds    1                ; bytes of tokenised body so far
TKLL         ds    1                ; length of the source line in LNBUF
TKEOF        ds    1                ; why TKREAD stopped
TKI2         ds    1                ; index into LNBUF
TKSTR        ds    1                ; inside a string
TKDATA       ds    1                ; inside a DATA, writing
TKREM2       ds    1                ; after a REM, writing
TKREM3       ds    1                ; after a REM, reading
TKANY2       ds    1                ; digits in the line number
TZKW         ds    1                ; keyword index
TKL2         ds    1                ; and its length
TKC2         ds    1                ; candidates left
TKCMP        ds    1
TKT1         ds    1
TKT2         ds    1
TKY2         ds    1
TKRN         ds    1                ; bytes in DATBUF
TKRI         ds    1                ; and how many have been handed out
TKPREV       ds    1                ; the last character written out
TKQUIET      ds    1                ; the failure has already been reported
TKDROP       ds    1                ; control characters the buffer cannot hold
TKIST        ds    1                ; TKREAD: 0 number, 1 indent, 2 body
TKRC         ds    1                ; the character it is deciding about
TKDEPTH      ds    1                ; FOR nesting, for the indent on load
TKNF         ds    1                ; FORs on this line
TKNN         ds    1                ; and NEXTs
TKLEAD       ds    1                ; the line began with one, already counted
TKFB         ds    1                ; first body byte, peeked before indenting
TKIC         ds    1                ; indent levels left to write
             dend
