#!/usr/bin/env python3
"""Read a tokenised Applesoft program.

    tools/detok.py FILE.bas              the program, as text
    tools/detok.py --tokens FILE.bas...  every token used, by frequency

The second form is the one worth reaching for before deciding what a program
needs from the compiler. It counts TOKEN BYTES and skips REM text, which the
obvious approach -- grepping the listing for keyword spellings -- does not:
that reported ONERR, STOP and DRAW as things BRIAN and LITTLE required, and
all three were words inside comments.

It cannot show the gap that actually stopped both programs, either: a
supported keyword in an unsupported form, NEXT with a list of variables and =
chained. Nothing but reading the program shows that. What this gives you is
the short list of places to look.
"""
import sys
from collections import Counter

TOKENS = ["END","FOR","NEXT","DATA","INPUT","DEL","DIM","READ","GR","TEXT",
    "PR#","IN#","CALL","PLOT","HLIN","VLIN","HGR2","HGR","HCOLOR=","HPLOT",
    "DRAW","XDRAW","HTAB","HOME","ROT=","SCALE=","SHLOAD","TRACE","NOTRACE",
    "NORMAL","INVERSE","FLASH","COLOR=","POP","VTAB","HIMEM:","LOMEM:","ONERR",
    "RESUME","RECALL","STORE","SPEED=","LET","GOTO","RUN","IF","RESTORE","&",
    "GOSUB","RETURN","REM","STOP","ON","WAIT","LOAD","SAVE","DEF","POKE",
    "PRINT","CONT","LIST","CLEAR","GET","NEW","TAB(","TO","FN","SPC(","THEN",
    "AT","NOT","STEP","+","-","*","/","^","AND","OR",">","=","<","SGN","INT",
    "ABS","USR","FRE","SCRN(","PDL","POS","SQR","RND","LOG","EXP","COS","SIN",
    "TAN","ATN","PEEK","LEN","STR$","VAL","ASC","CHR$","LEFT$","RIGHT$","MID$"]

def name(b):
    return TOKENS[b - 0x80] if 0x80 <= b < 0x80 + len(TOKENS) else f"${b:02x}"

def lines(data):
    """(number, [byte...]) for each line. A zero next-line address ends it."""
    p = 0
    while p + 4 <= len(data):
        if data[p] | (data[p+1] << 8) == 0:
            break
        num = data[p+2] | (data[p+3] << 8)
        p += 4
        start = p
        while p < len(data) and data[p] != 0:
            p += 1
        yield num, data[start:p]
        p += 1

def listing(data):
    for num, body in lines(data):
        out = ""
        for b in body:
            out += f" {name(b)} " if b >= 0x80 else chr(b)
        yield f"{num} {' '.join(out.split())}"

def tokens(data, counter):
    """Tokens only, and NOT the text of a REM -- which is stored verbatim, so
    a word like ONERR in a comment is ASCII and must not be counted."""
    for _, body in lines(data):
        rem = False
        for b in body:
            if b >= 0x80 and not rem:
                counter[name(b)] += 1
                if b == 0xB2:
                    rem = True

if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--tokens":
        c = Counter()
        for fn in args[1:]:
            tokens(open(fn, "rb").read(), c)
        print(" ".join(f"{k}({v})" for k, v in sorted(c.items(), key=lambda x: -x[1])))
    elif args:
        for line in listing(open(args[0], "rb").read()):
            print(line)
    else:
        sys.exit(__doc__)
