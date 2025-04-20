#!/bin/bash
# ================================================================
# Enhanced RTA Deployment Script v3.0
# ================================================================
# Robust, fully-automated deployment system for security testing
# appliances with comprehensive error handling and parallel processing
# ================================================================

# Exit on unhandled errors (will be caught by trap handler)
set -e

# Global configuration
VERSION="3.0"
DEPLOY_DIR="/opt/rta-deployment"
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$DEPLOY_DIR/logs"
CONFIG_DIR="$DEPLOY_DIR/config"
DOWNLOAD_DIR="$DEPLOY_DIR/downloads"
TEMP_DIR="$DEPLOY_DIR/temp"
SYSTEM_STATE_DIR="$TOOLS_DIR/system-state"
HELPERS_DIR="$TOOLS_DIR/helpers"
SCRIPTS_DIR="$TOOLS_DIR/scripts"
CONFIG_FILE="$CONFIG_DIR/config.yml"
MAIN_LOG="$LOG_DIR/deployment_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="$LOG_DIR/deployment_summary_$(date +%Y%m%d_%H%M%S).txt"

# Auto-detect CPU cores and limit parallel jobs
AVAILABLE_CORES=$(grep -c processor /proc/cpuinfo)
PARALLEL_JOBS=$((AVAILABLE_CORES > 1 ? AVAILABLE_CORES - 1 : 1))
# Limit max parallel jobs to prevent resource exhaustion
[[ $PARALLEL_JOBS -gt 8 ]] && PARALLEL_JOBS=8

# Timeout settings (in seconds)
DEFAULT_TIMEOUT=120    # 2 minutes
LONG_TIMEOUT=600       # 10 minutes
SHORT_TIMEOUT=300      # 5 minutes

# Colors for terminal output
BOLD="\e[1m"
RESET="\e[0m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
CYAN="\e[36m"
MAGENTA="\e[35m"
GRAY="\e[90m"

# Auto-detect terminal width for better formatting
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[[ $TERM_WIDTH -lt 80 ]] && TERM_WIDTH=80

# Runtime configuration
AUTO_MODE=false
VERBOSE=false
FORCE_REINSTALL=false
SKIP_DOWNLOADS=false
SKIP_UPDATE=false
BACKUP_CONFIG=true
FULL_INSTALL=true
CORE_TOOLS_ONLY=false
DESKTOP_ONLY=false
DISPLAY_PROGRESS=true
GITHUB_REPO_URL="https://github.com/yourusername/rta-deployment.git"

# Trap for proper cleanup
trap cleanup EXIT INT TERM

# Logging functions
log() {
  local level="$1"
  local message="$2"
  local color=""
  local prefix=""
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Determine color and prefix
  case "$level" in
    "DEBUG")
      color="$GRAY"
      prefix="[D]"
      ;;
    "INFO")
      color="$BLUE"
      prefix="[I]"
      ;;
    "SUCCESS")
      color="$GREEN"
      prefix="[✓]"
      ;;
    "WARNING")
      color="$YELLOW"
      prefix="[!]"
      ;;
    "ERROR")
      color="$RED"
      prefix="[✗]"
      ;;
    "CRITICAL")
      color="$RED$BOLD"
      prefix="[!!]"
      ;;
    "STATUS")
      color="$CYAN"
      prefix="[*]"
      ;;
    "HEADER")
      color="$MAGENTA$BOLD"
      prefix="[#]"
      ;;
    *)
      color="$RESET"
      prefix="[*]"
      ;;
  esac
  
  # Create log directory if it doesn't exist
  mkdir -p "$(dirname "$MAIN_LOG")"
  
  # Always write to log file
  echo -e "$timestamp [$level] $message" >> "$MAIN_LOG"
  
  # Only print to console for non-debug messages or if verbose mode is enabled
  if [[ "$level" != "DEBUG" ]] || $VERBOSE; then
    echo -e "${color}${prefix} ${message}${RESET}"
  fi
}

# Function to show spinner during long operations
show_spinner() {
  local pid=$1
  local message="$2"
  local delay=0.1
  local spinstr='⣾⣽⣻⢿⡿⣟⣯⣷'
  local temp_file=$(mktemp)

  # Make sure the process is still running
  if ! kill -0 $pid 2>/dev/null; then
    return
  fi

  # Calculate the available width for the message
  local spinstr_width=1
  local start_indicator="["
  local end_indicator="]"
  local max_msg_width=$((TERM_WIDTH - ${#start_indicator} - ${#end_indicator} - spinstr_width - 2))
  local formatted_message="${message:0:$max_msg_width}"
  
  if [[ ${#message} -gt $max_msg_width ]]; then
    formatted_message="${formatted_message:0:$((max_msg_width-3))}..."
  fi
  
  # Pad message to consistent width
  formatted_message="$(printf "%-${max_msg_width}s" "$formatted_message")"
  
  echo "$pid" > "$temp_file"
  
  (
    while [[ -f "$temp_file" ]] && kill -0 $pid 2>/dev/null; do
      local temp=${spinstr#?}
      local char=${spinstr%"$temp"}
      spinstr=$temp${char}
      printf "\r${BLUE}${start_indicator}${YELLOW}%s${BLUE}${end_indicator} ${formatted_message}" "$char"
      sleep $delay
    done
    # Clear the line after process completion
    printf "\r%-$((TERM_WIDTH-1))s\r" " " 
  ) &
  
  # Store spinner PID so we can kill it later
  spinner_pid=$!
  
  # Wait for the process to finish
  wait $pid
  local exit_status=$?
  
  # Kill spinner and cleanup
  rm -f "$temp_file"
  kill $spinner_pid 2>/dev/null
  wait $spinner_pid 2>/dev/null
  
  # Print final status
  if [[ $exit_status -eq 0 ]]; then
    printf "\r${GREEN}[✓]${RESET} ${formatted_message}\n"
  else
    printf "\r${RED}[✗]${RESET} ${formatted_message} (error code: $exit_status)\n"
  fi
  
  return $exit_status
}

# Function to show progress bar
show_progress_bar() {
  local current=$1
  local total=$2
  local message="$3"
  local width=30
  local percent=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  
  # Calculate the available width for the message
  local max_msg_width=$((TERM_WIDTH - width - 18))
  local formatted_message="${message:0:$max_msg_width}"
  
  if [[ ${#message} -gt $max_msg_width ]]; then
    formatted_message="${formatted_message:0:$((max_msg_width-3))}..."
  fi
  
  # Build the progress bar
  local progress_bar="["
  for ((i=0; i<filled; i++)); do progress_bar+="="; done
  if [[ $filled -lt $width ]]; then progress_bar+=">"; fi
  for ((i=0; i<$((empty-1)); i++)); do progress_bar+=" "; done
  progress_bar+="]"
  
  # Print the progress bar
  printf "\r%-${max_msg_width}s %3d%% %s" "$formatted_message" "$percent" "$progress_bar"
  
  # Print a newline if we're at 100%
  if [[ $current -eq $total ]]; then
    echo ""
  fi
}

# Function to get YAML values from config
get_config_value() {
  local yaml_file=$1
  local key=$2
  local default_value=$3
  
  if [[ ! -f "$yaml_file" ]]; then
    log "WARNING" "Config file not found: $yaml_file, using default value for $key"
    echo "$default_value"
    return
  fi
  
  # Try grep method first (faster and works for simple values)
  local value=$(grep -E "^$key:" "$yaml_file" | cut -d'"' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  # If empty, try another method for multiline values
  if [[ -z "$value" ]]; then
    value=$(sed -n "/^$key:/,/^[a-zA-Z]/{/^$key:/d;/^[a-zA-Z]/d;p}" "$yaml_file" | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
  fi
  
  # Return default if still empty
  if [[ -z "$value" ]]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

# Function to check dependencies
check_dependencies() {
  log "STATUS" "Checking system dependencies..."
  
  local dependencies=("curl" "wget" "git" "parallel" "bc" "unzip" "jq" "nmap" "python3")
  local missing_deps=()
  
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing_deps+=("$dep")
    fi
  done
  
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log "WARNING" "Missing dependencies: ${missing_deps[*]}"
    log "STATUS" "Installing missing dependencies..."
    
    apt-get update || {
      log "ERROR" "Failed to update APT repositories"
      return 1
    }
    
    apt-get install -y "${missing_deps[@]}" || {
      log "CRITICAL" "Failed to install required dependencies"
      return 1
    }
    
    log "SUCCESS" "Dependencies installed successfully"
  else
    log "SUCCESS" "All dependencies are installed"
  fi
  
  return 0
}

# Function to check system resources
check_system_resources() {
  log "STATUS" "Checking system resources..."
  
  # Check available disk space
  local available_space=$(df -BM "$DEPLOY_DIR" | awk 'NR==2 {print $4}' | sed 's/M//')
  if [[ $available_space -lt 10000 ]]; then  # Less than 10GB
    log "WARNING" "Low disk space: ${available_space}MB available. At least 10GB recommended."
    if [[ $available_space -lt 5000 ]]; then  # Less than 5GB
      log "CRITICAL" "Critically low disk space: ${available_space}MB available. Installation may fail."
      if ! prompt_yes_no "Continue with low disk space?" "false"; then
        log "STATUS" "Deployment aborted due to low disk space"
        exit 4
      fi
    fi
  else
    log "SUCCESS" "Sufficient disk space available: ${available_space}MB"
  fi
  
  # Check available RAM
  local total_ram=$(free -m | awk '/^Mem:/{print $2}')
  if [[ $total_ram -lt 2048 ]]; then  # Less than 2GB
    log "WARNING" "Low system memory: ${total_ram}MB RAM. At least 2GB recommended."
    if [[ $total_ram -lt 1024 ]]; then  # Less than 1GB
      log "CRITICAL" "Critically low system memory: ${total_ram}MB RAM. Installation may fail."
      if ! prompt_yes_no "Continue with low memory?" "false"; then
        log "STATUS" "Deployment aborted due to low memory"
        exit 4
      fi
    fi
  else
    log "SUCCESS" "Sufficient system memory available: ${total_ram}MB RAM"
  fi
  
  # Check CPU load
  local cpu_load=$(cat /proc/loadavg | cut -d ' ' -f1)
  if (( $(echo "$cpu_load > $AVAILABLE_CORES" | bc -l) )); then
    log "WARNING" "High system load: $cpu_load. This may slow down installation."
  else
    log "SUCCESS" "Normal system load: $cpu_load"
  fi
  
  return 0
}

# Function to create required directories
create_directories() {
  log "STATUS" "Creating required directories..."
  
  local directories=(
    "$DEPLOY_DIR"
    "$TOOLS_DIR"
    "$LOG_DIR"
    "$CONFIG_DIR"
    "$DOWNLOAD_DIR"
    "$TEMP_DIR"
    "$SYSTEM_STATE_DIR"
    "$HELPERS_DIR"
    "$SCRIPTS_DIR"
    "$TOOLS_DIR/bin"
    "$TOOLS_DIR/desktop"
    "$TOOLS_DIR/venvs"
  )
  
  for dir in "${directories[@]}"; do
    mkdir -p "$dir" || {
      log "ERROR" "Failed to create directory: $dir"
      continue
    }
  done
  
  # Set correct permissions
  chmod 755 "$DEPLOY_DIR" "$TOOLS_DIR" "$HELPERS_DIR" "$SCRIPTS_DIR" "$TOOLS_DIR/bin" || {
    log "WARNING" "Failed to set permissions on some directories"
  }
  
  log "SUCCESS" "Directories created successfully"
  return 0
}

# Function to download a file with auto-retry and validation
download_file() {
  local url="$1"
  local output_file="$2"
  local description="$3"
  local verify_command="${4:-true}"
  local max_retries=3
  local retry_count=0
  local timeout=300
  
  if [[ -f "$output_file" && -s "$output_file" && ! $FORCE_REINSTALL ]]; then
    # Verify existing file if verification command is provided
    if [[ "$verify_command" != "true" ]] && ! eval "$verify_command '$output_file'" &>/dev/null; then
      log "WARNING" "Existing $description file is invalid, will re-download"
    else
      log "INFO" "$description already downloaded at $output_file"
      return 0
    fi
  fi
  
  log "STATUS" "Downloading $description..."
  mkdir -p "$(dirname "$output_file")"
  
  while [[ $retry_count -lt $max_retries ]]; do
    retry_count=$((retry_count + 1))
    
    # Try curl first with user agent and headers, fallback to wget
    if command -v curl &>/dev/null; then
      curl -sSL --connect-timeout 30 --retry 3 --retry-delay 5 \
           -A "Mozilla/5.0 (X11; Linux x86_64)" \
           -H "Accept: application/octet-stream" \
           -o "$output_file" "$url" && {
        # Verify downloaded file if verification command is provided
        if [[ "$verify_command" != "true" ]]; then
          if eval "$verify_command '$output_file'" &>/dev/null; then
            log "SUCCESS" "Downloaded and verified $description successfully"
            return 0
          else
            log "WARNING" "Downloaded $description is invalid, retrying..."
            continue
          fi
        else
          log "SUCCESS" "Downloaded $description successfully"
          return 0
        fi
      }
    elif command -v wget &>/dev/null; then
      wget --timeout=30 --tries=3 --waitretry=5 -q \
           --user-agent="Mozilla/5.0 (X11; Linux x86_64)" \
           --header="Accept: application/octet-stream" \
           "$url" -O "$output_file" && {
        # Verify downloaded file
        if [[ "$verify_command" != "true" ]]; then
          if eval "$verify_command '$output_file'" &>/dev/null; then
            log "SUCCESS" "Downloaded and verified $description successfully"
            return 0
          else
            log "WARNING" "Downloaded $description is invalid, retrying..."
            continue
          fi
        else
          log "SUCCESS" "Downloaded $description successfully"
          return 0
        fi
      }
    else
      log "ERROR" "Neither curl nor wget is available"
      return 1
    fi
    
    log "WARNING" "Download attempt $retry_count for $description failed, retrying..."
    sleep 2
  done
  
  log "ERROR" "Failed to download $description after $max_retries attempts"
  return 1
}

# Function to verify Debian package
verify_deb_package() {
  local deb_file="$1"
  dpkg-deb --info "$deb_file" &>/dev/null
  return $?
}

# Function to run a command with timeout and output control
run_command() {
  local cmd="$1"
  local description="$2"
  local timeout_duration="${3:-$DEFAULT_TIMEOUT}"
  local log_file="$LOG_DIR/$(echo "$description" | tr ' ' '_')_$(date +%Y%m%d_%H%M%S).log"
  
  log "DEBUG" "Running command: $cmd"
  log "DEBUG" "Logging to: $log_file"
  
  # Execute command with timeout
  timeout "$timeout_duration" bash -c "$cmd" > "$log_file" 2>&1 &
  local cmd_pid=$!
  
  if $DISPLAY_PROGRESS; then
    # Display spinner while command is running
    show_spinner $cmd_pid "$description"
    local result=$?
  else
    # Wait for command to complete without spinner
    wait $cmd_pid
    local result=$?
  fi
  
  if [[ $result -eq 0 ]]; then
    log "SUCCESS" "$description completed successfully"
    return 0
  elif [[ $result -eq 124 || $result -eq 143 ]]; then
    log "ERROR" "$description timed out after $timeout_duration seconds"
    log "INFO" "Check log file for details: $log_file"
    return 1
  else
    log "ERROR" "$description failed with exit code $result"
    log "INFO" "Check log file for details: $log_file"
    return 1
  fi
}

# Function to run a command with safe retry and enhanced output
run_safely() {
  local cmd="$1"
  local description="$2"
  local timeout_duration="${3:-$DEFAULT_TIMEOUT}"
  local max_retries=3
  local retry_count=0
  
  while [[ $retry_count -lt $max_retries ]]; do
    retry_count=$((retry_count + 1))
    
    if [[ $retry_count -gt 1 ]]; then
      log "INFO" "Retry $retry_count/$max_retries for $description"
    fi
    
    if run_command "$cmd" "$description" "$timeout_duration"; then
      return 0
    fi
    
    # Abort if exceeds retries
    if [[ $retry_count -ge $max_retries ]]; then
      log "ERROR" "$description failed after $max_retries attempts"
      return 1
    fi
    
    log "WARNING" "Retrying in 5 seconds..."
    sleep 5
  done
  
  return 1
}

# Function to backup configuration
backup_config() {
  if [[ -f "$CONFIG_FILE" && $BACKUP_CONFIG == true ]]; then
    log "INFO" "Backing up existing configuration..."
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)" || {
      log "WARNING" "Failed to backup configuration file"
    }
  fi
}

# Function to ensure configuration file exists
ensure_config() {
  if [[ ! -f "$CONFIG_FILE" || $FORCE_REINSTALL == true ]]; then
    log "INFO" "Creating default configuration..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    
    # Use cat with here document for the configuration file
    cat > "$CONFIG_FILE" << 'EOL'
# Configuration from deploy-rta.sh script
# (This will contain your original config.yml content)
EOL
    
    # Copy the actual config.yml content from your repository
    if [[ -f "$DEPLOY_DIR/config.yml" ]]; then
      cp "$DEPLOY_DIR/config.yml" "$CONFIG_FILE"
    fi
    
    log "SUCCESS" "Configuration file created at $CONFIG_FILE"
  fi
  
  return 0
}

# Function to clone or update the installation repository
setup_repository() {
  log "HEADER" "Setting up installation repository..."
  
  if [[ -d "$DEPLOY_DIR/.git" ]] && ! $FORCE_REINSTALL; then
    log "INFO" "Repository already exists, updating..."
    cd "$DEPLOY_DIR"
    if git pull; then
      log "SUCCESS" "Repository updated successfully"
    else
      log "WARNING" "Failed to update repository, will continue with existing files"
    fi
  else
    log "INFO" "Cloning repository..."
    if [[ -d "$DEPLOY_DIR" && "$(ls -A $DEPLOY_DIR)" ]]; then
      log "WARNING" "Deploy directory not empty, cleaning up..."
      mkdir -p "${DEPLOY_DIR}.bak.$(date +%Y%m%d%H%M%S)"
      mv "$DEPLOY_DIR"/* "${DEPLOY_DIR}.bak.$(date +%Y%m%d%H%M%S)/" 2>/dev/null || true
    fi
    
    if git clone "$GITHUB_REPO_URL" "$DEPLOY_DIR"; then
      log "SUCCESS" "Repository cloned successfully"
    else
      log "ERROR" "Failed to clone repository"
      return 1
    fi
  fi
  
  # Make scripts executable
  if [[ -d "$DEPLOY_DIR/installer/scripts" ]]; then
    chmod +x "$DEPLOY_DIR/installer/scripts"/*.sh 2>/dev/null || true
    
    # Copy scripts to the scripts directory
    cp "$DEPLOY_DIR/installer/scripts"/*.sh "$SCRIPTS_DIR/" 2>/dev/null || true
    chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true
    
    log "SUCCESS" "Installation scripts prepared"
  else
    log "WARNING" "Scripts directory not found in repository"
  fi
  
  return 0
}

# Function to install APT packages in parallel
install_apt_packages() {
  local package_list="$1"
  local total_packages=0
  local current=0
  local success_count=0
  local fail_count=0
  
  # Split package list
  IFS=',' read -ra PACKAGES <<< "$package_list"
  total_packages=${#PACKAGES[@]}
  
  log "HEADER" "Installing $total_packages APT packages..."
  
  # Update APT repositories if needed
  if ! $SKIP_UPDATE; then
    log "STATUS" "Updating APT repositories..."
    apt-get update || {
      log "WARNING" "Failed to update APT repositories"
    }
  fi
  
  # Install packages in parallel if possible
  if command -v parallel &>/dev/null && [[ $total_packages -gt 10 ]]; then
    log "INFO" "Using parallel installation for APT packages ($PARALLEL_JOBS jobs)"
    
    # Create a temporary file to hold package results
    local temp_results=$(mktemp)
    
    # Define installation function for parallel
    install_package() {
      local pkg="$1"
      local temp_file="$2"
      local force_flag="$3"
      
      # Check if already installed, unless force reinstall
      if [[ "$force_flag" != "true" ]] && dpkg -l | grep -q "^ii  $pkg "; then
        echo "SUCCESS:$pkg:already_installed" >> "$temp_file"
      else
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
          echo "SUCCESS:$pkg:installed" >> "$temp_file"
        else
          # Try fixing dependencies
          DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1
          if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
            echo "SUCCESS:$pkg:installed_with_fix" >> "$temp_file"
          else
            echo "FAIL:$pkg" >> "$temp_file"
          fi
        fi
      fi
    }
    
    export -f install_package
    FORCE_FLAG=$FORCE_REINSTALL
    export FORCE_FLAG
    
    # Install in parallel with progress
    printf "%s\n" "${PACKAGES[@]}" | \
      parallel --no-notice -j $PARALLEL_JOBS \
      "install_package {} $temp_results $FORCE_FLAG"
    
    # Process results
    while IFS= read -r line; do
      if [[ "$line" == SUCCESS:* ]]; then
        ((success_count++))
        pkg=${line#SUCCESS:}
        pkg=${pkg%%:*}
        status=${line##*:}
        
        if [[ "$status" == "already_installed" ]]; then
          log "DEBUG" "$pkg is already installed"
        else
          log "DEBUG" "Successfully installed $pkg"
        fi
      elif [[ "$line" == FAIL:* ]]; then
        ((fail_count++))
        pkg=${line#FAIL:}
        log "ERROR" "Failed to install $pkg"
      fi
    done < "$temp_results"
    
    rm -f "$temp_results"
  else
    # Fallback to sequential installation
    for package in "${PACKAGES[@]}"; do
      ((current++))
      
      if $DISPLAY_PROGRESS; then
        show_progress_bar $current $total_packages "Installing $package ($current/$total_packages)"
      fi
      
      # Check if already installed
      if [[ ! $FORCE_REINSTALL ]] && dpkg -l | grep -q "^ii  $package "; then
        log "DEBUG" "$package is already installed"
        ((success_count++))
        continue
      fi
      
      # Install package
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
        log "DEBUG" "Successfully installed $package"
        ((success_count++))
      else
        log "WARNING" "Failed to install $package, attempting to fix dependencies..."
        DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
          log "DEBUG" "Successfully installed $package after fixing dependencies"
          ((success_count++))
        else
          log "ERROR" "Failed to install $package"
          ((fail_count++))
        fi
      fi
    done
  fi
  
  log "STATUS" "APT package installation completed: $success_count successful, $fail_count failed, out of $total_packages"
  
  # Install any missing dependencies
  apt-get -f install -y >/dev/null 2>&1
  
  return $fail_count
}

# Function to install PIPX packages
install_pipx_packages() {
  local package_list="$1"
  local total_packages=0
  local current=0
  local success_count=0
  local fail_count=0
  
  # Split package list
  IFS=',' read -ra PACKAGES <<< "$package_list"
  total_packages=${#PACKAGES[@]}
  
  log "HEADER" "Installing $total_packages PIPX packages..."
  
  # Ensure pipx is installed
  if ! command -v pipx &>/dev/null; then
    log "STATUS" "Installing pipx..."
    apt-get install -y python3-pip python3-venv || {
      log "ERROR" "Failed to install python3-pip or python3-venv"
      return 1
    }
    python3 -m pip install --user pipx || {
      log "ERROR" "Failed to install pipx"
      return 1
    }
    python3 -m pipx ensurepath || {
      log "WARNING" "Failed to add pipx to PATH"
    }
    export PATH="$PATH:$HOME/.local/bin"
  fi
  
  # Function to install a single pipx package
  install_pipx_package() {
    local package="$1"
    
    # Check if already installed
    if [[ ! $FORCE_REINSTALL ]] && pipx list 2>/dev/null | grep -q "$package"; then
      log "DEBUG" "$package is already installed via pipx"
      return 0
    fi
    
    # Uninstall if force reinstall
    if [[ $FORCE_REINSTALL ]] && pipx list 2>/dev/null | grep -q "$package"; then
      pipx uninstall "$package" >/dev/null 2>&1
    fi
    
    # Install package
    if pipx install "$package" >/dev/null 2>&1; then
      log "DEBUG" "Successfully installed $package via pipx"
      return 0
    else
      log "WARNING" "Failed to install $package via pipx, retrying with --pip-args..."
      if pipx install "$package" --pip-args="--no-cache-dir --no-deps" >/dev/null 2>&1; then
        log "DEBUG" "Successfully installed $package via pipx on retry"
        return 0
      else
        log "ERROR" "Failed to install $package via pipx"
        return 1
      fi
    fi
  }
  
  # Install packages with progress
  for package in "${PACKAGES[@]}"; do
    ((current++))
    
    if $DISPLAY_PROGRESS; then
      show_progress_bar $current $total_packages "Installing $package via pipx ($current/$total_packages)"
    fi
    
    if install_pipx_package "$package"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
  done
  
  log "STATUS" "PIPX package installation completed: $success_count successful, $fail_count failed, out of $total_packages"
  
  return $fail_count
}

# Function to install Git repositories
install_git_repos() {
  local repo_list="$1"
  local total_repos=0
  local current=0
  local success_count=0
  local fail_count=0
  
  # Split repository list
  IFS=',' read -ra REPOS <<< "$repo_list"
  total_repos=${#REPOS[@]}
  
  log "HEADER" "Installing $total_repos Git repositories..."
  
  # Ensure git is installed
  if ! command -v git &>/dev/null; then
    log "STATUS" "Installing git..."
    apt-get install -y git || {
      log "ERROR" "Failed to install git"
      return 1
    }
  fi
  
  # Function to install a single git repository
  install_git_repo() {
    local repo_url="$1"
    local repo_name=$(basename "$repo_url" .git)
    
    local repo_dir="$TOOLS_DIR/$repo_name"
    
    # Check if already cloned
    if [[ -d "$repo_dir/.git" && ! $FORCE_REINSTALL ]]; then
      log "DEBUG" "$repo_name already cloned, updating..."
      if cd "$repo_dir" && git pull >/dev/null 2>&1; then
        log "DEBUG" "Successfully updated $repo_name"
        
        # Run post-update tasks
        post_git_install "$repo_dir" "$repo_name"
        return 0
      else
        log "WARNING" "Failed to update $repo_name, attempting to reclone..."
        rm -rf "$repo_dir"
      fi
    fi
    
    # Clone repository
    if git clone --depth 1 "$repo_url" "$repo_dir" >/dev/null 2>&1; then
      log "DEBUG" "Successfully cloned $repo_name"
      
      # Run post-clone tasks
      post_git_install "$repo_dir" "$repo_name"
      return 0
    else
      log "ERROR" "Failed to clone $repo_name"
      return 1
    fi
  }
  
  # Function to handle post-installation tasks for git repos
  post_git_install() {
    local repo_dir="$1"
    local repo_name="$2"
    
    # Check for installation scripts
    if [[ -f "$repo_dir/setup.py" ]]; then
      log "DEBUG" "Installing $repo_name with pip..."
      cd "$repo_dir" && pip3 install -e . >/dev/null 2>&1 || {
        log "WARNING" "Failed to install $repo_name with pip"
      }
    elif [[ -f "$repo_dir/requirements.txt" ]]; then
      log "DEBUG" "Installing requirements for $repo_name..."
      cd "$repo_dir" && pip3 install -r requirements.txt >/dev/null 2>&1 || {
        log "WARNING" "Failed to install requirements for $repo_name"
      }
    elif [[ -f "$repo_dir/install.sh" ]]; then
      log "DEBUG" "Running install script for $repo_name..."
      cd "$repo_dir" && bash install.sh >/dev/null 2>&1 || {
        log "WARNING" "Failed to run install script for $repo_name"
      }
    fi
    
    # Create symbolic link if main executable exists
    local main_script=""
    for ext in ".py" ".sh" ""; do
      for name in "main" "cli" "$repo_name" "run"; do
        if [[ -f "$repo_dir/$name$ext" ]]; then
          main_script="$name$ext"
          break 2
        fi
      done
    done
    
    if [[ -n "$main_script" ]]; then
      chmod +x "$repo_dir/$main_script"
      ln -sf "$repo_dir/$main_script" "/usr/local/bin/$repo_name" || {
        log "WARNING" "Failed to create symbolic link for $repo_name"
      }
    fi
    
    return 0
  }
  
  # Install repositories with progress
  for repo_url in "${REPOS[@]}"; do
    ((current++))
    local repo_name=$(basename "$repo_url" .git)
    
    if $DISPLAY_PROGRESS; then
      show_progress_bar $current $total_repos "Installing $repo_name ($current/$total_repos)"
    fi
    
    if install_git_repo "$repo_url"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
  done
  
  log "STATUS" "Git repository installation completed: $success_count successful, $fail_count failed, out of $total_repos"
  
  return $fail_count
}

# Function to run installation helpers
run_installation_helpers() {
  local helper_list="$1"
  local total_helpers=0
  local current=0
  local success_count=0
  local fail_count=0
  
  # Split helper list
  IFS=',' read -ra HELPERS <<< "$helper_list"
  total_helpers=${#HELPERS[@]}
  
  log "HEADER" "Running installation helpers for $total_helpers tools..."
  
  # Run installation helpers
  for helper in "${HELPERS[@]}"; do
    ((current++))
    local helper_name="install_${helper}.sh"
    local helper_path=""
    
    # Look for the helper script in multiple locations
    for path in "$HELPERS_DIR/$helper_name" "$DEPLOY_DIR/installer/scripts/$helper_name" "$SCRIPTS_DIR/$helper_name"; do
      if [[ -f "$path" ]]; then
        helper_path="$path"
        break
      fi
    done
    
    if [[ -z "$helper_path" ]]; then
      log "WARNING" "Helper script for $helper not found"
      ((fail_count++))
      continue
    fi
    
    log "STATUS" "Installing $helper ($current/$total_helpers)..."
    
    # Make sure the script is executable
    chmod +x "$helper_path"
    
    # Run the helper script
    if run_safely "bash $helper_path" "Installing $helper" "$LONG_TIMEOUT"; then
      log "SUCCESS" "$helper installation completed successfully"
      ((success_count++))
    else
      log "ERROR" "Failed to install $helper"
      ((fail_count++))
    fi
  done
  
  log "STATUS" "Installation helpers completed: $success_count successful, $fail_count failed, out of $total_helpers"
  
  return $fail_count
}

# Function to configure system settings
configure_system() {
  log "HEADER" "Configuring system settings..."
  
  # Disable screen lock if requested
  local disable_screen_lock=$(get_config_value "$CONFIG_FILE" "tool_settings.system.disable_screen_lock" "true")
  if [[ "$disable_screen_lock" = "true" ]]; then
    log "STATUS" "Disabling screen lock..."
    
    # Look for the disable-lock-screen.sh script in multiple locations
    local lock_script=""
    for path in "$SCRIPTS_DIR/disable-lock-screen.sh" "$DEPLOY_DIR/installer/scripts/disable-lock-screen.sh"; do
      if [[ -f "$path" ]]; then
        lock_script="$path"
        break
      fi
    done
    
    if [[ -n "$lock_script" ]]; then
      chmod +x "$lock_script"
      run_safely "bash $lock_script" "Disabling screen lock" "$SHORT_TIMEOUT"
    else
      log "WARNING" "Screen lock disable script not found"
    fi
  fi
  
  # Configure desktop environment if running in GUI
  if [[ -n "$DISPLAY" || -n "$WAYLAND_DISPLAY" ]]; then
    log "STATUS" "Configuring desktop environment..."
    
    # Create desktop shortcuts
    local create_shortcuts=$(get_config_value "$CONFIG_FILE" "desktop.create_shortcuts" "true")
    if [[ "$create_shortcuts" = "true" ]]; then
      log "STATUS" "Creating desktop shortcuts..."
      
      # Create RTA Tools category
      mkdir -p "/usr/share/desktop-directories"
      cat > "/usr/share/desktop-directories/rta-tools.directory" << EOL
[Desktop Entry]
Type=Directory
Name=RTA Security Tools
Icon=security-high
EOL
      
      # Create RTA Validation desktop entry
      cat > "/usr/share/applications/rta-validate.desktop" << EOL
[Desktop Entry]
Name=RTA Tools Validation
Comment=Validate RTA security tools installation
Exec=x-terminal-emulator -e "sudo $SCRIPTS_DIR/validate-tools.sh"
Terminal=true
Type=Application
Icon=security-high
Categories=RTA;Security;
EOL
      
      # Create RTA deployment entry for re-installation
      cat > "/usr/share/applications/rta-deploy.desktop" << EOL
[Desktop Entry]
Name=RTA Tools Deployment
Comment=Re-deploy or update RTA tools
Exec=x-terminal-emulator -e "sudo $DEPLOY_DIR/deploy-rta.sh --interactive"
Terminal=true
Type=Application
Icon=system-software-update
Categories=RTA;System;
EOL
    fi
  fi
  
  # Network configuration if needed
  local disable_ipv6=$(get_config_value "$CONFIG_FILE" "tool_settings.network.disable_ipv6" "false")
  if [[ "$disable_ipv6" = "true" ]]; then
    log "STATUS" "Disabling IPv6..."
    
    # Disable IPv6 via sysctl
    cat > "/etc/sysctl.d/99-disable-ipv6.conf" << EOL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOL
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || {
      log "WARNING" "Failed to apply IPv6 disable settings"
    }
  fi
  
  log "SUCCESS" "System configuration completed"
  return 0
}

# Function to create system snapshot
create_system_snapshot() {
  log "HEADER" "Creating system snapshot..."
  
  mkdir -p "$SYSTEM_STATE_DIR"
  local snapshot_file="$SYSTEM_STATE_DIR/snapshot-$(date +%Y%m%d-%H%M%S).txt"
  
  {
    echo "=== SYSTEM SNAPSHOT ==="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo ""
    echo "=== INSTALLED TOOLS ==="
    if [[ -x "$SCRIPTS_DIR/validate-tools.sh" ]]; then
      "$SCRIPTS_DIR/validate-tools.sh" --essential-only 2>/dev/null | grep -E '^\[|\+|\-|\!]' | sed 's/^/  /'
    else
      echo "  Validation script not found"
    fi
    echo ""
    echo "=== DISK SPACE ==="
    df -h
    echo ""
    echo "=== MEMORY USAGE ==="
    free -h
    echo ""
    echo "=== NETWORK CONFIGURATION ==="
    ip a | grep -E 'inet|^[0-9]'
    echo ""
    echo "=== PROCESS SUMMARY ==="
    ps aux | head -1
    ps aux | sort -rk 3,3 | head -10
    echo ""
    echo "=== SERVICE STATUS ==="
    systemctl list-units --type=service --state=running | head -20
  } > "$snapshot_file"
  
  log "SUCCESS" "System snapshot saved to: $snapshot_file"
  return 0
}

# Function to create summary
create_summary() {
  log "HEADER" "Creating deployment summary..."
  
  local summary_file="$SUMMARY_FILE"
  
  {
    echo "==================================================================="
    echo "                RTA DEPLOYMENT SUMMARY"
    echo "==================================================================="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Script Version: $VERSION"
    echo ""
    echo "=== INSTALLATION RESULTS ==="
    grep -E "^\[[0-9]{4}-[0-9]{2}-[0-9]{2}.*STATUS\]|^\[[0-9]{4}-[0-9]{2}-[0-9]{2}.*SUCCESS\]|^\[[0-9]{4}-[0-9]{2}-[0-9]{2}.*ERROR\]" "$MAIN_LOG" | \
      sed 's/\[[0-9-]\{10\} [0-9:]\{8\}\] \[\([A-Z]*\)\] /[\1] /'
    echo ""
    echo "=== INSTALLED TOOLS ==="
    if [[ -x "$SCRIPTS_DIR/validate-tools.sh" ]]; then
      "$SCRIPTS_DIR/validate-tools.sh" --essential-only 2>/dev/null | grep -E '^\[\+\]|^\[\!\]|^\[\-\]' | sed 's/^/  /'
    else
      echo "  Validation script not found"
    fi
    echo ""
    echo "=== MANUAL TOOLS ==="
    echo "The following tools require manual installation or activation:"
    find "$HELPERS_DIR" "$SCRIPTS_DIR" -name "install_*.sh" 2>/dev/null | \
      sed 's/^.*install_\(.*\)\.sh$/  - \1/' | sort -u
    echo ""
    echo "To install these tools, run: sudo <path_to_script>/install_<tool_name>.sh"
    echo ""
    echo "=== NEXT STEPS ==="
    echo "1. Run validation to check tool installation: sudo $SCRIPTS_DIR/validate-tools.sh"
    echo "2. Install any missing tools using the relevant installation helpers"
    echo "3. Customize your environment as needed"
    echo ""
    echo "For issues, please contact the security team or submit a bug report."
    echo "==================================================================="
  } > "$summary_file"
  
  log "SUCCESS" "Deployment summary saved to: $summary_file"
  
  # Create a desktop shortcut to the summary
  if [[ -d "/usr/share/applications" ]]; then
    cat > "/usr/share/applications/rta-deployment-summary.desktop" << EOF
[Desktop Entry]
Name=RTA Deployment Summary
Exec=xdg-open $summary_file
Type=Application
Icon=document-properties
Terminal=false
Categories=Utility;Security;
EOF
  fi
  
  return 0
}

# Function to cleanup before exit
cleanup() {
  local exit_code=$?
  
  log "STATUS" "Performing cleanup..."
  
  # Kill any background processes
  jobs -p | xargs -r kill &>/dev/null
  
  # Remove temporary files
  rm -rf "$TEMP_DIR"/* 2>/dev/null || true
  
  # Create summary if we haven't exited early
  if [[ -d "$DEPLOY_DIR" && -d "$TOOLS_DIR" && $exit_code -ne 4 ]]; then
    create_summary || log "WARNING" "Failed to create summary"
  fi
  
  # Final message
  if [[ $exit_code -eq 0 ]]; then
    log "HEADER" "Deployment completed successfully!"
  elif [[ $exit_code -eq 130 ]]; then
    log "WARNING" "Deployment interrupted by user"
  elif [[ $exit_code -eq 4 ]]; then
    log "WARNING" "Deployment aborted by user"
  else
    log "ERROR" "Deployment encountered errors (code $exit_code)"
    log "INFO" "Check logs at $MAIN_LOG for details"
  fi
  
  # Display final message on console
  if [[ $exit_code -eq 0 ]]; then
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}                RTA DEPLOYMENT COMPLETED SUCCESSFULLY               ${NC}"
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "\n${BLUE}[i] Installation logs saved to: ${YELLOW}$LOG_DIR${NC}"
    echo -e "${BLUE}[i] Summary report saved to: ${YELLOW}$SUMMARY_FILE${NC}"
    echo -e "${BLUE}[i] Run validation with: ${YELLOW}sudo $SCRIPTS_DIR/validate-tools.sh${NC}"
    
    # Show manual tool instructions
    local manual_tools=$(find "$HELPERS_DIR" "$SCRIPTS_DIR" -name "install_*.sh" 2>/dev/null)
    if [[ -n "$manual_tools" ]]; then
      echo -e "\n${YELLOW}[!] The following tools require manual installation:${NC}"
      echo "$manual_tools" | sed 's/^.*install_\(.*\)\.sh$/  - \1/' | sort -u
      echo -e "${BLUE}[i] To install these tools, run the corresponding helper scripts${NC}"
    fi
    
    echo -e "\n${BLUE}[i] A reboot is recommended to complete setup${NC}"
  else
    echo -e "\n${RED}==================================================================${NC}"
    echo -e "${RED}                RTA DEPLOYMENT ENCOUNTERED ERRORS                  ${NC}"
    echo -e "${RED}==================================================================${NC}"
    echo -e "\n${BLUE}[i] Check logs for details: ${YELLOW}$MAIN_LOG${NC}"
    echo -e "${YELLOW}[!] To retry deployment, run: ${CYAN}sudo $0 --auto${NC}"
  fi
}

# Interactive prompt
prompt_yes_no() {
  local question="$1"
  local default_yes="$2"
  
  if $AUTO_MODE; then
    # Auto mode always returns yes
    return 0
  fi
  
  local prompt
  if [[ "$default_yes" = "true" ]]; then
    prompt="${question} [Y/n] "
  else
    prompt="${question} [y/N] "
  fi
  
  read -p "$prompt" response
  
  if [[ "$default_yes" = "true" ]]; then
    # Default is yes
    if [[ "$response" =~ ^[nN](o)?$ ]]; then
      return 1
    else
      return 0
    fi
  else
    # Default is no
    if [[ "$response" =~ ^[yY](es)?$ ]]; then
      return 0
    else
      return 1
    fi
  fi
}

# Function to prompt for continuation
prompt_continue() {
  local message="$1"
  
  if $AUTO_MODE; then
    # Auto mode always continues
    return 0
  fi
  
  echo ""
  if ! prompt_yes_no "Do you want to $message?" "true"; then
    log "INFO" "User chose to skip: $message"
    return 1
  fi
  
  return 0
}

# Function to display banner
display_banner() {
  local width=70
  
  echo -e "${CYAN}"
  echo "=================================================================="
  echo "          ENHANCED KALI LINUX RTA DEPLOYMENT v$VERSION            "
  echo "=================================================================="
  echo -e "${NC}"
  echo -e "${BLUE}A robust, automated deployment system for security testing appliances${NC}"
  echo -e "${BLUE}Supports comprehensive installation with error handling and recovery${NC}"
  echo ""
}

# Parse command-line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --auto)
        AUTO_MODE=true
        log "INFO" "Running in auto mode"
        shift
        ;;
      --verbose)
        VERBOSE=true
        log "INFO" "Running in verbose mode"
        shift
        ;;
      --force-reinstall)
        FORCE_REINSTALL=true
        log "INFO" "Force reinstall enabled"
        shift
        ;;
      --skip-downloads)
        SKIP_DOWNLOADS=true
        log "INFO" "Skipping downloads"
        shift
        ;;
      --skip-update)
        SKIP_UPDATE=true
        log "INFO" "Skipping APT update"
        shift
        ;;
      --core-only)
        CORE_TOOLS_ONLY=true
        FULL_INSTALL=false
        log "INFO" "Installing core tools only"
        shift
        ;;
      --desktop-only)
        DESKTOP_ONLY=true
        FULL_INSTALL=false
        log "INFO" "Setting up desktop environment only"
        shift
        ;;
      --interactive)
        AUTO_MODE=false
        log "INFO" "Running in interactive mode"
        shift
        ;;
      --reinstall-failed)
        FORCE_REINSTALL=true
        # TODO: Implement reinstalling only failed tools
        log "INFO" "Reinstalling failed tools"
        shift
        ;;
      --repo)
        shift
        if [[ $# -gt 0 ]]; then
          GITHUB_REPO_URL="$1"
          log "INFO" "Using custom repository: $GITHUB_REPO_URL"
          shift
        else
          log "ERROR" "No repository URL provided"
          exit 1
        fi
        ;;
      --help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  --auto                Run in fully automated mode without prompts"
        echo "  --verbose             Show detailed output during installation"
        echo "  --force-reinstall     Force reinstallation of all tools"
        echo "  --skip-downloads      Skip downloading external resources"
        echo "  --skip-update         Skip APT repository update"
        echo "  --core-only           Install core tools only"
        echo "  --desktop-only        Set up desktop environment only"
        echo "  --interactive         Run in interactive mode with prompts"
        echo "  --reinstall-failed    Reinstall only tools that failed validation"
        echo "  --repo URL            Use a specific GitHub repository URL"
        echo "  --help                Show this help message"
        exit 0
        ;;
      *)
        log "ERROR" "Unknown option: $1"
        echo "Usage: $0 [OPTIONS]"
        echo "Run '$0 --help' for more information"
        exit 1
        ;;
    esac
  done
}

# Main function
main() {
  # Step 1: Initialize
  display_banner
  mkdir -p "$LOG_DIR"
  log "HEADER" "Starting RTA deployment (version $VERSION)"
  log "INFO" "Log file: $MAIN_LOG"
  
  # Step 2: Check if running as root
  if [[ "$EUID" -ne 0 ]]; then
    log "CRITICAL" "This script must be run as root"
    echo -e "${RED}[✗] This script must be run as root${NC}"
    echo -e "${YELLOW}[!] Please run again with sudo:${NC} sudo $0 $ORIGINAL_ARGS"
    exit 1
  }
  
  # Step 3: Check dependencies
  if ! check_dependencies; then
    log "CRITICAL" "Failed to install required dependencies"
    exit 1
  fi
  
  # Step 4: Check system resources
  check_system_resources || {
    log "WARNING" "System resource check raised concerns"
    # Continue anyway as the user was prompted
  }
  
  # Step 5: Create required directories
  create_directories || {
    log "CRITICAL" "Failed to create required directories"
    exit 1
  }
  
  # Step 6: Clone or update repository
  if prompt_continue "set up the installation repository"; then
    setup_repository || {
      log "WARNING" "Failed to properly set up the repository, continuing with local files"
    }
  fi
  
  # Step 7: Backup and ensure configuration
  backup_config
  ensure_config || {
    log "CRITICAL" "Failed to create configuration"
    exit 1
  }
  
  # Step 8: Install packages based on mode
  if $DESKTOP_ONLY; then
    log "STATUS" "Performing desktop-only installation..."
    if prompt_continue "configure desktop environment"; then
      configure_system || log "WARNING" "Desktop configuration encountered some issues"
    }
  elif $CORE_TOOLS_ONLY; then
    log "STATUS" "Installing core tools only..."
    
    # Get core tools list from config
    local core_tools=$(get_config_value "$CONFIG_FILE" "apt_tools" "nmap,wireshark,sqlmap,hydra,metasploit-framework")
    
    if prompt_continue "install core tools"; then
      install_apt_packages "$core_tools" || log "WARNING" "Some core APT tools failed to install"
      
      # Install core PIPX tools
      local core_pipx=$(get_config_value "$CONFIG_FILE" "pipx_tools" "impacket")
      install_pipx_packages "$core_pipx" || log "WARNING" "Some core PIPX tools failed to install"
    }
  else
    # Full installation
    log "STATUS" "Performing full installation..."
    
    # Step 8.1: Install APT packages
    if prompt_continue "install APT packages"; then
      # Get APT tools list from config
      local apt_tools=$(get_config_value "$CONFIG_FILE" "apt_tools" "")
      
      if [[ -n "$apt_tools" ]]; then
        install_apt_packages "$apt_tools" || log "WARNING" "Some APT tools failed to install"
      else
        log "INFO" "No APT tools specified in configuration"
      }
    }
    
    # Step 8.2: Install PIPX packages
    if prompt_continue "install PIPX packages"; then
      # Get PIPX tools list from config
      local pipx_tools=$(get_config_value "$CONFIG_FILE" "pipx_tools" "")
      
      if [[ -n "$pipx_tools" ]]; then
        install_pipx_packages "$pipx_tools" || log "WARNING" "Some PIPX tools failed to install"
      else
        log "INFO" "No PIPX tools specified in configuration"
      }
    }
    
    # Step 8.3: Install Git repositories
    if prompt_continue "install Git repositories"; then
      # Get Git tools list from config
      local git_tools=$(get_config_value "$CONFIG_FILE" "git_tools" "")
      
      if [[ -n "$git_tools" ]]; then
        install_git_repos "$git_tools" || log "WARNING" "Some Git repositories failed to install"
      else
        log "INFO" "No Git repositories specified in configuration"
      }
    }
    
    # Step 8.4: Run manual tool installation helpers
    if prompt_continue "install manual tools"; then
      # Read manual tools list from config
      local manual_tools=$(get_config_value "$CONFIG_FILE" "manual_tools" "")
      
      if [[ -n "$manual_tools" ]]; then
        run_installation_helpers "$manual_tools" || log "WARNING" "Some manual tools failed to install"
      else
        log "INFO" "No manual tools specified in configuration"
      }
    }
    
    # Step 8.5: Configure system
    if prompt_continue "configure system settings"; then
      configure_system || log "WARNING" "System configuration encountered some issues"
    }
  }
  
  # Step 9: Create system snapshot
  if prompt_continue "create system snapshot"; then
    create_system_snapshot || log "WARNING" "Failed to create system snapshot"
  }
  
  # Step 10: Run validation
  if prompt_continue "validate tool installation"; then
    if [[ -x "$SCRIPTS_DIR/validate-tools.sh" ]]; then
      run_safely "$SCRIPTS_DIR/validate-tools.sh" "Validating tool installation" "$SHORT_TIMEOUT" && {
        log "SUCCESS" "Tool validation completed successfully"
      } || {
        log "WARNING" "Some tools failed validation, check the report for details"
      }
    else
      log "WARNING" "Validation script not found at $SCRIPTS_DIR/validate-tools.sh"
    }
  }
  
  # Step 11: Final steps
  log "SUCCESS" "RTA deployment completed successfully"
  return 0
}

# Store original arguments for error messages
ORIGINAL_ARGS="$*"

# Parse arguments and run main function
parse_arguments "$@"
main
exit 0
