#!/usr/bin/env bash
# WorktreeCreate hook — and, run by hand, the shell-only way to cut a worktree.
#
# Claude Code delegates creation to this hook when one is registered: it hands us
# the path it WOULD have used (`worktree_path`, inside the repo at
# .claude/worktrees/<name>) and the repo (`source_repo_path`), we create the
# worktree ourselves wherever we like, and echo ONLY the final path on stdout.
# Any non-zero exit aborts worktree creation, so this script never hard-fails on
# a surprise — it falls back and keeps going.
#
# Why relocate: the default location is inside the repo, so the main checkout's
# file watchers (Metro, webpack, watchman) crawl each worktree's node_modules —
# a second copy of the same modules — and a worktree running its own dev server
# nests its watch root inside the main one. Ours go to a sibling directory
# outside the repo (see wt_root), where each checkout is an independent root.
#
#   wt-create.sh                # hook: reads the JSON payload on stdin
#   wt-create.sh <name>         # by hand: create + provision, no Claude session
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

name=${1:-}
repo=""

if [ -z "$name" ]; then
	# Hook mode. Read `.name` first — Claude Code has sent it in practice — and
	# fall back to the documented `worktree_path` basename.
	input=$(cat)
	name=$(printf '%s' "$input" | jq -r '.name // empty' 2>/dev/null || true)
	if [ -z "$name" ]; then
		wtp=$(printf '%s' "$input" | jq -r '.worktree_path // empty' 2>/dev/null || true)
		[ -n "$wtp" ] && name=$(basename "$wtp")
	fi
	repo=$(printf '%s' "$input" | jq -r '.source_repo_path // .cwd // empty' 2>/dev/null || true)
	if [ -z "$name" ]; then
		# Never block creation on a schema surprise: log the payload and make one up.
		echo "WorktreeCreate: no .name/.worktree_path in hook input; raw=$input" >&2
		name="wt-$(date +%Y%m%d-%H%M%S)"
	fi
fi

[ -n "$repo" ] || repo=${CLAUDE_PROJECT_DIR:-$PWD}
main=$(wt_primary "$repo")
[ -n "$main" ] || { echo "wt-create: not a git repo: $repo" >&2; exit 1; }

root=$(wt_root "$main")
dir="$root/$name"
branch="worktree-$name"

# Reuse an existing one: reopening a tab for the same worktree, or one this
# script made earlier.
if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
	printf '%s\n' "$dir"
	exit 0
fi

mkdir -p "$root"

# The branch may outlive its worktree (removed the dir, kept the branch) — check
# it out instead of failing on "already exists".
if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
	git -C "$main" worktree add "$dir" "$branch" 1>&2 || exit 2
else
	base=$(wt_base_branch "$main")
	git -C "$main" worktree add "$dir" -b "$branch" ${base:+"$base"} 1>&2 || exit 2
fi

# Hook mode stops here: the SessionStart hook provisions the new worktree a
# moment later. Run by hand there is no session, so provision now.
if [ "${1:-}" != "" ]; then
	bash "$(dirname "${BASH_SOURCE[0]}")/wt-provision.sh" "$dir" >&2
	{
		echo
		echo "worktree : $dir"
		echo "branch   : $branch"
		echo "done     : git worktree remove \"$dir\""
	} >&2
fi

printf '%s\n' "$dir"
