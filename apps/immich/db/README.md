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
   # The root Application (infrastructure/cicd/argocd/root.yaml) self-heals
   # every Application spec, so it would switch immich-db's auto-sync back
   # on. Pause the root first, then immich-db.
   kubectl -n argocd patch application root      --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
   kubectl -n argocd patch application immich-db --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
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
   paused sync), then re-enable auto-sync. Re-applying the root restores the
   root's own policy, and the root then restores `immich-db`'s policy from git:

   ```bash
   kubectl apply -f infrastructure/cicd/argocd/root.yaml
   kubectl -n argocd get application immich-db -o jsonpath='{.spec.syncPolicy.automated}{"\n"}'   # {"prune":false,"selfHeal":true}
   ```

## Before an Immich upgrade: backup gate

An Immich version bump runs database migrations that a revert does **not**
undo. Before merging one, take **both** backups below and confirm both. The
snapshot lives on TrueNAS and goes through the same iSCSI path as the
database. The logical dump goes to a machine that isn't TrueNAS, so there is
a way back even if the storage side fails. Replace `<YYYYMMDD>` with today's date.

**1. On-demand snapshot backup.** Apply it from stdin, **not** as a file in this
directory: ArgoCD syncs `apps/immich/db`, and a committed `Backup` would be
re-applied or pruned.

```bash
kubectl -n immich apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: immich-db-pre-upgrade-<YYYYMMDD>
spec:
  cluster:
    name: immich-db
  method: volumeSnapshot
EOF
kubectl -n immich get backup immich-db-pre-upgrade-<YYYYMMDD> -w      # PHASE: completed, then Ctrl-C
kubectl -n immich get volumesnapshot -o custom-columns=NAME:.metadata.name,READY:.status.readyToUse | grep pre-upgrade-<YYYYMMDD>
#   expect TWO rows (PGDATA + WAL), both READY=true
```

The prune CronJob keeps the newest 7 `Backup`s of any kind, so this one ages
out after about a week of nightlies, and its snapshots go with it
(`snapshotOwnerReference: backup`). Once the upgrade is confirmed good,
that's what you want. Keep the dump if you want a longer way back.

**2. Off-array logical dump**, to your PC:

```bash
PRIMARY=$(kubectl -n immich get cluster immich-db -o jsonpath='{.status.currentPrimary}')
kubectl -n immich exec "$PRIMARY" -c postgres -- pg_dump -Fc -d immich > ~/immich-db-<YYYYMMDD>.dump
ls -lh ~/immich-db-<YYYYMMDD>.dump                               # non-zero, plausible size (tens-hundreds of MB)
kubectl -n immich exec -i "$PRIMARY" -c postgres -- pg_restore --list < ~/immich-db-<YYYYMMDD>.dump | grep -c 'TABLE DATA'
#   expect a number > 0 and no error. pg_restore can read the whole archive.
```

**Do not merge the bump until both checks pass.**

### Rolling back an Immich upgrade

Reverting the image tag alone is **not** a rollback. The new version has
already migrated the schema, and the old version may refuse to start against
it. Roll back the data and the tag together:

- **From the snapshot** (fastest): follow [Restore](#restore) above with the
  two `immich-db-pre-upgrade-<YYYYMMDD>` snapshot names, with the tag revert merged
  first so the old Immich starts against the old schema.
- **From the dump** (if the snapshots are unusable): recreate `immich-db`
  empty (the normal `cluster.yaml`; `initdb` creates the role and extensions),
  keep `immich-server` scaled to 0, then:

  ```bash
  PRIMARY=$(kubectl -n immich get cluster immich-db -o jsonpath='{.status.currentPrimary}')
  kubectl -n immich exec -i "$PRIMARY" -c postgres -- pg_restore --clean --if-exists --no-owner --role=immich -d immich < ~/immich-db-<YYYYMMDD>.dump
  ```

  Then scale `immich-server` back to 1.
