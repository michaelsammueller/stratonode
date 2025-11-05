#!/usr/bin/env python3
"""
Test script for GNSS reader
"""

import logging
from gnss_reader import SimulatedGNSSReader

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)

def test_simulated_reader():
    """Test simulated GNSS reader"""
    print("=" * 80)
    print("Testing Simulated GNSS Reader")
    print("=" * 80)

    # Initialize reader
    reader = SimulatedGNSSReader(
        nmea_file="examples/17.nmea.txt",
        ubx_file="examples/17.ubx.txt"
    )

    # Start reader
    reader.start()

    # Get a few batches
    for i in range(5):
        nmea_lines, ubx_base64 = reader.get_buffered_data()

        print(f"\nBatch {i+1}:")
        print(f"  NMEA lines: {len(nmea_lines)}")
        print(f"  UBX messages: {len(ubx_base64)}")

        if nmea_lines:
            print(f"  First NMEA: {nmea_lines[0][:60]}...")
            print(f"  Last NMEA:  {nmea_lines[-1][:60]}...")

        if ubx_base64:
            print(f"  UBX data length: {len(ubx_base64[0])} chars")

    # Stop reader
    reader.stop()

    print("\n" + "=" * 80)
    print("Test completed successfully!")
    print("=" * 80)

if __name__ == "__main__":
    test_simulated_reader()
