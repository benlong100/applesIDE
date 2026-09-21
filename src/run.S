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
KRUN         jsr   RUNPREP          ; name it, check it, save it
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
:done        rts

*--------------------------------------
* KCOMPILE -- OA-B: save, leave, and compile
*
* The same shape as Ctrl-R and for the same reason: the compiler reads the
* document off the disk, so it has to be on the disk first, and named. What
* differs is where we go and what we say on the way -- the compiler is handed
* the name at $0380 rather than being asked for it, and nothing is named to
* BASIC.SYSTEM because we are not going there.
*
* THE NOTE IS LEFT AS USUAL. If the program is refused the compiler comes back
* here, and RSLOAD finds the note and reopens the document at the top -- so
* the line the complaint named is a GOTO away rather than an OPEN away.
*--------------------------------------
KCOMPILE     jsr   RUNPREP
             bcs   :cdone

             lda   #HANDMAGIC
             sta   HANDOFF
             ldx   FNAME
             stx   HANDOFF+1
:hc          lda   FNAME,x
             sta   HANDOFF+1,x
             dex
             bne   :hc

*--- THE NOTE IS WRITTEN FROM RUNNAME, so the document's name has to be in it
*    when RSMARK runs. Zeroing it first -- which is what the launcher wants --
*    wrote a note naming nothing, and coming back would have opened nothing.
             ldx   FNAME
:keep        lda   FNAME,x
             sta   RUNNAME,x
             dex
             bpl   :keep
             jsr   RSMARK

             lda   #$00             ; and NOW nothing for the launcher to name:
             sta   RUNNAME          ; the compiler is not BASIC.SYSTEM
             jmp   CCGO
:cdone       rts

*--------------------------------------
* CCGO -- load the compiler over us and enter it
*
* RUNGO's own body, given a different name to open. The stub it copies to
* $0300 reads RUNNAME and writes it into $2006 only when it has a length, and
* KCOMPILE leaves that at zero -- $2006 is BASIC.SYSTEM's start-up field and
* means nothing to the compiler, which would be a poor place to write.
*--------------------------------------
CCGO         ldx   #CCNEND-CCNAME-1
:name        lda   CCNAME,x
             sta   FNAME,x
             dex
             bpl   :name
             jmp   RUNGO2

CCNAME       dfb   14
             asc   'ASIDECC.SYSTEM' ; single quotes: ProDOS wants LOW ascii
CCNEND

*--------------------------------------
* RUNPREP -- name the document, check the name is usable, and save it
*
* Carry set means do not go: cancelled at the prompt, unusable name, or a save
* that did not happen. Factored out of KRUN when OA-B wanted the same three
* steps -- a launch that proceeds on an unsaved document runs whatever was on
* the disk before, which is the one outcome worth ruling out twice.
*--------------------------------------
RUNPREP      lda   FNAME            ; never named? ask, exactly as OA-A does
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

             jmp   RUNSAVE          ; its carry is ours

*--- saved, but not runnable from here. CARRY SET ON THE WAY OUT: this is a
*    "do not go" answer, and it used to end in a JMP whose carry was whatever
*    the message printer happened to leave. That was harmless while KRUN was
*    the only caller and fell straight to an RTS; it is not harmless now that
*    the answer is read.
:toolong     lda   #$00             ; saved, but nothing is to be run
             sta   RUNNAME
             jsr   RUNSAVE
             bcs   :done
             lda   #<MSGRUNNAME
             sta   STRPTR
             lda   #>MSGRUNNAME
             sta   STRPTR+1
             jsr   SHOWMSG
:done        sec
             rts

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
