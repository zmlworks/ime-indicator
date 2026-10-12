#!/usr/bin/env python3
"""Static checks for ImeIndicator.exe (run by build.sh):
 - PE32+ / AMD64 / Windows GUI subsystem, ASLR(+high entropy)/NX, relocatable
 - every RUNTIME_FUNCTION in .pdata points at the expected 19-byte prologue
   (8 pushes + sub rsp,imm32), its UNWIND_INFO matches that prologue, the
   frame keeps RSP 16-byte aligned at calls, and the function contains a
   matching canonical epilogue (add rsp,imm32 / 8 pops / ret).
"""
import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "ImeIndicator.exe"
d = open(path, "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
assert d[pe:pe + 4] == b"PE\0\0", "not a PE file"
machine, nsec, _, _, _, optsz, chars = struct.unpack_from("<HHIIIHH", d, pe + 4)
opt = pe + 24
magic = struct.unpack_from("<H", d, opt)[0]
subsys, dllch = struct.unpack_from("<HH", d, opt + 68)
errors = []
def check(cond, msg):
    if not cond:
        errors.append(msg)
check(machine == 0x8664, "machine is not AMD64")
check(magic == 0x20B, "not PE32+")
check(subsys == 2, "subsystem is not Windows GUI")
check(dllch & 0x40 and dllch & 0x100 and dllch & 0x20, "DYNAMIC_BASE/NX_COMPAT/HIGH_ENTROPY_VA missing")
check(not chars & 1, "RELOCS_STRIPPED set (ASLR would be disabled)")

secs = []
for i in range(nsec):
    o = opt + optsz + 40 * i
    name = d[o:o + 8].rstrip(b"\0").decode()
    vsize, va, rsize, raw = struct.unpack_from("<IIII", d, o + 8)
    secs.append((name, va, vsize, raw, rsize))
def rva2off(rva):
    for n, va, vs, raw, rs in secs:
        if va <= rva < va + max(vs, rs):
            return raw + rva - va
    raise ValueError(hex(rva))
exc_rva, exc_size = struct.unpack_from("<II", d, opt + 112 + 3 * 8)
check(exc_size and exc_size % 12 == 0, "no/odd exception directory")

PROLOG = bytes([0x53, 0x56, 0x57, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xEC])
EPILOG_TAIL = bytes([0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5D, 0x5F, 0x5E, 0x5B, 0xC3])
CODES = bytes([12, 0xF0, 10, 0xE0, 8, 0xD0, 6, 0xC0, 4, 0x50, 3, 0x70, 2, 0x60, 1, 0x30])
prev_end = 0
n = exc_size // 12
for i in range(n):
    beg, end, uw = struct.unpack_from("<III", d, rva2off(exc_rva) + 12 * i)
    check(beg >= prev_end and end > beg, f"pdata #{i} unsorted/overlapping")
    prev_end = end
    code = d[rva2off(beg):rva2off(beg) + (end - beg)]
    check(code[:15] == PROLOG, f"pdata #{i} @{beg:#x}: unexpected prologue")
    frame = struct.unpack_from("<I", code, 15)[0]
    check(frame % 16 == 8, f"@{beg:#x}: frame {frame:#x} breaks 16-byte alignment")
    u = d[rva2off(uw):rva2off(uw) + 4 + 20]
    ver, plen, cnt, freg = u[0], u[1], u[2], u[3]
    check(ver == 1 and plen == 19 and cnt == 10 and freg == 0, f"@{beg:#x}: bad UNWIND_INFO header")
    check(u[4] == 19 and u[5] == 0x01 and struct.unpack_from("<H", u, 6)[0] * 8 == frame,
          f"@{beg:#x}: UWOP_ALLOC_LARGE does not match sub rsp,{frame:#x}")
    check(u[8:24] == CODES, f"@{beg:#x}: push unwind codes mismatch")
    epi = bytes([0x48, 0x81, 0xC4]) + struct.pack("<I", frame) + EPILOG_TAIL
    entry = struct.unpack_from("<I", d, opt + 16)[0]
    check(epi in code or beg == entry,  # entry point ends in ExitProcess
          f"@{beg:#x}: no canonical epilogue (add rsp,{frame:#x}; pops; ret)")
print(f"{path}: AMD64 PE32+ GUI, dllchar={dllch:#x}, chars={chars:#x}, {n} unwind entries verified")
if errors:
    print("ERRORS:\n  " + "\n  ".join(errors))
    sys.exit(1)
print("all checks passed")
