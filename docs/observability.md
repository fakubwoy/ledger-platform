# Observability

## Metrics, logs and traces

**Metrics** are numbers counted over time: requests per second, p95 latency, outbox backlog. They are cheap to
store and fast to query, so they drive dashboards and alerts. They tell you *that* something is wrong and roughly
*where* (which endpoint, which pod), but not *why*, because a counter has thrown away the details of each request.

**Logs** are the details of individual events, written by the code as it runs. They tell you *what the code
thought was happening*: which account, which error message, which request id. They are expensive to search at
scale, so you go to them once metrics have narrowed down when and where.

**Traces** follow one request through every step it takes: the HTTP handler, each SQL statement, the outbox write,
the Kafka publish, the consumer on the other side. Each step is a span with a start and a duration. They tell you
*where the time went* inside a single request, which neither metrics (aggregated) nor logs (no timing between
steps) can show.

They are linked: every log line carries the `trace_id` of the request that wrote it, Grafana turns that field into
a link to the trace in Tempo, and a trace links back to its logs in Loki.

## How it is wired

| Signal | Source in the app | Collected by | Stored in |
|---|---|---|---|
| Metrics | Micrometer, `/actuator/prometheus` | Prometheus via a `ServiceMonitor` | Prometheus |
| Logs | Spring Boot ECS JSON to stdout, with `requestId` and `trace_id` from MDC | Grafana Alloy (Kubernetes API) | Loki |
| Traces | OpenTelemetry Java agent (HTTP, JDBC, Kafka auto instrumentation) | OTLP gRPC | Tempo |

The outbox publisher runs on its own thread, so on its own the Kafka publish would start a new trace. The outbox
row stores the W3C `traceparent` of the request that wrote it (migration V5), and the publisher starts its span
with that as the parent. One transfer is therefore one trace, from the HTTP request to the consumer that builds
the statement view.

## SLOs and alerts

| SLO | Target | Error budget |
|---|---|---|
| Transfers succeed (no 5xx) | 99.5% | 0.5% |
| Transfers finish under 300 ms | 95% | 5% |

Alerts fire on the burn rate (how fast the budget is being spent), not on a raw threshold. Each alert needs two
windows to agree: a long one so a short blip does not page, and a short one so the alert clears soon after the
problem stops.

| Alert | Condition | Meaning |
|---|---|---|
| `*FastBurn` | burn > 14.4x over 5m and 1h | a month of budget gone in about 2 days: page |
| `*SlowBurn` | burn > 6x over 30m and 6h | a month of budget gone in about 5 days: ticket |
| `LedgerOutboxStuck` | backlog never reached 0 in 5m and grew over those 5m | events are written but not published |

Rules: [charts/ledger/templates/prometheusrule.yaml](../charts/ledger/templates/prometheusrule.yaml).
Dashboard JSON: [charts/ledger/dashboards/ledger.json](../charts/ledger/dashboards/ledger.json).

## Fault drill: slow query

Script: [scripts/m7-fault-slow-query.sh](../scripts/m7-fault-slow-query.sh). Raw output:
[results/m7-slow-query.txt](../results/m7-slow-query.txt).

Under steady load (10 virtual users), a Postgres trigger was added that sleeps 400 ms on every insert into
`entries`. The investigation then used only the dashboard, one trace and the logs.

| Time | Event |
|---|---|
| 09:49:26 | p95 latency 100 ms just before injection, then fault injected |
| 09:50:58 | `TransfersLatencySlowBurn` firing (+92 s) |
| 09:50:58 | root cause identified (+92 s, same minute as the alert) |

1. **Dashboard.** p95 latency for `POST /transfers` had jumped to 2.1 s, far above the 300 ms line. Error rate,
   outbox backlog and Kafka consumer lag were all normal. So the service was slow, not broken, and the async side
   was keeping up.

   ![Dashboard during the fault](../results/screenshots/dashboard-during-fault.png)

2. **Trace.** The slowest recent transfer took 815 ms. Almost all of it sat inside two `INSERT ledger.entries`
   spans of 401 ms each. Every other SQL statement took under 2 ms. The time was being spent inside Postgres, on
   one table, on insert.

   ![Trace of a slow transfer](../results/screenshots/trace-slow-query.png)

3. **Logs.** Searching Loki for the trace id returned the `Posted TRANSFER` line for that request with its
   `requestId`, so the slow request could be tied back to the caller.

From there the next step for a real incident is to look at what changed on `entries` (a trigger, a new index, a
lock), which here was the injected trigger.

**Honest caveat:** I injected the fault, so this measures how fast the tools point at the cause, not how fast an
engineer who did not know the cause would get there.

The burn-rate alert fired after 92 s because the fault was extreme: every transfer became slow, so the 5 minute
and 1 hour ratios crossed 72% almost at once. A partial slowdown would take longer to alert, by design.

The `LedgerOutboxStuck` alert is defined but not exercised here. The broker restart drill in milestone 10 tests
it.
