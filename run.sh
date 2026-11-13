#!/usr/bin/env bash
# AUTO-DRIVE — iCloud-style Linux Google Drive Mount + Encrypted Vault & Snapshots
# Usage: ./run.sh [setup | status | backup | evict | passwd | mount | unmount | sync | help]

set -euo pipefail

# If running unmount/passwd from inside ~/DRIVE itself, re-exec from /tmp so FUSE isn't held busy
CMD="${1:-status}"
REAL_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REAL_DIR="$(dirname "$REAL_SELF")"

if [[ "$CMD" =~ ^(unmount|passwd|setup)$ ]] && [[ -z "${AUTO_DRIVE_REEXEC:-}" ]]; then
  DEFAULT_MNT="${DRIVE_MOUNT:-$HOME/DRIVE}"
  if [[ "$REAL_DIR" == "$DEFAULT_MNT"* || "$PWD" == "$DEFAULT_MNT"* ]]; then
    TMP_BUNDLE="$(mktemp -d /tmp/auto-drive-exec.XXXXXX)"
    cp -a "$REAL_DIR/run.sh" "$REAL_DIR/installers" "$TMP_BUNDLE/"
    [[ -f "$REAL_DIR/README.md" ]] && cp -a "$REAL_DIR/README.md" "$TMP_BUNDLE/"
    cd "$HOME"
    AUTO_DRIVE_REEXEC=1 "$TMP_BUNDLE/run.sh" "$@"
    rc=$?
    rm -rf "$TMP_BUNDLE"
    exit "$rc"
  fi
fi

# shellcheck source=installers/lib.sh
source "$REAL_DIR/installers/lib.sh"

cmd_setup() {
  bash "$REAL_DIR/installers/01-deps.sh"
  bash "$REAL_DIR/installers/02-system-tuning.sh"
  bash "$REAL_DIR/installers/03-auth-and-crypt.sh"
  bash "$REAL_DIR/installers/04-systemd-mounts.sh"
  bash "$REAL_DIR/installers/05-daily-snapshots.sh"
  cmd_sync

  install -d -m 0755 "$AUTO_DRIVE_HOME/.local/bin"
  cat > "$AUTO_DRIVE_HOME/.local/bin/drive-status" << EOF
#!/usr/bin/env bash
exec /usr/bin/env bash "$DRIVE_MOUNT/run.sh" status "\$@"
EOF
  chmod 0755 "$AUTO_DRIVE_HOME/.local/bin/drive-status"
  log_ok "AUTO-DRIVE setup complete! Run './run.sh passwd' anytime to change your vault password."
}

cmd_sync() {
  if ! mountpoint -q "$DRIVE_MOUNT"; then
    log_warn "$DRIVE_MOUNT is not mounted; skipping toolkit sync."
    return 0
  fi
  if [[ "$REAL_DIR" == "$DRIVE_MOUNT" ]]; then
    return 0
  fi
  mkdir -p "$DRIVE_MOUNT/installers"
  install -m 0755 "$REAL_DIR/run.sh" "$DRIVE_MOUNT/run.sh"
  [[ -f "$REAL_DIR/README.md" ]] && install -m 0644 "$REAL_DIR/README.md" "$DRIVE_MOUNT/README.md"
  install -m 0755 "$REAL_DIR/installers/"*.sh "$DRIVE_MOUNT/installers/"
  log_ok "Synced README.md, run.sh, and installers/ -> $DRIVE_MOUNT/"
}

cmd_status() {
  eval "$(calc_cache_limits)"
  echo "=== 1. AUTO-DRIVE Mounts ($DRIVE_MOUNT) ==="
  printf "Root  (plain) : %s\n" "$(systemctl is-active auto-drive-root.service 2>/dev/null || echo inactive)"
  printf "Crypt (vault) : %s\n" "$(systemctl is-active auto-drive-crypt.service 2>/dev/null || echo inactive)"
  df -h "$DRIVE_MOUNT" "$DRIVE_MOUNT/encrypted" 2>/dev/null | awk 'NR==1 || !seen[$0]++' || true

  echo ""
  echo "=== 2. iCloud-Style Dynamic Local Cache (Cap: $TOTAL_CACHE_MAX_SIZE | Min Free Floor: $MIN_FREE_SPACE) ==="
  for label_sock in "Plain (store/)  :$RC_PLAIN_SOCK" "Crypt (encrypted):$RC_CRYPT_SOCK"; do
    label="${label_sock%%:*}"
    sock="${label_sock#*:}"
    if [[ -S "$sock" ]]; then
      rclone rc --unix-socket="$sock" vfs/stats 2>/dev/null \
        | jq -r --arg lbl "$label" '"\($lbl) -> Cached: \((.diskCache.bytesUsed / 1048576 | floor)) MiB (\(.diskCache.files) files) | Uploading: \(.diskCache.uploadsInProgress) (queued: \(.diskCache.uploadsQueued))"' \
        || echo "$label -> stats unavailable"
    else
      echo "$label -> socket offline"
    fi
  done

  echo ""
  echo "=== 3. Encrypted Daily Snapshots ($DRIVE_MOUNT/encrypted/snapshots) ==="
  systemctl list-timers auto-drive-snapshot.timer --no-pager 2>/dev/null | head -n 3 || true
  if [[ -d "$DRIVE_MOUNT/encrypted/snapshots" ]]; then
    find "$DRIVE_MOUNT/encrypted/snapshots" -maxdepth 2 -name '*.tar.zst' -printf '%TY-%Tm-%Td %TH:%TM  %k KiB  %P\n' 2>/dev/null | sort | tail -n 5 || true
  fi

  echo ""
  echo "=== 4. Local Disk, RAM & Swap ==="
  df -h "$AUTO_DRIVE_HOME" | awk 'NR==2 {printf "Local Disk Free : %s available of %s (%s used)\n", $4, $2, $5}'
  free -h | awk 'NR<=3'
}

cmd_backup() {
  log_info "Running encrypted snapshot into $DRIVE_MOUNT/encrypted/snapshots/$(hostname -s)/ ..."
  sudo systemctl start auto-drive-snapshot.service
  ls -lh "$DRIVE_MOUNT/encrypted/snapshots/$(hostname -s)/" | tail -n 5
  log_ok "Snapshot complete (uploads asynchronously via encrypted VFS cache)."
}

cmd_evict() {
  log_info "Popping unlocked clean cached files from local SSD..."
  sudo /usr/local/libexec/auto-drive-rebalance 1
  log_ok "Local cache evicted; remote files remain visible in $DRIVE_MOUNT."
  cmd_status
}

cmd_mount() {
  sudo systemctl start auto-drive-root.service auto-drive-crypt.service
  log_ok "Mounted $DRIVE_MOUNT and $DRIVE_MOUNT/encrypted"
}

cmd_unmount() {
  sudo systemctl stop auto-drive-crypt.service auto-drive-root.service
  log_ok "Unmounted $DRIVE_MOUNT"
}

cmd_passwd() {
  if ! mountpoint -q "$DRIVE_MOUNT/encrypted"; then
    log_err "$DRIVE_MOUNT/encrypted must be mounted before rotating password."
    exit 1
  fi

  local new_pass confirm_pass
  if [[ -n "${AUTO_DRIVE_NEW_PASS:-}" ]]; then
    new_pass="$AUTO_DRIVE_NEW_PASS"
  else
    while true; do
      read -rsp "Enter NEW vault password for DRIVE/encrypted: " new_pass </dev/tty
      echo >/dev/tty
      [[ -n "$new_pass" ]] || { log_warn "Password cannot be empty."; continue; }
      read -rsp "Confirm NEW vault password: " confirm_pass </dev/tty
      echo >/dev/tty
      [[ "$new_pass" == "$confirm_pass" ]] && break
      log_warn "Passwords did not match. Try again."
    done
  fi

  umask 077
  STAGE_DIR="$(mktemp -d "$AUTO_DRIVE_CACHE_DIR/.rekey-stage.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT

  log_info "Staging decrypted contents of $DRIVE_MOUNT/encrypted locally..."
  cp -r --preserve=timestamps "$DRIVE_MOUNT/encrypted/." "$STAGE_DIR/"

  log_info "Stopping encrypted sub-mount and rotating PBKDF2-SHA256 keys..."
  sudo systemctl stop auto-drive-crypt.service
  rm -rf "$AUTO_DRIVE_CACHE_DIR/crypt"

  rclone --config="$RCLONE_CONF" delete "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted" 2>/dev/null || true
  rclone --config="$RCLONE_CONF" rmdirs "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted" --leave-root 2>/dev/null || true
  mkdir -p "$DRIVE_MOUNT/encrypted"

  mapfile -t KEYS < <(printf '%s' "$new_pass" | derive_crypt_keys)
  unset new_pass confirm_pass

  rclone --config="$RCLONE_CONF" config delete "$GDRIVE_CRYPT_REMOTE" 2>/dev/null || true
  rclone --config="$RCLONE_CONF" config create "$GDRIVE_CRYPT_REMOTE" crypt \
    remote "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted" \
    filename_encryption "standard" \
    directory_name_encryption "true" \
    password "${KEYS[0]}" \
    password2 "${KEYS[1]}" >/dev/null
  unset KEYS
  chmod 0600 "$RCLONE_CONF"

  log_info "Remounting $DRIVE_MOUNT/encrypted with new key and restoring data..."
  sudo systemctl start auto-drive-crypt.service
  for _ in {1..15}; do mountpoint -q "$DRIVE_MOUNT/encrypted" && break; sleep 1; done
  mountpoint -q "$DRIVE_MOUNT/encrypted" || { log_err "Encrypted mount failed to come up; staged files preserved at $STAGE_DIR"; trap - EXIT; exit 1; }
  cp -r --preserve=timestamps "$STAGE_DIR/." "$DRIVE_MOUNT/encrypted/"
  rm -rf "$STAGE_DIR"
  trap - EXIT

  log_ok "Vault password rotated! All files in DRIVE/encrypted are re-encrypting under your new password."
}

case "$CMD" in
  setup)   cmd_setup ;;
  status)  cmd_status ;;
  backup)  cmd_backup ;;
  evict)   cmd_evict ;;
  mount)   cmd_mount ;;
  unmount) cmd_unmount ;;
  passwd)  cmd_passwd ;;
  sync)    cmd_sync ;;
  *)
    cat << 'EOF'
Usage: ./run.sh <command>

Commands:
  setup     Install dependencies, link Google Drive, set vault password, enable boot mounts & daily backups
  status    Show mount health, dynamic 20% cache usage, upload queue, snapshots, and RAM/swap
  backup    Trigger an immediate encrypted .tar.zst system snapshot into ~/DRIVE/encrypted/snapshots/
  evict     Immediately pop/evict unlocked cached files locally (remote files still appear local)
  passwd    Set or rotate the single password unlocking ~/DRIVE/encrypted/ (re-keys existing data)
  sync      Copy README.md, run.sh, and installers/ from this repo into ~/DRIVE/
  mount     Start ~/DRIVE and ~/DRIVE/encrypted systemd mounts
  unmount   Stop ~/DRIVE and ~/DRIVE/encrypted systemd mounts
EOF
    ;;
esac
