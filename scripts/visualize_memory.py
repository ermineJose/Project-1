#!/usr/bin/env python3
"""
visualize_memory.py - Parse and visualize ARM64 memory mappings

WHAT THIS DOES:
Takes the output from our QEMU guest's memory explorer and draws
a visual map of how memory is laid out.

Run: python3 scripts/visualize_memory.py < captured_output.txt
 Or: python3 scripts/visualize_memory.py   (uses built-in sample data)
"""

import sys
import re

# ANSI colors for terminal output
class C:
    RED     = '\033[91m'
    GREEN   = '\033[92m'
    YELLOW  = '\033[93m'
    BLUE    = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN    = '\033[96m'
    GRAY    = '\033[90m'
    BOLD    = '\033[1m'
    RESET   = '\033[0m'

def perm_color(perms):
    """Color-code permissions for easy reading."""
    if 'x' in perms:
        return C.RED       # Executable = red (dangerous if writable too)
    if 'w' in perms:
        return C.YELLOW    # Writable = yellow
    return C.GREEN         # Read-only = green (safest)

def format_size(size_bytes):
    """Human-readable sizes."""
    if size_bytes >= 1024*1024*1024:
        return f"{size_bytes/(1024*1024*1024):.1f} GB"
    if size_bytes >= 1024*1024:
        return f"{size_bytes/(1024*1024):.1f} MB"
    if size_bytes >= 1024:
        return f"{size_bytes/1024:.1f} KB"
    return f"{size_bytes} B"

def parse_maps_line(line):
    """Parse a /proc/PID/maps line."""
    m = re.match(
        r'([0-9a-f]+)-([0-9a-f]+)\s+([\w-]+)\s+([0-9a-f]+)\s+(\S+)\s+(\d+)\s*(.*)',
        line.strip()
    )
    if not m:
        return None
    return {
        'start': int(m.group(1), 16),
        'end':   int(m.group(2), 16),
        'perms': m.group(3),
        'offset': m.group(4),
        'dev':   m.group(5),
        'inode': m.group(6),
        'name':  m.group(7).strip() or '[anon]',
    }

def parse_iomem_line(line):
    """Parse a /proc/iomem line."""
    m = re.match(r'\s*([0-9a-f]+)-([0-9a-f]+)\s*:\s*(.*)', line.strip())
    if not m:
        return None
    return {
        'start': int(m.group(1), 16),
        'end':   int(m.group(2), 16),
        'name':  m.group(3).strip(),
        'indent': len(line) - len(line.lstrip()),
    }

def draw_bar(fraction, width=40, color=C.GREEN):
    """Draw a proportional bar."""
    filled = int(fraction * width)
    return f"{color}{'█' * filled}{C.GRAY}{'░' * (width - filled)}{C.RESET}"

def visualize_virtual_memory(regions):
    """Draw the process virtual memory map."""
    if not regions:
        return

    print(f"\n{C.BOLD}{'='*70}")
    print(f"  VIRTUAL MEMORY MAP (What the process sees)")
    print(f"{'='*70}{C.RESET}\n")

    print(f"  {C.BOLD}{'Address Range':<36} {'Perms':<8} {'Size':<10} Region{C.RESET}")
    print(f"  {'─'*70}")

    total_size = sum(r['end'] - r['start'] for r in regions)

    for r in regions:
        size = r['end'] - r['start']
        color = perm_color(r['perms'])
        bar = draw_bar(size / total_size if total_size else 0, width=15, color=color)

        # Annotate what each region is for
        annotation = ""
        name = r['name']
        if 'busybox' in name and 'x' in r['perms']:
            annotation = "← program CODE (instructions)"
        elif 'busybox' in name and 'w' in r['perms']:
            annotation = "← program DATA (variables)"
        elif 'busybox' in name:
            annotation = "← program read-only DATA"
        elif name == '[heap]':
            annotation = "← HEAP (malloc/dynamic memory)"
        elif name == '[stack]':
            annotation = "← STACK (function calls, local vars)"
        elif name == '[vdso]':
            annotation = "← fast syscall trampoline"
        elif name == '[vvar]':
            annotation = "← kernel shared variables"

        perms_display = (
            f"{'r' if 'r' in r['perms'] else '-'}"
            f"{'w' if 'w' in r['perms'] else '-'}"
            f"{'x' if 'x' in r['perms'] else '-'}"
        )

        print(f"  {color}0x{r['start']:012x}-0x{r['end']:012x}{C.RESET}"
              f"  {color}{perms_display:<5}{C.RESET}"
              f"  {format_size(size):<8}"
              f"  {bar} {name} {C.CYAN}{annotation}{C.RESET}")

    print(f"\n  {C.GRAY}Total mapped: {format_size(total_size)}{C.RESET}")

    # Draw the big picture
    print(f"\n{C.BOLD}  ARM64 Virtual Address Space Layout:{C.RESET}\n")
    print(f"  0x{'0'*16}  ┌──────────────────────────┐")
    print(f"                    │ {C.GRAY}(unmapped/unused){C.RESET}        │")
    print(f"  0x{'00400000':>16}  ├──────────────────────────┤")
    print(f"                    │ {C.RED}Program Code (r-x){C.RESET}       │")
    print(f"                    ├──────────────────────────┤")
    print(f"                    │ {C.YELLOW}Program Data (rw-){C.RESET}      │")
    print(f"                    ├──────────────────────────┤")
    print(f"                    │ {C.YELLOW}Heap ↓ (grows down){C.RESET}     │")
    print(f"                    │ {C.GRAY}        ...               {C.RESET}│")
    print(f"                    │ {C.GRAY}   (huge gap here){C.RESET}       │")
    print(f"                    │ {C.GRAY}        ...               {C.RESET}│")
    print(f"                    │ {C.YELLOW}Stack ↑ (grows up){C.RESET}      │")
    print(f"                    ├──────────────────────────┤")
    print(f"                    │ {C.GREEN}vDSO / vvar{C.RESET}              │")
    print(f"  0x{'f'*16}  └──────────────────────────┘")
    print(f"                    │ {C.MAGENTA}Kernel space (off limits){C.RESET}│")
    print(f"                    └──────────────────────────┘")

def visualize_physical_memory(regions):
    """Draw the physical memory map."""
    if not regions:
        return

    print(f"\n{C.BOLD}{'='*70}")
    print(f"  PHYSICAL MEMORY MAP (What the hardware provides)")
    print(f"{'='*70}{C.RESET}\n")

    # Only show top-level regions (indent=0)
    top_regions = [r for r in regions if r['indent'] == 0]
    max_addr = max(r['end'] for r in top_regions) if top_regions else 1

    for r in top_regions:
        size = r['end'] - r['start'] + 1
        name = r['name']

        if 'System RAM' in name:
            color = C.GREEN
        elif 'Kernel' in name:
            color = C.RED
        elif 'pcie' in name.lower() or 'PCI' in name:
            color = C.BLUE
        elif 'pl0' in name:
            color = C.YELLOW
        else:
            color = C.CYAN

        bar_width = max(1, int((size / max_addr) * 40))
        bar = f"{color}{'█' * min(bar_width, 40)}{C.RESET}"

        print(f"  {color}0x{r['start']:010x}-0x{r['end']:010x}{C.RESET}"
              f"  {format_size(size):<10}"
              f"  {bar} {name}")

    print(f"\n{C.BOLD}  Physical Address Space Diagram:{C.RESET}\n")
    print(f"  0x{0:010x}  ┌──────────────────────────┐")
    print(f"                  │ {C.GRAY}(nothing / MMIO gap){C.RESET}     │")
    print(f"  0x{'09000000':>10}  │ {C.YELLOW}UART (serial console){C.RESET}    │")
    print(f"  0x{'10000000':>10}  │ {C.BLUE}PCIe MMIO space{C.RESET}          │")
    print(f"  0x{'40000000':>10}  ├──────────────────────────┤")
    print(f"                  │ {C.GREEN}System RAM (512 MB){C.RESET}      │")
    print(f"                  │  ┌ Kernel code{C.RESET}             │")
    print(f"                  │  ├ Kernel data             │")
    print(f"                  │  └ Free memory             │")
    print(f"  0x{'60000000':>10}  └──────────────────────────┘")
    print(f"                  │ {C.BLUE}PCIe config (ECAM){C.RESET}       │")
    print()

def visualize_kernel_sections(first_sym, last_sym, sections):
    """Draw kernel memory sections."""
    if not first_sym:
        return

    print(f"\n{C.BOLD}{'='*70}")
    print(f"  KERNEL MEMORY SECTIONS")
    print(f"{'='*70}{C.RESET}\n")

    # Parse key symbols
    key_syms = {}
    for addr_str, name in sections:
        addr = int(addr_str, 16)
        key_syms[name] = addr

    stext = key_syms.get('_stext', 0)
    if stext:
        print(f"  Kernel is loaded at virtual address: {C.BOLD}0x{stext:016x}{C.RESET}")
        print(f"  (In ARM64, kernel virtual addresses start with 0xffff...)")
        print()
        print(f"  {C.RED}┌─ _stext  (start of kernel code){C.RESET}")
        print(f"  {C.RED}│  Executable instructions{C.RESET}")
        print(f"  {C.RED}│  (functions like schedule(), fork(), etc.){C.RESET}")
        print(f"  {C.RED}└─ _etext  (end of kernel code){C.RESET}")
        print(f"  {C.YELLOW}┌─ _sdata  (start of kernel data){C.RESET}")
        print(f"  {C.YELLOW}│  Global variables{C.RESET}")
        print(f"  {C.YELLOW}└─ _edata  (end of kernel data){C.RESET}")
        print(f"  {C.GRAY}┌─ __bss_start  (uninitialized data){C.RESET}")
        print(f"  {C.GRAY}│  Zeroed at boot{C.RESET}")
        print(f"  {C.GRAY}└─ _end  (end of kernel image){C.RESET}")

def main():
    """Parse input and visualize."""
    # Try to read from stdin or use sample data
    if not sys.stdin.isatty():
        data = sys.stdin.read()
    else:
        # Read from captured output file
        import os
        capture = os.path.join(os.path.dirname(__file__), '..', 'captured_output.txt')
        if os.path.exists(capture):
            with open(capture) as f:
                data = f.read()
        else:
            print(f"{C.BOLD}Usage:{C.RESET}")
            print(f"  1. Boot QEMU:  ./boot.sh")
            print(f"  2. In QEMU, run: explore_memory > /dev/ttyAMA0")
            print(f"  3. Or capture: ./scripts/capture_and_visualize.sh")
            print()
            print("No input data. Generating visualization from sample data...")
            data = SAMPLE_DATA

    # Parse virtual memory regions
    virt_regions = []
    phys_regions = []
    kernel_sections = []
    first_sym = last_sym = None

    in_maps = False
    in_iomem = False
    in_kallsyms = False

    for line in data.split('\n'):
        # Detect sections
        if "OUR PROCESS'S VIRTUAL MEMORY MAP" in line:
            in_maps = True
            in_iomem = False
            in_kallsyms = False
            continue
        if "PHYSICAL MEMORY MAP" in line:
            in_iomem = True
            in_maps = False
            in_kallsyms = False
            continue
        if "KERNEL MEMORY SECTIONS" in line:
            in_kallsyms = True
            in_maps = False
            in_iomem = False
            continue
        if "===" in line:
            in_maps = False
            in_iomem = False
            in_kallsyms = False
            continue

        if in_maps:
            r = parse_maps_line(line)
            if r:
                virt_regions.append(r)

        if in_iomem:
            r = parse_iomem_line(line)
            if r:
                phys_regions.append(r)

        if in_kallsyms:
            m = re.match(r'\s*First symbol:\s*([0-9a-f]+)', line)
            if m:
                first_sym = m.group(1)
            m = re.match(r'\s*Last symbol:\s*([0-9a-f]+)', line)
            if m:
                last_sym = m.group(1)
            # Key kernel sections
            m = re.match(r'\s*([0-9a-f]+)\s+\w\s+(\S+)', line)
            if m:
                kernel_sections.append((m.group(1), m.group(2)))

    # Draw everything
    print(f"\n{C.BOLD}{C.CYAN}╔══════════════════════════════════════════════════════════════╗")
    print(f"║          ARM64 Memory Layout Visualization                  ║")
    print(f"╚══════════════════════════════════════════════════════════════╝{C.RESET}")

    visualize_physical_memory(phys_regions)
    visualize_virtual_memory(virt_regions)
    visualize_kernel_sections(first_sym, last_sym, kernel_sections)

    # Page table explanation
    print(f"\n{C.BOLD}{'='*70}")
    print(f"  HOW PAGE TABLES CONNECT EVERYTHING")
    print(f"{'='*70}{C.RESET}\n")
    print(f"  When busybox accesses address 0x00400000 (its code):")
    print(f"")
    print(f"  {C.CYAN}CPU{C.RESET} → \"I need data at VA 0x00400000\"")
    print(f"        ↓")
    print(f"  {C.YELLOW}MMU{C.RESET} → Looks up page table:")
    print(f"        Level 0: VA[47:39] = 0x000 → entry in PGD")
    print(f"        Level 1: VA[38:30] = 0x000 → entry in PUD")
    print(f"        Level 2: VA[29:21] = 0x002 → entry in PMD")
    print(f"        Level 3: VA[20:12] = 0x000 → entry in PTE")
    print(f"        ↓")
    print(f"  {C.GREEN}PTE{C.RESET} → Contains physical frame number + permissions")
    print(f"        ↓")
    print(f"  {C.GREEN}Physical RAM{C.RESET} → Access the actual byte in DRAM")
    print(f"")
    print(f"  This happens for EVERY memory access, billions of times")
    print(f"  per second. The TLB (Translation Lookaside Buffer) caches")
    print(f"  recent translations so it's fast.")
    print()

SAMPLE_DATA = ""  # Will be populated when we have real output

if __name__ == '__main__':
    main()
