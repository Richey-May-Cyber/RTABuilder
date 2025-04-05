#!/bin/bash

# =====================================================================
# Improved Kali Linux Security Tools Installer for Remote Testing Appliances
# =====================================================================
# Description: Automated installer for security testing tools on Kali Linux RTA
# Usage: sudo ./rta_installer.sh [--full|--core-only|--desktop-only]
# =====================================================================

# Exit on error for most operations with cleaner error handling
set +e
trap cleanup EXIT

# =====================================================================
# CONFIGURATION AND CONSTANTS
# =====================================================================

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

# Files
CONFIG_FILE="$CONFIG_DIR/config.yml"
REPORT_FILE="$LOG_DIR/installation_report_$(date +%Y%m%d_%H%M%S).txt"

# Timeouts (in seconds)
GIT_CLONE_TIMEOUT=300
APT_INSTALL_TIMEOUT=600
PIP_INSTALL_TIMEOUT=300
BUILD_TIMEOUT=600

# Number of parallel jobs
PARALLEL_JOBS=$(nproc)

# Flags
FULL_INSTALL=false
CORE_ONLY=false
DESKTOP_ONLY=false
HEADLESS=false
VERBOSE=false

# =====================================================================
# UTILITY FUNCTIONS
# =====================================================================

# Logging and output functions
print_status() { echo -e "${YELLOW}[*] $1${NC}"; }
print_success() { echo -e "${GREEN}[+] $1${NC}"; }
print_error() { echo -e "${RED}[-] $1${NC}"; }
print_info() { echo -e "${BLUE}[i] $1${NC}"; }
print_debug() { if $VERBOSE; then echo -e "${CYAN}[D] $1${NC}"; fi; }

# Function to log results to the report file
log_result() {
    local status=$1
    local tool=$2
    local message=$3
    
    echo "[$status] $tool: $message" >> $REPORT_FILE
    print_debug "Logged: [$status] $tool: $message"
}

# Function to create directories if they don't exist
create_directories() {
    print_status "Creating directory structure..."
    mkdir -p $TOOLS_DIR $VENV_DIR $LOG_DIR $BIN_DIR $CONFIG_DIR $HELPERS_DIR $DESKTOP_DIR $TEMP_DIR
    print_success "Directory structure created."
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root"
        exit 1
    fi
}

# Function to cleanup on exit
cleanup() {
    print_status "Cleaning up temporary files..."
    # Clean up any temp files
    if [ -d "$TEMP_DIR" ]; then
        find "$TEMP_DIR" -type f -mtime +1 -delete
    fi
}

# Function to parse YAML file
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*'
    local w='[a-zA-Z0-9_]*'
    sed -ne "s|^$s\($w\)$s:$s\"\(.*\)\"$s\$|\1=\"\2\"|p" $1
}

# Function to show help message
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
  --full            Install all tools (default)
  --core-only       Install only core tools
  --desktop-only    Configure desktop shortcuts only
  --headless        Run in headless mode (no GUI dependencies)
  --verbose         Show debug messages
  --help            Display this help message and exit

EXAMPLES:
  $0 --full                  # Full installation
  $0 --core-only             # Core tools only
  $0 --desktop-only          # Configure desktop shortcuts only
  $0 --headless              # Headless installation
  $0 --verbose               # Verbose output
EOF
}

# Function to run commands with timeout protection
run_with_timeout() {
    local cmd="$1"
    local timeout_seconds=$2
    local log_file="$3"
    local tool_name="$4"
    
    print_debug "Running command with ${timeout_seconds}s timeout: $cmd"
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
}

# =====================================================================
# DESKTOP INTEGRATION
# =====================================================================

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
    
    print_status "Creating desktop shortcut for $name..."
    
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
    cp "/usr/share/applications/${name,,}.desktop" "$DESKTOP_DIR/${name,,}.desktop"
    
    print_success "Desktop shortcut created for $name."
}

# Function to create web shortcuts
create_web_shortcuts() {
    print_status "Creating web shortcuts..."
    
    # Create shortcuts for common web tools
    local web_tools=(
        "VirusTotal,https://www.virustotal.com/gui/home/search"
        "Fast People Search,https://www.fastpeoplesearch.com/names"
        "OSINT Framework,https://osintframework.com/"
        "Shodan,https://www.shodan.io/"
        "BuiltWith,https://builtwith.com/"
        "CVE Details,https://www.cvedetails.com/"
        "DNSDumpster,https://dnsdumpster.com/"
        "HaveIBeenPwned,https://haveibeenpwned.com/"
    )
    
    for tool in "${web_tools[@]}"; do
        IFS=',' read -r name url <<< "$tool"
        
        cat > "/usr/share/applications/${name,,}.desktop" << EOF
[Desktop Entry]
Name=$name
Exec=xdg-open $url
Type=Application
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
EOF
        
        # Also save a copy to our tools directory
        cp "/usr/share/applications/${name,,}.desktop" "$DESKTOP_DIR/${name,,}.desktop"
        
        print_info "Created shortcut for $name"
    done
    
    print_success "Web shortcuts created."
    log_result "SUCCESS" "web-shortcuts" "Created shortcuts for common web tools"
}

# Function to disable screen lock and power management
disable_screen_lock() {
    print_status "Disabling screen lock and power management..."
    
    # Create the disable-lock-screen script
    cat > "$TOOLS_DIR/scripts/disable-lock-screen.sh" << 'EOF'
#!/usr/bin/env bash
#
# disable-lock-screen.sh
#
# A more comprehensive script to disable screen lock & blanking in GNOME or Xfce on Kali.

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

echo "==> Remove GNOME or Xfce screensaver packages if still locking..."
echo "    sudo apt-get remove gnome-screensaver light-locker"
echo "==> Done! If it still locks, confirm you ran this script in your GUI user session."
EOF
    
    chmod +x "$TOOLS_DIR/scripts/disable-lock-screen.sh"
    
    # Run the script for the current user
    if [ -n "$SUDO_USER" ]; then
        print_status "Running disable-lock-screen.sh for $SUDO_USER..."
        su - $SUDO_USER -c "$TOOLS_DIR/scripts/disable-lock-screen.sh"
    else
        print_status "Running disable-lock-screen.sh..."
        bash "$TOOLS_DIR/scripts/disable-lock-screen.sh"
    fi
    
    print_success "Screen lock and power management disabled."
    log_result "SUCCESS" "screen-lock" "Disabled screen lock and power management"
}

# Function to set up environment
setup_environment() {
    print_status "Setting up environment..."
    
    # Create setup_env.sh script to be sourced
    cat > "$TOOLS_DIR/setup_env.sh" << 'EOF'
#!/bin/bash
# Source this file to set up environment variables and paths for all security tools

# Set up environment
export SECURITY_TOOLS_DIR="/opt/security-tools"
export PATH="$PATH:$SECURITY_TOOLS_DIR/bin"

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

echo "Security tools environment has been set up."
EOF
    
    chmod +x "$TOOLS_DIR/setup_env.sh"
    
    # Add to bash.bashrc for all users
    if ! grep -q "security-tools/setup_env.sh" /etc/bash.bashrc; then
        echo -e "\n# Security tools environment setup" >> /etc/bash.bashrc
        echo "[ -f /opt/security-tools/setup_env.sh ] && source /opt/security-tools/setup_env.sh" >> /etc/bash.bashrc
    fi
    
    print_success "Environment setup complete."
}

# =====================================================================
# INSTALLATION FUNCTIONS
# =====================================================================

# Function to set up a Python virtual environment for a tool
setup_venv() {
    local tool_name=$1
    print_debug "Setting up virtual environment for $tool_name..."
    
    if [ ! -d "$VENV_DIR/$tool_name" ]; then
        python3 -m venv "$VENV_DIR/$tool_name"
    fi
    
    # Activate the virtual environment
    source "$VENV_DIR/$tool_name/bin/activate"
    
    # Upgrade pip in the virtual environment
    pip install --upgrade pip
}

# Function to install an apt package with improved error handling and conflict resolution
install_apt_package() {
    local package_name=$1
    local conflicting_packages=$2  # Optional: comma-separated list
    local log_file="$LOG_DIR/${package_name}_apt_install.log"
    
    # Check if already installed
    if dpkg -l | grep -q "^ii  $package_name "; then
        print_info "$package_name already installed."
        log_result "SKIPPED" "$package_name" "Already installed"
        return 0
    fi
    
    print_status "Installing $package_name with apt..."
    
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
    run_with_timeout "apt-get install -y $package_name" $APT_INSTALL_TIMEOUT "$log_file" "$package_name"
    
    # Check if the package is installed regardless of timeout
    if dpkg -l | grep -q "^ii  $package_name "; then
        print_success "$package_name installed with apt."
        log_result "SUCCESS" "$package_name" "Installed with apt"
        return 0
    else
        print_error "Failed to install $package_name with apt."
        log_result "FAILED" "$package_name" "Apt installation failed. See $log_file for details."
        return 1
    fi
}

# Function to install multiple apt packages in parallel
install_apt_packages() {
    local packages=$1  # comma-separated list
    print_status "Installing apt packages: $packages"
    
    # Convert comma-separated list to array
    IFS=',' read -ra PKG_ARRAY <<< "$packages"
    
    # Install each package (can be parallelized with GNU Parallel if available)
    if command -v parallel &> /dev/null; then
        # Use parallel for faster installation
        printf '%s\n' "${PKG_ARRAY[@]}" | parallel -j$PARALLEL_JOBS "bash -c 'source $0; install_apt_package {}'" "$0"
    else
        # Fall back to sequential installation
        for pkg in "${PKG_ARRAY[@]}"; do
            install_apt_package "$pkg"
        done
    fi
}

# Function to install a tool using pipx with retry logic
install_with_pipx() {
    local package_name=$1
    local log_file="$LOG_DIR/${package_name}_pipx_install.log"
    
    print_status "Installing $package_name with pipx..."
    
    # Try up to 3 times with increasing timeouts
    for attempt in 1 2 3; do
        print_debug "Attempt $attempt of 3..."
        timeout $((120 * attempt)) pipx install $package_name >> $log_file 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "$package_name installed with pipx on attempt $attempt."
            log_result "SUCCESS" "$package_name" "Installed with pipx (attempt $attempt)"
            
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
        
        # Wait before retrying
        sleep 5
    done
    
    print_error "All attempts to install $package_name with pipx have failed."
    log_result "FAILED" "$package_name" "Pipx installation failed after 3 attempts. See $log_file for details."
    return 1
}

# Function to install multiple pipx packages with better parallelization
install_pipx_packages() {
    local packages=$1  # comma-separated list
    print_status "Installing pipx packages: $packages"
    
    # Convert comma-separated list to array
    IFS=',' read -ra PKG_ARRAY <<< "$packages"
    
    # Install each package (can be parallelized with GNU Parallel if available)
    if command -v parallel &> /dev/null; then
        # Use parallel for faster installation
        printf '%s\n' "${PKG_ARRAY[@]}" | parallel -j$PARALLEL_JOBS "bash -c 'source $0; install_with_pipx {}'" "$0"
    else
        # Fall back to sequential installation
        for pkg in "${PKG_ARRAY[@]}"; do
            install_with_pipx "$pkg"
        done
    fi
}

# Function to download binary and make executable with retry
download_binary() {
    local url=$1
    local output_file=$2
    local executable_name=$(basename $output_file)
    local log_file="$LOG_DIR/${executable_name}_download.log"
    
    print_status "Downloading $executable_name..."
    
    # Try up to 3 times
    for attempt in 1 2 3; do
        print_debug "Download attempt $attempt of 3..."
        timeout 180 wget $url -O $output_file >> $log_file 2>&1
        
        if [ $? -eq 0 ]; then
            chmod +x $output_file
            print_success "$executable_name downloaded and made executable."
            log_result "SUCCESS" "$executable_name" "Downloaded and made executable"
            return 0
        elif [ $? -eq 124 ]; then
            print_error "Download timed out on attempt $attempt."
            echo "Attempt $attempt timed out." >> $log_file
        else
            print_error "Download failed on attempt $attempt."
        fi
        
        # Wait before retrying
        sleep 5
    done
    
    print_error "All attempts to download $executable_name have failed."
    log_result "FAILED" "$executable_name" "Download failed after 3 attempts. See $log_file for details."
    return 1
}

# Function to install GitHub tool with improved error handling
install_github_tool() {
    local repo_url=$1
    local tool_name=$(basename $repo_url .git)
    local log_file="$LOG_DIR/${tool_name}_install.log"
    
    print_status "Installing $tool_name..."
    
    # Clone or update the repository
    if [ -d "$TOOLS_DIR/$tool_name" ]; then
        print_debug "$tool_name directory already exists. Updating..."
        cd "$TOOLS_DIR/$tool_name"
        git pull >> $log_file 2>&1
    else
        cd "$TOOLS_DIR"
        # Use timeout to prevent hanging git clones
        run_with_timeout "git clone $repo_url" $GIT_CLONE_TIMEOUT $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to clone $tool_name repository."
            log_result "FAILED" "$tool_name" "Git clone failed. See $log_file for details."
            return 1
        fi
        cd "$tool_name"
    fi
    
    process_git_repo $tool_name
    return $?
}

# Function to process Git repositories properly
process_git_repo() {
    local repo_name=$1
    local log_file="$LOG_DIR/${repo_name}_process.log"
    
    print_status "Processing $repo_name repository..."
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
            log_result "$repo_name" "SUCCESS" "Created executable wrapper and desktop shortcut"
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
            
            # Try to find executables and create wrappers
            EXECUTABLE=$(find "$VENV_DIR/$repo_name/bin" -type f -not -name "python*" -not -name "pip*" -not -name "activate*" | head -1)
            if [ -n "$EXECUTABLE" ]; then
                ln -sf "$EXECUTABLE" "/usr/local/bin/$(basename $EXECUTABLE)"
                create_desktop_shortcut "$(basename $EXECUTABLE)" "/usr/local/bin/$(basename $EXECUTABLE)" "" "Security;Utility;"
                print_success "Installed $repo_name and linked executable $(basename $EXECUTABLE)"
                log_result "$repo_name" "SUCCESS" "Installed in virtual environment and linked executable"
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
                create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
                
                print_success "Created executable wrapper for $repo_name."
                log_result "$repo_name" "SUCCESS" "Created executable wrapper and desktop shortcut"
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
                create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
                
                print_success "Built and installed $repo_name."
                log_result "$repo_name" "SUCCESS" "Built Go executable and created desktop shortcut"
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
            log_result "$repo_name" "PARTIAL" "Setup.py installation failed. See $log_file for details."
        else
            # Create symlink to bin directory if executable exists
            if [ -f "$VENV_DIR/$repo_name/bin/$repo_name" ]; then
                ln -sf "$VENV_DIR/$repo_name/bin/$repo_name" "/usr/local/bin/$repo_name"
                create_desktop_shortcut "$repo_name" "/usr/local/bin/$repo_name" "" "Security;Utility;"
            fi
            deactivate
            print_success "$repo_name installed via setup.py."
            log_result "$repo_name" "SUCCESS" "Installed via setup.py in virtual environment"
            return 0
        fi
    elif [ -f "requirements.txt" ]; then
        print_debug "Installing Python requirements in virtual environment..."
        setup_venv $repo_name
        pip install -r requirements.txt >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to install requirements for $repo_name."
            deactivate
            log_result "$repo_name" "PARTIAL" "Requirements installation failed. See $log_file for details."
        else
            deactivate
            print_success "$repo_name requirements installed."
            log_result "$repo_name" "SUCCESS" "Requirements installed in virtual environment"
            return 0
        fi
    elif [ -f "Makefile" ] || [ -f "makefile" ]; then
        print_debug "Building with make..."
        run_with_timeout "make" $BUILD_TIMEOUT $log_file $repo_name
        if [ $? -ne 0 ]; then
            print_error "Failed to build $repo_name with make."
            log_result "$repo_name" "PARTIAL" "Make build failed. See $log_file for details."
        else
            print_success "$repo_name built with make."
            # Try to find and link the executable
            find . -type f -executable -not -path "*/\.*" | while read -r executable; do
                if [[ "$executable" == *"$repo_name"* ]] || [[ "$executable" == *"/bin/"* ]]; then
                    chmod +x "$executable"
                    ln -sf "$executable" "/usr/local/bin/$(basename $executable)"
                    create_desktop_shortcut "$(basename $executable)" "/usr/local/bin/$(basename $executable)" "" "Security;Utility;"
                    print_info "Linked executable: $(basename $executable)"
                fi
            done
            log_result "$repo_name" "SUCCESS" "Built with make"
            return 0
        fi
    elif [ -f "install.sh" ]; then
        print_debug "Running install.sh script..."
        chmod +x install.sh
        run_with_timeout "./install.sh" $BUILD_TIMEOUT $log_file $repo_name
        if [ $? -ne 0 ]; then
            print_error "Failed to run install.sh script."
            log_result "$repo_name" "PARTIAL" "Install script failed. See $log_file for details."
        else
            print_success "$repo_name installed with install.sh script."
            log_result "$repo_name" "SUCCESS" "Installed with install.sh script"
            return 0
        fi
    fi
    
    # Generic handling if we couldn't determine specific instructions
    print_debug "Could not determine specific installation method, creating generic wrapper..."
    
    # Look for any executable files
    EXECUTABLE=$(find . -type f -executable -not -path "*/\.*" | head -1)
    if [ -n "$EXECUTABLE" ]; then
        ln -sf "$TOOLS_DIR/$repo_name/$EXECUTABLE" "/usr/local/bin/${repo_name,,}"
        create_desktop_shortcut "$repo_name" "/usr/local/bin/${repo_name,,}" "" "Security;Utility;"
        
        print_success "Linked executable for $repo_name."
        log_result "$repo_name" "SUCCESS" "Linked executable and created desktop shortcut"
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
        log_result "$repo_name" "PARTIAL" "Created info viewer for documentation"
    else
        log_result "$repo_name" "PARTIAL" "Could not determine installation method"
    fi
    
    return 1
}

# Function to install multiple GitHub tools potentially in parallel
install_github_tools() {
    local repo_urls=$1  # comma-separated list
    print_status "Installing GitHub tools: $repo_urls"
    
    # Convert comma-separated list to array
    IFS=',' read -ra REPO_ARRAY <<< "$repo_urls"
    
    # Install each repo (can be parallelized with GNU Parallel if available)
    if command -v parallel &> /dev/null && [ ${#REPO_ARRAY[@]} -gt 1 ]; then
        # Use parallel for faster installation
        printf '%s\n' "${REPO_ARRAY[@]}" | parallel -j$(( PARALLEL_JOBS / 2 )) "bash -c 'source $0; install_github_tool {}'" "$0"
    else
        # Fall back to sequential installation
        for repo in "${REPO_ARRAY[@]}"; do
            install_github_tool "$repo"
        done
    fi
}

# Function to create manual installation helpers
create_manual_helper() {
    local tool_name="$1"
    local instructions="$2"
    local file="$HELPERS_DIR/install_${tool_name}.sh"

    cat > "$file" <<EOF
#!/bin/bash
# Manual installation helper for $tool_name
# Created by RTA Tools Installer

set -e

$instructions

echo "Installation of $tool_name complete."
EOF

    chmod +x "$file"
    print_info "Created manual helper: $file"
    log_result "MANUAL" "$tool_name" "Helper script created at $file"
}

# Function to generate all needed manual installation helpers
generate_manual_helpers() {
    print_status "Generating manual installation helpers..."
    
    create_manual_helper "nessus" "echo '1. Visit: https://www.tenable.com/downloads/nessus'
echo '2. Download the Debian package for your version.'
echo '3. Run: sudo dpkg -i Nessus-*.deb && sudo apt-get install -f -y'
echo '4. Enable and start service: sudo systemctl enable nessusd && sudo systemctl start nessusd'
echo '5. Access https://localhost:8834 to complete setup.'

# Try automatic download if wanted
read -p 'Would you like to try automatic download? (y/n): ' auto_download
if [[ $auto_download == 'y' ]]; then
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
dpkg-deb -b \"\$dummy_dir\" /tmp/policykit-1_1.0_all.deb
sudo dpkg -i /tmp/policykit-1_1.0_all.deb

# Look for TeamViewer package
teamviewer_deb=\$(find ~/Downloads ~/Desktop -name 'teamviewer-host*.deb' 2>/dev/null | head -1)
if [ -n \"\$teamviewer_deb\" ]; then
    echo \"Found TeamViewer package at \$teamviewer_deb\"
    sudo dpkg -i \"\$teamviewer_deb\"
    sudo apt-get install -f -y
    
    # Configure TeamViewer
    sudo teamviewer daemon enable
    sudo systemctl enable teamviewerd.service
    sudo teamviewer daemon start
    
    # Get the TeamViewer ID
    sleep 3
    teamviewer_id=\$(teamviewer info | grep \"TeamViewer ID:\" | awk '{print \$3}')
    echo \"TeamViewer ID: \$teamviewer_id\"
else
    echo \"No TeamViewer package found. Please download it from teamviewer.com\"
fi"

    create_manual_helper "ninjaone" "# Installing NinjaOne agent
echo 'Looking for NinjaOne agent installer...'

ninjaone_deb=\$(find ~/Downloads ~/Desktop -name 'ninja-*.deb' 2>/dev/null | head -1)
if [ -n \"\$ninjaone_deb\" ]; then
    echo \"Found NinjaOne package at \$ninjaone_deb\"
    sudo dpkg -i \"\$ninjaone_deb\"
    sudo apt-get install -f -y
    echo 'NinjaOne agent installed.'
else
    echo 'NinjaOne .deb file not found. Please download it from your NinjaOne portal.'
fi"

    print_success "Generated manual installation helpers."
}

# Function to install additional dependencies
install_dependencies() {
    print_status "Installing dependencies..."
    
    # Core build dependencies
    DEPS="git python3 python3-pip python3-venv golang nodejs npm curl wget python3-dev"
    DEPS="$DEPS pipx openjdk-17-jdk unzip build-essential parallel"
    
    # Additional dependencies for specific tools
    DEPS="$DEPS net-tools dnsutils whois ncat netcat-traditional"
    
    # Install in one batch for speed
    apt-get install -y $DEPS
    
    print_success "Dependencies installed."
    log_result "SUCCESS" "dependencies" "Core dependencies installed"
}

# Function to install teamviewer with workaround
install_teamviewer_workaround() {
    print_status "Installing TeamViewer Host with workaround..."
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

    dpkg-deb -b "$dummy_dir" "$TEMP_DIR/policykit-1_1.0_all.deb" > /dev/null
    dpkg -i "$TEMP_DIR/policykit-1_1.0_all.deb" > /dev/null

    # Look for TeamViewer package in common locations
    TEAMVIEWER_DEB=$(find /home/*/Desktop /home/*/Downloads -name "teamviewer-host*.deb" 2>/dev/null | head -1)
    
    if [ -n "$TEAMVIEWER_DEB" ]; then
        print_status "Found TeamViewer package at $TEAMVIEWER_DEB"
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
            
            print_success "TeamViewer Host installed and configured."
            log_result "SUCCESS" "teamviewer-host" "Installed with dependencies workaround"
        else
            print_error "TeamViewer installation failed."
            log_result "FAILED" "teamviewer-host" "Installation failed despite workaround"
        fi
    else
        print_info "TeamViewer package not found. Creating helper script."
        # The helper was already created in generate_manual_helpers
    fi
    
    # Clean up
    rm -rf "$dummy_dir" "$TEMP_DIR/policykit-1_1.0_all.deb"
}

# Function to modify config files if needed
create_config_file() {
    print_status "Creating configuration file..."
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    # Create default config.yml if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# RTA Tools Installer Configuration
# Modify this file to customize your RTA setup

# Core apt tools - installed with apt-get
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,seclists,proxychains4,responder,metasploit-framework,exploitdb,nikto,dirb,dirbuster,whatweb,wpscan,masscan,aircrack-ng,john,hashcat,crackmapexec,enum4linux,gobuster,ffuf,steghide,binwalk,foremost,exiftool,httpie,rlwrap,nbtscan"

# Python tools - installed with pipx
pipx_tools: "scoutsuite,impacket,pymeta,fierce,pwnedpasswords,trufflehog,pydictor,apkleaks,datasploit,stegcracker,wfuzz,hakrawler,sublist3r,jwtcrack,nuclei,recon-ng,commix,evil-winrm"

# GitHub repositories
git_tools: "https://github.com/prowler-cloud/prowler.git,https://github.com/ImpostorKeanu/parsuite.git,https://github.com/fin3ss3g0d/evilgophish.git,https://github.com/Und3rf10w/kali-anonsurf.git,https://github.com/s0md3v/XSStrike.git,https://github.com/swisskyrepo/PayloadsAllTheThings.git,https://github.com/danielmiessler/SecLists.git,https://github.com/internetwache/GitTools.git,https://github.com/digininja/CeWL.git,https://github.com/gchq/CyberChef.git"

# Manual tools - installation helpers will be generated
manual_tools: "nessus,vmware_remote_console,burpsuite_enterprise,teamviewer,ninjaone"
EOF
    fi
    
    print_success "Configuration file created at $CONFIG_FILE"
}

# =====================================================================
# MAIN INSTALLATION FUNCTIONS
# =====================================================================

# Install core tools
install_core_tools() {
    print_status "Installing core tools..."
    
    # Core apt tools
    APT_CORE="nmap wireshark sqlmap hydra bettercap proxychains4 responder metasploit-framework"
    install_apt_packages "$APT_CORE"
    
    # Core pipx tools
    PIPX_CORE="impacket"
    install_pipx_packages "$PIPX_CORE"
    
    print_success "Core tools installed."
    log_result "SUCCESS" "core_tools" "Essential security tools installed"
}

# Install desktop shortcuts and configuration
install_desktop_integration() {
    print_status "Setting up desktop integration..."
    
    # Create web shortcuts
    create_web_shortcuts
    
    # Set up environment
    setup_environment
    
    # Disable screen lock and power management
    disable_screen_lock
    
    print_success "Desktop integration complete."
    log_result "SUCCESS" "desktop" "Desktop integration and shortcuts created"
}

# Install full toolkit
install_full_toolkit() {
    print_status "Installing full toolkit..."
    
    # Load configuration
    if [ -f "$CONFIG_FILE" ]; then
        print_debug "Loading config from $CONFIG_FILE"
        eval $(parse_yaml "$CONFIG_FILE")
    else
        print_error "Config file not found. Creating default config..."
        create_config_file
        eval $(parse_yaml "$CONFIG_FILE")
    fi
    
    # Install dependencies first
    install_dependencies
    
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
    
    print_success "Full toolkit installation complete."
    log_result "SUCCESS" "full_toolkit" "Complete security toolkit installed"
}

# Function to print a summary of installed tools
print_summary() {
    print_status "Installation Summary"
    
    # Count success, partial, failed, manual
    SUCCESS_COUNT=$(grep -c "\[SUCCESS\]" $REPORT_FILE)
    PARTIAL_COUNT=$(grep -c "\[PARTIAL\]" $REPORT_FILE)
    FAILED_COUNT=$(grep -c "\[FAILED\]" $REPORT_FILE)
    MANUAL_COUNT=$(grep -c "\[MANUAL\]" $REPORT_FILE)
    SKIPPED_COUNT=$(grep -c "\[SKIPPED\]" $REPORT_FILE)
    
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
    echo "Total installation time: $MINUTES minutes and $SECONDS seconds" >> $REPORT_FILE
    
    print_info "Successfully installed: $SUCCESS_COUNT"
    print_info "Partially installed: $PARTIAL_COUNT"
    print_info "Failed to install: $FAILED_COUNT"
    print_info "Manual installation required: $MANUAL_COUNT"
    print_info "Skipped (already installed): $SKIPPED_COUNT"
    
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
    print_info "You may need to log out and back in for all changes to take effect."
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================

# Record start time
START_TIME=$(date +%s)

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
    # Check if running as root
    check_root
    
    # Create directory structure
    create_directories
    
    # Initialize report file
    echo "RTA Tools Installation Report" > $REPORT_FILE
    echo "=================================" >> $REPORT_FILE
    echo "Date: $(date)" >> $REPORT_FILE
    echo "System: $(uname -a)" >> $REPORT_FILE
    echo "" >> $REPORT_FILE
    echo "Installation Results:" >> $REPORT_FILE
    echo "-------------------" >> $REPORT_FILE
    
    # Create config file if it doesn't exist
    create_config_file
    
    # Update apt repositories
    print_status "Updating package lists..."
    apt-get update
    print_success "Package lists updated."
    
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
}

# Run main function
main
