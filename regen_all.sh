#!/bin/bash
# Quick wrapper to regenerate the benchmark report from the latest results
RESULTS_DIR=$(ls -dt ~/Development/benchmarks/results/pgss_matrix_* 2>/dev/null | head -1)

if [[ -z "$RESULTS_DIR" ]]; then
    echo "No results directory found in ~/Development/benchmarks/results/"
    exit 1
fi

echo "Using: $RESULTS_DIR"
~/Development/benchmarks/regen_report.sh "$RESULTS_DIR"
