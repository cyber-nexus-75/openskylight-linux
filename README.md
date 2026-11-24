# OpenSkyLight Linux Kiosk

One-script bring-up for running [OpenSkyLight](https://github.com/lowerygt/OpenSkyLight) (or your fork of it) as a wall kiosk on a Microsoft Surface device under Linux.

Targets: Debian 12 (bookworm) and Ubuntu 22.04/24.04, amd64, X11. Surface hardware requires the [linux-surface](https://github.com/linux-surface/linux-surface) kernel; stock distro kernels do not drive the touchscreen.

## What it does

1. Adds the linux-surface apt repository and installs `linux-image-surface`, `linux-headers-surface`, `libwacom-surface`, and `iptsd`. Touch and pen work after the next reboot; kernel updates arrive through apt like any other package.
2. If Secure Boot is enabled, installs `linux-surface-secureboot-mok`, which auto-enrolls the linux-surface signing key. One interactive step at the next reboot: MOK Manager asks for a one-time password, which is `surface`. Secure Boot stays on.
3. Either downloads the OpenSkyLight AppImage to `/opt/openskylight` (`--appimage`), or installs Chromium (`--kiosk-url`) to display a server-hosted OpenSkyLight web app.
4. Creates a `kiosk` user (if missing), writes an XDG autostart entry, and configures LightDM autologin into an X11 session. The machine boots straight into the display.

## Usage

Run the app locally from an AppImage:

```bash
sudo ./setup-linux.sh --appimage https://github.com/<you>/<fork>/releases/download/vX.Y.Z/OpenSkyLight-x.y.z.AppImage
```

Or connect the device to a server-hosted web app (run `npm run start:server` on the server first — see the [Server mode](https://github.com/cyber-nexus-75/OpenSkyLight#server-mode-host-on-a-server-open-from-any-device) section of the OpenSkyLight README):

```bash
sudo ./setup-linux.sh --kiosk-url http://192.168.1.10:8080/
```

If the server sets `OSL_SERVER_TOKEN`, point at its login URL instead — it sets the session cookie and redirects to the app:

```bash
sudo ./setup-linux.sh --kiosk-url 'http://192.168.1.10:8080/api/login?t=<OSL_SERVER_TOKEN>'
```

Options (exactly one of `--appimage` / `--kiosk-url` is required):

- `--kiosk-user <name>` — autologin account (default `kiosk`, created if missing)
- `--skip-mok` — do not enroll the Secure Boot key (Secure Boot must then be off)
- `--skip-autologin` — install kernel and payload only, no kiosk session
- `-h` — help

Run it once on a fresh install, reboot, and the kiosk is live.

## Status

Syntax-checked with `bash -n`. Not yet executed on hardware. First validation target: Surface Pro 5, Debian 12, X11, Secure Boot on. Treat the first run on real hardware as the test run.

## Roadmap

- Auto-resolve the latest AppImage URL from the fork's GitHub Releases API, making `--appimage` optional
- CI: shellcheck and `bash -n` on push
- Preseed file for repeatable fleet installs
- systemd session hardening for the Electron process (memory/CPU limits)

## References

- [linux-surface Installation and Setup](https://github.com/linux-surface/linux-surface/wiki/Installation-and-Setup)
- [secureboot-mok](https://github.com/linux-surface/secureboot-mok)
