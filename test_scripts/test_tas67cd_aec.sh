#!/bin/bash
# TAS67CD-AEC Full Audio Path Test (AM62D2-EVM)
#
# Uses sample_audio.wav (8ch 48kHz) for real playback through the TAS6754
# amplifiers while simultaneously recording the VPREDICT/ISENSE feedback
# from both chips via the McASP1 capture path.
#
# Specific to the TAS67CD-AEC daughter card on AEC1 connector.
# Requires sample_audio.wav in the same directory as this script.

CARD="0"
PREFIX="TAS0"
PLAY_DEV="hw:$CARD,0"
CAP_DEV="hw:$CARD,1"
CHANNELS=8
FORMAT="S32_LE"      # playback: hw:0,0 requires S32_LE
CAP_FORMAT="S16_LE"  # capture:  hw:0,1 only supports S16_LE
RATE=48000
SCRIPT_DIR="$(dirname "$0")"
SAMPLE_WAV="$SCRIPT_DIR/sample_audio.wav"
CAP_OUT="/tmp/tas_feedback_cap.wav"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  TAS67CD-AEC Full Path Test           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Playback:  $PLAY_DEV  ($CHANNELS-ch $RATE Hz $FORMAT)"
echo "Capture:   $CAP_DEV   ($CHANNELS-ch $RATE Hz $CAP_FORMAT - VPREDICT + ISENSE)"
echo "Source:    $SAMPLE_WAV"
echo ""

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASS=$((PASS + 1)); }
print_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
print_warn() { echo -e "${YELLOW}⚠ WARN${NC}: $1"; WARN=$((WARN + 1)); }

get_control() {
    amixer -c $CARD cget name="$PREFIX $1" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}'
}

# Save ALSA mixer state; restore automatically on exit (normal or error)
ALSA_STATE=$(mktemp /tmp/alsa-test-XXXXXX.state)
cleanup() {
    alsactl restore -f "$ALSA_STATE" 2>/dev/null
    rm -f "$ALSA_STATE"
}
trap cleanup EXIT
alsactl store -f "$ALSA_STATE" 2>/dev/null


set_control() {
    amixer -c $CARD cset name="$PREFIX $1" "$2" >/dev/null 2>&1
}

cleanup() {
    kill $PLAY_PID $REC_PID 2>/dev/null
    wait $PLAY_PID $REC_PID 2>/dev/null
    rm -f $CAP_OUT /tmp/arecord_err.log
    for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 0; done
    set_control "Audio SDOUT Switch" $SDOUT_ORIG 2>/dev/null
}
trap cleanup EXIT

# ============================================================================
# Pre-flight check
# ============================================================================
print_header "Pre-flight"

if [ ! -f "$SAMPLE_WAV" ]; then
    print_fail "sample_audio.wav not found at $SAMPLE_WAV"
    echo "  Copy the 8ch 48kHz WAV to the same directory as this script"
    exit 1
fi

echo "  $(file "$SAMPLE_WAV" | sed 's/.*WAVE audio, //')"
print_pass "sample_audio.wav found"

SDOUT_ORIG=$(get_control "Audio SDOUT Switch")
set_control "Audio SDOUT Switch" 1

# ============================================================================
# TEST 1: Playback + capture open simultaneously
# ============================================================================
print_header "TEST 1: Simultaneous Playback + Capture"

dmesg -C

# Playback must start first. Feedback ADC DAPM path requires SPEAKER_LOAD
# to be connected, which chains back through the active playback output.
# Without playback active, DAPM won't enable SDOUT Vpredict/Isense.
echo "Starting playback of sample_audio.wav..."
# Force S32_LE on hw:0,0 directly — overrides WAV header format.
# plughw causes resource conflicts preventing hw:0,1 capture from opening.
(while true; do aplay -D "hw:$CARD,0" -r $RATE -c $CHANNELS -f $FORMAT "$SAMPLE_WAV" 2>/dev/null; done) &
PLAY_PID=$!
sleep 1  # wait for TAS6754 to reach PLAY state and DAPM to settle

echo "Starting capture on $CAP_DEV..."
arecord -D $CAP_DEV -r $RATE -c $CHANNELS -f $CAP_FORMAT -d 5 $CAP_OUT \
    >/dev/null 2>/tmp/arecord_err.log &
REC_PID=$!

sleep 1

# Check both are still running
PB_OK=0
REC_OK=0
kill -0 $PLAY_PID 2>/dev/null && PB_OK=1
kill -0 $REC_PID 2>/dev/null && REC_OK=1

if [ $PB_OK -eq 1 ] && [ $REC_OK -eq 1 ]; then
    print_pass "Playback and capture running simultaneously"
elif [ $PB_OK -eq 0 ]; then
    print_fail "Playback died"
elif [ $REC_OK -eq 0 ]; then
    print_fail "Capture died"
    [ -s /tmp/arecord_err.log ] && sed 's/^/  /' /tmp/arecord_err.log | head -3
fi

# ============================================================================
# TEST 2: RTLDG impedance with real audio
# ============================================================================
print_header "TEST 2: RTLDG Impedance (real audio signal)"

echo "Enabling RTLDG..."
for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 1; done

# Give RTLDG a moment to settle
sleep 1

ACTIVE=0
for ch in 1 2 3 4; do
    IMP=$(get_control "CH${ch} RTLDG Impedance")
    if [ "$IMP" -gt 0 ] 2>/dev/null; then
        echo "  CH${ch}: $IMP"
        ACTIVE=$((ACTIVE + 1))
    else
        echo "  CH${ch}: 0"
    fi
done

if [ $ACTIVE -ge 2 ]; then
    print_pass "$ACTIVE channel(s) show impedance with real audio"
else
    print_warn "Only $ACTIVE channel(s) active (CH3/CH4 depend on TDM slot assignment)"
fi

for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 0; done

# ============================================================================
# TEST 3: XRUN check mid-playback
# ============================================================================
print_header "TEST 3: Underrun/Overrun Check"

sleep 1

XRUNS=$(dmesg | grep -iE "xrun|underrun|overrun" | wc -l)
echo "  XRUNs so far: $XRUNS"

if [ $XRUNS -eq 0 ]; then
    print_pass "No XRUNs during simultaneous playback+capture"
else
    print_fail "$XRUNS XRUN(s) detected"
    dmesg | grep -iE "xrun|underrun|overrun"
fi

# ============================================================================
# TEST 4: Capture data contains non-zero feedback
# ============================================================================
print_header "TEST 4: Feedback Data Integrity"

# Wait for capture to complete (fixed -d 5 duration), then kill looped playback
wait $REC_PID 2>/dev/null
kill $PLAY_PID 2>/dev/null
wait $PLAY_PID 2>/dev/null

if [ ! -f "$CAP_OUT" ] || [ ! -s "$CAP_OUT" ]; then
    print_fail "Capture file missing or empty"
else
    CAP_BYTES=$(stat -c%s "$CAP_OUT" 2>/dev/null)
    EXPECTED=$((RATE * CHANNELS * 2 * 5))
    echo "  Capture file: $CAP_BYTES bytes (expected ~$EXPECTED)"
    echo ""

    # Per-channel analysis (S16_LE, 8 channels interleaved)
    # Slot layout from DTS: ti,vpredict-slot-no=0, ti,isense-slot-no=4
    #   ch0-3 = Vpredict CH1-4 (reconstructed speaker voltage)
    #   ch4-7 = Isense CH1-4  (measured speaker current)
    python3 -c "
import struct, sys, math

with open('$CAP_OUT', 'rb') as f:
    f.read(44)  # skip WAV header
    data = f.read()

n_ch = 8
sample_size = 2  # S16_LE
n_frames = len(data) // (n_ch * sample_size)
window = min(n_frames, $RATE)  # analyse first second

labels = ['VP-CH1', 'VP-CH2', 'VP-CH3', 'VP-CH4',
          'IS-CH1', 'IS-CH2', 'IS-CH3', 'IS-CH4']

print('  Channel   Peak         RMS          Non-zero')
any_nonzero = False
for ch in range(n_ch):
    samps = [struct.unpack_from('<h', data, (fr * n_ch + ch) * 2)[0]
             for fr in range(window)]
    nonzero = sum(1 for s in samps if s != 0)
    peak = max(abs(s) for s in samps) if samps else 0
    rms = int(math.sqrt(sum(s*s for s in samps) / len(samps))) if samps else 0
    flag = '✓' if nonzero > 0 else '✗'
    print(f'  {flag} {labels[ch]:8s}  {peak:12d}   {rms:12d}   {nonzero}/{window}')
    if nonzero > 0:
        any_nonzero = True

sys.exit(0 if any_nonzero else 1)
" 2>/dev/null
    FB_OK=$?

    echo ""
    if [ $FB_OK -eq 0 ]; then
        print_pass "Feedback data non-zero (TAS6754 SDOUT active during playback)"
    else
        print_warn "All channels zero (TAS6754 not in PLAY state or SDOUT not enabled)"
    fi
fi

# ============================================================================
# TEST 5: Kernel log
# ============================================================================
print_header "TEST 5: Kernel Log"

TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | grep -v "ASoC error (-22)" | wc -l)
echo "  Errors: $TAS_ERRORS"

if [ $TAS_ERRORS -eq 0 ]; then
    print_pass "No errors"
else
    print_fail "$TAS_ERRORS error(s)"
    dmesg | grep -iE "tas6754.*error" | grep -v "ASoC error (-22)" | tail -5
fi

# ============================================================================
# Summary
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

TOTAL=$((PASS + FAIL))
if [ $TOTAL -gt 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; $PASS * 100 / $TOTAL" | bc)
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
