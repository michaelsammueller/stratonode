#!/usr/bin/env python3
"""
Query ZED-F9P Configuration

This script queries the receiver for its active message configuration
and displays which messages are enabled on each port.
"""

import sys
import time
import serial
import struct
from typing import Dict, List, Tuple

# UBX Protocol Constants
UBX_SYNC_1 = 0xB5
UBX_SYNC_2 = 0x62

# UBX Message Classes
UBX_CLASS_CFG = 0x06
UBX_CLASS_MON = 0x0A
UBX_CLASS_NAV = 0x01
UBX_CLASS_RXM = 0x02

# Common message IDs
MESSAGES_TO_CHECK = {
    # NMEA Messages (class 0xF0)
    (0xF0, 0x00): "NMEA-GGA (Position)",
    (0xF0, 0x02): "NMEA-GSA (DOP and active satellites)",
    (0xF0, 0x03): "NMEA-GSV (Satellites in view)",
    (0xF0, 0x04): "NMEA-RMC (Recommended minimum)",
    (0xF0, 0x05): "NMEA-VTG (Course and speed)",
    (0xF0, 0x07): "NMEA-GST (Pseudorange error statistics)",
    (0xF0, 0x08): "NMEA-ZDA (Time and date)",
    (0xF0, 0x09): "NMEA-GBS (GNSS satellite fault detection)",
    (0xF0, 0x0D): "NMEA-GNS (GNSS fix data)",
    (0xF0, 0x0F): "NMEA-VLW (Dual ground/water distance)",

    # UBX-MON Messages
    (0x0A, 0x09): "UBX-MON-HW (Hardware status - CRITICAL FOR JAMMING)",
    (0x0A, 0x0B): "UBX-MON-HW2 (Extended hardware status)",
    (0x0A, 0x04): "UBX-MON-VER (Receiver version)",
    (0x0A, 0x28): "UBX-MON-RF (RF information)",

    # UBX-NAV Messages
    (0x01, 0x35): "UBX-NAV-SAT (Satellite information)",
    (0x01, 0x22): "UBX-NAV-CLOCK (Clock solution - CRITICAL FOR SPOOFING)",
    (0x01, 0x07): "UBX-NAV-PVT (Position velocity time)",
    (0x01, 0x21): "UBX-NAV-TIMEUTC (UTC time solution)",
    (0x01, 0x20): "UBX-NAV-TIMEGPS (GPS time solution)",
    (0x01, 0x04): "UBX-NAV-DOP (Dilution of precision)",

    # UBX-RXM Messages
    (0x02, 0x15): "UBX-RXM-RAWX (Raw measurements - CRITICAL FOR SPOOFING)",
    (0x02, 0x13): "UBX-RXM-SFRBX (Broadcast navigation data)",
    (0x02, 0x59): "UBX-RXM-MEASX (Satellite measurements)",
}

# Port names
PORTS = {
    0: "DDC (I2C)",
    1: "UART1 (Primary - connected to Pi)",
    2: "UART2 (Secondary)",
    3: "USB",
    4: "SPI",
}


def calculate_checksum(msg_class: int, msg_id: int, payload: bytes) -> Tuple[int, int]:
    """Calculate UBX checksum"""
    ck_a = 0
    ck_b = 0

    for byte in [msg_class, msg_id] + list(payload):
        ck_a = (ck_a + byte) & 0xFF
        ck_b = (ck_b + ck_a) & 0xFF

    return ck_a, ck_b


def build_ubx_message(msg_class: int, msg_id: int, payload: bytes = b'') -> bytes:
    """Build a complete UBX message"""
    length = len(payload)
    msg = struct.pack('<BBBBH', UBX_SYNC_1, UBX_SYNC_2, msg_class, msg_id, length)
    msg += payload

    ck_a, ck_b = calculate_checksum(msg_class, msg_id, payload)
    msg += struct.pack('<BB', ck_a, ck_b)

    return msg


def parse_ubx_response(data: bytes) -> Tuple[int, int, bytes]:
    """Parse UBX response and return class, id, payload"""
    if len(data) < 8:
        return None, None, None

    if data[0] != UBX_SYNC_1 or data[1] != UBX_SYNC_2:
        return None, None, None

    msg_class = data[2]
    msg_id = data[3]
    length = struct.unpack('<H', data[4:6])[0]

    if len(data) < 6 + length + 2:
        return None, None, None

    payload = data[6:6+length]

    return msg_class, msg_id, payload


def query_message_rate(ser: serial.Serial, msg_class: int, msg_id: int) -> Dict[int, int]:
    """Query the output rate of a specific message on all ports"""
    # Build CFG-MSG poll request
    payload = struct.pack('<BB', msg_class, msg_id)
    msg = build_ubx_message(0x06, 0x01, payload)

    # Send query
    ser.write(msg)
    ser.flush()

    # Wait for response (CFG-MSG with rates)
    timeout = time.time() + 1.0
    buffer = bytearray()

    while time.time() < timeout:
        if ser.in_waiting > 0:
            buffer.extend(ser.read(ser.in_waiting))

            # Look for UBX response
            if len(buffer) >= 8:
                for i in range(len(buffer) - 7):
                    if buffer[i] == UBX_SYNC_1 and buffer[i+1] == UBX_SYNC_2:
                        # Parse response
                        resp_class, resp_id, resp_payload = parse_ubx_response(buffer[i:])

                        if resp_class == 0x06 and resp_id == 0x01 and resp_payload:
                            # CFG-MSG response format: msgClass, msgID, rate[6 ports]
                            if len(resp_payload) >= 8:
                                rates = {}
                                for port in range(min(6, len(resp_payload) - 2)):
                                    rate = resp_payload[2 + port]
                                    if rate > 0:
                                        rates[port] = rate
                                return rates

                        buffer = buffer[i+8:]
                        break

        time.sleep(0.05)

    return {}


def query_port_config(ser: serial.Serial, port_id: int) -> Dict:
    """Query port configuration (CFG-PRT)"""
    payload = struct.pack('<B', port_id)
    msg = build_ubx_message(0x06, 0x00, payload)

    ser.write(msg)
    ser.flush()

    timeout = time.time() + 1.0
    buffer = bytearray()

    while time.time() < timeout:
        if ser.in_waiting > 0:
            buffer.extend(ser.read(ser.in_waiting))

            if len(buffer) >= 20:
                for i in range(len(buffer) - 19):
                    if buffer[i] == UBX_SYNC_1 and buffer[i+1] == UBX_SYNC_2:
                        resp_class, resp_id, resp_payload = parse_ubx_response(buffer[i:])

                        if resp_class == 0x06 and resp_id == 0x00 and resp_payload and len(resp_payload) >= 20:
                            # Parse port configuration
                            port_id = resp_payload[0]
                            baudrate = struct.unpack('<I', resp_payload[8:12])[0]
                            in_proto_mask = struct.unpack('<H', resp_payload[12:14])[0]
                            out_proto_mask = struct.unpack('<H', resp_payload[14:16])[0]

                            return {
                                'port_id': port_id,
                                'baudrate': baudrate,
                                'ubx_in': bool(in_proto_mask & 0x01),
                                'nmea_in': bool(in_proto_mask & 0x02),
                                'ubx_out': bool(out_proto_mask & 0x01),
                                'nmea_out': bool(out_proto_mask & 0x02),
                            }

        time.sleep(0.05)

    return {}


def query_receiver_version(ser: serial.Serial) -> str:
    """Query receiver firmware version (MON-VER)"""
    msg = build_ubx_message(0x0A, 0x04)

    ser.write(msg)
    ser.flush()

    timeout = time.time() + 1.0
    buffer = bytearray()

    while time.time() < timeout:
        if ser.in_waiting > 0:
            buffer.extend(ser.read(ser.in_waiting))

            if len(buffer) >= 40:
                for i in range(len(buffer) - 39):
                    if buffer[i] == UBX_SYNC_1 and buffer[i+1] == UBX_SYNC_2:
                        resp_class, resp_id, resp_payload = parse_ubx_response(buffer[i:])

                        if resp_class == 0x0A and resp_id == 0x04 and resp_payload:
                            # Parse SW version (first 30 bytes)
                            sw_version = resp_payload[:30].decode('ascii', errors='ignore').rstrip('\x00')
                            return sw_version

        time.sleep(0.05)

    return "Unknown"


def main():
    """Main function"""
    device = "/dev/ttyAMA0"
    baudrate = 115200

    if len(sys.argv) > 1:
        device = sys.argv[1]
    if len(sys.argv) > 2:
        baudrate = int(sys.argv[2])

    print(f"Querying ZED-F9P configuration on {device} @ {baudrate} baud...")
    print("=" * 80)
    print()

    try:
        ser = serial.Serial(device, baudrate, timeout=1.0)
        time.sleep(0.5)  # Let port stabilize

        # Clear any pending data
        ser.reset_input_buffer()

        # Query firmware version
        print("Receiver Information:")
        print("-" * 80)
        version = query_receiver_version(ser)
        print(f"Firmware: {version}")
        print()

        # Query UART1 port configuration
        print("UART1 Port Configuration (connected to Raspberry Pi):")
        print("-" * 80)
        uart1_config = query_port_config(ser, 1)
        if uart1_config:
            print(f"Baudrate: {uart1_config.get('baudrate', 'Unknown')}")
            print(f"UBX Input:  {'Enabled' if uart1_config.get('ubx_in') else 'Disabled'}")
            print(f"UBX Output: {'Enabled' if uart1_config.get('ubx_out') else 'Disabled'}")
            print(f"NMEA Input:  {'Enabled' if uart1_config.get('nmea_in') else 'Disabled'}")
            print(f"NMEA Output: {'Enabled' if uart1_config.get('nmea_out') else 'Disabled'}")
        else:
            print("Failed to query port configuration")
        print()

        # Query message rates
        print("Active Messages on UART1 (Primary Port):")
        print("-" * 80)
        print(f"{'Message':<55} {'Rate':<10} {'Status'}")
        print("-" * 80)

        critical_missing = []

        for (msg_class, msg_id), name in sorted(MESSAGES_TO_CHECK.items(), key=lambda x: x[1]):
            rates = query_message_rate(ser, msg_class, msg_id)

            uart1_rate = rates.get(1, 0)  # Port 1 = UART1

            if uart1_rate > 0:
                status = "✓ ENABLED"
                if uart1_rate == 1:
                    rate_str = "1 Hz"
                else:
                    rate_str = f"1/{uart1_rate} Hz"
            else:
                status = "✗ DISABLED"
                rate_str = "0 Hz"

                # Check if this is a critical message
                if "CRITICAL" in name.upper():
                    critical_missing.append(name)

            print(f"{name:<55} {rate_str:<10} {status}")

            time.sleep(0.1)  # Small delay between queries

        print()

        # Summary
        print("Configuration Summary:")
        print("=" * 80)

        if critical_missing:
            print("⚠️  WARNING: Critical messages are disabled!")
            print()
            print("Missing critical messages:")
            for msg in critical_missing:
                print(f"  • {msg}")
            print()
            print("These messages are required for spoofing/jamming detection.")
            print("See ZED_F9P_MESSAGE_CONFIG.md for configuration instructions.")
        else:
            print("✓ All critical messages are enabled")

        print()

        ser.close()

    except serial.SerialException as e:
        print(f"Error: Could not open {device}")
        print(f"Details: {e}")
        print()
        print("Make sure:")
        print("  1. The combined service is stopped: sudo systemctl stop combined")
        print("  2. You have permission: sudo usermod -a -G dialout $USER")
        print("  3. The port exists: ls -l /dev/ttyAMA0")
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        sys.exit(0)


if __name__ == "__main__":
    main()
