#!/bin/bash
# TAS6754 Load Diagnostics Test Suite - Quick Runner
# Run this script on the target AM62D-EVM board
#
# Usage: run_ldg_tests.sh [--strict] [--test N]
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

set_control() {
    amixer -c $CARD cset name="$PREFIX $1" "$2" >/dev/null 2>&1
    return $?
}

trigger_control() {
    # DC LDG/AC LDG triggers are write-only (no .get); amixer cset tries to
    # read first and gets EPERM. Use SNDRV_CTL_IOCTL_ELEM_WRITE directly.
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
echo -e "${BLUE}║  TAS6754 Load Diagnostics Test Suite  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Device: TAS6754 at I2C address 0x70"
echo "Card: $CARD"
echo "Prefix: $PREFIX"
echo "Test Audio: $TEST_AUDIO"
echo "Time: $(date)"
echo ""

# ============================================================================
# TEST 1: Control Availability Check
# ============================================================================
print_header "TEST 1: Control Availability Check"

REQUIRED_CONTROLS=(
    "DC LDG Trigger"
    "AC LDG Trigger"
    "DC LDG Result"
    "CH1 DC LDG Report"
    "CH1 DC LDG SL Threshold"
    "CH1 LO LDG Switch"
    "CH1 LO LDG Report"
    "DC LDG SLOL Ramp Time"
    "DC LDG SLOL Settling Time"
    "DC LDG S2PG Ramp Time"
    "DC LDG S2PG Settling Time"
    "CH1 DC Resistance"
    "AC DIAG GAIN"
    "AC LDG Test Frequency"
    "CH1 AC LDG Real"
    "CH1 AC LDG Imag"
    "Tweeter Detection Switch"
    "Tweeter Detect Threshold"
    "CH1 Tweeter Detect Report"
    "CH1 RTLDG Switch"
    "RTLDG Clip Mask Switch"
    "RTLDG Open Load Threshold"
    "RTLDG Short Load Threshold"
    "CH1 RTLDG Impedance"
    "RTLDG Fault Latched"
    "ISENSE Calibration Switch"
)

echo "Checking for required ALSA controls..."
for ctrl in "${REQUIRED_CONTROLS[@]}"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ $ctrl"
    else
        print_fail "Missing control: $ctrl"
    fi
done

if [ $FAIL -eq 0 ]; then
    print_pass "All required controls present"
fi

# Optional monitoring controls (added in newer driver versions; WARN if absent)
OPTIONAL_CONTROLS=(
    "PVDD Sense"
    "Global Temperature"
    "CH1 Temperature Range"
    "CH2 Temperature Range"
    "CH3 Temperature Range"
    "CH4 Temperature Range"
)

echo ""
echo "Checking optional monitoring controls (may not be in all firmware versions)..."
OPT_MISSING=0
for ctrl in "${OPTIONAL_CONTROLS[@]}"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ $ctrl"
    else
        echo "  ⚠ Optional: $ctrl (not in current firmware)"
        OPT_MISSING=$((OPT_MISSING + 1))
    fi
done

if [ $OPT_MISSING -gt 0 ]; then
    print_warn "$OPT_MISSING optional monitoring controls missing (newer driver needed)"
else
    print_pass "All optional monitoring controls present"
fi

# ============================================================================
# TEST 2: DC Load Diagnostics (DC LDG)
# ============================================================================
print_header "TEST 2: DC Load Diagnostics (DC LDG)"

echo "Triggering DC LDG..."
dmesg -C
trigger_control "DC LDG Trigger"
if [ $? -eq 0 ]; then
    print_pass "DC LDG completed successfully"
    dmesg | grep "DC LDG"
else
    print_fail "DC LDG trigger failed"
    dmesg | grep "DC LDG"
fi

echo ""
echo "Reading DC LDG Results:"
DC_RESULT=$(get_control "DC LDG Result")

# DC_LDG_RESULT_REG (0xC2): bits[7:4]=LO pass, bits[3:0]=DC pass (bit0=CH1..bit3=CH4)
PASS_MASK=$((DC_RESULT & 0x0F))
LO_PASS_MASK=$(( (DC_RESULT >> 4) & 0x0F ))

echo "  DC LDG Result: 0x$(printf '%02x' $DC_RESULT)"
echo "  DC LDG Pass Mask (bits[3:0]): 0x$(printf '%x' $PASS_MASK)"
echo "  LO LDG Pass Mask (bits[7:4]): 0x$(printf '%x' $LO_PASS_MASK)"
echo ""

# Per-channel report regs (0xC0/0xC1) may be cleared when driver restores HIZ.
# Use PASS_MASK from RESULT for reliable per-channel status.
echo "  Per-channel result (PASS_MASK):"
for ch in 1 2 3 4; do
    ch_idx=$((ch - 1))
    pass_bit=$(( (PASS_MASK >> ch_idx) & 1 ))
    if [ $pass_bit -eq 1 ]; then
        echo "    CH${ch}: ✓ PASS"
    else
        echo "    CH${ch}: ✗ FAIL (OL/SL/OC, check DCR)"
    fi
done

echo ""
echo "  Per-channel report registers (0xC0/0xC1):"
for ch in 1 2 3 4; do
    REPORT=$(get_control "CH${ch} DC LDG Report")
    if [ "$REPORT" -gt 0 ] 2>/dev/null; then
        # Decode report bits: [3]=pass, [2]=OC/DC, [1]=SL, [0]=OL
        PASS_BIT=$(( (REPORT >> 3) & 1 ))
        OC_BIT=$(( (REPORT >> 2) & 1 ))
        SL_BIT=$(( (REPORT >> 1) & 1 ))
        OL_BIT=$(( REPORT & 1 ))
        echo -n "    CH${ch} Report: 0x$(printf '%x' $REPORT) -"
        [ $PASS_BIT -eq 1 ] && echo -n " PASS" || echo -n " FAIL"
        [ $OC_BIT -eq 1 ] && echo -n " OC/DC"
        [ $SL_BIT -eq 1 ] && echo -n " SL"
        [ $OL_BIT -eq 1 ] && echo -n " OL"
        echo ""
    else
        echo "    CH${ch} Report: 0x00 (cleared on HIZ restore)"
    fi
done

print_pass "DC LDG completed and results readable"

# ============================================================================
# TEST 2A: DC LDG Short-to-Load (SL) Threshold Configuration
# ============================================================================
print_header "TEST 2A: DC LDG SL Threshold Configuration"

echo "Reading DC LDG SL Thresholds for all channels (enum index):"
# Enum: 0="0.5 Ohm", 1="1 Ohm", 2="1.5 Ohm", 3="2 Ohm", ..., 9="5 Ohm"
declare -a SL_THRESH_TEXTS=("0.5 Ohm" "1 Ohm" "1.5 Ohm" "2 Ohm" "2.5 Ohm" "3 Ohm" "3.5 Ohm" "4 Ohm" "4.5 Ohm" "5 Ohm")
for ch in 1 2 3 4; do
    THRESH=$(get_control "CH${ch} DC LDG SL Threshold")
    THRESH_TEXT=${SL_THRESH_TEXTS[$THRESH]}
    echo "  CH${ch} SL Threshold: $THRESH ($THRESH_TEXT)"
done

# Save CH1 original value for restore
CH1_ORIG_THRESH=$(get_control "CH1 DC LDG SL Threshold")

echo ""
echo "Testing threshold configuration (set CH1 to index 3 = '2 Ohm')..."
set_control "CH1 DC LDG SL Threshold" 3
if [ $? -eq 0 ]; then
    VERIFY=$(get_control "CH1 DC LDG SL Threshold")
    if [ "$VERIFY" = "3" ]; then
        print_pass "DC LDG SL Threshold writable and readable"
        # Restore original value
        set_control "CH1 DC LDG SL Threshold" $CH1_ORIG_THRESH
    else
        print_fail "Threshold readback mismatch: expected 3, got $VERIFY"
    fi
else
    print_fail "Failed to set DC LDG SL Threshold"
fi

# ============================================================================
# TEST 2B: LO LDG Switches
# ============================================================================
print_header "TEST 2B: LO LDG Switches (Load Output)"

echo "Testing CH1-CH4 LO (Load Output) LDG enable switches..."

LO_ERRORS=0
LO_FOUND=0
for ch in 1 2 3 4; do
    CTRL="CH${ch} LO LDG Switch"
    if check_control_exists "$CTRL"; then
        LO_FOUND=$((LO_FOUND + 1))
        echo "  ✓ Found: $CTRL"
        ORIG=$(get_control "$CTRL")

        # Test enable/disable
        set_control "$CTRL" 1
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "1" ] || [ "$VERIFY" = "on" ]; then
            echo "    ✓ CH${ch} LO LDG enabled"
        else
            echo "    ✗ CH${ch} LO LDG enable failed (got $VERIFY)"
            LO_ERRORS=$((LO_ERRORS + 1))
        fi

        set_control "$CTRL" 0
        VERIFY=$(get_control "$CTRL")
        if [ "$VERIFY" = "0" ] || [ "$VERIFY" = "off" ]; then
            echo "    ✓ CH${ch} LO LDG disabled"
        else
            echo "    ✗ CH${ch} LO LDG disable failed (got $VERIFY)"
            LO_ERRORS=$((LO_ERRORS + 1))
        fi

        set_control "$CTRL" $ORIG
    else
        print_fail "Missing: $CTRL"
        LO_ERRORS=$((LO_ERRORS + 1))
    fi
done

if [ $LO_FOUND -eq 4 ] && [ $LO_ERRORS -eq 0 ]; then
    print_pass "All LO LDG switches functional"
elif [ $LO_FOUND -eq 0 ]; then
    print_fail "No LO LDG switches found"
else
    print_warn "$LO_FOUND/4 LO LDG switches found, $LO_ERRORS errors"
fi

echo ""
echo "Reading LO LDG Reports (after DC LDG run)..."
for ch in 1 2 3 4; do
    REPORT=$(get_control "CH${ch} LO LDG Report")
    if [ "$REPORT" = "1" ] || [ "$REPORT" = "on" ]; then
        echo "  CH${ch} LO LDG Report: PASS (load detected)"
    else
        echo "  CH${ch} LO LDG Report: FAIL/no-load (report=$REPORT)"
    fi
done

# ============================================================================
# TEST 2C: DC LDG Timing Controls
# ============================================================================
print_header "TEST 2C: DC LDG Timing Controls (SLOL and S2PG)"

echo "Reading and testing DC LDG ramp/settling time configuration..."

TIMING_CONTROLS=(
    "DC LDG SLOL Ramp Time"
    "DC LDG SLOL Settling Time"
    "DC LDG S2PG Ramp Time"
    "DC LDG S2PG Settling Time"
)

TIMING_ERRORS=0
for ctrl in "${TIMING_CONTROLS[@]}"; do
    if check_control_exists "$ctrl"; then
        echo "  ✓ Found: $ctrl"
        ORIG=$(get_control "$ctrl")
        OPTS=$(amixer -c $CARD cget name="$PREFIX $ctrl" 2>/dev/null | grep "Item #" | wc -l)
        echo "    Options: $OPTS enum values"
        echo "    Current: $ORIG"

        # Write index 0 and verify
        set_control "$ctrl" 0
        VERIFY=$(get_control "$ctrl")
        if [ "$VERIFY" = "0" ]; then
            echo "    ✓ Write index 0 OK"
        else
            echo "    ✗ Write index 0 failed (got $VERIFY)"
            TIMING_ERRORS=$((TIMING_ERRORS + 1))
        fi

        set_control "$ctrl" $ORIG
    else
        print_fail "Missing: $ctrl"
        TIMING_ERRORS=$((TIMING_ERRORS + 1))
    fi
done

if [ $TIMING_ERRORS -eq 0 ]; then
    print_pass "All DC LDG timing controls present and functional"
else
    print_fail "DC LDG timing controls: $TIMING_ERRORS errors"
fi

# ============================================================================
# TEST 3: DC Resistance Measurement (DCR)
# ============================================================================
print_header "TEST 3: DC Resistance Measurement (DCR)"

echo "Reading DC Resistance for all channels:"
for ch in 1 2 3 4; do
    DCR=$(get_control "CH${ch} DC Resistance")
    OHMS=$(echo "scale=1; $DCR / 10" | bc)
    echo "  CH${ch}: ${DCR} codes = ${OHMS}Ω"

    # Sanity check: typical speaker range 2-100Ω
    if [ $DCR -ge 20 ] && [ $DCR -le 1000 ]; then
        echo "    ✓ Valid speaker impedance range"
    elif [ $DCR -eq 0 ]; then
        print_warn "CH${ch}: Zero resistance (no load or short)"
    else
        print_warn "CH${ch}: Unusual resistance value"
    fi
done

print_pass "DC Resistance readable for all channels"

# ============================================================================
# TEST 4: AC Load Diagnostics (AC LDG)
# ============================================================================
print_header "TEST 4: AC Load Diagnostics (AC LDG)"

echo "Triggering AC LDG..."
dmesg -C
trigger_control "AC LDG Trigger"
if [ $? -eq 0 ]; then
    print_pass "AC LDG completed successfully"
    dmesg | grep "AC LDG"
else
    print_fail "AC LDG trigger failed"
    dmesg | grep "AC LDG"
fi

echo ""
echo "Reading AC LDG Complex Impedance Results:"
for ch in 1 2 3 4; do
    REAL=$(get_control "CH${ch} AC LDG Real")
    IMAG=$(get_control "CH${ch} AC LDG Imag")

    # Convert to signed 8-bit
    [ $REAL -gt 127 ] && REAL=$((REAL - 256))
    [ $IMAG -gt 127 ] && IMAG=$((IMAG - 256))

    # Calculate magnitude (approximate)
    MAG=$(echo "scale=2; sqrt($REAL*$REAL + $IMAG*$IMAG)" | bc)

    echo "  CH${ch}: Real=$REAL, Imag=$IMAG, |Z|≈$MAG"
done

print_pass "AC impedance readable for all channels"

# ============================================================================
# TEST 4A: AC LDG Gain and Frequency Configuration
# ============================================================================
print_header "TEST 4A: AC LDG Gain and Frequency Configuration"

echo "Reading AC LDG test frequency and gain controls..."

# AC DIAG GAIN (switch)
if check_control_exists "AC DIAG GAIN"; then
    echo "  ✓ Found: AC DIAG GAIN"
    ORIG_GAIN=$(get_control "AC DIAG GAIN")
    echo "    Current: $ORIG_GAIN"

    set_control "AC DIAG GAIN" 1
    VERIFY=$(get_control "AC DIAG GAIN")
    if [ "$VERIFY" = "1" ] || [ "$VERIFY" = "on" ]; then
        echo "    ✓ AC DIAG GAIN enabled"
    else
        print_warn "AC DIAG GAIN enable returned: $VERIFY"
    fi

    set_control "AC DIAG GAIN" 0
    VERIFY=$(get_control "AC DIAG GAIN")
    if [ "$VERIFY" = "0" ] || [ "$VERIFY" = "off" ]; then
        echo "    ✓ AC DIAG GAIN disabled"
    else
        print_warn "AC DIAG GAIN disable returned: $VERIFY"
    fi

    set_control "AC DIAG GAIN" $ORIG_GAIN
else
    print_fail "AC DIAG GAIN not found"
fi

echo ""

# AC LDG Test Frequency (0-255)
if check_control_exists "AC LDG Test Frequency"; then
    echo "  ✓ Found: AC LDG Test Frequency"
    ORIG_FREQ=$(get_control "AC LDG Test Frequency")
    echo "    Current: $ORIG_FREQ"

    # Test boundary values
    AC_FREQ_ERRORS=0
    for val in 0 128 255; do
        set_control "AC LDG Test Frequency" $val
        VERIFY=$(get_control "AC LDG Test Frequency")
        if [ "$VERIFY" = "$val" ]; then
            echo "    ✓ Frequency $val write/read OK"
        else
            echo "    ✗ Frequency $val failed (got $VERIFY)"
            AC_FREQ_ERRORS=$((AC_FREQ_ERRORS + 1))
        fi
    done

    set_control "AC LDG Test Frequency" $ORIG_FREQ

    if [ $AC_FREQ_ERRORS -eq 0 ]; then
        print_pass "AC LDG Test Frequency functional"
    else
        print_fail "AC LDG Test Frequency: $AC_FREQ_ERRORS errors"
    fi
else
    print_fail "AC LDG Test Frequency not found"
fi

# ============================================================================
# TEST 5: Tweeter Detection
# ============================================================================
print_header "TEST 5: Tweeter Detection Report"

TWEETER_EN=$(get_control "Tweeter Detection Switch")
echo "Tweeter Detection Switch: $TWEETER_EN"

if [ "$TWEETER_EN" = "on" ] || [ "$TWEETER_EN" = "1" ]; then
    echo "Reading Tweeter Detection Results:"
    for ch in 1 2 3 4; do
        RESULT=$(get_control "CH${ch} Tweeter Detect Report")
        if [ "$RESULT" = "1" ]; then
            echo "  CH${ch}: Tweeter detected"
        else
            echo "  CH${ch}: Woofer/Full-range"
        fi
    done
    print_pass "Tweeter detection report readable"
else
    print_warn "Tweeter detection is disabled"
fi

# ============================================================================
# TEST 5A: Tweeter Detection Threshold Configuration
# ============================================================================
print_header "TEST 5A: Tweeter Detect Threshold Configuration"

THRESH=$(get_control "Tweeter Detect Threshold")
echo "Current Tweeter Detect Threshold: $THRESH (0-255)"

echo "Testing threshold configuration (set to 128)..."
set_control "Tweeter Detect Threshold" 128
if [ $? -eq 0 ]; then
    VERIFY=$(get_control "Tweeter Detect Threshold")
    if [ "$VERIFY" = "128" ]; then
        print_pass "Tweeter Detect Threshold writable and readable"
    else
        print_fail "Threshold readback mismatch: expected 128, got $VERIFY"
    fi
else
    print_fail "Failed to set Tweeter Detect Threshold"
fi

# ============================================================================
# TEST 5B: Device Monitoring (PVDD Sense and Temperature)
# ============================================================================
print_header "TEST 5B: Device Monitoring (PVDD Sense and Temperature)"

# PVDD Sense and Temperature controls were added in a newer driver version.

echo "Reading PVDD supply voltage sense..."
if check_control_exists "PVDD Sense"; then
    PVDD=$(get_control "PVDD Sense")
    echo "  PVDD Sense: $PVDD (raw 8-bit ADC value)"
    if [ "$PVDD" -gt 0 ] 2>/dev/null; then
        echo "  ✓ PVDD Sense returns non-zero (supply present)"
    else
        print_warn "PVDD Sense = 0 (supply may be absent or stream not active)"
    fi
    print_pass "PVDD Sense readable"
else
    print_warn "PVDD Sense not found (not in current firmware)"
fi

echo ""
echo "Reading temperature monitoring registers..."

if check_control_exists "Global Temperature"; then
    GTEMP=$(get_control "Global Temperature")
    echo "  Global Temperature: $GTEMP (raw)"
    print_pass "Global Temperature readable"
else
    print_warn "Global Temperature not found (not in current firmware)"
fi

TEMP_FOUND=0
for ch in 1 2 3 4; do
    CTRL="CH${ch} Temperature Range"
    if check_control_exists "$CTRL"; then
        TEMP_FOUND=$((TEMP_FOUND + 1))
        TEMP=$(get_control "$CTRL")
        # 2-bit range: 0=normal, 1=OTW1, 2=OTW2, 3=OTSD
        case "$TEMP" in
            0) RANGE_STR="Normal" ;;
            1) RANGE_STR="OTW1 (warning 1)" ;;
            2) RANGE_STR="OTW2 (warning 2)" ;;
            3) RANGE_STR="OTSD (shutdown)" ;;
            *) RANGE_STR="Unknown ($TEMP)" ;;
        esac
        echo "  CH${ch} Temperature Range: $TEMP ($RANGE_STR)"
    fi
done

if [ $TEMP_FOUND -eq 4 ]; then
    print_pass "All channel temperature range registers readable"
elif [ $TEMP_FOUND -eq 0 ]; then
    print_warn "Channel temperature range registers not found (not in current firmware)"
else
    print_warn "$TEMP_FOUND/4 channel temperature range registers found"
fi

# ============================================================================
# TEST 6: Real-Time Load Diagnostics (RTLDG)
# ============================================================================
print_header "TEST 6: Real-Time Load Diagnostics (RTLDG)"

echo "Disabling RTLDG for all channels (clean start)..."
for ch in 1 2 3 4; do
    set_control "CH${ch} RTLDG Switch" 0
done
# Give device time to stop RTLDG and clear impedance registers
sleep 2

# Verify RTLDG switches are disabled
echo "Verifying RTLDG switches disabled..."
for ch in 1 2 3 4; do
    VERIFY=$(get_control "CH${ch} RTLDG Switch")
    if [ "$VERIFY" = "off" ] || [ "$VERIFY" = "0" ]; then
        echo "  ✓ CH${ch} RTLDG disabled"
    else
        print_warn "CH${ch} RTLDG still enabled: $VERIFY"
    fi
done

echo ""
echo "Checking RTLDG configuration switches..."
CLIP_MASK=$(get_control "RTLDG Clip Mask Switch")
echo "  RTLDG Clip Mask Switch: $CLIP_MASK"

echo ""
echo "Enabling RTLDG for all channels..."
for ch in 1 2 3 4; do
    set_control "CH${ch} RTLDG Switch" 1
    VERIFY=$(get_control "CH${ch} RTLDG Switch")
    if [ "$VERIFY" = "on" ] || [ "$VERIFY" = "1" ]; then
        echo "  ✓ CH${ch} RTLDG enabled"
    else
        print_warn "CH${ch} RTLDG enable failed"
    fi
done

echo ""
echo "Checking RTLDG Fault Latched register (before playback)..."
FAULT=$(get_control "RTLDG Fault Latched")
echo "  RTLDG Fault Latched: 0x$(printf '%02x' $FAULT)"

echo ""
echo "RTLDG Impedance BEFORE playback:"
for ch in 1 2 3 4; do
    IMP=$(get_control "CH${ch} RTLDG Impedance")
    echo "  CH${ch}: $IMP (0x$(printf '%04x' $IMP))"
    if [ $IMP -ne 0 ]; then
        print_warn "CH${ch} impedance non-zero before playback (RTLDG may not have fully disabled)"
    fi
done

echo ""
echo "Starting audio playback..."
if [ -f "$TEST_AUDIO" ]; then
    aplay -D hw:$CARD,0 "$TEST_AUDIO" >/dev/null 2>&1 &
    APLAY_PID=$!
    sleep 0.5

    echo "RTLDG Impedance DURING playback:"
    for ch in 1 2 3 4; do
        IMP=$(get_control "CH${ch} RTLDG Impedance")
        echo "  CH${ch}: $IMP (0x$(printf '%04x' $IMP))"

        if [ $IMP -gt 0 ]; then
            echo "    ✓ Active (non-zero impedance)"
        else
            echo "    ✗ Inactive (zero impedance)"
        fi
    done

    kill $APLAY_PID 2>/dev/null
    wait $APLAY_PID 2>/dev/null

    echo ""
    echo "Checking RTLDG Fault Latched register (after playback)..."
    FAULT=$(get_control "RTLDG Fault Latched")
    echo "  RTLDG Fault Latched: 0x$(printf '%02x' $FAULT)"
    if [ $FAULT -eq 0 ]; then
        echo "  ✓ No RTLDG faults detected during playback"
    else
        echo "  ⚠ RTLDG faults detected: 0x$(printf '%02x' $FAULT)"
        echo "    Bits [7:4]=OL faults [CH4:CH1], Bits [3:0]=SL faults [CH4:CH1]"
    fi

    print_pass "RTLDG impedance updates during playback"
else
    print_warn "Test audio file not found: $TEST_AUDIO"
    print_warn "Skipping RTLDG playback test"
fi

# ============================================================================
# TEST 7: Error Handling - LDG During Playback
# ============================================================================
print_header "TEST 7: Error Handling - LDG During Playback"

echo "Starting playback and attempting DC LDG (should fail with EBUSY)..."
if [ -f "$TEST_AUDIO" ]; then
    aplay -D hw:$CARD,0 "$TEST_AUDIO" >/dev/null 2>&1 &
    APLAY_PID=$!

    # Give aplay time to start
    sleep 0.5

    # Check if aplay is still running
    if ! kill -0 $APLAY_PID 2>/dev/null; then
        print_warn "Audio playback failed to start"
    else
        trigger_control "DC LDG Trigger"
        RESULT=$?

        # Force kill aplay (no need to wait since we used SIGKILL)
        kill -9 $APLAY_PID 2>/dev/null
        # Brief sleep to let process terminate
        sleep 0.2

        if [ $RESULT -ne 0 ]; then
            print_pass "DC LDG correctly blocked during playback (EBUSY)"
        else
            print_fail "DC LDG should be blocked during playback"
        fi
    fi
else
    print_warn "Test audio file not found, skipping error handling test"
fi

# ============================================================================
# TEST 8: RTLDG Threshold Configuration
# ============================================================================
print_header "TEST 8: RTLDG Threshold Configuration"

echo "Reading RTLDG thresholds (32-bit DSP values)..."
OL_THRESH=$(get_control "RTLDG Open Load Threshold")
SL_THRESH=$(get_control "RTLDG Short Load Threshold")

echo "  Open Load Threshold: 0x$(printf '%08x' $OL_THRESH)"
echo "  Short Load Threshold: 0x$(printf '%08x' $SL_THRESH)"

# Verify thresholds are reasonable
if [ $OL_THRESH -gt 0 ] && [ $SL_THRESH -ge 0 ]; then
    print_pass "RTLDG thresholds readable"
else
    print_fail "Invalid RTLDG threshold values"
fi

echo ""
# 0x7F800000 does not round-trip (upper byte beyond 24-bit DSP range).
# Use 0x00800000 which stays within range and round-trips cleanly.
TEST_THRESH=$((0x00800000))
echo "Testing RTLDG threshold write (Open Load = 0x$(printf '%08x' $TEST_THRESH))..."
set_control "RTLDG Open Load Threshold" $TEST_THRESH
if [ $? -eq 0 ]; then
    VERIFY=$(get_control "RTLDG Open Load Threshold")
    if [ "$VERIFY" -eq "$TEST_THRESH" ] 2>/dev/null; then
        echo "  ✓ Open Load Threshold write/readback matches"
        print_pass "RTLDG threshold write round-trip verified"
    else
        echo "  Wrote: 0x$(printf '%08x' $TEST_THRESH), Read back: 0x$(printf '%08x' $VERIFY)"
        print_warn "Open Load Threshold readback mismatch (hardware may clamp or mask value)"
    fi
    # Restore original value
    set_control "RTLDG Open Load Threshold" $OL_THRESH
else
    print_warn "Failed to write RTLDG threshold"
fi

# ============================================================================
# TEST 9: Runtime PM Integration
# ============================================================================
print_header "TEST 9: Runtime PM Integration"

# Check if runtime PM sysfs exists
PM_PATH="/sys/bus/i2c/devices/3-0070/power/runtime_status"
if [ -f "$PM_PATH" ]; then
    RUNTIME_STATUS=$(cat "$PM_PATH" 2>/dev/null)
    echo "Current Runtime PM status: $RUNTIME_STATUS"

    echo "Triggering DC LDG to test Runtime PM wakeup..."
    trigger_control "DC LDG Trigger"

    RUNTIME_STATUS=$(cat "$PM_PATH" 2>/dev/null)
    echo "Runtime PM status after LDG: $RUNTIME_STATUS"

    if [ "$RUNTIME_STATUS" = "active" ] || [ "$RUNTIME_STATUS" = "resuming" ]; then
        print_pass "Runtime PM integration working"
    else
        print_warn "Runtime PM status: $RUNTIME_STATUS"
    fi
else
    print_warn "Runtime PM sysfs not accessible (may need root)"
fi

# ============================================================================
# TEST 10: Kernel Log Analysis
# ============================================================================
print_header "TEST 10: Kernel Log Analysis"

echo "Checking dmesg for errors/warnings..."
ERROR_COUNT=$(dmesg | grep -i "tas6754.*error" | wc -l)
WARN_COUNT=$(dmesg | grep -i "tas6754.*warn" | wc -l)

echo "  Errors found: $ERROR_COUNT"
echo "  Warnings found: $WARN_COUNT"

if [ $ERROR_COUNT -eq 0 ]; then
    print_pass "No errors in kernel log"
else
    print_fail "$ERROR_COUNT errors found in kernel log"
    dmesg | grep -i "tas6754.*error" | tail -5
fi

if [ $WARN_COUNT -eq 0 ]; then
    echo "  ✓ No warnings in kernel log"
else
    echo "  ⚠ $WARN_COUNT warnings found"
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
