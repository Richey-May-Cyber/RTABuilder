#!/bin/bash
# Nessus Installation Script with enhanced download verification and configuration

# Colors and logging functions (assuming these are defined elsewhere in your main script)
# If not, uncomment these definitions:
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# RED='\033[0;31m'
# BLUE='\033[0;34m'
# NC='\033[0m' # No Color

# Define variables
TOOLS_DIR="$TOOLS_DIR"  # This should be set in your main script
LOG_DIR="$LOG_DIR"      # This should be set in your main script
NESSUS_VERSION="10.8.3"
NESSUS_PKG="Nessus-${NESSUS_VERSION}-debian10_amd64.deb"
NESSUS_URL="https://www.tenable.com/downloads/api/v2/pages/nessus/files/${NESSUS_PKG}"
NESSUS_SERVICE="nessusd"
PRIMARY_USERNAME="rmcyber"  # Change this to your preferred username if needed

print_status "Installing Nessus..."

# Check if Nessus is already installed
if dpkg -l | grep -q "^ii.*nessus" || [ -d "/opt/nessus" ]; then
  print_status "Nessus appears to be already installed"
  
  # Check if service is running
  if systemctl is-active --quiet "$NESSUS_SERVICE"; then
    print_success "Nessus is running. Access it at: https://localhost:8834/"
    
    # Ask if user wants to reinstall
    read -p "Do you want to reinstall Nessus? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_info "Keeping existing installation"
      log_result "nessus" "SKIPPED" "Already installed and running"
      exit 0
    fi
    
    print_status "Stopping and removing existing Nessus installation..."
    systemctl stop "$NESSUS_SERVICE" >> "$LOG_DIR/nessus_uninstall.log" 2>&1
    apt-get remove -y nessus >> "$LOG_DIR/nessus_uninstall.log" 2>&1
    rm -rf /opt/nessus >> "$LOG_DIR/nessus_uninstall.log" 2>&1
  fi
fi

# Create download directory if necessary
mkdir -p "$TOOLS_DIR"
cd "$TOOLS_DIR"

# Try direct download with curl first
print_status "Attempting to download Nessus..."
run_with_timeout "curl -k --request GET --url '$NESSUS_URL' --output $NESSUS_PKG" 300 "$LOG_DIR/nessus_download.log" "nessus"

# Check if download succeeded and is a valid package
if [ $? -eq 0 ] && [ -f "$NESSUS_PKG" ] && dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
    print_status "Download successful. Installing Nessus package..."
else
    print_error "Direct download failed or invalid package. Trying alternative download method..."
    
    # Try using wget with additional headers as an alternative
    run_with_timeout "wget --no-check-certificate --content-disposition --header=\"Accept: application/x-debian-package\" --header=\"User-Agent: Mozilla/5.0 (X11; Linux x86_64)\" '$NESSUS_URL' -O $NESSUS_PKG" 300 "$LOG_DIR/nessus_alt_download.log" "nessus"
    
    # If that fails, try another approach
    if [ $? -ne 0 ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
        print_error "Alternative download also failed. Trying direct download from Tenable..."
        
        # Try a different URL format - direct download
        run_with_timeout "wget --no-check-certificate \"https://www.tenable.com/downloads/nessus?direct=true\" -O $NESSUS_PKG" 300 "$LOG_DIR/nessus_direct_download.log" "nessus"
        
        # Final check
        if [ $? -ne 0 ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
            print_error "All download attempts failed. Please download Nessus manually from Tenable's website."
            log_result "nessus" "FAILED" "Download failed"
            exit 1
        fi
    fi
fi

# Install Nessus
print_status "Installing Nessus package..."
apt-get update >> "$LOG_DIR/nessus_install.log" 2>&1
dpkg -i "$NESSUS_PKG" >> "$LOG_DIR/nessus_install.log" 2>&1

# Fix dependencies if needed
if [ $? -ne 0 ]; then
    print_status "Fixing dependencies..."
    apt-get install -f -y >> "$LOG_DIR/nessus_install.log" 2>&1
    dpkg -i "$NESSUS_PKG" >> "$LOG_DIR/nessus_install.log" 2>&1
    
    if [ $? -ne 0 ]; then
        print_error "Failed to install Nessus"
        log_result "nessus" "FAILED" "Installation failed"
        exit 1
    fi
fi

# Start and enable Nessus service
print_status "Starting Nessus service..."
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

# Check if service is running properly
if systemctl is-active --quiet "$NESSUS_SERVICE"; then
  print_success "Nessus installed and service started successfully"
  print_info "Access Nessus at: https://localhost:8834/"
  print_info "Complete setup by creating an account and activating your license"
  print_info "For configuration options, run: sudo nessus-config"
  log_result "nessus" "SUCCESS" "Installed and service started. Complete setup at https://localhost:8834/"
else
  print_warning "Nessus installed but service not running. Try starting manually:"
  print_info "systemctl start nessusd"
  log_result "nessus" "WARNING" "Installed but service failed to start"
fi

# Clean up
rm -f "$NESSUS_PKG"

exit 0
