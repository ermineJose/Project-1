#!/bin/bash
# =============================================================
# capture_and_visualize.sh
# Boots QEMU, captures memory explorer output, then visualizes it
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="$PROJECT_DIR/captured_output.txt"

echo "Booting ARM64 Linux in QEMU and running memory explorer..."
echo "(This takes ~15 seconds)"
echo ""

# Boot QEMU with auto-run init, capture output
timeout 25 qemu-system-aarch64 \
    -M virt -cpu cortex-a57 -m 512M -nographic \
    -kernel "$PROJECT_DIR/Image" \
    -initrd "$PROJECT_DIR/initramfs.cpio.gz" \
    -append "console=ttyAMA0 rdinit=/init-auto loglevel=3" \
    > "$OUTPUT" 2>/dev/null &

QEMU_PID=$!
sleep 20
kill $QEMU_PID 2>/dev/null
wait $QEMU_PID 2>/dev/null

echo "Output captured to: $OUTPUT"
echo ""

# Now visualize
python3 "$SCRIPT_DIR/visualize_memory.py" < "$OUTPUT"
