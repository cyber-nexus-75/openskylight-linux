# OpenSkyLight Linux Kiosk

One-script bring-up for running [OpenSkyLight](https://github.com/lowerygt/OpenSkyLight) (or your fork of it) as a wall kiosk on a Microsoft Surface device under Linux.

Targets: Debian 12 (bookworm) and Ubuntu 22.04/24.04, amd64, X11. Surface hardware requires the [linux-surface](https://github.com/linux-surface/linux-surface) kernel; stock distro kernels do not drive the touchscreen.

## What it does

1. Adds the linux-surface apt repository and installs `linux-image-surface`, `linux-headers-surface`, `libwacom-surface`, and `iptsd`. Touch and pen work after the next reboot; kernel updates arrive through apt like any other package.
2. If Secure Boot is enabled, installs `linux-surface-secureboot-mok`, which auto-enrolls the linux-surface signing key. One interactive step at the next reboot: MOK Manager asks for a one-time password, which is `surface`. Secure Boot stays on.
3. Resolves the latest OpenSkyLight `.AppImage` from the fork's GitHub Releases (or takes an explicit `--appimage` URL) and installs it to `/opt/openskylight`.
4. Creates a `kiosk` user (if missing), writes an XDG autostart entry, and configures LightDM autologin into an X11 session. The machine boots straight into the display.
5. Opens TCP 8420 in the firewall (ufw or firewalld) so the companion web app is reachable from phones on the LAN.

## Usage

```bash
sudo ./setup-linux.sh
```

By default this resolves the latest `.AppImage` asset from the `cyber-nexus-75/OpenSkyLight` fork's GitHub Releases. Alternatives:

```bash
sudo ./setup-linux.sh --appimage https://github.com/<you>/<fork>/releases/download/vX.Y.Z/OpenSkyLight-x.y.z.AppImage
sudo ./setup-linux.sh --appimage-repo <you>/<fork>
```

Options:

- `--appimage <url>` — explicit https URL of the `.AppImage` release asset
- `--appimage-repo <owner/repo>` — resolve the latest `.AppImage` from this repo's Releases
- `--kiosk-user <name>` — autologin account (default `kiosk`, created if missing)
- `--skip-mok` — do not enroll the Secure Boot key (Secure Boot must then be off)
- `--skip-autologin` — install kernel and AppImage only, no kiosk session
- `--skip-firewall` — do not open TCP 8420 for the companion web app
- `-h` — help

Run it once on a fresh install, reboot, and the kiosk is live.

## App features relevant on Linux (v0.6.0+)

- **Companion web app** (v0.6.0): phones on the LAN can edit lists, meals, and chores. The kiosk serves it on `0.0.0.0:8420` when enabled in the app's settings; this script opens that port in the firewall. Enable it in the app settings, then browse to `http://<kiosk-ip>:8420` from a phone.
- **Camera tile** (v0.5.0): live RTSP streams on the home screen. Requires network reachability to your camera streams; no extra system packages are needed.
- **BirdNET-Go Birds tile** (v0.7.0): recent bird detections with photos, auto-refreshing. The kiosk proxies photos from your BirdNET-Go host; configure that host in the app settings.
- **Timer tile** (v0.8.0): countdown timers with presets, persistence, and an alarm. No Linux-specific setup.
- **Auto-update**: the app checks GitHub Releases in the background and shows a "Restart now" pill on the display when an update is ready.

## Status

Syntax-checked with `bash -n`. Not yet executed on hardware. First validation target: Surface Pro 5, Debian 12, X11, Secure Boot on. Treat the first run on real hardware as the test run.

## Roadmap

- CI: shellcheck and `bash -n` on push
- Preseed file for repeatable fleet installs
- systemd session hardening for the Electron process (memory/CPU limits)

## References

- [linux-surface Installation and Setup](https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup)
- [secureboot-mok](https://github.com/linux-surface/secureboot-mok)
