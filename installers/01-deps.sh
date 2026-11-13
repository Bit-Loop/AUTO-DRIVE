#!/usr/bin/env bash
# Module 01: Install required system packages & tools (rclone, duckdb, litestream)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ARCH="$(dpkg --print-architecture)" # amd64 or arm64

log_info "Checking base packages (fuse3, zstd, jq, curl, unzip, python3)..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fuse3 zstd jq curl unzip python3 ca-certificates >/dev/null

# 1. rclone (require >= 1.67 for --vfs-read-chunk-streams & --vfs-cache-min-free-space)
NEED_RCLONE=1
if command -v rclone >/dev/null 2>&1; then
  if rclone mount --help 2>&1 | grep -q 'vfs-cache-min-free-space'; then
    NEED_RCLONE=0
  fi
fi
if (( NEED_RCLONE == 1 )); then
  log_info "Installing latest official rclone (${ARCH})..."
  curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${ARCH}.deb" -o /tmp/rclone.deb
  sudo dpkg -i /tmp/rclone.deb >/dev/null
  rm -f /tmp/rclone.deb
fi
log_ok "rclone ready: $(rclone version | head -n1)"

# 2. DuckDB CLI + tmux/headless dark-mode wrapper
if [[ ! -x /usr/local/bin/duckdb ]]; then
  log_info "Installing DuckDB CLI..."
  sudo -H -u "$AUTO_DRIVE_USER" sh -c 'curl -fsSL https://install.duckdb.org | sh'
  sudo install -m 0755 "$AUTO_DRIVE_HOME/.duckdb/cli/latest/duckdb" /usr/local/bin/duckdb
fi

install -d -m 0755 -o "$AUTO_DRIVE_USER" -g "$AUTO_DRIVE_GROUP" "$AUTO_DRIVE_HOME/.local/bin"
rm -f "$AUTO_DRIVE_HOME/.local/bin/duckdb"
cat > "$AUTO_DRIVE_HOME/.local/bin/duckdb" << 'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in -dark-mode|-light-mode) exec /usr/local/bin/duckdb "$@" ;; esac
done
exec /usr/local/bin/duckdb -dark-mode "$@"
EOF
chown "$AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP" "$AUTO_DRIVE_HOME/.local/bin/duckdb"
chmod 0755 "$AUTO_DRIVE_HOME/.local/bin/duckdb"
log_ok "DuckDB ready: $("$AUTO_DRIVE_HOME/.local/bin/duckdb" --version)"

# 3. Litestream (SQLite continuous WAL replication)
if ! command -v litestream >/dev/null 2>&1; then
  log_info "Installing Litestream (${ARCH})..."
  LITESTREAM_URL=$(curl -fsSL https://api.github.com/repos/benbjohnson/litestream/releases/latest 2>/dev/null \
    | jq -r --arg arch "$ARCH" '.assets[].browser_download_url | select(test("linux-" + (if $arch == "amd64" then "(amd64|x86_64)" else "(arm64|aarch64)" end) + "\\.deb$"))' \
    | head -n1 || true)
  if [[ -n "$LITESTREAM_URL" ]]; then
    curl -fsSL "$LITESTREAM_URL" -o /tmp/litestream.deb
    sudo DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/litestream.deb >/dev/null
    rm -f /tmp/litestream.deb
  else
    log_warn "Could not resolve Litestream release URL (GitHub API rate limit?); skipping optional Litestream install."
  fi
fi
if command -v litestream >/dev/null 2>&1; then
  log_ok "Litestream ready: $(litestream version)"
fi
