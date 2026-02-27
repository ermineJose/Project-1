"""
03_walk_pagetable.py — Full automated ARM64 page table walk via GDB+Python

Uses QEMU's 'monitor xp' to read physical memory directly.
This is the most reliable method — it doesn't depend on kernel
virtual address layout.

Load in GDB:  source scripts/03_walk_pagetable.py
Then run:     walk_auto
              walk_va 0xffff800010000000
"""

import gdb
import re

class WalkPageTable(gdb.Command):
    """Walk ARM64 page tables. Usage: walk_va <address> or walk_auto (uses PC)"""

    def __init__(self):
        super().__init__("walk_va", gdb.COMMAND_DATA)

    def read_phys_u64(self, pa):
        """Read 8 bytes from physical memory using QEMU monitor."""
        result = gdb.execute(f"monitor xp/1gx 0x{pa:x}", to_string=True)
        # Parse: "00000000xxxxxxxx: 0xYYYYYYYYYYYYYYYY"
        m = re.search(r'0x([0-9a-fA-F]+)\s*$', result.strip())
        if m:
            return int(m.group(1), 16)
        # Try alternate format
        parts = result.strip().split()
        for p in reversed(parts):
            p = p.strip().rstrip('\n')
            if p.startswith('0x'):
                return int(p, 16)
            try:
                return int(p, 16)
            except ValueError:
                continue
        return None

    def read_reg(self, name):
        """Read a register value."""
        try:
            val = gdb.parse_and_eval(f"${name}")
            return int(val) & 0xFFFFFFFFFFFFFFFF  # force unsigned
        except:
            return None

    def decode_ap(self, ap):
        return {0: "RW_EL1 only", 1: "RW_ALL", 2: "RO_EL1 only", 3: "RO_ALL"}.get(ap, "??")

    def invoke(self, arg, from_tty):
        args = gdb.string_to_argv(arg)
        if not args:
            print("Usage: walk_va <virtual_address>")
            print("Example: walk_va 0xffff800008cc895c")
            return
        va = int(args[0], 0) & 0xFFFFFFFFFFFFFFFF
        self.do_walk(va)

    def do_walk(self, va):
        print()
        print("=" * 60)
        print("  MANUAL ARM64 PAGE TABLE WALK")
        print(f"  VA = 0x{va:016x}")
        print("=" * 60)

        # Step 0: Choose TTBR
        is_kernel = (va >> 55) & 1
        if is_kernel:
            ttbr = self.read_reg("TTBR1_EL1")
            print(f"\n  Kernel address -> using TTBR1_EL1 = 0x{ttbr:016x}")
        else:
            ttbr = self.read_reg("TTBR0_EL1")
            print(f"\n  User address -> using TTBR0_EL1 = 0x{ttbr:016x}")

        table_pa = ttbr & 0x0000FFFFFFFFF000
        print(f"  Page table base PA = 0x{table_pa:012x}")

        # Step 1: Extract indices
        l0_idx = (va >> 39) & 0x1FF
        l1_idx = (va >> 30) & 0x1FF
        l2_idx = (va >> 21) & 0x1FF
        l3_idx = (va >> 12) & 0x1FF
        offset = va & 0xFFF

        print(f"\n  Index extraction from VA 0x{va:016x}:")
        print(f"    L0 index [47:39] = {l0_idx}")
        print(f"    L1 index [38:30] = {l1_idx}")
        print(f"    L2 index [29:21] = {l2_idx}")
        print(f"    L3 index [20:12] = {l3_idx}")
        print(f"    Offset   [11:0]  = 0x{offset:03x}")

        # Walk each level
        levels = [
            ("L0 (PGD)", l0_idx, 39, None),
            ("L1 (PUD)", l1_idx, 30, 0x0000FFFFC0000000),  # 1GB block mask
            ("L2 (PMD)", l2_idx, 21, 0x0000FFFFFFE00000),  # 2MB block mask
            ("L3 (PTE)", l3_idx, 12, 0x0000FFFFFFFFF000),  # 4KB page mask
        ]

        current_table = table_pa
        final_pa = None

        for level, (name, idx, shift, block_mask) in enumerate(levels):
            entry_pa = current_table + (idx * 8)
            print(f"\n  STEP {level+2}: {name}")
            print(f"  {'─' * 50}")
            print(f"    Table PA    = 0x{current_table:012x}")
            print(f"    Entry PA    = 0x{current_table:012x} + ({idx} * 8) = 0x{entry_pa:012x}")

            entry = self.read_phys_u64(entry_pa)
            if entry is None:
                print(f"    ERROR: Could not read physical memory at 0x{entry_pa:012x}")
                return

            print(f"    Raw entry   = 0x{entry:016x}")

            valid = entry & 1
            is_table = (entry >> 1) & 1

            print(f"    Bit[0] valid = {valid}", end="")
            if not valid:
                print("  <-- FAULT! Address not mapped.")
                return
            print("  (mapped)")

            if level == 3:
                # L3: always a page descriptor (bit[1] must be 1)
                page_pa = entry & 0x0000FFFFFFFFF000
                final_pa = page_pa | offset
                print(f"    Bit[1] page  = {is_table}  (page descriptor)")
                print(f"\n    ** 4KB PAGE MAPPING **")
                print(f"    Physical frame = 0x{page_pa:012x}")
                print(f"    Final PA       = 0x{page_pa:012x} | 0x{offset:03x} = 0x{final_pa:012x}")
                self.print_permissions(entry)
                break
            elif not is_table and level > 0:
                # Block mapping
                block_va_mask = (1 << shift) - 1
                block_pa_base = entry & block_mask
                final_pa = block_pa_base | (va & block_va_mask)
                block_size = {30: "1GB", 21: "2MB"}.get(shift, "?")
                print(f"    Bit[1] type  = 0  (BLOCK descriptor)")
                print(f"\n    ** {block_size} BLOCK MAPPING **")
                print(f"    Block base PA = 0x{block_pa_base:012x}")
                print(f"    Final PA      = 0x{final_pa:012x}")
                self.print_permissions(entry)
                break
            else:
                # Table descriptor -> follow to next level
                next_table = entry & 0x0000FFFFFFFFF000
                print(f"    Bit[1] type  = 1  (table -> next level)")
                print(f"    Next table  = PA 0x{next_table:012x}")
                current_table = next_table

        # Print final result
        if final_pa is not None:
            print(f"\n  {'=' * 50}")
            print(f"  RESULT:")
            print(f"  VA 0x{va:016x}")
            print(f"     |")
            print(f"     +-- L0[{l0_idx:3d}]")
            print(f"     +-- L1[{l1_idx:3d}]")
            print(f"     +-- L2[{l2_idx:3d}]")
            print(f"     +-- L3[{l3_idx:3d}] + offset 0x{offset:03x}")
            print(f"     |")
            print(f"     v")
            print(f"  PA 0x{final_pa:012x}")

            # Verify: read data at the physical address
            print(f"\n  Verification (4 bytes at PA 0x{final_pa:012x}):")
            gdb.execute(f"monitor xp/1xw 0x{final_pa:x}")

        print(f"\n{'=' * 60}\n")

    def print_permissions(self, entry):
        """Decode and print permission bits from a page table entry."""
        ap = (entry >> 6) & 3
        xn = (entry >> 54) & 1
        pxn = (entry >> 53) & 1
        af = (entry >> 10) & 1
        sh = (entry >> 8) & 3
        attr = (entry >> 2) & 7

        sh_str = {0: "Non-shareable", 1: "Reserved", 2: "Outer", 3: "Inner"}.get(sh, "?")

        print(f"\n    Permissions:")
        print(f"      AP  [7:6]  = {ap}  ({self.decode_ap(ap)})")
        print(f"      XN  [54]   = {xn}  ({'No execute' if xn else 'Executable'})")
        print(f"      PXN [53]   = {pxn}  ({'Kernel no-execute' if pxn else 'Kernel executable'})")
        print(f"      AF  [10]   = {af}  ({'Accessed' if af else 'Not accessed'})")
        print(f"      SH  [9:8]  = {sh}  ({sh_str} shareable)")
        print(f"      Attr[4:2]  = {attr}  (memory type index)")


class WalkAuto(gdb.Command):
    """Walk page tables for the current PC."""

    def __init__(self, walker):
        super().__init__("walk_auto", gdb.COMMAND_DATA)
        self.walker = walker

    def invoke(self, arg, from_tty):
        pc = int(gdb.parse_and_eval("$pc")) & 0xFFFFFFFFFFFFFFFF
        print(f"\nWalking page table for current PC = 0x{pc:016x}")
        self.walker.do_walk(pc)


walker = WalkPageTable()
WalkAuto(walker)

print("Page table walk tools loaded!")
print("  walk_auto            - walk for current PC")
print("  walk_va <address>    - walk for any VA")
