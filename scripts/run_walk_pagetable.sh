#!/bin/bash
# =============================================================
# run_walk_pagetable.sh — Manual page table walk via GDB
# =============================================================
#
# HOW TO USE:
#   Terminal 1:  ./boot-debug.sh
#   Terminal 2:  ./scripts/run_walk_pagetable.sh
#
# Or let it start QEMU automatically:
#   ./scripts/run_walk_pagetable.sh
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Start QEMU if not running
if ! lsof -i :1234 >/dev/null 2>&1; then
    echo "Starting QEMU in debug mode..."
    cd "$PROJECT_DIR"
    nohup qemu-system-aarch64 -M virt -cpu cortex-a57 -m 512M -nographic \
        -kernel Image -initrd initramfs.cpio.gz \
        -append "console=ttyAMA0 rdinit=/init loglevel=3 nokaslr" \
        -S -s </dev/null > /tmp/qemu-debug.log 2>&1 &
    disown
    sleep 2

    # Need to boot the kernel first
    echo "Booting kernel..."
    gdb-multiarch -batch \
        -ex "target remote :1234" \
        -ex "continue" 2>/dev/null &
    GDB_PID=$!
    sleep 15
    kill $GDB_PID 2>/dev/null
    wait $GDB_PID 2>/dev/null
    sleep 1
    echo "Kernel booted."
fi

echo ""
echo "Connecting GDB for page table walk..."
echo ""

# Connect and auto-stop, then run the walk (using Python for reliable parsing)
gdb-multiarch -batch \
    -ex "set pagination off" \
    -ex "target remote :1234" \
    -ex "source ${SCRIPT_DIR}/03_walk_pagetable.py" \
    -ex "walk_auto" \
    2>&1 | grep -v "^warning"
