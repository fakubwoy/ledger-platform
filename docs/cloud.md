# Running on Azure (AKS) and GCP (GKE)

The same Helm chart runs on kind, AKS and GKE. Only the values file changes. Each cloud has a Terraform module
for the cluster, a managed Postgres and a secret store.

**Status.** GKE was deployed for real on 2026-10-23 (`terraform apply`, the chart with `values-gke.yaml`, a
failure drill), then destroyed. AKS is written and passes `terraform validate`, but has not been applied: there is
no Azure account set up on this machine.

## What changes per environment

| | kind (dev) | AKS | GKE |
|---|---|---|---|
| Cluster | `kind/cluster.yaml` | [terraform/aks](../terraform/aks) | [terraform/gke](../terraform/gke) |
| NetworkPolicy enforced by | kindnet | Azure CNI overlay + Cilium | Dataplane V2 (Cilium) |
| Postgres | CloudNativePG in-cluster | Azure Database for PostgreSQL, private VNet access | Cloud SQL, private IP |
| DB password | chart-created dev Secret | Key Vault, synced by External Secrets | Secret Manager, synced by External Secrets |
| Kafka | Strimzi, 1 broker | Strimzi, 3 brokers, RF 3, min ISR 2 | same as AKS |
| Image | GHCR | GHCR | GHCR |
| Values | `values-dev.yaml` | [values-aks.yaml](../charts/ledger/values-aks.yaml) | [values-gke.yaml](../charts/ledger/values-gke.yaml) |

The chart switches to a managed database with `postgres.enabled: false` and `db.url`. Everything else
(probes, rollout settings, HPA, PDB, security context, ServiceAccount) is identical.

## Secrets and identity

The ledger pod still gets **no cloud identity and no Kubernetes token** (see [security.md](security.md)). Only the
External Secrets Operator has a cloud identity:

1. Terraform stores a random DB password in Key Vault or Secret Manager and sets it on the managed database.
2. Terraform creates an identity for External Secrets and federates it with the
   `external-secrets/external-secrets` ServiceAccount (AKS Workload Identity, GKE Workload Identity). There are no
   key files or client secrets anywhere.
3. [platform/cloud/aks/external-secret.yaml](../platform/cloud/aks/external-secret.yaml) (or the GKE one) makes
   External Secrets write the `ledger-db` Secret, the same Secret the chart already reads.

If the ledger pod is compromised, the attacker has the DB password (unavoidable: the app needs it) but no path
to the secret store or any other cloud API.

## GKE: what running it for real found

Running it found five problems that `terraform validate` and `helm template` could not. Four were real bugs in
the design; one was in my test scripts.

1. **Terraform ordering.** The Workload Identity binding for External Secrets needs the identity pool
   `<project>.svc.id.goog`, which GKE only creates with the cluster. Fixed with `depends_on`.
2. **Connection pool too large for the database.** `db-f1-micro` allows 25 connections (22 usable). Each ledger
   pod opened HikariCP's default 10, so three pods already exceeded it: throughput collapsed and a fourth pod
   could not even run Flyway at startup and crash-looped. Fixed with a `db.poolSize` chart value. The budget is
   `(maxReplicas + maxSurge) x poolSize`: with only `maxReplicas x poolSize` the next rolling update deadlocked,
   because `maxUnavailable: 0` waits for the new pod, which waits for a connection the old pods hold.
3. **A node power loss turned into a full outage.** In the node-crash drill (below), the dead pods' database
   sessions stayed "idle in transaction" holding row locks. A power cut sends no TCP reset, and Cloud SQL's
   defaults (no idle-in-transaction timeout, about 12 minutes to detect a dead client) kept them alive. Every
   healthy pod's pool filled with requests waiting on those locks, readiness failed everywhere, and the service
   stopped answering. The kind drills never showed this: killing a process there closes its sockets, so Postgres
   aborts the transaction at once. Fixed in two layers:
   - database: `idle_in_transaction_session_timeout = 10 s` and keepalive probes every 10 s (Cloud SQL flags in
     [terraform/gke](../terraform/gke/main.tf); the same timeout for Azure and for CloudNativePG on kind)
   - app: `lock_timeout = 5 s` on every connection, so a request blocked on a lock fails and the client retries
     instead of holding a pooled connection
4. **Kafka lost quorum from one node.** Each broker is also a KRaft controller. With 3 brokers on 2 nodes, a node
   holding 2 of them takes the controller quorum down and all 3 brokers stop. Transfers kept working (the outbox
   absorbs it), but Kafka needs 3 failure domains: anti-affinity across 3 nodes or zones. Not fixed: it would
   mean a third node.
5. **Test harness bugs.** The psql pod used by verify was a bare pod and died when it landed on the reset node,
   and the port-forward for verify collided with the kind cluster's ingress on port 8080. Both fixed in
   [scripts/drills/gke-node-crash.sh](../scripts/drills/gke-node-crash.sh).

### Node-crash drill: before and after

`gcloud compute instances reset` power-cycles a node running ledger and Kafka pods, mid-load, with the load
driver running inside the cluster against the ledger Service.

| | Before the fix | After the fix |
|---|---|---|
| Transfers without a final answer | 12 | 0 (3,005 posted) |
| Ledger pods on the healthy node | not ready, pools full of blocked requests | stayed ready |
| Service | stopped answering until the zombie sessions were killed by hand | dipped for about a minute, then recovered |
| verify | could not connect (no free connection slots) | every check passed |

Raw output: [after](../results/m10-gke-node-crash.txt),
[before](../results/m10-gke-node-crash-before-fix.txt),
[first run with the oversized pool](../results/m10-gke-node-crash-run1-pool-exhausted.txt).

### Also proven on GKE

- External Secrets with GKE Workload Identity read the password from Secret Manager and created the `ledger-db`
  Secret: no key file anywhere, and the ledger pod still has no token.
- The chart ran unchanged apart from the values file, against Cloud SQL over a private IP with TLS.

### Cost

One session of about 1.5 hours: two e2-standard-2 nodes, the smallest Cloud SQL instance and three 20 GB disks.
Roughly a couple of dollars. Kafka's disks were deleted with their namespace before `terraform destroy`, because
Kubernetes created them, not Terraform, and they would otherwise have been left behind and billed. The project
was deleted afterwards.

## Bring-up

```
cd terraform/gke && terraform init && terraform apply -var project=...      # or terraform/aks, -var subscription_id=...
$(terraform output -raw get_credentials)
helm upgrade --install strimzi platform/charts/strimzi-kafka-operator-1.3.0.tgz -n strimzi-system \
  --create-namespace --set 'watchNamespaces={ledger}'
helm upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace \
  --set installCRDs=true --set serviceAccount.annotations.iam\.gke\.io/gcp-service-account=<external_secrets_gsa>
sed "s/<your GCP project>/<project>/" platform/cloud/gke/external-secret.yaml | kubectl apply -f -
helm upgrade --install ledger charts/ledger -n ledger -f charts/ledger/values-gke.yaml --set db.url=<db_url>
```

Tear down: delete the `ledger` namespace and wait for its volumes to go, then `terraform destroy`.

## Deliberate choices

- **Managed Postgres, in-cluster Kafka.** Postgres holds the money, so backups, point-in-time recovery and
  patching are worth paying a provider for. Kafka only carries events that the outbox can always re-send, so
  Strimzi keeps it portable across both clouds. Event Hubs (Kafka API) or Google Managed Kafka would be the next
  step.
- **One image registry (GHCR) for all three.** ACR or Artifact Registry would cut pull latency and egress, but
  GHCR keeps one CI pipeline for every environment.
- **Monitoring off in the cloud values.** The chart's ServiceMonitor and PrometheusRule need kube-prometheus-stack.
  On AKS/GKE the managed Prometheus services use their own CRDs, so the rules would need porting.

## Not covered

- Remote Terraform state (a storage bucket with locking) and a CI job that runs `terraform plan`.
- Database backups and restore drills on the managed services.
- AKS has not been applied.
- Kafka spread over 3 failure domains (see finding 4).
- Multi-region or multi-zone node pools: both modules are single-zone to stay cheap.
