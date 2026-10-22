#!/usr/bin/env bash
# Milestone 6: restart every ledger Pod (rolling update) while k6 sends transfers, then count failed requests.
# usage: scripts/m6-rollout.sh <label>   (results/m6-<label>.txt)
set -u
LABEL=${1:?label}
OUT=results/m6-$LABEL
docker run --rm --user "$(id -u)" --network host -e PROFILE=rollout -v "$PWD/loadtest:/s" grafana/k6:latest run /s/transfers.js \
  --summary-export=/s/summary-$LABEL.json > $OUT-k6.log 2>&1 &
K6=$!
sleep 40
START=$(date +%s)
kubectl -n ledger rollout restart deploy/ledger >/dev/null
kubectl -n ledger rollout status deploy/ledger --timeout=600s | tail -1
echo "rollout took $(( $(date +%s) - START ))s"
wait $K6
mv loadtest/summary-$LABEL.json $OUT-summary.json
python3 - $OUT-summary.json <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))['metrics']
f=m['http_req_failed']; d=m['http_req_duration']
print(f"requests={f['passes']+f['fails']} failed={f['passes']} p95={d['p(95)']:.0f}ms max={d['max']:.0f}ms")
PY
