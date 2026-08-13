#!/bin/bash
# chDB diagnostic ROUND 4: NAME the contended mutex behind the 192-thread futex convoy.
# F1: gdb all-thread stack sampling on the Q10 loop @192  -> the lock's caller
# F2: perf dwarf callgraph on Q10 @192 (backup symbolization)
# F3: knob A/Bs on Q10 loop @192: use_query_condition_cache=0, MALLOC_ARENA_MAX
# F4: version-matched OFFICIAL clickhouse v26.7.2.59 local, persistent session
# F5: if a knob wins on the loop, quantify it on the full 43-query suite @192
set +e
Q=../chdb/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag3/harness3.py
TRIES="${DIAG_TRIES:-3}"
QI="${DIAG_QI:-10}"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND4 start $(date -u +%FT%TZ) ############"

section "[FACTS]"
echo "nproc=$(nproc)"; lscpu | grep -iE 'Model name|Socket\(s\)|NUMA node\(s\)'

section "[SETUP]"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y python3-venv python3-pip gdb sysstat numactl xz-utils curl \
     linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" >/dev/null 2>&1
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid' 2>/dev/null
sudo sh -c 'echo 0 > /proc/sys/kernel/yama/ptrace_scope' 2>/dev/null
python3 -m venv v267 && v267/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v267/bin/pip -q install pandas pyarrow 'chdb-core==26.7.0' >/dev/null 2>&1
echo "  chdb $(v267/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1)"
curl -fsSL -o dbg.tar.xz "https://github.com/chdb-io/chdb-core/releases/download/v26.7.0/linux-x86_64-debuginfo.tar.xz" 2>/dev/null && tar xf dbg.tar.xz 2>/dev/null
SO=$(v267/bin/python -c "import _chdb;print(_chdb.__file__)" 2>/dev/null); DBG=$(find . -name '_chdb*.debug' 2>/dev/null | head -1)
[ -n "$SO" ] && [ -n "$DBG" ] && cp "$DBG" "$(dirname "$SO")/" && echo "  debuginfo placed"
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

section "[F1] gdb all-thread stack sampling: Q$QI loop @$NP"
v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 70 >/dev/null 2>&1 &
PID=$!; sleep 8
for i in 1 2 3 4; do
  timeout -k 5 180 gdb -p "$PID" -batch -ex 'set pagination off' -ex 'thread apply all bt 10' > "gdb_$i.txt" 2>/dev/null
  sleep 2
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
python3 - <<'PY'
import re, glob, collections
waiters = collections.Counter()   # caller stacks of threads blocked in mutex lock
holders = collections.Counter()   # what running threads do (non-blocked)
nthreads = 0
for f in glob.glob('gdb_*.txt'):
    cur = []
    stacks = []
    for line in open(f, errors='replace'):
        if line.startswith('Thread '):
            if cur: stacks.append(cur)
            cur = []
        m = re.match(r'#\d+\s+(?:0x[0-9a-f]+ in )?([^(]+)', line)
        if m: cur.append(m.group(1).strip())
    if cur: stacks.append(cur)
    for st in stacks:
        nthreads += 1
        joined = ' | '.join(st)
        if any('pthread_mutex_lock' in fr or 'lll_lock_wait' in fr or 'futex' in fr.lower() for fr in st):
            # caller frames above the lock machinery
            interesting = [fr for fr in st if not re.search(r'futex|lll_lock|pthread_mutex|pthread_cond|__GI|clone|start_thread', fr)]
            waiters[' <- '.join(interesting[:4])] += 1
        else:
            interesting = [fr for fr in st if not re.search(r'clone|start_thread', fr)]
            holders[' <- '.join(interesting[:3])] += 1
print(f"  sampled thread-stacks: {nthreads}")
print("  === TOP BLOCKED-ON-MUTEX caller stacks ===")
for s, c in waiters.most_common(12): print(f"  {c:>5}  {s[:220]}")
print("  === TOP RUNNING stacks (for contrast) ===")
for s, c in holders.most_common(8): print(f"  {c:>5}  {s[:180]}")
PY

section "[F2] perf dwarf callgraph: Q$QI @$NP (8s, F=99)"
v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 40 >/dev/null 2>&1 &
PID=$!; sleep 5
timeout -k 5 60 perf record --call-graph dwarf -F 99 -o perf_dwarf.data -p "$PID" -- sleep 8 >/dev/null 2>&1
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
timeout -k 5 300 perf report -i perf_dwarf.data --stdio --no-children -g graph,0.5,caller --percent-limit 3 2>/dev/null \
  | grep -vE '^#|^\s*$' | head -60

section "[F3] knob A/B on Q$QI loop @$NP (iters in fixed 15s; higher = better)"
run_loop(){ echo "  --- $1 ---"; shift; "$@" v267/bin/python "$H" loopq .clickbench "$Q" "$QI" "$NP" 15 2>/dev/null | grep LOOPQ; }
run_loop "(a) default" env
run_loop "(b) MALLOC_ARENA_MAX=1 (glibc-malloc theory: should CRATER if glibc is contended)" env MALLOC_ARENA_MAX=1
run_loop "(c) MALLOC_ARENA_MAX=8 " env MALLOC_ARENA_MAX=8
echo "  --- (d) use_query_condition_cache=0 @$NP ---"
QCC=1 v267/bin/python - <<PY 2>/dev/null
import time
from chdb import session as chs
s=chs.Session(".clickbench")
qs=[l.strip().rstrip(";") for l in open("$Q") if l.strip()]
q=qs[$QI]+" SETTINGS max_threads=$NP, use_query_condition_cache=0"
n,t0=0,time.time()
while time.time()-t0<15: s.query(q); n+=1
print(f"LOOPQ q=$QI mt=$NP qcc=0 iters={n} wall={round(time.time()-t0,2)}s")
s.close()
PY

section "[F4] OFFICIAL clickhouse v26.7.2.59 local, ONE persistent session"
curl -fsSL -o ch267.tgz "https://github.com/ClickHouse/ClickHouse/releases/download/v26.7.2.59-stable/clickhouse-common-static-26.7.2.59-amd64.tgz" 2>/dev/null
tar xzf ch267.tgz 2>/dev/null && CH267=$(find . -path '*usr/bin/clickhouse' | head -1)
if [ -n "$CH267" ]; then
  "$CH267" --version 2>/dev/null | head -1
  python3 - <<'PY'
qs=[l.strip().rstrip(';') for l in open('../chdb/queries.sql') if l.strip()]
for name,suffix in (("default",""),("96"," SETTINGS max_threads=96")):
    with open(f"chl267_{name}.sql","w") as f:
        for q in qs:
            for _ in range(3):
                f.write(q+suffix+" FORMAT Null;\n")
PY
  for name in default 96; do
    "$CH267" local --path .clickbench --time --queries-file "chl267_$name.sql" >/dev/null 2> "chl267_$name.times"
    python3 - "$name" <<'PY'
import sys
name=sys.argv[1]
ts=[float(l) for l in open(f"chl267_{name}.times") if l.strip().replace('.','',1).isdigit()]
if ts and len(ts)%3==0:
    mins=[min(ts[i:i+3]) for i in range(0,len(ts),3)]
    print(f"  CHL-26.7 persistent @{name}: HOT_SUM={round(sum(mins),2)}s over {len(mins)} queries")
else:
    print(f"  CHL-26.7 @{name}: unexpected times count={len(ts)}")
PY
  done
else
  echo "  26.7 binary download failed"
fi

section "[F5] full suite @$NP with use_query_condition_cache=0"
v267/bin/python - <<PY 2>/dev/null | grep -E "HOT_SUM|PQ .* Q(9|10|12|13|28) "
import time
from chdb import session as chs
s=chs.Session(".clickbench")
qs=[l.strip().rstrip(";") for l in open("$Q") if l.strip()]
hot=0.0
for i,q in enumerate(qs):
    ts=[]
    for _ in range($TRIES):
        t=time.perf_counter()
        try:
            s.query(q+" SETTINGS max_threads=$NP, use_query_condition_cache=0")
            ts.append(time.perf_counter()-t)
        except Exception: ts.append(None)
    good=[t for t in ts if t is not None]
    m=min(good) if good else None
    if m: hot+=m
    print(f"PQ qcc0 Q{i:<2} min={None if m is None else round(m,4)}")
print(f"HOT_SUM max_threads=$NP qcc=0: {round(hot,2)}s")
s.close()
PY

echo "############ chDB DIAG ROUND4 done $(date -u +%FT%TZ) ############"
