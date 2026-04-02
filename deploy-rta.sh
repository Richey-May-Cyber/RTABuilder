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
readonly REFERENCE_SRC="${REFERENCE_SRC:-/opt/rta-deployment/referencestuff}"
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
GITHUB_REPO_URL="https://github.com/yourusername/rta-deployment.git"

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
# REFERENCE FILES DEPLOYMENT
################################################################################

deploy_reference_files() {
    log "HEADER" "Deploying reference files..."

    if [[ ! -d "$REFERENCE_SRC" ]]; then
        log "WARNING" "Reference source directory not found: $REFERENCE_SRC"
        return 0
    fi

    if $DRY_RUN; then
        log "STATUS" "[DRY-RUN] Would copy reference files from $REFERENCE_SRC to $REFERENCE_DST"
        return 0
    fi

    mkdir -p "$REFERENCE_DST"

    if cp -r "${REFERENCE_SRC}"/* "$REFERENCE_DST/" 2>/dev/null; then
        chmod -R 755 "$REFERENCE_DST" 2>/dev/null || true
        log "SUCCESS" "Reference files deployed to $REFERENCE_DST"
    else
        log "WARNING" "Failed to deploy reference files"
        return 1
    fi

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

        # Reference files
        if prompt_yes_no "Deploy reference files"; then
            deploy_reference_files || log "WARNING" "Reference file deployment had issues"
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
