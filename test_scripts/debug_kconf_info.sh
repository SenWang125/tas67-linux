#!/bin/bash
# Debug script to dump kconf info

for pfx in TAS0 TAS1; do
    echo "=== $pfx ==="
    for ctrl in \
        "Analog Playback Volume" \
        "CH1 Digital Playback Volume" \
        "CH2 Digital Playback Volume" \
        "CH3 Digital Playback Volume" \
        "CH4 Digital Playback Volume" \
        "Analog Gain Ramp Step" \
        "Volume Ramp Up Rate" \
        "Volume Ramp Down Rate" \
        "Volume Ramp Up Step" \
        "Volume Ramp Down Step" \
        "CH1/2 Volume Combine" \
        "CH3/4 Volume Combine" \
        "CH1 Auto Mute Switch" \
        "CH2 Auto Mute Switch" \
        "CH3 Auto Mute Switch" \
        "CH4 Auto Mute Switch" \
        "Auto Mute Combine Switch" \
        "Audio Path Switch" \
        "ANC Path Switch" \
        "DSP Signal Path Mode" \
        "Thermal Foldback Switch" \
        "PVDD Foldback Switch" \
        "DC Blocker Bypass Switch" \
        "Audio SDOUT Switch"; do
        val=$(amixer -c 0 cget name="$pfx $ctrl" 2>/dev/null | grep ': values=' | awk -F'=' '{print $2}')
        printf "  %-40s %s\n" "$ctrl" "$val"
    done
    echo ""
done
