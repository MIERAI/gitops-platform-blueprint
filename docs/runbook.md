# Runbook

What to do when an alert fires or a delivery step fails. Every alert's `runbook` annotation links to a section here.

- **page**: users are affected now → act immediately.
- **ticket**: something is degrading or a safety net is broken → fix within the working day.

Scripts referenced below live in [infrastructure-live](https://github.com/MIERAI/infrastructure-live) `scripts/`
unless noted.

## First five minutes (any alert)

1. `scripts/status.sh`: sync / health of every Application and the version each environment serves.
2. `scripts/ui.sh`: Argo CD (8443), Grafana (3000), Prometheus (9090), Argo Rollouts (3100); passwords in `.secrets/`.
3. What changed? `git log -5 --oneline` in [gitops-manifests](https://github.com/MIERAI/gitops-manifests) (every
   deployment, promotion and rollback is a commit there) and in the application repository.
4. If the alert started right after a deployment, **roll back first, investigate second** ([Rollback](#rollback)).

## error-budget-burn

Alerts: `SampleAppErrorBudgetFastBurn` (page), `ApiFactoryServerErrors` (page).

Server-side errors are consuming the error budget (sample-app: 14.4× burn = 2% of the 30-day budget per hour;
api-factory: more than 1% of RPCs fail with internal / unavailable / unknown / deadline_exceeded / data_loss).
Client errors (invalid_argument, not_found, unauthenticated, 4xx) do not count: they are the API working as specified.

1. Grafana dashboard of the app: is it one route / RPC or all of them? One environment or both?
2. Logs: `kubectl -n <ns> logs deploy/api-factory --since=15m | grep ERROR` (api-factory logs the RPC and the error).
3. Typical causes and actions:
   - recent deployment → [Rollback](#rollback);
   - database unreachable (`failed to connect … postgres-rw`) → `kubectl -n <ns> get cluster postgres`; a failover
     takes 25–49s ([database-replication](#database-replication)); longer → CloudNativePG operator logs
     (`kubectl -n cnpg-system logs deploy/cnpg-controller-manager`);
   - `relation … does not exist` → the migrate init container failed: `kubectl -n <ns> logs deploy/api-factory -c migrate`; after the
     fix `kubectl -n <ns> rollout restart deploy/api-factory`.

## latency

Alerts: `SampleAppHighLatency` (ticket, p95 /hello > 300ms), `ApiFactoryHighLatency` (ticket, p95 RPC > 500ms).

1. Grafana: did latency rise with traffic (capacity) or at a deployment (regression)?
2. Regression → [Rollback](#rollback). The canary load test exists to stop exactly this (a lock-contention
   regression served p95 661ms at 100 rps while looking fine at 2 rps).
3. Capacity: CPU throttling / memory (`kubectl top pods -n <ns>`), database (`kubectl -n <ns> get cluster postgres`,
   slow queries in the Postgres logs). Scale through Git (overlay `replicas`), never with `kubectl scale`: Argo CD
   would revert it.

## database-backups

Alerts: `PostgresWalArchivingFailing` (page), `PostgresWalArchivingStale` (page).

WAL is not reaching the object store, so the point-in-time recovery window is not advancing: a loss now would
lose everything since the last archived segment.

1. `kubectl -n <ns> get cluster postgres -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'`
2. Sidecar logs: `kubectl -n <ns> logs postgres-1 -c plugin-barman-cloud | grep -i error`
   - `Expected empty archive`: another cluster already archived under the same `destinationPath` / server name
     (e.g. a re-created cluster). Use a new prefix in the overlay's ObjectStore patch, or clear the old one if it is
     really obsolete. When re-creating a cluster under a new prefix, delete the old cluster **before** the new
     prefix syncs (or clear the new prefix afterwards): the old cluster keeps archiving and would fill the new
     prefix first (happened on kind, 2026-11-18). A re-created cluster has no tables until an api-factory Pod starts
     (its migrate init container creates them): `kubectl -n <ns> rollout restart deploy/api-factory`.
   - connection / credential errors: object store down (`kubectl -n object-storage get pods`) or Secret `backup-s3`
     differs from the object store's identity (both come from infrastructure-live `secrets/<cluster>.sops.yaml`:
     `tofu apply` for the Secret, `ansible-playbook site.yml --tags seaweedfs` for the laptop's host).
3. After the fix, take a base backup right away so PITR does not depend on the gap:
   `kubectl -n <ns> create -f -` with a `Backup` (method `plugin`, pluginConfiguration
   `barman-cloud.cloudnative-pg.io`), or wait for the daily ScheduledBackup.
4. Prove it: `scripts/restore-drill.sh <ns>` (≈1 min).

## daily-restore-check

Alert: `DailyRestoreCheckFailed` (ticket). The nightly CronJob `restore-check` (prod, 04:30 JST) restores the
latest backups into a throwaway cluster, compares it with live and rehearses the next release's migrations on it; it has not succeeded for 26 hours. The live
database is fine; what is in doubt is whether it could be restored.

1. `kubectl -n api-factory-prod get jobs -l batch.kubernetes.io/cronjob-name=restore-check` and the last Job's log:
   it names the failing step (heartbeat missing = WAL chain broken → see database-backups; a table or row count
   differs = the base backup or WAL replay is incomplete; not healthy after 90 min = the restore itself).
   `✗ migration rehearsal failed`: the migrations of the version dev runs (the next release) failed on a copy of
   prod's data (the log shows which one and how long each took). Do not promote it; fix forward with a new migration
   (migrations are append-only) and let the next night's check (or a manual run) prove it.
2. A leftover `restore-target` cluster is deleted by the next run; delete it by hand if disk is short.
3. Run once now: `kubectl -n api-factory-prod create job --from=cronjob/restore-check manual-$(date +%s)`.
4. Restore time trend: `restore_check:duration_seconds` (Prometheus).

## off-site-backup

Alert: `OffsiteBackupStale` (ticket, laptop only). The hourly CronJob `backup-offsite/offsite-backup` copies the
object store (all database backups + WAL) to the phone, encrypted by rclone crypt; it has not succeeded for 3 hours.
The local backups are unaffected: this is the "laptop lost / house on fire" copy.

1. `kubectl -n backup-offsite get jobs` and `kubectl -n backup-offsite logs job/<last>`
2. Phone reachable? `tailscale status | grep <phone>`; Termux sshd running (Termux killed by battery optimisation →
   open Termux, `sshd`). A host-key error means the phone's sshd key changed: update `known_hosts` in
   gitops-manifests `platform/offsite-backup` only after confirming it on the phone itself.
3. Run once now: `kubectl -n backup-offsite create job --from=cronjob/offsite-backup manual-$(date +%s)`

Restore from the phone (the laptop is gone): on any machine with the age key, `sops decrypt
infrastructure-live/secrets/laptop.sops.yaml` gives `offsite.crypt_password` / `crypt_salt`; configure an rclone
`crypt` remote over `sftp` to the phone's `backups/gitops` (or copy that directory off the phone first) and
`rclone copy <crypt>:cnpg <local object store>`; then restore with CloudNativePG `bootstrap.recovery` as in
"Restore a database". Trash: files deleted at the source stay in `trash/<day>` for 14 days.

## database-replication

Alert: `PostgresReplicationLag` (ticket, replica > 30s behind).

A lagging replica means a failover would lose recent writes or take longer.
`kubectl -n <ns> get cluster postgres` (instances, current primary), replica logs, node pressure.
If a replica is broken beyond repair: delete its Pod **and** PVC; the operator re-clones it from the primary.

Failover behaviour (measured with `scripts/failover-drill.sh`): the cluster is healthy again 25–49s after the
primary Pod is deleted, with a short burst of API errors. `smartShutdownTimeout: 10` is what makes it fast: with the
default (180s) the API's connection pool held the old primary and failover took 197s.

## load-test-failed

Alert: `ApiFactoryLoadTestFailed` (ticket). The PostSync k6 Job in api-factory dev breached a threshold
(per-RPC p95 < 300ms, errors < 1%, 30 rps sustained).

1. `kubectl -n api-factory-dev logs job/load-test`: the k6 summary shows which threshold and which RPC.
2. **Do not promote this version to prod.** (The promote PR is not blocked automatically: GitHub cannot see the
   cluster. The reviewer of the promote PR checks this alert / the Argo CD sync result.)
3. Fix forward in the app repository, or revert the dev image tag in gitops-manifests.

## Canary aborted

Not an alert: `kubectl argo rollouts get rollout sample-app -n <ns>` shows `Degraded` / `RolloutAborted` with the
failing metric (`error-ratio`, `p95-latency`, or the `k6` load-test Job). Traffic is already back on the stable
version. Fix in the app repository, or revert the commit in gitops-manifests that introduced the change; the
Rollout returns to Healthy as soon as its spec matches the stable version again.

## Admission denied

Argo CD shows `admission webhook "vpol.validate.kyverno.svc-…" denied the request: Policy <name> failed: <message>`.
The message names the container and the missing setting (pinned image, resources, readiness probe, non-root,
signature). The same check runs on every pull request (`gitops-manifests/scripts/validate.sh`), so this normally
only happens for resources created at runtime (operators, hooks, drills).

Fix the manifest. If an exception is really justified, add a `PolicyException` to
`gitops-manifests/platform/policies/exceptions.yaml` (namespace `kyverno` only) naming the policy, the exact
workload and the reason; it goes through review like any change.

## Rollback

Everything is a commit in gitops-manifests:

```sh
git revert <commit>      # the image-tag bump or the config change
ship.sh "Revert …"       # gitops-platform-blueprint/scripts/ship.sh: PR + auto-merge
```

Argo CD syncs within ~30s (measured: revert → old version serving in ~20s). Never `kubectl edit/scale/rollout undo`:
self-heal reverts manual changes.

## Restore a database (point in time)

`scripts/restore-drill.sh <ns>` restores into a separate cluster `restore-drill` and checks a marker row; use it to
rehearse and to estimate the time (≈1 min for the demo data). For a real recovery:

1. Pick the target time (before the bad write / deletion).
2. Create a new cluster from the backups with `bootstrap.recovery` and `recoveryTarget.targetTime` (the drill's
   manifest is the template), check the data.
3. Point the application at it through Git (change the Cluster in the overlay, or the connection secret), sync.
   Keep the damaged cluster until the restored one is verified.

## Rebuild the platform

`scripts/rebuild-drill.sh --yes` deletes the kind cluster and `.secrets/`, rebuilds everything from Git and runs
smoke checks, printing the time of each phase. **Data is not covered**: the object store with the backups runs in
the same cluster and is deleted with it (on GKE the backups go to a GCS bucket outside the cluster); databases come
back empty and dev is re-seeded.
