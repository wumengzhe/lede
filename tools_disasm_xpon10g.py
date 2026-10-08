#!/usr/bin/env python3
# Disassemble OEM xpon_10g.ko (ARM64) and hunt for AN7581 OMCI upstream
# register-programming sequences. Clean-room: we only read register offsets
# and immediate values, never copy code.
import sys, struct
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

KO = sys.argv[1] if len(sys.argv) > 1 else \
    "/e/WorkBuddy/OpenWrt/_src/stock_xg040g/rootfs/lib/modules/xpon_10g.ko"

# distinctive imm values to locate OMCI TX configuration
WATCH = {
    0x300101: "TX_OMCI_PRE_GET init value",
    0x528c:   "TX_OMCI_PRE_GET offset",
    0x5290:   "RX_OMCI_PRE_GET offset",
    0x5274:   "GEM_PORT_CFG offset",
    0x5250:   "TCONT_ID_CFG offset",
    0x5400:   "SW0_ENCSTART (CMAC)",
    0x5414:   "SW0_ENCINFO (CMAC)",
    0x59bc:   "OMCI_LEN_CTRL offset",
    0x48:     "OMCI GEM port id 0x048",
}

with open(KO, "rb") as f:
    elf = ELFFile(f)
    print("arch:", elf.get_machine_arch(), "entry:", hex(elf['e_entry']))

    # symbol table (function names if retained)
    syms = {}
    for s in elf.iter_sections():
        if isinstance(s, SymbolTableSection):
            for sym in s.iter_symbols():
                if sym['st_value']:
                    syms[sym['st_value']] = sym.name

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True

    # gather exec sections
    exec_secs = [s for s in elf.iter_sections()
                 if s['sh_flags'] & 0x4 and s['sh_type'] != 'SHT_NOBITS']

    hits = []  # (sec, vaddr, idx, reason)
    for sec in exec_secs:
        data = sec.data()
        base = sec['sh_addr']
        if not base:
            continue
        for ins in md.disasm(data, base):
            # scan immediates in operands
            for op in ins.operands:
                val = None
                if op.type == 1:  # register, skip
                    continue
                if op.type == 2:  # immediate
                    val = ins.operands[1].imm if False else None
                # capstone ARM64: op.imm
                try:
                    if op.type == 2:
                        val = op.imm
                except Exception:
                    val = None
            # also pull immediate from ins via regex on mnemonic operands
            if val is None:
                continue
            av = val & 0xffffffff
            if av in WATCH:
                hits.append((sec.name, ins.address, ins.mnemonic + " " + ins.op_str,
                             WATCH[av], av))

    print("\n=== immediate hits (value -> meaning) ===")
    for (sn, addr, asm, why, av) in hits:
        name = syms.get(addr, "")
        print(f"{sn} {hex(addr)}  {asm:40s} | {why} (0x{av:x})  f={name}")

    # also dump functions whose name contains omci/gem/tcont/cmac
    print("\n=== symbol names containing omci/gem/tcont/cmac/xpon/dma ===")
    seen = set()
    for addr, name in sorted(syms.items()):
        nl = name.lower()
        if any(k in nl for k in ('omci', 'gem', 'tcont', 'cmac', 'xpon', 'dma', 'ploam', 'mic')):
            if name not in seen:
                seen.add(name)
                print(f"  {hex(addr)}  {name}")
