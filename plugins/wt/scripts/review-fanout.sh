#!/usr/bin/env bash
# Steps 2-4 of /wt:review — lens fan-out, aggregation, refutation — run in a
# SEPARATE `claude -p` process instead of the implementing session.
#
#   review-fanout.sh --repo <root> --out <file> [--base-at <sha> | --pr <n>]
#                    [--lenses 1,2,3,4] [--test-writer] [--untracked "<paths>"]
#                    [--scope "<paths>"] [--budget <usd>]
#
# WHY THIS IS A SEPARATE PROCESS AND NOT SUBAGENTS IN THE CALLING SESSION.
# Measured across four real reviews (~/.claude/projects/*.jsonl `usage`): the
# ORCHESTRATOR, not the subagents, is half to two thirds of a review's cost, and
# almost all of that is `cache_read` = the context it is carrying x the number of
# requests it makes. Steps 2-4 are most of those requests and they read none of
# that context — the reviewers get a fresh window (measured: 5.6k-9.7k on their
# first request, they inherit nothing). So the session was paying to carry an
# implementation transcript through the one phase that provably cannot use it.
#
#   root-camera, uncompacted:  81 req x 428k avg ctx -> $25.0 orchestrator
#   root-camera, post-compact: 24 req x  80k avg ctx -> $ 2.7 orchestrator
#
# Compacting the session first hits the same term, but it burns the context that
# step 5 (the fixer) needs — the one step in this pipeline with no gate on its
# output. Moving steps 2-4 out hits the term without touching the fixer at all.
#
# The second, larger win is not in the review: a review INFLATES the session
# (+23k to +80k measured), and that increment then rides along in every request
# for the rest of the session. Out here, the session absorbs only the table.
#
# WHAT THIS BUYS THAT SUBAGENTS COULD NOT. `total_cost_usd` includes the nested
# subagents (measured: $0.194 total for a run whose orchestrator part was ~$0.10),
# so a review's price is observable for the first time, and `--max-budget-usd`
# caps it. Neither is possible for in-session subagents.
#
# THE ONE RULE: this process REPORTS. It never fixes. Fixing stays in the calling
# session where the implementation context lives, and where the ratchet check in
# step 5 can see what happened via `git diff`. The only writes permitted out here
# are the test writer's new test files, and only when --test-writer is passed.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-common.sh"

REPO='' OUT='' BASE_AT='' PR='' LENSES='1,2,3' TEST_WRITER=0
UNTRACKED='' BUDGET=''
SCOPE_ARGV=()

# `need` exists because a trailing flag with no value used to make `shift 2` fail
# and `set -e` kill the script with exit 1 and not one word of output — an exit
# code the calling contract does not define, produced by a plain typo.
need() { [ "$2" -ge 2 ] || { echo "review-fanout.sh: $1 에 값이 없다" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)        need "$1" $#; REPO=$2; shift 2 ;;
		--out)         need "$1" $#; OUT=$2; shift 2 ;;
		--base-at)     need "$1" $#; BASE_AT=$2; shift 2 ;;
		--pr)          need "$1" $#; PR=$2; shift 2 ;;
		--lenses)      need "$1" $#; LENSES=$2; shift 2 ;;
		--untracked)   need "$1" $#; UNTRACKED=$2; shift 2 ;;
		--budget)      need "$1" $#; BUDGET=$2; shift 2 ;;
		# Repeatable, one path per flag. A single space-separated string went
		# through `read -ra`, so `--scope "My Notes.md"` became two pathspecs that
		# match nothing: git exits 0 with an empty diff and the re-review passes
		# with "no findings". A path with a space is not exotic enough to fail
		# that quietly.
		--scope)       need "$1" $#; SCOPE_ARGV+=("$2"); shift 2 ;;
		--test-writer) TEST_WRITER=1; shift ;;
		*) echo "review-fanout.sh: 모르는 인자: $1" >&2; exit 2 ;;
	esac
done

[ -n "$REPO" ] || { echo "review-fanout.sh: --repo 가 필요하다" >&2; exit 2; }
[ -n "$OUT" ]  || { echo "review-fanout.sh: --out 이 필요하다" >&2; exit 2; }
[ -n "$BASE_AT" ] || [ -n "$PR" ] || {
	echo "review-fanout.sh: --base-at 또는 --pr 중 하나가 필요하다" >&2; exit 2; }

# Exit 3 is the FALLBACK signal, distinct from a failed review: the caller drops
# back to running the fan-out with in-session subagents. A missing CLI or python3
# must not mean "no findings" — that reads as a clean review.
command -v claude  >/dev/null 2>&1 || { echo "review-fanout.sh: claude CLI 가 PATH 에 없다 — 세션 안 폴백" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "review-fanout.sh: python3 가 없다 — 세션 안 폴백" >&2; exit 3; }

cd "$REPO"

# Absolutise AFTER the cd, because `git rev-parse --git-dir` — the natural place
# for this file, and where wt-verify keeps its own ledger — prints a RELATIVE path
# in a primary checkout. The inner process is told to Write to this path from its
# own cwd, and a caller standing anywhere but the repo root would send it
# somewhere else entirely.
case "$OUT" in
	/*) ;;
	*)  OUT="$PWD/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"

# Delete it BEFORE the run, not after. This file is the salvage path, and a
# salvage path that can return a PREVIOUS review's findings is worse than having
# none: the caller gets exit 0 and a plausible table describing a diff that no
# longer exists. The stale copy is indistinguishable from a fresh one.
rm -f "$OUT"

# TWO REPRESENTATIONS, AND THEY MUST NOT BE THE SAME ONE.
#
# DIFF_ARGV is what WE run — an array, executed directly, never through `eval`.
# wt-design.md §2 invariant 2 ("plugin scripts never eval a string the repo gave
# them") is not negotiable, and it is not theoretical here: `--pr`, `--base-at`
# and `--scope` all reach this line from outside, so an eval'd string is a shell
# injection with a branch name as its payload.
#
# DIFF_CMD is the same command as TEXT, because the subagents are handed a command
# to run rather than a diff to read. It is built by quoting each argv element, so
# the two can never disagree about what is being reviewed — and `:(exclude)*.lock`
# arrives over there as a single word instead of a syntax error (which is what an
# unquoted `(` produced: every reviewer would have seen an empty diff and reported
# nothing, the quietest possible failure).
shq() {
	case "$1" in
		*[!A-Za-z0-9_./=-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
		*)                   printf '%s' "$1" ;;
	esac
}

EXCLUDE_ARGV=(':(exclude)*.lock' ':(exclude)*.lockb' ':(exclude)*-lock.json'
              ':(exclude)*-lock.yaml' ':(exclude)npm-shrinkwrap.json' ':(exclude)go.sum')

# SCOPE is tested BEFORE PR on purpose. A re-review says "the range is only the
# files the fixer touched", and `gh pr diff` cannot honour that — it returns the
# whole PR. With PR winning, the prompt claimed a narrow scope while the reviewer
# read everything, which is worse than either behaviour alone.
if [ ${#SCOPE_ARGV[@]} -gt 0 ]; then
	[ -n "$BASE_AT" ] || { echo "review-fanout.sh: --scope 는 --base-at 과 함께 써야 한다 (PR diff 로는 범위를 좁힐 수 없다)" >&2; exit 2; }
	DIFF_ARGV=(git diff "$BASE_AT" -- "${SCOPE_ARGV[@]}")
elif [ -n "$PR" ]; then
	DIFF_ARGV=(gh pr diff "$PR")
else
	DIFF_ARGV=(git diff "$BASE_AT" -- "${EXCLUDE_ARGV[@]}")
fi

DIFF_CMD=''
for arg in "${DIFF_ARGV[@]}"; do DIFF_CMD="$DIFF_CMD${DIFF_CMD:+ }$(shq "$arg")"; done

# Budget from diff size, because that is what the reviewers actually read. The
# floor exists so a two-line diff still affords a fan-out; the ceiling is the
# backstop the calling session never had.
#
# An empty diff is a HARD STOP, not a warning. The subagents get this exact
# command; if it yields nothing they each review nothing and truthfully report
# nothing, and the caller receives exit 0 with an empty findings array — byte for
# byte what a clean review looks like. Every silent failure this script has had so
# far (an unquoted `(`, a scope path with a space, a wrong PR number) arrived
# through this one door, and wt-design.md §2 invariant 3 is explicit that an
# unrun check is reported by name rather than by silence.
#
# The count runs unconditionally for that reason — `--budget` skips the sizing,
# never the check.
#
# A BROKEN diff command and an EMPTY one are told apart, and that distinction is
# the whole point of keeping stderr. `2>/dev/null` collapsed them: a bad --base-at,
# a deleted branch and a wrong PR number all produced "diff 가 비었다", which sends
# the reader looking for a change that is in fact right there. git already says
# exactly what is wrong ("fatal: bad object …"); throwing that away and guessing in
# its place is strictly worse than saying nothing.
DIFF_ERR=$(mktemp)
set +e
diff_out=$("${DIFF_ARGV[@]}" 2>"$DIFF_ERR")
diff_rc=$?
set -e

if [ "$diff_rc" != 0 ]; then
	echo "review-fanout.sh: diff 명령이 실패했다 (rc=$diff_rc) — 범위 인자가 틀렸다:" >&2
	echo "    $DIFF_CMD" >&2
	sed 's/^/    /' "$DIFF_ERR" >&2
	rm -f "$DIFF_ERR"
	exit 2
fi

if [ -s "$DIFF_ERR" ]; then
	# rc 0 with output on stderr: `gh` warns this way, and the warning can be the
	# only sign that the diff is not what was asked for.
	echo "  diff 명령이 경고를 냈다:" >&2
	sed 's/^/    /' "$DIFF_ERR" >&2
fi
rm -f "$DIFF_ERR"

if [ -z "$diff_out" ]; then
	# An empty diff is only fatal when there is nothing else for the reviewers to
	# read. With --untracked there is: `git diff` never shows a new file, so a
	# re-review of freshly created files is empty BY CONSTRUCTION.
	#
	# That case is not hypothetical — this loop hits it on itself. Step 5 fixes a
	# file, the re-review scopes to that file, and if the file is new the scoped
	# diff is empty and the re-review exits 2 every single time. The check meant to
	# stop silent failures became a guaranteed one for exactly the changes least
	# covered by anything else.
	if [ -n "$UNTRACKED" ]; then
		echo "  diff 는 비었지만 untracked 경로가 있다 — 서브에이전트가 그 파일들을 직접 읽는다:" >&2
		echo "    $UNTRACKED" >&2
		lines=0
	else
		echo "review-fanout.sh: diff 가 비었다 — 서브에이전트도 같은 명령을 받으므로 리뷰가 성립하지 않는다:" >&2
		echo "    $DIFF_CMD" >&2
		echo "  (변경이 정말 없으면 이 스크립트를 부르기 전에 끝내야 한다. 새 파일만 고쳤다면 --untracked 로 넘겨라.)" >&2
		exit 2
	fi
else
	lines=$(printf '%s\n' "$diff_out" | wc -l | tr -d ' ')
fi

if [ -z "$BUDGET" ]; then
	BUDGET=$(( lines / 200 ))
	[ "$BUDGET" -lt 5 ] && BUDGET=5
	[ "$BUDGET" -gt 25 ] && BUDGET=25
fi

# `Write` is not optional: the durability contract below asks the inner process to
# write its JSON to --out BEFORE answering, and a tool it cannot call is not a
# contract. Leaving it out produced exactly one symptom — an empty --out and a
# useless exit 4 — with no hint that a permission was the cause.
#
# `Edit` stays behind --test-writer. That is the real line: Write lands whole new
# files (what a test writer does), Edit performs surgery inside existing ones
# (what a fixer does), and fixing belongs to the calling session.
#
# NONE OF THIS ENFORCES "이 프로세스는 아무것도 고치지 않는다". Be honest about it:
# `Bash` here is unscoped, so the rule lives in the prompt and a prompt is not a
# permission. Scoping it is not available as a trade — reproduction IS the refuter's
# only route to CONFIRMED (measured: `bash -c 'set -e; false; echo ALIVE'` really
# runs in here, which is what makes the verdict worth anything), and a refuter that
# cannot run commands downgrades every finding to PLAUSIBLE and silently disarms
# step 5. So the answer is the same one the test ratchet gives: what cannot be
# prevented gets DETECTED and shown. See the working-tree fingerprint below.
TOOLS='Task,Read,Grep,Glob,Bash,Write'
[ "$TEST_WRITER" = 1 ] && TOOLS="$TOOLS,Edit"

# --- the prompt -------------------------------------------------------------
# THIS FILE IS THE SINGLE SOURCE for the lens wording, the aggregation rules and
# the two mechanical downgrades. commands/review.md used to carry them; it now
# points here, including for its in-session fallback path. Each sentence was
# written in response to a specific observed failure, so a second copy anywhere
# would drift silently and the drift would decide what gets reviewed.

LENS_DEFS=''
case ",$LENSES," in *,1,*) LENS_DEFS="$LENS_DEFS
1. **정확성** — 이 변경이 깨뜨리는 것. 엣지케이스, null/빈 값, 에러 경로, 경합,
   되돌아온 회귀." ;; esac
case ",$LENSES," in *,2,*) LENS_DEFS="$LENS_DEFS
2. **규약** — \`CLAUDE.md\`/\`AGENTS.md\`/\`DESIGN.md\`가 명시한 규칙 위반. 문서에 적힌
   것만 근거로 삼는다. 리뷰어의 취향은 근거가 아니다.
   **이 diff가 그 문서들 자체를 고쳤다면 그것도 검토 대상이다** — 코드가 규칙을 어긴
   것인지, 규칙이 코드를 따라가며 사후 정당화된 것인지 구분해서 판정하게 한다." ;; esac
case ",$LENSES," in *,3,*) LENS_DEFS="$LENS_DEFS
3. **보안·설정** — 비밀·키·토큰, 커밋되면 안 되는 파일, 클라이언트 번들에 인라인되는
   공개 env, 빌드·네이티브 설정에 미치는 영향." ;; esac
case ",$LENSES," in *,4,*) LENS_DEFS="$LENS_DEFS
4. **인터페이스·데이터 흐름** — 호출자/스키마/타입 계약이 어긋나는 곳, 부분 마이그레이션." ;; esac

# A --lenses value that matches nothing (empty, or `correctness` instead of `1`)
# used to sail through: no lens definitions, a fan-out of nobody, exit 0 and an
# empty findings array — byte-identical to a clean review. Invariant 3 of
# wt-design.md §2 says an unrun check is reported by name, never by silence.
[ -n "$LENS_DEFS" ] || {
	echo "review-fanout.sh: --lenses '$LENSES' 가 아무 렌즈에도 해당하지 않는다 (1,2,3,4 중에서 고른다)" >&2
	exit 2
}

TW_BLOCK='테스트 작성자는 띄우지 않는다.'
if [ "$TEST_WRITER" = 1 ]; then
	TW_BLOCK='**`wt:test-writer` 도 같은 메시지에서 하나 띄운다.** 그가 돌려준 결과는 이렇게 다룬다:

- **빨간 테스트는 finding 으로 편입한다.** 이미 실행으로 확인된 것이므로 `check` 가
  비어 있지 않다 — 아래 기계적 강등에서 내려가지 않는다. `source` 는 `"test-writer"`.
- **`invalid_tests` 도 finding 으로 편입하되 `check` 가 있는 것만.** 없으면 버린다.
  "이 단언은 약해 보인다"는 인상은 취향이고, **공허함을 보이는 명령**이 있어야 결함이다.
- 초록으로 통과한 것은 finding 이 아니라 `tests_written` 에 적는다.'
fi

SCOPE_NOTE=''
if [ ${#SCOPE_ARGV[@]} -gt 0 ]; then
	scope_list=''
	for arg in "${SCOPE_ARGV[@]}"; do scope_list="$scope_list${scope_list:+, }$(shq "$arg")"; done
	SCOPE_NOTE="
**이것은 수정분 재검토다.** 범위는 다음 파일들뿐이다: $scope_list
원래 어떤 지적 때문에 고쳤는지, 무엇을 어떻게 고쳤는지 **너는 모르고 알 필요도 없다.**
수정 의도를 알면 \"코드가 그 의도대로인가\"를 묻게 되는데, 실측에서 잡혀야 했던 결함은
**의도 자체가 틀린** 경우였다. 무맥락 리뷰어만 \"이 전제가 참인가\"를 묻는다."
fi

UNTRACKED_NOTE=''
[ -n "$UNTRACKED" ] && UNTRACKED_NOTE="
추적되지 않는 새 파일이 있다 — \`git diff\` 계열은 이것을 보여주지 않으므로 경로를
넘긴다. 각 서브에이전트가 직접 열게 하라: $UNTRACKED"

PROMPT="너는 코드리뷰 fan-out 오케스트레이터다. 레포 루트는 \`$REPO\` 이고, 리뷰 대상
diff 를 얻는 명령은 다음 하나다:

    $DIFF_CMD

**diff 원문을 네 문맥에 올리지 마라.** 필요하면 \`--stat\` 만 본다. 원문은 각
서브에이전트가 자기 문맥에서 직접 읽는다 — 이게 이 작업의 비용을 결정하는 단 하나의
규칙이다.

**너는 아무것도 고치지 않는다.** 소스 파일을 편집하지 말고, 커밋하지 말고, 워킹 트리를
바꾸지 마라. 수정은 이 프로세스를 부른 세션의 일이다. 네 산출물은 아래 JSON 하나뿐이다.
$SCOPE_NOTE$UNTRACKED_NOTE

## 1. 렌즈 병렬 fan-out

\`wt:reviewer\` 를 렌즈마다 하나씩, **한 메시지에 전부** 띄운다(그래야 동시에 돈다).
이름이 해석되지 않으면 \`general-purpose\` 에 같은 프롬프트를 싣는다.
$LENS_DEFS

$TW_BLOCK

각 서브에이전트 프롬프트에 반드시 넣을 것: 그 렌즈의 정의(위 문장 그대로), **diff 를
얻는 명령 원문**(내용이 아니라 명령을), 레포 루트 경로, **커밋되지 않은 변경이 섞여
있다는 사실**, \"JSON 배열만 출력\".

서브에이전트가 결과 없이 죽으면 **그것만 한 번 재시도한다.** 두 번째도 실패하면 포기하고
\`coverage_gaps\` 에 어느 축이 비었는지 적는다. 조용히 넘어가면 호출자는 전부 돈 줄로 읽는다.

## 2. 취합

- \`file\` + \`line\`(±3줄)이 같은 지적은 하나로 합친다. 서로 다른 렌즈가 같은 곳을
  가리켰다면 그건 신호이니 severity 를 올린다.
- \`low\` 중 실패 시나리오가 부실한 것은 버린다.

## 3. 반증 병렬

남은 finding 마다 \`wt:refuter\` 를 하나씩, **한 메시지에 전부** 띄운다. **finding 당 1표.**
같은 기반 모델을 여러 표 쌓아도 오차가 상관되어 표 수만큼 정확해지지 않는다 — 정확도는
표가 아니라 아래 기계적 관문에서 나온다. 각 프롬프트에 finding JSON 하나를 그대로 싣고
레포 루트를 알려준다. 반증 담당이 결과 없이 죽으면 그것도 한 번 재시도한다.

**돌아온 판정을 그대로 믿지 말고 기계적으로 걸러라. 둘 다 프롬프트가 아니라 네가 강제한다:**

- \`verdict\` 가 \`CONFIRMED\` 인데 **\`check\` 가 비어 있으면** \`PLAUSIBLE\` 로 내린다.
  실측에서 반증 담당이 재현을 못 하자 규칙 기억으로 추론해 오탐을 승인한 사례가 있었다.
- \`check\` 에 **워킹 트리를 바꾸는 명령**이 보이면(리다이렉트 \`>\`·\`>>\`, \`sed -i\`,
  \`tee\`, \`git\` 변경 동사) \`PLAUSIBLE\` 로 내린다. 소스를 고쳐놓고 \"확인했다\"고 하는
  것은 확인이 아니라 **커밋되지 않은 사용자 코드에 남을 수 있는 변경**이다.

## 4. 출력 — 두 번 한다

먼저 아래 JSON 을 **파일 \`$OUT\` 에 Write 로 쓴다.** 그다음 같은 JSON 을 네 최종
응답으로 낸다. 파일을 먼저 쓰는 이유는 네가 예산 상한에 걸리거나 중간에 죽어도 호출자가
거기서 회수할 수 있게 하려는 것이다. 설명 문장 없이 JSON 객체 하나만:

\`\`\`json
{
  \"lenses_run\": [\"정확성\", \"규약\"],
  \"coverage_gaps\": [],
  \"findings\": [
    { \"file\": \"경로/파일.ts\", \"line\": 42, \"severity\": \"high|medium|low\",
      \"claim\": \"\", \"failure_scenario\": \"\", \"evidence\": \"\",
      \"source\": \"lens|test-writer\",
      \"verdict\": \"CONFIRMED|PLAUSIBLE|REFUTED\", \"reason\": \"\",
      \"check\": \"\", \"fix_hint\": \"\" }
  ],
  \"tests_written\": [],
  \"invalid_tests\": [],
  \"notes\": \"\"
}
\`\`\`

\`findings\` 는 REFUTED 까지 **전부** 싣는다 — 무엇이 걸러졌는지 보이지 않으면 호출자가
이 결과를 신뢰할 근거가 없다."

# --- run --------------------------------------------------------------------
echo "  리뷰 fan-out 을 별도 프로세스에서 돌린다 (렌즈 $LENSES$([ "$TEST_WRITER" = 1 ] && echo ' + 테스트작성'), 상한 \$$BUDGET)…" >&2

RAW=$(mktemp)
ERR=$(mktemp)
TREE_BEFORE=$(mktemp)
TREE_AFTER=$(mktemp)
trap 'rm -f "$RAW" "$ERR" "$TREE_BEFORE" "$TREE_AFTER"' EXIT

# The working-tree fingerprint. `--allowedTools` cannot express "read everything,
# write nothing" without taking away the refuter's shell, so instead of pretending
# the prompt is a guarantee, record what the tree looked like and compare after.
#
# The default --out lives under .git/, which `git status` does not report, so the
# expected diff of a well-behaved run is EMPTY — and with --test-writer, exactly
# the new test files and nothing else.
{ git status --porcelain -uall; echo '--- diff ---'; git diff HEAD; } >"$TREE_BEFORE" 2>/dev/null || true

# Keep stderr instead of discarding it. The failures that produce NO parseable
# stdout — expired credentials, an unusable model, a CLI that will not start —
# announce themselves only there, and dropping it left the caller holding an exit
# code and nothing to act on.
set +e
claude -p "$PROMPT" \
	--output-format json \
	--allowedTools "$TOOLS" \
	--max-budget-usd "$BUDGET" \
	>"$RAW" 2>"$ERR"
rc=$?
set -e

# Detect, do not roll back — the same rule the test ratchet follows, for the same
# reason: this runs over a working tree carrying uncommitted user work, so undoing
# anything would take unrelated changes with it. Name what moved and let it reach
# the report; `review.md` already puts coverage_gaps on the report's first line.
{ git status --porcelain -uall; echo '--- diff ---'; git diff HEAD; } >"$TREE_AFTER" 2>/dev/null || true

# `git status` alone was not enough: this loop runs over a tree that is ALREADY
# dirty, and editing an already-modified file leaves its status line byte-identical
# (`M path` before and after). The one case the detector most needed to catch was
# the one it structurally could not see, so the fingerprint carries `git diff HEAD`
# too — content, not just the file list.
#
# Names come from the status half; the diff half only decides whether something
# moved. Reporting changed status lines beats dumping a diff into the caller's
# transcript, and the caller can run `git diff` for the detail.
if cmp -s "$TREE_BEFORE" "$TREE_AFTER"; then
	TOUCHED=''
else
	TOUCHED=$(diff <(sed '/^--- diff ---$/q' "$TREE_BEFORE") <(sed '/^--- diff ---$/q' "$TREE_AFTER") 2>/dev/null \
		| grep -E '^[<>]' | sed 's/^< /사라짐: /; s/^> /생김: /' | tr '\n' ';' || true)
	[ -n "$TOUCHED" ] || TOUCHED='이미 변경돼 있던 파일의 내용이 더 바뀌었다 (git diff 로 확인해라)'
fi
if [ -n "$TOUCHED" ]; then
	if [ "$TEST_WRITER" = 1 ]; then
		echo "  fan-out 이 워킹 트리를 건드렸다 (테스트 작성자가 켜져 있으니 새 테스트 파일이면 정상): $TOUCHED" >&2
	else
		echo "  경고: fan-out 이 워킹 트리를 건드렸다 — 리뷰 프로세스는 아무것도 고치지 않아야 한다: $TOUCHED" >&2
	fi
fi

# The `--out` file is authoritative when it exists: the inner process was told to
# write it BEFORE answering, so it survives a budget stop or a crash that leaves
# no parseable result. Falling back to it is the whole reason for the two-step
# output contract above.
#
# `set +e` around this is deliberate. Exit 4 and 5 are meaningful codes the caller
# branches on, and leaving `set -e` to propagate them works only by accident —
# one added line after this block would silently start swallowing them.
set +e
python3 - "$RAW" "$OUT" "$rc" "$TOUCHED" "$TEST_WRITER" <<'PY'
import json, re, sys

raw_path, out_path, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
touched, test_writer = sys.argv[4], sys.argv[5]

def emit(payload, cost, note, code):
    payload.setdefault("lenses_run", [])
    payload.setdefault("coverage_gaps", [])
    payload.setdefault("findings", [])
    payload.setdefault("tests_written", [])
    payload.setdefault("invalid_tests", [])
    payload["cost_usd"] = cost
    gaps = list(payload["coverage_gaps"])
    if note:
        gaps.append(note)
    # The fingerprint result rides in coverage_gaps because that is the one field
    # review.md is already required to surface on the report's first line. A
    # detection nobody reads is not a detection.
    if touched:
        gaps.append(
            ("테스트 작성자가 워킹 트리에 남긴 것(새 테스트 파일이어야 한다): " if test_writer == "1"
             else "⚠ 리뷰 프로세스가 워킹 트리를 변경했다 — 리뷰는 아무것도 고치지 않아야 한다: ")
            + touched)
    payload["coverage_gaps"] = gaps
    with open(out_path, "w") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    sys.exit(code)

def from_out_file():
    # The same isinstance guard the main parse path has. Without it the SALVAGE
    # path — the one that exists precisely for when things have already gone wrong
    # — dies on an unhandled exception the moment the file holds an array or a
    # bare string, turning a recoverable failure into a traceback.
    try:
        with open(out_path) as f:
            parsed = json.load(f)
    except Exception:
        return None
    return parsed if isinstance(parsed, dict) else None

try:
    with open(raw_path) as f:
        env = json.load(f)
except Exception:
    env = None

if env is None:
    salvaged = from_out_file()
    if salvaged is not None:
        # cost is None, not 0.0. The envelope that carries total_cost_usd is the
        # thing that failed to parse, so the price is UNKNOWN — and review.md
        # step 6 reports this number as "measured, not guessed". A literal 0.0
        # would make a partial run look free.
        emit(salvaged, None,
             "fan-out 프로세스가 결과를 못 냈다 — --out 파일에서 회수함. 비용 미상, 커버리지 불완전할 수 있음", 0)
    sys.stderr.write("  fan-out 프로세스가 JSON 을 내지 않았다 (rc=%d)\n" % rc)
    sys.exit(4)

# `or 0.0` would fold "the field is missing" into "it cost nothing", which is the
# exact conflation this file rejects a few lines up when it refuses to report a
# salvaged run as free. A price that was never reported is unknown, not zero.
cost = env.get("total_cost_usd")
if not isinstance(cost, (int, float)):
    cost = None
result = env.get("result") or ""

payload = None
# The result is normally the bare JSON object; a fenced block is the common miss.
for candidate in (result, *re.findall(r"```(?:json)?\s*(.*?)```", result, re.S)):
    try:
        parsed = json.loads(candidate.strip())
    except Exception:
        continue
    if isinstance(parsed, dict):
        payload = parsed
        break

if payload is None:
    salvaged = from_out_file()
    if salvaged is not None:
        emit(salvaged, cost, "최종 응답이 JSON 이 아니었다 — --out 파일에서 회수함", 0)
    sys.stderr.write("  fan-out 결과를 JSON 으로 못 읽었다 (rc=%d, cost=%s)\n"
                     % (rc, ("$%.2f" % cost) if cost is not None else "미상"))
    # Permission denials first: a tool the inner process was never allowed to call
    # looks exactly like a model that ignored the contract, and the two have
    # completely different fixes. This diagnostic exists because that confusion
    # cost a full review run.
    denials = env.get("permission_denials") or []
    if denials:
        sys.stderr.write("  거부된 도구 호출: %s\n"
                         % ", ".join(sorted({d.get("tool_name", "?") for d in denials})))
    # The unparseable response goes to a FILE, not to stderr. It can quote diff
    # excerpts, and stderr here lands in the calling session's transcript, where a
    # secret that happened to sit in the diff would be permanent. A path is just
    # as debuggable and keeps the content where the diff already was.
    dump = out_path + ".raw"
    try:
        with open(dump, "w") as f:
            f.write(result)
        sys.stderr.write("  응답 원문을 %s 에 남겼다\n" % dump)
    except Exception:
        pass
    sys.exit(5)

note = None
if env.get("is_error") or rc != 0:
    note = "fan-out 프로세스가 오류·예산상한으로 끝났다 — 커버리지가 불완전할 수 있다"
emit(payload, cost, note, 0)
PY

rc2=$?
set -e

# Only on failure, and only the tail: a healthy run writes progress noise here
# that would drown the summary line.
if [ "$rc2" != 0 ] && [ -s "$ERR" ]; then
	echo "  claude 프로세스 stderr (마지막 10줄):" >&2
	tail -10 "$ERR" >&2
fi

if [ "$rc2" = 0 ]; then
	# Cost goes to stderr so the caller can put a measured number in its report
	# instead of the guess the old step 6 asked for.
	#
	# `|| true` and the isinstance guards are the same defect twice: this block runs
	# under `set -e` AFTER the payload is already written and reported, so a findings
	# element that is a string instead of an object would kill the script with an
	# exit code outside the documented 0/2/3/4/5 contract — losing a review that had
	# in fact succeeded, over a cosmetic summary line.
	python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
f=[x for x in (d.get("findings") or []) if isinstance(x,dict)]
n=lambda v:sum(1 for x in f if x.get("verdict")==v)
c=d.get("cost_usd")
sys.stderr.write("  fan-out 끝 — CONFIRMED %d / PLAUSIBLE %d / REFUTED %d · %s\n"
                 % (n("CONFIRMED"), n("PLAUSIBLE"), n("REFUTED"),
                    ("$%.2f" % c) if isinstance(c,(int,float)) else "비용 미상"))
for g in (d.get("coverage_gaps") or []):
    sys.stderr.write("  커버리지 구멍: %s\n" % g)
' "$OUT" || true
fi

exit "$rc2"
