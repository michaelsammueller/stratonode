#!/bin/bash
#
# UBX Parser Health Monitor
#
# Monitors the combined service for UBX parser desynchronization
# and automatically restarts the service if stuck in an error loop.
#
# Usage: Run via cron every minute:
#   * * * * * /home/strato/stratonode/sender/monitor_ubx_health.sh
#

SERVICE_NAME="combined"
LOG_FILE="/data/stratocentral/logs/ubx_monitor.log"
ERROR_THRESHOLD=10  # Restart if more than this many errors in 1 minute

# Ensure log directory exists (should already exist from service setup)
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Count UBX "too large" errors in the last minute
ERROR_COUNT=$(journalctl -u "$SERVICE_NAME" -S "1 minute ago" --no-pager 2>/dev/null | \
    grep -c "UBX message too large")

# Log current status
echo "[$(date '+%Y-%m-%d %H:%M:%S')] UBX errors in last minute: $ERROR_COUNT" >> "$LOG_FILE"

# Check if we're over the threshold
if [ "$ERROR_COUNT" -gt "$ERROR_THRESHOLD" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: UBX parser stuck ($ERROR_COUNT errors), restarting $SERVICE_NAME" >> "$LOG_FILE"

    # Log to syslog as well
    logger -t ubx-monitor "UBX parser desynchronized ($ERROR_COUNT errors), restarting $SERVICE_NAME"

    # Restart the service
    sudo systemctl restart "$SERVICE_NAME"

    # Log restart result
    sleep 2
    if sudo systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Service restarted successfully" >> "$LOG_FILE"
        logger -t ubx-monitor "Service $SERVICE_NAME restarted successfully"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Service failed to restart!" >> "$LOG_FILE"
        logger -t ubx-monitor "ERROR: Service $SERVICE_NAME failed to restart!"
    fi
fi

# Rotate log file if it gets too large (> 10MB)
if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt 10485760 ]; then
    mv "$LOG_FILE" "$LOG_FILE.old"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" >> "$LOG_FILE"
fi
