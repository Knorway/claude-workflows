#!/usr/bin/env bash
# A port offset that is this worktree's and stays this worktree's.
#
#   wt-port-offset          # e.g. 1370 — add it to whatever base ports you bind
#   wt-port-offset --check  # non-zero, and says so, if a sibling hashes the same
#
# WHY THIS LIVES IN wt. Every worktree is a full checkout of a repo whose dev and
# test servers bind fixed ports, so opening a second one puts two processes on the
# same number. What happens next is worse than a crash: a test runner configured
# to reuse an existing server attaches to whichever answers, and the second
# worktree ends up exercising the FIRST worktree's code against the first
# worktree's database — and reporting it as its own. Deriving the offset needs to
# know where the worktrees are, which is this plugin's job, not each repo's.
#
# WHY A HASH AND NOT AN INDEX. `git worktree list` position would be collision-free
# but it MOVES: add or remove a worktree and everyone after it shifts, so a server
# left running from an hour ago is suddenly on someone else's port — the failure
# this exists to prevent, reintroduced by the fix. The path hash never moves.
#
# The cost of that choice is that two paths can hash alike. `--check` is how you
# find out, and WT_PORT_OFFSET is how you step around it; nothing here tries to be
# clever about resolving it, because a silent reassignment would be the moving
# offset all over again.
#
# STEP is 10 so a repo can offset a whole family of related ports (8081→8091,
# 5177→5187) and keep them recognisable. SLOTS is deliberately much larger than
# anyone's worktree count: with a dozen worktrees the chance of any collision is a
# few percent, and `--check` catches the rest.

set -euo pipefail

STEP=10
SLOTS=1000

offset_for() {
	# cksum is POSIX and everywhere; the value only has to be stable and spread,
	# not cryptographic.
	local h
	h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
	echo $(( (h % SLOTS) * STEP ))
}

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "wt-port-offset: git 레포가 아니다" >&2
	exit 1
}

# An explicit override always wins, and is the documented way out of a collision.
if [ -n "${WT_PORT_OFFSET:-}" ]; then
	MINE=$WT_PORT_OFFSET
else
	MINE=$(offset_for "$TOP")
fi

case "${1:-}" in
	'')
		printf '%s\n' "$MINE"
		;;
	--check)
		rc=0
		while IFS= read -r wt; do
			[ -n "$wt" ] || continue
			[ "$wt" = "$TOP" ] && continue
			if [ "$(offset_for "$wt")" = "$MINE" ]; then
				echo "wt-port-offset: $MINE 이 $wt 와 겹친다 — WT_PORT_OFFSET 으로 하나를 옮길 것" >&2
				rc=1
			fi
		done <<-EOF
		$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
		EOF
		[ "$rc" = 0 ] && printf '%s\n' "$MINE"
		exit "$rc"
		;;
	-h|--help)
		sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		echo "wt-port-offset: 알 수 없는 옵션: $1 (--check)" >&2
		exit 2
		;;
esac
