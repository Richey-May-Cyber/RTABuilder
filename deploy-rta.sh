#!/bin/bash
# Streamlined RTA Deployment Script
# Continues regardless of tool installation status

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

# Run a script with background monitoring and ability to continue
run_with_monitoring() {
  local cmd="$1"
  local description="$2"
  local timeout="${3:-300}"  # Default timeout of 5 minutes
  
  print_status "Running $description..."
  
  # Save script output to a log file
  local log_file="/opt/rta-deployment/logs/$(echo "$description" | tr ' ' '_')_$(date +%Y%m%d_%H%M%S).log"
  mkdir -p "/opt/rta-deployment/logs"
  
  # Start the script in background and redirect output to log
  eval "$cmd" > "$log_file" 2>&1 &
  local CMD_PID=$!
  
  print_info "Process started with PID $CMD_PID (timeout: ${timeout}s)"
  
  # Wait for the command to finish or timeout
  local SECONDS=0
  local progress=0
  local update_interval=$((timeout / 20))  # Update progress 20 times
  if [ $update_interval -lt 1 ]; then update_interval=1; fi
  
  # Show progress updates while waiting
  while kill -0 $CMD_PID 2>/dev/null; do
    # If timeout reached, break out
    if [ $SECONDS -ge $timeout ]; then
      print_error "Timeout reached ($timeout seconds) - continuing with deployment"
      kill $CMD_PID 2>/dev/null || true
      sleep 2
      kill -9 $CMD_PID 2>/dev/null || true
      print_info "Process terminated, continuing with next step"
      print_info "Check log file for details: $log_file"
      return 1
    fi
    
    # Calculate and show progress
    progress=$((SECONDS * 100 / timeout))
    if [ $((SECONDS % update_interval)) -eq 0 ]; then
      print_info "Running $description... ($progress% of timeout)"
    fi
    
    sleep 1
  done
  
  # Get the exit code
  wait $CMD_PID
  local exit_code=$?
  
  if [ $exit_code -eq 0 ]; then
    print_success "$description completed successfully"
    return 0
  else
    print_error "$description exited with code $exit_code"
    print_info "Check log file for details: $log_file"
    print_info "Continuing with deployment anyway..."
    return 1
  fi
}

# Check root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root"
  exit 1
fi

# Display banner
echo "=================================================="
echo "        STREAMLINED KALI LINUX RTA DEPLOYMENT     "
echo "=================================================="
echo ""

# Parse command-line arguments
AUTO_MODE=false
SKIP_DOWNLOADS=false

for arg in "$@"; do
  case $arg in
    --auto)
      AUTO_MODE=true
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
mkdir -p /opt/rta-deployment/{logs,downloads,config}
mkdir -p /opt/security-tools/{bin,logs,scripts,helpers,config,system-state}

# Copy or create installer script
if [ -f "installer/rta-installer.sh" ]; then
  print_status "Copying installer script..."
  cp installer/rta-installer.sh /opt/rta-deployment/
  chmod +x /opt/rta-deployment/rta-installer.sh
else
  print_status "Creating basic installer script..."
  cat > /opt/rta-deployment/rta_installer.sh << 'ENDOFSCRIPT'
#!/bin/bash
echo "[*] Installing basic tools..."
apt-get update
apt-get install -y nmap wireshark
echo "[+] Basic tools installed."
mkdir -p /opt/security-tools/bin
mkdir -p /opt/security-tools/logs
mkdir -p /opt/security-tools/scripts
mkdir -p /opt/security-tools/helpers
echo "[+] Installation complete."
ENDOFSCRIPT
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

# Create Burp Suite installation script
print_status "Creating installation scripts..."
cat > /opt/security-tools/helpers/install_burpsuite.sh << 'ENDOFBURPSCRIPT'
#!/bin/bash
# Helper script to install Burp Suite Professional with aggressive handling

echo "Installing Burp Suite Professional using the GitHub repository installer..."

# Create a temp directory for installation
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Download the installer script directly
echo "Downloading installer script..."
mkdir -p burp-install
cd burp-install
git clone https://github.com/xiv3r/Burpsuite-Professional.git .

# Run only the first part of the installation that downloads the JAR file
echo "Downloading Burp Suite JAR and setting up files..."
chmod +x install.sh

# Extract key download commands from the script to avoid the activation part
grep -A20 "Installing Dependencies" install.sh > download_only.sh
chmod +x download_only.sh
./download_only.sh

# Check if the JAR file was downloaded
if [ -f "burpsuite_pro_v"*".jar" ]; then
    # Create the target directories
    mkdir -p /usr/share/burpsuite
    cp burpsuite_pro_v*.jar /usr/share/burpsuite/burpsuite.jar
    
    # Create desktop entry
    cat > /usr/share/applications/burpsuite.desktop << 'DESKTOPFILE'
[Desktop Entry]
Version=1.0
Type=Application
Name=Burp Suite Professional
Comment=Security Testing Tool
Exec=java -jar /usr/share/burpsuite/burpsuite.jar
Icon=burpsuite
Terminal=false
Categories=Development;Security;
DESKTOPFILE
    
    # Create executable
    cat > /usr/bin/burpsuite << 'EXECFILE'
#!/bin/bash
java -jar /usr/share/burpsuite/burpsuite.jar "$@"
EXECFILE
    chmod +x /usr/bin/burpsuite
    
    echo "Burp Suite Professional files installed"
    echo "You can run it with: burpsuite"
    echo "You'll need to activate it on first run"
else
    echo "Failed to download Burp Suite JAR file"
    echo "Please install it manually after deployment"
    exit 1
fi
ENDOFBURPSCRIPT
chmod +x /opt/security-tools/helpers/install_burpsuite.sh

# Create Nessus installation script
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

# Create TeamViewer installation script
cat > /opt/security-tools/helpers/install_teamviewer.sh << 'ENDOFTVSCRIPT'
#!/bin/bash
# TeamViewer Host Installer with simple PolicyKit fix and headless configuration

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

# Check if the DEB package exists
if [ ! -f "$TV_PACKAGE" ]; then
  log "WARNING" "TeamViewer Host package not found at $TV_PACKAGE"
  
  # Try to download it
  log "INFO" "Attempting to download TeamViewer Host..."
  wget https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Check if we're on Kali Linux and need the PolicyKit1 fix
if grep -q "Kali" /etc/os-release; then
  log "INFO" "Kali Linux detected, applying simplified PolicyKit1 workaround..."
  
  # Install equivs if not present
  if ! command -v equivs-control &>/dev/null; then
    log "INFO" "Installing equivs package..."
    apt-get update
    apt-get install -y equivs
  fi
  
  # Create directory for the temporary files
  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  
  # Generate template for policykit-1
  log "INFO" "Generating policykit-1 template..."
  equivs-control policykit-1
  
  # Edit the template to create a minimal dummy package
  log "INFO" "Creating minimal policykit-1 dummy package..."
  sed -i "s/^#Package: .*/Package: policykit-1/" policykit-1
  sed -i "s/^#Version: .*/Version: 124-3/" policykit-1
  # Remove the Depends line completely rather than adding polkitd dependency
  sed -i "/^#Depends:/d" policykit-1
  sed -i "/^Description:/,$ s/^.*$/Description: Dummy package for TeamViewer dependency/" policykit-1
  
  # Build package
  log "INFO" "Building policykit-1 dummy package..."
  equivs-build policykit-1
  
  # Install package
  log "INFO" "Installing policykit-1 dummy package..."
  apt-get install -y ./policykit-1_*_all.deb
  
  # Cleanup
  cd - > /dev/null
  rm -rf "$TEMP_DIR"
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
systemctl start teamviewerd || true
sleep 10

# Assign to your TeamViewer account using the assignment token
log "STATUS" "Assigning device to your TeamViewer account..."
teamviewer --daemon start || true
sleep 5

if [ -n "$ASSIGNMENT_TOKEN" ]; then
  log "INFO" "Using assignment token: $ASSIGNMENT_TOKEN"
  teamviewer assignment --token "$ASSIGNMENT_TOKEN" || true
fi

# Set a custom alias for this device
TIMESTAMP=$(date +%Y%m%d%H%M%S)
DEVICE_ALIAS="${ALIAS_PREFIX}${TIMESTAMP}"
log "INFO" "Setting device alias to: $DEVICE_ALIAS"
teamviewer alias "$DEVICE_ALIAS" || true

# Configure TeamViewer for unattended access
log "INFO" "Configuring for unattended access..."
teamviewer setup --grant-easy-access || true

# Disable commercial usage notification
log "INFO" "Disabling commercial usage notification..."
teamviewer config set General\\CUNotification 0 || true

# Configure TeamViewer for headless operation
log "INFO" "Configuring TeamViewer for headless operation..."

# Disable waiting for X server
log "INFO" "Disabling X server dependency..."
teamviewer option set General/WaitForX false || true

# Set AutoConnect to true
log "INFO" "Enabling auto connect..."
teamviewer option set General/AutoConnect true || true

# Configure for auto start with system
log "INFO" "Enabling autostart..."
teamviewer daemon enable || true
systemctl enable teamviewerd || true

# Prevent TeamViewer from showing dialog boxes
log "INFO" "Suppressing dialog boxes..."
teamviewer option set General/SuppressDialogs true || true

# Prevent GUI from opening by updating the global config
if [ -f "/etc/teamviewer/global.conf" ]; then
  log "INFO" "Updating global configuration..."
  # Backup existing config
  cp /etc/teamviewer/global.conf /etc/teamviewer/global.conf.bak
  # Set ClientGuiRequired=false
  if grep -q "ClientGuiRequired" /etc/teamviewer/global.conf; then
    sed -i 's/ClientGuiRequired=.*/ClientGuiRequired=false/' /etc/teamviewer/global.conf
  else
    echo "ClientGuiRequired=false" >> /etc/teamviewer/global.conf
  fi
else
  # Create global config if it doesn't exist
  log "INFO" "Creating global configuration..."
  mkdir -p /etc/teamviewer
  echo "ClientGuiRequired=false" > /etc/teamviewer/global.conf
fi

# Restart TeamViewer to apply all settings
log "INFO" "Restarting TeamViewer service..."
teamviewer --daemon restart || true
sleep 5

# Display the TeamViewer ID for reference
TV_ID=$(teamviewer info 2>/dev/null | grep "TeamViewer ID:" | awk '{print $3}')
if [ -n "$TV_ID" ]; then
  log "SUCCESS" "TeamViewer Host installation and headless configuration completed!"
  log "INFO" "TeamViewer ID: $TV_ID"
else
  log "WARNING" "TeamViewer installation completed, but could not retrieve ID."
  log "INFO" "Check TeamViewer status with: systemctl status teamviewerd"
fi

exit 0
ENDOFTVSCRIPT
chmod +x /opt/security-tools/helpers/install_teamviewer.sh

# Create NinjaOne Agent installation script
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
  echo "Starting and enabling NinjaOne Agent service..."
  systemctl enable ninjarmm-agent || true
  systemctl start ninjarmm-agent || true

  echo "NinjaOne Agent installation completed"
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
  run_with_monitoring "/opt/rta-deployment/rta_installer.sh" "main installer script" 300
  
  # Install Burp Suite (with our custom non-hanging installer)
  run_with_monitoring "/opt/security-tools/helpers/install_burpsuite.sh" "Burp Suite Professional installation" 600
  
  # Install Nessus
  run_with_monitoring "/opt/security-tools/helpers/install_nessus.sh" "Nessus installation" 300
  
  # Install TeamViewer
  run_with_monitoring "/opt/security-tools/helpers/install_teamviewer.sh" "TeamViewer installation" 300
  
  # Install NinjaOne Agent
  run_with_monitoring "/opt/security-tools/helpers/install_ninjaone.sh" "NinjaOne Agent installation" 300
  
  # Disable screen lock if script exists
  if [ -f "/opt/security-tools/scripts/disable-lock-screen.sh" ]; then
    run_with_monitoring "/opt/security-tools/scripts/disable-lock-screen.sh" "screen lock disabling" 60
  fi
else
  # Interactive mode - prompt for each step
  
  # Run main installer script
  if prompt_continue "running the main installer script"; then
    run_with_monitoring "/opt/rta-deployment/rta_installer.sh" "main installer script" 300
  fi
  
  # Install Burp Suite
  if prompt_continue "installing Burp Suite Professional"; then
    run_with_monitoring "/opt/security-tools/helpers/install_burpsuite.sh" "Burp Suite Professional installation" 600
  fi
  
  # Install Nessus
  if prompt_continue "installing Nessus"; then
    run_with_monitoring "/opt/security-tools/helpers/install_nessus.sh" "Nessus installation" 300
  fi
  
  # Install TeamViewer
  if prompt_continue "installing TeamViewer"; then
    run_with_monitoring "/opt/security-tools/helpers/install_teamviewer.sh" "TeamViewer installation" 300
  fi
  
  # Install NinjaOne Agent
  if prompt_continue "installing NinjaOne Agent"; then
    run_with_monitoring "/opt/security-tools/helpers/install_ninjaone.sh" "NinjaOne Agent installation" 300
  fi
  
  # Disable screen lock if script exists
  if [ -f "/opt/security-tools/scripts/disable-lock-screen.sh" ] && prompt_continue "disabling screen lock"; then
    run_with_monitoring "/opt/security-tools/scripts/disable-lock-screen.sh" "screen lock disabling" 60
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

# Display tool-specific information
echo ""
print_info "== Tool Status =="

# Burp Suite
if [ -f "/usr/bin/burpsuite" ]; then
  print_success "Burp Suite Professional installed"
  print_info "Run 'burpsuite' to start and activate"
else
  print_error "Burp Suite Professional not installed"
  print_info "You may need to install it manually"
fi

# Nessus
if systemctl status nessusd &>/dev/null; then
  print_success "Nessus is installed and running"
  print_info "Complete setup at: https://localhost:8834/"
else
  print_error "Nessus service is not running"
  print_info "Check the installation status with: systemctl status nessusd"
fi

# TeamViewer
if command -v teamviewer &>/dev/null; then
  print_success "TeamViewer is installed"
  TV_ID=$(teamviewer info 2>/dev/null | grep "TeamViewer ID:" | awk '{print $3}')
  if [ -n "$TV_ID" ]; then
    print_info "TeamViewer ID: $TV_ID"
  else
    print_error "Could not retrieve TeamViewer ID"
  fi
else
  print_error "TeamViewer is not installed"
fi

# NinjaOne Agent
if systemctl status ninjarmm-agent &>/dev/null; then
  print_success "NinjaOne Agent is installed and running"
  print_info "The device should appear in your NinjaOne dashboard shortly"
else
  print_error "NinjaOne Agent service is not running"
  print_info "Check the installation status with: systemctl status ninjarmm-agent"
fi
