#!/usr/bin/env bash
#
# disable-lock-screen.sh
#
# A more comprehensive script to disable screen lock & blanking in GNOME or Xfce on Kali.

echo "==> Disabling GNOME screensaver and lock screen (if GNOME is in use)..."

# Disable GNOME lock screen
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
# Disable auto-activation of screensaver
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
# Set lock delay to 0
gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null
# Attempt to disable lock on suspend (if key exists)
gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null

# Disable GNOME's power-related lock triggers
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null

echo "==> Disabling Xfce or light-locker (if Xfce is in use)..."
# Stop light-locker
pkill light-locker 2>/dev/null
# Disable it at startup
sudo systemctl disable light-locker.service 2>/dev/null
# Turn off Xfce screensaver lock, if present
xfconf-query -c xfce4-screensaver -p /screensaver/lock_enabled -s false 2>/dev/null

echo "==> Disabling X11 screen blanking and DPMS..."
xset s off
xset s noblank
xset -dpms

echo "==> Remove GNOME or Xfce screensaver packages if still locking..."
echo "    sudo apt-get remove gnome-screensaver light-locker"
echo "==> Done! If it still locks, confirm you ran this script in your GUI user session."
