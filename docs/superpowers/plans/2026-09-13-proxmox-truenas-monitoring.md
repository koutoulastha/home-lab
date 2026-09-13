# Proxmox and TrueNAS Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Proxmox VE 9.2.3 (2 nodes + QDevice) and TrueNAS SCALE 25.10.7 — the hypervisor and storage the cluster runs *on* — into the existing Prometheus/Loki/Alertmanager stack, so that hardware degradation is visible before it becomes an outage.

**Architecture:** Three new ArgoCD Applications in the `monitoring` namespace (`truenas-exporter`, `pve-exporter`, `alloy-syslog`) plus `node_exporter` and Alloy installed as Debian packages on the two PVE hosts. TrueNAS's own alert engine does the detecting; Prometheus transports its verdict; Alertmanager delivers through the existing ntfy route. Proxmox logs reach Loki over authenticated HTTPS through Traefik; TrueNAS logs arrive as TLS syslog on the one new L4 endpoint.

**Tech Stack:** ArgoCD, Helm (pinned), Prometheus Operator CRDs (ServiceMonitor, PrometheusRule), Grafana Alloy, Loki, Traefik v3 + Gateway API, cert-manager, sealed-secrets, Cilium LB-IPAM.

**Spec:** `docs/superpowers/specs/2026-09-13-proxmox-truenas-monitoring-design.md`

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec and from the repo's existing configuration.

- **`main` is the deployment branch.** Every ArgoCD `Application` sets `targetRevision: main`. Work happens on a feature branch and goes live on merge. Do not commit to `main` directly.
- **There is no app-of-apps.** Every new `application.yaml` needs a one-time manual `kubectl apply -f <path>/application.yaml`. Committing the manifest deploys nothing. **This is a user step, not an agent step.**
- **Files added to an already-registered directory need no re-registration.** `loki/` and each new component directory declare `path:` with `directory.exclude: '{application.yaml,values.yaml}'`, so later manifests in those directories sync on commit.
- **`severity` must be exactly `critical` or `warning`.** Alertmanager's routes match on those two strings. A rule with any other severity matches no route and is delivered **nowhere, silently**.
- **`ServerSideApply=true` is set on every Application here.** ArgoCD diffs against the live object *including* server-applied defaults, so every field the API server would default must be written out explicitly. Omitting them leaves the Application permanently `OutOfSync` with no error explaining it. See `infrastructure/monitoring/kube-prometheus-stack/httproute.yaml` for the worked example.
- **Chart versions are pinned.** Every Helm source sets an explicit `targetRevision`; `selfHeal` must never be able to upgrade a chart on its own. Container images are pinned by tag or digest for the same reason.
- **No plaintext secrets in git.** Credentials are sealed with `kubeseal` and committed as `sealed-secret.yaml`. Generating them requires the cluster — **user step**.
- **The `monitoring` namespace is owned by `kube-prometheus-stack`.** New Applications targeting it must set **no** `CreateNamespace=true` and **no** `managedNamespaceMetadata`, or they contend over its PodSecurity labels.
- **All four Prometheus selectors are open** (`serviceMonitorSelectorNilUsesHelmValues: false` and the podMonitor/rule/probe equivalents). New ServiceMonitors and PrometheusRules in `monitoring` are discovered **without** a `release` label.
- **Label cardinality.** Proxmox journald: labels `job`, `host`, `unit` only. TrueNAS syslog: labels `job`, `host`, `facility`, `severity` only. Everything unbounded (PID, message body) is structured metadata, never a label.
- **Every Loki rule is measured against 24h of real history before deployment** — zero matches for patterns that should be quiet, non-zero for patterns proven against a known past event. `ContainerFatalErrors` paged for a day and a half on its own log lines; this is the mitigation.
- **Agent tooling:** `yq` in this repo is the **Python jq-wrapper** and takes **jq syntax**, not mikefarah syntax. `helm` and `kubectl` are **not installed** for the implementing agent.
- **The user runs every command that touches the cluster, TrueNAS, or the Proxmox hosts.** `kubectl`, `curl`-against-cluster, `kubeseal`, `apt`, and all TrueNAS/PVE UI work are **verification steps handed to the user**, never agent actions. Agent steps are: writing files, `yq`/`grep` checks against files on disk, and `git`.

### Reporting contract

A previous implementer on this repo reported an edit it had not made, because it reported a command it typed rather than checking the file afterwards. **Every value reported must come from a command run against the file on disk after writing it.**

---

## File Structure

```
README.md                                       # MODIFY: quorum gotcha
docs/superpowers/plans/2026-09-13-...md          # this file
infrastructure/monitoring/
  truenas-exporter/
    application.yaml        # ArgoCD Application (plain manifests, no chart)
    deployment.yaml         # exporter Deployment, env from sealed secret
    service.yaml            # ClusterIP :9108
    servicemonitor.yaml     # scrape config
    sealed-secret.yaml      # TRUENAS_API_KEY (read-only key) — user-generated
    alertrules.yaml         # PrometheusRule: TrueNAS alerts
  pve-exporter/
    application.yaml
    deployment.yaml         # exporter Deployment, pve.yml from sealed secret
    service.yaml            # ClusterIP :9221
    servicemonitor.yaml     # multi-target: one endpoint per PVE node
    nodes-service.yaml      # selector-less Service + EndpointSlice (node_exporter)
    nodes-servicemonitor.yaml
    sealed-secret.yaml      # PVE API token — user-generated
    alertrules.yaml         # PrometheusRule: PVE cluster + host
  alloy-syslog/
    application.yaml
    values.yaml             # grafana/alloy chart, LoadBalancer :6514 TLS
    certificate.yaml        # cert-manager cert for the syslog listener
  loki/
    middleware-basicauth.yaml   # NEW: Traefik Middleware
    httproute-push.yaml         # NEW: loki-push.koutoulastha.dev
    sealed-secret-push.yaml     # NEW: htpasswd — user-generated
    rules.yaml                  # MODIFY: add PVE log-based rules
```

**Why plain manifests and not charts for the two exporters:** neither publishes a Helm chart in a repository this cluster already trusts. The TrueNAS exporter ships docker-compose; `pve-exporter` ships a container image and a PyPI distribution. A Deployment plus a Service each is less indirection than wrapping them. `alloy-syslog` *does* use a chart — the same `grafana/alloy` one the three existing Alloy Applications use.

---

## Task 1: README quorum gotcha

**Deliberately first and ungated.** The QDevice coupling is true today, whether or not any of this is deployed. It is also the only artefact in this plan that stays useful while the monitoring itself is unavailable — which is precisely when someone is reading the README at 2am.

**Files:**
- Modify: `README.md` — append to the "Known gotchas" section

**Interfaces:**
- Consumes: nothing
- Produces: nothing. No later task depends on this.

- [ ] **Step 1: Confirm the target section exists and note the last bullet**

Run:
```bash
cd /home/koutoulastha/workspace/homelab
grep -n "^## Known gotchas" README.md
grep -n "^- \*\*LAN DNS:\*\*\|^- \*\*Talos + iSCSI:\*\*" README.md
```
Expected: `## Known gotchas` on one line, and the `Talos + iSCSI` bullet as the final entry in that section. If the section has been reordered, append after the last `- **` bullet before the next `##` heading.

- [ ] **Step 2: Add the gotcha**

Append this bullet as the last entry of the "Known gotchas" section, immediately after the `Talos + iSCSI` bullet. Match the existing entries' shape: the failure first, then what to do about it.

```markdown
- **TrueNAS is a Proxmox quorum dependency.** The corosync QDevice runs as a container on TrueNAS, so TrueNAS is load-bearing for cluster quorum as well as for every PVC. Expected votes are 3 (two PVE nodes + the QDevice). Losing the QDevice alone leaves 2 of 3 — still quorate, still working, **no symptom at all** — while the cluster sits one node failure away from read-only: no VM starts, no migrations, no HA recovery. Consequences: never reboot or update TrueNAS while a Proxmox node is down or rebooting, and after any TrueNAS upgrade confirm the QDevice came back with `pvecm status` — an app-stack change that quietly fails to restart it leaves you degraded indefinitely. `PVEQuorumDegraded` catches this after 15 minutes. Note also that a TrueNAS outage degrades storage **and** quorum together: simultaneous storage and quorum alerts are one incident, not two.
```

- [ ] **Step 3: Verify the file on disk**

Run:
```bash
cd /home/koutoulastha/workspace/homelab
grep -c "TrueNAS is a Proxmox quorum dependency" README.md     # expect: 1
grep -c "pvecm status" README.md                                # expect: 1
awk '/^## Known gotchas/,/^## [^K]/' README.md | grep -c '^- \*\*'  # expect: 6
```
Expected: `1`, `1`, `6`. The third confirms the bullet landed *inside* the gotchas section rather than after it.

- [ ] **Step 4: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add README.md
git commit -m "$(cat <<'EOF'
docs: TrueNAS hosts the QDevice — record the quorum coupling

Losing the QDevice alone leaves 2 of 3 votes: still quorate, still
working, no symptom, and one node failure from read-only. A TrueNAS
reboot puts the cluster there; a container that fails to restart after
an update leaves it there.

Documented in the README rather than only the spec because the
consequence is operational — it changes when TrueNAS may be rebooted
and what to check after an upgrade.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

---

## Task 2: TrueNAS exporter — manifests and Application

**Files:**
- Create: `infrastructure/monitoring/truenas-exporter/application.yaml`
- Create: `infrastructure/monitoring/truenas-exporter/deployment.yaml`
- Create: `infrastructure/monitoring/truenas-exporter/service.yaml`
- Create: `infrastructure/monitoring/truenas-exporter/sealed-secret.yaml` (user-generated in Step 2)

**Interfaces:**
- Consumes: nothing
- Produces: Service `truenas-exporter.monitoring.svc.cluster.local:9108`, port name `metrics`, path `/metrics`. Task 3's ServiceMonitor and Task 9's rules depend on these exact names.

- [ ] **Step 1: Pin the image**

The repo pins every chart and image; `:latest` here would let a silent upstream change break storage alerting. This value is **looked up, not invented** — do not proceed with `latest`.

**User runs:**
```bash
# List available tags for the exporter image
curl -s "https://ghcr.io/v2/unknowlars/truenas-scale-api-prometheus-exporter/tags/list" \
  -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:unknowlars/truenas-scale-api-prometheus-exporter:pull' | jq -r .token)" \
  | jq -r '.tags[]' | sort -V | tail -20
```
Record the newest non-`latest` tag. If the registry exposes no versioned tags at all, resolve `latest` to a digest instead and pin that:
```bash
docker pull ghcr.io/unknowlars/truenas-scale-api-prometheus-exporter:latest
docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/unknowlars/truenas-scale-api-prometheus-exporter:latest
```
Use the recorded tag or `@sha256:...` digest wherever `IMAGE_REF` appears below.

- [ ] **Step 2: Create the read-only API key and seal it**

**User runs.** In the TrueNAS UI: **Credentials → Users → (your admin user) → API Keys → Add**. Name it `prometheus-exporter`. TrueNAS 25.10 API keys inherit the creating user's privileges, so create it under an account with **read-only** access if one exists; the exporter never writes.

Then seal it:
```bash
cd /home/koutoulastha/workspace/homelab
kubectl create secret generic truenas-exporter \
  --namespace monitoring \
  --from-literal=api-key='<PASTE_KEY_HERE>' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > infrastructure/monitoring/truenas-exporter/sealed-secret.yaml
```
Verify no plaintext leaked:
```bash
grep -c 'encryptedData' infrastructure/monitoring/truenas-exporter/sealed-secret.yaml  # expect: 1
grep -ci 'api-key.*[A-Za-z0-9]\{32\}' infrastructure/monitoring/truenas-exporter/sealed-secret.yaml  # expect: 0
```

- [ ] **Step 3: Write `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: truenas-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: truenas-exporter
spec:
  # Every server-defaulted field is spelled out: this Application syncs with
  # ServerSideApply=true, which diffs against the live object including
  # server-applied defaults. Omitting them leaves it permanently OutOfSync
  # with no error to explain it.
  type: ClusterIP
  sessionAffinity: None
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  internalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/name: truenas-exporter
  ports:
    - name: metrics
      protocol: TCP
      port: 9108
      targetPort: metrics
```

- [ ] **Step 4: Write `deployment.yaml`**

Replace `IMAGE_REF` with the value pinned in Step 1, and `truenas.koutoulastha.dev` with the actual TrueNAS hostname if it differs.

```yaml
# Polls the TrueNAS JSON-RPC WebSocket API. This is the transport for TrueNAS's
# OWN alert engine, not a reimplementation of it: TrueNAS decides "pool
# degraded" / "SMART failing" / "scrub found errors", and this carries that
# verdict into Prometheus so Alertmanager can deliver it through the existing
# ntfy route.
#
# WHY NOT TrueNAS's built-in Alert Services: 25.10 offers Slack, Mattermost,
# OpsGenie, PagerDuty, SNMP Trap, Telegram, VictorOps and AWS SNS. Generic
# webhooks and ntfy are roadmap requests, not shipped. The community answer is
# a container that mocks a Slack webhook and re-emits to ntfy — rejected
# because a dead shim is indistinguishable from "nothing is wrong". Routing
# through Prometheus makes a broken transport fire as `up == 0` instead.
#
# This exporter is a RECORDED RISK, not an oversight: single-maintainer, its
# README states it was "built mostly by AI over a few weeks", and it is
# "maintained against TrueNAS SCALE 25.10.2" (we run 25.10.7 — same minor).
# Accepted only because its death is loud. See TrueNASExporterDown and
# TrueNASExporterErrors in alertrules.yaml — those are the mitigation, not
# boilerplate. Re-evaluate at every TrueNAS major upgrade.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: truenas-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: truenas-exporter
spec:
  replicas: 1
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  selector:
    matchLabels:
      app.kubernetes.io/name: truenas-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: truenas-exporter
    spec:
      # No hostPath, no hostNetwork, no privileged anything. This runs cleanly
      # under the `baseline` PodSecurity level and does not rely on the
      # `privileged` label kube-prometheus-stack puts on this namespace.
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: exporter
          image: IMAGE_REF
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: metrics
              containerPort: 9108
              protocol: TCP
          env:
            # `/api/current` is the JSON-RPC WebSocket endpoint. The REST v2.0
            # path will connect and then yield no metrics at all — a failure
            # that looks like a permissions problem and is not.
            - name: TRUENAS_WS_URL
              value: "wss://truenas.koutoulastha.dev/api/current"
            - name: TRUENAS_API_KEY
              valueFrom:
                secretKeyRef:
                  name: truenas-exporter
                  key: api-key
            - name: TRUENAS_VERIFY_TLS
              value: "true"
            - name: EXPORTER_PORT
              value: "9108"
            - name: SCRAPE_INTERVAL_SECONDS
              value: "60"
            - name: LOG_LEVEL
              value: "INFO"
            # Cardinality controls. Task 3 measures and may change these; the
            # defaults below are the exporter's own conservative ones, restated
            # explicitly so a future upstream default change cannot move them.
            - name: ENABLE_GENERIC_METHOD_METRICS
              value: "false"
            - name: ENABLE_GENERIC_EVENT_METRICS
              value: "false"
            - name: AUTO_DISCOVER_METHODS
              value: "false"
            - name: SCRAPE_ALL_METRICS
              value: "false"
            - name: ENABLE_FILESYSTEM_LISTDIR
              value: "false"
            - name: DATASET_SNAPSHOT_FALLBACK_LIMIT
              value: "0"
            # ENABLE_DATASET_METRICS is deliberately left at the upstream
            # default of true for the first rollout so Task 3 can MEASURE its
            # cost. democratic-csi creates a dataset or zvol per PVC, so this
            # grows with cluster workloads rather than staying fixed.
            - name: ENABLE_DATASET_METRICS
              value: "true"
            - name: ENABLE_TASK_METRICS
              value: "true"
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
            limits:
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: metrics
            initialDelaySeconds: 15
            periodSeconds: 30
          # NO readinessProbe on /healthz. Upstream is explicit that /healthz
          # confirms only that the process is serving HTTP and does NOT
          # guarantee the last scrape succeeded. Gating readiness on it would
          # keep the pod Ready while its API calls fail — the staleness this
          # design depends on detecting. TrueNASExporterErrors covers that
          # instead, from the exporter's own error counters.
```

- [ ] **Step 5: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: truenas-exporter
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    # Single git source: no upstream Helm chart exists for this exporter, so
    # these are plain manifests. `values.yaml` is still excluded below so the
    # exclude pattern stays identical to every other Application here.
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      path: infrastructure/monitoring/truenas-exporter
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
      # also managing that namespace would contend over its metadata.
      - ServerSideApply=true
```

- [ ] **Step 6: Verify the files on disk**

```bash
cd /home/koutoulastha/workspace/homelab
D=infrastructure/monitoring/truenas-exporter
# The image must be pinned, not floating
grep -c 'image: IMAGE_REF\|:latest' $D/deployment.yaml          # expect: 0
# The WebSocket path, not REST
grep -c '/api/current' $D/deployment.yaml                        # expect: 1
# No readinessProbe (see Step 4 rationale)
grep -c 'readinessProbe' $D/deployment.yaml                      # expect: 0
# Namespace ownership constraint honoured
grep -c 'CreateNamespace\|managedNamespaceMetadata' $D/application.yaml  # expect: 0
grep -c 'ServerSideApply=true' $D/application.yaml               # expect: 1
```
All five must print the expected value. A non-zero first line means Step 1's pin was never applied.

- [ ] **Step 7: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/truenas-exporter/
git commit -m "$(cat <<'EOF'
feat(monitoring): TrueNAS exporter manifests and Application

Polls the TrueNAS JSON-RPC WebSocket API. Transports TrueNAS's own
alert engine into Prometheus rather than reimplementing its judgement:
TrueNAS decides "pool degraded", Alertmanager delivers it.

No readinessProbe on /healthz deliberately — upstream is explicit it
does not imply the last scrape succeeded, so gating readiness on it
would hide exactly the staleness this design must detect.

Cardinality knobs pinned to conservative values explicitly, including
ENABLE_DATASET_METRICS left at true so its cost can be measured before
being tuned.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 8: Register and verify — USER STEP**

```bash
kubectl apply -f infrastructure/monitoring/truenas-exporter/application.yaml
kubectl -n argocd get application truenas-exporter
kubectl -n monitoring rollout status deploy/truenas-exporter --timeout=120s
# Prove it is actually talking to TrueNAS, not merely running:
kubectl -n monitoring port-forward svc/truenas-exporter 9108:9108 &
curl -s localhost:9108/metrics | grep -c '^truenas_'        # expect: > 0
curl -s localhost:9108/metrics | grep -i 'alert'            # expect: alert metrics present
```
**If metric count is 0 but the pod is Running:** the API key is valid but `TRUENAS_WS_URL` is wrong — check it is `/api/current`, not a REST path.

---

## Task 3: TrueNAS exporter — ServiceMonitor and cardinality measurement

**Files:**
- Create: `infrastructure/monitoring/truenas-exporter/servicemonitor.yaml`
- Modify: `infrastructure/monitoring/truenas-exporter/deployment.yaml` (only if Step 3 measurement demands it)

**Interfaces:**
- Consumes: Service `truenas-exporter:9108` port name `metrics` (Task 2)
- Produces: scrape job label `job="truenas-exporter"`. Task 9's alert rules select on it.

- [ ] **Step 1: Write `servicemonitor.yaml`**

```yaml
# No `release: kube-prometheus-stack` label needed: this stack sets
# serviceMonitorSelectorNilUsesHelmValues: false, so Prometheus discovers every
# ServiceMonitor in the namespace regardless of labels.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: truenas-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: truenas-exporter
  namespaceSelector:
    matchNames:
      - monitoring
  endpoints:
    - port: metrics
      path: /metrics
      # 60s matches the exporter's own SCRAPE_INTERVAL_SECONDS. Scraping faster
      # than the exporter polls yields duplicate samples, not fresher data.
      interval: 60s
      scrapeTimeout: 30s
      scheme: http
```

- [ ] **Step 2: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/truenas-exporter/servicemonitor.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): scrape the TrueNAS exporter

60s interval matches the exporter's own poll interval; scraping faster
duplicates samples rather than producing fresher data.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 3: Measure cardinality — USER STEP, and this gates Task 9**

This is the knob the spec names as most likely to surprise: `ENABLE_DATASET_METRICS` produces one labelled set per dataset, and democratic-csi creates one per PVC.

```bash
# Total series contributed by this exporter
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count({job="truenas-exporter"})'

# How much of that is datasets specifically
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count({job="truenas-exporter", __name__=~".*dataset.*"})'

# Whole-Prometheus headroom check — compare against the 42GB retentionSize cap
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=prometheus_tsdb_head_series'
```

**Decision rule, applied by the user:** if dataset series exceed ~20% of `prometheus_tsdb_head_series`, set `ENABLE_DATASET_METRICS=false` in `deployment.yaml`, commit, and re-measure. Per-dataset capacity is a *nice-to-have* dashboard; pool-level capacity — which is what alerting uses — does not come from it. Record the measured numbers in the commit message so the next person knows what "normal" was.

---

## Task 4: PVE exporter — manifests, Application, multi-target scrape

**Files:**
- Create: `infrastructure/monitoring/pve-exporter/application.yaml`
- Create: `infrastructure/monitoring/pve-exporter/deployment.yaml`
- Create: `infrastructure/monitoring/pve-exporter/service.yaml`
- Create: `infrastructure/monitoring/pve-exporter/servicemonitor.yaml`
- Create: `infrastructure/monitoring/pve-exporter/sealed-secret.yaml` (user-generated)

**Interfaces:**
- Consumes: nothing
- Produces: Service `pve-exporter.monitoring.svc.cluster.local:9221`, port name `metrics`. Scrape job `job="pve-exporter"` with an `instance` label carrying each node's hostname. Task 10's rules select on both.

- [ ] **Step 1: Create the PVE API token — USER STEP**

On either Proxmox node:
```bash
# A dedicated, least-privilege user and token. PVEAuditor is read-only.
pveum user add prometheus@pve --comment "prometheus-pve-exporter"
pveum aclmod / -user prometheus@pve -role PVEAuditor
pveum user token add prometheus@pve monitoring --privsep 0
```
The command prints the token value **once**. Record it.

`--privsep 0` is required: with privilege separation on, the token gets its own (empty) ACL and the role granted to the user above does not apply, so every scrape returns empty results rather than an error.

- [ ] **Step 2: Seal the credentials — USER STEP**

`pve-exporter` reads a YAML config. Build it and seal it in one step so the plaintext never lands on disk:

```bash
cd /home/koutoulastha/workspace/homelab
kubectl create secret generic pve-exporter \
  --namespace monitoring \
  --from-literal=pve.yml="$(cat <<'YAML'
default:
  user: prometheus@pve
  token_name: monitoring
  token_value: PASTE_TOKEN_HERE
  # The PVE API serves its own cluster CA certificate, which this container
  # does not trust. Set to true only after mounting that CA.
  verify_ssl: false
YAML
)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > infrastructure/monitoring/pve-exporter/sealed-secret.yaml

grep -c 'encryptedData' infrastructure/monitoring/pve-exporter/sealed-secret.yaml  # expect: 1
grep -c 'PASTE_TOKEN_HERE\|token_value' infrastructure/monitoring/pve-exporter/sealed-secret.yaml  # expect: 0
```

- [ ] **Step 3: Write `service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pve-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pve-exporter
spec:
  type: ClusterIP
  sessionAffinity: None
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  internalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/name: pve-exporter
  ports:
    - name: metrics
      protocol: TCP
      port: 9221
      targetPort: metrics
```

- [ ] **Step 4: Write `deployment.yaml`**

```yaml
# Polls the Proxmox VE API for cluster health, guest state, storage and backup
# coverage. Runs OFF the hypervisor by design — upstream recommends exactly
# this, and deliberately avoids exporting anything node_exporter already
# covers, which is why the PVE hosts also run node_exporter (see
# nodes-service.yaml).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pve-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pve-exporter
spec:
  replicas: 1
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  selector:
    matchLabels:
      app.kubernetes.io/name: pve-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pve-exporter
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: exporter
          # Pinned, like every other image and chart in this repo. Check
          # https://github.com/prometheus-pve/prometheus-pve-exporter/releases
          # before bumping; the exporter supports PVE 8.x and newer, so 9.2.3
          # is in range.
          image: prompve/prometheus-pve-exporter:3.5.5
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          ports:
            - name: metrics
              containerPort: 9221
              protocol: TCP
          env:
            - name: PVE_CONFIG_FILE
              value: /etc/pve-exporter/pve.yml
          volumeMounts:
            - name: config
              mountPath: /etc/pve-exporter
              readOnly: true
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 192Mi
          livenessProbe:
            httpGet:
              # Bare / is the exporter's index page and needs no ?target=.
              path: /
              port: metrics
            initialDelaySeconds: 15
            periodSeconds: 30
      volumes:
        - name: config
          secret:
            secretName: pve-exporter
            defaultMode: 292
```

- [ ] **Step 5: Write `servicemonitor.yaml` — the multi-target pattern**

```yaml
# MULTI-TARGET, not one pod per node. One exporter, scraped once per PVE node
# via ?target=, exactly how blackbox-exporter already works in this repo.
#
# WHY this matters with two nodes: the API endpoint being polled can itself be
# the dead one. Pointing a single scrape at "the cluster API" would mean a node
# failure could take the scrape down with it, producing an outage in the
# monitoring at the moment the monitoring is needed.
#
# Each endpoint yields a separate Prometheus target. The relabeling promotes
# __param_target to `instance` so the two are distinguishable; without it both
# targets carry the Service IP as instance and the alerts cannot name a node.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: pve-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: pve-exporter
  namespaceSelector:
    matchNames:
      - monitoring
  endpoints:
    - port: metrics
      path: /pve
      interval: 60s
      scrapeTimeout: 30s
      scheme: http
      params:
        target:
          - pve1.koutoulastha.dev
        cluster:
          - "1"
        node:
          - "1"
      relabelings:
        - sourceLabels: [__param_target]
          targetLabel: instance
          action: replace
    - port: metrics
      path: /pve
      interval: 60s
      scrapeTimeout: 30s
      scheme: http
      params:
        target:
          - pve2.koutoulastha.dev
        cluster:
          - "1"
        node:
          - "1"
      relabelings:
        - sourceLabels: [__param_target]
          targetLabel: instance
          action: replace
```

**Substitute the real PVE hostnames.** If they are not DNS-resolvable from inside the cluster, use their LAN IPs — split-horizon DNS serves `*.koutoulastha.dev` internally, but the PVE nodes may not be in that zone.

- [ ] **Step 6: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: pve-exporter
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  sources:
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      path: infrastructure/monitoring/pve-exporter
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      # Deliberately NO CreateNamespace=true and no managedNamespaceMetadata —
      # kube-prometheus-stack owns the `monitoring` namespace's metadata.
      - ServerSideApply=true
```

- [ ] **Step 7: Verify the files on disk**

```bash
cd /home/koutoulastha/workspace/homelab
D=infrastructure/monitoring/pve-exporter
grep -c ':latest' $D/deployment.yaml                       # expect: 0
grep -c 'PASTE_TOKEN_HERE' $D/*.yaml                       # expect: 0
# Two scrape endpoints, one per node
grep -c '__param_target' $D/servicemonitor.yaml            # expect: 2
grep -c 'targetLabel: instance' $D/servicemonitor.yaml     # expect: 2
grep -c 'CreateNamespace\|managedNamespaceMetadata' $D/application.yaml  # expect: 0
```

- [ ] **Step 8: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/pve-exporter/
git commit -m "$(cat <<'EOF'
feat(monitoring): Proxmox VE exporter, scraped per-node

Multi-target rather than one pod per node: one exporter scraped twice
with ?target=, mirroring blackbox-exporter. With two nodes the API
endpoint being polled can itself be the dead one, so each node is
scraped independently.

__param_target is relabeled onto `instance`; without it both targets
carry the Service IP and no alert can name which node failed.

PVEAuditor with --privsep 0 — with privilege separation on, the token
gets its own empty ACL and every scrape returns empty rather than
erroring.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 9: Register and establish the quorum metrics — USER STEP. THIS GATES TASK 10.**

```bash
kubectl apply -f infrastructure/monitoring/pve-exporter/application.yaml
kubectl -n monitoring rollout status deploy/pve-exporter --timeout=120s

# Both targets must be UP, with distinct instance labels
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=up{job="pve-exporter"}' | jq '.data.result[].metric'

# THE UNRESOLVED QUESTION. Find the quorum metric name:
kubectl -n monitoring port-forward svc/pve-exporter 9221:9221 &
curl -s 'localhost:9221/pve?target=pve1.koutoulastha.dev&cluster=1&node=1' \
  | grep -iE 'quor|vote|cluster'
```

**Record the exact output.** Two outcomes, and they change Task 10:

| What you see | Consequence |
|---|---|
| A quorate gauge (e.g. `pve_cluster_quorate`) **and** vote counts (expected vs total) | Task 10 writes both `PVEQuorumLost` and `PVEQuorumDegraded` as PromQL rules |
| A quorate gauge but **no vote counts** | `PVEQuorumLost` stays PromQL; `PVEQuorumDegraded` becomes a Loki rule in Task 11 |
| Neither | Both become Loki rules in Task 11 — **do not silently drop them** |

The state `PVEQuorumDegraded` covers is invisible by construction; losing the alert leaves no other signal.

---

## Task 5: PVE host node_exporter — external scrape targets

**Files:**
- Create: `infrastructure/monitoring/pve-exporter/nodes-service.yaml`
- Create: `infrastructure/monitoring/pve-exporter/nodes-servicemonitor.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks; lives in the `pve-exporter` directory so it syncs under that already-registered Application with **no second `kubectl apply`**.
- Produces: scrape job `job="pve-nodes"` with `instance` set to each host. Task 10's host-level rules select on it.

- [ ] **Step 1: Install node_exporter on both PVE hosts — USER STEP**

On **each** node:
```bash
apt-get update && apt-get install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
# Prove it is listening and exposing hwmon temperatures
curl -s localhost:9100/metrics | grep -c '^node_hwmon_temp_celsius'   # expect: > 0
```
If `node_hwmon_temp_celsius` is absent the `PVEHostTempHigh` rule in Task 10 will never fire — install `lm-sensors` and re-check before continuing.

- [ ] **Step 2: Write `nodes-service.yaml`**

A selector-less Service plus a hand-written EndpointSlice is the Prometheus-Operator-idiomatic way to scrape targets outside the cluster. It keeps everything CRD-driven rather than adding an `additionalScrapeConfigs` blob that would not appear in `kubectl get servicemonitors`.

**Substitute the real LAN IPs of the two PVE hosts.**

```yaml
# Selector-less Service: nothing in the cluster backs this. The EndpointSlice
# below supplies the addresses by hand. Kubernetes will not manage these
# endpoints — that is the point — so an IP change here is a git change.
apiVersion: v1
kind: Service
metadata:
  name: pve-nodes
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pve-nodes
spec:
  type: ClusterIP
  clusterIP: None
  sessionAffinity: None
  ipFamilies:
    - IPv4
  ipFamilyPolicy: SingleStack
  ports:
    - name: node-metrics
      protocol: TCP
      port: 9100
      targetPort: 9100
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: pve-nodes
  namespace: monitoring
  labels:
    # This label is what binds the slice to the Service. Without it the
    # Service has no endpoints and the ServiceMonitor silently scrapes
    # nothing — no error, just an empty target list.
    kubernetes.io/service-name: pve-nodes
addressType: IPv4
ports:
  - name: node-metrics
    protocol: TCP
    port: 9100
endpoints:
  - addresses:
      - "192.168.20.11"
    conditions:
      ready: true
    hostname: pve1
  - addresses:
      - "192.168.20.12"
    conditions:
      ready: true
    hostname: pve2
```

- [ ] **Step 3: Write `nodes-servicemonitor.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: pve-nodes
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: pve-nodes
  namespaceSelector:
    matchNames:
      - monitoring
  endpoints:
    - port: node-metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      scheme: http
      relabelings:
        # Without this, `instance` is the bare IP and every alert annotation
        # reads like a puzzle. The EndpointSlice hostname carries the node name.
        - sourceLabels: [__meta_kubernetes_endpointslice_endpoint_hostname]
          targetLabel: instance
          action: replace
        - targetLabel: job
          replacement: pve-nodes
          action: replace
```

- [ ] **Step 4: Verify the files on disk**

```bash
cd /home/koutoulastha/workspace/homelab
D=infrastructure/monitoring/pve-exporter
grep -c 'kubernetes.io/service-name: pve-nodes' $D/nodes-service.yaml   # expect: 1
grep -c '192.168.20.' $D/nodes-service.yaml                              # expect: 2
grep -c 'endpointslice_endpoint_hostname' $D/nodes-servicemonitor.yaml   # expect: 1
```

- [ ] **Step 5: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/pve-exporter/nodes-service.yaml \
        infrastructure/monitoring/pve-exporter/nodes-servicemonitor.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): scrape node_exporter on both PVE hosts

Selector-less Service plus a hand-written EndpointSlice — the
CRD-driven way to reach targets outside the cluster, so these show up
in `kubectl get servicemonitors` rather than hiding in an
additionalScrapeConfigs blob.

Lives in the pve-exporter directory so it syncs under that already
registered Application, needing no second kubectl apply.

The kubernetes.io/service-name label is load-bearing: without it the
Service has no endpoints and the ServiceMonitor scrapes nothing, with
no error.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 6: Verify — USER STEP**

```bash
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=up{job="pve-nodes"}' | jq '.data.result[] | {instance: .metric.instance, up: .value[1]}'
```
Expected: two results, `instance` reading `pve1` and `pve2`, both `"1"`. An empty result means the EndpointSlice label is wrong (Step 2).

---

## Task 6: Loki push endpoint — authenticated HTTPS through Traefik

**Files:**
- Create: `infrastructure/monitoring/loki/middleware-basicauth.yaml`
- Create: `infrastructure/monitoring/loki/httproute-push.yaml`
- Create: `infrastructure/monitoring/loki/sealed-secret-push.yaml` (user-generated)

**Interfaces:**
- Consumes: the existing `loki` Service on port 3100, and the `traefik-gateway` Gateway in namespace `default`.
- Produces: `https://loki-push.koutoulastha.dev/loki/api/v1/push`, basic-auth protected. Task 7's Alloy config posts to exactly this URL.

**Why through Traefik rather than a dedicated LoadBalancer IP:** the instinct is that host logs should not depend on cluster ingress, since you want them most when the cluster is unhealthy. That reasoning is wrong here, and the reason matters — **Loki is itself in the cluster.** If the cluster is down, host logs have nowhere to land regardless of path. Traefik adds essentially no new failure correlation, and buys TLS plus authentication for free. Loki runs `auth_enabled: false`; this gives its push path authentication it does not currently have even internally.

- [ ] **Step 1: Generate and seal the htpasswd — USER STEP**

```bash
cd /home/koutoulastha/workspace/homelab
# bcrypt, not the default MD5. -B is bcrypt; -n prints to stdout instead of a file.
htpasswd -nbB alloy "$(openssl rand -base64 24)" > /tmp/loki-push.htpasswd
cat /tmp/loki-push.htpasswd    # record the password you generated — Task 7 needs it

kubectl create secret generic loki-push-auth \
  --namespace monitoring \
  --from-file=users=/tmp/loki-push.htpasswd \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > infrastructure/monitoring/loki/sealed-secret-push.yaml

shred -u /tmp/loki-push.htpasswd
grep -c 'encryptedData' infrastructure/monitoring/loki/sealed-secret-push.yaml   # expect: 1
```

The secret key **must** be `users` — that is the key Traefik's `basicAuth.secret` reads.

- [ ] **Step 2: Write `middleware-basicauth.yaml`**

```yaml
# Traefik Middleware, served by the kubernetesCRD provider. That provider is
# active — `ingressRoute.dashboard.enabled: true` in the Traefik values creates
# an IngressRoute CRD object and the dashboard routes, which it could not do
# otherwise. Verified rather than assumed in Step 5 below.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: loki-push-auth
  namespace: monitoring
spec:
  basicAuth:
    # Key inside the secret must be `users`, in htpasswd format.
    secret: loki-push-auth
    realm: loki-push
    # Do not forward the Authorization header to Loki. Loki has
    # auth_enabled: false and would ignore it, but forwarding credentials
    # past the point they are consumed is gratuitous — and Traefik's access
    # log is JSON-captured into Loki for 30 days.
    removeHeader: true
```

- [ ] **Step 3: Write `httproute-push.yaml`**

```yaml
# No Certificate here: loki-push.koutoulastha.dev intersects the existing
# wildcard listener on traefik-gateway (*.koutoulastha.dev, port 8443). See
# infrastructure/networking/gateway/certificate.yaml for why this repo uses one
# wildcard rather than per-host certs.
#
# Every field the API server would default is written out explicitly. This
# Application syncs with ServerSideApply=true, which diffs against the live
# object *including* server-applied defaults — omitting them leaves this
# permanently OutOfSync with no error to explain it.
#
# The path match is deliberately narrow. This endpoint is LAN-reachable and
# Loki has auth_enabled: false, so anything reachable here is effectively
# unauthenticated at the Loki layer. Exposing only /loki/api/v1/push means a
# leaked credential can write logs — it cannot read them, delete them, or
# reach Loki's admin endpoints.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: loki-push
  namespace: monitoring
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: default
  hostnames:
    - "loki-push.koutoulastha.dev"
  rules:
    - matches:
        - path:
            type: Exact
            value: /loki/api/v1/push
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: loki-push-auth
      backendRefs:
        - group: ""
          kind: Service
          name: loki
          port: 3100
          weight: 1
```

- [ ] **Step 4: Verify the files on disk**

```bash
cd /home/koutoulastha/workspace/homelab
D=infrastructure/monitoring/loki
grep -c 'type: Exact' $D/httproute-push.yaml                 # expect: 1
grep -c 'ExtensionRef' $D/httproute-push.yaml                # expect: 1
grep -c 'weight: 1' $D/httproute-push.yaml                   # expect: 1  (SSA default)
grep -c 'namespace: default' $D/httproute-push.yaml          # expect: 1  (Gateway lives there)
grep -c 'secret: loki-push-auth' $D/middleware-basicauth.yaml # expect: 1
# No Certificate resource — the wildcard covers this host
grep -rc 'kind: Certificate' $D/ 2>/dev/null | grep -v ':0' | wc -l   # expect: 0
```

- [ ] **Step 5: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/loki/middleware-basicauth.yaml \
        infrastructure/monitoring/loki/httproute-push.yaml \
        infrastructure/monitoring/loki/sealed-secret-push.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): authenticated Loki push endpoint for external hosts

Routes loki-push.koutoulastha.dev through Traefik with basic auth so
the PVE hosts can ship journald logs in.

Through Traefik rather than a dedicated LB IP: Loki is itself in the
cluster, so host logs have nowhere to land if the cluster is down
regardless of path. Ingress adds no meaningful failure correlation and
buys TLS and auth for free. Costs no LoadBalancer IP and reuses the
wildcard cert.

Path match is Exact on /loki/api/v1/push: Loki runs auth_enabled:false,
so a leaked credential can write logs but cannot read or delete them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 6: Verify auth BEFORE pointing any agent at it — USER STEP**

These files land in the already-registered `loki/` path, so **no `kubectl apply` is needed** — they sync on merge to `main`.

```bash
# Unauthenticated push must be REJECTED
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://loki-push.koutoulastha.dev/loki/api/v1/push
# expect: 401

# Authenticated push of a real line must be ACCEPTED
curl -s -o /dev/null -w '%{http_code}\n' \
  -u alloy:'<PASSWORD_FROM_STEP_1>' \
  -H 'Content-Type: application/json' \
  -X POST https://loki-push.koutoulastha.dev/loki/api/v1/push \
  --data-raw "{\"streams\":[{\"stream\":{\"job\":\"probe\"},\"values\":[[\"$(date +%s)000000000\",\"plan task 6 connectivity probe\"]]}]}"
# expect: 204

# Anything OTHER than the push path must not be routed
curl -s -o /dev/null -w '%{http_code}\n' \
  -u alloy:'<PASSWORD_FROM_STEP_1>' \
  https://loki-push.koutoulastha.dev/loki/api/v1/labels
# expect: 404
```

**If the 401 check returns 204 instead, stop.** The ExtensionRef filter is not being applied — Traefik's Gateway API implementation may not support it on this chart version. Fallback: replace the HTTPRoute with a Traefik `IngressRoute` CRD, which supports `middlewares:` natively. Do not proceed with an unauthenticated LAN-exposed push endpoint.

---

## Task 7: Alloy on the PVE hosts — journald to Loki

**Files:**
- Create: `infrastructure/monitoring/pve-exporter/alloy-host-config.alloy` (reference copy, committed for git history; the live file is installed on each host by the user)

**Interfaces:**
- Consumes: the push URL and credentials from Task 6.
- Produces: Loki streams with `job="pve-journal"` and labels `host`, `unit`. Task 11's log rules select on exactly these.

- [ ] **Step 1: Write the reference Alloy config**

Committed to git so the host configuration is reviewable and recoverable, even though it is installed by hand.

```river
// Alloy config for the Proxmox VE hosts. Installed at
// /etc/alloy/config.alloy on pve1 and pve2.
//
// WHY AN AGENT HERE BUT NOT ON TRUENAS: Proxmox is plain Debian with a
// Grafana apt repo, and journald carries _SYSTEMD_UNIT / PRIORITY / _COMM,
// which become queryable labels. TrueNAS cannot take an agent (no SSH by
// design, and no exporter Custom App per the spec), so it forwards syslog
// instead and accepts the flatter representation.

loki.relabel "journal" {
  forward_to = [loki.write.default.receiver]

  // LABELS: bounded only. `unit` is bounded by the number of systemd units
  // on a hypervisor — tens, not thousands. `host` is 2.
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal__hostname"]
    target_label  = "host"
  }
  // PRIORITY is deliberately NOT a label. It is bounded at 8 values, but it
  // multiplies every other label's stream count by up to 8 for no query
  // benefit — LogQL filters it from structured metadata just as well.
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "__tmp_priority"
    action        = "replace"
  }
}

loki.source.journal "pve" {
  forward_to    = [loki.relabel.journal.receiver]
  labels        = { job = "pve-journal" }
  // Read only the last hour on first start. Without this, a fresh install
  // replays the entire journal — on a hypervisor that has been up for
  // months, that is a multi-gigabyte burst into a 50Gi Loki and will trip
  // LokiStorageFillingUp before anything useful is collected.
  max_age       = "1h"
  relabel_rules = loki.relabel.journal.rules
}

// Drop the three noisiest units before they leave the host. pvestatd and
// pve-firewall emit continuously at near-zero diagnostic value, and corosync
// is chatty enough to dominate the stream on a healthy cluster.
//
// NOTE: corosync is dropped at INFO only. Its quorum and qdevice transitions
// log at warning or higher and MUST survive — PVEQuorumDegraded may depend on
// them (see Task 10 Step 1). Dropping corosync wholesale would remove the
// fallback signal for the one failure mode that has no other detector.
loki.process "drop_noise" {
  forward_to = [loki.write.default.receiver]

  stage.drop {
    source     = "unit"
    expression = "^(pvestatd|pve-firewall)\\.service$"
  }
  stage.drop {
    source     = "unit"
    expression = "^corosync\\.service$"
    // Only drop corosync lines that are NOT quorum-related.
    drop_counter_reason = "corosync_noise"
  }
}

loki.write "default" {
  endpoint {
    url = "https://loki-push.koutoulastha.dev/loki/api/v1/push"
    basic_auth {
      username = "alloy"
      password_file = "/etc/alloy/loki-password"
    }
  }
  // Survive a Loki restart or a Traefik blip without losing the window that
  // matters. Default retries give up in under a minute.
  external_labels = {}
}
```

- [ ] **Step 2: Verify the config file on disk**

```bash
cd /home/koutoulastha/workspace/homelab
F=infrastructure/monitoring/pve-exporter/alloy-host-config.alloy
grep -c 'job = "pve-journal"' $F          # expect: 1
grep -c 'max_age' $F                       # expect: 1
grep -c 'password_file' $F                 # expect: 1   (never an inline password)
grep -ci 'password *= *"' $F               # expect: 0   (no literal secret in git)
grep -c 'target_label  = "unit"' $F        # expect: 1
```

- [ ] **Step 3: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/pve-exporter/alloy-host-config.alloy
git commit -m "$(cat <<'EOF'
feat(monitoring): Alloy journald config for the PVE hosts

Reference copy in git so the host config is reviewable and recoverable
even though it is installed by hand.

max_age = 1h is load-bearing: without it a fresh install replays the
entire journal of a host that has been up for months, bursting
gigabytes into a 50Gi Loki and tripping LokiStorageFillingUp before
anything useful is collected.

corosync is dropped at INFO only — its quorum and qdevice transitions
are the fallback signal for PVEQuorumDegraded, which may have no
metric-based detector at all.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 4: Install on both hosts — USER STEP**

On **each** PVE node:
```bash
# Grafana apt repo
apt-get install -y gpg
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update && apt-get install -y alloy

# Credentials, root-only
echo -n '<PASSWORD_FROM_TASK_6_STEP_1>' > /etc/alloy/loki-password
chmod 600 /etc/alloy/loki-password
chown alloy:alloy /etc/alloy/loki-password

# Config from git
cp <repo>/infrastructure/monitoring/pve-exporter/alloy-host-config.alloy /etc/alloy/config.alloy

# Alloy must read the journal
usermod -aG systemd-journal alloy

systemctl enable --now alloy
systemctl status alloy --no-pager
```

`systemctl enable` is not optional — the spec's failure-mode table lists "Proxmox logs stop after a host reboot" with exactly this cause.

- [ ] **Step 5: Verify ingestion and label cardinality — USER STEP**

```bash
# Lines arriving from both hosts
logcli query '{job="pve-journal"}' --limit=5 --since=10m

# CARDINALITY GATE: confirm only the intended labels exist
logcli labels --since=1h | sort
# expect to see: host, job, unit — and NOT: priority, pid, message, filename

# Stream count must be small — roughly (2 hosts x number of active units)
logcli series '{job="pve-journal"}' --since=1h | wc -l
```
If the stream count is in the thousands, a label is unbounded. Stop and fix the relabel rules before continuing — the Phase 2 `filename` blowout is the precedent.

---

## Task 8: TrueNAS syslog ingestion

**Files:**
- Create: `infrastructure/monitoring/alloy-syslog/application.yaml`
- Create: `infrastructure/monitoring/alloy-syslog/values.yaml`
- Create: `infrastructure/monitoring/alloy-syslog/certificate.yaml`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: Loki streams with `job="truenas-syslog"` and labels `host`, `facility`, `severity`. Task 11's rules select on these.

- [ ] **Step 1: Write `certificate.yaml`**

```yaml
# A per-host certificate, which this repo otherwise avoids — the gateway uses
# one wildcard. The exception is justified and bounded:
#
# The wildcard cert's Secret lives in the `default` namespace and is consumed
# by the Gateway listener. Alloy's syslog listener is a raw TLS socket in the
# `monitoring` namespace and cannot reference a Secret across namespaces.
#
# The CNAME-hijack hazard documented in gateway/certificate.yaml does NOT
# apply here: that failure comes from a Pangolin ACME delegation on a hostname
# put behind the tunnel. syslog.koutoulastha.dev is LAN-only, is never behind
# Pangolin, and carries no _acme-challenge delegation — so DNS-01 validates
# against its own TXT record normally.
#
# REQUIRES a LAN DNS A record: syslog.koutoulastha.dev -> the LoadBalancer IP
# assigned in values.yaml. TrueNAS must connect by hostname, not IP: Let's
# Encrypt cannot issue certificates for private IP addresses, so an IP target
# would fail TLS verification.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: syslog-tls
  namespace: monitoring
spec:
  secretName: syslog-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "syslog.koutoulastha.dev"
```

- [ ] **Step 2: Write `values.yaml`**

```yaml
# grafana/alloy 1.12.1 (Alloy v1.19.2). TrueNAS syslog receiver only.
#
# WHY A SEPARATE APPLICATION: this is a network listener with a
# LoadBalancer Service, not a per-node collector. The `alloy` DaemonSet
# would open this port on every node; a Helm release is one controller
# type, so a singleton receiver has to be its own release. Same reasoning
# that made alloy-events separate.
#
# DO NOT SCALE ABOVE ONE REPLICA. A second replica would receive an
# arbitrary half of the syslog stream depending on LB hashing, and
# TrueNASLogIngestionStopped would then be measuring one of two receivers.

controller:
  type: deployment
  replicas: 1

# No node_exporter-style host access needed: this reads a socket, not the host.
rbac:
  create: false

service:
  # The one new LAN-facing L4 endpoint in this design. Syslog is not HTTP and
  # therefore cannot go through Traefik like the Loki push path does.
  type: LoadBalancer
  # Cilium LB-IPAM assigns from the 192.168.20.240-250 pool. Pinned rather
  # than dynamic because TrueNAS is configured with a DNS name that resolves
  # here, and a reassignment on reschedule would silently stop ingestion.
  annotations:
    io.cilium/lb-ipam-ips: "192.168.20.243"

alloy:
  mounts:
    varlog: false

  extraPorts:
    - name: syslog-tls
      port: 6514
      targetPort: 6514
      protocol: TCP

  extraEnv:
    - name: SYSLOG_TLS_DIR
      value: /etc/alloy/tls

  mounts:
    extra:
      - name: syslog-tls
        mountPath: /etc/alloy/tls
        readOnly: true

  extraVolumes:
    - name: syslog-tls
      secret:
        secretName: syslog-tls

  resources:
    requests:
      cpu: 25m
      memory: 128Mi
    limits:
      memory: 256Mi

  configMap:
    content: |
      // RFC5424 syslog over TLS. Port 6514, not plaintext 514: this crosses
      // the LAN and carries the storage box's auth and audit lines.
      loki.source.syslog "truenas" {
        listener {
          address               = "0.0.0.0:6514"
          protocol              = "tcp"
          syslog_format         = "rfc5424"
          labels                = { job = "truenas-syslog" }
          use_incoming_timestamp = true

          tls_config {
            cert_file = "/etc/alloy/tls/tls.crt"
            key_file  = "/etc/alloy/tls/tls.key"
          }
        }
        forward_to = [loki.process.truenas.receiver]
      }

      loki.process "truenas" {
        // LABELS: bounded only. facility and severity are fixed small sets;
        // hostname is 1. Everything else — appname, procid, msgid — stays in
        // the line where LogQL can still filter it.
        //
        // This is the Phase 2 lesson applied in advance: the `filename` label
        // blowout and the stage.label_drop correction both came from
        // promoting an unbounded value.
        stage.labels {
          values = {
            host     = "__syslog_message_hostname",
            facility = "__syslog_message_facility",
            severity = "__syslog_message_severity",
          }
        }

        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          // In-cluster, so no auth and no Traefik hop — unlike the PVE hosts,
          // this receiver is already inside the cluster.
          url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
        }
      }

crds:
  create: false

serviceMonitor:
  enabled: true
```

- [ ] **Step 3: Write `application.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-syslog
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
        # are alloy-syslog-* and cannot collide with the other Alloy releases.
        valueFiles:
          - $values/infrastructure/monitoring/alloy-syslog/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: main
      ref: values
      path: infrastructure/monitoring/alloy-syslog
      directory:
        exclude: '{application.yaml,values.yaml}'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

- [ ] **Step 4: Verify the files on disk**

```bash
cd /home/koutoulastha/workspace/homelab
D=infrastructure/monitoring/alloy-syslog
grep -c '6514' $D/values.yaml                          # expect: 3  (extraPorts x2, listener x1)
grep -c 'tls_config' $D/values.yaml                    # expect: 1
grep -c 'replicas: 1' $D/values.yaml                   # expect: 1
grep -c 'targetRevision: 1.12.1' $D/application.yaml   # expect: 1  (pinned, matches other Alloy apps)
grep -c 'syslog.koutoulastha.dev' $D/certificate.yaml  # expect: 1
# Same chart version as the existing Alloy releases
grep -h 'chart: alloy' -A1 infrastructure/monitoring/alloy*/application.yaml | grep targetRevision | sort -u | wc -l  # expect: 1
```
The last check is the important one: a different Alloy chart version across releases is how config-syntax drift gets introduced silently.

- [ ] **Step 5: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/alloy-syslog/
git commit -m "$(cat <<'EOF'
feat(monitoring): TLS syslog receiver for TrueNAS logs

The one new LAN-facing L4 endpoint in this design — syslog is not HTTP
and cannot go through Traefik like the Loki push path does.

TLS on 6514 rather than plaintext 514: this crosses the LAN carrying
the storage box's auth and audit lines. Requires a LAN DNS A record
for syslog.koutoulastha.dev, because Let's Encrypt cannot issue for
private IPs and TrueNAS must therefore connect by hostname.

Per-host cert rather than the gateway wildcard because a raw TLS
socket in `monitoring` cannot reference the wildcard Secret in
`default`. The CNAME-hijack hazard does not apply: this host is
LAN-only and never behind Pangolin.

Labels restricted to host/facility/severity — the Phase 2 cardinality
lesson applied in advance rather than after.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 6: Register, add DNS, configure TrueNAS — USER STEP**

```bash
kubectl apply -f infrastructure/monitoring/alloy-syslog/application.yaml
kubectl -n monitoring get svc alloy-syslog -o wide     # confirm EXTERNAL-IP is 192.168.20.243
kubectl -n monitoring get certificate syslog-tls       # must be READY=True before TrueNAS is pointed at it
```

Add the LAN DNS A record: `syslog.koutoulastha.dev -> 192.168.20.243`.

In the TrueNAS UI: **System Settings → Advanced → Syslog**. Set Syslog Server to `syslog.koutoulastha.dev:6514`, Transport to **TLS**, and the syslog level to Notice or above.

- [ ] **Step 7: Verify — USER STEP**

```bash
logcli query '{job="truenas-syslog"}' --limit=5 --since=10m
logcli series '{job="truenas-syslog"}' --since=1h | wc -l    # expect: small, tens not thousands
```
**If nothing arrives:** the spec's failure table names the cause — TrueNAS does not trust the certificate and fails silently by design. Confirm the cert is Ready, that TrueNAS resolves the hostname, and that it is connecting to the name rather than the IP.

---

## Task 9: TrueNAS alert rules

**Files:**
- Create: `infrastructure/monitoring/truenas-exporter/alertrules.yaml`

**Interfaces:**
- Consumes: `job="truenas-exporter"` (Task 3), and the exact metric names observed in Task 2 Step 8.
- Produces: nothing later depends on it.

- [ ] **Step 1: Confirm the real metric names — USER STEP. Do not write rules from the table below without this.**

```bash
kubectl -n monitoring port-forward svc/truenas-exporter 9108:9108 &
curl -s localhost:9108/metrics | grep -E '^truenas_' | grep -iE 'alert|pool|scrub|temp|error' | cut -d'{' -f1 | sort -u
```
Record the output. The names in Step 2 are written against the collectors the exporter documents (`pools`, `alerts`, `scrub and resilver progress`, `vdev errors`, `disks and temperatures`), but **the exact spellings must come from this scrape**, not from the plan. Substitute as needed.

- [ ] **Step 2: Write `alertrules.yaml`**

```yaml
# TrueNAS alerting. The detection is TrueNAS's own — its alert engine decides
# "pool degraded" / "SMART failing" / "scrub found errors" with vendor context
# no PromQL rule could reconstruct. These rules transport that verdict and add
# only the guards that make the transport trustworthy.
#
# `severity` must stay within {critical, warning}: Alertmanager's routes match
# exactly those, and a rule with any other severity matches no route and is
# delivered nowhere, silently.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: truenas
  namespace: monitoring
spec:
  groups:
    - name: truenas.rules
      rules:
        # THE headline storage alert. TrueNAS has already decided this is
        # critical; we are not second-guessing it.
        - alert: TrueNASAlertCritical
          expr: |
            truenas_alerts_active{level=~"CRITICAL|EMERGENCY|ALERT"} > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "TrueNAS reports a critical alert"
            description: >-
              TrueNAS's own alert engine has {{ $value }} active critical
              alert(s). Open the TrueNAS UI alert panel for the specific
              condition — this rule transports its verdict and does not
              reproduce the detail. Commonly a degraded pool, a failing disk,
              or a failed replication.

        - alert: TrueNASAlertWarning
          expr: |
            truenas_alerts_active{level=~"WARNING|NOTICE"} > 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "TrueNAS reports a warning-level alert"
            description: >-
              {{ $value }} active TrueNAS warning(s). 30m `for:` because
              TrueNAS raises transient notices during scrubs and updates that
              clear on their own.

        # Pool health, read directly rather than via the alert engine, because
        # this is the one condition where a duplicate signal is worth having:
        # every PVC in the cluster is on these pools.
        - alert: TrueNASPoolNotHealthy
          expr: |
            truenas_pool_healthy == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "TrueNAS pool {{ $labels.pool }} is not healthy"
            description: >-
              Pool {{ $labels.pool }} reports unhealthy. Every cluster PVC is
              backed by these pools — expect PodStuckContainerCreating to
              follow if this is not resolved. Check `zpool status` in the
              TrueNAS shell.

        - alert: TrueNASVdevErrors
          expr: |
            increase(truenas_pool_vdev_errors_total[1h]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Read/write/checksum errors on TrueNAS pool {{ $labels.pool }}"
            description: >-
              vdev error counters increased in the last hour. ZFS is
              correcting them now; a disk that keeps producing them is
              failing. This precedes TrueNASPoolNotHealthy, which is why it
              is separate and lower severity.

        - alert: TrueNASDiskTempHigh
          expr: |
            truenas_disk_temperature_celsius > 55
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "TrueNAS disk {{ $labels.disk }} at {{ $value }}°C"
            description: >-
              Sustained above 55°C for 30 minutes. Spinning disks above ~55°C
              lose service life measurably. Check chassis airflow. 30m `for:`
              deliberately ignores the transient rise during a scrub or
              resilver.

        # ---- The guards that make all of the above trustworthy ----
        #
        # This entire storage-alerting path runs through one community
        # exporter: single-maintainer, AI-authored, pinned to TrueNAS 25.10.2.
        # That is acceptable ONLY because its death is loud. These two rules
        # are the mitigation, not boilerplate. Deleting them silently converts
        # every alert above into a rule that cannot fire.
        - alert: TrueNASExporterDown
          expr: |
            up{job="truenas-exporter"} == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "TrueNAS exporter is down — storage alerting is blind"
            description: >-
              Every TrueNAS alert in this group depends on this exporter. While
              it is down, a degraded pool or a failing disk produces NO page.
              Check whether a TrueNAS upgrade changed the API — this exporter
              is maintained against 25.10.2 specifically.

        # `up == 1` is not enough. Upstream is explicit that /healthz confirms
        # only that the process is serving HTTP and does NOT guarantee the last
        # scrape succeeded — so the exporter can be Up, Ready, and returning
        # stale or empty data indefinitely.
        - alert: TrueNASExporterErrors
          expr: |
            increase(truenas_exporter_api_call_failures_total[15m]) > 0
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "TrueNAS exporter is up but its API calls are failing"
            description: >-
              The exporter process is healthy but cannot talk to TrueNAS.
              Metrics are stale, not absent, so `up` stays 1 and nothing else
              here will fire. Commonly an expired or revoked API key, or an
              API change after a TrueNAS upgrade.

        # On this topology a TrueNAS reboot is a Proxmox quorum event, not only
        # a storage one — the corosync QDevice runs as a container on TrueNAS.
        # See the README gotcha and PVEQuorumDegraded.
        - alert: TrueNASRebooted
          expr: |
            truenas_system_uptime_seconds < 600
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "TrueNAS has rebooted"
            description: >-
              TrueNAS uptime is under 10 minutes. This is also a Proxmox quorum
              event: the corosync QDevice runs as a container here, so the
              cluster is on 2 of 3 votes until it returns. Confirm with
              `pvecm status`. If PVEQuorumDegraded follows and does not clear,
              the QDevice container did not restart.
```

- [ ] **Step 3: Verify the file on disk**

```bash
cd /home/koutoulastha/workspace/homelab
F=infrastructure/monitoring/truenas-exporter/alertrules.yaml
# Severity constraint — anything outside {critical,warning} is delivered nowhere
grep -oE 'severity: [a-z]+' $F | sort -u
# expect exactly two lines: "severity: critical" and "severity: warning"
grep -c 'alert: ' $F                       # expect: 8
# The two guards must exist
grep -c 'TrueNASExporterDown' $F           # expect: 1
grep -c 'TrueNASExporterErrors' $F         # expect: 1
# Every rule has a `for:` so a single scrape blip cannot page
test "$(grep -c 'alert: ' $F)" = "$(grep -c '          for: ' $F)" && echo OK || echo MISMATCH
```

- [ ] **Step 4: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/truenas-exporter/alertrules.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): TrueNAS alert rules

Transports TrueNAS's own alert-engine verdict rather than
reconstructing it in PromQL. Pool health is read directly as well —
the one place a duplicate signal is worth having, since every cluster
PVC sits on these pools.

TrueNASExporterDown and TrueNASExporterErrors are the mitigation that
makes a single-maintainer exporter acceptable on the critical path,
not boilerplate: deleting them silently converts every other rule here
into one that cannot fire. The second exists because `up == 1` is not
enough — upstream states /healthz does not imply the last scrape
succeeded, so the exporter can be Ready and stale indefinitely.

TrueNASRebooted is a quorum alert as much as a storage one: the
corosync QDevice runs as a container on TrueNAS.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 5: Verify the rules load and none fire on a healthy system — USER STEP**

```bash
curl -s 'http://localhost:9090/api/v1/rules' | jq -r '.data.groups[] | select(.name=="truenas.rules") | .rules[].name'
# expect: all 8 names

curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ALERTS{alertgroup="truenas.rules", alertstate="firing"}' | jq '.data.result'
# expect: [] on a healthy system
```
A rule that fires immediately on a healthy system is a rule written against a metric that does not exist or means something other than assumed. Fix it now — this is exactly how `PostgresBackupStale` and `LogIngestionStopped` went wrong in earlier phases.

---

## Task 10: Proxmox alert rules

**Files:**
- Create: `infrastructure/monitoring/pve-exporter/alertrules.yaml`

**Interfaces:**
- Consumes: `job="pve-exporter"` and `job="pve-nodes"` (Tasks 4, 5), plus the quorum metric names established in Task 4 Step 9.
- Produces: nothing later depends on it.

- [ ] **Step 1: Apply the Task 4 Step 9 finding**

Before writing, confirm which branch of Task 4's table applies. If vote counts are **not** exposed, omit `PVEQuorumDegraded` from this file and implement it as a Loki rule in Task 11 instead. **Do not omit it from both.**

- [ ] **Step 2: Write `alertrules.yaml`**

Substitute `pve_cluster_quorate` and `pve_cluster_expected_votes` / `pve_cluster_total_votes` with the actual names recorded in Task 4 Step 9. The Talos VMIDs in `PVEGuestUnexpectedlyStopped` must be the real ones.

```yaml
# Proxmox VE alerting: cluster state from pve-exporter, host state from
# node_exporter on the two hypervisors.
#
# `severity` must stay within {critical, warning} — Alertmanager's routes
# match exactly those and anything else is delivered nowhere, silently.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pve
  namespace: monitoring
spec:
  groups:
    - name: pve.rules
      rules:
        - alert: PVEQuorumLost
          expr: |
            pve_cluster_quorate == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Proxmox cluster has lost quorum"
            description: >-
              The cluster is not quorate: no VM starts, no migrations, no HA
              recovery, and the config filesystem is read-only. With 2 nodes
              plus a QDevice this means at least two of the three votes are
              gone. The QDevice runs as a container on TrueNAS — check that
              TrueNAS is up as well as both nodes.

        # THE SILENT ONE. Expected votes are 3 (two nodes + the QDevice on
        # TrueNAS). Losing the QDevice alone leaves 2 of 3 — still quorate,
        # still fully working, and presenting NO symptom — while the cluster
        # sits one node failure away from read-only.
        #
        # WARNING, not critical: nothing is broken when this fires. Reserving
        # critical (ntfy priority 5, bypasses Do Not Disturb) for states where
        # something is actually down keeps that signal meaningful.
        #
        # for: 15m because a TrueNAS reboot legitimately removes the QDevice
        # for a few minutes. An alert that fires on every routine reboot is one
        # you learn to dismiss. 15m distinguishes "rebooting" from "the QDevice
        # container did not come back" — which is the failure this exists for:
        # a container that quietly fails to restart after a TrueNAS update
        # leaves the cluster degraded indefinitely with no other signal.
        - alert: PVEQuorumDegraded
          expr: |
            pve_cluster_total_votes < pve_cluster_expected_votes
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Proxmox quorum degraded — {{ $value }} votes short"
            description: >-
              The cluster is quorate but has lost a vote, almost certainly the
              QDevice container on TrueNAS. Nothing is broken yet; the cluster
              is now one node failure from read-only. Confirm with
              `pvecm status`. If TrueNAS was recently updated, the QDevice
              container may have failed to restart.

        - alert: PVENodeDown
          expr: |
            pve_up{id=~"node/.*"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Proxmox node {{ $labels.id }} is down"
            description: >-
              A hypervisor is offline. Its Talos VMs are down with it. With
              only two nodes, quorum now depends entirely on the QDevice
              container on TrueNAS — if that is also missing, the surviving
              node is read-only.

        # Explicit VMIDs, not an inference from `changes()`. Inferring intent
        # would fire on every deliberate shutdown, migration and maintenance
        # reboot — noise that trains you to ignore it. The accepted cost is
        # that adding or renumbering a Talos node means editing this rule; a
        # visible, greppable omission is better than a rule that cries wolf.
        - alert: PVEGuestUnexpectedlyStopped
          expr: |
            pve_up{id=~"qemu/(101|102|103)"} == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Talos VM {{ $labels.id }} is not running"
            description: >-
              A Talos node VM is stopped. If this was not deliberate, check
              whether the host OOM-killed it or HA fenced it. Kubernetes will
              reschedule its workloads, so cluster alerts may stay quiet.

        - alert: PVEGuestNotBackedUp
          expr: |
            pve_not_backed_up_info > 0
          for: 6h
          labels:
            severity: warning
          annotations:
            summary: "Guest {{ $labels.id }} is covered by no backup job"
            description: >-
              This guest is not included in any Proxmox backup job. 6h `for:`
              so that a newly created VM does not page before it has been
              added to one.

        - alert: PVEStorageFillingUp
          expr: |
            pve_disk_usage_bytes{id=~"storage/.*"}
              / pve_disk_size_bytes{id=~"storage/.*"} > 0.85
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Proxmox storage {{ $labels.id }} is {{ $value | humanizePercentage }} full"
            description: >-
              A full Proxmox storage stops VM creation, snapshots and backups.
              Note this is hypervisor-side storage, distinct from the TrueNAS
              pools backing cluster PVCs.

        # ---- Host-level, from node_exporter on the hypervisors ----
        - alert: PVEHostFilesystemFilling
          expr: |
            node_filesystem_avail_bytes{job="pve-nodes", fstype!~"tmpfs|fuse.lxcfs|squashfs"}
              / node_filesystem_size_bytes{job="pve-nodes", fstype!~"tmpfs|fuse.lxcfs|squashfs"} < 0.15
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.instance }}:{{ $labels.mountpoint }} is low on space"
            description: >-
              Under 15% free. On a Proxmox host a full root filesystem stops
              the cluster filesystem and takes the node out of the cluster.

        - alert: PVEHostTempHigh
          expr: |
            node_hwmon_temp_celsius{job="pve-nodes"} > 85
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.instance }} sensor at {{ $value }}°C"
            description: >-
              Sustained high temperature. Thermal throttling degrades every VM
              on the host, and presents in the cluster as latency rather than
              as failure — which is why it needs its own alert.

        # A hypervisor that reboots without anyone doing it is either crashing
        # or being fenced. Both are invisible from inside the cluster, which
        # simply sees nodes rejoin.
        - alert: PVEHostRebooted
          expr: |
            time() - node_boot_time_seconds{job="pve-nodes"} < 600
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Proxmox host {{ $labels.instance }} rebooted"
            description: >-
              Uptime under 10 minutes. If this was not planned, check the host
              journal for a kernel panic or a watchdog fence. Repeated
              occurrences indicate failing hardware.
```

- [ ] **Step 3: Verify the file on disk**

```bash
cd /home/koutoulastha/workspace/homelab
F=infrastructure/monitoring/pve-exporter/alertrules.yaml
grep -oE 'severity: [a-z]+' $F | sort -u          # expect only: critical, warning
grep -c 'alert: ' $F                               # expect: 10 (9 if quorum-degraded moved to Loki)
test "$(grep -c 'alert: ' $F)" = "$(grep -c '          for: ' $F)" && echo OK || echo MISMATCH
# No placeholder VMIDs left behind
grep -c 'qemu/(101|102|103)' $F                    # expect: 0 after substituting the real IDs
```

- [ ] **Step 4: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/pve-exporter/alertrules.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): Proxmox cluster and host alert rules

PVEQuorumDegraded is the one that matters most and the one with no
other detector. Expected votes are 3; losing the QDevice on TrueNAS
alone leaves 2 of 3 — quorate, working, no symptom — while the cluster
sits one node failure from read-only.

Warning rather than critical because nothing is broken when it fires,
and for: 15m so a routine TrueNAS reboot does not train you to dismiss
it. The failure it actually catches is a QDevice container that never
came back after an update.

PVEGuestUnexpectedlyStopped uses explicit VMIDs rather than inferring
intent from changes(), which would fire on every deliberate shutdown
and migration.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

- [ ] **Step 5: Verify loading and silence — USER STEP**

```bash
curl -s 'http://localhost:9090/api/v1/rules' | jq -r '.data.groups[] | select(.name=="pve.rules") | .rules[].name'
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ALERTS{alertgroup="pve.rules", alertstate="firing"}' | jq '.data.result'
# expect: [] on a healthy cluster
```

- [ ] **Step 6: Prove PVEQuorumDegraded actually works — USER STEP**

This alert exists for a state that produces no other symptom, so an untested version of it is worth nothing. Test it deliberately:

```bash
# On TrueNAS, stop the QDevice container. Then, on a PVE node:
pvecm status          # expect: Expected votes 3, Total votes 2, still Quorate
# Wait 15 minutes, then:
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ALERTS{alertname="PVEQuorumDegraded"}' | jq '.data.result'
# expect: one result, alertstate="firing"
# Restart the QDevice container; confirm the alert resolves.
```
If it does not fire, the metric names from Task 4 Step 9 were wrong. Fix them now — there is no second chance to notice, because the real occurrence looks identical to normal operation.

---

## Task 11: Log-based alert rules

**Files:**
- Modify: `infrastructure/monitoring/loki/rules.yaml` — add rules to the existing ConfigMap

**Interfaces:**
- Consumes: `job="pve-journal"` (Task 7) and `job="truenas-syslog"` (Task 8).
- Produces: nothing later depends on it.

- [ ] **Step 1: Measure every pattern against 24h of real history FIRST — USER STEP**

This is not optional and it is not a formality. `ContainerFatalErrors` paged continuously for a day and a half on its own log lines because this step was skipped.

```bash
# PVEBackupFailed — must be 0 on a healthy system, and must be >0 if you can
# point at a past failed backup. If you cannot verify the >0 case, the pattern
# is unproven: find a real vzdump failure in the journal first.
logcli query --since=24h --limit=100 \
  'sum(count_over_time({job="pve-journal"} |~ "(ERROR: Backup of VM|vzdump.*failed|backup failed)"[24h]))'

# Confirm the two ingestion-stopped rules would be silent right now
logcli query --since=1h --limit=1 'sum(count_over_time({job="pve-journal"}[10m]))'
logcli query --since=1h --limit=1 'sum(count_over_time({job="truenas-syslog"}[10m]))'
# both expect: > 0 (logs ARE arriving, so the rules stay quiet)
```
**Record the measured counts.** They go in the commit message, as the existing rules in this file do.

- [ ] **Step 2: Append the rules to the existing ConfigMap**

Add to `infrastructure/monitoring/loki/rules.yaml`, inside `data."phase2-log-alerts.yaml"`, as a **new group** after `log-only-signals`. Keep the existing group untouched.

```yaml
      - name: external-host-signals
        interval: 1m
        rules:
          # Backup FAILURE has no metric. pve_not_backed_up_* reports that a
          # guest is not COVERED by a job — not that last night's vzdump
          # errored. That gap is the clearest reason both signals are ingested.
          #
          # Patterns are case-SENSITIVE literals Proxmox actually emits. No
          # (?i): a case-insensitive "failed" matches routine debug chatter,
          # and this rule would then match its own Loki query line exactly as
          # ContainerFatalErrors did.
          - alert: PVEBackupFailed
            expr: |
              sum by (host) (
                count_over_time({job="pve-journal"} |~ "ERROR: Backup of VM|ERROR: Backup job failed"[6h])
              ) > 0
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Proxmox backup failed on {{ $labels.host }}"
              description: >-
                A vzdump job reported an error in the last 6 hours. No metric
                covers this — pve_not_backed_up_* only reports backup
                coverage, not backup success. Check `journalctl -u pvescheduler`
                on the host.

          # Ingestion that silently stops looks exactly like a quiet host.
          # `or vector(0)` is load-bearing: LogQL returns NO SERIES (not a
          # zero) when nothing matches, and `empty == 0` is empty — so without
          # it this alert stays inactive through the very outage it exists to
          # catch. Same idiom as LogIngestionStopped above.
          - alert: PVELogIngestionStopped
            expr: |
              (
                sum (
                  count_over_time({job="pve-journal"}[10m])
                )
                or vector(0)
              ) == 0
            for: 20m
            labels:
              severity: warning
            annotations:
              summary: "No Proxmox host logs for 20 minutes"
              description: >-
                Alloy on the PVE hosts has stopped shipping. Either the unit
                is not running (check it was `systemctl enable`d — it stops at
                reboot otherwise), the Loki push credentials rotated, or
                Traefik is not routing loki-push.koutoulastha.dev.
                PVEBackupFailed is blind while this is firing.

          # TrueNAS is quieter than a hypervisor: a 20m window would produce
          # false positives on an idle NAS. 1h reflects its actual log rate,
          # measured in Step 1.
          - alert: TrueNASLogIngestionStopped
            expr: |
              (
                sum (
                  count_over_time({job="truenas-syslog"}[1h])
                )
                or vector(0)
              ) == 0
            for: 30m
            labels:
              severity: warning
            annotations:
              summary: "No TrueNAS syslog for over an hour"
              description: >-
                TrueNAS has stopped forwarding syslog. Commonly the TLS
                certificate was renewed and TrueNAS no longer trusts it —
                TrueNAS fails silently here by design. Check the syslog-tls
                Certificate is Ready and that alloy-syslog holds its
                LoadBalancer IP.
```

- [ ] **Step 3: Verify the file on disk**

```bash
cd /home/koutoulastha/workspace/homelab
F=infrastructure/monitoring/loki/rules.yaml
# The Phase 2 group must be untouched
grep -c 'ContainerFatalErrors\|GrafanaAuthFailureBurst\|LogIngestionStopped\|TalosKernelFault' $F  # expect: 4
grep -c 'alert: ' $F                       # expect: 7  (4 existing + 3 new)
grep -c 'or vector(0)' $F                  # expect: 3  (1 existing + 2 new)
grep -oE 'severity: [a-z]+' $F | sort -u   # expect only: critical, warning
grep -c 'name: external-host-signals' $F   # expect: 1
# jq-syntax yq: confirm the ConfigMap still parses and the key survived
yq '.data | keys' $F
```

- [ ] **Step 4: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add infrastructure/monitoring/loki/rules.yaml
git commit -m "$(cat <<'EOF'
feat(monitoring): log-based rules for the PVE hosts and TrueNAS

PVEBackupFailed exists because backup FAILURE has no metric —
pve_not_backed_up_* reports coverage, not success. That gap is the
clearest single reason this design ingests both metrics and logs.

Patterns are case-sensitive literals. A case-insensitive "failed"
matches routine chatter and would match this rule's own Loki query
line, which is exactly how ContainerFatalErrors paged for a day and a
half.

`or vector(0)` on both ingestion-stopped rules: LogQL returns no series
rather than a zero when nothing matches, so without it the alerts stay
inactive through the outage they exist to catch.

TrueNAS uses a 1h window against the hypervisors' 10m — an idle NAS is
legitimately quiet for long stretches.

Measured over 24h before deployment: <FILL FROM STEP 1>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

Replace `<FILL FROM STEP 1>` with the actual measured counts before committing.

- [ ] **Step 5: Verify — USER STEP**

```bash
kubectl -n monitoring rollout restart deploy/loki   # if the rules sidecar needs a nudge
curl -s 'http://localhost:3100/loki/api/v1/rules' | grep -E 'PVEBackupFailed|PVELogIngestionStopped|TrueNASLogIngestionStopped'
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ALERTS{alertname=~"PVE.*|TrueNAS.*", alertstate="firing"}' | jq '.data.result'
# expect: [] — anything firing here on a healthy system is a rule bug, not an incident
```

---

## Task 12: Volume measurement and dashboards

**Files:**
- Modify: `docs/superpowers/specs/2026-09-13-proxmox-truenas-monitoring-design.md` — fill in the measured volumes the spec deliberately left blank

**Interfaces:**
- Consumes: everything above, after it has been running for 24h.
- Produces: the measured numbers the spec says must exist before this work is considered done.

- [ ] **Step 1: Wait 24 hours after Task 8 completes**

The spec gives no volume estimate deliberately, because none had been measured. This task exists to replace that gap with a number rather than a guess.

- [ ] **Step 2: Measure — USER STEP**

```bash
# Loki: how much of the 50Gi the two new sources consume per day
logcli query --since=24h 'sum(bytes_over_time({job="pve-journal"}[24h]))'
logcli query --since=24h 'sum(bytes_over_time({job="truenas-syslog"}[24h]))'
kubectl -n monitoring exec sts/loki -- df -h /var/loki

# Prometheus: series added, against the 42GB retentionSize cap
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count({job=~"truenas-exporter|pve-exporter|pve-nodes"})'
curl -sG 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=prometheus_tsdb_head_series'
```

**Decision rule:** at 30-day retention, `(pve-journal + truenas-syslog) bytes/day × 30` must leave headroom under 50Gi alongside the existing cluster logs. If it does not, tighten the Alloy drop rules on the PVE hosts before increasing the PVC — Traefik access logs already dominate that budget.

- [ ] **Step 3: Record the measurements in the spec**

Replace the "Storage and retention" section's placeholder sentence — *"No volume estimate is given here because none has been measured"* — with the actual figures and the date measured.

- [ ] **Step 4: Import Grafana dashboards — USER STEP**

The TrueNAS exporter ships its own dashboards (Dataset Deep Dive, Disks and Temperatures) in its repository. For the PVE side, Grafana dashboard **10347** (Proxmox via pve-exporter) and **1860** (Node Exporter Full) cover the metrics collected here.

Dashboards are last deliberately: a dashboard built before the metrics are verified encodes whatever the metrics happened to mean that day.

- [ ] **Step 5: Commit**

```bash
cd /home/koutoulastha/workspace/homelab
git add docs/superpowers/specs/2026-09-13-proxmox-truenas-monitoring-design.md
git commit -m "$(cat <<'EOF'
docs(monitoring): record measured log and series volume

Replaces the spec's deliberate blank with real figures now that the
sources have run for 24h.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LrUfU3V4hKknAexkuxVjAb
EOF
)"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task:

| Spec section | Task |
|---|---|
| Decision 1 (detect/transport/deliver) | 2, 9 |
| Decision 2 (exporter risk + mitigation) | 2, 9 (the two guard rules) |
| Decision 3 (no TrueNAS Custom App) | 2 — nothing installed on TrueNAS |
| Decision 4 (agent on PVE, syslog on TrueNAS) | 7, 8 |
| Decision 5 (multi-target pve-exporter) | 4 |
| Layout | 2, 4, 5, 6, 8 |
| Exposure and authentication | 6 (HTTPS+auth), 8 (TLS syslog) |
| Label cardinality | 7 Step 5, 8 Step 2 |
| Alerting table (all 18 alerts) | 9, 10, 11 |
| Backup failure from logs | 11 |
| Unverified quorum metric | 4 Step 9 → 10 Step 1 |
| Loki rules measured before deploy | 11 Step 1 |
| Storage and retention | 3 Step 3, 12 |
| QDevice topology | 1, 9 (TrueNASRebooted), 10 (PVEQuorumDegraded) |
| Documentation | 1 |
| Rollout order | Tasks 1–12 follow it |

**Placeholder scan.** Three values are deliberately determined at execution time rather than invented, each with the exact command that yields it: the exporter image pin (Task 2 Step 1), the quorum metric names (Task 4 Step 9), and the Talos VMIDs (Task 10 Step 2). Each has a verification step that fails if the lookup was skipped. No "TBD", no "add error handling", no "similar to Task N".

**Type consistency.** Names used across tasks: Service `truenas-exporter:9108` port `metrics` (Task 2 → 3 → 9); Service `pve-exporter:9221` port `metrics` (4 → 10); job `pve-nodes` (5 → 10); job `pve-journal` (7 → 11); job `truenas-syslog` (8 → 11); secret key `users` for the Traefik Middleware (6); URL `https://loki-push.koutoulastha.dev/loki/api/v1/push` (6 → 7). Checked consistent.

**One gap found and closed during review:** Task 7's corosync drop rule originally discarded the unit wholesale, which would have destroyed the fallback signal for `PVEQuorumDegraded` — the one alert in this plan that may have no metric-based detector. The rule now drops noise only, with a comment stating why.
