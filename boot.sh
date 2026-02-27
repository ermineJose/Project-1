#!/bin/bash
# =============================================================
# boot.sh - Boot ARM64 Linux in QEMU
# =============================================================
#
# WHAT THIS DOES:
# Starts a virtual ARM64 computer (like a computer inside your
# computer) and boots Linux on it.
#
# QEMU is an emulator - it pretends to be ARM64 hardware even
# though your real machine is x86_64. It's slow but works.
#
# The flags explained:
#   -M virt         = Use QEMU's generic ARM virtual machine
#   -cpu cortex-a57 = Emulate a Cortex-A57 CPU (common ARM64 chip)
#   -m 512M         = Give the VM 512MB of RAM
#   -nographic      = No GUI window, use terminal for console
#   -kernel Image   = Our ARM64 Linux kernel
#   -initrd ...     = Our tiny BusyBox filesystem (loaded into RAM)
#   -append "..."   = Kernel command line arguments
#
# To exit QEMU: press Ctrl-A then X
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "====================================="
echo "  Booting ARM64 Linux in QEMU"
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
    -append "console=ttyAMA0 rdinit=/init loglevel=3"
