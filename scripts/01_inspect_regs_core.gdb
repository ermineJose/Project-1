# Core MMU register inspection (called after kernel has booted)
# GDB connects and auto-stops the target.

echo \n
echo ============================================================\n
echo   ARM64 MMU REGISTER INSPECTION\n
echo ============================================================\n

printf "\n  PC = 0x%lx (where the kernel was interrupted)\n\n", $pc

# ---- SCTLR_EL1 ----
echo --- SCTLR_EL1 (System Control Register) ---\n
echo Controls the MMU on/off switch, caches, endianness.\n\n
set $sctlr = $SCTLR
printf "  SCTLR_EL1 = 0x%lx\n\n", $sctlr
set $mmu_on = $sctlr & 1
printf "  Bit[0]  M   (MMU Enable)         = %d", $mmu_on
if ($mmu_on)
    printf "  <-- MMU is ON\n"
else
    printf "  <-- MMU is OFF\n"
end
set $dcache = ($sctlr >> 2) & 1
printf "  Bit[2]  C   (Data cache)          = %d", $dcache
if ($dcache)
    printf "  <-- ON\n"
else
    printf "  <-- OFF\n"
end
set $icache = ($sctlr >> 12) & 1
printf "  Bit[12] I   (Instruction cache)   = %d", $icache
if ($icache)
    printf "  <-- ON\n"
else
    printf "  <-- OFF\n"
end
set $wxn = ($sctlr >> 19) & 1
printf "  Bit[19] WXN (Write-implies-XN)     = %d", $wxn
if ($wxn)
    printf "  <-- W^X enforced\n"
else
    printf "\n"
end
set $ee = ($sctlr >> 25) & 1
printf "  Bit[25] EE  (Endianness)           = %d", $ee
if ($ee)
    printf "  <-- Big Endian\n"
else
    printf "  <-- Little Endian\n"
end
echo \n

# ---- TTBR0_EL1 ----
echo --- TTBR0_EL1 (Userspace Page Table Base) ---\n
echo Points to the L0 page table for the current user process.\n\n
set $ttbr0 = $TTBR0_EL1
printf "  TTBR0_EL1 = 0x%lx\n", $ttbr0
set $asid0 = ($ttbr0 >> 48) & 0xFFFF
printf "  ASID      = %d (Address Space ID)\n", $asid0
set $baddr0 = $ttbr0 & 0x0000FFFFFFFFFFFF
set $baddr0 = $baddr0 & 0x0000FFFFFFFFF000
printf "  Base PA   = 0x%lx\n", $baddr0
echo \n

# ---- TTBR1_EL1 ----
echo --- TTBR1_EL1 (Kernel Page Table Base) ---\n
echo Points to the L0 page table for kernel space (0xffff...).\n\n
set $ttbr1 = $TTBR1_EL1
printf "  TTBR1_EL1 = 0x%lx\n", $ttbr1
set $baddr1 = $ttbr1 & 0x0000FFFFFFFFFFFF
set $baddr1 = $baddr1 & 0x0000FFFFFFFFF000
printf "  Base PA   = 0x%lx\n", $baddr1
echo \n

# ---- TCR_EL1 ----
echo --- TCR_EL1 (Translation Control Register) ---\n
echo Configures page size, VA width, and physical address size.\n\n
set $tcr = $TCR_EL1
printf "  TCR_EL1   = 0x%lx\n\n", $tcr

set $t0sz = $tcr & 0x3F
set $t1sz = ($tcr >> 16) & 0x3F
printf "  T0SZ = %d  --> User VA   = %d bits\n", $t0sz, 64 - $t0sz
printf "  T1SZ = %d  --> Kernel VA = %d bits\n", $t1sz, 64 - $t1sz

set $tg0 = ($tcr >> 14) & 0x3
printf "  TG0  = %d  --> ", $tg0
if ($tg0 == 0)
    printf "4 KB pages (user)\n"
end
if ($tg0 == 1)
    printf "64 KB pages (user)\n"
end
if ($tg0 == 2)
    printf "16 KB pages (user)\n"
end

set $tg1 = ($tcr >> 30) & 0x3
printf "  TG1  = %d  --> ", $tg1
if ($tg1 == 0)
    printf "4 KB pages (kernel)\n"
end
if ($tg1 == 1)
    printf "16 KB pages (kernel)\n"
end
if ($tg1 == 2)
    printf "4 KB pages (kernel)\n"
end
if ($tg1 == 3)
    printf "64 KB pages (kernel)\n"
end

set $ips = ($tcr >> 32) & 0x7
printf "  IPS  = %d  --> PA width: ", $ips
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
printf "  MMU:             "
if ($mmu_on)
    printf "ENABLED\n"
else
    printf "DISABLED\n"
end
printf "  User PT base:    PA 0x%lx\n", $baddr0
printf "  Kernel PT base:  PA 0x%lx\n", $baddr1
printf "  Page size:       4 KB\n"
printf "  User VA bits:    %d\n", 64 - $t0sz
printf "  Kernel VA bits:  %d\n", 64 - $t1sz
echo ============================================================\n

# ---- Show raw page table entries ----
echo \n--- L0 Page Table Entries (raw physical memory) ---\n\n

echo User L0 table (first 4 entries):\n
eval "monitor xp/4gx 0x%lx", $baddr0

echo \nKernel L0 table:\n
echo   [256] (covers 0xffff800000000000):\n
set $k256 = $baddr1 + (256 * 8)
eval "monitor xp/1gx 0x%lx", $k256
echo   [511] (covers 0xffffff8000000000):\n
set $k511 = $baddr1 + (511 * 8)
eval "monitor xp/1gx 0x%lx", $k511

echo \n============================================================\n\n
