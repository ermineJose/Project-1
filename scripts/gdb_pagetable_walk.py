#!/usr/bin/env python3
"""
gdb_pagetable_walk.py - Walk ARM64 page tables via GDB

HOW TO USE:
1. Start QEMU in debug mode:
     ./boot-debug.sh

2. In another terminal, connect GDB:
     gdb-multiarch -x scripts/gdb_pagetable_walk.py

   Or manually in GDB:
     (gdb) target remote :1234
     (gdb) source scripts/gdb_pagetable_walk.py
     (gdb) continue
     ... (wait for kernel to boot) ...
     (gdb) Ctrl-C
     (gdb) arm64_walk_pagetable 0xffff800000000000

WHAT THIS DOES:
Reads the ARM64 page table registers directly from the CPU and
manually walks the page table hierarchy, just like the MMU hardware
does. This gives you the deepest possible view into memory translation.

ARM64 PAGE TABLE FORMAT:
  - TTBR0_EL1: Page table base for userspace (VA < 0x0000ffffffffffff)
  - TTBR1_EL1: Page table base for kernel    (VA >= 0xffff000000000000)
  - Each table entry is 8 bytes (64 bits)
  - Bits [47:12] = next-level table address or output address
  - Bit  [0]     = valid/present
  - Bits [1]     = table (1) or block (0) descriptor
"""

import struct
import sys

# This script is designed to be sourced by GDB
# Check if we're running inside GDB
try:
    import gdb

    class Arm64PageTableWalk(gdb.Command):
        """Walk ARM64 page tables from GDB.

        Usage: arm64_walk_pagetable [virtual_address]
        If no address given, dumps the full page table structure.
        """

        def __init__(self):
            super().__init__("arm64_walk_pagetable", gdb.COMMAND_DATA)

        def read_memory(self, addr, size):
            """Read physical memory via QEMU's GDB stub."""
            try:
                inferior = gdb.selected_inferior()
                mem = inferior.read_memory(addr, size)
                return bytes(mem)
            except gdb.MemoryError:
                return None

        def read_u64(self, addr):
            """Read a 64-bit value from memory."""
            data = self.read_memory(addr, 8)
            if data is None:
                return None
            return struct.unpack('<Q', data)[0]

        def read_sysreg(self, name):
            """Read an ARM64 system register."""
            try:
                val = gdb.parse_and_eval(f"${name}")
                return int(val)
            except:
                return None

        def decode_pte(self, entry, level):
            """Decode a page table entry and return human-readable info."""
            if entry is None:
                return "UNREADABLE"

            valid = entry & 1
            if not valid:
                return "INVALID (not mapped)"

            is_table = (entry >> 1) & 1  # bit[1]
            addr_mask = 0x0000FFFFFFFFF000  # bits [47:12]
            next_addr = entry & addr_mask

            # Permission bits (for block/page entries)
            ap = (entry >> 6) & 0x3      # AP[2:1]
            xn = (entry >> 54) & 1       # XN (execute never)
            pxn = (entry >> 53) & 1      # PXN (privileged execute never)
            af = (entry >> 10) & 1       # Access flag
            sh = (entry >> 8) & 0x3      # Shareability
            attr_idx = (entry >> 2) & 0x7  # AttrIndx

            ap_str = {0: "RW_EL1", 1: "RW_ALL", 2: "RO_EL1", 3: "RO_ALL"}.get(ap, "??")
            sh_str = {0: "Non-share", 1: "Reserved", 2: "Outer-share", 3: "Inner-share"}.get(sh, "??")

            if level < 3 and is_table:
                return f"TABLE → 0x{next_addr:012x}"
            else:
                block_size = {0: "512GB", 1: "1GB", 2: "2MB", 3: "4KB"}.get(level, "??")
                xn_str = "NoExec" if xn else "Exec"
                return (f"{'BLOCK' if level < 3 else 'PAGE'} → PA 0x{next_addr:012x} "
                        f"[{block_size}] {ap_str} {xn_str} {sh_str} "
                        f"{'Accessed' if af else 'NotAccessed'}")

        def walk_table(self, table_addr, va_start, level, target_va=None, max_entries=512):
            """Recursively walk a page table level."""
            level_names = ["PGD (L0)", "PUD (L1)", "PMD (L2)", "PTE (L3)"]
            bits_per_level = [39, 30, 21, 12]
            indent = "  " * level

            if level > 3:
                return

            print(f"{indent}{'─' * 40}")
            print(f"{indent}{level_names[level]} at PA 0x{table_addr:012x}")
            print(f"{indent}{'─' * 40}")

            entries_shown = 0
            for i in range(512):
                entry_addr = table_addr + i * 8
                entry = self.read_u64(entry_addr)

                if entry is None:
                    continue
                if not (entry & 1):  # Skip invalid entries
                    continue

                # Calculate the VA range this entry covers
                shift = bits_per_level[level]
                va = va_start | (i << shift)
                # Sign extend for kernel addresses
                if va & (1 << 47):
                    va |= 0xFFFF000000000000

                decoded = self.decode_pte(entry, level)

                # If we have a target VA, only follow the matching path
                if target_va is not None:
                    idx_for_target = (target_va >> shift) & 0x1FF
                    if i != idx_for_target:
                        continue

                print(f"{indent}  [{i:3d}] VA 0x{va:016x}: {decoded}")
                print(f"{indent}        raw: 0x{entry:016x}")
                entries_shown += 1

                # Recurse into table descriptors
                is_table = (entry >> 1) & 1
                if level < 3 and is_table:
                    next_addr = entry & 0x0000FFFFFFFFF000
                    self.walk_table(next_addr, va_start | (i << shift),
                                   level + 1, target_va, max_entries)

                if entries_shown >= max_entries and target_va is None:
                    print(f"{indent}  ... (truncated, {entries_shown} entries shown)")
                    break

        def invoke(self, arg, from_tty):
            """GDB command entry point."""
            args = gdb.string_to_argv(arg)

            target_va = None
            if args:
                try:
                    target_va = int(args[0], 0)
                except ValueError:
                    print(f"Invalid address: {args[0]}")
                    return

            print("=" * 60)
            print("  ARM64 Page Table Walk")
            print("=" * 60)

            # Read translation table base registers
            ttbr0 = self.read_sysreg("TTBR0_EL1")
            ttbr1 = self.read_sysreg("TTBR1_EL1")
            tcr = self.read_sysreg("TCR_EL1")
            sctlr = self.read_sysreg("SCTLR_EL1")

            print(f"\n  System Registers:")
            if ttbr0 is not None:
                print(f"    TTBR0_EL1 = 0x{ttbr0:016x}  (userspace page table base)")
            if ttbr1 is not None:
                print(f"    TTBR1_EL1 = 0x{ttbr1:016x}  (kernel page table base)")
            if tcr is not None:
                print(f"    TCR_EL1   = 0x{tcr:016x}  (translation control)")
                t0sz = tcr & 0x3F
                t1sz = (tcr >> 16) & 0x3F
                tg0 = (tcr >> 14) & 0x3
                tg1 = (tcr >> 30) & 0x3
                granule = {0: "4KB", 1: "64KB", 2: "16KB"}.get(tg0, "??")
                print(f"              T0SZ={t0sz} T1SZ={t1sz} "
                      f"Granule0={granule}")
                print(f"              User VA bits: {64-t0sz}, "
                      f"Kernel VA bits: {64-t1sz}")
            if sctlr is not None:
                mmu_on = sctlr & 1
                print(f"    SCTLR_EL1 = 0x{sctlr:016x}  "
                      f"(MMU {'ENABLED' if mmu_on else 'DISABLED'})")

            print()

            if target_va is not None:
                print(f"  Walking page table for VA 0x{target_va:016x}:")
                print()
                # Use TTBR1 for kernel addresses, TTBR0 for user
                if target_va >= 0xFFFF000000000000:
                    if ttbr1 is None:
                        print("  Cannot read TTBR1_EL1")
                        return
                    base = ttbr1 & 0x0000FFFFFFFFFFFF  # mask out ASID
                    print(f"  Using TTBR1 (kernel) base: 0x{base:012x}")
                    self.walk_table(base, 0xFFFF000000000000, 0, target_va, 512)
                else:
                    if ttbr0 is None:
                        print("  Cannot read TTBR0_EL1")
                        return
                    base = ttbr0 & 0x0000FFFFFFFFFFFF
                    print(f"  Using TTBR0 (user) base: 0x{base:012x}")
                    self.walk_table(base, 0, 0, target_va, 512)
            else:
                # Dump both
                if ttbr0 is not None:
                    base = ttbr0 & 0x0000FFFFFFFFFFFF
                    print(f"  TTBR0 (userspace) page table:")
                    self.walk_table(base, 0, 0, None, 10)

                if ttbr1 is not None:
                    base = ttbr1 & 0x0000FFFFFFFFFFFF
                    print(f"\n  TTBR1 (kernel) page table:")
                    self.walk_table(base, 0xFFFF000000000000, 0, None, 10)

            print("\n" + "=" * 60)

    class Arm64ShowRegs(gdb.Command):
        """Show key ARM64 system registers with explanations."""

        def __init__(self):
            super().__init__("arm64_show_regs", gdb.COMMAND_DATA)

        def invoke(self, arg, from_tty):
            print("=" * 50)
            print("  ARM64 Key Registers")
            print("=" * 50)

            regs = [
                ("PC",        "Program Counter (current instruction)"),
                ("SP",        "Stack Pointer"),
                ("TTBR0_EL1", "User page table base"),
                ("TTBR1_EL1", "Kernel page table base"),
                ("TCR_EL1",   "Translation Control Register"),
                ("SCTLR_EL1", "System Control Register"),
                ("MAIR_EL1",  "Memory Attribute Indirection Register"),
                ("CurrentEL", "Current Exception Level"),
            ]

            for name, desc in regs:
                try:
                    val = gdb.parse_and_eval(f"${name}")
                    print(f"  {name:<12} = 0x{int(val):016x}  ({desc})")
                except:
                    print(f"  {name:<12} = <unavailable>  ({desc})")

            print("=" * 50)

    # Register commands
    Arm64PageTableWalk()
    Arm64ShowRegs()
    print("ARM64 page table tools loaded!")
    print("Commands: arm64_walk_pagetable [VA], arm64_show_regs")
    print("")
    print("Quick start:")
    print("  (gdb) target remote :1234")
    print("  (gdb) continue")
    print("  ... wait for kernel to boot, then Ctrl-C ...")
    print("  (gdb) arm64_show_regs")
    print("  (gdb) arm64_walk_pagetable")
    print("  (gdb) arm64_walk_pagetable 0xffff800010000000")

except ImportError:
    # Not running inside GDB - print usage
    print("This script must be run inside GDB:")
    print("  gdb-multiarch -x scripts/gdb_pagetable_walk.py")
    print("")
    print("Or in an existing GDB session:")
    print("  (gdb) source scripts/gdb_pagetable_walk.py")
    sys.exit(1)
