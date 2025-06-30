#!/bin/bash

machine_name=${1}
load_time=${2:-0}

TRIES=3
QUERY_COUNT=43
RESULT_FILE="results/${machine_name}.json"
declare -a results=()
for ((i=0; i<QUERY_COUNT; i++)); do
    nulls=$(printf 'null%.0s' $(seq 1 $TRIES))
    results[i]="[${nulls// /,}]"
done
mkdir -p results

q=0
while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo "$query"
    output=$(./query.py <<< "${query}" 2>&1)
    IFS=',' read -r t1 t2 t3 <<< "$(echo "$output" | tail -1)"

    results[$((q))]="[${t1:-null},${t2:-null},${t3:-null}]"
    echo "Query $((q+1)) results: ${results[$((q))]}"
    ((q++))
done < queries.sql

echo '{
    "system": "chDB",
    "date": "'$(date +%Y-%m-%d)'",
    "machine": "'$machine_name'",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "",
    "tags": [
        "C++",
        "column-oriented",
        "ClickHouse derivative",
        "embedded",
        "stateless",
        "serverless"
    ],
    "load_time": '$load_time',
    "data_size": 0,
    "result": [
'"$(IFS=,; printf '%s,\n' "${results[@]}" | sed '$s/,$//')"'
    ]
}' > $RESULT_FILE

echo "Benchmark completed. Results saved to $RESULT_FILE"
