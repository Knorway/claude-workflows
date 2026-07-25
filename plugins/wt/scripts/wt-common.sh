#!/usr/bin/env bash
# Shared helpers for the wt plugin. Sourced by the other scripts, never run.
#
# Everything here answers one of three questions: where is the primary checkout,
# where do this repo's worktrees live, and what does this repo want provisioned.
# The answers come from git and from an OPTIONAL `.claude/wt.json` in the repo —
# a plugin with no config must still work, so every lookup falls back.
#
# Config is read from a file in the repo rather than from the plugin's own
# `pluginConfigs`: Claude Code ignores `pluginConfigs` in project settings (a
# cloned repo could otherwise inject values into hook commands), so per-repo
# settings have to be a plain file the scripts read themselves.

# Primary checkout of the repo containing $1 — the first entry of `worktree
# list` is always the primary one. Empty when $1 isn't in a git repo.
wt_primary() {
	git -C "${1:-.}" worktree list --porcelain 2>/dev/null |
		awk '/^worktree /{print $2; exit}'
}

# Canonical absolute path. Falls back to the input when the path doesn't exist
# yet (a worktree we're about to create), which is fine for string comparison.
wt_abs() {
	if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s\n' "$1"; fi
}

# One field out of <main>/.claude/wt.json. A missing file, missing key, absent
# jq or malformed JSON all yield the empty string, so callers just use their own
# default — the config is never allowed to break a hook.
wt_cfg() {
	local main=$1 filter=$2 f="$1/.claude/wt.json"
	[ -f "$f" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "$filter // empty" "$f" 2>/dev/null || true
}

# Same, for an array field: one entry per line.
wt_cfg_list() {
	local main=$1 filter=$2 f="$1/.claude/wt.json"
	[ -f "$f" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "($filter // []) | .[]" "$f" 2>/dev/null || true
}

# Where this repo's worktrees live. `worktreeRoot` in wt.json wins (absolute,
# ~-prefixed, or relative to the repo); otherwise a sibling directory beside the
# repo: /path/to/repo -> /path/to/repo-wt.
#
# OUTSIDE the repo on purpose. Claude Code's default is .claude/worktrees/<name>
# inside it, which puts a second copy of node_modules under the main checkout's
# file watchers — duplicate-module and nested-watch-root failures in any JS repo
# with a dev server.
wt_root() {
	local main=$1 root
	root=$(wt_cfg "$main" '.worktreeRoot')
	case "$root" in
		'')  printf '%s-wt\n' "$main" ;;
		/*)  printf '%s\n' "$root" ;;
		'~'/*) printf '%s\n' "$HOME/${root#\~/}" ;;
		*)   printf '%s\n' "$main/$root" ;;
	esac
}

# May this repo's `provision.run` commands actually run on this machine?
#
# Every other wt.json key names a path to copy; `run` names a COMMAND, and the
# file is committed — so a cloned repo would otherwise get silent code execution
# the first time someone opens a worktree session in it. Claude Code puts
# project hooks behind a trust prompt for exactly this reason; a hook of ours
# reading a repo file must not become a way around that prompt.
#
# The machine owner opts in once per repo, by absolute path:
#
#   echo /path/to/repo >> ~/.claude/wt-run-allow
#
# Blank lines and `#` comments are ignored. Nothing else in provisioning is
# gated — copying and cloning paths cannot execute anything.
wt_run_allowed() {
	local main=$1 f="${WT_RUN_ALLOW_FILE:-$HOME/.claude/wt-run-allow}" line
	[ -f "$f" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		line=${line%"${line##*[! ]}"}                 # trailing spaces
		[ "$(wt_abs "$line")" = "$(wt_abs "$main")" ] && return 0
	done < "$f"
	return 1
}

# Branch new worktrees are cut from: config, else main, else master, else the
# remote's HEAD. Prints nothing if none of those exist (caller uses HEAD).
wt_base_branch() {
	local main=$1 b
	b=$(wt_cfg "$main" '.baseBranch')
	if [ -n "$b" ]; then printf '%s\n' "$b"; return; fi
	for b in main master; do
		git -C "$main" show-ref --verify --quiet "refs/heads/$b" && { printf '%s\n' "$b"; return; }
	done
	b=$(git -C "$main" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
	printf '%s\n' "${b#origin/}"
}
