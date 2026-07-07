# Storage validation tests

Apply-ready manifests for the plan's validation steps (Tasks 6, 7, 9). Run them
**after** both democratic-csi releases are `Synced/Healthy` and the
StorageClasses exist. All objects live in `default`; cleanup is at the bottom.

Prereq check:

```bash
kubectl get storageclass          # expect: truenas-iscsi (default), truenas-nfs
```

## 1. iSCSI RWO — bind, write, reschedule, read back

```bash
kubectl apply -f iscsi-rwo-writer.yaml
kubectl get pvc iscsi-test                       # -> Bound within ~30s
kubectl wait --for=condition=Ready pod/iscsi-writer --timeout=90s

kubectl delete pod iscsi-writer --wait           # detach the zvol
kubectl apply -f iscsi-rwo-reader.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/iscsi-reader --timeout=90s
kubectl logs iscsi-reader                         # -> prints "homelab"
```

`homelab` printing on a fresh pod proves the block volume survived deletion and
reattached (likely on another node). Confirm the zvol in TrueNAS under
`IOPSicle/k8s/iscsi/v`.

## 2. NFS RWX — two pods share one volume

```bash
kubectl apply -f nfs-rwx-test.yaml
kubectl wait --for=condition=Ready pod/nfs-a pod/nfs-b --timeout=90s
kubectl exec nfs-a -- cat /data/shared           # -> contains from-a AND from-b
kubectl get pods -o wide -l app=nfs-rwx-test      # ideally on two different nodes
```

## 3. Snapshot round-trip (iSCSI)

```bash
kubectl apply -f snapshot-test.yaml
kubectl get volumesnapshot snap-1 -w             # -> READYTOUSE=true, then Ctrl-C
```

## Cleanup

```bash
kubectl delete -f snapshot-test.yaml --ignore-not-found
kubectl delete -f nfs-rwx-test.yaml --ignore-not-found
kubectl delete pod iscsi-reader iscsi-writer --ignore-not-found
kubectl delete pvc iscsi-test --ignore-not-found      # reclaimPolicy: Delete -> zvol removed
```

After cleanup, verify in the TrueNAS UI that the test datasets/zvols under
`IOPSicle/k8s/{iscsi,nfs}/{v,s}` are gone (proves `reclaimPolicy: Delete` works).
