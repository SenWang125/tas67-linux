#!/bin/bash
# TAS6754 Integration Stress Test
# Tests multiple operations concurrently: playback + LDG + DSP + volume changes

# Configuration
CARD="0"
PREFIX="TAS0"
DURATION=60  # Test duration in seconds

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
WARN=0

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  TAS6754 Integration Stress Test      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Duration: ${DURATION} seconds"
echo ""

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASS=$((PASS + 1))
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

print_warn() {
    echo -e "${YELLOW}⚠ WARNING${NC}: $1"
    WARN=$((WARN + 1))
}

# Save ALSA mixer state; restore automatically on exit (normal or error)
ALSA_STATE=$(mktemp /tmp/alsa-test-XXXXXX.state)
cleanup() {
    alsactl restore -f "$ALSA_STATE" 2>/dev/null
    rm -f "$ALSA_STATE"
}
trap cleanup EXIT
alsactl store -f "$ALSA_STATE" 2>/dev/null


get_control() {
    local val=$(amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}' | awk -F',' '{print $1}')
    # Convert boolean on/off to 1/0
    case "$val" in
        on) echo "1" ;;
        off) echo "0" ;;
        *) echo "$val" ;;
    esac
}

set_control() {
    amixer -c $CARD cset name="$PREFIX $1" "$2" >/dev/null 2>&1
    return $?
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
    return $?
}

get_control_enum_index() {
    amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}'
}

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    # Kill all background jobs
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
}

trap cleanup EXIT

# ============================================================================
# TEST 1: Concurrent Operations Test
# ============================================================================
print_header "TEST 1: Concurrent Operations Test"

echo "Starting audio playback..."
# Start continuous audio playback
(speaker-test -t wav -c 2 -l 0 >/dev/null 2>&1) &
PLAYBACK_PID=$!

sleep 1

if ! kill -0 $PLAYBACK_PID 2>/dev/null; then
    print_warn "Audio playback failed to start"
else
    echo "  ✓ Playback started (PID: $PLAYBACK_PID)"
fi

# Clear dmesg
dmesg -C

# Worker 1: Periodic LDG triggers
ldg_worker() {
    local count=0
    while true; do
        trigger_control "DC LDG Trigger"
        sleep 5
        count=$((count + 1))
    done
}

# Worker 2: DSP mode cycling
dsp_worker() {
    local modes=("Normal" "LLP" "FFLP")
    local count=0
    while true; do
        for mode in "${modes[@]}"; do
            set_control "DSP Signal Path Mode" "$mode"
            sleep 3
            count=$((count + 1))
        done
    done
}

# Worker 3: Volume ramping
volume_worker() {
    local count=0
    if amixer -c $CARD cget name="$PREFIX Analog Playback Volume" >/dev/null 2>&1; then
        local info=$(amixer -c $CARD cget name="$PREFIX Analog Playback Volume" 2>/dev/null)
        local min=$(echo "$info" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
        local max=$(echo "$info" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

        while true; do
            # Ramp up
            for vol in $(seq $min 10 $max); do
                set_control "Analog Playback Volume" $vol
                sleep 0.1
            done
            # Ramp down
            for vol in $(seq $max -10 $min); do
                set_control "Analog Playback Volume" $vol
                sleep 0.1
            done
            count=$((count + 1))
        done
    fi
}

# Worker 4: Channel toggling (auto mute)
channel_worker() {
    local channels=("CH1" "CH2" "CH3" "CH4")
    local count=0
    while true; do
        for ch in "${channels[@]}"; do
            if amixer -c $CARD cget name="$PREFIX ${ch} Auto Mute Switch" >/dev/null 2>&1; then
                set_control "${ch} Auto Mute Switch" 1
                sleep 0.5
                set_control "${ch} Auto Mute Switch" 0
                sleep 0.5
                count=$((count + 1))
            fi
        done
    done
}

# Start all workers
echo ""
echo "Starting concurrent workers..."
ldg_worker &
LDG_PID=$!
echo "  ✓ LDG worker started (PID: $LDG_PID)"

dsp_worker &
DSP_PID=$!
echo "  ✓ DSP worker started (PID: $DSP_PID)"

volume_worker &
VOL_PID=$!
echo "  ✓ Volume worker started (PID: $VOL_PID)"

channel_worker &
CH_PID=$!
echo "  ✓ Channel worker started (PID: $CH_PID)"

echo ""
echo -e "${YELLOW}Running stress test for $DURATION seconds...${NC}"
echo "Press Ctrl+C to stop early"

# Monitor for duration
for i in $(seq 1 $DURATION); do
    echo -ne "\rElapsed: ${i}/${DURATION}s "
    sleep 1
done
echo ""

# Stop all workers
echo ""
echo "Stopping workers..."
kill $LDG_PID $DSP_PID $VOL_PID $CH_PID $PLAYBACK_PID 2>/dev/null
wait 2>/dev/null

echo "  ✓ All workers stopped"

# ============================================================================
# TEST 2: Results Analysis
# ============================================================================
print_header "TEST 2: Results Analysis"

echo "Analyzing kernel log for errors..."
TOTAL_ERRORS=$(dmesg | grep -iE "error|warning|fail" | wc -l)
TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)
I2C_ERRORS=$(dmesg | grep -iE "i2c.*error|i2c.*timeout" | wc -l)
LDG_ERRORS=$(dmesg | grep -iE "ldg.*error|ldg.*fail" | wc -l)

echo "  Total errors/warnings: $TOTAL_ERRORS"
echo "  TAS6754 errors: $TAS_ERRORS"
echo "  I2C errors: $I2C_ERRORS"
echo "  LDG errors: $LDG_ERRORS"

if [ $TAS_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}TAS6754 errors found:${NC}"
    dmesg | grep -iE "tas6754.*error" | tail -10
fi

if [ $I2C_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}I2C errors found:${NC}"
    dmesg | grep -iE "i2c.*error|i2c.*timeout" | tail -10
fi

# ============================================================================
# TEST 3: State Verification
# ============================================================================
print_header "TEST 3: State Verification"

echo "Verifying final system state..."

# Check if controls are still accessible
ACCESSIBLE=1

echo "  Checking DSP mode..."
DSP_MODE=$(get_control_enum_index "DSP Signal Path Mode")
if [ -n "$DSP_MODE" ]; then
    echo "    ✓ DSP mode accessible (current: $DSP_MODE)"
else
    echo -e "    ${RED}✗ DSP mode not accessible${NC}"
    ACCESSIBLE=0
fi

echo "  Checking channel auto mute..."
for ch in CH1 CH2 CH3 CH4; do
    if amixer -c $CARD cget name="$PREFIX ${ch} Auto Mute Switch" >/dev/null 2>&1; then
        STATE=$(get_control "${ch} Auto Mute Switch")
        echo "    ✓ $ch accessible (auto mute: $STATE)"
    fi
done

echo "  Checking LDG controls..."
if amixer -c $CARD cget name="$PREFIX DC LDG Trigger" >/dev/null 2>&1; then
    LDG_RESULT=$(get_control "DC LDG Result")
    echo "    ✓ LDG controls accessible (Last result: $LDG_RESULT)"
else
    echo -e "    ${RED}✗ LDG controls not accessible${NC}"
    echo -e "    ${YELLOW}Debug: Checking amixer error...${NC}"
    amixer -c $CARD cget name="$PREFIX DC LDG Trigger" 2>&1 | head -3 | sed 's/^/      /'
    ACCESSIBLE=0
fi

if [ $ACCESSIBLE -eq 1 ]; then
    print_pass "All controls accessible after stress test"
else
    print_fail "Some controls became inaccessible"
fi

# ============================================================================
# TEST 4: Recovery Test
# ============================================================================
print_header "TEST 4: Recovery Test"

echo "Testing system recovery..."

# Try to perform normal operations
RECOVERY_OK=1

echo "  Testing LDG trigger..."
if trigger_control "DC LDG Trigger"; then
    echo "    ✓ DC LDG Trigger writable"
    sleep 1
    RESULT=$(get_control "DC LDG Result")
    if [ -n "$RESULT" ]; then
        echo "    ✓ LDG operational (Result: $RESULT)"
    else
        echo -e "    ${RED}✗ LDG result not readable${NC}"
        RECOVERY_OK=0
    fi
else
    echo -e "    ${RED}✗ DC LDG Trigger not writable${NC}"
    RECOVERY_OK=0
fi

echo "  Testing DSP mode change..."
set_control "DSP Signal Path Mode" "Normal"
VERIFY=$(get_control_enum_index "DSP Signal Path Mode")
if [ "$VERIFY" = "0" ]; then
    echo "    ✓ DSP mode change operational"
else
    echo -e "    ${RED}✗ DSP mode change failed${NC}"
    RECOVERY_OK=0
fi

echo "  Testing channel control..."
set_control "CH1 Auto Mute Switch" 0
VERIFY=$(get_control "CH1 Auto Mute Switch")
set_control "CH1 Auto Mute Switch" 1
if [ -n "$VERIFY" ]; then
    echo "    ✓ Channel control operational"
else
    echo -e "    ${RED}✗ Channel control failed${NC}"
    RECOVERY_OK=0
fi

if [ $RECOVERY_OK -eq 1 ]; then
    print_pass "System recovered successfully"
else
    print_fail "System recovery incomplete"
    echo ""
    echo -e "${YELLOW}Checking for clues in kernel log...${NC}"
    RECENT_ERRORS=$(dmesg | grep -iE "tas6754|i2c.*error" | tail -10)
    if [ -n "$RECENT_ERRORS" ]; then
        echo "$RECENT_ERRORS" | sed 's/^/  /'
    else
        echo "  No obvious errors in kernel log"
        echo "  This may indicate regmap cache corruption or driver state issue"
    fi
fi

# ============================================================================
# FINAL VERDICT
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           FINAL VERDICT                ${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

echo "Test duration: $DURATION seconds"
echo "TAS6754 errors: $TAS_ERRORS"
echo "I2C errors: $I2C_ERRORS"
echo ""
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "WARNINGS: $WARN"
echo ""

if [ $FAIL -eq 0 ] && [ $TAS_ERRORS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   INTEGRATION STRESS TEST PASSED! ✓   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "System remained stable during $DURATION seconds of concurrent operations"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   INTEGRATION STRESS TEST FAILED! ✗   ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    if [ $TAS_ERRORS -gt 0 ]; then
        echo "  - TAS6754 errors detected during stress test"
    fi
    if [ $I2C_ERRORS -gt 0 ]; then
        echo "  - I2C errors detected during stress test"
    fi
    if [ $FAIL -gt 0 ]; then
        echo "  - System recovery incomplete"
    fi
    exit 1
fi
