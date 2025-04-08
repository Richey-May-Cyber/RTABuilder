#!/bin/bash

# Custom TeamViewer Host Installation Script

# Exit on any error
set -e

echo "Starting TeamViewer Host custom installation..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# Configuration Variables
TV_PACKAGE="teamviewer-host_amd64.deb"
ASSIGNMENT_TOKEN="25998227-v1SCqDinbXPh3pHnBv7s"  # Get this from your TeamViewer Management Console
GROUP_ID="g12345"  # Replace with your actual group ID
ALIAS_PREFIX="$(hostname)-"  # Device names will be hostname + timestamp

# Install dependencies
echo "Installing dependencies..."
apt-get update
apt-get install -y wget apt-transport-https gnupg2

# Download TeamViewer package if not already present
if [ ! -f "$TV_PACKAGE" ]; then
  echo "Downloading TeamViewer Host package..."
  wget https://download.teamviewer.com/download/linux/teamviewer-host_amd64.deb
fi

# Install TeamViewer
echo "Installing TeamViewer Host..."
apt-get install -y ./$TV_PACKAGE

# Wait for TeamViewer service to start
echo "Waiting for TeamViewer service to initialize..."
sleep 10

# Assign to your TeamViewer account using the assignment token
echo "Assigning device to your TeamViewer account..."
teamviewer --daemon start
teamviewer assignment --token $ASSIGNMENT_TOKEN

# Set a custom alias for this device
TIMESTAMP=$(date +%Y%m%d%H%M%S)
DEVICE_ALIAS="${ALIAS_PREFIX}${TIMESTAMP}"
echo "Setting device alias to: $DEVICE_ALIAS"
teamviewer alias $DEVICE_ALIAS

# Assign to specific group (if specified)
if [ ! -z "$GROUP_ID" ]; then
  echo "Assigning to group: $GROUP_ID"
  teamviewer assignment --group-id $GROUP_ID
fi

# Configure TeamViewer for unattended access (no password needed)
echo "Configuring for unattended access..."
teamviewer setup --grant-easy-access

# Disable commercial usage notification (available in corporate license)
echo "Disabling commercial usage notification..."
teamviewer config set General\CUNotification 0

# Restart TeamViewer to apply all settings
echo "Restarting TeamViewer service..."
teamviewer --daemon restart

echo "TeamViewer Host installation and configuration completed successfully!"
echo "This device is now accessible through your TeamViewer business account."

# Display the TeamViewer ID for reference
TV_ID=$(teamviewer info | grep "TeamViewer ID:" | awk '{print $3}')
echo "TeamViewer ID: $TV_ID"
