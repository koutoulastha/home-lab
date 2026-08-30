# Monitoring — design

**Date:** 2026-08-30
**Status:** approved, ready for implementation planning
**Scope:** Phase 1 — metrics, dashboards, alerting, uptime probes. Log aggregation is Phase 2 and has its own spec.

## Goal

Give the cluster three things it currently lacks: a way to see what it is doing, a way to be told when it stops, and a way to know that the telling still works.

Concretely, on completion:

- Every node, workload, and the Traefik/CNPG/Immich data path emit metrics into a 90-day Prometheus.
- Grafana is reachable on the LAN and publicly through Pangolin, behind authentication.
- Alerts push to a phone via ntfy, with severity mapped to notification priority.
- An external dead-man's-switch alerts when the cluster stops reporting at all.
- Public hostnames are probed both from inside the cluster and through the public path, so a dead tunnel is detectable.

## Non-goals

Explicitly out of scope, each for a stated reason:

| Not doing | Why |
|---|---|
| Loki / log aggregation | Phase 2. Separate chart, separate storage sizing and retention policy. Only dependency is that Grafana already exists. |
| Cilium + Hubble metrics | Cilium is installed by Talos/Omni, not this repo (see `infrastructure/networking/cilium/application.yaml`). Enabling its metrics is an Omni machine-config change, not a commit here. Worth doing; not a blocker. |
| Thanos / Mimir long-term storage | 90 days local covers the stated need. Remote-write is real infrastructure with real operational cost. |
| Grafana OIDC | Requires an IdP this homelab does not run. Sealed admin password plus Pangolin's auth layer is sufficient. |
| Tiered alert topics | Severity-to-priority mapping on a single topic gets most of the benefit with one less thing to manage. |

## Decisions

Recorded with rationale, because the reasoning is the part that decays:

1. **`kube-prometheus-stack` as a single umbrella Application**, rather than separately composed Prometheus / Grafana / Alertmanager Applications. The umbrella chart ships the operator, the components, and the glue between them already wired — provisioned dashboards, control-plane ServiceMonitors, Alertmanager already pointed at Prometheus. Composing it by hand is roughly four times the YAML for a cluster this size, with no benefit at this scale. Cost accepted: a large values file and inherited upstream opinions.
2. **Prometheus, not VictoriaMetrics.** VictoriaMetrics is meaningfully lighter on RAM and disk at 90-day retention and was a genuine contender. Rejected because the ecosystem, community dashboards, and every troubleshooting guide assume Prometheus, and the operator would be the one absorbing the difference. Revisit if Prometheus memory use becomes a problem.
3. **Full default rule set plus curated additions**, rather than a curated set alone. To be precise about what is kept and what is not: the default *alerting rules* are retained in full, while default *ServiceMonitors* aimed at components this cluster does not run are disabled. These are not in tension — a rule with no target is inert; a target that cannot be scraped alerts forever. Accepted consequence: day-one work is pruning targets, not writing rules. See "Talos-specific: targets that will be permanently red".
4. **Public ntfy.sh with a random topic**, not self-hosted ntfy. The alert path must not share dependencies with the thing being monitored. Self-hosting in-cluster would make alert delivery depend on the cluster, its storage, and Traefik — precisely what is broken when an alert matters. Consequence: the topic name is the only credential, so it is long, random, and sealed.
5. **Under `infrastructure/`, not `apps/`.** This is cluster plumbing, alongside `cert-manager` and `sealed-secrets`.

## Layout

```
infrastructure/monitoring/
  kube-prometheus-stack/
    application.yaml        # chart source + $values git source, pinned targetRevision
    values.yaml
    sealed-secret.yaml      # grafana admin password; ntfy URL; healthchecks URL
    alertrules.yaml         # PrometheusRule: curated additions
    httproute.yaml          # grafana.koutoulastha.dev
  blackbox-exporter/
    application.yaml
    values.yaml
    probes.yaml             # Probe CRs, internal + public-path
```

Application shape follows the repo's established two-source pattern (see `apps/immich/application.yaml`): one Helm source carrying `chart` + `targetRevision`, one git source carrying `ref: values` and a `path` for the plain manifests. A source with `ref` may not also set `chart`, which is why they are separate. `$values` paths are relative to the repo root.

Chart `targetRevision` is pinned to an explicit version, never `"*"`, per the repo convention — `selfHeal` must never upgrade a chart on its own.

## The two things that silently break the first sync

Both are already documented failure modes in this repo. Neither produces a useful error.

### PodSecurity rejects node-exporter

`node-exporter` is a DaemonSet using `hostNetwork`, `hostPID`, and hostPath mounts into `/proc` and `/sys`. The cluster enforces PodSecurity `baseline` on unlabeled namespaces. Under `baseline` the DaemonSet is rejected **silently**: it reports desired > 0 / current 0, and no pods ever appear. This is the identical failure the README documents for the CSI node DaemonSets.

Fix: `spec.syncPolicy.managedNamespaceMetadata` on the Application, setting `pod-security.kubernetes.io/enforce: privileged` on the `monitoring` namespace.

### CRDs exceed the annotation size limit

The Prometheus Operator CRDs are far larger than the 262144-byte `last-applied-configuration` annotation that client-side apply writes. Client-side apply fails outright. This is the same constraint already recorded in `infrastructure/database/cloudnative-pg/values.yaml` for the CNPG `Cluster` CRD.

Fix: `ServerSideApply=true` in the Application's `syncOptions`, with `Replace=true` as fallback.

## Scrape targets

### Free, no configuration

node-exporter (all nodes), kube-state-metrics, kubelet/cAdvisor, kube-apiserver.

### One-line changes to existing files in this repo

| File | Change | Why it matters |
|---|---|---|
| `infrastructure/networking/traefik/values.yaml` | enable `metrics.prometheus.service` and `metrics.prometheus.serviceMonitor` | Request rate, latency percentiles, and status codes per HTTPRoute. The highest-value signal available, since every service is reached through Traefik. |
| `infrastructure/database/cloudnative-pg/values.yaml` | `monitoring.podMonitorEnabled: true` | Replaces the now-obsolete `# No Prometheus Operator in this cluster.` comment. |
| `apps/immich/db/cluster.yaml` | `spec.monitoring.enablePodMonitor: true` | Postgres connection counts, replication state, backup age. |

Each is flipped **one at a time**, confirming the target goes green before the next. A mistyped label selector fails by the target simply never appearing — not by erroring.

### Talos-specific: targets that will be permanently red

`kube-controller-manager`, `kube-scheduler`, and `etcd` bind their metrics endpoints to `127.0.0.1` on Talos. Prometheus cannot reach them from a pod. The stack ships ServiceMonitors for all three **enabled by default**, so with the full default rule set all three sit permanently red and fire `TargetDown` forever.

Two actions, both intended:

- In `values.yaml`, set `kubeControllerManager.enabled: false`, `kubeScheduler.enabled: false`, `kubeEtcd.enabled: false` so the stack does not fabricate unreachable targets.
- Separately, in Omni, set `bind-address: 0.0.0.0` on controller-manager and scheduler and `listen-metrics-urls` on etcd to actually obtain the metrics, then re-enable. This is a Talos machine-config change outside this repo and is not a prerequisite.

Also set `kubeProxy.enabled: false` — Cilium runs in kube-proxy replacement mode, so that ServiceMonitor targets a DaemonSet that does not exist.

**General principle:** every default ServiceMonitor pointing at something this cluster does not run becomes a permanent red target and a recurring alert. Pruning these is the day-one work.

## Alerting

### Delivery

ntfy consumes Alertmanager's webhook format directly via its message-templating mode (`?tpl=yes` with title and message templates over the webhook JSON). A plain `webhook_config` — no bridge container, no sidecar.

### Secret handling

On public ntfy.sh the topic name *is* the credential: anyone holding it can read alerts and publish forgeries. It is never committed.

Sealing the entire Alertmanager config would work but would also hide the routing and inhibition rules from git review, which is where the reviewable logic lives. Instead:

- The routing tree stays readable in `values.yaml`.
- The receiver uses Alertmanager's `url_file` to read the endpoint from disk.
- The URL lives in a sealed secret mounted through `alertmanagerSpec.secrets`.

Same mechanism for the healthchecks.io ping URL. Git shows the shape of the routing and nothing sensitive.

### Routing

- Single ntfy topic; severity mapped to ntfy priority. `critical` → priority 5 (bypasses Do Not Disturb). `warning` → priority 2 (arrives silently).
- `group_by: [alertname, namespace]`
- `group_wait: 30s`
- `repeat_interval: 4h` — an unresolved problem nags four times a day, not every five minutes.

### Inhibition

The difference between one alert and forty when a node dies:

- `critical` suppresses `warning` for matching `alertname` + `namespace`.
- A firing `NodeDown` suppresses all other alerts originating on that node.
- `InfoInhibitor` (ships with the stack) suppresses info-level noise during any active warning.

### Watchdog → dead man's switch

The stack's built-in `Watchdog` alert fires permanently by design. It routes to a second webhook receiver hitting a healthchecks.io check URL with `repeat_interval: 5m`. Healthchecks alerts when pings **stop**.

This is the only signal for "the cluster is down" or "Prometheus itself died" — the exact state in which every other alert in this design is silent. Without it, total failure and total health are indistinguishable.

### Curated additions

One `PrometheusRule`, on top of the defaults. These encode things generic rules cannot know:

| Alert | Rationale |
|---|---|
| Wildcard TLS cert expiring < 14d | Given this repo's ACME/Pangolin CNAME history, a silent renewal failure is a realistic outage. Currently it would be discovered from a browser warning. |
| CNPG backup age exceeds schedule | A backup that quietly stops running is worth more than most infrastructure alerts. |
| PVC > 85% used | Standard capacity guard. |
| PVC projected full within 24h (trend-based) | The Immich library is the volume that will actually grow into this. |
| Blackbox probe failing | Covers both internal and public-path probes. |
| PV mount failure | A TrueNAS-side problem presents as pods stuck in `ContainerCreating`, which no default rule catches. |

## Uptime probing

`prometheus-blackbox-exporter` with `Probe` CRs for `photos.`, `grafana.`, `argocd.`, `traefik.`, module `http_2xx`. Yields status code, latency, redirect chain, and `probe_ssl_earliest_cert_expiry` — an independent read on cert expiry that does not depend on cert-manager's own metrics being correct.

### The gap in-cluster probing cannot cover

Two facts compound:

1. Split-horizon DNS means `*.koutoulastha.dev` resolves to the private IP from inside the network. An in-cluster probe reaches Traefik directly and never traverses Pangolin.
2. A dead Newt tunnel presents as a **502 served by Pangolin's own edge** — which the in-cluster probe, having bypassed that edge, never sees.

Result: the tunnel can be down indefinitely while every probe stays green.

**Mitigation:** one additional probe targeting Pangolin's **public IP directly**, with `tls_config.server_name` and a `Host` header set to the real hostname, forcing traffic through the external path. That probe failing while the internal one passes is a precise "the tunnel is down" signal.

## Exposure

**Grafana:** HTTPRoute at `grafana.koutoulastha.dev`, attaching to the existing wildcard `websecure` listener on `traefik-gateway` in `default`. Plus a Pangolin resource for the public path.

Because the wildcard cert validates at `_acme-challenge.koutoulastha.dev`, which carries no Pangolin delegation, the ACME CNAME-hijack trap documented in the README does not apply here.

Grafana configuration, given an internet-facing login page:

- `disable_signup`
- anonymous access off
- `cookie_secure`
- `root_url` set to the public hostname, so generated links and redirects do not point at an internal address
- admin password via `admin.existingSecret`, changed from the sealed default on first login

**Pangolin auth in front of Grafana as well.** Grafana's login is a reasonable barrier but should not be the only one. Pangolin already provides this; defense in depth costs nothing here.

**Prometheus and Alertmanager stay ClusterIP**, reached by port-forward. Neither has authentication, and both are more sensitive than Grafana — Prometheus exposes every metric in the cluster, Alertmanager allows silencing any alert.

## Storage and resources

| Component | Storage | Notes |
|---|---|---|
| Prometheus | 50 Gi, `truenas-iscsi` (RWO, default class) | `retention: 90d` **and** `retentionSize: 42GB` |
| Grafana | 5 Gi | SQLite DB; dashboards and users survive pod restarts |
| Alertmanager | 2 Gi | Silences and notification state |

**`retentionSize` is not optional.** Time-based retention alone does not bound disk usage: a cardinality spike fills the PVC well before 90 days elapse. A full Prometheus PVC halts TSDB writes — monitoring dies exactly when something interesting is happening. Size retention is the backstop.

**Prometheus resources:** request 2 Gi memory, limit 4 Gi. Memory scales with active series, not retention, so 90 days does not change this figure. An unbounded Prometheus is the component most likely to OOM a node, and this repo sets memory limits everywhere else.

Thin provisioning on TrueNAS means the 57 Gi total costs nothing until written.

## Rollout

Order matters; several steps fail confusingly if taken early.

1. **Register the stack Application first, alone.** Commit `kube-prometheus-stack/`, merge to `main`, then the once-only `kubectl apply -f infrastructure/monitoring/kube-prometheus-stack/application.yaml`. Nothing deploys without this — committing an `application.yaml` deploys nothing on its own. First sync is the risky one: CRD size and PodSecurity both bite here.
2. **Verify before configuring anything.** node-exporter pod count must equal node count — a missed `managedNamespaceMetadata` shows up here as desired > 0 / current 0 with no events. Then prune red targets until the target page is clean; the control-plane and kube-proxy monitors must be disabled before any of it is trustworthy.
3. **Alertmanager wiring, tested deliberately.** Seal the ntfy and healthchecks secrets. Fire a synthetic alert with `amtool` rather than waiting for a real one — an untested alert path is indistinguishable from a working one until it matters. Confirm the phone receives it and healthchecks.io shows Watchdog pings.
4. **Flip the existing ServiceMonitors** — Traefik, CNPG operator, Immich `Cluster` — one at a time, each confirmed green.
5. **Blackbox + probes**, including the public-path probe. Confirm the tunnel probe green now, so it can be trusted red later.
6. **Curated `PrometheusRule`**, added last, so your rules' noise is distinguishable from the defaults'.
7. **Grafana exposure** — HTTPRoute, then Pangolin resource. Change the admin password on first login.

### Verification uses `curl`, not a browser

Browser DNS-over-HTTPS breaks `*.koutoulastha.dev` resolution while `curl` works. Confirm `grafana.koutoulastha.dev` with `curl -I` before concluding anything is broken. This trap already cost time during the Immich rollout.

## Known failure modes

Recorded so they are recognizable rather than mysterious:

| Symptom | Cause |
|---|---|
| DaemonSet desired > 0 / current 0, no pods, no events | PodSecurity `baseline` rejecting node-exporter; missing `managedNamespaceMetadata` |
| First sync fails on CRD apply | Missing `ServerSideApply=true` |
| Permanently red control-plane targets, recurring `TargetDown` | Talos binds those metrics endpoints to `127.0.0.1` |
| Metrics stop, no alert fires | Prometheus PVC full; TSDB refusing writes. Prevented by `retentionSize` |
| All probes green while the site is unreachable externally | In-cluster probe bypassing Pangolin via split-horizon DNS. Prevented by the public-IP probe |
| Silence where alerts were expected | Alert path itself broken. Detected only by the healthchecks.io dead man's switch |

## Phase 2 (separate spec)

Loki + Alloy for log aggregation. Depends only on Grafana existing. Requires its own retention and storage sizing decisions.
