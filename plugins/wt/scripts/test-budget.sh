#!/usr/bin/env bash
# PreToolUse hook. Denies a write that would push a repo's e2e suite past the
# budget that repo declared for itself.
#
# Why this is a *Pre* hook when every other control in this plugin is post-hoc:
# the other budgets describe damage that is cheap to undo. A convention doc that
# went long can be trimmed after the fact; the test ratchet reports a deleted
# assertion and a person decides. An e2e test is different — once it exists it is
# load-bearing, the ratchet in /wt:review step 5 then *protects* it from removal,
# and the suite only ever grows. The asymmetry is stated as intent in review.md
# ("잡히는 건 기존 테스트가 지워지는 쪽이고, 그게 이 검사의 목적이다"), which is
# correct for deletion and is exactly why addition needs a gate of its own.
#
# What it is not: a judgment about whether a test is good. It cannot read the
# test. It only knows the count the repo said it wanted, and the honest thing a
# count can do is make the model spend the next one deliberately. The denial
# message carries the repo's own placement rule so the model knows where the
# test should have gone instead.
#
# Silent in any repo that has not declared a budget. This plugin is used by
# repos that never asked for this.
#
# Bash 3.2: macOS ships it and `/usr/bin/env bash` finds it. No `mapfile`, no
# associative arrays.
set -euo pipefail

# jq is a hard dependency of the plugin, but this hook fires before EVERY write
# under `set -euo pipefail` — a missing jq must not turn every edit into a hook
# error. Same guard as claude-md-budget.sh and plan-nudge.sh.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -n "$path" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
{ [ -n "$cwd" ] && [ -d "$cwd" ]; } || cwd=$(dirname "$path")

# The CURRENT checkout's config, deliberately — `verify.sh` prefers the primary
# checkout's copy instead. The ladder wants stable commands across worktrees; a
# budget wants the branch you are standing on, so that a branch which changes the
# budget takes effect where the editing is happening rather than after merge.
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
cfg="$root/.claude/wt.json"
[ -f "$cfg" ] || exit 0

max=$(jq -r '.budgets.e2e.max // empty' "$cfg" 2>/dev/null || true)
[ -n "$max" ] || exit 0
case "$max" in ''|*[!0-9]*) exit 0 ;; esac

# Directory prefixes, relative to the repo root, that hold the budgeted suite.
dirs=$(jq -r '.budgets.e2e.paths[]? // empty' "$cfg" 2>/dev/null || true)
[ -n "$dirs" ] || exit 0

# Is the file being written inside one of them? Compare on the path relative to
# the repo root so a worktree's absolute prefix does not matter.
rel=${path#"$root"/}
in_scope=0
while IFS= read -r d; do
	[ -n "$d" ] || continue
	case "$rel" in "$d"/*) in_scope=1 ;; esac
done <<EOF
$dirs
EOF
[ "$in_scope" -eq 1 ] || exit 0

# `test(` and `it(` at the head of a statement, counted as occurrences rather
# than as matching lines — `-c` would collapse two on one line into one.
# `test.describe(` and `test.use(` have a dot before the paren and so do not
# match, which is what we want: a describe block is not a test.
count_in() {
	grep -oE '(^|[^.[:alnum:]_])(test|it)[[:space:]]*\(' | wc -l | tr -d ' '
}

# Everything the suite holds right now.
existing=0
while IFS= read -r d; do
	[ -n "$d" ] || continue
	[ -d "$root/$d" ] || continue
	n=$(find "$root/$d" -type f -name '*.spec.ts' -exec cat {} + 2>/dev/null | count_in)
	existing=$((existing + n))
done <<EOF
$dirs
EOF

# What this call would add. Write replaces the file, so its delta is the new
# content against whatever is on disk; Edit's delta is new_string against
# old_string. MultiEdit carries an array of those.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool" in
	Write)
		after=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' | count_in)
		before=0
		[ -f "$path" ] && before=$(count_in <"$path")
		;;
	Edit)
		after=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' | count_in)
		before=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' | count_in)
		;;
	MultiEdit)
		after=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")' | count_in)
		before=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.old_string] | join("\n")' | count_in)
		;;
	*) exit 0 ;;
esac

delta=$((after - before))
# Removing or rewriting in place is always allowed, including while over budget.
# The gate exists to slow growth, not to freeze a suite someone is shrinking.
[ "$delta" -gt 0 ] || exit 0

projected=$((existing + delta))
[ "$projected" -gt "$max" ] || exit 0

rule=$(jq -r '.budgets.e2e.rule // empty' "$cfg" 2>/dev/null || true)
[ -n "$rule" ] || rule='e2e는 브라우저가 필요한 것만 담는다. 나머지는 유닛이다.'

reason=$(cat <<EOF
[wt] e2e 예산 초과 — 이 쓰기는 거부됐다.

지금 ${existing}개, 이 변경이 ${delta}개를 더해 ${projected}개가 된다. 예산은 ${max}개다.

${rule}

이 테스트가 정말 e2e여야 하면 **다른 e2e를 먼저 지워라** — 그 판단을 하는 것이 이 예산의
목적이다. 대부분의 경우 답은 유닛 테스트이고, 그러면 이 훅은 아무 말도 하지 않는다.
예산 자체가 틀렸다고 판단하면 사용자에게 말해라. .claude/wt.json 의 budgets.e2e.max 를
네가 조용히 올리는 것은 이 장치를 없애는 것과 같다.
EOF
)

# PreToolUse is the only event that can refuse a call. `permissionDecision:
# "deny"` puts the reason in front of the model instead of running the tool.
jq -cn --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
