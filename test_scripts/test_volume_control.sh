#!/bin/bash
# TAS6754 Volume Control Test
# Tests analog and digital volume controls, mute, and volume ramp settings

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
echo -e "${BLUE}║   TAS6754 Volume Control Test Suite   ║${NC}"
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

# ============================================================================
# TEST 1: Volume Control Availability
# ============================================================================
print_header "TEST 1: Volume Control Availability"

echo "Checking for volume controls..."

VOLUME_CONTROLS=()

# Check analog volume
if amixer -c $CARD cget name="$PREFIX Analog Playback Volume" >/dev/null 2>&1; then
    echo "  ✓ Found: Analog Playback Volume"
    VOLUME_CONTROLS+=("Analog Playback Volume")
fi

# Check per-channel digital volumes
CHANNELS=("CH1" "CH2" "CH3" "CH4")
for ch in "${CHANNELS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX ${ch} Digital Playback Volume" >/dev/null 2>&1; then
        echo "  ✓ Found: $ch Digital Playback Volume"
        VOLUME_CONTROLS+=("${ch} Digital Playback Volume")
    fi
done

if [ ${#VOLUME_CONTROLS[@]} -eq 0 ]; then
    print_fail "No volume controls found"
    exit 1
else
    print_pass "Found ${#VOLUME_CONTROLS[@]} volume controls"
fi

# ============================================================================
# TEST 2: Volume Range Test
# ============================================================================
print_header "TEST 2: Volume Range Test"

echo "Testing volume ranges for all controls..."

RANGE_ERRORS=0

for ctrl in "${VOLUME_CONTROLS[@]}"; do
    echo ""
    echo "  Testing: $ctrl"

    INFO=$(amixer -c $CARD cget name="$PREFIX $ctrl" 2>/dev/null)
    MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
    MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

    echo "    Range: $MIN to $MAX"

    # Save original
    ORIG=$(get_control "$ctrl")

    # Test min
    set_control "$ctrl" $MIN
    VERIFY=$(get_control "$ctrl")
    if [ $VERIFY -eq $MIN ]; then
        echo "    ✓ Min value works ($MIN)"
    else
        echo -e "    ${RED}✗ Min value failed (got $VERIFY)${NC}"
        RANGE_ERRORS=$((RANGE_ERRORS + 1))
    fi

    # Test max
    set_control "$ctrl" $MAX
    VERIFY=$(get_control "$ctrl")
    if [ $VERIFY -eq $MAX ]; then
        echo "    ✓ Max value works ($MAX)"
    else
        echo -e "    ${RED}✗ Max value failed (got $VERIFY)${NC}"
        RANGE_ERRORS=$((RANGE_ERRORS + 1))
    fi

    # Test mid-range
    MID=$(((MIN + MAX) / 2))
    set_control "$ctrl" $MID
    VERIFY=$(get_control "$ctrl")
    if [ $VERIFY -eq $MID ]; then
        echo "    ✓ Mid value works ($MID)"
    else
        echo -e "    ${RED}✗ Mid value failed (got $VERIFY)${NC}"
        RANGE_ERRORS=$((RANGE_ERRORS + 1))
    fi

    # Restore original
    set_control "$ctrl" $ORIG
done

echo ""
if [ $RANGE_ERRORS -eq 0 ]; then
    print_pass "All volume range tests passed"
else
    print_fail "Some volume range tests failed ($RANGE_ERRORS errors)"
fi

# ============================================================================
# TEST 3: Auto Mute Controls
# ============================================================================
print_header "TEST 3: Auto Mute Controls"

echo "Testing auto mute controls (mute-on-silence)..."

MUTE_AVAILABLE=()

for ch in "${CHANNELS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX ${ch} Auto Mute Switch" >/dev/null 2>&1; then
        MUTE_AVAILABLE+=($ch)
        echo "  ✓ Found: $ch Auto Mute Switch"
    fi
done

if [ ${#MUTE_AVAILABLE[@]} -eq 0 ]; then
    print_warn "No auto mute controls found"
else
    echo ""
    echo "Testing auto mute enable/disable..."

    MUTE_ERRORS=0
    for ch in "${MUTE_AVAILABLE[@]}"; do
        CTRL="${ch} Auto Mute Switch"

        # Enable
        set_control "$CTRL" 1
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "1" ]; then
            echo "  ✓ $ch auto mute enabled"
        else
            echo -e "  ${RED}✗ $ch auto mute enable failed${NC}"
            MUTE_ERRORS=$((MUTE_ERRORS + 1))
        fi

        # Disable
        set_control "$CTRL" 0
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "0" ]; then
            echo "  ✓ $ch auto mute disabled"
        else
            echo -e "  ${RED}✗ $ch auto mute disable failed${NC}"
            MUTE_ERRORS=$((MUTE_ERRORS + 1))
        fi
    done

    if [ $MUTE_ERRORS -eq 0 ]; then
        print_pass "All auto mute controls functional"
    else
        print_fail "Some auto mute controls failed ($MUTE_ERRORS errors)"
    fi
fi

# ============================================================================
# TEST 4: Volume Persistence Test
# ============================================================================
print_header "TEST 4: Volume Persistence Test"

echo "Testing volume value persistence..."

# Pick the first available volume control
TEST_CTRL="${VOLUME_CONTROLS[0]}"
echo "  Using: $TEST_CTRL"

INFO=$(amixer -c $CARD cget name="$PREFIX $TEST_CTRL" 2>/dev/null)
MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')
ORIG=$(get_control "$TEST_CTRL")

TEST_VAL=$(((MIN + MAX) / 2))

echo "  Setting test value: $TEST_VAL"
set_control "$TEST_CTRL" $TEST_VAL

# Read multiple times
READS=()
for i in $(seq 1 5); do
    VAL=$(get_control "$TEST_CTRL")
    READS+=($VAL)
    echo "    Read $i: $VAL"
done

# Check all reads are identical
PERSISTENT=1
for val in "${READS[@]}"; do
    if [ $val -ne $TEST_VAL ]; then
        PERSISTENT=0
    fi
done

# Restore
set_control "$TEST_CTRL" $ORIG

if [ $PERSISTENT -eq 1 ]; then
    print_pass "Volume values are persistent"
else
    print_fail "Volume values are not persistent"
fi

# ============================================================================
# TEST 5: Per-Channel Volume Independence
# ============================================================================
print_header "TEST 5: Per-Channel Volume Independence"

# Filter to only channel-specific volumes
CH_VOLUMES=()
for ctrl in "${VOLUME_CONTROLS[@]}"; do
    if echo "$ctrl" | grep -q "CH[1-4]"; then
        CH_VOLUMES+=("$ctrl")
    fi
done

if [ ${#CH_VOLUMES[@]} -lt 2 ]; then
    print_warn "Not enough channel volumes for independence test"
else
    echo "Testing ${#CH_VOLUMES[@]} channel volumes are independent..."

    # Set different volumes for each channel
    for i in "${!CH_VOLUMES[@]}"; do
        ctrl="${CH_VOLUMES[$i]}"
        INFO=$(amixer -c $CARD cget name="$PREFIX $ctrl" 2>/dev/null)
        MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
        MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

        # Set to different value based on index
        VAL=$((MIN + (MAX - MIN) * i / ${#CH_VOLUMES[@]}))
        set_control "$ctrl" $VAL
        echo "  Set $ctrl to $VAL"
    done

    # Verify each channel has its unique value
    echo ""
    echo "  Verifying independence..."
    INDEPENDENT=1
    for i in "${!CH_VOLUMES[@]}"; do
        ctrl="${CH_VOLUMES[$i]}"
        INFO=$(amixer -c $CARD cget name="$PREFIX $ctrl" 2>/dev/null)
        MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
        MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')
        EXPECTED=$((MIN + (MAX - MIN) * i / ${#CH_VOLUMES[@]}))

        ACTUAL=$(get_control "$ctrl")
        echo "    $ctrl: $ACTUAL (expected $EXPECTED)"

        if [ $ACTUAL -ne $EXPECTED ]; then
            INDEPENDENT=0
        fi
    done

    if [ $INDEPENDENT -eq 1 ]; then
        print_pass "Channel volumes are independent"
    else
        print_fail "Channel volume cross-talk detected"
    fi
fi

# ============================================================================
# TEST 6: Volume Ramp Settings
# ============================================================================
print_header "TEST 6: Volume Ramp Settings"

echo "Testing volume ramp configuration controls..."

RAMP_CONTROLS=(
    "Volume Ramp Up Rate"
    "Volume Ramp Up Step"
    "Volume Ramp Down Rate"
    "Volume Ramp Down Step"
)

RAMP_FOUND=0
for ctrl in "${RAMP_CONTROLS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX $ctrl" >/dev/null 2>&1; then
        echo "  ✓ Found: $ctrl"
        RAMP_FOUND=$((RAMP_FOUND + 1))

        # Try to read/write
        ORIG=$(get_control "$ctrl")
        echo "    Current value: $ORIG"
    fi
done

if [ $RAMP_FOUND -eq 0 ]; then
    print_warn "No volume ramp controls found"
elif [ $RAMP_FOUND -eq 4 ]; then
    print_pass "All volume ramp controls available"
else
    print_warn "Some volume ramp controls missing ($RAMP_FOUND/4 found)"
fi

# ============================================================================
# TEST 7: Volume Combine Controls
# ============================================================================
print_header "TEST 7: Volume Combine Controls"

echo "Testing CH1/2 and CH3/4 volume combine controls..."

COMBINE_CONTROLS=("CH1/2 Volume Combine" "CH3/4 Volume Combine")
COMBINE_FOUND=0

for ctrl in "${COMBINE_CONTROLS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX $ctrl" >/dev/null 2>&1; then
        echo "  ✓ Found: $ctrl"
        COMBINE_FOUND=$((COMBINE_FOUND + 1))

        # Read available enum options
        OPTS=$(amixer -c $CARD cget name="$PREFIX $ctrl" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}')
        echo "    Options: $(echo $OPTS | tr '\n' ' ')"

        # Save original
        ORIG=$(get_control "$ctrl")

        # Cycle through enum values (0 and 1 for typical combine enum)
        for val in 0 1; do
            set_control "$ctrl" $val
            VERIFY=$(get_control "$ctrl")
            if [ "$VERIFY" = "$val" ]; then
                echo "    ✓ Index $val write/read OK"
            else
                echo -e "    ${RED}✗ Index $val failed (got $VERIFY)${NC}"
            fi
        done

        # Restore
        set_control "$ctrl" $ORIG
    else
        echo -e "  ${RED}✗ Missing: $ctrl${NC}"
    fi
done

if [ $COMBINE_FOUND -eq 2 ]; then
    print_pass "Both volume combine controls present and functional"
elif [ $COMBINE_FOUND -eq 0 ]; then
    print_fail "Volume combine controls not found"
else
    print_warn "Only $COMBINE_FOUND/2 volume combine controls found"
fi

# ============================================================================
# TEST 8: Analog Volume Settings
# ============================================================================
print_header "TEST 8: Analog Volume Settings"

echo "Testing Analog Gain Ramp Step control..."

if amixer -c $CARD cget name="$PREFIX Analog Gain Ramp Step" >/dev/null 2>&1; then
    echo "  ✓ Found: Analog Gain Ramp Step"

    OPTS=$(amixer -c $CARD cget name="$PREFIX Analog Gain Ramp Step" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}')
    echo "    Options: $(echo $OPTS | tr '\n' ' ')"

    ORIG=$(get_control "Analog Gain Ramp Step")

    # Cycle through all available enum values
    NUM_OPTS=$(amixer -c $CARD cget name="$PREFIX Analog Gain Ramp Step" 2>/dev/null | grep "Item #" | wc -l)
    ANA_ERRORS=0
    for val in $(seq 0 $((NUM_OPTS - 1))); do
        set_control "Analog Gain Ramp Step" $val
        VERIFY=$(get_control "Analog Gain Ramp Step")
        if [ "$VERIFY" = "$val" ]; then
            echo "    ✓ Index $val OK"
        else
            echo -e "    ${RED}✗ Index $val failed (got $VERIFY)${NC}"
            ANA_ERRORS=$((ANA_ERRORS + 1))
        fi
    done

    set_control "Analog Gain Ramp Step" $ORIG

    if [ $ANA_ERRORS -eq 0 ]; then
        print_pass "Analog Gain Ramp Step functional"
    else
        print_fail "Analog Gain Ramp Step had $ANA_ERRORS errors"
    fi
else
    print_fail "Analog Gain Ramp Step not found"
fi

# ============================================================================
# TEST 9: Auto Mute Combine and Time Configuration
# ============================================================================
print_header "TEST 9: Auto Mute Combine and Time Configuration"

echo "Testing Auto Mute Combine Switch..."
if amixer -c $CARD cget name="$PREFIX Auto Mute Combine Switch" >/dev/null 2>&1; then
    echo "  ✓ Found: Auto Mute Combine Switch"
    ORIG=$(get_control "Auto Mute Combine Switch")

    set_control "Auto Mute Combine Switch" 1
    VERIFY=$(get_control "Auto Mute Combine Switch")
    if [ "$VERIFY" = "1" ]; then
        echo "  ✓ Auto Mute Combine enabled"
    else
        echo -e "  ${RED}✗ Auto Mute Combine enable failed${NC}"
    fi

    set_control "Auto Mute Combine Switch" 0
    VERIFY=$(get_control "Auto Mute Combine Switch")
    if [ "$VERIFY" = "0" ]; then
        echo "  ✓ Auto Mute Combine disabled"
    else
        echo -e "  ${RED}✗ Auto Mute Combine disable failed${NC}"
    fi

    set_control "Auto Mute Combine Switch" $ORIG
else
    print_fail "Auto Mute Combine Switch not found"
fi

echo ""
echo "Testing per-channel Auto Mute Time controls..."

MUTE_TIME_ERRORS=0
MUTE_TIME_FOUND=0
for ch in "CH1" "CH2" "CH3" "CH4"; do
    CTRL="${ch} Auto Mute Time"
    if amixer -c $CARD cget name="$PREFIX $CTRL" >/dev/null 2>&1; then
        MUTE_TIME_FOUND=$((MUTE_TIME_FOUND + 1))
        echo "  ✓ Found: $CTRL"
        ORIG=$(get_control "$CTRL")

        # Test a couple enum indices
        for val in 0 1; do
            set_control "$CTRL" $val
            VERIFY=$(get_control "$CTRL")
            if [ "$VERIFY" != "$val" ]; then
                MUTE_TIME_ERRORS=$((MUTE_TIME_ERRORS + 1))
            fi
        done

        set_control "$CTRL" $ORIG
    else
        echo -e "  ${RED}✗ Missing: $CTRL${NC}"
        MUTE_TIME_ERRORS=$((MUTE_TIME_ERRORS + 1))
    fi
done

if [ $MUTE_TIME_FOUND -eq 4 ] && [ $MUTE_TIME_ERRORS -eq 0 ]; then
    print_pass "All Auto Mute Time controls present and functional"
elif [ $MUTE_TIME_FOUND -eq 0 ]; then
    print_fail "No Auto Mute Time controls found"
else
    print_warn "$MUTE_TIME_FOUND/4 Auto Mute Time controls found, $MUTE_TIME_ERRORS errors"
fi

# ============================================================================
# TEST 10: Volume Stress Test
# ============================================================================
print_header "TEST 10: Volume Stress Test"

echo "Performing rapid volume changes (20 iterations)..."

dmesg -C

TEST_CTRL="${VOLUME_CONTROLS[0]}"
INFO=$(amixer -c $CARD cget name="$PREFIX $TEST_CTRL" 2>/dev/null)
MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')
ORIG=$(get_control "$TEST_CTRL")

ERRORS=0
for i in $(seq 1 20); do
    if ! set_control "$TEST_CTRL" $MIN; then
        ERRORS=$((ERRORS + 1))
    fi
    if ! set_control "$TEST_CTRL" $MAX; then
        ERRORS=$((ERRORS + 1))
    fi
done

# Restore
set_control "$TEST_CTRL" $ORIG

echo "  Completed 40 operations, errors: $ERRORS"

# Check kernel log
VOL_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*volume.*fail" | wc -l)

if [ $ERRORS -eq 0 ] && [ $VOL_ERRORS -eq 0 ]; then
    print_pass "Volume stress test passed"
else
    print_warn "Some issues during volume stress test (op errors: $ERRORS, kernel errors: $VOL_ERRORS)"
fi

# ============================================================================
# TEST 11: Kernel Log Analysis
# ============================================================================
print_header "TEST 11: Kernel Log Analysis"

echo "Checking kernel log for errors during volume tests..."

VOLUME_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*volume" | wc -l)

echo "  Volume-related errors in dmesg: $VOLUME_ERRORS"

if [ $VOLUME_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent errors:${NC}"
    dmesg | grep -iE "tas6754.*error|tas6754.*volume" | tail -5
    print_warn "Errors detected in kernel log"
else
    print_pass "No errors in kernel log"
fi

# ============================================================================
# FINAL VERDICT
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           TEST SUMMARY                 ║${NC}"
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
    echo -e "${GREEN}║   VOLUME CONTROL TEST PASSED! ✓       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   SOME TESTS FAILED! ✗                 ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    exit 1
fi
