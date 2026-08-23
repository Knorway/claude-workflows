#!/usr/bin/env bash
# PostToolUse hook. Fires after every Write/Edit and stays silent unless the file
# is a convention doc (CLAUDE.md / AGENTS.md / DESIGN.md) that just went over its
# line budget.
#
# Why a budget at all: those three files are the ONLY evidence base of the
# convention lens in /wt:review (agents/reviewer.md, procedure 2). A doc that
# grows without a ceiling stops being a rule set and becomes a transcript — and
# then every round of the review loop reads more prose to decide less. The cap is
# per file, not per repo: a monorepo's workspace docs each get their own 200.
#
# The budget is a proxy. The real rule is the second question in the message
# below — "can you learn it by reading the code?" — which no script can measure.
# Line count is what a hook CAN check, and in practice a file goes over exactly
# when someone has been appending what the code already says.
#
# Detection, not rollback: the write already landed and trimming is a judgment
# call (which lines are load-bearing?). Same stance as the test ratchet in
# /wt:review step 5 — make it visible, let the model act.
set -euo pipefail

BUDGET=200

# jq is a hard dependency of this plugin, but this hook fires on EVERY edit under
# `set -euo pipefail` — without the guard a missing jq exits 127 and the user eats
# a hook error on every single write. Same reasoning as plan-nudge.sh.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')

[ -n "$path" ] || exit 0
case "$(basename "$path")" in
	CLAUDE.md|AGENTS.md|DESIGN.md) ;;
	*) exit 0 ;;
esac

# The file can be gone by now (a rename or a delete after the write). Never fail
# the tool call over a missing file.
[ -f "$path" ] || exit 0

lines=$(wc -l < "$path" | tr -d ' ')
[ "$lines" -gt "$BUDGET" ] || exit 0

# exit 2 is the one PostToolUse channel that reaches the model on every Claude
# Code version: stderr comes back as feedback. `hookSpecificOutput.additionalContext`
# is newer and event-dependent, so it is not used here.
cat >&2 <<EOF
[claude-md-budget] $path 가 ${lines}줄이다. 예산은 파일당 ${BUDGET}줄 내외이고
$((lines - BUDGET))줄 초과했다. 늘릴 게 아니라 **덜어낼 것을 찾는 신호**다.

지금 이 파일을 줄여라. 한 줄을 남길지 지울지는 두 가지만 묻는다:

1. 이걸 모르면 반드시 헤매는가?
2. 코드를 읽으면 알 수 있는가?

2가 참이면 여기 적을 것이 아니다 — 지운다. 파일 하나의 근거·함정·측정값은 **코드 주석**으로,
길고 자주 안 읽는 재생성 절차는 **docs/** 로 옮긴다. CLAUDE.md에 남는 것은 **파일을 열어봐도
안 보이는 것**뿐이다: 워크스페이스 경계, 어느 파일을 봐야 하는지의 지도, 여러 파일에 걸친
불변식, 레포 밖 사실(대시보드 설정·측정값 같은).

같은 사실을 두 곳에 적지 마라 — 한쪽은 반드시 썩는다. 그리고 작업을 끝낼 때마다 그 작업을
여기 덧붙이는 것은 금지다.

단, ${BUDGET}줄을 맞추려고 **지식을 버리지는 마라.** 지울 근거가 없는 줄만 남았으면 거기서
멈추고 사용자에게 몇 줄이 왜 남았는지 말해라.
EOF
exit 2
