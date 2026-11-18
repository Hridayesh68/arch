#!/usr/bin/env bash
# =============================================================================
#  arch-setup.sh  -  one-shot post-install for Arch Linux
#  Target machine : MSI Bravo 15  (AMD Ryzen 5 5600H + Radeon RX 5500M)
#  What you get   : KDE Plasma (Wayland) desktop, Firefox, Dolphin, AMD GPU
#                   stack, gaming, video editing, AI / agent dev tooling,
#                   and performance tuning (zram, sysctl, zen kernel, ...)
#
#  Run as your NORMAL user (not root, not via sudo):
#       chmod +x arch-setup.sh && ./arch-setup.sh
#
#  Turn sections off by prefixing a 0, e.g.:
#       INSTALL_GAMING=0 INSTALL_CREATIVE=0 ./arch-setup.sh
# =============================================================================
set -uo pipefail

INSTALL_GAMING="${INSTALL_GAMING:-1}"      # Steam, Lutris, Wine, GameMode, MangoHud...
INSTALL_VIDEO="${INSTALL_VIDEO:-1}"        # Kdenlive, OBS, HandBrake, ffmpeg, codecs
INSTALL_CREATIVE="${INSTALL_CREATIVE:-1}"  # Blender, GIMP, Inkscape
INSTALL_AI_DEV="${INSTALL_AI_DEV:-1}"      # Docker, Python/uv, Node, Ollama, dev tools
INSTALL_ZEN_KERNEL="${INSTALL_ZEN_KERNEL:-1}"  # linux-zen (GRUB / systemd-boot only)

LOG="$HOME/arch-setup.log"
exec > >(tee -a "$LOG") 2>&1

# ----------------------------------------------------------------- helpers ---
B=$'\e[1;34m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; G=$'\e[1;32m'; N=$'\e[0m'
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*"; exit 1; }

FAILED=()
step() {                       # step "Description" function_name
  local name="$1"; shift
  info "$name"
  if ! "$@"; then warn "Finished with errors: $name"; FAILED+=("$name"); fi
}

# Install repo packages, silently skipping any name that does not exist
# (Arch renames/merges packages often; this keeps one bad name from
#  aborting the whole transaction).
pac() {
  local avail=() missing=() p
  for p in "$@"; do
    if pacman -Si "$p" &>/dev/null || pacman -Sg "$p" &>/dev/null; then
      avail+=("$p")
    else
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then warn "Not in repos, skipped: ${missing[*]}"; fi
  if [[ ${#avail[@]} -gt 0 ]]; then
    sudo pacman -S --needed --noconfirm "${avail[@]}"
  fi
}

# Install from AUR (or repos) one by one so one failure does not stop the rest.
aur() {
  local p rc=0
  for p in "$@"; do
    pacman -Qq "$p" &>/dev/null && continue
    paru -S --needed --noconfirm --skipreview "$p" || { warn "AUR/repo install failed: $p"; rc=1; }
  done
  return $rc
}

enable() {                     # enable (and optionally start) a system service
  sudo systemctl enable "$@" || warn "Could not enable: $*"
}

# --------------------------------------------------------------- preflight ---
preflight() {
  [[ $EUID -ne 0 ]] || die "Run as your normal user, not root and not with sudo. The script calls sudo itself."
  [[ -f /etc/arch-release ]] || die "This is not Arch Linux."
  command -v sudo >/dev/null || die "sudo is missing. As root: pacman -S sudo, then run visudo and enable the wheel group, and add your user to it."
  sudo -v || die "sudo does not work for this user (is your user in the wheel group?)."
  curl -fsI --max-time 15 https://archlinux.org >/dev/null || die "No internet connection."
  # keep sudo alive for the whole run
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  grep -q AuthenticAMD /proc/cpuinfo || warn "CPU is not AMD; this script is tuned for a Ryzen 5 5600H."
  lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true
}

# ---------------------------------------------------------- pacman / system ---
configure_pacman() {
  local f=/etc/pacman.conf
  sudo sed -i 's/^#Color/Color/' "$f"
  sudo sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$f"
  sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$f"      # enable 32-bit repo (Steam/Wine)
  grep -q '^\[multilib\]' "$f" || { warn "multilib could not be enabled"; return 1; }
  sudo sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf   # faster AUR builds
}

system_upgrade() { sudo pacman -Syu --noconfirm; }

update_mirrors() {
  pac reflector pacman-contrib || return 1
  sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
  if sudo reflector --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist; then
    sudo pacman -Syu --noconfirm
  else
    warn "reflector failed, restoring the old mirror list"
    sudo cp /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist
  fi
  enable paccache.timer
}

base_packages() {
  pac base-devel git curl wget rsync openssh \
      linux-headers linux-firmware amd-ucode \
      networkmanager bluez bluez-utils \
      man-db man-pages bash-completion nano vim \
      zip unzip p7zip unrar tree jq ripgrep fd fzf tmux \
      htop btop fastfetch lsof pciutils usbutils \
      ntfs-3g exfatprogs dosfstools xdg-utils xdg-user-dirs \
      ttf-liberation ttf-dejavu ttf-jetbrains-mono noto-fonts noto-fonts-emoji \
      flatpak ufw
}

install_paru() {
  command -v paru >/dev/null && { ok "paru already installed"; return 0; }
  local tmp; tmp="$(mktemp -d)"
  git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin" || return 1
  ( cd "$tmp/paru-bin" && makepkg -si --noconfirm ) || return 1
  rm -rf "$tmp"
}

# --------------------------------------------------------------- GPU / CPU ---
install_gpu() {
  # RX 5500M (Navi 14, RDNA1) uses the open amdgpu kernel driver + Mesa RADV.
  # The Ryzen's Vega iGPU is the "default" GPU; the RX 5500M is used on demand.
  pac mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
      vulkan-icd-loader lib32-vulkan-icd-loader vulkan-tools mesa-utils \
      libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau \
      libva-utils radeontop switcheroo-control xorg-xwayland qt6-wayland
  enable switcheroo-control.service
}

# ----------------------------------------------------- desktop (KDE Plasma) ---
install_desktop() {
  pac pipewire pipewire-alsa pipewire-pulse pipewire-jack lib32-pipewire \
      wireplumber alsa-utils sof-firmware pavucontrol \
      || return 1

  pac plasma-desktop sddm sddm-kcm \
      plasma-nm plasma-pa powerdevil bluedevil kscreen kinfocenter \
      plasma-systemmonitor plasma-browser-integration kdeplasma-addons \
      kde-gtk-config breeze-gtk xdg-desktop-portal-kde kwallet-pam \
      konsole dolphin dolphin-plugins kio-extras kio-admin ark kate okular \
      gwenview spectacle kcalc partitionmanager \
      kdegraphics-thumbnailers ffmpegthumbs \
      firefox power-profiles-daemon

  sudo systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
  enable --force sddm.service
  enable bluetooth.service power-profiles-daemon.service systemd-timesyncd.service
  sudo systemctl set-default graphical.target

  # NetworkManager: enable for next boot but do NOT restart it now, so your
  # current connection is not dropped in the middle of the script.
  if systemctl is-active --quiet NetworkManager; then
    enable NetworkManager.service
  else
    sudo systemctl enable NetworkManager.service
    warn "NetworkManager will take over networking after reboot (use 'nmtui' to connect to Wi-Fi if needed)."
  fi
  xdg-user-dirs-update || true
}

# -------------------------------------------------------- bootloader / kernel ---
setup_bootloader() {
  if [[ -f /boot/grub/grub.cfg ]]; then
    info "GRUB detected"
    pac os-prober
    if grep -q '^#\?GRUB_DISABLE_OS_PROBER' /etc/default/grub; then
      sudo sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    else
      echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a /etc/default/grub >/dev/null
    fi
    [[ "$INSTALL_ZEN_KERNEL" == 1 ]] && pac linux-zen linux-zen-headers
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  elif bootctl is-installed &>/dev/null; then
    info "systemd-boot detected"
    if [[ "$INSTALL_ZEN_KERNEL" == 1 ]]; then
      pac linux-zen linux-zen-headers || return 1
      local src
      src="$(grep -l 'vmlinuz-linux$' /boot/loader/entries/*.conf 2>/dev/null | grep -v fallback | head -n1 || true)"
      if [[ -n "$src" && -f /boot/vmlinuz-linux-zen && ! -f /boot/loader/entries/arch-zen.conf ]]; then
        sed -e 's#^title.*#title   Arch Linux (zen)#' \
            -e 's#vmlinuz-linux#vmlinuz-linux-zen#' \
            -e 's#initramfs-linux\(-fallback\)\?\.img#initramfs-linux-zen.img#' \
            "$src" | sudo tee /boot/loader/entries/arch-zen.conf >/dev/null
        ok "Added boot entry: Arch Linux (zen). Your normal kernel entry is untouched."
      else
        warn "Could not auto-create a zen boot entry. Add one manually (copy your Arch entry, use vmlinuz-linux-zen / initramfs-linux-zen.img)."
      fi
    fi
  else
    warn "No GRUB or systemd-boot detected: skipping extra kernel and os-prober."
  fi
}

# ------------------------------------------------------------- performance ---
tune_system() {
  pac zram-generator
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
  sudo tee /etc/sysctl.d/99-performance.conf >/dev/null <<'EOF'
# RAM-backed swap (zram) is cheap, so swap eagerly and skip readahead clustering
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
# Needed by some Proton/Wine games
vm.max_map_count = 2147483642
EOF
  sudo mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf >/dev/null

  sudo sysctl --system >/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl start systemd-zram-setup@zram0.service || warn "zram starts after reboot"
  enable fstrim.timer

  # Auto-nice daemon: keeps the desktop responsive while games/encodes run
  aur ananicy-cpp cachyos-ananicy-rules && enable ananicy-cpp.service

  # Firewall: deny incoming, allow outgoing
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw --force enable
  enable ufw.service
}

# ------------------------------------------------------------------ gaming ---
install_gaming() {
  pac steam gamemode lib32-gamemode mangohud lib32-mangohud lutris \
      wine-staging winetricks wine-mono wine-gecko gamescope goverlay
  aur protonup-qt
  getent group gamemode >/dev/null && sudo usermod -aG gamemode "$USER"
  return 0
}

# ------------------------------------------------------------------- video ---
install_video() {
  pac ffmpeg kdenlive obs-studio handbrake vlc mpv audacity \
      gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav \
      v4l2loopback-dkms
}

install_creative() { pac blender gimp inkscape; }

# --------------------------------------------------------- AI / dev tooling ---
install_ai_dev() {
  pac git github-cli docker docker-compose docker-buildx \
      python python-pip python-pipx uv nodejs npm pnpm \
      gcc clang gdb cmake ninja jdk-openjdk code \
      ollama ollama-vulkan
  enable --now docker.service
  sudo usermod -aG docker "$USER"
  enable --now ollama.service
}

# ------------------------------------------------------------------- main ---
main() {
  preflight
  step "Configuring pacman (multilib, colors, parallel downloads)" configure_pacman
  step "Full system upgrade"                                      system_upgrade
  step "Picking fast mirrors"                                     update_mirrors
  step "Base packages and tools"                                  base_packages
  step "Installing paru (AUR helper)"                             install_paru
  step "AMD GPU stack (Vulkan, VA-API, hybrid graphics)"          install_gpu
  step "KDE Plasma desktop, Firefox, Dolphin, audio, Bluetooth"   install_desktop
  step "Bootloader: os-prober and zen kernel"                     setup_bootloader
  step "Performance tuning (zram, sysctl, TRIM, ananicy, ufw)"    tune_system
  [[ "$INSTALL_GAMING"   == 1 ]] && step "Gaming stack"             install_gaming
  [[ "$INSTALL_VIDEO"    == 1 ]] && step "Video editing stack"      install_video
  [[ "$INSTALL_CREATIVE" == 1 ]] && step "Creative apps"            install_creative
  [[ "$INSTALL_AI_DEV"   == 1 ]] && step "AI / agent dev tooling"   install_ai_dev

  echo
  if [[ ${#FAILED[@]} -eq 0 ]]; then
    ok "All steps finished without errors."
  else
    warn "These steps reported errors (see $LOG):"
    printf '   - %s\n' "${FAILED[@]}"
  fi
  cat <<'EOF'

Next steps
  1. Reboot:  sudo reboot   (you will land on the SDDM login screen, pick "Plasma (Wayland)")
  2. Use the RX 5500M for a game:
       Steam launch option:   DRI_PRIME=1 gamemoderun mangohud %command%
       Other apps:            right-click -> "Run Using Dedicated Graphics Card"
  3. Open Steam > Settings > Compatibility and enable Steam Play (Proton), and
     use ProtonUp-Qt to add Proton-GE if a game needs it.
  4. Docker and GameMode group changes apply after you log out and back in.
EOF
}

main "$@"
