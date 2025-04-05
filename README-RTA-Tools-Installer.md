# 🛡️ Improved RTA Tools Installer

A robust, efficient, and reliable toolkit installer for Kali Linux Remote Testing Appliances (RTAs). This solution streamlines the setup and redeployment process for security testing environments.

## 🚀 Features

- **Comprehensive Toolkit**: Installs and configures 75+ security testing tools
- **Efficient Installation**: Parallel processing for faster deployment
- **Robust Error Handling**: Improved retry mechanisms and conflict resolution
- **Desktop Integration**: Creates shortcuts, sets up environment, and disables screen lock
- **Configuration**: YAML-based configuration for easy customization
- **Deployment Options**: Full installation, core tools only, or desktop-only mode
- **Helper Scripts**: Automated generators for tools requiring manual installation
- **Documentation**: Detailed reports and system snapshots

## 📋 Components

The solution consists of two main scripts:

1. **`rta_installer.sh`**: The main installer script that handles tool installation
2. **`deploy-rta.sh`**: A deployment wrapper that configures the entire system

## 🛠️ Installation

### Quick Start

```bash
# Download and run the deployment script
curl -sSL https://raw.githubusercontent.com/yourusername/rta-installer/main/deploy-rta.sh -o deploy-rta.sh
chmod +x deploy-rta.sh
sudo ./deploy-rta.sh
```

### Installation Options

```bash
# Full interactive installation
sudo ./deploy-rta.sh --interactive

# Fully automated installation
sudo ./deploy-rta.sh --auto

# Direct tool installation only
sudo ./rta_installer.sh --full       # Install all tools
sudo ./rta_installer.sh --core-only  # Install core tools only
sudo ./rta_installer.sh --desktop-only # Set up desktop shortcuts only
```

## 📦 Tool Categories

The installer handles tools from multiple sources:

| Type       | Source     | Examples                                                       |
|------------|------------|----------------------------------------------------------------|
| APT        | Kali repos | `nmap`, `wireshark`, `sqlmap`, `metasploit-framework`, etc.    |
| PIPX       | PyPI       | `scoutsuite`, `impacket`, `pymeta`, `trufflehog`, etc.         |
| Git        | GitHub     | `prowler`, `parsuite`, `evilgophish`, `CyberChef`, etc.        |
| Manual     | Various    | `nessus`, `burpsuite_enterprise`, `teamviewer`, etc.           |

## ⚙️ Configuration

The main configuration file is located at `/opt/security-tools/config/config.yml`:

```yaml
# Core apt tools - installed with apt-get
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,seclists,proxychains4,..."

# Python tools - installed with pipx
pipx_tools: "scoutsuite,impacket,pymeta,fierce,pwnedpasswords,trufflehog,..."

# GitHub repositories
git_tools: "https://github.com/prowler-cloud/prowler.git,..."

# Manual tools - installation helpers will be generated
manual_tools: "nessus,vmware_remote_console,burpsuite_enterprise,teamviewer,ninjaone"
```

## 📊 Reporting and Logging

The installer maintains detailed logs for troubleshooting:

- **Installation Report**: `/opt/security-tools/logs/installation_report_*.txt`
- **Tool-specific Logs**: `/opt/security-tools/logs/<tool_name>_*.log`
- **System Snapshot**: `/opt/security-tools/system-state/system-snapshot-*.txt`

## 🧰 Directory Structure

```
/opt/security-tools/
├── bin/              # Executable symlinks
├── config/           # Configuration files
├── desktop/          # Desktop shortcuts
├── helpers/          # Helper scripts for manual tools
├── logs/             # Installation logs
├── scripts/          # Utility scripts
├── system-state/     # System snapshots
├── temp/             # Temporary files
└── venvs/            # Python virtual environments
```

## 📝 Manual Installation Helpers

For tools that require manual installation, helper scripts are generated at `/opt/security-tools/helpers/`:

```bash
# Example: Install Nessus
sudo /opt/security-tools/helpers/install_nessus.sh

# Example: Install TeamViewer
sudo /opt/security-tools/helpers/install_teamviewer.sh
```

## 🔄 Redeployment

To redeploy your RTA after a wipe:

1. Boot up your fresh Kali Linux installation
2. Download the deployment script:
   ```bash
   curl -sSL https://raw.githubusercontent.com/yourusername/rta-installer/main/deploy-rta.sh -o deploy-rta.sh
   chmod +x deploy-rta.sh
   ```
3. Run the deployment script:
   ```bash
   sudo ./deploy-rta.sh --auto  # For fully automated installation
   ```

## 🔧 Customization

You can customize the installer by:

1. Modifying `/opt/security-tools/config/config.yml` to add/remove tools
2. Creating custom deployment configurations in `/opt/security-tools/config/`
3. Adding custom scripts to `/opt/security-tools/scripts/`

## 📋 Future Improvements

- Add support for containerized tools (Docker)
- Implement tool version control and update mechanism
- Add configuration profiles for different testing scenarios
- Integrate with VM snapshotting for faster reversion

## 📜 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
