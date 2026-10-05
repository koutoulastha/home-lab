# Media stack

qBittorrent downloads over Proton VPN; Prowlarr, Sonarr and Radarr drive it;
Jellyfin serves the library. Design: `docs/superpowers/specs/2026-09-30-media-stack-design.md`.

| App | Application | LAN URL | In-cluster |
|---|---|---|---|
| (storage) | `media-storage` | — | PVC `media/media-data` |
| qBittorrent + gluetun | `qbittorrent` | https://qbittorrent.koutoulastha.dev | `qbittorrent.media.svc` :8080 web, :8888 proxy, :8000 gluetun control |
| Prowlarr | `prowlarr` | https://prowlarr.koutoulastha.dev | `prowlarr.media.svc:9696` |
| FlareSolverr | `flaresolverr` | — (Prowlarr only) | `flaresolverr.media.svc:8191` |
| Sonarr | `sonarr` | https://sonarr.koutoulastha.dev | `sonarr.media.svc:8989` |
| Radarr | `radarr` | https://radarr.koutoulastha.dev | `radarr.media.svc:7878` |
| Jellyfin | `jellyfin` | https://jellyfin.koutoulastha.dev (also public via Pangolin) | `jellyfin.media.svc:8096` |

## Registering (no app-of-apps)

Each `application.yaml` is applied once by hand, **`media-storage` first** —
it owns the `media` namespace and its `privileged` Pod Security label; the
apps do not create the namespace.

```bash
kubectl apply -f apps/media/storage/application.yaml
kubectl apply -f apps/media/qbittorrent/application.yaml   # then run the leak tests below
kubectl apply -f apps/media/prowlarr/application.yaml
kubectl apply -f apps/media/flaresolverr/application.yaml
kubectl apply -f apps/media/sonarr/application.yaml
kubectl apply -f apps/media/radarr/application.yaml
kubectl apply -f apps/media/jellyfin/application.yaml
```

## Things that live outside git

- **TrueNAS:** dataset `IOPSicle/media` (owner `apps:apps` 568:568, mode 775,
  recordsize 1M, **quota 2 TiB**), NFS share of `/mnt/IOPSicle/media` to the
  Talos node IPs, no maproot/mapall. The quota protects the pool, which every
  iSCSI volume in the cluster shares.
- **Proton:** a WireGuard configuration (platform Router, **NAT-PMP on**);
  only its `PrivateKey` is used, sealed in `qbittorrent/sealed-secret.yaml`.
- **Pangolin Cloud:** HTTP resource `jellyfin.koutoulastha.dev`, site
  `main-tunnel`, target `http://jellyfin.media.svc.cluster.local:8096`,
  **Pangolin SSO on** (decided 2026-10-01). Remote access is browser-only;
  the Jellyfin TV/phone apps cannot pass SSO and work on the LAN only.
- **App UIs:** logins, download clients, root folders, Prowlarr proxy and app
  sync, backups folders, Jellyfin networking. Stored in each app's SQLite on
  its `/config` volume.

## How torrent traffic is kept off the home IP

1. gluetun's firewall (iptables in the shared pod network namespace) allows
   nothing out except the WireGuard tunnel.
2. qBittorrent binds to `tun0` (`Session\Interface` in the seeded config).
3. `qbittorrent/networkpolicy.yaml`: Cilium lets the pod reach the internet on
   UDP 51820 only. Prowlarr and FlareSolverr have no internet egress at all;
   both use gluetun's HTTP proxy.

DNS for the pod goes to gluetun's resolver on 127.0.0.1 (DNS over TLS inside
the tunnel).

## Leak tests (re-run after any change to the qbittorrent pod)

```bash
kubectl -n media exec deploy/qbittorrent -c app -- wget -qO- https://ipinfo.io/json      # Proton org, not home IP
kubectl -n media exec deploy/qbittorrent -c app -- cat /etc/resolv.conf                 # nameserver 127.0.0.1 only
kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- http://127.0.0.1:8000/v1/portforward   # {"port":N>0}
kubectl -n media exec deploy/qbittorrent -c gluetun -- ip link del tun0 && \
  kubectl -n media exec deploy/qbittorrent -c app -- sh -c 'wget -T 5 -qO- https://ipinfo.io/ip || echo BLOCKED'
kubectl -n media run cnp-test --rm -i --restart=Never --image=busybox:1.37 \
  --labels=app.kubernetes.io/name=qbittorrent -- sh -c 'wget -T 5 -qO- http://1.1.1.1 >/dev/null 2>&1 && echo LEAK || echo DROPPED'
```

Plus ipleak.net's torrent address detection magnet: only the Proton IP may appear.

## Operations

- **Rotate/replace the Proton key:** generate a new WireGuard config (NAT-PMP
  on), re-seal `qbittorrent/sealed-secret.yaml` with the command in the
  implementation plan (Task 3 Step 7), merge, then
  `kubectl -n media rollout restart deploy/qbittorrent`.
- **Port forwarding lost** (`QbittorrentPortForwardLost`): restart the pod —
  gluetun picks a new P2P server.
- **Dataset filling** (`MediaDatasetFilling`): delete watched media, or raise
  the quota on TrueNAS *and* the PV/PVC `storage` (a label only; NFS does not
  enforce it) — check the pool has room first.
- **Backups:** Prowlarr/Sonarr/Radarr write scheduled backups to
  `/data/backups/<app>`; Jellyfin backups are manual (*Dashboard → Backups*)
  and land in `/data/backups/jellyfin` (mounted over `/config/data/backups`). The
  media library itself is deliberately not backed up.
- **Prowlarr → Sonarr/Radarr** (*Settings → Apps*) must use `http://sonarr:8989`
  and `http://radarr:7878`. Prowlarr's global proxy bypasses only dotless
  hostnames, so `sonarr.media.svc` would be sent into gluetun's proxy and fail.
- **Cloudflare-protected indexers** (e.g. 1337x): in Prowlarr, *Settings →
  Indexers → + → FlareSolverr*, host `http://flaresolverr:8191/` (dotless, so
  it bypasses the proxy), tag `flaresolverr`; give that tag to the indexer.
  Prowlarr passes its proxy on to FlareSolverr, so the solve exits via Proton.
  Expect some challenges to stay unsolved — Cloudflare often wins.
  Check: `kubectl -n media logs deploy/flaresolverr` shows the solve, and
  `kubectl -n media exec deploy/flaresolverr -- python -c "import urllib.request as u;print(u.urlopen('http://1.1.1.1',timeout=5))"`
  must fail (no direct egress).
- **Render test** before any values change:
  `devbox run -- bash apps/media/tests/render-test.sh`.

## First-start gotchas (found during the 2026-10-01 rollout)

- **\*arr logins:** the values force forms auth via env, so the apps skip
  their "create user" screen and start locked. Set the user through the API
  with the pre-seeded key:
  ```bash
  set_login() {  # app, api-version (sonarr/radarr v3, prowlarr v1)
    local app=$1 v=$2 key user pass
    key=$(kubectl -n media exec deploy/$app -- printenv "${app^^}__AUTH__APIKEY")
    read -rp "$app username: " user; read -rsp "$app password: " pass; echo
    curl -sk -H "X-Api-Key: $key" "https://$app.koutoulastha.dev/api/$v/config/host" \
      | jq --arg u "$user" --arg p "$pass" '.username=$u | .password=$p | .passwordConfirmation=$p' \
      | curl -sk -o /dev/null -w "$app %{http_code}\n" -X PUT -H "X-Api-Key: $key" \
          -H 'Content-Type: application/json' -d @- "https://$app.koutoulastha.dev/api/$v/config/host"
  }
  ```
- **\*arr backup folder** is under *Settings → General → Backups*, visible
  only with **Show Advanced** on (or set `backupFolder` through the same
  `config/host` API).
- **Jellyfin transcode path** must be a subdirectory such as
  `/cache/transcodes` (the default). Setting it to `/cache` itself makes
  Jellyfin 12 refuse to start (`found marker for /cache/.jellyfin-cache`); fix
  by editing `TranscodingTempPath` in `/config/config/encoding.xml`.
- **Jellyfin networking:** Known proxies `10.244.0.0/16` (pod network — Traefik
  and Newt connect from it); LAN networks = home subnets only
  (`192.168.20.0/24`, `192.168.88.0/24`), never the pod network.
- **Pangolin resource for Jellyfin:** SSO stays **on**. The `jellyfin-public`
  probe expects the edge's 302 to `app.pangolin.net/auth/...`; it failing with
  a 200 means SSO was switched off and Jellyfin is exposed without it. To
  support native apps remotely instead, turn SSO off *and* change the
  `http_jellyfin_pangolin` module back to expecting `200` + `Healthy`.
- **Containers ship BusyBox `wget`:** no `-e`, and it cannot tunnel `https://`
  through a proxy — test the proxy with `http_proxy=… wget http://…`.
- **Editing a registered `application.yaml`** (including
  `infrastructure/cicd/argocd/application.yaml`) needs a re-`kubectl apply`;
  Argo CD reads the Application spec from the live object, not git.

## Known, accepted risk

gluetun's HTTP proxy and qBittorrent share a pod, and qBittorrent skips auth
for localhost (gluetun needs that to set the forwarded port). A client of the
proxy could therefore reach qBittorrent's API unauthenticated. Only Prowlarr
can reach the proxy (Cilium), and Prowlarr is LAN-only behind a login.

FlareSolverr can reach the proxy too (decided 2026-10-05), and it runs
JavaScript from indexer sites in Chrome (with certificate errors ignored, as
upstream configures it). A malicious page could send requests through the
proxy to `127.0.0.1:8080` and drive qBittorrent's API. gluetun's proxy does
not filter private destinations. Accepted as low likelihood; the fix, if
needed, is a qBittorrent API key (5.2+) for gluetun's port-update command and
`WebUI\LocalHostAuth=true`.
