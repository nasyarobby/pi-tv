#!/usr/bin/env bash
# Install Pi TV on the Raspberry Pi (Debian 13 Trixie / Raspberry Pi OS, arm64).
# Run from the unpacked release folder:  sudo ./install.sh [user]
# Native install (no Docker): binary + web build + systemd unit + config.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${1:-${SUDO_USER:-pi}}"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

[ "$(uname -m)" = aarch64 ] || echo "warning: this is $(uname -m), the release binary is for aarch64"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y chromium mpv ffmpeg cec-utils x11-xserver-utils wlopm || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y chromium mpv ffmpeg cec-utils

install -d /opt/pi-tv /etc/pi-tv
install -m 0755 "$HERE/pi-tv-server-linux-arm64" /opt/pi-tv/pi-tv-server
rm -rf /opt/pi-tv/web && cp -r "$HERE/web" /opt/pi-tv/web

if [ ! -f /etc/pi-tv/pi-tv.env ]; then
  sed "s#/home/pi#$USER_HOME#g" "$HERE/pi-tv.env.example" > /etc/pi-tv/pi-tv.env
fi
chown "$USER_NAME":"$USER_NAME" /etc/pi-tv/pi-tv.env
chmod 600 /etc/pi-tv/pi-tv.env

sed -e "s/^User=pi/User=$USER_NAME/" -e "s/^Group=pi/Group=$USER_NAME/" \
    -e "s#/run/user/1000#/run/user/$USER_UID#g" -e "s#HOME=/home/pi#HOME=$USER_HOME#" \
    "$HERE/pi-tv.service" > /etc/systemd/system/pi-tv.service
usermod -aG video "$USER_NAME" || true

systemctl daemon-reload
systemctl enable --now pi-tv
sleep 2
systemctl --no-pager status pi-tv | head -n 5 || true
echo
echo "Pi TV installed. Open http://$(hostname -I | awk '{print $1}'):8787 on your phone or laptop."
echo "PIN: set TV_PIN in /etc/pi-tv/pi-tv.env, or read the generated one: sudo cat $USER_HOME/.pi-tv/pin"
