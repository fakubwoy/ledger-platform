# Security basics

Each control below is checked by [scripts/m9-security.sh](../scripts/m9-security.sh) against a running pod.
Output: [results/m9-security.txt](../results/m9-security.txt).

| Control | Where | Checked by |
|---|---|---|
| Runs as a non-root user (uid 10001) | pod `securityContext`, `runAsNonRoot` | `id` inside the pod |
| Read-only root filesystem, writable `/tmp` only | container `securityContext`, `emptyDir` on `/tmp` | `touch /app/x` fails, `touch /tmp/x` works |
| No privilege escalation, all Linux capabilities dropped, default seccomp profile | container and pod `securityContext` | `CapEff: 0`, `NoNewPrivs: 1` in `/proc/1/status` |
| Own ServiceAccount with no permissions and no API token mounted | [serviceaccount.yaml](../charts/ledger/templates/serviceaccount.yaml) | `kubectl auth can-i`, no token directory |
| Only the ledger can reach Postgres | [networkpolicy-postgres.yaml](../charts/ledger/templates/networkpolicy-postgres.yaml) | port 5432 open from the ledger, blocked from other pods and namespaces |
| No HIGH/CRITICAL misconfigurations in the chart | trivy `config` in [chart.yml](../.github/workflows/chart.yml) | CI |
| No fixable HIGH/CRITICAL CVEs in the image | trivy `image` in ledger-service CI, before the push | CI |

## Why each one matters

- **Non-root, no capabilities, no privilege escalation.** If someone gets code execution in the JVM, they are an
  unprivileged user who cannot become root, so escaping the container gets much harder.
- **Read-only root filesystem.** The attacker cannot drop a binary or change the app's jars. Only `/tmp` is
  writable, and it is an `emptyDir` that disappears with the pod.
- **No ServiceAccount token.** The token is a credential for the Kubernetes API. The ledger never calls the API, so
  a compromised pod has nothing to steal. The ServiceAccount has no Role either, in case a token is ever mounted.
- **NetworkPolicy on Postgres.** Without it, any pod in the cluster can try to log in to the database. Now only
  the ledger (port 5432), the CloudNativePG operator (status port 8000) and other database instances can connect.
  Kafka is covered by the NetworkPolicies Strimzi generates for its listeners.

NetworkPolicy is only as good as the CNI that enforces it. Some CNIs ignore it silently. I checked kindnet with a
deny-all test first: traffic was reachable before the policy and blocked after.

## Scanning

The chart scan proves itself: the chart from before this change fails with 3 HIGH findings (no read-only root
filesystem, a default security context that allows root) and the current chart has none.

The image scan runs after the build and before the push, so a vulnerable image never reaches GHCR or the cluster.
It fails on HIGH and CRITICAL findings that have a fix available.

### Accepted findings

Two CRITICAL CVEs in `spring-webmvc` 6.2.19 are fixed only in Spring Framework 7 (Spring Boot 4). 6.2.19 is the
newest 6.2 release on Maven Central. Neither applies to this service:

| CVE | Needs | This service |
|---|---|---|
| CVE-2026-47884 (RCE) | server-side view rendering with `XsltView` | only `@RestController` endpoints, no view resolver or template engine |
| CVE-2026-47890 (stream corruption) | Server-Sent Events with view fragments | no SSE |

They are listed with these reasons in ledger-service's `.trivyignore.yaml` and expire on 2027-01-31. After that CI
fails again and someone has to look. The real fix is upgrading to Spring Boot 4.

## Not covered

- Pod Security Admission labels on the namespace (`restricted`), which would reject a pod that drops these
  settings, instead of relying on the chart.
- Egress policies: the ledger can still open connections anywhere.
- Image signing and verifying signatures at admission (cosign, policy controller).
- The dev Secret is committed in plain text. Prod values expect an existing Secret from a secret manager.
