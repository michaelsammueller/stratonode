# Second Ground Station Deployment Guide

**StratoCentral Multi-Station Setup**

This guide walks through deploying a **second ground station** to work alongside your existing station. Follow these steps to ensure both stations operate correctly without conflicts.

---

## ⚠️ CRITICAL: Each Station Needs Unique Credentials

**Before you begin, understand this:**

- ✅ Each ground station **MUST** have a unique `STATION_ID`
- ✅ Each ground station **MUST** have a unique `API_KEY`
- ✅ Each ground station **MUST** have unique coordinates (surveyed position)
- ✅ All stations share the same `INGEST_URL` (central server endpoint)

**Why unique API keys?**
- API keys authenticate and authorize each specific ground station
- The central server tracks which station sent which data
- API keys are used for access control and rate limiting per station
- Sharing API keys between stations will cause data attribution issues

**Generate API keys on your central server** before deploying each ground station.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture Overview](#architecture-overview)
3. [File Transfer](#file-transfer)
4. [File Permissions](#file-permissions)
5. [Python Environment Setup](#python-environment-setup)
6. [Configuration for Second Station](#configuration-for-second-station)
7. [Systemd Service Installation](#systemd-service-installation)
8. [Verification Steps](#verification-steps)
9. [Troubleshooting](#troubleshooting)
10. [Station Comparison Checklist](#station-comparison-checklist)
11. [Quick Command Reference](#quick-command-reference)
12. [Monitoring & Maintenance](#monitoring--maintenance)

---

## Prerequisites

### Hardware Requirements

- ✅ Raspberry Pi 4 (4GB+ RAM recommended)
- ✅ u-blox ZED-F9P GNSS receiver
- ✅ USB-to-Serial adapter (or GPIO UART)
- ✅ GNSS antenna with clear sky view
- ✅ Network connectivity to central server

### Software Requirements

- ✅ Raspberry Pi OS (Bullseye or later)
- ✅ Python 3.9+ installed
- ✅ Serial port enabled (`/dev/ttyAMA0`)
- ✅ Internet connection
- ✅ SSH access configured

### System Packages

Install required system packages:

```bash
sudo apt-get update
sudo apt-get install -y \
    python3-venv \
    python3-pip \
    git \
    zstd \
    coreutils
```

### Enable Serial Connections on the Pi
```bash
# Enter config mode
sudo raspi-config
```
Select "Interfaces", then "Serial". When asked if you want the serial console to be accessible via the shell, say 'No'.
When asked if you want to enable serial hardware, say "Yes".


### Verify Serial Port

Check that ZED-F9P is accessible:

```bash
# List serial devices
ls -l /dev/ttyAMA0

# Should show: crw-rw---- 1 root dialout ... /dev/ttyAMA0

# Test raw data output (Ctrl+C to stop)
cat /dev/ttyAMA0
# You should see NMEA sentences scrolling
```

---

## Architecture Overview

### Service Architecture

```
Ground Station #2
    │
    ├─ ZED-F9P (/dev/ttyAMA0 @ 115200 baud)
    │      │
    │      ▼
    ├─ gnss_combined_service.py
    │      ├─ GNSSReader (reads serial port)
    │      ├─ FileLogger (logs to /data/gnss/)
    │      └─ NetworkSender (sends to central server)
    │             │
    │             ▼
    └─ Central Server (receives from both stations)
           ├─ Station #1 (STATION_ID: SN_POC_01)
           └─ Station #2 (STATION_ID: SN_POC_02) ← YOU ARE HERE
```

### Key Difference from Station #1

**The ONLY critical difference between stations is the STATION_ID.**

Everything else (code, service configuration, transmission interval) should be **identical** except for:
- Station ID (must be unique)
- Station name (descriptive)
- Physical location (lat/lon/height)

---

## File Transfer

### Option 1: Git Clone (Recommended)

On the second ground station:

```bash
# Create directory structure
sudo mkdir -p /home/strato/stratonode
cd /home/strato/stratonode

# Clone repository
git clone https://github.com/yourusername/stratocentral.git
cd stratocentral/ground-node-sender
```

### Option 2: Manual Copy via SCP

From your development machine:

```bash
# Copy entire ground-node-sender directory
scp -r /path/to/stratocentral/ground-node-sender/ \
    strato@second-station:/home/strato/stratonode/sender/
```

### Required Files

Ensure these files are present:

```
/home/strato/stratonode/sender/
├── gnss_combined_service.py     ← Main service
├── gnss_reader.py                ← Serial port reader
├── config.py                     ← Configuration management
├── combined.service              ← Systemd unit file
├── requirements.txt              ← Python dependencies
├── .env.example                  ← Configuration template
└── README.md                     ← Documentation
```

---

## File Permissions

### Make Scripts Executable

```bash
cd /home/strato/stratonode/sender

# Main service
chmod +x gnss_combined_service.py

# Optional testing scripts
chmod +x test_reader.py

# Verify permissions
ls -l *.py
```

Expected output:
```
-rwxr-xr-x 1 strato strato 12345 ... gnss_combined_service.py
-rwxr-xr-x 1 strato strato  5678 ... test_reader.py
-rw-r--r-- 1 strato strato  3456 ... gnss_reader.py
-rw-r--r-- 1 strato strato  2345 ... config.py
```

### Create Data Directory

```bash
# Create log storage directory
sudo mkdir -p /data/gnss

# Set ownership (service runs as root but should write as strato)
sudo chown -R strato:strato /data/gnss

# Set permissions
sudo chmod 755 /data/gnss
```

### Serial Port Access

Add user to dialout group for serial port access:

```bash
sudo usermod -aG dialout strato

# Verify group membership
groups strato
# Should include: strato dialout ...

# You may need to log out and back in for group changes to take effect
```

---

## Python Environment Setup

### Create Virtual Environment

```bash
cd /home/strato/stratonode/sender

# Create venv
python3 -m venv ../venv

# Activate venv
source ../venv/bin/activate

# Verify activation
which python3
# Should show: /home/strato/stratonode/venv/bin/python3
```

### Install Dependencies

```bash
# Ensure venv is activated
source /home/strato/stratonode/venv/bin/activate

# Install requirements
pip install --upgrade pip
pip install -r requirements.txt

# Verify installation
pip list
```

Expected packages:
```
Package           Version
----------------- -------
requests          2.31.0
pydantic          2.0.0
pydantic-settings 2.0.0
python-dotenv     1.0.0
pyserial          3.5
```

### Test GNSS Reader

Optional but recommended:

```bash
# Activate venv
source /home/strato/stratonode/venv/bin/activate

# Run test reader (Ctrl+C to stop)
python3 test_reader.py

# You should see NMEA sentences being parsed
```

---

## Configuration for Second Station

### Create .env File

```bash
cd /home/strato/stratonode/sender

# Copy example
cp .env.example .env

# Edit with your station-specific values
nano .env
```

### Critical Configuration Parameters

**⚠️ MUST BE DIFFERENT FROM STATION #1:**

```bash
# === STATION IDENTIFICATION (UNIQUE!) ===
STATION_ID=SN_POC_02                        # ← MUST be different!
STATION_NAME=Second Ground Station          # ← Descriptive name

# === ANTENNA POSITION (MEASURED COORDINATES) ===
LATITUDE=25.2642                            # ← Your actual latitude
LONGITUDE=51.5326                           # ← Your actual longitude
ANTENNA_HEIGHT=12.5                         # ← Your actual height (meters)
IS_REFERENCE_STATION=true                   # ← Same as Station #1
```

**✅ SHOULD BE SAME AS STATION #1:**

```bash
# === CENTRAL SERVER ===
INGEST_URL=https://your-server.com/api/v1/ingest    # ← Same server endpoint

# === GNSS HARDWARE ===
GNSS_DEVICE=/dev/ttyAMA0                    # ← Same hardware
GNSS_BAUD_RATE=115200                       # ← Same baud rate

# === OPERATION ===
SEND_INTERVAL=1                             # ← Same timing (1 second)
LOG_ROOT_DIR=/data/gnss                     # ← Same log location
```

**❗ MUST BE DIFFERENT (UNIQUE API KEY PER STATION):**

```bash
# === AUTHENTICATION ===
API_KEY=station-2-unique-api-key-here       # ← UNIQUE key for this station
```

### Configuration Validation

**Station #1 vs Station #2 Comparison:**

| Parameter | Station #1 | Station #2 | Must Differ? |
|-----------|-----------|-----------|--------------|
| `STATION_ID` | `SN_POC_01` | `SN_POC_02` | ✅ **YES - Must be unique** |
| `API_KEY` | `key_abc123...` | `key_xyz789...` | ✅ **YES - Each station needs unique key** |
| `STATION_NAME` | `First Ground Station` | `Second Ground Station` | ✅ **YES** |
| `LATITUDE` | `25.2632` | `25.2642` | ✅ **YES** |
| `LONGITUDE` | `51.5316` | `51.5326` | ✅ **YES** |
| `ANTENNA_HEIGHT` | `10.5` | `12.5` | ✅ **YES** |
| `INGEST_URL` | `https://...` | `https://...` | ❌ No (same server) |
| `SEND_INTERVAL` | `1` | `1` | ❌ No (same) |
| `GNSS_BAUD_RATE` | `115200` | `115200` | ❌ No (same) |

### Secure .env File

```bash
# Set restrictive permissions
chmod 600 .env

# Verify
ls -l .env
# Should show: -rw------- 1 strato strato ... .env
```

---

## Systemd Service Installation

### Copy Service File

```bash
# Copy to systemd directory
sudo cp /home/strato/stratonode/sender/combined.service \
        /etc/systemd/system/combined.service

# Set permissions
sudo chmod 644 /etc/systemd/system/combined.service

# Verify
ls -l /etc/systemd/system/combined.service
```

### Verify Service File Paths

Check that paths in the service file match your installation:

```bash
sudo nano /etc/systemd/system/combined.service
```

**Verify these paths:**

```ini
[Service]
WorkingDirectory=/home/strato/stratonode/sender
ExecStart=/home/strato/stratonode/venv/bin/python3 \
          /home/strato/stratonode/sender/gnss_combined_service.py
EnvironmentFile=/home/strato/stratonode/sender/.env
```

If paths differ, update them accordingly.

### Enable and Start Service

```bash
# Reload systemd to recognize new service
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable combined

# Start service now
sudo systemctl start combined

# Check status
sudo systemctl status combined
```

Expected status output:
```
● combined.service - StratoCentral Ground Station Combined Service
     Loaded: loaded (/etc/systemd/system/combined.service; enabled; ...)
     Active: active (running) since ...
   Main PID: 1234 (python3)
      Tasks: 3 (limit: 4915)
     Memory: 45.2M
        CPU: 2.345s
     CGroup: /system.slice/combined.service
             └─1234 /home/strato/stratonode/venv/bin/python3 ...

[timestamp] INFO     Starting StratoCentral Ground Station...
[timestamp] INFO     Station: SN_POC_02 (Second Ground Station)
[timestamp] INFO     Serial port: /dev/ttyAMA0 @ 115200 baud
[timestamp] INFO     Logging to: /data/gnss
[timestamp] INFO     Sending to: https://your-server.com/api/v1/ingest
[timestamp] INFO     GNSS reader started
[timestamp] INFO     Service running
```

### Install UBX Health Monitor (Optional but Recommended)

The health monitor automatically restarts the service if the UBX parser gets stuck. This is a safety net for rare serial desynchronization issues.

```bash
# Make monitor script executable
chmod +x /home/strato/stratonode/sender/monitor_ubx_health.sh

# Install systemd service and timer
sudo cp /home/strato/stratonode/sender/combined-monitor.service /etc/systemd/system/
sudo cp /home/strato/stratonode/sender/combined-monitor.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start the monitor timer
sudo systemctl enable combined-monitor.timer
sudo systemctl start combined-monitor.timer

# Verify timer is running
sudo systemctl status combined-monitor.timer
```

Expected output:
```
● combined-monitor.timer - UBX Parser Health Monitor Timer
     Loaded: loaded (/etc/systemd/system/combined-monitor.timer; enabled)
     Active: active (waiting) since ...
    Trigger: [next run time]
```

For complete documentation, see `MONITOR_SERVICE_SETUP.md`.

---

## Verification Steps

### 1. Check Service Status

```bash
# Overall status
sudo systemctl status combined

# Live log output (Ctrl+C to exit)
sudo journalctl -u combined -f

# Recent logs (last 50 lines)
sudo journalctl -u combined -n 50
```

### 2. Verify Serial Port Communication

```bash
# Check if service can read from serial port
sudo journalctl -u combined | grep "GNSS reader"

# Should see:
# INFO     GNSS reader started
# INFO     Reading from /dev/ttyAMA0
```

### 3. Verify Log Files Created

```bash
# Check log directory structure
ls -R /data/gnss/

# Expected structure:
# /data/gnss/
#   └── 2025/
#       └── 01/
#           └── 22/
#               ├── 14.nmea      ← Current hour
#               ├── 14.ubx       ← Current hour
#               ├── 13.nmea.zst  ← Previous hour (compressed)
#               ├── 13.nmea.sha256
#               ├── 13.ubx.zst
#               └── 13.ubx.sha256

# Check file sizes (should be growing)
ls -lh /data/gnss/2025/01/22/
```

### 4. Verify Network Transmission

Check logs for successful HTTP requests:

```bash
# Search for successful transmissions
sudo journalctl -u combined | grep "202 Accepted"

# Should see messages like:
# INFO     Sent batch 123 (15 NMEA, 8 UBX) -> 202 Accepted

# Check for errors
sudo journalctl -u combined | grep -i error
```

### 5. Verify on Central Server

Log into your central server and check that data is arriving:

```bash
# On central server
# Check Redis for new station data
redis-cli XLEN ingest:frames

# Check database for new station
psql -U fusion stratocentral -c \
  "SELECT DISTINCT station_id FROM nodes ORDER BY station_id;"

# Should show both:
# station_id
# ------------
# SN_POC_01
# SN_POC_02
```

### 6. Verify Station Identity

```bash
# Check what station ID the service is using
sudo journalctl -u combined | grep "Station:"

# Should show:
# INFO     Station: SN_POC_02 (Second Ground Station)

# Verify it's NOT using Station #1's ID
sudo journalctl -u combined | grep "SN_POC_01"
# Should return nothing
```

---

## Troubleshooting

### Service Fails to Start

**Symptom:** `systemctl status combined` shows "failed"

**Check:**

```bash
# View detailed error
sudo journalctl -u combined -n 100

# Common issues:
# 1. Python module not found
#    → Verify venv path in service file
#    → Reinstall requirements.txt

# 2. Permission denied on serial port
#    → Add user to dialout group
#    → Verify /dev/ttyAMA0 exists

# 3. .env file not found
#    → Check EnvironmentFile path in service
#    → Verify .env exists in working directory

# 4. Log directory not writable
#    → Check /data/gnss ownership
#    → Run: sudo chown -R strato:strato /data/gnss
```

### Serial Port Permission Denied

**Symptom:** "Permission denied: '/dev/ttyAMA0'"

```bash
# Add user to dialout group
sudo usermod -aG dialout strato

# Log out and back in, or:
newgrp dialout

# Verify group membership
groups
# Should include dialout

# Check device permissions
ls -l /dev/ttyAMA0
# Should show: crw-rw---- 1 root dialout ...

# If not, set permissions:
sudo chmod 660 /dev/ttyAMA0
sudo chown root:dialout /dev/ttyAMA0
```

### Network Connection Failures

**Symptom:** Logs show "Connection refused" or "Connection timeout"

```bash
# Test connectivity to central server
curl -X POST https://your-server.com/api/v1/ingest \
  -H "Authorization: Bearer your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"test": true}'

# Should return: HTTP 400 or 202 (not 401 Unauthorized)

# Check firewall
sudo iptables -L

# Check DNS resolution
ping your-server.com

# Verify API_KEY in .env is correct
grep API_KEY /home/strato/stratonode/sender/.env
```

### Station ID Conflict

**Symptom:** Dashboard shows only one station, or data is mixed

**This is CRITICAL - both stations are using the same ID!**

```bash
# On Station #2, verify unique ID
grep STATION_ID /home/strato/stratonode/sender/.env

# Should show: STATION_ID=SN_POC_02
# NOT: STATION_ID=SN_POC_01

# If wrong, fix it:
nano /home/strato/stratonode/sender/.env
# Change STATION_ID to unique value

# Restart service
sudo systemctl restart combined

# Verify in logs
sudo journalctl -u combined | grep "Station:"
```

### Logs Not Being Created

**Symptom:** `/data/gnss/` directory is empty

```bash
# Check directory ownership
ls -ld /data/gnss/
# Should show: drwxr-xr-x ... strato strato ... /data/gnss

# Check LOG_ROOT_DIR in .env
grep LOG_ROOT_DIR /home/strato/stratonode/sender/.env

# Check service logs for file creation errors
sudo journalctl -u combined | grep -i "log"

# Test write access manually
sudo -u strato touch /data/gnss/test.txt
# Should succeed without errors

# If permission denied:
sudo chown -R strato:strato /data/gnss
sudo chmod 755 /data/gnss
```

### Service Keeps Restarting

**Symptom:** `systemctl status combined` shows multiple restarts

```bash
# Check crash reason
sudo journalctl -u combined | tail -100

# Common causes:
# 1. Invalid .env configuration
#    → Check INGEST_URL format (https://...)
#    → Check LATITUDE/LONGITUDE are numbers

# 2. Serial port disconnected
#    → Check USB connection
#    → Verify /dev/ttyAMA0 exists

# 3. Out of memory
#    → Check system memory: free -h
#    → Reduce SEND_INTERVAL to lower buffering

# 4. Missing Python dependencies
#    → Reinstall: pip install -r requirements.txt
```

### Data Not Appearing in Dashboard

**Symptom:** Service running, but dashboard doesn't show new station

**Check:**

1. **Verify station ID in database:**
   ```bash
   # On central server
   psql -U fusion stratocentral -c \
     "SELECT id, station_id, station_name, status FROM nodes;"
   ```

2. **Check central server ingest logs:**
   ```bash
   # On central server
   sudo journalctl -u stratocentral | grep SN_POC_02
   ```

3. **Verify Redis stream:**
   ```bash
   # On central server
   redis-cli XINFO STREAM ingest:frames
   ```

4. **Check worker is processing:**
   ```bash
   # On central server
   sudo systemctl status centralos-worker
   ```

---

## Station Comparison Checklist

Use this checklist to verify your multi-station setup is correct.

### Configuration Comparison

| Parameter | Station #1 | Station #2 | Status |
|-----------|-----------|-----------|---------|
| **Hardware** |
| Serial Device | `/dev/ttyAMA0` | `/dev/ttyAMA0` | ✅ Same |
| Baud Rate | `115200` | `115200` | ✅ Same |
| GNSS Model | ZED-F9P | ZED-F9P | ✅ Same |
| **Identity** |
| Station ID | `SN_POC_01` | `SN_POC_02` | ⚠️ **Must differ** |
| Station Name | `[Name 1]` | `[Name 2]` | ⚠️ **Should differ** |
| **Location** |
| Latitude | `[Lat 1]` | `[Lat 2]` | ⚠️ **Must differ** |
| Longitude | `[Lon 1]` | `[Lon 2]` | ⚠️ **Must differ** |
| Height | `[Height 1]` | `[Height 2]` | ⚠️ **Should differ** |
| **Network** |
| Ingest URL | `https://...` | `https://...` | ✅ Same |
| API Key | `xyz123...` | `xyz123...` | ✅ Same |
| Send Interval | `1` | `1` | ✅ Same |
| **Service** |
| Service Name | `combined` | `combined` | ✅ Same |
| Service File | `/etc/systemd/system/combined.service` | `/etc/systemd/system/combined.service` | ✅ Same |
| Working Dir | `/home/strato/stratonode/sender` | `/home/strato/stratonode/sender` | ✅ Same |
| Log Directory | `/data/gnss` | `/data/gnss` | ✅ Same |

### Verification Commands

Run these on **both stations** and compare results:

```bash
# 1. Check service status
systemctl is-active combined
# Both should return: active

# 2. Check station ID
grep STATION_ID /home/strato/stratonode/sender/.env
# Station #1: STATION_ID=SN_POC_01
# Station #2: STATION_ID=SN_POC_02

# 3. Check central server URL
grep INGEST_URL /home/strato/stratonode/sender/.env
# Both should return: INGEST_URL=https://[same-server]

# 4. Check log activity
ls -lh /data/gnss/2025/01/22/ | head -5
# Both should show recent files
```

---

## Quick Command Reference

### Copy-Paste Deployment

Complete deployment in one session:

```bash
# === STEP 1: PREPARE SYSTEM ===
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip git zstd
sudo mkdir -p /home/strato/stratonode /data/gnss
sudo chown -R strato:strato /home/strato/stratonode /data/gnss
sudo usermod -aG dialout strato

# === STEP 2: COPY FILES ===
cd /home/strato/stratonode
git clone https://github.com/yourusername/stratocentral.git
cd stratocentral/ground-node-sender

# === STEP 3: SETUP PYTHON ===
python3 -m venv ../../venv
source ../../venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# === STEP 4: CONFIGURE ===
cp .env.example .env
nano .env
# Edit: STATION_ID, STATION_NAME, LAT/LON/HEIGHT
chmod 600 .env

# === STEP 5: SET PERMISSIONS ===
chmod +x gnss_combined_service.py test_reader.py

# === STEP 6: INSTALL SERVICE ===
sudo cp combined.service /etc/systemd/system/
sudo chmod 644 /etc/systemd/system/combined.service
sudo systemctl daemon-reload
sudo systemctl enable combined
sudo systemctl start combined

# === STEP 7: VERIFY ===
sudo systemctl status combined
sudo journalctl -u combined -f
```

### Daily Operations

```bash
# Check service status
sudo systemctl status combined

# View live logs
sudo journalctl -u combined -f

# Restart service
sudo systemctl restart combined

# Stop service
sudo systemctl stop combined

# Start service
sudo systemctl start combined

# Check today's logs
ls -lh /data/gnss/$(date +%Y/%m/%d)/

# Check disk usage
du -sh /data/gnss/
```

### Troubleshooting Commands

```bash
# Check last 100 log lines
sudo journalctl -u combined -n 100

# Check for errors
sudo journalctl -u combined | grep -i error

# Test serial port
cat /dev/ttyAMA0

# Test network connectivity
curl -v https://your-server.com/api/v1/health

# Verify configuration
cat /home/strato/stratonode/sender/.env | grep -v "^#"

# Check Python environment
source /home/strato/stratonode/venv/bin/activate
pip list

# Test GNSS reader manually
cd /home/strato/stratonode/sender
source ../venv/bin/activate
python3 test_reader.py
```

---

## Monitoring & Maintenance

### Health Checks

**Daily:**
```bash
# Check service is running
systemctl is-active combined

# Check disk space
df -h /data/

# View transmission success rate
sudo journalctl -u combined -S today | grep "202 Accepted" | wc -l
```

**Weekly:**
```bash
# Check log file sizes
du -sh /data/gnss/

# Review error logs
sudo journalctl -u combined -S "1 week ago" | grep -i error

# Verify data on central server
# (Check dashboard shows both stations)
```

### Log Rotation

Logs are automatically compressed hourly by the service:

```bash
# Current hour: .nmea and .ubx (uncompressed)
# Previous hours: .nmea.zst and .ubx.zst (compressed)

# Verify compression is working
ls -lh /data/gnss/$(date +%Y/%m/%d)/ | grep zst

# Manually compress if needed
zstd /data/gnss/2025/01/22/14.nmea
```

### Update Configuration

To change configuration without reinstalling:

```bash
# Edit .env
nano /home/strato/stratonode/sender/.env

# Restart service to apply
sudo systemctl restart combined

# Verify new config loaded
sudo journalctl -u combined -n 50 | grep "Station:"
```

### Software Updates

To update the ground station software:

```bash
cd /home/strato/stratonode/stratocentral
git pull origin main

# Reinstall dependencies if requirements.txt changed
source /home/strato/stratonode/venv/bin/activate
pip install -r ground-node-sender/requirements.txt

# Restart service
sudo systemctl restart combined
```

### Backup Considerations

**What to backup:**
- Configuration: `/home/strato/stratonode/sender/.env`
- Service file: `/etc/systemd/system/combined.service`
- GNSS logs: `/data/gnss/` (optional, already sent to central server)

**Backup command:**
```bash
# Backup configuration
sudo tar -czf /home/strato/backup-$(date +%Y%m%d).tar.gz \
    /home/strato/stratonode/sender/.env \
    /etc/systemd/system/combined.service

# Copy to safe location
scp /home/strato/backup-*.tar.gz user@backup-server:/backups/
```

### Monitoring from Central Server

On the central server, monitor both stations:

```bash
# Check nodes in database
psql -U fusion stratocentral -c \
  "SELECT station_id, station_name, status, last_seen
   FROM nodes
   ORDER BY station_id;"

# Should show both stations with recent last_seen timestamps

# Check Redis stream activity
redis-cli XINFO STREAM ingest:frames

# Check worker is processing both stations
sudo journalctl -u centralos-worker -S today | grep SN_POC
```

---

## Next Steps

After successfully deploying Station #2:

1. **Verify Dashboard**: Check that both stations appear in the StratoCentral dashboard
2. **Test GPS Analysis**: Navigate to GPS Analysis page and verify data from both stations
3. **Configure Algorithms**: If using differential algorithms, ensure both stations are configured correctly
4. **Deploy Station #3**: Use this same guide to deploy additional stations (just change STATION_ID to SN_POC_03, etc.)

---

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section above
2. Review logs: `sudo journalctl -u combined -f`
3. Check main documentation: `README.md` and `DEPLOY_CHECKLIST.md`
4. Verify configuration: Compare `.env` with `.env.example`

---

**Congratulations!** You now have a multi-station StratoCentral deployment. Both ground stations are sending data to the central server for real-time GNSS monitoring and threat detection.
