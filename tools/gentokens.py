#!/usr/bin/env python3
"""Turn Applesoft's keyword list into the table src/tokens.S.

    tools/gentokens.py > src/tokens.S

The list below is Applesoft's own token table, $80 to $EA in order. It is
written out here rather than typed into assembly because ninety-odd keywords
hand-entered as `asc` lines with hand-counted lengths is a place typos hide:
one wrong length byte highlights half a word and nothing says why.

WHAT IS LEFT OUT, AND WHY

The single-character operators -- + - * / ^ > = < and & -- are tokens to
Applesoft but are not reserved WORDS, and drawing them inverse would make an
expression look like a rash. They are dropped here. Everything alphabetic is
kept, including the ones ending in punctuation (HCOLOR=, HIMEM:, TAB(), because
those characters are part of the keyword and Applesoft will not accept the name
without them.

FIRST-LETTER DISPATCH

The editor matches at a position rather than rolling a match over every
keyword at once: ninety-five simultaneous candidates would be ninety-five
compares per character drawn, and a redraw touches seventeen hundred of them.
So the table is grouped by first letter and the generator emits an index --
where each letter's group starts, and how many are in it. A character that
begins no keyword costs one lookup and nothing else.

LONGEST FIRST

Within a letter the keywords are sorted longest first, so ATN is tried before
AT and RESTORE before RESUME... and before RETURN, which shares nothing but
its first two letters. Applesoft's own tokenizer works down its table in token
order and needs a special case to stop ATN being read as AT followed by N;
longest-first gets the same answer without one.
"""
import sys

# Applesoft's token table, $80-$EA, in order.
TOKENS = [
    "END", "FOR", "NEXT", "DATA", "INPUT", "DEL", "DIM", "READ", "GR", "TEXT",
    "PR#", "IN#", "CALL", "PLOT", "HLIN", "VLIN", "HGR2", "HGR", "HCOLOR=",
    "HPLOT", "DRAW", "XDRAW", "HTAB", "HOME", "ROT=", "SCALE=", "SHLOAD",
    "TRACE", "NOTRACE", "NORMAL", "INVERSE", "FLASH", "COLOR=", "POP", "VTAB",
    "HIMEM:", "LOMEM:", "ONERR", "RESUME", "RECALL", "STORE", "SPEED=", "LET",
    "GOTO", "RUN", "IF", "RESTORE", "&", "GOSUB", "RETURN", "REM", "STOP",
    "ON", "WAIT", "LOAD", "SAVE", "DEF", "POKE", "PRINT", "CONT", "LIST",
    "CLEAR", "GET", "NEW", "TAB(", "TO", "FN", "SPC(", "THEN", "AT", "NOT",
    "STEP", "+", "-", "*", "/", "^", "AND", "OR", ">", "=", "<", "SGN", "INT",
    "ABS", "USR", "FRE", "SCRN(", "PDL", "POS", "SQR", "RND", "LOG", "EXP",
    "COS", "SIN", "TAN", "ATN", "PEEK", "LEN", "STR$", "VAL", "ASC", "CHR$",
    "LEFT$", "RIGHT$", "MID$",
]


# What each keyword looks like in use. Shown on the hint row for the last
# keyword before the cursor, so it stays up while you type the arguments --
# which is when it is wanted, not the instant the word is finished.
#
# No double quotes anywhere: these become `asc "..."` and Merlin would end the
# string early. Kept short, because the row is 80 columns on a //e and 40 on a
# ][+, and because every byte here is a byte of the code budget.
SYNTAX = {
    "END": "END - stop the program",
    "FOR": "FOR v=a TO b [STEP c]",
    "NEXT": "NEXT [v][,v...]",
    "DATA": "DATA item[,item...]",
    "INPUT": "INPUT [prompt;] var[,var...]",
    "DEL": "DEL first,last - delete lines",
    "DIM": "DIM name(size)[,...]",
    "READ": "READ var[,var...] - from DATA",
    "GR": "GR - lo-res graphics, 40x40",
    "TEXT": "TEXT - back to the text screen",
    "PR#": "PR# slot - send output to a slot",
    "IN#": "IN# slot - take input from a slot",
    "CALL": "CALL addr - run machine code",
    "PLOT": "PLOT x,y - one lo-res dot",
    "HLIN": "HLIN x1,x2 AT y",
    "VLIN": "VLIN y1,y2 AT x",
    "HGR2": "HGR2 - hi-res page 2, full screen",
    "HGR": "HGR - hi-res page 1, mixed",
    "HCOLOR=": "HCOLOR= 0..7 - hi-res colour",
    "HPLOT": "HPLOT x,y [TO x,y ...]",
    "DRAW": "DRAW shape AT x,y",
    "XDRAW": "XDRAW shape AT x,y - erases",
    "HTAB": "HTAB col - 1 to 40",
    "HOME": "HOME - clear the text screen",
    "ROT=": "ROT= 0..63 - shape rotation",
    "SCALE=": "SCALE= 1..255 - shape size",
    "SHLOAD": "SHLOAD - shape table from tape",
    "TRACE": "TRACE - show lines as they run",
    "NOTRACE": "NOTRACE - stop tracing",
    "NORMAL": "NORMAL - ordinary text",
    "INVERSE": "INVERSE - inverse text",
    "FLASH": "FLASH - flashing text",
    "COLOR=": "COLOR= 0..15 - lo-res colour",
    "POP": "POP - forget the last GOSUB",
    "VTAB": "VTAB row - 1 to 24",
    "HIMEM:": "HIMEM: addr - top of memory",
    "LOMEM:": "LOMEM: addr - bottom of variables",
    "ONERR": "ONERR GOTO line",
    "RESUME": "RESUME - retry the line that failed",
    "RECALL": "RECALL array - from tape",
    "STORE": "STORE array - to tape",
    "SPEED=": "SPEED= 0..255 - printing speed",
    "LET": "[LET] var = expr",
    "GOTO": "GOTO line",
    "RUN": "RUN [line]",
    "IF": "IF cond THEN stmt  or  THEN line",
    "RESTORE": "RESTORE - reset the DATA pointer",
    "GOSUB": "GOSUB line",
    "RETURN": "RETURN - back from a GOSUB",
    "REM": "REM comment - to end of line",
    "STOP": "STOP - break, with a message",
    "ON": "ON expr GOTO line[,line...]",
    "WAIT": "WAIT addr,mask[,value]",
    "LOAD": "LOAD - program from tape",
    "SAVE": "SAVE - program to tape",
    "DEF": "DEF FN name(v) = expr",
    "POKE": "POKE addr,value",
    "PRINT": "PRINT [expr][;,][expr...]",
    "CONT": "CONT - carry on after a STOP",
    "LIST": "LIST [first][-last]",
    "CLEAR": "CLEAR - forget all variables",
    "GET": "GET var - one key, no Return",
    "NEW": "NEW - erase the program",
    "TAB(": "TAB(col) - inside PRINT",
    "TO": "FOR v=a TO b   /   HPLOT .. TO",
    "FN": "FN name(expr)",
    "SPC(": "SPC(n) - n spaces inside PRINT",
    "THEN": "IF cond THEN stmt  or  THEN line",
    "AT": "HLIN/VLIN/DRAW ... AT",
    "NOT": "NOT expr",
    "STEP": "FOR v=a TO b STEP c",
    "AND": "expr AND expr",
    "OR": "expr OR expr",
    "SGN": "SGN(x) - sign: -1, 0 or 1",
    "INT": "INT(x) - whole part",
    "ABS": "ABS(x) - absolute value",
    "USR": "USR(x) - call machine code",
    "FRE": "FRE(0) - bytes of memory free",
    "SCRN(": "SCRN(x,y) - lo-res colour there",
    "PDL": "PDL(n) - paddle n, 0 to 255",
    "POS": "POS(0) - current print column",
    "SQR": "SQR(x) - square root",
    "RND": "RND(x) - random, 0 to 1",
    "LOG": "LOG(x) - natural logarithm",
    "EXP": "EXP(x) - e to the power x",
    "COS": "COS(x) - cosine, radians",
    "SIN": "SIN(x) - sine, radians",
    "TAN": "TAN(x) - tangent, radians",
    "ATN": "ATN(x) - arctangent, radians",
    "PEEK": "PEEK(addr) - the byte there",
    "LEN": "LEN(a$) - length of a string",
    "STR$": "STR$(x) - number as a string",
    "VAL": "VAL(a$) - string as a number",
    "ASC": "ASC(a$) - code of first character",
    "CHR$": "CHR$(n) - character with that code",
    "LEFT$": "LEFT$(a$,n)",
    "RIGHT$": "RIGHT$(a$,n)",
    "MID$": "MID$(a$,start[,len])",
}

def main():
    assert len(TOKENS) == 107, f"the table is $80-$EA, which is 107, not {len(TOKENS)}"

    dropped = [t for t in TOKENS if not t[0].isalpha()]
    assert len(dropped) == 9, dropped     # & + - * / ^ > = <
    words = [t for t in TOKENS if t[0].isalpha()]
    assert len(words) == 98, len(words)

    # group by first letter, longest first inside each group
    groups = {}
    for w in words:
        groups.setdefault(w[0], []).append(w)
    for g in groups.values():
        g.sort(key=lambda w: (-len(w), w))

    order = []
    index = {}
    for letter in sorted(groups):
        index[letter] = (len(order), len(groups[letter]))
        order.extend(groups[letter])

    out = [
        "*" + "-" * 37,
        "* GENERATED by tools/gentokens.py -- DO NOT EDIT.",
        "*",
        "* Applesoft's keywords, grouped by first letter and longest first, with",
        "* an index so that a character which begins no keyword costs one lookup.",
        "* Edit tools/gentokens.py and rebuild.",
        "*" + "-" * 37,
        "",
        f"TKN          equ   {len(order)}",
        f"TKREMI       equ   {order.index('REM')}"  + "        ; REM ends the line for highlighting",
        "",
        "*--- for each letter A-Z: where its group starts, and how many",
        "TKFIRST      dfb   " + ",".join(str(index.get(chr(c), (0, 0))[0]) for c in range(ord("A"), ord("N"))),
        "             dfb   " + ",".join(str(index.get(chr(c), (0, 0))[0]) for c in range(ord("N"), ord("["))),
        "TKCOUNT      dfb   " + ",".join(str(index.get(chr(c), (0, 0))[1]) for c in range(ord("A"), ord("N"))),
        "             dfb   " + ",".join(str(index.get(chr(c), (0, 0))[1]) for c in range(ord("N"), ord("["))),
        "",
        "*--- each keyword's length, then a pointer to its text",
        "TKLEN        dfb   " + ",".join(str(len(w)) for w in order[:16]),
    ]
    for i in range(16, len(order), 16):
        out.append("             dfb   " + ",".join(str(len(w)) for w in order[i:i + 16]))

    out.append("")
    out.append("TKLO         dfb   " + ",".join(f"<TKW{i}" for i in range(min(8, len(order)))))
    for i in range(8, len(order), 8):
        out.append("             dfb   " + ",".join(f"<TKW{j}" for j in range(i, min(i + 8, len(order)))))
    out.append("TKHI         dfb   " + ",".join(f">TKW{i}" for i in range(min(8, len(order)))))
    for i in range(8, len(order), 8):
        out.append("             dfb   " + ",".join(f">TKW{j}" for j in range(i, min(i + 8, len(order)))))

    out.append("")
    out.append("*--- what each looks like in use, for the hint row")
    out.append("TKSLO        dfb   " + ",".join(f"<TKS{i}" for i in range(min(8, len(order)))))
    for i in range(8, len(order), 8):
        out.append("             dfb   " + ",".join(f"<TKS{j}" for j in range(i, min(i + 8, len(order)))))
    out.append("TKSHI        dfb   " + ",".join(f">TKS{i}" for i in range(min(8, len(order)))))
    for i in range(8, len(order), 8):
        out.append("             dfb   " + ",".join(f">TKS{j}" for j in range(i, min(i + 8, len(order)))))

    out.append("")
    out.append("*--- and the text itself, high ASCII")
    for i, w in enumerate(order):
        out.append(f'TKW{i}'.ljust(12) + f' asc   "{w}"')
    out.append("")
    for i, w in enumerate(order):
        out.append(f'TKS{i}'.ljust(12) + f' asc   "{SYNTAX[w]}"')
        out.append("             dfb   $00")

    print("\n".join(out))

if __name__ == "__main__":
    main()
