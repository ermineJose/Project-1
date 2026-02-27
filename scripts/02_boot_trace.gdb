# =============================================================
# 02_boot_trace.gdb — Trace ARM64 boot and MMU enable
# =============================================================
# Sourced by run_boot_trace.sh after GDB connects to a
# paused QEMU. The kernel hasn't started yet.
# =============================================================

echo \n
echo ============================================================\n
echo   ARM64 BOOT TRACE\n
echo ============================================================\n\n

# ---- STOP 1: First instruction (MMU OFF) ----
echo ===== STOP 1: First Instruction (MMU OFF) =====\n\n

printf "  PC  = 0x%lx\n", $pc
printf "  This is a PHYSICAL address (MMU is off)\n\n"

set $sctlr_early = $SCTLR
set $mmu_early = $sctlr_early & 1
printf "  SCTLR = 0x%lx\n", $sctlr_early
printf "  MMU   = %d", $mmu_early
if ($mmu_early)
    printf " (ON)\n"
else
    printf " (OFF -- no translation, as expected)\n"
end

printf "\n  X0 = 0x%lx  (DTB address from bootloader)\n", $x0
printf "  SP = 0x%lx\n\n", $sp

echo   First 5 instructions:\n
x/5i $pc

echo \n  KEY POINT: right now VA == PA. No translation.\n
echo   Address 0x40000000 means physical RAM at 0x40000000.\n\n

# ---- Continue to __primary_switch ----
# __primary_switch is where ARM64 sets up page tables and enables MMU.
# Since we have no symbols, we use a hardware watchpoint on SCTLR
# write. Alternative: step through known code.
# Simpler: break at a known kernel VA to catch post-MMU state.

# The kernel text starts at 0xffff800010000000 (with nokaslr).
# But we can't break on virtual addresses while MMU is off.
# Instead, we'll break on the physical address of __primary_switch.
# ARM64 kernel entry: the kernel is loaded at PA 0x40210000.
# __primary_switch is early in the boot code.

echo ===== Stepping to see MMU transition... =====\n\n
echo We will step through early boot to find when MMU turns on.\n
echo This checks SCTLR after each batch of steps.\n\n

# Step in chunks, checking SCTLR each time
set $step_count = 0
set $found_mmu = 0

# First do a large jump (the MMU enable is ~thousands of instructions in)
# Use 'stepi' to step individual instructions
# Let's step 500 at a time and check
while ($found_mmu == 0 && $step_count < 20)
    stepi 500
    set $step_count = $step_count + 1
    set $now_sctlr = $SCTLR
    set $now_mmu = $now_sctlr & 1
    if ($now_mmu)
        set $found_mmu = 1
        printf "\n  *** MMU ENABLED at step %d (after ~%d instructions) ***\n", $step_count, $step_count * 500
        printf "  PC = 0x%lx\n", $pc
    end
end

if ($found_mmu)
    # ---- STOP 2: MMU just turned on ----
    echo \n===== STOP 2: MMU Just Enabled =====\n\n

    set $mypc = (unsigned long long)$pc
    printf "  PC      = 0x%lx\n", $mypc
    printf "  SCTLR   = 0x%lx\n", (unsigned long long)$SCTLR
    printf "  MMU     = 1 (ON!)\n\n"

    set $my_ttbr0 = (unsigned long long)$TTBR0_EL1
    set $my_ttbr1 = (unsigned long long)$TTBR1_EL1
    set $my_tcr = (unsigned long long)$TCR_EL1
    printf "  TTBR0   = 0x%lx  (user page table)\n", $my_ttbr0
    printf "  TTBR1   = 0x%lx  (kernel page table)\n", $my_ttbr1
    printf "  TCR     = 0x%lx\n", $my_tcr

    set $t0sz = (int)($my_tcr & 0x3F)
    set $t1sz = (int)(($my_tcr >> 16) & 0x3F)
    printf "\n  VA config: user=%d bits, kernel=%d bits\n", 64-$t0sz, 64-$t1sz

    echo \n  Page tables are now ACTIVE. Every memory access goes:\n
    echo     VA -> L0 -> L1 -> L2 -> L3 -> PA -> RAM\n\n

    # Show the raw L0 entries
    set $ttbr1_base = $my_ttbr1 & 0x0000FFFFFFFFF000
    echo   Kernel L0 page table (via physical memory read):\n
    eval "monitor xp/4gx 0x%lx", $ttbr1_base
    set $k256 = $ttbr1_base + (unsigned long long)(256 * 8)
    echo \n  Entry [256] (kernel linear map):\n
    eval "monitor xp/1gx 0x%lx", $k256
else
    echo \n  Could not find MMU enable point within step limit.\n
    echo   The kernel may need more steps. Try increasing the limit.\n
end

echo \n
echo ============================================================\n
echo   BOOT TRACE COMPLETE\n
echo ============================================================\n\n
echo   What you observed:\n
echo     Stop 1: CPU entry, MMU OFF, physical addresses\n
echo     Stop 2: MMU just turned ON, page tables active\n\n
echo   What happened in ~2000 instructions:\n
echo     1. CPU started at PA 0x40000000 (no translation)\n
echo     2. Kernel built page tables in physical memory\n
echo     3. Set TTBR0/TTBR1 to point to these tables\n
echo     4. Wrote SCTLR bit[0]=1 -> MMU activated!\n
echo     5. Now every address goes through page table lookup\n\n
echo   The identity map trick:\n
echo     When MMU turns on, the NEXT instruction must still work.\n
echo     So the kernel maps the SAME physical page at BOTH:\n
echo       PA 0x40xxxxxx (temporary identity map)\n
echo       VA 0xffffxxxx (permanent kernel virtual address)\n
echo     After jumping to the virtual address, the identity map\n
echo     is removed.\n\n
echo   To see the fully booted state with all registers:\n
echo     ./scripts/run_gdb_inspect.sh\n
echo   To do a full page table walk:\n
echo     ./scripts/run_walk_pagetable.sh\n\n
echo ============================================================\n\n
