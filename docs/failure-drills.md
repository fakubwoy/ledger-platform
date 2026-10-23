# Failure drills

Each drill runs real transfer load, breaks one part of the system on a timer, and then checks that no money was
lost or created and that every request had exactly one effect.

- Driver: [scripts/drills/driver.py](../scripts/drills/driver.py). Every transfer gets its own Idempotency-Key.
  On a timeout, a dropped connection or a 5xx, the client retries **with the same key** until it gets a final
  answer (201 posted or 422 insufficient funds). That is how a correct client behaves, and it is what makes
  "exactly once" checkable.
- Checks: [scripts/drills/verify.py](../scripts/drills/verify.py), the same for every drill:
  - all entries in the ledger sum to zero, every transaction is one debit plus one credit, no customer account
    is negative
  - one stored result and one transaction per acknowledged transfer, so a retry never posted twice
  - replaying **every** acknowledged key returns the same transaction id
  - the outbox drains and every transaction reaches the statement view exactly once (two lines)
- Faults: [scripts/drills/run.sh](../scripts/drills/run.sh) `<drill>`. Raw output: `results/m10-*.txt`.

Accounts start with small balances, so transfers regularly hit "insufficient funds". A transfer applied twice
would show up as a negative balance or an unbalanced ledger.

**Every drill passed every check.** Three ledger replicas minimum. The HPA scaled to 5 under the drill load.

## Summary

| Drill | Fault | Transfers | Requests that failed | Result |
|---|---|---|---|---|
| (a) Pod crash | SIGKILL the JVM in 2 pods, mid-load | 9,503 | 11 (502) | all retried, each applied once |
| (b) Shared outbox | 3+ replicas publish; 50 events forced out a second time | 8,499 | 0 | 8,519 transactions = 8,519 events; duplicates ignored |
| (c) Kafka down | broker down for 11 min 40 s | 98,219 | 0 | transfers never noticed; alert after 6 min; backlog of 93,350 drained in 2.5 min |
| (d) Postgres crash | Postgres pod force-deleted | 33,567 | 24 (500 or no answer) | back in 13 s, all retried, each applied once |
| (d) Postgres down 60 s | Postgres fenced for 60 s | 15,267 | about 280 (500, then fast 503) | all pods taken out of the Service; recovered 10 s after the fence lifted |
| (e) Slow database | +150 ms per packet into Postgres, 2 s client timeout | 12,139 | 210 client timeouts | 147 transfers retried while the first try was still running; each applied once |

## (a) Kill a ledger pod in the middle of a transfer load

[results/m10-pod-kill.txt](../results/m10-pod-kill.txt)

**Expected.** A crash mid-request kills open database transactions. Postgres rolls them back when the connection
dies, including the idempotency key row, so the client's retry runs fresh. A request that committed but whose
response was lost is answered from the stored result on retry.

**What happened.** The JVM was killed with SIGKILL from the node, twice, 30 s apart. 11 requests that were on
those pods got a 502 from the ingress. Each was retried with its key and succeeded. 9,503 transfers, 9,503
transactions, every replay identical.

**Note on the first attempt.** `kubectl delete pod --force` is not a crash. The pod leaves the Service first and
the app still gets SIGTERM, so in-flight requests finish (milestone 6 working as intended). That run had zero
failed requests and proved nothing about crashes. The drill now kills the process instead.

**Guarantee.** Exactly-once *effect* per Idempotency-Key, given a client that retries with the same key. The
network does not give exactly-once delivery; the key plus one database transaction does.

## (b) Several replicas on one outbox

[results/m10-outbox.txt](../results/m10-outbox.txt)

**Expected.** Every replica polls the outbox with `FOR UPDATE SKIP LOCKED`, so they share rows without taking the
same row twice. If a publisher crashes after Kafka acknowledged but before the row is marked published, the row is
sent again, so delivery is at least once and the consumer has to ignore duplicates.

**What happened.**
- Normal operation: 8,519 transactions written (8,499 transfers plus 20 seed deposits) and exactly 8,519 events in
  Kafka. Nothing lost, nothing sent twice.
- The work was shared: three pods published 2,174, 3,686 and 2,620 events (counted from `outbox publish` spans in
  Tempo; the 150 s search window cut off the earliest few, so these sum to 8,480). Two pods the HPA had just added
  published none in that window.
- Forced redelivery: 50 published rows were marked unpublished. 50 duplicate events went to Kafka, and the
  statement view did not change by a single row (425,092 lines before and after), because its primary key
  `(account_id, transaction_id)` makes the insert a no-op.

**Guarantee.** At-least-once delivery to Kafka, exactly-once effect in the statement view through an idempotent
consumer.

## (c) Kafka broker down while transfers continue

[results/m10-kafka.txt](../results/m10-kafka.txt)

**Expected.** Transfers only write to Postgres; the outbox decouples them from Kafka. Transfers keep working, the
backlog grows, `LedgerOutboxStuck` fires, and the backlog drains when Kafka is back.

**What happened.**
- 05:13:44 broker stopped (Strimzi operator scaled to 0, broker pod deleted, so it stays down).
- Transfers continued with **zero** errors: 98,219 posted during the 9 minute run.
- 05:19:54 `LedgerOutboxStuck` firing, 6 min 10 s after the outage began (rule: backlog never reached 0 and grew
  over 5 minutes, held for 1 minute).
- 05:22:30 backlog peaked at 93,350 when the load stopped.
- 05:19:54 operator restored. The broker pod was only Ready at 05:25:24: the operator had to start and reconcile
  first.
- 05:28:00 backlog at 0, about 2.5 minutes at roughly 600 events a second.

**Guarantee.** Eventual consistency between the ledger and its events and read models. The ledger itself is
always consistent; the statement view can lag by as long as Kafka is down.

## (d) Postgres pod deleted

[results/m10-postgres.txt](../results/m10-postgres.txt),
[results/m10-postgres-long.txt](../results/m10-postgres-long.txt),
[results/m10-postgres-graceful.txt](../results/m10-postgres-graceful.txt)

Readiness includes the database (`readinessState, db`), and the pool fails a request after 5 s instead of 30 s.
Liveness does not include the database, so an outage never restarts pods.

**Plain delete: the outage happens later than you think.** CloudNativePG shuts Postgres down "smart" for up to
180 s: no new connections, but existing sessions keep working. The ledger's pool already held its connections, so
it kept serving (24,615 transfers, zero errors) and the real outage began about 3 minutes after the delete.

**Crash (force delete).** Postgres was back in 13 s and recovered from its WAL. 24 requests failed in that window
and were retried. Readiness did **not** take the pods out: the outage was shorter than the detection window
(3 failed probes, 5 s apart).

**60 s outage (fenced).** About 20 s in, all 5 ledger pods were not ready. Before that, clients got 500s after the
5 s pool timeout. After that, the ingress answered 503 immediately because the Service had no endpoints. That is
the point of the readiness gate: fail fast and cheap instead of piling up requests on pods that cannot serve
them. 10 s after the fence was lifted, pods were ready and transfers resumed.

**Guarantee.** No committed transfer is lost (Postgres crash recovery from WAL on the same volume), and the
service recovers by itself. It does **not** stay available: with one primary, a database outage is a ledger
outage.

## (e) Slow network between the app and Postgres

[results/m10-latency.txt](../results/m10-latency.txt)

**Expected.** Every SQL round trip gets slower, transfers take longer than the client's 2 s timeout, and the
client retries while the server is still working on the first attempt. The second request with the same key
waits on the first one's idempotency row lock and then returns its stored result, so it cannot post twice.

**What happened.** `tc netem` added 150 ms to every packet into the Postgres pod for 60 s. Throughput fell from
about 240 to about 3 transfers a second. 210 attempts timed out on the client and 147 transfers needed a retry.
Every one was applied exactly once. Throughput recovered as soon as the delay was removed.

**Guarantee.** Retrying after a timeout is safe. The ledger has no SQL statement timeout, so a much slower
database would hold pool connections longer and turn into 500s from the pool's 5 s connection timeout. That was
not reached here.

## What the system does not guarantee

- **Availability through a database failure.** One Postgres primary. The prod values run 3 instances with
  CloudNativePG failover, which was not tested here.
- **Multi-region or multi-cluster anything.** One cluster, one zone.
- **Kafka durability in dev.** One broker, replication factor 1: losing its volume loses undelivered events
  (the outbox would re-send only rows not yet marked published). Prod values use 3 brokers, RF 3, min ISR 2.
- **Exactly once for clients that do not send an Idempotency-Key.** Without a key, a retry is a new transfer.
- **Cached rejections.** A 422 (insufficient funds) is not stored. Retrying the same key later re-evaluates it,
  and can succeed if the balance has changed.
- **Bounded idempotency storage.** Keys never expire.

## Bugs found by running these

- The first drill design used `kubectl delete --force`, which turned out not to be a crash (see (a)).
- verify.py's statement-view check used a per-row subquery on a column with no index of its own. Against 100,000
  transactions it ran for 27 minutes; a grouped join takes under a second.
- run.sh waited for Kafka with `kubectl wait` on the Kafka resource, which still said Ready from before the
  outage because the operator was down. It now waits for the broker pod.
