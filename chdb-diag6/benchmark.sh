#!/bin/bash
# chDB diagnostic ROUND 6 on c7a.metal-48xl: validate the ctl_mtx convoy fix.
# Fixed wheel = PR #182 CI run 31751999023 (je_vsallocx replaces mallctl("arenas.lookup")
# in Allocator freeImpl). Control = chdb-core==26.7.0 from PyPI.
# H1: Q10 loop A/B @nproc, fixed vs 26.7.0 (iters/15s + ctx-switch + sys%: symbol-free convoy signal)
# H2: native suite, fixed wheel @192/@96/@64 (per-query + HOT_SUM)
# H3: native suite, 26.7.0 control @192 (same-machine baseline)
# H4: DataFrame track, fixed wheel @default/@96/@64
# H5: polars same-harness baseline
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
QPL=../polars-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
QI="${DIAG_QI:-10}"
WHEEL_RUN="${DIAG_WHEEL_RUN:-31751999023}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND6 start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip sysstat unzip curl xz-utils >/dev/null 2>&1
NP=$(nproc)
echo "  nproc=$NP"
echo "  --- venv vfix: custom wheel from chdb-core CI run $WHEEL_RUN ---"
curl -fsSL -o whl.zip "https://nightly.link/chdb-io/chdb-core/actions/runs/$WHEEL_RUN/chdb-artifacts-linux-x86_64.zip" \
  && unzip -o -q whl.zip -d whl
python3 -m venv vfix && vfix/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && vfix/bin/pip -q install pandas pyarrow polars whl/*.whl >/dev/null 2>&1
echo "  vfix chdb: $(vfix/bin/python -c 'import chdb;print(chdb.__version__, chdb.__file__)' 2>/dev/null | tail -1)"
echo "  --- venv v267: control chdb-core==26.7.0 ---"
python3 -m venv v267 && v267/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v267/bin/pip -q install pandas pyarrow 'chdb-core==26.7.0' >/dev/null 2>&1
echo "  v267 chdb: $(v267/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1)"

section "[LOAD native]"
rm -rf .clickbench
bash ../lib/download-hits-csv
S="$SCHEMA" vfix/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute(open(os.environ["S"]).read())
s=time.time();cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
rm -f hits.csv; sync

section "[H1] convoy A/B: Q$QI loop @$NP for 15s (higher iters = better; low cs/s + low %sys = convoy gone)"
ab(){ # $1 label, $2 venv
  echo "  --- $1 ---"
  vmstat 1 12 > "vm_$1.txt" 2>/dev/null &
  VP=$!
  "$2/bin/python" "$H" loopq .clickbench "$Q" "$QI" "$NP" 15 2>/dev/null | grep LOOPQ | sed 's/^/  /'
  wait $VP 2>/dev/null
  python3 - "$1" <<'PY'
import sys
rows=[l.split() for l in open(f"vm_{sys.argv[1]}.txt") if l.strip() and l.split()[0].isdigit()]
if rows:
    cs=[int(r[11]) for r in rows[2:]]; sy=[int(r[13]) for r in rows[2:]]
    print(f"  vmstat: avg_cs/s={sum(cs)//max(1,len(cs))}  avg_sys%={sum(sy)/max(1,len(sy)):.0f}")
PY
}
ab fixed vfix
ab v2670 v267

section "[H2] native suite, FIXED wheel (hot=min of $TRIES)"
for MT in "-" 96 64; do
  echo "  --- fixed @${MT/-/$NP} ---"
  vfix/bin/python "$H" queries .clickbench "$Q" "$TRIES" "$MT" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'
done

section "[H3] native suite, 26.7.0 control @$NP"
v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" "-" 2>/dev/null | grep -E '^PQ|HOT_SUM' | sed 's/^/  /'

section "[H4] DataFrame track, FIXED wheel"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
for MT in "-" 96 64; do
  echo "  --- fixed DF @${MT/-/default} ---"
  vfix/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "$MT" 2>/dev/null | grep -E 'DF loaded|^PQ|HOT_SUM' | sed 's/^/  /'
done

section "[H5] polars same-harness baseline"
DFP="$DFP" QPL="$QPL" TRIES="$TRIES" vfix/bin/python - <<'PY' 2>/dev/null
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

echo "############ chDB DIAG ROUND6 done $(date -u +%FT%TZ) ############"
