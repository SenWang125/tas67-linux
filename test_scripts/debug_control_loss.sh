#!/bin/bash
# Debug script to investigate why LDG controls disappear after stress test

CARD="0"
PREFIX="TAS0"

echo "=================================================="
echo "TAS6754 Control Loss Diagnostic"
echo "=================================================="
echo ""

# Save ALSA mixer state; restore automatically on exit (normal or error)
ALSA_STATE=$(mktemp /tmp/alsa-test-XXXXXX.state)
cleanup() {
    alsactl restore -f "$ALSA_STATE" 2>/dev/null
    rm -f "$ALSA_STATE"
}
trap cleanup EXIT
alsactl store -f "$ALSA_STATE" 2>/dev/null

# Function to list all TAS controls
list_tas_controls() {
    echo "All TAS6754 controls:"
    amixer -c $CARD controls 2>/dev/null | grep "name='$PREFIX" | sed "s/.*name='//;s/'.*$//" | sort
    echo ""
    echo "Total count: $(amixer -c $CARD controls 2>/dev/null | grep -c "name='$PREFIX")"
}

trigger_control() {
    local ctrl_name="$PREFIX $1"
    python3 -c "
import ctypes, os, fcntl, sys
class _ElemId(ctypes.Structure):
    _fields_ = [('numid', ctypes.c_uint32), ('iface', ctypes.c_int32),
                ('device', ctypes.c_uint32), ('subdevice', ctypes.c_uint32),
                ('name', ctypes.c_char * 44), ('index', ctypes.c_uint32)]
class _ValUnion(ctypes.Union):
    _fields_ = [('integer', ctypes.c_int64 * 128),
                ('enumerated', ctypes.c_uint32 * 128),
                ('bytes', ctypes.c_uint8 * 512)]
class _ElemValue(ctypes.Structure):
    _fields_ = [('id', _ElemId), ('_ind', ctypes.c_uint32), ('_pad', ctypes.c_uint32),
                ('value', _ValUnion), ('reserved', ctypes.c_uint8 * 128)]
ELEM_WRITE = (3 << 30) | (ctypes.sizeof(_ElemValue) << 16) | (ord('U') << 8) | 0x13
ev = _ElemValue()
ev.id.iface = 2
ev.id.name = sys.argv[1].encode()[:43]
ev.value.integer[0] = 1
try:
    fd = os.open(sys.argv[2], os.O_RDWR)
    fcntl.ioctl(fd, ELEM_WRITE, ev)
    os.close(fd)
except OSError as e:
    sys.exit(e.errno)
" "$ctrl_name" "/dev/snd/controlC${CARD}"
}

# Capture initial state
echo "========== BEFORE STRESS TEST =========="
list_tas_controls > /tmp/controls_before.txt
cat /tmp/controls_before.txt

echo ""
echo "Looking for LDG-related controls..."
amixer -c $CARD controls 2>/dev/null | grep "name='$PREFIX" | grep -iE "LDG|load" | sed "s/.*name='//;s/'.*$//"
echo ""

# Check specific controls
echo "Checking specific LDG controls:"
for ctrl in "DC LDG Trigger" "DC LDG Result" "DC LDG Auto Diagnostics Switch"; do
    if amixer -c $CARD cget name="$PREFIX $ctrl" >/dev/null 2>&1; then
        echo "  ✓ $ctrl - EXISTS"
    else
        echo "  ✗ $ctrl - MISSING"
    fi
done

echo ""
echo "Press ENTER to run short stress test (10 seconds)..."
read

# Run abbreviated stress test
echo ""
echo "========== RUNNING STRESS TEST (10s) =========="
echo "Starting workers..."

# Background workers
(while true; do trigger_control "DC LDG Trigger"; sleep 1; done) &
LDG_PID=$!

(while true; do amixer -c $CARD cset name="$PREFIX DSP Signal Path Mode" 0 >/dev/null 2>&1; sleep 0.5; amixer -c $CARD cset name="$PREFIX DSP Signal Path Mode" 1 >/dev/null 2>&1; sleep 0.5; done) &
DSP_PID=$!

(while true; do amixer -c $CARD cset name="$PREFIX Analog Playback Volume" 0 >/dev/null 2>&1; sleep 0.3; amixer -c $CARD cset name="$PREFIX Analog Playback Volume" 31 >/dev/null 2>&1; sleep 0.3; done) &
VOL_PID=$!

echo "Workers started: LDG=$LDG_PID, DSP=$DSP_PID, VOL=$VOL_PID"

# Run for 10 seconds
sleep 10

# Stop workers
echo "Stopping workers..."
kill $LDG_PID $DSP_PID $VOL_PID 2>/dev/null
wait $LDG_PID $DSP_PID $VOL_PID 2>/dev/null

echo "Workers stopped"
echo ""

# Capture final state
echo "========== AFTER STRESS TEST =========="
list_tas_controls > /tmp/controls_after.txt
cat /tmp/controls_after.txt

echo ""
echo "Looking for LDG-related controls..."
amixer -c $CARD controls 2>/dev/null | grep "name='$PREFIX" | grep -iE "LDG|load" | sed "s/.*name='//;s/'.*$//"
echo ""

# Check specific controls again
echo "Checking specific LDG controls:"
for ctrl in "DC LDG Trigger" "DC LDG Result" "DC LDG Auto Diagnostics Switch"; do
    if amixer -c $CARD cget name="$PREFIX $ctrl" >/dev/null 2>&1; then
        echo "  ✓ $ctrl - EXISTS"
    else
        echo "  ✗ $ctrl - MISSING"
    fi
done

echo ""
echo "========== COMPARISON =========="
echo "Controls before: $(wc -l < /tmp/controls_before.txt | awk '{print $1-2}')"
echo "Controls after:  $(wc -l < /tmp/controls_after.txt | awk '{print $1-2}')"

echo ""
echo "Controls that disappeared:"
comm -23 <(grep "^$PREFIX" /tmp/controls_before.txt | sort) <(grep "^$PREFIX" /tmp/controls_after.txt | sort)

echo ""
echo "Controls that appeared:"
comm -13 <(grep "^$PREFIX" /tmp/controls_before.txt | sort) <(grep "^$PREFIX" /tmp/controls_after.txt | sort)

echo ""
echo "========== KERNEL LOG =========="
echo "Recent TAS6754 messages:"
dmesg | grep -i tas6754 | tail -20

echo ""
echo "========== DRIVER STATE =========="
echo "Checking sysfs..."
TAS_DEV=$(find /sys/bus/i2c/devices -name "name" -exec grep -l "tas6754" {} \; 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -n "$TAS_DEV" ]; then
    echo "Found: $TAS_DEV"
    cat "$TAS_DEV/name" 2>/dev/null
else
    echo "No tas6754 I2C device found in sysfs"
fi

echo ""
echo "Checking /proc/asound:"
cat /proc/asound/card0/pcm0p/info 2>/dev/null | head -10

echo ""
echo "=================================================="
echo "Diagnostic complete"
echo "=================================================="
