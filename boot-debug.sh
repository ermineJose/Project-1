#!/bin/bash
# =============================================================
# boot-debug.sh - Boot ARM64 Linux with GDB debugging enabled
# =============================================================
#
# WHAT THIS DOES:
# Same as boot.sh, but ALSO starts a GDB debug server on
# port 1234. You can connect to it from another terminal with:
#
#   gdb-multiarch -ex "target remote :1234"
#
# This lets you:
#   - Pause the kernel at any point
#   - Inspect CPU registers
#   - Read memory (including page tables!)
#   - Step through kernel code instruction by instruction
#
# Extra flags:
#   -S           = Start paused (wait for GDB to connect)
#   -s           = Start GDB server on port 1234
#   -d guest_errors = Log guest CPU errors to stderr
#
# To exit QEMU: press Ctrl-A then X
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "====================================="
echo "  Booting ARM64 Linux in QEMU"
echo "  DEBUG MODE - GDB server on :1234"
echo "  VM is PAUSED, waiting for GDB..."
echo ""
echo "  In another terminal, run:"
echo "    gdb-multiarch \\"
echo "      -ex 'target remote :1234' \\"
echo "      -ex 'continue'"
echo ""
echo "  Exit: Ctrl-A then X"
echo "====================================="
echo ""

qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a57 \
    -m 512M \
    -nographic \
    -kernel "${SCRIPT_DIR}/Image" \
    -initrd "${SCRIPT_DIR}/initramfs.cpio.gz" \
    -append "console=ttyAMA0 rdinit=/init loglevel=3 nokaslr" \
    -S -s \
    -d guest_errors
