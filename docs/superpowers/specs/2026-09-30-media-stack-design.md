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

Alert rules and probes live in the `media` namespace next to the app they
cover (Prometheus selects rules and probes from all namespaces); the blackbox
modules they use are added to the existing blackbox-exporter values. Each
`application.yaml` must be `kubectl apply`'d once (no app-of-apps). Argo CD
pulls app-template from an OCI registry, which needs a repository Secret with
`enableOCI: "true"` (added under `infrastructure/cicd/argocd/`).

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
  - `SERVER_COUNTRIES=Greece,Italy,Bulgaria,Cyprus,Romania,Albania,Serbia,Croatia,Slovenia,Hungary,Austria,Czech Republic,Germany,Switzerland,Netherlands` — names exactly as in gluetun's server list; ~60 port-forwarding WireGuard servers.
  - `FIREWALL_INPUT_PORTS=8080,8888,8000,9999` — gluetun's firewall also
    filters inbound on eth0, so the control server (blackbox) and health
    server (kubelet) must be listed too.
  - `HEALTH_SERVER_ADDRESS=:9999` backs gluetun liveness/readiness probes
    (the default `127.0.0.1:9999` is unreachable for the kubelet).
  - The `{{PORT}}` / `{{VPN_INTERFACE}}` placeholders in the up/down commands
    are Helm-escaped: app-template runs every value through `tpl`.
- Pod DNS is `dnsPolicy: None` with nameserver `127.0.0.1` (gluetun's DNS
  over TLS, inside the tunnel). gluetun's firewall blocks cluster DNS anyway,
  and this makes DNS leaks impossible.
  - Control server `:8000` with an auth config allowing unauthenticated
    `GET /v1/portforward` only.
- qBittorrent: `ghcr.io/home-operations/qbittorrent` pinned by tag+digest,
  UID/GID 568, read-only root filesystem, `/tmp` emptyDir, `/config` (1Gi
  iSCSI), `/data` (shared NFS PVC). Incomplete dir `/data/torrents/incomplete`.
  Torrent traffic bound to `tun0` (`Session\Interface`) as a third layer.
  qBittorrent has no minimum-free-space setting; the ZFS quota is the stop.
- Web UI auth: qBittorrent login (localhost bypass only). The image's default
  config whitelists all of RFC1918 from auth — i.e. no login at all behind
  Traefik — so the first-start config is seeded from a ConfigMap mounted over
  `/defaults/qBittorrent.conf` with the whitelist off.
- Known, accepted risk: gluetun's HTTP proxy runs in the same pod, so a proxy
  client could reach qBittorrent's API on localhost without auth. Only
  Prowlarr can reach the proxy (Cilium), and Prowlarr is LAN-only behind a
  login.

### CiliumNetworkPolicy (defense in depth under gluetun's kill switch)

- Egress to `world`: **UDP 51820 only**. Plus nothing else outside the
  cluster — no DNS, no TCP. gluetun connects to Proton by IP from its bundled
  server list; the server-list updater is disabled.
- Ingress: 8080 from Traefik and Sonarr/Radarr; 8888 from Prowlarr only;
  8000 from blackbox-exporter only; 9999 from the node (kubelet probes).

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
- PV `media-data`: NFS `server: 192.168.20.2`, `path: /mnt/IOPSicle/media`,
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

qBittorrent, Sonarr and Radarr mount the whole PVC at `/data` (identical
paths everywhere, no remote path mappings, hardlinks work). Prowlarr mounts
only `backups/prowlarr` at `/data/backups/prowlarr`. Jellyfin mounts
`/data/media` read-only via `subPath`, and `backups/jellyfin` over
`/config/backups`.

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
  - Prowlarr's proxy keeps "bypass proxy for local addresses" on, so its
    calls to Sonarr/Radarr stay in-cluster.
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
- Backups: Jellyfin 12's backup folder is fixed at `<data dir>/backups`
  (`/config/backups`) and it has no backup schedule. The NFS
  `backups/jellyfin` directory is mounted over `/config/backups`; backups are
  taken by hand from the Dashboard after significant changes.
- HTTPRoute `jellyfin.koutoulastha.dev` (LAN).
- Pangolin resource (manual, runbook): `jellyfin.koutoulastha.dev`, site
  `main-tunnel`, HTTP → Jellyfin Service :8096, **Pangolin auth disabled**
  (native TV/phone clients cannot pass SSO). Compensating controls: strong
  passwords, remote access disabled for admin users, Jellyfin "Known
  Proxies" set to the pod CIDR (it accepts subnets) and "LAN networks" to
  the home LAN only, so real client IPs are seen and remote vs. local is
  decided correctly.
- Expect ~1–2 concurrent remote streams (CPU transcoding, home upload and
  VPS bandwidth).

## 5. Operations

### Alerts / probes

| Name | Signal | For |
|---|---|---|
| `QbittorrentVpnDown` | gluetun container not Ready | 10m |
| `QbittorrentPortForwardLost` | blackbox probe of gluetun `/v1/portforward` fails / port 0; suppressed while the VPN is down | 15m |
| `MediaDatasetFilling` | `truenas_dataset_used_bytes / truenas_dataset_quota_bytes` for `IOPSicle/media` > 85% (warning), > 95% (critical) | 15m |
| Jellyfin external | blackbox probe of Pangolin's edge IP with Host `jellyfin.koutoulastha.dev`, expecting 200 `Healthy` from `/health` — end to end through the Newt tunnel, which no existing probe covers | existing `BlackboxProbeFailed` |

The generic `BlackboxProbeFailed` (critical, 5m) excludes the port-forward
probe, which has its own warning-level alert above.

### Backups

- App configs: Prowlarr/Sonarr/Radarr built-in scheduled backups to
  `/data/backups/<app>`; Jellyfin manual backups land in
  `/data/backups/jellyfin`. All on NFS, off the zvol being backed up.
  qBittorrent state is not backed up.
- **The media library is not backed up** — deliberate; it is re-downloadable.

### Error handling

- Tunnel failure → gluetun firewall blocks all non-tunnel traffic; Cilium
  policy blocks it again at the cluster level; pod goes not-ready; alert.
- Proxy failure → Prowlarr searches fail (no direct egress to fall back to).
- Pool pressure → alert at 85%; the ZFS quota is the hard stop (qBittorrent
  writes fail and torrents error out; the pool is untouched).

## Rollout (each phase verified before the next)

1. **Foundation** — TrueNAS dataset/share/quota; `media-storage`. Verify: a
   test pod as 568 can write under `/data` and create a hardlink.
2. **qBittorrent + gluetun + policy** — **gate: all four leak tests pass**;
   then a Linux ISO torrent confirms speed and incoming connections.
3. **Prowlarr, Sonarr, Radarr** + runbook wiring. Verify end to end: one
   grabbed item imported with link count 2 (`stat`).
4. **Jellyfin** — LAN, then Pangolin resource and external probe.
5. **Alerts** — firing tests (e.g. delete `tun0` → `QbittorrentVpnDown`).

## Pinned versions (verified 2026-09-30)

- app-template **5.2.1** (`oci://ghcr.io/bjw-s-labs/helm/app-template`)
- gluetun **v3.41.3**, qBittorrent **5.2.4**, Prowlarr **2.6.5.5623**,
  Sonarr **4.0.20.3012**, Radarr **6.4.4.10685**, Jellyfin **12.1** — all
  pinned by digest in the values files.

## Values supplied by the operator during rollout

- Talos node IPs for the NFS share allow-list.
- Proton WireGuard private key (sealed with `kubeseal`).
