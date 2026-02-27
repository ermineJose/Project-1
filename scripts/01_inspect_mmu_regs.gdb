# =============================================================
# 01_inspect_mmu_regs.gdb — Read & decode ARM64 MMU registers
# =============================================================
#
# WHAT THIS DOES:
# Reads the 4 key registers that control the MMU (the hardware
# that translates virtual → physical addresses).
#
# HOW TO USE:
#   Terminal 1:  ./boot-debug.sh
#   Terminal 2:  gdb-multiarch -x scripts/01_inspect_mmu_regs.gdb
#
# It will connect, let the kernel boot, then dump all MMU state.
# =============================================================

set pagination off

# Connect to QEMU's GDB server
target remote :1234

# Let kernel boot. We add a temporary hardware breakpoint at a
# known instruction address, or simply continue in background.
echo \n===== Letting kernel boot (15 sec)... =====\n
# Resume the paused VM, wait for boot, then stop it.
# GDB's 'continue &' runs in background so we can interrupt later.
continue &
shell sleep 15
interrupt
# Small delay for GDB to process the stop
shell sleep 1

echo \n
echo ============================================================\n
echo   ARM64 MMU REGISTER INSPECTION\n
echo ============================================================\n

# ---- SCTLR_EL1: System Control Register ----
echo \n--- SCTLR_EL1 (System Control Register) ---\n
echo This register has the MMU on/off switch.\n\n
set $sctlr = $SCTLR
printf "  SCTLR_EL1 = 0x%lx\n", $sctlr
printf "\n"
set $mmu_on = $sctlr & 1
printf "  Bit[0]  M   (MMU Enable)         = %d", $mmu_on
if ($mmu_on)
    printf "  <-- MMU is ON\n"
else
    printf "  <-- MMU is OFF (VA = PA)\n"
end
set $align = ($sctlr >> 1) & 1
printf "  Bit[1]  A   (Alignment check)    = %d\n", $align
set $dcache = ($sctlr >> 2) & 1
printf "  Bit[2]  C   (Data cache enable)  = %d", $dcache
if ($dcache)
    printf "  <-- Caching ON\n"
else
    printf "  <-- Caching OFF\n"
end
set $icache = ($sctlr >> 12) & 1
printf "  Bit[12] I   (Instruction cache)  = %d\n", $icache
set $wxn = ($sctlr >> 19) & 1
printf "  Bit[19] WXN (Write implies XN)   = %d", $wxn
if ($wxn)
    printf "  <-- Writable pages can't execute (W^X)\n"
else
    printf "\n"
end
set $ee = ($sctlr >> 25) & 1
printf "  Bit[25] EE  (Endianness at EL1)  = %d", $ee
if ($ee)
    printf "  <-- Big Endian\n"
else
    printf "  <-- Little Endian\n"
end
echo \n

# ---- TTBR0_EL1: User page table base ----
echo --- TTBR0_EL1 (Userspace Page Table Base) ---\n
echo This points to the root of the page table for user processes.\n
echo Think: where does the address book for programs start?\n\n
set $ttbr0 = $TTBR0_EL1
printf "  TTBR0_EL1  = 0x%lx\n", $ttbr0
set $asid0 = ($ttbr0 >> 48) & 0xFFFF
printf "  ASID       = %d (Address Space ID -- which process)\n", $asid0
set $baddr0 = $ttbr0 & 0x0000FFFFFFFFFFFF
printf "  BADDR      = 0x%lx (physical addr of L0 table)\n", $baddr0
echo \n

# ---- TTBR1_EL1: Kernel page table base ----
echo --- TTBR1_EL1 (Kernel Page Table Base) ---\n
echo This points to the root of the page table for the kernel.\n
echo All addresses starting with 0xFFFF... use this table.\n\n
set $ttbr1 = $TTBR1_EL1
printf "  TTBR1_EL1  = 0x%lx\n", $ttbr1
set $asid1 = ($ttbr1 >> 48) & 0xFFFF
printf "  ASID       = %d\n", $asid1
set $baddr1 = $ttbr1 & 0x0000FFFFFFFFFFFF
printf "  BADDR      = 0x%lx (physical addr of L0 table)\n", $baddr1
echo \n

# ---- TCR_EL1: Translation Control Register ----
echo --- TCR_EL1 (Translation Control Register) ---\n
echo This configures HOW page tables work: page size, number\n
echo of address bits, cacheability of table walks, etc.\n\n
set $tcr = $TCR_EL1
printf "  TCR_EL1    = 0x%lx\n", $tcr
printf "\n"

set $t0sz = $tcr & 0x3F
set $t1sz = ($tcr >> 16) & 0x3F
set $user_bits = 64 - $t0sz
set $kern_bits = 64 - $t1sz
printf "  T0SZ = %d  --> Userspace VA size = %d bits\n", $t0sz, $user_bits
printf "  T1SZ = %d  --> Kernel VA size    = %d bits\n", $t1sz, $kern_bits

set $tg0 = ($tcr >> 14) & 0x3
printf "  TG0  = %d  --> ", $tg0
if ($tg0 == 0)
    printf "4 KB pages (userspace)\n"
end
if ($tg0 == 1)
    printf "64 KB pages (userspace)\n"
end
if ($tg0 == 2)
    printf "16 KB pages (userspace)\n"
end

set $tg1 = ($tcr >> 30) & 0x3
printf "  TG1  = %d  --> ", $tg1
if ($tg1 == 1)
    printf "16 KB pages (kernel)\n"
end
if ($tg1 == 2)
    printf "4 KB pages (kernel)\n"
end
if ($tg1 == 3)
    printf "64 KB pages (kernel)\n"
end
if ($tg1 == 0)
    printf "4 KB pages (kernel, alternate encoding)\n"
end

set $ips = ($tcr >> 32) & 0x7
printf "  IPS  = %d  --> Physical address size: ", $ips
if ($ips == 0)
    printf "32 bits (4 GB)\n"
end
if ($ips == 1)
    printf "36 bits (64 GB)\n"
end
if ($ips == 2)
    printf "40 bits (1 TB)\n"
end
if ($ips == 3)
    printf "42 bits (4 TB)\n"
end
if ($ips == 4)
    printf "44 bits (16 TB)\n"
end
if ($ips == 5)
    printf "48 bits (256 TB)\n"
end

echo \n
echo ============================================================\n
echo   SUMMARY\n
echo ============================================================\n
printf "  MMU:            "
if ($mmu_on)
    printf "ENABLED\n"
else
    printf "DISABLED\n"
end
printf "  User PT base:   PA 0x%lx\n", $baddr0
printf "  Kernel PT base: PA 0x%lx\n", $baddr1
printf "  Page size:      "
if ($tg0 == 0)
    printf "4 KB\n"
end
if ($tg0 == 1)
    printf "64 KB\n"
end
if ($tg0 == 2)
    printf "16 KB\n"
end
printf "  User VA bits:   %d\n", $user_bits
printf "  Kernel VA bits: %d\n", $kern_bits

echo \n--- Raw L0 page table entries (via QEMU physical memory read) ---\n\n
echo Userspace L0 table (first 4 entries):\n
eval "monitor xp/4gx 0x%lx", $baddr0
echo \nKernel L0 table entry [256] (0xffff800...):\n
set $k256 = $baddr1 + (256 * 8)
eval "monitor xp/1gx 0x%lx", $k256
echo Kernel L0 table entry [511] (0xffffff...):\n
set $k511 = $baddr1 + (511 * 8)
eval "monitor xp/1gx 0x%lx", $k511

echo \n============================================================\n
echo \n
echo ===== DONE. You can now: =====\n
echo   continue             -- resume kernel\n
echo   Ctrl-C               -- pause again\n
echo   quit                 -- exit GDB\n
echo \n
