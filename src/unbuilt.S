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

KFIND        rts
FINDNEXT     rts
KGOTO        rts
KCOPY        rts
KCUT         rts
KPASTE       rts
KDELEOL      rts
KBOLD        rts
KITALIC      rts

*--- not a stub so much as a decision: see above.
WRAPCHECK    rts
KWORDL       rts
KWORDR       rts
WRAPALL      rts
REFLOW       rts
