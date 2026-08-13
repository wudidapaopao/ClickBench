#!/usr/bin/env python3
"""chDB native query-timing harness for the diagnostic battery.

Data is expected already loaded into clickbench.hits at <db_path>.

Modes:
  queries <db_path> <queries_file> <tries> [max_threads|-] [jemalloc_bg 0/1]
      run each query `tries` times; print per-query timings + a HOT_SUM line
      (sum over queries of the per-query minimum).
  select1 <db_path> <n>
      run `SELECT 1` n times; print mean/median/min ms = fixed per-query tax.
"""
import sys, time
from chdb import session as chs


def connect(db_path, jemalloc_bg=None):
    p = db_path if jemalloc_bg is None else f"{db_path}?jemalloc_enable_background_threads={jemalloc_bg}"
    return chs.Session(p)


def run_queries(db_path, qfile, tries, max_threads, jemalloc_bg):
    try:
        sess = connect(db_path, jemalloc_bg)
    except Exception as e:
        print(f"CONNECT_FAILED jemalloc_bg={jemalloc_bg}: {str(e)[:200]}")
        return
    qs = [l.strip().rstrip(";") for l in open(qfile) if l.strip()]
    hot = 0.0
    nfail = 0
    for i, q in enumerate(qs):
        qq = q if not max_threads else f"{q} SETTINGS max_threads={max_threads}"
        ts = []
        for _ in range(tries):
            s = time.perf_counter()
            try:
                sess.query(qq)
                ts.append(round(time.perf_counter() - s, 4))
            except Exception as e:
                ts.append(None)
                print(f"  Q{i} ERR {str(e)[:120]}", file=sys.stderr)
        good = [t for t in ts if t is not None]
        m = min(good) if good else None
        if m is None:
            nfail += 1
        else:
            hot += m
        print(f"  Q{i:<2} {ts} min={m}")
    print(f"HOT_SUM max_threads={max_threads or 'default'} jemalloc_bg={jemalloc_bg}: "
          f"{round(hot,2)}s  (failed {nfail}/{len(qs)})")
    sess.close()


HEAVY_Q = ("SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) "
           "FROM clickbench.hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10")


def heavy(db_path, max_threads, n):
    """Run the heavy GROUP BY n times (for wrapping under perf stat / perf record).
    jemalloc conf is inherited from the process environment (JE_MALLOC_CONF/MALLOC_CONF)."""
    sess = connect(db_path)
    mt = "" if max_threads in (None, "-", "default") else f" SETTINGS max_threads={max_threads}"
    for _ in range(n):
        sess.query(HEAVY_Q + mt)
    sess.close()
    print(f"HEAVY done: n={n} max_threads={max_threads or 'default'}")


def select1(db_path, n):
    sess = connect(db_path)
    lat = []
    for _ in range(n):
        s = time.perf_counter()
        sess.query("SELECT 1")
        lat.append((time.perf_counter() - s) * 1000)
    lat.sort()
    print(f"SELECT1 x{n}: mean={sum(lat)/len(lat):.2f}ms median={lat[n//2]:.2f}ms min={lat[0]:.2f}ms")
    sess.close()


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "queries":
        db, qf, tries = sys.argv[2], sys.argv[3], int(sys.argv[4])
        mt = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] != "-" else None
        jb = sys.argv[6] if len(sys.argv) > 6 else None
        run_queries(db, qf, tries, mt, jb)
    elif mode == "heavy":
        mt = sys.argv[3] if len(sys.argv) > 3 else None
        heavy(sys.argv[2], mt, int(sys.argv[4]) if len(sys.argv) > 4 else 30)
    elif mode == "select1":
        select1(sys.argv[2], int(sys.argv[3]))
