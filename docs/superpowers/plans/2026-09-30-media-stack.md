# Media Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** qBittorrent downloading exclusively over Proton VPN, driven by Prowlarr/Sonarr/Radarr, feeding a Jellyfin library that is reachable on the LAN and through Pangolin.

**Architecture:** One `media` namespace. A never-pruned `media-storage` Application owns the namespace (PodSecurity `privileged`) and a static NFS PV/PVC on TrueNAS dataset `IOPSicle/media`. Five app-template Helm releases — each its own Application — mount that PVC; qBittorrent's pod carries a gluetun native sidecar whose tunnel is the pod's only way out, backed by a CiliumNetworkPolicy. Tasks 1–8 author and merge YAML; nothing reaches the cluster until an `application.yaml` is registered by hand, so Tasks 9–13 roll out and verify one Application at a time.

**Tech Stack:** Talos Kubernetes, Argo CD (multi-source Applications), bjw-s app-template 5.2.1 (OCI), gluetun v3.41.3, qBittorrent 5.2.4, Prowlarr 2.6.5.5623, Sonarr 4.0.20.3012, Radarr 6.4.4.10685, Jellyfin 12.1, Cilium, sealed-secrets, kube-prometheus-stack + blackbox-exporter, TrueNAS SCALE NFS, Pangolin.

**Spec:** `docs/superpowers/specs/2026-09-30-media-stack-design.md`

## Global Constraints

- **`main` is the deployment branch.** Argo CD tracks `targetRevision: main`. Author on branch `feat/media-stack`; merge via PR (Task 8).
- **No app-of-apps.** Every `application.yaml` must be `kubectl apply`'d once by hand or it deploys nothing. This plan adds six. `media-storage` must be registered and synced **before** any app Application (it owns the namespace; apps set no `CreateNamespace`).
- **The user runs every command that touches the cluster, TrueNAS, Proton or Pangolin.** `kubectl`, `kubeseal`, and all UI work are steps handed to the user, who reports the output. Agent steps are: writing files, the render test, `grep`, and `git`.
- **Agent tooling:** run `helm` and `yq` **through devbox** — `devbox run -- <cmd>` — which provides Helm 4 and mikefarah `yq`. The bare `/usr/bin/yq` is the Python jq-wrapper with different syntax; never use it for this plan's checks.
- **Reporting contract:** every value reported as done must come from a command run against the file on disk (or the cluster) *after* the change — never from the command that was typed.
- **No plaintext secrets in git.** Credentials are sealed with `kubeseal --format yaml` (controller `sealed-secrets-controller` in `kube-system`, the kubeseal defaults) and committed as `sealed-secret.yaml`.
- **Pinned exactly:** chart `app-template` **5.2.1** from `ghcr.io/bjw-s-labs/helm`. Images by tag **and** digest:
  - `ghcr.io/qdm12/gluetun:v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027`
  - `ghcr.io/home-operations/qbittorrent:5.2.4@sha256:9307627e03981d5473aa31175ea76ed56ea3752333ca49d601b6af45e281e7ba`
  - `ghcr.io/home-operations/prowlarr:2.6.5.5623@sha256:6152751c3ea2e7751564f5952173d5e83eed0e09f3fabd2cb6bdb58690c39e2f`
  - `ghcr.io/home-operations/sonarr:4.0.20.3012@sha256:1f19eb5e0f421418c1a956bbe01310a0141423afe28bd9a4b1dcb8629ff2bce2`
  - `ghcr.io/home-operations/radarr:6.4.4.10685@sha256:be53998a2d39cfa3c3315b70c7509a6a1f2a10c3aee9337653efc9f4c970430e`
  - `ghcr.io/jellyfin/jellyfin:12.1@sha256:008ec8024bdaaa6f0a3f0de468e185633eeba9d67c56936e8dbf5ef6b8d6200f`
- **UID/GID 568** (TrueNAS `apps`) for every app container, the dataset owner, and `fsGroup`.
- **app-template runs every value through Helm `tpl`.** Any literal `{{…}}` a container needs (gluetun's `{{PORT}}`) must be written `{{ "{{PORT}}" }}`. The render test asserts the literal survives.
- **app-template names ConfigMaps `<release>-<key>`** (e.g. `qbittorrent-gluetun-auth`) and PVCs `<release>` for a single `config` item.
- **Storage:** `truenas-iscsi` for `/config` (RWO, `Prune=false`); the static PVC `media-data` (RWX NFS, `192.168.20.2:/mnt/IOPSicle/media`) for `/data`.
- **Gateway:** `traefik-gateway` in namespace `default`, hostnames `<app>.koutoulastha.dev`, covered by the existing wildcard cert — create no Certificate.
- **`severity` must be exactly `critical` or `warning`** — Alertmanager routes nothing else.
- **Prometheus selects rules and probes from all namespaces** (selectors open, namespace selectors default). Media rules/probes live in `media`.
- **Service ports:** qBittorrent 8080 (web/API), 8888 (gluetun HTTP proxy), 8000 (gluetun control); Prowlarr 9696; Sonarr 8989; Radarr 7878; Jellyfin 8096. Service names equal release names.
- **Repo URL:** `https://github.com/koutoulastha/home-lab.git`
- **User cluster commands assume a `devbox shell`** (it sets `KUBECONFIG` and provides mikefarah `yq`, used as `yq -p json`). Prometheus queries assume `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` is running in another shell.

## Review Focus

Inputs and conditions the spec implies but that are easy to get wrong; each has a test in the owning task.

1. **Tunnel drops mid-download** → no packet leaves via the home IP; qBittorrent and Prowlarr stall, then resume on reconnect. *Task 10 Step 6 (tunnel deleted → BLOCKED) and Step 7 (Cilium drops a gluetun-less pod).*
2. **Proton rotates the forwarded port / gluetun reconnects** → qBittorrent's listen port follows it. *Task 3 render assertion that `{{PORT}}` survives `tpl`; Task 10 Step 8 compares ports after a forced reconnect.*
3. **Browser on the LAN opens `qbittorrent.koutoulastha.dev`** → a login page, not the UI (the image's default whitelists RFC1918). *Task 3 render assertion on `AuthSubnetWhitelistEnabled=false`; Task 10 Step 4 unauthenticated `curl` expects 403.*
4. **An indexer request that ignores Prowlarr's proxy** → fails, does not go out directly. *Task 5 render assertion (no world egress); Task 11 Step 4 direct `curl` from the Prowlarr pod expects failure.*
5. **Dataset fills up** → alert at 85%, torrents error out at the 2 TiB quota, the pool (and every iSCSI volume) is unaffected. *Task 2 alert assertion; Task 9 Step 2 sets the quota and Step 6 confirms the alert expression returns a value.*

---

### Task 1: Feature branch and Argo CD OCI repository

Argo CD cannot pull a Helm chart from an OCI registry unless a repository Secret declares it with `enableOCI: "true"`. It contains no credentials (the registry is public), so it is committed as a plain Secret.

**Files:**
- Create: `infrastructure/cicd/argocd/repo-bjw-s-labs.yaml`
- Modify: `infrastructure/cicd/argocd/application.yaml` (the `include` glob)

**Interfaces:**
- Consumes: nothing.
- Produces: Argo CD can resolve `repoURL: ghcr.io/bjw-s-labs/helm`, `chart: app-template` — used by every app Application (Tasks 3, 5, 6, 7).

- [ ] **Step 1: Create the branch**

The spec and this plan arrive on `main` via the `docs/media-stack-spec` PR; merge that first so the feature branch carries them.

```bash
git switch main && git pull --ff-only && git switch -c feat/media-stack
```

- [ ] **Step 2: Write the failing check**

```bash
devbox run -- yq '.spec.source.directory.include' infrastructure/cicd/argocd/application.yaml
```
Expected: `{httproute.yaml}` — the repo Secret would not be synced.

- [ ] **Step 3: Create `infrastructure/cicd/argocd/repo-bjw-s-labs.yaml`**

```yaml
# Lets Argo CD pull Helm charts from bjw-s-labs' OCI registry (app-template,
# used by every apps/media Application). OCI Helm repositories must be
# declared with enableOCI; the registry is public, so no credentials — this
# Secret is safe to commit in plain text.
apiVersion: v1
kind: Secret
metadata:
  name: repo-bjw-s-labs
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: bjw-s-labs
  url: ghcr.io/bjw-s-labs/helm
  enableOCI: "true"
```

- [ ] **Step 4: Widen the include glob**

In `infrastructure/cicd/argocd/application.yaml` replace

```yaml
      include: '{httproute.yaml}'
```
with
```yaml
      include: '{httproute.yaml,repo-bjw-s-labs.yaml}'
```

- [ ] **Step 5: Verify**

```bash
devbox run -- yq '.spec.source.directory.include' infrastructure/cicd/argocd/application.yaml
devbox run -- yq '.metadata.namespace + " " + .metadata.labels["argocd.argoproj.io/secret-type"] + " " + .stringData.enableOCI' infrastructure/cicd/argocd/repo-bjw-s-labs.yaml
```
Expected: `{httproute.yaml,repo-bjw-s-labs.yaml}` and `argocd repository true`.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/cicd/argocd/
git commit -m "feat(argocd): register bjw-s-labs OCI Helm repository"
```

---

### Task 2: Render test harness and `media-storage`

**Files:**
- Create: `apps/media/tests/render-test.sh` (final content below — it already contains every app's test function; later tasks make them pass)
- Create: `apps/media/storage/application.yaml`, `apps/media/storage/pv.yaml`, `apps/media/storage/pvc.yaml`, `apps/media/storage/alertrules.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: namespace `media` (PodSecurity `privileged`); PVC `media/media-data` (RWX) bound to PV `media-data`; `apps/media/tests/render-test.sh [app...]`, which runs `test_<dir>` for every `apps/media/<dir>` that exists (or the named ones) and exits non-zero on any failed assertion.

- [ ] **Step 1: Write the test harness**

Create `apps/media/tests/render-test.sh`:

```bash
#!/usr/bin/env bash
# Renders every media app through the exact app-template version its
# Application pins, and asserts the properties the design depends on.
# yq on values.yaml alone proves nothing — app-template decides what those
# keys turn into, so the assertions run against its output.
#
# Run from the repo root inside devbox (helm + yq-go):
#   devbox run -- bash apps/media/tests/render-test.sh [app...]
# With no arguments, tests every apps/media/<dir> that has a test_<dir>.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
MEDIA="$ROOT/apps/media"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FAILS=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n       expected: %s\n       got:      %s\n' "$1" "$2" "$3"; FAILS=$((FAILS + 1)); }

# eq <description> <file> <yq expression> <expected>
eq() {
  local got
  got=$(yq "$3" "$2" 2>&1 | grep -v '^---$' | sed '/^$/d' || true)
  if [[ "$got" == "$4" ]]; then pass "$1"; else fail "$1" "$4" "$got"; fi
}

# contains <description> <file> <yq expression> <substring>
contains() {
  local got
  got=$(yq "$3" "$2" 2>&1 || true)
  if [[ "$got" == *"$4"* ]]; then pass "$1"; else fail "$1" "…$4…" "$got"; fi
}

# render <app> -> path of rendered manifest stream
render() {
  local app=$1 version
  version=$(yq '.spec.sources[] | select(.chart == "app-template") | .targetRevision' "$MEDIA/$app/application.yaml")
  helm template "$app" oci://ghcr.io/bjw-s-labs/helm/app-template \
    --version "$version" --namespace media \
    --values "$MEDIA/$app/values.yaml" \
    --api-versions gateway.networking.k8s.io/v1/HTTPRoute \
    > "$OUT/$app.yaml" 2> "$OUT/$app.err" || { cat "$OUT/$app.err" >&2; return 1; }
  echo "$OUT/$app.yaml"
}

# Shared by every app: the invariants from the spec's Decisions table.
common_checks() {
  local app=$1 f=$2 port=$3 container=$4
  local dep='select(.kind == "Deployment")'
  local c=".spec.template.spec.containers[] | select(.name == \"$container\")"
  eq "$app: Recreate strategy"            "$f" "$dep | .spec.strategy.type" "Recreate"
  eq "$app: runs as 568"                  "$f" "$dep | $c | .securityContext.runAsUser" "568"
  eq "$app: fsGroup 568"                  "$f" "$dep | .spec.template.spec.securityContext.fsGroup" "568"
  eq "$app: config PVC on truenas-iscsi"  "$f" 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName' "truenas-iscsi"
  eq "$app: config PVC never pruned"      "$f" 'select(.kind == "PersistentVolumeClaim") | .metadata.annotations["argocd.argoproj.io/sync-options"]' "Prune=false"
  eq "$app: HTTPRoute is gateway v1"      "$f" 'select(.kind == "HTTPRoute") | .apiVersion' "gateway.networking.k8s.io/v1"
  eq "$app: HTTPRoute hostname"           "$f" 'select(.kind == "HTTPRoute") | .spec.hostnames[0]' "$app.koutoulastha.dev"
  eq "$app: HTTPRoute -> traefik-gateway" "$f" 'select(.kind == "HTTPRoute") | .spec.parentRefs[0].name' "traefik-gateway"
  eq "$app: HTTPRoute backend port"       "$f" 'select(.kind == "HTTPRoute") | .spec.rules[0].backendRefs[0].port' "$port"
  eq "$app: Service name"                 "$f" 'select(.kind == "Service") | .metadata.name' "$app"
}

test_qbittorrent() {
  local f; f=$(render qbittorrent)
  local dep='select(.kind == "Deployment")'
  local g='.spec.template.spec.initContainers[] | select(.name == "gluetun")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  common_checks qbittorrent "$f" 8080 app
  eq "gluetun is a native sidecar"          "$f" "$dep | $g | .restartPolicy" "Always"
  eq "gluetun has NET_ADMIN"                "$f" "$dep | $g | .securityContext.capabilities.add[0]" "NET_ADMIN"
  eq "pod DNS is gluetun only"              "$f" "$dep | .spec.template.spec.dnsPolicy" "None"
  eq "pod nameserver 127.0.0.1"             "$f" "$dep | .spec.template.spec.dnsConfig.nameservers[0]" "127.0.0.1"
  eq "gluetun: proton"                      "$f" "$dep | $g | .env[] | select(.name == \"VPN_SERVICE_PROVIDER\") | .value" "protonvpn"
  eq "gluetun: wireguard"                   "$f" "$dep | $g | .env[] | select(.name == \"VPN_TYPE\") | .value" "wireguard"
  eq "gluetun: P2P port-forward servers"    "$f" "$dep | $g | .env[] | select(.name == \"PORT_FORWARD_ONLY\") | .value" "on"
  eq "gluetun: firewall input ports"        "$f" "$dep | $g | .env[] | select(.name == \"FIREWALL_INPUT_PORTS\") | .value" "8080,8888,8000,9999"
  eq "gluetun: health server off localhost" "$f" "$dep | $g | .env[] | select(.name == \"HEALTH_SERVER_ADDRESS\") | .value" ":9999"
  eq "gluetun: key from secret"             "$f" "$dep | $g | .envFrom[0].secretRef.name" "gluetun-proton"
  # Survived Helm's tpl pass as literal gluetun placeholders:
  contains "up-command keeps {{PORT}}"      "$f" "$dep | $g | .env[] | select(.name == \"VPN_PORT_FORWARDING_UP_COMMAND\") | .value" '"listen_port\":{{PORT}}'
  contains "up-command keeps {{VPN_INTERFACE}}" "$f" "$dep | $g | .env[] | select(.name == \"VPN_PORT_FORWARDING_UP_COMMAND\") | .value" '{{VPN_INTERFACE}}'
  eq "gluetun readiness on :9999"           "$f" "$dep | $g | .readinessProbe.httpGet.port" "9999"
  eq "qbittorrent: read-only root"          "$f" "$dep | $a | .securityContext.readOnlyRootFilesystem" "true"
  eq "qbittorrent: /data is media-data"     "$f" "$dep | .spec.template.spec.volumes[] | select(.name == \"data\") | .persistentVolumeClaim.claimName" "media-data"
  eq "qbittorrent: /data mounted whole"     "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data\") | has(\"subPath\")" "false"
  eq "qbittorrent: defaults mounted"        "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/defaults/qBittorrent.conf\") | .subPath" "qBittorrent.conf"
  local conf='select(.kind == "ConfigMap" and .metadata.name == "qbittorrent-qbittorrent-defaults") | .data["qBittorrent.conf"]'
  contains "conf: no RFC1918 auth bypass"   "$f" "$conf" 'WebUI\AuthSubnetWhitelistEnabled=false'
  contains "conf: localhost bypass (gluetun)" "$f" "$conf" 'WebUI\LocalHostAuth=false'
  contains "conf: bound to tun0"            "$f" "$conf" 'Session\Interface=tun0'
  contains "conf: incomplete dir"           "$f" "$conf" 'Session\TempPath=/data/torrents/incomplete'
  contains "gluetun auth: portforward only" "$f" 'select(.kind == "ConfigMap" and .metadata.name == "qbittorrent-gluetun-auth") | .data["config.toml"]' 'routes = ["GET /v1/portforward"]'
  eq "gluetun auth mounted"                 "$f" "$dep | $g | .volumeMounts[] | select(.mountPath == \"/gluetun/auth/config.toml\") | .subPath" "config.toml"
  eq "Service exposes proxy 8888"           "$f" 'select(.kind == "Service") | .spec.ports[] | select(.name == "proxy") | .port' "8888"
  eq "Service exposes control 8000"         "$f" 'select(.kind == "Service") | .spec.ports[] | select(.name == "control") | .port' "8000"
  local np="$MEDIA/qbittorrent/networkpolicy.yaml"
  eq "CNP: selects qbittorrent"             "$np" '.spec.endpointSelector.matchLabels["app.kubernetes.io/name"]' "qbittorrent"
  eq "CNP: exactly one egress rule"         "$np" '.spec.egress | length' "1"
  eq "CNP: egress only to world"            "$np" '.spec.egress[0].toEntities[0]' "world"
  eq "CNP: egress only UDP 51820"           "$np" '.spec.egress[0].toPorts[0].ports[0].port + "/" + .spec.egress[0].toPorts[0].ports[0].protocol' "51820/UDP"
  eq "CNP: proxy only from prowlarr"        "$np" '.spec.ingress[] | select(.toPorts[0].ports[0].port == "8888") | .fromEndpoints[0].matchLabels["app.kubernetes.io/name"]' "prowlarr"
}

arr_checks() {
  local app=$1 port=$2 f; f=$(render "$app")
  local dep='select(.kind == "Deployment")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  local upper; upper=$(tr '[:lower:]' '[:upper:]' <<< "$app")
  common_checks "$app" "$f" "$port" app
  eq "$app: read-only root"               "$f" "$dep | $a | .securityContext.readOnlyRootFilesystem" "true"
  eq "$app: probes /ping"                 "$f" "$dep | $a | .readinessProbe.httpGet.path" "/ping"
  eq "$app: probe port"                   "$f" "$dep | $a | .readinessProbe.httpGet.port" "$port"
  eq "$app: forms auth"                   "$f" "$dep | $a | .env[] | select(.name == \"${upper}__AUTH__METHOD\") | .value" "Forms"
  eq "$app: auth required"                "$f" "$dep | $a | .env[] | select(.name == \"${upper}__AUTH__REQUIRED\") | .value" "Enabled"
  eq "$app: API key from secret"          "$f" "$dep | $a | .envFrom[0].secretRef.name" "$app-secret"
}

test_sonarr() {
  arr_checks sonarr 8989
  local f="$OUT/sonarr.yaml" a='select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app")'
  eq "sonarr: /data mounted whole" "$f" "$a | .volumeMounts[] | select(.mountPath == \"/data\") | has(\"subPath\")" "false"
}

test_radarr() {
  arr_checks radarr 7878
  local f="$OUT/radarr.yaml" a='select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app")'
  eq "radarr: /data mounted whole" "$f" "$a | .volumeMounts[] | select(.mountPath == \"/data\") | has(\"subPath\")" "false"
}

test_prowlarr() {
  arr_checks prowlarr 9696
  local f="$OUT/prowlarr.yaml" a='select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app")'
  # Empty output = no container mounts anything at exactly /data.
  eq "prowlarr: no whole /data"          "$f" "$a | .volumeMounts[] | select(.mountPath == \"/data\") | .mountPath" ""
  local np="$MEDIA/prowlarr/networkpolicy.yaml"
  eq "prowlarr CNP: no world egress"     "$np" '[.spec.egress[] | select(has("toEntities") or has("toCIDR") or has("toCIDRSet") or has("toFQDNs"))] | length' "0"
  eq "prowlarr CNP: may reach the proxy" "$np" '.spec.egress[] | select(.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "qbittorrent") | .toPorts[0].ports[0].port' "8888"
  eq "prowlarr: backups subPath only"    "$f" "$a | .volumeMounts[] | select(.mountPath == \"/data/backups/prowlarr\") | .subPath" "backups/prowlarr"
}

test_jellyfin() {
  local f; f=$(render jellyfin)
  local dep='select(.kind == "Deployment")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  common_checks jellyfin "$f" 8096 app
  eq "jellyfin: probes /health"          "$f" "$dep | $a | .readinessProbe.httpGet.path" "/health"
  eq "jellyfin: library read-only"       "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data/media\") | .readOnly" "true"
  eq "jellyfin: library is media/ only"  "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data/media\") | .subPath" "media"
  eq "jellyfin: backups over /config/backups" "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/config/backups\") | .subPath" "backups/jellyfin"
  eq "jellyfin: cache capped"            "$f" "$dep | .spec.template.spec.volumes[] | select(.name == \"cache\") | .emptyDir.sizeLimit" "20Gi"
}

test_storage() {
  local d="$MEDIA/storage"
  eq "PV: Retain"                     "$d/pv.yaml" '.spec.persistentVolumeReclaimPolicy' "Retain"
  eq "PV: pinned to media/media-data" "$d/pv.yaml" '.spec.claimRef.namespace + "/" + .spec.claimRef.name' "media/media-data"
  eq "PV: TrueNAS NFS server"         "$d/pv.yaml" '.spec.nfs.server' "192.168.20.2"
  eq "PV: IOPSicle/media export"      "$d/pv.yaml" '.spec.nfs.path' "/mnt/IOPSicle/media"
  eq "PV: no StorageClass"            "$d/pv.yaml" '.spec.storageClassName' ""
  eq "PV: RWX"                        "$d/pv.yaml" '.spec.accessModes[0]' "ReadWriteMany"
  eq "PVC: binds the PV by name"      "$d/pvc.yaml" '.spec.volumeName' "media-data"
  eq "PVC: never pruned"              "$d/pvc.yaml" '.metadata.annotations["argocd.argoproj.io/sync-options"]' "Prune=false"
  eq "App: prune disabled"            "$d/application.yaml" '.spec.syncPolicy.automated.prune' "false"
  eq "App: namespace is privileged"   "$d/application.yaml" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]' "privileged"
  eq "App: creates the namespace"     "$d/application.yaml" '.spec.syncPolicy.syncOptions[0]' "CreateNamespace=true"
  contains "Alert: watches IOPSicle/media" "$d/alertrules.yaml" '.spec.groups[0].rules[0].expr' 'dataset="IOPSicle/media"'
}

apps=("$@")
if [[ ${#apps[@]} -eq 0 ]]; then
  # Every app directory that exists so far and has a test_ function here.
  for d in "$MEDIA"/*/; do
    name=$(basename "$d")
    declare -F "test_$name" > /dev/null && apps+=("$name")
  done
fi

for app in "${apps[@]}"; do
  echo "== $app"
  "test_$app"
done

if (( FAILS > 0 )); then
  echo "$FAILS assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
```

```bash
chmod +x apps/media/tests/render-test.sh
```

- [ ] **Step 2: Run it to see it fail**

```bash
devbox run -- bash apps/media/tests/render-test.sh storage
```
Expected: FAIL on every `PV:`/`PVC:`/`App:`/`Alert:` line (files missing), exit 1.

- [ ] **Step 3: Create `apps/media/storage/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: media-storage
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  source:
    repoURL: https://github.com/koutoulastha/home-lab.git
    targetRevision: main
    path: apps/media/storage
    directory:
      exclude: application.yaml
  syncPolicy:
    automated:
      # Never prune: this Application holds the media library's PV/PVC. A
      # file deleted from git must not become a deleted library.
      prune: false
      selfHeal: true
    # This Application owns the `media` namespace and its metadata; the app
    # Applications do not set CreateNamespace, so they cannot contend over it.
    # privileged: gluetun needs NET_ADMIN, which the cluster-default
    # `baseline` Pod Security Standard rejects.
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Create `apps/media/storage/pv.yaml`**

```yaml
# The media library: TrueNAS dataset IOPSicle/media over NFS, statically
# bound. Created by hand on TrueNAS (see apps/media/README.md), not by
# democratic-csi — its lifecycle must not depend on the cluster's.
#
# Retain + claimRef: only media/media-data can bind this, and deleting that
# claim leaves the PV (and the data) in place.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-data
spec:
  capacity:
    storage: 2Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: media
    name: media-data
  mountOptions:
    - nfsvers=4.1
    - hard
  nfs:
    server: 192.168.20.2
    path: /mnt/IOPSicle/media
```

- [ ] **Step 5: Create `apps/media/storage/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-data
  namespace: media
  annotations:
    # Second guard after the Application's prune: false.
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: media-data
  resources:
    requests:
      storage: 2Ti
```

- [ ] **Step 6: Create `apps/media/storage/alertrules.yaml`**

```yaml
# IOPSicle/media has a 2 TiB ZFS quota because the pool is shared with every
# iSCSI zvol in the cluster. At the quota, qBittorrent's writes fail and the
# affected torrents error out — safe for the pool, but downloads stop. These
# warn well before that. The warning stops at 95% so the two do not both
# notify once the critical one fires.
#
# Metrics from truenas-exporter (ENABLE_DATASET_METRICS=true); the `dataset`
# label value is the full dataset name. quota_bytes > 0 guards against the
# quota having been removed, which would otherwise divide by zero silently.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: media-storage
  namespace: media
spec:
  groups:
    - name: media-storage.rules
      rules:
        - alert: MediaDatasetFilling
          expr: |
            truenas_dataset_used_bytes{dataset="IOPSicle/media"}
              / (truenas_dataset_quota_bytes{dataset="IOPSicle/media"} > 0)
              > 0.85 <= 0.95
          for: 15m
          labels:
            severity: warning
          annotations:
            description: >-
              IOPSicle/media is {{ $value | humanizePercentage }} of its quota.
              Delete watched media or raise the quota (and check the pool has
              room for it — the iSCSI volumes share it).
        - alert: MediaDatasetFilling
          expr: |
            truenas_dataset_used_bytes{dataset="IOPSicle/media"}
              / (truenas_dataset_quota_bytes{dataset="IOPSicle/media"} > 0)
              > 0.95
          for: 15m
          labels:
            severity: critical
          annotations:
            description: >-
              IOPSicle/media is {{ $value | humanizePercentage }} of its quota;
              downloads will start failing. Free space now.
```

- [ ] **Step 7: Run the test to see it pass**

```bash
devbox run -- bash apps/media/tests/render-test.sh storage
```
Expected: 12 `ok` lines, `all assertions passed`.

- [ ] **Step 8: Commit**

```bash
git add apps/media/tests apps/media/storage
git commit -m "feat(media): storage foundation and render test harness"
```

---

### Task 3: qBittorrent + gluetun

**Files:**
- Create: `apps/media/qbittorrent/application.yaml`, `apps/media/qbittorrent/values.yaml`, `apps/media/qbittorrent/networkpolicy.yaml`
- Create (user): `apps/media/qbittorrent/sealed-secret.yaml`

**Interfaces:**
- Consumes: PVC `media-data`, namespace `media` (Task 2); OCI repo (Task 1).
- Produces: Service `qbittorrent.media.svc` with ports `http` 8080, `proxy` 8888, `control` 8000; pod label `app.kubernetes.io/name: qbittorrent`; container `gluetun` (its readiness = tunnel health) — consumed by Tasks 4, 5, 6.

- [ ] **Step 1: Run the test to see it fail**

```bash
devbox run -- bash apps/media/tests/render-test.sh qbittorrent
```
Expected: exit non-zero — `application.yaml` does not exist, so `render` cannot read the chart version.

- [ ] **Step 2: Create `apps/media/qbittorrent/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: qbittorrent
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
        releaseName: qbittorrent
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/qbittorrent/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe, alert rules).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/qbittorrent
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 3: Create `apps/media/qbittorrent/values.yaml`**

```yaml
# qBittorrent with a gluetun (Proton VPN, WireGuard) sidecar. Values for
# bjw-s app-template 5.2.1 — keys checked against that chart version's
# templates by apps/media/tests/render-test.sh, not assumed.
#
# Three layers keep torrent traffic off the home IP:
#   1. gluetun's firewall (in-pod iptables kill switch),
#   2. qBittorrent bound to tun0 (Session\Interface in the defaults below),
#   3. networkpolicy.yaml — Cilium lets this pod reach the world on UDP 51820
#      (the WireGuard handshake) and nothing else.
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  qbittorrent:
    strategy: Recreate
    pod:
      # Every container in the pod resolves through gluetun's DNS server on
      # 127.0.0.1 (DNS over TLS, inside the tunnel). Cluster DNS would be
      # unreachable anyway — gluetun's firewall blocks non-tunnel egress — so
      # without this qBittorrent could not resolve tracker hostnames. It also
      # means DNS cannot leak.
      dnsPolicy: None
      dnsConfig:
        nameservers: [127.0.0.1]
    initContainers:
      # Native sidecar (restartPolicy: Always): starts, and must pass its
      # startup probe, before qBittorrent starts; keeps running alongside it.
      gluetun:
        image:
          repository: ghcr.io/qdm12/gluetun
          tag: v3.41.3@sha256:fa19cc76b2af13d57a8d3dc3066f2ada061b1c761b8aecf989b3877c0486e027
        restartPolicy: Always
        env:
          VPN_SERVICE_PROVIDER: protonvpn
          VPN_TYPE: wireguard
          # P2P servers only, with NAT-PMP port forwarding.
          VPN_PORT_FORWARDING: "on"
          PORT_FORWARD_ONLY: "on"
          # Southern/central Europe, nearest first in spirit. Every name must
          # match gluetun's bundled server list exactly — an unknown country
          # stops gluetun at startup. With PORT_FORWARD_ONLY these cover ~60
          # Proton WireGuard servers (v3.41.3 data); Greece alone has one.
          SERVER_COUNTRIES: Greece,Italy,Bulgaria,Cyprus,Romania,Albania,Serbia,Croatia,Slovenia,Hungary,Austria,Czech Republic,Germany,Switzerland,Netherlands
          # Push each (re)assigned forwarded port into qBittorrent. Relies on
          # qBittorrent's localhost auth bypass (WebUI\LocalHostAuth=false).
          # The DOWN command resets the port — qBittorrent otherwise fails to
          # rebind after a reconnect (gluetun wiki, qBittorrent example).
          # {{ "{{PORT}}" }} is Helm-escaped: app-template runs every value
          # through `tpl`, and gluetun needs the literal {{PORT}} placeholder.
          VPN_PORT_FORWARDING_UP_COMMAND: >-
            /bin/sh -c 'wget -O- -nv --retry-connrefused --post-data
            "json={\"listen_port\":{{ "{{PORT}}" }},\"current_network_interface\":\"{{ "{{VPN_INTERFACE}}" }}\",\"random_port\":false,\"upnp\":false}"
            http://127.0.0.1:8080/api/v2/app/setPreferences'
          VPN_PORT_FORWARDING_DOWN_COMMAND: >-
            /bin/sh -c 'wget -O- -nv --retry-connrefused --post-data
            "json={\"listen_port\":0,\"current_network_interface\":\"lo\"}"
            http://127.0.0.1:8080/api/v2/app/setPreferences'
          # HTTP proxy for Prowlarr's indexer traffic (exits via the tunnel).
          HTTPPROXY: "on"
          # Ports reachable on eth0 through gluetun's firewall: web UI,
          # proxy, control server (blackbox probe), health server (kubelet).
          FIREWALL_INPUT_PORTS: "8080,8888,8000,9999"
          # Default is 127.0.0.1:9999, which kubelet cannot reach.
          HEALTH_SERVER_ADDRESS: ":9999"
        envFrom:
          - secretRef:
              name: gluetun-proton
        probes:
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /, port: 9999}
              periodSeconds: 5
              failureThreshold: 36  # 3 minutes to establish the tunnel
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /, port: 9999}
              periodSeconds: 10
              failureThreshold: 3
          liveness:
            # gluetun heals the tunnel internally (HEALTH_RESTART_VPN). The
            # kubelet only restarts it if that has failed for 5 minutes.
            enabled: true
            custom: true
            spec:
              httpGet: {path: /, port: 9999}
              periodSeconds: 30
              failureThreshold: 10
        securityContext:
          capabilities:
            add: [NET_ADMIN]
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/qbittorrent
          tag: 5.2.4@sha256:9307627e03981d5473aa31175ea76ed56ea3752333ca49d601b6af45e281e7ba
        probes:
          # TCP on the web UI port: every qBittorrent HTTP endpoint other
          # than the login page needs auth, so an httpGet would see 403.
          liveness: &tcp
            enabled: true
            custom: true
            spec:
              tcpSocket: {port: 8080}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *tcp
        securityContext:
          runAsUser: 568
          runAsGroup: 568
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}

service:
  app:
    controller: qbittorrent
    ports:
      http:
        primary: true
        port: 8080
      proxy:
        port: 8888
      control:
        port: 8000

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [qbittorrent.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 8080

configMaps:
  gluetun-auth:
    data:
      # Every control-server route requires auth since gluetun v3.39.1. The
      # blackbox probe needs exactly one read-only route, unauthenticated;
      # networkpolicy.yaml limits port 8000 to blackbox-exporter.
      config.toml: |
        [[roles]]
        name = "blackbox"
        routes = ["GET /v1/portforward"]
        auth = "none"
  qbittorrent-defaults:
    data:
      # The image copies /defaults/qBittorrent.conf into /config only when no
      # config exists yet, so this seeds the first start and is ignored after.
      # Upstream's defaults, except:
      #   - AuthSubnetWhitelistEnabled=false: upstream whitelists all of
      #     RFC1918, which here means no login at all (Traefik and the LAN
      #     are both private addresses).
      #   - Session\Interface=tun0: bind torrent traffic to the tunnel.
      #   - save paths under /data/torrents; automatic torrent management on,
      #     so an *arr category "tv" saves to /data/torrents/tv.
      qBittorrent.conf: |
        [AutoRun]
        enabled=false
        program=

        [LegalNotice]
        Accepted=true

        [BitTorrent]
        Session\AsyncIOThreadsCount=10
        Session\DefaultSavePath=/data/torrents
        Session\DisableAutoTMMByDefault=false
        Session\DiskCacheSize=-1
        Session\DiskIOReadMode=DisableOSCache
        Session\DiskIOType=SimplePreadPwrite
        Session\DiskIOWriteMode=EnableOSCache
        Session\DiskQueueSize=4194304
        Session\FilePoolSize=40
        Session\HashingThreadsCount=2
        Session\Interface=tun0
        Session\InterfaceName=tun0
        Session\Port=50413
        Session\ResumeDataStorageType=SQLite
        Session\TempPath=/data/torrents/incomplete
        Session\TempPathEnabled=true
        Session\UseOSCache=true

        [Preferences]
        Connection\PortRangeMin=6881
        Connection\UPnP=false
        General\Locale=en
        General\UseRandomPort=false
        WebUI\Address=*
        WebUI\AuthSubnetWhitelistEnabled=false
        WebUI\CSRFProtection=false
        WebUI\HostHeaderValidation=false
        WebUI\LocalHostAuth=false
        WebUI\Port=8080
        WebUI\ServerDomains=*
        WebUI\UseUPnP=false

persistence:
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 1Gi
    annotations:
      # truenas-iscsi reclaimPolicy is Delete: a pruned PVC takes its zvol.
      argocd.argoproj.io/sync-options: Prune=false
    advancedMounts:
      qbittorrent:
        app:
          - path: /config
  data:
    existingClaim: media-data
    advancedMounts:
      qbittorrent:
        app:
          - path: /data
  tmp:
    type: emptyDir
    advancedMounts:
      qbittorrent:
        app:
          - path: /tmp
  defaults:
    type: configMap
    identifier: qbittorrent-defaults
    advancedMounts:
      qbittorrent:
        app:
          - path: /defaults/qBittorrent.conf
            subPath: qBittorrent.conf
            readOnly: true
  gluetun-auth:
    type: configMap
    identifier: gluetun-auth
    advancedMounts:
      qbittorrent:
        gluetun:
          - path: /gluetun/auth/config.toml
            subPath: config.toml
            readOnly: true
```

- [ ] **Step 4: Create `apps/media/qbittorrent/networkpolicy.yaml`**

```yaml
# Cluster-level kill switch for the qBittorrent pod, underneath gluetun's own
# firewall. If gluetun ever let a packet out of eth0 that was not WireGuard,
# Cilium drops it here.
#
# Egress: the world on UDP 51820 only (Proton's WireGuard port; gluetun
# connects by IP from its bundled server list, so no DNS is needed before the
# tunnel is up). DNS for the pod goes to gluetun on 127.0.0.1, which no
# policy governs. Nothing else — not even cluster DNS.
#
# Ingress, per port:
#   8080  web UI/API   — Traefik (the LAN route) and Sonarr/Radarr
#   8888  HTTP proxy   — Prowlarr only
#   8000  control srv  — blackbox-exporter only (port-forward probe)
#   9999  health srv   — the node (kubelet probes)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: qbittorrent
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: qbittorrent
  egress:
    - toEntities: [world]
      toPorts:
        - ports:
            - port: "51820"
              protocol: UDP
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: traefik
            app.kubernetes.io/name: traefik
        - matchExpressions:
            - key: app.kubernetes.io/name
              operator: In
              values: [sonarr, radarr]
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: prowlarr
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus-blackbox-exporter
      toPorts:
        - ports:
            - port: "8000"
              protocol: TCP
    - fromEntities: [host]
      toPorts:
        - ports:
            - port: "9999"
              protocol: TCP
```

- [ ] **Step 5: Run the test to see it pass**

```bash
devbox run -- bash apps/media/tests/render-test.sh qbittorrent
```
Expected: 40 `ok` lines, `all assertions passed`.

- [ ] **Step 6: Prove the test catches the two worst regressions**

```bash
cp apps/media/qbittorrent/values.yaml /tmp/qbt-values.bak
sed -i 's/{{ "{{PORT}}" }}/{{PORT}}/; s/AuthSubnetWhitelistEnabled=false/AuthSubnetWhitelistEnabled=true/' apps/media/qbittorrent/values.yaml
devbox run -- bash apps/media/tests/render-test.sh qbittorrent; echo "exit=$?"
cp /tmp/qbt-values.bak apps/media/qbittorrent/values.yaml
devbox run -- bash apps/media/tests/render-test.sh qbittorrent | tail -1
```
Expected: first run fails — Helm itself errors with `function "PORT" not defined` (unescaped placeholder), `exit=1`; after restoring, `all assertions passed`.

- [ ] **Step 7 (user): Generate the Proton WireGuard key and seal it**

In the Proton account: *Downloads → WireGuard configuration* → platform **Router**, enable **NAT-PMP (Port Forwarding)**, pick any P2P server, **Create**. Copy the `PrivateKey` value only (it works for every Proton server). Then:

```bash
read -rsp 'Proton WireGuard PrivateKey: ' KEY; echo
kubectl create secret generic gluetun-proton \
  --namespace media \
  --from-literal=WIREGUARD_PRIVATE_KEY="$KEY" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > apps/media/qbittorrent/sealed-secret.yaml
unset KEY
grep -c 'encryptedData' apps/media/qbittorrent/sealed-secret.yaml   # expect: 1
grep -c 'WIREGUARD_PRIVATE_KEY:' apps/media/qbittorrent/sealed-secret.yaml  # expect: 1 (key name only, value encrypted)
```

`--dry-run=client` does not need the `media` namespace to exist; the sealed secret is scoped to it.

- [ ] **Step 8: Commit**

```bash
git add apps/media/qbittorrent
git commit -m "feat(media): qBittorrent behind a gluetun Proton VPN sidecar"
```

---

### Task 4: VPN monitoring

**Files:**
- Create: `apps/media/qbittorrent/probe.yaml`, `apps/media/qbittorrent/alertrules.yaml`
- Modify: `infrastructure/monitoring/blackbox-exporter/values.yaml` (append a module)
- Modify: `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml` (`BlackboxProbeFailed` expr)

**Interfaces:**
- Consumes: Service `qbittorrent.media.svc:8000` and container name `gluetun` (Task 3).
- Produces: alerts `QbittorrentVpnDown`, `QbittorrentPortForwardLost`; blackbox module `http_gluetun_portforward`; Probe job `probe/media/qbittorrent-portforward` with label `path="vpn-portforward"`.

- [ ] **Step 1: Write the failing check**

```bash
devbox run -- yq '.config.modules | has("http_gluetun_portforward")' infrastructure/monitoring/blackbox-exporter/values.yaml
devbox run -- yq '.spec.groups[].rules[] | select(.alert == "BlackboxProbeFailed") | .expr' infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
```
Expected: `false`, and `probe_success == 0` (would also page critical for the port-forward probe).

- [ ] **Step 2: Create `apps/media/qbittorrent/probe.yaml`**

```yaml
# Is Proton still forwarding a port to us? gluetun's control server answers
# {"port":N}; N=0 means forwarding is lost, which leaves torrents running but
# unreachable by peers (slow downloads, near-zero seeding). The module fails
# on anything but a non-zero port.
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: qbittorrent-portforward
  namespace: media
spec:
  interval: 60s
  module: http_gluetun_portforward
  prober:
    url: blackbox-exporter.monitoring.svc.cluster.local:9115
  targets:
    staticConfig:
      static:
        - http://qbittorrent.media.svc.cluster.local:8000/v1/portforward
      labels:
        path: vpn-portforward
```

- [ ] **Step 3: Create `apps/media/qbittorrent/alertrules.yaml`**

```yaml
# VPN health for the qBittorrent pod.
#
# `severity` must stay within {critical, warning} — Alertmanager routes only
# those. Both are warnings: a dead tunnel stops torrents (fails closed), it
# does not leak, so nothing here is urgent in the middle of the night.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: media-vpn
  namespace: media
spec:
  groups:
    - name: media-vpn.rules
      rules:
        # gluetun's readiness probe is its health server: not ready means the
        # tunnel is down and gluetun's own auto-heal has not fixed it.
        # gluetun is a native sidecar, i.e. an INIT container: kube-state-
        # metrics reports it under kube_pod_init_container_status_ready, and
        # kube_pod_container_status_ready never has a gluetun series.
        - alert: QbittorrentVpnDown
          expr: |
            kube_pod_init_container_status_ready{namespace="media", container="gluetun"} == 0
          for: 10m
          labels:
            severity: warning
          annotations:
            description: >-
              gluetun in {{ $labels.pod }} has been not-ready for 10 minutes:
              the Proton tunnel is down, so qBittorrent and Prowlarr's indexer
              searches are stopped (by design — they fail closed). Check
              `kubectl -n media logs {{ $labels.pod }} -c gluetun`; an expired
              or revoked WireGuard key is the most common cause.

        # Suppressed while the VPN itself is down — that alert explains this.
        - alert: QbittorrentPortForwardLost
          expr: |
            probe_success{job="probe/media/qbittorrent-portforward"} == 0
            unless on()
            (kube_pod_init_container_status_ready{namespace="media", container="gluetun"} == 0)
          for: 15m
          labels:
            severity: warning
          annotations:
            description: >-
              Proton has not forwarded a port for 15 minutes while the tunnel
              is up. Torrents still run but peers cannot connect in. Check the
              gluetun logs for port forwarding errors; restarting the pod
              picks a new P2P server.
```

- [ ] **Step 4: Append the module to `infrastructure/monitoring/blackbox-exporter/values.yaml`**

After the last line of the `http_2xx_pangolin` module (`          server_name: traefik.koutoulastha.dev`), append at the same indentation as `http_2xx_pangolin:`:

```yaml

    # gluetun's control server: {"port":N} with N > 0 while Proton forwards a
    # port. Fails on port 0 (forwarding lost) as well as on no answer. Used by
    # apps/media/qbittorrent/probe.yaml; route auth is opened for exactly this
    # GET in that app's gluetun-auth ConfigMap.
    http_gluetun_portforward:
      prober: http
      timeout: 5s
      http:
        valid_status_codes: [200]
        fail_if_body_not_matches_regexp:
          - '"port":[1-9]'
        preferred_ip_protocol: ip4
```

- [ ] **Step 5: Exclude the port-forward probe from the generic alert**

In `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml`, replace

```yaml
        - alert: BlackboxProbeFailed
          expr: probe_success == 0
```
with
```yaml
        # The VPN port-forward probe (path="vpn-portforward") has its own
        # warning-level alert, QbittorrentPortForwardLost in apps/media; a lost
        # forwarded port is not a critical outage.
        - alert: BlackboxProbeFailed
          expr: probe_success{path!="vpn-portforward"} == 0
```

- [ ] **Step 6: Verify**

```bash
devbox run -- yq '.config.modules.http_gluetun_portforward.http.fail_if_body_not_matches_regexp[0]' infrastructure/monitoring/blackbox-exporter/values.yaml
devbox run -- yq '.config.modules | keys | join(",")' infrastructure/monitoring/blackbox-exporter/values.yaml
devbox run -- yq '.spec.groups[].rules[] | select(.alert == "BlackboxProbeFailed") | .expr' infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
devbox run -- yq '.spec.module + " " + .spec.targets.staticConfig.labels.path' apps/media/qbittorrent/probe.yaml
devbox run -- yq '[.spec.groups[].rules[].labels.severity] | unique | join(",")' apps/media/qbittorrent/alertrules.yaml
grep -c 'kube_pod_init_container_status_ready{namespace="media", container="gluetun"}' apps/media/qbittorrent/alertrules.yaml
grep -c 'kube_pod_container_status_ready' apps/media/qbittorrent/alertrules.yaml
```
Expected: `"port":[1-9]`; `http_2xx,http_2xx_pangolin,http_gluetun_portforward`; `probe_success{path!="vpn-portforward"} == 0`; `http_gluetun_portforward vpn-portforward`; `warning`; `2`; `1` (only the comment explaining why the non-init metric is wrong — **no expression may use it**: gluetun is an init container and kube-state-metrics never reports it under `kube_pod_container_status_ready`).

- [ ] **Step 7: Commit**

```bash
git add apps/media/qbittorrent infrastructure/monitoring
git commit -m "feat(monitoring): alert on media VPN tunnel and port forwarding"
```

---

### Task 5: Prowlarr

**Files:**
- Create: `apps/media/prowlarr/application.yaml`, `apps/media/prowlarr/values.yaml`, `apps/media/prowlarr/networkpolicy.yaml`
- Create (user): `apps/media/prowlarr/sealed-secret.yaml`

**Interfaces:**
- Consumes: Service `qbittorrent.media.svc:8888` (Task 3); pod labels `app.kubernetes.io/name: sonarr|radarr` (Task 6).
- Produces: Service `prowlarr.media.svc:9696`; Secret `prowlarr-secret` with key `PROWLARR__AUTH__APIKEY`.

- [ ] **Step 1: Run the test to see it fail**

```bash
devbox run -- bash apps/media/tests/render-test.sh prowlarr
```
Expected: exit non-zero (`apps/media/prowlarr/application.yaml` missing).

- [ ] **Step 2: Create `apps/media/prowlarr/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prowlarr
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
        releaseName: prowlarr
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/prowlarr/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe, alert rules).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/prowlarr
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 3: Create `apps/media/prowlarr/values.yaml`**

```yaml
# Prowlarr. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Same shape as prowlarr/values.yaml, except /data (below).
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  prowlarr:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/prowlarr
          tag: 2.6.5.5623@sha256:6152751c3ea2e7751564f5952173d5e83eed0e09f3fabd2cb6bdb58690c39e2f
        env:
          PROWLARR__AUTH__METHOD: Forms
          PROWLARR__AUTH__REQUIRED: Enabled
        # PROWLARR__AUTH__APIKEY, from sealed-secret.yaml. Pre-seeding the key
        # is harmless here and keeps all three apps configured the same way.
        envFrom:
          - secretRef:
              name: prowlarr-secret
        probes:
          # /ping answers 200 without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 9696}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 9696}
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
    controller: prowlarr
    ports:
      http:
        port: 9696

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [prowlarr.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 9696

persistence:
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 5Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false
    globalMounts:
      - path: /config
  # Prowlarr never touches downloads or media; it only needs somewhere off
  # its own zvol to write scheduled backups. Same path as in Sonarr/Radarr.
  backups:
    existingClaim: media-data
    globalMounts:
      - path: /data/backups/prowlarr
        subPath: backups/prowlarr
  tmp:
    type: emptyDir
    globalMounts:
      - path: /tmp
```

- [ ] **Step 4: Create `apps/media/prowlarr/networkpolicy.yaml`**

```yaml
# Prowlarr reaches indexers only through gluetun's HTTP proxy. With no direct
# `world` egress, an indexer that bypasses the proxy fails instead of leaking
# the home IP.
#
# Egress-only: ingress stays default-allow (Traefik, and Sonarr/Radarr, which
# fetch Torznab results from Prowlarr on 9696).
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: prowlarr
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: prowlarr
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: qbittorrent
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: sonarr
      toPorts:
        - ports:
            - port: "8989"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: radarr
      toPorts:
        - ports:
            - port: "7878"
              protocol: TCP
```

- [ ] **Step 5: Run the test to see it pass**

```bash
devbox run -- bash apps/media/tests/render-test.sh prowlarr
```
Expected: 20 `ok` lines, `all assertions passed`.

- [ ] **Step 6 (user): Seal the API key**

```bash
kubectl create secret generic prowlarr-secret \
  --namespace media \
  --from-literal=PROWLARR__AUTH__APIKEY="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > apps/media/prowlarr/sealed-secret.yaml
grep -c 'encryptedData' apps/media/prowlarr/sealed-secret.yaml  # expect: 1
```
The key never needs to be known: Prowlarr pulls Sonarr's and Radarr's keys, not the other way round.

- [ ] **Step 7: Commit**

```bash
git add apps/media/prowlarr
git commit -m "feat(media): Prowlarr, indexer traffic via the VPN proxy only"
```

---

### Task 6: Sonarr and Radarr

**Files:**
- Create: `apps/media/sonarr/application.yaml`, `apps/media/sonarr/values.yaml`
- Create: `apps/media/radarr/application.yaml`, `apps/media/radarr/values.yaml`
- Create (user): `apps/media/sonarr/sealed-secret.yaml`, `apps/media/radarr/sealed-secret.yaml`

**Interfaces:**
- Consumes: PVC `media-data`; Service `qbittorrent.media.svc:8080`.
- Produces: Services `sonarr.media.svc:8989`, `radarr.media.svc:7878`; Secrets `sonarr-secret` (`SONARR__AUTH__APIKEY`), `radarr-secret` (`RADARR__AUTH__APIKEY`); API keys the user records for Task 11.

- [ ] **Step 1: Run the tests to see them fail**

```bash
devbox run -- bash apps/media/tests/render-test.sh sonarr radarr
```
Expected: exit non-zero (`application.yaml` missing).

- [ ] **Step 2: Create `apps/media/sonarr/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
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
        releaseName: sonarr
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/sonarr/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe, alert rules).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/sonarr
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 3: Create `apps/media/sonarr/values.yaml`**

```yaml
# Sonarr. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Radarr and Prowlarr are the same shape.
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  sonarr:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/sonarr
          tag: 4.0.20.3012@sha256:1f19eb5e0f421418c1a956bbe01310a0141423afe28bd9a4b1dcb8629ff2bce2
        env:
          SONARR__AUTH__METHOD: Forms
          SONARR__AUTH__REQUIRED: Enabled
        # SONARR__AUTH__APIKEY, from sealed-secret.yaml. Pre-seeding the key
        # means Prowlarr can be wired to Sonarr without copying it out of a UI.
        envFrom:
          - secretRef:
              name: sonarr-secret
        probes:
          # /ping answers 200 without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 8989}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 8989}
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
    controller: sonarr
    ports:
      http:
        port: 8989

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [sonarr.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 8989

persistence:
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 5Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false
    globalMounts:
      - path: /config
  # The whole volume at /data, same path as qBittorrent: no remote path
  # mappings, and imports are hardlinks because it is one filesystem.
  data:
    existingClaim: media-data
    globalMounts:
      - path: /data
  tmp:
    type: emptyDir
    globalMounts:
      - path: /tmp
```

- [ ] **Step 4: Create `apps/media/radarr/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: radarr
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
        releaseName: radarr
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/radarr/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe, alert rules).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/radarr
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 5: Create `apps/media/radarr/values.yaml`**

```yaml
# Radarr. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Same shape as sonarr/values.yaml.
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  radarr:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/radarr
          tag: 6.4.4.10685@sha256:be53998a2d39cfa3c3315b70c7509a6a1f2a10c3aee9337653efc9f4c970430e
        env:
          RADARR__AUTH__METHOD: Forms
          RADARR__AUTH__REQUIRED: Enabled
        # RADARR__AUTH__APIKEY, from sealed-secret.yaml. Pre-seeding the key
        # means Prowlarr can be wired to Radarr without copying it out of a UI.
        envFrom:
          - secretRef:
              name: radarr-secret
        probes:
          # /ping answers 200 without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 7878}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /ping, port: 7878}
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
    controller: radarr
    ports:
      http:
        port: 7878

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [radarr.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 7878

persistence:
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 5Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false
    globalMounts:
      - path: /config
  # The whole volume at /data, same path as qBittorrent: no remote path
  # mappings, and imports are hardlinks because it is one filesystem.
  data:
    existingClaim: media-data
    globalMounts:
      - path: /data
  tmp:
    type: emptyDir
    globalMounts:
      - path: /tmp
```

- [ ] **Step 6: Run the tests to see them pass**

```bash
devbox run -- bash apps/media/tests/render-test.sh sonarr radarr
```
Expected: 17 `ok` lines per app, `all assertions passed`.

- [ ] **Step 7 (user): Seal the API keys, keeping a copy for wiring**

```bash
for app in sonarr radarr; do
  key=$(openssl rand -hex 16)
  echo "$app API key: $key"   # store in your password manager; Task 11 pastes it into Prowlarr
  kubectl create secret generic "$app-secret" \
    --namespace media \
    --from-literal="${app^^}__AUTH__APIKEY=$key" \
    --dry-run=client -o yaml \
    | kubeseal --format yaml \
    > "apps/media/$app/sealed-secret.yaml"
  grep -c 'encryptedData' "apps/media/$app/sealed-secret.yaml"  # expect: 1
done
unset key
```

- [ ] **Step 8: Commit**

```bash
git add apps/media/sonarr apps/media/radarr
git commit -m "feat(media): Sonarr and Radarr"
```

---

### Task 7: Jellyfin

**Files:**
- Create: `apps/media/jellyfin/application.yaml`, `apps/media/jellyfin/values.yaml`, `apps/media/jellyfin/probe.yaml`
- Modify: `infrastructure/monitoring/blackbox-exporter/values.yaml` (append a module)

**Interfaces:**
- Consumes: PVC `media-data`.
- Produces: Service `jellyfin.media.svc:8096`; blackbox module `http_jellyfin_pangolin`; Probe job `probe/media/jellyfin-public` (covered by the existing `BlackboxProbeFailed`).

- [ ] **Step 1: Run the test to see it fail**

```bash
devbox run -- bash apps/media/tests/render-test.sh jellyfin
```
Expected: exit non-zero (`application.yaml` missing).

- [ ] **Step 2: Create `apps/media/jellyfin/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jellyfin
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
        releaseName: jellyfin
        valueFiles:
          # $values paths are always relative to the repo root.
          - $values/apps/media/jellyfin/values.yaml
    # Supplies the values file above, and renders this directory's plain
    # manifests (sealed secret, network policy, probe, alert rules).
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: apps/media/jellyfin
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # No CreateNamespace: media-storage owns the namespace and its Pod
    # Security label, and must be synced first.
```

- [ ] **Step 3: Create `apps/media/jellyfin/values.yaml`**

```yaml
# Jellyfin 12.1. Values for bjw-s app-template 5.2.1 (checked by
# apps/media/tests/render-test.sh). Direct play, CPU-only transcoding — no
# GPU is passed through to the Talos VMs.
defaultPodOptions:
  securityContext:
    fsGroup: 568
    fsGroupChangePolicy: OnRootMismatch

controllers:
  jellyfin:
    strategy: Recreate
    containers:
      app:
        image:
          repository: ghcr.io/jellyfin/jellyfin
          tag: 12.1@sha256:008ec8024bdaaa6f0a3f0de468e185633eeba9d67c56936e8dbf5ef6b8d6200f
        probes:
          # /health answers 200 "Healthy" without authentication.
          liveness: &probe
            enabled: true
            custom: true
            spec:
              httpGet: {path: /health, port: 8096}
              periodSeconds: 30
              failureThreshold: 5
          readiness: *probe
          startup:
            enabled: true
            custom: true
            spec:
              httpGet: {path: /health, port: 8096}
              periodSeconds: 5
              failureThreshold: 60
        # The image runs as root by default. Root filesystem stays writable:
        # Jellyfin/ffmpeg write outside the declared volumes (font cache etc.)
        # in ways not worth chasing for a service with no network privileges.
        securityContext:
          runAsUser: 568
          runAsGroup: 568
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          capabilities: {drop: [ALL]}

service:
  app:
    controller: jellyfin
    ports:
      http:
        port: 8096

route:
  app:
    parentRefs:
      - name: traefik-gateway
        namespace: default
    hostnames: [jellyfin.koutoulastha.dev]
    rules:
      - backendRefs:
          - identifier: app
            port: 8096

persistence:
  # JELLYFIN_DATA_DIR=/config in this image: database, metadata, images.
  config:
    type: persistentVolumeClaim
    storageClass: truenas-iscsi
    accessMode: ReadWriteOnce
    size: 20Gi
    annotations:
      argocd.argoproj.io/sync-options: Prune=false
    globalMounts:
      - path: /config
  # JELLYFIN_CACHE_DIR=/cache, plus transcodes (Jellyfin's default transcode
  # path lives under the cache dir). Capped: a runaway transcode evicts the
  # pod instead of filling the node's disk.
  cache:
    type: emptyDir
    sizeLimit: 20Gi
    globalMounts:
      - path: /cache
  media:
    existingClaim: media-data
    globalMounts:
      # Library: read-only — Jellyfin has no business writing there.
      - path: /data/media
        subPath: media
        readOnly: true
      # Jellyfin's backup folder is fixed at <data dir>/backups and cannot be
      # configured, so the NFS backups directory is mounted over it.
      - path: /config/backups
        subPath: backups/jellyfin
```

- [ ] **Step 4: Run the test to see it pass**

```bash
devbox run -- bash apps/media/tests/render-test.sh jellyfin
```
Expected: 15 `ok` lines, `all assertions passed`.

- [ ] **Step 5: Create `apps/media/jellyfin/probe.yaml`**

```yaml
# Jellyfin through Pangolin, end to end: edge -> Newt tunnel -> Jellyfin.
#
# Unlike the pangolin-tunnel probe (which stops at the edge's auth redirect),
# this resource has Pangolin auth disabled, so a 200 "Healthy" can only come
# from Jellyfin itself. This is the one probe that notices a dead Newt tunnel.
# A 302 means someone re-enabled Pangolin auth on the resource.
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: jellyfin-public
  namespace: media
spec:
  interval: 60s
  module: http_jellyfin_pangolin
  prober:
    url: blackbox-exporter.monitoring.svc.cluster.local:9115
  targets:
    staticConfig:
      static:
        - https://130.110.2.46/health
      labels:
        path: jellyfin-public
```

- [ ] **Step 6: Append the module to `infrastructure/monitoring/blackbox-exporter/values.yaml`**

After the `http_gluetun_portforward` module added in Task 4, at the same indentation:

```yaml

    # Jellyfin through Pangolin's public edge, by IP (like http_2xx_pangolin),
    # but this resource has Pangolin auth disabled, so the request is proxied
    # through the Newt tunnel to Jellyfin itself: 200 + "Healthy" proves the
    # whole path. A 302 here means Pangolin auth was re-enabled on the
    # resource. Used by apps/media/jellyfin/probe.yaml.
    http_jellyfin_pangolin:
      prober: http
      timeout: 10s
      http:
        valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
        valid_status_codes: [200]
        follow_redirects: false
        fail_if_body_not_matches_regexp:
          - Healthy
        preferred_ip_protocol: ip4
        headers:
          Host: jellyfin.koutoulastha.dev
        tls_config:
          server_name: jellyfin.koutoulastha.dev
```

- [ ] **Step 7: Verify**

```bash
devbox run -- yq '.config.modules | keys | join(",")' infrastructure/monitoring/blackbox-exporter/values.yaml
devbox run -- yq '.config.modules.http_jellyfin_pangolin.http.headers.Host + " " + .config.modules.http_jellyfin_pangolin.http.tls_config.server_name' infrastructure/monitoring/blackbox-exporter/values.yaml
devbox run -- bash apps/media/tests/render-test.sh | tail -1
```
Expected: `http_2xx,http_2xx_pangolin,http_gluetun_portforward,http_jellyfin_pangolin`; `jellyfin.koutoulastha.dev jellyfin.koutoulastha.dev`; `all assertions passed` (every app).

- [ ] **Step 8: Commit**

```bash
git add apps/media/jellyfin infrastructure/monitoring/blackbox-exporter
git commit -m "feat(media): Jellyfin, with an end-to-end Pangolin probe"
```

---

### Task 8: Runbook, final check, and merge

**Files:**
- Create: `apps/media/README.md`

- [ ] **Step 1: Create `apps/media/README.md`**

````markdown
# Media stack

qBittorrent downloads over Proton VPN; Prowlarr, Sonarr and Radarr drive it;
Jellyfin serves the library. Design: `docs/superpowers/specs/2026-09-30-media-stack-design.md`.

| App | Application | LAN URL | In-cluster |
|---|---|---|---|
| (storage) | `media-storage` | — | PVC `media/media-data` |
| qBittorrent + gluetun | `qbittorrent` | https://qbittorrent.koutoulastha.dev | `qbittorrent.media.svc` :8080 web, :8888 proxy, :8000 gluetun control |
| Prowlarr | `prowlarr` | https://prowlarr.koutoulastha.dev | `prowlarr.media.svc:9696` |
| Sonarr | `sonarr` | https://sonarr.koutoulastha.dev | `sonarr.media.svc:8989` |
| Radarr | `radarr` | https://radarr.koutoulastha.dev | `radarr.media.svc:7878` |
| Jellyfin | `jellyfin` | https://jellyfin.koutoulastha.dev (also public via Pangolin) | `jellyfin.media.svc:8096` |

## Registering (no app-of-apps)

Each `application.yaml` is applied once by hand, **`media-storage` first** —
it owns the `media` namespace and its `privileged` Pod Security label; the
apps do not create the namespace.

```bash
kubectl apply -f apps/media/storage/application.yaml
kubectl apply -f apps/media/qbittorrent/application.yaml   # then run the leak tests below
kubectl apply -f apps/media/prowlarr/application.yaml
kubectl apply -f apps/media/sonarr/application.yaml
kubectl apply -f apps/media/radarr/application.yaml
kubectl apply -f apps/media/jellyfin/application.yaml
```

## Things that live outside git

- **TrueNAS:** dataset `IOPSicle/media` (owner `apps:apps` 568:568, mode 775,
  recordsize 1M, **quota 2 TiB**), NFS share of `/mnt/IOPSicle/media` to the
  Talos node IPs, no maproot/mapall. The quota protects the pool, which every
  iSCSI volume in the cluster shares.
- **Proton:** a WireGuard configuration (platform Router, **NAT-PMP on**);
  only its `PrivateKey` is used, sealed in `qbittorrent/sealed-secret.yaml`.
- **Pangolin Cloud:** HTTP resource `jellyfin.koutoulastha.dev`, site
  `main-tunnel`, target `http://jellyfin.media.svc.cluster.local:8096`,
  **Pangolin auth disabled** (TV/phone apps cannot pass SSO).
- **App UIs:** logins, download clients, root folders, Prowlarr proxy and app
  sync, backups folders, Jellyfin networking. Stored in each app's SQLite on
  its `/config` volume.

## How torrent traffic is kept off the home IP

1. gluetun's firewall (iptables in the shared pod network namespace) allows
   nothing out except the WireGuard tunnel.
2. qBittorrent binds to `tun0` (`Session\Interface` in the seeded config).
3. `qbittorrent/networkpolicy.yaml`: Cilium lets the pod reach the internet on
   UDP 51820 only. Prowlarr has no internet egress at all; it uses gluetun's
   HTTP proxy.

DNS for the pod goes to gluetun's resolver on 127.0.0.1 (DNS over TLS inside
the tunnel).

## Leak tests (re-run after any change to the qbittorrent pod)

```bash
kubectl -n media exec deploy/qbittorrent -c app -- wget -qO- https://ipinfo.io/json      # Proton org, not home IP
kubectl -n media exec deploy/qbittorrent -c app -- cat /etc/resolv.conf                 # nameserver 127.0.0.1 only
kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- http://127.0.0.1:8000/v1/portforward   # {"port":N>0}
kubectl -n media exec deploy/qbittorrent -c gluetun -- ip link del tun0 && \
  kubectl -n media exec deploy/qbittorrent -c app -- sh -c 'wget -T 5 -qO- https://ipinfo.io/ip || echo BLOCKED'
kubectl -n media run cnp-test --rm -i --restart=Never --image=busybox:1.37 \
  --labels=app.kubernetes.io/name=qbittorrent -- sh -c 'wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
```

Plus ipleak.net's torrent address detection magnet: only the Proton IP may appear.

## Operations

- **Rotate/replace the Proton key:** generate a new WireGuard config (NAT-PMP
  on), re-seal `qbittorrent/sealed-secret.yaml` with the command in the
  implementation plan (Task 3 Step 7), merge, then
  `kubectl -n media rollout restart deploy/qbittorrent`.
- **Port forwarding lost** (`QbittorrentPortForwardLost`): restart the pod —
  gluetun picks a new P2P server.
- **Dataset filling** (`MediaDatasetFilling`): delete watched media, or raise
  the quota on TrueNAS *and* the PV/PVC `storage` (a label only; NFS does not
  enforce it) — check the pool has room first.
- **Backups:** Prowlarr/Sonarr/Radarr write scheduled backups to
  `/data/backups/<app>`; Jellyfin backups are manual (*Dashboard → Backups*)
  and land in `/data/backups/jellyfin` (mounted over `/config/backups`). The
  media library itself is deliberately not backed up.
- **Render test** before any values change:
  `devbox run -- bash apps/media/tests/render-test.sh`.

## Known, accepted risk

gluetun's HTTP proxy and qBittorrent share a pod, and qBittorrent skips auth
for localhost (gluetun needs that to set the forwarded port). A client of the
proxy could therefore reach qBittorrent's API unauthenticated. Only Prowlarr
can reach the proxy (Cilium), and Prowlarr is LAN-only behind a login.
````

- [ ] **Step 2: Full render test and plaintext-secret sweep**

```bash
devbox run -- bash apps/media/tests/render-test.sh | tail -1
ls apps/media/*/sealed-secret.yaml | wc -l
grep -L 'kind: SealedSecret' apps/media/*/sealed-secret.yaml
```
Expected: `all assertions passed`; `4`; no output from the last command (every sealed-secret file really is a SealedSecret).

- [ ] **Step 3 (user): Server-side dry run of the plain manifests**

Catches schema errors in the files the render test does not render (CiliumNetworkPolicy, Probe, PrometheusRule, PV/PVC). The namespace does not exist yet, so namespaced objects are checked with `--namespace default` overridden only for the dry run:

```bash
kubectl apply --dry-run=server -f apps/media/storage/pv.yaml
for f in apps/media/*/networkpolicy.yaml apps/media/*/probe.yaml apps/media/*/alertrules.yaml; do
  yq ".metadata.namespace = \"default\"" "$f" | kubectl apply --dry-run=server -f - || echo "FAILED: $f"
done
```
Expected: every line ends `(server dry run)`; no `FAILED:`.

- [ ] **Step 4: Push and open the PR**

```bash
git add apps/media/README.md
git commit -m "docs(media): runbook for the media stack"
git push -u origin feat/media-stack
gh pr create --base main --head feat/media-stack \
  --title "feat(media): qBittorrent over Proton VPN, *arr, Jellyfin" \
  --body "$(cat <<'EOF'
Adds the media stack from docs/superpowers/specs/2026-09-30-media-stack-design.md.

- `media-storage`: namespace (privileged PSS), static NFS PV/PVC on IOPSicle/media, never pruned
- qBittorrent + gluetun (Proton WireGuard, NAT-PMP port forwarding), Cilium egress = UDP 51820 only
- Prowlarr (indexers via gluetun's proxy, no direct egress), Sonarr, Radarr
- Jellyfin (LAN + Pangolin, end-to-end probe)
- Alerts: VPN down, port forward lost, dataset filling

On merge only the Argo CD OCI repo Secret and the blackbox module / alert-expression changes go live.
Every media Application is registered by hand, in order — see apps/media/README.md.

Render test: `devbox run -- bash apps/media/tests/render-test.sh`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5 (user): Merge**

```bash
gh pr merge --squash --delete-branch
git switch main && git pull --ff-only
```

---

### Task 9 (user): Roll out storage

- [ ] **Step 1: Preflight — cluster capabilities**

```bash
kubectl version -o yaml | yq '.serverVersion.gitVersion'
kubectl get crd ciliumnetworkpolicies.cilium.io -o name
kubectl -n argocd get secret repo-bjw-s-labs -o jsonpath='{.metadata.labels}'; echo
kubectl get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address
```
Expected: server ≥ `v1.29` (native sidecars; they are on by default from 1.29); the Cilium CRD exists; the repo Secret carries `argocd.argoproj.io/secret-type: repository`; a list of node IPs — **keep it for Step 3**.

- [ ] **Step 2: Create the dataset (TrueNAS UI)**

*Datasets → IOPSicle → Add Dataset*: name `media`, preset **Generic**. Under *Advanced Options*: **Record Size 1M**, **Quota for this dataset 2 TiB**. Save. Then *Edit Permissions* on `IOPSicle/media`: owner user **apps**, group **apps**, apply user and group, mode `775`. Confirm in the TrueNAS shell:

```bash
zfs get -H -o property,value quota,recordsize IOPSicle/media
stat -c '%u:%g %a' /mnt/IOPSicle/media
```
Expected: `quota 2T`, `recordsize 1M`; `568:568 775`.

- [ ] **Step 3: Create the NFS share (TrueNAS UI)**

*Shares → Unix (NFS) Shares → Add*: path `/mnt/IOPSicle/media`; *Hosts*: each node IP from Step 1; *Maproot* and *Mapall* **empty**. Save; enable the NFS service if prompted. If the nodes take their IPs from DHCP, give them reservations first — a node that changes IP loses the mount.

- [ ] **Step 4: Register `media-storage`**

```bash
kubectl apply -f apps/media/storage/application.yaml
kubectl -n argocd get application media-storage -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
kubectl get ns media -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'; echo
kubectl -n media get pvc media-data -o jsonpath='{.status.phase} {.spec.volumeName}'; echo
```
Expected: `Synced Healthy`; `privileged`; `Bound media-data`.

- [ ] **Step 5: Write, hardlink and ownership test as UID 568**

```bash
kubectl -n media run nfs-test --rm -i --restart=Never --image=busybox:1.37 \
  --overrides='{"spec":{"securityContext":{"runAsUser":568,"runAsGroup":568},"containers":[{"name":"t","image":"busybox:1.37","stdin":true,"command":["sh","-c","mkdir -p /data/torrents/incomplete /data/torrents/tv /data/torrents/movies /data/media/tv /data/media/movies /data/backups/prowlarr /data/backups/sonarr /data/backups/radarr /data/backups/jellyfin && echo hi > /data/torrents/t && ln /data/torrents/t /data/media/t && stat -c \"%h %u:%g %n\" /data/media/t && rm /data/torrents/t /data/media/t && ls /data /data/torrents /data/media /data/backups"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"media-data"}}]}}'
```
Expected: `2 568:568 /data/media/t` (link count 2 = hardlink across the directories), then the directory listing `backups media torrents` / `incomplete movies tv` / `movies tv` / `jellyfin prowlarr radarr sonarr`.

- [ ] **Step 6: Confirm the dataset alert has data**

```bash
curl -s 'http://localhost:9090/api/v1/query?query=truenas_dataset_quota_bytes%7Bdataset%3D%22IOPSicle%2Fmedia%22%7D' | yq -p json '.data.result[0].value[1]'
curl -s 'http://localhost:9090/api/v1/rules?type=alert' | yq -p json '[.data.groups[] | select(.name == "media-storage.rules") | .rules[].name]'
```
Expected: `2199023255552` (2 TiB); `["MediaDatasetFilling","MediaDatasetFilling"]`. If the first query is empty, the `dataset` label value differs — run `…query=truenas_dataset_quota_bytes%3E0` and fix the label value in `apps/media/storage/alertrules.yaml` in a follow-up PR. (It may take one exporter scrape interval after Step 2 to appear.)

---

### Task 10 (user): Roll out qBittorrent — leak gate

**Nothing else is rolled out until every step here passes.**

- [ ] **Step 1: Register and wait for the pod**

```bash
kubectl apply -f apps/media/qbittorrent/application.yaml
kubectl -n media rollout status deploy/qbittorrent --timeout=5m
kubectl -n media get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{range .items[0].status.initContainerStatuses[*]}{.name} ready={.ready}{"\n"}{end}{range .items[0].status.containerStatuses[*]}{.name} ready={.ready}{"\n"}{end}'
```
Expected: `gluetun ready=true`, `app ready=true`. If gluetun is not ready: `kubectl -n media logs deploy/qbittorrent -c gluetun | tail -40`.

Confirm the metric `QbittorrentVpnDown` depends on exists in this cluster's kube-state-metrics:
```bash
curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_init_container_status_ready%7Bnamespace%3D%22media%22%2Ccontainer%3D%22gluetun%22%7D' | yq -p json '.data.result[0].value[1]'
```
Expected: `1`. An empty result means the alert can never fire — stop and fix the rule before continuing.

- [ ] **Step 2: Leak test 1 — exit IP is Proton's**

```bash
curl -s https://ipinfo.io/ip; echo "  <- home IP"
kubectl -n media exec deploy/qbittorrent -c app -- sh -c 'wget -qO- https://ipinfo.io/json'
```
Expected: the pod's `ip` differs from the home IP and its `org` names Proton (e.g. `AS9009 M247` or `AS62371 Proton AG`). If the `app` image lacks `wget`, use `-c gluetun` for the same check — they share the network namespace.

- [ ] **Step 3: Leak test — DNS**

```bash
kubectl -n media exec deploy/qbittorrent -c app -- cat /etc/resolv.conf
```
Expected: `nameserver 127.0.0.1` and nothing else.

- [ ] **Step 4: Web UI requires a login; set the password**

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://qbittorrent.koutoulastha.dev/api/v2/app/version
kubectl -n media logs deploy/qbittorrent -c app | grep -i 'temporary password'
```
Expected: `403` (no RFC1918 bypass). Log in at `https://qbittorrent.koutoulastha.dev` as `admin` with the temporary password; *Tools → Options → WebUI*: set a strong password, confirm **Bypass authentication for clients on localhost** is ticked and **Bypass authentication for clients in whitelisted IP subnets** is not; *Advanced*: **Network interface** shows `tun0`. Save.

- [ ] **Step 5: Leak test 4 — forwarded port matches**

```bash
kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- http://127.0.0.1:8000/v1/portforward; echo
kubectl -n media logs deploy/qbittorrent -c gluetun | grep -i 'port forward' | tail -3
```
Expected: `{"port":N}` with N > 0; the log shows the up-command's `wget` succeeding. In the web UI *Options → Connection*, **Port used for incoming connections** equals N.

- [ ] **Step 6: Leak test 3 — kill the tunnel; nothing leaks**

```bash
kubectl -n media exec deploy/qbittorrent -c gluetun -- ip link del tun0
kubectl -n media exec deploy/qbittorrent -c app -- sh -c 'wget -T 5 -qO- https://ipinfo.io/ip || echo BLOCKED'
sleep 60
kubectl -n media exec deploy/qbittorrent -c app -- sh -c 'wget -T 5 -qO- https://ipinfo.io/ip || echo BLOCKED'
```
Expected: first `BLOCKED` (or a Proton IP if gluetun already reconnected — never the home IP); after a minute, a Proton IP again.

- [ ] **Step 7: The Cilium layer is enforcing, independently of gluetun**

A throwaway pod with no gluetun but the qBittorrent label is selected by the same CiliumNetworkPolicy; a control pod without the label is not. (The test pod lacks the chart's `controller`/`instance` labels, so the Service does not select it.)

```bash
kubectl -n media run cnp-test --rm -i --restart=Never --image=busybox:1.37 \
  --labels=app.kubernetes.io/name=qbittorrent -- sh -c 'wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
kubectl -n media run cnp-control --rm -i --restart=Never --image=busybox:1.37 \
  --labels=app=cnp-control -- sh -c 'wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1 && echo REACHED || echo DROPPED'
kubectl -n media rollout restart deploy/qbittorrent && kubectl -n media rollout status deploy/qbittorrent --timeout=5m
```
Expected: `DROPPED`, then `REACHED` — the policy, not the network, blocks the first. The restart is for Step 8.

- [ ] **Step 8: Port follows a reconnect**

```bash
kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- http://127.0.0.1:8000/v1/portforward; echo
```
Expected: `{"port":M}`, M > 0, and qBittorrent's incoming port (web UI) equals M after the restart in Step 7 — the up-command re-ran.

- [ ] **Step 9: Torrent-level leak test and real download**

On `https://ipleak.net` → *Torrent Address detection* → copy the magnet link; add it in qBittorrent. Within a minute ipleak lists the peer IP. Then add the current Debian netinst torrent (`https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/`).
Expected: ipleak shows only the Proton IP from Step 2, never the home IP. The Debian torrent downloads to `/data/torrents`, and qBittorrent's status bar shows the connection icon green (incoming connections reachable). Delete both torrents with files.

---

### Task 11 (user): Roll out Prowlarr, Sonarr, Radarr

- [ ] **Step 1: Register and wait**

```bash
for app in prowlarr sonarr radarr; do kubectl apply -f apps/media/$app/application.yaml; done
for app in prowlarr sonarr radarr; do kubectl -n media rollout status deploy/$app --timeout=5m; done
for h in prowlarr sonarr radarr; do curl -sk -o /dev/null -w "$h %{http_code}\n" https://$h.koutoulastha.dev/; done
```
Expected: three rollouts complete; each host answers `200` or `302` (login page).

- [ ] **Step 2: First login** — each UI asks to create its forms-login user on first visit. Use strong, distinct passwords.

- [ ] **Step 3: Sonarr and Radarr → qBittorrent and root folders**

In **Sonarr** *Settings → Download Clients → + → qBittorrent*: host `qbittorrent.media.svc`, port `8080`, username `admin`, the password from Task 10 Step 4, category `tv`. **Test**, save. *Settings → Media Management*: *Root Folders → Add* `/data/media/tv`; **Use Hardlinks instead of Copy** on (default). *Settings → General → Backups*: folder `/data/backups/sonarr`, interval 7 days.
In **Radarr**: same, category `movies`, root folder `/data/media/movies`, backup folder `/data/backups/radarr`.

- [ ] **Step 4: Prowlarr → proxy, then prove the bypass fails**

*Settings → General → Proxy*: enabled, type **HTTP(S)**, hostname `qbittorrent.media.svc`, port `8888`, **Bypass Proxy for Local Addresses** on. Save. *Settings → General → Backups*: folder `/data/backups/prowlarr`. Then:

```bash
kubectl -n media exec deploy/prowlarr -- sh -c 'wget -T 5 -qO- https://ipinfo.io/ip || echo BLOCKED'
kubectl -n media exec deploy/prowlarr -- sh -c 'wget -T 10 -qO- -e use_proxy=yes -e https_proxy=http://qbittorrent.media.svc:8888 https://ipinfo.io/ip'
```
Expected: `BLOCKED` (Cilium: no direct egress); the proxied request prints the Proton IP from Task 10.

- [ ] **Step 5: Prowlarr → Sonarr/Radarr, then an indexer**

*Settings → Apps → + Sonarr*: Prowlarr server `http://prowlarr.media.svc:9696`, Sonarr server `http://sonarr:8989`, API key = the Sonarr key from Task 6 Step 7. **Test**, save. Same for Radarr (`http://radarr:7878`). Use the **single-label** hostnames `sonarr` / `radarr` here, not `*.media.svc`: Prowlarr's proxy only bypasses dotless hostnames (.NET `WebProxy` locality rules), so a dotted name would be sent into gluetun's proxy and fail. *Indexers → Add*: one public indexer; **Test**. In Sonarr *Settings → Indexers*, the indexer appears (synced by Prowlarr).

- [ ] **Step 6: End-to-end with hardlink check**

In Radarr add a small public-domain film (e.g. *Night of the Living Dead*, 1968), search, grab. When it shows as imported:

```bash
kubectl -n media exec deploy/radarr -- sh -c 'find /data/media/movies -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) -exec stat -c "%h %n" {} \;'
```
Expected: link count `2` on the imported file — the same inode as the torrent still seeding in `/data/torrents/movies`, no copy.

---

### Task 12 (user): Roll out Jellyfin

- [ ] **Step 1: Register and wait**

```bash
kubectl apply -f apps/media/jellyfin/application.yaml
kubectl -n media rollout status deploy/jellyfin --timeout=5m
curl -sk https://jellyfin.koutoulastha.dev/health; echo
```
Expected: `Healthy`.

- [ ] **Step 2: Setup wizard (LAN)** at `https://jellyfin.koutoulastha.dev`: create the admin user; libraries **Movies** → `/data/media/movies`, **Shows** → `/data/media/tv`. The film from Task 11 plays in the browser.

- [ ] **Step 3: Networking and remote-access hardening**

Find the pod CIDR:
```bash
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.ipam} {.data.cluster-pool-ipv4-cidr}'; echo
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'; echo
```
Use `cluster-pool-ipv4-cidr` when `ipam` is `cluster-pool`; otherwise the nodes' `podCIDR`s. *Dashboard → Networking*: **Known proxies** = that CIDR; **LAN networks** = `192.168.20.0/24` (home LAN only — never the pod CIDR). Save, restart Jellyfin (*Dashboard → Restart*). *Dashboard → Users → admin → Profile*: untick **Allow remote connections to this server**. *Dashboard → Playback → Transcoding*: confirm the transcode path is under `/cache`.

- [ ] **Step 4: Pangolin resource**

In Pangolin Cloud: *Resources → Add*: type **HTTP**, site **main-tunnel**, subdomain `jellyfin` on `koutoulastha.dev`, target `http://jellyfin.media.svc.cluster.local:8096`. Under *Authentication*, **disable** Pangolin SSO for this resource. Wait for its certificate to be issued.

- [ ] **Step 5: External checks**

```bash
curl -s --resolve jellyfin.koutoulastha.dev:443:130.110.2.46 https://jellyfin.koutoulastha.dev/health; echo
curl -s 'http://localhost:9090/api/v1/query?query=probe_success%7Bpath%3D%22jellyfin-public%22%7D' | yq -p json '.data.result[0].value[1]'
```
Expected: `Healthy` via the public edge; probe value `1` (allow two minutes after the resource goes live). From a phone on mobile data, a non-admin user can sign in and play; the admin user is refused remotely.

- [ ] **Step 6: First manual backup** — *Dashboard → Backups → Create*. Then `kubectl -n media exec deploy/jellyfin -- ls /config/backups` lists the archive (it lives on NFS under `backups/jellyfin`).

---

### Task 13 (user): Alert firing tests

- [ ] **Step 1: Rules and probe are loaded**

```bash
curl -s 'http://localhost:9090/api/v1/rules?type=alert' | yq -p json '[.data.groups[] | select(.name | test("^media-")) | .rules[].name]'
curl -s 'http://localhost:9090/api/v1/query?query=probe_success%7Bpath%3D%22vpn-portforward%22%7D' | yq -p json '.data.result[0].value[1]'
```
Expected: `QbittorrentVpnDown`, `QbittorrentPortForwardLost`, `MediaDatasetFilling` ×2; probe value `1`.

- [ ] **Step 2: `QbittorrentVpnDown` fires**

Block the pod's WireGuard handshake with a temporary deny policy (not in git, so Argo CD leaves it alone), then restart the pod so the tunnel has to be re-established — an already-established flow would survive a new deny rule:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: alert-test-block-vpn
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: qbittorrent
  egressDeny:
    - toEntities: [world]
EOF
kubectl -n media rollout restart deploy/qbittorrent
```
Wait 11 minutes. On the Prometheus *Alerts* page (or Alertmanager): `QbittorrentVpnDown` **firing**; `QbittorrentPortForwardLost` **not** firing (suppressed); no `BlackboxProbeFailed` with `path="vpn-portforward"`.

- [ ] **Step 3: Restore**

```bash
kubectl -n media delete ciliumnetworkpolicy alert-test-block-vpn
kubectl -n media rollout restart deploy/qbittorrent
kubectl -n media rollout status deploy/qbittorrent --timeout=5m
```
Expected: `QbittorrentVpnDown` resolves; Task 10 Step 5's port check passes again.

- [ ] **Step 4: Record the outcome** — note in the PR (or a follow-up commit to `apps/media/README.md`) the date the leak gate and alert tests passed.
