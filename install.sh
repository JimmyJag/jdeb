#!/usr/bin/env bash
#
# Noctalia v5 + Umbriel desktop setup
# Target: fresh, minimal Debian 13 (Trixie) netinstall (no DE installed)
#
# Stack this builds:
#   Umbriel (compositor) + Noctalia (shell) + Noctalia Greeter (greetd)
#   Ghostty (terminal) + Nautilus (files) + RobotoMono Nerd Font
#   grim/slurp (screenshots) + NetworkManager + ufw + CUPS printing
#   NVIDIA driver (proprietary, DRM KMS) + git, Firefox, Zed, Obsidian,
#   OBS Studio, Discord + shell tools (btop, fzf, tldr, zoxide, ripgrep,
#   eza, fd, bat, yt-dlp, fastfetch, starship)
#
# Usage:
#   chmod +x setup-noctalia-umbriel.sh
#   ./setup-noctalia-umbriel.sh
#
# Run this as your normal sudo-capable user, NOT as root/with sudo prefixed.
# The script calls sudo itself for the steps that need it, so you'll be
# prompted for your password when required.

set -euo pipefail

# ---------------------------------------------------------------------------
# Toggles - flip to false to skip a component
# ---------------------------------------------------------------------------
INSTALL_GHOSTTY=false
INSTALL_XWAYLAND_SATELLITE=true   # X11-app compatibility for Umbriel; optional
INSTALL_BLUETOOTH=false

ARCH="$(dpkg --print-architecture)"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m!! %s\033[0m\n' "$*"; }

# Writes stdin to $1. If a file is already there with different content
# (a previous run, or a hand-edit), it's backed up to "$1.bak" first rather
# than silently discarded - so re-running to pick up a script update never
# destroys anything, it just archives the last version. If the content is
# identical to what's already there, this is a no-op (no needless .bak).
write_config() {
  local target="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$target" ] && ! cmp -s "$target" "$tmp"; then
    cp "$target" "$target.bak"
  fi
  mv "$tmp" "$target"
}

if [ "$(id -u)" -eq 0 ]; then
  echo "Don't run this as root. Run it as your normal user (it calls sudo itself when needed)." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required. Install it first: su -c 'apt install sudo' and add your user to the sudo group." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
log "Updating the base system"
# ---------------------------------------------------------------------------
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y curl wget gnupg ca-certificates unzip

# If an earlier version of this script already ran here, it may have
# dropped these into sources.list.d directly; the current version puts
# everything in /etc/apt/sources.list instead, and a leftover file here
# would make apt see the same repo twice ("configured multiple times").
sudo rm -f /etc/apt/sources.list.d/noctalia-trixie.sources \
           /etc/apt/sources.list.d/home_clayrisser_sid.sources \
           /etc/apt/sources.list.d/mozilla.sources

# ---------------------------------------------------------------------------
log "Enabling contrib/non-free/non-free-firmware and installing the NVIDIA driver"
# ---------------------------------------------------------------------------
# A real Debian 13 netinstall configures apt via the legacy
# /etc/apt/sources.list, not a DEB822 sources.list.d/debian.sources file
# (that file only shows up on cloud images, or after `apt
# modernize-sources`) - so that's the primary target here, edited in place
# rather than laying a second file on top (which risks apt's "configured
# multiple times" error if a component is re-declared). Only whichever of
# contrib/non-free/non-free-firmware is missing gets appended to each
# existing deb/deb-src line; everything else about the file is untouched.
# A .bak copy is kept first either way.
LEGACY_SOURCES="/etc/apt/sources.list"
DEB822_SOURCES="/etc/apt/sources.list.d/debian.sources"

add_missing_components_legacy() {
  awk '
    /^[[:space:]]*#/ || !/^[[:space:]]*deb(-src)?[[:space:]]/ { print; next }
    {
      n = split($0, tok, " ")
      i = 2
      if (tok[i] ~ /^\[/) {
        while (i <= n && tok[i] !~ /\]$/) i++
        i++
      }
      # tok[i] = URI, tok[i+1] = suite, tok[i+2..n] = components
      have_contrib=0; have_nonfree=0; have_nonfreefw=0
      for (j = i+2; j <= n; j++) {
        if (tok[j] == "contrib") have_contrib = 1
        if (tok[j] == "non-free") have_nonfree = 1
        if (tok[j] == "non-free-firmware") have_nonfreefw = 1
      }
      line = $0
      if (!have_contrib)   line = line " contrib"
      if (!have_nonfree)   line = line " non-free"
      if (!have_nonfreefw) line = line " non-free-firmware"
      print line
    }
  ' "$1"
}

if [ -f "$LEGACY_SOURCES" ] && grep -Eq '^[[:space:]]*deb(-src)?[[:space:]]' "$LEGACY_SOURCES"; then
  # Only ever back up the *first* time - a re-run's .bak should still be
  # the state before this script ever touched the file, not before its
  # own previous run.
  [ -f "$LEGACY_SOURCES.bak" ] || sudo cp "$LEGACY_SOURCES" "$LEGACY_SOURCES.bak"
  add_missing_components_legacy "$LEGACY_SOURCES" | sudo tee "$LEGACY_SOURCES.new" > /dev/null
  sudo mv "$LEGACY_SOURCES.new" "$LEGACY_SOURCES"
elif [ -f "$DEB822_SOURCES" ]; then
  # Fallback for systems already on DEB822 (apt modernize-sources, cloud
  # images) - same idea, applied to Components: lines instead.
  [ -f "$DEB822_SOURCES.bak" ] || sudo cp "$DEB822_SOURCES" "$DEB822_SOURCES.bak"
  awk '
    /^Components:/ {
      have_contrib=0; have_nonfree=0; have_nonfreefw=0
      for (i = 2; i <= NF; i++) {
        if ($i == "contrib") have_contrib = 1
        if ($i == "non-free") have_nonfree = 1
        if ($i == "non-free-firmware") have_nonfreefw = 1
      }
      line = $0
      if (!have_contrib)  line = line " contrib"
      if (!have_nonfree)  line = line " non-free"
      if (!have_nonfreefw) line = line " non-free-firmware"
      print line
      next
    }
    { print }
  ' "$DEB822_SOURCES" | sudo tee "$DEB822_SOURCES.new" > /dev/null
  sudo mv "$DEB822_SOURCES.new" "$DEB822_SOURCES"
else
  warn "Couldn't find $LEGACY_SOURCES or $DEB822_SOURCES." \
       "Add 'contrib non-free non-free-firmware' to your apt sources by hand," \
       "then re-run this script, or just install nvidia-driver manually."
fi
sudo apt update

# The linux-headers-$ARCH metapackage always tracks whatever kernel image
# package is current, which is safer than pinning to `uname -r` right after
# a full-upgrade (the running kernel may not be the newest installed one yet).
sudo apt install -y "linux-headers-$ARCH" nvidia-driver firmware-misc-nonfree

# DRM kernel modesetting is required for any Wayland compositor (Umbriel
# included) to drive the display through the NVIDIA driver.
sudo tee /etc/modprobe.d/nvidia-drm-modeset.conf > /dev/null <<'EOF'
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
EOF
sudo update-initramfs -u

# Session-level env var overrides, imported automatically by start-umbriel
# via systemd's environment.d mechanism. Left commented out: modern NVIDIA
# drivers (555+) with wlroots' explicit-sync support usually don't need any
# of this. Uncomment one at a time only if you hit cursor glitches or apps
# failing to start.
mkdir -p "$HOME/.config/environment.d"
if [ ! -f "$HOME/.config/environment.d/nvidia.conf" ]; then
cat > "$HOME/.config/environment.d/nvidia.conf" << 'EOF'
#WLR_NO_HARDWARE_CURSORS=1
#__GLX_VENDOR_LIBRARY_NAME=nvidia
#LIBVA_DRIVER_NAME=nvidia
EOF
fi
warn "NVIDIA driver installed - a REBOOT is required before Umbriel will start" \
     "correctly (the kernel needs to load with nvidia-drm.modeset=1 active)."

# ---------------------------------------------------------------------------
log "Adding the Noctalia APT repository (Noctalia, Umbriel, Greeter, portal)"
# ---------------------------------------------------------------------------
# Official repo per https://docs.noctalia.dev/noctalia/getting-started/installation/
wget -q https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb -O /tmp/nickh-archive-keyring.deb
sudo dpkg -i /tmp/nickh-archive-keyring.deb

# Noctalia publish a DEB822 .sources file; rather than drop it as-is into
# sources.list.d, parse its fields and append the equivalent plain deb
# line(s) to /etc/apt/sources.list instead. Its Suites: field can list more
# than one suite (their repo currently bundles a self-hosted
# "trixie-backports" alongside "trixie" - see the pin note below), and
# legacy format only takes one suite per line, so each becomes its own line.
NOCT_TMP="/tmp/noctalia-trixie.sources"
wget -q https://pkg.noctalia.dev/deb/noctalia-trixie.sources -O "$NOCT_TMP"

NOCT_URI=$(sed -n 's/^URIs:[[:space:]]*//p' "$NOCT_TMP" | head -1)
NOCT_SUITES=$(sed -n 's/^Suites:[[:space:]]*//p' "$NOCT_TMP" | head -1)
NOCT_COMPONENTS=$(sed -n 's/^Components:[[:space:]]*//p' "$NOCT_TMP" | head -1)
NOCT_SIGNED_BY=$(sed -n 's/^Signed-By:[[:space:]]*//p' "$NOCT_TMP" | head -1)

if [ -z "$NOCT_URI" ] || [ -z "$NOCT_SUITES" ]; then
  warn "Couldn't parse noctalia-trixie.sources; falling back to dropping it" \
       "into sources.list.d unchanged."
  sudo mv "$NOCT_TMP" /etc/apt/sources.list.d/noctalia-trixie.sources
else
  NOCT_OPTS=""
  [ -n "$NOCT_SIGNED_BY" ] && NOCT_OPTS="[signed-by=$NOCT_SIGNED_BY] "
  for suite in $NOCT_SUITES; do
    # A suite ending in "/" is an "absolute" reference in legacy one-line
    # format (Noctalia's own suites do this - visible as the trailing "/"
    # in apt's "Hit: ... trixie/ InRelease" output) - and apt flatly
    # refuses to parse an absolute suite combined with any components
    # ("Malformed entry ... (absolute Suite Component)"), even though
    # that combination is valid in their source DEB822 file. So: no
    # components appended for those, same as a flat repo.
    case "$suite" in
      */) NOCT_LINE="deb ${NOCT_OPTS}${NOCT_URI} ${suite}" ;;
      *)  NOCT_LINE="deb ${NOCT_OPTS}${NOCT_URI} ${suite} ${NOCT_COMPONENTS}" ;;
    esac
    grep -qxF "$NOCT_LINE" /etc/apt/sources.list 2>/dev/null || \
      echo "$NOCT_LINE" | sudo tee -a /etc/apt/sources.list > /dev/null
  done
  rm -f "$NOCT_TMP"
fi

# Noctalia's repo bundles a self-hosted "trixie-backports" suite alongside
# "trixie" (needed because current Umbriel/Noctalia builds require a newer
# wlroots than stock Trixie's libdrm2/libwayland/libxkbcommon can satisfy).
# Like real backports, that suite defaults to NotAutomatic, so apt's solver
# won't auto-select the newer libs even though umbriel hard-depends on them
# - producing a "held broken packages" conflict on plain `apt install`.
# Known upstream issue: https://github.com/noctalia-dev/noctalia-greeter/issues/108
# Pinning by hostname (not suite name) avoids ever touching Debian's own
# official trixie-backports if that's enabled separately.
sudo tee /etc/apt/preferences.d/noctalia > /dev/null <<'EOF'
Package: *
Pin: origin "pkg.noctalia.dev"
Pin-Priority: 500
EOF

sudo apt update

log "Installing Umbriel, Noctalia, the Umbriel portal backend, and the greeter"
sudo apt install -y umbriel noctalia xdg-desktop-portal-umbriel noctalia-greeter

# ---------------------------------------------------------------------------
log "Installing session plumbing: Xwayland, portals, audio, NetworkManager"
# ---------------------------------------------------------------------------
sudo apt install -y \
  xwayland \
  xdg-desktop-portal xdg-desktop-portal-gtk \
  pipewire pipewire-audio pipewire-pulse wireplumber \
  network-manager

if [ "$INSTALL_BLUETOOTH" = true ]; then
  sudo apt install -y bluez
fi

sudo systemctl enable --now NetworkManager.service
warn "If /etc/network/interfaces still has a stanza for your wired/Wi-Fi" \
     "interface (anything besides 'auto lo'/'iface lo'), comment it out so" \
     "ifupdown and NetworkManager don't fight over the same interface, then:" \
     "sudo systemctl restart networking NetworkManager"

# A fresh box with no firewall at all is worth locking down at least
# minimally, even behind a home router. Adjust rules later with 'sudo ufw'.
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable

# ---------------------------------------------------------------------------
if [ "$INSTALL_GHOSTTY" = true ]; then
  log "Installing Ghostty (community-maintained Debian repo, not official)"
  # https://github.com/clayrisser/debian-ghostty - trixie uses the sid/unstable channel
  curl -fsSL https://download.opensuse.org/repositories/home:clayrisser:sid/Debian_Unstable/Release.key \
    | gpg --dearmor | sudo tee /etc/apt/keyrings/home_clayrisser_sid.gpg > /dev/null
  GHOSTTY_LINE="deb [arch=$ARCH signed-by=/etc/apt/keyrings/home_clayrisser_sid.gpg] http://download.opensuse.org/repositories/home:/clayrisser:/sid/Debian_Unstable/ ./"
  grep -qxF "$GHOSTTY_LINE" /etc/apt/sources.list 2>/dev/null || \
    echo "$GHOSTTY_LINE" | sudo tee -a /etc/apt/sources.list > /dev/null
  sudo apt update
  sudo apt install -y ghostty
  sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/ghostty 50 || true
fi

# ---------------------------------------------------------------------------
log "Installing Nautilus and gvfs (trash, network shares, mounting)"
# ---------------------------------------------------------------------------
sudo apt install -y nautilus gvfs gvfs-backends gvfs-fuse
xdg-mime default org.gnome.Nautilus.desktop inode/directory 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Installing grim + slurp (used by Noctalia's screenshot widget)"
# ---------------------------------------------------------------------------
sudo apt install -y grim slurp

# ---------------------------------------------------------------------------
log "Installing clipboard backend and archive support"
# ---------------------------------------------------------------------------
sudo apt install -y wl-clipboard file-roller

# ---------------------------------------------------------------------------
log "Installing printer support (CUPS)"
# ---------------------------------------------------------------------------
sudo apt install -y cups cups-pdf printer-driver-all system-config-printer avahi-daemon
sudo systemctl enable --now cups.service avahi-daemon.service
sudo usermod -aG lpadmin "$USER"
warn "Printer admin group added - log out/in for it to take effect, then manage" \
     "printers at http://localhost:631 or via the System Config Printer app" \
     "(network printers should also show up automatically via Avahi/mDNS)."

# ---------------------------------------------------------------------------
log "Installing git, OBS Studio (both in Debian's own repos)"
# ---------------------------------------------------------------------------
sudo apt install -y git obs-studio v4l2loopback-dkms jq

# ---------------------------------------------------------------------------
log "Installing shell tools"
# ---------------------------------------------------------------------------
sudo apt install -y \
  btop fzf tldr zoxide ripgrep eza fd-find bat fastfetch starship

# Debian renames two of these to avoid clashing with older packages that
# already owned the plain command name - symlink the familiar names back in.
mkdir -p "$HOME/.local/bin"
ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"

# yt-dlp changes fast enough (YouTube breaks it regularly) that Debian's own
# package lags noticeably; installing the official upstream binary directly
# is yt-dlp's own recommended route rather than relying on trixie-backports.
sudo curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
  -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

# Activate zoxide and starship in bash.
if ! grep -q 'zoxide init bash' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" << 'EOF'

# --- shell tools (added by setup-noctalia-umbriel.sh) ---
export PATH="$HOME/.local/bin:$PATH"
eval "$(zoxide init bash)"
eval "$(starship init bash)"
EOF
fi

# ---------------------------------------------------------------------------
log "Adding Mozilla's official APT repo and installing Firefox"
# ---------------------------------------------------------------------------
# Debian's own repo only carries firefox-esr; this is Mozilla's real repo,
# per https://support.mozilla.org/kb/install-firefox-linux
sudo install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
  | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
MOZILLA_LINE="deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main"
grep -qxF "$MOZILLA_LINE" /etc/apt/sources.list 2>/dev/null || \
  echo "$MOZILLA_LINE" | sudo tee -a /etc/apt/sources.list > /dev/null
sudo tee /etc/apt/preferences.d/mozilla > /dev/null <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

# ---------------------------------------------------------------------------
log "Installing Zed (official install script - Zed has no APT package)"
# ---------------------------------------------------------------------------
# https://zed.dev/docs/linux - per-user install, deliberately NOT run with
# sudo. Needs a Vulkan-capable GPU (the NVIDIA driver installed above
# covers that) and glibc >= 2.31 (Trixie ships 2.41).
curl -f https://zed.dev/install.sh | sh

sudo apt update
sudo apt install -y firefox

# ---------------------------------------------------------------------------
log "Installing Obsidian (no APT repo; official .deb from GitHub releases)"
# ---------------------------------------------------------------------------
OBSIDIAN_DEB_URL="$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
  | jq -r '.assets[] | select(.name | test("_amd64\\.deb$")) | .browser_download_url')"
if [ -n "${OBSIDIAN_DEB_URL:-}" ]; then
  curl -fsSL -o /tmp/obsidian.deb "$OBSIDIAN_DEB_URL"
  sudo apt install -y /tmp/obsidian.deb
else
  warn "Couldn't auto-detect the latest Obsidian .deb; get it from https://obsidian.md/download"
fi

# ---------------------------------------------------------------------------
log "Installing Discord (no APT repo; official .deb from Discord's own endpoint)"
# ---------------------------------------------------------------------------
curl -fsSL -o /tmp/discord.deb "https://discord.com/api/download?platform=linux&format=deb"
sudo apt install -y /tmp/discord.deb

# ---------------------------------------------------------------------------
if [ "$INSTALL_XWAYLAND_SATELLITE" = true ]; then
  log "Building xwayland-satellite (Xwayland/X11-app support for Umbriel)"
  # Not packaged for Debian; official Umbriel dependency, built from source.
  # https://github.com/Supreeeme/xwayland-satellite
  sudo apt install -y cargo rustc clang pkg-config libxcb1-dev libxcb-cursor-dev
  if ! command -v xwayland-satellite >/dev/null 2>&1; then
    cargo install --locked xwayland-satellite --root "$HOME/.local"
  fi
  warn "Add \$HOME/.local/bin to PATH if it isn't already (check: echo \$PATH)."
fi

# ---------------------------------------------------------------------------
log "Installing the RobotoMono Nerd Font"
# ---------------------------------------------------------------------------
FONT_DIR="$HOME/.local/share/fonts/RobotoMonoNerdFont"
mkdir -p "$FONT_DIR"
curl -fsSL -o /tmp/RobotoMono.zip \
  https://github.com/ryanoasis/nerd-fonts/releases/latest/download/RobotoMono.zip
unzip -oq /tmp/RobotoMono.zip -d "$FONT_DIR"
fc-cache -f "$FONT_DIR" >/dev/null

# ---------------------------------------------------------------------------
log "Enabling greetd (Noctalia Greeter)"
# ---------------------------------------------------------------------------
sudo systemctl enable greetd.service
sudo systemctl restart greetd.service 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Writing Umbriel config (~/.config/umbriel/config.toml)"
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/umbriel"
write_config "$HOME/.config/umbriel/config.toml" << 'EOF'
[general]
autostart = ["noctalia"]
# mod_key defaults to Super; change here if you want Alt instead.

[appearance]
prefer_no_csd = true
border_width = 2
corner_radius = 10

[appearance.blur]
enabled = true
optimized = true
passes = 3
radius = 3
noise = 0.02
brightness = 0.9
contrast = 0.9
saturation = 1.1

# --- window rules ---
[[window_rule]]
blur = true
blur_optimized = true

[[window_rule]]
match.app_id = "^dev.noctalia.Noctalia$"
default_floating = true
default_size = [1020, 900]

# --- layer rules (blur Noctalia's bar/dock/panels/notifications/OSD) ---
[[layer_rule]]
match.namespace = "^noctalia-(bar-[^\"]+|notification|dock|panel|attached-panel|osd)$"
blur = true
blur_ignore_alpha = 0.5
blur_optimized = false

# --- keybinds ---
[keybinds]
"Mod+Return" = "spawn:ghostty"
"Mod+E" = "spawn:nautilus"
"Mod+B" = "spawn:firefox"
"Mod+Space" = "spawn:noctalia msg panel-toggle launcher"
"Mod+S" = "spawn:noctalia msg panel-toggle control-center"
"Mod+Comma" = "spawn:noctalia msg settings-toggle"
"Alt+Tab" = "spawn:noctalia msg window-switcher"
"Mod+Shift+A" = "spawn:noctalia msg screenshot-annotate"
"Mod+Ctrl+A" = "spawn:noctalia msg annotate"
"XF86AudioRaiseVolume" = "spawn:noctalia msg volume-up"
"XF86AudioLowerVolume" = "spawn:noctalia msg volume-down"
"XF86AudioMute" = "spawn:noctalia msg volume-mute"
"XF86MonBrightnessUp" = "spawn:noctalia msg brightness-up"
"XF86MonBrightnessDown" = "spawn:noctalia msg brightness-down"
EOF

# ---------------------------------------------------------------------------
log "Writing Noctalia config (~/.config/noctalia/config.toml)"
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/noctalia"
write_config "$HOME/.config/noctalia/config.toml" << 'EOF'
[shell]
font_family = "RobotoMono Nerd Font"
# Native polkit agent: safe to enable since no other agent is installed.
polkit_agent = true
# Lets typing in Umbriel's overview open Noctalia's launcher pre-filled -
# this Noctalia-side setting name is prefixed per-compositor (Niri's
# equivalent is niri_overview_type_to_launch_enabled); it does NOT belong
# in umbriel/config.toml, which has no [shell] section at all.
umbriel_overview_type_to_launch_enabled = true
EOF

# ---------------------------------------------------------------------------
log "Writing Ghostty config (~/.config/ghostty/config)"
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/ghostty"
write_config "$HOME/.config/ghostty/config" << 'EOF'
font-family = RobotoMono Nerd Font
window-decoration = false
EOF

# ---------------------------------------------------------------------------
log "Done."
cat <<'EOF'

Next steps:
  1. Reboot: sudo reboot
  2. At the Noctalia Greeter, pick the "Umbriel" session and log in.
  3. Inside the session: open Noctalia Settings -> Shell -> Security ->
     Noctalia Greeter -> "Sync Now" to push your wallpaper/palette/monitor
     layout to the login screen.
  4. Keybinds: Mod+Return = Ghostty, Mod+E = Nautilus, Mod+B = Firefox,
     Mod+Space = launcher, Mod+S = control center, Mod+Comma = settings,
     Alt+Tab = window switcher.
  5. If Wi-Fi/Ethernet doesn't come up, check the ifupdown/NetworkManager
     note printed above.
  6. Zed, Obsidian, OBS Studio, and Discord all launch from Noctalia's
     app launcher (Mod+Space) once installed.
  7. Open a new Ghostty window to see the starship prompt + zoxide (use
     'z <partial-dir-name>' instead of cd once you've visited it once).
     bat/fd are symlinked from batcat/fdfind - fastfetch, btop, ripgrep,
     eza, tldr, fzf, and yt-dlp are ready to use as-is.
  8. NVIDIA: this needs the reboot in step 1 before it'll work at all. If
     Umbriel fails to start or the cursor looks wrong afterward, edit
     ~/.config/environment.d/nvidia.conf and uncomment one line at a time.
  9. Printing: log out/in once so your lpadmin group membership applies,
     then add printers at http://localhost:631.

EOF
