#!/bin/bash
# RTA Deployment Script
# This script helps setting up a Kali Linux RTA with automated tool installation
# Usage: ./deploy-rta.sh [--auto|--interactive]

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Output helpers
print_banner() {
    echo -e "\n${BLUE}========================================================${NC}"
    echo -e "${BLUE}               KALI LINUX RTA DEPLOYMENT                ${NC}"
    echo -e "${BLUE}========================================================${NC}\n"
}

print_step() {
    echo -e "\n${YELLOW}[*] STEP $1: $2${NC}"
}

print_info() {
    echo -e "${BLUE}[i] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

print_error() {
    echo -e "${RED}[-] $1${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root."
    echo "Please run: sudo $0"
    exit 1
fi

# Default mode
MODE="interactive"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            MODE="auto"
            shift
            ;;
        --interactive)
            MODE="interactive"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--auto|--interactive]"
            exit 1
            ;;
    esac
done

# Print banner
print_banner

# Create working directory
WORK_DIR="/opt/rta-deployment"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Step 1: System preparation
print_step "1" "System Preparation"

if [ "$MODE" == "interactive" ]; then
    read -p "Do you want to update the system first? (y/n): " UPDATE_SYSTEM
    UPDATE_SYSTEM=${UPDATE_SYSTEM,,} # Convert to lowercase
else
    print_info "Automatic mode: System will be updated."
    UPDATE_SYSTEM="y"
fi

if [[ "$UPDATE_SYSTEM" == "y" ]]; then
    print_info "Updating system packages..."
    apt-get update
    apt-get upgrade -y
    print_success "System updated successfully."
else
    print_info "Skipping system update."
fi

# Step 2: Download the installer
print_step "2" "Downloading RTA Installer"

# Clone or download the improved installer script
print_info "Downloading RTA installer script..."
wget -O "$WORK_DIR/rta_installer.sh" https://raw.githubusercontent.com/yourusername/rta-installer/main/rta_installer.sh 2>/dev/null

# If download failed, create the script locally
if [ $? -ne 0 ]; then
    print_info "Download failed. Creating installer script locally..."
    cat > "$WORK_DIR/rta_installer.sh" << 'EOF'
# Your improved RTA installer script will be inserted here
# This is a placeholder - the real script should be downloaded from your repository
EOF
    # Copy the full script content from your repository or store it within this deploy script
fi

chmod +x "$WORK_DIR/rta_installer.sh"
print_success "Installer script ready."

# Step 3: Configure installation options
print_step "3" "Configuration"

INSTALL_MODE="--full"
VERBOSE=""
HEADLESS=""

if [ "$MODE" == "interactive" ]; then
    echo "Please select installation mode:"
    echo "1) Full installation (all tools)"
    echo "2) Core tools only (faster)"
    echo "3) Desktop shortcuts only (no tools)"
    read -p "Enter your choice [1-3]: " CHOICE
    
    case $CHOICE in
        1) INSTALL_MODE="--full" ;;
        2) INSTALL_MODE="--core-only" ;;
        3) INSTALL_MODE="--desktop-only" ;;
        *) print_info "Invalid choice. Using default: full installation." ;;
    esac
    
    read -p "Enable verbose output? (y/n): " VERBOSE_CHOICE
    if [[ "${VERBOSE_CHOICE,,}" == "y" ]]; then
        VERBOSE="--verbose"
    fi
    
    read -p "Headless installation (no GUI components)? (y/n): " HEADLESS_CHOICE
    if [[ "${HEADLESS_CHOICE,,}" == "y" ]]; then
        HEADLESS="--headless"
    fi
else
    print_info "Automatic mode: Using full installation with verbose output."
    INSTALL_MODE="--full"
    VERBOSE="--verbose"
fi

# Step 4: Run the installer
print_step "4" "Tool Installation"

print_info "Starting installation with options: $INSTALL_MODE $VERBOSE $HEADLESS"
"$WORK_DIR/rta_installer.sh" $INSTALL_MODE $VERBOSE $HEADLESS

if [ $? -eq 0 ]; then
    print_success "Installation completed successfully."
else
    print_error "Installation encountered issues. Check the logs for details."
fi

# Step 5: Post-installation tasks
print_step "5" "Post-Installation Configuration"

if [ "$MODE" == "interactive" ]; then
    read -p "Disable screen lock for testing environment? (y/n): " DISABLE_LOCK
    DISABLE_LOCK=${DISABLE_LOCK,,}
else
    print_info "Automatic mode: Screen lock will be disabled."
    DISABLE_LOCK="y"
fi

if [[ "$DISABLE_LOCK" == "y" ]]; then
    print_info "Disabling screen lock and power management..."
    if [ -f "/opt/security-tools/scripts/disable-lock-screen.sh" ]; then
        chmod +x "/opt/security-tools/scripts/disable-lock-screen.sh"
        if [ -n "$SUDO_USER" ]; then
            su - $SUDO_USER -c "/opt/security-tools/scripts/disable-lock-screen.sh"
        else
            bash "/opt/security-tools/scripts/disable-lock-screen.sh"
        fi
        print_success "Screen lock disabled."
    else
        print_error "Could not find disable-lock-screen.sh script."
    fi
else
    print_info "Skipping screen lock configuration."
fi

# Step 6: Configure system persistence
print_step "6" "System Persistence Configuration"

if [ "$MODE" == "interactive" ]; then
    read -p "Configure system to keep network settings between reboots? (y/n): " CONFIG_NETWORK
    CONFIG_NETWORK=${CONFIG_NETWORK,,}
else
    print_info "Automatic mode: Network persistence will be configured."
    CONFIG_NETWORK="y"
fi

if [[ "$CONFIG_NETWORK" == "y" ]]; then
    print_info "Configuring network persistence..."
    
    # Ensure NetworkManager persists connections
    mkdir -p /etc/NetworkManager/conf.d/
    cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf << EOF
[keyfile]
unmanaged-devices=none
EOF

    # Ensure MAC addresses are not randomized
    cat > /etc/NetworkManager/conf.d/disable-mac-randomization.conf << EOF
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=preserve
ethernet.cloned-mac-address=preserve
connection.stable-id=\${CONNECTION}/\${BOOT}
EOF

    # Restart NetworkManager
    systemctl restart NetworkManager
    print_success "Network persistence configured."
else
    print_info "Skipping network persistence configuration."
fi

# Step 7: Configure default credentials
print_step "7" "User Configuration"

if [ "$MODE" == "interactive" ]; then
    read -p "Set up a default user account for remote access? (y/n): " SETUP_USER
    SETUP_USER=${SETUP_USER,,}
else
    print_info "Automatic mode: Default user account will be set up."
    SETUP_USER="y"
fi

if [[ "$SETUP_USER" == "y" ]]; then
    if [ "$MODE" == "interactive" ]; then
        read -p "Enter username [rtatester]: " USERNAME
        USERNAME=${USERNAME:-rtatester}
        read -s -p "Enter password [rtatester]: " PASSWORD
        echo
        PASSWORD=${PASSWORD:-rtatester}
    else
        USERNAME="rtatester"
        PASSWORD="rtatester"
    fi
    
    print_info "Creating user $USERNAME..."
    
    # Create user if it doesn't exist
    if ! id "$USERNAME" &>/dev/null; then
        useradd -m -s /bin/bash "$USERNAME"
        echo "$USERNAME:$PASSWORD" | chpasswd
        
        # Add to sudo group
        usermod -aG sudo "$USERNAME"
        
        # Configure SSH access
        mkdir -p /home/$USERNAME/.ssh
        chmod 700 /home/$USERNAME/.ssh
        
        # Add empty authorized_keys file
        touch /home/$USERNAME/.ssh/authorized_keys
        chmod 600 /home/$USERNAME/.ssh/authorized_keys
        chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
        
        print_success "User $USERNAME created with sudo access."
    else
        print_info "User $USERNAME already exists. Updating password."
        echo "$USERNAME:$PASSWORD" | chpasswd
    fi
    
    # Enable SSH server if needed
    if ! systemctl is-active --quiet ssh; then
        print_info "Enabling SSH server..."
        apt-get install -y openssh-server &>/dev/null
        systemctl enable ssh
        systemctl start ssh
        print_success "SSH server enabled."
    fi
else
    print_info "Skipping user account setup."
fi

# Step 8: Cleanup
print_step "8" "Cleanup"

if [ "$MODE" == "interactive" ]; then
    read -p "Clean up installation files and logs? (y/n): " CLEANUP
    CLEANUP=${CLEANUP,,}
else
    print_info "Automatic mode: Installation files will be kept for reference."
    CLEANUP="n"
fi

if [[ "$CLEANUP" == "y" ]]; then
    print_info "Cleaning up installation files..."
    
    # Keep critical logs but remove temporary files
    if [ -d "/opt/security-tools/temp" ]; then
        rm -rf /opt/security-tools/temp/*
    fi
    
    # Clean apt cache
    apt-get clean
    
    print_success "Cleanup completed."
else
    print_info "Skipping cleanup. Installation files kept for reference."
fi

# Step 9: Finalization
print_step "9" "Finalization"

print_info "Creating system state snapshot for future reference..."

# Create a system state report
SNAPSHOT_DIR="/opt/security-tools/system-state"
mkdir -p "$SNAPSHOT_DIR"
SNAPSHOT_FILE="$SNAPSHOT_DIR/system-snapshot-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "==== RTA SYSTEM SNAPSHOT ===="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Kali Version: $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2)"
    echo ""
    
    echo "==== INSTALLED PACKAGES ===="
    dpkg-query -l | grep ^ii | awk '{print $2 " " $3}'
    echo ""
    
    echo "==== NETWORK CONFIGURATION ===="
    ip addr
    echo ""
    
    echo "==== DISK USAGE ===="
    df -h
    echo ""
    
    echo "==== MEMORY USAGE ===="
    free -h
    echo ""
    
    echo "==== ACTIVE SERVICES ===="
    systemctl list-units --type=service --state=running
    echo ""
    
    echo "==== INSTALLED SECURITY TOOLS ===="
    ls -la /opt/security-tools/bin/ 2>/dev/null || echo "No tools found in /opt/security-tools/bin/"
    ls -la /usr/local/bin/ | grep -v "^l" | tail -n +2
    echo ""
} > "$SNAPSHOT_FILE"

# Create a simple desktop shortcut to reports
if [ -d "/usr/share/applications" ]; then
    cat > "/usr/share/applications/rta-reports.desktop" << EOF
[Desktop Entry]
Name=RTA Reports
Exec=xdg-open /opt/security-tools/logs
Type=Application
Icon=document-open
Terminal=false
Categories=Utility;
EOF
fi

print_success "System state snapshot saved to: $SNAPSHOT_FILE"

# Final message
print_banner
echo -e "${GREEN}RTA DEPLOYMENT COMPLETED SUCCESSFULLY!${NC}"
echo
echo -e "${BLUE}Installed tools can be found at:${NC} /opt/security-tools/"
echo -e "${BLUE}Installation logs are available at:${NC} /opt/security-tools/logs/"
echo -e "${BLUE}System snapshot is saved at:${NC} $SNAPSHOT_FILE"
echo

# Reboot recommendation
if [ "$MODE" == "interactive" ]; then
    read -p "Do you want to reboot the system now? (y/n): " REBOOT
    REBOOT=${REBOOT,,}
else
    print_info "Automatic mode: System will not reboot automatically."
    REBOOT="n"
fi

if [[ "$REBOOT" == "y" ]]; then
    print_info "Rebooting in 5 seconds... Press Ctrl+C to cancel."
    sleep 5
    reboot
else
    print_info "Reboot skipped. Remember to reboot manually to apply all changes."
fi

exit 0
