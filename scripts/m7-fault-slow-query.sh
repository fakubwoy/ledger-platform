#!/usr/bin/env bash
# Milestone 7 fault drill: make every insert into `entries` sleep 400 ms in Postgres, then find it with
# the dashboard, one trace and the logs. Records how long each phase took.
set -u
OUT=results/m7-slow-query.txt
N="kubectl -n ledger"
PF=()
for pf in "monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090" "monitoring svc/tempo 3200:3200" "monitoring svc/loki 3100:3100"; do
  set -- $pf; kubectl -n $1 port-forward $2 $3 >/dev/null 2>&1 & PF+=($!)
done
cleanup() { kill "${PF[@]}" 2>/dev/null; docker kill k6-fault >/dev/null 2>&1
  $N exec ledger-db-1 -c postgres -- psql -q -d ledger -c "drop trigger if exists slow_entries on entries; drop function if exists slow_entries();" >/dev/null 2>&1; }
trap cleanup EXIT
sleep 3
{
docker run --rm --name k6-fault --user "$(id -u)" --network host -e PROFILE=fault -e FAULT_DURATION=10m \
  -v "$PWD/loadtest:/s" grafana/k6:latest run /s/transfers.js >/dev/null 2>&1 &
sleep 45
echo "baseline p95 before the fault: $(python3 - <<'PY'
import json,urllib.parse,urllib.request
q='histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{uri="/transfers",method="POST"}[1m])) by (le))'
print(json.load(urllib.request.urlopen("http://localhost:9090/api/v1/query?query="+urllib.parse.quote(q)))["data"]["result"][0]["value"][1])
PY
) s"
T0=$(date +%s); echo "T0 $(date +%T)  fault injected (insert into entries now sleeps 400 ms)"
$N exec ledger-db-1 -c postgres -- psql -q -d ledger -c "
create function slow_entries() returns trigger language plpgsql as \$\$ begin perform pg_sleep(0.4); return new; end \$\$;
create trigger slow_entries before insert on entries for each row execute function slow_entries();"
while :; do
  S=$(curl -s localhost:9090/api/v1/alerts | python3 -c 'import sys,json;print(",".join(a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"))')
  [ -n "$S" ] && break
  [ $(( $(date +%s) - T0 )) -gt 540 ] && { echo "no alert within 9 minutes"; break; }
  sleep 10
done
T1=$(date +%s); echo "T1 $(date +%T)  alert firing: $S  (+$((T1 - T0))s after injection)"
echo; python3 scripts/m7-investigate.py
T2=$(date +%s); echo; echo "T2 $(date +%T)  root cause identified (+$((T2 - T0))s after injection, +$((T2 - T1))s after the alert)"
} 2>&1 | tee $OUT
