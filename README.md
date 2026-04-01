# TAS6754 Linux Driver

This repo contains the Linux driver for the **TI TAS6754-Q1** — a quad-channel Class-D audio amplifier with onboard DSP and load diagnostics. The patches are based on linux-next and are being prepared for upstream submission.

> **Branch:** `main` — 5 patches on top of `next-20260320`

---

## What's included

- **DT binding** — device tree schema for `ti,tas6754`
- **ASoC codec driver** — full driver with 3 DAI endpoints, DAPM, volume controls, load diagnostics, fault monitoring, and suspend/resume support
- **McASP update** — audio-graph-card2 DPCM topology support in `davinci-mcasp`
- **DTS overlay** — example overlay for the AM62D2-EVM with TAS67CD-AEC daughter card
- **Documentation** — mixer controls reference with usage examples

The patch files are in the [`patches/`](patches/) directory.

---

## Getting started

You'll need linux-next at `next-20260320` as the base:

```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git
cd linux-next
git checkout next-20260320
```

Clone this repo and apply the patches:

```bash
git clone https://github.com/SenWang125/tas67-linux.git
cd linux-next
git am ../tas67-linux/patches/*.patch
```

Build for ARM64:

```bash
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make defconfig
make Image dtbs modules -j$(nproc)
```

---

## Hardware setup

Validated on the **AM62D-EVM** with a TAS67CD-AEC daughter card. The device tree overlay (`k3-am62d-evm-tas67cd-aec.dtso`) sets up a full audio-graph-card2 DPCM topology on McASP2.

---

## Test scripts

The [`test_scripts/`](test_scripts/) directory contains a test suite for validating the driver on target hardware. Run on the board after loading the driver.

| Script | Description |
|--------|-------------|
| `run_ldg_tests.sh` | DC / AC / real-time load diagnostics |
| `run_dsp_tests.sh` | DSP signal path modes and protection |
| `test_dsp_lock.sh` | Concurrent DSP access (mutex) |
| `test_playback_capture.sh` | Playback / capture, rates, RTLDG verify |
| `test_tas67cd_aec.sh` | Real audio playback + feedback capture (needs sample_audio.wav) |
| `test_channel_control.sh` | Per-channel auto-mute, RTLDG, volume |
| `test_volume_control.sh` | Volume ranges and persistence |
| `test_fault_injection.sh` | Error handling and recovery |
| `test_integration_stress.sh` | Multi-operation sustained stress |
| `test_power_management.sh` | Suspend / resume (requires sudo) |
| `test_sample_rate.sh` | Sample rate switching |
| `test_multi_codec.sh` | 4× codec concurrent (AM62D2-EVM) |
