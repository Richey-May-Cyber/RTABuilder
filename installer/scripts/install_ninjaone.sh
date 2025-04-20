#!/bin/bash
# NinjaOne Agent Installer with advanced configuration for Kali Linux

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
NINJA_PACKAGE="/opt/security-tools/downloads/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb"
NINJA_URL="https://app.ninjarmm.com/agent/installer/fc75fb12-9ee2-4f8d-8319-8df4493a9fb9/8.0.2891/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb"
SERVICE_NAME="ninjarmm-agent"
AGENT_DIR="/opt/NinjaRMMAgent"
PRIMARY_USERNAME="rmcyber"  # The primary user of this system

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

# Create directory if it doesn't exist
mkdir -p "$(dirname "$NINJA_PACKAGE")"

# Check if the DEB package exists
if [ ! -f "$NINJA_PACKAGE" ]; then
  log "WARNING" "NinjaOne Agent package not found at $NINJA_PACKAGE"
  
  # Try to download it
  log "INFO" "Downloading NinjaOne Agent..."
  wget -q --show-progress "$NINJA_URL" -O "$NINJA_PACKAGE" || {
    log "ERROR" "Failed to download NinjaOne Agent package"
    log "INFO" "Please download the agent manually from your NinjaOne portal"
    exit 1
  }
fi

# Check if the agent is already installed
if [ -d "$AGENT_DIR" ] && systemctl is-active --quiet "$SERVICE_NAME"; then
  log "WARNING" "NinjaOne Agent is already installed and running"
  log "INFO" "To reinstall, first uninstall the current agent"
  
  read -p "Do you want to uninstall the current agent and reinstall? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "INFO" "Uninstalling current NinjaOne Agent..."
    
    # Stop and disable service
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    
    # Try to uninstall package
    if dpkg -l | grep -q "ninjarmm-agent"; then
      dpkg -r ninjarmm-agent
    fi
    
    # Clean up directories
    rm -rf "$AGENT_DIR"
    log "SUCCESS" "Uninstalled NinjaOne Agent"
  else
    log "INFO" "Keeping current installation"
    exit 0
  fi
fi

# Install prerequisites for Kali Linux
log "INFO" "Installing prerequisites..."
apt-get update
apt-get install -y libc6 libstdc++6 zlib1g libgcc1 libssl1.1 libxcb-xinerama0 || {
  log "WARNING" "Some prerequisites couldn't be installed. Trying alternatives..."
  # On newer Kali versions, libssl1.1 might be replaced by libssl3
  apt-get install -y libc6 libstdc++6 zlib1g libgcc1 libssl3 libxcb-xinerama0
}

# Install NinjaOne Agent
log "STATUS" "Installing NinjaOne Agent..."
dpkg -i "$NINJA_PACKAGE" || {
  log "INFO" "Fixing dependencies..."
  apt-get -f install -y
  dpkg -i "$NINJA_PACKAGE" || {
    log "ERROR" "Failed to install NinjaOne Agent"
    exit 1
  }
}

# Additional setup for Kali Linux compatibility
log "INFO" "Performing additional setup for Kali Linux..."

# Ensure agent directory has correct permissions
if [ -d "$AGENT_DIR" ]; then
  chmod -R 755 "$AGENT_DIR"
  chown -R root:root "$AGENT_DIR"
fi

# Make sure the service is enabled and started
log "INFO" "Configuring and starting the NinjaOne Agent service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify service is running
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "SUCCESS" "NinjaOne Agent service is running"
else
  log "WARNING" "NinjaOne Agent service is not running, attempting to fix..."
  
  # Try to fix any issues
  systemctl stop "$SERVICE_NAME"
  sleep 2
  systemctl start "$SERVICE_NAME"
  
  # Check again
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "SUCCESS" "NinjaOne Agent service is now running"
  else
    log "ERROR" "Failed to start NinjaOne Agent service"
    systemctl status "$SERVICE_NAME"
  fi
fi

# Create desktop notification widget
if [ -d "/usr/share/applications" ]; then
  log "INFO" "Creating NinjaOne status widget..."
  
  cat > "/usr/share/applications/ninjaone-status.desktop" << DESKTOP
[Desktop Entry]
Name=NinjaOne Status
Comment=Check NinjaOne Agent Status
Exec=x-terminal-emulator -e "bash -c 'echo \"NinjaOne Agent Status\"; echo \"-------------------\"; systemctl status ninjarmm-agent; echo; echo \"Press Enter to exit\"; read'"
Type=Application
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
DESKTOP

  # Also create for primary user
  if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME/.local/share/applications" ]; then
    cp "/usr/share/applications/ninjaone-status.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
    chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications/ninjaone-status.desktop"
  fi
  
  log "SUCCESS" "Created NinjaOne status widget"
fi

# Create troubleshooting script
log "INFO" "Creating troubleshooting script..."
cat > "/usr/local/bin/ninja-troubleshoot" << 'SCRIPT'
#!/bin/bash
# NinjaOne Troubleshooting Script

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root or with sudo${NC}"
  exit 1
fi

echo -e "${BLUE}=== NinjaOne Agent Troubleshooting ===${NC}"
echo

# Check service status
echo -e "${YELLOW}Checking service status:${NC}"
systemctl status ninjarmm-agent
echo

# Check connection
echo -e "${YELLOW}Checking connection to NinjaOne servers:${NC}"
if ping -c 3 app.ninjarmm.com &>/dev/null; then
  echo -e "${GREEN}Connection to app.ninjarmm.com successful${NC}"
else
  echo -e "${RED}Cannot connect to app.ninjarmm.com${NC}"
  echo -e "${YELLOW}Checking DNS resolution:${NC}"
  nslookup app.ninjarmm.com
  echo
  echo -e "${YELLOW}Checking route to NinjaOne servers:${NC}"
  traceroute -T -p 443 app.ninjarmm.com
fi
echo

# Check logs
echo -e "${YELLOW}Recent logs from NinjaOne Agent:${NC}"
if [ -d "/opt/NinjaRMMAgent/logs" ]; then
  tail -n 20 /opt/NinjaRMMAgent/logs/agent.log
else
  echo -e "${RED}Log directory not found${NC}"
fi
echo

# Restart option
echo -e "${YELLOW}Options:${NC}"
echo "1) Restart NinjaOne Agent"
echo "2) Reinstall NinjaOne Agent"
echo "3) Exit"
read -p "Select an option: " option

case $option in
  1)
    echo -e "${BLUE}Restarting NinjaOne Agent...${NC}"
    systemctl restart ninjarmm-agent
    sleep 2
    systemctl status ninjarmm-agent
    ;;
  2)
    echo -e "${BLUE}To reinstall, run:${NC}"
    echo "sudo /opt/security-tools/helpers/install_ninjaone.sh"
    ;;
  *)
    echo -e "${BLUE}Exiting.${NC}"
    ;;
esac
SCRIPT

chmod +x "/usr/local/bin/ninja-troubleshoot"
log "SUCCESS" "Created troubleshooting script at /usr/local/bin/ninja-troubleshoot"

# Set system information
if [ -n "$PRIMARY_USERNAME" ]; then
  log "INFO" "Setting system information..."
  
  # Create a custom system info file that NinjaOne can read
  cat > "/etc/ninjaone-sysinfo" << EOF
PRIMARY_USER=$PRIMARY_USERNAME
DEVICE_TYPE=Kali Linux Penetration Testing Device
ORGANIZATION=Pentesting Team
LOCATION=Main Office
EOF
  
  chmod 644 "/etc/ninjaone-sysinfo"
  log "SUCCESS" "Set system information for NinjaOne Agent"
fi

log "SUCCESS" "NinjaOne Agent installation and configuration completed"
log "INFO" "To check status, run: systemctl status ninjarmm-agent"
log "INFO" "For troubleshooting, run: sudo ninja-troubleshoot"
exit 0
