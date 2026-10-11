# Music in the media stack (Lidarr, Navidrome) — design

Date: 2026-10-11
Extends: `docs/superpowers/specs/2026-09-30-media-stack-design.md`

## Goal

Music joins the existing pipeline: Prowlarr finds releases, **Lidarr**
requests them, qBittorrent downloads them over Proton VPN, and the library is
served by **Navidrome** (a Subsonic-API player, usable from phone apps
anywhere) and by **Jellyfin** (a Music library over the same files).

Success criteria:

- Music torrent and indexer traffic follows the existing VPN path; the
  qBittorrent leak tests still pass after the network-policy change.
- Lidarr imports are hardlinks (link count 2 on library files).
- Navidrome is reachable at `https://music.koutoulastha.dev` from the LAN and
  from the internet, with Subsonic phone apps working remotely.
- A compromised Navidrome cannot reach anything in the cluster or on the home
  LAN, and cannot modify the library.
- Nobody but the owner can become Navidrome's admin.

Out of scope: Soulseek/slskd (possible later, separate change — it would need
its own VPN treatment), importing an existing collection (there is none),
Spotify metadata agent, declarative Lidarr/Navidrome configuration.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Acquisition | Lidarr, torrents only, via existing Prowlarr + qBittorrent | No new network path or VPN work; Soulseek deferred |
| Player | Navidrome, plus a Jellyfin Music library | Navidrome for Subsonic phone apps; Jellyfin already mounts `/data/media` |
| Placement | Both in the `media` namespace, `apps/media/<app>/`, app-template 5.2.1 | Same pattern as the rest of the stack; isolation comes from a network policy rather than a separate namespace |
| Library path | `/data/media/music` on the existing `media-data` NFS PVC | One filesystem with `/data/torrents`, so imports are hardlinks; 2 TiB quota shared |
| Exposure | Navidrome public via Pangolin, **SSO off**; Lidarr LAN-only | Phone apps cannot pass Pangolin SSO; Navidrome's own login is the gate |
| Hostname | `music.koutoulastha.dev` for both LAN route and Pangolin resource | Same split-horizon pattern as Jellyfin |
| Navidrome egress | DNS + TCP 443 to public IPs only (RFC1918 excluded) | Artwork (Deezer) and bios (Last.fm) wanted; LAN and cluster stay unreachable |

## 1. Lidarr

`apps/media/lidarr/` — `application.yaml`, `values.yaml`, `sealed-secret.yaml`,
a copy of Sonarr's shape:

- Image `ghcr.io/home-operations/lidarr:3.1.6.5078`, pinned by digest.
- `LIDARR__AUTH__METHOD=Forms`, `LIDARR__AUTH__REQUIRED=Enabled`;
  `LIDARR__AUTH__APIKEY` from the sealed secret `lidarr-secret`.
- Probes on `/ping` port 8686 (liveness/readiness/startup as Sonarr).
- UID/GID 568, fsGroup 568, `readOnlyRootFilesystem`, no privilege escalation,
  all capabilities dropped; `Recreate` strategy.
- `/config`: 5 Gi `truenas-iscsi` PVC with `Prune=false,Delete=false`.
  `/data`: whole `media-data` PVC. `/tmp`: emptyDir.
- LAN HTTPRoute `lidarr.koutoulastha.dev` → `traefik-gateway`.
- UI configuration (runbook): qBittorrent download client with category
  `music` (saves to `/data/torrents/music`), root folder `/data/media/music`,
  backups folder `/data/backups/lidarr`.

Changes to existing files:

1. `qbittorrent/networkpolicy.yaml`: add `lidarr` to the ingress allow-list
   for 8080. Leak tests are re-run after this change.
2. `prowlarr/networkpolicy.yaml`: add egress to `lidarr` on 8686. Prowlarr's
   app entry uses `http://lidarr:8686` (dotless, so it bypasses the proxy).
3. `tests/render-test.sh`: `test_lidarr`.

## 2. Navidrome

`apps/media/navidrome/` — `application.yaml`, `values.yaml`,
`networkpolicy.yaml`, `probe.yaml`, plus `sealed-secret.yaml` only if a
Last.fm key turns out to be required (see Open checks).

- Image `ghcr.io/navidrome/navidrome:0.64.2`, pinned by digest; port 4533;
  `Recreate` strategy.
- UID/GID 568, fsGroup 568, `readOnlyRootFilesystem`, all capabilities
  dropped, `automountServiceAccountToken: false` (internet-facing).
- Probes on `/ping` (unauthenticated).
- Mounts: `/config` — 2 Gi `truenas-iscsi` PVC, `Prune=false,Delete=false`,
  holds the SQLite DB and caches; `/music` — `media-data` subPath
  `media/music`, **read-only**; `/tmp` — emptyDir (ffmpeg transcoding).
- Environment:
  - `ND_DATAFOLDER=/config`, `ND_MUSICFOLDER=/music`
  - `ND_SCANNER_SCHEDULE=1h` — inotify does not fire over NFS, so the
    scheduled scan is what picks up Lidarr's imports
  - `ND_AGENTS=deezer,lastfm` — artist images and biographies
  - `ND_ENABLEINSIGHTSCOLLECTOR=false`, `ND_ENABLESHARING=false`
  - `ND_REVERSEPROXYWHITELIST` **must stay unset**: it enables header-based
    login for any client in the whitelist.
- LAN HTTPRoute `music.koutoulastha.dev` → `traefik-gateway`.

### Network policy (`CiliumNetworkPolicy navidrome`)

Both directions are restricted (the stack's other policies are egress-only):

- Ingress on 4533 from Traefik (`traefik` namespace) and Newt (`pangolin`
  namespace) only.
- Egress: kube-dns on 53; TCP 443 to `0.0.0.0/0` except `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`. Cilium's `world` entity is not used — it
  includes LAN addresses (TrueNAS, router, Talos nodes).

## 3. Public exposure and monitoring

Pangolin Cloud resource (outside git, recorded in the README): HTTP resource
`music.koutoulastha.dev`, site `main-tunnel`, target
`http://navidrome.media.svc.cluster.local:4533`, **SSO off**.

**Admin first:** Navidrome makes the first visitor its admin. The admin is
created over the LAN before the Pangolin resource exists. The README states
this as a hard rule.

Probe `navidrome-public` (`apps/media/navidrome/probe.yaml`) with a new
blackbox module `http_navidrome_pangolin` in
`infrastructure/monitoring/blackbox-exporter/values.yaml`:
`GET https://130.110.2.46/ping`, `Host: music.koutoulastha.dev`, expect
**200**, `follow_redirects: false`. A 302 to `app.pangolin.net/auth` means SSO
was switched on (phone apps broken); a 502 means tunnel or pod down. Unlike
Jellyfin's probe, a 200 here proves the tunnel end to end. Existing
probe-failure alerting covers it; no new alert rules.

Jellyfin: no manifest change. Runbook step: add a Music library at
`/data/media/music`.

## 4. Testing and rollout

Pre-merge:

- `render-test.sh`: `test_lidarr` (common checks, `/data` mount, auth env);
  `test_navidrome` (common checks with hostname `music.koutoulastha.dev`,
  `/music` read-only with subPath `media/music`, no SA token,
  `ND_DATAFOLDER=/config`, `ND_AGENTS=deezer,lastfm`, no
  `ND_REVERSEPROXYWHITELIST`). `common_checks` takes the hostname as a
  parameter instead of deriving it from the app name.
- Network policies: `kubectl apply --dry-run=server`.

Open checks, settled from upstream source during planning, not assumed:

1. Whether Navidrome 0.64.2 ships a default Last.fm API key. If not: a free
   key in `sealed-secret.yaml` as `ND_LASTFM_APIKEY`/`ND_LASTFM_SECRET`.
2. How Navidrome's login rate limiter identifies clients behind a proxy (all
   requests arrive from Traefik or Newt). If it keys on the peer address, an
   attacker can lock out everyone — accepted as a nuisance, documented.

Rollout (user runs the commands):

1. Merge; apply `lidarr/application.yaml`; set login (`set_login lidarr v1`),
   download client, root folder, backups folder; add Lidarr in Prowlarr.
2. Re-run the qBittorrent leak tests. Lidarr's download-client test and
   Prowlarr's Lidarr test both pass.
3. Apply `navidrome/application.yaml`; open `https://music.koutoulastha.dev`
   on the LAN; create the admin.
4. Create the Pangolin resource (SSO off). `navidrome-public` probe is up;
   `curl https://music.koutoulastha.dev/ping` from off-LAN returns 200; a
   Subsonic app logs in off-LAN.
5. From the Navidrome pod: `https://api.deezer.com` succeeds;
   `qbittorrent:8080`, `qbittorrent:8888` and TrueNAS on 443 are dropped.
6. Jellyfin Music library added. One album end to end: Lidarr search →
   qBittorrent → import with link count 2 → visible in Navidrome after a scan
   and in Jellyfin.

README updates: table rows for Lidarr and Navidrome, apply commands, Pangolin
resource under "Things that live outside git", admin-first rule, `set_login`
note for Lidarr (API v1), Prowlarr → `http://lidarr:8686`, Jellyfin Music
library, Navidrome's exposure under "Known, accepted risk".
