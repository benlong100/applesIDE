*--------------------------------------
* OPS.S -- editing commands this editor needs and ZipEdit's did not
*--------------------------------------

*--------------------------------------
* KQUERY -- "?" expands to PRINT
*
* Applesoft accepts ? as a shorthand for PRINT and stores it as the PRINT
* token, so LIST prints it back as PRINT. Typing ? and getting PRINT is
* therefore not a convenience the editor invented: it is what the machine is
* going to do anyway, done early enough to see.
*
* NOT INSIDE A STRING, and not after a REM. PRINT "?" has to keep its question
* mark, and so does a comment -- Applesoft would not expand either, and an
* editor that did would silently change the program. HNFIND already walks the
* line tracking exactly those two things for the hint row, so this asks it.
*--------------------------------------
KQUERY       jsr   DELSEL           ; typing replaces the selection
             jsr   HNFIND           ; carry set = no keyword on the line
             bcs   :maybe
             lda   HNW
             cmp   #TKREMI
             beq   :literal         ; after REM: it is a comment
:maybe       lda   HNSTR
             bne   :literal         ; inside a string: it is text

             lda   #<KWPRINT
             sta   STRPTR
             lda   #>KWPRINT
             sta   STRPTR+1
             jsr   INSSTR
             jmp   FASTOK           ; one row changed, like ordinary typing

:literal     lda   #'?'+$80
             jsr   INSCHR
             jmp   FASTOK

KWPRINT      asc   "PRINT"
             dfb   $00

*--------------------------------------
* KDELEOL -- delete from the cursor to the end of the line (Ctrl-Y)
*
* DELFWD takes the character after the cursor without moving it, so this is a
* plain loop that stops at the first break. The line count cannot change --
* the break itself is never eaten -- but the row's contents do, so it does not
* opt into the one-row redraw and takes the full one.
*--------------------------------------
KDELEOL      jsr   ATEND
             bcs   :done
             lda   GAPEND
             sta   AUXPTR
             lda   GAPEND+1
             sta   AUXPTR+1
             ldy   #$00
             jsr   AUXRD
             cmp   #TEXTLO
             bcc   :done            ; a break: the line ends here
             jsr   DELFWD
             jmp   KDELEOL
:done        rts
