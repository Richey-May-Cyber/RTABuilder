#!/bin/bash
# Burp Suite Professional Installer with enhanced configuration for Kali Linux

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting Burp Suite Professional installation...${NC}"

# Configuration Variables
BURP_DIR="/opt/BurpSuitePro"
DOWNLOAD_DIR="/opt/security-tools/downloads"
PRIMARY_USERNAME="rmcyber" # The primary user of this system
BURP_JAR="$DOWNLOAD_DIR/burpsuite_pro.jar"

# Create directories if they don't exist
mkdir -p "$BURP_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Check if Burp Suite Pro is already installed
if [ -f "$BURP_DIR/burpsuite_pro.jar" ]; then
  echo -e "${YELLOW}[!] Burp Suite Professional appears to be already installed.${NC}"
  read -p "Do you want to reinstall or update? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[i] Keeping existing installation${NC}"
    exit 0
  fi
fi

# Look for Burp Suite installer in common locations
BURP_INSTALLER=""
for location in "$DOWNLOAD_DIR" "/home/$PRIMARY_USERNAME/Downloads" "/home/$PRIMARY_USERNAME/Desktop"; do
  if [ -d "$location" ]; then
    FOUND_INSTALLER=$(find "$location" -maxdepth 1 -name "burpsuite_pro*.jar" -o -name "burpsuite_professional*.jar" | head -1)
    if [ -n "$FOUND_INSTALLER" ]; then
      BURP_INSTALLER="$FOUND_INSTALLER"
      break
    fi
  fi
done

# If no installer found, download it
if [ -z "$BURP_INSTALLER" ]; then
  echo -e "${YELLOW}[!] No Burp Suite Professional installer found.${NC}"
  
  # Ask for the Burp Suite Pro download URL or path
  echo -e "${YELLOW}[!] Please provide the Burp Suite Professional JAR file${NC}"
  echo -e "${YELLOW}[!] You can download it from your PortSwigger account${NC}"
  
  read -p "Would you like to provide a download URL for Burp Suite Pro? (y/N) " -n 1 -r
  echo
  
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter the download URL: " BURP_URL
    
    if [ -n "$BURP_URL" ]; then
      echo -e "${YELLOW}[*] Downloading Burp Suite Professional...${NC}"
      wget -q --show-progress "$BURP_URL" -O "$BURP_JAR" || {
        echo -e "${RED}[-] Failed to download Burp Suite Professional${NC}"
        echo -e "${YELLOW}[!] Please download it manually from your PortSwigger account${NC}"
        exit 1
      }
      BURP_INSTALLER="$BURP_JAR"
    else
      echo -e "${RED}[-] No URL provided${NC}"
      exit 1
    fi
  else
    # Ask for file path
    read -p "Please drag & drop or enter the full path to the Burp Suite Pro JAR file: " BURP_PATH
    
    if [ -f "$BURP_PATH" ]; then
      echo -e "${YELLOW}[*] Using provided JAR file: $BURP_PATH${NC}"
      BURP_INSTALLER="$BURP_PATH"
    else
      echo -e "${RED}[-] Invalid file path provided: $BURP_PATH${NC}"
      exit 1
    fi
  fi
fi

# Verify Java is installed
if ! command -v java &>/dev/null; then
  echo -e "${YELLOW}[*] Java not found. Installing Java...${NC}"
  apt-get update
  apt-get install -y default-jre || {
    echo -e "${RED}[-] Failed to install Java${NC}"
    exit 1
  }
fi

# Install Burp Suite Pro
echo -e "${YELLOW}[*] Installing Burp Suite Professional...${NC}"

# Copy the JAR file to the installation directory
cp "$BURP_INSTALLER" "$BURP_DIR/burpsuite_pro.jar"
chmod +x "$BURP_DIR/burpsuite_pro.jar"

# Create activation helper script for license handling
cat > "$BURP_DIR/activate_burp.sh" << 'EOL'
#!/bin/bash
# Burp Suite Pro Activation Helper

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

BURP_DIR="/opt/BurpSuitePro"
LICENSE_FILE="$BURP_DIR/license.txt"

# Check if desktop entry exists and Burp can be launched
if [ ! -f "/usr/bin/burpsuite" ]; then
  echo -e "${RED}[-] Burp Suite executable not found${NC}"
  exit 1
fi

# Option to manually activate
echo -e "${BLUE}=== Burp Suite Professional Activation Helper ===${NC}"
echo
echo -e "${YELLOW}[!] To activate Burp Suite Professional:${NC}"
echo "1) Launch Burp Suite and select 'Manual Activation'"
echo "2) Copy the activation request text and save it to a file"
echo "3) Go to your PortSwigger account and generate a license key"
echo "4) Copy the license key response and save it here"
echo

read -p "Do you want to launch Burp Suite now? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo -e "${YELLOW}[*] Launching Burp Suite Professional...${NC}"
  java -jar "$BURP_DIR/burpsuite_pro.jar" &
fi

# Option to save license key
read -p "Do you want to save a license key to a file for future use? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}[*] Please paste your license key below and press Ctrl+D when done:${NC}"
  cat > "$LICENSE_FILE"
  
  if [ -s "$LICENSE_FILE" ]; then
    echo -e "${GREEN}[+] License key saved to $LICENSE_FILE${NC}"
    chmod 600 "$LICENSE_FILE"  # Restrict permissions
  else
    echo -e "${RED}[-] No license key was saved${NC}"
    rm -f "$LICENSE_FILE"
  fi
fi

echo -e "${GREEN}[+] Done. You can activate Burp Suite Professional manually or using the saved license key.${NC}"
EOL

chmod +x "$BURP_DIR/activate_burp.sh"

# Create wrapper script
cat > "/usr/bin/burpsuite" << EOL
#!/bin/bash
# Burp Suite Professional Wrapper Script

# Use more memory for large projects
java -Xmx2g -jar "$BURP_DIR/burpsuite_pro.jar" "\$@"
EOL

chmod +x "/usr/bin/burpsuite"

# Create desktop entry
cat > "/usr/share/applications/burpsuite_pro.desktop" << EOL
[Desktop Entry]
Name=Burp Suite Professional
GenericName=Web Security Tool
Comment=Integrated platform for performing security testing of web applications
Exec=burpsuite %U
Icon=burpsuite
Terminal=false
Type=Application
Categories=Security;Application;Network;
Keywords=security;web;scanner;proxy;
EOL

# Create desktop shortcut for specified user
if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME" ]; then
  mkdir -p "/home/$PRIMARY_USERNAME/.local/share/applications"
  cp "/usr/share/applications/burpsuite_pro.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
  
  # Also add to desktop
  if [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
    cp "/usr/share/applications/burpsuite_pro.desktop" "/home/$PRIMARY_USERNAME/Desktop/"
    chmod +x "/home/$PRIMARY_USERNAME/Desktop/burpsuite_pro.desktop"
  fi
  
  # Fix ownership
  chown -R "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications"
  [ -d "/home/$PRIMARY_USERNAME/Desktop" ] && chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/Desktop/burpsuite_pro.desktop"
  
  echo -e "${GREEN}[+] Desktop shortcuts created for $PRIMARY_USERNAME${NC}"
fi

# Create a simple icon if not present
if [ ! -f "/usr/share/icons/hicolor/256x256/apps/burpsuite.png" ]; then
  mkdir -p "/usr/share/icons/hicolor/256x256/apps"
  
  # Use system icon or create a placeholder
  if [ -f "/usr/share/icons/hicolor/256x256/apps/org.gnome.Network.png" ]; then
    cp "/usr/share/icons/hicolor/256x256/apps/org.gnome.Network.png" "/usr/share/icons/hicolor/256x256/apps/burpsuite.png"
  elif [ -f "/usr/share/icons/hicolor/256x256/apps/web-browser.png" ]; then
    cp "/usr/share/icons/hicolor/256x256/apps/web-browser.png" "/usr/share/icons/hicolor/256x256/apps/burpsuite.png"
  fi
fi

# Set up Firefox configurations for Burp proxying
if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME/.mozilla" ]; then
  echo -e "${YELLOW}[*] Setting up Firefox proxy configurations...${NC}"
  
  # Create Firefox proxy toggle scripts
  mkdir -p "/home/$PRIMARY_USERNAME/bin"
  
  # Script to enable Burp proxy
  cat > "/home/$PRIMARY_USERNAME/bin/burp-proxy-on.sh" << 'PROXY_ON'
#!/bin/bash
# Enable Burp Suite proxy for Firefox

# Colors
GREEN="\033[0;32m"
NC="\033[0m" # No Color

# Kill Firefox if it's running
pkill -f firefox

sleep 1

# Start Firefox with Burp proxy
firefox -P default --new-instance -no-remote \
  -preferences \
  -purgecaches \
  --setDefaultBrowser \
  -url "about:config" &

sleep 2

# Notify the user
echo -e "${GREEN}Firefox started with Burp proxy (127.0.0.1:8080)${NC}"
echo "Please confirm the 'Accept the Risk and Continue' prompt if shown"
echo "The proxy settings will persist until Firefox is restarted normally"
PROXY_ON

  # Script to disable Burp proxy
  cat > "/home/$PRIMARY_USERNAME/bin/burp-proxy-off.sh" << 'PROXY_OFF'
#!/bin/bash
# Disable Burp Suite proxy for Firefox

# Colors
GREEN="\033[0;32m"
NC="\033[0m" # No Color

# Kill Firefox if it's running
pkill -f firefox

sleep 1

# Start Firefox normally without proxy
firefox &

sleep 2

# Notify the user
echo -e "${GREEN}Firefox started normally without Burp proxy${NC}"
PROXY_OFF

  # Make scripts executable
  chmod +x "/home/$PRIMARY_USERNAME/bin/burp-proxy-on.sh"
  chmod +x "/home/$PRIMARY_USERNAME/bin/burp-proxy-off.sh"
  
  # Set ownership
  chown -R "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/bin"
  
  # Create desktop shortcuts for proxy toggle
  cat > "/home/$PRIMARY_USERNAME/.local/share/applications/firefox-burp-proxy.desktop" << EOL
[Desktop Entry]
Name=Firefox with Burp Proxy
Comment=Start Firefox configured to use Burp Suite proxy
Exec=/home/$PRIMARY_USERNAME/bin/burp-proxy-on.sh
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;Security;
EOL

  cat > "/home/$PRIMARY_USERNAME/.local/share/applications/firefox-normal.desktop" << EOL
[Desktop Entry]
Name=Firefox (Normal)
Comment=Start Firefox with normal configuration
Exec=/home/$PRIMARY_USERNAME/bin/burp-proxy-off.sh
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOL

  # Fix ownership
  chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications/firefox-burp-proxy.desktop"
  chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications/firefox-normal.desktop"
  
  echo -e "${GREEN}[+] Firefox proxy configuration completed${NC}"
fi

# Create a config helper script
cat > "/usr/local/bin/burpsuite-config" << 'CONFIG_SCRIPT'
#!/bin/bash
# Burp Suite Configuration Helper

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

BURP_DIR="/opt/BurpSuitePro"

echo -e "${BLUE}=== Burp Suite Configuration Helper ===${NC}"
echo
echo -e "${YELLOW}Options:${NC}"
echo "1) Run Burp Suite Professional"
echo "2) Run Burp Suite with more memory (4GB)"
echo "3) Run Burp Suite with maximum memory (8GB)"
echo "4) Activate Burp Suite license"
echo "5) Fix Burp Suite Java compatibility issues"
echo "6) Create Firefox shortcuts for Burp proxy"
echo "7) Exit"

read -p "Select an option: " option

case $option in
  1)
    echo -e "${YELLOW}[*] Running Burp Suite Professional...${NC}"
    java -jar "$BURP_DIR/burpsuite_pro.jar" &
    ;;
  2)
    echo -e "${YELLOW}[*] Running Burp Suite with 4GB memory...${NC}"
    java -Xmx4g -jar "$BURP_DIR/burpsuite_pro.jar" &
    ;;
  3)
    echo -e "${YELLOW}[*] Running Burp Suite with 8GB memory...${NC}"
    java -Xmx8g -jar "$BURP_DIR/burpsuite_pro.jar" &
    ;;
  4)
    echo -e "${YELLOW}[*] Running Burp Suite activation helper...${NC}"
    "$BURP_DIR/activate_burp.sh"
    ;;
  5)
    echo -e "${YELLOW}[*] Installing/Updating Java for compatibility...${NC}"
    apt-get update
    apt-get install -y openjdk-11-jre || apt-get install -y default-jre
    echo -e "${GREEN}[+] Java updated. Try running Burp Suite again.${NC}"
    ;;
  6)
    echo -e "${YELLOW}[*] Creating Firefox shortcuts for Burp proxy...${NC}"
    
    # Get username
    read -p "Enter your username: " username
    
    if [ -z "$username" ] || [ ! -d "/home/$username" ]; then
      echo -e "${RED}[-] Invalid username or home directory not found${NC}"
      exit 1
    fi
    
    # Create bin directory
    mkdir -p "/home/$username/bin"
    
    # Create proxy toggle scripts
    cat > "/home/$username/bin/burp-proxy-on.sh" << 'PROXY_ON'
#!/bin/bash
# Enable Burp Suite proxy for Firefox

# Kill Firefox if it's running
pkill -f firefox

sleep 1

# Start Firefox with Burp proxy
firefox -P default --new-instance -no-remote -preferences -purgecaches --setDefaultBrowser -url "about:config" &

sleep 2

# Notify user
echo -e "\033[0;32mFirefox started with Burp proxy (127.0.0.1:8080)\033[0m"
PROXY_ON

    cat > "/home/$username/bin/burp-proxy-off.sh" << 'PROXY_OFF'
#!/bin/bash
# Disable Burp Suite proxy for Firefox

# Kill Firefox if it's running
pkill -f firefox

sleep 1

# Start Firefox normally
firefox &

sleep 2

# Notify user
echo -e "\033[0;32mFirefox started normally without Burp proxy\033[0m"
PROXY_OFF

    # Make scripts executable
    chmod +x "/home/$username/bin/burp-proxy-on.sh"
    chmod +x "/home/$username/bin/burp-proxy-off.sh"
    
    # Create desktop shortcuts
    mkdir -p "/home/$username/.local/share/applications"
    
    cat > "/home/$username/.local/share/applications/firefox-burp-proxy.desktop" << FF_PROXY
[Desktop Entry]
Name=Firefox with Burp Proxy
Comment=Start Firefox configured to use Burp Suite proxy
Exec=/home/$username/bin/burp-proxy-on.sh
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;Security;
FF_PROXY

    cat > "/home/$username/.local/share/applications/firefox-normal.desktop" << FF_NORMAL
[Desktop Entry]
Name=Firefox (Normal)
Comment=Start Firefox with normal configuration
Exec=/home/$username/bin/burp-proxy-off.sh
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
FF_NORMAL

    # Fix ownership
    chown -R "$username:$username" "/home/$username/bin"
    chown -R "$username:$username" "/home/$username/.local/share/applications"
    
    echo -e "${GREEN}[+] Firefox proxy shortcuts created for $username${NC}"
    ;;
  *)
    echo -e "${BLUE}Exiting.${NC}"
    ;;
esac
CONFIG_SCRIPT

chmod +x "/usr/local/bin/burpsuite-config"

echo -e "${GREEN}[+] Burp Suite Professional installation completed${NC}"
echo -e "${BLUE}[i] Run Burp Suite with command: burpsuite${NC}"
echo -e "${BLUE}[i] For configuration options, run: burpsuite-config${NC}"
echo -e "${BLUE}[i] To activate your license, run: $BURP_DIR/activate_burp.sh${NC}"

# Final steps
echo -e "${YELLOW}[*] Would you like to run Burp Suite Professional now? (Y/n)${NC}"
read -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo -e "${YELLOW}[*] Launching Burp Suite Professional...${NC}"
  java -jar "$BURP_DIR/burpsuite_pro.jar" &
fi

exit 0
