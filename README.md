# AUTO-DRIVE

**iCloud-style Google Drive virtual filesystem for Linux & headless VPS servers** — combining a bidirectional plain Google Drive store, a single-password encrypted high-I/O vault (`rclone crypt` + PBKDF2), automated daily `.tar.zst` system snapshots, and dynamic free-space cache eviction.

---

## Directory Layout (`~/DRIVE` <-> Google Drive `/DRIVE`)

On Google Drive, everything lives neatly inside a single `/DRIVE` folder alongside your existing Drive files. On Linux, `~/DRIVE` and all subdirectories auto-mount at boot as standard **read-write** folders:

```text
~/DRIVE/                            <-- Mounted from gdrive:DRIVE (auto-drive-root.service)
├── encrypted/                      <-- Decrypted RW sub-mount (auto-drive-crypt.service)
│   ├── data/                       <-- High-IO & sensitive storage (client-side encrypted)
│   │   ├── archives/               # Shelved compiled projects (.tar.zst) & DB dumps
│   │   ├── pcaps/                  # Packet captures
│   │   ├── recon/                  # Columnar Zstd .parquet datasets (queryable via DuckDB)
│   │   ├── sqlite-backups/         # Continuous SQLite WAL replicas (Litestream)
│   │   └── wordlists/              # Streaming wordlists
│   └── snapshots/                  <-- Automated daily 03:30 UTC .tar.zst system backups
│       └── <hostname>/YYYY-MM-DD_HHMMSS.tar.zst
├── store/                          <-- Unencrypted RW files (visible in Google Drive Web UI / mobile)
├── installers/                     <-- Self-contained setup modules mirrored to Google Drive
├── README.md
└── run.sh                          <-- Unified bootstrap & control CLI
```

---

## Key Features

- **iOS iCloud-Style Dynamic Storage Optimization:**
  - Files written to `~/DRIVE` land on fast local NVMe/SSD first, upload asynchronously in the background, and **pop/evict locally ~5 minutes after closing** (`--vfs-cache-max-age=5m`) while continuing to appear as normal local files that stream on demand when opened.
  - Dynamically caps cache at **20% of local free storage (minimum 2 GiB floor)** and enforces **`--vfs-cache-min-free-space`** (`max(2 GiB, 20% of total disk)`) + a 2-minute rebalance timer so cached cloud files automatically pop whenever local disk space shrinks.
- **Zero-API-Cost Native File Index & RAM Dir-Cache (`drive-find`):**
  - Holds the full directory tree in RAM (`--dir-cache-time=9999h`) updated incrementally via Google Drive's lightweight 20-second `changes.list` delta feed (`0` API calls for unchanged folders).
  - A background `systemd` timer (`auto-drive-index.timer`) walks the local dentry tree every **5 minutes** to pre-warm any remotely modified folders and write a `0600` local TSV index (`~/.cache/auto-drive/index.tsv`), powering **`drive-find`** (`./run.sh find [query]`) for **<5 ms** `fzf` / CLI search across 20 TB without network roundtrips.
- **Single-Password Zero-Knowledge Vault (`~/DRIVE/encrypted`):**
  - Derives deterministic 256-bit `rclone crypt` key + salt from **one memorable password** via **600,000-iteration PBKDF2-HMAC-SHA256**—unlock `DRIVE/encrypted` on any new Linux machine with just your password (no separate salt files to carry, zero secrets in Git or plain Google Drive).
  - Live password rotation (`./run.sh passwd`) safely stages, re-keys, and re-encrypts `DRIVE/encrypted`.
- **Standard Read-Write Daily System Snapshots (`encrypted/snapshots/`):**
  - Systemd timer (`auto-drive-snapshot.timer`) runs daily at **03:30 UTC** (`Persistent=true`), capturing `/etc` system & reverse-proxy configs (`/etc/nginx`, `/etc/caddy`, `/etc/letsencrypt`, `/etc/systemd/system`, etc.) + `$HOME` into browseable `.tar.zst` archives with automatic **7-daily / 4-weekly / 6-monthly** retention pruning.
- **Headless VPS Hardening:**
  - Copy-paste browser OAuth flow that works over SSH with **no local `rclone` install or port-forwarding required**.
  - Automatic 4 GiB `/swapfile` safeguard on low-RAM (<8 GiB), zero-swap VPSes (`GOMEMLIMIT=256MiB`, `OOMScoreAdjust=-500`).
  - Private Unix domain RC sockets (`0700` `~/.config/auto-drive/rc-*.sock` — zero exposed localhost TCP ports against SSRF).
  - Pre-configured `~/.ignore` so `fd` (`Ctrl-T`) and `ripgrep` (`rg`) in `$HOME` never accidentally crawl 20 TB over the network, while still working normally when inside `~/DRIVE`.
  - Pre-installed **DuckDB** (512 MiB RAM cap + NVMe spill for querying multi-TB `.parquet` lakes directly off `~/DRIVE/encrypted/data/recon/`) and **Litestream** (continuous SQLite WAL replication).

---

## Quickstart (Fresh Ubuntu / Debian VPS)

```bash
git clone https://github.com/Bit-Loop/AUTO-DRIVE.git ~/GITHUB/AUTO-DRIVE
cd ~/GITHUB/AUTO-DRIVE
chmod +x run.sh installers/*.sh
./run.sh setup
```

During `./run.sh setup`:
1. Click the printed Google OAuth URL in any browser, sign in, and paste back the `http://127.0.0.1:53682/?state=...` redirect URL.
2. Enter your vault password (sets up a new `DRIVE/encrypted` vault, or unlocks your existing one on a second machine).

---

## Everyday CLI (`./run.sh` or `~/DRIVE/run.sh`)

```bash
./run.sh status          # Mount health, dynamic 20% cache stats, index stats, snapshots, RAM/swap (also: `drive-status`)
./run.sh find [query]    # <5ms instant search across all 20 TB (interactive fzf picker if no args; also: `drive-find`)
./run.sh reindex         # Force remote dir-cache refresh + rebuild local index on demand
./run.sh backup          # Run an immediate encrypted .tar.zst system snapshot
./run.sh evict           # Immediately pop unlocked cached files from local SSD (remote files stay visible)
./run.sh passwd          # Set or rotate your vault password (re-encrypts DRIVE/encrypted)
./run.sh sync            # Sync repo changes (README.md, run.sh, installers/) into ~/DRIVE/
./run.sh unmount         # Cleanly stop ~/DRIVE mounts
./run.sh mount           # Start ~/DRIVE mounts
```

---

## Power-User Workflows

- **Plain Google Drive (`~/DRIVE/store/`):** Drop files you want visible in Google Drive's browser UI or mobile app into `~/DRIVE/store/`. Conversely, files uploaded into `/DRIVE/store` from your browser/phone appear automatically in `~/DRIVE/store/`.
- **Compilation & Active Git Repos:** Build on local SSD (`~/GITHUB`, `/tmp`) for full POSIX speed and small-file IOPS; shelve inactive projects with `tar --zstd -cf ~/DRIVE/encrypted/data/archives/proj.tar.zst proj/`.
- **Query Multi-TB Datasets in Place (`DuckDB` + `Parquet`):**
  ```bash
  duckdb -c "COPY (SELECT * FROM read_json_auto('data.jsonl')) TO '~/DRIVE/encrypted/data/recon/part1.parquet' (COMPRESSION ZSTD);"
  duckdb -c "SELECT * FROM '~/DRIVE/encrypted/data/recon/*.parquet' LIMIT 20;"
  ```
- **Continuous SQLite Replication (`Litestream`):**
  ```bash
  litestream replicate ~/work/app.db ~/DRIVE/encrypted/data/sqlite-backups/app.db
  ```

### Custom Google Cloud OAuth Client ID (Recommended)
`rclone`'s shared global OAuth `client_id` shares API quota across users and is scheduled for retirement. To switch to your own free GCP OAuth Client ID without re-setting up:
```bash
rclone --config ~/.config/auto-drive/rclone.conf config update gdrive client_id YOUR_ID client_secret YOUR_SECRET
./run.sh unmount && ./run.sh mount
```

---

## License

MIT
