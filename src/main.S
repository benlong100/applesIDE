*--------------------------------------
* MAIN.S -- START and the main loop, shared by every machine
*
* Split out of edit.S so that a second top-level can build the same editor
* against a different screen and keyboard. What varies between machines is
* which files get PUT, not what the editor does once it is running: the
* geometry comes from a record the screen driver names, and the screen driver
* supplies DISPINIT, CLRSCRN and DRAWLINE.
*
* This must be PUT first, because ProDOS enters at $2000 and START has to be
* the first thing there.
*--------------------------------------

*--------------------------------------
START        lda   #$00             ; nothing remembered about the viewport yet
             sta   TOPOK
             jsr   GEOMINIT         ; the layout's columns first of all: it
                                    ; depends on nothing, and everything that
                                    ; draws depends on it
             lda   #FCHEAT          ; the syntax hint row is ON to begin with.
             sta   FLAGS            ; It is the reason half this editor exists,
                                    ; and a feature nobody finds is no feature;
                                    ; OA-/ turns it off for the extra text row.
             lda   #$00
             sta   SCROLLTOP
             sta   SCROLLTOP+1
             sta   HOFF             ; and the view starts at the left margin
             sta   HOLD

             jsr   UNHOOKRAM        ; claim aux before anything else uses it
             lda   #$e5             ; poison, so tests can see untouched gap
             jsr   AUXFILL
             jsr   INSTSTUB         ; aux read stub into the stack page
             jsr   INITFILE         ; ProDOS parameter blocks into RAM
             jsr   SETPFX           ; ...and a prefix, if nobody left one
             jsr   SELINIT
             lda   #$00
             sta   GOALCOL
             sta   VERTMOVE
             sta   WASVERT
             jsr   BUFINIT

*--- The editor opens on an empty document. It used to plant a sample here,
*    which was useful while the buffer was being built and is just something to
*    delete now. The sample lives on the disk as SAMPLE.MD instead, where it can
*    be opened deliberately -- and where the test suite gets it from.
             jsr   HOMECURSOR
             lda   #$00             ; an empty document is not unsaved work
             sta   MODFLAG

*--- Everything here lives in a dum block or on zero page, so none of it is
*    part of the loaded file and none of it starts at a known value. A cold
*    boot leaves this memory zero and the editor looked correct by luck. Quit
*    to the ProDOS selector and relaunch, and it is whatever that left behind:
*    FNAME's length byte comes back non-zero, so the editor believes the
*    document is already named, prints the garbage as its filename, and OA-S
*    saves to it and fails. KNEW does this for a new document already -- the
*    launch path simply never did the same.
             lda   #$00
             sta   FNAME            ; length 0: no name yet, so OA-S asks
             sta   PLEN             ; nothing collected by a prompt yet
             sta   FINDLEN          ; no search pattern, so OA-G has nothing
             sta   CLIPLEN          ; and nothing on the clipboard to paste
             sta   CLIPLEN+1
             sta   CLIPLINE
             sta   KBHEAD           ; and nothing caught in the ring. These
             sta   KBTAIL           ; live in a dum block, so a relaunch would
                                    ; otherwise start with garbage indices

             jsr   DETECTMT         ; MouseText, or solid blocks instead
             jsr   PLAINIFY         ; which the help screen has to know before
                                    ; it is ever drawn
             jsr   SETMAXROW
             lda   #$00
             sta   MSGSHOWN
             jsr   DISPINIT
             jsr   SPLASH           ; dismissed by any key, before the document
             jsr   DRAWSTATUS
             jsr   STATUPD

*--------------------------------------
* Main loop. Redraw, wait for a key, act on it, repeat.
*
* A full redraw per keystroke is more work than it needs to be, and what it
* costs is the rescan from the buffer start: RENDER counts its way down from
* byte zero every time, so the deeper in the document you are, the longer
* every redraw takes. Timed at 1MHz with the arrow keys, which force a full
* redraw on every press and so measure RENDER and nothing else:
*
*     line 1    218ms per arrow
*     line 64   398ms
*     line 112  553ms
*
* -- a straight line in the bytes above the viewport. That is what the line
* index is for. Measure this with the ARROW keys: an earlier attempt used
* typing, where most keystrokes take the one-row path and never reach RENDER
* at all, and averaged the effect away into "depth does not matter".
*--------------------------------------
MAINLOOP     jsr   SCROLLFIX
             jsr   HSCROLLFIX
             jsr   REDRAW

*--- remember what a one-row redraw is allowed to assume
:keys        lda   #$00
             sta   FASTDRAW
             sta   PARTIAL
             lda   CURLNO
             sta   OLDLINE
             lda   CURLNO+1
             sta   OLDLINE+1

*--- The size of the gap, which is the one thing that says whether the BUFFER
*    changed. Moving the cursor slides both edges together and leaves it
*    alone; an insert or a delete cannot help but alter it. So the redraw
*    below can tell "only the cursor moved" without a single handler having to
*    declare it, which is the difference between fixing this in one place and
*    fixing it in fifteen.
             lda   GAPEND
             sec
             sbc   GAPBEG
             sta   OLDGAP
             lda   GAPEND+1
             sbc   GAPBEG+1
             sta   OLDGAP+1

             lda   SCROLLTOP
             sta   OLDTOP
             lda   SCROLLTOP+1
             sta   OLDTOP+1
             lda   SELACT
             sta   OLDSEL
             lda   VERTMOVE         ; did the last keystroke move vertically?
             sta   WASVERT
             lda   #$00
             sta   VERTMOVE

             jsr   GETKEY

*--- a keystroke retires whatever message was owning the status line
             lda   MSGSHOWN
             beq   :go
             lda   #$00
             sta   MSGSHOWN
             jsr   DRAWSTATUS

:go          jsr   DISPATCH

*--- ZipEdit deferred its hard-wrap tidy-up to here: a burst of typing put
*    breaks off until the writer paused, and this decided which of two reflow
*    walks to run. All of it is gone, because ApplesIDE never wraps -- there is
*    no tidy-up to owe. FLOWOWED, RTFAST and RTFASTALL went with it.
*
*    Worth knowing what was thrown away, in case a future feature wants the
*    shape: the trick was to defer only while the NEXT key is printable, so a
*    command or an arrow got the work done FIRST, before it could move the
*    cursor away and strand the mess. It is a good pattern for anything
*    expensive that a burst of typing would otherwise repeat.

             jsr   SCROLLFIX
             jsr   HSCROLLFIX
             jsr   STATUPD

*--- NOTHING BUT THE CURSOR MOVED?
*
*    Then the screen is already right everywhere except two cells: the one the
*    cursor was on, and the one it is on now. Lifting it off one and putting it
*    on the other is two writes, against RENDER walking the buffer and
*    repainting twenty-three rows -- which is what an arrow key used to cost,
*    and why scrolling up a long program was slow enough to complain about.
*
*    CURSROW and CURSCOL can be computed rather than rendered: the line and
*    column are both maintained, and SCROLLTOP and HOFF have not moved or we
*    would not be here.
             lda   SELACT           ; a selection is a painted region
             ora   OLDSEL
             bne   :notmove
             lda   SCROLLTOP
             cmp   OLDTOP
             bne   :notmove
             lda   SCROLLTOP+1
             cmp   OLDTOP+1
             bne   :notmove
             lda   HOFF
             cmp   HOLD
             bne   :notmove
             lda   MSGSHOWN         ; a message owns a row; let REDRAW have it
             bne   :notmove

             lda   GAPEND           ; the buffer itself unchanged?
             sec
             sbc   GAPBEG
             sta   TMPA
             lda   GAPEND+1
             sbc   GAPBEG+1
             cmp   OLDGAP+1
             bne   :notmove
             lda   TMPA
             cmp   OLDGAP
             bne   :notmove

             jsr   HIDECURSOR
             lda   CURLNO
             sec
             sbc   SCROLLTOP
             sta   CURSROW
             lda   CCOL             ; the difference is always under a screen
             sec                    ; width, so one byte is enough
             sbc   HOFF
             sta   CURSCOL
             jsr   SHOWCURSOR

*--- The hint row still has to follow: moving onto a different keyword is
*    exactly when it should change, and skipping it here would leave it saying
*    whatever was true where the cursor used to be.
             lda   FLAGS
             and   #FCHEAT
             beq   :backj
             jsr   DRAWCHEAT
             jmp   :backj

*--- one row is enough only if the handler opted in AND nothing structural
*    moved. Anything else -- a wrap, a newline, a scroll, a file load -- falls
*    through to the full redraw.
:notmove     lda   SELACT           ; a selection spans rows: repaint the lot
             ora   OLDSEL
             bne   :full
             lda   FASTDRAW
             beq   :full
             lda   CURLNO
             cmp   OLDLINE
             bne   :full
             lda   CURLNO+1
             cmp   OLDLINE+1
             bne   :full
*--- A horizontal jump shifts every row, so it is a full redraw exactly like
*    a vertical scroll. HSCROLLFIX left the old value in HOLD.
*
*    And the one-row path is not merely unnecessary while scrolled, it is
*    WRONG: RENDERROW block-copies the line from its first character and has
*    no notion of HOFF, so it would repaint a scrolled row unscrolled. Any
*    non-zero HOFF takes the full redraw.
             lda   HOFF
             bne   :full
             cmp   HOLD
             bne   :full
             lda   SCROLLTOP
             cmp   OLDTOP
             bne   :full
             lda   SCROLLTOP+1
             cmp   OLDTOP+1
             bne   :full

*--- RENDERROW stages the row through LINEBUF, which is exactly one screen
*    wide, copying CCOL bytes into it from before the gap and GSCRW-CCOL from
*    after. Both of those run off the end of it once the cursor sits further
*    along the line than the screen is wide, and the second one runs off by
*    however far GSCRW-CCOL underflowed -- straight through page 2 and into
*    page 3. Nothing could put the cursor there while every insert was
*    wrap-checked; PASTE can. Over-long lines take the full redraw, which
*    clips at the margin instead of overrunning.
             lda   CCOL+1
             bne   :full
             lda   CCOL
             cmp   GSCRW
             bcs   :full
             jsr   RENDERROW

*--- The hint row belongs to the KEYWORD before the cursor, so it has to be
*    revisited whenever the cursor or the line changes -- which is every
*    keystroke, and most keystrokes come through here rather than through
*    REDRAW. Without this the hint only ever changed on a full redraw, so it
*    showed whatever was true when the row was switched on.
             lda   FLAGS
             and   #FCHEAT
             beq   :backj
             jsr   DRAWCHEAT
:backj       jmp   :keys            ; the cursor-only path pushed :keys out of
                                    ; branch range from here

*--- A wrap rearranges the text below the cursor and cannot touch a line above
*    it, so the rows above the one the cursor started on are already right and
*    RENDER can be told to count them rather than draw them. Everything else --
*    a scroll, a selection, a return, a load -- redraws the lot.
*--- A wrap rearranges the text below the cursor and cannot touch a line above
*    it, so the rows above the one the cursor started on are already right and
*    RENDER can be told to count them rather than draw them. Everything else --
*    a scroll, a selection, a return, a load -- redraws the lot.
:full        lda   SELACT
             ora   OLDSEL
             bne   :all
             lda   PARTIAL
             beq   :all
             lda   SCROLLTOP        ; a scroll moves every row: no shortcut
             cmp   OLDTOP
             bne   :all
             lda   SCROLLTOP+1
             cmp   OLDTOP+1
             bne   :all

             lda   OLDLINE          ; which row was that?
             sec
             sbc   SCROLLTOP
             tax
             lda   OLDLINE+1
             sbc   SCROLLTOP+1
             bne   :all             ; not on screen at all; draw everything
             cpx   MAXROW
             bcs   :all
             stx   RSKIP

:all         jsr   REDRAW
             jmp   :keys

*--------------------------------------
* REDRAW -- text area, cursor, and whichever chrome is showing
*--------------------------------------
REDRAW       jsr   RENDER
             jsr   BLANKTAIL
             jsr   SHOWCURSOR
             lda   FLAGS
             and   #FCHEAT
             beq   :done            ; hidden: row 22 is text, leave it alone
             jmp   DRAWCHEAT
:done        rts

*--------------------------------------
* BLANKTAIL -- clear text rows below the end of the buffer, so deleting a line
*              does not leave its ghost on screen
*--------------------------------------
BLANKTAIL    lda   CURROW
             cmp   MAXROW
             bcs   :done
             pha
             jsr   CLRBUF
             pla
:loop        pha
             jsr   DRAWLINE
             pla
             clc
             adc   #$01
             cmp   MAXROW
             bcc   :loop
:done        rts

*--------------------------------------
* HOMECURSOR -- walk the gap back to the start of the buffer
*
* Deliberately uses the single-byte primitive rather than a bulk move: it
* exercises GAPLEFT across the whole text, so if the shuffle across the gap
* were wrong the rendered screen would show it immediately.
*--------------------------------------
HOMECURSOR   jsr   GAPLEFT
             bcc   HOMECURSOR

*--- The cursor is at the first byte of the buffer, so the column is zero and
*    saying so is cheaper than having walked there correctly. This used to be
*    load-bearing rather than an optimisation: CCOL was one byte, GAPLEFT
*    decrements it per character, and walking back over a line longer than 255
*    wrapped the count around. A file whose lines are whole unwrapped
*    paragraphs arrived with CCOL already past the margin and WRAPALL broke the
*    line at its FIRST character: "**History Duel**" opened as "*" and then
*    "*History Duel**" on the line below.
*
*    The comment here used to add that such a line "cannot happen while
*    editing, since nothing survives longer than the wrap margin". That was
*    wrong: PASTE inserts a whole clipboard between wrap checks and every
*    character of it goes in unwrapped. CCOL is two bytes now, so the count no
*    longer wraps either way, and this remains simply the cheap answer.
             lda   #$00
             sta   CCOL
             sta   CCOL+1
             rts

*--- $1428 is display.S's LASTCOLH; $1429-$142f is otherwise free.
*    FLOWOWED lived at $1429 and went with the deferred reflow.
             dum   $1429
RNUMW        ds    1                ; RENDER: digits in this line's leading
                                    ; number, so the body knows what not to
                                    ; draw over when the view is scrolled
RINNUM       ds    1                ; RENDER: still inside that digit run
             dend

*--- $142b-$142d are display.S's cursor-save; $142e is free.
             dum   $142e
OLDGAP       ds    2                ; gap size before the keystroke
             dend

*--------------------------------------
