#!/bin/bash
# TeamViewer Host Installer Script with Assignment

# Exit on error with controlled error handling
set +e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/opt/rta-deployment/downloads/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN="25998227-v1SCqDinbXPh3pHnBv7s"  # Your assignment token
GROUP_ID="RTAs"  # Replace with your actual group ID
ALIAS_PREFIX="$(hostname)-"  # Device names will be hostname + timestamp

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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "Please run as root or with sudo"
  exit 1
fi

# Check if the DEB package exists
if [ ! -f "$TV_PACKAGE" ]; then
  log "WARNING" "TeamViewer Host package not found at $TV_PACKAGE"
  
  # Try to download it
  log "INFO" "Attempting to download TeamViewer Host..."
  mkdir -p "$(dirname "$TV_PACKAGE")"
  wget https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Install TeamViewer
log "STATUS" "Installing TeamViewer Host..."
apt-get update
dpkg -i "$TV_PACKAGE" || {
  log "INFO" "Fixing dependencies..."
  apt-get -f install -y
  dpkg -i "$TV_PACKAGE" || {
    log "ERROR" "Failed to install TeamViewer Host"
    exit 1
  }
}

# Wait for TeamViewer service to start
log "INFO" "Waiting for TeamViewer service to initialize..."
systemctl start teamviewerd
sleep 10

# Assign to your TeamViewer account using the assignment token
log "STATUS" "Assigning device to your TeamViewer account..."
teamviewer --daemon start

if [ -n "$ASSIGNMENT_TOKEN" ]; then
  log "INFO" "Using assignment token: $ASSIGNMENT_TOKEN"
  teamviewer assignment --token "$ASSIGNMENT_TOKEN" || {
    log "WARNING" "Failed to assign with token. Please check the token and try manually."
  }
else
  log "WARNING" "No assignment token provided. Device will need manual assignment."
fi

# Set a custom alias for this device
TIMESTAMP=$(date +%Y%m%d%H%M%S)
DEVICE_ALIAS="${ALIAS_PREFIX}${TIMESTAMP}"
log "INFO" "Setting device alias to: $DEVICE_ALIAS"
teamviewer alias "$DEVICE_ALIAS" || log "WARNING" "Failed to set alias"

# Assign to specific group (if specified)
if [ -n "$GROUP_ID" ]; then
  log "INFO" "Assigning to group: $GROUP_ID"
  teamviewer assignment --group-id "$GROUP_ID" || log "WARNING" "Failed to assign to group"
fi

# Configure TeamViewer for unattended access (no password needed)
log "INFO" "Configuring for unattended access..."
teamviewer setup --grant-easy-access || log "WARNING" "Failed to configure unattended access"

# Disable commercial usage notification (available in corporate license)
log "INFO" "Disabling commercial usage notification..."
teamviewer config set General\\CUNotification 0 || log "WARNING" "Failed to disable commercial usage notification"

# Restart TeamViewer to apply all settings
log "INFO" "Restarting TeamViewer service..."
teamviewer --daemon restart

# Display the TeamViewer ID for reference
TV_ID=$(teamviewer info | grep "TeamViewer ID:" | awk '{print $3}')
if [ -n "$TV_ID" ]; then
  log "SUCCESS" "TeamViewer Host installation completed successfully!"
  log "INFO" "TeamViewer ID: $TV_ID"
  log "INFO" "This device is now accessible through your TeamViewer business account."
else
  log "WARNING" "TeamViewer installation completed, but could not retrieve ID."
  log "INFO" "Check TeamViewer status with: teamviewer info"
fi

exit 0
