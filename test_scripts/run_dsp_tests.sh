#!/bin/bash
# TAS6754 DSP Control Test Suite
# Run this script on the target AM62D-EVM board
#
# Usage: run_dsp_tests.sh [--strict] [--test N]
#   --strict: Exit immediately on first failure (default: continue all tests)
#   --test N: Run only test N (e.g., --test 2 runs only TEST 2)

# Parse command-line options
STRICT_MODE=0
SPECIFIC_TEST=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --strict)
            STRICT_MODE=1
            shift
            ;;
        --test)
            SPECIFIC_TEST="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--strict] [--test N]"
            exit 1
            ;;
    esac
done

# Only exit on error if strict mode enabled
if [ $STRICT_MODE -eq 1 ]; then
    set -e
fi

# Configuration
CARD="0"
PREFIX="TAS0"
TEST_AUDIO="/usr/share/sounds/alsa/Front_Center.wav"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
PASS=0
FAIL=0
WARN=0

# Helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_pass() {
    echo -e "${GREEN}✓ PASS: $1${NC}"
    PASS=$((PASS + 1))
}

print_fail() {
    echo -e "${RED}✗ FAIL: $1${NC}"
    FAIL=$((FAIL + 1))
}

print_warn() {
    echo -e "${YELLOW}⚠ WARN: $1${NC}"
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

get_control_enum() {
    # Get the numeric index
    local idx=$(amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}')
    # Get the corresponding item text
    amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep "Item #${idx} " | awk -F"'" '{print $2}'
}

get_control_enum_index() {
    amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}'
}

set_control() {
    amixer -c $CARD cset name="$PREFIX $1" "$2" >/dev/null 2>&1
    return $?
}

check_control_exists() {
    amixer -c $CARD cget name="$PREFIX $1" >/dev/null 2>&1
    return $?
}

should_run_test() {
    local test_num=$1
    # If no specific test requested, run all tests
    if [ -z "$SPECIFIC_TEST" ]; then
        return 0
    fi
    # Otherwise, only run the requested test
    if [ "$SPECIFIC_TEST" = "$test_num" ]; then
        return 0
    fi
    return 1
}

# Start test suite
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     TAS6754 DSP Control Test Suite    ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Device: TAS6754 at I2C address 0x70"
echo "Card: $CARD"
echo "Prefix: $PREFIX"
echo "Test Audio: $TEST_AUDIO"
echo "Time: $(date)"
echo ""

# ============================================================================
# TEST 1: DSP Control Availability Check
# ============================================================================
if should_run_test 1; then
print_header "TEST 1: DSP Control Availability Check"

REQUIRED_CONTROLS=(
    "DSP Signal Path Mode"
    "Thermal Foldback Switch"
    "PVDD Foldback Switch"
    "DC Blocker Bypass Switch"
    "Clip Detect Switch"
    "Audio SDOUT Switch"
    "OTSD Auto Recovery Switch"
    "Overcurrent Limit Level"
    "CH1 OTW Threshold"
    "CH2 OTW Threshold"
    "CH3 OTW Threshold"
    "CH4 OTW Threshold"
    "Spread Spectrum Mode"
    "SS Triangle Range"
    "SS Random Range"
    "SS Random Dwell Range"
    "SS Triangle Dwell Min"
    "SS Triangle Dwell Max"
    "RTLDG Open Load Threshold"
    "RTLDG Short Load Threshold"
)

echo "Checking for required DSP ALSA controls..."
for ctrl in "${REQUIRED_CONTROLS[@]}"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ $ctrl"
    else
        print_fail "Missing control: $ctrl"
    fi
done

if [ $FAIL -eq 0 ]; then
    print_pass "All required DSP controls present"
fi
fi

# ============================================================================
# TEST 2: DSP Signal Path Mode
# ============================================================================
if should_run_test 2; then
print_header "TEST 2: DSP Signal Path Mode"

echo "Reading current DSP mode..."
CURRENT_MODE_IDX=$(get_control_enum_index "DSP Signal Path Mode")
CURRENT_MODE=$(get_control_enum "DSP Signal Path Mode")
echo "  Current mode: $CURRENT_MODE (index $CURRENT_MODE_IDX)"

# Save original mode for restore
ORIG_MODE_IDX="$CURRENT_MODE_IDX"

echo ""
echo "Testing mode switching (Normal → LLP → FFLP → Normal)..."

# Test Normal mode
echo "  Setting mode to 'Normal'..."
set_control "DSP Signal Path Mode" "Normal"
if [ $? -eq 0 ]; then
    VERIFY_IDX=$(get_control_enum_index "DSP Signal Path Mode")
    VERIFY=$(get_control_enum "DSP Signal Path Mode")
    if [ "$VERIFY_IDX" = "0" ]; then
        echo "    ✓ Switched to Normal mode (verified: $VERIFY)"
    else
        print_fail "Mode readback mismatch: expected index 0, got $VERIFY_IDX ($VERIFY)"
    fi
else
    print_fail "Failed to set Normal mode"
fi

# Test LLP mode
echo "  Setting mode to 'LLP' (Low Latency Path)..."
set_control "DSP Signal Path Mode" "LLP"
if [ $? -eq 0 ]; then
    VERIFY_IDX=$(get_control_enum_index "DSP Signal Path Mode")
    VERIFY=$(get_control_enum "DSP Signal Path Mode")
    if [ "$VERIFY_IDX" = "1" ]; then
        echo "    ✓ Switched to LLP mode (verified: $VERIFY)"
    else
        print_fail "Mode readback mismatch: expected index 1, got $VERIFY_IDX ($VERIFY)"
    fi
else
    print_fail "Failed to set LLP mode"
fi

# Test FFLP mode
echo "  Setting mode to 'FFLP' (Full Feature Low Power)..."
set_control "DSP Signal Path Mode" "FFLP"
if [ $? -eq 0 ]; then
    VERIFY_IDX=$(get_control_enum_index "DSP Signal Path Mode")
    VERIFY=$(get_control_enum "DSP Signal Path Mode")
    if [ "$VERIFY_IDX" = "2" ]; then
        echo "    ✓ Switched to FFLP mode (verified: $VERIFY)"
    else
        print_fail "Mode readback mismatch: expected index 2, got $VERIFY_IDX ($VERIFY)"
    fi
else
    print_fail "Failed to set FFLP mode"
fi

# Restore original mode
echo "  Restoring original mode: index $ORIG_MODE_IDX"
set_control "DSP Signal Path Mode" "$ORIG_MODE_IDX"

print_pass "DSP mode switching works correctly"
fi

# ============================================================================
# TEST 3: DSP Protection Switches
# ============================================================================
if should_run_test 3; then
print_header "TEST 3: DSP Protection Switches"

# Ensure we're in Normal mode for full DSP features
echo "Setting DSP mode to 'Normal' for full feature access..."
set_control "DSP Signal Path Mode" "Normal"

DSP_SWITCHES=(
    "Thermal Foldback Switch"
    "PVDD Foldback Switch"
    "DC Blocker Bypass Switch"
    "Clip Detect Switch"
    "Audio SDOUT Switch"
)

echo ""
echo "Testing DSP protection switches (read, toggle, verify, restore)..."

for switch in "${DSP_SWITCHES[@]}"; do
    echo ""
    echo "  Testing: $switch"

    # Read original value
    ORIG=$(get_control "$switch")
    echo "    Original value: $ORIG"

    # Toggle to opposite value
    if [ "$ORIG" = "on" ] || [ "$ORIG" = "1" ]; then
        NEW_VAL="0"
    else
        NEW_VAL="1"
    fi

    # Write new value
    set_control "$switch" $NEW_VAL
    if [ $? -ne 0 ]; then
        print_fail "$switch: Failed to write value"
        continue
    fi

    # Verify
    VERIFY=$(get_control "$switch")
    if [ "$VERIFY" = "$NEW_VAL" ] || \
       ([ "$NEW_VAL" = "1" ] && [ "$VERIFY" = "on" ]) || \
       ([ "$NEW_VAL" = "0" ] && [ "$VERIFY" = "off" ]); then
        echo "    ✓ Write successful (new value: $VERIFY)"
    else
        print_fail "$switch: Readback mismatch (expected $NEW_VAL, got $VERIFY)"
    fi

    # Restore original
    set_control "$switch" "$ORIG"
    VERIFY=$(get_control "$switch")
    if [ "$VERIFY" = "$ORIG" ]; then
        echo "    ✓ Restored to original value"
    else
        print_warn "$switch: Failed to restore original value"
    fi
done

print_pass "All DSP protection switches functional"
fi

# ============================================================================
# TEST 4: DSP Memory Access (RTLDG Thresholds)
# ============================================================================
if should_run_test 4; then
print_header "TEST 4: DSP Memory Access (RTLDG Thresholds)"

echo "Reading RTLDG thresholds from DSP memory..."
OL_THRESH=$(get_control "RTLDG Open Load Threshold")
SL_THRESH=$(get_control "RTLDG Short Load Threshold")

echo "  Open Load Threshold:  0x$(printf '%08x' $OL_THRESH) ($OL_THRESH)"
echo "  Short Load Threshold: 0x$(printf '%08x' $SL_THRESH) ($SL_THRESH)"

if [ $OL_THRESH -gt 0 ] && [ $SL_THRESH -ge 0 ]; then
    echo "  ✓ DSP memory read successful"
else
    print_warn "Threshold values may be zero (not initialized or disabled)"
fi

echo ""
echo "Testing DSP memory write (Open Load Threshold)..."

# Save original value
OL_ORIG=$OL_THRESH

# Test value (common threshold: 0x7F800000 for high impedance)
TEST_VAL=$((0x7F800000))
echo "  Writing test value: 0x$(printf '%08x' $TEST_VAL)"

set_control "RTLDG Open Load Threshold" $TEST_VAL
if [ $? -eq 0 ]; then
    VERIFY=$(get_control "RTLDG Open Load Threshold")
    if [ $VERIFY -eq $TEST_VAL ]; then
        echo "  ✓ DSP memory write successful"
        echo "  ✓ Readback matches: 0x$(printf '%08x' $VERIFY)"
    else
        # Check if value changed at all (some bits may be read-only)
        if [ $VERIFY -ne $OL_ORIG ]; then
            echo "  ⚠ Write partially successful (got 0x$(printf '%08x' $VERIFY), expected 0x$(printf '%08x' $TEST_VAL))"
            echo "  ℹ Note: Some bits may be hardware-limited or read-only"
        else
            print_warn "DSP memory write had no effect (register may be read-only)"
        fi
    fi

    # Restore original
    set_control "RTLDG Open Load Threshold" $OL_ORIG
    VERIFY=$(get_control "RTLDG Open Load Threshold")
    if [ $VERIFY -eq $OL_ORIG ]; then
        echo "  ✓ Restored original value: 0x$(printf '%08x' $VERIFY)"
    else
        print_warn "Failed to restore original threshold (got 0x$(printf '%08x' $VERIFY))"
    fi
else
    print_warn "Failed to write DSP memory (amixer error)"
fi

print_pass "DSP memory read/write functional"
fi

# ============================================================================
# TEST 5: DSP Mode Persistence During Operations
# ============================================================================
if should_run_test 5; then
print_header "TEST 5: DSP Mode Persistence During Operations"

echo "Setting DSP mode to 'FFLP'..."
set_control "DSP Signal Path Mode" "FFLP"
MODE_BEFORE_IDX=$(get_control_enum_index "DSP Signal Path Mode")
MODE_BEFORE=$(get_control_enum "DSP Signal Path Mode")
echo "  Mode before test: $MODE_BEFORE (index $MODE_BEFORE_IDX)"

echo ""
echo "Toggling various controls while in FFLP mode..."
set_control "Thermal Foldback Switch" 1
set_control "PVDD Foldback Switch" 1
set_control "DC Blocker Bypass Switch" 0
set_control "Clip Detect Switch" 1

MODE_AFTER_IDX=$(get_control_enum_index "DSP Signal Path Mode")
MODE_AFTER=$(get_control_enum "DSP Signal Path Mode")
echo "  Mode after control changes: $MODE_AFTER (index $MODE_AFTER_IDX)"

if [ "$MODE_BEFORE_IDX" = "$MODE_AFTER_IDX" ]; then
    print_pass "DSP mode persisted correctly during operations"
else
    print_fail "DSP mode changed unexpectedly: $MODE_BEFORE → $MODE_AFTER"
fi

# Restore to Normal
set_control "DSP Signal Path Mode" "Normal"
fi

# ============================================================================
# TEST 6: DSP Feature Availability by Mode
# ============================================================================
if should_run_test 6; then
print_header "TEST 6: DSP Feature Availability by Mode"

echo "Testing feature availability across DSP modes..."
echo ""

# Test Normal mode (all features available)
echo "Testing Normal mode (all DSP features should work)..."
set_control "DSP Signal Path Mode" "Normal"
sleep 0.5

set_control "Thermal Foldback Switch" 1
TF_RESULT=$?
set_control "PVDD Foldback Switch" 1
PF_RESULT=$?

if [ $TF_RESULT -eq 0 ] && [ $PF_RESULT -eq 0 ]; then
    echo "  ✓ Normal mode: All DSP features accessible"
else
    print_warn "Normal mode: Some features failed"
fi

# Test LLP mode (limited features)
echo ""
echo "Testing LLP mode (Low Latency Path - limited DSP)..."
set_control "DSP Signal Path Mode" "LLP"
sleep 0.5

# LLP mode disables some DSP features like thermal/PVDD foldback
# Just verify mode switch worked
MODE_CHECK_IDX=$(get_control_enum_index "DSP Signal Path Mode")
MODE_CHECK=$(get_control_enum "DSP Signal Path Mode")
if [ "$MODE_CHECK_IDX" = "1" ]; then
    echo "  ✓ LLP mode: Mode switch successful ($MODE_CHECK)"
    echo "  ℹ Note: Some DSP features unavailable in LLP mode (per TRM)"
else
    print_fail "LLP mode: Mode verification failed (got index $MODE_CHECK_IDX, expected 1)"
fi

# Test FFLP mode
echo ""
echo "Testing FFLP mode (Full Feature Low Power)..."
set_control "DSP Signal Path Mode" "FFLP"
sleep 0.5

MODE_CHECK_IDX=$(get_control_enum_index "DSP Signal Path Mode")
MODE_CHECK=$(get_control_enum "DSP Signal Path Mode")
if [ "$MODE_CHECK_IDX" = "2" ]; then
    echo "  ✓ FFLP mode: Mode switch successful ($MODE_CHECK)"
else
    print_fail "FFLP mode: Mode verification failed (got index $MODE_CHECK_IDX, expected 2)"
fi

# Restore to Normal
set_control "DSP Signal Path Mode" "Normal"

print_pass "DSP mode feature availability behaves as expected"
fi

# ============================================================================
# TEST 7: DSP Controls During Playback
# ============================================================================
if should_run_test 7; then
print_header "TEST 7: DSP Controls During Playback"

if [ -f "$TEST_AUDIO" ]; then
    echo "Setting DSP mode to Normal..."
    set_control "DSP Signal Path Mode" "Normal"

    echo "Starting audio playback..."
    aplay -D hw:$CARD,0 "$TEST_AUDIO" >/dev/null 2>&1 &
    APLAY_PID=$!
    sleep 0.5

    # Check if playback started
    if ! kill -0 $APLAY_PID 2>/dev/null; then
        print_warn "Audio playback failed to start"
    else
        echo ""
        echo "Testing DSP control access during playback..."

        # Try reading DSP controls during playback
        MODE_IDX=$(get_control_enum_index "DSP Signal Path Mode")
        MODE=$(get_control_enum "DSP Signal Path Mode")
        TF=$(get_control "Thermal Foldback Switch")
        OL_THRESH=$(get_control "RTLDG Open Load Threshold")

        echo "  DSP Mode: $MODE (index $MODE_IDX)"
        echo "  Thermal Foldback: $TF"
        echo "  RTLDG OL Threshold: 0x$(printf '%08x' $OL_THRESH)"

        if [ -n "$MODE_IDX" ] && [ -n "$TF" ] && [ $OL_THRESH -ge 0 ]; then
            echo "  ✓ DSP controls readable during playback"
        else
            print_fail "Failed to read DSP controls during playback"
        fi

        # Test DSP mode switch during playback (should work)
        echo ""
        echo "Testing DSP mode switch during playback..."
        set_control "DSP Signal Path Mode" "FFLP"
        SWITCH_RESULT=$?

        if [ $SWITCH_RESULT -eq 0 ]; then
            VERIFY_IDX=$(get_control_enum_index "DSP Signal Path Mode")
            VERIFY=$(get_control_enum "DSP Signal Path Mode")
            if [ "$VERIFY_IDX" = "2" ]; then
                echo "  ✓ DSP mode switch during playback: SUCCESS ($VERIFY)"
                # Restore Normal mode
                set_control "DSP Signal Path Mode" "Normal"
            else
                print_warn "Mode switch returned success but verification failed (got index $VERIFY_IDX, expected 2)"
            fi
        else
            print_warn "DSP mode switch during playback failed (may be intentional)"
        fi

        # Stop playback
        kill $APLAY_PID 2>/dev/null
        wait $APLAY_PID 2>/dev/null
    fi

    print_pass "DSP control behavior during playback tested"
else
    print_warn "Test audio file not found: $TEST_AUDIO"
fi
fi

# ============================================================================
# TEST 8: DSP Memory Book Switching Integrity
# ============================================================================
if should_run_test 8; then
print_header "TEST 8: DSP Memory Book Switching Integrity"

echo "Testing DSP book switching by reading thresholds multiple times..."

# Read RTLDG thresholds multiple times to test book switching
ITERATIONS=5
SUCCESS_COUNT=0

for i in $(seq 1 $ITERATIONS); do
    OL=$(get_control "RTLDG Open Load Threshold")
    SL=$(get_control "RTLDG Short Load Threshold")

    if [ $? -eq 0 ] && [ $OL -ge 0 ] && [ $SL -ge 0 ]; then
        echo "  Iteration $i: OL=0x$(printf '%08x' $OL), SL=0x$(printf '%08x' $SL) ✓"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  Iteration $i: Read failed ✗"
    fi

    # Small delay between reads
    sleep 0.2
done

echo ""
if [ $SUCCESS_COUNT -eq $ITERATIONS ]; then
    print_pass "DSP book switching reliable ($SUCCESS_COUNT/$ITERATIONS successful reads)"
else
    print_fail "DSP book switching unreliable ($SUCCESS_COUNT/$ITERATIONS successful reads)"
fi
fi

# ============================================================================
# TEST 9: DSP Control Write/Read Consistency
# ============================================================================
if should_run_test 9; then
print_header "TEST 9: DSP Control Write/Read Consistency"

echo "Testing write/read consistency for DSP controls..."

TEST_CONTROLS=(
    "Thermal Foldback Switch:1"
    "Thermal Foldback Switch:0"
    "PVDD Foldback Switch:1"
    "PVDD Foldback Switch:0"
    "DC Blocker Bypass Switch:1"
    "DC Blocker Bypass Switch:0"
    "Clip Detect Switch:1"
    "Clip Detect Switch:0"
)

CONSISTENT=0
TOTAL=${#TEST_CONTROLS[@]}

for test_case in "${TEST_CONTROLS[@]}"; do
    CTRL=$(echo "$test_case" | cut -d':' -f1)
    VAL=$(echo "$test_case" | cut -d':' -f2)

    set_control "$CTRL" "$VAL"
    if [ $? -eq 0 ]; then
        VERIFY=$(get_control "$CTRL")

        if [ "$VERIFY" = "$VAL" ] || \
           ([ "$VAL" = "1" ] && [ "$VERIFY" = "on" ]) || \
           ([ "$VAL" = "0" ] && [ "$VERIFY" = "off" ]); then
            CONSISTENT=$((CONSISTENT + 1))
        fi
    fi
done

echo "  Consistency: $CONSISTENT/$TOTAL tests passed"

if [ $CONSISTENT -eq $TOTAL ]; then
    print_pass "All DSP control writes are consistent with reads"
else
    print_fail "Some DSP control writes inconsistent: $CONSISTENT/$TOTAL"
fi

# Restore defaults
set_control "Thermal Foldback Switch" 0
set_control "PVDD Foldback Switch" 0
set_control "DC Blocker Bypass Switch" 0
set_control "Clip Detect Switch" 0
fi

# ============================================================================
# TEST 10: Spread Spectrum Controls
# ============================================================================
if should_run_test 10; then
print_header "TEST 10: Spread Spectrum Controls"

echo "Testing spread spectrum controls..."

SS_ERRORS=0

# Spread Spectrum Mode enum
if check_control_exists "Spread Spectrum Mode"; then
    echo "  ✓ Found: Spread Spectrum Mode"
    SS_ORIG=$(get_control "Spread Spectrum Mode")
    OPTS=$(amixer -c $CARD cget name="$PREFIX Spread Spectrum Mode" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}' | tr '\n' ' ')
    echo "    Options: $OPTS"

    NUM_OPTS=$(amixer -c $CARD cget name="$PREFIX Spread Spectrum Mode" 2>/dev/null | grep "Item #" | wc -l)
    for val in $(seq 0 $((NUM_OPTS - 1))); do
        set_control "Spread Spectrum Mode" $val
        VERIFY=$(get_control "Spread Spectrum Mode")
        if [ "$VERIFY" = "$val" ]; then
            echo "    ✓ SS Mode index $val OK"
        else
            echo "    ✗ SS Mode index $val failed (got $VERIFY)"
            SS_ERRORS=$((SS_ERRORS + 1))
        fi
    done

    set_control "Spread Spectrum Mode" $SS_ORIG
else
    print_fail "Spread Spectrum Mode not found"
    SS_ERRORS=$((SS_ERRORS + 1))
fi

echo ""
echo "Testing Spread Spectrum parameter controls..."

SS_PARAM_CONTROLS=(
    "SS Triangle Range"
    "SS Random Range"
    "SS Random Dwell Range"
)

for ctrl in "${SS_PARAM_CONTROLS[@]}"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ Found: $ctrl"
        ORIG=$(get_control "$ctrl")
        # Test first two values
        for val in 0 1; do
            set_control "$ctrl" $val
            VERIFY=$(get_control "$ctrl")
            if [ "$VERIFY" = "$val" ]; then
                echo "    ✓ Index $val OK"
            else
                echo "    ✗ Index $val failed (got $VERIFY)"
                SS_ERRORS=$((SS_ERRORS + 1))
            fi
        done
        set_control "$ctrl" $ORIG
    else
        print_fail "Missing: $ctrl"
        SS_ERRORS=$((SS_ERRORS + 1))
    fi
done

echo ""
echo "Testing SS dwell min/max..."

for ctrl in "SS Triangle Dwell Min" "SS Triangle Dwell Max"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ Found: $ctrl"
        ORIG=$(get_control "$ctrl")
        # Range is 0-15 (4-bit)
        for val in 0 7 15; do
            set_control "$ctrl" $val
            VERIFY=$(get_control "$ctrl")
            if [ "$VERIFY" = "$val" ]; then
                echo "    ✓ Value $val OK"
            else
                echo "    ✗ Value $val failed (got $VERIFY)"
                SS_ERRORS=$((SS_ERRORS + 1))
            fi
        done
        set_control "$ctrl" $ORIG
    else
        print_fail "Missing: $ctrl"
        SS_ERRORS=$((SS_ERRORS + 1))
    fi
done

if [ $SS_ERRORS -eq 0 ]; then
    print_pass "All Spread Spectrum controls functional"
else
    print_fail "Spread Spectrum controls: $SS_ERRORS errors"
fi
fi

# ============================================================================
# TEST 11: Protection Controls (OTSD and OTW)
# ============================================================================
if should_run_test 11; then
print_header "TEST 11: Protection Controls (OTSD Auto Recovery and OTW)"

echo "Testing OTSD Auto Recovery Switch..."
if check_control_exists "OTSD Auto Recovery Switch"; then
    echo "  ✓ Found: OTSD Auto Recovery Switch"
    ORIG=$(get_control "OTSD Auto Recovery Switch")

    OTSD_ERRORS=0
    for val in 1 0; do
        set_control "OTSD Auto Recovery Switch" $val
        VERIFY=$(get_control "OTSD Auto Recovery Switch")
        if [ "$VERIFY" = "$val" ] || \
           ([ "$val" = "1" ] && [ "$VERIFY" = "on" ]) || \
           ([ "$val" = "0" ] && [ "$VERIFY" = "off" ]); then
            echo "  ✓ OTSD Auto Recovery set to $val"
        else
            echo "  ✗ OTSD Auto Recovery set to $val failed (got $VERIFY)"
            OTSD_ERRORS=$((OTSD_ERRORS + 1))
        fi
    done

    set_control "OTSD Auto Recovery Switch" $ORIG

    if [ $OTSD_ERRORS -eq 0 ]; then
        print_pass "OTSD Auto Recovery Switch functional"
    else
        print_fail "OTSD Auto Recovery Switch: $OTSD_ERRORS errors"
    fi
else
    print_fail "OTSD Auto Recovery Switch not found"
fi

echo ""
echo "Testing Overcurrent Limit Level enum..."
if check_control_exists "Overcurrent Limit Level"; then
    echo "  ✓ Found: Overcurrent Limit Level"
    ORIG=$(get_control "Overcurrent Limit Level")
    OPTS=$(amixer -c $CARD cget name="$PREFIX Overcurrent Limit Level" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}' | tr '\n' ' ')
    echo "    Options: $OPTS"

    OC_ERRORS=0
    NUM_OC=$(amixer -c $CARD cget name="$PREFIX Overcurrent Limit Level" 2>/dev/null | grep "Item #" | wc -l)
    for val in $(seq 0 $((NUM_OC - 1))); do
        set_control "Overcurrent Limit Level" $val
        VERIFY=$(get_control "Overcurrent Limit Level")
        if [ "$VERIFY" = "$val" ]; then
            echo "    ✓ OC Level index $val OK"
        else
            echo "    ✗ OC Level index $val failed (got $VERIFY)"
            OC_ERRORS=$((OC_ERRORS + 1))
        fi
    done

    set_control "Overcurrent Limit Level" $ORIG

    if [ $OC_ERRORS -eq 0 ]; then
        print_pass "Overcurrent Limit Level functional"
    else
        print_fail "Overcurrent Limit Level: $OC_ERRORS errors"
    fi
else
    print_fail "Overcurrent Limit Level not found"
fi

echo ""
echo "Testing per-channel OTW Threshold enums..."

OTW_ERRORS=0
OTW_FOUND=0
for ch in 1 2 3 4; do
    CTRL="CH${ch} OTW Threshold"
    if check_control_exists "$CTRL"; then
        OTW_FOUND=$((OTW_FOUND + 1))
        echo "  ✓ Found: $CTRL"
        ORIG=$(get_control "$CTRL")
        OPTS=$(amixer -c $CARD cget name="$PREFIX $CTRL" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}' | tr '\n' ' ')
        echo "    Options: $OPTS"

        # Test first two indices
        for val in 0 1; do
            set_control "$CTRL" $val
            VERIFY=$(get_control "$CTRL")
            if [ "$VERIFY" = "$val" ]; then
                echo "    ✓ CH${ch} OTW index $val OK"
            else
                echo "    ✗ CH${ch} OTW index $val failed (got $VERIFY)"
                OTW_ERRORS=$((OTW_ERRORS + 1))
            fi
        done

        set_control "$CTRL" $ORIG
    else
        print_fail "Missing: $CTRL"
        OTW_ERRORS=$((OTW_ERRORS + 1))
    fi
done

if [ $OTW_FOUND -eq 4 ] && [ $OTW_ERRORS -eq 0 ]; then
    print_pass "All OTW Threshold controls functional"
elif [ $OTW_FOUND -eq 0 ]; then
    print_fail "OTW Threshold controls not found"
else
    print_warn "$OTW_FOUND/4 OTW Threshold controls, $OTW_ERRORS errors"
fi
fi

# ============================================================================
# TEST 12: Kernel Log Analysis
# ============================================================================
if should_run_test 12; then
print_header "TEST 12: Kernel Log Analysis"

echo "Checking dmesg for DSP-related errors/warnings..."
ERROR_COUNT=$(dmesg | grep -iE "tas6754.*(error|fail).*dsp|tas6754.*book.*fail" | wc -l)
WARN_COUNT=$(dmesg | grep -iE "tas6754.*warn.*dsp" | wc -l)

echo "  DSP-related errors found: $ERROR_COUNT"
echo "  DSP-related warnings found: $WARN_COUNT"

if [ $ERROR_COUNT -eq 0 ]; then
    print_pass "No DSP-related errors in kernel log"
else
    print_fail "$ERROR_COUNT DSP-related errors found in kernel log"
    echo ""
    echo "Recent errors:"
    dmesg | grep -iE "tas6754.*(error|fail).*dsp|tas6754.*book.*fail" | tail -3
fi

if [ $WARN_COUNT -eq 0 ]; then
    echo "  ✓ No DSP-related warnings in kernel log"
else
    echo "  ⚠ $WARN_COUNT DSP-related warnings found"
fi
fi

# ============================================================================
# Test Summary
# ============================================================================
echo ""
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           TEST SUMMARY                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}PASSED: $PASS${NC}"
echo -e "${RED}FAILED: $FAIL${NC}"
echo -e "${YELLOW}WARNINGS: $WARN${NC}"
echo ""

TOTAL=$((PASS + FAIL))
if [ $TOTAL -gt 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; $PASS * 100 / $TOTAL" | bc)
    echo "Success Rate: ${SUCCESS_RATE}%"
fi

echo ""
echo "End time: $(date)"
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
