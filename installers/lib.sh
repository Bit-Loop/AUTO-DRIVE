#!/usr/bin/env bash
# Shared configuration & helper functions for AUTO-DRIVE

set -euo pipefail

export AUTO_DRIVE_USER="${AUTO_DRIVE_USER:-$(id -un)}"
export AUTO_DRIVE_GROUP="${AUTO_DRIVE_GROUP:-$(id -gn)}"
export AUTO_DRIVE_HOME="${AUTO_DRIVE_HOME:-$(getent passwd "$AUTO_DRIVE_USER" | cut -d: -f6)}"

export DRIVE_MOUNT="${DRIVE_MOUNT:-$AUTO_DRIVE_HOME/DRIVE}"
export GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
export GDRIVE_CRYPT_REMOTE="${GDRIVE_CRYPT_REMOTE:-gdrive-crypt}"
export GDRIVE_DRIVE_PATH="${GDRIVE_DRIVE_PATH:-DRIVE}"

export AUTO_DRIVE_CONFIG_DIR="${AUTO_DRIVE_CONFIG_DIR:-$AUTO_DRIVE_HOME/.config/auto-drive}"
export RCLONE_CONF="${RCLONE_CONF:-$AUTO_DRIVE_CONFIG_DIR/rclone.conf}"
export AUTO_DRIVE_CACHE_DIR="${AUTO_DRIVE_CACHE_DIR:-$AUTO_DRIVE_HOME/.cache/auto-drive}"
export RC_PLAIN_SOCK="$AUTO_DRIVE_CONFIG_DIR/rc-plain.sock"
export RC_CRYPT_SOCK="$AUTO_DRIVE_CONFIG_DIR/rc-crypt.sock"

log_info()  { printf '\033[1;34m[AUTO-DRIVE]\033[0m %s\n' "$*"; }
log_ok()    { printf '\033[1;32m[   OK    ]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[  WARN   ]\033[0m %s\n' "$*" >&2; }
log_err()   { printf '\033[1;31m[  ERROR  ]\033[0m %s\n' "$*" >&2; }

# Derive deterministic 256-bit rclone crypt key + salt from a single user password
# using 600,000-iteration PBKDF2-HMAC-SHA256 (reads password from stdin, prints 2 lines).
derive_crypt_keys() {
  python3 -c '
import hashlib, sys
pw = sys.stdin.buffer.read()
k1 = hashlib.pbkdf2_hmac("sha256", pw, b"AUTO-DRIVE:v1:crypt-password", 600_000, dklen=32).hex()
k2 = hashlib.pbkdf2_hmac("sha256", pw, b"AUTO-DRIVE:v1:crypt-salt", 600_000, dklen=32).hex()
sys.stdout.write(f"{k1}\n{k2}\n")
'
}

# Compute iCloud-style dynamic cache ceiling & min-free-space floor:
# - Total cache cap = max(2 GiB, 20% of local non-cache free storage), split across plain & crypt
# - Min free OS space = max(2 GiB, 20% of total local disk) -> rclone pops cached files as free disk shrinks
calc_cache_limits() {
  mkdir -p "$AUTO_DRIVE_CACHE_DIR/plain" "$AUTO_DRIVE_CACHE_DIR/crypt"
  local two_gib=$((2 * 1024 * 1024 * 1024))
  local one_gib=$((1024 * 1024 * 1024))

  local total_bytes avail_bytes cache_bytes true_free_bytes
  total_bytes=$(df -B1 --output=size "$AUTO_DRIVE_CACHE_DIR" | tail -n1 | tr -d ' ')
  avail_bytes=$(df -B1 --output=avail "$AUTO_DRIVE_CACHE_DIR" | tail -n1 | tr -d ' ')
  cache_bytes=$(du -sb "$AUTO_DRIVE_CACHE_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
  true_free_bytes=$(( avail_bytes + cache_bytes ))

  local total_cache_cap=$(( true_free_bytes * 20 / 100 ))
  if (( total_cache_cap < two_gib )); then
    total_cache_cap=$two_gib
  fi
  local per_mount_cap=$(( total_cache_cap / 2 ))
  if (( per_mount_cap < one_gib )); then
    per_mount_cap=$one_gib
  fi

  local min_free_floor=$(( total_bytes * 20 / 100 ))
  if (( min_free_floor < two_gib )); then
    min_free_floor=$two_gib
  fi

  # Convert bytes to whole MiB with 'M' suffix for rclone SizeSuffix
  local per_mount_mib=$(( per_mount_cap / 1048576 ))
  local total_cap_mib=$(( total_cache_cap / 1048576 ))
  local min_free_mib=$(( min_free_floor / 1048576 ))

  printf 'PER_MOUNT_MAX_SIZE=%dM\nTOTAL_CACHE_MAX_SIZE=%dM\nMIN_FREE_SPACE=%dM\nMIN_FREE_BYTES=%d\n' \
    "$per_mount_mib" "$total_cap_mib" "$min_free_mib" "$min_free_floor"
}
