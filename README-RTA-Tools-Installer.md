
# 🧰 RTA Tools Installer

A fully automated Kali Linux-based security toolkit installer for Remote Testing Appliances (RTAs).

## 🚀 Features

- 🔁 Fully automated setup with retry, validation, and logging
- 🛠 Optional CLI flags for core or full tool installation
- ⚡ Parallel installation to reduce setup time
- 🔐 Desktop integration (shortcuts) and post-install hardening
- 📄 Manual installation helpers generated for tools requiring GUI or special handling (e.g., Nessus, VMware Remote Console, Burp Suite Enterprise, NinjaOne)

## 📦 Tool Categories

| Type       | Source     | Examples                                                |
|------------|------------|---------------------------------------------------------|
| APT        | Kali repos | `nmap`, `wireshark`, `sqlmap`, `bettercap`, `hydra`     |
| pipx       | PyPi       | `scoutsuite`, `impacket`, `pymeta`                      |
| Git        | GitHub     | `prowler`, `parsuite`, `evilgophish`, `kali-anonsurf`   |
| Manual     | Local file | `nessus`, `burpsuite_enterprise`, `teamviewer`, `ninjaone` |

## ⚙️ CLI Usage

```bash
# Clone repo
git clone https://github.com/Richey-May-Cyber/RTABuilder.git
cd RTABuilder/installer

# Run as root
sudo ./installer.sh --core-only    # Fast install with just core tools
sudo ./installer.sh --full         # Full install with GitHub tools, pipx, apt, and helpers
```

## 🧾 Configuration

The YAML config at `/opt/security-tools/config.yml` contains the list of tools to install:

```yaml
apt_tools: "nmap,wireshark,sqlmap,hydra,bettercap,seclists,proxychains4,responder,metasploit-framework"
pipx_tools: "scoutsuite,impacket,pymeta"
git_tools: "https://github.com/prowler-cloud/prowler.git,https://github.com/ImpostorKeanu/parsuite.git,https://github.com/fin3ss3g0d/evilgophish.git,https://github.com/Und3rf10w/kali-anonsurf.git"
```

## 🪛 Manual Tools

The script detects and builds helper scripts for tools that cannot be installed automatically:

| Tool                  | Notes                                               |
|-----------------------|-----------------------------------------------------|
| Nessus                | Downloads from Tenable and configures local web UI |
| VMware Remote Console | Must be downloaded manually and run with `.bundle` |
| Burp Suite Enterprise | Installs from local `.run` or `.jar`               |
| TeamViewer Host       | Installs with workaround for deprecated dependency |
| NinjaOne              | Installs via `wine` if present, or helper created  |

Helpers are saved to:

```bash
/opt/security-tools/helpers/install_<tool>.sh
```

Run them as needed:

```bash
sudo /opt/security-tools/helpers/install_ninjaone.sh
```

## 📜 Post-Install: Disable Lock Screen

Optional script provided to ensure RTAs don’t lock during testing:

```bash
chmod +x /opt/security-tools/scripts/disable-lock-screen.sh
sudo /opt/security-tools/scripts/disable-lock-screen.sh
```

Script disables screen lock in both GNOME and XFCE, and turns off DPMS.

## 📂 File Structure

```
installer/
├── installer.sh                      # Main entry point
├── config.yml                        # List of tools to install
├── helpers/                          # Manual install scripts
├── logs/                             # Logs per tool and overall
└── scripts/disable-lock-screen.sh    # Optional UX hardening
```

## 🧪 Status

✅ Fully tested on Kali 2024.1
