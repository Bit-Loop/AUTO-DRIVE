#!/usr/bin/env bash
# Module 05: Daily 03:30 UTC .tar.zst snapshots into RW ~/DRIVE/encrypted/snapshots/<host>/

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

sudo mkdir -p /usr/local/libexec

# Stage root-owned /etc system & reverse-proxy configs safely before archiving $HOME
sudo tee /usr/local/libexec/auto-drive-stage-etc >/dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail
umask 077
install -d -m 0700 -o $AUTO_DRIVE_USER -g $AUTO_DRIVE_GROUP "$AUTO_DRIVE_HOME/.backups"

existing=()
for p in /etc/nginx /etc/caddy /etc/traefik /etc/haproxy /etc/letsencrypt /etc/systemd/system /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/fstab /etc/sysctl.d /etc/fuse.conf; do
  [[ -e "\$p" ]] && existing+=("\$p")
done

if (( \${#existing[@]} > 0 )); then
  tar --zstd -cf "$AUTO_DRIVE_HOME/.backups/etc-system-and-proxy.tar.zst" \\
    --warning=no-file-changed --warning=no-file-removed --warning=no-file-ignored \\
    "\${existing[@]}" || { rc=\$?; (( rc == 1 )) || exit "\$rc"; }
  chown $AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP "$AUTO_DRIVE_HOME/.backups/etc-system-and-proxy.tar.zst"
  chmod 0600 "$AUTO_DRIVE_HOME/.backups/etc-system-and-proxy.tar.zst"
fi
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-stage-etc

# Main snapshot builder + 7-daily / 4-weekly / 6-monthly GFS retention pruner
sudo tee /usr/local/libexec/auto-drive-snapshot >/dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail

HOST_TAG="\$(hostname -s)"
SNAP_DIR="$DRIVE_MOUNT/encrypted/snapshots/\$HOST_TAG"
STAMP="\$(date -u +%Y-%m-%d_%H%M%S)"
TMP_ARCHIVE="$AUTO_DRIVE_CACHE_DIR/.snap-\${STAMP}.tar.zst"
FINAL_ARCHIVE="\$SNAP_DIR/\${STAMP}.tar.zst"

if ! mountpoint -q "$DRIVE_MOUNT/encrypted"; then
  echo "ERROR: $DRIVE_MOUNT/encrypted is not mounted; aborting snapshot." >&2
  exit 1
fi

mkdir -p "\$SNAP_DIR" "$AUTO_DRIVE_CACHE_DIR"
trap 'rm -f "\$TMP_ARCHIVE"' EXIT

# Build compressed archive on fast local SSD first, excluding ~/DRIVE and ephemeral caches
tar --zstd -cf "\$TMP_ARCHIVE" \\
  --warning=no-file-changed --warning=no-file-removed --warning=no-file-ignored \\
  --one-file-system \\
  --exclude="$DRIVE_MOUNT" \\
  --exclude="$AUTO_DRIVE_HOME/.cache" \\
  --exclude="$AUTO_DRIVE_HOME/.duckdb" \\
  --exclude="$AUTO_DRIVE_HOME/.npm" \\
  --exclude="$AUTO_DRIVE_HOME/.bun/install/cache" \\
  --exclude='*.sock' \\
  --exclude='**/node_modules' \\
  --exclude='**/target/debug' \\
  --exclude='**/target/release' \\
  -C "$(dirname "$AUTO_DRIVE_HOME")" "$(basename "$AUTO_DRIVE_HOME")" \\
  || { rc=\$?; (( rc == 1 )) || exit "\$rc"; }

mv -f "\$TMP_ARCHIVE" "\$FINAL_ARCHIVE"
trap - EXIT

# Prune expired snapshots: keep 7 daily + 4 weekly + 6 monthly
python3 - "\$SNAP_DIR" << 'PY'
import datetime, os, re, sys

snap_dir = sys.argv[1]
pat = re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{6})\.tar\.zst$")
items = []
for name in os.listdir(snap_dir):
    m = pat.match(name)
    if m:
        dt = datetime.datetime.strptime(m.group(1) + m.group(2), "%Y-%m-%d%H%M%S")
        items.append((dt, os.path.join(snap_dir, name)))

items.sort(reverse=True)  # newest first
keep = set()
days, weeks, months = set(), set(), set()

for dt, path in items:
    d_key = dt.strftime("%Y-%m-%d")
    w_key = f"{dt.isocalendar()[0]}-W{dt.isocalendar()[1]:02d}"
    m_key = dt.strftime("%Y-%m")
    if len(days) < 7 and d_key not in days:
        days.add(d_key); keep.add(path)
    if len(weeks) < 4 and w_key not in weeks:
        weeks.add(w_key); keep.add(path)
    if len(months) < 6 and m_key not in months:
        months.add(m_key); keep.add(path)

for dt, path in items:
    if path not in keep:
        os.remove(path)
PY

echo "Snapshot saved: \$FINAL_ARCHIVE"
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-snapshot

sudo tee /etc/systemd/system/auto-drive-snapshot.service >/dev/null << EOF
[Unit]
Description=AUTO-DRIVE Daily Encrypted System Snapshot
Requires=auto-drive-crypt.service
After=network-online.target auto-drive-crypt.service
Wants=network-online.target

[Service]
Type=oneshot
User=$AUTO_DRIVE_USER
Group=$AUTO_DRIVE_GROUP
Nice=19
IOSchedulingClass=idle
MemoryMax=768M
ExecStartPre=+/usr/local/libexec/auto-drive-stage-etc
ExecStart=/usr/bin/flock -n /tmp/auto-drive-snapshot.lock /usr/local/libexec/auto-drive-snapshot
EOF

sudo tee /etc/systemd/system/auto-drive-snapshot.timer >/dev/null << 'EOF'
[Unit]
Description=AUTO-DRIVE Daily 03:30 UTC Snapshot Timer

[Timer]
OnCalendar=*-*-* 03:30:00 UTC
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Clean up legacy Kopia timer if present
if systemctl list-unit-files | grep -q '^kopia-backup\.timer'; then
  sudo systemctl disable --now kopia-backup.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/kopia-backup.timer /etc/systemd/system/kopia-backup.service /usr/local/libexec/kopia-stage-etc.sh
fi

sudo systemctl daemon-reload
sudo systemctl enable --now auto-drive-snapshot.timer
log_ok "Daily 03:30 UTC snapshot timer enabled (-> $DRIVE_MOUNT/encrypted/snapshots/)"
