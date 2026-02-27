#!/bin/bash
# =============================================================
# run_gdb_inspect.sh — Run GDB register inspection reliably
# =============================================================
#
# HOW TO USE:
#   Terminal 1:  ./boot-debug.sh
#   Terminal 2:  ./scripts/run_gdb_inspect.sh
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Step 1: Start QEMU if not running
if ! lsof -i :1234 >/dev/null 2>&1; then
    echo "Starting QEMU in debug mode..."
    cd "$PROJECT_DIR"
    nohup qemu-system-aarch64 -M virt -cpu cortex-a57 -m 512M -nographic \
        -kernel Image -initrd initramfs.cpio.gz \
        -append "console=ttyAMA0 rdinit=/init loglevel=3 nokaslr" \
        -S -s </dev/null > /tmp/qemu-debug.log 2>&1 &
    disown
    sleep 2
    echo "QEMU started."
fi

# Step 2: Connect GDB, continue kernel, wait, then interrupt and inspect
# We use 'expect'-style approach: feed commands with delays
echo "Connecting GDB and booting kernel..."
gdb-multiarch -batch -ex "target remote :1234" \
    -ex "continue" \
    2>&1 &
GDB_PID=$!

# Let kernel boot
echo "Waiting 15 seconds for kernel to boot..."
sleep 15

# Kill the first GDB (it was just used to continue the VM)
kill $GDB_PID 2>/dev/null
wait $GDB_PID 2>/dev/null
sleep 1

# Step 3: Connect fresh GDB to the now-running (and booted) kernel
# This GDB will interrupt the target on connect
echo ""
echo "Connecting GDB to inspect registers..."
echo ""

gdb-multiarch -batch \
    -ex "set pagination off" \
    -ex "target remote :1234" \
    -ex "source ${SCRIPT_DIR}/01_inspect_regs_core.gdb" \
    2>&1 | grep -v "^warning"
