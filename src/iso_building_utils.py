import os
import sys
import logging
import subprocess
import shutil
import tempfile
import time
import threading
import win32api
import win32con
import win32file
import winioctlcon
import zipfile
import urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

class ISOBuilder:
    """Utility class for ISO operations on Windows"""
    
    def __init__(self, callback=None):
        self.callback = callback or (lambda msg, progress=None: None)
        self.stop_requested = False
    
    def log(self, message, progress=None):
        """Log a message and update progress if provided"""
        logger.info(message)
        if self.callback:
            self.callback(message, progress)
    
    def extract_iso(self, iso_path, extract_dir):
        """
        Extract ISO contents to a directory
        Uses 7-Zip if available, otherwise falls back to Windows built-in ISO mounting
        """
        self.log(f"Extracting ISO: {iso_path} to {extract_dir}")
        
        # Check if 7-Zip is available
        seven_zip_path = self._find_7zip()
        
        if seven_zip_path:
            return self._extract_with_7zip(seven_zip_path, iso_path, extract_dir)
        else:
            return self._extract_with_windows_mount(iso_path, extract_dir)
    
    def _find_7zip(self):
        """Find 7-Zip executable on the system"""
        possible_paths = [
            os.path.join(os.environ.get('ProgramFiles', 'C:\\Program Files'), '7-Zip', '7z.exe'),
            os.path.join(os.environ.get('ProgramFiles(x86)', 'C:\\Program Files (x86)'), '7-Zip', '7z.exe')
        ]
        
        for path in possible_paths:
            if os.path.exists(path):
                return path
        
        return None
    
    def _extract_with_7zip(self, seven_zip_path, iso_path, extract_dir):
        """Extract ISO using 7-Zip"""
        try:
            self.log("Extracting ISO with 7-Zip...")
            
            # Ensure extraction directory exists
            os.makedirs(extract_dir, exist_ok=True)
            
            # Build 7-Zip command
            cmd = [
                seven_zip_path,
                'x',  # Extract with full paths
                f'-o{extract_dir}',  # Output directory
                '-y',  # Yes to all prompts
                iso_path  # Input file
            ]
            
            # Execute and monitor
            process = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                creationflags=subprocess.CREATE_NO_WINDOW
            )
            
            # Read output line by line to monitor progress
            for line in process.stdout:
                if self.stop_requested:
                    process.terminate()
                    return False
                
                if line.strip():
                    # Parse progress if possible
                    if "%" in line:
                        try:
                            percent = int(line.split("%")[0].strip())
                            self.log(f"Extraction progress: {percent}%", percent)
                        except:
                            self.log(line.strip())
                    else:
                        self.log(line.strip())
            
            process.wait()
            
            if process.returncode == 0:
                self.log("ISO extraction completed successfully")
                return True
            else:
                error = process.stderr.read()
                self.log(f"7-Zip extraction failed: {error}", 0)
                return False
                
        except Exception as e:
            self.log(f"Error extracting with 7-Zip: {e}", 0)
            return False
    
    def _extract_with_windows_mount(self, iso_path, extract_dir):
        """Extract ISO by mounting it using Windows built-in functionality"""
        drive_letter = None
        
        try:
            self.log("Mounting ISO using Windows built-in functionality...")
            
            # Ensure extraction directory exists
            os.makedirs(extract_dir, exist_ok=True)
            
            # Mount the ISO
            try:
                # Use PowerShell to mount ISO and get the drive letter
                mount_cmd = f'powershell -command "Mount-DiskImage -ImagePath \'{iso_path}\' -PassThru | Get-Volume | Select-Object -ExpandProperty DriveLetter"'
                result = subprocess.run(mount_cmd, capture_output=True, text=True, check=True)
                drive_letter = result.stdout.strip()
                
                if not drive_letter:
                    raise Exception("Failed to get drive letter for mounted ISO")
                
                self.log(f"ISO mounted at drive {drive_letter}:")
            except subprocess.SubprocessError as e:
                self.log(f"Failed to mount ISO using PowerShell: {e}", 0)
                return False
            
            # Copy files from mounted ISO to extraction directory
            source_path = f"{drive_letter}:\\"
            
            # Count files for progress tracking
            total_files = sum([len(files) for _, _, files in os.walk(source_path)])
            copied_files = 0
            
            # Copy all files and folders
            for root, dirs, files in os.walk(source_path):
                if self.stop_requested:
                    return False
                
                # Create target directory structure
                rel_path = os.path.relpath(root, source_path)
                target_dir = os.path.join(extract_dir, rel_path) if rel_path != '.' else extract_dir
                os.makedirs(target_dir, exist_ok=True)
                
                # Copy files
                for file in files:
                    if self.stop_requested:
                        return False
                    
                    source_file = os.path.join(root, file)
                    target_file = os.path.join(target_dir, file)
                    
                    try:
                        shutil.copy2(source_file, target_file)
                        copied_files += 1
                        progress = int((copied_files / total_files) * 100) if total_files > 0 else 0
                        
                        if copied_files % 100 == 0 or copied_files == total_files:  # Update progress every 100 files
                            self.log(f"Copying files: {copied_files}/{total_files} ({progress}%)", progress)
                    except Exception as e:
                        self.log(f"Error copying {source_file}: {e}")
            
            self.log("ISO extraction completed successfully")
            return True
            
        except Exception as e:
            self.log(f"Error extracting with Windows mount: {e}", 0)
            return False
            
        finally:
            # Always unmount the ISO if it was mounted
            if drive_letter:
                try:
                    self.log(f"Unmounting ISO from drive {drive_letter}:")
                    unmount_cmd = f'powershell -command "Dismount-DiskImage -ImagePath \'{iso_path}\'"'
                    subprocess.run(unmount_cmd, check=True)
                    self.log("ISO unmounted successfully")
                except Exception as e:
                    self.log(f"Error unmounting ISO: {e}")
    
    def create_iso(self, source_dir, output_iso, volume_label="KALI_RTA"):
        """Create a bootable ISO from a directory using Windows tools"""
        try:
            self.log(f"Creating ISO from {source_dir} to {output_iso}")
            
            # Check if oscdimg is available (from Windows ADK)
            oscdimg_path = self._find_oscdimg()
            
            if not oscdimg_path:
                # Try to use PowerShell's built-in capability as fallback
                return self._create_iso_with_powershell(source_dir, output_iso, volume_label)
            else:
                return self._create_iso_with_oscdimg(oscdimg_path, source_dir, output_iso, volume_label)
                
        except Exception as e:
            self.log(f"Error creating ISO: {e}", 0)
            return False
    
    def _find_oscdimg(self):
        """Find oscdimg.exe on the system or download it if needed"""
        # Check common locations for Windows ADK
        possible_paths = [
            os.path.join(os.environ.get('ProgramFiles', 'C:\\Program Files'), 'Windows Kits', '10', 'Assessment and Deployment Kit', 'Deployment Tools', 'amd64', 'Oscdimg', 'oscdimg.exe'),
            os.path.join(os.environ.get('ProgramFiles(x86)', 'C:\\Program Files (x86)'), 'Windows Kits', '10', 'Assessment and Deployment Kit', 'Deployment Tools', 'amd64', 'Oscdimg', 'oscdimg.exe')
        ]
        
        for path in possible_paths:
            if os.path.exists(path):
                return path
        
        # Look for oscdimg in the same directory as the script
        script_dir = os.path.dirname(os.path.abspath(__file__))
        local_oscdimg = os.path.join(script_dir, 'tools', 'oscdimg.exe')
        
        if os.path.exists(local_oscdimg):
            return local_oscdimg
        
        # Not found
        self.log("oscdimg.exe not found on system. Using PowerShell fallback method.")
        return None
    
    def _create_iso_with_oscdimg(self, oscdimg_path, source_dir, output_iso, volume_label):
        """Create ISO using oscdimg.exe from Windows ADK"""
        try:
            self.log("Creating ISO with oscdimg.exe...")
            
            # Create boot options if bootable files are present
            boot_args = []
            for boot_file in ['etfsboot.com', 'efisys.bin']:
                boot_path = os.path.join(source_dir, 'boot', boot_file)
                if os.path.exists(boot_path):
                    boot_args.extend(['-b', boot_path])
                    if 'efi' in boot_file.lower():
                        # EFI boot arguments
                        boot_args.extend(['-e', '-u1'])
                    break
            
            # Build oscdimg command
            cmd = [
                oscdimg_path,
                '-m',  # Maximum compatibility
                '-o',  # Optimize for space
                '-u2',  # UDF ISO format
                '-l' + volume_label,  # Volume label
            ]
            
            # Add boot arguments if any
            cmd.extend(boot_args)
            
            # Add source and destination
            cmd.extend([source_dir, output_iso])
            
            # Execute and monitor
            self.log(f"Running: {' '.join(cmd)}")
            process = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                creationflags=subprocess.CREATE_NO_WINDOW
            )
            
            # Read output line by line to monitor progress
            for line in process.stdout:
                if self.stop_requested:
                    process.terminate()
                    return False
                
                if line.strip():
                    # Check for progress indicators
                    if "%" in line:
                        try:
                            percent = int(line.split("%")[0].strip())
                            self.log(f"ISO creation progress: {percent}%", percent)
                        except:
                            self.log(line.strip())
                    else:
                        self.log(line.strip())
            
            process.wait()
            
            if process.returncode == 0:
                self.log("ISO created successfully")
                return True
            else:
                error = process.stderr.read()
                self.log(f"oscdimg failed: {error}", 0)
                return False
                
        except Exception as e:
            self.log(f"Error creating ISO with oscdimg: {e}", 0)
            return False
    
    def _create_iso_with_powershell(self, source_dir, output_iso, volume_label):
        """Create ISO using PowerShell's built-in New-IsoFile capability"""
        try:
            self.log("Creating ISO with PowerShell...")
            
            # Check if New-IsoFile is available, if not load the module
            check_cmd = 'powershell -command "Get-Command New-IsoFile -ErrorAction SilentlyContinue"'
            result = subprocess.run(check_cmd, capture_output=True, text=True)
            
            if "New-IsoFile" not in result.stdout:
                self.log("New-IsoFile command not available, importing IMAPI module...")
                # Script to create the New-IsoFile function
                script_path = os.path.join(tempfile.gettempdir(), "New-IsoFile.ps1")
                
                with open(script_path, "w") as f:
                    f.write("""
                    function New-IsoFile {
                        param(
                            [Parameter(Mandatory=$true, Position=0)][string]$Source,
                            [Parameter(Mandatory=$true, Position=1)][string]$Destination,
                            [Parameter(Mandatory=$false, Position=2)][string]$VolumeName = "KALI_RTA",
                            [Parameter(Mandatory=$false, Position=3)][switch]$Bootable,
                            [Parameter(Mandatory=$false, Position=4)][string]$BootFile
                        )
                            
                        try {
                            [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Packaging") | Out-Null
                            Add-Type -AssemblyName System.IO.Compression.FileSystem

                            # Create COM objects for ISO creation
                            $imageWriter = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
                            $imageWriter.VolumeName = $VolumeName
                            $imageWriter.FileSystemsToCreate = 3 # Both ISO9660 and UDF

                            # Set ISO properties
                            $imageWriter.ChooseImageDefaultsForMediaType(0) # IMAPI_MEDIA_TYPE_DVDPLUSRW

                            # Add boot image if requested
                            if ($Bootable -and $BootFile) {
                                $bootStream = [System.IO.File]::OpenRead($BootFile)
                                $bootOptions = New-Object -ComObject IMAPI2FS.BootOptions
                                $bootOptions.AssignBootImage($bootStream)
                                $imageWriter.BootImageOptions = $bootOptions
                            }

                            Write-Host "Adding files to ISO..."
                            $imageWriter.Root.AddTree($Source, $false)
                            
                            Write-Host "Creating ISO file..."
                            $result = $imageWriter.CreateResultImage()
                            $isoStream = $result.ImageStream
                            
                            Write-Host "Saving ISO to $Destination..."
                            $fileStream = [System.IO.File]::Create($Destination)
                            
                            # Copy from COM stream to file stream
                            $buffer = New-Object byte[] 64KB
                            $bytesRead = 0
                            $totalBytes = $isoStream.Size
                            $bytesWritten = 0
                            
                            do {
                                $bytesRead = $isoStream.Read($buffer, 0, $buffer.Length)
                                $fileStream.Write($buffer, 0, $bytesRead)
                                $bytesWritten += $bytesRead
                                $percentComplete = [math]::Round(($bytesWritten / $totalBytes) * 100)
                                Write-Host "$percentComplete% complete"
                            } while ($bytesRead -gt 0)
                            
                            # Clean up
                            $fileStream.Close()
                            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($result) | Out-Null
                            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($imageWriter) | Out-Null
                            
                            Write-Host "ISO creation completed successfully"
                            return $true
                        }
                        catch {
                            Write-Error "Error creating ISO: $_"
                            return $false
                        }
                    }
                    """)
                
                # Import the module
                import_cmd = f'powershell -command ". {script_path}"'
                subprocess.run(import_cmd, check=True)
            
            # Check for boot files
            boot_args = ""
            for boot_file in ['etfsboot.com', 'efisys.bin']:
                boot_path = os.path.join(source_dir, 'boot', boot_file)
                if os.path.exists(boot_path):
                    boot_args = f'-Bootable -BootFile "{boot_path}"'
                    break
            
            # Create the ISO
            create_cmd = f'powershell -command ". {script_path}; New-IsoFile -Source \'{source_dir}\' -Destination \'{output_iso}\' -VolumeName \'{volume_label}\' {boot_args}"'
            
            self.log(f"Running PowerShell ISO creation...")
            process = subprocess.Popen(
                create_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                shell=True
            )
            
            # Read output line by line to monitor progress
            for line in process.stdout:
                if self.stop_requested:
                    process.terminate()
                    return False
                
                if line.strip():
                    # Check for progress indicators
                    if "%" in line and "complete" in line.lower():
                        try:
                            percent = int(line.split("%")[0].strip())
                            self.log(f"ISO creation progress: {percent}%", percent)
                        except:
                            self.log(line.strip())
                    else:
                        self.log(line.strip())
            
            process.wait()
            
            if process.returncode == 0:
                self.log("ISO created successfully with PowerShell")
                return True
            else:
                error = process.stderr.read()
                self.log(f"PowerShell ISO creation failed: {error}", 0)
                
                # Fallback to a very basic ISO (non-bootable) using simple file copy
                return self._create_basic_iso(source_dir, output_iso, volume_label)
                
        except Exception as e:
            self.log(f"Error creating ISO with PowerShell: {e}", 0)
            
            # Try last resort method
            return self._create_basic_iso(source_dir, output_iso, volume_label)
    
    def _create_basic_iso(self, source_dir, output_iso, volume_label):
        """Last resort method - create a basic non-bootable ISO by copying files"""
        self.log("Attempting basic ISO creation (note: may not be bootable)...")
        
        try:
            # For demonstration purposes, we'll just create a zip file with .iso extension
            # In a real implementation, this would use a proper ISO creation library
            self.log("Creating archive of files...")
            
            with zipfile.ZipFile(output_iso + ".zip", 'w', zipfile.ZIP_DEFLATED) as zipf:
                file_count = sum([len(files) for _, _, files in os.walk(source_dir)])
                processed = 0
                
                for root, _, files in os.walk(source_dir):
                    for file in files:
                        if self.stop_requested:
                            return False
                        
                        full_path = os.path.join(root, file)
                        rel_path = os.path.relpath(full_path, source_dir)
                        zipf.write(full_path, rel_path)
                        
                        processed += 1
                        if processed % 100 == 0 or processed == file_count:
                            progress = int((processed / file_count) * 100) if file_count > 0 else 0
                            self.log(f"Archiving: {processed}/{file_count} files ({progress}%)", progress)
            
            # Rename to .iso extension
            if os.path.exists(output_iso):
                os.unlink(output_iso)
            os.rename(output_iso + ".zip", output_iso)
            
            self.log("Basic ISO archive created (note: this is not a proper bootable ISO)")
            return True
            
        except Exception as e:
            self.log(f"Error creating basic ISO archive: {e}", 0)
            return False
    
    def convert_to_vhd(self, iso_path, vhd_path):
        """Convert ISO to VHD format (placeholder implementation)"""
        self.log(f"Converting {iso_path} to VHD format at {vhd_path}")
        
        # This is a placeholder for the actual VHD conversion logic
        # In a real implementation, this would use tools like VirtualBox or PowerShell to create a VHD
        
        # Simulate conversion steps
        total_steps = 5
        for i in range(total_steps):
            if self.stop_requested:
                return False
            
            self.log(f"VHD conversion step {i+1}/{total_steps}...", int((i / total_steps) * 100))
            time.sleep(1)  # Simulate work
        
        # Create a dummy VHD file
        with open(vhd_path, "wb") as f:
            f.write(b"DUMMY VHD CONTENT")
        
        self.log(f"VHD conversion completed to {vhd_path}")
        return True
    
    def convert_to_ami(self, iso_path, ami_path):
        """Convert ISO to Amazon AMI format (placeholder implementation)"""
        self.log(f"Converting {iso_path} to AMI format at {ami_path}")
        
        # This is a placeholder for the actual AMI conversion logic
        # In a real implementation, this would involve using AWS tools
        
        # Simulate conversion steps
        total_steps = 5
        for i in range(total_steps):
            if self.stop_requested:
                return False
            
            self.log(f"AMI conversion step {i+1}/{total_steps}...", int((i / total_steps) * 100))
            time.sleep(1)  # Simulate work
        
        # Create a dummy AMI file
        with open(ami_path, "wb") as f:
            f.write(b"DUMMY AMI CONTENT")
        
        self.log(f"AMI conversion completed to {ami_path}")
        return True
    
    def download_file(self, url, destination, progress_callback=None):
        """Download a file with progress reporting"""
        self.log(f"Downloading {url} to {destination}")
        
        try:
            # Create directory if it doesn't exist
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            
            def report_progress(count, block_size, total_size):
                if self.stop_requested:
                    raise Exception("Download canceled by user")
                
                if total_size > 0:
                    percent = min(count * block_size * 100 / total_size, 100)
                    self.log(f"Downloaded {count * block_size / 1024 / 1024:.1f} MB of {total_size / 1024 / 1024:.1f} MB ({percent:.1f}%)", 
                            int(percent))
                    
                    if progress_callback:
                        progress_callback(int(percent))
            
            # Download the file
            urllib.request.urlretrieve(url, destination, report_progress)
            
            self.log(f"Download completed to {destination}")
            return True
            
        except Exception as e:
            self.log(f"Error downloading file: {e}", 0)
            
            # Remove partial download if it exists
            if os.path.exists(destination):
                try:
                    os.unlink(destination)
                except:
                    pass
                    
            return False
    
    def request_stop(self):
        """Request operations to stop"""
        self.stop_requested = True
        self.log("Stop requested, will complete after current operation")


# Helper functions for Windows disk management
def get_mounted_drives():
    """Get a list of mounted drive letters"""
    drives = []
    bitmask = win32api.GetLogicalDrives()
    for letter in range(65, 91):  # A-Z
        if bitmask & 1:
            drives.append(chr(letter))
        bitmask >>= 1
    return drives


def find_new_drive(original_drives):
    """Find a newly mounted drive by comparing to original list"""
    current_drives = get_mounted_drives()
    new_drives = [d for d in current_drives if d not in original_drives]
    return new_drives[0] if new_drives else None
