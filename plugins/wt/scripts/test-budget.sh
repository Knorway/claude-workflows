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
# ## It counts cost, not tests
#
# Counting tests was the first version and it optimised the wrong thing: a spec
# that boots a browser five times and rasterises at print resolution costs tens
# of seconds and counted as five, while a byte check that costs a tenth of a
# second also counted as one. The expensive thing went through and the cheap one
# hit the ceiling — the exact inversion of what a budget is for.
#
# So the repo declares what its expensive calls are and what they are worth:
#
#     "budgets": { "e2e": {
#       "paths":   ["web/e2e"],
#       "maxCost": 260,
#       "cost":    { "test": 1, "openEditor": 2, "sendOrder": 6 }
#     }}
#
# `test` is the per-test base (`test(` and `it(`); every other key is an
# identifier counted where it is called. Weights are integers and the unit is
# whatever the repo says it is — seconds is the honest choice, because then the
# ceiling is a number a person can compare against a suite they have watched run.
#
# **It is a budget, not a profiler, and it is biased low on purpose.** A helper
# called once in a `beforeEach` counts once even though it runs per test. Fixing
# that needs scope parsing, and the bias is harmless here: the ceiling is set from
# the same measurement, so both sides carry it. Never read the number as a
# prediction of how long the suite takes.
#
# A repo that declares `max` and no `cost` keeps the old behaviour — a plain test
# count — so nothing that was configured before this needs to change.
#
# What it still is not: a judgment about whether a test is good. It cannot read
# the test. The denial message carries the repo's own placement rule and the
# breakdown of what this write would add, so the model knows both where the test
# should have gone and which call made it expensive.
#
# Silent in any repo that has not declared a budget.
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

# Directory prefixes, relative to the repo root, that hold the budgeted suite.
dirs=$(jq -r '.budgets.e2e.paths[]? // empty' "$cfg" 2>/dev/null || true)
[ -n "$dirs" ] || exit 0

# `cost` is the weighted axis; `max` is the older count-only one. Exactly one of
# them decides, and `cost` wins when both are present.
weights=$(jq -r '.budgets.e2e.cost // {} | to_entries[] | "\(.key) \(.value)"' "$cfg" 2>/dev/null || true)
if [ -n "$weights" ]; then
	ceiling=$(jq -r '.budgets.e2e.maxCost // empty' "$cfg" 2>/dev/null || true)
	unit=' (비용)'
else
	ceiling=$(jq -r '.budgets.e2e.max // empty' "$cfg" 2>/dev/null || true)
	weights='test 1'
	unit='개'
fi
[ -n "$ceiling" ] || exit 0
case "$ceiling" in ''|*[!0-9]*) exit 0 ;; esac

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

# Occurrences of one marker, counted rather than matching lines — `grep -c` would
# collapse two on one line into one. A dot before the name excludes `test.describe(`
# and `page.sendOrder(`: a describe block is not a test, and a method call on an
# object is not the helper this budget is about.
count_marker() {
	if [ "$1" = 'test' ]; then
		grep -oE '(^|[^.[:alnum:]_])(test|it)[[:space:]]*\(' | wc -l | tr -d ' '
	else
		grep -oE "(^|[^.[:alnum:]_])$1[[:space:]]*\(" | wc -l | tr -d ' '
	fi
}

# Weighted cost of the spec source arriving on stdin, printed as
# `<total>|<breakdown>`. One string rather than two variables because every call
# is inside a command substitution, and a subshell cannot hand a variable back.
cost_of() {
	text=$(cat)
	total=0
	parts=''
	while IFS=' ' read -r name weight; do
		[ -n "$name" ] || continue
		case "$weight" in ''|*[!0-9]*) continue ;; esac
		n=$(printf '%s' "$text" | count_marker "$name")
		[ "$n" -gt 0 ] || continue
		total=$((total + n * weight))
		parts="${parts}${parts:+, }${name} ${n}회×${weight}"
	done <<EOF
$weights
EOF
	printf '%s|%s' "$total" "$parts"
}

# The two halves of what `cost_of` printed.
total_of() { printf '%s' "${1%%|*}"; }
parts_of() { printf '%s' "${1#*|}"; }

# Everything the suite holds right now.
existing=0
while IFS= read -r d; do
	[ -n "$d" ] || continue
	[ -d "$root/$d" ] || continue
	n=$(find "$root/$d" -type f -name '*.spec.ts' -exec cat {} + 2>/dev/null | cost_of)
	existing=$((existing + $(total_of "$n")))
done <<EOF
$dirs
EOF

# What this call would add. Write replaces the file, so its delta is the new
# content against whatever is on disk; Edit's delta is new_string against
# old_string. MultiEdit carries an array of those.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
case "$tool" in
	Write)
		a=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' | cost_of)
		b='0|'
		[ -f "$path" ] && b=$(cost_of <"$path")
		;;
	Edit)
		a=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' | cost_of)
		b=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' | cost_of)
		;;
	MultiEdit)
		a=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")' | cost_of)
		b=$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.old_string] | join("\n")' | cost_of)
		;;
	*) exit 0 ;;
esac

added=$(parts_of "$a")
delta=$(( $(total_of "$a") - $(total_of "$b") ))
# Removing, or rewriting into something cheaper, is always allowed — including
# while over budget. The gate exists to slow growth, not to freeze a suite
# someone is in the middle of shrinking.
[ "$delta" -gt 0 ] || exit 0

projected=$((existing + delta))
[ "$projected" -gt "$ceiling" ] || exit 0

rule=$(jq -r '.budgets.e2e.rule // empty' "$cfg" 2>/dev/null || true)
[ -n "$rule" ] || rule='e2e는 브라우저가 필요한 것만 담는다. 나머지는 유닛이다.'

reason=$(cat <<EOF
[wt] e2e 예산 초과 — 이 쓰기는 거부됐다.

지금 ${existing}${unit} + 이 변경 ${delta} = ${projected}. 상한 ${ceiling}.
이 쓰기가 더하는 것: ${added:-없음}

${rule}

**개수가 아니라 비용으로 잰다.** 값싼 테스트는 거의 공짜이고 브라우저를 띄우거나 무거운
렌더를 도는 것이 비싸다 — 위의 내역이 어느 호출 때문인지 말해준다. 그 호출을 안 하고
같은 것을 물을 수 있으면 그렇게 해라.

정말 이 비용을 써야 하면 **다른 e2e를 먼저 지워라** — 그 판단을 하는 것이 이 예산의
목적이다. 대부분의 경우 답은 유닛 테스트이고, 그러면 이 훅은 아무 말도 하지 않는다.
상한 자체가 틀렸다고 판단하면 사용자에게 말해라. .claude/wt.json 의 budgets.e2e 를
네가 조용히 올리는 것은 이 장치를 없애는 것과 같다.
EOF
)

# PreToolUse is the only event that can refuse a call. `permissionDecision:
# "deny"` puts the reason in front of the model instead of running the tool.
jq -cn --arg reason "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
exit 0
