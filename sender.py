#!/usr/bin/env python3
"""
Ground Node Sender Service

Reads live GNSS data from a serial device and sends batches to central-ingest.
Forwards raw NMEA and UBX data for central processing.
"""

import time
import uuid
import logging
from typing import Dict, Any, List

import requests
from config import config
from gnss_reader import GNSSReader

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


class GroundNodeSender:
    """
    Ground node sender that reads live GNSS data and sends batches to central-ingest.
    """

    def __init__(self):
        """Initialize sender"""
        self.station_id = config.station_id
        self.station_name = config.station_name
        self.sequence_number = 0
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": "application/json",
        })

        # Initialize GNSS reader for live data collection
        logger.info(f"Initializing GNSS reader: {config.gnss_device} @ {config.gnss_baud_rate} baud")
        self.reader = GNSSReader(config.gnss_device, config.gnss_baud_rate)

        logger.info(f"Ground Node Sender initialized: {self.station_id}")
        logger.info(f"Target: {config.ingest_url}")
        logger.info(f"Antenna position: {config.latitude}, {config.longitude}, {config.antenna_height}m MSL")

    def create_batch(self) -> Dict[str, Any]:
        """
        Create a batch from live GNSS data.

        Returns:
            Batch dictionary matching IngestBatch schema
        """
        # Get buffered GNSS data
        nmea_lines, ubx_base64 = self.reader.get_buffered_data()

        # Increment sequence number
        self.sequence_number += 1

        # Build batch with raw data
        batch = {
            "station_id": self.station_id,
            "station_name": self.station_name,
            "batch_id": str(uuid.uuid4()),
            "sequence_number": self.sequence_number,
            "recv_ts": time.time(),
            "nmea_raw": nmea_lines,  # Raw NMEA strings
            "ubx_raw": ubx_base64,    # Base64-encoded UBX messages
            "is_reference_station": config.is_reference_station,
        }

        # Add known position if reference station
        if config.is_reference_station:
            batch["known_position"] = (
                config.latitude,
                config.longitude,
                config.antenna_height
            )

        return batch

    def send_batch(self, batch: Dict[str, Any]) -> bool:
        """
        Send batch to central-ingest service.

        Args:
            batch: Batch dictionary

        Returns:
            True if successful, False otherwise
        """
        try:
            response = self.session.post(
                config.ingest_url,
                json=batch,
                timeout=10.0
            )

            if response.status_code == 202:
                result = response.json()
                logger.info(
                    f"✓ Batch {batch['batch_id'][:8]} accepted "
                    f"(seq={batch['sequence_number']}, "
                    f"nmea={len(batch['nmea_raw'])} lines, ubx={len(batch['ubx_raw'])} msgs)"
                )
                return True
            else:
                logger.error(
                    f"✗ Batch rejected: {response.status_code} - {response.text}"
                )
                return False

        except requests.exceptions.RequestException as e:
            logger.error(f"✗ Failed to send batch: {e}")
            return False

    def run(self):
        """
        Main sender loop: read GNSS data and send batches periodically.
        """
        logger.info("=" * 80)
        logger.info(f"Starting Ground Node Sender: {self.station_id}")
        logger.info(f"Sending every {config.send_interval} seconds")
        logger.info("Press Ctrl+C to stop")
        logger.info("=" * 80)

        batches_sent = 0
        batches_failed = 0

        try:
            # Start GNSS reader
            self.reader.start()

            while True:
                # Create batch from buffered data
                batch = self.create_batch()

                # Send to central-ingest
                success = self.send_batch(batch)

                if success:
                    batches_sent += 1
                else:
                    batches_failed += 1

                # Log statistics periodically
                if (batches_sent + batches_failed) % 10 == 0:
                    logger.info(
                        f"Stats: {batches_sent} sent, {batches_failed} failed, "
                        f"success rate={(batches_sent/(batches_sent+batches_failed)*100):.1f}%"
                    )

                # Wait before next send
                time.sleep(config.send_interval)

        except KeyboardInterrupt:
            logger.info("\n" + "=" * 80)
            logger.info("Shutting down sender...")
            logger.info(f"Final stats: {batches_sent} sent, {batches_failed} failed")
            logger.info("=" * 80)
        finally:
            # Stop GNSS reader
            self.reader.stop()


def main():
    """Entry point"""
    try:
        sender = GroundNodeSender()
        sender.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        return 1

    return 0


if __name__ == "__main__":
    exit(main())
