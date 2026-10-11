# Music stack (Lidarr, Navidrome) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Lidarr to the media pipeline and serve the music library through Navidrome (public via Pangolin, SSO off) and Jellyfin.

**Architecture:** Two new Argo CD Applications in `apps/media/` on bjw-s app-template 5.2.1, the same shape as Sonarr. Lidarr is LAN-only and reaches qBittorrent through an updated Cilium policy. Navidrome mounts `media/music` read-only, sits behind a two-way `CiliumNetworkPolicy`, and is monitored through Pangolin's edge by a blackbox probe.

**Tech Stack:** Argo CD, bjw-s app-template 5.2.1 (OCI), Cilium `CiliumNetworkPolicy`, sealed-secrets, kube-prometheus-stack `Probe` + blackbox-exporter, Pangolin Cloud + Newt.

**Spec:** `docs/superpowers/specs/2026-10-11-music-stack-design.md` (extends `docs/superpowers/specs/2026-09-30-media-stack-design.md`).

## Global Constraints

- **Branch:** work on `feat/music-stack`; Argo CD tracks `main`, so nothing deploys until the PR merges (Task 6).
- **The user runs every command that touches the cluster, TrueNAS, Last.fm or Pangolin** (`kubectl`, `kubeseal`, UI work). Agent steps: writing files, the render test, `grep`, `git`. Steps marked **(user)** are handed over as copy-paste blocks; wait for the user's output.
- **Tooling through devbox:** `devbox run -- helm …`, `devbox run -- yq …`. The bare `/usr/bin/yq` is a different tool; never use it.
- **Render test:** `devbox run -- bash apps/media/tests/render-test.sh [app...]` from the repo root. It must end with `all assertions passed` for **all** apps (no argument) before every commit.
- **Pinned exactly:** chart `app-template` **5.2.1**; images
  - `ghcr.io/home-operations/lidarr:3.1.6.5078@sha256:b4c60ae24ff264bcdfd8d5562982d99105c17b82c28a6986498f6fb215b7f42e`
  - `ghcr.io/navidrome/navidrome:0.64.2@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52`
- **UID/GID 568** for both containers and `fsGroup`.
- **No plaintext secrets in git.** Seal with `kubeseal --format yaml` (controller defaults); commit only `sealed-secret.yaml`.
- **Hostnames:** `lidarr.koutoulastha.dev` (LAN only); `music.koutoulastha.dev` (LAN route **and** Pangolin resource). Gateway `traefik-gateway` in `default`; the wildcard cert covers both — create no Certificate.
- **Library path:** `/data/media/music`; qBittorrent category `music` → `/data/torrents/music`.
- **Navidrome env must never contain** `ND_EXTAUTH_TRUSTEDSOURCES` or `ND_REVERSEPROXYWHITELIST`.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Navidrome's first visitor becomes admin.** If the Pangolin resource exists before the admin, anyone on the internet can claim it. Pinned by Task 6's ordering (admin step 3, Pangolin step 4) and the `curl /auth/createAdmin` check in Task 6 Step 4.
2. **Header-auth bypass.** Someone "fixing" the shared rate-limit bucket by setting `ND_EXTAUTH_TRUSTEDSOURCES` would let any internet client log in as any user by sending `Remote-User`. Pinned by the `test_navidrome` assertion that neither variable is set, and a values-file comment.
3. **Lidarr blocked by existing policies.** Without the qBittorrent ingress and Prowlarr egress changes, the deploy looks healthy but downloads and indexer sync time out. Pinned by the Task 2 assertions and Task 6's UI *Test* checks.
4. **Kubelet probes dropped by Navidrome's ingress policy.** An ingress policy without `fromEntities: [host]` makes the pod never become Ready. Pinned by a `test_navidrome` assertion.
5. **Egress wider than intended.** Using `toEntities: [world]` or dropping an `except` entry would let a compromised Navidrome reach TrueNAS or the router. Pinned by `test_navidrome` CIDR assertions and Task 6's in-pod drop tests.

---

## File map

| File | Task | Responsibility |
|---|---|---|
| `apps/media/tests/render-test.sh` | 1, 2, 3, 4 | `test_lidarr`, `test_navidrome`; hostname parameter in `common_checks`; policy assertions |
| `apps/media/lidarr/{application,values,sealed-secret}.yaml` | 1 | Lidarr |
| `apps/media/qbittorrent/networkpolicy.yaml` | 2 | allow Lidarr → 8080 |
| `apps/media/prowlarr/networkpolicy.yaml` | 2 | allow Prowlarr → Lidarr 8686 |
| `apps/media/navidrome/{application,values,networkpolicy,sealed-secret}.yaml` | 3 | Navidrome |
| `apps/media/navidrome/probe.yaml` | 4 | public probe |
| `infrastructure/monitoring/blackbox-exporter/values.yaml` | 4 | `http_navidrome_pangolin` module |
| `apps/media/README.md` | 5 | runbook |

---

### Task 1: Lidarr Application

**Files:**
- Create: `apps/media/lidarr/application.yaml`, `apps/media/lidarr/values.yaml`, `apps/media/lidarr/sealed-secret.yaml`
- Modify: `apps/media/tests/render-test.sh` (add `test_lidarr` after `test_radarr`)

**Interfaces:**
- Consumes: `arr_checks <app> <port>` (existing in render-test.sh); PVC `media-data`.
- Produces: pods labelled `app.kubernetes.io/name: lidarr`; Service `lidarr` port 8686 (Task 2 relies on both); Secret `lidarr-secret` key `LIDARR__AUTH__APIKEY`.

- [ ] **Step 1: Write the failing test**

In `apps/media/tests/render-test.sh`, after the `test_radarr` function, add:

```bash
test_lidarr() {
  arr_checks lidarr 8686
  local f="$OUT/lidarr.yaml" a='select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app")'
  eq "lidarr: /data mounted whole" "$f" "$a | .volumeMounts[] | select(.mountPath == \"/data\") | has(\"subPath\")" "false"
  eq "lidarr: /data is media-data" "$f" 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName' "media-data"
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `devbox run -- bash apps/media/tests/render-test.sh lidarr`
Expected: failure — `yq` cannot read `apps/media/lidarr/application.yaml` (the directory does not exist yet).

- [ ] **Step 3: Write `apps/media/lidarr/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: lidarr
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  sources:
    - repoURL: ghcr.io/bjw-s-labs/helm
      chart: app-template
      targetRevision: 5.2.1
      helm:
        releaseName: lidarr
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/lidarr/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/lidarr
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 4: Write `apps/media/lidarr/values.yaml`**

```yaml
# Lidarr. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Same shape as Sonarr/Radarr.
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  lidarr:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/lidarr
          tag: 3.1.6.5078@sha256:b4c60ae24ff264bcdfd8d5562982d99105c17b82c28a6986498f6fb215b7f42e
        env:
          LIDARR__AUTH__METHOD: Forms
          LIDARR__AUTH__REQUIRED: Enabled
        # LIDARR__AUTH__APIKEY, from sealed-secret.yaml. Pre-seeding the key
        # means Prowlarr can be wired to Lidarr without copying it out of a UI.
        envFrom:
          - secretRef:
              name: lidarr-secret
        probes:
          # /ping answers 200 without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 8686}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 8686}
              periodSeconds: 5
              failureThreshold: 60
        securityContext:
          runAsUser: 568
          runAsGroup: 568
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}

service:
  app:
    controller: lidarr
    ports:
      http:
        port: 8686

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [lidarr.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 8686

persistence:
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 5Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false,Delete=false
    globalMounts:
      - path: /config
  # The whole volume at /data, same path as qBittorrent: no remote path
  # mappings, and imports are hardlinks because it is one filesystem.
  # Root folder /data/media/music; qBittorrent category "music".
  data:
    existingClaim: media-data
    globalMounts:
      - path: /data
  tmp:
    type: emptyDir
    globalMounts:
      - path: /tmp
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `devbox run -- bash apps/media/tests/render-test.sh lidarr`
Expected: every line `ok`, then `all assertions passed`. (`arr_checks` reads only the rendered chart, so the missing sealed secret doesn't matter yet.)

- [ ] **Step 6 (user): Seal the API key**

Hand the user this block; ask for the two `grep` counts back:

```bash
cd ~/workspace/homelab
kubectl create secret generic lidarr-secret --namespace media \
  --from-literal=LIDARR__AUTH__APIKEY="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > apps/media/lidarr/sealed-secret.yaml
grep -c 'encryptedData' apps/media/lidarr/sealed-secret.yaml          # expect: 1
grep -c 'LIDARR__AUTH__APIKEY:' apps/media/lidarr/sealed-secret.yaml  # expect: 1
```

The key never needs to be known: `set_login` (README) reads it from the pod, and Prowlarr is given it in its UI from the same command.

- [ ] **Step 7: Verify the file on disk, then run all tests**

Run: `devbox run -- yq '.kind + " " + .metadata.name + " " + .metadata.namespace' apps/media/lidarr/sealed-secret.yaml`
Expected: `SealedSecret lidarr-secret media`

Run: `devbox run -- bash apps/media/tests/render-test.sh`
Expected: `all assertions passed`

- [ ] **Step 8: Commit**

```bash
git add apps/media/lidarr apps/media/tests/render-test.sh
git commit -m "feat(media): Lidarr

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Let Lidarr through the existing network policies

**Files:**
- Modify: `apps/media/qbittorrent/networkpolicy.yaml` (header comment, and the 8080 ingress `values` list)
- Modify: `apps/media/prowlarr/networkpolicy.yaml` (add an egress rule after the radarr rule)
- Modify: `apps/media/tests/render-test.sh` (`test_qbittorrent`, `test_prowlarr`)

**Interfaces:**
- Consumes: label `app.kubernetes.io/name: lidarr`, port 8686 (Task 1).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Write the failing assertions**

In `test_qbittorrent`, after the line `eq "CNP: proxy only from prowlarr+flaresolverr" …`, add:

```bash
  eq "CNP: web UI from the *arrs"           "$np" '.spec.ingress[] | select(.toPorts[0].ports[0].port == "8080") | .fromEndpoints[] | select(has("matchExpressions")) | .matchExpressions[0].values | sort | join(",")' "lidarr,radarr,sonarr"
```

In `test_prowlarr`, after the `prowlarr CNP: may reach flaresolverr` line, add:

```bash
  eq "prowlarr CNP: may reach lidarr"    "$np" '.spec.egress[] | select(.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "lidarr") | .toPorts[0].ports[0].port' "8686"
```

- [ ] **Step 2: Run to verify both fail**

Run: `devbox run -- bash apps/media/tests/render-test.sh qbittorrent prowlarr`
Expected: two `FAIL` lines — `got: radarr,sonarr` and `got:` (empty).

- [ ] **Step 3: Update `apps/media/qbittorrent/networkpolicy.yaml`**

In the header comment, change `#   8080  web UI/API   — Traefik (the LAN route) and Sonarr/Radarr` to:

```yaml
#   8080  web UI/API   — Traefik (the LAN route) and Sonarr/Radarr/Lidarr
```

and change the ingress list `values: [sonarr, radarr]` to:

```yaml
              values: [sonarr, radarr, lidarr]
```

- [ ] **Step 4: Update `apps/media/prowlarr/networkpolicy.yaml`**

In the header comment change `(Traefik, and Sonarr/Radarr, which` to `(Traefik, and Sonarr/Radarr/Lidarr, which`. After the radarr egress rule (the block ending `port: "7878"`), add:

```yaml
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: lidarr
      toPorts:
        - ports:
            - port: "8686"
              protocol: TCP
```

- [ ] **Step 5: Run all tests**

Run: `devbox run -- bash apps/media/tests/render-test.sh`
Expected: `all assertions passed` (the existing `CNP: exactly one egress rule` for qBittorrent must still pass — egress is untouched).

- [ ] **Step 6: Commit**

```bash
git add apps/media/qbittorrent/networkpolicy.yaml apps/media/prowlarr/networkpolicy.yaml apps/media/tests/render-test.sh
git commit -m "feat(media): let Lidarr reach qBittorrent and Prowlarr reach Lidarr

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Navidrome Application and network policy

**Files:**
- Create: `apps/media/navidrome/application.yaml`, `values.yaml`, `networkpolicy.yaml`, `sealed-secret.yaml`
- Modify: `apps/media/tests/render-test.sh` (`common_checks` gains an optional hostname; add `test_navidrome` after `test_jellyfin`)

**Interfaces:**
- Consumes: PVC `media-data`; Newt pods labelled `app.kubernetes.io/component: newt` in namespace `pangolin`; Traefik pods `app.kubernetes.io/name: traefik` in namespace `traefik`.
- Produces: Service `navidrome` port 4533 (target for the Pangolin resource: `http://navidrome.media.svc.cluster.local:4533`); HTTPRoute host `music.koutoulastha.dev`; Secret `navidrome-secret` keys `ND_LASTFM_APIKEY`, `ND_LASTFM_SECRET`. Task 4 tests extend `test_navidrome`.

- [ ] **Step 1: Make `common_checks` take a hostname**

In `render-test.sh`, change the first lines of `common_checks` to:

```bash
# common_checks <app> <file> <port> <container> [hostname]
common_checks() {
  local app=$1 f=$2 port=$3 container=$4 host=${5:-$1.koutoulastha.dev}
```

and its hostname line to:

```bash
  eq "$app: HTTPRoute hostname"           "$f" 'select(.kind == "HTTPRoute") | .spec.hostnames[0]' "$host"
```

Run: `devbox run -- bash apps/media/tests/render-test.sh`
Expected: `all assertions passed` (behaviour unchanged for existing apps).

- [ ] **Step 2: Write the failing test**

After `test_jellyfin`, add:

```bash
test_navidrome() {
  local f; f=$(render navidrome)
  local dep='select(.kind == "Deployment")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  local env="$dep | $a | .env[]"
  common_checks navidrome "$f" 4533 app music.koutoulastha.dev
  eq "navidrome: read-only root"          "$f" "$dep | $a | .securityContext.readOnlyRootFilesystem" "true"
  eq "navidrome: drops all caps"          "$f" "$dep | $a | .securityContext.capabilities.drop[0]" "ALL"
  eq "navidrome: no SA token"             "$f" "$dep | .spec.template.spec.automountServiceAccountToken" "false"
  eq "navidrome: probes /ping"            "$f" "$dep | $a | .readinessProbe.httpGet.path" "/ping"
  eq "navidrome: library read-only"       "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/music\") | .readOnly" "true"
  eq "navidrome: library is media/music"  "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/music\") | .subPath" "media/music"
  eq "navidrome: nothing else of media-data" "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data\") | .mountPath" ""
  eq "navidrome: data folder"             "$f" "$env | select(.name == \"ND_DATAFOLDER\") | .value" "/config"
  eq "navidrome: music folder"            "$f" "$env | select(.name == \"ND_MUSICFOLDER\") | .value" "/music"
  eq "navidrome: scheduled scan"          "$f" "$env | select(.name == \"ND_SCANNER_SCHEDULE\") | .value" "@every 1h"
  eq "navidrome: agents"                  "$f" "$env | select(.name == \"ND_AGENTS\") | .value" "deezer,lastfm"
  eq "navidrome: no insights"             "$f" "$env | select(.name == \"ND_ENABLEINSIGHTSCOLLECTOR\") | .value" "false"
  eq "navidrome: no sharing"              "$f" "$env | select(.name == \"ND_ENABLESHARING\") | .value" "false"
  # Header-auth bypass: these would let any internet client send Remote-User.
  eq "navidrome: no ExtAuth trust"        "$f" "$env | select(.name == \"ND_EXTAUTH_TRUSTEDSOURCES\" or .name == \"ND_REVERSEPROXYWHITELIST\") | .name" ""
  eq "navidrome: Last.fm key from secret" "$f" "$dep | $a | .envFrom[0].secretRef.name" "navidrome-secret"
  local np="$MEDIA/navidrome/networkpolicy.yaml"
  eq "navidrome CNP: selects navidrome"   "$np" '.spec.endpointSelector.matchLabels["app.kubernetes.io/name"]' "navidrome"
  eq "navidrome CNP: ingress traefik+newt" "$np" '[.spec.ingress[].fromEndpoints[]? | .matchLabels | (.["app.kubernetes.io/name"] // .["app.kubernetes.io/component"])] | sort | join(",")' "newt,traefik"
  eq "navidrome CNP: kubelet probes"      "$np" '.spec.ingress[] | select(has("fromEntities")) | .fromEntities[0]' "host"
  eq "navidrome CNP: ingress only 4533"   "$np" '[.spec.ingress[].toPorts[].ports[].port] | unique | join(",")' "4533"
  eq "navidrome CNP: no world entity"     "$np" '[.spec.egress[] | select(has("toEntities"))] | length' "0"
  eq "navidrome CNP: internet excludes LAN" "$np" '.spec.egress[] | select(has("toCIDRSet")) | .toCIDRSet[0].except | sort | join(",")' "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  eq "navidrome CNP: internet is 443 only" "$np" '.spec.egress[] | select(has("toCIDRSet")) | .toPorts[0].ports[0].port + "/" + .toPorts[0].ports[0].protocol' "443/TCP"
  eq "navidrome CNP: egress rule count"   "$np" '.spec.egress | length' "2"
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `devbox run -- bash apps/media/tests/render-test.sh navidrome`
Expected: failure — `apps/media/navidrome/application.yaml` does not exist.

- [ ] **Step 4: Write `apps/media/navidrome/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: navidrome
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  sources:
    - repoURL: ghcr.io/bjw-s-labs/helm
      chart: app-template
      targetRevision: 5.2.1
      helm:
        releaseName: navidrome
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/navidrome/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/navidrome
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 5: Write `apps/media/navidrome/values.yaml`**

```yaml
# Navidrome. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Public via Pangolin with SSO OFF, so
# Navidrome's own login is the only gate; networkpolicy.yaml confines it.
defaultPodOptions:
  # Internet-facing: no Kubernetes API credentials in the pod.
  automountServiceAccountToken: false
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  navidrome:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/navidrome/navidrome
          tag: 0.64.2@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52
        env:
          ND_DATAFOLDER: /config
          ND_MUSICFOLDER: /music
          # inotify does not fire over NFS, so the schedule is what picks up
          # Lidarr's imports.
          ND_SCANNER_SCHEDULE: "@every 1h"
          # Artist images (Deezer, no key) and bios (Last.fm, key in
          # sealed-secret.yaml). ListenBrainz, a default, is left out.
          ND_AGENTS: deezer,lastfm
          ND_ENABLEINSIGHTSCOLLECTOR: "false"
          ND_ENABLESHARING: "false"
          # NEVER set ND_EXTAUTH_TRUSTEDSOURCES (old name
          # ND_REVERSEPROXYWHITELIST). It does make the login rate limiter see
          # real client IPs, but it also turns on Remote-User header login for
          # requests from those proxies, and Traefik and Newt pass that header
          # through from the internet. The render test fails if it appears.
        # ND_LASTFM_APIKEY, ND_LASTFM_SECRET.
        envFrom:
          - secretRef:
              name: navidrome-secret
        probes:
          # /ping answers 200 "." without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 4533}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 4533}
              periodSeconds: 5
              failureThreshold: 60
        securityContext:
          runAsUser: 568
          runAsGroup: 568
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}

service:
  app:
    controller: navidrome
    ports:
      http:
        port: 4533

# Same hostname as the Pangolin resource: LAN DNS resolves it to Traefik,
# public DNS to the Pangolin edge.
route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [music.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 4533

persistence:
  # SQLite database and caches (artwork, transcodes). SQLite is unsafe on NFS.
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 2Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false,Delete=false
    globalMounts:
      - path: /config
  # The music library only, read-only: Navidrome cannot change or delete it.
  media:
    existingClaim: media-data
    globalMounts:
      - path: /music
        subPath: media/music
        readOnly: true
  tmp:
    type: emptyDir
    sizeLimit: 2Gi
    globalMounts:
      - path: /tmp
```

- [ ] **Step 6: Write `apps/media/navidrome/networkpolicy.yaml`**

```yaml
# Navidrome is the only app in the stack reachable from the internet without
# Pangolin SSO, so both directions are restricted.
#
# Ingress on 4533: Traefik (LAN route), Newt (Pangolin tunnel), and the node
# (kubelet probes — with an ingress policy present they are not implied).
#
# Egress: cluster DNS, and HTTPS to public addresses only — Deezer artwork and
# Last.fm bios. Not `toEntities: [world]`: that includes the LAN (TrueNAS,
# router, Talos nodes). Private ranges are excepted explicitly; pods and
# Services (10.244/16, 10.96/12) fall inside 10.0.0.0/8 as well.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: navidrome
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: navidrome
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: traefik
            app.kubernetes.io/name: traefik
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: pangolin
            app.kubernetes.io/component: newt
      toPorts:
        - ports:
            - port: "4533"
              protocol: TCP
    - fromEntities: [host]
      toPorts:
        - ports:
            - port: "4533"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
    - toCIDRSet:
        - cidr: 0.0.0.0/0
          except:
            - 10.0.0.0/8
            - 172.16.0.0/12
            - 192.168.0.0/16
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `devbox run -- bash apps/media/tests/render-test.sh navidrome`
Expected: every line `ok`. If `navidrome: no SA token` fails with an empty value, app-template 5.2.1 does not take `automountServiceAccountToken` under `defaultPodOptions` — check the chart's `values.schema.json` (`helm show values oci://ghcr.io/bjw-s-labs/helm/app-template --version 5.2.1 | grep -n -i automount`) and move the key to where the schema puts it; do not delete the assertion.

- [ ] **Step 8 (user): Last.fm API account and sealed secret**

Navidrome ships no Last.fm key; without one the Last.fm agent silently does nothing (Deezer still works). Hand the user this:

1. Create an API account at https://www.last.fm/api/account/create (any application name, e.g. "homelab navidrome"; callback URL can be blank). Note the **API key** and **Shared secret**.
2. Run:

```bash
cd ~/workspace/homelab
read -rp "Last.fm API key: " LFM_KEY; read -rsp "Last.fm shared secret: " LFM_SECRET; echo
kubectl create secret generic navidrome-secret --namespace media \
  --from-literal=ND_LASTFM_APIKEY="$LFM_KEY" \
  --from-literal=ND_LASTFM_SECRET="$LFM_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > apps/media/navidrome/sealed-secret.yaml
unset LFM_KEY LFM_SECRET
grep -c 'ND_LASTFM_APIKEY:\|ND_LASTFM_SECRET:' apps/media/navidrome/sealed-secret.yaml   # expect: 2
```

- [ ] **Step 9: Verify on disk, run all tests**

Run: `devbox run -- yq '.kind + " " + .metadata.name + " " + .metadata.namespace + " " + (.spec.encryptedData | keys | join(","))' apps/media/navidrome/sealed-secret.yaml`
Expected: `SealedSecret navidrome-secret media ND_LASTFM_APIKEY,ND_LASTFM_SECRET`

Run: `devbox run -- bash apps/media/tests/render-test.sh`
Expected: `all assertions passed`

- [ ] **Step 10 (user): Server-side dry run of the policy**

```bash
kubectl apply --dry-run=server -f apps/media/navidrome/networkpolicy.yaml
# expect: ciliumnetworkpolicy.cilium.io/navidrome created (server dry run)
```

- [ ] **Step 11: Commit**

```bash
git add apps/media/navidrome apps/media/tests/render-test.sh
git commit -m "feat(media): Navidrome, library read-only, two-way network policy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Public probe for Navidrome

**Files:**
- Create: `apps/media/navidrome/probe.yaml`
- Modify: `infrastructure/monitoring/blackbox-exporter/values.yaml` (new module after `http_jellyfin_pangolin`)
- Modify: `apps/media/tests/render-test.sh` (append to `test_navidrome`)

**Interfaces:**
- Consumes: Pangolin edge `130.110.2.46`; existing `BlackboxProbeFailed` alert (`probe_success{path!="vpn-portforward"} == 0` for 5m) — no new rule.
- Produces: Probe `navidrome-public`, `path` label `navidrome-public`; module `http_navidrome_pangolin`.

- [ ] **Step 1: Write the failing assertions**

At the end of `test_navidrome` (before its closing `}`), add:

```bash
  local pr="$MEDIA/navidrome/probe.yaml"
  local bb="$ROOT/infrastructure/monitoring/blackbox-exporter/values.yaml"
  local mod='.config.modules.http_navidrome_pangolin.http'
  eq "probe: module"                     "$pr" '.spec.module' "http_navidrome_pangolin"
  eq "probe: edge /ping"                 "$pr" '.spec.targets.staticConfig.static[0]' "https://130.110.2.46/ping"
  eq "probe: path label"                 "$pr" '.spec.targets.staticConfig.labels.path' "navidrome-public"
  eq "module: 200 only"                  "$bb" "$mod.valid_status_codes | join(\",\")" "200"
  eq "module: no redirects (SSO = fail)" "$bb" "$mod.follow_redirects" "false"
  eq "module: Host"                      "$bb" "$mod.headers.Host" "music.koutoulastha.dev"
  eq "module: SNI"                       "$bb" "$mod.tls_config.server_name" "music.koutoulastha.dev"
  eq "module: body is Navidrome's ping"  "$bb" "$mod.fail_if_body_not_matches_regexp[0]" '^\.$'
```

(Modules live under `.config.modules` — verified 2026-10-11: that path lists `http_2xx`, `http_2xx_pangolin`, `http_gluetun_portforward`, `http_jellyfin_pangolin`.)

- [ ] **Step 2: Run to verify failure**

Run: `devbox run -- bash apps/media/tests/render-test.sh navidrome`
Expected: `FAIL` lines for every new assertion (`probe.yaml` missing, module absent).

- [ ] **Step 3: Add the blackbox module**

In `infrastructure/monitoring/blackbox-exporter/values.yaml`, directly after the `http_jellyfin_pangolin` module (same indentation), add:

```yaml
    # Navidrome's public edge, by IP. Pangolin SSO is deliberately OFF for this
    # resource (Subsonic phone apps cannot pass it), so the request must go
    # through the Newt tunnel and be answered by Navidrome's /ping with ".".
    # Unlike the Jellyfin module, success proves the tunnel end to end.
    # A 302 to app.pangolin.net FAILS it (SSO switched on: phone apps broken);
    # a 502 means the tunnel or the pod is down.
    # Used by apps/media/navidrome/probe.yaml.
    http_navidrome_pangolin:
      prober: http
      timeout: 10s
      http:
        valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
        valid_status_codes: [200]
        follow_redirects: false
        fail_if_body_not_matches_regexp:
          - '^\.$'
        preferred_ip_protocol: ip4
        headers:
          Host: music.koutoulastha.dev
        tls_config:
          server_name: music.koutoulastha.dev
```

- [ ] **Step 4: Write `apps/media/navidrome/probe.yaml`**

```yaml
# Navidrome's Pangolin resource: edge + certificate + tunnel + Navidrome.
#
# Pangolin SSO is OFF for this resource (decided 2026-10-07: Subsonic apps
# need direct access; Navidrome's own login is the gate). The module expects
# Navidrome's own 200 "." from /ping and fails on a 302 to Pangolin auth.
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: navidrome-public
  namespace: media
spec:
  interval: 60s
  module: http_navidrome_pangolin
  prober:
    url: blackbox-exporter.monitoring.svc.cluster.local:9115
  targets:
    staticConfig:
      static:
        - https://130.110.2.46/ping
      labels:
        path: navidrome-public
```

- [ ] **Step 5: Run all tests**

Run: `devbox run -- bash apps/media/tests/render-test.sh`
Expected: `all assertions passed`

- [ ] **Step 6: Commit**

```bash
git add apps/media/navidrome/probe.yaml infrastructure/monitoring/blackbox-exporter/values.yaml apps/media/tests/render-test.sh
git commit -m "feat(monitoring): probe Navidrome through the Pangolin edge, SSO must stay off

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Runbook (README)

**Files:**
- Modify: `apps/media/README.md`

**Interfaces:** none; documents Tasks 1–4.

- [ ] **Step 1: Intro and table**

Change the intro to:

```markdown
qBittorrent downloads over Proton VPN; Prowlarr, Sonarr, Radarr and Lidarr
drive it; Jellyfin serves the library and Navidrome the music. Design:
`docs/superpowers/specs/2026-09-30-media-stack-design.md`, music:
`docs/superpowers/specs/2026-10-11-music-stack-design.md`.
```

Add rows after Radarr and after Jellyfin respectively:

```markdown
| Lidarr | `lidarr` | https://lidarr.koutoulastha.dev | `lidarr.media.svc:8686` |
```
```markdown
| Navidrome | `navidrome` | https://music.koutoulastha.dev (also public via Pangolin, **no SSO**) | `navidrome.media.svc:4533` |
```

- [ ] **Step 2: Registering**

Add after the radarr apply line and after the jellyfin apply line respectively:

```bash
kubectl apply -f apps/media/lidarr/application.yaml
```
```bash
kubectl apply -f apps/media/navidrome/application.yaml  # then create the admin on the LAN BEFORE the Pangolin resource
```

- [ ] **Step 3: Things that live outside git**

Add bullets:

```markdown
- **Pangolin Cloud:** HTTP resource `music.koutoulastha.dev`, site
  `main-tunnel`, target `http://navidrome.media.svc.cluster.local:4533`,
  **Pangolin SSO off** (decided 2026-10-07: Subsonic phone apps cannot pass
  it). Create it only **after** Navidrome has an admin — Navidrome makes the
  first visitor its admin (`/auth/createAdmin` is open until then).
- **Last.fm:** an API account (https://www.last.fm/api/account/create) for
  Navidrome's biographies; key and secret sealed in
  `navidrome/sealed-secret.yaml`. Re-seal with the command in the music plan
  (Task 3 Step 8) to rotate.
```

- [ ] **Step 4: Operations and first-start notes**

In the `set_login` comment, change `# app, api-version (sonarr/radarr v3, prowlarr v1)` to `# app, api-version (sonarr/radarr v3, prowlarr/lidarr v1)`.

In **Operations**, change the backups bullet's first line to `Prowlarr/Sonarr/Radarr/Lidarr write scheduled backups to` and extend the Prowlarr bullet to `must use \`http://sonarr:8989\`, \`http://radarr:7878\` and \`http://lidarr:8686\``. Add:

```markdown
- **Lidarr:** download client qBittorrent `http://qbittorrent:8080`,
  category `music` (saves to `/data/torrents/music`); root folder
  `/data/media/music`; backups folder `/data/backups/lidarr`.
- **Music in Jellyfin:** *Dashboard → Libraries → Add* → type Music, folder
  `/data/media/music` (already mounted read-only — no manifest change).
- **Navidrome scans hourly** (`ND_SCANNER_SCHEDULE`); inotify does not work
  over NFS. For a new album now: *Settings → Library → Scan* (admin).
- **Navidrome locked out remotely** (`Too many failed login attempts` in its
  log): every remote request reaches Navidrome from the Newt pod, so the
  limiter (5 failures per 20 s per username) is shared by all remote
  clients. It clears after 20 s of quiet. Do **not** "fix" it with
  `ND_EXTAUTH_TRUSTEDSOURCES` — see Known, accepted risk.
```

- [ ] **Step 5: Known, accepted risk**

Append:

```markdown
Navidrome is public without Pangolin SSO (decided 2026-10-07), so its own
login faces the internet. Mitigations: a long random password per user;
rate limits on web and Subsonic logins; the library mounted read-only; no
service-account token; Cilium allows it only DNS and HTTPS to public
addresses, so a compromise cannot reach qBittorrent, the *arr APIs, TrueNAS
or the LAN. Because every remote request arrives from the Newt pod, an
attacker who knows a username can keep that user locked out remotely
(a nuisance, not a breach). `ND_EXTAUTH_TRUSTEDSOURCES` would restore
per-client limits but also enable `Remote-User` header login through Traefik
and Newt — it must stay unset (the render test enforces this).
```

- [ ] **Step 6: Verify and commit**

Run: `grep -c 'lidarr\|navidrome\|music.koutoulastha' apps/media/README.md`
Expected: a count of at least 12.

```bash
git add apps/media/README.md
git commit -m "docs(media): runbook for Lidarr and Navidrome

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Pull request and rollout

**Files:** none (merge and cluster operations). Every cluster step is **(user)**; ask for the output and confirm the expected result before moving on.

- [ ] **Step 1: Final local check and PR**

Run: `devbox run -- bash apps/media/tests/render-test.sh` → `all assertions passed`.

```bash
git push -u origin feat/music-stack
gh pr create --title "feat(media): Lidarr and Navidrome" --body "$(cat <<'EOF'
Adds music to the media stack: Lidarr (LAN-only, torrents via the existing VPN path) and Navidrome (public via Pangolin with SSO off, library read-only, two-way Cilium policy, edge probe). Jellyfin gets a Music library through the UI only.

Spec: docs/superpowers/specs/2026-10-11-music-stack-design.md
Plan: docs/superpowers/plans/2026-10-11-music-stack.md

Rollout is manual and ordered (plan Task 6): Navidrome's admin must exist before the Pangolin resource.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Merge only after the user approves the PR.

- [ ] **Step 2 (user): Lidarr**

```bash
kubectl apply -f apps/media/lidarr/application.yaml
kubectl -n argocd get application lidarr qbittorrent prowlarr -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
# expect: all Synced / Healthy
```

Then the README `set_login lidarr v1`; in Lidarr's UI: download client, root folder, backups folder (README Operations); in Prowlarr *Settings → Apps → + Lidarr*: Prowlarr server `http://prowlarr:9696`, Lidarr server `http://lidarr:8686`, API key from `kubectl -n media exec deploy/lidarr -- printenv LIDARR__AUTH__APIKEY`. Expected: Lidarr's download-client **Test** and Prowlarr's Lidarr **Test** are both green. A timeout on either means the Task 2 policy is not live — check `kubectl -n media get cnp qbittorrent -o yaml | grep -A3 values`.

**Re-run all README leak tests** (qBittorrent's policy changed). Expected: Proton org, `nameserver 127.0.0.1`, `{"port":N>0}`, `BLOCKED`, `DROPPED`.

- [ ] **Step 3 (user): Navidrome, admin first**

```bash
kubectl apply -f apps/media/navidrome/application.yaml
kubectl -n media rollout status deploy/navidrome --timeout=5m
```

If the pod crash-loops, `kubectl -n media logs deploy/navidrome` — a `read-only file system` path means something writes outside `/config` and `/tmp`; add an emptyDir for that path (do not drop `readOnlyRootFilesystem`).

On the LAN, open https://music.koutoulastha.dev and **create the admin now** (long random password from a password manager).

- [ ] **Step 4 (user): Pangolin resource and public checks**

First confirm the admin exists — this must return an error, not create a user:

```bash
curl -sk -X POST https://music.koutoulastha.dev/auth/createAdmin \
  -H 'Content-Type: application/json' -d '{"username":"probe","password":"x"}' -w '\n%{http_code}\n'
# expect: a 403/4xx — anything that returns a token means STOP, the admin step did not happen
```

Then in Pangolin Cloud create the resource (README *Things that live outside git*), SSO **off**. Check public DNS the same way as Jellyfin's: `dig +short music.koutoulastha.dev @1.1.1.1` returns the Pangolin edge (or its `*.cname.pangolin-ns.net` chain); if empty, add the record exactly as `jellyfin` has it. Then:

```bash
curl -s --resolve music.koutoulastha.dev:443:130.110.2.46 https://music.koutoulastha.dev/ping -w ' %{http_code}\n'
# expect: . 200
```

In Prometheus: `probe_success{path="navidrome-public"}` is `1` (allow 2 min). From a phone on mobile data, a Subsonic app (Symfonium, Substreamer…) logs in at `https://music.koutoulastha.dev`.

- [ ] **Step 5 (user): Network policy checks from inside Navidrome**

The image has BusyBox `wget`:

```bash
kubectl -n media exec deploy/navidrome -- wget -T 5 -qO /dev/null https://api.deezer.com/ping && echo DEEZER_OK
kubectl -n media exec deploy/navidrome -- sh -c 'wget -T 5 -qO- http://qbittorrent:8080 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
kubectl -n media exec deploy/navidrome -- sh -c 'wget -T 5 -qO- http://qbittorrent:8888 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
kubectl -n media exec deploy/navidrome -- sh -c 'wget -T 5 -qO- --no-check-certificate https://192.168.20.2 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
kubectl -n media exec deploy/navidrome -- sh -c 'test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo TOKEN || echo NO_TOKEN'
kubectl -n media exec deploy/navidrome -- sh -c 'touch /music/x 2>&1 || echo READ_ONLY'
```

Expected: `DEEZER_OK`, `DROPPED` ×3, `NO_TOKEN`, `READ_ONLY`. If the image has no `wget`, report it and run the drop tests from a busybox pod carrying the label instead: `kubectl -n media run cnp-test --rm -i --restart=Never --image=busybox:1.37 --labels=app.kubernetes.io/name=navidrome -- sh -c '…'`.

- [ ] **Step 6 (user): Jellyfin and one album end to end**

Jellyfin: add the Music library (README Operations). Lidarr: add one artist, search one album. Then:

```bash
f=$(kubectl -n media exec deploy/lidarr -- find /data/media/music -type f -name '*.flac' -o -type f -name '*.mp3' | head -1)
kubectl -n media exec deploy/lidarr -- stat -c '%h %n' "$f"
# expect: 2 <path>  (hardlink with the copy under /data/torrents/music)
```

Trigger a Navidrome scan (*Settings → Library → Scan*) — the album appears with artwork; the artist page shows a Last.fm biography. Jellyfin shows the album after its library scan.

- [ ] **Step 7: Record lessons**

If any step needed a deviation, add it to the README's *First-start gotchas* in a follow-up commit on `main` via PR, as for the 2026-10-01 rollout.
