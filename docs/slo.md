# Service level objectives

> **Maintained version:** slo-platform [`docs/concepts.md`](https://github.com/MIERAI/slo-platform/blob/main/docs/concepts.md) (and [`configuration.md`](https://github.com/MIERAI/slo-platform/blob/main/docs/configuration.md) for how SLOs are declared).
> This page is where the principles started and is kept for history; slo-platform's docs are what is kept current.

How the platform decides what is "reliable enough", when a human is woken up, and what happens when an application
is not reliable enough. The rules here are what [gitops-manifests](https://github.com/MIERAI/gitops-manifests) implements
(SLOs declared in each `app.yaml`, rendered by the platform into [Pyrra](https://github.com/pyrra-dev/pyrra) objectives
and burn-rate alerts) and what the fault experiments test.

Short version:

1. An SLO measures what a **user** of the service experiences, as a ratio `good events / valid events`.
2. Only an SLO burning fast **pages**. Everything else is a ticket or a dashboard.
3. Every alert has been **seen firing in an experiment** before anyone relies on it, and normal traffic must not page.
4. When the error budget is spent, reliability work comes before features.

## 1. What gets an SLO

Pick the SLI by the **shape** of the service, not by the service. One representative per shape is enough to learn on.

| Shape | What the user cares about (SLI) | Representative here |
|---|---|---|
| Request / response | availability (non-5xx and not degraded), latency (share under a threshold), a probe from outside | sample-app `/hello`, storefront api, api-factory |
| Dependency chain (A calls B) | the same, measured at the edge the user sees (A); B's own SLO says whose fault it is | storefront web → api |
| Asynchronous pipeline | intake, freshness (orders older than N processed), completeness (processed in time) | storefront orders: web → Postgres → worker |
| Scheduled job | a fresh good result exists (age of the last success), the recovery point keeps up | database backups, WAL archiving, restore check, off-site copy |
| Delivery | lead time, change failure rate (SLOs, tickets); deployment frequency, time to restore (dashboard) | delivery board (`docs/dora.md` there) |

## 2. SLI rules

- **From the user's side.** Count what the user received, not what the process did. A page rendered with "products
  unavailable" and status 200 is a **bad** event: storefront web labels it `result="degraded"`.
- **Ratio of events, not averages.** `good / valid` over a window; p95 hides how many users were slow, a ratio does
  not. Latency SLI = share of requests faster than a threshold.
- **The threshold is a histogram bucket edge.** "99% under 500 ms" needs a bucket `le="0.5"`; interpolating between
  buckets is a guess. Choose the buckets when choosing the SLO.
- **Client errors are not bad events.** 4xx is the API working as specified. They are still counted as valid events.
- **Counters in the application, not regexes over logs.** Labels stay low-cardinality: route *pattern*, status code,
  result. Never user ids or raw paths.
- **No data is not zero errors.** A broken scrape or a renamed metric makes an error ratio silently vanish; every
  SLO gets an "SLI absent" alert (ticket).
- **Measure from outside too.** An SLI counted inside the pods cannot see an outage with no pod left to count it:
  every sample-app pod down, or api-factory's database down (readiness took every pod out of the Service), paged
  nobody until a `probe` SLO (a blackbox prober calling the service) was added. Every user-facing service has one.
- **Health checks must not check dependencies.** Liveness answers "is this process stuck?", readiness "is this
  process ready?" — neither pings the database. Otherwise a database outage restarts every pod in a loop and takes
  them all out of the Service: users get connection refused instead of an error, the in-pod SLIs count nothing, the
  restarts clear the counters. A deep check (`/healthz`) is for the external probe only.
- **Probes tolerate slowness.** With the default 1s timeout, a 600ms network delay on storefront api made both
  pods fail readiness and liveness: they left the Service and restarted, slowness became an outage, and the latency SLO
  never burned (calls failed fast). Readiness 3s; liveness only detects a stuck process: 5s × 6 before a restart.
- **Two latency thresholds.** A mild one (e.g. 99% under 100 ms) burns slowly — a +200 ms database paged after 15
  min, ≈4% of the budget, by design; a severe one (99.9% under 1 s) pages within minutes when slowness is as bad as
  an outage.
- **Test with open-loop traffic.** Synthetic traffic that waits for each answer sends less when the service slows
  down and hides it; send at a fixed rate (k6 arrival-rate, background calls).
- **Write down the caveats.** What the SLI does not see (e.g. requests that never reach the pod) goes in the SLO's
  description.
- **An SLI that matches nothing is the classic mistake** (storefront's route label was `GET /{$}`, not `GET /`): the
  "SLI absent" ticket found it within minutes. Check the series in Prometheus before writing matchers.

## 3. Declaring an SLO

In the application's `app.yaml` (one place, like everything else about an application); the platform (gitops-manifests
`platform/slo`) renders one Pyrra objective per SLO and environment, every query scoped to the environment's
namespace — one declaration serves dev, staging and prod.

```yaml
slos:
  - name: web-availability
    description: The page served completely (not 5xx, not degraded). Blind to requests that never reach a pod.
    objective: 99.5            # percent good, over the window (default 28d)
    availability: { metric: http_requests_total, matchers: 'app="web", route="GET /{$}"', errors: 'result!="ok"' }
  - name: web-probe
    objective: 99.5
    probe: { service: web, port: 8080, path: "/" }
  - name: web-latency
    objective: 99
    latency: { metric: http_request_duration_seconds, matchers: 'app="web", route="GET /{$}"', threshold: "0.5" }
```

| Type | Good / bad | For |
|---|---|---|
| `availability` | bad = `metric{matchers, errors}` among `metric{matchers}` | requests |
| `latency` | good = `metric_bucket{le=threshold}` among `metric_count` (threshold = a bucket edge) | requests |
| `probe` | `probe_success` from a blackbox prober outside the pods (also renders the Probe) | every user-facing service |
| `ratio` | bad = one counter among another (e.g. orders overdue among orders created) | pipelines |
| `age` | good while the last success (a unix-time gauge) is at most `max` old | scheduled jobs, freshness |
| `bool` | a 0/1 gauge made elsewhere | platform-level SLIs |

Optional per SLO: `environments` (only these), `severities` (override page/ticket per burn tier), `runbook` (anchor).

## 4. Alert layers

| Layer | Fires on | Route | Examples |
|---|---|---|---|
| **L1 page** | users affected now, a human must act now | `severity: page` → speaker / phone | SLO fast burn (14× over 1h and 5m), medium burn (7× over 6h and 30m) |
| **L2 ticket** | budget eroding slowly, or a safety net is broken | `severity: ticket` → work queue | slow burn (2× over 1d, 1× over 4d), SLI absent, backups, restore check, replication |
| **L3 dashboard** | causes, not symptoms | no notification | CPU, memory, restarts, queue depth, dependency latency |

Rules for paging:

- Page on **symptoms** (an SLO burning), never on causes. A pod restart that no user noticed is not a page.
- A burn-rate alert needs **two windows** (long: is it significant? short: is it still happening?), so it fires fast on
  a real outage, stays quiet on a single bad minute, and resolves soon after recovery.
- Every page links to a runbook section whose **first step** finds the cause (`runbook` annotation).
- **An unactionable page is a bug** in the alert: fix or demote it the same week.
- **Only prod notifies.** dev / staging alerts are visible (Alertmanager, Grafana) and notify nobody: their low
  traffic and the experiments run there made every short fault page twice.
- **One incident, one announcement.** Group per service (a database outage burns four SLOs); while an SLO's fast
  burn pages, its 6h page and its tickets are inhibited.
- **A young SLO is oversensitive.** With little history in its windows (new SLO, Prometheus storage lost) a short
  blip is a large share: expect extra pages in its first 6 hours. Keep Prometheus on a volume, with a retention longer
  than the SLO window (30 days for 28).
- Target: fewer than ~2 pages per application per week, and every one of them actionable.

## 5. Alerts are tested

An alert that has never fired is a hope, not a safety net. Each failure mode has a fault experiment
(gitops-manifests `experiments/`, run by `scripts/experiment.py`, on the lab cluster only):

- **hypothesis and predictions, committed before the run**: which alert fires on which SLO within how long, which
  must stay quiet; nothing else may page. A wrong prediction is a finding: record it, never edit it afterwards to
  pass — write a corrected experiment instead.
- **the fault must bite**: a fault tool saying "injected" only means its rules are in place (a network fault on the
  client side never matched traffic to a Service). Each experiment states an `effect` query that proves the fault is
  visible in the traffic; application faults (an error a service returns itself) use fault switches.
- **one experiment per namespace**, across people and processes (a namespace annotation is the lock), and its late
  alerts still belong to it for 30 minutes.

The **negative test** matters as much: hours of realistic traffic (day/night shape, bursts, client errors) must not
page. Its first run found a real defect within a minute (a missing index: one procedure at 175 ms in prod only,
invisible to the old p95 > 500 ms alert). Experiments run on a schedule, like unit tests for alerting: change an
alert rule, the next run tells whether it still fires — and whether it now fires when it should not.

## 6. Error budget policy

The budget is `100% − objective` of the window's events (99.5% over 28 days ≈ 3.4 hours of full outage).

| Budget left (28d) | What happens |
|---|---|
| > 25% | normal: ship features, promote when the gates pass |
| 0–25% | promotions to prod need a stated reason; the top reliability issue is planned next |
| exhausted | feature promotions to prod stop; only fixes and reliability work ship until the budget is positive again |
| fast burn during a rollout | roll back first, investigate second |

Exceptions (a budget spent by a dependency outside our control, a bad SLI) are decided explicitly and written in the
postmortem, not silently ignored.

**Enforced by the delivery board's promotion gate** (MIERAI/delivery-board `docs/error-budget.md`) for promotions into
prod. The budget is the lowest of the application's SLOs in prod, from Pyrra: `(availability − objective) / (1 −
objective)` over 28 days, plus its fast-burn alert. A promotion declares `change: feature | fix | exception` and a
`reason`. These are inputs of gitops-manifests `promote.yml` and the board's Promote form, and are written into the
promotion PR as `Change:` / `Reason:`.

- **> 25%:** passes.
- **0–25%:** needs a reason.
- **Exhausted or fast burn:** only `fix` (fixes, reliability work, rollbacks) or `exception`, each with a reason.
- **Unknown budget** (no SLO, no data, Prometheus unreachable): **fails closed**, like an exhausted budget. A missing SLI is
  not a healthy one (§2), and an unknown budget is an exception decided explicitly. Fixes still ship.

The board shows each app's verdict and judges an open promotion PR's declaration. It does not block the merge itself;
a person does.

## 7. Postmortems

Write one, blameless, when an incident **paged**, spent **more than 20% of a budget**, or needed a **manual data
fix**. Within a week:

```markdown
# <date> <one-line what users saw>

Impact: who / what / how long; budget spent (% of 28d).
Detection: which alert, after how many minutes; or how it was noticed if no alert fired (that is a finding).
Timeline: detection → mitigation → resolution, UTC.
Cause: the trigger and why it could reach users.
What went well / what went badly / where we were lucky.
Actions: each with an owner and a ticket; at least one makes the alert or the experiment catalog better.
```

## 8. Review

Monthly: pages per application, share actionable, budget per SLO, experiments run and failed. An alert that fired and
nobody acted on is demoted or deleted; an incident no alert caught gets an experiment.
