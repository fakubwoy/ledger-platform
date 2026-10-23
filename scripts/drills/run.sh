#!/usr/bin/env bash
# Milestone 10 failure drills. usage: scripts/drills/run.sh <pod-kill|outbox|kafka|postgres|postgres-long|latency>
# Each drill runs driver.py (transfers with idempotent retries), injects one fault on a timer, samples what the
# cluster does, then runs verify.py. Output: results/m10-<drill>.txt
set -u
DRILL=${1:?drill}
cd "$(dirname "$0")/../.."
N="kubectl -n ledger"
OUT=results/m10-$DRILL.txt
CLIENT=${TMPDIR:-/tmp}/m10-$DRILL-client.json
log() { echo "$(date +%T) $*" | tee -a $OUT; }
psqlq() { $N exec ledger-db-1 -c postgres -- psql -d ledger -At -c "$1" 2>/dev/null; }
ready() { $N get pods -l app.kubernetes.io/name=ledger -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}' | tr ' ' '\n' | grep -c true; }
topic_end() { $N exec ledger-dual-0 -- /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
  --topic ledger.transfer-completed 2>/dev/null | awk -F: '{s+=$3} END{print s+0}'; }
alerts() { curl -s localhost:9090/api/v1/alerts 2>/dev/null | python3 -c 'import sys,json
try: print(",".join(a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing") or "-")
except Exception: print("?")'; }
sampler() { while :; do log "  sample: ready ledger pods=$(ready) db=$($N get pod ledger-db-1 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo gone) outbox_backlog=$(psqlq 'select count(*) from outbox where published_at is null' || echo '?') alerts=$(alerts)"; sleep ${1:-5}; done; }
drive() { python3 scripts/drills/driver.py --name $DRILL --out $CLIENT "$@" >> $OUT 2>&1 & DRIVER=$!; }

kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 & PF=$!
cleanup() { kill $PF ${SAMPLER:-} 2>/dev/null; }
trap cleanup EXIT
: > $OUT
log "drill $DRILL: $(ready) ledger pods ready, image $($N get deploy ledger -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"

case $DRILL in
pod-kill)
  # A real crash: SIGKILL the JVM from the node. No SIGTERM, no graceful shutdown, open DB transactions die,
  # and the pod stays in the Service until its readiness probe fails. (kubectl delete --force is NOT a crash:
  # the pod leaves the endpoints first and the app still gets SIGTERM, so in-flight requests finish.)
  crash() { local P=$1 NODE CID PID
    NODE=$($N get pod $P -o jsonpath='{.spec.nodeName}')
    CID=$($N get pod $P -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
    PID=$(docker exec $NODE crictl inspect -o go-template --template '{{.info.pid}}' $CID)
    docker exec $NODE kill -9 $PID; }
  drive --duration 90
  sleep 25; P=$($N get pods -l app.kubernetes.io/name=ledger -o jsonpath='{.items[0].metadata.name}')
  log "FAULT: SIGKILL the JVM in $P while transfers are in flight"; crash $P
  sleep 30; P=$($N get pods -l app.kubernetes.io/name=ledger -o jsonpath='{.items[2].metadata.name}')
  log "FAULT: SIGKILL the JVM in $P"; crash $P
  wait $DRIVER
  log "restarts: $($N get pods -l app.kubernetes.io/name=ledger -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].restartCount} {end}')" ;;
outbox)
  before=$(topic_end); tx_before=$(psqlq "select count(*) from transactions")
  drive --duration 60; wait $DRIVER
  for i in $(seq 60); do [ "$(psqlq 'select count(*) from outbox where published_at is null')" = 0 ] && break; sleep 2; done
  sleep 5; after=$(topic_end); tx_after=$(psqlq "select count(*) from transactions")
  log "3 replicas polling one outbox: $((tx_after - tx_before)) transactions written, $((after - before)) events in Kafka"
  kubectl -n monitoring port-forward svc/tempo 3200:3200 >/dev/null 2>&1 & TPF=$!; sleep 3
  for P in $($N get pods -l app.kubernetes.io/name=ledger -o jsonpath='{.items[*].metadata.name}'); do
    n=$(python3 -c "import json,sys,time,urllib.parse as u,urllib.request as r
q=u.quote('{ name = \"outbox publish\" && resource.k8s.pod.name = \"$P\" }')
print(len(json.load(r.urlopen(f'http://localhost:3200/api/search?limit=5000&start={int(time.time())-150}&end={int(time.time())}&q='+q))['traces']))")
    log "  $P published $n events (outbox publish spans in Tempo)"
  done; kill $TPF
  lines_before=$(psqlq "select count(*) from statement_lines")
  log "FAULT: marking the 50 newest published rows unpublished, so they are sent to Kafka a second time"
  psqlq "update outbox set published_at = null where id in (select id from outbox order by id desc limit 50)" >/dev/null
  for i in $(seq 60); do [ "$(psqlq 'select count(*) from outbox where published_at is null')" = 0 ] && break; sleep 2; done
  sleep 10; after2=$(topic_end); lines_after=$(psqlq "select count(*) from statement_lines")
  log "redelivery: $((after2 - after)) duplicate events in Kafka, statement_lines $lines_before -> $lines_after" ;;
kafka)
  SAMPLER=; sampler 15 & SAMPLER=$!
  drive --duration 540
  sleep 30
  log "FAULT: stopping the Kafka broker (operator scaled to 0 so it does not come back, then broker pod deleted)"
  kubectl -n strimzi-system scale deploy/strimzi-cluster-operator --replicas=0 >/dev/null
  $N delete pod ledger-dual-0 --wait=false >/dev/null
  for i in $(seq 48); do sleep 10; [ "$(alerts)" != "-" ] && [ "$(alerts)" != "?" ] && break; done
  log "broker down for ~$((i * 10))s; alerts firing: $(alerts)"
  log "RECOVER: operator scaled back to 1, it recreates the broker"
  kubectl -n strimzi-system scale deploy/strimzi-cluster-operator --replicas=1 >/dev/null
  # Wait for the broker pod itself: the Kafka resource still says Ready from before, nobody updated it while
  # the operator was down.
  until [ "$($N get pod ledger-dual-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; do sleep 5; done
  log "broker pod Ready again"
  wait $DRIVER ;;
postgres)
  # Forced delete = a crash: no smart shutdown. (A plain delete lets CloudNativePG shut down "smart" for up to
  # 180 s, and the app keeps working on its pooled connections the whole time: see m10-postgres-graceful.txt.)
  SAMPLER=; sampler 2 & SAMPLER=$!
  drive --duration 150
  sleep 30; log "FAULT: force-deleting the Postgres pod ledger-db-1 (crash; CloudNativePG recreates it on the same volume)"
  $N delete pod ledger-db-1 --grace-period=0 --force >/dev/null 2>&1
  until [ "$($N get pod ledger-db-1 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; do sleep 1; done
  log "Postgres pod Ready again"
  wait $DRIVER ;;
postgres-long)
  # A 60 s database outage, long enough for readiness to react: CloudNativePG "fencing" stops Postgres and keeps
  # it stopped while the pod stays.
  SAMPLER=; sampler 2 & SAMPLER=$!
  drive --duration 150
  sleep 30; log "FAULT: fencing ledger-db-1 (Postgres stopped) for 60 s"
  kubectl -n ledger annotate cluster ledger-db cnpg.io/fencedInstances='["ledger-db-1"]' --overwrite >/dev/null
  sleep 60; log "RECOVER: unfencing"
  kubectl -n ledger annotate cluster ledger-db cnpg.io/fencedInstances- >/dev/null
  until [ "$($N get pod ledger-db-1 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = true ]; do sleep 1; done
  log "Postgres pod Ready again"
  wait $DRIVER ;;
latency)
  NODE=$($N get pod ledger-db-1 -o jsonpath='{.spec.nodeName}'); IP=$($N get pod ledger-db-1 -o jsonpath='{.status.podIP}')
  VETH=$(docker exec $NODE ip route get $IP | grep -o 'dev [^ ]*' | cut -d' ' -f2)
  drive --duration 120 --timeout 2
  sleep 30; log "FAULT: +150 ms on every packet into Postgres (tc netem on $NODE/$VETH); client timeout is 2 s"
  docker exec $NODE tc qdisc add dev $VETH root netem delay 150ms
  sleep 60; docker exec $NODE tc qdisc del dev $VETH root; log "RECOVER: delay removed"
  wait $DRIVER ;;
*) echo "unknown drill $DRILL"; exit 2 ;;
esac
[ -n "${SAMPLER:-}" ] && kill $SAMPLER 2>/dev/null; SAMPLER=
log "client view (status per second, 0 = no HTTP answer):"
python3 - $CLIENT >> $OUT <<'PY'
import json,sys
from collections import defaultdict
t=defaultdict(dict)
for sec,st,n in json.load(open(sys.argv[1]))["summary"]["timeline"]: t[sec//10*10][st]=t[sec//10*10].get(st,0)+n
for s in sorted(t): print(f"  t={s:3d}-{s+9:3d}s  " + "  ".join(f"{k}:{v}" for k,v in sorted(t[s].items())))
PY
log "verify:"; python3 -u scripts/drills/verify.py $CLIENT 2>&1 | tee -a $OUT; RC=${PIPESTATUS[0]}
log "drill $DRILL verify exit=$RC"; exit $RC
