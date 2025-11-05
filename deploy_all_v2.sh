#!/bin/bash
#
# StratoCentral Ground Station - Complete Deployment Script
#
# This script automates the complete setup of a StratoCentral ground station.
# It installs all files, creates directories, sets up services, and configures
# the system for automatic operation.
#
# Usage: sudo ./deploy_all.sh
#
# Prerequisites:
# - Raspberry Pi OS with Python 3.9+
# - All ground-node-sender files uploaded to ~/stratonode/sender/
# - Serial port configured (/dev/ttyAMA0)
# - Network connectivity
#

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
ACTUAL_USER="${SUDO_USER:-strato}"
USER_HOME=$(eval echo ~$ACTUAL_USER)
SENDER_DIR="$USER_HOME/stratonode/sender"
VENV_DIR="$USER_HOME/stratonode/venv"
DATA_DIR="/data"
GNSS_LOG_DIR="$DATA_DIR/gnss"
STRATO_LOG_DIR="$DATA_DIR/stratocentral/logs"

# Version info
SCRIPT_VERSION="1.0.0"
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}║         ${GREEN}StratoCentral Ground Station Deployment${CYAN}         ║${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}║  Automated setup for GNSS monitoring and data collection  ║${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BLUE}Version:${NC} $SCRIPT_VERSION"
echo -e "${BLUE}Date:${NC} $DEPLOY_DATE"
echo -e "${BLUE}User:${NC} $ACTUAL_USER"
echo -e "${BLUE}Home:${NC} $USER_HOME"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run with sudo${NC}"
    echo "Usage: sudo ./deploy_all.sh"
    exit 1
fi

# Confirm deployment
echo -e "${YELLOW}This script will:${NC}"
echo "  • Install system packages"
echo "  • Set up Tailscale VPN (optional)"
echo "  • Create Python virtual environment"
echo "  • Install Python dependencies"
echo "  • Setup NVMe storage drive (if available)"
echo "  • Create data directories on NVMe"
echo "  • Configure file permissions"
echo "  • Install systemd services"
echo "  • Set up UBX health monitoring"
echo "  • Enable auto-start on boot"
echo
read -p "Continue with deployment? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo

# =============================================================================
# STEP 1: System Package Installation
# =============================================================================
echo -e "${MAGENTA}[1/14] Installing system packages...${NC}"

# Update package list
echo "  Updating package lists..."
apt-get update -qq

# Install required packages
PACKAGES=(
    "python3"
    "python3-venv"
    "python3-pip"
    "git"
)

for package in "${PACKAGES[@]}"; do
    if dpkg -l | grep -q "^ii  $package "; then
        echo -e "  ✓ $package already installed"
    else
        echo "  Installing $package..."
        apt-get install -y -qq "$package"
        echo -e "  ✓ $package installed"
    fi
done

echo

# =============================================================================
# STEP 2: Tailscale VPN Setup (Optional)
# =============================================================================
echo -e "${MAGENTA}[2/14] Setting up Tailscale VPN...${NC}"

echo -e "${YELLOW}Tailscale provides secure remote access to your ground stations.${NC}"
echo "It creates a private mesh network between all your devices."
echo "This runs independently from your existing HTTPS connections."
echo
read -p "Install Tailscale VPN for remote access? (yes/no): " -r
echo

if [[ $REPLY =~ ^[Yy]es$ ]]; then
    # Check if Tailscale is already installed
    if command -v tailscale &> /dev/null; then
        echo -e "  ✓ Tailscale already installed"
        
        # Check if it's running
        if systemctl is-active tailscaled >/dev/null 2>&1; then
            echo -e "  ✓ Tailscale daemon is running"
            
            # Check connection status
            if tailscale status &>/dev/null; then
                echo -e "  ✓ Tailscale is connected"
                echo "  Current Tailscale IP:"
                tailscale ip -4 2>/dev/null || echo "    Not connected yet"
            else
                echo -e "  ${YELLOW}⚠ Tailscale installed but not authenticated${NC}"
                echo "  Run 'sudo tailscale up' after deployment to connect"
            fi
        else
            echo -e "  ${YELLOW}⚠ Tailscale daemon not running${NC}"
            echo "  Starting Tailscale daemon..."
            systemctl start tailscaled
            systemctl enable tailscaled
            echo -e "  ✓ Tailscale daemon started and enabled"
        fi
    else
        echo "  Installing Tailscale..."
        
        # Download and run Tailscale install script
        if curl -fsSL https://tailscale.com/install.sh -o /tmp/install-tailscale.sh; then
            chmod +x /tmp/install-tailscale.sh
            
            # Run installation
            if /tmp/install-tailscale.sh >/dev/null 2>&1; then
                echo -e "  ✓ Tailscale installed successfully"
                
                # Enable and start the service
                systemctl enable tailscaled
                systemctl start tailscaled
                echo -e "  ✓ Tailscale daemon started and enabled"
                
                # Add user to tailscale group if it exists
                if getent group tailscale >/dev/null; then
                    usermod -a -G tailscale "$ACTUAL_USER"
                    echo -e "  ✓ User $ACTUAL_USER added to tailscale group"
                fi
                
                echo
                echo -e "  ${GREEN}Tailscale installed!${NC}"
                echo
                echo -e "  ${YELLOW}IMPORTANT: After deployment completes, authenticate Tailscale:${NC}"
                echo "    sudo tailscale up"
                echo
                echo "  Optional: Make this node a subnet router to access local network:"
                echo "    sudo tailscale up --advertise-routes=192.168.1.0/24"
                echo
                echo "  Set a hostname for easy identification:"
                echo "    sudo tailscale up --hostname=ground-station-\$(hostname)"
                
                # Clean up
                rm -f /tmp/install-tailscale.sh
            else
                echo -e "  ${RED}✗ Failed to install Tailscale${NC}"
                echo "  You can try manual installation later:"
                echo "    curl -fsSL https://tailscale.com/install.sh | sh"
                rm -f /tmp/install-tailscale.sh
            fi
        else
            echo -e "  ${RED}✗ Failed to download Tailscale installer${NC}"
            echo "  Check your internet connection and try manual installation:"
            echo "    curl -fsSL https://tailscale.com/install.sh | sh"
        fi
    fi
    
    # Store Tailscale configuration preference
    echo "TAILSCALE_ENABLED=true" >> "$USER_HOME/.stratonode_config" 2>/dev/null || true
    
else
    echo "  Skipping Tailscale installation"
    echo "  You can install it later with:"
    echo "    curl -fsSL https://tailscale.com/install.sh | sh"
    echo "    sudo tailscale up"
fi

echo

# =============================================================================
# STEP 3: Verify Serial Port
# =============================================================================
echo -e "${MAGENTA}[3/14] Verifying serial port configuration...${NC}"

SERIAL_PORT="/dev/ttyAMA0"

if [ -e "$SERIAL_PORT" ]; then
    echo -e "  ✓ Serial port ${GREEN}$SERIAL_PORT${NC} exists"

    # Check if it's a character device
    if [ -c "$SERIAL_PORT" ]; then
        echo -e "  ✓ Serial port is a valid character device"
    else
        echo -e "  ${YELLOW}⚠ Warning: $SERIAL_PORT exists but is not a character device${NC}"
    fi

    # Add user to dialout group for serial access
    if groups "$ACTUAL_USER" | grep -q dialout; then
        echo -e "  ✓ User $ACTUAL_USER is in dialout group"
    else
        echo "  Adding $ACTUAL_USER to dialout group..."
        usermod -a -G dialout "$ACTUAL_USER"
        echo -e "  ✓ User added to dialout group ${YELLOW}(logout required for effect)${NC}"
    fi
else
    echo -e "  ${RED}✗ Serial port $SERIAL_PORT not found${NC}"
    echo -e "  ${YELLOW}⚠ You may need to enable serial hardware via raspi-config${NC}"
    echo "  Run: sudo raspi-config → Interfaces → Serial"
    echo "  - Serial console: No"
    echo "  - Serial hardware: Yes"
fi

echo

# =============================================================================
# STEP 4: Verify Directory Structure
# =============================================================================
echo -e "${MAGENTA}[4/14] Verifying directory structure...${NC}"

# Verify sender directory exists
if [ ! -d "$SENDER_DIR" ]; then
    echo -e "  ${RED}✗ ERROR: Sender directory not found: $SENDER_DIR${NC}"
    echo "  Please upload all files to $SENDER_DIR first"
    exit 1
fi
echo -e "  ✓ Sender directory exists: $SENDER_DIR"

# Ensure parent directory exists with correct ownership
STRATONODE_DIR="$USER_HOME/stratonode"
if [ ! -d "$STRATONODE_DIR" ]; then
    mkdir -p "$STRATONODE_DIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$STRATONODE_DIR"
    echo -e "  ✓ Created parent directory: $STRATONODE_DIR"
fi

# Ensure sender directory has correct ownership
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SENDER_DIR"

# Verify GNSS data directory exists (should be created in NVMe step)
if [ -d "$GNSS_LOG_DIR" ]; then
    echo -e "  ✓ GNSS data directory exists: $GNSS_LOG_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$GNSS_LOG_DIR"
    chmod 755 "$GNSS_LOG_DIR"
else
    echo -e "  ${YELLOW}⚠ Creating GNSS directory: $GNSS_LOG_DIR${NC}"
    mkdir -p "$GNSS_LOG_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$GNSS_LOG_DIR"
    chmod 755 "$GNSS_LOG_DIR"
fi

# Verify StratoCentral log directory exists (should be created in NVMe step)
if [ -d "$STRATO_LOG_DIR" ]; then
    echo -e "  ✓ StratoCentral log directory exists: $STRATO_LOG_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$STRATO_LOG_DIR"
    chmod 755 "$STRATO_LOG_DIR"
else
    echo -e "  ${YELLOW}⚠ Creating StratoCentral directory: $STRATO_LOG_DIR${NC}"
    mkdir -p "$STRATO_LOG_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$STRATO_LOG_DIR"
    chmod 755 "$STRATO_LOG_DIR"
fi

# Display /data mount status
if mountpoint -q "$DATA_DIR"; then
    MOUNT_INFO=$(df -h "$DATA_DIR" | tail -1 | awk '{print $1, $2, $4}')
    echo -e "  ✓ $DATA_DIR is mounted: $MOUNT_INFO"
else
    echo -e "  ${YELLOW}⚠ $DATA_DIR is on root filesystem (no NVMe)${NC}"
fi

echo

# =============================================================================
# STEP 5: Python Virtual Environment
# =============================================================================
echo -e "${MAGENTA}[5/14] Setting up Python virtual environment...${NC}"

# Ensure stratonode directory has correct ownership before creating venv
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$STRATONODE_DIR"

if [ -d "$VENV_DIR" ]; then
    echo -e "  ${YELLOW}⚠ Virtual environment already exists at $VENV_DIR${NC}"
    read -p "  Recreate virtual environment? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy]es$ ]]; then
        echo "  Removing old virtual environment..."
        rm -rf "$VENV_DIR"
    else
        echo "  Keeping existing virtual environment"
        # Ensure existing venv has correct ownership
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$VENV_DIR"
    fi
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "  Creating virtual environment..."
    # Run as the actual user to avoid permission issues
    sudo -u "$ACTUAL_USER" python3 -m venv "$VENV_DIR"

    if [ $? -eq 0 ]; then
        echo -e "  ✓ Virtual environment created"
    else
        echo -e "  ${RED}✗ Failed to create virtual environment${NC}"
        exit 1
    fi
fi

echo

# =============================================================================
# STEP 6: Install Python Dependencies
# =============================================================================
echo -e "${MAGENTA}[6/14] Installing Python dependencies...${NC}"

if [ -f "$SENDER_DIR/requirements.txt" ]; then
    echo "  Installing from requirements.txt..."
    sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/pip" install -q --upgrade pip
    sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/pip" install -q -r "$SENDER_DIR/requirements.txt"
    echo -e "  ✓ Python packages installed"
else
    echo -e "  ${YELLOW}⚠ requirements.txt not found, installing core packages...${NC}"
    sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/pip" install -q --upgrade pip
    sudo -u "$ACTUAL_USER" "$VENV_DIR/bin/pip" install -q pyserial requests
    echo -e "  ✓ Core packages installed"
fi

echo

# =============================================================================
# STEP 7: Setup NVMe Storage Drive
# =============================================================================
echo -e "${MAGENTA}[7/14] Setting up NVMe storage drive...${NC}"

# Check if NVMe drive is present
echo "  Checking for NVMe drive..."
NVME_DEVICE="/dev/nvme0n1"
NVME_PARTITION="/dev/nvme0n1p1"

if lsblk | grep -q "nvme0n1"; then
    echo -e "  ✓ NVMe drive detected: $NVME_DEVICE"
    
    # Check if already mounted on /data
    if mount | grep -q "$NVME_PARTITION on /data"; then
        echo -e "  ✓ NVMe already mounted on /data"
        NVME_UUID=$(blkid -s UUID -o value $NVME_PARTITION 2>/dev/null)
        echo "  UUID: $NVME_UUID"
        
        # Check if in fstab
        if grep -q "$NVME_UUID" /etc/fstab 2>/dev/null || grep -q "$NVME_PARTITION" /etc/fstab 2>/dev/null; then
            echo -e "  ✓ NVMe mount already in /etc/fstab"
        else
            echo -e "  ${YELLOW}⚠ NVMe mounted but not in /etc/fstab${NC}"
            read -p "  Add to /etc/fstab for automatic mounting? (yes/no): " -r
            if [[ $REPLY =~ ^[Yy]es$ ]]; then
                echo "UUID=$NVME_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab
                echo -e "  ✓ Added to /etc/fstab"
            fi
        fi
    else
        # Check if partition exists
        if [ -b "$NVME_PARTITION" ]; then
            echo -e "  ${YELLOW}⚠ NVMe partition exists but not mounted${NC}"
            
            # Check if it has a filesystem
            if blkid $NVME_PARTITION &>/dev/null; then
                echo "  Partition has a filesystem"
                read -p "  Mount existing partition? (yes/no): " -r
                if [[ $REPLY =~ ^[Yy]es$ ]]; then
                    mkdir -p /data
                    mount $NVME_PARTITION /data
                    if [ $? -eq 0 ]; then
                        echo -e "  ✓ Mounted $NVME_PARTITION on /data"
                        
                        # Add to fstab
                        NVME_UUID=$(blkid -s UUID -o value $NVME_PARTITION)
                        if ! grep -q "$NVME_UUID" /etc/fstab 2>/dev/null; then
                            echo "UUID=$NVME_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab
                            echo -e "  ✓ Added to /etc/fstab"
                        fi
                    else
                        echo -e "  ${RED}✗ Failed to mount partition${NC}"
                    fi
                fi
            else
                echo -e "  ${RED}✗ Partition exists but has no filesystem${NC}"
                echo "  Please manually prepare the partition"
            fi
        else
            # No partition exists, offer to create
            echo -e "  ${YELLOW}⚠ NVMe drive not partitioned${NC}"
            echo
            echo -e "  ${YELLOW}WARNING: This will CREATE A NEW PARTITION on $NVME_DEVICE${NC}"
            echo -e "  ${RED}This will DESTROY ALL DATA on the drive!${NC}"
            echo
            read -p "  Create new partition and filesystem? (yes/no): " -r
            
            if [[ $REPLY =~ ^[Yy]es$ ]]; then
                echo "  Creating partition..."
                
                # Use fdisk with automated commands
                (echo g      # Create GPT partition table
                 echo n      # New partition
                 echo        # Default partition number (1)
                 echo        # Default first sector
                 echo        # Default last sector (use full disk)
                 echo w      # Write changes
                ) | fdisk $NVME_DEVICE &>/dev/null
                
                if [ $? -eq 0 ]; then
                    echo -e "  ✓ Partition created"
                    
                    # Wait for partition to be recognized
                    sleep 2
                    partprobe $NVME_DEVICE 2>/dev/null
                    
                    # Create filesystem
                    echo "  Creating ext4 filesystem..."
                    mkfs.ext4 -F -L STRATODATA $NVME_PARTITION &>/dev/null
                    
                    if [ $? -eq 0 ]; then
                        echo -e "  ✓ Filesystem created with label STRATODATA"
                        
                        # Create mount point and mount
                        mkdir -p /data
                        mount $NVME_PARTITION /data
                        
                        if [ $? -eq 0 ]; then
                            echo -e "  ✓ Mounted $NVME_PARTITION on /data"
                            
                            # Get UUID and add to fstab
                            NVME_UUID=$(blkid -s UUID -o value $NVME_PARTITION)
                            echo "  UUID: $NVME_UUID"
                            
                            # Add to fstab if not already there
                            if ! grep -q "$NVME_UUID" /etc/fstab 2>/dev/null; then
                                echo "UUID=$NVME_UUID /data ext4 defaults,noatime 0 2" >> /etc/fstab
                                echo -e "  ✓ Added to /etc/fstab for automatic mounting"
                            fi
                            
                            # Verify mount
                            df -h | grep "/data" | head -1
                        else
                            echo -e "  ${RED}✗ Failed to mount partition${NC}"
                        fi
                    else
                        echo -e "  ${RED}✗ Failed to create filesystem${NC}"
                    fi
                else
                    echo -e "  ${RED}✗ Failed to create partition${NC}"
                    echo "  You may need to manually partition the drive"
                fi
            else
                echo "  Skipping NVMe setup"
                echo -e "  ${YELLOW}Note: System will use root filesystem for data storage${NC}"
            fi
        fi
    fi
else
    echo -e "  ${YELLOW}⚠ No NVMe drive detected${NC}"
    echo "  System will use root filesystem for data storage"
    
    # Create /data directory on root filesystem if it doesn't exist
    if [ ! -d "/data" ]; then
        mkdir -p /data
        echo -e "  ✓ Created /data directory on root filesystem"
    fi
fi

# Ensure data directories exist with correct permissions
if [ -d "/data" ]; then
    # Create GNSS directory
    if [ ! -d "/data/gnss" ]; then
        mkdir -p /data/gnss
        echo -e "  ✓ Created /data/gnss directory"
    fi
    
    # Create stratocentral logs directory
    if [ ! -d "/data/stratocentral/logs" ]; then
        mkdir -p /data/stratocentral/logs
        echo -e "  ✓ Created /data/stratocentral/logs directory"
    fi
    
    # Set ownership for all data directories
    chown -R "$ACTUAL_USER:$ACTUAL_USER" /data
    echo -e "  ✓ Set ownership of /data to $ACTUAL_USER:$ACTUAL_USER"
    
    # Display storage info
    echo
    echo "  Storage Configuration:"
    df -h /data | tail -1 | awk '{printf "    Filesystem: %s\n    Size: %s, Used: %s, Available: %s\n", $1, $2, $3, $4}'
fi

echo

# =============================================================================
# STEP 8: Configure File Permissions
# =============================================================================
echo -e "${MAGENTA}[8/14] Configuring file permissions...${NC}"

# Make Python scripts executable
PYTHON_SCRIPTS=(
    "gnss_combined_service.py"
    "gnss_reader.py"
    "test_reader.py"
)

for script in "${PYTHON_SCRIPTS[@]}"; do
    if [ -f "$SENDER_DIR/$script" ]; then
        chmod +x "$SENDER_DIR/$script"
        echo -e "  ✓ $script is executable"
    else
        echo -e "  ${YELLOW}⚠ $script not found${NC}"
    fi
done

# Make shell scripts executable
SHELL_SCRIPTS=(
    "monitor_ubx_health.sh"
    "setup_monitor.sh"
)

for script in "${SHELL_SCRIPTS[@]}"; do
    if [ -f "$SENDER_DIR/$script" ]; then
        chmod +x "$SENDER_DIR/$script"
        echo -e "  ✓ $script is executable"
    else
        echo -e "  ${YELLOW}⚠ $script not found${NC}"
    fi
done

# Set ownership
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SENDER_DIR"
echo -e "  ✓ Ownership set to $ACTUAL_USER:$ACTUAL_USER"

echo

# =============================================================================
# STEP 9: Verify Configuration File
# =============================================================================
echo -e "${MAGENTA}[9/14] Verifying configuration file...${NC}"

ENV_FILE="$SENDER_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    echo -e "  ✓ Configuration file exists: .env"

    # Check critical configuration values
    echo "  Checking configuration..."

    # Station ID
    if grep -q "^STATION_ID=" "$ENV_FILE"; then
        STATION_ID=$(grep "^STATION_ID=" "$ENV_FILE" | cut -d'=' -f2)
        echo "    Station ID: $STATION_ID"
    else
        echo -e "    ${YELLOW}⚠ STATION_ID not set${NC}"
    fi

    # Ingest URL
    if grep -q "^INGEST_URL=" "$ENV_FILE"; then
        INGEST_URL=$(grep "^INGEST_URL=" "$ENV_FILE" | cut -d'=' -f2)
        echo "    Ingest URL: $INGEST_URL"
    else
        echo -e "    ${YELLOW}⚠ INGEST_URL not set${NC}"
    fi

    # Serial port
    if grep -q "^SERIAL_PORT=" "$ENV_FILE"; then
        CONF_SERIAL=$(grep "^SERIAL_PORT=" "$ENV_FILE" | cut -d'=' -f2)
        echo "    Serial port: $CONF_SERIAL"
    else
        echo -e "    ${YELLOW}⚠ SERIAL_PORT not set${NC}"
    fi

else
    echo -e "  ${RED}✗ Configuration file not found: .env${NC}"
    echo "  Creating template .env file..."

    cat > "$ENV_FILE" <<EOF
# StratoCentral Ground Station Configuration

# Station Identification (MUST BE UNIQUE PER STATION!)
STATION_ID=SN_XXX
STATION_NAME=Ground Station Name

# Central-ingest service URL (HTTPS via nginx reverse proxy)
INGEST_URL=https://ingest.stratosentinel.com/api/v1/ingest

# API key for authentication (must match central-ingest configuration)
API_KEY=your_api_key_here

# Known surveyed position (decimal degrees, meters)
LATITUDE=0.0
LONGITUDE=0.0
ANTENNA_HEIGHT=0.0

# Sender behavior
SEND_INTERVAL=1

# Reference station
IS_REFERENCE_STATION=true

# Live GNSS Device
GNSS_DEVICE=/dev/ttyAMA0
GNSS_BAUD_RATE=115200

EOF

    chown "$ACTUAL_USER:$ACTUAL_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"

    echo -e "  ${YELLOW}⚠ Template .env created - YOU MUST EDIT IT!${NC}"
    echo -e "  ${YELLOW}  Edit: $ENV_FILE${NC}"
    echo -e "  ${YELLOW}  Set: STATION_ID, INGEST_URL, API_KEY, coordinates${NC}"
fi

echo

# =============================================================================
# STEP 10: Install Combined Service
# =============================================================================
echo -e "${MAGENTA}[10/14] Installing combined service...${NC}"

SERVICE_FILE="$SENDER_DIR/combined.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo -e "  ${YELLOW}⚠ combined.service not found, creating...${NC}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=StratoCentral Ground Station Combined Service
Documentation=file://$SENDER_DIR/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=$ACTUAL_USER
WorkingDirectory=$SENDER_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python3 $SENDER_DIR/gnss_combined_service.py

# Restart policy
Restart=always
RestartSec=10

# Resource limits
LimitNOFILE=65536

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=combined

[Install]
WantedBy=multi-user.target
EOF
fi

# Install service file
cp "$SERVICE_FILE" /etc/systemd/system/combined.service
chmod 644 /etc/systemd/system/combined.service
echo -e "  ✓ Service file installed: /etc/systemd/system/combined.service"

# Reload systemd
systemctl daemon-reload
echo -e "  ✓ Systemd configuration reloaded"

echo

# =============================================================================
# STEP 11: Install UBX Health Monitor
# =============================================================================
echo -e "${MAGENTA}[11/14] Installing UBX health monitor...${NC}"

MONITOR_SERVICE="$SENDER_DIR/combined-monitor.service"
MONITOR_TIMER="$SENDER_DIR/combined-monitor.timer"

if [ ! -f "$MONITOR_SERVICE" ] || [ ! -f "$MONITOR_TIMER" ]; then
    echo -e "  ${RED}✗ Monitor service files not found${NC}"
    echo "  Please ensure combined-monitor.service and combined-monitor.timer exist"
    echo "  Skipping monitor installation..."
else
    # Copy service and timer files
    cp "$MONITOR_SERVICE" /etc/systemd/system/
    cp "$MONITOR_TIMER" /etc/systemd/system/
    chmod 644 /etc/systemd/system/combined-monitor.service
    chmod 644 /etc/systemd/system/combined-monitor.timer
    echo -e "  ✓ Monitor service files installed"

    # Configure sudo permissions for monitor
    SUDOERS_FILE="/etc/sudoers.d/stratocentral-monitor"

    cat > "$SUDOERS_FILE" <<EOF
# Allow strato user to restart combined service without password
# Required for UBX health monitor to auto-restart on desync
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart combined
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl is-active combined
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl status combined
EOF

    chmod 440 "$SUDOERS_FILE"

    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        echo -e "  ✓ Sudo permissions configured"
    else
        echo -e "  ${RED}✗ Invalid sudoers configuration${NC}"
        rm -f "$SUDOERS_FILE"
    fi

    # Reload systemd
    systemctl daemon-reload
    echo -e "  ✓ Monitor configuration reloaded"
fi

echo

# =============================================================================
# STEP 12: Enable Services
# =============================================================================
echo -e "${MAGENTA}[12/14] Enabling services...${NC}"

# Enable combined service
systemctl enable combined.service
echo -e "  ✓ Combined service enabled (will start on boot)"

# Enable monitor timer if it exists
if [ -f /etc/systemd/system/combined-monitor.timer ]; then
    systemctl enable combined-monitor.timer
    echo -e "  ✓ UBX health monitor enabled (will start on boot)"
else
    echo -e "  ${YELLOW}⚠ Monitor timer not available${NC}"
fi

echo

# =============================================================================
# STEP 13: Start Services
# =============================================================================
echo -e "${MAGENTA}[13/14] Starting services...${NC}"

read -p "Start services now? (yes/no): " -r
echo

if [[ $REPLY =~ ^[Yy]es$ ]]; then
    # Start combined service
    echo "  Starting combined service..."
    systemctl start combined.service
    sleep 2

    if systemctl is-active combined.service >/dev/null 2>&1; then
        echo -e "  ✓ Combined service ${GREEN}started${NC}"
    else
        echo -e "  ${RED}✗ Combined service failed to start${NC}"
        echo "  Check logs: sudo journalctl -u combined -n 50"
    fi

    # Start monitor timer
    if [ -f /etc/systemd/system/combined-monitor.timer ]; then
        echo "  Starting UBX health monitor..."
        systemctl start combined-monitor.timer
        sleep 1

        if systemctl is-active combined-monitor.timer >/dev/null 2>&1; then
            echo -e "  ✓ UBX health monitor ${GREEN}started${NC}"
        else
            echo -e "  ${YELLOW}⚠ Monitor timer not started${NC}"
        fi
    fi
else
    echo "  Services not started. Start manually with:"
    echo "    sudo systemctl start combined"
    echo "    sudo systemctl start combined-monitor.timer"
fi

echo

# =============================================================================
# STEP 14: Verification
# =============================================================================
echo -e "${MAGENTA}[14/14] Running verification checks...${NC}"

CHECKS_PASSED=0
CHECKS_TOTAL=0

# Check 1: Virtual environment
((CHECKS_TOTAL++))
if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/python3" ]; then
    echo -e "  ✓ Virtual environment exists"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Virtual environment missing${NC}"
fi

# Check 2: Data directories
((CHECKS_TOTAL++))
if [ -d "$GNSS_LOG_DIR" ] && [ -d "$STRATO_LOG_DIR" ]; then
    echo -e "  ✓ Data directories exist"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Data directories missing${NC}"
fi

# Check 3: NVMe storage
((CHECKS_TOTAL++))
if mountpoint -q "$DATA_DIR" && mount | grep -q "nvme0n1"; then
    echo -e "  ✓ NVMe storage mounted on /data"
    ((CHECKS_PASSED++))
elif [ -d "$DATA_DIR" ]; then
    echo -e "  ${YELLOW}⚠ Using root filesystem for /data (no NVMe)${NC}"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ /data directory not available${NC}"
fi

# Check 4: Service files
((CHECKS_TOTAL++))
if [ -f /etc/systemd/system/combined.service ]; then
    echo -e "  ✓ Combined service installed"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Combined service not installed${NC}"
fi

# Check 5: Configuration file
((CHECKS_TOTAL++))
if [ -f "$ENV_FILE" ]; then
    echo -e "  ✓ Configuration file exists"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Configuration file missing${NC}"
fi

# Check 6: Service enabled
((CHECKS_TOTAL++))
if systemctl is-enabled combined.service >/dev/null 2>&1; then
    echo -e "  ✓ Combined service enabled"
    ((CHECKS_PASSED++))
else
    echo -e "  ${YELLOW}⚠ Combined service not enabled${NC}"
fi

# Check 7: Monitor timer
((CHECKS_TOTAL++))
if [ -f /etc/systemd/system/combined-monitor.timer ]; then
    if systemctl is-enabled combined-monitor.timer >/dev/null 2>&1; then
        echo -e "  ✓ UBX health monitor enabled"
        ((CHECKS_PASSED++))
    else
        echo -e "  ${YELLOW}⚠ Monitor installed but not enabled${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠ UBX health monitor not installed${NC}"
fi

echo
echo -e "${BLUE}Verification: $CHECKS_PASSED/$CHECKS_TOTAL checks passed${NC}"
echo

# =============================================================================
# Deployment Summary
# =============================================================================
echo
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}║                 ${GREEN}Deployment Complete!${CYAN}                      ║${NC}"
echo -e "${CYAN}║                                                            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo

echo -e "${GREEN}Services Installed:${NC}"
echo "  • combined.service          - Main GNSS collection service"
echo "  • combined-monitor.timer    - UBX health monitoring"
echo

echo -e "${GREEN}Data Directories:${NC}"
echo "  • GNSS Logs:  $GNSS_LOG_DIR"
echo "  • Monitor:    $STRATO_LOG_DIR/ubx_monitor.log"
echo

echo -e "${GREEN}Next Steps:${NC}"
echo

# Check if Tailscale needs authentication
if command -v tailscale &> /dev/null && ! tailscale status &>/dev/null 2>&1; then
    echo -e "${YELLOW}1. AUTHENTICATE TAILSCALE VPN:${NC}"
    echo "   sudo tailscale up"
    echo
    echo "   This will provide a URL to authenticate your device."
    echo "   Optional: Set a friendly hostname:"
    echo "   sudo tailscale up --hostname=ground-station-$(hostname)"
    echo
    STEP_NUM=2
else
    STEP_NUM=1
fi

if [ ! -f "$ENV_FILE" ] || grep -q "your-api-key-here" "$ENV_FILE" 2>/dev/null; then
    echo -e "${YELLOW}$STEP_NUM. EDIT CONFIGURATION FILE:${NC}"
    echo "   nano $ENV_FILE"
    echo
    echo "   Required settings:"
    echo "   - STATION_ID (must be unique!)"
    echo "   - KNOWN_LATITUDE, KNOWN_LONGITUDE, KNOWN_ALTITUDE"
    echo "   - INGEST_URL"
    echo "   - API_KEY"
    echo
    ((STEP_NUM++))
else
    STEP_NUM=$((STEP_NUM))
fi

echo "$STEP_NUM. Check service status:"
echo "   sudo systemctl status combined"
echo "   sudo systemctl status combined-monitor.timer"
echo

((STEP_NUM++))
echo "$STEP_NUM. View live logs:"
echo "   sudo journalctl -u combined -f"
echo

((STEP_NUM++))
echo "$STEP_NUM. View monitor logs:"
echo "   tail -f $STRATO_LOG_DIR/ubx_monitor.log"
echo

((STEP_NUM++))
echo "$STEP_NUM. Test serial connection:"
echo "   $VENV_DIR/bin/python3 $SENDER_DIR/test_reader.py"
echo

echo -e "${GREEN}Useful Commands:${NC}"
echo "  • Restart service:        sudo systemctl restart combined"
echo "  • Stop service:           sudo systemctl stop combined"
echo "  • Check service status:   sudo systemctl status combined"
echo "  • View recent logs:       sudo journalctl -u combined -n 100"
echo "  • View error logs:        sudo journalctl -u combined -p err"
echo

# Check if Tailscale is installed and show relevant commands
if command -v tailscale &> /dev/null; then
    echo -e "${GREEN}Tailscale VPN Commands:${NC}"
    echo "  • Connect to network:     sudo tailscale up"
    echo "  • Check VPN status:       tailscale status"
    echo "  • Show your VPN IP:       tailscale ip -4"
    echo "  • Enable subnet routing:  sudo tailscale up --advertise-routes=192.168.1.0/24"
    echo "  • Set friendly hostname:  sudo tailscale up --hostname=ground-station-\$(hostname)"
    
    # Show current status if connected
    if tailscale status &>/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Not connected")
        echo
        echo -e "  ${CYAN}Current Tailscale IP: $TAILSCALE_IP${NC}"
    fi
    echo
fi

echo -e "${BLUE}Documentation:${NC}"
echo "  • UBX Desync Fix:         $SENDER_DIR/UBX_DESYNC_FIX.md"
echo "  • Monitor Setup:          $SENDER_DIR/MONITOR_SERVICE_SETUP.md"
echo "  • ZED-F9P Config:         $SENDER_DIR/ZED_F9P_MESSAGE_CONFIG.md"
echo "  • Second Station Setup:   $SENDER_DIR/SECOND_STATION_SETUP.md"
echo

if systemctl is-active combined.service >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Your ground station is now running!${NC}"
    echo
    echo "Check the dashboard - your node should appear ONLINE shortly."
else
    echo -e "${YELLOW}⚠ Service is installed but not running.${NC}"
    echo
    echo "Start the service with: sudo systemctl start combined"
fi

echo
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo

# Save deployment info
DEPLOY_INFO="$SENDER_DIR/.deploy_info"
cat > "$DEPLOY_INFO" <<EOF
# StratoCentral Ground Station Deployment Info
# Auto-generated by deploy_all.sh

DEPLOY_DATE=$DEPLOY_DATE
DEPLOY_VERSION=$SCRIPT_VERSION
DEPLOY_USER=$ACTUAL_USER
PYTHON_VERSION=$($VENV_DIR/bin/python3 --version 2>&1)
EOF

# Add Tailscale info if installed
if command -v tailscale &> /dev/null; then
    echo "TAILSCALE_INSTALLED=yes" >> "$DEPLOY_INFO"
    if tailscale status &>/dev/null 2>&1; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Not connected")
        echo "TAILSCALE_IP=$TAILSCALE_IP" >> "$DEPLOY_INFO"
    else
        echo "TAILSCALE_IP=Not connected" >> "$DEPLOY_INFO"
    fi
else
    echo "TAILSCALE_INSTALLED=no" >> "$DEPLOY_INFO"
fi

chown "$ACTUAL_USER:$ACTUAL_USER" "$DEPLOY_INFO"

echo "Deployment information saved to: $DEPLOY_INFO"
echo

exit 0
