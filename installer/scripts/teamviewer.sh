#!/bin/bash
# TeamViewer Host Installer with advanced configuration and Kali Linux compatibility fixes

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/opt/rta-deployment/downloads/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN="25998227-v1SCqDinbXPh3pHnBv7s"  # Your assignment token
GROUP_ID="g12345"  # Replace with your actual group ID
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
  wget -q --show-progress https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Install policykit-1 dependency for Kali Linux
if grep -q "Kali" /etc/os-release; then
  log "INFO" "Kali Linux detected, installing policykit-1 dependency..."
  
  # Direct installation of policykit-1
  apt-get update
  apt-get install -y policykit-1 || {
    log "WARNING" "Could not install policykit-1 from repositories"
    
    # Alternative way - install polkit instead (provides policykit-1)
    log "INFO" "Attempting to install polkit as an alternative..."
    apt-get install -y polkit
  }
  
  # Verify if policykit-1 or equivalent is installed
  if ! dpkg -l | grep -E 'policykit-1|polkit' | grep -q '^ii'; then
    log "WARNING" "Could not install required dependency. Creating manual override..."
    
    # Create directory for fake policykit-1 package
    mkdir -p /tmp/fake-policykit
    cd /tmp/fake-policykit
    
    # Creating a minimal debian package structure
    mkdir -p DEBIAN
    cat > DEBIAN/control << EOF
Package: policykit-1
Version: 1.0.0
Architecture: all
Maintainer: RTA Installer <rta@example.com>
Description: Dummy policykit-1 package for TeamViewer
Priority: optional
Section: admin
EOF
    
    # Build the package
    log "INFO" "Building dummy policykit-1 package..."
    dpkg-deb --build . policykit-1_1.0.0_all.deb
    
    # Install the dummy package
    log "INFO" "Installing dummy policykit-1 package..."
    dpkg -i policykit-1_1.0.0_all.deb || {
      log "ERROR" "Failed to install dummy policykit-1 package"
      cd - > /dev/null
      rm -rf /tmp/fake-policykit
      exit 1
    }
    
    cd - > /dev/null
    rm -rf /tmp/fake-policykit
  fi
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

exit 0
