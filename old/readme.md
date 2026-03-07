# Legacy Homelab Stack (`old/`)

This folder keeps an **older Docker Compose setup** for reference and migration.

It is useful when:
- rebuilding services from the previous setup,
- checking old port/profile mappings,
- migrating data directories to a newer stack.

## Files

- `docker-compose.yml`: legacy multi-service homelab stack.
- `readme.md`: this migration-oriented documentation.

## Services (by profile)

The compose file is organized with Docker Compose profiles so you can run only what you need.

- `adguard`: AdGuard Home
- `smokeping`: SmokePing
- `pialert`: PI.Alert
- `homarr`: Homarr dashboard
- `jellyfin`: Jellyfin media server
- `navidrome`: Navidrome music server
- `torrent`: qBittorrent
- `sonarr`, `radarr`, `lidarr`, `whisparr`, `jackett`, `prowlarr`, `jellyseerr`, `flaresolverr`: *Arr stack components
- `rrs`: grouped profile shared by multiple media stack services
- `traefik`: reverse proxy
- `whoami`: test service behind Traefik
- `stirling-pdf`: Stirling PDF
- `pi-hole` exists but is currently commented out

## Quick start

From this directory:

```bash
cd old
```

Start a single profile:

```bash
docker compose --profile adguard up -d
```

Start the media stack group:

```bash
docker compose --profile rrs up -d
```

Start multiple profiles:

```bash
docker compose \
	--profile traefik \
	--profile whoami \
	--profile adguard \
	up -d
```

Stop everything started from this compose file:

```bash
docker compose down
```

## Migration notes

- Most data paths are bound to host directories under `/zfspool/...`.
- Ensure destination hosts have those paths (or adjust mounts) before bringing services up.
- Keep UID/GID consistent (`1000:1000` in most services) to avoid permissions issues.
- `pialert` uses `network_mode: host`; preserve that behavior if required by your network discovery setup.

## Security notes

This legacy file includes placeholder and/or sensitive-style values (e.g. Cloudflare and basic auth fields for Traefik).

Before using it outside a trusted local environment:
- move secrets to an env file or secret manager,
- rotate any real tokens/passwords that may have been used previously,
- avoid committing real credentials.

## Known legacy characteristics

- Compose `version: "3"` is legacy style but still commonly accepted.
- Some services expose many ports directly; review exposure before production use.
- Traefik configuration appears tuned for a personal homelab domain and DNS challenge flow.
