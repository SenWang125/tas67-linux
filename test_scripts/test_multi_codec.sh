#!/bin/bash
# TAS6754 Multi-Codec Concurrent Test (AM62D2-EVM)
# Tests concurrent operations across both TAS6754 codec instances

# Configuration
CARD="0"
# AM62D2-EVM has 2 TAS6754 codecs with prefixes TAS0, TAS1
CODECS=("TAS0" "TAS1")

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
echo -e "${BLUE}║  TAS6754 Multi-Codec Concurrent Test  ║${NC}"
echo -e "${BLUE}║         (AM62D2-EVM Specific)          ║${NC}"
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
    local prefix=$1
    local ctrl=$2
    amixer -c $CARD cget name="$prefix $ctrl" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}'
}

set_control() {
    local prefix=$1
    local ctrl=$2
    local val=$3
    amixer -c $CARD cset name="$prefix $ctrl" "$val" >/dev/null 2>&1
    return $?
}

check_control_exists() {
    local prefix=$1
    local ctrl=$2
    amixer -c $CARD cget name="$prefix $ctrl" >/dev/null 2>&1
    return $?
}

trigger_codec_control() {
    local ctrl_name="$1 $2"
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

# ============================================================================
# TEST 1: Codec Detection
# ============================================================================
print_header "TEST 1: Codec Detection"

echo "Detecting available codecs..."
FOUND_CODECS=()
for codec in "${CODECS[@]}"; do
    # Check for a common control (LDG trigger)
    if check_control_exists "$codec" "DC LDG Trigger"; then
        echo "  ✓ Found codec: $codec"
        FOUND_CODECS+=("$codec")
    else
        echo "  - Not found: $codec"
    fi
done

echo ""
echo "Found ${#FOUND_CODECS[@]} codec(s) out of ${#CODECS[@]} expected"

if [ ${#FOUND_CODECS[@]} -eq 0 ]; then
    print_fail "No codecs detected"
    exit 1
elif [ ${#FOUND_CODECS[@]} -lt ${#CODECS[@]} ]; then
    print_warn "Only ${#FOUND_CODECS[@]} codecs detected (expected ${#CODECS[@]})"
else
    print_pass "All ${#CODECS[@]} codecs detected"
fi

# ============================================================================
# TEST 2: Concurrent DC LDG on All Codecs
# ============================================================================
print_header "TEST 2: Concurrent DC LDG on All Codecs"

echo "Triggering DC LDG on all codecs simultaneously..."

# Clear dmesg
dmesg -C

# Trigger LDG on all codecs concurrently
for codec in "${FOUND_CODECS[@]}"; do
    (
        trigger_codec_control "$codec" "DC LDG Trigger"
    ) &
done

# Wait for all background jobs
wait

sleep 2

echo ""
echo "Checking LDG results:"
ALL_SUCCESS=1
for codec in "${FOUND_CODECS[@]}"; do
    RESULT=$(get_control "$codec" "DC LDG Result")
    echo "  $codec: Result=$RESULT (0x$(printf '%02x' $RESULT 2>/dev/null || echo '??'))"

    # Check if we got valid reading
    if [ -z "$RESULT" ]; then
        ALL_SUCCESS=0
    fi
done

# Check kernel log
LDG_ERRORS=$(dmesg | grep -iE "tas6754.*ldg.*error|tas6754.*ldg.*fail" | wc -l)
echo ""
echo "LDG errors in kernel log: $LDG_ERRORS"

if [ $ALL_SUCCESS -eq 1 ] && [ $LDG_ERRORS -eq 0 ]; then
    print_pass "Concurrent DC LDG successful on all codecs"
else
    print_fail "Concurrent DC LDG failed"
fi

# ============================================================================
# TEST 3: Concurrent Channel Control
# ============================================================================
print_header "TEST 3: Concurrent Channel Control"

echo "Testing concurrent channel enable/disable across all codecs..."

# Disable all channels on all codecs simultaneously
for codec in "${FOUND_CODECS[@]}"; do
    for ch in CH1 CH2 CH3 CH4; do
        (set_control "$codec" "$ch Auto Mute Switch" 0) &
    done
done
wait
sleep 0.1

# Verify all disabled
echo ""
echo "Verifying all channels disabled:"
ALL_DISABLED=1
for codec in "${FOUND_CODECS[@]}"; do
    CH1=$(get_control "$codec" "CH1 Auto Mute Switch")
    CH2=$(get_control "$codec" "CH2 Auto Mute Switch")
    CH3=$(get_control "$codec" "CH3 Auto Mute Switch")
    CH4=$(get_control "$codec" "CH4 Auto Mute Switch")
    echo "  $codec: CH1=$CH1 CH2=$CH2 CH3=$CH3 CH4=$CH4"
    if [ "$CH1" != "off" ] || [ "$CH2" != "off" ] || [ "$CH3" != "off" ] || [ "$CH4" != "off" ]; then
        ALL_DISABLED=0
    fi
done

# Re-enable all channels
for codec in "${FOUND_CODECS[@]}"; do
    for ch in CH1 CH2 CH3 CH4; do
        (set_control "$codec" "$ch Auto Mute Switch" 1) &
    done
done
wait
sleep 0.1

# Verify all enabled
echo ""
echo "Verifying all channels enabled:"
ALL_ENABLED=1
for codec in "${FOUND_CODECS[@]}"; do
    CH1=$(get_control "$codec" "CH1 Auto Mute Switch")
    CH2=$(get_control "$codec" "CH2 Auto Mute Switch")
    CH3=$(get_control "$codec" "CH3 Auto Mute Switch")
    CH4=$(get_control "$codec" "CH4 Auto Mute Switch")
    echo "  $codec: CH1=$CH1 CH2=$CH2 CH3=$CH3 CH4=$CH4"
    if [ "$CH1" != "on" ] || [ "$CH2" != "on" ] || [ "$CH3" != "on" ] || [ "$CH4" != "on" ]; then
        ALL_ENABLED=0
    fi
done

if [ $ALL_DISABLED -eq 1 ] && [ $ALL_ENABLED -eq 1 ]; then
    print_pass "Concurrent channel control successful"
else
    print_fail "Concurrent channel control failed"
fi

# ============================================================================
# TEST 4: Concurrent Volume Changes
# ============================================================================
print_header "TEST 4: Concurrent Volume Changes"

echo "Testing concurrent volume changes across all codecs..."

# Save original volumes
declare -A ORIG_VOLUMES
for codec in "${FOUND_CODECS[@]}"; do
    if check_control_exists "$codec" "CH1 Digital Volume"; then
        ORIG_VOLUMES[$codec]=$(get_control "$codec" "CH1 Digital Volume")
    fi
done

# Set different volumes on each codec simultaneously
VOLUMES=(50 100 150 200)
idx=0
for codec in "${FOUND_CODECS[@]}"; do
    if check_control_exists "$codec" "CH1 Digital Volume"; then
        VOL=${VOLUMES[$idx]}
        (set_control "$codec" "CH1 Digital Volume" $VOL) &
        idx=$((idx + 1))
    fi
done
wait
sleep 0.1

# Verify
echo ""
echo "Verifying volume settings:"
idx=0
ALL_CORRECT=1
for codec in "${FOUND_CODECS[@]}"; do
    if check_control_exists "$codec" "CH1 Digital Volume"; then
        EXPECTED=${VOLUMES[$idx]}
        ACTUAL=$(get_control "$codec" "CH1 Digital Volume")
        echo "  $codec: expected $EXPECTED, got $ACTUAL"
        if [ "$ACTUAL" != "$EXPECTED" ]; then
            ALL_CORRECT=0
        fi
        idx=$((idx + 1))
    fi
done

# Restore volumes
for codec in "${FOUND_CODECS[@]}"; do
    if [ -n "${ORIG_VOLUMES[$codec]}" ]; then
        set_control "$codec" "CH1 Digital Volume" "${ORIG_VOLUMES[$codec]}"
    fi
done

if [ $ALL_CORRECT -eq 1 ]; then
    print_pass "Concurrent volume changes successful"
else
    print_fail "Concurrent volume changes failed"
fi

# ============================================================================
# TEST 5: Concurrent Control Read Stress
# ============================================================================
print_header "TEST 5: Concurrent Control Read Stress"

echo "Hammering all codecs with concurrent reads..."

ITERATIONS=20
ERRORS=0

for i in $(seq 1 $ITERATIONS); do
    # Read multiple controls from all codecs simultaneously
    for codec in "${FOUND_CODECS[@]}"; do
        (
            get_control "$codec" "DC LDG Result" >/dev/null
            get_control "$codec" "CH1 Auto Mute Switch" >/dev/null
            get_control "$codec" "CH2 Auto Mute Switch" >/dev/null
        ) &
    done
    wait

    # Brief pause
    sleep 0.05
done

echo "  Completed $ITERATIONS iterations of concurrent reads"

# Check for errors in kernel log
READ_ERRORS=$(dmesg | grep -iE "tas6754.*error|i2c.*error" | wc -l)
echo "  Kernel errors: $READ_ERRORS"

if [ $READ_ERRORS -eq 0 ]; then
    print_pass "Concurrent read stress test passed"
else
    print_fail "Concurrent read stress failed with $READ_ERRORS errors"
fi

# ============================================================================
# TEST 6: Cross-Codec Independence
# ============================================================================
print_header "TEST 6: Cross-Codec Independence"

echo "Verifying codecs don't interfere with each other..."

if [ ${#FOUND_CODECS[@]} -ge 2 ]; then
    CODEC1="${FOUND_CODECS[0]}"
    CODEC2="${FOUND_CODECS[1]}"

    echo "  Testing: $CODEC1 and $CODEC2"

    # Set different states
    set_control "$CODEC1" "CH1 Auto Mute Switch" 1
    set_control "$CODEC2" "CH1 Auto Mute Switch" 0

    sleep 0.1

    # Verify
    STATE1=$(get_control "$CODEC1" "CH1 Auto Mute Switch")
    STATE2=$(get_control "$CODEC2" "CH1 Auto Mute Switch")

    echo "  $CODEC1 CH1: $STATE1 (expected on)"
    echo "  $CODEC2 CH1: $STATE2 (expected off)"

    if [ "$STATE1" = "on" ] && [ "$STATE2" = "off" ]; then
        print_pass "Codecs are independent"
    else
        print_fail "Cross-codec interference detected"
    fi

    # Restore
    set_control "$CODEC1" "CH1 Auto Mute Switch" 1
    set_control "$CODEC2" "CH1 Auto Mute Switch" 1
fi

# ============================================================================
# TEST 7: I2C Bus Stress Test
# ============================================================================
print_header "TEST 7: I2C Bus Stress Test"

echo "Stressing I2C bus with rapid concurrent operations..."

dmesg -C

STRESS_ITERATIONS=50
for i in $(seq 1 $STRESS_ITERATIONS); do
    # Random operations on all codecs
    for codec in "${FOUND_CODECS[@]}"; do
        (
            # Random enable/disable
            if [ $((RANDOM % 2)) -eq 0 ]; then
                set_control "$codec" "CH1 Auto Mute Switch" 1
            else
                set_control "$codec" "CH1 Auto Mute Switch" 0
            fi

            # Read status
            get_control "$codec" "DC LDG Result" >/dev/null
        ) &
    done
    wait
done

echo "  Completed $STRESS_ITERATIONS stress iterations"

# Check for I2C errors
I2C_ERRORS=$(dmesg | grep -iE "i2c.*error|i2c.*timeout" | wc -l)
TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)

echo "  I2C errors: $I2C_ERRORS"
echo "  TAS6754 errors: $TAS_ERRORS"

if [ $I2C_ERRORS -eq 0 ] && [ $TAS_ERRORS -eq 0 ]; then
    print_pass "I2C bus stress test passed"
else
    print_fail "I2C bus stress test failed"
    if [ $I2C_ERRORS -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Recent I2C errors:${NC}"
        dmesg | grep -iE "i2c.*error|i2c.*timeout" | tail -5
    fi
fi

# ============================================================================
# TEST SUMMARY
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           TEST SUMMARY                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Codecs tested: ${#FOUND_CODECS[@]}"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo "WARNINGS: $WARN"
echo ""

TOTAL=$((PASS + FAIL))
if [ $TOTAL -gt 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; ($PASS / $TOTAL) * 100" | bc)
    echo "Success Rate: ${SUCCESS_RATE}%"
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ALL TESTS PASSED! ✓                  ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   SOME TESTS FAILED! ✗                 ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    exit 1
fi
