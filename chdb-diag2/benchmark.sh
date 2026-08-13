#!/bin/bash
# chDB diagnostic ROUND 2 (native, chdb-core 26.7.0) on one machine.
# T1: JE_MALLOC_CONF A/B (allocation-lifecycle)   T2: page-faults per config
# T7: full (untruncated) perf by symbol self% at @96 and @nproc
# All output -> stdout -> ClickBench log -> pastila (PR runs).
#
# Local dry-run env: DIAG_DATA_PARQUET (small parquet), DIAG_TRIES, DIAG_HEAVYN.
set +e
Q=../chdb/queries.sql
SCHEMA=../chdb/create.sql
H=../chdb-diag/harness.py
TRIES="${DIAG_TRIES:-3}"
HEAVYN="${DIAG_HEAVYN:-40}"
JECONF="oversize_threshold:1073741824,dirty_decay_ms:-1"
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG ROUND2 (T1+T2+T7) start $(date -u +%FT%TZ) ############"

section "[FACTS]"
echo "nproc=$(nproc)"
lscpu | grep -iE 'Model name|^CPU\(s\)|Core\(s\) per socket|Socket\(s\)|NUMA node\(s\)'
numactl --hardware 2>&1 | grep -E 'available:|node . size:' | head

section "[SETUP]"
if [ -z "${DIAG_DATA_PARQUET:-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y python3-venv python3-pip sysstat numactl xz-utils pigz curl \
       linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" >/dev/null 2>&1
fi
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid' 2>/dev/null
python3 -m venv v267 && v267/bin/pip -q install --upgrade pip >/dev/null 2>&1 \
  && v267/bin/pip -q install pandas pyarrow 'chdb-core==26.7.0' >/dev/null 2>&1
echo "  chdb $(v267/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1)"
JE_MALLOC_CONF="abort_conf:true,zzz:1" v267/bin/python -c "import chdb" 2>/dev/null
echo "  JE_MALLOC_CONF honored on this box: $([ $? -ne 0 ] && echo yes || echo NO)"

section "[LOAD native 26.7.0]"
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
NP=$(nproc)

section "[T1] JE_MALLOC_CONF A/B (native 43q, hot=min of $TRIES)"
echo "  conf = $JECONF"
printf "  (1) default @%s : " "$NP"; v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" -  2>/dev/null | grep -o 'HOT_SUM.*'
printf "  (2) default @96 : ";       v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" 96 2>/dev/null | grep -o 'HOT_SUM.*'
printf "  (3) JEconf  @%s : " "$NP"; JE_MALLOC_CONF="$JECONF" v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" -  2>/dev/null | grep -o 'HOT_SUM.*'
printf "  (4) JEconf  @96 : ";       JE_MALLOC_CONF="$JECONF" v267/bin/python "$H" queries .clickbench "$Q" "$TRIES" 96 2>/dev/null | grep -o 'HOT_SUM.*'

section "[T2] page-faults for heavy GROUP BY x$HEAVYN under 3 configs"
pf(){ echo "  --- $1 ---"; shift; perf stat -e page-faults,minor-faults,major-faults,cpu-migrations -- "$@" 2>&1 \
        | grep -E 'page-faults|minor-faults|major-faults|cpu-migrations|elapsed'; }
pf "(1) default @$NP" env                            v267/bin/python "$H" heavy .clickbench -  "$HEAVYN"
pf "(2) default @96"  env                            v267/bin/python "$H" heavy .clickbench 96 "$HEAVYN"
pf "(3) JEconf  @$NP" env JE_MALLOC_CONF="$JECONF"    v267/bin/python "$H" heavy .clickbench -  "$HEAVYN"

section "[T7] full perf by symbol self% (>=0.3%) at @96 and @$NP"
if [ "${DIAG_SKIP_DEBUGINFO:-0}" != "1" ]; then
  curl -fsSL -o dbg.tar.xz "https://github.com/chdb-io/chdb-core/releases/download/v26.7.0/linux-x86_64-debuginfo.tar.xz" 2>/dev/null && tar xf dbg.tar.xz 2>/dev/null
fi
SO=$(v267/bin/python -c "import _chdb;print(_chdb.__file__)" 2>/dev/null); DBG=$(find . -name '_chdb*.debug' | head -1)
[ -n "$SO" ] && [ -n "$DBG" ] && cp "$DBG" "$(dirname "$SO")/" && echo "  debuginfo placed next to $(basename "$SO")"
perf_one(){
  local MT="$1"
  DIAG_MT="$MT" v267/bin/python - <<'PY' &
import os,time
from chdb import session as chs
s=chs.Session(".clickbench")
q=("SELECT WatchID, ClientIP, COUNT(*) c, SUM(IsRefresh), AVG(ResolutionWidth) FROM clickbench.hits "
   "GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10 SETTINGS max_threads="+os.environ["DIAG_MT"])
t=time.time()
while time.time()-t<25: s.query(q)
PY
  local PID=$!; sleep 2
  perf record -g -o "perf_$MT.data" -p "$PID" -- sleep 12 >/dev/null 2>&1
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  echo "  === perf @$MT : top symbols by self% ==="
  perf report -i "perf_$MT.data" --stdio -n --no-children --sort=symbol --percent-limit 0.3 2>/dev/null \
    | grep -vE '^#|^\s*$' | head -30
}
perf_one 96
perf_one "$NP"

echo "############ chDB DIAG ROUND2 done $(date -u +%FT%TZ) ############"
