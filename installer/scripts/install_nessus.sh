#!/bin/bash
# Nessus Installation Script with enhanced download verification and configuration

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[i] Starting Nessus installation...${NC}"

# Verify and download the Nessus package
NESSUS_PKG="/opt/security-tools/downloads/Nessus-10.5.0-debian10_amd64.deb"
NESSUS_URL="https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true"
NESSUS_SERVICE="nessusd"
PRIMARY_USERNAME="rmcyber"

# Create download directory if it doesn't exist
mkdir -p "$(dirname "$NESSUS_PKG")"

# Check if Nessus is already installed
if dpkg -l | grep -q "^ii.*nessus" || [ -d "/opt/nessus" ]; then
  echo -e "${YELLOW}[!] Nessus appears to be already installed${NC}"
  
  # Check if service is running
  if systemctl is-active --quiet "$NESSUS_SERVICE"; then
    echo -e "${GREEN}[+] Nessus is running. Access it at: https://localhost:8834/${NC}"
    
    # Ask if user wants to reinstall
    read -p "Do you want to reinstall Nessus? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${BLUE}[i] Keeping existing installation${NC}"
      exit 0
    fi
    
    echo -e "${YELLOW}[!] Stopping and removing existing Nessus installation...${NC}"
    systemctl stop "$NESSUS_SERVICE"
    apt-get remove -y nessus
    rm -rf /opt/nessus
  fi
fi

# Check if the DEB package exists and is valid
if [ ! -f "$NESSUS_PKG" ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] Nessus package not found or invalid, downloading again...${NC}"
  
  # Use wget with proper headers to get a valid download
  echo -e "${YELLOW}[*] Downloading Nessus...${NC}"
  wget --content-disposition --header="Accept: application/x-debian-package" \
       --header="User-Agent: Mozilla/5.0 (X11; Linux x86_64)" \
       "$NESSUS_URL" -O "$NESSUS_PKG" || {
    echo -e "${RED}[-] Failed to download Nessus from Tenable's site.${NC}"
    
    # Try alternative approach - direct download from Tenable server
    echo -e "${YELLOW}[!] Trying alternative download approach...${NC}"
    wget --content-disposition "https://www.tenable.com/downloads/nessus?direct=true" -O "$NESSUS_PKG" || {
      echo -e "${RED}[-] All download attempts failed. Please download manually from Tenable's website.${NC}"
      exit 1
    }
  }
  
  # Verify the downloaded file is a valid Debian package
  if ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
    echo -e "${RED}[-] Downloaded file is not a valid Debian package.${NC}"
    echo -e "${YELLOW}[!] The downloaded file might be an HTML page or an error response.${NC}"
    echo -e "${YELLOW}[!] Please download Nessus manually from: https://www.tenable.com/downloads/nessus${NC}"
    exit 1
  fi
fi

# Install Nessus
echo -e "${YELLOW}[*] Installing Nessus...${NC}"
apt-get update
dpkg -i "$NESSUS_PKG" || {
  echo -e "${YELLOW}[!] Fixing dependencies...${NC}"
  apt-get -f install -y
  dpkg -i "$NESSUS_PKG" || {
    echo -e "${RED}[-] Failed to install Nessus${NC}"
    exit 1
  }
}

# Start and enable Nessus service
echo -e "${YELLOW}[*] Starting Nessus service...${NC}"
systemctl start "$NESSUS_SERVICE"
systemctl enable "$NESSUS_SERVICE"

# Create desktop entry
mkdir -p "/usr/share/applications"
cat > "/usr/share/applications/nessus.desktop" << DESKTOP
[Desktop Entry]
Name=Nessus Vulnerability Scanner
GenericName=Vulnerability Scanner
Comment=Scan systems for vulnerabilities
Exec=xdg-open https://localhost:8834/
Icon=/opt/nessus/var/nessus/www/favicon.ico
Terminal=false
Type=Application
Categories=Security;Network;
Keywords=scan;security;vulnerability;
DESKTOP

# Create desktop entry for the specific user if exists
if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME" ]; then
  mkdir -p "/home/$PRIMARY_USERNAME/.local/share/applications"
  cp "/usr/share/applications/nessus.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
  
  # Create desktop shortcut
  if [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
    cp "/usr/share/applications/nessus.desktop" "/home/$PRIMARY_USERNAME/Desktop/"
    chmod +x "/home/$PRIMARY_USERNAME/Desktop/nessus.desktop"
  fi
  
  # Fix ownership
  chown -R "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications"
  if [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
    chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/Desktop/nessus.desktop"
  fi
fi

# Create configuration helper script
cat > "/usr/local/bin/nessus-config" << 'CONFIG_SCRIPT'
#!/bin/bash
# Nessus Configuration Helper Script

# Colors
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

echo -e "${BLUE}=== Nessus Configuration Helper ===${NC}"
echo

# Check service status
echo -e "${YELLOW}Checking Nessus service status:${NC}"
systemctl status nessusd
echo

# Configuration menu
echo -e "${YELLOW}Options:${NC}"
echo "1) Start Nessus"
echo "2) Stop Nessus"
echo "3) Restart Nessus"
echo "4) Reset admin password"
echo "5) Change listening port (default: 8834)"
echo "6) Check logs"
echo "7) Check updates"
echo "8) Exit"

read -p "Select an option: " option

case $option in
  1)
    echo -e "${BLUE}Starting Nessus...${NC}"
    systemctl start nessusd
    sleep 2
    systemctl status nessusd
    ;;
  2)
    echo -e "${BLUE}Stopping Nessus...${NC}"
    systemctl stop nessusd
    sleep 2
    systemctl status nessusd
    ;;
  3)
    echo -e "${BLUE}Restarting Nessus...${NC}"
    systemctl restart nessusd
    sleep 2
    systemctl status nessusd
    ;;
  4)
    echo -e "${BLUE}Resetting admin password...${NC}"
    /opt/nessus/sbin/nessuscli user password admin
    ;;
  5)
    echo -e "${BLUE}Changing listening port...${NC}"
    read -p "Enter new port number: " port
    if [[ "$port" =~ ^[0-9]+$ && "$port" -gt 1024 && "$port" -lt 65536 ]]; then
      /opt/nessus/sbin/nessuscli fix --set listen_port="$port"
      echo -e "${GREEN}Port changed to $port. Restarting Nessus...${NC}"
      systemctl restart nessusd
    else
      echo -e "${RED}Invalid port number. Please use a port between 1025 and 65535.${NC}"
    fi
    ;;
  6)
    echo -e "${BLUE}Last 50 lines of Nessus logs:${NC}"
    tail -n 50 /opt/nessus/var/nessus/logs/nessusd.messages
    ;;
  7)
    echo -e "${BLUE}Checking for Nessus updates:${NC}"
    /opt/nessus/sbin/nessuscli update --check
    ;;
  *)
    echo -e "${BLUE}Exiting.${NC}"
    ;;
esac
CONFIG_SCRIPT

chmod +x "/usr/local/bin/nessus-config"

# Create startup check/notification
cat > "/etc/profile.d/nessus-check.sh" << 'PROFILE_SCRIPT'
#!/bin/bash
# Display Nessus status notification on login

# Only run for interactive shells
if [[ $- == *i* ]] && [ "$EUID" != "0" ]; then
  if systemctl is-active --quiet nessusd; then
    echo -e "\033[0;32m[✓] Nessus is running - Access at: https://localhost:8834/\033[0m"
  else
    echo -e "\033[0;33m[!] Nessus is not running - Start with: sudo systemctl start nessusd\033[0m"
  fi
fi
PROFILE_SCRIPT

chmod +x "/etc/profile.d/nessus-check.sh"

# Check service status
if systemctl is-active --quiet "$NESSUS_SERVICE"; then
  echo -e "${GREEN}[+] Nessus installed and service started successfully${NC}"
  echo -e "${BLUE}[i] Access Nessus at: https://localhost:8834/${NC}"
  echo -e "${BLUE}[i] Complete setup by creating an account and activating your license${NC}"
  echo -e "${BLUE}[i] For configuration options, run: sudo nessus-config${NC}"
else
  echo -e "${YELLOW}[!] Nessus installed but service not running. Try starting manually:${NC}"
  echo -e "${YELLOW}    systemctl start nessusd${NC}"
fi

exit 0
