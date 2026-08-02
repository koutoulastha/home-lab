# Persistent Storage via democratic-csi + TrueNAS SCALE

**Date:** 2026-07-03
**Status:** Approved design, ready for implementation planning
**Repo:** `github.com/koutoulastha/home-lab.git` (branch `version3`)

## Problem

The Kubernetes cluster has no persistent storage solution. There is no
StorageClass, no dynamic provisioner, and no PVC support. Workloads that need
durable volumes (databases, app state, media, shared config) cannot survive pod
restarts or rescheduling across nodes. A TrueNAS SCALE box with 3× NVMe on a ZFS
mirror sits idle and is the intended backing store.

## Goals

- Dynamic persistent volume provisioning for the multi-node Kubernetes cluster,
  backed by the existing TrueNAS SCALE NAS.
- **iSCSI block** as the default StorageClass: per-PVC ZFS zvol, best
  performance, per-volume snapshots/quota/resize, safe for databases (RWO).
- **NFS** as a secondary StorageClass: `ReadWriteMany` (RWX) shared volumes, and
  the same export is mountable by Docker hosts.
- GitOps-managed through ArgoCD, matching the repo's existing multi-source
  Application pattern.
- No plaintext credentials committed to git.

## Non-Goals

- Distributed/replicated node-local storage (Longhorn, Rook-Ceph). These solve
  node-failure HA by replicating across Kubernetes nodes' own disks; they ignore
  the TrueNAS and are heavier than this homelab needs.
- Automating Talos node configuration through GitOps. Talos machine-config and
  system-extension rollout is performed out-of-band via `talosctl`.
- Migrating any existing data (there is none).
- Adopting Docker-host provisioning automation. Docker hosts consume the NFS
  export manually; they are not driven by the CSI driver.

## Context / Current State

- **Cluster:** multi-node Kubernetes; nodes are **Talos Linux** VMs on Proxmox.
- **CNI/LB:** Cilium (L2 announcement + LB pool), Traefik + Gateway API.
- **GitOps:** ArgoCD. Apps use a multi-source `Application`: an external Helm
  chart repo plus a `$values` ref back to this git repo, with
  `automated: { prune, selfHeal }` and `CreateNamespace=true`.
- **Storage backend:** TrueNAS SCALE, 3× NVMe, ZFS mirror, currently unused by
  Proxmox and Kubernetes.
- **Secrets:** no secret-management tooling exists in the repo today. This design
  introduces sealed-secrets.

## Chosen Approach

A single CSI driver — **democratic-csi** — deployed as **two independent Helm
releases**, one per TrueNAS protocol. iSCSI is the default class; NFS is
secondary. Credentials are stored as a sealed secret and decrypted in-cluster.

### Why democratic-csi (vs. alternatives considered)

- **NFS-only (csi-driver-nfs / nfs-subdir):** simplest, but no per-volume ZFS
  features and databases on NFS are risky. Rejected as the primary tier.
- **iSCSI-only:** loses RWX and Docker-host sharing for no reduction in setup
  effort — the heavy cost is standing up democratic-csi + TrueNAS wiring, which
  is identical whether one or both protocols are enabled. Rejected.
- **democratic-csi with iSCSI + NFS:** same install cost as iSCSI-only, strictly
  more capability (block default for perf/DBs, NFS for RWX + Docker). **Chosen.**

## Architecture

```
                    ┌─────────────────────── Kubernetes (multi-node Talos) ──────────────────┐
                    │                                                                        │
 PVC (default) ─────┼─▶ StorageClass: truenas-iscsi ─▶ democratic-csi-iscsi (freenas-api-iscsi)┼──┐
                    │     RWO block, per-PVC ZFS zvol                                         │  │  iSCSI
 PVC (RWX) ─────────┼─▶ StorageClass: truenas-nfs   ─▶ democratic-csi-nfs   (freenas-api-nfs) ┼──┤  + NFS
                    │     RWX file,  per-PVC ZFS dataset                                      │  │
                    └────────────────────────────────────────────────────────────────────────┘  │
                                                                                                  ▼
                                                            ┌───────────── TrueNAS SCALE ─────────────┐
                                                            │  ZFS mirror (3× NVMe)                    │
                                                            │   <pool>/k8s/iscsi/*  → zvols (iSCSI LUN)│
                                                            │   <pool>/k8s/nfs/*    → datasets (NFS)   │
                                                            └──────────────────────────────────────────┘
                                                                              ▲  NFS export
 Docker hosts (Proxmox VM) ───────────────────────────────────────────────────┘  (mounts the NFS share directly)
```

- **iSCSI (default):** each PVC → a dedicated ZFS **zvol** exported as an iSCSI
  LUN. `ReadWriteOnce`. Best performance; per-volume snapshots, quota, online
  resize; safe for databases.
- **NFS (secondary):** each PVC → a ZFS **dataset** exported over NFS. Supports
  `ReadWriteMany`. Also the export mounted by Docker hosts.

## Components

Each unit has one clear purpose and a well-defined interface.

### 1. Talos system extensions (node prerequisite — out-of-band)

iSCSI does not function on stock Talos. Nodes need:

- **`siderolabs/iscsi-tools`** — provides `iscsid` (as a Talos extension service)
  and `iscsiadm`.
- **`siderolabs/util-linux-tools`** — provides `blkid` and related utilities the
  node driver needs.

Rollout:

1. Build an installer image via **Talos Image Factory** (`factory.talos.dev`)
   with both extensions → obtain a schematic ID.
2. `talosctl upgrade --image factory.talos.dev/installer/<schematic-id>:<talos-version>`
   applied node-by-node (rolling).
3. Confirm the iscsi extension service is running on each node before proceeding.

**Interface to the rest of the system:** once nodes report the iscsi-tools
extension healthy, the democratic-csi node DaemonSet can log in to iSCSI targets.
This is a hard gate — no iSCSI PVC binds until it is complete.

### 2. sealed-secrets controller (ArgoCD-managed)

- New ArgoCD `Application`: `infrastructure/sealed-secrets/`.
- Bitnami chart `sealed-secrets` from `https://bitnami-labs.github.io/sealed-secrets`,
  installed into `kube-system` with `fullnameOverride=sealed-secrets-controller`
  (so the `kubeseal` CLI's defaults match).
- Installed **before** democratic-csi.

**Interface:** consumes `SealedSecret` CRs committed to git; emits real `Secret`s
in-cluster. Nothing else depends on its internals.

### 3. TrueNAS SCALE preparation (out-of-band)

Performed on TrueNAS before the CSI releases sync:

- Parent datasets: `<pool>/k8s/iscsi` (for zvols) and `<pool>/k8s/nfs` (for
  datasets).
- **iSCSI service:** enabled; a portal, an initiator group, and a target
  basename configured.
- **NFS service:** enabled; allowed network scoped to the cluster + Docker-host
  subnet.
- An **API key** (TrueNAS → API Keys) owned by a **`FULL_ADMIN`** user. The
  API-only drivers (`freenas-api-*`) do everything over the HTTP middleware API,
  so **no SSH access or SSH key is required** — SSH can stay disabled on TrueNAS.

### 4. democratic-csi — iSCSI release (ArgoCD-managed)

- Path: `infrastructure/storage/democratic-csi/iscsi/`
  (`application.yaml` + `values.yaml`).
- Chart: `democratic-csi` from `https://democratic-csi.github.io/charts/`
  (pinned `targetRevision`), namespace `democratic-csi`.
- Driver: `freenas-api-iscsi`, pointed at the TrueNAS API via the sealed
  credential (`driver.existingConfigSecret` referencing the decrypted Secret).
- Node section carries **Talos-specific overrides** (`hostPID: true` + iscsi host
  paths). Exact paths are pinned during implementation against democratic-csi's
  current Talos node reference — this is an explicit verify-step, not assumed
  here.
- Creates StorageClass **`truenas-iscsi`**, marked **default**
  (`storageclass.kubernetes.io/is-default-class: "true"`), plus a
  VolumeSnapshotClass.

### 5. democratic-csi — NFS release (ArgoCD-managed)

- Path: `infrastructure/storage/democratic-csi/nfs/`
  (`application.yaml` + `values.yaml`).
- Same chart, second Helm release, driver `freenas-api-nfs`, referencing the same
  (or a sibling) sealed credential.
- Creates StorageClass **`truenas-nfs`** (RWX-capable, not default).

### 6. Docker-host consumption (out-of-band, documented)

Docker hosts mount the `<pool>/k8s/nfs` export directly (fstab or a Docker NFS
volume). Independent of the CSI driver; documented in the component README.

## Repo Layout (new)

```
infrastructure/
  sealed-secrets/
    application.yaml          # ArgoCD App: Bitnami sealed-secrets chart + $values
    values.yaml
  storage/
    democratic-csi/
      iscsi/
        application.yaml       # ArgoCD App: democratic-csi chart + $values
        values.yaml            # freenas-api-iscsi; SC truenas-iscsi (default); snapshot class
      nfs/
        application.yaml
        values.yaml            # freenas-api-nfs; SC truenas-nfs (RWX)
      README.md                # Talos extension rollout, TrueNAS prep, kubeseal steps,
                               # Docker-host NFS mount — all the out-of-band runbook steps
docs/superpowers/specs/
  2026-07-03-persistent-storage-democratic-csi-design.md   # this file
```

All ArgoCD Applications follow the existing multi-source convention: external
Helm chart repo + a `ref: values` source pointing at
`https://github.com/koutoulastha/home-lab.git` @ `version3`, with
`automated: { prune: true, selfHeal: true }` and `CreateNamespace=true`.

## Data Flow (provisioning a volume)

1. A workload's PVC names `truenas-iscsi` (or omits `storageClassName` → default).
2. democratic-csi controller calls the TrueNAS API, creates a zvol under
   `<pool>/k8s/iscsi/`, and exposes it as an iSCSI LUN.
3. The node DaemonSet (using the iscsi-tools extension) logs into the target,
   attaches the block device, formats and mounts it into the pod.
4. On pod delete + reschedule to another node, the volume detaches and reattaches
   on the new node; data persists in the zvol.
5. For `truenas-nfs`, the controller creates a dataset under `<pool>/k8s/nfs/`,
   exports it, and pods mount it over NFS — multiple pods concurrently for RWX.

## Secrets Handling

- The driver config (TrueNAS API key) is **never committed in plaintext**. The
  API-only drivers use no SSH key.
- Operator runs `kubeseal` locally against the cluster's sealed-secrets
  controller to produce a `SealedSecret`, which **is** safe to commit.
- The controller decrypts it in-cluster into the real `Secret`; each
  democratic-csi release references that Secret via `driver.existingConfigSecret`.
- `kubeseal` CLI is installed locally from the sealed-secrets GitHub releases.

## Build Order (phased)

- **Phase 0 — Node & backend prep (out-of-band, gating):** roll out Talos
  `iscsi-tools` + `util-linux-tools` extensions via Image Factory + `talosctl
  upgrade`; prepare TrueNAS datasets, iSCSI/NFS services, and a `FULL_ADMIN`
  API key (no SSH key needed).
- **Phase 1 — Secrets:** deploy sealed-secrets controller via ArgoCD; install
  `kubeseal`; seal the TrueNAS driver config and commit the `SealedSecret`.
- **Phase 2 — iSCSI:** deploy democratic-csi iSCSI release; `truenas-iscsi`
  becomes the default StorageClass; add VolumeSnapshotClass.
- **Phase 3 — NFS:** deploy democratic-csi NFS release; `truenas-nfs` (RWX);
  mount the export on Docker hosts.
- **Phase 4 — Validation:** see success criteria.

## Testing / Success Criteria

1. Both StorageClasses exist; `truenas-iscsi` is marked default.
2. **iSCSI RWO:** a test PVC binds; a pod writes data; after deleting the pod and
   rescheduling onto a **different node**, the data is intact.
3. **NFS RWX:** a `ReadWriteMany` PVC is mounted by **two pods simultaneously**;
   both read/write.
4. **Docker host:** a Docker host mounts the NFS export and reads/writes.
5. **Backend verification:** the corresponding zvol/dataset actually appears under
   `<pool>/k8s/iscsi` / `<pool>/k8s/nfs` on TrueNAS.
6. **Snapshot:** a VolumeSnapshot of an iSCSI PVC is created and restorable.
7. **No secret leakage:** `git grep` finds no plaintext API key; only the
   `SealedSecret` is committed.

## Risks / Open Implementation Details

- **Exact democratic-csi Talos node values** (host paths, `hostPID`) must be
  pinned from the current democratic-csi Talos reference during implementation.
- **Talos upgrade is disruptive** (rolling node reboots) — schedule accordingly.
- **iSCSI is RWO only** — databases and single-writer apps use `truenas-iscsi`;
  anything needing shared access must explicitly request `truenas-nfs`.
- **Chart version pinning** — pin `targetRevision` for democratic-csi and
  sealed-secrets rather than tracking `*`, given these are storage/secret
  critical.
```
