#!/bin/bash
# TAS6754 Power Management Test
# Tests suspend/resume behavior and power state transitions

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
echo -e "${BLUE}║  TAS6754 Power Management Test        ║${NC}"
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
    amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}'
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

# Check if we have suspend capability
if ! which rtcwake >/dev/null 2>&1; then
    echo -e "${YELLOW}WARNING: rtcwake not available, suspend tests will be skipped${NC}"
    echo "  Install util-linux package for suspend testing"
    echo ""
    SUSPEND_AVAILABLE=0
else
    SUSPEND_AVAILABLE=1
fi

# Check if we have root privileges for suspend
if [ "$EUID" -ne 0 ] && [ $SUSPEND_AVAILABLE -eq 1 ]; then
    echo -e "${YELLOW}WARNING: Not running as root, suspend tests will be skipped${NC}"
    echo "  Run with sudo to enable suspend/resume testing"
    echo ""
    SUSPEND_AVAILABLE=0
fi

# ============================================================================
# TEST 1: Control State Persistence
# ============================================================================
print_header "TEST 1: Control State Persistence"

echo "Setting up non-default control state..."

# Store original values
DSP_MODE_ORIG=$(get_control_enum_index "DSP Signal Path Mode")
LDG_AUTO_ORIG=$(get_control "DC LDG Auto Diagnostics Switch")

echo "  Original state:"
echo "    DSP Mode: $DSP_MODE_ORIG"
echo "    LDG Auto Diagnostics: $LDG_AUTO_ORIG"
echo ""

# Set non-default values
echo "  Setting test state..."
set_control "DSP Signal Path Mode" "FFLP"  # Mode 2 (FFLP)
set_control "DC LDG Auto Diagnostics Switch" 1

# Store volume if available
if amixer -c $CARD cget name="$PREFIX CH1 Digital Playback Volume" >/dev/null 2>&1; then
    VOL_ORIG=$(get_control "CH1 Digital Playback Volume")
    INFO=$(amixer -c $CARD cget name="$PREFIX CH1 Digital Playback Volume" 2>/dev/null)
    MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')
    TEST_VOL=$((MAX / 2))
    set_control "CH1 Digital Playback Volume" $TEST_VOL
    echo "    Volume set to: $TEST_VOL"
fi

# Verify test state
DSP_MODE_TEST=$(get_control_enum_index "DSP Signal Path Mode")
LDG_AUTO_TEST=$(get_control "DC LDG Auto Diagnostics Switch")

echo "  Test state:"
echo "    DSP Mode: $DSP_MODE_TEST (expected 2=FFLP)"
echo "    LDG Auto Diagnostics: $LDG_AUTO_TEST (expected on)"

if [ "$DSP_MODE_TEST" = "2" ] && [ "$LDG_AUTO_TEST" = "on" ]; then
    print_pass "Test state configured successfully (DSP=FFLP, LDG_AUTO=on)"
else
    print_fail "Failed to set test state (DSP=$DSP_MODE_TEST, LDG_AUTO=$LDG_AUTO_TEST)"
fi

# ============================================================================
# TEST 2: Suspend/Resume Cycle
# ============================================================================
print_header "TEST 2: Suspend/Resume Cycle"

if [ $SUSPEND_AVAILABLE -eq 0 ]; then
    print_warn "Suspend not available, skipping suspend/resume tests"
else
    echo "Preparing for suspend/resume cycle..."
    echo "  NOTE: System will suspend for 5 seconds"
    echo ""

    dmesg -C

    # Perform suspend/resume
    echo "  Suspending system..."
    rtcwake -m mem -s 5

    RESUME_STATUS=$?
    echo ""
    echo "  System resumed (exit status: $RESUME_STATUS)"

    # Give devices time to reinitialize
    sleep 2

    # Check if controls are still accessible
    echo ""
    echo "  Verifying control accessibility..."

    ACCESSIBLE=1

    if ! DSP_MODE_AFTER=$(get_control_enum_index "DSP Signal Path Mode"); then
        echo -e "    ${RED}✗ Cannot read DSP mode after resume${NC}"
        ACCESSIBLE=0
    else
        echo "    ✓ DSP mode accessible (value: $DSP_MODE_AFTER)"
    fi

    if ! LDG_AUTO_AFTER=$(get_control "DC LDG Auto Diagnostics Switch"); then
        echo -e "    ${RED}✗ Cannot read LDG auto diagnostics after resume${NC}"
        ACCESSIBLE=0
    else
        echo "    ✓ LDG auto diagnostics accessible (value: $LDG_AUTO_AFTER)"
    fi

    if [ $ACCESSIBLE -eq 1 ]; then
        print_pass "Controls accessible after suspend/resume"
    else
        print_fail "Some controls inaccessible after suspend/resume"
    fi

    # Check state persistence
    echo ""
    echo "  Checking state persistence..."

    PERSISTENT=1

    if [ "$DSP_MODE_AFTER" != "$DSP_MODE_TEST" ]; then
        echo -e "    ${YELLOW}⚠ DSP mode changed: $DSP_MODE_TEST → $DSP_MODE_AFTER${NC}"
        if [ "$DSP_MODE_AFTER" = "$DSP_MODE_ORIG" ]; then
            echo "      (Restored to default - this may be expected)"
        fi
        PERSISTENT=0
    else
        echo "    ✓ DSP mode persisted ($DSP_MODE_AFTER)"
    fi

    if [ "$LDG_AUTO_AFTER" != "$LDG_AUTO_TEST" ]; then
        echo -e "    ${YELLOW}⚠ LDG auto diagnostics changed: $LDG_AUTO_TEST → $LDG_AUTO_AFTER${NC}"
        PERSISTENT=0
    else
        echo "    ✓ LDG auto diagnostics persisted ($LDG_AUTO_AFTER)"
    fi

    if [ $PERSISTENT -eq 1 ]; then
        print_pass "Control state persisted across suspend/resume"
    else
        print_warn "Some control state was reset during suspend/resume"
    fi

    # Check kernel log for PM errors
    echo ""
    echo "  Checking kernel log..."
    PM_ERRORS=$(dmesg | grep -iE "tas6754.*suspend|tas6754.*resume|tas6754.*pm" | grep -iE "error|fail" | wc -l)

    if [ $PM_ERRORS -gt 0 ]; then
        echo -e "    ${YELLOW}⚠ PM errors found: $PM_ERRORS${NC}"
        dmesg | grep -iE "tas6754.*suspend|tas6754.*resume" | tail -10
        print_warn "PM errors detected in kernel log"
    else
        echo "    ✓ No PM errors in kernel log"
        print_pass "Suspend/resume completed without errors"
    fi
fi

# ============================================================================
# TEST 3: Functionality After Resume
# ============================================================================
print_header "TEST 3: Functionality After Resume"

if [ $SUSPEND_AVAILABLE -eq 0 ]; then
    print_warn "Suspend not available, testing basic functionality instead"
    TEST_LABEL="basic functionality"
else
    TEST_LABEL="post-resume functionality"
fi

echo "Testing $TEST_LABEL..."

FUNCTIONAL=1

# Test 1: LDG trigger
echo "  Testing LDG trigger..."
trigger_control "DC LDG Trigger"
sleep 1
LDG_RESULT=$(get_control "DC LDG Result")
if [ -n "$LDG_RESULT" ]; then
    echo "    ✓ LDG operational (Result: $LDG_RESULT)"
else
    echo -e "    ${RED}✗ LDG not operational${NC}"
    FUNCTIONAL=0
fi

# Test 2: DSP mode switching
echo "  Testing DSP mode switching..."
MODES=("Normal" "LLP" "FFLP")
for idx in 0 1 2; do
    mode="${MODES[$idx]}"
    set_control "DSP Signal Path Mode" "$mode"
    VERIFY=$(get_control_enum_index "DSP Signal Path Mode")
    if [ "$VERIFY" = "$idx" ]; then
        echo "    ✓ Mode $mode switch successful"
    else
        echo -e "    ${RED}✗ Mode $mode switch failed (got index $VERIFY)${NC}"
        FUNCTIONAL=0
    fi
done

# Test 3: Volume control
if amixer -c $CARD cget name="$PREFIX CH1 Digital Playback Volume" >/dev/null 2>&1; then
    echo "  Testing volume control..."
    INFO=$(amixer -c $CARD cget name="$PREFIX CH1 Digital Playback Volume" 2>/dev/null)
    MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
    MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

    set_control "CH1 Digital Playback Volume" $MIN
    VERIFY=$(get_control "CH1 Digital Playback Volume")
    if [ $VERIFY -eq $MIN ]; then
        echo "    ✓ Volume min works"
    else
        echo -e "    ${RED}✗ Volume min failed${NC}"
        FUNCTIONAL=0
    fi

    set_control "CH1 Digital Playback Volume" $MAX
    VERIFY=$(get_control "CH1 Digital Playback Volume")
    if [ $VERIFY -eq $MAX ]; then
        echo "    ✓ Volume max works"
    else
        echo -e "    ${RED}✗ Volume max failed${NC}"
        FUNCTIONAL=0
    fi
fi

if [ $FUNCTIONAL -eq 1 ]; then
    print_pass "All functions operational after test"
else
    print_fail "Some functions not operational after test"
fi

# ============================================================================
# TEST 4: Multiple Suspend/Resume Cycles
# ============================================================================
print_header "TEST 4: Multiple Suspend/Resume Cycles"

if [ $SUSPEND_AVAILABLE -eq 0 ]; then
    print_warn "Suspend not available, skipping multiple cycle test"
else
    echo "Performing 3 suspend/resume cycles..."
    echo "  (3 seconds per cycle)"
    echo ""

    CYCLE_ERRORS=0

    CYCLE_MODES=("Normal" "LLP" "FFLP")
    for cycle in 1 2 3; do
        echo "  Cycle $cycle/3..."

        # Set a unique test value for this cycle
        TEST_MODE_IDX=$((cycle - 1))  # 0, 1, 2
        TEST_MODE="${CYCLE_MODES[$TEST_MODE_IDX]}"
        set_control "DSP Signal Path Mode" "$TEST_MODE"

        # Suspend/resume
        rtcwake -m mem -s 3 >/dev/null 2>&1
        sleep 1

        # Verify accessibility
        MODE_AFTER=$(get_control_enum_index "DSP Signal Path Mode")
        if [ -z "$MODE_AFTER" ]; then
            echo "    ✗ Controls inaccessible after cycle $cycle"
            CYCLE_ERRORS=$((CYCLE_ERRORS + 1))
        else
            echo "    ✓ Cycle $cycle completed (mode: $MODE_AFTER)"
        fi
    done

    echo ""
    echo "  Cycle errors: $CYCLE_ERRORS/3"

    if [ $CYCLE_ERRORS -eq 0 ]; then
        print_pass "All suspend/resume cycles successful"
    else
        print_fail "Some suspend/resume cycles failed ($CYCLE_ERRORS/3)"
    fi

    # Final verification
    echo ""
    echo "  Final functionality check..."
    trigger_control "DC LDG Trigger"
    sleep 1
    LDG_RESULT=$(get_control "DC LDG Result")
    if [ -n "$LDG_RESULT" ]; then
        echo "    ✓ LDG still operational (Result: $LDG_RESULT)"
    else
        echo -e "    ${RED}✗ LDG not operational after multiple cycles${NC}"
        print_fail "Device not fully functional after multiple cycles"
    fi
fi

# ============================================================================
# TEST 5: Power State Control Verification
# ============================================================================
print_header "TEST 5: Power State Control Verification"

echo "Checking power management sysfs attributes..."

# Find the TAS6754 device in sysfs
DEVICE_PATH=""
for dev in /sys/bus/i2c/devices/*; do
    if [ -f "$dev/name" ]; then
        NAME=$(cat "$dev/name" 2>/dev/null)
        if echo "$NAME" | grep -q "tas6754"; then
            DEVICE_PATH="$dev"
            break
        fi
    fi
done

if [ -z "$DEVICE_PATH" ]; then
    echo "  Searching for TAS6754 I2C device..."
    # Try alternate method: look for address 0x70
    for dev in /sys/bus/i2c/devices/*0070; do
        if [ -d "$dev" ]; then
            DEVICE_PATH="$dev"
            break
        fi
    done
fi

if [ -n "$DEVICE_PATH" ]; then
    echo "  Found device: $DEVICE_PATH"

    # Check runtime PM attributes
    if [ -d "$DEVICE_PATH/power" ]; then
        echo ""
        echo "  Power management attributes:"

        if [ -f "$DEVICE_PATH/power/runtime_status" ]; then
            RT_STATUS=$(cat "$DEVICE_PATH/power/runtime_status" 2>/dev/null)
            echo "    Runtime status: $RT_STATUS"
        fi

        if [ -f "$DEVICE_PATH/power/runtime_suspended_time" ]; then
            RT_SUSP=$(cat "$DEVICE_PATH/power/runtime_suspended_time" 2>/dev/null)
            echo "    Runtime suspended time: $RT_SUSP ms"
        fi

        if [ -f "$DEVICE_PATH/power/runtime_active_time" ]; then
            RT_ACT=$(cat "$DEVICE_PATH/power/runtime_active_time" 2>/dev/null)
            echo "    Runtime active time: $RT_ACT ms"
        fi

        print_pass "Power management attributes accessible"
    else
        print_warn "Power management attributes not found"
    fi
else
    print_warn "Could not locate TAS6754 device in sysfs"
fi

# ============================================================================
# TEST 6: Restore Original State
# ============================================================================
print_header "TEST 6: Restore Original State"

echo "Restoring original control state..."

set_control "DSP Signal Path Mode" "$DSP_MODE_ORIG"
set_control "DC LDG Auto Diagnostics Switch" "$LDG_AUTO_ORIG"

if [ -n "$VOL_ORIG" ]; then
    set_control "CH1 Digital Playback Volume" "$VOL_ORIG"
fi

# Verify restoration
DSP_RESTORED=$(get_control_enum_index "DSP Signal Path Mode")
LDG_AUTO_RESTORED=$(get_control "DC LDG Auto Diagnostics Switch")

echo "  Restored state:"
echo "    DSP Mode: $DSP_RESTORED (expected $DSP_MODE_ORIG)"
echo "    LDG Auto Diagnostics: $LDG_AUTO_RESTORED (expected $LDG_AUTO_ORIG)"

if [ "$DSP_RESTORED" = "$DSP_MODE_ORIG" ] && [ "$LDG_AUTO_RESTORED" = "$LDG_AUTO_ORIG" ]; then
    print_pass "Original state restored successfully"
else
    print_warn "Some values not restored correctly"
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

if [ $SUSPEND_AVAILABLE -eq 0 ]; then
    echo -e "${YELLOW}NOTE: Suspend/resume tests were skipped${NC}"
    echo "  Run with sudo and ensure rtcwake is available for full testing"
    echo ""
fi

if [ $FAIL -eq 0 ] && [ $PASS -ge 3 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  POWER MANAGEMENT TEST PASSED! ✓      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Device demonstrated proper power management behavior"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  POWER MANAGEMENT TEST FAILED! ✗      ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Device showed issues with power management"
    exit 1
fi
