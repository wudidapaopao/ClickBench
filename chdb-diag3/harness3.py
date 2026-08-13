#!/usr/bin/env python3
"""Round-3 harness: per-query native timings, arbitrary-query loops for perf,
and a DataFrame-track mode mirroring chdb-dataframe/server.py's load.

Modes:
  queries   <db_path> <queries_file> <tries> [max_threads|-]
  loopq     <db_path> <queries_file> <qindex> <max_threads|-> <seconds>
  dfqueries <parquet> <queries_file> <tries> [max_threads|-]
"""
import sys
import time


def _run_suite(run_one, qs, tries, mt_label):
    hot, nfail = 0.0, 0
    for i, q in enumerate(qs):
        ts = []
        for _ in range(tries):
            s = time.perf_counter()
            try:
                run_one(q)
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
        print(f"PQ {mt_label} Q{i:<2} min={m} tries={ts}")
    print(f"HOT_SUM max_threads={mt_label}: {round(hot, 2)}s  (failed {nfail}/{len(qs)})")


def load_qs(qfile):
    return [l.strip().rstrip(";") for l in open(qfile) if l.strip()]


def queries(db_path, qfile, tries, mt):
    from chdb import session as chs
    sess = chs.Session(db_path)
    suffix = "" if mt in (None, "-", "default") else f" SETTINGS max_threads={mt}"
    _run_suite(lambda q: sess.query(q + suffix), load_qs(qfile), tries, mt or "default")
    sess.close()


def loopq(db_path, qfile, qindex, mt, seconds):
    from chdb import session as chs
    sess = chs.Session(db_path)
    q = load_qs(qfile)[qindex]
    if mt not in (None, "-", "default"):
        q += f" SETTINGS max_threads={mt}"
    n, t0 = 0, time.time()
    while time.time() - t0 < seconds:
        sess.query(q)
        n += 1
    print(f"LOOPQ q={qindex} mt={mt} iters={n} wall={round(time.time() - t0, 2)}s")
    sess.close()


def dfqueries(parquet, qfile, tries, mt):
    import pandas as pd
    import chdb
    t0 = time.time()
    df = pd.read_parquet(parquet)
    df["EventTime"] = pd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = pd.to_datetime(df["EventDate"], unit="D")
    for col in df.columns:
        if df[col].dtype == "O":
            df[col] = df[col].astype(str)
    globals()["hits"] = df
    print(f"DF loaded rows={len(df)} load_s={round(time.time() - t0, 1)}")
    conn = chdb.connect("./tmpdf")
    suffix = "" if mt in (None, "-", "default") else f" SETTINGS max_threads={mt}"
    _run_suite(lambda q: conn.query(q + suffix), load_qs(qfile), tries, mt or "default")
    conn.close()


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "queries":
        queries(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] != "-" else None)
    elif mode == "loopq":
        loopq(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], int(sys.argv[6]))
    elif mode == "dfqueries":
        dfqueries(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                  sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] != "-" else None)
