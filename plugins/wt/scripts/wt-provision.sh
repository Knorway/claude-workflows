#!/usr/bin/env bash
# Fill a fresh worktree with the gitignored things it needs to actually build,
# so `claude --worktree` just works with no project-specific command to remember.
#
#   wt-provision.sh <worktree-dir>   # by hand
#   wt-provision.sh                  # SessionStart hook: reads .cwd on stdin
#
# Idempotent: every step is guarded, so re-running is a fast no-op. No-op in the
# primary checkout too, which is where most sessions start.
#
# What gets provisioned comes from <repo>/.claude/wt.json:
#
#   { "provision": { "clone": [...], "copy": [...], "mkdir": [...], "run": [...] } }
#
# With no config, `node_modules` is cloned if the primary checkout has one, and
# nothing else happens.
#
# Why CLONE node_modules instead of symlinking it: a package directory typically
# holds RELATIVE symlinks (yarn/pnpm workspace links like
# node_modules/@scope/pkg -> ../../packages/pkg). Symlink the whole directory
# and those inner links resolve back through it into the MAIN checkout — the
# worktree then silently reads main's sources. A copy makes them resolve inside
# the worktree. On APFS `cp -c` is copy-on-write, so a multi-gigabyte
# node_modules costs ~0 real disk and needs no reinstall.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

hook=0
wt=${1:-}
if [ -z "$wt" ]; then
	hook=1
	wt=$(jq -r '.cwd // empty' 2>/dev/null || true)
	[ -n "$wt" ] || wt=$PWD
fi

emit() {   # hook mode talks to the user through a systemMessage; by hand, stdout
	if [ "$hook" = 1 ]; then jq -nc --arg m "$1" '{systemMessage:$m}'
	else printf '%s\n' "$1"; fi
}

main=$(wt_primary "$wt")
[ -n "$main" ] || exit 0                      # not a git repo: nothing to do
[ "$(wt_abs "$main")" != "$(wt_abs "$wt")" ] || exit 0   # primary checkout

# Copy-on-write where the filesystem supports it, a plain copy where it doesn't.
clone_dir() {
	cp -c -R "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

did=""
failed=""

clones=$(wt_cfg_list "$main" '.provision.clone')
[ -n "$clones" ] || { [ -d "$main/node_modules" ] && clones="node_modules"; }

while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -e "$main/$rel" ] || continue           # not present upstream: skip quietly
	[ -e "$wt/$rel" ] && continue             # already provisioned
	mkdir -p "$(dirname "$wt/$rel")"
	if clone_dir "$main/$rel" "$wt/$rel"; then did="$did $rel"; else failed="$failed $rel"; fi
done <<EOF
$clones
EOF

while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -f "$main/$rel" ] || continue
	[ -e "$wt/$rel" ] && continue
	mkdir -p "$(dirname "$wt/$rel")"
	if cp "$main/$rel" "$wt/$rel"; then did="$did $(basename "$rel")"; else failed="$failed $rel"; fi
done <<EOF
$(wt_cfg_list "$main" '.provision.copy')
EOF

# Directories a generator refuses to create for itself (relay-compiler's
# artifactDirectory is the usual one). Their absence is also what tells us the
# `run` commands below have never been executed in this worktree.
fresh=0
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -d "$wt/$rel" ] && continue
	mkdir -p "$wt/$rel" && fresh=1
done <<EOF
$(wt_cfg_list "$main" '.provision.mkdir')
EOF

runs=$(wt_cfg_list "$main" '.provision.run')
if [ -n "$runs" ] && { [ "$fresh" = 1 ] || [ -n "$did" ]; }; then
	while IFS= read -r cmd; do
		[ -n "$cmd" ] || continue
		if (cd "$wt" && eval "$cmd" >/dev/null 2>&1); then did="$did ${cmd%% *}"
		else failed="$failed ${cmd%% *}"; fi
	done <<EOF
$runs
EOF
fi

if [ -n "$failed" ]; then
	emit "worktree 프로비저닝 경고 — 실패:$failed${did:+ / 완료:$did}"
elif [ -n "$did" ]; then
	emit "worktree 프로비저닝 완료 —$did"
elif [ "$hook" != 1 ]; then
	emit "already provisioned"
fi
exit 0
