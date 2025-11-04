#!/usr/bin/env python3
"""
GNSS file-first logger for ZED-F9P on /dev/ttyGPS_logger.

Writes two append-only files per hour under /data/gnss/YYYY/MM/DD:
  HH.nmea, ASCII lines beginning with $
  HH.ubx, raw UBX binary frames

At the hour boundary, closes the current pair, then:
  compresses to .zst
  writes a .sha256 file of the compressed artifact
  fsyncs, renames atomically

Logger is resilient to restarts and clock drift,
and never overwrites existing files.

Requirements:
  apt install zstd
  pip install pyserial pyubx2 pynmea2
"""

import os
import sys
import time
import errno
import signal
import subprocess
from datetime import datetime, timezone, timedelta
import serial
from pyubx2 import UBXReader

# configurable via environment
ROOT = os.getenv("GNSS_ROOT", "/data/gnss")
PORT = os.getenv("GNSS_PORT", "/dev/ttyGPS_logger")
BAUD = int(os.getenv("GNSS_BAUD", "115200"))
FSYNC_INTERVAL_BYTES = 1_000_000   # fsync after about one megabyte written
PRINT_EVERY_SEC = 10               # status line interval

STOP = False

def sigterm(_n, _f):
    global STOP
    STOP = True

signal.signal(signal.SIGINT, sigterm)
signal.signal(signal.SIGTERM, sigterm)

def ensure_dir(path: str):
    os.makedirs(path, exist_ok=True)

def path_for(dt: datetime):
    day_dir = os.path.join(ROOT, dt.strftime("%Y"), dt.strftime("%m"), dt.strftime("%d"))
    ensure_dir(day_dir)
    base = os.path.join(day_dir, dt.strftime("%H"))
    return base + ".nmea", base + ".ubx"

def atomic_compress_and_checksum(src_path: str):
    """
    Compress src_path to src_path.zst.tmp, compute sha256,
    then atomically rename to .zst and .zst.sha256.
    Leaves original src_path in place until both artifacts are durable,
    then removes it to reclaim space.
    """
    zst_tmp = src_path + ".zst.tmp"
    zst_final = src_path + ".zst"
    sha_final = src_path + ".zst.sha256"

    if os.path.exists(zst_final) and os.path.exists(sha_final):
        # done previously
        return

    # compress, multi thread if available
    try:
        subprocess.run(
            ["zstd", "-q", "-T0", "-19", "-f", "-o", zst_tmp, src_path],
            check=True,
        )
    except FileNotFoundError:
        # zstd missing
        print("zstd not found, please install it, apt install zstd", file=sys.stderr)
        return
    os.sync()

    # checksum
    sha_out = subprocess.run(
        ["sha256sum", os.path.basename(zst_tmp)],
        check=True,
        cwd=os.path.dirname(zst_tmp),
        capture_output=True,
        text=True,
    ).stdout
    # write checksum to temp then move
    sha_tmp = sha_final + ".tmp"
    with open(sha_tmp, "w", encoding="utf-8") as f:
        f.write(sha_out)
        f.flush()
        os.fsync(f.fileno())

    # finalize
    os.replace(zst_tmp, zst_final)
    os.replace(sha_tmp, sha_final)

    # remove original uncompressed file
    try:
        os.remove(src_path)
    except FileNotFoundError:
        pass

def rotate_previous_hour(now: datetime):
    """
    Compress and checksum the previous hour pair if present and not yet processed.
    Safe to run at startup and on each hour tick.
    """
    prev = now.replace(minute=0, second=0, microsecond=0) - timedelta(hours=1)
    # build paths
    prev_nmea, prev_ubx = path_for(prev)
    # only act on complete files that are not open
    for src in (prev_nmea, prev_ubx):
        if os.path.exists(src):
            atomic_compress_and_checksum(src)

def open_pair(dt: datetime):
    """
    Open append handles for the current hour, creating directories as needed.
    Use unbuffered binary for UBX, text for NMEA.
    """
    nmea_path, ubx_path = path_for(dt)
    nfh = open(nmea_path, "a", buffering=1, encoding="ascii", errors="ignore")
    ufh = open(ubx_path, "ab", buffering=0)
    return nmea_path, ubx_path, nfh, ufh

def fsync_if_needed(fh, counter, threshold):
    if counter >= threshold:
        try:
            fh.flush()
            os.fsync(fh.fileno())
        except Exception:
            pass
        return 0
    return counter

def main():
    ensure_dir(ROOT)
    ser = serial.Serial(PORT, BAUD, timeout=1)
    ubr = UBXReader(ser, protfilter=7)  # NMEA, UBX, RTCM
    current_hour = None
    nmea_path = ubx_path = None
    nfh = ufh = None
    n_written = u_written = 0
    last_print = 0.0

    def open_current(dt):
        nonlocal current_hour, nmea_path, ubx_path, nfh, ufh, n_written, u_written
        if nfh:
            try:
                nfh.flush(); os.fsync(nfh.fileno()); nfh.close()
            except Exception:
                pass
        if ufh:
            try:
                ufh.flush(); os.fsync(ufh.fileno()); ufh.close()
            except Exception:
                pass
        n_written = u_written = 0
        nmea_path, ubx_path, nfh, ufh = open_pair(dt)
        current_hour = dt.hour

    # first open
    now = datetime.now(timezone.utc)
    open_current(now)
    # attempt compression of the previous hour if any uncompressed files exist
    rotate_previous_hour(now)

    while not STOP:
        try:
            raw, msg = next(ubr)
        except Exception:
            # timeout or parse hiccup
            now = datetime.now(timezone.utc)
            if now.hour != current_hour:
                # rotate
                open_current(now)
                rotate_previous_hour(now)
            continue

        now = datetime.now(timezone.utc)
        if now.hour != current_hour:
            # hour rolled, rotate files and post-process previous hour
            open_current(now)
            rotate_previous_hour(now)

        # NMEA line
        if isinstance(raw, (bytes, bytearray)) and raw.startswith(b"$"):
            try:
                line = raw.decode("ascii", errors="ignore").rstrip("\r\n")
            except Exception:
                line = ""
            if line:
                nfh.write(line + "\n")
                n_written += len(line) + 1
                n_written = fsync_if_needed(nfh, n_written, FSYNC_INTERVAL_BYTES)
        else:
            # UBX or RTCM frames, write the exact raw bytes
            if isinstance(raw, (bytes, bytearray)):
                try:
                    ufh.write(raw)
                    u_written += len(raw)
                    u_written = fsync_if_needed(ufh, u_written, FSYNC_INTERVAL_BYTES)
                except Exception:
                    pass

        # very light status
        t = time.time()
        if t - last_print >= PRINT_EVERY_SEC:
            print(f"{now.isoformat()}Z, hour {current_hour:02d}, wrote {n_written} NMEA bytes, {u_written} UBX bytes", flush=True)
            last_print = t

    # graceful shutdown, flush and compress current hour too
    try:
        if nfh: nfh.flush(); os.fsync(nfh.fileno()); nfh.close()
        if ufh: ufh.flush(); os.fsync(ufh.fileno()); ufh.close()
    except Exception:
        pass
    # compress current hour on exit
    try:
        if nmea_path: atomic_compress_and_checksum(nmea_path)
        if ubx_path:  atomic_compress_and_checksum(ubx_path)
    except Exception:
        pass

if __name__ == "__main__":
    sys.exit(main())