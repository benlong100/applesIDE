*--------------------------------------
* ASIDE.S -- ApplesIDE for the Enhanced Apple //e
*
* The 80-column build: auxiliary-memory program buffer, MouseText where the
* machine has it, and the Open-Apple command set.
*
* The engine below the keymap is ZipEdit's, brought over module for module:
* the gap buffer, the screen drivers, ProDOS file I/O, the prompt and help
* machinery, and the geometry record that keeps column numbers out of the
* code. What is NOT here is wrap.S, and that absence is the whole design.
* ZipEdit hard-wraps on entry so that one logical line is always one screen
* row; breaking a line is free in prose because Markdown renders a single
* newline as a space. Breaking an Applesoft line changes the program. So
* ApplesIDE keeps the same one-line-per-row invariant by the opposite means:
* it never breaks, and scrolls sideways instead.
*
* ProDOS truncates a filename at fifteen characters, and APPLESIDE.SYSTEM is
* sixteen -- it would land as APPLESIDE.SYSTE, stop looking like a .SYSTEM
* file, and never auto-launch. Hence ASIDE.SYSTEM, which also happens to read
* as a word.
*--------------------------------------
             org   $2000
             typ   $ff
             dsk   ASIDE.SYSTEM

             put   equates
             put   main             ; START first: ProDOS enters at $2000
             put   screen80         ; the machine-specific half of the display
             put   auxbuf
             put   keysiie
             put   keyboard
             put   file
             put   column           ; where wrap.S sits in ZipEdit, and does not here
             put   lineno           ; automatic line numbers
             put   refs             ; line-number references, and OA-K
             put   renum            ; OA-R, which needs refs
             put   scroll
             put   select
             put   unbuilt          ; the work queue; see the header
             put   help
             put   helpdata         ; the Makefile picks the language
             put   lang             ; the Makefile picks the language
             put   splash
             put   buffer
             put   display
             put   machine
             put   geom
