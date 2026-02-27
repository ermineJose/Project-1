# =============================================================
# 03_walk_pagetable.gdb — Manual ARM64 Page Table Walk
# =============================================================
#
# WHAT THIS DOES:
# Performs a REAL hardware-level page table walk:
#   1. Reads TTBR register (page table base address)
#   2. Extracts index bits from a virtual address
#   3. Reads raw 8-byte entries from PHYSICAL memory
#   4. Decodes permission/attribute bits
#   5. Follows pointers to the next level
#   6. Arrives at the final physical address
#
# Uses QEMU's "monitor xp" to read physical memory directly —
# exactly what the MMU hardware sees.
#
# HOW TO USE:
#   Terminal 1:  ./boot-debug.sh
#   Terminal 2:  gdb-multiarch -x scripts/03_walk_pagetable.gdb
#
# Or if already in GDB after boot:
#   (gdb) source scripts/03_walk_pagetable.gdb
#   (gdb) walk_kernel
#   (gdb) walk_user
# =============================================================

set pagination off

define walk_kernel
    echo \n
    echo ============================================================\n
    echo   MANUAL PAGE TABLE WALK — Kernel address\n
    echo   Walking: the PC (current instruction pointer)\n
    echo ============================================================\n\n

    set $va = $pc
    printf "Target VA = 0x%lx (current PC)\n\n", $va

    # Step 0: Get TTBR1 (kernel page table base)
    echo STEP 0: Read TTBR1_EL1 (kernel page table base)\n
    echo ────────────────────────────────────────────────\n
    set $ttbr = $TTBR1_EL1
    set $table_pa = $ttbr & 0x0000FFFFFFFFF000
    printf "  TTBR1_EL1  = 0x%lx\n", $ttbr
    printf "  Table base = PA 0x%lx\n\n", $table_pa

    # Step 1: Extract index bits
    echo STEP 1: Extract index bits from VA\n
    echo ────────────────────────────────────────────────\n
    printf "  VA = 0x%lx\n\n", $va
    set $l0_idx = ($va >> 39) & 0x1FF
    set $l1_idx = ($va >> 30) & 0x1FF
    set $l2_idx = ($va >> 21) & 0x1FF
    set $l3_idx = ($va >> 12) & 0x1FF
    set $offset = $va & 0xFFF
    printf "  Bits[47:39] -> L0 index = %d\n", $l0_idx
    printf "  Bits[38:30] -> L1 index = %d\n", $l1_idx
    printf "  Bits[29:21] -> L2 index = %d\n", $l2_idx
    printf "  Bits[20:12] -> L3 index = %d\n", $l3_idx
    printf "  Bits[11: 0] -> offset   = 0x%lx\n\n", $offset

    # Step 2: L0 lookup
    echo STEP 2: Level 0 (PGD) lookup\n
    echo ────────────────────────────────────────────────\n
    set $l0_entry_pa = $table_pa + ($l0_idx * 8)
    printf "  Entry addr = 0x%lx + (%d * 8) = PA 0x%lx\n", $table_pa, $l0_idx, $l0_entry_pa
    echo   Reading physical memory:\n
    eval "monitor xp/1gx 0x%lx", $l0_entry_pa
    echo \n

    # We need to parse the output. Since GDB can't easily capture
    # monitor output into variables, we read it via the linear map.
    # After MMU is on, Linux maps all physical RAM at a known VA offset.
    # We find it by: kernel_va - kernel_pa = linear_map_offset
    # For now, calculate the next table address manually.
    echo   (To decode: bit[0]=valid, bit[1]=table, bits[47:12]=next addr)\n
    echo   Follow along with the hex value printed above.\n\n

    # Step 3-5: Continue the walk using monitor
    echo STEP 3: Level 1 (PUD) — reading via QEMU monitor\n
    echo ────────────────────────────────────────────────\n
    echo   To find L1 entry: take bits[47:12] from L0 entry above,\n
    echo   add (L1_index * 8).\n
    echo   L1 raw table:\n
    # We dump the full range that L1 index falls into
    # First get L0 entry to find next table
    eval "monitor xp/1gx 0x%lx", $l0_entry_pa
    echo \n

    echo FULL L0 TABLE (first 4 + kernel entries):\n
    eval "monitor xp/4gx 0x%lx", $table_pa
    set $k256 = $table_pa + (256 * 8)
    echo \n  L0[256]:\n
    eval "monitor xp/1gx 0x%lx", $k256
    set $k511 = $table_pa + (511 * 8)
    echo   L0[511]:\n
    eval "monitor xp/1gx 0x%lx", $k511
    echo \n

    echo ============================================================\n
    echo   HOW TO MANUALLY CONTINUE THE WALK\n
    echo ============================================================\n\n
    echo Step-by-step:\n
    echo   1. From the L0 entry hex value, extract bits[47:12]\n
    echo      (mask with 0x0000FFFFFFFFF000) = next table PA\n\n
    echo   2. Add (L1_index * 8) to get L1 entry address\n
    printf "      L1 entry PA = next_table + (%d * 8)\n\n", $l1_idx
    echo   3. Read it:\n
    printf "      (gdb) monitor xp/1gx <L1_entry_PA>\n\n"
    echo   4. If bit[1]=1 (table), repeat for L2:\n
    printf "      L2 entry PA = next_table + (%d * 8)\n\n", $l2_idx
    echo   5. If bit[1]=1 (table), repeat for L3:\n
    printf "      L3 entry PA = next_table + (%d * 8)\n\n", $l3_idx
    echo   6. If bit[1]=0 at L1 or L2, it's a BLOCK mapping:\n
    echo      L1 block = 1 GB mapping (bits[47:30] = PA)\n
    echo      L2 block = 2 MB mapping (bits[47:21] = PA)\n\n
    echo   7. L3 entry: bits[47:12] = final page PA\n
    printf "      Final PA = page_PA + 0x%lx (offset)\n\n", $offset

    echo   Permission bits in ANY entry:\n
    echo     bit[6:7] AP  : 00=RW_EL1, 01=RW_ALL, 10=RO_EL1, 11=RO_ALL\n
    echo     bit[54]  XN  : 1=cannot execute\n
    echo     bit[53]  PXN : 1=kernel cannot execute\n
    echo     bit[10]  AF  : 1=page was accessed\n
    echo     bit[8:9] SH  : 00=none, 10=outer, 11=inner shareable\n
    echo \n
    echo ============================================================\n\n
end

define walk_auto
    echo \n
    echo ============================================================\n
    echo   AUTOMATED PAGE TABLE WALK\n
    echo ============================================================\n\n

    # Get TTBR1 for kernel walk
    set $ttbr = $TTBR1_EL1
    set $l0_pa = $ttbr & 0x0000FFFFFFFFF000
    set $va = (unsigned long long)$pc

    printf "Walking VA 0x%lx\n\n", $va

    # Cast to unsigned to avoid sign-extension issues with kernel addresses
    set $l0_idx = (int)(($va >> 39) & 0x1FF)
    set $l1_idx = (int)(($va >> 30) & 0x1FF)
    set $l2_idx = (int)(($va >> 21) & 0x1FF)
    set $l3_idx = (int)(($va >> 12) & 0x1FF)
    set $offset = (unsigned long long)($va & 0xFFF)

    printf "Indices: L0=%d L1=%d L2=%d L3=%d offset=0x%lx\n\n", $l0_idx, $l1_idx, $l2_idx, $l3_idx, $offset

    # L0
    set $l0_entry_pa = (unsigned long long)$l0_pa + (unsigned long long)($l0_idx * 8)
    printf "L0: reading PA 0x%lx\n", $l0_entry_pa
    eval "monitor xp/1gx 0x%lx", $l0_entry_pa

    # To get the value into GDB, we use the kernel's linear map.
    # Linux maps all of physical memory at 0xffff800000000000 + PA (with nokaslr).
    # So we can read PA via VA = 0xffff800000000000 + PA
    set $linmap = (unsigned long long)0xffff800000000000

    # Read L0 entry via linear map
    set $l0_va = $linmap + $l0_entry_pa
    set $l0_entry = *(unsigned long long *)$l0_va
    printf "  L0 entry = 0x%lx  valid=%d type=%d\n", $l0_entry, (int)($l0_entry & 1), (int)(($l0_entry >> 1) & 1)

    set $l0_valid = (int)($l0_entry & 1)
    if (!$l0_valid)
        echo  FAULT at L0 - address not mapped!\n
    else
        set $l0_is_table = (int)(($l0_entry >> 1) & 1)
        if (!$l0_is_table)
            echo  L0 BLOCK (512GB) - unusual!\n
        else
            set $l1_pa = (unsigned long long)($l0_entry & 0x0000FFFFFFFFF000)
            printf "  -> L1 table at PA 0x%lx\n\n", $l1_pa

            # L1
            set $l1_entry_pa = $l1_pa + (unsigned long long)($l1_idx * 8)
            printf "L1: reading PA 0x%lx\n", $l1_entry_pa
            eval "monitor xp/1gx 0x%lx", $l1_entry_pa
            set $l1_va = $linmap + $l1_entry_pa
            set $l1_entry = *(unsigned long long *)$l1_va
            printf "  L1 entry = 0x%lx  valid=%d type=%d\n", $l1_entry, (int)($l1_entry & 1), (int)(($l1_entry >> 1) & 1)

            set $l1_valid = (int)($l1_entry & 1)
            if (!$l1_valid)
                echo  FAULT at L1!\n
            else
                set $l1_is_table = (int)(($l1_entry >> 1) & 1)
                if (!$l1_is_table)
                    # 1GB block mapping
                    set $block_pa = (unsigned long long)($l1_entry & 0x0000FFFFC0000000)
                    set $final_pa = $block_pa | ($va & 0x3FFFFFFF)
                    printf "\n  ** 1GB BLOCK MAPPING **\n"
                    printf "  VA 0x%lx -> PA 0x%lx\n", $va, $final_pa
                    set $ap = (int)(($l1_entry >> 6) & 3)
                    set $xn = (int)(($l1_entry >> 54) & 1)
                    set $af = (int)(($l1_entry >> 10) & 1)
                    printf "  AP=%d  XN=%d  AF=%d\n", $ap, $xn, $af
                else
                    set $l2_pa = (unsigned long long)($l1_entry & 0x0000FFFFFFFFF000)
                    printf "  -> L2 table at PA 0x%lx\n\n", $l2_pa

                    # L2
                    set $l2_entry_pa = $l2_pa + (unsigned long long)($l2_idx * 8)
                    printf "L2: reading PA 0x%lx\n", $l2_entry_pa
                    eval "monitor xp/1gx 0x%lx", $l2_entry_pa
                    set $l2_va = $linmap + $l2_entry_pa
                    set $l2_entry = *(unsigned long long *)$l2_va
                    printf "  L2 entry = 0x%lx  valid=%d type=%d\n", $l2_entry, (int)($l2_entry & 1), (int)(($l2_entry >> 1) & 1)

                    set $l2_valid = (int)($l2_entry & 1)
                    if (!$l2_valid)
                        echo  FAULT at L2!\n
                    else
                        set $l2_is_table = (int)(($l2_entry >> 1) & 1)
                        if (!$l2_is_table)
                            # 2MB block mapping
                            set $block_pa = (unsigned long long)($l2_entry & 0x0000FFFFFFE00000)
                            set $final_pa = $block_pa | ($va & 0x1FFFFF)
                            printf "\n  ** 2MB BLOCK MAPPING **\n"
                            printf "  VA 0x%lx -> PA 0x%lx\n\n", $va, $final_pa
                            set $ap = (int)(($l2_entry >> 6) & 3)
                            set $xn = (int)(($l2_entry >> 54) & 1)
                            set $pxn = (int)(($l2_entry >> 53) & 1)
                            set $af = (int)(($l2_entry >> 10) & 1)
                            set $sh = (int)(($l2_entry >> 8) & 3)
                            printf "  Permissions:\n"
                            printf "    AP  = %d  ", $ap
                            if ($ap == 0)
                                printf "(RW kernel only)\n"
                            end
                            if ($ap == 1)
                                printf "(RW all)\n"
                            end
                            if ($ap == 2)
                                printf "(RO kernel only)\n"
                            end
                            if ($ap == 3)
                                printf "(RO all)\n"
                            end
                            printf "    XN  = %d  ", $xn
                            if ($xn)
                                printf "(no execute)\n"
                            else
                                printf "(executable)\n"
                            end
                            printf "    PXN = %d  AF = %d  SH = %d\n", $pxn, $af, $sh
                        else
                            set $l3_pa = (unsigned long long)($l2_entry & 0x0000FFFFFFFFF000)
                            printf "  -> L3 table at PA 0x%lx\n\n", $l3_pa

                            # L3
                            set $l3_entry_pa = $l3_pa + (unsigned long long)($l3_idx * 8)
                            printf "L3: reading PA 0x%lx\n", $l3_entry_pa
                            eval "monitor xp/1gx 0x%lx", $l3_entry_pa
                            set $l3_va = $linmap + $l3_entry_pa
                            set $l3_entry = *(unsigned long long *)$l3_va
                            printf "  L3 entry = 0x%lx  valid=%d\n", $l3_entry, (int)($l3_entry & 1)

                            set $l3_valid = (int)($l3_entry & 1)
                            if (!$l3_valid)
                                echo  FAULT at L3!\n
                            else
                                set $page_pa = (unsigned long long)($l3_entry & 0x0000FFFFFFFFF000)
                                set $final_pa = $page_pa | $offset
                                printf "\n  ** 4KB PAGE MAPPING **\n"
                                printf "  VA 0x%lx -> PA 0x%lx\n\n", $va, $final_pa
                                set $ap = (int)(($l3_entry >> 6) & 3)
                                set $xn = (int)(($l3_entry >> 54) & 1)
                                set $pxn = (int)(($l3_entry >> 53) & 1)
                                set $af = (int)(($l3_entry >> 10) & 1)
                                set $sh = (int)(($l3_entry >> 8) & 3)
                                printf "  Permissions:\n"
                                printf "    AP  = %d  ", $ap
                                if ($ap == 0)
                                    printf "(RW kernel only)\n"
                                end
                                if ($ap == 1)
                                    printf "(RW all)\n"
                                end
                                if ($ap == 2)
                                    printf "(RO kernel only)\n"
                                end
                                if ($ap == 3)
                                    printf "(RO all)\n"
                                end
                                printf "    XN  = %d  ", $xn
                                if ($xn)
                                    printf "(no execute)\n"
                                else
                                    printf "(executable)\n"
                                end
                                printf "    PXN = %d  AF = %d  SH = %d\n", $pxn, $af, $sh

                                echo \n  Verification — read 4 bytes at physical address:\n
                                eval "monitor xp/1xw 0x%lx", $final_pa
                            end
                        end
                    end
                end
            end
        end
    end

    echo \n
    printf "  RESULT: VA 0x%lx\n", $va
    printf "      L0[%d] -> L1[%d] -> L2[%d] -> L3[%d] + 0x%lx\n", $l0_idx, $l1_idx, $l2_idx, $l3_idx, $offset
    printf "      = PA 0x%lx\n", $final_pa
    echo \n============================================================\n\n
end

echo \n
echo ============================================================\n
echo   PAGE TABLE WALK TOOLS LOADED\n
echo ============================================================\n
echo \n
echo   walk_kernel  - Walk page table for current PC\n
echo   walk_auto    - Full automated walk with decoded permissions\n
echo \n
echo   Quick start:\n
echo     1. Boot QEMU: ./boot-debug.sh  (in another terminal)\n
echo     2. Connect:   target remote :1234\n
echo     3. Boot:      continue\n
echo     4. Pause:     Ctrl-C\n
echo     5. Walk:      walk_auto\n
echo \n
echo ============================================================\n\n
