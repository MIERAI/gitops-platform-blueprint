# Lessons learned

Problems hit while building this platform, each with the symptom, the cause and the fix. Most of them looked like
something else first; the measurement that settled each one is noted.

## Delivery (CI, Argo CD)

| Symptom | Cause | Fix |
|---|---|---|
| Argo CD UI / API unreachable on kind | Upstream Argo CD NetworkPolicies; kindnet drops the ingress they allow | Remove them locally (`$patch: delete` in `infrastructure-live/argocd`) |
| Sync stuck forever on an old hook | A hook Job that can never finish (image not pullable) blocks the sync | `activeDeadlineSeconds` on every hook Job |
| Pod rejected: `runAsNonRoot` with a named user | The kubelet cannot verify a user *name* is non-root | Numeric UID (`runAsUser: 65532`) |
| Image tag `1234567` deployed as `1.234567e+06` | An all-digit short SHA is a YAML number | Quote tags in every overlay (`set-image.sh` / `promote.sh` write `"tag"`) |
| Trivy fails the schema image (CRITICAL in `gosu`) | The `postgres` base image carries gosu | Schema image on `alpine` + `postgresql-client` |
| Promote workflow cannot open a PR | Repository setting: Actions may not create PRs | Enable it for gitops-manifests |
| Bot PRs never merge | PRs opened with `GITHUB_TOKEN` do not trigger workflows → required check missing | The promote workflow validates and reports the `validate` commit status itself |
| e2e on GitHub runners: wrong kind version | kind preinstalled on the runner image shadows ours | Install into `RUNNER_TEMP` and use that path |
| Argo CD Application OutOfSync forever (Kyverno CRDs) | Upstream manifest has `labels: {}`; the API server drops empty maps | Add a real label with a kustomize patch (found by diffing `predictedLiveState` / `normalizedLiveState` from the Argo CD API) |
| `ship.sh` wiped uncommitted work | A failed commit (zsh did not split `-c user.name=…` from a variable) and the script still ran `reset --hard` | The script refuses to run with uncommitted changes or nothing to ship; run multi-step git in `bash`, not zsh |

## Progressive delivery

| Symptom | Cause | Fix |
|---|---|---|
| Faulty canary passed (first 3 fault-injection runs) | Several real bugs, below | Each fixed; the fault-injection run is the test of the analysis |
| Analysis found no data | Short service name in the Prometheus address from another namespace | FQDN `kps-prometheus.monitoring.svc.cluster.local` |
| Canary got no traffic | Keep-alive connections of the traffic generator stayed pinned to old Pods (conntrack) | `Connection: close` in the synthetic traffic |
| Healthy canary aborted in prod | `errors / total` is *empty* when there are no errors | `(errors or vector(0)) / total` |
| Fully broken canary "failed" only by accident | `1 - success / total` is empty when *everything* fails | Same expression: no error series counts as 0, no traffic stays empty (= fail safe) |
| Lock-contention regression shipped | Metric analysis at 2 rps: p95 stayed ~20ms; at 100 rps it was 661ms (healthy: 0.84ms) | k6 load test against the canary in the analysis step; the same fault was then aborted in 53s |

## Observability

| Symptom | Cause | Fix |
|---|---|---|
| Grafana restarting (exit 137) | Liveness probe killed it before its first start completed | `initialDelaySeconds: 180`, 512Mi |
| Prometheus cannot scrape the API | `/metrics` sat behind the API's auth | Separate internal listener (`METRICS_PORT`) |
| Unformatted Go merged | CI only ran `go vet` / tests | `gofmt -l` check in CI |

## Data (CloudNativePG)

| Symptom | Cause | Fix |
|---|---|---|
| Deprecation warning for `barmanObjectStore` | Removed in CloudNativePG 1.31 | Barman Cloud plugin (needs cert-manager) |
| WAL archiving failed: `Expected empty archive` | Another cluster's WAL under the same path (safety check) | New prefix / clear the obsolete one |
| Failover took 197s with the API connected | Smart shutdown waits for clients; a connection pool never disconnects (a probe with fresh connections measured 4s and hid it) | `smartShutdownTimeout: 10` → 25–49s |
| PITR drill took 427s | `psql -c "DELETE …; SELECT pg_switch_wal()"` is one transaction: the commit landed after the switch and waited for `archive_timeout` (5 min) | Separate statements, wait for `pg_stat_archiver` → 57s |
| ~1 min of `relation does not exist` while migrating to CloudNativePG | The API reconnected to the new empty database before the schema Job ran | Real migrations: move the data before switching the connection |
| Old StatefulSet volumes left behind | Argo CD does not prune PVCs created from `volumeClaimTemplates` | Delete them by hand after checking nothing mounts them |

## Admission policies (Kyverno)

| Symptom | Cause | Fix |
|---|---|---|
| (avoided) Database Pods would have been rejected | The plugin-injected sidecar had no resources: found in **Audit** mode before enforcing | `instanceSidecarConfiguration.resources`; Pods only pick it up when re-created |
| Restore drill stuck after enforcing | The drill's temporary cluster had no resources: its bootstrap Job was denied | Resources in the drill's Cluster spec |
| PolicyException ignored | Disabled upstream (`--enablePolicyException=false`) | Enabled, accepted from the `kyverno` namespace only; JSON patch guarded by `test` ops |
| `cosign verify`: no signatures found | cosign v3 stores signatures as OCI referrers; the v2 CLI does not look there | Use cosign v3; identity = the *reusable* workflow (`build-image.yml@refs/heads/main`), not the caller |
| Signature check bypassable | Policy matched `sample-app:*` only; a digest reference skipped it | Also match `sample-app@*` |
| CLI check found nothing | `kyverno apply` does not know namespace labels | `--values-file` with the namespace labels; policy tests with good/bad fixtures make a silent policy fail |

## Method

- Every safety net gets a run where it must fail: fault injection for the canary, a wrong-identity policy for the
  signature check, mutated fixtures for the policy tests, a disabled lock for the contention test.
- Measure under realistic conditions: short-lived probes hid the 197s failover; low traffic hid the contention.
- Roll out enforcement in audit mode first; the findings were real (database Pods, drills).
