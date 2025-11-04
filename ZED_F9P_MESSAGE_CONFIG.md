# ZED-F9P Required Message Configuration

**StratoCentral GNSS Message Requirements**

This document specifies which NMEA and UBX messages must be enabled on your u-blox ZED-F9P GNSS receiver for StratoCentral's detection algorithms to function correctly.

---

## Overview

StratoCentral uses a multi-tier algorithm architecture:
- **NMEA Tier**: Basic position/signal analysis from NMEA sentences
- **UBX Tier**: Advanced spoofing/jamming detection from UBX binary messages

Both message types are required for full protection coverage.

---

## Required NMEA Messages

Enable the following NMEA sentences for **multi-constellation output** (GN prefix):

### 1. GGA - Global Positioning System Fix Data
**Purpose**: Position, altitude, fix quality, satellite count

**Used by**:
- `StationLocationValidator` - Validates position against known surveyed location
- `StationAltitudeValidator` - Validates altitude consistency
- `ConsensusValidator` - Cross-station position comparison
- `NetworkSignalShield` - Position-based spoofing detection
- `StationHealthMonitor` - Overall station health

**Message ID**: `GGA` (enable as `GNGGA` for multi-constellation)

**Example**:
```
$GNGGA,174416.00,2522.36365,N,05133.47395,E,1,12,0.68,56.5,M,-24.6,M,,*5F
```

**Key Fields**:
- Position (lat/lon)
- Altitude
- Fix quality (0=invalid, 1=GPS, 2=DGPS, 4=RTK Fixed, 5=RTK Float)
- Number of satellites
- HDOP (Horizontal Dilution of Precision)

---

### 2. RMC - Recommended Minimum Navigation Information
**Purpose**: Position, speed, date/time validation

**Used by**:
- `NetworkTimeSync` - Time synchronization validation
- `StationHealthMonitor` - Speed and status monitoring
- `ConsensusValidator` - Time correlation across stations

**Message ID**: `RMC` (enable as `GNRMC` for multi-constellation)

**Example**:
```
$GNRMC,174416.00,A,2522.36365,N,05133.47395,E,0.052,,181025,,,A,V*17
```

**Key Fields**:
- Position (lat/lon)
- Speed over ground
- Date and time (UTC)
- Status (A=active, V=void)

---

### 3. GSA - GPS DOP and Active Satellites
**Purpose**: Dilution of Precision (DOP) values, fix type

**Used by**:
- `StationHealthMonitor` - Signal quality assessment
- `ConsensusValidator` - DOP-based quality filtering

**Message ID**: `GSA` (enable as `GNGSA` for multi-constellation)

**Example**:
```
$GNGSA,A,3,10,12,14,15,18,21,24,25,26,32,,,1.01,0.68,0.75,1*00
```

**Key Fields**:
- Fix type (1=no fix, 2=2D, 3=3D)
- PDOP (Position DOP)
- HDOP (Horizontal DOP)
- VDOP (Vertical DOP)

---

### 4. GSV - Satellites in View
**Purpose**: Satellite visibility, signal strength

**Used by**:
- `NetworkJammingDetector` - Satellite visibility patterns
- `StationHealthMonitor` - Signal strength monitoring

**Message ID**: `GSV` (enable as `GNGSV` for multi-constellation)

**Example**:
```
$GNGSV,3,1,12,10,45,120,42,12,38,215,40,14,25,310,38,15,65,045,45*6A
```

**Key Fields**:
- Number of satellites in view
- Per-satellite: PRN, elevation, azimuth, SNR

---

### 5. VTG - Track Made Good and Ground Speed
**Purpose**: Course and speed information

**Used by**:
- `StationHealthMonitor` - Speed validation (should be ~0 for fixed stations)

**Message ID**: `VTG` (enable as `GNVTG` for multi-constellation)

**Example**:
```
$GNVTG,,T,,M,0.052,N,0.097,K,A*37
```

**Key Fields**:
- Course over ground
- Speed (knots and km/h)

---

## Required UBX Messages

Enable the following UBX binary messages:

### 1. UBX-MON-HW (Class 0x0A, ID 0x09)
**Purpose**: Hardware status monitoring, AGC levels, jamming indicators

**Used by**:
- `AGCMonitor` - Primary jamming detection via AGC analysis

**Output Rate**: 1 Hz recommended

**Key Fields**:
- `agcCnt` - AGC monitor value (0-8191)
  - Higher values = more gain = weaker signals
  - Sudden drops indicate strong interference/jamming
- `jamInd` - Jamming indicator (0=unknown, 1=ok, 2=warning, 3=critical)
- `flags` - Status flags including CW jamming detection

**Why Critical**: Hardware-level jamming detection is the most authoritative indicator. AGC patterns are very difficult for attackers to manipulate.

---

### 2. UBX-RXM-RAWX (Class 0x02, ID 0x15)
**Purpose**: Raw GNSS measurements per satellite

**Used by**:
- `DopplerValidator` - Doppler shift consistency validation
- `CarrierPhaseValidator` - Carrier phase continuity analysis
- `CNRAnalyzer` - Signal-to-noise ratio patterns
- `PseudorangePhaseChecker` - Pseudorange consistency
- `MultiFrequencyValidator` - Multi-band signal validation

**Output Rate**: 1 Hz recommended (can be reduced to 0.5 Hz to save bandwidth)

**Key Fields Per Satellite**:
- `svId` - Satellite ID
- `prMes` - Pseudorange measurement (meters)
- `cpMes` - Carrier phase measurement (cycles)
- `doMes` - Doppler frequency (Hz)
- `cno` - Carrier-to-noise ratio (dB-Hz)
- `locktime` - Carrier tracking lock time

**Why Critical**: Provides raw measurements that are extremely difficult for spoofers to replicate accurately. Carrier phase is nearly impossible to spoof correctly across multiple stations.

**Warning**: This is the largest message. Each satellite adds ~32 bytes. With 12 satellites, expect ~400 bytes per message.

---

### 3. UBX-NAV-SAT (Class 0x01, ID 0x35)
**Purpose**: Satellite information (signal quality, geometry)

**Used by**:
- `CNRAnalyzer` - Alternative to RAWX for C/N0 analysis

**Output Rate**: 1 Hz recommended

**Key Fields Per Satellite**:
- `svId` - Satellite ID
- `cno` - Carrier-to-noise ratio (dB-Hz)
- `elev` - Elevation angle (degrees)
- `azim` - Azimuth angle (degrees)
- `flags` - Quality indicators, health status

**Note**: Can be used as a lighter alternative to RAWX if only C/N0 analysis is needed, but RAWX is preferred for full algorithm coverage.

---

### 4. UBX-NAV-CLOCK (Class 0x01, ID 0x22)
**Purpose**: Receiver clock bias and drift

**Used by**:
- `ClockDriftValidator` - Clock behavior analysis for spoofing detection

**Output Rate**: 1 Hz recommended

**Key Fields**:
- `clkB` - Clock bias (nanoseconds)
- `clkD` - Clock drift (nanoseconds/second)

**Why Critical**: Each receiver has unique clock characteristics. Spoofing causes the victim's clock to track the spoofed time, creating detectable anomalies.

---

## Configuration Priority

If you need to minimize bandwidth, prioritize messages in this order:

### Essential (Required for core functionality):
1. **NMEA-GGA** - Position and fix quality
2. **NMEA-RMC** - Time and date
3. **UBX-RXM-RAWX** - Raw measurements (enables most UBX algorithms)
4. **UBX-MON-HW** - AGC and jamming indicators

### Important (Significantly enhances detection):
5. **NMEA-GSA** - DOP values
6. **UBX-NAV-CLOCK** - Clock drift analysis
7. **NMEA-GSV** - Satellite visibility

### Useful (Additional validation):
8. **UBX-NAV-SAT** - Satellite signal quality (if not using RAWX)
9. **NMEA-VTG** - Speed validation

---

## Message Output Rates

Recommended output rates for optimal detection performance:

| Message | Recommended Rate | Minimum Rate | Notes |
|---------|-----------------|--------------|-------|
| NMEA-GGA | 1 Hz | 1 Hz | Core position data |
| NMEA-RMC | 1 Hz | 1 Hz | Core time data |
| NMEA-GSA | 1 Hz | 0.5 Hz | Can reduce if needed |
| NMEA-GSV | 1 Hz | 0.5 Hz | Can reduce if needed |
| NMEA-VTG | 1 Hz | 0.2 Hz | Low priority |
| UBX-MON-HW | 1 Hz | 1 Hz | Critical for jamming |
| UBX-RXM-RAWX | 1 Hz | 0.5 Hz | Large message |
| UBX-NAV-SAT | 1 Hz | 0.5 Hz | Alternative to RAWX |
| UBX-NAV-CLOCK | 1 Hz | 0.5 Hz | Clock analysis |

---

## Configuration Methods

### Method 1: u-center Configuration Tool (Recommended)

**For Windows/macOS**:

1. Connect ZED-F9P to computer via USB
2. Open u-blox u-center software
3. Connect to receiver (Receiver → Connection → COM port)

**Enable NMEA Messages**:
1. View → Messages View
2. Navigate to UBX → CFG → PRT (Ports)
3. Select UART1 (serial port connected to Raspberry Pi)
4. Under "Protocol out", enable NMEA
5. Click "Send" to apply

6. Navigate to UBX → CFG → MSG (Messages)
7. For each NMEA message:
   - Select message type (e.g., NMEA-GN-GGA)
   - Set output rate on UART1 (1 = every epoch)
   - Click "Send"

**Enable UBX Messages**:
1. Still in UBX → CFG → MSG (Messages)
2. For each UBX message:
   - Select message (e.g., UBX → MON → HW)
   - Set output rate on UART1 (1 = every epoch)
   - Click "Send"

**Save Configuration**:
1. Navigate to UBX → CFG → CFG (Configuration)
2. Select "Save current configuration"
3. Check: "Devices: BBR, FLASH, I2C-EEPROM, SPI-FLASH"
4. Click "Send"

---

### Method 2: UBX Configuration Commands (Advanced)

If using u-center is not possible, you can send UBX commands via serial:

**Example: Enable UBX-MON-HW at 1 Hz on UART1**:
```
UBX-CFG-MSG: 0x0A 0x09 (MON-HW)
Payload: 00 00 00 01 00 00 00 00
         (No I2C, No USB, No UART2, 1x UART1, ...)
```

**Example: Enable NMEA-GN-GGA at 1 Hz on UART1**:
```
UBX-CFG-MSG: 0xF0 0x00 (NMEA-GGA)
Payload: 00 00 00 01 00 00 00 00
```

Refer to the ZED-F9P Interface Description for complete command format.

---

### Method 3: PyUBX2 Configuration Script (Coming Soon)

A Python script to automatically configure the ZED-F9P will be added to this repository.

---

## Verification

### Check NMEA Output

On your ground station Raspberry Pi:

```bash
# View raw serial output (Ctrl+C to stop)
cat /dev/ttyAMA0

# You should see NMEA sentences scrolling:
# $GNGGA,...
# $GNRMC,...
# $GNGSA,...
# $GNGSV,...
# $GNVTG,...
```

### Check UBX Output

UBX messages are binary, so you won't see readable text. To verify:

```bash
# Check for UBX sync bytes (0xB5 0x62)
od -A x -t x1 /dev/ttyAMA0 | head -50

# You should see patterns like:
# b5 62 0a 09 ... (MON-HW)
# b5 62 02 15 ... (RXM-RAWX)
# b5 62 01 35 ... (NAV-SAT)
# b5 62 01 22 ... (NAV-CLOCK)
```

### Check Service Logs

After configuring the ZED-F9P:

```bash
# Monitor the combined service
sudo journalctl -u combined -f

# You should see:
# INFO - Parsed UBX-MON-HW
# INFO - Parsed UBX-RXM-RAWX
# INFO - Parsed NMEA: GGA, RMC, GSA, GSV, VTG
```

---

## Bandwidth Considerations

### Typical Message Sizes (at 1 Hz):

| Message Type | Size (bytes) | Bandwidth (bps @ 1Hz) |
|--------------|--------------|------------------------|
| NMEA-GGA | ~80 | 640 |
| NMEA-RMC | ~75 | 600 |
| NMEA-GSA | ~70 | 560 |
| NMEA-GSV (4 msgs) | ~280 | 2,240 |
| NMEA-VTG | ~50 | 400 |
| UBX-MON-HW | ~68 | 544 |
| UBX-RXM-RAWX (12 sats) | ~400 | 3,200 |
| UBX-NAV-SAT (12 sats) | ~264 | 2,112 |
| UBX-NAV-CLOCK | ~28 | 224 |
| **TOTAL** | ~1,315 | **10,520 bps** |

**Serial Connection**: 115200 baud = 115,200 bps
**Utilization**: ~9% at 1 Hz (plenty of headroom)

---

## Multi-Constellation Support

The ZED-F9P supports multiple GNSS constellations:
- GPS (USA)
- GLONASS (Russia)
- Galileo (Europe)
- BeiDou (China)

**Recommendation**: Enable all constellations for maximum satellite visibility and best spoofing/jamming detection.

This is why we use **GN** prefix (multi-GNSS) instead of **GP** (GPS only):
- `GNGGA` instead of `GPGGA`
- `GNRMC` instead of `GPRMC`
- etc.

**Configuration in u-center**:
1. UBX → CFG → GNSS
2. Enable: GPS, GLONASS, Galileo, BeiDou
3. Click "Send"
4. Save configuration (CFG-CFG)

---

## Troubleshooting

### No NMEA Output

**Symptoms**: No `$GN...` sentences in serial output

**Solutions**:
1. Check NMEA protocol is enabled on UART1 in CFG-PRT
2. Verify message rates in CFG-MSG
3. Check baud rate matches (115200 default)
4. Verify serial port wiring (TX/RX not swapped)

### No UBX Output

**Symptoms**: No `0xB5 0x62` sync bytes in serial output

**Solutions**:
1. Check UBX protocol is enabled on UART1 in CFG-PRT
2. Verify UBX message rates in CFG-MSG
3. Use u-center to confirm messages are enabled

### Service Not Parsing Messages

**Symptoms**: Service running but no messages logged

**Solutions**:
```bash
# Check serial port permissions
ls -l /dev/ttyAMA0
# Should show: crw-rw---- 1 root dialout

# Check if another process is using the port
sudo fuser /dev/ttyAMA0

# Monitor raw serial output
cat /dev/ttyAMA0

# Check service logs for errors
sudo journalctl -u combined -n 100
```

### Algorithm Warnings

**Symptoms**: Logs show "No UBX data provided" or "Missing RAWX measurements"

**Cause**: Required UBX messages not enabled on ZED-F9P

**Solution**: Enable the specific UBX messages mentioned in this document

---

## Algorithm-Specific Requirements Summary

### NMEA-Tier Algorithms (Require NMEA sentences only):

| Algorithm | Required Messages | Optional Messages |
|-----------|-------------------|-------------------|
| StationLocationValidator | GGA | RMC |
| StationAltitudeValidator | GGA | - |
| NetworkTimeSync | RMC | GGA |
| ConsensusValidator | GGA, RMC, GSA | GSV |
| NetworkSignalShield | GGA, RMC | GSA, GSV |
| StationHealthMonitor | GGA, RMC | GSA, GSV, VTG |
| NetworkJammingDetector | GGA, GSV | GSA |

### UBX-Tier Algorithms (Require UBX messages):

| Algorithm | Required Messages | Optional Messages |
|-----------|-------------------|-------------------|
| AGCMonitor | MON-HW | - |
| DopplerValidator | RXM-RAWX | - |
| CarrierPhaseValidator | RXM-RAWX | - |
| CNRAnalyzer | RXM-RAWX or NAV-SAT | - |
| PseudorangePhaseChecker | RXM-RAWX | - |
| MultiFrequencyValidator | RXM-RAWX | - |
| ClockDriftValidator | NAV-CLOCK | - |
| EphemerisValidator | RXM-RAWX | - |

---

## Configuration Checklist

Use this checklist to verify your ZED-F9P is configured correctly:

- [ ] **NMEA Messages Enabled**:
  - [ ] GNGGA at 1 Hz on UART1
  - [ ] GNRMC at 1 Hz on UART1
  - [ ] GNGSA at 1 Hz on UART1
  - [ ] GNGSV at 1 Hz on UART1
  - [ ] GNVTG at 1 Hz on UART1

- [ ] **UBX Messages Enabled**:
  - [ ] UBX-MON-HW at 1 Hz on UART1
  - [ ] UBX-RXM-RAWX at 1 Hz on UART1
  - [ ] UBX-NAV-SAT at 1 Hz on UART1
  - [ ] UBX-NAV-CLOCK at 1 Hz on UART1

- [ ] **Multi-Constellation Enabled**:
  - [ ] GPS enabled
  - [ ] GLONASS enabled
  - [ ] Galileo enabled
  - [ ] BeiDou enabled

- [ ] **Configuration Saved**:
  - [ ] Configuration saved to flash (CFG-CFG)
  - [ ] Receiver rebooted to verify persistence

- [ ] **Verification**:
  - [ ] NMEA sentences visible in serial output
  - [ ] UBX sync bytes visible in serial output
  - [ ] Ground station service parsing messages
  - [ ] No "missing data" warnings in logs

---

## Reference Documents

- [ZED-F9P Interface Description](https://www.u-blox.com/en/docs/UBX-18010854) - Complete UBX protocol specification
- [ZED-F9P Integration Manual](https://www.u-blox.com/en/docs/UBX-18010802) - Hardware integration guide
- [NMEA-0183 Standard](https://www.nmea.org/nmea-0183.html) - NMEA sentence specifications

---

## Support

If you're having trouble configuring your ZED-F9P:

1. **Check receiver firmware version**:
   - Use u-center: View → Packet Console
   - Send UBX-MON-VER
   - Recommended: Firmware HPG 1.13 or later

2. **Factory reset** (if configuration is corrupted):
   - In u-center: UBX → CFG → CFG
   - Select "Revert to default configuration"
   - Click "Send"
   - Reconfigure from scratch

3. **Contact support** with:
   - Firmware version
   - u-center configuration export (.txt file)
   - Service logs: `sudo journalctl -u combined -n 200`

---

**Date:** 2025-10-23
**Version:** 1.0
**Author:** StratoCentral Development Team
**Applies to**: u-blox ZED-F9P receivers (all versions)
