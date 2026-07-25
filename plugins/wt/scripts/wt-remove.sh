#!/usr/bin/env bash
# WorktreeRemove hook. Because wt-create.sh relocates worktrees outside the repo,
# Claude Code's own removal (aimed at .claude/worktrees/<name>) would miss ours
# and orphan them.
#
# Non-force on purpose: `git worktree remove` refuses when the worktree has
# uncommitted or unmerged work, which is exactly when it must NOT be deleted. On
# refusal we leave it in place — the branch and any PR are still there — and stay
# quiet. This hook cannot block removal and its failures are only logged in debug
# mode, so it always exits 0.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true; }

repo=$(j '.source_repo_path')
[ -n "$repo" ] || repo=$(j '.cwd')
[ -n "$repo" ] || repo=${CLAUDE_PROJECT_DIR:-$PWD}

main=$(wt_primary "$repo")
[ -n "$main" ] || exit 0
root=$(wt_root "$main")

# `worktree_path` is the documented field; the rest are defensive.
dir=$(j '.worktree_path')
[ -n "$dir" ] || dir=$(j '.directory // .path // .worktreePath')
if [ -z "$dir" ]; then
	name=$(j '.name')
	[ -n "$name" ] && dir="$root/$name"
fi
[ -n "$dir" ] || exit 0

# Only ever touch our own tree.
case "$(wt_abs "$dir")/" in
	"$(wt_abs "$root")"/*) ;;
	*) exit 0 ;;
esac

git -C "$main" worktree remove "$dir" >/dev/null 2>&1 || true
exit 0
