#!/usr/bin/env bash
# Checks infrastructure/cicd/argocd/root.yaml, the app-of-apps Application:
# that its include glob selects exactly the repo's Application files, and
# that its sync policy can never delete a child Application.
#
# ArgoCD matches `directory.include` against each file's path relative to the
# source path with no path separator, so `*` also matches `/`. Bash's
# [[ str == pattern ]] has the same semantics, which is what this test uses.
#
#   devbox run -- bash tests/root-app.test.sh
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel)
APP="$ROOT/infrastructure/cicd/argocd/root.yaml"
FAILS=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/       /'; FAILS=$((FAILS + 1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1" "expected: $3"$'\n'"got:      $2"; fi; }

if [[ ! -f "$APP" ]]; then fail "root.yaml exists"; echo "1 assertion(s) failed"; exit 1; fi

include=$(yq '.spec.source.directory.include' "$APP")
inner=${include#\{}; inner=${inner%\}}
IFS=',' read -r -a patterns <<< "$inner"

matches() {
  local f=$1 p
  for p in "${patterns[@]}"; do
    # shellcheck disable=SC2053  # unquoted on purpose: glob match
    [[ "$f" == $p ]] && return 0
  done
  return 1
}

cd "$ROOT"
selected=$(git ls-files | while read -r f; do matches "$f" && echo "$f"; done | sort)
expected=$(git ls-files 'apps/**application*.yaml' 'infrastructure/**application*.yaml' | sort)

eq "include selects exactly the Application files" "$selected" "$expected"
matches "infrastructure/cicd/argocd/root.yaml" && fail "root.yaml does not manage itself" || ok "root.yaml does not manage itself"
grep -q '^old/' <<< "$selected" && fail "nothing under old/ is selected" || ok "nothing under old/ is selected"

eq "kind is Application"        "$(yq '.kind' "$APP")" "Application"
eq "lives in argocd namespace"  "$(yq '.metadata.namespace' "$APP")" "argocd"
eq "children go to argocd"      "$(yq '.spec.destination.namespace' "$APP")" "argocd"
eq "tracks main"                "$(yq '.spec.source.targetRevision' "$APP")" "main"
eq "source path is repo root"   "$(yq '.spec.source.path' "$APP")" "."
eq "recurses"                   "$(yq '.spec.source.directory.recurse' "$APP")" "true"
eq "never prunes children"      "$(yq '.spec.syncPolicy.automated.prune' "$APP")" "false"
eq "self-heals drift"           "$(yq '.spec.syncPolicy.automated.selfHeal' "$APP")" "true"

# Every selected file must hold only Application documents, or the root
# would start managing arbitrary resources.
bad=$(for f in $selected; do yq ea '.kind' "$f" | grep -vx -e Application -e '---' | sed "s|^|$f: |"; done)
eq "selected files hold only Applications" "$bad" ""

if (( FAILS > 0 )); then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all assertions passed"
