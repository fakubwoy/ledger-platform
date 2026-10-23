#!/usr/bin/env python3
"""Checks the ledger after a drill. Money invariants come from Postgres; idempotency is checked by replaying
every acknowledged key and comparing the answer. Exit 1 if any check fails."""
import functools, json, os, subprocess, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

print = functools.partial(print, flush=True)

data = json.load(open(sys.argv[1]))
s, results = data["summary"], data["results"]
BASE = os.environ.get("BASE_URL", "http://localhost:8080")
# How to run psql. Default: exec into the CloudNativePG pod. On a managed database (Cloud SQL), point it at a
# client pod instead, e.g. VERIFY_PSQL="kubectl -n ledger exec psql-client -- psql postgresql://...".
PSQL = os.environ.get("VERIFY_PSQL", "kubectl -n ledger exec ledger-db-1 -c postgres -- psql -d ledger").split()
ok = True

def sql(q):
    out = subprocess.run(PSQL + ["-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()
    return out

def check(name, cond, detail):
    global ok
    ok &= bool(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}: {detail}")

print("Money")
total = int(sql("select coalesce(sum(amount),0) from entries"))
check("all entries sum to zero", total == 0, f"sum = {total}")
bad = int(sql("select count(*) from (select transaction_id from entries group by 1 having sum(amount) <> 0 or count(*) <> 2) x"))
check("every transaction is one debit + one credit", bad == 0, f"{bad} unbalanced transactions")
neg = int(sql("select count(*) from (select a.id from accounts a join entries e on e.account_id = a.id "
              "where a.owner <> 'external' group by a.id having sum(e.amount) < 0) x"))
check("no customer account below zero (no double spend)", neg == 0, f"{neg} negative accounts")

print("Exactly-once effect")
p = s["prefix"]
posted = [r for r in results.values() if r["status"] == 201]
stored = int(sql(f"select count(*) from idempotency_keys where key like '{p}-%' and key not like '{p}-seed-%' and response is not null"))
check("server stored one result per acknowledged transfer", stored == len(posted), f"{stored} stored, {len(posted)} acknowledged")
txs = int(sql(f"select count(*) from transactions where type = 'TRANSFER' and created_at >= to_timestamp({s['started']})"))
check("one transaction per acknowledged transfer (no duplicates from retries)", txs == len(posted), f"{txs} transactions, {len(posted)} acknowledged")
check("no two keys produced the same transaction", len({r['tx'] for r in posted}) == len(posted), f"{len(posted)} distinct ids")
unknown = [k for k, r in results.items() if r["status"] is None]
check("client got a final answer for every transfer", not unknown, f"{len(unknown)} without an answer")

def replay(item):
    k, r = item
    req = urllib.request.Request(BASE + "/transfers", method="POST", data=json.dumps(r["body"]).encode(),
                                 headers={"Content-Type": "application/json", "Idempotency-Key": k})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            got = (resp.status, json.loads(resp.read())["transactionId"])
    except urllib.error.HTTPError as e:
        got = (e.code, None)
    return got != (201, r["tx"])

with ThreadPoolExecutor(16) as pool:
    mismatch = sum(pool.map(replay, [(k, r) for k, r in results.items() if r["status"] == 201]))
check("replaying every acknowledged key returns the same transaction", mismatch == 0, f"{mismatch} of {len(posted)} differ")

print("Events (outbox -> Kafka -> statement view)")
for _ in range(300):   # up to 10 minutes: after a long broker outage the backlog is large
    backlog = int(sql("select count(*) from outbox where published_at is null"))
    if backlog == 0:
        break
    time.sleep(2)
check("outbox drained", backlog == 0, f"{backlog} unpublished")
for _ in range(60):
    # One grouped join: statement_lines is keyed (account_id, transaction_id), so a per-row subquery on
    # transaction_id would scan the whole table once per transaction.
    missing = int(sql("select count(*) from transactions t left join (select transaction_id, count(*) c from "
                      f"statement_lines group by 1) l on l.transaction_id = t.id where t.created_at >= to_timestamp({s['started']}) "
                      "and coalesce(l.c, 0) <> 2"))
    if missing == 0:
        break
    time.sleep(2)
check("every transaction reached the statement view exactly once (2 lines)", missing == 0, f"{missing} incomplete")
sys.exit(0 if ok else 1)
