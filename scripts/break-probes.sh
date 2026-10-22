#!/usr/bin/env bash
# Milestone 2: break each probe on purpose and record what Kubernetes does. Restores the manifest at the end.
set -u
N="kubectl -n ledger"
patch() { $N patch deploy/ledger --type=json -p "$1" >/dev/null; }
restore() { kubectl apply -f k8s/30-ledger.yaml >/dev/null; $N rollout status deploy/ledger --timeout=240s >/dev/null; }

echo "## A: liveness points at a path that 404s"
patch '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/nope"}]'
sleep 90
$N get pods -l app=ledger
$N get events --field-selector reason=Unhealthy,type=Warning --sort-by=.lastTimestamp | grep -i liveness | tail -2
$N get events --field-selector reason=Killing | tail -1
restore

echo; echo "## B: readiness points at a path that 404s"
patch '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'
sleep 60
$N get pods -l app=ledger
echo "Service endpoints:"; $N get endpoints ledger
$N rollout status deploy/ledger --timeout=5s 2>&1 | tail -1
restore

echo; echo "## C: startup probe gives the JVM only 1 x 1s"
patch '[{"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":1},{"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":1}]'
sleep 75
$N get pods -l app=ledger
$N get events --field-selector reason=Unhealthy | grep -i startup | tail -1
restore
echo; echo "## restored"; $N get pods -l app=ledger
