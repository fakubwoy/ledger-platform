#!/usr/bin/env bash
# Cloud-only drill on GKE: hard-reset (power-cycle) a node that runs ledger and Kafka pods, mid-load.
# The load driver runs inside the cluster against the ledger Service, so it is not tied to any one pod.
# Needs: PROJECT, ZONE, DB_HOST (Cloud SQL private IP). Output: results/m10-gke-node-crash.txt
set -u
: "${PROJECT:?}" "${ZONE:?}" "${DB_HOST:?}"
cd "$(dirname "$0")/../.."
N="kubectl -n ledger"
OUT=results/m10-gke-node-crash.txt
log() { echo "$(date +%T) $*" | tee -a $OUT; }
: > $OUT
nodes_with() { $N get pods -l "$1" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c; }

# psql client for verify (Cloud SQL has no pod to exec into)
$N run psql-client --image=postgres:17 --restart=Never --overrides='{"spec":{"containers":[{"name":"psql-client","image":"postgres:17","command":["sleep","7200"],"env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"ledger-db","key":"password"}}}]}]}}' >/dev/null 2>&1
$N create configmap drill-driver --from-file=scripts/drills/driver.py --dry-run=client -o yaml | kubectl apply -f - >/dev/null
$N run drill-driver --image=python:3.12-slim --restart=Never --overrides='{"spec":{"containers":[{"name":"drill-driver","image":"python:3.12-slim","command":["sh","-c","python /d/driver.py --name gke-node-crash --base http://ledger.ledger.svc --duration 180 --out /tmp/out.json && sleep 3600"],"volumeMounts":[{"name":"d","mountPath":"/d"}]}],"volumes":[{"name":"d","configMap":{"name":"drill-driver"}}]}}' >/dev/null
$N wait pod/psql-client pod/drill-driver --for=condition=Ready --timeout=300s >/dev/null
DRIVER_NODE=$($N get pod drill-driver -o jsonpath='{.spec.nodeName}')
log "drill gke-node-crash: driver on $DRIVER_NODE; ledger pods per node:"; nodes_with app.kubernetes.io/name=ledger | tee -a $OUT
log "kafka brokers per node:"; nodes_with strimzi.io/kind=Kafka,strimzi.io/name=ledger-kafka | tee -a $OUT
# Reset the node with the most ledger pods that is not running the driver.
VICTIM=$(nodes_with app.kubernetes.io/name=ledger | sort -rn | awk -v d="$DRIVER_NODE" '$2!=d {print $2; exit}')
sleep 45
log "FAULT: hard reset of node $VICTIM (like pulling the power cord: no drain, no SIGTERM)"
gcloud compute instances reset "$VICTIM" --zone "$ZONE" --project "$PROJECT" --quiet >/dev/null 2>&1
for i in $(seq 40); do
  log "  sample: node=$(kubectl get node $VICTIM -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') ledger ready=$($N get deploy ledger -o jsonpath='{.status.readyReplicas}') kafka brokers ready=$($N get pods -l strimzi.io/name=ledger-kafka -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}')"
  sleep 10
  [ "$($N get pod drill-driver -o jsonpath='{.status.containerStatuses[0].state.running}')" != "" ] && $N exec drill-driver -- test -f /tmp/out.json 2>/dev/null && break
done
until $N exec drill-driver -- test -f /tmp/out.json 2>/dev/null; do sleep 5; done
$N cp drill-driver:/tmp/out.json /tmp/m10-gke-client.json >/dev/null 2>&1
python3 -c "import json;print(json.dumps({k:v for k,v in json.load(open('/tmp/m10-gke-client.json'))['summary'].items() if k!='timeline'}))" | tee -a $OUT
log "client view (status per 10 s, 0 = no HTTP answer):"
python3 - /tmp/m10-gke-client.json >> $OUT <<'PY'
import json,sys
from collections import defaultdict
t=defaultdict(dict)
for sec,st,n in json.load(open(sys.argv[1]))["summary"]["timeline"]: t[sec//10*10][st]=t[sec//10*10].get(st,0)+n
for s in sorted(t): print(f"  t={s:3d}-{s+9:3d}s  " + "  ".join(f"{k}:{v}" for k,v in sorted(t[s].items())))
PY
until [ "$(kubectl get node $VICTIM -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; do sleep 5; done; log "node $VICTIM Ready again"
kubectl -n ledger port-forward svc/ledger 8080:80 >/dev/null 2>&1 & PF=$!; sleep 4
log "verify:"
VERIFY_PSQL="kubectl -n ledger exec psql-client -- psql postgresql://ledger@$DB_HOST/ledger?sslmode=require" \
  python3 -u scripts/drills/verify.py /tmp/m10-gke-client.json 2>&1 | tee -a $OUT; RC=${PIPESTATUS[0]}
kill $PF; $N delete pod drill-driver psql-client --wait=false >/dev/null 2>&1
log "drill gke-node-crash verify exit=$RC"; exit $RC
