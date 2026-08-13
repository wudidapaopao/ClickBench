#!/bin/bash
# chDB single-machine diagnostic battery (see ClickBench PR #1280 discussion).
# ALL output goes to stdout -> ClickBench `log` -> pastila.nl (for PR runs),
# so every section below is retrievable from the PR.
#
# Items: (1) max_threads sweep  (2) version A/B  (3) clickhouse-local same-data
#        (4) utilization + perf  (5) jemalloc bg threads  (6) fixed per-query tax
#
# Env overrides (for a fast LOCAL dry-run; leave unset on the benchmark machine):
#   DIAG_DATA_PARQUET  load a small parquet instead of downloading hits.csv
#   DIAG_CH            path to an existing clickhouse binary (skip download)
#   DIAG_SKIP_DEBUGINFO=1  skip the 1.4GB debuginfo download in item 4
#   DIAG_TRIES         tries per query (default 3)
set +e
DIAG_TRIES="${DIAG_TRIES:-3}"
Q=../chdb/queries.sql
SCHEMA=../chdb/create.sql
section(){ echo; echo "===== $* ====="; }
echo "############ chDB DIAG BATTERY start $(date -u +%FT%TZ) ############"

section "[FACTS]"
echo "nproc=$(nproc)"
lscpu | grep -iE 'Model name|Architecture|^CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket|NUMA node\(s\)|Vendor|BIOS Model' | head -20
echo "--- numactl --hardware ---"; numactl --hardware 2>&1 | head -25
free -g | head -2

section "[SETUP deps]"
if [ -z "${DIAG_DATA_PARQUET:-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y python3-venv python3-pip sysstat numactl unzip xz-utils pigz curl \
       linux-tools-common linux-tools-generic "linux-tools-$(uname -r)" >/dev/null 2>&1
fi
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid' 2>/dev/null

mkvenv(){ python3 -m venv "$1" && "$1/bin/pip" -q install --upgrade pip >/dev/null 2>&1 \
          && "$1/bin/pip" -q install pandas pyarrow "chdb-core==$2" >/dev/null 2>&1; }
section "[SETUP chdb versions]"
mkvenv v267 26.7.0; mkvenv v265 26.5.0; mkvenv v263 26.3.0
for v in v267 v265 v263; do echo "  $v -> chdb $($v/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null | tail -1)"; done

section "[LOAD native (26.7.0)]"
rm -rf .clickbench
if [ -n "${DIAG_DATA_PARQUET:-}" ]; then
  DIAG_DATA_PARQUET="$DIAG_DATA_PARQUET" v267/bin/python - <<'PY'
import os,time
from chdb import dbapi
con=dbapi.connect(path=".clickbench"); cur=con.cursor()
cur.execute("CREATE DATABASE IF NOT EXISTS clickbench")
s=time.time()
cur.execute("CREATE TABLE clickbench.hits ENGINE=MergeTree ORDER BY tuple() AS "
            "SELECT * REPLACE(toDateTime(EventTime) AS EventTime, toDate(EventDate) AS EventDate) "
            f"FROM file('{os.environ['DIAG_DATA_PARQUET']}')")
cur.execute("SELECT count() FROM clickbench.hits"); print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close(); con.close()
PY
else
  bash ../lib/download-hits-csv
  SCHEMA="$SCHEMA" v267/bin/python - <<'PY'
import os,time
from chdb import dbapi
con=dbapi.connect(path=".clickbench"); cur=con.cursor()
cur.execute(open(os.environ["SCHEMA"]).read())
s=time.time(); cur.execute("INSERT INTO clickbench.hits SELECT * FROM file('hits.csv')")
cur.execute("SELECT count() FROM clickbench.hits"); print("rows",cur.fetchone(),"load_s",round(time.time()-s,1))
cur.close(); con.close()
PY
  rm -f hits.csv; sync
fi

section "[ITEM 1] max_threads sweep (26.7.0): default / nproc / 128 / 96 / 64"
NPROC=$(nproc)
for MT in - "$NPROC" 128 96 64; do
  v267/bin/python harness.py queries .clickbench "$Q" "$DIAG_TRIES" "$MT" 2>/dev/null | grep HOT_SUM
done

section "[ITEM 6] fixed per-query tax (SELECT 1 x200): 26.7 vs 26.5"
v267/bin/python harness.py select1 .clickbench 200
v265/bin/python harness.py select1 .clickbench 200

section "[ITEM 2] version A/B (default + max_threads=96)"
for V in v267 v265 v263; do
  ver=$($V/bin/python -c 'import chdb;print(chdb.__version__)' 2>/dev/null)
  for MT in - 96; do
    printf "  [chdb %s] " "$ver"
    $V/bin/python harness.py queries .clickbench "$Q" "$DIAG_TRIES" "$MT" 2>/dev/null | grep HOT_SUM
  done
done

section "[ITEM 5] jemalloc background threads OFF (26.7.0, default threads)"
v267/bin/python harness.py queries .clickbench "$Q" "$DIAG_TRIES" - 0 2>/tmp/e5 | grep -E 'HOT_SUM|CONNECT_FAILED'
head -2 /tmp/e5 2>/dev/null

section "[ITEM 3] clickhouse-local (same .clickbench via --path): default + max_threads=96"
CH="${DIAG_CH:-./clickhouse}"
if [ ! -x "$CH" ]; then curl -fsSL https://clickhouse.com/ | sh >/dev/null 2>&1; CH=./clickhouse; fi
echo "  clickhouse-local version: $($CH local --query 'SELECT version()' 2>&1 | head -1)"
ch_run(){
  local extra="$1" tot=0 n=0 t best
  while IFS= read -r q; do
    [ -z "$q" ] && continue; q="${q%;}"
    best=""
    for _ in 1 2 3; do
      t=$($CH local --path=.clickbench --query "$q $extra" --time 2>&1 >/dev/null | tail -1)
      case "$t" in ''|*[!0-9.]*) t=999 ;; esac
      best=$(awk -v a="$best" -v b="$t" 'BEGIN{print (a==""||b+0<a+0)?b:a}')
    done
    tot=$(awk -v a="$tot" -v b="$best" 'BEGIN{print a+b}'); n=$((n+1))
  done < "$Q"
  echo "  CH_LOCAL_HOT_SUM [$extra]: ${tot}s  over $n queries"
}
ch_run ""
ch_run "SETTINGS max_threads=96"

section "[ITEM 4] utilization (mpstat) + perf on a heavy GROUP BY"
if [ "${DIAG_SKIP_DEBUGINFO:-0}" != "1" ]; then
  curl -fsSL -o dbg.tar.xz "https://github.com/chdb-io/chdb-core/releases/download/v26.7.0/linux-x86_64-debuginfo.tar.xz" 2>/dev/null && tar xf dbg.tar.xz 2>/dev/null
  SO=$(v267/bin/python -c "import _chdb;print(_chdb.__file__)" 2>/dev/null)
  DBG=$(find . -name '_chdb*.debug' 2>/dev/null | head -1)
  [ -n "$SO" ] && [ -n "$DBG" ] && cp "$DBG" "$(dirname "$SO")/" && echo "  placed debuginfo: $DBG -> $(dirname "$SO")"
fi
export HEAVY="SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM clickbench.hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10"
v267/bin/python - <<'PY' &
import os,time
from chdb import session as chs
s=chs.Session(".clickbench"); q=os.environ["HEAVY"]
t=time.time()
while time.time()-t < 22: s.query(q)
PY
PID=$!; sleep 2
echo "  --- mpstat 1x8 (core utilization) ---"
mpstat -P ALL 1 8 > /tmp/mp.txt 2>/dev/null
awk '/Average/ && $2 ~ /^[0-9]+$/ {busy=100-$NF; sum+=busy; n++; if(busy>50)b++} END{if(n)printf "  cores=%d  avg_busy=%.0f%%  cores_over_50pct=%d\n",n,sum/n,b}' /tmp/mp.txt
perf record -g -o perf.data -p "$PID" -- sleep 10 >/dev/null 2>&1
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "  --- perf report top symbols ---"
perf report -i perf.data --stdio 2>/dev/null | grep -vE '^#|^\s*$' | head -30

echo; echo "############ chDB DIAG BATTERY done $(date -u +%FT%TZ) ############"
