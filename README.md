# partition_snapshot_git.sh - Partition Inventory Snapshots (find -xdev) -> Git Commit -> Push

A self-contained (self-modifying) Bash script that captures a **filesystem inventory snapshot per mounted partition** using `find -xdev` (so it **never crosses into other mounts/filesystems**), then writes results into a git repo, commits, and pushes to `origin main`.

Designed to run from `cron` and to keep each host’s snapshots neatly separated via a persistent per-host **INSTANCE_ID** stored **inside the script itself**.

---

## What it does

### 1) Discovers mounted partitions
The script enumerates mounted local partitions using:

- `findmnt -rn -o SOURCE,TARGET,FSTYPE`

It keeps only:
- mounts whose source matches `^/dev/`
- real filesystems (filters out pseudo types like proc, sysfs, tmpfs, overlay, etc.)

Result is a list of:
- `device<TAB>mountpoint`

Examples:
- `/dev/sda2    /`
- `/dev/sdb1    /data`

---

### 2) Runs a partition-safe inventory scan per mountpoint
For each discovered mountpoint, it runs:

- `find "<mountpoint>" -xdev -printf '...'`

The key safety flag:
- `-xdev` ensures the scan **stays within that filesystem** and does not traverse into other mounted filesystems.

Each output line is pipe-separated:

- inode|path|size|user|group|mode_octal|mtime_epoch|ctime_epoch|type

Where:
- inode: inode number
- path: full path
- size: bytes
- user/group: numeric IDs
- mode_octal: file mode (octal)
- mtime_epoch: modification time (epoch, float-ish)
- ctime_epoch: metadata change time (epoch, float-ish)
- type: find %y (f,d,l,b,c,p,s, etc.)

Each output file also includes a header section (host, timestamp, device, mountpoint, command) followed by a separator line.

---

### 3) Writes one output file per partition into a git repo
Outputs are placed under:

- <hostname>-<INSTANCE_ID>/

File naming includes both device and mountpoint so they stay unique even across similar layouts:

- <device>__<mountpoint>.find.txt

Example:
- nas-01234/sda2___root.find.txt
- nas-01234/sdb1___data.find.txt

Names are sanitized so they are filesystem-safe.

---

### 4) Overwrites, commits, pushes
Each run overwrites the per-partition files for that host instance folder, then:

- `sudo git add -A`
- if changes exist: commit with message:
  - `Partition snapshot: <hostname> DD-MMM-YYYY HH:mm`
- `sudo git push -u origin main`

If nothing changed:
- it logs and exits cleanly without committing.

---

### 5) Optional integrations
- `--notification-url=URL`
  Sends a POST (works great with **ntfy**) on errors/warnings.
- `--heartbeat-url=URL`
  Hits a URL at the end (healthchecks / uptime monitors). Intended to confirm successful completion.

---

## Requirements

The script expects these tools to exist on the host:

- `findmnt` (util-linux)
- `find` (findutils)
- `git`
- `awk, sed, sort` (core utils)
- `curl` (only if using notification/heartbeat)
- `mail` (only if you want email alerts)

Notes:
- Your repo must already exist and have its remote configured (origin) and main branch in place.
- The script must be writable by the running user (it self-modifies to store INSTANCE_ID).

---

## Install & run (copy/paste)

### 1) Install packages (Debian/Ubuntu)
```bash
sudo apt update
sudo apt install -y util-linux findutils git curl mailutils
```

(If you do not want email, you can skip mailutils and still run the script.)

---

### 2) Setup a github.com repo to receive snapshots

- Create a Personal Access Token (PAT)
Replace in below
01. `<NAME>`: Suitable descriptive name for token.
```text
GitHub → Settings → Developer settings → Personal access tokens
- Token Name: <NAME>
- Expiration: No expiration
- Repository access: Only select repositiories `partition-snapshot-git-data`
- Permissions: Add permissions: Add `Contents` (it will automatically ad `Metadata`)
- Change `Contents` access to: `Read and write`
- Click on `Generate Token` # Remember this token to use in next step.
````

- Use token instead of password
```text
sudo git push https://github.com/USERNAME/REPO.git
Username → your Git username
Password → PASTE TOKEN
```

- Cache credentials permanently
```text
sudo git config --global credential.helper store
```

- Run `sudo git push -u origin main` again with the token for it to cache
```text
sudo git push -u origin main
Username → your Git username
Password → PASTE TOKEN
```

---

### 3) Create a git repo for snapshots
Replace in the code below
01. `<FULL NAME>` with your GIT full name.
02. `<EMAIL ADDRESS>` with your GIT email.
03. `<YOUR_REMOTE_REPO_URL>` with your github remote URL.
```bash
sudo mkdir -p /mnt/backup-store/partition-snapshot-git-data
cd /mnt/backup-store/partition-snapshot-git-data

sudo git config --global init.defaultBranch main
sudo git config --global user.name "<FULL NAME>"
sudo git config --global user.email <EMAIL ADDRESS>


sudo git init

sudo git branch -M main
sudo git remote add origin <YOUR_REMOTE_REPO_URL>
sudo git commit --allow-empty -m "Initial blank commit."
sudo touch .gitignore
sudo git add .gitignore
sudo git commit -m "Added \`.gitignore\`."
sudo git push -u origin main
```

---

### 4) Create the script
```bash
sudo vi /usr/local/sbin/partition_snapshot_git.sh # paste the script contents
sudo chmod +x /usr/local/sbin/partition_snapshot_git.sh
```

---

### 5) Create the log file
Default log path is:
- /var/log/partition_snapshot_git.log

Create it and ensure it is writable by the user running the cron job:
```bash
sudo touch /var/log/partition_snapshot_git.log
sudo chown root:root /var/log/partition_snapshot_git.log
sudo chmod 0644 /var/log/partition_snapshot_git.log
```

If running from root cron, this is fine.
If running as a non-root user, consider:
- `--log=/path/you/own.log`

---

### 6) Add cron
Edit root crontab:
```bash
sudo crontab -e
```

Make sure the PATH line is present on the top, just below the comments, otherwise add it.:
```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Replace in the code below
01. `<EMAIL.GOES.HERE@PROVIDER.COM>` with your email, on which you want notification.
02. `<NOTIFICATION URL>` with your notification URL, on which you want notification alerts. it can be something like `http://ntfy.sh/<TOPIC-NAME-HERE>`
03. `<HEARTBEAT URL>` with your heartbeat URL, this can be a URL of uptime kuma or other uptime checkers.
```cron
10 0 1 * * /bin/bash /usr/local/sbin/partition_snapshot_git.sh --repo=/mnt/backup-store/partition-snapshot-git-data --email=<EMAIL.GOES.HERE@PROVIDER.COM> --notification-url="<NOTIFICATION URL>" --heartbeat-url="<HEARTBEAT URL>"
```

---

## Usage

### Required flags
- `--repo=PATH`
  Existing git repo with origin configured.
- `--email=EMAIL`
  Email recipient (used for warnings/errors; still required by the script).

---

### Common optional flags
- `--debug`
  Enables debug logging.
- `--log=PATH`
  Default: `/var/log/partition_snapshot_git.log`
- `--paths=PATHS`
  Comma-separated mountpoints; repeatable.
  If omitted, scans all eligible mounted partitions.
- `--notification-url=URL`
  POSTs a message on errors/warnings (ntfy works nicely).
- `--heartbeat-url=URL`
  GET request at end of run.

---

## Output format

Each per-partition file contains:

1) Header:
- HOST
- TIMESTAMP
- DEVICE
- MOUNTPOINT
- CMD
- separator line

2) Data lines:
- inode|path|size|user|group|mode_octal|mtime_epoch|ctime_epoch|type

Example line (illustrative):
- 12345|/var/log/syslog|1048576|0|0|644|1736522732.0000000000|1736522732.0000000000|f

---

## Folder layout in the repo

Inside your repo:

- <hostname>-<INSTANCE_ID>/
    - <device>__<mountpoint>.find.txt
    - ...

INSTANCE_ID is a 5-digit value generated once per host-script copy and stored inside the script between:

- # BEGIN_INSTANCE
- # END_INSTANCE

This keeps each host’s snapshots stable and avoids collisions if you clone the same repo across multiple machines.

---

## Tips / Troubleshooting

### Permissions
- If the script cannot write itself, it will still run but will generate a new INSTANCE_ID on each run.
- Best practice: install the script with permissions so the cron user can modify it (or accept that ID may reset).
- Scanning system paths often requires root to avoid permission-denied noise and missing entries.

---

### Mail delivery
The script uses:
- mail -s "subject" recipient

If you do not have an MTA configured, mail may not deliver.
Options:
- Configure postfix (or another MTA)
- Use an SMTP relay
- Rely on `--notification-url` instead for alerts

---

### Git push failures
If push fails, the script:
- logs the error
- posts to notification-url (if set)
- emails (if mail exists)

Common causes:
- missing credentials for non-interactive git push
- branch mismatch (repo not on main)
- origin not configured
- network/firewall issues

If using HTTPS remotes, consider:
- credential helper
- deploy token
- SSH remote with key-based auth for cron environments

---

### Large filesystems
Running find on large mounts can be heavy.
Mitigations:
- schedule off-hours (cron)
- limit scans using `--paths`
- consider excluding paths (would require script modification)
- ensure your repo storage can handle snapshot growth over time

---

## Example runs

### Scan everything (all eligible mounted /dev/* partitions)
```bash
sudo /usr/local/sbin/partition_snapshot_git.sh --repo=/mnt/backup-store/partition-snapshot-git-data --email=you@domain.com
```

### Scan only root and /data
```bash
sudo /usr/local/sbin/partition_snapshot_git.sh --repo=/mnt/backup-store/partition-snapshot-git-data --email=you@domain.com --paths=/,/data
```

### With webhook + heartbeat + debug logging
```bash
sudo /usr/local/sbin/partition_snapshot_git.sh \
  --repo=/mnt/backup-store/partition-snapshot-git-data \
  --email=you@domain.com \
  --debug \
  --notification-url="http://ntfy.sh/<TOPIC>" \
  --heartbeat-url="https://hc-ping.com/<UUID>"
```

---

## Safety notes

- The script scans mountpoints (/, /data, /boot, etc.), not raw block devices.
- It uses `find -xdev` so it will not traverse into other mounted filesystems, avoiding accidental cross-partition scanning.
- On very busy systems, a full filesystem walk may impact IO; schedule appropriately.
