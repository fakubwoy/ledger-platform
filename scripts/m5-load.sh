#!/usr/bin/env bash
# Milestone 5: run the k6 load test through the ingress while sampling the HPA every 10s.
set -u
OUT=results/m5-hpa
mkdir -p results
( while true; do echo "$(date +%T) $(kubectl -n ledger get hpa ledger --no-headers | awk '{print "cpu="$3, "replicas="$7}') ready=$(kubectl -n ledger get deploy ledger -o jsonpath='{.status.readyReplicas}')"; sleep 10; done ) > $OUT-timeline.txt &
SAMPLER=$!
docker run --rm --network host -v "$PWD/loadtest:/s" grafana/k6:latest run /s/transfers.js --summary-export=/s/summary.json 2>&1 | tail -40 > $OUT-k6.txt
sleep 60   # let it start to scale down
kill $SAMPLER
mv loadtest/summary.json results/m5-k6-summary.json 2>/dev/null
cat $OUT-k6.txt; echo; cat $OUT-timeline.txt
