#!/usr/bin/env python3
"""A very small 6502 emitter, and BENCH1 compiled by hand through it.

This is NOT the compiler. It is the compiler's OUTPUT, produced on the Mac so
the shape of the generated code can be proved on the machine before anything
is written to generate it automatically. If this is not faster, nothing built
on top of it will be either.
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from fp import pack

# Every one of these was confirmed on a running //e -- see docs/compiler.md.
MOVFM, MOVMF = 0xEAF9, 0xEB2B          # FAC <- mem ; mem <- FAC
FADD, FSUB   = 0xE7BE, 0xE7A7          # FAC+mem ; mem-FAC  (note the order)
FMUL, FDIV   = 0xE97F, 0xEA66          # FAC*mem ; mem/FAC  (note the order)
FCOMP        = 0xEBB2                  # 1 greater, 255 less, 0 equal
FOUT, COUT   = 0xED34, 0xFDED          # FAC -> $0100 ; character out


class Asm:
    def __init__(self, org):
        self.org, self.code = org, bytearray()
        self.labels, self.fix = {}, []

    def here(self):  return self.org + len(self.code)
    def label(self, n): self.labels[n] = self.here()
    def b(self, *xs): self.code.extend(xs)

    def _ref(self, sym, part):
        self.fix.append((len(self.code), sym, part)); self.code.append(0)

    def lda_lo(self, s): self.b(0xA9); self._ref(s, 'lo')
    def ldy_hi(self, s): self.b(0xA0); self._ref(s, 'hi')
    def ldx_lo(self, s): self.b(0xA2); self._ref(s, 'lo')
    def jsr(self, a):    self.b(0x20, a & 0xFF, a >> 8)
    def jmp(self, s):    self.b(0x4C); self._ref(s, 'lo'); self._ref(s, 'hi')

    def call(self, rom, sym):            # operand address in A/Y, then the call
        self.lda_lo(sym); self.ldy_hi(sym); self.jsr(rom)

    def store(self, sym):                # destination in X/Y
        self.ldx_lo(sym); self.ldy_hi(sym); self.jsr(MOVMF)

    def resolve(self):
        for off, sym, part in self.fix:
            a = self.labels[sym]
            self.code[off] = (a & 0xFF) if part == 'lo' else (a >> 8)
        return bytes(self.code)


ORG = 0x6000
a = Asm(ORG)

def print_fac():
    a.jsr(FOUT)
    a.b(0xA2, 0x00)                       # LDX #0
    top = a.here()
    a.b(0xBD, 0x00, 0x01)                 # LDA $0100,X
    a.b(0xF0, 0x08)                       # BEQ +8 -> past the loop
    a.b(0x09, 0x80)                       # ORA #$80
    a.jsr(COUT)
    a.b(0xE8)                             # INX
    a.b(0xD0, (top - (a.here() + 2)) & 0xFF)   # BNE back
    a.b(0xA9, 0x8D); a.jsr(COUT)          # newline

def print_str(sym):
    a.b(0xA2, 0x00)
    top = a.here()
    a.b(0xBD); a._ref(sym, 'lo'); a._ref(sym, 'hi')   # LDA str,X
    a.b(0xF0, 0x06)
    a.jsr(COUT)
    a.b(0xE8)
    a.b(0xD0, (top - (a.here() + 2)) & 0xFF)
    a.b(0xA9, 0x8D); a.jsr(COUT)

# 10 S = 0 / 20 I = 0
a.call(MOVFM, 'C0'); a.store('S')
a.call(MOVFM, 'C0'); a.store('I')
# 30 I = I + 1
a.label('L30')
a.call(MOVFM, 'I'); a.call(FADD, 'C1'); a.store('I')
# 40 S = S + I
a.call(MOVFM, 'S'); a.call(FADD, 'I'); a.store('S')
# 50 IF I < 3000 THEN GOTO 30
a.call(MOVFM, 'I'); a.call(FCOMP, 'C3000')
a.b(0xC9, 0xFF)                           # CMP #$FF  (FAC less than memory)
a.b(0xD0, 0x03)                           # BNE over the jump
a.jmp('L30')
# 60 PRINT S / 70 PRINT "ENDONE"
a.call(MOVFM, 'S'); print_fac()
print_str('MSG')
a.b(0x60)                                 # RTS, back to BASIC

for name, val in (('S', 0), ('I', 0), ('C0', 0), ('C1', 1), ('C3000', 3000)):
    a.label(name); a.b(*pack(val))
a.label('MSG'); a.b(*[c | 0x80 for c in b"ENDONE"], 0x00)

blob = a.resolve()
out = pathlib.Path("build/bench/CBENCH1.bin")
out.write_bytes(blob)
print(f"{len(blob)} bytes at ${ORG:04X}, entry ${ORG:04X}")
