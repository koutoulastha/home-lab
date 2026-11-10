# Repo-wide tests

Run from the repo root inside devbox.

## `render-app.sh`: render Applications the way ArgoCD does

Renders every Helm chart source of one or more ArgoCD Applications with the
pinned chart version, release name, destination namespace and `valueFiles`
(`$values/` resolved to the repo root), against this cluster's Kubernetes
version and the Gateway API / Prometheus Operator API groups. Run it on every
Application a version bump touches before merging.

```bash
export KUBE_VERSION=<cluster version, see below>
devbox run -- bash tests/render-app.sh --all
devbox run -- bash tests/render-app.sh infrastructure/monitoring/loki/application.yaml
```

Prints `ok`, `FAIL` (with helm's error) or `skip` (no chart source) per
Application. Exits 1 if any render fails, and 2 if `KUBE_VERSION` is unset.
Set `RENDER_OUT=<dir>` to keep the rendered manifests for diffing.

**`KUBE_VERSION`**: the cluster's server version, from
`kubectl version -o json | jq -r .serverVersion.gitVersion`.
Recorded value: `v1.37.2` (2026-11-10; update when the cluster is upgraded).

Self-test: `KUBE_VERSION=… devbox run -- bash tests/render-app.test.sh`.
It expects every current Application to render, a bogus chart version to be
reported as `FAIL`, and a missing `KUBE_VERSION` to be refused.
