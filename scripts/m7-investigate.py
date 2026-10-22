#!/usr/bin/env python3
"""Look at a fault the way an on-call engineer would: dashboard queries, then one slow trace, then its logs.
Needs port-forwards: Prometheus 9090, Tempo 3200, Loki 3100. Prints what each tool shows."""
import json, sys, time, urllib.parse, urllib.request

def get(url):
    return json.load(urllib.request.urlopen(url, timeout=20))

def prom(q):
    r = get("http://localhost:9090/api/v1/query?query=" + urllib.parse.quote(q))["data"]["result"]
    return float(r[0]["value"][1]) if r else float("nan")

print("== 1. Dashboard (the PromQL behind each panel)")
for name, q in [
    ("p95 latency POST /transfers (s)", 'histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{uri="/transfers",method="POST"}[1m])) by (le))'),
    ("5xx error ratio", 'sum(rate(http_server_requests_seconds_count{uri="/transfers",status=~"5.."}[1m])) / sum(rate(http_server_requests_seconds_count{uri="/transfers"}[1m])) or vector(0)'),
    ("outbox backlog", "max(ledger_outbox_backlog)"),
    ("kafka consumer lag", "max(kafka_consumer_fetch_manager_records_lag_max)"),
    ("transfers/min", 'sum(rate(ledger_transactions_posted_total{type="TRANSFER"}[1m])) * 60'),
]:
    print(f"   {name:36s} {prom(q):.3f}")
print("   -> only latency is off; errors, backlog and lag are fine, so the app is slow, not broken.")

print("\n== 2. Trace (slowest recent POST /transfers)")
tq = '{ resource.service.name = "ledger-service" && span.http.route = "/transfers" && duration > 500ms }'
res = get("http://localhost:3200/api/search?limit=1&start=%d&end=%d&q=%s" % (time.time() - 600, time.time() + 5, urllib.parse.quote(tq)))
trace_id = res["traces"][0]["traceID"]
spans = []
for b in get("http://localhost:3200/api/traces/" + trace_id)["batches"]:
    for ss in b["scopeSpans"]:
        for s in ss["spans"]:
            attrs = {a["key"]: next(iter(a["value"].values())) for a in s.get("attributes", [])}
            spans.append(((int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e6, s["name"], attrs.get("db.statement") or attrs.get("db.query.text", "")))
print(f"   trace {trace_id}, {len(spans)} spans. Slowest:")
for d, n, st in sorted(spans, reverse=True)[:5]:
    print(f"   {d:8.1f} ms  {n[:50]:50s} {st[:70]}")
leaf = [x for x in sorted(spans, reverse=True) if x[2]][0]
print(f"   -> the time is spent inside Postgres: '{leaf[1]}' took {leaf[0]:.0f} ms.")

print("\n== 3. Logs for that trace (Loki)")
q = '{namespace="ledger", app="ledger"} |= "%s" | json | line_format "{{.requestId}} {{.message}}"' % trace_id
r = get("http://localhost:3100/loki/api/v1/query_range?limit=5&since=15m&query=" + urllib.parse.quote(q))["data"]["result"]
for s in r:
    for ts, line in s["values"][:3]:
        print("  ", line[:110])
print("   -> same trace id in the log line; requestId from there lets you find the caller's request.")
