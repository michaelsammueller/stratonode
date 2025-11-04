#!/usr/bin/env python3
"""
GNSS Combined Logger and Sender Service

Combines file logging and network transmission into a single service.
Reads from physical GNSS port, logs to hourly files, and sends batches to central server.

Features:
- Direct access to /dev/ttyAMA0 (no multiplexer needed)
- Hourly log rotation with zstd compression and SHA256 checksums
- Network transmission every 1 second
- Timestamps for all logged data
- Guaranteed data consistency (same bytes logged and sent)

Requirements:
    apt install zstd python3-serial
    pip install pyserial requests pydantic pydantic-settings python-dotenv
"""

import os
import sys
import time
import uuid
import errno
import signal
import logging
import subprocess
import threading
from datetime import datetime, timezone, timedelta
from typing import List, Tuple, Optional

import requests
from config import config
from gnss_reader import GNSSReader

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Global stop flag
STOP = False

# File sync settings
FSYNC_INTERVAL_BYTES = 1_000_000  # fsync after ~1MB written


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    global STOP
    logger.info(f"Received signal {signum}, initiating shutdown...")
    STOP = True


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


class FileLogger:
    """
    Manages hourly log files for NMEA and UBX data.
    Handles rotation, compression, and checksumming.
    """

    def __init__(self, root_dir: str = "/data/gnss"):
        self.root_dir = root_dir
        self.current_hour = None
        self.nmea_path: Optional[str] = None
        self.ubx_path: Optional[str] = None
        self.nmea_fh = None
        self.ubx_fh = None
        self.n_written = 0
        self.u_written = 0

        # Ensure root directory exists
        os.makedirs(self.root_dir, exist_ok=True)

    def _get_paths(self, dt: datetime) -> Tuple[str, str]:
        """
        Get file paths for a given datetime.
        Returns: (nmea_path, ubx_path)
        """
        day_dir = os.path.join(
            self.root_dir,
            dt.strftime("%Y"),
            dt.strftime("%m"),
            dt.strftime("%d")
        )
        os.makedirs(day_dir, exist_ok=True)

        base = os.path.join(day_dir, dt.strftime("%H"))
        return base + ".nmea", base + ".ubx"

    def _compress_and_checksum(self, src_path: str):
        """
        Compress file to .zst and compute SHA256 checksum.
        Safe to run multiple times (idempotent).
        """
        zst_tmp = src_path + ".zst.tmp"
        zst_final = src_path + ".zst"
        sha_final = src_path + ".zst.sha256"

        # Skip if already done
        if os.path.exists(zst_final) and os.path.exists(sha_final):
            return

        # Check if source file exists
        if not os.path.exists(src_path):
            return

        try:
            # Compress with zstd
            subprocess.run(
                ["zstd", "-q", "-T0", "-19", "-f", "-o", zst_tmp, src_path],
                check=True,
            )
            os.sync()

            # Compute SHA256
            sha_out = subprocess.run(
                ["sha256sum", os.path.basename(zst_tmp)],
                check=True,
                cwd=os.path.dirname(zst_tmp),
                capture_output=True,
                text=True,
            ).stdout

            # Write checksum
            sha_tmp = sha_final + ".tmp"
            with open(sha_tmp, "w", encoding="utf-8") as f:
                f.write(sha_out)
                f.flush()
                os.fsync(f.fileno())

            # Atomic rename
            os.replace(zst_tmp, zst_final)
            os.replace(sha_tmp, sha_final)

            # Remove original
            os.remove(src_path)

            logger.info(f"Compressed and checksummed: {os.path.basename(src_path)}")

        except FileNotFoundError:
            logger.error("zstd not found. Install with: apt install zstd")
        except Exception as e:
            logger.error(f"Failed to compress {src_path}: {e}")

    def _rotate_previous_hour(self, now: datetime):
        """Compress previous hour's files"""
        prev = now.replace(minute=0, second=0, microsecond=0) - timedelta(hours=1)
        prev_nmea, prev_ubx = self._get_paths(prev)

        for src in (prev_nmea, prev_ubx):
            if os.path.exists(src):
                self._compress_and_checksum(src)

    def _open_files(self, dt: datetime):
        """Open new hourly files"""
        # Close existing files
        if self.nmea_fh:
            try:
                self.nmea_fh.flush()
                os.fsync(self.nmea_fh.fileno())
                self.nmea_fh.close()
            except Exception as e:
                logger.warning(f"Error closing NMEA file: {e}")

        if self.ubx_fh:
            try:
                self.ubx_fh.flush()
                os.fsync(self.ubx_fh.fileno())
                self.ubx_fh.close()
            except Exception as e:
                logger.warning(f"Error closing UBX file: {e}")

        # Reset counters
        self.n_written = 0
        self.u_written = 0

        # Open new files
        self.nmea_path, self.ubx_path = self._get_paths(dt)
        self.nmea_fh = open(self.nmea_path, "a", buffering=1, encoding="ascii", errors="ignore")
        self.ubx_fh = open(self.ubx_path, "ab", buffering=0)
        self.current_hour = dt.hour

        logger.info(f"Opened new log files: {os.path.basename(self.nmea_path)}, {os.path.basename(self.ubx_path)}")

    def initialize(self):
        """Initialize logger with current hour's files"""
        now = datetime.now(timezone.utc)
        self._open_files(now)
        # Compress previous hour if needed
        self._rotate_previous_hour(now)

    def check_rotation(self):
        """Check if hour has changed and rotate if needed"""
        now = datetime.now(timezone.utc)
        if now.hour != self.current_hour:
            logger.info("Hour boundary detected, rotating files...")
            self._open_files(now)
            self._rotate_previous_hour(now)

    def write_nmea(self, nmea_line: str, timestamp: float):
        """Write timestamped NMEA line"""
        if not self.nmea_fh:
            return

        try:
            # Format: timestamp nmea_sentence
            ts_str = datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()
            self.nmea_fh.write(f"{ts_str} {nmea_line}\n")
            self.n_written += len(nmea_line) + len(ts_str) + 2

            # Periodic fsync
            if self.n_written >= FSYNC_INTERVAL_BYTES:
                self.nmea_fh.flush()
                os.fsync(self.nmea_fh.fileno())
                self.n_written = 0

        except Exception as e:
            logger.error(f"Error writing NMEA: {e}")

    def write_ubx(self, ubx_bytes: bytes, timestamp: float):
        """Write timestamped UBX message"""
        if not self.ubx_fh:
            return

        try:
            # Format: 8-byte timestamp (double) + UBX message
            import struct
            ts_bytes = struct.pack('<d', timestamp)
            self.ubx_fh.write(ts_bytes + ubx_bytes)
            self.u_written += len(ubx_bytes) + 8

            # Periodic fsync
            if self.u_written >= FSYNC_INTERVAL_BYTES:
                self.ubx_fh.flush()
                os.fsync(self.ubx_fh.fileno())
                self.u_written = 0

        except Exception as e:
            logger.error(f"Error writing UBX: {e}")

    def close(self):
        """Close files and compress current hour"""
        logger.info("Closing log files...")

        if self.nmea_fh:
            try:
                self.nmea_fh.flush()
                os.fsync(self.nmea_fh.fileno())
                self.nmea_fh.close()
            except Exception:
                pass

        if self.ubx_fh:
            try:
                self.ubx_fh.flush()
                os.fsync(self.ubx_fh.fileno())
                self.ubx_fh.close()
            except Exception:
                pass

        # Compress current hour on shutdown
        if self.nmea_path:
            self._compress_and_checksum(self.nmea_path)
        if self.ubx_path:
            self._compress_and_checksum(self.ubx_path)


class NetworkSender:
    """
    Sends batches to central-ingest service.
    """

    def __init__(self):
        self.station_id = config.station_id
        self.station_name = config.station_name
        self.sequence_number = 0
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": "application/json",
        })

        self.batches_sent = 0
        self.batches_failed = 0

        logger.info(f"Network sender initialized: {self.station_id}")
        logger.info(f"Target: {config.ingest_url}")
        logger.info(f"Send interval: {config.send_interval}s")

    def send_batch(self, nmea_lines: List[str], ubx_base64: List[str]) -> bool:
        """
        Send batch to central-ingest.
        Returns True if successful, False otherwise.
        """
        # Increment sequence number
        self.sequence_number += 1

        # Build batch (same format as sender.py)
        batch = {
            "station_id": self.station_id,
            "station_name": self.station_name,
            "batch_id": str(uuid.uuid4()),
            "sequence_number": self.sequence_number,
            "recv_ts": time.time(),
            "nmea_raw": nmea_lines,
            "ubx_raw": ubx_base64,
            "is_reference_station": config.is_reference_station,
        }

        # Add known position if reference station
        if config.is_reference_station:
            batch["known_position"] = (
                config.latitude,
                config.longitude,
                config.antenna_height
            )

        try:
            response = self.session.post(
                config.ingest_url,
                json=batch,
                timeout=10.0
            )

            if response.status_code == 202:
                self.batches_sent += 1
                logger.info(
                    f"✓ Batch {batch['batch_id'][:8]} accepted "
                    f"(seq={self.sequence_number}, nmea={len(nmea_lines)}, ubx={len(ubx_base64)})"
                )
                return True
            else:
                self.batches_failed += 1
                logger.error(f"✗ Batch rejected: {response.status_code} - {response.text}")
                return False

        except requests.exceptions.RequestException as e:
            self.batches_failed += 1
            logger.error(f"✗ Network error: {e}")
            return False

    def get_stats(self) -> str:
        """Get transmission statistics"""
        total = self.batches_sent + self.batches_failed
        if total == 0:
            return "No batches sent yet"
        success_rate = (self.batches_sent / total) * 100
        return f"{self.batches_sent} sent, {self.batches_failed} failed, success rate={success_rate:.1f}%"


class CombinedService:
    """
    Main service that combines logging and sending.
    """

    def __init__(self):
        self.reader = GNSSReader(config.gnss_device, config.gnss_baud_rate)
        self.logger = FileLogger(getattr(config, 'log_root_dir', '/data/gnss'))
        self.sender = NetworkSender()
        self.last_send_time = 0
        self.send_interval = config.send_interval

    def run(self):
        """Main service loop"""
        logger.info("=" * 80)
        logger.info(f"GNSS Combined Service Starting")
        logger.info(f"Station: {config.station_id}")
        logger.info(f"Device: {config.gnss_device} @ {config.gnss_baud_rate} baud")
        logger.info(f"Send interval: {self.send_interval}s")
        logger.info("=" * 80)

        try:
            # Initialize file logger
            self.logger.initialize()

            # Start GNSS reader
            self.reader.start()
            logger.info("GNSS reader started")

            # Main loop
            self.last_send_time = time.time()

            while not STOP:
                # Check for hour boundary (file rotation)
                self.logger.check_rotation()

                # Check if it's time to send
                now = time.time()
                if now - self.last_send_time >= self.send_interval:
                    # Get buffered data (with raw UBX for logging)
                    nmea_lines, ubx_base64, ubx_raw = self.reader.get_buffered_data_with_raw_ubx()

                    # Send batch (even if empty, for heartbeat)
                    if nmea_lines or ubx_base64:
                        self.sender.send_batch(nmea_lines, ubx_base64)

                        # Log to files (with timestamps)
                        for nmea_line in nmea_lines:
                            self.logger.write_nmea(nmea_line, now)

                        for ubx_msg in ubx_raw:
                            self.logger.write_ubx(ubx_msg, now)

                    self.last_send_time = now

                    # Periodic stats
                    if self.sender.sequence_number % 60 == 0:  # Every minute
                        logger.info(f"Stats: {self.sender.get_stats()}")

                # Small sleep to avoid busy-waiting
                time.sleep(0.1)

        except KeyboardInterrupt:
            logger.info("Interrupted by user")
        except Exception as e:
            logger.error(f"Fatal error: {e}", exc_info=True)
        finally:
            self.shutdown()

    def shutdown(self):
        """Clean shutdown"""
        logger.info("Shutting down service...")

        # Stop reader
        self.reader.stop()

        # Close log files
        self.logger.close()

        # Final stats
        logger.info(f"Final stats: {self.sender.get_stats()}")
        logger.info("Service stopped")


def main():
    """Entry point"""
    try:
        service = CombinedService()
        service.run()
        return 0
    except Exception as e:
        logger.error(f"Failed to start service: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
