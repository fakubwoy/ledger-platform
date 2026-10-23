# Raw manifests (milestones 1 to 3)

The first version of the deployment, written by hand before Helm: Namespace, ConfigMap, Secret, Deployment,
Service, then the CloudNativePG and Strimzi resources. Kept to show the plain Kubernetes objects that the chart
in [charts/ledger](../charts/ledger) now generates.

**Not what runs.** The cluster is deployed by Argo CD from the chart; these files are not kept in sync with it.
