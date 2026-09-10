#!/bin/bash
# tests/run.sh -- ApplesIDE's regression suite, driven through Virtual ][.
#
# Built after a first run on real hardware turned up three bugs in one sitting,
# two of which the emulator would have shown instantly had anyone asked it. The
# cases below are, deliberately, the ones that have actually gone wrong:
# scrolled strings, REM, ATN against AT, renumbering with references, and the
# refusal to renumber a broken program. A suite of cases nobody has ever seen
# fail tests mostly that the code compiles.
#
# INVERSE VIDEO CANNOT BE READ FROM THE SCREEN TEXT. Virtual ][ reports an
# inverse character and a normal one identically, so every keyword-highlighting
# assertion here reads the text page out of emulated RAM instead: bytes below
# $80 are inverse. See `hlrow`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VII="$ROOT/tools/vii.sh"
IMAGE="${IMAGE:-$ROOT/build/APPLESIDE.po}"
DISTIMG="${DISTIMG:-$ROOT/build/APPLESIDE-DIST.po}"
BIN="${BIN:-$ROOT/build/ASIDE.SYSTEM}"

# One suite at a time. Virtual ][ has exactly one front machine, so a second
# run -- or a stray boot from another window -- steers the machine out from
# under the first, and what comes back is a scatter of failures in sections
# nothing touched. ZipEdit lost three runs to this in a day.
LOCK="${TMPDIR:-/tmp}/applesIDE-suite.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    other="$(cat "$LOCK/pid" 2>/dev/null)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "another test run (pid $other) holds the emulator" >&2
        exit 2
    fi
    echo "clearing a stale lock from pid ${other:-unknown}" >&2
    rm -rf "$LOCK"
    mkdir "$LOCK" || { echo "cannot take $LOCK" >&2; exit 2; }
fi
echo "$$" > "$LOCK/pid"
TMP="$(mktemp -d)"
trap 'rm -rf "$LOCK" "$TMP"' EXIT INT TERM

SCRW=80
HSTEP=16          # must match src/equates.S

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; fail=$((fail+1)); }

ONLY="${1:-}"
section() {
    case "$1" in
        *"$ONLY"*) echo; echo "$1"; return 0 ;;
        *)         return 1 ;;
    esac
}

#--------------------------------------
# Driving the machine
#--------------------------------------
SCREEN="$TMP/screen.txt"
snapshot() { "$VII" screen-raw > "$SCREEN"; }

# reboot -- a fresh machine with an empty program, caps off, hint row as the
# editor starts it. Every section sets up its own text: there is no fixture
# document on the disk, because a program that renumbers and rewrites itself
# would poison one for every later section.
reboot() {
    local tries
    for tries in 1 2 3; do
        "$VII" boot "$IMAGE" >/dev/null || { echo "boot failed"; exit 1; }
        "$VII" await "ApplesIDE" 120 >/dev/null || continue
        "$VII" text " " >/dev/null
        "$VII" await "UNTITLED.BAS" 60 >/dev/null || continue
        "$VII" caps false >/dev/null
        "$VII" settle 3 >/dev/null
        return 0
    done
    echo "the editor never reached an empty document after 3 boots"; exit 1
}

# type <text> -- and wait for the machine to stop moving
t() { "$VII" text "$1" >/dev/null; "$VII" settle 4 >/dev/null; }
# a line, then Return. Return auto-numbers, so callers that want their own
# number delete what it supplied first -- see `numbered`.
tl() { "$VII" line "$1" >/dev/null; "$VII" settle 3 >/dev/null; }

# numbered <digits-to-drop> <text> -- Return supplies a number, we take it out
# and type our own. The count is how many characters it inserted, digits plus
# the space after them.
numbered() {
    "$VII" line "" >/dev/null; "$VII" settle 2 >/dev/null
    local i; for i in $(seq 1 "$1"); do "$VII" del >/dev/null; done
    "$VII" text "$2" >/dev/null; "$VII" settle 3 >/dev/null
}

oa() { "$VII" caps true >/dev/null; "$VII" oa "$1" >/dev/null; "$VII" settle 5 >/dev/null; "$VII" caps false >/dev/null; }

#--------------------------------------
# Assertions
#--------------------------------------
# row <0-based> -- one line of the screen, trailing blanks trimmed
row() { sed -n "$(($1+1))p" "$SCREEN" | sed 's/ *$//'; }

assert_row() {
    local name="$1" r="$2" want="$3" got; got="$(row "$r")"
    if [[ "$got" == *"$want"* ]]; then ok "$name"
    else bad "$name" "row $r wanted: $want" "row $r got:    $got"; fi
}

assert_notrow() {
    local name="$1" r="$2" nope="$3" got; got="$(row "$r")"
    if [[ "$got" != *"$nope"* ]]; then ok "$name"
    else bad "$name" "row $r should NOT contain: $nope" "row $r got: $got"; fi
}

status() { sed -n '24p' "$SCREEN"; }
assert_col() {
    local name="$1" want="$2" got
    got="$(status | sed 's/.*C:\([0-9]*\).*/\1/')"
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "column $got, wanted $want"; fi
}

# hlrow <0-based row> -- the text page for that row, and which cells are
# INVERSE, as two parallel strings. 80-column text is interleaved: even cells
# in the aux bank, odd in main, both at $400 with the usual row scramble.
# Inverse screen codes are below $80; normal high-ASCII text is $A0 and up.
hlrow() {
    local r="$1"
    "$VII" dump 0x0400 0x400 1 "$TMP/aux.bin" >/dev/null
    "$VII" dump 0x0400 0x400 0 "$TMP/main.bin" >/dev/null
    python3 - "$TMP/aux.bin" "$TMP/main.bin" "$r" <<'PY'
import sys
aux = open(sys.argv[1],'rb').read(); main = open(sys.argv[2],'rb').read()
r = int(sys.argv[3]); off = (r % 8) * 0x80 + (r // 8) * 0x28
cells = []
for c in range(40):
    cells.append(aux[off+c]); cells.append(main[off+c])
print(''.join(chr((b & 0x7f) | 0x40) if b < 0x40 else chr(b & 0x7f) for b in cells).rstrip())
print(''.join('^' if b < 0x80 else ' ' for b in cells).rstrip())
PY
}

# assert_inverse <name> <row> <word> -- is that word drawn inverse?
# Finds the word in the row's text and checks every one of its cells.
assert_inverse() {
    local name="$1" r="$2" word="$3" want="${4:-yes}" out txt inv i n
    out="$(hlrow "$r")"; txt="$(echo "$out" | sed -n '1p')"; inv="$(echo "$out" | sed -n '2p')"
    # hlrow strips the inverse line's trailing spaces, so a row with NOTHING
    # inverse hands back an empty string and every slice of it is empty --
    # which read as a failure even when the answer was right. Pad it back out.
    printf -v inv '%-*s' "${#txt}" "$inv"
    local before="${txt%%$word*}"
    if [ "$before" = "$txt" ]; then
        bad "$name" "'$word' is not on row $r at all" "row: $txt"; return
    fi
    i=${#before}; n=${#word}
    local slice="${inv:$i:$n}" expect
    if [ "$want" = "yes" ]; then expect="$(printf '^%.0s' $(seq 1 $n))"
    else expect="$(printf ' %.0s' $(seq 1 $n))"; fi
    if [ "$slice" = "$expect" ]; then ok "$name"
    else bad "$name" "'$word' at cell $i wanted [$expect] got [$slice]" "row: $txt" "inv: $inv"; fi
}

echo "ApplesIDE suite -- $(basename "$IMAGE")"
[ -f "$IMAGE" ] || { echo "no image at $IMAGE -- run: make disk" >&2; exit 1; }

# IS THE IMAGE THE BINARY WE JUST BUILT? Checked FIRST, and fatally.
#
# Virtual ][ buffers writes to a mounted image and flushes them when the disk
# is ejected, so an image the emulator is holding can be quietly overwritten
# with an older copy of itself after being rebuilt. Everything then runs
# against code that is not the code on disk -- and the failures look like
# ordinary bugs, so you fix things that are already fixed. That cost two wrong
# diagnoses in a row before anyone thought to compare the two files.
#
# It was checked before, in the last section of the suite. The end of a
# twenty-minute run is no use: by then every result above it is worthless.
if [ -f "$BIN" ]; then
    "$ROOT/tools/ac" -g "$IMAGE" ASIDE.SYSTEM > "$TMP/onimage.bin" 2>/dev/null
    if cmp -s "$TMP/onimage.bin" "$BIN"; then
        ok "the image carries the binary that was just built"
    else
        bad "the image carries the binary that was just built" \
            "image: $(stat -f%z "$TMP/onimage.bin" 2>/dev/null || echo 0) bytes" \
            "build: $(stat -f%z "$BIN") bytes" \
            "the emulator has probably flushed a stale copy over it." \
            "eject in Virtual ][, then: rm -f $IMAGE && make disk"
        echo
        echo "stopping: every result below this would be about the wrong code." >&2
        echo "$pass passed, $fail failed"
        exit 1
    fi
fi

#--------------------------------------
if section "it boots"; then
reboot
snapshot
assert_row "the status row names the untitled program" 23 "UNTITLED.BAS"
assert_row "and reports free memory"                   23 "FREE"
assert_row "and the free memory it has"                23 "46K FREE"
t '10 HOME'
snapshot
assert_row "typing reaches the buffer"                  0 "10 HOME"
assert_col "and the column follows it"                  8

# The figure was static text in the layout for the whole project's life: it
# read 46K with a fifteen-kilobyte program loaded. An empty buffer is exactly
# 46K, so any content at all has to move it.
assert_notrow "and typing moves the free figure"       23 "46K FREE"
fi

#--------------------------------------
# Return supplies the next number. Every case here has been wrong at some
# point: the emit loop hung the editor, the value came out as 0, and an
# insert between two lines produced a duplicate.
#--------------------------------------
if section "automatic line numbers"; then
reboot
t '10 HOME'
tl ''
t 'PRINT 1'
tl ''
t 'END'
snapshot
assert_row "the first line keeps its number"            0 "10 HOME"
assert_row "Return supplies the next"                   1 "20 PRINT 1"
assert_row "and the next"                               2 "30 END"

# between two lines, the midpoint rather than a duplicate
"$VII" caps true >/dev/null; "$VII" oa "<" >/dev/null; "$VII" settle 5 >/dev/null
"$VII" ctrl E >/dev/null; "$VII" settle 3 >/dev/null; "$VII" caps false >/dev/null
tl ''
snapshot
assert_row "inserting between 10 and 20 gives 15"       1 "15"
assert_row "and 20 is still there"                      2 "20 PRINT 1"

# and where no whole number is free, it says so rather than guessing
reboot
t '10 A'
numbered 3 '11 B'
"$VII" caps true >/dev/null; "$VII" oa "<" >/dev/null; "$VII" settle 5 >/dev/null
"$VII" ctrl E >/dev/null; "$VII" settle 3 >/dev/null; "$VII" caps false >/dev/null
tl ''
snapshot
assert_row "between 10 and 11 there is no room, and it says so" 23 "NO FREE LINE NUMBER"
fi

#--------------------------------------
# Long lines scroll sideways rather than wrapping, and the line number stays
# pinned. Both the cursor cell and the pinned region have been wrong.
#--------------------------------------
if section "long lines scroll"; then
reboot
t '10 FOR I=1 TO 9: PRINT I;: NEXT I: REM PADDING TO PUSH THIS WELL PAST COLUMN EIGHTY'
snapshot
assert_row "the number stays pinned when the view scrolls"  0 "10>"
assert_notrow "and the start of the line has scrolled away" 0 "10 FOR"

"$VII" ctrl A >/dev/null; "$VII" settle 5 >/dev/null
snapshot
assert_row "Ctrl-A brings the view home"                    0 "10 FOR I=1 TO 9"
assert_notrow "and the scroll marker goes with it"          0 "10>"

# an edit while scrolled must land where the cursor appears to be
"$VII" ctrl E >/dev/null; "$VII" settle 5 >/dev/null
for _i in 1 2 3 4 5 6; do "$VII" key "left arrow" >/dev/null; done
"$VII" settle 3 >/dev/null
t '#'
snapshot
assert_row "an insert while scrolled lands at the cursor"   0 "#EIGHTY"
fi

#--------------------------------------
# Keywords drawn inverse. Read from the text page, since the screen text
# cannot tell inverse from normal.
#--------------------------------------
if section "keywords are inverse"; then
reboot
t '10 HOME'
tl ''
t 'FOR I=1 TO 9'
tl ''
t 'X = AT 5 + ATN(1)'
"$VII" settle 5 >/dev/null
assert_inverse "HOME is a keyword"          0 "HOME"
assert_inverse "FOR is a keyword"           1 "FOR"
assert_inverse "so is TO"                   1 "TO"
assert_inverse "but I is a variable"        1 "I=1" no
# ATN before AT: longest match, which Applesoft needs a special case for.
# The bare AT comes FIRST on the line on purpose -- assert_inverse finds the
# first occurrence of what it is given, so searching for AT with ATN earlier
# would land inside ATN, and searching for "AT " would demand the trailing
# space be inverse too, which it correctly is not.
assert_inverse "a bare AT is a keyword"     2 "AT"
assert_inverse "and ATN matches as one word" 2 "ATN"
fi

#--------------------------------------
# Strings and REM. THE SCROLLED CASE IS THE BUG REAL HARDWARE FOUND: the
# string state was recorded only where a cell is drawn, so an opening quote
# scrolled off the left edge stopped protecting anything.
#--------------------------------------
if section "strings and REM are not code"; then
reboot
t '10 PRINT "GOTO": HOME'
"$VII" settle 5 >/dev/null
assert_inverse "PRINT outside the quotes is a keyword"  0 "PRINT"
assert_inverse "GOTO inside them is not"                0 "GOTO" no
assert_inverse "and HOME after the close is again"      0 "HOME"

reboot
t '20 REM HOME AND PRINT'
"$VII" settle 5 >/dev/null
assert_inverse "REM itself is a keyword"                0 "REM"
assert_inverse "but nothing after it is"                0 "HOME" no

# the hardware bug, exactly as reported
reboot
t '10 PRINT "AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC DDDDDDDDDD EEEEEEEEEE FFFFFFFFFF GGGGGGG'
"$VII" settle 5 >/dev/null
t ' HOME GOTO PRINT'
"$VII" settle 6 >/dev/null
assert_inverse "an open string still protects HOME once scrolled"  0 "HOME" no
assert_inverse "...and GOTO"                                       0 "GOTO" no
assert_inverse "...and PRINT"                                      0 "PRINT" no
fi

#--------------------------------------
if section "syntax hints"; then
reboot
t '10 PRINT '
snapshot
assert_row "the hint row is on from the start"      22 "PRINT"
t 'X: FOR I'
snapshot
assert_row "and follows to the newest keyword"      22 "FOR v=a TO b"
t '=1 TO 9'
snapshot
assert_row "and holds while the arguments are typed" 22 "TO"

# OA-/ cycles normal -> inverse -> off -> normal. A tester lost the row among
# the code, so inverse earns its place: the check is on the screen bytes, since
# the emulator's screen TEXT reads the same either way.
reboot
t '10 PRINT '
snapshot
assert_inverse "the hint row starts out normal"     22 "PRINT" no
oa /
snapshot
assert_inverse "OA-/ once draws it inverse"         22 "PRINT" yes
assert_row "and it still says what it said"         22 "PRINT"
oa /
snapshot
got="$(row 22)"
if [ -z "${got// /}" ]; then ok "twice turns it off"
else bad "twice turns it off" "row 22 should be blank, got: $got"; fi
oa /
snapshot
assert_inverse "three times is back to normal"      22 "PRINT" no
assert_row "with the hint text again"               22 "PRINT"
fi

#--------------------------------------
if section "? types PRINT"; then
reboot
t '10 ?"HI"'
snapshot
assert_row "a bare ? becomes PRINT"                 0 "10 PRINT"
reboot
t '10 REM ? STAYS'
snapshot
assert_row "after REM it does not"                  0 "REM ? STAYS"
reboot
t '10 ? "A ? INSIDE"'
snapshot
assert_row "nor inside a string"                    0 "PRINT \"A ? INSIDE\""
fi

#--------------------------------------
if section "delete to end of line"; then
reboot
t '10 PRINT "HELLO"'
"$VII" ctrl A >/dev/null; "$VII" settle 3 >/dev/null
for _i in $(seq 1 8); do "$VII" key "right arrow" >/dev/null; done
"$VII" settle 3 >/dev/null
"$VII" ctrl Y >/dev/null; "$VII" settle 4 >/dev/null
snapshot
assert_row "Ctrl-Y clears from the cursor"          0 "10 PRINT"
assert_notrow "and takes the rest with it"          0 "HELLO"
fi

#--------------------------------------
# OA-K. It once reported ALL REFERENCES OK while checking nothing at all,
# which is why the first case here is a program known to be broken.
#--------------------------------------
if section "reference check"; then
reboot
t '10 GOTO 999'
numbered 3 '20 END'
oa "K"
snapshot
assert_row "a GOTO to nowhere is reported"          23 "NO SUCH LINE: 10 -> 999"

reboot
t '10 PRINT "GOTO 999"'
numbered 3 '20 REM GOTO 888'
numbered 3 '30 GOSUB 10'
numbered 3 '40 ON X GOTO 10,20,30'
oa "K"
snapshot
assert_row "quotes, REM, GOSUB and a list all pass" 23 "ALL LINE REFERENCES OK"

reboot
t '10 REM'
numbered 3 '20 ON X GOTO 10,20,777'
oa "K"
snapshot
assert_row "every element of a list is checked"     23 "NO SUCH LINE: 20 -> 777"
fi

#--------------------------------------
if section "renumber"; then
reboot
t '100 HOME'
numbered 4 '200 GOSUB 500'
numbered 4 '300 IF X THEN 100'
numbered 4 '500 RETURN'
oa "R"
snapshot
assert_row "lines become 10, 20, 30, 40"            0 "10 HOME"
assert_row "a GOSUB follows its line"               1 "20 GOSUB 40"
assert_row "and so does a THEN"                     2 "30 IF X THEN 10"
assert_row "the last line lands on 40"              3 "40 RETURN"

# numbers that GROW, plus a comment and a string that must not move
reboot
t '1 REM GOTO 999'
numbered 3 '2 PRINT "GOTO 3"'
numbered 3 '3 ON X GOTO 1,2,3'
numbered 3 '4 END'
oa "R"
snapshot
assert_row "one digit grows to two"                 0 "10 REM"
assert_row "a comment keeps its number"             0 "GOTO 999"
assert_row "so does a string"                       1 "20 PRINT \"GOTO 3\""
assert_row "and a whole list is remapped"           2 "30 ON X GOTO 10,20,30"

# and it refuses a program it would silently corrupt
reboot
t '100 GOTO 999'
numbered 4 '200 END'
oa "R"
snapshot
assert_row "a broken program is refused"            23 "NO SUCH LINE: 100 -> 999"
assert_row "and nothing is renumbered"              0 "100 GOTO 999"
fi

#--------------------------------------
# Tokenised files. The whole point of the editor: a saved program must be one
# Applesoft will RUN. Asserted against the FILE, not the screen -- the bytes
# are what BASIC.SYSTEM reads, and a screen that looks right proves nothing
# about them.
#--------------------------------------
if section "tokenised files"; then
reboot
t '10 HOME'
tl ''
t 'PRINT "HI":REM X'
tl ''
t 'A = ATN(1) + 2'
tl ''
t 'GOTO 10'
oa "S"
"$VII" await "SAVE AS" 30 >/dev/null || bad "the save prompt never appeared"
"$VII" text "TOKTEST" >/dev/null; "$VII" line "" >/dev/null; "$VII" settle 10 >/dev/null

# flush the emulator's buffered writes before reading the image on the Mac
osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1
sleep 2

info="$("$ROOT/tools/ac" -l "$IMAGE" 2>/dev/null | grep -i '^  TOKTEST')"
case "$info" in
    *BAS*) ok "the file is type BAS, not TXT" ;;
    "")    bad "the file is type BAS, not TXT" "TOKTEST is not on the image at all" ;;
    *)     bad "the file is type BAS, not TXT" "$info" ;;
esac
case "$info" in
    *'A=$0801'*) ok "and loads at \$801, where Applesoft lives" ;;
    *)           bad "and loads at \$801, where Applesoft lives" "$info" ;;
esac

"$ROOT/tools/ac" -g "$IMAGE" TOKTEST > "$TMP/tok.bin" 2>/dev/null
python3 - "$TMP/tok.bin" > "$TMP/tok.txt" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
i, addr, out = 0, 0x801, []
while i < len(d) - 1:
    nxt = d[i] | (d[i+1] << 8)
    if nxt == 0: break
    ln = d[i+2] | (d[i+3] << 8); j = i + 4; body = []
    while j < len(d) and d[j] != 0: body.append(d[j]); j += 1
    out.append(f"{ln}:" + ' '.join(f'{b:02X}' for b in body))
    addr = nxt; i = j + 1
print('\n'.join(out))
PYEOF

# Applesoft's own bytes for the same program, taken off the machine and
# written down in src/tok.S. HOME is one token; the operators are tokens too.
tokline() { grep "^$1:" "$TMP/tok.txt" | cut -d: -f2- | sed 's/^ //'; }
[ "$(tokline 10)" = "97" ]     && ok "HOME is the single token \$97"     || bad "HOME is the single token \$97" "got: $(tokline 10)"
[ "$(tokline 20)" = "BA 22 48 49 22 3A B2 20 58" ]     && ok "a string and a REM keep their text, spaces and all"     || bad "a string and a REM keep their text, spaces and all" "got: $(tokline 20)"
[ "$(tokline 30)" = "41 D0 E1 28 31 29 C8 32" ]     && ok "spaces are dropped and = and + are tokens"     || bad "spaces are dropped and = and + are tokens" "got: $(tokline 30)"
[ -n "$(tokline 40)" ]     && ok "the LAST line is written, having no break after it"     || bad "the LAST line is written, having no break after it" "line 40 is missing"

# and back again
reboot
oa "O"
"$VII" await "OPEN" 30 >/dev/null || bad "the open prompt never appeared"
"$VII" text "TOKTEST" >/dev/null; "$VII" line "" >/dev/null; "$VII" settle 10 >/dev/null
snapshot
assert_row "it reads back its own file"          0 "10 HOME"
assert_row "and the cursor lands at the TOP"    23 "L:1 "
assert_row "a string and comment survive"        1 "20 PRINT\"HI\":REM X"
assert_row "and the spacing Applesoft stores"    2 "30 A=ATN(1)+2"
assert_row "a keyword gets a space before a digit" 3 "40 GOTO 10"

# a line with no number cannot become an Applesoft line
reboot
t 'HOME'
oa "S"
"$VII" await "SAVE AS" 30 >/dev/null
"$VII" text "NONUM" >/dev/null; "$VII" line "" >/dev/null; "$VII" settle 8 >/dev/null
snapshot
assert_row "an unnumbered line is refused"      23 "EVERY LINE NEEDS A NUMBER"
fi

#--------------------------------------
# Leaving, and coming back. Both directions were broken: quitting landed in a
# file picker with the screen still in 80-column mode, and returning left no
# ProDOS prefix, so every relative filename failed with $40.
#
# Needs BASIC.SYSTEM, so it runs against the DIST image rather than the plain
# build one.
#--------------------------------------
# A LONG program, saved and then checked the way Applesoft reads it -- by
# following the next-line pointers, not by walking the bodies.
#
# That distinction is the whole section. The editor loads by walking bodies,
# so a file with a broken pointer chain looks perfect here and is rubble to
# BASIC -- which is exactly how this shipped: "if I load the program into the
# ide, everything looks good, if I try to run the program... the data appears
# corrupted to the applesoft interpreter."
#
# The fault only shows where a line happens to begin in the last five bytes of
# a page, about one line in fifty. Every short test program in this suite
# crosses no page boundary at all.
#--------------------------------------
if section "long programs"; then
python3 - "$TMP/long.bas" <<'PYEOF'
import sys
# Varied line lengths, so line starts land all over the page.
lines = []
for i in range(1, 221):
    pad = "X" * (i % 37)
    lines.append((i * 10, f'PRINT "L{i}{pad}": FOR J=1 TO 9: NEXT J'))
out = bytearray(); addr = 0x801
TOK = {"PRINT": 0xBA, "FOR": 0x81, "NEXT": 0x82, "TO": 0xC1, "=": 0xD0}
for n, text in lines:
    body = bytearray(); i = 0
    while i < len(text):
        for kw, t in TOK.items():
            if text.startswith(kw, i): body.append(t); i += len(kw); break
        else:
            if text[i] != " ": body.append(ord(text[i]))
            i += 1
    nxt = addr + 5 + len(body)
    out += bytes([nxt & 0xFF, nxt >> 8, n & 0xFF, n >> 8]) + body + b"\x00"
    addr = nxt
out += b"\x00\x00"
open(sys.argv[1], "wb").write(bytes(out))
PYEOF
"$ROOT/tools/ac" -d "$IMAGE" LONG >/dev/null 2>&1
"$ROOT/tools/ac" -p "$IMAGE" LONG BAS 0x0801 < "$TMP/long.bas"

reboot
oa "O"
"$VII" await "OPEN:" 30 >/dev/null || bad "no open prompt"
"$VII" settle 2 >/dev/null
"$VII" text "LONG" >/dev/null; "$VII" line "" >/dev/null
for i in $(seq 1 240); do "$VII" screen-raw 2>/dev/null | sed -n '24p' | grep -q "LONG" && break; sleep 0.5; done
"$VII" settle 6 >/dev/null
snapshot
assert_row "a 220-line program loads"                 0 "10 PRINT"

oa "A"
"$VII" await "SAVE AS" 30 >/dev/null || bad "no save-as prompt"
"$VII" settle 2 >/dev/null
"$VII" text "LONG2" >/dev/null; "$VII" line "" >/dev/null
for i in $(seq 1 240); do "$VII" screen-raw 2>/dev/null | sed -n '24p' | grep -qE "LONG2|NUMBER|ERROR" && break; sleep 0.5; done
"$VII" settle 6 >/dev/null
snapshot
assert_row "and saves under a new name"              23 "LONG2"

osascript -e 'tell application "Virtual ][" to tell (last machine) to eject device "S6D1"' >/dev/null 2>&1
sleep 2
"$ROOT/tools/ac" -g "$IMAGE" LONG2 > "$TMP/long2.bas" 2>/dev/null
python3 - "$TMP/long2.bas" > "$TMP/chain.txt" <<'PYEOF'
import sys
d = open(sys.argv[1], "rb").read()
i, addr, n, bad = 0, 0x801, 0, 0
while i < len(d) - 1:
    nxt = d[i] | (d[i+1] << 8)
    if nxt == 0: break
    j = i + 4
    while j < len(d) and d[j] != 0: j += 1
    j += 1
    if nxt != addr + (j - i): bad += 1
    n += 1; addr = nxt; i = j
else:
    print("UNTERMINATED"); raise SystemExit
print(f"{n} {bad}")
PYEOF
read -r nlines nbad < "$TMP/chain.txt" 2>/dev/null || { nlines=0; nbad=999; }
if [ "$nlines" = "220" ]; then ok "the saved file holds all 220 lines"
else bad "the saved file holds all 220 lines" "got $nlines"; fi
if [ "$nbad" = "0" ]; then ok "and every next-line pointer is right, which is all Applesoft reads"
else bad "and every next-line pointer is right, which is all Applesoft reads" "$nbad pointers wrong"; fi
fi

#--------------------------------------
if section "quit and return"; then
if [ ! -f "$DISTIMG" ]; then
    bad "the dist image exists" "no $DISTIMG -- run: make dist"
else
"$VII" boot "$DISTIMG" >/dev/null || { echo "boot failed"; exit 1; }
"$VII" await "ApplesIDE" 120 >/dev/null || bad "the dist image never booted"
"$VII" text " " >/dev/null
"$VII" await "UNTITLED" 60 >/dev/null || bad "the editor never opened"
"$VII" caps false >/dev/null
t '10 PRINT "ROUND TRIP"'
oa "S"
"$VII" await "SAVE AS" 30 >/dev/null; "$VII" settle 2 >/dev/null
"$VII" text "LOOP" >/dev/null; "$VII" line "" >/dev/null; "$VII" settle 8 >/dev/null

oa "Q"
"$VII" settle 12 >/dev/null
if "$VII" screen 2>/dev/null | grep -q "PRODOS BASIC"; then
    ok "OA-Q goes straight to BASIC, not to the file picker"
else
    bad "OA-Q goes straight to BASIC, not to the file picker" \
        "$("$VII" screen 2>/dev/null | tail -2)"
fi
# the banner interleaved with the editor's screen when 80-column mode was
# left on, and came out as "P R O D O S   B A S I C"
if "$VII" screen 2>/dev/null | grep -q "P R O D O S"; then
    bad "and hands the screen back in 40 columns" "still interleaved with the aux half"
else
    ok "and hands the screen back in 40 columns"
fi

"$VII" caps true >/dev/null
"$VII" line "RUN LOOP" >/dev/null; "$VII" settle 8 >/dev/null
if "$VII" screen 2>/dev/null | grep -q "ROUND TRIP"; then
    ok "and the saved program runs there without EXEC"
else
    bad "and the saved program runs there without EXEC" \
        "$("$VII" screen 2>/dev/null | tail -2)"
fi

# back into the editor, and a RELATIVE filename must work
"$VII" line "-ASIDE.SYSTEM" >/dev/null
"$VII" await "ApplesIDE" 120 >/dev/null || bad "BASIC could not relaunch the editor"
"$VII" text " " >/dev/null
"$VII" await "UNTITLED" 60 >/dev/null
oa "O"
"$VII" await "OPEN:" 30 >/dev/null; "$VII" settle 2 >/dev/null
"$VII" text "LOOP" >/dev/null; "$VII" line "" >/dev/null; "$VII" settle 8 >/dev/null
snapshot
assert_row "and a relative name opens after the relaunch"  0 "10 PRINT"
assert_notrow "with no invalid-pathname error"            23 "ERROR"
fi
fi

#--------------------------------------
if section "help and chrome"; then
reboot
oa "?"
snapshot
assert_row "the help screen names the program"       1 "APPLESIDE"
assert_row "and lists renumbering"                   5 "renumber by ten"
assert_row "and the word and paging keys"            6 "word / page"
assert_row "and the reference check"                 6 "check GOTO targets"
"$VII" text " " >/dev/null; "$VII" settle 3 >/dev/null
snapshot
assert_row "page two lists the file keys"            5 "open"
assert_row "page two lists the clipboard"            5 "copy the line"
assert_row "and going to a line"                     8 "go to line number"
assert_row "and the search keys"                    11 "find"
assert_row "and says they wrap"                     13 "both wrap round"

# Nothing user-facing is unbuilt any more, so the heading that said so is gone.
# It went when find landed; if it comes back, something regressed into a stub.
if grep -q "NOT BUILT YET" "$SCREEN"; then
    bad "no NOT BUILT YET heading remains" "$(grep -o 'NOT BUILT YET' "$SCREEN" | head -1)"
else
    ok "no NOT BUILT YET heading remains"
fi

# THE KEY THAT LEAVES. The suite walked to page two and stopped, so the exit
# path was never exercised -- and when the cursor-only redraw landed, leaving
# the help screen stopped repainting the program underneath it. Found on real
# hardware instead of here, which is the whole argument for this assertion.
reboot
t '10 HOME'
tl ''
t '20 PRINT "STILL HERE"'
oa "?"
"$VII" text " " >/dev/null; "$VII" settle 4 >/dev/null    # to page two
"$VII" text " " >/dev/null; "$VII" settle 5 >/dev/null    # and back out
snapshot
assert_row "a key on page two brings the program back" 0 "10 HOME"
assert_row "all of it"                                 1 "20 PRINT"
assert_notrow "and the help screen is gone"            1 "APPLESIDE  --"
fi

#--------------------------------------
# The clipboard, and going to a line by its number.
#
# The paste test is the one worth reading. A line-wise paste at a cursor
# sitting mid-line used to produce "30 PRINT 30 PRINT" -- not untidy but a
# syntax error, on the line the writer was in the middle of. A whole line now
# goes back as a whole line, above the one the cursor is on.
#--------------------------------------
if section "clipboard"; then
reboot
t '100 HOME'
numbered 4 '200 GOSUB 500'
numbered 4 '300 RETURN'

# OA-C says so, because a copy changes nothing on screen
oa "C"
snapshot
assert_row "OA-C reports the copy"                  23 "COPIED"

# up two lines, and the copied line goes in ABOVE line 200
"$VII" key "up arrow" >/dev/null; "$VII" settle 3 >/dev/null
oa "V"
snapshot
assert_row "the pasted line lands above the cursor"  1 "300 RETURN"
assert_row "and the line it displaced is still there" 2 "200 GOSUB 500"
assert_row "the line above is untouched"             0 "100 HOME"

# a paste is a whole line, not an append to the one under the cursor
if [ -n "$(row 1 | grep -o 'RETURN.*GOSUB')" ]; then
    bad "a paste does not run two lines together" "row 1: $(row 1)"
else
    ok "a paste does not run two lines together"
fi

# and cut takes the line away
reboot
t '100 HOME'
numbered 4 '200 GOSUB 500'
numbered 4 '300 RETURN'
"$VII" key "up arrow" >/dev/null; "$VII" settle 3 >/dev/null
oa "X"
snapshot
assert_row "OA-X removes the line"                   0 "100 HOME"
assert_row "and closes the gap it left"              1 "300 RETURN"
if [ -n "$(grep -c 'GOSUB' "$SCREEN" | grep -v '^0$')" ]; then
    bad "the cut line is gone from the screen" "still shows: $(grep GOSUB "$SCREEN" | head -1)"
else
    ok "the cut line is gone from the screen"
fi
fi

#--------------------------------------
if section "go to line"; then
reboot
t '100 HOME'
numbered 4 '200 GOSUB 500'
numbered 4 '300 RETURN'
numbered 4 '500 END'

# OA-L takes a line NUMBER, not the n'th line: 300 is the third line here, and
# asking for 3 must not land on it.
oa "L"
"$VII" await "GO TO LINE" 30 >/dev/null || bad "OA-L never prompted"
"$VII" text "300" >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
assert_row "OA-L goes to the line with that number" 23 "L:3"

# a number that is not in the program says so AND LEAVES THE CURSOR ALONE --
# stranding it at the bottom to report a miss is the bug this avoids
oa "L"
"$VII" await "GO TO LINE" 30 >/dev/null || bad "OA-L never prompted the second time"
"$VII" text "250" >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
assert_row "a missing number is reported"           23 "NO SUCH LINE: 250"
# any keystroke retires the message and puts the status row back; a RIGHT
# arrow is the one that cannot change the line it reports, where a left arrow
# at column 1 legitimately steps up to the end of the line above
"$VII" key "right arrow" >/dev/null; "$VII" settle 3 >/dev/null
snapshot
assert_row "and the cursor never moved"             23 "L:3"

# the ordinal trap, stated as its own assertion
oa "L"
"$VII" await "GO TO LINE" 30 >/dev/null || bad "OA-L never prompted the third time"
"$VII" text "3" >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
assert_row "3 is a line number, not the third line" 23 "NO SUCH LINE: 3"
fi

#--------------------------------------
# Find, ported whole from ZipEdit 1.4 -- including the two bugs that version
# fixed, which are the ones asserted hardest here. OA-G never advancing, and a
# match against the very end of the buffer being unfindable, were both
# invisible to a find test that only checked OA-F once.
#--------------------------------------
if section "find"; then
reboot
t '100 HOME'
numbered 4 '200 PRINT "ALPHA"'
numbered 4 '300 PRINT "BETA"'
numbered 4 '400 PRINT "ALPHA"'

# To the top first. Typing leaves the cursor at the END of the program, where
# every match is behind it and a search has to wrap to find anything -- which
# is right, and tests nothing about the forward pass.
oa "<"
oa "F"
"$VII" await "FIND" 30 >/dev/null || bad "OA-F never prompted"
"$VII" text 'BETA' >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
assert_row "OA-F finds a pattern below the cursor"  23 "L:3"
if grep -q "WRAPPED" "$SCREEN"; then
    bad "a forward hit does not claim to have wrapped" "$(row 23)"
else
    ok "a forward hit does not claim to have wrapped"
fi

# OA-G MUST ADVANCE. It re-matched where it stood, every time, until 1.4.
reboot
t '100 HOME'
numbered 4 '200 PRINT "ALPHA"'
numbered 4 '300 PRINT "BETA"'
numbered 4 '400 PRINT "ALPHA"'
oa "<"
oa "F"
"$VII" await "FIND" 30 >/dev/null || bad "OA-F never prompted the second time"
"$VII" text 'ALPHA' >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
first="$(row 23)"
assert_row "the first ALPHA is on line 2"           23 "L:2"
oa "G"
snapshot
assert_row "and OA-G moves on to the next"          23 "L:4"
if [ "$(row 23)" = "$first" ]; then
    bad "OA-G does not stand still" "row 23 unchanged: $first"
else
    ok "OA-G does not stand still"
fi

# and wraps, saying so, rather than stopping at the end
oa "G"
snapshot
assert_row "a search past the last match wraps"     23 "WRAPPED TO THE TOP"
"$VII" key "right arrow" >/dev/null; "$VII" settle 3 >/dev/null
snapshot
assert_row "and lands back on the first one"        23 "L:2"

# a pattern that is not there says so and leaves the cursor alone
oa "F"
"$VII" await "FIND" 30 >/dev/null || bad "OA-F never prompted the third time"
"$VII" text 'GAMMA' >/dev/null
"$VII" line "" >/dev/null
"$VII" settle 5 >/dev/null
snapshot
assert_row "a pattern that is absent says so"       23 "NOT FOUND"
fi

#--------------------------------------
if section "the toolchain"; then
if [ -f "$BIN" ]; then
    size=$(stat -f%z "$BIN")
    if [ "$size" -lt 20480 ]; then
        ok "the binary fits the \$2000-\$6FFF budget ($size bytes)"
    else
        bad "the binary fits the \$2000-\$6FFF budget" "$size bytes, over 20480"
    fi
else
    bad "the binary exists" "no $BIN"
fi
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
