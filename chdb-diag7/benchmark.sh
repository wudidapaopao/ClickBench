#!/bin/bash
# chDB diagnostic ROUND 7 on c7a.metal-48xl: validate the NUMA-capped default
# max_threads + MergeTree arena init (wheel v7) against the round-6 wheel (v6,
# convoy fix only), plus decompose the Q23 DataFrame-track gap vs polars.
# I0: default max_threads sanity on both wheels
# I1/I2: native suite v7@default vs v6@96 (same-instance A/B; arena + cap mechanics)
# I3/I4: DF track v7@default vs v6@96
# I5: Q23 decomposition on v7 DF (wide TopN: what part costs 0.45s?)
# I6: polars same-harness baseline
# I7: native v7 @192 explicit (cap must not degrade explicit settings; Q32 check)
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
QPL=../polars-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
RUN7="${DIAG_WHEEL_RUN7:-31756141198}"
RUN6="${DIAG_WHEEL_RUN6:-31751999023}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND7 start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip unzip curl xz-utils >/dev/null 2>&1
NP=$(nproc)
echo "  nproc=$NP"
mkvenv(){ # $1 venv dir, $2 run id
  curl -fsSL -o "$1.zip" "https://nightly.link/chdb-io/chdb-core/actions/runs/$2/chdb-artifacts-linux-x86_64.zip" \
    && unzip -o -q "$1.zip" -d "$1_whl"
  python3 -m venv "$1" && "$1/bin/pip" -q install --upgrade pip >/dev/null 2>&1 \
    && "$1/bin/pip" -q install pandas pyarrow polars "$1_whl"/*.whl >/dev/null 2>&1
  echo "  $1 chdb: $("$1/bin/python" -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1) (run $2)"
}
mkvenv v7 "$RUN7"
mkvenv v6 "$RUN6"

section "[I0] default max_threads sanity"
for V in v7 v6; do
  echo "  $V: $("$V/bin/python" -c "
import chdb
conn = chdb.connect(':memory:')
print('max_threads=', str(conn.query(\"SELECT value FROM system.settings WHERE name='max_threads'\", 'CSV')).strip())
conn.close()" 2>/dev/null | tail -1)"
done

section "[LOAD native]"
rm -rf .clickbench
bash ../lib/download-hits-csv
S="$SCHEMA" v7/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute(open(os.environ["S"]).read())
s=time.time();cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
rm -f hits.csv; sync

section "[I1] native suite v7 @default (cap active)"
v7/bin/python "$H" queries .clickbench "$Q" "$TRIES" "-" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'

section "[I2] native suite v6 @96 (same-instance control)"
v6/bin/python "$H" queries .clickbench "$Q" "$TRIES" 96 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'

section "[I7] native suite v7 @192 explicit (cap must not bind)"
v7/bin/python "$H" queries .clickbench "$Q" "$TRIES" 192 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'

section "[I3/I4] DataFrame track"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
echo "  --- I3: v7 DF @default ---"
v7/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
echo "  --- I4: v6 DF @96 ---"
v6/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 96 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[I5] Q23 decomposition, v7 DF @default (5 tries each)"
Q23REF=$(sed -n '24p' "$QDF")
echo "  reference Q23: $Q23REF"
cat > q23x.sql <<'EOF'
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT URL, EventTime FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT count() FROM Python(hits) WHERE URL LIKE '%google%';
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' LIMIT 10;
SELECT WatchID, ClientIP, EventTime FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT * FROM Python(hits) ORDER BY EventTime LIMIT 10;
EOF
echo "  E0=SELECT* topn  E1=2cols topn  E2=count only  E3=SELECT* no-sort  E4=3numcols topn  E5=SELECT* topn no-filter"
v7/bin/python "$H" dfqueries "$DFP" q23x.sql 5 "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[I6] polars same-harness baseline"
DFP="$DFP" QPL="$QPL" TRIES="$TRIES" v7/bin/python - <<'PY' 2>/dev/null
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

echo "############ chDB DIAG ROUND7 done $(date -u +%FT%TZ) ############"
