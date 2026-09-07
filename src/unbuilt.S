*--------------------------------------
* UNBUILT.S -- the work queue, as code
*
* Every label here is a key handler the engine's keymaps still refer to and
* ApplesIDE has not written yet. They are `rts` so that the thing builds and
* boots, which is worth far more right now than a complete keymap.
*
* THIS FILE IS MEANT TO SHRINK TO NOTHING. As each handler is written it moves
* to a real module and its stub comes out of here. When the file is empty the
* editor is feature-complete against the engine it was cut from, and the file
* should be deleted rather than kept as an empty monument.
*
* Deliberately NOT silent-by-accident: a stub that quietly returns looks
* exactly like a bug once there is enough working code to be confused by it.
* Anything still here at the point where the editor feels usable should be
* given a "not yet" message instead, so a key that does nothing says so.
*
*   from ZipEdit's edit_ops.S -- wanted, and mostly portable as-is
* KFIND KFINDNEXT   search. The wrap logic is worth taking whole; it was only
*                   fixed in ZipEdit 1.4 and the two bugs it flushed out
*                   (OA-G never advancing, and the end-of-buffer match) are
*                   not ones to reintroduce by retyping it from memory.
* KGOTO             go to line. Means something different here: a BASIC line
*                   NUMBER, not an ordinal. Wants rewriting, not copying.
* KCOPY KCUT KPASTE clipboard, line-oriented. Portable.
* KDELEOL           delete to end of line. Portable.
*                   (KDELWORD is NOT here: keyboard.S defines it already.)
*
*   from ZipEdit's edit_ops.S -- Markdown, and NOT wanted
* KBOLD KITALIC     emphasis. There is no such thing in Applesoft. These
*                   stubs exist only because the shared keymaps still name
*                   them, and they go when the keymaps are rewritten.
*
*   from ZipEdit's wrap.S -- deliberately absent
* WRAPCHECK         hard wrap on entry, which is the one thing a BASIC editor
*                   must never do: breaking a line changes the program. Kept
*                   as a no-op so keyboard.S's self-insert path still links,
*                   and it should end up DELETED rather than implemented.
*--------------------------------------

*--- These are bound to keys, so pressing one and getting silence is
*    indistinguishable from a bug -- which the header above predicted and
*    real hardware confirmed. They say so now.
KFIND
FINDNEXT
KGOTO
KCOPY
KCUT
KPASTE
KDELEOL      lda   #<MSGNOTYET
             sta   STRPTR
             lda   #>MSGNOTYET
             sta   STRPTR+1
             jmp   SHOWMSG

*--- Markdown emphasis, which Applesoft has no notion of. Silent on purpose:
*    these are not "not yet", they are "never", and they go when the keymaps
*    are rewritten for this machine rather than inherited from ZipEdit.
KBOLD
KITALIC      rts

*--- not a stub so much as a decision: see above. Called on every keystroke,
*    so it must stay silent.
WRAPCHECK    rts
KWORDL       rts
KWORDR       rts
WRAPALL      rts
REFLOW       rts
