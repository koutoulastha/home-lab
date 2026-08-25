# homelab

GitOps configuration for a multi-node **Talos Linux** Kubernetes cluster, managed by **ArgoCD**, with persistent storage backed by **TrueNAS SCALE**.

## Deployment model — read this first

Two things about this repo are not obvious and will waste your time if you miss them:

**1. `main` is the deployment branch.** Every ArgoCD `Application` sets `targetRevision: main`. Anything merged to `main` is live; anything on another branch is not.

**2. There is no app-of-apps or ApplicationSet.** Each `application.yaml` must be registered with ArgoCD **once**, by hand:

```bash
kubectl apply -f infrastructure/<component>/application.yaml
```

After that, ArgoCD self-heals the component's *contents* from git — but it will never notice a **new** `Application` manifest that you only committed. Committing an `application.yaml` deploys nothing on its own.

Before debugging a component that "isn't deploying", confirm it is actually registered:

```bash
kubectl -n argocd get applications
```

## Layout

```
infrastructure/
  cicd/argocd/            # ArgoCD managing itself
  cert-manager/           # + ClusterIssuer (Cloudflare DNS-01)
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
  helm-webapp/            # demo chart, deployed to the `dev` namespace (manual sync)
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
3. Commit and merge to `main`.
4. `kubectl apply -f <path>/application.yaml` **once** to register it.

## Known gotchas

- **PodSecurity:** unlabeled namespaces inherit a cluster-wide `baseline` enforce level. Workloads needing `privileged` (notably CSI **node** DaemonSets) are rejected silently — the DaemonSet reports desired > 0 / current 0 and pods never appear. Fix via `managedNamespaceMetadata` on the Application.
- **Floating chart versions:** `cert-manager` and `traefik` use `targetRevision: "*"`, so `selfHeal` upgrades them unattended. Every other chart is pinned. Pin these two unless you want surprise upgrades.
- **ACME + Pangolin delegation:** hosts put behind the Pangolin tunnel get an `_acme-challenge.<host>` CNAME pointing at `*.cname.pangolin-ns.net`. cert-manager follows `_acme-challenge` CNAMEs unconditionally, so it reads Pangolin's TXT instead of its own and the challenge hangs on "not yet propagated" forever — silently, since that path logs at debug level. This is why TLS is one **wildcard** cert (`infrastructure/networking/gateway/certificate.yaml`): a wildcard validates at `_acme-challenge.koutoulastha.dev`, which carries no delegation. Diagnose DNS-01 failures with `dig CNAME` on the challenge name, never a bare `dig TXT` — Cloudflare serves both and the TXT lookup looks correct.
- **LAN DNS:** `*.koutoulastha.dev` resolves only through local DNS. Browser DNS-over-HTTPS breaks resolution even while `curl` works.
- **Talos + iSCSI:** nodes need the `siderolabs/iscsi-tools` and `util-linux-tools` system extensions before any iSCSI PVC will mount. NFS needs no extension.

## Tooling

`devbox shell` provides kubectl, kubeseal, opentofu, talosctl, and kubelogin-oidc, and exports `KUBECONFIG` / `TALOSCONFIG`.
