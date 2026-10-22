#!/usr/bin/env bash
# Milestone 3: write money data, delete the Postgres pod, show the data and the volume survive.
set -eu
N="kubectl -n ledger"
kubectl -n ledger port-forward svc/ledger 8080:80 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 3
J='Content-Type: application/json'
acct() { curl -fs -XPOST localhost:8080/accounts -H "$J" -d "{\"owner\":\"$1\",\"currency\":\"USD\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])'; }
bal()  { curl -fs localhost:8080/accounts/$1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["balance"])'; }
A=$(acct alice); B=$(acct bob)
curl -fs -XPOST localhost:8080/accounts/$A/deposits -H "$J" -H "Idempotency-Key: m3-dep-$RANDOM$RANDOM" -d '{"amount":1000}' >/dev/null
curl -fs -XPOST localhost:8080/transfers -H "$J" -H "Idempotency-Key: m3-tr-$RANDOM$RANDOM" -d "{\"fromAccountId\":\"$A\",\"toAccountId\":\"$B\",\"amount\":250}" >/dev/null
echo "before: alice=$(bal $A) bob=$(bal $B)"
echo "pod:    $($N get pod ledger-db-1 -o jsonpath='{.metadata.uid}')  pvc: $($N get pvc ledger-db-1 -o jsonpath='{.spec.volumeName}')"

echo "--- deleting the Postgres pod"
$N delete pod ledger-db-1 --wait=true >/dev/null
$N wait cluster/ledger-db --for=condition=Ready --timeout=240s >/dev/null
echo "pod:    $($N get pod ledger-db-1 -o jsonpath='{.metadata.uid}')  pvc: $($N get pvc ledger-db-1 -o jsonpath='{.spec.volumeName}')"
for i in $(seq 30); do bal $A >/dev/null 2>&1 && break; sleep 2; done
echo "after:  alice=$(bal $A) bob=$(bal $B)"
