# Immich — self-hosted photo & video backup

**Date:** 2026-08-29
**Status:** Approved design, ready for implementation planning
**Repo:** `github.com/koutoulastha/home-lab.git` (branch `main`)

## Problem

Phone photos and videos have no self-hosted backup target. The cluster now has
working persistent storage (democratic-csi + TrueNAS), a Gateway API ingress
path with a wildcard certificate, and a Pangolin/Newt tunnel for public
exposure — everything Immich needs — but Immich itself is not deployed.

Immich is not a single-container app. It needs a Postgres with the
**VectorChord** extension (a stock `postgres:17` image will not start it), a
Redis-compatible queue, a machine-learning service, and a large single-writer
media volume. The official Helm chart deliberately ships **none** of the
stateful pieces: no Postgres, no library PVC. Both must come from this repo.

## Goals

- Immich deployed via ArgoCD, matching the repo's existing multi-source
  `Application` pattern.
- Postgres with VectorChord, managed by an operator, with automated backups.
- Reachable on the LAN at `photos.koutoulastha.dev` **and** publicly through the
  existing Pangolin tunnel, so phone backup works away from home.
- Machine learning (face recognition, CLIP search, smart tagging) enabled,
  CPU-only.
- No plaintext credentials committed to git.
- The database's lifecycle decoupled from the app's, so an app-level mistake
  cannot prune the database.

## Non-Goals

- **Migrating an existing library.** Starting fresh, phones only.
- **Hardware acceleration** for ML or transcoding. CPU only. Revisit if the
  initial library scan proves intolerable.
- **Point-in-time recovery** for Postgres. Nightly snapshots only — see
  *Accepted Risks*.
- **High availability.** Single Postgres instance; single Immich server. The
  library volume is RWO, which makes a second writer impossible anyway.
- **Managing Immich admin settings in git.** See *Application* below.
- **Automating the Pangolin resource.** Pangolin resources are created in the
  Pangolin UI on the VPS; they are not Kubernetes objects.

## Context / Current State

- **Cluster:** Talos Linux on Proxmox, Cilium CNI, Traefik + Gateway API.
- **GitOps:** ArgoCD. **There is no app-of-apps and no ApplicationSet** — every
  `application.yaml` must be `kubectl apply`'d once by hand or it deploys
  nothing. This design adds three such registrations.
- **Storage:** democratic-csi against TrueNAS SCALE.
  - `truenas-iscsi` — default class, RWO, ext4, `allowVolumeExpansion: true`
  - `truenas-nfs` — RWX
  - A `VolumeSnapshotClass` also named `truenas-iscsi`, with the
    snapshot-controller already deployed.
- **Ingress:** Gateway `traefik-gateway` in namespace `default`, wildcard
  `*.koutoulastha.dev` HTTPS listener on 8443, `allowedRoutes.namespaces.from:
  All`. The wildcard certificate already covers any new subdomain, so **this
  design creates no Certificate and triggers no ACME challenge.**
- **Public exposure:** Pangolin on a VPS with a Newt tunnel terminating
  in-cluster. Requires UDP 51820 open; a 502 is the signature of a dead tunnel.
- **Secrets:** sealed-secrets / `kubeseal`. This design needs **no new secret**
  — the database credential is generated in-cluster by the operator.
- **DNS history:** this cluster has lost significant time to DNS issues
  (search-domain expansion in the argocd namespace; stale Cilium kube-dns
  backends). Immich's Alpine images have a known musl resolver bug when nodes
  set a search domain. Mitigated pre-emptively rather than diagnosed later.

## Chosen Approach

**Three ArgoCD Applications, split by lifecycle:**

1. `infrastructure/database/cloudnative-pg` — the CNPG operator, cluster-scoped
   infrastructure that will outlive Immich.
2. `apps/immich/db` — the Postgres `Cluster` and its backup schedule. **Not
   pruned** by ArgoCD.
3. `apps/immich` — the Immich Helm release plus our PVC and HTTPRoute.

### Alternatives considered

- **One Application for everything.** Fewer registrations, but the database and
  the app then share a pruning blast radius: an app-level mistake could delete
  the `Cluster`. Rejected.
- **Plain Postgres StatefulSet** instead of CNPG. Simpler, no operator, but we
  would hand-roll backups, failover and the VectorChord image. Rejected in
  favour of CNPG (user's decision, and it holds up: tensorchord publishes
  CNPG-flavoured VectorChord images, so there is no custom Dockerfile to
  maintain).
- **Chart-bundled Postgres/Redis subcharts.** Not available — removed from the
  Immich chart in 0.10.0.

## Layout

```
infrastructure/database/cloudnative-pg/
  application.yaml          # chart 0.29.0 (operator v1.30.0), ns cnpg-system
  values.yaml
apps/immich/
  application.yaml          # multi-source: chart + $values + our manifests
  values.yaml
  pvc.yaml                  # immich-library, 500Gi, truenas-iscsi
  httproute.yaml
apps/immich/db/
  application.yaml          # syncPolicy: automated { prune: false, selfHeal: true }
  cluster.yaml
  scheduled-backup.yaml
  backup-prune-cronjob.yaml
  README.md                 # restore procedure + library backup note
```

`README.md` at the repo root gains `infrastructure/database/` in its layout
tree.

### The app Application

```yaml
sources:
  - repoURL: https://immich-app.github.io/immich-charts
    chart: immich
    targetRevision: 0.12.0
    helm:
      valueFiles:
        - $values/apps/immich/values.yaml
  - repoURL: https://github.com/koutoulastha/home-lab.git
    targetRevision: main
    ref: values
    path: apps/immich
    directory:
      exclude: '{application.yaml,values.yaml,db}'
```

A single git source carries both `ref: values` and `path`, so it supplies the
values file *and* renders `pvc.yaml` + `httproute.yaml`. This was verified
against the ArgoCD docs rather than assumed. Two constraints that bit during
design and are easy to re-trip:

- `$values` paths are **always relative to the repo root**, never to `path`.
- A source with `ref` may not also set `chart` — hence chart and git are
  separate sources.

The `directory.exclude` glob keeps ArgoCD from trying to apply the Application
manifest and the Helm values file as cluster resources, and keeps the `db/`
subdirectory out of this Application entirely.

### Registration (one-time, in order)

```bash
kubectl apply -f infrastructure/database/cloudnative-pg/application.yaml
kubectl apply -f apps/immich/db/application.yaml
kubectl apply -f apps/immich/application.yaml
```

## Database

**Cluster `immich-db`, namespace `immich`.**

- Image `ghcr.io/tensorchord/cloudnative-vectorchord:17-0.4.3` — a
  CNPG-compatible Postgres 17 with VectorChord baked in.
- `instances: 1`.
- `shared_preload_libraries: ["vchord.so"]` — required; the extension will not
  load otherwise.
- Parameters: `shared_buffers=512MB`, `max_wal_size=2GB`,
  `wal_compression=on`.
- Bootstrap: database `immich`, owner `immich`, with `postInitApplicationSQL`:
  ```sql
  CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
  CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
  ```
- The `immich` role is granted **superuser**. Immich's migrations require it.
  This is a documented Immich requirement, not a shortcut.
- Storage: 20Gi on `truenas-iscsi`, plus a **separate 8Gi `walStorage`** so WAL
  churn during the initial library scan cannot fill the data volume.

**Credentials — nothing in git.** CNPG generates a Secret `immich-db-app`
containing a ready-formed `uri`. Immich consumes it directly:

```yaml
DB_URL:
  valueFrom:
    secretKeyRef: { name: immich-db-app, key: uri }
```

**Backups.** A `ScheduledBackup` with `method: volumeSnapshot`, class
`truenas-iscsi`, `online: true`, schedule `"0 30 2 * * *"` — note CNPG cron is
**six fields, seconds first**; a five-field expression is a silent misfire.

CNPG volume snapshots **have no retention policy** (retention applies only to
object-store backups). Without intervention TrueNAS accumulates snapshots
forever. A small CronJob — with its own ServiceAccount and a Role over
`backups.postgresql.cnpg.io` — deletes all but the newest 7 `Backup` objects,
which cascades to the VolumeSnapshots.

## Application

- **Chart 0.12.0**, image tag pinned to **v3.1.0** on both the server and the
  machine-learning container. The chart's appVersion is v2.6.3, a full major
  behind. Immich v3's breaking changes are API-surface changes affecting
  third-party integrations; they do not change the container/env/volume shape
  the chart builds. **Server and ML tags must always match.**

- **`server.controllers.main.strategy: Recreate`** — not optional. The chart
  hardcodes `RollingUpdate`, which deadlocks against an RWO iSCSI volume: the
  new pod cannot attach a volume the old pod still holds, and the old pod will
  not terminate until the new one is ready. The chart applies its hardcoded
  values with Helm's `merge` (gap-filling only), so our value wins. Cost: brief
  downtime on each upgrade, which is correct for a single-writer volume.

- **Storage:**

  | Volume | Class | Size | Notes |
  |---|---|---|---|
  | `immich-library` (ours, `pvc.yaml`) | `truenas-iscsi` RWO | 500Gi | chart never creates this; wired via `immich.persistence.library.existingClaim` |
  | ML model cache | `truenas-iscsi` RWO | 10Gi | chart default is `emptyDir`, which re-downloads ~1–2GB of models on every restart |
  | Valkey data | `emptyDir` | 1Gi | chart default, kept — a job queue; a restart re-queues work rather than losing photos |

  500Gi is a starting point, not a ceiling: `truenas-iscsi` has
  `allowVolumeExpansion: true`, so growing it later is an edit, not a migration.

- **`valkey.enabled: true`** — the chart defaults this to `false` while its
  default `REDIS_HOSTNAME` already points at `<release>-valkey`. The one place
  where the chart's default value and default wiring disagree.

- **DNS:** both pods get `dnsConfig.options: ndots=1`. Immich's Kubernetes docs
  warn that its Alpine images hit a musl resolver bug when nodes set a search
  domain, and this cluster has already lost time to search-domain behaviour.

- **Configuration stays in the database.** `immich.configuration` is left empty.
  Setting it makes the chart render an `immich-config.yaml` and mount it via
  `IMMICH_CONFIG_FILE`, which turns **every** admin setting in the web UI
  read-only. For a homelab where storage templates and job concurrency get tuned
  by feel, that trade is wrong. Cost: those settings live only in Postgres —
  covered by the nightly snapshots.

- **Resources:** server `500m`/`2Gi` request, `2Gi` limit. ML `500m` request,
  `4` CPU / `3Gi` limit — CPU-only CLIP inference is bursty and the initial
  library scan will use whatever it is given.

- Namespace `immich`, `CreateNamespace=true`. Nothing here needs privileged or
  hostPath, so the cluster's default `baseline` PodSecurity applies unchanged —
  no namespace labelling of the kind democratic-csi needed.

- The chart's own ingress is left disabled; ingress is our HTTPRoute.

## Exposure

**LAN** — `apps/immich/httproute.yaml`:

```yaml
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: default
  hostnames: ["photos.koutoulastha.dev"]
  rules:
    - backendRefs: [{name: immich-server, port: 2283}]
```

Port 2283 is fixed by the chart (container, service, and the
`/api/server/ping` probes).

**Upload sizes.** Traefik imposes no request-body limit by default, so unlike an
nginx ingress there is no 1MB cliff to raise — a multi-GB video POST just works.
Immich's mobile app also chunks uploads. **No middleware is needed; do not add
one speculatively.**

**Public** — created in the Pangolin UI on the VPS, *not* in this repo:

- Resource → `photos.koutoulastha.dev`, target
  `immich-server.immich.svc.cluster.local:2283`
- **SSO/auth off** on this resource. The Immich mobile app cannot traverse an
  auth portal; gating it there breaks phone backup entirely. Immich's own login
  is the auth boundary.

This is the security decision in this design: Immich's login page is exposed to
the internet. Mitigations are day-one admin steps, listed below.

## Post-install checklist

1. Create the admin account immediately (first visitor to the URL becomes
   admin).
2. Set a strong admin password.
3. Disable public registration once all accounts exist.
4. Create the TrueNAS ZFS snapshot task for the library (see *Accepted Risks*).
5. Install the mobile app, point it at `https://photos.koutoulastha.dev`, enable
   background backup.

## Rollout & verification

```bash
# 1. operator
kubectl apply -f infrastructure/database/cloudnative-pg/application.yaml
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg

# 2. database (creates ns immich)
kubectl apply -f apps/immich/db/application.yaml
kubectl -n immich get cluster immich-db -w      # wait for "Cluster in healthy state"
kubectl -n immich get secret immich-db-app      # the uri key the app consumes

# 3. app
kubectl apply -f apps/immich/application.yaml
kubectl -n immich get pvc immich-library        # must reach Bound before pods schedule
kubectl -n immich rollout status deploy/immich-server
```

### Failure modes

| Symptom | Likely cause |
|---|---|
| `immich-db` stuck in `Setting up primary` | wrong VectorChord image tag, or `vchord.so` missing from `shared_preload_libraries` — `kubectl -n immich logs immich-db-1` |
| Server crashloops on `extension "vchord" is not available` | `postInitApplicationSQL` did not run; the database was already bootstrapped by a prior attempt |
| Server crashloops resolving `immich-db-rw` | the Alpine search-domain bug — confirm the `ndots` option actually landed on the pod |
| PVC `Pending` | 500Gi exceeds free space in the TrueNAS parent dataset; democratic-csi reports it in PVC events |
| ArgoCD Application syncs but nothing appears | the `application.yaml` was never `kubectl apply`'d — the repo's standing gotcha |
| 502 publicly, fine on LAN | dead Newt tunnel — UDP 51820, the documented signature |

## Accepted Risks

- **No PITR.** Nightly volume snapshots mean up to 24h of *metadata* loss
  (albums, faces, sharing) on a database restore. Photo files themselves are
  unaffected — they live on the library volume. Adding PITR means WAL archiving
  to an object store, which is a larger change than this warrants today.
- **CNPG does not protect the library volume.** The database backups cover
  metadata only; the irreplaceable photos are on the `immich-library` PVC and
  are outside CNPG's scope entirely. Mitigation: a **TrueNAS-side ZFS snapshot
  task on the iSCSI parent dataset**, configured in the TrueNAS UI and
  documented in `apps/immich/db/README.md`. The dataset path is not in git — the
  democratic-csi driver config lives in
  `infrastructure/storage/democratic-csi/iscsi/sealed-secret.yaml`; read
  `datasetParentName` from the decrypted Secret in-cluster, or read it off the
  TrueNAS UI. This is a manual, out-of-cluster step and the single most
  important item on the checklist.
- **Public login page exposure.** Accepted deliberately — off-LAN phone backup
  is a stated goal and the app cannot authenticate through a portal. Mitigated
  by a strong admin password and disabled registration.
- **Single instance, no HA.** A node failure means downtime until reschedule,
  and RWO attach/detach can make that slow. Acceptable for a homelab photo
  service.

## Open Item for Implementation

Confirm that `CREATE EXTENSION vchord CASCADE` resolves pgvector inside
`cloudnative-vectorchord:17-0.4.3`. If it does not, switch to the `-pgvector`
image variant. This is a one-command check once the Cluster is up and does not
change any other part of the design.
