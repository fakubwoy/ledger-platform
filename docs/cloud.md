# Running on Azure (AKS) and GCP (GKE)

The same Helm chart runs on kind, AKS and GKE. Only the values file changes. Each cloud has a Terraform module
for the cluster, a managed Postgres and a secret store.

**Status:** `terraform validate` passes for both modules and `helm lint`/`helm template` pass for both values files.
Neither has been applied: that needs a cloud account and costs money (roughly 2 small nodes plus the smallest
managed Postgres). Treat this as a reviewed design, not a tested deployment.

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

## Bring-up (not run)

```
cd terraform/aks && terraform init && terraform apply -var subscription_id=...    # or terraform/gke, -var project=...
$(terraform output -raw get_credentials)
# install Strimzi (platform/charts), ingress-nginx and External Secrets Operator, then:
kubectl apply -f platform/cloud/aks/external-secret.yaml          # after filling the <...> values
helm upgrade --install ledger charts/ledger -n ledger --create-namespace -f charts/ledger/values-aks.yaml
```

With Argo CD, the same thing is a second Application pointing at `values-aks.yaml`.

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
- Multi-region or multi-zone node pools: both modules are single-zone to stay cheap.
