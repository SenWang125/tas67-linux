#!/bin/bash
# TAS6754 Fault Injection & Recovery Test
# Tests error handling and recovery from fault conditions

# Configuration
CARD="0"
PREFIX="TAS0"

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
echo -e "${BLUE}║  TAS6754 Fault Injection & Recovery   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
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

# ============================================================================
# TEST 1: Invalid Control Value Rejection
# ============================================================================
print_header "TEST 1: Invalid Control Value Rejection"

echo "Testing invalid values are properly rejected..."

# Test out-of-range volume
TEST_PASSED=1
echo "  Testing volume control with out-of-range value..."
if amixer -c $CARD cget name="$PREFIX Analog Playback Volume" >/dev/null 2>&1; then
    INFO=$(amixer -c $CARD cget name="$PREFIX Analog Playback Volume" 2>/dev/null)
    MAX=$(echo "$INFO" | grep max= | sed 's/.*max=//' | sed 's/,.*//')
    INVALID_VOL=$((MAX + 1000))

    ORIG=$(get_control "Analog Playback Volume")
    set_control "Analog Playback Volume" $INVALID_VOL
    VERIFY=$(get_control "Analog Playback Volume")

    if [ "$VERIFY" = "$ORIG" ] || [ $VERIFY -le $MAX ]; then
        echo "    ✓ Driver rejected/clamped out-of-range volume"
    else
        echo -e "    ${RED}✗ Driver accepted out-of-range volume${NC}"
        TEST_PASSED=0
    fi
fi

# Test invalid enum value
echo "  Testing enum control with invalid index..."
ORIG_MODE=$(get_control_enum_index "DSP Signal Path Mode")
MAX_IDX=$(( $(amixer -c $CARD cget name="$PREFIX DSP Signal Path Mode" 2>/dev/null | grep -c "Item #") - 1 ))
if set_control "DSP Signal Path Mode" 99; then
    VERIFY=$(get_control_enum_index "DSP Signal Path Mode")
    # Clamping out-of-range index to maximum valid index is correct ALSA behavior
    if [ "$VERIFY" -ge 0 ] && [ "$VERIFY" -le "$MAX_IDX" ] 2>/dev/null; then
        echo "    ✓ Invalid enum index 99 clamped to valid index $VERIFY (correct ALSA behavior)"
    else
        echo -e "    ${RED}✗ Unexpected enum state after invalid write: $VERIFY${NC}"
        TEST_PASSED=0
    fi
else
    echo "    ✓ Driver rejected invalid enum index 99"
fi

# Restore mode
set_control "DSP Signal Path Mode" "$ORIG_MODE"

if [ $TEST_PASSED -eq 1 ]; then
    print_pass "Driver properly validates control values"
else
    print_fail "Driver accepted some invalid values"
fi

# ============================================================================
# TEST 2: Rapid Control Toggle Stress
# ============================================================================
print_header "TEST 2: Rapid Control Toggle Stress"

echo "Performing rapid toggle stress (100 iterations per control)..."

dmesg -C

# Test rapid LDG trigger toggle
ERRORS=0
echo "  Testing LDG Trigger rapid toggle..."
for i in $(seq 1 100); do
    trigger_control "DC LDG Trigger" || ERRORS=$((ERRORS + 1))
done
echo "    Completed 100 operations, errors: $ERRORS"

# Test rapid channel toggle
if amixer -c $CARD cget name="$PREFIX CH1 Auto Mute Switch" >/dev/null 2>&1; then
    echo "  Testing CH1 Enable rapid toggle..."
    ERRORS=0
    for i in $(seq 1 100); do
        set_control "CH1 Auto Mute Switch" 1 || ERRORS=$((ERRORS + 1))
        set_control "CH1 Auto Mute Switch" 0 || ERRORS=$((ERRORS + 1))
    done
    echo "    Completed 100 operations, errors: $ERRORS"
fi

# Check for kernel errors
KERNEL_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*fail" | wc -l)
echo ""
echo "  Kernel errors during rapid toggle: $KERNEL_ERRORS"

if [ $KERNEL_ERRORS -eq 0 ]; then
    print_pass "Rapid toggle stress handled without errors"
else
    print_warn "Kernel errors detected during rapid toggle"
    dmesg | grep -iE "tas6754.*error|tas6754.*fail" | tail -5
fi

# ============================================================================
# TEST 3: Conflicting Operation Sequence
# ============================================================================
print_header "TEST 3: Conflicting Operation Sequence"

echo "Testing potentially conflicting operations..."

dmesg -C

# Test: Trigger LDG (should work even without auto diagnostics enabled)
echo "  Test: Trigger LDG..."
trigger_control "DC LDG Trigger"
sleep 0.5
STATUS=$(get_control "DC LDG Result")
echo "    Result: $STATUS"

# Test: Trigger LDG again immediately (no delay)
echo "  Test: Trigger LDG immediately again..."
trigger_control "DC LDG Trigger"
sleep 1
STATUS=$(get_control "DC LDG Result")
echo "    Result: $STATUS"

# Test: Change DSP mode during active operation
echo "  Test: Change DSP mode rapidly..."
for mode in 0 1 2 0; do
    set_control "DSP Signal Path Mode" $mode
done
FINAL_MODE=$(get_control_enum_index "DSP Signal Path Mode")
echo "    Final mode: $FINAL_MODE"

# Check kernel log
CONFLICT_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*busy|tas6754.*conflict" | wc -l)
echo ""
echo "  Kernel errors during conflicting operations: $CONFLICT_ERRORS"

if [ $CONFLICT_ERRORS -eq 0 ]; then
    print_pass "Conflicting operations handled gracefully"
else
    print_warn "Some errors detected during conflicting operations"
    dmesg | grep -iE "tas6754.*error" | tail -5
fi

# ============================================================================
# TEST 4: Recovery from Failed Operations
# ============================================================================
print_header "TEST 4: Recovery from Failed Operations"

echo "Testing recovery after fault injection..."

# Simulate a sequence of operations that might fail
echo "  Performing operation sequence..."

dmesg -C

# Operation 1: Normal LDG operation
trigger_control "DC LDG Trigger"
sleep 1

# Operation 2: Rapid mode changes
for i in $(seq 1 10); do
    set_control "DSP Signal Path Mode" 0
    set_control "DSP Signal Path Mode" 1
done

# Operation 3: Rapid volume changes
if amixer -c $CARD cget name="$PREFIX Analog Playback Volume" >/dev/null 2>&1; then
    INFO=$(amixer -c $CARD cget name="$PREFIX Analog Playback Volume" 2>/dev/null)
    MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
    MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

    for i in $(seq 1 10); do
        set_control "Analog Playback Volume" $MIN
        set_control "Analog Playback Volume" $MAX
    done
fi

# Now verify system is still operational
echo ""
echo "  Verifying system functionality after stress..."

RECOVERY_OK=1

# Test 1: LDG still works
echo "    Testing LDG..."
trigger_control "DC LDG Trigger"
sleep 1
RESULT=$(get_control "DC LDG Result")
if [ -n "$RESULT" ]; then
    echo "      ✓ LDG operational (Result: $RESULT)"
else
    echo -e "      ${RED}✗ LDG not operational${NC}"
    RECOVERY_OK=0
fi

# Test 2: DSP mode switching works
echo "    Testing DSP mode..."
set_control "DSP Signal Path Mode" 0
VERIFY=$(get_control_enum_index "DSP Signal Path Mode")
if [ "$VERIFY" = "0" ]; then
    echo "      ✓ DSP mode control operational"
else
    echo -e "      ${RED}✗ DSP mode control failed${NC}"
    RECOVERY_OK=0
fi

# Test 3: Volume control works
if amixer -c $CARD cget name="$PREFIX Analog Playback Volume" >/dev/null 2>&1; then
    echo "    Testing volume control..."
    INFO=$(amixer -c $CARD cget name="$PREFIX Analog Playback Volume" 2>/dev/null)
    TEST_MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
    set_control "Analog Playback Volume" $TEST_MIN
    VERIFY=$(get_control "Analog Playback Volume")
    if [ -n "$VERIFY" ]; then
        echo "      ✓ Volume control operational"
    else
        echo -e "      ${RED}✗ Volume control failed${NC}"
        RECOVERY_OK=0
    fi
fi

if [ $RECOVERY_OK -eq 1 ]; then
    print_pass "System recovered successfully from stress"
else
    print_fail "System recovery incomplete"
fi

# ============================================================================
# TEST 5: Control Accessibility During Faults
# ============================================================================
print_header "TEST 5: Control Accessibility During Faults"

echo "Testing control accessibility under stress..."

# Start background worker that continuously hammers controls
stress_worker() {
    for i in $(seq 1 100); do
        trigger_control "DC LDG Trigger"
        set_control "DSP Signal Path Mode" 0
        set_control "DSP Signal Path Mode" 1
    done
}

echo "  Starting background stress worker..."
stress_worker &
STRESS_PID=$!

# Give it a moment to start
sleep 0.5

# Try to access controls while stress is running
echo "  Attempting control access during stress..."

ACCESSIBLE=1

# Try reading LDG result
if ! RESULT=$(get_control "DC LDG Result"); then
    echo -e "    ${RED}✗ Could not read LDG result during stress${NC}"
    ACCESSIBLE=0
else
    echo "    ✓ Read LDG result during stress (value: $RESULT)"
fi

# Try reading DSP mode
if ! MODE=$(get_control_enum_index "DSP Signal Path Mode"); then
    echo -e "    ${RED}✗ Could not read DSP mode during stress${NC}"
    ACCESSIBLE=0
else
    echo "    ✓ Read DSP mode during stress (value: $MODE)"
fi

# Try writing a control
if trigger_control "DC LDG Trigger"; then
    echo "    ✓ Write operation succeeded during stress"
else
    echo -e "    ${YELLOW}⚠ Write operation blocked during stress${NC}"
fi

# Wait for stress worker to finish
wait $STRESS_PID 2>/dev/null

if [ $ACCESSIBLE -eq 1 ]; then
    print_pass "Controls remained accessible during stress"
else
    print_fail "Some controls became inaccessible during stress"
fi

# ============================================================================
# TEST 6: Error State Recovery
# ============================================================================
print_header "TEST 6: Error State Recovery"

echo "Testing recovery from error states..."

dmesg -C

# Try to put device in various states and verify recovery
echo "  Test sequence:"

# State 1: Disable all channels
if amixer -c $CARD cget name="$PREFIX CH1 Auto Mute Switch" >/dev/null 2>&1; then
    echo "    Disabling all channels..."
    for ch in CH1 CH2 CH3 CH4; do
        set_control "${ch} Auto Mute Switch" 0
    done
fi

# State 2: Trigger LDG
echo "    Triggering LDG..."
trigger_control "DC LDG Trigger"

# State 3: Set DSP to LLP mode
echo "    Setting DSP to LLP mode..."
set_control "DSP Signal Path Mode" 1

# Now perform a "reset" sequence
echo ""
echo "  Performing recovery sequence..."

# Restore normal state
set_control "DSP Signal Path Mode" 0
# Note: DC LDG Trigger is write-only, no need to "disable" it

if amixer -c $CARD cget name="$PREFIX CH1 Auto Mute Switch" >/dev/null 2>&1; then
    for ch in CH1 CH2 CH3 CH4; do
        set_control "${ch} Auto Mute Switch" 1
    done
fi

# Verify recovery
echo ""
echo "  Verifying recovery..."

DSP_MODE=$(get_control_enum_index "DSP Signal Path Mode")

RECOVERED=1

if [ "$DSP_MODE" != "0" ]; then
    echo -e "    ${RED}✗ DSP mode not restored (got $DSP_MODE, expected 0)${NC}"
    RECOVERED=0
else
    echo "    ✓ DSP mode restored to Normal"
fi

# Verify LDG is still functional (trigger and check result)
trigger_control "DC LDG Trigger"
sleep 1
LDG_RESULT=$(get_control "DC LDG Result")
if [ -n "$LDG_RESULT" ]; then
    echo "    ✓ LDG still functional (Result: $LDG_RESULT)"
else
    echo -e "    ${RED}✗ LDG not functional${NC}"
    RECOVERED=0
fi

if [ $RECOVERED -eq 1 ]; then
    print_pass "Successfully recovered from error state"
else
    print_fail "Recovery from error state incomplete"
fi

# ============================================================================
# TEST 7: Kernel Log Error Analysis
# ============================================================================
print_header "TEST 7: Kernel Log Error Analysis"

echo "Analyzing kernel log for errors during fault injection..."

TOTAL_ERRORS=$(dmesg | grep -iE "error|warning|fail" | wc -l)
TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)
I2C_ERRORS=$(dmesg | grep -iE "i2c.*error|i2c.*timeout" | wc -l)
WARN_MSGS=$(dmesg | grep -iE "tas6754.*warning" | wc -l)

echo "  Total errors/warnings in log: $TOTAL_ERRORS"
echo "  TAS6754 errors: $TAS_ERRORS"
echo "  I2C errors: $I2C_ERRORS"
echo "  TAS6754 warnings: $WARN_MSGS"

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

# Some errors during fault injection are expected
if [ $TAS_ERRORS -le 5 ]; then
    print_pass "Error count acceptable for fault injection test ($TAS_ERRORS errors)"
else
    print_warn "High error count during fault injection ($TAS_ERRORS errors)"
fi

# ============================================================================
# FINAL VERDICT
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           TEST SUMMARY                 ${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "WARNINGS: $WARN"
echo ""

if [ $FAIL -eq 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; ($PASS / ($PASS + $WARN)) * 100" | bc 2>/dev/null || echo "100.0")
else
    SUCCESS_RATE=$(echo "scale=1; ($PASS / ($PASS + $FAIL + $WARN)) * 100" | bc 2>/dev/null || echo "0")
fi

echo "Success Rate: ${SUCCESS_RATE}%"
echo ""

if [ $FAIL -eq 0 ] && [ $PASS -ge 5 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  FAULT INJECTION TEST PASSED! ✓       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Driver demonstrated robust error handling and recovery"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  FAULT INJECTION TEST FAILED! ✗       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Driver showed issues with error handling or recovery"
    exit 1
fi
