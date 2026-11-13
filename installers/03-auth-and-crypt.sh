#!/usr/bin/env bash
# Module 03: Headless-friendly Google Drive OAuth + Single-Password PBKDF2 rclone crypt setup

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

umask 077
install -d -m 0700 -o "$AUTO_DRIVE_USER" -g "$AUTO_DRIVE_GROUP" "$AUTO_DRIVE_CONFIG_DIR"
touch "$RCLONE_CONF"
chown "$AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP" "$RCLONE_CONF"
chmod 0600 "$RCLONE_CONF"

has_remote() {
  rclone --config="$RCLONE_CONF" listremotes | grep -qx "${1}:"
}

# 1. Authenticate base Google Drive remote if not yet present
if ! has_remote "$GDRIVE_REMOTE"; then
  log_info "Google Drive remote '${GDRIVE_REMOTE}:' not found. Starting headless OAuth flow..."
  AUTH_LOG="$(mktemp "$AUTO_DRIVE_CONFIG_DIR/auth.XXXXXX")"
  rclone authorize "drive" --auth-no-open-browser >"$AUTH_LOG" 2>&1 &
  AUTH_PID=$!
  trap 'kill "$AUTH_PID" 2>/dev/null || true; rm -f "$AUTH_LOG"' EXIT

  LOCAL_AUTH_URL=""
  for _ in {1..30}; do
    LOCAL_AUTH_URL=$(grep -oE 'http://127\.0\.0\.1:[0-9]+/auth\?[^[:space:]]+' "$AUTH_LOG" || true)
    [[ -n "$LOCAL_AUTH_URL" ]] && break
    sleep 0.2
  done

  if [[ -z "$LOCAL_AUTH_URL" ]]; then
    log_err "Failed to start local rclone OAuth listener (is port 53682 already in use?)."
    exit 1
  fi

  GOOGLE_URL=$(curl -sI "$LOCAL_AUTH_URL" | awk 'tolower($1)=="location:" {sub(/\r$/,"",$2); print $2}')
  printf '\n1) Open this URL in any browser and sign in to Google:\n   %s\n\n' "$GOOGLE_URL"
  printf '2) When redirected to "http://127.0.0.1:53682/?state=..." ("site cannot be reached"),\n'
  read -rp '   copy that full http://127.0.0.1:53682/... URL and paste it here: ' CALLBACK_URL </dev/tty

  curl -fsS "$CALLBACK_URL" >/dev/null
  sleep 1
  TOKEN=$(awk '/Paste the following into your remote machine --->/,/<---End paste/' "$AUTH_LOG" | grep -v -- '---' || true)
  rm -f "$AUTH_LOG"
  trap - EXIT

  if [[ -z "$TOKEN" ]]; then
    log_err "OAuth token exchange failed; please re-run './run.sh setup'."
    exit 1
  fi

  rclone --config="$RCLONE_CONF" config create "$GDRIVE_REMOTE" drive \
    scope=drive token="$TOKEN" config_is_local=false --non-interactive >/dev/null

  if ! rclone --config="$RCLONE_CONF" about "${GDRIVE_REMOTE}:" >/dev/null 2>&1; then
    rclone --config="$RCLONE_CONF" config delete "$GDRIVE_REMOTE" 2>/dev/null || true
    log_err "Could not verify Google Drive access for '${GDRIVE_REMOTE}:'."
    exit 1
  fi
  log_ok "Google Drive OAuth linked to '${GDRIVE_REMOTE}:'"
else
  log_ok "Google Drive remote '${GDRIVE_REMOTE}:' already configured"
fi

# Ensure remote DRIVE skeleton exists on Google Drive
rclone --config="$RCLONE_CONF" mkdir "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted"
rclone --config="$RCLONE_CONF" mkdir "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/store"
rclone --config="$RCLONE_CONF" mkdir "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/installers"

# 2. Configure single-password PBKDF2 encrypted remote (gdrive-crypt -> gdrive:DRIVE/encrypted)
if ! has_remote "$GDRIVE_CRYPT_REMOTE" || [[ "${FORCE_REKEY:-0}" == "1" ]]; then
  EXISTING_CIPHERTEXT=$(rclone --config="$RCLONE_CONF" lsf "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted" --max-depth 1 | head -n1 || true)

  while true; do
    if [[ -n "${AUTO_DRIVE_PASS:-}" ]]; then
      PASS1="$AUTO_DRIVE_PASS"
    elif [[ -n "$EXISTING_CIPHERTEXT" ]]; then
      log_info "Existing encrypted vault detected in ${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted."
      read -rsp "Enter your existing AUTO-DRIVE vault password: " PASS1 </dev/tty
      echo >/dev/tty
      [[ -n "$PASS1" ]] || { log_warn "Password cannot be empty."; continue; }
    else
      log_info "Setting up new encrypted folder (${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted)."
      while true; do
        read -rsp "Choose a vault password for DRIVE/encrypted: " PASS1 </dev/tty
        echo >/dev/tty
        [[ -n "$PASS1" ]] || { log_warn "Password cannot be empty."; continue; }
        read -rsp "Confirm vault password: " PASS2 </dev/tty
        echo >/dev/tty
        [[ "$PASS1" == "$PASS2" ]] && break
        log_warn "Passwords did not match. Try again."
      done
    fi

    mapfile -t KEYS < <(printf '%s' "$PASS1" | derive_crypt_keys)
    unset PASS1 PASS2

    rclone --config="$RCLONE_CONF" config delete "$GDRIVE_CRYPT_REMOTE" 2>/dev/null || true
    rclone --config="$RCLONE_CONF" config create "$GDRIVE_CRYPT_REMOTE" crypt \
      remote "${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted" \
      filename_encryption "standard" \
      directory_name_encryption "true" \
      password "${KEYS[0]}" \
      password2 "${KEYS[1]}" >/dev/null
    unset KEYS

    # Verify password against existing ciphertext so a typo never silently mounts an empty vault
    if [[ -n "$EXISTING_CIPHERTEXT" ]]; then
      DEC_ITEMS=$(rclone --config="$RCLONE_CONF" lsf "${GDRIVE_CRYPT_REMOTE}:" --max-depth 1 2>/dev/null | head -n1 || true)
      if [[ -z "$DEC_ITEMS" ]]; then
        rclone --config="$RCLONE_CONF" config delete "$GDRIVE_CRYPT_REMOTE" 2>/dev/null || true
        if [[ -n "${AUTO_DRIVE_PASS:-}" ]]; then
          log_err "AUTO_DRIVE_PASS could not decrypt existing files in ${GDRIVE_REMOTE}:${GDRIVE_DRIVE_PATH}/encrypted."
          exit 1
        fi
        log_warn "Incorrect password (could not decrypt existing vault entries). Try again."
        continue
      fi
    fi
    break
  done

  chown "$AUTO_DRIVE_USER:$AUTO_DRIVE_GROUP" "$RCLONE_CONF"
  chmod 0600 "$RCLONE_CONF"
  log_ok "Encrypted remote '${GDRIVE_CRYPT_REMOTE}:' configured via PBKDF2-SHA256"
else
  log_ok "Encrypted remote '${GDRIVE_CRYPT_REMOTE}:' already configured"
fi
