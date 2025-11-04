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
echo "  • Create Python virtual environment"
echo "  • Install Python dependencies"
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
echo -e "${MAGENTA}[1/12] Installing system packages...${NC}"

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
# STEP 2: Verify Serial Port
# =============================================================================
echo -e "${MAGENTA}[2/12] Verifying serial port configuration...${NC}"

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
# STEP 3: Create Directory Structure
# =============================================================================
echo -e "${MAGENTA}[3/12] Creating directory structure...${NC}"

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

# Create GNSS data directory
mkdir -p "$GNSS_LOG_DIR"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$GNSS_LOG_DIR"
chmod 755 "$GNSS_LOG_DIR"
echo -e "  ✓ Created: $GNSS_LOG_DIR"

# Create StratoCentral log directory
mkdir -p "$STRATO_LOG_DIR"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$STRATO_LOG_DIR"
chmod 755 "$STRATO_LOG_DIR"
echo -e "  ✓ Created: $STRATO_LOG_DIR"

# Verify /data is on NVMe
if mountpoint -q "$DATA_DIR"; then
    MOUNT_INFO=$(df -h "$DATA_DIR" | tail -1 | awk '{print $1, $2}')
    echo -e "  ✓ $DATA_DIR is a mountpoint: $MOUNT_INFO"
else
    echo -e "  ${YELLOW}⚠ Warning: $DATA_DIR is not a separate mountpoint${NC}"
    echo "  Consider mounting your NVMe drive to $DATA_DIR for better performance"
fi

echo

# =============================================================================
# STEP 4: Python Virtual Environment
# =============================================================================
echo -e "${MAGENTA}[4/12] Setting up Python virtual environment...${NC}"

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
# STEP 5: Install Python Dependencies
# =============================================================================
echo -e "${MAGENTA}[5/12] Installing Python dependencies...${NC}"

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
# STEP 6: Configure File Permissions
# =============================================================================
echo -e "${MAGENTA}[6/12] Configuring file permissions...${NC}"

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
# STEP 7: Verify Configuration File
# =============================================================================
echo -e "${MAGENTA}[7/12] Verifying configuration file...${NC}"

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

# Known surveyed position (decimal degrees, meters)
KNOWN_LATITUDE=0.0
KNOWN_LONGITUDE=0.0
KNOWN_ALTITUDE=0.0

# Serial Port Configuration
SERIAL_PORT=/dev/ttyAMA0
SERIAL_BAUD=115200

# Central Server Configuration
INGEST_URL=https://your-server.com/api/v1/ingest

# Authentication (EACH STATION NEEDS ITS OWN UNIQUE API KEY!)
# Generate a unique API key for this station on your central server
API_KEY=your-unique-api-key-here

# Data Logging Configuration
LOG_TO_FILE=true
LOG_DIR=$GNSS_LOG_DIR

# Network Configuration
SEND_BATCH_SIZE=10
SEND_INTERVAL_SECONDS=5
MAX_RETRY_ATTEMPTS=3
RETRY_BACKOFF_SECONDS=5

# Logging
LOG_LEVEL=INFO
EOF

    chown "$ACTUAL_USER:$ACTUAL_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"

    echo -e "  ${YELLOW}⚠ Template .env created - YOU MUST EDIT IT!${NC}"
    echo -e "  ${YELLOW}  Edit: $ENV_FILE${NC}"
    echo -e "  ${YELLOW}  Set: STATION_ID, INGEST_URL, API_KEY, coordinates${NC}"
fi

echo

# =============================================================================
# STEP 8: Install Combined Service
# =============================================================================
echo -e "${MAGENTA}[8/12] Installing combined service...${NC}"

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
# STEP 9: Install UBX Health Monitor
# =============================================================================
echo -e "${MAGENTA}[9/12] Installing UBX health monitor...${NC}"

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
# STEP 10: Enable Services
# =============================================================================
echo -e "${MAGENTA}[10/12] Enabling services...${NC}"

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
# STEP 11: Start Services
# =============================================================================
echo -e "${MAGENTA}[11/12] Starting services...${NC}"

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
# STEP 12: Verification
# =============================================================================
echo -e "${MAGENTA}[12/12] Running verification checks...${NC}"

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

# Check 3: Service files
((CHECKS_TOTAL++))
if [ -f /etc/systemd/system/combined.service ]; then
    echo -e "  ✓ Combined service installed"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Combined service not installed${NC}"
fi

# Check 4: Configuration file
((CHECKS_TOTAL++))
if [ -f "$ENV_FILE" ]; then
    echo -e "  ✓ Configuration file exists"
    ((CHECKS_PASSED++))
else
    echo -e "  ${RED}✗ Configuration file missing${NC}"
fi

# Check 5: Service enabled
((CHECKS_TOTAL++))
if systemctl is-enabled combined.service >/dev/null 2>&1; then
    echo -e "  ✓ Combined service enabled"
    ((CHECKS_PASSED++))
else
    echo -e "  ${YELLOW}⚠ Combined service not enabled${NC}"
fi

# Check 6: Monitor timer
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

if [ ! -f "$ENV_FILE" ] || grep -q "your-api-key-here" "$ENV_FILE" 2>/dev/null; then
    echo -e "${YELLOW}1. EDIT CONFIGURATION FILE:${NC}"
    echo "   nano $ENV_FILE"
    echo
    echo "   Required settings:"
    echo "   - STATION_ID (must be unique!)"
    echo "   - KNOWN_LATITUDE, KNOWN_LONGITUDE, KNOWN_ALTITUDE"
    echo "   - INGEST_URL"
    echo "   - API_KEY"
    echo
fi

echo "2. Check service status:"
echo "   sudo systemctl status combined"
echo "   sudo systemctl status combined-monitor.timer"
echo

echo "3. View live logs:"
echo "   sudo journalctl -u combined -f"
echo

echo "4. View monitor logs:"
echo "   tail -f $STRATO_LOG_DIR/ubx_monitor.log"
echo

echo "5. Test serial connection:"
echo "   $VENV_DIR/bin/python3 $SENDER_DIR/test_reader.py"
echo

echo -e "${GREEN}Useful Commands:${NC}"
echo "  • Restart service:        sudo systemctl restart combined"
echo "  • Stop service:           sudo systemctl stop combined"
echo "  • Check service status:   sudo systemctl status combined"
echo "  • View recent logs:       sudo journalctl -u combined -n 100"
echo "  • View error logs:        sudo journalctl -u combined -p err"
echo

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

chown "$ACTUAL_USER:$ACTUAL_USER" "$DEPLOY_INFO"

echo "Deployment information saved to: $DEPLOY_INFO"
echo

exit 0
