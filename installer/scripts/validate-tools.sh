#!/bin/bash
# =================================================================
# RTA Tools Validation Script 2.0
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

# Function to export HTML report
export_html_report() {
    local html_file="${VALIDATION_REPORT%.txt}.html"
    
    cat > "$html_file" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RTA Tools Validation Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        h1, h2, h3 {
            color: #2c3e50;
        }
        .header {
            background-color: #34495e;
            color: white;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
            text-align: center;
        }
        .summary {
            display: flex;
            justify-content: space-between;
            margin-bottom: 30px;
        }
        .summary-card {
            flex: 1;
            padding: 15px;
            border-radius: 5px;
            margin: 0 10px;
            text-align: center;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .success { background-color: #e6f7e9; border-left: 4px solid #2ecc71; }
        .warning { background-color: #fef8e7; border-left: 4px solid #f1c40f; }
        .error { background-color: #feecec; border-left: 4px solid #e74c3c; }
        .category {
            margin-bottom: 30px;
            border: 1px solid #eee;
            border-radius: 5px;
            overflow: hidden;
        }
        .category-header {
            background-color: #f9f9f9;
            padding: 10px 15px;
            border-bottom: 1px solid #eee;
            font-weight: bold;
        }
        .tool-list {
            padding: 0;
            margin: 0;
            list-style-type: none;
        }
        .tool-item {
            padding: 10px 15px;
            border-bottom: 1px solid #eee;
        }
        .tool-item:last-child {
            border-bottom: none;
        }
        .tool-success { color: #2ecc71; }
        .tool-warning { color: #f1c40f; }
        .tool-error { color: #e74c3c; }
        .tool-fixed { color: #3498db; }
        .footer {
            margin-top: 30px;
            text-align: center;
            font-size: 0.9em;
            color: #7f8c8d;
        }
        @media print {
            body { font-size: 12pt; }
            .category { page-break-inside: avoid; }
            .header { background-color: #f9f9f9; color: #333; }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>RTA Tools Validation Report</h1>
        <p>Generated on $(date)</p>
        <p>Host: $(hostname) - Kali $(cat /etc/os-release | grep VERSION= | cut -d'"' -f2 2>/dev/null || echo "Linux")</p>
    </div>

    <div class="summary">
        <div class="summary-card success">
            <h3>Success</h3>
            <p style="font-size: 24px;"><strong>$success_count</strong></p>
            <p>Tools successfully validated</p>
        </div>
        <div class="summary-card warning">
            <h3>Warnings</h3>
            <p style="font-size: 24px;"><strong>$warning_count</strong></p>
            <p>Tools with warnings</p>
        </div>
        <div class="summary-card error">
            <h3>Failed</h3>
            <p style="font-size: 24px;"><strong>$failure_count</strong></p>
            <p>Tools failed validation</p>
        </div>
    </div>
EOF

    # Add category sections
    for category in APT_TOOLS PIPX_TOOLS GIT_TOOLS MANUAL_TOOLS; do
        # Check if we should include this category
        if $ESSENTIAL_ONLY && [ "$category" != "ESSENTIAL_TOOLS" ]; then
            continue
        fi
        if $APT_ONLY && [ "$category" != "APT_TOOLS" ]; then
            continue
        fi
        if $PIPX_ONLY && [ "$category" != "PIPX_TOOLS" ]; then
            continue
        fi
        if $GIT_ONLY && [ "$category" != "GIT_TOOLS" ]; then
            continue
        fi
        
        # Get pretty name for category
        case "$category" in
            "APT_TOOLS") pretty_name="APT-Installed Tools" ;;
            "PIPX_TOOLS") pretty_name="PIPX-Installed Tools" ;;
            "GIT_TOOLS") pretty_name="Git-Installed Tools" ;;
            "MANUAL_TOOLS") pretty_name="Manually Installed Tools" ;;
            "ESSENTIAL_TOOLS") pretty_name="Essential Tools" ;;
            *) pretty_name="$category" ;;
        esac
        
        # Start category section
        cat >> "$html_file" << EOF
    <div class="category">
        <div class="category-header">$pretty_name</div>
        <ul class="tool-list">
EOF
        
        # Add tools in the category
        declare -n tools_array="$category"
        for tool in "${!tools_array[@]}"; do
            status="${VALIDATION_RESULTS[$tool]}"
            details="${VALIDATION_DETAILS[$tool]}"
            
            case "$status" in
                "SUCCESS") 
                    icon="✓"
                    class="tool-success"
                    ;;
                "FIXED") 
                    icon="✓"
                    class="tool-fixed"
                    ;;
                "WARNING") 
                    icon="⚠"
                    class="tool-warning"
                    ;;
                "FAILED") 
                    icon="✗"
                    class="tool-error"
                    ;;
                *) 
                    icon="?"
                    class=""
                    ;;
            esac
            
            cat >> "$html_file" << EOF
            <li class="tool-item">
                <span class="$class">$icon $tool:</span> $details
            </li>
EOF
        done
        
        # End category section
        cat >> "$html_file" << EOF
        </ul>
    </div>
EOF
    done
    
    # Add footer and close HTML
    cat >> "$html_file" << EOF
    <div class="footer">
        <p>Validation time: $minutes minutes and $seconds seconds</p>
        <p>RTA Tools Validation System v2.0</p>
    </div>
</body>
</html>
EOF

    echo -e "${BLUE}[i] HTML report exported to: ${YELLOW}$html_file${NC}"
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
    local category_total="${#tools_array[@]}"
    local category_current=0
    
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

# Export HTML report if requested
if $EXPORT_HTML; then
    export_html_report
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
