#!/usr/bin/env bash
# Module 06: Cheap periodic local file index + RAM dir-cache warmer (Spotlight-like <5ms search)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

sudo mkdir -p /usr/local/libexec

sudo tee /usr/local/libexec/auto-drive-index >/dev/null << EOF
#!/usr/bin/env bash
set -euo pipefail
FORCE_REMOTE="\${1:-0}"

DRIVE_MOUNT="$DRIVE_MOUNT"
INDEX_FILE="$AUTO_DRIVE_CACHE_DIR/index.tsv"
TMP_INDEX="$AUTO_DRIVE_CACHE_DIR/.index.tsv.\$\$"

# Only index when both root and encrypted mounts are online so we never write a partial index
if ! mountpoint -q "\$DRIVE_MOUNT" || ! mountpoint -q "\$DRIVE_MOUNT/encrypted"; then
  exit 0
fi

umask 077
mkdir -p "$AUTO_DRIVE_CACHE_DIR"
chmod 0700 "$AUTO_DRIVE_CACHE_DIR"
trap 'rm -f "\$TMP_INDEX"' EXIT

if [[ "\$FORCE_REMOTE" == "1" ]]; then
  if [[ -S "$RC_PLAIN_SOCK" ]]; then
    rclone rc --unix-socket="$RC_PLAIN_SOCK" vfs/refresh dir=store dir2=installers recursive=true >/dev/null 2>&1 || true
  fi
  if [[ -S "$RC_CRYPT_SOCK" ]]; then
    rclone rc --unix-socket="$RC_CRYPT_SOCK" vfs/refresh recursive=true >/dev/null 2>&1 || true
  fi
fi

# Walk metadata only (readdir + lstat). Because rclone holds --dir-cache-time=9999h fed by Google's
# 20s changes.list delta poller, unchanged folders cost 0 API calls, while any folder invalidated by
# a remote web/mobile upload gets automatically re-warmed into RAM here before you interactively cd into it!
find "\$DRIVE_MOUNT" -mindepth 1 -printf '%P\t%y\t%s\t%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null \\
  | LC_ALL=C sort > "\$TMP_INDEX"

chmod 0600 "\$TMP_INDEX"
mv -f "\$TMP_INDEX" "\$INDEX_FILE"
trap - EXIT
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-index

sudo tee /etc/systemd/system/auto-drive-index.service >/dev/null << EOF
[Unit]
Description=AUTO-DRIVE Periodic Local File Indexer & Dir-Cache Warmer
After=auto-drive-crypt.service
Requires=auto-drive-crypt.service

[Service]
Type=oneshot
User=$AUTO_DRIVE_USER
Group=$AUTO_DRIVE_GROUP
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/flock -n /tmp/auto-drive-index.lock /usr/local/libexec/auto-drive-index 0
EOF

sudo tee /etc/systemd/system/auto-drive-index.timer >/dev/null << 'EOF'
[Unit]
Description=Refresh AUTO-DRIVE Local File Index every 5 minutes

[Timer]
OnBootSec=45s
OnUnitActiveSec=5m

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now auto-drive-index.timer
sudo -u "$AUTO_DRIVE_USER" /usr/local/libexec/auto-drive-index 0 || true
log_ok "Periodic 5m file indexer enabled (-> $AUTO_DRIVE_CACHE_DIR/index.tsv)"
