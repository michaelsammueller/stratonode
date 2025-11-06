#!/usr/bin/env python3
"""
Monitor ZED-F9P Output Stream

Listens to the receiver's data stream and reports what messages are being sent.
This is more reliable than polling because it works even when the receiver
is continuously streaming data.
"""

import sys
import time
import serial
import struct
from collections import defaultdict
from datetime import datetime

# UBX Protocol Constants
UBX_SYNC_1 = 0xB5
UBX_SYNC_2 = 0x62

# Message name mappings
UBX_MESSAGES = {
    # MON messages
    (0x0A, 0x09): "UBX-MON-HW (Hardware status - CRITICAL)",
    (0x0A, 0x0B): "UBX-MON-HW2 (Extended hardware)",
    (0x0A, 0x04): "UBX-MON-VER (Version)",
    (0x0A, 0x28): "UBX-MON-RF (RF information)",

    # NAV messages
    (0x01, 0x35): "UBX-NAV-SAT (Satellite info)",
    (0x01, 0x22): "UBX-NAV-CLOCK (Clock - CRITICAL)",
    (0x01, 0x07): "UBX-NAV-PVT (Position velocity time)",
    (0x01, 0x21): "UBX-NAV-TIMEUTC (UTC time)",
    (0x01, 0x20): "UBX-NAV-TIMEGPS (GPS time)",
    (0x01, 0x04): "UBX-NAV-DOP (Dilution of precision)",

    # RXM messages
    (0x02, 0x15): "UBX-RXM-RAWX (Raw measurements - CRITICAL)",
    (0x02, 0x13): "UBX-RXM-SFRBX (Broadcast nav data)",
    (0x02, 0x59): "UBX-RXM-MEASX (Measurements)",

    # CFG messages (responses)
    (0x06, 0x01): "UBX-CFG-MSG (Message config response)",
    (0x06, 0x00): "UBX-CFG-PRT (Port config response)",
}

NMEA_TALKERS = {
    'GN': 'Multi-GNSS (GPS+GLONASS+Galileo+BeiDou)',
    'GP': 'GPS only',
    'GL': 'GLONASS only',
    'GA': 'Galileo only',
    'GB': 'BeiDou only',
}

NMEA_SENTENCES = {
    'GGA': 'Global Positioning Fix Data',
    'RMC': 'Recommended Minimum Navigation',
    'GSA': 'DOP and Active Satellites',
    'GSV': 'Satellites in View',
    'VTG': 'Course and Speed',
    'GLL': 'Geographic Position',
    'GST': 'Pseudorange Error Statistics',
    'ZDA': 'Time and Date',
    'GBS': 'GNSS Satellite Fault Detection',
    'GNS': 'GNSS Fix Data',
    'VLW': 'Dual Ground/Water Distance',
}


class StreamMonitor:
    def __init__(self, device: str, baudrate: int, duration: int = 10):
        self.device = device
        self.baudrate = baudrate
        self.duration = duration

        self.nmea_counts = defaultdict(int)
        self.ubx_counts = defaultdict(int)
        self.ubx_sizes = defaultdict(list)

        self.buffer = bytearray()
        self.nmea_buffer = bytearray()

    def parse_nmea(self, line: bytes):
        """Parse and count NMEA sentence"""
        try:
            line_str = line.decode('ascii', errors='ignore').strip()
            if line_str.startswith('$'):
                # Extract talker and sentence type
                # Format: $GNGGA,... or $GPGGA,...
                parts = line_str[1:].split(',')
                if parts:
                    msg_id = parts[0]
                    if len(msg_id) >= 5:
                        talker = msg_id[:2]
                        sentence = msg_id[2:]
                        self.nmea_counts[(talker, sentence)] += 1
        except Exception:
            pass

    def parse_ubx(self, data: bytes):
        """Parse and count UBX message"""
        if len(data) < 8:
            return

        msg_class = data[2]
        msg_id = data[3]
        length = struct.unpack('<H', data[4:6])[0]

        self.ubx_counts[(msg_class, msg_id)] += 1
        self.ubx_sizes[(msg_class, msg_id)].append(length + 8)  # Total message size

    def process_data(self, data: bytes):
        """Process incoming serial data"""
        self.buffer.extend(data)

        i = 0
        while i < len(self.buffer):
            # Look for UBX sync bytes
            if i < len(self.buffer) - 1 and self.buffer[i] == UBX_SYNC_1 and self.buffer[i+1] == UBX_SYNC_2:
                # Found UBX message
                if i + 6 <= len(self.buffer):
                    length = struct.unpack('<H', self.buffer[i+4:i+6])[0]
                    total_size = 6 + length + 2

                    if i + total_size <= len(self.buffer):
                        # Complete UBX message
                        ubx_msg = bytes(self.buffer[i:i+total_size])
                        self.parse_ubx(ubx_msg)
                        i += total_size
                        continue

                # Incomplete UBX message, wait for more data
                break

            # Look for NMEA sentences
            if self.buffer[i] == ord('$'):
                # Look for end of line
                end = self.buffer.find(b'\n', i)
                if end != -1:
                    nmea_line = bytes(self.buffer[i:end])
                    self.parse_nmea(nmea_line)
                    i = end + 1
                    continue
                else:
                    # Incomplete NMEA, wait for more data
                    break

            # Skip byte
            i += 1

        # Keep remaining data
        self.buffer = self.buffer[i:]

    def monitor(self):
        """Monitor the serial stream"""
        print(f"Monitoring {self.device} @ {self.baudrate} baud for {self.duration} seconds...")
        print("=" * 80)
        print()

        try:
            ser = serial.Serial(self.device, self.baudrate, timeout=0.1)

            start_time = time.time()
            last_update = start_time

            while time.time() - start_time < self.duration:
                if ser.in_waiting > 0:
                    data = ser.read(ser.in_waiting)
                    self.process_data(data)

                # Progress indicator
                elapsed = time.time() - start_time
                if time.time() - last_update > 1.0:
                    print(f"\rMonitoring... {elapsed:.0f}/{self.duration}s", end='', flush=True)
                    last_update = time.time()

                time.sleep(0.01)

            print(f"\rMonitoring complete: {self.duration} seconds")
            print()

            ser.close()

            self.display_results()

        except serial.SerialException as e:
            print(f"Error: Could not open {self.device}")
            print(f"Details: {e}")
            print()
            print("Make sure:")
            print("  1. The combined service is stopped: sudo systemctl stop combined")
            print("  2. You have permission: sudo usermod -a -G dialout $USER")
            print("  3. The port exists: ls -l /dev/ttyAMA0")
            sys.exit(1)

    def display_results(self):
        """Display monitoring results"""
        print()
        print("=" * 80)
        print("NMEA Messages Detected:")
        print("=" * 80)

        if self.nmea_counts:
            print(f"{'Message':<30} {'Count':<10} {'Rate (Hz)':<12} {'Constellation'}")
            print("-" * 80)

            critical_nmea = {'GGA', 'RMC', 'GSA', 'GSV', 'VTG'}

            for (talker, sentence), count in sorted(self.nmea_counts.items()):
                rate = count / self.duration
                constellation = NMEA_TALKERS.get(talker, 'Unknown')
                sentence_desc = NMEA_SENTENCES.get(sentence, 'Unknown')

                status = "✓" if sentence in critical_nmea else " "

                msg_name = f"{status} {talker}{sentence} ({sentence_desc})"
                print(f"{msg_name:<30} {count:<10} {rate:>6.2f} Hz    {constellation}")

            print()
            print("Note: ✓ indicates messages required by StratoCentral")
        else:
            print("⚠️  No NMEA messages detected!")
            print()

        print()
        print("=" * 80)
        print("UBX Messages Detected:")
        print("=" * 80)

        if self.ubx_counts:
            print(f"{'Message':<50} {'Count':<10} {'Rate (Hz)':<12} {'Avg Size'}")
            print("-" * 80)

            for (msg_class, msg_id), count in sorted(self.ubx_counts.items()):
                rate = count / self.duration
                avg_size = sum(self.ubx_sizes[(msg_class, msg_id)]) / len(self.ubx_sizes[(msg_class, msg_id)])
                max_size = max(self.ubx_sizes[(msg_class, msg_id)])

                msg_name = UBX_MESSAGES.get((msg_class, msg_id), f"UBX-{msg_class:02X}-{msg_id:02X} (Unknown)")

                print(f"{msg_name:<50} {count:<10} {rate:>6.2f} Hz    {avg_size:>6.0f}B (max {max_size}B)")

            print()
        else:
            print("⚠️  No UBX messages detected!")
            print()

        print()
        print("=" * 80)
        print("Configuration Assessment:")
        print("=" * 80)

        # Check critical messages
        critical_ok = True

        # Check NMEA
        required_nmea = [('GN', 'GGA'), ('GN', 'RMC'), ('GN', 'GSA'), ('GN', 'GSV')]
        missing_nmea = []

        for talker, sentence in required_nmea:
            if (talker, sentence) not in self.nmea_counts:
                missing_nmea.append(f"{talker}{sentence}")
                critical_ok = False

        # Check UBX
        required_ubx = [
            (0x0A, 0x09),  # MON-HW
            (0x02, 0x15),  # RXM-RAWX
        ]
        missing_ubx = []

        for msg_class, msg_id in required_ubx:
            if (msg_class, msg_id) not in self.ubx_counts:
                missing_ubx.append(UBX_MESSAGES.get((msg_class, msg_id), f"UBX-{msg_class:02X}-{msg_id:02X}"))
                critical_ok = False

        if critical_ok:
            print("✓ All critical messages are present")
            print()
            print("Your receiver is properly configured for StratoCentral!")
        else:
            print("⚠️  WARNING: Missing critical messages!")
            print()

            if missing_nmea:
                print("Missing NMEA messages:")
                for msg in missing_nmea:
                    print(f"  • {msg}")
                print()

            if missing_ubx:
                print("Missing UBX messages:")
                for msg in missing_ubx:
                    print(f"  • {msg}")
                print()

            print("These messages are required for spoofing/jamming detection.")
            print("See ZED_F9P_MESSAGE_CONFIG.md for configuration instructions.")

        # Check for large messages
        print()
        for (msg_class, msg_id), sizes in self.ubx_sizes.items():
            max_size = max(sizes)
            if max_size > 2048:
                msg_name = UBX_MESSAGES.get((msg_class, msg_id), f"UBX-{msg_class:02X}-{msg_id:02X}")
                print(f"ℹ️  {msg_name} messages are large (max {max_size} bytes)")
                print(f"   This is normal for receivers tracking many satellites (60+)")
                print(f"   Buffer size has been increased to 4096 bytes to handle this.")


def main():
    """Main function"""
    device = "/dev/ttyAMA0"
    baudrate = 115200
    duration = 10

    if len(sys.argv) > 1:
        device = sys.argv[1]
    if len(sys.argv) > 2:
        baudrate = int(sys.argv[2])
    if len(sys.argv) > 3:
        duration = int(sys.argv[3])

    monitor = StreamMonitor(device, baudrate, duration)

    try:
        monitor.monitor()
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        monitor.display_results()


if __name__ == "__main__":
    main()
