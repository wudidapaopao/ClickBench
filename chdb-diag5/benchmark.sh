#!/bin/bash
# chDB diagnostic ROUND 5 on c7a.metal-48xl.
# G1: OPENBLAS thread-pool kill A/B (64 in-process BLAS threads vs engine's 192)
# G2: gdb/eu-stack sampling with FIXED debuginfo placement -> name the mutex
# G3: native suite combos: threads x OPENBLAS=1 (+ use_concurrency_control=0 probe)
# G4: DataFrame track with best combo
# G6: polars same-harness baseline (their exact track semantics)
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
QPL=../polars-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
QI="${DIAG_QI:-10}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND5 start $(date -u +%FT%TZ) ############"

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip gdb elfutils sysstat numactl xz-utils curl \
     linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" >/dev/null 2>&1
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid' 2>/dev/null
sudo sh -c 'echo 0 > /proc/sys/kernel/yama/ptrace_scope' 2>/dev/null
python3 -m venv v267 && v267/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v267/bin/pip -q install pandas pyarrow polars 'chdb-core==26.7.0' >/dev/null 2>&1
echo "  chdb $(v267/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1), polars $(v267/bin/python -c 'import polars;print(polars.__version__)' 2>/dev/null | tail -1)"
echo "  --- debuginfo (robust placement) ---"
curl -fsSL -o dbg.tar.xz "https://github.com/chdb-io/chdb-core/releases/download/v26.7.0/linux-x86_64-debuginfo.tar.xz" && tar xf dbg.tar.xz
SO=$(v267/bin/python -c "import chdb,glob,os;print(glob.glob(os.path.join(os.path.dirname(chdb.__file__),'..','_chdb*.so'))[0])" 2>/dev/null)
[ -z "$SO" ] && SO=$(find v267/lib -name '_chdb*.so' | head -1)
DBG=$(find . -name '*_chdb*debug*' -o -name '*debug*chdb*' 2>/dev/null | grep -v tar | head -1)
echo "  SO=$SO"; echo "  DBG=$DBG"
[ -n "$SO" ] && [ -n "$DBG" ] && cp "$DBG" "$(dirname "$SO")/$(basename "${SO%.so}.so.debug")" \
  && cp "$DBG" "$(dirname "$SO")/_chdb.abi3.so.debug" 2>/dev/null && echo "  debuginfo placed OK"
NP=$(nproc)

section "[LOAD native]"
rm -rf .clickbench
bash ../lib/download-hits-csv
S="$SCHEMA" v267/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute(open(os.environ["S"]).read())
s=time.time();cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
rm -f hits.csv; sync

section "[G1] OPENBLAS thread-pool A/B: Q$QI loop @$NP (iters/15s, higher=better) + thread census"
census(){ v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 12 >/dev/null 2>&1 & P=$!; sleep 6; \
  echo "    threads=$(ls /proc/$P/task 2>/dev/null | wc -l)  blas=$(grep -l blas /proc/$P/task/*/comm 2>/dev/null | wc -l)"; \
  kill $P 2>/dev/null; wait $P 2>/dev/null; }
echo "  (a) default env:"; census
run_loop(){ echo "  --- $1 ---"; shift; "$@" v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 15 2>/dev/null | grep LOOPQ; }
run_loop "(b) default" env
run_loop "(c) OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1" env OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
echo "  (d) OPENBLAS=1 thread census:"; OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 census

section "[G2] name the mutex: gdb + eu-stack sampling on Q$QI @$NP"
v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 90 >/dev/null 2>&1 &
PID=$!; sleep 8
for i in 1 2 3; do
  timeout -k 5 180 gdb -p "$PID" -batch -ex 'set pagination off' -ex 'thread apply all bt 8' > "gdb_$i.txt" 2>/dev/null
  timeout -k 5 60 eu-stack -p "$PID" > "eu_$i.txt" 2>/dev/null
  sleep 2
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
python3 - <<'PY'
import re, glob, collections
waiters=collections.Counter(); runners=collections.Counter(); n=0
def frames_from(f, gdb):
    cur=[]; stacks=[]
    for line in open(f, errors='replace'):
        if (gdb and line.startswith('Thread ')) or (not gdb and re.match(r'TID \d+', line)):
            if cur: stacks.append(cur); cur=[]
        m=re.match(r'#\d+\s+(?:0x[0-9a-f]+ in )?(.+)', line.strip())
        if m:
            fr=re.sub(r'\s*\(.*','',m.group(1)).strip()
            cur.append(fr)
    if cur: stacks.append(cur)
    return stacks
for f in sorted(glob.glob('gdb_*.txt'))+sorted(glob.glob('eu_*.txt')):
    for st in frames_from(f, f.startswith('gdb')):
        n+=1
        if any(re.search(r'futex|lll_lock|pthread_mutex_lock|pthread_cond',fr) for fr in st):
            hot=[fr for fr in st if not re.search(r'futex|lll|pthread|__GI|clone|start_thread|\?\?',fr)]
            waiters[' <- '.join(hot[:4]) or '(all-unresolved)'] += 1
        else:
            hot=[fr for fr in st if not re.search(r'clone|start_thread|\?\?',fr)]
            runners[' <- '.join(hot[:3]) or '(unresolved)'] += 1
print(f"  stacks={n}")
print("  === BLOCKED-on-lock callers ===")
for s,c in waiters.most_common(14): print(f"  {c:>5}  {s[:230]}")
print("  === RUNNING (contrast) ===")
for s,c in runners.most_common(6): print(f"  {c:>5}  {s[:160]}")
PY

section "[G3] native suite combos (hot=min of $TRIES)"
suite(){ echo "  --- $1 ---"; shift; MT=$1; shift; "$@" v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" "$MT" 2>/dev/null | grep HOT_SUM; }
suite "(a) @$NP + OPENBLAS=1" - env OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
suite "(b) @96  + OPENBLAS=1" 96 env OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
suite "(c) @64  + OPENBLAS=1" 64 env OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
echo "  --- (d) @$NP + use_concurrency_control=0 ---"
v267/bin/python - <<PY 2>/dev/null | grep HOT_SUM
import time
from chdb import session as chs
s=chs.Session(".clickbench")
qs=[l.strip().rstrip(";") for l in open("$Q") if l.strip()]
hot=0.0
for q in qs:
    best=None
    for _ in range($TRIES):
        t=time.perf_counter()
        try:
            s.query(q+" SETTINGS max_threads=$NP, use_concurrency_control=0")
            e=time.perf_counter()-t
            best=e if best is None or e<best else best
        except Exception: pass
    if best: hot+=best
print(f"HOT_SUM ucc0 @$NP: {round(hot,2)}s")
s.close()
PY

section "[G4] DataFrame track with best combos"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
echo "  --- @96 + OPENBLAS=1 ---"
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 v267/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 96 2>/dev/null | grep -E 'DF loaded|HOT_SUM'
echo "  --- @64 + OPENBLAS=1 ---"
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 v267/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 64 2>/dev/null | grep -E 'DF loaded|HOT_SUM'

section "[G6] polars same-harness baseline (their exact track semantics)"
DFP="$DFP" QPL="$QPL" TRIES="$TRIES" v267/bin/python - <<'PY' 2>/dev/null
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

echo "############ chDB DIAG ROUND5 done $(date -u +%FT%TZ) ############"
