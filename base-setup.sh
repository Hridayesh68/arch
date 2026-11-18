#!/usr/bin/env bash
set -e

echo "=== 1. Setting Timezone & Automatic NTP Time Sync ==="
sudo timedatectl set-timezone Asia/Kolkata
sudo timedatectl set-ntp true
timedatectl status

echo "=== 2. Installing Essential Tools, Fonts & Console Mouse (gpm) ==="
sudo pacman -Syu --noconfirm --needed \
  git curl wget unzip zip base-devel \
  nano vim htop btop tree tmux \
  terminus-font gpm bash-completion \
  nodejs npm

echo "=== 3. Enabling Console Mouse Cursor & Large Readable Font ==="
sudo systemctl enable --now gpm
setfont ter-132b || true
if ! grep -q "FONT=ter-132b" /etc/vconsole.conf 2>/dev/null; then
  echo "FONT=ter-132b" | sudo tee -a /etc/vconsole.conf
fi

echo "=== Base Setup Complete! ==="
