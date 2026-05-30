#!/usr/bin/env python3
"""Targeted x64 disassembler for BstkRooter.exe with string/import annotation."""
import sys, pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86 import X86_OP_MEM, X86_OP_IMM, X86_REG_RIP

EXE = "/Users/jordan/Downloads/new root/BstkRooter.exe"
pe = pefile.PE(EXE)
IB = pe.OPTIONAL_HEADER.ImageBase

# section map
secs = []
for s in pe.sections:
    secs.append((IB + s.VirtualAddress, s.Misc_VirtualSize, s.PointerToRawData, s.SizeOfRawData, s.Name.rstrip(b'\x00').decode(errors='replace')))

def va_to_off(va):
    for base, vsize, praw, rsize, name in secs:
        if base <= va < base + max(vsize, rsize):
            d = va - base
            if d < rsize:
                return praw + d
    return None

def sec_of(va):
    for base, vsize, praw, rsize, name in secs:
        if base <= va < base + max(vsize, rsize):
            return name
    return None

data = pe.__data__

def read(va, n):
    off = va_to_off(va)
    if off is None: return None
    return data[off:off+n]

# import thunk map: IAT vaddr -> "DLL!name"
iat = {}
try:
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll = entry.dll.decode(errors='replace')
        for imp in entry.imports:
            if imp.address:
                iat[imp.address] = f"{dll}!{(imp.name or b'').decode(errors='replace')}"
except Exception:
    pass

def get_string(va, maxlen=200):
    off = va_to_off(va)
    if off is None: return None
    raw = data[off:off+maxlen]
    # try ascii
    end = raw.find(b'\x00')
    if end == -1: end = len(raw)
    s = raw[:end]
    if len(s) >= 2 and all(0x09 <= c < 0x7f or c in (0x0a,0x0d) for c in s):
        return s.decode(errors='replace')
    return None

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = True

def annotate(insn):
    notes = []
    for op in insn.operands:
        if op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP:
            target = insn.address + insn.size + op.mem.disp
            # call/jmp through IAT?
            if target in iat:
                notes.append(f"-> [{iat[target]}]")
            else:
                s = get_string(target)
                sect = sec_of(target)
                if s is not None:
                    notes.append(f'-> {hex(target)} "{s}"')
                elif sect:
                    notes.append(f"-> {hex(target)} ({sect})")
                else:
                    notes.append(f"-> {hex(target)}")
        elif op.type == X86_OP_IMM:
            t = op.imm
            if insn.mnemonic in ('call','jmp') or insn.mnemonic.startswith('j'):
                if t in iat:
                    notes.append(f"=> [{iat[t]}]")
    return "  ".join(notes)

def disasm(start, length=0x400, stop_on_ret=True):
    off = va_to_off(start)
    if off is None:
        print("bad va"); return
    code = data[off:off+length]
    last_was_ret = False
    for insn in md.disasm(code, start):
        ann = annotate(insn)
        print(f"0x{insn.address:08x}  {insn.bytes.hex():<16} {insn.mnemonic:<7} {insn.op_str:<40} {ann}")
        if insn.mnemonic == 'ret':
            # heuristic: stop after ret if followed by int3 padding
            nxt = data[va_to_off(insn.address+insn.size):va_to_off(insn.address+insn.size)+1]
            if stop_on_ret and nxt in (b'\xcc', b''):
                print("---- (ret + pad, stop) ----")
                break

if __name__ == "__main__":
    start = int(sys.argv[1], 16)
    length = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x400
    disasm(start, length)
