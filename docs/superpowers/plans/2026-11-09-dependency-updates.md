# Dependency Catch-up and Renovate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring every chart and image this repo deploys to its latest stable release in five risk-sized PRs, then turn on Renovate so every future update arrives as a PR the owner reviews.

**Architecture:** First a render harness (`tests/render-app.sh`) that renders any Application's Helm source(s) exactly as ArgoCD would. Every bump PR has to pass it before the owner merges. Then five catch-up PRs, merged and verified by the owner one at a time. Last, a `renovate.json` driven by a coverage test that runs Renovate locally against the repo and checks every expected dependency is detected and no pre-release or blocked update is proposed.

**Tech Stack:** ArgoCD Applications (Helm + OCI Helm), helm, yq-go, jq, devbox, Renovate (hosted Mend GitHub app in production, `npx renovate` locally for tests), Node.js via devbox.

**Spec:** `docs/superpowers/specs/2026-11-09-dependency-updates-design.md`

## Global Constraints

- "Latest" = latest **stable**. Never move anything onto a pre-release. The `home-operations` *arr tags don't mark pre-releases, so check each candidate against the upstream GitHub release (`prerelease: false`).
- **Merging to `main` deploys** (ArgoCD auto-sync). One branch and one PR per batch, branched from up-to-date `main`. **Stop after opening each batch PR.** The owner merges it, watches the sync, and runs the verification commands. The next batch starts only after the owner confirms.
- **Claude never runs cluster-mutating commands.** Every `kubectl`/`talosctl` command goes in the PR description or a doc as copy-pasteable text for the owner. Read-only `helm template` / registry lookups run locally are fine.
- Re-check "latest stable" for each dependency at the start of its batch. The spec's table is a snapshot from 2026-11-08.
- Keep each file's existing pin style: `tag: <ver>@sha256:<digest>` stays digest-pinned (get the digest from the registry for the exact tag). Quoted `targetRevision` (`"v1.21.1"`, `"41.4.0"`) stays quoted with the same `v` style.
- Out of scope, don't touch: Talos, Kubernetes, Gateway API CRDs, Cilium (the chart/DaemonSet itself), ArgoCD itself, TrueNAS, democratic-csi version.
- Images supplied by a chart's defaults are not separate targets. Don't add new image overrides (Newt included).
- If a target needs newer Gateway API CRDs or a newer Kubernetes: stop at the highest version that works without them, say why in the PR, and add a Renovate `allowedVersions` cap for it in Task 7.
- Immich Postgres (`cloudnative-vectorchord`): never a Postgres major. Bump only if the target Immich release requires a newer VectorChord.
- No auto-merge anywhere.
- Every bump PR description has, per dependency: old → new, release-notes link, any breaking change and what was done about it, verification commands, and (for batches 2-5) rollback steps including what a revert does *not* undo.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Review Focus

1. **A pre-release *arr build looks like a normal update** (Sonarr 5.0.0.x, Radarr 7.0.x, Prowlarr 3.0.x, Lidarr 3.2.x on 2026-11-08). The owner expects Renovate never to propose one. Pinned by the lookup assertions in Task 6/7.
2. **A dependency Renovate silently can't see**: the Immich tag with no `repository`, `imageName:` in the CNPG Cluster, the OCI `app-template` source, quoted `v`-prefixed `targetRevision`. The owner expects all of them tracked. Pinned by the coverage test in Task 6.
3. **A chart bump that renders fine against the default kube version but not against this cluster's** (Gateway API capability gates, `kubeVersion` constraints). The owner expects the render check to use the cluster's real version and APIs. Pinned by `KUBE_VERSION` + `--api-versions` in Task 1.
4. **Deleting `helm-webapp` files leaves the workload running.** Its Application has no `automated` sync and no resources finalizer. The owner expects the `dev` workload gone. Pinned by the finalizer-then-delete commands and the post-check in Task 2.
5. **The Immich update starts before both backups are confirmed good**: an empty dump, or a snapshot not `readyToUse`. The owner expects the bump PR to be unmergeable until both checks pass. Pinned by the backup gate in Task 4.

---

### Task 1: Render harness for any Application

**Files:**
- Create: `tests/render-app.sh`
- Create: `tests/README.md`

**Interfaces:**
- Produces: `devbox run -- bash tests/render-app.sh <path/to/application.yaml>...`. For each Application, renders every source that has `chart:` (HTTP or OCI repo) with `--version <targetRevision>`, `--namespace <spec.destination.namespace>`, each `helm.valueFiles` entry with `$values/` resolved to the repo root, `--kube-version "$KUBE_VERSION"` (env, required), and `--api-versions gateway.networking.k8s.io/v1/HTTPRoute --api-versions gateway.networking.k8s.io/v1/Gateway --api-versions monitoring.coreos.com/v1/ServiceMonitor`. It prints `ok <app>` or `FAIL <app>` plus helm's stderr, and exits non-zero on any failure. With `--all`, it runs on every `application*.yaml` with a chart source outside `old/`. Applications with no chart source print `skip <app>`.
- OCI repos (no `https://` scheme in `repoURL`) render as `oci://<repoURL>/<chart>`.

- [ ] **Step 1: Get the cluster's Kubernetes version from the owner.** Ask them to run `kubectl version -o json | jq -r .serverVersion.gitVersion` and record the value (e.g. `v1.34.x`) in `tests/README.md` as the `KUBE_VERSION` to export. Also use it in Task 2 for `alpine/kubectl`.
- [ ] **Step 2: Write the failing check.** In `tests/README.md`, document two expected runs: (a) `KUBE_VERSION=<v> devbox run -- bash tests/render-app.sh --all` → every chart app prints `ok`, exit 0; (b) a copy of `infrastructure/monitoring/loki/application.yaml` in a temp dir with `targetRevision: 0.0.0-doesnotexist` → `FAIL`, exit 1. Run (a) before the script exists → `No such file`.
- [ ] **Step 3: Implement `tests/render-app.sh`** in the style of `apps/media/tests/render-test.sh` (`set -euo pipefail`, `git rev-parse --show-toplevel`, temp dir with trap). Read Application fields with `yq`. Fail fast with a clear message if `KUBE_VERSION` is unset.
- [ ] **Step 4: Run both checks from Step 2.** Expected: (a) all `ok`, exit 0; (b) `FAIL`, exit 1. If (a) fails on the *current* pins, stop and report it. That's pre-existing breakage, not something to fix here.
- [ ] **Step 5: Commit** on branch `chore/deps-batch-1` (Task 2 continues on it): `test: render harness for chart-backed Applications`.

### Task 2: Batch 1: low-risk bumps, helm-webapp removal, pins, comment fix

**Files:**
- Modify (`targetRevision`): the 4 alloy `application.yaml`s, `infrastructure/monitoring/loki/application.yaml`, `infrastructure/monitoring/blackbox-exporter/application.yaml`, `apps/pangolin-newt/application.yaml`, `infrastructure/cert-manager/application.yaml`, `infrastructure/sealed-secrets/application.yaml`, the 8 `apps/media/*/application.yaml` (app-template)
- Modify (image tags): `apps/media/{prowlarr,qbittorrent,jellyfin}/values.yaml`, `infrastructure/monitoring/pve-exporter/deployment.yaml`, `apps/immich/db/backup-prune-cronjob.yaml`, `infrastructure/storage/democratic-csi/tests/*.yaml` (busybox)
- Modify: `apps/openspeedtest/deployment.yaml` (pin `openspeedtest/latest:latest` to a versioned tag + digest; check Docker Hub `openspeedtest/latest` for the newest version tag, and if the repo publishes none, pin `latest@sha256:<current digest>` and say so in the PR)
- Modify: `infrastructure/networking/cilium/application.yaml` header comment: Cilium is a manually installed Helm release `cilium` in `kube-system`, not installed by Talos/Omni
- Delete: `apps/helm-webapp/` (whole directory)
- Test: `tests/render-app.sh`, `apps/media/tests/render-test.sh`

**Interfaces:**
- Consumes: `tests/render-app.sh` (Task 1), `KUBE_VERSION`.

Not in this batch: Lidarr (stays on `3.1.6.5078`, since home-operations never published stable 5079), Radarr, Sonarr, Navidrome, gluetun, FlareSolverr, truenas-exporter (all already current, but re-check). `alpine/kubectl` goes to the newest patch of the cluster's **minor** from Task 1 Step 1, not 1.37.x unless the cluster is on 1.37.

- [ ] **Step 1: Re-check latest stable for every dependency in this batch** (Helm `index.yaml`, ghcr/Docker Hub tags, upstream GitHub releases with `prerelease: false`). Write the old → new table into the PR body draft. Drop any item whose release notes show a breaking change affecting this repo's values, and list it in the PR as deferred with the reason.
- [ ] **Step 2: Apply the version edits.** For digest-pinned images, fetch the digest of the exact new tag from the registry (multi-arch index digest, the same kind the current pins use).
- [ ] **Step 3: Run `KUBE_VERSION=<v> devbox run -- bash tests/render-app.sh --all`.** Expected: all `ok`.
- [ ] **Step 4: Run `devbox run -- bash apps/media/tests/render-test.sh`.** Expected: `all assertions passed`. If an app-template 5.3.0 change breaks an assertion, fix the values (not the assertion) unless the release notes show the assertion encodes old chart behaviour. Explain which in the PR.
- [ ] **Step 5: Delete `apps/helm-webapp/`, fix the Cilium comment, pin openspeedtest.** Re-run Step 3 (expected: all `ok`).
- [ ] **Step 6: Commit** (one commit per logical change is fine), push `chore/deps-batch-1`, open the PR. The PR body must include the owner's commands:
  - helm-webapp removal, run **before** merging. The Application has no finalizer, so a plain delete would orphan the workload:
    ```bash
    kubectl -n argocd get application helm-webapp-dev -o jsonpath='{.spec.destination.namespace}{"\n"}'   # expect: dev
    kubectl -n dev get all
    kubectl -n argocd patch application helm-webapp-dev --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
    kubectl -n argocd delete application helm-webapp-dev
    kubectl -n dev get all          # expect: No resources found
    kubectl get ns dev && kubectl delete ns dev   # only if nothing else lives there
    ```
  - Post-merge checks: `kubectl -n argocd get applications` (all `Synced`/`Healthy`), pods running in `monitoring`, `media`, `cert-manager`, `kube-system` (sealed-secrets), the pangolin-newt Application's destination namespace, the Pangolin-exposed probes `probe_success == 1` in Prometheus, and one `kubeseal --fetch-cert` to confirm the sealed-secrets controller answers.
- [ ] **Step 7: Stop.** Wait for the owner to confirm batch 1 is merged and healthy.

### Task 3: Batch 2: snapshot-controller and cloudnative-pg

**Files:**
- Modify: `infrastructure/storage/snapshot-controller/application.yaml`, `infrastructure/database/cloudnative-pg/application.yaml`
- Test: `tests/render-app.sh`

- [ ] **Step 1: Re-check latest stable and read the release notes** for snapshot-controller (5.2.0 → 5.4.0, app v8.x: check for CRD version changes, e.g. `v1beta1` removal, and whether the chart ships CRDs) and cloudnative-pg chart (0.29.0 → 0.29.x: operator version and any CRD changes).
- [ ] **Step 2: Edit both `targetRevision`s. Run `tests/render-app.sh` on both files.** Expected: `ok` ×2.
- [ ] **Step 3: Commit, push `chore/deps-batch-2`, open the PR** with owner checks:
  ```bash
  kubectl get crd volumesnapshots.snapshot.storage.k8s.io -o jsonpath='{.spec.versions[*].name}{"\n"}'
  kubectl -n kube-system get pods | grep -i snapshot
  kubectl -n cnpg-system get pods        # adjust namespace to the Application's destination
  kubectl -n immich get cluster immich-db   # expect: Cluster in healthy state
  kubectl -n immich get backup --sort-by=.metadata.creationTimestamp | tail -3
  ```
  plus the existing snapshot round-trip: `kubectl apply -f infrastructure/storage/democratic-csi/tests/snapshot-test.yaml` per `infrastructure/storage/democratic-csi/tests/README.md`, then clean up as that README says. Rollback section: revert the PR. CRD changes are **not** reverted by ArgoCD and the old operator must still be able to read them, so state whether that holds based on the release notes.
- [ ] **Step 4: Stop.** Wait for the owner.

### Task 4: Batch 3: Immich (backup gate, then bump)

**Files:**
- Modify: `apps/immich/values.yaml` (`tag:`), possibly `apps/immich/db/cluster.yaml` (`imageName:`, only if required)
- Modify: `apps/immich/db/README.md` (add a "Before an Immich upgrade" section with the backup and restore commands below, so they're reusable)
- Test: `tests/render-app.sh`

- [ ] **Step 1: Decide the target and the VectorChord requirement.** Latest stable Immich (≥ v3.3.6). Read `server/src/constants.ts` at that tag for the accepted VectorChord range. Compare it with the current `17.9-1.1.0` (VectorChord 1.1.0). If 1.1.0 is in range, `cluster.yaml` stays unchanged. If not, pick the newest `17.*-<vchord>` tag in range: same Postgres major **17**, never 18. Read each Immich release note from v3.1.0 up to the target for breaking changes and required manual steps.
- [ ] **Step 2: Check the server/ML tag coupling.** Render the immich chart 0.12.0 with the current values (`tests/render-app.sh apps/immich/application.yaml`, plus `helm template` to a file). Confirm with `yq` that both the server and machine-learning containers resolve to the single `tag:` in `values.yaml`. If ML takes its tag from a different key, set both to the target in this task and note it for Task 7 (grouping).
- [ ] **Step 3: Edit the tag(s). Run `tests/render-app.sh apps/immich/application.yaml apps/immich/db/application.yaml`.** Expected: `ok` / `skip`. Then use `yq` on the rendered output to check both containers show the new tag.
- [ ] **Step 4: Write the backup gate** into `apps/immich/db/README.md` and the PR body, to run **before merging**, in this order:
  ```bash
  # 1. On-demand snapshot backup. Apply from stdin, NOT a file under apps/immich/db (ArgoCD syncs that dir and would prune it)
  kubectl -n immich apply -f - <<'EOF'
  apiVersion: postgresql.cnpg.io/v1
  kind: Backup
  metadata:
    name: immich-db-pre-upgrade-<YYYYMMDD>
  spec:
    cluster: { name: immich-db }
    method: volumeSnapshot
  EOF
  kubectl -n immich get backup immich-db-pre-upgrade-<YYYYMMDD> -w   # expect phase: completed
  kubectl -n immich get volumesnapshot -l cnpg.io/backupName=immich-db-pre-upgrade-<YYYYMMDD> -o custom-columns=NAME:.metadata.name,READY:.status.readyToUse   # expect two rows (data + WAL), both true
  # 2. Off-array logical dump to the owner's PC
  PRIMARY=$(kubectl -n immich get cluster immich-db -o jsonpath='{.status.currentPrimary}')
  kubectl -n immich exec "$PRIMARY" -c postgres -- pg_dump -Fc -d immich > ~/immich-db-<YYYYMMDD>.dump
  ls -lh ~/immich-db-<YYYYMMDD>.dump                                     # expect: non-zero, plausible size
  kubectl -n immich exec -i "$PRIMARY" -c postgres -- pg_restore --list < ~/immich-db-<YYYYMMDD>.dump | grep -c 'TABLE DATA'   # expect: > 0, no error
  ```
  Also document both restore paths. (a) A new CNPG Cluster bootstrapped `from volumeSnapshots` of that Backup (`bootstrap.recovery.volumeSnapshots.storage`/`walStorage`). (b) `pg_restore --clean --if-exists -d immich` into a fresh cluster from the dump. The PR body says: **do not merge until both checks above pass.** Check the snapshot label selector against the CNPG version deployed after Task 3. If the label differs, use the one that version sets.
- [ ] **Step 5: Commit, push `chore/deps-batch-3`, open the PR** with post-merge checks: `kubectl -n immich logs deploy/immich-server --since=15m | grep -iE 'migrat|error'` (expect migrations completed, no errors), `kubectl -n immich get pods`, and log in through the browser to open a recent photo and run a search (this exercises ML + VectorChord). Rollback: a revert doesn't undo the DB migrations. Rolling back means restoring the database from the Step 4 backup **and** reverting the tag.
- [ ] **Step 6: Stop.** Wait for the owner.

### Task 5: Batches 4 and 5: Traefik 42, then kube-prometheus-stack 93 (two separate PRs)

**Files:**
- Modify: `infrastructure/networking/traefik/application.yaml` (+ `infrastructure/networking/traefik/values.yaml` if the notes require it), branch `chore/deps-batch-4`
- Modify: `infrastructure/monitoring/kube-prometheus-stack/application.yaml` (+ `values.yaml` if required), branch `chore/deps-batch-5`, opened only after batch 4 is confirmed
- Test: `tests/render-app.sh`

- [ ] **Step 1 (Traefik): Read the chart upgrade notes 41 → 42 and the Traefik app release notes** between the current and target app versions. Check the Gateway API version the target requires against what's installed. The owner runs `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'`. If 42 needs newer CRDs, stop at the newest 41.x and record why (Global Constraints).
- [ ] **Step 2 (Traefik): Edit, adjust values per the notes, run `tests/render-app.sh infrastructure/networking/traefik/application.yaml`.** Expected: `ok`. Diff the render before and after (`helm template` both versions to files, `diff`) and summarise the material changes in the PR.
- [ ] **Step 3 (Traefik): Commit, push, open the PR** with checks: `kubectl -n traefik get pods`, `kubectl get gateway -A` (Programmed=True), `kubectl get httproute -A` (Accepted), `curl -sI https://<each *.koutoulastha.dev host>` from the LAN, `probe_success` for the Pangolin-edge probes. Rollback: revert the PR. Then **stop** and wait for the owner.
- [ ] **Step 4 (kps): Read the kube-prometheus-stack upgrade notes for every major 89 → 93** (chart README "Upgrading" section). Collect the required CRD actions, values renames and removed keys. Check the current `values.yaml` against each one.
- [ ] **Step 5 (kps): Edit `targetRevision`, apply the values changes, run `tests/render-app.sh infrastructure/monitoring/kube-prometheus-stack/application.yaml`.** Expected: `ok`. Diff the renders (old vs new) and summarise. If the notes require a manual CRD step that ArgoCD's ServerSideApply sync doesn't cover, put it in the PR as a pre-merge owner command.
- [ ] **Step 6 (kps): Commit, push `chore/deps-batch-5`, open the PR** with checks: `kubectl -n monitoring get pods`, Prometheus targets page has no new `down` targets, Alertmanager has no new firing alerts beyond `Watchdog`, Grafana loads the Loki datasource and the pve/TrueNAS dashboards, and the `PrometheusRule`s from `alertrules.yaml` files are still loaded (`kubectl get prometheusrule -A`). Rollback: revert. CRDs stay at the newer version, which is backward-compatible per the chart notes (state what the notes say). Then **stop**.

### Task 6: Renovate coverage test (failing first)

**Files:**
- Create: `tests/renovate/coverage-test.sh`
- Create: `tests/renovate/expected-deps.txt`
- Modify: `devbox.json` (add `nodejs@22`)
- Modify: `tests/README.md`

**Interfaces:**
- Produces: `devbox run -- bash tests/renovate/coverage-test.sh`. It runs `npx --yes renovate@<pinned current major> --platform=local --dry-run=lookup --report-type=file --report-path=$OUT/report.json` from the repo root (`RENOVATE_CONFIG_FILE` unset, so it reads the repo's `renovate.json`; set `GITHUB_COM_TOKEN` from `gh auth token` if present, to avoid rate limits). It extracts `depName` and `currentValue` for every dependency from the report with `jq`, and asserts:
  1. **Coverage:** every line of `expected-deps.txt` (`<depName> <file>`) is detected in that file.
  2. **No pre-releases:** no proposed update for `ghcr.io/home-operations/sonarr` with `newVersion` starting `5.`, radarr `7.`, prowlarr `3.`, lidarr `3.2`. These are the known pre-release lines on 2026-11-09. Each line carries a comment that it's a dated fixture, to update when those lines go stable.
  3. **Blocked majors:** no proposed `major` update for `ghcr.io/tensorchord/cloudnative-vectorchord`.
  4. **No helm-webapp, nothing under `old/`.**
  It prints `ok`/`FAIL` per assertion and exits non-zero on any failure.
- `expected-deps.txt` has one line for every row of the spec's inventory table as it stands after Tasks 2-5. That includes `ghcr.io/immich-app/immich-server apps/immich/values.yaml`, `ghcr.io/tensorchord/cloudnative-vectorchord apps/immich/db/cluster.yaml`, `app-template` ×8 files, `alloy` ×4, `cert-manager`, `traefik`, `openspeedtest/latest`, `alpine/kubectl`, `busybox`, `prompve/prometheus-pve-exporter`, `ghcr.io/unknowlars/truenas-scale-api-prometheus-exporter`, and every media image.

- [ ] **Step 1: Write `expected-deps.txt` and `coverage-test.sh`. Add `nodejs@22` to devbox.** Branch `chore/renovate` from `main` after batch 5 is merged.
- [ ] **Step 2: Run it with no `renovate.json` in the repo.** Expected: FAIL. Coverage misses at least every ArgoCD `targetRevision` (the `argocd` manager matches no files by default), the Immich tag and `imageName`.
- [ ] **Step 3: Commit:** `test: Renovate dependency coverage and pre-release guard`.

### Task 7: `renovate.json` and runbook, then enable the app

**Files:**
- Create: `renovate.json`
- Create: `docs/dependency-updates.md`
- Modify: `README.md` (one line linking the runbook)
- Test: `tests/renovate/coverage-test.sh`

**Interfaces:**
- Consumes: the coverage test (Task 6). Any version caps recorded in Tasks 2-5's PRs.

`renovate.json` must contain (values from the spec):
- `extends`: `config:recommended`, `:dependencyDashboard`, `docker:pinDigests` (keeps existing digest pins updated).
- `timezone: "Europe/Athens"`, `schedule: ["* * * * 0,6"]` (weekends only).
- `ignorePaths`: `old/**`.
- `argocd.managerFilePatterns` (or `fileMatch`, depending on the pinned Renovate version): `/(^|/)application[^/]*\.ya?ml$/` under `apps/` and `infrastructure/`. Also `helm-values` and `kubernetes` file patterns covering `apps/**` and `infrastructure/**` `*.yaml`.
- `customManagers` (regex): (1) Immich: `apps/immich/values.yaml` `tag: (?<currentValue>v\S+)` → `depName: ghcr.io/immich-app/immich-server`, `datasourceTemplate: docker`. (2) CNPG `imageName: (?<depName>[^:\s]+):(?<currentValue>\S+)` in `apps/immich/db/cluster.yaml`, with `versioningTemplate` set to a regex versioning that treats `17.9` as major.minor and the `-1.1.0` suffix as compatibility, e.g. `regex:^(?<major>\d+)\.(?<minor>\d+)-(?<compatibility>.+)$`. Pick what makes assertion 3 meaningful and document the choice. (3) Any other gap the Step 2 run shows.
- `packageRules`:
  - group `app-template` (all files) → one PR. Group `alloy` → one PR. Group Immich server + ML (only if Task 4 found separate keys).
  - `matchUpdateTypes: ["major"]` → `labels: ["major"]`.
  - `cloudnative-vectorchord`: `major` → `enabled: false`.
  - home-operations *arr: `allowedVersions` per image excluding the current pre-release line (sonarr `<5`, radarr `<7`, prowlarr `<3`, lidarr `<3.2`). Plus `prBodyNotes` with a link to the upstream releases page and the text "home-operations tags don't mark pre-releases: confirm this version is a non-pre-release on GitHub before merging." Plus label `check-upstream-stable`. **This is the stable-only mechanism: caps for the known pre-release majors, with the owner's review as the backstop for pre-releases inside a major.** The runbook says so plainly, and says to move the cap when upstream promotes a line to stable.
  - `alpine/kubectl`: `allowedVersions` limited to the cluster's minor (from Task 1).
  - any caps from Tasks 2-5 (Gateway API / Kubernetes blocked).
  - a final rule `"description": "FUTURE: patch auto-merge — flip enabled to true"`, `matchUpdateTypes: ["patch"]`, `automerge: true`, `enabled: false`. Plus a rule after it excluding `democratic-csi`, `snapshot-controller`, `cloudnative-pg`, `cloudnative-vectorchord`, `immich-server` and the *arr images from auto-merge (`automerge: false`). The runbook explains that turning auto-merge on means changing only that one `enabled`.

- [ ] **Step 1: Write `renovate.json`.** Run `npx --yes --package renovate@<same version> renovate-config-validator --strict`. Expected: `Config validated successfully`.
- [ ] **Step 2: Run `devbox run -- bash tests/renovate/coverage-test.sh`.** Expected: all assertions `ok`. For each coverage gap, fix the config (add a manager or a custom manager) and re-run. Never edit `expected-deps.txt` to make it pass, unless the line is wrong about the repo.
- [ ] **Step 3: Write `docs/dependency-updates.md`**: how Renovate PRs flow (weekend schedule, Dependency Dashboard, merge = deploy); a pre-merge checklist per risk class (low-risk = render test green; storage/DB = Task 3 checks; Immich = Task 4 backup gate; Traefik/kps = Task 5 checks; *arr = confirm upstream non-pre-release); how to run `tests/render-app.sh` and the coverage test; how to turn on patch auto-merge; and a **Deferred: Cilium and ArgoCD** section with the spec's recorded facts (Helm release `cilium` chart 1.19.4 but DaemonSet image v1.19.1, generation 7 vs revision 4; ArgoCD v3.3.3 from plain manifests; latest 1.19.10/1.20.4 and 3.6.1 as of 2026-11-08; first commands to run next time). Link it from `README.md`.
- [ ] **Step 4: Commit, push `chore/renovate`, open the PR.** The body tells the owner to merge it **then** install the Mend Renovate GitHub app on `koutoulastha/home-lab` only (https://github.com/apps/renovate), choosing to skip the onboarding PR since the config already exists.
- [ ] **Step 5: Stop until the owner confirms the app is installed and the Dependency Dashboard issue appeared.** Then compare the dashboard's "Detected dependencies" section (`gh issue view <n> --repo koutoulastha/home-lab`) against `tests/renovate/expected-deps.txt`. Expected: every line present, and no pending PR for a pre-release *arr line or a vectorchord major. Report any difference to the owner as a gap with a proposed config fix (a follow-up PR). Phase 2 is done only when there are no gaps.
