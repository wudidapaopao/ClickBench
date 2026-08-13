#!/bin/bash
# chDB diagnostic ROUND 3 on one machine (c7a.metal-48xl).
# E1: per-query breakdown @nproc vs @96 (where does the suite-level penalty live?)
# E2: perf stat + perf record on the top per-query regressors (not the heavy query)
# E3: numactl single-socket binding vs unbound @96; per-socket busy sampling
# E5: clickhouse-local, ONE persistent session, @default vs @96 (clean form-factor split)
# E4: DataFrame track max_threads sweep + numactl binding (Polars question)
# All output -> stdout -> ClickBench log -> pastila.
set +e
Q=../chdb/queries.sql
QDF=../chdb-dataframe/queries.sql
SCHEMA=../chdb/create.sql
H=./harness3.py
TRIES="${DIAG_TRIES:-3}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND3 start $(date -u +%FT%TZ) ############"

section "[FACTS]"
echo "nproc=$(nproc)"
lscpu | grep -iE 'Model name|^CPU\(s\)|Core\(s\) per socket|Socket\(s\)|NUMA node\(s\)'
numactl --hardware 2>&1 | grep -E 'available:|node . cpus:|node . size:' | head -8

section "[SETUP]"
if [ -z "${DIAG_DATA_PARQUET:-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y python3-venv python3-pip sysstat numactl xz-utils curl \
       linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" >/dev/null 2>&1
fi
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid' 2>/dev/null
python3 -m venv v267 && v267/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v267/bin/pip -q install pandas pyarrow 'chdb-core==26.7.0' >/dev/null 2>&1
echo "  chdb $(v267/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1)"
NP=$(nproc)

section "[LOAD native]"
rm -rf .clickbench
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then
  DP="$DIAG_DATA_PARQUET" v267/bin/python - <<'PY'
import os,time
from chdb import dbapi
c=dbapi.connect(path=".clickbench");cur=c.cursor();cur.execute("CREATE DATABASE IF NOT EXISTS clickbench")
s=time.time()
cur.execute("CREATE TABLE clickbench.hits ENGINE=MergeTree ORDER BY tuple() AS "
            "SELECT * REPLACE(toDateTime(EventTime) AS EventTime, toDate(EventDate) AS EventDate) "
            f"FROM file('{os.environ['DP']}')")
cur.execute("SELECT count() FROM clickbench.hits");print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close();c.close()
PY
else
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
fi

section "[E1] per-query breakdown: @$NP vs @96 (native, $TRIES tries, per-query lines included)"
v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" -  2>/dev/null | tee e1_np.txt | grep HOT_SUM
v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" 96 2>/dev/null | tee e1_96.txt | grep HOT_SUM
echo "  --- delta table (哪些查询贡献了 @$NP 的惩罚) ---"
python3 - <<'PY'
import re
def parse(p):
    d={}
    for l in open(p):
        m=re.match(r'PQ \S+ Q(\d+)\s+min=([0-9.]+|None)',l)
        if m and m.group(2)!='None': d[int(m.group(1))]=float(m.group(2))
    return d
a,b=parse('e1_np.txt'),parse('e1_96.txt')
rows=sorted(((q,a[q],b[q],a[q]-b[q]) for q in a if q in b),key=lambda r:-r[3])
tot=sum(r[3] for r in rows); pos=sum(r[3] for r in rows if r[3]>0)
print(f"  sum(delta)={tot:+.2f}s  sum(positive)={pos:+.2f}s")
print(f"  {'Q':>4} {'@NP':>8} {'@96':>8} {'delta':>8}")
for q,x,y,d in rows[:12]:
    print(f"  Q{q:<3} {x:>8.3f} {y:>8.3f} {d:>+8.3f}")
open('worst.txt','w').write("\n".join(str(q) for q,_,_,d in rows[:3] if d>0.03))
PY

section "[E2] perf on the top regressors (stat + record, @$NP vs @96)"
[ -s worst.txt ] || echo "32" > worst.txt
curl -fsSL -o dbg.tar.xz "https://github.com/chdb-io/chdb-core/releases/download/v26.7.0/linux-x86_64-debuginfo.tar.xz" 2>/dev/null && tar xf dbg.tar.xz 2>/dev/null
SO=$(v267/bin/python -c "import _chdb;print(_chdb.__file__)" 2>/dev/null); DBG=$(find . -name '_chdb*.debug' 2>/dev/null | head -1)
[ -n "$SO" ] && [ -n "$DBG" ] && cp "$DBG" "$(dirname "$SO")/" && echo "  debuginfo placed"
while read -r QI; do
  [ -z "$QI" ] && continue
  echo "  ================ regressor Q$QI ================"
  for MT in "$NP" 96; do
    echo "  --- perf stat Q$QI @$MT (15s loop) ---"
    perf stat -e page-faults,cpu-migrations,context-switches -- \
      v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$MT" 15 2>&1 \
      | grep -E 'LOOPQ|page-faults|cpu-migrations|context-switches|elapsed'
  done
  echo "  --- perf record Q$QI @$NP: top symbols ---"
  v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 30 >/dev/null 2>&1 &
  PID=$!; sleep 3
  perf record -g -o "perf_q$QI.data" -p "$PID" -- sleep 12 >/dev/null 2>&1
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  perf report -i "perf_q$QI.data" --stdio -n --no-children --sort=symbol --percent-limit 1.0 2>/dev/null \
    | grep -vE '^#|^\s*$' | head -18
done < worst.txt

section "[E3] numactl single-socket binding (native @96) + per-socket busy sampling"
echo "  --- (a) unbound @96 (from E1): $(grep HOT_SUM e1_96.txt) ---"
echo "  --- (b) numactl --cpunodebind=0 --membind=0 @96 ---"
numactl --cpunodebind=0 --membind=0 v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" 96 2>/dev/null | grep HOT_SUM
echo "  --- (c) per-socket busy% while unbound @96 runs the heavy query ---"
v267/bin/python "$H" loopq .clickbench "$Q" 32 96 20 >/dev/null 2>&1 &
PID=$!; sleep 4
mpstat -P ALL 1 3 2>/dev/null | awk '/Average/ && $2 ~ /^[0-9]+$/ {busy=100-$NF; if ($2<96) s0+=busy; else s1+=busy; n++} END {if(n>0) printf "  socket0(cpu0-95) avg busy%%=%.1f   socket1(cpu96-191) avg busy%%=%.1f\n", s0/96, s1/96}'
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

section "[E5] clickhouse-local OFFICIAL binary, ONE persistent session, @default vs @96"
curl -fsSL https://clickhouse.com/ | sh >/dev/null 2>&1
./clickhouse --version 2>/dev/null | head -1
python3 - <<'PY'
qs=[l.strip().rstrip(';') for l in open('../chdb/queries.sql') if l.strip()]
for name,suffix in (("default",""),("96"," SETTINGS max_threads=96")):
    with open(f"chl_{name}.sql","w") as f:
        for q in qs:
            for _ in range(3):
                f.write(q+suffix+" FORMAT Null;\n")
PY
for name in default 96; do
  ./clickhouse local --path .clickbench --time --queries-file "chl_$name.sql" >/dev/null 2> "chl_$name.times"
  python3 - "$name" <<'PY'
import sys
name=sys.argv[1]
ts=[float(l) for l in open(f"chl_{name}.times") if l.strip().replace('.','',1).isdigit()]
if len(ts)%3==0 and ts:
    mins=[min(ts[i:i+3]) for i in range(0,len(ts),3)]
    print(f"  CHL persistent-session @{name}: HOT_SUM={round(sum(mins),2)}s over {len(mins)} queries")
else:
    print(f"  CHL @{name}: unexpected times count={len(ts)} (parse issue)")
PY
done

section "[E4] DataFrame track sweep (official server.py load semantics)"
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then DFP="$DIAG_DATA_PARQUET"; else bash ../lib/download-hits-parquet-single; DFP=hits.parquet; fi
for MT in - 96 64; do
  v267/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" "$MT" 2>/dev/null | grep -E 'DF loaded|HOT_SUM'
done
echo "  --- numactl --cpunodebind=0 --membind=0 @96 (df and engine on one node) ---"
numactl --cpunodebind=0 --membind=0 v267/bin/python "$H" dfqueries "$DFP" "$QDF" "$TRIES" 96 2>/dev/null | grep -E 'DF loaded|HOT_SUM'

echo "############ chDB DIAG ROUND3 done $(date -u +%FT%TZ) ############"
