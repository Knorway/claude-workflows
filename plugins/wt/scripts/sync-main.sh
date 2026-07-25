#!/usr/bin/env bash
# SessionStart hook. Keep the PRIMARY checkout's base branch current with origin,
# so a merged workflow is actually present in the working tree instead of
# silently rotting behind origin — which is exactly what breaks the first real
# multi-tab run: new worktrees get cut from a stale base.
#
# Acts ONLY in the primary checkout, ONLY on the base branch, ONLY as a
# fast-forward. It does NOT gate on a clean tree: the primary checkout is almost
# always dirty, and `git merge --ff-only` is inherently safe — it never
# overwrites local changes and aborts on any conflict. `git pull --ff-only` is
# avoided because some fetch configs make it error with "Cannot fast-forward to
# multiple branches"; an explicit merge is used instead.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

cwd=$(jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd=$PWD

main=$(wt_primary "$cwd")
[ -n "$main" ] || exit 0
[ "$(wt_abs "$main")" = "$(wt_abs "$cwd")" ] || exit 0   # skip worktrees

base=$(wt_base_branch "$main")
[ -n "$base" ] || exit 0
[ "$(git -C "$cwd" branch --show-current 2>/dev/null)" = "$base" ] || exit 0

git -C "$cwd" fetch --quiet origin "$base" 2>/dev/null || exit 0
# ff only makes sense when HEAD is an ancestor of the remote branch and strictly behind.
git -C "$cwd" merge-base --is-ancestor HEAD "origin/$base" 2>/dev/null || exit 0
[ "$(git -C "$cwd" rev-parse HEAD)" != "$(git -C "$cwd" rev-parse "origin/$base")" ] || exit 0

if git -C "$cwd" merge --ff-only "origin/$base" >/dev/null 2>&1; then
	jq -nc --arg m "$base fast-forward: origin/$base 반영됨" '{systemMessage:$m}'
fi
exit 0
