# Media stack (qBittorrent over Proton VPN, *arr, Jellyfin) — design

Date: 2026-09-30

## Goal

An automated media pipeline: Prowlarr finds releases, Sonarr/Radarr request
them, qBittorrent downloads them **exclusively over Proton VPN**, and Jellyfin
serves the resulting library — on LAN, and externally via Pangolin.

Success criteria:

- No torrent or indexer traffic ever leaves from the home IP, including when
  the tunnel fails (verified by leak tests, not assumed).
- Imports are hardlinks, not copies (link count 2 on library files).
- The media library cannot be deleted by an ArgoCD sync mistake, and cannot
  fill the TrueNAS pool that also backs every iSCSI volume.
- Only Jellyfin is reachable from outside the LAN.

Out of scope: hardware transcoding (GPU passthrough + Talos extension — a
later, separate change), declarative *arr configuration, backing up the media
library itself.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Packaging | bjw-s `app-template` Helm chart for all five apps | Uniform values schema, first-class sidecar support; same chart+`$values` pattern as `apps/immich` |
| Namespace | single `media`, PSS `enforce=privileged` | gluetun needs `NET_ADMIN` + `/dev/net/tun`; cluster default is `baseline` |
| Applications | `media-storage` (prune: false) + one per app | Library storage can never be pruned by an app change; apps sync/roll back independently |
| Shared data | static NFS PV on TrueNAS dataset `IOPSicle/media` | RWX across pods, hardlinks on one filesystem, independent of cluster lifecycle, browsable from TrueNAS |
| App config | per-app `truenas-iscsi` PVCs | SQLite is unsafe on NFS |
| VPN | gluetun native sidecar, Proton WireGuard, NAT-PMP port forwarding | Kill switch + forwarded port for connectability; user has a paid Proton plan |
| Indexer traffic | Prowlarr via gluetun HTTP proxy | ISP blocks / home IP in indexer logs; searches are pointless while VPN is down anyway |
| Media server | Jellyfin, direct play, CPU transcoding only | No account/cloud dependency; no GPU work now |
| Exposure | Jellyfin via Pangolin; everything else LAN-only HTTPRoutes | *arr/qBittorrent UIs are high-value, weakly authenticated targets |
| UID/GID | 568:568 (TrueNAS `apps`) for every app and dataset owner | Consistent ownership end to end; hardlinks and permissions just work |

## Repository layout

```
apps/media/
├── storage/            # media-storage Application: PV, PVC (namespace via managedNamespaceMetadata)
├── qbittorrent/        # application.yaml, values.yaml, sealed-secret.yaml, networkpolicy.yaml
├── prowlarr/           # application.yaml, values.yaml, sealed-secret.yaml, networkpolicy.yaml
├── sonarr/             # application.yaml, values.yaml, sealed-secret.yaml
├── radarr/             # application.yaml, values.yaml, sealed-secret.yaml
├── jellyfin/           # application.yaml, values.yaml
└── README.md           # runbook: manual TrueNAS/Pangolin steps, UI wiring, leak tests
```

Alert rules and probes live with the monitoring stack, following the existing
PVE/TrueNAS alert-rule placement. Each `application.yaml` must be
`kubectl apply`'d once (no app-of-apps).

## 1. qBittorrent + gluetun pod

- Deployment, `replicas: 1`, strategy `Recreate`.
- **gluetun** is a native sidecar (init container, `restartPolicy: Always`),
  so the tunnel and its firewall exist before qBittorrent starts. Both share
  the pod network namespace; qBittorrent's only route out is the tunnel.
- gluetun env:
  - `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`,
    `WIREGUARD_PRIVATE_KEY` from SealedSecret `gluetun-proton`.
  - `VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=on` (P2P servers only).
  - `VPN_PORT_FORWARDING_UP_COMMAND` sets qBittorrent's listen port via
    `http://127.0.0.1:8080/api/v2/app/setPreferences` on every (re)assignment.
    qBittorrent has "bypass authentication for clients on localhost" enabled.
  - `HTTPPROXY=on` (port 8888) for Prowlarr.
  - `FIREWALL_INPUT_PORTS=8080,8888`.
  - `HEALTH_SERVER_ADDRESS=:9999` backs gluetun liveness/readiness probes.
  - Control server `:8000` with an auth config allowing unauthenticated
    `GET /v1/portforward` only.
- qBittorrent: `ghcr.io/home-operations/qbittorrent` pinned by tag+digest,
  UID/GID 568, read-only root filesystem, `/tmp` emptyDir, `/config` (1Gi
  iSCSI), `/data` (shared NFS PVC). Incomplete dir `/data/torrents/incomplete`.
  Free-space guard set so downloads pause before the dataset quota is hit.
- Web UI auth: qBittorrent login (localhost bypass only).

### CiliumNetworkPolicy (defense in depth under gluetun's kill switch)

- Egress to `world`: **UDP 51820 only**. Plus nothing else outside the
  cluster — no DNS, no TCP. gluetun connects to Proton by IP from its bundled
  server list; the server-list updater is disabled.
- Ingress: 8080 from the `media` namespace and the gateway (Traefik);
  8888 from Prowlarr pods only; 8000 from blackbox-exporter only.

### Leak tests — gate before any real use

1. `curl ifconfig.me` from the qBittorrent container returns a Proton IP.
2. An ipleak-style torrent-IP-check magnet reports only the Proton IP.
3. `ip link del tun0` inside gluetun → qBittorrent container has no
   connectivity until gluetun reconnects.
4. Forwarded port shows in qBittorrent preferences and matches
   gluetun's `/v1/portforward`.

## 2. Storage

### TrueNAS (manual, runbook)

- Dataset `IOPSicle/media`, owner `apps:apps` (568:568), `recordsize=1M`,
  **quota 2 TiB** (pool is 3.32 TiB shared with `k8s/iscsi` zvols — a full
  pool would break every iSCSI volume in the cluster).
- NFS share, NFSv4, restricted to the Talos node IPs, no maproot/mapall.
- No snapshot task on this dataset.

### Kubernetes (`media-storage` Application, `prune: false`)

- Owns the `media` namespace via `managedNamespaceMetadata` with
  `pod-security.kubernetes.io/enforce: privileged`.
- PV `media-data`: NFS `server: <TrueNAS IP>`, `path: /mnt/IOPSicle/media`,
  `mountOptions: [nfsvers=4.1, hard]`, `persistentVolumeReclaimPolicy: Retain`,
  `storageClassName: ""`, `claimRef` → `media/media-data`.
- PVC `media-data`: `ReadWriteMany`, `volumeName: media-data`,
  `argocd.argoproj.io/sync-options: Prune=false`.

### Directory layout

```
/data
├── backups/{prowlarr,sonarr,radarr,jellyfin}/
├── torrents/{incomplete,movies,tv}/
└── media/{movies,tv}/
```

Every app mounts the whole PVC at `/data` (identical paths everywhere, no
remote path mappings, hardlinks work) — except Jellyfin, which mounts
`/data/media` read-only via `subPath`.

### Per-app config PVCs

`truenas-iscsi`, RWO, each annotated `Prune=false`: qBittorrent 1Gi,
Prowlarr/Sonarr/Radarr 5Gi each, Jellyfin 20Gi. Expandable later.

## 3. Prowlarr, Sonarr, Radarr

- app-template, `replicas: 1`, `Recreate`, UID/GID 568, read-only root fs,
  `/tmp` emptyDir, images `ghcr.io/home-operations/{prowlarr,sonarr,radarr}`
  pinned by tag+digest.
- API keys and auth pre-seeded via env from per-app SealedSecrets:
  `<APP>__AUTH__APIKEY`, `<APP>__AUTH__METHOD=Forms`,
  `<APP>__AUTH__REQUIRED=Enabled`.
- Wiring (runbook, done once in the UIs — not declarative):
  - Prowlarr Apps → `http://sonarr.media.svc:8989`, `http://radarr.media.svc:7878`.
  - Prowlarr proxy → HTTP `qbittorrent.media.svc:8888`, applied to all indexers.
  - Sonarr/Radarr download client → `http://qbittorrent.media.svc:8080`,
    categories `tv` / `movies` saving to `/data/torrents/{tv,movies}`.
  - Root folders `/data/media/tv`, `/data/media/movies`; hardlinks on.
  - Scheduled backups → `/data/backups/<app>`.
- Prowlarr CiliumNetworkPolicy: egress only to in-cluster (qBittorrent 8888,
  Sonarr, Radarr, kube-dns) — no direct `world` egress, so a proxy bypass
  fails closed.
- Sonarr/Radarr keep normal direct egress: their outbound traffic is
  metadata lookups (TVDB/TMDB) and calls to in-cluster services, which do not
  need the VPN.
- HTTPRoutes on `traefik-gateway` (ns `default`): `prowlarr`, `sonarr`,
  `radarr`, `qbittorrent` `.koutoulastha.dev`. LAN-only.

## 4. Jellyfin

- app-template, `replicas: 1`, `Recreate`, UID 568, image
  `ghcr.io/jellyfin/jellyfin` pinned.
- `/config` 20Gi iSCSI; `/cache` emptyDir; transcode dir emptyDir with
  `sizeLimit`; `/data/media` read-only.
- Libraries: Movies `/data/media/movies`, Shows `/data/media/tv`.
  Scheduled backups → `/data/backups/jellyfin` (requires a writable mount of
  that one subPath).
- HTTPRoute `jellyfin.koutoulastha.dev` (LAN).
- Pangolin resource (manual, runbook): `jellyfin.koutoulastha.dev`, site
  `main-tunnel`, HTTP → Jellyfin Service :8096, **Pangolin auth disabled**
  (native TV/phone clients cannot pass SSO). Compensating controls: strong
  passwords, remote access disabled for admin users, Jellyfin "Known
  Proxies" set so real client IPs are logged and rate-limited.
- Expect ~1–2 concurrent remote streams (CPU transcoding, home upload and
  VPS bandwidth).

## 5. Operations

### Alerts / probes

| Name | Signal | For |
|---|---|---|
| `QbittorrentVpnDown` | qBittorrent pod not Ready (gluetun health) | 10m |
| `QbittorrentPortForwardLost` | blackbox probe of gluetun `/v1/portforward` fails / port 0 | 15m |
| `MediaDatasetFilling` | truenas-exporter dataset usage > 85% of quota (warning), > 95% (critical) | 15m |
| Jellyfin external | blackbox HTTPS probe of `jellyfin.koutoulastha.dev` | existing probe alert |

### Backups

- App configs: built-in scheduled backups to `/data/backups/<app>` (NFS,
  off the zvol being backed up). qBittorrent state is not backed up.
- **The media library is not backed up** — deliberate; it is re-downloadable.

### Error handling

- Tunnel failure → gluetun firewall blocks all non-tunnel traffic; Cilium
  policy blocks it again at the cluster level; pod goes not-ready; alert.
- Proxy failure → Prowlarr searches fail (no direct egress to fall back to).
- Pool pressure → qBittorrent free-space guard pauses first; ZFS quota is the
  hard stop; alert at 85%.

## Rollout (each phase verified before the next)

1. **Foundation** — TrueNAS dataset/share/quota; `media-storage`. Verify: a
   test pod as 568 can write under `/data` and create a hardlink.
2. **qBittorrent + gluetun + policy** — **gate: all four leak tests pass**;
   then a Linux ISO torrent confirms speed and incoming connections.
3. **Prowlarr, Sonarr, Radarr** + runbook wiring. Verify end to end: one
   grabbed item imported with link count 2 (`stat`).
4. **Jellyfin** — LAN, then Pangolin resource and external probe.
5. **Alerts** — firing tests (e.g. delete `tun0` → `QbittorrentVpnDown`).

## Values confirmed during implementation

- TrueNAS NFS server IP and Talos node IPs for the share allow-list.
- Proton WireGuard private key (sealed by the operator with `kubeseal`).
- Current app-template chart version and image digests (checked against the
  chart's schema, not assumed).
