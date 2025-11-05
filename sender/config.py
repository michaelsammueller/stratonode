"""
Configuration for ground node sender service.
Loads settings from environment variables.
"""

import os
from pydantic_settings import BaseSettings
from pydantic import Field
from dotenv import load_dotenv

# Load .env file
load_dotenv()


class SenderConfig(BaseSettings):
    """Configuration for sender service"""

    # Station identification
    station_id: str = Field(..., description="Station ID (must match node in database)")
    station_name: str = Field(default="Test Ground Node", description="Human-readable station name")

    # Central-ingest service
    ingest_url: str = Field(default="http://localhost:8000/api/v1/ingest", description="Central-ingest endpoint URL")
    api_key: str = Field(..., description="API key for authentication")

    # Antenna position (for reference stations)
    latitude: float = Field(default=25.2731, description="Antenna latitude in decimal degrees")
    longitude: float = Field(default=51.6080, description="Antenna longitude in decimal degrees")
    antenna_height: float = Field(default=10.5, description="Antenna height above mean sea level in meters")

    # Sender behavior
    send_interval: int = Field(default=1, description="Seconds between batch sends")

    # Logging configuration (for combined service)
    log_root_dir: str = Field(default="/data/gnss", description="Root directory for GNSS log files")

    # Known position (for reference stations)
    is_reference_station: bool = Field(default=True, description="Whether this is a reference station")

    # GNSS device settings (required for live data collection)
    gnss_device: str = Field(default="/dev/ttyAMA0", description="Serial device path for GNSS receiver")
    gnss_baud_rate: int = Field(default=115200, description="Baud rate for GNSS serial connection")

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"


# Global config instance
config = SenderConfig()
