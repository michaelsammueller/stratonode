#!/bin/bash
#
# Network Connectivity Monitor and Service Recovery Script
# Checks internet connectivity and restarts failed services when connection is restored
#
# This script is run by network-monitor.timer every minute
# It ensures combined.service, combined-monitor.service, and combined-monitor.timer
# are automatically recovered after network outages

PING_HOST="8.8.8.8"
PING_COUNT=2
PING_TIMEOUT=5
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

SERVICES=(
    "combined.service"
    "combined-monitor.service"
    "combined-monitor.timer"
)

# Function to check internet connectivity
check_internet() {
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_HOST" > /dev/null 2>&1
    return $?
}

# Function to restart a failed service
restart_if_failed() {
    local service="$1"

    if systemctl is-failed "$service" &>/dev/null; then
        echo "$LOG_PREFIX $service is in failed state, restarting..."

        systemctl restart "$service"
        sleep 2

        if systemctl is-active "$service" &>/dev/null; then
            echo "$LOG_PREFIX ✓ $service successfully restarted"
            return 0
        else
            echo "$LOG_PREFIX ✗ WARNING: $service failed to restart"
            return 1
        fi
    fi

    return 0
}

# Main logic
if ! check_internet; then
    # No internet - don't try to restart services, they might be failing due to network issues
    # This prevents unnecessary restart attempts during outages
    exit 0
fi

# Internet is available - check and recover failed services
services_restarted=0

for service in "${SERVICES[@]}"; do
    if restart_if_failed "$service"; then
        if systemctl is-failed "$service" &>/dev/null 2>&1; then
            # Service was restarted
            ((services_restarted++))
        fi
    fi
done

if [ $services_restarted -gt 0 ]; then
    echo "$LOG_PREFIX Network monitor recovered $services_restarted service(s)"
fi

exit 0
