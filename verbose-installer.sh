#!/bin/bash
# =====================================================================
# Verbose Kali Linux RTA Tools Installer
# =====================================================================
# This script provides a simplified, highly verbose installer that clearly
# shows which tools were successfully installed and which failed
# =====================================================================

# Exit on error with error handling
set -e
trap cleanup EXIT

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Main directories
INSTALL_DIR="/opt/security-tools"
LOG_DIR="$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/logs"

# Set timestamp format
TIMESTAMP_FORMAT="%H:%M:%S"

# Installation tracking
declare -A INSTALL_STATUS
declare -A INSTALL_NOTES

# =====================================================================
# UTILITY FUNCTIONS
# =====================================================================

# Function to display usage
show_usage() {
    echo -e "\n${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo -e "  OPTIONS:"
    echo -e "    --apt-tools TOOLS    Comma-separated list of apt tools to install"
    echo -e "    --pipx-tools TOOLS   Comma-separated list of pipx tools to install"
    echo -e "    --github-tools URLS  Comma-separated list of GitHub repository URLs"
    echo -e "    --help               Show this help message"
    echo -e "\n  EXAMPLE:"
    echo -e "    $0 --apt-tools nmap,wireshark,sqlmap --pipx-tools impacket"
    exit 1
}

# Function to display timestamp
timestamp() {
    date +"[%Y-%m-%d ${TIMESTAMP_FORMAT}]"
}

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"[%Y-%m-%d ${TIMESTAMP_FORMAT}]")
    
    # Log to file
    echo "$timestamp [$level] $message" >> "$LOG_DIR/install.log"
    
    # Log to console with colors
    case "$level" in
        "INFO")    echo -e "${BLUE}$timestamp [INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}$timestamp [SUCCESS]${NC} $message" ;;
        "ERROR")   echo -e "${RED}$timestamp [ERROR]${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}$timestamp [WARNING]${NC} $message" ;;
        *)         echo -e "$timestamp [$level] $message" ;;
    esac
}

# Function to display a header
display_header() {
    local text="$1"
    local width=70
    local padding=$(( (width - ${#text}) / 2 ))
    
    echo -e "\n${YELLOW}$("="%{$width}s)${NC}"
    printf "${YELLOW}%${padding}s%s%${padding}s${NC}\n" "" "$text" ""
    echo -e "${YELLOW}$("="%{$width}s)${NC}\n"
}

# Function to cleanup on exit
cleanup() {
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Script terminated with errors. Check logs for details."
    fi
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_message "ERROR" "This script must be run as root (sudo)."
    exit 1
fi

# =====================================================================
# INSTALLATION FUNCTIONS
# =====================================================================

# Function to install an apt package with detailed output
install_apt_package() {
    local package="$1"
    local log_file="$LOG_DIR/${package}_apt.log"
    
    log_message "INFO" "Installing $package with apt-get..."
    
    # Check if already installed
    if dpkg -l | grep -q "^ii  $package "; then
        log_message "INFO" "$package is already installed."
        INSTALL_STATUS["$package"]="SKIPPED"
        INSTALL_NOTES["$package"]="Already installed"
        return 0
    fi
    
    # Clear the log file
    > "$log_file"
    
    # Try to install the package
    if apt-get install -y "$package" >> "$log_file" 2>&1; then
        # Verify the installation
        if dpkg -l | grep -q "^ii  $package "; then
            log_message "SUCCESS" "$package successfully installed."
            INSTALL_STATUS["$package"]="SUCCESS"
            INSTALL_NOTES["$package"]="Installed via apt-get"
        else
            log_message "ERROR" "$package installation failed - package not found after install."
            INSTALL_STATUS["$package"]="FAILED"
            INSTALL_NOTES["$package"]="Installation appeared to succeed, but package not found"
        fi
    else
        log_message "ERROR" "$package installation failed. Check $log_file for details."
        
        # Extract the error message from the log file
        local error_msg=$(grep -i "error\|failed\|not found" "$log_file" | head -3)
        
        if [ -n "$error_msg" ]; then
            log_message "ERROR" "Error details: ${error_msg}"
        fi
        
        INSTALL_STATUS["$package"]="FAILED"
        INSTALL_NOTES["$package"]="Installation failed - see $log_file for details"
    fi
}

# Function to install a pipx package with detailed output
install_pipx_package() {
    local package="$1"
    local log_file="$LOG_DIR/${package}_pipx.log"
    
    log_message "INFO" "Installing $package with pipx..."
    
    # Ensure pipx is installed
    if ! command -v pipx &> /dev/null; then
        log_message "INFO" "pipx not found, installing..."
        apt-get install -y python3-pip python3-venv
        python3 -m pip install --user pipx
        python3 -m pipx ensurepath
    fi
    
    # Clear the log file
    > "$log_file"
    
    # Try to install the package
    if pipx install "$package" >> "$log_file" 2>&1; then
        log_message "SUCCESS" "$package successfully installed with pipx."
        INSTALL_STATUS["$package"]="SUCCESS"
        INSTALL_NOTES["$package"]="Installed via pipx"
    else
        log_message "ERROR" "$package installation with pipx failed. Check $log_file for details."
        
        # Extract the error message from the log file
        local error_msg=$(grep -i "error\|failed\|not found" "$log_file" | head -3)
        
        if [ -n "$error_msg" ]; then
            log_message "ERROR" "Error details: ${error_msg}"
        fi
        
        INSTALL_STATUS["$package"]="FAILED"
        INSTALL_NOTES["$package"]="Installation failed - see $log_file for details"
    fi
}

# Function to clone a GitHub repository with detailed output
clone_github_repo() {
    local repo_url="$1"
    local repo_name=$(basename "$repo_url" .git)
    local repo_dir="$INSTALL_DIR/$repo_name"
    local log_file="$LOG_DIR/${repo_name}_github.log"
    
    log_message "INFO" "Cloning $repo_name from $repo_url..."
    
    # Clear the log file
    > "$log_file"
    
    # Clone the repository
    if [ -d "$repo_dir" ]; then
        log_message "INFO" "$repo_name directory already exists, updating..."
        if cd "$repo_dir" && git pull >> "$log_file" 2>&1; then
            log_message "SUCCESS" "$repo_name updated successfully."
            INSTALL_STATUS["$repo_name"]="SUCCESS"
            INSTALL_NOTES["$repo_name"]="Repository updated"
        else
            log_message "ERROR" "Failed to update $repo_name. Check $log_file for details."
            INSTALL_STATUS["$repo_name"]="FAILED"
            INSTALL_NOTES["$repo_name"]="Failed to update repository"
        fi
    else
        if git clone "$repo_url" "$repo_dir" >> "$log_file" 2>&1; then
            log_message "SUCCESS" "$repo_name cloned successfully."
            INSTALL_STATUS["$repo_name"]="SUCCESS"
            INSTALL_NOTES["$repo_name"]="Repository cloned"
            
            # Try to install if there are common installation methods
            cd "$repo_dir"
            
            if [ -f "setup.py" ]; then
                log_message "INFO" "Found setup.py in $repo_name, attempting to install..."
                if python3 -m pip install -e . >> "$log_file" 2>&1; then
                    log_message "SUCCESS" "$repo_name installed via setup.py."
                    INSTALL_NOTES["$repo_name"]="${INSTALL_NOTES["$repo_name"]} and installed via setup.py"
                else
                    log_message "WARNING" "Failed to install $repo_name via setup.py. Check $log_file for details."
                    INSTALL_NOTES["$repo_name"]="${INSTALL_NOTES["$repo_name"]} but setup.py installation failed"
                fi
            elif [ -f "requirements.txt" ]; then
                log_message "INFO" "Found requirements.txt in $repo_name, installing dependencies..."
                if python3 -m pip install -r requirements.txt >> "$log_file" 2>&1; then
                    log_message "SUCCESS" "$repo_name dependencies installed."
                    INSTALL_NOTES["$repo_name"]="${INSTALL_NOTES["$repo_name"]} and dependencies installed"
                else
                    log_message "WARNING" "Failed to install dependencies for $repo_name. Check $log_file for details."
                    INSTALL_NOTES["$repo_name"]="${INSTALL_NOTES["$repo_name"]} but dependency installation failed"
                fi
            fi
        else
            log_message "ERROR" "Failed to clone $repo_name from $repo_url. Check $log_file for details."
            INSTALL_STATUS["$repo_name"]="FAILED"
            INSTALL_NOTES["$repo_name"]="Failed to clone repository"
        fi
    fi
}

# =====================================================================
# INSTALLATION FUNCTIONS
# =====================================================================

# Function to install apt tools
install_apt_tools() {
    local tools="$1"
    
    if [ -z "$tools" ]; then
        log_message "WARNING" "No apt tools specified, skipping apt installation."
        return 0
    fi
    
    display_header "APT PACKAGE INSTALLATION"
    log_message "INFO" "Installing apt packages: $tools"
    
    # Update package lists
    log_message "INFO" "Updating package lists..."
    apt-get update >> "$LOG_DIR/apt_update.log" 2>&1
    log_message "SUCCESS" "Package lists updated."
    
    # Install each tool
    IFS=',' read -ra TOOLS_ARRAY <<< "$tools"
    for tool in "${TOOLS_ARRAY[@]}"; do
        install_apt_package "$tool"
    done
    
    # Display results
    local success_count=0
    local failed_count=0
    local skipped_count=0
    
    for tool in "${TOOLS_ARRAY[@]}"; do
        case "${INSTALL_STATUS[$tool]}" in
            "SUCCESS") ((success_count++)) ;;
            "FAILED")  ((failed_count++)) ;;
            "SKIPPED") ((skipped_count++)) ;;
        esac
    done
    
    log_message "INFO" "APT installation complete: $success_count succeeded, $failed_count failed, $skipped_count skipped."
}

# Function to install pipx tools
install_pipx_tools() {
    local tools="$1"
    
    if [ -z "$tools" ]; then
        log_message "WARNING" "No pipx tools specified, skipping pipx installation."
        return 0
    fi
    
    display_header "PIPX PACKAGE INSTALLATION"
    log_message "INFO" "Installing pipx packages: $tools"
    
    # Install each tool
    IFS=',' read -ra TOOLS_ARRAY <<< "$tools"
    for tool in "${TOOLS_ARRAY[@]}"; do
        install_pipx_package "$tool"
    done
    
    # Display results
    local success_count=0
    local failed_count=0
    
    for tool in "${TOOLS_ARRAY[@]}"; do
        case "${INSTALL_STATUS[$tool]}" in
            "SUCCESS") ((success_count++)) ;;
            "FAILED")  ((failed_count++)) ;;
        esac
    done
    
    log_message "INFO" "PIPX installation complete: $success_count succeeded, $failed_count failed."
}

# Function to install GitHub tools
install_github_tools() {
    local repos="$1"
    
    if [ -z "$repos" ]; then
        log_message "WARNING" "No GitHub repositories specified, skipping GitHub installation."
        return 0
    fi
    
    display_header "GITHUB REPOSITORY INSTALLATION"
    log_message "INFO" "Installing GitHub repositories: $repos"
    
    # Install git if not already installed
    if ! command -v git &> /dev/null; then
        log_message "INFO" "Git not found, installing..."
        apt-get install -y git >> "$LOG_DIR/git_install.log" 2>&1
    fi
    
    # Clone and process each repository
    IFS=',' read -ra REPOS_ARRAY <<< "$repos"
    for repo in "${REPOS_ARRAY[@]}"; do
        clone_github_repo "$repo"
    done
    
    # Display results
    local success_count=0
    local failed_count=0
    
    for repo in "${REPOS_ARRAY[@]}"; do
        repo_name=$(basename "$repo" .git)
        case "${INSTALL_STATUS[$repo_name]}" in
            "SUCCESS") ((success_count++)) ;;
            "FAILED")  ((failed_count++)) ;;
        esac
    done
    
    log_message "INFO" "GitHub installation complete: $success_count succeeded, $failed_count failed."
}

# =====================================================================
# REPORTING FUNCTIONS
# =====================================================================

# Function to generate installation summary
generate_summary() {
    local report_file="$LOG_DIR/installation_summary_$(date +%Y%m%d_%H%M%S).txt"
    
    display_header "INSTALLATION SUMMARY"
    
    # Count tools by status
    local success_count=0
    local failed_count=0
    local skipped_count=0
    
    for tool in "${!INSTALL_STATUS[@]}"; do
        case "${INSTALL_STATUS[$tool]}" in
            "SUCCESS") ((success_count++)) ;;
            "FAILED")  ((failed_count++)) ;;
            "SKIPPED") ((skipped_count++)) ;;
        esac
    done
    
    # Display summary
    log_message "INFO" "Installation completed with:"
    log_message "SUCCESS" "$success_count tools successfully installed/updated"
    log_message "ERROR" "$failed_count tools failed to install/update"
    log_message "INFO" "$skipped_count tools skipped (already installed)"
    
    # Write detailed report
    {
        echo "==================================================="
        echo "   INSTALLATION SUMMARY REPORT"
        echo "==================================================="
        echo "Date: $(date)"
        echo "System: $(uname -a)"
        echo ""
        
        echo "SUMMARY:"
        echo "  Successfully installed/updated: $success_count"
        echo "  Failed to install/update: $failed_count"
        echo "  Skipped (already installed): $skipped_count"
        echo "  Total tools processed: $((success_count + failed_count + skipped_count))"
        echo ""
        
        echo "SUCCESSFUL INSTALLATIONS:"
        echo "------------------------"
        for tool in "${!INSTALL_STATUS[@]}"; do
            if [ "${INSTALL_STATUS[$tool]}" == "SUCCESS" ]; then
                echo "  ✓ $tool: ${INSTALL_NOTES[$tool]}"
            fi
        done
        echo ""
        
        if [ $failed_count -gt 0 ]; then
            echo "FAILED INSTALLATIONS:"
            echo "--------------------"
            for tool in "${!INSTALL_STATUS[@]}"; do
                if [ "${INSTALL_STATUS[$tool]}" == "FAILED" ]; then
                    echo "  ✗ $tool: ${INSTALL_NOTES[$tool]}"
                fi
            done
            echo ""
        fi
        
        if [ $skipped_count -gt 0 ]; then
            echo "SKIPPED INSTALLATIONS:"
            echo "---------------------"
            for tool in "${!INSTALL_STATUS[@]}"; do
                if [ "${INSTALL_STATUS[$tool]}" == "SKIPPED" ]; then
                    echo "  • $tool: ${INSTALL_NOTES[$tool]}"
                fi
            done
            echo ""
        fi
        
        echo "INSTALLED TOOL LOCATIONS:"
        echo "------------------------"
        echo "  APT packages: Standard system locations"
        echo "  PIPX packages: ~/.local/bin/ and linked to /usr/local/bin/"
        echo "  GitHub repositories: $INSTALL_DIR/<repository-name>"
        echo ""
        
        echo "LOG LOCATIONS:"
        echo "-------------"
        echo "  Installation logs: $LOG_DIR/"
        echo "  Main log: $LOG_DIR/install.log"
        echo ""
        
        echo "==================================================="
        echo "END OF REPORT"
        echo "==================================================="
    } > "$report_file"
    
    log_message "SUCCESS" "Installation summary report generated: $report_file"
    
    # If there were failures, print them prominently
    if [ $failed_count -gt 0 ]; then
        echo ""
        log_message "ERROR" "The following tools failed to install:"
        for tool in "${!INSTALL_STATUS[@]}"; do
            if [ "${INSTALL_STATUS[$tool]}" == "FAILED" ]; then
                log_message "ERROR" "  • $tool: ${INSTALL_NOTES[$tool]}"
            fi
        done
        echo ""
    fi
}

# =====================================================================
# MAIN SCRIPT
# =====================================================================

# Initialize variables
APT_TOOLS=""
PIPX_TOOLS=""
GITHUB_TOOLS=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apt-tools)
            APT_TOOLS="$2"
            shift 2
            ;;
        --pipx-tools)
            PIPX_TOOLS="$2"
            shift 2
            ;;
        --github-tools)
            GITHUB_TOOLS="$2"
            shift 2
            ;;
        --help)
            show_usage
            ;;
        *)
            log_message "ERROR" "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Display welcome banner
clear
cat << EOF
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║          VERBOSE KALI LINUX RTA TOOLS INSTALLER                       ║
║                                                                       ║
║  This script will install security tools with detailed status         ║
║  reporting to clearly show which tools succeeded and which failed.    ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝

EOF

# Log start of installation
log_message "INFO" "Starting installation with verbose logging"

# Check if no tools were specified, use defaults
if [ -z "$APT_TOOLS" ] && [ -z "$PIPX_TOOLS" ] && [ -z "$GITHUB_TOOLS" ]; then
    log_message "INFO" "No tools specified, using defaults"
    
    # Default tools
    APT_TOOLS="nmap,wireshark,sqlmap,hydra,bettercap,proxychains4,responder,metasploit-framework"
    PIPX_TOOLS="impacket,scoutsuite,pymeta"
    GITHUB_TOOLS="https://github.com/prowler-cloud/prowler.git,https://github.com/ImpostorKeanu/parsuite.git"
    
    log_message "INFO" "Default APT tools: $APT_TOOLS"
    log_message "INFO" "Default PIPX tools: $PIPX_TOOLS"
    log_message "INFO" "Default GitHub tools: $GITHUB_TOOLS"
fi

# Install tools
install_apt_tools "$APT_TOOLS"
install_pipx_tools "$PIPX_TOOLS"
install_github_tools "$GITHUB_TOOLS"

# Generate summary
generate_summary

log_message "SUCCESS" "Installation process completed!"
echo -e "\nYou can view the detailed installation log at: ${GREEN}$LOG_DIR/install.log${NC}"
echo -e "A summary report has been generated in the ${GREEN}$LOG_DIR${NC} directory.\n"
