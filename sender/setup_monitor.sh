#!/bin/bash
#
# Setup UBX Health Monitor
#
# This script configures the UBX health monitoring system for the combined service.
# Run this script with sudo on your ground station Raspberry Pi.
#
# Usage: sudo ./setup_monitor.sh
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== UBX Health Monitor Setup ===${NC}"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run with sudo${NC}"
    echo "Usage: sudo ./setup_monitor.sh"
    exit 1
fi

# Get the actual user (not root) who ran sudo
ACTUAL_USER="${SUDO_USER:-strato}"
USER_HOME=$(eval echo ~$ACTUAL_USER)

echo -e "${YELLOW}Configuration:${NC}"
echo "  User: $ACTUAL_USER"
echo "  Home: $USER_HOME"
echo

# Step 1: Create log directory on NVMe drive
echo -e "${GREEN}[1/5] Creating log directory on NVMe...${NC}"
LOG_DIR="/data/stratocentral/logs"
mkdir -p "$LOG_DIR"
chown $ACTUAL_USER:$ACTUAL_USER "$LOG_DIR"
chmod 755 "$LOG_DIR"
echo "  Created: $LOG_DIR"

# Verify /data is mounted
if ! mountpoint -q /data; then
    echo -e "${YELLOW}  WARNING: /data is not a mountpoint. Using /data anyway.${NC}"
fi
echo

# Step 2: Configure passwordless sudo for service restart
echo -e "${GREEN}[2/5] Configuring sudo permissions...${NC}"
SUDOERS_FILE="/etc/sudoers.d/stratocentral-monitor"

cat > "$SUDOERS_FILE" <<EOF
# Allow strato user to restart combined service without password
# Required for UBX health monitor to auto-restart on desync
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart combined
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl is-active combined
$ACTUAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl status combined
EOF

# Set correct permissions for sudoers file
chmod 440 "$SUDOERS_FILE"

# Validate sudoers file
if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo "  Created: $SUDOERS_FILE"
else
    echo -e "${RED}  ERROR: Invalid sudoers file!${NC}"
    rm -f "$SUDOERS_FILE"
    exit 1
fi
echo

# Step 3: Install systemd service and timer files
echo -e "${GREEN}[3/5] Installing systemd files...${NC}"

# Verify source files exist
if [ ! -f "$USER_HOME/stratonode/sender/combined-monitor.service" ]; then
    echo -e "${RED}  ERROR: combined-monitor.service not found in $USER_HOME/stratonode/sender/${NC}"
    echo "  Please upload the file from your repository first."
    exit 1
fi

if [ ! -f "$USER_HOME/stratonode/sender/combined-monitor.timer" ]; then
    echo -e "${RED}  ERROR: combined-monitor.timer not found in $USER_HOME/stratonode/sender/${NC}"
    echo "  Please upload the file from your repository first."
    exit 1
fi

# Copy service file
cp "$USER_HOME/stratonode/sender/combined-monitor.service" /etc/systemd/system/
chmod 644 /etc/systemd/system/combined-monitor.service
echo "  Installed: /etc/systemd/system/combined-monitor.service"

# Copy timer file
cp "$USER_HOME/stratonode/sender/combined-monitor.timer" /etc/systemd/system/
chmod 644 /etc/systemd/system/combined-monitor.timer
echo "  Installed: /etc/systemd/system/combined-monitor.timer"
echo

# Step 4: Reload systemd and enable timer
echo -e "${GREEN}[4/5] Enabling monitor timer...${NC}"
systemctl daemon-reload
systemctl enable combined-monitor.timer
systemctl start combined-monitor.timer
echo "  Timer enabled and started"
echo

# Step 5: Verify installation
echo -e "${GREEN}[5/5] Verifying installation...${NC}"

# Check timer status
if systemctl is-active combined-monitor.timer >/dev/null 2>&1; then
    echo -e "  ✓ Timer is ${GREEN}active${NC}"
else
    echo -e "  ✗ Timer is ${RED}inactive${NC}"
    exit 1
fi

# Check log directory
if [ -d "$LOG_DIR" ] && [ -w "$LOG_DIR" ]; then
    echo -e "  ✓ Log directory ${GREEN}writable${NC}"
else
    echo -e "  ✗ Log directory ${RED}not writable${NC}"
    exit 1
fi

# Check sudoers file exists and is valid
if [ -f "$SUDOERS_FILE" ] && visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo -e "  ✓ Sudo permissions ${GREEN}configured${NC}"
else
    echo -e "  ✗ Sudo permissions ${RED}not configured${NC}"
    exit 1
fi

echo
echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo
echo "Monitor status:"
systemctl status combined-monitor.timer --no-pager | head -10
echo
echo "Next run:"
systemctl list-timers combined-monitor.timer --no-pager
echo
echo "To view monitor logs:"
echo "  tail -f /data/stratocentral/logs/ubx_monitor.log"
echo
echo "To view systemd logs:"
echo "  sudo journalctl -u combined-monitor.service -f"
echo
