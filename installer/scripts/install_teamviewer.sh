#!/bin/bash
# TeamViewer Host Installer with PolicyKit fix
# This script installs TeamViewer Host with a fix for PolicyKit issues on Kali Linux

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/tmp/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN=""  # Your assignment token (optional)
ALIAS_PREFIX="$(hostname)-"  # Device names will be hostname + timestamp
TOOLS_DIR="/tmp/tv-installer"
LOG_DIR="/tmp/tv-installer/logs"

# Create necessary directories
mkdir -p "$TOOLS_DIR"
mkdir -p "$LOG_DIR"

# Function to log messages
log() {
  local level="$1"
  local message="$2"
  
  case "$level" in
    "INFO")   echo -e "${BLUE}[i] $message${NC}" ;;
    "SUCCESS") echo -e "${GREEN}[+] $message${NC}" ;;
    "ERROR")  echo -e "${RED}[-] $message${NC}" ;;
    "WARNING") echo -e "${YELLOW}[!] $message${NC}" ;;
    *)        echo -e "${YELLOW}[*] $message${NC}" ;;
  esac
}

# Function to print status messages (for compatibility with your original script)
print_status() {
  log "INFO" "$1"
}

print_success() {
  log "SUCCESS" "$1"
}

print_error() {
  log "ERROR" "$1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "Please run as root or with sudo"
  exit 1
fi

# Fix the policykit-1 package maintainer field
log "INFO" "Installing TeamViewer Host..."
cd "$TOOLS_DIR"

log "INFO" "Fixing policykit-1 package metadata..."
mkdir -p "$TOOLS_DIR/policykit-dummy-fixed/DEBIAN"

# Create updated control file with Maintainer field
cat > "$TOOLS_DIR/policykit-dummy-fixed/DEBIAN/control" << EOF
Package: policykit-1
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Depends: polkitd, pkexec
Maintainer: System Administrator <root@localhost>
Description: Transitional package for PolicyKit 
 This is a dummy package that provides policykit-1 while depending on
 modern PolicyKit packages polkitd and pkexec.
EOF

# Build the updated package
log "INFO" "Building updated policykit-1 package..."
dpkg-deb -b "$TOOLS_DIR/policykit-dummy-fixed" "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

# Install the updated package
log "INFO" "Installing updated policykit-1 package..."
dpkg -i "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

if [ $? -eq 0 ]; then
    log "SUCCESS" "Fixed policykit-1 package metadata."
    
    # Clean up
    rm -rf "$TOOLS_DIR/policykit-dummy-fixed"
    rm -f "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb"
else
    log "ERROR" "Failed to fix policykit-1 package metadata. The warning will continue but it's safe to ignore."
fi

# Check if the DEB package exists
if [ ! -f "$TV_PACKAGE" ]; then
  log "WARNING" "TeamViewer Host package not found at $TV_PACKAGE"
  
  # Try to download it
  log "INFO" "Attempting to download TeamViewer Host..."
  wget -q --show-progress https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Install TeamViewer
log "INFO" "Installing TeamViewer Host..."
apt-get update
dpkg -i "$TV_PACKAGE" || {
  log "INFO" "Fixing dependencies..."
  apt-get -f install -y
  dpkg -i "$TV_PACKAGE" || {
    log "ERROR" "Failed to install TeamViewer Host"
    exit 1
  }
}

# Make sure TeamViewer daemon is running
log "INFO" "Starting TeamViewer daemon..."
systemctl start teamviewerd || true
sleep 5

# Configure TeamViewer
if systemctl is-active --quiet teamviewerd; then
  log "SUCCESS" "TeamViewer Host installed and daemon is running"
  
  # Set a custom alias for this device
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  DEVICE_ALIAS="${ALIAS_PREFIX}${TIMESTAMP}"
  log "INFO" "Setting device alias to: $DEVICE_ALIAS"
  teamviewer alias "$DEVICE_ALIAS" || true
  
  # Assign to account if token provided
  if [ -n "$ASSIGNMENT_TOKEN" ]; then
    log "INFO" "Assigning device to your TeamViewer account..."
    teamviewer assignment --token "$ASSIGNMENT_TOKEN" || true
  fi
  
  # Configure for unattended access
  log "INFO" "Configuring for unattended access..."
  teamviewer setup --grant-easy-access || true
  
  # Create desktop entry
  cat > /usr/share/applications/teamviewer.desktop << DESKTOP
[Desktop Entry]
Name=TeamViewer
Comment=Remote Control Application
Exec=teamviewer
Icon=/opt/teamviewer/tv_bin/desktop/teamviewer.png
Terminal=false
Type=Application
Categories=Network;RemoteAccess;
DESKTOP
  
  # Display the TeamViewer ID
  TV_ID=$(teamviewer info 2>/dev/null | grep "TeamViewer ID:" | awk '{print $3}')
  if [ -n "$TV_ID" ]; then
    log "SUCCESS" "Configuration completed. TeamViewer ID: $TV_ID"
  else
    log "WARNING" "Could not retrieve TeamViewer ID"
  fi
else
  log "ERROR" "TeamViewer daemon is not running after installation"
  exit 1
fi

# Add to startup applications
if [ -d "/etc/xdg/autostart" ]; then
  log "INFO" "Adding TeamViewer to startup applications..."
  cat > /etc/xdg/autostart/teamviewerd.desktop << AUTOSTART
[Desktop Entry]
Type=Application
Name=TeamViewer
Comment=TeamViewer Remote Control Application
Exec=teamviewer
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOSTART
  log "SUCCESS" "TeamViewer added to startup applications"
fi

# Create .desktop file for user
current_user=$(who | awk '{print $1}' | grep -v "root" | head -1)
if [ -n "$current_user" ]; then
  user_home="/home/$current_user"
  if [ -d "$user_home/.local/share/applications" ] || [ -d "$user_home/Desktop" ]; then
    log "INFO" "Creating desktop shortcut for user $current_user..."
    mkdir -p "$user_home/.local/share/applications"
    cp /usr/share/applications/teamviewer.desktop "$user_home/.local/share/applications/"
    
    # Also add to Desktop
    if [ -d "$user_home/Desktop" ]; then
      cp /usr/share/applications/teamviewer.desktop "$user_home/Desktop/"
      chmod +x "$user_home/Desktop/teamviewer.desktop"
    fi
    
    # Fix ownership
    chown -R "$current_user:$current_user" "$user_home/.local/share/applications"
    [ -d "$user_home/Desktop" ] && chown "$current_user:$current_user" "$user_home/Desktop/teamviewer.desktop"
    
    log "SUCCESS" "Desktop shortcuts created for user $current_user"
  fi
fi

# Clean up
log "INFO" "Cleaning up..."
rm -rf "$TOOLS_DIR"
[ -f "$TV_PACKAGE" ] && rm -f "$TV_PACKAGE"

log "SUCCESS" "TeamViewer installation and configuration completed"
exit 0
