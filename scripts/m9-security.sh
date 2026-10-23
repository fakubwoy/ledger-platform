#!/usr/bin/env bash
# Milestone 9: check each security control from the inside (exec into a ledger pod) and the outside.
set -u
N="kubectl -n ledger"
P=$($N get pods -l app.kubernetes.io/name=ledger --field-selector=status.phase=Running -o name | head -1)
ex() { $N exec "$P" -c ledger -- bash -c "$1" 2>&1; }
tcp() { echo "timeout 3 bash -c '</dev/tcp/$1/$2' && echo OPEN || echo BLOCKED"; }

echo "## Non-root";                         ex 'id'
echo; echo "## Read-only root filesystem";  ex 'touch /app/x 2>&1 | sed "s/^/write \/app: /"; touch /tmp/x && echo "write /tmp: ok (emptyDir)"'
echo; echo "## No privilege escalation, no capabilities"; ex 'grep -E "^(NoNewPrivs|CapEff)" /proc/1/status'
echo; echo "## No Kubernetes API token mounted"; ex 'ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 | head -1'
echo; echo "## ServiceAccount permissions (beyond the defaults every account gets)"
kubectl auth can-i --list --as=system:serviceaccount:ledger:ledger -n ledger | grep -vE '^(selfsubject|\s*\[/|Resources)' | grep -vE '^\s*$' || echo "none"
echo "can list secrets? $(kubectl auth can-i list secrets --as=system:serviceaccount:ledger:ledger -n ledger)"
echo "can list pods?    $(kubectl auth can-i list pods --as=system:serviceaccount:ledger:ledger -n ledger)"

echo; echo "## NetworkPolicy: who can reach Postgres (ledger-db-rw:5432)"
echo "from the ledger pod:                $(ex "$(tcp ledger-db-rw 5432)")"
echo "from another pod in ledger ns:      $($N run np$RANDOM --rm -i --restart=Never --image=busybox:1.36 -- sh -c 'nc -w 3 ledger-db-rw 5432 </dev/null && echo OPEN || echo BLOCKED' 2>/dev/null | grep -E 'OPEN|BLOCKED')"
echo "from the monitoring namespace:      $(kubectl -n monitoring run np$RANDOM --rm -i --restart=Never --image=busybox:1.36 -- sh -c 'nc -w 3 ledger-db-rw.ledger 5432 </dev/null && echo OPEN || echo BLOCKED' 2>/dev/null | grep -E 'OPEN|BLOCKED')"
echo "CNPG still manages the cluster:     $($N get cluster ledger-db -o jsonpath='{.status.phase}')"
echo "app still healthy:                  $(curl -s localhost:8080/actuator/health)"
