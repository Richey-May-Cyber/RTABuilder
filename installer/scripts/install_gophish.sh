#!/bin/bash
# Gophish Installation Script with enhanced features and error handling

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting Gophish installation...${NC}"

# Installation directory
INSTALL_DIR="/opt/gophish"
DOWNLOAD_DIR="/opt/security-tools/downloads"
LOG_FILE="/tmp/gophish_install.log"
PRIMARY_USERNAME="rmcyber"

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Gophish version and URL
GOPHISH_VERSION="0.12.1"
GOPHISH_URL="https://github.com/gophish/gophish/releases/download/v$GOPHISH_VERSION/gophish-v$GOPHISH_VERSION-linux-64bit.zip"
GOPHISH_ZIP="$DOWNLOAD_DIR/gophish-v$GOPHISH_VERSION-linux-64bit.zip"

# Helper function for logging
log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

# Download Gophish
download_gophish() {
  log "${YELLOW}[*] Downloading Gophish v$GOPHISH_VERSION...${NC}"
  
  if [ -f "$GOPHISH_ZIP" ]; then
    log "${YELLOW}[!] Gophish ZIP already exists, using existing file...${NC}"
  else
    wget -q --show-progress "$GOPHISH_URL" -O "$GOPHISH_ZIP"
    
    if [ $? -ne 0 ]; then
      log "${RED}[-] Failed to download Gophish${NC}"
      return 1
    fi
  fi
  
  log "${GREEN}[+] Gophish downloaded successfully${NC}"
  return 0
}

# Extract and setup Gophish
setup_gophish() {
  log "${YELLOW}[*] Extracting Gophish...${NC}"
  
  # Check if unzip is installed
  if ! command -v unzip &>/dev/null; then
    log "${YELLOW}[!] unzip not found, installing...${NC}"
    apt-get update
    apt-get install -y unzip
  fi
  
  # Clean installation directory if it exists and force reinstall
  if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR")" ]; then
    log "${YELLOW}[!] Cleaning existing Gophish installation...${NC}"
    rm -rf "$INSTALL_DIR"/*
  fi
  
  # Extract the ZIP file
  unzip -qo "$GOPHISH_ZIP" -d "$INSTALL_DIR"
  
  if [ $? -ne 0 ]; then
    log "${RED}[-] Failed to extract Gophish${NC}"
    return 1
  fi
  
  # Set permissions
  log "${YELLOW}[*] Setting permissions...${NC}"
  chmod +x "$INSTALL_DIR/gophish"
  
  # Modify config to listen on all interfaces for admin
  log "${YELLOW}[*] Configuring Gophish to listen on all interfaces...${NC}"
  if [ -f "$INSTALL_DIR/config.json" ]; then
    # Create backup of original config
    cp "$INSTALL_DIR/config.json" "$INSTALL_DIR/config.json.bak"
    
    # Change admin interface to listen on all interfaces
    sed -i 's/"listen_url": "127.0.0.1:3333"/"listen_url": "0.0.0.0:3333"/g' "$INSTALL_DIR/config.json"
    
    # Optional: Change phishing server port if needed
    # sed -i 's/"listen_url": "0.0.0.0:80"/"listen_url": "0.0.0.0:8080"/g' "$INSTALL_DIR/config.json"
  else
    log "${RED}[-] Config file not found${NC}"
    return 1
  fi
  
  log "${GREEN}[+] Gophish extracted and configured successfully${NC}"
  return 0
}

# Create systemd service
create_service() {
  log "${YELLOW}[*] Creating systemd service...${NC}"
  
  cat > "/etc/systemd/system/gophish.service" << 'SERVICE'
[Unit]
Description=Gophish Phishing Framework
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gophish
ExecStart=/opt/gophish/gophish
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE
  
  # Reload systemd and enable service
  systemctl daemon-reload
  systemctl enable gophish.service
  
  log "${GREEN}[+] Gophish service created and enabled${NC}"
  return 0
}

# Create desktop shortcut
create_desktop_shortcut() {
  log "${YELLOW}[*] Creating desktop shortcuts...${NC}"
  
  # Admin interface
  cat > "/usr/share/applications/gophish-admin.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Gophish Admin
Comment=Gophish Admin Interface
Exec=xdg-open https://127.0.0.1:3333/
Type=Application
Icon=web-browser
Terminal=false
Categories=Security;Network;
Keywords=phishing;security;email;
DESKTOP

  # Phishing server status
  cat > "/usr/share/applications/gophish-server.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Gophish Server Status
Comment=Check Gophish Server Status
Exec=x-terminal-emulator -e "bash -c 'echo \"Gophish Server Status\"; echo \"-------------------\"; systemctl status gophish; echo; echo \"Press Enter to exit\"; read'"
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Security;Network;
DESKTOP

  # Gophish control panel
  cat > "/usr/share/applications/gophish-control.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Gophish Control Panel
Comment=Start/Stop Gophish Service
Exec=x-terminal-emulator -e "bash -c 'echo \"Gophish Service Control\"; echo \"-------------------\"; echo \"1) Start Gophish\"; echo \"2) Stop Gophish\"; echo \"3) Restart Gophish\"; echo \"4) Check Status\"; echo; read -p \"Select option: \" opt; case $opt in 1) sudo systemctl start gophish;; 2) sudo systemctl stop gophish;; 3) sudo systemctl restart gophish;; 4) sudo systemctl status gophish;; *) echo \"Invalid option\";; esac; echo; echo \"Press Enter to exit\"; read'"
Type=Application
Icon=utilities-system-monitor
Terminal=false
Categories=Security;Network;
DESKTOP

  # Create shortcuts for the specified user
  if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME" ]; then
    mkdir -p "/home/$PRIMARY_USERNAME/.local/share/applications"
    
    cp "/usr/share/applications/gophish-admin.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
    cp "/usr/share/applications/gophish-server.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
    cp "/usr/share/applications/gophish-control.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
    
    # Add to desktop if it exists
    if [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
      cp "/usr/share/applications/gophish-admin.desktop" "/home/$PRIMARY_USERNAME/Desktop/"
      chmod +x "/home/$PRIMARY_USERNAME/Desktop/gophish-admin.desktop"
    fi
    
    # Fix ownership
    chown -R "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications"
    [ -d "/home/$PRIMARY_USERNAME/Desktop" ] && chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/Desktop/gophish-admin.desktop"
  fi
  
  log "${GREEN}[+] Desktop shortcuts created${NC}"
  return 0
}

# Create CLI wrapper
create_cli_wrapper() {
  log "${YELLOW}[*] Creating CLI wrapper...${NC}"
  
  cat > "/usr/local/bin/gophish-cli" << 'WRAPPER'
#!/bin/bash
# Gophish CLI wrapper

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

GOPHISH_DIR="/opt/gophish"
CONFIG_FILE="$GOPHISH_DIR/config.json"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root or with sudo${NC}"
  exit 1
fi

case "$1" in
  "start")
    echo -e "${YELLOW}[*] Starting Gophish...${NC}"
    systemctl start gophish
    sleep 2
    if systemctl is-active --quiet gophish; then
      echo -e "${GREEN}[+] Gophish started successfully${NC}"
      echo -e "${BLUE}[i] Admin interface: https://127.0.0.1:3333/${NC}"
      echo -e "${BLUE}[i] Default credentials: admin:gophish${NC}"
    else
      echo -e "${RED}[-] Failed to start Gophish${NC}"
      systemctl status gophish
    fi
    ;;
  "stop")
    echo -e "${YELLOW}[*] Stopping Gophish...${NC}"
    systemctl stop gophish
    if ! systemctl is-active --quiet gophish; then
      echo -e "${GREEN}[+] Gophish stopped successfully${NC}"
    else
      echo -e "${RED}[-] Failed to stop Gophish${NC}"
      systemctl status gophish
    fi
    ;;
  "restart")
    echo -e "${YELLOW}[*] Restarting Gophish...${NC}"
    systemctl restart gophish
    sleep 2
    if systemctl is-active --quiet gophish; then
      echo -e "${GREEN}[+] Gophish restarted successfully${NC}"
      echo -e "${BLUE}[i] Admin interface: https://127.0.0.1:3333/${NC}"
    else
      echo -e "${RED}[-] Failed to restart Gophish${NC}"
      systemctl status gophish
    fi
    ;;
  "status")
    echo -e "${YELLOW}[*] Gophish status:${NC}"
    systemctl status gophish
    ;;
  "logs")
    echo -e "${YELLOW}[*] Gophish logs:${NC}"
    journalctl -u gophish -n 50
    ;;
  "config")
    echo -e "${YELLOW}[*] Current Gophish configuration:${NC}"
    cat "$CONFIG_FILE"
    
    echo
    echo -e "${YELLOW}[*] Configuration options:${NC}"
    echo "1) Edit config file"
    echo "2) Reset to default config"
    echo "3) Change admin interface port"
    echo "4) Change phishing server port"
    echo "5) Back to main menu"
    read -p "Select an option: " config_opt
    case $config_opt in
      1)
        nano "$CONFIG_FILE"
        echo -e "${GREEN}[+] Configuration updated${NC}"
        echo -e "${YELLOW}[*] Restart Gophish for changes to take effect${NC}"
        ;;
      2)
        if [ -f "$CONFIG_FILE.bak" ]; then
          cp "$CONFIG_FILE.bak" "$CONFIG_FILE"
          echo -e "${GREEN}[+] Configuration reset to default${NC}"
        else
          echo -e "${RED}[-] Backup configuration not found${NC}"
        fi
        ;;
      3)
        read -p "Enter new admin interface port: " admin_port
        if [[ "$admin_port" =~ ^[0-9]+$ ]]; then
          sed -i "s/\"listen_url\": \"0.0.0.0:[0-9]\+\"/\"listen_url\": \"0.0.0.0:$admin_port\"/g" "$CONFIG_FILE"
          echo -e "${GREEN}[+] Admin interface port changed to $admin_port${NC}"
          echo -e "${YELLOW}[*] Restart Gophish for changes to take effect${NC}"
        else
          echo -e "${RED}[-] Invalid port number${NC}"
        fi
        ;;
      4)
        read -p "Enter new phishing server port: " phish_port
        if [[ "$phish_port" =~ ^[0-9]+$ ]]; then
          sed -i "/\"phish_server\": {/,/}/s/\"listen_url\": \"0.0.0.0:[0-9]\+\"/\"listen_url\": \"0.0.0.0:$phish_port\"/g" "$CONFIG_FILE"
          echo -e "${GREEN}[+] Phishing server port changed to $phish_port${NC}"
          echo -e "${YELLOW}[*] Restart Gophish for changes to take effect${NC}"
        else
          echo -e "${RED}[-] Invalid port number${NC}"
        fi
        ;;
      *)
        echo -e "${BLUE}[i] Returning to main menu${NC}"
        ;;
    esac
    ;;
  *)
    echo -e "${BLUE}[i] Gophish CLI Wrapper${NC}"
    echo -e "${BLUE}[i] Usage: gophish-cli [command]${NC}"
    echo -e "${YELLOW}Commands:${NC}"
    echo "  start    - Start Gophish service"
    echo "  stop     - Stop Gophish service"
    echo "  restart  - Restart Gophish service"
    echo "  status   - Check Gophish service status"
    echo "  logs     - View Gophish logs"
    echo "  config   - Configure Gophish"
    echo
    echo -e "${BLUE}[i] Admin interface: https://127.0.0.1:3333/${NC}"
    echo -e "${BLUE}[i] Default credentials: admin:gophish${NC}"
    echo -e "${YELLOW}[!] Note: Remember to change the default password on first login${NC}"
    ;;
esac
WRAPPER
  
  chmod +x "/usr/local/bin/gophish-cli"
  
  log "${GREEN}[+] CLI wrapper created${NC}"
  return 0
}

# Start the service
start_service() {
  log "${YELLOW}[*] Starting Gophish service...${NC}"
  
  systemctl start gophish.service
  sleep 3
  
  if systemctl is-active --quiet gophish.service; then
    log "${GREEN}[+] Gophish service started successfully${NC}"
    return 0
  else
    log "${RED}[-] Failed to start Gophish service${NC}"
    systemctl status gophish.service
    return 1
  fi
}

# Create setup guide
create_setup_guide() {
  log "${YELLOW}[*] Creating setup guide...${NC}"
  
  mkdir -p "$INSTALL_DIR/docs"
  
  cat > "$INSTALL_DIR/docs/setup_guide.txt" << 'GUIDE'
==========================================================
                GOPHISH SETUP GUIDE
==========================================================

INITIAL ACCESS:
--------------
1. Access the admin interface at https://127.0.0.1:3333/
2. Default login credentials: admin:gophish
3. Change the default password immediately

CREATING A CAMPAIGN:
------------------
1. Set up Users & Groups (target lists)
2. Create Email Templates
3. Configure Landing Pages
4. Set up Sending Profiles
5. Create and Launch Campaigns

BASIC CONFIGURATION:
-----------------
- Admin Interface: Edit /opt/gophish/config.json to change the admin interface settings
- Phishing Server: Configure phishing server settings in the same config file
- HTTPS: By default, Gophish uses self-signed certificates. For production use, configure proper SSL/TLS

COMMON ISSUES:
------------
- SMTP Blocking: Many ISPs block outgoing SMTP traffic. Consider using an external SMTP relay
- SSL Errors: The admin interface uses self-signed certificates, which will cause browser warnings
- Landing Page Issues: Ensure your landing pages match the target site's design

COMMANDS:
--------
- Start Gophish: sudo systemctl start gophish
- Stop Gophish: sudo systemctl stop gophish
- Restart Gophish: sudo systemctl restart gophish
- Check Status: sudo systemctl status gophish
- CLI Wrapper: sudo gophish-cli [command]

SECURITY CONSIDERATIONS:
---------------------
- Gophish is a powerful tool designed for legitimate security testing
- Always have proper authorization before conducting phishing campaigns
- Document your activities and maintain a professional approach
- Ensure compliance with relevant laws and regulations

For more information, visit: https://getgophish.com/documentation/
==========================================================
GUIDE

  # Create a desktop shortcut to the guide
  cat > "/usr/share/applications/gophish-guide.desktop" << DESKTOP_GUIDE
[Desktop Entry]
Name=Gophish Setup Guide
Comment=Instructions for setting up and using Gophish
Exec=xdg-open /opt/gophish/docs/setup_guide.txt
Type=Application
Icon=text-x-generic
Terminal=false
Categories=Security;Documentation;
DESKTOP_GUIDE

  # Copy to user's desktop if specified
  if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
    cp "/usr/share/applications/gophish-guide.desktop" "/home/$PRIMARY_USERNAME/Desktop/"
    chmod +x "/home/$PRIMARY_USERNAME/Desktop/gophish-guide.desktop"
    chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/Desktop/gophish-guide.desktop"
  fi
  
  log "${GREEN}[+] Setup guide created${NC}"
  return 0
}

# Main installation process
main() {
  log "${BLUE}[i] Gophish Installation Script${NC}"
  log "${BLUE}[i] -----------------------${NC}"
  
  # Check if running as root
  if [ "$EUID" -ne 0 ]; then
    log "${RED}[-] Please run as root${NC}"
    exit 1
  fi
  
  # Download Gophish
  download_gophish || {
    log "${RED}[-] Failed to download Gophish, cannot continue${NC}"
    exit 1
  }
  
  # Extract and setup
  setup_gophish || {
    log "${RED}[-] Failed to setup Gophish, cannot continue${NC}"
    exit 1
  }
  
  # Create systemd service
  create_service
  
  # Create desktop shortcut
  create_desktop_shortcut
  
  # Create CLI wrapper
  create_cli_wrapper
  
  # Create setup guide
  create_setup_guide
  
  # Start service
  start_service
  
  log "${GREEN}[+] Gophish installation completed successfully!${NC}"
  log "${BLUE}[i] Access the admin interface at:${NC} https://127.0.0.1:3333/"
  log "${BLUE}[i] Default credentials:${NC} admin:gophish"
  log "${BLUE}[i] Note: On first login, you'll be prompted to change the default password.${NC}"
  log "${BLUE}[i] Use 'gophish-cli' command to control the service.${NC}"
  
  return 0
}

# Run main function
main
exit $?
