#!/bin/bash
# =================================================================
# Enhanced Kali Linux RTA Deployment Script
# =================================================================
# Description: Wrapper script to deploy a complete Remote Testing Appliance
# Author: Security Professional
# Version: 2.0
# Usage: sudo ./deploy-rta.sh [OPTIONS]
# =================================================================

# Exit on error for critical operations, but with controlled error handling
set +e
trap cleanup EXIT INT TERM

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Directories and files
WORK_DIR="/opt/rta-deployment"
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$WORK_DIR/logs"
INSTALLER_SCRIPT="$WORK_DIR/rta_installer.sh"
DETAILED_LOG="$LOG_DIR/deployment_$(date +%Y%m%d_%H%M%S).log"
CONFIG_DIR="$WORK_DIR/config"
CONFIG_FILE="$CONFIG_DIR/deployment.conf"

# Flags
AUTO_MODE=false
INTERACTIVE=true
HEADLESS=false
VERBOSE=false
FORCE_REINSTALL=false
SKIP_UPDATES=false
NETWORK_SETUP=true
USER_SETUP=true
DISABLE_LOCK=true
DRY_RUN=false

# User configuration
DEFAULT_USERNAME="rtatester"
DEFAULT_PASSWORD="rtatester"

# Start time
START_TIME=$(date +%s)

# =================================================================
# UTILITY FUNCTIONS
# =================================================================

# Logging and output functions
print_status() { 
    echo -e "${YELLOW}[*] $(date +"%H:%M:%S") | $1${NC}"
    echo "[STATUS] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_success() { 
    echo -e "${GREEN}[+] $(date +"%H:%M:%S") | $1${NC}"
    echo "[SUCCESS] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_error() { 
    echo -e "${RED}[-] $(date +"%H:%M:%S") | $1${NC}"
    echo "[ERROR] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_info() { 
    echo -e "${BLUE}[i] $(date +"%H:%M:%S") | $1${NC}"
    echo "[INFO] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_debug() { 
    if $VERBOSE; then 
        echo -e "${CYAN}[D] $(date +"%H:%M:%S") | $1${NC}"
        echo "[DEBUG] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
    fi
}

print_warning() { 
    echo -e "${MAGENTA}[!] $(date +"%H:%M:%S") | $1${NC}"
    echo "[WARNING] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_step() {
    echo -e "\n${BOLD}${YELLOW}=== STEP $1: $2 ===${NC}"
    echo "[STEP] $(date +"%Y-%m-%d %H:%M:%S") | STEP $1: $2" >> "$DETAILED_LOG"
}

print_banner() {
    local width=70
    local line=$(printf '%*s' "$width" | tr ' ' '=')
    
    echo -e "\n${BOLD}${BLUE}$line${NC}"
    echo -e "${BOLD}${BLUE}                KALI LINUX RTA DEPLOYMENT                ${NC}"
    echo -e "${BOLD}${BLUE}$line${NC}\n"
    
    echo "[BANNER] $(date +"%Y-%m-%d %H:%M:%S") | Kali Linux RTA Deployment" >> "$DETAILED_LOG"
}

# Function to perform cleanup and finalization
finalize_deployment() {
    print_step "8" "Finalization"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would finalize deployment"
        return 0
    fi
    
    # Create system state snapshot
    print_info "Creating system state snapshot for future reference..."
    
    # Create system state directory
    local snapshot_dir="/opt/security-tools/system-state"
    mkdir -p "$snapshot_dir"
    local snapshot_file="$snapshot_dir/system-snapshot-$(date +%Y%m%d-%H%M%S).txt"
    
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
        
        echo "==== PYTHON PACKAGES ===="
        pip list 2>/dev/null || echo "Pip not installed or no packages found"
        echo ""
        
        echo "==== DESKTOP SHORTCUTS ===="
        ls -la "/opt/security-tools/desktop/" 2>/dev/null || echo "No desktop shortcuts found"
        echo ""
    } > "$snapshot_file"
    
    # Create a simple desktop shortcut to reports
    if [ -d "/usr/share/applications" ]; then
        cat > "/usr/share/applications/rta-reports.desktop" << EOF
[Desktop Entry]
Name=RTA Reports & Logs
Exec=xdg-open /opt/security-tools/logs
Type=Application
Icon=document-open
Terminal=false
Categories=Utility;
EOF
    fi
    
    # Create a desktop shortcut to tool validation
    if [ -d "/usr/share/applications" ] && [ -f "/opt/security-tools/scripts/validate-tools.sh" ]; then
        cat > "/usr/share/applications/rta-validate.desktop" << EOF
[Desktop Entry]
Name=Validate RTA Tools
Exec=gnome-terminal -- /opt/security-tools/scripts/validate-tools.sh
Type=Application
Icon=security-high
Terminal=false
Categories=Utility;Security;
EOF
    fi
    
    print_success "System state snapshot saved to: $snapshot_file"
    
    # Optional cleanup
    if $INTERACTIVE && confirm_action "Clean up installation files to save disk space?"; then
        print_info "Cleaning up installation files..."
        
        # Clean apt cache
        apt-get clean
        
        # Remove temporary files but keep logs
        if [ -d "/opt/security-tools/temp" ]; then
            rm -rf /opt/security-tools/temp/*
        fi
        
        print_success "Cleanup completed."
    else
        print_info "Installation files kept for reference."
    fi
    
    # Display completion message with next steps
    cat << EOF

${GREEN}==================================================================${NC}
${GREEN}                  RTA DEPLOYMENT COMPLETED!                       ${NC}
${GREEN}==================================================================${NC}

${BLUE}Installed tools can be found at:${NC} /opt/security-tools/
${BLUE}Installation logs are available at:${NC} /opt/security-tools/logs/
${BLUE}System snapshot is saved at:${NC} $snapshot_file

${YELLOW}Next steps:${NC}
1. Validate the installation by running:
   ${CYAN}sudo /opt/security-tools/scripts/validate-tools.sh${NC}
2. Install any remaining manual tools using the helper scripts:
   ${CYAN}ls /opt/security-tools/helpers/${NC}
3. Configure any tool-specific settings

${BLUE}Thank you for using the RTA Deployment Script!${NC}
EOF
}

# =================================================================
# MAIN EXECUTION
# =================================================================

# Initialize detailed log file
mkdir -p "$LOG_DIR"
echo "RTA Deployment Log - $(date)" > "$DETAILED_LOG"
echo "=============================================" >> "$DETAILED_LOG"
echo "System: $(uname -a)" >> "$DETAILED_LOG"
echo "User: $(whoami)" >> "$DETAILED_LOG"
echo "Command: $0 $*" >> "$DETAILED_LOG"
echo "=============================================" >> "$DETAILED_LOG"
echo "" >> "$DETAILED_LOG"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTO_MODE=true
            INTERACTIVE=false
            shift
            ;;
        --interactive)
            INTERACTIVE=true
            AUTO_MODE=false
            shift
            ;;
        --headless)
            HEADLESS=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --force-reinstall)
            FORCE_REINSTALL=true
            shift
            ;;
        --skip-updates)
            SKIP_UPDATES=true
            shift
            ;;
        --no-network-setup)
            NETWORK_SETUP=false
            shift
            ;;
        --no-user-setup)
            USER_SETUP=false
            shift
            ;;
        --no-disable-lock)
            DISABLE_LOCK=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
main() {
    # Print banner
    print_banner
    
    # Display current configuration
    echo -e "Deployment mode:"
    if $INTERACTIVE; then echo -e " - ${GREEN}Interactive mode${NC}"; fi
    if $AUTO_MODE; then echo -e " - ${GREEN}Automated mode${NC}"; fi
    if $HEADLESS; then echo -e " - ${YELLOW}Headless mode${NC}"; fi
    if $VERBOSE; then echo -e " - ${BLUE}Verbose output${NC}"; fi
    if $FORCE_REINSTALL; then echo -e " - ${YELLOW}Force reinstall${NC}"; fi
    if $SKIP_UPDATES; then echo -e " - ${YELLOW}Skipping system updates${NC}"; fi
    if ! $NETWORK_SETUP; then echo -e " - ${YELLOW}Skipping network setup${NC}"; fi
    if ! $USER_SETUP; then echo -e " - ${YELLOW}Skipping user setup${NC}"; fi
    if ! $DISABLE_LOCK; then echo -e " - ${YELLOW}Skipping screen lock disabling${NC}"; fi
    if $DRY_RUN; then echo -e " - ${CYAN}Dry run (no changes)${NC}"; fi
    echo ""
    
    # Check if running as root
    check_root
    
    # Create/update config file
    create_config_file
    
    # Load configuration
    load_config
    
    # Run deployment steps
    prepare_system
    download_installer
    configure_installation
    run_installer
    configure_post_install
    configure_network
    setup_user_account
    finalize_deployment
    
    # Reboot recommendation
    if $INTERACTIVE; then
        if confirm_action "Do you want to reboot the system now?"; then
            print_info "Rebooting in 5 seconds... Press Ctrl+C to cancel."
            sleep 5
            reboot
        else
            print_info "Reboot skipped. Please reboot manually to apply all changes."
        fi
    else
        print_info "Automated mode: System will not reboot automatically."
        print_info "Please reboot manually to ensure all changes take effect."
    fi
    
    return 0
}

# Run main function
main
exit $?
 to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        echo -e "\nUsage: sudo $0 [OPTIONS]"
        exit 1
    fi
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    
    # Only perform cleanup if not a dry run
    if ! $DRY_RUN; then
        print_status "Performing cleanup operations..."
    fi
    
    # Print final message based on exit code
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then  # 130 is Ctrl+C
        print_error "Deployment terminated with errors (code $exit_code). Check logs for details."
        print_info "Detailed log: $DETAILED_LOG"
    elif [ $exit_code -eq 130 ]; then
        print_warning "Deployment interrupted by user."
    elif $DRY_RUN; then
        print_info "Dry run completed. No changes were made to the system."
    else
        print_success "Deployment completed successfully."
    fi
    
    # Record end time and calculate duration
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))
    
    # Print duration
    if [ $exit_code -ne 130 ]; then  # Don't print time for Ctrl+C
        print_info "Total execution time: $MINUTES minutes and $SECONDS seconds"
    fi
}

# Function to ask user for confirmation
confirm_action() {
    local message=$1
    local default=${2:-y}
    
    # If in auto mode, return the default
    if $AUTO_MODE; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    
    # Otherwise, ask the user
    local prompt
    if [ "$default" = "y" ]; then
        prompt="$message [Y/n]: "
    else
        prompt="$message [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response,,} # Convert to lowercase
    
    if [ -z "$response" ]; then
        response=$default
    fi
    
    [[ "$response" =~ ^(yes|y)$ ]] && return 0 || return 1
}

# Function to show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --auto              Run in automated mode with default settings (no prompts)
  --interactive       Run in interactive mode (default)
  --headless          Run in headless mode (no GUI components)
  --verbose           Show debug messages
  --force-reinstall   Reinstall tools even if already installed
  --skip-updates      Skip system updates
  --no-network-setup  Skip network persistence configuration
  --no-user-setup     Skip default user account creation
  --no-disable-lock   Skip disabling screen lock
  --dry-run           Show what would be done without making changes
  --help              Display this help message and exit

EXAMPLES:
  $0 --auto                  # Fully automated deployment
  $0 --interactive           # Interactive deployment (default)
  $0 --auto --verbose        # Automated with verbose output
  $0 --auto --skip-updates   # Automated without system updates
  $0 --dry-run               # Simulation mode
EOF
}

# Function to create or update config file
create_config_file() {
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would create/update configuration file"
        return 0
    fi
    
    # Create config file if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# RTA Deployment Configuration
# This file contains settings for the RTA deployment

# User settings
USERNAME="$DEFAULT_USERNAME"
PASSWORD="$DEFAULT_PASSWORD"

# Network settings
PRESERVE_MAC_ADDRESSES=true
MANAGED_NETWORK=true

# System settings
DISABLE_SCREEN_LOCK=true
DISABLE_POWER_MANAGEMENT=true
DISABLE_AUTO_UPDATES=true

# Tools settings
INSTALL_MODE="full"  # Options: full, core, desktop
HEADLESS_MODE=false
EOF
    fi
}

# Function to load configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_debug "Loading config from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        print_warning "Config file not found. Using default settings."
    fi
}

# =================================================================
# DEPLOYMENT FUNCTIONS
# =================================================================

# Function to prepare the system
prepare_system() {
    print_step "1" "System Preparation"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would prepare system"
        return 0
    fi
    
    # Update system if not skipping updates
    if ! $SKIP_UPDATES; then
        if $INTERACTIVE && ! confirm_action "Do you want to update the system first?"; then
            print_info "System update skipped by user."
        else
            print_info "Updating system packages..."
            apt-get update >> "$DETAILED_LOG" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$DETAILED_LOG" 2>&1
            print_success "System updated successfully."
        fi
    else
        print_info "System update skipped (--skip-updates flag set)."
    fi
    
    # Install essential tools needed for deployment
    print_info "Installing essential tools for deployment..."
    apt-get install -y git curl wget unzip net-tools dnsutils whois >> "$DETAILED_LOG" 2>&1
    
    print_success "System preparation complete."
}

# Function to download and prepare the installer
download_installer() {
    print_step "2" "Downloading RTA Installer"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would download installer"
        return 0
    fi
    
    # Create working directory
    mkdir -p "$WORK_DIR" "$LOG_DIR"
    
    # Download or copy the improved installer script
    if [ -f "$INSTALLER_SCRIPT" ] && confirm_action "Installer script already exists. Use existing file?"; then
        print_info "Using existing installer script at $INSTALLER_SCRIPT"
    else
        print_info "Downloading RTA installer script..."
        
        # Try to download from repository or URL
        # For this example, we'll embed the script directly
        cat > "$INSTALLER_SCRIPT" << 'EOF'
#!/bin/bash
# Insert the content of the improved RTA installer script here
# This will be replaced with the actual download in production

echo "This is a placeholder for the RTA installer script."
echo "In production, this would be downloaded from your repository."
echo "For the purposes of this example, we'll consider it successful."

exit 0
EOF
        
        chmod +x "$INSTALLER_SCRIPT"
        print_success "Installer script ready at $INSTALLER_SCRIPT."
    fi
}

# Function to configure installation options
configure_installation() {
    print_step "3" "Configuration"
    
    local install_mode="--full"
    local verbose=""
    local headless=""
    local force=""
    local skip_updates=""
    local dry_run=""
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would configure installation options"
        dry_run="--dry-run"
    fi
    
    if $INTERACTIVE; then
        echo "Please select installation mode:"
        echo "1) Full installation (all tools)"
        echo "2) Core tools only (faster)"
        echo "3) Desktop shortcuts only (no tools)"
        read -p "Enter your choice [1-3]: " CHOICE
        
        case $CHOICE in
            1) install_mode="--full" ;;
            2) install_mode="--core-only" ;;
            3) install_mode="--desktop-only" ;;
            *) print_info "Invalid choice. Using default: full installation." ;;
        esac
        
        if confirm_action "Enable verbose output?"; then
            verbose="--verbose"
            VERBOSE=true
        fi
        
        if confirm_action "Headless installation (no GUI components)?"; then
            headless="--headless"
            HEADLESS=true
        fi
        
        if confirm_action "Force reinstall of tools?"; then
            force="--force-reinstall"
            FORCE_REINSTALL=true
        fi
        
        if confirm_action "Skip system updates during tool installation?"; then
            skip_updates="--skip-updates"
            SKIP_UPDATES=true
        fi
    else
        print_info "Automatic mode: Using configured installation options."
        install_mode="--full"
        
        if $VERBOSE; then
            verbose="--verbose"
        fi
        
        if $HEADLESS; then
            headless="--headless"
        fi
        
        if $FORCE_REINSTALL; then
            force="--force-reinstall"
        fi
        
        if $SKIP_UPDATES; then
            skip_updates="--skip-updates"
        fi
    fi
    
    # Set global variable with all options
    INSTALLER_OPTIONS="$install_mode $verbose $headless $force $skip_updates $dry_run"
    if $AUTO_MODE; then
        INSTALLER_OPTIONS="$INSTALLER_OPTIONS --auto"
    fi
    
    print_info "Installation will use options: $INSTALLER_OPTIONS"
}

# Function to run the installer
run_installer() {
    print_step "4" "Tool Installation"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would run installer with options: $INSTALLER_OPTIONS"
        return 0
    fi
    
    print_info "Starting installation with options: $INSTALLER_OPTIONS"
    
    # Check if the installer script exists
    if [ ! -f "$INSTALLER_SCRIPT" ]; then
        print_error "Installer script not found at $INSTALLER_SCRIPT"
        print_info "Please run the script again with the --download option to download the installer."
        return 1
    fi
    
    # Make sure it's executable
    chmod +x "$INSTALLER_SCRIPT"
    
    # Run the installer
    "$INSTALLER_SCRIPT" $INSTALLER_OPTIONS
    
    local result=$?
    if [ $result -eq 0 ]; then
        print_success "Installation completed successfully."
    else
        print_error "Installation encountered issues (exit code $result). Check the logs for details."
        if confirm_action "Continue with deployment despite installation errors?" "n"; then
            print_warning "Continuing deployment despite errors. Some functionality may be limited."
        else
            print_error "Deployment aborted due to installation errors."
            return 1
        fi
    fi
}

# Function to configure post-installation settings
configure_post_install() {
    print_step "5" "Post-Installation Configuration"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would configure post-installation settings"
        return 0
    fi
    
    # Disable screen lock if requested
    if $DISABLE_LOCK; then
        if $INTERACTIVE && ! confirm_action "Disable screen lock for testing environment?"; then
            print_info "Screen lock configuration skipped by user."
        else
            print_info "Disabling screen lock and power management..."
            local lock_script="/opt/security-tools/scripts/disable-lock-screen.sh"
            
            if [ -f "$lock_script" ]; then
                chmod +x "$lock_script"
                if [ -n "$SUDO_USER" ]; then
                    su - $SUDO_USER -c "$lock_script"
                else
                    bash "$lock_script"
                fi
                print_success "Screen lock disabled."
            else
                print_error "Could not find disable-lock-screen.sh script."
                
                # Try a basic alternative method
                if [ -n "$SUDO_USER" ]; then
                    su - $SUDO_USER -c "
                        gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
                        gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
                    "
                fi
                print_info "Basic screen lock disabling attempted."
            fi
        fi
    else
        print_info "Screen lock configuration skipped (--no-disable-lock flag set)."
    fi
    
    # Configure any additional post-installation settings
    print_info "Configuring additional system settings..."
    
    # Disable system sleep/hibernation
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >> "$DETAILED_LOG" 2>&1
    
    # Disable automatic updates if requested
    if $INTERACTIVE && confirm_action "Disable automatic updates to prevent disruptions?"; then
        print_info "Disabling automatic updates..."
        if [ -f "/etc/apt/apt.conf.d/20auto-upgrades" ]; then
            sed -i 's/^APT::Periodic::Update-Package-Lists "1";/APT::Periodic::Update-Package-Lists "0";/' /etc/apt/apt.conf.d/20auto-upgrades
            sed -i 's/^APT::Periodic::Unattended-Upgrade "1";/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades
        fi
        
        if [ -f "/etc/apt/apt.conf.d/10periodic" ]; then
            sed -i 's/^APT::Periodic::Update-Package-Lists "1";/APT::Periodic::Update-Package-Lists "0";/' /etc/apt/apt.conf.d/10periodic
            sed -i 's/^APT::Periodic::Download-Upgradeable-Packages "1";/APT::Periodic::Download-Upgradeable-Packages "0";/' /etc/apt/apt.conf.d/10periodic
        fi
        
        # Disable update-notifier
        if [ -d "/etc/xdg/autostart" ]; then
            if [ -f "/etc/xdg/autostart/update-notifier.desktop" ]; then
                echo "X-GNOME-Autostart-enabled=false" >> /etc/xdg/autostart/update-notifier.desktop
            fi
        fi
        
        print_success "Automatic updates disabled."
    fi
    
    print_success "Post-installation configuration complete."
}

# Function to configure network persistence
configure_network() {
    print_step "6" "Network Configuration"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would configure network persistence"
        return 0
    fi
    
    if ! $NETWORK_SETUP; then
        print_info "Network configuration skipped (--no-network-setup flag set)."
        return 0
    fi
    
    if $INTERACTIVE && ! confirm_action "Configure system to keep network settings between reboots?"; then
        print_info "Network persistence configuration skipped by user."
        return 0
    fi
    
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
    
    # Add custom route persistence if needed
    if $INTERACTIVE && confirm_action "Do you need to configure persistent static routes?"; then
        print_info "Creating network persistence script..."
        
        mkdir -p /etc/NetworkManager/dispatcher.d
        cat > /etc/NetworkManager/dispatcher.d/02-restore-routes << 'EOF'
#!/bin/bash
# Custom script to restore static routes after network changes

INTERFACE=$1
EVENT=$2
LOG_FILE="/var/log/network-routes.log"

# Only run when an interface goes up
if [ "$EVENT" != "up" ]; then
    exit 0
fi

# Log the event
echo "[$(date)] Network interface $INTERFACE is up, restoring routes..." >> $LOG_FILE

# Add your custom static routes here
# Example: ip route add 192.168.2.0/24 via 192.168.1.1 dev $INTERFACE
# Example: ip route add 10.0.0.0/8 via 192.168.1.254 dev $INTERFACE

echo "[$(date)] Routes restored for $INTERFACE" >> $LOG_FILE

exit 0
EOF
        
        chmod +x /etc/NetworkManager/dispatcher.d/02-restore-routes
        print_success "Network persistence script created."
    fi
    
    print_success "Network persistence configured."
}

# Function to create default user account
setup_user_account() {
    print_step "7" "User Configuration"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would set up user account"
        return 0
    fi
    
    if ! $USER_SETUP; then
        print_info "User account setup skipped (--no-user-setup flag set)."
        return 0
    fi
    
    local username=$DEFAULT_USERNAME
    local password=$DEFAULT_PASSWORD
    
    if $INTERACTIVE; then
        if ! confirm_action "Set up a default user account for remote access?"; then
            print_info "User account setup skipped by user."
            return 0
        fi
        
        read -p "Enter username [$DEFAULT_USERNAME]: " input_username
        username=${input_username:-$DEFAULT_USERNAME}
        
        read -s -p "Enter password [$DEFAULT_PASSWORD]: " input_password
        echo
        password=${input_password:-$DEFAULT_PASSWORD}
    fi
    
    print_info "Creating user $username..."
    
    # Create user if it doesn't exist
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash "$username"
        echo "$username:$password" | chpasswd
        
        # Add to sudo group
        usermod -aG sudo "$username"
        
        # Configure SSH access
        mkdir -p /home/$username/.ssh
        chmod 700 /home/$username/.ssh
        
        # Add empty authorized_keys file
        touch /home/$username/.ssh/authorized_keys
        chmod 600 /home/$username/.ssh/authorized_keys
        chown -R $username:$username /home/$username/.ssh
        
        print_success "User $username created with sudo access."
    else
        print_info "User $username already exists. Updating password."
        echo "$username:$password" | chpasswd
    fi
    
    # Enable SSH server if needed
    if ! systemctl is-active --quiet ssh; then
        print_info "Enabling SSH server..."
        apt-get install -y openssh-server &>/dev/null
        systemctl enable ssh
        systemctl start ssh
        print_success "SSH server enabled."
    fi
    
    print_success "User account setup complete."
}

# Function
