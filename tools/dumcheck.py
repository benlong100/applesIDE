#!/usr/bin/env python3
"""Check that no two dum blocks overlap.

Merlin will not catch this: a dum block declares addresses without emitting
anything, so two of them can quietly claim the same bytes and the only sign
is a variable that changes when nothing touched it. That is a bad afternoon,
so the build asks this question every time.
"""
import re, sys, glob, os

def equates(root):
    """ds sizes are often named. Resolve the simple ones from the source."""
    out = {}
    for path in glob.glob(os.path.join(root, "src", "*.S")):
        for line in open(path):
            m = re.match(r"(\S+)\s+equ\s+\$?([0-9a-fA-F]+)\s*$", line.rstrip())
            if m:
                txt = m.group(2)
                base = 16 if "$" in line.split("equ")[1] else 10
                try:
                    out[m.group(1)] = int(txt, base)
                except ValueError:
                    pass
    return out

def main():
    root = os.path.join(os.path.dirname(__file__), "..")
    SIZES = equates(root)
    spans = []
    for path in sorted(glob.glob(os.path.join(root, "src", "*.S"))):
        addr = None
        items = []
        for i, line in enumerate(open(path), 1):
            m = re.match(r"\s+dum\s+\$([0-9a-fA-F]+)", line)
            if m:
                addr = int(m.group(1), 16); items = []; start = addr; ln = i
                continue
            if addr is not None and re.match(r"\s+dend", line):
                if items:
                    spans.append((start, addr - 1, os.path.basename(path), ln, items[0]))
                addr = None
                continue
            if addr is None:
                continue
            m = re.match(r"(\S*)\s+ds\s+(\S+)", line)
            if m:
                n = m.group(2)
                n = int(n) if n.isdigit() else SIZES.get(n, 0)
                items.append(m.group(1) or "?")
                addr += n

    spans.sort()
    bad = 0
    for i, (s, e, f, ln, first) in enumerate(spans):
        for (s2, e2, f2, ln2, first2) in spans[i+1:]:
            if s2 <= e:
                print(f"OVERLAP: ${s:04x}-${e:04x} {first} ({f}:{ln})"
                      f"  and  ${s2:04x}-${e2:04x} {first2} ({f2}:{ln2})")
                bad += 1
    if bad:
        return 1
    if "-v" in sys.argv:
        for s, e, f, ln, first in spans:
            print(f"${s:04x}-${e:04x}  {first:<12} {f}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
