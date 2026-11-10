#!/usr/bin/env bash
# Renders the Helm chart source(s) of ArgoCD Applications the way ArgoCD
# would: the pinned chart version, the destination namespace, the release
# name and every helm.valueFiles entry (with $values/ resolved to the repo
# root), against this cluster's Kubernetes version and Gateway API.
# Every version bump must render cleanly here before it is merged.
#
# Run from the repo root inside devbox (helm + yq-go):
#   KUBE_VERSION=<cluster version> devbox run -- bash tests/render-app.sh <application.yaml>...
#   KUBE_VERSION=<cluster version> devbox run -- bash tests/render-app.sh --all
# Rendered output lands in $RENDER_OUT (default: a temp dir, deleted on exit).
set -euo pipefail

if [[ -z "${KUBE_VERSION:-}" ]]; then
  echo "KUBE_VERSION is not set; see tests/README.md for the cluster's version" >&2
  exit 2
fi

ROOT=$(git rev-parse --show-toplevel)
if [[ -z "${RENDER_OUT:-}" ]]; then
  RENDER_OUT=$(mktemp -d)
  trap 'rm -rf "$RENDER_OUT"' EXIT
fi
FAILS=0

API_VERSIONS=(
  gateway.networking.k8s.io/v1/HTTPRoute
  gateway.networking.k8s.io/v1/Gateway
  monitoring.coreos.com/v1/ServiceMonitor
  monitoring.coreos.com/v1
  gateway.networking.k8s.io/v1
)

# render_app <application.yaml>
render_app() {
  local file=$1 app ns n i
  app=$(yq '.metadata.name' "$file")
  ns=$(yq '.spec.destination.namespace' "$file")
  # Normalise single `source:` and multi `sources:` into one list.
  n=$(yq '[(.spec.sources // [.spec.source])[] | select(has("chart"))] | length' "$file")
  if [[ "$n" == 0 ]]; then echo "skip $app (no chart source)"; return 0; fi

  for ((i = 0; i < n; i++)); do
    local src repo chart version release ref args=()
    src="[(.spec.sources // [.spec.source])[] | select(has(\"chart\"))][$i]"
    repo=$(yq "$src.repoURL" "$file")
    chart=$(yq "$src.chart" "$file")
    version=$(yq "$src.targetRevision" "$file")
    release=$(yq "$src.helm.releaseName // \"$app\"" "$file")
    if [[ "$repo" == http* ]]; then
      args+=("$chart" --repo "$repo")
    else
      ref="oci://${repo%/}/$chart"
      args+=("$ref")
    fi
    while IFS= read -r vf; do
      [[ -z "$vf" ]] && continue
      args+=(--values "$ROOT/${vf#\$values/}")
    done < <(yq "$src.helm.valueFiles[]" "$file")
    for api in "${API_VERSIONS[@]}"; do args+=(--api-versions "$api"); done

    local out="$RENDER_OUT/$app-$i.yaml" err="$RENDER_OUT/$app-$i.err"
    if helm template "$release" "${args[@]}" --version "$version" \
        --namespace "$ns" --kube-version "$KUBE_VERSION" --include-crds \
        > "$out" 2> "$err"; then
      echo "ok   $app ($chart $version)"
    else
      echo "FAIL $app ($chart $version)"
      sed 's/^/     /' "$err"
      FAILS=$((FAILS + 1))
    fi
  done
}

files=()
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r f; do files+=("$ROOT/$f"); done < <(
    git -C "$ROOT" ls-files 'apps/**application*.yaml' 'infrastructure/**application*.yaml')
else
  files=("$@")
fi
[[ ${#files[@]} -gt 0 ]] || { echo "usage: render-app.sh --all | <application.yaml>..." >&2; exit 2; }

# A file may hold several documents (traefik's does); render each Application.
for f in "${files[@]}"; do
  docs=$(yq ea '[.] | length' "$f")
  for ((d = 0; d < docs; d++)); do
    one="$RENDER_OUT/doc-$(basename "$(dirname "$f")")-$d.yaml"
    yq "select(document_index == $d)" "$f" > "$one"
    [[ $(yq '.kind' "$one") == Application ]] && render_app "$one"
  done
done

if (( FAILS > 0 )); then echo "$FAILS render(s) failed"; exit 1; fi
