# Proxmox and TrueNAS monitoring — design

Date: 2026-09-13
Status: approved, not yet implemented
Depends on: Phase 1 (kube-prometheus-stack), Phase 2 (Loki + Alloy)

## Goal

Bring the two pieces of infrastructure the cluster runs *on* into the monitoring
that currently only watches what runs *in* it:

- **Proxmox VE 9.2.3**, 2 nodes plus a QDevice, hosting the Talos VMs.
- **TrueNAS SCALE 25.10.7**, separate bare metal, backing every PVC through
  democratic-csi.

Four outcomes, all four requested explicitly:

1. Storage failure on TrueNAS is alerted — degraded pool, failing disk, scrub
   errors, pool filling.
2. Proxmox host degradation is alerted — quorum loss, node down, a stopped Talos
   VM, host filesystem or thermal problems.
3. Logs from both hosts land in the existing Loki alongside cluster logs.
4. Both hosts have Grafana dashboards for capacity and trending.

## What the dead man's switch already covers

Total Proxmox failure is **already detected**. The cluster runs on Proxmox, so if
the hypervisor dies the cluster stops pinging healthchecks.io and the existing
external dead man's switch fires. This design does not need to solve that, and
should not be justified by it.

The gap it closes is **degradation**: a failing host disk, thermal throttling, a
fenced VM, quorum silently reduced to one — states where the cluster keeps
pinging happily while the hardware under it is dying.

## Non-goals

- **No `node_exporter` Custom App on TrueNAS.** Considered and rejected — see
  Decisions. The API exporter already covers CPU, memory, disks, temperatures,
  network and ARC.
- **No SSH on TrueNAS.** It is disabled by deliberate decision; democratic-csi
  works entirely over the API and this design does too.
- **No Graphite export path.** TrueNAS 25.04 dropped most default metrics from
  that path, and restoring them requires installing a custom Netdata config on
  the appliance. Appliance mutation with none of the upside.
- **No second notification channel.** Everything reaches ntfy through the
  existing Alertmanager route. No Telegram, no Slack shim.
- **No per-guest metrics from inside the Talos VMs.** They are already scraped as
  Kubernetes nodes.

## Decisions

### 1. TrueNAS detects, Prometheus transports, Alertmanager delivers

The obvious framing — "should storage alerts come from TrueNAS or from
Alertmanager?" — is a false choice, and the three-way split is better than either
answer:

- **TrueNAS detects.** Its alert engine decides *pool degraded*, *SMART failing*,
  *scrub found errors*. It has vendor context we cannot reconstruct from scraped
  metrics, and reimplementing its judgement in PromQL would be strictly worse.
- **The exporter transports.** Those alerts arrive in Prometheus as metrics via
  the `alerts` collector.
- **Alertmanager delivers.** One notification path, the existing ntfy route.

This was not the original plan. The first design had TrueNAS pushing to ntfy
directly through an Alert Service. **That does not work:** TrueNAS 25.10 offers
Slack, Mattermost, OpsGenie, PagerDuty, SNMP Trap, Telegram, VictorOps and AWS
SNS — generic webhooks and ntfy are both roadmap requests, not shipped features.
The community answer is a container that mocks a Slack webhook and re-emits to
ntfy.

That shim was rejected on a failure-mode argument, not a complexity one: **a dead
shim is indistinguishable from "nothing is wrong."** A silent alerting path is
the worst property such a path can have. Routing through Prometheus means a
broken transport shows up as `up == 0` — loud, and alertable.

### 2. The TrueNAS exporter is a considered risk, not an oversight

`Unknowlars/truenas-scale-api-prometheus-exporter` is single-maintainer, its
README states it was *"built mostly by AI over a few weeks"*, and it is
*"maintained against TrueNAS SCALE 25.10.2"*. We run 25.10.7 — same minor series,
so version risk is a future upgrade problem rather than a today problem.

Accepted because the engineering hygiene is visibly better than the disclaimer
suggests: a documented cardinality-impact table with conservative defaults,
insistence on a **read-only** API key, TLS verification on by default, and it
exports its own API-failure and collector-error counters.

That last point is what makes it tolerable on the critical path. **The mitigation
is `TrueNASExporterDown` plus rules on its internal error counters** — its README
is explicit that `/healthz` confirms only that the process is serving HTTP and
does *not* guarantee the last scrape succeeded, so liveness alone would lie.

**Revisit this decision at every TrueNAS major upgrade.**

### 3. No `node_exporter` Custom App on TrueNAS

The original answer during brainstorming was "exporters as TrueNAS Apps". That
was overridden after establishing what the API exporter already covers. A second
Custom App would duplicate CPU, memory, disk, temperature, network and ARC
metrics, double the surface a TrueNAS upgrade can break, and buy nothing.

If the API exporter later proves insufficient, adding it is a small follow-up.
Starting with it is unearned complexity.

### 4. Proxmox gets an agent, TrueNAS does not

Deliberately asymmetric. Proxmox is plain Debian with root and a Grafana apt
repo, so `node_exporter` and Alloy install as ordinary packages. journald carries
`_SYSTEMD_UNIT`, `PRIORITY` and `_COMM`, which Alloy turns into labels.

TrueNAS cannot take an agent once decision 3 stands, so it uses the built-in
Syslog Server setting and accepts the flatter syslog representation. Forwarding
Proxmox by syslog too would flatten its journald metadata for symmetry's sake and
lose the ability to query by unit.

### 5. `pve-exporter` is multi-target, not one pod per node

One pod, scraped twice with `?target=pve1` / `?target=pve2` via `relabel_configs`
— the same pattern `blackbox-exporter` already uses in this repo. With two nodes,
the API endpoint being polled can itself be the dead one, so each node is scraped
independently rather than through a single cluster endpoint.

## Layout

```
infrastructure/monitoring/
  truenas-exporter/
    application.yaml
    deployment.yaml          # plain manifests — see below
    service.yaml
    sealed-secret.yaml       # read-only TrueNAS API key
    servicemonitor.yaml
    alertrules.yaml
  pve-exporter/
    application.yaml
    deployment.yaml
    service.yaml
    sealed-secret.yaml       # PVE API token (PVEAuditor)
    servicemonitor.yaml      # multi-target, ?target= per node
    nodes-service.yaml       # selector-less Service + EndpointSlice for the
    nodes-servicemonitor.yaml  #   two hosts' node_exporter
    alertrules.yaml
  alloy-syslog/
    application.yaml
    values.yaml              # grafana/alloy chart: loki.source.syslog, TLS 6514
    certificate.yaml         # cert-manager cert for the syslog listener
  loki/
    httproute-push.yaml      # NEW: loki-push.koutoulastha.dev
    middleware-basicauth.yaml
    sealed-secret-push.yaml  # htpasswd
```

Three new ArgoCD Applications, each following the `blackbox-exporter` precedent:
deployed into the `monitoring` namespace, **no `CreateNamespace=true` and no
`managedNamespaceMetadata`** — that namespace is owned by `kube-prometheus-stack`,
which sets its PodSecurity labels, and a second Application managing its metadata
would contend over it.

**The `loki/` additions need no new Application and no re-registration.** The
existing `loki` Application already declares `path: infrastructure/monitoring/loki`
with `directory.exclude: '{application.yaml,values.yaml}'`, so any manifest
dropped in that directory syncs on commit — the same mechanism that let
`rules.yaml` appear in Phase 2 Task 5 without re-registering anything.

**Plain manifests, not charts, for the two exporters.** Neither publishes a Helm
chart in a repository this cluster already trusts; the TrueNAS exporter ships
docker-compose, and `pve-exporter`'s packaging is a container image plus a PyPI
distribution. A Deployment and a Service each is less indirection than wrapping
them. If implementation finds a maintained upstream chart, prefer it — and pin an
explicit `targetRevision`, as every other Helm source in this repo does.
`alloy-syslog` does use a chart, the same `grafana/alloy` one the three existing
Alloy Applications use.

## Exposure and authentication

### The availability argument

The instinct is that Proxmox host logs should not traverse cluster ingress, since
you want them most when the cluster is unhealthy. **That reasoning is wrong, and
the reason matters: Loki is itself in the cluster.** If the cluster is down, host
logs have nowhere to land regardless of path. Adding Traefik introduces almost no
new failure correlation — the dependency is already total.

Traefik therefore carries it, which buys TLS and authentication for free.

### Proxmox → Loki over HTTPS

Alloy on each PVE node pushes to a new `loki-push.koutoulastha.dev` HTTPRoute,
restricted to `/loki/api/v1/push`, gated by a Traefik `Middleware` basic-auth
filter attached via `ExtensionRef`. Gateway API has no native basic-auth filter;
Traefik v3's extension point is the supported route. The htpasswd is committed as
a sealed secret.

No new LoadBalancer IP. Covered by the existing wildcard certificate.

Loki runs `auth_enabled: false` with `gateway.enabled: false` and has only ever
been reachable in-cluster. **This gives its push path authentication it does not
currently have even internally.**

### TrueNAS → syslog

The only new L4 exposure. TrueNAS's built-in Syslog Server setting forwards to
`alloy-syslog` on a LoadBalancer IP from the Cilium `192.168.20.240-250` pool
(Traefik holds two, so roughly nine are free). 25.10 supports TLS syslog
transport, so this is **TCP+TLS on 6514**, not plaintext 514, using a
cert-manager certificate.

Net result: one new LAN-facing L4 endpoint, not two.

## Label cardinality

Phase 2 was bitten by this twice — the `filename` label blowout and the
`stage.label_drop` correction. The rules are stated up front here rather than
discovered:

| Source | Labels (bounded) | Structured metadata (unbounded) |
|---|---|---|
| Proxmox journald | `job`, `host`, `unit` | PID, message body |
| TrueNAS syslog | `job`, `host`, `facility`, `severity` | PID, message body |

Proxmox journald is noisy — `pvestatd`, `pve-firewall` and `corosync` emit
constantly at low value. **Dropped at the agent**, not shipped and filtered later.

## Alerting

| Alert | Severity | Source |
|---|---|---|
| `TrueNASAlertCritical` | critical | Exporter `alerts` collector — TrueNAS's own verdict |
| `TrueNASPoolNotHealthy` | critical | Pool state ≠ ONLINE |
| `TrueNASExporterDown` | critical | `up == 0` — guards the whole storage-alerting path |
| `TrueNASExporterErrors` | critical | Exporter's own API-failure / collector-error counters |
| `PVEQuorumLost` | critical | Cluster not quorate — **metric name unverified, see below** |
| `PVENodeDown` | critical | `pve_up{id=~"node/.*"} == 0` |
| `TrueNASAlertWarning` | warning | Exporter `alerts` collector |
| `TrueNASDiskTempHigh` | warning | Disk temperature |
| `TrueNASVdevErrors` | warning | vdev error counters |
| `PVEGuestUnexpectedlyStopped` | warning | `pve_up == 0` for an explicitly listed Talos VMID |
| `PVEGuestNotBackedUp` | warning | `pve_not_backed_up_info` |
| `PVEStorageFillingUp` | warning | `pve_disk_usage_bytes / pve_disk_size_bytes` |
| `PVEHostFilesystemFilling` | warning | `node_filesystem_avail_bytes` |
| `PVEHostTempHigh` | warning | `node_hwmon_temp_celsius` |
| `PVEHostRebooted` | warning | `node_boot_time_seconds` change |
| `PVEBackupFailed` | warning | **Loki rule** on `vzdump` failures in the PVE journal |
| `PVELogIngestionStopped` | warning | Mirrors the existing Loki rule, per host |
| `TrueNASLogIngestionStopped` | warning | Mirrors the existing Loki rule, per host |

### Backup failure comes from logs, not metrics

`pve_not_backed_up_total` and `pve_not_backed_up_info` report that a guest is not
*covered* by a backup job. Neither reports that last night's `vzdump` **errored**.
That is a real gap in the exporter, and it is the clearest case in this design for
why both signals are being ingested: `PVEBackupFailed` is a Loki rule against the
PVE journal, not a PromQL rule.

### "Expected running" is an explicit list, not an inference

`PVEGuestUnexpectedlyStopped` matches a **hardcoded set of Talos VMIDs** written
into the rule, not a guest that "was running and stopped". Inferring intent from
`changes()` over `pve_up` would fire on every deliberate shutdown, migration and
maintenance reboot — noise that trains you to ignore it.

The cost is honest and accepted: **adding or renumbering a Talos node means
editing this rule**, and forgetting to do so means a new node is not watched.
That is a visible, greppable omission; a rule that cries wolf is not.

### Verified metric names

Confirmed against `pve_exporter/collector/cluster.py`: `pve_up{id}`,
`pve_ha_state{id,state}`, `pve_disk_size_bytes{id}`, `pve_disk_usage_bytes{id}`,
`pve_memory_size_bytes{id}`, `pve_memory_usage_bytes{id}`,
`pve_not_backed_up_total{id}`, `pve_not_backed_up_info{id}`.

**Not confirmed: the quorum metric.** `ClusterCollector` reads `/cluster/status`
and filters `type == 'cluster'`, which is where `quorate` lives, but the exported
metric name could not be established from source. Since `PVEQuorumLost` is the
headline Proxmox alert, **the implementation must verify it against a live
`/metrics` scrape before writing the rule.** A config that parses proves nothing;
check the consumer.

### Every Loki rule is measured before deployment

`ContainerFatalErrors` paged for a day and a half on its own log lines. Same
discipline applies to `PVEBackupFailed` and both `LogIngestionStopped` variants:
**measured against 24h of real history with the match count confirmed before
deployment** — zero for patterns that should be quiet, non-zero for patterns
proven against a known past event.

## Storage and retention

Two additional hosts of logs land on the existing 50Gi Loki PVC at 30-day
retention, and new series land on Prometheus's 42GB `retentionSize` cap.

**No volume estimate is given here because none has been measured.** The
implementation plan includes a measurement step before this work is considered
complete. `LokiStorageFillingUp` already exists as a backstop.

The single knob most likely to surprise: the TrueNAS exporter's
`ENABLE_DATASET_METRICS` defaults to `true` and scales linearly with dataset
count. **democratic-csi creates a dataset or zvol per PVC**, so this grows with
cluster workloads rather than staying fixed. Measure before leaving it enabled.

## Assumption on record

**The QDevice is assumed to run on a standalone host outside both Proxmox nodes.**
This was asked twice during design and not answered.

If it in fact runs as a guest on either node, quorum is **circular** — the
tiebreaker dies with the thing it is meant to arbitrate — and `PVEQuorumLost`
would be structurally unable to fire in precisely the scenario it exists for.
Verify during implementation. If the assumption is wrong, that circularity
warrants its own alert and a note in the README.

## Rollout

Order matters; each step is verifiable before the next.

1. TrueNAS: create a **read-only** API key. Seal it. Deploy `truenas-exporter`.
2. Verify metrics, then tune cardinality knobs before adding rules.
3. Proxmox: create an API token with `PVEAuditor`. Seal it. Deploy `pve-exporter`.
4. Verify both node targets scrape. **Establish the quorum metric name here.**
5. Install `node_exporter` debs on both PVE hosts; add `nodes-service.yaml` and
   `nodes-servicemonitor.yaml` to the already-registered `pve-exporter` path.
6. Add the Loki push HTTPRoute, middleware and htpasswd — these land in the
   existing `loki/` path and sync without re-registration. Verify auth rejects
   an unauthenticated push **before** pointing any agent at it.
7. Install Alloy debs on both PVE nodes. Verify logs arrive and labels match.
8. Deploy `alloy-syslog` with its certificate. Point TrueNAS at it. Verify.
9. Measure 24h of log and series volume.
10. Write alert rules, each validated against real history.
11. Dashboards last.

Every `application.yaml` needs its one-time `kubectl apply` — there is no
app-of-apps, and committing the manifest deploys nothing.

### Verification means querying, not looking at a dashboard

A green dashboard panel is not evidence. Each step is verified by a LogQL or
PromQL query returning the expected result, or by a `curl` against the endpoint in
question.

## Known failure modes

| Symptom | Cause |
|---|---|
| Application committed, nothing deploys | Each `application.yaml` needs its one-time manual `kubectl apply` — no app-of-apps |
| All PVE targets down, cluster otherwise fine | API token lacks `PVEAuditor`, or was scoped to a single node |
| Exporter up, all TrueNAS metrics absent | Read-only key valid but WebSocket URL wrong — `wss://.../api/current`, not the REST path |
| Prometheus series count jumps hard after rollout | `ENABLE_DATASET_METRICS` defaults `true`, one set per dataset, and democratic-csi makes one per PVC |
| TrueNAS logs never arrive | Syslog TLS certificate not trusted by TrueNAS, which fails silently by design |
| Proxmox logs stop after a host reboot | Alloy deb installed but its unit never enabled |
| Loki push returns 401 from PVE only | Basic-auth sealed secret rotated without updating host-side Alloy config |
| Quorum alert never fires despite node loss | Rule written against an unverified metric name |
| Storage alerts silently stop | Exporter died or its API calls are failing — this is what `TrueNASExporterDown` and `TrueNASExporterErrors` exist to catch |
| New Application stuck `OutOfSync` with no visible diff | `ServerSideApply=true` changes how ArgoCD diffs; server-defaulted fields must be spelled out |

## Revisit triggers

- **TrueNAS major upgrade** — re-evaluate the exporter (decision 2).
- **The exporter goes unmaintained** — the fallback is SNMP, which TrueNAS
  supports natively and which survives upgrades, at the cost of coarser metrics
  and a generated `snmp_exporter` module for FREENAS-MIB.
- **Measured log volume exceeds headroom** — revisit Loki retention or the Phase 3
  object-storage question.
