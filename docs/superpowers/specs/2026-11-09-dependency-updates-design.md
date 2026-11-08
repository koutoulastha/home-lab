# Dependency updates: catch-up and Renovate — design

Date: 2026-11-09
Status: draft, awaiting owner approval (review questions resolved)

## Intent

Every chart and image version in this repo has been bumped by hand, and many
have drifted behind upstream while the media and music stacks were built out.
The owner wants two things:

1. **Catch up now**: bring everything this repo deploys to its latest
   *stable* upstream release.
2. **Stay current automatically from then on**, with every update arriving as
   a pull request the owner reviews and merges. Auto-merge of small patch
   updates may be switched on later, not now.

Because every ArgoCD Application here auto-syncs, **merging to `main` is
deploying**. The design treats a merged PR as a production rollout.

## Goals

- All Helm charts and container images deployed from this repo are on their
  latest stable release after the catch-up.
- No floating tags (`latest`) remain in anything this repo deploys.
- Renovate is set up so that every pinned chart and image in the repo is detected
  and gets update PRs. A dependency Renovate cannot see counts as a bug.
- The owner reviews and merges every update. Nothing merges on its own.
- The Renovate config is structured so that patch auto-merge can be enabled
  later with a small change, with storage/database excluded.

## Non-goals

- **Talos, Kubernetes, Gateway API CRDs**: out of scope.
- **Cilium and ArgoCD itself**: deliberately left out for now (see
  "Deferred: Cilium and ArgoCD" below). Do not adopt, upgrade or change them.
- **TrueNAS**: stays on 25.x (democratic-csi has no WebSocket API yet). Out of scope.
- Auto-merge of any kind in this phase.

## Anti-goals (would make this a failure even if versions end up current)

- Moving anything onto a **pre-release** channel. The `home-operations` *arr
  images publish pre-release builds under plain numeric tags (e.g. Sonarr
  5.0.0.x, Radarr 7.0.x, Prowlarr 3.0.x are all GitHub pre-releases as of
  2026-11-08). "Latest" means latest stable.
- A Renovate config that *looks* valid but silently misses dependencies.
  `renovate-config-validator` passing proves only syntax, not coverage
  (consistent with the repo's existing rule: verify against the consumer).
- Day-one PR flood: Renovate enabled before the catch-up lands, opening ~30
  PRs at once.
- Losing data: Immich DB migrations or storage-driver changes without a
  backup and a way back.
- Claude running cluster-mutating commands. The owner runs cluster commands
  themselves. The builder provides copy-pasteable commands.

## Constraints and context

- Repo: `github.com/koutoulastha/home-lab`, default branch `main`. Work on
  branches, merge via PR.
- No app-of-apps: each `application.yaml` is applied manually once. Renovate
  only changes versions inside existing Applications, so this doesn't block
  anything, but any *new* Application file would need a manual apply.
- Tooling runs inside devbox (`devbox run -- …`). `helm` and `yq` are available
  there.
- `apps/media/tests/render-test.sh` renders every media app through the exact
  `app-template` version its Application pins and asserts properties. It must
  pass after the `app-template` bump.
- Version locations Renovate must understand:
  - ArgoCD `Application` sources: `chart:` + `targetRevision:` with an HTTP
    Helm `repoURL`, and one OCI repo (`ghcr.io/bjw-s-labs/helm`,
    `app-template`, used by 8 media apps). Renovate's `argocd` manager needs
    `fileMatch`/`managerFilePatterns` configured, since it matches nothing by default.
  - `values.yaml` images as `repository:` + `tag: <ver>@sha256:<digest>`
    (app-template style). Digests should be kept and updated.
  - Plain manifests with `image: repo:tag` (pve-exporter, truenas-exporter,
    the kubectl CronJob in `apps/immich/db/`, busybox test pods).
  - **Immich**: `apps/immich/values.yaml` sets only `tag: v3.1.0` with no
    `repository` (the chart supplies it). This needs a custom regex manager or
    an annotation comment so Renovate knows it is `ghcr.io/immich-app/immich-server`.
    The values comment says server and machine-learning must always carry the
    same tag. The builder must check in the immich chart 0.12.0 render whether
    one `tag` drives both, and make sure Renovate can never update one without the other.
  - `cert-manager` and `traefik` pin `targetRevision` as quoted strings (`"v1.21.1"`,
    `"41.4.0"`); keep the existing quoting/`v` style.

## Inventory at time of writing (2026-11-08)

| Dependency | Where | Now | Latest stable | Notes |
|---|---|---|---|---|
| kube-prometheus-stack | infrastructure/monitoring | 88.6.1 | 93.1.0 | 5 majors; CRD upgrades; uses ServerSideApply |
| traefik chart | infrastructure/networking | 41.4.0 | 42.3.1 | major |
| immich (image) | apps/immich | v3.1.0 | v3.3.6 | DB migrations; chart 0.12.0 already latest |
| jellyfin | apps/media | 12.1 | 12.4 | |
| alloy chart ×4 | infrastructure/monitoring | 1.12.1 | 1.15.0 | |
| loki chart | infrastructure/monitoring | 7.3.0 | 7.5.0 | |
| sealed-secrets chart | infrastructure | 2.19.1 | 2.22.0 | |
| snapshot-controller chart | infrastructure/storage | 5.2.0 | 5.4.0 | storage-adjacent |
| prometheus-blackbox-exporter | infrastructure/monitoring | 11.17.2 | 11.21.1 | |
| newt chart | apps/pangolin-newt | 1.4.0 | 1.5.0 | chart's appVersion (1.12.5) lags upstream Newt (1.20.0) |
| app-template ×8 | apps/media | 5.2.1 | 5.3.0 | run render-test.sh |
| cert-manager | infrastructure | v1.21.1 | v1.21.3 | |
| cloudnative-pg chart | infrastructure/database | 0.29.0 | 0.29.1 | database operator |
| radarr | apps/media | 6.4.4.10685 | 6.4.4.10685 | current. 7.x is pre-release |
| prowlarr | apps/media | 2.6.5.5623 | 2.7.0.5723 | 3.x is pre-release |
| lidarr | apps/media | 3.1.6.5078 (**pre-release**) | 3.1.6.5079 | move back onto stable |
| sonarr | apps/media | 4.0.20.3012 | 4.0.20.3012 (verify) | 5.x is pre-release |
| qbittorrent | apps/media | 5.2.4 | 5.3.0 | |
| prometheus-pve-exporter | infrastructure/monitoring | 3.10.0 | 3.11.0 | |
| alpine/kubectl | apps/immich/db | 1.36.4 | 1.37.2 | probably track cluster k8s minor, builder to check |
| busybox (test pods) | democratic-csi/tests | 1.36 | 1.38.0 | test-only |
| cloudnative-vectorchord (Immich PG) | apps/immich/db/cluster.yaml | 17.9-1.1.0 | builder to check | `imageName:`, see the calls made during review |
| democratic-csi, navidrome, gluetun, flaresolverr, truenas-exporter, immich chart | — | — | current | |
| openspeedtest | apps/openspeedtest | `latest` | — | pin to a real tag + digest |
| helm-webapp | apps/helm-webapp | `latest` (devopsjourney1/mywebapp) | — | **delete** (owner decision) |

The builder should re-check the "latest stable" column when starting, since it will
have moved.

## Approach (decided)

### Phase 1: catch-up, in risk-sized batches

One branch and one PR per batch. The owner merges each PR, watches ArgoCD
sync, and runs the verification commands the builder supplies before the next
batch. Batch order goes from lowest blast radius to highest:

1. **Low-risk batch**: patch/minor bumps of non-critical things: blackbox-exporter,
   alloy ×4, loki, pve-exporter, busybox, kubectl, newt, cert-manager,
   sealed-secrets, the *arr stable bumps (prowlarr, lidarr back to stable),
   qbittorrent, jellyfin, app-template (with render-test.sh passing), and
   pinning openspeedtest. The builder may split this further if a release note
   shows breaking changes.
2. **Storage/database batch**: snapshot-controller, cloudnative-pg. Each one
   needs a check that PVCs/snapshots/CNPG clusters are healthy afterwards.
3. **Immich**: on its own. Backup first, both of these (owner's decision):
   - an on-demand CNPG `Backup` (volumeSnapshot) taken right before the update,
     with written steps to bootstrap a cluster from it, **and**
   - an **off-array `pg_dump`** copied to a location that is not TrueNAS (e.g. the
     owner's PC), with a check that it is complete and non-empty and the restore
     command written down.
   The builder writes the commands for both and how to confirm each one completed.
   Then the bump, then check that it migrated cleanly. A rehearsed restore is
   not required.
4. **Traefik 41 → 42**: on its own. Read the upgrade notes. Check all
   HTTPRoutes, the gateway and the Pangolin-exposed services afterwards.
5. **kube-prometheus-stack 88 → 93**: on its own. Read each major's upgrade
   notes. CRDs may need updating before or with the chart (ServerSideApply is
   already set). Check alerts, Grafana and probes afterwards.

Every PR description lists, for each bump: old → new, a link to the release notes,
any breaking change found and what was done about it, and the verification
commands. Each risky batch also states how to roll back (revert the PR and let
ArgoCD sync back, plus anything a revert does *not* undo, such as DB migrations or CRDs).

### Phase 2: Renovate

- **Hosted Mend Renovate GitHub app** on `koutoulastha/home-lab` (Claude's call,
  owner did not object). The owner installs the app. Nothing runs in-cluster.
- Enabled **after** Phase 1 is merged.
- `renovate.json` (or `.github/renovate.json5`) in the repo:
  - Managers: `argocd` (with file patterns covering `apps/**` and
    `infrastructure/**` Application files), `helm-values`, `kubernetes`, plus
    regex/custom managers wherever those miss something (Immich tag at minimum).
  - Exclude `old/**`.
  - Pin digests where the repo already uses them, and keep them updated.
  - **Stable only**: block pre-releases. For the `home-operations` *arr images,
    whose tags don't mark pre-releases, the builder must find a reliable way to
    hold to stable (e.g. version constraints per major, or rules informed by the
    upstream release channel), and document what it relies on.
  - **Grouping**: one PR per dependency for all its uses (app-template ×8,
    alloy ×4). Immich server and ML are always together.
  - **Schedule**: weekends only (Claude's call, owner did not object). Exact
    window and timezone (Europe/Athens) up to the builder.
  - **Dependency Dashboard** issue enabled.
  - **No auto-merge.** Leave a commented or clearly marked spot (packageRule) for
    future patch auto-merge, explicitly excluding democratic-csi,
    snapshot-controller, cloudnative-pg and Immich.
  - Major updates get a label so they stand out.
- **Coverage verification** (required, see anti-goals): after the app is
  installed, compare the Dependency Dashboard's detected dependencies (or a
  local `renovate --platform=local` dry run in devbox) against the inventory
  table above. Every row must appear. List any gaps and fix them before
  calling Phase 2 done.

### Housekeeping in the same work

- Fix the wrong comment in `infrastructure/networking/cilium/application.yaml`:
  Cilium was installed manually with Helm (release `cilium` in `kube-system`), not
  by Talos/Omni.
- Add a short runbook doc (the repo has them for other stacks) covering how
  Renovate PRs flow, what to check before merging each risk class, and how to
  turn on patch auto-merge later.

## Deferred: Cilium and ArgoCD (record, don't act)

Facts found on 2026-11-08, kept for a later project:

- **Cilium**: Helm release `cilium` in `kube-system`, chart 1.19.4, but the
  agent DaemonSet runs image `quay.io/cilium/cilium:v1.19.1`. The DaemonSet is at
  generation 7 while Helm is at revision 4, which suggests a hand edit or a values pin.
  The owner doesn't remember how it was installed. Latest stable: 1.19.10 / 1.20.4.
  Before any adoption: `helm -n kube-system get values cilium` and compare
  the live operator/agent images.
- **ArgoCD**: v3.3.3, installed from plain manifests (no Helm/Kustomize
  labels), probably `kubectl apply` of `install.yaml`. Latest stable: 3.6.1.
- Record these in the runbook (or a short note) so the next project starts from them.

## Calls made during review (Claude's, owner to check)

- **Immich Postgres image** (`apps/immich/db/cluster.yaml`,
  `imageName: ghcr.io/tensorchord/cloudnative-vectorchord:17.9-1.1.0`): Renovate
  tracks it with a custom manager, because a dependency it can't see is a bug. **Postgres
  major updates are disabled**, and it is permanently excluded from any future
  auto-merge. In the catch-up it is bumped only if the target Immich release
  requires a newer vectorchord, and then inside batch 3 alongside Immich.
- **Chart-default images are not separate targets.** "What this repo deploys"
  means the versions pinned in this repo. Images a chart supplies itself move
  when the chart is bumped. No new image overrides get added. Newt follows its
  chart's image (the tunnel is critical, so don't run an image newer than the
  chart templates expect).
- **Out-of-scope prerequisites:** if a target version (e.g. Traefik 42,
  kube-prometheus-stack 93) needs newer Gateway API CRDs or a newer
  Kubernetes version, stop at the highest version that works without them, record
  why in the PR, and add a Renovate constraint so it doesn't keep proposing
  the blocked upgrade. Widening the scope is a decision for the owner.
- **helm-webapp:** deleted (see below), so no Renovate handling.

## Left to the builder

- Exact Renovate config syntax, manager file patterns, regex managers.
- How to enforce stable-only for the *arr images, as long as it is documented and verified.
- Further splitting of batch 1 if release notes warrant it.
- Verification commands for each batch (copy-pasteable, for the owner to run).
- Whether `alpine/kubectl` tracks the cluster's Kubernetes minor version (check `kubectl version`
  via the owner) instead of the latest.
- Renovate schedule window details.

## Decided after review (owner's)

- **helm-webapp is deleted** (owner's decision). Remove `apps/helm-webapp/`
  in batch 1. Since there's no app-of-apps, give the owner the `kubectl delete`
  command for its Application(s), after checking the Application name(s) and
  the namespace/resources it owns, so pruning removes the workload too.
  Renovate doesn't need to handle it.
