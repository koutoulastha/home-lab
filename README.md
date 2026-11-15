# homelab

GitOps configuration for a multi-node **Talos Linux** Kubernetes cluster, managed by **ArgoCD**, with persistent storage backed by **TrueNAS SCALE**.

## Deployment model — read this first

Two things about this repo are not obvious and will waste your time if you miss them:

**1. `main` is the deployment branch.** Every ArgoCD `Application` sets `targetRevision: main`. Anything merged to `main` is live; anything on another branch is not.

**2. One root Application manages every Application.** [`infrastructure/cicd/argocd/root.yaml`](infrastructure/cicd/argocd/root.yaml) syncs every `apps/**/application*.yaml` and `infrastructure/**/application*.yaml` with `selfHeal: true` and `prune: false`. That means:
- A new or changed `application.yaml` deploys when it merges, chart `targetRevision` bumps included.
- Hand edits to an Application (e.g. `targetRevision: '*'`) are reverted to git.
- **Deleting an `application.yaml` deletes nothing.** Removing an app is a deliberate step: add the `resources-finalizer.argocd.argoproj.io` finalizer if you want its workloads gone, then `kubectl -n argocd delete application <name>`.

The root itself is applied **once**, by hand, and is not managed by anything:

```bash
kubectl apply -f infrastructure/cicd/argocd/root.yaml
```

Before 2026-11 there was no root, and every `application.yaml` had to be `kubectl apply`'d after each change. If a component "isn't deploying", check that the root is Synced and lists it:

```bash
kubectl -n argocd get application root
kubectl -n argocd get application root -o jsonpath='{range .status.resources[*]}{.name}{"\n"}{end}'
```

## Layout

```
infrastructure/
  cicd/argocd/            # root.yaml (app-of-apps root) + ArgoCD's own route/repo config
  cert-manager/           # + ClusterIssuer (Cloudflare DNS-01)
  database/
    cloudnative-pg/       # Postgres operator — see apps/immich/db
  monitoring/
    kube-prometheus-stack/  # Prometheus + Alertmanager + Grafana + exporters
    blackbox-exporter/      # uptime probes, incl. the Pangolin public-edge probe
  networking/
    cilium/               # CNI, L2 announcements, LB IP pool
    traefik/              # ingress via Gateway API
    gateway/              # Gateway + listeners (see note below)
  sealed-secrets/         # Bitnami controller — encrypts secrets for git
  storage/
    snapshot-controller/  # VolumeSnapshot CRDs + controller
    democratic-csi/       # iSCSI + NFS CSI drivers (see its README)
apps/
  openspeedtest/
  pangolin-newt/          # Pangolin tunnel agent
  immich/                 # photos; db/ is a separate, never-pruned Application
docs/superpowers/         # design specs + implementation plans
old/                      # pre-Kubernetes docker-compose setup
.talos/, .kube/           # Talos (Omni) and kube contexts — no credentials, auth is OIDC/exec
```

## Storage

| StorageClass | Protocol | Access | Use for |
|---|---|---|---|
| `truenas-iscsi` (**default**) | iSCSI block (ZFS zvol) | RWO | databases, single-writer state, perf-sensitive |
| `truenas-nfs` | NFS (ZFS dataset) | RWX | shared volumes, media/config, Docker-host mounts |

Omit `storageClassName` on a PVC to get `truenas-iscsi`. Snapshots via the `truenas-iscsi` VolumeSnapshotClass. Full setup, credential rotation, and gotchas: [`infrastructure/storage/democratic-csi/README.md`](infrastructure/storage/democratic-csi/README.md).

## Secrets

No plaintext secrets in git. Credentials are encrypted with **sealed-secrets** and committed as `sealed-secret.yaml`, which only the in-cluster controller can decrypt. Generate them with `kubeseal` (`devbox` provides the CLI) — see the storage README for the pattern.

## Adding a component

1. Create `<path>/application.yaml` with `targetRevision: main` and a `$values` source pointing at this repo.
2. If it needs a privileged namespace (CSI drivers, anything with hostPath/hostPID), set `spec.syncPolicy.managedNamespaceMetadata` — the cluster enforces PodSecurity `baseline` on unlabeled namespaces.
3. Commit and merge to `main`. The root Application picks it up, so there's nothing to apply by hand.

## Known gotchas

- **PodSecurity:** unlabeled namespaces inherit a cluster-wide `baseline` enforce level. Workloads needing `privileged` (notably CSI **node** DaemonSets) are rejected silently — the DaemonSet reports desired > 0 / current 0 and pods never appear. Fix via `managedNamespaceMetadata` on the Application.
- **Chart versions are pinned:** every Helm source sets an explicit `targetRevision`, so `selfHeal` never upgrades a chart on its own. Upgrades are a deliberate commit. `cert-manager` and `traefik` used to float on `"*"`. Git was pinned, but the live Applications were never re-applied and kept floating until 2026-11 (Traefik reached chart 42 that way). The root Application's `selfHeal` now prevents that. Note that jetstack's chart versions carry a `v` prefix and Traefik's do not. To check what a multi-source app actually resolved, read the **plural** status fields (`.status.sync.revisions`, `.status.sourceTypes`); the singular ones are only populated for single-source apps and read `<none>` here.
- **ACME + Pangolin delegation:** hosts put behind the Pangolin tunnel get an `_acme-challenge.<host>` CNAME pointing at `*.cname.pangolin-ns.net`. cert-manager follows `_acme-challenge` CNAMEs unconditionally, so it reads Pangolin's TXT instead of its own and the challenge hangs on "not yet propagated" forever — silently, since that path logs at debug level. This is why TLS is one **wildcard** cert (`infrastructure/networking/gateway/certificate.yaml`): a wildcard validates at `_acme-challenge.koutoulastha.dev`, which carries no delegation. Diagnose DNS-01 failures with `dig CNAME` on the challenge name, never a bare `dig TXT` — Cloudflare serves both and the TXT lookup looks correct.
- **LAN DNS:** `*.koutoulastha.dev` resolves only through local DNS. Browser DNS-over-HTTPS breaks resolution even while `curl` works.
- **Talos + iSCSI:** nodes need the `siderolabs/iscsi-tools` and `util-linux-tools` system extensions before any iSCSI PVC will mount. NFS needs no extension.
- **TrueNAS is a Proxmox quorum dependency.** The corosync QDevice runs as a container on TrueNAS, so TrueNAS is load-bearing for cluster quorum as well as for every PVC. Expected votes are 3 (two PVE nodes + the QDevice). Losing the QDevice alone leaves 2 of 3 — still quorate, still working, **no symptom at all** — while the cluster sits one node failure away from read-only: no VM starts, no migrations, no HA recovery. Consequences: never reboot or update TrueNAS while a Proxmox node is down or rebooting, and after any TrueNAS upgrade confirm the QDevice came back with `pvecm status` — an app-stack change that quietly fails to restart it leaves you degraded indefinitely. `PVEQuorumDegraded` catches this after 15 minutes. Note also that a TrueNAS outage degrades storage **and** quorum together: simultaneous storage and quorum alerts are one incident, not two.

## Tooling

`devbox shell` provides kubectl, kubeseal, opentofu, talosctl, and kubelogin-oidc, and exports `KUBECONFIG` / `TALOSCONFIG`.
