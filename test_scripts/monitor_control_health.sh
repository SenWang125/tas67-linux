#!/bin/bash
# Monitor TAS6754 control health during stress test
# Checks every second if LDG control still exists

CARD="0"
PREFIX="TAS0"
LOG_FILE="/tmp/control_health.log"

echo "TAS6754 Control Health Monitor"
echo "Checking: $PREFIX DC LDG Trigger"
echo "Logging to: $LOG_FILE"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Clear log
> $LOG_FILE

# Counter
CHECK_COUNT=0
FAILURES=0
FIRST_FAILURE=""

while true; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    TIMESTAMP=$(date '+%H:%M:%S')

    # Try to access the control
    if amixer -c $CARD cget name="$PREFIX DC LDG Trigger" >/dev/null 2>&1; then
        STATUS="OK"
        echo "[$TIMESTAMP] Check $CHECK_COUNT: ✓ Control accessible" | tee -a $LOG_FILE
    else
        STATUS="MISSING"
        FAILURES=$((FAILURES + 1))
        if [ -z "$FIRST_FAILURE" ]; then
            FIRST_FAILURE="$TIMESTAMP (after $CHECK_COUNT checks)"
        fi
        echo "[$TIMESTAMP] Check $CHECK_COUNT: ✗ CONTROL MISSING!" | tee -a $LOG_FILE

        # Log additional info on first failure
        if [ $FAILURES -eq 1 ]; then
            echo "  First failure detected!" | tee -a $LOG_FILE
            echo "  Kernel log:" | tee -a $LOG_FILE
            dmesg | tail -5 | sed 's/^/    /' | tee -a $LOG_FILE
            echo "  Available controls:" | tee -a $LOG_FILE
            amixer -c $CARD | grep -i "$PREFIX" | wc -l | xargs echo "    Total:" | tee -a $LOG_FILE
        fi
    fi

    sleep 1
done
