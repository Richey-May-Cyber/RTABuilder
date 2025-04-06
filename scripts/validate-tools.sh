#!/bin/bash
# =================================================================
# RTA Tools Validation Script
# =================================================================
# Description: Validates that security tools are correctly installed and accessible
# Author: Security Professional
# Version: 1.0
# Usage: sudo ./validate-tools.sh [OPTIONS]
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
  --help              Display this help message and exit
EOF
}

# Parse command line arguments
ESSENTIAL_ONLY=false
APT_ONLY=false
PIPX_ONLY=false
GIT_ONLY=false
VERBOSE=false

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
)

declare -A MANUAL_TOOLS=(
    ["teamviewer"]="teamviewer --help 2>&1 | grep -i 'teamviewer'"
    ["bfg"]="bfg --version 2>&1 | grep -i 'BFG'"
    ["nessus"]="systemctl status nessusd 2>&1 | grep 'nessusd'"
    ["burpsuite"]="burpsuite --help 2>&1 | grep -i 'Burp Suite'"
)

# Function to validate a tool
validate_tool() {
    local tool_name=$1
    local validation_command=$2
    local category=$3
    
    ((total_tools++))
    
    echo -e "${YELLOW}[*] Checking $tool_name...${NC}"
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
        if command -v $tool_cmd &>/dev/null; then
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
    local warning_list=""
    local failed_list=""
    
    for tool in "${!tools[@]}"; do
        if [[ "${VALIDATION_RESULTS[$tool]}" == "SUCCESS" ]]; then
            success_list+="  ✓ $tool: ${VALIDATION_DETAILS[$tool]}\n"
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
    
    for tool in "${!tools_array[@]}"; do
        validate_tool "$tool" "${tools_array[$tool]}" "$category"
    done
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
  sudo /opt/security-tools/rta_installer.sh --force-reinstall

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
    echo -e "  - For APT/PIPX tools: ${CYAN}sudo /opt/security-tools/rta_installer.sh --force-reinstall${NC}"
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
