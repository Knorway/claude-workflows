#!/usr/bin/env bash
# One at a time, across every worktree of this repo.
#
#   wt-lock <name> -- <command...>          # wait for the lock, then run
#   wt-lock <name> --wait 300 -- <cmd...>   # give up after 300s instead of waiting
#   wt-lock <name> --status                 # who holds it, if anyone
#
# WHY THIS EXISTS. Opening several worktrees is what this plugin is for, and the
# bill arrives when two tabs run the same heavy command at once. On the machine
# this was written for — 8GB, four tabs — one e2e suite alone put the machine into
# swap: free fell to 57MB and the compressor moved 300-500 MB/s while doing zero
# application work. A second suite starting did not halve the throughput, it
# multiplied the paging, because the shortfall lengthens each run and the longer
# run widens the overlap. Serialising is not a sacrifice there; it is faster.
#
# It also removes a whole class of silent wrongness. Test runners look for their
# server on a fixed port and attach to whatever answers — so the second worktree
# was checking the FIRST worktree's code, against the first worktree's database,
# and reporting the result as its own.
#
# WHAT IT DOES NOT LOCK: dev servers, editors, your other tab's typing. Only the
# command you hand it. Naming the lock (rather than one global "wt" lock) is what
# keeps `build` and `e2e` from blocking each other on a machine that could run
# both.
#
# THE WAIT IS THE FEATURE, AND SO IS SAYING SO. Before this existed the second
# tab did not wait — it started its own servers, failed to bind, and sat in a
# 120-second poll against a URL that was never going to answer, with no output.
# That reads as "hung forever". Here the holder's worktree, pid and elapsed time
# are printed every couple of seconds, so the wait has a visible reason and a
# visible end.
#
# mkdir is the mutex: atomic create-if-absent, and macOS ships no flock(1). Same
# reason and same shape as todo.sh's lock over TODO.md.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/budget.sh"

# --- where the lock lives -------------------------------------------------------
# The COMMON git dir, not `--git-dir`. In a worktree the latter is
# <main>/.git/worktrees/<name>, which is per-worktree — exactly the thing this
# must not be. The common dir is one path for every worktree of the repo
# (verified across ten of them), it is outside every working tree so no file
# watcher sees it and no commit can contain it, and it dies with the repo.
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
	echo "wt-lock: git 레포가 아니다 — 락 없이 그대로 실행한다" >&2
	COMMON=""
}

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }

# --- arguments ------------------------------------------------------------------
NAME=""; WAIT_MAX=""; STATUS_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--) shift; break ;;
		--wait) WAIT_MAX=${2:-}; shift 2 || { echo "wt-lock: --wait 에 초 단위 값이 필요하다" >&2; exit 2; } ;;
		--status) STATUS_ONLY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "wt-lock: 알 수 없는 옵션: $1" >&2; exit 2 ;;
		*) [ -n "$NAME" ] && { echo "wt-lock: 이름은 하나만 준다 ($NAME, $1)" >&2; exit 2; }
		   NAME=$1; shift ;;
	esac
done

[ -n "$NAME" ] || { usage >&2; exit 2; }

# The name reaches the filesystem, so it is narrowed rather than trusted.
SAFE=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_.-' '-')
[ -n "$SAFE" ] || SAFE=lock

LOCK="$COMMON/wt-lock-$SAFE"
SELF=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# --- status ---------------------------------------------------------------------
holder_line() {
	local owner pid started now
	owner=$(cat "$LOCK/owner" 2>/dev/null || echo '?')
	pid=$(cat "$LOCK/pid" 2>/dev/null || echo 0)
	started=$(cat "$LOCK/started" 2>/dev/null || echo 0)
	now=$(date +%s)
	printf '%s (pid %s, %s째)' "$(basename "$owner")" "$pid" "$(human_secs $(( now - started )))"
}

human_secs() {
	local s=${1:-0}
	if [ "$s" -lt 60 ]; then printf '%ds' "$s"
	elif [ "$s" -lt 3600 ]; then printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
	else printf '%dh %02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi
}

if [ "$STATUS_ONLY" = 1 ]; then
	if [ -d "$LOCK" ]; then echo "$SAFE: $(holder_line)"; else echo "$SAFE: 비어 있음"; fi
	exit 0
fi

[ $# -gt 0 ] || { echo 'wt-lock: `--` 뒤에 실행할 명령이 없다' >&2; exit 2; }

# No repo, no lock — but still run the command. A missing lock must never be the
# reason someone's tests do not run.
if [ -z "$COMMON" ]; then "$@"; exit $?; fi

# --- acquire --------------------------------------------------------------------
# Stale reclaim: `kill -0` asks "is that pid alive and could I signal it", without
# sending anything. A holder killed with SIGKILL (or a machine that rebooted) left
# the directory behind, and without this the next run would wait forever on a
# process that no longer exists.
announced=0
waited_from=$(date +%s)
while ! mkdir "$LOCK" 2>/dev/null; do
	pid=$(cat "$LOCK/pid" 2>/dev/null || echo 0)
	case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
	if [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null; then
		echo "wt-lock: 죽은 홀더의 락을 회수한다 ($(holder_line))" >&2
		rm -rf "$LOCK"
		continue
	fi
	# A lock directory with no pid file is a half-built one from a process that
	# died between mkdir and the write. Give it one beat, then treat it as stale.
	if [ "$pid" = 0 ] && [ -d "$LOCK" ]; then
		sleep 1
		[ -f "$LOCK/pid" ] || { rm -rf "$LOCK"; continue; }
	fi

	now=$(date +%s)
	if [ -n "$WAIT_MAX" ] && [ $(( now - waited_from )) -ge "$WAIT_MAX" ]; then
		echo "wt-lock: ${WAIT_MAX}초를 기다렸지만 $SAFE 락이 풀리지 않았다 — $(holder_line)" >&2
		exit 75   # EX_TEMPFAIL: try again later, not a failure of the command
	fi
	# In place on a terminal; one line every 30s when the output is captured (a
	# model's tool call, a CI log). Rewriting the same line into a pipe came out as
	# "대기 2s — … 대기 4s — …" run together, and repeating it every two seconds
	# would bury a long wait in its own progress.
	if [ "$announced" = 0 ]; then
		echo "wt-lock: $SAFE — $(holder_line) 가 잡고 있다. 대기 중…" >&2
		announced=1
	elif [ -t 2 ]; then
		printf '\r  대기 %s — %s ' "$(human_secs $(( now - waited_from )))" "$(holder_line)" >&2
	elif [ $(( (now - waited_from) % 30 )) -lt 2 ]; then
		printf '  대기 %s — %s\n' "$(human_secs $(( now - waited_from )))" "$(holder_line)" >&2
	fi
	sleep 2
done
if [ "$announced" = 1 ] && [ -t 2 ]; then printf '\n' >&2; fi

STARTED=$(date +%s)
printf '%s' "$SELF"    > "$LOCK/owner"
printf '%s' "$$"       > "$LOCK/pid"
printf '%s' "$STARTED" > "$LOCK/started"
trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT INT TERM

# --- what the machine looked like when this started ------------------------------
# Read once, here. Re-reading per event would be a different machine each time,
# and the question the note answers is "what did this run start into".
OTHERS=0; OTHER_NAMES=""
if rows=$(wt_budget_other_worktrees 2>/dev/null) && [ -n "$rows" ]; then
	OTHERS=$(printf '%s\n' "$rows" | grep -c .)
	OTHER_NAMES=$(printf '%s\n' "$rows" | awk -F'\t' '{ n = $1; sub(/.*\//, "", n); printf "%s%s(%sMB)", (NR > 1 ? ", " : ""), n, $2 }')
fi
SWAP_AT_START=$(wt_budget_swap_free_mb 2>/dev/null || true)
LOAD_AT_START=$(wt_budget_load1 2>/dev/null || true)
NCPU=$(wt_budget_ncpu 2>/dev/null || true)

# --- run --------------------------------------------------------------------------
# Not `exec`: that would replace this shell and take the trap, the timing and the
# note with it.
"$@"
RC=$?
ELAPSED=$(( $(date +%s) - STARTED ))

# --- the timing note (W-7) ---------------------------------------------------------
# Silent by default. It speaks only when this run stands out against this repo's
# own history for this lock name, and even then it reports rather than prescribes:
# this script has no idea whether the command was Playwright, pytest or make, and
# "use fewer workers" is wrong advice on a runner that has no workers. The reader
# knows their repo; they need the facts they could not have collected afterwards.
#
# Only successful runs are recorded. A cancelled or failing run's duration says
# nothing about how long the work takes, and letting it into the baseline would
# make the next comparison meaningless.
note_timing() {
	[ "${WT_LOCK_QUIET:-}" = 1 ] && return 0
	[ "$RC" -eq 0 ] || return 0

	local dir="$COMMON/wt" f median ratio
	mkdir -p "$dir" 2>/dev/null || return 0
	f="$dir/timing-$SAFE.tsv"

	median=$(cut -f2 "$f" 2>/dev/null | sort -n | awk '
		{ a[n++] = $1 }
		END { if (n < 5) exit 1
		      print (n % 2) ? a[int(n/2)] : int((a[n/2 - 1] + a[n/2]) / 2) }')

	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$STARTED" "$ELAPSED" "$OTHERS" "${SWAP_AT_START:-}" "${LOAD_AT_START:-}" >> "$f"
	# Keep the file small enough to stay honest about "recent".
	tail -n 50 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"

	# No baseline yet, or nothing worth interrupting for.
	[ -n "$median" ] || return 0
	[ "$ELAPSED" -ge 60 ] || return 0
	[ "$median" -gt 0 ] || return 0
	[ $(( ELAPSED * 10 )) -gt $(( median * 15 )) ] || return 0

	ratio=$(awk -v e="$ELAPSED" -v m="$median" 'BEGIN { printf "%.1f", e / m }')
	{
		printf '\n[wt-lock %s] %s — 최근 중앙값 %s의 %s배.\n' \
			"$SAFE" "$(human_secs "$ELAPSED")" "$(human_secs "$median")" "$ratio"
		if [ "$OTHERS" -gt 0 ]; then
			printf '              시작할 때 다른 워크트리 %s개가 프로세스를 띄우고 있었다: %s\n' \
				"$OTHERS" "$OTHER_NAMES"
		fi
		printf '              그때 스왑 여유 %sMB, load %s/%s. (끄려면 WT_LOCK_QUIET=1)\n' \
			"${SWAP_AT_START:-?}" "${LOAD_AT_START:-?}" "${NCPU:-?}"
	} >&2
}
note_timing

exit $RC
