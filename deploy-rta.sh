#!/bin/bash
# Enhanced RTA Deployment Script
# Executes all scripts in sequence with user prompts and downloads required tools

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Functions
print_status() { 
  echo -e "${YELLOW}[*] $1${NC}"
}

print_success() { 
  echo -e "${GREEN}[+] $1${NC}"
}

print_error() { 
  echo -e "${RED}[-] $1${NC}"
}

print_info() { 
  echo -e "${BLUE}[i] $1${NC}"
}

prompt_continue() {
  echo ""
  read -p "Do you want to proceed with $1? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) 
      return 0
      ;;
    *)
      print_info "Skipping $1"
      return 1
      ;;
  esac
}

download_file() {
  local url="$1"
  local output_file="$2"
  local description="$3"
  
  if [ -f "$output_file" ]; then
    print_info "$description already downloaded"
  else
    print_status "Downloading $description..."
    curl -sSL "$url" -o "$output_file" || wget -q "$url" -O "$output_file"
    if [ $? -eq 0 ]; then
      print_success "$description downloaded successfully"
    else
      print_error "Failed to download $description"
      return 1
    fi
  fi
  return 0
}

# Check root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root"
  exit 1
fi

# Display banner
echo "=================================================="
echo "        ENHANCED KALI LINUX RTA DEPLOYMENT        "
echo "=================================================="
echo ""

# Parse command-line arguments
AUTO_MODE=false
INTERACTIVE_MODE=false
SKIP_DOWNLOADS=false

for arg in "$@"; do
  case $arg in
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --interactive)
      INTERACTIVE_MODE=true
      shift
      ;;
    --skip-downloads)
      SKIP_DOWNLOADS=true
      shift
      ;;
    *)
      # Unknown option
      ;;
  esac
done

# Create required directories
print_status "Creating directories..."
mkdir -p /opt/rta-deployment/{logs,downloads}
mkdir -p /opt/security-tools/{bin,logs,scripts,helpers,config,system-state}

# Create config directory and copy configuration if needed
if [ ! -d "/opt/rta-deployment/config" ]; then
  mkdir -p /opt/rta-deployment/config
  
  print_status "Copying configuration file..."
  cp installer/config.yml /opt/rta-deployment/config/config.yml 2>/dev/null || {
    print_info "Default configuration not found, creating minimal version"
    cat > /opt/rta-deployment/config/config.yml << 'ENDOFCONFIG'
# Minimal RTA Configuration
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,proxychains4,metasploit-framework"
pipx_tools: "scoutsuite,impacket"
git_tools: "https://github.com/prowler-cloud/prowler.git"
manual_tools: "nessus,burpsuite_enterprise,teamviewer"
ENDOFCONFIG
  }
fi

# Copy installer script if it exists locally, otherwise download it
if [ -f "installer/rta-installer.sh" ]; then
  print_status "Copying installer script..."
  cp installer/rta-installer.sh /opt/rta-deployment/
  chmod +x /opt/rta-deployment/rta-installer.sh
else
  print_status "Downloading installer script..."
  curl -sSL "https://raw.githubusercontent.com/yourusername/rta-installer/main/rta_installer.sh" -o /opt/rta-deployment/rta_installer.sh
  chmod +x /opt/rta-deployment/rta_installer.sh
fi

# Download required tools
if ! $SKIP_DOWNLOADS; then
  # Check if we're in auto mode or if user wants to download tools
  if $AUTO_MODE || prompt_continue "downloading required tools"; then
    print_status "Downloading required tools..."
    
    # We'll skip separate Burp Suite download since we're using the GitHub installer
    print_info "Burp Suite Professional will be downloaded by its installer script"
    
    # Download Nessus
    download_file "https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true" \
      "/opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb" \
      "Nessus Vulnerability Scanner"
    
    # Download TeamViewer
    download_file "https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb" \
      "/opt/rta-deployment/downloads/teamviewer-host_amd64.deb" \
      "TeamViewer Host"
      
    # Download NinjaOne Agent
    download_file "https://app.ninjarmm.com/agent/installer/fc75fb12-9ee2-4f8d-8319-8df4493a9fb9/8.0.2891/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb" \
      "/opt/rta-deployment/downloads/NinjaOne-Agent.deb" \
      "NinjaOne Agent"
  fi
fi

# Create tool installation helpers
print_status "Creating tool installation helpers..."

# Create Burp Suite Professional helper script
cat > /opt/security-tools/helpers/install_burpsuite.sh << 'ENDOFBURPSCRIPT'
#!/bin/bash
# Helper script to install Burp Suite Professional using GitHub repo

echo "Installing Burp Suite Professional using the GitHub repository installer..."
  
# Download and run the installer from GitHub
wget -qO- https://raw.githubusercontent.com/xiv3r/Burpsuite-Professional/main/install.sh | bash

# Check if installation was successful
if [ -f "/usr/bin/burpsuite" ]; then
  echo "Burp Suite Professional installed successfully"
else
  echo "Burp Suite Professional installation may have failed. Please check logs for details."
  exit 1
fi
ENDOFBURPSCRIPT
chmod +x /opt/security-tools/helpers/install_burpsuite.sh

# Create Nessus helper script
cat > /opt/security-tools/helpers/install_nessus.sh << 'ENDOFNESSUSSCRIPT'
#!/bin/bash
# Helper script to install Nessus

# Check if the DEB package exists
if [ -f "/opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb" ]; then
  echo "Installing Nessus..."
  apt-get update
  dpkg -i /opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb || {
    apt-get -f install -y  # Fix broken dependencies if any
    dpkg -i /opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb
  }
  
  # Start Nessus service
  systemctl start nessusd
  systemctl enable nessusd
  
  echo "Nessus installed successfully"
  echo "Open https://localhost:8834/ to complete setup"
else
  echo "Nessus DEB package not found. Please download it first."
  exit 1
fi
ENDOFNESSUSSCRIPT
chmod +x /opt/security-tools/helpers/install_nessus.sh

# Create TeamViewer helper script
cat > /opt/security-tools/helpers/install_teamviewer.sh << 'ENDOFTVSCRIPT'
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
ENDOFTVSCRIPT
chmod +x /opt/security-tools/helpers/install_teamviewer.sh

# Create NinjaOne Agent helper script
cat > /opt/security-tools/helpers/install_ninjaone.sh << 'ENDOFNINJASCRIPT'
#!/bin/bash
# Helper script to install NinjaOne Agent

# Check if the DEB package exists
if [ -f "/opt/rta-deployment/downloads/NinjaOne-Agent.deb" ]; then
  echo "Installing NinjaOne Agent..."
  
  # Install the DEB package
  apt-get update
  dpkg -i /opt/rta-deployment/downloads/NinjaOne-Agent.deb || {
    echo "Fixing dependencies..."
    apt-get -f install -y
    dpkg -i /opt/rta-deployment/downloads/NinjaOne-Agent.deb
  }
  
  # Check if service is running
  systemctl status ninjarmm-agent &>/dev/null
  if [ $? -eq 0 ]; then
    echo "NinjaOne Agent installed successfully and service is running"
  else
    echo "Starting NinjaOne Agent service..."
    systemctl start ninjarmm-agent
    echo "NinjaOne Agent installed"
  fi
else
  echo "NinjaOne Agent DEB package not found. Please download it first."
  exit 1
fi
ENDOFNINJASCRIPT
chmod +x /opt/security-tools/helpers/install_ninjaone.sh

# Copy validation script if it exists locally, otherwise create a minimal one
if [ -f "installer/scripts/validate-tools.sh" ]; then
  print_status "Copying validation script..."
  cp installer/scripts/validate-tools.sh /opt/security-tools/scripts/
  chmod +x /opt/security-tools/scripts/validate-tools.sh
else
  print_status "Creating validation script..."
  cat > /opt/security-tools/scripts/validate-tools.sh << 'ENDOFVALSCRIPT'
#!/bin/bash
echo "Validating tools..."
which nmap > /dev/null && echo "✓ nmap found" || echo "✗ nmap not found"
which wireshark > /dev/null && echo "✓ wireshark found" || echo "✗ wireshark not found"
test -f "/usr/bin/burpsuite" && echo "✓ Burp Suite Professional found" || echo "✗ Burp Suite Professional not found"
systemctl status nessusd &>/dev/null && echo "✓ Nessus service found" || echo "✗ Nessus service not found"
which teamviewer &>/dev/null && echo "✓ TeamViewer found" || echo "✗ TeamViewer not found"
systemctl status ninjarmm-agent &>/dev/null && echo "✓ NinjaOne Agent found" || echo "✗ NinjaOne Agent not found"
ENDOFVALSCRIPT
  chmod +x /opt/security-tools/scripts/validate-tools.sh
fi

# Copy screen lock disable script if it exists locally
if [ -f "installer/scripts/disable-lock-screen.sh" ]; then
  print_status "Copying screen lock disable script..."
  cp installer/scripts/disable-lock-screen.sh /opt/security-tools/scripts/
  chmod +x /opt/security-tools/scripts/disable-lock-screen.sh
fi

# Execute installation steps in sequence
if $AUTO_MODE; then
  # Automatic mode - no prompts
  print_status "Running installer in automatic mode..."
  
  # Run main installer script
  print_status "Running main installer script..."
  /opt/rta-deployment/rta_installer.sh
  
  # Install Burp Suite
  print_status "Installing Burp Suite Professional..."
  /opt/security-tools/helpers/install_burpsuite.sh
  
  # Install Nessus
  print_status "Installing Nessus..."
  /opt/security-tools/helpers/install_nessus.sh
  
  # Install TeamViewer
  print_status "Installing TeamViewer..."
  /opt/security-tools/helpers/install_teamviewer.sh
  
  # Install NinjaOne Agent
  print_status "Installing NinjaOne Agent..."
  /opt/security-tools/helpers/install_ninjaone.sh
  
  # Disable screen lock if script exists
  if [ -f "/opt/security-tools/scripts/disable-lock-screen.sh" ]; then
    print_status "Disabling screen lock..."
    /opt/security-tools/scripts/disable-lock-screen.sh
  fi
else
  # Interactive mode - prompt for each step
  
  # Run main installer script
  if prompt_continue "running the main installer script"; then
    print_status "Running main installer script..."
    /opt/rta-deployment/rta_installer.sh
  fi
  
  # Install Burp Suite
  if prompt_continue "installing Burp Suite Professional"; then
    print_status "Installing Burp Suite Professional..."
    /opt/security-tools/helpers/install_burpsuite.sh
  fi
  
  # Install Nessus
  if prompt_continue "installing Nessus"; then
    print_status "Installing Nessus..."
    /opt/security-tools/helpers/install_nessus.sh
  fi
  
  # Install TeamViewer
  if prompt_continue "installing TeamViewer"; then
    print_status "Installing TeamViewer..."
    /opt/security-tools/helpers/install_teamviewer.sh
  fi
  
  # Install NinjaOne Agent
  if prompt_continue "installing NinjaOne Agent"; then
    print_status "Installing NinjaOne Agent..."
    /opt/security-tools/helpers/install_ninjaone.sh
  fi
  
  # Disable screen lock if script exists
  if [ -f "/opt/security-tools/scripts/disable-lock-screen.sh" ] && prompt_continue "disabling screen lock"; then
    print_status "Disabling screen lock..."
    /opt/security-tools/scripts/disable-lock-screen.sh
  fi
fi

# Create system snapshot
print_status "Creating system snapshot..."
SNAPSHOT_FILE="/opt/security-tools/system-state/snapshot-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "=== SYSTEM SNAPSHOT ==="
  echo "Date: $(date)"
  echo "Hostname: $(hostname)"
  echo "Kernel: $(uname -r)"
  echo ""
  echo "=== INSTALLED TOOLS ==="
  /opt/security-tools/scripts/validate-tools.sh | sed 's/^/  /'
  echo ""
  echo "=== DISK SPACE ==="
  df -h
  echo ""
  echo "=== MEMORY USAGE ==="
  free -h
  echo ""
  echo "=== NETWORK CONFIGURATION ==="
  ip a | grep -E 'inet|^[0-9]'
} > "$SNAPSHOT_FILE"

print_success "System snapshot saved: $SNAPSHOT_FILE"

# Display completion message
echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}          RTA DEPLOYMENT COMPLETED!              ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
print_info "Installed tools can be found at: /opt/security-tools/"
print_info "Manual installation helpers are in: /opt/security-tools/helpers/"
print_info "System snapshot saved to: $SNAPSHOT_FILE"
print_info "To validate tools run: sudo /opt/security-tools/scripts/validate-tools.sh"
print_info "A reboot is recommended to complete setup."

# If Nessus was installed, provide additional information
if systemctl status nessusd &>/dev/null; then
  echo ""
  print_info "Nessus has been installed and the service is running."
  print_info "Complete the setup at: https://localhost:8834/"
fi

# If TeamViewer was installed, show the ID
if command -v teamviewer &>/dev/null; then
  echo ""
  print_info "TeamViewer has been installed."
  TV_ID=$(teamviewer info 2>/dev/null | grep "TeamViewer ID:" | awk '{print $3}')
  if [ -n "$TV_ID" ]; then
    print_info "TeamViewer ID: $TV_ID"
  fi
fi

# If NinjaOne was installed, show confirmation
if systemctl status ninjarmm-agent &>/dev/null; then
  echo ""
  print_info "NinjaOne Agent has been installed and is running."
  print_info "The device should appear in your NinjaOne dashboard shortly."
fi
