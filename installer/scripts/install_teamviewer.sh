#!/bin/bash
# TeamViewer Host Installer with advanced configuration and Kali Linux compatibility fixes

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/opt/security-tools/downloads/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN=""  # Your assignment token (optional)
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

# TeamViewer Host
print_status "Installing TeamViewer Host..."
cd "$TOOLS_DIR"

# Fix the policykit-1 package maintainer field
print_status "Fixing policykit-1 package metadata..."
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
print_status "Building updated policykit-1 package..."
dpkg-deb -b "$TOOLS_DIR/policykit-dummy-fixed" "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

# Install the updated package
print_status "Installing updated policykit-1 package..."
dpkg -i "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

if [ $? -eq 0 ]; then
    print_success "Fixed policykit-1 package metadata."
    
    # Clean up
    rm -rf "$TOOLS_DIR/policykit-dummy-fixed"
    rm -f "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb"
else
    print_error "Failed to fix policykit-1 package metadata. The warning will continue but it's safe to ignore."
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "Please run as root or with sudo"
  exit 1
fi

# Create directory if it doesn't exist
mkdir -p "$(dirname "$TV_PACKAGE")"

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

# Install policykit-1 dependency for Kali Linux
if grep -q "Kali" /etc/os-release; then
  log "INFO" "Kali Linux detected, installing policykit-1 dependency..."
  
  # Check if policykit-1 or polkit is already installed
  if dpkg -l | grep -E 'policykit-1|polkit' | grep -q '^ii'; then
    log "SUCCESS" "PolicyKit already installed"
  else
    # Try direct installation first
    apt-get update
    if apt-get install -y policykit-1 2>/dev/null; then
      log "SUCCESS" "Successfully installed policykit-1"
    else
      log "WARNING" "No installation candidate for policykit-1"
      
      # Try to install polkit as an alternative
      if apt-get install -y polkit 2>/dev/null; then
        log "SUCCESS" "Successfully installed polkit as an alternative"
      else
        log "WARNING" "Could not install polkit either. Creating equivs package..."
        
        # Install equivs if not already installed
        if ! command -v equivs-control &>/dev/null; then
          log "INFO" "Installing equivs package..."
          apt-get install -y equivs || {
            log "ERROR" "Failed to install equivs"
            exit 1
          }
        fi
        
        # Create a temporary directory
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR" || exit 1
        
        # Generate the equivs control file
        log "INFO" "Generating equivs control file..."
        equivs-control policykit-1
        
        # Edit the control file
        sed -i 's/^#\s*Version:.*/Version: 124-3/' policykit-1
        sed -i 's/^#\s*Depends:.*/Depends: pkexec, polkitd/' policykit-1
        sed -i 's/^Package:.*/Package: policykit-1/' policykit-1
        
        # Build the package
        log "INFO" "Building policykit-1 package..."
        equivs-build policykit-1 || {
          log "ERROR" "Failed to build policykit-1 package"
          rm -rf "$TEMP_DIR"
          exit 1
        }
        
        # Install the package
        log "INFO" "Installing dummy policykit-1 package..."
        apt-get install -y ./policykit-1_124-3_all.deb || {
          log "ERROR" "Failed to install dummy policykit-1 package"
          rm -rf "$TEMP_DIR"
          exit 1
        }
        
        # Fix permissions on polkit agent helper if it exists
        if [ -f "/usr/lib/policykit-1/polkit-agent-helper-1" ]; then
          log "INFO" "Setting correct permissions on polkit-agent-helper-1..."
          chmod 4755 /usr/lib/policykit-1/polkit-agent-helper-1
        fi
        
        # Cleanup
        rm -rf "$TEMP_DIR"
      fi
    fi
  fi
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

# Create .desktop file for rmcyber user
if [ -d "/home/rmcyber/.local/share/applications" ] || [ -d "/home/rmcyber/Desktop" ]; then
  log "INFO" "Creating desktop shortcut for rmcyber user..."
  mkdir -p "/home/rmcyber/.local/share/applications"
  cp /usr/share/applications/teamviewer.desktop "/home/rmcyber/.local/share/applications/"
  
  # Also add to Desktop
  if [ -d "/home/rmcyber/Desktop" ]; then
    cp /usr/share/applications/teamviewer.desktop "/home/rmcyber/Desktop/"
    chmod +x "/home/rmcyber/Desktop/teamviewer.desktop"
  fi
  
  # Fix ownership
  chown -R rmcyber:rmcyber "/home/rmcyber/.local/share/applications"
  [ -d "/home/rmcyber/Desktop" ] && chown rmcyber:rmcyber "/home/rmcyber/Desktop/teamviewer.desktop"
  
  log "SUCCESS" "Desktop shortcuts created for rmcyber user"
fi

log "SUCCESS" "TeamViewer installation and configuration completed"
exit 0
