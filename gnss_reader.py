#!/usr/bin/env python3
"""
GNSS Reader Module

Reads raw NMEA and UBX data from a GNSS receiver via serial connection.
Buffers data for batch transmission to central server.
"""

import time
import logging
import threading
from typing import List, Tuple, Optional
import base64

try:
    import serial
except ImportError:
    serial = None

logger = logging.getLogger(__name__)


class GNSSReader:
    """
    Reads raw GNSS data from serial device and buffers it.
    No parsing - just raw data collection.
    """

    # UBX message header
    UBX_SYNC_CHAR_1 = 0xB5
    UBX_SYNC_CHAR_2 = 0x62

    def __init__(self, device: str, baud_rate: int = 115200):
        """
        Initialize GNSS reader.

        Args:
            device: Serial device path (e.g., /dev/ttyACM0, COM3)
            baud_rate: Baud rate for serial connection
        """
        if serial is None:
            raise RuntimeError("pyserial not installed. Install with: pip install pyserial")

        self.device = device
        self.baud_rate = baud_rate
        self.serial_conn: Optional[serial.Serial] = None
        self.running = False
        self.reader_thread: Optional[threading.Thread] = None

        # Output buffers (thread-safe)
        self.nmea_buffer: List[str] = []
        self.ubx_buffer: List[bytes] = []
        self.buffer_lock = threading.Lock()

        # Parser state for NMEA
        self.nmea_line_buffer = bytearray()

        # Parser state for UBX
        self.ubx_partial_buffer = bytearray()

        # State machine
        self.parsing_state = 'SEARCHING'  # SEARCHING, IN_NMEA, IN_UBX

        # Safety limits
        self.max_nmea_line_length = 512  # Max NMEA sentence length
        self.max_ubx_message_length = 2048  # Max UBX message length

        # Desync detection
        self.ubx_error_count = 0  # Track consecutive UBX errors
        self.max_ubx_errors_before_resync = 5  # Force resync after N errors

        logger.info(f"GNSS Reader initialized: {device} @ {baud_rate} baud")

    def connect(self):
        """Open connection to GNSS device."""
        try:
            self.serial_conn = serial.Serial(
                port=self.device,
                baudrate=self.baud_rate,
                timeout=1.0,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
            )
            logger.info(f"Connected to GNSS device: {self.device}")

            # Detect potential port sharing
            time.sleep(0.2)  # Let data accumulate
            if self.serial_conn.in_waiting == 0:
                logger.warning(
                    "⚠️  No data from GNSS device after 200ms. "
                    "Possible causes: (1) Device not sending data, "
                    "(2) Another process is reading from this port. "
                    "Check with: fuser " + self.device
                )

        except serial.SerialException as e:
            if "busy" in str(e).lower() or "in use" in str(e).lower():
                logger.error(
                    f"Port {self.device} is BUSY - another process is using it!\n"
                    f"Solutions:\n"
                    f"  1. Stop other services: sudo systemctl stop <service-name>\n"
                    f"  2. Check processes: fuser {self.device}"
                )
            else:
                logger.error(f"Failed to connect to {self.device}: {e}")
            raise

    def disconnect(self):
        """Close serial connection."""
        if self.serial_conn and self.serial_conn.is_open:
            self.serial_conn.close()
            logger.info("Disconnected from GNSS device")

    def start(self):
        """Start reading data in background thread."""
        if self.running:
            logger.warning("Reader already running")
            return

        self.connect()
        self.running = True
        self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self.reader_thread.start()
        logger.info("GNSS reader started")

    def stop(self):
        """Stop reading data."""
        self.running = False
        if self.reader_thread:
            self.reader_thread.join(timeout=2.0)
        self.disconnect()
        logger.info("GNSS reader stopped")

    def _read_loop(self):
        """
        Main reading loop - runs in background thread.
        """
        logger.info("Serial reader loop started")
        consecutive_errors = 0
        max_consecutive_errors = 10

        while self.running and self.serial_conn and self.serial_conn.is_open:
            try:
                # Read available data
                if self.serial_conn.in_waiting > 0:
                    data = self.serial_conn.read(self.serial_conn.in_waiting)
                    self._process_data(data)
                    consecutive_errors = 0  # Reset on successful read
                else:
                    time.sleep(0.01)  # Small delay if no data

            except serial.SerialException as e:
                consecutive_errors += 1
                logger.error(f"Serial read error ({consecutive_errors}/{max_consecutive_errors}): {e}")

                if consecutive_errors >= max_consecutive_errors:
                    logger.error("Too many consecutive errors, stopping reader")
                    break

                time.sleep(0.1)  # Back off on error

            except Exception as e:
                consecutive_errors += 1
                logger.error(f"Unexpected error in read loop ({consecutive_errors}/{max_consecutive_errors}): {e}", exc_info=True)

                if consecutive_errors >= max_consecutive_errors:
                    logger.error("Too many consecutive errors, stopping reader")
                    break

                time.sleep(0.1)

        logger.info("Serial reader loop ended")

    def _process_data(self, data: bytes):
        """
        Process incoming data with proper state machine to separate NMEA from UBX.

        This method uses a state machine to correctly handle:
        - Mixed NMEA/UBX streams
        - Incomplete messages across read boundaries
        - Data corruption and recovery

        Args:
            data: Raw bytes from serial port
        """
        # Prepend any partial UBX data from previous read
        if self.ubx_partial_buffer:
            data = self.ubx_partial_buffer + data
            self.ubx_partial_buffer.clear()

        i = 0
        while i < len(data):
            byte = data[i]

            # STATE: SEARCHING - looking for message start
            if self.parsing_state == 'SEARCHING':
                # Check for UBX sync bytes
                if byte == self.UBX_SYNC_CHAR_1:
                    if i + 1 < len(data) and data[i + 1] == self.UBX_SYNC_CHAR_2:
                        # Found UBX start - try to extract complete message
                        self.ubx_partial_buffer = bytearray(data[i:])

                        # Check if we have enough bytes to validate the length field
                        if len(self.ubx_partial_buffer) >= 6:
                            # Parse length (bytes 4-5)
                            length = self.ubx_partial_buffer[4] | (self.ubx_partial_buffer[5] << 8)

                            # Check for obviously invalid length
                            if length > self.max_ubx_message_length:
                                self.ubx_error_count += 1
                                logger.warning(
                                    f"UBX message too large: {length} bytes (max {self.max_ubx_message_length}), "
                                    f"skipping sync bytes (error count: {self.ubx_error_count})"
                                )

                                # If we've seen too many errors, force aggressive resync
                                if self.ubx_error_count >= self.max_ubx_errors_before_resync:
                                    logger.error(
                                        f"UBX parser stuck after {self.ubx_error_count} consecutive errors. "
                                        f"Forcing resync by clearing all buffers."
                                    )
                                    self.ubx_partial_buffer.clear()
                                    self.ubx_error_count = 0
                                else:
                                    self.ubx_partial_buffer.clear()

                                # Skip these 2 sync bytes and continue searching
                                i += 2
                                continue

                        ubx_msg = self._extract_ubx_message(self.ubx_partial_buffer)
                        if ubx_msg:
                            # Complete message - buffer it
                            with self.buffer_lock:
                                self.ubx_buffer.append(ubx_msg)

                            # Reset error count on successful parse
                            self.ubx_error_count = 0

                            # Advance past this message
                            bytes_consumed = len(ubx_msg)
                            i += bytes_consumed
                            self.ubx_partial_buffer.clear()
                            # Stay in SEARCHING state
                            continue
                        else:
                            # Incomplete message - save remainder for next read
                            # Will be prepended in next call
                            # Stay in SEARCHING state (important!)
                            break

                # Check for NMEA start
                elif byte == ord('$'):
                    self.parsing_state = 'IN_NMEA'
                    self.nmea_line_buffer.clear()
                    self.nmea_line_buffer.append(byte)

                # Ignore other bytes while searching
                i += 1

            # STATE: IN_NMEA - building NMEA sentence
            elif self.parsing_state == 'IN_NMEA':
                self.nmea_line_buffer.append(byte)

                # Check for end of line
                if byte == ord('\n'):
                    # Complete NMEA line
                    try:
                        nmea_line = self.nmea_line_buffer.decode('ascii').strip()

                        # Validate it looks like NMEA
                        if nmea_line.startswith('$') and len(nmea_line) > 5:
                            # Optional: validate checksum
                            if self._validate_nmea_checksum(nmea_line):
                                with self.buffer_lock:
                                    self.nmea_buffer.append(nmea_line)
                            else:
                                logger.debug(f"NMEA checksum failed: {nmea_line[:20]}...")

                    except UnicodeDecodeError as e:
                        logger.warning(f"Failed to decode NMEA line (corrupted data), resyncing")

                    # Reset state
                    self.nmea_line_buffer.clear()
                    self.parsing_state = 'SEARCHING'

                # Check for buffer overflow protection
                elif len(self.nmea_line_buffer) > self.max_nmea_line_length:
                    logger.warning(f"NMEA line too long ({len(self.nmea_line_buffer)} bytes), discarding")
                    self.nmea_line_buffer.clear()
                    self.parsing_state = 'SEARCHING'

                # Check for unexpected UBX sync in middle of NMEA
                elif byte == self.UBX_SYNC_CHAR_1 and i + 1 < len(data) and data[i + 1] == self.UBX_SYNC_CHAR_2:
                    # Data corruption detected - UBX in NMEA stream
                    logger.warning("Data corruption: UBX bytes in NMEA stream, resyncing")
                    self.nmea_line_buffer.clear()
                    self.parsing_state = 'SEARCHING'
                    # Don't increment i, let next iteration process UBX
                    continue

                i += 1

            # Unknown state - should never happen
            else:
                logger.error(f"BUG: Unknown parsing state: {self.parsing_state}, resetting to SEARCHING")
                self.parsing_state = 'SEARCHING'
                self.nmea_line_buffer.clear()
                self.ubx_partial_buffer.clear()
                i += 1

    def _validate_nmea_checksum(self, nmea_line: str) -> bool:
        """
        Validate NMEA sentence checksum.

        Args:
            nmea_line: NMEA sentence (with or without checksum)

        Returns:
            True if valid or no checksum present, False if invalid
        """
        if '*' not in nmea_line:
            return True  # No checksum to validate

        try:
            sentence, checksum = nmea_line.split('*')
            sentence = sentence.lstrip('$')

            # Calculate checksum
            calc_checksum = 0
            for char in sentence:
                calc_checksum ^= ord(char)

            # Compare
            provided_checksum = int(checksum[:2], 16)  # Only first 2 hex chars
            return calc_checksum == provided_checksum

        except Exception:
            return False

    def _extract_ubx_message(self, data: bytes) -> Optional[bytes]:
        """
        Extract a complete UBX message from data.
        UBX format: 0xB5 0x62 [class] [id] [length_low] [length_high] [payload] [ck_a] [ck_b]

        Args:
            data: Bytes starting with UBX header

        Returns:
            Complete UBX message or None if incomplete
        """
        if len(data) < 8:  # Minimum UBX message size
            return None

        # Parse length (bytes 4-5)
        length = data[4] | (data[5] << 8)

        # Check for reasonable length (prevent buffer overflow)
        # Note: This should be caught earlier in _process_serial_data, but double-check here
        if length > self.max_ubx_message_length:
            return None

        # Total message size = header(2) + class(1) + id(1) + length(2) + payload + checksum(2)
        total_size = 6 + length + 2

        if len(data) < total_size:
            return None  # Incomplete message

        # Extract message
        message = data[:total_size]

        # Validate checksum
        if not self._validate_ubx_checksum(message):
            logger.warning("UBX message failed checksum validation, skipping")
            return None

        return message

    def _validate_ubx_checksum(self, message: bytes) -> bool:
        """
        Validate UBX message checksum.

        Args:
            message: Complete UBX message

        Returns:
            True if checksum valid, False otherwise
        """
        if len(message) < 8:
            return False

        # Calculate checksum over class, id, length, and payload
        ck_a = 0
        ck_b = 0

        for byte in message[2:-2]:  # Skip header and checksum bytes
            ck_a = (ck_a + byte) & 0xFF
            ck_b = (ck_b + ck_a) & 0xFF

        # Compare with provided checksum
        return message[-2] == ck_a and message[-1] == ck_b

    def get_buffered_data(self) -> Tuple[List[str], List[str]]:
        """
        Get and clear current buffered data.

        Returns:
            Tuple of (nmea_lines, ubx_messages_base64)
            - nmea_lines: List of raw NMEA strings
            - ubx_messages_base64: List of base64-encoded UBX messages
        """
        with self.buffer_lock:
            # Copy buffers
            nmea_lines = self.nmea_buffer.copy()
            ubx_base64 = [base64.b64encode(msg).decode('ascii') for msg in self.ubx_buffer]

            # Clear buffers
            self.nmea_buffer.clear()
            self.ubx_buffer.clear()

        return nmea_lines, ubx_base64

    def get_buffered_data_with_raw_ubx(self) -> Tuple[List[str], List[str], List[bytes]]:
        """
        Get and clear current buffered data, including raw UBX bytes.

        Returns:
            Tuple of (nmea_lines, ubx_messages_base64, ubx_messages_raw)
            - nmea_lines: List of raw NMEA strings
            - ubx_messages_base64: List of base64-encoded UBX messages
            - ubx_messages_raw: List of raw UBX message bytes
        """
        with self.buffer_lock:
            # Copy buffers
            nmea_lines = self.nmea_buffer.copy()
            ubx_raw = self.ubx_buffer.copy()
            ubx_base64 = [base64.b64encode(msg).decode('ascii') for msg in ubx_raw]

            # Clear buffers
            self.nmea_buffer.clear()
            self.ubx_buffer.clear()

        return nmea_lines, ubx_base64, ubx_raw
