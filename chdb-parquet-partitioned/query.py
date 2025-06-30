#!/usr/bin/env python3

import chdb
import timeit
import sys

query = sys.stdin.read()

conn = chdb.connect()
times = []

for try_num in range(3):
    start = timeit.default_timer()
    conn.query(query, "Null")
    end = timeit.default_timer()
    elapsed = round(end - start, 3)
    times.append(f"{elapsed}" if elapsed else "")

print(','.join(times))

conn.close()
