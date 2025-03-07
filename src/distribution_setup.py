"""
Setup script for creating an executable for the Richey May RTA Builder
This uses PyInstaller to create a standalone Windows executable
"""

import os
import sys
import subprocess
import shutil
import tempfile
from pathlib import Path

APP_NAME = "Richey May RTA Builder"
APP_VERSION = "1.0.0"

def check_pyinstaller():
    """Check if PyInstaller is installed and install it if needed"""
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "show", "pyinstaller"], 
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        print("PyInstaller is already installed.")
        return True
    except subprocess.CalledProcessError:
        print("PyInstaller not found. Installing...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])
            print("PyInstaller installed successfully.")
            return True
        except subprocess.CalledProcessError as e:
            print(f"Failed to install PyInstaller: {e}")
            return False

def create_icon():
    """Create a custom icon for the application"""
    # In a real implementation, this would embed a custom icon
    # For now, we'll create a placeholder icon
    
    icon_dir = "build"
    os.makedirs(icon_dir, exist_ok=True)
    
    try:
        # Check if Pillow is installed for image manipulation
        try:
            from PIL import Image, ImageDraw
            
            # Create a simple icon - a blue square with green R
            img = Image.new('RGBA', (256, 256), (0, 43, 73, 255))  # PRIMARY_COLOR
            draw = ImageDraw.Draw(img)
            
            # Draw a green R
            draw.rectangle((64, 64, 192, 192), fill=(106, 163, 57, 255))  # ACCENT_COLOR
            draw.text((100, 80), "R", fill=(255, 255, 255, 255), font_size=100)
            
            # Save as ICO
            icon_path = os.path.join(icon_dir, "rta_icon.ico")
            img.save(icon_path, format="ICO")
            
        except ImportError:
            # Pillow not installed, create a blank icon file
            icon_path = os.path.join(icon_dir, "rta_icon.ico")
            with open(icon_path, "wb") as f:
                # Write minimal ICO file header
                f.write(b"\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x04\x00\x28\x01\x00\x00\x16\x00\x00\x00")
                # Write minimal icon data
                f.write(b"\x28\x00\x00\x00\x10\x00\x00\x00\x20\x00\x00\x00\x01\x00\x04\x00\x00\x00\x00\x00\x80\x00\x00\x00")
                f.write(b"\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
                # Color table
                f.write(b"\x00\x00\x00\x00\x00\x2B\x49\x00\x6A\xA3\x39\x00\xFF\xFF\xFF\x00")
                # Pixel data
                for _ in range(128):
                    f.write(b"\x00")
        
        print(f"Icon created at {icon_path}")
        return icon_path
    
    except Exception as e:
        print(f"Failed to create icon: {e}")
        return None

def prepare_files():
    """Prepare files for packaging"""
    # Create build directory
    build_dir = "build"
    os.makedirs(build_dir, exist_ok=True)
    
    # Create a tools directory for bundled tools
    tools_dir = os.path.join(build_dir, "tools")
    os.makedirs(tools_dir, exist_ok=True)
    
    # Copy application files
    source_files = [
        "rta_builder_app.py",
        "iso_building_utils.py",
        "rta_builder_launcher.py"
    ]
    
    for file in source_files:
        if os.path.exists(file):
            shutil.copy2(file, build_dir)
            print(f"Copied {file} to build directory")
        else:
            print(f"Warning: Source file {file} not found")
    
    # Create version file
    with open(os.path.join(build_dir, "version.txt"), "w") as f:
        f.write(f"{APP_NAME} v{APP_VERSION}")
    
    # Create config files
    with open(os.path.join(build_dir, "tools_config.json"), "w") as f:
        f.write("""
        [
            {"name": "Nmap", "description": "Network scanner", "category": "Reconnaissance", "selected": true},
            {"name": "Metasploit", "description": "Penetration testing framework", "category": "Exploitation", "selected": true},
            {"name": "Wireshark", "description": "Network protocol analyzer", "category": "Packet Analysis", "selected": true},
            {"name": "Burp Suite", "description": "Web vulnerability scanner", "category": "Web Application", "selected": true},
            {"name": "John the Ripper", "description": "Password cracker", "category": "Password Attacks", "selected": false},
            {"name": "Hydra", "description": "Login cracker", "category": "Password Attacks", "selected": false},
            {"name": "Aircrack-ng", "description": "Wireless security tools", "category": "Wireless", "selected": false},
            {"name": "SQLmap", "description": "SQL injection tool", "category": "Web Application", "selected": false},
            {"name": "Responder", "description": "LLMNR/NBT-NS/mDNS poisoner", "category": "Network Attacks", "selected": false},
            {"name": "CrackMapExec", "description": "Post-exploitation tool", "category": "Post Exploitation", "selected": false}
        ]
        """)
    
    return build_dir

def create_executable(build_dir, icon_path):
    """Create an executable using PyInstaller"""
    try:
        # Create spec file for PyInstaller
        spec_content = f"""
# -*- mode: python ; coding: utf-8 -*-

block_cipher = None

a = Analysis(
    ['{os.path.join(build_dir, "rta_builder_launcher.py")}'],
    pathex=['{os.path.abspath(build_dir)}'],
    binaries=[],
    datas=[
        ('{os.path.join(build_dir, "tools_config.json")}', '.'),
        ('{os.path.join(build_dir, "version.txt")}', '.'),
        ('{os.path.join(build_dir, "tools")}', 'tools')
    ],
    hiddenimports=['win32api', 'win32con', 'win32file', 'winioctlcon'],
    hookspath=[],
    hooksconfig={{}},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='{APP_NAME}',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='{icon_path}' if '{icon_path}' else None,
    uac_admin=True,
)
"""
        
        spec_file = "RTA_Builder.spec"
        with open(spec_file, "w") as f:
            f.write(spec_content)
        
        print(f"Created PyInstaller spec file: {spec_file}")
        
        # Run PyInstaller
        print("Building executable with PyInstaller (this may take a few minutes)...")
        subprocess.check_call([sys.executable, "-m", "PyInstaller", spec_file, "--clean"])
        
        print(f"Executable created successfully in dist/{APP_NAME}.exe")
        return True
        
    except Exception as e:
        print(f"Failed to create executable: {e}")
        return False

def create_installer():
    """Create an installer using NSIS (if available)"""
    try:
        # Check if NSIS is installed
        nsis_path = None
        for path in [
            r"C:\Program Files\NSIS\makensis.exe",
            r"C:\Program Files (x86)\NSIS\makensis.exe"
        ]:
            if os.path.exists(path):
                nsis_path = path
                break
        
        if not nsis_path:
            print("NSIS not found. Skipping installer creation.")
            return False
        
        # Create NSIS script
        nsis_script = """
!define APP_NAME "Richey May RTA Builder"
!define APP_VERSION "1.0.0"
!define APP_PUBLISHER "Richey May"
!define MAIN_EXE_NAME "Richey May RTA Builder.exe"

Name "${APP_NAME}"
OutFile "RicheyMay_RTA_Builder_Setup.exe"
InstallDir "$PROGRAMFILES64\\${APP_NAME}"
InstallDirRegKey HKLM "Software\\${APP_NAME}" "Install_Dir"
RequestExecutionLevel admin

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "build\\rta_icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Install"
    SetOutPath $INSTDIR
    
    # Copy all files from dist folder
    File /r "dist\\${APP_NAME}\\*.*"
    
    # Create uninstaller
    WriteUninstaller "$INSTDIR\\Uninstall.exe"
    
    # Start Menu shortcuts
    CreateDirectory "$SMPROGRAMS\\${APP_NAME}"
    CreateShortcut "$SMPROGRAMS\\${APP_NAME}\\${APP_NAME}.lnk" "$INSTDIR\\${MAIN_EXE_NAME}"
    CreateShortcut "$SMPROGRAMS\\${APP_NAME}\\Uninstall.lnk" "$INSTDIR\\Uninstall.exe"
    
    # Desktop shortcut
    CreateShortcut "$DESKTOP\\${APP_NAME}.lnk" "$INSTDIR\\${MAIN_EXE_NAME}"
    
    # Registry information for Add/Remove Programs
    WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}" "DisplayName" "${APP_NAME}"
    WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}" "UninstallString" "$INSTDIR\\Uninstall.exe"
    WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}" "DisplayIcon" "$INSTDIR\\${MAIN_EXE_NAME},0"
    WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}" "Publisher" "${APP_PUBLISHER}"
    WriteRegStr HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}" "DisplayVersion" "${APP_VERSION}"
SectionEnd

Section "Uninstall"
    # Remove files and directories
    Delete "$INSTDIR\\*.*"
    RMDir /r "$INSTDIR"
    
    # Remove shortcuts
    Delete "$DESKTOP\\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\\${APP_NAME}\\*.*"
    RMDir "$SMPROGRAMS\\${APP_NAME}"
    
    # Remove registry keys
    DeleteRegKey HKLM "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${APP_NAME}"
    DeleteRegKey HKLM "Software\\${APP_NAME}"
SectionEnd
"""
        
        nsis_file = "installer.nsi"
        with open(nsis_file, "w") as f:
            f.write(nsis_script)
        
        print(f"Created NSIS script: {nsis_file}")
        
        # Run NSIS
        print("Building installer with NSIS (this may take a few minutes)...")
        subprocess.check_call([nsis_path, nsis_file])
        
        print("Installer created successfully: RicheyMay_RTA_Builder_Setup.exe")
        return True
        
    except Exception as e:
        print(f"Failed to create installer: {e}")
        return False

def main():
    """Main function for packaging the application"""
    print(f"Starting packaging process for {APP_NAME} v{APP_VERSION}")
    
    # Check for PyInstaller
    if not check_pyinstaller():
        print("PyInstaller is required to create the executable.")
        return
    
    # Create icon
    icon_path = create_icon()
    
    # Prepare files
    build_dir = prepare_files()
    
    # Create executable
    if create_executable(build_dir, icon_path):
        # Create installer
        create_installer()
    
    print("Packaging process completed.")

if __name__ == "__main__":
    main()
