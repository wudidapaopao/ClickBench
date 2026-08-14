#!/bin/bash
# chDB diagnostic ROUND 10b: max_threads A/B with the final wheels (v10) on
# c6a.metal / c7a.metal-48xl / c8g.metal-24xl. DataFrame track only.
# K0: default max_threads sanity (expect 96 on all three machines)
# K1: DF @default   K2: DF @96 explicit   K3: DF @192 explicit
set +e
QDF=../chdb-dataframe/queries.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
RUN10_X86="${DIAG_WHEEL_RUN10_X86:-31825106389}"
RUN10_ARM="${DIAG_WHEEL_RUN10_ARM:-31825106331}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND10b start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip unzip curl xz-utils >/dev/null 2>&1
NP=$(nproc); ARCH=$(uname -m)
echo "  nproc=$NP arch=$ARCH instance=$(curl -s -m 2 http://169.254.169.254/latest/meta-data/instance-type || echo unknown)"
if [ "$ARCH" = "aarch64" ]; then SUF=linux-aarch64; RUNNEW="$RUN10_ARM"; else SUF=linux-x86_64; RUNNEW="$RUN10_X86"; fi
curl -fsSL -o w.zip "https://nightly.link/chdb-io/chdb-core/actions/runs/$RUNNEW/chdb-artifacts-$SUF.zip" && unzip -o -q w.zip -d w_whl
python3 -m venv v10 && v10/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v10/bin/pip -q install pandas pyarrow w_whl/*.whl >/dev/null 2>&1
echo "  v10 chdb: $(v10/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1) (run $RUNNEW)"

section "[K0] default max_threads"
v10/bin/python -c "
import chdb
conn = chdb.connect(':memory:')
print('  max_threads default =', str(conn.query(\"SELECT value FROM system.settings WHERE name='max_threads'\", 'CSV')).strip())
conn.close()" 2>/dev/null | tail -1

if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
section "[K1] DF @default"
v10/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
section "[K2] DF @96 explicit"
v10/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 96 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
section "[K3] DF @192 explicit"
v10/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 192 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

echo "############ chDB DIAG ROUND10b done $(date -u +%FT%TZ) ############"
