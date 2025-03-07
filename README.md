# Richey May RTA Builder

A Windows-native application for creating custom Kali Linux ISO images for Richey May's Red Team Assessment (RTA) devices. This tool allows you to easily select and inject penetration testing tools into a Kali Linux ISO, without requiring WSL or a Linux environment.

## 🌟 Features

### Core Functionality
- **Windows-Native Operation**: Build Kali Linux ISOs directly from Windows without WSL or Linux VMs
- **Custom Tool Injection**: Select from a list of penetration testing tools to include in your ISO
- **Modern GUI**: Clean, professional interface with Richey May Cyber branding
- **Progress Tracking**: Real-time progress updates and detailed logging
- **Multiple Output Formats**: Create ISO, VHD (Hyper-V), and AMI (AWS) images (VHD/AMI in future updates)

### Deployment & Image Customization
- **Custom Output Location**: Choose where to save your customized ISO
- **Tool Selection Interface**: Clean checkbox interface for selecting tools to include
- **ISO Repackaging**: Automatic extraction, modification, and repackaging of ISO files
- **Branding Options**: Add custom Richey May branding to the ISO

## 📋 Requirements

- Windows 10/11 (64-bit)
- Administrator privileges (required for ISO modification)
- Internet connection (for downloading Kali ISO if needed)
- Approximately 8GB of free disk space

## 🚀 Installation

### Option 1: Installer (Recommended)
1. Download the latest installer from the releases page
2. Run `RicheyMay_RTA_Builder_Setup.exe`
3. Follow the installation wizard instructions
4. Launch the application from the Start Menu or Desktop shortcut

### Option 2: Portable Version
1. Download the latest ZIP package from the releases page
2. Extract the ZIP file to a location of your choice
3. Run `Richey May RTA Builder.exe` to start the application

## 📝 Usage Instructions

### Basic Usage
1. **Select or Download ISO**: Choose an existing Kali ISO or download the latest version
2. **Choose Output Folder**: Select where you want to save the customized ISO
3. **Select Tools**: Check the boxes for the tools you want to include
4. **Build**: Click "Build Custom ISO" to create your customized Kali image
5. **Monitor Progress**: Watch the build log and progress bar for updates

### Advanced Options
- **Custom Hostname**: Set a custom hostname for your Kali system
- **Branding**: Enable/disable Richey May branding
- **Output Formats**: Select additional output formats (ISO, VHD, AMI)

## 🛠️ For Developers

### Building from Source
1. Clone the repository
2. Install required Python packages:
   ```
   pip install -r requirements.txt
   ```
3. Run the launcher:
   ```
   python rta_builder_launcher.py
   ```

### Creating Distributable Package
1. Install PyInstaller:
   ```
   pip install pyinstaller
   ```
2. Run the distribution script:
   ```
   python distribution_setup.py
   ```
3. Find the executable in the `dist` folder

## 📊 Branding Information

- **Primary Color**: #002B49 (Midnight Blue)
- **Accent Color**: #6AA339 (Spring Green)
- **Text Color**: White
- **Font**: Arial, 12pt

## 🤝 Support

For issues, feature requests, or questions, please contact the Richey May Cyber team.

## 📜 License

This software is proprietary and confidential. Unauthorized copying, distribution, or use is strictly prohibited.

© 2023 Richey May & Co., LLC. All rights reserved.
