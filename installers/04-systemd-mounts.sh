#!/usr/bin/env bash
# Module 04: Systemd auto-mounts (~/DRIVE + ~/DRIVE/encrypted) & dynamic free-space watchdog

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

sudo mkdir -p /usr/local/libexec

# 1. Dynamic rclone mount launcher (computes 20% free-space cap & 20%/2GiB min-free-space floor)
sudo tee /usr/local/libexec/auto-drive-mount >/dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail
MODE="\${1:?Usage: auto-drive-mount plain|crypt}"

AUTO_DRIVE_CACHE_DIR="$AUTO_DRIVE_CACHE_DIR"
RCLONE_CONF="$RCLONE_CONF"
DRIVE_MOUNT="$DRIVE_MOUNT"
GDRIVE_REMOTE="$GDRIVE_REMOTE"
GDRIVE_CRYPT_REMOTE="$GDRIVE_CRYPT_REMOTE"
GDRIVE_DRIVE_PATH="$GDRIVE_DRIVE_PATH"

mkdir -p "\$AUTO_DRIVE_CACHE_DIR/plain" "\$AUTO_DRIVE_CACHE_DIR/crypt"

TWO_GIB=\$((2 * 1024 * 1024 * 1024))
ONE_GIB=\$((1024 * 1024 * 1024))
TOTAL_BYTES=\$(df -B1 --output=size "\$AUTO_DRIVE_CACHE_DIR" | tail -n1 | tr -d ' ')
AVAIL_BYTES=\$(df -B1 --output=avail "\$AUTO_DRIVE_CACHE_DIR" | tail -n1 | tr -d ' ')
CACHE_BYTES=\$(du -sb "\$AUTO_DRIVE_CACHE_DIR" 2>/dev/null | awk '{print \$1}' || echo 0)
TRUE_FREE=\$(( AVAIL_BYTES + CACHE_BYTES ))

TOTAL_CAP=\$(( TRUE_FREE * 20 / 100 ))
(( TOTAL_CAP < TWO_GIB )) && TOTAL_CAP=\$TWO_GIB
PER_MOUNT_CAP=\$(( TOTAL_CAP / 2 ))
(( PER_MOUNT_CAP < ONE_GIB )) && PER_MOUNT_CAP=\$ONE_GIB

MIN_FREE=\$(( TOTAL_BYTES * 20 / 100 ))
(( MIN_FREE < TWO_GIB )) && MIN_FREE=\$TWO_GIB

MAX_SIZE_FLAG="\$(( PER_MOUNT_CAP / 1048576 ))M"
MIN_FREE_FLAG="\$(( MIN_FREE / 1048576 ))M"

COMMON_FLAGS=(
  --config="\$RCLONE_CONF"
  --vfs-cache-mode=full
  --vfs-fast-fingerprint
  --vfs-cache-max-size="\$MAX_SIZE_FLAG"
  --vfs-cache-min-free-space="\$MIN_FREE_FLAG"
  --vfs-cache-max-age=5m
  --vfs-cache-poll-interval=20s
  --vfs-read-chunk-size=16M
  --vfs-read-chunk-size-limit=128M
  --vfs-read-chunk-streams=4
  --buffer-size=0
  --use-mmap
  --drive-chunk-size=32M
  --drive-pacer-min-sleep=10ms
  --drive-pacer-burst=200
  --transfers=2
  --dir-cache-time=9999h
  --poll-interval=20s
  --bwlimit=8.5M:off
  --rc
  --rc-no-auth
  --allow-other
  --allow-non-empty
)

if [[ "\$MODE" == "plain" ]]; then
  rm -f "$RC_PLAIN_SOCK"
  mkdir -p "\$DRIVE_MOUNT"
  exec /usr/bin/rclone mount "\${GDRIVE_REMOTE}:\${GDRIVE_DRIVE_PATH}" "\$DRIVE_MOUNT" \\
    "\${COMMON_FLAGS[@]}" \\
    --file-perms=0755 \\
    --cache-dir="\$AUTO_DRIVE_CACHE_DIR/plain" \\
    --vfs-write-back=30s \\
    --rc-addr="unix://$RC_PLAIN_SOCK"
elif [[ "\$MODE" == "crypt" ]]; then
  rm -f "$RC_CRYPT_SOCK"
  mkdir -p "\$DRIVE_MOUNT/encrypted"
  exec /usr/bin/rclone mount "\${GDRIVE_CRYPT_REMOTE}:" "\$DRIVE_MOUNT/encrypted" \\
    "\${COMMON_FLAGS[@]}" \\
    --cache-dir="\$AUTO_DRIVE_CACHE_DIR/crypt" \\
    --vfs-write-back=1m \\
    --rc-addr="unix://$RC_CRYPT_SOCK"
else
  echo "Unknown mode: \$MODE" >&2
  exit 2
fi
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-mount

# 2. Live cache resize / disk-pressure pop helper (updates VFS CacheMaxSize dynamically as free space changes)
sudo tee /usr/local/libexec/auto-drive-rebalance >/dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail
FORCE_POP="\${1:-0}"
AUTO_DRIVE_CACHE_DIR="$AUTO_DRIVE_CACHE_DIR"
TWO_GIB=\$((2 * 1024 * 1024 * 1024))
ONE_GIB=\$((1024 * 1024 * 1024))

AVAIL_BYTES=\$(df -B1 --output=avail "\$AUTO_DRIVE_CACHE_DIR" | tail -n1 | tr -d ' ')
CACHE_BYTES=\$(du -sb "\$AUTO_DRIVE_CACHE_DIR" 2>/dev/null | awk '{print \$1}' || echo 0)
TRUE_FREE=\$(( AVAIL_BYTES + CACHE_BYTES ))

TOTAL_CAP=\$(( TRUE_FREE * 20 / 100 ))
(( TOTAL_CAP < TWO_GIB )) && TOTAL_CAP=\$TWO_GIB
PER_MOUNT_CAP=\$(( TOTAL_CAP / 2 ))
(( PER_MOUNT_CAP < ONE_GIB )) && PER_MOUNT_CAP=\$ONE_GIB

if [[ "\$FORCE_POP" == "1" ]]; then
  # Temporarily squeeze CacheMaxSize to 64 MiB so rclone pops all unlocked clean cached files immediately,
  # then restore the 20% budget!
  for sock in "$RC_PLAIN_SOCK" "$RC_CRYPT_SOCK"; do
    if [[ -S "\$sock" ]]; then
      rclone rc --unix-socket="\$sock" options/set --json '{"vfs":{"CacheMaxSize":67108864}}' >/dev/null 2>&1 || true
    fi
  done
  sleep 2
fi

for sock in "$RC_PLAIN_SOCK" "$RC_CRYPT_SOCK"; do
  if [[ -S "\$sock" ]]; then
    rclone rc --unix-socket="\$sock" options/set --json "{\"vfs\":{\"CacheMaxSize\":\$PER_MOUNT_CAP}}" >/dev/null 2>&1 || true
  fi
done
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-rebalance

# 3. Root plain DRIVE mount unit (~/DRIVE -> gdrive:DRIVE)
sudo tee /etc/systemd/system/auto-drive-root.service >/dev/null << EOF
[Unit]
Description=AUTO-DRIVE Root Mount ($DRIVE_MOUNT -> ${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH})
After=network-online.target
Wants=network-online.target auto-drive-crypt.service

[Service]
Type=notify
User=$AUTO_DRIVE_USER
Group=$AUTO_DRIVE_GROUP
Environment=GOMEMLIMIT=256MiB
OOMScoreAdjust=-500
ExecStart=/usr/local/libexec/auto-drive-mount plain
ExecStartPost=-/usr/bin/rclone rc --unix-socket=$RC_PLAIN_SOCK vfs/refresh dir=store dir2=installers recursive=true _async=true
ExecStop=/bin/fusermount3 -uz $DRIVE_MOUNT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 4. Encrypted sub-mount unit (~/DRIVE/encrypted -> gdrive-crypt:)
sudo tee /etc/systemd/system/auto-drive-crypt.service >/dev/null << EOF
[Unit]
Description=AUTO-DRIVE Encrypted Sub-Mount ($DRIVE_MOUNT/encrypted)
Requires=auto-drive-root.service
BindsTo=auto-drive-root.service
After=auto-drive-root.service

[Service]
Type=notify
User=$AUTO_DRIVE_USER
Group=$AUTO_DRIVE_GROUP
Environment=GOMEMLIMIT=256MiB
OOMScoreAdjust=-500
ExecStartPre=/bin/sleep 1
ExecStart=/usr/local/libexec/auto-drive-mount crypt
ExecStartPost=-/usr/bin/rclone rc --unix-socket=$RC_CRYPT_SOCK vfs/refresh recursive=true _async=true
ExecStop=/bin/fusermount3 -uz $DRIVE_MOUNT/encrypted
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 5. Periodic free-space rebalance watchdog timer (adapts cache cap every 2m as OS disk usage fluctuates)
sudo tee /etc/systemd/system/auto-drive-watchdog.service >/dev/null << EOF
[Unit]
Description=AUTO-DRIVE Dynamic Free-Space Cache Rebalancer

[Service]
Type=oneshot
User=$AUTO_DRIVE_USER
Group=$AUTO_DRIVE_GROUP
ExecStart=/usr/local/libexec/auto-drive-rebalance 0
EOF

sudo tee /etc/systemd/system/auto-drive-watchdog.timer >/dev/null << 'EOF'
[Unit]
Description=Run AUTO-DRIVE Dynamic Cache Rebalancer every 2 minutes

[Timer]
OnBootSec=2m
OnUnitActiveSec=2m

[Install]
WantedBy=timers.target
EOF

# Stop any existing mounts cleanly before starting/restarting the layered mounts
sudo systemctl stop auto-drive-crypt.service auto-drive-root.service 2>/dev/null || true
if systemctl list-unit-files | grep -q '^rclone-drive\.service'; then
  sudo systemctl disable --now rclone-drive.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/rclone-drive.service
fi
sudo umount -lf "$DRIVE_MOUNT/encrypted" 2>/dev/null || true
sudo umount -lf "$DRIVE_MOUNT" 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable --now auto-drive-root.service
sudo systemctl enable --now auto-drive-crypt.service
sudo systemctl enable --now auto-drive-watchdog.timer

# Create standard subdirectories inside ~/DRIVE and ~/DRIVE/encrypted
sudo -u "$AUTO_DRIVE_USER" mkdir -p \
  "$DRIVE_MOUNT/store" \
  "$DRIVE_MOUNT/installers" \
  "$DRIVE_MOUNT/encrypted/data/archives" \
  "$DRIVE_MOUNT/encrypted/data/pcaps" \
  "$DRIVE_MOUNT/encrypted/data/recon" \
  "$DRIVE_MOUNT/encrypted/data/sqlite-backups" \
  "$DRIVE_MOUNT/encrypted/data/wordlists" \
  "$DRIVE_MOUNT/encrypted/snapshots"

log_ok "Mounted $DRIVE_MOUNT (plain) and $DRIVE_MOUNT/encrypted (PBKDF2 crypt) + enabled at boot"
