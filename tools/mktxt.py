#!/usr/bin/env python3
"""Plain text to a ProDOS TXT file.

    tools/mktxt.py disk/README.src disk/README.TXT

The file on the disk is high ASCII with carriage returns, which is what the
Apple wants and what nobody can read in a diff. Keeping the SOURCE plain and
converting at build time means a change to the README shows up as a change to
the README, rather than as three hundred bytes of moved punctuation.

Uppercased on the way, because the //e this ships for has no lowercase in its
character generator on a plain 40-column screen, and a README that reads as
mush is worse than one that shouts.
"""
import sys, pathlib

WIDTH = 40

def main():
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out = bytearray()
    for line in src.read_text().splitlines():
        line = line.upper().rstrip()
        if len(line) > WIDTH:
            print(f"{src}: line over {WIDTH} columns: {line!r}", file=sys.stderr)
            return 1
        out += bytes((ord(c) | 0x80) & 0xff for c in line)
        out.append(0x8d)
    dst.write_bytes(out)
    return 0

if __name__ == "__main__":
    sys.exit(main())
