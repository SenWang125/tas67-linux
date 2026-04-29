# TAS67524 Linux Driver

This repo contains the Linux driver for the **TI TAS67524-Q1** (TAS675x family) - a quad-channel Class-D audio amplifier with onboard DSP and load diagnostics. The patches are based on linux-next and are being prepared for upstream submission.

> **Branch:** `main` - 7 patches on top of `next-20260320`

---

## What's included

- **DT binding** (`ti,tas67524.yaml`) - device tree schema for TAS67524
- **ASoC codec driver** - full driver with 3 DAI endpoints, DAPM, volume controls, load diagnostics, fault monitoring, and suspend/resume support
- **McASP update** - audio-graph-card2 DPCM topology support in `davinci-mcasp` (experimental, for demonstration)
- **DTS overlays** - two overlays for the AM62D2-EVM with TAS67CD-AEC daughter card:
  - `k3-am62d-evm-tas67cd-aec.dtso` — audio-graph-card2 DPCM topology (main + LLP + I/V feedback capture)
  - `k3-am62d-evm-tas67cd-aec-simple.dtso` — simple-audio-card, main audio only (no LLP, no feedback)
- **Documentation** - mixer controls, fault monitoring reference with usage examples
- **MAINTAINERS** - entry for TAS67524 driver and bindings

The patch files are in the [`patches/`](patches/) directory.

---

## Getting started

### 1. Get linux-next base

```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git
cd linux-next
git checkout next-20260320
```

### 2. Apply patches

```bash
git clone https://github.com/SenWang125/tas67-linux.git
cd linux-next
git am ../tas67-linux/patches/*.patch
```

### 3. Enable driver and McASP in kernel config

```bash
scripts/config --module CONFIG_SND_SOC_TAS675X
scripts/config --module CONFIG_SND_SOC_DAVINCI_MCASP
```

### 4. Build

```bash
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make olddefconfig
make Image dtbs modules -j$(nproc)
```

### 5. Deploy to AM62D2-EVM

Copy the kernel image, modules, and DTB overlay to the board. Then configure U-Boot to load the overlay by editing `uEnv.txt` on the boot partition:

For the full DPCM topology (audio-graph-card2 with LLP and I/V feedback):
```
name_overlays=ti/k3-am62d-evm-tas67cd-aec.dtbo
```

For the simple-audio-card (main audio path only, easier bring-up):
```
name_overlays=ti/k3-am62d-evm-tas67cd-aec-simple.dtbo
```

Example on target:

```bash
# Mount boot partition if not already mounted
mount /dev/mmcblk1p1 /run/media/boot-mmcblk1p1

# Edit uEnv.txt
vi /run/media/boot-mmcblk1p1/uEnv.txt
# Add one of the name_overlays lines above

# Reboot
reboot
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
| `test_multi_codec.sh` | 4x codec concurrent (AM62D2-EVM) |

---

## Upstream status

The driver-only patches (binding, codec, docs, MAINTAINERS) are at **v6** on the linux-sound mailing list. The McASP DPCM and DTS overlay patches are not yet submitted upstream and are provided here for evaluation.

- [v6 on lore](https://lore.kernel.org/linux-sound/)
- GitHub: https://github.com/SenWang125/tas67-linux
