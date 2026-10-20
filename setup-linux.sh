#!/usr/bin/env bash
# OpenSkyLight Linux kiosk bring-up for Microsoft Surface devices.
#
# Installs the linux-surface kernel + iptsd (touch support), optionally
# enrolls the linux-surface Secure Boot signing key, installs the
# OpenSkyLight AppImage, and configures LightDM autologin + XDG autostart
# for the kiosk user.
#
# Targets: Debian 12 (bookworm) and Ubuntu 22.04/24.04, amd64, X11.
# Usage:
#   sudo ./setup-linux.sh --appimage <https-url> [options]

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APT_KEY_DIR="/etc/apt/trusted.gpg.d"
SURFACE_KEY_URL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc"
SURFACE_APT_LIST="/etc/apt/sources.list.d/linux-surface.list"
SURFACE_APT_LINE="deb [arch=amd64] https://pkg.surfacelinux.com/debian release main"
SURFACE_PACKAGES=(linux-image-surface linux-headers-surface libwacom-surface iptsd)
MOK_PACKAGE="linux-surface-secureboot-mok"
MOK_PASSWORD="surface"
INSTALL_DIR="/opt/openskylight"
DEFAULT_KIOSK_USER="kiosk"
DEFAULT_APPIMAGE_REPO="cyber-nexus-75/OpenSkyLight"
GITHUB_API="https://api.github.com"
COMPANION_PORT=8420
APPIMAGE_URL=""
APPIMAGE_REPO=""
KIOSK_USER="$DEFAULT_KIOSK_USER"
WITH_MOK=1
WITH_AUTOLOGIN=1
WITH_FIREWALL=1

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }

die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./setup-linux.sh [--appimage <url> | --appimage-repo <owner/repo>] [options]

AppImage source (pick one; default: latest .AppImage release from $DEFAULT_APPIMAGE_REPO):
  --appimage <url>        https URL of the OpenSkyLight .AppImage (GitHub Releases asset)
  --appimage-repo <r>     owner/repo to resolve the latest .AppImage release from

Options:
  --kiosk-user <name>     Autologin account (default: kiosk, created if missing)
  --skip-mok              Do not enroll the linux-surface Secure Boot key
  --skip-autologin        Do not configure LightDM autologin or the autostart entry
  --skip-firewall         Do not open the companion web app port (TCP 8420)
  -h, --help              Show this help
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
      --appimage-repo)
        [ $# -ge 2 ] || die "--appimage-repo needs owner/repo"
        APPIMAGE_REPO="$2"
        shift 2
        ;;
      --skip-firewall)
        WITH_FIREWALL=0
        shift
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
  if [ -n "$APPIMAGE_URL" ] && [ -n "$APPIMAGE_REPO" ]; then
    die "--appimage and --appimage-repo are mutually exclusive"
  fi
  if [ -n "$APPIMAGE_URL" ]; then
    case "$APPIMAGE_URL" in
      https://*.AppImage) : ;;
      *) die "--appimage must be an https URL ending in .AppImage" ;;
    esac
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
    *) die "unsupported distro: ${ID:-unknown}; use Debian 12+ or Ubuntu 22.04+" ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
  log "Detected ${PRETTY_NAME:-$ID}"
}

add_surface_repo() {
  log "Adding the linux-surface apt repository"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl gnupg
  curl -fsSL "$SURFACE_KEY_URL" | gpg --dearmor > "$APT_KEY_DIR/linux-surface.gpg"
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

resolve_appimage_url() {
  if [ -n "$APPIMAGE_URL" ]; then
    log "Using explicit AppImage URL"
    return
  fi
  local repo="${APPIMAGE_REPO:-$DEFAULT_APPIMAGE_REPO}"
  log "Resolving latest AppImage from GitHub Releases: $repo"
  local url
  url="$(curl -fsSL "$GITHUB_API/repos/$repo/releases/latest" \
    | grep -oE '"browser_download_url":\s*"[^"]+\.AppImage"' \
    | head -n1 \
    | sed -E 's/.*"(https:[^"]+)"$/\1/')" || true
  [ -n "$url" ] || die "no .AppImage asset found in the latest release of $repo; build one or pass --appimage"
  APPIMAGE_URL="$url"
  log "Latest AppImage: $APPIMAGE_URL"
}

configure_firewall() {
  if [ "$WITH_FIREWALL" -eq 0 ]; then
    log "Skipping firewall configuration (--skip-firewall)"
    return
  fi
  if command -v ufw >/dev/null 2>&1; then
    log "Allowing companion web app on TCP $COMPANION_PORT (ufw)"
    ufw allow "$COMPANION_PORT/tcp" comment 'OpenSkyLight companion' \
      || log "warning: could not open port $COMPANION_PORT in ufw"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    log "Allowing companion web app on TCP $COMPANION_PORT (firewalld)"
    firewall-cmd --add-port="$COMPANION_PORT/tcp" \
      && firewall-cmd --permanent --add-port="$COMPANION_PORT/tcp" \
      || log "warning: could not open port $COMPANION_PORT in firewalld"
    return
  fi
  log "No firewall detected; nothing to open for TCP $COMPANION_PORT"
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
  mkdir -p "$autostart_dir"
  cat > "$autostart_dir/openskylight.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OpenSkyLight Kiosk
Exec=$INSTALL_DIR/openskylight.AppImage --kiosk
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
  usermod -aG autologin "$KIOSK_USER" || log "warning: could not add '$KIOSK_USER' to autologin group"
}

main() {
  parse_args "$@"
  require_root
  detect_distro
  add_surface_repo
  install_surface_kernel
  enroll_mok
  resolve_appimage_url
  install_appimage
  configure_kiosk
  configure_firewall
  log "Done. Reboot to activate the surface kernel and start the kiosk."
}

main "$@"
