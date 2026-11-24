#!/usr/bin/env bash
# OpenSkyLight Linux kiosk bring-up for Microsoft Surface devices.
#
# Installs the linux-surface kernel + iptsd (touch support), optionally
# enrolls the linux-surface Secure Boot signing key, then either installs
# the OpenSkyLight AppImage or points a browser kiosk at a server-hosted
# OpenSkyLight web app (--kiosk-url), and configures LightDM autologin +
# XDG autostart for the kiosk user.
#
# Targets: Debian 12 (bookworm) and Ubuntu 22.04/24.04, amd64, X11.
# Usage:
#   sudo ./setup-linux.sh --appimage <https-url> [options]
#   sudo ./setup-linux.sh --kiosk-url <http-url> [options]

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APT_KEYRING_DIR="/etc/apt/keyrings"
SURFACE_KEY_URL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc"
SURFACE_APT_LIST="/etc/apt/sources.list.d/linux-surface.list"
SURFACE_APT_LINE="deb [arch=amd64 signed-by=/etc/apt/keyrings/linux-surface.gpg] https://pkg.surfacelinux.com/debian release main"
SURFACE_PACKAGES=(linux-image-surface linux-headers-surface libwacom-surface iptsd)
MOK_PACKAGE="linux-surface-secureboot-mok"
# One-time MOK enrollment password: generated fresh per run. Never hardcode it.
MOK_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
INSTALL_DIR="/opt/openskylight"
DEFAULT_KIOSK_USER="kiosk"
APPIMAGE_URL=""
KIOSK_URL=""
CHROMIUM_BIN=""
KIOSK_USER="$DEFAULT_KIOSK_USER"
WITH_MOK=1
WITH_AUTOLOGIN=1

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }

die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./setup-linux.sh (--appimage <url> | --kiosk-url <url>) [options]

Required (exactly one):
  --appimage <url>      https URL of the OpenSkyLight .AppImage (GitHub Releases asset) — run the app locally
  --kiosk-url <url>     http(s) URL of a server-hosted OpenSkyLight web app (npm run start:server on the server) — the device opens it in a browser kiosk

Options:
  --kiosk-user <name>   Account for autologin and autostart (default: kiosk, created if missing)
  --skip-mok            Do not enroll the linux-surface Secure Boot key
  --skip-autologin      Do not configure LightDM autologin or the autostart entry
  -h, --help            Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --appimage)
        [ $# -ge 2 ] || die "--appimage needs a URL"
        APPIMAGE_URL="$2"
        shift 2
        ;;
      --kiosk-url)
        [ $# -ge 2 ] || die "--kiosk-url needs a URL"
        KIOSK_URL="$2"
        shift 2
        ;;
      --kiosk-user)
        [ $# -ge 2 ] || die "--kiosk-user needs a name"
        KIOSK_USER="$2"
        shift 2
        ;;
      --skip-mok)
        WITH_MOK=0
        shift
        ;;
      --skip-autologin)
        WITH_AUTOLOGIN=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
  done
  if [ -n "$APPIMAGE_URL" ] && [ -n "$KIOSK_URL" ]; then
    usage >&2
    die "pass only one of --appimage or --kiosk-url"
  fi
  if [ -n "$APPIMAGE_URL" ]; then
    case "$APPIMAGE_URL" in
      https://*.AppImage) : ;;
      *) die "--appimage must be an https URL ending in .AppImage" ;;
    esac
  elif [ -n "$KIOSK_URL" ]; then
    case "$KIOSK_URL" in
      http://*|https://*) : ;;
      *) die "--kiosk-url must be an http(s) URL" ;;
    esac
  else
    usage >&2
    die "one of --appimage or --kiosk-url is required"
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
}

detect_distro() {
  [ -r /etc/os-release ] || die "/etc/os-release missing; unsupported system"
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "unsupported distro: ${ID:-unknown}; use Debian 12+ or Ubuntu 22.04/24.04+" ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
  log "Detected ${PRETTY_NAME:-$ID}"
}

add_surface_repo() {
  log "Adding the linux-surface apt repository"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg
  mkdir -p "$APT_KEYRING_DIR"
  chmod 755 "$APT_KEYRING_DIR"
  curl -fsSL "$SURFACE_KEY_URL" | gpg --dearmor > "$APT_KEYRING_DIR/linux-surface.gpg"
  chmod 644 "$APT_KEYRING_DIR/linux-surface.gpg"
  printf '%s\n' "$SURFACE_APT_LINE" > "$SURFACE_APT_LIST"
  apt-get update -qq
}

install_surface_kernel() {
  log "Installing linux-surface kernel and iptsd"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${SURFACE_PACKAGES[@]}"
  log "Kernel installed; it becomes active at the next reboot"
}

enroll_mok() {
  if [ "$WITH_MOK" -eq 0 ]; then
    log "Skipping Secure Boot key enrollment (--skip-mok)"
    return
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mokutil
  if [ "$(mokutil --sb-state 2>/dev/null || true)" = "SecureBoot enabled" ]; then
    log "Secure Boot is enabled; enrolling the linux-surface signing key"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$MOK_PACKAGE"
    log "IMPORTANT: at the next reboot, MOK Manager asks for a one-time password: $MOK_PASSWORD"
  else
    log "Secure Boot is disabled; skipping MOK enrollment"
  fi
}

install_appimage() {
  log "Installing AppImage to $INSTALL_DIR"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libfuse2; then
    # Ubuntu 24.04 renamed the FUSE 2 runtime.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libfuse2t64 \
      || log "warning: FUSE 2 runtime not found; the AppImage may fail to launch"
  fi
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$APPIMAGE_URL" -o "$INSTALL_DIR/openskylight.AppImage"
  chmod 755 "$INSTALL_DIR/openskylight.AppImage"
}

# Server mode: the app runs on another machine (npm run start:server there);
# this device just boots into a fullscreen browser pointed at it.
install_browser_kiosk() {
  log "Installing Chromium for the web kiosk ($KIOSK_URL)"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium; then
    # Ubuntu ships chromium as a snap via the chromium-browser package.
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium-browser \
      || die "could not install chromium (or chromium-browser)"
  fi
  CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser)"
  [ -n "$CHROMIUM_BIN" ] || die "chromium binary not found after install"
  log "Chromium at $CHROMIUM_BIN"
}

configure_kiosk() {
  if [ "$WITH_AUTOLOGIN" -eq 0 ]; then
    log "Skipping autologin and autostart (--skip-autologin)"
    return
  fi

  if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    log "Creating kiosk user '$KIOSK_USER'"
    useradd -m -s /bin/bash "$KIOSK_USER"
    usermod -aG video,audio,input "$KIOSK_USER" || log "warning: could not add all auxiliary groups"
  fi

  log "Configuring XDG autostart for '$KIOSK_USER'"
  local autostart_dir="/home/$KIOSK_USER/.config/autostart"
  local exec_line
  if [ -n "$KIOSK_URL" ]; then
    # If the server has OSL_SERVER_TOKEN set, point at the login URL once:
    # it sets the session cookie and redirects to the app.
    exec_line="$CHROMIUM_BIN --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --touch-events=enabled --autoplay-policy=no-user-gesture-required $KIOSK_URL"
  else
    exec_line="$INSTALL_DIR/openskylight.AppImage --kiosk"
  fi
  mkdir -p "$autostart_dir"
  cat > "$autostart_dir/openskylight.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OpenSkyLight Kiosk
Exec=$exec_line
EOF
  chown -R "$KIOSK_USER":"$(id -gn "$KIOSK_USER")" "/home/$KIOSK_USER/.config"

  log "Configuring LightDM autologin"
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/70-openskylight-kiosk.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
autologin-session=xubuntu
EOF
  groupadd -f autologin
  usermod -aG autologin "$KIOSK_USER" || log "warning: could not add '$KIOSK_USER' to the autologin group"
}

main() {
  parse_args "$@"
  require_root
  detect_distro
  add_surface_repo
  install_surface_kernel
  enroll_mok
  if [ -n "$KIOSK_URL" ]; then
    install_browser_kiosk
  else
    install_appimage
  fi
  configure_kiosk
  log "Done. Reboot to activate the surface kernel and start the kiosk."
}

main "$@"
