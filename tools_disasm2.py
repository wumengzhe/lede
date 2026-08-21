#!/usr/bin/env python3
# Focused disassembly of relocatable .ko by symbol name (ET_REL aware).
import sys
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

KO = sys.argv[1]
FUNCS = sys.argv[2:]

with open(KO, "rb") as f:
    elf = ELFFile(f)
    secs = list(elf.iter_sections())
    symtab = None
    for s in secs:
        if isinstance(s, SymbolTableSection) and s['sh_entsize'] and s.name == '.symtab':
            symtab = s; break
    if symtab is None:
        for s in secs:
            if isinstance(s, SymbolTableSection):
                symtab = s; break

    byname = {}
    for s in symtab.iter_symbols():
        if s.name and s['st_value'] and s['st_size']:
            byname.setdefault(s.name, (s['st_value'], s['st_size'], s['st_shndx']))

    if not FUNCS:
        for addr, name in sorted({(s['st_value'], s.name) for s in symtab.iter_symbols() if s.name}):
            pass
        out = []
        for s in symtab.iter_symbols():
            if s.name and s['st_value']:
                out.append(f"{s['st_value']:x}  {s.name}  {s['st_size']}")
        print("\n".join(out))
        sys.exit(0)

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True

    for fn in FUNCS:
        if fn not in byname:
            print(f"!! no symbol {fn}")
            for n, (a, sz, sh) in byname.items():
                if fn in n:
                    print(f"   maybe: {hex(a)} {n}")
            continue
        addr, size, shndx = byname[fn]
        sec = secs[shndx] if shndx < len(secs) else None
        if sec is None or sec['sh_type'] == 'SHT_NOBITS':
            print(f"!! no code section for {fn} shndx={shndx}")
            continue
        data = sec.data()
        off = addr  # in ET_REL, st_value == offset within the section
        code = data[off:off + size]
        print(f"\n========== {fn}  off={hex(addr)}  size={size}  sec={sec.name} ==========")
        for ins in md.disasm(code, addr):
            print(f"{hex(ins.address)}  {ins.mnemonic:8s} {ins.op_str}")
