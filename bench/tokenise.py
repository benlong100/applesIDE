#!/usr/bin/env python3
"""Tokenise a subset of Applesoft, for building benchmark programs.

Not a general tokeniser -- it handles what the benchmarks use and no more.
The token values come from tools/gentokens.py rather than being written out
again here, so there is one place where Applesoft's table lives and the
benchmarks cannot drift from the editor's idea of it.
"""
import re, pathlib

_SRC = pathlib.Path(__file__).resolve().parent.parent / "tools" / "gentokens.py"
_ns = {}
exec(re.search(r'TOKENS = \[.*?\n\]', _SRC.read_text(), re.S).group(0), _ns)
TOKENS = _ns['TOKENS']

# Longest first, so TO is not matched inside a word that merely starts with it.
_ORDER = sorted(range(len(TOKENS)), key=lambda i: -len(TOKENS[i]))


def statement(text):
    """One line's worth of source to tokens. Spaces outside strings go, which
    is what Applesoft itself does."""
    out, i, instr = bytearray(), 0, False
    while i < len(text):
        c = text[i]
        if instr:
            out.append(ord(c)); i += 1
            if c == '"':
                instr = False
            continue
        if c == '"':
            out.append(ord(c)); instr = True; i += 1; continue
        if c == ' ':
            i += 1; continue
        for t in _ORDER:
            w = TOKENS[t]
            if text.startswith(w, i):
                out.append(0x80 + t); i += len(w); break
        else:
            out.append(ord(c)); i += 1
    return bytes(out)


def program(lines, start=0x801):
    """[(number, text)] -> a tokenised file, ready to write as BAS at $801.

    Each line is a two-byte address of the NEXT line, the line number, the
    body, and a zero; a zero address ends the program."""
    addr, out = start, bytearray()
    for num, text in lines:
        body = statement(text)
        nxt = addr + 4 + len(body) + 1
        out += bytes([nxt & 0xFF, nxt >> 8, num & 0xFF, num >> 8]) + body + b'\x00'
        addr = nxt
    return bytes(out) + b'\x00\x00'
