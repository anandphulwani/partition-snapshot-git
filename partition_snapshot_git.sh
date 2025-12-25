#!/usr/bin/env bash
#
# Partition inventory snapshot (find) -> git commit -> push
#
# - Discovers mounted partitions (source device + mountpoint)
# - Runs find per mountpoint with -xdev so it NEVER crosses into other mounts/filesystems
# - Writes one output file per partition (named by device + mount)
# - Overwrites files each run; then: git add -A; commit; push -u origin main
# - Optional: --paths=PATHS (comma-separated, repeatable) to scan only specific mountpoints
# - Commit message: "DD-MMM-YYYY HH:mm" (e.g. "10-Jan-2025 16:25")
# - Maintains per-host instance id INSIDE THIS SCRIPT (self-modifying)
#
# Example cron:
#   10 3 * * * /path/to/partition_snapshot_git.sh --repo=/srv/tree-repo --email=you@domain.com
#
set -euo pipefail
ORIGINAL_CMDLINE=("$0" "$@")

usage() {
	cat <<'EOF'
Usage:
  partition_snapshot_git.sh --repo=PATH --email=EMAIL [options]

Required:
  --repo=PATH          (existing git repo; remote already configured)
  --email=EMAIL        (for notifications)

Optional:
  --debug
  --log=PATH
  --paths=PATHS        (comma-separated; repeatable; if omitted scans all mounted partitions)
  --heartbeat-url=URL
  --notification-url=URL
  -h|--help

Output format per line (pipe-separated):
  inode|path|size|user|group|mode_octal|mtime_epoch|ctime_epoch|type

Notes:
  - Uses `find -xdev` so scans never descend into other mounted filesystems.
  - Scans mountpoints (/, /data, /boot, etc.), not raw block devices.
  - Script must be writable by the running user (self-edit to persist instance id).
EOF
}

die() {
	echo "ERROR: $*" >&2
	usage >&2
	exit 2
}

# Defaults, (but allow override via flags, if flag option is available)
DEBUG=0
LOG="/var/log/partition_snapshot_git.log"
EMAIL=""
REPO=""
HEARTBEAT_URL=""
NOTIFICATION_URL=""
SCAN_PATHS=() # optional filter list (mountpoints)

# -----------------------------
# BEGIN_INSTANCE
INSTANCE_ID=""
# END_INSTANCE
# -----------------------------

# --- Arg parsing ---
for arg in "$@"; do
	case "$arg" in
	--debug)
		DEBUG=1
		;;
	--log=*)
		LOG="${arg#*=}"
		;;
	--email=*)
		EMAIL="${arg#*=}"
		;;
	--repo=*)
		REPO="${arg#*=}"
		;;
	--heartbeat-url=*)
		HEARTBEAT_URL="${arg#*=}"
		;;
	--notification-url=*)
		NOTIFICATION_URL="${arg#*=}"
		;;
	--paths=*)
		IFS=',' read -r -a _paths <<<"${arg#*=}"
		for p in "${_paths[@]}"; do
			[[ -n "$p" ]] && SCAN_PATHS+=("$p")
		done
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "Unknown argument: $arg"
		;;
	esac
done

[[ -n "$EMAIL" ]] || die "--email is required"
[[ -n "$REPO" ]] || die "--repo is required"

timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log() {
	# Usage:
	#   log "message"
	#   log info "message"
	#   log debug "message"
	local level="info"
	local msg

	if [[ "${1:-}" == "debug" || "${1:-}" == "info" ]]; then
		level="$1"
		shift
	fi

	msg="$*"

	if [[ "$level" == "debug" && "${DEBUG:-0}" -ne 1 ]]; then
		return 0
	fi

	echo "[$(timestamp)] [$level] $msg" >>"$LOG"
}

log debug "Config: EMAIL=$EMAIL REPO=$REPO DEBUG=$DEBUG LOG=$LOG"
log debug "Config: SCAN_PATHS=(${SCAN_PATHS[*]:-})"
log debug "Config: NOTIFICATION_URL=$NOTIFICATION_URL"
log debug "Config: HEARTBEAT_URL=$HEARTBEAT_URL"

notify_webhook() {
	local msg="$1"
	[[ -n "$NOTIFICATION_URL" ]] || return 0

	command -v curl >/dev/null 2>&1 || {
		log "ERROR: curl not found; cannot POST notification-url."
		return 0
	}

	curl -fsS -X POST \
		-H "Title: $(hostname): Partition Snapshot" \
		-H "Priority: urgent" \
		-H "Tags: rotating_light,skull" \
		-d "$msg" \
		"$NOTIFICATION_URL" >/dev/null || log "ERROR: notification-url POST failed"
}

heartbeat() {
	[[ -n "$HEARTBEAT_URL" ]] || return 0
	command -v curl >/dev/null 2>&1 || {
		log "ERROR: curl not found; cannot hit heartbeat-url."
		return 0
	}
	curl -fsS "$HEARTBEAT_URL" >/dev/null || log "ERROR: heartbeat-url failed"
}

require_cmd() {
	local cmd="$1"
	local msg

	if ! command -v "$cmd" >/dev/null 2>&1; then
		msg="ERROR: Command '$cmd' not found; skipping related checks."
		log "$msg"
		notify_webhook "$msg"
		return 1
	fi
	return 0
}

sendemail() {
	# Args: subject, body
	local subject="$1"
	local body="$2"

	if ! command -v mail >/dev/null 2>&1; then
		log "ERROR: mail command not found; cannot send email. Subject: $subject"
		return 0
	fi

	printf '%s\n' "$body" | mail -s "$subject" "$EMAIL" || log "ERROR: mail send failed"
	log "Successfully sent email to \`$EMAIL\` with subject \`$subject\`."
}

# Return a list of "device<TAB>mountpoint" lines for real mounted local filesystems.
# We exclude pseudo fs types
list_mounted_partitions() {
	require_cmd findmnt || return 1
	require_cmd awk || return 1
	require_cmd sort || return 1

	# SOURCE TARGET FSTYPE
	findmnt -rn -o SOURCE,TARGET,FSTYPE | awk '
		$1 ~ "^/dev/" && $2 != "" {
			ft=$3
			if (ft ~ "^(proc|sysfs|devtmpfs|devpts|tmpfs|cgroup2?|pstore|securityfs|debugfs|tracefs|overlay|squashfs|rpc_pipefs|nsfs|fusectl)$") next
			print $1 "\t" $2
		}
	' | sort -u
}

# Sanitize string for filename
safe_name() {
	local s="$1"
	s="${s#/dev/}" # drop /dev/
	s="${s//\//_}" # / -> _
	s="${s//-/_}"  # - -> _
	s="${s//./_}"  # . -> _
	s="${s// /_}"  # space -> _
	echo "$s"
}

# Decide if mountpoint should be scanned based on SCAN_PATHS (if any)
should_scan_mount() {
	local mp="$1"
	if ((${#SCAN_PATHS[@]} == 0)); then
		return 0
	fi
	local p
	for p in "${SCAN_PATHS[@]}"; do
		if [[ "$mp" == "$p" ]]; then
			return 0
		fi
	done
	return 1
}

generate_instance_id_5digits() {
	local num=""

	if [[ -r /dev/urandom ]]; then
		require_cmd od || {
			printf "%05d\n" "$((RANDOM % 100000))"
			return 0
		}
		require_cmd tr || {
			printf "%05d\n" "$((RANDOM % 100000))"
			return 0
		}
		require_cmd awk || {
			printf "%05d\n" "$((RANDOM % 100000))"
			return 0
		}

		num="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ' | awk '{print $1 % 100000}')"
	else
		num="$((RANDOM % 100000))"
	fi

	printf "%05d" "$num"
}

save_instance_into_script() {
	require_cmd mktemp || return 1
	require_cmd sed || return 1
	require_cmd mv || return 1

	# Persist INSTANCE_ID inside the script
	local script="${BASH_SOURCE[0]}"
	local tmp script_dir

	script_dir="$(dirname -- "$script")"
	tmp="$(mktemp -- "${script_dir}/.script_instance_tmp.XXXXXX")" || return 1

	# Before BEGIN_INSTANCE (excluding the BEGIN_INSTANCE line itself)
	sed -n '1,/^# BEGIN_INSTANCE$/p' "$script" | sed '$d' >"$tmp"

	{
		echo "# BEGIN_INSTANCE"
		printf 'INSTANCE_ID=%q\n' "$INSTANCE_ID"
		echo "# END_INSTANCE"
	} >>"$tmp"

	# After END_INSTANCE (excluding the END_INSTANCE line itself)
	sed -n '/^# END_INSTANCE$/,$p' "$script" | sed '1d' >>"$tmp"

	mv -- "$tmp" "$script"
}

ensure_instance_id() {
	# Initialize only once; keep stable thereafter (stored in this script).
	if [[ -n "${INSTANCE_ID:-}" ]]; then
		return 0
	fi

	INSTANCE_ID="$(generate_instance_id_5digits)"
	log "Initialized INSTANCE_ID=$INSTANCE_ID (persisting into script)"

	# Best-effort persist; if it fails, we still proceed (but would re-init next run).
	if ! save_instance_into_script; then
		local msg="ERROR: Failed to persist INSTANCE_ID into script. Ensure the script is writable."
		log "$msg"
		notify_webhook "$msg"
		sendemail "$(hostname): partition snapshot WARNING" "$msg"
	fi
}

host_instance_folder() {
	local h
	h="$(hostname -s 2>/dev/null || hostname)"
	h="$(safe_name "$h")"
	echo "${h}-${INSTANCE_ID}"
}

run_find_for_mount() {
	local dev="$1"
	local mp="$2"
	local outdir="$3"

	# Output file name includes both device and mountpoint (so /dev/sda2 on / is distinct)
	local outfile="${outdir}/$(safe_name "$dev")__$(safe_name "$mp").find.txt"

	log "Generating filesystem snapshot for $dev mounted at $mp -> $outfile"

	# Write header first; if this fails, report and stop this mount.
	if ! {
		echo "HOST: $(hostname)"
		echo "TIMESTAMP: $(timestamp)"
		echo "DEVICE: $dev"
		echo "MOUNTPOINT: $mp"
		echo "CMD: find \"$mp\" -xdev -printf '%i|%p|%s|%u|%g|%m|%T@|%C@|%y\\n'"
		echo "------------------------------------------------------------"
	} >"$outfile"; then
		log "ERROR: failed to write snapshot header to $outfile"
		notify_webhook "ERROR: failed to write snapshot header to $outfile"
		return 1
	fi

	# -xdev ensures we do not cross to other mounts/filesystems.
	# Append find output; if it fails, log/notify but don't crash entire script.
	if ! find "$mp" -xdev -printf '%i|%p|%s|%u|%g|%m|%T@|%C@|%y\n' >>"$outfile"; then
		local msg="ERROR: find failed for mountpoint $mp (device $dev). Output may be incomplete: $outfile"
		log "$msg"
		notify_webhook "$msg"
		sendemail "$(hostname): partition snapshot find FAILED" "$msg"$'\n'"Log: $LOG"
		return 1
	fi

	return 0
}

git_commit_and_push() {
	local repo="$1"

	pushd "$repo" >/dev/null || {
		log "ERROR: pushd failed: $repo"
		return 1
	}

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		popd >/dev/null || true
		die "--repo is not a git repo: $repo"
	fi

	if ! git add -A; then
		log "ERROR: git add failed in repo $repo"
		popd >/dev/null || true
		return 1
	fi

	if git diff --cached --quiet; then
		log "No changes to commit."
		popd >/dev/null || true
		return 0
	fi

	local msg="Partition snapshot: $(hostname) $(date '+%d-%b-%Y %H:%M')"

	if ! git commit -m "$msg"; then
		log "ERROR: git commit failed: $msg"
		popd >/dev/null || true
		return 1
	fi
	log "Committed changes: $msg"

	if ! git push -u origin main; then
		log "ERROR: git push failed (origin main) in repo $repo"
		popd >/dev/null || true
		return 1
	fi
	log "Pushed to origin main with -u."

	popd >/dev/null || true
	return 0
}

main() {
	log "STARTING === Partition snapshot (find) -> git ==="
	log "Invoked as: $(printf '%q ' "${ORIGINAL_CMDLINE[@]}")"

	require_cmd find || die "find is required"
	require_cmd git || die "git is required"

	if [[ ! -d "$REPO" ]]; then
		die "--repo does not exist or is not a directory: $REPO"
	fi

	# Ensure stable instance id exists (self-modifying)
	ensure_instance_id

	# Output directory in repo: <hostname>-<id>/
	local folder
	folder="$(host_instance_folder)"
	local outdir="${REPO%/}/${folder}"
	mkdir -p "$outdir"

	# Discover mounted partitions
	local mounts
	if ! mounts="$(list_mounted_partitions)"; then
		die "Failed to list mounted partitions (need findmnt)."
	fi

	if [[ -z "$mounts" ]]; then
		die "No mounted /dev/* partitions found."
	fi

	log debug 'mounts raw:\n%s\n' "$mounts"
	log debug 'mounts lines: %s\n' "$(printf '%s' "$mounts" | wc -l)"
	local scanned=0 skipped=0

	while IFS=$'\t' read -r dev mp; do
		[[ -n "$dev" && -n "$mp" ]] || continue

		if ! should_scan_mount "$mp"; then
			((++skipped))
			continue
		fi

		if [[ ! -d "$mp" ]]; then
			log "ERROR: mountpoint not a directory: $mp (device $dev)"
			notify_webhook "ERROR: mountpoint not a directory: $mp (device $dev)"
			continue
		fi

		run_find_for_mount "$dev" "$mp" "$outdir"
		((++scanned))
	done <<<"$mounts"

	log "Scan complete: scanned=$scanned skipped=$skipped"
	log "Output directory: $outdir"

	# Commit + push
	if ! git_commit_and_push "$REPO"; then
		local msg="ERROR: git commit/push failed for repo $REPO"
		log "$msg"
		notify_webhook "$msg"
		sendemail "$(hostname): partition snapshot git push FAILED" "$msg"$'\n'"Log: $LOG"
		return 1
	fi

	if ((scanned == 0)); then
		local msg="WARNING: No mountpoints matched --paths filter; nothing scanned."
		log "$msg"
		notify_webhook "$msg"
		sendemail "$(hostname): partition snapshot WARNING" "$msg"$'\n'"Invoked as: $(printf '%q ' "${ORIGINAL_CMDLINE[@]}")"
	fi

	log "DONE === Partition snapshot (find) -> git ==="
	return 0
}

main
heartbeat
