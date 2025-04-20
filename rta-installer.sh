#!/bin/bash

# ================================================================
# Enhanced Remote Testing Appliance (RTA) Tools Installer v3.0
# ================================================================
# Robust Kali Linux Security Tools Installer with advanced error
# handling, resource management, and comprehensive validation
# ================================================================

# Exit on error with controlled error handling
set +e

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
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$TOOLS_DIR/logs"
TEMP_DIR="/tmp/rta-installer"
CONFIG_DIR="$TOOLS_DIR/config"
HELPERS_DIR="$TOOLS_DIR/helpers"
SCRIPTS_DIR="$TOOLS_DIR/scripts"
DESKTOP_DIR="$TOOLS_DIR/desktop"
BIN_DIR="$TOOLS_DIR/bin"
VENV_DIR="$TOOLS_DIR/venvs"
INSTALL_LOG="$LOG_DIR/installation_$(date +%Y%m%d_%H%M%S).log"
REPORT_FILE="$LOG_DIR/installation_report_$(date +%Y%m%d_%H%M%S).txt"
CONFIG_FILE="$CONFIG_DIR/config.yml"

# Resource control settings
MAX_LOAD=4.0                  # Maximum system load average
MAX_MEMORY_PERCENT=80         # Maximum memory usage percentage
DEFAULT_TIMEOUT=300           # Default timeout for commands (5 minutes)
LONG_TIMEOUT=600              # Long timeout for larger operations (10 minutes)
MAX_RETRY=3                   # Maximum retry attempts
PARALLEL_JOBS=$(nproc)        # Number of parallel jobs
if [ $PARALLEL_JOBS -gt 4 ]; then
  PARALLEL_JOBS=4             # Limit to 4 parallel jobs max
fi

# Runtime settings
VERBOSE=false
FORCE_REINSTALL=false
SKIP_DOWNLOADS=false
SKIP_UPDATE=false
CORE_ONLY=false
CUSTOM_CONFIG=""
NO_COLOR=false
LOG_LEVEL="INFO"  # DEBUG, INFO, WARNING, ERROR, CRITICAL

# Record start time
START_TIME=$(date +%s)

# Trap signals for cleanup
trap cleanup EXIT INT TERM

# Function to display usage help
show_usage() {
  cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  -v, --verbose             Enable verbose output
  -f, --force               Force reinstallation of tools
  --no-downloads            Skip downloading external resources
  --no-update               Skip APT repository update
  --core-only               Install only core tools
  -c, --config FILE         Use custom configuration file
  --no-color                Disable colored output
  -l, --log-level LEVEL     Set log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)
  -h, --help                Display this help message and exit

Example:
  $0 --verbose --force      Verbose installation with forced reinstall
EOF
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -f|--force)
        FORCE_REINSTALL=true
        shift
        ;;
      --no-downloads)
        SKIP_DOWNLOADS=true
        shift
        ;;
      --no-update)
        SKIP_UPDATE=true
        shift
        ;;
      --core-only)
        CORE_ONLY=true
        shift
        ;;
      -c|--config)
        CUSTOM_CONFIG="$2"
        shift 2
        ;;
      --no-color)
        NO_COLOR=true
        # Reset all color variables if colors disabled
        if $NO_COLOR; then
          GREEN=''
          YELLOW=''
          RED=''
          BLUE=''
          CYAN=''
          MAGENTA=''
          BOLD=''
          NC=''
        fi
        shift
        ;;
      -l|--log-level)
        LOG_LEVEL="$2"
        shift 2
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}"
        show_usage
        exit 1
        ;;
    esac
  done
}

# Logging function
log() {
  local level="$1"
  local message="$2"
  
  # Skip logging if level is below the configured log level
  case "$LOG_LEVEL" in
    "DEBUG")
      # Log everything
      ;;
    "INFO")
      if [ "$level" = "DEBUG" ]; then return; fi
      ;;
    "WARNING")
      if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ]; then return; fi
      ;;
    "ERROR")
      if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ] || [ "$level" = "WARNING" ]; then return; fi
      ;;
    "CRITICAL")
      if [ "$level" != "CRITICAL" ]; then return; fi
      ;;
  esac
  
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_message="[$timestamp] [$level] $message"
  
  # Ensure log directory exists
  mkdir -p "$LOG_DIR"
  
  # Always write to log file
  echo "$log_message" >> "$INSTALL_LOG"
  
  # Determine console color
  local color_code=""
  case "$level" in
    "DEBUG")   color_code="$BLUE"   ;;
    "INFO")    color_code="$CYAN"   ;;
    "WARNING") color_code="$YELLOW" ;;
    "ERROR")   color_code="$RED"    ;;
    "CRITICAL")color_code="$RED$BOLD" ;;
    "SUCCESS") color_code="$GREEN"  ;;
    "STATUS")  color_code="$MAGENTA" ;;
  esac
  
  # Print to console based on verbosity setting
  if [ "$level" != "DEBUG" ] || $VERBOSE; then
    if $VERBOSE; then
      echo -e "${color_code}[$level] $message${NC}"
    else
      echo -e "${color_code}$message${NC}"
    fi
  fi
}

# Function to display a spinner animation during long operations
show_spinner() {
  local pid=$1
  local message="$2"
  local spin_chars='⣾⣽⣻⢿⡿⣟⣯⣷'
  local i=0
  
  tput civis  # Hide cursor
  
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) % ${#spin_chars} ))
    printf "\r${CYAN}[%c] ${NC}${message}..." "${spin_chars:$i:1}"
    sleep 0.1
  done
  
  wait $pid
  local exit_status=$?
  
  # Clear line and show final status
  printf "\r${CYAN}[*] ${NC}${message}... "
  
  if [ $exit_status -eq 0 ]; then
    echo -e "${GREEN}Done${NC}"
  else
    echo -e "${RED}Failed (Code: $exit_status)${NC}"
  fi
  
  tput cnorm  # Show cursor
  return $exit_status
}

# Function to display a progress bar
show_progress() {
  local current=$1
  local total=$2
  local message="$3"
  local width=40
  local percent=$((current * 100 / total))
  local completed=$((width * current / total))
  local todo=$((width - completed))
  
  # Build progress bar
  local bar="["
  for ((i=0; i<completed; i++)); do
    bar+="#"
  done
  for ((i=0; i<todo; i++)); do
    bar+="-"
  done
  bar+="]"
  
  # Ensure progress message fits terminal width
  local term_width=$(tput cols 2>/dev/null || echo 80)
  local max_message_width=$((term_width - width - 15))
  if [ ${#message} -gt $max_message_width ]; then
    message="${message:0:$((max_message_width-3))}..."
  fi
  
  # Print progress
  printf "\r${CYAN}%3d%%${NC} %-${max_message_width}s %s" "$percent" "$message" "$bar"
  
  # Add new line if we're at 100%
  if [ $percent -eq 100 ]; then
    echo ""
  fi
}

# Function to check if running as root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    log "CRITICAL" "This script must be run as root"
    echo -e "${RED}[!] This script must be run as root or with sudo${NC}"
    exit 1
  fi
}

# Function to check system resources before running intensive operations
check_resources() {
  # Check system load
  local load=$(cat /proc/loadavg | awk '{print $1}')
  if (( $(echo "$load > $MAX_LOAD" | bc -l) )); then
    log "WARNING" "System load is high: $load (threshold: $MAX_LOAD)"
    log "WARNING" "Waiting for system load to reduce..."
    
    # Wait with visual feedback
    printf "${YELLOW}[!] System load high (${load}). Waiting.${NC}"
    while (( $(echo "$(cat /proc/loadavg | awk '{print $1}') > $MAX_LOAD" | bc -l) )); do
      printf "."
      sleep 3
    done
    printf " ${GREEN}Load reduced.${NC}\n"
    
    log "INFO" "System load reduced to acceptable level"
    return 0
  fi
  
  # Check memory usage
  local mem_used_percent=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
  if (( $(echo "$mem_used_percent > $MAX_MEMORY_PERCENT" | bc -l) )); then
    log "WARNING" "Memory usage is high: ${mem_used_percent%.2f}% (threshold: $MAX_MEMORY_PERCENT%)"
    log "WARNING" "Waiting for memory usage to reduce..."
    
    # Wait with visual feedback
    printf "${YELLOW}[!] Memory usage high (${mem_used_percent%.2f}%%). Waiting.${NC}"
    while (( $(echo "$(free | grep Mem | awk '{print $3/$2 * 100.0}') > $MAX_MEMORY_PERCENT" | bc -l) )); do
      printf "."
      sleep 5
    done
    printf " ${GREEN}Memory freed.${NC}\n"
    
    log "INFO" "Memory usage reduced to acceptable level"
  fi
  
  return 0
}

# Function to create required directories
create_directories() {
  log "STATUS" "Creating required directories..."
  
  # Define all required directories
  local dirs=(
    "$TOOLS_DIR"
    "$LOG_DIR"
    "$TEMP_DIR"
    "$CONFIG_DIR"
    "$HELPERS_DIR"
    "$SCRIPTS_DIR"
    "$DESKTOP_DIR"
    "$BIN_DIR"
    "$VENV_DIR"
  )
  
  # Create directories with proper permissions
  for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir"
      if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create directory: $dir"
        continue
      fi
      chmod 755 "$dir"
      log "DEBUG" "Created directory: $dir"
    else
      log "DEBUG" "Directory already exists: $dir"
    fi
  done
  
  # Ensure correct ownership (especially important if run with sudo)
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$TOOLS_DIR"
    log "DEBUG" "Set ownership of $TOOLS_DIR to $SUDO_USER"
  fi
  
  log "SUCCESS" "Directories created successfully"
  return 0
}

# Function to run a command with timeout and enhanced error handling
run_command() {
  local cmd="$1"
  local description="$2"
  local timeout_duration="${3:-$DEFAULT_TIMEOUT}"
  local log_file="$LOG_DIR/cmd_${description// /_}_$(date +%Y%m%d_%H%M%S).log"
  
  # Ensure resources are available
  check_resources
  
  log "DEBUG" "Running command: $cmd"
  log "DEBUG" "Timeout: $timeout_duration seconds"
  log "DEBUG" "Log file: $log_file"
  
  # Execute command with timeout
  timeout $timeout_duration bash -c "$cmd" > "$log_file" 2>&1 &
  local cmd_pid=$!
  
  # Show spinner if not in verbose mode
  if ! $VERBOSE; then
    show_spinner $cmd_pid "$description"
    local result=$?
  else
    # In verbose mode, show real-time output
    log "INFO" "Running: $description"
    tail -f "$log_file" --pid=$cmd_pid &
    local tail_pid=$!
    wait $cmd_pid
    local result=$?
    kill $tail_pid 2>/dev/null
  fi
  
  # Handle result
  if [ $result -eq 0 ]; then
    log "SUCCESS" "$description completed successfully"
    return 0
  elif [ $result -eq 124 ] || [ $result -eq 143 ]; then
    log "ERROR" "$description timed out after $timeout_duration seconds"
    if ! $VERBOSE; then
      log "INFO" "Last lines of output:"
      tail -n 5 "$log_file" | while read -r line; do log "INFO" "  > $line"; done
    fi
    return 124
  else
    log "ERROR" "$description failed with exit code $result"
    if ! $VERBOSE; then
      log "INFO" "Last lines of output:"
      tail -n 5 "$log_file" | while read -r line; do log "INFO" "  > $line"; done
    fi
    return $result
  fi
}

# Function to run a command with retry logic
run_with_retry() {
  local cmd="$1"
  local description="$2"
  local timeout_duration="${3:-$DEFAULT_TIMEOUT}"
  local max_attempts="${4:-$MAX_RETRY}"
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    log "DEBUG" "Attempt $attempt of $max_attempts: $description"
    
    if [ $attempt -gt 1 ]; then
      log "INFO" "Retry $attempt/$max_attempts for: $description"
    fi
    
    run_command "$cmd" "$description" "$timeout_duration"
    local result=$?
    
    if [ $result -eq 0 ]; then
      if [ $attempt -gt 1 ]; then
        log "SUCCESS" "$description successful on attempt $attempt"
      fi
      return 0
    fi
    
    if [ $attempt -ge $max_attempts ]; then
      log "ERROR" "$description failed after $max_attempts attempts"
      return $result
    fi
    
    # Calculate exponential backoff delay: 2^attempt seconds with max of 30 seconds
    local delay=$((2 ** attempt))
    if [ $delay -gt 30 ]; then delay=30; fi
    
    log "WARNING" "$description failed (code $result), retrying in $delay seconds..."
    sleep $delay
    
    attempt=$((attempt + 1))
  done
  
  # Should never get here, but just in case
  return 1
}

# Function to install an apt package with improved error handling
install_apt_package() {
  local package="$1"
  local conflicting_packages="$2"  # Optional: comma-separated list
  local log_file="$LOG_DIR/${package// /_}_apt_install.log"
  
  log "INFO" "Installing $package with apt..."
  
  # Check if already installed and not forcing reinstall
  if dpkg -l | grep -q "^ii  $package " && ! $FORCE_REINSTALL; then
    log "SUCCESS" "$package is already installed"
    echo "[SUCCESS] $package: Already installed" >> "$REPORT_FILE"
    return 0
  fi
  
  # Update APT repositories if needed and not skipped
  if ! $SKIP_UPDATE; then
    if [ ! -f "/tmp/apt_updated" ] || [ $(( $(date +%s) - $(stat -c %Y /tmp/apt_updated 2>/dev/null || echo 0) )) -gt 3600 ]; then
      log "INFO" "Updating APT repositories..."
      run_with_retry "apt-get update" "APT repository update"
      touch "/tmp/apt_updated"
    fi
  fi
  
  # Handle conflicting packages if specified
  if [ ! -z "$conflicting_packages" ]; then
    log "DEBUG" "Checking for conflicting packages: $conflicting_packages"
    
    for pkg in $(echo $conflicting_packages | tr ',' ' '); do
      if dpkg -l | grep -q "^ii  $pkg "; then
        log "WARNING" "Found conflicting package $pkg, removing..."
        
        run_with_retry "apt-get remove -y $pkg" "Removing conflicting package $pkg"
        if [ $? -ne 0 ]; then
          log "ERROR" "Failed to remove conflicting package: $pkg"
          echo "[FAILED] $package: Unable to resolve conflict with $pkg" >> "$REPORT_FILE"
          return 1
        fi
      fi
    done
  fi
  
  # Install the package with a timeout
  run_with_retry "DEBIAN_FRONTEND=noninteractive apt-get install -y $package" "Installing $package with apt" $LONG_TIMEOUT
  local result=$?
  
  # Verify installation regardless of return code (sometimes apt returns non-zero but package installs)
  if dpkg -l | grep -q "^ii  $package "; then
    log "SUCCESS" "$package installed successfully with apt"
    echo "[SUCCESS] $package: Installed with apt" >> "$REPORT_FILE"
    return 0
  else
    # Try to fix broken dependencies and retry once
    if [ $result -ne 0 ]; then
      log "WARNING" "Installation failed, attempting to fix dependencies..."
      
      run_with_retry "apt-get -f install -y" "Fixing broken dependencies"
      run_with_retry "DEBIAN_FRONTEND=noninteractive apt-get install -y $package" "Retrying $package installation" $LONG_TIMEOUT
      
      # Final verification
      if dpkg -l | grep -q "^ii  $package "; then
        log "SUCCESS" "$package installed successfully after fixing dependencies"
        echo "[SUCCESS] $package: Installed with apt after fixing dependencies" >> "$REPORT_FILE"
        return 0
      fi
    fi
    
    log "ERROR" "Failed to install $package with apt"
    echo "[FAILED] $package: APT installation failed" >> "$REPORT_FILE"
    return 1
  fi
}

# Function to install a list of apt packages with parallel processing
install_apt_packages() {
  local package_list="$1"
  
  # Skip if empty list
  if [ -z "$package_list" ]; then
    log "WARNING" "Empty APT package list, skipping..."
    return 0
  fi
  
  # Split package list
  IFS=',' read -ra packages <<< "$package_list"
  local total_packages=${#packages[@]}
  
  log "STATUS" "Installing $total_packages APT packages..."
  echo "APT Packages ($total_packages):" >> "$REPORT_FILE"
  
  # Update apt repository if not skipped
  if ! $SKIP_UPDATE; then
    log "INFO" "Updating APT repositories..."
    run_with_retry "apt-get update" "APT repository update"
    touch "/tmp/apt_updated"
  fi
  
  local success_count=0
  local fail_count=0
  
  # Use parallel processing for larger package lists if available
  if command -v parallel &>/dev/null && [ $total_packages -gt 10 ]; then
    log "INFO" "Using parallel processing for APT packages ($PARALLEL_JOBS jobs)"
    
    # Create temporary file to track results
    local results_file=$(mktemp)
    
    # Export functions for parallel
    export -f log run_command run_with_retry install_apt_package check_resources
    export TOOLS_DIR LOG_DIR REPORT_FILE FORCE_REINSTALL VERBOSE NO_COLOR LOG_LEVEL DEFAULT_TIMEOUT LONG_TIMEOUT MAX_RETRY
    export GREEN YELLOW RED BLUE CYAN MAGENTA BOLD NC
    
    # Process packages in parallel with status updates
    (
      echo "${packages[@]}" | tr ' ' '\n' | \
        parallel -j $PARALLEL_JOBS --eta --progress --joblog "$LOG_DIR/parallel_apt.log" \
          "install_apt_package {} && echo SUCCESS:{} >> $results_file || echo FAIL:{} >> $results_file"
    ) 2>&1 | grep --line-buffered -v "^parallel:" | while read -r line; do
      log "DEBUG" "Parallel: $line"
    done
    
    # Process results
    if [ -f "$results_file" ]; then
      while read -r line; do
        if [[ "$line" == SUCCESS:* ]]; then
          ((success_count++))
          package=${line#SUCCESS:}
          log "DEBUG" "Successfully installed: $package"
        elif [[ "$line" == FAIL:* ]]; then
          ((fail_count++))
          package=${line#FAIL:}
          log "ERROR" "Failed to install: $package"
        fi
      done < "$results_file"
      
      rm -f "$results_file"
    fi
  else
    # Sequential installation with progress bar
    local current=0
    
    for package in "${packages[@]}"; do
      ((current++))
      show_progress $current $total_packages "Installing $package"
      
      install_apt_package "$package"
      if [ $? -eq 0 ]; then
        ((success_count++))
      else
        ((fail_count++))
      fi
    done
    
    # Ensure we end with a newline
    if [ $total_packages -gt 0 ]; then
      echo ""
    fi
  fi
  
  # Fix any broken dependencies
  if [ $fail_count -gt 0 ]; then
    log "WARNING" "Some packages failed to install, attempting to fix dependencies..."
    run_with_retry "apt-get -f install -y" "Fixing broken dependencies"
  fi
  
  log "STATUS" "APT package installation completed: $success_count successful, $fail_count failed, out of $total_packages"
  return $fail_count
}

# Function to setup and use a Python virtual environment
setup_venv() {
  local tool_name="$1"
  local venv_dir="$VENV_DIR/$tool_name"
  
  log "INFO" "Setting up virtual environment for $tool_name..."
  
  # Ensure Python and venv are installed
  if ! command -v python3 &>/dev/null; then
    log "WARNING" "Python3 not found, installing..."
    install_apt_package "python3"
  fi
  
  if ! python3 -c "import venv" &>/dev/null 2>&1; then
    log "WARNING" "Python venv module not found, installing..."
    install_apt_package "python3-venv"
  fi
  
  # Create virtual environment if it doesn't exist
  if [ ! -d "$venv_dir" ]; then
    run_with_retry "python3 -m venv '$venv_dir'" "Creating virtual environment for $tool_name"
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create virtual environment for $tool_name"
      return 1
    fi
  fi
  
  # Activate virtual environment
  source "$venv_dir/bin/activate"
  if [ $? -ne 0 ]; then
    log "ERROR" "Failed to activate virtual environment for $tool_name"
    return 1
  fi
  
  # Upgrade pip in the virtual environment
  run_with_retry "pip install --upgrade pip" "Upgrading pip in $tool_name venv"
  
  log "SUCCESS" "Virtual environment for $tool_name ready"
  return 0
}

# Function to install a tool with pipx
install_pipx_tool() {
  local tool_name="$1"
  local extra_args="$2"  # Optional arguments for pipx
  
  log "INFO" "Installing $tool_name with pipx..."
  
  # Check if already installed
  if pipx list 2>/dev/null | grep -q "$tool_name" && ! $FORCE_REINSTALL; then
    log "SUCCESS" "$tool_name already installed with pipx"
    echo "[SUCCESS] $tool_name: Already installed with pipx" >> "$REPORT_FILE"
    return 0
  fi
  
  # Ensure pipx is installed
  if ! command -v pipx &>/dev/null; then
    log "INFO" "Installing pipx..."
    
    install_apt_package "python3-pip"
    install_apt_package "python3-venv"
    
    run_with_retry "python3 -m pip install --user pipx" "Installing pipx"
    run_with_retry "python3 -m pipx ensurepath" "Setting up pipx in PATH"
    
    # Add pipx to PATH for this session
    if [ -d "$HOME/.local/bin" ]; then
      export PATH="$PATH:$HOME/.local/bin"
    fi
    
    # Verify installation
    if ! command -v pipx &>/dev/null; then
      log "ERROR" "Failed to install pipx"
      echo "[FAILED] $tool_name: Could not install pipx dependency" >> "$REPORT_FILE"
      return 1
    fi
  fi
  
  # Uninstall first if force reinstall
  if $FORCE_REINSTALL && pipx list 2>/dev/null | grep -q "$tool_name"; then
    log "INFO" "Removing existing installation of $tool_name..."
    run_with_retry "pipx uninstall $tool_name" "Uninstalling $tool_name"
  fi
  
  # Install with pipx
  if [ -z "$extra_args" ]; then
    run_with_retry "pipx install $tool_name" "Installing $tool_name with pipx" $LONG_TIMEOUT
  else
    run_with_retry "pipx install $tool_name $extra_args" "Installing $tool_name with pipx and arguments" $LONG_TIMEOUT
  fi
  
  # Verify installation
  if pipx list 2>/dev/null | grep -q "$tool_name"; then
    log "SUCCESS" "$tool_name installed successfully with pipx"
    echo "[SUCCESS] $tool_name: Installed with pipx" >> "$REPORT_FILE"
    
    # Create symlink in /usr/local/bin if it doesn't exist
    local bin_path=$(which "$tool_name" 2>/dev/null || echo "")
    if [ -n "$bin_path" ] && [ ! -e "/usr/local/bin/$tool_name" ]; then
      ln -sf "$bin_path" "/usr/local/bin/$tool_name"
      log "DEBUG" "Created symlink for $tool_name in /usr/local/bin"
    fi
    
    return 0
  else
    # Try alternative approach with pip in a venv
    log "WARNING" "Pipx installation failed for $tool_name, trying with venv and pip..."
    
    setup_venv "$tool_name"
    if [ $? -eq 0 ]; then
      run_with_retry "pip install $tool_name" "Installing $tool_name with pip in venv"
      
      # Create wrapper script
      log "INFO" "Creating wrapper script for $tool_name..."
      
      cat > "/usr/local/bin/$tool_name" << EOF
#!/bin/bash
source "$VENV_DIR/$tool_name/bin/activate"
if [ -f "$VENV_DIR/$tool_name/bin/$tool_name" ]; then
  "$VENV_DIR/$tool_name/bin/$tool_name" "\$@"
else
  python -m $tool_name "\$@"
fi
deactivate
EOF
      chmod +x "/usr/local/bin/$tool_name"
      
      # Deactivate venv
      deactivate
      
      log "SUCCESS" "$tool_name installed with pip in venv"
      echo "[SUCCESS] $tool_name: Installed with pip in venv (pipx failed)" >> "$REPORT_FILE"
      return 0
    else
      log "ERROR" "All installation methods failed for $tool_name"
      echo "[FAILED] $tool_name: All installation methods failed" >> "$REPORT_FILE"
      return 1
    fi
  fi
}

# Function to install a list of pipx tools
install_pipx_tools() {
  local tool_list="$1"
  
  # Skip if empty list
  if [ -z "$tool_list" ]; then
    log "WARNING" "Empty pipx tool list, skipping..."
    return 0
  fi
  
  # Split tool list
  IFS=',' read -ra tools <<< "$tool_list"
  local total_tools=${#tools[@]}
  
  log "STATUS" "Installing $total_tools tools with pipx..."
  echo "PIPX Packages ($total_tools):" >> "$REPORT_FILE"
  
  local success_count=0
  local fail_count=0
  local current=0
  
  # Install each tool with progress indicator
  for tool in "${tools[@]}"; do
    ((current++))
    show_progress $current $total_tools "Installing $tool with pipx"
    
    install_pipx_tool "$tool"
    if [ $? -eq 0 ]; then
      ((success_count++))
    else
      ((fail_count++))
    fi
  done
  
  # Ensure we end with a newline
  if [ $total_tools -gt 0 ]; then
    echo ""
  fi
  
  log "STATUS" "Pipx tools installation completed: $success_count successful, $fail_count failed, out of $total_tools"
  return $fail_count
}

# Function to process a Git repository
process_git_repo() {
  local repo_dir="$1"
  local repo_name="$2"
  local log_file="$LOG_DIR/${repo_name}_process.log"
  
  log "INFO" "Processing $repo_name repository..."
  
  # Change to repository directory
  cd "$repo_dir" || {
    log "ERROR" "Failed to change to directory: $repo_dir"
    echo "[FAILED] $repo_name: Could not access repository directory" >> "$REPORT_FILE"
    return 1
  }
  
  # Look for installation instructions in README files
  local readme_file=""
  for file in "README.md" "README" "README.txt"; do
    if [ -f "$file" ]; then
      readme_file="$file"
      break
    fi
  done
  
  local setup_method="custom"  # Default method
  
  # Detect repository type and installation method
  if [ -f "setup.py" ]; then
    setup_method="python_setup"
  elif [ -f "requirements.txt" ]; then
    setup_method="python_requirements"
  elif [ -f "go.mod" ]; then
    setup_method="golang"
  elif [ -f "package.json" ]; then
    setup_method="nodejs"
  elif [ -f "Makefile" ] || [ -f "makefile" ]; then
    setup_method="make"
  elif [ -n "$readme_file" ]; then
    # Check README for installation instructions
    if grep -q "pip install" "$readme_file"; then
      setup_method="python_pip"
    elif grep -q "go build" "$readme_file"; then
      setup_method="golang"
    elif grep -q "npm install" "$readme_file"; then
      setup_method="nodejs"
    elif grep -q "make " "$readme_file"; then
      setup_method="make"
    fi
  fi
  
  log "DEBUG" "Detected setup method for $repo_name: $setup_method"
  
  # Process based on detected method
  case "$setup_method" in
    "python_setup")
      log "INFO" "Installing $repo_name with Python setup.py..."
      
      setup_venv "$repo_name"
      if [ $? -eq 0 ]; then
        run_with_retry "pip install -e ." "Installing $repo_name with setup.py" $LONG_TIMEOUT
        local result=$?
        deactivate
        
        if [ $result -eq 0 ]; then
          # Create symlink to bin directory if executable exists
          if [ -f "$VENV_DIR/$repo_name/bin/$repo_name" ]; then
            ln -sf "$VENV_DIR/$repo_name/bin/$repo_name" "/usr/local/bin/$repo_name"
            log "DEBUG" "Created symlink for $repo_name in /usr/local/bin"
          fi
          
          # Create desktop shortcut
          create_desktop_shortcut "$repo_name" "x-terminal-emulator -e /usr/local/bin/$repo_name" "" "Security;Utility;"
          
          log "SUCCESS" "$repo_name installed via setup.py"
          echo "[SUCCESS] $repo_name: Installed via setup.py in virtual environment" >> "$REPORT_FILE"
          return 0
        else
          log "ERROR" "Failed to install $repo_name with setup.py"
          echo "[PARTIAL] $repo_name: Setup.py installation failed" >> "$REPORT_FILE"
        fi
      fi
      ;;
      
    "python_requirements")
      log "INFO" "Installing requirements for $repo_name..."
      
      setup_venv "$repo_name"
      if [ $? -eq 0 ]; then
        run_with_retry "pip install -r requirements.txt" "Installing requirements for $repo_name" $LONG_TIMEOUT
        local requirements_result=$?
        
        # Try to install the package itself if requirements installed successfully
        if [ $requirements_result -eq 0 ] && [ -f "setup.py" ]; then
          run_with_retry "pip install -e ." "Installing $repo_name package" $LONG_TIMEOUT
          local setup_result=$?
          deactivate
          
          if [ $setup_result -eq 0 ]; then
            log "SUCCESS" "$repo_name installed with requirements and setup.py"
            echo "[SUCCESS] $repo_name: Installed via requirements.txt and setup.py" >> "$REPORT_FILE"
            return 0
          else
            deactivate
            log "WARNING" "Installed requirements but failed to install package for $repo_name"
            echo "[PARTIAL] $repo_name: Requirements installed but package installation failed" >> "$REPORT_FILE"
          fi
        else
          deactivate
          
          if [ $requirements_result -eq 0 ]; then
            log "SUCCESS" "$repo_name requirements installed"
            echo "[SUCCESS] $repo_name: Requirements installed in virtual environment" >> "$REPORT_FILE"
            return 0
          else
            log "ERROR" "Failed to install requirements for $repo_name"
            echo "[PARTIAL] $repo_name: Requirements installation failed" >> "$REPORT_FILE"
          fi
        fi
      fi
      ;;
      
    "golang")
      log "INFO" "Building Go module for $repo_name..."
      
      # Ensure Go is installed
      if ! command -v go &>/dev/null; then
        log "INFO" "Installing Go..."
        install_apt_package "golang"
      fi
      
      # Build the module
      if [ -f "go.mod" ]; then
        run_with_retry "go build -o $repo_name" "Building $repo_name Go module" $LONG_TIMEOUT
      else
        run_with_retry "go build" "Building $repo_name Go module" $LONG_TIMEOUT
      fi
      
      # Check if build was successful and executable exists
      if [ $? -eq 0 ]; then
        # Find the built executable
        local executable=""
        if [ -f "$repo_name" ]; then
          executable="$repo_name"
        else
          executable=$(find . -maxdepth 1 -type f -executable | grep -v "\.sh$" | head -1)
        fi
        
        if [ -n "$executable" ]; then
          chmod +x "$executable"
          ln -sf "$repo_dir/$executable" "/usr/local/bin/$(basename $executable)"
          
          # Create desktop shortcut
          create_desktop_shortcut "$repo_name" "/usr/local/bin/$(basename $executable)" "" "Security;Utility;"
          
          log "SUCCESS" "$repo_name Go module built and linked"
          echo "[SUCCESS] $repo_name: Go module built and linked to /usr/local/bin" >> "$REPORT_FILE"
          return 0
        else
          log "WARNING" "No executable found after building $repo_name"
          echo "[PARTIAL] $repo_name: Go module built but no executable found" >> "$REPORT_FILE"
        fi
      else
        log "ERROR" "Failed to build $repo_name Go module"
        echo "[PARTIAL] $repo_name: Go build failed" >> "$REPORT_FILE"
      fi
      ;;
      
    "nodejs")
      log "INFO" "Installing Node.js dependencies for $repo_name..."
      
      # Ensure Node.js and npm are installed
      if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
        log "INFO" "Installing Node.js and npm..."
        install_apt_package "nodejs npm"
      fi
      
      # Install dependencies
      run_with_retry "npm install" "Installing Node.js dependencies for $repo_name" $LONG_TIMEOUT
      
      if [ $? -eq 0 ]; then
        log "SUCCESS" "$repo_name Node.js dependencies installed"
        
        # Check if there's a bin script to link
        if [ -f "package.json" ]; then
          local bin_script=$(grep -o '"bin"[[:space:]]*:[[:space:]]*"[^"]*"' package.json | cut -d'"' -f4)
          
          if [ -n "$bin_script" ] && [ -f "$bin_script" ]; then
            chmod +x "$bin_script"
            ln -sf "$repo_dir/$bin_script" "/usr/local/bin/$repo_name"
            log "DEBUG" "Created symlink for $repo_name bin script in /usr/local/bin"
          fi
        fi
        
        echo "[SUCCESS] $repo_name: Node.js dependencies installed" >> "$REPORT_FILE"
        return 0
      else
        log "ERROR" "Failed to install Node.js dependencies for $repo_name"
        echo "[PARTIAL] $repo_name: Node.js dependencies installation failed" >> "$REPORT_FILE"
      fi
      ;;
      
    "make")
      log "INFO" "Building $repo_name with make..."
      
      # Ensure build-essential is installed
      if ! command -v make &>/dev/null; then
        log "INFO" "Installing build-essential..."
        install_apt_package "build-essential"
      fi
      
      # Run make
      run_with_retry "make" "Building $repo_name with make" $LONG_TIMEOUT
      
      if [ $? -eq 0 ]; then
        log "SUCCESS" "$repo_name built with make"
        
        # Try to find and link executable(s)
        found_executable=false
        
        find . -type f -executable -not -path "*/\.*" | while read -r executable; do
          if [[ "$executable" == *"$repo_name"* ]] || [[ "$executable" == *"/bin/"* ]]; then
            chmod +x "$executable"
            ln -sf "$executable" "/usr/local/bin/$(basename $executable)"
            log "DEBUG" "Linked executable: $(basename $executable)"
            found_executable=true
          fi
        done
        
        if $found_executable; then
          echo "[SUCCESS] $repo_name: Built with make and executables linked" >> "$REPORT_FILE"
        else
          echo "[PARTIAL] $repo_name: Built with make but no executables linked" >> "$REPORT_FILE"
        fi
        
        return 0
      else
        log "ERROR" "Failed to build $repo_name with make"
        echo "[PARTIAL] $repo_name: Make build failed" >> "$REPORT_FILE"
      fi
      ;;
      
    "custom")
      log "INFO" "Using custom processing for $repo_name..."
      
      # Look for any executable files
      local main_executable=""
      
      # First look for specific executable patterns
      for name in "$repo_name" "$repo_name.py" "$repo_name.sh" "main" "main.py" "main.sh" "run" "run.py" "run.sh"; do
        if [ -f "$name" ]; then
          main_executable="$name"
          break
        fi
      done
      
      # If nothing found, look for any executable in the repo
      if [ -z "$main_executable" ]; then
        main_executable=$(find . -type f -executable -not -path "*/\.*" | head -1)
      fi
      
      if [ -n "$main_executable" ]; then
        log "INFO" "Found executable for $repo_name: $main_executable"
        
        chmod +x "$main_executable"
        ln -sf "$repo_dir/$main_executable" "/usr/local/bin/$repo_name"
        
        # Create desktop shortcut
        create_desktop_shortcut "$repo_name" "/usr/local/bin/$repo_name" "" "Security;Utility;"
        
        log "SUCCESS" "Linked executable for $repo_name"
        echo "[SUCCESS] $repo_name: Linked executable and created desktop shortcut" >> "$REPORT_FILE"
        return 0
      else
        # Create a readme viewer as a last resort
        if [ -n "$readme_file" ]; then
          log "INFO" "Creating info viewer for $repo_name..."
          
          cat > "/usr/local/bin/${repo_name}-info" << EOF
#!/bin/bash
cd "$repo_dir"
if command -v batcat &>/dev/null; then
  batcat "$readme_file"
else
  less "$readme_file"
fi
EOF
          chmod +x "/usr/local/bin/${repo_name}-info"
          
          create_desktop_shortcut "${repo_name}-info" "x-terminal-emulator -e /usr/local/bin/${repo_name}-info" "text-x-generic" "Security;Documentation;"
          
          log "INFO" "Created info viewer for $repo_name"
          echo "[PARTIAL] $repo_name: Created info viewer for documentation" >> "$REPORT_FILE"
        else
          log "WARNING" "Could not determine installation method for $repo_name"
          echo "[PARTIAL] $repo_name: Could not determine installation method" >> "$REPORT_FILE"
        fi
      fi
      ;;
  esac
  
  return 1
}

# Function to install a GitHub tool
install_github_tool() {
  local repo_url="$1"
  local branch="${2:-master}"  # Optional branch/tag to checkout
  
  # Extract repository name from URL
  local repo_name=$(basename "$repo_url" .git)
  local repo_dir="$TOOLS_DIR/$repo_name"
  local log_file="$LOG_DIR/${repo_name}_git_install.log"
  
  log "INFO" "Installing $repo_name from GitHub..."
  
  # Ensure git is installed
  if ! command -v git &>/dev/null; then
    log "INFO" "Installing git..."
    install_apt_package "git"
  fi
  
  # Check if repository directory already exists
  if [ -d "$repo_dir/.git" ] && ! $FORCE_REINSTALL; then
    log "INFO" "$repo_name directory already exists, updating..."
    
    cd "$repo_dir" || {
      log "ERROR" "Failed to change to repository directory: $repo_dir"
      echo "[FAILED] $repo_name: Could not access repository directory" >> "$REPORT_FILE"
      return 1
    }
    
    # Update repository
    run_with_retry "git fetch && git reset --hard origin/$branch" "Updating $repo_name repository"
    local update_result=$?
    
    if [ $update_result -eq 0 ]; then
      log "SUCCESS" "$repo_name repository updated successfully"
    else
      log "WARNING" "Failed to update $repo_name repository, attempting fresh clone..."
      
      # Remove the directory and clone again
      cd "$TOOLS_DIR"
      rm -rf "$repo_dir"
      
      run_with_retry "git clone --depth 1 --branch $branch $repo_url $repo_dir" "Cloning $repo_name repository" $LONG_TIMEOUT
      if [ $? -ne 0 ]; then
        log "ERROR" "Failed to clone $repo_name repository"
        echo "[FAILED] $repo_name: Git clone failed" >> "$REPORT_FILE"
        return 1
      fi
    fi
  else
    # Clone repository
    if [ -d "$repo_dir" ]; then
      log "INFO" "Removing existing $repo_name directory for fresh clone..."
      rm -rf "$repo_dir"
    fi
    
    cd "$TOOLS_DIR" || {
      log "ERROR" "Failed to change to tools directory: $TOOLS_DIR"
      echo "[FAILED] $repo_name: Could not access tools directory" >> "$REPORT_FILE"
      return 1
    }
    
    run_with_retry "git clone --depth 1 --branch $branch $repo_url $repo_dir" "Cloning $repo_name repository" $LONG_TIMEOUT
    if [ $? -ne 0 ]; then
      # Try without specifying branch as fallback
      log "WARNING" "Failed to clone with specified branch, trying default branch..."
      run_with_retry "git clone --depth 1 $repo_url $repo_dir" "Cloning $repo_name repository with default branch" $LONG_TIMEOUT
      
      if [ $? -ne 0 ]; then
        log "ERROR" "Failed to clone $repo_name repository"
        echo "[FAILED] $repo_name: Git clone failed" >> "$REPORT_FILE"
        return 1
      fi
    fi
    
    log "SUCCESS" "$repo_name repository cloned successfully"
  fi
  
  # Process the repository
  process_git_repo "$repo_dir" "$repo_name"
  return $?
}

# Function to install a list of GitHub tools
install_github_tools() {
  local repo_list="$1"
  
  # Skip if empty list
  if [ -z "$repo_list" ]; then
    log "WARNING" "Empty GitHub repository list, skipping..."
    return 0
  fi
  
  # Split repository list
  IFS=',' read -ra repos <<< "$repo_list"
  local total_repos=${#repos[@]}
  
  log "STATUS" "Installing $total_repos GitHub repositories..."
  echo "GitHub Repositories ($total_repos):" >> "$REPORT_FILE"
  
  local success_count=0
  local fail_count=0
  local current=0
  
  # Install each repository with progress indicator
  for repo_url in "${repos[@]}"; do
    ((current++))
    local repo_name=$(basename "$repo_url" .git)
    show_progress $current $total_repos "Cloning/updating $repo_name"
    
    install_github_tool "$repo_url"
    if [ $? -eq 0 ]; then
      ((success_count++))
    else
      ((fail_count++))
    fi
  done
  
  # Ensure we end with a newline
  if [ $total_repos -gt 0 ]; then
    echo ""
  fi
  
  log "STATUS" "GitHub repositories installation completed: $success_count successful, $fail_count failed, out of $total_repos"
  return $fail_count
}

# Function to create a desktop shortcut
create_desktop_shortcut() {
  local name="$1"
  local exec_command="$2"
  local icon="${3:-utilities-terminal}"
  local categories="${4:-Security;}"
  
  log "DEBUG" "Creating desktop shortcut for $name..."
  
  # Ensure applications directory exists
  mkdir -p "/usr/share/applications"
  
  # Create desktop entry
  cat > "/usr/share/applications/${name}.desktop" << EOF
[Desktop Entry]
Name=$name
Exec=$exec_command
Type=Application
Icon=$icon
Terminal=false
Categories=$categories
EOF
  
  # Create copy in tools desktop directory for backup
  mkdir -p "$DESKTOP_DIR"
  cp "/usr/share/applications/${name}.desktop" "$DESKTOP_DIR/"
  
  log "DEBUG" "Desktop shortcut created for $name"
  return 0
}

# Function to create a manual installation helper script
create_helper_script() {
  local tool_name="$1"
  local helper_script="$HELPERS_DIR/install_${tool_name}.sh"
  
  log "INFO" "Creating helper script for $tool_name..."
  
  # Create basic structure
  mkdir -p "$HELPERS_DIR"
  
  # Specific helper scripts based on tool type
  case "$tool_name" in
    "nessus")
      cat > "$helper_script" << 'EOF'
#!/bin/bash
# Helper script to install Nessus with improved download verification

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[i] Starting Nessus installation...${NC}"

# Verify and download the Nessus package
NESSUS_PKG="/opt/security-tools/downloads/Nessus-10.5.0-debian10_amd64.deb"
NESSUS_URL="https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true"

# Create download directory if it doesn't exist
mkdir -p "$(dirname "$NESSUS_PKG")"

# Check if the DEB package exists and is valid
if [ ! -f "$NESSUS_PKG" ] || ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] Nessus package not found or invalid, downloading again...${NC}"
  
  # Use wget with proper headers to get a valid download
  echo -e "${YELLOW}[*] Downloading Nessus...${NC}"
  wget --content-disposition --header="Accept: application/x-debian-package" \
       --header="User-Agent: Mozilla/5.0 (X11; Linux x86_64)" \
       "$NESSUS_URL" -O "$NESSUS_PKG" || {
    echo -e "${RED}[-] Failed to download Nessus from Tenable's site.${NC}"
    
    # Try alternative approach - direct download from Tenable server
    echo -e "${YELLOW}[!] Trying alternative download approach...${NC}"
    wget --content-disposition "https://www.tenable.com/downloads/nessus?direct=true" -O "$NESSUS_PKG" || {
      echo -e "${RED}[-] All download attempts failed. Please download manually from Tenable's website.${NC}"
      exit 1
    }
  }
  
  # Verify the downloaded file is a valid Debian package
  if ! dpkg-deb --info "$NESSUS_PKG" >/dev/null 2>&1; then
    echo -e "${RED}[-] Downloaded file is not a valid Debian package.${NC}"
    echo -e "${YELLOW}[!] The downloaded file might be an HTML page or an error response.${NC}"
    echo -e "${YELLOW}[!] Please download Nessus manually from: https://www.tenable.com/downloads/nessus${NC}"
    exit 1
  fi
fi

# Install Nessus
echo -e "${YELLOW}[*] Installing Nessus...${NC}"
apt-get update
dpkg -i "$NESSUS_PKG" || {
  echo -e "${YELLOW}[!] Fixing dependencies...${NC}"
  apt-get -f install -y
  dpkg -i "$NESSUS_PKG" || {
    echo -e "${RED}[-] Failed to install Nessus${NC}"
    exit 1
  }
}

# Start and enable Nessus service
echo -e "${YELLOW}[*] Starting Nessus service...${NC}"
systemctl start nessusd
systemctl enable nessusd

# Create desktop entry
cat > /usr/share/applications/nessus.desktop << DESKTOP
[Desktop Entry]
Name=Nessus
Exec=xdg-open https://localhost:8834/
Type=Application
Icon=/opt/nessus/var/nessus/www/favicon.ico
Terminal=false
Categories=Security;
DESKTOP

# Check service status
if systemctl is-active --quiet nessusd; then
  echo -e "${GREEN}[+] Nessus installed and service started successfully${NC}"
  echo -e "${BLUE}[i] Access Nessus at: https://localhost:8834/${NC}"
  echo -e "${BLUE}[i] Complete setup by creating an account and activating your license${NC}"
else
  echo -e "${YELLOW}[!] Nessus installed but service not running. Try starting manually:${NC}"
  echo -e "${YELLOW}    systemctl start nessusd${NC}"
fi

exit 0
EOF
      ;;
      
    "teamviewer")
      cat > "$helper_script" << 'EOF'
#!/bin/bash
# TeamViewer Host Installer with advanced configuration and Kali Linux compatibility fixes

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/opt/security-tools/downloads/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN=""  # Your assignment token (optional)
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "Please run as root or with sudo"
  exit 1
fi

# Create directory if it doesn't exist
mkdir -p "$(dirname "$TV_PACKAGE")"

# Check if the DEB package exists
if [ ! -f "$TV_PACKAGE" ]; then
  log "WARNING" "TeamViewer Host package not found at $TV_PACKAGE"
  
  # Try to download it
  log "INFO" "Attempting to download TeamViewer Host..."
  wget -q --show-progress https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Install policykit-1 dependency for Kali Linux
if grep -q "Kali" /etc/os-release; then
  log "INFO" "Kali Linux detected, installing policykit-1 dependency..."
  
  # Direct installation of policykit-1
  apt-get update
  apt-get install -y policykit-1 || {
    log "WARNING" "Could not install policykit-1 from repositories"
    
    # Alternative way - install polkit instead (provides policykit-1)
    log "INFO" "Attempting to install polkit as an alternative..."
    apt-get install -y polkit
  }
  
  # Verify if policykit-1 or equivalent is installed
  if ! dpkg -l | grep -E 'policykit-1|polkit' | grep -q '^ii'; then
    log "WARNING" "Could not install required dependency. Creating manual override..."
    
    # Create directory for fake policykit-1 package
    mkdir -p /tmp/fake-policykit/DEBIAN
    
    # Creating a minimal debian package structure
    cat > /tmp/fake-policykit/DEBIAN/control << PKG
Package: policykit-1
Version: 1.0.0
Architecture: all
Maintainer: RTA Installer <rta@example.com>
Description: Dummy policykit-1 package for TeamViewer
Priority: optional
Section: admin
PKG
    
    # Build the package
    log "INFO" "Building dummy policykit-1 package..."
    dpkg-deb --build /tmp/fake-policykit /tmp/policykit-1_1.0.0_all.deb
    
    # Install the dummy package
    log "INFO" "Installing dummy policykit-1 package..."
    dpkg -i /tmp/policykit-1_1.0.0_all.deb || {
      log "ERROR" "Failed to install dummy policykit-1 package"
      rm -rf /tmp/fake-policykit /tmp/policykit-1_1.0.0_all.deb
      exit 1
    }
    
    rm -rf /tmp/fake-policykit /tmp/policykit-1_1.0.0_all.deb
  fi
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

# Make sure TeamViewer daemon is running
log "INFO" "Starting TeamViewer daemon..."
systemctl start teamviewerd || true
sleep 5

# Configure TeamViewer
if systemctl is-active --quiet teamviewerd; then
  log "SUCCESS" "TeamViewer Host installed and daemon is running"
  
  # Set a custom alias for this device
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  DEVICE_ALIAS="${ALIAS_PREFIX}${TIMESTAMP}"
  log "INFO" "Setting device alias to: $DEVICE_ALIAS"
  teamviewer alias "$DEVICE_ALIAS" || true
  
  # Assign to account if token provided
  if [ -n "$ASSIGNMENT_TOKEN" ]; then
    log "INFO" "Assigning device to your TeamViewer account..."
    teamviewer assignment --token "$ASSIGNMENT_TOKEN" || true
  fi
  
  # Configure for unattended access
  log "INFO" "Configuring for unattended access..."
  teamviewer setup --grant-easy-access || true
  
  # Create desktop entry
  cat > /usr/share/applications/teamviewer.desktop << DESKTOP
[Desktop Entry]
Name=TeamViewer
Comment=Remote Control Application
Exec=teamviewer
Icon=/opt/teamviewer/tv_bin/desktop/teamviewer.png
Terminal=false
Type=Application
Categories=Network;RemoteAccess;
DESKTOP
  
  # Display the TeamViewer ID
  TV_ID=$(teamviewer info 2>/dev/null | grep "TeamViewer ID:" | awk '{print $3}')
  if [ -n "$TV_ID" ]; then
    log "SUCCESS" "Configuration completed. TeamViewer ID: $TV_ID"
  else
    log "WARNING" "Could not retrieve TeamViewer ID"
  fi
else
  log "ERROR" "TeamViewer daemon is not running after installation"
  exit 1
fi

exit 0
EOF
      ;;
      
    "burpsuite_enterprise")
      cat > "$helper_script" << 'EOF'
#!/bin/bash
# Robust BurpSuite Enterprise installer with error handling and activation

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting Burp Suite Enterprise installation...${NC}"

# Create a temp directory for installation
TEMP_DIR=$(mktemp -d)
INSTALL_DIR="/opt/BurpSuiteEnterprise"
DOWNLOAD_DIR="/opt/security-tools/downloads"

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$INSTALL_DIR"

# Look for installer in common locations
BURP_INSTALLER=""
for location in "$DOWNLOAD_DIR" "$HOME/Desktop" "$HOME/Downloads"; do
  FOUND_INSTALLER=$(find "$location" -maxdepth 1 -name "burpsuite_enterprise_*.jar" -o -name "burpsuite_enterprise_*.sh" -o -name "burp_enterprise*.zip" | head -1)
  if [ -n "$FOUND_INSTALLER" ]; then
    BURP_INSTALLER="$FOUND_INSTALLER"
    break
  fi
done

if [ -z "$BURP_INSTALLER" ]; then
  echo -e "${YELLOW}[!] No Burp Suite Enterprise installer found.${NC}"
  echo -e "${YELLOW}[!] Please download the installer from PortSwigger and place it in:${NC}"
  echo -e "${YELLOW}    $DOWNLOAD_DIR${NC}"
  echo -e "${YELLOW}    or your Desktop/Downloads folder${NC}"
  
  read -p "Would you like to proceed with Burp Suite Professional instead? [y/N] " -n 1 -r
  echo
  
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}[-] Installation aborted${NC}"
    exit 1
  fi
  
  # Continue with Professional installation instead
  echo -e "${YELLOW}[*] Installing Burp Suite Professional instead...${NC}"
  
  # Ensure java is installed
  if ! command -v java &>/dev/null; then
    echo -e "${YELLOW}[*] Installing Java...${NC}"
    apt-get update
    apt-get install -y openjdk-17-jdk
  fi
  
  # Download Burp Suite Pro
  BURP_PRO_URL="https://portswigger-cdn.net/burp/releases/download?product=pro&version=2023.10.3.2&type=jar"
  echo -e "${YELLOW}[*] Downloading Burp Suite Professional...${NC}"
  mkdir -p "/opt/BurpSuitePro"
  wget -q --show-progress "$BURP_PRO_URL" -O "/opt/BurpSuitePro/burpsuite_pro.jar" || {
    echo -e "${RED}[-] Failed to download Burp Suite Professional${NC}"
    exit 1
  }
  
  chmod +x "/opt/BurpSuitePro/burpsuite_pro.jar"
  
  # Create executable wrapper
  echo -e "${YELLOW}[*] Creating executable wrapper...${NC}"
  cat > "/usr/bin/burpsuite" << 'WRAPPER'
#!/bin/bash
java -jar /opt/BurpSuitePro/burpsuite_pro.jar "$@"
WRAPPER
  chmod +x "/usr/bin/burpsuite"
  
  # Create desktop shortcut
  echo -e "${YELLOW}[*] Creating desktop shortcut...${NC}"
  cat > "/usr/share/applications/burpsuite_pro.desktop" << 'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Burp Suite Professional
Comment=Security Testing Tool
Exec=java -jar /opt/BurpSuitePro/burpsuite_pro.jar
Icon=burpsuite
Terminal=false
Categories=Development;Security;
DESKTOP
  
  echo -e "${GREEN}[+] Burp Suite Professional installed successfully!${NC}"
  echo -e "${BLUE}[i] You can run it with the command: burpsuite${NC}"
  echo -e "${BLUE}[i] Or find it in your application menu${NC}"
  echo -e "${YELLOW}[!] Note: You will need to activate the software on first run${NC}"
  
  exit 0
fi

# Process the found installer
echo -e "${YELLOW}[*] Found installer: $(basename "$BURP_INSTALLER")${NC}"

# Determine installer type and process accordingly
if [[ "$BURP_INSTALLER" == *.zip ]]; then
  echo -e "${YELLOW}[*] Extracting ZIP installer...${NC}"
  unzip -q "$BURP_INSTALLER" -d "$TEMP_DIR" || {
    echo -e "${RED}[-] Failed to extract ZIP installer${NC}"
    exit 1
  }
  
  # Look for actual installer in extracted content
  INSTALLER=$(find "$TEMP_DIR" -name "*.run" -o -name "*.jar" -o -name "*.sh" | head -1)
  
  if [ -z "$INSTALLER" ]; then
    echo -e "${RED}[-] Could not find installer in the ZIP file${NC}"
    exit 1
  fi
elif [[ "$BURP_INSTALLER" == *.jar ]]; then
  INSTALLER="$BURP_INSTALLER"
elif [[ "$BURP_INSTALLER" == *.run ]] || [[ "$BURP_INSTALLER" == *.sh ]]; then
  INSTALLER="$BURP_INSTALLER"
else
  echo -e "${RED}[-] Unsupported installer format: $(basename "$BURP_INSTALLER")${NC}"
  exit 1
fi

# Execute installer
echo -e "${YELLOW}[*] Running installer: $(basename "$INSTALLER")${NC}"
chmod +x "$INSTALLER"

if [[ "$INSTALLER" == *.jar ]]; then
  # For JAR installer
  java -jar "$INSTALLER" || {
    echo -e "${RED}[-] Failed to run JAR installer${NC}"
    exit 1
  }
else
  # For shell or run installer
  "$INSTALLER" || {
    echo -e "${RED}[-] Failed to run installer${NC}"
    exit 1
  }
fi

# Create symlink and desktop entry if needed
if [ -d "/opt/BurpSuiteEnterprise" ]; then
  # Enterprise installation location
  if [ -f "/opt/BurpSuiteEnterprise/burpsuite_enterprise" ]; then
    echo -e "${YELLOW}[*] Creating symlink and desktop shortcut...${NC}"
    ln -sf "/opt/BurpSuiteEnterprise/burpsuite_enterprise" "/usr/local/bin/burpsuite_enterprise"
    
    cat > "/usr/share/applications/burpsuite_enterprise.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Burp Suite Enterprise
Comment=Enterprise Security Testing
Exec=/opt/BurpSuiteEnterprise/burpsuite_enterprise
Type=Application
Icon=/opt/BurpSuiteEnterprise/burpsuite_enterprise.png
Terminal=false
Categories=Development;Security;
DESKTOP
  fi
elif [ -d "/opt/burp" ]; then
  # Alternative installation location
  if [ -f "/opt/burp/burpsuite_enterprise" ]; then
    echo -e "${YELLOW}[*] Creating symlink and desktop shortcut...${NC}"
    ln -sf "/opt/burp/burpsuite_enterprise" "/usr/local/bin/burpsuite_enterprise"
    
    cat > "/usr/share/applications/burpsuite_enterprise.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Burp Suite Enterprise
Comment=Enterprise Security Testing
Exec=/opt/burp/burpsuite_enterprise
Type=Application
Icon=/opt/burp/burpsuite_enterprise.png
Terminal=false
Categories=Development;Security;
DESKTOP
  fi
fi

# Clean up
rm -rf "$TEMP_DIR"

echo -e "${GREEN}[+] Burp Suite Enterprise installation completed!${NC}"
echo -e "${BLUE}[i] Please complete the setup through the web interface${NC}"
exit 0
EOF
      ;;
      
    "evilginx3")
      cat > "$helper_script" << 'EOF'
#!/bin/bash
# Evilginx3 installation helper with enhanced error handling and compatibility fixes

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting Evilginx3 installation...${NC}"

# Installation directory
INSTALL_DIR="/opt/evilginx3"
HOME_DIR="/home/$SUDO_USER"
LOG_FILE="/tmp/evilginx3_install.log"

# Helper functions
log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

# Ensure Go is installed and properly configured
install_golang() {
  log "${YELLOW}[*] Installing/updating Golang...${NC}"
  
  # Install golang from repositories
  apt-get update
  apt-get install -y golang
  
  # Check if installation was successful
  if ! command -v go &>/dev/null; then
    log "${RED}[-] Failed to install Golang from repositories, trying direct installation...${NC}"
    
    # Try direct installation
    GO_VERSION="1.19.5"
    wget "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    
    if [ -f "/tmp/go.tar.gz" ]; then
      rm -rf /usr/local/go
      tar -C /usr/local -xzf /tmp/go.tar.gz
      rm /tmp/go.tar.gz
      
      # Add to PATH if not already there
      if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" ~/.bashrc; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
      fi
      
      export PATH=$PATH:/usr/local/go/bin
    else
      log "${RED}[-] Failed to download Golang${NC}"
      return 1
    fi
    
    # Check again
    if ! command -v go &>/dev/null; then
      log "${RED}[-] Golang installation failed${NC}"
      return 1
    fi
  fi
  
  log "${GREEN}[+] Golang installed successfully:${NC} $(go version)"
  return 0
}

# Install dependencies
install_dependencies() {
  log "${YELLOW}[*] Installing dependencies...${NC}"
  
  apt-get update
  apt-get install -y git make gcc g++ pkg-config openssl libcap2-bin
  
  if [ $? -ne 0 ]; then
    log "${RED}[-] Failed to install dependencies${NC}"
    return 1
  fi
  
  log "${GREEN}[+] Dependencies installed successfully${NC}"
  return 0
}

# Clone and build evilginx3
install_evilginx() {
  log "${YELLOW}[*] Cloning and building Evilginx3...${NC}"
  
  # Clone repository
  if [ -d "$INSTALL_DIR" ]; then
    log "${YELLOW}[!] Evilginx3 directory already exists, updating...${NC}"
    cd "$INSTALL_DIR"
    git pull
  else
    log "${YELLOW}[*] Cloning Evilginx3 repository...${NC}"
    git clone https://github.com/kgretzky/evilginx2 "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
      # Try alternative repository
      log "${YELLOW}[!] Failed to clone from primary repository, trying alternative...${NC}"
      git clone https://github.com/kingsmandralph/evilginx3 "$INSTALL_DIR"
      if [ $? -ne 0 ]; then
        log "${RED}[-] Failed to clone Evilginx3 repository${NC}"
        return 1
      fi
    fi
    cd "$INSTALL_DIR"
  fi
  
  # Build the project
  log "${YELLOW}[*] Building Evilginx3...${NC}"
  make
  
  if [ $? -ne 0 ]; then
    log "${RED}[-] Failed to build Evilginx3${NC}"
    return 1
  fi
  
  # Set capabilities for binding to privileged ports
  log "${YELLOW}[*] Setting capabilities...${NC}"
  setcap cap_net_bind_service=+ep "$INSTALL_DIR/evilginx"
  
  # Create symlink
  ln -sf "$INSTALL_DIR/evilginx" "/usr/local/bin/evilginx"
  
  log "${GREEN}[+] Evilginx3 built and installed successfully${NC}"
  return 0
}

# Create desktop shortcut
create_desktop_shortcut() {
  log "${YELLOW}[*] Creating desktop shortcut...${NC}"
  
  cat > "/usr/share/applications/evilginx3.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Evilginx3
Comment=Man-in-the-middle attack framework
Exec=x-terminal-emulator -e "bash -c 'sudo evilginx; exec bash'"
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Security;Network;
DESKTOP
  
  log "${GREEN}[+] Desktop shortcut created${NC}"
  return 0
}

# Main installation process
main() {
  log "${BLUE}[i] Evilginx3 Installation Script${NC}"
  log "${BLUE}[i] ------------------------------${NC}"
  
  # Check if running as root
  if [ "$EUID" -ne 0 ]; then
    log "${RED}[-] Please run as root${NC}"
    exit 1
  fi
  
  # Create log file
  touch "$LOG_FILE"
  
  # Install Go
  install_golang || {
    log "${RED}[-] Golang installation failed, cannot continue${NC}"
    exit 1
  }
  
  # Install dependencies
  install_dependencies || {
    log "${RED}[-] Failed to install dependencies, cannot continue${NC}"
    exit 1
  }
  
  # Install evilginx3
  install_evilginx || {
    log "${RED}[-] Evilginx3 installation failed${NC}"
    exit 1
  }
  
  # Create desktop shortcut
  create_desktop_shortcut
  
  log "${GREEN}[+] Evilginx3 installation completed successfully!${NC}"
  log "${BLUE}[i] You can now run Evilginx3 using the command:${NC} sudo evilginx"
  log "${BLUE}[i] Installation log available at:${NC} $LOG_FILE"
  
  return 0
}

# Run main function
main
exit $?
EOF
      ;;
      
    "gophish")
      cat > "$helper_script" << 'EOF'
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
  
  # Modify config to listen on all interfaces (optional, safer to leave on localhost)
  # sed -i 's/"listen_url" : "127.0.0.1:3333"/"listen_url" : "0.0.0.0:3333"/g' "$INSTALL_DIR/config.json"
  
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
  log "${YELLOW}[*] Creating desktop shortcut...${NC}"
  
  cat > "/usr/share/applications/gophish.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Gophish
Comment=Open-Source Phishing Toolkit
Exec=xdg-open http://127.0.0.1:3333/
Type=Application
Icon=web-browser
Terminal=false
Categories=Security;Network;
DESKTOP
  
  # Also create an admin launcher for the service
  cat > "/usr/share/applications/gophish-admin.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Gophish Admin
Comment=Start/Stop Gophish Service
Exec=x-terminal-emulator -e "bash -c 'echo \"Gophish Service Control\"; echo \"-------------------\"; echo \"1) Start Gophish\"; echo \"2) Stop Gophish\"; echo \"3) Restart Gophish\"; echo \"4) Check Status\"; echo; read -p \"Select option: \" opt; case $opt in 1) sudo systemctl start gophish;; 2) sudo systemctl stop gophish;; 3) sudo systemctl restart gophish;; 4) sudo systemctl status gophish;; *) echo \"Invalid option\";; esac; echo; echo \"Press Enter to exit\"; read'"
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Security;Network;
DESKTOP
  
  log "${GREEN}[+] Desktop shortcuts created${NC}"
  return 0
}

# Create CLI wrapper
create_cli_wrapper() {
  log "${YELLOW}[*] Creating CLI wrapper...${NC}"
  
  cat > "/usr/local/bin/gophish" << 'WRAPPER'
#!/bin/bash
# Gophish CLI wrapper

case "$1" in
  "start")
    sudo systemctl start gophish
    echo "Gophish started. Access the admin interface at: http://127.0.0.1:3333/"
    ;;
  "stop")
    sudo systemctl stop gophish
    echo "Gophish stopped."
    ;;
  "restart")
    sudo systemctl restart gophish
    echo "Gophish restarted. Access the admin interface at: http://127.0.0.1:3333/"
    ;;
  "status")
    sudo systemctl status gophish
    ;;
  *)
    echo "Gophish CLI Wrapper"
    echo "Usage: gophish [start|stop|restart|status]"
    echo ""
    echo "Admin interface: http://127.0.0.1:3333/"
    echo "Default credentials: admin:gophish"
    echo ""
    echo "Note: On first login, you'll be prompted to change the default password."
    ;;
esac
WRAPPER
  
  chmod +x "/usr/local/bin/gophish"
  
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
  
  # Start service
  start_service
  
  log "${GREEN}[+] Gophish installation completed successfully!${NC}"
  log "${BLUE}[i] Access the admin interface at:${NC} http://127.0.0.1:3333/"
  log "${BLUE}[i] Default credentials:${NC} admin:gophish"
  log "${BLUE}[i] Note: On first login, you'll be prompted to change the default password.${NC}"
  log "${BLUE}[i] Use 'gophish' command to control the service.${NC}"
  
  return 0
}

# Run main function
main
exit $?
EOF
      ;;
      
    "bfg")
      cat > "$helper_script" << 'EOF'
#!/bin/bash
# BFG Repo Cleaner Installation Script

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Installing BFG Repo Cleaner...${NC}"

# Installation paths
INSTALL_DIR="/opt/security-tools"
BIN_DIR="/usr/local/bin"
BFG_VERSION="1.14.0"
BFG_URL="https://repo1.maven.org/maven2/com/madgag/bfg/$BFG_VERSION/bfg-$BFG_VERSION.jar"
BFG_JAR="$INSTALL_DIR/bfg-$BFG_VERSION.jar"

# Ensure Java is installed
if ! command -v java &>/dev/null; then
  echo -e "${YELLOW}[*] Java not found, installing...${NC}"
  apt-get update
  apt-get install -y default-jre || {
    echo -e "${RED}[-] Failed to install Java${NC}"
    exit 1
  }
fi

# Create installation directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Download BFG
echo -e "${YELLOW}[*] Downloading BFG Repo Cleaner v$BFG_VERSION...${NC}"
wget -q --show-progress "$BFG_URL" -O "$BFG_JAR" || {
  echo -e "${RED}[-] Failed to download BFG Repo Cleaner${NC}"
  exit 1
}

# Create wrapper script
echo -e "${YELLOW}[*] Creating wrapper script...${NC}"
cat > "$BIN_DIR/bfg" << EOF
#!/bin/bash
java -jar $BFG_JAR "\$@"
EOF

# Make wrapper executable
chmod +x "$BIN_DIR/bfg"

# Create desktop shortcut
echo -e "${YELLOW}[*] Creating desktop shortcut...${NC}"
mkdir -p "/usr/share/applications"
cat > "/usr/share/applications/bfg.desktop" << EOF
[Desktop Entry]
Name=BFG Repo Cleaner
Comment=Removes large or troublesome blobs from Git repository history
Exec=x-terminal-emulator -e "bfg --help"
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Development;Utility;
EOF

# Verify installation
if command -v bfg &>/dev/null; then
  echo -e "${GREEN}[+] BFG Repo Cleaner installed successfully!${NC}"
  echo -e "${BLUE}[i] Usage: bfg [options] <repo.git>${NC}"
else
  echo -e "${RED}[-] Installation verification failed${NC}"
  echo -e "${YELLOW}[!] Manual usage: java -jar $BFG_JAR [options] <repo.git>${NC}"
fi

exit 0
EOF
      ;;
      
    *)
      # Generic helper script for other tools
      cat > "$helper_script" << EOF
#!/bin/bash
# Installation Helper for $tool_name

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[i] $tool_name Installation Helper${NC}"
echo -e "${BLUE}[i] =========================${NC}"
echo ""
echo -e "${YELLOW}[!] This tool requires manual installation.${NC}"
echo ""
echo -e "${BLUE}[i] Please follow these steps:${NC}"
echo "1. Download $tool_name from the official website"
echo "2. Follow the installation instructions provided by the vendor"
echo "3. For assistance, refer to the documentation or community forums"
echo ""
echo -e "${BLUE}[i] After installation, you may need to:${NC}"
echo "- Create desktop shortcuts"
echo "- Configure environment variables"
echo "- Set up required services"
echo ""
echo -e "${YELLOW}[!] If you encounter issues, check the log files in:${NC}"
echo "   /opt/security-tools/logs"
echo ""
echo -e "${BLUE}[i] For more information, visit:${NC}"
echo "   https://example.com/$tool_name"
echo ""
EOF
      ;;
  esac
  
  # Make the script executable
  chmod +x "$helper_script"
  
  log "SUCCESS" "Created installation helper for $tool_name at $helper_script"
  return 0
}

# Function to initialize installation report
initialize_report() {
  log "STATUS" "Initializing installation report..."
  
  # Create report header
  cat > "$REPORT_FILE" << EOF
====================================================================
                SECURITY TOOLS INSTALLATION REPORT
====================================================================
Date: $(date)
System: $(hostname) - $(uname -r)
Kali Version: $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Unknown")

EOF
  
  return 0
}

# Function to disable screen lock and power saving
disable_screen_lock() {
  log "STATUS" "Disabling screen lock and power saving features..."
  
  # Detect desktop environment
  local desktop_env=""
  if [ -n "$XDG_CURRENT_DESKTOP" ]; then
    desktop_env="$XDG_CURRENT_DESKTOP"
  elif [ -n "$DESKTOP_SESSION" ]; then
    desktop_env="$DESKTOP_SESSION"
  elif pgrep -x "gnome-shell" > /dev/null; then
    desktop_env="GNOME"
  elif pgrep -x "xfce4-session" > /dev/null; then
    desktop_env="XFCE"
  elif pgrep -x "kwin" > /dev/null; then
    desktop_env="KDE"
  else
    desktop_env="Unknown"
  fi
  
  log "DEBUG" "Detected desktop environment: $desktop_env"
  
  # Create generic script to disable screen lock
  cat > "$SCRIPTS_DIR/disable-lock-screen.sh" << 'EOF'
#!/usr/bin/env bash
# Comprehensive script to disable screen lock and power management features

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Disabling screen lock and power management...${NC}"

# Detect desktop environment
if [ -n "$XDG_CURRENT_DESKTOP" ]; then
  DE=$XDG_CURRENT_DESKTOP
elif [ -n "$DESKTOP_SESSION" ]; then
  DE=$DESKTOP_SESSION
else
  # Try to detect based on running processes
  if pgrep -x "gnome-shell" > /dev/null; then
    DE="GNOME"
  elif pgrep -x "xfce4-session" > /dev/null; then
    DE="XFCE"
  elif pgrep -x "kwin" > /dev/null; then
    DE="KDE"
  else
    DE="UNKNOWN"
  fi
fi

echo -e "${BLUE}[i] Detected desktop environment: $DE${NC}"

# GNOME settings
if [[ "$DE" == *"GNOME"* ]]; then
  echo -e "${YELLOW}[*] Configuring GNOME settings...${NC}"
  
  # Disable screen lock
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
  gsettings set org.gnome.desktop.lockdown disable-lock-screen true 2>/dev/null
  
  # Disable screen blank
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
  
  # Disable auto-activation of screensaver
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
  
  # Disable lock on suspend
  gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null
  
  # Disable power management features
  gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null
  
  echo -e "${GREEN}[+] GNOME screen lock and power management disabled${NC}"
fi

# XFCE settings
if [[ "$DE" == *"XFCE"* ]]; then
  echo -e "${YELLOW}[*] Configuring XFCE settings...${NC}"
  
  # Disable XFCE screensaver
  xfconf-query -c xfce4-screensaver -p /screensaver/enabled -s false 2>/dev/null
  xfconf-query -c xfce4-screensaver -p /screensaver/lock/enabled -s false 2>/dev/null
  
  # Disable XFCE power management
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-off -s 0 2>/dev/null
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-sleep -s 0 2>/dev/null
  
  echo -e "${GREEN}[+] XFCE screen lock and power management disabled${NC}"
fi

# KDE settings
if [[ "$DE" == *"KDE"* ]]; then
  echo -e "${YELLOW}[*] Configuring KDE settings...${NC}"
  
  # Disable KDE screen locking
  kwriteconfig5 --file kscreenlockerrc --group Daemon --key Autolock false
  kwriteconfig5 --file kscreenlockerrc --group Daemon --key LockOnResume false
  
  # Disable KDE screen energy saving
  kwriteconfig5 --file kwinrc --group Compositing --key SuspendWhenInvisible false
  
  echo -e "${GREEN}[+] KDE screen lock and power management disabled${NC}"
fi

# Light Locker (common on XFCE)
if command -v light-locker-command &> /dev/null; then
  echo -e "${YELLOW}[*] Disabling Light Locker...${NC}"
  
  # Kill any running instances
  pkill light-locker 2>/dev/null
  
  # Disable the service
  if [ -f "/etc/xdg/autostart/light-locker.desktop" ]; then
    echo -e "${YELLOW}[*] Disabling Light Locker autostart...${NC}"
    mkdir -p ~/.config/autostart
    cp /etc/xdg/autostart/light-locker.desktop ~/.config/autostart/
    echo "Hidden=true" >> ~/.config/autostart/light-locker.desktop
  fi
  
  # System-wide disable
  if [ -f "/usr/bin/light-locker" ]; then
    echo -e "${YELLOW}[*] Disabling Light Locker system-wide...${NC}"
    mv /usr/bin/light-locker /usr/bin/light-locker.disabled
  fi
  
  echo -e "${GREEN}[+] Light Locker disabled${NC}"
fi

# X11 settings (works on any X11-based environment)
echo -e "${YELLOW}[*] Configuring X11 settings...${NC}"

# Disable screen blanking and DPMS
xset s off
xset s noblank
xset -dpms

# Create autostart entry to ensure settings persist
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/disable-screen-lock.desktop << EOF
[Desktop Entry]
Type=Application
Name=Disable Screen Lock
Comment=Disables screen locking and power management
Exec=bash -c "xset s off; xset s noblank; xset -dpms"
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

echo -e "${GREEN}[+] X11 screen blanking and DPMS disabled${NC}"

# Remove screensaver packages if present
echo -e "${YELLOW}[*] Checking for screensaver packages...${NC}"

# Check if gnome-screensaver is installed
if dpkg -l | grep -q gnome-screensaver; then
  echo -e "${YELLOW}[*] Removing gnome-screensaver...${NC}"
  apt-get remove -y gnome-screensaver
  echo -e "${GREEN}[+] gnome-screensaver removed${NC}"
fi

# Check if xscreensaver is installed
if dpkg -l | grep -q xscreensaver; then
  echo -e "${YELLOW}[*] Removing xscreensaver...${NC}"
  apt-get remove -y xscreensaver
  echo -e "${GREEN}[+] xscreensaver removed${NC}"
fi

# Check if light-locker is installed
if dpkg -l | grep -q light-locker; then
  echo -e "${YELLOW}[*] Removing light-locker...${NC}"
  apt-get remove -y light-locker
  echo -e "${GREEN}[+] light-locker removed${NC}"
fi

echo -e "${GREEN}[+] Screen lock and power management successfully disabled${NC}"
echo -e "${BLUE}[i] Note: A reboot is recommended to ensure all changes take effect${NC}"

exit 0
EOF
  
  # Make script executable
  chmod +x "$SCRIPTS_DIR/disable-lock-screen.sh"
  
  # Execute the script
  if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    log "INFO" "Running disable screen lock script..."
    "$SCRIPTS_DIR/disable-lock-screen.sh" || log "WARNING" "Failed to disable screen lock"
  else
    log "INFO" "No display detected, skipping screen lock disabling"
  fi
  
  log "SUCCESS" "Screen lock settings configured"
  return 0
}

# Function to install desktop shortcuts for web tools
install_web_shortcuts() {
  log "STATUS" "Creating desktop shortcuts for web tools..."
  
  # Create desktop shortcuts directory if it doesn't exist
  mkdir -p "/usr/share/applications"
  
  # Common web tools
  local web_tools=(
    "VirusTotal|https://www.virustotal.com/gui/home/search|web-browser|Security;Network;"
    "ExploitDB|https://www.exploit-db.com|web-browser|Security;Development;"
    "MITRE ATT&CK|https://attack.mitre.org|web-browser|Security;Documentation;"
    "CVE Details|https://cvedetails.com|web-browser|Security;Documentation;"
    "HaveIBeenPwned|https://haveibeenpwned.com|web-browser|Security;Network;"
    "OSINT Framework|https://osintframework.com|web-browser|Security;Network;"
    "Shodan|https://www.shodan.io|web-browser|Security;Network;"
    "Fast People Search|https://www.fastpeoplesearch.com/name|web-browser|Security;Network;"
  )
  
  # Create shortcuts
  for tool in "${web_tools[@]}"; do
    IFS='|' read -r name url icon categories <<< "$tool"
    
    cat > "/usr/share/applications/${name// /_}.desktop" << EOF
[Desktop Entry]
Name=$name
Comment=Web-based security tool
Exec=xdg-open $url
Type=Application
Icon=$icon
Terminal=false
Categories=$categories
EOF
    
    log "DEBUG" "Created web shortcut for $name"
  done
  
  log "SUCCESS" "Web shortcuts created successfully"
  return 0
}

# Function to setup bash aliases
setup_bash_aliases() {
  log "STATUS" "Setting up bash aliases..."
  
  # Create aliases file
  cat > "$TOOLS_DIR/bash_aliases" << 'EOF'
# RTA Security Tools Aliases
alias ll='ls -la'
alias update='sudo apt update && sudo apt upgrade -y'
alias tools-dir='cd /opt/security-tools'

# Network tools aliases
alias myip='curl -s https://ifconfig.me'
alias ports='netstat -tulanp'
alias scan='sudo nmap -sS -p-'
alias fastscan='sudo nmap -sS -F'
alias proxychains='proxychains4'

# Metasploit aliases
alias msfconsole='sudo msfconsole'
alias msfvenom='sudo msfvenom'

# Tool shortcuts
alias validate-tools='sudo /opt/security-tools/scripts/validate-tools.sh'
alias fix-tools='sudo /opt/security-tools/scripts/validate-tools.sh --fix-failed'

# Update function for RTA tools
rta-update() {
  echo "Updating RTA tools..."
  sudo /opt/rta-deployment/deploy-rta.sh --no-downloads
}

# Helper function to install a tool by name
install-tool() {
  if [ -z "$1" ]; then
    echo "Usage: install-tool <tool-name>"
    echo "Available helpers:"
    ls -1 /opt/security-tools/helpers/install_*.sh | sed 's/.*install_\(.*\)\.sh/\1/'
    return 1
  fi
  
  local tool="$1"
  local helper="/opt/security-tools/helpers/install_${tool}.sh"
  
  if [ -f "$helper" ]; then
    echo "Installing $tool..."
    sudo "$helper"
  else
    echo "No installation helper found for $tool"
    echo "Available helpers:"
    ls -1 /opt/security-tools/helpers/install_*.sh | sed 's/.*install_\(.*\)\.sh/\1/'
  fi
}
EOF
  
  # Add to system-wide bash aliases
  cp "$TOOLS_DIR/bash_aliases" "/etc/skel/.bash_aliases"
  
  # If sudo user exists, add to their home directory too
  if [ -n "$SUDO_USER" ] && [ -d "/home/$SUDO_USER" ]; then
    cp "$TOOLS_DIR/bash_aliases" "/home/$SUDO_USER/.bash_aliases"
    chown "$SUDO_USER:$SUDO_USER" "/home/$SUDO_USER/.bash_aliases"
    
    # Add source line to bashrc if not already there
    if ! grep -q "source ~/.bash_aliases" "/home/$SUDO_USER/.bashrc"; then
      echo -e "\n# Load security tools aliases\nif [ -f ~/.bash_aliases ]; then\n    source ~/.bash_aliases\nfi" >> "/home/$SUDO_USER/.bashrc"
      log "DEBUG" "Added source line to user's bashrc"
    fi
  fi
  
  # Add to root's home directory too
  cp "$TOOLS_DIR/bash_aliases" "/root/.bash_aliases"
  
  # Add source line to root's bashrc if not already there
  if ! grep -q "source ~/.bash_aliases" "/root/.bashrc"; then
    echo -e "\n# Load security tools aliases\nif [ -f ~/.bash_aliases ]; then\n    source ~/.bash_aliases\nfi" >> "/root/.bashrc"
    log "DEBUG" "Added source line to root's bashrc"
  fi
  
  log "SUCCESS" "Bash aliases set up successfully"
  return 0
}

# Function to create validation script
create_validation_script() {
  log "STATUS" "Creating validation script..."
  
  # Check if script already exists
  if [ -f "$SCRIPTS_DIR/validate-tools.sh" ] && ! $FORCE_REINSTALL; then
    log "INFO" "Validation script already exists, skipping creation"
    return 0
  }
  
  # Create script
  cat > "$SCRIPTS_DIR/validate-tools.sh" << 'EOFSCRIPT'
#!/bin/bash
# =================================================================
# RTA Tools Validation Script v3.0
# =================================================================
# Comprehensive validation of security tools with detailed reporting
# =================================================================

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Directories
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$TOOLS_DIR/logs"
VALIDATION_LOG="$LOG_DIR/tool_validation_$(date +%Y%m%d_%H%M%S).log"
VALIDATION_REPORT="$LOG_DIR/tool_validation_report_$(date +%Y%m%d_%H%M%S).txt"
CONFIG_FILE="/opt/security-tools/config/config.yml"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Initialize log file
echo "Tool Validation Report" > "$VALIDATION_LOG"
echo "====================" >> "$VALIDATION_LOG"
echo "Date: $(date)" >> "$VALIDATION_LOG"
echo "" >> "$VALIDATION_LOG"

# Initialize report file with nice formatting
cat > "$VALIDATION_REPORT" << REPORT_EOF
=================================================================
               SECURITY TOOLS VALIDATION REPORT
=================================================================
Date: $(date)
System: $(hostname) - $(uname -r)
Kali Version: $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Unknown")

REPORT_EOF

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Function to display usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --essential-only    Only check essential security tools
  --apt-only          Only check apt-installed tools
  --pipx-only         Only check pipx-installed tools
  --git-only          Only check git-installed tools
  --verbose           Show more detailed output
  --fix-failed        Attempt to reinstall failed tools
  --export-html       Export results as HTML report
  --help              Display this help message and exit
EOF
}

# Parse command line arguments
ESSENTIAL_ONLY=false
APT_ONLY=false
PIPX_ONLY=false
GIT_ONLY=false
VERBOSE=false
FIX_FAILED=false
EXPORT_HTML=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --essential-only)
            ESSENTIAL_ONLY=true
            shift
            ;;
        --apt-only)
            APT_ONLY=true
            shift
            ;;
        --pipx-only)
            PIPX_ONLY=true
            shift
            ;;
        --git-only)
            GIT_ONLY=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --fix-failed)
            FIX_FAILED=true
            shift
            ;;
        --export-html)
            EXPORT_HTML=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

echo -e "${BOLD}${YELLOW}=== RTA Security Tools Validation ===${NC}"
echo -e "${BLUE}This script will verify that security tools are correctly installed and accessible.${NC}"
echo -e "${BLUE}Results will be saved to: ${VALIDATION_REPORT}${NC}\n"

# Validation tracking
declare -A VALIDATION_RESULTS
declare -A VALIDATION_DETAILS

# Initialize results
success_count=0
failure_count=0
warning_count=0
total_tools=0
start_time=$(date +%s)

# Read tool lists from config file if it exists
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}[i] Reading tool configuration from $CONFIG_FILE${NC}"
    APT_TOOLS_LIST=$(grep -E "^apt_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    PIPX_TOOLS_LIST=$(grep -E "^pipx_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    GIT_TOOLS_LIST=$(grep -E "^git_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    MANUAL_TOOLS_LIST=$(grep -E "^manual_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
else
    echo -e "${YELLOW}[!] Configuration file not found, using default tool list${NC}"
fi

# Categories of tools to check
declare -A APT_TOOLS=(
    ["nmap"]="nmap -V | grep 'Nmap version'"
    ["wireshark"]="wireshark --version | grep 'Wireshark'"
    ["metasploit"]="msfconsole -v | grep 'Framework'"
    ["sqlmap"]="sqlmap --version | grep 'sqlmap'"
    ["hydra"]="hydra -h | grep 'Hydra'"
    ["responder"]="responder -h | grep 'NBT-NS/LLMNR'"
    ["bettercap"]="bettercap -v | grep 'bettercap v'"
    ["crackmapexec"]="crackmapexec -h | grep 'CrackMapExec'"
    ["nikto"]="nikto -Version | grep 'Nikto v'"
    ["aircrack-ng"]="aircrack-ng --help | grep 'Aircrack-ng'"
    ["john"]="john --version | grep 'John the Ripper'"
    ["hashcat"]="hashcat -V | grep 'hashcat v'"
    ["wpscan"]="wpscan --version | grep 'WPScan v'"
    ["enum4linux"]="enum4linux -h | grep 'Enum4linux'"
    ["proxychains"]="proxychains4 -h 2>&1 | grep 'ProxyChains'"
    ["gobuster"]="gobuster -h | grep 'gobuster'"
    ["ffuf"]="ffuf -V | grep 'ffuf v'"
    ["dirsearch"]="dirsearch -h | grep 'dirsearch'"
    ["exploitdb"]="searchsploit -h | grep 'Exploit Database'"
    ["binwalk"]="binwalk -h | grep 'Binwalk v'"
    ["foremost"]="foremost -V | grep 'foremost version'"
    ["exiftool"]="exiftool -ver | grep '^[0-9]'"
    ["steghide"]="steghide --version | grep 'steghide '"
    ["terminator"]="terminator --version | grep 'terminator'"
)

declare -A PIPX_TOOLS=(
    ["scoutsuite"]="scout --version 2>&1 | grep 'Scout Suite'"
    ["impacket"]="impacket-samrdump --help 2>&1 | grep 'impacket v'"
    ["pymeta"]="pymeta -h | grep 'pymeta v'"
    ["wfuzz"]="wfuzz -h | grep 'Wfuzz'"
    ["trufflehog"]="trufflehog --help | grep 'trufflehog'"
    ["nuclei"]="nuclei -version | grep 'nuclei'"
    ["evil-winrm"]="evil-winrm --version | grep 'Evil-WinRM'"
    ["hakrawler"]="hakrawler -h | grep 'hakrawler'"
    ["sublist3r"]="sublist3r -h | grep 'Sublist3r'"
    ["commix"]="commix --version | grep 'commix'"
    ["recon-ng"]="recon-ng -h | grep 'recon-ng'"
)

declare -A GIT_TOOLS=(
    ["prowler"]="prowler --version 2>&1 | grep 'Prowler'"
    ["parsuite"]="parsuite -h 2>&1 | grep 'ParSuite'"
    ["evilginx3"]="evilginx -h 2>&1 | grep -i 'evilginx'"
    ["evilgophish"]="ls -la /opt/security-tools/evilgophish 2>&1 | grep -i 'evilgophish'"
    ["payloadsallthethings"]="ls -la /opt/security-tools/PayloadsAllTheThings 2>&1 | grep -i 'payloads'"
    ["seclists"]="ls -la /opt/security-tools/SecLists 2>&1 | grep -i 'seclists'"
    ["kali-anonsurf"]="anonsurf --help 2>&1 | grep -i 'anonsurf'"
    ["inveigh"]="inveigh -h 2>&1 | grep -i 'inveigh'"
    ["xsstrike"]="ls -la /opt/security-tools/XSStrike 2>&1 | grep -i 'xsstrike'"
    ["gittools"]="ls -la /opt/security-tools/GitTools 2>&1 | grep -i 'gittools'"
    ["gophish"]="ls -la /opt/gophish/gophish 2>&1 | grep -i 'gophish'"
    ["cyberchef"]="ls -la /opt/security-tools/CyberChef 2>&1 | grep -i 'cyberchef'"
)

declare -A ESSENTIAL_TOOLS=(
    ["nmap"]="nmap -V | grep 'Nmap version'"
    ["wireshark"]="wireshark --version | grep 'Wireshark'"
    ["metasploit"]="msfconsole -v | grep 'Framework'"
    ["sqlmap"]="sqlmap --version | grep 'sqlmap'"
    ["hydra"]="hydra -h | grep 'Hydra'"
    ["responder"]="responder -h | grep 'NBT-NS/LLMNR'"
    ["crackmapexec"]="crackmapexec -h | grep 'CrackMapExec'"
    ["john"]="john --version | grep 'John the Ripper'"
    ["hashcat"]="hashcat -V | grep 'hashcat v'"
    ["impacket"]="impacket-samrdump --help 2>&1 | grep 'impacket v'"
    ["proxychains"]="proxychains4 -h 2>&1 | grep 'ProxyChains'"
    ["bettercap"]="bettercap -v | grep 'bettercap v'"
    ["terminator"]="terminator --version | grep 'terminator'"
)

declare -A MANUAL_TOOLS=(
    ["teamviewer"]="teamviewer --help 2>&1 | grep -i 'teamviewer'"
    ["bfg"]="bfg --version 2>&1 | grep -i 'BFG'"
    ["nessus"]="systemctl status nessusd 2>&1 | grep 'nessusd'"
    ["burpsuite"]="burpsuite --help 2>&1 | grep -i 'Burp Suite'"
    ["ninjaone"]="systemctl status ninjarmm-agent 2>&1 | grep 'ninjarmm-agent'"
)

# Add any tools from config file that aren't already in our arrays
if [ -n "$APT_TOOLS_LIST" ]; then
    IFS=',' read -ra APT_ARRAY <<< "$APT_TOOLS_LIST"
    for tool in "${APT_ARRAY[@]}"; do
        tool=$(echo "$tool" | tr -d ' ')
        if [[ -n "$tool" ]] && [[ -z "${APT_TOOLS[$tool]}" ]]; then
            APT_TOOLS["$tool"]="which $tool 2>&1 | grep -v 'no $tool'"
        fi
    done
fi

if [ -n "$PIPX_TOOLS_LIST" ]; then
    IFS=',' read -ra PIPX_ARRAY <<< "$PIPX_TOOLS_LIST"
    for tool in "${PIPX_ARRAY[@]}"; do
        tool=$(echo "$tool" | tr -d ' ')
        if [[ -n "$tool" ]] && [[ -z "${PIPX_TOOLS[$tool]}" ]]; then
            PIPX_TOOLS["$tool"]="which $tool 2>&1 | grep -v 'no $tool'"
        fi
    done
fi

if [ -n "$GIT_TOOLS_LIST" ]; then
    IFS=',' read -ra GIT_ARRAY <<< "$GIT_TOOLS_LIST"
    for tool_url in "${GIT_ARRAY[@]}"; do
        # Extract repo name from URL
        tool=$(basename "$tool_url" .git | tr -d ' ')
        if [[ -n "$tool" ]] && [[ -z "${GIT_TOOLS[$tool]}" ]]; then
            GIT_TOOLS["$tool"]="ls -la $TOOLS_DIR/$tool 2>&1 | grep -i '$tool'"
        fi
    done
fi

if [ -n "$MANUAL_TOOLS_LIST" ]; then
    IFS=',' read -ra MANUAL_ARRAY <<< "$MANUAL_TOOLS_LIST"
    for tool in "${MANUAL_ARRAY[@]}"; do
        tool=$(echo "$tool" | tr -d ' ')
        if [[ -n "$tool" ]] && [[ -z "${MANUAL_TOOLS[$tool]}" ]]; then
            MANUAL_TOOLS["$tool"]="which $tool 2>&1 | grep -v 'no $tool' || ls -la $TOOLS_DIR/$tool 2>&1 | grep -i '$tool'"
        fi
    done
fi

# Function to validate a tool
validate_tool() {
    local tool_name=$1
    local validation_command=$2
    local category=$3
    
    ((total_tools++))
    
    if $VERBOSE; then
        echo -e "${YELLOW}[*] Checking $tool_name...${NC}"
    fi
    echo "[CHECKING] $tool_name" >> "$VALIDATION_LOG"
    
    # Try to execute the validation command
    if eval "$validation_command" &>/dev/null; then
        echo -e "${GREEN}[+] $tool_name is correctly installed and accessible${NC}"
        echo "[SUCCESS] $tool_name: Installed and accessible" >> "$VALIDATION_LOG"
        VALIDATION_RESULTS["$tool_name"]="SUCCESS"
        VALIDATION_DETAILS["$tool_name"]="Installed and accessible"
        ((success_count++))
        return 0
    else
        # Check if the command exists but fails validation
        local tool_cmd=$(echo "$validation_command" | awk '{print $1}')
        if command -v "$tool_cmd" &>/dev/null; then
            echo -e "${YELLOW}[!] $tool_name exists but validation failed${NC}"
            echo "[WARNING] $tool_name: Command exists but validation failed" >> "$VALIDATION_LOG"
            VALIDATION_RESULTS["$tool_name"]="WARNING"
            VALIDATION_DETAILS["$tool_name"]="Command exists but validation failed"
            ((warning_count++))
            return 1
        else
            # Check if there's a file path in the validation command
            if [[ "$validation_command" == *"ls -la"* ]]; then
                local file_path=$(echo "$validation_command" | awk '{print $3}')
                if [ -e "$file_path" ]; then
                    echo -e "${GREEN}[+] $tool_name directory exists${NC}"
                    echo "[SUCCESS] $tool_name: Directory exists" >> "$VALIDATION_LOG"
                    VALIDATION_RESULTS["$tool_name"]="SUCCESS"
                    VALIDATION_DETAILS["$tool_name"]="Directory exists"
                    ((success_count++))
                    return 0
                fi
            fi
            
            echo -e "${RED}[-] $tool_name is not installed or not in PATH${NC}"
            echo "[FAILED] $tool_name: Not installed or not in PATH" >> "$VALIDATION_LOG"
            VALIDATION_RESULTS["$tool_name"]="FAILED"
            VALIDATION_DETAILS["$tool_name"]="Not installed or not in PATH"
            ((failure_count++))
            
            # If --fix-failed is enabled, attempt to reinstall
            if $FIX_FAILED; then
                echo -e "${YELLOW}[!] Attempting to reinstall $tool_name...${NC}"
                
                if [[ "$category" == "APT_TOOLS" ]]; then
                    apt-get install -y "$tool_name" >/dev/null 2>&1
                    if eval "$validation_command" &>/dev/null; then
                        echo -e "${GREEN}[+] Successfully reinstalled $tool_name${NC}"
                        VALIDATION_RESULTS["$tool_name"]="FIXED"
                        VALIDATION_DETAILS["$tool_name"]="Reinstalled successfully"
                        ((success_count++))
                        ((failure_count--))
                        return 0
                    else
                        echo -e "${RED}[-] Failed to reinstall $tool_name${NC}"
                    fi
                elif [[ "$category" == "PIPX_TOOLS" ]]; then
                    pipx install "$tool_name" >/dev/null 2>&1
                    if eval "$validation_command" &>/dev/null; then
                        echo -e "${GREEN}[+] Successfully reinstalled $tool_name with pipx${NC}"
                        VALIDATION_RESULTS["$tool_name"]="FIXED"
                        VALIDATION_DETAILS["$tool_name"]="Reinstalled successfully with pipx"
                        ((success_count++))
                        ((failure_count--))
                        return 0
                    else
                        echo -e "${RED}[-] Failed to reinstall $tool_name with pipx${NC}"
                    fi
elif [[ "$category" == "GIT_TOOLS" ]]; then
                    # For git tools, check if there's a helper script
                    local helper_script="$TOOLS_DIR/helpers/install_${tool_name}.sh"
                    if [ -f "$helper_script" ]; then
                        echo -e "${YELLOW}[!] Running helper script for $tool_name...${NC}"
                        bash "$helper_script" >/dev/null 2>&1
                        if eval "$validation_command" &>/dev/null; then
                            echo -e "${GREEN}[+] Successfully reinstalled $tool_name with helper script${NC}"
                            VALIDATION_RESULTS["$tool_name"]="FIXED"
                            VALIDATION_DETAILS["$tool_name"]="Reinstalled successfully with helper script"
                            ((success_count++))
                            ((failure_count--))
                            return 0
                        else
                            echo -e "${RED}[-] Failed to reinstall $tool_name with helper script${NC}"
                        fi
                    else
                        echo -e "${RED}[-] No helper script found for $tool_name${NC}"
                    fi
                elif [[ "$category" == "MANUAL_TOOLS" ]]; then
                    # For manual tools, check if there's a helper script
                    local helper_script="$TOOLS_DIR/helpers/install_${tool_name}.sh"
                    if [ -f "$helper_script" ]; then
                        echo -e "${YELLOW}[!] Running helper script for $tool_name...${NC}"
                        bash "$helper_script" >/dev/null 2>&1
                        if eval "$validation_command" &>/dev/null; then
                            echo -e "${GREEN}[+] Successfully reinstalled $tool_name with helper script${NC}"
                            VALIDATION_RESULTS["$tool_name"]="FIXED"
                            VALIDATION_DETAILS["$tool_name"]="Reinstalled successfully with helper script"
                            ((success_count++))
                            ((failure_count--))
                            return 0
                        else
                            echo -e "${RED}[-] Failed to reinstall $tool_name with helper script${NC}"
                        fi
                    else
                        echo -e "${RED}[-] No helper script found for $tool_name${NC}"
                    fi
                fi
            fi
            
            return 2
        fi
    fi
}

# Function to add a section to the report
add_report_section() {
    local title=$1
    local tools=$2
    
    echo "=================================================================" >> "$VALIDATION_REPORT"
    echo "  $title" >> "$VALIDATION_REPORT"
    echo "=================================================================" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
    
    # Sort tools by status: SUCCESS, WARNING, FAILED
    local success_list=""
    local fixed_list=""
    local warning_list=""
    local failed_list=""
    
    for tool in "${!tools[@]}"; do
        if [[ "${VALIDATION_RESULTS[$tool]}" == "SUCCESS" ]]; then
            success_list+="  ✓ $tool: ${VALIDATION_DETAILS[$tool]}\n"
        elif [[ "${VALIDATION_RESULTS[$tool]}" == "FIXED" ]]; then
            fixed_list+="  ✓ $tool: ${VALIDATION_DETAILS[$tool]}\n"
        elif [[ "${VALIDATION_RESULTS[$tool]}" == "WARNING" ]]; then
            warning_list+="  ⚠ $tool: ${VALIDATION_DETAILS[$tool]}\n"
        elif [[ "${VALIDATION_RESULTS[$tool]}" == "FAILED" ]]; then
            failed_list+="  ✗ $tool: ${VALIDATION_DETAILS[$tool]}\n"
        fi
    done
    
    # Print results in order
    if [ -n "$success_list" ]; then
        echo "SUCCESSFULLY VALIDATED:" >> "$VALIDATION_REPORT"
        echo -e "$success_list" >> "$VALIDATION_REPORT"
    fi
    
    if [ -n "$fixed_list" ]; then
        echo "FIXED DURING VALIDATION:" >> "$VALIDATION_REPORT"
        echo -e "$fixed_list" >> "$VALIDATION_REPORT"
    fi
    
    if [ -n "$warning_list" ]; then
        echo "WARNINGS:" >> "$VALIDATION_REPORT"
        echo -e "$warning_list" >> "$VALIDATION_REPORT"
    fi
    
    if [ -n "$failed_list" ]; then
        echo "FAILED VALIDATION:" >> "$VALIDATION_REPORT"
        echo -e "$failed_list" >> "$VALIDATION_REPORT"
    fi
    
    echo "" >> "$VALIDATION_REPORT"
}

# Function to export HTML report
export_html_report() {
    local html_file="${VALIDATION_REPORT%.txt}.html"
    
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RTA Tools Validation Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        h1, h2, h3 {
            color: #2c3e50;
        }
        .header {
            background-color: #34495e;
            color: white;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
            text-align: center;
        }
        .summary {
            display: flex;
            justify-content: space-between;
            margin-bottom: 30px;
        }
        .summary-card {
            flex: 1;
            padding: 15px;
            border-radius: 5px;
            margin: 0 10px;
            text-align: center;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .success { background-color: #e6f7e9; border-left: 4px solid #2ecc71; }
        .warning { background-color: #fef8e7; border-left: 4px solid #f1c40f; }
        .error { background-color: #feecec; border-left: 4px solid #e74c3c; }
        .category {
            margin-bottom: 30px;
            border: 1px solid #eee;
            border-radius: 5px;
            overflow: hidden;
        }
        .category-header {
            background-color: #f9f9f9;
            padding: 10px 15px;
            border-bottom: 1px solid #eee;
            font-weight: bold;
        }
        .tool-list {
            padding: 0;
            margin: 0;
            list-style-type: none;
        }
        .tool-item {
            padding: 10px 15px;
            border-bottom: 1px solid #eee;
        }
        .tool-item:last-child {
            border-bottom: none;
        }
        .tool-success { color: #2ecc71; }
        .tool-warning { color: #f1c40f; }
        .tool-error { color: #e74c3c; }
        .tool-fixed { color: #3498db; }
        .footer {
            margin-top: 30px;
            text-align: center;
            font-size: 0.9em;
            color: #7f8c8d;
        }
        @media print {
            body { font-size: 12pt; }
            .category { page-break-inside: avoid; }
            .header { background-color: #f9f9f9; color: #333; }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>RTA Tools Validation Report</h1>
        <p>Generated on $(date)</p>
        <p>Host: $(hostname) - Kali $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Linux")</p>
    </div>

    <div class="summary">
        <div class="summary-card success">
            <h3>Success</h3>
            <p style="font-size: 24px;"><strong>$success_count</strong></p>
            <p>Tools successfully validated</p>
        </div>
        <div class="summary-card warning">
            <h3>Warnings</h3>
            <p style="font-size: 24px;"><strong>$warning_count</strong></p>
            <p>Tools with warnings</p>
        </div>
        <div class="summary-card error">
            <h3>Failed</h3>
            <p style="font-size: 24px;"><strong>$failure_count</strong></p>
            <p>Tools failed validation</p>
        </div>
    </div>
EOF

    # Add category sections
    for category in APT_TOOLS PIPX_TOOLS GIT_TOOLS MANUAL_TOOLS; do
        # Check if we should include this category
        if $ESSENTIAL_ONLY && [ "$category" != "ESSENTIAL_TOOLS" ]; then
            continue
        fi
        if $APT_ONLY && [ "$category" != "APT_TOOLS" ]; then
            continue
        fi
        if $PIPX_ONLY && [ "$category" != "PIPX_TOOLS" ]; then
            continue
        fi
        if $GIT_ONLY && [ "$category" != "GIT_TOOLS" ]; then
            continue
        fi
        
        # Get pretty name for category
        case "$category" in
            "APT_TOOLS") pretty_name="APT-Installed Tools" ;;
            "PIPX_TOOLS") pretty_name="PIPX-Installed Tools" ;;
            "GIT_TOOLS") pretty_name="Git-Installed Tools" ;;
            "MANUAL_TOOLS") pretty_name="Manually Installed Tools" ;;
            "ESSENTIAL_TOOLS") pretty_name="Essential Tools" ;;
            *) pretty_name="$category" ;;
        esac
        
        # Start category section
        cat >> "$html_file" << EOF
    <div class="category">
        <div class="category-header">$pretty_name</div>
        <ul class="tool-list">
EOF
        
        # Add tools in the category
        declare -n tools_array="$category"
        for tool in "${!tools_array[@]}"; do
            status="${VALIDATION_RESULTS[$tool]}"
            details="${VALIDATION_DETAILS[$tool]}"
            
            case "$status" in
                "SUCCESS") 
                    icon="✓"
                    class="tool-success"
                    ;;
                "FIXED") 
                    icon="✓"
                    class="tool-fixed"
                    ;;
                "WARNING") 
                    icon="⚠"
                    class="tool-warning"
                    ;;
                "FAILED") 
                    icon="✗"
                    class="tool-error"
                    ;;
                *) 
                    icon="?"
                    class=""
                    ;;
            esac
            
            cat >> "$html_file" << EOF
            <li class="tool-item">
                <span class="$class">$icon $tool:</span> $details
            </li>
EOF
        done
        
        # End category section
        cat >> "$html_file" << EOF
        </ul>
    </div>
EOF
    done
    
    # Add footer and close HTML
    cat >> "$html_file" << EOF
    <div class="footer">
        <p>Validation time: $minutes minutes and $seconds seconds</p>
        <p>RTA Tools Validation System v3.0</p>
    </div>
</body>
</html>
EOF

    echo -e "${BLUE}[i] HTML report exported to: ${YELLOW}$html_file${NC}"
}

# Determine which tools to validate
if $ESSENTIAL_ONLY; then
    echo -e "${BLUE}[i] Validating essential tools only${NC}"
    tools_to_check=("ESSENTIAL_TOOLS")
elif $APT_ONLY; then
    echo -e "${BLUE}[i] Validating apt-installed tools only${NC}"
    tools_to_check=("APT_TOOLS")
elif $PIPX_ONLY; then
    echo -e "${BLUE}[i] Validating pipx-installed tools only${NC}"
    tools_to_check=("PIPX_TOOLS")
elif $GIT_ONLY; then
    echo -e "${BLUE}[i] Validating git-installed tools only${NC}"
    tools_to_check=("GIT_TOOLS")
else
    echo -e "${BLUE}[i] Validating all security tools${NC}"
    tools_to_check=("APT_TOOLS" "PIPX_TOOLS" "GIT_TOOLS" "MANUAL_TOOLS")
fi

# Validate each category of tools
for category in "${tools_to_check[@]}"; do
    echo -e "\n${BOLD}${YELLOW}=== Validating ${category} ===${NC}"
    
    # Get the associative array by name using indirect reference
    declare -n tools_array="$category"
    
    # Count tools in this category for progress display
    local category_total="${#tools_array[@]}"
    local category_current=0
    
    for tool in "${!tools_array[@]}"; do
        ((category_current++))
        if [ $category_total -gt 10 ] && ! $VERBOSE; then
            # Show progress for large categories
            printf "Progress: [%3d/%3d] %3d%%\r" $category_current $category_total $((category_current * 100 / category_total))
        fi
        validate_tool "$tool" "${tools_array[$tool]}" "$category"
    done
    
    if [ $category_total -gt 10 ] && ! $VERBOSE; then
        printf "%-60s\r" " " # Clear the progress line
    fi
done

# Calculate elapsed time
end_time=$(date +%s)
elapsed=$((end_time - start_time))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))

# Add sections to the report
if $ESSENTIAL_ONLY; then
    add_report_section "ESSENTIAL TOOLS" "ESSENTIAL_TOOLS"
elif $APT_ONLY; then
    add_report_section "APT-INSTALLED TOOLS" "APT_TOOLS"
elif $PIPX_ONLY; then
    add_report_section "PIPX-INSTALLED TOOLS" "PIPX_TOOLS"
elif $GIT_ONLY; then
    add_report_section "GIT-INSTALLED TOOLS" "GIT_TOOLS"
else
    add_report_section "APT-INSTALLED TOOLS" "APT_TOOLS"
    add_report_section "PIPX-INSTALLED TOOLS" "PIPX_TOOLS"
    add_report_section "GIT-INSTALLED TOOLS" "GIT_TOOLS"
    add_report_section "MANUALLY INSTALLED TOOLS" "MANUAL_TOOLS"
fi

# Add summary to report
cat >> "$VALIDATION_REPORT" << EOF
=================================================================
                        SUMMARY
=================================================================
Total tools checked: $total_tools
Successfully validated: $success_count
Warnings: $warning_count
Failed validation: $failure_count

Validation time: $minutes minutes and $seconds seconds
=================================================================

EOF

if [ $failure_count -gt 0 ]; then
    cat >> "$VALIDATION_REPORT" << EOF
RECOMMENDATION FOR FAILED TOOLS:
-------------------------------
For failed tools, try reinstalling with:
  sudo $TOOLS_DIR/scripts/validate-tools.sh --fix-failed

For manual tools, use the helper scripts:
  cd $TOOLS_DIR/helpers
  sudo ./install_<tool_name>.sh

EOF
fi

# Export HTML report if requested
if $EXPORT_HTML; then
    export_html_report
fi

# Print summary
echo -e "\n${BOLD}${YELLOW}=== Validation Summary ===${NC}"
echo -e "${BLUE}[i] Total tools checked:${NC} $total_tools"
echo -e "${GREEN}[+] Successfully validated:${NC} $success_count"
echo -e "${YELLOW}[!] Warnings:${NC} $warning_count"
echo -e "${RED}[-] Failed validation:${NC} $failure_count"
echo -e "${BLUE}[i] Validation time:${NC} $minutes minutes and $seconds seconds"
echo -e "${BLUE}[i] Results saved to:${NC} ${VALIDATION_REPORT}"

# Provide recommendations for failed tools
if [ $failure_count -gt 0 ]; then
    echo -e "\n${YELLOW}[!] Recommendations for failed tools:${NC}"
    echo -e "  - For APT/PIPX tools: ${CYAN}sudo $TOOLS_DIR/scripts/validate-tools.sh --fix-failed${NC}"
    echo -e "  - For manual tools: ${CYAN}cd $TOOLS_DIR/helpers && sudo ./install_<tool_name>.sh${NC}"
fi

# Create a desktop shortcut to the report
if [ -d "/usr/share/applications" ]; then
    cat > "/usr/share/applications/rta-validation-report.desktop" << EOF
[Desktop Entry]
Name=RTA Validation Report
Exec=xdg-open $VALIDATION_REPORT
Type=Application
Icon=document-properties
Terminal=false
Categories=Utility;Security;
EOF
    echo -e "\n${BLUE}[i] Created desktop shortcut to the validation report${NC}"
fi

# Exit with appropriate status
if [ $failure_count -gt 0 ]; then
    exit 1
else
    exit 0
fi
EOF
  
  # Make the script executable
  chmod +x "$SCRIPTS_DIR/validate-tools.sh"
  
  log "SUCCESS" "Validation script created successfully"
  return 0
}

# Function to create setup environment script
create_environment_script() {
  log "STATUS" "Creating environment setup script..."
  
  cat > "$SCRIPTS_DIR/setup_env.sh" << 'EOF'
#!/bin/bash
# RTA Security Tools Environment Setup Script
# This script sets up the environment for all installed security tools

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[i] Setting up security tools environment...${NC}"

# Set up environment variables
export SECURITY_TOOLS_DIR="/opt/security-tools"
export PATH="$PATH:$SECURITY_TOOLS_DIR/bin:/usr/local/bin"

# Function to activate a specific tool's virtual environment
activate_tool() {
    local tool=$1
    
    if [ -z "$tool" ]; then
        echo -e "${YELLOW}[!] Please specify a tool name${NC}"
        echo -e "${BLUE}[i] Available virtual environments:${NC}"
        ls -1 "$SECURITY_TOOLS_DIR/venvs" | sed 's/^/  - /'
        return 1
    fi
    
    if [ -d "$SECURITY_TOOLS_DIR/venvs/$tool" ]; then
        source "$SECURITY_TOOLS_DIR/venvs/$tool/bin/activate"
        echo -e "${GREEN}[+] Activated $tool virtual environment${NC}"
    else
        echo -e "${RED}[-] Virtual environment for $tool not found${NC}"
        echo -e "${BLUE}[i] Available virtual environments:${NC}"
        ls -1 "$SECURITY_TOOLS_DIR/venvs" | sed 's/^/  - /'
        return 1
    fi
}

# Create aliases for all available tools
for tool_venv in $SECURITY_TOOLS_DIR/venvs/*; do
    if [ -d "$tool_venv" ]; then
        tool_name=$(basename "$tool_venv")
        alias "activate-$tool_name"="activate_tool $tool_name"
    fi
done

# Tool-specific aliases and functions
alias update-tools='sudo /opt/rta-deployment/deploy-rta.sh --no-downloads'
alias validate-tools='sudo /opt/security-tools/scripts/validate-tools.sh'
alias fix-tools='sudo /opt/security-tools/scripts/validate-tools.sh --fix-failed'
alias bfg='java -jar $SECURITY_TOOLS_DIR/bfg*.jar'

# Helper function to install a specific tool
install-tool() {
    if [ -z "$1" ]; then
        echo -e "${YELLOW}[!] Please specify a tool name${NC}"
        echo -e "${BLUE}[i] Available installation helpers:${NC}"
        ls -1 $SECURITY_TOOLS_DIR/helpers/install_*.sh | sed 's/.*install_\(.*\)\.sh/  - \1/'
        return 1
    fi
    
    local tool="$1"
    local helper="$SECURITY_TOOLS_DIR/helpers/install_${tool}.sh"
    
    if [ -f "$helper" ]; then
        echo -e "${BLUE}[i] Installing $tool...${NC}"
        sudo "$helper"
    else
        echo -e "${RED}[-] No installation helper found for $tool${NC}"
        echo -e "${BLUE}[i] Available installation helpers:${NC}"
        ls -1 $SECURITY_TOOLS_DIR/helpers/install_*.sh | sed 's/.*install_\(.*\)\.sh/  - \1/'
        return 1
    fi
}

# Function to search for tools
search-tool() {
    if [ -z "$1" ]; then
        echo -e "${YELLOW}[!] Please specify a search term${NC}"
        return 1
    fi
    
    local term="$1"
    echo -e "${BLUE}[i] Searching for tools matching '$term'...${NC}"
    
    # Search in installed binaries
    echo -e "${BLUE}[i] Installed binaries:${NC}"
    find /usr/bin /usr/local/bin $SECURITY_TOOLS_DIR/bin -type f -executable -name "*$term*" 2>/dev/null | sort | sed 's/^/  - /'
    
    # Search in virtual environments
    echo -e "${BLUE}[i] Virtual environments:${NC}"
    find $SECURITY_TOOLS_DIR/venvs -name "*$term*" 2>/dev/null | sed 's/^/  - /'
    
    # Search in helper scripts
    echo -e "${BLUE}[i] Installation helpers:${NC}"
    find $SECURITY_TOOLS_DIR/helpers -name "*$term*" 2>/dev/null | sed 's/^/  - /'
}

# Function to show environment info
show-env-info() {
    echo -e "${BLUE}[i] Security Tools Environment Information${NC}"
    echo -e "${BLUE}[i] -----------------------------------${NC}"
    echo -e "${YELLOW}Tools Directory:${NC} $SECURITY_TOOLS_DIR"
    echo -e "${YELLOW}Virtual Environments:${NC} $(ls -1 $SECURITY_TOOLS_DIR/venvs | wc -l)"
    echo -e "${YELLOW}Helper Scripts:${NC} $(ls -1 $SECURITY_TOOLS_DIR/helpers | wc -l)"
    echo -e "${YELLOW}Installed APT Tools:${NC} $(validate-tools --apt-only 2>&1 | grep "Successfully validated" | cut -d':' -f2 | tr -d ' ')"
    echo -e "${YELLOW}System:${NC} $(uname -a)"
    echo -e "${YELLOW}Kali Version:${NC} $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Unknown")"
}

echo -e "${GREEN}[+] Security tools environment set up successfully.${NC}"
echo -e "${BLUE}[i] Available commands:${NC}"
echo -e "  - ${YELLOW}activate-<tool>${NC}: Activate a specific tool's virtual environment"
echo -e "  - ${YELLOW}install-tool <name>${NC}: Install a specific tool using its helper script"
echo -e "  - ${YELLOW}search-tool <term>${NC}: Search for installed tools"
echo -e "  - ${YELLOW}show-env-info${NC}: Show environment information"
echo -e "  - ${YELLOW}validate-tools${NC}: Validate installed tools"
echo -e "  - ${YELLOW}fix-tools${NC}: Try to fix failed tools"
echo -e "  - ${YELLOW}update-tools${NC}: Update all tools"
EOF
  
  chmod +x "$SCRIPTS_DIR/setup_env.sh"
  
  # Add source line to /etc/bashrc to enable the environment for all users
  if ! grep -q "source $SCRIPTS_DIR/setup_env.sh" "/etc/bash.bashrc"; then
    echo -e "\n# Source the security tools environment\nif [ -f $SCRIPTS_DIR/setup_env.sh ]; then\n    source $SCRIPTS_DIR/setup_env.sh\nfi" >> "/etc/bash.bashrc"
  fi
  
  log "SUCCESS" "Environment setup script created successfully"
  return 0
}

# Function for cleanup
cleanup() {
  local exit_code=$?
  
  log "STATUS" "Performing cleanup..."
  
  # Kill any background processes
  jobs -p | xargs -r kill &>/dev/null
  
  # Remove temporary files
  rm -rf "$TEMP_DIR" 2>/dev/null
  
  # Create final summary
  local end_time=$(date +%s)
  local total_time=$((end_time - START_TIME))
  local minutes=$((total_time / 60))
  local seconds=$((total_time % 60))
  
  cat >> "$REPORT_FILE" << EOF

====================================================================
                    INSTALLATION SUMMARY
====================================================================
Date: $(date)
Installation Duration: $minutes minutes and $seconds seconds

For help with these tools, see the documentation at:
$TOOLS_DIR/docs

To validate the installation, run:
sudo $SCRIPTS_DIR/validate-tools.sh

To update the tools in the future, run:
sudo /opt/rta-deployment/deploy-rta.sh --no-downloads

Thank you for using the RTA Security Tools Installer.
====================================================================
EOF
  
  # Create a desktop shortcut to the report
  if [ -d "/usr/share/applications" ]; then
    cat > "/usr/share/applications/rta-installation-report.desktop" << EOF
[Desktop Entry]
Name=RTA Installation Report
Exec=xdg-open $REPORT_FILE
Type=Application
Icon=document-properties
Terminal=false
Categories=Utility;Security;
EOF
  fi
  
  # Display final message
  if [ $exit_code -eq 0 ]; then
    log "SUCCESS" "Installation completed successfully in $minutes minutes and $seconds seconds"
    log "INFO" "See the full report at: $REPORT_FILE"
    log "INFO" "Run validation with: sudo $SCRIPTS_DIR/validate-tools.sh"
  else
    log "ERROR" "Installation encountered errors (code $exit_code)"
    log "INFO" "See the log file at: $INSTALL_LOG"
  fi
  
  # Return the original exit code
  return $exit_code
}

# Function to configure default system settings
configure_system_settings() {
  log "STATUS" "Configuring system settings..."
  
  # Disable power management and screen lock
  disable_screen_lock
  
  # Create desktop shortcuts for web tools
  install_web_shortcuts
  
  # Set up bash aliases
  setup_bash_aliases
  
  # Create validation script
  create_validation_script
  
  # Create environment setup script
  create_environment_script
  
  log "SUCCESS" "System settings configured successfully"
  return 0
}

# Main function
main() {
  # Parse command line arguments
  parse_arguments "$@"
  
  # Check if running as root
  check_root
  
  # Create required directories
  create_directories
  
  # Initialize report
  initialize_report
  
  log "STATUS" "Starting enhanced RTA tools installation..."
  
  # Create default configuration if using custom config
  if [ -n "$CUSTOM_CONFIG" ]; then
    if [ -f "$CUSTOM_CONFIG" ]; then
      log "INFO" "Using custom configuration file: $CUSTOM_CONFIG"
      mkdir -p "$CONFIG_DIR"
      cp "$CUSTOM_CONFIG" "$CONFIG_FILE"
    else
      log "ERROR" "Custom configuration file not found: $CUSTOM_CONFIG"
      exit 1
    fi
  else
    # Create default configuration
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'EOF'
# RTA Tools Installer Configuration
# Comprehensive config file for Kali Linux Remote Testing Appliance

# Core apt tools - installed with apt-get
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,seclists,proxychains4,responder,metasploit-framework,exploitdb,nikto,dirb,dirbuster,whatweb,wpscan,masscan,aircrack-ng,john,hashcat,crackmapexec,enum4linux,gobuster,ffuf,steghide,binwalk,foremost,exiftool,httpie,rlwrap,nbtscan,ncat,netcat-traditional,netdiscover,dnsutils,whois,net-tools,putty,rdesktop,freerdp2-x11,snmp,golang,nodejs,npm,python3-dev,build-essential,xsltproc,parallel,wifite,theharvester,dsniff,macchanger,wordlists,dnsenum,dnsrecon,onesixtyone,snmpcheck,smbmap,sslscan,sslyze,nfs-common,tmux,screen,powershell,bloodhound,zaproxy,burpsuite,amass,hashid,hashcat-utils,medusa,crunch,recon-ng,fierce,terminator"

# Python tools - installed with pipx
pipx_tools: "scoutsuite,impacket,pymeta,fierce,pwnedpasswords,trufflehog,pydictor,apkleaks,wfuzz,hakrawler,sublist3r,nuclei,recon-ng,commix,evil-winrm,droopescan,sshuttle,gitleaks,stegcracker,pypykatz,witnessme,ldapdomaindump,bloodhound-python,certipy,cve-search,dirsearch,wprecon,wafw00f,crosslinked,autorecon,subjack,tldextract,s3scanner,subfinder"

# GitHub repositories
git_tools: "https://github.com/prowler-cloud/prowler.git,https://github.com/ImpostorKeanu/parsuite.git,https://github.com/fin3ss3g0d/evilgophish.git,https://github.com/Und3rf10w/kali-anonsurf.git,https://github.com/s0md3v/XSStrike.git,https://github.com/swisskyrepo/PayloadsAllTheThings.git,https://github.com/danielmiessler/SecLists.git,https://github.com/internetwache/GitTools.git,https://github.com/digininja/CeWL.git,https://github.com/gchq/CyberChef.git,https://github.com/Kevin-Robertson/Inveigh.git,https://github.com/projectdiscovery/nuclei.git,https://github.com/m8sec/pymeta.git,https://github.com/FortyNorthSecurity/EyeWitness.git,https://github.com/dievus/threader3000.git,https://github.com/carlospolop/PEASS-ng.git,https://github.com/ticarpi/jwt_tool.git,https://github.com/ShutdownRepo/LinEnum.git,https://github.com/maurosoria/dirsearch.git,https://github.com/mdsecactivebreach/o365-attack-toolkit.git,https://github.com/AlessandroZ/LaZagne.git,https://github.com/secretsquirrel/the-backdoor-factory.git,https://github.com/byt3bl33d3r/SprayingToolkit.git,https://github.com/BC-SECURITY/Empire.git,https://github.com/CoreSecurity/impacket.git,https://github.com/BloodHoundAD/BloodHound.git"

# Manual tools - installation helpers will be generated
manual_tools: "nessus,vmware_remote_console,burpsuite_enterprise,teamviewer,ninjaone,gophish,evilginx3,metasploit-framework,cobalt-strike,covenant,sliver,powershell-empire,bfg"

# Tool configuration settings
tool_settings:
  # Metasploit configuration
  metasploit:
    db_enabled: true
    auto_update: true
  
  # Nessus configuration
  nessus:
    port: 8834
    auto_start: true
    
  # Proxy settings
  proxy:
    enable_global_proxy: false
    proxy_address: "127.0.0.1"
    proxy_port: 8080
    
  # Browser configurations
  browsers:
    install_firefox_extensions: true
    firefox_extensions:
      - "foxyproxy"
      - "wappalyzer"
      - "user-agent-switcher"
    
  # Network settings
  network:
    disable_ipv6: true
    preserve_mac_address: true
    disable_network_manager_auto_connect: true
    
  # System settings
  system:
    disable_screen_lock: true
    disable_power_management: true
    disable_auto_updates: true
    disable_bluetooth: true
    use_zsh: false
    set_bash_aliases: true

# Desktop integration settings
desktop:
  create_shortcuts: true
  categories:
    - "Reconnaissance"
    - "Vulnerability Analysis"
    - "Web Application"
    - "Password Attacks"
    - "Exploitation"
    - "Post Exploitation"
    - "Reporting"
  web_shortcuts:
    - name: "VirusTotal"
      url: "https://www.virustotal.com"
    - name: "ExploitDB"
      url: "https://www.exploit-db.com"
    - name: "MITRE ATT&CK"
      url: "https://attack.mitre.org"
    - name: "CVE Details"
      url: "https://cvedetails.com"
    - name: "HaveIBeenPwned"
      url: "https://haveibeenpwned.com"
    - name: "OSINT Framework"
      url: "https://osintframework.com"
    - name: "Shodan"
      url: "https://www.shodan.io"

# Environment settings
environment:
  setup_path: true
  setup_aliases: true
  setup_completion: true
  setup_tmux_config: true
  default_shell: "bash"
  custom_prompt: true

# Update and validation settings
validation:
  validate_after_install: true
  auto_fix_failures: true
  create_validation_report: true
  check_tool_versions: true
  
# Logging settings
logging:
  verbose: false
  save_logs: true
  log_level: "info"
  create_system_snapshot: true
EOF
  fi
  
  # Install core packages based on configuration
  if $CORE_ONLY; then
    log "INFO" "Installing core tools only"
    
    # Extract core tools from config
    local core_apt_tools="nmap,wireshark,sqlmap,hydra,bettercap,responder,metasploit-framework,john,hashcat,proxychains4,terminator"
    local core_pipx_tools="impacket,pymeta,nuclei,evil-winrm"
    local core_git_tools="https://github.com/prowler-cloud/prowler.git,https://github.com/danielmiessler/SecLists.git"
    
    # Install core tools
    install_apt_packages "$core_apt_tools"
    install_pipx_tools "$core_pipx_tools"
    install_github_tools "$core_git_tools"
  else
    # Extract tools from config
    local apt_tools=$(grep -E "^apt_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    local pipx_tools=$(grep -E "^pipx_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    local git_tools=$(grep -E "^git_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    local manual_tools=$(grep -E "^manual_tools:" "$CONFIG_FILE" | cut -d'"' -f2)
    
    # Install tools
    log "STATUS" "Installing security tools from configuration..."
    
    # Install apt packages
    install_apt_packages "$apt_tools"
    
    # Install pipx tools
    install_pipx_tools "$pipx_tools"
    
    # Install GitHub repositories
    install_github_tools "$git_tools"
    
    # Generate helper scripts for manual tools
    log "STATUS" "Creating helper scripts for manual tools..."
    if [ -n "$manual_tools" ]; then
      IFS=',' read -ra TOOLS <<< "$manual_tools"
      for tool in "${TOOLS[@]}"; do
        create_helper_script "$tool"
      done
    fi
  fi
  
  # Configure system settings
  configure_system_settings
  
  # Done!
  log "SUCCESS" "Enhanced RTA tools installer completed successfully"
  return 0
}

# Run the main function with the provided arguments
main "$@"
exit $?
