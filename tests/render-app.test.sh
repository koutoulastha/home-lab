#!/usr/bin/env bash
# Self-test for tests/render-app.sh. Run from the repo root inside devbox:
#   KUBE_VERSION=<cluster version> devbox run -- bash tests/render-app.test.sh
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1 (expected exit $3, got $2)"; FAILS=$((FAILS+1)); fi; }

# 1. Every current chart-backed Application renders.
bash "$ROOT/tests/render-app.sh" --all > "$TMP/all.log" 2>&1; rc=$?
check "--all renders every chart-backed Application" "$rc" 0
grep -E '^(FAIL|ok|skip)' "$TMP/all.log" | sed 's/^/       /'

# 2. A nonexistent chart version is reported as FAIL with a non-zero exit.
yq '(.spec.sources[] | select(has("chart")) | .targetRevision) = "0.0.0-doesnotexist"' \
  "$ROOT/infrastructure/monitoring/loki/application.yaml" > "$TMP/application.yaml"
bash "$ROOT/tests/render-app.sh" "$TMP/application.yaml" > "$TMP/bad.log" 2>&1; rc=$?
check "bad version exits non-zero" "$rc" 1
grep -q '^FAIL' "$TMP/bad.log"; check "bad version prints FAIL" "$?" 0

# 3. A missing KUBE_VERSION is refused.
env -u KUBE_VERSION bash "$ROOT/tests/render-app.sh" "$TMP/application.yaml" > /dev/null 2>&1; rc=$?
check "missing KUBE_VERSION is refused" "$rc" 2

(( FAILS == 0 )) && echo "all assertions passed" || { echo "$FAILS assertion(s) failed"; exit 1; }
