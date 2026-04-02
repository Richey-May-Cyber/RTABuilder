# RTA Deployment Script v4.0

Automated deployment system for Kali Linux Remote Testing Appliances. Installs, configures, and validates 75+ security tools with comprehensive error handling, parallel processing, and a built-in dry-run mode.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/Richey-May-Cyber/RTABuilder.git /opt/rta-deployment
cd /opt/rta-deployment

# Preview what will happen (no system changes)
sudo ./deploy-rta.sh --auto --dry-run

# Fully automated install
sudo ./deploy-rta.sh --auto
```

## What Gets Installed

**APT packages (70+):** nmap, wireshark, sqlmap, hydra, metasploit-framework, bloodhound, burpsuite, responder, seclists, gobuster, ffuf, hashcat, john, crackmapexec, and more.

**Python tools via PIPX (30+):** impacket, scoutsuite, bloodhound-python, certipy, evil-winrm, autorecon, nuclei, trufflehog, and more.

**Git repositories (25+):** PayloadsAllTheThings, SecLists, PEASS-ng, BloodHound, Empire, CyberChef, EyeWitness, and more.

**BloodHound CE:** Docker-based BloodHound Community Edition with a systemd service, the bloodhound-python ingestor, and SharpHound collector.

**Manual tools:** Nessus, BurpSuite Enterprise, TeamViewer, NinjaOne, GoPhish, Evilginx3 (via helper scripts in `installer/scripts/`).

**Reference cheatsheets:** 60+ security reference files deployed to `/opt/security-tools/references/`.

## CLI Flags

```
--auto              Fully automated, no prompts
--interactive       Step-by-step with confirmation prompts (default)
--dry-run           Simulate install — logs what WOULD happen, changes nothing
--verbose           Show debug-level output
--force-reinstall   Reinstall everything, even if already present
--skip-downloads    Skip git clone / external downloads
--skip-update       Skip apt-get update
--core-only         Install core APT + PIPX tools only
--desktop-only      Desktop environment setup only
--reinstall-failed  Re-run only for tools that failed validation
--repo URL          Use a custom GitHub repository URL
--help              Show help and exit
```

## Installation Modes

| Command | What it does |
|---|---|
| `sudo ./deploy-rta.sh --auto` | Full unattended install — installs everything |
| `sudo ./deploy-rta.sh --interactive` | Step-by-step with prompts for each stage |
| `sudo ./deploy-rta.sh --auto --core-only` | APT + PIPX tools only (no git repos, no BloodHound) |
| `sudo ./deploy-rta.sh --auto --desktop-only` | Desktop shortcuts and system config only |
| `sudo ./deploy-rta.sh --auto --dry-run` | Simulate the entire install without touching the system |

## BloodHound CE

The script installs BloodHound Community Edition using Docker Compose. After install:

```bash
# Start BloodHound CE
sudo systemctl start bloodhound-ce

# Access the web UI at http://localhost:8080
# Default credentials are printed in the Docker logs:
sudo docker compose -f /opt/security-tools/bloodhound-ce/docker-compose.yml logs bloodhound

# Run the Python ingestor (installed via PIPX)
bloodhound-python -u 'user' -p 'pass' -d domain.local -c all -ns <DC_IP> --zip

# SharpHound is downloaded to /opt/security-tools/sharphound/
```

## TeamViewer on Kali Linux

Kali Linux no longer ships the `policykit-1` package, which TeamViewer requires as a dependency. The deploy script automatically handles this by building and installing a dummy `policykit-1` .deb package that depends on the modern `polkitd` and `pkexec` packages. This runs before the TeamViewer helper script executes, so the `dpkg -i` of TeamViewer proceeds without dependency errors. No manual intervention is needed.

## Reference Files

The `referencestuff/` directory contains 60+ security cheatsheets covering BloodHound, Kerberos, Active Directory, reverse shells, privilege escalation, web attacks, and more. These are automatically deployed to `/opt/security-tools/references/` during installation.

```bash
ls /opt/security-tools/references/
cat /opt/security-tools/references/bloodref
cat /opt/security-tools/references/kerbref
```

## Directory Structure

```
/opt/rta-deployment/              # Deployment files and logs
├── deploy-rta.sh                 # Main script
├── config/config.yml             # Tool lists and settings
├── referencestuff/               # Source reference files
├── installer/scripts/            # Helper scripts for manual tools
├── logs/                         # Deployment and tool-specific logs
├── downloads/                    # Downloaded packages
└── temp/                         # Temporary build files

/opt/security-tools/              # Installed tools and data
├── bin/                          # Executable symlinks
├── bloodhound-ce/                # BloodHound CE docker-compose + config
│   └── docker-compose.yml
├── sharphound/                   # SharpHound collector
├── references/                   # Security cheatsheets (deployed from referencestuff/)
├── helpers/                      # Manual tool helper scripts
├── scripts/                      # Utility scripts (validate-tools.sh, etc.)
├── desktop/                      # Desktop shortcuts
├── system-state/                 # System snapshots
└── venvs/                        # Python virtual environments
```

## Configuration

Edit `installer/config.yml` to add or remove tools before running the script. The config uses simple YAML with comma-separated lists:

```yaml
apt_tools: "nmap,wireshark,sqlmap,hydra,..."
pipx_tools: "impacket,scoutsuite,..."
git_tools: "https://github.com/org/repo.git,..."
manual_tools: "nessus,teamviewer,..."
```

## Redeployment After a Wipe

1. Boot fresh Kali Linux
2. Clone the repo: `git clone https://github.com/Richey-May-Cyber/RTABuilder.git /opt/rta-deployment`
3. Run: `cd /opt/rta-deployment && sudo ./deploy-rta.sh --auto`
4. After completion, validate: `sudo /opt/security-tools/scripts/validate-tools.sh`
5. Install any remaining manual tools using the helper scripts

## Logs and Reports

Each run generates:

- **Deployment log:** `/opt/rta-deployment/logs/deployment_<timestamp>.log` — full trace of every action
- **Summary report:** `/opt/rta-deployment/logs/deployment_summary_<timestamp>.txt` — pass/fail overview
- **System snapshot:** `/opt/security-tools/system-state/snapshot-<timestamp>.txt` — disk, memory, network, and running services

## Testing

**Dry-run mode** simulates the full installation flow without making any system changes:

```bash
sudo ./deploy-rta.sh --auto --dry-run --verbose
```

**Static analysis** with ShellCheck:

```bash
shellcheck --severity=info deploy-rta.sh
# Passes at all severity levels (info, warning, error)
```

## What Changed from v3.0

- Complete rewrite with `set -euo pipefail` and proper bash best practices
- New `--dry-run` flag for safe testing
- BloodHound CE installation (Docker + bloodhound-python + SharpHound)
- Reference cheatsheet deployment
- TeamViewer policykit-1 dependency fix built into the main flow
- Fixed NC vs RESET color variable mismatch
- Fixed parallel APT install race conditions
- Fixed FORCE_REINSTALL boolean comparison logic
- Fixed cleanup function referencing undefined variables
- Fixed spinner cleanup on error paths
- More robust YAML config parsing
- All functions are idempotent (safe to re-run)

## System Requirements

- Kali Linux (current version)
- Root access (via sudo)
- 10GB disk space (recommended)
- 2GB RAM (minimum)
- Network connectivity

## License

MIT License
