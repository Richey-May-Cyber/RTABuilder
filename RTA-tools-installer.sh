#!/bin/bash

# Robust Kali Linux Security Tools Installer
# This script automates the installation of various security tools on Kali Linux
# Enhanced version with improved error handling, timeout protection, and conflict resolution

# Exit on error for most operations, but continue script if a tool installation fails
set +e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored status messages
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root"
    exit 1
fi

# Create a directory for all the tools
TOOLS_DIR="/opt/security-tools"
VENV_DIR="$TOOLS_DIR/venvs"
LOG_DIR="$TOOLS_DIR/logs"
mkdir -p $TOOLS_DIR
mkdir -p $VENV_DIR
mkdir -p $LOG_DIR
cd $TOOLS_DIR

# Record start time
START_TIME=$(date +%s)
REPORT_FILE="$LOG_DIR/installation_report_$(date +%Y%m%d_%H%M%S).txt"

# Add this function to create desktop shortcuts for all installed tools
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
    
    print_success "Desktop shortcut created for $name."
}

# Update system
print_status "Updating package lists..."
apt-get update
print_success "Package lists updated."

# Install dependencies
print_status "Installing dependencies..."
apt-get install -y git python3 python3-pip python3-venv golang nodejs npm curl wget python3-dev pipx openjdk-17-jdk unzip build-essential
print_success "Dependencies installed."

# Initialize report
echo "Security Tools Installation Report" > $REPORT_FILE
echo "=================================" >> $REPORT_FILE
echo "Date: $(date)" >> $REPORT_FILE
echo "System: $(uname -a)" >> $REPORT_FILE
echo "" >> $REPORT_FILE
echo "Installation Results:" >> $REPORT_FILE
echo "-------------------" >> $REPORT_FILE

# Function to log results
log_result() {
    local tool=$1
    local status=$2
    local message=$3
    
    echo "[$status] $tool: $message" >> $REPORT_FILE
}

# Function to run commands with timeout protection
run_with_timeout() {
    local cmd="$1"
    local timeout_seconds=$2
    local log_file="$3"
    local tool_name="$4"
    
    print_status "Running command with ${timeout_seconds}s timeout protection..."
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

# Function to install an apt package with increased timeout
install_apt_package() {
    local package_name=$1
    local conflicting_packages=$2  # Optional: comma-separated list
    local log_file="$LOG_DIR/${package_name}_apt_install.log"
    
    print_status "Installing $package_name with apt..."
    
    # Handle conflicts if specified
    if [ ! -z "$conflicting_packages" ]; then
        for pkg in $(echo $conflicting_packages | tr ',' ' '); do
            if dpkg -l | grep -q $pkg; then
                print_status "Removing conflicting package $pkg..."
                apt-get remove -y $pkg >> "$log_file" 2>&1
                if [ $? -ne 0 ]; then
                    print_error "Failed to remove conflicting package $pkg."
                    log_result "$package_name" "FAILED" "Unable to resolve conflict with $pkg. See $log_file for details."
                    return 1
                fi
            fi
        done
    fi
    
# Install the package with a timeout (increase to 600 seconds for larger packages)
    run_with_timeout "apt-get install -y $package_name" 600 "$log_file" "$package_name"
    
    # Check if the package is installed regardless of timeout
    if dpkg -l | grep -q "$package_name"; then
        print_success "$package_name installed with apt."
        log_result "$package_name" "SUCCESS" "Installed with apt"
        return 0
    else
        print_error "Failed to install $package_name with apt."
        log_result "$package_name" "FAILED" "Apt installation failed. See $log_file for details."
        return 1
    fi
}

# Function to create and use virtual environment for Python tools
setup_venv() {
    local tool_name=$1
    print_status "Setting up virtual environment for $tool_name..."
    
    if [ ! -d "$VENV_DIR/$tool_name" ]; then
        python3 -m venv "$VENV_DIR/$tool_name"
    fi
    
    # Activate the virtual environment
    source "$VENV_DIR/$tool_name/bin/activate"
    
    # Upgrade pip in the virtual environment
    pip install --upgrade pip
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
        print_status "Found README file, checking for installation instructions..."
        
        # Check if a Python script is intended to be run directly
        MAIN_PY=$(find . -maxdepth 2 -name "*.py" | grep -i -E 'main|run|start' | head -1)
        if [ -n "$MAIN_PY" ]; then
            chmod +x "$MAIN_PY"
            print_status "Creating wrapper script for ${repo_name}..."
            
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
            print_status "Found pip install instructions, installing in virtual environment..."
            
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
            print_status "Found Go project, building..."
            
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
    
    # Generic handling if we couldn't determine specific instructions
    print_status "Could not determine specific installation method, creating generic wrapper..."
    
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

# Function to install GitHub tool with improved error handling
install_github_tool() {
    local repo_url=$1
    local tool_name=$(basename $repo_url)
    local log_file="$LOG_DIR/${tool_name}_install.log"
    
    print_status "Installing $tool_name..."
    
    # Clone or update the repository
    if [ -d "$TOOLS_DIR/$tool_name" ]; then
        print_status "$tool_name directory already exists. Updating..."
        cd "$TOOLS_DIR/$tool_name"
        git pull >> $log_file 2>&1
    else
        cd "$TOOLS_DIR"
        # Use timeout to prevent hanging git clones
        run_with_timeout "git clone $repo_url" 300 $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to clone $tool_name repository."
            log_result "$tool_name" "FAILED" "Git clone failed. See $log_file for details."
            return 1
        fi
        cd "$tool_name"
    fi
    
    # Try different installation methods
    # Check for specific installation methods
    if [ -f "setup.py" ]; then
        print_status "Installing with Python setup.py in virtual environment..."
        setup_venv $tool_name
        pip install . >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to install $tool_name with setup.py."
            deactivate
            log_result "$tool_name" "PARTIAL" "Setup.py installation failed. See $log_file for details."
        else
            # Create symlink to bin directory if executable exists
            if [ -f "$VENV_DIR/$tool_name/bin/$tool_name" ]; then
                ln -sf "$VENV_DIR/$tool_name/bin/$tool_name" "/usr/local/bin/$tool_name"
            fi
            deactivate
            print_success "$tool_name installed via setup.py."
            log_result "$tool_name" "SUCCESS" "Installed via setup.py in virtual environment"
        fi
    elif [ -f "requirements.txt" ]; then
        print_status "Installing Python requirements in virtual environment..."
        setup_venv $tool_name
        pip install -r requirements.txt >> $log_file 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to install requirements for $tool_name."
            deactivate
            log_result "$tool_name" "PARTIAL" "Requirements installation failed. See $log_file for details."
        else
            deactivate
            print_success "$tool_name requirements installed."
            log_result "$tool_name" "SUCCESS" "Requirements installed in virtual environment"
        fi
    elif [ -f "go.mod" ]; then
        print_status "Building Go module..."
        run_with_timeout "go build" 300 $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to build $tool_name Go module."
            log_result "$tool_name" "PARTIAL" "Go build failed. See $log_file for details."
        else
            if [ -f $tool_name ]; then
                chmod +x $tool_name
                ln -sf "$TOOLS_DIR/$tool_name/$tool_name" "/usr/local/bin/$tool_name"
                print_success "$tool_name Go module built and linked."
                log_result "$tool_name" "SUCCESS" "Go module built and linked to /usr/local/bin"
            else
                print_info "$tool_name: No executable found after Go build."
                log_result "$tool_name" "PARTIAL" "Go module built but no executable found"
            fi
        fi
    elif [ -f "package.json" ]; then
        print_status "Installing Node dependencies..."
        run_with_timeout "npm install" 300 $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to install $tool_name Node dependencies."
            log_result "$tool_name" "PARTIAL" "NPM installation failed. See $log_file for details."
        else
            print_success "$tool_name Node dependencies installed."
            log_result "$tool_name" "SUCCESS" "Node dependencies installed"
        fi
    elif [ -f "Makefile" ] || [ -f "makefile" ]; then
        print_status "Building with make..."
        run_with_timeout "make" 300 $log_file $tool_name
        if [ $? -ne 0 ]; then
            print_error "Failed to build $tool_name with make."
            log_result "$tool_name" "PARTIAL" "Make build failed. See $log_file for details."
        else
            print_success "$tool_name built with make."
            # Try to find and link the executable
            find . -type f -executable -not -path "*/\.*" | while read -r executable; do
                if [[ "$executable" == *"$tool_name"* ]] || [[ "$executable" == *"/bin/"* ]]; then
                    chmod +x "$executable"
                    ln -sf "$executable" "/usr/local/bin/$(basename $executable)"
                    print_info "Linked executable: $(basename $executable)"
                fi
            done
            log_result "$tool_name" "SUCCESS" "Built with make"
        fi
    else
        print_info "$tool_name: No recognized build system found. Repository cloned only."
        log_result "$tool_name" "PARTIAL" "Repository cloned but no recognized build system found"
    fi
    
    # Return success even if some parts failed - we'll track in the report
    return 0
}

# Function to install a tool using pipx with retry
install_with_pipx() {
    local package_name=$1
    local log_file="$LOG_DIR/${package_name}_pipx_install.log"
    
    print_status "Installing $package_name with pipx..."
    
    # Try up to 3 times with increasing timeouts
    for attempt in 1 2 3; do
        print_status "Attempt $attempt of 3..."
        timeout $((120 * attempt)) pipx install $package_name >> $log_file 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "$package_name installed with pipx on attempt $attempt."
            log_result "$package_name" "SUCCESS" "Installed with pipx (attempt $attempt)"
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
    log_result "$package_name" "FAILED" "Pipx installation failed after 3 attempts. See $log_file for details."
    return 1
}

# Function to install an apt package with conflict resolution
install_apt_package() {
    local package_name=$1
    local conflicting_packages=$2  # Optional: comma-separated list
    local log_file="$LOG_DIR/${package_name}_apt_install.log"
    
    print_status "Installing $package_name with apt..."
    
    # Handle conflicts if specified
    if [ ! -z "$conflicting_packages" ]; then
        for pkg in $(echo $conflicting_packages | tr ',' ' '); do
            if dpkg -l | grep -q $pkg; then
                print_status "Removing conflicting package $pkg..."
                apt-get remove -y $pkg >> "$log_file" 2>&1
                if [ $? -ne 0 ]; then
                    print_error "Failed to remove conflicting package $pkg."
                    log_result "$package_name" "FAILED" "Unable to resolve conflict with $pkg. See $log_file for details."
                    return 1
                fi
            fi
        done
    fi
    
    # Install the package with a timeout
    run_with_timeout "apt-get install -y $package_name" 300 "$log_file" "$package_name"
    
    if [ $? -ne 0 ]; then
        print_error "Failed to install $package_name with apt."
        log_result "$package_name" "FAILED" "Apt installation failed. See $log_file for details."
        return 1
    else
        print_success "$package_name installed with apt."
        log_result "$package_name" "SUCCESS" "Installed with apt"
        return 0
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
        print_status "Download attempt $attempt of 3..."
        timeout 180 wget $url -O $output_file >> $log_file 2>&1
        
        if [ $? -eq 0 ]; then
            chmod +x $output_file
            print_success "$executable_name downloaded and made executable."
            log_result "$executable_name" "SUCCESS" "Downloaded and made executable"
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
    log_result "$executable_name" "FAILED" "Download failed after 3 attempts. See $log_file for details."
    return 1
}

# Install GitHub tools
print_status "Installing GitHub tools..."

# Orca
apt install orca

# ScoutSuite - try several methods
print_status "Installing ScoutSuite..."
install_with_pipx "scoutsuite" || {
    print_info "Trying alternative installation method for ScoutSuite..."
    install_github_tool "https://github.com/nccgroup/ScoutSuite"
    setup_venv "ScoutSuite"
    cd "$TOOLS_DIR/ScoutSuite"
    pip install -e . >> "$LOG_DIR/ScoutSuite_install.log" 2>&1
    deactivate
}

# Prowler - try several methods
print_status "Installing Prowler..."
install_with_pipx "prowler" || {
    print_info "Trying alternative installation method for Prowler..."
    install_github_tool "https://github.com/prowler-cloud/prowler"
    setup_venv "prowler"
    cd "$TOOLS_DIR/prowler"
    pip install -e . >> "$LOG_DIR/prowler_install.log" 2>&1
    deactivate
}

# Gophish
print_status "Installing Gophish..."
cd "$TOOLS_DIR"
if [ ! -d "gophish" ]; then
    mkdir -p gophish
    cd gophish
    download_binary "https://github.com/gophish/gophish/releases/download/v0.12.1/gophish-v0.12.1-linux-64bit.zip" "gophish.zip"
    if [ $? -eq 0 ]; then
        unzip gophish.zip >> "$LOG_DIR/gophish_install.log" 2>&1
        chmod +x gophish
        ln -sf "$TOOLS_DIR/gophish/gophish" "/usr/local/bin/gophish"
        log_result "gophish" "SUCCESS" "Downloaded and installed binary"
        print_success "Gophish installed."
    fi
else
    print_status "Gophish already installed."
    log_result "gophish" "SUCCESS" "Already installed"
    print_success "Gophish installed."
fi

# Evilginx3
print_status "Installing evilginx3..."
cd "$TOOLS_DIR"

# Check if the installation script exists
if [ -f "/home/rmcyber/Desktop/install_evilginx3.sh" ]; then
    print_status "Found evilginx3 installation script. Running..."
    
    # Make the script executable
    chmod +x /home/rmcyber/Desktop/install_evilginx3.sh
    
    # Run the installation script
    run_with_timeout "/home/rmcyber/Desktop/install_evilginx3.sh" 900 "$LOG_DIR/evilginx3_install.log" "evilginx3"
    
    if [ $? -eq 0 ]; then
        print_success "Evilginx3 installed successfully."
        
        # Create symbolic link to make evilginx3 accessible system-wide
        if [ -f "/home/rmcyber/evilginx/evilginx" ]; then
            ln -sf "/home/rmcyber/evilginx/evilginx" "/usr/local/bin/evilginx"
            chmod +x "/usr/local/bin/evilginx"
            print_success "Created evilginx command symlink."
        fi
        
        # Create desktop shortcut
        create_desktop_shortcut "Evilginx3" "evilginx" "utilities-terminal" "Security;Network;"
        
        log_result "evilginx3" "SUCCESS" "Installed using custom installation script"
    else
        print_error "Evilginx3 installation script failed."
        log_result "evilginx3" "FAILED" "Installation script failed. See $LOG_DIR/evilginx3_install.log for details."
    fi
else
    print_error "Evilginx3 installation script not found at /home/rmcyber/Desktop/install_evilginx3.sh"
    log_result "evilginx3" "FAILED" "Installation script not found."
    
    # Try the original method as a fallback
    install_github_tool "https://github.com/kingsmandralph/evilginx3"
fi

# EvilGoPhish
install_github_tool "https://github.com/fin3ss3g0d/evilgophish"

# Responder
apt install responder
log_result "Responder" "SUCCESS" "Installed and linked to /usr/local/bin"

# Fix PyMeta dependencies
print_status "Fixing PyMeta dependencies..."
cd "$TOOLS_DIR"

# Activate the PyMeta virtual environment
source "$VENV_DIR/pymeta/bin/activate"

# Install missing dependency
print_status "Installing missing tldextract dependency for PyMeta..."
pip install tldextract >> "$LOG_DIR/pymeta_fix.log" 2>&1
pip install lxml

if [ $? -eq 0 ]; then
    print_success "PyMeta dependency fixed successfully."
    log_result "pymeta-fix" "SUCCESS" "Installed missing dependency tldextract"
else
    print_error "Failed to install PyMeta dependency."
    log_result "pymeta-fix" "FAILED" "Failed to install tldextract. See $LOG_DIR/pymeta_fix.log for details."
fi

# PyMeta
install_with_pipx "pymeta" || {
    print_info "Trying alternative installation method for PyMeta..."
    install_github_tool "https://github.com/m8sec/pymeta"
}

# Deactivate the virtual environment
deactivate

# Parsuite
install_github_tool "https://github.com/ImpostorKeanu/parsuite"

# Inveigh
print_status "Installing Inveigh..."
cd "$TOOLS_DIR"

if [ -d "$TOOLS_DIR/Inveigh" ]; then
    cd "$TOOLS_DIR/Inveigh"
    git pull >> "$LOG_DIR/inveigh_update.log" 2>&1
    print_status "Inveigh repository updated."
else
    print_status "Cloning Inveigh repository..."
    git clone https://github.com/Kevin-Robertson/Inveigh.git "$TOOLS_DIR/Inveigh" >> "$LOG_DIR/inveigh_clone.log" 2>&1
    cd "$TOOLS_DIR/Inveigh"
fi

print_status "Building Inveigh..."

# Install .NET SDK if not already installed
if ! command -v dotnet &> /dev/null; then
    print_status "Installing .NET SDK..."
    wget https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    dpkg -i packages-microsoft-prod.deb
    apt-get update
    apt-get install -y dotnet-sdk-6.0
    rm packages-microsoft-prod.deb
fi

# Build Inveigh targeting .NET 6.0 (cross-platform)
print_status "Building Inveigh for .NET 6.0..."
cd "$TOOLS_DIR/Inveigh"
dotnet publish -r linux-x64 -f net6.0 -p:AssemblyName=inveigh >> "$LOG_DIR/inveigh_build.log" 2>&1

if [ $? -eq 0 ]; then
    print_success "Inveigh built successfully."
    
    # Find the built executable
    INVEIGH_BINARY=$(find "$TOOLS_DIR/Inveigh" -name "inveigh" -type f -executable | head -1)
    
    if [ -n "$INVEIGH_BINARY" ]; then
        # Create a symbolic link to make Inveigh accessible from anywhere
        ln -sf "$INVEIGH_BINARY" "/usr/local/bin/inveigh"
        chmod +x "/usr/local/bin/inveigh"
        
        # Create desktop shortcut
        create_desktop_shortcut "Inveigh" "inveigh" "utilities-terminal" "Security;Network;"
        
        print_success "Inveigh installed successfully and available as 'inveigh' command."
        log_result "inveigh" "SUCCESS" "Built and installed successfully"
    else
        print_error "Built Inveigh binary not found."
        log_result "inveigh" "PARTIAL" "Built successfully but binary not found"
    fi
else
    print_error "Failed to build Inveigh."
    
    # Try alternative build approach with self-contained deployment
    print_status "Trying alternative build approach..."
    dotnet publish --self-contained=true -p:PublishSingleFile=true -r linux-x64 -f net6.0 -p:AssemblyName=inveigh >> "$LOG_DIR/inveigh_alt_build.log" 2>&1
    
    if [ $? -eq 0 ]; then
        print_success "Inveigh built successfully with alternative method."
        
        # Find the built executable
        INVEIGH_BINARY=$(find "$TOOLS_DIR/Inveigh" -name "inveigh" -type f -executable | head -1)
        
        if [ -n "$INVEIGH_BINARY" ]; then
            # Create a symbolic link to make Inveigh accessible from anywhere
            ln -sf "$INVEIGH_BINARY" "/usr/local/bin/inveigh"
            chmod +x "/usr/local/bin/inveigh"
            
            # Create desktop shortcut
            create_desktop_shortcut "Inveigh" "inveigh" "utilities-terminal" "Security;Network;"
            
            print_success "Inveigh installed successfully and available as 'inveigh' command."
            log_result "inveigh" "SUCCESS" "Built and installed successfully with alternative method"
        else
            print_error "Built Inveigh binary not found."
            log_result "inveigh" "PARTIAL" "Built successfully but binary not found"
        fi
    else
        print_error "All build attempts for Inveigh failed."
        log_result "inveigh" "FAILED" "Build failed. See logs for details."
    fi
fi

# Nuclei
print_status "Installing Nuclei..."
run_with_timeout "GO111MODULE=on go install -v github.com/projectdiscovery/nuclei/v2/cmd/nuclei@latest" 300 "$LOG_DIR/nuclei_install.log" "nuclei"
if [ $? -ne 0 ]; then
    print_error "Failed to install Nuclei with go install."
    log_result "nuclei" "FAILED" "Go installation failed. See $LOG_DIR/nuclei_install.log for details."
    install_github_tool "https://github.com/projectdiscovery/nuclei"
else
    print_success "Nuclei installed with go install."
    log_result "nuclei" "SUCCESS" "Installed with go install"
fi

# Kali-anonsurf
install_github_tool "https://github.com/Und3rf10w/kali-anonsurf"
cd "$TOOLS_DIR/kali-anonsurf"
git clone https://github.com/Und3rf10w/kali-anonsurf.git
run_with_timeout "./installer.sh" 300 "$LOG_DIR/kali-anonsurf_install.log" "kali-anonsurf"
if [ $? -ne 0 ]; then
    print_error "Failed to install Kali-anonsurf with installer script."
    log_result "kali-anonsurf" "PARTIAL" "Installer script failed. See $LOG_DIR/kali-anonsurf_install.log for details."
else
    print_success "Kali-anonsurf installed with installer script."
    log_result "kali-anonsurf" "SUCCESS" "Installed with installer script"
fi

# Bettercap
install_apt_package "bettercap"

# BFG Repo Cleaner
print_status "Installing BFG Repo Cleaner..."
cd "$TOOLS_DIR"
download_binary "https://repo1.maven.org/maven2/com/madgag/bfg/1.14.0/bfg-1.14.0.jar" "bfg.jar"
if [ $? -eq 0 ]; then
    cat > /usr/local/bin/bfg << 'EOF'
#!/bin/bash
java -jar /opt/security-tools/bfg.jar "$@"
EOF
    chmod +x /usr/local/bin/bfg
    print_success "BFG Repo Cleaner installed and linked."
    log_result "bfg" "SUCCESS" "Installed and linked to /usr/local/bin"
fi

# SecLists
apt install seclists

# Proxychains
apt install proxychains4

# Impacket
install_with_pipx "impacket" || {
    print_info "Trying alternative installation method for Impacket..."
    install_github_tool "https://github.com/fortra/impacket"
}

# Burp Enterprise
print_status "Installing Burp Enterprise..."
BURP_ENTERPRISE_ZIP="$HOME/Desktop/burp_enterprise_linux_v2025_2.zip"

# Search for the file in common locations if not found at the specified path
if [ ! -f "$BURP_ENTERPRISE_ZIP" ]; then
    print_status "Burp Enterprise ZIP not found at $BURP_ENTERPRISE_ZIP, searching in common locations..."
    BURP_ENTERPRISE_ZIP=$(find "$HOME/Desktop" "$HOME/Downloads" -maxdepth 1 -name "burp_enterprise*.zip" | head -1)
fi

if [ -f "$BURP_ENTERPRISE_ZIP" ]; then
    print_status "Found Burp Enterprise ZIP at $BURP_ENTERPRISE_ZIP"
    # Installation code as previously provided
    # ...
else
    print_error "Burp Enterprise ZIP file not found. Please download it and place it in your Desktop or Downloads folder."
    print_info "Once downloaded, you can run: sudo $TOOLS_DIR/install_burp_enterprise.sh"
    
    # Create a helper script
    cat > "$TOOLS_DIR/install_burp_enterprise.sh" << 'EOF'
#!/bin/bash
# Helper script to install Burp Enterprise

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "Burp Enterprise Installation Helper"
echo "=================================="

# Try to find the ZIP file
BURP_ENTERPRISE_ZIP=$(find "$HOME/Desktop" "$HOME/Downloads" -maxdepth 1 -name "burp_enterprise*.zip" | head -1)

if [ -z "$BURP_ENTERPRISE_ZIP" ]; then
    echo "Please enter the full path to the Burp Enterprise ZIP file:"
    read BURP_ENTERPRISE_ZIP
fi

if [ ! -f "$BURP_ENTERPRISE_ZIP" ]; then
    echo "File not found: $BURP_ENTERPRISE_ZIP"
    exit 1
fi

INSTALL_DIR="/opt/burp-enterprise"
mkdir -p "$INSTALL_DIR"

echo "Extracting Burp Enterprise from $BURP_ENTERPRISE_ZIP..."
unzip -q "$BURP_ENTERPRISE_ZIP" -d "$INSTALL_DIR"

# Find the installer
INSTALLER=$(find "$INSTALL_DIR" -name "*.run" | head -1)

if [ -n "$INSTALLER" ]; then
    echo "Found installer: $(basename "$INSTALLER")"
    chmod +x "$INSTALLER"
    
    echo "Running installer..."
    "$INSTALLER" --quiet
    
    # Create desktop shortcut
    cat > /usr/share/applications/burp-enterprise.desktop << EOD
[Desktop Entry]
Name=Burp Enterprise
Comment=Burp Enterprise Security Testing
Exec=/opt/BurpSuiteEnterprise/burpsuite_enterprise
Type=Application
Icon=/opt/BurpSuiteEnterprise/burpsuite_enterprise.png
Terminal=false
Categories=Security;
EOD
    
    echo "Burp Enterprise installed successfully."
else
    # Check for JAR file
    JAR_INSTALLER=$(find "$INSTALL_DIR" -name "*.jar" | head -1)
    
    if [ -n "$JAR_INSTALLER" ]; then
        echo "Found JAR installer: $(basename "$JAR_INSTALLER")"
        
        # Create wrapper script
        cat > "$INSTALL_DIR/burpsuite_enterprise" << EOD
#!/bin/bash
cd "$INSTALL_DIR"
java -jar "$(basename "$JAR_INSTALLER")" "\$@"
EOD
        chmod +x "$INSTALL_DIR/burpsuite_enterprise"
        
        # Create symlink
        ln -sf "$INSTALL_DIR/burpsuite_enterprise" "/usr/local/bin/burpsuite_enterprise"
        
        # Create desktop shortcut
        cat > /usr/share/applications/burp-enterprise.desktop << EOD
[Desktop Entry]
Name=Burp Enterprise
Comment=Burp Enterprise Security Testing
Exec=burpsuite_enterprise
Type=Application
Terminal=false
Categories=Security;
EOD
        
        echo "Burp Enterprise JAR set up successfully."
    else
        echo "No installer found in the ZIP file."
    fi
fi
EOF
    
    chmod +x "$TOOLS_DIR/install_burp_enterprise.sh"
    log_result "burp-enterprise" "MANUAL" "ZIP file not found. Run the helper script after downloading"
fi

# VMware Remote Console (note: this might need manual installation)
print_status "VMware Remote Console needs to be downloaded manually from: https://knowledge.broadcom.com/external/article/368995/download-vmware-remote-console.html"
log_result "vmware-remote-console" "MANUAL" "Manual download required"

# RealVNC - Fixed with conflict resolution
print_status "Installing RealVNC Viewer..."
cd "$TOOLS_DIR"
download_binary "https://downloads.realvnc.com/download/file/viewer.files/VNC-Viewer-7.0.1-Linux-x64.deb" "realvnc.deb"
if [ $? -eq 0 ]; then
    # Check if xtightvncviewer is installed and remove it before installing RealVNC
    if dpkg -l | grep -q xtightvncviewer; then
        print_status "Detected xtightvncviewer which conflicts with RealVNC."
        print_status "Removing xtightvncviewer before installing RealVNC..."
        apt-get remove -y xtightvncviewer >> "$LOG_DIR/realvnc_install.log" 2>&1
        if [ $? -ne 0 ]; then
            print_error "Failed to remove xtightvncviewer. Skipping RealVNC installation."
            log_result "realvnc" "FAILED" "Conflict resolution failed. See $LOG_DIR/realvnc_install.log for details."
            rm realvnc.deb
        else
            dpkg -i realvnc.deb >> "$LOG_DIR/realvnc_install.log" 2>&1
            apt-get install -f -y >> "$LOG_DIR/realvnc_install.log" 2>&1
            rm realvnc.deb
            print_success "RealVNC Viewer installed after removing xtightvncviewer."
            log_result "realvnc" "SUCCESS" "Installed (replaced xtightvncviewer)"
        fi
    else
        dpkg -i realvnc.deb >> "$LOG_DIR/realvnc_install.log" 2>&1
        apt-get install -f -y >> "$LOG_DIR/realvnc_install.log" 2>&1
        rm realvnc.deb
        print_success "RealVNC Viewer installed."
        log_result "realvnc" "SUCCESS" "Installed"
    fi
fi

# TeamViewer Host
print_status "Installing TeamViewer Host..."
cd "$TOOLS_DIR"

# Fix the policykit-1 package maintainer field
print_status "Fixing policykit-1 package metadata..."
mkdir -p "$TOOLS_DIR/policykit-dummy-fixed/DEBIAN"

# Create updated control file with Maintainer field
cat > "$TOOLS_DIR/policykit-dummy-fixed/DEBIAN/control" << EOF
Package: policykit-1
Version: 1.0
Section: misc
Priority: optional
Architecture: all
Depends: polkitd, pkexec
Maintainer: System Administrator <root@localhost>
Description: Transitional package for PolicyKit 
 This is a dummy package that provides policykit-1 while depending on
 modern PolicyKit packages polkitd and pkexec.
EOF

# Build the updated package
print_status "Building updated policykit-1 package..."
dpkg-deb -b "$TOOLS_DIR/policykit-dummy-fixed" "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

# Install the updated package
print_status "Installing updated policykit-1 package..."
dpkg -i "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb" >> "$LOG_DIR/policykit_fix.log" 2>&1

if [ $? -eq 0 ]; then
    print_success "Fixed policykit-1 package metadata."
    
    # Clean up
    rm -rf "$TOOLS_DIR/policykit-dummy-fixed"
    rm -f "$TOOLS_DIR/policykit-1_1.0_all_fixed.deb"
else
    print_error "Failed to fix policykit-1 package metadata. The warning will continue but it's safe to ignore."
fi

# Use the TeamViewer Host package from the Desktop
TEAMVIEWER_HOST_DEB="/home/rmcyber/Desktop/teamviewer-host_15.63.4_amd64.deb"

if [ -f "$TEAMVIEWER_HOST_DEB" ]; then
    # Install TeamViewer Host directly with dpkg
    print_status "Installing TeamViewer Host package from $TEAMVIEWER_HOST_DEB..."
    dpkg --install "$TEAMVIEWER_HOST_DEB" >> "$LOG_DIR/teamviewer_host_install.log" 2>&1
    
    # Fix any dependencies
    apt-get install -f -y >> "$LOG_DIR/teamviewer_fix_deps.log" 2>&1
    
    # Check if installation was successful
    if dpkg -l | grep -q "teamviewer-host"; then
        print_success "TeamViewer Host installed successfully."
        
        # Configure TeamViewer to start automatically at system boot
        print_status "Configuring TeamViewer Host to start at boot..."
        teamviewer daemon enable >> "$LOG_DIR/teamviewer_autostart.log" 2>&1
        systemctl enable teamviewerd.service >> "$LOG_DIR/teamviewer_autostart.log" 2>&1
        
        # Start TeamViewer daemon if not already running
        print_status "Starting TeamViewer daemon..."
        teamviewer daemon start >> "$LOG_DIR/teamviewer_start.log" 2>&1
        sleep 5  # Give daemon time to start
        
        # Enable easy access (unattended access)
        print_status "Enabling easy access..."
        teamviewer setup --grant-easy-access >> "$LOG_DIR/teamviewer_easy_access.log" 2>&1
        
        # Get the TeamViewer ID for reference
        TEAMVIEWER_ID=$(teamviewer info | grep "TeamViewer ID:" | awk '{print $3}')
        print_info "Your TeamViewer ID is: $TEAMVIEWER_ID"
        print_info "Please add this ID to your TeamViewer account for remote access."
        
        # Create desktop shortcut
        create_desktop_shortcut "TeamViewer Host" "teamviewer" "/opt/teamviewer/tv_bin/desktop/teamviewer.png" "Network;RemoteAccess;Security;"
        
        # Start TeamViewer application
        print_status "Starting TeamViewer application..."
        su - $SUDO_USER -c "teamviewer &" >> "$LOG_DIR/teamviewer_start.log" 2>&1
        
        log_result "teamviewer-host" "SUCCESS" "Installed and configured for easy access"
        
    else
        print_error "TeamViewer Host installation failed."
        
        # Create a manual installation helper
        print_status "Creating manual installation instructions..."
        cat > "$TOOLS_DIR/install_teamviewer_host_manual.sh" << 'EOF'
#!/bin/bash
# Manual TeamViewer Host installation helper for Kali Linux

echo "TeamViewer Host Installation Helper for Kali Linux"
echo "================================================"
echo "TeamViewer requires PolicyKit which has changed package names in Kali Linux."
echo ""
echo "Please follow these steps to install TeamViewer Host:"
echo ""
echo "1. Create a dummy policykit-1 package:"
echo "   mkdir -p ~/policykit-dummy/DEBIAN"
echo ""
echo "2. Create the control file:"
echo "   cat > ~/policykit-dummy/DEBIAN/control << EOT"
echo "   Package: policykit-1"
echo "   Version: 1.0"
echo "   Section: misc"
echo "   Priority: optional"
echo "   Architecture: all"
echo "   Depends: polkitd, pkexec"
echo "   Description: Transitional package for PolicyKit"
echo "    This is a dummy package that provides policykit-1."
echo "   EOT"
echo ""
echo "3. Build and install the package:"
echo "   sudo apt-get install -y polkitd pkexec"
echo "   dpkg-deb -b ~/policykit-dummy ~/policykit-1_1.0_all.deb"
echo "   sudo dpkg -i ~/policykit-1_1.0_all.deb"
echo ""
echo "4. Install TeamViewer Host:"
echo "   sudo dpkg --install /home/rmcyber/Desktop/teamviewer-host_15.63.4_amd64.deb"
echo "   sudo apt-get install -f -y"
echo ""
echo "5. Configure TeamViewer Host to start at boot:"
echo "   sudo teamviewer daemon enable"
echo "   sudo systemctl enable teamviewerd.service"
echo ""
echo "6. Start TeamViewer daemon and enable easy access:"
echo "   sudo teamviewer daemon start"
echo "   sudo teamviewer setup --grant-easy-access"
echo ""
echo "7. Get your TeamViewer ID to add to your account:"
echo "   teamviewer info"
echo "   # Note the TeamViewer ID and add it to your account"
echo ""
echo "8. Start TeamViewer application:"
echo "   teamviewer"
EOF
            
        chmod +x "$TOOLS_DIR/install_teamviewer_host_manual.sh"
        print_info "Created manual installation helper: $TOOLS_DIR/install_teamviewer_host_manual.sh"
        log_result "teamviewer-host" "MANUAL" "Installation failed. Manual installation instructions created."
    fi
else
    print_error "TeamViewer Host package not found at $TEAMVIEWER_HOST_DEB"
    print_info "Please ensure the TeamViewer Host package is in the correct location."
    log_result "teamviewer-host" "FAILED" "Package not found at specified location."
fi

# Nessus
print_status "Installing Nessus..."
cd "$TOOLS_DIR"

# Try direct download with curl first
print_status "Attempting to download Nessus..."
run_with_timeout "curl -k --request GET --url 'https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-10.8.3-debian10_amd64.deb' --output nessus_amd64.deb" 300 "$LOG_DIR/nessus_download.log" "nessus"

# Check if download succeeded
if [ $? -eq 0 ] && [ -f "nessus_amd64.deb" ]; then
    # Install the package
    print_status "Installing Nessus package..."
    dpkg -i nessus_amd64.deb >> "$LOG_DIR/nessus_install.log" 2>&1
    apt-get install -f -y >> "$LOG_DIR/nessus_install.log" 2>&1
    
    # Start the Nessus service
    print_status "Starting Nessus service..."
    systemctl enable nessusd >> "$LOG_DIR/nessus_install.log" 2>&1
    systemctl start nessusd >> "$LOG_DIR/nessus_install.log" 2>&1
    
    # Create desktop entry
    cat > /usr/share/applications/nessus.desktop << EOF
[Desktop Entry]
Name=Nessus
Exec=xdg-open https://localhost:8834/
Type=Application
Icon=/opt/nessus/var/nessus/www/favicon.ico
Terminal=false
Categories=Security;
EOF
    
    print_success "Nessus installed and service started."
    print_info "Access Nessus at https://localhost:8834/ to complete setup and register."
    log_result "nessus" "SUCCESS" "Installed and service started. Complete setup at https://localhost:8834/"
    
    # Clean up
    rm -f nessus_amd64.deb
else
    print_error "Direct download failed. Trying alternative download method..."
    
    # Try using wget with different options as an alternative
    run_with_timeout "wget --no-check-certificate https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-10.8.3-debian10_amd64.deb -O nessus_alt.deb" 300 "$LOG_DIR/nessus_alt_download.log" "nessus"
    
    if [ $? -eq 0 ] && [ -f "nessus_alt.deb" ]; then
        print_status "Alternative download successful. Installing Nessus..."
        dpkg -i nessus_alt.deb >> "$LOG_DIR/nessus_alt_install.log" 2>&1
        apt-get install -f -y >> "$LOG_DIR/nessus_alt_install.log" 2>&1
        
        # Start the Nessus service
        systemctl enable nessusd >> "$LOG_DIR/nessus_alt_install.log" 2>&1
        systemctl start nessusd >> "$LOG_DIR/nessus_alt_install.log" 2>&1
        
        # Create desktop entry (same as above)
        cat > /usr/share/applications/nessus.desktop << EOF
[Desktop Entry]
Name=Nessus
Exec=xdg-open https://localhost:8834/
Type=Application
Icon=/opt/nessus/var/nessus/www/favicon.ico
Terminal=false
Categories=Security;
EOF
        
        print_success "Nessus installed and service started (alternative method)."
        print_info "Access Nessus at https://localhost:8834/ to complete setup and register."
        log_result "nessus" "SUCCESS" "Installed via alternative download method"
        
        # Clean up
        rm -f nessus_alt.deb
    else
        print_error "All download attempts failed. Creating manual installation helper..."
        
        # Create a helper script as fallback
        cat > "$TOOLS_DIR/install_nessus.sh" << 'EOF'
#!/bin/bash
# Helper script to install Nessus

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "Nessus Installation Helper"
echo "=========================="
echo "This script will attempt to download and install Nessus."
echo ""
echo "Option 1: Try downloading with curl"
curl -k --request GET \
     --url 'https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-10.8.3-debian10_amd64.deb' \
     --output 'Nessus-10.8.3-debian10_amd64.deb'

if [ ! -f "Nessus-10.8.3-debian10_amd64.deb" ]; then
    echo "Option 2: Try downloading with wget"
    wget --no-check-certificate -O Nessus-10.8.3-debian10_amd64.deb \
         https://www.tenable.com/downloads/api/v2/pages/nessus/files/Nessus-10.8.3-debian10_amd64.deb
fi

if [ ! -f "Nessus-10.8.3-debian10_amd64.deb" ]; then
    echo "Both download attempts failed."
    echo ""
    echo "Please download Nessus manually from Tenable's website:"
    echo "https://www.tenable.com/downloads/nessus"
    echo ""
    echo "After downloading, run:"
    echo "sudo dpkg -i Nessus-*.deb"
    echo "sudo apt-get install -f -y"
    echo "sudo systemctl enable nessusd"
    echo "sudo systemctl start nessusd"
    exit 1
fi

echo "Installing Nessus..."
dpkg -i Nessus-10.8.3-debian10_amd64.deb
apt-get install -f -y

echo "Starting Nessus service..."
systemctl enable nessusd
systemctl start nessusd

# Create desktop entry
cat > /usr/share/applications/nessus.desktop << EOD
[Desktop Entry]
Name=Nessus
Exec=xdg-open https://localhost:8834/
Type=Application
Icon=/opt/nessus/var/nessus/www/favicon.ico
Terminal=false
Categories=Security;
EOD

echo "Nessus installed successfully!"
echo "Access Nessus at https://localhost:8834/ to complete setup and register."
rm -f Nessus-10.8.3-debian10_amd64.deb
EOF
        
        chmod +x "$TOOLS_DIR/install_nessus.sh"
        print_info "Created helper script: $TOOLS_DIR/install_nessus.sh"
        print_info "Run the helper script to try installation again: sudo $TOOLS_DIR/install_nessus.sh"
        log_result "nessus" "MANUAL" "Download failed. Helper script created for manual installation."
    fi
fi

# Configuration
CONFIG_FILE="/opt/security-tools/config.yml"
LOG_DIR="/opt/security-tools/logs"
TOOLS_DIR="/opt/security-tools"
VENV_DIR="$TOOLS_DIR/venvs"

# Initialize logging
setup_logging() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$LOG_DIR"
    exec 3>&1 4>&2
    trap 'exec 1>&3 2>&4' 0 1 2 3
    exec 1>"$LOG_DIR/install_$timestamp.log" 2>&1
}

# Enhanced error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    logger "ERROR" "Failed at line $line_number with exit code $exit_code"
    cleanup
    exit $exit_code
}
trap 'handle_error ${LINENO}' ERR

# Structured logging
logger() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_DIR/install.log"
}

# Cleanup function
cleanup() {
    logger "INFO" "Running cleanup..."
    # Remove partial installations
    rm -rf /tmp/security-tools-*
    # Reset package manager
    apt-get clean
    apt-get update
}

# Package verification
verify_package() {
    local package=$1
    local checksum=$2
    logger "INFO" "Verifying package: $package"
    echo "$checksum $package" | sha256sum -c - || return 1
}

# Enhanced download with retry
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [ $attempt -le $max_attempts ]; do
        logger "INFO" "Download attempt $attempt of $max_attempts"
        if wget --no-check-certificate "$url" -O "$output" 2>/dev/null; then
            logger "SUCCESS" "Download successful"
            return 0
        fi
        attempt=$((attempt + 1))
        wait_time=$((wait_time * 2))
        logger "WARN" "Download failed, waiting ${wait_time}s before retry"
        sleep $wait_time
    done
    return 1
}

# Parallel installation
install_parallel() {
    local packages=("$@")
    local pids=()
    
    for package in "${packages[@]}"; do
        (apt-get install -y --no-install-recommends "$package") &
        pids+=($!)
    done

    # Wait for all installations to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
}

# Main installation function
main() {
    setup_logging
    logger "INFO" "Starting security tools installation"

    # Load configuration
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        logger "WARN" "Configuration file not found, using defaults"
    fi

    # Update system
    logger "INFO" "Updating system packages"
    apt-get update
    apt-get upgrade -y

    # Install dependencies in parallel
    logger "INFO" "Installing dependencies"
    install_parallel git python3 python3-pip python3-venv golang nodejs npm curl wget

    # Install and configure tools
    install_tools
    
    logger "INFO" "Installation complete"
    cleanup
}

# Tool installation function
install_tools() {
    local tools=(
        "nmap"
        "wireshark"
        "metasploit-framework"
        "burpsuite"
        "sqlmap"
        "hydra"
    )

    for tool in "${tools[@]}"; do
        logger "INFO" "Installing $tool"
        if ! apt-get install -y --no-install-recommends "$tool"; then
            logger "ERROR" "Failed to install $tool"
            continue
        fi
        
        # Configure tool-specific settings
        configure_tool "$tool"
    done
}

# Tool configuration
configure_tool() {
    local tool=$1
    logger "INFO" "Configuring $tool"

    case "$tool" in
        "burpsuite")
            setup_burpsuite
            ;;
        "metasploit-framework")
            setup_metasploit
            ;;
        *)
            logger "INFO" "No specific configuration needed for $tool"
            ;;
    esac
}

# Run main function
main "$@"

# Create desktop shortcuts for web tools
print_status "Creating desktop shortcuts for web tools..."
mkdir -p /usr/share/applications

cat > /usr/share/applications/fastpeoplesearch.desktop << EOF
[Desktop Entry]
Name=Fast People Search
Exec=xdg-open https://www.fastpeoplesearch.com/names
Type=Application
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
EOF

cat > /usr/share/applications/virustotal.desktop << EOF
[Desktop Entry]
Name=VirusTotal
Exec=xdg-open https://www.virustotal.com/gui/home/search
Type=Application
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
EOF

print_success "Desktop shortcuts created."
log_result "desktop-shortcuts" "SUCCESS" "Created"

# Create a simple script to set up environment variables
print_status "Creating environment setup script..."

cat > "$TOOLS_DIR/setup_env.sh" << 'EOF'
#!/bin/bash
# Source this file to set up environment variables and paths for all tools

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

# Add to bashrc
echo "# Security tools environment setup" >> ~/.bashrc
echo "[ -f /opt/security-tools/setup_env.sh ] && source /opt/security-tools/setup_env.sh" >> ~/.bashrc

# Record end time and calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# Generate installation summary
echo "" >> $REPORT_FILE
echo "Installation Summary:" >> $REPORT_FILE
echo "--------------------" >> $REPORT_FILE
echo "Duration: $MINUTES minutes and $SECONDS seconds" >> $REPORT_FILE
echo "" >> $REPORT_FILE

# Count success, partial, failed, manual
SUCCESS_COUNT=$(grep -c "\[SUCCESS\]" $REPORT_FILE)
PARTIAL_COUNT=$(grep -c "\[PARTIAL\]" $REPORT_FILE)
FAILED_COUNT=$(grep -c "\[FAILED\]" $REPORT_FILE)
MANUAL_COUNT=$(grep -c "\[MANUAL\]" $REPORT_FILE)

echo "Successfully installed: $SUCCESS_COUNT" >> $REPORT_FILE
echo "Partially installed: $PARTIAL_COUNT" >> $REPORT_FILE
echo "Failed to install: $FAILED_COUNT" >> $REPORT_FILE
echo "Manual installation required: $MANUAL_COUNT" >> $REPORT_FILE

print_success "All tools have been processed. Installation report saved to $REPORT_FILE"
print_status "Installation summary:"
print_info "Successfully installed: $SUCCESS_COUNT"
print_info "Partially installed: $PARTIAL_COUNT"
print_info "Failed to install: $FAILED_COUNT"
print_info "Manual installation required: $MANUAL_COUNT"
print_status "Some tools may require additional configuration or manual steps."
print_status "You may need to source your .bashrc or log out and back in for all changes to take effect:"
print_status "    source ~/.bashrc"
echo ""
echo "Installation complete! Total time: $MINUTES minutes and $SECONDS seconds"
process_git_repositories
print_manual_installations
print_manual_installations() {
    print_status "Tools requiring manual installation:"
    echo "" >> $REPORT_FILE
    echo "Tools requiring manual installation:" >> $REPORT_FILE
    echo "-----------------------------------" >> $REPORT_FILE
    
    MANUAL_TOOLS=$(grep "\[MANUAL\]" $REPORT_FILE | sed 's/\[MANUAL\] \(.*\):.*/\1/')
    
    if [ -z "$MANUAL_TOOLS" ]; then
        print_info "No tools require manual installation."
        echo "No tools require manual installation." >> $REPORT_FILE
    else
        for tool in $MANUAL_TOOLS; do
            MANUAL_REASON=$(grep "\[MANUAL\] $tool:" $REPORT_FILE | sed 's/\[MANUAL\] .*: \(.*\)/\1/')
            print_info "- $tool: $MANUAL_REASON"
            echo "- $tool: $MANUAL_REASON" >> $REPORT_FILE
        done
    fi
    
    echo "" >> $REPORT_FILE
}

# Add this to process Git repositories before generating the final report
process_git_repositories() {
    print_status "Processing Git repositories that were only cloned..."
    
    # Get list of partially installed tools (likely just cloned)
    PARTIAL_REPOS=$(grep "\[PARTIAL\]" $REPORT_FILE | grep "Repository cloned" | sed 's/\[PARTIAL\] \(.*\):.*/\1/')
    
    for repo in $PARTIAL_REPOS; do
        if [ -d "$TOOLS_DIR/$repo" ]; then
            process_git_repo "$repo"
        fi
    done
}
