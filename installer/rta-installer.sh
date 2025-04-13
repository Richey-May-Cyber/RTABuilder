#!/bin/bash
# =================================================================
# Robust Kali Linux Security Tools Installer v2.0
# =================================================================
# This script installs security tools with comprehensive error handling
# and resource management to prevent system crashes
# =================================================================

# Exit on error with controlled error handling
set +e
trap cleanup EXIT INT TERM

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Directories
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$TOOLS_DIR/logs"
DETAILED_LOG="$LOG_DIR/install_$(date +%Y%m%d_%H%M%S).log"

# Create directories if they don't exist
mkdir -p "$TOOLS_DIR/bin" "$LOG_DIR" "$TOOLS_DIR/scripts" "$TOOLS_DIR/helpers"

# Configuration
MAX_LOAD=4.0                  # Maximum system load average
MAX_MEMORY_PERCENT=80         # Maximum memory usage percentage
TIMEOUT_SECONDS=300           # Timeout for commands (5 minutes)
MAX_RETRY=3                   # Maximum retry attempts
PARALLEL_JOBS=$(nproc)        # Number of parallel jobs
if [ $PARALLEL_JOBS -gt 4 ]; then
  PARALLEL_JOBS=4             # Limit to 4 parallel jobs max
fi

# Parse command-line arguments
FORCE_REINSTALL=false
CORE_ONLY=false
DESKTOP_ONLY=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-reinstall)
            FORCE_REINSTALL=true
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
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Usage: $0 [--force-reinstall] [--core-only] [--desktop-only] [--verbose]"
            exit 1
            ;;
    esac
done

# Logging
echo "RTA Tools Installation - $(date)" > "$DETAILED_LOG"
echo "=======================================" >> "$DETAILED_LOG"

# Function for controlled cleanup
cleanup() {
  local exit_code=$?
  
  echo -e "\n${YELLOW}[*] Performing cleanup...${NC}"
  echo "[CLEANUP] $(date): Performing cleanup with exit code $exit_code" >> "$DETAILED_LOG"
  
  # Kill any background processes
  jobs -p | xargs -r kill &>/dev/null
  
  # Final message
  if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}[+] Installation completed successfully.${NC}"
  elif [ $exit_code -eq 130 ]; then
    echo -e "${YELLOW}[!] Installation interrupted by user.${NC}"
  else
    echo -e "${RED}[-] Installation encountered errors (code $exit_code).${NC}"
    echo -e "${YELLOW}[!] Check logs at $DETAILED_LOG for details.${NC}"
  fi
}

# Function to log messages
log() {
  local level="$1"
  local message="$2"
  echo "[$(date '+%H:%M:%S')] [$level] $message" >> "$DETAILED_LOG"
  
  case "$level" in
    "INFO")   
      if $VERBOSE; then
        echo -e "${BLUE}[i] $message${NC}"
      fi
      ;;
    "SUCCESS") echo -e "${GREEN}[+] $message${NC}" ;;
    "ERROR")  echo -e "${RED}[-] $message${NC}" ;;
    "WARNING") echo -e "${YELLOW}[!] $message${NC}" ;;
    *)        echo -e "${YELLOW}[*] $message${NC}" ;;
  esac
}

# Function to check system resources
check_resources() {
  # Check CPU load
  local load=$(cat /proc/loadavg | awk '{print $1}')
  if (( $(echo "$load > $MAX_LOAD" | bc -l) )); then
    log "WARNING" "System load too high ($load). Waiting for 30 seconds..."
    sleep 30
    return 1
  fi
  
  # Check memory usage
  local mem_used_percent=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
  if (( $(echo "$mem_used_percent > $MAX_MEMORY_PERCENT" | bc -l) )); then
    log "WARNING" "Memory usage too high ($mem_used_percent%). Waiting for 30 seconds..."
    sleep 30
    return 1
  fi
  
  return 0
}

# Function to run command with timeout and retry
run_safely() {
  local cmd="$1"
  local name="$2"
  local logfile="$LOG_DIR/${name// /_}_$(date +%Y%m%d_%H%M%S).log"
  local attempts=0
  
  # Log the command
  log "INFO" "Running: $cmd"
  echo "COMMAND: $cmd" > "$logfile"
  
  # Try up to MAX_RETRY times
  while [ $attempts -lt $MAX_RETRY ]; do
    attempts=$((attempts + 1))
    
    # Check if resources are available
    until check_resources; do
      log "INFO" "Waiting for system resources to be available..."
    done
    
    # Run with timeout
    timeout $TIMEOUT_SECONDS bash -c "$cmd" >> "$logfile" 2>&1
    local result=$?
    
    if [ $result -eq 0 ]; then
      log "SUCCESS" "$name completed successfully (attempt $attempts)"
      return 0
    elif [ $result -eq 124 ]; then
      log "WARNING" "$name timed out after $TIMEOUT_SECONDS seconds (attempt $attempts)"
    else
      log "WARNING" "$name failed with code $result (attempt $attempts)"
    fi
    
    # If we've tried enough times, give up
    if [ $attempts -ge $MAX_RETRY ]; then
      log "ERROR" "$name failed after $MAX_RETRY attempts. See $logfile"
      return 1
    fi
    
    # Wait before retrying (increasing backoff)
    sleep $((attempts * 5))
  done
}

# Function to install apt package safely
install_apt_package() {
  local package="$1"
  
  # Check if already installed
  if dpkg -l | grep -q "^ii  $package " && ! $FORCE_REINSTALL; then
    log "INFO" "$package is already installed"
    return 0
  fi
  
  log "STATUS" "Installing $package with apt..."
  
  # Update package lists if needed
  if [ ! -f "/tmp/apt_updated" ] || [ $(( $(date +%s) - $(stat -c %Y /tmp/apt_updated) )) -gt 3600 ]; then
    run_safely "apt-get update" "apt-update"
    touch "/tmp/apt_updated"
  fi
  
  # Install with controlled resources
  run_safely "DEBIAN_FRONTEND=noninteractive apt-get install -y $package" "apt-install-$package"
  
  # Verify installation
  if dpkg -l | grep -q "^ii  $package "; then
    log "SUCCESS" "$package installed successfully"
    return 0
  else
    log "ERROR" "Failed to install $package"
    return 1
  fi
}

# Function to install multiple apt packages
install_apt_packages() {
  local package_list="$1"
  local success_count=0
  local fail_count=0
  
  # Split package list
  IFS=',' read -ra PACKAGES <<< "$package_list"
  local total=${#PACKAGES[@]}
  
  log "STATUS" "Installing $total apt packages..."
  
  # Check if we can use parallel
  if command -v parallel &>/dev/null && [ $total -gt 10 ]; then
    log "INFO" "Using parallel processing for apt package installation"
    
    # Update first
    apt-get update
    
    # Create a temp file to track package installation status
    local temp_file=$(mktemp)
    
    # Define a function to install packages and log results
    install_package() {
      local pkg="$1"
      local temp_file="$2"
      if dpkg -l | grep -q "^ii  $pkg " && ! $FORCE_REINSTALL; then
        echo "SUCCESS:$pkg:already_installed" >> "$temp_file"
        return 0
      fi
      
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
        echo "SUCCESS:$pkg:newly_installed" >> "$temp_file"
        return 0
      else
        echo "FAIL:$pkg" >> "$temp_file"
        return 1
      fi
    }
    
    export -f install_package
    
    # Run parallel installation
    printf "%s\n" "${PACKAGES[@]}" | \
      parallel -j $PARALLEL_JOBS "install_package {} $temp_file"
    
    # Process results
    while read line; do
      if [[ "$line" == SUCCESS:* ]]; then
        ((success_count++))
        pkg=${line#SUCCESS:}
        pkg=${pkg%%:*}
        status=${line##*:}
        if [ "$status" == "already_installed" ]; then
          log "INFO" "$pkg is already installed"
        else
          log "SUCCESS" "$pkg installed successfully"
        fi
      elif [[ "$line" == FAIL:* ]]; then
        ((fail_count++))
        pkg=${line#FAIL:}
        log "ERROR" "Failed to install $pkg"
      fi
    done < "$temp_file"
    
    rm -f "$temp_file"
  else
    # Sequential installation
    for package in "${PACKAGES[@]}"; do
      if install_apt_package "$package"; then
        success_count=$((success_count + 1))
      else
        fail_count=$((fail_count + 1))
      fi
      
      # Report progress
      log "INFO" "Progress: $success_count successful, $fail_count failed out of $total"
    done
  fi
  
  log "STATUS" "Apt package installation completed: $success_count successful, $fail_count failed"
  
  # Fix any broken dependencies
  if [ $fail_count -gt 0 ]; then
    log "STATUS" "Attempting to fix broken dependencies..."
    apt-get -f install -y
  fi
}

# Function to install pipx package safely
install_pipx_package() {
  local package="$1"
  
  # Ensure pipx is installed
  if ! command -v pipx &>/dev/null; then
    log "INFO" "Installing pipx..."
    install_apt_package "python3-pip"
    install_apt_package "python3-venv"
    run_safely "pip3 install pipx" "install-pipx"
    run_safely "pipx ensurepath" "pipx-ensurepath"
    export PATH="$PATH:$HOME/.local/bin"
  fi
  
  # Check if already installed
  if pipx list 2>/dev/null | grep -q "$package" && ! $FORCE_REINSTALL; then
    log "INFO" "$package is already installed via pipx"
    return 0
  fi
  
  log "STATUS" "Installing $package with pipx..."
  if $FORCE_REINSTALL && pipx list 2>/dev/null | grep -q "$package"; then
    run_safely "pipx uninstall $package" "pipx-uninstall-$package"
  fi
  
  run_safely "pipx install $package" "pipx-install-$package"
  
  # Verify installation
  if pipx list 2>/dev/null | grep -q "$package" || command -v "$package" &>/dev/null || [ -f "$HOME/.local/bin/$package" ]; then
    log "SUCCESS" "$package installed successfully with pipx"
    return 0
  else
    log "ERROR" "Failed to install $package with pipx"
    return 1
  fi
}

# Function to install GitHub repo safely
install_github_repo() {
  local repo_url="$1"
  local repo_name=$(basename "$repo_url" .git)
  local target_dir="$TOOLS_DIR/$repo_name"
  
  log "STATUS" "Installing $repo_name from GitHub..."
  
  # Check if git is installed
  if ! command -v git &>/dev/null; then
    install_apt_package "git"
  fi
  
  # Check if already cloned
  if [ -d "$target_dir/.git" ] && ! $FORCE_REINSTALL; then
    log "INFO" "$repo_name already exists, updating..."
    
    if run_safely "cd $target_dir && git pull" "git-pull-$repo_name"; then
      log "SUCCESS" "$repo_name updated successfully"
      # Process repo as needed
      process_repo "$target_dir" "$repo_name"
      return 0
    else
      log "WARNING" "Failed to update $repo_name, will attempt to clone fresh"
      rm -rf "$target_dir"
    fi
  fi
  
  # Clone repository
  if run_safely "git clone --depth 1 $repo_url $target_dir" "git-clone-$repo_name"; then
    log "SUCCESS" "$repo_name cloned successfully"
    
    # Process repo based on content
    process_repo "$target_dir" "$repo_name"
    return 0
  else
    log "ERROR" "Failed to clone $repo_name"
    return 1
  fi
}

# Process repository based on content
process_repo() {
  local repo_dir="$1"
  local repo_name="$2"
  
  # Check if it's a Python package
  if [ -f "$repo_dir/setup.py" ]; then
    log "INFO" "Python package detected for $repo_name, installing with pip..."
    run_safely "cd $repo_dir && pip3 install -e ." "pip-install-$repo_name"
  elif [ -f "$repo_dir/requirements.txt" ]; then
    log "INFO" "Python requirements detected for $repo_name, installing..."
    run_safely "cd $repo_dir && pip3 install -r requirements.txt" "pip-requirements-$repo_name"
  fi

  # Look for main executable scripts
  local main_script=""
  for script in "$repo_name.py" "main.py" "$repo_name.sh" "main.sh" "$repo_name" "main"; do
    if [ -f "$repo_dir/$script" ]; then
      main_script="$script"
      break
    fi
  done
  
  # If script found, make executable and create link
  if [ -n "$main_script" ]; then
    log "INFO" "Creating executable wrapper for $repo_name..."
    chmod +x "$repo_dir/$main_script"
    ln -sf "$repo_dir/$main_script" "$TOOLS_DIR/bin/$repo_name"
    
    # Create /usr/local/bin symlink if it doesn't exist
    if [ ! -f "/usr/local/bin/$repo_name" ]; then
      ln -sf "$repo_dir/$main_script" "/usr/local/bin/$repo_name"
    fi
  fi
}

# Function to create a basic helper script for manual tools
create_helper_script() {
  local tool_name="$1"
  local helper_file="$TOOLS_DIR/helpers/install_${tool_name}.sh"
  
  # Skip if script already exists
  if [ -f "$helper_file" ] && ! $FORCE_REINSTALL; then
    log "INFO" "Helper script for $tool_name already exists"
    return 0
  fi
  
  log "INFO" "Creating helper script for $tool_name..."
  
  mkdir -p "$TOOLS_DIR/helpers"
  
  cat > "$helper_file" << EOF
#!/bin/bash
# Helper script to install $tool_name
# Run with: sudo bash $helper_file

echo "==================================================="
echo "  Manual installation helper for $tool_name"
echo "==================================================="
echo ""
echo "This tool requires manual installation steps."
echo "Please download $tool_name from the official website"
echo "and follow their installation instructions."
echo ""
echo "After installation, you may need to create desktop shortcuts"
echo "or add the tool to your PATH."
echo ""
echo "==================================================="
EOF
  
  chmod +x "$helper_file"
  log "SUCCESS" "Created helper script for $tool_name at $helper_file"
  return 0
}

# Function to read configuration from file
read_config() {
  local config_file="$1"
  local section="$2"
  local default_value="$3"
  
  if [ ! -f "$config_file" ]; then
    log "ERROR" "Configuration file not found: $config_file"
    return 1
  fi
  
  # Extract value from configuration file
  local value=$(grep -E "^$section:" "$config_file" | cut -d'"' -f2)
  
  if [ -z "$value" ]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

# Main installation function
main() {
  log "STATUS" "Starting RTA tools installation..."
  
  # Configuration file
  local config_file="/opt/rta-deployment/config/config.yml"
  
  # Read configuration
  local apt_tools=$(read_config "$config_file" "apt_tools" "nmap,wireshark,sqlmap,hydra,bettercap,terminator")
  local pipx_tools=$(read_config "$config_file" "pipx_tools" "scoutsuite,impacket")
  local git_tools=$(read_config "$config_file" "git_tools" "https://github.com/prowler-cloud/prowler.git")
  local manual_tools=$(read_config "$config_file" "manual_tools" "nessus,burpsuite_enterprise")
  
  # Handle different installation modes
  if $DESKTOP_ONLY; then
    log "STATUS" "Running in desktop-only mode..."
    # Configure desktop environment only
    configure_desktop
  elif $CORE_ONLY; then
    log "STATUS" "Running in core-tools-only mode..."
    # Install only essential tools
    apt_tools="nmap,wireshark,sqlmap,hydra,bettercap,metasploit-framework,terminator"
    install_apt_packages "$apt_tools"
    install_pipx_package "impacket"
  else
    # Install apt packages
    if [ -n "$apt_tools" ]; then
      log "STATUS" "Installing apt packages: $apt_tools"
      install_apt_packages "$apt_tools"
    fi
    
    # Install pipx packages
    if [ -n "$pipx_tools" ]; then
      log "STATUS" "Installing pipx packages: $pipx_tools"
      IFS=',' read -ra PACKAGES <<< "$pipx_tools"
      for package in "${PACKAGES[@]}"; do
        install_pipx_package "$package"
      done
    fi
    
    # Install GitHub repositories
    if [ -n "$git_tools" ]; then
      log "STATUS" "Installing GitHub repositories: $git_tools"
      IFS=',' read -ra REPOS <<< "$git_tools"
      for repo in "${REPOS[@]}"; do
        install_github_repo "$repo"
      done
    fi
    
    # Create helper scripts for manual tools
    if [ -n "$manual_tools" ]; then
      log "STATUS" "Creating helper scripts for manual tools: $manual_tools"
      IFS=',' read -ra TOOLS <<< "$manual_tools"
      for tool in "${TOOLS[@]}"; do
        create_helper_script "$tool"
      done
    fi
  fi
  
  # Create validation script
  log "INFO" "Creating validation script..."
  if [ ! -f "$TOOLS_DIR/scripts/validate-tools.sh" ] || $FORCE_REINSTALL; then
    cp "/opt/rta-deployment/scripts/validate-tools.sh" "$TOOLS_DIR/scripts/" 2>/dev/null || {
      log "WARNING" "Could not copy validation script"
    }
    chmod +x "$TOOLS_DIR/scripts/validate-tools.sh" 2>/dev/null
  fi
  
  log "SUCCESS" "RTA tools installation completed successfully"
}

# Configure desktop environment
configure_desktop() {
  log "STATUS" "Configuring desktop environment..."
  
  # Create desktop shortcuts
  mkdir -p /usr/share/applications
  
  # Metasploit shortcut
  if command -v msfconsole &>/dev/null; then
    cat > /usr/share/applications/metasploit.desktop << EOF
[Desktop Entry]
Name=Metasploit Framework
Comment=Security Testing Framework
Exec=x-terminal-emulator -e msfconsole
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Security;
EOF
  fi
  
  # Burp Suite shortcut
  if [ -f "/opt/BurpSuitePro/burpsuite_pro.jar" ] || [ -f "/usr/bin/burpsuite" ]; then
    cat > /usr/share/applications/burpsuite.desktop << EOF
[Desktop Entry]
Name=Burp Suite Professional
Comment=Web Application Security Testing
Exec=burpsuite
Icon=burpsuite
Terminal=false
Type=Application
Categories=Security;
EOF
  fi
  
  # Terminator shortcut
  if command -v terminator &>/dev/null; then
    cat > /usr/share/applications/terminator-custom.desktop << EOF
[Desktop Entry]
Name=Terminator (RTA)
Comment=Multiple GNOME terminals in one window
Exec=terminator
Icon=terminator
Type=Application
Categories=GNOME;GTK;Utility;TerminalEmulator;System;
StartupNotify=true
EOF
  fi
  
  # RTA tools menu
  mkdir -p /usr/share/desktop-directories
  cat > /usr/share/desktop-directories/rta-tools.directory << EOF
[Desktop Entry]
Name=RTA Security Tools
Icon=security-high
Type=Directory
EOF
  
  # Add more desktop configuration as needed
  
  log "SUCCESS" "Desktop environment configured"
}

# Run main function
main
exit 0
