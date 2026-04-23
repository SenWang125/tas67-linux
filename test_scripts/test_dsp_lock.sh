#!/bin/bash
# TAS6754 DSP io_lock Mutex Stress Test
# Tests concurrent DSP memory access to verify mutex protection during book switching

# Configuration
export CARD="0"
export PREFIX="TAS0"
ITERATIONS=50
CONCURRENT_PROCS=4

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   TAS6754 DSP io_lock Stress Test     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Configuration:"
echo "  Concurrent processes: $CONCURRENT_PROCS"
echo "  Iterations per process: $ITERATIONS"
echo "  Total DSP accesses: $((CONCURRENT_PROCS * ITERATIONS))"
echo ""

# Helper function to read DSP threshold
read_dsp_threshold() {
    local proc_id=$1
    local iter=$2
    local result
    local amixer_err

    # Read RTLDG Open Load Threshold (requires Book 0x8C switch)
    # Capture stderr to see what's actually failing
    amixer_err=$(mktemp)
    result=$(amixer -c $CARD cget name="$PREFIX RTLDG Open Load Threshold" 2>"$amixer_err" | grep ': values=' | awk -F'=' '{print $2}')

    if [ -z "$result" ]; then
        # Log the actual amixer error for first 5 failures per process
        if [ $iter -le 5 ]; then
            echo "ERROR: Process $proc_id iteration $iter: Read failed" >&2
            if [ -s "$amixer_err" ]; then
                echo "  amixer error: $(cat "$amixer_err")" >&2
            fi
        fi
        rm -f "$amixer_err"
        return 1
    fi
    rm -f "$amixer_err"

    # Verify result is reasonable (0x00ffffff is expected value)
    if [ $result -lt 0 ] || [ $result -gt 4294967295 ]; then
        echo "ERROR: Process $proc_id iteration $iter: Invalid value 0x$(printf '%08x' $result)" >&2
        return 1
    fi

    # Store result for verification
    echo $result >> /tmp/dsp_test_proc${proc_id}.log
    return 0
}

# Worker process that hammers DSP reads
worker_process() {
    local proc_id=$1
    local errors=0

    # Clean up log file
    rm -f /tmp/dsp_test_proc${proc_id}.log

    for i in $(seq 1 $ITERATIONS); do
        if ! read_dsp_threshold $proc_id $i; then
            errors=$((errors + 1))
        fi

        # No delay - stress test at maximum rate
    done

    # Report errors and exit with proper code
    if [ $errors -gt 0 ]; then
        echo "PROC_${proc_id}_ERRORS:$errors"
        exit 1
    else
        echo "PROC_${proc_id}_SUCCESS"
        exit 0
    fi
}

# Verify control exists before starting test
echo "Verifying DSP control availability..."
if ! amixer -c $CARD cget name="$PREFIX RTLDG Open Load Threshold" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Control '$PREFIX RTLDG Open Load Threshold' not found on card $CARD${NC}"
    echo "Available TAS controls:"
    amixer -c $CARD | grep -i "TAS"
    exit 1
fi
echo "  ✓ Control found: $PREFIX RTLDG Open Load Threshold"

# Clear dmesg before test
echo ""
echo "Clearing kernel log..."
dmesg -C

echo ""
echo -e "${BLUE}Starting concurrent DSP access test...${NC}"
echo "Spawning $CONCURRENT_PROCS worker processes..."

# Spawn worker processes
start_time=$(date +%s)
for proc_id in $(seq 1 $CONCURRENT_PROCS); do
    worker_process $proc_id 2>/tmp/dsp_test_proc${proc_id}.err &
    PIDS="$PIDS $!"
done

echo "All workers spawned, waiting for completion..."

# Wait for all workers to complete
# Note: We don't check wait exit codes because processes may complete
# so fast that they're already reaped (wait returns -1).
# Instead, we validate success by checking the log files.
for pid in $PIDS; do
    wait $pid 2>/dev/null
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo ""
echo -e "${BLUE}Test completed in ${elapsed} seconds${NC}"
echo ""

# Analyze results
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}           RESULTS ANALYSIS             ${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Count successful reads per process
echo "Per-process statistics:"
TOTAL_SUCCESSFUL_READS=0
TOTAL_ERRORS=0
for proc_id in $(seq 1 $CONCURRENT_PROCS); do
    if [ -f /tmp/dsp_test_proc${proc_id}.log ]; then
        count=$(wc -l < /tmp/dsp_test_proc${proc_id}.log)
        TOTAL_SUCCESSFUL_READS=$((TOTAL_SUCCESSFUL_READS + count))

        # Check for value consistency
        unique_values=$(sort -u /tmp/dsp_test_proc${proc_id}.log | wc -l)

        echo "  Process $proc_id: $count/$ITERATIONS successful reads, $unique_values unique value(s)"

        if [ $count -lt $ITERATIONS ]; then
            echo -e "    ${RED}✗ Missing $((ITERATIONS - count)) reads${NC}"
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        fi

        if [ $unique_values -gt 1 ]; then
            echo -e "    ${YELLOW}⚠ Multiple different values detected (possible corruption):${NC}"
            sort -u /tmp/dsp_test_proc${proc_id}.log | while read val; do
                echo "      - 0x$(printf '%08x' $val)"
            done
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
        fi

        # Show error samples if reads failed
        if [ -s /tmp/dsp_test_proc${proc_id}.err ]; then
            err_count=$(wc -l < /tmp/dsp_test_proc${proc_id}.err)
            if [ $err_count -gt 0 ]; then
                echo -e "    ${YELLOW}⚠ $err_count error messages (showing first 3):${NC}"
                head -6 /tmp/dsp_test_proc${proc_id}.err | sed 's/^/      /'
            fi
        fi
    else
        echo -e "  Process $proc_id: ${RED}No log file (process may have crashed)${NC}"
        # Show error file if available
        if [ -s /tmp/dsp_test_proc${proc_id}.err ]; then
            echo -e "    ${RED}Error output:${NC}"
            head -10 /tmp/dsp_test_proc${proc_id}.err | sed 's/^/      /'
        fi
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi
done

echo ""
TOTAL_EXPECTED=$((CONCURRENT_PROCS * ITERATIONS))
echo "Total operations: $TOTAL_EXPECTED"
echo "Successful reads: $TOTAL_SUCCESSFUL_READS"
if [ $TOTAL_EXPECTED -gt 0 ]; then
    SUCCESS_RATE=$(echo "scale=1; ($TOTAL_SUCCESSFUL_READS / $TOTAL_EXPECTED) * 100" | bc)
    echo "Success rate: ${SUCCESS_RATE}%"
else
    echo "Success rate: N/A"
fi

# Check kernel log for errors
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}         KERNEL LOG ANALYSIS            ${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

I2C_ERRORS=$(dmesg | grep -iE "i2c.*error|i2c.*timeout|i2c.*0x70" | wc -l)
BOOK_ERRORS=$(dmesg | grep -iE "tas6754.*book.*fail|tas6754.*select.*book" | wc -l)
MUTEX_ERRORS=$(dmesg | grep -iE "tas6754.*lock|tas6754.*mutex" | wc -l)
GENERAL_ERRORS=$(dmesg | grep -iE "tas6754.*error" | wc -l)

echo "I2C errors: $I2C_ERRORS"
echo "Book switching errors: $BOOK_ERRORS"
echo "Mutex/locking errors: $MUTEX_ERRORS"
echo "General TAS6754 errors: $GENERAL_ERRORS"

if [ $I2C_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent I2C errors:${NC}"
    dmesg | grep -iE "i2c.*error|i2c.*timeout" | tail -5
fi

if [ $BOOK_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${RED}Book switching errors detected:${NC}"
    dmesg | grep -iE "tas6754.*book"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
fi

if [ $GENERAL_ERRORS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Recent TAS6754 errors:${NC}"
    dmesg | grep -iE "tas6754.*error" | tail -5
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}           FINAL VERDICT                ${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

TOTAL_EXPECTED=$((CONCURRENT_PROCS * ITERATIONS))
if [ $TOTAL_ERRORS -eq 0 ] && [ $I2C_ERRORS -eq 0 ] && [ $BOOK_ERRORS -eq 0 ] && [ $TOTAL_SUCCESSFUL_READS -eq $TOTAL_EXPECTED ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   io_lock MUTEX TEST PASSED! ✓        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "All $TOTAL_EXPECTED concurrent DSP accesses completed successfully."
    echo "Book switching is properly protected by io_lock mutex."
    echo ""
    # Cleanup on success
    rm -f /tmp/dsp_test_proc*.log /tmp/dsp_test_proc*.err
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   io_lock MUTEX TEST FAILED! ✗        ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Detected $TOTAL_ERRORS error(s) during concurrent access."
    echo "This may indicate:"
    echo "  - Race condition in book switching"
    echo "  - Missing or ineffective mutex protection"
    echo "  - I2C bus contention issues"
    echo ""
    echo "Debug files preserved in /tmp/dsp_test_proc*.{log,err} for inspection"
    exit 1
fi
