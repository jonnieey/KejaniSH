#!/usr/bin/env bash
#
# Back up Home Assistant config, database and deployment inputs.
# See docs/specs/2026-11-16-retire-appdaemon-native-automation.md (§5.7).
#
# The config tar is produced inside the running container because some HA
# config files (.storage/auth, core.entity_registry) are owned by root.
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups/homeassistant}"
CONFIG_DIR="${HOME}/.HASS/hass/config"
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_ROOT}/${STAMP}"
DOCKER="env -u DOCKER_HOST docker"

mkdir -p "$DEST"

if ! $DOCKER ps --format '{{.Names}}' | grep -qx homeassistant; then
  echo "homeassistant container is not running" >&2
  exit 1
fi

# 1. Config tree, read as root inside the container so .storage is included.
$DOCKER exec homeassistant tar -C / -czf - \
  --exclude='config/home-assistant_v2.db*' \
  --exclude='config/home-assistant.log*' \
  --exclude='config/.cloud' \
  config > "${DEST}/hass-config.tar.gz"

# 2. Consistent SQLite snapshot (WAL-safe).
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

# 3. Deployment inputs.
cp "$HOME/KejaniSH/docker-compose.yml" "${DEST}/" 2>/dev/null || true
if [ -f "$HOME/KejaniSH/.env" ]; then
  cp "$HOME/KejaniSH/.env" "${DEST}/env.backup"
  chmod 600 "${DEST}/env.backup"
fi
tar -C "$HOME/KejaniSH" -czf "${DEST}/repo-worktree.tar.gz" \
  --exclude='.git' . 2>/dev/null || true
chmod 600 "${DEST}/repo-worktree.tar.gz" 2>/dev/null || true

# 4. Retention.
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${KEEP_DAYS}" -exec rm -rf {} +

echo "Backup written to ${DEST}"
