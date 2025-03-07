import os
import sys
import logging
import threading
import subprocess
import shutil
import urllib.request
import tempfile
import tkinter as tk
from tkinter import ttk, filedialog, scrolledtext
from tkinter import messagebox
import ctypes
from pathlib import Path
import json
import re
from datetime import datetime

# Constants
APP_NAME = "Richey May RTA Builder"
APP_VERSION = "1.0.0"
PRIMARY_COLOR = "#002B49"  # Midnight Blue
ACCENT_COLOR = "#6AA339"   # Spring Green
TEXT_COLOR = "white"
FONT = ("Arial", 12)
DEFAULT_KALI_ISO_URL = "https://cdimage.kali.org/kali-2023.1/kali-linux-2023.1-installer-amd64.iso"
LOG_FILE = "rta_builder.log"

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

class ScrollableFrame(ttk.Frame):
    """A scrollable frame widget"""
    def __init__(self, container, *args, **kwargs):
        super().__init__(container, *args, **kwargs)
        canvas = tk.Canvas(self)
        scrollbar = ttk.Scrollbar(self, orient="vertical", command=canvas.yview)
        self.scrollable_frame = ttk.Frame(canvas)

        self.scrollable_frame.bind(
            "<Configure>",
            lambda e: canvas.configure(
                scrollregion=canvas.bbox("all")
            )
        )

        canvas.create_window((0, 0), window=self.scrollable_frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)

        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

class RTABuilderApp:
    def __init__(self, root):
        self.root = root
        self.root.title(f"{APP_NAME} v{APP_VERSION}")
        self.root.geometry("900x700")
        self.root.minsize(800, 600)
        
        # Set window icon (if available)
        try:
            self.root.iconbitmap("icon.ico")
        except:
            pass
            
        # Apply dark theme
        self.style = ttk.Style()
        self.style.theme_use('clam')
        self.style.configure('TFrame', background=PRIMARY_COLOR)
        self.style.configure('TLabel', background=PRIMARY_COLOR, foreground=TEXT_COLOR, font=FONT)
        self.style.configure('TButton', background=ACCENT_COLOR, foreground=TEXT_COLOR, font=FONT)
        self.style.map('TButton', background=[('active', ACCENT_COLOR)])
        self.style.configure('TCheckbutton', background=PRIMARY_COLOR, foreground=TEXT_COLOR, font=FONT)
        self.style.map('TCheckbutton', background=[('active', PRIMARY_COLOR)])
        
        # Configure root window
        self.root.configure(bg=PRIMARY_COLOR)
        
        # Variables
        self.output_folder = tk.StringVar(value=os.path.join(os.path.expanduser("~"), "RTA_Builder_Output"))
        self.iso_path = tk.StringVar(value="")
        self.tools_folder = tk.StringVar(value="")
        self.tool_checkboxes = {}
        self.tool_vars = {}
        self.build_thread = None
        self.stop_build = False

        # Create UI
        self.create_ui()
        
        # Initialize
        self.load_tools_config()
        
        logger.info(f"{APP_NAME} v{APP_VERSION} started")

    def create_ui(self):
        """Create the main user interface"""
        main_frame = ttk.Frame(self.root, padding=10)
        main_frame.pack(fill=tk.BOTH, expand=True)
        
        # Header with logo (placeholder for now)
        header_frame = ttk.Frame(main_frame)
        header_frame.pack(fill=tk.X, pady=(0, 10))
        
        # Title
        title_label = ttk.Label(header_frame, text=APP_NAME, font=("Arial", 18, "bold"))
        title_label.pack(side=tk.LEFT, padx=5)
        
        # Version
        version_label = ttk.Label(header_frame, text=f"v{APP_VERSION}", font=("Arial", 10))
        version_label.pack(side=tk.LEFT, padx=5, pady=8)
        
        # Settings frame
        settings_frame = ttk.LabelFrame(main_frame, text="Configuration", padding=10)
        settings_frame.pack(fill=tk.X, pady=5)
        
        # ISO Selection
        iso_frame = ttk.Frame(settings_frame)
        iso_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(iso_frame, text="Kali ISO:").pack(side=tk.LEFT, padx=5)
        ttk.Entry(iso_frame, textvariable=self.iso_path, width=50).pack(side=tk.LEFT, padx=5, fill=tk.X, expand=True)
        ttk.Button(iso_frame, text="Browse", command=self.browse_iso).pack(side=tk.LEFT, padx=5)
        ttk.Button(iso_frame, text="Download", command=self.download_iso).pack(side=tk.LEFT, padx=5)
        
        # Tools folder
        tools_frame = ttk.Frame(settings_frame)
        tools_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(tools_frame, text="Tools Folder:").pack(side=tk.LEFT, padx=5)
        ttk.Entry(tools_frame, textvariable=self.tools_folder, width=50).pack(side=tk.LEFT, padx=5, fill=tk.X, expand=True)
        ttk.Button(tools_frame, text="Browse", command=self.browse_tools_folder).pack(side=tk.LEFT, padx=5)
        
        # Output folder
        output_frame = ttk.Frame(settings_frame)
        output_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(output_frame, text="Output Folder:").pack(side=tk.LEFT, padx=5)
        ttk.Entry(output_frame, textvariable=self.output_folder, width=50).pack(side=tk.LEFT, padx=5, fill=tk.X, expand=True)
        ttk.Button(output_frame, text="Browse", command=self.browse_output).pack(side=tk.LEFT, padx=5)
        
        # Notebook for tabs
        self.notebook = ttk.Notebook(main_frame)
        self.notebook.pack(fill=tk.BOTH, expand=True, pady=10)
        
        # Tools tab (for tool selection)
        tools_tab = ttk.Frame(self.notebook)
        self.notebook.add(tools_tab, text="Tools Selection")
        
        # Create scrollable frame for tools
        self.tools_frame = ScrollableFrame(tools_tab)
        self.tools_frame.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)
        
        # Tool selection header
        tools_header = ttk.Frame(self.tools_frame.scrollable_frame)
        tools_header.pack(fill=tk.X, pady=5)
        
        ttk.Label(tools_header, text="Select tools to include:", font=("Arial", 12, "bold")).pack(side=tk.LEFT)
        select_all_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(tools_header, text="Select All", variable=select_all_var, 
                        command=lambda: self.toggle_all_tools(select_all_var.get())).pack(side=tk.RIGHT)
        
        # Advanced tab (for future options)
        advanced_tab = ttk.Frame(self.notebook)
        self.notebook.add(advanced_tab, text="Advanced Options")
        
        advanced_frame = ttk.LabelFrame(advanced_tab, text="Image Options", padding=10)
        advanced_frame.pack(fill=tk.X, padx=10, pady=10)
        
        # Hostname setting
        hostname_frame = ttk.Frame(advanced_frame)
        hostname_frame.pack(fill=tk.X, pady=5)
        
        ttk.Label(hostname_frame, text="Hostname:").pack(side=tk.LEFT, padx=5)
        self.hostname_var = tk.StringVar(value="kali-rta")
        ttk.Entry(hostname_frame, textvariable=self.hostname_var, width=20).pack(side=tk.LEFT, padx=5)
        
        # Branding option
        self.enable_branding = tk.BooleanVar(value=True)
        ttk.Checkbutton(advanced_frame, text="Enable Richey May branding", 
                        variable=self.enable_branding).pack(anchor=tk.W, pady=5)
        
        # Output formats
        formats_frame = ttk.LabelFrame(advanced_tab, text="Output Formats", padding=10)
        formats_frame.pack(fill=tk.X, padx=10, pady=10)
        
        self.iso_format = tk.BooleanVar(value=True)
        ttk.Checkbutton(formats_frame, text="ISO Image (Bootable)", 
                        variable=self.iso_format).pack(anchor=tk.W, pady=2)
        
        self.vhd_format = tk.BooleanVar(value=False)
        ttk.Checkbutton(formats_frame, text="VHD (Hyper-V)", 
                        variable=self.vhd_format).pack(anchor=tk.W, pady=2)
        
        self.ami_format = tk.BooleanVar(value=False)
        ttk.Checkbutton(formats_frame, text="AMI (AWS)", 
                        variable=self.ami_format).pack(anchor=tk.W, pady=2)
        
        # Log output area
        log_frame = ttk.LabelFrame(main_frame, text="Build Log", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True, pady=5)
        
        self.log_text = scrolledtext.ScrolledText(log_frame, height=10, font=("Consolas", 10))
        self.log_text.pack(fill=tk.BOTH, expand=True)
        self.log_text.config(state=tk.DISABLED)
        
        # Add log handler to display in GUI
        self.log_handler = LogTextHandler(self.log_text)
        self.log_handler.setLevel(logging.INFO)
        formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        self.log_handler.setFormatter(formatter)
        logger.addHandler(self.log_handler)
        
        # Progress bar
        self.progress_var = tk.DoubleVar(value=0.0)
        self.progress_bar = ttk.Progressbar(main_frame, variable=self.progress_var, mode='determinate')
        self.progress_bar.pack(fill=tk.X, pady=5)
        
        # Buttons frame
        buttons_frame = ttk.Frame(main_frame)
        buttons_frame.pack(fill=tk.X, pady=10)
        
        # Create style for accent button
        self.style.configure('Accent.TButton', background=ACCENT_COLOR, foreground=TEXT_COLOR, font=("Arial", 12, "bold"))
        self.style.map('Accent.TButton', background=[('active', ACCENT_COLOR)])
        
        self.build_button = ttk.Button(buttons_frame, text="Build Custom ISO", style='Accent.TButton', 
                                      command=self.start_build)
        self.build_button.pack(side=tk.RIGHT, padx=5)
        
        self.stop_button = ttk.Button(buttons_frame, text="Stop", command=self.stop_build_process)
        self.stop_button.pack(side=tk.RIGHT, padx=5)
        self.stop_button.config(state=tk.DISABLED)

    def load_tools_config(self):
        """Load the list of available tools from config or create default"""
        tools_config_file = "tools_config.json"
        
        # Default tools if no config found
        default_tools = [
            {"name": "Nmap", "description": "Network scanner", "category": "Reconnaissance", "selected": True},
            {"name": "Metasploit", "description": "Penetration testing framework", "category": "Exploitation", "selected": True},
            {"name": "Wireshark", "description": "Network protocol analyzer", "category": "Packet Analysis", "selected": True},
            {"name": "Burp Suite", "description": "Web vulnerability scanner", "category": "Web Application", "selected": True},
            {"name": "John the Ripper", "description": "Password cracker", "category": "Password Attacks", "selected": False},
            {"name": "Hydra", "description": "Login cracker", "category": "Password Attacks", "selected": False},
            {"name": "Aircrack-ng", "description": "Wireless security tools", "category": "Wireless", "selected": False},
            {"name": "SQLmap", "description": "SQL injection tool", "category": "Web Application", "selected": False},
            {"name": "Responder", "description": "LLMNR/NBT-NS/mDNS poisoner", "category": "Network Attacks", "selected": False},
            {"name": "CrackMapExec", "description": "Post-exploitation tool", "category": "Post Exploitation", "selected": False}
        ]
        
        try:
            if os.path.exists(tools_config_file):
                with open(tools_config_file, 'r') as f:
                    tools = json.load(f)
            else:
                tools = default_tools
                with open(tools_config_file, 'w') as f:
                    json.dump(tools, f, indent=4)
        except Exception as e:
            logger.error(f"Error loading tools configuration: {e}")
            tools = default_tools
            
        # Group tools by category
        categories = {}
        for tool in tools:
            category = tool.get("category", "Uncategorized")
            if category not in categories:
                categories[category] = []
            categories[category].append(tool)
            
        # Create checkboxes for tools
        for category, category_tools in categories.items():
            # Category frame
            category_frame = ttk.LabelFrame(self.tools_frame.scrollable_frame, text=category, padding=5)
            category_frame.pack(fill=tk.X, pady=5, padx=5, anchor=tk.W)
            
            # Tool checkboxes
            for tool in category_tools:
                tool_var = tk.BooleanVar(value=tool.get("selected", False))
                self.tool_vars[tool["name"]] = tool_var
                
                tool_frame = ttk.Frame(category_frame)
                tool_frame.pack(fill=tk.X, pady=2)
                
                checkbox = ttk.Checkbutton(tool_frame, text=tool["name"], variable=tool_var)
                checkbox.pack(side=tk.LEFT)
                self.tool_checkboxes[tool["name"]] = checkbox
                
                description = ttk.Label(tool_frame, text=f"- {tool['description']}", font=("Arial", 10, "italic"))
                description.pack(side=tk.LEFT, padx=10)

    def toggle_all_tools(self, select_all):
        """Select or deselect all tools"""
        for var in self.tool_vars.values():
            var.set(select_all)

    def browse_iso(self):
        """Browse for Kali ISO file"""
        iso_path = filedialog.askopenfilename(
            title="Select Kali ISO file",
            filetypes=[("ISO files", "*.iso"), ("All files", "*.*")]
        )
        if iso_path:
            self.iso_path.set(iso_path)
            logger.info(f"Selected ISO: {iso_path}")
    
    def browse_tools_folder(self):
        """Browse for tools folder"""
        tools_folder = filedialog.askdirectory(
            title="Select Tools Folder"
        )
        if tools_folder:
            self.tools_folder.set(tools_folder)
            logger.info(f"Selected Tools Folder: {tools_folder}")
    
    def browse_output(self):
        """Browse for output folder"""
        output_folder = filedialog.askdirectory(
            title="Select Output Folder"
        )
        if output_folder:
            self.output_folder.set(output_folder)
            logger.info(f"Selected Output Folder: {output_folder}")
    
    def download_iso(self):
        """Download the latest Kali ISO"""
        # This would be expanded in a real implementation
        if not messagebox.askyesno("Download ISO", 
                                 f"This will download the latest Kali Linux ISO (approx. 4GB). Continue?"):
            return
        
        # Start download in a separate thread
        threading.Thread(target=self._download_iso_thread, daemon=True).start()
    
    def _download_iso_thread(self):
        """Thread for downloading the ISO"""
        try:
            download_dir = os.path.join(self.output_folder.get(), "downloads")
            os.makedirs(download_dir, exist_ok=True)
            
            iso_filename = os.path.basename(DEFAULT_KALI_ISO_URL)
            target_file = os.path.join(download_dir, iso_filename)
            
            # Check if file already exists
            if os.path.exists(target_file):
                self.root.after(0, lambda: messagebox.showinfo("Download", 
                                                           f"ISO file already exists at {target_file}"))
                self.iso_path.set(target_file)
                return
            
            # Update UI
            self.update_progress(0.0)
            self.log("Starting ISO download...")
            
            # Set up progress reporting
            def progress_hook(count, block_size, total_size):
                if total_size > 0:
                    percent = min(count * block_size * 100 / total_size, 100)
                    self.update_progress(percent)
                    if count % 100 == 0:  # Don't log too frequently
                        self.log(f"Downloaded {count * block_size / 1024 / 1024:.1f} MB of {total_size / 1024 / 1024:.1f} MB ({percent:.1f}%)")
            
            # Download file
            urllib.request.urlretrieve(DEFAULT_KALI_ISO_URL, target_file, progress_hook)
            
            # Update UI
            self.update_progress(100.0)
            self.log(f"ISO downloaded successfully to {target_file}")
            self.iso_path.set(target_file)
            
            self.root.after(0, lambda: messagebox.showinfo("Download Complete", 
                                                       f"Kali ISO downloaded successfully to {target_file}"))
        except Exception as e:
            logger.error(f"ISO download failed: {e}")
            self.root.after(0, lambda: messagebox.showerror("Download Failed", 
                                                       f"Failed to download ISO: {e}"))
            self.update_progress(0.0)
    
    def update_progress(self, value):
        """Update the progress bar"""
        self.progress_var.set(value)
    
    def log(self, message, level=logging.INFO):
        """Add message to the log"""
        if level == logging.INFO:
            logger.info(message)
        elif level == logging.ERROR:
            logger.error(message)
        elif level == logging.WARNING:
            logger.warning(message)
    
    def start_build(self):
        """Start the build process"""
        # Validate inputs
        if not self.validate_inputs():
            return
        
        # Disable build button and enable stop button
        self.build_button.config(state=tk.DISABLED)
        self.stop_button.config(state=tk.NORMAL)
        self.stop_build = False
        
        # Start build in a separate thread
        self.build_thread = threading.Thread(target=self._build_thread)
        self.build_thread.daemon = True
        self.build_thread.start()
    
    def stop_build_process(self):
        """Stop the current build process"""
        if self.build_thread and self.build_thread.is_alive():
            self.stop_build = True
            self.log("Build process will stop after current operation completes...", logging.WARNING)
    
    def validate_inputs(self):
        """Validate user inputs before starting build"""
        # Check if ISO exists
        if not self.iso_path.get() or not os.path.exists(self.iso_path.get()):
            messagebox.showerror("Error", "Please select a valid Kali ISO file")
            return False
        
        # Check if output folder exists or can be created
        try:
            os.makedirs(self.output_folder.get(), exist_ok=True)
        except:
            messagebox.showerror("Error", "Cannot create output folder")
            return False
        
        # Check if any tools are selected
        if not any(var.get() for var in self.tool_vars.values()):
            if not messagebox.askyesno("No Tools Selected", 
                                     "No tools are selected. Do you want to continue anyway?"):
                return False
        
        return True
    
    def _build_thread(self):
        """Thread for building the custom ISO"""
        try:
            self.log("Starting build process...")
            self.update_progress(0)
            
            # Create timestamps for unique naming
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_name = f"kali-rta-custom_{timestamp}"
            workspace = os.path.join(self.output_folder.get(), f"build_{timestamp}")
            
            # Create workspace
            os.makedirs(workspace, exist_ok=True)
            self.log(f"Created workspace at {workspace}")
            
            # Steps and their weights for progress calculation
            steps = {
                "extract_iso": 20,
                "copy_tools": 10,
                "customize": 10,
                "rebuild_iso": 50,
                "cleanup": 10
            }
            completed_weight = 0
            
            # 1. Extract ISO
            extract_dir = os.path.join(workspace, "iso_contents")
            os.makedirs(extract_dir, exist_ok=True)
            
            self.log("Extracting ISO contents...")
            if not self._extract_iso(self.iso_path.get(), extract_dir):
                raise Exception("Failed to extract ISO")
            
            if self.stop_build:
                raise Exception("Build process stopped by user")
            
            completed_weight += steps["extract_iso"]
            self.update_progress(completed_weight)
            
            # 2. Copy selected tools
            tools_dir = os.path.join(extract_dir, "tools")
            os.makedirs(tools_dir, exist_ok=True)
            
            self.log("Copying selected tools...")
            selected_tools = [name for name, var in self.tool_vars.items() if var.get()]
            
            for tool in selected_tools:
                self.log(f"Adding tool: {tool}")
                # In a real implementation, this would copy from the tools folder
                # For now, we'll just create placeholder files
                tool_dir = os.path.join(tools_dir, tool.lower().replace(" ", "_"))
                os.makedirs(tool_dir, exist_ok=True)
                
                with open(os.path.join(tool_dir, "info.txt"), "w") as f:
                    f.write(f"Placeholder for {tool}\nThis would be the actual tool in a real implementation.")
            
            if self.stop_build:
                raise Exception("Build process stopped by user")
            
            completed_weight += steps["copy_tools"]
            self.update_progress(completed_weight)
            
            # 3. Customize ISO (hostname, branding, etc.)
            self.log("Customizing ISO settings...")
            
            # Set hostname
            hostname_file = os.path.join(extract_dir, "etc", "hostname")
            os.makedirs(os.path.dirname(hostname_file), exist_ok=True)
            with open(hostname_file, "w") as f:
                f.write(self.hostname_var.get())
            
            # Add branding if enabled
            if self.enable_branding.get():
                self.log("Adding Richey May branding...")
                # In a real implementation, this would add custom splash screens, etc.
            
            if self.stop_build:
                raise Exception("Build process stopped by user")
            
            completed_weight += steps["customize"]
            self.update_progress(completed_weight)
            
            # 4. Rebuild ISO
            output_iso = os.path.join(self.output_folder.get(), f"{output_name}.iso")
            
            self.log(f"Rebuilding ISO as {output_iso}...")
            if not self._rebuild_iso(extract_dir, output_iso):
                raise Exception("Failed to rebuild ISO")
            
            completed_weight += steps["rebuild_iso"]
            self.update_progress(completed_weight)
            
            # 5. Create additional formats if requested
            if self.vhd_format.get():
                self.log("Creating VHD format (not implemented in this version)")
                # This would be implemented in a full version
            
            if self.ami_format.get():
                self.log("Creating AMI format (not implemented in this version)")
                # This would be implemented in a full version
            
            # 6. Cleanup
            self.log("Cleaning up temporary files...")
            # In a real implementation, we might delete the workspace
            # shutil.rmtree(workspace)
            
            completed_weight += steps["cleanup"]
            self.update_progress(100)
            
            self.log(f"Build completed successfully! Output saved to {output_iso}")
            self.root.after(0, lambda: messagebox.showinfo("Build Complete", 
                                                       f"Custom Kali ISO created successfully at:\n{output_iso}"))
            
        except Exception as e:
            logger.error(f"Build failed: {e}")
            self.root.after(0, lambda: messagebox.showerror("Build Failed", 
                                                       f"Failed to build custom ISO: {e}"))
        finally:
            # Re-enable build button and disable stop button
            self.root.after(0, lambda: self.build_button.config(state=tk.NORMAL))
            self.root.after(0, lambda: self.stop_button.config(state=tk.DISABLED))
    
    def _extract_iso(self, iso_path, extract_dir):
        """Extract ISO contents (placeholder implementation)"""
        # In a real implementation, this would use tools like 7-Zip or similar
        # For now, we'll simulate the extraction process
        
        self.log("Mounting ISO image...")
        # Simulate extraction steps for demo purposes
        for i in range(5):
            if self.stop_build:
                return False
            self.log(f"Extracting files (step {i+1}/5)...")
            time.sleep(0.5)
        
        # Create some basic structure for demo
        os.makedirs(os.path.join(extract_dir, "live"), exist_ok=True)
        os.makedirs(os.path.join(extract_dir, "boot"), exist_ok=True)
        os.makedirs(os.path.join(extract_dir, "EFI"), exist_ok=True)
        
        return True
    
    def _rebuild_iso(self, source_dir, output_iso):
        """Rebuild ISO from modified contents (placeholder implementation)"""
        # In a real implementation, this would use oscdimg.exe or similar
        # For now, we'll simulate the rebuilding process
        
        self.log("Preparing to rebuild ISO...")
        
        # Simulate rebuild steps
        total_steps = 10
        for i in range(total_steps):
            if self.stop_build:
                return False
            self.log(f"Rebuilding ISO (step {i+1}/{total_steps})...")
            self.update_progress(50 + (i * 5))  # Update progress within the rebuild step
            time.sleep(0.5)
        
        # Create dummy ISO file
        with open(output_iso, "wb") as f:
            f.write(b"DUMMY ISO CONTENT")
        
        return True

class LogTextHandler(logging.Handler):
    """Handler for redirecting logging to the ScrolledText widget"""
    def __init__(self, text_widget):
        logging.Handler.__init__(self)
        self.text_widget = text_widget
        
    def emit(self, record):
        msg = self.format(record)
        self.text_widget.config(state=tk.NORMAL)
        
        # Add color based on log level
        if record.levelno >= logging.ERROR:
            self.text_widget.tag_config("error", foreground="red")
            self.text_widget.insert(tk.END, msg + "\n", "error")
        elif record.levelno >= logging.WARNING:
            self.text_widget.tag_config("warning", foreground="orange")
            self.text_widget.insert(tk.END, msg + "\n", "warning")
        else:
            self.text_widget.insert(tk.END, msg + "\n")
            
        self.text_widget.see(tk.END)
        self.text_widget.config(state=tk.DISABLED)
        
        # Process events to update display immediately
        self.text_widget.update_idletasks()

if __name__ == "__main__":
    # Fix for DPI scaling issues on Windows
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except:
        pass
    
    # Create and start the application
    root = tk.Tk()
    app = RTABuilderApp(root)
    root.mainloop()
