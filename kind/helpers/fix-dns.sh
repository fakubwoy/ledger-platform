#!/usr/bin/env bash
# Start the DNS-over-TLS resolver on the kind network and point every kind node at it. Idempotent: rerun after a Docker restart.
set -eu
CLUSTER=${1:-ledger}
DIR=$(cd "$(dirname "$0")" && pwd)
docker rm -f kind-dns >/dev/null 2>&1 || true
docker run -d --name kind-dns --restart unless-stopped --network kind \
  -v "$DIR/Corefile:/Corefile:ro" coredns/coredns:1.12.0 -conf /Corefile >/dev/null
# kind's network has no user-set subnet, so Docker picks the IP. Rerun this script if Docker restarts.
DNS_IP=$(docker inspect kind-dns -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
for n in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$n" sh -c "printf 'nameserver $DNS_IP\noptions ndots:0\n' > /etc/resolv.conf"
done
sleep 2
docker exec "$CLUSTER-worker" getent hosts ghcr.io >/dev/null && echo "node DNS ok"
