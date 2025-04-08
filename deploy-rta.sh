#!/bin/bash
# Simple RTA Deployment Script

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Functions
print_status() { 
  echo -e "${YELLOW}[*] $1${NC}"
}

print_success() { 
  echo -e "${GREEN}[+] $1${NC}"
}

print_error() { 
  echo -e "${RED}[-] $1${NC}"
}

print_info() { 
  echo -e "${BLUE}[i] $1${NC}"
}

# Check root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run as root"
  exit 1
fi

# Display banner
echo "=================================================="
echo "          KALI LINUX RTA DEPLOYMENT              "
echo "=================================================="
echo ""

# Create directories
print_status "Creating directories..."
mkdir -p /opt/rta-deployment/logs
mkdir -p /opt/security-tools/bin
mkdir -p /opt/security-tools/logs
mkdir -p /opt/security-tools/scripts
mkdir -p /opt/security-tools/helpers
mkdir -p /opt/security-tools/system-state

# Create basic installer
print_status "Creating installer script..."
cat > /opt/rta-deployment/rta_installer.sh << 'ENDOFSCRIPT'
#!/bin/bash
echo "[*] Installing basic tools..."
apt-get update
apt-get install -y nmap wireshark
echo "[+] Basic tools installed."
mkdir -p /opt/security-tools/bin
mkdir -p /opt/security-tools/logs
mkdir -p /opt/security-tools/scripts
mkdir -p /opt/security-tools/helpers
echo "[+] Installation complete."
ENDOFSCRIPT
chmod +x /opt/rta-deployment/rta_installer.sh

# Create validation script
print_status "Creating validation script..."
cat > /opt/security-tools/scripts/validate-tools.sh << 'ENDOFVALSCRIPT'
#!/bin/bash
echo "Validating tools..."
which nmap > /dev/null && echo "✓ nmap found" || echo "✗ nmap not found"
which wireshark > /dev/null && echo "✓ wireshark found" || echo "✗ wireshark not found"
ENDOFVALSCRIPT
chmod +x /opt/security-tools/scripts/validate-tools.sh

# Run installer 
print_status "Running installer..."
/opt/rta-deployment/rta_installer.sh

# Create snapshot
print_status "Creating system snapshot..."
SNAPSHOT_FILE="/opt/security-tools/system-state/snapshot-$(date +%Y%m%d-%H%M%S).txt"
{
  echo "=== SYSTEM SNAPSHOT ==="
  echo "Date: $(date)"
  echo "Hostname: $(hostname)"
  echo "Kernel: $(uname -r)"
  echo ""
  echo "=== DISK SPACE ==="
  df -h
} > "$SNAPSHOT_FILE"

print_success "System snapshot saved: $SNAPSHOT_FILE"

# Display completion message
echo ""
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}          RTA DEPLOYMENT COMPLETED!              ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo ""
print_info "Installed tools can be found at: /opt/security-tools/"
print_info "System snapshot saved to: $SNAPSHOT_FILE"
print_info "To validate tools run: sudo /opt/security-tools/scripts/validate-tools.sh"
print_info "A reboot is recommended to complete setup."
