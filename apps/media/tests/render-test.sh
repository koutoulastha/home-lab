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
  eq "$app: config PVC never pruned"      "$f" 'select(.kind == "PersistentVolumeClaim") | .metadata.annotations["argocd.argoproj.io/sync-options"]' "Prune=false,Delete=false"
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
  # qBittorrent is bound to tun0 (seeded conf) and the leak tests delete tun0;
  # gluetun names the WireGuard interface wg0 unless told otherwise.
  eq "gluetun: interface is tun0"           "$f" "$dep | $g | .env[] | select(.name == \"VPN_INTERFACE\") | .value" "tun0"
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
  eq "CNP: proxy only from prowlarr+flaresolverr" "$np" '.spec.ingress[] | select(.toPorts[0].ports[0].port == "8888") | [.fromEndpoints[].matchLabels["app.kubernetes.io/name"]] | sort | join(",")' "flaresolverr,prowlarr"
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
  eq "prowlarr CNP: may reach flaresolverr" "$np" '.spec.egress[] | select(.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "flaresolverr") | .toPorts[0].ports[0].port' "8191"
}

test_flaresolverr() {
  local f; f=$(render flaresolverr)
  local dep='select(.kind == "Deployment")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  eq "flaresolverr: Recreate strategy"    "$f" "$dep | .spec.strategy.type" "Recreate"
  eq "flaresolverr: Service name"         "$f" 'select(.kind == "Service") | .metadata.name' "flaresolverr"
  eq "flaresolverr: Service port"         "$f" 'select(.kind == "Service") | .spec.ports[0].port' "8191"
  # Empty output = no document of that kind rendered.
  eq "flaresolverr: no HTTPRoute"         "$f" 'select(.kind == "HTTPRoute") | .kind' ""
  eq "flaresolverr: no PVC"               "$f" 'select(.kind == "PersistentVolumeClaim") | .kind' ""
  # The image's user is named, not numeric; runAsNonRoot needs the UID.
  eq "flaresolverr: runs as image UID"    "$f" "$dep | $a | .securityContext.runAsUser" "1000"
  eq "flaresolverr: non-root"             "$f" "$dep | $a | .securityContext.runAsNonRoot" "true"
  eq "flaresolverr: drops all caps"       "$f" "$dep | $a | .securityContext.capabilities.drop[0]" "ALL"
  eq "flaresolverr: probes /health"       "$f" "$dep | $a | .readinessProbe.httpGet.path" "/health"
  eq "flaresolverr: fallback proxy"       "$f" "$dep | $a | .env[] | select(.name == \"PROXY_URL\") | .value" "http://qbittorrent:8888"
  eq "flaresolverr: memory limit"         "$f" "$dep | $a | .resources.limits.memory" "1Gi"
  local np="$MEDIA/flaresolverr/networkpolicy.yaml"
  eq "flaresolverr CNP: selects flaresolverr" "$np" '.spec.endpointSelector.matchLabels["app.kubernetes.io/name"]' "flaresolverr"
  eq "flaresolverr CNP: no world egress"  "$np" '[.spec.egress[] | select(has("toEntities") or has("toCIDR") or has("toCIDRSet") or has("toFQDNs"))] | length' "0"
  eq "flaresolverr CNP: egress = dns + proxy" "$np" '[.spec.egress[].toEndpoints[0].matchLabels | (.["k8s-app"] // .["app.kubernetes.io/name"])] | sort | join(",")' "kube-dns,qbittorrent"
  eq "flaresolverr CNP: proxy port"       "$np" '.spec.egress[] | select(.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "qbittorrent") | .toPorts[0].ports[0].port' "8888"
  eq "flaresolverr CNP: ingress only prowlarr" "$np" '[.spec.ingress[].fromEndpoints[].matchLabels["app.kubernetes.io/name"]] | join(",")' "prowlarr"
  eq "flaresolverr CNP: ingress port"     "$np" '.spec.ingress[0].toPorts[0].ports[0].port' "8191"
}

test_jellyfin() {
  local f; f=$(render jellyfin)
  local dep='select(.kind == "Deployment")'
  local a='.spec.template.spec.containers[] | select(.name == "app")'
  common_checks jellyfin "$f" 8096 app
  eq "jellyfin: probes /health"          "$f" "$dep | $a | .readinessProbe.httpGet.path" "/health"
  eq "jellyfin: library read-only"       "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data/media\") | .readOnly" "true"
  eq "jellyfin: library is media/ only"  "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/data/media\") | .subPath" "media"
  eq "jellyfin: backups over /config/data/backups" "$f" "$dep | $a | .volumeMounts[] | select(.mountPath == \"/config/data/backups\") | .subPath" "backups/jellyfin"
  eq "jellyfin: cache capped"            "$f" "$dep | .spec.template.spec.volumes[] | select(.name == \"cache\") | .emptyDir.sizeLimit" "20Gi"
}

test_storage() {
  local d="$MEDIA/storage"
  eq "PV: Retain"                     "$d/pv.yaml" '.spec.persistentVolumeReclaimPolicy' "Retain"
  eq "PV: pinned to media/media-data" "$d/pv.yaml" '.spec.claimRef.namespace + "/" + .spec.claimRef.name' "media/media-data"
  eq "PV: TrueNAS NFS server"         "$d/pv.yaml" '.spec.nfs.server' "192.168.20.2"
  eq "PV: IOPSicle/media export"      "$d/pv.yaml" '.spec.nfs.path' "/mnt/IOPSicle/media"
  eq "PV: no StorageClass"            "$d/pv.yaml" '.spec.storageClassName' ""
  eq "PV: never pruned or deleted"    "$d/pv.yaml" '.metadata.annotations["argocd.argoproj.io/sync-options"]' "Prune=false,Delete=false"
  eq "PV: RWX"                        "$d/pv.yaml" '.spec.accessModes[0]' "ReadWriteMany"
  eq "PVC: binds the PV by name"      "$d/pvc.yaml" '.spec.volumeName' "media-data"
  eq "PVC: never pruned or deleted"   "$d/pvc.yaml" '.metadata.annotations["argocd.argoproj.io/sync-options"]' "Prune=false,Delete=false"
  eq "App: prune disabled"            "$d/application.yaml" '.spec.syncPolicy.automated.prune' "false"
  eq "App: namespace is privileged"   "$d/application.yaml" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"]' "privileged"
  eq "App: no restricted warnings"    "$d/application.yaml" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/warn"]' "privileged"
  eq "App: no restricted audit"       "$d/application.yaml" '.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/audit"]' "privileged"
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
