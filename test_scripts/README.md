# TAS675x Test Scripts

Test suite for the TAS675x audio amplifier driver, validated on AM62D-EVM
with TAS67CD-AEC daughter card.

---

## Quick Start

```bash
# Unit tests (driver controls, no audio path required)
./run_ldg_tests.sh
./run_dsp_tests.sh
./test_dsp_lock.sh
./test_channel_control.sh
./test_volume_control.sh
./test_sample_rate.sh
./test_fault_injection.sh
./test_integration_stress.sh
./test_power_management.sh   # requires sudo

# Functional tests (TAS67CD-AEC board with active audio path)
./test_playback_capture.sh
./test_tas67cd_aec.sh        # requires sample_audio.wav
./test_multi_codec.sh
```

---

## Unit Tests

Driver-level tests that exercise ALSA controls and driver behaviour
without requiring an active audio signal.

### `run_ldg_tests.sh` — [test log](https://gist.github.com/SenWang125/f0aba22bb6b2cadd61f1eb857ccd0d15)
- Control Availability Check
- DC Load Diagnostics (DC LDG)
- DC Resistance Measurement (DCR)
- AC Load Diagnostics (AC LDG)
- Tweeter Detection Report
- Real-Time Load Diagnostics (RTLDG)
- Error Handling - LDG During Playback
- RTLDG Threshold Configuration
- Runtime PM Integration
- Kernel Log Analysis

### `run_dsp_tests.sh` — [test log](https://gist.github.com/SenWang125/3b64d46eea09812a5d091a4b03a6a0b9)
- DSP Control Availability Check
- DSP Signal Path Mode
- DSP Protection Switches
- DSP Memory Access (RTLDG Thresholds)
- DSP Mode Persistence During Operations
- DSP Feature Availability by Mode
- DSP Controls During Playback
- DSP Memory Book Switching Integrity
- DSP Control Write/Read Consistency
- Spread Spectrum Controls
- Protection Controls (OTSD Auto Recovery and OTW)
- Kernel Log Analysis

### `test_dsp_lock.sh` — [test log](https://gist.github.com/SenWang125/d2e63d2d7d1c567bcec451b836767b3e)
- Concurrent DSP memory access (io_lock mutex safety)

### `test_channel_control.sh` — [test log](https://gist.github.com/SenWang125/8d0634b80ab65ffeb0cc5e6d6aa9e455)
- Channel Auto Mute Control
- Channel RTLDG Switches
- Channel Digital Volume Controls
- Channel Independence Test
- Rapid Toggle Stress Test
- Auto Mute Combine Switch
- Auto Mute Time Configuration
- ISENSE Calibration Switch
- Kernel Log Analysis

### `test_volume_control.sh` — [test log](https://gist.github.com/SenWang125/d72ae684a9758a512ca2e1675d3a2e6e)
- Volume Control Availability
- Volume Range Test
- Auto Mute Controls
- Volume Persistence Test
- Per-Channel Volume Independence
- Volume Ramp Settings
- Volume Combine Controls
- Analog Volume Settings
- Auto Mute Combine and Time Configuration
- Volume Stress Test
- Kernel Log Analysis

### `test_sample_rate.sh` — [test log](https://gist.github.com/SenWang125/c6177c8f6d31898132565d57d60f41ca)
- Supported Sample Rate Detection
- Sequential Sample Rate Switching
- Rapid Sample Rate Switching
- Channel Count Variations
- Format Switching
- Rate Switching During DSP Mode Changes
- Rate Switching Under Load
- Kernel Log Analysis

### `test_fault_injection.sh` — [test log](https://gist.github.com/SenWang125/57bc42b897333c4c22859536bc7f0d34)
- Invalid Control Value Rejection
- Rapid Control Toggle Stress
- Conflicting Operation Sequence
- Recovery from Failed Operations
- Control Accessibility During Faults
- Error State Recovery
- Kernel Log Error Analysis

### `test_integration_stress.sh`
- Multi-operation sustained load

### `test_power_management.sh`
- Suspend / resume (requires sudo)

---

## Functional Tests

End-to-end tests that require the TAS67CD-AEC daughter card with an active
audio path on the AM62D-EVM.

### `test_playback_capture.sh` — [test log](https://gist.github.com/SenWang125/47df59ac0aa590a55a2698da91a8c02e)
- PCM Devices
- Playback Sample Rates
- RTLDG Auto-disable at 192kHz
- Audio Output Verification
- Feedback Capture
- Simultaneous Playback + Capture
- Rate Conflict Rejection
- Kernel Log

### `test_tas67cd_aec.sh` — [test log](https://gist.github.com/SenWang125/7d6a3468f8859473926e4edf7b7536c1)
Requires `sample_audio.wav`
- Simultaneous Playback + Capture
- RTLDG Impedance (real audio signal)
- Underrun/Overrun Check
- Feedback Data Integrity
- Kernel Log

### `test_multi_codec.sh` — [test log](https://gist.github.com/SenWang125/98af8cb7d27c71a3feaf54bdb0ffe7b3)
- Codec Detection
- Concurrent DC LDG on All Codecs
- Concurrent Channel Control
- Concurrent Volume Changes
- Concurrent Control Read Stress
- Cross-Codec Independence
- I2C Bus Stress Test

---

## Notes

- All scripts auto-detect available controls
- Tests gracefully skip unsupported features
- Exit code 0 = pass, 1 = fail
- Kernel log (dmesg) monitored for errors
- Background processes auto-cleaned on exit
