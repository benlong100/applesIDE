#!/usr/bin/env python3
"""Local labels used in one scope and defined in another.

Merlin scopes a :local label to the global label above it, and accepts a
reference to one that is nowhere in that scope WITHOUT COMPLAINING -- no
error, no warning, and an object file comes out. A `jmp :dim` whose target had
been deleted assembled cleanly and jumped into whatever followed; see
docs/compiler.md.

    tools/scopecheck.py src src/cc

Exits non-zero if anything is unresolved.
"""
import re, sys, pathlib

# an operand may name a local label anywhere in it: jmp :x, lda :t,y, bcc :a
REF = re.compile(r"(?<![A-Za-z0-9_])(:[A-Za-z0-9_]+)")

def sameline(path):
    """A local label referenced on a global label's OWN line.

    Merlin resolves that reference in the PREVIOUS scope, not the one the
    label opens. `UFN jmp :go` reached the :go of the routine above it and ran
    that instead -- silently, because both routines defined :go. Every
    reference on a later line was scoped correctly, which is what made it look
    impossible. See docs/compiler.md.
    """
    bad = []
    for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line or line[0].isspace() or line.lstrip().startswith("*"):
            continue
        label = line.split()[0]
        if label.startswith(":"):
            continue
        rest = line[len(label):].split(";")[0]
        parts = rest.split(None, 1)
        if len(parts) > 1:
            for ref in REF.findall(parts[1]):
                bad.append((n, label, ref))
    return bad


def check(path):
    scope, defined, used, bad = None, set(), [], []
    for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("*"):
            continue
        if not line[0].isspace():                 # column 1: a label
            label = line.split()[0]
            if label.startswith(":"):
                defined.add((scope, label))
            else:                                 # a global: a new scope
                bad += [(s, l, ln) for s, l, ln in used if (s, l) not in defined]
                used, scope = [], label
                continue
            rest = line[len(label):]
        else:
            rest = line
        body = rest.split(";")[0]
        parts = body.split(None, 1)
        if len(parts) > 1:
            for ref in REF.findall(parts[1].split(";")[0]):
                used.append((scope, ref, n))
    bad += [(s, l, ln) for s, l, ln in used if (s, l) not in defined]
    return bad

fail = 0
for arg in sys.argv[1:] or ["src"]:
    root = pathlib.Path(arg)
    for path in sorted(root.glob("*.S")) if root.is_dir() else [root]:
        for scope, label, n in check(path):
            print(f"{path}:{n}: {label} is not defined in {scope}")
            fail = 1
        for n, label, ref in sameline(path):
            print(f"{path}:{n}: {ref} is on {label}'s own line, so it resolves"
                  f" in the PREVIOUS scope -- give {label} a line of its own")
            fail = 1
print("scopecheck: clean" if not fail else "scopecheck: unresolved labels", file=sys.stderr)
sys.exit(fail)
