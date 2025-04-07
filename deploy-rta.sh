cat > ~/RTABuilder/deploy-rta.sh << 'EOF'
#!/bin/bash
# =================================================================
# Enhanced Kali Linux RTA Deployment Script for GitHub Deployment
# =================================================================

# Exit on error for critical operations
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Directories and files
WORK_DIR="/opt/rta-deployment"
TOOLS_DIR="/opt/security-tools"
LOG_DIR="$WORK_DIR/logs"
CONFIG_DIR="$WORK_DIR/config"
CURRENT_DIR="$(pwd)"

# Logging and output functions
print_status() { echo -e "${YELLOW}[*] $1${NC}"; }
print_success() { echo -e "${GREEN}[+] $1${NC}"; }
print_error() { echo -e "${RED}[-] $1${NC}"; }
print_info() { echo -e "${BLUE}[i] $1${NC}"; }
print_debug() { echo -e "${CYAN}[D] $1${NC}"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo -e "\nUsage: sudo $0"
    exit 1
fi

print_banner() {
    echo -e "\n${BOLD}${BLUE}==================================================================${NC}"
    echo -e "${BOLD}${BLUE}                 KALI LINUX RTA DEPLOYMENT                 ${NC}"
    echo -e "${BOLD}${BLUE}==================================================================${NC}\n"
}

# Display banner
print_banner

# Create necessary directories
print_status "Creating directories..."
mkdir -p "$WORK_DIR" "$TOOLS_DIR" "$LOG_DIR" "$CONFIG_DIR" "$TOOLS_DIR/scripts" "$TOOLS_DIR/logs" "$TOOLS_DIR/system-state"

# Create a placeholder installer
print_status "Creating placeholder installer..."
cat > "$WORK_DIR/rta_installer.sh" << 'EOFINSTALLER'
#!/bin/bash
echo "This is a placeholder installer script."
echo "Creating basic directory structure..."
mkdir -p /opt/security-tools/bin
mkdir -p /opt/security-tools/logs
mkdir -p /opt/security-tools/scripts
mkdir -p /opt/security-tools/helpers
mkdir -p /opt/security-tools/desktop

echo "Tools would be installed here."
exit 0
EOFINSTALLER
chmod +x "$WORK_DIR/rta_installer.sh"

# Create a placeholder validation script
print_status "Creating placeholder validation script..."
mkdir -p "$TOOLS_DIR/scripts"
cat > "$TOOLS_DIR/scripts/validate-tools.sh" << 'EOFVALIDATE'
#!/bin/bash
echo "This is a placeholder validation script."
echo "It would validate the installed tools."
exit 0
EOFVALIDATE
chmod +x "$TOOLS_DIR/scripts/validate-tools.sh"

# Create system snapshot
print_status "Creating system snapshot..."
SNAPSHOT_FILE="$TOOLS_DIR/system-state/system-snapshot-$(date +%Y%m%d-%H%M%S).txt"
{
    echo "==== RTA SYSTEM SNAPSHOT ===="
    echo "Date: $(date)"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Kali Version: $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo 'Unknown')"
    echo ""
    
    echo "==== DISK USAGE ===="
    df -h
    echo ""
    
    echo "==== MEMORY USAGE ===="
    free -h
    echo ""
} > "$SNAPSHOT_FILE"

print_success "System snapshot created: $SNAPSHOT_FILE"

# Display completion message
cat << EOF

${GREEN}==================================================================${NC}
${GREEN}                  RTA DEPLOYMENT COMPLETED!                       ${NC}
${GREEN}==================================================================${NC}

${BLUE}Installed tools can be found at:${NC} $TOOLS_DIR/
${BLUE}Installation logs are available at:${NC} $TOOLS_DIR/logs/
${BLUE}System snapshot is saved at:${NC} $SNAPSHOT_FILE

${YELLOW}Next steps:${NC}
1. Validate the installation by running:
   ${CYAN}sudo $TOOLS_DIR/scripts/validate-tools.sh${NC}
2. Install any remaining manual tools using the helper scripts:
   ${CYAN}ls $TOOLS_DIR/helpers/${NC}
3. Configure any tool-specific settings

${BLUE}Thank you for using the RTA Deployment Script!${NC}
EOF

print_info "Reboot recommended to apply changes."
EOF
