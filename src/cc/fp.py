#!/usr/bin/env python3
"""Applesoft's packed five-byte float.

Exponent biased by 129, then 31 bits of fraction with a leading 1 implied,
and the sign in bit 7 of the first fraction byte. An exponent of zero is the
value zero.

The layout was read off a running machine (docs/compiler.md); this checks
itself against those readings rather than trusting the description.
"""

def pack(x):
    if x == 0:
        return bytes(5)
    sign = 0x80 if x < 0 else 0
    x = abs(float(x))
    exp = 0
    while x >= 1.0:
        x /= 2.0; exp += 1
    while x < 0.5:
        x *= 2.0; exp -= 1
    # x is now in [0.5, 1); doubling it gives the 1.f the format implies
    frac = x * 2.0 - 1.0
    bits = int(round(frac * (1 << 31)))
    if bits >> 31:                      # rounded up to the next power of two
        bits = 0; exp += 1
    b = [(bits >> 24) & 0x7F, (bits >> 16) & 0xFF,
         (bits >> 8) & 0xFF, bits & 0xFF]
    b[0] |= sign
    return bytes([exp + 128] + b)


# The three values the machine printed out of its own variable table.
_KNOWN = {2.5: (130, 32, 0, 0, 0), 1: (129, 0, 0, 0, 0), -1: (129, 128, 0, 0, 0)}
for _v, _want in _KNOWN.items():
    assert tuple(pack(_v)) == _want, f"pack({_v}) = {tuple(pack(_v))}, machine said {_want}"

if __name__ == "__main__":
    for v in (0, 1, -1, 2.5, 10, 3000, 4501500):
        print(f"{v:>10} -> " + ' '.join(f"{b:3d}" for b in pack(v)))
