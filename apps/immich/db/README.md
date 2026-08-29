# Immich database

CloudNativePG `Cluster` backing Immich. Separate from `apps/immich` on purpose:
this Application syncs with `prune: false`, so an error in the app's manifests
can never delete the database.

## What is backed up, and what is not

`ScheduledBackup` takes a CSI volume snapshot of the Postgres data and WAL
volumes at 02:30 daily; `immich-db-backup-prune` deletes all but the newest 7 at
03:30. That covers **metadata only** — albums, faces, sharing, admin settings.

**The photos themselves are not covered by anything in this directory.** They
live on the `immich-library` PVC and need a **TrueNAS-side ZFS snapshot task on
the iSCSI parent dataset**, created in the TrueNAS UI. The dataset path is not
in git; read `datasetParentName` from the decrypted driver config:

```bash
kubectl -n democratic-csi get secret truenas-iscsi-driver-config \
  -o jsonpath='{.data.driver-config-file\.yaml}' | base64 -d | grep datasetParentName
```

or read it off the TrueNAS UI. Without that task there is no photo backup.

## Retention depends on a chain that defaults the wrong way

Deleting a `Backup` only reclaims space if every link holds:

1. `Cluster.spec.backup.volumeSnapshot.snapshotOwnerReference: backup` — set
   here. The default is `none`, which orphans VolumeSnapshots.
2. The `VolumeSnapshotClass` `deletionPolicy` must be `Delete`, or the ZFS
   snapshot survives:

```bash
kubectl get volumesnapshotclass truenas-iscsi -o jsonpath='{.deletionPolicy}'
```

   If it reads `Retain` instead, set `deletionPolicy: Delete` under
   `volumeSnapshotClasses[0]` in
   `infrastructure/storage/democratic-csi/iscsi/values.yaml` — a different
   Application, so it's a separate change and sync.

## Restore

Restoring replaces the cluster. There is **no PITR** — recovery lands on the
chosen snapshot, so up to 24h of metadata can be lost.

1. **Stop ArgoCD from fighting the restore, first.** `apps/immich/db` syncs
   with `selfHeal: true`, and git still holds the `bootstrap.initdb` version
   of `cluster.yaml`. A hand-applied recovery `Cluster` gets reverted within
   minutes unless you do one of these first:

   ```bash
   argocd app set immich-db --sync-policy none
   ```

   or commit the recovery stanza (step 4) to `main` before applying it.

2. **List the snapshots to choose from:**

   ```bash
   kubectl -n immich get volumesnapshot
   ```

   Each backup produces two snapshots sharing a timestamp — one for PGDATA
   (`storage`), one for WAL (`walStorage`). You need both names below.

3. **Scale Immich down** so nothing writes during recovery:

   ```bash
   kubectl -n immich scale deploy/immich-server --replicas=0
   ```

4. **Delete the existing `Cluster` and recreate it with a recovery bootstrap**
   referencing both snapshots:

   ```bash
   kubectl -n immich delete cluster immich-db
   ```

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: immich-db
     namespace: immich
   spec:
     instances: 1
     imageName: ghcr.io/tensorchord/cloudnative-vectorchord:17.9-1.1.0
     postgresql:
       shared_preload_libraries:
         - vchord.so
     bootstrap:
       recovery:
         volumeSnapshots:
           storage:
             name: <PGDATA-SNAPSHOT-NAME>
             kind: VolumeSnapshot
             apiGroup: snapshot.storage.k8s.io
           walStorage:
             name: <WAL-SNAPSHOT-NAME>
             kind: VolumeSnapshot
             apiGroup: snapshot.storage.k8s.io
     storage:
       size: 20Gi
       storageClass: truenas-iscsi
     walStorage:
       size: 8Gi
       storageClass: truenas-iscsi
   ```

   `bootstrap.recovery` replaces `bootstrap.initdb` entirely — the
   `postInitSQL`/`postInitApplicationSQL` blocks from the normal `cluster.yaml`
   do not run on recovery, and don't need to: the superuser grant and the
   extensions are already inside the restored volume.

5. **Scale Immich back up:**

   ```bash
   kubectl -n immich scale deploy/immich-server --replicas=1
   ```

6. **Restore normal operation.** Put `cluster.yaml` back to its `main` version
   (revert the commit from step 1, or discard the hand-applied change if you
   used `sync-policy none`), then re-enable auto-sync:

   ```bash
   argocd app set immich-db --sync-policy automated
   ```
