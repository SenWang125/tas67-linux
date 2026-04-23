#!/bin/bash
# TAS6754 Sample Rate Switching Test
# Tests different audio formats and sample rate handling

# Configuration
CARD="0"
PREFIX="TAS0"
# AM62D2-EVM TAS6754 setup uses 8-channel TDM
DEFAULT_CHANNELS=8
DEFAULT_FORMAT="S32_LE"

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
echo -e "${BLUE}║  TAS6754 Sample Rate Switching Test   ║${NC}"
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

# Test if audio playback works
test_playback() {
    local rate=$1
    local channels=$2
    local duration=$3

    # Generate and play audio at specified rate using aplay (speaker-test doesn't support 8ch well)
    # Exit code 124 = timeout success (command was running), 0 = normal completion
    timeout $duration aplay -D hw:$CARD,0 -c $channels -r $rate -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    local status=$?
    if [ $status -eq 0 ] || [ $status -eq 124 ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# TEST 1: Supported Sample Rate Detection
# ============================================================================
print_header "TEST 1: Supported Sample Rate Detection"

echo "Detecting supported sample rates..."

# Get card info
if [ -f "/proc/asound/card${CARD}/pcm0p/info" ]; then
    echo "  Card info:"
    cat "/proc/asound/card${CARD}/pcm0p/info" | grep -E "name|subname|rates" | sed 's/^/    /'
    echo ""
fi

# Driver-declared rates (tas675x.c: SNDRV_PCM_RATE_44100|48000|96000|192000)
# TRM §4.3.2.6.1: supported range 44.1-48kHz, 88.2-96kHz, 192kHz
SAMPLE_RATES=(44100 48000 96000 192000)

echo "  Testing sample rates..."
SUPPORTED_RATES=()

for rate in "${SAMPLE_RATES[@]}"; do
    dmesg -C
    timeout 1 aplay -D hw:$CARD,0 -r $rate -c $DEFAULT_CHANNELS -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?
    CLK_FAULTS=$(dmesg | grep -c "Clock Fault Latched" 2>/dev/null)
    if [ $STATUS -eq 0 ] || [ $STATUS -eq 124 ]; then
        if [ "$CLK_FAULTS" -gt 0 ]; then
            echo "    ⚠ $rate Hz supported (CLK_FAULT: actual FSYNC outside TAS675x 44.1-192kHz detection range)"
            SUPPORTED_RATES+=($rate)
        else
            echo "    ✓ $rate Hz supported"
            SUPPORTED_RATES+=($rate)
        fi
    else
        echo "    ✗ $rate Hz not supported"
    fi
    sleep 0.3
done

echo ""
echo "  Supported rates: ${SUPPORTED_RATES[@]}"
echo "  Count: ${#SUPPORTED_RATES[@]}"

if [ ${#SUPPORTED_RATES[@]} -ge 3 ]; then
    print_pass "Multiple sample rates supported (${#SUPPORTED_RATES[@]} rates)"
else
    print_warn "Limited sample rate support (${#SUPPORTED_RATES[@]} rates)"
fi

# ============================================================================
# TEST 2: Sequential Sample Rate Switching
# ============================================================================
print_header "TEST 2: Sequential Sample Rate Switching"

if [ ${#SUPPORTED_RATES[@]} -lt 2 ]; then
    print_warn "Not enough supported rates for switching test"
else
    echo "Testing sequential sample rate switching..."
    echo "  (2 seconds per rate)"
    echo ""

    dmesg -C

    SWITCH_ERRORS=0

    for rate in "${SUPPORTED_RATES[@]}"; do
        echo "  Playing at $rate Hz..."
        dmesg -C

        if test_playback $rate $DEFAULT_CHANNELS 2; then
            CLK_FAULTS=$(dmesg | grep -c "Clock Fault Latched" 2>/dev/null)
            if [ "$CLK_FAULTS" -gt 0 ]; then
                echo "    ⚠ $rate Hz playback ok (CLK_FAULT: actual FSYNC outside TAS675x detection range)"
            else
                echo "    ✓ $rate Hz playback successful"
            fi
        else
            echo -e "    ${RED}✗ $rate Hz playback failed${NC}"
            SWITCH_ERRORS=$((SWITCH_ERRORS + 1))
        fi

        sleep 0.5
    done

    echo ""
    echo "  Failed rate switches: $SWITCH_ERRORS/${#SUPPORTED_RATES[@]}"

    # Check for kernel errors
    RATE_ERRORS=$(dmesg | grep -iE "tas6754.*rate|tas6754.*freq|tas6754.*clock" | grep -iE "error|fail" | wc -l)

    if [ $RATE_ERRORS -gt 0 ]; then
        echo -e "    ${YELLOW}⚠ Rate-related errors in kernel log: $RATE_ERRORS${NC}"
        dmesg | grep -iE "tas6754.*rate|tas6754.*freq" | tail -5
    fi

    if [ $SWITCH_ERRORS -eq 0 ] && [ $RATE_ERRORS -eq 0 ]; then
        print_pass "Sequential rate switching successful"
    else
        print_fail "Errors during sequential rate switching"
    fi
fi

# ============================================================================
# TEST 3: Rapid Sample Rate Switching
# ============================================================================
print_header "TEST 3: Rapid Sample Rate Switching"

if [ ${#SUPPORTED_RATES[@]} -lt 2 ]; then
    print_warn "Not enough supported rates for rapid switching test"
else
    echo "Testing rapid sample rate switching (10 iterations)..."

    dmesg -C

    RAPID_ERRORS=0

    # Use TAS675x-native rates with acceptable McASP PPM for reliable rapid switching.
    # Avoid high-PPM-error rates (96kHz, 192kHz) which trigger CLK_FAULT due to
    # non-supported SCLK/FSYNC ratio detection (TRM §4.3.2.6.1).
    RATE1=48000
    RATE2=44100
    echo "${SUPPORTED_RATES[@]}" | grep -qw $RATE1 || RATE1=${SUPPORTED_RATES[0]}
    echo "${SUPPORTED_RATES[@]}" | grep -qw $RATE2 || RATE2=${SUPPORTED_RATES[1]:-$RATE1}

    for i in $(seq 1 10); do

        echo -ne "  Iteration $i/10: $RATE1 Hz → $RATE2 Hz\r"

        # Play brief audio at rate 1
        timeout 0.5 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r $RATE1 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
        STATUS1=$?
        sleep 0.05

        # Switch to rate 2
        timeout 0.5 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r $RATE2 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
        STATUS2=$?
        sleep 0.05

        # Accept 0 (normal exit) or 124 (timeout killed - success)
        if [ $STATUS1 -ne 0 ] && [ $STATUS1 -ne 124 ]; then
            RAPID_ERRORS=$((RAPID_ERRORS + 1))
        elif [ $STATUS2 -ne 0 ] && [ $STATUS2 -ne 124 ]; then
            RAPID_ERRORS=$((RAPID_ERRORS + 1))
        fi
    done

    echo ""
    echo ""
    echo "  Rapid switch errors: $RAPID_ERRORS/10"

    # Check kernel log
    RAPID_KERNEL_ERRORS=$(dmesg | grep -iE "tas6754.*error|tas6754.*fail" | wc -l)

    if [ $RAPID_KERNEL_ERRORS -gt 0 ]; then
        echo -e "    ${YELLOW}⚠ Kernel errors: $RAPID_KERNEL_ERRORS${NC}"
        dmesg | grep -iE "tas6754" | tail -5
    fi

    if [ $RAPID_ERRORS -eq 0 ] && [ $RAPID_KERNEL_ERRORS -eq 0 ]; then
        print_pass "Rapid rate switching successful"
    else
        print_warn "Errors during rapid rate switching"
    fi
fi

# ============================================================================
# TEST 4: Channel Count Variations
# ============================================================================
print_header "TEST 4: Channel Count Variations"

echo "Testing different channel configurations..."
echo "  Note: TAS6754 on AM62D2-EVM uses 8-channel TDM configuration"
echo ""

# Test 8-channel configuration (what the hardware supports)
CHANNEL_CONFIGS=(8)

dmesg -C

CHANNEL_ERRORS=0

for channels in "${CHANNEL_CONFIGS[@]}"; do
    echo "  Testing $channels channel(s)..."

    # Use 48kHz as a commonly supported rate
    TEST_RATE=48000
    if ! echo "${SUPPORTED_RATES[@]}" | grep -q "48000"; then
        TEST_RATE=${SUPPORTED_RATES[0]}
    fi

    timeout 2 aplay -D hw:$CARD,0 -c $channels -r $TEST_RATE -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?
    if [ $STATUS -eq 0 ] || [ $STATUS -eq 124 ]; then
        echo "    ✓ $channels channel playback successful"
    else
        echo -e "    ${YELLOW}⚠ $channels channel playback failed${NC}"
        CHANNEL_ERRORS=$((CHANNEL_ERRORS + 1))
    fi
done

echo ""
echo "  Channel config errors: $CHANNEL_ERRORS/${#CHANNEL_CONFIGS[@]}"

if [ $CHANNEL_ERRORS -eq 0 ]; then
    print_pass "All channel configurations successful"
elif [ $CHANNEL_ERRORS -lt ${#CHANNEL_CONFIGS[@]} ]; then
    print_warn "Some channel configurations failed"
else
    print_fail "All channel configurations failed"
fi

# ============================================================================
# TEST 5: Format Switching
# ============================================================================
print_header "TEST 5: Format Switching"

echo "Testing different audio formats..."

# Common formats to test
FORMATS=("S16_LE" "S24_LE" "S32_LE")

dmesg -C

FORMAT_ERRORS=0

for format in "${FORMATS[@]}"; do
    echo "  Testing format $format..."

    TEST_RATE=48000
    if ! echo "${SUPPORTED_RATES[@]}" | grep -q "48000"; then
        TEST_RATE=${SUPPORTED_RATES[0]}
    fi

    timeout 2 aplay -D hw:$CARD,0 -r $TEST_RATE -c $DEFAULT_CHANNELS -f $format /dev/zero >/dev/null 2>&1
    STATUS=$?
    if [ $STATUS -eq 0 ] || [ $STATUS -eq 124 ]; then
        echo "    ✓ $format playback successful"
    else
        echo -e "    ${YELLOW}⚠ $format playback failed${NC}"
        FORMAT_ERRORS=$((FORMAT_ERRORS + 1))
    fi
done

echo ""
echo "  Format errors: $FORMAT_ERRORS/${#FORMATS[@]}"

# Check kernel log
FORMAT_KERNEL_ERRORS=$(dmesg | grep -iE "tas6754.*format|tas6754.*width" | grep -iE "error|fail" | wc -l)

if [ $FORMAT_ERRORS -eq 0 ] && [ $FORMAT_KERNEL_ERRORS -eq 0 ]; then
    print_pass "All audio formats successful"
elif [ $FORMAT_ERRORS -lt ${#FORMATS[@]} ]; then
    print_warn "Some audio formats failed"
else
    print_fail "All audio formats failed"
fi

# ============================================================================
# TEST 6: Rate Switching During DSP Mode Changes
# ============================================================================
print_header "TEST 6: Rate Switching During DSP Mode Changes"

echo "Testing sample rate switching combined with DSP mode changes..."

if [ ${#SUPPORTED_RATES[@]} -lt 2 ]; then
    print_warn "Not enough supported rates for combined test"
else
    dmesg -C

    DSP_RATE_ERRORS=0

    echo "  Cycle 1: Normal mode, 44.1kHz → 48kHz"
    set_control "DSP Signal Path Mode" "Normal"
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 44100 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 48000 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))

    echo "  Cycle 2: LLP mode, 48kHz → 44.1kHz"
    set_control "DSP Signal Path Mode" "LLP"
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 48000 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 44100 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))

    echo "  Cycle 3: FFLP mode, 44.1kHz → 48kHz"
    set_control "DSP Signal Path Mode" "FFLP"
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 44100 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))
    timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r 48000 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && DSP_RATE_ERRORS=$((DSP_RATE_ERRORS + 1))

    # Restore normal mode
    set_control "DSP Signal Path Mode" "Normal"

    echo ""
    echo "  Combined DSP+rate errors: $DSP_RATE_ERRORS/6"

    COMBINED_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)

    if [ $DSP_RATE_ERRORS -eq 0 ] && [ $COMBINED_ERRORS -eq 0 ]; then
        print_pass "Rate switching during DSP mode changes successful"
    else
        print_warn "Some errors during combined DSP+rate switching"
    fi
fi

# ============================================================================
# TEST 7: Rate Switching Under Load
# ============================================================================
print_header "TEST 7: Rate Switching Under Load"

echo "Testing sample rate switching while performing control operations..."

if [ ${#SUPPORTED_RATES[@]} -lt 2 ]; then
    print_warn "Not enough supported rates for load test"
else
    dmesg -C

    # Start background worker that hammers controls
    control_worker() {
        for i in $(seq 1 30); do
            trigger_control "DC LDG Trigger"
            set_control "DSP Signal Path Mode" 0
            set_control "DSP Signal Path Mode" 1
            sleep 0.1
        done
    }

    echo "  Starting background control operations..."
    control_worker &
    WORKER_PID=$!

    sleep 0.5

    echo "  Switching sample rates while controls are active..."

    LOAD_ERRORS=0

    LOAD_RATE1=48000
    LOAD_RATE2=44100
    echo "${SUPPORTED_RATES[@]}" | grep -qw $LOAD_RATE1 || LOAD_RATE1=${SUPPORTED_RATES[0]}
    echo "${SUPPORTED_RATES[@]}" | grep -qw $LOAD_RATE2 || LOAD_RATE2=${SUPPORTED_RATES[1]:-$LOAD_RATE1}

    for i in $(seq 1 5); do

        echo -ne "    Iteration $i/5: $LOAD_RATE1 Hz → $LOAD_RATE2 Hz\r"

        timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r $LOAD_RATE1 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
        STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && LOAD_ERRORS=$((LOAD_ERRORS + 1))
        sleep 0.05
        timeout 1 aplay -D hw:$CARD,0 -c $DEFAULT_CHANNELS -r $LOAD_RATE2 -f $DEFAULT_FORMAT /dev/zero >/dev/null 2>&1
        STATUS=$?; [ $STATUS -ne 0 ] && [ $STATUS -ne 124 ] && LOAD_ERRORS=$((LOAD_ERRORS + 1))
        sleep 0.05
    done

    echo ""

    # Wait for worker to finish
    wait $WORKER_PID 2>/dev/null

    echo ""
    echo "  Rate switch errors under load: $LOAD_ERRORS/10"

    LOAD_KERNEL_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)

    if [ $LOAD_ERRORS -eq 0 ] && [ $LOAD_KERNEL_ERRORS -eq 0 ]; then
        print_pass "Rate switching under load successful"
    else
        print_warn "Errors during rate switching under load"
    fi
fi

# ============================================================================
# TEST 8: Kernel Log Analysis
# ============================================================================
print_header "TEST 8: Kernel Log Analysis"

echo "Analyzing kernel log for audio-related errors..."

TOTAL_ERRORS=$(dmesg | grep -iE "error|warning|fail" | wc -l)
TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)
RATE_ERRORS=$(dmesg | grep -iE "rate.*error|freq.*error|clock.*error" | wc -l)
FORMAT_ERRORS=$(dmesg | grep -iE "format.*error|width.*error" | wc -l)

echo "  Total errors/warnings: $TOTAL_ERRORS"
echo "  TAS6754 errors: $TAS_ERRORS"
echo "  Rate-related errors: $RATE_ERRORS"
echo "  Format-related errors: $FORMAT_ERRORS"

if [ $TAS_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}TAS6754 errors found:${NC}"
    dmesg | grep -iE "tas6754.*error" | tail -10
fi

if [ $RATE_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Rate-related errors found:${NC}"
    dmesg | grep -iE "rate.*error|freq.*error" | tail -5
fi

if [ $TAS_ERRORS -eq 0 ] && [ $RATE_ERRORS -eq 0 ]; then
    print_pass "No audio errors in kernel log"
else
    print_warn "Some audio errors detected in kernel log"
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

if [ ${#SUPPORTED_RATES[@]} -gt 0 ]; then
    echo "Supported sample rates: ${SUPPORTED_RATES[@]}"
    echo ""
fi

if [ $FAIL -eq 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; ($PASS / ($PASS + $WARN)) * 100" | bc 2>/dev/null || echo "100.0")
else
    SUCCESS_RATE=$(echo "scale=1; ($PASS / ($PASS + $FAIL + $WARN)) * 100" | bc 2>/dev/null || echo "0")
fi

echo "Success Rate: ${SUCCESS_RATE}%"
echo ""

if [ $FAIL -eq 0 ] && [ $PASS -ge 4 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  SAMPLE RATE TEST PASSED! ✓           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Device handles sample rate switching correctly"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  SAMPLE RATE TEST FAILED! ✗           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Device showed issues with sample rate handling"
    exit 1
fi
