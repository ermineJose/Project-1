#!/bin/bash
# =============================================================
# run_boot_trace.sh — Trace the ARM64 boot process via GDB
# =============================================================
#
# This traces the kernel from first instruction (MMU off)
# through MMU enable to start_kernel (MMU on).
#
# It starts its own QEMU, so don't run boot-debug.sh separately.
#
# HOW TO USE:
#   ./scripts/run_boot_trace.sh
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Kill any existing QEMU debug instance
pkill -f "qemu-system-aarch64.*-S" 2>/dev/null
sleep 2

echo "Starting fresh QEMU in debug mode..."
cd "$PROJECT_DIR"
nohup qemu-system-aarch64 -M virt -cpu cortex-a57 -m 512M -nographic \
    -kernel Image -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0 rdinit=/init loglevel=3 nokaslr" \
    -S -s </dev/null > /tmp/qemu-debug.log 2>&1 &
disown
sleep 2

if ! lsof -i :1234 >/dev/null 2>&1; then
    echo "ERROR: QEMU failed to start"
    exit 1
fi
echo "QEMU ready (paused at first instruction)."
echo ""

# Run the boot trace — kernel starts paused, so this script
# controls the breakpoints and continues.
gdb-multiarch -batch \
    -ex "set pagination off" \
    -ex "target remote :1234" \
    -ex "source ${SCRIPT_DIR}/02_boot_trace.gdb" \
    2>&1 | grep -v "^warning"

echo ""
echo "Cleaning up..."
pkill -f "qemu-system-aarch64.*-S" 2>/dev/null
