# Spec: Retire AppDaemon, move lighting logic to native Home Assistant, clean up and upgrade

- **Status:** Draft — awaiting approval. No changes have been made to the Pi yet.
- **Date:** 2026-11-16
- **Target host:** `blackbeing` (Raspberry Pi 4, 8 GB) — LAN `192.168.0.101`, Tailscale `100.85.189.120`
- **Repos:** `jonnieey/KejaniSH` (public, compose + scripts), `jonnieey/KejaniSH-Resources` (private, `~/.HASS` HA config + AppDaemon)

---

## 1. Goals

1. **Fix WLED reboot behaviour.** After a WLED reboot, Home Assistant — not WLED — decides whether the bedroom lights should be on or off. WLED itself must boot dark.
2. **Make HA the single owner of automation state.** One desired-state helper, one idempotent apply script, explicit automations. No duplicated logic.
3. **Retire AppDaemon completely.** Container removed from compose, config archived, HA long-lived token revoked, port 5050 closed.
4. **Replace the working AppDaemon logic** (`bedlight.py` sun schedule, `movie_mode.py`, `dnd.py`) with native HA automations, fixing the bugs found in them.
5. **Clean up the runtime**: compose hygiene, dead services (Rhasspy, Portainer), stale `.env`, Docker socket confusion.
6. **Add backups** and a documented, reversible **Home Assistant upgrade** from 2024.7.2 to 2026.11.1.
7. **Remove leaked secrets** from the public repo and rotate/revoke them.
8. **Leave a documented, reproducible deploy model** (repo ↔ Pi) with a README runbook.

## 2. Non-goals

- Replacing voice control. Rhasspy is retired; voice input stays unavailable until a replacement (HA Assist/Wyoming satellite) is chosen. This spec only removes the dead service and keeps the color-name data for a future implementation.
- Rebuilding the network, changing router/DHCP, or hardening the LAN beyond what is listed.
- Rewriting `rpi-setup` / `rhasspy-setup` provisioning scripts. Known defects are recorded in §16 as a follow-up, not fixed here.
- Zigbee/Bluetooth/other integrations, dashboards, or new devices.
- Setting a WLED current limit (`maxpwr`) — needs the PSU rating; recorded as a follow-up.

## 3. Current state (verified 2026-11-15 / 2026-11-16)

| Area | Fact |
|---|---|
| OS | Raspberry Pi OS, kernel `6.12.93+rpt-rpi-v8`, aarch64, 29 GB SD, 17 GB free, 7.6 GB RAM |
| Docker | Docker 29.6.1 (rootful `dockerd`), Compose v5.3.1. `~/.bashrc` exports a stale rootless `DOCKER_HOST`, so every `docker` command needs `env -u DOCKER_HOST`. |
| HA | `homeassistant/home-assistant:latest`, content = **2024.7.2** (image built 2024-07-12). No backups. `automations.yaml = []`, `scripts.yaml` empty, `scenes.yaml` empty. |
| AppDaemon | 4.4.2, up 15 h, port 5050 exposed on `0.0.0.0`, HA token stored in plaintext in `appdaemon.yaml` (and committed once to the private repo). |
| Rhasspy | 2.5, port 12101, **no capture device** (`arecord: No such device`), HA URL still `http://192.168.100.110:8123`. Effectively dead. |
| Portainer | 2.19.5, mounts `/run/user/1000/docker.sock` (an empty **directory**) instead of `/var/run/docker.sock`; logs "Cannot connect to the Docker daemon". |
| HA entities | `light.wled`, `select.wled_preset` = `Solid Pattern`, `input_boolean.movie_mode` = off, `input_boolean.dnd` = off. TV entities `media_player.smart_tv_pro` / `remote.smart_tv_pro` are `unavailable` when the TV is off. |
| WLED | 16.0.1, 150 LEDs, `GET /json/info` → `leds.bootps = 1`; `GET /json/cfg` → `"def": {"ps": 1, "on": true, "bri": 128}`. Only preset: `1 = "Solid Pattern"` (`on: true`). `maxpwr = 0`, NTP disabled, clock at 1970. |
| WLED behaviour | Boots by applying preset 1 with `on:true`, which overrides `turnOnAtBoot`. HA history shows `light.wled` going `unavailable` → `on` repeatedly (e.g. 11:23 on 2026-11-15), including hours after sunrise. `sensor.wled_uptime` is disabled by the integration; it exposes the boot timestamp, which HA is not watching. |
| Secrets | Public repo `KejaniSH` tracks `.env` with a live HA long-lived token (`iss 75c5329e…`) and a Tailscale auth key (`TS_AUTHKEY`). Remote raw `.env` is 594 bytes, i.e. still published. Pi home also has `appdaemon_token.txt` and `tailscale_authkey.txt`. |
| Repo drift | `~/KejaniSH` on the Pi is **not a git repo** and differs from the public repo. `~/.HASS` has a private remote (`KejaniSH-Resources`, `main`) with an old commit; push auth fails (key not on GitHub). |
| Config ownership | HA config files are mostly `jonnieey`, but `.storage/auth` and `core.entity_registry` are `root` (container writes). Backups must read via the container. |
| Broken app logic | `movie_mode.py` selects presets `"Movie Mode"` / `"Default"` that do not exist; `cancel_tv_off_timer` awaits a non-awaitable and never clears the handle; turning movie mode off does nothing. `dnd.py` calls `call_service` without `await` and targets the retired Xiaomi `mobile_app_2201116pg`. `bedlight.py` has a dead `cancel_timers()`. |
| HA config wart | `configuration.yaml` has `frontend: themes: !include_dir_merge_named themes` but there is **no `themes/` directory**. Unused; remove. |
| SSH | `PasswordAuthentication yes`, `PermitRootLogin without-password`, user in `sudo`+`docker`, password is trivially weak (used for this inspection). Tailscale is active with an SSH-reachable node. |

## 4. Target architecture

```
                 ┌──────────────────────────────┐
   sun ─────────▶│ automation: sunrise/sunset   │──┐
   TV  ─────────▶│ automation: movie mode       │  │
   DND ─────────▶│ automation: DND notify       │  │   writes
   HA start ────▶│ automation: start reconcile  │  ├──────────▶ input_boolean.bedroom_lights_should_be_on
   WLED reboot ─▶│ automation: WLED reconcile   │  │            input_text.bedroom_lights_preset
   manual use ──▶│ automation: manual sync      │  │
                 └──────────────────────────────┘  │
                                                   ▼
                                    script.bedroom_light_apply  (idempotent)
                                                   │
                                    ┌──────────────┴──────────────┐
                                    ▼                             ▼
                        select.wled_preset = preset      light.turn_off
                        (or light.turn_on fallback)      light.wled
```

Rules:

- **One writer of intent:** the two helpers. Nothing calls `light.wled` directly except the apply script (movie-mode preset switching is the only other writer, and it reuses the preset entity).
- **Idempotent apply:** the script compares actual state (on/off and current preset) to desired state and only acts when they differ. Calling it twice is harmless.
- **WLED boots dark.** HA restores intent. If HA is also down, lights simply stay off until HA is back — the safe default.
- **AppDaemon, Rhasspy, Portainer are gone.** Tailscale stays a host service.

## 5. Design

### 5.1 New/used entities

| Entity | Type | Purpose |
|---|---|---|
| `input_boolean.bedroom_lights_should_be_on` | YAML helper | Single source of truth for on/off intent. Set by sun, movie mode off, manual sync, startup catch-up. |
| `input_text.bedroom_lights_preset` | YAML helper | Preset to restore when lights should be on. Default `Solid Pattern`. |
| `input_boolean.bedroom_lights_last_sun_state` | YAML helper (internal) | Records what the last sun event decided, so HA can detect a sun transition missed while it was off. |
| `timer.bedroom_movie_mode` | YAML helper | 5-minute auto-off after the TV goes off while movie mode is on. Survives HA restarts. |
| `script.bedroom_light_apply` | script | Idempotent reconciliation. |
| `light.wled`, `select.wled_preset` | existing | Only outputs. |
| `sensor.wled_uptime` | existing, **enable** | Reboot detection: the boot timestamp changes on every WLED restart. |

Additions to `configuration.yaml`: the four helpers, and removal of the unused `frontend:` block. `default_config` already loads `frontend`, `sun`, `recorder`, `mobile_app`.

### 5.2 WLED device configuration

All against `http://192.168.0.102`.

1. **Back up first** (into the backup directory, never the public repo, because `/json/cfg` contains the WiFi SSID):
   ```bash
   curl -s http://192.168.0.102/json/cfg      > wled-cfg.$(date +%F).json
   curl -s http://192.168.0.102/presets.json  > wled-presets.$(date +%F).json
   ```
2. **Boot dark:** fetch the full config, set `def.ps = 0` and `def.on = false`, POST the whole document back. Posting a partial `def` is avoided so unrelated settings are not reset. Both fields are required: `ps` is the boot preset, and a boot preset with `on:true` overrides `turnOnAtBoot`.
   ```bash
   python3 - <<'PY'
   import json
   cfg = json.load(open("wled-cfg.json"))
   cfg.setdefault("def", {})["ps"] = 0
   cfg["def"]["on"] = False
   json.dump(cfg, open("wled-cfg.new.json", "w"))
   PY
   curl -s -X POST -H 'Content-Type: application/json' \
        --data-binary @wled-cfg.new.json http://192.168.0.102/json/cfg
   ```
   Acceptance: `curl -s http://192.168.0.102/json/info | python3 -c 'import json,sys; print(json.load(sys.stdin)["leds"]["bootps"])'` → `0`.
3. **Create the `Movie Mode` preset** (id 2, dim warm solid):
   Two calls are required: apply the look, then save it. `psave` is processed
   before the incoming state is applied, and a preset only stores `on`/`bri`
   when `ib` (include brightness) is set.

   ```bash
   # 1. apply the look
   curl -s -X POST -H 'Content-Type: application/json' \
     http://192.168.0.102/json/state -d '{
       "on": true, "bri": 40, "transition": 7, "mainseg": 0,
       "seg": [{"id":0,"on":true,"bri":255,
                "col":[[255,110,84],[0,0,0],[0,0,0]],
                "fx":83,"sx":128,"ix":128,"pal":0}]
     }'
   # 2. save the current state as preset 2
   curl -s -X POST -H 'Content-Type: application/json' \
     http://192.168.0.102/json/state -d '{"psave":2,"ib":true,"n":"Movie Mode"}'
   ```
   Acceptance: `presets.json` has `"2": {"n": "Movie Mode", "on": true, "bri": 40, …}`,
   and applying `{"ps":2}` turns the strip on at brightness 40. HA's
   `select.wled_preset` options include `Movie Mode` within ~30 s (reload the
   WLED integration if not). Saving applies the look, so turn the strip off
   again on a daytime run.
4. **Reboot test (daytime and night-time):**
   ```bash
   curl -s -X POST -H 'Content-Type: application/json' http://192.168.0.102/json/state -d '{"rb":true}'
   ```
   Expect the strip dark immediately after boot in both cases. Within ~10–20 s HA reaches the correct state.

No HA-side WLED power limit, NTP, or firmware change in this spec (see §16).

### 5.3 Reconciliation semantics (truth table)

| Desired | `light.wled` | Current preset | Action |
|---|---|---|---|
| off | on | any | `light.turn_off` |
| off | off | any | nothing |
| on | on | equals desired preset | nothing |
| on | on | differs | `select.select_option(desired)` |
| on | off | desired preset exists | `select.select_option(desired)` (preset turns it on) |
| on | off | desired preset missing | `light.turn_on` (fallback) |
| any | `unavailable`/`unknown` | — | stop; the reconnect automation retries |

Consequences:

- Manual preset choice is **not** overwritten, because the script only runs on explicit triggers (helper change, reboot, HA start, movie-mode exit) and the "on + different preset" rule is only reached then.
- The apply script never loops: changing on/off updates the helper through the manual-sync automation, but a no-op state change does not retrigger anything.

### 5.4 Automation inventory

| ID | Trigger | Condition | Action |
|---|---|---|---|
| `bedroom_lights_desired_changed` | `should_be_on` or `bedroom_lights_preset` changes | — | apply |
| `bedroom_lights_sunrise` | sun `sunrise` | — | set `last_sun_state` off, then `should_be_on` off |
| `bedroom_lights_sunset` | sun `sunset` | — | set `last_sun_state` on, then `should_be_on` on |
| `bedroom_lights_ha_start` | `homeassistant` start | — | wait 20 s; if `last_sun_state` is unknown **or disagrees with current sun state** (a sun event was missed), re-derive both helpers from `sun.sun`; then apply |
| `bedroom_lights_wled_reconcile` | `light.wled` leaves `unavailable`/`unknown`, **or** `sensor.wled_uptime` moves by more than 30 s | boot trigger must move >30 s (jitter filter) | wait 10 s; if movie mode is on and the TV is active, select `Movie Mode`, otherwise apply the desired state |
| `bedroom_lights_manual_sync` | `light.wled` → `on`/`off` | after a 35 s settle: state unchanged and boot older than 60 s | set `should_be_on` to the new state |
| `movie_mode_toggle` | `input_boolean.movie_mode` | — | on + TV active → `Movie Mode`; on + TV inactive → apply; off → cancel timer, apply |
| `movie_mode_tv_state` | `media_player.smart_tv_pro` changes | movie mode on; WLED available | TV became active → cancel timer, `Movie Mode`; TV went inactive (incl. `unavailable` while previously active) → apply, start 5-min timer |
| `movie_mode_auto_off` | `timer.finished` = `timer.bedroom_movie_mode` | movie mode on | turn movie mode off (toggle automation restores normal state) |
| `dnd_follow_input_boolean` | `input_boolean.dnd` | — | `notify.mobile_app_pixel_9a` with `command_dnd` / `priority_only` or `off` |

Notes:

- **Why detect reboots twice:** normally the integration marks `light.wled` unavailable during a WLED reboot, but a short reboot can be missed by polling. The `sensor.wled_uptime` trigger covers that: the sensor holds the boot timestamp. WLED reports that timestamp with a +/-2 s jitter between polls, so the trigger only accepts a movement of more than 30 s. Both are harmless together because the script is idempotent.
- **Why manual sync is delayed and guarded:** a reboot briefly reports `off`; without guards that would be written back as "user turned the lights off". Live testing showed the light, preset and boot-timestamp entities update at different times (and the preset is `unknown` whenever the strip is off, so it cannot be used as a reboot signal). The automation therefore waits 35 s — longer than the reconcile automation's 10 s apply delay — and then re-checks that the light is still in the state that triggered it and that the boot is older than 60 s. A reboot with intent on is already back on by then, so it is ignored; a real manual change updates intent within ~35 s, not instantly. If the uptime sensor is missing, `as_timestamp(..., 0)` keeps sync working.
- **TV states:** when the TV is off, the Cast entity is `unavailable`, not `off`. "Active" therefore means any state not in `off`, `standby`, `unavailable`, `unknown`. A transition from active to `unavailable` counts as "TV off" for the timer.
- **DND:** uses the current `notify.mobile_app_pixel_9a` service. The phone must keep the Companion app's DND access permission; the automation cannot grant it.
- **Movie mode is an override:** enabling it while the TV is on turns the lights on at `Movie Mode` (and marks intent on via manual sync). Disabling it restores the desired state/preset.

### 5.5 Voice / Rhasspy

- Remove `bedlight.py`'s `rhasspy_ChangeLightState` / `rhasspy_ChangeLightColor` listeners with the rest of AppDaemon.
- Archive the dead profile to `~/.HASS/archive/rhasspy-<date>.tar.gz` (sentence files, Kaldi/Vosk models, stale token), remove the live directory, and copy `sentences.ini` + `slots/colors` plus `colors.json` into the repo as reference data for a future Assist implementation.
- Result: **no voice control** until a replacement input is installed. This is accepted explicitly.
- Optional future work: HA Assist + Wyoming (Whisper/Piper/openWakeWord) with a USB mic, using `light.turn_on` `color_name` for the common colors.

### 5.6 Compose / runtime cleanup

Target `docker-compose.yml` (full text in Appendix D):

- Remove `appdaemon`, `rhasspy`, `portainer` services and the commented Tailscale block.
- Pin `homeassistant/home-assistant:2026.11.1` (latest stable tag on Docker Hub as of 2026-11-16).
- Remove `version: '3'`, `privileged: true`, and `env_file: .env` from HA (no secrets are needed).
- Add `stop_grace_period: 60s` (clean recorder shutdown), log rotation (`10m × 3`), and an HTTP healthcheck.
- Keep bridge networking and `${HA_PORT:-8123}:8123`.
- Keep `/etc/localtime` and `/run/dbus` mounts.

`.env` (local only, gitignored) keeps only `HA_CONFIG_DIR` and `HA_PORT`; `.env.example` is committed.

Also:

- Remove the stale `DOCKER_HOST` export from `~/.bashrc`.
- Delete `/home/jonnieey/KejaniSH/appdaemon_token.txt` and `tailscale_authkey.txt`.
- Free ports 5050, 8000, 9443, 12101.
- Do **not** uninstall rootless Docker packages; only stop pointing the shell at the empty rootless socket.

### 5.7 Backups

New `scripts/backup.sh` (Appendix E) writes to `~/backups/homeassistant/<timestamp>/`:

1. `hass-config.tar.gz` — config tree minus `home-assistant_v2.db*`, `home-assistant.log*`, `.cloud`; produced **inside the container** so root-owned `.storage` files are readable.
2. `home-assistant_v2.db` — consistent copy via Python's `sqlite3.Connection.backup()` (WAL-safe).
3. `docker-compose.yml`, `env.backup` (mode 600), and a tar of the `~/KejaniSH` worktree (no `.git`).
4. Retention: 14 days.

Scheduled with a **systemd user timer** (03:15 daily) plus `loginctl enable-linger jonnieey`. Requires `env -u DOCKER_HOST` inside the script.

Restore procedure (documented in README): stop HA, untar config over `~/.HASS/hass/config`, copy the DB, start HA.

Off-site storage is deferred (decision 5): keep 14 days locally and copy one snapshot off-device after each upgrade. HA's native *Backups* integration can be pointed at a network target later.

### 5.8 Home Assistant upgrade (2024.7.2 → 2026.11.1)

Direct upgrade is supported (recorder/storage migrations run sequentially at startup). It is still a two-year jump, so the plan is backup-first and explicitly reversible:

1. Tag the current image locally for rollback:
   ```bash
   env -u DOCKER_HOST docker tag \
     "$(env -u DOCKER_HOST docker inspect homeassistant --format '{{.Image}}')" \
     homeassistant/home-assistant:rollback-2024.7.2
   ```
2. Run `scripts/backup.sh` and copy the backup off the SD card.
3. Set the image to `2026.11.1`, `docker compose pull homeassistant`, `docker compose up -d`.
4. Watch startup (`docker logs -f homeassistant`); first start can take several minutes (DB migration + dependency install). Verify: UI login, WLED entities, mobile app notifications, sun/automation traces, recorder history.
5. Keep 2024.7.2 pullable for a week.

**Rollback** = stop the container, restore the *whole* config snapshot (`.storage` and the DB are migrated in place and are **not** downgrade-safe), point the image back at `homeassistant/home-assistant:2024.7.2` (or the local rollback tag), and start. The DB from the backup must be restored too, otherwise old HA may refuse the newer schema.

Pre-upgrade config changes that must land first: remove the broken `frontend: themes` include, deploy the new helpers/automations, stop AppDaemon. This keeps the upgrade diff about the upgrade only.

HA 2026.11 note: after the upgrade, move `home-assistant.log` handling/recorder retention decisions to the new defaults (recorder keeps 10 days by default) and configure native backups.

### 5.9 Secrets and repo hygiene

Rotation (do this regardless of history rewriting — the token has been public since 2024-10):

1. **Revoke the leaked HA tokens** in Profile → Security → Refresh tokens, or via WebSocket `auth/delete_refresh_token` with the JWT `iss` as `refresh_token_id`:
   - AppDaemon: `75c5329e9d71434ab03a46e859d3a236`
   - Rhasspy: `f706ebbb…` (read it from `rhasspy/profiles/en/profile.json` before archiving)
   No replacement tokens are needed once both services are gone.
2. **Revoke the Tailscale auth key** in the Tailscale admin console (cannot be done from the node). Confirm the host stays connected via its saved state.
3. **Change the `jonnieey` password** and install SSH keys (see phase 8 in §6).

Repo cleanup (`jonnieey/KejaniSH`):

1. `git rm --cached .env`, add `.gitignore`:
   ```
   .env
   *.token
   *.token.txt
   wled-cfg*.json
   wled-presets*.json
   ```
2. Add `.env.example` with placeholder values (no `TS_AUTHKEY`, no tokens).
3. Purge `.env` from history (no `git-filter-repo` installed; use `filter-branch`):
   ```bash
   git filter-branch --force --index-filter \
     'git rm --cached --ignore-unmatch .env' \
     --prune-empty --tag-name-filter cat -- --all
   git for-each-ref --format='delete %(refname)' refs/original | git update-ref --stdin
   git reflog expire --expire=now --all && git gc --prune=now --aggressive
   git push --force --all && git push --force --tags
   ```
4. Note in the README that the old token is public and must stay revoked even after history is clean (forks/caches).

`~/.HASS` (private repo): add `portainer/`, `rhasspy/`, `archive/` to `.gitignore`; scrub the token from `appdaemon.yaml` history only if it was ever committed (currently `appdaemon.yaml` is modified in the worktree; the committed copy is assumed to contain a token). Since the repo is private and the token is revoked, a rewrite is optional; at minimum, remove the file with the AppDaemon directory.

### 5.10 Entity / config cleanup

- Enable `sensor.wled_uptime` (Settings → Devices & Services → Entities → show disabled → enable). This is required for reliable reboot detection.
- Delete stale mobile-app devices/entries:
  - Xiaomi `2201116PG` (app 2025.1.2, device `ee0cf9ec3b4d044c`)
  - Pixel 9a app 2026.6.5 (device `ab084697aed03258`)
  - Keep Pixel 9a app 2026.11.1 (device `e518a08705267bb6`), which owns `notify.mobile_app_pixel_9a`.
- Create an area **Bedroom**; assign the WLED device and the TV.
- Give `input_boolean.dnd` / `input_boolean.movie_mode` proper names and icons; keep them UI-managed.
- Remove `frontend: themes` from `configuration.yaml`; no `themes/` directory exists.
- Optional: rename `light.wled` friendly name to "Bedroom Lights".
- Leave `update.wled_firmware`, `number.*`, `switch.*` diagnostic entities as-is.

### 5.11 Deploy model

- `~/KejaniSH` becomes a real clone of the public repo; `.env` stays local and untracked; deploy = `git pull && docker compose pull && docker compose up -d`.
- `~/.HASS` stays a clone of the private repo, and HA config changes are committed there.
- Fix Pi push auth: add the Pi's `~/.ssh/id_ed25519.pub` as a write deploy key on `KejaniSH-Resources` using the local authenticated `gh`:
  ```bash
  gh repo deploy-key add /tmp/pi-blackbeing.pub \
     --repo jonnieey/KejaniSH-Resources \
     --title pi-blackbeing --allow-write
  ```
  If deploy keys are undesirable, mirror the Pi repo to GitHub by pushing the fetched branch from the local machine.
- `README.md` (currently empty) becomes the runbook: topology, deploy, backup/restore, upgrade/rollback, and the secrets policy.

### 5.12 Post-implementation findings (2026-11-18)

- **Sun logic verified in production:** sunset fired unattended on 2026-11-18 at
  18:32 (intent `on`, strip `on`). Sunrise was missed because the Pi rebooted
  twice overnight (00:31 and 09:09) and, with no RTC, its clock jumped when NTP
  corrected it; the `startup` reconcile restored the correct intent nine minutes
  after HA came up. That is the designed fallback, not a regression.
- The reboots left no clean-shutdown record and no undervoltage entries;
  `vcgencmd get_throttled` reads `0x0` on the current boot. The most likely cause
  is a power interruption — see follow-up 12.
- **DND mirror:** `notify.mobile_app_pixel_9a` still exists on 2026.11 and is the
  only path for Companion notification commands such as `command_dnd`
  (`notify.send_message` accepts only `message`/`title`). Delivery is local-push
  only — the phone's entry has `push_websocket_channel: true` and no `push_url`
  or cloudhook — so it works while the app holds its WebSocket to HA and fails
  with `not connected to local push notifications` otherwise. The automation now
  sets `continue_on_error: true` and sends `ttl: 0` / `priority: high`; see
  follow-up 13.
- Registry cleanup: 16 → 14 config entries, 10 → 8 devices, 393 → 192 entities.
  The stale Pixel 9a entry (app 2026.6.5) was the duplicate that takes over
  `notify.mobile_app_<device>` when two registrations share a device name.

## 6. Execution plan

Each phase is independently verifiable and revertible. Order matters: AppDaemon must stop **before** native HA logic is enabled, otherwise both drive the lights at sunrise/sunset.

| Phase | Work | Verify | Rollback |
|---|---|---|---|
| **0. Prep** | Write `scripts/backup.sh`, create `~/backups`, run it, copy the snapshot off-device; record image digest; tag rollback image; snapshot WLED cfg/presets | backup files exist and are readable; `tar -tzf` lists config | n/a |
| **1. WLED** | Boot preset off + `def.on=false`; create `Movie Mode`; reboot test | `bootps=0`; strip dark after `{"rb":true}`; preset 2 exists | POST the saved `wled-cfg` backup |
| **2. Stop AppDaemon** | `docker compose stop appdaemon` (not removed yet) | `light.wled` no longer toggles at sun events; no AppDaemon log entries | `docker compose start appdaemon` |
| **3. Native logic** | Write helpers into `configuration.yaml`, `scripts.yaml`, `automations.yaml`; remove `frontend:` block; enable `sensor.wled_uptime`; restart HA | Config valid; run apply script manually; test day/night reboot; sunrise/sunset tested with `sun` trigger simulation | restore the three YAML files from the backup and restart |
| **4. Retire AppDaemon** | Remove service from compose; archive `~/.HASS/appdaemon`; `docker compose up -d --remove-orphans`; delete token files; revoke HA tokens; close 5050 | `docker ps` has only `homeassistant`; 5050 refused; no AppDaemon refresh token | re-add service, untar archive, restore token |
| **5. Compose + upgrade** | Apply new compose (pin 2026.11.1, log rotation, healthcheck, grace period); remove `DOCKER_HOST` from `.bashrc`; pull; up -d | `docker ps` healthy; HA version 2026.11.1 in UI; entities present; logs clean | restore config backup + 2024.7.2 image |
| **6. Backups** | Install the systemd user unit/timer (`backup.sh` already written in phase 0); confirm linger | `systemctl --user list-timers`; manual run; test restore into a temp dir | remove unit/timer |
| **7. Repo/secrets** | `.gitignore`, `.env.example`, untrack `.env`, purge history, force-push; deploy-key for Pi; README | `git ls-files` has no `.env`; raw URL 404; `gh api` shows key; Pi `git push` works | local `git reflog`/backup clone |
| **8. Cleanup + SSH** | SSH keys, password change, `PasswordAuthentication no`; remove stale mobile_app entries; areas; entity names | key-only login works; phone notifies | keep an existing session open; revert sshd drop-in |

**Phase 8 (SSH hardening) is deliberately last.** Locking out password auth on a headless Pi is the highest-risk change in this spec. Procedure: install the public key, verify with `ssh -o PreferredAuthentications=publickey`, then disable password auth. If any step is unclear, stop.

**Tailscale SSH (2026-11-18):** `tailscale set --ssh` was tried as a fallback and reverted. The tailnet policy currently requires an interactive check (`https://login.tailscale.com/a/…`) for each new connection, and enabling it reroutes all tailnet SSH through that check, which breaks key-based automation and offers no unattended fallback. Keep it off until the ACL grants `ssh` with `action: accept`, and re-test with a watchdog (`sleep 240; tailscale set --ssh=false`) in case the change locks you out.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| HA 2024.7.2 → 2026.11.1 migration fails or config key removed | HA down | Full config+DB backup; documented restore; 2024.7.2 image tagged and retained |
| Rollback onto a migrated DB/`.storage` | Old HA refuses to start | Rollback always restores the pre-upgrade backup, never just the image |
| WLED boots dark while HA is down | Lights stay off at night | Accepted safe default; user can toggle WLED manually |
| Two writers during migration (AppDaemon + HA) | Flicker/fighting | Stop AppDaemon before enabling automations |
| Manual-sync echoes reboot transitions | Intent gets flipped | `from` not unavailable + boot-older-than-60 s guards |
| `select.wled_preset` option list stale after preset creation | Script selects a missing option | Default `input_text` fallback + preset-existence check + integration reload |
| `notify` DND permission missing on the phone | DND command silently ignored | Documented; verify manually once |
| Secrets remain in GitHub forks/caches after purge | Token still usable | Revocation is mandatory; rotation is the real fix |
| Deploy key / repo auth changes | Cannot push HA config from Pi | Write deploy key added with local `gh`; local mirror as fallback |
| SSH lockout | No access | Key verified before disabling passwords; Tailscale SSH fallback; keep an existing session open |

## 8. Test plan / acceptance criteria

1. **WLED reboot during the day:** helper off → reboot → strip dark → after ~15 s still off; `light.wled` off; no "on" flash in history.
2. **WLED reboot at night:** helper on → reboot → strip dark briefly, then on with `Solid Pattern`; helper unchanged.
3. **WLED unavailable at sunset:** stop WLED (or block it), let the sunset automation fire; helper on, light still unavailable; power WLED → HA applies preset.
4. **Sunrise / sunset:** at each event the helper flips and the lights follow; `last_sun_state` matches the event.
5. **Manual override:** toggle `light.wled` off at night in HA; helper becomes off within ~35 s and stays off through a restart.
6. **HA restart:** helper restored; if HA was down across a sun event, the new state is re-derived (tested by stopping HA before sunset and starting after).
7. **Movie mode:** TV on + movie mode on → `Movie Mode` preset; TV off → normal preset restored; 5 min later movie mode off automatically; movie mode off → desired state (including off) restored.
8. **DND:** toggle helper on/off → Pixel 9a enters/leaves priority-only.
9. **Idempotence:** call `script.bedroom_light_apply` twice with no change → second call performs no service calls (Trace shows an early `stop`).
10. **Cleanup:** only `homeassistant` is running; 5050/8000/9443/12101 closed; `.env` absent from git; leaked tokens revoked.
11. **Backup/restore drill:** restore a backup into a temporary directory and start a throwaway HA container against it; entity registry and automations present.
12. **Upgrade:** HA 2026.11.1 UI reachable, WLED + mobile app + automation traces work, recorder history continuous.

## 9. Decisions (resolved 2026-11-17)

| # | Decision | Outcome |
|---|---|---|
| 1 | Missed-sun-event catch-up | **Keep the extra helper.** `input_boolean.bedroom_lights_last_sun_state` stays in scope; a sun event missed while HA was down is re-derived at startup. |
| 2 | Movie mode + TV off | **Restore normal lights.** Apply the desired preset (or off), matching the original `"Default"` intent. |
| 3 | Rhasspy profile | **Keep a tarball on the Pi.** Archive to `~/.HASS/archive/rhasspy-<date>.tar.gz`, delete the live directory, copy `sentences.ini` and `slots/colors` into the repo for future Assist work. |
| 4 | SSH hardening | **In scope, keys first.** Phase 8 is no longer optional: install the key, verify key-only login, enable Tailscale SSH as fallback, change the password, then disable password auth. |
| 5 | Off-site backups | **Local only for now.** 14-day retention on the Pi plus a manual copy after each upgrade; off-site research deferred (follow-up §16). |

## 10. Appendix A — `configuration.yaml`

```yaml
# Loads the default integration set (frontend, sun, recorder, mobile_app, ...).
default_config:

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

input_boolean:
  bedroom_lights_should_be_on:
    name: Bedroom lights should be on
    icon: mdi:lightbulb-on
  bedroom_lights_last_sun_state:
    name: Bedroom lights last sun state
    icon: mdi:weather-sunset

input_text:
  bedroom_lights_preset:
    name: Bedroom lights preset
    icon: mdi:palette
    initial: Solid Pattern
    max: 32

timer:
  bedroom_movie_mode:
    name: Bedroom movie mode auto-off
    duration: "00:05:00"
```

## 11. Appendix B — `scripts.yaml`

```yaml
bedroom_light_apply:
  alias: "Bedroom lights: apply desired state"
  description: >-
    Idempotently make light.wled match input_boolean.bedroom_lights_should_be_on
    and input_text.bedroom_lights_preset. Does nothing if WLED is unavailable or
    if the actual state already matches the desired state.
  icon: mdi:lightbulb-auto
  mode: queued
  max: 5
  sequence:
    - if:
        - condition: template
          value_template: >-
            {{ is_state('light.wled', 'unavailable')
               or is_state('light.wled', 'unknown') }}
      then:
        - stop: "WLED is unavailable; will reconcile when it reconnects."
    - variables:
        desired_on: >-
          {{ is_state('input_boolean.bedroom_lights_should_be_on', 'on') }}
        desired_preset: >-
          {% set p = states('input_text.bedroom_lights_preset') | trim %}
          {{ p if p not in ['', 'unknown', 'unavailable'] else 'Solid Pattern' }}
        current_preset: "{{ states('select.wled_preset') }}"
        preset_exists: >-
          {{ desired_preset in (state_attr('select.wled_preset', 'options') or []) }}
    - choose:
        # Desired off
        - conditions:
            - condition: template
              value_template: "{{ not desired_on }}"
          sequence:
            - if:
                - condition: template
                  value_template: "{{ is_state('light.wled', 'on') }}"
              then:
                - service: light.turn_off
                  target:
                    entity_id: light.wled
        # Desired on and already correct
        - conditions:
            - condition: template
              value_template: >-
                {{ is_state('light.wled', 'on')
                   and current_preset == desired_preset }}
          sequence:
            - stop: "Already on with the desired preset."
        # Desired on, preset available
        - conditions:
            - condition: template
              value_template: "{{ preset_exists }}"
          sequence:
            - service: select.select_option
              target:
                entity_id: select.wled_preset
              data:
                option: "{{ desired_preset }}"
      # Desired on, preset missing: plain turn-on fallback
      default:
        - service: light.turn_on
          target:
            entity_id: light.wled
```

## 12. Appendix C — `automations.yaml`

```yaml
- id: bedroom_lights_desired_changed
  alias: "Bedroom lights: apply desired state on change"
  description: >-
    The only trigger that acts on a user, sun or script change of intent.
  mode: restart
  trigger:
    - platform: state
      entity_id: input_boolean.bedroom_lights_should_be_on
    - platform: state
      entity_id: input_text.bedroom_lights_preset
  action:
    - service: script.bedroom_light_apply

- id: bedroom_lights_sunrise
  alias: "Bedroom lights: sunrise (desired off)"
  description: Record the sun decision and set bedroom light intent to off.
  mode: single
  trigger:
    - platform: sun
      event: sunrise
  action:
    - service: input_boolean.turn_off
      target:
        entity_id: input_boolean.bedroom_lights_last_sun_state
    - service: input_boolean.turn_off
      target:
        entity_id: input_boolean.bedroom_lights_should_be_on

- id: bedroom_lights_sunset
  alias: "Bedroom lights: sunset (desired on)"
  description: Record the sun decision and set bedroom light intent to on.
  mode: single
  trigger:
    - platform: sun
      event: sunset
  action:
    - service: input_boolean.turn_on
      target:
        entity_id: input_boolean.bedroom_lights_last_sun_state
    - service: input_boolean.turn_on
      target:
        entity_id: input_boolean.bedroom_lights_should_be_on

- id: bedroom_lights_ha_start
  alias: "Bedroom lights: reconcile on Home Assistant start"
  description: >-
    Re-derive intent from the sun only if the helper is new or a sun event was
    missed while HA was off; otherwise preserve the restored user intent.
  mode: single
  trigger:
    - platform: homeassistant
      event: start
  action:
    - delay: "00:00:20"
    - variables:
        sun_state: >-
          {{ 'on' if is_state('sun.sun', 'below_horizon') else 'off' }}
        last_sun: >-
          {{ states('input_boolean.bedroom_lights_last_sun_state') }}
    - if:
        - condition: template
          value_template: >-
            {{ last_sun in ['unknown', 'unavailable'] or last_sun != sun_state }}
      then:
        - if:
            - condition: template
              value_template: "{{ sun_state == 'on' }}"
          then:
            - service: input_boolean.turn_on
              target:
                entity_id:
                  - input_boolean.bedroom_lights_last_sun_state
                  - input_boolean.bedroom_lights_should_be_on
          else:
            - service: input_boolean.turn_off
              target:
                entity_id:
                  - input_boolean.bedroom_lights_last_sun_state
                  - input_boolean.bedroom_lights_should_be_on
    - service: script.bedroom_light_apply

- id: bedroom_lights_wled_reconcile
  alias: "Bedroom lights: reconcile after WLED restart"
  description: >-
    WLED boots dark; apply the desired state once it is reachable again. The
    boot-timestamp trigger catches reboots too short to make the entity
    unavailable, and ignores the small jitter WLED reports between polls.
  mode: restart
  trigger:
    - platform: state
      entity_id: light.wled
      from:
        - unavailable
        - unknown
      id: reconnect
    - platform: state
      entity_id: sensor.wled_uptime
      not_to:
        - unavailable
        - unknown
      id: boot
  condition:
    - condition: template
      value_template: >-
        {{ trigger.id != 'boot'
           or (as_timestamp(trigger.to_state.state, 0)
               - as_timestamp(trigger.from_state.state, 0)) | abs > 30 }}
  action:
    - delay: "00:00:10"
    - if:
        - condition: state
          entity_id: input_boolean.movie_mode
          state: "on"
        - condition: template
          value_template: >-
            {{ states('media_player.smart_tv_pro')
               not in ['off', 'standby', 'unavailable', 'unknown'] }}
      then:
        - service: select.select_option
          target:
            entity_id: select.wled_preset
          data:
            option: "Movie Mode"
      else:
        - service: script.bedroom_light_apply

- id: bedroom_lights_manual_sync
  alias: "Bedroom lights: follow manual on/off changes"
  description: >-
    Keep the helper in sync when the light is switched outside the apply script.
    Waits longer than the reconcile automation, then re-checks that the light
    is still in the triggered state and the boot is older than 60 s, so WLED
    restarts are not mistaken for user intent.
  mode: restart
  trigger:
    - platform: state
      entity_id: light.wled
      to:
        - "on"
        - "off"
  condition:
    - condition: template
      value_template: >-
        {{ trigger.from_state is not none
           and trigger.from_state.state not in ['unavailable', 'unknown'] }}
  action:
    - delay: "00:00:35"
    - if:
        - condition: template
          value_template: "{{ is_state('light.wled', trigger.to_state.state) }}"
        - condition: template
          value_template: >-
            {{ now().timestamp()
               - as_timestamp(states('sensor.wled_uptime'), 0) >= 60 }}
      then:
        - if:
            - condition: template
              value_template: "{{ trigger.to_state.state == 'on' }}"
          then:
            - service: input_boolean.turn_on
              target:
                entity_id: input_boolean.bedroom_lights_should_be_on
          else:
            - service: input_boolean.turn_off
              target:
                entity_id: input_boolean.bedroom_lights_should_be_on

- id: movie_mode_toggle
  alias: "Movie mode: apply on enable, restore on disable"
  mode: restart
  trigger:
    - platform: state
      entity_id: input_boolean.movie_mode
  action:
    - if:
        - condition: state
          entity_id: input_boolean.movie_mode
          state: "on"
      then:
        - if:
            - condition: template
              value_template: >-
                {{ states('media_player.smart_tv_pro')
                   not in ['off', 'standby', 'unavailable', 'unknown'] }}
            - condition: template
              value_template: "{{ not is_state('light.wled', 'unavailable') }}"
          then:
            - service: select.select_option
              target:
                entity_id: select.wled_preset
              data:
                option: "Movie Mode"
          else:
            - service: script.bedroom_light_apply
      else:
        - service: timer.cancel
          target:
            entity_id: timer.bedroom_movie_mode
        - service: script.bedroom_light_apply

- id: movie_mode_tv_state
  alias: "Movie mode: follow TV power"
  description: >-
    Cast entities report unavailable when the TV is off, so an active to
    inactive transition (including unavailable) starts the auto-off timer.
  mode: restart
  trigger:
    - platform: state
      entity_id: media_player.smart_tv_pro
  condition:
    - condition: state
      entity_id: input_boolean.movie_mode
      state: "on"
    - condition: template
      value_template: "{{ not is_state('light.wled', 'unavailable') }}"
  action:
    - variables:
        tv_active: >-
          {{ trigger.to_state.state not in ['off', 'standby', 'unavailable', 'unknown'] }}
        tv_was_active: >-
          {{ trigger.from_state is not none
             and trigger.from_state.state not in ['off', 'standby', 'unavailable', 'unknown'] }}
    - choose:
        - conditions:
            - condition: template
              value_template: "{{ tv_active }}"
          sequence:
            - service: timer.cancel
              target:
                entity_id: timer.bedroom_movie_mode
            - service: select.select_option
              target:
                entity_id: select.wled_preset
              data:
                option: "Movie Mode"
        - conditions:
            - condition: template
              value_template: "{{ tv_was_active }}"
          sequence:
            - service: script.bedroom_light_apply
            - service: timer.start
              target:
                entity_id: timer.bedroom_movie_mode

- id: movie_mode_auto_off
  alias: "Movie mode: auto-off after TV is off"
  mode: single
  trigger:
    - platform: event
      event_type: timer.finished
      event_data:
        entity_id: timer.bedroom_movie_mode
  condition:
    - condition: state
      entity_id: input_boolean.movie_mode
      state: "on"
  action:
    - service: input_boolean.turn_off
      target:
        entity_id: input_boolean.movie_mode

- id: dnd_follow_input_boolean
  alias: "DND: mirror helper to Pixel 9a"
  mode: single
  trigger:
    - platform: state
      entity_id: input_boolean.dnd
  action:
    - service: notify.mobile_app_pixel_9a
      data:
        message: command_dnd
        data:
          command: >-
            {{ 'priority_only' if is_state('input_boolean.dnd', 'on') else 'off' }}
```

## 13. Appendix D — `docker-compose.yml`

```yaml
services:
  homeassistant:
    container_name: homeassistant
    image: homeassistant/home-assistant:2026.11.1
    restart: unless-stopped
    stop_grace_period: 60s
    environment:
      TZ: Africa/Nairobi
    ports:
      - "${HA_PORT:-8123}:8123"
    volumes:
      - "${HA_CONFIG_DIR}:/config"
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test:
        - CMD-SHELL
        - >-
          python -c "import urllib.request;
          urllib.request.urlopen('http://127.0.0.1:8123/manifest.json', timeout=5)"
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 180s
```

`.env.example`:

```bash
HA_CONFIG_DIR="${HOME}/.HASS/hass/config"
HA_PORT=8123
```

## 14. Appendix E — `scripts/backup.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups/homeassistant}"
CONFIG_DIR="${HOME}/.HASS/hass/config"
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_ROOT}/${STAMP}"
DOCKER="env -u DOCKER_HOST docker"

mkdir -p "$DEST"

# Config tree, read as root inside the container so .storage/auth is included.
$DOCKER exec homeassistant tar -C / -czf - \
  --exclude='config/home-assistant_v2.db*' \
  --exclude='config/home-assistant.log*' \
  --exclude='config/.cloud' \
  config > "${DEST}/hass-config.tar.gz"

# Consistent SQLite snapshot (WAL-safe).
python3 - "${CONFIG_DIR}/home-assistant_v2.db" "${DEST}/home-assistant_v2.db" <<'PY'
import sqlite3
import sys

src, dst = sys.argv[1], sys.argv[2]
source = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
target = sqlite3.connect(dst)
with target:
    source.backup(target)
target.close()
source.close()
PY

# Deployment inputs.
cp "$HOME/KejaniSH/docker-compose.yml" "${DEST}/" 2>/dev/null || true
if [ -f "$HOME/KejaniSH/.env" ]; then
  cp "$HOME/KejaniSH/.env" "${DEST}/env.backup"
  chmod 600 "${DEST}/env.backup"
fi
tar -C "$HOME/KejaniSH" -czf "${DEST}/repo-worktree.tar.gz" \
  --exclude='.git' . 2>/dev/null || true

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${KEEP_DAYS}" -exec rm -rf {} +

echo "Backup written to ${DEST}"
```

Systemd user units (installed by `scripts/install-backup-timer.sh`):

```ini
# ~/.config/systemd/user/homeassistant-backup.service
[Unit]
Description=Back up Home Assistant config and database

[Service]
Type=oneshot
ExecStart=%h/KejaniSH/scripts/backup.sh
```

```ini
# ~/.config/systemd/user/homeassistant-backup.timer
[Unit]
Description=Daily Home Assistant backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now homeassistant-backup.timer
sudo loginctl enable-linger jonnieey
```

## 15. Appendix F — implementation checklist

- [ ] Backup created and copied off the Pi
- [ ] Rollback image tagged (`homeassistant/home-assistant:rollback-2024.7.2`)
- [ ] WLED cfg/presets backed up (outside the repo)
- [ ] `def.ps = 0`, `def.on = false`; `leds.bootps = 0`
- [ ] `Movie Mode` preset created and visible in HA
- [ ] Reboot test passes by day and by night
- [ ] `configuration.yaml` helpers added, `frontend:` block removed
- [ ] `scripts.yaml` / `automations.yaml` deployed, config check passes
- [ ] `sensor.wled_uptime` enabled
- [ ] `script.bedroom_light_apply` idempotence test passes
- [ ] AppDaemon stopped, then removed; archive created
- [ ] 5050/8000/9443/12101 closed; only `homeassistant` running
- [ ] New compose applied; HA on 2026.11.1; healthcheck healthy
- [ ] `DOCKER_HOST` removed from `~/.bashrc`
- [ ] Backup timer active + restore drill passed
- [ ] Leaked HA tokens revoked; Tailscale key revoked; password changed
- [ ] `.env` untracked, history purged, force-push done
- [ ] Deploy key added; `~/KejaniSH` clone; Pi can push `~/.HASS`
- [ ] Stale mobile_app devices removed; Bedroom area created
- [ ] README runbook written
- [ ] SSH key-only login verified, password changed, then password auth disabled

## 16. Follow-ups (explicitly out of scope here)

Recorded so they are not lost; each is a separate change set.

1. **`rpi-setup` defects:** `$ROUTE` is used but never defined (gateway), `SetupStaticIP` runs even when `USE_STATIC_IP=no`, `SetupNetwork` is never called, `IFconsole=` should be `console=`, `$image_file_path` is referenced before assignment, and `mkfs.ext4` runs before `dd` (redundant/incorrect order). Add `set -euo pipefail` and shellcheck in CI.
2. **`rhasspy-setup` defects:** installs rootless Docker while the host uses rootful, `apt remove pulseaudio` has no `-y`, and it sources `~/.bashrc` as root. Retire the script with Rhasspy.
3. **WLED power safety:** `maxpwr = 0` means no current limit on 150 LEDs. Set a limit that matches the PSU rating before running long bright effects.
4. **WLED clock:** NTP is disabled and the clock reads 1970. Enable NTP if WLED schedules/timers are ever used.
5. **WLED reboot frequency:** `light.wled` dropped to `unavailable` on most nights (00:00–02:00) even before this change. Once `sensor.wled_uptime` is enabled, log resets for a week; if they continue, suspect the PSU, the 5 V wiring, or WiFi power management (check `dmesg` for undervoltage, `vcgencmd get_throttled`).
6. **Voice input:** choose a replacement for Rhasspy (HA Assist + Wyoming satellite). The retained `colors.json` can drive `light.turn_on` color names or an `input_select` of favorite colors.
7. **Exposure:** HA (8123) is still reachable on the LAN; 5050/8000/9443/12101 are closed by this spec. Consider a reverse proxy with auth or Tailscale-only access for the HA UI in a later pass.
8. **Entity naming:** friendly names/areas for all WLED diagnostic entities, and removal of the `update.wled_firmware` entity if firmware updates are handled manually.
9. **Off-site backups:** add an rclone/SMB target and point both the script and HA's native *Backups* integration at it so an SD-card failure is recoverable.
10. **Tailscale access:** the node's `tailscale set --ssh` is off because the tailnet ACL requires an interactive check per connection (§6, phase 8). Add an `ssh` rule with `action: accept` for this node (or for the admin user) and re-test before relying on it as the break-glass path. Revoke the 2024 `tailscale up` auth key in the admin console.
11. **HA credentials:** the owner login and the OS login use different passwords; record the owner password in a password manager (the OS password is being rotated as part of phase 8).
12. **Power resilience / RTC:** the Pi has no RTC and lost power twice on 2026-11-17/18. `fake-hwclock` + NTP then jump the clock, which can silently skip a sun trigger (the startup reconcile recovers the intent, but minutes late). Add a UPS/supercapacitor HAT or an RTC module, and consider `wait-online`/`timesyncd` ordering so the clock is settled before automations load.
13. **Phone push:** `notify.mobile_app_pixel_9a` and the notify entity only deliver via local push while the app is connected to HA on the LAN. Add a cloud/remote push URL (Nabu Casa or another push server) if notifications must work when the phone is away, or treat DND mirroring as best-effort.
