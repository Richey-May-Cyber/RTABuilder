#!/bin/bash
# Standalone Nessus Installation Script

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Define helper functions
echo_status() {
  echo -e "${BLUE}[*] $1${NC}"
}

echo_success() {
  echo -e "${GREEN}[+] $1${NC}"
}

echo_error() {
  echo -e "${RED}[-] $1${NC}"
}

echo_info() {
  echo -e "${BLUE}[i] $1${NC}"
}

echo_warning() {
  echo -e "${YELLOW}[!] $1${NC}"
}

# Custom timeout function
run_command_with_timeout() {
  local cmd="$1"
  local timeout="$2"
  local log_file="$3"
  
  # Create log directory if it doesn't exist
  mkdir -p "$(dirname "$log_file")"
  
  # Run the command with timeout
  timeout "$timeout" bash -c "$cmd" > "$log_file" 2>&1
  return $?
}

# Define variables
TOOLS_DIR="/opt/security-tools/downloads"
LOG_DIR="/var/log/security-tools"
NESSUS_VERSION="10.8.4"
NESSUS_PKG="Nessus-${NESSUS_VERSION}-ubuntu1604_amd64.deb"
NESSUS_URL="https://www.tenable.com/downloads/api/v2/pages/nessus/files/${NESSUS_PKG}"
NESSUS_SERVICE="nessusd"
PRIMARY_USERNAME="rmcyber"

# Create directories
mkdir -p "$TOOLS_DIR"
mkdir -p "$LOG_DIR"

echo_status "Installing Nessus..."

# Check if Nessus is already installed
if dpkg -l | grep -q "^ii.*nessus" || [ -d "/opt/nessus" ]; then
  echo_warning "Nessus appears to be already installed"
  
  # Check if service is running
  if systemctl is-active --quiet "$NESSUS_SERVICE"; then
    echo_success "Nessus is running. Access it at: https://localhost:8834/"
    
    # Ask if user wants to reinstall
    read -p "Do you want to reinstall Nessus? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo_info "Keeping existing installation"
      exit 0
    fi
    
    echo_warning "Stopping and removing existing Nessus installation..."
    systemctl stop "$NESSUS_SERVICE" >> "$LOG_DIR/nessus_uninstall.log" 2>&1
    apt-get remove -y nessus >> "$LOG_DIR/nessus_uninstall.log" 2>&1
    rm -rf /opt/nessus >> "$LOG_DIR/nessus_uninstall.log" 2>&1
  fi
fi

# Change to the tools directory
cd "$TOOLS_DIR"

# Try direct download with curl first
echo_status "Attempting to download Nessus with curl..."
run_command_with_timeout "curl -k --request GET --url '$NESSUS_URL' --output $NESSUS_PKG" 300 "$LOG_DIR/nessus_download.log"

# Check if download succeeded and is a valid package
if [ $? -eq 0 ] && [ -f "$NESSUS_PKG" ] && dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
    echo_success "Download successful. Installing Nessus package..."
else
    echo_error "Direct download failed or invalid package. Trying alternative download method..."
    
    # Try using wget with additional headers as an alternative
    echo_status "Trying alternative download with wget..."
    run_command_with_timeout "wget --no-check-certificate --content-disposition --header=\"Accept: application/x-debian-package\" --header=\"User-Agent: Mozilla/5.0 (X11; Linux x86_64)\" '$NESSUS_URL' -O $NESSUS_PKG" 300 "$LOG_DIR/nessus_alt_download.log"
    
    # If that fails, try another approach
    if [ $? -ne 0 ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
        echo_error "Alternative download also failed. Trying direct download from Tenable..."
        
        # Try one more approach - direct download
        run_command_with_timeout "wget --no-check-certificate \"https://www.tenable.com/downloads/nessus?direct=true\" -O $NESSUS_PKG" 300 "$LOG_DIR/nessus_direct_download.log"
        
        # Final check
        if [ $? -ne 0 ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
            echo_error "All download attempts failed. Please download Nessus manually from Tenable's website."
            exit 1
        fi
    fi
fi

# Install Nessus
echo_status "Installing Nessus package..."
apt-get update >> "$LOG_DIR/nessus_install.log" 2>&1
dpkg -i "$NESSUS_PKG" >> "$LOG_DIR/nessus_install.log" 2>&1

# Fix dependencies if needed
if [ $? -ne 0 ]; then
    echo_warning "Fixing dependencies..."
    apt-get install -f -y >> "$LOG_DIR/nessus_install.log" 2>&1
    dpkg -i "$NESSUS_PKG" >> "$LOG_DIR/nessus_install.log" 2>&1
    
    if [ $? -ne 0 ]; then
        echo_error "Failed to install Nessus"
        exit 1
    fi
fi

# Start and enable Nessus service
echo_status "Starting Nessus service..."
systemctl enable nessusd >> "$LOG_DIR/nessus_install.log" 2>&1
systemctl start nessusd >> "$LOG_DIR/nessus_install.log" 2>&1

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

# Create configuration helper script - optional but useful
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

# Check if service is running properly
if systemctl is-active --quiet "$NESSUS_SERVICE"; then
  echo_success "Nessus installed and service started successfully"
  echo_info "Access Nessus at: https://localhost:8834/"
  echo_info "Complete setup by creating an account and activating your license"
  echo_info "For configuration options, run: sudo nessus-config"
else
  echo_warning "Nessus installed but service not running. Try starting manually:"
  echo_info "systemctl start nessusd"
fi

# Clean up
rm -f "$NESSUS_PKG"

echo_success "Nessus installation completed"
exit 0
