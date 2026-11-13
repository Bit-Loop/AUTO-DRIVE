#!/usr/bin/env bash
# Module 02: FUSE config, low-RAM swap safeguard, VM cache sysctls, DuckDB & fd/rg guards

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# 1. Cleanly enable user_allow_other in /etc/fuse.conf (exact line match only)
sudo sed -i 's/^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$/user_allow_other/' /etc/fuse.conf
if ! grep -Eq '^[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf; then
  echo 'user_allow_other' | sudo tee -a /etc/fuse.conf >/dev/null
fi
log_ok "/etc/fuse.conf configured (user_allow_other enabled)"

# 2. Add 4 GiB persistent swapfile if system has 0 swap and < 8 GiB RAM
MEM_TOTAL_KIB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
SWAP_TOTAL_KIB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
if (( SWAP_TOTAL_KIB == 0 && MEM_TOTAL_KIB < 8388608 )); then
  if [[ ! -f /swapfile ]]; then
    log_info "Low-RAM system with 0 swap detected; creating 4 GiB /swapfile..."
    sudo fallocate -l 4G /swapfile
    sudo chmod 0600 /swapfile
    sudo mkswap /swapfile >/dev/null
  fi
  sudo swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  log_ok "4 GiB /swapfile active"
fi

# 3. Kernel VM tuning for FUSE dentry responsiveness & gentle swap behavior
sudo tee /etc/sysctl.d/99-auto-drive.conf >/dev/null << 'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sudo sysctl --system >/dev/null
log_ok "Kernel VM sysctls applied (swappiness=10, vfs_cache_pressure=50)"

# 4. DuckDB safe memory cap & local NVMe spill directory
if [[ ! -f "$AUTO_DRIVE_HOME/.duckdbrc" ]]; then
  cat > "$AUTO_DRIVE_HOME/.duckdbrc" << EOF
SET memory_limit = '512MB';
SET temp_directory = '$AUTO_DRIVE_HOME/.cache/duckdb_temp';
SET threads = 2;
EOF
  chown "$AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP" "$AUTO_DRIVE_HOME/.duckdbrc"
fi

# 5. Protect fd (Ctrl-T) and ripgrep from accidentally crawling ~/DRIVE over the network when run in $HOME,
#    while keeping fd/rg working normally when explicitly inside ~/DRIVE!
MOUNT_REL="/$(basename "$DRIVE_MOUNT")/"
touch "$AUTO_DRIVE_HOME/.ignore"
grep -qxF "$MOUNT_REL" "$AUTO_DRIVE_HOME/.ignore" || echo "$MOUNT_REL" >> "$AUTO_DRIVE_HOME/.ignore"
grep -qxF "/.cache/" "$AUTO_DRIVE_HOME/.ignore" || echo "/.cache/" >> "$AUTO_DRIVE_HOME/.ignore"
chown "$AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP" "$AUTO_DRIVE_HOME/.ignore"
log_ok "Shell search guards (~/.ignore) and ~/.duckdbrc configured"
