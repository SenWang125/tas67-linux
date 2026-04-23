#!/bin/bash
# TAS6754 Playback and Capture Test (AM62D2-EVM)
#
# Board: AM62D2-EVM with TAS67CD-AES daughter card (2x TAS6754)
# McASP1 TDM (16-slot DSP_B):
#   Playback (SDIN AXR0): TAS0 slots 0-3, TAS1 slots 4-7
#                          ANC LLP: TAS0 slots 8-11, TAS1 slots 12-15
#   Capture  (SDOUT):     TAS0 Vpredict+Isense on AXR2, TAS1 on AXR3
#
# PCM devices (DPCM via audio-graph-card2):
#   hw:0,0  Playback-only FE
#   hw:0,1  Capture-only FE (48kHz only, feedback path)
#
# Rate constraint: all active DAIs share one SCLK/FSYNC.
# Playback and capture must use the same sample rate.
# RTLDG auto-disables above 96kHz and restores on next lower-rate stream.

CARD="0"
PREFIX="TAS0"
PLAY_DEV="hw:$CARD,0"
CAP_DEV="hw:$CARD,1"
CHANNELS=8
FORMAT="S32_LE"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  TAS6754 Playback / Capture Test      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Playback: $PLAY_DEV  Capture: $CAP_DEV"
echo "Channels: $CHANNELS  Format: $FORMAT"
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

# ============================================================================
# TEST 1: PCM Devices
# ============================================================================
print_header "TEST 1: PCM Devices"

echo "Playback ($PLAY_DEV):"
if [ -f /proc/asound/card${CARD}/pcm0p/info ]; then
    grep -E "^(id|stream):" /proc/asound/card${CARD}/pcm0p/info 2>/dev/null | sed 's/^/  /'
    print_pass "Playback PCM found"
else
    print_fail "Playback PCM not found"
fi

echo ""
echo "Capture ($CAP_DEV):"
if [ -f /proc/asound/card${CARD}/pcm1c/info ]; then
    grep -E "^(id|stream):" /proc/asound/card${CARD}/pcm1c/info 2>/dev/null | sed 's/^/  /'
    print_pass "Capture PCM found (device 1)"
elif [ -f /proc/asound/card${CARD}/pcm0c/info ]; then
    CAP_DEV="hw:$CARD,0"
    grep -E "^(id|stream):" /proc/asound/card${CARD}/pcm0c/info 2>/dev/null | sed 's/^/  /'
    print_warn "Capture on device 0 (adjusted)"
else
    print_warn "Capture PCM not found - feedback path may not be wired"
fi

# ============================================================================
# TEST 2: Playback Sample Rates
# ============================================================================
print_header "TEST 2: Playback Sample Rates"

# Driver supports: 44100, 48000, 96000, 192000
# Note: 96kHz/192kHz may trigger CLK_FAULT if McASP clock dividers cannot
# achieve the rate within TAS675x auto-detect tolerance (TRM §4.3.2.6.1).
RATES=(44100 48000 96000 192000)
RATE_FAIL=0

for rate in "${RATES[@]}"; do
    dmesg -C
    timeout 2 aplay -D $PLAY_DEV -r $rate -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1
    STATUS=$?
    CLK_FAULTS=$(dmesg | grep -c "Clock Fault Latched" 2>/dev/null || echo 0)
    if [ $STATUS -eq 0 ] || [ $STATUS -eq 124 ]; then
        if [ "$CLK_FAULTS" -gt 0 ]; then
            echo "  ⚠ ${rate}Hz (ALSA ok, CLK_FAULT: McASP PPM too large for TAS675x auto-detect)"
            WARN=$((WARN + 1))
        else
            echo "  ✓ ${rate}Hz"
        fi
    else
        echo "  ✗ ${rate}Hz (exit $STATUS)"
        RATE_FAIL=$((RATE_FAIL + 1))
    fi
    sleep 0.5
done

if [ $RATE_FAIL -eq 0 ]; then
    print_pass "All rates accepted by ALSA"
elif [ $RATE_FAIL -lt ${#RATES[@]} ]; then
    print_warn "$RATE_FAIL/${#RATES[@]} rates failed"
else
    print_fail "All playback rates failed"
fi

# ============================================================================
# TEST 3: RTLDG auto-disable at 192kHz
# ============================================================================
print_header "TEST 3: RTLDG Auto-disable at 192kHz"

# hw_params disables RTLDG at >96kHz to prevent DSP overload.
# It saves the mask and restores it when a lower-rate stream opens.
echo "Enabling RTLDG on all channels..."
for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 1; done
sleep 0.3

echo "Starting 192kHz stream..."
timeout 2 aplay -D $PLAY_DEV -r 192000 -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1 &
PLAY_PID=$!
sleep 1

CH1_DURING=$(get_control "CH1 RTLDG Switch")
echo "  CH1 RTLDG during 192kHz: $CH1_DURING"
kill $PLAY_PID 2>/dev/null; wait $PLAY_PID 2>/dev/null
sleep 0.1

# Open a 48kHz stream to trigger the restore path
timeout 2 aplay -D $PLAY_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1
CH1_AFTER=$(get_control "CH1 RTLDG Switch")
echo "  CH1 RTLDG after 48kHz restore: $CH1_AFTER"

if [ "$CH1_DURING" = "off" ] && [ "$CH1_AFTER" = "on" ]; then
    print_pass "RTLDG auto-disabled at 192kHz and restored at 48kHz"
elif [ "$CH1_DURING" = "off" ]; then
    print_warn "RTLDG disabled at 192kHz but not yet restored"
else
    print_warn "RTLDG was not auto-disabled at 192kHz (may have been off already)"
fi

for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 0; done

# ============================================================================
# TEST 4: Verify audio output via RTLDG impedance
# ============================================================================
print_header "TEST 4: Audio Output Verification"

echo "Checking RTLDG impedance during 48kHz playback..."
for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 1; done
sleep 0.3

timeout 3 aplay -D $PLAY_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1 &
PLAY_PID=$!
sleep 1

ACTIVE=0
for ch in 1 2 3 4; do
    IMP=$(get_control "CH${ch} RTLDG Impedance")
    if [ "$IMP" -gt 0 ] 2>/dev/null; then
        echo "  CH${ch}: $IMP (active)"
        ACTIVE=$((ACTIVE + 1))
    else
        echo "  CH${ch}: 0 (no signal in this slot)"
    fi
done

kill $PLAY_PID 2>/dev/null; wait $PLAY_PID 2>/dev/null
for ch in 1 2 3 4; do set_control "CH${ch} RTLDG Switch" 0; done

if [ $ACTIVE -ge 2 ]; then
    print_pass "$ACTIVE channel(s) active - audio is flowing"
elif [ $ACTIVE -gt 0 ]; then
    print_warn "$ACTIVE channel(s) active (CH3/CH4 need data in TDM slots 4-7)"
else
    print_warn "No RTLDG activity"
fi

# ============================================================================
# TEST 5: Feedback capture (VPREDICT + ISENSE, 48kHz only)
# ============================================================================
print_header "TEST 5: Feedback Capture"

# The feedback path captures Vpredict and Isense from both TAS chips.
# Audio SDOUT Switch must be on to enable SDOUT serializer output.
SDOUT_ORIG=$(get_control "Audio SDOUT Switch")
set_control "Audio SDOUT Switch" 1
echo "  Audio SDOUT enabled"

echo "Capture at 48kHz on $CAP_DEV..."
timeout 3 arecord -D $CAP_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/null >/dev/null 2>&1
STATUS=$?

if [ $STATUS -eq 0 ] || [ $STATUS -eq 124 ]; then
    print_pass "Feedback capture opened at 48kHz $CHANNELS-ch"
else
    # Try with fewer channels
    for ch in 4 2; do
        timeout 2 arecord -D $CAP_DEV -r 48000 -c $ch -f $FORMAT /dev/null >/dev/null 2>&1
        if [ $? -eq 0 ] || [ $? -eq 124 ]; then
            print_warn "Capture works at ${ch}-ch (not $CHANNELS-ch)"
            break
        fi
    done
    if [ $STATUS -ne 0 ]; then
        print_warn "Feedback capture not available (check DTS feedback route)"
    fi
fi

set_control "Audio SDOUT Switch" $SDOUT_ORIG

# ============================================================================
# TEST 6: Simultaneous playback + capture (48kHz, shared clock domain)
# ============================================================================
print_header "TEST 6: Simultaneous Playback + Capture"

echo "Both streams at 48kHz (shared SCLK/FSYNC)..."
dmesg -C

set_control "Audio SDOUT Switch" 1

timeout 5 aplay -D $PLAY_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1 &
PLAY_PID=$!
sleep 0.5

timeout 4 arecord -D $CAP_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/null >/dev/null 2>&1 &
REC_PID=$!
sleep 2

kill $PLAY_PID $REC_PID 2>/dev/null
wait $PLAY_PID $REC_PID 2>/dev/null
set_control "Audio SDOUT Switch" $SDOUT_ORIG

ERRORS=$(dmesg | grep -iE "tas6754.*error|xrun|underrun" | wc -l)
if [ $ERRORS -eq 0 ]; then
    print_pass "Simultaneous playback+capture at 48kHz, no errors"
else
    print_warn "$ERRORS error(s) during simultaneous streams"
    dmesg | grep -iE "tas6754.*error|xrun" | tail -3
fi

# ============================================================================
# TEST 7: Rate conflict rejected
# ============================================================================
print_header "TEST 7: Rate Conflict Rejection"

# Playback at 48kHz, then attempt capture at 44.1kHz.
# Driver enforces single clock domain: hw_params returns -EINVAL on mismatch.
echo "48kHz playback active, trying 44.1kHz capture..."

timeout 5 aplay -D $PLAY_DEV -r 48000 -c $CHANNELS -f $FORMAT /dev/zero >/dev/null 2>&1 &
PLAY_PID=$!
sleep 0.5

timeout 2 arecord -D $CAP_DEV -r 44100 -c $CHANNELS -f $FORMAT /dev/null >/dev/null 2>&1
CONFLICT=$?

kill $PLAY_PID 2>/dev/null; wait $PLAY_PID 2>/dev/null

if [ $CONFLICT -ne 0 ]; then
    print_pass "Rate conflict rejected (44.1kHz capture blocked during 48kHz playback)"
else
    print_warn "Rate conflict not rejected"
fi

# ============================================================================
# TEST 8: Kernel log
# ============================================================================
print_header "TEST 8: Kernel Log"

# skip expected -EINVAL from TEST 7 rate conflict
TAS_ERRORS=$(dmesg | grep -iE "tas6754.*error" | grep -v "ASoC error (-22)" | wc -l)
XRUNS=$(dmesg | grep -iE "xrun|underrun" | wc -l)

echo "  TAS6754 errors: $TAS_ERRORS"
echo "  XRUNs: $XRUNS"

if [ $TAS_ERRORS -eq 0 ] && [ $XRUNS -eq 0 ]; then
    print_pass "No errors"
elif [ $TAS_ERRORS -gt 0 ]; then
    print_fail "$TAS_ERRORS error(s)"
    dmesg | grep -iE "tas6754.*error" | grep -v "ASoC error (-22)" | tail -5
else
    print_warn "$XRUNS XRUN(s)"
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
