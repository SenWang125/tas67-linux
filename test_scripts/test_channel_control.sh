#!/bin/bash
# TAS6754 Channel Control Test
# Tests channel-specific controls (Auto Mute, RTLDG, Digital Volume)

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
echo -e "${BLUE}║  TAS6754 Channel Control Test Suite   ║${NC}"
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
# TEST 1: Channel Auto Mute Control
# ============================================================================
print_header "TEST 1: Channel Auto Mute Control"

echo "Testing channel auto mute switches..."

CHANNELS=("CH1" "CH2" "CH3" "CH4")
AVAILABLE=()

for ch in "${CHANNELS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX ${ch} Auto Mute Switch" >/dev/null 2>&1; then
        AVAILABLE+=($ch)
        echo "  ✓ Found: $ch Auto Mute Switch"
    fi
done

if [ ${#AVAILABLE[@]} -eq 0 ]; then
    print_warn "No channel auto mute controls found"
else
    echo ""
    echo "Testing auto mute enable/disable for ${#AVAILABLE[@]} channels..."

    ERRORS=0
    for ch in "${AVAILABLE[@]}"; do
        CTRL="${ch} Auto Mute Switch"

        # Enable auto mute
        set_control "$CTRL" 1
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "1" ]; then
            echo "  ✓ $ch auto mute enabled"
        else
            echo -e "  ${RED}✗ $ch auto mute enable failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi

        # Disable auto mute
        set_control "$CTRL" 0
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "0" ]; then
            echo "  ✓ $ch auto mute disabled"
        else
            echo -e "  ${RED}✗ $ch auto mute disable failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done

    if [ $ERRORS -eq 0 ]; then
        print_pass "All channel auto mute controls functional"
    else
        print_fail "Some channel auto mute controls failed ($ERRORS errors)"
    fi
fi

# ============================================================================
# TEST 2: Channel RTLDG Switches
# ============================================================================
print_header "TEST 2: Channel RTLDG Switches"

echo "Testing channel RTLDG enable switches..."

RTLDG_AVAILABLE=()

for ch in "${CHANNELS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX ${ch} RTLDG Switch" >/dev/null 2>&1; then
        RTLDG_AVAILABLE+=($ch)
        echo "  ✓ Found: $ch RTLDG Switch"
    fi
done

if [ ${#RTLDG_AVAILABLE[@]} -eq 0 ]; then
    print_warn "No channel RTLDG switches found"
else
    echo ""
    echo "Testing RTLDG enable/disable for ${#RTLDG_AVAILABLE[@]} channels..."

    ERRORS=0
    for ch in "${RTLDG_AVAILABLE[@]}"; do
        CTRL="${ch} RTLDG Switch"

        # Enable RTLDG
        set_control "$CTRL" 1
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "1" ]; then
            echo "  ✓ $ch RTLDG enabled"
        else
            echo -e "  ${RED}✗ $ch RTLDG enable failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi

        # Disable RTLDG
        set_control "$CTRL" 0
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "0" ]; then
            echo "  ✓ $ch RTLDG disabled"
        else
            echo -e "  ${RED}✗ $ch RTLDG disable failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done

    if [ $ERRORS -eq 0 ]; then
        print_pass "All channel RTLDG switches functional"
    else
        print_fail "Some channel RTLDG switches failed ($ERRORS errors)"
    fi
fi

# ============================================================================
# TEST 3: Channel Digital Volume Controls
# ============================================================================
print_header "TEST 3: Channel Digital Volume Controls"

echo "Testing per-channel digital volume controls..."

VOL_AVAILABLE=()

for ch in "${CHANNELS[@]}"; do
    if amixer -c $CARD cget name="$PREFIX ${ch} Digital Playback Volume" >/dev/null 2>&1; then
        VOL_AVAILABLE+=($ch)
        echo "  ✓ Found: $ch Digital Playback Volume"
    fi
done

if [ ${#VOL_AVAILABLE[@]} -eq 0 ]; then
    print_warn "No per-channel volume controls found"
else
    echo ""
    echo "Testing volume range for ${#VOL_AVAILABLE[@]} channels..."

    ERRORS=0
    for ch in "${VOL_AVAILABLE[@]}"; do
        CTRL="${ch} Digital Playback Volume"

        # Get range
        INFO=$(amixer -c $CARD cget name="$PREFIX $CTRL" 2>/dev/null)
        MIN=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*min=//' | sed 's/,.*//')
        MAX=$(echo "$INFO" | grep "type=INTEGER" | sed 's/.*max=//' | sed 's/,.*//')

        # Test min
        set_control "$CTRL" $MIN
        VERIFY=$(get_control "$CTRL")
        if [ $VERIFY -eq $MIN ]; then
            echo "  ✓ $ch volume min works ($MIN)"
        else
            echo -e "  ${RED}✗ $ch volume min failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi

        # Test max
        set_control "$CTRL" $MAX
        VERIFY=$(get_control "$CTRL")
        if [ $VERIFY -eq $MAX ]; then
            echo "  ✓ $ch volume max works ($MAX)"
        else
            echo -e "  ${RED}✗ $ch volume max failed${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done

    if [ $ERRORS -eq 0 ]; then
        print_pass "All channel volume controls functional"
    else
        print_fail "Some channel volume controls failed ($ERRORS errors)"
    fi
fi

# ============================================================================
# TEST 4: Channel Independence Test
# ============================================================================
print_header "TEST 4: Channel Independence Test"

echo "Testing that channel controls are independent..."

if [ ${#AVAILABLE[@]} -lt 2 ]; then
    print_warn "Not enough channels for independence test"
else
    # Set alternating auto mute pattern
    echo "  Setting alternating auto mute pattern..."
    for i in "${!AVAILABLE[@]}"; do
        ch="${AVAILABLE[$i]}"
        val=$((i % 2))
        set_control "${ch} Auto Mute Switch" $val
    done

    # Verify pattern
    INDEPENDENT=1
    for i in "${!AVAILABLE[@]}"; do
        ch="${AVAILABLE[$i]}"
        expected=$((i % 2))
        actual=$(get_control "${ch} Auto Mute Switch")
        echo "    $ch: $actual (expected $expected)"
        if [ "$actual" != "$expected" ]; then
            INDEPENDENT=0
        fi
    done

    if [ $INDEPENDENT -eq 1 ]; then
        print_pass "Channel controls are independent"
    else
        print_fail "Channel cross-talk detected"
    fi
fi

# ============================================================================
# TEST 5: Rapid Toggle Stress Test
# ============================================================================
print_header "TEST 5: Rapid Toggle Stress Test"

if [ ${#AVAILABLE[@]} -eq 0 ]; then
    print_warn "No channels available for stress test"
else
    echo "Performing rapid auto mute toggle (20 iterations)..."

    dmesg -C

    ERRORS=0
    for i in $(seq 1 20); do
        for ch in "${AVAILABLE[@]}"; do
            if ! set_control "${ch} Auto Mute Switch" 1; then
                ERRORS=$((ERRORS + 1))
            fi
            if ! set_control "${ch} Auto Mute Switch" 0; then
                ERRORS=$((ERRORS + 1))
            fi
        done
    done

    echo "  Completed $((20 * ${#AVAILABLE[@]} * 2)) operations"
    echo "  Errors: $ERRORS"

    if [ $ERRORS -eq 0 ]; then
        print_pass "Rapid toggle stress test passed"
    else
        print_warn "Some operations failed during rapid toggle ($ERRORS errors)"
    fi
fi

# ============================================================================
# TEST 6: Auto Mute Combine Switch
# ============================================================================
print_header "TEST 6: Auto Mute Combine Switch"

echo "Testing Auto Mute Combine Switch..."

if amixer -c $CARD cget name="$PREFIX Auto Mute Combine Switch" >/dev/null 2>&1; then
    echo "  ✓ Found: Auto Mute Combine Switch"
    ORIG=$(get_control "Auto Mute Combine Switch")

    ERRORS=0
    for val in 1 0; do
        set_control "Auto Mute Combine Switch" $val
        VERIFY=$(get_control "Auto Mute Combine Switch")
        if [ "$VERIFY" = "$val" ]; then
            echo "  ✓ Auto Mute Combine set to $val"
        else
            echo -e "  ${RED}✗ Auto Mute Combine set to $val failed (got $VERIFY)${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done

    set_control "Auto Mute Combine Switch" $ORIG

    if [ $ERRORS -eq 0 ]; then
        print_pass "Auto Mute Combine Switch functional"
    else
        print_fail "Auto Mute Combine Switch failed ($ERRORS errors)"
    fi
else
    print_fail "Auto Mute Combine Switch not found"
fi

# ============================================================================
# TEST 7: Auto Mute Time Configuration
# ============================================================================
print_header "TEST 7: Auto Mute Time Configuration"

echo "Testing per-channel Auto Mute Time enum controls..."

MUTE_TIME_ERRORS=0
MUTE_TIME_FOUND=0

for ch in "${CHANNELS[@]}"; do
    CTRL="${ch} Auto Mute Time"
    if amixer -c $CARD cget name="$PREFIX $CTRL" >/dev/null 2>&1; then
        MUTE_TIME_FOUND=$((MUTE_TIME_FOUND + 1))
        echo "  ✓ Found: $CTRL"

        OPTS=$(amixer -c $CARD cget name="$PREFIX $CTRL" 2>/dev/null | grep "Item #" | awk -F"'" '{print $2}' | tr '\n' ' ')
        echo "    Options: $OPTS"

        ORIG=$(get_control "$CTRL")

        # Test first two enum values
        for val in 0 1; do
            set_control "$CTRL" $val
            VERIFY=$(get_control "$CTRL")
            if [ "$VERIFY" = "$val" ]; then
                echo "    ✓ $ch: index $val write/read OK"
            else
                echo -e "    ${RED}✗ $ch: index $val failed (got $VERIFY)${NC}"
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
    print_warn "$MUTE_TIME_FOUND/4 Auto Mute Time controls, $MUTE_TIME_ERRORS errors"
fi

# ============================================================================
# TEST 8: ISENSE Calibration Switch
# ============================================================================
print_header "TEST 8: ISENSE Calibration Switch"

echo "Testing ISENSE Calibration Switch..."

if amixer -c $CARD cget name="$PREFIX ISENSE Calibration Switch" >/dev/null 2>&1; then
    echo "  ✓ Found: ISENSE Calibration Switch"
    ORIG=$(get_control "ISENSE Calibration Switch")

    ERRORS=0
    for val in 1 0; do
        set_control "ISENSE Calibration Switch" $val
        VERIFY=$(get_control "ISENSE Calibration Switch")
        if [ "$VERIFY" = "$val" ]; then
            echo "  ✓ ISENSE Calibration set to $val"
        else
            echo -e "  ${RED}✗ ISENSE Calibration set to $val failed (got $VERIFY)${NC}"
            ERRORS=$((ERRORS + 1))
        fi
    done

    set_control "ISENSE Calibration Switch" $ORIG

    if [ $ERRORS -eq 0 ]; then
        print_pass "ISENSE Calibration Switch functional"
    else
        print_fail "ISENSE Calibration Switch failed ($ERRORS errors)"
    fi
else
    print_fail "ISENSE Calibration Switch not found"
fi

# ============================================================================
# TEST 9: Kernel Log Analysis
# ============================================================================
print_header "TEST 9: Kernel Log Analysis"

echo "Checking kernel log for errors during channel control tests..."

CHANNEL_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*channel.*fail" | wc -l)

echo "  Channel-related errors in dmesg: $CHANNEL_ERRORS"

if [ $CHANNEL_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent errors:${NC}"
    dmesg | grep -iE "tas6754.*error|tas6754.*channel" | tail -5
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
    echo -e "${GREEN}║   CHANNEL CONTROL TEST PASSED! ✓      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   SOME TESTS FAILED! ✗                 ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    exit 1
fi
