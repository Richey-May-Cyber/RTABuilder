#!/bin/bash

# Enhanced and Modular Kali Linux Security Tools Installer
# Author: You
# Description: Installs core and optional pentest tools with logging, validation, and desktop integration.

set -euo pipefail

### === Constants === ###
TOOLS_DIR="/opt/security-tools"
VENV_DIR="$TOOLS_DIR/venvs"
LOG_DIR="$TOOLS_DIR/logs"
HELPERS_DIR="$TOOLS_DIR/helpers"
CONFIG_FILE="$TOOLS_DIR/config.yml"
REPORT_FILE="$LOG_DIR/installation_report_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$TOOLS_DIR" "$VENV_DIR" "$LOG_DIR" "$HELPERS_DIR"

### === Color Definitions === ###
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

### === Logging Functions === ###
print_status()   { echo -e "${YELLOW}[*] $1${NC}"; }
print_success()  { echo -e "${GREEN}[+] $1${NC}"; }
print_error()    { echo -e "${RED}[-] $1${NC}"; }
print_info()     { echo -e "${BLUE}[i] $1${NC}"; }
log_result()     { echo "[$1] $2: $3" >> "$REPORT_FILE"; }

### === Root Check === ###
if [[ $EUID -ne 0 ]]; then print_error "Run as root." && exit 1; fi

### === Manual Installation Helpers === ###
create_manual_helper() {
    local tool_name="$1"
    local instructions="$2"
    local file="$HELPERS_DIR/install_${tool_name}.sh"

    cat > "$file" <<EOF
#!/bin/bash
# Manual installation helper for $tool_name

set -e

$instructions
EOF

    chmod +x "$file"
    print_info "Created manual helper: $file"
    log_result "MANUAL" "$tool_name" "Helper script created at $file"
}

generate_manual_helpers() {
    create_manual_helper "nessus" "echo '1. Visit: https://www.tenable.com/downloads/nessus'
echo '2. Download the Debian package for your version.'
echo '3. Run: sudo dpkg -i Nessus-*.deb && sudo apt-get install -f -y'
echo '4. Enable and start service: sudo systemctl enable nessusd && sudo systemctl start nessusd'
echo '5. Access https://localhost:8834 to complete setup.'"

    create_manual_helper "vmware_remote_console" "echo 'Visit: https://knowledge.broadcom.com/external/article/368995/download-vmware-remote-console.html'
echo 'Download the latest .bundle file and run it with:'
echo 'chmod +x VMware-Remote-Console*.bundle && sudo ./VMware-Remote-Console*.bundle'"

    create_manual_helper "burpsuite_enterprise" "echo '1. Place the Burp Suite Enterprise .zip file in ~/Desktop or ~/Downloads.'
echo '2. Extract and run the .run or .jar installer inside the extracted directory.'
echo '3. Follow GUI setup steps or use silent mode if available.'"

    create_manual_helper "ninjaone" "if [ -f \"\$HOME/Downloads/$NINJAONE_DEB\" ]; then
    echo 'Installing NinjaOne agent from .deb package...'
    sudo dpkg -i \"\$HOME/Downloads/$NINJAONE_DEB\"
    sudo apt-get install -f -y
    echo 'NinjaOne agent installed.'
else
    echo 'NinjaOne .deb file not found in ~/Downloads. Please move it there and re-run this script.'
fi"
}

### === Basic Installer === ###
install_apt_package() {
    local pkg="$1"
    local log="$LOG_DIR/${pkg}_apt.log"

    if dpkg -s "$pkg" &>/dev/null; then
        print_info "$pkg already installed. Skipping."
        log_result "SKIPPED" "$pkg" "Already installed"
        return
    fi

    print_status "Installing $pkg..."
    if timeout 300 apt-get install -y "$pkg" &>> "$log"; then
        print_success "$pkg installed."
        log_result "SUCCESS" "$pkg" "Installed via apt"
    else
        print_error "$pkg installation failed."
        log_result "FAILED" "$pkg" "Apt install failed"
    fi
}

install_with_pipx() {
    local pkg="$1"
    local log="$LOG_DIR/${pkg}_pipx.log"

    print_status "Installing $pkg with pipx..."
    if pipx install "$pkg" &>> "$log"; then
        print_success "$pkg installed with pipx."
        log_result "SUCCESS" "$pkg" "Installed with pipx"
    else
        print_error "$pkg installation via pipx failed."
        log_result "FAILED" "$pkg" "pipx install failed"
    fi
}

clone_and_build_git() {
    local repo="$1"
    local name="$(basename "$repo" .git)"
    local dir="$TOOLS_DIR/$name"
    local log="$LOG_DIR/${name}_git.log"

    print_status "Cloning and building $name from GitHub..."

    if [[ -d "$dir" ]]; then
        print_info "$name already exists. Pulling latest..."
        git -C "$dir" pull &>> "$log"
    else
        git clone "$repo" "$dir" &>> "$log"
    fi

    if [[ -f "$dir/setup.py" ]]; then
        python3 -m venv "$VENV_DIR/$name"
        source "$VENV_DIR/$name/bin/activate"
        pip install -e "$dir" &>> "$log"
        deactivate
        print_success "$name installed in venv."
        log_result "SUCCESS" "$name" "Installed via setup.py in venv"
    elif [[ -f "$dir/install.sh" ]]; then
        chmod +x "$dir/install.sh"
        bash "$dir/install.sh" &>> "$log"
        print_success "$name installed using install.sh."
        log_result "SUCCESS" "$name" "Installed using install.sh"
    else
        print_info "$name cloned but not built."
        log_result "PARTIAL" "$name" "Cloned but no setup.py or install.sh"
    fi
}

install_teamviewer_workaround() {
    print_status "Installing TeamViewer Host with workaround..."
    dummy_dir="$TOOLS_DIR/policykit-dummy"
    mkdir -p "$dummy_dir/DEBIAN"

    cat > "$dummy_dir/DEBIAN/control" <<EOF
Package: policykit-1
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Depends: polkitd, pkexec
Maintainer: System Administrator <root@localhost>
Description: Transitional package for PolicyKit
EOF

    dpkg-deb -b "$dummy_dir" "$TOOLS_DIR/policykit-1_1.0_all.deb"
    dpkg -i "$TOOLS_DIR/policykit-1_1.0_all.deb"

    if [ -f "/home/\$SUDO_USER/Desktop/teamviewer-host_15.63.4_amd64.deb" ]; then
        dpkg -i "/home/\$SUDO_USER/Desktop/teamviewer-host_15.63.4_amd64.deb"
        apt-get install -f -y
        print_success "TeamViewer Host installed and dependencies resolved."
        log_result "SUCCESS" "teamviewer-host" "Installed with deprecated workaround"
    else
        print_error "TeamViewer .deb not found on Desktop. Skipping."
        log_result "FAILED" "teamviewer-host" "Missing .deb file"
    fi
}

### === Desktop Shortcut === ###
create_desktop_shortcut() {
    local name="$1" exec="$2" icon="$3" cat="$4"
    icon="${icon:-utilities-terminal}" cat="${cat:-Security;}"

    cat > "/usr/share/applications/${name,,}.desktop" <<EOF
[Desktop Entry]
Name=$name
Exec=$exec
Type=Application
Icon=$icon
Terminal=false
Categories=$cat
EOF
    print_info "Shortcut created for $name."
}

### === YAML Loader === ###
parse_yaml() {
    local prefix=$2
    local s='[[:space:]]*'
    local w='[a-zA-Z0-9_]*'
    sed -ne "s|^$s\($w\)$s:$s\"\(.*\)\"$s\$|\1=\"\2\"|p" $1
}

### === Tool Installer === ###
install_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Tool config YAML not found: $CONFIG_FILE"
        exit 1
    fi

    eval $(parse_yaml "$CONFIG_FILE")

    IFS=',' read -ra APT_PKGS <<< "$apt_tools"
    IFS=',' read -ra PIPX_PKGS <<< "$pipx_tools"
    IFS=',' read -ra GIT_PKGS <<< "$git_tools"

    for t in "${APT_PKGS[@]}"; do install_apt_package "$t"; done
    for t in "${PIPX_PKGS[@]}"; do install_with_pipx "$t"; done
    for repo in "${GIT_PKGS[@]}"; do clone_and_build_git "$repo"; done

    install_teamviewer_workaround
    generate_manual_helpers
}

### === CLI Flag Parser === ###
FULL=false
CORE_ONLY=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --core-only)
            CORE_ONLY=true
            shift;;
        --full)
            FULL=true
            shift;;
        *)
            print_error "Unknown option: $1"
            exit 1;;
    esac
done

### === Main === ###
main() {
    print_info "Starting Kali Security Tool Installer..."
    echo "Installation started at: $(date)" >> "$REPORT_FILE"

    apt-get update
    install_apt_package git
    install_apt_package python3-pip
    install_apt_package pipx

    if $CORE_ONLY; then
        install_apt_package nmap
        install_apt_package wireshark
        install_apt_package sqlmap
    elif $FULL; then
        install_from_config
    else
        print_status "No flags provided. Use --core-only or --full"
        exit 1
    fi

    echo "Installation finished at: $(date)" >> "$REPORT_FILE"
    print_success "Installation complete. Log: $REPORT_FILE"
}

main "$@"
