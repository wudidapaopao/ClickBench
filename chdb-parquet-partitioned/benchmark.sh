#!/bin/bash

machine=${1:-"c6a.4xlarge"}
case "$machine" in
    "c6a.4xlarge"|"c6a.metal")
        machine_name="$machine"
        ;;
    *)
        echo "Invalid machine parameter. Allowed: c6a.4xlarge or c6a.metal"
        exit 1
        ;;
esac

# Install
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv
python3 -m venv myenv
source myenv/bin/activate
pip install psutil
pip install chdb

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Run the queries
./run.sh $machine_name 2>&1 | tee log.txt

echo "Load time: 0"
echo "Data size: $(du -bcs hits*.parquet | grep total)"

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
