# TAS6754 Linux Driver

This repo contains a work-in-progress Linux driver for the **TI TAS6754-Q1** — a quad-channel Class-D audio amplifier with onboard DSP and load diagnostics. The patches are based on linux-next and are being prepared for upstream submission.

> **Branch:** `ldg_triggers` — 5 patches on top of `next-20260320`

---

## What's included

- **DT binding** — device tree schema for `ti,tas6754`
- **ASoC codec driver** — full driver with 3 DAI endpoints, DAPM, volume controls, load diagnostics, fault monitoring, and suspend/resume support
- **McASP update** — audio-graph-card2 DPCM topology support in `davinci-mcasp`
- **DTS overlay** — example overlay for the AM62D2-EVM with TAS67CD-AES daughter card
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

## Hardware tested

Validated on the **AM62D-EVM** with a TAS67CD-AEC daughter card. The device tree overlay (`k3-am62d-evm-tas67cd-aec.dtso`) sets up a full audio-graph-card2 DPCM topology with four channels on McASP2.

---

## About the TAS6754

The TAS6754-Q1 is a 4-channel digital-input Class-D amp designed for automotive and embedded audio. Highlights:

- I2S/TDM input, up to 48 kHz
- Integrated DSP with configurable signal path (Normal / LLP / FFLP)
- Per-channel DC and AC load diagnostics
- Hardware fault protection (OC, OTW, UVLO/OVLO)
- I2C control, single 4V–20V supply
