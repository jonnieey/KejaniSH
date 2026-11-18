# KejaniSH

Home-lab deployment for `blackbeing` (Raspberry Pi 4, Arch Linux ARM): Home
Assistant in Docker, a WLED strip in the bedroom, and the backup/upgrade tooling
that keeps it running.

The house logic used to live in AppDaemon. It is now native Home Assistant
automations, configured in the private `KejaniSH-Resources` repo and deployed to
`/config`. See
[`docs/specs/2026-11-16-retire-appdaemon-native-automation.md`](docs/specs/2026-11-16-retire-appdaemon-native-automation.md)
for the design, the ten automations and the reasoning.

## Topology

```
Safaricom router 192.168.100.1
└── Tenda router 192.168.0.1 (DHCP)
    ├── blackbeing / Raspberry Pi 4   192.168.0.101   100.85.189.120 (Tailscale)
    │   ├── docker: homeassistant     :8123
    │   ├── /home/jonnieey/.HASS      HA config clone (private repo)
    │   └── /home/jonnieey/KejaniSH   this repo (deployment + scripts)
    └── ESP32 WLED                   192.168.0.102   (boots dark)
        └── TV `media_player.smart_tv_pro`
```

Only Home Assistant runs. AppDaemon, Rhasspy and Portainer are archived under
`~/.HASS/archive/` and their images were removed.

## Deploy

`~/KejaniSH` is a clone of this public repo. Secrets live in a local, untracked
`.env`:

```bash
cp .env.example .env      # then adjust paths/ports
docker compose pull
docker compose up -d
```

`docker compose up -d` is also the upgrade step; the image tag is pinned in
`docker-compose.yml`.

Home Assistant configuration is not in this repo. It lives in the private
`KejaniSH-Resources` repo, cloned to `~/.HASS`, and is bind-mounted at
`/config`. Edit the YAML there, then reload or restart HA.

## Backups

`scripts/backup.sh` writes a timestamped snapshot to
`~/backups/homeassistant/<YYYYMMDD-HHMMSS>/`:

| File | Contents |
|---|---|
| `hass-config.tar.gz` | entire `/config`, produced inside the container so root-owned `.storage` is included |
| `home-assistant_v2.db` | SQLite snapshot taken with the backup API (WAL-safe) |
| `docker-compose.yml`, `env.backup` | deployment inputs |
| `repo-worktree.tar.gz` | this repo's working tree |

Retention is 14 days. A systemd **user** timer runs it daily at 03:30
(`Persistent=true`, so a missed run happens at next boot):

```bash
systemctl --user list-timers homeassistant-backup.timer
systemctl --user start homeassistant-backup.service   # run now
```

`loginctl enable-linger jonnieey` must stay enabled so the timer runs without an
active session. The units are versioned in `scripts/systemd/`; install with:

```bash
mkdir -p ~/.config/systemd/user
cp scripts/systemd/homeassistant-backup.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now homeassistant-backup.timer
```

Backups are local only for now. Copy one snapshot off-device after every
upgrade — the SD card is a single point of failure.

### Restore drill

```bash
B=~/backups/homeassistant/<stamp>
mkdir -p /tmp/restore && tar -xzf "$B/hass-config.tar.gz" -C /tmp/restore
cp "$B/home-assistant_v2.db" /tmp/restore/config/
docker run -d --name ha-restore -p 8124:8123 \
  -v /tmp/restore/config:/config homeassistant/home-assistant:2026.11.1
# verify, then: docker rm -f ha-restore && rm -rf /tmp/restore
```

## Upgrade and rollback

Upgrade:

```bash
docker compose pull
docker compose up -d
```

Before upgrading, run `scripts/backup.sh` (or wait for the nightly run) and copy
the snapshot off-device. The pre-2026.11 image is kept as
`homeassistant/home-assistant:rollback-2024.7.2`.

Rollback is **not** just an image change: `.storage` and the recorder database
are migrated in place and old HA refuses the newer schema. Stop the container,
restore the whole pre-upgrade snapshot (config **and** database), point the
compose file at the rollback tag, and start.

## Secrets policy

- `.env` is untracked. It is ignored by `.gitignore` and was purged from
  history; use `.env.example` as the template.
- Never commit tokens, `.storage`, `secrets.yaml`, WLED config dumps (they
  contain the Wi-Fi password), or tarballs of the archived services.
- Two Home Assistant long-lived tokens leaked publicly in 2024 (AppDaemon
  `75c532ee…`, Rhasspy `f706ebbb…`). They were revoked in November 2026. Forks
  and caches may still contain them, so they must stay revoked — rewrites alone
  are not a rotation.
- The Tailscale auth key used by `tailscale up` should be revoked in the
  Tailscale admin console (it cannot be revoked from the node). The node keeps
  its saved state and reconnects without it.

## Rhasspy reference data

`reference/rhasspy/` keeps the old voice profile's `sentences.ini`, the `colors`
slot and a token-scrubbed `profile.example.json` for future Assist work. The
full profile (Kaldi/Vosk models) is in `~/.HASS/archive/rhasspy-*.tar.gz`. It is
not used by anything today.

## Layout

```
docker-compose.yml          HA deployment, pinned image
.env.example                template for the local .env
scripts/backup.sh           snapshot script
scripts/systemd/            daily backup timer/service
reference/rhasspy/          retired voice profile reference data
docs/specs/                 design documents
HomelabNetworkMap.md        network sketch
```
