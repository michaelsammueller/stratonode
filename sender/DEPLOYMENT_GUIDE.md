# StratoCentral Ground Station - Deployment Guide

**Complete automated deployment for StratoCentral ground stations**

---

## Overview

The `deploy_all.sh` script automates the complete setup of a StratoCentral ground station, including:

- ✅ System package installation
- ✅ Python virtual environment setup
- ✅ Dependency installation
- ✅ Directory structure creation
- ✅ File permissions configuration
- ✅ Systemd service installation
- ✅ UBX health monitoring setup
- ✅ Auto-start on boot configuration

**Time to deploy**: ~5 minutes

---

## Prerequisites

### Hardware Requirements

- Raspberry Pi 4 (4GB+ RAM recommended)
- u-blox ZED-F9P GNSS receiver
- MicroSD card with Raspberry Pi OS
- NVMe SSD (recommended, mounted at `/data`)
- Network connectivity

### Software Requirements

- Raspberry Pi OS (Bullseye or later)
- SSH access enabled
- Serial port enabled via `raspi-config`

### Before You Start

1. **Enable Serial Port**:
   ```bash
   sudo raspi-config
   ```
   - Navigate to: Interfaces → Serial
   - Serial console: **No**
   - Serial hardware: **Yes**
   - Reboot

2. **Mount NVMe Drive** (if using external storage):
   ```bash
   sudo mkdir -p /data
   sudo mount /dev/nvme0n1p1 /data  # Adjust device as needed

   # Add to /etc/fstab for auto-mount on boot
   echo "/dev/nvme0n1p1 /data ext4 defaults 0 2" | sudo tee -a /etc/fstab
   ```

3. **Set Hostname** (optional but recommended):
   ```bash
   sudo hostnamectl set-hostname stratonode01
   ```

---

## Deployment Steps

### Step 1: Upload Files to Raspberry Pi

On your development machine:

```bash
cd ~/Documents/GitHub/stratocentral/ground-node-sender

# Create stratonode directory on Pi
ssh strato@stratonode01 'mkdir -p ~/stratonode/sender'

# Upload all files
scp * strato@stratonode01:~/stratonode/sender/

# Or use rsync for cleaner transfer
rsync -av --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    ./ strato@stratonode01:~/stratonode/sender/
```

### Step 2: Configure Station Settings

SSH into your Raspberry Pi:

```bash
ssh strato@stratonode01
cd ~/stratonode/sender
```

**Edit the configuration file**:

```bash
nano .env
```

**Required settings** (must be unique per station):

```bash
# Station Identification - MUST BE UNIQUE PER STATION!
STATION_ID=SN_001
STATION_NAME=Primary Ground Station

# Known surveyed position (use GPS coordinates from surveying)
KNOWN_LATITUDE=25.372727
KNOWN_LONGITUDE=51.558232
KNOWN_ALTITUDE=56.5

# Serial Port (default for Raspberry Pi UART)
SERIAL_PORT=/dev/ttyAMA0
SERIAL_BAUD=115200

# Central Server (same endpoint for all stations)
INGEST_URL=https://your-server.com/api/v1/ingest

# Authentication - EACH STATION NEEDS ITS OWN UNIQUE API KEY!
API_KEY=your-unique-api-key-for-this-station-here

# Data Logging
LOG_TO_FILE=true
LOG_DIR=/data/gnss
```

**Save and exit** (Ctrl+X, Y, Enter)

### Step 3: Run Deployment Script

Make the script executable:

```bash
chmod +x deploy_all.sh
```

Run the deployment:

```bash
sudo ./deploy_all.sh
```

**Follow the prompts**:

1. Confirm deployment: `yes`
2. Start services now: `yes` (recommended)

**Expected output**:

```
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║         StratoCentral Ground Station Deployment           ║
║                                                            ║
║  Automated setup for GNSS monitoring and data collection  ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝

[1/12] Installing system packages...
[2/12] Verifying serial port configuration...
[3/12] Creating directory structure...
[4/12] Setting up Python virtual environment...
[5/12] Installing Python dependencies...
[6/12] Configuring file permissions...
[7/12] Verifying configuration file...
[8/12] Installing combined service...
[9/12] Installing UBX health monitor...
[10/12] Enabling services...
[11/12] Starting services...
[12/12] Running verification checks...

╔════════════════════════════════════════════════════════════╗
║                                                            ║
║                 Deployment Complete!                       ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
```

### Step 4: Verify Deployment

**Check service status**:

```bash
sudo systemctl status combined
sudo systemctl status combined-monitor.timer
```

Both should show **active (running)** or **active (waiting)**.

**View live logs**:

```bash
# Watch combined service logs
sudo journalctl -u combined -f

# You should see:
# INFO - Starting StratoCentral Ground Station...
# INFO - Station: SN_001
# INFO - GNSS reader started
# INFO - Service running
```

**Check monitor logs** (wait ~1 minute for first entry):

```bash
tail -f /data/stratocentral/logs/ubx_monitor.log

# You should see:
# [2025-10-23 HH:MM:SS] UBX errors in last minute: 0
```

**Test serial connection**:

```bash
~/stratonode/venv/bin/python3 ~/stratonode/sender/test_reader.py

# Should show NMEA sentences scrolling
```

---

## Post-Deployment

### Verify in Dashboard

1. Open StratoCentral dashboard in browser
2. Navigate to **Node Management** or **Dashboard**
3. Your station should appear **ONLINE** within 1-2 minutes
4. Check satellite count and fix quality

### Configure ZED-F9P Messages

Your ZED-F9P must output the correct NMEA and UBX messages. See:

```bash
cat ~/stratonode/sender/ZED_F9P_MESSAGE_CONFIG.md
```

**Required messages**:
- NMEA: GGA, RMC, GSA, GSV, VTG (with GN prefix)
- UBX: MON-HW, RXM-RAWX, NAV-SAT, NAV-CLOCK

Use u-blox u-center software to configure these messages.

### Monitor Health

**Daily checks**:

```bash
# Service status
sudo systemctl status combined

# Recent logs
sudo journalctl -u combined -n 100

# Error count
sudo journalctl -u combined -S today | grep -c ERROR

# Monitor log
tail /data/stratocentral/logs/ubx_monitor.log
```

---

## Troubleshooting

### Service Won't Start

```bash
# Check logs
sudo journalctl -u combined -n 50 --no-pager

# Common issues:
# 1. Serial port busy
sudo fuser /dev/ttyAMA0

# 2. Configuration errors
cat ~/stratonode/sender/.env

# 3. Python errors
~/stratonode/venv/bin/python3 ~/stratonode/sender/gnss_combined_service.py
```

### No GNSS Data

```bash
# Test serial port directly
cat /dev/ttyAMA0
# Should see NMEA sentences

# Check permissions
ls -l /dev/ttyAMA0
# Should be: crw-rw---- 1 root dialout

# Verify user in dialout group
groups strato
# Should include: dialout
```

### Node Shows OFFLINE in Dashboard

```bash
# Check network connectivity
ping -c 3 your-server.com

# Verify ingest URL
grep INGEST_URL ~/stratonode/sender/.env

# Test API connection
curl -X POST https://your-server.com/api/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: your-api-key" \
  -d '{"test": true}'
```

### UBX Parser Stuck

If you see repeated "UBX message too large" errors:

```bash
# Check monitor is running
sudo systemctl status combined-monitor.timer

# Monitor should auto-restart within 1 minute
# Check monitor log
tail /data/stratocentral/logs/ubx_monitor.log

# Manual restart
sudo systemctl restart combined
```

---

## Useful Commands

### Service Management

```bash
# Start service
sudo systemctl start combined

# Stop service
sudo systemctl stop combined

# Restart service
sudo systemctl restart combined

# Enable on boot
sudo systemctl enable combined

# Disable from boot
sudo systemctl disable combined

# Check status
sudo systemctl status combined
```

### Log Viewing

```bash
# Live logs (Ctrl+C to exit)
sudo journalctl -u combined -f

# Last 100 lines
sudo journalctl -u combined -n 100

# Today's logs
sudo journalctl -u combined -S today

# Errors only
sudo journalctl -u combined -p err

# Specific time range
sudo journalctl -u combined -S "2025-10-23 10:00" -U "2025-10-23 11:00"
```

### Data Management

```bash
# Check disk usage
df -h /data

# List GNSS log files
ls -lh /data/gnss/

# View monitor log
tail -f /data/stratocentral/logs/ubx_monitor.log

# Archive old logs
cd /data/gnss
tar -czf gnss_logs_$(date +%Y%m%d).tar.gz *.log
```

---

## Redeployment

If you need to redeploy (e.g., after code updates):

```bash
# Stop services
sudo systemctl stop combined
sudo systemctl stop combined-monitor.timer

# Upload new files
cd ~/Documents/GitHub/stratocentral/ground-node-sender
scp * strato@stratonode01:~/stratonode/sender/

# Run deployment (will preserve .env)
ssh strato@stratonode01
cd ~/stratonode/sender
sudo ./deploy_all.sh
```

The deployment script will:
- Detect existing installation
- Preserve your `.env` configuration
- Ask before recreating virtual environment
- Update service files
- Restart services

---

## Uninstallation

To completely remove the ground station:

```bash
# Stop and disable services
sudo systemctl stop combined
sudo systemctl stop combined-monitor.timer
sudo systemctl disable combined
sudo systemctl disable combined-monitor.timer

# Remove service files
sudo rm /etc/systemd/system/combined.service
sudo rm /etc/systemd/system/combined-monitor.service
sudo rm /etc/systemd/system/combined-monitor.timer
sudo rm /etc/sudoers.d/stratocentral-monitor

# Reload systemd
sudo systemctl daemon-reload

# Remove installation
rm -rf ~/stratonode

# Optional: Remove data
sudo rm -rf /data/gnss
sudo rm -rf /data/stratocentral
```

---

## Multiple Ground Stations

To deploy additional ground stations:

1. **Use the same process** but ensure **unique configuration** for each station:
   - Different `STATION_ID` (e.g., SN_002, SN_003) - **MUST BE UNIQUE**
   - Different `API_KEY` - **EACH STATION NEEDS ITS OWN API KEY**
   - Different `KNOWN_LATITUDE`, `KNOWN_LONGITUDE`, `KNOWN_ALTITUDE`
   - Same `INGEST_URL` (central server endpoint)

2. **Copy configuration** from first station as template:
   ```bash
   # On first station
   cat ~/stratonode/sender/.env > station2_config.txt

   # Edit for second station
   nano station2_config.txt
   # MUST CHANGE:
   #   - STATION_ID (e.g., SN_001 → SN_002)
   #   - API_KEY (get unique key for this station from central server)
   #   - KNOWN_LATITUDE, KNOWN_LONGITUDE, KNOWN_ALTITUDE
   #   - STATION_NAME

   # Upload to second station
   scp station2_config.txt strato@stratonode02:~/stratonode/sender/.env
   ```

3. **Deploy on second station**:
   ```bash
   ssh strato@stratonode02
   cd ~/stratonode/sender
   sudo ./deploy_all.sh
   ```

See `SECOND_STATION_SETUP.md` for detailed multi-station deployment guide.

---

## Support

If you encounter issues:

1. **Collect diagnostics**:
   ```bash
   # Save to file
   sudo journalctl -u combined -n 200 > combined_logs.txt
   cat ~/stratonode/sender/.env > config_sanitized.txt  # Remove API_KEY before sharing!
   sudo systemctl status combined > service_status.txt
   ```

2. **Check documentation**:
   - `UBX_DESYNC_FIX.md` - UBX parser issues
   - `ZED_F9P_MESSAGE_CONFIG.md` - GNSS configuration
   - `MONITOR_SERVICE_SETUP.md` - Health monitoring

3. **Common solutions** are usually:
   - Serial port permissions (add user to dialout group, reboot)
   - Wrong `.env` configuration (check STATION_ID, URLs, API keys)
   - ZED-F9P not configured (enable UBX messages)
   - Network issues (check firewall, DNS, connectivity)

---

## Deployment Checklist

Use this checklist for each ground station deployment:

- [ ] Hardware assembled and powered on
- [ ] Raspberry Pi OS installed and updated
- [ ] Serial port enabled via `raspi-config`
- [ ] NVMe drive mounted at `/data` (if using)
- [ ] Network connectivity verified
- [ ] All files uploaded to `~/stratonode/sender/`
- [ ] `.env` configuration edited with unique STATION_ID
- [ ] Known coordinates entered in `.env`
- [ ] API credentials configured in `.env`
- [ ] `deploy_all.sh` executed successfully
- [ ] Services started and running
- [ ] Node appears ONLINE in dashboard
- [ ] GNSS fix obtained (satellite count > 4)
- [ ] UBX health monitor running
- [ ] Data being transmitted to central server
- [ ] ZED-F9P configured with required messages

---

**Date:** 2025-10-23
**Version:** 1.0.0
**Script:** deploy_all.sh v1.0.0
