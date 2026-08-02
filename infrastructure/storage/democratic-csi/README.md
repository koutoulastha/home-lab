# Persistent Storage — democratic-csi + TrueNAS SCALE

Dynamic persistent volumes for the Talos Kubernetes cluster, backed by TrueNAS
SCALE (ZFS on NVMe). Two ArgoCD-managed democratic-csi releases:

| StorageClass | Protocol | Access | Use for |
|---|---|---|---|
| `truenas-iscsi` (**default**) | iSCSI block (ZFS zvol) | RWO | databases, single-writer app state, anything perf-sensitive |
| `truenas-nfs` | NFS (ZFS dataset) | RWX | shared volumes across pods, media/config, Docker-host mounts |

Omit `storageClassName` on a PVC to get `truenas-iscsi`. Request `truenas-nfs`
explicitly when you need `ReadWriteMany`.

Design + full plan:
- `docs/superpowers/specs/2026-07-03-persistent-storage-democratic-csi-design.md`
- `docs/superpowers/plans/2026-07-03-persistent-storage-democratic-csi.md`

## Layout

```
infrastructure/
  sealed-secrets/                      # SealedSecret controller (prereq for creds)
  storage/
    snapshot-controller/               # VolumeSnapshot CRDs + controller
    democratic-csi/
      iscsi/  {application,values,sealed-secret}.yaml   # default SC
      nfs/    {application,values,sealed-secret}.yaml   # RWX SC
      tests/                                           # apply-ready validation manifests
```

`sealed-secret.yaml` in each `iscsi/` and `nfs/` dir is produced by `kubeseal`
(see "Rotating credentials" below) and is the only place TrueNAS credentials
live in git — encrypted.

## One-time prerequisites (operator)

### 1. Talos iSCSI node extensions (gates iSCSI)

Build an Image Factory schematic (<https://factory.talos.dev/>) with
`siderolabs/iscsi-tools` + `siderolabs/util-linux-tools`, then roll it out:

```bash
talosctl -n <NODE_IP> upgrade \
  --image factory.talos.dev/installer/<SCHEMATIC_ID>:<TALOS_VERSION> --preserve
talosctl -n <NODE_IP> get extensions        # expect iscsi-tools + util-linux-tools
```

Repeat per node, one at a time, waiting for `Ready` between nodes. NFS needs no
extension (Talos mounts NFS natively).

### 2. TrueNAS SCALE

- Datasets: `<ZFS_POOL>/k8s/{iscsi,nfs}/{v,s}`. Create them as plain **Generic**
  filesystem datasets (compression `lz4`, atime off, encryption *inherit*,
  everything else default). They are just parents — the driver creates the
  per-PVC zvols and datasets inside them.
- iSCSI service on, **plus a Portal and an Initiator Group that actually exist**
  (Shares → Block (iSCSI) Targets). The driver config references Portal ID `1`
  and Initiator Group ID `1`; if those IDs don't exist, provisioning fails with
  HTTP `422 ... Portal not found in database / Initiator not found in database`
  even though authentication and zvol creation succeed. Verify the IDs match:

  ```bash
  midclt call iscsi.portal.query '[]'     | jq '.[].id'
  midclt call iscsi.initiator.query '[]'  | jq '.[].id'
  ```

  Do **not** create Targets or Extents by hand — democratic-csi does that per PVC.
- NFS service on (shares are created dynamically by the driver).
- An API key owned by a `FULL_ADMIN` user. The **API-only drivers**
  (`freenas-api-iscsi` / `freenas-api-nfs`) do everything over the HTTP API, so
  **no SSH key or root SSH is required** — SSH can stay disabled on TrueNAS.

### 3. Privileged namespace (gates the CSI node plugin)

The cluster enforces PodSecurity `baseline` on unlabeled namespaces, which
rejects the democratic-csi **node** DaemonSet (it needs `privileged`, `hostPID`,
`hostNetwork` and many `hostPath` mounts). Both Applications therefore set:

```yaml
spec:
  syncPolicy:
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/enforce-version: latest
```

This is handled in git — but if the namespace ever loses the label, the failure
is silent and confusing (see Troubleshooting).

## Rotating / creating credentials (kubeseal)

The sealed secrets are generated from plaintext driver configs that are **never
committed**. To (re)create them:

```bash
# 1. Write /tmp/iscsi-config.yaml and /tmp/nfs-config.yaml
#    (freenas-api-iscsi / freenas-api-nfs driver configs — see the plan, Task 4)

# 2. Seal each into its release directory
for p in iscsi nfs; do
  kubectl create secret generic truenas-$p-driver-config \
    --namespace democratic-csi \
    --from-file=driver-config-file.yaml=/tmp/$p-config.yaml \
    --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller \
             --controller-namespace kube-system --format yaml \
    > infrastructure/storage/democratic-csi/$p/sealed-secret.yaml
done

# 3. Scrub plaintext, commit the sealed files
shred -u /tmp/iscsi-config.yaml /tmp/nfs-config.yaml 2>/dev/null || rm -f /tmp/*-config.yaml
git add infrastructure/storage/democratic-csi/*/sealed-secret.yaml
```

The controller decrypts each into a real `Secret` referenced by the releases via
`driver.existingConfigSecret`.

## Mounting the NFS backend on a Docker host

Create a dedicated dataset for the host (or reuse `<ZFS_POOL>/k8s/nfs`) and mount it:

```bash
sudo apt-get install -y nfs-common
echo '<TRUENAS_HOST>:/mnt/<ZFS_POOL>/k8s/nfs  /mnt/truenas  nfs  vers=4,noatime,_netdev  0  0' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/truenas && sudo mount -a
```

Use it as a Docker bind mount (`-v /mnt/truenas/myapp:/data`) or an NFS-backed
named volume.

## Apply order

`sealed-secrets` → seal creds → `snapshot-controller` → `democratic-csi-iscsi`
→ `democratic-csi-nfs`. Do not apply the CSI releases before the Talos
extensions (iSCSI) and the sealed secrets exist.

Each release must be registered with ArgoCD once — this repo has no app-of-apps,
so committing `application.yaml` deploys nothing:

```bash
kubectl apply -f infrastructure/storage/democratic-csi/iscsi/application.yaml
kubectl apply -f infrastructure/storage/democratic-csi/nfs/application.yaml
kubectl -n argocd get applications | grep democratic   # both should be listed
```

## Validation

Apply-ready manifests live in [`tests/`](tests/) — iSCSI RWO (write → detach →
reattach), NFS RWX (two pods, two nodes, one volume), and an iSCSI snapshot
round-trip. See `tests/README.md` for the run order and cleanup.

## Troubleshooting

Symptoms map to causes fairly cleanly — work from the PVC outward.

| Symptom | Cause |
|---|---|
| PVC `Pending`, `ProvisioningFailed ... 422 Portal/Initiator not found in database` | TrueNAS iSCSI Portal / Initiator Group missing or IDs don't match the config |
| PVC `Pending`, `storageclass "truenas-nfs" not found`, no NFS pods | The Application was never registered — `kubectl apply -f nfs/application.yaml` |
| PVC `Bound`, pod stuck `ContainerCreating`, `driver org.democratic-csi.iscsi not found in the list of registered CSI drivers` | Node plugin isn't running. Check `kubectl -n democratic-csi get ds` — if desired > 0 but current is 0, the namespace lost its `privileged` PodSecurity label |
| Node DaemonSet pods never created, `FailedCreate ... violates PodSecurity "baseline:latest"` | Same as above. Confirm with `kubectl get ns democratic-csi -o jsonpath='{.metadata.labels}'` |
| `FailedMount` with an `iscsiadm` / login error | Talos `iscsi-tools` extension missing on that node, or the node can't reach TrueNAS on `:3260` |

Recovering a namespace that lost its label:

```bash
kubectl label namespace democratic-csi \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest --overwrite
kubectl -n democratic-csi rollout restart ds/democratic-csi-iscsi-node
```

Note that `kubectl` prints a `restricted:latest` PodSecurity **warning** when
applying these workloads. That is advisory only — enforcement is `privileged`,
so the pods are admitted.
