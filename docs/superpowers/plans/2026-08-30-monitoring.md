# Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Phase 1 observability — a 90-day Prometheus, Grafana on the LAN and public via Pangolin, alerts pushed to a phone through ntfy, and uptime probes that can actually detect a dead tunnel.

**Architecture:** Two ArgoCD Applications under `infrastructure/monitoring/` — `kube-prometheus-stack` (operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) and `blackbox-exporter` (probes). Tasks 1–2 author YAML and seal secrets with nothing reaching the cluster; Task 3 registers the stack and proves it healthy in isolation; Tasks 4–8 each add one capability on top of a known-good base, merging to `main` and verifying before the next.

**Tech Stack:** Kubernetes on Talos, ArgoCD, Helm (rendered by ArgoCD, not locally), Prometheus Operator v0.93.1, blackbox_exporter v0.28.0, Gateway API (Traefik), democratic-csi on TrueNAS SCALE, sealed-secrets, ntfy.sh, healthchecks.io.

**Spec:** `docs/superpowers/specs/2026-08-30-monitoring-design.md`

## Global Constraints

- **`main` is the deployment branch.** ArgoCD tracks `targetRevision: main`. Author on `feat/monitoring`; merge when you want a change live. Tasks 3–8 each state their own merge point.
- **No app-of-apps.** Every `application.yaml` must be `kubectl apply`'d once by hand or it deploys nothing. This plan adds two.
- **The user runs all cluster commands.** `kubectl`, `helm`, and `kubeseal` are **not** installed in this workspace — only `yq`, `jq`, `git`, and `python3`. Every cluster step is a copy-pasteable block for the user, and the task waits on their reported output.
- **`yq` here is the Python jq-wrapper, not yq-go.** Filters are jq syntax. **Multi-document files require `yq -s`** (slurp); without it, plain `-e` evaluates each document separately and only the last one sets the exit code.
- **No plaintext secrets in git.** Two new sealed secrets. Sealing controller: `--controller-name sealed-secrets-controller --controller-namespace kube-system`.
- **Repo URL:** `https://github.com/koutoulastha/home-lab.git`
- **Chart versions, pinned exactly:** `kube-prometheus-stack` **88.6.1** (Prometheus Operator v0.93.1), `prometheus-blackbox-exporter` **11.17.2** (blackbox_exporter v0.28.0). Never `"*"` — `selfHeal` must not upgrade a chart on its own.
- **Namespace:** `monitoring`, created and label-managed by the `kube-prometheus-stack` Application **only**.
- **Storage classes:** omit `storageClassName` to get `truenas-iscsi` (RWO, default, expandable), per repo convention.
- **Gateway:** `traefik-gateway` in namespace `default`. Hostname `grafana.koutoulastha.dev`, covered by the existing wildcard cert — **create no Certificate resource.**
- **Verify hostnames with `curl`, never a browser.** Browser DNS-over-HTTPS breaks `*.koutoulastha.dev` resolution while `curl` works.
- **Derived Helm resource names** (release name = Application name = `kube-prometheus-stack`), referenced throughout:
  - Prometheus StatefulSet/pod: `prometheus-kube-prometheus-stack-prometheus` / `-0`
  - Alertmanager StatefulSet/pod: `alertmanager-kube-prometheus-stack-alertmanager` / `-0`
  - Services: `kube-prometheus-stack-prometheus:9090`, `kube-prometheus-stack-alertmanager:9093`, `kube-prometheus-stack-grafana:80`
  - Operator Deployment: `kube-prometheus-stack-operator`

---

### Task 1: Author the kube-prometheus-stack Application

**Files:**
- Create: `infrastructure/monitoring/kube-prometheus-stack/application.yaml`
- Create: `infrastructure/monitoring/kube-prometheus-stack/values.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: the `monitoring.coreos.com/v1` API group (`ServiceMonitor`, `PodMonitor`, `Probe`, `PrometheusRule`) that Tasks 5, 6 and 7 depend on. The `monitoring` namespace with `pod-security.kubernetes.io/enforce: privileged`. Secret names `grafana-admin` (keys `admin-user`, `admin-password`) and `alertmanager-endpoints`, both referenced here and created in Task 2.

- [ ] **Step 1: Confirm you are on the feature branch**

```bash
cd /home/koutoulastha/workspace/homelab
git rev-parse --abbrev-ref HEAD
```

Expected: `feat/monitoring`. If not: `git checkout feat/monitoring`.

- [ ] **Step 2: Write the check, and watch it fail**

```bash
yq -e '.spec.sources[0].chart == "kube-prometheus-stack"
   and .spec.sources[0].targetRevision == "88.6.1"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["ServerSideApply=true"]))
   and (.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"] == "privileged")' \
  infrastructure/monitoring/kube-prometheus-stack/application.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 3: Write `infrastructure/monitoring/kube-prometheus-stack/values.yaml`**

```yaml
# kube-prometheus-stack 88.6.1 (Prometheus Operator v0.93.1).
#
# Chart CRDs are far past the 262144-byte last-applied-configuration annotation
# that client-side apply writes, exactly like the CNPG Cluster CRD. The
# Application sets ServerSideApply=true for this reason; it is not optional.
crds:
  enabled: true

# --- Targets this cluster does not have -------------------------------------
#
# Talos binds controller-manager, scheduler and etcd metrics to 127.0.0.1, so
# Prometheus cannot reach them from a pod. The chart enables ServiceMonitors for
# all three by default; left on, they sit permanently red and fire TargetDown
# forever. Re-enable only after setting bind-address: 0.0.0.0 (and etcd's
# listen-metrics-urls) in the Talos machine config via Omni.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
# Cilium runs in kube-proxy replacement mode — there is no kube-proxy DaemonSet.
kubeProxy:
  enabled: false

# Keep the full upstream alerting rule set. Rules with no matching target are
# inert; it is unreachable *targets* that generate noise, and those are off above.
defaultRules:
  create: true

prometheus:
  prometheusSpec:
    # The chart defaults every selector to "only objects carrying this release's
    # Helm labels". That would silently ignore the Traefik ServiceMonitor, the
    # CNPG PodMonitor, our Probes and our PrometheusRule. Opening all four is
    # what makes Tasks 5, 6 and 7 work at all.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false

    retention: 90d
    # retentionSize is the backstop and is not optional. Time-based retention
    # alone does not bound disk: a cardinality spike fills the PVC well before
    # 90 days elapse, and a full PVC halts TSDB writes — monitoring dies exactly
    # when something interesting is happening. 42GB leaves headroom under 50Gi.
    retentionSize: 42GB

    # Memory scales with active series, not retention, so 90d does not change
    # this. An unbounded Prometheus is the component most likely to OOM a node.
    resources:
      requests:
        cpu: 250m
        memory: 2Gi
      limits:
        memory: 4Gi

    storageSpec:
      volumeClaimTemplate:
        spec:
          # storageClassName omitted on purpose: truenas-iscsi is the default
          # class. Thin provisioning means 50Gi costs nothing until written.
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
  # Routing is deliberately left at the chart default (everything to the "null"
  # receiver) until Task 4. Task 3 proves the stack healthy in isolation first.

grafana:
  # Password comes from the sealed secret created in Task 2. Never the chart's
  # default of "prom-operator".
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  persistence:
    enabled: true
    size: 5Gi
    accessModes: ["ReadWriteOnce"]
  # Public exposure settings (root_url, signup, cookies) are added in Task 8,
  # together with the HTTPRoute that makes them true. Until then Grafana is
  # ClusterIP-only and reachable solely by port-forward.

nodeExporter:
  enabled: true
kube-state-metrics:
  enabled: true
```

- [ ] **Step 4: Write `infrastructure/monitoring/kube-prometheus-stack/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 88.6.1
      helm:
        valueFiles:
          # $values paths are always relative to the repo root, never to the
          # `path` of the source that carries the ref.
          - $values/infrastructure/monitoring/kube-prometheus-stack/values.yaml
    # One git source doing two jobs: supplying the values file above, and
    # rendering the plain manifests in this directory (sealed secrets in Task 2,
    # alertrules.yaml in Task 7, httproute.yaml in Task 8). Because the path is
    # already declared here, those later files sync with no re-registration.
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/kube-prometheus-stack
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      # Not optional: the Prometheus Operator CRDs exceed the client-side apply
      # annotation limit and the first sync fails outright without this.
      - ServerSideApply=true
      - CreateNamespace=true
    managedNamespaceMetadata:
      labels:
        # node-exporter is a DaemonSet using hostNetwork, hostPID and hostPath
        # mounts into /proc and /sys. Under the cluster-wide `baseline` enforce
        # level it is rejected SILENTLY — desired > 0, current 0, no pods, no
        # events. Identical failure to the CSI node DaemonSets.
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/enforce-version: latest
```

- [ ] **Step 5: Run the check and watch it pass**

```bash
yq -e '.spec.sources[0].chart == "kube-prometheus-stack"
   and .spec.sources[0].targetRevision == "88.6.1"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["ServerSideApply=true"]))
   and (.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"] == "privileged")' \
  infrastructure/monitoring/kube-prometheus-stack/application.yaml
```

Expected: `true`

- [ ] **Step 6: Check the values file for the four selector overrides and retention**

```bash
yq -e '.prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues == false
   and .prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues == false
   and .prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues == false
   and .prometheus.prometheusSpec.probeSelectorNilUsesHelmValues == false
   and .prometheus.prometheusSpec.retention == "90d"
   and .prometheus.prometheusSpec.retentionSize == "42GB"
   and .kubeControllerManager.enabled == false
   and .kubeScheduler.enabled == false
   and .kubeEtcd.enabled == false
   and .kubeProxy.enabled == false
   and .grafana.admin.existingSecret == "grafana-admin"' \
  infrastructure/monitoring/kube-prometheus-stack/values.yaml
```

Expected: `true`

- [ ] **Step 7: Commit**

```bash
git add infrastructure/monitoring/kube-prometheus-stack/
git commit -m "feat(monitoring): add kube-prometheus-stack Application and values"
```

---

### Task 2: Seal the Grafana and Alertmanager secrets

**Files:**
- Create: `infrastructure/monitoring/kube-prometheus-stack/sealed-secret-grafana.yaml`
- Create: `infrastructure/monitoring/kube-prometheus-stack/sealed-secret-alertmanager.yaml`

**Interfaces:**
- Consumes: the `monitoring` namespace name and secret names declared in Task 1.
- Produces: Secret `grafana-admin` with keys `admin-user`, `admin-password`. Secret `alertmanager-endpoints` with keys `ntfy-critical-url`, `ntfy-warning-url`, `deadmans-url`, mounted by Task 4 at `/etc/alertmanager/secrets/alertmanager-endpoints/<key>`.

The spec names a single `sealed-secret.yaml`. Two files is a deliberate deviation: they are created from different sources, rotate independently, and the Application's `directory.exclude` picks up both without change.

- [ ] **Step 1: Generate the ntfy topic and build the three URLs**

The topic name **is** the credential on public ntfy.sh — anyone holding it can read your alerts and publish forgeries. Generate a long random one and keep the output of this command; you will paste it into Step 3.

Run locally (no cluster needed):

```bash
cd /home/koutoulastha/workspace/homelab
python3 - <<'PY'
import secrets, urllib.parse
topic = "homelab-" + secrets.token_urlsafe(24).replace("-", "").replace("_", "")[:24]

title   = "{{.status}}: {{.commonLabels.alertname}}"
message = "{{range .alerts}}{{.labels.alertname}} [{{.labels.namespace}}] {{.annotations.description}}\n{{end}}"

def url(priority, tags):
    q = urllib.parse.urlencode({
        "tpl": "yes",
        "title": title,
        "message": message,
        "priority": priority,
        "tags": tags,
    })
    return f"https://ntfy.sh/{topic}?{q}"

print("TOPIC (write this down):", topic)
print()
print("ntfy-critical-url:")
print(url("5", "rotating_light"))
print()
print("ntfy-warning-url:")
print(url("2", "warning"))
PY
```

Priority 5 bypasses Do Not Disturb; priority 2 arrives silently. The mapping lives in these URLs rather than in `values.yaml`, which is the one piece of routing not visible in git — it is recorded in the values comment written in Task 4.

- [ ] **Step 2: Create the healthchecks.io check**

In a browser at <https://healthchecks.io>: create a check named `homelab-watchdog`, **Period 5 minutes**, **Grace 10 minutes**. Copy its ping URL (the form `https://hc-ping.com/<uuid>`).

This is the only signal for "the cluster is down" or "Prometheus itself died" — the exact state in which every other alert in this design is silent.

- [ ] **Step 3: Seal both secrets**

Substitute the three URLs from Steps 1–2 and a strong Grafana password. Run in `devbox shell`.

**Keep the single quotes around every substituted value.** The ntfy URLs contain `&`; unquoted, the shell splits the command into background jobs and you get a half-written secret plus a pile of `No such file or directory` errors.

```bash
cd /home/koutoulastha/workspace/homelab

kubectl -n monitoring create secret generic grafana-admin \
  --dry-run=client -o yaml \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='REPLACE_WITH_STRONG_PASSWORD' \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
  > infrastructure/monitoring/kube-prometheus-stack/sealed-secret-grafana.yaml

kubectl -n monitoring create secret generic alertmanager-endpoints \
  --dry-run=client -o yaml \
  --from-literal=ntfy-critical-url='REPLACE_WITH_CRITICAL_URL' \
  --from-literal=ntfy-warning-url='REPLACE_WITH_WARNING_URL' \
  --from-literal=deadmans-url='REPLACE_WITH_HC_PING_URL' \
| kubeseal --format yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
  > infrastructure/monitoring/kube-prometheus-stack/sealed-secret-alertmanager.yaml
```

`kubectl create secret --dry-run=client` never contacts the cluster, so nothing plaintext is created in-cluster. `kubeseal` reads only the controller's public certificate.

- [ ] **Step 4: Verify the files are sealed and carry no plaintext**

```bash
yq -e '.kind == "SealedSecret"
   and .metadata.namespace == "monitoring"
   and (.spec.encryptedData | has("admin-password"))
   and (has("data") | not)' \
  infrastructure/monitoring/kube-prometheus-stack/sealed-secret-grafana.yaml

yq -e '.kind == "SealedSecret"
   and .metadata.namespace == "monitoring"
   and (.spec.encryptedData | keys | sort == ["deadmans-url","ntfy-critical-url","ntfy-warning-url"])
   and (has("data") | not)' \
  infrastructure/monitoring/kube-prometheus-stack/sealed-secret-alertmanager.yaml
```

Expected: `true` twice.

- [ ] **Step 5: Confirm nothing plaintext leaked into the working tree**

```bash
grep -RIn -e 'ntfy.sh' -e 'hc-ping.com' \
  --include='*.yaml' infrastructure/ apps/ || echo "CLEAN"
```

Expected: `CLEAN`. Any hit means a URL was pasted somewhere unsealed — remove it before committing.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/monitoring/kube-prometheus-stack/sealed-secret-grafana.yaml \
        infrastructure/monitoring/kube-prometheus-stack/sealed-secret-alertmanager.yaml
git commit -m "feat(monitoring): add sealed Grafana admin and Alertmanager endpoint secrets"
```

---

### Task 3: Roll out the stack and prove it healthy in isolation

**Files:**
- Modify: none (rollout and verification only)

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces: a running Prometheus with a clean target page — the known-good base every later task builds on.

- [ ] **Step 1: Merge to `main`**

```bash
cd /home/koutoulastha/workspace/homelab
git push -u origin feat/monitoring
gh pr create --fill --base main
gh pr merge --merge --delete-branch=false
git checkout main && git pull
```

Nothing has reached the cluster yet — committing an `application.yaml` deploys nothing on its own.

- [ ] **Step 2: Register the Application (once, by hand)**

```bash
kubectl apply -f infrastructure/monitoring/kube-prometheus-stack/application.yaml
kubectl -n argocd get application kube-prometheus-stack
```

Expected: the Application appears and begins syncing. First sync pulls large CRDs and can take several minutes.

- [ ] **Step 3: Watch the sync settle**

```bash
kubectl -n argocd get application kube-prometheus-stack \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revisions
```

Expected: `Synced` / `Healthy`.

If sync fails with an error mentioning `metadata.annotations: Too long` or `last-applied-configuration`, `ServerSideApply=true` did not take effect — recheck `.spec.syncPolicy.syncOptions` in the Application. Read the **plural** status fields; the singular ones read `<none>` for multi-source apps.

- [ ] **Step 4: Verify node-exporter — this is where a PodSecurity mistake surfaces**

```bash
kubectl get nodes --no-headers | wc -l
kubectl -n monitoring get daemonset kube-prometheus-stack-prometheus-node-exporter
kubectl get namespace monitoring -o jsonpath='{.metadata.labels}' ; echo
```

Expected: DaemonSet `DESIRED` and `READY` both equal the node count, and the namespace carries `pod-security.kubernetes.io/enforce: privileged`.

**If `DESIRED > 0` but `CURRENT` is 0 with no pods and no events, this is the silent PodSecurity rejection.** Confirm the namespace label above; if missing, `managedNamespaceMetadata` is wrong or ArgoCD has not re-applied the namespace.

- [ ] **Step 5: Verify the PVCs bound**

```bash
kubectl -n monitoring get pvc
```

Expected: three `Bound` PVCs — Prometheus 50Gi, Alertmanager 2Gi, Grafana 5Gi, all on `truenas-iscsi`.

- [ ] **Step 6: Confirm the target page is clean**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Then in another shell:

```bash
curl -sS 'http://localhost:9090/api/v1/targets?state=active' \
| jq -r '.data.activeTargets[] | select(.health != "up")
         | "\(.health)\t\(.labels.job)\t\(.lastError)"'
```

Expected: **no output.** Any line here is a target that will fire `TargetDown` forever. If `kube-controller-manager`, `kube-scheduler`, `kube-etcd` or `kube-proxy` appear, the corresponding `enabled: false` in `values.yaml` did not apply.

- [ ] **Step 7: Confirm Grafana accepts the sealed password**

With a port-forward running:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -u "admin:REPLACE_WITH_STRONG_PASSWORD" \
  http://localhost:3000/api/org
```

Expected: `200`. A `401` means Grafana is still using the chart default and `admin.existingSecret` was not honoured — check that the `grafana-admin` Secret exists (`kubectl -n monitoring get secret grafana-admin`), which proves the SealedSecret decrypted.

- [ ] **Step 8: Report the outcome before continuing**

State the node-exporter ready count, the PVC list, and that Step 6 produced no output. Do not proceed with a red target outstanding.

---

### Task 4: Wire Alertmanager to ntfy and the dead man's switch

**Files:**
- Modify: `infrastructure/monitoring/kube-prometheus-stack/values.yaml` (the `alertmanager:` block)

**Interfaces:**
- Consumes: Secret `alertmanager-endpoints` from Task 2; the running Alertmanager from Task 3.
- Produces: receivers `ntfy-critical`, `ntfy-warning`, `deadmans-switch`. Alert severity `critical` routes to high-priority push; everything else to low-priority.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -B feat/monitoring
```

- [ ] **Step 2: Write the check, and watch it fail**

```bash
yq -e '(.alertmanager.alertmanagerSpec.secrets | contains(["alertmanager-endpoints"]))
   and ([.alertmanager.config.receivers[].name] | sort
        == ["deadmans-switch","ntfy-critical","ntfy-warning"])
   and (.alertmanager.config.route.repeat_interval == "4h")' \
  infrastructure/monitoring/kube-prometheus-stack/values.yaml
```

Expected: FAIL — `false` (exit status 1), because the `alertmanager:` block currently has no `config`.

- [ ] **Step 3: Replace the `alertmanager:` block in `values.yaml`**

Replace the existing block (the one whose comment says routing is left at the chart default until Task 4) with:

```yaml
alertmanager:
  alertmanagerSpec:
    # Mounts each key at /etc/alertmanager/secrets/alertmanager-endpoints/<key>.
    secrets:
      - alertmanager-endpoints
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi

  # The routing tree stays readable in git; only the endpoints are sealed, read
  # via url_file. What the two ntfy URLs differ in, since it is not visible here:
  #   ntfy-critical-url -> priority=5 (bypasses Do Not Disturb)
  #   ntfy-warning-url  -> priority=2 (arrives silently)
  config:
    global:
      resolve_timeout: 5m

    inhibit_rules:
      # A critical alert makes its own warning redundant.
      - source_matchers: ['severity = "critical"']
        target_matchers: ['severity = "warning"']
        equal: [alertname, namespace]
      # A node that is gone explains everything else reported about that node.
      # This only suppresses alerts that carry a `node` label; alerts labelled
      # only with `instance` are not matched and will still fire.
      - source_matchers: ['alertname =~ "KubeNodeNotReady|KubeNodeUnreachable"']
        target_matchers: ['severity =~ "warning|critical"']
        equal: [node]
      # Ships with the stack: silences info-level noise during any active warning.
      - source_matchers: ['alertname = "InfoInhibitor"']
        target_matchers: ['severity = "info"']
        equal: [namespace]

    route:
      group_by: [alertname, namespace]
      group_wait: 30s
      group_interval: 5m
      # An unresolved problem nags four times a day, not every five minutes.
      repeat_interval: 4h
      receiver: ntfy-warning
      routes:
        # Watchdog fires permanently by design. Healthchecks.io alerts when
        # these pings STOP — the only signal for total cluster or Prometheus
        # failure, in which state every other alert here is silent.
        - receiver: deadmans-switch
          matchers: ['alertname = "Watchdog"']
          group_wait: 0s
          group_interval: 5m
          repeat_interval: 5m
        - receiver: ntfy-critical
          matchers: ['severity = "critical"']

    receivers:
      - name: ntfy-warning
        webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-endpoints/ntfy-warning-url
            send_resolved: true
      - name: ntfy-critical
        webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-endpoints/ntfy-critical-url
            send_resolved: true
      - name: deadmans-switch
        webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-endpoints/deadmans-url
            send_resolved: false
```

- [ ] **Step 4: Run the check and watch it pass**

```bash
yq -e '(.alertmanager.alertmanagerSpec.secrets | contains(["alertmanager-endpoints"]))
   and ([.alertmanager.config.receivers[].name] | sort
        == ["deadmans-switch","ntfy-critical","ntfy-warning"])
   and (.alertmanager.config.route.repeat_interval == "4h")
   and ([.alertmanager.config.receivers[].webhook_configs[0].url_file]
        | map(startswith("/etc/alertmanager/secrets/alertmanager-endpoints/")) | all)' \
  infrastructure/monitoring/kube-prometheus-stack/values.yaml
```

Expected: `true`

- [ ] **Step 5: Commit and merge**

```bash
git add infrastructure/monitoring/kube-prometheus-stack/values.yaml
git commit -m "feat(monitoring): route Alertmanager to ntfy with a dead man's switch"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
git checkout main && git pull
```

- [ ] **Step 6: Confirm the secret mounted and the config loaded**

```bash
kubectl -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager

kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager \
  -- ls /etc/alertmanager/secrets/alertmanager-endpoints/
```

Expected: `deadmans-url`, `ntfy-critical-url`, `ntfy-warning-url`.

```bash
kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --tail=30
```

Expected: `Completed loading of configuration file`, with no `error` lines.

- [ ] **Step 7: Fire a synthetic critical alert**

An untested alert path is indistinguishable from a working one right up until you need it.

Note the annotation quoting: the value contains spaces, so it must be double-quoted *inside* a
single-quoted argument. Written as `--annotation=description="..."` the shell strips the inner
quotes and amtool's matcher parser rejects it, falling back to a legacy parser with a warning.

A clean `Completed loading of configuration file` in the Alertmanager log is NOT evidence the
alert path works: `url_file` is resolved at notification time, not at config load, so a missing
secret file starts up silently and only fails when an alert actually fires. This smoke test is
the first thing that proves delivery end to end.

```bash
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add \
    alertname=PlanSmokeTest severity=critical namespace=monitoring \
    --annotation='description="synthetic critical test"' \
    --alertmanager.url=http://localhost:9093
```

Expected: the phone receives a high-priority ntfy notification titled `firing: PlanSmokeTest` within about 30 seconds (`group_wait`).

Subscribe the phone first: install the ntfy app and subscribe to the topic from Task 2 Step 1.

- [ ] **Step 8: Fire a synthetic warning and confirm the priority difference**

```bash
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add \
    alertname=PlanSmokeTestWarning severity=warning namespace=monitoring \
    --annotation='description="synthetic warning test"' \
    --alertmanager.url=http://localhost:9093
```

Expected: a notification that arrives **silently** — no sound, no DND bypass.

- [ ] **Step 9: Confirm the dead man's switch is being pinged**

Open the healthchecks.io check created in Task 2. Expected: status **up**, last ping within the past 5 minutes.

If it is still "never pinged" after 10 minutes, the `Watchdog` route is not matching — check `amtool alert query --alertmanager.url=http://localhost:9093` from inside the pod for a firing `Watchdog`.

- [ ] **Step 10: Report before continuing**

Confirm: critical push received, warning push received silently, healthchecks.io showing pings.

---

### Task 5: Enable metrics on the components already in this repo

**Files:**
- Modify: `infrastructure/networking/traefik/values.yaml`
- Modify: `infrastructure/cert-manager/values.yaml`
- Modify: `infrastructure/database/cloudnative-pg/values.yaml:11-13`
- Modify: `apps/immich/db/cluster.yaml`

**Interfaces:**
- Consumes: the open selectors from Task 1 (without `serviceMonitorSelectorNilUsesHelmValues: false` none of these are picked up).
- Produces: metrics `traefik_*`, `certmanager_certificate_expiration_timestamp_seconds`, `cnpg_collector_*` — consumed by the alert rules in Task 7.

Flip one at a time and confirm each target goes green. A mistyped label selector fails by the target simply never appearing, not by erroring.

- [ ] **Step 1: Branch**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -B feat/monitoring
```

- [ ] **Step 2: Write the check, and watch it fail**

```bash
yq -e '.metrics.prometheus.serviceMonitor.enabled == true
   and .metrics.prometheus.service.enabled == true
   and .metrics.prometheus.addRoutersLabels == true' \
  infrastructure/networking/traefik/values.yaml
```

Expected: FAIL — `false` (exit status 1); there is no `metrics:` key in that file yet.

- [ ] **Step 3: Append the metrics block to `infrastructure/networking/traefik/values.yaml`**

```yaml
# Prometheus metrics. `service.enabled` creates the dedicated metrics Service
# the ServiceMonitor scrapes; without it the ServiceMonitor has no endpoints.
# addRoutersLabels is off by default and is what yields per-HTTPRoute request
# rate, latency and status codes — the highest-value signal in the cluster,
# since every service is reached through Traefik.
metrics:
  prometheus:
    addRoutersLabels: true
    service:
      enabled: true
    serviceMonitor:
      enabled: true
```

- [ ] **Step 4: Run the check and watch it pass**

```bash
yq -e '.metrics.prometheus.serviceMonitor.enabled == true
   and .metrics.prometheus.service.enabled == true
   and .metrics.prometheus.addRoutersLabels == true' \
  infrastructure/networking/traefik/values.yaml
```

Expected: `true`

- [ ] **Step 5: Append the metrics block to `infrastructure/cert-manager/values.yaml`**

```yaml
# Exposes certmanager_certificate_expiration_timestamp_seconds, which the
# curated "wildcard cert expiring" alert in Task 7 depends on. Note the chart
# spells this key `servicemonitor`, all lowercase.
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
```

- [ ] **Step 6: Flip the CNPG operator PodMonitor**

In `infrastructure/database/cloudnative-pg/values.yaml`, replace:

```yaml
# No Prometheus Operator in this cluster.
monitoring:
  podMonitorEnabled: false
```

with:

```yaml
# Prometheus Operator is installed (infrastructure/monitoring/kube-prometheus-stack).
monitoring:
  podMonitorEnabled: true
```

- [ ] **Step 7: Enable the PodMonitor on the Immich Postgres cluster**

In `apps/immich/db/cluster.yaml`, add under `spec:` (sibling of `instances`):

```yaml
  # Postgres connection counts, replication state and backup age. The backup-age
  # metric is what the curated "backup stopped running" alert in Task 7 reads.
  monitoring:
    enablePodMonitor: true
```

- [ ] **Step 8: Verify all four edits**

```bash
yq -e '.prometheus.servicemonitor.enabled == true' infrastructure/cert-manager/values.yaml
yq -e '.monitoring.podMonitorEnabled == true' infrastructure/database/cloudnative-pg/values.yaml
yq -e '.spec.monitoring.enablePodMonitor == true' apps/immich/db/cluster.yaml
grep -c 'No Prometheus Operator in this cluster' infrastructure/database/cloudnative-pg/values.yaml || echo "comment removed: good"
```

Expected: `true` three times, then `comment removed: good`.

- [ ] **Step 9: Commit and merge**

```bash
git add infrastructure/networking/traefik/values.yaml \
        infrastructure/cert-manager/values.yaml \
        infrastructure/database/cloudnative-pg/values.yaml \
        apps/immich/db/cluster.yaml
git commit -m "feat(monitoring): enable ServiceMonitors on traefik, cert-manager, CNPG and Immich"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
git checkout main && git pull
```

- [ ] **Step 10: Confirm the monitors exist and every new target is up**

```bash
kubectl get servicemonitor,podmonitor -A
```

Expected: a Traefik ServiceMonitor, a cert-manager ServiceMonitor, a CNPG operator PodMonitor, and an Immich Postgres PodMonitor.

With a Prometheus port-forward running:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

```bash
curl -sS 'http://localhost:9090/api/v1/targets?state=active' \
| jq -r '.data.activeTargets[] | select(.health != "up")
         | "\(.health)\t\(.labels.job)\t\(.lastError)"'
```

Expected: **no output.**

- [ ] **Step 11: Confirm the metrics the Task 7 rules depend on actually exist**

```bash
for q in 'traefik_router_requests_total' \
         'certmanager_certificate_expiration_timestamp_seconds' \
         'cnpg_collector_last_available_backup_timestamp'; do
  printf '%s => ' "$q"
  curl -sS --get 'http://localhost:9090/api/v1/query' --data-urlencode "query=$q" \
  | jq -r '.data.result | length'
done
```

Expected: a non-zero count for each. A zero means the rule written against it in Task 7 can never fire — resolve it here, not there.

---

### Task 6: Blackbox exporter and probes, including the tunnel blind spot

**Files:**
- Create: `infrastructure/monitoring/blackbox-exporter/application.yaml`
- Create: `infrastructure/monitoring/blackbox-exporter/values.yaml`
- Create: `infrastructure/monitoring/blackbox-exporter/probes.yaml`

**Interfaces:**
- Consumes: the `Probe` CRD and open `probeSelector` from Task 1; the `monitoring` namespace from Task 3.
- Produces: Service `blackbox-exporter:9115` in `monitoring`; metric `probe_success` labelled `instance` per target, and `probe_ssl_earliest_cert_expiry` — both consumed by Task 7.

- [ ] **Step 1: Find Pangolin's public IP**

The tunnel probe needs the address the outside world reaches, which is Pangolin's edge, not your WAN IP.

```bash
dig +short photos.koutoulastha.dev @1.1.1.1
```

Expected: a single public IPv4. Use a **public** resolver — the LAN resolver is authoritative for this split-horizon zone and returns the private address. Record this value; it is substituted in Step 4.

- [ ] **Step 2: Branch and write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -B feat/monitoring

yq -e '.spec.sources[0].chart == "prometheus-blackbox-exporter"
   and .spec.sources[0].targetRevision == "11.17.2"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]) | not)' \
  infrastructure/monitoring/blackbox-exporter/application.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 3: Write `infrastructure/monitoring/blackbox-exporter/values.yaml`**

```yaml
# prometheus-blackbox-exporter 11.17.2 (blackbox_exporter v0.28.0).
#
# Predictable Service name. Without this the chart derives
# blackbox-exporter-prometheus-blackbox-exporter, which every Probe below
# would have to spell out.
fullnameOverride: blackbox-exporter

resources:
  requests:
    cpu: 25m
    memory: 32Mi
  limits:
    memory: 64Mi

config:
  modules:
    # Standard in-cluster probe. Split-horizon DNS means these hostnames resolve
    # to the private address from here, so this module tests Traefik directly.
    http_2xx:
      prober: http
      timeout: 5s
      http:
        valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
        follow_redirects: true
        preferred_ip_protocol: ip4

    # Probes the PUBLIC path by connecting straight to Pangolin's edge IP.
    # Two facts make this necessary: split-horizon DNS sends the in-cluster
    # probe to the private address, and a dead Newt tunnel presents as a 502
    # served by Pangolin's own edge — which a probe that bypassed that edge
    # never sees. Without this, the tunnel can be down for a week with every
    # other probe green.
    #
    # Connecting by IP means SNI and Host must both be forced to the real
    # hostname, or TLS fails on a name mismatch before HTTP is reached.
    http_2xx_pangolin:
      prober: http
      timeout: 10s
      http:
        valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
        follow_redirects: true
        preferred_ip_protocol: ip4
        headers:
          Host: photos.koutoulastha.dev
        tls_config:
          server_name: photos.koutoulastha.dev
```

- [ ] **Step 4: Write `infrastructure/monitoring/blackbox-exporter/probes.yaml`**

Substitute the IP from Step 1 for `PANGOLIN_PUBLIC_IP`.

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: public-hosts-internal
  namespace: monitoring
spec:
  interval: 60s
  module: http_2xx
  prober:
    url: blackbox-exporter:9115
  targets:
    staticConfig:
      static:
        - https://photos.koutoulastha.dev
        - https://grafana.koutoulastha.dev
        - https://argocd.koutoulastha.dev
        - https://traefik.koutoulastha.dev
---
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: pangolin-tunnel
  namespace: monitoring
spec:
  interval: 60s
  module: http_2xx_pangolin
  prober:
    url: blackbox-exporter:9115
  targets:
    staticConfig:
      static:
        # Pangolin's public edge, by IP. This probe failing while
        # public-hosts-internal passes is a precise "the tunnel is down" signal.
        - https://PANGOLIN_PUBLIC_IP/
      labels:
        path: pangolin-public
```

`grafana.koutoulastha.dev` is probed before Task 8 creates its HTTPRoute, so that probe reports down until Task 8 completes. That is expected and is the probe proving it works.

- [ ] **Step 5: Write `infrastructure/monitoring/blackbox-exporter/application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: blackbox-exporter
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: prometheus-blackbox-exporter
      targetRevision: 11.17.2
      helm:
        valueFiles:
          - $values/infrastructure/monitoring/blackbox-exporter/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/blackbox-exporter
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      # Deliberately NO CreateNamespace=true and no managedNamespaceMetadata.
      # The `monitoring` namespace is owned by the kube-prometheus-stack
      # Application, which sets its PodSecurity labels. A second Application
      # also managing that namespace would contend over its metadata. This
      # Application therefore requires kube-prometheus-stack to be synced first,
      # which the rollout order guarantees.
      - ServerSideApply=true
```

- [ ] **Step 6: Run the checks and watch them pass**

```bash
yq -e '.spec.sources[0].chart == "prometheus-blackbox-exporter"
   and .spec.sources[0].targetRevision == "11.17.2"
   and .spec.destination.namespace == "monitoring"
   and (.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]) | not)' \
  infrastructure/monitoring/blackbox-exporter/application.yaml

yq -s -e '([.[] | select(.kind == "Probe")] | length == 2)
   and ([.[].spec.prober.url] | map(. == "blackbox-exporter:9115") | all)
   and ([.[].spec.module] | sort == ["http_2xx","http_2xx_pangolin"])' \
  infrastructure/monitoring/blackbox-exporter/probes.yaml
```

Expected: `true` twice. `probes.yaml` is multi-document, which is why the second uses `-s`.

- [ ] **Step 7: Confirm the placeholder was substituted**

```bash
grep -n 'PANGOLIN_PUBLIC_IP' infrastructure/monitoring/blackbox-exporter/probes.yaml \
  && echo "PLACEHOLDER STILL PRESENT — substitute the IP from Step 1" \
  || echo "substituted: good"
```

Expected: `substituted: good`

- [ ] **Step 8: Commit, merge, and register**

```bash
git add infrastructure/monitoring/blackbox-exporter/
git commit -m "feat(monitoring): add blackbox exporter with internal and tunnel probes"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
git checkout main && git pull

kubectl apply -f infrastructure/monitoring/blackbox-exporter/application.yaml
kubectl -n argocd get application blackbox-exporter
```

- [ ] **Step 9: Verify the probes are reporting**

With a Prometheus port-forward running:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

```bash
curl -sS --get 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=probe_success' \
| jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
```

Expected: five rows. `photos.`, `argocd.` and `traefik.` report `1`; `grafana.` reports `0` until Task 8; the Pangolin IP target reports `1`.

**If the Pangolin target reports `0`,** check for a TLS name mismatch before assuming the tunnel is down:

```bash
curl -sS --get 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=probe_http_ssl' | jq -r '.data.result[] | "\(.metric.instance) \(.value[1])"'
```

- [ ] **Step 10: Report which targets are up before continuing**

---

### Task 7: Curated alert rules

**Files:**
- Create: `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml`

**Interfaces:**
- Consumes: metrics verified present in Task 5 Step 11 and Task 6 Step 9; the open `ruleSelector` from Task 1.
- Produces: `PrometheusRule` named `homelab-curated` in `monitoring`, group `homelab.rules`.

Added last so your rules' noise is distinguishable from the upstream defaults'.

- [ ] **Step 1: Branch and write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -B feat/monitoring

yq -e '.kind == "PrometheusRule"
   and .metadata.namespace == "monitoring"
   and ([.spec.groups[0].rules[].alert] | length == 6)' \
  infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 2: Write `infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: homelab-curated
  namespace: monitoring
spec:
  groups:
    - name: homelab.rules
      rules:
        # The repo's ACME/Pangolin CNAME history makes a silent renewal failure
        # a realistic outage. Without this it is discovered from a browser
        # warning, after the fact.
        - alert: CertificateExpiringSoon
          expr: |
            (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
          for: 1h
          labels:
            severity: critical
          annotations:
            description: >-
              Certificate {{ $labels.name }} in {{ $labels.namespace }} expires in
              {{ $value | printf "%.1f" }} days. Check for a stuck DNS-01 challenge
              with `dig CNAME _acme-challenge.<host>`, never a bare `dig TXT`.

        # A backup that quietly stops running is worth more than most
        # infrastructure alerts. The schedule is daily at 02:30; 30h allows one
        # missed run plus slack before alerting.
        - alert: PostgresBackupStale
          expr: |
            time() - cnpg_collector_last_available_backup_timestamp > 108000
          for: 30m
          labels:
            severity: critical
          annotations:
            description: >-
              No successful CNPG backup for cluster {{ $labels.pod }} in over 30
              hours. Check `kubectl -n immich get backups.postgresql.cnpg.io`.

        - alert: PersistentVolumeFillingUp
          expr: |
            kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
          for: 15m
          labels:
            severity: warning
          annotations:
            description: >-
              PVC {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }} is
              {{ $value | humanizePercentage }} full.

        # Trend-based: catches the Immich library growing into its volume before
        # the static threshold would, and catches sudden growth the 85% rule
        # would only report once it is already too late to act calmly.
        - alert: PersistentVolumeFillingUpFast
          expr: |
            predict_linear(kubelet_volume_stats_available_bytes[6h], 24 * 3600) < 0
          for: 1h
          labels:
            severity: critical
          annotations:
            description: >-
              PVC {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }} is
              projected to be full within 24 hours at the current rate.

        - alert: BlackboxProbeFailed
          expr: probe_success == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            description: >-
              Probe of {{ $labels.instance }} has been failing for 5 minutes. If
              only the pangolin-public target is down, the Newt tunnel is dead
              (check UDP 51820); if only the internal targets are down, Traefik
              or the backing service is.

        # A TrueNAS-side storage problem presents as pods stuck in
        # ContainerCreating rather than as anything the default rules catch.
        - alert: PodStuckContainerCreating
          expr: |
            kube_pod_container_status_waiting_reason{reason="ContainerCreating"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            description: >-
              Pod {{ $labels.namespace }}/{{ $labels.pod }} has been stuck in
              ContainerCreating for 15 minutes. Commonly an iSCSI or NFS mount
              failure — check the democratic-csi node pod on that node.
```

- [ ] **Step 3: Run the check and watch it pass**

```bash
yq -e '.kind == "PrometheusRule"
   and .metadata.namespace == "monitoring"
   and ([.spec.groups[0].rules[].alert] | length == 6)
   and ([.spec.groups[0].rules[].labels.severity] | map(. == "critical" or . == "warning") | all)
   and ([.spec.groups[0].rules[].annotations.description] | map(length > 0) | all)' \
  infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
```

Expected: `true`

- [ ] **Step 4: Commit and merge**

```bash
git add infrastructure/monitoring/kube-prometheus-stack/alertrules.yaml
git commit -m "feat(monitoring): add curated homelab alert rules"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
git checkout main && git pull
```

- [ ] **Step 5: Confirm Prometheus loaded the group**

With a Prometheus port-forward running:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

```bash
curl -sS 'http://localhost:9090/api/v1/rules' \
| jq -r '.data.groups[] | select(.name == "homelab.rules") | .rules[] | "\(.name)\t\(.health)"'
```

Expected: six rows, each with health `ok`. A missing group means `ruleSelectorNilUsesHelmValues: false` did not apply; a rule with health `err` has a bad expression.

- [ ] **Step 6: Confirm `BlackboxProbeFailed` is already firing for Grafana**

```bash
curl -sS 'http://localhost:9090/api/v1/alerts' \
| jq -r '.data.alerts[] | select(.labels.alertname == "BlackboxProbeFailed")
         | "\(.state)\t\(.labels.instance)"'
```

Expected: a `firing` row for `https://grafana.koutoulastha.dev`, since Task 8 has not created its route yet.

This is a free end-to-end test of the whole chain — rule evaluated, alert routed, ntfy push delivered. **Confirm the phone received it.** Task 8 resolves it, which also tests `send_resolved`.

---

### Task 8: Expose Grafana on the LAN and publicly

**Files:**
- Create: `infrastructure/monitoring/kube-prometheus-stack/httproute.yaml`
- Modify: `infrastructure/monitoring/kube-prometheus-stack/values.yaml` (the `grafana:` block)

**Interfaces:**
- Consumes: Secret `grafana-admin` from Task 2; the wildcard listener on `traefik-gateway` in `default`.
- Produces: `https://grafana.koutoulastha.dev` on the LAN and, after the Pangolin step, publicly.

- [ ] **Step 1: Branch and write the check, and watch it fail**

```bash
cd /home/koutoulastha/workspace/homelab
git checkout main && git pull
git checkout -B feat/monitoring

yq -e '.kind == "HTTPRoute"
   and .spec.hostnames == ["grafana.koutoulastha.dev"]
   and .spec.parentRefs[0].name == "traefik-gateway"
   and .spec.parentRefs[0].namespace == "default"
   and .spec.rules[0].backendRefs[0].name == "kube-prometheus-stack-grafana"
   and .spec.rules[0].backendRefs[0].port == 80' \
  infrastructure/monitoring/kube-prometheus-stack/httproute.yaml
```

Expected: FAIL — `Error: ... no such file or directory`

- [ ] **Step 2: Write `infrastructure/monitoring/kube-prometheus-stack/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: default
  hostnames:
    - "grafana.koutoulastha.dev"
  rules:
    - backendRefs:
        - name: kube-prometheus-stack-grafana
          port: 80
```

No `Certificate` resource: this hostname intersects the existing wildcard listener. A per-host cert would also hit the `_acme-challenge` CNAME hijack once the host is behind Pangolin — the wildcard validates at `_acme-challenge.koutoulastha.dev`, which carries no delegation.

- [ ] **Step 3: Replace the `grafana:` block in `values.yaml`**

Replace the existing block (the one whose comment says exposure settings are added in Task 8) with:

```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  persistence:
    enabled: true
    size: 5Gi
    accessModes: ["ReadWriteOnce"]
  # This login page is internet-facing via Pangolin. Signup off, anonymous off,
  # secure cookies on, and root_url set to the public hostname so generated
  # links and redirects do not point at an in-cluster address.
  grafana.ini:
    server:
      root_url: https://grafana.koutoulastha.dev
    users:
      allow_sign_up: false
      allow_org_create: false
    auth.anonymous:
      enabled: false
    security:
      cookie_secure: true
      cookie_samesite: lax
```

- [ ] **Step 4: Run both checks and watch them pass**

```bash
yq -e '.kind == "HTTPRoute"
   and .spec.hostnames == ["grafana.koutoulastha.dev"]
   and .spec.rules[0].backendRefs[0].name == "kube-prometheus-stack-grafana"' \
  infrastructure/monitoring/kube-prometheus-stack/httproute.yaml

yq -e '.grafana["grafana.ini"].server.root_url == "https://grafana.koutoulastha.dev"
   and .grafana["grafana.ini"].users.allow_sign_up == false
   and .grafana["grafana.ini"]["auth.anonymous"].enabled == false
   and .grafana["grafana.ini"].security.cookie_secure == true' \
  infrastructure/monitoring/kube-prometheus-stack/values.yaml
```

Expected: `true` twice.

- [ ] **Step 5: Commit and merge**

```bash
git add infrastructure/monitoring/kube-prometheus-stack/httproute.yaml \
        infrastructure/monitoring/kube-prometheus-stack/values.yaml
git commit -m "feat(monitoring): expose Grafana via HTTPRoute and harden for public access"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
git checkout main && git pull
```

- [ ] **Step 6: Verify the route attached**

```bash
kubectl -n monitoring get httproute grafana \
  -o jsonpath='{.status.parents[0].conditions[*].type}{"\n"}{.status.parents[0].conditions[*].status}{"\n"}'
```

Expected: `Accepted ResolvedRefs` / `True True`.

- [ ] **Step 7: Verify on the LAN with `curl`, not a browser**

```bash
curl -sSI https://grafana.koutoulastha.dev | head -1
```

Expected: `HTTP/2 302` (Grafana redirecting to `/login`).

A DNS failure here in a browser but not in `curl` is the DNS-over-HTTPS trap, not a broken deployment.

- [ ] **Step 8: Confirm anonymous access is actually off**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://grafana.koutoulastha.dev/api/org
```

Expected: `401`. Anything else means `auth.anonymous` did not apply — do not proceed to public exposure.

- [ ] **Step 9: Add the Pangolin resource**

Pangolin resources are configured in Pangolin's own UI, not in this repo — `apps/pangolin-newt/` only deploys the Newt tunnel agent.

In the Pangolin dashboard: add a resource for `grafana.koutoulastha.dev` targeting the Newt site, backend `kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80`. **Enable Pangolin's own authentication on the resource.** Grafana's login is a reasonable barrier but should not be the only one facing the internet.

- [ ] **Step 10: Verify the public path from off-network**

From a device on mobile data, not the LAN:

```bash
curl -sSI https://grafana.koutoulastha.dev | head -1
```

Expected: a response from Pangolin's auth layer, not Grafana's login page directly.

A `502` means the Newt tunnel is down — check UDP 51820 is open.

- [ ] **Step 11: Confirm the Grafana probe recovered and a resolve notification arrived**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

```bash
curl -sS --get 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=probe_success{instance="https://grafana.koutoulastha.dev"}' \
| jq -r '.data.result[0].value[1]'
```

Expected: `1`.

The `BlackboxProbeFailed` alert firing since Task 7 now resolves, so the phone should receive a **resolved** notification. That confirms `send_resolved` works — the last untested part of the alert path.

- [ ] **Step 12: Update the repo README**

Add `monitoring/` to the Layout block in `README.md`, under `infrastructure/`:

```
  monitoring/
    kube-prometheus-stack/  # Prometheus + Alertmanager + Grafana + exporters
    blackbox-exporter/      # uptime probes, incl. the public-path tunnel probe
```

```bash
git add README.md
git commit -m "docs: add monitoring/ to the repo layout"
git push -u origin feat/monitoring
gh pr create --fill --base main && gh pr merge --merge --delete-branch=false
```

---

## Done when

- `kubectl -n argocd get applications` lists `kube-prometheus-stack` and `blackbox-exporter`, both Synced/Healthy.
- The Prometheus active-target query returns no unhealthy rows.
- `homelab.rules` shows six rules with health `ok`.
- A synthetic critical alert reaches the phone at high priority; a warning arrives silently; a resolve notification arrives.
- healthchecks.io shows the Watchdog check up.
- `curl -sSI https://grafana.koutoulastha.dev` returns 302 on the LAN and hits Pangolin auth from off-network.

## Deferred, by decision of the spec

- **Loki + Alloy (Phase 2).** Own spec and plan.
- **Talos control-plane metrics.** `bind-address: 0.0.0.0` on controller-manager and scheduler, `listen-metrics-urls` on etcd, via Omni. Then flip the three `enabled: false` flags in `values.yaml` back on and re-run the target check.
- **Cilium + Hubble metrics.** Also an Omni change; Cilium is not managed by this repo.
- **Thanos/Mimir long-term storage, Grafana OIDC.**
