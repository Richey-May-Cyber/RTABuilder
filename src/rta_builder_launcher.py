import os
import sys
import subprocess
import logging
import tkinter as tk
from tkinter import messagebox
import ctypes
import time
import importlib.util
import urllib.request
import zipfile
import tempfile
from rta_builder_app import RTABuilderApp

# Application info
APP_NAME = "Richey May RTA Builder"
APP_VERSION = "1.0.0"
REQUIRED_PACKAGES = [
    "tkinter",
    "win32api",
    "win32con",
    "win32file",
    "winioctlcon",
    "pywin32"
]

def check_admin():
    """Check if the script is running with admin privileges"""
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except:
        return False

def install_package(package):
    """Install a Python package using pip"""
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", package])
        return True
    except subprocess.CalledProcessError:
        return False

def check_dependencies():
    """Check if all required packages are installed"""
    missing_packages = []
    
    for package in REQUIRED_PACKAGES:
        try:
            if package == "tkinter":
                importlib.import_module(package)
            else:
                spec = importlib.util.find_spec(package)
                if spec is None:
                    missing_packages.append(package)
        except ImportError:
            missing_packages.append(package)
    
    return missing_packages

def setup_environment():
    """Set up the application environment"""
    # Create application directory in user's home folder
    app_dir = os.path.join(os.path.expanduser("~"), "RTA_Builder")
    os.makedirs(app_dir, exist_ok=True)
    
    # Create subdirectories
    os.makedirs(os.path.join(app_dir, "downloads"), exist_ok=True)
    os.makedirs(os.path.join(app_dir, "tools"), exist_ok=True)
    os.makedirs(os.path.join(app_dir, "logs"), exist_ok=True)
    
    return app_dir

def download_tools():
    """Download necessary tools if they don't exist"""
    app_dir = os.path.join(os.path.expanduser("~"), "RTA_Builder")
    tools_dir = os.path.join(app_dir, "tools")
    
    # Check for oscdimg.exe
    oscdimg_path = os.path.join(tools_dir, "oscdimg.exe")
    if not os.path.exists(oscdimg_path):
        try:
            # In a real implementation, this would download from a legitimate source
            # For this demo, we create a placeholder file
            with open(oscdimg_path, "wb") as f:
                f.write(b"PLACEHOLDER FOR OSCDIMG.EXE")
        except Exception as e:
            print(f"Error setting up tools: {e}")

def main():
    """Main entry point for the application"""
    # Check for admin privileges
    if not check_admin():
        if sys.platform.startswith('win'):
            # Re-run the script with admin privileges
            ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, " ".join(sys.argv), None, 1)
            return
        else:
            print("This application requires administrator privileges to modify ISO files.")
            return
    
    # Check dependencies
    missing_packages = check_dependencies()
    if missing_packages:
        print(f"Missing required packages: {', '.join(missing_packages)}")
        print("Installing missing packages...")
        
        for package in missing_packages:
            print(f"Installing {package}...")
            if not install_package(package):
                print(f"Failed to install {package}. Please install it manually.")
                input("Press Enter to exit...")
                return
        
        print("All dependencies installed. Restarting application...")
        # Restart the application to ensure modules are properly loaded
        os.execv(sys.executable, ['python'] + sys.argv)
        return
    
    # Set up environment
    app_dir = setup_environment()
    
    # Download necessary tools
    download_tools()
    
    # Configure logging
    log_file = os.path.join(app_dir, "logs", "rta_builder.log")
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(log_file),
            logging.StreamHandler(sys.stdout)
        ]
    )
    
    # Start the main application
    try:
        # Fix for high DPI displays
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except:
            pass
        
        # Import the main application module
        from rta_builder_app import RTABuilderApp
        
        root = tk.Tk()
        app = RTABuilderApp(root)
        root.mainloop()
        
    except Exception as e:
        print(f"Error starting application: {e}")
        input("Press Enter to exit...")

if __name__ == "__main__":
    main()
