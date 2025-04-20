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
LOG_FILE="/tmp/evilginx3_install.log"
PRIMARY_USERNAME="rmcyber"

# Helper functions
log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

# Create log file
touch "$LOG_FILE"
log "${BLUE}[i] Evilginx3 Installation Script${NC}"
log "${BLUE}[i] ------------------------------${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  log "${RED}[-] Please run as root${NC}"
  exit 1
fi

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
      if ! grep -q "export PATH=\$PATH:/usr/local/go/bin" /etc/profile.d/golang.sh 2>/dev/null; then
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
        chmod +x /etc/profile.d/golang.sh
      fi
      
      # Add to current session
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
    cd "$INSTALL_DIR" || return 1
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
    cd "$INSTALL_DIR" || return 1
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

# Create desktop shortcut and integration
create_desktop_integration() {
  log "${YELLOW}[*] Creating desktop integration...${NC}"
  
  # Create desktop shortcut
  cat > "/usr/share/applications/evilginx3.desktop" << DESKTOP
[Desktop Entry]
Name=Evilginx3
Comment=Man-in-the-middle attack framework
Exec=x-terminal-emulator -e "bash -c 'sudo evilginx; exec bash'"
Type=Application
Icon=utilities-terminal
Terminal=false
Categories=Security;Network;
DESKTOP

  # Create launcher script
  cat > "/usr/local/bin/evilginx-launcher" << 'LAUNCHER'
#!/bin/bash
# Evilginx3 Launcher Script

# Colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[-] Please run as root${NC}"
  exit 1
fi

echo -e "${BLUE}=== Evilginx3 Launcher ===${NC}"
echo
echo -e "${YELLOW}[*] Select an option:${NC}"
echo "1) Launch Evilginx3 in interactive mode"
echo "2) Launch Evilginx3 with specific phishlet"
echo "3) Update Evilginx3"
echo "4) Manage phishlets"
echo "5) Exit"

read -p "Select option: " option

case $option in
  1)
    echo -e "${YELLOW}[*] Launching Evilginx3 in interactive mode...${NC}"
    cd /opt/evilginx3
    ./evilginx
    ;;
  2)
    echo -e "${YELLOW}[*] Available phishlets:${NC}"
    find /opt/evilginx3/phishlets -name "*.yaml" | sed 's/.*\///' | sed 's/\.yaml//'
    echo
    read -p "Enter phishlet name: " phishlet
    
    if [ -f "/opt/evilginx3/phishlets/${phishlet}.yaml" ]; then
      echo -e "${YELLOW}[*] Launching Evilginx3 with phishlet ${phishlet}...${NC}"
      cd /opt/evilginx3
      ./evilginx -p "$phishlet"
    else
      echo -e "${RED}[-] Phishlet not found${NC}"
    fi
    ;;
  3)
    echo -e "${YELLOW}[*] Updating Evilginx3...${NC}"
    cd /opt/evilginx3
    git pull
    make
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}[+] Evilginx3 updated successfully${NC}"
    else
      echo -e "${RED}[-] Failed to update Evilginx3${NC}"
    fi
    ;;
  4)
    echo -e "${YELLOW}[*] Phishlet management:${NC}"
    echo "1) List installed phishlets"
    echo "2) Install custom phishlet"
    echo "3) Back"
    
    read -p "Select option: " phishlet_option
    
    case $phishlet_option in
      1)
        echo -e "${YELLOW}[*] Installed phishlets:${NC}"
        find /opt/evilginx3/phishlets -name "*.yaml" | sed 's/.*\///' | sed 's/\.yaml//'
        ;;
      2)
        read -p "Enter path to custom phishlet YAML: " phishlet_path
        
        if [ -f "$phishlet_path" ]; then
          phishlet_name=$(basename "$phishlet_path")
          cp "$phishlet_path" "/opt/evilginx3/phishlets/"
          echo -e "${GREEN}[+] Phishlet installed: $phishlet_name${NC}"
        else
          echo -e "${RED}[-] File not found: $phishlet_path${NC}"
        fi
        ;;
      *)
        echo -e "${BLUE}[i] Returning to main menu${NC}"
        ;;
    esac
    ;;
  *)
    echo -e "${BLUE}[i] Exiting${NC}"
    exit 0
    ;;
esac
LAUNCHER

  chmod +x "/usr/local/bin/evilginx-launcher"
  
  # Create user-specific shortcuts if needed
  if [ -n "$PRIMARY_USERNAME" ] && [ -d "/home/$PRIMARY_USERNAME" ]; then
    mkdir -p "/home/$PRIMARY_USERNAME/.local/share/applications"
    cp "/usr/share/applications/evilginx3.desktop" "/home/$PRIMARY_USERNAME/.local/share/applications/"
    
    # Create desktop shortcut if desktop directory exists
    if [ -d "/home/$PRIMARY_USERNAME/Desktop" ]; then
      cp "/usr/share/applications/evilginx3.desktop" "/home/$PRIMARY_USERNAME/Desktop/"
      chmod +x "/home/$PRIMARY_USERNAME/Desktop/evilginx3.desktop"
    fi
    
    # Fix ownership
    chown -R "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/.local/share/applications"
    [ -d "/home/$PRIMARY_USERNAME/Desktop" ] && chown "$PRIMARY_USERNAME:$PRIMARY_USERNAME" "/home/$PRIMARY_USERNAME/Desktop/evilginx3.desktop"
  fi
  
  log "${GREEN}[+] Desktop integration created${NC}"
  return 0
}

# Create completion helper
create_completion_helper() {
  log "${YELLOW}[*] Creating command completion helper...${NC}"
  
  # Create Bash completion script
  mkdir -p /etc/bash_completion.d/
  
  cat > "/etc/bash_completion.d/evilginx" << 'COMPLETION'
#!/bin/bash
# Evilginx Bash completion script

_evilginx_completions() {
  local cur prev opts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  
  # Main evilginx commands
  opts="help config sessions phishlets lures clear"
  
  # Complete the main command
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
  fi
  
  # Complete options for specific commands
  case "${prev}" in
    phishlets)
      local phishlet_cmds="create enable disable get download"
      COMPREPLY=( $(compgen -W "${phishlet_cmds}" -- ${cur}) )
      return 0
      ;;
    lures)
      local lures_cmds="create get edit disable enable"
      COMPREPLY=( $(compgen -W "${lures_cmds}" -- ${cur}) )
      return 0
      ;;
    config)
      local config_cmds="domain ip redirect js-payload hsts"
      COMPREPLY=( $(compgen -W "${config_cmds}" -- ${cur}) )
      return 0
      ;;
    sessions)
      local sessions_cmds="get id active delete"
      COMPREPLY=( $(compgen -W "${sessions_cmds}" -- ${cur}) )
      return 0
      ;;
  esac
}

complete -F _evilginx_completions evilginx
COMPLETION

  # Create documentation for common commands
  mkdir -p "$INSTALL_DIR/docs"
  
  cat > "$INSTALL_DIR/docs/commands.txt" << 'COMMANDS'
EVILGINX3 COMMON COMMANDS
========================

SETUP:
------
config domain <domain>        - Set the domain name for the phishing server
config ip <ip>                - Set the IP address for the phishing server
config redirect <url>         - Set the URL to redirect unauthorized requests

PHISHLETS:
---------
phishlets                     - List available phishlets
phishlets get <name>          - Show details of a phishlet
phishlets enable <name>       - Enable a phishlet
phishlets disable <name>      - Disable a phishlet

LURES:
-----
lures create <phishlet>       - Create a new lure for a phishlet
lures get <id>                - Show details of a lure
lures edit <id> path <path>   - Set the URL path for a lure
lures edit <id> redirect <url> - Set the redirect URL for a lure
lures enable <id>             - Enable a lure
lures disable <id>            - Disable a lure

SESSIONS:
--------
sessions                      - List active sessions
sessions get <id>             - Show details of a session
sessions delete <id>          - Delete a session

OTHER:
-----
clear                         - Clear the screen
help                          - Show help
exit                          - Exit Evilginx3

EXAMPLE WORKFLOW:
---------------
1. config domain example.com
2. config ip 10.0.0.1
3. phishlets enable google
4. lures create google
5. lures edit 0 path login
6. lures enable 0
COMMANDS

  log "${GREEN}[+] Command completion helper created${NC}"
  return 0
}

# Create security reminder
create_security_reminder() {
  log "${YELLOW}[*] Creating security reminder...${NC}"
  
  cat > "$INSTALL_DIR/IMPORTANT_SECURITY_NOTICE.txt" << 'NOTICE'
=====================================================================
                      IMPORTANT SECURITY NOTICE
=====================================================================

Evilginx3 is a powerful tool designed for LEGITIMATE SECURITY TESTING ONLY.

Using this tool without proper authorization is ILLEGAL and may result in:
  - Criminal charges
  - Civil liability
  - Violation of computer crime laws
  - Unauthorized access penalties

LEGAL REQUIREMENTS:
------------------
1. ALWAYS obtain written permission before testing
2. NEVER use this tool against unauthorized targets
3. Document all testing activities thoroughly
4. Follow responsible disclosure procedures
5. Comply with all applicable laws and regulations

PROFESSIONAL GUIDELINES:
----------------------
1. Define clear scope and boundaries for testing
2. Protect any sensitive data captured during testing
3. Maintain detailed logs of all activities
4. Provide complete reporting to authorized parties
5. Delete all captured credentials after testing is complete

REMEMBER:
--------
The possession of security testing tools is legal, but their misuse is not.
Always operate within the bounds of the law and professional ethics.

By using this tool, you acknowledge your responsibility to use it ethically
and legally. The developers of this tool accept no liability for misuse.

=====================================================================
NOTICE

  # Force display of notice when running evilginx
  if ! grep -q "cat $INSTALL_DIR/IMPORTANT_SECURITY_NOTICE.txt" "/usr/local/bin/evilginx-launcher"; then
    sed -i "/#!\/bin\/bash/a\\\n# Display security notice\ncat $INSTALL_DIR/IMPORTANT_SECURITY_NOTICE.txt\necho\nread -p \"Press Enter to acknowledge this notice\" acknowledgement\n" "/usr/local/bin/evilginx-launcher"
  fi
  
  log "${GREEN}[+] Security reminder created${NC}"
  return 0
}

# Main installation process
main() {
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
  
  # Create desktop integration
  create_desktop_integration
  
  # Create command completion helper
  create_completion_helper
  
  # Create security reminder
  create_security_reminder
  
  log "${GREEN}[+] Evilginx3 installation completed successfully!${NC}"
  log "${BLUE}[i] You can now run Evilginx3 using the command:${NC} sudo evilginx"
  log "${BLUE}[i] Or use the launcher:${NC} sudo evilginx-launcher"
  log "${BLUE}[i] Installation log available at:${NC} $LOG_FILE"
  
  return 0
}

# Run main function
main
exit $?
