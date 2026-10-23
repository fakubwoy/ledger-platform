#!/usr/bin/env python3
"""Transfer load for the failure drills. Behaves like a correct client: every transfer has its own
Idempotency-Key, and on a timeout, connection error or 5xx it retries with the SAME key until it gets a
final answer (201 posted, 422 rejected). Writes every key's outcome to a JSON file for verify.py."""
import argparse, json, random, threading, time, urllib.error, urllib.request, uuid
from collections import Counter

p = argparse.ArgumentParser()
p.add_argument("--name", required=True)
p.add_argument("--duration", type=int, default=90)
p.add_argument("--workers", type=int, default=12)
p.add_argument("--timeout", type=float, default=5.0, help="client timeout per attempt, seconds")
p.add_argument("--base", default="http://localhost:8080")
p.add_argument("--out", required=True)
a = p.parse_args()

def call(method, path, body=None, key=None, timeout=a.timeout):
    """Returns (status, json body or None). Status 0 means no HTTP answer (timeout, reset, refused)."""
    req = urllib.request.Request(a.base + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json", **({"Idempotency-Key": key} if key else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None

def must(method, path, body=None, key=None):
    for _ in range(60):
        s, b = call(method, path, body, key, timeout=10)
        if s in (200, 201):
            return b
        time.sleep(1)
    raise SystemExit(f"setup failed: {method} {path}")

prefix = f"drill-{a.name}-{int(time.time())}"
# Small balances on purpose: transfers often hit "insufficient funds", so a double-applied transfer would show
# up as a negative balance or a sum that is off.
accounts = [must("POST", "/accounts", {"owner": f"{prefix}-{i}", "currency": "USD"})["id"] for i in range(20)]
for i, acc in enumerate(accounts):
    must("POST", f"/accounts/{acc}/deposits", {"amount": 10_000}, key=f"{prefix}-seed-{i}")

results, lock = {}, threading.Lock()
timeline = Counter()          # (second, outcome) -> attempts, for the "what did clients see" chart
t0 = time.time()
end = t0 + a.duration

def worker():
    while time.time() < end:
        src, dst = random.sample(accounts, 2)
        body = {"fromAccountId": src, "toAccountId": dst, "amount": random.randint(1, 300)}
        key = f"{prefix}-{uuid.uuid4()}"
        attempts, errors, final = 0, Counter(), None
        delay = 0.2
        while attempts < 40:
            attempts += 1
            s, b = call("POST", "/transfers", body, key)
            sec = int(time.time() - t0)
            with lock:
                timeline[(sec, s)] += 1
            if s in (201, 422):
                final = (s, b["transactionId"] if s == 201 and b else None)
                break
            errors[s] += 1
            time.sleep(delay)
            delay = min(delay * 2, 3)
        with lock:
            results[key] = {"body": body, "status": final[0] if final else None,
                            "tx": final[1] if final else None, "attempts": attempts,
                            "errors": {str(k): v for k, v in errors.items()}}

threads = [threading.Thread(target=worker) for _ in range(a.workers)]
for t in threads: t.start()
for t in threads: t.join()

outcomes = Counter(str(r["status"]) for r in results.values())
retried = sum(1 for r in results.values() if r["attempts"] > 1)
summary = {"name": a.name, "prefix": prefix, "started": t0, "ended": time.time(), "transfers": len(results),
           "final_status": dict(outcomes), "retried_transfers": retried,
           "attempt_errors": dict(sum((Counter(r["errors"]) for r in results.values()), Counter())),
           "timeline": [[sec, st, n] for (sec, st), n in sorted(timeline.items())]}
json.dump({"summary": summary, "accounts": accounts, "results": results}, open(a.out, "w"))
print(json.dumps({k: v for k, v in summary.items() if k != "timeline"}))
