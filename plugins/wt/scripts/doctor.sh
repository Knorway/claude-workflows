#!/usr/bin/env bash
# What is still running, and which worktree does it belong to?
#
#   wt-doctor          # list it
#   wt-doctor --kill   # stop what belongs to worktrees that are gone
#
# WHY. A test runner stops the servers IT started; it has no idea about the ones
# left by a run that was interrupted, and neither does `git worktree remove`,
# which deletes a directory and walks away from whatever was serving out of it.
# Measured twice while writing this: ~600MB of dev server, workerd and sqld still
# resident for worktrees nobody was using. On a machine where one test run
# already sits at the edge of swap, that is the difference between a suite that
# passes and one that times out — and the timeout looks like a flaky test.
#
# WHY `git worktree list` MAKES THIS HONEST. Matching on process names would sweep
# in a second project's dev server. Matching on the worktree's absolute path — which
# is in the command line of anything started inside it — cannot.
#
# **It shows, and only kills when asked, and even then only for worktrees that no
# longer exist.** The complaint that started this was a session killing a server
# another tab was using; a doctor that guessed would be that same bug wearing a
# stethoscope. A live worktree's processes are listed and left alone: it is not
# possible to tell from out here whether that dev server is garbage or is the one
# someone is looking at.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/budget.sh"

KILL=0
case "${1:-}" in
	'') ;;
	--kill) KILL=1 ;;
	-h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "wt-doctor: 알 수 없는 옵션: $1 (--kill)" >&2; exit 2 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || { echo "wt-doctor: git 레포가 아니다" >&2; exit 1; }

SELF=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
rows=$(wt_budget_worktree_procs "")

if [ -z "$rows" ]; then
	echo "이 레포의 워크트리에서 도는 프로세스가 없다."
	exit 0
fi

total=0
orphan_paths=""
while IFS=$'\t' read -r path rss n names; do
	[ -n "$path" ] || continue
	total=$(( total + rss ))
	mark="  "
	note=""
	if [ "$path" = "$SELF" ]; then
		mark="* "
		note="  ← 여기"
	elif [ ! -d "$path" ]; then
		# The directory is gone but something started inside it is still resident.
		# Nothing will ever come back for these.
		note="  ← 워크트리가 없다"
		orphan_paths="$orphan_paths$path"$'\n'
	fi
	printf '%s%-32s %6s MB  프로세스 %-3s (%s)%s\n' "$mark" "$(basename "$path")" "$rss" "$n" "$names" "$note"
done <<-EOF
$rows
EOF

printf '합계 %s MB\n' "$total"

orphans=$(printf '%s' "$orphan_paths" | grep -c . || true)
if [ "${orphans:-0}" = 0 ]; then
	echo
	echo "정리할 것은 없다 — 전부 지금 있는 워크트리의 것이다."
	echo "살아 있는 워크트리의 서버는 여기서 건드리지 않는다(그 탭이 쓰고 있을 수 있다)."
	exit 0
fi

if [ "$KILL" = 0 ]; then
	echo
	echo "워크트리가 사라졌는데 남아 있는 것이 ${orphans}건 있다. 정리하려면: wt-doctor --kill"
	exit 0
fi

# SIGTERM only. These are dev servers and databases; something mid-write deserves
# the chance to finish, and anything that ignores TERM is a bug worth seeing.
echo
while IFS= read -r path; do
	[ -n "$path" ] || continue
	pids=$(ps -Ao pid=,command= 2>/dev/null | awk -v wt="$path" 'index($0, wt) { print $1 }')
	[ -n "$pids" ] || continue
	echo "정리: $(basename "$path") — pid $(printf '%s' "$pids" | tr '\n' ' ')"
	# shellcheck disable=SC2086
	kill $pids 2>/dev/null || true
done <<-EOF
$orphan_paths
EOF
echo "TERM 을 보냈다. 남아 있으면 다시 확인할 것: wt-doctor"
