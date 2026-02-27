# ARM Boot & Memory Mapping Explorer - Learning Guide

## What You'll Learn

This project teaches you how ARM64 computers organize memory — the foundation
you need before understanding hypervisors (which add *another* layer on top).

---

## Part 1: The Big Picture (Layman's Terms)

### What is memory?

Your computer's RAM is like a massive grid of numbered mailboxes.
Each mailbox holds 1 byte (8 bits). A computer with 512 MB of RAM
has about 536 million mailboxes, numbered 0 to 536,870,911.

### Why do we need virtual memory?

**Problem:** If two programs both want to use mailbox #1000, they'd
overwrite each other's data. Chaos.

**Solution:** Give each program its own *fake* numbering system.
Program A thinks it's using mailbox #1000, but the hardware secretly
redirects it to real mailbox #50000. Program B also thinks it's using
mailbox #1000, but gets redirected to real mailbox #90000.

- **Virtual Address (VA):** The fake mailbox number (what programs see)
- **Physical Address (PA):** The real mailbox number (actual RAM location)
- **Page Table:** The lookup table that maps fake → real
- **MMU:** The hardware chip that does the lookup automatically

### Why "pages"?

Translating every single byte address would require a gigantic lookup table.
Instead, memory is divided into **pages** (usually 4 KB = 4096 bytes each).
The translation only happens at the page level, not individual bytes.

Think of it like postal ZIP codes: instead of mapping every house individually,
you map ZIP codes to neighborhoods, then find the house within that area.

---

## Part 2: ARM64 Boot Flow

When you run `./boot.sh`, here's what happens step by step:

```
1. QEMU starts
   └─ Creates a virtual ARM64 machine (CPU, RAM, UART, etc.)

2. QEMU loads the kernel into RAM at address 0x40210000
   └─ This is just copying the Image file into the virtual RAM

3. CPU starts executing at the kernel entry point
   └─ At this point, MMU is OFF — virtual = physical addresses
   └─ The kernel is running in "identity mapped" mode

4. Kernel early boot:
   a. Sets up exception vectors (interrupt handlers)
   b. Detects how much RAM is available
   c. Creates initial page tables
   d. TURNS ON THE MMU ← this is the magic moment
   └─ Now virtual addresses are active!

5. Kernel main boot:
   a. Initializes drivers (UART, timer, etc.)
   b. Sets up memory management (buddy allocator, slab, etc.)
   c. Mounts the initramfs (our BusyBox filesystem)
   d. Runs /init (our script!)

6. init script runs
   └─ Mounts /proc, /sys, /dev
   └─ You get a shell
```

### Key Moment: MMU Turn-On

Before the MMU is on:
- Address 0x40210000 means "go to physical RAM at 0x40210000"

After the MMU is on:
- Address 0xffffaaa101e10000 means "look up the page table, which
  says this maps to physical address 0x40210000"

The kernel remaps itself from low physical addresses to high virtual
addresses (starting with 0xffff...). This is why kernel symbols like
`_stext` have addresses like `0xffffaaa101e10000`.

---

## Part 3: ARM64 Page Table Structure

ARM64 uses a **4-level page table** with 4KB pages:

```
 63        48 47    39 38    30 29    21 20    12 11        0
┌───────────┬────────┬────────┬────────┬────────┬───────────┐
│  sign ext │  L0    │  L1    │  L2    │  L3    │  offset   │
│ (all 1/0) │ index  │ index  │ index  │ index  │ (in page) │
└───────────┴────────┴────────┴────────┴────────┴───────────┘
              │         │         │         │         │
              │         │         │         │         └─ Byte within 4KB page
              │         │         │         └─ Which entry in PTE table (512 options)
              │         │         └─ Which entry in PMD table (512 options)
              │         └─ Which entry in PUD table (512 options)
              └─ Which entry in PGD table (512 options)
```

**Library analogy:**
- L0 (PGD) = Which building? (512 buildings, each covers 512 GB)
- L1 (PUD) = Which floor?    (512 floors, each covers 1 GB)
- L2 (PMD) = Which shelf?    (512 shelves, each covers 2 MB)
- L3 (PTE) = Which book?     (512 books, each covers 4 KB)
- Offset   = Which page in the book? (4096 pages)

### Page Table Entry Format

Each entry in a page table is 64 bits (8 bytes):

```
 63  54 53  48 47              12 11  2 1 0
┌──────┬──────┬──────────────────┬─────┬─┬─┐
│ upper│ res  │  output address  │attrs│T│V│
│ attrs│      │  (physical addr) │     │ │ │
└──────┴──────┴──────────────────┴─────┴─┴─┘
                                        │ └─ Valid bit (1=mapped, 0=fault)
                                        └─ Table bit (1=points to next table,
                                                      0=this IS the final mapping)
```

**Permission bits:**
- `AP[2:1]`: Access Permission (read/write, user/kernel)
- `XN`: Execute Never (can code run from here?)
- `AF`: Access Flag (has this page been used?)
- `SH`: Shareability (for multi-core cache coherence)

---

## Part 4: What the Explorer Shows You

### Physical Memory Map (`/proc/iomem`)

This is the real hardware layout — what physical addresses correspond to:

```
09000000-09000fff : UART     ← Serial console (how we see text)
10000000-3efeffff : PCIe     ← PCI Express bus (for devices)
40000000-5fffffff : RAM      ← Our 512 MB of actual memory
  40210000-4184ffff : Kernel code  ← The kernel's instructions
  41ea0000-421fffff : Kernel data  ← The kernel's variables
```

### Virtual Memory Map (`/proc/self/maps`)

This is what our process (BusyBox shell) sees:

```
00400000-005b3000 r-x  /bin/busybox  ← Program code (read+execute)
005c9000-005d0000 r--  /bin/busybox  ← Read-only data (strings, etc.)
005d0000-005d3000 rw-  /bin/busybox  ← Writable data (global variables)
0fcc7000-0fce9000 rw-  [heap]        ← Dynamic memory (malloc)
ffff8e8fd000      r-x  [vdso]        ← Fast syscall page
fffffcdb2000      rw-  [stack]       ← Function call stack
```

**Permission meanings:**
- `r-x` = Can read and execute, but NOT write (code is protected!)
- `rw-` = Can read and write, but NOT execute (data can't be run as code!)
- `r--` = Read only (constants, string literals)

This separation (code ≠ data) is a crucial security feature. If an attacker
injects data, they can't execute it because data pages aren't executable.

### Kernel Sections

The kernel's own virtual addresses (in high memory, 0xffff...):

```
_stext  → _etext    = Kernel code (schedule(), fork(), etc.)
_sdata  → _edata    = Kernel global variables
__bss_start → _end  = Uninitialized data (zeroed at boot)
```

---

## Part 5: Hands-On Exercises

### Exercise 1: Boot and Explore

```bash
cd ~/arm-boot-explorer
./boot.sh
# Inside QEMU:
explore_memory
cat /proc/self/maps
cat /proc/iomem
# Exit: Ctrl-A then X
```

### Exercise 2: Visualize

```bash
./scripts/capture_and_visualize.sh
# Or if you have captured_output.txt:
python3 scripts/visualize_memory.py < captured_output.txt
```

### Exercise 3: Debug with GDB (Advanced)

Terminal 1:
```bash
./boot-debug.sh
```

Terminal 2 (requires gdb-multiarch):
```bash
gdb-multiarch -x scripts/gdb_pagetable_walk.py
(gdb) target remote :1234
(gdb) continue
# Wait for boot, then Ctrl-C
(gdb) arm64_show_regs
(gdb) arm64_walk_pagetable
(gdb) arm64_walk_pagetable 0xffff800010000000
```

### Exercise 4: Observe VA→PA Translation

Inside QEMU, compare virtual and physical addresses:
```sh
# See where busybox is mapped in virtual memory
cat /proc/self/maps | grep busybox

# See where the kernel is in physical memory
cat /proc/iomem | grep Kernel

# The page tables bridge the gap between these two views!
```

---

## Part 6: Why This Matters for Hypervisors

A hypervisor (like KVM) adds ANOTHER layer of address translation:

```
Without hypervisor (what we built):
  Program VA  →  [Guest Page Table]  →  Physical Address

With hypervisor:
  Program VA  →  [Guest Page Table]  →  Guest PA (IPA)
                                             ↓
                                    [Stage-2 Page Table]
                                             ↓
                                      Host Physical Address
```

The guest OS thinks its "physical memory" starts at address 0x40000000,
but the hypervisor secretly maps that to wherever it actually put the
VM's memory. The guest doesn't know it's being tricked!

ARM64 calls this **Stage-2 translation** or **Intermediate Physical
Addresses (IPA)**. The hardware supports this natively — the MMU can
do both translations in a single memory access.

This is why understanding page tables is prerequisite #1 for hypervisors.

---

## Quick Reference

| File | Purpose |
|------|---------|
| `boot.sh` | Boot ARM64 Linux in QEMU (interactive) |
| `boot-debug.sh` | Boot with GDB debug server |
| `rootfs/init` | Init script (first program kernel runs) |
| `rootfs/bin/explore_memory` | Memory exploration script (runs in guest) |
| `scripts/visualize_memory.py` | Visualize captured output (runs on host) |
| `scripts/capture_and_visualize.sh` | Auto-capture and visualize |
| `scripts/gdb_pagetable_walk.py` | GDB commands for page table walking |

| Key Concept | One-liner |
|-------------|-----------|
| Virtual Address | Fake address programs see |
| Physical Address | Real address in RAM chips |
| Page Table | Maps fake → real addresses |
| MMU | Hardware that reads page tables |
| TLB | Cache for recent translations |
| Page | 4 KB chunk (smallest unit of mapping) |
| TTBR0 | Page table base for userspace |
| TTBR1 | Page table base for kernel |

| QEMU Keys | Action |
|-----------|--------|
| Ctrl-A, X | Exit QEMU |
| Ctrl-A, C | QEMU monitor console |
| Ctrl-A, H | Help |
