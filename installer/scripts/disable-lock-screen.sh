#!/usr/bin/env bash
#
# Enhanced disable-lock-screen.sh
#
# Comprehensive script to disable ALL screen locks, power management,
# and screen blanking in Kali Linux (GNOME and Xfce)

# Colors for better visibility
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
NC="\033[0m" # No Color

echo -e "${BLUE}${BOLD}==> Disabling GNOME screensaver and lock screen...${NC}"

# Detect current desktop environment
if [ -n "$XDG_CURRENT_DESKTOP" ]; then
  DE=$XDG_CURRENT_DESKTOP
elif [ -n "$DESKTOP_SESSION" ]; then
  DE=$DESKTOP_SESSION
else
  # Try to detect based on running processes
  if pgrep -x "gnome-shell" > /dev/null; then
    DE="GNOME"
  elif pgrep -x "xfce4-session" > /dev/null; then
    DE="XFCE"
  else
    DE="UNKNOWN"
  fi
fi

echo -e "${YELLOW}Detected desktop environment: $DE${NC}"

# GNOME-specific settings
if [[ "$DE" == *"GNOME"* ]]; then
  echo -e "${BLUE}Applying GNOME-specific settings...${NC}"
  
  # 1. Disable lock screen
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
  gsettings set org.gnome.desktop.lockdown disable-lock-screen true 2>/dev/null
  
  # 2. Disable screen blanking and screensaver
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
  
  # 3. Disable automatic suspend
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null
  
  # 4. Disable automatic dimming
  gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power idle-brightness 100 2>/dev/null
  
  # 5. Disable automatic blank
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
  
  # 6. Disable lock on suspend
  gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null
  gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null
  
  # 7. Additional GNOME power settings
  gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing' 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing' 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action 'nothing' 2>/dev/null
  
  # 8. Disable screen blanking in mutter (GNOME Shell window manager)
  gsettings set org.gnome.mutter idle-monitor-type 'nothing' 2>/dev/null
fi

# XFCE-specific settings
if [[ "$DE" == *"XFCE"* ]]; then
  echo -e "${BLUE}Applying XFCE-specific settings...${NC}"
  
  # Disable XFCE power management
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-off -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-sleep -s 0 2>/dev/null
  
  # Disable XFCE screensaver
  xfconf-query -c xfce4-screensaver -p /screensaver/enabled -s false 2>/dev/null
  xfconf-query -c xfce4-screensaver -p /screensaver/lock/enabled -s false 2>/dev/null
fi

echo -e "${BLUE}==> Disabling light-locker (common on Xfce)...${NC}"
# Stop light-locker
pkill light-locker 2>/dev/null
# Disable it at startup
systemctl disable light-locker.service 2>/dev/null

# Check if light-locker is in autostart
if [ -f "/etc/xdg/autostart/light-locker.desktop" ]; then
  echo -e "${YELLOW}Disabling light-locker autostart...${NC}"
  mkdir -p ~/.config/autostart
  cp /etc/xdg/autostart/light-locker.desktop ~/.config/autostart/
  echo "Hidden=true" >> ~/.config/autostart/light-locker.desktop
fi

echo -e "${BLUE}==> Disabling X11 screen blanking and DPMS...${NC}"
xset s off
xset s noblank
xset -dpms

# Create a startup script to ensure settings persist
echo -e "${BLUE}==> Creating autostart script to make settings persistent...${NC}"
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/disable-screen-lock.desktop << EOF
[Desktop Entry]
Type=Application
Name=Disable Screen Lock
Comment=Disables screen locking and power management
Exec=bash -c "xset s off; xset s noblank; xset -dpms"
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

# System-wide power management through logind
echo -e "${BLUE}==> Configuring system-wide power management via logind...${NC}"
if [ -d "/etc/systemd/logind.conf.d" ]; then
  # Create configuration file if directory exists
  sudo tee /etc/systemd/logind.conf.d/10-disable-power-management.conf > /dev/null << EOF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
else
  # Edit main config if directory doesn't exist
  sudo sed -i 's/^#HandleLidSwitch=.*$/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
  sudo sed -i 's/^#HandleLidSwitchExternalPower=.*$/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
  sudo sed -i 's/^#HandleLidSwitchDocked=.*$/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
  sudo sed -i 's/^#IdleAction=.*$/IdleAction=ignore/' /etc/systemd/logind.conf
fi

# Optionally remove screensaver packages
echo -e "${YELLOW}==> Consider removing screensaver packages if still having issues:${NC}"
echo -e "    sudo apt-get remove gnome-screensaver light-locker xscreensaver"

echo -e "${GREEN}==> Done! Screen locking and power management have been disabled.${NC}"
echo -e "${YELLOW}NOTE: You may need to reboot or restart your session for all changes to take effect.${NC}"
