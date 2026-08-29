#!/usr/bin/env bash
# What can this machine take on right now?
#
#   wt-budget            # one fact per line, for a person
#   wt-budget --json     # for a repo's own runner script
#
# WHY THIS LIVES IN wt. Opening several worktrees is what this plugin is for, and
# the bill for that arrives as memory: three tabs each running a dev server and a
# test runner is three copies of everything. A repo trying to size its own test
# run cannot see the other tabs — it does not know where the sibling worktrees
# are, and guessing from process names catches the wrong processes on a machine
# that has two projects open. `git worktree list` is the authority and this
# plugin is already standing on it, so the question belongs here.
#
# WHAT IT REFUSES TO DO: tell you how many workers to use. It cannot. It does not
# know whether the runner is Playwright, vitest, pytest or a Makefile, and
# "workers" is not a concept all of them have. It reports; the caller — who knows
# what one worker costs in THIS repo — divides. A tip that assumes the tool is
# wrong advice on the next project.
#
# TWO MEASUREMENTS THAT LOOK OBVIOUS AND ARE WRONG. Both were measured on an 8GB
# M1 while one worktree ran its e2e suite:
#
#   - `Pages free` alone (which is all node's os.freemem() reports) said 188MB
#     while `memory_pressure -Q` said 46% free. It ignores inactive and
#     speculative pages, which are reclaimable. Free is not availability.
#   - `kern.memorystatus_vm_pressure_level` stayed at 1 (normal) through a run
#     that was compressing 300-500 MB/s, and `memory_pressure -Q` swung between
#     54% and 35% inside that same run. Neither can carry a decision alone.
#
# So the numbers a caller should branch on are the DETERMINISTIC ones —
# otherWorktrees, swapFreeMB, load1 — and the two gauges ride along as context
# for a human reading the line. That ordering is the whole design.
#
# Sourced by lock.sh (for its timing note) as well as run by bin/wt-budget, so
# collection lives in functions and the CLI sits behind the usual guard at the
# bottom. Every helper degrades to an empty value rather than failing: a budget
# that died on an unexpected `sysctl` would take its caller's test run with it.

# --- measurement ---------------------------------------------------------------
# macOS for now. Each helper prints nothing when it cannot measure, and callers
# treat empty as "unknown" rather than zero — the difference matters, because
# zero swap free means "stop" and unknown means "carry on blind".

_wt_pagesize() { sysctl -n hw.pagesize 2>/dev/null || echo 4096; }

# vm_stat prints "Pages free:   3609." — trailing dot, leading spaces.
_wt_vmstat_pages() {
	vm_stat 2>/dev/null | awk -F: -v k="$1" '
		index($1, k) == 1 { gsub(/[^0-9]/, "", $2); print $2; exit }'
}

# Reclaimable, not merely free. inactive and speculative pages are handed back
# under pressure; counting only `free` is the mistake documented in the header.
wt_budget_free_mb() {
	local psz f i s p
	psz=$(_wt_pagesize)
	f=$(_wt_vmstat_pages "Pages free")
	i=$(_wt_vmstat_pages "Pages inactive")
	s=$(_wt_vmstat_pages "Pages speculative")
	p=$(_wt_vmstat_pages "Pages purgeable")
	[ -n "$f" ] || return 0
	echo $(( ( (f + ${i:-0} + ${s:-0} + ${p:-0}) * psz ) / 1048576 ))
}

# Physical RAM minus wired: the ceiling user processes can ever share.
wt_budget_user_available_mb() {
	local total psz w
	total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
	[ -n "$total" ] || return 0
	psz=$(_wt_pagesize)
	w=$(_wt_vmstat_pages "Pages wired down")
	[ -n "$w" ] || return 0
	echo $(( (total - w * psz) / 1048576 ))
}

# "total = 7168.00M  used = 6542.00M  free = 626.00M  (encrypted)"
wt_budget_swap_free_mb() {
	sysctl -n vm.swapusage 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++)
			if ($i == "free") { gsub(/[^0-9.]/, "", $(i+2)); printf "%.0f\n", $(i+2); exit } }'
}

# "{ 14.82 12.34 10.11 }"
wt_budget_load1() {
	sysctl -n vm.loadavg 2>/dev/null | awk '{ gsub(/[{}]/, ""); print $1 }'
}

wt_budget_ncpu()     { sysctl -n hw.logicalcpu 2>/dev/null || true; }
wt_budget_pressure() { sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || true; }

# --- the part only this plugin can answer ---------------------------------------
# Which OTHER worktrees of this repo are holding processes, and how much.
#
# `git worktree list` is what makes this trustworthy. Matching on process names
# ("node", "vite") would sweep in a second project's dev server and bill this
# repo for it; matching on the worktree's absolute path cannot, because that path
# is in the command line of anything started inside it — verified, a sibling's
# dev server appears as
#   .../worktrees/abstract-floating-owl/dashboard/node_modules/.bin/react-router dev --port 5174
#
# One `ps` for the whole answer. Per-worktree pgrep was the first version and
# cost a subprocess per worktree on a machine that was already thrashing.
#
# One TSV row per other worktree that has processes: path, rssMB, count, sample.
# Silent when there are none.
# $1: a worktree path to leave out, or empty for all of them. `wt-doctor` wants
# the whole picture including the tree it is standing in; the budget wants only
# the competition.
wt_budget_worktree_procs() {
	local exclude=${1:-} wts
	# LONGEST PATH FIRST, and each process counted once, against the most specific
	# worktree that matches it. Claude Code's default worktree location is
	# `<repo>/.claude/worktrees/<name>`, i.e. INSIDE the primary checkout — so the
	# primary's path is a prefix of every worktree's, and a naive per-worktree scan
	# billed every worktree's processes to the primary as well. Observed: the
	# primary and a worktree both reporting the same 368MB / 8 processes, which is
	# one set of processes counted twice.
	wts=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' |
		awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
	[ -n "$wts" ] || return 0

	# Through the environment, not `-v`: awk's -v assignment cannot carry a
	# newline, and this list is one path per line.
	ps -Ao rss=,command= 2>/dev/null | WT_PATHS="$wts" awk -v exclude="$exclude" '
		BEGIN { n = split(ENVIRON["WT_PATHS"], W, "\n") }
		{
			for (i = 1; i <= n; i++) {
				if (W[i] == "" || index($0, W[i]) == 0) continue
				if (exclude != "" && W[i] == exclude) break
				rss[W[i]] += $1
				cnt[W[i]] += 1
				if (cnt[W[i]] <= 3) {
					cmd = $2
					sub(/.*\//, "", cmd)
					names[W[i]] = names[W[i]] (names[W[i]] ? ", " : "") cmd
				}
				break
			}
		}
		END { for (w in rss) printf "%s\t%d\t%d\t%s\n", w, rss[w] / 1024, cnt[w], names[w] }'
}

wt_budget_other_worktrees() {
	wt_budget_worktree_procs "$(git rev-parse --show-toplevel 2>/dev/null)"
}

# --- output --------------------------------------------------------------------
# Hand-rolled JSON. jq is optional everywhere else in this plugin (verify.sh
# guards on it) and a budget that needed it would be unavailable on exactly the
# machines that are struggling. Only paths can contain anything worth escaping.
_wt_json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
_wt_num_or_null() { if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi; }

wt_budget_json() {
	local avail free swap load ncpu press rows first=1 path rss n names
	avail=$(wt_budget_user_available_mb); free=$(wt_budget_free_mb)
	swap=$(wt_budget_swap_free_mb);       load=$(wt_budget_load1)
	ncpu=$(wt_budget_ncpu);               press=$(wt_budget_pressure)
	rows=$(wt_budget_other_worktrees)

	printf '{"userAvailableMB":%s,"freeMB":%s,"swapFreeMB":%s,"load1":%s,"ncpu":%s,"pressure":%s,"otherWorktrees":[' \
		"$(_wt_num_or_null "$avail")" "$(_wt_num_or_null "$free")" \
		"$(_wt_num_or_null "$swap")"  "$(_wt_num_or_null "$load")" \
		"$(_wt_num_or_null "$ncpu")"  "$(_wt_num_or_null "$press")"
	if [ -n "$rows" ]; then
		while IFS=$'\t' read -r path rss n names; do
			[ -n "$path" ] || continue
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"path":%s,"rssMB":%s,"procs":%s,"sample":%s}' \
				"$(_wt_json_str "$path")" "$rss" "$n" "$(_wt_json_str "$names")"
		done <<-EOF
		$rows
		EOF
	fi
	printf ']}\n'
}

wt_budget_human() {
	local avail free swap load ncpu press rows path rss n names
	avail=$(wt_budget_user_available_mb); free=$(wt_budget_free_mb)
	swap=$(wt_budget_swap_free_mb);       load=$(wt_budget_load1)
	ncpu=$(wt_budget_ncpu);               press=$(wt_budget_pressure)
	rows=$(wt_budget_other_worktrees)

	printf '유저 가용   %s MB  (물리 − wired)\n' "${avail:-?}"
	printf '회수 가능   %s MB  (free+inactive+speculative+purgeable)\n' "${free:-?}"
	printf '스왑 여유   %s MB\n' "${swap:-?}"
	printf 'load1       %s / %s\n' "${load:-?}" "${ncpu:-?}"
	printf 'pressure    %s  (1=normal — 단독으로 믿지 말 것, 이 파일 헤더)\n' "${press:-?}"
	if [ -n "$rows" ]; then
		echo '다른 워크트리:'
		while IFS=$'\t' read -r path rss n names; do
			[ -n "$path" ] || continue
			printf '  %-34s %6s MB  프로세스 %s  (%s)\n' "$(basename "$path")" "$rss" "$n" "$names"
		done <<-EOF
		$rows
		EOF
	else
		echo '다른 워크트리: 프로세스 없음'
	fi
}

# --- CLI ------------------------------------------------------------------------
# Only when run, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -euo pipefail
	case "${1:-}" in
		--json)     wt_budget_json ;;
		''|--human) wt_budget_human ;;
		-h|--help)  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' ;;
		*) echo "wt-budget: 알 수 없는 옵션: $1 (--json | --human)" >&2; exit 2 ;;
	esac
fi
