#!/bin/bash
# =================================================================
# Robust Kali Linux Security Tools Installer
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
    "INFO")   echo -e "${BLUE}[i] $message${NC}" ;;
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
  if dpkg -l | grep -q "^ii  $package "; then
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
  
  for package in "${PACKAGES[@]}"; do
    if install_apt_package "$package"; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
    
    # Report progress
    log "INFO" "Progress: $success_count successful, $fail_count failed out of $total"
  done
  
  log "STATUS" "Apt package installation completed: $success_count successful, $fail_count failed"
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
  
  log "STATUS" "Installing $package with pipx..."
  run_safely "pipx install $package" "pipx-install-$package"
  
  # Verify installation
  if command -v "$package" &>/dev/null || [ -f "$HOME/.local/bin/$package" ]; then
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
  
  log "STATUS" "Installing $repo_name from GitHub..."
  
  # Check if git is installed
  if ! command -v git &>/dev/null; then
    install_apt_package "git"
  fi
  
  # Clone repository
  if [ ! -d "$TOOLS_DIR/$repo_name" ]; then
    run_safely "git clone $repo_url $TOOLS_DIR/$repo_name" "git-clone-$repo_name"
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to clone $repo_name"
      return 1
    fi
  else
    log "INFO" "$repo_name already exists, updating..."
    run_safely "cd $TOOLS_DIR/$repo_name && git pull" "git-pull-$repo_name"
  fi
  
  # Process repo based on type
  cd "$TOOLS_DIR/$repo_name"
  
  # Check for Python setup
  if [ -f "setup.py" ]; then
    log "INFO" "Python package detected, installing with pip..."
    run_safely "pip3 install -e ." "pip-install-$repo_name"
  elif [ -f "requirements.txt" ]; then
    log "INFO" "Python requirements detected, installing..."
    run_safely "pip3 install -r requirements.txt" "pip-requirements-$repo_name"
  fi
  
  # Create basic wrapper script
  if [ ! -f "/usr/local/bin/$repo_name" ]; then
    log "INFO" "Creating wrapper script for $repo_name..."
    echo "#!/bin/bash
cd $TOOLS_DIR/$repo_name
# Run the tool - adjust this line based on how the tool is executed
python3 $TOOLS_DIR/$repo_name/$(find . -name '*.py' | grep -E 'main|app|run' | head -1 2>/dev/null || echo 'main.py')
" > "/usr/local/bin/$repo_name"
    chmod +x "/usr/local/bin/$repo_name"
  fi
  
  log "SUCCESS" "$repo_name installed from GitHub"
  return 0
}

# Function to create a basic helper script for manual tools
create_helper_script() {
  local tool_name="$1"
  local helper_file="$TOOLS_DIR/helpers/install_${tool_name}.sh"
  
  mkdir -p "$TOOLS_DIR/helpers"
  
  log "INFO" "Creating helper script for $tool_name..."
  
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
}

# Function to read configuration from file
read_config() {
  local config_file="$1"
  local section="$2"
  
  if [ ! -f "$config_file" ]; then
    log "ERROR" "Configuration file not found: $config_file"
    return 1
  fi
  
  # Extract value from configuration file
  local value=$(grep -E "^$section:" "$config_file" | cut -d'"' -f2)
  echo "$value"
}

# Main installation function
main() {
  log "STATUS" "Starting RTA tools installation..."
  
  # Configuration file
  local config_file="/opt/rta-deployment/config/config.yml"
  
  # Create default config if it doesn't exist
  if [ ! -f "$config_file" ]; then
    log "INFO" "Configuration file not found, creating default..."
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" << EOF
# Default RTA configuration
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,proxychains4,metasploit-framework"
pipx_tools: "scoutsuite,impacket"
git_tools: "https://github.com/prowler-cloud/prowler.git"
manual_tools: "nessus,burpsuite_enterprise"
EOF
  fi
  
  # Read configuration
  local apt_tools=$(read_config "$config_file" "apt_tools")
  local pipx_tools=$(read_config "$config_file" "pipx_tools")
  local git_tools=$(read_config "$config_file" "git_tools")
  local manual_tools=$(read_config "$config_file" "manual_tools")
  
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
  
  # Create validation script
  log "INFO" "Creating validation script..."
  cat > "$TOOLS_DIR/scripts/validate-tools.sh" << 'EOF'
#!/bin/bash
# Tool validation script
echo "Validating installed tools..."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check_tool() {
  local tool="$1"
  if command -v "$tool" &>/dev/null; then
    echo -e "${GREEN}✓ $tool found${NC}"
    return 0
  else
    echo -e "${RED}✗ $tool not found${NC}"
    return 1
  fi
}

# Check common tools
echo "Checking core tools..."
check_tool nmap
check_tool wireshark
check_tool sqlmap
check_tool hydra
check_tool bettercap
check_tool proxychains4
check_tool msfconsole

echo "Checking pip tools..."
check_tool impacket-secretsdump
check_tool scout

echo "Checking for manual tools..."
[ -d "/opt/security-tools/helpers" ] && echo "Helper scripts available in /opt/security-tools/helpers"

echo "Validation complete."
EOF
  chmod +x "$TOOLS_DIR/scripts/validate-tools.sh"
  
  log "SUCCESS" "RTA tools installation completed successfully"
}

# Run main function
main
exit 0
