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

- Datasets: `<ZFS_POOL>/k8s/{iscsi,nfs}/{v,s}`.
- iSCSI service on; one Portal (group `1`), one Initiator group (group `1`),
  note the target Base Name.
- NFS service on (shares are created dynamically by the driver).
- An API key owned by a `FULL_ADMIN` user. The **API-only drivers**
  (`freenas-api-iscsi` / `freenas-api-nfs`) do everything over the HTTP API, so
  **no SSH key or root SSH is required** — SSH can stay disabled on TrueNAS.

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
