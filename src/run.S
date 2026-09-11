*--------------------------------------
* RUN.S -- Ctrl-R: save the program, leave, and run it
*
* The one thing that makes this an environment rather than an editor. Until
* now the loop was: OA-S, OA-Q, choose BASIC.SYSTEM out of the selector, type
* RUN, and then find your way back. This is that, on one key.
*
* CTRL-R RATHER THAN OA-R, which is renumber and stays renumber. Ctrl-R has a
* second merit that decided it: the suite can send it. `vii.sh ctrl R` is an
* ordinary keystroke, where Open-Apple with anything but a letter cannot be
* produced from Virtual ][ at all -- which is why OA-arrows have no test and
* never will. A command this central should not be one that cannot be tested.
*
* WHAT IT DOES NOT DO is come back afterwards. The program runs, ends, and
* leaves you at the ] prompt; `-ASIDE.SYSTEM` returns, with the document still
* on the disk where it was saved. Returning automatically would mean staying
* resident under BASIC, which is a much larger thing than this.
*--------------------------------------
KRUN         lda   FNAME            ; never named? ask, exactly as OA-A does
             bne   :named
             lda   #<MSGSAVE
             sta   STRPTR
             lda   #>MSGSAVE
             sta   STRPTR+1
             jsr   PROMPT
             bcs   :done            ; cancelled: do not save and do not run
             jsr   MKFNAME

*--- A NAME BASIC.SYSTEM CAN BE GIVEN. Its start-up field is a length byte and
*    fifteen characters, and a name with a slash in it would need the prefix
*    moved to match. Neither is worth guessing at: the document is saved
*    either way, and saying so is better than running the wrong thing.
:named       lda   FNAME
             cmp   #$10
             bcs   :toolong
             ldx   FNAME
:slash       lda   FNAME,x
             cmp   #'/'
             beq   :toolong
             dex
             bne   :slash

             jsr   RUNSAVE
             bcs   :done

*--- Take the name away with us. RUNGO writes "BASIC.SYSTEM" over FNAME to
*    open the interpreter, so the document's own name has to be somewhere
*    else by then.
             ldx   FNAME
:keep        lda   FNAME,x
             sta   RUNNAME,x
             dex
             bpl   :keep
             jsr   RSMARK           ; a note to come back by
             jmp   RUNGO

*--- saved, but not runnable from here
:toolong     lda   #$00             ; saved, but nothing is to be run
             sta   RUNNAME
             jsr   RUNSAVE
             bcs   :done
             lda   #<MSGRUNNAME
             sta   STRPTR
             lda   #>MSGRUNNAME
             sta   STRPTR+1
             jmp   SHOWMSG
:done        rts

*--------------------------------------
* RUNSAVE -- write the document out. Carry set if it did not go.
*
* SAVENOW cannot be used: it reports the outcome to the screen and returns
* nothing, which is right for OA-S and useless here, where a failed save must
* stop the launch rather than run whatever was on the disk before.
*--------------------------------------
RUNSAVE      lda   #<MSGSAVING
             sta   STRPTR
             lda   #>MSGSAVING
             sta   STRPTR+1
             jsr   SHOWBUSY
             jsr   SAVEFILE
             bcc   :ok
             lda   TKQUIET          ; the writer already said what was wrong
             bne   :quiet
             jsr   SHOWERR
:quiet       sec
             rts
:ok          jsr   RESTORESTAT
             clc
             rts

*--------------------------------------
* RSMARK / RSLOAD -- come back to the program you ran
*
* Ctrl-R leaves the editor entirely: BASIC.SYSTEM is read over the top of it
* and the program runs. Coming back means launching ApplesIDE again, and
* without this you would come back to an empty document and have to open the
* thing you were just working on.
*
* So Ctrl-R leaves a note. A one-block file naming the document, written
* beside it, read and DELETED on the next start. Deleted because the question
* it answers is "did the last thing that happened here go out to BASIC", and
* that is only true once: quit with OA-Q, or start the editor fresh, and there
* is nothing to come back to.
*
* IT PUTS A FILE ON THE DISK, which is the honest cost. ASIDE.LAST is one
* block, it appears beside the program, and it is gone again the next time the
* editor starts. Keeping the note in memory instead is not possible: a program
* runs in between and BASIC.SYSTEM is loaded over everything.
*--------------------------------------
RSMARK       jsr   RSNAMEIT
             lda   #$04             ; TXT; TOKSAVE leaves this set to $FC
             sta   CREATEPARM+4
             lda   #$00
             sta   CREATEPARM+5
             sta   CREATEPARM+6
             jsr   DESTROYF         ; a missing one is not an error here
             jsr   CREATEF
             bcs   :done
             jsr   OPENF
             bcs   :done
             lda   OPENPARM+5
             sta   WRITEPARM+1
             sta   CLOSEPARM+1
             jsr   RSPARM
             lda   #<WRITEPARM
             sta   RSP
             lda   #>WRITEPARM
             sta   RSP+1
             jsr   WRITEF
             jsr   CLOSEF
:done        rts

*--------------------------------------
* RSLOAD -- if there is a note, open what it names and take it away
*--------------------------------------
RSLOAD       jsr   RSNAMEIT
             jsr   OPENF
             bcs   :none            ; no note: an ordinary empty start
             lda   OPENPARM+5
             sta   READPARM+1
             sta   CLOSEPARM+1
             lda   #<RUNNAME
             sta   READPARM+2
             lda   #>RUNNAME
             sta   READPARM+3
             lda   #$10
             sta   READPARM+4
             lda   #$00
             sta   READPARM+5
             jsr   READF
             jsr   CLOSEF
             jsr   DESTROYF         ; consumed: one launch only

             lda   RUNNAME          ; a name worth going back to?
             beq   :none
             cmp   #$10
             bcs   :none
             ldx   RUNNAME
:cp          lda   RUNNAME,x
             sta   FNAME,x
             dex
             bpl   :cp
             jsr   LOADFILE
             bcc   :done
                                    ; it is gone: fall through and disown it

*--- FNAME IS STILL THE NOTE'S OWN NAME at this point -- RSNAMEIT put it there
*    so the parameter blocks would aim at it. Leaving it is how the editor came
*    up with an empty document called ASIDE.LAST, one OA-S away from saving the
*    writer's work over its own bookkeeping.
:none        lda   #$00
             sta   FNAME
:done        rts

*--- FNAME = the note's own name. Every parameter block points at FNAME, so
*    this is how any of them are aimed at it.
RSNAMEIT     ldx   #RSNEND-RSNAME-1
:nm          lda   RSNAME,x
             sta   FNAME,x
             dex
             bpl   :nm
             rts

RSPARM       lda   #<RUNNAME
             sta   WRITEPARM+2
             lda   #>RUNNAME
             sta   WRITEPARM+3
             lda   #$10
             sta   WRITEPARM+4
             lda   #$00
             sta   WRITEPARM+5
             rts

RSNAME       dfb   10
             asc   'ASIDE.LAST'     ; single quotes: ProDOS wants LOW ascii
RSNEND

             dum   $13f0
RSP          ds    2                ; scratch pointer
             dend
