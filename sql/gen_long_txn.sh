#!/bin/bash
# Generate a SQL file with a single transaction containing 5000 unique queries.
# Usage: ./gen_long_txn.sh > long_txn_5000.sql
#        psql -f long_txn_5000.sql  (will block at the end waiting for input)

N=${1:-5000}

echo "BEGIN;"
for i in $(seq 1 $N); do
    printf "SELECT 1 WHERE 'long_txn_%05d' IS NOT NULL;\n" "$i"
done
echo "-- Transaction intentionally left open. Press Ctrl+C or run ROLLBACK to end."
echo "SELECT pg_sleep(3600);"
echo "ROLLBACK;"
