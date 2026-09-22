#!/usr/bin/env python3
"""Plain Applesoft text to a tokenised BAS file.

    tools/mkbas.py disk/MANDELBROT.src disk/MANDELBROT.bas

The file on the disk is tokenised and loads at $801, which is what makes it a
real Applesoft program: RUN works from the ] prompt, and ApplesIDE opens it as
the program it is rather than as text. Keeping the SOURCE plain means a change
to the sample reads as a change to the sample, rather than as a diff of token
bytes nobody can check by eye.

The tokeniser is bench/tokenise.py, which takes its table from
tools/gentokens.py -- so Applesoft's keyword list lives in exactly one place
and a sample on the disk cannot drift from the editor's idea of it.

CHECKED BOTH WAYS. Whatever comes out is read back with tools/detok.py and
compared against the source, because a sample program that ships broken is
worse than no sample at all: it is the first thing anybody runs.
"""
import sys, pathlib, re

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bench"))
sys.path.insert(0, str(HERE))
import tokenise                                  # noqa: E402
import detok                                     # noqa: E402


def main():
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    lines, last = [], 0
    for n, raw in enumerate(src.read_text().splitlines(), 1):
        if not raw.strip():
            continue
        m = re.match(r"^(\d+)\s+(.*)$", raw)
        if not m:
            print(f"{src}:{n}: no line number: {raw!r}", file=sys.stderr)
            return 1
        num, body = int(m.group(1)), m.group(2).rstrip()
        if num <= last:
            print(f"{src}:{n}: line {num} is not after {last}", file=sys.stderr)
            return 1
        if len(body) > 239:
            print(f"{src}:{n}: line {num} is {len(body)} characters, over 239",
                  file=sys.stderr)
            return 1
        lines.append((num, body))
        last = num

    out = tokenise.program(lines)
    dst.write_bytes(out)

    # READ IT BACK. Spaces outside strings are dropped by the tokeniser, as
    # Applesoft drops them, so the comparison is made with them gone on both
    # sides rather than by hoping the round trip is exact.
    def flat(s):
        keep, r, instr = [], False, False
        for c in s:
            if c == '"':
                instr = not instr
            if c != " " or instr:
                keep.append(c)
        return "".join(keep)

    back = [l for l in detok.listing(out)]
    if len(back) != len(lines):
        print(f"{src}: wrote {len(lines)} lines, read back {len(back)}",
              file=sys.stderr)
        return 1
    for (num, body), got in zip(lines, back):
        want = flat(f"{num} {body}")
        if flat(got) != want:
            print(f"{src}: line {num} did not survive tokenising", file=sys.stderr)
            print(f"  wrote: {want}", file=sys.stderr)
            print(f"  read:  {flat(got)}", file=sys.stderr)
            return 1
    print(f"tokenised {src} -> {dst} ({len(lines)} lines, {len(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
