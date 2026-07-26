#!/usr/bin/env bash
# UserPromptSubmit hook. When the session is NOT in plan mode, inject a short,
# model-only note nudging Claude to offer plan mode for substantive work, so the
# user gets a chance to review the plan before implementation begins.
#
# Stateless on purpose. The "suggest at most once, skip trivia" judgment lives in
# the injected text and is enforced by the model reading its own conversation
# history — no marker files. Silent in plan mode, and silent whenever the mode
# field is absent (never guess).
#
# One carve-out: a /wt:todo selection reply must claim FIRST — before any
# plan-mode proposal or EnterPlanMode call — or another tab can grab the same
# item while this session explores. There the model doesn't propose at all: it
# claims, then enters plan mode itself. The injected text states that exception
# explicitly.
#
# The carve-out only has teeth in a non-plan session, which is the only kind this
# hook fires in anyway: plan mode blocks every write, claim included, so a repo
# whose defaultMode is `plan` can't claim without a human toggling out first.
# That trade-off is the repo owner's call, not this plugin's — see commands/todo.md.
set -euo pipefail

# jq is a hard dependency of this plugin, but this hook fires on EVERY prompt and
# runs under `set -euo pipefail` — without the guard a missing jq exits 127 and
# the user eats a hook error on every single turn. A nudge is the most optional
# thing here: no jq, no nudge, no noise.
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
mode=$(printf '%s' "$input" | jq -r '.permission_mode // empty')

# Only when we positively know the mode and it isn't plan.
[ -n "$mode" ] || exit 0
[ "$mode" = "plan" ] && exit 0

ctx=$(cat <<EOF
[plan-nudge] 지금 plan 모드가 아니다(permission mode=$mode). 이번 요청이 기능
구현·리팩터·다단계 변경 같은 실질 작업이면, 착수 전에 "plan 모드로 전환할까요?
(shift+tab)"를 한 번만 제안하라 — 그래야 사용자가 착수 전에 플랜을 검토할 수 있다.
단발 질문·사소한 수정이거나, 이미 이 대화에서 제안했거나 사용자가 거절했으면
조용히 넘어가라. 예외: 이 프롬프트가 TODO 목록에 대한 번호 선택 답장이면, plan
모드 제안이나 EnterPlanMode를 포함해 다른 무엇보다 먼저 \`wt-todo claim\`을 실행해
점유를 박아야 한다. 그 뒤 항목이 사소하지 않으면 — 이때는 묻지 말고 — 곧바로
EnterPlanMode로 진입해 탐색·설계를 이어가라. 이 안내는 사용자에게 보이지 않는다.
EOF
)

jq -nc --arg c "$ctx" \
	'{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
