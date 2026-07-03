# Persistent Storage (democratic-csi + TrueNAS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the multi-node Talos Kubernetes cluster dynamic persistent volumes backed by TrueNAS SCALE — iSCSI block as the default StorageClass and NFS as a secondary RWX class — managed via ArgoCD with credentials kept out of git.

**Architecture:** One CSI driver (democratic-csi) is deployed as two independent ArgoCD-managed Helm releases, one per TrueNAS protocol. iSCSI PVCs become ZFS zvols exported as LUNs (RWO, default); NFS PVCs become ZFS datasets exported over NFS (RWX, also mountable by Docker hosts). Credentials live in a SealedSecret decrypted in-cluster by the sealed-secrets controller. Talos nodes gain iSCSI support via system extensions rolled out with `talosctl`.

**Tech Stack:** Talos Linux, Kubernetes, ArgoCD, Helm, democratic-csi, TrueNAS SCALE (ZFS), Bitnami sealed-secrets + kubeseal, kubernetes-csi external-snapshotter.

## Global Constraints

- **GitOps pattern (copy exactly from existing apps):** every ArgoCD `Application` uses `spec.sources` with (1) the external Helm chart repo (`chart:` + `targetRevision:` + `helm.valueFiles: [$values/<path>]`) and (2) a values source `repoURL: https://github.com/koutoulastha/home-lab.git`, `targetRevision: version3`, `ref: values`. `syncPolicy.automated: { prune: true, selfHeal: true }`, `syncOptions: [CreateNamespace=true]`.
- **Branch:** all repo files are committed to branch `version3` (the branch ArgoCD tracks).
- **Pin chart versions:** set an explicit `targetRevision` (chart version) for democratic-csi, sealed-secrets, and snapshot-controller — do NOT use `"*"` for these storage/secret-critical components. The versions written in the tasks below (`democratic-csi 0.14.7`, `sealed-secrets 2.16.2`, `snapshot-controller 3.0.6`) are starting points — confirm/replace each with a current release before syncing: `helm repo add <name> <url> && helm search repo <name>/<chart> --versions | head`. If you bump a chart, re-check its `values.yaml` keys still match this plan (esp. the piraeus snapshot-controller `installCRDs`/`controller` keys).
- **No plaintext secrets in git:** the TrueNAS API key and SSH private key appear ONLY inside a `SealedSecret`. A final task greps the repo to prove it.
- **Division of labor:** the implementer creates and commits repo files. All cluster-side commands (`talosctl`, `kubectl`, `argocd`, `kubeseal`, TrueNAS UI) are presented as copy-paste blocks for the operator to run — the implementer does not execute them.
- **Operator-supplied inputs** (substitute everywhere you see the token). Fill these in once, up front:

  | Token | Meaning | Example |
  |---|---|---|
  | `<TRUENAS_HOST>` | TrueNAS IP/hostname (API, SSH, NFS/iSCSI portal) | `192.168.1.20` |
  | `<TRUENAS_API_KEY>` | TrueNAS API key | `1-abc...` |
  | `<TRUENAS_SSH_PRIVATE_KEY>` | PEM private key for the TrueNAS SSH user | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
  | `<ZFS_POOL>` | Root ZFS pool name on TrueNAS | `tank` |
  | `<CLUSTER_SUBNET>` | CIDR of K8s nodes + Docker hosts allowed to mount NFS | `192.168.1.0/24` |
  | `<TALOS_VERSION>` | Talos version currently running | `v1.7.6` |
  | `<SCHEMATIC_ID>` | Image Factory schematic id (produced in Task 1) | `abc123...` |
  | `<NODE_IP>` | A Talos node IP (for `talosctl -n`) | `192.168.1.31` |

- **ZFS dataset layout (fixed by this plan):**
  - iSCSI volumes: `<ZFS_POOL>/k8s/iscsi/v` ; iSCSI detached snapshots: `<ZFS_POOL>/k8s/iscsi/s`
  - NFS volumes: `<ZFS_POOL>/k8s/nfs/v` ; NFS detached snapshots: `<ZFS_POOL>/k8s/nfs/s`
- **Namespaces:** sealed-secrets → `kube-system`; snapshot-controller → `kube-system`; democratic-csi (both releases) → `democratic-csi`.
- **Unique CSI driver names:** iSCSI release `org.democratic-csi.iscsi`; NFS release `org.democratic-csi.nfs`.

---

### Task 1: Talos iSCSI node extensions (operator-run, GATING)

Stock Talos has no iSCSI stack. Every node needs the `iscsi-tools` and `util-linux-tools` system extensions before any iSCSI PVC can bind. No repo files change in this task; it is a prerequisite rollout the operator performs.

**Files:** none (out-of-band).

**Interfaces:**
- Consumes: nothing.
- Produces: Talos nodes with a running `iscsi-tools` extension service, so the democratic-csi node DaemonSet (Task 6) can log into iSCSI targets.

- [ ] **Step 1: Generate an Image Factory schematic with the extensions**

Open <https://factory.talos.dev/>, choose your Talos version and architecture, and select the extensions **`siderolabs/iscsi-tools`** and **`siderolabs/util-linux-tools`**. Copy the resulting schematic ID into `<SCHEMATIC_ID>`.

Equivalent API call (optional):
```bash
curl -sX POST --data-binary @- https://factory.talos.dev/schematics <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
```
Expected: JSON `{"id":"<SCHEMATIC_ID>"}`.

- [ ] **Step 2: Roll the new image onto each node (one at a time)**

```bash
talosctl -n <NODE_IP> upgrade \
  --image factory.talos.dev/installer/<SCHEMATIC_ID>:<TALOS_VERSION> \
  --preserve
```
Expected: node reboots, rejoins; repeat per node. Wait for `kubectl get nodes` to show the node `Ready` before doing the next one.

- [ ] **Step 3: Verify the extension is present on every node**

```bash
talosctl -n <NODE_IP> get extensions
```
Expected: rows listing `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools`.

```bash
talosctl -n <NODE_IP> services | grep -i iscsi
```
Expected: an `ext-iscsid` (iscsi-tools) service in state `Running`.

- [ ] **Step 4: Confirm all nodes Ready**

```bash
kubectl get nodes -o wide
```
Expected: every node `Ready`. Do not proceed until all nodes show the extension.

---

### Task 2: TrueNAS SCALE backend preparation (operator-run)

Prepare datasets, iSCSI/NFS services, and the credentials democratic-csi will use. No repo files; performed in the TrueNAS UI/shell.

**Files:** none (out-of-band).

**Interfaces:**
- Consumes: nothing.
- Produces: `<TRUENAS_API_KEY>`, `<TRUENAS_SSH_PRIVATE_KEY>`, parent datasets, an iSCSI portal (group 1) + initiator group (group 1) + target basename, and an enabled NFS service — all consumed by Tasks 4–7.

- [ ] **Step 1: Create parent datasets**

In TrueNAS: **Datasets** → create `k8s`, then children `k8s/iscsi`, `k8s/iscsi/v`, `k8s/iscsi/s`, `k8s/nfs`, `k8s/nfs/v`, `k8s/nfs/s` under `<ZFS_POOL>`.

Verify over SSH:
```bash
ssh root@<TRUENAS_HOST> "zfs list -r <ZFS_POOL>/k8s"
```
Expected: all six datasets listed.

- [ ] **Step 2: Enable + configure iSCSI**

**System Settings → Services → iSCSI** (enable, start on boot). Under **Shares → Block (iSCSI)**:
- **Portals:** create one portal listening on `0.0.0.0:3260` → note its **Portal Group ID** (should be `1`).
- **Initiators Groups:** create one allowing your cluster subnet `<CLUSTER_SUBNET>` (or "Allow All Initiators") → **Group ID** `1`.
- **Target Global Configuration:** note the **Base Name** (e.g. `iqn.2005-10.org.freenas.ctl`).

- [ ] **Step 3: Enable NFS**

**System Settings → Services → NFS** → enable + start on boot. (Per-share exports are created dynamically by democratic-csi; no manual share needed.)

- [ ] **Step 4: Create an API key**

**Credentials → API Keys → Add** → copy the value into `<TRUENAS_API_KEY>`.

- [ ] **Step 5: Provide SSH access for the driver**

Ensure the `root` user (or a dedicated user) has SSH enabled and an authorized public key. Keep the matching private key for `<TRUENAS_SSH_PRIVATE_KEY>`.

```bash
ssh root@<TRUENAS_HOST> "zfs --version && iscsictl -L >/dev/null 2>&1; echo ssh-ok"
```
Expected: prints the zfs version and `ssh-ok`.

---

### Task 3: sealed-secrets controller (ArgoCD)

Deploy the sealed-secrets controller so credentials can be committed as encrypted `SealedSecret`s. Must exist before Task 4.

**Files:**
- Create: `infrastructure/sealed-secrets/application.yaml`
- Create: `infrastructure/sealed-secrets/values.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: a running controller named `sealed-secrets-controller` in `kube-system` that decrypts `SealedSecret` → `Secret`.

- [ ] **Step 1: Create the values file**

`infrastructure/sealed-secrets/values.yaml`:
```yaml
fullnameOverride: sealed-secrets-controller
namespace: kube-system
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 128Mi
```

- [ ] **Step 2: Create the ArgoCD Application**

`infrastructure/sealed-secrets/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sealed-secrets
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  sources:
    - repoURL: https://bitnami-labs.github.io/sealed-secrets
      chart: sealed-secrets
      targetRevision: 2.16.2
      helm:
        valueFiles:
          - $values/infrastructure/sealed-secrets/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      ref: values
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Commit**

```bash
git add infrastructure/sealed-secrets/
git commit -m "feat(storage): add sealed-secrets controller (ArgoCD)"
```

- [ ] **Step 4: Register the app + verify (operator)**

```bash
kubectl apply -f infrastructure/sealed-secrets/application.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```
Expected: `deployment "sealed-secrets-controller" successfully rolled out`.

- [ ] **Step 5: Install the kubeseal CLI (operator)**

```bash
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/tags | jq -r '.[0].name' | cut -c2-)
curl -sOL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
kubeseal --version
```
Expected: prints a `kubeseal version: ...` line.

---

### Task 4: Seal the TrueNAS driver credentials

Produce two `SealedSecret`s (one per protocol) holding the full democratic-csi driver config under key `driver-config-file.yaml`. These are the ONLY place credentials live in git.

**Files:**
- Create: `infrastructure/storage/democratic-csi/iscsi/sealed-secret.yaml` (committed)
- Create: `infrastructure/storage/democratic-csi/nfs/sealed-secret.yaml` (committed)
- (Operator scratch, NOT committed): `/tmp/iscsi-config.yaml`, `/tmp/nfs-config.yaml`

**Interfaces:**
- Consumes: `<TRUENAS_HOST>`, `<TRUENAS_API_KEY>`, `<TRUENAS_SSH_PRIVATE_KEY>`, `<ZFS_POOL>`, `<CLUSTER_SUBNET>` (Task 2); the controller from Task 3.
- Produces: in-cluster `Secret`s `truenas-iscsi-driver-config` and `truenas-nfs-driver-config` (namespace `democratic-csi`), each with key `driver-config-file.yaml`, referenced by Tasks 6–7 via `driver.existingConfigSecret`.

- [ ] **Step 1: Write the iSCSI driver config (operator, scratch file)**

`/tmp/iscsi-config.yaml` — the value that becomes the secret. Fill tokens:
```yaml
driver: freenas-iscsi
httpConnection:
  protocol: https
  host: <TRUENAS_HOST>
  port: 443
  apiKey: <TRUENAS_API_KEY>
  allowInsecure: true
  apiVersion: 2
sshConnection:
  host: <TRUENAS_HOST>
  port: 22
  username: root
  privateKey: |
    <TRUENAS_SSH_PRIVATE_KEY>
zfs:
  datasetParentName: <ZFS_POOL>/k8s/iscsi/v
  detachedSnapshotsDatasetParentName: <ZFS_POOL>/k8s/iscsi/s
  zvolCompression: lz4
  zvolDedup: ""
  zvolEnableReservation: false
  zvolBlocksize: ""
iscsi:
  targetPortal: "<TRUENAS_HOST>:3260"
  targetPortals: []
  interface: ""
  namePrefix: csi-
  nameSuffix: ""
  targetGroups:
    - targetGroupPortalGroup: 1
      targetGroupInitiatorGroup: 1
      targetGroupAuthType: None
      targetGroupAuthGroup: ""
  extentInsecureTpc: true
  extentXenCompat: false
  extentDisablePhysicalBlocksize: true
  extentBlocksize: 512
  extentRpm: "SSD"
  extentAvailThreshold: 0
```

- [ ] **Step 2: Write the NFS driver config (operator, scratch file)**

`/tmp/nfs-config.yaml`:
```yaml
driver: freenas-nfs
httpConnection:
  protocol: https
  host: <TRUENAS_HOST>
  port: 443
  apiKey: <TRUENAS_API_KEY>
  allowInsecure: true
  apiVersion: 2
sshConnection:
  host: <TRUENAS_HOST>
  port: 22
  username: root
  privateKey: |
    <TRUENAS_SSH_PRIVATE_KEY>
zfs:
  datasetParentName: <ZFS_POOL>/k8s/nfs/v
  detachedSnapshotsDatasetParentName: <ZFS_POOL>/k8s/nfs/s
  datasetEnableQuotas: true
  datasetEnableReservation: false
  datasetPermissionsMode: "0777"
  datasetPermissionsUser: 0
  datasetPermissionsGroup: 0
nfs:
  shareHost: <TRUENAS_HOST>
  shareAlldirs: false
  shareAllowedHosts: []
  shareAllowedNetworks:
    - <CLUSTER_SUBNET>
  shareMaprootUser: root
  shareMaprootGroup: wheel
  shareMapallUser: ""
  shareMapallGroup: ""
```

- [ ] **Step 3: Seal both configs (operator)**

```bash
kubectl create secret generic truenas-iscsi-driver-config \
  --namespace democratic-csi \
  --from-file=driver-config-file.yaml=/tmp/iscsi-config.yaml \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system \
  --format yaml > infrastructure/storage/democratic-csi/iscsi/sealed-secret.yaml

kubectl create secret generic truenas-nfs-driver-config \
  --namespace democratic-csi \
  --from-file=driver-config-file.yaml=/tmp/nfs-config.yaml \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system \
  --format yaml > infrastructure/storage/democratic-csi/nfs/sealed-secret.yaml
```
Note: `kubeseal` needs the `democratic-csi` namespace to exist OR use scope. If the namespace does not exist yet, create it first: `kubectl create namespace democratic-csi`.

- [ ] **Step 4: Verify no plaintext leaked into the sealed files**

```bash
grep -E "BEGIN OPENSSH|BEGIN RSA|<TRUENAS_API_KEY>|apiKey" \
  infrastructure/storage/democratic-csi/iscsi/sealed-secret.yaml \
  infrastructure/storage/democratic-csi/nfs/sealed-secret.yaml
```
Expected: **no matches** (grep exits non-zero). The files contain only `encryptedData`.

- [ ] **Step 5: Remove scratch files + commit sealed secrets**

```bash
shred -u /tmp/iscsi-config.yaml /tmp/nfs-config.yaml 2>/dev/null || rm -f /tmp/iscsi-config.yaml /tmp/nfs-config.yaml
git add infrastructure/storage/democratic-csi/iscsi/sealed-secret.yaml \
        infrastructure/storage/democratic-csi/nfs/sealed-secret.yaml
git commit -m "feat(storage): add sealed TrueNAS driver credentials"
```

---

### Task 5: external-snapshotter (VolumeSnapshot CRDs + controller)

The iSCSI release declares a `VolumeSnapshotClass`; that CRD and the snapshot controller are cluster-wide prerequisites not shipped by democratic-csi. Install them before Task 6.

**Files:**
- Create: `infrastructure/storage/snapshot-controller/application.yaml`
- Create: `infrastructure/storage/snapshot-controller/values.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: `snapshot.storage.k8s.io` CRDs (`VolumeSnapshot`, `VolumeSnapshotClass`, `VolumeSnapshotContent`) + a running `snapshot-controller` in `kube-system`, enabling the VolumeSnapshotClass in Task 6.

- [ ] **Step 1: Create the values file**

`infrastructure/storage/snapshot-controller/values.yaml`:
```yaml
# piraeus snapshot-controller chart bundles CRDs + controller
installCRDs: true
controller:
  replicaCount: 1
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      memory: 64Mi
```

- [ ] **Step 2: Create the ArgoCD Application**

`infrastructure/storage/snapshot-controller/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: snapshot-controller
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  sources:
    - repoURL: https://piraeus.io/helm-charts/
      chart: snapshot-controller
      targetRevision: 3.0.6
      helm:
        valueFiles:
          - $values/infrastructure/storage/snapshot-controller/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      ref: values
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 3: Commit**

```bash
git add infrastructure/storage/snapshot-controller/
git commit -m "feat(storage): add external snapshot-controller + CRDs"
```

- [ ] **Step 4: Register + verify (operator)**

```bash
kubectl apply -f infrastructure/storage/snapshot-controller/application.yaml
kubectl get crd | grep snapshot.storage.k8s.io
kubectl -n kube-system get pods -l app.kubernetes.io/name=snapshot-controller
```
Expected: three `*.snapshot.storage.k8s.io` CRDs; controller pod `Running`.

---

### Task 6: democratic-csi iSCSI release (default StorageClass)

Deploy the iSCSI driver, its default StorageClass `truenas-iscsi`, and a VolumeSnapshotClass. Includes Talos node overrides so the node DaemonSet can drive the host iSCSI stack.

**Files:**
- Create: `infrastructure/storage/democratic-csi/iscsi/application.yaml`
- Create: `infrastructure/storage/democratic-csi/iscsi/values.yaml`
- (Task 4 already created `.../iscsi/sealed-secret.yaml`.)

**Interfaces:**
- Consumes: `truenas-iscsi-driver-config` secret (Task 4); Talos extensions (Task 1); snapshot CRDs (Task 5).
- Produces: StorageClass `truenas-iscsi` (default), VolumeSnapshotClass `truenas-iscsi`, CSI driver `org.democratic-csi.iscsi`.

- [ ] **Step 1: Create the values file**

`infrastructure/storage/democratic-csi/iscsi/values.yaml`:
```yaml
csiDriver:
  name: "org.democratic-csi.iscsi"

storageClasses:
  - name: truenas-iscsi
    defaultClass: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: ext4
    mountOptions: []
    secrets:
      provisioner-secret:
      controller-publish-secret:
      node-stage-secret:
      node-publish-secret:
      controller-expand-secret:

volumeSnapshotClasses:
  - name: truenas-iscsi
    parameters:
    secrets:
      snapshotter-secret:

driver:
  existingConfigSecret: truenas-iscsi-driver-config
  config:
    driver: freenas-iscsi

# Talos: node DaemonSet must reach the host iscsi-tools extension.
node:
  hostPID: true
  driver:
    iscsiDirHostPath: /system/iscsi-tools/var/lib/iscsi
    iscsiDirHostPathType: ""
```

- [ ] **Step 2: VERIFY the Talos iSCSI host path (operator) before syncing**

The `iscsiDirHostPath` above is the commonly-correct location exposed by the `iscsi-tools` extension. Confirm it on a node:
```bash
talosctl -n <NODE_IP> list /system/iscsi-tools/var/lib/iscsi
```
Expected: the directory exists (lists `nodes`, `send_targets`, etc.). If the path differs on your Talos version, update `iscsiDirHostPath` in `values.yaml` to the real path before committing.

- [ ] **Step 3: Create the ArgoCD Application**

`infrastructure/storage/democratic-csi/iscsi/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: democratic-csi-iscsi
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: democratic-csi
  sources:
    - repoURL: https://democratic-csi.github.io/charts/
      chart: democratic-csi
      targetRevision: 0.14.7
      helm:
        valueFiles:
          - $values/infrastructure/storage/democratic-csi/iscsi/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      ref: values
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      path: infrastructure/storage/democratic-csi/iscsi
      directory:
        include: 'sealed-secret.yaml'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Commit**

```bash
git add infrastructure/storage/democratic-csi/iscsi/application.yaml \
        infrastructure/storage/democratic-csi/iscsi/values.yaml
git commit -m "feat(storage): add democratic-csi iSCSI release (default StorageClass)"
```

- [ ] **Step 5: Register + verify driver up (operator)**

```bash
kubectl apply -f infrastructure/storage/democratic-csi/iscsi/application.yaml
kubectl -n democratic-csi get pods
kubectl get storageclass
```
Expected: controller + node pods `Running`; `truenas-iscsi (default)` in the StorageClass list.

- [ ] **Step 6: Functional test — bind, write, reschedule (operator)**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: iscsi-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc iscsi-test
```
Expected: PVC `Bound` within ~30s, and a zvol appears: `ssh root@<TRUENAS_HOST> "zfs list -r <ZFS_POOL>/k8s/iscsi/v"`.

```bash
kubectl run iscsi-w --image=busybox --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","command":["sh","-c","echo homelab > /data/marker && sleep 3600"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"iscsi-test"}}]}}'
kubectl wait --for=condition=Ready pod/iscsi-w --timeout=60s
kubectl delete pod iscsi-w --wait
# reschedule onto (likely) another node and read it back
kubectl run iscsi-r --image=busybox --restart=Never --overrides='{"spec":{"containers":[{"name":"c","image":"busybox","command":["cat","/data/marker"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"iscsi-test"}}]}}'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/iscsi-r --timeout=60s
kubectl logs iscsi-r
```
Expected: logs print `homelab` (data survived pod deletion + reschedule).

- [ ] **Step 7: Clean up test objects (operator)**

```bash
kubectl delete pod iscsi-r --ignore-not-found
kubectl delete pvc iscsi-test
```
Expected: PVC deleted; confirm the zvol is gone (`reclaimPolicy: Delete`).

---

### Task 7: democratic-csi NFS release (RWX StorageClass)

Deploy the NFS driver and the secondary RWX StorageClass `truenas-nfs`. No Talos node extension needed (Talos mounts NFS natively).

**Files:**
- Create: `infrastructure/storage/democratic-csi/nfs/application.yaml`
- Create: `infrastructure/storage/democratic-csi/nfs/values.yaml`
- (Task 4 already created `.../nfs/sealed-secret.yaml`.)

**Interfaces:**
- Consumes: `truenas-nfs-driver-config` secret (Task 4); NFS service (Task 2).
- Produces: StorageClass `truenas-nfs` (RWX), CSI driver `org.democratic-csi.nfs`.

- [ ] **Step 1: Create the values file**

`infrastructure/storage/democratic-csi/nfs/values.yaml`:
```yaml
csiDriver:
  name: "org.democratic-csi.nfs"

storageClasses:
  - name: truenas-nfs
    defaultClass: false
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: nfs
    mountOptions:
      - noatime
      - nfsvers=4
    secrets:
      provisioner-secret:
      controller-publish-secret:
      node-stage-secret:
      node-publish-secret:
      controller-expand-secret:

driver:
  existingConfigSecret: truenas-nfs-driver-config
  config:
    driver: freenas-nfs
```

- [ ] **Step 2: Create the ArgoCD Application**

`infrastructure/storage/democratic-csi/nfs/application.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: democratic-csi-nfs
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: democratic-csi
  sources:
    - repoURL: https://democratic-csi.github.io/charts/
      chart: democratic-csi
      targetRevision: 0.14.7
      helm:
        valueFiles:
          - $values/infrastructure/storage/democratic-csi/nfs/values.yaml
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      ref: values
    - repoURL: https://github.com/koutoulastha/home-lab.git
      targetRevision: version3
      path: infrastructure/storage/democratic-csi/nfs
      directory:
        include: 'sealed-secret.yaml'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: Commit**

```bash
git add infrastructure/storage/democratic-csi/nfs/application.yaml \
        infrastructure/storage/democratic-csi/nfs/values.yaml
git commit -m "feat(storage): add democratic-csi NFS release (RWX StorageClass)"
```

- [ ] **Step 4: Register + verify (operator)**

```bash
kubectl apply -f infrastructure/storage/democratic-csi/nfs/application.yaml
kubectl -n democratic-csi get pods -l app.kubernetes.io/instance=democratic-csi-nfs
kubectl get storageclass truenas-nfs
```
Expected: NFS controller/node pods `Running`; `truenas-nfs` present (not default).

- [ ] **Step 5: RWX test — two pods share one volume (operator)**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-test, namespace: default }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: truenas-nfs
  resources: { requests: { storage: 1Gi } }
EOF
for n in a b; do
kubectl run nfs-$n --image=busybox --restart=Never --overrides="{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"echo from-$n >> /data/shared && sleep 3600\"],\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"nfs-test\"}}]}}"
done
kubectl wait --for=condition=Ready pod/nfs-a pod/nfs-b --timeout=60s
kubectl exec nfs-a -- cat /data/shared
```
Expected: both pods `Ready` on the same RWX volume; the file contains `from-a` and `from-b`.

- [ ] **Step 6: Clean up (operator)**

```bash
kubectl delete pod nfs-a nfs-b --ignore-not-found
kubectl delete pvc nfs-test
```

---

### Task 8: Docker-host NFS mount + component README

Document and enable Docker-host consumption of the NFS backend, and write the runbook README that ties the out-of-band steps together.

**Files:**
- Create: `infrastructure/storage/democratic-csi/README.md`

**Interfaces:**
- Consumes: the NFS service from Task 2.
- Produces: operator documentation; a mounted NFS share on Docker hosts.

- [ ] **Step 1: Write the README**

`infrastructure/storage/democratic-csi/README.md` — cover: the Task 1 Talos extension rollout, Task 2 TrueNAS prep, the kubeseal re-seal procedure (Task 4) for rotating credentials, the two StorageClasses (`truenas-iscsi` default / `truenas-nfs` RWX) and when to use each, and the Docker-host mount below. Include this Docker section verbatim:

````markdown
## Mounting the NFS backend on a Docker host

Create a dedicated dataset for the host (or reuse `<ZFS_POOL>/k8s/nfs`) and mount it:

```bash
sudo apt-get install -y nfs-common
echo '<TRUENAS_HOST>:/mnt/<ZFS_POOL>/k8s/nfs  /mnt/truenas  nfs  vers=4,noatime,_netdev  0  0' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/truenas && sudo mount -a
```

Use it as a Docker bind mount (`-v /mnt/truenas/myapp:/data`) or an NFS-backed named volume.
````

- [ ] **Step 2: Commit**

```bash
git add infrastructure/storage/democratic-csi/README.md
git commit -m "docs(storage): democratic-csi runbook + Docker-host NFS mount"
```

- [ ] **Step 3: Verify a Docker host can read/write (operator)**

Run the mount block from the README on one Docker host, then:
```bash
touch /mnt/truenas/.write-test && ls -l /mnt/truenas/.write-test && rm /mnt/truenas/.write-test
```
Expected: file is created and removed without permission errors.

---

### Task 9: Final validation & guardrails

Confirm the whole system against the spec's success criteria and prove no secrets leaked.

**Files:** none.

**Interfaces:**
- Consumes: everything above.
- Produces: sign-off.

- [ ] **Step 1: StorageClasses (operator)**

```bash
kubectl get storageclass
```
Expected: `truenas-iscsi (default)` and `truenas-nfs` both present.

- [ ] **Step 2: Snapshot round-trip (operator)**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: snap-src, namespace: default }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } } }
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: snap-1, namespace: default }
spec:
  volumeSnapshotClassName: truenas-iscsi
  source: { persistentVolumeClaimName: snap-src }
EOF
kubectl get volumesnapshot snap-1 -w
```
Expected: `READYTOUSE=true`. Then clean up: `kubectl delete volumesnapshot snap-1; kubectl delete pvc snap-src`.

- [ ] **Step 3: Prove no plaintext credentials in the repo**

```bash
git grep -nE "BEGIN OPENSSH PRIVATE KEY|BEGIN RSA PRIVATE KEY" -- . || echo "clean: no private keys"
git grep -nE "apiKey:\s*\S+" -- infrastructure/ || echo "clean: no plaintext apiKey"
```
Expected: both print their `clean:` message (only `encryptedData` lives in the sealed-secret files).

- [ ] **Step 4: ArgoCD health (operator)**

```bash
kubectl -n argocd get applications sealed-secrets snapshot-controller democratic-csi-iscsi democratic-csi-nfs
```
Expected: all `Synced` / `Healthy`.

---

## Notes on execution order

Tasks are strictly ordered by dependency: **1 (Talos) and 2 (TrueNAS) gate everything**; 3 → 4 (secrets) precede 6/7; 5 (snapshot CRDs) precedes 6. Do not reorder 6 before 1/4/5.
