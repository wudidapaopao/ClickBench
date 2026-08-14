#!/bin/bash
# chDB diagnostic ROUND 8 on c7a.metal-48xl: validate the buffer-wide arrow
# LIKE predicate (wheel v8) against the round-7 wheel (v7: convoy fix +
# NUMA-capped defaults + arena init), all on one instance.
# J0: default max_threads sanity
# J1/J2: DF track v8 @default vs v7 @default (predicate fix is DF-only)
# J3: Q23 decomposition on v8 (E0 should approach E2)
# J4: native suite v8 @default (no-regression check)
# J5: polars same-harness baseline
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
QPL=../polars-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
RUN8="${DIAG_WHEEL_RUN8:-31767768115}"
RUN7="${DIAG_WHEEL_RUN7:-31756141198}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND8 start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip unzip curl xz-utils >/dev/null 2>&1
NP=$(nproc)
echo "  nproc=$NP"
mkvenv(){
  curl -fsSL -o "$1.zip" "https://nightly.link/chdb-io/chdb-core/actions/runs/$2/chdb-artifacts-linux-x86_64.zip" \
    && unzip -o -q "$1.zip" -d "$1_whl"
  python3 -m venv "$1" && "$1/bin/pip" -q install --upgrade pip >/dev/null 2>&1 \
    && "$1/bin/pip" -q install pandas pyarrow polars "$1_whl"/*.whl >/dev/null 2>&1
  echo "  $1 chdb: $("$1/bin/python" -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1) (run $2)"
}
mkvenv v8 "$RUN8"
mkvenv v7 "$RUN7"

section "[J0] default max_threads sanity"
for V in v8 v7; do
  echo "  $V: $("$V/bin/python" -c "
import chdb
conn = chdb.connect(':memory:')
print('max_threads=', str(conn.query(\"SELECT value FROM system.settings WHERE name='max_threads'\", 'CSV')).strip())
conn.close()" 2>/dev/null | tail -1)"
done

section "[J1/J2] DataFrame track @default: v8 (predicate fix) vs v7 (control)"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
echo "  --- J1: v8 DF @default ---"
v8/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
echo "  --- J2: v7 DF @default ---"
v7/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[J3] Q23 decomposition, v8 DF @default (5 tries each)"
cat > q23x.sql <<'EOF'
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT URL, EventTime FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT count() FROM Python(hits) WHERE URL LIKE '%google%';
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' LIMIT 10;
SELECT * FROM Python(hits) ORDER BY EventTime LIMIT 10;
EOF
echo "  E0=SELECT* topn  E1=2cols topn  E2=count only  E3=SELECT* no-sort  E4=SELECT* topn no-filter"
v8/bin/python "$H" dfqueries "$DFP" q23x.sql 5 "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[LOAD native]"
rm -rf .clickbench
bash ../lib/download-hits-csv
S="$SCHEMA" v8/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute(open(os.environ["S"]).read())
s=time.time();cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
rm -f hits.csv; sync

section "[J4] native suite v8 @default (no-regression check)"
v8/bin/python "$H" queries .clickbench "$Q" "$TRIES" "-" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'

section "[J5] polars same-harness baseline"
DFP="$DFP" QPL="$QPL" TRIES="$TRIES" v8/bin/python - <<'PY' 2>/dev/null
import os, time
import polars as pl
from datetime import date
pl.Config.set_engine_affinity("streaming")
t0=time.time()
df = pl.scan_parquet(os.environ["DFP"]).collect()
df = df.with_columns((pl.col("EventTime")*int(1e6)).cast(pl.Datetime(time_unit="us")), pl.col("EventDate").cast(pl.Date))
df = df.rechunk()
hits = df.lazy()
print(f"POLARS loaded load_s={round(time.time()-t0,1)}")
qs=[l.strip() for l in open(os.environ["QPL"]) if l.strip()]
tries=int(os.environ["TRIES"]); hot=0.0; nf=0
for i,q in enumerate(qs):
    best=None
    for _ in range(tries):
        t=time.perf_counter()
        try:
            eval(q, {"hits":hits,"pl":pl,"date":date})
            e=time.perf_counter()-t
            best=e if best is None or e<best else best
        except Exception as ex:
            pass
    if best is None: nf+=1
    else: hot+=best
    print(f"PQ polars Q{i:<2} min={None if best is None else round(best,4)}")
print(f"POLARS HOT_SUM: {round(hot,2)}s (failed {nf}/{len(qs)})")
PY

echo "############ chDB DIAG ROUND8 done $(date -u +%FT%TZ) ############"
