# Monitoring Phase 2 (Logging) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the cluster searchable logs — pod logs, Kubernetes Events, Traefik access logs and Talos node logs — in a 30-day Loki, correlatable in Grafana against the 90-day Prometheus from Phase 1, with a small set of log-only alerts on the existing ntfy path.

**Architecture:** Four ArgoCD Applications under `infrastructure/monitoring/`: `loki` (SingleBinary on a filesystem PVC), `alloy` (DaemonSet, pod logs), `alloy-events` (Deployment at one replica, because Kubernetes Events are a cluster-wide stream that a DaemonSet would duplicate per node), and `alloy-talos` (DaemonSet with hostNetwork, added last, isolated because its receiver is an Experimental component). Task 1 stands up Loki and proves it healthy alone; Tasks 2–6 each add exactly one log source on top of a known-good base, merging to `main` and verifying before the next begins.

**Tech Stack:** Kubernetes on Talos, ArgoCD, Helm (rendered by ArgoCD, not locally), Loki 3.6.11, Grafana Alloy v1.19.2, Prometheus Operator (Phase 1), democratic-csi on TrueNAS SCALE, Traefik + Gateway API, ntfy.sh.

**Spec:** `docs/superpowers/specs/2026-09-07-monitoring-phase2-logging-design.md`

## Global Constraints

- **`main` is the deployment branch.** ArgoCD tracks `targetRevision: main`. Author on a feature branch; merge when you want a change live. Every task states its own merge point.
- **No app-of-apps.** Every `application.yaml` must be `kubectl apply`'d once by hand or it deploys nothing and reports nothing. This plan adds four.
- **The user runs all cluster commands.** `kubectl` and `helm` are **not** installed in this workspace — only `yq`, `jq`, `git`, `python3` and `curl`. Every cluster step is a copy-pasteable block for the user, and the task waits on their reported output.
- **`yq` here is the Python jq-wrapper, not yq-go.** Filters are jq syntax. **Multi-document files require `yq -s`** (slurp); without it, plain `-e` evaluates each document separately and only the *last* document sets the exit code — a silent false pass.
- **No new secrets.** Nothing in this phase needs sealing. Loki has no credentials; the ruler reaches Alertmanager in-cluster over plain HTTP.
- **Repo URL:** `https://github.com/koutoulastha/home-lab.git`
- **Chart versions, pinned exactly:** `loki` **7.3.0** (Loki 3.6.11), `alloy` **1.12.1** (Alloy v1.19.2). Never `"*"` — `selfHeal` must not upgrade a chart on its own.
- **Namespace:** `monitoring`, created and label-managed by the `kube-prometheus-stack` Application **only**. Every Application here sets **no** `CreateNamespace=true` and **no** `managedNamespaceMetadata`.
- **`ServerSideApply=true` on every Application.** It changes how ArgoCD diffs *every* resource, so server-defaulted fields must be spelled out or the Application sits permanently `OutOfSync` with no visible diff. This is the Grafana HTTPRoute drift from 2026-09-01.
- **Storage classes:** omit `storageClassName` to get `truenas-iscsi` (RWO, default, expandable), per repo convention.
- **Verify hostnames with `curl`, never a browser.** Browser DNS-over-HTTPS breaks `*.koutoulastha.dev` resolution while `curl` works.
- **Label discipline:** stream labels are `namespace`, `app`, `container`, `node`, `pod`, `stream`, and `level` where a format yields one. Request paths and client IPs go to structured metadata, never labels.
- **Derived Helm resource names** (release name = Application name), referenced throughout:
  - Loki StatefulSet/pod: `loki` / `loki-0`; Service: `loki.monitoring.svc.cluster.local:3100`
  - Alloy DaemonSet: `alloy`; events Deployment: `alloy-events`; Talos DaemonSet: `alloy-talos`
  - Alertmanager Service (Phase 1): `kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093`
  - Grafana Deployment (Phase 1): `kube-prometheus-stack-grafana`

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `infrastructure/monitoring/loki/values.yaml` | Every chart default that must be overridden, with the reason |
| `infrastructure/monitoring/loki/application.yaml` | Chart source, git values source, sync policy |
| `infrastructure/monitoring/loki/datasource.yaml` | ConfigMap consumed by Grafana's datasource sidecar |
| `infrastructure/monitoring/loki/rules.yaml` | ConfigMap consumed by Loki's ruler sidecar (Task 5) |
| `infrastructure/monitoring/alloy/values.yaml` | Alloy config for pod logs |
| `infrastructure/monitoring/alloy/application.yaml` | As above, DaemonSet |
| `infrastructure/monitoring/alloy-events/values.yaml` | Alloy config for Kubernetes Events |
| `infrastructure/monitoring/alloy-events/application.yaml` | As above, Deployment at one replica |
| `infrastructure/monitoring/alloy-talos/values.yaml` | Talos tcplog receivers, experimental stability (Task 6) |
| `infrastructure/monitoring/alloy-talos/application.yaml` | As above, DaemonSet with hostNetwork (Task 6) |

**Modified:**

| File | Change |
|---|---|
| `infrastructure/networking/traefik/values.yaml` | Add the `accessLog` block (Task 4) |
| `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml` | Add the Loki PVC utilisation alert (Task 5) |

---

### Task 1: Stand up Loki and prove it healthy in isolation

**Files:**
- Create: `infrastructure/monitoring/loki/values.yaml`
- Create: `infrastructure/monitoring/loki/application.yaml`
- Create: `infrastructure/monitoring/loki/datasource.yaml`

**Interfaces:**
- Consumes: the `monitoring` namespace and its `pod-security.kubernetes.io/enforce: privileged` label, both owned by `kube-prometheus-stack`; Grafana's datasource sidecar, which watches for the label `grafana_datasource: "1"`.
- Produces: the push endpoint `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`, which every Alloy instance in Tasks 2, 3 and 6 writes to, and the query endpoint on the same host/port that Grafana and Task 5's verification use.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-loki
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-loki`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.spec.sources[0].chart == "loki"
   and .spec.sources[0].targetRevision == "7.3.0"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["ServerSideApply=true"]))
   and (.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]) | not)
   and (.spec.syncPolicy | has("managedNamespaceMetadata") | not)' \
  infrastructure/monitoring/loki/application.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

The two negative assertions are the important ones: this Application must not touch the namespace that `kube-prometheus-stack` owns.

- [ ] **Step 3: Write `infrastructure/monitoring/loki/values.yaml`**

```yaml
# grafana/loki 7.3.0 (Loki 3.6.11).
#
# The chart's defaults target a scaled-out cloud deployment: SimpleScalable
# across nine pods, S3 storage, replication factor 3, multi-tenancy on, and
# roughly 9GB of memcached. Nearly every block below exists to turn one of
# those off. See docs/superpowers/specs/2026-09-07-monitoring-phase2-logging-design.md.

deploymentMode: SingleBinary

loki:
  # Multi-tenancy off. Left on, every query and every push needs an
  # X-Scope-OrgID header, including Grafana's and the ruler's.
  auth_enabled: false

  commonConfig:
    # Chart default is 3. There is one replica and one PVC; asking for three
    # copies of a single ingester makes writes fail, not redundant.
    replication_factor: 1

  storage:
    type: filesystem
    filesystem:
      chunks_directory: /var/loki/chunks
      rules_directory: /var/loki/rules

  # The chart ships schemaConfig as {} and Loki does not start without it.
  # tsdb + v13 is the current schema. `from` is the date this cluster first
  # writes logs; it must never be moved backwards once data exists, and a
  # future schema change is an additional list entry, never an edit of this one.
  schemaConfig:
    configs:
      # Must predate the oldest line any collector might ever replay, NOT the
      # install date. Alloy keeps its file positions in ephemeral storage, so
      # every Alloy pod restart re-tails each existing /var/log/pods file from
      # the beginning and ships lines written long before Loki existed. A line
      # older than this date is rejected with HTTP 500 "no schema config found
      # for time", and a 500 fails the WHOLE batch --- current log lines
      # batched alongside an old one are dropped with it.
      #
      # Moving this date backwards is safe on an existing install: index table
      # names are derived from absolute epoch time (schema_config.go:598,
      # `t.Unix() / periodSecs`), not relative to `from`, so already-written
      # tables keep their names and stay readable. Validate() only requires
      # that `from` values strictly increase across periods.
      - from: "2026-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h

  limits_config:
    # 30 days. Correlates against the 90-day Prometheus for the recent window
    # that actually gets investigated.
    retention_period: 720h
    # Required for the structured metadata that keeps client IPs and request
    # paths queryable without making them stream labels.
    allow_structured_metadata: true
    # Chart defaults, restated so they are visible rather than inherited.
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    volume_enabled: true

  compactor:
    working_directory: /var/loki/compactor
    # Load-bearing. Without retention_enabled the retention_period above is
    # silently inert: nothing is ever deleted, and the first symptom is a full
    # PVC weeks later. There is no retentionSize backstop in Loki the way there
    # is in Prometheus, so the alert in Task 5 is the only other guard.
    retention_enabled: true
    delete_request_store: filesystem

  server:
    http_listen_port: 3100
    grpc_listen_port: 9095

singleBinary:
  # Chart default is 0, because the default deployment mode is SimpleScalable.
  replicas: 1
  persistence:
    enabled: true
    size: 50Gi
    accessModes: ["ReadWriteOnce"]
    # storageClassName omitted on purpose: truenas-iscsi is the default class.
    #
    # The next three are a data-loss guard, not tidiness. The chart defaults to
    # enableStatefulSetAutoDeletePVC: true with whenScaled/whenDeleted: Delete,
    # so scaling this StatefulSet to zero — an ordinary troubleshooting move —
    # destroys 30 days of logs.
    enableStatefulSetAutoDeletePVC: false
    whenScaled: Retain
    whenDeleted: Retain
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 2Gi

# Zero out the replica counts of the other deployment modes. This is NOT
# optional and NOT tidiness: the chart defaults backend/read/write to 3
# replicas each, deploymentMode: SingleBinary does not zero them, and
# templates/validate.yaml:30 then refuses to render at all --- ArgoCD reports
# a ComparisonError and the Application never syncs. The chart's own
# single-binary-values.yaml carries the same block.
#
# Only these three default non-zero. Every distributed target (ingester,
# querier, distributor, compactor, ruler, indexGateway, queryFrontend,
# queryScheduler) already defaults to 0 and is deliberately not listed.
#
# NOTE: a top-level `compactor:` here would be the DISTRIBUTED compactor
# target, which is a different thing from `loki.compactor` above --- that one
# carries retention_enabled and must not be touched.
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0

# No Recreate strategy here, deliberately. This is a StatefulSet, not a
# Deployment: it terminates the old pod before creating its replacement under
# the same identity and PVC, so the RWO rollout deadlock that trapped Grafana
# for six hours on 2026-09-01 cannot occur. Do not copy the Grafana comment here.

# --- Components this cluster does not need -----------------------------------

# nginx in front of a single pod. The datasource and every Alloy instance reach
# the Service directly.
gateway:
  enabled: false

# The chart default allocates 8192MB for chunks and 1024MB for results — more
# memory than Prometheus, Grafana and Alloy combined, to cache one person's
# queries. Loki works without them; add back only if queries become slow.
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# Synthetic-log DaemonSet and a Helm test pod. Neither belongs in a
# GitOps-managed namespace yet.
lokiCanary:
  enabled: false
test:
  enabled: false

# Monitoring infrastructure that is not itself monitored is a blind spot, so
# the ServiceMonitor is on. metricsInstance must be off: it emits Grafana Agent
# Operator custom resources, and this cluster has no such CRDs — the sync fails
# on a missing MetricsInstance kind.
monitoring:
  serviceMonitor:
    enabled: true
    metricsInstance:
      enabled: false
  selfMonitoring:
    enabled: false
  rules:
    enabled: false
```

- [ ] **Step 4: Write `infrastructure/monitoring/loki/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: loki
      targetRevision: 7.3.0
      helm:
        valueFiles:
          # $values paths are always relative to the repo root, never to the
          # `path` of the source that carries the ref.
          - $values/infrastructure/monitoring/loki/values.yaml
    # One git source doing two jobs: supplying the values file above, and
    # rendering the plain manifests in this directory — datasource.yaml now,
    # rules.yaml in Task 5. Because the path is already declared here, that
    # later file syncs with no re-registration.
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/loki
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      # Deliberately NO CreateNamespace=true and no managedNamespaceMetadata.
      # The `monitoring` namespace is owned by the kube-prometheus-stack
      # Application, which sets its PodSecurity labels. A second Application
      # also managing that namespace would contend over its metadata. This
      # Application therefore requires kube-prometheus-stack to be synced
      # first, which the rollout order guarantees.
```

- [ ] **Step 5: Write `infrastructure/monitoring/loki/datasource.yaml`**

```yaml
# Picked up by the Grafana datasource sidecar that kube-prometheus-stack
# already runs, which watches for this label. Shipping the datasource from
# here rather than adding it to kube-prometheus-stack/values.yaml keeps this
# Application self-contained: deleting it removes its datasource too, and the
# Phase 1 values file is never touched.
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://loki.monitoring.svc.cluster.local:3100
        isDefault: false
        jsonData:
          # Matches limits_config.retention_period. Grafana uses it to keep
          # the time picker from offering ranges with no data behind them.
          maxLines: 5000
```

- [ ] **Step 6: Run the check and watch it pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.spec.sources[0].chart == "loki"
   and .spec.sources[0].targetRevision == "7.3.0"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["ServerSideApply=true"]))
   and (.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]) | not)
   and (.spec.syncPolicy | has("managedNamespaceMetadata") | not)' \
  infrastructure/monitoring/loki/application.yaml
```

Expected: `true`

- [ ] **Step 7: Check the values file for the settings that silently break things**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.deploymentMode == "SingleBinary"
   and .loki.auth_enabled == false
   and .loki.commonConfig.replication_factor == 1
   and .loki.storage.type == "filesystem"
   and (.loki.schemaConfig.configs | length) == 1
   and .loki.schemaConfig.configs[0].schema == "v13"
   and .loki.schemaConfig.configs[0].store == "tsdb"
   and .loki.limits_config.retention_period == "720h"
   and .loki.compactor.retention_enabled == true
   and .singleBinary.replicas == 1
   and .singleBinary.persistence.size == "50Gi"
   and .singleBinary.persistence.enableStatefulSetAutoDeletePVC == false
   and .singleBinary.persistence.whenScaled == "Retain"
   and .backend.replicas == 0
   and .read.replicas == 0
   and .write.replicas == 0
   and .chunksCache.enabled == false
   and .resultsCache.enabled == false
   and .gateway.enabled == false
   and .monitoring.serviceMonitor.enabled == true
   and .monitoring.serviceMonitor.metricsInstance.enabled == false' \
  infrastructure/monitoring/loki/values.yaml
```

Expected: `true`. If this prints `false`, find which conjunct failed by splitting the filter — do not proceed on a partial pass.

- [ ] **Step 8: Check the datasource ConfigMap carries the sidecar label**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.kind == "ConfigMap"
   and .metadata.labels["grafana_datasource"] == "1"
   and (.data["loki-datasource.yaml"] | contains("http://loki.monitoring.svc.cluster.local:3100"))' \
  infrastructure/monitoring/loki/datasource.yaml
```

Expected: `true`

- [ ] **Step 9: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/loki/
git commit -m "feat(monitoring): add Loki for log aggregation

SingleBinary on a filesystem PVC, 30d retention. Overrides the chart's
scaled-out defaults: SimpleScalable, S3 storage, replication factor 3,
multi-tenancy, and ~9GB of memcached.

Two of the overrides are load-bearing rather than tidiness: an empty
schemaConfig prevents startup entirely, and without compactor
retention_enabled the retention period is silently inert."
git push -u origin feat/logging-loki
```

Then open and merge the PR to `main`.

- [ ] **Step 10: Register the Application (once, by hand)**

There is no app-of-apps. Until this runs, the committed YAML does nothing.

```bash
kubectl apply -f https://raw.githubusercontent.com/koutoulastha/home-lab/main/infrastructure/monitoring/loki/application.yaml
kubectl -n argocd get application loki
```

Expected: the Application exists and begins syncing.

- [ ] **Step 11: Watch the sync settle**

```bash
kubectl -n argocd get application loki -w
```

Expected: `Synced` / `Healthy`. Ctrl-C once it settles.

If it sits `OutOfSync` with no visible diff, that is the `ServerSideApply` drift pattern from Phase 1 — a server-defaulted field needs spelling out. Report before changing anything.

- [ ] **Step 12: Verify the pod is running and the PVC bound**

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
kubectl -n monitoring get pvc | grep loki
```

Expected: `loki-0` `Running` `1/1`, and a bound 50Gi PVC on `truenas-iscsi`.

If the pod is `Pending` on the PVC, the storage class is the problem. If it is `CrashLoopBackOff`, get the reason — an empty `schemaConfig` reaching the pod produces a startup error naming the schema:

```bash
kubectl -n monitoring logs loki-0 --tail=50
```

- [ ] **Step 13: Confirm Loki reports ready**

The `grafana/loki` image is distroless: no shell, no `wget`, no `curl`. Every Loki API check in this plan and the tasks after it goes through a port-forward instead. Open it once and leave it running.

```bash
# Terminal A — leave this running for the rest of the rollout
kubectl -n monitoring port-forward pod/loki-0 3100:3100
```

```bash
# Terminal B
curl -s http://127.0.0.1:3100/ready
```

Expected: `ready`

A freshly started Loki reports `Ingester not ready` for a short warm-up period. Wait 30 seconds and retry before treating it as a failure.

- [ ] **Step 14: Confirm the datasource reached Grafana**

```bash
kubectl -n monitoring get configmap loki-datasource
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-datasources --tail=20
```

Expected: the ConfigMap exists, and the sidecar log shows it writing the datasource file.

- [ ] **Step 15: Report the outcome before continuing**

Report: Application sync status, pod status, PVC size and class, `/ready` output, and whether the datasource appears in Grafana under Connections → Data sources. Nothing is shipping logs yet — that is Task 2 — so an empty Loki here is the expected state, not a fault.

---

### Task 2: Collect pod logs with the Alloy DaemonSet

**Files:**
- Create: `infrastructure/monitoring/alloy/values.yaml`
- Create: `infrastructure/monitoring/alloy/application.yaml`

**Interfaces:**
- Consumes: Loki's push endpoint from Task 1; the namespace's `privileged` PodSecurity label, without which this DaemonSet is rejected with no error message.
- Produces: log streams labelled `namespace`, `app`, `container`, `node`, `pod`, `stream` — the label vocabulary Tasks 4 and 6 extend and Task 5's alert rules match on.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-alloy
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-alloy`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "daemonset"
   and .alloy.mounts.varlog == true
   and (.controller.hostNetwork // false) == false
   and (.alloy.stabilityLevel // "generally-available") == "generally-available"
   and (.alloy.configMap.content | contains("loki.write"))' \
  infrastructure/monitoring/alloy/values.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

The `hostNetwork` and `stabilityLevel` assertions are guards, not decoration: both belong to `alloy-talos` in Task 6 and must never appear on this instance.

- [ ] **Step 3: Write `infrastructure/monitoring/alloy/values.yaml`**

```yaml
# grafana/alloy 1.12.1 (Alloy v1.19.2). Pod log collection.
#
# This instance stays at the default `generally-available` stability level and
# uses no hostNetwork. The Talos receivers need both loosened, which is exactly
# why they live in a separate alloy-talos Application (Task 6) rather than here.

controller:
  type: daemonset

alloy:
  # Mounts /var/log, which is where the kubelet writes every container's stdout.
  # Combined with the hostPath this implies, it is the reason the `monitoring`
  # namespace must stay pod-security enforce: privileged. Under `baseline` this
  # DaemonSet is rejected SILENTLY — desired > 0, current 0, no pods, no events.
  mounts:
    varlog: true

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi

  configMap:
    content: |
      // ---------------------------------------------------------------------
      // Discovery: every pod in the cluster, with its metadata.
      // ---------------------------------------------------------------------
      discovery.kubernetes "pods" {
        role = "pod"
      }

      // Turn Kubernetes metadata into the stream labels, and build the path to
      // the container's log file on this node.
      //
      // Label discipline (see spec, "Label cardinality"): everything here is
      // bounded. `pod` is included because it does not multiply the stream
      // count — each pod belongs to exactly one namespace/app/container — and
      // it is what makes a crash-loop investigation navigable. Request paths
      // and client IPs are NOT labels anywhere; they are structured metadata,
      // added in Task 4 where they are actually parsed.
      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        // Must be the pod-role label. __meta_kubernetes_node_name belongs to
        // the `node` role; on a pod target it resolves to empty, and an empty
        // replacement DELETES the label rather than setting it — so the `node`
        // label silently would not exist at all.
        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "node"
        }
        // Prefer the standard app label; fall back to the controller name so
        // workloads that do not set it are still grouped by something stable.
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
          target_label  = "app"
        }
        rule {
          source_labels = ["app", "__meta_kubernetes_pod_controller_name"]
          separator     = ";"
          regex         = ";(.*)"
          target_label  = "app"
          replacement   = "$1"
        }
        // Strip the ReplicaSet hash suffix. Without this, a Deployment pod
        // with no app.kubernetes.io/name label gets app="grafana-7d8f9c4b" —
        // a value that changes on every rollout, which is an unbounded stream
        // label and exactly what the cardinality rules above exist to prevent.
        rule {
          source_labels = ["app"]
          regex         = "(.+)-[0-9a-f]{6,10}"
          target_label  = "app"
          replacement   = "$1"
        }

        // The kubelet lays these out as
        //   /var/log/pods/<namespace>_<pod>_<uid>/<container>/*.log
        // so uid + container name is enough to reach exactly one directory.
        rule {
          source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
          separator     = "/"
          action        = "replace"
          replacement   = "/var/log/pods/*$1/*.log"
          target_label  = "__path__"
        }
      }

      local.file_match "pod_logs" {
        path_targets = discovery.relabel.pod_logs.output
      }

      loki.source.file "pod_logs" {
        targets    = local.file_match.pod_logs.targets
        forward_to = [loki.process.pod_logs.receiver]
      }

      loki.process "pod_logs" {
        // The kubelet writes CRI format: "<time> <stream> <flags> <line>".
        // Without this stage every log line arrives with that prefix glued on
        // and the real timestamp is ignored in favour of ingestion time.
        stage.cri {}

        // stage.cri puts `stream` (stdout/stderr) in the extracted map; promote
        // it so stderr can be filtered on without a line-content match.
        stage.labels {
          values = {
            stream = "",
          }
        }

        // loki.source.file publishes __path__ as a `filename` label on every
        // entry (see its docs: "The __path__ value is available as the
        // filename label"). That path carries the pod UID and the log
        // rotation index, so it is unbounded twice over: a new stream on
        // every pod restart AND a new stream each time the kubelet rotates a
        // file. Nothing queries it --- namespace/app/container/pod already
        // identify the source --- so drop it before it reaches the stream key.
        stage.label_drop {
          values = ["filename"]
        }

        // Traefik access logs only. Everything else passes through untouched —
        // a selector, not a filter, so no other workload's logs are affected.
        stage.match {
          selector = "{namespace=\"traefik\", app=\"traefik\"}"

          // Drop health and metrics polling before it costs any storage. These
          // are a constant, high-rate background that answers no question
          // anyone asks 30 days later.
          stage.drop {
            expression = ".*\"RequestPath\":\"/(ping|healthz|metrics)\".*"
          }

          stage.json {
            expressions = {
              client_addr = "ClientAddr",
              method      = "RequestMethod",
              path        = "RequestPath",
              status      = "DownstreamStatus",
              router      = "RouterName",
              duration    = "Duration",
            }
          }

          // Bounded values become labels. `router` is bounded by the number of
          // HTTPRoutes; status_class is three or four values.
          // atoi returns 0 when the value is missing or non-numeric, so the
          // `< 100` branch must come first. Without it a status Traefik did
          // not record falls through to the else and is labelled 2xx — a
          // failed request silently counted as a success.
          stage.template {
            source   = "status_class"
            // The alloy chart passes configMap.content through Helm's `tpl`
            // (templates/configmap.yaml, unconditional -- there is no flag to
            // turn it off). Helm therefore evaluates this Go template BEFORE
            // Loki ever sees it, resolving .status against the chart context
            // where it does not exist, and manifest generation dies with
            // "wrong type for value; expected string; got interface {}".
            //
            // The escape below is a template action whose body is the string
            // literal for an opening delimiter: Helm evaluates it, emits the
            // two braces verbatim, and never dereferences .status. What
            // stage.template finally receives is the plain conditional.
            //
            // Do not write a bare opening delimiter anywhere in this file,
            // including in comments -- tpl parses those too.
            template = "{{ "{{" }} if lt (atoi .status) 100 }}unknown{{ "{{" }} else if ge (atoi .status) 500 }}5xx{{ "{{" }} else if ge (atoi .status) 400 }}4xx{{ "{{" }} else if ge (atoi .status) 300 }}3xx{{ "{{" }} else }}2xx{{ "{{" }} end }}"
          }
          stage.labels {
            values = {
              status_class = "",
              router       = "",
            }
          }

          // Unbounded values become structured metadata: queryable, but never
          // part of a stream key. Request path as a label would be unbounded
          // cardinality, and client_addr nearly so.
          stage.structured_metadata {
            values = {
              client_addr = "",
              path        = "",
              method      = "",
              status      = "",
              duration    = "",
            }
          }
        }

        forward_to = [loki.write.default.receiver]
      }

      // ---------------------------------------------------------------------
      // Single write path, shared by every source in this instance.
      // ---------------------------------------------------------------------
      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }

# The chart installs the PodLogs CRD used by loki.source.podlogs. This config
# discovers pods directly and never references that CRD, so the cluster does
# not need it.
crds:
  create: false

# Alloy scrapes its own metrics; Prometheus should have them, for the same
# reason Loki gets a ServiceMonitor — a broken collector otherwise looks
# identical to a quiet cluster.
serviceMonitor:
  enabled: true
```

- [ ] **Step 4: Write `infrastructure/monitoring/alloy/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: alloy
      targetRevision: 1.12.1
      helm:
        valueFiles:
          - $values/infrastructure/monitoring/alloy/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/alloy
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      # No CreateNamespace / managedNamespaceMetadata — kube-prometheus-stack
      # owns the monitoring namespace and its PodSecurity labels.
```

- [ ] **Step 5: Run the check and watch it pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "daemonset"
   and .alloy.mounts.varlog == true
   and (.controller.hostNetwork // false) == false
   and (.alloy.stabilityLevel // "generally-available") == "generally-available"
   and (.alloy.configMap.content | contains("loki.write"))' \
  infrastructure/monitoring/alloy/values.yaml
```

Expected: `true`

- [ ] **Step 6: Check the Alloy config references the right push URL and labels**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.alloy.configMap.content
       | contains("http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push")
       and contains("stage.cri")
       and contains("/var/log/pods/")' \
  infrastructure/monitoring/alloy/values.yaml
```

Expected: `true`

- [ ] **Step 7: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/alloy/
git commit -m "feat(monitoring): collect pod logs with an Alloy DaemonSet

Tails /var/log/pods rather than reading through the API server, which
would put the cluster's whole log volume through the control plane and
fail exactly when the API is unhealthy.

Stays at generally-available stability with no hostNetwork; the Talos
receivers that need both loosened get their own Application."
git push -u origin feat/logging-alloy
```

Then open and merge the PR to `main`.

- [ ] **Step 8: Register the Application (once, by hand)**

```bash
kubectl apply -f https://raw.githubusercontent.com/koutoulastha/home-lab/main/infrastructure/monitoring/alloy/application.yaml
kubectl -n argocd get application alloy -w
```

Expected: `Synced` / `Healthy`.

- [ ] **Step 9: Verify one pod per node — this is where a PodSecurity mistake surfaces**

```bash
kubectl -n monitoring get daemonset alloy
kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy -o wide
```

Expected: DESIRED = CURRENT = READY = the node count, and one pod per node.

**If DESIRED > 0 but CURRENT = 0 with no pods and no events, that is PodSecurity rejecting the hostPath mount silently.** Confirm the namespace label rather than guessing:

```bash
kubectl get namespace monitoring -o jsonpath='{.metadata.labels}' | jq
```

It must show `pod-security.kubernetes.io/enforce: privileged`. If it does not, `kube-prometheus-stack` is not managing the namespace as expected — report rather than patching the namespace by hand, because the next `kube-prometheus-stack` sync would revert it.

- [ ] **Step 10: Confirm Alloy loaded its config without error**

```bash
kubectl -n monitoring logs daemonset/alloy --tail=40
```

Expected: no `level=error` lines. A component that failed to load names itself explicitly in the error.

- [ ] **Step 11: Generate a log line you can search for**

```bash
kubectl -n default run logtest --image=busybox --restart=Never -- \
  sh -c 'echo PHASE2_CANARY_LINE; sleep 5'
sleep 20
```

- [ ] **Step 12: Prove the line reached Loki**

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="default"} |= "PHASE2_CANARY_LINE"' \
  --data limit=5 \
  | jq '.data.result[].values'
```

Expected: at least one entry containing `PHASE2_CANARY_LINE`.

An empty result means the pipeline is broken somewhere between the file and the push. Check in this order, reporting what you find: Alloy pod logs for errors, then whether the file exists on the node, then whether Loki is rejecting writes (`kubectl -n monitoring logs loki-0 --tail=50`).

- [ ] **Step 13: Confirm the stream labels are the ones intended**

```bash
curl -s http://127.0.0.1:3100/loki/api/v1/labels | jq '.data'
```

Expected: includes `namespace`, `app`, `container`, `node`, `pod`, `stream`.

Expected **absent**: anything unbounded — no `path`, no `client_ip`, no `uid`.

- [ ] **Step 14: Clean up the canary pod**

```bash
kubectl -n default delete pod logtest
```

- [ ] **Step 15: Report before continuing**

Report: DaemonSet ready count vs node count, the query result proving the canary line arrived, and the full label list from Step 13.

---

### Task 3: Collect Kubernetes Events with a singleton collector

**Files:**
- Create: `infrastructure/monitoring/alloy-events/values.yaml`
- Create: `infrastructure/monitoring/alloy-events/application.yaml`

**Interfaces:**
- Consumes: Loki's push endpoint from Task 1.
- Produces: a stream at `{job="kubernetes-events"}`, which Task 5's rules do not use but which is the first place to look when a later task's pods fail to schedule.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-events
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-events`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "deployment"
   and .controller.replicas == 1
   and .rbac.create == true
   and (.alloy.configMap.content | contains("loki.source.kubernetes_events"))' \
  infrastructure/monitoring/alloy-events/values.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 3: Write `infrastructure/monitoring/alloy-events/values.yaml`**

```yaml
# grafana/alloy 1.12.1 (Alloy v1.19.2). Kubernetes Events only.
#
# WHY THIS IS A SEPARATE APPLICATION FROM `alloy`:
# loki.source.kubernetes_events consumes a single cluster-wide API stream, not
# a per-node one. In a DaemonSet, every node would collect every event and
# Loki would receive one copy per node. A Helm release is one controller type,
# so a singleton collector has to be its own release.
#
# DO NOT SCALE THIS ABOVE ONE REPLICA. It looks like harmless redundancy and
# silently duplicates every event in the cluster.

controller:
  type: deployment
  replicas: 1

# Needs a ClusterRole to watch events across all namespaces. The chart creates
# it; this is the default, restated because turning it off breaks collection
# with a permissions error that is easy to misread as a config problem.
rbac:
  create: true

alloy:
  # No /var/log mount: this instance reads the API, not the disk. It therefore
  # needs none of the host access the DaemonSet does.
  mounts:
    varlog: false

  resources:
    requests:
      cpu: 25m
      memory: 128Mi
    limits:
      memory: 256Mi

  configMap:
    content: |
      // Cluster-wide Events. Empty namespaces list means all namespaces.
      //
      // Events live roughly an hour in etcd and then vanish. That is why this
      // exists: the explanation for an eviction, a failed volume attach, or a
      // stalled rollout is routinely already gone by the time anyone looks.
      loki.source.kubernetes_events "cluster_events" {
        job_name   = "kubernetes-events"
        forward_to = [loki.process.events.receiver]
      }

      loki.process "events" {
        // The source sets `namespace` already. Promote nothing else: event
        // `reason` is tempting but unbounded across controllers, and belongs
        // in the line where LogQL can still filter it.
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }

crds:
  create: false

serviceMonitor:
  enabled: true
```

- [ ] **Step 4: Write `infrastructure/monitoring/alloy-events/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-events
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: alloy
      targetRevision: 1.12.1
      helm:
        # Release name is the Application name, so this instance's resources
        # are alloy-events-* and cannot collide with the `alloy` DaemonSet.
        valueFiles:
          - $values/infrastructure/monitoring/alloy-events/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/alloy-events
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

- [ ] **Step 5: Run the check and watch it pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "deployment"
   and .controller.replicas == 1
   and .rbac.create == true
   and (.alloy.configMap.content | contains("loki.source.kubernetes_events"))' \
  infrastructure/monitoring/alloy-events/values.yaml
```

Expected: `true`

- [ ] **Step 6: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/alloy-events/
git commit -m "feat(monitoring): collect Kubernetes Events as a log stream

Separate Application from the alloy DaemonSet because
loki.source.kubernetes_events reads one cluster-wide API stream: in a
DaemonSet every node collects every event and Loki gets one copy per
node. Pinned to a single replica for the same reason.

Events expire from etcd within the hour, so the explanation for an
eviction or a failed volume attach is normally gone before anyone looks."
git push -u origin feat/logging-events
```

Then open and merge the PR to `main`.

- [ ] **Step 7: Register the Application (once, by hand)**

```bash
kubectl apply -f https://raw.githubusercontent.com/koutoulastha/home-lab/main/infrastructure/monitoring/alloy-events/application.yaml
kubectl -n argocd get application alloy-events -w
```

Expected: `Synced` / `Healthy`.

- [ ] **Step 8: Confirm exactly one collector pod exists**

```bash
kubectl -n monitoring get deploy alloy-events
kubectl -n monitoring get pods -l app.kubernetes.io/instance=alloy-events
```

Expected: `1/1` and exactly one pod. More than one means the replica count drifted and events are being duplicated.

- [ ] **Step 9: Generate an event with a known shape**

```bash
kubectl -n default run eventtest --image=busybox --restart=Never -- true
sleep 30
kubectl -n default delete pod eventtest
```

- [ ] **Step 10: Prove events reached Loki and are not duplicated**

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="kubernetes-events"} |= "eventtest"' \
  --data limit=100 \
  | jq '[.data.result[].values[][1]] | length as $n | {total: $n, unique: (unique | length)}'
```

Expected: `total` and `unique` are equal — every event line appears once.

If `total` is a multiple of `unique` matching the node count, the collector is running as a DaemonSet or has been scaled up. Check Step 8 again.

- [ ] **Step 11: Report before continuing**

Report: the replica count, and the total-vs-unique numbers from Step 10.

---

### Task 4: Turn on Traefik access logs and structure them

**Files:**
- Modify: `infrastructure/networking/traefik/values.yaml`
- Modify: `infrastructure/monitoring/alloy/values.yaml`

**Interfaces:**
- Consumes: the pod-log pipeline from Task 2 — access logs are Traefik's stdout, so they already arrive; this task only adds parsing.
- Produces: the labels `status_class` and `router`, plus structured metadata `client_addr`, `path`, `method`, `status`, `duration` (Traefik's raw `Duration` field, not milliseconds).

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-traefik-access
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-traefik-access`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.accessLog.enabled == true and .accessLog.format == "json"' \
  infrastructure/networking/traefik/values.yaml
```

Expected: FAIL — prints `false` (the file exists; the key does not).

- [ ] **Step 3: Append the access log block to `infrastructure/networking/traefik/values.yaml`**

Add at the end of the file, matching the existing comment style. The chart has no `logs` key — the correct root key is `accessLog`, and the chart ships `values.schema.json` with root `additionalProperties: false`, so a wrong key fails schema validation and breaks the Application's sync entirely:

```yaml
# Access logging, off by default in this chart. JSON rather than the default
# common-log format because Alloy parses it into structured metadata; the
# text format would have to be regex-matched and would lose fields.
#
# This is the highest-volume log stream in the cluster and dominates Loki's
# 50Gi budget. Health and metrics endpoints are dropped on the Alloy side
# rather than here, so that a request that 500s on /healthz is still visible
# in Traefik's own debug output if it is ever needed.
#
# The chart's default for accessLog.fields.headers.defaultMode is already
# drop, and accessLog.addInternals defaults to false so Traefik's own
# internal endpoints (api@internal, dashboard, ping) are not access-logged
# at all. Set explicitly below for clarity.
accessLog:
  enabled: true
  format: json
  fields:
    headers:
      defaultMode: drop
      names:
        # Deliberately minimal. Authorization and Cookie headers must never
        # be logged: these lines are retained for 30 days and this is an
        # internet-facing edge.
        User-Agent: keep
```

- [ ] **Step 4: Run the check and watch it pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.accessLog.enabled == true
   and .accessLog.format == "json"
   and .accessLog.fields.headers.defaultMode == "drop"' \
  infrastructure/networking/traefik/values.yaml
```

Expected: `true`

- [ ] **Step 5: Confirm the metrics block from Phase 1 is untouched**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.metrics.prometheus.addRoutersLabels == true
   and .metrics.prometheus.service.enabled == true
   and .metrics.prometheus.serviceMonitor.enabled == true' \
  infrastructure/networking/traefik/values.yaml
```

Expected: `true`. This file is shared with Phase 1; an accidental restructure here breaks metrics.

- [ ] **Step 6: Add the Traefik parsing stage to `infrastructure/monitoring/alloy/values.yaml`**

Replace the `loki.process "pod_logs"` block with the version below. The CRI and stream stages are unchanged; everything after `stage.match` is new.

```alloy
      loki.process "pod_logs" {
        stage.cri {}

        stage.labels {
          values = {
            stream = "",
          }
        }

        // Traefik access logs only. Everything else passes through untouched —
        // a selector, not a filter, so no other workload's logs are affected.
        stage.match {
          selector = "{namespace=\"traefik\", app=\"traefik\"}"

          // Drop health and metrics polling before it costs any storage. These
          // are a constant, high-rate background that answers no question
          // anyone asks 30 days later.
          stage.drop {
            expression = ".*\"RequestPath\":\"/(ping|healthz|metrics)\".*"
          }

          stage.json {
            expressions = {
              client_addr = "ClientAddr",
              method      = "RequestMethod",
              path        = "RequestPath",
              status      = "DownstreamStatus",
              router      = "RouterName",
              duration    = "Duration",
            }
          }

          // Bounded values become labels. `router` is bounded by the number of
          // HTTPRoutes; status_class is three or four values.
          // atoi returns 0 when the value is missing or non-numeric, so the
          // `< 100` branch must come first. Without it a status Traefik did
          // not record falls through to the else and is labelled 2xx — a
          // failed request silently counted as a success.
          stage.template {
            source   = "status_class"
            template = "{{ if lt (atoi .status) 100 }}unknown{{ else if ge (atoi .status) 500 }}5xx{{ else if ge (atoi .status) 400 }}4xx{{ else if ge (atoi .status) 300 }}3xx{{ else }}2xx{{ end }}"
          }
          stage.labels {
            values = {
              status_class = "",
              router       = "",
            }
          }

          // Unbounded values become structured metadata: queryable, but never
          // part of a stream key. Request path as a label would be unbounded
          // cardinality, and client_addr nearly so.
          stage.structured_metadata {
            values = {
              client_addr = "",
              path        = "",
              method      = "",
              status      = "",
              duration    = "",
            }
          }
        }

        forward_to = [loki.write.default.receiver]
      }
```

- [ ] **Step 7: Check the parsing stage is present and the label split is right**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.alloy.configMap.content
       | contains("stage.structured_metadata")
       and contains("status_class")
       and contains("ping|healthz|metrics")' \
  infrastructure/monitoring/alloy/values.yaml
```

Expected: `true`

- [ ] **Step 8: Confirm path and client_addr are not promoted to labels**

```bash
cd /home/koutoulastha/workspace/homelab
python3 - <<'EOF'
import re, yaml
c = yaml.safe_load(open('infrastructure/monitoring/alloy/values.yaml'))['alloy']['configMap']['content']
# Every stage.labels block in the file, flattened
blocks = re.findall(r'stage\.labels\s*\{(.*?)\n\s*\}', c, re.S)
banned = [k for b in blocks for k in ('path', 'client_addr', 'duration') if re.search(rf'\b{k}\s*=', b)]
print("FAIL - unbounded key promoted to a label:", banned) if banned else print("OK - no unbounded keys in stage.labels")
EOF
```

Expected: `OK - no unbounded keys in stage.labels`

- [ ] **Step 9: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/networking/traefik/values.yaml infrastructure/monitoring/alloy/values.yaml
git commit -m "feat(monitoring): collect and structure Traefik access logs

JSON access logging on Traefik, parsed by Alloy into bounded labels
(status_class, router) and structured metadata (client IP, path, method,
duration). Path and client IP are deliberately not labels: path is
unbounded cardinality and would grow stream count without limit.

Health and metrics polling is dropped before storage, and all headers
except User-Agent are dropped -- these lines are retained 30 days from
an internet-facing edge."
git push -u origin feat/logging-traefik-access
```

Then open and merge the PR to `main`.

- [ ] **Step 10: Watch both Applications resync**

```bash
kubectl -n argocd get application traefik alloy -w
```

Expected: both `Synced` / `Healthy`. Traefik restarts its pods to pick up the new config; Alloy reloads its ConfigMap.

- [ ] **Step 11: Generate a request through the public edge**

Use `curl`, not a browser — browser DNS-over-HTTPS breaks `*.koutoulastha.dev` resolution.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://grafana.koutoulastha.dev/login
curl -sS -o /dev/null -w '%{http_code}\n' https://grafana.koutoulastha.dev/definitely-not-a-real-path
sleep 20
```

Expected: `200` then `404`. The 404 is deliberate — it gives a non-2xx line to confirm `status_class` works.

- [ ] **Step 12: Confirm access logs arrive parsed**

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={app="traefik", status_class="4xx"}' \
  --data limit=5 \
  | jq '.data.result[] | {labels: .stream, sample: .values[0][1]}'
```

Expected: at least one result, its `labels` containing `status_class: "4xx"` and a `router` value, and the sample line containing the fake path.

If results come back but `status_class` is absent, the `stage.template` did not run — most likely `DownstreamStatus` is absent from the JSON, which happens if Traefik's access log format did not actually switch to JSON. Check `kubectl -n traefik logs deploy/traefik --tail=5` and report what the raw line looks like.

- [ ] **Step 13: Confirm health endpoints are being dropped**

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={app="traefik"} |= "/healthz"' \
  --data limit=5 \
  | jq '.data.result | length'
```

Expected: `0`

- [ ] **Step 14: Report before continuing**

Report: the parsed result from Step 12 including its label set, the drop-check count from Step 13, and confirmation that Traefik metrics still work (a Loki query is not enough here — check a Grafana Traefik panel or the Prometheus target page).

---

### Task 5: Wire the ruler, add curated rules, and alert on Loki's own disk

**Files:**
- Create: `infrastructure/monitoring/loki/rules.yaml`
- Modify: `infrastructure/monitoring/loki/values.yaml`
- Modify: `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml`

**Interfaces:**
- Consumes: the label vocabulary from Tasks 2 and 4; the Phase 1 Alertmanager Service and its `severity`-based routing.
- Produces: nothing later tasks depend on. This is the last task that can be completed entirely from this repo.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-alerts
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-alerts`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.metadata.labels["loki_rule"] == "1"' \
  infrastructure/monitoring/loki/rules.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 3: Add the ruler config to `infrastructure/monitoring/loki/values.yaml`**

Insert this block inside the existing top-level `loki:` mapping, after `compactor:`:

```yaml
  rulerConfig:
    wal:
      dir: /var/loki/ruler-wal
    # The rules sidecar writes files into /rules. Loki's local ruler store
    # expects <directory>/<tenant>/, and with auth_enabled: false the tenant
    # is literally "fake" — hence the sidecar folder below being /rules/fake
    # while this directory stays /rules. Getting this pair wrong loads zero
    # rule groups and reports no error.
    storage:
      type: local
      local:
        directory: /rules
    rule_path: /var/loki/rules-temp
    ring:
      kvstore:
        store: inmemory
    enable_api: true
    # The Phase 1 Alertmanager. Nothing new is built here: these alerts
    # inherit its ntfy routing, severity-to-priority mapping, null receiver,
    # InfoInhibitor route and dead man's switch.
    alertmanager_url: http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093
    enable_alertmanager_v2: true
```

And add this top-level block at the end of the file:

```yaml
# Rules arrive as a labelled ConfigMap, discovered by the chart's sidecar —
# the same pattern as the Grafana datasource. Changing a rule is then a commit,
# not a chart upgrade.
sidecar:
  rules:
    enabled: true
    label: loki_rule
    labelValue: "1"
    # Must be <rulerConfig.storage.local.directory>/<tenant>. See the comment
    # on rulerConfig.storage above.
    folder: /rules/fake
```

- [ ] **Step 4: Write `infrastructure/monitoring/loki/rules.yaml`**

```yaml
# LogQL alert rules, mounted into the ruler by the chart's rules sidecar.
#
# Deliberately small. Phase 1 closed by removing alerts that fired in healthy
# states, so every rule here is restricted to something metrics genuinely
# cannot see, and every one carries a `for:` so a single blip cannot page.
#
# The `severity` values must stay within {critical, warning}: Alertmanager's
# Phase 1 routes match on exactly those, and a rule with any other severity
# matches no route and is delivered nowhere, silently.
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-alerting-rules
  namespace: monitoring
  labels:
    loki_rule: "1"
data:
  phase2-log-alerts.yaml: |
    groups:
      - name: log-only-signals
        interval: 1m
        rules:
          # Restart metrics say a pod restarted. Only the log says why — and
          # only the log catches a process that logs a fatal error and then
          # keeps running in a broken state without ever restarting.
          #
          # `app!="loki"` is not an aesthetic exclusion, it breaks a feedback
          # loop. Loki logs about its own query execution, Alloy ships those
          # logs back into Loki, and two of those lines match this very regex:
          #
          #   1. The ruler logs every evaluation through an "insights" logger
          #      built as msg="request timings" insight=true source=loki_ruler
          #      (ruler/evaluator_local.go:38) and stamps the rule name onto it
          #      (:67). "ContainerFatalErrors" contains "Fatal", and this regex
          #      is case-insensitive, so the alert matches its own name.
          #   2. The query path logs the served query verbatim as `query=`
          #      (logql/metrics.go:151) at level=info. This expression contains
          #      the string `fatal error|FATAL`, so every evaluation — and every
          #      hand-run query using this pattern — writes a matching line.
          #
          # Left unexcluded the rule is self-sustaining: it fired continuously
          # for a day and a half on an otherwise healthy cluster, reporting ~20
          # matches per 5m against a threshold of 5, all of them its own.
          #
          # The cost is that a genuine Loki panic no longer reaches this alert.
          # That is acceptable because it is the one container here whose crash
          # is already covered by the Phase 1 restart metrics, and because a
          # broken Loki takes every rule in this file down with it anyway.
          #
          # A `!=` matcher keeps streams that carry no `app` label at all
          # (an absent label compares equal to ""), so pod streams without an
          # `app` label stay in scope.
          #
          # Talos does NOT, and never did. Talos lines arrive from alloy-talos
          # with job/service/node/level and no `namespace` label at all, and
          # `namespace=~".+"` requires at least one character, so an absent
          # namespace fails the match before `app!="loki"` is ever consulted.
          # Measured: `sum by (job) (count_over_time({namespace=~".+"}[5m]))`
          # returns only pod streams and kubernetes-events, never job="talos".
          # This alert therefore covers containers only, which is what its name
          # says, but it means a Talos kernel panic reaches nobody. Covering
          # that needs its own rule against {job="talos"} -- deliberately not
          # added here, because an alert nobody decided to want is how Phase 1
          # ended up with rules that fired in healthy states.
          - alert: ContainerFatalErrors
            expr: |
              sum by (namespace, app, container) (
                count_over_time({namespace=~".+", app!="loki"} |~ "(?i)(panic:|fatal error|FATAL)"[5m])
              ) > 5
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "{{ $labels.app }} logging fatal errors"
              description: "{{ $labels.namespace }}/{{ $labels.app }} container {{ $labels.container }} logged more than 5 panic/fatal lines in 5 minutes."

          # An internet-facing login page. Purely a log signal: Grafana emits
          # no metric for failed authentication.
          #
          # Matches the error ID Grafana actually logs, not the message it
          # shows the user. "Invalid username or password" is a public message
          # attached to the error (errutil.WithPublicMessage) and is returned
          # in the HTTP response body — it never reaches the log. The logged
          # line is msg="Failed to authenticate request" with
          # error="[password-auth.failed] ...".
          - alert: GrafanaAuthFailureBurst
            expr: |
              sum (
                count_over_time({namespace="monitoring", app="grafana"} |= "password-auth"[5m])
              ) > 10
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Burst of failed Grafana logins"
              description: "More than 10 failed Grafana login attempts in 5 minutes on an internet-facing login page."

          # Logging that silently stops looks exactly like a quiet cluster.
          # The selector must therefore match every stream, not one namespace.
          # This rule originally selected kube-system on the assumption that it
          # always produces traffic; measured on this cluster it produces about
          # 2 lines per 10 minutes, so a 15m run of zeros is its ordinary quiet
          # state and the alert fired continuously while ingestion was healthy.
          # Matching all namespaces makes the query mean what the alert claims:
          # nothing anywhere reached Loki.
          # The `or vector(0)` is load-bearing. LogQL returns no series (not a
          # zero) when nothing matches, and `empty == 0` is empty — so without
          # it this alert stays inactive through the very outage it exists to
          # catch. This is the documented Loki idiom for alerting on absence.
          - alert: LogIngestionStopped
            expr: |
              (
                sum (
                  count_over_time({namespace=~".+"}[10m])
                )
                or vector(0)
              ) == 0
            for: 15m
            labels:
              severity: critical
            annotations:
              summary: "Loki has received no logs from any namespace for 15 minutes"
              description: "Alloy or Loki has stopped ingesting. Logs are not being collected and every other log alert here is now blind."
```

- [ ] **Step 5: Add the PVC alert to `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml`**

Append this rule to the end of the existing `homelab.rules` group in that file. The existing rules sit at 8 spaces of indentation for `- alert:`, which the block below matches — the file is a single `PrometheusRule` document, so a mis-indented append breaks every Phase 1 alert, not just this one.

This task also edits the existing `PersistentVolumeFillingUp` rule (Phase 1) to exclude `persistentvolumeclaim=~"storage-loki-.*"` on both sides of its division. That rule's selector is unrestricted, so without the exclusion it and the new `LokiStorageFillingUp` both fire at `severity: warning` above 85% — two notifications for one condition. `PersistentVolumeFillingUpFast` is left untouched: it is predictive and critical, an escalation rather than a duplicate.

```yaml
        # Loki's only retention backstop. Unlike Prometheus, Loki has no
        # retentionSize setting — retention is purely by time, so a volume
        # spike fills the PVC well before 30 days elapse, and a full PVC
        # stops ingestion exactly when something interesting is happening.
        #
        # This lives here, in a Prometheus rule, rather than in Loki's own
        # ruler on purpose: asking Loki to alert on Loki running out of disk
        # fails at the moment it is needed.
        - alert: LokiStorageFillingUp
          expr: |
            (
              kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"storage-loki-.*"}
              /
              kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"storage-loki-.*"}
            ) > 0.80
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Loki PVC is over 80% full"
            description: "{{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }} full. Loki has no size-based retention: when this fills, ingestion stops."
```

- [ ] **Step 6: Run the checks and watch them pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.metadata.labels["loki_rule"] == "1"
   and (.data["phase2-log-alerts.yaml"] | contains("severity: critical"))' \
  infrastructure/monitoring/loki/rules.yaml

yq -e '.loki.rulerConfig.alertmanager_url == "http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093"
   and .loki.rulerConfig.storage.local.directory == "/rules"
   and .sidecar.rules.folder == "/rules/fake"
   and .sidecar.rules.label == "loki_rule"' \
  infrastructure/monitoring/loki/values.yaml
```

Expected: `true` from both.

- [ ] **Step 7: Confirm every rule uses a routable severity**

```bash
cd /home/koutoulastha/workspace/homelab
python3 - <<'EOF'
import yaml
cm = yaml.safe_load(open('infrastructure/monitoring/loki/rules.yaml'))
rules = yaml.safe_load(cm['data']['phase2-log-alerts.yaml'])
bad = [r['alert'] for g in rules['groups'] for r in g['rules']
       if r.get('labels', {}).get('severity') not in ('critical', 'warning')]
missing_for = [r['alert'] for g in rules['groups'] for r in g['rules'] if 'for' not in r]
print("FAIL - unroutable severity:", bad) if bad else print("OK - all severities routable")
print("FAIL - no `for:` duration:", missing_for) if missing_for else print("OK - every rule has a for:")
EOF
```

Expected: both `OK` lines.

- [ ] **Step 8: Confirm the Phase 1 rules file is still valid YAML and unbroken**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.kind == "PrometheusRule"' infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
yq -r '[.spec.groups[].rules[].alert] | join(", ")' infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
```

Expected: `true`, then a list that includes both the Phase 1 alerts and the new `LokiStorageFillingUp`.

- [ ] **Step 9: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/loki/ infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
git commit -m "feat(monitoring): wire the Loki ruler and add log-only alerts

Three LogQL rules covering what metrics cannot see: fatal errors logged
without a restart, failed-login bursts on the public Grafana, and log
ingestion stopping. All reuse the Phase 1 Alertmanager, so they inherit
its ntfy routing and severity mapping.

Also adds a Prometheus alert on Loki's PVC. Loki has no retentionSize
equivalent, so an alert is the only backstop against a full volume
halting ingestion -- and it lives in Prometheus because asking Loki to
alert on Loki running out of disk fails when it matters."
git push -u origin feat/logging-alerts
```

Then open and merge the PR to `main`.

- [ ] **Step 10: Confirm the ruler actually loaded the groups**

```bash
kubectl -n argocd get application loki -w   # wait for Synced/Healthy, then Ctrl-C
# /loki/api/v1/rules is the ruler CONFIG api and returns YAML, not JSON --
# piping it to jq fails with "Invalid numeric literal". The Prometheus-
# compatible endpoint below returns JSON and is the one that carries rule state.
curl -s http://127.0.0.1:3100/prometheus/api/v1/rules | jq '.data.groups[].name'
```

Expected: `log-only-signals`.

The sidecar syncs on its own schedule after the ConfigMap appears, so check
`kubectl -n monitoring logs loki-0 -c loki-sc-rules --tail=30` for a
`Writing /rules/fake/...` line before concluding anything is wrong. An empty
`/rules` seconds after the sync is normal.

**If it is still empty once the sidecar has logged a write, the sidecar folder and the ruler directory disagree** — that is the `/rules` vs `/rules/fake` pairing in Step 3. Check what actually landed on disk before changing config:

```bash
# the `loki` container is distroless; the rules sidecar mounts the same volume and has a shell
kubectl -n monitoring exec loki-0 -c loki-sc-rules -- ls -R /rules
```

Report what you see rather than guessing at the fix.

- [ ] **Step 11: Confirm the ruler can reach Alertmanager**

```bash
kubectl -n monitoring logs loki-0 -c loki --tail=50 | grep -i alertmanager
```

Expected: no connection errors. Silence here is fine; errors name the URL.

- [ ] **Step 12: Fire a real alert and confirm it reaches the phone**

Config loading successfully does not prove delivery — Phase 1 established this the hard way with Alertmanager. Generate enough fatal lines to cross the `ContainerFatalErrors` threshold:

```bash
kubectl -n default run fatalspam --image=busybox --restart=Never -- \
  sh -c 'for i in $(seq 1 30); do echo "FATAL synthetic phase2 alert test $i"; sleep 1; done; sleep 900'
```

Wait up to 12 minutes (5m window + 10m `for:` overlap), then check:

```bash
curl -s http://127.0.0.1:3100/prometheus/api/v1/rules \
  | jq '.data.groups[].rules[] | {name: .name, state: .state}'
```

Expected: `ContainerFatalErrors` moves `inactive` → `pending` → `firing`, and a notification arrives on the phone via ntfy.

- [ ] **Step 13: Clean up and confirm it resolves**

```bash
kubectl -n default delete pod fatalspam
```

Expected: the alert returns to `inactive` within ~10 minutes. Phase 1 set `send_resolved: false`, so no resolution notification is expected on the phone — the alert simply stops.

- [ ] **Step 14: Report before continuing**

Report: the rule group list from Step 10, the alert state transition from Step 12, and explicitly whether the ntfy notification arrived on your phone. Do not mark this task complete on the rule appearing in the API alone.

---

### Task 6: Talos node logs

**Files:**
- Create: `infrastructure/monitoring/alloy-talos/values.yaml`
- Create: `infrastructure/monitoring/alloy-talos/application.yaml`
- Change outside this repo: Talos machine config, via Omni

**Interfaces:**
- Consumes: Loki's push endpoint from Task 1.
- Produces: streams labelled `job="talos"` with `source` of `service` or `kernel`.

**This task cannot be completed from this repo alone.** The Talos half is a machine-config change applied through Omni, in the same category as the Cilium metrics note in the Phase 1 spec. Everything through Task 5 is complete and useful without it; if this task fights back, deleting the `alloy-talos` Application removes the entire experiment with no effect on anything else.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -b feat/logging-talos
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/logging-talos`

- [ ] **Step 2: Write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "daemonset"
   and .controller.hostNetwork == true
   and .controller.dnsPolicy == "ClusterFirstWithHostNet"
   and .alloy.stabilityLevel == "experimental"' \
  infrastructure/monitoring/alloy-talos/values.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 3: Write `infrastructure/monitoring/alloy-talos/values.yaml`**

```yaml
# grafana/alloy 1.12.1 (Alloy v1.19.2). Talos node service and kernel logs.
#
# WHY THIS IS A SEPARATE APPLICATION FROM `alloy`:
# otelcol.receiver.tcplog is an EXPERIMENTAL component, and Alloy gates
# experimental components per instance — loading one requires setting
# stabilityLevel below for the whole instance. Putting this receiver in the
# pod-logs DaemonSet would lower the stability gate on the cluster's primary
# log path just to collect node logs. Keeping it here also means the pod-logs
# DaemonSet needs no hostNetwork at all, and that this whole experiment can be
# deleted in one command.
#
# Ports are 12350/12351, deliberately NOT 12345/12346: the alloy chart's own
# HTTP server defaults to listenPort 12345 on 0.0.0.0, and because this
# instance runs hostNetwork that server shares a network namespace with these
# receivers. Binding 12345 here races Alloy's own server for the port; the
# readiness probe is on 12345 too, so the pod would report Ready while
# silently dropping every Talos service log.

controller:
  type: daemonset
  # Each node ships to its own node's collector on loopback, so the pod must
  # share the host's network namespace. This is the entire reason for the
  # split: delivery then depends on no Service IP, no cluster DNS and no CNI —
  # which matters because node logs are most valuable when those are broken.
  hostNetwork: true
  # Mandatory with hostNetwork. Without it the pod inherits the host resolver
  # and cannot resolve loki.monitoring.svc, so it receives logs and silently
  # fails to forward them.
  dnsPolicy: ClusterFirstWithHostNet

alloy:
  # Required for otelcol.receiver.tcplog. Set on THIS instance only — never on
  # the pod-logs `alloy` instance.
  stabilityLevel: experimental

  mounts:
    varlog: false

  resources:
    requests:
      cpu: 25m
      memory: 128Mi
    limits:
      memory: 256Mi

  configMap:
    content: |
      // ---------------------------------------------------------------------
      // Talos service logs: machine.logging.destinations -> tcp://127.0.0.1:12350
      // ---------------------------------------------------------------------
      otelcol.receiver.tcplog "talos_service" {
        listen_address = "127.0.0.1:12350"
        output {
          logs = [otelcol.processor.batch.talos.input]
        }
      }

      // ---------------------------------------------------------------------
      // Talos kernel logs: KmsgLogConfig -> tcp://127.0.0.1:12351
      // ---------------------------------------------------------------------
      otelcol.receiver.tcplog "talos_kernel" {
        listen_address = "127.0.0.1:12351"
        output {
          logs = [otelcol.processor.batch.talos.input]
        }
      }

      otelcol.processor.batch "talos" {
        output {
          logs = [otelcol.exporter.loki.talos.input]
        }
      }

      // Bridge from the OpenTelemetry pipeline into the same Loki write path
      // every other source uses, so limits and retries stay configured in one
      // place.
      otelcol.exporter.loki "talos" {
        forward_to = [loki.process.talos.receiver]
      }

      loki.process "talos" {
        // otelcol.exporter.loki does NOT hand this stage the Talos line. It
        // hands it an OTLP envelope with the line as a string inside:
        //   {"body":"{\"msg\":\"...\",\"node\":\"...\",\"talos-service\":\"...\"}"}
        // Parsing for a top-level `msg` therefore extracted nothing, every
        // stage.labels value came out empty, and the whole Talos payload ---
        // service, level and the node identity from extraTags --- stayed
        // buried in the body where no selector can reach it. Unwrap the
        // envelope first, then parse the payload out of it.
        stage.json {
          expressions = {
            body = "body",
          }
        }

        // Talos sends json_lines with msg, talos-level, talos-service and
        // talos-time present. `node` comes from the extraTags in the machine
        // config; kernel logs arrive through KmsgLogConfig, which carries no
        // extraTags, so they have neither `node` nor `talos-service` and are
        // simply left without those labels.
        stage.json {
          source = "body"
          expressions = {
            msg      = "msg",
            level    = "\"talos-level\"",
            service  = "\"talos-service\"",
            node     = "node",
          }
        }

        // Bounded: a handful of Talos services, a handful of levels, one value
        // per node.
        stage.labels {
          values = {
            level   = "",
            service = "",
            node    = "",
          }
        }

        stage.static_labels {
          values = {
            job = "talos",
          }
        }

        // Replace the OTLP envelope with the actual message.
        stage.output {
          source = "msg"
        }

        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }

crds:
  create: false

serviceMonitor:
  enabled: true
```

- [ ] **Step 4: Write `infrastructure/monitoring/alloy-talos/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-talos
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: alloy
      targetRevision: 1.12.1
      helm:
        valueFiles:
          - $values/infrastructure/monitoring/alloy-talos/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/alloy-talos
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

- [ ] **Step 5: Run the check and watch it pass**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '.controller.type == "daemonset"
   and .controller.hostNetwork == true
   and .controller.dnsPolicy == "ClusterFirstWithHostNet"
   and .alloy.stabilityLevel == "experimental"
   and (.alloy.configMap.content | contains("127.0.0.1:12350"))
   and (.alloy.configMap.content | contains("127.0.0.1:12351"))' \
  infrastructure/monitoring/alloy-talos/values.yaml
```

Expected: `true`

- [ ] **Step 6: Confirm the pod-logs instance was not contaminated**

```bash
cd /home/koutoulastha/workspace/homelab
yq -e '(.controller.hostNetwork // false) == false
   and (.alloy.stabilityLevel // "generally-available") == "generally-available"' \
  infrastructure/monitoring/alloy/values.yaml
```

Expected: `true`. The whole point of the split is that this stays true.

- [ ] **Step 7: Commit and merge**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/alloy-talos/
git commit -m "feat(monitoring): receive Talos node and kernel logs

Separate Application because otelcol.receiver.tcplog is experimental and
Alloy gates experimental components per instance -- collecting node logs
should not lower the stability gate on the cluster's primary log path.

Receives on loopback via hostNetwork so node log delivery depends on no
Service IP, no cluster DNS and no CNI, which is the point: node logs
matter most when those are broken.

Requires a matching Talos machine-config change through Omni; this
commit is inert without it."
git push -u origin feat/logging-talos
```

Then open and merge the PR to `main`.

- [ ] **Step 8: Register the Application (once, by hand)**

```bash
kubectl apply -f https://raw.githubusercontent.com/koutoulastha/home-lab/main/infrastructure/monitoring/alloy-talos/application.yaml
kubectl -n argocd get application alloy-talos -w
```

Expected: `Synced` / `Healthy`.

- [ ] **Step 9: Confirm the receivers loaded before touching any node config**

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/instance=alloy-talos -o wide
kubectl -n monitoring logs daemonset/alloy-talos --tail=40
```

Expected: one pod per node, `Running`, and no `level=error` lines.

**If the log complains about component stability**, `alloy.stabilityLevel` did not reach the pod — verify the rendered ConfigMap rather than re-editing values:

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/instance=alloy-talos -o jsonpath='{.items[0].spec.containers[0].args}'
```

Nothing has been sent yet, so an idle collector here is the expected state.

- [ ] **Step 10: Check the host ports are actually free on every node**

```bash
# The alloy image ships neither netstat nor ss, and `2>/dev/null` hides the
# "executable file not found" so the check looks like "nothing is listening".
# /proc/net/tcp needs only cat, and under hostNetwork it is the node's own
# table. Ports are hex: 303E=12350, 303F=12351, 3039=12345 (Alloy's own UI);
# 0100007F is 127.0.0.1, 00000000 is all interfaces. The awk runs locally.
kubectl -n monitoring exec daemonset/alloy-talos -- cat /proc/net/tcp \
  | awk 'NR>1 {split($2,a,":"); print a[1], a[2]}' | grep -iE '303E|303F|3039'
```

Expected: `0100007F 303E` and `0100007F 303F`. A port already in use shows as a bind
error in Step 9's logs; conversely `Starting stanza receiver` logged for both
`talos_service` and `talos_kernel` with no error after it is good evidence the
binds succeeded, since a failed bind is logged at error level.

- [ ] **Step 11: Add the Talos machine config through Omni**

This is the manual, out-of-repo step. In Omni, patch the machine config for **all** nodes:

```yaml
machine:
  logging:
    destinations:
      - endpoint: "tcp://127.0.0.1:12350/"
        format: "json_lines"
        extraTags:
          node: <this-node-name>
```

`extraTags` is not optional. Talos sends no node identity of its own, so without
it every node's logs arrive as one indistinguishable `{job="talos"}` stream and
the per-node coverage check in Step 14 cannot be satisfied — a node that stopped
shipping would look exactly like a quiet node. The value differs per machine, so
this patch is not identical across nodes.

And, as a separate config document for kernel logs:

```yaml
apiVersion: v1alpha1
kind: KmsgLogConfig
name: remote-log
url: tcp://127.0.0.1:12351/
```

`KmsgLogConfig` is used rather than the `talos.logging.kernel` kernel argument on purpose: `extraKernelArgs` take effect only on a Talos **upgrade**, while this document applies on an ordinary config apply.

Apply to one node first and confirm Step 12 before rolling to the rest.

- [ ] **Step 12: Prove node logs reached Loki**

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="talos"}' \
  --data limit=10 \
  | jq '.data.result[] | {labels: .stream, sample: .values[0][1]}'
```

Expected: entries with `job: "talos"`, a `service` label such as `machined` or `kubelet`, and a readable message.

If nothing arrives: confirm from Alloy's side first (`kubectl -n monitoring logs daemonset/alloy-talos --tail=40` — a receiver that got bytes but failed to parse says so), then confirm Talos is actually sending (`talosctl -n <node> get kmsglogconfig`). Report before changing config.

- [ ] **Step 13: Confirm both streams, service and kernel**

```bash
curl -s http://127.0.0.1:3100/loki/api/v1/label/service/values | jq '.data'
```

Expected: several Talos service names. Kernel lines arrive through `KmsgLogConfig`, which carries no `extraTags`, so they have neither a `service` nor a `node` label — query `{job="talos"}` and look for kernel-style messages to confirm the second port works.

- [ ] **Step 14: Roll out to the remaining nodes and verify coverage**

After applying the machine config to all nodes:

```bash
curl -s http://127.0.0.1:3100/loki/api/v1/label/node/values | jq '.data'
```

Expected: every node name appears.

- [ ] **Step 15: Final report**

Report: the Talos query results, which nodes are covered, and the full Application list (`kubectl -n argocd get applications`) showing all four Phase 2 Applications `Synced`/`Healthy`.

---

## Rollback

Each Application is independently removable, and removal is the intended response to any of them misbehaving:

```bash
kubectl -n argocd delete application alloy-talos    # Task 6 only
kubectl -n argocd delete application alloy-events   # Task 3 only
kubectl -n argocd delete application alloy          # stops all collection
kubectl -n argocd delete application loki           # PVC is RETAINED by design
```

Deleting `loki` leaves its PVC behind deliberately — `whenDeleted: Retain` in Task 1. To reclaim the 50Gi, delete the PVC explicitly after confirming the logs are not wanted.

Reverting Task 4 needs a commit, not a delete: remove the `accessLog` block from `infrastructure/networking/traefik/values.yaml`, since Traefik is a Phase 1 Application shared with the metrics path.
