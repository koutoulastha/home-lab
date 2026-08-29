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

## Restore

List available backups:

```bash
kubectl -n immich get backups.postgresql.cnpg.io \
  --sort-by=.metadata.creationTimestamp
```

Restoring replaces the cluster: scale Immich down, delete the `Cluster`, and
recreate it with a `bootstrap.recovery.volumeSnapshots` stanza pointing at the
chosen snapshot, then scale Immich back up. There is **no PITR** — recovery
lands on the snapshot, so up to 24h of metadata can be lost.
