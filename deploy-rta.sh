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
    
    # Download Burp Suite
    download_file "https://portswigger.net/burp/releases/download?product=community&version=2023.1.2&type=Jar" \
      "/opt/rta-deployment/downloads/burpsuite_community.jar" \
      "Burp Suite Community Edition"
    
    # Download Nessus
    download_file "https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true" \
      "/opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb" \
      "Nessus Vulnerability Scanner"
    
    # Download TeamViewer
    download_file "https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb" \
      "/opt/rta-deployment/downloads/teamviewer-host_amd64.deb" \
      "TeamViewer Host"
  fi
fi

# Create tool installation helpers
print_status "Creating tool installation helpers..."

# Create Burp Suite helper script
cat > /opt/security-tools/helpers/install_burpsuite.sh << 'ENDOFBURPSCRIPT'
#!/bin/bash
# Helper script to install Burp Suite

# Check if Java is installed
if ! command -v java &>/dev/null; then
  echo "Installing Java..."
  apt-get update
  apt-get install -y default-jre
fi

# Check if the JAR exists
if [ -f "/opt/rta-deployment/downloads/burpsuite_community.jar" ]; then
  echo "Installing Burp Suite..."
  mkdir -p /opt/BurpSuiteCommunity
  cp /opt/rta-deployment/downloads/burpsuite_community.jar /opt/BurpSuiteCommunity/
  
  # Create launcher script
  cat > /usr/local/bin/burpsuite << 'ENDOFSCRIPT'
#!/bin/bash
java -jar /opt/BurpSuiteCommunity/burpsuite_community.jar "$@"
ENDOFSCRIPT
  chmod +x /usr/local/bin/burpsuite
  
  # Create desktop shortcut
  cat > /usr/share/applications/burpsuite.desktop << 'ENDOFDESKTOP'
[Desktop Entry]
Type=Application
Name=Burp Suite Community
Comment=Web Security Testing Tool
Exec=java -jar /opt/BurpSuiteCommunity/burpsuite_community.jar
Icon=burpsuite
Terminal=false
Categories=Security;Application;Network;
ENDOFDESKTOP

  echo "Burp Suite Community installed successfully"
else
  echo "Burp Suite JAR file not found. Please download it first."
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
# Helper script to install TeamViewer Host

# Check if the DEB package exists
if [ -f "/opt/rta-deployment/downloads/teamviewer-host_amd64.deb" ]; then
  echo "Installing TeamViewer Host..."
  apt-get update
  dpkg -i /opt/rta-deployment/downloads/teamviewer-host_amd64.deb || {
    apt-get -f install -y  # Fix broken dependencies if any
    dpkg -i /opt/rta-deployment/downloads/teamviewer-host_amd64.deb
  }
  
  # Configure TeamViewer (optional - uncomment and modify as needed)
  # ASSIGNMENT_TOKEN="your-token-here"  # Get this from your TeamViewer Management Console
  # teamviewer assignment --token $ASSIGNMENT_TOKEN
  
  echo "TeamViewer Host installed successfully"
  TV_ID=$(teamviewer info | grep "TeamViewer ID:" | awk '{print $3}')
  echo "TeamViewer ID: $TV_ID"
else
  echo "TeamViewer Host DEB package not found. Please download it first."
  exit 1
fi
ENDOFTVSCRIPT
chmod +x /opt/security-tools/helpers/install_teamviewer.sh

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
test -f "/opt/BurpSuiteCommunity/burpsuite_community.jar" && echo "✓ Burp Suite found" || echo "✗ Burp Suite not found"
systemctl status nessusd &>/dev/null && echo "✓ Nessus service found" || echo "✗ Nessus service not found"
which teamviewer &>/dev/null && echo "✓ TeamViewer found" || echo "✗ TeamViewer not found"
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
  print_status "Installing Burp Suite..."
  /opt/security-tools/helpers/install_burpsuite.sh
  
  # Install Nessus
  print_status "Installing Nessus..."
  /opt/security-tools/helpers/install_nessus.sh
  
  # Install TeamViewer
  print_status "Installing TeamViewer..."
  /opt/security-tools/helpers/install_teamviewer.sh
  
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
  if prompt_continue "installing Burp Suite"; then
    print_status "Installing Burp Suite..."
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
