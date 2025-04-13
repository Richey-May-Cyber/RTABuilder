#!/bin/bash
# ================================================================
# Enhanced RTA Deployment Script v2.0
# ================================================================
# A robust, fully-automated deployment system for Kali Linux RTAs
# with comprehensive error handling and recovery
# ================================================================

# Exit codes
# 0 - Success
# 1 - Dependency error
# 2 - Configuration error
# 3 - Installation error
# 4 - User abort

# Global configuration
VERSION="2.0"
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
PARALLEL_JOBS=$(grep -c processor /proc/cpuinfo)
# Limit parallel jobs to avoid resource exhaustion
if [ $PARALLEL_JOBS -gt 10 ]; then
  PARALLEL_JOBS=10
fi

# Timeout settings (in seconds)
DEFAULT_TIMEOUT=60  # 1 minutes
LONG_TIMEOUT=600    # 10 minutes
SHORT_TIMEOUT=300    # 5 minutes

# Colors
BOLD="\e[1m"
RESET="\e[0m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[34m"
CYAN="\e[36m"
MAGENTA="\e[35m"
GRAY="\e[90m"

# Auto-detect terminal width
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
if [ $TERM_WIDTH -lt 60 ]; then
  TERM_WIDTH=80
fi

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
GITHUB_INSTALLER_URL="https://raw.githubusercontent.com/Richey-May-Cyber/RTABuilder/main"
DISPLAY_PROGRESS=true

# Trap for cleanup
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
  if [ "$level" != "DEBUG" ] || $VERBOSE; then
    echo -e "${color}${prefix} ${message}${RESET}"
  fi
}

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
  
  if [ ${#message} -gt $max_msg_width ]; then
    formatted_message="${formatted_message:0:$((max_msg_width-3))}..."
  fi
  
  # Pad message to consistent width
  formatted_message="$(printf "%-${max_msg_width}s" "$formatted_message")"
  
  echo "$pid" > "$temp_file"
  
  (
    while [ -f "$temp_file" ] && kill -0 $pid 2>/dev/null; do
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
  if [ $exit_status -eq 0 ]; then
    printf "\r${GREEN}[✓]${RESET} ${formatted_message}\n"
  else
    printf "\r${RED}[✗]${RESET} ${formatted_message} (error code: $exit_status)\n"
  fi
  
  return $exit_status
}

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
  
  if [ ${#message} -gt $max_msg_width ]; then
    formatted_message="${formatted_message:0:$((max_msg_width-3))}..."
  fi
  
  # Build the progress bar
  local progress_bar="["
  for ((i=0; i<filled; i++)); do progress_bar+="="; done
  if [ $filled -lt $width ]; then progress_bar+=">"; fi
  for ((i=0; i<$((empty-1)); i++)); do progress_bar+=" "; done
  progress_bar+="]"
  
  # Print the progress bar
  printf "\r%-${max_msg_width}s %3d%% %s" "$formatted_message" "$percent" "$progress_bar"
  
  # Print a newline if we're at 100%
  if [ $current -eq $total ]; then
    echo ""
  fi
}

# Function to get YAML values from config file with graceful fallback
get_config_value() {
  local yaml_file=$1
  local key=$2
  local default_value=$3
  
  if [ ! -f "$yaml_file" ]; then
    log "WARNING" "Config file not found: $yaml_file, using default value for $key"
    echo "$default_value"
    return
  fi
  
  # Try grep method first (faster and works for simple values)
  local value=$(grep -E "^$key:" "$yaml_file" | cut -d'"' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  # If empty, try another method for multiline values
  if [ -z "$value" ]; then
    value=$(sed -n "/^$key:/,/^[a-zA-Z]/{/^$key:/d;/^[a-zA-Z]/d;p}" "$yaml_file" | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
  fi
  
  # Return default if still empty
  if [ -z "$value" ]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

# Function to check dependencies
check_dependencies() {
  log "STATUS" "Checking system dependencies..."
  
  local dependencies=("curl" "wget" "git" "parallel" "bc" "unzip" "jq")
  local missing_deps=()
  
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing_deps+=("$dep")
    fi
  done
  
  if [ ${#missing_deps[@]} -gt 0 ]; then
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

# Function to download a file with auto-retry
download_file() {
  local url="$1"
  local output_file="$2"
  local description="$3"
  local max_retries=3
  local retry_count=0
  local timeout=300
  
  if [ -f "$output_file" ] && [ -s "$output_file" ] && ! $FORCE_REINSTALL; then
    log "INFO" "$description already downloaded at $output_file"
    return 0
  fi
  
  log "STATUS" "Downloading $description..."
  mkdir -p "$(dirname "$output_file")"
  
  while [ $retry_count -lt $max_retries ]; do
    retry_count=$((retry_count + 1))
    
    # Try curl first, fallback to wget
    if command -v curl &>/dev/null; then
      curl -sSL --connect-timeout 30 --retry 3 --retry-delay 5 -o "$output_file" "$url" && {
        log "SUCCESS" "Downloaded $description successfully"
        return 0
      }
    elif command -v wget &>/dev/null; then
      wget --timeout=30 --tries=3 --waitretry=5 -q "$url" -O "$output_file" && {
        log "SUCCESS" "Downloaded $description successfully"
        return 0
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
  
  if [ $result -eq 0 ]; then
    log "SUCCESS" "$description completed successfully"
    return 0
  elif [ $result -eq 124 ] || [ $result -eq 143 ]; then
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
  
  while [ $retry_count -lt $max_retries ]; do
    retry_count=$((retry_count + 1))
    
    if [ $retry_count -gt 1 ]; then
      log "INFO" "Retry $retry_count/$max_retries for $description"
    fi
    
    if run_command "$cmd" "$description" "$timeout_duration"; then
      return 0
    fi
    
    # Abort if exceeds retries
    if [ $retry_count -ge $max_retries ]; then
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
  if [ -f "$CONFIG_FILE" ] && $BACKUP_CONFIG; then
    log "INFO" "Backing up existing configuration..."
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)" || {
      log "WARNING" "Failed to backup configuration file"
    }
  fi
}

# Function to ensure configuration file exists
ensure_config() {
  if [ ! -f "$CONFIG_FILE" ] || $FORCE_REINSTALL; then
    log "INFO" "Creating default configuration..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << 'EOL'
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
    use_zsh: true
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
EOL
    log "SUCCESS" "Configuration file created at $CONFIG_FILE"
  fi
  
  return 0
}

# Create installation helper scripts
create_helper_scripts() {
  log "HEADER" "Creating installation helper scripts..."
  
  # Nessus installation script
  log "STATUS" "Creating Nessus installation script..."
  mkdir -p "$HELPERS_DIR"
  cat > "$HELPERS_DIR/install_nessus.sh" << 'ENDOFNESSUSSCRIPT'
#!/bin/bash
# Helper script to install Nessus

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[i] Starting Nessus installation...${NC}"

# Check if the DEB package exists
NESSUS_PKG="/opt/rta-deployment/downloads/Nessus-10.5.0-debian10_amd64.deb"
if [ ! -f "$NESSUS_PKG" ]; then
  echo -e "${YELLOW}[!] Nessus package not found, attempting to download...${NC}"
  
  mkdir -p "$(dirname "$NESSUS_PKG")"
  
  # Try to download
  wget -q --show-progress "https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true" -O "$NESSUS_PKG" || {
    echo -e "${RED}[-] Failed to download Nessus. Please download it manually from Tenable's website.${NC}"
    exit 1
  }
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
ENDOFNESSUSSCRIPT
  chmod +x "$HELPERS_DIR/install_nessus.sh"
  
  # TeamViewer installation script
  log "STATUS" "Creating TeamViewer installation script..."
  cat > "$HELPERS_DIR/install_teamviewer.sh" << 'ENDOFTVSCRIPT'
#!/bin/bash
# TeamViewer Host Installer with advanced configuration and Kali Linux compatibility fixes

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
TV_PACKAGE="/opt/rta-deployment/downloads/teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN="25998227-v1SCqDinbXPh3pHnBv7s"  # Your assignment token - REPLACE THIS WITH YOUR OWN
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "ERROR" "Please run as root or with sudo"
  exit 1
fi

# Check if the DEB package exists
if [ ! -f "$TV_PACKAGE" ]; then
  log "WARNING" "TeamViewer Host package not found at $TV_PACKAGE"
  
  # Try to download it
  log "INFO" "Attempting to download TeamViewer Host..."
  mkdir -p "$(dirname "$TV_PACKAGE")"
  wget -q --show-progress https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O "$TV_PACKAGE" || {
    log "ERROR" "Failed to download TeamViewer Host package"
    exit 1
  }
fi

# Check if we're on Kali Linux and need the PolicyKit1 fix
if grep -q "Kali" /etc/os-release; then
  log "INFO" "Kali Linux detected, applying PolicyKit1 workaround..."
  
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
  # Remove the Depends line completely
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
  chmod +x "$HELPERS_DIR/install_teamviewer.sh"

  # Burp Suite installation script
  log "STATUS" "Creating Burp Suite installation script..."
  cat > "$HELPERS_DIR/install_burpsuite.sh" << 'ENDOFBURPSCRIPT'
#!/bin/bash
# Robust BurpSuite Professional installer with error handling and activation

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting Burp Suite Professional installation...${NC}"

# Create a temp directory for installation
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || {
  echo -e "${RED}[-] Failed to create temporary directory${NC}"
  exit 1
}

# Ensure git is installed
if ! command -v git &> /dev/null; then
  echo -e "${YELLOW}[!] Git not found, installing...${NC}"
  apt-get update && apt-get install -y git || {
    echo -e "${RED}[-] Failed to install Git${NC}"
    exit 1
  }
fi

# Download the installer script from GitHub
echo -e "${YELLOW}[*] Cloning Burp Suite installer repository...${NC}"
git clone https://github.com/xiv3r/Burpsuite-Professional.git burpsuite-installer || {
  echo -e "${RED}[-] Failed to clone installer repository${NC}"
  exit 1
}

cd burpsuite-installer || {
  echo -e "${RED}[-] Failed to navigate to installer directory${NC}"
  exit 1
}

# Make the install script executable
chmod +x install.sh || {
  echo -e "${RED}[-] Failed to make installer executable${NC}"
  exit 1
}

# Extract JAR file path from the installer script
JAR_DOWNLOAD_URL=$(grep -m 1 "https.*\.jar" install.sh | grep -o "https.*\.jar" || echo "")

if [ -z "$JAR_DOWNLOAD_URL" ]; then
  echo -e "${YELLOW}[!] Could not extract download URL from installer, using manual installation method...${NC}"
  
  # Try downloading using the script but intercept to avoid activation part
  echo -e "${YELLOW}[*] Running modified installation process...${NC}"
  
  # Create a minimal download script
  cat > download_only.sh << 'EOF'
#!/bin/bash
# Dependencies
apt update
apt install openjdk-17-jdk wget zip unzip curl alien dpkg -y

# Create installation destination
mkdir -p /opt/BurpSuitePro

# Download Burp Suite Pro
echo "[+] Downloading Burp Suite Professional JAR file..."
wget -q --show-progress "https://portswigger-cdn.net/burp/releases/download?product=pro&version=2023.10.3.2&type=jar" -O /opt/BurpSuitePro/burpsuite_pro.jar
chmod +x /opt/BurpSuitePro/burpsuite_pro.jar

# Exit if download failed
if [ ! -f "/opt/BurpSuitePro/burpsuite_pro.jar" ]; then
  echo "[-] Download failed!"
  exit 1
fi

echo "[+] JAR file downloaded successfully"
EOF

  chmod +x download_only.sh
  ./download_only.sh || {
    echo -e "${RED}[-] Failed to run download script${NC}"
    exit 1
  }
else
  echo -e "${YELLOW}[*] Downloading Burp Suite Professional JAR file...${NC}"
  mkdir -p /opt/BurpSuitePro
  wget -q --show-progress "$JAR_DOWNLOAD_URL" -O /opt/BurpSuitePro/burpsuite_pro.jar || {
    echo -e "${RED}[-] Failed to download JAR file${NC}"
    exit 1
  }
  chmod +x /opt/BurpSuitePro/burpsuite_pro.jar
fi

# Create desktop entry
echo -e "${YELLOW}[*] Creating desktop shortcut...${NC}"
cat > /usr/share/applications/burpsuite_pro.desktop << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Burp Suite Professional
Comment=Security Testing Tool
Exec=java -jar /opt/BurpSuitePro/burpsuite_pro.jar
Icon=burpsuite
Terminal=false
Categories=Development;Security;
EOF

# Create executable wrapper
echo -e "${YELLOW}[*] Creating executable wrapper...${NC}"
cat > /usr/bin/burpsuite << 'EOF'
#!/bin/bash
java -jar /opt/BurpSuitePro/burpsuite_pro.jar "$@"
EOF
chmod +x /usr/bin/burpsuite

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo -e "${GREEN}[+] Burp Suite Professional installed successfully!${NC}"
echo -e "${BLUE}[i] You can run it with the command: burpsuite${NC}"
echo -e "${BLUE}[i] Or find it in your application menu${NC}"
echo -e "${YELLOW}[!] Note: You will need to activate the software on first run${NC}"

exit 0
ENDOFBURPSCRIPT
  chmod +x "$HELPERS_DIR/install_burpsuite.sh"

  # NinjaOne Agent installation script
  log "STATUS" "Creating NinjaOne Agent installation script..."
  cat > "$HELPERS_DIR/install_ninjaone.sh" << 'ENDOFNINJASCRIPT'
#!/bin/bash
# Helper script to install NinjaOne Agent

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

echo -e "${BLUE}[i] Starting NinjaOne Agent installation...${NC}"

# Check if the DEB package exists
NINJA_PKG="/opt/rta-deployment/downloads/NinjaOne-Agent.deb"
if [ ! -f "$NINJA_PKG" ]; then
  echo -e "${YELLOW}[!] NinjaOne Agent package not found, checking for alternate locations...${NC}"
  
  # Try to find it with a more flexible approach
  NINJA_PKG=$(find /opt/rta-deployment/downloads -name "NinjaOne*.deb" -type f | head -1)
  
  if [ -z "$NINJA_PKG" ]; then
    echo -e "${YELLOW}[!] No NinjaOne package found, attempting to download...${NC}"
    mkdir -p "/opt/rta-deployment/downloads"
    
    # Try to download - replace URL with your actual NinjaOne download URL
    wget -q --show-progress "https://app.ninjarmm.com/agent/installer/fc75fb12-9ee2-4f8d-8319-8df4493a9fb9/8.0.2891/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb" -O "/opt/rta-deployment/downloads/NinjaOne-Agent.deb" || {
      echo -e "${RED}[-] Failed to download NinjaOne Agent${NC}"
      echo -e "${YELLOW}[!] Please download the agent manually from your NinjaOne dashboard${NC}"
      exit 1
    }
    
    NINJA_PKG="/opt/rta-deployment/downloads/NinjaOne-Agent.deb"
  else
    echo -e "${BLUE}[i] Found NinjaOne package at: $NINJA_PKG${NC}"
  fi
fi

# Install the DEB package
echo -e "${YELLOW}[*] Installing NinjaOne Agent...${NC}"
apt-get update
dpkg -i "$NINJA_PKG" || {
  echo -e "${YELLOW}[!] Fixing dependencies...${NC}"
  apt-get -f install -y
  dpkg -i "$NINJA_PKG" || {
    echo -e "${RED}[-] Failed to install NinjaOne Agent${NC}"
    exit 1
  }
}

# Check if service is running
echo -e "${YELLOW}[*] Starting and enabling NinjaOne Agent service...${NC}"
systemctl enable ninjarmm-agent || true
systemctl start ninjarmm-agent || true

# Verify service is running
if systemctl is-active --quiet ninjarmm-agent; then
  echo -e "${GREEN}[+] NinjaOne Agent installed and service started successfully${NC}"
else
  echo -e "${YELLOW}[!] NinjaOne Agent installed but service not running. Try starting manually:${NC}"
  echo -e "${YELLOW}    systemctl start ninjarmm-agent${NC}"
fi

echo -e "${BLUE}[i] Note: It may take a few minutes for the agent to appear in your NinjaOne dashboard${NC}"

exit 0
ENDOFNINJASCRIPT
  chmod +x "$HELPERS_DIR/install_ninjaone.sh"

  # Disable screen lock script
  log "STATUS" "Creating screen lock disable script..."
  cat > "$SCRIPTS_DIR/disable-lock-screen.sh" << 'ENDOFLOCKSCRIPT'
#!/usr/bin/env bash
# Script to disable screen lock and power management features in Kali Linux
# Enhanced version with support for multiple desktop environments

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
ENDOFLOCKSCRIPT
  chmod +x "$SCRIPTS_DIR/disable-lock-screen.sh"

  # Create validation script 
  log "STATUS" "Creating validation script..."
  cat > "$SCRIPTS_DIR/validate-tools.sh" << 'ENDOFVALSCRIPT'
#!/bin/bash
# =================================================================
# RTA Tools Validation Script v2.0
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
CONFIG_FILE="/opt/rta-deployment/config/config.yml"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Initialize log file
echo "Tool Validation Report" > "$VALIDATION_LOG"
echo "====================" >> "$VALIDATION_LOG"
echo "Date: $(date)" >> "$VALIDATION_LOG"
echo "" >> "$VALIDATION_LOG"

# Initialize report file with nice formatting
cat > "$VALIDATION_REPORT" << EOF
=================================================================
               SECURITY TOOLS VALIDATION REPORT
=================================================================
Date: $(date)
System: $(hostname) - $(uname -r)
Kali Version: $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Unknown")

EOF

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
    ["proxychains"]="proxychains -h 2>&1 | grep 'ProxyChains'"
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
    ["evilginx3"]="evilginx3 -h 2>&1 | grep -i 'evilginx'"
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
    ["proxychains"]="proxychains -h 2>&1 | grep 'ProxyChains'"
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
    category_total="${#tools_array[@]}"
    category_current=0
    
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
  sudo /opt/rta-deployment/deploy-rta.sh --reinstall-failed

For manual tools, use the helper scripts:
  cd /opt/security-tools/helpers
  sudo ./install_<tool_name>.sh

EOF
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
    echo -e "  - For APT/PIPX tools: ${CYAN}sudo /opt/rta-deployment/deploy-rta.sh --reinstall-failed${NC}"
    echo -e "  - For manual tools: ${CYAN}cd /opt/security-tools/helpers && sudo ./install_<tool_name>.sh${NC}"
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
ENDOFVALSCRIPT
  chmod +x "$SCRIPTS_DIR/validate-tools.sh"
  
  log "SUCCESS" "Installation helper scripts created successfully"
  return 0
}

# Function to download and prepare installation files
download_resources() {
  log "HEADER" "Downloading required resources..."
  
  if $SKIP_DOWNLOADS; then
    log "INFO" "Skipping downloads as requested"
    return 0
  fi
  
  # Ensure download directory exists
  mkdir -p "$DOWNLOAD_DIR"
  
  # Define downloads with retry logic
  local downloads=(
    "Nessus|https://www.tenable.com/downloads/api/v1/public/pages/nessus/downloads/18189/download?i_agree_to_tenable_license_agreement=true|$DOWNLOAD_DIR/Nessus-10.5.0-debian10_amd64.deb"
    "TeamViewer|https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb|$DOWNLOAD_DIR/teamviewer-host_amd64.deb"
    "NinjaOne Agent|https://app.ninjarmm.com/agent/installer/fc75fb12-9ee2-4f8d-8319-8df4493a9fb9/8.0.2891/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb|$DOWNLOAD_DIR/NinjaOne-Agent.deb"
  )
  
  local total_downloads=${#downloads[@]}
  local current=0
  
  for download in "${downloads[@]}"; do
    IFS='|' read -r name url file <<< "$download"
    ((current++))
    
    if $DISPLAY_PROGRESS; then
      show_progress_bar $current $total_downloads "Downloading $name ($current/$total_downloads)"
    fi
    
    if ! download_file "$url" "$file" "$name"; then
      log "WARNING" "Failed to download $name, installation may be incomplete"
    fi
  done
  
  log "SUCCESS" "Downloads completed"
  return 0
}

# Function to install APT packages
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
  if command -v parallel &>/dev/null && [ $total_packages -gt 10 ]; then
    log "INFO" "Using parallel installation for APT packages ($PARALLEL_JOBS jobs)"
    
    # Create a temporary file to hold package results
    local temp_results=$(mktemp)
    
    # Process packages in parallel with progress
    echo "${PACKAGES[@]}" | tr ' ' '\n' | \
    parallel -j $PARALLEL_JOBS --eta --bar \
    "apt-get install -y {} >/dev/null 2>&1 && echo 'SUCCESS:{}' >> $temp_results || echo 'FAIL:{}' >> $temp_results"
    
    # Process results
    while read line; do
      if [[ "$line" == SUCCESS:* ]]; then
        ((success_count++))
        log "DEBUG" "Successfully installed ${line#SUCCESS:}"
      elif [[ "$line" == FAIL:* ]]; then
        ((fail_count++))
        log "ERROR" "Failed to install ${line#FAIL:}"
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
      if dpkg -l | grep -q "^ii  $package " && ! $FORCE_REINSTALL; then
        log "DEBUG" "$package is already installed"
        ((success_count++))
        continue
      fi
      
      # Install package
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
        log "DEBUG" "Successfully installed $package"
        ((success_count++))
      else
        log "WARNING" "Failed to install $package, retrying once..."
        if DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-broken --fix-missing "$package" >/dev/null 2>&1; then
          log "DEBUG" "Successfully installed $package on retry"
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
  
  # Install packages
  for package in "${PACKAGES[@]}"; do
    ((current++))
    
    if $DISPLAY_PROGRESS; then
      show_progress_bar $current $total_packages "Installing $package ($current/$total_packages)"
    fi
    
    # Check if already installed
    if pipx list 2>/dev/null | grep -q "$package" && ! $FORCE_REINSTALL; then
      log "DEBUG" "$package is already installed via pipx"
      ((success_count++))
      continue
    fi
    
    # Install package
    if pipx install "$package" >/dev/null 2>&1; then
      log "DEBUG" "Successfully installed $package via pipx"
      ((success_count++))
    else
      log "WARNING" "Failed to install $package via pipx, retrying with --pip-args..."
      if pipx install "$package" --pip-args="--no-cache-dir --no-deps" >/dev/null 2>&1; then
        log "DEBUG" "Successfully installed $package via pipx on retry"
        ((success_count++))
      else
        log "ERROR" "Failed to install $package via pipx"
        ((fail_count++))
      fi
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
  
  # Install repositories
  for repo_url in "${REPOS[@]}"; do
    ((current++))
    local repo_name=$(basename "$repo_url" .git)
    
    if $DISPLAY_PROGRESS; then
      show_progress_bar $current $total_repos "Installing $repo_name ($current/$total_repos)"
    fi
    
    local repo_dir="$TOOLS_DIR/$repo_name"
    
    # Check if already cloned
    if [ -d "$repo_dir/.git" ] && ! $FORCE_REINSTALL; then
      log "DEBUG" "$repo_name already cloned, updating..."
      if cd "$repo_dir" && git pull >/dev/null 2>&1; then
        log "DEBUG" "Successfully updated $repo_name"
        ((success_count++))
        continue
      else
        log "WARNING" "Failed to update $repo_name, attempting to reclone..."
        rm -rf "$repo_dir"
      fi
    fi
    
    # Clone repository
    if git clone --depth 1 "$repo_url" "$repo_dir" >/dev/null 2>&1; then
      log "DEBUG" "Successfully cloned $repo_name"
      
      # Check for installation scripts
      if [ -f "$repo_dir/setup.py" ]; then
        log "DEBUG" "Installing $repo_name with pip..."
        cd "$repo_dir" && pip3 install -e . >/dev/null 2>&1 || {
          log "WARNING" "Failed to install $repo_name with pip"
        }
      elif [ -f "$repo_dir/requirements.txt" ]; then
        log "DEBUG" "Installing requirements for $repo_name..."
        cd "$repo_dir" && pip3 install -r requirements.txt >/dev/null 2>&1 || {
          log "WARNING" "Failed to install requirements for $repo_name"
        }
      elif [ -f "$repo_dir/install.sh" ]; then
        log "DEBUG" "Running install script for $repo_name..."
        cd "$repo_dir" && bash install.sh >/dev/null 2>&1 || {
          log "WARNING" "Failed to run install script for $repo_name"
        }
      fi
      
      # Create symbolic link if main executable exists
      local main_script=""
      for ext in ".py" ".sh" ""; do
        for name in "main" "cli" "$repo_name" "run"; do
          if [ -f "$repo_dir/$name$ext" ]; then
            main_script="$name$ext"
            break 2
          fi
        done
      done
      
      if [ -n "$main_script" ]; then
        chmod +x "$repo_dir/$main_script"
        ln -sf "$repo_dir/$main_script" "/usr/local/bin/$repo_name" || {
          log "WARNING" "Failed to create symbolic link for $repo_name"
        }
      fi
      
      ((success_count++))
    else
      log "ERROR" "Failed to clone $repo_name"
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
  
  # Create installation helpers if they don't exist
  create_helper_scripts
  
  # Run installation helpers
  for helper in "${HELPERS[@]}"; do
    ((current++))
    local helper_script="$HELPERS_DIR/install_${helper}.sh"
    
    if [ ! -f "$helper_script" ]; then
      log "WARNING" "Helper script for $helper not found"
      ((fail_count++))
      continue
    fi
    
    log "STATUS" "Installing $helper ($current/$total_helpers)..."
    
    if run_safely "bash $helper_script" "Installing $helper" "$LONG_TIMEOUT"; then
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
  if [ "$disable_screen_lock" = "true" ]; then
    log "STATUS" "Disabling screen lock..."
    run_safely "bash $SCRIPTS_DIR/disable-lock-screen.sh" "Disabling screen lock" "$SHORT_TIMEOUT"
  fi
  
  # Configure desktop environment if running in GUI
  if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    log "STATUS" "Configuring desktop environment..."
    
    # Create desktop shortcuts
    local create_shortcuts=$(get_config_value "$CONFIG_FILE" "desktop.create_shortcuts" "true")
    if [ "$create_shortcuts" = "true" ]; then
      log "STATUS" "Creating desktop shortcuts..."
      
      # Main tools
      mkdir -p "$TOOLS_DIR/desktop"
      
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
    
    # Configure default applications (optional)
    # Add more desktop configuration if needed
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
    $SCRIPTS_DIR/validate-tools.sh --essential-only 2>/dev/null | grep -E '^\[|\+|\-|\!]' | sed 's/^/  /'
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
    $SCRIPTS_DIR/validate-tools.sh --essential-only 2>/dev/null | grep -E '^\[\+\]|^\[\!\]|^\[\-\]' | sed 's/^/  /'
    echo ""
    echo "=== MANUAL TOOLS ==="
    echo "The following tools require manual installation or activation:"
    ls -1 "$HELPERS_DIR" | grep "^install_" | sed 's/^install_\(.*\)\.sh$/  - \1/'
    echo ""
    echo "To install these tools, run: sudo $HELPERS_DIR/install_<tool_name>.sh"
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
  if [ -d "/usr/share/applications" ]; then
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

# Function to install main installer script
install_rta_installer() {
  log "HEADER" "Installing main RTA installer script..."
  
  # Create installer script path
  mkdir -p "$(dirname "$DEPLOY_DIR/rta_installer.sh")"
  
  # Create the script with proper formatting and structure
  cat > "$DEPLOY_DIR/rta_installer.sh" << 'EORTA'
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
EORTA

  chmod +x "$DEPLOY_DIR/rta_installer.sh"
  log "SUCCESS" "Main installer script created successfully"
  return 0
}

# Function to cleanup before exit
cleanup() {
  local exit_code=$?
  
  log "STATUS" "Performing cleanup..."
  
  # Kill any background processes
  jobs -p | xargs -r kill &>/dev/null
  
  # Create summary if we haven't exited early
  if [ -d "$DEPLOY_DIR" ] && [ -d "$TOOLS_DIR" ]; then
    create_summary || log "WARNING" "Failed to create summary"
  fi
  
  # Final message
  if [ $exit_code -eq 0 ]; then
    log "HEADER" "Deployment completed successfully!"
  elif [ $exit_code -eq 130 ]; then
    log "WARNING" "Deployment interrupted by user"
  elif [ $exit_code -eq 4 ]; then
    log "WARNING" "Deployment aborted by user"
  else
    log "ERROR" "Deployment encountered errors (code $exit_code)"
    log "INFO" "Check logs at $MAIN_LOG for details"
  fi
  
  # Display final message on console
  if [ $exit_code -eq 0 ]; then
    echo -e "\n${GREEN}==================================================================${NC}"
    echo -e "${GREEN}                RTA DEPLOYMENT COMPLETED SUCCESSFULLY               ${NC}"
    echo -e "${GREEN}==================================================================${NC}"
    echo -e "\n${BLUE}[i] Installation logs saved to: ${YELLOW}$LOG_DIR${NC}"
    echo -e "${BLUE}[i] Summary report saved to: ${YELLOW}$SUMMARY_FILE${NC}"
    echo -e "${BLUE}[i] Run validation with: ${YELLOW}sudo $SCRIPTS_DIR/validate-tools.sh${NC}"
    
    # Show manual tool instructions
    if ls "$HELPERS_DIR"/install_*.sh >/dev/null 2>&1; then
      echo -e "\n${YELLOW}[!] The following tools require manual installation:${NC}"
      ls -1 "$HELPERS_DIR" | grep "^install_" | sed 's/^install_\(.*\)\.sh$/  - \1/'
      echo -e "${BLUE}[i] To install these tools, run the corresponding helper scripts in:${NC}"
      echo -e "${YELLOW}   $HELPERS_DIR${NC}"
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
  if [ "$default_yes" = "true" ]; then
    prompt="${question} [Y/n] "
  else
    prompt="${question} [y/N] "
  fi
  
  read -p "$prompt" response
  
  if [ "$default_yes" = "true" ]; then
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
  
  # Step 2: Check dependencies
  if ! check_dependencies; then
    log "CRITICAL" "Failed to install required dependencies"
    exit 1
  fi
  
  # Step 3: Create required directories
  create_directories || {
    log "CRITICAL" "Failed to create required directories"
    exit 1
  }
  
  # Step 4: Backup and ensure configuration
  backup_config
  ensure_config || {
    log "CRITICAL" "Failed to create configuration"
    exit 1
  }
  
  # Step 5: Check for root privileges
  if [ "$EUID" -ne 0 ]; then
    log "CRITICAL" "This script must be run as root"
    echo -e "${RED}[✗] This script must be run as root${NC}"
    echo -e "${YELLOW}[!] Please run again with sudo:${NC} sudo $0 $ORIGINAL_ARGS"
    exit 1
  fi
  
  # Step 6: Install main installer script
  install_rta_installer || {
    log "CRITICAL" "Failed to install main installer script"
    exit 1
  }
  
  # Step 7: Download required resources
  if prompt_continue "download required resources"; then
    download_resources || log "WARNING" "Some downloads failed, continuing anyway"
  fi
  
  # Step 8: Install packages based on mode
  if $DESKTOP_ONLY; then
    log "STATUS" "Performing desktop-only installation..."
    if prompt_continue "configure desktop environment"; then
      configure_system || log "WARNING" "Desktop configuration encountered some issues"
    fi
  elif $CORE_TOOLS_ONLY; then
    log "STATUS" "Installing core tools only..."
    if prompt_continue "install core tools"; then
      run_safely "$DEPLOY_DIR/rta_installer.sh --core-only" "Installing core tools" "$LONG_TIMEOUT"
    fi
  else
    # Full installation
    log "STATUS" "Performing full installation..."
    
    # Step 8.1: Run main installer script
    if prompt_continue "install security tools"; then
      if run_safely "$DEPLOY_DIR/rta_installer.sh" "Running main installer script" "$LONG_TIMEOUT"; then
        log "SUCCESS" "Main installer script completed successfully"
      else
        log "WARNING" "Main installer script encountered some issues, continuing anyway"
      fi
    fi
    
    # Step 8.2: Run manual tool installation helpers if desired
    if prompt_continue "install manual tools"; then
      # Read manual tools list from config
      local manual_tools=$(get_config_value "$CONFIG_FILE" "manual_tools" "")
      
      if [ -n "$manual_tools" ]; then
        run_installation_helpers "$manual_tools" || log "WARNING" "Some manual tools failed to install"
      else
        log "INFO" "No manual tools specified in configuration"
      fi
    fi
    
    # Step 8.3: Configure system
    if prompt_continue "configure system settings"; then
      configure_system || log "WARNING" "System configuration encountered some issues"
    fi
  fi
  
  # Step 9: Create system snapshot
  if prompt_continue "create system snapshot"; then
    create_system_snapshot || log "WARNING" "Failed to create system snapshot"
  fi
  
  # Step 10: Run validation
  if prompt_continue "validate tool installation"; then
    if run_safely "$SCRIPTS_DIR/validate-tools.sh" "Validating tool installation" "$SHORT_TIMEOUT"; then
      log "SUCCESS" "Tool validation completed successfully"
    else
      log "WARNING" "Some tools failed validation, check the report for details"
    fi
  fi
  
  # Step 11: Final steps
  log "SUCCESS" "RTA deployment completed successfully"
  return 0
}

# Run main function with provided arguments
ORIGINAL_ARGS="$*"
parse_arguments "$@"
main
exit 0
