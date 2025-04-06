#!/bin/bash

# =================================================================
# Enhanced Kali Linux Security Tools Installer for Remote Testing Appliances
# =================================================================
# Description: Robust, efficient, and reliable toolkit installer for Kali Linux RTAs
# Author: Security Professional
# Version: 2.0
# Usage: sudo ./rta_installer.sh [OPTIONS]
# =================================================================

# =================================================================
# CONFIGURATION AND CONSTANTS
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

# Directories
TOOLS_DIR="/opt/security-tools"
VENV_DIR="$TOOLS_DIR/venvs"
LOG_DIR="$TOOLS_DIR/logs"
BIN_DIR="$TOOLS_DIR/bin"
CONFIG_DIR="$TOOLS_DIR/config"
HELPERS_DIR="$TOOLS_DIR/helpers"
DESKTOP_DIR="$TOOLS_DIR/desktop"
TEMP_DIR="$TOOLS_DIR/temp"
SCRIPTS_DIR="$TOOLS_DIR/scripts"
SYSTEM_STATE_DIR="$TOOLS_DIR/system-state"

# Files
CONFIG_FILE="$CONFIG_DIR/config.yml"
REPORT_FILE="$LOG_DIR/installation_report_$(date +%Y%m%d_%H%M%S).txt"
DETAILED_LOG="$LOG_DIR/detailed_install_$(date +%Y%m%d_%H%M%S).log"
SNAPSHOT_FILE="$SYSTEM_STATE_DIR/system-snapshot-$(date +%Y%m%d_%H%M%S).txt"

# Timeouts (in seconds)
GIT_CLONE_TIMEOUT=300
APT_INSTALL_TIMEOUT=600
PIP_INSTALL_TIMEOUT=300
BUILD_TIMEOUT=600
DOWNLOAD_TIMEOUT=180

# Number of parallel jobs
PARALLEL_JOBS=$(nproc)
# Limit to a reasonable number to avoid overwhelming the system
if [ $PARALLEL_JOBS -gt 8 ]; then
    PARALLEL_JOBS=8
fi

# Flags
FULL_INSTALL=false
CORE_ONLY=false
DESKTOP_ONLY=false
HEADLESS=false
VERBOSE=false
AUTO_MODE=false
IGNORE_ERRORS=false
FORCE_REINSTALL=false
SKIP_UPDATES=false
DRY_RUN=false

# Tool installation tracking
declare -A INSTALL_STATUS
declare -A INSTALL_NOTES
declare -A INSTALL_TIMES

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
    echo -e "\n${BOLD}${YELLOW}=== STEP: $1 ===${NC}"
    echo "[STEP] $(date +"%Y-%m-%d %H:%M:%S") | $1" >> "$DETAILED_LOG"
}

print_banner() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text} - 4) / 2 ))
    local line=$(printf '%*s' "$width" | tr ' ' '=')
    
    echo -e "\n${BOLD}${BLUE}$line${NC}"
    echo -e "${BOLD}${BLUE}$(printf "%${padding}s" '')== $text ==$(printf "%${padding}s" '')${NC}"
    echo -e "${BOLD}${BLUE}$line${NC}\n"
    
    echo "[BANNER] $(date +"%Y-%m-%d %H:%M:%S") | $text" >> "$DETAILED_LOG"
}

# Function to log results to the report file
log_result() {
    local status=$1
    local tool=$2
    local message=$3
    local install_time=$4
    
    echo "[$status] $tool: $message" >> $REPORT_FILE
    
    if [ -n "$install_time" ]; then
        echo "  Time: $install_time seconds" >> $REPORT_FILE
    fi
    
    print_debug "Logged: [$status] $tool: $message${install_time:+ (${install_time}s)}"
    
    # Update tracking arrays
    INSTALL_STATUS["$tool"]="$status"
    INSTALL_NOTES["$tool"]="$message"
    
    if [ -n "$install_time" ]; then
        INSTALL_TIMES["$tool"]="$install_time"
    fi
}

# Function to create directories if they don't exist
create_directories() {
    print_status "Creating directory structure..."
    mkdir -p $TOOLS_DIR $VENV_DIR $LOG_DIR $BIN_DIR $CONFIG_DIR $HELPERS_DIR $DESKTOP_DIR $TEMP_DIR $SCRIPTS_DIR $SYSTEM_STATE_DIR
    chmod 755 $TOOLS_DIR $VENV_DIR $LOG_DIR $BIN_DIR $CONFIG_DIR $HELPERS_DIR $DESKTOP_DIR $TEMP_DIR $SCRIPTS_DIR $SYSTEM_STATE_DIR
    print_success "Directory structure created at $TOOLS_DIR"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root"
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
        
        # Clean up any temp files
        if [ -d "$TEMP_DIR" ]; then
            find "$TEMP_DIR" -type f -mtime +1 -delete
        fi
        
        # Save current system state
        if [ $exit_code -eq 0 ]; then
            save_system_state
        fi
    fi
    
    # Print final message based on exit code
    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then  # 130 is Ctrl+C
        print_error "Installation terminated with errors (code $exit_code). Check logs for details."
        print_info "Detailed log: $DETAILED_LOG"
        print_info "Report file: $REPORT_FILE"
    elif [ $exit_code -eq 130 ]; then
        print_warning "Installation interrupted by user."
    elif $DRY_RUN; then
        print_info "Dry run completed. No changes were made to the system."
    else
        print_success "Installation completed successfully."
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

# Function to parse YAML file
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*'
    local w='[a-zA-Z0-9_]*'
    sed -ne "s|^$s\($w\)$s:$s\"\(.*\)\"$s\$|\1=\"\2\"|p" $1 || true
}

# Function to show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --full              Install all tools (default)
  --core-only         Install only core tools
  --desktop-only      Configure desktop shortcuts only
  --headless          Run in headless mode (no GUI dependencies)
  --verbose           Show debug messages
  --auto              Run in automated mode (no prompts)
  --ignore-errors     Continue installation even if tools fail
  --force-reinstall   Reinstall tools even if already installed
  --skip-updates      Skip system updates
  --dry-run           Show what would be installed without making changes
  --help              Display this help message and exit

EXAMPLES:
  $0 --full                  # Full installation
  $0 --core-only             # Core tools only
  $0 --desktop-only          # Configure desktop shortcuts only
  $0 --headless              # Headless installation
  $0 --verbose               # Verbose output
  $0 --auto --full           # Full automated installation
  $0 --force-reinstall       # Reinstall all tools
  $0 --skip-updates          # Skip apt-get update/upgrade
  $0 --dry-run               # Simulation mode
EOF
}

# Function to run commands with timeout protection
run_with_timeout() {
    local cmd="$1"
    local timeout_seconds=$2
    local log_file="$3"
    local tool_name="$4"
    
    print_debug "Running command with ${timeout_seconds}s timeout: $cmd"
    
    # Only execute the command if not in dry run mode
    if ! $DRY_RUN; then
        timeout $timeout_seconds bash -c "$cmd" >> "$log_file" 2>&1
        local result=$?
        
        if [ $result -eq 124 ]; then
            # Check if the package was actually installed despite the timeout
            if [ ! -z "$tool_name" ] && dpkg -l | grep -q "$tool_name"; then
                print_success "$tool_name installed despite timeout."
                return 0
            else
                print_error "Command timed out after ${timeout_seconds} seconds"
                return 124
            fi
        else
            return $result
        fi
    else
        print_debug "[DRY RUN] Would execute: $cmd"
        return 0
    fi
}

# Function to validate tool installation
validate_tool() {
    local tool_name=$1
    local command=$2
    local validation_string=$3
    
    print_debug "Validating installation of $tool_name..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would validate $tool_name with: $command"
        return 0
    fi
    
    # Try to run the command
    if [ -z "$validation_string" ]; then
        # Just check if the command exists and runs without error
        if command -v $command >/dev/null 2>&1 && $command --help >/dev/null 2>&1; then
            print_debug "$tool_name validation successful: command $command exists and runs"
            return 0
        else
            print_warning "$tool_name validation failed: command $command not found or fails to run"
            return 1
        fi
    else
        # Check if the command output contains the validation string
        if command -v $command >/dev/null 2>&1 && $command --help 2>&1 | grep -q "$validation_string"; then
            print_debug "$tool_name validation successful: output contains '$validation_string'"
            return 0
        else
            print_warning "$tool_name validation failed: output does not contain '$validation_string'"
            return 1
        fi
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

# Function to save system state
save_system_state() {
    print_status "Creating system state snapshot for future reference..."
    
    # Create system state directory if it doesn't exist
    mkdir -p "$SYSTEM_STATE_DIR"
    
    # Create a system state report
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
        ls -la "$TOOLS_DIR/bin/" 2>/dev/null || echo "No tools found in $TOOLS_DIR/bin/"
        ls -la /usr/local/bin/ | grep -v "^l" | tail -n +2
        echo ""
        
        echo "==== PYTHON PACKAGES ===="
        pip list 2>/dev/null || echo "Pip not installed or no packages found"
        echo ""
        
        echo "==== DESKTOP SHORTCUTS ===="
        ls -la "$DESKTOP_DIR/" 2>/dev/null || echo "No desktop shortcuts found"
        echo ""
    } > "$SNAPSHOT_FILE"
    
    print_success "System state snapshot saved to: $SNAPSHOT_FILE"
}

# =================================================================
# DESKTOP INTEGRATION FUNCTIONS
# =================================================================

# Function to create desktop shortcuts for all installed tools
create_desktop_shortcut() {
    local name=$1
    local exec_command=$2
    local icon=$3
    local categories=$4
    
    if [ -z "$categories" ]; then
        categories="Security;"
    fi
    
    if [ -z "$icon" ]; then
        icon="utilities-terminal"
    fi
    
    print_debug "Creating desktop shortcut for $name..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would create desktop shortcut for $name"
        return 0
    fi
    
    # Create desktop entry in system applications directory
    cat > "/usr/share/applications/${name,,}.desktop" << EOF
[Desktop Entry]
Name=$name
Exec=$exec_command
Type=Application
Icon=$icon
Terminal=false
Categories=$categories
EOF
    
    # Also save a copy to our tools directory
    mkdir -p "$DESKTOP_DIR"
    cp "/usr/share/applications/${name,,}.desktop" "$DESKTOP_DIR/${name,,}.desktop"
    
    print_success "Desktop shortcut created for $name"
    return 0
}

# Function to create web shortcuts
create_web_shortcuts() {
    print_status "Creating web shortcuts..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would create web shortcuts"
        return 0
    fi
    
    # Create shortcuts for common web tools
    local web_tools=(
        "VirusTotal,https://www.virustotal.com/gui/home/search,web-browser,Network;Security;"
        "Fast People Search,https://www.fastpeoplesearch.com/names,web-browser,Network;Security;"
        "OSINT Framework,https://osintframework.com/,web-browser,Network;Security;"
        "Shodan,https://www.shodan.io/,web-browser,Network;Security;"
        "BuiltWith,https://builtwith.com/,web-browser,Network;Security;"
        "CVE Details,https://www.cvedetails.com/,web-browser,Network;Security;"
        "DNSDumpster,https://dnsdumpster.com/,web-browser,Network;Security;"
        "HaveIBeenPwned,https://haveibeenpwned.com/,web-browser,Network;Security;"
        "ExploitDB,https://www.exploit-db.com/,web-browser,Network;Security;"
        "GTFOBins,https://gtfobins.github.io/,web-browser,Network;Security;"
        "CyberChef,https://gchq.github.io/CyberChef/,web-browser,Network;Security;"
        "MITRE ATT&CK,https://attack.mitre.org/,web-browser,Network;Security;"
    )
    
    # Create the desktop entries
    for tool in "${web_tools[@]}"; do
        IFS=',' read -r name url icon categories <<< "$tool"
        
        cat > "/usr/share/applications/${name,,}.desktop" << EOF
[Desktop Entry]
Name=$name
Exec=xdg-open $url
Type=Application
Icon=${icon:-web-browser}
Terminal=false
Categories=${categories:-Network;WebBrowser;}
EOF
        
        # Also save a copy to our tools directory
        mkdir -p "$DESKTOP_DIR"
        cp "/usr/share/applications/${name,,}.desktop" "$DESKTOP_DIR/${name,,}.desktop"
        
        print_debug "Created shortcut for $name"
    done
    
    print_success "Web shortcuts created."
    log_result "SUCCESS" "web-shortcuts" "Created shortcuts for common web tools"
}

# Function to disable screen lock and power management
disable_screen_lock() {
    print_status "Disabling screen lock and power management..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would disable screen lock"
        return 0
    fi
    
    # Create the disable-lock-screen script
    mkdir -p "$SCRIPTS_DIR"
    cat > "$SCRIPTS_DIR/disable-lock-screen.sh" << 'EOF'
#!/usr/bin/env bash
#
# disable-lock-screen.sh
#
# A comprehensive script to disable screen lock & blanking in GNOME or Xfce on Kali.

echo "==> Disabling GNOME screensaver and lock screen (if GNOME is in use)..."

# Disable GNOME lock screen
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
# Disable auto-activation of screensaver
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
# Set lock delay to 0
gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null
# Attempt to disable lock on suspend (if key exists)
gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null

# Disable GNOME's power-related lock triggers
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null

echo "==> Disabling Xfce or light-locker (if Xfce is in use)..."
# Stop light-locker
pkill light-locker 2>/dev/null
# Disable it at startup
systemctl disable light-locker.service 2>/dev/null
# Turn off Xfce screensaver lock, if present
xfconf-query -c xfce4-screensaver -p /screensaver/lock_enabled -s false 2>/dev/null

echo "==> Disabling X11 screen blanking and DPMS..."
xset s off
xset s noblank
xset -dpms

echo "==> Adding X11 settings to autostart..."
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/disable-screen-blank.desktop <<EOT
[Desktop Entry]
Type=Application
Name=Disable Screen Blanking
Exec=sh -c "xset s off; xset s noblank; xset -dpms"
Terminal=false
Hidden=false
EOT

echo "==> Done! If it still locks, try removing lock packages:"
echo "    sudo apt-get remove gnome-screensaver light-locker xfce4-screensaver"
echo "==> You may need to log out and back in for all changes to take effect."
EOF
    
    chmod +x "$SCRIPTS_DIR/disable-lock-screen.sh"
    
    # Run the script for the current user
    if [ -n "$SUDO_USER" ]; then
        print_debug "Running disable-lock-screen.sh for $SUDO_USER..."
        su - $SUDO_USER -c "$SCRIPTS_DIR/disable-lock-screen.sh"
    else
        print_debug "Running disable-lock-screen.sh..."
        bash "$SCRIPTS_DIR/disable-lock-screen.sh"
    fi
    
    # Disable lock screen packages if present
    print_debug "Removing screensaver packages..."
    apt-get remove -y gnome-screensaver light-locker xfce4-screensaver 2>/dev/null
    
    print_success "Screen lock and power management disabled."
    log_result "SUCCESS" "screen-lock" "Disabled screen lock and power management"
}

# Function to set up environment
setup_environment() {
    print_status "Setting up environment..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would set up environment"
        return 0
    fi
    
    # Create setup_env.sh script to be sourced
    cat > "$TOOLS_DIR/setup_env.sh" << 'EOF'
#!/bin/bash
# Source this file to set up environment variables and paths for all security tools

# Set up environment
export SECURITY_TOOLS_DIR="/opt/security-tools"
export PATH="$PATH:$SECURITY_TOOLS_DIR/bin:/usr/local/bin"

# Function to activate a specific tool's virtual environment
activate_tool() {
    local tool=$1
    if [ -d "$SECURITY_TOOLS_DIR/venvs/$tool" ]; then
        source "$SECURITY_TOOLS_DIR/venvs/$tool/bin/activate"
        echo "Activated $tool virtual environment"
    else
        echo "Virtual environment for $tool not found"
    fi
}

# Add aliases for all available tools
for tool_venv in $SECURITY_TOOLS_DIR/venvs/*; do
    if [ -d "$tool_venv" ]; then
        tool_name=$(basename "$tool_venv")
        alias "activate-$tool_name"="activate_tool $tool_name"
    fi
done

# Tool-specific aliases and functions
alias bfg="java -jar $SECURITY_TOOLS_DIR/bfg.jar"
alias list-tools="ls -la $SECURITY_TOOLS_DIR/bin /usr/local/bin | grep -v '^l' | sort"
alias validate-tools="sudo $SECURITY_TOOLS_DIR/scripts/validate-tools.sh"

# Function to help navigate to tool directories
goto_tool() {
    local tool=$1
    if [ -d "$SECURITY_TOOLS_DIR/$tool" ]; then
        cd "$SECURITY_TOOLS_DIR/$tool"
    else
        echo "Tool directory for $tool not found"
    fi
}
alias goto=goto_tool

# Function to view tool logs
view_tool_log() {
    local tool=$1
    local log_dir="$SECURITY_TOOLS_DIR/logs"
    local log_file=$(find "$log_dir" -name "*${tool}*" | sort | tail -1)
    
    if [ -f "$log_file" ]; then
        less "$log_file"
    else
        echo "No log file found for $tool"
    fi
}
alias tool-log=view_tool_log

echo "Security tools environment has been set up."
EOF
    
    chmod +x "$TOOLS_DIR/setup_env.sh"
    
    # Create validate-tools.sh script
    cat > "$SCRIPTS_DIR/validate-tools.sh" << 'EOF'
#!/bin/bash
# Script to validate that tools are correctly installed and accessible

TOOLS_DIR="/opt/security-tools"
LOG_DIR="$TOOLS_DIR/logs"
VALIDATION_LOG="$LOG_DIR/tool_validation_$(date +%Y%m%d_%H%M%S).log"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Initialize log file
echo "Tool Validation Report" > "$VALIDATION_LOG"
echo "====================" >> "$VALIDATION_LOG"
echo "Date: $(date)" >> "$VALIDATION_LOG"
echo "" >> "$VALIDATION_LOG"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Validating installed tools...${NC}"

# List of common security tools to validate
declare -A TOOLS_TO_CHECK=(
    ["nmap"]="nmap -V | grep 'Nmap version'"
    ["wireshark"]="wireshark --version | grep 'Wireshark'"
    ["metasploit"]="msfconsole -v | grep 'Framework'"
    ["sqlmap"]="sqlmap --version | grep 'sqlmap'"
    ["hydra"]="hydra -h | grep 'Hydra'"
    ["burpsuite"]="burpsuite --help 2>&1 | grep -i 'Burp Suite'"
    ["responder"]="responder -h | grep 'NBT-NS/LLMNR'"
    ["bettercap"]="bettercap -v | grep 'bettercap v'"
    ["scoutsuite"]="scout --version 2>&1 | grep 'Scout Suite'"
    ["impacket"]="impacket-samrdump --help 2>&1 | grep 'impacket v'"
    ["prowler"]="prowler --version 2>&1 | grep 'Prowler'"
    ["crackmapexec"]="crackmapexec -h | grep 'CrackMapExec'"
    ["nikto"]="nikto -Version | grep 'Nikto v'"
    ["aircrack-ng"]="aircrack-ng --help | grep 'Aircrack-ng'"
    ["john"]="john --version | grep 'John the Ripper'"
    ["hashcat"]="hashcat -V | grep 'hashcat v'"
    ["wpscan"]="wpscan --version | grep 'WPScan v'"
    ["nessus"]="systemctl status nessusd | grep 'nessusd'"
    ["enum4linux"]="enum4linux -h | grep 'Enum4linux'"
    ["proxychains"]="proxychains -h 2>&1 | grep 'ProxyChains'"
    ["gobuster"]="gobuster -h | grep 'gobuster'"
    ["ffuf"]="ffuf -V | grep 'ffuf v'"
    ["dirsearch"]="dirsearch -h | grep 'dirsearch'"
    ["exploitdb"]="searchsploit -h | grep 'Exploit Database'"
    ["binwalk"]="binwalk -h | grep 'Binwalk v'"
    ["foremost"]="foremost -V | grep 'foremost version'"
    ["exiftool"]="exiftool -ver | grep '^[0-9]'"
    ["steghide"]="steghide --version | grep 'steghide '"
    ["evil-winrm"]="evil-winrm --version | grep 'Evil-WinRM '"
    ["gphish"]="gophish -h 2>&1 | grep -i 'gophish'"
    ["inveigh"]="inveigh -h 2>&1 | grep -i 'inveigh'"
    ["nuclei"]="nuclei -version | grep 'nuclei '"
    ["pymeta"]="pymeta -h | grep 'pymeta v'"
    ["kali-anonsurf"]="anonsurf --help 2>&1 | grep -i 'anonsurf'"
    ["teamviewer"]="teamviewer --help 2>&1 | grep -i 'teamviewer'"
    ["bfg"]="bfg --version 2>&1 | grep -i 'BFG'"
)

success_count=0
failure_count=0
total_count=${#TOOLS_TO_CHECK[@]}

echo -e "${BLUE}[i] Checking $total_count tools...${NC}"
echo "" >> "$VALIDATION_LOG"
echo "Tool Check Results:" >> "$VALIDATION_LOG"
echo "-------------------" >> "$VALIDATION_LOG"

# Validate each tool
for tool in "${!TOOLS_TO_CHECK[@]}"; do
    command=${TOOLS_TO_CHECK[$tool]}
    echo -e "${YELLOW}[*] Checking $tool...${NC}"
    
    # Try to execute the validation command
    if eval "$command" &>/dev/null; then
        echo -e "${GREEN}[+] $tool is correctly installed and accessible${NC}"
        echo "[SUCCESS] $tool: Installed and accessible" >> "$VALIDATION_LOG"
        ((success_count++))
    else
        if command -v $tool &>/dev/null; then
            echo -e "${YELLOW}[!] $tool exists but validation failed${NC}"
            echo "[WARNING] $tool: Command exists but validation failed" >> "$VALIDATION_LOG"
        else
            echo -e "${RED}[-] $tool is not installed or not in PATH${NC}"
            echo "[FAILED] $tool: Not installed or not in PATH" >> "$VALIDATION_LOG"
        fi
        ((failure_count++))
    fi
done

# Print summary
echo ""
echo -e "${BLUE}[i] Validation complete:${NC}"
echo -e "${GREEN}[+] $success_count tools successfully validated${NC}"
echo -e "${RED}[-] $failure_count tools failed validation${NC}"
echo -e "${YELLOW}[*] Results saved to: $VALIDATION_LOG${NC}"

# Add summary to log
echo "" >> "$VALIDATION_LOG"
echo "Summary:" >> "$VALIDATION_LOG"
echo "========" >> "$VALIDATION_LOG"
echo "Total tools checked: $total_count" >> "$VALIDATION_LOG"
echo "Successfully validated: $success_count" >> "$VALIDATION_LOG"
echo "Failed validation: $failure_count" >> "$VALIDATION_LOG"

exit 0
EOF

    chmod +x "$SCRIPTS_DIR/validate-tools.sh"
    
    # Add to bash.bashrc for all users
    if ! grep -q "security-tools/setup_env.sh" /etc/bash.bashrc; then
        echo -e "\n# Security tools environment setup" >> /etc/bash.bashrc
        echo "[ -f /opt/security-tools/setup_env.sh ] && source /opt/security-tools/setup_env.sh" >> /etc/bash.bashrc
    fi
    
    print_success "Environment setup complete."
}

# =================================================================
# INSTALLATION FUNCTIONS
# =================================================================

# Function to set up a Python virtual environment for a tool
setup_venv() {
    local tool_name=$1
    print_debug "Setting up virtual environment for $tool_name..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would set up Python virtual environment for $tool_name"
        return 0
    fi
    
    if [ ! -d "$VENV_DIR/$tool_name" ]; then
        python3 -m venv "$VENV_DIR/$tool_name"
    fi
    
    # Activate the virtual environment
    source "$VENV_DIR/$tool_name/bin/activate"
    
    # Upgrade pip in the virtual environment
    pip install --upgrade pip >> "$LOG_DIR/${tool_name}_venv_setup.log" 2>&1
}

# Function to install an apt package with improved error handling and conflict resolution
install_apt_package() {
    local package_name=$1
    local conflicting_packages=$2  # Optional: comma-separated list
    local log_file="$LOG_DIR/${package_name}_apt_install.log"
    local start_time=$(date +%s)
    
    # Check if already installed and not forcing reinstall
    if ! $FORCE_REINSTALL && dpkg -l | grep -q "^ii  $package_name "; then
        print_info "$package_name already installed."
        log_result "SKIPPED" "$package_name" "Already installed"
        return 0
    fi
    
    print_status "Installing $package_name with apt..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install $package_name with apt"
        log_result "SIMULATED" "$package_name" "Would be installed with apt"
        return 0
    fi
    
    # Clear log file
    > "$log_file"
    
    # Handle conflicts if specified
    if [ ! -z "$conflicting_packages" ]; then
        for pkg in $(echo $conflicting_packages | tr ',' ' '); do
            if dpkg -l | grep -q $pkg; then
                print_status "Removing conflicting package $pkg..."
                apt-get remove -y $pkg >> "$log_file" 2>&1
                if [ $? -ne 0 ]; then
                    print_error "Failed to remove conflicting package $pkg."
                    log_result "FAILED" "$package_name" "Unable to resolve conflict with $pkg. See $log_file for details."
                    return 1
                fi
            fi
        done
    fi
    
    # Install the package with a timeout
    run_with_timeout "DEBIAN_FRONTEND=noninteractive apt-get install -y $package_name" $APT_INSTALL_TIMEOUT "$log_file" "$package_name"
    local result=$?
    
    # Check if the package is installed regardless of timeout
    if dpkg -l | grep -q "^ii  $package_name "; then
        local end_time=$(date +%s)
        local install_time=$((end_time - start_time))
        print_success "$package_name installed with apt in ${install_time}s."
        log_result "SUCCESS" "$package_name" "Installed with apt" "$install_time"
        return 0
    else
        print_error "Failed to install $package_name with apt (exit code $result)."
        
        # Extract and display error messages from the log
        if [ -f "$log_file" ]; then
            local error_msg=$(grep -i "error\|failed\|not found" "$log_file" | head -3)
            if [ -n "$error_msg" ]; then
                print_error "Error details: $error_msg"
            fi
        fi
        
        log_result "FAILED" "$package_name" "Apt installation failed. See $log_file for details."
        
        # Try alternative apt approach if it seems to be a repository issue
        if grep -q "404 Not Found\|could not resolve\|connection failed" "$log_file"; then
            print_warning "Repository issue detected. Trying alternative approach..."
            apt-get update >> "$log_file" 2>&1
            apt-get install -y --fix-missing $package_name >> "$log_file" 2>&1
            
            if dpkg -l | grep -q "^ii  $package_name "; then
                local end_time=$(date +%s)
                local install_time=$((end_time - start_time))
                print_success "$package_name installed with alternative apt approach in ${install_time}s."
                log_result "SUCCESS" "$package_name" "Installed with alternative apt approach" "$install_time"
                return 0
            else
                print_error "Alternative apt approach also failed."
            fi
        fi
        
        # Continue if we're ignoring errors
        if $IGNORE_ERRORS; then
            print_warning "Continuing despite installation failure (--ignore-errors flag is set)"
            return 0
        else
            return 1
        fi
    fi
}

# Function to install multiple apt packages more efficiently
install_apt_packages() {
    local packages=$1  # comma-separated list
    print_step "Installing apt packages: $packages"
    
    # Convert comma-separated list to array
    IFS=',' read -ra PKG_ARRAY <<< "$packages"
    
    # Install packages in batches for better speed
    # Batch size: Up to PARALLEL_JOBS packages at once
    local batch_size=$PARALLEL_JOBS
    local total_packages=${#PKG_ARRAY[@]}
    local batch_count=$(( (total_packages + batch_size - 1) / batch_size ))
    
    print_info "Installing $total_packages packages in $batch_count batches (max $batch_size per batch)"
    
    for ((i=0; i<total_packages; i+=batch_size)); do
        local batch_start=$i
        local batch_end=$((i + batch_size - 1))
        if [ $batch_end -ge $total_packages ]; then
            batch_end=$((total_packages - 1))
        fi
        
        local batch_pkgs=()
        for ((j=batch_start; j<=batch_end; j++)); do
            batch_pkgs+=("${PKG_ARRAY[$j]}")
        done
        
        print_status "Installing batch $((i/batch_size + 1))/$batch_count: ${batch_pkgs[*]}"
        
        if $DRY_RUN; then
            print_debug "[DRY RUN] Would install: ${batch_pkgs[*]}"
            for pkg in "${batch_pkgs[@]}"; do
                log_result "SIMULATED" "$pkg" "Would be installed with apt"
            done
            continue
        fi
        
        # Install the batch
        if command -v parallel &> /dev/null && [ ${#batch_pkgs[@]} -gt 1 ]; then
            # Use parallel for faster installation
            printf '%s\n' "${batch_pkgs[@]}" | parallel -j$PARALLEL_JOBS "bash -c 'source \"$0\"; install_apt_package {}'" "$0"
        else
            # Fall back to sequential installation for this batch
            for pkg in "${batch_pkgs[@]}"; do
                install_apt_package "$pkg"
            done
        fi
    done
    
    print_success "Apt package installation complete."
}

# Function to install a tool using pipx with retry logic
install_with_pipx() {
    local package_name=$1
    local log_file="$LOG_DIR/${package_name}_pipx_install.log"
    local start_time=$(date +%s)
    
    # Check if already installed and not forcing reinstall
    if ! $FORCE_REINSTALL && command -v "$package_name" &> /dev/null; then
        print_info "$package_name already installed with pipx."
        log_result "SKIPPED" "$package_name" "Already installed with pipx"
        return 0
    fi
    
    print_status "Installing $package_name with pipx..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install $package_name with pipx"
        log_result "SIMULATED" "$package_name" "Would be installed with pipx"
        return 0
    fi
    
    # Clear log file
    > "$log_file"
    
    # Try up to 3 times with increasing timeouts
    for attempt in 1 2 3; do
        print_debug "Attempt $attempt of 3..."
        timeout $((120 * attempt)) pipx install $package_name >> $log_file 2>&1
        
        if [ $? -eq 0 ]; then
            local end_time=$(date +%s)
            local install_time=$((end_time - start_time))
            print_success "$package_name installed with pipx on attempt $attempt in ${install_time}s."
            log_result "SUCCESS" "$package_name" "Installed with pipx (attempt $attempt)" "$install_time"
            
            # Create symlinks to /usr/local/bin for easier access
            if [ -f "$HOME/.local/bin/$package_name" ]; then
                ln -sf "$HOME/.local/bin/$package_name" "/usr/local/bin/$package_name"
            fi
            
            return 0
        elif [ $? -eq 124 ]; then
            print_error "Installation timed out on attempt $attempt."
            echo "Attempt $attempt timed out." >> $log_file
        else
            print_error "Installation failed on attempt $attempt."
        fi
        
        # Extract and display error messages from the log
        if [ -f "$log_file" ]; then
            local error_msg=$(grep -i "error\|failed\|not found" "$log_file" | head -3)
            if [ -n "$error_msg" ]; then
                print_error "Error details: $error_msg"
            fi
        fi
        
        # Wait before retrying
        sleep 5
    done
    
    print_error "All attempts to install $package_name with pipx have failed."
    log_result "FAILED" "$package_name" "Pipx installation failed after 3 attempts. See $log_file for details."
    
    # Continue if we're ignoring errors
    if $IGNORE_ERRORS; then
        print_warning "Continuing despite installation failure (--ignore-errors flag is set)"
        return 0
    else
        return 1
    fi
}

# Function to install multiple pipx packages with better parallelization
install_pipx_packages() {
    local packages=$1  # comma-separated list
    print_step "Installing pipx packages: $packages"
    
    # Convert comma-separated list to array
    IFS=',' read -ra PKG_ARRAY <<< "$packages"
    local total_packages=${#PKG_ARRAY[@]}
    
    # Ensure pipx is installed
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would ensure pipx is installed"
    else
        if ! command -v pipx &> /dev/null; then
            print_status "Installing pipx..."
            apt-get install -y python3-pip python3-venv >> "$LOG_DIR/pipx_install.log" 2>&1
            python3 -m pip install --user pipx >> "$LOG_DIR/pipx_install.log" 2>&1
            python3 -m pipx ensurepath >> "$LOG_DIR/pipx_install.log" 2>&1
            export PATH="$PATH:$HOME/.local/bin"
        fi
    fi
    
    print_info "Installing $total_packages pipx packages"
    
    # Install packages with parallelization if available
    if command -v parallel &> /dev/null && ! $DRY_RUN; then
        # Use parallel for faster installation - limit to half the cores to avoid overloading
        local pipx_jobs=$(( PARALLEL_JOBS / 2 ))
        if [ $pipx_jobs -lt 1 ]; then pipx_jobs=1; fi
        
        print_debug "Using GNU parallel with $pipx_jobs concurrent jobs"
        printf '%s\n' "${PKG_ARRAY[@]}" | parallel -j$pipx_jobs "bash -c 'source \"$0\"; install_with_pipx {}'" "$0"
    else
        # Fall back to sequential installation
        for pkg in "${PKG_ARRAY[@]}"; do
            install_with_pipx "$pkg"
        done
    fi
    
    print_success "Pipx package installation complete."
}

# Function to download binary and make executable with retry
download_binary() {
    local url=$1
    local output_file=$2
    local executable_name=$(basename $output_file)
    local log_file="$LOG_DIR/${executable_name}_download.log"
    local start_time=$(date +%s)
    
    # Check if file already exists and not forcing reinstall
    if ! $FORCE_REINSTALL && [ -f "$output_file" ]; then
        print_info "$executable_name already downloaded."
        log_result "SKIPPED" "$executable_name" "Already downloaded"
        return 0
    fi
    
    print_status "Downloading $executable_name from $url..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would download $executable_name from $url"
        log_result "SIMULATED" "$executable_name" "Would be downloaded"
        return 0
    fi
    
    # Clear log file
    > "$log_file"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"
    
    # Try up to 3 times
    for attempt in 1 2 3; do
        print_debug "Download attempt $attempt of 3..."
        
        # Try different download tools in order of preference
        if command -v curl &> /dev/null; then
            timeout $DOWNLOAD_TIMEOUT curl -L "$url" -o "$output_file" >> "$log_file" 2>&1
        elif command -v wget &> /dev/null; then
            timeout $DOWNLOAD_TIMEOUT wget "$url" -O "$output_file" >> "$log_file" 2>&1
        else
            # If neither curl nor wget is available, install curl
            apt-get install -y curl >> "$log_file" 2>&1
            timeout $DOWNLOAD_TIMEOUT curl -L "$url" -o "$output_file" >> "$log_file" 2>&1
        fi
        
        if [ $? -eq 0 ] && [ -f "$output_file" ]; then
            chmod +x "$output_file"
            local end_time=$(date +%s)
            local download_time=$((end_time - start_time))
            print_success "$executable_name downloaded and made executable in ${download_time}s."
            log_result "SUCCESS" "$executable_name" "Downloaded and made executable" "$download_time"
            return 0
        elif [ $? -eq 124 ]; then
            print_error "Download timed out on attempt $attempt."
            echo "Attempt $attempt timed out." >> "$log_file"
        else
            print_error "Download failed on attempt $attempt."
        fi
        
        # Extract and display error messages from the log
        if [ -f "$log_file" ]; then
            local error_msg=$(grep -i "error\|failed\|not found" "$log_file" | head -3)
            if [ -n "$error_msg" ]; then
                print_error "Error details: $error_msg"
            fi
        fi
        
        # Wait before retrying
        sleep 5
    done
    
    print_error "All attempts to download $executable_name have failed."
    log_result "FAILED" "$executable_name" "Download failed after 3 attempts. See $log_file for details."
    
    # Continue if we're ignoring errors
    if $IGNORE_ERRORS; then
        print_warning "Continuing despite download failure (--ignore-errors flag is set)"
        return 0
    else
        return 1
    fi
}

# Function to install GitHub tool with improved error handling
install_github_tool() {
    local repo_url=$1
    local tool_name=$(basename $repo_url .git)
    local log_file="$LOG_DIR/${tool_name}_install.log"
    local start_time=$(date +%s)
    
    print_status "Installing $tool_name from $repo_url..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install $tool_name from $repo_url"
        log_result "SIMULATED" "$tool_name" "Would be installed from GitHub"
        return 0
    fi
    
    # Clear log file
    > "$log_file"
    
    # Clone or update the repository
    if [ -d "$TOOLS_DIR/$tool_name" ] && ! $FORCE_REINSTALL; then
        print_debug "$tool_name directory already exists. Updating..."
        cd "$TOOLS_DIR/$tool_name"
        git pull >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_warning "Failed to update $tool_name repository. Continuing with existing version."
            log_result "PARTIAL" "$tool_name" "Update failed, using existing version"
        else
            print_success "$tool_name repository updated."
        fi
    else
        # Remove existing directory if force reinstall
        if [ -d "$TOOLS_DIR/$tool_name" ] && $FORCE_REINSTALL; then
            print_debug "Removing existing $tool_name directory for force reinstall..."
            rm -rf "$TOOLS_DIR/$tool_name"
        fi
        
        cd "$TOOLS_DIR"
        # Use timeout to prevent hanging git clones
        run_with_timeout "git clone $repo_url" $GIT_CLONE_TIMEOUT $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to clone $tool_name repository."
            log_result "FAILED" "$tool_name" "Git clone failed. See $log_file for details."
            
            # Continue if we're ignoring errors
            if $IGNORE_ERRORS; then
                print_warning "Continuing despite installation failure (--ignore-errors flag is set)"
                return 0
            else
                return 1
            fi
        fi
        cd "$tool_name"
    fi
    
    local result=0
    process_git_repo $tool_name
    result=$?
    
    local end_time=$(date +%s)
    local install_time=$((end_time - start_time))
    
    # Return appropriate status code
    if [ $result -eq 0 ]; then
        print_success "$tool_name installed successfully in ${install_time}s."
        log_result "SUCCESS" "$tool_name" "Installed from GitHub" "$install_time"
        return 0
    elif $IGNORE_ERRORS; then
        print_warning "Continuing despite installation failure (--ignore-errors flag is set)"
        return 0
    else
        return $result
    fi
}

# Function to process Git repositories properly
process_git_repo() {
    local repo_name=$1
    local log_file="$LOG_DIR/${repo_name}_process.log"
    
    print_debug "Processing $repo_name repository..."
    cd "$TOOLS_DIR/$repo_name"
    
    # Look for installation instructions in README files
    if [ -f "README.md" ]; then
        README_FILE="README.md"
    elif [ -f "README" ]; then
        README_FILE="README"
    elif [ -f "README.txt" ]; then
        README_FILE="README.txt"
    else
        README_FILE=""
    fi
    
    # Check for common installation patterns
    if [ -n "$README_FILE" ]; then
        print_debug "Found README file, checking for installation instructions..."
        
        # Check if a Python script is intended to be run directly
        MAIN_PY=$(find . -maxdepth 2 -name "*.py" | grep -i -E 'main|run|start' | head -1)
        if [ -n "$MAIN_PY" ]; then
            chmod +x "$MAIN_PY"
            print_debug "Creating wrapper script for ${repo_name}..."
            
            cat > "/usr/local/bin/${repo_name,,}" << EOF
#!/bin/bash
cd "$TOOLS_DIR/$repo_name"
python3 "$MAIN_PY" "\$@"
EOF
            chmod +x "/usr/local/bin/${repo_name,,}"
            create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
            
            print_success "Created executable wrapper for $repo_name."
            log_result "SUCCESS" "$repo_name" "Created executable wrapper and desktop shortcut"
            return 0
        fi
        
        # Check for installation instructions involving pip install
        if grep -q "pip install" "$README_FILE"; then
            print_debug "Found pip install instructions, installing in virtual environment..."
            
            setup_venv "$repo_name"
            if grep -q "pip install -e ." "$README_FILE"; then
                pip install -e . >> "$log_file" 2>&1
            elif grep -q "pip install ." "$README_FILE"; then
                pip install . >> "$log_file" 2>&1
            elif grep -q "pip install -r requirements.txt" "$README_FILE"; then
                pip install -r requirements.txt >> "$log_file" 2>&1
                pip install . >> "$log_file" 2>&1
            else
                pip install . >> "$log_file" 2>&1
            fi
            
            # Try to find any executables that were installed
            find /usr/local/bin -newer "$LOG_DIR/${repo_name}_install.log" -type f | while read -r exec_file; do
                print_debug "Found newly installed executable: $exec_file"
                # Create symlink in our bin directory too
                mkdir -p "$BIN_DIR"
                ln -sf "$exec_file" "$BIN_DIR/$(basename $exec_file)"
            done
            
            return 0
        fi
    fi
    
    # Generic handling if we couldn't determine specific instructions
    print_debug "Could not determine specific installation method, using generic approach..."
    
    # Look for any executable files
    EXECUTABLE=$(find . -type f -executable -not -path "*/\.*" | head -1)
    if [ -n "$EXECUTABLE" ]; then
        ln -sf "$TOOLS_DIR/$repo_name/$EXECUTABLE" "/usr/local/bin/${repo_name,,}"
        # Create symlink in our bin directory too
        mkdir -p "$BIN_DIR"
        ln -sf "$TOOLS_DIR/$repo_name/$EXECUTABLE" "$BIN_DIR/${repo_name,,}"
        create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
        
        print_success "Linked executable for $repo_name."
        log_result "SUCCESS" "$repo_name" "Linked executable and created desktop shortcut"
        return 0
    fi
    
    # Create a readme viewer as a last resort
    if [ -n "$README_FILE" ]; then
        cat > "/usr/local/bin/${repo_name,,}-info" << EOF
#!/bin/bash
cd "$TOOLS_DIR/$repo_name"
less "$README_FILE"
EOF
        chmod +x "/usr/local/bin/${repo_name,,}-info"
        
        cat > "/usr/share/applications/${repo_name,,}-info.desktop" << EOF
[Desktop Entry]
Name=$repo_name Info
Exec=gnome-terminal -- /usr/local/bin/${repo_name,,}-info
Type=Application
Icon=text-x-generic
Terminal=false
Categories=Security;Documentation;
EOF
        
        print_info "Created info viewer for $repo_name."
        log_result "PARTIAL" "$repo_name" "Created info viewer for documentation"
    else
        log_result "PARTIAL" "$repo_name" "Could not determine installation method"
    fi
    
    return 1
}

# Function to install multiple GitHub tools potentially in parallel
install_github_tools() {
    local repo_urls=$1  # comma-separated list
    print_step "Installing GitHub tools: $repo_urls"
    
    # Convert comma-separated list to array
    IFS=',' read -ra REPO_ARRAY <<< "$repo_urls"
    local total_repos=${#REPO_ARRAY[@]}
    
    print_info "Installing $total_repos GitHub repositories"
    
    # Install each repo (can be parallelized with GNU Parallel if available)
    if command -v parallel &> /dev/null && [ ${#REPO_ARRAY[@]} -gt 1 ] && ! $DRY_RUN; then
        # Use parallel for faster installation - limit to half the cores to avoid overloading
        local git_jobs=$(( PARALLEL_JOBS / 2 ))
        if [ $git_jobs -lt 1 ]; then git_jobs=1; fi
        
        print_debug "Using GNU parallel with $git_jobs concurrent jobs"
        printf '%s\n' "${REPO_ARRAY[@]}" | parallel -j$git_jobs "bash -c 'source \"$0\"; install_github_tool {}'" "$0"
    else
        # Fall back to sequential installation
        for repo in "${REPO_ARRAY[@]}"; do
            install_github_tool "$repo"
        done
    fi
    
    print_success "GitHub tools installation complete."
}

# Function to create manual installation helpers
create_manual_helper() {
    local tool_name="$1"
    local instructions="$2"
    local file="$HELPERS_DIR/install_${tool_name}.sh"

    print_debug "Creating manual installation helper for $tool_name..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would create manual helper for $tool_name"
        log_result "SIMULATED" "$tool_name" "Would create manual installation helper"
        return 0
    fi
    
    mkdir -p "$HELPERS_DIR"
    
    cat > "$file" <<EOF
#!/bin/bash
# Manual installation helper for $tool_name
# Created by RTA Tools Installer
# Run with: sudo $file

set -e
echo "========================================================="
echo "   Manual Installation Helper for $tool_name"
echo "========================================================="

$instructions

echo "========================================================="
echo "Installation of $tool_name complete."
echo "========================================================="
EOF

    chmod +x "$file"
    print_info "Created manual helper: $file"
    log_result "MANUAL" "$tool_name" "Helper script created at $file"
}

# Function to generate all needed manual installation helpers
generate_manual_helpers() {
    print_step "Generating manual installation helpers..."
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would generate manual installation helpers"
        return 0
    fi
    
    create_manual_helper "nessus" "echo '1. Visit: https://www.tenable.com/downloads/nessus'
echo '2. Download the Debian package for your version.'
echo '3. Run: sudo dpkg -i Nessus-*.deb && sudo apt-get install -f -y'
echo '4. Enable and start service: sudo systemctl enable nessusd && sudo systemctl start nessusd'
echo '5. Access https://localhost:8834 to complete setup.'

# Try automatic download if wanted
read -p 'Would you like to try automatic download? (y/n): ' auto_download
if [[ \$auto_download == 'y' ]]; then
    cd /tmp
    echo 'Attempting to download Nessus...'
    curl -k --request GET --url 'https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-10.8.3-debian10_amd64.deb' --output nessus_amd64.deb
    
    if [ -f 'nessus_amd64.deb' ]; then
        echo 'Installing Nessus package...'
        sudo dpkg -i nessus_amd64.deb
        sudo apt-get install -f -y
        sudo systemctl enable nessusd
        sudo systemctl start nessusd
        echo 'Nessus installed. Access at https://localhost:8834/'
    else
        echo 'Download failed. Please download manually.'
    fi
fi"

    create_manual_helper "vmware_remote_console" "echo 'Visit: https://knowledge.broadcom.com/external/article/368995/download-vmware-remote-console.html'
echo 'Download the latest .bundle file and run it with:'
echo 'chmod +x VMware-Remote-Console*.bundle && sudo ./VMware-Remote-Console*.bundle'

# Look for existing bundle files
vmware_bundle=\$(find ~/Downloads ~/Desktop -name 'VMware-Remote-Console*.bundle' 2>/dev/null | head -1)
if [ -n \"\$vmware_bundle\" ]; then
    echo \"Found VMware Remote Console bundle at \$vmware_bundle\"
    read -p 'Would you like to install it now? (y/n): ' install_now
    if [[ \$install_now == 'y' ]]; then
        chmod +x \"\$vmware_bundle\"
        sudo \"\$vmware_bundle\"
    fi
fi"

    create_manual_helper "burpsuite_enterprise" "echo '1. Place the Burp Suite Enterprise .zip file in ~/Desktop or ~/Downloads.'
echo '2. Extract and run the .run or .jar installer inside the extracted directory.'
echo '3. Follow GUI setup steps.'

# Look for existing installation files
burp_enterprise_zip=\$(find ~/Downloads ~/Desktop -name 'burp_enterprise*.zip' 2>/dev/null | head -1)
if [ -n \"\$burp_enterprise_zip\" ]; then
    echo \"Found Burp Enterprise ZIP at \$burp_enterprise_zip\"
    read -p 'Would you like to unpack and install it now? (y/n): ' install_now
    if [[ \$install_now == 'y' ]]; then
        install_dir=\"/opt/burp-enterprise\"
        mkdir -p \"\$install_dir\"
        echo \"Extracting Burp Enterprise to \$install_dir...\"
        unzip -q \"\$burp_enterprise_zip\" -d \"\$install_dir\"
        
        installer=\$(find \"\$install_dir\" -name \"*.run\" | head -1)
        if [ -n \"\$installer\" ]; then
            echo \"Found installer: \$(basename \"\$installer\")\"
            chmod +x \"\$installer\"
            echo \"Running installer...\"
            \"\$installer\"
        else
            jar_installer=\$(find \"\$install_dir\" -name \"*.jar\" | head -1)
            if [ -n \"\$jar_installer\" ]; then
                echo \"Found JAR installer: \$(basename \"\$jar_installer\")\"
                echo \"Creating wrapper script...\"
                wrapper=\"\$install_dir/burpsuite_enterprise\"
                cat > \"\$wrapper\" << 'EOD'
#!/bin/bash
cd \"\$(dirname \"\$0\")\"
java -jar \"\$(basename \"\$jar_installer\")\" \"\$@\"
EOD
                chmod +x \"\$wrapper\"
                ln -sf \"\$wrapper\" \"/usr/local/bin/burpsuite_enterprise\"
                echo \"Burp Enterprise JAR set up successfully.\"
            else
                echo \"No installer found in the ZIP file.\"
            fi
        fi
    fi
fi"

    create_manual_helper "teamviewer" "echo 'Installing TeamViewer Host with workaround...'
dummy_dir=\"/tmp/policykit-dummy\"
mkdir -p \"\$dummy_dir/DEBIAN\"

cat > \"\$dummy_dir/DEBIAN/control\" <<'EOF'
Package: policykit-1
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Depends: polkitd, pkexec
Maintainer: System Administrator <root@localhost>
Description: Transitional package for PolicyKit
EOF

# Build and install the dummy package
apt-get install -y polkitd pkexec
dpkg-deb -b \"\$dummy_dir\" /tmp/policykit-1_1.0_all.deb
dpkg -i /tmp/policykit-1_1.0_all.deb

# Look for TeamViewer package
teamviewer_deb=\$(find ~/Downloads ~/Desktop -name 'teamviewer-host*.deb' 2>/dev/null | head -1)
if [ -n \"\$teamviewer_deb\" ]; then
    echo \"Found TeamViewer package at \$teamviewer_deb\"
    dpkg -i \"\$teamviewer_deb\"
    apt-get install -f -y
    
    # Configure TeamViewer
    teamviewer daemon enable
    systemctl enable teamviewerd.service
    teamviewer daemon start
    
    # Get the TeamViewer ID
    sleep 3
    teamviewer_id=\$(teamviewer info | grep \"TeamViewer ID:\" | awk '{print \$3}')
    echo \"TeamViewer ID: \$teamviewer_id\"
    
    # Create desktop shortcut
    cat > \"/usr/share/applications/teamviewer.desktop\" << EOD
[Desktop Entry]
Name=TeamViewer
Comment=TeamViewer Remote Control Application
Exec=teamviewer
Icon=/opt/teamviewer/tv_bin/desktop/teamviewer.png
Terminal=false
Type=Application
Categories=Network;RemoteAccess;
EOD
    
    echo \"TeamViewer Host installed successfully.\"
else
    echo \"No TeamViewer package found. Please download it from teamviewer.com\"
    echo \"and place it in your Downloads or Desktop folder, then run this script again.\"
fi"

    create_manual_helper "ninjaone" "# Installing NinjaOne agent
echo 'Looking for NinjaOne agent installer...'

ninjaone_deb=\$(find ~/Downloads ~/Desktop -name 'ninja-*.deb' 2>/dev/null | head -1)
if [ -n \"\$ninjaone_deb\" ]; then
    echo \"Found NinjaOne package at \$ninjaone_deb\"
    dpkg -i \"\$ninjaone_deb\"
    apt-get install -f -y
    
    # Ensure the service is enabled and started
    systemctl enable ninjarmm-agent.service
    systemctl start ninjarmm-agent.service
    
    echo 'NinjaOne agent installed and started.'
else
    echo 'NinjaOne .deb file not found. Please download it from your NinjaOne portal.'
    echo 'Then place it in your Downloads or Desktop folder and run this script again.'
fi"

    create_manual_helper "gophish" "echo 'Installing Gophish...'
cd /tmp

# Download Gophish
echo 'Downloading Gophish...'
wget https://github.com/gophish/gophish/releases/download/v0.12.1/gophish-v0.12.1-linux-64bit.zip -O gophish.zip

if [ -f 'gophish.zip' ]; then
    # Create installation directory
    mkdir -p /opt/gophish
    
    # Extract Gophish
    echo 'Extracting Gophish...'
    unzip -o gophish.zip -d /opt/gophish
    
    # Set permissions
    chmod +x /opt/gophish/gophish
    
    # Create systemd service
    cat > /etc/systemd/system/gophish.service << 'EOD'
[Unit]
Description=Gophish Phishing Framework
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/gophish
ExecStart=/opt/gophish/gophish
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOD

    # Enable and start service
    systemctl daemon-reload
    systemctl enable gophish.service
    systemctl start gophish.service
    
    # Create symlink to command
    ln -sf /opt/gophish/gophish /usr/local/bin/gophish
    
    # Create desktop shortcut
    cat > /usr/share/applications/gophish.desktop << EOD
[Desktop Entry]
Name=Gophish
Comment=Open-Source Phishing Framework
Exec=xdg-open http://127.0.0.1:3333/login
Type=Application
Icon=applications-internet
Terminal=false
Categories=Network;Security;
EOD
    
    echo 'Gophish installed successfully.'
    echo 'Admin interface: http://127.0.0.1:3333 (default creds: admin/gophish)'
    echo 'Phishing server: http://127.0.0.1:8080'
    
    # Clean up
    rm -f gophish.zip
else
    echo 'Download failed. Please install manually from https://github.com/gophish/gophish/releases'
fi"

    create_manual_helper "evilginx3" "echo 'Installing Evilginx3...'

# Make sure GO is installed
if ! command -v go &>/dev/null; then
    echo 'Installing Go...'
    apt-get update
    apt-get install -y golang
fi

# Clone the repository
echo 'Cloning Evilginx3 repository...'
git clone https://github.com/kingsmandralph/evilginx3.git /opt/evilginx3

if [ -d '/opt/evilginx3' ]; then
    cd /opt/evilginx3
    
    # Build the binary
    echo 'Building Evilginx3...'
    go build
    
    # Create symlink
    ln -sf /opt/evilginx3/evilginx3 /usr/local/bin/evilginx3
    
    # Create desktop shortcut
    cat > /usr/share/applications/evilginx3.desktop << EOD
[Desktop Entry]
Name=Evilginx3
Comment=Man-in-the-middle attack framework for phishing credentials
Exec=gnome-terminal -- evilginx3
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Network;Security;
EOD
    
    echo 'Evilginx3 installed successfully.'
    echo 'Run with: evilginx3'
else
    echo 'Failed to clone Evilginx3 repository.'
fi"

    print_success "Generated manual installation helpers"
}

# Function to install teamviewer with workaround
install_teamviewer_workaround() {
    print_step "Installing TeamViewer with compatibility workaround"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install TeamViewer with workaround"
        log_result "SIMULATED" "teamviewer-host" "Would install with workaround"
        return 0
    fi
    
    # Create a dummy policykit-1 package to satisfy TeamViewer's dependency
    dummy_dir="$TEMP_DIR/policykit-dummy"
    mkdir -p "$dummy_dir/DEBIAN"

    cat > "$dummy_dir/DEBIAN/control" << EOF
Package: policykit-1
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Depends: polkitd, pkexec
Maintainer: System Administrator <root@localhost>
Description: Transitional package for PolicyKit
EOF

    print_info "Building dummy policykit-1 package..."
    apt-get install -y polkitd pkexec >> "$LOG_DIR/teamviewer_deps.log" 2>&1
    dpkg-deb -b "$dummy_dir" "$TEMP_DIR/policykit-1_1.0_all.deb" >> "$LOG_DIR/policykit_build.log" 2>&1
    dpkg -i "$TEMP_DIR/policykit-1_1.0_all.deb" >> "$LOG_DIR/policykit_install.log" 2>&1

    # Look for TeamViewer package in common locations
    TEAMVIEWER_DEB=$(find /home/*/Desktop /home/*/Downloads -type f -name "teamviewer-host*.deb" 2>/dev/null | head -1)
    
    if [ -n "$TEAMVIEWER_DEB" ]; then
        print_status "Found TeamViewer package at $TEAMVIEWER_DEB"
        print_info "Installing TeamViewer from $TEAMVIEWER_DEB..."
        dpkg -i "$TEAMVIEWER_DEB" >> "$LOG_DIR/teamviewer_install.log" 2>&1
        apt-get install -f -y >> "$LOG_DIR/teamviewer_deps.log" 2>&1
        
        # Configure TeamViewer if installed successfully
        if dpkg -l | grep -q "teamviewer-host"; then
            print_status "Configuring TeamViewer..."
            teamviewer daemon enable >> "$LOG_DIR/teamviewer_config.log" 2>&1
            systemctl enable teamviewerd.service >> "$LOG_DIR/teamviewer_config.log" 2>&1
            teamviewer daemon start >> "$LOG_DIR/teamviewer_config.log" 2>&1
            
            # Get the TeamViewer ID for reference
            sleep 3
            TEAMVIEWER_ID=$(teamviewer info | grep "TeamViewer ID:" | awk '{print $3}')
            print_info "TeamViewer ID: $TEAMVIEWER_ID"
            
            # Create desktop shortcut if doesn't exist
            if [ ! -f "/usr/share/applications/teamviewer.desktop" ]; then
                create_desktop_shortcut "TeamViewer" "teamviewer" "/opt/teamviewer/tv_bin/desktop/teamviewer.png" "Network;RemoteAccess;Security;"
            fi
            
            print_success "TeamViewer Host installed and configured."
            log_result "SUCCESS" "teamviewer-host" "Installed with dependencies workaround"
        else
            print_error "TeamViewer installation failed."
            log_result "FAILED" "teamviewer-host" "Installation failed despite workaround"
        fi
    else
        print_info "TeamViewer package not found. Creating helper script."
        # The helper was already created in generate_manual_helpers
        log_result "MANUAL" "teamviewer-host" "Package not found, use $HELPERS_DIR/install_teamviewer.sh"
    fi
    
    # Clean up
    rm -rf "$dummy_dir" "$TEMP_DIR/policykit-1_1.0_all.deb"
}

# Function to modify config files if needed
create_config_file() {
    print_status "Creating configuration file..."
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would create/update configuration file"
        return 0
    fi
    
    # Create default config.yml if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# RTA Tools Installer Configuration
# Modify this file to customize your RTA setup

# Core apt tools - installed with apt-get
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,seclists,proxychains4,responder,metasploit-framework,exploitdb,nikto,dirb,dirbuster,whatweb,wpscan,masscan,aircrack-ng,john,hashcat,crackmapexec,enum4linux,gobuster,ffuf,steghide,binwalk,foremost,exiftool,httpie,rlwrap,nbtscan,ncat,netcat-traditional,netdiscover,dnsutils,whois,net-tools,putty,rdesktop,freerdp2-x11,snmp,golang,nodejs,npm,python3-dev,build-essential,xsltproc,parallel"

# Python tools - installed with pipx
pipx_tools: "scoutsuite,impacket,pymeta,fierce,pwnedpasswords,trufflehog,pydictor,apkleaks,wfuzz,hakrawler,sublist3r,nuclei,recon-ng,commix,evil-winrm,droopescan,sshuttle,gitleaks,stegcracker,pypykatz"

# GitHub repositories
git_tools: "https://github.com/prowler-cloud/prowler.git,https://github.com/ImpostorKeanu/parsuite.git,https://github.com/fin3ss3g0d/evilgophish.git,https://github.com/Und3rf10w/kali-anonsurf.git,https://github.com/s0md3v/XSStrike.git,https://github.com/swisskyrepo/PayloadsAllTheThings.git,https://github.com/danielmiessler/SecLists.git,https://github.com/internetwache/GitTools.git,https://github.com/digininja/CeWL.git,https://github.com/gchq/CyberChef.git,https://github.com/Kevin-Robertson/Inveigh.git,https://github.com/projectdiscovery/nuclei.git,https://github.com/m8sec/pymeta.git"

# Manual tools - installation helpers will be generated
manual_tools: "nessus,vmware_remote_console,burpsuite_enterprise,teamviewer,ninjaone,gophish,evilginx3"
EOF
    fi
    
    print_success "Configuration file created at $CONFIG_FILE"
}

# Function to install additional dependencies
install_dependencies() {
    print_step "Installing core dependencies"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install dependencies"
        return 0
    fi
    
    # Core build dependencies
    DEPS="git python3 python3-pip python3-venv golang nodejs npm curl wget python3-dev"
    DEPS="$DEPS pipx openjdk-17-jdk unzip build-essential parallel"
    
    # Additional dependencies for specific tools
    DEPS="$DEPS net-tools dnsutils whois ncat netcat-traditional"
    
    # Install initial dependencies in one batch for speed
    print_status "Installing core dependencies: $DEPS"
    apt-get update >> "$LOG_DIR/apt_update.log" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y $DEPS >> "$LOG_DIR/dependencies_install.log" 2>&1
    
    # Ensure PATH includes local bin directories
    export PATH="$PATH:$HOME/.local/bin:/usr/local/bin"
    
    print_success "Core dependencies installed"
    log_result "SUCCESS" "dependencies" "Core dependencies installed"
}

# =================================================================
# MAIN INSTALLATION FUNCTIONS
# =================================================================

# Install core tools
install_core_tools() {
    print_step "Installing core security tools"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would install core tools"
        return 0
    fi
    
    # Core apt tools
    APT_CORE="nmap wireshark sqlmap hydra bettercap proxychains4 responder metasploit-framework"
    install_apt_packages "$APT_CORE"
    
    # Core pipx tools
    PIPX_CORE="impacket"
    install_pipx_packages "$PIPX_CORE"
    
    print_success "Core tools installed"
    log_result "SUCCESS" "core_tools" "Essential security tools installed"
}

# Install desktop shortcuts and configuration
install_desktop_integration() {
    print_step "Setting up desktop integration"
    
    if $DRY_RUN; then
        print_debug "[DRY RUN] Would set up desktop integration"
        return 0
    fi
    
    # Create web shortcuts
    create_web_shortcuts
    
    # Set up environment
    setup_environment
    
    # Disable screen lock and power management
    disable_screen_lock
    
    # Create RTA menu entry for reports and tools
    cat > "/usr/share/applications/rta-tools.desktop" << EOF
[Desktop Entry]
Name=RTA Tools
Comment=Access RTA security tools and reports
Exec=xdg-open /opt/security-tools
Type=Application
Icon=security-high
Terminal=false
Categories=System;Security;
EOF

    print_success "Desktop integration complete"
    log_result "SUCCESS" "desktop" "Desktop integration and shortcuts created"
}

# Install full toolkit
install_full_toolkit() {
    print_step "Installing full security toolkit"
    
    # Load configuration
    if [ -f "$CONFIG_FILE" ]; then
        print_debug "Loading config from $CONFIG_FILE"
        eval $(parse_yaml "$CONFIG_FILE")
    else
        print_warning "Config file not found. Creating default config..."
        create_config_file
        eval $(parse_yaml "$CONFIG_FILE")
    fi
    
    # Install dependencies first
    install_dependencies
    
    # Check if we need to skip updates
    if ! $SKIP_UPDATES; then
        print_status "Updating system..."
        if $DRY_RUN; then
            print_debug "[DRY RUN] Would update system packages"
        else
            apt-get update >> "$LOG_DIR/apt_update.log" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y >> "$LOG_DIR/apt_upgrade.log" 2>&1
        fi
        print_success "System updated"
    else
        print_info "System updates skipped (--skip-updates flag)"
    fi
    
    # Install apt packages
    install_apt_packages "$apt_tools"
    
    # Install pipx packages
    install_pipx_packages "$pipx_tools"
    
    # Install GitHub tools
    install_github_tools "$git_tools"
    
    # Install TeamViewer with workaround
    install_teamviewer_workaround
    
    # Generate helper scripts for manual tools
    generate_manual_helpers
    
    # Download BFG Repo Cleaner (special case)
    download_binary "https://repo1.maven.org/maven2/com/madgag/bfg/1.14.0/bfg-1.14.0.jar" "$TOOLS_DIR/bfg.jar"
    if [ $? -eq 0 ] && ! $DRY_RUN; then
        cat > "/usr/local/bin/bfg" << 'EOF'
#!/bin/bash
java -jar /opt/security-tools/bfg.jar "$@"
EOF
        chmod +x "/usr/local/bin/bfg"
        print_success "BFG Repo Cleaner installed and linked"
        log_result "SUCCESS" "bfg" "Installed and linked to /usr/local/bin"
    fi
    
    print_success "Full toolkit installation complete"
    log_result "SUCCESS" "full_toolkit" "Complete security toolkit installed"
}

# Function to print a summary of installed tools
print_summary() {
    print_step "Installation Summary"
    
    # Count success, partial, failed, manual
    SUCCESS_COUNT=$(grep -c "\[SUCCESS\]" $REPORT_FILE || echo 0)
    PARTIAL_COUNT=$(grep -c "\[PARTIAL\]" $REPORT_FILE || echo 0)
    FAILED_COUNT=$(grep -c "\[FAILED\]" $REPORT_FILE || echo 0)
    MANUAL_COUNT=$(grep -c "\[MANUAL\]" $REPORT_FILE || echo 0)
    SKIPPED_COUNT=$(grep -c "\[SKIPPED\]" $REPORT_FILE || echo 0)
    SIMULATED_COUNT=$(grep -c "\[SIMULATED\]" $REPORT_FILE || echo 0)
    
    # Calculate total time
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))
    
    echo "====================================================" >> $REPORT_FILE
    echo "INSTALLATION SUMMARY" >> $REPORT_FILE
    echo "====================================================" >> $REPORT_FILE
    echo "Successfully installed: $SUCCESS_COUNT" >> $REPORT_FILE
    echo "Partially installed: $PARTIAL_COUNT" >> $REPORT_FILE
    echo "Failed to install: $FAILED_COUNT" >> $REPORT_FILE
    echo "Manual installation required: $MANUAL_COUNT" >> $REPORT_FILE
    echo "Skipped (already installed): $SKIPPED_COUNT" >> $REPORT_FILE
    if [ $SIMULATED_COUNT -gt 0 ]; then
        echo "Simulated (dry run): $SIMULATED_COUNT"
    fi
    
    # Print manual tools that need attention
    if [ $MANUAL_COUNT -gt 0 ]; then
        echo ""
        print_status "Tools requiring manual installation:"
        echo "Tools requiring manual installation:" >> $REPORT_FILE
        echo "-----------------------------------" >> $REPORT_FILE
        
        grep "\[MANUAL\]" $REPORT_FILE | while read -r line; do
            tool=$(echo "$line" | awk -F':' '{print $1}' | awk -F' ' '{print $2}')
            reason=$(echo "$line" | awk -F':' '{print $2}')
            print_info "- $tool: Run $HELPERS_DIR/install_${tool}.sh"
            echo "- $tool: Run $HELPERS_DIR/install_${tool}.sh" >> $REPORT_FILE
        done
    fi
    
    # Print failed tools
    if [ $FAILED_COUNT -gt 0 ]; then
        echo ""
        print_status "Tools that failed to install:"
        echo "Tools that failed to install:" >> $REPORT_FILE
        echo "----------------------------" >> $REPORT_FILE
        
        grep "\[FAILED\]" $REPORT_FILE | while read -r line; do
            tool=$(echo "$line" | awk -F':' '{print $1}' | awk -F' ' '{print $2}')
            reason=$(echo "$line" | awk -F':' '{print $2}')
            print_info "- $tool: $reason"
            echo "- $tool: $reason" >> $REPORT_FILE
        done
    fi
    
    echo ""
    print_status "Installation complete! Total time: $MINUTES minutes and $SECONDS seconds"
    print_info "Installation report saved to: $REPORT_FILE"
    print_info "Detailed log file: $DETAILED_LOG"
    
    if ! $DRY_RUN; then
        print_info "To validate tools installation: sudo $SCRIPTS_DIR/validate-tools.sh"
        print_info "You may need to log out and back in for all changes to take effect"
    fi
}

# =================================================================
# MAIN EXECUTION
# =================================================================

# Initialize detailed log file
mkdir -p "$LOG_DIR"
echo "RTA Tools Installation Log - $(date)" > "$DETAILED_LOG"
echo "=============================================" >> "$DETAILED_LOG"
echo "System: $(uname -a)" >> "$DETAILED_LOG"
echo "User: $(whoami)" >> "$DETAILED_LOG"
echo "Command: $0 $*" >> "$DETAILED_LOG"
echo "=============================================" >> "$DETAILED_LOG"
echo "" >> "$DETAILED_LOG"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL_INSTALL=true
            shift
            ;;
        --core-only)
            CORE_ONLY=true
            shift
            ;;
        --desktop-only)
            DESKTOP_ONLY=true
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
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --ignore-errors)
            IGNORE_ERRORS=true
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

# Default to full install if no options provided
if ! $FULL_INSTALL && ! $CORE_ONLY && ! $DESKTOP_ONLY; then
    FULL_INSTALL=true
fi

# Main execution
main() {
    # Print banner
    print_banner "Kali Linux RTA Tools Installer"
    
    # Display current configuration
    echo -e "Installation mode:"
    if $FULL_INSTALL; then echo -e " - ${GREEN}Full installation${NC}"; fi
    if $CORE_ONLY; then echo -e " - ${GREEN}Core tools only${NC}"; fi
    if $DESKTOP_ONLY; then echo -e " - ${GREEN}Desktop shortcuts only${NC}"; fi
    if $HEADLESS; then echo -e " - ${YELLOW}Headless mode${NC}"; fi
    if $VERBOSE; then echo -e " - ${BLUE}Verbose output${NC}"; fi
    if $AUTO_MODE; then echo -e " - ${YELLOW}Automated mode (no prompts)${NC}"; fi
    if $IGNORE_ERRORS; then echo -e " - ${YELLOW}Ignoring errors${NC}"; fi
    if $FORCE_REINSTALL; then echo -e " - ${YELLOW}Force reinstall${NC}"; fi
    if $SKIP_UPDATES; then echo -e " - ${YELLOW}Skipping system updates${NC}"; fi
    if $DRY_RUN; then echo -e " - ${CYAN}Dry run (no changes)${NC}"; fi
    echo ""
    
    # Check if running as root
    check_root
    
    # Validate parameters
    if $DESKTOP_ONLY && $HEADLESS; then
        print_error "Cannot use --desktop-only with --headless"
        exit 1
    fi
    
    if $DRY_RUN && ! $VERBOSE; then
        # Force verbose mode for dry runs
        print_info "Enabling verbose mode for dry run"
        VERBOSE=true
    fi
    
    # Initialize report file
    echo "RTA Tools Installation Report" > $REPORT_FILE
    echo "=================================" >> $REPORT_FILE
    echo "Date: $(date)" >> $REPORT_FILE
    echo "System: $(uname -a)" >> $REPORT_FILE
    if $DRY_RUN; then
        echo "Mode: DRY RUN - No changes made to the system" >> $REPORT_FILE
    fi
    echo "" >> $REPORT_FILE
    echo "Installation Results:" >> $REPORT_FILE
    echo "-------------------" >> $REPORT_FILE
    
    # Create directory structure
    create_directories
    
    # Create config file if it doesn't exist
    create_config_file
    
    # Perform installation based on flags
    if $DESKTOP_ONLY; then
        install_desktop_integration
    elif $CORE_ONLY; then
        install_core_tools
        if ! $HEADLESS; then
            install_desktop_integration
        fi
    elif $FULL_INSTALL; then
        install_full_toolkit
        if ! $HEADLESS; then
            install_desktop_integration
        fi
    fi
    
    # Print summary
    print_summary
    
    # Return appropriate exit code
    if grep -q "\[FAILED\]" $REPORT_FILE && ! $IGNORE_ERRORS && ! $DRY_RUN; then
        print_warning "Some tools failed to install. Check the report for details."
        return 1
    else
        return 0
    fi
}

# Run main function
main
exit $?
 >> $REPORT_FILE
    fi
    echo "Total installation time: $MINUTES minutes and $SECONDS seconds" >> $REPORT_FILE
    
    print_info "Successfully installed: $SUCCESS_COUNT"
    print_info "Partially installed: $PARTIAL_COUNT"
    print_info "Failed to install: $FAILED_COUNT"
    print_info "Manual installation required: $MANUAL_COUNT"
    print_info "Skipped (already installed): $SKIPPED_COUNT"
    if [ $SIMULATED_COUNT -gt 0 ]; then
        print_info "Sim to find executables and create wrappers
            EXECUTABLE=$(find "$VENV_DIR/$repo_name/bin" -type f -not -name "python*" -not -name "pip*" -not -name "activate*" | head -1)
            if [ -n "$EXECUTABLE" ]; then
                ln -sf "$EXECUTABLE" "/usr/local/bin/$(basename $EXECUTABLE)"
                # Create symlink in our bin directory too
                mkdir -p "$BIN_DIR"
                ln -sf "$EXECUTABLE" "$BIN_DIR/$(basename $EXECUTABLE)"
                create_desktop_shortcut "$(basename $EXECUTABLE)" "/usr/local/bin/$(basename $EXECUTABLE)" "" "Security;Utility;"
                print_success "Installed $repo_name and linked executable $(basename $EXECUTABLE)"
                log_result "SUCCESS" "$repo_name" "Installed in virtual environment and linked executable"
            else
                # Create a generic wrapper script
                cat > "/usr/local/bin/${repo_name,,}" << EOF
#!/bin/bash
source "$VENV_DIR/$repo_name/bin/activate"
cd "$TOOLS_DIR/$repo_name"
python3 -m $repo_name "\$@"
deactivate
EOF
                chmod +x "/usr/local/bin/${repo_name,,}"
                # Create symlink in our bin directory too
                mkdir -p "$BIN_DIR"
                ln -sf "/usr/local/bin/${repo_name,,}" "$BIN_DIR/${repo_name,,}"
                create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
                
                print_success "Created executable wrapper for $repo_name."
                log_result "SUCCESS" "$repo_name" "Created executable wrapper and desktop shortcut"
            fi
            
            deactivate
            return 0
        fi
        
        # Check for Go-based projects
        if [ -f "go.mod" ] || grep -q "go build" "$README_FILE"; then
            print_debug "Found Go project, building..."
            
            if [ -f "go.mod" ]; then
                go build -o "${repo_name,,}" >> "$log_file" 2>&1
            else
                go build >> "$log_file" 2>&1
            fi
            
            # Find the built executable
            EXECUTABLE=$(find . -maxdepth 1 -type f -executable | grep -v "\.sh$" | head -1)
            if [ -n "$EXECUTABLE" ]; then
                cp "$EXECUTABLE" "/usr/local/bin/${repo_name,,}"
                chmod +x "/usr/local/bin/${repo_name,,}"
                # Create symlink in our bin directory too
                mkdir -p "$BIN_DIR"
                ln -sf "/usr/local/bin/${repo_name,,}" "$BIN_DIR/${repo_name,,}"
                create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
                
                print_success "Built and installed $repo_name."
                log_result "SUCCESS" "$repo_name" "Built Go executable and created desktop shortcut"
                return 0
            fi
        fi
    fi
    
    # Check specific installation methods
    if [ -f "setup.py" ]; then
        print_debug "Installing with Python setup.py in virtual environment..."
        setup_venv $repo_name
        pip install . >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to install $repo_name with setup.py."
            deactivate
            log_result "PARTIAL" "$repo_name" "Setup.py installation failed. See $log_file for details."
        else
            # Create symlink to bin directory if executable exists
            if [ -f "$VENV_DIR/$repo_name/bin/$repo_name" ]; then
                ln -sf "$VENV_DIR/$repo_name/bin/$repo_name" "/usr/local/bin/$repo_name"
                # Create symlink in our bin directory too
                mkdir -p "$BIN_DIR"
                ln -sf "$VENV_DIR/$repo_name/bin/$repo_name" "$BIN_DIR/$repo_name"
                create_desktop_shortcut "$repo_name" "/usr/local/bin/$repo_name" "" "Security;Utility;"
            fi
            deactivate
            print_success "$repo_name installed via setup.py."
            log_result "SUCCESS" "$repo_name" "Installed via setup.py in virtual environment"
            return 0
        fi
    elif [ -f "requirements.txt" ]; then
        print_debug "Installing Python requirements in virtual environment..."
        setup_venv $repo_name
        pip install -r requirements.txt >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to install requirements for $repo_name."
            deactivate
            log_result "PARTIAL" "$repo_name" "Requirements installation failed. See $log_file for details."
        else
            deactivate
            print_success "$repo_name requirements installed."
            log_result "SUCCESS" "$repo_name" "Requirements installed in virtual environment"
            return 0
        fi
    elif [ -f "Makefile" ] || [ -f "makefile" ]; then
        print_debug "Building with make..."
        run_with_timeout "make" $BUILD_TIMEOUT $log_file $repo_name
        if [ $? -ne 0 ]; then
            print_error "Failed to build $repo_name with make."
            log_result "PARTIAL" "$repo_name" "Make build failed. See $log_file for details."
        else
            print_success "$repo_name built with make."
            # Try to find and link the executable
            find . -type f -executable -not -path "*/\.*" | while read -r executable; do
                if [[ "$executable" == *"$repo_name"* ]] || [[ "$executable" == *"/bin/"* ]]; then
                    chmod +x "$executable"
                    ln -sf "$executable" "/usr/local/bin/$(basename $executable)"
                    # Create symlink in our bin directory too
                    mkdir -p "$BIN_DIR"
                    ln -sf "$executable" "$BIN_DIR/$(basename $executable)"
                    create_desktop_shortcut "$(basename $executable)" "/usr/local/bin/$(basename $executable)" "" "Security;Utility;"
                    print_info "Linked executable: $(basename $executable)"
                fi
            done
            log_result "SUCCESS" "$repo_name" "Built with make"
            return 0
        fi
    elif [ -f "install.sh" ]; then
        print_debug "Running install.sh script..."
        chmod +x install.sh
        run_with_timeout "./install.sh" $BUILD_TIMEOUT $log_file $repo_name
        if [ $? -ne 0 ]; then
            print_error "Failed to run install.sh script."
            log_result "PARTIAL" "$repo_name" "Install script failed. See $log_file for details."
        else
            print_success "$repo_name installed with install.sh script."
            log_result "SUCCESS" "$repo_name" "Installed with install.sh script"
            
            # Try
