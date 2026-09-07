# Monitoring Phase 2, logging — design

**Date:** 2026-09-07
**Status:** approved, ready for implementation planning
**Scope:** Phase 2 — log aggregation with Loki and Alloy. Metrics, dashboards, alerting and uptime probes are Phase 1 and have their own spec (`2026-08-30-monitoring-design.md`).

## Goal

Phase 1 gave the cluster metrics, alerts, and a way to know the alerting still works. Metrics say a pod restarted; they never say why. This phase adds the why, and keeps it long enough to line up against the metrics that pointed at it.

Concretely, on completion:

- Pod logs from every namespace are searchable in Grafana, including logs from pods that no longer exist.
- Kubernetes Events are retained as a log stream, past the ~1h they survive in etcd.
- Traefik access logs are collected and structured, so the public edge is answerable after the fact.
- Talos node service and kernel logs reach the same place as everything else.
- Log labels match the Prometheus label vocabulary, so logs and metrics can be read side by side on one time axis.
- A small set of log-only alerts reaches the phone through the Phase 1 delivery path.
- 30-day retention, correlatable with the 90-day Prometheus.

## Non-goals

Explicitly out of scope, each for a stated reason:

| Not doing | Why |
|---|---|
| S3 / object storage backend | Filesystem on a PVC is the proven storage path in this cluster. Object storage buys durability and multi-replica reads that a single-node Loki cannot use. Revisit if retention or log volume outgrows one PVC. |
| Loki HTTPRoute / public exposure | Access is through Grafana, which already has authentication and a public path. A second internet-reachable endpoint is attack surface with no capability gained. |
| Multi-tenancy (`auth_enabled`) | One tenant, one person. It costs an `X-Scope-OrgID` header on every request and buys nothing. |
| Promtail | Deprecated by Grafana in favour of Alloy; its last chart release is stale against Alloy's active line. Starting on it in 2026 is starting on a migration. |
| Tempo / distributed tracing | Phase 3 at the earliest. Nothing in this cluster is currently instrumented for traces. |
| `grafana/k8s-monitoring` umbrella chart | Rejected during design — see Decisions. It contends with `kube-prometheus-stack` over metrics collection. |
| Log-based SLOs | Requires a stable baseline that does not exist yet. Revisit after 30 days of data. |

## Decisions

Recorded with rationale, because the reasoning is the part that decays:

1. **Loki in SingleBinary mode on a filesystem PVC**, not SimpleScalable on object storage. The scaled-out topology is nine pods and an S3 backend to serve one person's queries over one cluster's logs. The PVC path reuses `truenas-iscsi`, already proven by Prometheus and Grafana. Cost accepted: one replica, and no size-based retention backstop (see Storage and retention).

2. **Alloy, in three separate instances.** `loki.source.kubernetes_events` consumes a cluster-wide API stream, so running it in a DaemonSet produces one copy of every event per node; events need a singleton collector, and a Helm release is one controller type. The Talos receiver is separated for a different reason — it is an Experimental component and Alloy gates those per instance (see Talos node logs). So: `alloy` (DaemonSet, pod logs), `alloy-events` (Deployment, one replica), and `alloy-talos` (DaemonSet, hostNetwork, experimental, added last and droppable).

3. **`grafana/k8s-monitoring` rejected.** It would generate the Alloy config for pod logs and events from feature flags, saving real work. It is also an umbrella for metrics *and* logs, and wants to deploy its own Alloy-based metrics scraping alongside `kube-prometheus-stack` in the same namespace. The config saved is spent turning that off, and every chart upgrade re-litigates it. Paying the "inherited upstream opinions" cost once for `kube-prometheus-stack` was a good trade; paying it twice in one namespace is not.

4. **Pod logs tailed from `/var/log/pods`, not read through the API server.** `loki.source.kubernetes` reads logs via the Kubernetes API, which puts the entire cluster's log volume through the control plane and fails exactly when the API is unhealthy — the moment logs matter most. File tailing needs a hostPath mount, which the namespace already permits.

5. **Talos node logs delivered to loopback.** The `alloy-talos` DaemonSet runs `hostNetwork: true` and listens on `127.0.0.1`; nodes ship to their own node's collector. Node log delivery then depends on no Service IP, no cluster DNS, and no CNI. Given that node logs are most valuable when cluster networking is broken, a delivery path that shares fate with cluster networking would be self-defeating.

6. **Datasource shipped as a sidecar-discovered ConfigMap**, not added to `kube-prometheus-stack/values.yaml`. Grafana already runs a sidecar watching for `grafana_datasource: "1"`. This keeps the Loki Application self-contained, leaves the Phase 1 values file untouched, and means deleting the Application also removes its datasource.

7. **Under `infrastructure/monitoring/`, in the existing `monitoring` namespace.** Cluster plumbing, alongside Phase 1.

## Layout

```
infrastructure/monitoring/
  loki/
    application.yaml        # grafana/loki 7.3.0, SingleBinary
    values.yaml
    datasource.yaml         # ConfigMap, label grafana_datasource: "1"
    rules.yaml              # ConfigMap, label loki_rule: LogQL alert rules
  alloy/
    application.yaml        # grafana/alloy 1.12.1, DaemonSet, pod logs
    values.yaml
  alloy-events/
    application.yaml        # grafana/alloy 1.12.1, Deployment replicas: 1
    values.yaml             # Kubernetes Events only
  alloy-talos/              # task 6; droppable without affecting the above
    application.yaml        # grafana/alloy 1.12.1, DaemonSet, hostNetwork
    values.yaml             # Talos tcplog receivers, stabilityLevel experimental
```

Pinned versions, verified against the Grafana chart repository on 2026-09-07:

| Chart | Version | App version |
|---|---|---|
| `grafana/loki` | 7.3.0 | 3.6.11 (image tag pinned by chart values) |
| `grafana/alloy` | 1.12.1 | v1.19.2 |

Two files outside these directories change:

- `infrastructure/networking/traefik/values.yaml` — enable JSON access logging.
- `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml` — add the Loki PVC utilisation alert.

## Application shape

All four Applications follow the `blackbox-exporter` precedent exactly:

- Multi-source: upstream chart, plus a git source with `ref: values` supplying both the values file and the plain manifests in the directory. `$values` paths are relative to the repo root, never to the source's `path`.
- `directory.exclude: '{application.yaml,values.yaml}'` so the chart values and the Application itself are not also applied as manifests.
- `ServerSideApply=true`.
- Deliberately **no** `CreateNamespace=true` and **no** `managedNamespaceMetadata`. The `monitoring` namespace is owned by `kube-prometheus-stack`, which sets its PodSecurity labels; a second Application managing that namespace's metadata would contend over it. All four therefore require `kube-prometheus-stack` to be synced first, which the rollout order guarantees.

Each `application.yaml` needs a one-time manual `kubectl apply`. There is no app-of-apps in this repo; an Application that is committed but never applied deploys nothing and reports nothing.

## The thing that would have silently broken the first sync

The `alloy` DaemonSet mounts `/var/log` as hostPath, and `alloy-talos` additionally runs with `hostNetwork: true`. Under the cluster-wide `baseline` PodSecurity enforce level both are rejected **silently** — desired > 0, current 0, no pods, and no events explaining it. This is the identical failure that hit node-exporter and the CSI node DaemonSets.

It does not bite here, because `kube-prometheus-stack` already labels the `monitoring` namespace `pod-security.kubernetes.io/enforce: privileged` for node-exporter's benefit, and Alloy inherits it. This is recorded because the mitigation is invisible: nothing in the Alloy Application shows why it works, and anyone tightening that namespace label later will break log collection in a way that produces no error message.

## Loki configuration

The chart's defaults target a scaled-out cloud deployment. Every one of these is overridden deliberately:

| Chart default | Set to | Why |
|---|---|---|
| `deploymentMode: SimpleScalable` | `SingleBinary` | Nine pods for a three-node homelab |
| `singleBinary.replicas: 0` | `1` | Zero in the default mode; nothing starts otherwise |
| `loki.auth_enabled: true` | `false` | Multi-tenancy; otherwise every query needs `X-Scope-OrgID` |
| `loki.storage.type: s3` | `filesystem` | Decision 1 |
| `commonConfig.replication_factor: 3` | `1` | Three replicas of one copy on one PVC |
| `loki.schemaConfig: {}` | explicit `tsdb` / schema `v13` | **Empty in chart defaults; Loki will not start without it** |
| `chunksCache.enabled: true` | `false` | Default allocates 8192 MB of memcached — twice Prometheus's entire 4Gi limit |
| `resultsCache.enabled: true` | `false` | Another 1024 MB for one person's query volume |
| `gateway.enabled: true` | `false` | An nginx proxy in front of a single pod; the datasource reaches the Service directly |
| `lokiCanary.enabled: true` | `false` | Synthetic log prober; useful, not yet earned. Addable later. |
| `test.enabled: true` | `false` | Test pod, not wanted in a GitOps-managed namespace |
| `monitoring.serviceMonitor.enabled: false` | `true` | Monitoring infrastructure that is not itself monitored is a blind spot |
| `monitoring.serviceMonitor.metricsInstance.enabled: true` | `false` | Emits Grafana Agent Operator CRs; this cluster has no such CRDs |

With the Application named `loki`, the chart's `singleBinaryFullname` helper resolves the release name directly, so the Service is `loki.monitoring.svc.cluster.local:3100`.

## Storage and retention

30 days, on a 50Gi `truenas-iscsi` PVC — the same class and size as Prometheus, whose 90 days of metrics and 30 days of logs are comparable in volume at this scale.

Retention is `limits_config.retention_period: 720h` **plus** `compactor.retention_enabled: true`. The second flag is load-bearing: without it, `retention_period` is silently inert and nothing is ever deleted.

**Loki has no `retentionSize` equivalent.** The Phase 1 reasoning — that time-based retention alone does not bound disk, because a volume spike fills the PVC well before the retention window elapses, and a full PVC stops ingestion exactly when something interesting is happening — applies here with no chart-level remedy available. The compensation is two-part: generous sizing, and an explicit alert on Loki PVC utilisation. That alert is the backstop the chart does not provide, not a nice-to-have.

The chart's PVC lifecycle defaults are a data-loss hazard and are overridden: `enableStatefulSetAutoDeletePVC: true` with `whenDeleted: Delete` and `whenScaled: Delete` means scaling the StatefulSet to zero — an ordinary troubleshooting step — destroys the log volume.

**On RWO and rollouts:** this is a StatefulSet, not a Deployment, so the deadlock that trapped Grafana for six hours on 2026-09-01 does not apply. A StatefulSet terminates the old pod before creating its replacement under the same identity and PVC, so no `Recreate` override is needed. This is stated in the values file so that the Grafana comment is not cargo-culted into a place it does not belong.

## Collection

### Label cardinality

This is the single decision most able to wreck a Loki install, so it is explicit rather than inherited. Every distinct combination of label values is a separate stream with its own chunks; one high-cardinality label multiplies streams until write throughput and query latency collapse.

- **Stream labels** — bounded: `namespace`, `app`, `container`, `node`, `pod`, `stream` (stdout/stderr), and `level` where available.
- **Structured metadata** — parsed out of the line, queryable, never a stream key: client IP, request path, request method, duration, trace IDs.
- **Left in the log line** — everything else.

`app` is taken from the pod's owning controller name (the `app.kubernetes.io/name` label where present, falling back to the controller's name with any ReplicaSet hash suffix stripped) — never the raw pod name.

`level` is promoted only for streams whose format actually yields one, such as Traefik's JSON access logs and Talos's `talos-level` field. Arbitrary container stdout is not parsed to manufacture one. A `level` label defaulted to `unknown` across most streams costs a label dimension and answers nothing.

**`pod` is a stream label, not structured metadata.** An earlier draft of this spec put it in structured metadata on the reasoning that every restart mints a new pod name. Two things corrected that. First, the cardinality argument is weaker than it looks: `pod` is not orthogonal to the other labels — each pod belongs to exactly one namespace/app/container — so adding it does not multiply the stream count, it tracks the number of distinct pods over the retention window, which is bounded and small at this scale. Second, Alloy's `stage.structured_metadata` populates from the **extracted map** — values parsed out of the log line — and `pod` arrives as a discovery label, not an extracted value. Moving it would need a contrived pipeline to buy nothing.

The labels that genuinely are unbounded — request path and client IP — come from parsing the line, so they land in the extracted map naturally and structured metadata is exactly the right home for them. That is where this rule earns its keep.

The stream label names `namespace`, `pod` and `container` deliberately match what `kube-state-metrics` and the Phase 1 ServiceMonitors emit. That alignment is the correlation feature: it is what lets a Grafana split view put logs and metrics on one axis, and what lets a dashboard panel drill from a metric spike into the matching log stream. Divergent names for identical concepts would work and leave every correlation to be done by hand.

### Pod logs

`discovery.kubernetes` for metadata, `loki.source.file` tailing `/var/log/pods`, per decision 4. All namespaces.

### Kubernetes Events

`loki.source.kubernetes_events` in `alloy-events`, at exactly one replica, with a ClusterRole to watch events cluster-wide. The values file states that scaling this above 1 duplicates every event, because that consequence is invisible to a future reader deciding to add redundancy.

Events are collected because they are where several of this cluster's real incidents were legible and nowhere else: silent PodSecurity rejections, PVC attach failures, stalled rollouts. They expire from etcd within the hour, so by the time a problem is noticed the explanation is routinely already gone.

### Traefik access logs

Access logging is currently off entirely in `infrastructure/networking/traefik/values.yaml`. Enabled in JSON format, access logs become ordinary pod stdout and ride the DaemonSet path already built; the only addition is a pipeline stage parsing the JSON and promoting the status class and router name to labels.

Three constraints:

1. This is the **highest-volume stream by a wide margin** and will dominate the 50Gi budget. Health and metrics endpoint requests are dropped at the pipeline stage.
2. Client IP and full request path stay in the line and structured metadata, never labels. Request path as a stream label is unbounded cardinality.
3. These logs contain **client IPs from an internet-facing edge, retained for 30 days**. Recorded as a conscious choice rather than an accident of defaults.

### Talos node logs

Talos exposes two separate remote log streams, both `json_lines` only:

- **Service logs** — `machine.logging.destinations`, with `endpoint` and optional `extraTags`.
- **Kernel logs** — a `KmsgLogConfig` document.

`KmsgLogConfig` is specified rather than the `talos.logging.kernel` kernel argument, because `extraKernelArgs` take effect only on a Talos upgrade, while the config document applies on a normal config apply.

In-cluster, these are received with `otelcol.receiver.tcplog` on loopback, bridged into the same `loki.write` endpoint every other source uses.

**This runs as a fourth Application, `alloy-talos`, not in the pod-logs DaemonSet.** `otelcol.receiver.tcplog` is an **Experimental** component, and Alloy gates experimental components per instance: loading one requires setting `alloy.stabilityLevel: experimental` for the whole instance. Putting the Talos receiver in the pod-logs DaemonSet would therefore lower the stability gate on the cluster's primary log path in order to collect node logs. Isolating it means three things:

- Pod log collection stays at the default `generally-available` stability.
- The pod-logs DaemonSet needs **no `hostNetwork`** at all — loopback binding is only a Talos requirement — so its privilege surface shrinks to the `/var/log` hostPath mount.
- Task 6 becomes genuinely droppable: deleting one Application removes the entire experiment with no effect on anything else.

`alloy-talos` is itself a DaemonSet with `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet`, since each node must reach its own collector on loopback. Two ports, so the streams are distinguishable at the receiver rather than by inspecting payloads:

| Stream | Node endpoint | Talos configuration |
|---|---|---|
| Service logs | `tcp://127.0.0.1:12345/` | `machine.logging.destinations` |
| Kernel logs | `tcp://127.0.0.1:12346/` | `KmsgLogConfig` document |

Because the DaemonSet uses `hostNetwork`, these are host ports and must not collide with anything else on the node; both are outside the Kubernetes NodePort range and are checked against listening ports during task 6.

**The Talos side is an Omni machine-config change, not a commit in this repo** — the same category as the Cilium metrics note in the Phase 1 spec. The implementation plan carries the exact configuration to paste as an explicit manual step. This is why Talos is the last task: it is the only part that cannot be completed or verified from this repository, and everything else is complete and useful without it.

## Alerting

The ruler points at the existing `kube-prometheus-stack-alertmanager` Service. Nothing new is built in the delivery path: log alerts inherit the ntfy routing, the severity-to-priority mapping, the `null` receiver, the `InfoInhibitor` route, and the dead man's switch — all already built and verified in Phase 1.

Consequently, rules **must** use the same `severity` vocabulary (`critical` / `warning`). A rule with a severity outside it matches no route and is delivered nowhere, silently.

Rules are delivered as a ConfigMap labeled `loki_rule` and discovered by the chart's built-in sidecar, mirroring the datasource ConfigMap pattern. Neither requires a chart upgrade to change.

### Curated additions

Phase 1's last work was removing alerts that fired in healthy states. This set is therefore deliberately small, restricted to signals metrics cannot see, and every rule carries a `for:` duration so no single blip pages:

1. **Container panic / fatal** — a pod repeatedly logging `panic:` or a fatal-level line. Restart metrics say a pod restarted; only the log says why, and only the log catches a process that logs a fatal error without exiting.
2. **Repeated authentication failures on Grafana** — a burst of failed logins against an internet-facing login page. A log-only signal, and a security one.
3. **Log ingestion stopped** — the ruler noticing its own pipeline has gone quiet. Logging that silently stops is indistinguishable from a quiet cluster.

### Deliberately excluded

**Traefik 5xx rate.** Traefik metrics with `addRoutersLabels` already alert on this. A second alert on the same condition is two pages for one problem — exactly the noise pattern removed in the fix that closed Phase 1.

### One Phase 1 file changes

The Loki PVC utilisation alert goes into `kube-prometheus-stack/alertrules.yaml`, not the Loki ruler, because it is a Prometheus rule about Loki rather than a LogQL rule. Prometheus must be the thing that fires when Loki's disk is filling; asking Loki's own ruler to alert on Loki running out of disk fails at the exact moment it is needed.

## Rollout

Six tasks, ordered so that each is independently verifiable and no later task can invalidate an earlier one.

| # | Task | Verification |
|---|---|---|
| 1 | Loki Application, values, datasource ConfigMap | Pod `Running`; `/ready` reports ready; datasource present in Grafana and its Test passes |
| 2 | Alloy DaemonSet, pod logs | One Alloy pod per node; a LogQL query returns lines from a pod deliberately generating output |
| 3 | `alloy-events` singleton | Events queryable; a count confirms one copy per event, not one per node |
| 4 | Traefik access logs | A request through the public edge appears with parsed status; health endpoints absent |
| 5 | Ruler, rules ConfigMap, PVC alert | Rules listed by Loki's API, **and** one deliberately fired rule arrives on the phone |
| 6 | `alloy-talos` Application + Omni machine config | Service and kernel logs from every node queryable in Grafana |

### Verification means querying, not looking at a dashboard

Task 5's requirement is deliberate. Phase 1 established that an Alertmanager configuration loading successfully does not prove the alert path works; the same holds for the ruler. A rule that appears in the API has been parsed, not delivered. Only an alert arriving on the phone tests the path.

## Known failure modes

| Symptom | Cause |
|---|---|
| Loki does not start at all | `schemaConfig` is empty in chart defaults and must be spelled out |
| Disk fills; retention appears ignored | `compactor.retention_enabled` not set — `retention_period` alone is inert |
| Every query returns 401 or demands an org ID | `auth_enabled: true` chart default |
| Logs vanish after scaling the StatefulSet to zero | Chart's `enableStatefulSetAutoDeletePVC` / `whenScaled: Delete` defaults |
| Every Kubernetes Event appears N times | `alloy-events` scaled above one replica |
| Writes and queries degrade over weeks | A high-cardinality label (pod name, request path) promoted to a stream label |
| Alloy DaemonSet: desired > 0, current 0, no pods, **no events** | `baseline` PodSecurity rejecting hostPath/hostNetwork. Pre-empted only because `kube-prometheus-stack` labels the namespace `privileged` |
| Loki pod will not schedule, or OOMs a node | `chunksCache` default allocating 8192 MB |
| Sync fails on missing `MetricsInstance` CRD | `monitoring.serviceMonitor.metricsInstance.enabled` left at its `true` default |
| Application permanently `OutOfSync` with no visible diff | `ServerSideApply=true` changes how ArgoCD diffs every resource in the Application; server-defaulted fields must be spelled out. Identical to the Grafana HTTPRoute drift fixed on 2026-09-01 |
| Application committed but deploys nothing | Each `application.yaml` needs its one-time manual `kubectl apply`; there is no app-of-apps |
| Talos kernel logs never arrive despite config | `extraKernelArgs` apply only on upgrade — use the `KmsgLogConfig` document instead |
| `alloy-talos` fails to start, complaining about component stability | `otelcol.receiver.tcplog` is Experimental; the instance needs `alloy.stabilityLevel: experimental`. Set it on `alloy-talos` only — never on the pod-logs instance |

## Phase 3 (if ever)

Tempo and tracing, log-based SLOs, and object storage for logs. None are committed to; all are cheaper to add once 30 days of real log volume is known.
