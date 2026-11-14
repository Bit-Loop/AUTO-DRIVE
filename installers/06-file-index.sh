#!/usr/bin/env bash
# Module 06: Cheap periodic local file index, RAM dir-cache warmer & Google Docs materializer

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

sudo mkdir -p /usr/local/libexec

# Helper: materialize native Google Docs/Sheets/Slides (Size == -1 -> 0 bytes on FUSE) in store/
# into real seekable .docx/.xlsx/.pptx/.svg files so --vfs-cache-mode=full & local tools work seamlessly.
sudo tee /usr/local/libexec/auto-drive-materialize-gdocs >/dev/null << 'EOF'
#!/usr/bin/env python3
import fcntl
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

EXPORT_EXTS = {".docx", ".xlsx", ".pptx", ".svg", ".odt", ".ods", ".odp", ".rtf", ".epub"}
ZIP_EXTS = {".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".epub"}


def load_known_empty(state_path: str) -> dict:
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_known_empty(state_path: str, mapping: dict) -> None:
    tmp_path = f"{state_path}.tmp.{os.getpid()}"
    try:
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(mapping, f)
        os.replace(tmp_path, state_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def main() -> int:
    if len(sys.argv) < 8:
        return 2
    drive_mount, rclone_conf, gdrive_remote, gdrive_drive_path, cache_dir, rc_plain_sock, force_remote = sys.argv[1:8]
    store_dir = os.path.join(drive_mount, "store")
    if not os.path.isdir(store_dir):
        return 0

    os.makedirs(cache_dir, mode=0o700, exist_ok=True)
    lock_path = os.path.join(cache_dir, ".materialize-gdocs.lock")
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    try:
        zero_candidates = {}
        for root, _, files in os.walk(store_dir):
            for name in files:
                ext = os.path.splitext(name)[1].lower()
                if ext not in EXPORT_EXTS:
                    continue
                full_path = os.path.join(root, name)
                try:
                    st = os.lstat(full_path)
                except OSError:
                    continue
                if stat.S_ISREG(st.st_mode) and st.st_size == 0:
                    rel = os.path.relpath(full_path, store_dir).replace(os.sep, "/")
                    zero_candidates[rel] = st.st_mtime_ns

        state_path = os.path.join(cache_dir, "empty-store-files.json")
        known_empty = {k: v for k, v in load_known_empty(state_path).items() if k in zero_candidates}

        if not zero_candidates:
            save_known_empty(state_path, {})
            return 0

        if force_remote != "1" and all(known_empty.get(rel) == mtime for rel, mtime in zero_candidates.items()):
            save_known_empty(state_path, known_empty)
            return 0

        remote_store = f"{gdrive_remote}:{gdrive_drive_path}/store"
        ls_res = subprocess.run(
            ["rclone", f"--config={rclone_conf}", "lsjson", "-R", "--files-only", remote_store],
            capture_output=True,
            text=True,
            check=True,
        )
        entries = json.loads(ls_res.stdout)

        gdocs = []
        for entry in entries:
            if entry.get("IsDir"):
                continue
            rel = entry.get("Path", "")
            if not rel or os.path.isabs(rel) or ".." in rel.split("/"):
                continue
            size = entry.get("Size", 0)
            if size == 0 and rel in zero_candidates:
                known_empty[rel] = zero_candidates[rel]
            elif size == -1 and entry.get("ID") and os.path.splitext(rel)[1].lower() in EXPORT_EXTS:
                gdocs.append((entry["ID"], rel))

        save_known_empty(state_path, known_empty)
        if not gdocs:
            return 0

        stage_dir = tempfile.mkdtemp(prefix=".gdoc-export-", dir=cache_dir)
        try:
            copyid_cmd = ["rclone", f"--config={rclone_conf}", "backend", "copyid", f"{gdrive_remote}:"]
            for file_id, rel in gdocs:
                local_dest = os.path.join(stage_dir, rel)
                os.makedirs(os.path.dirname(local_dest), exist_ok=True)
                copyid_cmd.extend([file_id, local_dest])
            subprocess.run(copyid_cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            verified = []
            for file_id, rel in gdocs:
                local_dest = os.path.join(stage_dir, rel)
                ext = os.path.splitext(rel)[1].lower()
                ok = os.path.isfile(local_dest) and os.path.getsize(local_dest) > 0
                if ok and ext in ZIP_EXTS:
                    with open(local_dest, "rb") as f:
                        ok = f.read(4) == b"PK\x03\x04"
                if ok:
                    verified.append((file_id, rel))
                elif os.path.exists(local_dest):
                    os.unlink(local_dest)

            if not verified:
                return 0

            trash_stage = f".auto-drive-gdoc-trash-{os.getpid()}"
            move_cmd = ["rclone", f"--config={rclone_conf}", "backend", "moveid", f"{gdrive_remote}:"]
            for file_id, _ in verified:
                move_cmd.extend([file_id, f"{gdrive_remote}:{trash_stage}/{file_id}/"])
            subprocess.run(move_cmd, check=True, stdout=subprocess.DEVNULL)

            try:
                subprocess.run(
                    [
                        "rclone",
                        f"--config={rclone_conf}",
                        "copy",
                        stage_dir,
                        remote_store,
                        "--transfers=2",
                        "--bwlimit=8.5M:off",
                    ],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
            except Exception:
                rollback_cmd = ["rclone", f"--config={rclone_conf}", "backend", "moveid", f"{gdrive_remote}:"]
                for file_id, rel in verified:
                    parent = os.path.dirname(rel)
                    dest_dir = f"{gdrive_drive_path}/store/{parent}/" if parent else f"{gdrive_drive_path}/store/"
                    rollback_cmd.extend([file_id, f"{gdrive_remote}:{dest_dir}"])
                subprocess.run(rollback_cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                raise

            subprocess.run(
                ["rclone", f"--config={rclone_conf}", "purge", "--drive-show-all-gdocs", f"{gdrive_remote}:{trash_stage}"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            if os.path.exists(rc_plain_sock):
                dirs_to_forget = {"store"}
                for _, rel in verified:
                    parent = os.path.dirname(rel)
                    if parent:
                        dirs_to_forget.add(f"store/{parent}")
                for d in sorted(dirs_to_forget):
                    subprocess.run(
                        ["rclone", "rc", f"--unix-socket={rc_plain_sock}", "vfs/forget", f"dir={d}"],
                        check=False,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                subprocess.run(
                    ["rclone", "rc", f"--unix-socket={rc_plain_sock}", "vfs/refresh", "dir=store", "recursive=true"],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(1.1)
        finally:
            shutil.rmtree(stage_dir, ignore_errors=True)
    finally:
        os.close(lock_fd)

    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF
sudo chmod 0755 /usr/local/libexec/auto-drive-materialize-gdocs

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

# Native Google Docs/Sheets/Slides in store/ have Size=-1 (0 bytes on FUSE) and fail under --vfs-cache-mode=full.
# Fast in-RAM check (0 API calls when none exist); exports & materializes real seekable Office/SVG files when found.
if [[ -d "\$DRIVE_MOUNT/store" ]] && [[ -n "\$(find "\$DRIVE_MOUNT/store" -type f -size 0 \\( -iname '*.docx' -o -iname '*.xlsx' -o -iname '*.pptx' -o -iname '*.svg' -o -iname '*.odt' -o -iname '*.ods' -o -iname '*.odp' -o -iname '*.rtf' -o -iname '*.epub' \\) -print -quit 2>/dev/null)" ]]; then
  /usr/local/libexec/auto-drive-materialize-gdocs "\$DRIVE_MOUNT" "$RCLONE_CONF" "$GDRIVE_REMOTE" "$GDRIVE_DRIVE_PATH" "$AUTO_DRIVE_CACHE_DIR" "$RC_PLAIN_SOCK" "\$FORCE_REMOTE" || true
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
Description=Refresh AUTO-DRIVE Local File Index every 2 minutes

[Timer]
OnBootSec=45s
OnUnitActiveSec=2m

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now auto-drive-index.timer
sudo -u "$AUTO_DRIVE_USER" /usr/local/libexec/auto-drive-index 0 || true
log_ok "Periodic 2m file indexer & Google Docs materializer enabled (-> $AUTO_DRIVE_CACHE_DIR/index.tsv)"
