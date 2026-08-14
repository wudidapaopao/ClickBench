#!/bin/bash
# chDB diagnostic ROUND 9: validate the _ndarray column-resolution fix (v9).
# Arch-aware: on x86 (c7a.metal-48xl) v9 vs the round-8 wheel; on aarch64
# (c8g.metal-24xl) v9 vs chdb-core==26.7.0 from PyPI (first fixed wheel on ARM).
# J0: default max_threads sanity
# J1/J2: DF track v9 @default vs control @default
# J3: Q23 decomposition on v9 (E0 should approach E2 now)
# J4: native suite v9 @default (+ control on aarch64, where we have no prior data)
# J5: polars same-harness baseline
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
QPL=../polars-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
RUN9_X86="${DIAG_WHEEL_RUN9_X86:-31774629193}"
RUN9_ARM="${DIAG_WHEEL_RUN9_ARM:-31774629343}"
RUN8_X86="${DIAG_WHEEL_RUN8_X86:-31767768115}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND9 start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip unzip curl xz-utils >/dev/null 2>&1
NP=$(nproc); ARCH=$(uname -m)
echo "  nproc=$NP arch=$ARCH"
if [ "$ARCH" = "aarch64" ]; then SUF=linux-aarch64; RUNNEW="$RUN9_ARM"; else SUF=linux-x86_64; RUNNEW="$RUN9_X86"; fi
mkvenv(){ # $1 venv, $2 run id (wheel from CI) or "pypi" (chdb-core==26.7.0)
  python3 -m venv "$1" && "$1/bin/pip" -q install --upgrade pip >/dev/null 2>&1
  if [ "$2" = "pypi" ]; then
    "$1/bin/pip" -q install pandas pyarrow polars 'chdb-core==26.7.0' >/dev/null 2>&1
  else
    curl -fsSL -o "$1.zip" "https://nightly.link/chdb-io/chdb-core/actions/runs/$2/chdb-artifacts-$SUF.zip" \
      && unzip -o -q "$1.zip" -d "$1_whl"
    "$1/bin/pip" -q install pandas pyarrow polars "$1_whl"/*.whl >/dev/null 2>&1
  fi
  echo "  $1 chdb: $("$1/bin/python" -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1) (src $2)"
}
mkvenv v9 "$RUNNEW"
if [ "$ARCH" = "aarch64" ]; then mkvenv vctl pypi; else mkvenv vctl "$RUN8_X86"; fi

section "[J0] default max_threads sanity"
for V in v9 vctl; do
  echo "  $V: $("$V/bin/python" -c "
import chdb
conn = chdb.connect(':memory:')
print('max_threads=', str(conn.query(\"SELECT value FROM system.settings WHERE name='max_threads'\", 'CSV')).strip())
conn.close()" 2>/dev/null | tail -1)"
done

section "[J1/J2] DataFrame track @default: v9 vs control"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
echo "  --- J1: v9 DF @default ---"
v9/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
echo "  --- J2: control DF @default ---"
vctl/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[J3] Q23 decomposition, v9 DF @default (5 tries each)"
cat > q23x.sql <<'EOF'
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT URL, EventTime FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
SELECT count() FROM Python(hits) WHERE URL LIKE '%google%';
SELECT * FROM Python(hits) WHERE URL LIKE '%google%' LIMIT 10;
SELECT * FROM Python(hits) ORDER BY EventTime LIMIT 10;
EOF
echo "  E0=SELECT* topn  E1=2cols topn  E2=count only  E3=SELECT* no-sort  E4=SELECT* topn no-filter"
v9/bin/python "$H" dfqueries "$DFP" q23x.sql 5 "-" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'

section "[LOAD native]"
rm -rf .clickbench
bash ../lib/download-hits-csv
S="$SCHEMA" v9/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute(open(os.environ["S"]).read())
s=time.time();cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
rm -f hits.csv; sync

section "[J4] native suite v9 @default"
v9/bin/python "$H" queries .clickbench "$Q" "$TRIES" "-" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'
if [ "$ARCH" = "aarch64" ]; then
  echo "  --- J4b: control (26.7.0) native @default ---"
  vctl/bin/python "$H" queries .clickbench "$Q" "$TRIES" "-" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'
fi

section "[J5] polars same-harness baseline"
DFP="$DFP" QPL="$QPL" TRIES="$TRIES" v9/bin/python - <<'PY' 2>/dev/null
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

echo "############ chDB DIAG ROUND9 done $(date -u +%FT%TZ) ############"
