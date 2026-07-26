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

# Hook mode talks to the user through a systemMessage; by hand, plain stdout.
# The no-jq branch exists because the one message that matters most — "jq is
# missing" — would otherwise be the one message we cannot print. Messages here
# are our own literals, and the escape covers the two characters JSON forbids
# raw in a string anyway.
emit() {
	if [ "$hook" != 1 ]; then printf '%s\n' "$1"; return; fi
	if command -v jq >/dev/null 2>&1; then
		jq -nc --arg m "$1" '{systemMessage:$m}'
	else
		printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
	fi
}

main=$(wt_primary "$wt")
[ -n "$main" ] || exit 0                      # not a git repo: nothing to do
[ "$(wt_abs "$main")" != "$(wt_abs "$wt")" ] || exit 0   # primary checkout

# Config reads degrade to empty without jq, which would otherwise look like a
# repo that asked for nothing — a worktree missing its .env and its generated
# code, reported as a success. Carried into the final message rather than
# emitted here: a hook must write ONE JSON object, not two.
warn=""
if [ -f "$main/.claude/wt.json" ] && ! command -v jq >/dev/null 2>&1; then
	warn="jq가 없어 .claude/wt.json을 읽지 못했다(복사·생성·실행 건너뜀). "
fi

# Copy-on-write where the filesystem supports it, a plain copy where it doesn't.
clone_dir() {
	cp -c -R "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

did=""
failed=""
skipped_runs=""

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

# With no `copy` configured we cannot know what this repo's worktrees need — and
# the failure is silent: a worktree missing its .env builds, runs, and is wrong.
# So look for the shape of the problem (gitignored config sitting in the primary
# but absent here) and NAME it. Deliberately report-only: copying a file the repo
# never asked us to copy would move secrets around on a guess.
if [ -z "$(wt_cfg_list "$main" '.provision.copy')" ]; then
	# `glob` magic is required on the EXCLUDE too. Without it `**` is literal and
	# the exclude matches nothing, so a package shipping a `.env` fixture eats the
	# list and the one file we meant to name never gets printed.
	candidates=$(git -C "$main" ls-files --others --ignored --exclude-standard -- \
		':(glob)**/.env' ':(glob)**/.env.*' ':(glob)**/*.local' \
		':(exclude,glob)**/node_modules/**' ':(exclude,glob)**/vendor/**' 2>/dev/null || true)
	# The cap goes AFTER the "is it missing here" filter, never before. Capping the
	# candidates first meant five files that were already provisioned could fill the
	# quota and the sixth — the one actually absent — was never looked at, which
	# silences the exact warning this block exists to print.
	miss=""; nmiss=0
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		[ -e "$wt/$rel" ] && continue
		nmiss=$((nmiss + 1))
		[ "$nmiss" -le 5 ] && miss="$miss $rel"
	done <<EOF
$candidates
EOF
	if [ "$nmiss" -gt 5 ]; then miss="$miss 외 $((nmiss - 5))개"; fi
	# Braces are load-bearing: in a UTF-8 locale bash reads `$warn메인` as one
	# identifier and dies with "unbound variable" under `set -u`.
	[ -n "$miss" ] && warn="${warn}메인에 있는 설정 파일이 이 워크트리엔 없다($miss). 필요하면 .claude/wt.json의 provision.copy에 넣을 것. "
fi

# Directories a generator refuses to create for itself — a codegen tool's output
# directory (relay's artifactDirectory, protoc's --*_out, sqlc's gen) that the
# tool expects to already exist. Their absence is also what tells us the
# `run` commands below have never been executed in this worktree.
fresh=0
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -d "$wt/$rel" ] && continue
	mkdir -p "$wt/$rel" && fresh=1
done <<EOF
$(wt_cfg_list "$main" '.provision.mkdir')
EOF

# `run` is the one key that executes repo-supplied strings, so it is the one key
# that needs the machine owner's consent. Claude Code makes project hooks in
# .claude/settings.json go through a trust prompt; a repo file read by our own
# hook would otherwise be a second hook channel with no such gate — clone a
# hostile repo, open one worktree session, and its commands run silently.
# So: the repo may PROPOSE commands, the machine owner opts in per repo, once.
runs=$(wt_cfg_list "$main" '.provision.run')
if [ -n "$runs" ] && { [ "$fresh" = 1 ] || [ -n "$did" ]; }; then
	if wt_run_allowed "$main"; then
		while IFS= read -r cmd; do
			[ -n "$cmd" ] || continue
			if (cd "$wt" && eval "$cmd" >/dev/null 2>&1); then did="$did ${cmd%% *}"
			else failed="$failed ${cmd%% *}"; fi
		done <<EOF
$runs
EOF
	else
		skipped_runs=$(printf '%s' "$runs" | tr '\n' ',' | sed 's/,$//')
	fi
fi

if [ -n "$skipped_runs" ]; then
	warn="$warn.claude/wt.json의 run을 실행하지 않았다($skipped_runs). 이 레포에서 허용하려면 \`echo '$main' >> ~/.claude/wt-run-allow\`. "
fi

if [ -n "$failed" ]; then
	emit "worktree 프로비저닝 경고: ${warn}실패:$failed${did:+ / 완료:$did}"
elif [ -n "$warn" ]; then
	emit "worktree 프로비저닝 경고: ${warn}완료:${did:- 없음}"
elif [ -n "$did" ]; then
	emit "worktree 프로비저닝 완료 —$did"
elif [ "$hook" != 1 ]; then
	emit "already provisioned"
fi
exit 0
