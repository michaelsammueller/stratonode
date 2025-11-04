# Ground Node Sender

Combined GNSS data logger and network transmission service for StratoCentral ground stations.

## Overview

This service reads GNSS data from a ZED-F9P receiver, logs it to hourly files, and transmits batches to the central-ingest service every second.

**Key Features:**
- Direct serial port access (no multiplexer needed)
- Hourly log rotation with zstd compression and SHA256 checksums  
- Real-time network transmission (1-second batches)
- Guaranteed data consistency (same bytes logged and sent)
- Resilient to restarts and clock drift

## Architecture

```
┌─────────────────────────────────────────┐
│  /dev/ttyAMA0 (ZED-F9P @ 115200 baud)  │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────▼──────────┐
        │  Combined Service   │
        │  (gnss-combined)    │
        └─────┬─────────┬─────┘
              │         │
    ┌─────────▼─┐   ┌──▼─────────────┐
    │ Log Files │   │ Central Server │
    │ (hourly)  │   │ (every 1 sec)  │
    └───────────┘   └────────────────┘
```

## Files

### Core Service
- `gnss_combined_service.py` - Main service combining logging and transmission
- `combined.service` - Systemd service definition
- `gnss_reader.py` - Serial port reader with NMEA/UBX parsing
- `config.py` - Configuration management
- `.env` - Environment variables (not in git)

### Testing
- `test_reader.py` - Test GNSS reader functionality

## Installation

See DEPLOY_CHECKLIST.md for detailed deployment steps.

## Configuration

Create `.env` file in `/home/strato/stratonode/sender/`:
```bash
# Station identification
STATION_ID=SN_POC_01
STATION_NAME=Fusion Technology Office Node

# Central-ingest service
INGEST_URL=https://your-server.com/api/v1/ingest
API_KEY=your-api-key-here

# Antenna position
LATITUDE=25.2632
LONGITUDE=51.5316
ANTENNA_HEIGHT=10.5
IS_REFERENCE_STATION=true

# GNSS device
GNSS_DEVICE=/dev/ttyAMA0
GNSS_BAUD_RATE=115200

# Behavior
SEND_INTERVAL=1
LOG_ROOT_DIR=/data/gnss
```

## Service Management

```bash
# Start service
sudo systemctl start combined

# Check status
sudo systemctl status combined

# View logs
sudo journalctl -u combined -f

# Stop service
sudo systemctl stop combined
```

## Performance

- GNSS data rate: ~2-5 KB/s
- Processing overhead: <15ms per second
- CPU usage: <5% on Raspberry Pi 4

## License

Copyright © 2025 StratoCentral
